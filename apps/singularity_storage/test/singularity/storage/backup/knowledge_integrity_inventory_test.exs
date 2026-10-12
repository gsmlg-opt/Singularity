defmodule Singularity.Storage.Backup.KnowledgeIntegrityInventoryTest do
  use ExUnit.Case, async: false

  alias Singularity.Core.Error
  alias Singularity.Storage.Backup.IntegrityAudit
  alias Singularity.Storage.Local.PathGuard
  alias Singularity.Storage.LocalFilesystemAdapter

  @subject Singularity.Storage.Backup.KnowledgeIntegrityInventory
  @moduletag :tmp_dir
  @owner "71000000-0000-4000-8000-000000000001"
  @domain "71000000-0000-4000-8000-000000000002"

  defmodule OtherStorage do
    def stat(_context, _object) do
      send(self(), :unexpected_projection_storage_read)
      {:error, Singularity.Core.Error.new(:storage_unavailable)}
    end
  end

  defmodule NoSQLRepo do
    def transaction(_callback, _options \\ []) do
      send(self(), :unexpected_inventory_sql)
      raise "invalid input reached a transaction"
    end
  end

  test "UUID projection preserves every original field, position and unchanged V1 digest", ctx do
    original = entries(:uuid)
    cut = cut(original)

    for storage <- [
          {LocalFilesystemAdapter, %{root: ctx.tmp_dir}},
          %{adapter: LocalFilesystemAdapter, context: %{root: ctx.tmp_dir}},
          {OtherStorage, %{}}
        ] do
      assert {:ok, projected} = call(:project, [storage, cut])
      assert projected === original
      assert {:ok, ^original} = call(:project, [storage, Map.delete(cut, :object_count)])
      assert {:ok, digest} = IntegrityAudit.inventory_sha256(@owner, projected)
      assert {:ok, ^digest} = IntegrityAudit.inventory_sha256(@owner, original)
      refute_received :unexpected_projection_storage_read
    end
  end

  for mode <- [:canonical, :mixed] do
    test "#{mode} projection replaces only references with their existing UUIDs", ctx do
      original = entries(unquote(mode))
      expected = Enum.map(original, &Map.replace!(&1, :storage_ref, &1.asset_object_id))
      before = :erlang.term_to_binary(original, [:deterministic])
      storage = {LocalFilesystemAdapter, %{root: ctx.tmp_dir}}

      assert {:ok, ^expected} = call(:project, [storage, cut(original)])
      assert :erlang.term_to_binary(original, [:deterministic]) == before
      assert {:ok, projected_digest} = IntegrityAudit.inventory_sha256(@owner, expected)
      assert {:ok, ^projected_digest} = IntegrityAudit.inventory_sha256(@owner, entries(:uuid))

      for {entry, projected} <- Enum.zip(original, expected) do
        assert Map.delete(entry, :storage_ref) === Map.delete(projected, :storage_ref)

        context = %{
          root: ctx.tmp_dir,
          vault_namespace: id(90),
          domain_namespace: id(91),
          lookup_digest: String.duplicate("f", 64)
        }

        exact =
          Map.merge(context, %{
            vault_namespace: entry.vault_id,
            domain_namespace: entry.key_domain_id,
            lookup_digest: Base.encode16(entry.lookup_digest, case: :lower)
          })

        assert {:ok, path} =
                 PathGuard.object_path(
                   exact.root,
                   exact.vault_namespace,
                   exact.domain_namespace,
                   exact.lookup_digest
                 )

        assert canonical(entry) == Path.relative_to(path, ctx.tmp_dir)
      end

      # Conflicting adapter defaults must never override per-entry namespaces.
      assert {:ok, ^expected} =
               call(:project, [
                 {
                   LocalFilesystemAdapter,
                   %{
                     root: ctx.tmp_dir,
                     vault_namespace: id(90),
                     domain_namespace: id(91),
                     lookup_digest: String.duplicate("f", 64)
                   }
                 },
                 cut(original)
               ])
    end
  end

  test "projection is explicit V3 dispatch rather than reference or table-count inference", ctx do
    valid = cut(entries(:uuid))

    for version <- [nil, 0, 1, 2, 4, "3", :three] do
      assert_invalid(
        call(:project, [
          {LocalFilesystemAdapter, %{root: ctx.tmp_dir}},
          Map.put(valid, :logical_version, version)
        ])
      )
    end

    assert_invalid(
      call(:project, [
        {LocalFilesystemAdapter, %{root: ctx.tmp_dir}},
        Map.delete(valid, :logical_version)
      ])
    )

    assert_invalid(call(:project, [{LocalFilesystemAdapter, %{root: ctx.tmp_dir}}, nil]))
  end

  test "cut owner and exact count must agree with every projected entry", ctx do
    valid = cut(entries(:uuid))
    storage = {LocalFilesystemAdapter, %{root: ctx.tmp_dir}}

    for count <- [nil, -1, 0, 1, 3, "2"] do
      assert_invalid(call(:project, [storage, Map.put(valid, :object_count, count)]))
    end

    for owner <- [nil, id(80), "not-an-owner"] do
      assert_invalid(call(:project, [storage, Map.put(valid, :vault_id, owner)]))
    end
  end

  test "wrong UUIDs, alternate spellings and foreign physical paths never normalize", ctx do
    [first, second] = entries(:canonical)
    path = canonical(first)
    assert String.upcase(first.asset_object_id) != first.asset_object_id

    invalid = [
      second.asset_object_id,
      String.upcase(first.asset_object_id),
      canonical(%{first | vault_id: id(80)}),
      canonical(%{first | key_domain_id: id(81)}),
      canonical(%{first | lookup_digest: <<99::256>>}),
      "opaque-reference",
      String.upcase(path),
      "/" <> path,
      path <> "/",
      "objects/../" <> path,
      String.replace(path, "/", "\\")
    ]

    for reference <- invalid do
      changed = [%{first | storage_ref: reference}, second]

      assert_invalid(
        call(:project, [{LocalFilesystemAdapter, %{root: ctx.tmp_dir}}, cut(changed)])
      )
    end
  end

  test "canonical conversion needs the actual local adapter and safe configured root", ctx do
    canonical_cut = cut(entries(:canonical))
    assert_invalid(call(:project, [{OtherStorage, %{root: ctx.tmp_dir}}, canonical_cut]))
    refute_received :unexpected_projection_storage_read

    for context <- [%{}, %{root: nil}, %{root: <<0>>}] do
      assert_invalid(call(:project, [{LocalFilesystemAdapter, context}, canonical_cut]))
    end

    foreign = Path.join(ctx.tmp_dir, "foreign")
    root = Path.join(ctx.tmp_dir, "owned")
    File.mkdir_p!(foreign)
    File.mkdir_p!(root)
    File.ln_s!(foreign, Path.join(root, "objects"))
    assert_invalid(call(:project, [{LocalFilesystemAdapter, %{root: root}}, canonical_cut]))
    assert File.lstat!(Path.join(root, "objects")).type == :symlink
  end

  test "malformed fields, ordering and duplicate physical identities fail before storage", ctx do
    [first, second] = entries(:uuid)

    malformed = [
      [second, first],
      [first, %{second | inventory_position: 0}],
      [first, %{second | vault_id: id(90)}],
      [
        first,
        %{second | asset_object_id: first.asset_object_id, storage_ref: first.asset_object_id}
      ],
      [first, %{second | lookup_digest: first.lookup_digest}],
      [%{first | ciphertext_hash: <<0>>}, second],
      [%{first | lookup_digest: <<0>>}, second],
      [%{first | ciphertext_byte_size: -1}, second],
      [%{first | classification: :public}, second],
      [Map.put(first, :unchecked_authority, true), second],
      [Map.delete(first, :storage_ref), second]
    ]

    for inventory <- malformed do
      assert_invalid(
        call(:project, [{LocalFilesystemAdapter, %{root: ctx.tmp_dir}}, cut(inventory)])
      )

      refute_received :unexpected_projection_storage_read
    end
  end

  test "malformed handoffs and bindings reject without SQL or key-bearing error details", ctx do
    for imported <- [nil, %{}, %{cut: cut(entries(:uuid)), object_inventory: []}] do
      assert_invalid(
        call(:prepare, [NoSQLRepo, {LocalFilesystemAdapter, %{root: ctx.tmp_dir}}, imported])
      )

      refute_received :unexpected_inventory_sql
    end

    for binding <- [nil, %{}, %{raw_key: "PRIVATE-CANARY"}, %{manifest_id: id(71)}] do
      result = call(:load_plaintext_material, [%{}, binding, hd(entries(:uuid))])
      assert_invalid(result)
      refute inspect(result) =~ "PRIVATE-CANARY"
      refute inspect(result) =~ ctx.tmp_dir
      refute_received :unexpected_inventory_sql
    end
  end

  defp call(function, arguments) do
    assert Code.ensure_loaded?(@subject), "missing concrete V3 two-view inventory adapter"
    assert function_exported?(@subject, function, length(arguments))
    apply(@subject, function, arguments)
  end

  defp cut(inventory),
    do: %{
      logical_version: 3,
      manifest_id: id(71),
      vault_id: @owner,
      object_count: length(inventory),
      object_inventory: inventory
    }

  defp entries(mode) do
    for position <- 0..1 do
      entry = %{
        asset_object_id: id(position + 10),
        ciphertext_byte_size: 134 + position,
        ciphertext_hash: :crypto.hash(:sha256, "ciphertext-#{position}"),
        classification: :private,
        inventory_position: position,
        key_domain_id: @domain,
        lookup_digest: :crypto.hash(:sha256, "lookup-#{position}"),
        storage_ref: id(position + 10),
        vault_id: @owner
      }

      if mode == :canonical or (mode == :mixed and position == 1),
        do: %{entry | storage_ref: canonical(entry)},
        else: entry
    end
  end

  defp canonical(entry) do
    hex = Base.encode16(entry.lookup_digest, case: :lower)

    "objects/#{entry.vault_id}/#{entry.key_domain_id}/hmac-sha256/#{binary_part(hex, 0, 2)}/#{hex}"
  end

  defp id(n), do: "7100000a-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")

  defp assert_invalid(result) do
    assert {:error, %Error{code: code, message: nil, details: %{}, retryable?: false}} = result
    assert code in [:backup_invalid, :invalid, :integrity_failure, :conflict]
  end
end

defmodule Singularity.Storage.Backup.KnowledgeIntegrityInventorySQLTest do
  use ExUnit.Case, async: false

  alias Singularity.Core.Error
  alias Singularity.Storage.{LocalFilesystemAdapter, MigrationRepo, SafeSQL}

  alias Singularity.Storage.Backup.{
    BundleReader,
    IntegrityAudit,
    KnowledgeBackupFixtures,
    LocalDestination,
    LogicalBundleVerifier,
    Restorer
  }

  alias Singularity.Storage.Backup.KnowledgeBackupFixtures.FixtureCrypto
  alias Singularity.Storage.Crypto.Format

  @subject Singularity.Storage.Backup.KnowledgeIntegrityInventory
  @moduletag :integration
  @ids ~w(account_id principal_id vault_id session_id live_note_id deleted_note_id
    initial_note_version_id canonical_note_version_id competing_note_version_id
    merge_note_version_id open_competing_note_version_id deleted_note_version_id
    resolved_conflict_id open_conflict_id ready_document_id ready_old_version_id
    ready_current_version_id deleted_document_id deleted_document_version_id
    pending_document_id pending_version_id extracting_document_id extracting_version_id
    failed_document_id failed_version_id unsupported_document_id unsupported_version_id
    attachment_id citation_id deleted_attachment_id deleted_citation_id tag_id
    relationship_id pdf_object_id empty_object_id plain_object_id unicode_object_id
    markdown_object_id)a
       |> Enum.with_index(1)
       |> Map.new(fn {name, n} ->
         {name, "72000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")}
       end)
  @originals %{
    pdf: "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n",
    pdf_duplicate: "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n",
    empty: "",
    plain: "plain original\r\nsecond line\n",
    unicode: "界🙂 café\n",
    markdown: "# Original Markdown\n"
  }

  defmodule RecordingRepo do
    alias Singularity.Storage.{MigrationRepo, SafeSQL}
    def __adapter__, do: MigrationRepo.__adapter__()
    def get_dynamic_repo, do: MigrationRepo.get_dynamic_repo()
    def in_transaction?, do: MigrationRepo.in_transaction?()
    def rollback(reason), do: MigrationRepo.rollback(reason)
    def checkout(callback, options \\ []), do: MigrationRepo.checkout(callback, options)

    def transaction(callback, options \\ []) do
      with_native_sql_alias(fn -> transaction_with_witness(callback, options) end)
    end

    defp transaction_with_witness(callback, options) do
      nested = MigrationRepo.in_transaction?()

      MigrationRepo.transaction(
        fn ->
          if nested and Process.get({__MODULE__, :barrier}) do
            writer = Process.delete({__MODULE__, :barrier})
            send(writer, {:material_entry, self(), witness()})

            receive do
              {:material_writer_committed, connection} ->
                Process.put({__MODULE__, :writer}, connection)
            after
              5_000 -> raise "native material writer did not complete"
            end
          end

          result = callback.()
          observed = witness()

          Process.put({__MODULE__, :events}, [
            %{nested: nested, witness: observed} | Process.get({__MODULE__, :events}, [])
          ])

          result
        end,
        options
      )
    end

    # SafeSQL receives a registered repo name, not a module's get_dynamic_repo/0.
    # Alias only the real MigrationRepo metadata; no separate pool or SQL double.
    # The outer call owns this inert address, including cleanup on exceptions.
    defp with_native_sql_alias(callback) do
      case Process.get({__MODULE__, :sql_alias}) do
        nil ->
          {:ok, address} = Agent.start_link(fn -> nil end, name: __MODULE__)

          try do
            native_meta = Ecto.Adapter.lookup_meta(MigrationRepo.get_dynamic_repo())
            :ok = Ecto.Repo.Registry.associate(address, __MODULE__, native_meta)
            true = Ecto.Adapter.lookup_meta(__MODULE__) === native_meta
            Process.put({__MODULE__, :sql_alias}, address)
            callback.()
          after
            Process.delete({__MODULE__, :sql_alias})
            Agent.stop(address)
          end

        address ->
          true = Process.whereis(__MODULE__) === address

          true =
            Ecto.Adapter.lookup_meta(__MODULE__) ===
              Ecto.Adapter.lookup_meta(MigrationRepo.get_dynamic_repo())

          callback.()
      end
    end

    defp witness do
      %{rows: [[backend, snapshot, isolation, role, owner]]} =
        SafeSQL.query!(
          MigrationRepo,
          """
          SELECT pg_backend_pid(),txid_current_snapshot()::text,
            current_setting('transaction_isolation'),current_role::text,
            current_setting('singularity.vault_id',true)
          """,
          []
        )

      %{backend: backend, snapshot: snapshot, isolation: isolation, role: role, owner: owner}
    end
  end

  setup_all do
    portable =
      Path.join(System.tmp_dir!(), "knowledge-integrity-inventory-#{Ecto.UUID.generate()}")

    File.mkdir_p!(portable)
    File.chmod!(portable, 0o700)
    on_exit(fn -> File.rm_rf!(portable) end)

    sources =
      KnowledgeBackupFixtures.with_destination(:current, fn destination ->
        fixture =
          KnowledgeBackupFixtures.seed!(
            Map.merge(destination, %{ids: @ids, originals: @originals})
          )

        original = KnowledgeBackupFixtures.canonical_rows(fixture)
        assert length(original["content.asset_objects"]) == 5
        assert length(original["content.document_versions"]) == 7

        Map.new([:uuid, :canonical, :mixed], fn mode ->
          transform = fn rows ->
            Map.update!(rows, "content.asset_objects", fn objects ->
              Enum.with_index(objects)
              |> Enum.map(fn {object, index} ->
                if mode == :uuid or (mode == :mixed and rem(index, 2) == 0),
                  do: Map.replace!(object, "storage_ref", object["id"]),
                  else: object
              end)
            end)
          end

          assert {:ok, bundle} =
                   KnowledgeBackupFixtures.transformed_bundle(fixture, rows: transform)

          filename = bundle.binding.destination_ref
          File.cp!(Path.join(destination.object_root, filename), Path.join(portable, filename))
          File.chmod!(Path.join(portable, filename), 0o600)
          assert :ok = BundleReader.discard_verified(bundle.verified)

          {mode,
           %{
             portable: portable,
             filename: filename,
             binding: bundle.binding,
             database: destination.database,
             rows: transform.(original),
             mode: mode
           }}
        end)
      end)

    %{sources: sources}
  end

  for mode <- [:uuid, :canonical, :mixed] do
    test "real #{mode} import preserves original evidence and delegates unchanged wrapper material",
         ctx do
      with_import(ctx.sources[unquote(mode)], fn destination, storage, imported ->
        original = imported.object_inventory
        expected = Enum.map(original, &Map.replace!(&1, :storage_ref, &1.asset_object_id))
        assert imported.cut.object_inventory === original
        original_hash = inventory_hash(original)

        assert [[^original_hash, 5, "imported"]] =
                 owner(fn ->
                   sql("SELECT inventory_hash,object_count,state FROM audit.restore_import_sagas").rows
                 end)

        assert {:ok, %{inventory: ^expected, material_loader: {@subject, context}}} =
                 call(:prepare, [MigrationRepo, storage, imported])

        assert imported.object_inventory === original
        assert persisted_inventory() === original
        binding = lease_binding(imported)

        for entry <- expected do
          assert {:ok, native} =
                   owner(fn ->
                     IntegrityAudit.load_plaintext_material(MigrationRepo, binding, entry)
                   end)

          assert {:ok, ^native} = call(:load_plaintext_material, [context, binding, entry])
          assert native.object_id == entry.asset_object_id
          assert native.lookup_digest == entry.lookup_digest
          assert native.ciphertext_hash == entry.ciphertext_hash
          assert is_binary(native.wrapped_dek) and byte_size(native.wrapped_dek) > 0
          assert is_binary(native.wrapped_domain_key) and byte_size(native.wrapped_domain_key) > 0
          refute Map.has_key?(native, :vault_key)
          refute Map.has_key?(native, :dek)
        end

        assert Enum.count(original, &(&1.asset_object_id == @ids.pdf_object_id)) == 1

        assert [[nil, "deleted", true, true, object, version]] =
                 owner(fn ->
                   sql(
                     """
                     SELECT a.asset_object_id,a.state,ra.released_at IS NOT NULL,
                       r.deleted_at IS NOT NULL,d.source_object_id::text,d.source_resource_version_id::text
                     FROM content.document_versions d
                     JOIN content.assets a ON a.id=d.source_asset_id
                     JOIN content.resource_assets ra ON ra.asset_id=d.source_asset_id
                       AND ra.resource_version_id=d.source_resource_version_id
                     JOIN content.resources r ON r.id=d.source_resource_id
                     WHERE d.resource_version_id=$1
                     """,
                     [dump(@ids.ready_old_version_id)]
                   ).rows
                 end)

        assert object == @ids.pdf_object_id

        assert Enum.any?(
                 ctx.sources[unquote(mode)].rows["content.resource_versions"],
                 &(&1["id"] == version and &1["resource_id"] == id(300))
               )

        assert destination.database != ctx.sources[unquote(mode)].database

        assert [[^original_hash, 5, "imported"]] =
                 owner(fn ->
                   sql("SELECT inventory_hash,object_count,state FROM audit.restore_import_sagas").rows
                 end)
      end)
    end
  end

  test "cut and handoff disagreement rejects even when each separate inventory projects", ctx do
    with_import(ctx.sources.canonical, fn _destination, storage, imported ->
      altered =
        Enum.map(imported.object_inventory, &Map.replace!(&1, :storage_ref, &1.asset_object_id))

      assert {:ok, ^altered} = call(:project, [storage, imported.cut])
      changed = %{imported | object_inventory: altered}
      assert_invalid(call(:prepare, [MigrationRepo, storage, changed]))
      assert persisted_inventory() === imported.object_inventory
    end)
  end

  test "every original saga commitment is independently revalidated", ctx do
    with_import(ctx.sources.canonical, fn _destination, storage, imported ->
      before = saga()

      changes = [
        {"manifest_id", dump(Ecto.UUID.generate())},
        {"vault_id", dump(Ecto.UUID.generate())},
        {"manifest_hash", <<1::256>>},
        {"manifest_tag", <<2::128>>},
        {"inventory_hash", <<3::256>>},
        {"destination_root_hash", <<4::256>>},
        {"object_count", 4}
      ]

      for {field, changed} <- changes do
        original = before[field]

        assert %{num_rows: 1} =
                 owner(fn ->
                   sql("UPDATE audit.restore_import_sagas SET #{field}=$1", [changed])
                 end)

        assert saga()[field] == changed
        assert_invalid(call(:prepare, [MigrationRepo, storage, imported]))

        assert %{num_rows: 1} =
                 owner(fn ->
                   sql("UPDATE audit.restore_import_sagas SET #{field}=$1", [original])
                 end)

        assert saga() === before
      end

      owner(fn ->
        sql("UPDATE audit.restore_import_sagas SET state='pending',imported_at=NULL")
      end)

      assert saga()["state"] == "pending"
      assert_invalid(call(:prepare, [MigrationRepo, storage, imported]))

      owner(fn ->
        sql("UPDATE audit.restore_import_sagas SET state='imported',imported_at=$1", [
          before["imported_at"]
        ])
      end)

      assert saga() === before
    end)
  end

  test "trusted destination root binding rejects a different real local root but accepts expanded alias",
       ctx do
    with_import(ctx.sources.canonical, fn destination, storage, imported ->
      other = Path.join(destination.object_root, "different-root")
      File.mkdir_p!(other)
      File.chmod!(other, 0o700)

      assert_invalid(
        call(:prepare, [MigrationRepo, {LocalFilesystemAdapter, %{root: other}}, imported])
      )

      alias_root = Path.join([destination.object_root, ".", "unused", ".."])
      assert Path.expand(alias_root) == Path.expand(destination.object_root)

      assert {:ok, %{inventory: projected}} =
               call(:prepare, [
                 MigrationRepo,
                 {LocalFilesystemAdapter, %{root: alias_root}},
                 imported
               ])

      assert projected ==
               Enum.map(
                 imported.object_inventory,
                 &Map.replace!(&1, :storage_ref, &1.asset_object_id)
               )

      assert storage == {LocalFilesystemAdapter, %{root: destination.object_root}}
    end)
  end

  test "valid alternate persisted reference remains a mismatch rather than normalization", ctx do
    with_import(ctx.sources.canonical, fn _destination, storage, imported ->
      entry = hd(imported.object_inventory)

      assert {:ok, %{inventory: projected, material_loader: {@subject, context}}} =
               call(:prepare, [MigrationRepo, storage, imported])

      owner(fn ->
        sql("UPDATE content.asset_objects SET storage_ref=id::text WHERE id=$1", [
          dump(entry.asset_object_id)
        ])
      end)

      assert hd(persisted_inventory()).storage_ref == entry.asset_object_id
      assert_invalid(call(:prepare, [MigrationRepo, storage, imported]))

      assert_invalid(
        call(:load_plaintext_material, [context, lease_binding(imported), hd(projected)])
      )

      # The unchanged base loader alone cannot attest that original reference.
      assert {:ok, _material} =
               owner(fn ->
                 IntegrityAudit.load_plaintext_material(
                   MigrationRepo,
                   lease_binding(imported),
                   hd(projected)
                 )
               end)
    end)
  end

  test "changed persisted original metadata fails while every unchanged field remains witnessed",
       ctx do
    with_import(ctx.sources.uuid, fn _destination, storage, imported ->
      entry = hd(imported.object_inventory)

      mutations = [
        {"ciphertext_hash", <<91::256>>},
        {"lookup_digest", <<92::256>>},
        {"ciphertext_byte_size", entry.ciphertext_byte_size + 1}
      ]

      before = persisted_inventory()

      for {field, value} <- mutations do
        original = Map.fetch!(entry, String.to_existing_atom(field))

        owner(fn ->
          sql("UPDATE content.asset_objects SET #{field}=$1 WHERE id=$2", [
            value,
            dump(entry.asset_object_id)
          ])
        end)

        assert_invalid(call(:prepare, [MigrationRepo, storage, imported]))

        owner(fn ->
          sql("UPDATE content.asset_objects SET #{field}=$1 WHERE id=$2", [
            original,
            dump(entry.asset_object_id)
          ])
        end)

        assert persisted_inventory() === before
      end
    end)
  end

  test "required historical Document-only objects cannot be omitted with a coherent replacement saga",
       ctx do
    with_import(ctx.sources.canonical, fn _destination, storage, imported ->
      assert [[0]] =
               owner(fn ->
                 sql("SELECT count(*) FROM content.assets WHERE asset_object_id=$1", [
                   dump(@ids.pdf_object_id)
                 ]).rows
               end)

      assert [[count]] =
               owner(fn ->
                 sql("SELECT count(*) FROM content.document_versions WHERE source_object_id=$1", [
                   dump(@ids.pdf_object_id)
                 ]).rows
               end)

      assert count > 1

      missing =
        Enum.reject(imported.object_inventory, &(&1.asset_object_id == @ids.pdf_object_id))
        |> Enum.with_index()
        |> Enum.map(fn {entry, position} -> %{entry | inventory_position: position} end)

      changed = replace_inventory(imported, missing)

      owner(fn ->
        sql("UPDATE audit.restore_import_sagas SET inventory_hash=$1,object_count=$2", [
          inventory_hash(missing),
          length(missing)
        ])
      end)

      assert [[hash, 4]] =
               owner(fn ->
                 sql("SELECT inventory_hash,object_count FROM audit.restore_import_sagas").rows
               end)

      assert hash == inventory_hash(changed.object_inventory)
      assert changed.cut.object_inventory === changed.object_inventory
      assert {:ok, _projected} = call(:project, [storage, changed.cut])
      assert_invalid(call(:prepare, [MigrationRepo, storage, changed]))
      assert length(persisted_inventory()) == 5
    end)
  end

  test "a coherent disposable SQL-only extra object is not part of the required source closure",
       ctx do
    with_import(ctx.sources.uuid, fn _destination, storage, imported ->
      first = hd(imported.object_inventory)
      extra_id = "f2000000-0000-4000-8000-000000000001"

      extra = %{
        first
        | asset_object_id: extra_id,
          storage_ref: extra_id,
          lookup_digest: <<88::256>>,
          inventory_position: 5
      }

      assert %{num_rows: 1} =
               owner(fn ->
                 sql(
                   """
                   INSERT INTO content.asset_objects (
                     id,vault_id,key_domain_id,classification,lookup_digest,ciphertext_hash,
                     plaintext_byte_size,ciphertext_byte_size,storage_ref,format_version,lifecycle
                   ) SELECT $1,vault_id,key_domain_id,classification,$2,ciphertext_hash,
                     plaintext_byte_size,ciphertext_byte_size,$3,format_version,'available'
                   FROM content.asset_objects WHERE id=$4
                   """,
                   [
                     dump(extra_id),
                     extra.lookup_digest,
                     extra.storage_ref,
                     dump(first.asset_object_id)
                   ]
                 )
               end)

      assert [[0, 0]] =
               owner(fn ->
                 sql(
                   """
                   SELECT (SELECT count(*) FROM content.assets WHERE asset_object_id=$1),
                     (SELECT count(*) FROM content.document_versions WHERE source_object_id=$1)
                   """,
                   [dump(extra_id)]
                 ).rows
               end)

      replacement = imported.object_inventory ++ [extra]
      changed = replace_inventory(imported, replacement)

      owner(fn ->
        sql("UPDATE audit.restore_import_sagas SET inventory_hash=$1,object_count=$2", [
          inventory_hash(replacement),
          length(replacement)
        ])
      end)

      assert changed.cut.object_inventory === changed.object_inventory
      assert persisted_inventory() === replacement
      assert saga()["inventory_hash"] == inventory_hash(replacement)
      assert saga()["object_count"] == 6
      assert {:ok, ^replacement} = call(:project, [storage, changed.cut])
      assert_invalid(call(:prepare, [MigrationRepo, storage, changed]))
      # This mutation is a closure counterproof, never authenticated byte evidence.
    end)
  end

  test "all projected fields and exact positions are checked before the real base loader", ctx do
    with_import(ctx.sources.uuid, fn _destination, storage, imported ->
      assert {:ok, %{inventory: [first, second | _], material_loader: {@subject, context}}} =
               call(:prepare, [MigrationRepo, storage, imported])

      binding = lease_binding(imported)

      changes = [
        %{first | inventory_position: second.inventory_position},
        %{first | storage_ref: second.storage_ref},
        %{first | ciphertext_hash: <<0::256>>},
        %{first | ciphertext_byte_size: first.ciphertext_byte_size + 1},
        %{first | lookup_digest: <<0::256>>},
        %{first | key_domain_id: Ecto.UUID.generate()},
        %{first | vault_id: Ecto.UUID.generate()},
        %{first | classification: :restricted},
        Map.put(first, :authority, :migration)
      ]

      assert Enum.all?(changes, &(&1 !== first))

      assert_no_base_loader(fn ->
        for entry <- changes,
            do: assert_invalid(call(:load_plaintext_material, [context, binding, entry]))

        for field <- [:manifest_id, :vault_id, :vault_key_version_id] do
          changed = Map.replace!(binding, field, Ecto.UUID.generate())
          assert_invalid(call(:load_plaintext_material, [context, changed, first]))
        end

        for changed <- [
              Map.put(binding, :vault_key_generation, binding.vault_key_generation + 1),
              Map.put(binding, :vault_key_generation, 0),
              Map.put(binding, :raw_key, "NEVER-A-KEY"),
              Map.delete(binding, :manifest_id)
            ],
            do: assert_invalid(call(:load_plaintext_material, [context, changed, first]))
      end)
    end)
  end

  test "prepare and nested native material load share an actual owner connection and stable snapshot",
       ctx do
    with_import(ctx.sources.canonical, fn _destination, storage, imported ->
      Process.put({RecordingRepo, :events}, [])

      assert {:ok, %{inventory: [entry | _], material_loader: {@subject, context}}} =
               call(:prepare, [RecordingRepo, storage, imported])

      Process.put({RecordingRepo, :events}, [])

      assert {:ok, material} =
               call(:load_plaintext_material, [context, lease_binding(imported), entry])

      events = Process.get({RecordingRepo, :events})
      assert Enum.any?(events, & &1.nested)
      assert Enum.any?(events, &(not &1.nested))
      witnesses = Enum.map(events, & &1.witness)
      assert Enum.uniq(Enum.map(witnesses, & &1.backend)) |> length() == 1
      assert Enum.uniq(Enum.map(witnesses, & &1.snapshot)) |> length() == 1
      assert Enum.all?(witnesses, &(&1.role == "singularity_table_owner"))
      assert Enum.all?(witnesses, &(&1.isolation in ["repeatable read", "serializable"]))
      assert Enum.all?(witnesses, &(&1.owner == imported.cut.vault_id))
      assert material.object_id == entry.asset_object_id
      refute MigrationRepo.in_transaction?()
      assert %{rows: [["singularity_migration"]]} = sql("SELECT current_role::text")
    end)
  end

  test "a genuine concurrent metadata commit cannot split original validation from native material snapshot",
       ctx do
    with_import(ctx.sources.canonical, fn _destination, storage, imported ->
      assert {:ok, %{inventory: [entry | _], material_loader: {@subject, context}}} =
               call(:prepare, [RecordingRepo, storage, imported])

      assert {:ok, expected} =
               owner(fn ->
                 IntegrityAudit.load_plaintext_material(
                   MigrationRepo,
                   lease_binding(imported),
                   entry
                 )
               end)

      caller = self()

      config =
        Keyword.take(
          MigrationRepo.config(),
          [:hostname, :socket_dir, :port, :username, :password, :database, :ssl, :parameters]
        )

      writer =
        Task.async(fn ->
          {:ok, connection} = Postgrex.start_link(config)

          try do
            %{rows: [[backend]]} = Postgrex.query!(connection, "SELECT pg_backend_pid()", [])
            send(caller, {:native_writer_ready, self(), backend})

            receive do
              {:material_entry, reader, witness} ->
                assert witness.backend != backend
                assert witness.isolation in ["repeatable read", "serializable"]

                assert {:ok, :committed} =
                         Postgrex.transaction(connection, fn tx ->
                           Postgrex.query!(tx, "SET LOCAL ROLE singularity_table_owner", [])
                           Postgrex.query!(tx, "SET LOCAL lock_timeout='2s'", [])

                           assert %{num_rows: 1} =
                                    Postgrex.query!(
                                      tx,
                                      "UPDATE content.asset_objects SET ciphertext_hash=$1 WHERE id=$2",
                                      [<<77::256>>, dump(entry.asset_object_id)]
                                    )

                           :committed
                         end)

                send(reader, {:material_writer_committed, %{backend: backend, reader: witness}})
                :ok
            after
              5_000 -> flunk("native material entry barrier missing")
            end
          after
            GenServer.stop(connection)
          end
        end)

      assert_receive {:native_writer_ready, writer_pid, backend}, 5_000
      assert writer_pid == writer.pid
      Process.put({RecordingRepo, :barrier}, writer.pid)

      assert {:ok, ^expected} =
               call(:load_plaintext_material, [context, lease_binding(imported), entry])

      assert %{backend: ^backend, reader: witness} = Process.get({RecordingRepo, :writer})
      assert witness.backend != backend
      assert :ok = Task.await(writer, 5_000)
      assert_invalid(call(:load_plaintext_material, [context, lease_binding(imported), entry]))
      refute MigrationRepo.in_transaction?()
    end)
  end

  defp with_import(source, callback) do
    KnowledgeBackupFixtures.with_destination(:current, fn destination ->
      refute destination.database == source.database
      storage = {LocalFilesystemAdapter, %{root: destination.object_root}}

      assert {:ok, reader} =
               LocalDestination.reader_source(
                 %{backup_root: source.portable},
                 source.filename
               )

      crypto = %{
        key: :crypto.hash(:sha256, "knowledge-fixture-backup-key"),
        vault_id: @ids.vault_id,
        encryption_domain_id: id(902),
        object_id: id(900),
        chunk_index: 0,
        algorithm: Format.algorithm(),
        format_version: Format.format_version(),
        chunk_size: Format.chunk_size()
      }

      assert {:ok, verified} =
               BundleReader.authenticate_all(reader,
                 crypto: {FixtureCrypto, crypto},
                 verifier: {LogicalBundleVerifier, source.binding}
               )

      input = %{verified: verified, cut: verified.cut, binding: source.binding}
      assert {:ok, imported} = Restorer.import(%{object_storage: storage}, MigrationRepo, input)
      assert imported.cut.logical_version == 3
      assert length(imported.object_inventory) == 5
      assert persisted_inventory() === imported.object_inventory
      callback.(destination, storage, imported)
    end)
  end

  defp lease_binding(imported),
    do: %{
      manifest_id: imported.manifest.manifest_id,
      vault_id: imported.cut.vault_id,
      vault_key_version_id: imported.owner.vault_key_version_id,
      vault_key_generation: imported.owner.vault_key_generation
    }

  defp replace_inventory(imported, inventory) do
    # Actual verifier cut_result/2 intentionally omits the wire-only counts.
    refute Map.has_key?(imported.cut, :table_count_vector)
    refute Map.has_key?(imported.cut, :object_count)
    cut = %{imported.cut | object_inventory: inventory}
    %{imported | cut: cut, object_inventory: inventory}
  end

  defp persisted_inventory do
    owner(fn ->
      %{rows: rows} =
        sql("""
        SELECT id::text,vault_id::text,key_domain_id::text,classification,
          lookup_digest,ciphertext_hash,ciphertext_byte_size,storage_ref
        FROM content.asset_objects WHERE lifecycle='available' ORDER BY id
        """)

      rows
      |> Enum.with_index()
      |> Enum.map(fn {
                       [
                         object,
                         vault,
                         domain,
                         classification,
                         lookup,
                         ciphertext,
                         size,
                         reference
                       ],
                       position
                     } ->
        %{
          asset_object_id: object,
          vault_id: vault,
          key_domain_id: domain,
          classification: String.to_existing_atom(classification),
          lookup_digest: lookup,
          ciphertext_hash: ciphertext,
          ciphertext_byte_size: size,
          storage_ref: reference,
          inventory_position: position
        }
      end)
    end)
  end

  defp saga do
    owner(fn ->
      %{columns: columns, rows: [row]} = sql("SELECT * FROM audit.restore_import_sagas")
      Map.new(Enum.zip(columns, row))
    end)
  end

  defp inventory_hash(inventory),
    do:
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary(inventory, [:deterministic])
      )

  defp assert_no_base_loader(callback) do
    parent = self()
    assert IntegrityAudit == Code.ensure_loaded!(IntegrityAudit)
    {observer, monitor} = spawn_monitor(fn -> trace_loop(parent) end)

    assert 1 =
             :erlang.trace_pattern({IntegrityAudit, :load_plaintext_material, 3}, true, [:local])

    assert 1 = :erlang.trace(self(), true, [:call, :arity, {:tracer, observer}])

    try do
      callback.()
      reference = :erlang.trace_delivered(self())

      receive do
        {:trace_delivered, _, ^reference} -> :ok
      after
        5_000 -> flunk("base-loader arity-only trace did not drain")
      end

      send(observer, {:drain, self()})
      assert_receive :base_loader_trace_drained, 5_000
      refute_received :base_loader_called
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({IntegrityAudit, :load_plaintext_material, 3}, false, [:local])
      send(observer, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^observer, :normal}, 5_000
    end
  end

  defp trace_loop(parent) do
    receive do
      {:trace, _, :call, {IntegrityAudit, :load_plaintext_material, 3}} ->
        send(parent, :base_loader_called)
        trace_loop(parent)

      {:drain, caller} ->
        send(caller, :base_loader_trace_drained)
        trace_loop(parent)

      :stop ->
        :ok
    end
  end

  defp owner(callback) do
    assert {:ok, result} =
             MigrationRepo.transaction(fn ->
               sql("SET LOCAL ROLE singularity_table_owner")
               callback.()
             end)

    result
  end

  defp sql(statement, params \\ []), do: SafeSQL.query!(MigrationRepo, statement, params)

  defp call(function, arguments) do
    assert Code.ensure_loaded?(@subject), "missing concrete V3 two-view inventory adapter"
    assert function_exported?(@subject, function, length(arguments))
    apply(@subject, function, arguments)
  end

  defp dump(value), do: Ecto.UUID.dump!(value)
  defp id(n), do: "60000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")

  defp assert_invalid(result) do
    assert {:error, %Error{code: code, message: nil, details: %{}, retryable?: false}} = result
    assert code in [:backup_invalid, :invalid, :integrity_failure, :conflict]
  end
end
