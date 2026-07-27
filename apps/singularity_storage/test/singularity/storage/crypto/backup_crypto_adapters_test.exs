defmodule Singularity.Storage.Crypto.BackupCryptoAdaptersTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Storage.Crypto.Argon2KeyDeriver
  alias Singularity.Storage.Crypto.BackupKeyDeriver
  alias Singularity.Storage.Crypto.BackupRecoveryWrapper
  alias Singularity.Storage.Crypto.KeyWrapper

  @passphrase "correct horse battery staple"
  @salt :binary.list_to_bin(Enum.to_list(0..15))
  @kdf %{
    domain: "singularity.backup.bundle.v1",
    parameters: %{
      "m_cost" => 65_536,
      "parallelism" => 2,
      "t_cost" => 5,
      "version" => 4
    },
    salt: @salt
  }
  @expected_key Base.decode16!(
                  "2d61d2d842b83b70eae721d46552fdcd42afbf11589690a245e792a9b3653c03",
                  case: :lower
                )

  @manifest_id "00000000-0000-4000-8000-000000000741"
  @other_manifest_id "00000000-0000-4000-8000-000000000742"
  @vault_id "00000000-0000-4000-8000-000000000743"
  @other_vault_id "00000000-0000-4000-8000-000000000744"
  @backup_key :binary.copy(<<0xA4>>, 32)
  @vault_key :binary.copy(<<0xB4>>, 32)
  @binding %{
    label: :backup_recovery,
    manifest_id: @manifest_id,
    vault_id: @vault_id
  }

  test "derives the fixed backup-key vector from the exact allowlisted profile" do
    assert {:ok, @expected_key} = BackupKeyDeriver.derive(@passphrase, @kdf)

    assert {:ok, vault_kek} =
             Argon2KeyDeriver.derive(@passphrase, @salt, %{
               version: 1,
               t_cost: 5,
               m_cost: 16,
               parallelism: 2
             })

    refute vault_kek == @expected_key
  end

  test "rejects malformed or non-allowlisted KDF metadata before derivation" do
    invalid_kdfs = [
      put_in(@kdf, [:domain], "singularity:v1:vault-kek:"),
      put_in(@kdf, [:parameters, "version"], 3),
      put_in(@kdf, [:parameters, "t_cost"], 6),
      put_in(@kdf, [:parameters, "m_cost"], 4_294_967_295),
      put_in(@kdf, [:parameters, "parallelism"], 1),
      put_in(@kdf, [:salt], :binary.copy(<<0>>, 15)),
      put_in(@kdf, [:salt], Base.encode64(@salt)),
      Map.put(@kdf, :extra, true),
      %{domain: @kdf.domain, parameters: Map.put(@kdf.parameters, "extra", 1), salt: @salt},
      %{"domain" => @kdf.domain, "parameters" => @kdf.parameters, "salt" => @salt}
    ]

    for invalid_kdf <- invalid_kdfs do
      assert_backup_invalid(BackupKeyDeriver.derive(@passphrase, invalid_kdf))
    end

    for invalid_passphrase <- [nil, "", :not_a_secret] do
      assert_backup_invalid(BackupKeyDeriver.derive(invalid_passphrase, @kdf))
    end
  end

  test "adapts the recovery binding to KeyWrapper with deterministic versioned AAD" do
    assert {:ok, encoded} =
             BackupRecoveryWrapper.wrap(@backup_key, @vault_key, @binding)

    assert is_binary(encoded) and encoded != ""
    assert {:ok, @vault_key} = BackupRecoveryWrapper.unwrap(@backup_key, encoded, @binding)

    aad =
      :erlang.term_to_binary(
        {"singularity.backup.recovery", 1, @manifest_id, @vault_id},
        [:deterministic]
      )

    assert {:ok, @vault_key} =
             KeyWrapper.unwrap(@backup_key, encoded, %{
               purpose: :backup_recovery,
               generation: 1,
               aad: aad
             })

    assert {:error, %Error{code: :integrity_failure}} =
             KeyWrapper.unwrap(@backup_key, encoded, %{
               purpose: :backup_recovery,
               generation: 1,
               aad:
                 :erlang.term_to_binary(
                   {"singularity.backup.recovery", 2, @manifest_id, @vault_id},
                   [:deterministic]
                 )
             })

    assert {:error, %Error{code: :integrity_failure}} =
             KeyWrapper.unwrap(@backup_key, encoded, %{
               purpose: :vault_key,
               generation: 1,
               aad: @vault_id
             })
  end

  test "rejects malformed keys, wrappers, and recovery bindings uniformly" do
    assert {:ok, encoded} =
             BackupRecoveryWrapper.wrap(@backup_key, @vault_key, @binding)

    invalid_bindings = [
      %{@binding | label: :vault_key},
      %{@binding | label: "backup_recovery"},
      %{@binding | manifest_id: @other_manifest_id},
      %{@binding | vault_id: @other_vault_id},
      %{@binding | manifest_id: "not-a-uuid"},
      Map.put(@binding, :extra, true),
      Map.delete(@binding, :vault_id)
    ]

    for invalid_binding <- invalid_bindings do
      assert_backup_invalid(BackupRecoveryWrapper.unwrap(@backup_key, encoded, invalid_binding))
    end

    assert_backup_invalid(
      BackupRecoveryWrapper.unwrap(:binary.copy(<<0xC4>>, 32), encoded, @binding)
    )

    assert_backup_invalid(
      BackupRecoveryWrapper.unwrap(
        @backup_key,
        binary_part(encoded, 0, byte_size(encoded) - 1),
        @binding
      )
    )

    assert_backup_invalid(
      BackupRecoveryWrapper.wrap(:binary.copy(<<0xA4>>, 31), @vault_key, @binding)
    )

    assert_backup_invalid(
      BackupRecoveryWrapper.wrap(@backup_key, :binary.copy(<<0xB4>>, 31), @binding)
    )
  end

  defp assert_backup_invalid(result) do
    assert {:error,
            %Error{
              code: :backup_invalid,
              details: %{},
              message: nil,
              retryable?: false
            }} = result
  end
end
