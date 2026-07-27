defmodule Singularity.Runtime.RecoveredVaultKeyTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Runtime.BackupKeyLease
  alias Singularity.Storage.Backup.BundleReader
  alias Singularity.Storage.Backup.Manifest
  alias Singularity.Storage.Crypto.BackupRecoveryWrapper
  alias Singularity.Storage.Crypto.ChunkedAEAD
  alias Singularity.Storage.Crypto.KeyWrapper
  alias Singularity.Storage.Crypto.RecoveredVaultKey

  @manifest_id "00000000-0000-4000-8000-000000000751"
  @other_manifest_id "00000000-0000-4000-8000-000000000752"
  @vault_id "00000000-0000-4000-8000-000000000753"
  @other_vault_id "00000000-0000-4000-8000-000000000754"
  @snapshot_id "00000000-0000-4000-8000-000000000755"
  @backup_key :binary.copy(<<0xA5>>, 32)
  @vault_key :binary.copy(<<0xB5>>, 32)
  @new_kek :binary.copy(<<0xC5>>, 32)
  @record_payload "authenticated logical restore record"

  test "BundleReader authentication gates an opaque one-shot vault-key rewrap" do
    fixture = encrypted_bundle_fixture()
    lease = start_restore_lease(fixture)

    assert {:ok, verified} =
             BundleReader.authenticate_all(fixture.source,
               crypto: {BackupKeyLease.StorageAdapter, lease}
             )

    proof = authenticated_proof(verified)

    assert {:ok, capability} =
             BackupKeyLease.claim_recovered_vault_key(lease, proof)

    assert %{__struct__: RecoveredVaultKey} = capability
    assert inspect(capability) == "#RecoveredVaultKey<REDACTED>"

    assert {:ok,
            %{
              algorithm: :aes_256_gcm,
              encoded: encoded,
              generation: 7,
              purpose: :vault_key,
              version: 1
            } = wrapper} =
             RecoveredVaultKey.rewrap(capability, @new_kek, %{
               vault_id: @vault_id,
               generation: 7
             })

    assert {:ok, @vault_key} =
             KeyWrapper.unwrap(@new_kek, encoded, %{
               purpose: :vault_key,
               generation: 7,
               aad: @vault_id
             })

    assert {:error, :lease_unavailable} =
             RecoveredVaultKey.rewrap(capability, @new_kek, %{
               vault_id: @vault_id,
               generation: 7
             })

    assert :ok = RecoveredVaultKey.revoke(capability)
    assert :ok = RecoveredVaultKey.revoke(capability)

    refute secret_leaked?([verified, proof, capability, wrapper], [@backup_key, @vault_key])
  end

  test "claim requires the restore owner and every authenticated proof binding" do
    fixture = encrypted_bundle_fixture()
    lease = start_restore_lease(fixture)

    assert_backup_invalid(
      BackupKeyLease.claim_recovered_vault_key(lease, %{
        manifest_id: @manifest_id
      })
    )

    foreign_authentication =
      Task.async(fn ->
        BundleReader.authenticate_all(fixture.source,
          crypto: {BackupKeyLease.StorageAdapter, lease}
        )
      end)

    assert_backup_invalid(Task.await(foreign_authentication))

    assert {:ok, verified} =
             BundleReader.authenticate_all(fixture.source,
               crypto: {BackupKeyLease.StorageAdapter, lease}
             )

    proof = authenticated_proof(verified)

    invalid_proofs = [
      %{proof | vault_id: @other_vault_id},
      %{proof | manifest_id: @other_manifest_id},
      %{proof | manifest_hash: flip_last_byte(proof.manifest_hash)},
      %{proof | manifest_tag: flip_last_byte(proof.manifest_tag)},
      put_in(proof, [:recovery, :label], "vault_key"),
      put_in(proof, [:recovery, :binding, :vault_id], @other_vault_id),
      put_in(proof, [:recovery, :binding, :manifest_id], @other_manifest_id),
      put_in(
        proof,
        [:recovery, :wrapper_sha256],
        flip_last_byte(proof.recovery.wrapper_sha256)
      ),
      Map.put(proof, :extra, true)
    ]

    for invalid_proof <- invalid_proofs do
      assert_backup_invalid(BackupKeyLease.claim_recovered_vault_key(lease, invalid_proof))
    end

    foreign_claim =
      Task.async(fn ->
        BackupKeyLease.claim_recovered_vault_key(lease, proof)
      end)

    assert_backup_invalid(Task.await(foreign_claim))

    assert {:ok, capability} =
             BackupKeyLease.claim_recovered_vault_key(lease, proof)

    for invalid_binding <- [
          %{vault_id: @other_vault_id, generation: 2},
          %{vault_id: @vault_id, generation: 0},
          %{vault_id: @vault_id, generation: 2, extra: true}
        ] do
      assert_backup_invalid(RecoveredVaultKey.rewrap(capability, @new_kek, invalid_binding))
    end

    foreign_rewrap =
      Task.async(fn ->
        RecoveredVaultKey.rewrap(capability, @new_kek, %{
          vault_id: @vault_id,
          generation: 2
        })
      end)

    assert_backup_invalid(Task.await(foreign_rewrap))

    assert {:ok, %{generation: 2, purpose: :vault_key}} =
             RecoveredVaultKey.rewrap(capability, @new_kek, %{
               vault_id: @vault_id,
               generation: 2
             })
  end

  test "restore phase rejects export use and capability revocation is owner-bound and idempotent" do
    fixture = encrypted_bundle_fixture()
    lease = start_restore_lease(fixture)

    assert_backup_invalid(
      BackupKeyLease.init_encrypt(lease, %{
        manifest_id: @manifest_id,
        vault_id: @vault_id
      })
    )

    assert {:ok, verified} =
             BundleReader.authenticate_all(fixture.source,
               crypto: {BackupKeyLease.StorageAdapter, lease}
             )

    assert {:ok, capability} =
             BackupKeyLease.claim_recovered_vault_key(
               lease,
               authenticated_proof(verified)
             )

    foreign_revoke = Task.async(fn -> RecoveredVaultKey.revoke(capability) end)
    assert_backup_invalid(Task.await(foreign_revoke))

    assert :ok = RecoveredVaultKey.revoke(capability)
    assert :ok = RecoveredVaultKey.revoke(capability)

    assert {:error, :lease_unavailable} =
             RecoveredVaultKey.rewrap(capability, @new_kek, %{
               vault_id: @vault_id,
               generation: 1
             })

    assert_backup_invalid(
      RecoveredVaultKey.rewrap(:not_a_capability, @new_kek, %{
        vault_id: @vault_id,
        generation: 1
      })
    )

    assert_backup_invalid(RecoveredVaultKey.revoke(:not_a_capability))
  end

  defp start_restore_lease(fixture) do
    assert {:ok, lease} = BackupKeyLease.start_restore_link(restore_options(fixture))
    lease
  end

  defp restore_options(fixture) do
    %{
      active_ttl_ms: 10_000,
      binding: fixture.binding,
      cipher: ChunkedAEAD,
      custodian: self(),
      key_material: @backup_key,
      public_header: fixture.public_header
    }
  end

  defp encrypted_bundle_fixture do
    binding = %{manifest_id: @manifest_id, vault_id: @vault_id}

    assert {:ok, recovery_wrapper} =
             BackupRecoveryWrapper.wrap(@backup_key, @vault_key, %{
               label: :backup_recovery,
               manifest_id: @manifest_id,
               vault_id: @vault_id
             })

    manifest = %{
      version: 1,
      manifest_id: @manifest_id,
      vault_ids: [@vault_id],
      snapshot_id: @snapshot_id,
      outbox_high_water_mark: 42,
      recovery: %{
        "label" => "backup_recovery",
        "binding" => %{
          "manifest_id" => @manifest_id,
          "vault_id" => @vault_id
        },
        "wrapper" => recovery_wrapper
      },
      inventory: [
        %{
          position: 0,
          record_type: 0x1234,
          payload_length: byte_size(@record_payload),
          sha256: :crypto.hash(:sha256, @record_payload)
        }
      ]
    }

    assert {:ok, encoded_manifest} = Manifest.encode(manifest)

    plaintext =
      IO.iodata_to_binary([
        frame(0x1234, @record_payload),
        frame(0xFFFF, encoded_manifest)
      ])

    public_header = %{
      version: 1,
      manifest_id: @manifest_id,
      vault_id: @vault_id,
      kdf: %{
        domain: "singularity.backup.bundle.v1",
        parameters: %{
          "m_cost" => 65_536,
          "parallelism" => 2,
          "t_cost" => 5,
          "version" => 4
        },
        salt: :binary.copy(<<0x75>>, 16)
      }
    }

    export_lease =
      start_supervised!(
        {BackupKeyLease,
         %{
           id: make_ref(),
           binding: binding,
           cipher: ChunkedAEAD,
           custodian: self(),
           key_material: @backup_key,
           public_header: public_header,
           recovery_wrapper: recovery_wrapper
         }}
      )

    assert {:ok, header, encrypt_state} =
             BackupKeyLease.StorageAdapter.init_encrypt(export_lease, public_header)

    assert {:ok, encrypted_records, encrypt_state} =
             BackupKeyLease.StorageAdapter.encrypt_chunk(encrypt_state, plaintext)

    assert {:ok, trailer, _summary, :finalized} =
             BackupKeyLease.StorageAdapter.finalize(encrypt_state, manifest)

    assert :ok = BackupKeyLease.revoke(export_lease)

    encrypted = IO.iodata_to_binary([header, encrypted_records, trailer])
    encoded_header = :erlang.term_to_binary(public_header, [:deterministic])

    encoded_bundle =
      <<"SINGULARITY-BACKUP", 1::unsigned-big-16, byte_size(encoded_header)::unsigned-big-32,
        encoded_header::binary, encrypted::binary>>

    source = %{
      path: "backup://restore-capability",
      file_system: %{
        read: fn "backup://restore-capability", max_bytes ->
          if byte_size(encoded_bundle) <= max_bytes,
            do: {:ok, encoded_bundle},
            else: {:error, :max_bytes_exceeded}
        end
      }
    }

    %{
      binding: binding,
      manifest: manifest,
      public_header: public_header,
      recovery_wrapper: recovery_wrapper,
      source: source
    }
  end

  defp authenticated_proof(verified) do
    recovery = verified.manifest.recovery
    binding = recovery["binding"]

    %{
      vault_id: binding["vault_id"],
      manifest_id: binding["manifest_id"],
      manifest_hash: verified.manifest_hash,
      manifest_tag: verified.manifest_tag,
      recovery: %{
        label: recovery["label"],
        binding: %{
          vault_id: binding["vault_id"],
          manifest_id: binding["manifest_id"]
        },
        wrapper_sha256: :crypto.hash(:sha256, recovery["wrapper"])
      }
    }
  end

  defp frame(type, payload),
    do: <<type::unsigned-big-16, byte_size(payload)::unsigned-big-64, payload::binary>>

  defp flip_last_byte(binary) do
    prefix_size = byte_size(binary) - 1
    <<prefix::binary-size(prefix_size), last>> = binary
    <<prefix::binary, Bitwise.bxor(last, 1)>>
  end

  defp secret_leaked?(value, secrets) do
    binaries = collect_binaries(value)

    Enum.any?(secrets, fn secret ->
      Enum.any?(binaries, fn binary ->
        binary == secret or :binary.match(binary, secret) != :nomatch
      end)
    end)
  end

  defp collect_binaries(value) when is_binary(value), do: [value]

  defp collect_binaries(value) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.flat_map(fn {key, nested} -> collect_binaries(key) ++ collect_binaries(nested) end)
  end

  defp collect_binaries(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.flat_map(&collect_binaries/1)

  defp collect_binaries(value) when is_list(value),
    do: Enum.flat_map(value, &collect_binaries/1)

  defp collect_binaries(_value), do: []

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
