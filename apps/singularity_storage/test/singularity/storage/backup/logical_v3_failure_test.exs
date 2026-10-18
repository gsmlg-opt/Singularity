defmodule Singularity.Storage.Backup.LogicalV3FailureTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Singularity.Storage.Backup.KnowledgeBackupFixtures

  @source_names [:pdf, :pdf_duplicate, :empty, :plain, :unicode, :markdown]
  @source_fields [:resource_id, :resource_version_id, :asset_id, :object_id, :digest, :byte_size]

  alias Singularity.Core.Error
  alias Singularity.Storage.{LocalFilesystemAdapter, MigrationRepo}

  alias Singularity.Storage.Backup.{
    BundleReader,
    KnowledgePreflight,
    LocalDestination,
    LogicalBundleVerifier,
    LogicalRecordCodec,
    LogicalSchemaV3,
    Restorer
  }

  alias Singularity.Storage.Backup.KnowledgeBackupFixtures.FixtureCrypto
  alias Singularity.Storage.Crypto.Format
  alias __MODULE__.ObservedStorage

  # TASK10 ALIASES BEGIN
  alias Singularity.Storage.Backup.KnowledgeCanonicalOracle
  alias __MODULE__.{Task10CommitUncertaintyRepo, Task10FaultStorage, Task10ReadOnlyStorage}
  # TASK10 ALIASES END

  # These are independent source-construction literals, not validator output.
  @tables ~w(identity.people identity.accounts identity.credentials identity.principals
    core.capabilities core.vaults core.vault_members core.principal_capabilities
    identity.devices core.key_domains core.vault_key_versions core.vault_key_wrappers
    core.domain_key_versions core.domain_dedup_key_wrappers content.resources
    content.resource_versions content.asset_objects content.assets content.asset_key_envelopes
    content.asset_metadata content.resource_assets content.source_references content.tombstones
    audit.events core.outbox_events jobs.job_submissions jobs.job_progress jobs.effect_receipts
    content.note_versions content.note_conflicts content.document_versions
    content.document_fragments content.document_import_receipts content.note_attachments
    content.note_citations content.tags content.resource_tags content.relationships)
  @appended ~w(content.document_versions content.document_fragments content.document_import_receipts
    content.note_attachments content.note_citations content.tags content.resource_tags content.relationships)
  # Import receipts encode owner/principal identity but have no classification
  # column. Enumerate the actual seven classified appended tables explicitly.
  @classified ~w(content.document_versions content.document_fragments content.note_attachments
    content.note_citations content.tags content.resource_tags content.relationships)
  @excluded ~w(identity.sessions identity.auth_attempts content.asset_stages content.upload_grants
    content.asset_search_documents content.note_search_documents content.search_entries
    content.note_mutation_receipts audit.backup_manifests audit.backup_manifest_objects
    jobs.oban_jobs jobs.oban_peers content.note_source_set_seals
    audit.knowledge_restore_admissions audit.restore_import_sagas)
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
         {name, "50000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")}
       end)
  @unknown "60000000-0000-4000-8000-000000999999"
  @originals %{
    pdf: "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n",
    pdf_duplicate: "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n",
    empty: "",
    plain: "plain original\r\nsecond line\n",
    unicode: "界🙂 café\n",
    markdown: "# Original Markdown\n\n[source](https://example.test/)\n"
  }
  @events {__MODULE__, :events}

  # Each non-PK-implied canonical unique index needs a distinct-PK witness.
  # Catalog assertions below also prove the redundant-index implication using
  # actual indkey columns rather than assuming that every UNIQUE is a PK.
  @secondary [
    {"identity.credentials", "credentials_normalized_login_key", ~w(normalized_login)},
    {"core.capabilities", "capabilities_name_key", ~w(name)},
    {"core.vault_key_versions", "vault_key_versions_vault_id_generation_key",
     ~w(vault_id generation)},
    {"core.vault_key_versions", "vault_key_versions_one_active", ~w(vault_id)},
    {"core.domain_key_versions", "domain_key_versions_key_domain_id_generation_key",
     ~w(key_domain_id generation)},
    {"content.resource_versions", "resource_versions_resource_id_vault_id_revision_key",
     ~w(resource_id vault_id revision)},
    {"content.asset_objects", "asset_objects_live_lookup_key",
     ~w(vault_id key_domain_id lookup_digest)},
    {"content.asset_key_envelopes",
     "asset_key_envelopes_asset_object_id_domain_key_version_id_key",
     ~w(asset_object_id domain_key_version_id)},
    {"content.asset_metadata", "asset_metadata_asset_id_key", ~w(asset_id)},
    {"core.outbox_events", "outbox_events_sequence_key", ~w(sequence)},
    {"core.outbox_events", "outbox_events_vault_id_idempotency_key_key",
     ~w(vault_id idempotency_key)},
    {"jobs.job_submissions", "job_submissions_outbox_event_id_key", ~w(outbox_event_id)},
    {"jobs.job_submissions", "job_submissions_vault_id_idempotency_key_key",
     ~w(vault_id idempotency_key)},
    {"jobs.job_progress", "job_progress_submission_id_key", ~w(submission_id)},
    {"jobs.effect_receipts", "effect_receipts_vault_id_effect_key_key", ~w(vault_id effect_key)},
    {"content.document_fragments", "document_fragments_version_ordinal_key",
     ~w(resource_version_id ordinal)},
    {"content.note_attachments", "note_attachments_note_ordinal_key",
     ~w(note_resource_version_id ordinal)},
    {"content.note_attachments", "note_attachments_note_target_role_key",
     ~w(note_resource_version_id target_resource_version_id role)},
    {"content.note_citations", "note_citations_note_ordinal_key",
     ~w(note_resource_version_id ordinal)},
    {"content.tags", "tags_owner_normalized_key", ~w(vault_id normalized_key)},
    {"content.relationships", "relationships_owner_source_target_type_key",
     ~w(vault_id source_resource_id target_resource_id type)}
  ]
  @pk_implied [
    {"core.key_domains", "key_domains_id_vault_id_key", ~w(id vault_id)},
    {"core.vault_key_versions", "vault_key_versions_id_vault_id_key", ~w(id vault_id)},
    {"core.domain_key_versions", "domain_key_versions_id_vault_id_key", ~w(id vault_id)},
    {"core.domain_key_versions", "domain_key_versions_id_vault_id_key_domain_id_key",
     ~w(id vault_id key_domain_id)},
    {"content.resources", "resources_id_vault_id_key", ~w(id vault_id)},
    {"content.resources", "resources_id_vault_classification_key",
     ~w(id vault_id classification)},
    {"content.resources", "resources_head_vault_classification_key",
     ~w(id current_version_id vault_id classification)},
    {"content.resource_versions", "resource_versions_id_vault_id_key", ~w(id vault_id)},
    {"content.resource_versions", "resource_versions_identity_aggregate_key",
     ~w(id resource_id vault_id classification)},
    {"content.asset_objects", "asset_objects_id_vault_id_key", ~w(id vault_id)},
    {"content.asset_objects", "asset_objects_id_vault_id_key_domain_id_key",
     ~w(id vault_id key_domain_id)},
    {"content.assets", "assets_id_vault_id_key", ~w(id vault_id)},
    {"content.source_references", "source_references_id_vault_id_key", ~w(id vault_id)},
    {"core.outbox_events", "outbox_events_id_vault_id_key", ~w(id vault_id)},
    {"jobs.job_submissions", "job_submissions_id_vault_id_key", ~w(id vault_id)},
    {"jobs.job_progress", "job_progress_id_vault_id_key", ~w(id vault_id)},
    {"content.note_versions", "note_versions_identity_aggregate_key",
     ~w(resource_version_id resource_id vault_id classification)},
    {"content.note_versions", "note_versions_receipt_identity_key",
     ~w(resource_version_id resource_id vault_id)},
    {"content.note_conflicts", "note_conflicts_receipt_identity_key",
     ~w(id resource_id vault_id)},
    {"content.document_versions", "document_versions_identity_aggregate_key",
     ~w(resource_version_id resource_id vault_id classification)},
    {"content.document_versions", "document_versions_receipt_identity_key",
     ~w(resource_version_id resource_id vault_id)},
    {"content.document_fragments", "document_fragments_identity_aggregate_key",
     ~w(id resource_id resource_version_id vault_id classification)},
    {"content.tags", "tags_id_vault_key", ~w(id vault_id)}
  ]

  @required_semantic ~w(resource_kind head_absent head_wrong_resource head_wrong_type
    history_state parent_missing parent_foreign_resource parent_cycle merge_missing merge_same_parent
    conflict_missing_resolution conflict_wrong_resolution conflict_open_resolution conflict_missing_competing
    attachment_gap attachment_target_kind attachment_target_missing attachment_note_identity
    citation_gap citation_target_missing citation_note_identity citation_locator
    fragment_id fragment_text fragment_digest fragment_gap fragment_locator_page fragment_locator_shape
    fragment_locator_kind fragment_resource fragment_version fragment_history_aggregate
    tag_display tag_normalization assignment_missing_tag assignment_missing_resource
    relationship_missing_target relationship_foreign_source relationship_pinned_version relationship_kind
    relationship_unpinned_asset receipt_missing_result receipt_wrong_resource receipt_wrong_version
    receipt_short_fingerprint receipt_principal receipt_pending submission_type submission_outbox
    submission_idempotency progress_submission progress_revision effect_submission effect_revision
    event_principal event_payload event_type event_principal_epoch event_owner_epoch event_revision
    attempt_missing_job attempt_wrong_job attempt_generation attempt_deadline
    object_format object_path_owner object_path_domain object_path_digest object_path_traversal
    object_path_uppercase object_path_wrong_uuid object_foreign_domain object_ambiguous_association
    object_path_noncanonical_uuid object_foreign_owner
    object_metadata_hash object_metadata_size document_source_short_digest document_source_size
    document_source_shared_digest document_source_wrong_asset document_source_wrong_version)
  @required_wire ~w(missing_canonical extra_canonical wrong_table_count wrong_object_count
    missing_evidence extra_evidence duplicate_evidence evidence_index missing_raw extra_raw
    changed_raw truncated_raw evidence_hash evidence_size cut3_row2 cut3_object2 row3_cut2
    unknown_wire attachment_encoded_remove attachment_encoded_duplicate
    citation_encoded_remove citation_encoded_duplicate object_encoded_remove object_encoded_duplicate)

  @tag :tmp_dir
  @tag timeout: 300_000
  test "independent malformed protocol/import matrix preserves an empty destination", %{
    tmp_dir: portable
  } do
    # FixtureCrypto and the literal fixture-recovery-wrapper qualify protocol /
    # import contracts, NOT native wrapper/custody proof. Native material and
    # plaintext counterparts live in the separate Runtime owner.
    assert ObservedStorage == __MODULE__.ObservedStorage,
           "matrix adapter must resolve to its actual test-owned module"

    File.chmod!(portable, 0o700)
    sources = prepare_matrix(portable)
    assert_matrix_membership(sources)

    # A genuine positive import proves that the extra eligible metadata seed is
    # lawful with every ordinary destination guard still enabled.
    KnowledgeBackupFixtures.with_destination(:current, fn destination ->
      source = Enum.find(sources, &(&1.name == "positive"))

      with_authenticated(source, fn bundle ->
        context = %{object_storage: {LocalFilesystemAdapter, %{root: destination.object_root}}}

        imported? =
          match?({:ok, %Restorer.Imported{}}, Restorer.import(context, MigrationRepo, bundle))

        assert imported?, "lawful matrix source did not import"
      end)

      owner_value(fn ->
        assert [[1]] == query("SELECT count(*) FROM content.asset_metadata").rows
        assert [[6]] == query("SELECT count(*) FROM content.note_source_set_seals").rows
      end)
    end)

    KnowledgeBackupFixtures.with_destination(:current, fn destination ->
      storage = %{
        module: ObservedStorage,
        context: %{root: destination.object_root},
        observer: fn name, _numeric_metrics -> event(name) end
      }

      # Precreate the legitimate empty staging directory before the baseline;
      # never remove/normalize artifacts after a rejection to manufacture equality.
      File.mkdir_p!(Path.join(destination.object_root, "staging"))

      File.write!(
        Path.join(destination.object_root, "unrelated-owned-sentinel"),
        "preserve-this-file",
        [:exclusive]
      )

      File.chmod!(Path.join(destination.object_root, "unrelated-owned-sentinel"), 0o400)
      assert {:ok, []} = LocalFilesystemAdapter.list_staged(storage.context)
      before = snapshot(destination.object_root)
      assert_empty_rows(before)

      for source <- Enum.reject(sources, &(&1.name == "positive")) do
        Process.put(@events, [])
        result = authenticate(source)

        case source.earliest_stage do
          :authentication ->
            assert_exact_error(result, source)
            assert Process.get(@events) == [], source.name

          :preflight ->
            assert match?({:ok, %BundleReader.Verified{replay: %BundleReader.Replay{}}}, result),
                   source.name <> ": intended authenticated preflight was not reached"

            {:ok, verified} = result

            try do
              assert {:error, :qualified_rejection} =
                       owner(fn ->
                         event(:preflight_entered)

                         actual =
                           KnowledgePreflight.stage(
                             MigrationRepo,
                             verified,
                             verified.cut,
                             storage
                           )

                         assert_exact_error(actual, source)
                         event(:preflight_rejected)
                         assert [[1]] == query("SELECT 1").rows
                         assert_no_temporary_tables()
                         same? = snapshot_rows() == before.rows
                         assert same?, source.name <> ": canonical or derived rows changed"
                         MigrationRepo.rollback(:qualified_rejection)
                       end)
            after
              BundleReader.discard_verified(verified)
            end

            events = Enum.reverse(Process.get(@events))
            assert hd(events) == :preflight_entered, source.name
            assert List.last(events) == :preflight_rejected, source.name
            if source.semantics?, do: assert(Enum.count(events, &(&1 == :seal)) == 5, source.name)

            if String.starts_with?(source.name, "unique:") do
              # A secondary-key error must occur during row insertion, before
              # any raw object or late semantic validator can reject it.
              assert Enum.count(events, &(&1 == :seal)) == 0, source.name
              assert :batch in events, source.name
            end

            if source.exact_error == :integrity_failure do
              # This public helper intentionally masks the more specific
              # direct stage error. Reauthenticate a fresh one-shot replay.
              with_authenticated(source, fn bundle ->
                assert {:error, :masked_rejection} =
                         owner(fn ->
                           context = %{object_storage: {ObservedStorage, storage.context}}
                           actual = Restorer.preflight_knowledge(context, MigrationRepo, bundle)
                           assert_exact_error(actual, %{source | exact_error: :backup_invalid})
                           MigrationRepo.rollback(:masked_rejection)
                         end)
              end)
            end

          :structural_positive ->
            assert match?({:ok, %BundleReader.Verified{}}, result), source.name
            {:ok, verified} = result

            try do
              assert {:error, :structural_positive} =
                       owner(fn ->
                         assert {:ok, staged} =
                                  KnowledgePreflight.stage(
                                    MigrationRepo,
                                    verified,
                                    verified.cut,
                                    storage
                                  )

                         assert {:ok, _summary} =
                                  KnowledgePreflight.validate(MigrationRepo, staged, verified.cut)

                         assert {:ok, stages} =
                                  LocalFilesystemAdapter.list_staged(storage.context)

                         assert length(stages) == 5

                         for stage <- stages,
                             do:
                               assert(
                                 :ok == LocalFilesystemAdapter.abort_stage(storage.context, stage)
                               )

                         MigrationRepo.rollback(:structural_positive)
                       end)
            after
              BundleReader.discard_verified(verified)
            end
        end

        assert :finalize not in Process.get(@events), source.name
        # Direct preflight cannot invoke Runtime rebuild/completion. Actual
        # canonical/import absence is proved by the complete empty SQL snapshot,
        # not an invented uninstrumented downstream callback counter.
        assert {:ok, []} = LocalFilesystemAdapter.list_staged(storage.context)
        assert_no_temporary_tables()
        same? = snapshot(destination.object_root) == before
        assert same?, source.name <> ": exact destination snapshot changed"
      end
    end)
  end

  test "graph construction rejects every missing source before inspecting descriptors" do
    for missing <- @source_names do
      sources =
        @source_names
        |> List.delete(missing)
        |> Map.new(&{&1, :not_a_descriptor})

      assert_rejected_graph(sources)
    end
  end

  test "graph construction rejects additional and renamed sources before inspecting descriptors" do
    sources = Map.new(@source_names, &{&1, :not_a_descriptor})
    assert_rejected_graph(Map.put(sources, :extra, :not_a_descriptor))

    for name <- @source_names do
      renamed = sources |> Map.delete(name) |> Map.put(Atom.to_string(name), :not_a_descriptor)
      assert_rejected_graph(renamed)
    end
  end

  test "graph construction requires every identity and original evidence field on every source" do
    for name <- @source_names, field <- @source_fields do
      # Nil markers are malformed-input shape witnesses, never native source
      # descriptors. Every invocation is missing one required field and must
      # reject before owner lookup, a transaction, or any graph construction.
      sources =
        Map.new(@source_names, fn source_name ->
          fields =
            if source_name == name, do: List.delete(@source_fields, field), else: @source_fields

          {source_name, Map.new(fields, &{&1, nil})}
        end)

      assert_rejected_graph(sources)
    end
  end

  # TASK10 CONTRACTS BEGIN — additive; established Task9 contracts stay intact.
  for fault <- [:stage, :canonical, :empty_seal, :before_finalize, :post_stat, :marker] do
    expected_code = if fault == :stage, do: :backup_invalid, else: :storage_unavailable

    @tag :tmp_dir
    test "Task10 actual #{fault} failure rolls back its guarded stage and exact replay succeeds",
         %{tmp_dir: portable} do
      fault = unquote(fault)
      source = task10_source(portable)

      KnowledgeBackupFixtures.with_destination(:current, fn destination ->
        task10_with_fault(fault, source, destination, fn counter ->
          result = task10_import(source, destination, Task10FaultStorage, fault)
          # Preflight masks an adapter stage error as backup_invalid; later
          # canonical/SQL/publication errors preserve storage_unavailable.
          task10_error(result, unquote(expected_code), "guarded #{fault}")
          assert counter.() == 1, "fault must reach exactly its guarded boundary"
          task10_assert_fault_order(fault, source, destination)
          task10_pending_empty(destination)
        end)

        task10_success(task10_import(source, destination))
        task10_complete(source, destination)
        before = snapshot(destination.object_root)
        imported = task10_import(source, destination, Task10ReadOnlyStorage)
        task10_success(imported)
        task10_same_snapshot(before, destination, "read-only imported replay")
        task10_complete(source, destination)
      end)
    end
  end

  @tag :tmp_dir
  test "Task10 actual COMMIT followed by Repo uncertainty preserves graph and read-only replay",
       %{tmp_dir: portable} do
    source = task10_source(portable)

    KnowledgeBackupFixtures.with_destination(:current, fn destination ->
      options = MigrationRepo.config() |> Keyword.put(:name, Task10CommitUncertaintyRepo)
      {:ok, pid} = Task10CommitUncertaintyRepo.start_link(options)
      Process.unlink(pid)

      try do
        Process.put({Task10CommitUncertaintyRepo, :armed}, true)

        result =
          task10_import(
            source,
            destination,
            LocalFilesystemAdapter,
            nil,
            Task10CommitUncertaintyRepo
          )

        task10_error(result, :storage_unavailable, "actual committed Repo error")
        assert Process.get({Task10CommitUncertaintyRepo, :hits}, 0) == 1

        committed? =
          Process.get({Task10CommitUncertaintyRepo, :committed_result}) == {:ok, :imported}

        assert committed?, "injection must follow the actual imported COMMIT result"
        refute Task10CommitUncertaintyRepo.in_transaction?()
        task10_complete(source, destination)
        before = snapshot(destination.object_root)
        task10_success(task10_import(source, destination, Task10ReadOnlyStorage))
        task10_same_snapshot(before, destination, "committed imported replay")
      after
        Supervisor.stop(pid)

        for key <- [:armed, :hits, :committed_result],
            do: Process.delete({Task10CommitUncertaintyRepo, key})
      end
    end)
  end

  @tag :tmp_dir
  test "Task10 pending retained publication is identity-cleaned on exact same-target replay",
       %{tmp_dir: portable} do
    source = task10_source(portable)

    KnowledgeBackupFixtures.with_destination(:current, fn destination ->
      task10_retained_pending(source, destination)
      task10_success(task10_import(source, destination))
      task10_complete(source, destination)
      before = snapshot(destination.object_root)
      task10_success(task10_import(source, destination, Task10ReadOnlyStorage))
      task10_same_snapshot(before, destination, "recovered imported replay")
    end)
  end

  for state <- [:pending, :imported],
      field <-
        ~w(manifest_id vault_id manifest_hash manifest_tag inventory_hash destination_root_hash object_count) do
    @tag :tmp_dir
    test "Task10 #{state} replay rejects exact #{field} binding mismatch without effects",
         %{tmp_dir: portable} do
      state = unquote(state)
      field = unquote(field)
      source = task10_source(portable)

      KnowledgeBackupFixtures.with_destination(:current, fn destination ->
        task10_prepare_state(state, source, destination)
        task10_change_marker(field)
        before = snapshot(destination.object_root)

        task10_error(
          task10_import(source, destination, Task10ReadOnlyStorage, :binding),
          :conflict,
          "#{state} #{field} binding"
        )

        task10_same_snapshot(before, destination, "binding mismatch")
      end)
    end
  end

  for state <- [:pending, :imported] do
    @tag :tmp_dir
    test "Task10 #{state} replay rejects authenticated changed source and foreign root",
         %{tmp_dir: portable} do
      state = unquote(state)
      source = task10_source(portable)

      KnowledgeBackupFixtures.with_destination(:current, fn destination ->
        task10_prepare_state(state, source, destination)
        before = snapshot(destination.object_root)

        task10_error(
          task10_import(source.changed, destination, Task10ReadOnlyStorage, :binding),
          :conflict,
          "authenticated changed manifest"
        )

        task10_same_snapshot(before, destination, "changed authenticated source")

        foreign_root = Path.join(portable, "foreign-destination")
        File.mkdir!(foreign_root)
        File.chmod!(foreign_root, 0o700)
        foreign_before = filesystem_snapshot(foreign_root)

        task10_error(
          task10_import(
            source,
            %{destination | object_root: foreign_root},
            Task10ReadOnlyStorage,
            :binding
          ),
          :conflict,
          "foreign root"
        )

        foreign_same? = filesystem_snapshot(foreign_root) == foreign_before
        assert foreign_same?, "foreign destination was modified"
        task10_same_snapshot(before, destination, "foreign root binding")
      end)
    end
  end

  @tag :tmp_dir
  test "Task10 pending cleanup preserves foreign artifact and exact retry follows its owned removal",
       %{tmp_dir: portable} do
    source = task10_source(portable)

    KnowledgeBackupFixtures.with_destination(:current, fn destination ->
      task10_retained_pending(source, destination)
      rows_before = owner_value(&snapshot_rows/0)
      sentinel = Path.join(destination.object_root, "task10-foreign-sentinel")
      File.write!(sentinel, "foreign-test-owned-sentinel", [:exclusive])
      File.chmod!(sentinel, 0o400)
      sentinel_before = task10_file_evidence(sentinel)
      task10_error(task10_import(source, destination), :conflict, "foreign pending artifact")
      assert task10_file_evidence(sentinel) == sentinel_before
      rows_same? = owner_value(&snapshot_rows/0) == rows_before
      assert rows_same?, "foreign cleanup denial changed pending database"
      assert task10_regular_files(destination.object_root) == [sentinel]
      # Remove only the exact artifact this contract created, not failure leftovers.
      File.rm!(sentinel)
      task10_success(task10_import(source, destination))
      task10_complete(source, destination)
    end)
  end

  @tag :tmp_dir
  test "Task10 imported replay rejects changed graph and stale marker without rewriting either",
       %{tmp_dir: portable} do
    source = task10_source(portable)

    KnowledgeBackupFixtures.with_destination(:current, fn destination ->
      task10_success(task10_import(source, destination))

      owner_value(fn ->
        %{num_rows: 1} =
          query(
            "UPDATE content.note_versions SET markdown='task10 owned mutation' WHERE resource_version_id=$1",
            [Ecto.UUID.dump!(@ids.initial_note_version_id)]
          )
      end)

      before = snapshot(destination.object_root)

      task10_error(
        task10_import(source, destination, Task10ReadOnlyStorage),
        :conflict,
        "same-count changed imported graph"
      )

      task10_same_snapshot(before, destination, "mutated imported graph")
    end)

    KnowledgeBackupFixtures.with_destination(:current, fn destination ->
      task10_success(task10_import(source, destination))

      owner_value(fn ->
        %{num_rows: 1} =
          query(
            "UPDATE audit.restore_import_sagas SET state='pending',imported_at=NULL WHERE singleton"
          )
      end)

      before = snapshot(destination.object_root)

      task10_error(
        task10_import(source, destination, Task10ReadOnlyStorage),
        :conflict,
        "stale pending marker with committed graph"
      )

      task10_same_snapshot(before, destination, "stale marker")
    end)
  end

  @tag :tmp_dir
  test "Task10 ordinary singleton guards prevent ambiguous markers without disabling constraints",
       %{tmp_dir: portable} do
    source = task10_source(portable)

    KnowledgeBackupFixtures.with_destination(:current, fn destination ->
      task10_retained_pending(source, destination)
      before = snapshot(destination.object_root)

      for {singleton, expected} <- [{true, :unique_violation}, {false, :check_violation}] do
        {:error, code} =
          owner(fn ->
            result =
              Ecto.Adapters.SQL.query(
                MigrationRepo,
                "INSERT INTO audit.restore_import_sagas(singleton,manifest_id,vault_id,manifest_hash,manifest_tag,inventory_hash,destination_root_hash,object_count,state) SELECT $1,manifest_id,vault_id,manifest_hash,manifest_tag,inventory_hash,destination_root_hash,object_count,state FROM audit.restore_import_sagas WHERE singleton",
                [singleton],
                log: false
              )

            code =
              case result do
                {:error, %Postgrex.Error{postgres: %{code: code}}} -> code
                _ -> :unexpected_result_shape
              end

            MigrationRepo.rollback(code)
          end)

        assert code == expected, "ordinary marker ambiguity barrier changed"
        task10_same_snapshot(before, destination, "rejected ambiguous marker")
      end

      task10_success(task10_import(source, destination))
      task10_complete(source, destination)
    end)
  end

  @tag :tmp_dir
  test "Task10 imported replay preserves foreign files and rejects a genuine stale stage",
       %{tmp_dir: portable} do
    source = task10_source(portable)

    KnowledgeBackupFixtures.with_destination(:current, fn destination ->
      task10_success(task10_import(source, destination))
      sentinel = Path.join(destination.object_root, "task10-imported-foreign")
      File.write!(sentinel, "preserve-imported-foreign", [:exclusive])
      File.chmod!(sentinel, 0o400)
      before = snapshot(destination.object_root)

      task10_error(
        task10_import(source, destination, Task10ReadOnlyStorage),
        :conflict,
        "foreign imported file"
      )

      task10_same_snapshot(before, destination, "foreign imported file")
      File.rm!(sentinel)

      context = %{root: destination.object_root}
      {:ok, stale} = LocalFilesystemAdapter.stage(context, %{stage_id: id(1600)})

      try do
        before = snapshot(destination.object_root)

        task10_error(
          task10_import(source, destination, Task10ReadOnlyStorage),
          :backup_invalid,
          "genuine stale staged artifact"
        )

        task10_same_snapshot(before, destination, "stale staged artifact")
      after
        :ok = LocalFilesystemAdapter.abort_stage(context, stale)
      end

      task10_success(task10_import(source, destination, Task10ReadOnlyStorage))
      task10_complete(source, destination)
    end)
  end

  # TASK10 CONTRACTS END

  defp prepare_matrix(portable) do
    KnowledgeBackupFixtures.with_destination(:current, fn destination ->
      fixture =
        KnowledgeBackupFixtures.seed!(Map.merge(destination, %{ids: @ids, originals: @originals}))

      seed_eligible_metadata!()
      canonical = KnowledgeBackupFixtures.canonical_rows(fixture)
      assert_unique_catalog!()

      cases =
        [
          contract("positive", [], :preflight),
          contract(
            "structural_nonshared_plaintext_digest",
            [
              rows:
                &edit(
                  &1,
                  "content.document_versions",
                  %{"resource_version_id" => @ids.extracting_version_id},
                  fn row ->
                    Map.put(
                      row,
                      "source_digest",
                      :crypto.hash(:sha256, "different-length-correct-digest")
                    )
                  end
                )
            ],
            :structural_positive
          ),
          contract(
            "structural_fingerprint_and_epochs",
            [
              rows: fn rows ->
                rows
                |> edit(
                  "content.document_import_receipts",
                  %{"mutation_id" => @ids.ready_old_version_id},
                  &Map.put(
                    &1,
                    "request_fingerprint",
                    :crypto.hash(:sha256, "different-opaque-fingerprint")
                  )
                )
                |> edit(
                  "core.outbox_events",
                  %{},
                  &Map.merge(&1, %{
                    "principal_authorization_epoch" => 7,
                    "vault_authorization_epoch" => 9
                  })
                )
              end
            ],
            :structural_positive
          )
        ] ++ malformed_cases(canonical)

      Enum.map(cases, fn contract ->
        Process.delete({__MODULE__, :portable_source})
        Process.delete({__MODULE__, :mutation_signature})
        original_records = Keyword.get(contract.mutation, :records, &Function.identity/1)

        options =
          Keyword.merge(contract.mutation,
            records: fn records ->
              transformed = original_records.(records)

              Process.put(
                {__MODULE__, :mutation_signature},
                :crypto.hash(:sha256, :erlang.term_to_binary(transformed, [:deterministic]))
              )

              transformed
            end,
            source: fn source ->
              filename = Path.basename(source.path)
              File.cp!(source.path, Path.join(portable, filename))
              File.chmod!(Path.join(portable, filename), 0o600)
              Process.put({__MODULE__, :portable_source}, filename)
              source
            end
          )

        built = KnowledgeBackupFixtures.transformed_bundle(fixture, options)
        # Source construction can reject an intentionally malformed logical
        # stream, but the callback above has retained the authentic outer file.
        case built do
          {:ok, bundle} -> BundleReader.discard_verified(bundle.verified)
          {:error, %Error{}} -> :ok
        end

        filename = Process.get({__MODULE__, :portable_source})
        signature = Process.get({__MODULE__, :mutation_signature})
        assert is_binary(filename), "matrix input was not materialized"
        assert is_binary(signature), "matrix mutation was not observed"

        Map.merge(contract, %{
          portable: portable,
          filename: filename,
          signature: signature,
          binding: %{
            manifest_id: id(900),
            vault_id: @ids.vault_id,
            recovery: %{
              "binding" => %{"manifest_id" => id(900), "vault_id" => @ids.vault_id},
              "label" => "backup_recovery",
              "wrapper" => "fixture-recovery-wrapper"
            },
            destination_ref: filename
          }
        })
      end)
    end)
  end

  defp seed_eligible_metadata! do
    owner_value(fn ->
      assert %{num_rows: 1} =
               query(
                 """
                 INSERT INTO content.asset_metadata
                   (id,asset_id,resource_version_id,vault_id,classification,projection_version,
                    original_filename,declared_media_type,plaintext_byte_size,extraction_state)
                 SELECT $1,a.id,a.resource_version_id,a.vault_id,a.classification,1,
                   'matrix-original.txt','text/plain',o.plaintext_byte_size,'pending'
                 FROM content.assets a JOIN content.asset_objects o ON o.id=a.asset_object_id
                 WHERE a.id=$2
                 """,
                 [Ecto.UUID.dump!(id(1200)), Ecto.UUID.dump!(source_id(:plain, :asset_id))]
               )
    end)
  end

  defp malformed_cases(rows) do
    pk =
      Enum.map(@appended, fn table ->
        contract(
          "pk:" <> table,
          [
            rows: fn input ->
              put_rows(input, table, [hd(input[table]) | input[table]])
            end
          ],
          :authentication
        )
      end)

    scoped =
      Enum.map(@appended, fn table ->
        row_contract(
          "scope:" <> table <> ":vault_id",
          table,
          %{},
          "vault_id",
          @unknown,
          :authentication
        )
      end) ++
        Enum.map(@classified, fn table ->
          row_contract(
            "scope:" <> table <> ":classification",
            table,
            %{},
            "classification",
            "public",
            :preflight
          )
        end)

    unique =
      Enum.map(@secondary, fn {table, index, columns} ->
        # Sequence is also the authenticated outbox wire sort key. Its duplicate
        # is necessarily rejected before temporary SQL, even with distinct IDs.
        stage = if index == "outbox_events_sequence_key", do: :authentication, else: :preflight
        contract("unique:" <> index, [rows: &unique_collision(&1, table, index, columns)], stage)
      end)

    pk ++ scoped ++ unique ++ semantic_cases(rows) ++ wire_cases()
  end

  defp semantic_cases(rows) do
    fragment =
      Enum.find(
        rows["content.document_fragments"],
        &(&1["resource_version_id"] == @ids.ready_old_version_id and &1["ordinal"] == 0)
      )

    attachment = %{"note_resource_version_id" => @ids.merge_note_version_id}
    citation = %{"note_resource_version_id" => @ids.merge_note_version_id}
    document = %{"resource_version_id" => @ids.ready_old_version_id}
    extracting = %{"resource_version_id" => @ids.extracting_version_id}
    object = Enum.find(rows["content.asset_objects"], &(&1["id"] == @ids.plain_object_id))
    reference = canonical_reference(object)
    # Literal expected outcomes are traced to real stage/semantic branches.
    # They remain predictions until the exclusive native gate executes them.
    fields = [
      {"resource_kind", "content.resources", %{"id" => @ids.live_note_id}, "kind", "document"},
      {"head_absent", "content.resources", %{"id" => @ids.ready_document_id},
       "current_version_id", nil},
      {"head_wrong_resource", "content.resources", %{"id" => @ids.live_note_id},
       "current_version_id", @ids.deleted_note_version_id},
      {"head_wrong_type", "content.resources", %{"id" => @ids.live_note_id}, "current_version_id",
       @ids.ready_current_version_id},
      {"history_state", "content.document_versions", document, "state", "pending"},
      {"parent_missing", "content.note_versions",
       %{"resource_version_id" => @ids.canonical_note_version_id}, "parent_version_id", @unknown},
      {"parent_foreign_resource", "content.note_versions",
       %{"resource_version_id" => @ids.canonical_note_version_id}, "parent_version_id",
       @ids.deleted_note_version_id},
      {"parent_cycle", "content.note_versions",
       %{"resource_version_id" => @ids.canonical_note_version_id}, "parent_version_id",
       @ids.merge_note_version_id},
      {"merge_missing", "content.note_versions",
       %{"resource_version_id" => @ids.merge_note_version_id}, "merge_parent_version_id",
       @unknown},
      {"merge_same_parent", "content.note_versions",
       %{"resource_version_id" => @ids.merge_note_version_id}, "merge_parent_version_id",
       @ids.canonical_note_version_id},
      {"conflict_missing_resolution", "content.note_conflicts",
       %{"id" => @ids.resolved_conflict_id}, "resolution_version_id", nil},
      {"conflict_wrong_resolution", "content.note_conflicts",
       %{"id" => @ids.resolved_conflict_id}, "resolution_version_id",
       @ids.deleted_note_version_id},
      {"conflict_open_resolution", "content.note_conflicts", %{"id" => @ids.open_conflict_id},
       "resolution_version_id", @ids.merge_note_version_id},
      {"conflict_missing_competing", "content.note_conflicts",
       %{"id" => @ids.resolved_conflict_id}, "competing_version_id", @unknown},
      {"attachment_gap", "content.note_attachments", attachment, "ordinal", 2},
      {"attachment_target_kind", "content.note_attachments", attachment, "target_kind",
       "document"},
      {"attachment_target_missing", "content.note_attachments", attachment,
       "target_resource_version_id", @unknown},
      {"attachment_note_identity", "content.note_attachments", attachment, "note_resource_id",
       @ids.deleted_note_id},
      {"citation_gap", "content.note_citations", citation, "ordinal", 2},
      {"citation_target_missing", "content.note_citations", citation,
       "source_resource_version_id", @unknown},
      {"citation_note_identity", "content.note_citations", citation, "note_resource_id",
       @ids.deleted_note_id},
      {"citation_locator", "content.note_citations", citation, "locator",
       %{"version" => 1, "kind" => "pdf", "page" => 99}},
      {"fragment_id", "content.document_fragments", %{"id" => fragment["id"]}, "id",
       String.duplicate("f", 64)},
      {"fragment_text", "content.document_fragments", %{"id" => fragment["id"]}, "text",
       "changed-text"},
      {"fragment_digest", "content.document_fragments", %{"id" => fragment["id"]}, "digest",
       <<0::256>>},
      {"fragment_gap", "content.document_fragments", %{"id" => fragment["id"]}, "ordinal", 9},
      {"fragment_locator_page", "content.document_fragments", %{"id" => fragment["id"]},
       "locator", %{"version" => 1, "kind" => "pdf", "page" => 0}},
      {"fragment_locator_shape", "content.document_fragments", %{"id" => fragment["id"]},
       "locator", %{"version" => 1, "kind" => "pdf", "page" => 1, "extra" => true}},
      {"fragment_locator_kind", "content.document_fragments", %{"id" => fragment["id"]},
       "locator", %{"version" => 1, "kind" => "text", "start_line" => 1, "end_line" => 1}},
      {"fragment_resource", "content.document_fragments", %{"id" => fragment["id"]},
       "resource_id", @ids.live_note_id},
      {"fragment_version", "content.document_fragments", %{"id" => fragment["id"]},
       "resource_version_id", @ids.pending_version_id},
      {"fragment_history_aggregate", "content.document_versions", document,
       "extracted_text_digest", <<0::256>>},
      {"tag_display", "content.tags", %{}, "display_value", "\n"},
      {"tag_normalization", "content.tags", %{}, "normalized_key", "straße"},
      {"assignment_missing_tag", "content.resource_tags", %{}, "tag_id", @unknown},
      {"assignment_missing_resource", "content.resource_tags", %{}, "resource_id", @unknown},
      {"relationship_missing_target", "content.relationships", %{}, "target_resource_id",
       @unknown},
      {"relationship_foreign_source", "content.relationships", %{}, "source_resource_id",
       @unknown},
      {"relationship_pinned_version", "content.relationships", %{}, "target_resource_version_id",
       @ids.deleted_document_version_id},
      {"relationship_kind", "content.relationships", %{}, "type", "unknown"},
      {"receipt_missing_result", "content.document_import_receipts",
       %{"mutation_id" => @ids.ready_old_version_id}, "version_id", nil},
      {"receipt_wrong_resource", "content.document_import_receipts",
       %{"mutation_id" => @ids.ready_old_version_id}, "resource_id", @ids.live_note_id},
      {"receipt_wrong_version", "content.document_import_receipts",
       %{"mutation_id" => @ids.ready_old_version_id}, "version_id", @ids.pending_version_id},
      {"receipt_short_fingerprint", "content.document_import_receipts",
       %{"mutation_id" => @ids.ready_old_version_id}, "request_fingerprint", <<1>>},
      {"receipt_principal", "content.document_import_receipts",
       %{"mutation_id" => @ids.ready_old_version_id}, "principal_id", @unknown},
      {"receipt_pending", "content.document_import_receipts",
       %{"mutation_id" => @ids.ready_old_version_id}, "state", "pending"},
      {"submission_type", "jobs.job_submissions", %{}, "job_type", "document_projection"},
      {"submission_outbox", "jobs.job_submissions", %{}, "outbox_event_id", @unknown},
      {"submission_idempotency", "jobs.job_submissions", %{}, "idempotency_key",
       "different-submission"},
      {"progress_submission", "jobs.job_progress", %{}, "submission_id", @unknown},
      {"progress_revision", "jobs.job_progress", %{}, "processing_revision", -1},
      {"effect_submission", "jobs.effect_receipts", %{}, "submission_id", @unknown},
      {"effect_revision", "jobs.effect_receipts", %{}, "entity_revision", -1},
      {"event_principal", "core.outbox_events", %{}, "principal_id", @unknown},
      {"event_payload", "core.outbox_events", %{}, "payload",
       %{"resource_id" => @ids.live_note_id, "resource_version_id" => @ids.extracting_version_id}},
      {"event_type", "core.outbox_events", %{}, "event_type", "note.saved"},
      {"event_principal_epoch", "core.outbox_events", %{}, "principal_authorization_epoch", -1},
      {"event_owner_epoch", "core.outbox_events", %{}, "vault_authorization_epoch", -1},
      {"event_revision", "core.outbox_events", %{}, "expected_entity_revision", 2},
      {"attempt_missing_job", "content.document_versions", extracting, "attempt_job_id", nil},
      {"attempt_wrong_job", "content.document_versions", extracting, "attempt_job_id", @unknown},
      {"attempt_generation", "content.document_versions", extracting, "attempt_generation", 2},
      {"attempt_deadline", "content.document_versions", extracting, "attempt_deadline_at",
       "2026-10-11T00:00:01.000000Z"},
      {"object_format", "content.asset_objects", %{"id" => object["id"]}, "format_version", 2},
      {"object_path_owner", "content.asset_objects", %{"id" => object["id"]}, "storage_ref",
       canonical_reference(Map.put(object, "vault_id", @unknown))},
      {"object_path_domain", "content.asset_objects", %{"id" => object["id"]}, "storage_ref",
       canonical_reference(Map.put(object, "key_domain_id", @unknown))},
      {"object_path_digest", "content.asset_objects", %{"id" => object["id"]}, "storage_ref",
       canonical_reference(Map.put(object, "lookup_digest", <<0::256>>))},
      {"object_path_traversal", "content.asset_objects", %{"id" => object["id"]}, "storage_ref",
       "objects/../" <> reference},
      {"object_path_uppercase", "content.asset_objects", %{"id" => object["id"]}, "storage_ref",
       String.upcase(reference)},
      {"object_path_wrong_uuid", "content.asset_objects", %{"id" => object["id"]}, "storage_ref",
       @ids.pdf_object_id},
      {"object_path_noncanonical_uuid", "content.asset_objects", %{"id" => object["id"]},
       "storage_ref", "60000000-0000-4000-8000-000000ABCDEF"},
      {"object_foreign_owner", "content.asset_objects", %{"id" => object["id"]}, "vault_id",
       @unknown},
      {"object_foreign_domain", "content.asset_objects", %{"id" => object["id"]}, "key_domain_id",
       @unknown},
      {"object_metadata_hash", "content.asset_objects", %{"id" => object["id"]},
       "ciphertext_hash", <<0::256>>},
      {"object_metadata_size", "content.asset_objects", %{"id" => object["id"]},
       "ciphertext_byte_size", object["ciphertext_byte_size"] + 1},
      {"document_source_short_digest", "content.document_versions", document, "source_digest",
       <<1>>},
      {"document_source_size", "content.document_versions", document, "source_byte_size", 1},
      {"document_source_shared_digest", "content.document_versions", document, "source_digest",
       <<0::256>>},
      {"document_source_wrong_asset", "content.document_versions", document, "source_asset_id",
       @unknown},
      {"document_source_wrong_version", "content.document_versions", document,
       "source_resource_version_id", source_id(:plain, :resource_version_id)}
    ]

    field_cases =
      Enum.map(fields, fn {name, table, key, field, value} ->
        code =
          if name in ["submission_outbox", "attempt_wrong_job"],
            do: :integrity_failure,
            else: :backup_invalid

        # Metadata hash/length is also copied into the evidence by the builder;
        # the actual raw-frame digest/length check rejects it during authentication.
        stage =
          if name in ["object_metadata_hash", "object_metadata_size", "object_foreign_owner"],
            do: :authentication,
            else: :preflight

        contract = row_contract(name, table, key, field, value, stage, code)

        if name == "fragment_id" or String.starts_with?(name, "fragment_locator_") do
          original = Keyword.fetch!(contract.mutation, :rows)

          mutation = fn input ->
            changed = original.(input)

            replacement_id =
              if name == "fragment_locator_kind" do
                # A valid text locator with its correct canonical fragment ID is
                # still the wrong source-media locator for this historical PDF.
                Singularity.Core.DocumentFragment.id(
                  fragment["resource_version_id"],
                  value,
                  fragment["ordinal"],
                  fragment["digest"]
                )
              else
                if name == "fragment_id", do: value, else: fragment["id"]
              end

            changed =
              if name == "fragment_locator_kind",
                do: edit(changed, table, key, &Map.put(&1, "id", replacement_id)),
                else: changed

            # Keep every dependent citation's FK/locator coherent, so the changed
            # fragment reaches its own identity/locator contract rather than an
            # unrelated missing-reference or stale-citation comparison.
            citations =
              Enum.map(changed["content.note_citations"], fn citation ->
                if citation["fragment_id"] == fragment["id"],
                  do:
                    citation
                    |> Map.put("fragment_id", replacement_id)
                    |> Map.put(
                      "locator",
                      if(name == "fragment_id", do: citation["locator"], else: value)
                    ),
                  else: citation
              end)

            put_rows(changed, "content.note_citations", citations)
          end

          %{contract | mutation: [rows: mutation]}
        else
          contract
        end
      end)

    field_cases ++
      [
        contract(
          "relationship_unpinned_asset",
          [
            rows: fn input ->
              resource =
                input["content.resources"]
                |> hd()
                |> Map.merge(%{
                  "id" => id(1350),
                  "kind" => "asset",
                  "current_version_id" => nil,
                  "deleted_at" => nil
                })

              input
              |> put_rows("content.resources", input["content.resources"] ++ [resource])
              |> edit(
                "content.relationships",
                %{},
                &Map.merge(&1, %{
                  "target_resource_id" => id(1350),
                  "target_resource_version_id" => nil
                })
              )
            end
          ],
          :preflight,
          :backup_invalid,
          true
        ),
        contract(
          "object_ambiguous_association",
          [
            rows: fn input ->
              [first | _] =
                Enum.filter(
                  input["content.assets"],
                  &(&1["resource_version_id"] == source_id(:plain, :resource_version_id))
                )

              duplicate = Map.put(first, "id", id(1300))

              association =
                Enum.find(input["content.resource_assets"], &(&1["asset_id"] == first["id"]))

              input
              |> put_rows("content.assets", input["content.assets"] ++ [duplicate])
              |> put_rows(
                "content.resource_assets",
                input["content.resource_assets"] ++ [Map.put(association, "asset_id", id(1300))]
              )
            end
          ],
          :preflight,
          :backup_invalid,
          true
        )
      ]
  end

  defp wire_cases do
    specifications = [
      {"missing_canonical", [records: fn [cut, _row | rest] -> [cut | rest] end]},
      {"extra_canonical", [records: fn [cut, row | rest] -> [cut, row, row | rest] end]},
      {"wrong_table_count",
       [
         cut: fn cut ->
           Map.update!(cut, :table_count_vector, fn [n | rest] -> [n + 1 | rest] end)
         end
       ]},
      {"wrong_object_count", [cut: &Map.update!(&1, :object_count, fn n -> n + 1 end)]},
      {"missing_evidence", [evidence: &tl/1]},
      {"extra_evidence", [evidence: fn evidence -> evidence ++ [hd(evidence)] end]},
      {"duplicate_evidence", [evidence: fn [first, _second | rest] -> [first, first | rest] end]},
      {"evidence_index",
       [evidence: fn [first | rest] -> [%{first | object_index: 1} | rest] end]},
      {"missing_raw", [raw: &tl/1]},
      {"extra_raw", [raw: fn raw -> raw ++ [hd(raw)] end]},
      {"changed_raw",
       [
         raw: fn [<<byte, tail::binary>> | rest] ->
           [<<Bitwise.bxor(byte, 1), tail::binary>> | rest]
         end
       ]},
      {"truncated_raw",
       [raw: fn [first | rest] -> [binary_part(first, 0, byte_size(first) - 1) | rest] end]},
      {"evidence_hash",
       [evidence: fn [first | rest] -> [%{first | ciphertext_hash: <<0::256>>} | rest] end]},
      {"evidence_size",
       [
         evidence: fn [first | rest] ->
           [%{first | ciphertext_byte_size: first.ciphertext_byte_size + 1} | rest]
         end
       ]},
      {"cut3_row2", [records: &change_record_version(&1, 2, 2)]},
      {"cut3_object2", [records: &change_record_version(&1, 3, 2)]},
      {"row3_cut2", [records: &change_record_version(&1, 1, 2)]},
      {"unknown_wire", [records: &change_record_version(&1, 1, 99)]},
      {"attachment_encoded_remove",
       [records: &encoded_member(&1, "content.note_attachments", :remove)]},
      {"attachment_encoded_duplicate",
       [records: &encoded_member(&1, "content.note_attachments", :duplicate)]},
      {"citation_encoded_remove",
       [records: &encoded_member(&1, "content.note_citations", :remove)]},
      {"citation_encoded_duplicate",
       [records: &encoded_member(&1, "content.note_citations", :duplicate)]},
      {"object_encoded_remove", [records: &encoded_member(&1, "content.asset_objects", :remove)]},
      {"object_encoded_duplicate",
       [records: &encoded_member(&1, "content.asset_objects", :duplicate)]}
    ]

    Enum.map(specifications, fn {name, mutation} -> contract(name, mutation, :authentication) end)
  end

  defp change_record_version(records, type, version) do
    index = Enum.find_index(records, &(&1.type == type))
    assert is_integer(index), "requested wire record is absent"

    List.update_at(records, index, fn record ->
      term = :erlang.binary_to_term(record.payload, [:safe])
      changed = put_elem(term, 1, version)
      # Version-two has exactly 30 tables. Keep its cut structurally lawful so
      # the retained V3 first row, not an invalid vector, causes the denial.
      changed =
        if type == 1 and version == 2,
          do: put_elem(changed, 7, Enum.take(elem(changed, 7), 30)),
          else: changed

      %{record | payload: :erlang.term_to_binary(changed, [:deterministic])}
    end)
  end

  defp encoded_member(records, table, mutation) do
    index =
      Enum.find_index(records, fn
        %{type: 2, payload: payload} ->
          {:ok, decoded} = LogicalRecordCodec.decode(2, payload)
          decoded.table == table

        _ ->
          false
      end)

    assert is_integer(index), "requested fixed-cut source member is absent"

    case mutation do
      :remove -> List.delete_at(records, index)
      :duplicate -> List.insert_at(records, index, Enum.fetch!(records, index))
    end
  end

  defp unique_collision(rows, table, index, columns) do
    first = hd(rows[table])

    duplicate =
      Map.put(
        first,
        "id",
        if(table == "content.document_fragments", do: String.duplicate("e", 64), else: @unknown)
      )

    duplicate =
      case index do
        "vault_key_versions_vault_id_generation_key" ->
          Map.put(duplicate, "state", "retired")

        "vault_key_versions_one_active" ->
          Map.put(duplicate, "generation", first["generation"] + 1)

        "outbox_events_sequence_key" ->
          Map.put(duplicate, "idempotency_key", "unique-sequence-witness")

        "outbox_events_vault_id_idempotency_key_key" ->
          Map.put(duplicate, "sequence", first["sequence"] + 1)

        "job_submissions_outbox_event_id_key" ->
          Map.put(duplicate, "idempotency_key", "unique-outbox-witness")

        "job_submissions_vault_id_idempotency_key_key" ->
          Map.put(duplicate, "outbox_event_id", id(1400))

        "note_attachments_note_target_role_key" ->
          Map.put(duplicate, "ordinal", first["ordinal"] + 1)

        "note_attachments_note_ordinal_key" ->
          Map.merge(duplicate, %{
            "target_resource_id" => source_id(:plain, :resource_id),
            "target_resource_version_id" => source_id(:plain, :resource_version_id),
            "target_kind" => "asset"
          })

        _ ->
          duplicate
      end

    {original, collision} =
      if table == "content.asset_objects" do
        [left, right | _] = rows[table]
        {left, Map.merge(right, Map.take(left, columns ++ ["storage_ref"]))}
      else
        {first, duplicate}
      end

    assert Enum.all?(columns, &(original[&1] == collision[&1])), "unique witness did not collide"
    {:ok, schema} = LogicalSchemaV3.fetch_table(table)
    primary = primary_columns(schema)
    distinct_pk? = Enum.map(primary, &original[&1]) != Enum.map(primary, &collision[&1])
    assert distinct_pk?, "secondary witness must have a distinct primary key"

    values =
      if table == "content.asset_objects" do
        Enum.map(rows[table], fn row ->
          if row["id"] == collision["id"], do: collision, else: row
        end)
      else
        rows[table] ++ [collision]
      end

    put_rows(rows, table, values)
  end

  defp row_contract(name, table, key, field, value, stage, code \\ :backup_invalid) do
    contract(
      name,
      [rows: &edit(&1, table, key, fn row -> Map.replace!(row, field, value) end)],
      stage,
      code,
      stage == :preflight
    )
  end

  defp contract(
         name,
         mutation,
         earliest_stage,
         exact_error \\ :backup_invalid,
         semantics? \\ false
       ),
       do: %{
         name: name,
         mutation: mutation,
         earliest_stage: earliest_stage,
         exact_error: exact_error,
         retryable?: false,
         semantics?: semantics?
       }

  defp assert_matrix_membership(sources) do
    actual = Enum.map(sources, & &1.name)

    expected =
      ["positive", "structural_nonshared_plaintext_digest", "structural_fingerprint_and_epochs"] ++
        @required_semantic ++
        @required_wire ++
        Enum.map(@appended, &("pk:" <> &1)) ++
        Enum.map(@appended, &("scope:" <> &1 <> ":vault_id")) ++
        Enum.map(@classified, &("scope:" <> &1 <> ":classification")) ++
        Enum.map(@secondary, fn {_, index, _} -> "unique:" <> index end)

    assert Enum.sort(actual) == Enum.sort(expected)
    assert length(actual) == length(Enum.uniq(actual))
    signatures = Enum.map(sources, & &1.signature)

    assert length(signatures) == length(Enum.uniq(signatures)),
           "matrix contains duplicate logical mutations"
  end

  defp assert_unique_catalog! do
    owner_value(fn ->
      catalog =
        query(
          """
          SELECT n.nspname||'.'||t.relname,c.relname::text,i.indisprimary,
            ARRAY(SELECT a.attname::text FROM unnest(i.indkey) WITH ORDINALITY k(num,ord)
              JOIN pg_attribute a ON a.attrelid=i.indrelid AND a.attnum=k.num
              WHERE k.ord<=i.indnkeyatts ORDER BY k.ord),
            pg_get_expr(i.indpred,i.indrelid)
          FROM pg_index i JOIN pg_class t ON t.oid=i.indrelid
          JOIN pg_namespace n ON n.oid=t.relnamespace JOIN pg_class c ON c.oid=i.indexrelid
          WHERE i.indisunique AND n.nspname||'.'||t.relname=ANY($1::text[])
          ORDER BY n.nspname,t.relname,c.relname
          """,
          [@tables]
        ).rows

      for {table, index, columns} <- @secondary do
        assert Enum.any?(catalog, fn [t, n, primary?, keys, _] ->
                 t == table and n == index and not primary? and keys == columns
               end),
               "required unique index is absent or its columns changed: " <> index
      end

      for {table, index, columns} <- @pk_implied do
        assert Enum.any?(catalog, fn [t, n, primary?, keys, predicate] ->
                 t == table and n == index and not primary? and keys == columns and
                   is_nil(predicate)
               end),
               "PK-implied unique catalog changed: " <> index
      end

      for [table, index, primary?, columns, predicate] <- catalog do
        {:ok, schema} = LogicalSchemaV3.fetch_table(table)
        primary = primary_columns(schema)

        cond do
          primary? ->
            assert columns == primary, "canonical PK catalog changed: " <> index

          Enum.all?(primary, &(&1 in columns)) ->
            # A collision necessarily duplicates the PK; no independent
            # secondary counterexample is mathematically possible for this key.
            assert is_nil(predicate), "PK-implied unique unexpectedly became partial: " <> index

            assert {table, index, columns} in @pk_implied,
                   "unlisted PK-implied unique index: " <> index

          true ->
            assert {table, index, columns} in @secondary,
                   "uncovered independent canonical secondary unique index: " <> index

            case index do
              "vault_key_versions_one_active" ->
                assert predicate == "(state = 'active'::text)"

              "asset_objects_live_lookup_key" ->
                assert predicate == "(lifecycle <> 'deleted'::text)"

              _ ->
                assert is_nil(predicate), "unexpected partial canonical unique index: " <> index
            end
        end
      end

      assert Enum.count(catalog, fn [_, _, primary?, _, _] -> primary? end) == 38
    end)
  end

  defp authenticate(source) do
    {:ok, reader} =
      LocalDestination.reader_source(%{backup_root: source.portable}, source.filename)

    context = %{
      key: :crypto.hash(:sha256, "knowledge-fixture-backup-key"),
      vault_id: source.binding.vault_id,
      encryption_domain_id: id(902),
      object_id: source.binding.manifest_id,
      chunk_index: 0,
      algorithm: Format.algorithm(),
      format_version: Format.format_version(),
      chunk_size: Format.chunk_size()
    }

    BundleReader.authenticate_all(reader,
      crypto: {FixtureCrypto, context},
      verifier: {LogicalBundleVerifier, source.binding}
    )
  end

  defp with_authenticated(source, fun) do
    {:ok, verified} = authenticate(source)

    try do
      fun.(%{verified: verified, cut: verified.cut, binding: source.binding})
    after
      BundleReader.discard_verified(verified)
    end
  end

  defp assert_exact_error(result, contract) do
    # Only the sanitized code and flag may appear in failure output, never
    # whole rows, encrypted file contents, configuration, or key material.
    sanitized =
      case result do
        {:error, %Error{code: code, retryable?: retryable?, details: details, message: message}} ->
          {code, retryable?, map_size(details), is_nil(message)}

        _ ->
          :unexpected_result_shape
      end

    assert sanitized == {contract.exact_error, contract.retryable?, 0, true}, contract.name
  end

  defp snapshot(root),
    do: %{rows: owner_value(&snapshot_rows/0), files: filesystem_snapshot(root)}

  defp snapshot_rows do
    for table <- @tables ++ @excluded ++ ["content.knowledge_mutation_receipts"], into: %{} do
      case query("SELECT to_regclass($1)::text", [table]).rows do
        [[nil]] ->
          assert table == "content.knowledge_mutation_receipts",
                 "required snapshot table is absent"

          {table, :absent}

        [[_]] ->
          {table, query("SELECT to_jsonb(t) FROM #{table} t ORDER BY to_jsonb(t)::text").rows}
      end
    end
  end

  defp assert_empty_rows(before) do
    empty? = Enum.all?(before.rows, fn {_table, rows} -> rows in [[], :absent] end)
    assert empty?, "malformed matrix target must have zero canonical and derived rows"
  end

  defp filesystem_snapshot(root) do
    [root | Path.wildcard(Path.join(root, "**/*"), match_dot: true)]
    |> Enum.sort()
    |> Enum.map(fn path ->
      stat = File.lstat!(path)

      evidence =
        case stat.type do
          :regular -> {:regular, stat.size, :crypto.hash(:sha256, File.read!(path))}
          :symlink -> {:symlink, File.read_link!(path)}
          type -> type
        end

      {Path.relative_to(path, root), stat.type, stat.mode, evidence}
    end)
  end

  defp assert_no_temporary_tables do
    owner_value(fn ->
      assert [[0]] ==
               query(
                 "SELECT count(*) FROM pg_class WHERE relnamespace=pg_my_temp_schema() AND relname LIKE 'knowledge_restore_%'"
               ).rows
    end)
  end

  defp edit(rows, table, key, transform) do
    matches =
      Enum.filter(rows[table], fn row ->
        Enum.all?(key, fn {field, value} -> row[field] == value end)
      end)

    selected = hd(matches)

    put_rows(
      rows,
      table,
      Enum.map(rows[table], fn row -> if row == selected, do: transform.(row), else: row end)
    )
  end

  defp put_rows(rows, table, values) do
    {:ok, schema} = LogicalSchemaV3.fetch_table(table)
    keys = primary_columns(schema)
    Map.replace!(rows, table, Enum.sort_by(values, fn row -> Enum.map(keys, &row[&1]) end))
  end

  defp primary_columns(schema),
    do: Enum.map(schema.primary_key, &Enum.fetch!(schema.columns, &1.position).name)

  defp canonical_reference(object) do
    digest = Base.encode16(object["lookup_digest"], case: :lower)

    Enum.join(
      [
        "objects",
        object["vault_id"],
        object["key_domain_id"],
        "hmac-sha256",
        binary_part(digest, 0, 2),
        digest
      ],
      "/"
    )
  end

  defp source_id(name, field) do
    index = Enum.find_index(@source_names, &(&1 == name))
    id(%{resource_id: 300, resource_version_id: 400, asset_id: 500}[field] + index)
  end

  defp owner(fun),
    do:
      MigrationRepo.transaction(fn ->
        query("SET LOCAL ROLE singularity_table_owner")
        fun.()
      end)

  defp owner_value(fun) do
    {:ok, value} = owner(fun)
    value
  end

  defp query(statement, params \\ []),
    do: Ecto.Adapters.SQL.query!(MigrationRepo, statement, params, log: false)

  defp id(n), do: "60000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")
  defp event(value), do: Process.put(@events, [value | Process.get(@events, [])])

  defmodule ObservedStorage do
    @moduledoc false
    alias Singularity.Storage.LocalFilesystemAdapter, as: Real
    @events {Singularity.Storage.Backup.LogicalV3FailureTest, :events}

    def stage(context, options), do: observe(Real.stage(context, options), :stage)

    def append_encrypted_chunk(context, ref, bytes),
      do: observe(Real.append_encrypted_chunk(context, ref, bytes), :append)

    def seal_stage(context, ref, metadata),
      do: observe(Real.seal_stage(context, ref, metadata), :seal)

    def abort_stage(context, ref), do: observe(Real.abort_stage(context, ref), :abort)

    def finalize(context, stage, object) do
      Process.put(@events, [:finalize | Process.get(@events, [])])
      Real.finalize(context, stage, object)
    end

    defdelegate stat_stage(context, ref), to: Real
    defdelegate stat(context, ref), to: Real
    defdelegate list_staged(context), to: Real
    defdelegate rollback_finalize(context, stage, object), to: Real
    defdelegate delete(context, ref), to: Real

    defp observe(result, event) do
      if result == :ok or match?({:ok, _}, result),
        do: Process.put(@events, [event | Process.get(@events, [])])

      result
    end
  end

  # TASK10 HELPERS BEGIN — protocol/import fixture, never native custody proof.
  defp task10_source(portable) do
    File.chmod!(portable, 0o700)

    KnowledgeBackupFixtures.with_destination(:current, fn destination ->
      fixture =
        KnowledgeBackupFixtures.seed!(Map.merge(destination, %{ids: @ids, originals: @originals}))

      independent = owner_value(&task10_canonical_rows/0)
      assert Enum.sort(Map.keys(independent)) == Enum.sort(@tables)
      total = independent |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
      seals = owner_value(&task10_seals/0)
      assert length(seals) == 6

      assert [@ids.initial_note_version_id, @ids.live_note_id, @ids.vault_id, "private", 0, 0] in seals

      expected =
        Map.update!(independent, "core.vaults", fn rows ->
          Enum.map(rows, &Map.replace!(&1, "locked", true))
        end)

      source = task10_portable_bundle(fixture, portable, [])

      changed =
        task10_portable_bundle(fixture, portable,
          rows:
            &edit(&1, "content.resources", %{"id" => @ids.live_note_id}, fn row ->
              Map.replace!(row, "title", "task10 authenticated changed source")
            end)
        )

      assert source.binding.manifest_id == changed.binding.manifest_id
      same_inventory? = source.cut.object_inventory == changed.cut.object_inventory
      assert same_inventory?, "changed source must preserve its real ciphertext inventory"
      different_authenticated_hash? = source.manifest_hash != changed.manifest_hash

      assert different_authenticated_hash?,
             "changed source must have a genuinely different authenticated manifest hash"

      assert length(source.cut.object_inventory) == 5

      source_files =
        Map.new(source.cut.object_inventory, fn entry ->
          path = Path.join(destination.object_root, entry.storage_ref)
          {type, mode, size, hash} = task10_file_evidence(path)
          assert mode == 0o100600, "protocol fixture source must retain its explicit private mode"
          {entry.storage_ref, {type, size, hash}}
        end)

      Map.merge(source, %{
        expected: expected,
        total: total,
        seals: seals,
        source_files: source_files,
        changed: changed
      })
    end)
  end

  defp task10_portable_bundle(fixture, portable, options) do
    options =
      Keyword.put(options, :source, fn reader ->
        target = Path.join(portable, Path.basename(reader.path))
        File.cp!(reader.path, target)
        File.chmod!(target, 0o600)
        reader
      end)

    {:ok, bundle} = KnowledgeBackupFixtures.transformed_bundle(fixture, options)

    try do
      %{
        portable: portable,
        filename: bundle.binding.destination_ref,
        binding: bundle.binding,
        cut: bundle.cut,
        manifest_hash: bundle.verified.manifest_hash
      }
    after
      BundleReader.discard_verified(bundle.verified)
    end
  end

  defp task10_canonical_rows do
    Map.new(KnowledgeCanonicalOracle.projection(), fn {table, columns, primary} ->
      selected = Enum.map_join(columns, ",", &~s("#{&1}"))
      ordered = Enum.map_join(primary, ",", &~s("#{&1}"))

      {table,
       KnowledgeCanonicalOracle.normalize_rows(
         table,
         query("SELECT #{selected} FROM #{table} ORDER BY #{ordered}")
       )}
    end)
  end

  defp task10_import(
         source,
         destination,
         adapter \\ LocalFilesystemAdapter,
         fault \\ nil,
         repo \\ MigrationRepo
       ) do
    expected_stats =
      Map.new(source.cut.object_inventory, fn entry ->
        {entry.storage_ref, {entry.ciphertext_byte_size, entry.ciphertext_hash}}
      end)

    context = %{
      root: destination.object_root,
      fault: fault,
      expected_stats: expected_stats,
      guard: fn stage -> task10_guard!(source, stage) end
    }

    try do
      with_authenticated(source, fn input ->
        # with_authenticated always opens a fresh, one-shot verified Replay.
        Restorer.import(%{object_storage: {adapter, context}}, repo, input)
      end)
    after
      if adapter == Task10ReadOnlyStorage do
        writes = Process.get({Task10ReadOnlyStorage, context.root, :write_hits}, 0)
        reads = Process.get({Task10ReadOnlyStorage, context.root, :read_hits}, 0)
        Process.delete({Task10ReadOnlyStorage, context.root, :write_hits})
        Process.delete({Task10ReadOnlyStorage, context.root, :read_hits})
        assert writes == 0, "imported/binding verification attempted an object write"

        if fault == :binding,
          do: assert(reads == 0, "binding denial must precede all object callbacks")
      end
    end
  end

  defp task10_success(result) do
    succeeded? = match?({:ok, %Restorer.Imported{}}, result)
    assert succeeded?, "fresh authenticated replay did not return Imported"
    :ok
  end

  defp task10_error(result, code, label),
    do: assert_exact_error(result, %{name: label, exact_error: code, retryable?: false})

  defp task10_same_snapshot(before, destination, label) do
    same? = snapshot(destination.object_root) == before
    assert same?, label <> ": canonical/derived/admission/marker/seal/files changed"
  end

  defp task10_complete(source, destination) do
    actual = owner_value(&task10_canonical_rows/0)
    assert :ok == KnowledgeCanonicalOracle.compare(source.expected, actual)

    owner_value(fn ->
      seals_same? = task10_seals() == source.seals
      assert seals_same?, "six exact source sets, including empty sets, changed"
      assert [["imported"]] == query("SELECT state FROM audit.restore_import_sagas").rows
      assert [["validated"]] == query("SELECT state FROM audit.knowledge_restore_admissions").rows

      for table <-
            @excluded --
              [
                "content.note_source_set_seals",
                "audit.restore_import_sagas",
                "audit.knowledge_restore_admissions"
              ] do
        assert [[0]] == query("SELECT count(*) FROM #{table}").rows, table
      end

      optional = Map.fetch!(snapshot_rows(), "content.knowledge_mutation_receipts")
      optional_empty? = optional in [[], :absent]
      assert optional_empty?, "optional mutation receipts must stay absent or empty"
    end)

    actual_files =
      Map.new(source.cut.object_inventory, fn entry ->
        {type, mode, size, hash} =
          task10_file_evidence(Path.join(destination.object_root, entry.storage_ref))

        assert mode == 0o100400, "restored originals must be actually sealed read-only"
        {entry.storage_ref, {type, size, hash}}
      end)

    same? = actual_files == source.source_files
    assert same?, "all five physical original ciphertexts changed"

    expected_paths =
      Enum.map(source.cut.object_inventory, fn entry ->
        {:ok, receipt} =
          Singularity.Storage.Local.PathGuard.finalization_receipt_path(
            destination.object_root,
            entry.asset_object_id
          )

        [Path.join(destination.object_root, entry.storage_ref), receipt]
      end)
      |> List.flatten()
      |> Enum.sort()

    assert task10_regular_files(destination.object_root) == expected_paths
    assert {:ok, []} == LocalFilesystemAdapter.list_staged(%{root: destination.object_root})
  end

  defp task10_seals do
    query(
      "SELECT note_resource_version_id::text,note_resource_id::text,vault_id::text,classification,attachment_count,citation_count FROM content.note_source_set_seals ORDER BY note_resource_version_id"
    ).rows
  end

  defp task10_pending_empty(destination, retained? \\ false) do
    owner_value(fn ->
      rows = snapshot_rows()

      empty? =
        Enum.all?(
          Map.delete(rows, "audit.restore_import_sagas"),
          fn {_table, value} -> value in [[], :absent] end
        )

      assert empty?, "rollback retained canonical/derived/seal/admission/job rows"
      assert [["pending"]] == query("SELECT state FROM audit.restore_import_sagas").rows
    end)

    assert {:ok, []} == LocalFilesystemAdapter.list_staged(%{root: destination.object_root})
    if not retained?, do: assert(task10_regular_files(destination.object_root) == [])
  end

  defp task10_guard!(source, stage) do
    total = Enum.map_join(@tables, "+", &"(SELECT count(*) FROM #{&1})")

    case stage do
      :before_canonical ->
        assert [[0, 0, 0, "pending"]] ==
                 query(
                   "SELECT (#{total}),(SELECT count(*) FROM audit.knowledge_restore_admissions),(SELECT count(*) FROM content.note_source_set_seals),(SELECT state FROM audit.restore_import_sagas)"
                 ).rows

      :validated ->
        assert [[source.total, 6, 4, 3, 6, "validated", "pending"]] ==
                 query(
                   "SELECT (#{total}),(SELECT count(*) FROM content.note_versions),(SELECT count(*) FROM content.note_attachments),(SELECT count(*) FROM content.note_citations),(SELECT count(*) FROM content.note_source_set_seals),(SELECT state FROM audit.knowledge_restore_admissions),(SELECT state FROM audit.restore_import_sagas)"
                 ).rows
    end

    :ok
  end

  defp task10_with_fault(kind, source, destination, fun) do
    try do
      if kind in [:canonical, :empty_seal, :marker] do
        task10_sql_fault(kind, source, fun)
      else
        key =
          %{stage: :stage_fault, before_finalize: :finalize_fault, post_stat: :stat_fault}[kind]

        fun.(fn -> Task10FaultStorage.hits(destination.object_root, key) end)
      end
    after
      Task10FaultStorage.clear(destination.object_root)
    end
  end

  defp task10_sql_fault(kind, source, fun) do
    suffix = "task10_" <> String.replace(Ecto.UUID.generate(), "-", "")
    sequence = "audit.#{suffix}_hits"
    function = "audit.#{suffix}_fail"
    trigger = "#{suffix}_trigger"
    total = Enum.map_join(@tables, "+", &"(SELECT count(*) FROM #{&1})")

    loading =
      "(SELECT state FROM audit.knowledge_restore_admissions)='loading' AND (SELECT state FROM audit.restore_import_sagas)='pending'"

    graph =
      "(#{total})=#{source.total} AND (SELECT count(*) FROM content.note_versions)=6 AND (SELECT count(*) FROM content.note_attachments)=4 AND (SELECT count(*) FROM content.note_citations)=3"

    {table, operation, guard} =
      case kind do
        :canonical ->
          person = source.expected["identity.people"] |> hd() |> Map.fetch!("id")

          {"identity.people", "INSERT",
           "#{loading} AND NEW.id='#{person}'::uuid AND (#{total})=0 AND (SELECT count(*) FROM content.note_source_set_seals)=0"}

        :empty_seal ->
          {"content.note_source_set_seals", "INSERT",
           "#{loading} AND #{graph} AND NEW.note_resource_version_id='#{@ids.initial_note_version_id}'::uuid AND NEW.attachment_count=0 AND NEW.citation_count=0 AND (SELECT count(*) FROM content.note_attachments WHERE note_resource_version_id=NEW.note_resource_version_id)=0 AND (SELECT count(*) FROM content.note_citations WHERE note_resource_version_id=NEW.note_resource_version_id)=0 AND (SELECT count(*) FROM content.note_source_set_seals)=0"}

        :marker ->
          {"audit.restore_import_sagas", "UPDATE",
           "OLD.state='pending' AND NEW.state='imported' AND #{graph} AND (SELECT count(*) FROM content.note_source_set_seals)=6 AND (SELECT state FROM audit.knowledge_restore_admissions)='validated' AND (SELECT count(*) FROM content.asset_objects)=5 AND NEW.object_count=5"}
      end

    owner_value(fn ->
      query("CREATE SEQUENCE #{sequence}")

      query(
        "CREATE FUNCTION #{function}() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $fault$ BEGIN IF (#{guard}) IS NOT TRUE THEN RAISE EXCEPTION 'task10_wrong_fault_stage'; END IF; PERFORM pg_catalog.nextval(TG_ARGV[0]::regclass); RAISE EXCEPTION 'task10_#{kind}_fault'; END $fault$"
      )

      query(
        "CREATE TRIGGER #{trigger} BEFORE #{operation} ON #{table} FOR EACH ROW EXECUTE FUNCTION #{function}('#{sequence}')"
      )
    end)

    try do
      fun.(fn ->
        owner_value(fn ->
          [[count, called?]] = query("SELECT last_value,is_called FROM #{sequence}").rows
          if called?, do: count, else: 0
        end)
      end)
    after
      owner_value(fn ->
        query("DROP TRIGGER #{trigger} ON #{table}")
        query("DROP FUNCTION #{function}()")
        query("DROP SEQUENCE #{sequence}")
      end)
    end
  end

  defp task10_assert_fault_order(fault, source, destination) do
    root = destination.object_root

    case fault do
      :stage ->
        assert Task10FaultStorage.hits(root, :stage) == 1
        assert Task10FaultStorage.hits(root, :seal) == 0
        assert Task10FaultStorage.hits(root, :finalize) == 0

      kind when kind in [:canonical, :empty_seal] ->
        assert Task10FaultStorage.hits(root, :stage) == 5
        assert Task10FaultStorage.hits(root, :seal) == 5
        assert Task10FaultStorage.hits(root, :finalize) == 0

      :before_finalize ->
        assert Task10FaultStorage.hits(root, :seal) == 5
        assert Task10FaultStorage.hits(root, :finalize) == 1
        assert Task10FaultStorage.hits(root, :published) == 0

      :post_stat ->
        assert Task10FaultStorage.hits(root, :seal) == 5
        assert Task10FaultStorage.hits(root, :published) == 1
        assert Task10FaultStorage.hits(root, :stat_verified) == 1
        assert Task10FaultStorage.hits(root, :rollback_published) == 1

      :marker ->
        assert Task10FaultStorage.hits(root, :published) == 5
        assert Task10FaultStorage.hits(root, :stat_verified) == 5
        assert Task10FaultStorage.hits(root, :rollback_published) == 5
        expected = MapSet.new(source.cut.object_inventory, & &1.storage_ref)

        same_objects? =
          Task10FaultStorage.objects(root, :published_objects) == expected and
            Task10FaultStorage.objects(root, :stat_objects) == expected

        assert same_objects?,
               "marker fault must follow all five distinct actual publications and stats"
    end
  end

  defp task10_retained_pending(source, destination) do
    try do
      task10_error(
        task10_import(source, destination, Task10FaultStorage, :retain),
        :storage_unavailable,
        "identity-bound retained publication"
      )

      root = destination.object_root
      assert Task10FaultStorage.hits(root, :published) == 1
      assert Task10FaultStorage.hits(root, :stat_verified) == 1
      assert Task10FaultStorage.hits(root, :rollback_fault) == 1
      published = Task10FaultStorage.objects(root, :published_objects)
      expected = MapSet.new(source.cut.object_inventory, & &1.storage_ref)
      assert MapSet.size(published) == 1

      subset? =
        MapSet.subset?(published, expected) and
          published == Task10FaultStorage.objects(root, :stat_objects)

      assert subset?, "retained receipt must belong to the actual authenticated inventory"
      task10_pending_empty(destination, true)
      assert length(task10_regular_files(root)) == 2
    after
      Task10FaultStorage.clear(destination.object_root)
    end
  end

  defp task10_prepare_state(:pending, source, destination),
    do: task10_retained_pending(source, destination)

  defp task10_prepare_state(:imported, source, destination) do
    task10_success(task10_import(source, destination))
    task10_complete(source, destination)
  end

  defp task10_change_marker(field) do
    assignment =
      case field do
        name when name in ["manifest_id", "vault_id"] ->
          "#{name}='#{@unknown}'::uuid"

        "manifest_tag" ->
          "manifest_tag=decode(repeat('00',16),'hex')"

        "object_count" ->
          "object_count=object_count+1"

        name when name in ["manifest_hash", "inventory_hash", "destination_root_hash"] ->
          "#{name}=decode(repeat('00',32),'hex')"
      end

    owner_value(fn ->
      %{num_rows: 1} =
        query("UPDATE audit.restore_import_sagas SET #{assignment} WHERE singleton")
    end)
  end

  defp task10_regular_files(root),
    do:
      Path.wildcard(Path.join(root, "**/*"), match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.sort()

  defp task10_file_evidence(path) do
    stat = File.lstat!(path)
    assert stat.type == :regular, "expected a regular owned artifact"
    {stat.type, stat.mode, stat.size, :crypto.hash(:sha256, File.read!(path))}
  end

  defmodule Task10CommitUncertaintyRepo do
    use Ecto.Repo, otp_app: :singularity_storage, adapter: Ecto.Adapters.Postgres
    def default_options(_operation), do: [telemetry_event: nil]
    defoverridable transact: 2

    def transact(fun, options) do
      result = super(fun, options)

      if result == {:ok, :imported} and Process.get({__MODULE__, :armed}, false) do
        false = in_transaction?()
        Process.put({__MODULE__, :armed}, false)
        Process.put({__MODULE__, :hits}, Process.get({__MODULE__, :hits}, 0) + 1)
        Process.put({__MODULE__, :committed_result}, result)
        {:error, :simulated_commit_uncertainty}
      else
        result
      end
    end
  end

  defmodule Task10FaultStorage do
    alias Singularity.Core.Error
    alias Singularity.Storage.LocalFilesystemAdapter, as: Real
    alias Singularity.Storage.Local.PathGuard

    @names [
      :stage,
      :stage_fault,
      :seal,
      :finalize,
      :finalize_fault,
      :published,
      :stat_verified,
      :stat_fault,
      :rollback_fault,
      :rollback_published,
      :published_objects,
      :stat_objects
    ]

    def stage(context, options) do
      result = Real.stage(context, options)
      if match?({:ok, _}, result), do: hit(context.root, :stage)

      if context.fault == :stage and hits(context.root, :stage_fault) == 0 and
           match?({:ok, _}, result) do
        :ok = context.guard.(:before_canonical)
        1 = hit(context.root, :stage_fault)
        {:error, Error.new(:storage_unavailable)}
      else
        result
      end
    end

    def seal_stage(context, stage, metadata) do
      result = Real.seal_stage(context, stage, metadata)
      if result == :ok or match?({:ok, _}, result), do: hit(context.root, :seal)
      result
    end

    def finalize(context, stage, object) do
      hit(context.root, :finalize)
      :ok = context.guard.(:validated)

      if context.fault == :before_finalize and hits(context.root, :finalize_fault) == 0 do
        1 = hit(context.root, :finalize_fault)
        {:error, Error.new(:storage_unavailable)}
      else
        result = Real.finalize(context, stage, object)

        if match?({:ok, _}, result) do
          hit(context.root, :published)
          record(context.root, :published_objects, object.object_id)
        end

        result
      end
    end

    def stat(context, object) do
      result = Real.stat(context, object)

      if hits(context.root, :published) > 0 and match?({:ok, _}, result) do
        {:ok, actual} = result
        {expected_size, expected_hash} = Map.fetch!(context.expected_stats, object.object_id)
        true = actual.ciphertext_hash == expected_hash
        true = actual.byte_size == expected_size
        hit(context.root, :stat_verified)
        record(context.root, :stat_objects, object.object_id)

        if context.fault in [:post_stat, :retain] and hits(context.root, :stat_fault) == 0 do
          :ok = context.guard.(:validated)
          1 = hit(context.root, :stat_fault)
          {:error, Error.new(:storage_unavailable)}
        else
          result
        end
      else
        result
      end
    end

    def rollback_finalize(context, stage, object) do
      published? = published_artifact?(context, stage, object)

      if published? and context.fault == :retain and hits(context.root, :rollback_fault) == 0 do
        1 = hit(context.root, :rollback_fault)
        {:error, Error.new(:storage_unavailable)}
      else
        result = Real.rollback_finalize(context, stage, object)
        if published? and result == :ok, do: hit(context.root, :rollback_published)
        result
      end
    end

    defp published_artifact?(context, stage, object) do
      with {:ok, %{ciphertext_hash: hash}} <- Real.stat(context, object),
           true <- hash == context.ciphertext_hash,
           {:ok, receipt} <- PathGuard.finalization_receipt_path(context.root, stage.stage_id),
           {:ok, %File.Stat{type: :regular}} <- File.lstat(receipt) do
        true
      else
        _ -> false
      end
    end

    defdelegate append_encrypted_chunk(context, stage, bytes), to: Real
    defdelegate stat_stage(context, stage), to: Real
    defdelegate abort_stage(context, stage), to: Real
    defdelegate delete(context, object), to: Real
    defdelegate list_staged(context), to: Real
    def hits(root, name), do: Process.get({__MODULE__, root, name}, 0)
    def objects(root, name), do: Process.get({__MODULE__, root, name}, MapSet.new())
    def clear(root), do: Enum.each(@names, &Process.delete({__MODULE__, root, &1}))

    defp record(root, name, object),
      do: Process.put({__MODULE__, root, name}, MapSet.put(objects(root, name), object))

    defp hit(root, name) do
      value = hits(root, name) + 1
      Process.put({__MODULE__, root, name}, value)
      value
    end
  end

  defmodule Task10ReadOnlyStorage do
    alias Singularity.Core.Error
    alias Singularity.Storage.LocalFilesystemAdapter, as: Real
    def stage(context, _options), do: deny(context)
    def append_encrypted_chunk(context, _stage, _bytes), do: deny(context)
    def seal_stage(context, _stage, _metadata), do: deny(context)
    def finalize(context, _stage, _object), do: deny(context)
    def abort_stage(context, _stage), do: deny(context)
    def rollback_finalize(context, _stage, _object), do: deny(context)
    def delete(context, _object), do: deny(context)

    def stat(context, object) do
      observe_read(context)
      Real.stat(context, object)
    end

    def list_staged(context) do
      observe_read(context)
      Real.list_staged(context)
    end

    defp observe_read(context) do
      key = {__MODULE__, context.root, :read_hits}
      Process.put(key, Process.get(key, 0) + 1)
    end

    defp deny(context) do
      key = {__MODULE__, context.root, :write_hits}
      Process.put(key, Process.get(key, 0) + 1)
      {:error, Error.new(:storage_unavailable)}
    end
  end

  # TASK10 HELPERS END

  defp assert_rejected_graph(sources) do
    assert_raise MatchError, "no match of right hand side value: false", fn ->
      KnowledgeBackupFixtures.seed_graph!(%{
        owner: :not_used,
        ids: :not_used,
        sources: sources,
        work: :not_used
      })
    end
  end
end
