defmodule Singularity.Storage.Backup.KnowledgePreflightTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias __MODULE__.ObservedStorage
  alias Singularity.Core.Error
  alias Singularity.Core.DocumentFragment
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.LocalFilesystemAdapter
  alias Singularity.Storage.Backup.{BundleReader, LogicalRecordCodec, LogicalSchemaV3}
  alias Singularity.Storage.Backup.Restorer

  @preflight Singularity.Storage.Backup.KnowledgePreflight
  @fixtures Singularity.Storage.Backup.KnowledgeBackupFixtures
  @originals %{
    pdf: "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n",
    pdf_duplicate: "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n",
    empty: "",
    plain: "plain original\r\nsecond line\n",
    unicode: "界🙂 café\n",
    markdown: "# Original Markdown\n\n[source](https://example.test/)\n"
  }
  @ids ~w(
    account_id principal_id vault_id session_id live_note_id deleted_note_id
    initial_note_version_id canonical_note_version_id competing_note_version_id
    merge_note_version_id open_competing_note_version_id deleted_note_version_id
    resolved_conflict_id open_conflict_id ready_document_id ready_old_version_id
    ready_current_version_id deleted_document_id deleted_document_version_id
    pending_document_id pending_version_id extracting_document_id extracting_version_id
    failed_document_id failed_version_id unsupported_document_id unsupported_version_id
    attachment_id citation_id deleted_attachment_id deleted_citation_id tag_id
    relationship_id pdf_object_id empty_object_id plain_object_id unicode_object_id
    markdown_object_id
  )a
       |> Enum.with_index(1)
       |> Map.new(fn {name, index} ->
         {name,
          "50000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(index), 12, "0")}
       end)
  @unknown "50000000-0000-4000-8000-000000999999"
  @events {__MODULE__, :events}
  @metrics {__MODULE__, :metrics}
  @arm {__MODULE__, :arm}
  @flips {__MODULE__, :flips}
  @columns_sql """
  SELECT a.attname, t.typname, a.attnotnull
  FROM pg_attribute a JOIN pg_type t ON t.oid=a.atttypid
  WHERE a.attrelid=to_regclass($1) AND a.attnum>0 AND NOT a.attisdropped
  ORDER BY a.attnum
  """
  @keys_sql """
  SELECT i.indisprimary, ARRAY(
    SELECT a.attname::text FROM unnest(i.indkey) WITH ORDINALITY AS k(n,ord)
    JOIN pg_attribute a ON a.attrelid=i.indrelid AND a.attnum=k.n ORDER BY k.ord)
  FROM pg_index i WHERE i.indrelid=to_regclass($1) AND i.indisunique
  """

  test "the complete historical graph stages privately into typed, keyed transaction-local tables" do
    with_fixture(fn fixture, storage ->
      before = @fixtures.canonical_rows(fixture)
      bundle = authenticated(fixture)
      Process.put({__MODULE__, :probe_inserts}, true)
      assert %BundleReader.Verified{records: [], replay: %BundleReader.Replay{}} = bundle.verified

      assert {:error, :inspected} =
               owner_transaction(fn ->
                 assert {:ok, staged} = stage(bundle, storage)
                 assert {:ok, summary} = validate(staged, bundle.cut)

                 assert summary.counts ==
                          Map.new(before, fn {table, rows} -> {table, length(rows)} end)

                 assert Enum.sort(Map.keys(summary.digests)) == Enum.sort(Map.keys(before))

                 assert Enum.all?(summary.digests, fn {_table, value} ->
                          byte_size(value) == 32
                        end)

                 for schema <- LogicalSchemaV3.all() do
                   relation = relation(schema)

                   assert [[length(before[schema.table])]] ==
                            sql("SELECT count(*) FROM #{relation}").rows

                   columns = sql(@columns_sql, [relation]).rows
                   assert Enum.map(columns, &hd/1) == Enum.map(schema.columns, & &1.name)

                   assert Enum.map(columns, &Enum.at(&1, 2)) ==
                            Enum.map(schema.columns, &(not &1.nullable?))

                   assert Enum.all?(Enum.zip(columns, schema.columns), fn {[
                                                                             _name,
                                                                             type,
                                                                             _required
                                                                           ], column} ->
                            type in sql_types(column.tag)
                          end)

                   keys = sql(@keys_sql, [relation]).rows
                   assert [true, primary_columns(schema)] in keys

                   assert [["t", "r"]] ==
                            sql(
                              "SELECT relpersistence::text, relkind::text FROM pg_class WHERE oid=to_regclass($1)",
                              [relation]
                            ).rows

                   assert staged_rows(schema) == before[schema.table]
                 end

                 assert_secondary_keys()

                 assert [[nil]] ==
                          sql(
                            "SELECT asset_object_id FROM pg_temp.knowledge_restore_17 WHERE id=$1",
                            [dump(fixture.sources.pdf.asset_id)]
                          ).rows

                 assert [[true]] ==
                          sql(
                            "SELECT released_at IS NOT NULL FROM pg_temp.knowledge_restore_20 WHERE asset_id=$1",
                            [dump(fixture.sources.pdf.asset_id)]
                          ).rows

                 assert Enum.count(events(), &(&1 == :seal)) == 5
                 assert :finalize not in events()
                 MigrationRepo.rollback(:inspected)
               end)

      assert @fixtures.canonical_rows(fixture) == before
      assert_no_temp_tables()
      cleanup_stages(storage)
      assert_no_publication(storage)
    end)
  end

  test "the narrow Restorer preflight wrapper stages V3 but ordinary import and mismatched binding stay closed" do
    with_fixture(fn fixture, storage ->
      before = @fixtures.canonical_rows(fixture)

      context = %{
        object_storage: {storage.module, storage.context},
        preflight_observer: storage.observer
      }

      bundle = authenticated(fixture)

      assert {:error, :qualified} =
               owner_transaction(fn ->
                 assert {:ok, _qualified} =
                          preflight_knowledge(context, bundle)

                 assert [[7]] == sql("SELECT count(*) FROM pg_temp.knowledge_restore_30").rows
                 assert :finalize not in events()
                 MigrationRepo.rollback(:qualified)
               end)

      cleanup_stages(storage)
      assert @fixtures.canonical_rows(fixture) == before

      for invalid <- [:binding, :cut] do
        bundle = authenticated(fixture)

        bundle =
          case invalid do
            :binding -> put_in(bundle.binding.manifest_id, @unknown)
            :cut -> put_in(bundle.cut.snapshot_id, @unknown)
          end

        assert {:error, :denied} =
                 owner_transaction(fn ->
                   assert {:error, %Error{code: :backup_invalid}} =
                            preflight_knowledge(context, bundle)

                   assert_no_temp_tables()
                   MigrationRepo.rollback(:denied)
                 end)

        assert @fixtures.canonical_rows(fixture) == before
        assert {:ok, []} = LocalFilesystemAdapter.list_staged(storage.context)
        assert_no_publication(storage)
      end

      bundle = authenticated(fixture)

      assert {:error, %Error{code: :backup_invalid}} =
               Restorer.import(context, MigrationRepo, bundle)

      assert @fixtures.canonical_rows(fixture) == before
      assert {:ok, []} = LocalFilesystemAdapter.list_staged(storage.context)
      assert_no_publication(storage)
    end)
  end

  test "wire duplicates, row order/count/version, raw bytes and evidence hashes fail before staging" do
    with_fixture(fn fixture, storage ->
      before = @fixtures.canonical_rows(fixture)

      cases = [
        {:duplicate,
         [rows: fn rows -> Map.update!(rows, "content.tags", fn [row] -> [row, row] end) end]},
        {:order,
         [rows: fn rows -> Map.update!(rows, "content.note_versions", &Enum.reverse/1) end]},
        {:count,
         [
           cut: fn cut ->
             Map.update!(cut, :table_count_vector, fn [n | rest] -> [n + 1 | rest] end)
           end
         ]},
        {:missing_row, [records: fn [cut, _row | rest] -> [cut | rest] end]},
        {:extra_row, [records: fn [cut, row | rest] -> [cut, row, row | rest] end]},
        {:mixed_version,
         [
           records: fn records ->
             Enum.map(records, fn
               %{type: 2, payload: payload} = record ->
                 {:ok, decoded} = LogicalRecordCodec.decode(2, payload)

                 if decoded.table == "identity.people" do
                   {:ok, changed} =
                     LogicalRecordCodec.encode_row(
                       decoded.table,
                       decoded.primary_key_values,
                       decoded.ordered_column_values,
                       2
                     )

                   Map.merge(record, changed)
                 else
                   record
                 end

               record ->
                 record
             end)
           end
         ]},
        {:raw_hash, [raw: fn [first | rest] -> [first <> <<0>> | rest] end]},
        {:evidence_hash,
         [evidence: fn [first | rest] -> [%{first | ciphertext_hash: <<0::256>>} | rest] end]},
        {:missing_raw, [raw: &tl/1]},
        {:extra_raw, [raw: fn raws -> raws ++ [hd(raws)] end]},
        {:duplicate_evidence,
         [evidence: fn [first, _second | rest] -> [first, first | rest] end]},
        {:foreign_owner,
         [
           rows: fn rows ->
             edit(
               rows,
               "content.tags",
               %{"id" => @ids.tag_id},
               &Map.replace!(&1, "vault_id", @unknown)
             )
           end
         ]}
      ]

      for {label, options} <- cases do
        assert {:error, %Error{code: code}} = @fixtures.transformed_bundle(fixture, options),
               inspect(label)

        assert code in [:invalid, :backup_invalid]
        assert events() == []
        assert @fixtures.canonical_rows(fixture) == before
        assert_no_temp_tables()
        assert_no_publication(storage)
        assert {:ok, []} = LocalFilesystemAdapter.list_staged(storage.context)
      end
    end)
  end

  test "authentic records-only input, mismatched cut and missing caller transaction are denied" do
    with_fixture(fn fixture, storage ->
      before = @fixtures.canonical_rows(fixture)
      authenticated_cut = authenticated(fixture)

      reject_bundle(
        fixture,
        storage,
        %{verified: %{records: []}, cut: authenticated_cut.cut},
        before
      )

      records = authenticated(fixture, mode: :records)
      assert %BundleReader.Verified{replay: nil, records: [_ | _]} = records.verified
      reject_bundle(fixture, storage, records, before)
      replay = authenticated(fixture)

      reject_bundle(
        fixture,
        storage,
        %{replay | cut: %{replay.cut | manifest_id: @unknown}},
        before
      )

      replay = authenticated(fixture)
      assert {:error, %Error{code: :backup_invalid}} = stage(replay, storage)
      assert @fixtures.canonical_rows(fixture) == before
      assert_no_temp_tables()
      assert {:ok, []} = LocalFilesystemAdapter.list_staged(storage.context)
      assert_no_publication(storage)
    end)
  end

  test "ownership, generic references, exact heads, subtype and creator joins are enforced" do
    with_fixture(fn fixture, storage ->
      for {table, key, field, value} <- [
            {"identity.accounts", %{"id" => @ids.account_id}, "person_id", @unknown},
            {"identity.principals", %{"id" => @ids.principal_id}, "account_id", @unknown},
            {"core.vault_members", %{"principal_id" => @ids.principal_id}, "principal_id",
             @unknown},
            {"core.principal_capabilities", %{"principal_id" => @ids.principal_id},
             "capability_id", @unknown},
            {"content.resource_versions", %{"id" => @ids.ready_old_version_id}, "resource_id",
             @unknown},
            {"content.resources", %{"id" => @ids.live_note_id}, "current_version_id",
             @ids.ready_current_version_id},
            {"content.resources", %{"id" => @ids.ready_document_id}, "current_version_id", nil},
            {"content.resources", %{"id" => @ids.live_note_id}, "kind", "document"},
            {"content.document_versions", %{"resource_version_id" => @ids.ready_old_version_id},
             "classification", "public"},
            {"content.document_versions", %{"resource_version_id" => @ids.ready_old_version_id},
             "created_by_principal_id", @unknown},
            {"content.note_versions", %{"resource_version_id" => @ids.initial_note_version_id},
             "created_by_principal_id", @unknown},
            {"content.tags", %{"id" => @ids.tag_id}, "created_by_principal_id", @unknown}
          ] do
        reject_change(fixture, storage, table, key, field, value)
      end

      reject_rows(fixture, storage, fn rows ->
        Map.update!(rows, "core.vault_members", fn members ->
          Enum.reject(members, &(&1["principal_id"] == @ids.principal_id))
        end)
      end)
    end)
  end

  test "frozen key-domain, envelope and legacy owner identities remain graph-checked" do
    with_fixture(fn fixture, storage ->
      for {table, key, field, value} <- [
            {"core.vault_key_wrappers", %{"id" => id(108)}, "account_id", @unknown},
            {"core.domain_key_versions", %{"id" => id(109)}, "vault_key_version_id", @unknown},
            {"core.domain_dedup_key_wrappers", %{"id" => id(110)}, "domain_key_version_id",
             @unknown},
            {"content.asset_key_envelopes", %{"id" => id(200)}, "domain_key_version_id",
             @unknown},
            {"content.asset_key_envelopes", %{"id" => id(200)}, "key_domain_id", @unknown},
            {"content.asset_key_envelopes", %{"id" => id(200)}, "key_generation", 2},
            {"core.key_domains", %{"id" => id(106)}, "classification", "public"}
          ] do
        reject_change(fixture, storage, table, key, field, value)
      end
    end)
  end

  test "Note ancestry, revision uniqueness, conflict state and merge resolution cannot be fabricated" do
    with_fixture(fn fixture, storage ->
      for {table, key, field, value} <- [
            {"content.note_versions", %{"resource_version_id" => @ids.canonical_note_version_id},
             "parent_version_id", @unknown},
            {"content.note_versions", %{"resource_version_id" => @ids.canonical_note_version_id},
             "parent_version_id", @ids.merge_note_version_id},
            {"content.note_versions", %{"resource_version_id" => @ids.canonical_note_version_id},
             "parent_version_id", @ids.deleted_note_version_id},
            {"content.note_versions", %{"resource_version_id" => @ids.merge_note_version_id},
             "merge_parent_version_id", @ids.canonical_note_version_id},
            {"content.note_versions", %{"resource_version_id" => @ids.initial_note_version_id},
             "title", ""},
            {"content.note_versions", %{"resource_version_id" => @ids.initial_note_version_id},
             "markdown", String.duplicate("x", 1_048_577)},
            {"content.resource_versions", %{"id" => @ids.competing_note_version_id}, "revision",
             1},
            {"content.note_conflicts", %{"id" => @ids.open_conflict_id}, "state", "resolved"},
            {"content.note_conflicts", %{"id" => @ids.open_conflict_id}, "resolution_version_id",
             @ids.merge_note_version_id},
            {"content.note_conflicts", %{"id" => @ids.resolved_conflict_id},
             "resolution_version_id", @ids.deleted_note_version_id},
            {"content.note_conflicts", %{"id" => @ids.resolved_conflict_id},
             "competing_version_id", @unknown}
          ] do
        reject_change(fixture, storage, table, key, field, value)
      end
    end)
  end

  test "Note source sets require immutable exact pins, natural keys, bounds and canonical locators" do
    with_fixture(fn fixture, storage ->
      attachment = %{
        "note_resource_version_id" => @ids.merge_note_version_id,
        "id" => @ids.attachment_id
      }

      citation = %{
        "note_resource_version_id" => @ids.merge_note_version_id,
        "id" => @ids.citation_id
      }

      for {table, key, field, value} <- [
            {"content.note_attachments", attachment, "note_resource_id", @ids.deleted_note_id},
            {"content.note_attachments", attachment, "target_resource_version_id", @unknown},
            {"content.note_attachments", attachment, "target_kind", "note"},
            {"content.note_attachments", attachment, "role", "anything"},
            {"content.note_attachments", attachment, "ordinal", -1},
            {"content.note_attachments", attachment, "label", String.duplicate("x", 256)},
            {"content.note_citations", citation, "source_resource_version_id",
             @ids.ready_current_version_id},
            {"content.note_citations", citation, "fragment_id", String.duplicate("0", 64)},
            {"content.note_citations", citation, "locator",
             %{"version" => 1, "kind" => "pdf", "page" => 99}},
            {"content.note_citations", citation, "ordinal", -1}
          ] do
        reject_change(fixture, storage, table, key, field, value)
      end

      reject_rows(fixture, storage, fn rows ->
        edit(rows, "content.note_attachments", attachment, fn row ->
          %{
            row
            | "target_resource_id" => @ids.live_note_id,
              "target_resource_version_id" => @ids.merge_note_version_id,
              "target_kind" => "note"
          }
        end)
      end)

      for table <- ["content.note_attachments", "content.note_citations"] do
        reject_rows(fixture, storage, fn rows ->
          source =
            Enum.find(
              rows[table],
              &(&1["note_resource_version_id"] == @ids.merge_note_version_id)
            )

          duplicate = %{source | "id" => @unknown}
          put_rows(rows, table, rows[table] ++ [duplicate])
        end)

        reject_rows(fixture, storage, fn rows ->
          source =
            Enum.find(
              rows[table],
              &(&1["note_resource_version_id"] == @ids.merge_note_version_id)
            )

          excess = for n <- 1..101, do: %{source | "id" => id(10_000 + n), "ordinal" => n}
          put_rows(rows, table, rows[table] ++ excess)
        end)
      end

      # Unlike duplicate-target negatives above, these 101 added attachments
      # have different, genuine-shaped Asset versions and unique ordinals/IDs.
      # The source-count bound is the only new Note source-set violation.
      reject_rows(fixture, storage, fn rows ->
        source = fixture.sources.plain

        version =
          Enum.find(rows["content.resource_versions"], &(&1["id"] == source.resource_version_id))

        asset = Enum.find(rows["content.assets"], &(&1["id"] == source.asset_id))

        association =
          Enum.find(rows["content.resource_assets"], &(&1["asset_id"] == source.asset_id))

        member = Enum.find(rows["content.note_attachments"], &matches?(&1, attachment))
        versions = for n <- 1..101, do: %{version | "id" => id(30_000 + n), "revision" => n}

        assets =
          for n <- 1..101,
              do: %{asset | "id" => id(31_000 + n), "resource_version_id" => id(30_000 + n)}

        associations =
          for n <- 1..101,
              do: %{
                association
                | "asset_id" => id(31_000 + n),
                  "resource_version_id" => id(30_000 + n)
              }

        members =
          for n <- 1..101,
              do: %{
                member
                | "id" => id(32_000 + n),
                  "ordinal" => n,
                  "target_resource_id" => source.resource_id,
                  "target_resource_version_id" => id(30_000 + n)
              }

        rows
        |> put_rows("content.resource_versions", rows["content.resource_versions"] ++ versions)
        |> put_rows("content.assets", rows["content.assets"] ++ assets)
        |> put_rows("content.resource_assets", rows["content.resource_assets"] ++ associations)
        |> put_rows("content.note_attachments", rows["content.note_attachments"] ++ members)
      end)
    end)
  end

  test "Document source tuple, source identity and complete extraction state shape are enforced" do
    with_fixture(fn fixture, storage ->
      ready = %{"resource_version_id" => @ids.ready_old_version_id}
      pending = %{"resource_version_id" => @ids.pending_version_id}
      extracting = %{"resource_version_id" => @ids.extracting_version_id}

      for {key, field, value} <- [
            {ready, "source_asset_id", @unknown},
            {ready, "source_resource_id", @ids.live_note_id},
            {ready, "source_resource_version_id", fixture.sources.plain.resource_version_id},
            {ready, "source_object_id", @unknown},
            {ready, "source_digest", <<1>>},
            {ready, "source_digest", <<0::256>>},
            {ready, "source_byte_size", fixture.sources.pdf.byte_size + 1},
            {ready, "source_byte_size", -1},
            {ready, "media_type", "application/office"},
            {ready, "title", ""},
            {ready, "state", "unknown"},
            {ready, "extracted_text_digest", nil},
            {ready, "extracted_text_digest", <<0::256>>},
            {ready, "failure_code", "extractor_failed"},
            {ready, "attempt_finished_at", nil},
            {ready, "extraction_format", 0},
            {ready, "attempt_generation", -1},
            {pending, "extraction_adapter", "plain_text"},
            {extracting, "attempt_job_id", nil},
            {extracting, "attempt_deadline_at", "2026-10-11T00:00:01.000000Z"},
            {%{"resource_version_id" => @ids.failed_version_id}, "failure_code", nil},
            {%{"resource_version_id" => @ids.unsupported_version_id}, "detected_language", "en"}
          ] do
        reject_change(fixture, storage, "content.document_versions", key, field, value)
      end
    end)
  end

  test "a unique valid-length false plaintext digest remains a structural positive until Task9" do
    with_fixture(fn fixture, storage ->
      before = @fixtures.canonical_rows(fixture)
      false_digest = :crypto.hash(:sha256, "not the original plain bytes")
      assert false_digest != fixture.sources.plain.digest

      bundle =
        authenticated(fixture,
          rows: fn rows ->
            edit(
              rows,
              "content.document_versions",
              %{"resource_version_id" => @ids.extracting_version_id},
              &Map.replace!(&1, "source_digest", false_digest)
            )
          end
        )

      assert {:error, :structurally_valid} =
               owner_transaction(fn ->
                 assert {:ok, staged} = stage(bundle, storage)
                 assert {:ok, _summary} = validate(staged, bundle.cut)

                 assert [[false_digest]] ==
                          sql(
                            "SELECT source_digest FROM pg_temp.knowledge_restore_30 WHERE resource_version_id=$1",
                            [dump(@ids.extracting_version_id)]
                          ).rows

                 MigrationRepo.rollback(:structurally_valid)
               end)

      assert @fixtures.canonical_rows(fixture) == before
      cleanup_stages(storage)
      assert_no_publication(storage)
    end)
  end

  test "ready fragments require canonical IDs, ordinals, text hashes and extraction-state membership" do
    with_fixture(fn fixture, storage ->
      original = @fixtures.canonical_rows(fixture)

      fragment =
        Enum.find(
          original["content.document_fragments"],
          &(&1["resource_version_id"] == @ids.ready_old_version_id and &1["ordinal"] == 0)
        )

      key = %{"id" => fragment["id"]}

      for {field, value} <- [
            {"id", String.duplicate("f", 64)},
            {"ordinal", -1},
            {"ordinal", 7},
            {"text", "changed"},
            {"text", "carriage\rreturn"},
            {"text", String.duplicate("x", 65_537)},
            {"digest", <<0::256>>},
            {"locator", %{"version" => 1, "kind" => "pdf", "page" => 0}},
            {"locator", %{"version" => 1, "kind" => "pdf", "page" => 1, "extra" => true}},
            {"resource_id", @ids.live_note_id},
            {"resource_version_id", @ids.pending_version_id}
          ] do
        reject_change(fixture, storage, "content.document_fragments", key, field, value)
      end

      reject_rows(fixture, storage, fn rows ->
        put_rows(
          rows,
          "content.document_fragments",
          Enum.reject(rows["content.document_fragments"], &(&1["id"] == fragment["id"]))
        )
      end)

      reject_rows(fixture, storage, fn rows ->
        duplicate = %{fragment | "id" => String.duplicate("f", 64)}

        put_rows(
          rows,
          "content.document_fragments",
          rows["content.document_fragments"] ++ [duplicate]
        )
      end)

      reject_rows(fixture, storage, fn rows ->
        locator = %{"version" => 1, "kind" => "fragment", "ordinal" => 0}

        {:ok, canonical} =
          DocumentFragment.new(%{
            resource_id: @ids.pending_document_id,
            resource_version_id: @ids.pending_version_id,
            owner_scope_id: @ids.vault_id,
            classification: :private,
            ordinal: 0,
            text: "pending text",
            locator: locator
          })

        nonready = %{
          fragment
          | "id" => canonical.fragment_id,
            "resource_id" => @ids.pending_document_id,
            "resource_version_id" => @ids.pending_version_id,
            "text" => "pending text",
            "digest" => :crypto.hash(:sha256, "pending text"),
            "locator" => locator
        }

        put_rows(
          rows,
          "content.document_fragments",
          rows["content.document_fragments"] ++ [nonready]
        )
      end)
    end)
  end

  test "tags, resource memberships and directed edge natural keys are checked independently" do
    with_fixture(fn fixture, storage ->
      for {table, key, field, value} <- [
            {"content.tags", %{"id" => @ids.tag_id}, "normalized_key", "straße"},
            {"content.tags", %{"id" => @ids.tag_id}, "display_value", "\n"},
            {"content.resource_tags",
             %{"resource_id" => @ids.live_note_id, "tag_id" => @ids.tag_id}, "tag_id", @unknown},
            {"content.resource_tags", %{"resource_id" => @ids.live_note_id}, "resource_id",
             @unknown},
            {"content.relationships", %{"id" => @ids.relationship_id},
             "target_resource_version_id", @ids.deleted_document_version_id},
            {"content.relationships", %{"id" => @ids.relationship_id}, "source_resource_id",
             @ids.ready_document_id},
            {"content.relationships", %{"id" => @ids.relationship_id}, "type", "unknown"},
            {"content.relationships", %{"id" => @ids.relationship_id}, "created_by_principal_id",
             @unknown}
          ] do
        reject_change(fixture, storage, table, key, field, value)
      end

      for table <- ["content.tags", "content.relationships"] do
        reject_rows(fixture, storage, fn rows ->
          duplicate = %{hd(rows[table]) | "id" => @unknown}
          put_rows(rows, table, rows[table] ++ [duplicate])
        end)
      end
    end)
  end

  test "completed import results and extraction outbox/submission/progress/effect provenance are joined" do
    with_fixture(fn fixture, storage ->
      for {table, key, field, value} <- [
            {"content.document_import_receipts", %{"mutation_id" => @ids.ready_old_version_id},
             "principal_id", @unknown},
            {"content.document_import_receipts", %{"mutation_id" => @ids.ready_old_version_id},
             "version_id", nil},
            {"content.document_import_receipts", %{"mutation_id" => @ids.ready_old_version_id},
             "resource_id", @ids.live_note_id},
            {"content.document_import_receipts", %{"mutation_id" => @ids.ready_old_version_id},
             "request_fingerprint", <<1>>},
            {"jobs.job_submissions", %{"id" => id(702)}, "outbox_event_id", @unknown},
            {"jobs.job_submissions", %{"id" => id(702)}, "job_type", "unknown"},
            {"jobs.job_progress", %{"id" => id(703)}, "submission_id", @unknown},
            {"jobs.effect_receipts", %{"id" => id(704)}, "submission_id", @unknown},
            {"core.outbox_events", %{"id" => id(700)}, "principal_id", @unknown},
            {"core.outbox_events", %{"id" => id(700)}, "payload",
             %{
               "resource_id" => @ids.live_note_id,
               "resource_version_id" => @ids.extracting_version_id
             }},
            {"content.document_versions", %{"resource_version_id" => @ids.extracting_version_id},
             "attempt_job_id", @unknown}
          ] do
        reject_change(fixture, storage, table, key, field, value)
      end

      reject_rows(fixture, storage, fn rows ->
        edit(
          rows,
          "content.document_import_receipts",
          %{"mutation_id" => @ids.ready_old_version_id},
          fn row ->
            %{row | "state" => "pending", "resource_id" => nil, "version_id" => nil}
          end
        )
      end)
    end)
  end

  test "undispatched extraction generations permit pending equality and stale history but not the future" do
    with_fixture(fn fixture, storage ->
      before = @fixtures.canonical_rows(fixture)

      for {generation, requested} <- [{0, 0}, {2, 2}, {2, 1}] do
        bundle =
          authenticated(fixture,
            rows: fn rows ->
              rows
              |> edit(
                "content.document_versions",
                %{"resource_version_id" => @ids.pending_version_id},
                &Map.replace!(&1, "attempt_generation", generation)
              )
              |> add_extraction_request(
                @ids.pending_document_id,
                @ids.pending_version_id,
                requested
              )
            end
          )

        assert %BundleReader.Verified{records: [], replay: %BundleReader.Replay{}} =
                 bundle.verified

        assert {:error, :accepted_generation} =
                 owner_transaction(fn ->
                   assert {:ok, staged} = stage(bundle, storage)
                   assert {:ok, summary} = validate(staged, bundle.cut)
                   assert summary.counts["core.outbox_events"] == 2
                   assert @fixtures.canonical_rows(fixture) == before
                   assert_no_publication(storage)
                   MigrationRepo.rollback(:accepted_generation)
                 end)

        cleanup_stages(storage)
        assert_no_temp_tables()
        assert @fixtures.canonical_rows(fixture) == before
      end

      # Keep the original current extracting job intact. A second, genuinely
      # authenticated event needs no submission before dispatch at the cut.
      for {resource_id, version_id} <- [
            {@ids.pending_document_id, @ids.pending_version_id},
            {@ids.failed_document_id, @ids.failed_version_id},
            {@ids.ready_document_id, @ids.ready_current_version_id}
          ] do
        reject_rows(fixture, storage, fn rows ->
          document =
            Enum.find(
              rows["content.document_versions"],
              &(&1["resource_version_id"] == version_id)
            )

          add_extraction_request(
            rows,
            resource_id,
            version_id,
            document["attempt_generation"] + 9
          )
        end)
      end
    end)
  end

  test "authenticated inventory and canonical Asset metadata must agree without decrypting originals" do
    with_fixture(fn fixture, storage ->
      original = @fixtures.canonical_rows(fixture)
      object = Enum.find(original["content.asset_objects"], &(&1["id"] == @ids.plain_object_id))

      for {field, value} <- [
            {"key_domain_id", @unknown},
            {"classification", "public"},
            {"lookup_digest", <<0::256>>},
            {"storage_ref", "../outside"},
            {"ciphertext_hash", <<0::256>>},
            {"ciphertext_byte_size", object["ciphertext_byte_size"] + 1},
            {"plaintext_byte_size", object["plaintext_byte_size"] + 1}
          ] do
        # Keep independent evidence and raw bytes authentic/coherent. Only the
        # typed Asset row is wrong; this must reach semantic staging, not Reader.
        bundle =
          authenticated(fixture,
            rows: fn rows ->
              edit(
                rows,
                "content.asset_objects",
                %{"id" => object["id"]},
                &Map.replace!(&1, field, value)
              )
            end,
            evidence: fn entries ->
              Enum.map(entries, fn entry ->
                if entry.asset_object_id == object["id"],
                  do: %{
                    entry
                    | key_domain_id: object["key_domain_id"],
                      classification: object["classification"],
                      lookup_digest: object["lookup_digest"],
                      storage_ref: object["storage_ref"],
                      ciphertext_hash: object["ciphertext_hash"],
                      ciphertext_byte_size: object["ciphertext_byte_size"]
                  },
                  else: entry
              end)
            end
          )

        reject_bundle(fixture, storage, bundle, original)
      end

      reject_rows(fixture, storage, fn rows ->
        put_rows(
          rows,
          "content.asset_objects",
          Enum.reject(rows["content.asset_objects"], &(&1["id"] == @ids.empty_object_id))
        )
      end)

      reject_change(
        fixture,
        storage,
        "content.assets",
        %{"id" => fixture.sources.plain.asset_id},
        "asset_object_id",
        @unknown
      )

      # The existing original stays authentic but is no longer in either half
      # of the required union: no durable Asset pointer and no Document pin.
      reject_rows(fixture, storage, fn rows ->
        rows
        |> edit("content.assets", %{"id" => fixture.sources.plain.asset_id}, fn row ->
          %{row | "state" => "deleted", "asset_object_id" => nil}
        end)
        |> edit(
          "content.resource_assets",
          %{"asset_id" => fixture.sources.plain.asset_id},
          &Map.replace!(&1, "released_at", "2026-10-11T00:00:00.000000Z")
        )
        |> drop_matching("content.document_versions", %{
          "resource_version_id" => @ids.extracting_version_id
        })
        |> drop_matching("content.document_import_receipts", %{
          "version_id" => @ids.extracting_version_id
        })
        |> drop_matching("content.resource_versions", %{"id" => @ids.extracting_version_id})
        |> drop_matching("content.resources", %{"id" => @ids.extracting_document_id})
        |> drop_matching("core.outbox_events", %{"id" => id(700)})
        |> drop_matching("jobs.job_submissions", %{"id" => id(702)})
        |> drop_matching("jobs.job_progress", %{"id" => id(703)})
        |> drop_matching("jobs.effect_receipts", %{"id" => id(704)})
      end)

      reject_rows(fixture, storage, fn rows ->
        source = fixture.sources.pdf
        asset = Enum.find(rows["content.assets"], &(&1["id"] == source.asset_id))

        association =
          Enum.find(rows["content.resource_assets"], &(&1["asset_id"] == source.asset_id))

        rows
        |> put_rows("content.assets", rows["content.assets"] ++ [%{asset | "id" => @unknown}])
        |> put_rows(
          "content.resource_assets",
          rows["content.resource_assets"] ++ [%{association | "asset_id" => @unknown}]
        )
      end)
    end)
  end

  test "1001 extra tags and a large genuine original prove bounded actual inserts and object appends" do
    originals = Map.put(@originals, :plain, String.duplicate("large original\n", 150_000))

    with_fixture(
      fn fixture, storage ->
        before = @fixtures.canonical_rows(fixture)

        bundle =
          authenticated(fixture,
            rows: fn rows ->
              template = hd(rows["content.tags"])

              tags =
                for n <- 1..1001,
                    do: %{
                      template
                      | "id" => id(20_000 + n),
                        "display_value" => "Tag #{n}",
                        "normalized_key" => "tag #{n}"
                    }

              put_rows(rows, "content.tags", rows["content.tags"] ++ tags)
            end
          )

        Process.put({__MODULE__, :probe_inserts}, true)

        assert {:error, :bounded} =
                 owner_transaction(fn ->
                   assert {:ok, staged} = stage(bundle, storage)
                   assert {:ok, summary} = validate(staged, bundle.cut)
                   assert summary.counts["content.tags"] == 1002

                   assert [[1002]] ==
                            sql("SELECT count(*) FROM pg_temp.knowledge_restore_35").rows

                   batches = for {:batch, metric} <- metrics(), do: metric
                   chunks = for {:object_chunk, metric} <- metrics(), do: metric
                   metadata = for {:metadata, metric} <- metrics(), do: metric
                   assert length(batches) >= 3
                   assert Enum.all?(batches, &(&1.rows in 1..500 and &1.bytes in 1..16_777_216))

                   assert Enum.sum(Enum.map(batches, & &1.rows)) ==
                            Enum.sum(Map.values(summary.counts))

                   assert chunks != [] and Enum.all?(chunks, &(&1.bytes in 1..65_536))

                   assert Enum.sum(Enum.map(chunks, & &1.bytes)) ==
                            Enum.sum(
                              Enum.map(
                                before["content.asset_objects"],
                                & &1["ciphertext_byte_size"]
                              )
                            )

                   assert Enum.map(chunks, & &1.bytes) ==
                            for({:append, bytes} <- events(), do: bytes)

                   assert length(chunks) > 30
                   assert metadata != [] and Enum.all?(metadata, &(&1.bytes in 1..16_777_216))

                   assert Enum.all?(metrics(), fn {_event, metric} ->
                            Enum.all?(metric, fn {_key, value} ->
                              is_integer(value) and value >= 0
                            end)
                          end)

                   assert Process.get({__MODULE__, :insert_observed}, false)
                   assert :finalize not in events()
                   MigrationRepo.rollback(:bounded)
                 end)

        assert @fixtures.canonical_rows(fixture) == before
        cleanup_stages(storage)
        assert_no_publication(storage)
      end,
      originals
    )
  end

  test "late final-record authentication failure after real inserts and sealed object appends leaves no effects" do
    with_fixture(fn fixture, storage ->
      before = @fixtures.canonical_rows(fixture)
      Process.put(@arm, false)
      Process.put(@flips, 0)
      Process.put({__MODULE__, :probe_inserts}, true)
      bundle = authenticated(fixture, source: &final_record_fault_source/1)
      assert Process.get(@flips) == 0
      assert %BundleReader.Replay{} = bundle.verified.replay
      storage = %{storage | context: Map.put(storage.context, :test_late_fault, true)}
      reject_bundle(fixture, storage, bundle, before)
      assert Process.get({__MODULE__, :insert_observed}, false)
      assert Enum.count(events(), &(&1 == :seal)) == 5
      assert Enum.count(events(), &match?({:append, n} when n > 0, &1)) >= 5
      assert Process.get(@arm) == true
      assert Process.get(@flips) > 0
      assert Enum.count(events(), &(&1 == :abort)) == 5
      assert :finalize not in events()
    end)
  end

  test "staged typed ownership cannot validate against another cut or after its caller transaction" do
    with_fixture(fn fixture, storage ->
      before = @fixtures.canonical_rows(fixture)
      bundle = authenticated(fixture)

      assert {:error, {:staged, staged}} =
               owner_transaction(fn ->
                 assert {:ok, staged} = stage(bundle, storage)

                 assert {:error, %Error{code: :backup_invalid}} =
                          validate(staged, %{bundle.cut | snapshot_id: @unknown})

                 assert @fixtures.canonical_rows(fixture) == before
                 assert_no_publication(storage)
                 MigrationRepo.rollback({:staged, staged})
               end)

      assert {:error, %Error{code: :backup_invalid}} = validate(staged, bundle.cut)
      assert @fixtures.canonical_rows(fixture) == before

      assert {:error, :different_transaction} =
               owner_transaction(fn ->
                 assert {:error, %Error{code: :backup_invalid}} = validate(staged, bundle.cut)
                 assert @fixtures.canonical_rows(fixture) == before
                 assert_no_publication(storage)
                 MigrationRepo.rollback(:different_transaction)
               end)

      assert @fixtures.canonical_rows(fixture) == before
      assert_no_temp_tables()
      cleanup_stages(storage)
      assert_no_publication(storage)
    end)
  end

  defp with_fixture(fun, originals \\ @originals) do
    @fixtures.with_destination(:current, fn destination ->
      fixture = @fixtures.seed!(Map.merge(destination, %{ids: @ids, originals: originals}))
      root = Path.join(destination.object_root, "preflight-private")
      File.mkdir_p!(root)
      File.chmod!(root, 0o700)
      for key <- [@events, @metrics], do: Process.put(key, [])
      Process.put({__MODULE__, :insert_observed}, false)
      Process.put({__MODULE__, :insert_count}, 0)
      Process.put({__MODULE__, :probe_inserts}, false)
      Process.put(@arm, false)

      observer = fn event, numeric ->
        Process.put(@metrics, [{event, numeric} | Process.get(@metrics, [])])

        if event == :batch and Process.get({__MODULE__, :probe_inserts}, false) do
          # This is the actual caller connection, not disabled Ecto telemetry or
          # a fake repo facade. The notification must follow a successful INSERT.
          count =
            Enum.reduce(LogicalSchemaV3.all(), 0, fn schema, acc ->
              acc + hd(hd(sql("SELECT count(*) FROM #{relation(schema)}").rows))
            end)

          assert count > 0
          assert count - Process.get({__MODULE__, :insert_count}, 0) == numeric.rows
          Process.put({__MODULE__, :insert_count}, count)
          Process.put({__MODULE__, :insert_observed}, true)
        end
      end

      storage = %{module: ObservedStorage, context: %{root: root}, observer: observer}
      fun.(fixture, storage)
    end)
  end

  defp authenticated(fixture, options \\ []) do
    assert {:ok, bundle} = @fixtures.transformed_bundle(fixture, options)
    bundle
  end

  defp reject_change(fixture, storage, table, key, field, value),
    do:
      reject_rows(
        fixture,
        storage,
        &edit(&1, table, key, fn row -> Map.replace!(row, field, value) end)
      )

  defp add_extraction_request(rows, resource_id, version_id, generation) do
    events = rows["core.outbox_events"]

    key =
      "document-extraction:#{version_id}" <> if(generation == 0, do: "", else: ":#{generation}")

    event =
      hd(events)
      |> Map.merge(%{
        "id" => id(1_200),
        "sequence" => Enum.max(Enum.map(events, & &1["sequence"])) + 1,
        "idempotency_key" => key,
        "expected_entity_revision" => generation,
        "payload" => %{"resource_id" => resource_id, "resource_version_id" => version_id}
      })

    put_rows(rows, "core.outbox_events", events ++ [event])
  end

  defp reject_rows(fixture, storage, transform) do
    before = @fixtures.canonical_rows(fixture)
    bundle = authenticated(fixture, rows: transform)
    reject_bundle(fixture, storage, bundle, before)
  end

  defp reject_bundle(fixture, storage, bundle, before) do
    assert {:error, :rejected} =
             owner_transaction(fn ->
               result =
                 with {:ok, staged} <- stage(bundle, storage), do: validate(staged, bundle.cut)

               assert {:error, %Error{code: :backup_invalid, details: %{}} = error} = result
               assert error.details == %{}
               # The stage owns its savepoint: even a typed SQL constraint failure must
               # leave this caller transaction queryable before our explicit rollback.
               assert @fixtures.canonical_rows(fixture) == before
               assert_no_temp_tables()
               assert {:ok, []} = LocalFilesystemAdapter.list_staged(storage.context)
               assert_no_publication(storage)
               MigrationRepo.rollback(:rejected)
             end)

    assert @fixtures.canonical_rows(fixture) == before
    assert {:ok, []} = LocalFilesystemAdapter.list_staged(storage.context)
    assert_no_temp_tables()
    assert_no_publication(storage)
  end

  defp stage(bundle, storage) do
    assert Code.ensure_loaded?(@preflight), "missing KnowledgePreflight implementation"
    assert function_exported?(@preflight, :stage, 4), "missing KnowledgePreflight.stage/4"
    Process.put({__MODULE__, :insert_count}, 0)
    apply(@preflight, :stage, [MigrationRepo, bundle.verified, bundle.cut, storage])
  end

  defp validate(staged, cut) do
    assert Code.ensure_loaded?(@preflight), "missing KnowledgePreflight implementation"
    assert function_exported?(@preflight, :validate, 3), "missing KnowledgePreflight.validate/3"
    apply(@preflight, :validate, [MigrationRepo, staged, cut])
  end

  defp preflight_knowledge(context, bundle) do
    assert Code.ensure_loaded?(Restorer), "missing Restorer implementation"

    assert function_exported?(Restorer, :preflight_knowledge, 3),
           "missing Restorer.preflight_knowledge/3"

    apply(Restorer, :preflight_knowledge, [context, MigrationRepo, bundle])
  end

  defp owner_transaction(fun) do
    MigrationRepo.transaction(fn ->
      sql("SET LOCAL ROLE singularity_table_owner")
      fun.()
    end)
  end

  defp sql(statement, parameters \\ []),
    do: Ecto.Adapters.SQL.query!(MigrationRepo, statement, parameters)

  defp dump(uuid), do: Ecto.UUID.dump!(uuid)

  defp id(index),
    do: "60000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(index), 12, "0")

  defp relation(schema), do: "pg_temp.knowledge_restore_#{schema.ordinal}"

  defp edit(rows, table, key, transform) do
    assert Enum.count(rows[table], &matches?(&1, key)) == 1

    put_rows(
      rows,
      table,
      Enum.map(rows[table], fn row -> if matches?(row, key), do: transform.(row), else: row end)
    )
  end

  defp matches?(row, key), do: Enum.all?(key, fn {field, value} -> row[field] == value end)

  defp put_rows(rows, table, values) do
    {:ok, schema} = LogicalSchemaV3.fetch_table(table)
    keys = primary_columns(schema)
    Map.replace!(rows, table, Enum.sort_by(values, fn row -> Enum.map(keys, &row[&1]) end))
  end

  defp drop_matching(rows, table, key),
    do: put_rows(rows, table, Enum.reject(rows[table], &matches?(&1, key)))

  defp staged_rows(schema) do
    order =
      if schema.table == "core.outbox_events",
        do: "sequence",
        else: Enum.join(primary_columns(schema), ",")

    columns = Enum.map_join(schema.columns, ",", & &1.name)
    result = sql("SELECT #{columns} FROM #{relation(schema)} ORDER BY #{order}")

    Enum.map(result.rows, fn row ->
      Map.new(Enum.zip(schema.columns, row), fn {column, value} ->
        canonical =
          case {column.tag, value} do
            {"uuid", value} when is_binary(value) -> Ecto.UUID.load!(value)
            {"timestamp", %DateTime{} = value} -> DateTime.to_iso8601(value)
            _ -> value
          end

        {column.name, canonical}
      end)
    end)
  end

  defp assert_secondary_keys do
    for {ordinal, columns} <- [
          {15, ~w(resource_id revision)},
          {31, ~w(resource_version_id ordinal)},
          {33, ~w(note_resource_version_id ordinal)},
          {33, ~w(note_resource_version_id target_resource_version_id role)},
          {34, ~w(note_resource_version_id ordinal)},
          {35, ~w(vault_id normalized_key)},
          {37, ~w(vault_id source_resource_id target_resource_id type)}
        ] do
      assert Enum.any?(sql(@keys_sql, ["pg_temp.knowledge_restore_#{ordinal}"]).rows, fn [
                                                                                           _primary,
                                                                                           key
                                                                                         ] ->
               key == columns
             end)
    end
  end

  defp assert_no_temp_tables do
    assert [[0]] ==
             sql(
               "SELECT count(*) FROM pg_class WHERE relnamespace=pg_my_temp_schema() AND relname LIKE 'knowledge_restore_%'"
             ).rows
  end

  defp events, do: Enum.reverse(Process.get(@events, []))
  defp metrics, do: Enum.reverse(Process.get(@metrics, []))

  defp assert_no_publication(storage) do
    assert :finalize not in events()
    assert Path.wildcard(Path.join(storage.context.root, "objects/**/*"), match_dot: true) == []
    assert Path.wildcard(Path.join(storage.context.root, "finalized/**/*"), match_dot: true) == []
  end

  defp cleanup_stages(storage) do
    assert {:ok, stages} = LocalFilesystemAdapter.list_staged(storage.context)

    for ref <- stages do
      assert :ok = LocalFilesystemAdapter.abort_stage(storage.context, ref)
    end

    assert {:ok, []} = LocalFilesystemAdapter.list_staged(storage.context)
  end

  defp primary_columns(schema),
    do: Enum.map(schema.primary_key, &Enum.fetch!(schema.columns, &1.position).name)

  defp sql_types("integer"), do: ["int4", "int8"]
  defp sql_types("bytes"), do: ["bytea"]
  defp sql_types("boolean"), do: ["bool"]
  defp sql_types("json"), do: ["jsonb"]
  defp sql_types("timestamp"), do: ["timestamptz"]
  defp sql_types(tag), do: [tag]

  defp final_record_fault_source(source) do
    size = File.stat!(source.path).size
    # The reserved 68-byte final record has an 8-byte counter/length header,
    # 44 ciphertext bytes and the unchanged 16-byte tag. Corrupt ciphertext only.
    flip_offset = size - 68 + 8
    original = source.file_system.pread

    pread = fn snapshot, offset, count ->
      with {:ok, bytes} <- original.(snapshot, offset, count) do
        if Process.get(@arm, false) and offset <= flip_offset and
             flip_offset < offset + byte_size(bytes) do
          local = flip_offset - offset
          <<prefix::binary-size(local), byte, suffix::binary>> = bytes
          Process.put(@flips, Process.get(@flips, 0) + 1)
          {:ok, <<prefix::binary, Bitwise.bxor(byte, 1), suffix::binary>>}
        else
          {:ok, bytes}
        end
      end
    end

    %{source | file_system: %{source.file_system | pread: pread}}
  end

  defmodule ObservedStorage do
    @moduledoc false
    alias Singularity.Storage.LocalFilesystemAdapter, as: Real
    @events {Singularity.Storage.Backup.KnowledgePreflightTest, :events}
    @arm {Singularity.Storage.Backup.KnowledgePreflightTest, :arm}

    def stage(context, options) do
      result = Real.stage(context, options)
      if match?({:ok, _}, result), do: event(:stage)
      result
    end

    def append_encrypted_chunk(context, ref, bytes) do
      result = Real.append_encrypted_chunk(context, ref, bytes)
      if result == :ok, do: event({:append, byte_size(bytes)})
      result
    end

    def seal_stage(context, ref, metadata) do
      result = Real.seal_stage(context, ref, metadata)

      if match?({:ok, _}, result) do
        event(:seal)

        if Map.get(context, :test_late_fault, false) and
             Process.get(
               {Singularity.Storage.Backup.KnowledgePreflightTest, :insert_observed},
               false
             ) and
             Enum.count(Process.get(@events, []), &(&1 == :seal)) == 5,
           do: Process.put(@arm, true)
      end

      result
    end

    def abort_stage(context, ref) do
      result = Real.abort_stage(context, ref)
      if result == :ok, do: event(:abort)
      result
    end

    def finalize(context, stage, object) do
      event(:finalize)
      Real.finalize(context, stage, object)
    end

    defdelegate stat_stage(context, ref), to: Real
    defdelegate stat(context, ref), to: Real
    defdelegate list_staged(context), to: Real
    defdelegate rollback_finalize(context, stage, object), to: Real
    defdelegate delete(context, ref), to: Real
    defp event(event), do: Process.put(@events, [event | Process.get(@events, [])])
  end
end
