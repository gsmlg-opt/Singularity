defmodule Singularity.Runtime.BackupKeyLeaseTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Singularity.Core.Error
  alias Singularity.Runtime.KeyCustodian
  alias Singularity.Runtime.KeyLeaseSupervisor
  alias Singularity.Storage.Backup.Manifest
  alias Singularity.Storage.Crypto.BackupRecoveryWrapper
  alias Singularity.Storage.Crypto.ChunkedAEAD
  alias Singularity.Storage.Crypto.Format
  alias Singularity.Storage.Crypto.RecoveredVaultKey

  @backup_key_lease Singularity.Runtime.BackupKeyLease
  @storage_adapter Singularity.Runtime.BackupKeyLease.StorageAdapter
  @manifest_id "00000000-0000-4000-8000-000000000701"
  @vault_id "00000000-0000-4000-8000-000000000702"
  @session_id "00000000-0000-4000-8000-000000000703"
  @principal_id "00000000-0000-4000-8000-000000000704"
  @passphrase "CANARY_BACKUP_PASSPHRASE_701"
  @wrong_passphrase "CANARY_WRONG_BACKUP_PASSPHRASE_701"
  @derived_key :binary.copy(<<0xA7>>, 32)
  @vault_key :binary.copy(<<0xB7>>, 32)
  @passphrase_hash :crypto.hash(:sha256, @passphrase)
  @derived_key_hash :crypto.hash(:sha256, @derived_key)
  @vault_key_hash :crypto.hash(:sha256, @vault_key)
  @salt :binary.copy(<<0xC7>>, 16)
  @encoded_salt Base.encode64(@salt)
  @backup_domain "singularity.backup.bundle.v1"
  @backup_encryption_domain_id "9c22b7fa-ff48-4ee2-a49a-d23464393618"
  @max_encrypted_bundle_bytes 4_294_967_296
  @backup_parameters %{
    "m_cost" => 65_536,
    "parallelism" => 2,
    "t_cost" => 5,
    "version" => 4
  }

  defmodule Recorder do
    use Agent

    def start_link(options) do
      owner = Keyword.fetch!(options, :owner)

      Agent.start_link(fn -> %{events: [], owner: owner, pause_next_decrypt?: false} end)
    end

    def record(recorder, event) do
      Agent.update(recorder, &Map.update!(&1, :events, fn events -> [event | events] end))
    end

    def events(recorder), do: Agent.get(recorder, &Enum.reverse(&1.events))

    def pause_next_decrypt(recorder) do
      Agent.update(recorder, &Map.put(&1, :pause_next_decrypt?, true))
    end

    def before_decrypt(recorder, index) do
      case Agent.get_and_update(recorder, fn state ->
             if state.pause_next_decrypt? do
               {{:pause, state.owner}, %{state | pause_next_decrypt?: false}}
             else
               {:continue, state}
             end
           end) do
        {:pause, owner} ->
          token = make_ref()
          send(owner, {:backup_cipher_decrypt_paused, self(), token, index})

          receive do
            {:release_backup_cipher_decrypt, ^token} -> :ok
          end

        :continue ->
          :ok
      end
    end

    def release_decrypt(worker, token),
      do: send(worker, {:release_backup_cipher_decrypt, token})
  end

  defmodule Clock do
    def utc_now(_context), do: DateTime.utc_now()
  end

  defmodule Callbacks do
    def idle_lock(_recorder, _session), do: :ok
    def wake_waiting(_recorder, _command), do: :ok
  end

  defmodule UnusedReader do
    def load_object_key(_context, _binding, _hierarchy), do: {:error, :not_used}
    def load_checkpoint(_context, _binding), do: {:error, :not_used}
  end

  defmodule Deriver do
    def derive(recorder, passphrase, %{domain: domain, parameters: parameters, salt: salt}) do
      Recorder.record(
        recorder,
        {:derive, :crypto.hash(:sha256, passphrase), domain, parameters, salt}
      )

      key =
        if passphrase == "CANARY_BACKUP_PASSPHRASE_701" and
             domain == "singularity.backup.bundle.v1" and
             parameters == %{
               "m_cost" => 65_536,
               "parallelism" => 2,
               "t_cost" => 5,
               "version" => 4
             } and salt == :binary.copy(<<0xC7>>, 16),
           do: :binary.copy(<<0xA7>>, 32),
           else: :binary.copy(<<0xE7>>, 32)

      {:ok, key}
    end
  end

  defmodule Wrapper do
    def wrap(recorder, wrapping_key, raw_key, metadata) do
      Recorder.record(
        recorder,
        {:wrap, :crypto.hash(:sha256, wrapping_key), :crypto.hash(:sha256, raw_key), metadata}
      )

      {:ok, "authenticated-recovery-wrapper"}
    end

    def unwrap(
          recorder,
          wrapping_key,
          "authenticated-recovery-wrapper",
          %{
            label: :backup_recovery,
            manifest_id: "00000000-0000-4000-8000-000000000701",
            vault_id: "00000000-0000-4000-8000-000000000702"
          } = metadata
        ) do
      Recorder.record(recorder, {:unwrap, :crypto.hash(:sha256, wrapping_key), metadata})

      if wrapping_key == :binary.copy(<<0xA7>>, 32) do
        {:ok, :binary.copy(<<0xB7>>, 32)}
      else
        {:error, Error.new(:backup_invalid)}
      end
    end

    def unwrap(recorder, wrapping_key, _wrapper, metadata) do
      Recorder.record(recorder, {:unwrap, :crypto.hash(:sha256, wrapping_key), metadata})
      {:error, Error.new(:backup_invalid)}
    end
  end

  defmodule BackupKeyObserver do
    def pending_prepared(recorder, opaque_ref) do
      Recorder.record(recorder, {:backup_custody_prepared, opaque_ref})
    end
  end

  setup do
    recorder = start_supervised!({Recorder, owner: self()})

    lease_supervisor =
      start_supervised!({KeyLeaseSupervisor, name: nil}, id: make_ref())

    custodian = start_custodian(recorder, lease_supervisor)
    assert :ok = unlock(custodian)

    {:ok,
     custodian: custodian,
     lease_supervisor: lease_supervisor,
     recorder: recorder,
     runtime: runtime(custodian, recorder)}
  end

  test "uses an independent backup KDF domain and the backup-recovery wrapper label", context do
    result_ref = make_ref()
    log = capture_log(fn -> send(self(), {result_ref, prepare(context.runtime)}) end)
    assert_receive {^result_ref, {:ok, prepared}}

    refute secret_leaked?([prepared, log], [@passphrase, @derived_key, @vault_key])

    assert prepared.public_metadata == %{
             "kdf" => %{
               "domain" => @backup_domain,
               "parameters" => @backup_parameters,
               "salt" => @encoded_salt
             },
             "recovery" => %{
               "binding" => %{
                 "manifest_id" => @manifest_id,
                 "vault_id" => @vault_id
               },
               "label" => "backup_recovery",
               "wrapper" => "authenticated-recovery-wrapper"
             }
           }

    persisted_parameters = get_in(prepared.public_metadata, ["kdf", "parameters"])
    refute persisted_parameters == context.runtime.account_kdf_parameters
    refute persisted_parameters == context.runtime.vault_kdf_parameters
    assert is_binary(prepared.opaque_ref)

    assert [
             {:derive, @passphrase_hash, @backup_domain, @backup_parameters, @salt},
             {:wrap, @derived_key_hash, @vault_key_hash, wrapper_binding},
             {:backup_custody_prepared, opaque_ref}
           ] = Recorder.events(context.recorder)

    assert opaque_ref == prepared.opaque_ref

    assert wrapper_binding == %{
             label: :backup_recovery,
             manifest_id: @manifest_id,
             vault_id: @vault_id
           }
  end

  test "returns only an opaque redacted reference and never returns key material", context do
    assert {:ok, prepared} = prepare(context.runtime)

    rendered = inspect(prepared)
    assert rendered =~ "REDACTED"

    refute secret_leaked?(
             [prepared.opaque_ref, prepared.public_metadata, rendered],
             [@passphrase, @derived_key, @vault_key]
           )
  end

  test "pending custody is inert until activation and crypto is one shot and exactly bound",
       context do
    assert {:ok, prepared} = prepare(context.runtime)

    assert {:error, :waiting_for_backup_key} =
             api(:init_encrypt, [prepared.opaque_ref, lease_binding()])

    assert :ok = activate(context.custodian, prepared.opaque_ref)
    assert {:ok, lease} = active_lease(context.custodian, prepared.opaque_ref)

    assert {:error, %Error{code: :backup_invalid}} =
             api(:init_encrypt, [lease, lease_binding(vault_id: "other-vault")])

    assert {:error, %Error{code: :backup_invalid}} =
             api(:init_encrypt, [lease, lease_binding(manifest_id: "other-manifest")])

    assert {:ok, header} = api(:init_encrypt, [lease, lease_binding()])
    assert {:ok, encrypted} = api(:encrypt_chunk, [lease, 0, "framed record"])
    assert {:ok, trailer} = api(:finalize, [lease, authenticated_manifest()])

    assert cipher_key_used?(context.recorder, :cipher_init_encrypt, @derived_key_hash)
    refute cipher_key_used?(context.recorder, :cipher_init_encrypt, @vault_key_hash)

    refute secret_leaked?({header, encrypted, trailer}, [@derived_key, @vault_key])

    assert {:error, %Error{code: :conflict}} =
             api(:init_encrypt, [lease, lease_binding()])
  end

  test "custodian synchronously revokes an active backup capability", context do
    assert {:ok, prepared} = prepare(context.runtime)
    assert :ok = activate(context.custodian, prepared.opaque_ref)
    assert {:ok, lease} = active_lease(context.custodian, prepared.opaque_ref)
    assert Process.alive?(lease)

    assert :ok =
             call(KeyCustodian, :revoke_backup_key, [
               context.custodian,
               prepared.opaque_ref
             ])

    refute Process.alive?(lease)

    assert backup_key_state(context.custodian) == %{
             active_refs: [],
             pending_refs: []
           }

    assert {:error, :lease_missing} = backup_crypto(context.custodian, prepared.opaque_ref)
  end

  test "storage adapter streams through the opaque one-shot lease contract", context do
    assert {:ok, prepared} = prepare(context.runtime)
    assert :ok = activate(context.custodian, prepared.opaque_ref)

    assert {:ok,
            %{
              adapter: @storage_adapter,
              capability: encryptor,
              public_header: public_header
            } = crypto} = backup_crypto(context.custodian, prepared.opaque_ref)

    assert is_pid(encryptor)
    assert public_header == expected_public_header()

    tampered_header =
      put_in(public_header, [:kdf, "domain"], "singularity.account.password.v1")

    assert {:error, %Error{code: :backup_invalid}} =
             call(@storage_adapter, :init_encrypt, [encryptor, tampered_header])

    assert {:ok, encoded_header, encryption_state} =
             call(@storage_adapter, :init_encrypt, [encryptor, public_header])

    assert <<"SGKC", 1, 1, _rest::binary>> = encoded_header

    assert encryption_state
           |> Map.from_struct()
           |> Map.keys()
           |> Enum.sort() == [:capability, :public_header, :sequence]

    assert encryption_state.capability == encryptor
    assert encryption_state.public_header == public_header
    assert encryption_state.sequence == 0

    assert %{
             phase:
               {:storage_encrypting, %ChunkedAEAD.EncryptState{} = cipher_state, 0, encoded_bytes,
                0}
           } = :sys.get_state(encryptor)

    assert encoded_bytes == Format.header_size()

    assert Map.take(cipher_state.context, [
             :vault_id,
             :encryption_domain_id,
             :object_id,
             :chunk_index
           ]) == %{
             vault_id: @vault_id,
             encryption_domain_id: @backup_encryption_domain_id,
             object_id: @manifest_id,
             chunk_index: 0
           }

    plaintext =
      <<0xBEEF::unsigned-big-16, byte_size("framed record")::unsigned-big-64, "framed record">>

    assert {:ok, encoded_record, encryption_state} =
             call(@storage_adapter, :encrypt_chunk, [encryption_state, plaintext])

    manifest = authenticated_manifest()
    assert {:ok, encoded_manifest} = Manifest.encode(manifest)

    manifest_frame =
      <<0xFFFF::unsigned-big-16, byte_size(encoded_manifest)::unsigned-big-64,
        encoded_manifest::binary>>

    assert {:ok, encoded_manifest_record, encryption_state} =
             call(@storage_adapter, :encrypt_chunk, [encryption_state, manifest_frame])

    assert {:ok, encoded_trailer, summary, :finalized} =
             call(@storage_adapter, :finalize, [encryption_state, manifest])

    assert <<_::binary-size(byte_size(encoded_trailer) - 16), manifest_tag::binary-size(16)>> =
             encoded_trailer

    authenticated_plaintext = plaintext <> manifest_frame

    assert summary == %{
             chunk_count: 1,
             plaintext_bytes: byte_size(authenticated_plaintext),
             plaintext_sha256: :crypto.hash(:sha256, authenticated_plaintext),
             manifest_hash: :crypto.hash(:sha256, encoded_manifest),
             manifest_tag: manifest_tag
           }

    assert is_binary(encoded_header) and encoded_header != ""
    assert is_binary(encoded_record)
    assert is_binary(encoded_trailer) and encoded_trailer != ""

    refute binary_contains?(encoded_trailer, encoded_manifest)

    encoded_bundle =
      IO.iodata_to_binary([
        encoded_header,
        encoded_record,
        encoded_manifest_record,
        encoded_trailer
      ])

    refute binary_contains?(encoded_bundle, "SINGULARITY-BACKUP-CRYPTO")

    assert {:ok, ^encoded_header, _records, parsed_header} =
             Format.split_header(encoded_bundle)

    assert parsed_header.vault_id == Ecto.UUID.dump!(@vault_id)
    assert parsed_header.encryption_domain_id == Ecto.UUID.dump!(@backup_encryption_domain_id)
    assert parsed_header.object_id == Ecto.UUID.dump!(@manifest_id)

    refute secret_leaked?(
             [crypto, encryption_state, encoded_bundle, summary],
             [@passphrase, @derived_key, @vault_key]
           )

    persisted = %{
      "backup_key_lease_id" => prepared.opaque_ref,
      "manifest" => manifest,
      "public_metadata" => prepared.public_metadata,
      "vault_id" => @vault_id
    }

    assert {:ok, reentered} = api(:reenter, [context.runtime, persisted, @passphrase])
    assert :ok = activate(context.custodian, reentered.opaque_ref)

    assert {:ok,
            %{
              adapter: @storage_adapter,
              capability: decryptor,
              public_header: ^public_header
            }} = backup_crypto(context.custodian, reentered.opaque_ref)

    assert is_pid(decryptor)
    refute decryptor == encryptor

    assert {:ok, ^authenticated_plaintext,
            %{manifest_hash: expected_manifest_hash, manifest_tag: ^manifest_tag}} =
             call(@storage_adapter, :decrypt_all, [decryptor, public_header, encoded_bundle])

    assert expected_manifest_hash == :crypto.hash(:sha256, encoded_manifest)

    assert {:error, %Error{code: :conflict}} =
             api(:decrypt, [decryptor, 1, "post-storage-decrypt probe"])

    decryptor_state = :sys.get_state(decryptor)
    assert decryptor_state.phase == :consumed

    refute secret_leaked?(
             decryptor_state,
             [@derived_key, @vault_key]
           )

    assert {:error, %Error{code: :conflict}} =
             call(@storage_adapter, :decrypt_all, [decryptor, public_header, encoded_bundle])
  end

  test "raw SGKC authentication failure releases no plaintext and consumes the lease", context do
    assert {:ok, prepared} = prepare(context.runtime)
    assert :ok = activate(context.custodian, prepared.opaque_ref)

    assert {:ok, %{capability: encryptor, public_header: public_header}} =
             backup_crypto(context.custodian, prepared.opaque_ref)

    assert {:ok, encoded_header, encryption_state} =
             call(@storage_adapter, :init_encrypt, [encryptor, public_header])

    assert {:ok, encoded_record, encryption_state} =
             call(@storage_adapter, :encrypt_chunk, [
               encryption_state,
               "authenticated plaintext must not escape"
             ])

    manifest = authenticated_manifest()

    assert {:ok, encoded_trailer, _summary, :finalized} =
             call(@storage_adapter, :finalize, [encryption_state, manifest])

    encoded_bundle = IO.iodata_to_binary([encoded_header, encoded_record, encoded_trailer])
    assert <<"SGKC", _rest::binary>> = encoded_bundle
    tampered_bundle = flip_byte(encoded_bundle, 66 + 8)

    assert :ok = api(:revoke, [encryptor])

    assert_eventually(fn ->
      prepared.opaque_ref not in backup_key_state(context.custodian).active_refs
    end)

    persisted = %{
      "backup_key_lease_id" => prepared.opaque_ref,
      "manifest" => manifest,
      "public_metadata" => prepared.public_metadata,
      "vault_id" => @vault_id
    }

    assert {:ok, reentered} = api(:reenter, [context.runtime, persisted, @passphrase])
    assert :ok = activate(context.custodian, reentered.opaque_ref)
    assert {:ok, decryptor} = active_lease(context.custodian, reentered.opaque_ref)

    assert {:error, %Error{code: :backup_invalid}} =
             call(@storage_adapter, :decrypt_all, [decryptor, public_header, tampered_bundle])

    assert :sys.get_state(decryptor).phase == :consumed

    refute secret_leaked?(
             :sys.get_state(decryptor),
             [@passphrase, @derived_key, @vault_key, "authenticated plaintext must not escape"]
           )
  end

  test "oversized structural cipher metadata is rejected", context do
    assert :ok = stop_supervised(KeyCustodian)

    custodian =
      start_custodian(
        context.recorder,
        context.lease_supervisor,
        {__MODULE__.OversizedHeaderCipher, context.recorder}
      )

    assert :ok = unlock(custodian)
    assert {:ok, prepared} = prepare(runtime(custodian, context.recorder))
    assert :ok = activate(custodian, prepared.opaque_ref)

    assert {:ok, %{capability: lease, public_header: public_header}} =
             backup_crypto(custodian, prepared.opaque_ref)

    assert {:error, %Error{code: :backup_invalid}} =
             call(@storage_adapter, :init_encrypt, [lease, public_header])

    assert :sys.get_state(lease).phase == :consumed
  end

  test "storage encryption consumes output beyond the SGKC byte and record caps", context do
    assert :ok = stop_supervised(KeyCustodian)

    custodian =
      start_custodian(
        context.recorder,
        context.lease_supervisor,
        {__MODULE__.LimitCipher, context.recorder}
      )

    for {encoded_bytes, record_count, counter} <- [
          {@max_encrypted_bundle_bytes - 1, 0, 0},
          {Format.header_size(), 1_024, 1_024}
        ] do
      assert :ok = unlock(custodian)
      assert {:ok, prepared} = prepare(runtime(custodian, context.recorder))
      assert :ok = activate(custodian, prepared.opaque_ref)

      assert {:ok, %{capability: lease, public_header: public_header}} =
               backup_crypto(custodian, prepared.opaque_ref)

      assert {:ok, _header, encryption_state} =
               call(@storage_adapter, :init_encrypt, [lease, public_header])

      :sys.replace_state(lease, fn state ->
        {:storage_encrypting, cipher_state, 0, _bytes, _records} = state.phase

        %{
          state
          | phase: {:storage_encrypting, cipher_state, 0, encoded_bytes, record_count}
        }
      end)

      assert {:error, %Error{code: :backup_invalid}} =
               call(@storage_adapter, :encrypt_chunk, [
                 encryption_state,
                 <<counter::unsigned-big-32>>
               ])

      assert :sys.get_state(lease).phase == :consumed
    end
  end

  test "storage adapter consumes an authenticated manifest-only bundle atomically", context do
    assert {:ok, prepared} = prepare(context.runtime)
    assert :ok = activate(context.custodian, prepared.opaque_ref)

    assert {:ok, %{capability: encryptor, public_header: public_header}} =
             backup_crypto(context.custodian, prepared.opaque_ref)

    assert {:ok, encoded_header, encryption_state} =
             call(@storage_adapter, :init_encrypt, [encryptor, public_header])

    manifest = %{authenticated_manifest() | inventory: []}
    assert {:ok, encoded_manifest} = Manifest.encode(manifest)

    manifest_frame =
      <<0xFFFF::unsigned-big-16, byte_size(encoded_manifest)::unsigned-big-64,
        encoded_manifest::binary>>

    assert {:ok, encoded_manifest_record, encryption_state} =
             call(@storage_adapter, :encrypt_chunk, [encryption_state, manifest_frame])

    assert {:ok, encoded_trailer, zero_summary, :finalized} =
             call(@storage_adapter, :finalize, [encryption_state, manifest])

    manifest_tag = binary_part(encoded_trailer, byte_size(encoded_trailer) - 16, 16)

    assert zero_summary == %{
             chunk_count: 1,
             plaintext_bytes: byte_size(manifest_frame),
             plaintext_sha256: :crypto.hash(:sha256, manifest_frame),
             manifest_hash: :crypto.hash(:sha256, encoded_manifest),
             manifest_tag: manifest_tag
           }

    persisted = %{
      "backup_key_lease_id" => prepared.opaque_ref,
      "manifest" => manifest,
      "public_metadata" => prepared.public_metadata,
      "vault_id" => @vault_id
    }

    assert {:ok, reentered} = api(:reenter, [context.runtime, persisted, @passphrase])
    assert :ok = activate(context.custodian, reentered.opaque_ref)
    assert {:ok, decryptor} = active_lease(context.custodian, reentered.opaque_ref)

    encoded_bundle = encoded_header <> encoded_manifest_record <> encoded_trailer

    assert {:ok, ^manifest_frame,
            %{
              manifest_hash: expected_manifest_hash,
              manifest_tag: ^manifest_tag
            }} =
             call(@storage_adapter, :decrypt_all, [decryptor, public_header, encoded_bundle])

    assert expected_manifest_hash == :crypto.hash(:sha256, encoded_manifest)

    decryptor_state = :sys.get_state(decryptor)
    assert decryptor_state.phase == :consumed
    refute secret_leaked?(decryptor_state, [@derived_key, @vault_key])
  end

  test "bounded restore decrypts one record at a time and requires an exact replay before claim",
       context do
    recovery_binding = %{
      label: :backup_recovery,
      manifest_id: @manifest_id,
      vault_id: @vault_id
    }

    assert {:ok, recovery_wrapper} =
             BackupRecoveryWrapper.wrap(@derived_key, @vault_key, recovery_binding)

    manifest = put_in(authenticated_manifest(), [:recovery, "wrapper"], recovery_wrapper)
    assert {:ok, encoded_manifest} = Manifest.encode(manifest)

    logical_record =
      <<0xBEEF::unsigned-big-16, byte_size("framed record")::unsigned-big-64, "framed record">>

    manifest_record =
      <<0xFFFF::unsigned-big-16, byte_size(encoded_manifest)::unsigned-big-64,
        encoded_manifest::binary>>

    plaintext = logical_record <> manifest_record

    assert {:ok, encoded_bundle} =
             ChunkedAEAD.encode(%{
               algorithm: :aes_256_gcm,
               chunk_index: 0,
               chunk_size: Format.chunk_size(),
               encryption_domain_id: @backup_encryption_domain_id,
               format_version: 1,
               key: @derived_key,
               object_id: @manifest_id,
               plaintext: plaintext,
               vault_id: @vault_id
             })

    assert {:ok, crypto_header, records, _parsed} = Format.split_header(encoded_bundle)

    assert <<0::unsigned-big-32, record_size::unsigned-big-32,
             _ciphertext::binary-size(record_size), _tag::binary-size(16),
             final_record::binary-size(68)>> = records

    data_record_size = 8 + record_size + 16
    <<data_record::binary-size(data_record_size), ^final_record::binary>> = records
    assert {:ok, manifest_tag} = ChunkedAEAD.final_tag(final_record)

    encrypted_record_sizes =
      <<0::unsigned-big-32, record_size::unsigned-big-64, 0xFFFFFFFF::unsigned-big-32,
        44::unsigned-big-64>>

    encrypted_records =
      <<0::unsigned-big-32, record_size::unsigned-big-64,
        :crypto.hash(:sha256, data_record)::binary-size(32), 0xFFFFFFFF::unsigned-big-32,
        44::unsigned-big-64, :crypto.hash(:sha256, final_record)::binary-size(32)>>

    evidence = %{
      encoded_manifest: encoded_manifest,
      encrypted_record_sizes_sha256: :crypto.hash(:sha256, encrypted_record_sizes),
      encrypted_records_sha256: :crypto.hash(:sha256, encrypted_records),
      frame_count: 1,
      frame_digest: :crypto.hash(:sha256, "one logical frame"),
      manifest_hash: :crypto.hash(:sha256, encoded_manifest),
      manifest_tag: manifest_tag,
      source_sha256: :crypto.hash(:sha256, "bounded source fixture")
    }

    assert {:ok, lease} =
             @backup_key_lease.start_restore_link(%{
               active_ttl_ms: 1_000,
               binding: lease_binding(),
               cipher: ChunkedAEAD,
               custodian: self(),
               key_material: @derived_key,
               public_header: expected_public_header()
             })

    Process.unlink(lease)

    assert Format.header_size() == @storage_adapter.header_size()

    assert {:ok, decrypt_state} =
             @storage_adapter.init_decrypt(lease, expected_public_header(), crypto_header)

    assert {:ok, ^plaintext, decrypt_state} =
             @storage_adapter.decrypt_record(decrypt_state, data_record)

    refute secret_leaked?(:sys.get_state(lease), [plaintext])

    assert {:ok, authenticated, replay} =
             @storage_adapter.finalize_decrypt(decrypt_state, final_record, evidence)

    assert authenticated.plaintext_sha256 == :crypto.hash(:sha256, plaintext)

    assert authenticated.encrypted_record_sizes_sha256 ==
             evidence.encrypted_record_sizes_sha256

    assert authenticated.encrypted_records_sha256 == evidence.encrypted_records_sha256
    assert authenticated.source_sha256 == evidence.source_sha256
    assert inspect(replay) =~ "REDACTED"

    proof = authenticated.proof

    assert {:error, %Error{code: :backup_invalid}} =
             @backup_key_lease.claim_recovered_vault_key(lease, proof)

    assert {:ok, replay_state} =
             @storage_adapter.init_decrypt(replay, expected_public_header(), crypto_header)

    assert {:ok, ^plaintext, replay_state} =
             @storage_adapter.decrypt_record(replay_state, data_record)

    assert {:ok, replayed, :replayed} =
             @storage_adapter.finalize_decrypt(replay_state, final_record, evidence)

    assert replayed.plaintext_sha256 == authenticated.plaintext_sha256

    assert {:ok, %RecoveredVaultKey{} = recovered} =
             @backup_key_lease.claim_recovered_vault_key(lease, proof)

    assert :ok = RecoveredVaultKey.revoke(recovered)

    assert {:ok, mismatch_lease} =
             @backup_key_lease.start_restore_link(%{
               active_ttl_ms: 1_000,
               binding: lease_binding(),
               cipher: {__MODULE__.Cipher, context.recorder},
               custodian: self(),
               key_material: @derived_key,
               public_header: expected_public_header()
             })

    Process.unlink(mismatch_lease)

    assert {:ok, mismatch_state} =
             @storage_adapter.init_decrypt(
               mismatch_lease,
               expected_public_header(),
               crypto_header
             )

    assert {:ok, ^plaintext, mismatch_state} =
             @storage_adapter.decrypt_record(mismatch_state, data_record)

    assert {:ok, _authenticated, mismatch_replay} =
             @storage_adapter.finalize_decrypt(mismatch_state, final_record, evidence)

    assert {:ok, mismatch_replay_state} =
             @storage_adapter.init_decrypt(
               mismatch_replay,
               expected_public_header(),
               crypto_header
             )

    decrypt_events_before =
      context.recorder
      |> Recorder.events()
      |> Enum.count(&match?({:cipher_decrypt, _, _}, &1))

    tamper_offset = byte_size(data_record) - 1
    <<prefix::binary-size(tamper_offset), last>> = data_record
    tampered_data_record = prefix <> <<Bitwise.bxor(last, 1)>>

    assert {:error, %Error{code: :backup_invalid}} =
             @storage_adapter.decrypt_record(mismatch_replay_state, tampered_data_record)

    assert decrypt_events_before ==
             context.recorder
             |> Recorder.events()
             |> Enum.count(&match?({:cipher_decrypt, _, _}, &1))

    assert :ok = @backup_key_lease.revoke(mismatch_lease)

    assert {:ok, canonical_lease} =
             @backup_key_lease.start_restore_link(%{
               active_ttl_ms: 1_000,
               binding: lease_binding(),
               cipher: {__MODULE__.Cipher, context.recorder},
               custodian: self(),
               key_material: @derived_key,
               public_header: expected_public_header()
             })

    Process.unlink(canonical_lease)

    assert {:ok, canonical_state} =
             @storage_adapter.init_decrypt(
               canonical_lease,
               expected_public_header(),
               crypto_header
             )

    assert {:ok, ^plaintext, canonical_state} =
             @storage_adapter.decrypt_record(canonical_state, data_record)

    canonical_events_before =
      context.recorder
      |> Recorder.events()
      |> Enum.count(&match?({:cipher_decrypt, _, _}, &1))

    noncanonical_second_record = <<1::unsigned-big-32, 1::unsigned-big-32, 0, 0::128>>

    assert {:error, %Error{code: :backup_invalid}} =
             @storage_adapter.decrypt_record(canonical_state, noncanonical_second_record)

    assert canonical_events_before ==
             context.recorder
             |> Recorder.events()
             |> Enum.count(&match?({:cipher_decrypt, _, _}, &1))

    assert :ok = @backup_key_lease.revoke(canonical_lease)
  end

  for revocation <- [:explicit_revoke, :expiry, :custodian_termination] do
    test "paused storage decrypt is cancelled by #{revocation} before plaintext release",
         context do
      fixture = paused_decrypt_fixture(context)
      assert :ok = Recorder.pause_next_decrypt(context.recorder)

      decrypt =
        Task.async(fn ->
          call(@storage_adapter, :decrypt_all, [
            fixture.lease,
            fixture.public_header,
            fixture.encoded_bundle
          ])
        end)

      assert_receive {:backup_cipher_decrypt_paused, worker, token, 0}, 1_000
      worker_monitor = Process.monitor(worker)
      lease = fixture.lease
      lease_monitor = Process.monitor(lease)
      revocation = unquote(revocation)
      revocation_handle = revoke_paused_decrypt(revocation, fixture)

      try do
        assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000
        assert_revocation_completed(revocation, revocation_handle)
        assert_receive {:DOWN, ^lease_monitor, :process, ^lease, :normal}, 1_000

        result = Task.await(decrypt, 1_000)
        assert {:error, :waiting_for_backup_key} = result
        refute result == {:ok, fixture.plaintext}

        custodian = custodian_after_revocation(revocation, fixture)
        assert_backup_custody_cleared(custodian, fixture.opaque_ref, result)
      after
        Recorder.release_decrypt(worker, token)
        shutdown_task(revocation_handle)
        shutdown_task(decrypt)
      end
    end
  end

  test "abnormal lease death also terminates a paused decrypt worker", context do
    fixture = paused_decrypt_fixture(context)
    assert :ok = Recorder.pause_next_decrypt(context.recorder)

    decrypt =
      Task.async(fn ->
        call(@storage_adapter, :decrypt_all, [
          fixture.lease,
          fixture.public_header,
          fixture.encoded_bundle
        ])
      end)

    assert_receive {:backup_cipher_decrypt_paused, worker, token, 0}, 1_000
    worker_monitor = Process.monitor(worker)
    lease = fixture.lease
    lease_monitor = Process.monitor(lease)

    try do
      Process.exit(lease, :kill)

      assert_receive {:DOWN, ^lease_monitor, :process, ^lease, :killed}, 1_000
      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000

      result = Task.await(decrypt, 1_000)
      assert {:error, :waiting_for_backup_key} = result
      refute result == {:ok, fixture.plaintext}

      assert_backup_custody_cleared(fixture.custodian, fixture.opaque_ref, result)
    after
      Recorder.release_decrypt(worker, token)
      shutdown_task(decrypt)
    end
  end

  test "re-entry opens the exact bundle and decrypts each frame only once", context do
    assert {:ok, prepared} = prepare(context.runtime)
    assert :ok = activate(context.custodian, prepared.opaque_ref)
    assert {:ok, encryptor} = active_lease(context.custodian, prepared.opaque_ref)
    assert {:ok, header} = api(:init_encrypt, [encryptor, lease_binding()])
    assert {:ok, encrypted} = api(:encrypt_chunk, [encryptor, 0, "framed record"])
    assert {:ok, trailer} = api(:finalize, [encryptor, authenticated_manifest()])

    persisted = %{
      "backup_key_lease_id" => prepared.opaque_ref,
      "manifest" => authenticated_manifest(),
      "public_metadata" => prepared.public_metadata,
      "vault_id" => @vault_id
    }

    reentry_event_offset = length(Recorder.events(context.recorder))

    assert_invalid_reentry(context, persisted, @wrong_passphrase)

    tampered_wrapper =
      put_in(
        persisted,
        ["public_metadata", "recovery", "wrapper"],
        "tampered-recovery-wrapper"
      )

    assert_invalid_reentry(context, tampered_wrapper, @passphrase)

    tampered_binding =
      put_in(
        persisted,
        ["public_metadata", "recovery", "binding", "vault_id"],
        "other-vault"
      )

    assert_invalid_reentry(context, tampered_binding, @passphrase)

    tampered_kdf =
      put_in(
        persisted,
        ["public_metadata", "kdf", "parameters", "m_cost"],
        8
      )

    assert_invalid_reentry(context, tampered_kdf, @passphrase)

    result_ref = make_ref()

    log =
      capture_log(fn ->
        send(self(), {result_ref, api(:reenter, [context.runtime, persisted, @passphrase])})
      end)

    assert_receive {^result_ref, {:ok, reentered}}

    refute secret_leaked?(
             [reentered, log, backup_key_state(context.custodian)],
             [@passphrase, @derived_key, @vault_key]
           )

    reentry_events =
      context.recorder
      |> Recorder.events()
      |> Enum.drop(reentry_event_offset)

    assert Enum.count(reentry_events, &match?({:derive, _, _, _, _}, &1)) == 5

    exact_derivations =
      Enum.count(reentry_events, fn
        {:derive, _passphrase_hash, @backup_domain, @backup_parameters, @salt} -> true
        _other -> false
      end)

    assert exact_derivations == 4

    assert Enum.any?(reentry_events, fn
             {:derive, @passphrase_hash, @backup_domain, %{"m_cost" => 8}, @salt} -> true
             _other -> false
           end)

    assert Enum.count(reentry_events, &match?({:unwrap, _, _}, &1)) == 5

    assert Enum.count(
             reentry_events,
             &match?({:backup_custody_prepared, _opaque_ref}, &1)
           ) == 1

    assert last_event_index!(reentry_events, :unwrap) <
             event_index!(reentry_events, :backup_custody_prepared)

    assert :ok = activate(context.custodian, reentered.opaque_ref)
    assert {:ok, decryptor} = active_lease(context.custodian, reentered.opaque_ref)

    bundle = %{
      header: header,
      manifest: authenticated_manifest(),
      frames: [encrypted],
      trailer: trailer
    }

    assert {:error, %Error{code: :backup_invalid}} =
             api(:open, [decryptor, lease_binding(vault_id: "other-vault"), bundle])

    assert {:error, %Error{code: :backup_invalid}} =
             api(:open, [decryptor, lease_binding(manifest_id: "other-manifest"), bundle])

    tampered_bundle = put_in(bundle, [:manifest, "vault_ids"], ["other-vault"])

    assert {:error, %Error{code: :backup_invalid}} =
             api(:open, [decryptor, lease_binding(), tampered_bundle])

    assert :ok = api(:open, [decryptor, lease_binding(), bundle])

    assert cipher_key_used?(context.recorder, :cipher_open, @derived_key_hash)
    refute cipher_key_used?(context.recorder, :cipher_open, @vault_key_hash)

    wrong_binding_frame =
      :erlang.term_to_binary({lease_binding(vault_id: "other-vault"), 0, "framed record"})

    assert {:error, %Error{code: :backup_invalid}} =
             api(:decrypt, [decryptor, 0, wrong_binding_frame])

    assert {:error, %Error{code: :backup_invalid}} =
             api(:decrypt, [decryptor, 1, encrypted])

    assert {:error, %Error{code: :backup_invalid}} =
             api(:decrypt, [decryptor, 0, <<131, 255>>])

    assert {:ok, "framed record"} = api(:decrypt, [decryptor, 0, encrypted])
    assert {:error, %Error{code: :conflict}} = api(:decrypt, [decryptor, 0, encrypted])
  end

  test "discard, pending expiry, and owner death remove unresolved custody", context do
    assert {:ok, discarded} = prepare(context.runtime)
    assert :ok = discard(context.custodian, discarded.opaque_ref)
    assert :ok = discard(context.custodian, discarded.opaque_ref)

    assert {:error, %Error{code: :conflict}} =
             activate(context.custodian, discarded.opaque_ref)

    assert {:ok, expiring} = prepare(context.runtime)
    send(context.custodian, {:expire_pending, expiring.opaque_ref})

    assert {:error, %Error{code: :conflict}} =
             activate(context.custodian, expiring.opaque_ref)

    owner =
      Task.async(fn ->
        {:ok, prepared} = prepare(context.runtime)
        prepared.opaque_ref
      end)

    orphan = Task.await(owner)

    assert_eventually(fn ->
      match?(
        {:error, %Error{code: :conflict}},
        activate(context.custodian, orphan)
      )
    end)
  end

  test "explicit revocation and custodian restart destroy every usable capability", context do
    assert {:ok, prepared} = prepare(context.runtime)
    assert :ok = activate(context.custodian, prepared.opaque_ref)
    assert {:ok, lease} = active_lease(context.custodian, prepared.opaque_ref)

    assert :ok = api(:revoke, [lease])
    assert {:error, :waiting_for_backup_key} = api(:init_encrypt, [lease, lease_binding()])

    assert_eventually(fn ->
      prepared.opaque_ref not in backup_key_state(context.custodian).active_refs
    end)

    assert {:ok, replacement_prepared} = prepare(context.runtime)
    assert :ok = activate(context.custodian, replacement_prepared.opaque_ref)

    assert {:ok, replacement_lease} =
             active_lease(context.custodian, replacement_prepared.opaque_ref)

    monitor = Process.monitor(replacement_lease)
    assert :ok = stop_supervised(KeyCustodian)
    assert_receive {:DOWN, ^monitor, :process, ^replacement_lease, _reason}, 1_000

    replacement_custodian = start_custodian(context.recorder, context.lease_supervisor)

    assert {:error, :lease_missing} =
             active_lease(replacement_custodian, replacement_prepared.opaque_ref)
  end

  test "activated custody survives requester exit until bounded lease expiry", context do
    requester =
      Task.async(fn ->
        assert {:ok, prepared} = prepare(context.runtime)
        assert :ok = activate(context.custodian, prepared.opaque_ref)
        prepared.opaque_ref
      end)

    opaque_ref = Task.await(requester)
    assert {:ok, lease} = active_lease(context.custodian, opaque_ref)
    assert opaque_ref in backup_key_state(context.custodian).active_refs

    monitor = Process.monitor(lease)
    send(lease, :expire)
    assert_receive {:DOWN, ^monitor, :process, ^lease, :normal}, 1_000

    assert_eventually(fn ->
      opaque_ref not in backup_key_state(context.custodian).active_refs
    end)

    assert {:error, :lease_missing} = active_lease(context.custodian, opaque_ref)
  end

  test "active custody uses a sliding idle timeout while encryption makes progress", context do
    assert :ok = stop_supervised(KeyCustodian)

    custodian =
      start_custodian(context.recorder, context.lease_supervisor, nil, 100)

    assert :ok = unlock(custodian)
    runtime = runtime(custodian, context.recorder)
    assert {:ok, prepared} = prepare(runtime)
    assert :ok = activate(custodian, prepared.opaque_ref)

    assert {:ok, %{capability: lease, public_header: public_header}} =
             backup_crypto(custodian, prepared.opaque_ref)

    assert {:ok, _header, encryption_state} =
             call(@storage_adapter, :init_encrypt, [lease, public_header])

    frame = <<0xBEEF::unsigned-big-16, 13::unsigned-big-64, "framed record">>
    <<prefix::binary-size(10), payload::binary>> = frame

    Process.sleep(60)

    assert {:ok, "", encryption_state} =
             call(@storage_adapter, :encrypt_chunk, [encryption_state, prefix])

    Process.sleep(60)

    assert {:ok, "", encryption_state} =
             call(@storage_adapter, :encrypt_chunk, [encryption_state, payload])

    Process.sleep(60)

    assert {:ok, _trailer, _summary, :finalized} =
             call(@storage_adapter, :finalize, [encryption_state, authenticated_manifest()])
  end

  test "dead lease supervisor returns a safe activation error without crashing custody",
       context do
    assert {:ok, prepared} = prepare(context.runtime)
    lease_supervisor = context.lease_supervisor
    custodian = context.custodian

    supervisor_monitor = Process.monitor(lease_supervisor)
    Process.exit(lease_supervisor, :kill)

    assert_receive {:DOWN, ^supervisor_monitor, :process, ^lease_supervisor, :killed},
                   1_000

    custodian_monitor = Process.monitor(custodian)

    assert {:error, %Error{code: :conflict}} =
             activate(custodian, prepared.opaque_ref)

    refute_receive {:DOWN, ^custodian_monitor, :process, ^custodian, _reason}, 100
    assert Process.alive?(custodian)
    assert KeyCustodian.unlocked?(custodian, @session_id)
    assert backup_key_state(custodian) == %{active_refs: [], pending_refs: []}

    custodian_state = :sys.get_state(custodian)
    refute secret_leaked?(custodian_state, [@passphrase, @derived_key])

    Process.demonitor(custodian_monitor, [:flush])
  end

  defp paused_decrypt_fixture(context) do
    plaintext = "plaintext must not escape after revocation"
    assert {:ok, prepared} = prepare(context.runtime)
    assert :ok = activate(context.custodian, prepared.opaque_ref)

    assert {:ok, %{capability: encryptor, public_header: public_header}} =
             backup_crypto(context.custodian, prepared.opaque_ref)

    assert {:ok, encoded_header, encryption_state} =
             call(@storage_adapter, :init_encrypt, [encryptor, public_header])

    assert {:ok, encoded_record, encryption_state} =
             call(@storage_adapter, :encrypt_chunk, [encryption_state, plaintext])

    manifest = authenticated_manifest()

    assert {:ok, encoded_trailer, _summary, :finalized} =
             call(@storage_adapter, :finalize, [encryption_state, manifest])

    encoded_bundle = IO.iodata_to_binary([encoded_header, encoded_record, encoded_trailer])

    assert :ok = api(:revoke, [encryptor])

    assert_eventually(fn ->
      prepared.opaque_ref not in backup_key_state(context.custodian).active_refs
    end)

    persisted = %{
      "backup_key_lease_id" => prepared.opaque_ref,
      "manifest" => manifest,
      "public_metadata" => prepared.public_metadata,
      "vault_id" => @vault_id
    }

    assert {:ok, reentered} = api(:reenter, [context.runtime, persisted, @passphrase])
    assert :ok = activate(context.custodian, reentered.opaque_ref)
    assert {:ok, lease} = active_lease(context.custodian, reentered.opaque_ref)

    %{
      custodian: context.custodian,
      encoded_bundle: encoded_bundle,
      lease: lease,
      lease_supervisor: context.lease_supervisor,
      opaque_ref: reentered.opaque_ref,
      plaintext: plaintext,
      public_header: public_header,
      recorder: context.recorder
    }
  end

  defp revoke_paused_decrypt(:explicit_revoke, fixture) do
    Task.async(fn -> api(:revoke, [fixture.lease]) end)
  end

  defp revoke_paused_decrypt(:expiry, fixture) do
    send(fixture.lease, :expire)
    :ok
  end

  defp revoke_paused_decrypt(:custodian_termination, _fixture) do
    assert :ok = stop_supervised(KeyCustodian)
    :ok
  end

  defp assert_revocation_completed(:explicit_revoke, revoker) do
    assert {:ok, :ok} = Task.yield(revoker, 1_000)
  end

  defp assert_revocation_completed(revocation, :ok)
       when revocation in [:expiry, :custodian_termination],
       do: :ok

  defp custodian_after_revocation(:custodian_termination, fixture) do
    start_custodian(fixture.recorder, fixture.lease_supervisor)
  end

  defp custodian_after_revocation(revocation, fixture)
       when revocation in [:explicit_revoke, :expiry],
       do: fixture.custodian

  defp assert_backup_custody_cleared(custodian, opaque_ref, result) do
    assert_eventually(fn ->
      backup_key_state(custodian) == %{active_refs: [], pending_refs: []}
    end)

    assert {:error, :lease_missing} = active_lease(custodian, opaque_ref)

    refute secret_leaked?(
             [result, backup_key_state(custodian), :sys.get_state(custodian)],
             [@passphrase, @derived_key]
           )
  end

  defp shutdown_task(%Task{pid: pid} = task) do
    if Process.alive?(pid), do: Task.shutdown(task, :brutal_kill)
    :ok
  end

  defp shutdown_task(_not_a_task), do: :ok

  defp prepare(runtime) do
    api(:prepare, [runtime, session(), @manifest_id, @passphrase])
  end

  defp activate(custodian, opaque_ref) do
    call(KeyCustodian, :activate_backup_key, [custodian, opaque_ref])
  end

  defp discard(custodian, opaque_ref) do
    call(KeyCustodian, :discard_pending, [custodian, opaque_ref])
  end

  defp active_lease(custodian, opaque_ref) do
    case backup_crypto(custodian, opaque_ref) do
      {:ok,
       %{
         adapter: @storage_adapter,
         capability: capability,
         public_header: public_header
       }} ->
        assert is_pid(capability)
        assert public_header == expected_public_header()
        {:ok, capability}

      other ->
        other
    end
  end

  defp backup_crypto(custodian, opaque_ref) do
    call(KeyCustodian, :backup_crypto, [custodian, @manifest_id, opaque_ref])
  end

  defp expected_public_header do
    %{
      version: 1,
      manifest_id: @manifest_id,
      vault_id: @vault_id,
      kdf: %{
        "domain" => @backup_domain,
        "parameters" => @backup_parameters,
        "salt" => @encoded_salt
      }
    }
  end

  defp backup_key_state(custodian) do
    state = call(KeyCustodian, :backup_key_state, [custodian])

    assert Map.keys(state) |> Enum.sort() == [:active_refs, :pending_refs]
    assert Enum.all?(state.active_refs ++ state.pending_refs, &is_binary/1)
    state
  end

  defp assert_invalid_reentry(context, persisted, passphrase) do
    before = backup_key_state(context.custodian)
    result_ref = make_ref()

    log =
      capture_log(fn ->
        send(
          self(),
          {result_ref, api(:reenter, [context.runtime, persisted, passphrase])}
        )
      end)

    assert_receive {^result_ref, {:error, %Error{code: :backup_invalid} = error}}

    after_reentry = backup_key_state(context.custodian)
    assert after_reentry == before

    refute secret_leaked?(
             [error, log, after_reentry],
             [passphrase, @derived_key, @vault_key]
           )
  end

  defp api(function, arguments), do: call(@backup_key_lease, function, arguments)
  defp call(module, function, arguments), do: apply(module, function, arguments)

  defp runtime(custodian, recorder) do
    %{
      account_kdf_parameters: %{
        "m_cost" => 8,
        "parallelism" => 1,
        "t_cost" => 2,
        "version" => 1
      },
      backup_cipher: {__MODULE__.Cipher, recorder},
      backup_kdf_domain: @backup_domain,
      backup_kdf_parameters: @backup_parameters,
      backup_key_deriver: {Deriver, recorder},
      backup_key_wrapper: {Wrapper, recorder},
      backup_pending_ttl_ms: 1_000,
      custodian: {KeyCustodian, custodian},
      random_bytes: fn 16 -> @salt end,
      vault_kdf_parameters: %{
        "m_cost" => 16,
        "parallelism" => 1,
        "t_cost" => 3,
        "version" => 2
      }
    }
  end

  defmodule Cipher do
    @tag_size 16
    @hostile_record <<131, 80, 0x40000000::unsigned-big-32, 120, 156, 3, 0, 0, 0, 0, 1>>

    alias Singularity.Storage.Crypto.ChunkedAEAD

    def hostile_record, do: @hostile_record

    def init_encrypt(recorder, %{key: key, vault_id: vault_id, object_id: manifest_id} = context) do
      Recorder.record(recorder, {
        :cipher_init_encrypt,
        :crypto.hash(:sha256, key),
        %{manifest_id: manifest_id, vault_id: vault_id}
      })

      ChunkedAEAD.init_encrypt(context)
    end

    def encrypt_chunk(_recorder, state, plaintext),
      do: ChunkedAEAD.encrypt_chunk(state, plaintext)

    def finalize(_recorder, state), do: ChunkedAEAD.finalize(state)

    def before_storage_record(recorder, index),
      do: Recorder.before_decrypt(recorder, index)

    def decrypt_data_record(recorder, record, context) do
      Recorder.record(
        recorder,
        {:cipher_decrypt, context.counter, :crypto.hash(:sha256, record)}
      )

      ChunkedAEAD.decrypt_data_record(record, context)
    end

    def decrypt_final_record(_recorder, record, context),
      do: ChunkedAEAD.decrypt_final_record(record, context)

    def init_encrypt(recorder, key, binding) do
      Recorder.record(recorder, {:cipher_init_encrypt, :crypto.hash(:sha256, key), binding})

      header = %{
        "algorithm" => "chunked_aead_v1",
        "binding_hash" => :crypto.hash(:sha256, :erlang.term_to_binary(binding)),
        "nonce_prefix" => :crypto.strong_rand_bytes(8)
      }

      {:ok, header, %{binding: binding, header: header, key: key}}
    end

    def encrypt_chunk(_recorder, state, _index, "hostile ETF-shaped ciphertext") do
      {:ok, @hostile_record, state}
    end

    def encrypt_chunk(_recorder, state, index, plaintext) do
      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          state.key,
          nonce(state.header["nonce_prefix"], index),
          plaintext,
          aad(state.binding, index),
          @tag_size,
          true
        )

      {:ok, ciphertext <> tag, state}
    end

    def finalize(_recorder, state, manifest) do
      {:ok,
       :crypto.mac(
         :hmac,
         :sha256,
         state.key,
         :erlang.term_to_binary({state.binding, manifest}, [:deterministic])
       )}
    end

    def open(recorder, key, binding, bundle) do
      Recorder.record(recorder, {:cipher_open, :crypto.hash(:sha256, key), binding})

      expected_binding_hash = :crypto.hash(:sha256, :erlang.term_to_binary(binding))

      expected_trailer =
        :crypto.mac(
          :hmac,
          :sha256,
          key,
          :erlang.term_to_binary({binding, bundle.manifest}, [:deterministic])
        )

      if bundle.header["algorithm"] == "chunked_aead_v1" and
           bundle.header["binding_hash"] == expected_binding_hash and
           is_binary(bundle.header["nonce_prefix"]) and
           byte_size(bundle.header["nonce_prefix"]) == 8 and bundle.trailer == expected_trailer do
        {:ok, %{binding: binding, header: bundle.header, key: key}}
      else
        {:error, Error.new(:backup_invalid)}
      end
    end

    def decrypt(recorder, state, index, encrypted) do
      Recorder.record(recorder, {:cipher_decrypt, index, :crypto.hash(:sha256, encrypted)})
      :ok = Recorder.before_decrypt(recorder, index)

      with true <- byte_size(encrypted) >= @tag_size do
        ciphertext_size = byte_size(encrypted) - @tag_size
        <<ciphertext::binary-size(ciphertext_size), tag::binary-size(@tag_size)>> = encrypted

        case :crypto.crypto_one_time_aead(
               :aes_256_gcm,
               state.key,
               nonce(state.header["nonce_prefix"], index),
               ciphertext,
               aad(state.binding, index),
               tag,
               false
             ) do
          plaintext when is_binary(plaintext) -> {:ok, plaintext, state}
          :error -> {:error, Error.new(:backup_invalid)}
        end
      else
        false -> {:error, Error.new(:backup_invalid)}
      end
    rescue
      ArgumentError -> {:error, Error.new(:backup_invalid)}
    end

    defp nonce(prefix, index), do: <<prefix::binary-size(8), index::unsigned-big-32>>

    defp aad(binding, index),
      do: :erlang.term_to_binary({binding, index}, [:deterministic])
  end

  defmodule OversizedHeaderCipher do
    def init_encrypt(recorder, context) do
      with {:ok, _header, state} <- Cipher.init_encrypt(recorder, context) do
        {:ok, :binary.copy(<<0xEF>>, 65_537), state}
      end
    end

    def init_encrypt(recorder, key, binding) do
      with {:ok, _header, state} <- Cipher.init_encrypt(recorder, key, binding) do
        {:ok, %{"oversized" => :binary.copy(<<0xEF>>, 65_537)}, state}
      end
    end

    def encrypt_chunk(recorder, state, plaintext),
      do: Cipher.encrypt_chunk(recorder, state, plaintext)

    def finalize(recorder, state), do: Cipher.finalize(recorder, state)

    def decrypt_data_record(recorder, record, context),
      do: Cipher.decrypt_data_record(recorder, record, context)

    def decrypt_final_record(recorder, record, context),
      do: Cipher.decrypt_final_record(recorder, record, context)
  end

  defmodule LimitCipher do
    @chunk_size 4_194_304

    def init_encrypt(recorder, context), do: Cipher.init_encrypt(recorder, context)

    def encrypt_chunk(_recorder, state, <<counter::unsigned-big-32>>) do
      record =
        <<counter::unsigned-big-32, @chunk_size::unsigned-big-32,
          :binary.copy(<<0xEE>>, @chunk_size)::binary, 0::128>>

      {:ok, record, state}
    end

    def finalize(recorder, state), do: Cipher.finalize(recorder, state)

    def decrypt_data_record(recorder, record, context),
      do: Cipher.decrypt_data_record(recorder, record, context)

    def decrypt_final_record(recorder, record, context),
      do: Cipher.decrypt_final_record(recorder, record, context)
  end

  defp start_custodian(
         recorder,
         lease_supervisor,
         backup_cipher \\ nil,
         backup_active_ttl_ms \\ 60_000
       ) do
    backup_cipher = backup_cipher || {Cipher, recorder}

    start_supervised!(
      {KeyCustodian,
       %{
         authorization: UnusedReader,
         backup_cipher: backup_cipher,
         backup_active_ttl_ms: backup_active_ttl_ms,
         backup_key_observer: {BackupKeyObserver, recorder},
         backup_key_deriver: {Deriver, recorder},
         backup_key_wrapper: {Wrapper, recorder},
         backup_pending_ttl_ms: 1_000,
         clock: Clock,
         context: %{},
         idle_lock: {Callbacks, recorder},
         key_reader: UnusedReader,
         lease_supervisor: lease_supervisor,
         object_key_loader: UnusedReader,
         pending_ttl_ms: 1_000,
         wake_waiting: {Callbacks, recorder}
       }}
    )
  end

  defp unlock(custodian) do
    with {:ok, pending} <- KeyCustodian.prepare_unlock(custodian, session()) do
      KeyCustodian.activate_unlock(custodian, pending)
    end
  end

  defp session do
    %{
      principal_authorization_epoch: 7,
      principal_id: @principal_id,
      session_id: @session_id,
      vault_authorization_epoch: 11,
      vault_id: @vault_id,
      vault_key: @vault_key
    }
  end

  defp lease_binding(overrides \\ []) do
    Map.merge(%{manifest_id: @manifest_id, vault_id: @vault_id}, Map.new(overrides))
  end

  defp authenticated_manifest do
    %{
      inventory: [
        %{
          payload_length: byte_size("framed record"),
          position: 0,
          record_type: 0xBEEF,
          sha256: :crypto.hash(:sha256, "framed record")
        }
      ],
      manifest_id: @manifest_id,
      outbox_high_water_mark: 41,
      recovery: %{
        "binding" => %{
          "manifest_id" => @manifest_id,
          "vault_id" => @vault_id
        },
        "label" => "backup_recovery",
        "wrapper" => "authenticated-recovery-wrapper"
      },
      snapshot_id: "00000000-0000-4000-8000-000000000705",
      vault_ids: [@vault_id],
      version: 1
    }
  end

  defp secret_leaked?(value, secrets) do
    binaries = collect_binaries(value) ++ rendered_forms(value)

    Enum.any?(secrets, fn secret ->
      Enum.any?(secret_forms(secret), fn form ->
        Enum.any?(binaries, &binary_contains?(&1, form))
      end)
    end)
  end

  defp collect_binaries(value) when is_binary(value), do: [value]

  defp collect_binaries(value) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.flat_map(fn {key, nested} ->
      collect_binaries(key) ++ collect_binaries(nested)
    end)
  end

  defp collect_binaries(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.flat_map(&collect_binaries/1)

  defp collect_binaries(value) when is_list(value),
    do: Enum.flat_map(value, &collect_binaries/1)

  defp collect_binaries(_value), do: []

  defp rendered_forms(value) do
    [
      inspect(value, limit: :infinity, printable_limit: :infinity),
      inspect(value,
        base: :hex,
        binaries: :as_binaries,
        charlists: :as_lists,
        limit: :infinity,
        printable_limit: :infinity
      )
    ]
  end

  defp secret_forms(secret) when is_binary(secret) do
    [
      secret,
      Base.encode16(secret, case: :lower),
      Base.encode16(secret, case: :upper),
      inspect(secret, limit: :infinity, printable_limit: :infinity),
      inspect(secret,
        base: :hex,
        binaries: :as_binaries,
        limit: :infinity,
        printable_limit: :infinity
      ),
      inspect(:binary.bin_to_list(secret), limit: :infinity)
    ]
    |> Enum.uniq()
  end

  defp binary_contains?(binary, form) when is_binary(binary) and is_binary(form),
    do: :binary.match(binary, form) != :nomatch

  defp cipher_key_used?(recorder, operation, key_hash) do
    Enum.any?(Recorder.events(recorder), fn
      {^operation, ^key_hash, _binding} -> true
      _other -> false
    end)
  end

  defp flip_byte(binary, offset) do
    <<prefix::binary-size(offset), byte, suffix::binary>> = binary
    <<prefix::binary, Bitwise.bxor(byte, 1), suffix::binary>>
  end

  defp event_index!(events, tag) do
    case Enum.find_index(events, &tagged?(&1, tag)) do
      nil -> flunk("expected event #{inspect(tag)} was not recorded")
      index -> index
    end
  end

  defp last_event_index!(events, tag) do
    case events
         |> Enum.with_index()
         |> Enum.reduce(nil, fn {event, index}, last ->
           if tagged?(event, tag), do: index, else: last
         end) do
      nil -> flunk("expected event #{inspect(tag)} was not recorded")
      index -> index
    end
  end

  defp tagged?(tag, tag), do: true

  defp tagged?(event, tag) when is_tuple(event) and tuple_size(event) > 0,
    do: elem(event, 0) == tag

  defp tagged?(_event, _tag), do: false

  defp assert_eventually(callback, attempts \\ 40)

  defp assert_eventually(callback, attempts) when attempts > 0 do
    if callback.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(callback, attempts - 1)
    end
  end

  defp assert_eventually(callback, 0), do: assert(callback.())
end
