defmodule Singularity.Storage.Backup.DocumentRestoreIntegritySizeTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.{Error, ObjectRef}
  alias Singularity.Storage.{AuthenticatedReader, LocalFilesystemAdapter}
  alias Singularity.Storage.Crypto.{ChunkedAEAD, Format}

  @subject Singularity.Storage.Backup.KnowledgeIntegrityInventory
  @moduletag :tmp_dir
  @owner "73000000-0000-4000-8000-000000000001"
  @domain "73000000-0000-4000-8000-000000000002"
  @vectors [
    {0, 134},
    {1, 159},
    {4_194_303, 4_194_461},
    {4_194_304, 4_194_462},
    {4_194_305, 4_194_487},
    {8_388_607, 8_388_789},
    {8_388_608, 8_388_790},
    {8_388_609, 8_388_815},
    {67_108_864, 67_109_382}
  ]

  test "format1 public constants independently fix the existing encoding" do
    assert Format.format_version() == 1
    assert Format.header_size() == 66
    assert Format.chunk_size() == 4_194_304
    assert Format.max_data_counter() == 0xFFFFFFFE
    assert Format.final_counter() == 0xFFFFFFFF
  end

  test "all nine independent literal plaintext and ciphertext vectors qualify" do
    for {plaintext, ciphertext} <- @vectors do
      assert :ok = size_result(plaintext, ciphertext)
    end
  end

  test "adjacent lengths and impossible chunk-boundary gaps deny" do
    for {plaintext, ciphertext} <- @vectors,
        wrong <- [ciphertext - 1, ciphertext + 1] do
      assert_invalid(size_result(plaintext, wrong))
    end

    for ciphertext <- 4_194_463..4_194_486,
        plaintext <- [4_194_304, 4_194_305] do
      assert_invalid(size_result(plaintext, ciphertext))
    end

    for ciphertext <- 8_388_791..8_388_814,
        plaintext <- [8_388_608, 8_388_609] do
      assert_invalid(size_result(plaintext, ciphertext))
    end
  end

  test "negative noninteger absent and counter-overflow sizes deny without allocation" do
    for plaintext <- [-1, nil, 1.0, "1", :missing, %{}, []] do
      assert_invalid(size_result(plaintext, 159))
    end

    for ciphertext <- [-1, nil, 159.0, "159", :missing, %{}, []] do
      assert_invalid(size_result(1, ciphertext))
    end

    # The pure seam is format-bounded, not Document's stricter 64MiB admission.
    maximum = 0xFFFFFFFF * 4_194_304
    assert :ok = size_result(maximum, 66 + maximum + 24 * 0xFFFFFFFF + 68)
    overflow = maximum + 1
    assert_invalid(size_result(overflow, 66 + overflow + 24 * 0x100000000 + 68))
  end

  for {plaintext_size, ciphertext_size} <- [
        {0, 134},
        {4_194_303, 4_194_461},
        {4_194_304, 4_194_462},
        {4_194_305, 4_194_487}
      ] do
    test "actual reader authenticates #{plaintext_size} bytes and literal ciphertext length",
         ctx do
      plaintext = :binary.copy("x", unquote(plaintext_size))
      key = :crypto.strong_rand_bytes(32)
      object = Ecto.UUID.generate()
      reference = %ObjectRef{object_id: object}
      lookup = Base.encode16(:crypto.hash(:sha256, object), case: :lower)

      context = %{
        root: ctx.tmp_dir,
        vault_namespace: @owner,
        domain_namespace: @domain,
        lookup_digest: lookup
      }

      assert {:ok, ciphertext} =
               ChunkedAEAD.encode(%{
                 key: key,
                 plaintext: plaintext,
                 vault_id: @owner,
                 encryption_domain_id: @domain,
                 object_id: object,
                 chunk_index: 0,
                 algorithm: Format.algorithm(),
                 format_version: Format.format_version(),
                 chunk_size: Format.chunk_size()
               })

      assert byte_size(ciphertext) == unquote(ciphertext_size)
      assert {:ok, stage} = LocalFilesystemAdapter.stage(context, %{})
      assert :ok = LocalFilesystemAdapter.append_encrypted_chunk(context, stage, ciphertext)
      assert {:ok, %{sealed?: true}} = LocalFilesystemAdapter.seal_stage(context, stage, %{})
      assert {:ok, ^reference} = LocalFilesystemAdapter.finalize(context, stage, reference)

      binding = %{
        object_ref: reference,
        object_id: object,
        vault_id: @owner,
        encryption_domain_id: @domain,
        plaintext_byte_size: unquote(plaintext_size),
        ciphertext_byte_size: unquote(ciphertext_size),
        format_version: 1
      }

      storage = %{adapter: LocalFilesystemAdapter, context: context}
      assert {:ok, ^plaintext} = AuthenticatedReader.read(storage, binding, key, :all)
      expected = %{sha256: :crypto.hash(:sha256, plaintext), byte_size: unquote(plaintext_size)}
      assert {:ok, ^expected} = AuthenticatedReader.digest(storage, binding, key)
    end
  end

  defp size_result(plaintext, ciphertext) do
    assert Code.ensure_loaded?(@subject)

    assert function_exported?(@subject, :validate_plaintext_size, 2),
           "missing internal format1 size-law seam"

    apply(@subject, :validate_plaintext_size, [plaintext, ciphertext])
  end

  defp assert_invalid(result) do
    assert {:error, %Error{message: nil, details: %{}, retryable?: false}} = result
  end
end

defmodule Singularity.Storage.Backup.DocumentRestoreIntegritySQLTest do
  use ExUnit.Case, async: false

  alias Singularity.Core.{DocumentFragment, Error, ObjectRef}
  alias Singularity.Storage.{AuthenticatedReader, LocalFilesystemAdapter, MigrationRepo, SafeSQL}

  alias Singularity.Storage.Backup.{
    BundleReader,
    IntegrityAudit,
    KnowledgeBackupFixtures,
    LocalDestination,
    LogicalBundleVerifier,
    Restorer
  }

  alias Singularity.Storage.Backup.KnowledgeBackupFixtures.FixtureCrypto
  alias Singularity.Storage.Crypto.{Format, KeyWrapper}

  @subject Singularity.Storage.Backup.KnowledgeIntegrityInventory
  @lease Singularity.Runtime.RestoreIntegrityLease
  @moduletag :integration
  @ids ~w(account_id principal_id vault_id session_id live_note_id deleted_note_id
    initial_note_version_id canonical_note_version_id competing_note_version_id
    merge_note_version_id open_competing_note_version_id deleted_note_version_id
    resolved_conflict_id open_conflict_id ready_document_id ready_old_version_id
    ready_current_version_id deleted_document_id deleted_document_version_id
    pending_document_id pending_version_id extracting_document_id extracting_version_id
    failed_document_id failed_version_id unsupported_document_id unsupported_version_id
    attachment_id citation_id deleted_attachment_id deleted_citation_id tag_id
    relationship_id pdf_object_id empty_object_id plain_object_id unicode_object_id markdown_object_id)a
       |> Enum.with_index(1)
       |> Map.new(fn {name, n} ->
         {name, "74000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")}
       end)
  @originals %{
    pdf: "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n",
    pdf_duplicate: "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n",
    empty: "",
    plain: "plain original\r\nsecond line\n",
    unicode: "界🙂 café\n",
    markdown: "# Original Markdown\n"
  }

  setup_all do
    portable = Path.join(System.tmp_dir!(), "document-integrity-#{Ecto.UUID.generate()}")
    File.mkdir_p!(portable)
    File.chmod!(portable, 0o700)
    on_exit(fn -> File.rm_rf!(portable) end)

    sources =
      KnowledgeBackupFixtures.with_destination(:current, fn destination ->
        fixture =
          KnowledgeBackupFixtures.seed!(
            Map.merge(destination, %{ids: @ids, originals: @originals})
          )

        rows = KnowledgeBackupFixtures.canonical_rows(fixture)
        bytes = KnowledgeBackupFixtures.source_bytes(fixture)
        assert length(rows["content.document_versions"]) == 7
        assert map_size(bytes) == 5

        variants = [
          canonical: &Function.identity/1,
          uuid: &references(&1, :uuid),
          mixed: &references(&1, :mixed),
          wrong_digest: &source_digest/1,
          wrong_size: &source_size/1,
          asset_only: &asset_only/1
        ]

        Map.new(variants, fn {name, transform} ->
          result =
            if name == :canonical,
              do:
                {:ok,
                 KnowledgeBackupFixtures.verified_bundle(fixture,
                   logical_version: 3,
                   mode: :replay
                 )},
              else: KnowledgeBackupFixtures.transformed_bundle(fixture, rows: transform)

          assert {:ok, bundle} = result
          filename = bundle.binding.destination_ref
          File.cp!(Path.join(destination.object_root, filename), Path.join(portable, filename))
          File.chmod!(Path.join(portable, filename), 0o600)
          assert :ok = BundleReader.discard_verified(bundle.verified)

          {name,
           %{
             portable: portable,
             filename: filename,
             binding: bundle.binding,
             source_database: destination.database,
             source_root: destination.object_root,
             rows: transform.(rows),
             bytes: bytes,
             vault_key: fixture.keys.vault_key
           }}
        end)
      end)

    %{sources: sources}
  end

  for mode <- [:uuid, :canonical, :mixed] do
    test "committed #{mode} restore verifies all seven historical states and Document-only PDF",
         ctx do
      with_import(ctx.sources[unquote(mode)], fn destination, imported, hashes ->
        versions =
          owner(fn ->
            sql(
              "SELECT resource_version_id::text,state FROM content.document_versions ORDER BY resource_version_id"
            ).rows
          end)

        assert Enum.sort(versions) ==
                 Enum.sort([
                   [@ids.ready_old_version_id, "ready"],
                   [@ids.ready_current_version_id, "ready"],
                   [@ids.deleted_document_version_id, "ready"],
                   [@ids.pending_version_id, "pending"],
                   [@ids.extracting_version_id, "extracting"],
                   [@ids.failed_version_id, "failed"],
                   [@ids.unsupported_version_id, "unsupported"]
                 ])

        assert [[0, 3]] =
                 owner(fn ->
                   sql(
                     """
                     SELECT (SELECT count(*) FROM content.assets WHERE asset_object_id=$1),
                       (SELECT count(*) FROM content.document_versions WHERE source_object_id=$1)
                     """,
                     [dump(@ids.pdf_object_id)]
                   ).rows
                 end)

        assert [[true, true]] =
                 owner(fn ->
                   sql(
                     """
                     SELECT old.resource_version_id<>r.current_version_id,deleted.deleted_at IS NOT NULL
                     FROM content.document_versions old JOIN content.resources r ON r.id=old.resource_id
                     CROSS JOIN content.resources deleted WHERE old.resource_version_id=$1 AND deleted.id=$2
                     """,
                     [dump(@ids.ready_old_version_id), dump(@ids.deleted_document_id)]
                   ).rows
                 end)

        assert :ok = verify(imported, hashes)
        assert_retained(destination, imported)
      end)
    end
  end

  test "Asset-only original remains covered while every retained target row is preserved", ctx do
    original = ctx.sources.canonical.rows
    changed = ctx.sources.asset_only.rows

    for table <- [
          "content.assets",
          "content.resource_assets",
          "content.asset_objects",
          "content.asset_key_envelopes",
          "content.note_attachments",
          "content.note_citations",
          "content.note_versions"
        ] do
      assert changed[table] === original[table]
    end

    with_import(ctx.sources.asset_only, fn destination, imported, hashes ->
      assert [[0, 1]] =
               owner(fn ->
                 sql(
                   """
                   SELECT (SELECT count(*) FROM content.document_versions WHERE source_object_id=$1),
                     (SELECT count(*) FROM content.assets WHERE asset_object_id=$1 AND state='available')
                   """,
                   [dump(@ids.markdown_object_id)]
                 ).rows
               end)

      assert Enum.any?(hashes, &(&1.asset_object_id == @ids.markdown_object_id))
      assert :ok = verify(imported, hashes)
      assert_retained(destination, imported)
    end)
  end

  test "coherently wrong immutable source digests import and authenticate before helper denial",
       ctx do
    with_import(ctx.sources.wrong_digest, fn destination, imported, hashes ->
      actual = Enum.find(hashes, &(&1.asset_object_id == @ids.pdf_object_id)).sha256
      assert actual == :crypto.hash(:sha256, @originals.pdf)
      assert actual != <<0::256>>

      assert [[3, 1, [<<0::256>>]]] =
               owner(fn ->
                 sql(
                   """
                   SELECT count(*),count(DISTINCT source_digest),array_agg(DISTINCT source_digest)
                   FROM content.document_versions WHERE source_object_id=$1
                   """,
                   [dump(@ids.pdf_object_id)]
                 ).rows
               end)

      assert_invalid(verify(imported, hashes))
      assert_retained(destination, imported)
    end)
  end

  test "immutable ciphertext length defeats matching wrong Document and current Object sizes after real reads",
       ctx do
    source = ctx.sources.wrong_size

    with_import(
      source,
      fn destination, imported, _hashes ->
        original = imported.object_inventory
        before = persisted_inventory()
        actual_size = byte_size(@originals.pdf)
        wrong_size = actual_size + 1

        assert [[^wrong_size, ^wrong_size, 3]] =
                 owner(fn ->
                   sql(
                     """
                     SELECT o.plaintext_byte_size,min(d.source_byte_size),count(*)
                     FROM content.asset_objects o JOIN content.document_versions d ON d.source_object_id=o.id
                     WHERE o.id=$1 GROUP BY o.plaintext_byte_size
                     """,
                     [dump(@ids.pdf_object_id)]
                   ).rows
                 end)

        assert :corrected =
                 owner(fn ->
                   assert %{num_rows: 1, rows: [[^actual_size]]} =
                            sql(
                              "UPDATE content.asset_objects SET plaintext_byte_size=$2 WHERE id=$1 RETURNING plaintext_byte_size",
                              [dump(@ids.pdf_object_id), actual_size]
                            )

                   :corrected
                 end)

        assert [[^actual_size]] =
                 owner(fn ->
                   sql("SELECT plaintext_byte_size FROM content.asset_objects WHERE id=$1", [
                     dump(@ids.pdf_object_id)
                   ]).rows
                 end)

        hashes = native_hashes(destination, imported, source)
        lease_hashes = native_lease_hashes(destination, imported, source)
        assert lease_hashes === hashes

        assert :restored_wrong =
                 owner(fn ->
                   assert %{num_rows: 1, rows: [[^wrong_size]]} =
                            sql(
                              "UPDATE content.asset_objects SET plaintext_byte_size=$2 WHERE id=$1 RETURNING plaintext_byte_size",
                              [dump(@ids.pdf_object_id), wrong_size]
                            )

                   :restored_wrong
                 end)

        assert [[^wrong_size, ^wrong_size, 3]] =
                 owner(fn ->
                   sql(
                     """
                     SELECT o.plaintext_byte_size,min(d.source_byte_size),count(*)
                     FROM content.asset_objects o JOIN content.document_versions d ON d.source_object_id=o.id
                     WHERE o.id=$1 GROUP BY o.plaintext_byte_size
                     """,
                     [dump(@ids.pdf_object_id)]
                   ).rows
                 end)

        assert persisted_inventory() === before
        assert imported.object_inventory === original
        entry = Enum.find(original, &(&1.asset_object_id == @ids.pdf_object_id))
        assert entry.ciphertext_byte_size == 66 + actual_size + 24 + 68
        refute entry.ciphertext_byte_size == 66 + wrong_size + 24 + 68
        assert_invalid(verify(imported, hashes))
        assert_retained(destination, imported)
      end,
      authenticate: false
    )
  end

  test "postcommit exact ordered hash closure rejects missing duplicate extra reordered and malformed pairs",
       ctx do
    with_import(ctx.sources.canonical, fn destination, imported, hashes ->
      assert :ok = verify(imported, hashes)
      [first, second | rest] = hashes

      variants = [
        tl(hashes),
        hashes ++ [first],
        [first, first | rest],
        [second, first | rest],
        hashes ++ [%{asset_object_id: id(990), sha256: <<0::256>>}],
        [Map.put(first, :byte_size, 1), second | rest],
        [Map.delete(first, :sha256), second | rest],
        [%{first | sha256: <<0>>}, second | rest],
        [%{first | sha256: nil}, second | rest],
        [%{first | asset_object_id: "7400000A-0000-4000-8000-000000000001"}, second | rest],
        nil,
        %{}
      ]

      for invalid <- variants do
        assert_invalid(verify(imported, invalid))
        assert_retained(destination, imported)
      end
    end)
  end

  test "only exact owner manifest binding and original nine-field inventory are accepted", ctx do
    with_import(ctx.sources.canonical, fn destination, imported, hashes ->
      assert :ok = verify(imported, hashes)
      binding = document_binding(imported)

      for changed <- [
            Map.put(binding, :vault_id, id(990)),
            Map.put(binding, :manifest_id, id(991)),
            Map.put(binding, :vault_key_generation, 1),
            Map.delete(binding, :vault_id),
            nil
          ] do
        assert_invalid(
          call(:verify_document_sources, [
            MigrationRepo,
            changed,
            imported.object_inventory,
            hashes
          ])
        )
      end

      [first, second | rest] = imported.object_inventory

      projected =
        Enum.map(imported.object_inventory, &Map.replace!(&1, :storage_ref, &1.asset_object_id))

      refute projected === imported.object_inventory

      for changed <- [
            projected,
            [second, first | rest],
            [first, first | rest],
            [Map.put(first, :plaintext_byte_size, 1), second | rest],
            [Map.delete(first, :ciphertext_hash), second | rest],
            [%{first | inventory_position: 1}, second | rest],
            [%{first | lookup_digest: <<0>>}, second | rest],
            [%{first | storage_ref: "objects/../invalid"}, second | rest]
          ] do
        assert_invalid(call(:verify_document_sources, [MigrationRepo, binding, changed, hashes]))
      end

      assert_retained(destination, imported)
    end)
  end

  test "changed persisted original reference denies even when replacement is an accepted UUID form",
       ctx do
    with_import(ctx.sources.canonical, fn destination, imported, hashes ->
      assert :ok = verify(imported, hashes)
      [entry | _] = imported.object_inventory
      assert entry.storage_ref != entry.asset_object_id

      owner(fn ->
        assert %{num_rows: 1} =
                 sql("UPDATE content.asset_objects SET storage_ref=id::text WHERE id=$1", [
                   dump(entry.asset_object_id)
                 ])
      end)

      assert_invalid(verify(imported, hashes))

      owner(fn ->
        assert %{num_rows: 1} =
                 sql("UPDATE content.asset_objects SET storage_ref=$2 WHERE id=$1", [
                   dump(entry.asset_object_id),
                   entry.storage_ref
                 ])
      end)

      assert persisted_inventory() === imported.object_inventory
      assert :ok = verify(imported, hashes)
      assert_retained(destination, imported)
    end)
  end

  test "one old ready nonhead canonical fragment mutation commits with exact guard restoration and helper denial",
       ctx do
    with_import(ctx.sources.canonical, fn destination, imported, hashes ->
      assert :ok = verify(imported, hashes)
      old = historical_fragment()
      assert old["ordinal"] == 1

      assert [["ready", true]] =
               owner(fn ->
                 sql(
                   """
                   SELECT d.state,d.resource_version_id<>r.current_version_id FROM content.document_versions d
                   JOIN content.resources r ON r.id=d.resource_id WHERE d.resource_version_id=$1
                   """,
                   [dump(@ids.ready_old_version_id)]
                 ).rows
               end)

      assert_unreferenced(old)
      snapshot = protections()
      assert_guards(snapshot)
      assert_immutable(old)
      assert protections() === snapshot

      assert {:ok, replacement} =
               DocumentFragment.new(%{
                 resource_id: old["resource_id"],
                 resource_version_id: old["resource_version_id"],
                 owner_scope_id: old["vault_id"],
                 classification: :private,
                 ordinal: old["ordinal"],
                 text: "historical replacement\n",
                 locator: old["locator"]
               })

      refute replacement.fragment_id == old["id"]
      refute replacement.digest == old["digest"]

      # This rollback proves transactional DDL and data restoration on the same
      # single-guard injection path before observing a genuine later COMMIT.
      assert {:error, :injected_failure} =
               MigrationRepo.transaction(fn ->
                 sql("SET LOCAL ROLE singularity_table_owner")
                 mutate_fragment(old, replacement, true)
               end)

      refute MigrationRepo.in_transaction?()
      assert historical_fragment() === old
      assert protections() === snapshot
      assert_immutable(old)

      try do
        assert :mutation_committed =
                 owner(fn ->
                   mutate_fragment(old, replacement)
                   :mutation_committed
                 end)
      after
        # Native transaction failures must also restore every database protection.
        assert protections() === snapshot
      end

      refute MigrationRepo.in_transaction?()
      changed = historical_fragment()

      assert changed ===
               Map.merge(old, %{
                 "id" => replacement.fragment_id,
                 "text" => replacement.text,
                 "digest" => replacement.digest
               })

      assert protections() === snapshot
      assert_immutable(changed)
      assert protections() === snapshot

      assert [[false]] =
               owner(fn ->
                 sql(
                   """
                   SELECT sha256(convert_to(string_agg(f.text,'' ORDER BY f.ordinal),'UTF8'))=d.extracted_text_digest
                   FROM content.document_versions d JOIN content.document_fragments f ON f.resource_version_id=d.resource_version_id
                   WHERE d.resource_version_id=$1 GROUP BY d.extracted_text_digest
                   """,
                   [dump(@ids.ready_old_version_id)]
                 ).rows
               end)

      assert persisted_inventory() === imported.object_inventory
      assert native_hashes(destination, imported, ctx.sources.canonical) === hashes
      # Own fresh helper transaction: neither nesting nor import/lifecycle rejection.
      assert_invalid(verify(imported, hashes))
      assert_retained(destination, imported)
    end)
  end

  defp with_import(source, callback, options \\ []) do
    KnowledgeBackupFixtures.with_destination(:current, fn destination ->
      refute destination.database == source.source_database
      refute File.exists?(source.source_root)

      assert [[0, 0, 0]] =
               owner(fn ->
                 sql("""
                 SELECT (SELECT count(*) FROM core.vaults),(SELECT count(*) FROM content.asset_objects),
                   (SELECT count(*) FROM audit.restore_import_sagas)
                 """).rows
               end)

      assert {:ok, reader} =
               LocalDestination.reader_source(%{backup_root: source.portable}, source.filename)

      {reader, snapshot_closes} = observe_snapshot_close(reader)

      crypto = %{
        key: :crypto.hash(:sha256, "knowledge-fixture-backup-key"),
        vault_id: @ids.vault_id,
        encryption_domain_id: id(902),
        object_id: source.binding.manifest_id,
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

      try do
        assert_snapshot_closes(snapshot_closes, 0)
        storage = {LocalFilesystemAdapter, %{root: destination.object_root}}

        assert {:ok, imported} =
                 Restorer.import(%{object_storage: storage}, MigrationRepo, %{
                   verified: verified,
                   cut: verified.cut,
                   binding: source.binding
                 })

        assert_snapshot_closes(snapshot_closes, 1)
        assert imported.cut.logical_version == 3
        assert imported.cut.object_inventory === imported.object_inventory
        assert length(imported.object_inventory) == 5
        assert Enum.all?(imported.object_inventory, &(map_size(&1) == 9))
        refute MigrationRepo.in_transaction?()
        assert persisted_inventory() === imported.object_inventory

        restored =
          KnowledgeBackupFixtures.canonical_rows(%{
            owner: Map.take(@ids, [:account_id, :vault_id])
          })

        for table <- [
              "content.resources",
              "content.resource_versions",
              "content.assets",
              "content.resource_assets",
              "content.asset_objects",
              "content.document_versions",
              "content.document_fragments",
              "content.document_import_receipts",
              "content.note_attachments",
              "content.note_citations"
            ] do
          assert restored[table] === source.rows[table],
                 "committed canonical mismatch in #{table}"
        end

        assert_retained(destination, imported)

        hashes =
          if Keyword.get(options, :authenticate, true),
            do: native_hashes(destination, imported, source),
            else: nil

        callback.(destination, imported, hashes)
      after
        if :atomics.get(snapshot_closes, 1) == 0 do
          assert :ok = BundleReader.discard_verified(verified)
        end

        assert_snapshot_closes(snapshot_closes, 1)
      end
    end)
  end

  defp observe_snapshot_close(reader) do
    owner = self()
    counts = :atomics.new(2, signed: false)
    native_close = reader.file_system.close_snapshot

    observed_close = fn snapshot ->
      result = native_close.(snapshot)

      if result === :ok do
        :atomics.add(counts, 1, 1)
        if self() != owner, do: :atomics.add(counts, 2, 1)
      end

      result
    end

    {%{reader | file_system: %{reader.file_system | close_snapshot: observed_close}}, counts}
  end

  defp assert_snapshot_closes(counts, expected) do
    assert :atomics.get(counts, 1) == expected
    assert :atomics.get(counts, 2) == 0
  end

  defp native_hashes(destination, imported, source) do
    Enum.map(imported.object_inventory, fn original ->
      projected = %{original | storage_ref: original.asset_object_id}

      assert {:ok, material} =
               IntegrityAudit.load_plaintext_material(
                 MigrationRepo,
                 lease_binding(imported),
                 projected
               )

      assert {:ok, domain_key} =
               KeyWrapper.unwrap(source.vault_key, material.wrapped_domain_key, %{
                 purpose: :domain_key,
                 generation: material.domain_key_generation,
                 aad: material.vault_id <> ":" <> material.key_domain_id
               })

      assert {:ok, dek} =
               KeyWrapper.unwrap(domain_key, material.wrapped_dek, %{
                 purpose: :object_dek,
                 generation: material.object_generation,
                 aad: "object:" <> material.object_id
               })

      reader_storage = %{
        adapter: LocalFilesystemAdapter,
        context: %{
          root: destination.object_root,
          vault_namespace: original.vault_id,
          domain_namespace: original.key_domain_id,
          lookup_digest: Base.encode16(original.lookup_digest, case: :lower),
          ciphertext_hash: original.ciphertext_hash
        }
      }

      reader_binding = %{
        object_ref: %ObjectRef{object_id: original.asset_object_id},
        object_id: material.object_id,
        vault_id: material.vault_id,
        encryption_domain_id: material.key_domain_id,
        plaintext_byte_size: material.plaintext_byte_size,
        ciphertext_byte_size: material.ciphertext_byte_size,
        format_version: material.format_version
      }

      expected = Map.fetch!(source.bytes, original.asset_object_id)

      assert {:ok, ^expected} =
               AuthenticatedReader.read(reader_storage, reader_binding, dek, :all)

      digest = %{sha256: :crypto.hash(:sha256, expected), byte_size: byte_size(expected)}
      assert {:ok, ^digest} = AuthenticatedReader.digest(reader_storage, reader_binding, dek)
      assert reader_binding.ciphertext_byte_size == original.ciphertext_byte_size
      %{asset_object_id: original.asset_object_id, sha256: digest.sha256}
    end)
  end

  defp native_lease_hashes(destination, imported, source) do
    storage = {LocalFilesystemAdapter, %{root: destination.object_root}}
    assert {:ok, prepared} = call(:prepare, [MigrationRepo, storage, imported])

    assert Code.ensure_loaded?(@lease),
           "native lease witness must not use a recording replacement"

    options = %{
      binding: lease_binding(imported),
      inventory: prepared.inventory,
      material_loader: prepared.material_loader,
      object_storage: storage,
      key_wrapper: KeyWrapper,
      owner: self(),
      ttl_ms: 5_000,
      vault_key: source.vault_key
    }

    assert {:ok, capability} = apply(@lease, :issue, [options])

    try do
      assert {:ok, summary} = apply(@lease, :verify_all, [capability])
      assert summary.__struct__ == Module.concat(@lease, PlaintextSummary)
      assert summary.vault_id == imported.cut.vault_id
      assert summary.object_count == 5

      assert {:ok, digest} =
               IntegrityAudit.inventory_sha256(imported.cut.vault_id, prepared.inventory)

      assert summary.inventory_sha256 == digest
      summary.plaintext_hashes
    after
      assert :ok = apply(@lease, :revoke, [capability])
    end
  end

  defp references(rows, mode) do
    Map.update!(rows, "content.asset_objects", fn objects ->
      objects
      |> Enum.with_index()
      |> Enum.map(fn {object, index} ->
        if mode == :uuid or rem(index, 2) == 0,
          do: Map.replace!(object, "storage_ref", object["id"]),
          else: object
      end)
    end)
  end

  defp source_digest(rows) do
    Map.update!(rows, "content.document_versions", fn documents ->
      Enum.map(documents, fn document ->
        if document["source_object_id"] == @ids.pdf_object_id,
          do: Map.replace!(document, "source_digest", <<0::256>>),
          else: document
      end)
    end)
  end

  defp source_size(rows) do
    wrong = byte_size(@originals.pdf) + 1

    rows
    |> Map.update!("content.document_versions", fn documents ->
      Enum.map(documents, fn document ->
        if document["source_object_id"] == @ids.pdf_object_id,
          do: Map.replace!(document, "source_byte_size", wrong),
          else: document
      end)
    end)
    |> Map.update!("content.asset_objects", fn objects ->
      Enum.map(objects, fn object ->
        if object["id"] == @ids.pdf_object_id,
          do: Map.replace!(object, "plaintext_byte_size", wrong),
          else: object
      end)
    end)
  end

  defp asset_only(rows) do
    # Remove only the unreferenced unsupported Document; its original Asset and
    # all Note attachment/citation target rows stay present byte-for-byte.
    for {table, field, id} <- [
          {"content.document_versions", "resource_version_id", @ids.unsupported_version_id},
          {"content.document_import_receipts", "version_id", @ids.unsupported_version_id},
          {"content.resource_versions", "id", @ids.unsupported_version_id},
          {"content.resources", "id", @ids.unsupported_document_id}
        ],
        reduce: rows do
      acc -> Map.update!(acc, table, &Enum.reject(&1, fn row -> row[field] == id end))
    end
  end

  defp document_binding(imported),
    do: %{manifest_id: imported.manifest.manifest_id, vault_id: imported.cut.vault_id}

  defp lease_binding(imported),
    do:
      Map.merge(document_binding(imported), %{
        vault_key_version_id: imported.owner.vault_key_version_id,
        vault_key_generation: imported.owner.vault_key_generation
      })

  defp verify(imported, hashes) do
    refute MigrationRepo.in_transaction?()

    call(:verify_document_sources, [
      MigrationRepo,
      document_binding(imported),
      imported.object_inventory,
      hashes
    ])
  end

  defp assert_retained(destination, imported) do
    original_hash =
      :crypto.hash(:sha256, :erlang.term_to_binary(imported.object_inventory, [:deterministic]))

    manifest = imported.manifest.manifest_id
    owner_id = imported.cut.vault_id

    assert [[^manifest, ^owner_id, "imported", 5, ^original_hash, true, nil, nil]] =
             owner(fn ->
               sql("""
               SELECT manifest_id::text,vault_id::text,state,object_count,inventory_hash,imported_at IS NOT NULL,
                 verified_at,completed_at
               FROM audit.restore_import_sagas
               """).rows
             end)

    assert [[0]] =
             owner(fn ->
               sql(
                 "SELECT count(*) FROM audit.events WHERE operation='integrity.audit_completed'"
               ).rows
             end)

    assert [[false]] =
             owner(fn ->
               sql("SELECT audit.knowledge_restore_is_bound($1)", [dump(owner_id)]).rows
             end)

    assert Application.get_env(:singularity_storage, :storage_root) == destination.object_root
    # The native disposable destination has no dispatching Runtime application.
    refute Enum.any?(Application.started_applications(), &(elem(&1, 0) == :singularity_runtime))
  end

  defp persisted_inventory do
    owner(fn ->
      sql("""
      SELECT id::text,vault_id::text,key_domain_id::text,classification,lookup_digest,
        ciphertext_hash,ciphertext_byte_size,storage_ref FROM content.asset_objects
      WHERE lifecycle='available' ORDER BY id
      """).rows
      |> Enum.with_index()
      |> Enum.map(fn {[object, vault, domain, classification, lookup, hash, size, reference],
                      position} ->
        %{
          asset_object_id: object,
          vault_id: vault,
          key_domain_id: domain,
          classification: String.to_existing_atom(classification),
          lookup_digest: lookup,
          ciphertext_hash: hash,
          ciphertext_byte_size: size,
          storage_ref: reference,
          inventory_position: position
        }
      end)
    end)
  end

  defp historical_fragment do
    owner(fn ->
      result =
        sql(
          """
          SELECT id,resource_id::text,resource_version_id::text,vault_id::text,classification,
            ordinal,text,digest,locator,inserted_at FROM content.document_fragments
          WHERE resource_version_id=$1 AND ordinal=1
          """,
          [dump(@ids.ready_old_version_id)]
        )

      assert [row] = result.rows
      Map.new(Enum.zip(result.columns, row))
    end)
  end

  defp assert_unreferenced(fragment) do
    owner(fn ->
      foreign_keys =
        sql("""
        SELECT n.nspname,c.relname,k.conname,array_agg(a.attname ORDER BY pair.ordinality),
          array_agg(b.attname ORDER BY pair.ordinality)
        FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid
        JOIN pg_namespace n ON n.oid=c.relnamespace
        CROSS JOIN LATERAL unnest(k.conkey,k.confkey) WITH ORDINALITY pair(local_key,target_key,ordinality)
        JOIN pg_attribute a ON a.attrelid=k.conrelid AND a.attnum=pair.local_key
        JOIN pg_attribute b ON b.attrelid=k.confrelid AND b.attnum=pair.target_key
        WHERE k.contype='f' AND k.confrelid='content.document_fragments'::regclass
        GROUP BY n.nspname,c.relname,k.conname ORDER BY n.nspname,c.relname,k.conname
        """).rows

      assert Enum.any?(foreign_keys, fn [schema, table | _] ->
               schema == "content" and table == "note_citations"
             end)

      assert Enum.any?(foreign_keys, fn [schema, table | _] ->
               schema == "content" and table == "search_entries"
             end)

      for [schema, table, _constraint, local_columns, target_columns] <- foreign_keys do
        params =
          Enum.map(target_columns, fn field ->
            value = Map.fetch!(fragment, field)

            if field in ["resource_id", "resource_version_id", "vault_id"],
              do: dump(value),
              else: value
          end)

        predicate =
          local_columns
          |> Enum.with_index(1)
          |> Enum.map_join(" AND ", fn {column, index} ->
            quote_identifier(column) <> "=$#{index}"
          end)

        assert [[0]] =
                 sql(
                   "SELECT count(*) FROM #{quote_identifier(schema)}.#{quote_identifier(table)} WHERE #{predicate}",
                   params
                 ).rows
      end
    end)
  end

  defp protections do
    owner(fn ->
      triggers =
        sql("""
        SELECT n.nspname,c.relname,t.tgname,t.tgenabled::text,pg_get_triggerdef(t.oid,true),
          pg_get_functiondef(t.tgfoid),pg_get_userbyid(p.proowner),p.proacl::text
        FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
        JOIN pg_namespace n ON n.oid=c.relnamespace
        JOIN pg_proc p ON p.oid=t.tgfoid
        WHERE NOT t.tgisinternal AND t.tgrelid IN ('content.document_versions'::regclass,
          'content.document_fragments'::regclass,'audit.knowledge_restore_admissions'::regclass)
        ORDER BY n.nspname,c.relname,t.tgname
        """).rows

      tables =
        sql("""
        SELECT c.oid::regclass::text,c.relrowsecurity,c.relforcerowsecurity,c.relacl::text,
          pg_get_userbyid(c.relowner)
        FROM pg_class c WHERE c.oid IN ('content.document_versions'::regclass,
          'content.document_fragments'::regclass,'content.document_import_receipts'::regclass)
        ORDER BY c.oid::regclass::text
        """).rows

      policies =
        sql("""
        SELECT p.polrelid::regclass::text,p.polname,p.polcmd::text,p.polpermissive,p.polroles::text,
          pg_get_expr(p.polqual,p.polrelid),pg_get_expr(p.polwithcheck,p.polrelid)
        FROM pg_policy p WHERE p.polrelid IN ('content.document_versions'::regclass,
          'content.document_fragments'::regclass,'content.document_import_receipts'::regclass)
        ORDER BY p.polrelid::regclass::text,p.polname
        """).rows

      %{triggers: triggers, tables: tables, policies: policies}
    end)
  end

  defp assert_guards(snapshot) do
    for guard <- [
          "document_versions_lifecycle_guard",
          "document_fragments_immutable_guard",
          "document_versions_completion_check",
          "document_fragments_completion_check",
          "knowledge_restore_admission_immutable_check",
          "knowledge_restore_final_check"
        ] do
      assert Enum.any?(snapshot.triggers, fn [_schema, _table, name, enabled | _] ->
               name == guard and enabled == "O"
             end)
    end

    assert Enum.all?(snapshot.triggers, fn [_schema, _table, _name, enabled | _] ->
             enabled == "O"
           end)

    assert Enum.all?(snapshot.tables, fn [_table, enabled, forced | _] -> enabled and forced end)
    assert snapshot.policies != []
  end

  defp assert_immutable(fragment) do
    assert {:error, :immutable_denied} =
             MigrationRepo.transaction(fn ->
               sql("SET LOCAL ROLE singularity_table_owner")

               assert {:error,
                       %Postgrex.Error{
                         postgres: %{
                           code: :check_violation,
                           constraint: "document_fragments_immutable_check"
                         }
                       }} =
                        SafeSQL.query(
                          MigrationRepo,
                          "UPDATE content.document_fragments SET text=text WHERE id=$1",
                          [fragment["id"]]
                        )

               MigrationRepo.rollback(:immutable_denied)
             end)

    refute MigrationRepo.in_transaction?()
  end

  defp mutate_fragment(old, replacement, inject_failure? \\ false) do
    # Execute every active constraint during UPDATE, before ALTER restores the
    # single guard; deferred events would otherwise prevent that ALTER.
    sql("SET CONSTRAINTS ALL IMMEDIATE")

    sql(
      "ALTER TABLE content.document_fragments DISABLE TRIGGER document_fragments_immutable_guard"
    )

    assert %{num_rows: 1, rows: [[id, text, digest]]} =
             sql(
               """
               UPDATE content.document_fragments SET id=$2,text=$3,digest=$4
               WHERE id=$1 AND resource_version_id=$5 AND ordinal=1 RETURNING id,text,digest
               """,
               [
                 old["id"],
                 replacement.fragment_id,
                 replacement.text,
                 replacement.digest,
                 dump(old["resource_version_id"])
               ]
             )

    assert {id, text, digest} == {replacement.fragment_id, replacement.text, replacement.digest}
    if inject_failure?, do: MigrationRepo.rollback(:injected_failure)

    sql(
      "ALTER TABLE content.document_fragments ENABLE TRIGGER document_fragments_immutable_guard"
    )

    assert [["O"]] =
             sql(
               "SELECT tgenabled::text FROM pg_trigger WHERE tgrelid='content.document_fragments'::regclass AND tgname='document_fragments_immutable_guard'"
             ).rows
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
  defp dump(value), do: Ecto.UUID.dump!(value)
  defp id(n), do: "60000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")
  defp quote_identifier(value), do: "\"" <> String.replace(value, "\"", "\"\"") <> "\""

  defp call(function, arguments) do
    assert Code.ensure_loaded?(@subject)

    assert function_exported?(@subject, function, length(arguments)),
           "missing Task9E #{function}/#{length(arguments)}"

    apply(@subject, function, arguments)
  end

  defp assert_invalid(result) do
    assert {:error, %Error{code: code, message: nil, details: %{}, retryable?: false}} = result
    assert code in [:backup_invalid, :invalid, :integrity_failure, :conflict]
  end
end
