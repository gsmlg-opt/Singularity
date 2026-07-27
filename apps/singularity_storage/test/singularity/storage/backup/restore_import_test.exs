defmodule Singularity.Storage.Backup.RestoreImportTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias Singularity.Core.Error
  alias Singularity.Storage.Backup.BundleReader
  alias Singularity.Storage.Backup.LogicalBundleVerifier
  alias Singularity.Storage.Backup.LocalDestination
  alias Singularity.Storage.Backup.LogicalRecordCodec
  alias Singularity.Storage.Backup.LogicalSchema
  alias Singularity.Storage.Backup.Manifest
  alias Singularity.Storage.Backup.Restorer
  alias Singularity.Storage.LocalFilesystemAdapter
  alias Singularity.Storage.Local.PathGuard
  alias Singularity.Storage.MigrationRepo

  @timestamp "2026-07-23T00:00:00.000000Z"

  defmodule RollbackAfterFinalizeAdapter do
    @moduledoc false

    alias Singularity.Core.Error
    alias Singularity.Storage.LocalFilesystemAdapter

    defdelegate stage(context, options), to: LocalFilesystemAdapter
    defdelegate append_encrypted_chunk(context, stage_ref, chunk), to: LocalFilesystemAdapter
    defdelegate seal_stage(context, stage_ref, metadata), to: LocalFilesystemAdapter
    defdelegate finalize(context, stage_ref, object_ref), to: LocalFilesystemAdapter
    defdelegate abort_stage(context, stage_ref), to: LocalFilesystemAdapter
    defdelegate delete(context, object_ref), to: LocalFilesystemAdapter
    defdelegate list_staged(context), to: LocalFilesystemAdapter

    def stat(%{rollback_after_finalize: gate} = context, object_ref) do
      if Agent.get_and_update(gate, fn failed? -> {not failed?, true} end) do
        {:error, Error.new(:storage_unavailable, retryable?: true)}
      else
        LocalFilesystemAdapter.stat(context, object_ref)
      end
    end

    def rollback_finalize(%{rollback_after_finalize: gate} = context, stage_ref, object_ref) do
      if Agent.get(gate, & &1) do
        {:error, Error.new(:storage_unavailable, retryable?: true)}
      else
        LocalFilesystemAdapter.rollback_finalize(context, stage_ref, object_ref)
      end
    end
  end

  defmodule ReplayMutationCrypto do
    @moduledoc false
    @header "TEST"
    @final_counter 0xFFFFFFFF

    def header_size, do: byte_size(@header)

    def init_decrypt(capability, _public_header, @header) do
      {:ok, %{bytes: 0, capability: capability, count: 0, hash: :crypto.hash_init(:sha256)}}
    end

    def decrypt_record(state, record) do
      with <<counter::unsigned-big-32, size::unsigned-big-32, plaintext::binary-size(size),
             _tag::binary-size(16)>> <- record,
           true <- counter == state.count,
           :ok <- maybe_mutate_source(state.capability) do
        {:ok, plaintext,
         %{
           state
           | bytes: state.bytes + size,
             count: counter + 1,
             hash: :crypto.hash_update(state.hash, plaintext)
         }}
      else
        _invalid -> {:error, :integrity_failure}
      end
    end

    def finalize_decrypt(state, final_record, evidence) do
      with <<@final_counter::unsigned-big-32, 44::unsigned-big-32, _metadata::binary-size(44),
             _tag::binary-size(16)>> <- final_record do
        authenticated =
          Map.merge(evidence, %{
            chunk_count: state.count,
            plaintext_bytes: state.bytes,
            plaintext_sha256: :crypto.hash_final(state.hash),
            proof: %{manifest_hash: evidence.manifest_hash}
          })

        case state.capability do
          {:authenticate, recorder} ->
            Agent.update(recorder, &Map.put(&1, :authentication, authenticated))
            {:ok, authenticated, {:replay, recorder}}

          {:replay, recorder} ->
            if Agent.get(recorder, &(&1.authentication == authenticated)) do
              {:ok, authenticated, :replayed}
            else
              {:error, :integrity_failure}
            end
        end
      else
        _invalid -> {:error, :integrity_failure}
      end
    end

    defp maybe_mutate_source({:authenticate, _recorder}), do: :ok

    defp maybe_mutate_source({:replay, recorder}) do
      case Agent.get_and_update(recorder, fn state ->
             if state.mutated?,
               do: {:already_mutated, state},
               else: {:mutate, %{state | mutated?: true}}
           end) do
        :already_mutated -> :ok
        :mutate -> mutate_last_byte(Agent.get(recorder, & &1.path))
      end
    end

    defp mutate_last_byte(path) do
      with {:ok, device} <- :file.open(String.to_charlist(path), [:read, :write, :binary, :raw]),
           {:ok, size} <- :file.position(device, :eof),
           {:ok, <<last>>} <- :file.pread(device, size - 1, 1),
           :ok <- :file.pwrite(device, size - 1, <<Bitwise.bxor(last, 1)>>),
           :ok <- :file.sync(device),
           :ok <- :file.close(device) do
        :ok
      else
        _failure -> {:error, :mutation_failed}
      end
    end
  end

  test "rejects a supplied cut that differs from the authenticated bundle cut" do
    fixture = verified_fixture()
    mismatched_cut = %{fixture.cut | database_snapshot: "8:9:"}

    assert {:error, %Error{code: :backup_invalid}} =
             Restorer.import(
               %{object_storage: :must_not_be_called},
               :must_not_be_called,
               %{verified: fixture.verified, cut: mismatched_cut, binding: fixture.binding}
             )
  end

  @tag :tmp_dir
  test "rejects authenticated object evidence that differs from its logical row", %{
    tmp_dir: tmp_dir
  } do
    fixture =
      full_verified_fixture()
      |> rewrite_row("content.asset_objects", fn schema, values ->
        replace_wire_field(schema, values, "storage_ref", {"text", "different-storage-ref"})
      end)

    assert {:ok, authenticated_cut} =
             LogicalBundleVerifier.verify(fixture.verified, fixture.binding)

    assert authenticated_cut == fixture.cut

    object_root = Path.join(tmp_dir, "must-remain-absent")

    assert {:error, %Error{code: :backup_invalid}} =
             Restorer.import(
               %{object_storage: {LocalFilesystemAdapter, %{root: object_root}}},
               :must_not_be_called,
               %{verified: fixture.verified, cut: fixture.cut, binding: fixture.binding}
             )

    refute File.exists?(object_root)
  end

  @tag :integration
  test "rejects an unknown nonempty object destination without creating a saga marker" do
    with_clean_destination(fn storage_root ->
      fixture = complete_verified_fixture()
      object_root = Path.join(storage_root, "nonempty-destination")
      File.mkdir_p!(object_root)
      existing_path = Path.join(object_root, "existing-object")
      File.write!(existing_path, "do-not-touch")

      assert {:error, %Error{code: :conflict}} =
               Restorer.import(
                 %{object_storage: {LocalFilesystemAdapter, %{root: object_root}}},
                 MigrationRepo,
                 %{verified: fixture.verified, cut: fixture.cut, binding: fixture.binding}
               )

      assert File.read!(existing_path) == "do-not-touch"

      owner_transaction(fn ->
        assert %{rows: [[0]]} = query("SELECT count(*) FROM audit.restore_import_sagas")
      end)
    end)
  end

  @tag :integration
  test "imports authenticated owner rows into an empty locked destination" do
    with_clean_destination(fn storage_root ->
      fixture = complete_verified_fixture()
      object_root = Path.join(storage_root, "restore-objects")
      assert_fresh_destination()

      assert {:ok,
              %Restorer.Imported{
                manifest: %{manifest_id: manifest_id},
                cut: %{vault_id: vault_id, object_inventory: []},
                object_inventory: [],
                owner: %{
                  account_id: account_id,
                  active_credential_ids: active_credential_ids,
                  all_credential_ids: all_credential_ids,
                  owner_principal_ids: owner_principal_ids,
                  vault_key_generation: 7,
                  vault_key_version_id: vault_key_version_id,
                  vault_key_wrapper_id: wrapper_id,
                  wrapper_generation: 9
                }
              } = imported} =
               Restorer.import(
                 %{
                   object_storage: {LocalFilesystemAdapter, %{root: object_root}}
                 },
                 MigrationRepo,
                 %{verified: fixture.verified, cut: fixture.cut, binding: fixture.binding}
               )

      assert manifest_id == fixture.ids.manifest_id
      assert vault_id == fixture.ids.vault_id
      assert account_id == fixture.ids.account_id
      assert active_credential_ids == [fixture.ids.active_credential_id]

      assert all_credential_ids ==
               Enum.sort([fixture.ids.active_credential_id, fixture.ids.revoked_credential_id])

      assert owner_principal_ids == [fixture.ids.owner_principal_id]
      assert vault_key_version_id == fixture.ids.vault_key_version_id
      assert wrapper_id == fixture.ids.wrapper_id
      refute inspect(imported) =~ "source-verifier-canary"
      refute inspect(imported) =~ "source-wrapper-canary"

      second_object_root = Path.join(storage_root, "second-restore-objects")

      assert {:error, %Error{code: :conflict}} =
               Restorer.import(
                 %{
                   object_storage: {LocalFilesystemAdapter, %{root: second_object_root}}
                 },
                 MigrationRepo,
                 %{verified: fixture.verified, cut: fixture.cut, binding: fixture.binding}
               )

      refute File.exists?(second_object_root)

      assert_destination_rows(fixture.ids)
      assert_excluded_tables_empty()
      assert next_outbox_sequence() == 1
      refute File.exists?(object_root)
    end)
  end

  @tag :integration
  test "imports every logical group and publishes exact authenticated ciphertext" do
    with_clean_destination(fn storage_root ->
      fixture = full_verified_fixture()
      object_root = Path.join(storage_root, "restore-objects")

      assert {:ok, %Restorer.Imported{} = imported} =
               Restorer.import(
                 %{
                   object_storage: {LocalFilesystemAdapter, %{root: object_root}}
                 },
                 MigrationRepo,
                 %{verified: fixture.verified, cut: fixture.cut, binding: fixture.binding}
               )

      assert imported.object_inventory == fixture.cut.object_inventory

      refute inspect(imported) =~ fixture.raw_payload
      refute inspect(imported) =~ object_root
      assert_all_logical_groups_imported(fixture.row_counts)
      assert next_outbox_sequence() == 43

      lookup_digest = Base.encode16(fixture.object.lookup_digest, case: :lower)

      assert {:ok, object_path} =
               PathGuard.object_path(
                 object_root,
                 fixture.ids.vault_id,
                 fixture.ids.key_domain_id,
                 lookup_digest
               )

      assert File.read!(object_path) == fixture.raw_payload
      assert %{mode: mode, size: size, type: :regular} = File.lstat!(object_path)
      assert band(mode, 0o777) == 0o400
      assert size == byte_size(fixture.raw_payload)
      refute object_path =~ fixture.object.storage_ref
    end)
  end

  @tag :integration
  test "recovers an exact pending import after rollback follows object finalization" do
    with_clean_destination(fn storage_root ->
      fixture = full_verified_fixture()
      object_root = Path.join(storage_root, "restore-objects")
      other_root = Path.join(storage_root, "different-restore-objects")
      {:ok, gate} = Agent.start_link(fn -> false end)

      assert {:error, %Error{code: :storage_unavailable}} =
               Restorer.import(
                 %{
                   object_storage:
                     {RollbackAfterFinalizeAdapter,
                      %{root: object_root, rollback_after_finalize: gate}}
                 },
                 MigrationRepo,
                 %{verified: fixture.verified, cut: fixture.cut, binding: fixture.binding}
               )

      lookup_digest = Base.encode16(fixture.object.lookup_digest, case: :lower)

      assert {:ok, object_path} =
               PathGuard.object_path(
                 object_root,
                 fixture.ids.vault_id,
                 fixture.ids.key_domain_id,
                 lookup_digest
               )

      assert File.read!(object_path) == fixture.raw_payload

      owner_transaction(fn ->
        assert %{rows: [[manifest_id, vault_id, manifest_hash, 1, root_hash, "pending"]]} =
                 query("""
                 SELECT
                   manifest_id,
                   vault_id,
                   manifest_hash,
                   object_count,
                   destination_root_hash,
                   state
                 FROM audit.restore_import_sagas
                 WHERE singleton
                 """)

        assert Ecto.UUID.load!(manifest_id) == fixture.ids.manifest_id
        assert Ecto.UUID.load!(vault_id) == fixture.ids.vault_id
        assert manifest_hash == fixture.verified.manifest_hash
        assert root_hash == :crypto.hash(:sha256, Path.expand(object_root))
      end)

      mismatched_fixture =
        rewrite_row(fixture, "identity.people", fn schema, values ->
          replace_wire_field(schema, values, "display_name", {"text", "Different Owner"})
        end)

      assert {:error, %Error{code: :conflict}} =
               Restorer.import(
                 %{object_storage: {LocalFilesystemAdapter, %{root: object_root}}},
                 MigrationRepo,
                 %{
                   verified: mismatched_fixture.verified,
                   cut: mismatched_fixture.cut,
                   binding: mismatched_fixture.binding
                 }
               )

      assert {:error, %Error{code: :conflict}} =
               Restorer.import(
                 %{object_storage: {LocalFilesystemAdapter, %{root: other_root}}},
                 MigrationRepo,
                 %{verified: fixture.verified, cut: fixture.cut, binding: fixture.binding}
               )

      assert File.read!(object_path) == fixture.raw_payload
      refute File.exists?(other_root)

      unknown_path = Path.join(object_root, "unknown-preexisting-file")
      File.write!(unknown_path, "do-not-delete")

      assert {:error, %Error{code: :conflict}} =
               Restorer.import(
                 %{object_storage: {LocalFilesystemAdapter, %{root: object_root}}},
                 MigrationRepo,
                 %{verified: fixture.verified, cut: fixture.cut, binding: fixture.binding}
               )

      assert File.read!(unknown_path) == "do-not-delete"
      refute File.exists?(object_path)
      File.rm!(unknown_path)

      assert {:ok, %Restorer.Imported{} = imported} =
               Restorer.import(
                 %{object_storage: {LocalFilesystemAdapter, %{root: object_root}}},
                 MigrationRepo,
                 %{verified: fixture.verified, cut: fixture.cut, binding: fixture.binding}
               )

      assert File.read!(object_path) == fixture.raw_payload

      owner_transaction(fn ->
        assert %{rows: [["imported"]]} =
                 query("SELECT state FROM audit.restore_import_sagas WHERE singleton")
      end)

      assert {:ok, ^imported} =
               Restorer.import(
                 %{object_storage: {LocalFilesystemAdapter, %{root: object_root}}},
                 MigrationRepo,
                 %{verified: fixture.verified, cut: fixture.cut, binding: fixture.binding}
               )
    end)
  end

  @tag :integration
  test "mutation during bounded replay rolls back rows and removes every provisional stage" do
    with_clean_destination(fn storage_root ->
      fixture = full_verified_fixture()
      source_root = Path.join(storage_root, "bounded-source")
      object_root = Path.join(storage_root, "bounded-objects")
      source_path = Path.join(source_root, "restore.bundle")
      File.mkdir_p!(source_root)
      File.write!(source_path, encode_bounded_source(fixture))

      {:ok, recorder} =
        Agent.start_link(fn ->
          %{authentication: nil, mutated?: false, path: source_path}
        end)

      assert {:ok, source} =
               LocalDestination.reader_source(%{backup_root: source_root}, "restore.bundle")

      verifier_binding = Map.drop(fixture.binding, [:recovery])

      assert {:ok, verified} =
               BundleReader.authenticate_all(source,
                 crypto: {ReplayMutationCrypto, {:authenticate, recorder}},
                 verifier: {LogicalBundleVerifier, verifier_binding}
               )

      assert {:error, %Error{}} =
               Restorer.import(
                 %{object_storage: {LocalFilesystemAdapter, %{root: object_root}}},
                 MigrationRepo,
                 %{verified: verified, cut: fixture.cut, binding: fixture.binding}
               )

      owner_transaction(fn ->
        for table <- LogicalSchema.tables() do
          assert %{rows: [[0]]} = query("SELECT count(*) FROM #{quote_table(table)}")
        end

        assert %{rows: [["pending"]]} =
                 query("SELECT state FROM audit.restore_import_sagas WHERE singleton")
      end)

      assert {:ok, []} = LocalFilesystemAdapter.list_staged(%{root: object_root})

      lookup_digest = Base.encode16(fixture.object.lookup_digest, case: :lower)

      assert {:ok, object_path} =
               PathGuard.object_path(
                 object_root,
                 fixture.ids.vault_id,
                 fixture.ids.key_domain_id,
                 lookup_digest
               )

      refute File.exists?(object_path)
    end)
  end

  defp encode_bounded_source(fixture) do
    {:ok, encoded_manifest} = Manifest.encode(fixture.verified.manifest)

    plaintext =
      (fixture.verified.records ++ [%{type: 0xFFFF, payload: encoded_manifest}])
      |> Enum.map(fn record ->
        <<record.type::unsigned-big-16, byte_size(record.payload)::unsigned-big-64,
          record.payload::binary>>
      end)
      |> IO.iodata_to_binary()

    encrypted =
      plaintext
      |> bounded_chunks(4_194_304)
      |> Enum.with_index()
      |> Enum.map(fn {chunk, index} ->
        <<index::unsigned-big-32, byte_size(chunk)::unsigned-big-32, chunk::binary, 0::128>>
      end)
      |> Kernel.++([
        <<0xFFFFFFFF::unsigned-big-32, 44::unsigned-big-32, 0::352, 0xAB::128>>
      ])
      |> then(&IO.iodata_to_binary(["TEST" | &1]))

    public_header = %{manifest_id: fixture.ids.manifest_id, version: 1}
    encoded_header = :erlang.term_to_binary(public_header, [:deterministic])

    <<"SINGULARITY-BACKUP", 1::unsigned-big-16, byte_size(encoded_header)::unsigned-big-32,
      encoded_header::binary, encrypted::binary>>
  end

  defp bounded_chunks(binary, size), do: bounded_chunks(binary, size, [])
  defp bounded_chunks("", _size, chunks), do: Enum.reverse(chunks)

  defp bounded_chunks(binary, size, chunks) do
    count = min(size, byte_size(binary))
    <<chunk::binary-size(count), rest::binary>> = binary
    bounded_chunks(rest, size, [chunk | chunks])
  end

  defp verified_fixture do
    vault_id = Ecto.UUID.generate()
    manifest_id = Ecto.UUID.generate()
    snapshot_id = Ecto.UUID.generate()

    counts =
      LogicalSchema.all()
      |> Enum.map(fn
        %{table: "core.vaults"} -> 1
        _schema -> 0
      end)

    {:ok, cut_record} =
      LogicalRecordCodec.encode_cut(%{
        database_snapshot: "1:2:",
        manifest_id: manifest_id,
        object_count: 0,
        outbox_high_water_mark: 0,
        snapshot_id: snapshot_id,
        table_count_vector: counts,
        vault_id: vault_id
      })

    {:ok, vault_record} =
      LogicalRecordCodec.encode_row(
        "core.vaults",
        [{"uuid", vault_id}],
        [
          {"uuid", vault_id},
          {"text", "personal"},
          {"integer", 0},
          {"boolean", false},
          {"json", %{}},
          {"timestamp", @timestamp},
          {"timestamp", @timestamp},
          {"null"}
        ]
      )

    records = [cut_record, vault_record]

    recovery = %{
      "binding" => %{"manifest_id" => manifest_id, "vault_id" => vault_id},
      "label" => "backup_recovery",
      "wrapper" => "authenticated-wrapper"
    }

    {:ok, manifest} =
      Manifest.new(%{
        version: 1,
        manifest_id: manifest_id,
        vault_ids: [vault_id],
        snapshot_id: snapshot_id,
        outbox_high_water_mark: 0,
        recovery: recovery,
        inventory: manifest_inventory(records)
      })

    {:ok, encoded_manifest} = Manifest.encode(manifest)

    verified = %BundleReader.Verified{
      manifest: manifest,
      records: records,
      manifest_hash: :crypto.hash(:sha256, encoded_manifest),
      manifest_tag: :binary.copy(<<0xA5>>, 16)
    }

    binding = %{
      destination_ref: "restore-import-test",
      manifest_id: manifest_id,
      recovery: recovery,
      vault_id: vault_id
    }

    {:ok, cut} = LogicalBundleVerifier.verify(verified, binding)

    %{binding: binding, cut: cut, verified: verified}
  end

  defp complete_verified_fixture do
    ids = %{
      person_id: "10000000-0000-0000-0000-000000000001",
      account_id: "10000000-0000-0000-0000-000000000002",
      active_credential_id: "10000000-0000-0000-0000-000000000003",
      revoked_credential_id: "10000000-0000-0000-0000-000000000004",
      owner_principal_id: "10000000-0000-0000-0000-000000000005",
      cleanup_principal_id: "10000000-0000-0000-0000-000000000006",
      capability_id: "10000000-0000-0000-0000-000000000007",
      vault_id: "10000000-0000-0000-0000-000000000008",
      vault_key_version_id: "10000000-0000-0000-0000-000000000009",
      wrapper_id: "10000000-0000-0000-0000-000000000010",
      manifest_id: "10000000-0000-0000-0000-000000000011",
      snapshot_id: "10000000-0000-0000-0000-000000000012"
    }

    rows = %{
      "identity.people" => [
        [ids.person_id, "Restored Owner", %{}, @timestamp, @timestamp]
      ],
      "identity.accounts" => [
        [ids.account_id, ids.person_id, "active", %{}, @timestamp, @timestamp]
      ],
      "identity.credentials" => [
        [
          ids.active_credential_id,
          ids.account_id,
          "owner@example.test",
          nil,
          @timestamp
        ],
        [
          ids.revoked_credential_id,
          ids.account_id,
          "revoked@example.test",
          @timestamp,
          @timestamp
        ]
      ],
      "identity.principals" => [
        [ids.owner_principal_id, ids.account_id, "owner", 3, nil, %{}, @timestamp, @timestamp],
        [
          ids.cleanup_principal_id,
          ids.account_id,
          "system",
          4,
          nil,
          %{"name" => "object_cleanup"},
          @timestamp,
          @timestamp
        ]
      ],
      "core.capabilities" => [
        [ids.capability_id, "object.cleanup", @timestamp]
      ],
      "core.vaults" => [
        [
          ids.vault_id,
          "personal",
          5,
          false,
          %{},
          @timestamp,
          @timestamp,
          ids.cleanup_principal_id
        ]
      ],
      "core.vault_members" => [
        [ids.owner_principal_id, ids.vault_id, "restricted", nil, @timestamp, @timestamp],
        [ids.cleanup_principal_id, ids.vault_id, "restricted", nil, @timestamp, @timestamp]
      ],
      "core.principal_capabilities" => [
        [ids.cleanup_principal_id, ids.vault_id, ids.capability_id, nil, @timestamp]
      ],
      "core.vault_key_versions" => [
        [
          ids.vault_key_version_id,
          ids.vault_id,
          7,
          "active",
          "aes-256-gcm",
          @timestamp,
          nil,
          @timestamp
        ]
      ],
      "core.vault_key_wrappers" => [
        [ids.wrapper_id, ids.vault_id, ids.vault_key_version_id, ids.account_id, 9, @timestamp]
      ]
    }

    build_verified_fixture(ids, rows, [], [])
  end

  defp full_verified_fixture do
    ids = %{
      person_id: fixture_id(1),
      account_id: fixture_id(2),
      active_credential_id: fixture_id(3),
      revoked_credential_id: fixture_id(4),
      owner_principal_id: fixture_id(5),
      cleanup_principal_id: fixture_id(6),
      capability_id: fixture_id(7),
      vault_id: fixture_id(8),
      vault_key_version_id: fixture_id(9),
      wrapper_id: fixture_id(10),
      device_id: fixture_id(13),
      key_domain_id: fixture_id(14),
      domain_key_version_id: fixture_id(15),
      dedup_wrapper_id: fixture_id(16),
      resource_id: fixture_id(17),
      resource_version_id: fixture_id(18),
      asset_object_id: fixture_id(19),
      live_asset_id: fixture_id(20),
      deleted_asset_id: fixture_id(21),
      asset_envelope_id: fixture_id(22),
      asset_metadata_id: fixture_id(23),
      source_reference_id: fixture_id(24),
      tombstone_id: fixture_id(25),
      audit_event_id: fixture_id(26),
      audit_correlation_id: fixture_id(27),
      outbox_event_id: fixture_id(28),
      outbox_correlation_id: fixture_id(29),
      job_submission_id: fixture_id(30),
      job_progress_id: fixture_id(31),
      effect_receipt_id: fixture_id(32),
      manifest_id: fixture_id(90),
      snapshot_id: fixture_id(91)
    }

    raw_payload = "exact-authenticated-ciphertext-v1"
    lookup_digest = :crypto.hash(:sha256, "full-import-lookup")
    ciphertext_hash = :crypto.hash(:sha256, raw_payload)
    storage_ref = "../../opaque/source/object"

    rows = %{
      "identity.people" => [
        [ids.person_id, "Restored Owner", %{}, @timestamp, @timestamp]
      ],
      "identity.accounts" => [
        [ids.account_id, ids.person_id, "active", %{}, @timestamp, @timestamp]
      ],
      "identity.credentials" => [
        [ids.active_credential_id, ids.account_id, "owner@example.test", nil, @timestamp],
        [
          ids.revoked_credential_id,
          ids.account_id,
          "revoked@example.test",
          @timestamp,
          @timestamp
        ]
      ],
      "identity.principals" => [
        [ids.owner_principal_id, ids.account_id, "owner", 3, nil, %{}, @timestamp, @timestamp],
        [
          ids.cleanup_principal_id,
          ids.account_id,
          "system",
          4,
          nil,
          %{"name" => "object_cleanup"},
          @timestamp,
          @timestamp
        ]
      ],
      "core.capabilities" => [[ids.capability_id, "object.cleanup", @timestamp]],
      "core.vaults" => [
        [
          ids.vault_id,
          "personal",
          5,
          false,
          %{},
          @timestamp,
          @timestamp,
          ids.cleanup_principal_id
        ]
      ],
      "core.vault_members" => [
        [ids.owner_principal_id, ids.vault_id, "restricted", nil, @timestamp, @timestamp],
        [ids.cleanup_principal_id, ids.vault_id, "restricted", nil, @timestamp, @timestamp]
      ],
      "core.principal_capabilities" => [
        [ids.cleanup_principal_id, ids.vault_id, ids.capability_id, nil, @timestamp]
      ],
      "identity.devices" => [
        [
          ids.device_id,
          ids.owner_principal_id,
          ids.vault_id,
          "restored-device",
          nil,
          @timestamp,
          @timestamp
        ]
      ],
      "core.key_domains" => [
        [ids.key_domain_id, ids.vault_id, "private", "content", "active", @timestamp, @timestamp]
      ],
      "core.vault_key_versions" => [
        [
          ids.vault_key_version_id,
          ids.vault_id,
          7,
          "active",
          "aes-256-gcm",
          @timestamp,
          nil,
          @timestamp
        ]
      ],
      "core.vault_key_wrappers" => [
        [ids.wrapper_id, ids.vault_id, ids.vault_key_version_id, ids.account_id, 9, @timestamp]
      ],
      "core.domain_key_versions" => [
        [
          ids.domain_key_version_id,
          ids.vault_id,
          ids.key_domain_id,
          ids.vault_key_version_id,
          2,
          "active",
          "aes-256-gcm",
          "domain-key-wrapper",
          @timestamp
        ]
      ],
      "core.domain_dedup_key_wrappers" => [
        [
          ids.dedup_wrapper_id,
          ids.vault_id,
          ids.key_domain_id,
          ids.domain_key_version_id,
          "aes-256-gcm",
          "dedup-key-wrapper",
          @timestamp
        ]
      ],
      "content.resources" => [
        [
          ids.resource_id,
          ids.vault_id,
          "private",
          "Restored resource",
          nil,
          %{},
          @timestamp,
          @timestamp
        ]
      ],
      "content.resource_versions" => [
        [
          ids.resource_version_id,
          ids.resource_id,
          ids.vault_id,
          "private",
          1,
          @timestamp,
          @timestamp
        ]
      ],
      "content.asset_objects" => [
        [
          ids.asset_object_id,
          ids.vault_id,
          ids.key_domain_id,
          "private",
          lookup_digest,
          ciphertext_hash,
          17,
          byte_size(raw_payload),
          storage_ref,
          1,
          "available",
          nil,
          nil,
          nil,
          @timestamp,
          @timestamp,
          2,
          nil,
          nil
        ]
      ],
      "content.assets" => [
        [
          ids.live_asset_id,
          ids.vault_id,
          ids.resource_version_id,
          ids.asset_object_id,
          "private",
          "ready",
          3,
          nil,
          nil,
          nil,
          1,
          @timestamp,
          @timestamp
        ],
        [
          ids.deleted_asset_id,
          ids.vault_id,
          ids.resource_version_id,
          ids.asset_object_id,
          "private",
          "deleted",
          4,
          nil,
          nil,
          nil,
          1,
          @timestamp,
          @timestamp
        ]
      ],
      "content.asset_key_envelopes" => [
        [
          ids.asset_envelope_id,
          ids.vault_id,
          ids.asset_object_id,
          ids.domain_key_version_id,
          ids.key_domain_id,
          "private",
          "aes-256-gcm",
          2,
          "wrapped-dek",
          @timestamp
        ]
      ],
      "content.asset_metadata" => [
        [
          ids.asset_metadata_id,
          ids.live_asset_id,
          ids.resource_version_id,
          ids.vault_id,
          "private",
          1,
          "document.pdf",
          "application/pdf",
          "application/pdf",
          17,
          "1.7",
          nil,
          nil,
          "completed",
          "fixture-v1",
          @timestamp,
          @timestamp,
          @timestamp
        ]
      ],
      "content.resource_assets" => [
        [
          ids.resource_version_id,
          ids.live_asset_id,
          ids.vault_id,
          "private",
          @timestamp,
          @timestamp
        ]
      ],
      "content.source_references" => [
        [
          ids.source_reference_id,
          ids.vault_id,
          ids.resource_version_id,
          ids.owner_principal_id,
          "private",
          "browser_upload",
          @timestamp,
          "document.pdf",
          "application/pdf",
          17,
          :crypto.hash(:sha256, "source-reference"),
          @timestamp
        ]
      ],
      "content.tombstones" => [
        [
          ids.tombstone_id,
          ids.vault_id,
          ids.deleted_asset_id,
          ids.owner_principal_id,
          "private",
          "operator delete",
          %{"source" => "restore-test"},
          @timestamp
        ]
      ],
      "audit.events" => [
        [
          ids.audit_event_id,
          ids.vault_id,
          "principal",
          ids.owner_principal_id,
          nil,
          "asset.created",
          "completed",
          "private",
          ids.audit_correlation_id,
          "asset",
          ids.live_asset_id,
          %{},
          @timestamp,
          @timestamp
        ]
      ],
      "core.outbox_events" => [
        [
          ids.outbox_event_id,
          42,
          "asset.verify_requested",
          "restore-import-outbox",
          ids.vault_id,
          ids.owner_principal_id,
          "asset.verify",
          3,
          "private",
          ids.outbox_correlation_id,
          nil,
          0,
          1,
          %{"asset_id" => ids.live_asset_id},
          @timestamp,
          nil,
          nil,
          nil,
          nil,
          @timestamp,
          @timestamp,
          5,
          nil,
          nil
        ]
      ],
      "jobs.job_submissions" => [
        [
          ids.job_submission_id,
          ids.vault_id,
          ids.outbox_event_id,
          "private",
          "restore-import-job",
          "asset_verify",
          nil,
          @timestamp,
          @timestamp
        ]
      ],
      "jobs.job_progress" => [
        [
          ids.job_progress_id,
          ids.vault_id,
          ids.job_submission_id,
          "private",
          "waiting_for_unlock",
          2,
          1,
          %{"step" => "verify"},
          @timestamp,
          @timestamp
        ]
      ],
      "jobs.effect_receipts" => [
        [
          ids.effect_receipt_id,
          ids.vault_id,
          ids.job_submission_id,
          "private",
          "restore-import-effect",
          "applied",
          3,
          @timestamp
        ]
      ]
    }

    object = %{
      asset_object_id: ids.asset_object_id,
      ciphertext_byte_size: byte_size(raw_payload),
      ciphertext_hash: ciphertext_hash,
      classification: "private",
      key_domain_id: ids.key_domain_id,
      lookup_digest: lookup_digest,
      object_index: 0,
      storage_ref: storage_ref,
      vault_id: ids.vault_id
    }

    fixture = build_verified_fixture(ids, rows, [object], [raw_payload], 42)

    Map.merge(fixture, %{
      object: object,
      raw_payload: raw_payload,
      row_counts: Map.new(rows, fn {table, table_rows} -> {table, length(table_rows)} end)
    })
  end

  defp build_verified_fixture(ids, rows, objects, raw_payloads, outbox_high_water_mark \\ 0) do
    row_records =
      LogicalSchema.all()
      |> Enum.flat_map(fn schema ->
        rows
        |> Map.get(schema.table, [])
        |> Enum.map(&encode_row!(schema, &1))
      end)

    counts =
      Enum.map(LogicalSchema.all(), fn schema ->
        rows |> Map.get(schema.table, []) |> length()
      end)

    cut_attrs = %{
      database_snapshot: "1:2:",
      manifest_id: ids.manifest_id,
      object_count: length(objects),
      outbox_high_water_mark: outbox_high_water_mark,
      snapshot_id: ids.snapshot_id,
      table_count_vector: counts,
      vault_id: ids.vault_id
    }

    {:ok, cut_record} = LogicalRecordCodec.encode_cut(cut_attrs)
    object_records = Enum.map(objects, &encode_object!/1)

    raw_records =
      Enum.map(raw_payloads, fn payload ->
        %{type: 0x8000, payload: payload, payload_length: byte_size(payload)}
      end)

    records = [cut_record | row_records] ++ object_records ++ raw_records

    recovery = %{
      "binding" => %{"manifest_id" => ids.manifest_id, "vault_id" => ids.vault_id},
      "label" => "backup_recovery",
      "wrapper" => "authenticated-wrapper"
    }

    {:ok, manifest} =
      Manifest.new(%{
        version: 1,
        manifest_id: ids.manifest_id,
        vault_ids: [ids.vault_id],
        snapshot_id: ids.snapshot_id,
        outbox_high_water_mark: outbox_high_water_mark,
        recovery: recovery,
        inventory: manifest_inventory(records)
      })

    {:ok, encoded_manifest} = Manifest.encode(manifest)

    verified = %BundleReader.Verified{
      manifest: manifest,
      records: records,
      manifest_hash: :crypto.hash(:sha256, encoded_manifest),
      manifest_tag: :binary.copy(<<0xA5>>, 16)
    }

    binding = %{
      destination_ref: "restore-import-test",
      manifest_id: ids.manifest_id,
      recovery: recovery,
      vault_id: ids.vault_id
    }

    {:ok, cut} = LogicalBundleVerifier.verify(verified, binding)
    %{binding: binding, cut: cut, ids: ids, verified: verified}
  end

  defp rewrite_row(fixture, table, rewrite) do
    records =
      Enum.map(fixture.verified.records, fn
        %{type: 0x0002, payload: payload} = original ->
          case LogicalRecordCodec.decode(0x0002, payload) do
            {:ok, %{table: ^table} = row} ->
              {:ok, schema} = LogicalSchema.fetch_table(table)
              values = rewrite.(schema, row.ordered_column_values)

              {:ok, rewritten} =
                LogicalRecordCodec.encode_row(table, row.primary_key_values, values)

              rewritten

            _other ->
              original
          end

        original ->
          original
      end)

    {:ok, manifest} =
      fixture.verified.manifest
      |> Map.put(:inventory, manifest_inventory(records))
      |> Manifest.new()

    {:ok, encoded_manifest} = Manifest.encode(manifest)

    verified = %BundleReader.Verified{
      fixture.verified
      | manifest: manifest,
        records: records,
        manifest_hash: :crypto.hash(:sha256, encoded_manifest)
    }

    %{fixture | verified: verified}
  end

  defp replace_wire_field(schema, values, name, replacement) do
    position = Enum.find_index(schema.columns, &(&1.name == name))
    List.replace_at(values, position, replacement)
  end

  defp encode_row!(schema, raw_values) do
    tagged_values =
      schema.columns
      |> Enum.zip(raw_values)
      |> Enum.map(fn
        {%{nullable?: true}, nil} -> {"null"}
        {%{tag: tag}, value} -> {tag, value}
      end)

    primary_key_values =
      Enum.map(schema.primary_key, &Enum.at(tagged_values, &1.position))

    {:ok, record} =
      LogicalRecordCodec.encode_row(schema.table, primary_key_values, tagged_values)

    record
  end

  defp encode_object!(object) do
    {:ok, record} = LogicalRecordCodec.encode_object(object)
    record
  end

  defp assert_destination_rows(ids) do
    owner_transaction(fn ->
      assert %{rows: [[true, cleanup_principal_id]]} =
               query(
                 "SELECT locked, object_cleanup_principal_id FROM core.vaults WHERE id = $1",
                 [
                   Ecto.UUID.dump!(ids.vault_id)
                 ]
               )

      assert Ecto.UUID.load!(cleanup_principal_id) == ids.cleanup_principal_id

      assert %{rows: credential_rows} =
               query("""
               SELECT
                 credential.id,
                 credential.verifier = setting.dummy_verifier,
                 credential.verifier_version,
                 credential.inserted_at,
                 credential.updated_at
               FROM identity.credentials AS credential
               CROSS JOIN identity.security_settings AS setting
               ORDER BY credential.id
               """)

      assert [
               [active_id, true, 1, active_inserted_at, active_updated_at],
               [revoked_id, true, 1, revoked_inserted_at, revoked_updated_at]
             ] = credential_rows

      assert Ecto.UUID.load!(active_id) == ids.active_credential_id
      assert Ecto.UUID.load!(revoked_id) == ids.revoked_credential_id
      assert DateTime.to_iso8601(active_inserted_at) == @timestamp
      assert active_updated_at == active_inserted_at
      assert DateTime.to_iso8601(revoked_inserted_at) == @timestamp
      assert revoked_updated_at == revoked_inserted_at

      assert %{rows: [[9, 1, kdf_salt, kdf_parameters, "restore_pending", wrapped_key]]} =
               query(
                 """
                 SELECT
                   generation,
                   kdf_version,
                   kdf_salt,
                   kdf_parameters,
                   wrapper_algorithm,
                   wrapped_key
                 FROM core.vault_key_wrappers
                 WHERE id = $1
                 """,
                 [Ecto.UUID.dump!(ids.wrapper_id)]
               )

      assert kdf_salt == "restore-pending"
      assert kdf_parameters == %{"state" => "restore_pending", "version" => 1}
      assert wrapped_key == "restore-pending"
    end)
  end

  defp assert_fresh_destination do
    owner_transaction(fn ->
      assert %{rows: [["singularity_table_owner", "singularity_migration", true]]} =
               query("""
               SELECT
                 current_user,
                 session_user,
                 pg_has_role(session_user, 'singularity_table_owner', 'SET')
               """)

      for table <-
            LogicalSchema.tables() ++
              ~w[
                identity.sessions identity.auth_attempts content.asset_stages
                content.upload_grants content.asset_search_documents audit.backup_manifests
                audit.backup_manifest_objects audit.restore_import_sagas jobs.oban_jobs jobs.oban_peers
              ] do
        assert %{rows: [[0]]} = query("SELECT count(*) FROM #{quote_table(table)}")
      end

      assert %{rows: [[1]]} =
               query("SELECT count(*) FROM identity.security_settings WHERE singleton")

      assert %{rows: [[3]]} = query("SELECT count(*) FROM core.data_classifications")
    end)
  end

  defp assert_all_logical_groups_imported(row_counts) do
    owner_transaction(fn ->
      for table <- LogicalSchema.tables() do
        expected_count = Map.fetch!(row_counts, table)
        assert %{rows: [[^expected_count]]} = query("SELECT count(*) FROM #{quote_table(table)}")
      end
    end)
  end

  defp assert_excluded_tables_empty do
    owner_transaction(fn ->
      assert %{rows: rows} =
               query("""
               SELECT table_name, row_count
               FROM (
                 VALUES
                   ('identity.sessions', (SELECT count(*) FROM identity.sessions)),
                   ('identity.auth_attempts', (SELECT count(*) FROM identity.auth_attempts)),
                   ('content.asset_stages', (SELECT count(*) FROM content.asset_stages)),
                   ('content.upload_grants', (SELECT count(*) FROM content.upload_grants)),
                   ('content.asset_search_documents', (SELECT count(*) FROM content.asset_search_documents)),
                   ('audit.backup_manifests', (SELECT count(*) FROM audit.backup_manifests)),
                   ('audit.backup_manifest_objects', (SELECT count(*) FROM audit.backup_manifest_objects)),
                   ('jobs.oban_jobs', (SELECT count(*) FROM jobs.oban_jobs)),
                   ('jobs.oban_peers', (SELECT count(*) FROM jobs.oban_peers))
               ) AS excluded(table_name, row_count)
               ORDER BY table_name
               """)

      assert Enum.all?(rows, fn [_table, count] -> count == 0 end)
    end)
  end

  defp next_outbox_sequence do
    owner_transaction(fn ->
      %{rows: [[sequence]]} = query("SELECT nextval('core.outbox_events_sequence_seq')")
      sequence
    end)
  end

  defp with_clean_destination(operation) do
    {migration_repo, started_here?} = ensure_migration_repo_started!()

    storage_root =
      :singularity_storage
      |> Application.fetch_env!(:storage_root)
      |> Path.join("restore-import-#{System.unique_integer([:positive])}")

    reset_destination!()
    File.rm_rf!(storage_root)

    try do
      operation.(storage_root)
    after
      reset_destination!()
      File.rm_rf!(storage_root)

      if started_here? and Process.alive?(migration_repo) do
        Supervisor.stop(migration_repo)
      end
    end
  end

  defp ensure_migration_repo_started! do
    case Process.whereis(MigrationRepo) do
      nil ->
        case MigrationRepo.start_link(pool_size: 2) do
          {:ok, migration_repo} -> {migration_repo, true}
          {:error, {:already_started, migration_repo}} -> {migration_repo, false}
        end

      migration_repo ->
        {migration_repo, false}
    end
  end

  defp reset_destination! do
    tables =
      (LogicalSchema.tables() ++
         ~w[
           identity.sessions identity.auth_attempts content.asset_stages
           content.upload_grants content.asset_search_documents audit.backup_manifests
           audit.backup_manifest_objects audit.restore_import_sagas jobs.oban_jobs jobs.oban_peers
         ])
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map_join(", ", &quote_table/1)

    owner_transaction(fn ->
      query("TRUNCATE TABLE #{tables} RESTART IDENTITY CASCADE")
    end)
  end

  defp owner_transaction(operation) do
    {:ok, result} =
      MigrationRepo.transaction(fn ->
        query("SET LOCAL ROLE singularity_table_owner")
        operation.()
      end)

    result
  end

  defp query(statement, parameters \\ []) do
    Ecto.Adapters.SQL.query!(MigrationRepo, statement, parameters, log: false)
  end

  defp quote_table(table) do
    table
    |> String.split(".")
    |> Enum.map_join(".", &~s("#{&1}"))
  end

  defp fixture_id(number) do
    suffix = number |> Integer.to_string() |> String.pad_leading(12, "0")
    "20000000-0000-0000-0000-#{suffix}"
  end

  defp manifest_inventory(records) do
    records
    |> Enum.with_index()
    |> Enum.map(fn {%{type: type, payload: payload}, position} ->
      %{
        position: position,
        record_type: type,
        payload_length: byte_size(payload),
        sha256: :crypto.hash(:sha256, payload)
      }
    end)
  end
end
