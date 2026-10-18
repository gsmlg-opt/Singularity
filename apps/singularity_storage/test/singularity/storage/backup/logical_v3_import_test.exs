defmodule Singularity.Storage.Backup.LogicalV3ImportTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Storage.{LocalFilesystemAdapter, MigrationRepo}

  alias Singularity.Storage.Backup.{
    BundleReader,
    KnowledgeBackupFixtures,
    KnowledgePreflight,
    KnowledgeRestoreDigest,
    LocalDestination,
    LogicalBundleVerifier,
    LogicalRecordCodec,
    LogicalSchemaV3,
    Manifest,
    Restorer
  }

  alias Singularity.Storage.Backup.KnowledgeBackupFixtures.FixtureCrypto
  alias Singularity.Storage.Crypto.{Argon2KeyDeriver, ChunkedAEAD, Format}
  alias Singularity.Storage.Local.PathGuard

  # The table order and cardinalities are source-construction literals, not
  # manifest-selected or destination-derived expectations.
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
  @counts [
    1,
    1,
    1,
    2,
    2,
    1,
    2,
    2,
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
  @added Enum.drop(@tables, 30)
  @excluded ~w(identity.sessions identity.auth_attempts content.asset_stages content.upload_grants
    content.asset_search_documents content.note_search_documents content.search_entries
    content.note_mutation_receipts audit.backup_manifests audit.backup_manifest_objects
    jobs.oban_jobs jobs.oban_peers)
  @ordinary ~w(resource_versions_resource_classification_fkey resources_version_head_fkey
    note_versions_parent_fkey note_versions_merge_parent_fkey note_conflicts_base_version_fkey
    note_conflicts_canonical_version_fkey note_conflicts_competing_version_fkey
    note_conflicts_resolution_version_fkey note_mutation_receipts_resource_fkey
    note_mutation_receipts_version_fkey note_mutation_receipts_conflict_fkey
    document_versions_resource_version_fkey document_import_receipts_version_fkey
    document_fragments_document_version_fkey note_attachments_note_fkey note_attachments_target_fkey
    note_citations_note_fkey note_citations_fragment_fkey note_source_set_seals_note_fkey
    note_versions_aggregate_check note_mutation_receipts_resource_check resources_00_typed_head_check
    note_versions_00_typed_head_check document_versions_00_typed_head_check
    document_import_receipts_completed_check document_versions_completion_check
    document_fragments_completion_check note_attachments_source_set_check
    note_citations_source_set_check note_versions_source_set_seal_check
    note_attachments_source_set_seal_check note_citations_source_set_seal_check)
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
         {name, "50000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")}
       end)
  @originals %{
    pdf: "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n",
    pdf_duplicate: "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n",
    empty: "",
    plain: "plain original\r\nsecond line\n",
    unicode: "界🙂 café\n",
    markdown: "# Original Markdown\n\n[source](https://example.test/)\n"
  }
  @golden_sha "75605267628f11cb694b8ae05cd9b43fcdb87ae0c240fcc98c87ab143045b6b2"

  # This is a registered, real PostgreSQL repo. The error is injected only
  # after super has completed actual COMMIT, not in a callback or fake delegate.
  defmodule CommitUncertaintyRepo do
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

  # Only actual storage operations are delegated. Process-local counters are
  # outside PostgreSQL rollback and prove that the chosen boundary was reached.
  defmodule FaultStorage do
    alias Singularity.Core.Error
    alias Singularity.Storage.{LocalFilesystemAdapter, MigrationRepo}
    alias Singularity.Storage.Local.PathGuard

    def stage(context, options) do
      if context.fault == :before_canonical and hit(context, :stage) == 1 do
        [[0]] = query("SELECT count(*) FROM content.resources")
        [[0]] = query("SELECT count(*) FROM audit.knowledge_restore_admissions")
        {:error, Error.new(:storage_unavailable)}
      else
        LocalFilesystemAdapter.stage(context, options)
      end
    end

    def finalize(context, stage, object) do
      hit(context, :finalize)

      if context.fault == :before_publication do
        [[6]] = query("SELECT count(*) FROM content.note_source_set_seals")
        [["validated"]] = query("SELECT state FROM audit.knowledge_restore_admissions")
        [["pending"]] = query("SELECT state FROM audit.restore_import_sagas")
        Process.put({__MODULE__, context.root, :validated_before_publication}, true)
        {:error, Error.new(:storage_unavailable)}
      else
        result = LocalFilesystemAdapter.finalize(context, stage, object)

        if match?({:ok, _}, result), do: hit(context, :published)
        result
      end
    end

    def stat(context, object) do
      if context.fault in [:after_publication, :retain_publication] and
           Process.get({__MODULE__, context.root, :published}, 0) > 0 and
           hit(context, :stat_failure) == 1 do
        {:error, Error.new(:storage_unavailable)}
      else
        LocalFilesystemAdapter.stat(context, object)
      end
    end

    def rollback_finalize(context, stage, object) do
      if context.fault == :retain_publication and
           Process.get({__MODULE__, context.root, :published}, 0) > 0 and
           Process.get({__MODULE__, context.root, :rollback_failure}, 0) == 0 and
           finalized_artifact?(context, stage, object) do
        1 = hit(context, :rollback_failure)
        {:error, Error.new(:storage_unavailable)}
      else
        LocalFilesystemAdapter.rollback_finalize(context, stage, object)
      end
    end

    defp finalized_artifact?(context, stage, object) do
      with {:ok, %{ciphertext_hash: hash}} <- LocalFilesystemAdapter.stat(context, object),
           true <- hash == context.ciphertext_hash,
           {:ok, path} <- PathGuard.finalization_receipt_path(context.root, stage.stage_id),
           {:ok, %File.Stat{type: :regular}} <- File.lstat(path) do
        true
      else
        _not_published -> false
      end
    end

    defdelegate append_encrypted_chunk(context, stage, bytes), to: LocalFilesystemAdapter
    defdelegate seal_stage(context, stage, metadata), to: LocalFilesystemAdapter
    defdelegate stat_stage(context, stage), to: LocalFilesystemAdapter
    defdelegate abort_stage(context, stage), to: LocalFilesystemAdapter
    defdelegate delete(context, object), to: LocalFilesystemAdapter
    defdelegate list_staged(context), to: LocalFilesystemAdapter

    defp hit(context, name) do
      key = {__MODULE__, context.root, name}
      value = Process.get(key, 0) + 1
      Process.put(key, value)
      value
    end

    defp query(sql), do: Ecto.Adapters.SQL.query!(MigrationRepo, sql, [], log: false).rows
  end

  defmodule ReadOnlyStorage do
    alias Singularity.Storage.LocalFilesystemAdapter

    for {name, arity} <- [
          stage: 2,
          append_encrypted_chunk: 3,
          seal_stage: 3,
          finalize: 3,
          abort_stage: 2,
          rollback_finalize: 3,
          delete: 2
        ] do
      arguments =
        Macro.generate_arguments(arity, __MODULE__)
        |> Enum.with_index()
        |> Enum.map(fn {{name, metadata, context}, index} ->
          name = if index == 0, do: name, else: String.to_atom("_" <> Atom.to_string(name))
          {name, metadata, context}
        end)

      def unquote(name)(unquote_splicing(arguments)) do
        context = unquote(hd(arguments))
        key = {__MODULE__, context.root, :write_hits}
        Process.put(key, Process.get(key, 0) + 1)
        raise "imported verification attempted #{unquote(name)}"
      end
    end

    defdelegate stat(context, object), to: LocalFilesystemAdapter
    defdelegate list_staged(context), to: LocalFilesystemAdapter
  end

  setup_all do
    portable = Path.join(System.tmp_dir!(), "logical-v3-import-#{Ecto.UUID.generate()}")
    File.mkdir_p!(portable)
    File.chmod!(portable, 0o700)
    on_exit(fn -> File.rm_rf!(portable) end)
    source = prepare_source(portable)
    legacy = prepare_v2(portable)
    %{source: source, legacy: legacy}
  end

  for algorithm <- ["aes_256_gcm", "aes-256-gcm"] do
    @tag :tmp_dir
    test "structural V3 full import preserves established owner algorithm #{algorithm}",
         %{tmp_dir: tmp_dir} do
      algorithm = unquote(algorithm)
      portable = Path.join(tmp_dir, "algorithm")
      File.mkdir!(portable)
      File.chmod!(portable, 0o700)
      source = prepare_source(portable, vault_algorithm: algorithm)

      with_destination(source, fn destination ->
        assert {:ok, %Restorer.Imported{} = imported} = import_bundle(source, destination)
        assert imported.cut.logical_version == 3
        assert Enum.map(source.rows["core.vault_key_versions"], & &1["algorithm"]) == [algorithm]

        assert owner_value(fn -> rows("SELECT algorithm FROM core.vault_key_versions") end) ==
                 [[algorithm]]

        assert_complete(source, destination)
        before = snapshot(destination.object_root)
        assert {:ok, ^imported} = import_bundle(source, destination, ReadOnlyStorage)
        assert snapshot(destination.object_root) == before
        assert_complete(source, destination)
      end)
    end
  end

  test "owned V3 graph keeps malformed and adjacent algorithm metadata denied",
       %{source: source} do
    vectors =
      Enum.map(
        ["", "unknown", "aes-128-gcm", "AES-256-GCM", "aes-256-gcm ", "aes_256_gcm "],
        &{"core.vault_key_versions", &1}
      ) ++
        Enum.map(
          [
            "core.domain_key_versions",
            "core.domain_dedup_key_wrappers",
            "content.asset_key_envelopes"
          ],
          &{&1, "aes-256-gcm"}
        )

    with_destination(source, fn destination ->
      assert {:ok, %Restorer.Imported{}} = import_bundle(source, destination)
      before = snapshot(destination.object_root)

      for {table, algorithm} <- vectors do
        assert {:error, :algorithm_rejected} =
                 owner(fn ->
                   assert %{num_rows: count} =
                            sql("UPDATE #{table} SET algorithm=$1", [algorithm])

                   assert count > 0

                   assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
                            Singularity.Storage.SafeSQL.query(
                              MigrationRepo,
                              "SELECT audit.assert_knowledge_restore_graph($1)",
                              [dump(@ids.vault_id)]
                            )

                   MigrationRepo.rollback(:algorithm_rejected)
                 end)

        assert snapshot(destination.object_root) == before
      end

      assert_complete(source, destination)
    end)
  end

  test "public import restores the literal 114-row complete V3 cut into a different empty database",
       %{source: source} do
    with_destination(source, fn destination ->
      assert_empty(destination.object_root, :absent)
      assert_constraint_catalog()
      # Initial causal RED: the current dispatch rejects logical_version 3
      # with backup_invalid before entering repository or object operations.
      assert {:ok, %Restorer.Imported{} = imported} = import_bundle(source, destination)
      assert imported.cut.logical_version == 3

      owner(fn ->
        assert Enum.map(@tables, fn table ->
                 [[count]] = rows("SELECT count(*) FROM #{table}")
                 count
               end) == @counts
      end)

      authenticated(source, fn input -> assert imported.cut == input.cut end)
      assert imported.owner.account_id == @ids.account_id
      assert imported.owner.owner_principal_ids == [@ids.principal_id]
      assert_complete(source, destination)
    end)
  end

  test "retained PDF pins and deduplication restore exactly five original ciphertext objects",
       %{source: source} do
    with_destination(source, fn destination ->
      assert {:ok, %Restorer.Imported{}} = import_bundle(source, destination)
      assert map_size(source.ciphertexts) == 5
      assert source.sources.pdf.object_id == source.sources.pdf_duplicate.object_id
      assert source.sources.pdf.digest == :crypto.hash(:sha256, @originals.pdf)

      owner(fn ->
        assert [[2]] ==
                 rows(
                   "SELECT count(*) FROM content.assets WHERE state='deleted' AND asset_object_id IS NULL"
                 )

        assert [[2]] ==
                 rows(
                   "SELECT count(*) FROM content.resource_assets WHERE released_at IS NOT NULL"
                 )

        assert [[@ids.ready_old_version_id]] ==
                 rows("SELECT target_resource_version_id::text FROM content.relationships")

        assert [[3]] ==
                 rows(
                   "SELECT count(*) FROM content.document_versions WHERE state='ready' AND source_object_id=$1",
                   [dump(source.sources.pdf.object_id)]
                 )
      end)

      assert_objects(source, destination.object_root)
      assert_complete(source, destination)
    end)
  end

  test "all six historical source sets seal after exact empty, merge and deleted memberships",
       %{source: source} do
    with_destination(source, fn destination ->
      assert {:ok, %Restorer.Imported{}} = import_bundle(source, destination)

      owner(fn ->
        assert seal_rows() == source.seals

        assert [[0, 0]] ==
                 rows(
                   "SELECT attachment_count,citation_count FROM content.note_source_set_seals WHERE note_resource_version_id=$1",
                   [dump(@ids.initial_note_version_id)]
                 )

        assert [[1, 1]] ==
                 rows(
                   "SELECT attachment_count,citation_count FROM content.note_source_set_seals WHERE note_resource_version_id=$1",
                   [dump(@ids.merge_note_version_id)]
                 )

        assert [[1, 1]] ==
                 rows(
                   "SELECT attachment_count,citation_count FROM content.note_source_set_seals WHERE note_resource_version_id=$1",
                   [dump(@ids.deleted_note_version_id)]
                 )

        assert [[@ids.canonical_note_version_id, @ids.competing_note_version_id]] ==
                 rows(
                   "SELECT parent_version_id::text,merge_parent_version_id::text FROM content.note_versions WHERE resource_version_id=$1",
                   [dump(@ids.merge_note_version_id)]
                 )

        assert [["open"], ["resolved"]] ==
                 rows("SELECT state FROM content.note_conflicts ORDER BY state")
      end)

      assert_complete(source, destination)
    end)
  end

  test "fresh authenticated imported retry is read-only for all V3 rows, seals and objects",
       %{source: source} do
    with_destination(source, fn destination ->
      assert {:ok, %Restorer.Imported{} = first} = import_bundle(source, destination)
      before = snapshot(destination.object_root)

      assert {:ok, %Restorer.Imported{} = retry} =
               import_bundle(source, destination, ReadOnlyStorage)

      assert retry == first
      assert snapshot(destination.object_root) == before
      assert_complete(source, destination)
    end)
  end

  test "fresh imported retry rejects same-count ordinary Note tampering without rewriting it",
       %{source: source} do
    with_destination(source, fn destination ->
      assert {:ok, %Restorer.Imported{}} = import_bundle(source, destination)

      owner(fn ->
        assert %{num_rows: 1} =
                 sql(
                   "UPDATE content.note_versions SET markdown='# Same-count tamper' WHERE resource_version_id=$1",
                   [dump(@ids.initial_note_version_id)]
                 )
      end)

      before = snapshot(destination.object_root)

      assert {:error, %Error{code: :conflict}} =
               import_bundle(source, destination, ReadOnlyStorage)

      assert snapshot(destination.object_root) == before

      owner(fn ->
        assert [[6]] == rows("SELECT count(*) FROM content.note_versions")

        assert [["# Same-count tamper"]] ==
                 rows("SELECT markdown FROM content.note_versions WHERE resource_version_id=$1", [
                   dump(@ids.initial_note_version_id)
                 ])
      end)
    end)
  end

  test "fresh imported retry rejects a genuine extra search projection and preserves it",
       %{source: source} do
    with_destination(source, fn destination ->
      assert {:ok, %Restorer.Imported{}} = import_bundle(source, destination)

      owner(fn ->
        # Project the actual live Note without changing canonical history.
        sql("SELECT content.reconcile_search_resource_internal($1,$2)", [
          dump(@ids.vault_id),
          dump(@ids.live_note_id)
        ])

        assert [[count]] = rows("SELECT count(*) FROM content.search_entries")
        assert count > 0
      end)

      before = snapshot(destination.object_root)

      assert {:error, %Error{code: :conflict}} =
               import_bundle(source, destination, ReadOnlyStorage)

      assert snapshot(destination.object_root) == before

      owner(fn ->
        assert [[count]] = rows("SELECT count(*) FROM content.search_entries")
        assert count > 0
      end)
    end)
  end

  test "known failure before canonical insertion rolls back stages and permits an exact fresh retry",
       %{source: source} do
    with_destination(source, fn destination ->
      assert {:error, %Error{}} =
               import_bundle(source, destination, FaultStorage, :before_canonical)

      assert fault_hits(destination, :stage) == 1
      assert_empty(destination.object_root, :pending)
      assert {:ok, %Restorer.Imported{}} = import_bundle(source, destination)
      assert_complete(source, destination)
    end)
  end

  test "a real source-set finalization failure rolls back the entire canonical graph",
       %{source: source} do
    with_destination(source, fn destination ->
      with_sql_fault(:seal, fn counter ->
        assert {:error, %Error{}} = import_bundle(source, destination)
        assert counter.() == 1
        assert_empty(destination.object_root, :pending)
      end)

      assert {:ok, %Restorer.Imported{}} = import_bundle(source, destination)
      assert_complete(source, destination)
    end)
  end

  test "failure after validated canonical insertion but before publication leaves no objects",
       %{source: source} do
    with_destination(source, fn destination ->
      assert {:error, %Error{}} =
               import_bundle(source, destination, FaultStorage, :before_publication)

      assert fault_hits(destination, :finalize) == 1
      assert Process.get({FaultStorage, destination.object_root, :validated_before_publication})
      assert fault_hits(destination, :published) == 0
      assert_empty(destination.object_root, :pending)
      assert {:ok, %Restorer.Imported{}} = import_bundle(source, destination)
      assert_complete(source, destination)
    end)
  end

  test "failure after actual object publication removes only owned finalized artifacts",
       %{source: source} do
    with_destination(source, fn destination ->
      assert {:error, %Error{}} =
               import_bundle(source, destination, FaultStorage, :after_publication)

      assert fault_hits(destination, :published) == 1
      assert fault_hits(destination, :stat_failure) == 1
      assert_empty(destination.object_root, :pending)
      assert {:ok, %Restorer.Imported{}} = import_bundle(source, destination)
      assert_complete(source, destination)
    end)
  end

  test "failure at the actual imported marker rolls back validated rows and five published objects",
       %{source: source} do
    with_destination(source, fn destination ->
      with_sql_fault(:marker, fn counter ->
        assert {:error, %Error{}} = import_bundle(source, destination, FaultStorage, :marker)
        assert counter.() == 1
        assert fault_hits(destination, :published) == 5
        assert_empty(destination.object_root, :pending)
      end)

      assert {:ok, %Restorer.Imported{}} = import_bundle(source, destination)
      assert_complete(source, destination)
    end)
  end

  test "committed-but-error outcome preserves the committed imported graph and recovers read-only",
       %{source: source} do
    with_destination(source, fn destination ->
      options = MigrationRepo.config() |> Keyword.put(:name, CommitUncertaintyRepo)
      assert {:ok, pid} = CommitUncertaintyRepo.start_link(options)
      Process.unlink(pid)
      Process.put({CommitUncertaintyRepo, :armed}, true)
      Process.put({CommitUncertaintyRepo, :hits}, 0)

      try do
        assert {:error, %Error{code: :storage_unavailable}} =
                 import_bundle(
                   source,
                   destination,
                   LocalFilesystemAdapter,
                   nil,
                   CommitUncertaintyRepo
                 )

        assert Process.get({CommitUncertaintyRepo, :hits}) == 1
        assert Process.get({CommitUncertaintyRepo, :committed_result}) == {:ok, :imported}
        refute CommitUncertaintyRepo.in_transaction?()
        assert_complete(source, destination)
        before = snapshot(destination.object_root)
        assert {:ok, %Restorer.Imported{}} = import_bundle(source, destination, ReadOnlyStorage)
        assert snapshot(destination.object_root) == before
        assert_complete(source, destination)
      after
        Supervisor.stop(pid)
        Process.delete({CommitUncertaintyRepo, :armed})
        Process.delete({CommitUncertaintyRepo, :hits})
        Process.delete({CommitUncertaintyRepo, :committed_result})
      end
    end)
  end

  test "pending recovery binds the authenticated manifest and exact destination root",
       %{source: source} do
    with_destination(source, fn destination ->
      assert {:error, %Error{}} =
               import_bundle(source, destination, FaultStorage, :retain_publication)

      assert fault_hits(destination, :published) == 1
      assert fault_hits(destination, :rollback_failure) == 1
      before = snapshot(destination.object_root)
      assert length(before.files) >= 1
      assert_pending_empty_graph()
      assert {:error, %Error{code: :conflict}} = import_bundle(source.alternate, destination)
      assert snapshot(destination.object_root) == before

      other_root = Path.join(destination.object_root, "different-destination")
      File.mkdir_p!(other_root)
      File.chmod!(other_root, 0o700)

      assert {:error, %Error{code: :conflict}} =
               import_bundle(source, %{destination | object_root: other_root})

      assert regular_files(other_root) == []
      assert snapshot(destination.object_root) == before
      File.rmdir!(other_root)

      assert {:ok, %Restorer.Imported{}} = import_bundle(source, destination)
      assert_complete(source, destination)
    end)
  end

  test "pending cleanup preserves foreign files and exact fresh retry recovers after their removal",
       %{source: source} do
    with_destination(source, fn destination ->
      assert {:error, %Error{}} =
               import_bundle(source, destination, FaultStorage, :retain_publication)

      assert fault_hits(destination, :published) == 1
      assert fault_hits(destination, :rollback_failure) == 1
      owned = regular_files(destination.object_root)
      assert owned != []
      foreign = Path.join(destination.object_root, "foreign-object")
      File.write!(foreign, "foreign operator data", [:exclusive])
      File.chmod!(foreign, 0o600)
      assert {:error, %Error{code: :conflict}} = import_bundle(source, destination)
      assert File.read!(foreign) == "foreign operator data"
      assert regular_files(destination.object_root) == [foreign]
      assert_pending_empty_graph()
      File.rm!(foreign)
      assert {:ok, %Restorer.Imported{}} = import_bundle(source, destination)
      assert_complete(source, destination)
    end)
  end

  test "genuine V1 golden imports no appended knowledge rows or source seals" do
    golden = golden_source()

    KnowledgeBackupFixtures.with_destination(:current, fn destination ->
      assert {:ok, %Restorer.Imported{cut: %{logical_version: 1}}} =
               import_bundle(golden, destination)

      owner(fn ->
        for table <-
              @added ++
                ~w(content.note_versions content.note_conflicts content.note_source_set_seals),
            do: assert([[0]] == rows("SELECT count(*) FROM #{table}"))

        assert_excluded()
      end)

      before = snapshot(destination.object_root)
      assert {:ok, %Restorer.Imported{}} = import_bundle(golden, destination, ReadOnlyStorage)
      assert snapshot(destination.object_root) == before
    end)
  end

  test "genuine V2 empty source sets remain compatible without any of the eight appended tables",
       %{legacy: legacy} do
    KnowledgeBackupFixtures.with_destination(:current, fn destination ->
      assert {:ok, %Restorer.Imported{cut: %{logical_version: 2}}} =
               import_bundle(legacy, destination)

      owner(fn ->
        for table <- @added, do: assert([[0]] == rows("SELECT count(*) FROM #{table}"))
        assert [[1]] == rows("SELECT count(*) FROM content.note_versions")

        assert [[id(11), 0, 0]] ==
                 rows(
                   "SELECT note_resource_version_id::text,attachment_count,citation_count FROM content.note_source_set_seals"
                 )

        assert_excluded()
      end)

      before = snapshot(destination.object_root)
      assert {:ok, %Restorer.Imported{}} = import_bundle(legacy, destination, ReadOnlyStorage)
      assert snapshot(destination.object_root) == before
    end)
  end

  test "V2 imported retry with a genuine valid tag rejects an extra V3 row under the expanded union",
       %{legacy: legacy} do
    KnowledgeBackupFixtures.with_destination(:current, fn destination ->
      assert {:ok, %Restorer.Imported{}} = import_bundle(legacy, destination)

      owner(fn ->
        sql(
          "INSERT INTO content.tags(id,vault_id,classification,display_value,normalized_key,created_by_principal_id,inserted_at) VALUES($1,$2,'private','Extra','extra',$3,CURRENT_TIMESTAMP)",
          [dump(id(990)), dump(legacy.binding.vault_id), dump(id(2))]
        )

        assert [[1]] == rows("SELECT count(*) FROM content.tags")
      end)

      before = snapshot(destination.object_root)

      assert {:error, %Error{code: :conflict}} =
               import_bundle(legacy, destination, ReadOnlyStorage)

      assert snapshot(destination.object_root) == before
      owner(fn -> assert [[1]] == rows("SELECT count(*) FROM content.tags") end)
    end)
  end

  test "verification-only staging performs no object writes and cannot open or validate admission",
       %{source: source} do
    with_destination(source, fn destination ->
      authenticated(source, fn input ->
        assert {:ok, :verified} =
                 owner(fn ->
                   staged = verification_stage(input, destination)
                   assert Map.fetch!(staged, :purpose) == :verification

                   assert {:error, %Error{code: :backup_invalid}} =
                            KnowledgePreflight.begin_restore(MigrationRepo, staged)

                   assert {:error, %Error{code: :backup_invalid}} =
                            KnowledgePreflight.validate_destination(MigrationRepo, staged)

                   assert [[0]] == rows("SELECT count(*) FROM audit.knowledge_restore_admissions")
                   assert [[0]] == rows("SELECT count(*) FROM audit.restore_import_sagas")

                   assert {:ok, %{count: 114, ordinals: ordinals}} =
                            native_reduce(staged, %{count: 0, ordinals: MapSet.new()}, fn schema,
                                                                                          values,
                                                                                          acc ->
                              assert length(values) == length(schema.columns)

                              for {column, value} <- Enum.zip(schema.columns, values),
                                  value != nil do
                                case column.tag do
                                  "uuid" -> assert is_binary(value) and byte_size(value) == 16
                                  "timestamp" -> assert %DateTime{} = value
                                  "json" -> assert is_binary(value)
                                  _other -> :ok
                                end
                              end

                              {:ok,
                               %{
                                 count: acc.count + 1,
                                 ordinals: MapSet.put(acc.ordinals, schema.ordinal)
                               }}
                            end)

                   expected_ordinals =
                     @counts
                     |> Enum.with_index()
                     |> Enum.reject(fn {count, _} -> count == 0 end)
                     |> Enum.map(&elem(&1, 1))
                     |> MapSet.new()

                   assert ordinals == expected_ordinals
                   :verified
                 end)
      end)

      assert Process.get({ReadOnlyStorage, destination.object_root, :write_hits}, 0) == 0
      assert_empty(destination.object_root, :absent)
    end)
  end

  test "native staged reducer rejects another caller before invoking its callback",
       %{source: source} do
    with_destination(source, fn destination ->
      authenticated(source, fn input ->
        assert {:ok, :rejected} =
                 owner(fn ->
                   staged = verification_stage(input, destination)
                   caller = self()

                   task =
                     Task.async(fn ->
                       native_reduce(staged, 0, fn _schema, _values, acc ->
                         send(caller, {:unexpected_native_callback, :wrong_caller})
                         {:ok, acc + 1}
                       end)
                     end)

                   assert {:error, %Error{code: :backup_invalid}} = Task.await(task)
                   refute_received {:unexpected_native_callback, :wrong_caller}
                   assert [[0]] == rows("SELECT count(*) FROM audit.knowledge_restore_admissions")
                   :rejected
                 end)
      end)

      assert_empty(destination.object_root, :absent)
    end)
  end

  test "native staged reducer rejects a later transaction before invoking its callback",
       %{source: source} do
    with_destination(source, fn destination ->
      staged =
        authenticated(source, fn input ->
          owner_value(fn -> verification_stage(input, destination) end)
        end)

      assert {:ok, :rejected} =
               owner(fn ->
                 caller = self()

                 assert {:error, %Error{code: :backup_invalid}} =
                          native_reduce(staged, 0, fn _schema, _values, acc ->
                            send(caller, {:unexpected_native_callback, :wrong_transaction})
                            {:ok, acc + 1}
                          end)

                 refute_received {:unexpected_native_callback, :wrong_transaction}
                 assert [[0]] == rows("SELECT count(*) FROM audit.knowledge_restore_admissions")
                 :rejected
               end)

      assert_empty(destination.object_root, :absent)
    end)
  end

  test "native staged reducer rejects a same-count temporary Note mutation before callback",
       %{source: source} do
    with_destination(source, fn destination ->
      authenticated(source, fn input ->
        assert {:ok, :rejected} =
                 owner(fn ->
                   staged = verification_stage(input, destination)

                   assert {:ok, %{ordinal: 28}} =
                            LogicalSchemaV3.fetch_table("content.note_versions")

                   assert [[6]] == rows("SELECT count(*) FROM pg_temp.knowledge_restore_28")

                   assert {:ok, before} =
                            KnowledgeRestoreDigest.table_digest(
                              MigrationRepo,
                              "content.note_versions",
                              :staged
                            )

                   assert %{num_rows: 1} =
                            sql(
                              "UPDATE pg_temp.knowledge_restore_28 SET title=title||'!' WHERE resource_version_id=$1",
                              [dump(@ids.initial_note_version_id)]
                            )

                   assert [[6]] == rows("SELECT count(*) FROM pg_temp.knowledge_restore_28")

                   assert {:ok, after_mutation} =
                            KnowledgeRestoreDigest.table_digest(
                              MigrationRepo,
                              "content.note_versions",
                              :staged
                            )

                   assert before.count == after_mutation.count
                   refute before.digest == after_mutation.digest
                   caller = self()

                   assert {:error, %Error{code: :backup_invalid}} =
                            native_reduce(staged, 0, fn _schema, _values, acc ->
                              send(caller, {:unexpected_native_callback, :staged_tamper})
                              {:ok, acc + 1}
                            end)

                   refute_received {:unexpected_native_callback, :staged_tamper}
                   assert [[0]] == rows("SELECT count(*) FROM audit.knowledge_restore_admissions")
                   :rejected
                 end)
      end)

      assert_empty(destination.object_root, :absent)
    end)
  end

  test "public V3 import preserves legal wire JSON whose typed native row expands beyond 16 MiB" do
    # Preparation and destination are sequential, never nested active repos.
    # This artifact has its own private root and cannot overwrite setup_all's
    # original complete-history bundle or its independently captured oracle.
    portable = Path.join(System.tmp_dir!(), "logical-v3-large-#{Ecto.UUID.generate()}")
    File.mkdir_p!(portable)
    File.chmod!(portable, 0o700)
    on_exit(fn -> File.rm_rf!(portable) end)
    source = prepare_source(portable, large_json: true)
    assert source.wire_length <= 16_777_216
    assert source.native_length > 16_777_216
    assert Enum.map(@tables, &source.expected.counts[&1]) == @counts
    assert map_size(source.expected.digests) == 38

    with_destination(source, fn destination ->
      assert_empty(destination.object_root, :absent)
      assert {:ok, %Restorer.Imported{}} = import_bundle(source, destination)
      assert_complete(source, destination)

      owner(fn ->
        assert [[16_767_216, 1000]] ==
                 rows(
                   "SELECT length(metadata->>'bulk'),jsonb_array_length(metadata->'numbers') FROM identity.people"
                 )
      end)
    end)
  end

  test "native outbox replay follows UUID primary-key order rather than historical sequence order" do
    portable = Path.join(System.tmp_dir!(), "logical-v3-native-pk-#{Ecto.UUID.generate()}")
    File.mkdir_p!(portable)
    File.chmod!(portable, 0o700)
    on_exit(fn -> File.rm_rf!(portable) end)
    source = prepare_native_pk_source(portable)
    assert source.outbox == [[id(699), 2], [id(700), 1]]

    KnowledgeBackupFixtures.with_destination(:current, fn destination ->
      refute destination.database == source.database
      assert_empty(destination.object_root, :absent)

      authenticated(source, fn input ->
        assert {:ok, :ordered} =
                 owner(fn ->
                   staged = verification_stage(input, destination)
                   assert [[2]] == rows("SELECT count(*) FROM pg_temp.knowledge_restore_24")

                   assert {:ok, emitted} =
                            native_reduce(staged, [], fn schema, values, acc ->
                              if schema.table == "core.outbox_events" do
                                assert schema.ordinal == 24
                                assert schema.primary_key == [%{position: 0, tag: "uuid"}]
                                [native_id, sequence | _columns] = values
                                {:ok, acc ++ [[Ecto.UUID.load!(native_id), sequence]]}
                              else
                                {:ok, acc}
                              end
                            end)

                   assert length(emitted) == 2
                   assert emitted == source.outbox
                   :ordered
                 end)
      end)

      assert Process.get({ReadOnlyStorage, destination.object_root, :write_hits}, 0) == 0
      assert_empty(destination.object_root, :absent)
    end)
  end

  defp prepare_native_pk_source(portable) do
    KnowledgeBackupFixtures.with_destination(:current, fn destination ->
      fixture =
        KnowledgeBackupFixtures.seed!(Map.merge(destination, %{ids: @ids, originals: @originals}))

      assert {:ok, %{ordinal: 24} = schema} = LogicalSchemaV3.fetch_table("core.outbox_events")
      # Preserve the current extracting job at sequence1. The new, undispatched
      # request uses valid generation equality1 and its native idempotency key;
      # no submission is fabricated and sequence2 is allocated normally.
      columns = Enum.map(schema.columns, & &1.name) -- ["sequence"]

      projection =
        Enum.map_join(columns, ",", fn
          "id" -> "$1::uuid"
          "idempotency_key" -> "$2::text"
          "expected_entity_revision" -> "1::bigint"
          name -> name
        end)

      owner(fn ->
        assert [[id(700), 1, 0]] ==
                 rows("SELECT id::text,sequence,expected_entity_revision FROM core.outbox_events")

        assert [[id(699), 2]] ==
                 rows(
                   "INSERT INTO core.outbox_events(#{Enum.join(columns, ",")}) SELECT #{projection} FROM core.outbox_events WHERE id=$3 RETURNING id::text,sequence",
                   [
                     dump(id(699)),
                     "document-extraction:#{@ids.extracting_version_id}:1",
                     dump(id(700))
                   ]
                 )
      end)

      outbox =
        owner_value(fn ->
          assert [[2]] == rows("SELECT count(*) FROM core.outbox_events")
          assert [[1]] == rows("SELECT count(*) FROM jobs.job_submissions")

          assert [[true], [true]] ==
                   rows(
                     "SELECT audit.knowledge_restore_payload_is_valid(e) FROM core.outbox_events e ORDER BY id"
                   )

          assert [[id(700)]] ==
                   rows(
                     "SELECT attempt_job_id::text FROM content.document_versions WHERE resource_version_id=$1",
                     [dump(@ids.extracting_version_id)]
                   )

          rows("SELECT id::text,sequence FROM core.outbox_events ORDER BY id")
        end)

      assert outbox == [[id(699), 2], [id(700), 1]]
      actual = KnowledgeBackupFixtures.canonical_rows(fixture)
      counts = List.replace_at(@counts, 24, 2)
      assert Enum.map(@tables, &length(actual[&1])) == counts
      assert Enum.sum(counts) == 115
      # The frozen wire verifier requires ascending outbox sequence. Only wire
      # ordering changes; every value remains the committed source-A value.
      assert {:ok, bundle} =
               KnowledgeBackupFixtures.transformed_bundle(fixture,
                 rows:
                   &Map.update!(&1, "core.outbox_events", fn events ->
                     Enum.sort_by(events, fn event -> event["sequence"] end)
                   end)
               )

      source = portable_bundle(bundle, destination, portable)
      BundleReader.discard_verified(bundle.verified)
      Map.merge(source, %{database: destination.database, outbox: outbox})
    end)
  end

  defp verification_stage(input, destination) do
    storage = %{module: ReadOnlyStorage, context: %{root: destination.object_root}}

    assert {:ok, staged} =
             apply(KnowledgePreflight, :stage_for_verification, [
               MigrationRepo,
               input.verified,
               input.cut,
               storage
             ])

    assert {:ok, _summary} = KnowledgePreflight.validate(MigrationRepo, staged, input.cut)
    staged
  end

  defp native_reduce(staged, accumulator, callback),
    do:
      apply(KnowledgePreflight, :reduce_native_rows, [
        MigrationRepo,
        staged,
        accumulator,
        callback
      ])

  defp prepare_source(portable, options \\ []) do
    KnowledgeBackupFixtures.with_destination(:current, fn destination ->
      fixture =
        KnowledgeBackupFixtures.seed!(Map.merge(destination, %{ids: @ids, originals: @originals}))

      if algorithm = Keyword.get(options, :vault_algorithm) do
        owner(fn ->
          assert %{num_rows: 1} =
                   sql("UPDATE core.vault_key_versions SET algorithm=$1", [algorithm])
        end)
      end

      large? = Keyword.get(options, :large_json, false)

      if large? do
        # Accepted Task4 literal: valid wire framing is smaller than native
        # typed JSON framing. These are genuine committed source-A rows.
        metadata = %{
          "bulk" => String.duplicate("x", 16_777_216 - 10_000),
          "numbers" => List.duplicate(1, 1000)
        }

        owner(fn ->
          assert %{num_rows: 1} =
                   sql("UPDATE identity.people SET metadata=($1::text)::jsonb", [
                     Jason.encode!(metadata)
                   ])
        end)
      end

      source_rows = KnowledgeBackupFixtures.canonical_rows(fixture)
      assert Enum.map(@tables, &length(source_rows[&1])) == @counts
      assert Enum.sum(@counts) == 114
      assert LogicalSchemaV3.tables() == @tables
      assert length(@excluded) == 12

      mode = if large?, do: :records, else: :replay
      bundle = KnowledgeBackupFixtures.verified_bundle(fixture, logical_version: 3, mode: mode)

      wire_length =
        if large? do
          [_cut, record | _tail] = bundle.verified.records

          assert {:ok, %{table: "identity.people"}} =
                   LogicalRecordCodec.decode(record.type, record.payload)

          assert byte_size(record.payload) <= 16_777_216
          byte_size(record.payload)
        end

      source = portable_bundle(bundle, destination, portable)
      assert Bitwise.band(File.stat!(portable).mode, 0o777) == 0o700
      assert Bitwise.band(File.stat!(Path.join(portable, source.filename)).mode, 0o777) == 0o600
      BundleReader.discard_verified(bundle.verified)

      # A second genuine encrypted bundle carries another authenticated
      # snapshot/manifest. Only disposable wire input is transformed.
      alternate = if large?, do: nil, else: alternate_source(source, portable)

      staging_root = Path.join(destination.object_root, "source-oracle-stages")
      File.mkdir_p!(staging_root)
      File.chmod!(staging_root, 0o700)
      storage = %{module: LocalFilesystemAdapter, context: %{root: staging_root}}

      summary =
        authenticated(source, fn input ->
          assert {:error, {:oracle, summary}} =
                   owner(fn ->
                     assert {:ok, summary} =
                              Restorer.preflight_knowledge(
                                %{object_storage: {LocalFilesystemAdapter, storage.context}},
                                MigrationRepo,
                                input
                              )

                     MigrationRepo.rollback({:oracle, summary})
                   end)

          summary
        end)

      abort_stages(storage.context)

      expected =
        authenticated(source, fn input ->
          assert {:error, {:oracle, expected}} =
                   owner(fn ->
                     assert {:ok, staged} =
                              KnowledgePreflight.stage(
                                MigrationRepo,
                                input.verified,
                                input.cut,
                                storage
                              )

                     assert {:ok, ^summary} =
                              KnowledgePreflight.validate(MigrationRepo, staged, input.cut)

                     native_length =
                       if large? do
                         assert {:ok, statement} =
                                  KnowledgeRestoreDigest.row_chunks_sql(
                                    "identity.people",
                                    :staged
                                  )

                         assert [[length]] =
                                  rows(
                                    "SELECT max(row_length) FROM (#{statement}) AS encoded(row_length,byte_offset,bytes)"
                                  )

                         assert length > 16_777_216
                         length
                       end

                     expected =
                       Enum.reduce(@tables, %{counts: %{}, digests: %{}}, fn table, acc ->
                         assert {:ok, %{count: count, digest: digest}} =
                                  KnowledgeRestoreDigest.destination_table_digest(
                                    MigrationRepo,
                                    table
                                  )

                         %{
                           counts: Map.put(acc.counts, table, count),
                           digests: Map.put(acc.digests, table, digest)
                         }
                       end)

                     MigrationRepo.rollback(
                       {:oracle, Map.put(expected, :native_length, native_length)}
                     )
                   end)

          expected
        end)

      abort_stages(storage.context)
      assert regular_files(staging_root) == []
      assert Enum.map(@tables, &expected.counts[&1]) == @counts
      assert map_size(expected.digests) == 38

      for table <- @tables -- ["core.vaults"],
          do: assert(expected.digests[table] == summary.digests[table])

      seals = owner_value(&seal_rows/0)
      assert length(seals) == 6

      assert Enum.map(seals, &Enum.take(&1, -2)) == [
               [0, 0],
               [1, 0],
               [0, 1],
               [1, 1],
               [1, 0],
               [1, 1]
             ]

      ciphertexts =
        Map.new(source_rows["content.asset_objects"], fn object ->
          path = object_path(destination.object_root, object)
          {object["id"], File.read!(path)}
        end)

      assert map_size(ciphertexts) == 5

      Map.merge(source, %{
        database: destination.database,
        rows: source_rows,
        expected: expected,
        seals: seals,
        ciphertexts: ciphertexts,
        sources: fixture.sources,
        alternate: alternate,
        wire_length: wire_length,
        native_length: expected.native_length
      })
    end)
  end

  defp portable_bundle(bundle, destination, portable) do
    filename = bundle.binding.destination_ref
    File.cp!(Path.join(destination.object_root, filename), Path.join(portable, filename))
    File.chmod!(Path.join(portable, filename), 0o600)

    %{
      portable: portable,
      filename: filename,
      binding: bundle.binding,
      crypto: fixture_context(bundle.binding.vault_id, bundle.binding.manifest_id),
      mode: :replay
    }
  end

  defp alternate_source(source, portable) do
    {:ok, reader} =
      LocalDestination.reader_source(%{backup_root: source.portable}, source.filename)

    assert {:ok, verified} =
             BundleReader.authenticate_all(reader, crypto: {FixtureCrypto, source.crypto})

    alternate_id = id(990)
    [cut_record | tail] = verified.records

    {label, version, _old_manifest, vault, snapshot_id, snapshot, high_water, counts, objects} =
      :erlang.binary_to_term(cut_record.payload, [:safe])

    cut = %{
      cut_record
      | payload:
          :erlang.term_to_binary(
            {label, version, alternate_id, vault, snapshot_id, snapshot, high_water, counts,
             objects},
            [:deterministic]
          )
    }

    recovery = put_in(verified.manifest.recovery, ["binding", "manifest_id"], alternate_id)
    records = [cut | tail]

    manifest = %{
      verified.manifest
      | manifest_id: alternate_id,
        recovery: recovery,
        inventory: inventory(records)
    }

    binding = %{
      source.binding
      | manifest_id: alternate_id,
        recovery: recovery,
        destination_ref: "alternate.backup"
    }

    encode_portable(portable, binding, records, manifest)
  end

  defp prepare_v2(portable) do
    bundle =
      KnowledgeBackupFixtures.verified_bundle(:legacy_v2, logical_version: 2, mode: :records)

    binding = %{bundle.binding | destination_ref: "legacy-v2.backup"}
    encode_portable(portable, binding, bundle.verified.records, bundle.verified.manifest)
  end

  defp encode_portable(portable, binding, records, manifest) do
    assert {:ok, encoded_manifest} = Manifest.encode(manifest)

    plaintext =
      Enum.map(records ++ [%{type: 0xFFFF, payload: encoded_manifest}], fn record ->
        <<record.type::16, byte_size(record.payload)::64, record.payload::binary>>
      end)
      |> IO.iodata_to_binary()

    crypto = fixture_context(binding.vault_id, binding.manifest_id)
    assert {:ok, ciphertext} = ChunkedAEAD.encode(Map.put(crypto, :plaintext, plaintext))

    header =
      :erlang.term_to_binary(%{version: 1, manifest_id: binding.manifest_id}, [:deterministic])

    encoded =
      <<"SINGULARITY-BACKUP", 1::16, byte_size(header)::32, header::binary, ciphertext::binary>>

    File.write!(Path.join(portable, binding.destination_ref), encoded, [:binary, :exclusive])
    File.chmod!(Path.join(portable, binding.destination_ref), 0o600)

    %{
      portable: portable,
      filename: binding.destination_ref,
      binding: binding,
      crypto: crypto,
      mode: :replay
    }
  end

  defp inventory(records),
    do:
      Enum.map(Enum.with_index(records), fn {record, index} ->
        %{
          position: index,
          record_type: record.type,
          payload_length: byte_size(record.payload),
          sha256: :crypto.hash(:sha256, record.payload)
        }
      end)

  defp fixture_context(vault, manifest),
    do: %{
      key: :crypto.hash(:sha256, "knowledge-fixture-backup-key"),
      vault_id: vault,
      encryption_domain_id: id(902),
      object_id: manifest,
      chunk_index: 0,
      algorithm: Format.algorithm(),
      format_version: Format.format_version(),
      chunk_size: Format.chunk_size()
    }

  defp golden_source do
    path = Path.expand("../../../fixtures/backup/logical-v1-pre-notes.backup", __DIR__)
    assert Base.encode16(:crypto.hash(:sha256, File.read!(path)), case: :lower) == @golden_sha

    assert {:ok, reader} =
             LocalDestination.reader_source(
               %{backup_root: Path.dirname(path)},
               Path.basename(path)
             )

    assert {:ok, public} = BundleReader.read_public_header(reader)
    assert {:ok, salt} = Base.decode64(public.kdf["salt"])
    parameters = public.kdf["parameters"]

    assert {:ok, key} =
             Argon2KeyDeriver.derive("singularity-v1-compatibility-passphrase", salt, %{
               version: parameters["version"],
               t_cost: parameters["t_cost"],
               m_cost: parameters["m_cost"],
               parallelism: parameters["parallelism"]
             })

    crypto = %{
      fixture_context(public.vault_id, public.manifest_id)
      | key: key,
        encryption_domain_id: "9c22b7fa-ff48-4ee2-a49a-d23464393618"
    }

    assert {:ok, verified} =
             BundleReader.authenticate_all(reader, crypto: {FixtureCrypto, crypto})

    binding = %{
      manifest_id: public.manifest_id,
      vault_id: public.vault_id,
      recovery: verified.manifest.recovery,
      destination_ref: Path.basename(path)
    }

    %{
      portable: Path.dirname(path),
      filename: Path.basename(path),
      binding: binding,
      crypto: crypto,
      mode: :records
    }
  end

  defp with_destination(source, fun) do
    KnowledgeBackupFixtures.with_destination(:current, fn destination ->
      refute destination.database == source.database
      assert source.expected.counts |> Map.values() |> Enum.sum() == 114
      fun.(destination)
    end)
  end

  defp authenticated(source, fun) do
    assert {:ok, reader} =
             LocalDestination.reader_source(%{backup_root: source.portable}, source.filename)

    options = [crypto: {FixtureCrypto, source.crypto}]

    options =
      if source.mode == :replay,
        do: options ++ [verifier: {LogicalBundleVerifier, source.binding}],
        else: options

    assert {:ok, verified} = BundleReader.authenticate_all(reader, options)

    try do
      cut =
        if source.mode == :replay do
          assert %BundleReader.Verified{records: [], replay: %BundleReader.Replay{}, cut: cut} =
                   verified

          cut
        else
          assert {:ok, cut} = LogicalBundleVerifier.verify(verified, source.binding)
          cut
        end

      fun.(%{verified: verified, cut: cut, binding: source.binding})
    after
      BundleReader.discard_verified(verified)
    end
  end

  defp import_bundle(
         source,
         destination,
         adapter \\ LocalFilesystemAdapter,
         fault \\ nil,
         repo \\ MigrationRepo
       ) do
    context = %{root: destination.object_root}
    context = if fault, do: Map.put(context, :fault, fault), else: context

    result =
      authenticated(source, &Restorer.import(%{object_storage: {adapter, context}}, repo, &1))

    if adapter == ReadOnlyStorage,
      do: assert(Process.get({ReadOnlyStorage, context.root, :write_hits}, 0) == 0)

    result
  end

  defp assert_complete(source, destination) do
    owner(fn ->
      for {table, ordinal} <- Enum.with_index(@tables) do
        assert [[source.expected.counts[table], source.expected.digests[table]]] ==
                 rows("SELECT row_count,digest FROM audit.knowledge_restore_table_digest($1)", [
                   ordinal
                 ]),
               table
      end

      assert seal_rows() == source.seals
      assert [["imported"]] == rows("SELECT state FROM audit.restore_import_sagas")
      assert [["validated"]] == rows("SELECT state FROM audit.knowledge_restore_admissions")

      assert [[false]] ==
               rows("SELECT audit.knowledge_restore_is_bound($1)", [dump(@ids.vault_id)])

      assert_excluded()
      assert_transformations()

      assert [
               ["extracting"],
               ["failed"],
               ["pending"],
               ["ready"],
               ["ready"],
               ["ready"],
               ["unsupported"]
             ] == rows("SELECT state FROM content.document_versions ORDER BY state")

      assert [[@ids.ready_current_version_id]] ==
               rows("SELECT current_version_id::text FROM content.resources WHERE id=$1", [
                 dump(@ids.ready_document_id)
               ])

      assert [[@ids.merge_note_version_id]] ==
               rows("SELECT current_version_id::text FROM content.resources WHERE id=$1", [
                 dump(@ids.live_note_id)
               ])

      assert [["waiting_for_unlock", 1]] ==
               rows("SELECT state,checkpoint_version FROM jobs.job_progress")

      assert [["applied"]] == rows("SELECT result FROM jobs.effect_receipts")
    end)

    assert_objects(source, destination.object_root)
    assert {:ok, []} = LocalFilesystemAdapter.list_staged(%{root: destination.object_root})
  end

  defp assert_transformations do
    assert [[true, id(103)]] ==
             rows("SELECT locked,object_cleanup_principal_id::text FROM core.vaults")

    assert [[true]] ==
             rows(
               "SELECT c.verifier=s.dummy_verifier AND c.verifier_version=1 FROM identity.credentials c CROSS JOIN identity.security_settings s WHERE s.singleton"
             )

    assert [
             [
               1,
               "restore-pending",
               %{"state" => "restore_pending", "version" => 1},
               "restore_pending",
               "restore-pending"
             ]
           ] ==
             rows(
               "SELECT kdf_version,kdf_salt,kdf_parameters,wrapper_algorithm,wrapped_key FROM core.vault_key_wrappers"
             )

    assert [[last, true, high]] =
             rows(
               "SELECT last_value,is_called,(SELECT max(sequence) FROM core.outbox_events) FROM core.outbox_events_sequence_seq"
             )

    assert last >= high
  end

  defp assert_constraint_catalog do
    owner(fn ->
      catalog =
        rows(
          "SELECT conname::text,contype::text FROM pg_constraint WHERE connamespace='content'::regnamespace AND condeferrable ORDER BY conname"
        )

      assert Enum.map(catalog, &hd/1) == Enum.sort(@ordinary)
      assert Enum.count(catalog, &(List.last(&1) == "f")) == 19
      assert Enum.count(catalog, &(List.last(&1) == "t")) == 13
      refute "knowledge_restore_final_check" in @ordinary

      assert [[true, true]] ==
               rows(
                 "SELECT condeferrable,condeferred FROM pg_constraint WHERE connamespace='audit'::regnamespace AND conname='knowledge_restore_final_check'"
               )
    end)
  end

  defp assert_objects(source, root) do
    expected_paths =
      Enum.map(source.rows["content.asset_objects"], fn object ->
        path = object_path(root, object)
        ciphertext = source.ciphertexts[object["id"]]
        assert File.read!(path) == ciphertext
        assert byte_size(ciphertext) == object["ciphertext_byte_size"]
        assert :crypto.hash(:sha256, ciphertext) == object["ciphertext_hash"]
        path
      end)

    assert length(expected_paths) == 5
    assert regular_files(Path.join(root, "objects")) == Enum.sort(expected_paths)

    receipts =
      Enum.map(source.rows["content.asset_objects"], fn object ->
        assert {:ok, receipt} = PathGuard.finalization_receipt_path(root, object["id"])
        receipt
      end)

    assert regular_files(Path.join(root, "finalized")) == Enum.sort(receipts)
    assert length(regular_files(root)) == 10
  end

  defp object_path(root, object) do
    assert {:ok, path} =
             PathGuard.object_path(
               root,
               object["vault_id"],
               object["key_domain_id"],
               Base.encode16(object["lookup_digest"], case: :lower)
             )

    path
  end

  defp assert_empty(root, marker) do
    owner(fn ->
      for table <-
            @tables ++ ["content.note_source_set_seals", "audit.knowledge_restore_admissions"],
          do: assert([[0]] == rows("SELECT count(*) FROM #{table}"), table)

      assert_excluded()

      case marker do
        :absent -> assert [[0]] == rows("SELECT count(*) FROM audit.restore_import_sagas")
        :pending -> assert [["pending"]] == rows("SELECT state FROM audit.restore_import_sagas")
      end
    end)

    assert {:ok, []} = LocalFilesystemAdapter.list_staged(%{root: root})
    assert regular_files(root) == []
  end

  defp assert_pending_empty_graph do
    owner(fn ->
      for table <-
            @tables ++ ["content.note_source_set_seals", "audit.knowledge_restore_admissions"],
          do: assert([[0]] == rows("SELECT count(*) FROM #{table}"), table)

      assert [["pending"]] == rows("SELECT state FROM audit.restore_import_sagas")
      assert_excluded()
    end)
  end

  defp assert_excluded do
    for table <- @excluded do
      assert [[true]] == rows("SELECT to_regclass($1) IS NOT NULL", [table])
      assert [[0]] == rows("SELECT count(*) FROM #{table}"), table
    end

    case rows("SELECT to_regclass('content.knowledge_mutation_receipts')::text") do
      [[nil]] ->
        :absent

      [["content.knowledge_mutation_receipts"]] ->
        assert [[0]] == rows("SELECT count(*) FROM content.knowledge_mutation_receipts")
    end
  end

  defp with_sql_fault(kind, fun) do
    suffix = "t7_" <> String.replace(Ecto.UUID.generate(), "-", "")
    sequence = "audit.#{suffix}_hits"
    function = "audit.#{suffix}_fail"
    trigger = "#{suffix}_trigger"

    {table, event, guard} =
      case kind do
        :seal ->
          {"content.note_source_set_seals", "INSERT",
           "(SELECT count(*) FROM content.note_versions)=6 AND (SELECT count(*) FROM content.note_attachments)=4 AND (SELECT count(*) FROM content.note_citations)=3 AND (SELECT state FROM audit.knowledge_restore_admissions)='loading'"}

        :marker ->
          {"audit.restore_import_sagas", "UPDATE",
           "OLD.state='pending' AND NEW.state='imported' AND (SELECT count(*) FROM content.note_source_set_seals)=6 AND (SELECT state FROM audit.knowledge_restore_admissions)='validated'"}
      end

    guard =
      if kind == :marker do
        total = Enum.map_join(@tables, "+", &"(SELECT count(*) FROM #{&1})")
        guard <> " AND (#{total})=114"
      else
        guard
      end

    owner(fn ->
      sql("CREATE SEQUENCE #{sequence}")

      sql(
        "CREATE FUNCTION #{function}() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $fault$ BEGIN IF (#{guard}) IS NOT TRUE THEN RAISE EXCEPTION 'Task7 fault reached wrong phase'; END IF; PERFORM pg_catalog.nextval('#{sequence}'::regclass); RAISE EXCEPTION 'Task7 causal #{kind} fault'; END $fault$"
      )

      sql(
        "CREATE TRIGGER #{trigger} BEFORE #{event} ON #{table} FOR EACH ROW EXECUTE FUNCTION #{function}()"
      )
    end)

    try do
      fun.(fn ->
        owner_value(fn ->
          [[count, called]] = rows("SELECT last_value,is_called FROM #{sequence}")
          if called, do: count, else: 0
        end)
      end)
    after
      owner(fn ->
        sql("DROP TRIGGER #{trigger} ON #{table}")
        sql("DROP FUNCTION #{function}()")
        sql("DROP SEQUENCE #{sequence}")
      end)
    end
  end

  defp seal_rows,
    do:
      rows(
        "SELECT note_resource_version_id::text,note_resource_id::text,vault_id::text,classification,attachment_count,citation_count FROM content.note_source_set_seals ORDER BY note_resource_version_id"
      )

  defp fault_hits(destination, name),
    do: Process.get({FaultStorage, destination.object_root, name}, 0)

  defp snapshot(root),
    do: %{
      files: Enum.map(regular_files(root), &{&1, File.read!(&1)}),
      rows:
        owner_value(fn ->
          Enum.map(
            @tables ++
              [
                "content.note_source_set_seals",
                "audit.restore_import_sagas",
                "audit.knowledge_restore_admissions"
              ],
            fn table ->
              {table, rows("SELECT to_jsonb(t) FROM #{table} t ORDER BY to_jsonb(t)::text")}
            end
          )
        end)
    }

  defp regular_files(root),
    do:
      Path.wildcard(Path.join(root, "**/*"), match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.sort()

  defp abort_stages(context) do
    assert {:ok, stages} = LocalFilesystemAdapter.list_staged(context)
    for stage <- stages, do: assert(:ok == LocalFilesystemAdapter.abort_stage(context, stage))
    assert {:ok, []} = LocalFilesystemAdapter.list_staged(context)
  end

  defp owner(fun),
    do:
      MigrationRepo.transaction(fn ->
        sql("SET LOCAL ROLE singularity_table_owner")
        fun.()
      end)

  defp owner_value(fun) do
    assert {:ok, value} = owner(fun)
    value
  end

  defp sql(statement, params \\ []),
    do: Ecto.Adapters.SQL.query!(MigrationRepo, statement, params, log: false)

  defp rows(statement, params \\ []), do: sql(statement, params).rows
  defp dump(value), do: Ecto.UUID.dump!(value)
  defp id(n), do: "60000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")
end
