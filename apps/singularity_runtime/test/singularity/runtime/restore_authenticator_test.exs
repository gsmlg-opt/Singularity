defmodule Singularity.Runtime.RestoreAuthenticatorTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Storage.Backup.BundleReader
  alias Singularity.Storage.Crypto.RecoveredVaultKey

  @authenticator Singularity.Runtime.RestoreAuthenticator
  @manifest_id "00000000-0000-4000-8000-000000000741"
  @vault_id "00000000-0000-4000-8000-000000000742"
  @passphrase "CANARY_RESTORE_AUTH_PASSPHRASE_741"
  @backup_key :binary.copy(<<0x74>>, 32)
  @manifest_hash :binary.copy(<<0x75>>, 32)
  @manifest_tag :binary.copy(<<0x76>>, 16)
  @wrapper "authenticated-recovery-wrapper-741"

  defmodule Recorder do
    use Agent

    def start_link(options) do
      Agent.start_link(fn ->
        %{events: [], failure: Keyword.get(options, :failure), handles: []}
      end)
    end

    def record(recorder, event),
      do: Agent.update(recorder, &update_in(&1.events, fn events -> events ++ [event] end))

    def get(recorder), do: Agent.get(recorder, & &1)

    def register_handle(recorder, handle),
      do: Agent.update(recorder, &update_in(&1.handles, fn handles -> [handle | handles] end))
  end

  defmodule Destination do
    alias Singularity.Core.Error

    def reader_source(recorder, destination_ref) do
      Recorder.record(recorder, {:reader_source, destination_ref})

      if Recorder.get(recorder).failure == :source,
        do: {:error, Error.new(:storage_unavailable, retryable?: true)},
        else: {:ok, %{file_system: :opaque_file_system, path: "/opaque/final.bundle"}}
    end
  end

  defmodule Reader do
    alias Singularity.Core.Error
    alias Singularity.Storage.Backup.BundleReader

    def read_public_header(recorder, source) do
      Recorder.record(recorder, {:read_public_header, source})

      case Recorder.get(recorder).failure do
        :header -> {:error, Error.new(:backup_invalid)}
        :malformed_header -> {:ok, %{version: 1, kdf: %{}}}
        _other -> {:ok, public_header()}
      end
    end

    def authenticate_all(recorder, source, options) when is_list(options) do
      {crypto, lease} = Keyword.fetch!(options, :crypto)
      verifier = Keyword.fetch!(options, :verifier)
      Recorder.record(recorder, {:authenticate_all, source, crypto, lease, verifier})

      if Recorder.get(recorder).failure in [:authentication, :logical_verification] do
        {:error, Error.new(:backup_invalid)}
      else
        binding = %{
          destination_ref: "backups/vault.bundle",
          manifest_id: "00000000-0000-4000-8000-000000000741",
          recovery: manifest().recovery,
          vault_id: "00000000-0000-4000-8000-000000000742"
        }

        verified =
          %BundleReader.Verified{
            authentication: %{proof: proof()},
            cut: cut(binding),
            manifest: manifest(),
            records: [],
            manifest_hash: :binary.copy(<<0x75>>, 32),
            manifest_tag: :binary.copy(<<0x76>>, 16)
          }

        if Recorder.get(recorder).failure == :post_reader_validation do
          {:ok, handle} = Agent.start_link(fn -> :open_snapshot end)
          Recorder.register_handle(recorder, handle)
          {:ok, %{verified | cut: %{verified.cut | manifest_id: Ecto.UUID.generate()}}}
        else
          {:ok, verified}
        end
      end
    end

    def discard_verified(recorder, _verified) do
      Enum.each(Recorder.get(recorder).handles, fn handle ->
        if Process.alive?(handle), do: Agent.stop(handle)
      end)

      Recorder.record(recorder, :discard_verified)
      :ok
    end

    def cut(binding) do
      %{
        database_snapshot: "42:42:",
        manifest_id: binding.manifest_id,
        object_inventory: [],
        outbox_high_water_mark: 42,
        snapshot_id: "00000000-0000-4000-8000-000000000743",
        vault_id: binding.vault_id
      }
    end

    def proof do
      %{
        manifest_hash: :binary.copy(<<0x75>>, 32),
        manifest_id: "00000000-0000-4000-8000-000000000741",
        manifest_tag: :binary.copy(<<0x76>>, 16),
        recovery: %{
          binding: %{
            manifest_id: "00000000-0000-4000-8000-000000000741",
            vault_id: "00000000-0000-4000-8000-000000000742"
          },
          label: "backup_recovery",
          wrapper_sha256: :crypto.hash(:sha256, "authenticated-recovery-wrapper-741")
        },
        vault_id: "00000000-0000-4000-8000-000000000742"
      }
    end

    def public_header do
      %{
        version: 1,
        manifest_id: "00000000-0000-4000-8000-000000000741",
        vault_id: "00000000-0000-4000-8000-000000000742",
        kdf: %{
          "domain" => "singularity.backup.bundle.v1",
          "parameters" => %{
            "m_cost" => 65_536,
            "parallelism" => 2,
            "t_cost" => 5,
            "version" => 4
          },
          "salt" => Base.encode64(:binary.copy(<<0x73>>, 16))
        }
      }
    end

    def manifest do
      %{
        version: 1,
        manifest_id: "00000000-0000-4000-8000-000000000741",
        vault_ids: ["00000000-0000-4000-8000-000000000742"],
        snapshot_id: "00000000-0000-4000-8000-000000000743",
        outbox_high_water_mark: 42,
        recovery: %{
          "binding" => %{
            "manifest_id" => "00000000-0000-4000-8000-000000000741",
            "vault_id" => "00000000-0000-4000-8000-000000000742"
          },
          "label" => "backup_recovery",
          "wrapper" => "authenticated-recovery-wrapper-741"
        },
        inventory: []
      }
    end
  end

  defmodule Deriver do
    alias Singularity.Core.Error

    def derive(recorder, passphrase, kdf) do
      Recorder.record(
        recorder,
        {:derive, :crypto.hash(:sha256, passphrase), kdf}
      )

      if passphrase == "CANARY_RESTORE_AUTH_PASSPHRASE_741" do
        {:ok, :binary.copy(<<0x74>>, 32)}
      else
        {:error, Error.new(:backup_invalid)}
      end
    end
  end

  defmodule Lease do
    alias Singularity.Core.Error
    alias Singularity.Storage.Crypto.RecoveredVaultKey

    def start_restore_link(recorder, options) do
      Recorder.record(recorder, {
        :start_restore_link,
        Map.drop(options, [:key_material]),
        :crypto.hash(:sha256, options.key_material)
      })

      if Recorder.get(recorder).failure == :lease_start do
        {:error, :lease_unavailable}
      else
        Agent.start_link(fn -> :restore_lease end)
      end
    end

    def claim_recovered_vault_key(recorder, lease, proof) do
      Recorder.record(recorder, {:claim_recovered_vault_key, lease, proof})

      case Recorder.get(recorder).failure do
        :claim -> {:error, Error.new(:backup_invalid)}
        :raw_claim -> {:ok, :binary.copy(<<0x77>>, 32)}
        _other -> {:ok, RecoveredVaultKey.issue(self(), make_ref())}
      end
    end

    def revoke(recorder, lease) do
      Recorder.record(recorder, {:revoke_lease, lease})

      if is_pid(lease) and Process.alive?(lease), do: Agent.stop(lease)
      :ok
    end
  end

  defmodule Verifier do
    alias Singularity.Core.Error
    alias Singularity.Storage.Backup.BundleReader

    def verify(recorder, %BundleReader.Verified{} = verified, binding) do
      Recorder.record(recorder, {:verify_logical_bundle, verified, binding})

      if Recorder.get(recorder).failure == :logical_verification do
        {:error, Error.new(:backup_invalid)}
      else
        {:ok,
         %{
           database_snapshot: "42:42:",
           manifest_id: binding.manifest_id,
           object_inventory: [],
           outbox_high_water_mark: 42,
           snapshot_id: "00000000-0000-4000-8000-000000000743",
           vault_id: binding.vault_id
         }}
      end
    end
  end

  defmodule RecoveredKey do
    def revoke(recorder, capability) do
      Recorder.record(recorder, {:revoke_recovered_vault_key, capability})
      :ok
    end
  end

  defmodule Crypto do
    def decrypt_all(_lease, _public_header, _bundle), do: {:error, :not_used}
  end

  setup do
    recorder = start_supervised!({Recorder, []})
    {:ok, context: context(recorder), recorder: recorder}
  end

  test "authenticates the full bundle and logical cut but delays the recovered key until replay",
       context do
    assert {:ok, authenticated} =
             apply(@authenticator, :authenticate_all, [
               context.context,
               "backups/vault.bundle",
               @passphrase
             ])

    assert authenticated.binding == %{
             destination_ref: "backups/vault.bundle",
             manifest_id: @manifest_id,
             recovery: Reader.manifest().recovery,
             vault_id: @vault_id
           }

    assert authenticated.cut.manifest_id == @manifest_id
    assert authenticated.verified.manifest.manifest_id == @manifest_id
    assert is_pid(authenticated.lease)
    refute Map.has_key?(authenticated, :recovered_vault_key)
    refute inspect(authenticated) =~ @wrapper
    refute inspect(authenticated) =~ Base.encode16(@backup_key)
    lease = authenticated.lease

    assert [
             {:reader_source, "backups/vault.bundle"},
             {:read_public_header, source},
             {:derive, _passphrase_hash, kdf},
             {:start_restore_link, lease_options, _key_hash},
             {:authenticate_all, source, Crypto, ^lease, {{Verifier, recorder}, binding}}
           ] = Recorder.get(context.recorder).events

    assert recorder == context.recorder

    assert kdf == %{
             domain: "singularity.backup.bundle.v1",
             parameters: Reader.public_header().kdf["parameters"],
             salt: :binary.copy(<<0x73>>, 16)
           }

    assert lease_options == %{
             active_ttl_ms: 30_000,
             binding: %{manifest_id: @manifest_id, vault_id: @vault_id},
             cipher: :test_cipher,
             custodian: self(),
             public_header: Reader.public_header()
           }

    assert binding == Map.drop(authenticated.binding, [:recovery])

    refute Enum.any?(
             Recorder.get(context.recorder).events,
             &match?({:claim_recovered_vault_key, _, _}, &1)
           )

    assert {:ok, %RecoveredVaultKey{} = recovered_vault_key} =
             apply(@authenticator, :claim_recovered_vault_key, [
               context.context,
               authenticated
             ])

    assert {:claim_recovered_vault_key, ^lease, proof} =
             List.last(Recorder.get(context.recorder).events)

    assert proof == %{
             manifest_hash: @manifest_hash,
             manifest_id: @manifest_id,
             manifest_tag: @manifest_tag,
             recovery: %{
               binding: %{manifest_id: @manifest_id, vault_id: @vault_id},
               label: "backup_recovery",
               wrapper_sha256: :crypto.hash(:sha256, @wrapper)
             },
             vault_id: @vault_id
           }

    assert :ok = apply(@authenticator, :revoke, [context.context, authenticated])

    assert Enum.take(Recorder.get(context.recorder).events, -2) == [
             :discard_verified,
             {:revoke_lease, authenticated.lease}
           ]

    assert %RecoveredVaultKey{} = recovered_vault_key
  end

  test "all failures after lease creation synchronously revoke the restore lease" do
    for failure <- [:authentication, :logical_verification] do
      recorder = start_supervised!({Recorder, failure: failure}, id: make_ref())

      assert {:error, %Error{code: :backup_invalid}} =
               apply(@authenticator, :authenticate_all, [
                 context(recorder),
                 "backups/vault.bundle",
                 @passphrase
               ])

      assert {:revoke_lease, lease} = List.last(Recorder.get(recorder).events)
      refute Process.alive?(lease)
    end
  end

  test "post-reader validation failure closes the verified snapshot exactly once" do
    recorder = start_supervised!({Recorder, failure: :post_reader_validation}, id: make_ref())

    assert {:error, %Error{code: :backup_invalid}} =
             apply(@authenticator, :authenticate_all, [
               context(recorder),
               "backups/vault.bundle",
               @passphrase
             ])

    state = Recorder.get(recorder)
    assert [handle] = state.handles
    refute Process.alive?(handle)
    assert Enum.count(state.events, &(&1 == :discard_verified)) == 1
    assert {:revoke_lease, lease} = List.last(state.events)
    refute Process.alive?(lease)
  end

  test "claim failures occur only after authentication and remain revocable" do
    for failure <- [:claim, :raw_claim] do
      recorder = start_supervised!({Recorder, failure: failure}, id: make_ref())
      restore_context = context(recorder)

      assert {:ok, authenticated} =
               apply(@authenticator, :authenticate_all, [
                 restore_context,
                 "backups/vault.bundle",
                 @passphrase
               ])

      assert {:error, %Error{code: :backup_invalid}} =
               apply(@authenticator, :claim_recovered_vault_key, [
                 restore_context,
                 authenticated
               ])

      assert :ok = apply(@authenticator, :revoke, [restore_context, authenticated])
      refute Process.alive?(authenticated.lease)
    end
  end

  test "invalid public KDF metadata and wrong passphrases never create a lease" do
    for {failure, passphrase} <- [
          {:malformed_header, @passphrase},
          {nil, "wrong-passphrase"}
        ] do
      recorder = start_supervised!({Recorder, failure: failure}, id: make_ref())

      assert {:error, %Error{code: :backup_invalid}} =
               apply(@authenticator, :authenticate_all, [
                 context(recorder),
                 "backups/vault.bundle",
                 passphrase
               ])

      refute Enum.any?(Recorder.get(recorder).events, &match?({:start_restore_link, _, _}, &1))
    end
  end

  test "storage failures remain retryable and do not expose the passphrase" do
    recorder = start_supervised!({Recorder, failure: :source}, id: make_ref())

    assert {:error, %Error{code: :storage_unavailable, retryable?: true} = error} =
             apply(@authenticator, :authenticate_all, [
               context(recorder),
               "backups/vault.bundle",
               @passphrase
             ])

    refute inspect([error, Recorder.get(recorder)]) =~ @passphrase
  end

  defp context(recorder) do
    %{
      backup_cipher: :test_cipher,
      backup_key_deriver: {Deriver, recorder},
      backup_key_lease: {Lease, recorder},
      bundle_reader: {Reader, recorder},
      destination: {Destination, recorder},
      logical_verifier: {Verifier, recorder},
      recovered_vault_key: {RecoveredKey, recorder},
      restore_crypto_adapter: Crypto,
      restore_key_ttl_ms: 30_000
    }
  end
end
