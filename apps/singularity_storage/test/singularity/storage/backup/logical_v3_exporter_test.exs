defmodule Singularity.Storage.Backup.LogicalV3ExporterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :integration

  alias Ecto.Adapters.SQL
  alias Singularity.Core.Error
  alias Singularity.Storage.{Fixtures, LocalFilesystemAdapter, MigrationRepo, NoteFixtures}
  alias Singularity.Storage.{RequestRepo, SafeSQL, ScopedRepo, WorkerRepo}
  alias Singularity.Storage.Backup.{Exporter, KnowledgeBackupFixtures, LogicalRecordCodec}
  alias Singularity.Storage.Crypto.{ChunkedAEAD, Format, KeyWrapper, ObjectIdentity}
  alias Singularity.Storage.Local.PathGuard

  # Fixed source projections and native PKs, independently transcribed from DDL.
  # Neither the writer, its inventory nor any wire registry supplies expectations.
  @projection [
    {"identity.people", ~w(id display_name metadata inserted_at updated_at), ~w(id)},
    {"identity.accounts", ~w(id person_id status metadata inserted_at updated_at), ~w(id)},
    {"identity.credentials", ~w(id account_id normalized_login revoked_at inserted_at), ~w(id)},
    {"identity.principals",
     ~w(id account_id kind authorization_epoch revoked_at metadata inserted_at updated_at),
     ~w(id)},
    {"core.capabilities", ~w(id name inserted_at), ~w(id)},
    {"core.vaults",
     ~w(id kind authorization_epoch locked metadata inserted_at updated_at object_cleanup_principal_id),
     ~w(id)},
    {"core.vault_members", ~w(principal_id vault_id clearance revoked_at inserted_at updated_at),
     ~w(principal_id vault_id)},
    {"core.principal_capabilities",
     ~w(principal_id vault_id capability_id revoked_at inserted_at),
     ~w(principal_id vault_id capability_id)},
    {"identity.devices", ~w(id principal_id vault_id label revoked_at inserted_at updated_at),
     ~w(id)},
    {"core.key_domains", ~w(id vault_id classification kind state inserted_at updated_at),
     ~w(id)},
    {"core.vault_key_versions",
     ~w(id vault_id generation state algorithm activated_at retired_at inserted_at), ~w(id)},
    {"core.vault_key_wrappers",
     ~w(id vault_id vault_key_version_id account_id generation inserted_at), ~w(id)},
    {"core.domain_key_versions",
     ~w(id vault_id key_domain_id vault_key_version_id generation state algorithm wrapped_key inserted_at),
     ~w(id)},
    {"core.domain_dedup_key_wrappers",
     ~w(id vault_id key_domain_id domain_key_version_id algorithm wrapped_key inserted_at),
     ~w(id)},
    {"content.resources",
     ~w(id vault_id classification title deleted_at metadata inserted_at updated_at kind current_version_id),
     ~w(id)},
    {"content.resource_versions",
     ~w(id resource_id vault_id classification revision inserted_at updated_at), ~w(id)},
    {"content.asset_objects",
     ~w(id vault_id key_domain_id classification lookup_digest ciphertext_hash plaintext_byte_size ciphertext_byte_size storage_ref format_version lifecycle retained_until deleted_at deletion_evidence inserted_at updated_at lifecycle_revision delete_claim_token delete_claimed_at),
     ~w(id)},
    {"content.assets",
     ~w(id vault_id resource_version_id asset_object_id classification state state_revision failure_code retryable failed_operation attempt inserted_at updated_at),
     ~w(id)},
    {"content.asset_key_envelopes",
     ~w(id vault_id asset_object_id domain_key_version_id key_domain_id classification algorithm key_generation wrapped_dek inserted_at),
     ~w(id)},
    {"content.asset_metadata",
     ~w(id asset_id resource_version_id vault_id classification projection_version original_filename declared_media_type detected_media_type plaintext_byte_size pdf_header_version image_width image_height extraction_state extractor_version completed_at inserted_at updated_at),
     ~w(id)},
    {"content.resource_assets",
     ~w(resource_version_id asset_id vault_id classification released_at inserted_at),
     ~w(resource_version_id asset_id)},
    {"content.source_references",
     ~w(id vault_id resource_version_id principal_id classification kind observed_at original_filename declared_media_type byte_size idempotency_key_digest inserted_at),
     ~w(id)},
    {"content.tombstones",
     ~w(id vault_id asset_id principal_id classification reason retention_metadata deleted_at),
     ~w(id)},
    {"audit.events",
     ~w(id vault_id actor_kind principal_id anonymous_fingerprint system_principal_name operation result classification correlation_id target_type target_id metadata occurred_at inserted_at),
     ~w(id)},
    {"core.outbox_events",
     ~w(id sequence event_type idempotency_key vault_id principal_id required_capability vault_authorization_epoch classification correlation_id causation_id expected_entity_revision envelope_version payload occurred_at claim_token claimed_until runner_job_id delivered_at inserted_at updated_at principal_authorization_epoch retired_at retirement_reason),
     ~w(id)},
    {"jobs.job_submissions",
     ~w(id vault_id outbox_event_id classification idempotency_key job_type runner_job_id inserted_at updated_at),
     ~w(id)},
    {"jobs.job_progress",
     ~w(id vault_id submission_id classification state processing_revision checkpoint_version checkpoint inserted_at updated_at),
     ~w(id)},
    {"jobs.effect_receipts",
     ~w(id vault_id submission_id classification effect_key result entity_revision inserted_at),
     ~w(id)},
    {"content.note_versions",
     ~w(resource_version_id resource_id vault_id classification title markdown created_by_principal_id parent_version_id merge_parent_version_id inserted_at),
     ~w(resource_version_id)},
    {"content.note_conflicts",
     ~w(id resource_id vault_id classification base_version_id canonical_version_id competing_version_id state resolution_version_id created_at resolved_at),
     ~w(id)},
    {"content.document_versions",
     ~w(resource_version_id resource_id vault_id classification source_asset_id source_resource_id source_resource_version_id source_object_id source_digest source_byte_size media_type title created_by_principal_id state attempt_generation extraction_adapter extraction_format extracted_text_digest detected_language failure_code attempt_finished_at inserted_at attempt_job_id attempt_started_at attempt_deadline_at),
     ~w(resource_version_id)},
    {"content.document_fragments",
     ~w(id resource_id resource_version_id vault_id classification ordinal text digest locator inserted_at),
     ~w(id)},
    {"content.document_import_receipts",
     ~w(vault_id principal_id mutation_id request_fingerprint state resource_id version_id inserted_at),
     ~w(vault_id principal_id mutation_id)},
    {"content.note_attachments",
     ~w(note_resource_version_id id note_resource_id vault_id classification target_resource_id target_resource_version_id target_kind ordinal role label inserted_at),
     ~w(note_resource_version_id id)},
    {"content.note_citations",
     ~w(note_resource_version_id id note_resource_id vault_id classification source_resource_id source_resource_version_id fragment_id locator ordinal inserted_at),
     ~w(note_resource_version_id id)},
    {"content.tags",
     ~w(id vault_id classification display_value normalized_key created_by_principal_id inserted_at),
     ~w(id)},
    {"content.resource_tags", ~w(resource_id tag_id vault_id classification inserted_at),
     ~w(resource_id tag_id vault_id)},
    {"content.relationships",
     ~w(id vault_id classification source_resource_id target_resource_id target_resource_version_id type created_by_principal_id inserted_at),
     ~w(id)}
  ]
  @tables Enum.map(@projection, &elem(&1, 0))
  @added Enum.drop(@tables, 30)
  @counts [
    1,
    1,
    1,
    2,
    3,
    1,
    2,
    3,
    0,
    1,
    1,
    1,
    1,
    1,
    14,
    19,
    5,
    6,
    5,
    0,
    6,
    0,
    0,
    0,
    1,
    1,
    1,
    1,
    6,
    2,
    7,
    6,
    7,
    4,
    3,
    1,
    1,
    1
  ]
  @excluded ~w(identity.sessions content.note_mutation_receipts content.knowledge_mutation_receipts
    content.note_source_set_seals content.search_entries content.note_search_documents
    content.asset_search_documents content.asset_stages content.upload_grants jobs.oban_jobs
    jobs.oban_peers audit.knowledge_restore_admissions audit.restore_import_sagas)
  @ids ~w(account_id principal_id vault_id session_id live_note_id deleted_note_id
    initial_note_version_id canonical_note_version_id competing_note_version_id
    merge_note_version_id open_competing_note_version_id deleted_note_version_id
    resolved_conflict_id open_conflict_id ready_document_id ready_old_version_id
    ready_current_version_id deleted_document_id deleted_document_version_id
    pending_document_id pending_version_id extracting_document_id extracting_version_id
    failed_document_id failed_version_id unsupported_document_id unsupported_version_id
    attachment_id citation_id deleted_attachment_id deleted_citation_id tag_id relationship_id
    pdf_object_id empty_object_id plain_object_id unicode_object_id markdown_object_id)a
       |> Enum.with_index(1)
       |> Map.new(fn {name, index} ->
         {name,
          "50000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(index), 12, "0")}
       end)
  @originals %{
    pdf: "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n",
    pdf_duplicate: "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n",
    empty: "",
    plain: "plain original\r\nsecond line\n",
    unicode: "界🙂 café\n",
    markdown: "# Original Markdown\n\n[source](https://example.test/)\n"
  }
  @capture_keys ~w(database_snapshot object_inventory outbox_high_water_mark snapshot_id vault_id)a
  @logical_keys Enum.sort([:manifest_id | @capture_keys])
  @receipt_helper "content.export_document_import_receipts_for_backup(uuid)"
  @version_guard "content.backup_has_unsupported_canonical_rows(uuid,integer)"
  @roles ~w(singularity_worker singularity_web singularity_dispatcher singularity_pre_auth)

  defmodule NoCallsRepo do
    def in_transaction?, do: raise("unsupported writer called the repository")
    def query!(_, _, _), do: raise("unsupported writer queried the repository")
  end

  # A real adapter delegate, with messages outside SQL rollback for read ordering.
  defmodule CountingStorage do
    alias Singularity.Storage.LocalFilesystemAdapter

    def open(context, reference) do
      send(context.observer, {:adapter_open, self(), reference})
      LocalFilesystemAdapter.open(context, reference)
    end

    def read_range(context, handle, range) do
      send(context.observer, {:adapter_read, self(), range})
      LocalFilesystemAdapter.read_range(context, handle, range)
    end
  end

  test "unsupported writer selections deny before any repository or storage access" do
    for version <- [1, 0, 4, 99, nil, :unknown] do
      assert {:error, %Error{code: :backup_unsupported, message: nil, details: %{}}} =
               snapshot(NoCallsRepo, Ecto.UUID.generate(), version)

      assert {:error, %Error{code: :backup_unsupported, message: nil, details: %{}}} =
               records(NoCallsRepo, %{object_inventory: :must_not_be_read}, version)
    end
  end

  for shape <- [:live, :history, :conflict, :tombstone] do
    @note_shape shape
    test "V1 cannot write #{@note_shape} Note-only history while V2 retains it" do
      note =
        case @note_shape do
          :conflict -> NoteFixtures.note_with_conflict!()
          _shape -> NoteFixtures.note!()
        end

      if @note_shape == :history do
        NoteFixtures.insert_note_version!(note, %{
          title: "Historical Note canary",
          markdown: "# Historical Note canary\n"
        })
      end

      Fixtures.with_owner(fn ->
        grant_backup!(note)
        initialize_note_backup_wrapper!(note)

        if @note_shape == :tombstone do
          owner_query!("UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id=$1", [
            dump(note.resource_id)
          ])
        end

        for table <- @added do
          assert %{rows: [[0]]} =
                   owner_query!("SELECT count(*) FROM #{table} WHERE vault_id=$1", [
                     dump(note.vault_id)
                   ])
        end
      end)

      expected =
        Fixtures.with_owner(fn ->
          owner_query!(
            "SELECT resource_version_id::text,markdown FROM content.note_versions WHERE vault_id=$1 ORDER BY resource_version_id",
            [dump(note.vault_id)]
          ).rows
        end)

      assert {:ok, :checked} =
               scoped(note, fn repo ->
                 assert {:ok, cut} = snapshot(repo, note.vault_id, 2)
                 logical = Map.put(cut, :manifest_id, Ecto.UUID.generate())

                 assert {:error, %Error{code: :backup_unsupported}} =
                          snapshot(repo, note.vault_id, 1)

                 assert {:error, %Error{code: :backup_unsupported}} = records(repo, logical, 1)
                 assert {:ok, explicit} = records(repo, logical, 2)
                 assert {:ok, default} = Exporter.records(repo, logical)
                 explicit_rows = decode(Enum.to_list(explicit.records))
                 assert decode(Enum.to_list(default.records)) == explicit_rows
                 assert Enum.all?(explicit_rows, &(&1.logical_version == 2))

                 actual =
                   explicit_rows
                   |> Enum.filter(&(&1.kind == :row and &1.table == "content.note_versions"))
                   |> Enum.map(fn row ->
                     [{"uuid", version} | values] = row.ordered_column_values
                     {"text", markdown} = Enum.at(values, 4)
                     [version, markdown]
                   end)

                 assert actual == expected

                 if @note_shape == :conflict,
                   do:
                     assert(
                       Enum.any?(
                         explicit_rows,
                         &(&1.kind == :row and &1.table == "content.note_conflicts")
                       )
                     )

                 if @note_shape == :tombstone do
                   resource =
                     Enum.find(
                       explicit_rows,
                       &(&1.kind == :row and &1.table == "content.resources" and
                           &1.primary_key_values == [{"uuid", note.resource_id}])
                     )

                   assert {"timestamp", _deleted_at} = Enum.at(resource.ordered_column_values, 4)
                 end

                 assert {:ok, default_cut} = Exporter.snapshot_cut(repo, note.vault_id)
                 assert Map.drop(default_cut, [:snapshot_id]) == Map.drop(cut, [:snapshot_id])
                 {:ok, :checked}
               end)
    end
  end

  test "explicit V3 emits the exact 38-table SQL oracle, complete history and original closure" do
    with_fixture(fn fixture ->
      oracle = source_oracle(fixture.owner)
      assert Enum.map(@tables, &length(oracle[&1])) == @counts
      assert length(@projection) == 38
      assert Enum.sum(Enum.map(@projection, fn {_, columns, _} -> length(columns) end)) == 367
      expected_inventory = inventory_oracle(fixture.owner)

      assert Enum.map(expected_inventory, & &1.asset_object_id) ==
               Enum.sort(
                 Map.values(
                   Map.take(
                     @ids,
                     ~w(pdf_object_id empty_object_id plain_object_id unicode_object_id markdown_object_id)a
                   )
                 )
               )

      assert Enum.count(expected_inventory, &(&1.asset_object_id == @ids.pdf_object_id)) == 1

      assert {:ok, :checked} =
               scoped(fixture.owner, fn repo ->
                 assert {:ok, capture} = snapshot(repo, fixture.owner.vault_id, 3)
                 assert Enum.sort(Map.keys(capture)) == Enum.sort(@capture_keys)
                 assert capture.object_inventory == expected_inventory
                 logical = Map.put(capture, :manifest_id, Ecto.UUID.generate())
                 assert Enum.sort(Map.keys(logical)) == @logical_keys
                 assert {:ok, export} = records(repo, logical, 3)
                 first = Enum.to_list(export.records)
                 assert Enum.to_list(export.records) == first
                 assert Enum.map(first, &LogicalRecordCodec.descriptor/1) == export.inventory
                 [header | body] = decode(first)

                 assert %{
                          kind: :cut,
                          logical_version: 3,
                          table_count_vector: @counts,
                          object_count: 5
                        } = header

                 assert header.manifest_id == logical.manifest_id
                 assert header.database_snapshot == capture.database_snapshot
                 assert header.outbox_high_water_mark == capture.outbox_high_water_mark
                 assert Enum.all?(body, &(&1.logical_version == 3))
                 rows = Enum.filter(body, &(&1.kind == :row))
                 assert_source_rows(rows, oracle)
                 evidence = Enum.filter(body, &(&1.kind == :object))

                 assert Enum.map(evidence, & &1.asset_object_id) ==
                          Enum.map(expected_inventory, & &1.asset_object_id)

                 for {object, entry} <- Enum.zip(evidence, expected_inventory) do
                   assert Map.drop(object, [:kind, :logical_version, :object_index]) ==
                            entry
                            |> Map.delete(:inventory_position)
                            |> Map.update!(:classification, &Atom.to_string/1)

                   assert object.object_index == entry.inventory_position
                 end

                 assert_retained_history(rows)
                 assert {:ok, raw} = raw_inventory(repo, storage(fixture), capture)

                 assert {:ok, delegated} =
                          Exporter.stream_inventory(
                            %{repo: repo, storage: storage(fixture)},
                            capture
                          )

                 assert raw.inventory == delegated.inventory
                 assert_raw_ciphertext(raw, fixture, expected_inventory)
                 assert_raw_ciphertext(delegated, fixture, expected_inventory)
                 {:ok, :checked}
               end)
    end)
  end

  test "default and explicit V2 still deny both live and tombstoned V3 graphs" do
    with_fixture(fn fixture ->
      assert_legacy_denied(fixture)

      owner(fn ->
        owner_query!(
          "UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE vault_id=$1",
          [dump(fixture.owner.vault_id)]
        )
      end)

      assert_legacy_denied(fixture)
    end)
  end

  test "inventory includes live Asset-only objects and omits orphan and physically retired Asset-only bytes" do
    with_fixture(fn fixture ->
      live = asset_only_original!(fixture, :live)
      retired = asset_only_original!(fixture, :retired)
      orphan = asset_only_original!(fixture, :orphan)
      refute File.exists?(retired.path)
      expected = inventory_oracle(fixture.owner)
      assert length(expected) == 6
      assert Enum.any?(expected, &(&1.asset_object_id == live.object_id))
      refute Enum.any?(expected, &(&1.asset_object_id in [retired.object_id, orphan.object_id]))
      oracle = source_oracle(fixture.owner)

      assert {:ok, :checked} =
               scoped(fixture.owner, fn repo ->
                 assert {:ok, cut} = snapshot(repo, fixture.owner.vault_id, 3)
                 assert cut.object_inventory == expected

                 assert {:ok, logical} =
                          records(repo, Map.put(cut, :manifest_id, Ecto.UUID.generate()), 3)

                 assert_source_rows(
                   Enum.filter(decode(Enum.to_list(logical.records)), &(&1.kind == :row)),
                   oracle
                 )

                 assert {:ok, raw} = raw_inventory(repo, storage(fixture), cut)
                 assert_raw_ciphertext(raw, fixture, expected)
                 {:ok, :checked}
               end)
    end)
  end

  # Persisted-shape/guard regressions: reserve_finalization stores the candidate
  # object UUID as storage_ref, and make_object_available preserves that value.
  # These owner-SQL fixtures do not prove live authenticated bytes, custody or
  # the backup saga; the canonical-path/raw-byte cases remain separate above.
  test "V3 preserves an available Asset-only object's own UUID storage reference" do
    with_fixture(fn fixture ->
      live = asset_only_original!(fixture, :live, :object_uuid)
      assert_uuid_reference_export(fixture, live.object_id)
    end)
  end

  test "V3 preserves immutable Document pins to an available object's own UUID storage reference" do
    with_fixture(fn fixture ->
      before = source_oracle(fixture.owner)

      # Only this disposable object's reference changes; the protected fixture
      # inserts and every immutable Document pin remain unchanged.
      owner(fn ->
        assert %{num_rows: 1} =
                 owner_query!(
                   "UPDATE content.asset_objects SET storage_ref=id::text WHERE id=$1",
                   [
                     dump(@ids.pdf_object_id)
                   ]
                 )
      end)

      after_reference_change = source_oracle(fixture.owner)

      assert after_reference_change["content.document_versions"] ==
               before["content.document_versions"]

      for {version, source} <- [
            {@ids.ready_old_version_id, fixture.sources.pdf},
            {@ids.ready_current_version_id, fixture.sources.pdf_duplicate},
            {@ids.deleted_document_version_id, fixture.sources.pdf}
          ] do
        [pin] =
          Enum.filter(
            after_reference_change["content.document_versions"],
            &(hd(&1) == {"uuid", version})
          )

        assert Enum.slice(pin, 4, 6) == [
                 {"uuid", source.asset_id},
                 {"uuid", source.resource_id},
                 {"uuid", source.resource_version_id},
                 {"uuid", @ids.pdf_object_id},
                 {"bytes", source.digest},
                 {"integer", source.byte_size}
               ]
      end

      assert_uuid_reference_export(fixture, @ids.pdf_object_id)
    end)
  end

  for mismatch <- [:object_uuid, :path_owner, :path_domain, :path_lookup] do
    @reference_mismatch mismatch
    test "V3 storage reference guard fails closed for #{@reference_mismatch} disagreement" do
      with_fixture(fn fixture ->
        entry =
          Enum.find(inventory_oracle(fixture.owner), &(&1.asset_object_id == @ids.pdf_object_id))

        ["objects", vault, domain, "hmac-sha256", shard, lookup] =
          String.split(entry.storage_ref, "/")

        foreign = Ecto.UUID.generate()

        wrong_lookup =
          if String.starts_with?(lookup, "0"),
            do: "1" <> String.slice(lookup, 1, 63),
            else: "0" <> String.slice(lookup, 1, 63)

        reference =
          case @reference_mismatch do
            :object_uuid ->
              @ids.empty_object_id

            :path_owner ->
              Enum.join(["objects", foreign, domain, "hmac-sha256", shard, lookup], "/")

            :path_domain ->
              Enum.join(["objects", vault, foreign, "hmac-sha256", shard, lookup], "/")

            :path_lookup ->
              Enum.join(
                [
                  "objects",
                  vault,
                  domain,
                  "hmac-sha256",
                  String.slice(wrong_lookup, 0, 2),
                  wrong_lookup
                ],
                "/"
              )
          end

        owner(fn ->
          assert %{num_rows: 1} =
                   owner_query!("UPDATE content.asset_objects SET storage_ref=$2 WHERE id=$1", [
                     dump(@ids.pdf_object_id),
                     reference
                   ])
        end)

        assert {:ok, :checked} =
                 scoped(fixture.owner, fn repo ->
                   assert %{rows: [[true]]} = guard_query(repo, fixture.owner.vault_id, 3)

                   assert {:error, %Error{code: :backup_unsupported, message: nil, details: %{}}} =
                            snapshot(repo, fixture.owner.vault_id, 3)

                   {:ok, :checked}
                 end)
      end)
    end
  end

  test "V3 recomputes retained closure and denies fabricated omissions and extra objects" do
    with_fixture(fn fixture ->
      assert {:ok, :checked} =
               scoped(fixture.owner, fn repo ->
                 assert {:ok, cut} = snapshot(repo, fixture.owner.vault_id, 3)
                 logical = Map.put(cut, :manifest_id, Ecto.UUID.generate())
                 [first | rest] = cut.object_inventory

                 omitted = %{
                   logical
                   | object_inventory:
                       Enum.with_index(rest, fn row, i -> %{row | inventory_position: i} end)
                 }

                 extra = %{
                   first
                   | asset_object_id: "ffffffff-ffff-4fff-8fff-ffffffffffff",
                     inventory_position: length(cut.object_inventory)
                 }

                 foreign = %{first | vault_id: Ecto.UUID.generate()}

                 for changed <- [
                       omitted,
                       %{logical | object_inventory: cut.object_inventory ++ [extra]},
                       %{logical | object_inventory: [foreign | rest]},
                       %{
                         logical
                         | object_inventory: [%{first | ciphertext_hash: <<0::256>>} | rest]
                       }
                     ] do
                   assert {:error, %Error{code: code}} = records(repo, changed, 3)

                   assert code in [
                            :invalid,
                            :backup_invalid,
                            :backup_unsupported,
                            :integrity_failure
                          ]
                 end

                 {:ok, :checked}
               end)
    end)
  end

  test "wire outbox order is sequence then UUID even when native PK order is opposite" do
    with_fixture(fn fixture ->
      earlier = "ffffffff-ffff-4fff-8fff-fffffffffff0"
      later = "00000000-0000-4000-8000-000000000001"

      owner(fn ->
        for id <- [earlier, later] do
          owner_query!(
            """
            INSERT INTO core.outbox_events(id,event_type,idempotency_key,vault_id,principal_id,
              required_capability,principal_authorization_epoch,vault_authorization_epoch,
              classification,correlation_id,expected_entity_revision,envelope_version,payload,occurred_at)
            SELECT $1,'document.extraction_requested',$2,vault_id,principal_id,required_capability,
              principal_authorization_epoch,vault_authorization_epoch,classification,$1,
              expected_entity_revision,envelope_version,payload,occurred_at
            FROM core.outbox_events WHERE vault_id=$3 ORDER BY sequence LIMIT 1
            """,
            [dump(id), "wire-order:" <> id, dump(fixture.owner.vault_id)]
          )
        end
      end)

      oracle = source_oracle(fixture.owner)
      assert [_, first, second] = oracle["core.outbox_events"]
      assert hd(first) == {"uuid", earlier}
      assert hd(second) == {"uuid", later}
      assert {:ok, rows} = export_rows(fixture, 3)
      assert_source_rows(rows, oracle)
    end)
  end

  test "native JSON null differs from SQL NULL throughout ordinary and identity projections" do
    with_fixture(fn fixture ->
      owner(fn ->
        for {table, where, params} <- [
              {"identity.people", "id IN (SELECT person_id FROM identity.accounts WHERE id=$1)",
               [dump(fixture.owner.account_id)]},
              {"identity.accounts", "id=$1", [dump(fixture.owner.account_id)]},
              {"identity.principals", "account_id=$1", [dump(fixture.owner.account_id)]},
              {"core.vaults", "id=$1", [dump(fixture.owner.vault_id)]},
              {"content.resources", "vault_id=$1", [dump(fixture.owner.vault_id)]}
            ] do
          owner_query!("UPDATE #{table} SET metadata='null'::jsonb WHERE #{where}", params)
        end

        owner_query!("UPDATE jobs.job_progress SET checkpoint='null'::jsonb WHERE vault_id=$1", [
          dump(fixture.owner.vault_id)
        ])

        owner_query!("UPDATE core.outbox_events SET payload='null'::jsonb WHERE vault_id=$1", [
          dump(fixture.owner.vault_id)
        ])
      end)

      oracle = source_oracle(fixture.owner)
      assert {:ok, rows} = export_rows(fixture, 3)
      assert_source_rows(rows, oracle)

      for {table, position} <- [
            {"identity.people", 2},
            {"identity.accounts", 3},
            {"identity.principals", 5},
            {"core.vaults", 4},
            {"content.resources", 5},
            {"jobs.job_progress", 7},
            {"core.outbox_events", 13}
          ] do
        for row <- rows_for(rows, table),
            do: assert(Enum.at(row.ordered_column_values, position) == {"json", nil})
      end

      pdf =
        Enum.find(
          rows_for(rows, "content.asset_objects"),
          &(&1.primary_key_values == [{"uuid", @ids.pdf_object_id}])
        )

      # Available objects require SQL NULL deletion evidence in the live DDL.
      assert Enum.at(pdf.ordered_column_values, 13) == {"null"}

      empty =
        Enum.find(
          rows_for(rows, "content.asset_objects"),
          &(&1.primary_key_values == [{"uuid", @ids.empty_object_id}])
        )

      assert Enum.at(empty.ordered_column_values, 13) == {"null"}

      [pending] =
        Enum.filter(
          rows_for(rows, "content.document_versions"),
          &(&1.primary_key_values == [{"uuid", @ids.pending_version_id}])
        )

      assert Enum.at(pending.ordered_column_values, 15) == {"null"}
      assert Enum.at(pending.ordered_column_values, 16) == {"null"}
      assert Enum.at(pending.ordered_column_values, 17) == {"null"}

      assert Enum.any?(
               rows_for(rows, "content.note_attachments"),
               &(Enum.at(&1.ordered_column_values, 10) == {"null"})
             )
    end)
  end

  test "advanced wrapper generation is valid with the existing active key generation" do
    with_fixture(fn fixture ->
      metadata = %{purpose: :vault_key, generation: 2, aad: fixture.owner.vault_id}

      assert {:ok, wrapped} =
               KeyWrapper.wrap(fixture.keys.password_key, fixture.keys.vault_key, metadata)

      assert {:ok, key} = KeyWrapper.unwrap(fixture.keys.password_key, wrapped.encoded, metadata)
      assert key == fixture.keys.vault_key

      owner(fn ->
        owner_query!(
          "UPDATE core.vault_key_wrappers SET generation=2,wrapped_key=$2 WHERE vault_id=$1",
          [dump(fixture.owner.vault_id), wrapped.encoded]
        )
      end)

      assert {:ok, rows} = export_rows(fixture, 3)
      [wrapper] = rows_for(rows, "core.vault_key_wrappers")
      [key] = rows_for(rows, "core.vault_key_versions")
      assert Enum.at(wrapper.ordered_column_values, 4) == {"integer", 2}
      assert Enum.at(key.ordered_column_values, 2) == {"integer", 1}
    end)
  end

  test "raw retained originals reject disagreement with actual ciphertext evidence" do
    with_fixture(fn fixture ->
      owner(fn ->
        owner_query!("UPDATE content.asset_objects SET ciphertext_hash=$2 WHERE id=$1", [
          dump(@ids.pdf_object_id),
          <<0::256>>
        ])
      end)

      assert {:ok, :checked} =
               scoped(fixture.owner, fn repo ->
                 assert {:ok, cut} = snapshot(repo, fixture.owner.vault_id, 3)
                 assert {:ok, raw} = raw_inventory(repo, storage(fixture), cut)

                 entry =
                   Enum.find(
                     Enum.to_list(raw.records),
                     &(&1.asset_object_id == @ids.pdf_object_id)
                   )

                 assert {Exporter, :object_stream_error, %Error{code: :integrity_failure}} =
                          catch_throw(Enum.to_list(entry.payload))

                 {:ok, :checked}
               end)
    end)
  end

  test "receipt export is whole-owner while direct RLS remains principal-specific" do
    with_fixture(fn fixture ->
      second = Ecto.UUID.generate()
      mutation = Ecto.UUID.generate()

      owner(fn ->
        owner_query!(
          "INSERT INTO identity.principals(id,account_id,kind) VALUES($1,$2,'owner')",
          [dump(second), dump(fixture.owner.account_id)]
        )

        owner_query!(
          "INSERT INTO core.vault_members(principal_id,vault_id,clearance) VALUES($1,$2,'restricted')",
          [dump(second), dump(fixture.owner.vault_id)]
        )

        grant_backup!(%{fixture.owner | principal_id: second})

        owner_query!(
          """
          INSERT INTO content.document_import_receipts(vault_id,principal_id,mutation_id,
            request_fingerprint,state,resource_id,version_id,inserted_at)
          VALUES($1,$2,$3,$4,'completed',$5,$6,CURRENT_TIMESTAMP)
          """,
          [
            dump(fixture.owner.vault_id),
            dump(second),
            dump(mutation),
            :crypto.hash(:sha256, "second-owner-principal"),
            dump(@ids.ready_document_id),
            dump(@ids.ready_current_version_id)
          ]
        )
      end)

      oracle = source_oracle(fixture.owner)
      assert length(oracle["content.document_import_receipts"]) == 8

      assert {:ok, :checked} =
               scoped(fixture.owner, fn repo ->
                 assert %{rows: [[false]]} =
                          SafeSQL.query!(
                            repo,
                            "SELECT has_table_privilege(current_user,'content.document_import_receipts','SELECT')",
                            []
                          )

                 result =
                   SafeSQL.query!(
                     repo,
                     "SELECT * FROM content.export_document_import_receipts_for_backup($1) ORDER BY vault_id,principal_id,mutation_id",
                     [dump(fixture.owner.vault_id)]
                   )

                 assert result.columns ==
                          ~w(vault_id principal_id mutation_id request_fingerprint state resource_id version_id inserted_at)

                 assert length(result.rows) == 8
                 assert Enum.any?(result.rows, &(Enum.at(&1, 1) == dump(second)))
                 assert {:ok, cut} = snapshot(repo, fixture.owner.vault_id, 3)

                 assert {:ok, export} =
                          records(repo, Map.put(cut, :manifest_id, Ecto.UUID.generate()), 3)

                 assert_source_rows(
                   Enum.filter(decode(Enum.to_list(export.records)), &(&1.kind == :row)),
                   oracle
                 )

                 {:ok, :checked}
               end)

      policy_before = receipt_policy()

      owner(fn ->
        owner_query!("GRANT SELECT ON content.document_import_receipts TO singularity_worker")
      end)

      try do
        for {principal, count} <- [{fixture.owner.principal_id, 7}, {second, 1}] do
          assert {:ok, :checked} =
                   scoped(%{fixture.owner | principal_id: principal}, fn repo ->
                     assert %{rows: direct} =
                              SafeSQL.query!(
                                repo,
                                "SELECT principal_id FROM content.document_import_receipts WHERE vault_id=$1",
                                [dump(fixture.owner.vault_id)]
                              )

                     assert length(direct) == count
                     assert Enum.all?(direct, &(&1 == [dump(principal)]))

                     assert %{rows: all} =
                              SafeSQL.query!(
                                repo,
                                "SELECT principal_id FROM content.export_document_import_receipts_for_backup($1)",
                                [dump(fixture.owner.vault_id)]
                              )

                     assert length(all) == 8
                     {:ok, :checked}
                   end)
        end
      after
        owner(fn ->
          owner_query!(
            "REVOKE SELECT ON content.document_import_receipts FROM singularity_worker"
          )
        end)
      end

      assert receipt_policy() == policy_before
    end)
  end

  test "forward read grants and definer helpers preserve mutation, identity and private restore boundaries" do
    with_fixture(fn fixture ->
      assert {:ok, :checked} =
               scoped(fixture.owner, fn repo ->
                 for table <- @added do
                   expected = table != "content.document_import_receipts"

                   assert %{rows: [[^expected]]} =
                            SafeSQL.query!(
                              repo,
                              "SELECT has_table_privilege('singularity_worker',$1,'SELECT')",
                              [table]
                            )

                   for role <- @roles,
                       privilege <- ~w(INSERT UPDATE DELETE TRUNCATE REFERENCES TRIGGER) do
                     # Preserve the already accepted Phase 4 web mutation grants exactly.
                     permitted? =
                       role == "singularity_web" and
                         ((privilege == "INSERT" and
                             table in ~w(content.note_attachments content.note_citations content.tags content.resource_tags content.relationships)) or
                            (privilege == "DELETE" and
                               table in ~w(content.resource_tags content.relationships)))

                     assert %{rows: [[^permitted?]]} =
                              SafeSQL.query!(repo, "SELECT has_table_privilege($1,$2,$3)", [
                                role,
                                table,
                                privilege
                              ])
                   end
                 end

                 for signature <- [@receipt_helper, @version_guard] do
                   assert %{rows: [[true, "s", "singularity_table_owner", config, body]]} =
                            SafeSQL.query!(
                              repo,
                              "SELECT p.prosecdef,p.provolatile::text,r.rolname,p.proconfig,p.prosrc FROM pg_proc p JOIN pg_roles r ON r.oid=p.proowner WHERE p.oid=$1::text::regprocedure",
                              [signature]
                            )

                   assert config == ["search_path=pg_catalog, content, core"]
                   normalized = String.replace(body, ~r/\s+/, " ")
                   assert normalized =~ "core.live_principal_authorization()"
                   assert normalized =~ "principal_kind"
                   assert normalized =~ "owner"
                   assert normalized =~ "principal_revoked_at IS NULL"
                   assert normalized =~ "membership_revoked_at IS NULL"
                   assert normalized =~ "backup.create"
                   assert normalized =~ "42501"
                   refute normalized =~ "audit.assert_knowledge_restore_graph"
                   refute normalized =~ "knowledge_restore_is_bound"

                   for role <- @roles do
                     expected = role == "singularity_worker"

                     assert %{rows: [[^expected]]} =
                              SafeSQL.query!(
                                repo,
                                "SELECT has_function_privilege($1,$2,'EXECUTE')",
                                [role, signature]
                              )
                   end

                   assert %{rows: [[false]]} =
                            SafeSQL.query!(
                              repo,
                              "SELECT EXISTS(SELECT 1 FROM pg_proc p,LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) acl WHERE p.oid=$1::text::regprocedure AND acl.grantee=0 AND acl.privilege_type='EXECUTE')",
                              [signature]
                            )
                 end

                 assert %{rows: types} =
                          SafeSQL.query!(
                            repo,
                            "SELECT p.proargnames[i],format_type(p.proallargtypes[i],NULL) FROM pg_proc p CROSS JOIN LATERAL generate_subscripts(p.proallargtypes,1) i WHERE p.oid=$1::text::regprocedure ORDER BY i",
                            [@receipt_helper]
                          )

                 assert Enum.take(types, -8) == [
                          ["vault_id", "uuid"],
                          ["principal_id", "uuid"],
                          ["mutation_id", "uuid"],
                          ["request_fingerprint", "bytea"],
                          ["state", "text"],
                          ["resource_id", "uuid"],
                          ["version_id", "uuid"],
                          ["inserted_at", "timestamp with time zone"]
                        ]

                 assert %{rows: [[body]]} =
                          SafeSQL.query!(
                            repo,
                            "SELECT prosrc FROM pg_proc WHERE oid=$1::text::regprocedure",
                            [@receipt_helper]
                          )

                 for field <-
                       ~w(vault_id principal_id mutation_id request_fingerprint state resource_id version_id inserted_at),
                     do: assert(body =~ ".#{field}")

                 refute body =~ "SELECT *"
                 refute body =~ "state = 'completed'"
                 refute body =~ "state='completed'"
                 refute body =~ "EXECUTE "

                 assert %{rows: [[true, true]]} =
                          SafeSQL.query!(
                            repo,
                            "SELECT relrowsecurity,relforcerowsecurity FROM pg_class WHERE oid='content.document_import_receipts'::regclass",
                            []
                          )

                 for role <- @roles,
                     table <-
                       ~w(identity.people identity.accounts identity.credentials identity.principals core.vault_key_wrappers core.domain_key_versions),
                     privilege <- ~w(INSERT UPDATE DELETE) do
                   # Frozen 20260718000600 grants both old key tables to web/worker.
                   # Assert the complete accepted matrix, not a new blanket denial.
                   expected =
                     role in ~w(singularity_worker singularity_web) and
                       table in ~w(core.vault_key_wrappers core.domain_key_versions)

                   assert %{rows: [[^expected]]} =
                            SafeSQL.query!(repo, "SELECT has_table_privilege($1,$2,$3)", [
                              role,
                              table,
                              privilege
                            ])
                 end

                 for role <- @roles,
                     signature <- [
                       "audit.assert_knowledge_restore_graph(uuid)",
                       "audit.knowledge_restore_is_bound(uuid)"
                     ] do
                   assert %{rows: [[false]]} =
                            SafeSQL.query!(
                              repo,
                              "SELECT has_function_privilege($1,$2,'EXECUTE')",
                              [role, signature]
                            )
                 end

                 {:ok, :checked}
               end)
    end)
  end

  test "versioned guard preserves the complete frozen one-argument function and authenticates first" do
    with_fixture(fn fixture ->
      legacy =
        owner(fn ->
          owner_query!(
            "SELECT prosrc,proacl::text,proowner,proconfig FROM pg_proc WHERE oid='content.backup_has_unsupported_canonical_rows(uuid)'::regprocedure"
          ).rows
        end)

      [[legacy_body, _acl, _owner, legacy_config]] = legacy

      source =
        Path.expand(
          "../../../../priv/repo/migrations/20260922000000_backup_unsupported_guard.exs",
          __DIR__
        )
        |> File.read!()

      [_, frozen_body] = Regex.run(~r/AS \$function\$(.*?)\$function\$/s, source)
      assert normalize_sql(legacy_body) == normalize_sql(frozen_body)
      assert legacy_config == ["search_path=pg_catalog, content, core"]

      assert {:ok, :checked} =
               scoped(fixture.owner, fn repo ->
                 for version <- [1, 2, 0, 4, 99] do
                   assert %{rows: [[true]]} = guard_query(repo, fixture.owner.vault_id, version)
                 end

                 assert %{rows: [[false]]} = guard_query(repo, fixture.owner.vault_id, 3)

                 assert %{rows: [[true]]} =
                          SafeSQL.query!(
                            repo,
                            "SELECT content.backup_has_unsupported_canonical_rows($1)",
                            [dump(fixture.owner.vault_id)]
                          )

                 {:ok, :checked}
               end)

      assert owner(fn ->
               owner_query!(
                 "SELECT prosrc,proacl::text,proowner,proconfig FROM pg_proc WHERE oid='content.backup_has_unsupported_canonical_rows(uuid)'::regprocedure"
               ).rows
             end) == legacy
    end)
  end

  for rejection <- [
        :foreign_owner,
        :no_capability,
        :revoked_principal,
        :revoked_membership,
        :system_principal
      ] do
    @rejection rejection
    test "whole-owner helper and versioned guard deny #{@rejection} without content leakage" do
      with_fixture(fn fixture ->
        principal = Ecto.UUID.generate()
        requested = fixture.owner.vault_id

        owner(fn ->
          kind = if @rejection == :system_principal, do: "system", else: "owner"

          owner_query!("INSERT INTO identity.principals(id,account_id,kind) VALUES($1,$2,$3)", [
            dump(principal),
            dump(fixture.owner.account_id),
            kind
          ])

          owner_query!(
            "INSERT INTO core.vault_members(principal_id,vault_id,clearance) VALUES($1,$2,'restricted')",
            [dump(principal), dump(requested)]
          )

          if @rejection != :no_capability,
            do: grant_backup!(%{fixture.owner | principal_id: principal})

          if @rejection == :revoked_principal,
            do:
              owner_query!(
                "UPDATE identity.principals SET revoked_at=CURRENT_TIMESTAMP WHERE id=$1",
                [dump(principal)]
              )

          if @rejection == :revoked_membership,
            do:
              owner_query!(
                "UPDATE core.vault_members SET revoked_at=CURRENT_TIMESTAMP WHERE principal_id=$1 AND vault_id=$2",
                [dump(principal), dump(requested)]
              )
        end)

        context =
          if @rejection == :foreign_owner do
            owner(fn -> foreign_owner!() end)
          else
            %{principal_id: principal, vault_id: requested}
          end

        log =
          capture_log(fn ->
            assert {:ok, :checked} =
                     scoped(context, fn repo ->
                       for version <- [1, 2, 3, 99] do
                         denied_sql(
                           repo,
                           "SELECT content.backup_has_unsupported_canonical_rows($1,$2)",
                           [dump(requested), version]
                         )
                       end

                       denied_sql(
                         repo,
                         "SELECT * FROM content.export_document_import_receipts_for_backup($1)",
                         [dump(requested)]
                       )

                       SQL.query!(repo, "SAVEPOINT writer_denial", [], log: false)
                       result = snapshot(repo, requested, 3)
                       SQL.query!(repo, "ROLLBACK TO SAVEPOINT writer_denial", [], log: false)

                       assert result ==
                                {:error, Error.new(:storage_unavailable, retryable?: true)}

                       refute inspect(result) =~ "Fixture Document"
                       refute inspect(result) =~ "# Merged fixture"
                       {:ok, :checked}
                     end)
          end)

        refute log =~ "Fixture Document"
        refute log =~ "# Merged fixture"
        refute log =~ @originals.unicode
      end)
    end
  end

  for defect <- [
        :storage_format,
        :extractor_format,
        :extractor_adapter,
        :missing_envelope,
        :unavailable_retained,
        :source_size,
        :source_classification,
        :missing_typed_history
      ] do
    @defect defect
    test "V3 guard fails closed for legal persisted #{@defect} corruption" do
      with_fixture(fn fixture ->
        owner(fn -> corrupt!(@defect, fixture) end)

        assert {:ok, :checked} =
                 scoped(fixture.owner, fn repo ->
                   assert %{rows: [[true]]} = guard_query(repo, fixture.owner.vault_id, 3)

                   assert {:error, %Error{code: :backup_unsupported, message: nil, details: %{}}} =
                            snapshot(repo, fixture.owner.vault_id, 3)

                   {:ok, :checked}
                 end)
      end)
    end
  end

  test "pending receipts are returned by the helper and denied before their ordinary deferred commit guard" do
    with_fixture(fn fixture ->
      assert {:error, :fixture_rollback} =
               MigrationRepo.transaction(fn ->
                 owner_query!("SET LOCAL ROLE singularity_table_owner")

                 owner_query!(
                   "INSERT INTO content.document_import_receipts(vault_id,principal_id,mutation_id,request_fingerprint,inserted_at) VALUES($1,$2,$3,$4,CURRENT_TIMESTAMP)",
                   [
                     dump(fixture.owner.vault_id),
                     dump(fixture.owner.principal_id),
                     dump(Ecto.UUID.generate()),
                     <<7::256>>
                   ]
                 )

                 use_precommit_owner_context!(fixture.owner)

                 assert %{rows: [[1]]} =
                          owner_query!(
                            "SELECT count(*) FROM content.export_document_import_receipts_for_backup($1) WHERE state='pending'",
                            [dump(fixture.owner.vault_id)]
                          )

                 assert %{rows: [[true]]} = guard_query(MigrationRepo, fixture.owner.vault_id, 3)
                 MigrationRepo.rollback(:fixture_rollback)
               end)
    end)
  end

  test "incomplete ready fragments fail closed before ordinary completion validation" do
    with_fixture(fn fixture ->
      assert {:error, :fixture_rollback} =
               MigrationRepo.transaction(fn ->
                 owner_query!("SET LOCAL ROLE singularity_table_owner")

                 owner_query!(
                   "UPDATE content.document_versions SET state='ready',extracted_text_digest=$2,attempt_finished_at=CURRENT_TIMESTAMP WHERE resource_version_id=$1",
                   [
                     dump(@ids.extracting_version_id),
                     :crypto.hash(:sha256, "missing-fragments-canary")
                   ]
                 )

                 use_precommit_owner_context!(fixture.owner)
                 assert %{rows: [[true]]} = guard_query(MigrationRepo, fixture.owner.vault_id, 3)
                 MigrationRepo.rollback(:fixture_rollback)
               end)
    end)
  end

  test "completed receipt disagreement fails closed before its ordinary deferred FK" do
    with_fixture(fn fixture ->
      assert {:error, :fixture_rollback} =
               MigrationRepo.transaction(fn ->
                 owner_query!("SET LOCAL ROLE singularity_table_owner")
                 source = fixture.sources.plain

                 owner_query!(
                   "UPDATE content.document_import_receipts SET resource_id=$1,version_id=$2 WHERE vault_id=$3 AND mutation_id=$4",
                   [
                     dump(source.resource_id),
                     dump(source.resource_version_id),
                     dump(fixture.owner.vault_id),
                     dump(@ids.ready_old_version_id)
                   ]
                 )

                 use_precommit_owner_context!(fixture.owner)
                 assert %{rows: [[true]]} = guard_query(MigrationRepo, fixture.owner.vault_id, 3)
                 MigrationRepo.rollback(:fixture_rollback)
               end)
    end)
  end

  test "missing Note source seal fails closed before its ordinary deferred finalizer" do
    with_fixture(fn fixture ->
      version = Ecto.UUID.generate()

      assert {:error, :fixture_rollback} =
               MigrationRepo.transaction(fn ->
                 owner_query!("SET LOCAL ROLE singularity_table_owner")

                 owner_query!(
                   "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',99)",
                   [dump(version), dump(@ids.live_note_id), dump(fixture.owner.vault_id)]
                 )

                 owner_query!(
                   "INSERT INTO content.note_versions(resource_version_id,resource_id,vault_id,classification,title,markdown,created_by_principal_id,parent_version_id,inserted_at) VALUES($1,$2,$3,'private','Unsealed canary','# Unsealed canary',$4,$5,CURRENT_TIMESTAMP)",
                   [
                     dump(version),
                     dump(@ids.live_note_id),
                     dump(fixture.owner.vault_id),
                     dump(fixture.owner.principal_id),
                     dump(@ids.merge_note_version_id)
                   ]
                 )

                 use_precommit_owner_context!(fixture.owner)
                 assert %{rows: [[true]]} = guard_query(MigrationRepo, fixture.owner.vault_id, 3)
                 MigrationRepo.rollback(:fixture_rollback)
               end)
    end)
  end

  test "citation locator disagreement fails closed before ordinary source-set validation" do
    with_fixture(fn fixture ->
      version = Ecto.UUID.generate()

      assert {:error, :fixture_rollback} =
               MigrationRepo.transaction(fn ->
                 owner_query!("SET LOCAL ROLE singularity_table_owner")

                 owner_query!(
                   "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',99)",
                   [dump(version), dump(@ids.live_note_id), dump(fixture.owner.vault_id)]
                 )

                 owner_query!(
                   "INSERT INTO content.note_versions(resource_version_id,resource_id,vault_id,classification,title,markdown,created_by_principal_id,parent_version_id,inserted_at) VALUES($1,$2,$3,'private','Citation canary','# Citation canary',$4,$5,CURRENT_TIMESTAMP)",
                   [
                     dump(version),
                     dump(@ids.live_note_id),
                     dump(fixture.owner.vault_id),
                     dump(fixture.owner.principal_id),
                     dump(@ids.merge_note_version_id)
                   ]
                 )

                 owner_query!(
                   """
                   INSERT INTO content.note_citations(note_resource_version_id,id,note_resource_id,vault_id,
                     classification,source_resource_id,source_resource_version_id,fragment_id,locator,ordinal,inserted_at)
                   SELECT $1,$2,$3,vault_id,classification,resource_id,resource_version_id,id,
                     '{"version":1,"kind":"pdf","page":999}'::jsonb,0,CURRENT_TIMESTAMP
                   FROM content.document_fragments WHERE resource_version_id=$4 AND ordinal=0
                   """,
                   [
                     dump(version),
                     dump(Ecto.UUID.generate()),
                     dump(@ids.live_note_id),
                     dump(@ids.ready_current_version_id)
                   ]
                 )

                 use_precommit_owner_context!(fixture.owner)
                 assert %{rows: [[true]]} = guard_query(MigrationRepo, fixture.owner.vault_id, 3)
                 MigrationRepo.rollback(:fixture_rollback)
               end)
    end)
  end

  test "ordinary constraints reject unknown kinds, malformed attempts and changed source pins" do
    with_fixture(fn fixture ->
      owner(fn ->
        for {statement, parameters, constraint} <- [
              {"INSERT INTO content.resources(id,vault_id,classification,title,kind) VALUES($1,$2,'private','Unknown kind canary','future_kind')",
               [dump(Ecto.UUID.generate()), dump(fixture.owner.vault_id)],
               "resources_kind_check"},
              {"UPDATE content.document_versions SET state='extracting',attempt_generation=1,attempt_job_id=$2,attempt_started_at=$3::timestamptz,attempt_deadline_at=$3::timestamptz+interval '1 second',extraction_adapter='plain_text',extraction_format=1 WHERE resource_version_id=$1",
               [
                 dump(@ids.pending_version_id),
                 dump(Ecto.UUID.generate()),
                 ~U[2026-10-11 00:00:00Z]
               ], "document_versions_state_shape_check"},
              {"UPDATE content.document_versions SET source_digest=$2 WHERE resource_version_id=$1",
               [dump(@ids.pending_version_id), <<0::256>>], "document_versions_immutable_check"}
            ] do
          owner_query!("SAVEPOINT ordinary_shape")

          assert {:error,
                  %Postgrex.Error{postgres: %{code: :check_violation, constraint: ^constraint}}} =
                   SQL.query(MigrationRepo, statement, parameters, log: false)

          owner_query!("ROLLBACK TO SAVEPOINT ordinary_shape")
        end
      end)

      assert {:ok, _rows} = export_rows(fixture, 3)
    end)
  end

  test "cut, SQL oracle and lazy rows retain old heads and tags after an independent commit" do
    with_fixture(fn fixture ->
      oracle = source_oracle(fixture.owner)
      parent = self()
      reference = make_ref()
      supervisor = start_supervised!(Task.Supervisor)

      writer =
        Task.Supervisor.async_nolink(supervisor, fn ->
          receive do
            {^reference, :write} ->
              owner(fn ->
                %{rows: [[pid]]} = owner_query!("SELECT pg_backend_pid()")

                owner_query!("UPDATE content.resources SET current_version_id=$1 WHERE id=$2", [
                  dump(@ids.ready_old_version_id),
                  dump(@ids.ready_document_id)
                ])

                owner_query!(
                  "INSERT INTO content.tags(id,vault_id,classification,display_value,normalized_key,created_by_principal_id,inserted_at) VALUES($1,$2,'private','new tag canary','new tag canary',$3,CURRENT_TIMESTAMP)",
                  [
                    dump(Ecto.UUID.generate()),
                    dump(fixture.owner.vault_id),
                    dump(fixture.owner.principal_id)
                  ]
                )

                send(parent, {reference, :writer_backend, pid})
              end)

              :committed
          after
            10_000 -> raise "V3 snapshot writer was not released"
          end
        end)

      try do
        assert {:ok, :checked} =
                 scoped(fixture.owner, fn repo ->
                   %{rows: [[reader_pid]]} = SafeSQL.query!(repo, "SELECT pg_backend_pid()", [])
                   assert {:ok, capture} = snapshot(repo, fixture.owner.vault_id, 3)

                   assert {:ok, export} =
                            records(repo, Map.put(capture, :manifest_id, Ecto.UUID.generate()), 3)

                   send(writer.pid, {reference, :write})
                   assert :committed = Task.await(writer, 10_000)
                   assert_receive {^reference, :writer_backend, writer_pid}
                   refute reader_pid == writer_pid

                   assert_source_rows(
                     Enum.filter(decode(Enum.to_list(export.records)), &(&1.kind == :row)),
                     oracle
                   )

                   assert {:ok, second} = snapshot(repo, fixture.owner.vault_id, 3)
                   assert Map.drop(second, [:snapshot_id]) == Map.drop(capture, [:snapshot_id])
                   {:ok, :checked}
                 end)
      after
        Task.shutdown(writer, 5_000)
        refute Process.alive?(writer.pid)
      end

      assert source_oracle(fixture.owner) != oracle
    end)
  end

  test "logical header and raw entry streams deny consumption after transaction closure before SQL or reads" do
    with_fixture(fn fixture ->
      assert {:ok, {logical, raw, payload}} =
               scoped(fixture.owner, fn repo ->
                 assert {:ok, cut} = snapshot(repo, fixture.owner.vault_id, 3)

                 assert {:ok, logical} =
                          records(repo, Map.put(cut, :manifest_id, Ecto.UUID.generate()), 3)

                 assert {:ok, raw} = raw_inventory(repo, counting_storage(fixture), cut)
                 [entry] = Enum.take(raw.records, 1)
                 {:ok, {logical.records, raw.records, entry.payload}}
               end)

      assert_stream_denied(fn -> Enum.take(logical, 1) end)
      assert_stream_denied(fn -> Enum.take(raw, 1) end)
      assert_stream_denied(fn -> Enum.take(payload, 1) end)
      refute_receive {:adapter_open, _, _}
      refute_receive {:adapter_read, _, _}
    end)
  end

  test "same backend with a new full transaction ID cannot consume previously constructed streams" do
    with_fixture(fn fixture ->
      assert {:ok, {binding, logical, raw}} =
               scoped(fixture.owner, fn repo ->
                 binding = transaction_identity(repo)
                 assert {:ok, cut} = snapshot(repo, fixture.owner.vault_id, 3)

                 assert {:ok, logical} =
                          records(repo, Map.put(cut, :manifest_id, Ecto.UUID.generate()), 3)

                 assert {:ok, raw} = raw_inventory(repo, counting_storage(fixture), cut)
                 {:ok, {binding, logical.records, raw.records}}
               end)

      assert {:ok, :checked} =
               scoped(fixture.owner, fn repo ->
                 current = transaction_identity(repo)
                 assert current.backend == binding.backend
                 refute current.xid == binding.xid
                 assert_stream_denied(fn -> Enum.take(logical, 1) end)
                 assert_stream_denied(fn -> Enum.take(raw, 1) end)
                 refute_receive {:adapter_open, _, _}
                 refute_receive {:adapter_read, _, _}
                 {:ok, :checked}
               end)
    end)
  end

  test "different caller cannot consume a live stream or open a raw object" do
    with_fixture(fn fixture ->
      supervisor = start_supervised!(Task.Supervisor)

      assert {:ok, :checked} =
               scoped(fixture.owner, fn repo ->
                 assert {:ok, cut} = snapshot(repo, fixture.owner.vault_id, 3)

                 assert {:ok, logical} =
                          records(repo, Map.put(cut, :manifest_id, Ecto.UUID.generate()), 3)

                 assert {:ok, raw} = raw_inventory(repo, counting_storage(fixture), cut)
                 [entry | _] = Enum.to_list(raw.records)

                 task =
                   Task.Supervisor.async_nolink(supervisor, fn ->
                     assert_stream_denied(fn -> Enum.take(logical.records, 1) end)
                     assert_stream_denied(fn -> Enum.take(raw.records, 1) end)
                     assert_stream_denied(fn -> Enum.take(entry.payload, 1) end)
                     :checked
                   end)

                 try do
                   assert :checked = Task.await(task, 5_000)
                 after
                   Task.shutdown(task, 5_000)
                   refute Process.alive?(task.pid)
                 end

                 refute_receive {:adapter_open, _, _}
                 refute_receive {:adapter_read, _, _}
                 {:ok, :checked}
               end)
    end)
  end

  test "scope changes invalidate logical records and raw entries before any content read" do
    with_fixture(fn fixture ->
      assert {:ok, :checked} =
               scoped(fixture.owner, fn repo ->
                 assert {:ok, cut} = snapshot(repo, fixture.owner.vault_id, 3)

                 assert {:ok, logical} =
                          records(repo, Map.put(cut, :manifest_id, Ecto.UUID.generate()), 3)

                 assert {:ok, raw} = raw_inventory(repo, counting_storage(fixture), cut)

                 for setting <- ~w(singularity.principal_id singularity.vault_id) do
                   original =
                     if setting == "singularity.principal_id",
                       do: fixture.owner.principal_id,
                       else: fixture.owner.vault_id

                   SafeSQL.query!(repo, "SELECT set_config($1,$2,true)", [
                     setting,
                     Ecto.UUID.generate()
                   ])

                   assert_stream_denied(fn -> Enum.take(logical.records, 1) end)
                   assert_stream_denied(fn -> Enum.take(raw.records, 1) end)
                   SafeSQL.query!(repo, "SELECT set_config($1,$2,true)", [setting, original])
                 end

                 refute_receive {:adapter_open, _, _}
                 refute_receive {:adapter_read, _, _}
                 {:ok, :checked}
               end)
    end)
  end

  test "every suspended logical record and raw entry rechecks the live binding" do
    with_fixture(fn fixture ->
      assert {:ok, :checked} =
               scoped(fixture.owner, fn repo ->
                 assert {:ok, cut} = snapshot(repo, fixture.owner.vault_id, 3)

                 assert {:ok, logical} =
                          records(repo, Map.put(cut, :manifest_id, Ecto.UUID.generate()), 3)

                 assert {:ok, raw} = raw_inventory(repo, counting_storage(fixture), cut)
                 suspend = fn item, _acc -> {:suspend, item} end

                 assert {:suspended, %{type: 0x0001}, logical_next} =
                          Enumerable.reduce(logical.records, {:cont, nil}, suspend)

                 assert {:suspended, %{type: 0x8000}, raw_next} =
                          Enumerable.reduce(raw.records, {:cont, nil}, suspend)

                 SafeSQL.query!(repo, "SELECT set_config('singularity.principal_id',$1,true)", [
                   Ecto.UUID.generate()
                 ])

                 try do
                   assert_stream_denied(fn -> logical_next.({:cont, nil}) end)
                   assert_stream_denied(fn -> raw_next.({:cont, nil}) end)
                   refute_receive {:adapter_open, _, _}
                   refute_receive {:adapter_read, _, _}
                 after
                   logical_next.({:halt, nil})
                   raw_next.({:halt, nil})

                   SafeSQL.query!(repo, "SELECT set_config('singularity.principal_id',$1,true)", [
                     fixture.owner.principal_id
                   ])
                 end

                 {:ok, :checked}
               end)
    end)
  end

  test "another backend with the same owner, principal and isolation cannot consume live streams" do
    with_fixture(fn fixture ->
      {:ok, alternate} = WorkerRepo.start_link(name: nil, pool_size: 1)
      Process.unlink(alternate)
      original = WorkerRepo.get_dynamic_repo()

      try do
        assert {:ok, :checked} =
                 scoped(fixture.owner, fn repo ->
                   binding = transaction_identity(repo)
                   assert {:ok, cut} = snapshot(repo, fixture.owner.vault_id, 3)

                   assert {:ok, logical} =
                            records(repo, Map.put(cut, :manifest_id, Ecto.UUID.generate()), 3)

                   assert {:ok, raw} = raw_inventory(repo, counting_storage(fixture), cut)
                   WorkerRepo.put_dynamic_repo(alternate)

                   try do
                     assert {:ok, :checked} =
                              WorkerRepo.transaction(fn ->
                                # Raw adapter SQL uses its explicit repo/PID, unlike
                                # Ecto transaction/2's get_dynamic_repo dispatch.
                                SafeSQL.query!(
                                  alternate,
                                  "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ",
                                  []
                                )

                                assert %{rows: [[true, true]]} =
                                         SafeSQL.query!(
                                           alternate,
                                           "SELECT NULLIF(current_setting('singularity.vault_id',true),'') IS NULL,NULLIF(current_setting('singularity.principal_id',true),'') IS NULL",
                                           []
                                         )

                                SafeSQL.query!(
                                  alternate,
                                  "SELECT set_config('singularity.vault_id',$1,true),set_config('singularity.principal_id',$2,true)",
                                  [fixture.owner.vault_id, fixture.owner.principal_id]
                                )

                                current = transaction_identity(alternate)
                                refute current.backend == binding.backend

                                assert SafeSQL.query!(
                                         alternate,
                                         "SELECT current_setting('transaction_isolation'),current_setting('singularity.vault_id'),current_setting('singularity.principal_id')",
                                         []
                                       ).rows == [
                                         [
                                           "repeatable read",
                                           fixture.owner.vault_id,
                                           fixture.owner.principal_id
                                         ]
                                       ]

                                assert_stream_denied(fn -> Enum.take(logical.records, 1) end)
                                assert_stream_denied(fn -> Enum.take(raw.records, 1) end)
                                refute_receive {:adapter_open, _, _}
                                refute_receive {:adapter_read, _, _}
                                :checked
                              end)
                   after
                     WorkerRepo.put_dynamic_repo(original)
                   end

                   {:ok, :checked}
                 end)
      after
        WorkerRepo.put_dynamic_repo(original)
        if Process.alive?(alternate), do: Supervisor.stop(alternate)
        refute Process.alive?(alternate)
      end
    end)
  end

  test "raw payload continuation denies the second 64 KiB read after its transaction closes" do
    # Real encrypted original large enough for multiple adapter reads.
    originals = %{@originals | plain: String.duplicate("large original canary\n", 7_000)}

    with_fixture(
      fn fixture ->
        assert {:ok, continuation} =
                 scoped(fixture.owner, fn repo ->
                   assert {:ok, cut} = snapshot(repo, fixture.owner.vault_id, 3)
                   assert {:ok, raw} = raw_inventory(repo, counting_storage(fixture), cut)

                   entry =
                     Enum.find(
                       Enum.to_list(raw.records),
                       &(&1.asset_object_id == @ids.plain_object_id)
                     )

                   assert {:suspended, first, continuation} =
                            Enumerable.reduce(entry.payload, {:cont, nil}, fn chunk, _ ->
                              {:suspend, chunk}
                            end)

                   assert byte_size(first) == 65_536
                   assert_receive {:adapter_open, _, _}
                   assert_receive {:adapter_read, _, %Range{first: 0, last: 65_535}}
                   {:ok, continuation}
                 end)

        try do
          assert_stream_denied(fn -> continuation.({:cont, nil}) end)
          refute_receive {:adapter_read, _, _}
        after
          continuation.({:halt, nil})
        end
      end,
      originals
    )
  end

  test "repository-aware raw composition keeps V2 success and bare-storage compatibility" do
    note = NoteFixtures.note!()
    Fixtures.with_owner(fn -> grant_backup!(note) end)

    assert {:ok, :checked} =
             scoped(note, fn repo ->
               assert {:ok, capture} = snapshot(repo, note.vault_id, 2)
               assert capture.object_inventory == []
               context = {CountingStorage, %{observer: self(), root: "unused-empty-inventory"}}
               assert {:ok, aware} = raw_inventory(repo, context, capture)

               assert {:ok, delegated} =
                        Exporter.stream_inventory(%{repo: repo, storage: context}, capture)

               assert {:ok, bare} = Exporter.stream_inventory(context, capture)
               assert aware.inventory == delegated.inventory
               assert bare.inventory == aware.inventory
               assert Enum.to_list(aware.records) == []
               assert Enum.to_list(delegated.records) == []
               assert Enum.to_list(bare.records) == []

               for bad <- [
                     Map.put(capture, :logical_version, 2),
                     Map.put(capture, :manifest_id, Ecto.UUID.generate()),
                     Map.delete(capture, :snapshot_id)
                   ] do
                 assert {:error, %Error{code: :invalid}} = raw_inventory(repo, context, bad)
               end

               assert {:error, %Error{code: :invalid}} =
                        raw_inventory(RequestRepo, context, capture)

               {:ok, :checked}
             end)
  end

  test "successful V3 logical and object streaming exposes no content on Logger or raw query telemetry" do
    with_fixture(fn fixture ->
      handler = {__MODULE__, self(), make_ref()}

      assert :ok =
               :telemetry.attach(
                 handler,
                 [:singularity, :storage, :worker_repo, :query],
                 &__MODULE__.capture_query/4,
                 self()
               )

      try do
        log =
          capture_log(fn ->
            assert {:ok, :checked} =
                     scoped(fixture.owner, fn repo ->
                       assert {:ok, cut} = snapshot(repo, fixture.owner.vault_id, 3)

                       assert {:ok, logical} =
                                records(repo, Map.put(cut, :manifest_id, Ecto.UUID.generate()), 3)

                       assert [%{type: 0x0001} | _] = Enum.to_list(logical.records)
                       assert {:ok, raw} = raw_inventory(repo, storage(fixture), cut)
                       for entry <- Enum.to_list(raw.records), do: Enum.to_list(entry.payload)
                       refute_receive {:raw_worker_query, _, _}
                       {:ok, :checked}
                     end)
          end)

        for canary <- ["Fixture Document", "# Merged fixture", "first\n", @originals.unicode],
            do: refute(log =~ canary)

        refute_receive {:raw_worker_query, _, _}
      after
        :telemetry.detach(handler)
      end
    end)
  end

  def capture_query(event, _measurements, metadata, observer),
    do: send(observer, {:raw_worker_query, event, metadata})

  defp snapshot(repo, owner, version), do: apply(Exporter, :snapshot_cut, [repo, owner, version])
  defp records(repo, cut, version), do: apply(Exporter, :records, [repo, cut, version])

  defp raw_inventory(repo, storage, cut),
    do: apply(Exporter, :stream_inventory, [repo, storage, cut])

  defp with_fixture(fun, originals \\ @originals) do
    KnowledgeBackupFixtures.with_destination(:current, fn destination ->
      # The established environment started WorkerRepo against this new database.
      # Own a single connection so same-backend/new-xid assertions are deterministic.
      Supervisor.stop(Process.whereis(WorkerRepo))
      {:ok, worker} = WorkerRepo.start_link(pool_size: 1)
      Process.unlink(worker)

      try do
        fixture =
          KnowledgeBackupFixtures.seed!(
            Map.merge(destination, %{ids: @ids, originals: originals})
          )

        owner(fn ->
          grant_backup!(fixture.owner)

          owner_query!("UPDATE core.vaults SET locked=false WHERE id=$1", [
            dump(fixture.owner.vault_id)
          ])
        end)

        fun.(fixture)
      after
        if Process.alive?(worker), do: Supervisor.stop(worker)
        refute Process.alive?(worker)
      end
    end)
  end

  defp scoped(context, fun),
    do: ScopedRepo.transact(WorkerRepo, context, [isolation: :repeatable_read], fun)

  defp owner(fun) do
    {:ok, result} =
      MigrationRepo.transaction(fn ->
        owner_query!("SET LOCAL ROLE singularity_table_owner")
        fun.()
      end)

    result
  end

  defp owner_query!(sql, params \\ []), do: SQL.query!(MigrationRepo, sql, params, log: false)
  defp dump(id), do: Ecto.UUID.dump!(id)
  defp normalize_sql(sql), do: sql |> String.replace(~r/\s+/, " ") |> String.trim()

  defp grant_backup!(owner) do
    owner_query!(
      "INSERT INTO core.capabilities(id,name) VALUES($1,'backup.create') ON CONFLICT(name) DO NOTHING",
      [dump(Ecto.UUID.generate())]
    )

    owner_query!(
      "INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name='backup.create' ON CONFLICT DO NOTHING",
      [dump(owner.principal_id), dump(owner.vault_id)]
    )
  end

  defp decode(records) do
    Enum.map(records, fn record ->
      assert {:ok, decoded} = LogicalRecordCodec.decode(record.type, record.payload)
      decoded
    end)
  end

  defp source_oracle(scope) do
    owner(fn ->
      Map.new(@projection, fn {table, columns, pk} ->
        %{rows: actual_pk} =
          owner_query!(
            """
            SELECT a.attname FROM pg_constraint c
            CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY k(attnum,position)
            JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=k.attnum
            WHERE c.conrelid=$1::text::regclass AND c.contype='p' ORDER BY k.position
            """,
            [table]
          )

        assert actual_pk == Enum.map(pk, &[&1])

        types =
          Map.new(
            owner_query!(
              "SELECT attname,typname FROM pg_attribute JOIN pg_type ON pg_type.oid=atttypid WHERE attrelid=$1::text::regclass AND attnum>0 AND NOT attisdropped",
              [table]
            ).rows,
            fn [name, type] -> {name, type} end
          )

        sql_columns =
          Enum.map_join(columns, ",", fn name ->
            if types[name] in ["uuid", "jsonb", "json"],
              do: "#{name}::text AS #{name}",
              else: name
          end)

        {predicate, value} = owner_filter(table, scope)
        order = if table == "core.outbox_events", do: ~w(sequence id), else: pk

        result =
          owner_query!(
            "SELECT #{sql_columns} FROM #{table} WHERE #{predicate} ORDER BY #{Enum.join(order, ",")}",
            [dump(value)]
          )

        assert result.columns == columns

        values =
          Enum.map(result.rows, fn row ->
            Enum.zip(columns, row)
            |> Enum.map(fn {name, value} -> oracle_tag(types[name], value) end)
          end)

        {table, values}
      end)
    end)
  end

  defp owner_filter("identity.people", owner),
    do: {"id IN(SELECT person_id FROM identity.accounts WHERE id=$1)", owner.account_id}

  defp owner_filter("identity.accounts", owner), do: {"id=$1", owner.account_id}

  defp owner_filter(table, owner) when table in ["identity.credentials", "identity.principals"],
    do: {"account_id=$1", owner.account_id}

  defp owner_filter("core.capabilities", owner),
    do:
      {"id IN(SELECT capability_id FROM core.principal_capabilities WHERE vault_id=$1)",
       owner.vault_id}

  defp owner_filter("core.vaults", owner), do: {"id=$1", owner.vault_id}
  defp owner_filter(_table, owner), do: {"vault_id=$1", owner.vault_id}

  defp oracle_tag(_type, nil), do: {"null"}
  defp oracle_tag(type, text) when type in ["json", "jsonb"], do: {"json", Jason.decode!(text)}
  defp oracle_tag("uuid", value), do: {"uuid", value}
  defp oracle_tag("bool", value), do: {"boolean", value}
  defp oracle_tag("bytea", value), do: {"bytes", value}
  defp oracle_tag(type, value) when type in ["int2", "int4", "int8"], do: {"integer", value}

  defp oracle_tag("timestamptz", value) do
    {microseconds, _precision} = value.microsecond
    {"timestamp", DateTime.to_iso8601(%{value | microsecond: {microseconds, 6}})}
  end

  defp oracle_tag("text", value), do: {"text", value}

  defp assert_source_rows(rows, oracle) do
    assert Enum.map(rows, & &1.table_ordinal) == Enum.sort(Enum.map(rows, & &1.table_ordinal))

    for {{table, columns, pk}, ordinal} <- Enum.with_index(@projection) do
      actual = rows_for(rows, table)
      assert Enum.map(actual, & &1.ordered_column_values) == oracle[table], table
      assert Enum.all?(actual, &(&1.table_ordinal == ordinal))

      for row <- actual do
        expected_pk =
          Enum.map(pk, fn name ->
            Enum.at(row.ordered_column_values, Enum.find_index(columns, &(&1 == name)))
          end)

        assert row.primary_key_values == expected_pk
        assert length(row.ordered_column_values) == length(columns)
      end
    end

    refute Enum.any?(rows, &(&1.table in @excluded))
  end

  defp rows_for(rows, table), do: Enum.filter(rows, &(&1.table == table))

  defp inventory_oracle(scope) do
    owner(fn ->
      result =
        owner_query!(
          """
          WITH required AS (
            SELECT o.id FROM content.asset_objects o
            WHERE o.vault_id=$1 AND o.lifecycle='available'
              AND EXISTS(SELECT 1 FROM content.assets a WHERE a.asset_object_id=o.id
                AND a.vault_id=o.vault_id AND a.state NOT IN('pending_delete','deleted'))
            UNION SELECT source_object_id FROM content.document_versions WHERE vault_id=$1
          )
          SELECT o.id::text,o.vault_id::text,o.key_domain_id::text,o.classification,
            o.lookup_digest,o.storage_ref,o.ciphertext_byte_size,o.ciphertext_hash
          FROM required r LEFT JOIN content.asset_objects o ON o.id=r.id ORDER BY r.id
          """,
          [dump(scope.vault_id)]
        )

      Enum.with_index(result.rows, fn [
                                        id,
                                        vault,
                                        domain,
                                        classification,
                                        lookup,
                                        path,
                                        size,
                                        hash
                                      ],
                                      position ->
        assert vault == scope.vault_id

        %{
          asset_object_id: id,
          vault_id: vault,
          key_domain_id: domain,
          classification: String.to_existing_atom(classification),
          lookup_digest: lookup,
          storage_ref: path,
          ciphertext_byte_size: size,
          ciphertext_hash: hash,
          inventory_position: position
        }
      end)
    end)
  end

  defp assert_uuid_reference_export(fixture, object_id) do
    oracle = source_oracle(fixture.owner)
    expected_inventory = inventory_oracle(fixture.owner)
    [uuid_entry] = Enum.filter(expected_inventory, &(&1.asset_object_id == object_id))
    assert uuid_entry.storage_ref == object_id
    assert Enum.any?(expected_inventory, &String.starts_with?(&1.storage_ref, "objects/"))

    assert {:ok, :checked} =
             scoped(fixture.owner, fn repo ->
               assert %{rows: [[false]]} = guard_query(repo, fixture.owner.vault_id, 3)
               assert {:ok, cut} = snapshot(repo, fixture.owner.vault_id, 3)
               assert Enum.sort(Map.keys(cut)) == Enum.sort(@capture_keys)
               assert cut.object_inventory == expected_inventory
               logical = Map.put(cut, :manifest_id, Ecto.UUID.generate())
               assert Enum.sort(Map.keys(logical)) == @logical_keys
               assert {:ok, export} = records(repo, logical, 3)
               encoded = Enum.to_list(export.records)
               assert Enum.map(encoded, &LogicalRecordCodec.descriptor/1) == export.inventory
               [header | body] = decode(encoded)
               assert header.logical_version == 3
               assert header.table_count_vector == Enum.map(@tables, &length(oracle[&1]))
               assert header.object_count == length(expected_inventory)
               assert header.database_snapshot == cut.database_snapshot
               assert header.outbox_high_water_mark == cut.outbox_high_water_mark
               assert header.manifest_id == logical.manifest_id
               assert Enum.all?(body, &(&1.logical_version == 3))
               rows = Enum.filter(body, &(&1.kind == :row))
               assert_source_rows(rows, oracle)
               assert_retained_history(rows)
               evidence = Enum.filter(body, &(&1.kind == :object))
               assert length(evidence) == length(expected_inventory)

               for {object, entry} <- Enum.zip(evidence, expected_inventory) do
                 assert Map.drop(object, [:kind, :logical_version, :object_index]) ==
                          entry
                          |> Map.delete(:inventory_position)
                          |> Map.update!(:classification, &Atom.to_string/1)

                 assert object.object_index == entry.inventory_position
               end

               [uuid_evidence] = Enum.filter(evidence, &(&1.asset_object_id == object_id))
               assert uuid_evidence.storage_ref == object_id

               assert {:error, %Error{code: :backup_unsupported}} =
                        snapshot(repo, fixture.owner.vault_id, 1)

               assert {:error, %Error{code: :backup_unsupported}} = records(repo, logical, 1)
               {:ok, :checked}
             end)

    assert_legacy_denied(fixture)
  end

  defp assert_retained_history(rows) do
    docs = rows_for(rows, "content.document_versions")

    assert Enum.map(docs, &Enum.at(&1.ordered_column_values, 13)) |> Enum.uniq() |> Enum.sort() ==
             Enum.sort(Enum.map(~w(ready pending extracting failed unsupported), &{"text", &1}))

    assert Enum.any?(docs, &(&1.primary_key_values == [{"uuid", @ids.ready_old_version_id}]))

    assert Enum.any?(
             docs,
             &(&1.primary_key_values == [{"uuid", @ids.deleted_document_version_id}])
           )

    assert Enum.any?(
             rows_for(rows, "content.resources"),
             &(Enum.at(&1.ordered_column_values, 4) != {"null"})
           )

    assert Enum.any?(
             rows_for(rows, "content.assets"),
             &(Enum.at(&1.ordered_column_values, 3) == {"null"} and
                 Enum.at(&1.ordered_column_values, 5) == {"text", "deleted"})
           )

    assert Enum.any?(
             rows_for(rows, "content.resource_assets"),
             &(Enum.at(&1.ordered_column_values, 4) != {"null"})
           )

    assert Enum.any?(
             rows_for(rows, "content.note_versions"),
             &(Enum.at(&1.ordered_column_values, 8) != {"null"})
           )

    assert Enum.map(
             rows_for(rows, "content.note_conflicts"),
             &Enum.at(&1.ordered_column_values, 7)
           )
           |> Enum.sort() == [{"text", "open"}, {"text", "resolved"}]
  end

  defp storage(fixture), do: {LocalFilesystemAdapter, %{root: fixture.destination.object_root}}

  defp counting_storage(fixture),
    do: {CountingStorage, %{root: fixture.destination.object_root, observer: self()}}

  defp asset_only_original!(fixture, state, reference \\ :canonical_path) do
    object_id = Ecto.UUID.generate()
    bytes = "Asset-only #{state} original\n" <> <<0, 255>>

    [domain, version] =
      owner(fn ->
        [[domain, version]] =
          owner_query!(
            "SELECT d.id::text,k.id::text FROM core.key_domains d JOIN core.domain_key_versions k ON k.key_domain_id=d.id WHERE d.vault_id=$1",
            [dump(fixture.owner.vault_id)]
          ).rows

        [domain, version]
      end)

    {:ok, lookup} =
      ObjectIdentity.lookup_digest(fixture.keys.domain_dedup_key, :crypto.hash(:sha256, bytes))

    {:ok, path} =
      PathGuard.object_path(
        fixture.destination.object_root,
        fixture.owner.vault_id,
        domain,
        Base.encode16(lookup, case: :lower)
      )

    {:ok, ciphertext} =
      ChunkedAEAD.encode(%{
        key: fixture.keys.object_dek,
        vault_id: fixture.owner.vault_id,
        encryption_domain_id: domain,
        object_id: object_id,
        chunk_index: 0,
        algorithm: Format.algorithm(),
        format_version: Format.format_version(),
        chunk_size: Format.chunk_size(),
        plaintext: bytes
      })

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, ciphertext, [:binary, :exclusive])
    File.chmod!(path, 0o600)

    {:ok, wrapped} =
      KeyWrapper.wrap(fixture.keys.domain_key, fixture.keys.object_dek, %{
        purpose: :object_dek,
        generation: 1,
        aad: "object:" <> object_id
      })

    owner(fn ->
      owner_query!(
        """
        INSERT INTO content.asset_objects(id,vault_id,key_domain_id,classification,lookup_digest,
          ciphertext_hash,plaintext_byte_size,ciphertext_byte_size,storage_ref,format_version,lifecycle,
          deleted_at,deletion_evidence)
        VALUES($1,$2,$3,'private',$4,$5,$6,$7,$8,1,$9,$10,$11::text::jsonb)
        """,
        [
          dump(object_id),
          dump(fixture.owner.vault_id),
          dump(domain),
          lookup,
          :crypto.hash(:sha256, ciphertext),
          byte_size(bytes),
          byte_size(ciphertext),
          if(reference == :object_uuid,
            do: object_id,
            else: Path.relative_to(path, fixture.destination.object_root)
          ),
          if(state == :retired, do: "deleted", else: "available"),
          if(state == :retired, do: ~U[2026-10-11 00:00:00Z], else: nil),
          if(state == :retired, do: "{\"reason\":\"fixture_cleanup\"}", else: nil)
        ]
      )

      owner_query!(
        "INSERT INTO content.asset_key_envelopes(id,vault_id,asset_object_id,domain_key_version_id,key_domain_id,classification,algorithm,key_generation,wrapped_dek) VALUES($1,$2,$3,$4,$5,'private','aes_256_gcm',1,$6)",
        [
          dump(Ecto.UUID.generate()),
          dump(fixture.owner.vault_id),
          dump(object_id),
          dump(version),
          dump(domain),
          wrapped.encoded
        ]
      )

      if state != :orphan do
        resource = Ecto.UUID.generate()
        resource_version = Ecto.UUID.generate()
        asset = Ecto.UUID.generate()

        owner_query!(
          "INSERT INTO content.resources(id,vault_id,classification,title,kind) VALUES($1,$2,'private','Asset-only fixture','asset')",
          [dump(resource), dump(fixture.owner.vault_id)]
        )

        owner_query!(
          "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',0)",
          [dump(resource_version), dump(resource), dump(fixture.owner.vault_id)]
        )

        owner_query!(
          "INSERT INTO content.assets(id,vault_id,resource_version_id,asset_object_id,classification,state) VALUES($1,$2,$3,$4,'private',$5)",
          [
            dump(asset),
            dump(fixture.owner.vault_id),
            dump(resource_version),
            if(state == :retired, do: nil, else: dump(object_id)),
            if(state == :retired, do: "deleted", else: "available")
          ]
        )

        owner_query!(
          "INSERT INTO content.resource_assets(resource_version_id,asset_id,vault_id,classification,released_at) VALUES($1,$2,$3,'private',$4)",
          [
            dump(resource_version),
            dump(asset),
            dump(fixture.owner.vault_id),
            if(state == :retired, do: ~U[2026-10-11 00:00:00Z], else: nil)
          ]
        )
      end
    end)

    if state == :retired, do: File.rm!(path)
    %{object_id: object_id, path: path}
  end

  defp assert_raw_ciphertext(export, fixture, inventory) do
    entries = Enum.to_list(export.records)
    assert Enum.map(entries, & &1.asset_object_id) == Enum.map(inventory, & &1.asset_object_id)

    for {entry, evidence} <- Enum.zip(entries, inventory) do
      assert entry.type == 0x8000
      assert entry.payload_length == evidence.ciphertext_byte_size
      actual = entry.payload |> Enum.to_list() |> IO.iodata_to_binary()
      expected = File.read!(Path.join(fixture.destination.object_root, evidence.storage_ref))
      assert actual == expected
      assert :crypto.hash(:sha256, actual) == evidence.ciphertext_hash
    end
  end

  defp assert_legacy_denied(fixture) do
    assert {:ok, :checked} =
             scoped(fixture.owner, fn repo ->
               assert {:ok, capture} = snapshot(repo, fixture.owner.vault_id, 3)
               logical = Map.put(capture, :manifest_id, Ecto.UUID.generate())

               assert {:error, %Error{code: :backup_unsupported}} =
                        Exporter.snapshot_cut(repo, fixture.owner.vault_id)

               assert {:error, %Error{code: :backup_unsupported}} =
                        Exporter.records(repo, logical)

               assert {:error, %Error{code: :backup_unsupported}} =
                        snapshot(repo, fixture.owner.vault_id, 2)

               assert {:error, %Error{code: :backup_unsupported}} = records(repo, logical, 2)
               {:ok, :checked}
             end)
  end

  defp export_rows(fixture, version) do
    scoped(fixture.owner, fn repo ->
      assert {:ok, capture} = snapshot(repo, fixture.owner.vault_id, version)

      assert {:ok, export} =
               records(repo, Map.put(capture, :manifest_id, Ecto.UUID.generate()), version)

      {:ok, Enum.filter(decode(Enum.to_list(export.records)), &(&1.kind == :row))}
    end)
  end

  defp guard_query(repo, vault, version),
    do:
      SQL.query!(
        repo,
        "SELECT content.backup_has_unsupported_canonical_rows($1,$2)",
        [dump(vault), version],
        log: false
      )

  defp receipt_policy do
    owner(fn ->
      owner_query!(
        "SELECT polname,polcmd,polroles,pg_get_expr(polqual,polrelid),pg_get_expr(polwithcheck,polrelid) FROM pg_policy WHERE polrelid='content.document_import_receipts'::regclass ORDER BY polname"
      ).rows
    end)
  end

  defp foreign_owner! do
    person = Ecto.UUID.generate()
    account = Ecto.UUID.generate()
    principal = Ecto.UUID.generate()
    vault = Ecto.UUID.generate()

    owner_query!(
      "INSERT INTO identity.people(id,display_name) VALUES($1,'Foreign owner canary')",
      [dump(person)]
    )

    owner_query!("INSERT INTO identity.accounts(id,person_id) VALUES($1,$2)", [
      dump(account),
      dump(person)
    ])

    owner_query!("INSERT INTO identity.principals(id,account_id,kind) VALUES($1,$2,'owner')", [
      dump(principal),
      dump(account)
    ])

    owner_query!("INSERT INTO core.vaults(id) VALUES($1)", [dump(vault)])

    owner_query!(
      "INSERT INTO core.vault_members(principal_id,vault_id,clearance) VALUES($1,$2,'restricted')",
      [dump(principal), dump(vault)]
    )

    context = %{principal_id: principal, vault_id: vault}
    grant_backup!(context)
    context
  end

  defp denied_sql(repo, sql, params) do
    SQL.query!(repo, "SAVEPOINT denied_backup", [], log: false)

    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
             SQL.query(repo, sql, params, log: false)

    SQL.query!(repo, "ROLLBACK TO SAVEPOINT denied_backup", [], log: false)
  end

  # Deferred-invalid fixtures cannot commit through ordinary constraints. These calls
  # exercise real SECURITY DEFINER validation before commit as the fixture table owner,
  # not worker ACLs. Committed WorkerRepo cases separately prove ACL/RLS/authorization.
  defp use_precommit_owner_context!(scope) do
    assert %{rows: [["singularity_table_owner"]]} = owner_query!("SELECT current_user")

    owner_query!(
      "SELECT set_config('singularity.principal_id',$1,true),set_config('singularity.vault_id',$2,true)",
      [scope.principal_id, scope.vault_id]
    )
  end

  # Establish only the frozen wrapper prerequisite, without adding knowledge rows.
  defp initialize_note_backup_wrapper!(note) do
    version = Ecto.UUID.generate()

    {:ok, wrapped} =
      KeyWrapper.wrap(<<11::256>>, <<12::256>>, %{
        purpose: :vault_key,
        generation: 1,
        aad: note.vault_id
      })

    owner_query!(
      "INSERT INTO core.vault_key_versions(id,vault_id,generation,state,algorithm,activated_at) VALUES($1,$2,1,'active','aes_256_gcm',CURRENT_TIMESTAMP)",
      [dump(version), dump(note.vault_id)]
    )

    owner_query!(
      "INSERT INTO core.vault_key_wrappers(id,vault_id,vault_key_version_id,account_id,generation,kdf_version,kdf_salt,kdf_parameters,wrapper_algorithm,wrapped_key) VALUES($1,$2,$3,$4,1,1,$5,$6::text::jsonb,'aes_256_gcm',$7)",
      [
        dump(Ecto.UUID.generate()),
        dump(note.vault_id),
        dump(version),
        dump(note.account_id),
        <<1::128>>,
        "{\"t_cost\":1,\"m_cost\":8192,\"parallelism\":1}",
        wrapped.encoded
      ]
    )
  end

  defp transaction_identity(repo) do
    %{rows: [[backend, xid]]} =
      SafeSQL.query!(repo, "SELECT pg_backend_pid(),pg_current_xact_id()::text", [])

    %{backend: backend, xid: xid}
  end

  defp assert_stream_denied(fun) do
    assert {Exporter, :object_stream_error,
            %Error{code: :storage_unavailable, message: nil, details: %{}}} = catch_throw(fun.())
  end

  defp corrupt!(:storage_format, _fixture),
    do:
      owner_query!("UPDATE content.asset_objects SET format_version=99 WHERE id=$1", [
        dump(@ids.pdf_object_id)
      ])

  defp corrupt!(:missing_envelope, _fixture),
    do:
      owner_query!("DELETE FROM content.asset_key_envelopes WHERE asset_object_id=$1", [
        dump(@ids.pdf_object_id)
      ])

  defp corrupt!(:unavailable_retained, _fixture),
    do:
      owner_query!("UPDATE content.asset_objects SET lifecycle='staged' WHERE id=$1", [
        dump(@ids.pdf_object_id)
      ])

  defp corrupt!(:source_size, _fixture),
    do:
      owner_query!(
        "UPDATE content.asset_objects SET plaintext_byte_size=plaintext_byte_size+1 WHERE id=$1",
        [dump(@ids.pdf_object_id)]
      )

  defp corrupt!(:source_classification, _fixture),
    do:
      owner_query!("UPDATE content.asset_objects SET classification='sensitive' WHERE id=$1", [
        dump(@ids.pdf_object_id)
      ])

  defp corrupt!(:missing_typed_history, fixture),
    do:
      owner_query!(
        "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',99)",
        [dump(Ecto.UUID.generate()), dump(@ids.ready_document_id), dump(fixture.owner.vault_id)]
      )

  defp corrupt!(defect, _fixture) when defect in [:extractor_format, :extractor_adapter] do
    owner_query!(
      "UPDATE content.document_versions SET state='extracting',attempt_generation=1,attempt_job_id=$2,attempt_started_at=$3::timestamptz,attempt_deadline_at=$3::timestamptz+interval '180 seconds',extraction_adapter=$4,extraction_format=$5 WHERE resource_version_id=$1",
      [
        dump(@ids.pending_version_id),
        dump(Ecto.UUID.generate()),
        ~U[2026-10-11 00:00:00Z],
        if(defect == :extractor_adapter, do: "future_canary_adapter", else: "plain_text"),
        if(defect == :extractor_format, do: 99, else: 1)
      ]
    )
  end
end
