defmodule Singularity.Runtime.KnowledgeBackupRestoreLiveTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Singularity.Storage.Backup.{KnowledgeBackupFixtures, LogicalSchemaV2, LogicalSchemaV3}
  alias Singularity.Storage.Backup.KnowledgeCanonicalOracle, as: Canonical
  alias Singularity.Storage.{MigrationRepo, SafeSQL, ScopedRepo, WorkerRepo}
  alias Singularity.Runtime.{Api, KnowledgeBackupRestoreFixture, NativeAssetFixture}
  alias Singularity.Storage.Backup.KnowledgeFixtureResourceOwner, as: ResourceOwner
  alias Singularity.Runtime.{KnowledgeRestoreOracle, RestoreVault}
  alias Singularity.Runtime.RestoreIntegrityLease.PlaintextSummary

  @inventory_fields ~w(asset_object_id vault_id key_domain_id classification
    lookup_digest ciphertext_hash ciphertext_byte_size storage_ref inventory_position)a

  # SQL foundation only: this established static fixture does not qualify
  # native publication, native crypto, or a backup/import worker cut.
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

  test "canonical oracle owns the literal complete projection and primary keys" do
    projection = Canonical.projection()
    assert length(projection) == 38
    assert Enum.sum(for {_table, columns, _pk} <- projection, do: length(columns)) == 367
    assert elem(hd(projection), 0) == "identity.people"
    assert elem(Enum.at(projection, 29), 0) == "content.note_conflicts"
    assert elem(Enum.at(projection, 30), 0) == "content.document_versions"
    assert elem(List.last(projection), 0) == "content.relationships"
    assert length(Enum.uniq_by(projection, &elem(&1, 0))) == 38

    for {table, columns, pk} <- projection do
      assert pk != [], "missing literal primary key for #{table}"
      assert Enum.all?(pk, &(&1 in columns)), "unknown primary-key column in #{table}"
      assert Enum.uniq(columns) == columns, "duplicate wire column in #{table}"
    end

    # Registry calls belong only in this assertion, never in the SQL oracle.
    registry = fn schemas ->
      Enum.map(schemas, fn schema ->
        {schema.table, Enum.map(schema.columns, & &1.name),
         Enum.map(schema.primary_key, &Enum.fetch!(schema.columns, &1.position).name)}
      end)
    end

    assert Enum.take(projection, 30) == registry.(LogicalSchemaV2.all())
    assert projection == registry.(LogicalSchemaV3.all())
  end

  test "SQL foundation reads all scoped wire columns in literal primary-key order" do
    with_sql_foundation(fn fixture ->
      {before_role, _backend} = role_and_backend(MigrationRepo)

      owner_query(fn ->
        # The later sequence sorts first by UUID. This distinguishes the SQL
        # oracle's literal PK ordering from the backup wire's sequence order.
        query!(
          """
          INSERT INTO core.outbox_events(id,event_type,idempotency_key,vault_id,principal_id,
            required_capability,principal_authorization_epoch,vault_authorization_epoch,
            classification,correlation_id,expected_entity_revision,envelope_version,payload,occurred_at)
          SELECT $1,event_type,idempotency_key || ':sql-foundation',vault_id,principal_id,
            required_capability,principal_authorization_epoch,vault_authorization_epoch,
            classification,correlation_id,expected_entity_revision,envelope_version,payload,occurred_at
          FROM core.outbox_events WHERE vault_id=$2 ORDER BY sequence LIMIT 1
          """,
          ["40000000-0000-4000-8000-000000000001", fixture.owner.vault_id]
        )
      end)

      cut = owner_query(fn -> cut!(MigrationRepo, fixture.owner) end)
      rows = Canonical.read_committed!(MigrationRepo, fixture.owner, cut)
      assert elem(role_and_backend(MigrationRepo), 0) == before_role

      expected_tables = Canonical.projection() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      assert Enum.sort(Map.keys(rows)) == expected_tables

      for {table, columns, pk} <- Canonical.projection() do
        table_rows = Map.fetch!(rows, table)
        complete? = Enum.all?(table_rows, &(Enum.sort(Map.keys(&1)) == Enum.sort(columns)))
        assert complete?, "incomplete canonical row in #{table}"
        keys = Enum.map(table_rows, &Enum.map(pk, fn column -> Map.fetch!(&1, column) end))
        assert keys == Enum.sort(keys), "noncanonical primary-key order in #{table}"
      end

      assert length(rows["identity.people"]) == 1
      assert Enum.map(rows["identity.accounts"], & &1["id"]) == [fixture.owner.account_id]
      assert Enum.map(rows["core.vaults"], & &1["id"]) == [fixture.owner.vault_id]
      assert length(rows["content.document_versions"]) == 7
      assert length(rows["content.document_fragments"]) > 0
      outbox_sequences = Enum.map(rows["core.outbox_events"], & &1["sequence"])
      assert outbox_sequences == Enum.sort(outbox_sequences, :desc)

      again = Canonical.read_committed!(MigrationRepo, fixture.owner, cut)
      assert :ok = Canonical.compare(rows, again)

      earlier = %{cut | outbox_high_water_mark: cut.outbox_high_water_mark - 1}
      previous_rows = Canonical.read_committed!(MigrationRepo, fixture.owner, earlier)
      assert length(rows["core.outbox_events"]) == length(previous_rows["core.outbox_events"]) + 1

      assert {:error, {:canonical_mismatch, ["core.outbox_events"]}} =
               Canonical.compare(rows, previous_rows)
    end)
  end

  test "SQL foundation excludes foreign accounts, nonmember principals and inactive wrappers" do
    with_sql_foundation(fn fixture ->
      cut = owner_query(fn -> cut!(MigrationRepo, fixture.owner) end)
      before = Canonical.read_committed!(MigrationRepo, fixture.owner, cut)

      owner_query(fn ->
        seed_foreign_scope!(fixture.owner)
        seed_unselected_wrappers!(fixture.owner)
      end)

      after_rows = Canonical.read_committed!(MigrationRepo, fixture.owner, cut)

      # The retired version and in-scope membership are canonical. Neither its
      # wrapper nor another account's active wrapper belongs to this projection.
      before_versions = before["core.vault_key_versions"]

      selected_versions =
        Enum.reject(after_rows["core.vault_key_versions"], &(&1["id"] == id(910)))

      selected_members =
        Enum.reject(after_rows["core.vault_members"], &(&1["principal_id"] == id(902)))

      unchanged =
        after_rows
        |> Map.put("core.vault_key_versions", selected_versions)
        |> Map.put("core.vault_members", selected_members)

      assert :ok = Canonical.compare(before, unchanged)
      assert length(after_rows["core.vault_key_versions"]) == length(before_versions) + 1
      assert length(after_rows["core.vault_members"]) == length(before["core.vault_members"]) + 1

      foreign = %{account_id: id(901), principal_id: id(902), vault_id: id(903)}
      foreign_cut = owner_query(fn -> cut!(MigrationRepo, foreign) end)
      foreign_rows = Canonical.read_committed!(MigrationRepo, foreign, foreign_cut)
      assert Enum.map(foreign_rows["identity.people"], & &1["id"]) == [id(900)]
      assert Enum.map(foreign_rows["identity.accounts"], & &1["id"]) == [id(901)]
      assert Enum.map(foreign_rows["identity.credentials"], & &1["id"]) == [id(905)]
      assert Enum.map(foreign_rows["identity.principals"], & &1["id"]) == [id(902)]
      assert Enum.map(foreign_rows["core.capabilities"], & &1["id"]) == [id(904)]
      assert Enum.map(foreign_rows["identity.devices"], & &1["id"]) == [id(906)]
    end)
  end

  test "SQL foundation preserves text fragment IDs, bytea, JSON and both microsecond timestamp types" do
    KnowledgeBackupFixtures.with_destination(:current, fn _destination ->
      text_id = "0123456789abcdef"
      bytes = <<0, 255, 1, 254, 2, 253, 3, 252, 4, 251, 5, 250, 6, 249, 7, 248>>
      timestamp = ~U[2026-10-15 12:34:56.123456Z]
      naive = ~N[2026-10-15 12:34:56.654321]
      json = %{"nested" => [1, true, nil, %{"unicode" => "界🙂"}]}

      result =
        SafeSQL.query!(
          MigrationRepo,
          """
          SELECT $1::text AS id, $1::text AS fragment_id, $2::uuid AS resource_id,
            $3::bytea AS digest, $4::jsonb AS locator, $5::timestamptz AS inserted_at,
            $6::timestamp AS updated_at
          """,
          [text_id, Ecto.UUID.dump!(@ids.ready_document_id), bytes, json, timestamp, naive]
        )

      [row] = Canonical.normalize_rows("content.document_fragments", result)

      valid? =
        row == %{
          "id" => text_id,
          "fragment_id" => text_id,
          "resource_id" => @ids.ready_document_id,
          "digest" => bytes,
          "locator" => json,
          "inserted_at" => "2026-10-15T12:34:56.123456Z",
          "updated_at" => "2026-10-15T12:34:56.654321"
        }

      assert valid?, "PostgreSQL round-trip normalization changed a canonical value"

      [citation] = Canonical.normalize_rows("content.note_citations", result)
      assert citation["fragment_id"] == text_id
    end)
  end

  test "SQL foundation snapshot observer uses distinct backends and preserves the scoped worker" do
    with_sql_foundation(fn fixture ->
      # This invokes the real observer and real scoped SQL connection, but is
      # not an Exporter callback or native publication/import qualification.
      observation =
        ScopedRepo.transact(WorkerRepo, fixture.owner, [isolation: :repeatable_read], fn worker ->
          identity = role_and_backend(worker)
          cut = cut!(worker, fixture.owner)
          observation = Canonical.capture_worker_cut!(worker, fixture.owner, cut)
          assert role_and_backend(worker) == identity
          observation
        end)

      assert observation.worker_backend != observation.observer_backend
      assert observation.database == fixture.destination.database
      assert observation.snapshot == observation.cut.database_snapshot
      assert observation.worker_role == "singularity_worker"
      assert map_size(observation.rows) == 38

      committed = Canonical.read_committed!(MigrationRepo, fixture.owner, observation.cut)
      assert :ok = Canonical.compare(observation.rows, committed)
    end)
  end

  test "complete-row commitments detect every selected field and report table names only" do
    with_sql_foundation(fn fixture ->
      cut = owner_query(fn -> cut!(MigrationRepo, fixture.owner) end)
      rows = Canonical.read_committed!(MigrationRepo, fixture.owner, cut)
      commitments = Canonical.commitments(rows)
      assert map_size(commitments) == 38
      assert Enum.all?(Map.values(commitments), &(is_binary(&1) and byte_size(&1) == 32))

      for {table, table_rows} <- rows, row <- Enum.take(table_rows, 1), column <- Map.keys(row) do
        changed_row = Map.put(row, column, {:changed, column})
        changed = Map.put(rows, table, [changed_row | tl(table_rows)])

        assert {:error, {:canonical_mismatch, [^table]}} = Canonical.compare(rows, changed)
      end

      changed = Map.update!(rows, "content.note_versions", &Enum.drop(&1, 1))

      assert {:error, {:canonical_mismatch, ["content.note_versions"]}} =
               Canonical.compare(rows, changed)
    end)
  end

  for outcome <- [:return, :error, :throw] do
    @tag :tmp_dir
    test "owned native source and empty destination close and restore config on #{outcome}", %{
      tmp_dir: tmp_dir
    } do
      outcome = unquote(outcome)
      portable_root = Path.join(tmp_dir, "portable-#{Ecto.UUID.generate()}")
      sentinel = Path.join(tmp_dir, "active-installation-sentinel")
      File.mkdir!(portable_root)
      File.chmod!(portable_root, 0o700)
      File.write!(sentinel, "active installation remains unchanged")
      saved = fixture_configuration()
      reference = make_ref()

      try do
        run_fixture_outcome(outcome, fn ->
          KnowledgeBackupRestoreFixture.with_source(portable_root, fn fixture ->
            send(self(), {reference, :source, fixture.lifecycle})
            assert Process.alive?(fixture.infrastructure)
            assert fixture.repositories == NativeAssetFixture.repo_identities()
            assert fixture.session.unlocked?
            assert Application.fetch_env!(:singularity_runtime, :maintenance_mode) == false
            assert Application.fetch_env!(:singularity_runtime, :start_infrastructure) == true

            # Reject before another ResourceOwner can pause these live globals.
            assert_raise ArgumentError, "knowledge source resources are still live", fn ->
              KnowledgeBackupRestoreFixture.with_destination(fixture.lifecycle, fn _ ->
                flunk("live source admitted a destination callback")
              end)
            end

            assert fixture.repositories == NativeAssetFixture.repo_identities()
            finish_fixture_callback(outcome)
          end)
        end)

        assert_receive {^reference, :source, source}
        refute_receive {^reference, :source, _}
        assert_closed_lifecycle(source)
        same_configuration? = fixture_configuration() == saved
        assert same_configuration?, "source did not restore exact application settings"

        run_fixture_outcome(outcome, fn ->
          KnowledgeBackupRestoreFixture.with_destination(source, fn fixture ->
            send(self(), {reference, :destination, fixture.lifecycle})
            assert_closed_lifecycle(source)
            refute fixture.destination.database == source.database
            assert {:ok, []} = File.ls(fixture.destination.object_root)
            assert fixture.repositories == NativeAssetFixture.repo_identities()
            assert is_nil(fixture.infrastructure)
            assert is_nil(Process.whereis(Singularity.Runtime.KeyCustodian))
            assert is_nil(Process.whereis(Singularity.Runtime.OutboxDispatcher))
            assert is_nil(Oban.whereis(Singularity.Oban))
            assert Application.fetch_env!(:singularity_runtime, :maintenance_mode) == true
            assert Application.fetch_env!(:singularity_runtime, :start_infrastructure) == false

            %{rows: [[0, 0, 0]]} =
              NativeAssetFixture.observe!("""
              SELECT (SELECT count(*) FROM identity.accounts),
                (SELECT count(*) FROM core.vaults),
                (SELECT count(*) FROM content.resources)
              """)

            finish_fixture_callback(outcome)
          end)
        end)

        assert_receive {^reference, :destination, destination}
        refute_receive {^reference, :destination, _}
        assert_closed_lifecycle(destination)
        same_configuration? = fixture_configuration() == saved
        assert same_configuration?, "destination did not restore exact application settings"
        assert File.read!(sentinel) == "active installation remains unchanged"
        assert {:ok, []} = File.ls(portable_root)
      after
        File.rm!(sentinel)
        File.rmdir!(portable_root)
      end
    end
  end

  @tag :tmp_dir
  test "failed acquisition before infrastructure restores present and absent configuration", %{
    tmp_dir: tmp_dir
  } do
    portable_root = Path.join(tmp_dir, "portable-#{Ecto.UUID.generate()}")
    File.mkdir!(portable_root)
    File.chmod!(portable_root, 0o700)
    saved = fixture_configuration()
    reference = make_ref()
    caller = self()

    try do
      ResourceOwner.with_checkpoint(
        fn
          :ready, resources ->
            send(caller, {reference, resources.names, resources.repos})
            Application.put_env(:singularity_runtime, :knowledge_v3_test_observer, :interrupted)
            Application.delete_env(:singularity_runtime, :authorization_dependencies)
            raise "knowledge fixture acquisition interrupted"

          _stage, _resources ->
            :ok
        end,
        fn ->
          assert_raise RuntimeError, "knowledge fixture acquisition interrupted", fn ->
            KnowledgeBackupRestoreFixture.with_source(portable_root, fn _ ->
              flunk("failed acquisition called source callback")
            end)
          end
        end
      )

      assert_receive {^reference, names, repositories}
      refute File.exists?(names.storage_root)
      assert Enum.all?(repositories, fn {_repo, pid} -> not Process.alive?(pid) end)
      same_configuration? = fixture_configuration() == saved
      assert same_configuration?, "interrupted acquisition changed application settings"
    after
      File.rmdir!(portable_root)
    end
  end

  @tag :tmp_dir
  test "real backup worker invokes the V3 observer inside its unchanged repeatable-read cut", %{
    tmp_dir: tmp_dir
  } do
    portable_root = Path.join(tmp_dir, "portable-#{Ecto.UUID.generate()}")
    File.mkdir!(portable_root)
    File.chmod!(portable_root, 0o700)
    saved = fixture_configuration()

    try do
      lifecycle =
        KnowledgeBackupRestoreFixture.with_source(portable_root, fn fixture ->
          passphrase = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
          requested = take_ok!(Api.request_backup(fixture.session, passphrase), "backup request")
          operation_id = requested.operation_id
          NativeAssetFixture.dispatch!()
          assert %{failure: 0, success: 1} = Oban.drain_queue(Singularity.Oban, queue: :backup)
          status = take_ok!(Api.backup_status(fixture.session, operation_id), "backup status")
          assert status.operation_id == operation_id
          assert status.status == :sealed

          observed = fixture.snapshot_observation.()
          assert observed.count == 1
          observation = observed.observation
          observation_present? = is_map(observation)
          assert observation_present?, "real backup worker did not capture a snapshot"
          assert observation.worker_backend != observation.observer_backend
          assert observation.database == fixture.destination.database
          assert observation.worker_role == "singularity_worker"
          assert observation.snapshot == observation.cut.database_snapshot
          assert observation.cut.vault_id == fixture.session.vault_id

          assert KnowledgeBackupRestoreFixture.V3JobHandler.dependencies().exporter ==
                   KnowledgeBackupRestoreFixture.V3Exporter

          refute Map.has_key?(observation.cut, :manifest_id)
          assert map_size(observation.rows) == 38

          assert Enum.map(observation.rows["core.vaults"], & &1["id"]) ==
                   [fixture.session.vault_id]

          assert observation.rows["content.resources"] == []

          %{rows: [[snapshot_id, high_water, "sealed"]]} =
            NativeAssetFixture.observe!(
              """
              SELECT snapshot_id, outbox_high_water, status
              FROM audit.backup_manifests WHERE id=$1 AND vault_id=$2
              """,
              [Ecto.UUID.dump!(operation_id), Ecto.UUID.dump!(fixture.session.vault_id)]
            )

          assert Ecto.UUID.load!(snapshot_id) == observation.cut.snapshot_id
          assert high_water == observation.cut.outbox_high_water_mark
          assert fixture.repositories == NativeAssetFixture.repo_identities()
          fixture.lifecycle
        end)

      assert_closed_lifecycle(lifecycle)
      same_configuration? = fixture_configuration() == saved
      assert same_configuration?, "worker observation changed application settings"
    after
      File.rmdir!(portable_root)
    end
  end

  @tag :tmp_dir
  test "genuine UUID V3 backup retains the complete graph and document-only PDF originals", %{
    tmp_dir: tmp_dir
  } do
    portable_root = Path.join(tmp_dir, "portable-#{Ecto.UUID.generate()}")
    File.mkdir!(portable_root)
    File.chmod!(portable_root, 0o700)
    saved = fixture_configuration()

    source = KnowledgeBackupRestoreFixture.backup_source!(portable_root, :uuid)

    try do
      assert_closed_lifecycle(source.lifecycle)
      same_configuration? = fixture_configuration() == saved
      assert same_configuration?, "genuine publication did not restore application settings"
      assert source.reference_mode == :uuid
      assert source.default_backup_error == :backup_unsupported
      assert source.observation.worker_role == "singularity_worker"
      assert source.observation.worker_backend != source.observation.observer_backend
      assert source.observation.database == source.lifecycle.database
      assert source.observation.snapshot == source.observation.cut.database_snapshot
      assert source.manifest.snapshot_id == source.observation.cut.snapshot_id
      assert source.manifest.high_water == source.observation.cut.outbox_high_water_mark
      assert source.manifest.id == source.operation_id
      assert source.manifest.status == "sealed"

      %{type: :regular, mode: mode, size: size} = File.lstat!(source.bundle_path)
      assert Bitwise.band(mode, 0o777) == 0o600
      assert size > 0
      assert File.ls!(portable_root) == [source.destination_ref]
      assert source.destination_ref == source.operation_id <> ".bundle"
      assert Bitwise.band(File.lstat!(portable_root).mode, 0o777) == 0o700

      rows = source.observation.rows

      for {table, count} <- [
            {"content.resources", 14},
            {"content.resource_versions", 19},
            {"content.assets", 6},
            {"content.asset_objects", 5},
            {"content.source_references", 6},
            {"content.document_versions", 7},
            {"content.document_fragments", 6},
            {"content.document_import_receipts", 7},
            {"content.note_versions", 6},
            {"content.note_conflicts", 2},
            {"content.note_attachments", 4},
            {"content.note_citations", 3},
            {"content.tags", 1},
            {"content.resource_tags", 1},
            {"content.relationships", 1},
            {"content.tombstones", 2}
          ] do
        assert length(Map.fetch!(rows, table)) == count, "wrong native graph count for #{table}"
      end

      sources = source.sources
      assert map_size(sources) == 6
      pdf = "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n"

      exact_originals? =
        source.originals == %{
          pdf: pdf,
          pdf_duplicate: pdf,
          empty: "",
          plain: "plain original\r\nsecond line\n",
          unicode: <<0xEF, 0xBB, 0xBF, 0xE4, 0xB8, 0xAD>> <> "é\r\n",
          markdown: "# Original Markdown\r\n[source](https://example.test/)\n"
        }

      assert exact_originals?, "genuine publications did not retain the six exact input binaries"

      for field <- [:asset_id, :resource_id, :resource_version_id] do
        assert length(Enum.uniq(Enum.map(sources, fn {_name, item} -> item[field] end))) == 6
      end

      assert sources.pdf.object_id == sources.pdf_duplicate.object_id
      assert map_size(source.native_inventory) == 5
      assert length(source.observation.cut.object_inventory) == 5
      expected_objects = sources |> Map.values() |> MapSet.new(& &1.object_id)
      assert MapSet.new(Map.keys(source.native_inventory)) == expected_objects

      assert MapSet.new(source.observation.cut.object_inventory, & &1.asset_object_id) ==
               expected_objects

      for {name, descriptor} <- sources do
        bytes = Map.fetch!(source.originals, name)
        same_input? = descriptor.digest == :crypto.hash(:sha256, bytes)
        assert same_input?, "independent original digest differs"
        assert descriptor.byte_size == byte_size(bytes)
        object = Map.fetch!(source.native_inventory, descriptor.object_id)
        assert object["storage_ref"] == descriptor.object_id
        assert object["lifecycle"] == "available"
        assert object["format_version"] == 1
        assert object["plaintext_byte_size"] == byte_size(bytes)
      end

      ids = source.ids
      documents = Map.new(rows["content.document_versions"], &{&1["resource_version_id"], &1})

      expected_documents = [
        {ids.ready_old_version_id, ids.ready_document_id, :pdf, "ready"},
        {ids.ready_current_version_id, ids.ready_document_id, :pdf_duplicate, "ready"},
        {ids.deleted_document_version_id, ids.deleted_document_id, :pdf, "ready"},
        {ids.pending_version_id, ids.pending_document_id, :empty, "pending"},
        {ids.extracting_version_id, ids.extracting_document_id, :plain, "extracting"},
        {ids.failed_version_id, ids.failed_document_id, :unicode, "failed"},
        {ids.unsupported_version_id, ids.unsupported_document_id, :markdown, "unsupported"}
      ]

      assert MapSet.new(Map.keys(documents)) == MapSet.new(expected_documents, &elem(&1, 0))

      for {version, resource, name, state} <- expected_documents do
        document = Map.fetch!(documents, version)
        descriptor = Map.fetch!(sources, name)
        assert document["resource_id"] == resource
        assert document["state"] == state
        assert document["source_asset_id"] == descriptor.asset_id
        assert document["source_resource_id"] == descriptor.resource_id
        assert document["source_resource_version_id"] == descriptor.resource_version_id
        assert document["source_object_id"] == descriptor.object_id
        same_digest? = document["source_digest"] == descriptor.digest
        assert same_digest?, "document lost original-byte provenance"
        assert document["source_byte_size"] == descriptor.byte_size
      end

      resources = Map.new(rows["content.resources"], &{&1["id"], &1})
      assert resources[ids.live_note_id]["current_version_id"] == ids.merge_note_version_id

      assert resources[ids.ready_document_id]["current_version_id"] ==
               ids.ready_current_version_id

      expected_resources =
        MapSet.new(
          Enum.map(sources, fn {_name, item} -> item.resource_id end) ++
            [
              ids.live_note_id,
              ids.deleted_note_id,
              ids.ready_document_id,
              ids.deleted_document_id,
              ids.pending_document_id,
              ids.extracting_document_id,
              ids.failed_document_id,
              ids.unsupported_document_id
            ]
        )

      assert MapSet.new(Map.keys(resources)) == expected_resources
      notes = Map.new(rows["content.note_versions"], &{&1["resource_version_id"], &1})

      assert MapSet.new(Map.keys(notes)) ==
               MapSet.new([
                 ids.initial_note_version_id,
                 ids.canonical_note_version_id,
                 ids.competing_note_version_id,
                 ids.merge_note_version_id,
                 ids.open_competing_note_version_id,
                 ids.deleted_note_version_id
               ])

      assert notes[ids.merge_note_version_id]["parent_version_id"] ==
               ids.canonical_note_version_id

      assert notes[ids.merge_note_version_id]["merge_parent_version_id"] ==
               ids.competing_note_version_id

      assert notes[ids.open_competing_note_version_id]["parent_version_id"] ==
               ids.canonical_note_version_id

      assert MapSet.new(rows["content.note_conflicts"], fn row ->
               {row["id"], row["state"], row["canonical_version_id"], row["competing_version_id"],
                row["resolution_version_id"]}
             end) ==
               MapSet.new([
                 {ids.resolved_conflict_id, "resolved", ids.canonical_note_version_id,
                  ids.competing_note_version_id, ids.merge_note_version_id},
                 {ids.open_conflict_id, "open", ids.merge_note_version_id,
                  ids.open_competing_note_version_id, nil}
               ])

      assert MapSet.new(
               rows["content.note_attachments"],
               &{&1["note_resource_version_id"], &1["id"]}
             ) ==
               MapSet.new([
                 {ids.canonical_note_version_id, ids.attachment_id},
                 {ids.merge_note_version_id, ids.attachment_id},
                 {ids.open_competing_note_version_id, ids.attachment_id},
                 {ids.deleted_note_version_id, ids.deleted_attachment_id}
               ])

      assert MapSet.new(
               rows["content.note_citations"],
               &{&1["note_resource_version_id"], &1["id"]}
             ) ==
               MapSet.new([
                 {ids.competing_note_version_id, ids.citation_id},
                 {ids.merge_note_version_id, ids.citation_id},
                 {ids.deleted_note_version_id, ids.deleted_citation_id}
               ])

      fragments = Map.new(rows["content.document_fragments"], &{&1["id"], &1})

      for citation <- rows["content.note_citations"] do
        fragment = Map.fetch!(fragments, citation["fragment_id"])
        assert citation["source_resource_id"] == fragment["resource_id"]
        assert citation["source_resource_version_id"] == fragment["resource_version_id"]
        same_locator? = citation["locator"] == fragment["locator"]
        assert same_locator?, "citation lost its immutable fragment locator"
        same_fragment_digest? = fragment["digest"] == :crypto.hash(:sha256, fragment["text"])
        assert same_fragment_digest?, "immutable fragment digest changed"
      end

      assert MapSet.new(rows["content.document_import_receipts"], & &1["version_id"]) ==
               MapSet.new(Map.keys(documents))

      assert Enum.all?(rows["content.document_import_receipts"], &(&1["state"] == "completed"))

      organization? =
        match?(
          [%{"id" => tag, "display_value" => "Straße", "normalized_key" => "strasse"}]
          when tag == ids.tag_id,
          rows["content.tags"]
        ) and
          match?(
            [%{"resource_id" => note, "tag_id" => tag}]
            when note == ids.live_note_id and tag == ids.tag_id,
            rows["content.resource_tags"]
          ) and
          match?(
            [
              %{
                "id" => edge,
                "source_resource_id" => note,
                "target_resource_id" => document,
                "target_resource_version_id" => pin,
                "type" => "references"
              }
            ]
            when edge == ids.relationship_id and note == ids.live_note_id and
                   document == ids.ready_document_id and pin == ids.ready_old_version_id,
            rows["content.relationships"]
          )

      assert organization?, "native graph lost tag normalization or historical relationship pin"
      submissions = Enum.frequencies_by(rows["jobs.job_submissions"], & &1["job_type"])

      assert submissions == %{
               "asset_verify" => 6,
               "asset_finalize" => 6,
               "asset_metadata" => 2,
               "asset_cleanup" => 2,
               "document_extract" => 1,
               "backup" => 1
             }

      extracting = documents[ids.extracting_version_id]
      assert extracting["attempt_job_id"] == source.work.submission_id

      [work_submission] =
        Enum.filter(rows["jobs.job_submissions"], &(&1["id"] == source.work.submission_id))

      assert work_submission["outbox_event_id"] == source.work.submission_id

      [work_event] =
        Enum.filter(rows["core.outbox_events"], &(&1["id"] == source.work.submission_id))

      assert work_event["principal_authorization_epoch"] ==
               source.work.principal_authorization_epoch

      assert work_event["vault_authorization_epoch"] == source.work.vault_authorization_epoch

      for resource <- [
            sources.pdf.resource_id,
            sources.pdf_duplicate.resource_id,
            ids.deleted_note_id,
            ids.deleted_document_id
          ] do
        refute is_nil(resources[resource]["deleted_at"])
      end

      assert Map.new(source.source_set_seals, fn [version, attached, cited] ->
               {version, {attached, cited}}
             end) == %{
               ids.initial_note_version_id => {0, 0},
               ids.canonical_note_version_id => {1, 0},
               ids.competing_note_version_id => {0, 1},
               ids.merge_note_version_id => {1, 1},
               ids.open_competing_note_version_id => {1, 0},
               ids.deleted_note_version_id => {1, 1}
             }

      assert source.pdf_pin_count == 3
      assert source.live_pdf_asset_references == 0
      assert source.orphan_cleanup_events == 0
      assert source.bootstrap_hierarchy_unchanged?
      assert source.pdf_retention_unchanged?

      assert MapSet.new(rows["content.tombstones"], & &1["asset_id"]) ==
               MapSet.new([sources.pdf.asset_id, sources.pdf_duplicate.asset_id])

      assert Enum.all?(source.deletions, fn deletion ->
               deletion.pending_revision == deletion.before_revision + 1 and
                 deletion.deleted_revision == deletion.before_revision + 2 and
                 deletion.worker_effect_revision == deletion.deleted_revision and
                 deletion.cleanup_success == 1
             end)

      assert Enum.all?(rows["content.assets"], fn asset ->
               if asset["id"] in [sources.pdf.asset_id, sources.pdf_duplicate.asset_id],
                 do: asset["state"] == "deleted" and is_nil(asset["asset_object_id"]),
                 else: asset["state"] == "ready" and asset["state_revision"] == 5
             end)
    after
      File.rm!(source.bundle_path)
      File.rmdir!(portable_root)
    end
  end

  for changed_name? <- [false, true] do
    @tag :tmp_dir
    test "genuine UUID restore compares committed history and observes native originals (mutable mismatch: #{changed_name?})",
         %{tmp_dir: tmp_dir} do
      run_uuid_saga!(tmp_dir, unquote(changed_name?))
    end
  end

  for reference_mode <- [:canonical_compatibility, :mixed_compatibility] do
    @tag :tmp_dir
    test "historical #{reference_mode} source restores the complete native saga with preserved references",
         %{tmp_dir: tmp_dir} do
      run_uuid_saga!(tmp_dir, false, unquote(reference_mode))
    end
  end

  @tag :tmp_dir
  test "observer-wiring contract receives native Document verification arguments after the complete UUID saga",
       %{tmp_dir: tmp_dir} do
    run_uuid_saga!(tmp_dir, false, :uuid, true)
  end

  # BEGIN Task8 native denials and separately labelled adapter contracts.
  # BEGIN Task8 finalized-file fixture-port permission regression.
  @tag :tmp_dir
  test "fixture filesystem port, not crypto evidence: faults a real finalized 0400 file without changing its mode",
       %{tmp_dir: tmp_dir} do
    alias Singularity.Storage.Local.PathGuard

    portable_root = Path.join(tmp_dir, "portable-#{Ecto.UUID.generate()}")
    File.mkdir!(portable_root)
    File.chmod!(portable_root, 0o700)
    saved = fixture_configuration()

    try do
      lifecycle =
        KnowledgeBackupRestoreFixture.with_source(portable_root, fn fixture ->
          pdf = "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n"
          upload = NativeAssetFixture.upload!(fixture, "application/pdf", [pdf], "fault-port.pdf")
          NativeAssetFixture.verify_and_finalize!()

          %{
            rows: [
              [object, owner, domain, lookup, hash, size, storage_ref, "available", "finalized"]
            ]
          } =
            NativeAssetFixture.observe!(
              """
              SELECT o.id::text,o.vault_id::text,o.key_domain_id::text,o.lookup_digest,
                o.ciphertext_hash,o.ciphertext_byte_size,o.storage_ref,o.lifecycle,s.state
              FROM content.assets a
              JOIN content.asset_objects o ON o.id=a.asset_object_id AND o.vault_id=a.vault_id
              JOIN content.asset_stages s ON s.asset_id=a.id AND s.vault_id=a.vault_id
              WHERE a.id=$1 AND a.vault_id=$2
              """,
              [Ecto.UUID.dump!(upload.asset_id), Ecto.UUID.dump!(fixture.session.vault_id)]
            )

          entry = %{
            asset_object_id: object,
            vault_id: owner,
            key_domain_id: domain,
            lookup_digest: lookup,
            ciphertext_hash: hash,
            ciphertext_byte_size: size,
            storage_ref: storage_ref
          }

          {:ok, path} =
            PathGuard.object_path(
              fixture.destination.object_root,
              owner,
              domain,
              Base.encode16(lookup, case: :lower)
            )

          before_stat = File.lstat!(path)
          before_bytes = File.read!(path)
          assert Bitwise.band(before_stat.mode, 0o777) == 0o400
          assert :crypto.hash(:sha256, before_bytes) == hash
          assert byte_size(before_bytes) == size

          witness =
            KnowledgeRestoreOracle.mutate_ciphertext!(fixture.destination.object_root, entry)

          after_stat = File.lstat!(path)
          <<first, rest::binary>> = before_bytes
          expected = <<Bitwise.bxor(first, 1), rest::binary>>

          exact? =
            witness == %{
              before_sha256: hash,
              before_size: size,
              after_sha256: :crypto.hash(:sha256, expected),
              after_size: size
            } and
              File.read!(path) == expected and after_stat.mode == before_stat.mode and
              {after_stat.major_device, after_stat.minor_device, after_stat.inode} ==
                {before_stat.major_device, before_stat.minor_device, before_stat.inode}

          assert exact?,
                 "fault fixture did not preserve exact owned file identity and permissions"

          fixture.lifecycle
        end)

      assert_closed_lifecycle(lifecycle)
      same_configuration? = fixture_configuration() == saved
      assert same_configuration?, "fault fixture did not restore exact application settings"
      assert File.ls!(portable_root) == []
    after
      File.rmdir!(portable_root)
    end
  end

  # END Task8 finalized-file fixture-port permission regression.

  # BEGIN Task9 genuine native material rejection contracts.
  @tag :tmp_dir
  test "genuine native unsupported material format denies before the PDF reader opens storage",
       %{tmp_dir: tmp_dir} do
    run_native_material_denial!(tmp_dir, :unsupported_format)
  end

  @tag :tmp_dir
  test "genuine foreign ciphertext with matching authenticated evidence reaches native header denial",
       %{tmp_dir: tmp_dir} do
    run_native_material_denial!(tmp_dir, :foreign_header)
  end

  defp run_native_material_denial!(tmp_dir, fault) do
    portable_root = Path.join(tmp_dir, "material-#{Ecto.UUID.generate()}")
    File.mkdir!(portable_root)
    File.chmod!(portable_root, 0o700)
    saved = fixture_configuration()
    reference = make_ref()
    caller = self()

    record = fn event ->
      send(caller, {reference, :native_denial, event})
      :ok
    end

    try do
      donor =
        if fault == :foreign_header,
          do: KnowledgeBackupRestoreFixture.foreign_pdf_witness!(portable_root),
          else: :native

      if is_map(donor), do: assert_closed_lifecycle(donor.lifecycle)

      source =
        KnowledgeBackupRestoreFixture.backup_source!(portable_root, :uuid, :valid, donor)

      try do
        assert_closed_lifecycle(source.lifecycle)
        assert_native_denial_source!(source, :valid)
        source_configuration? = fixture_configuration() == saved
        assert source_configuration?, "native material source changed application settings"

        if fault == :foreign_header do
          composition = source.native_material_witness

          coherent? =
            composition.donor_identity == donor.identity and
              composition.before.sha256 != composition.after.sha256 and
              composition.after.sha256 == donor.ciphertext_sha256 and
              composition.before.byte_size == composition.after.byte_size and
              composition.after.byte_size == donor.ciphertext_byte_size and
              composition.before.physical == composition.after.physical and
              composition.before.mode == composition.after.mode and
              composition.before.mode == 0o100400 and
              source.owner.vault_id != donor.identity.vault_id and
              source.sources.pdf.object_id != donor.identity.object_id

          assert coherent?, "foreign composition did not retain genuine coherent owned evidence"
          assert_closed_lifecycle(donor.lifecycle)
        end

        lifecycle =
          KnowledgeBackupRestoreFixture.with_destination(source.lifecycle, fn fixture ->
            root = fixture.destination.object_root
            pdf = source.sources.pdf
            original = source.original_inventory
            projected = KnowledgeRestoreOracle.projected_inventory!(source)
            pdf_entry = Enum.find(projected, &(&1.asset_object_id == pdf.object_id))
            counter = :counters.new(1, [])
            new_password = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

            hooks = %{
              after_import: fn imported ->
                expected =
                  Map.update!(source.observation.rows, "core.vaults", fn rows ->
                    Enum.map(rows, &Map.put(&1, "locked", true))
                  end)

                observed = Canonical.read_committed!(MigrationRepo, source.owner, imported.cut)
                assert :ok = Canonical.compare(expected, observed)

                assert :ok =
                         KnowledgeRestoreOracle.assert_saga_commitment!(source, root, imported)

                assert_import_secrets_and_seals!(source)
                record.(:import)
              end,
              after_rewrap: fn rewrapped ->
                capability = rewrapped.integrity_capability
                monitor = Process.monitor(capability.lease)
                send(caller, {reference, :native_denial_capability, capability, monitor})
                assert_rewrapped_password!(source, new_password)

                assert :ok =
                         KnowledgeRestoreOracle.assert_saga_commitment!(source, root, rewrapped)

                same_inventory? = rewrapped.object_inventory == original
                assert same_inventory?, "native material rewrap changed original inventory"
                record.(:rewrap)
              end,
              after_complete: fn :ok -> record.(:restore_complete) end,
              before_documents: fn _, _, _ -> record.(:documents) end,
              before_rebuild: fn _ -> record.(:before_rebuild) end,
              after_rebuild: fn _ -> record.(:after_rebuild) end,
              reader_object_id: pdf.object_id,
              reader_observer: fn stage, observation -> record.({:reader, stage, observation}) end,
              native_lease_observer: fn stage, payload ->
                if stage == :entered do
                  canonical =
                    Canonical.read_committed!(MigrationRepo, source.owner, source.observation.cut)

                  files =
                    Map.new(
                      projected,
                      &{&1.asset_object_id, KnowledgeRestoreOracle.reference_witness!(root, &1)}
                    )

                  %{rows: seals} =
                    NativeAssetFixture.observe!(
                      """
                      SELECT note_resource_version_id::text,attachment_count,citation_count
                      FROM content.note_source_set_seals WHERE vault_id=$1 ORDER BY note_resource_version_id
                      """,
                      [Ecto.UUID.dump!(source.owner.vault_id)]
                    )

                  same_seals? = seals == source.source_set_seals

                  assert same_seals?,
                         "native material entry lost exact six committed source seals"

                  send(
                    caller,
                    {reference, :native_material_before,
                     %{canonical: canonical, files: files, seals: seals}}
                  )
                end

                if stage == :entered and fault == :unsupported_format do
                  assert :ok =
                           KnowledgeBackupRestoreFixture.set_object_format!(
                             source.owner,
                             pdf.object_id,
                             1,
                             2
                           )

                  record.(:format_changed)
                end

                record.({:lease, stage, payload})
              end,
              ciphertext_result_observer: fn result ->
                category =
                  KnowledgeBackupRestoreFixture.ObservedAuthenticator.return_category(result)

                record.({:ciphertext_return, category})
              end,
              inventory_observer: fn stage, payload ->
                case stage do
                  :authenticated ->
                    exact? =
                      payload.binding == %{
                        manifest_id: source.operation_id,
                        vault_id: source.owner.vault_id
                      } and
                        payload.cut.object_inventory == original and
                        payload.verified_cut == payload.cut

                    assert exact?, "native material authentication lost original inventory"
                    record.(:authenticated)

                  :saga_plaintext ->
                    exact? =
                      payload.inventory == original and payload.cut.object_inventory == original

                    assert exact?, "native material final audit lost original inventory"
                    record.(:final_cipher_enter)

                  :ciphertext ->
                    assert_native_denial_ciphertext!(source, root, payload)
                    :counters.add(counter, 1, 1)
                    record.({:ciphertext, :counters.get(counter, 1)})

                  :material ->
                    entry = payload.entry

                    format =
                      if fault == :unsupported_format and entry.asset_object_id == pdf.object_id,
                        do: 2,
                        else: 1

                    exact? =
                      entry == Enum.at(projected, entry.inventory_position) and
                        payload.format_version == format and
                        payload.material == %{
                          object_id: entry.asset_object_id,
                          vault_id: entry.vault_id,
                          key_domain_id: entry.key_domain_id,
                          classification: entry.classification,
                          lookup_digest: entry.lookup_digest,
                          ciphertext_hash: entry.ciphertext_hash,
                          ciphertext_byte_size: entry.ciphertext_byte_size,
                          vault_key_version_id: payload.binding.vault_key_version_id,
                          vault_key_generation: payload.binding.vault_key_generation
                        }

                    assert exact?,
                           "native material observation differs from actual positioned source"

                    record.({:material, entry.asset_object_id, format})

                  _ ->
                    :ok
                end
              end
            }

            Application.put_env(:singularity_runtime, :knowledge_v3_plaintext_observer, fn _ ->
              record.(:typed_summary)
            end)

            context =
              KnowledgeBackupRestoreFixture.restore_context(
                fixture.destination,
                portable_root,
                hooks,
                %{}
              )

            result =
              RestoreVault.run(context, %{
                source: source.destination_ref,
                passphrase: source.passphrase,
                new_password: new_password
              })

            {capability, monitor} =
              receive do
                {^reference, :native_denial_capability, capability, monitor} ->
                  {capability, monitor}
              after
                0 -> flunk("native material denial did not issue genuine integrity authority")
              end

            try do
              assert_native_denial_capability_closed!(capability, monitor)
              assert_native_denial_error!(result, :integrity_failure, false)
              events = native_denial_events(reference)
              material_entries = Enum.take(projected, pdf_entry.inventory_position + 1)

              expected_material =
                Enum.map(material_entries, fn entry ->
                  format =
                    if fault == :unsupported_format and entry.asset_object_id == pdf.object_id,
                      do: 2,
                      else: 1

                  {:material, entry.asset_object_id, format}
                end)

              expected =
                [
                  :authenticated,
                  :import,
                  :rewrap,
                  {:ciphertext, 1},
                  {:ciphertext_return, :ok},
                  :final_cipher_enter,
                  {:ciphertext, 2},
                  {:ciphertext_return, :ok}
                ] ++
                  if(fault == :unsupported_format, do: [:format_changed], else: []) ++
                  [{:lease, :entered, :ok}] ++
                  expected_material ++
                  native_material_reader_stages(fault, donor) ++
                  [{:lease, :returned, {:error, :integrity_failure, false}}]

              exact_stages? = events == expected

              assert exact_stages?,
                     "native material denial reached an unexpected or downstream stage"

              rows =
                Canonical.read_committed!(MigrationRepo, source.owner, source.observation.cut)

              before =
                receive do
                  {^reference, :native_material_before, snapshot} -> snapshot
                after
                  0 ->
                    flunk("native material denial did not capture its genuine reached boundary")
                end

              expected_canonical =
                if fault == :unsupported_format do
                  Map.update!(before.canonical, "content.asset_objects", fn objects ->
                    Enum.map(objects, fn row ->
                      if row["id"] == pdf.object_id,
                        do: Map.replace!(row, "format_version", 2),
                        else: row
                    end)
                  end)
                else
                  before.canonical
                end

              assert :ok = Canonical.compare(expected_canonical, rows)

              for table <- [
                    "content.asset_objects",
                    "content.asset_key_envelopes",
                    "content.document_versions"
                  ] do
                expected_rows =
                  if table == "content.asset_objects" and fault == :unsupported_format do
                    Enum.map(source.observation.rows[table], fn row ->
                      if row["id"] == pdf.object_id,
                        do: Map.replace!(row, "format_version", 2),
                        else: row
                    end)
                  else
                    source.observation.rows[table]
                  end

                unchanged? = rows[table] == expected_rows

                assert unchanged?,
                       "native material denial changed metadata beyond its owned format fault"
              end

              for entry <- projected do
                witness = KnowledgeRestoreOracle.reference_witness!(root, entry)
                bytes = witness.ciphertext

                coherent? =
                  witness == before.files[entry.asset_object_id] and
                    byte_size(bytes) == entry.ciphertext_byte_size and
                    :crypto.hash(:sha256, bytes) == entry.ciphertext_hash

                assert coherent?, "native material denial changed committed ciphertext evidence"

                if fault == :foreign_header and entry.asset_object_id == pdf.object_id do
                  same_donor? = bytes == donor.ciphertext

                  assert same_donor?,
                         "native foreign denial changed the genuinely published donor ciphertext"
                end
              end

              %{rows: after_seals} =
                NativeAssetFixture.observe!(
                  """
                  SELECT note_resource_version_id::text,attachment_count,citation_count
                  FROM content.note_source_set_seals WHERE vault_id=$1 ORDER BY note_resource_version_id
                  """,
                  [Ecto.UUID.dump!(source.owner.vault_id)]
                )

              same_seals? = after_seals == before.seals
              assert same_seals?, "native material denial changed committed source seals"

              # The actual login probe appends authentication audit/session evidence.
              # Compare every restore effect before this separate public-entry probe.
              assert_native_denial_unpublished!(source, new_password)
            after
              if Process.alive?(capability.lease) do
                assert :ok = Singularity.Runtime.RestoreIntegrityLease.revoke(capability)
                assert_native_denial_capability_closed!(capability, monitor)
              end

              Process.demonitor(monitor, [:flush])
            end

            fixture.lifecycle
          end)

        assert_closed_lifecycle(lifecycle)
        if is_map(donor), do: assert_closed_lifecycle(donor.lifecycle)
        same_configuration? = fixture_configuration() == saved
        assert same_configuration?, "native material denial did not restore application settings"
        assert File.ls!(portable_root) == [source.destination_ref]
      after
        File.rm!(source.bundle_path)
      end
    after
      File.rmdir!(portable_root)
    end
  end

  defp native_material_reader_stages(:unsupported_format, :native), do: []

  defp native_material_reader_stages(:foreign_header, donor) do
    [
      {:reader, :stat, %{byte_size: donor.ciphertext_byte_size, sha256: donor.ciphertext_sha256}},
      {:reader, :open, :ok},
      {:reader, :header, donor.header_identity}
    ]
  end

  # END Task9 genuine native material rejection contracts.

  @tag :tmp_dir
  test "genuine native wrong PDF size denies at Document verification after successful plaintext reads",
       %{tmp_dir: tmp_dir} do
    run_native_denial!(tmp_dir, :wrong_pdf_size)
  end

  @tag :tmp_dir
  test "genuine native wrong PDF source digest denies at Document verification after successful plaintext reads",
       %{tmp_dir: tmp_dir} do
    run_native_denial!(tmp_dir, :wrong_pdf_digest)
  end

  @tag :tmp_dir
  test "genuine native ciphertext mutation after early verification is denied by the final ciphertext auditor",
       %{tmp_dir: tmp_dir} do
    run_native_denial!(tmp_dir, :after_early_ciphertext)
  end

  @tag :tmp_dir
  test "genuine native ciphertext mutation after final verification is denied by the native read path",
       %{tmp_dir: tmp_dir} do
    run_native_denial!(tmp_dir, :after_final_ciphertext)
  end

  defp run_native_denial!(tmp_dir, fault) do
    portable_root = Path.join(tmp_dir, "portable-#{Ecto.UUID.generate()}")
    File.mkdir!(portable_root)
    File.chmod!(portable_root, 0o700)
    saved = fixture_configuration()
    metadata = if fault in [:wrong_pdf_size, :wrong_pdf_digest], do: fault, else: :valid
    reference = make_ref()
    caller = self()

    record = fn event ->
      send(caller, {reference, :native_denial, event})
      :ok
    end

    try do
      source = KnowledgeBackupRestoreFixture.backup_source!(portable_root, :uuid, metadata)

      try do
        assert_closed_lifecycle(source.lifecycle)
        assert_native_denial_source!(source, fault)
        source_configuration? = fixture_configuration() == saved
        assert source_configuration?, "native denial source changed application settings"

        lifecycle =
          KnowledgeBackupRestoreFixture.with_destination(source.lifecycle, fn fixture ->
            root = fixture.destination.object_root
            pdf = source.sources.pdf
            plaintext_size = byte_size(pdf.bytes)
            original = source.observation.cut.object_inventory
            pdf_entry = Enum.find(original, &(&1.asset_object_id == pdf.object_id))
            counter = :counters.new(1, [])
            new_password = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

            expected_binding = %{
              manifest_id: source.operation_id,
              vault_id: source.owner.vault_id
            }

            hooks = %{
              after_import: fn imported ->
                expected =
                  Map.update!(source.observation.rows, "core.vaults", fn rows ->
                    Enum.map(rows, &Map.put(&1, "locked", true))
                  end)

                observed = Canonical.read_committed!(MigrationRepo, source.owner, imported.cut)
                assert :ok = Canonical.compare(expected, observed)

                assert :ok =
                         KnowledgeRestoreOracle.assert_saga_commitment!(source, root, imported)

                same_cut? =
                  imported.cut.object_inventory == original and
                    imported.cut.snapshot_id == source.observation.cut.snapshot_id and
                    imported.manifest.manifest_id == source.operation_id

                assert same_cut?, "native denial import lost authenticated source identity"
                assert_import_secrets_and_seals!(source)
                record.(:import)
              end,
              after_rewrap: fn rewrapped ->
                capability = rewrapped.integrity_capability
                monitor = Process.monitor(capability.lease)
                send(caller, {reference, :native_denial_capability, capability, monitor})
                assert_rewrapped_password!(source, new_password)

                assert :ok =
                         KnowledgeRestoreOracle.assert_saga_commitment!(source, root, rewrapped)

                same_inventory? = rewrapped.object_inventory == original
                assert same_inventory?, "native denial rewrap changed original inventory"

                if fault == :wrong_pdf_size do
                  assert :ok =
                           KnowledgeBackupRestoreFixture.set_object_plaintext_size!(
                             source.owner,
                             pdf.object_id,
                             plaintext_size + 1,
                             plaintext_size
                           )
                end

                record.(:rewrap)
              end,
              after_complete: fn :ok -> record.(:restore_complete) end,
              before_documents: fn binding, inventory, hashes ->
                same_arguments? =
                  binding == expected_binding and inventory == original and
                    hashes == native_denial_expected_hashes(source)

                assert same_arguments?, "native Document callback lost actual source evidence"

                if fault == :wrong_pdf_size do
                  assert :ok =
                           KnowledgeBackupRestoreFixture.set_object_plaintext_size!(
                             source.owner,
                             pdf.object_id,
                             plaintext_size,
                             plaintext_size + 1
                           )
                end

                assert_native_denial_pdf_rows!(source, fault)

                expected_length? =
                  pdf_entry.ciphertext_byte_size == native_ciphertext_size(plaintext_size)

                assert expected_length?, "original inventory lost genuine ciphertext length"

                if fault == :wrong_pdf_size do
                  differs? =
                    pdf_entry.ciphertext_byte_size != native_ciphertext_size(plaintext_size + 1)

                  assert differs?, "wrong immutable PDF size did not contradict ciphertext length"
                end

                record.(:documents)
              end,
              before_rebuild: fn _binding -> record.(:before_rebuild) end,
              after_rebuild: fn _summary -> record.(:after_rebuild) end,
              native_lease_observer: fn stage, payload -> record.({:lease, stage, payload}) end,
              ciphertext_result_observer: fn result ->
                category =
                  KnowledgeBackupRestoreFixture.ObservedAuthenticator.return_category(result)

                if match?({:error, _}, result),
                  do: assert_native_denial_error!(result, :integrity_failure, false)

                record.({:ciphertext_return, category})
              end,
              inventory_observer: fn stage, payload ->
                case stage do
                  :authenticated ->
                    exact? =
                      payload.binding == expected_binding and
                        payload.cut.object_inventory == original and
                        payload.verified_cut == payload.cut

                    assert exact?, "native denial authentication changed original inventory"
                    record.(:authenticated)

                  :saga_plaintext ->
                    exact? =
                      payload.inventory == original and payload.cut.object_inventory == original

                    assert exact?, "native final verification changed original inventory"
                    record.(:final_cipher_enter)

                  :ciphertext ->
                    :ok = assert_native_denial_ciphertext!(source, root, payload)
                    :counters.add(counter, 1, 1)
                    ordinal = :counters.get(counter, 1)
                    record.({:ciphertext, ordinal})

                    if {fault, ordinal} in [
                         {:after_early_ciphertext, 1},
                         {:after_final_ciphertext, 2}
                       ] do
                      witness = KnowledgeRestoreOracle.mutate_ciphertext!(root, pdf_entry)

                      changed? =
                        witness.before_sha256 == pdf_entry.ciphertext_hash and
                          witness.before_size == pdf_entry.ciphertext_byte_size and
                          witness.after_size == witness.before_size and
                          witness.after_sha256 != witness.before_sha256

                      assert changed?,
                             "owned ciphertext mutation lacks physical before/after evidence"

                      record.(:mutated)
                    end

                    :ok

                  _stage ->
                    :ok
                end
              end
            }

            Application.put_env(
              :singularity_runtime,
              :knowledge_v3_plaintext_observer,
              fn summary ->
                assert_native_summary!(source, summary)
                record.(:typed_summary)
              end
            )

            context =
              KnowledgeBackupRestoreFixture.restore_context(
                fixture.destination,
                portable_root,
                hooks,
                %{}
              )

            result =
              RestoreVault.run(context, %{
                source: source.destination_ref,
                passphrase: source.passphrase,
                new_password: new_password
              })

            {capability, monitor} =
              receive do
                {^reference, :native_denial_capability, capability, monitor} ->
                  {capability, monitor}
              after
                0 -> flunk("native denial did not reach genuine integrity capability issuance")
              end

            try do
              assert_native_denial_capability_closed!(capability, monitor)
              expected_code = if metadata == :valid, do: :integrity_failure, else: :backup_invalid
              assert_native_denial_error!(result, expected_code, false)
              actual_events = native_denial_events(reference)
              exact_stages? = actual_events == native_denial_stages(fault)

              assert exact_stages?,
                     "native denial reached an unexpected stage or downstream boundary"

              assert_native_denial_unpublished!(source, new_password)

              rows =
                Canonical.read_committed!(MigrationRepo, source.owner, source.observation.cut)

              for table <- [
                    "content.asset_objects",
                    "content.asset_key_envelopes",
                    "content.document_versions"
                  ] do
                unchanged? = rows[table] == source.observation.rows[table]

                assert unchanged?,
                       "native denial changed retained object, envelope or immutable Document metadata"
              end
            after
              if Process.alive?(capability.lease) do
                assert :ok = Singularity.Runtime.RestoreIntegrityLease.revoke(capability)
                assert_native_denial_capability_closed!(capability, monitor)
              end

              Process.demonitor(monitor, [:flush])
            end

            fixture.lifecycle
          end)

        assert_closed_lifecycle(lifecycle)
        same_configuration? = fixture_configuration() == saved
        assert same_configuration?, "native denial did not restore exact application settings"
        assert File.ls!(portable_root) == [source.destination_ref]
      after
        File.rm!(source.bundle_path)
      end
    after
      File.rmdir!(portable_root)
    end
  end

  defp assert_native_denial_source!(source, fault) do
    pdf = source.sources.pdf
    size = byte_size(pdf.bytes)
    digest = :crypto.hash(:sha256, pdf.bytes)
    expected_size = if fault == :wrong_pdf_size, do: size + 1, else: size

    documents =
      Enum.filter(
        source.observation.rows["content.document_versions"],
        &(&1["source_object_id"] == pdf.object_id)
      )

    expected_versions =
      Enum.sort([
        source.ids.ready_old_version_id,
        source.ids.ready_current_version_id,
        source.ids.deleted_document_version_id
      ])

    exact? =
      source.reference_mode == :uuid and source.manifest.status == "sealed" and
        source.manifest.id == source.operation_id and map_size(source.observation.rows) == 38 and
        Enum.sort(Enum.map(documents, & &1["resource_version_id"])) == expected_versions and
        Enum.all?(
          documents,
          &(&1["source_byte_size"] == expected_size and &1["source_digest"] == pdf.digest)
        ) and
        source.native_inventory[pdf.object_id]["plaintext_byte_size"] == expected_size and
        source.sources.pdf_duplicate.object_id == pdf.object_id and
        source.sources.pdf_duplicate.byte_size == pdf.byte_size and
        source.sources.pdf_duplicate.digest == pdf.digest and pdf.byte_size == expected_size and
        source.pdf_retention_unchanged? and source.bootstrap_hierarchy_unchanged?

    assert exact?,
           "native denial source lacks coherent genuine publication and three immutable PDF pins"

    digest_composed? =
      if fault == :wrong_pdf_digest,
        do: is_binary(pdf.digest) and byte_size(pdf.digest) == 32 and pdf.digest != digest,
        else: pdf.digest == digest

    assert digest_composed?,
           "native denial source digest composition differs from its declared fault"
  end

  defp native_denial_expected_hashes(source) do
    bytes = source.sources |> Map.values() |> Map.new(&{&1.object_id, &1.bytes})

    Enum.map(source.observation.cut.object_inventory, fn entry ->
      %{
        asset_object_id: entry.asset_object_id,
        sha256: :crypto.hash(:sha256, Map.fetch!(bytes, entry.asset_object_id))
      }
    end)
  end

  defp assert_native_denial_pdf_rows!(source, fault) do
    pdf = source.sources.pdf
    size = byte_size(pdf.bytes) + if(fault == :wrong_pdf_size, do: 1, else: 0)

    %{rows: rows} =
      NativeAssetFixture.observe!(
        """
        SELECT d.resource_version_id::text,d.source_digest,d.source_byte_size,o.plaintext_byte_size
        FROM content.document_versions d JOIN content.asset_objects o
          ON o.id=d.source_object_id AND o.vault_id=d.vault_id
        WHERE d.vault_id=$1 AND d.source_object_id=$2 ORDER BY d.resource_version_id
        """,
        [Ecto.UUID.dump!(source.owner.vault_id), Ecto.UUID.dump!(pdf.object_id)]
      )

    versions =
      Enum.sort([
        source.ids.ready_old_version_id,
        source.ids.ready_current_version_id,
        source.ids.deleted_document_version_id
      ])

    same_rows? = rows == Enum.map(versions, &[&1, pdf.digest, size, size])
    assert same_rows?, "Document callback did not observe all three coherent immutable PDF pins"

    if fault == :wrong_pdf_digest do
      differs? = pdf.digest != :crypto.hash(:sha256, pdf.bytes)
      assert differs?, "wrong source digest did not contradict actual native plaintext"
    end
  end

  defp native_ciphertext_size(size), do: 66 + size + 24 * div(size + 4_194_303, 4_194_304) + 68

  defp assert_native_denial_ciphertext!(source, root, observation) do
    alias Singularity.Storage.Backup.IntegrityAudit, as: StorageAudit
    inventory = KnowledgeRestoreOracle.projected_inventory!(source)
    {:ok, digest} = StorageAudit.inventory_sha256(source.owner.vault_id, inventory)

    exact? =
      observation.storage == {Singularity.Storage.LocalFilesystemAdapter, %{root: root}} and
        observation.vault_id == source.owner.vault_id and observation.inventory == inventory and
        match?(%StorageAudit.CiphertextSummary{}, observation.summary) and
        observation.summary.vault_id == source.owner.vault_id and
        observation.summary.object_count == 5 and
        observation.summary.inventory_sha256 == digest and
        observation.summary.ciphertext_hashes ==
          Enum.map(inventory, &%{asset_object_id: &1.asset_object_id, sha256: &1.ciphertext_hash})

    assert exact?,
           "native ciphertext success lost its actual typed five-object inventory evidence"

    :ok
  end

  defp assert_native_denial_error!(result, code, retryable?) do
    exact? = result == {:error, Singularity.Core.Error.new(code, retryable?: retryable?)}

    assert exact?,
           "native denial changed the exact public error code, retryability or sanitized fields"
  end

  defp assert_native_denial_capability_closed!(capability, monitor) do
    closed? =
      receive do
        {:DOWN, ^monitor, :process, lease, :normal} when lease == capability.lease -> true
        {:DOWN, ^monitor, :process, _lease, _reason} -> false
      after
        1_000 -> false
      end

    assert closed?, "native denial integrity authority did not close normally"
    refute Process.alive?(capability.lease), "native denial retained live integrity authority"

    assert_native_denial_error!(
      Singularity.Runtime.RestoreIntegrityLease.verify_all(capability),
      :backup_invalid,
      false
    )

    assert :ok = Singularity.Runtime.RestoreIntegrityLease.revoke(capability)
    assert :ok = Singularity.Runtime.RestoreIntegrityLease.revoke(capability)
  end

  defp assert_native_denial_unpublished!(source, new_password) do
    withheld? =
      Application.fetch_env!(:singularity_runtime, :maintenance_mode) == true and
        Application.fetch_env!(:singularity_runtime, :start_infrastructure) == false and
        is_nil(Process.whereis(Singularity.Runtime.KeyCustodian)) and
        is_nil(Process.whereis(Singularity.Runtime.OutboxDispatcher)) and
        is_nil(Process.whereis(Singularity.Runtime.Documents.ExtractionReconciler)) and
        is_nil(Oban.whereis(Singularity.Oban))

    assert withheld?, "native denial activated ordinary runtime or dispatch outside maintenance"

    %{rows: rows} =
      NativeAssetFixture.observe!(
        """
        SELECT
          (SELECT count(*) FROM audit.events WHERE vault_id=$1 AND target_id=$2 AND operation='integrity.audit_completed'),
          (SELECT count(*) FROM audit.events WHERE vault_id=$1 AND target_id=$2 AND operation='backup.restore_completed'),
          (SELECT state FROM audit.restore_import_sagas WHERE singleton),
          (SELECT state FROM audit.knowledge_restore_admissions WHERE singleton),
          (SELECT locked FROM core.vaults WHERE id=$1),
          (SELECT count(*) FROM content.search_entries WHERE vault_id=$1),
          (SELECT count(*) FROM content.asset_search_documents WHERE vault_id=$1),
          (SELECT count(*) FROM content.note_search_documents WHERE vault_id=$1)
        """,
        [Ecto.UUID.dump!(source.owner.vault_id), Ecto.UUID.dump!(source.operation_id)]
      )

    unpublished? = rows == [[0, 0, "imported", "validated", true, 0, 0, 0]]
    assert unpublished?, "native denial published a search projection or persisted a completion"

    # The ordinary authenticated entry is unavailable in this withheld-runtime
    # composition. This does not claim a generic Api flag guard or a graph read.
    entry_unavailable? =
      Api.login(%{login: source.credentials.login, password: new_password, source: "127.0.0.1"}) ==
        {:error, :storage_unavailable}

    assert entry_unavailable?, "native denial exposed ordinary authenticated entry in maintenance"
  end

  defp native_denial_events(reference, events \\ []) do
    receive do
      {^reference, :native_denial, event} -> native_denial_events(reference, [event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp native_denial_stages(fault) do
    prefix = [:authenticated, :import, :rewrap, {:ciphertext, 1}]

    case fault do
      :after_early_ciphertext ->
        prefix ++
          [
            :mutated,
            {:ciphertext_return, :ok},
            :final_cipher_enter,
            {:ciphertext_return, {:error, :integrity_failure, false}}
          ]

      :after_final_ciphertext ->
        prefix ++
          [
            {:ciphertext_return, :ok},
            :final_cipher_enter,
            {:ciphertext, 2},
            :mutated,
            {:ciphertext_return, :ok},
            {:lease, :entered, :ok},
            {:lease, :returned, {:error, :integrity_failure, false}}
          ]

      metadata when metadata in [:wrong_pdf_size, :wrong_pdf_digest] ->
        prefix ++
          [
            {:ciphertext_return, :ok},
            :final_cipher_enter,
            {:ciphertext, 2},
            {:ciphertext_return, :ok},
            {:lease, :entered, :ok},
            :typed_summary,
            {:lease, :returned, :ok},
            :documents
          ]
    end
  end

  # These recording ports provide adapter-contract evidence only.
  defmodule ShapeLease do
    def verify_all(context, capability) do
      send(context.caller, {context.reference, :shape, :lease, capability == context.capability})
      {:ok, context.returned_plaintext}
    end

    def revoke(context, capability) do
      send(context.caller, {context.reference, :shape, :revoke, capability == context.capability})
      :ok
    end
  end

  defmodule ShapePorts do
    def verify_ciphertext(context, storage, owner, inventory) do
      record(
        context,
        :ciphertext,
        storage == context.storage and owner == context.binding.vault_id and
          inventory == context.inventory
      )

      {:ok, context.ciphertext}
    end

    def verify_document_sources(context, binding, inventory, hashes) do
      record(
        context,
        :documents,
        binding == context.binding and inventory == context.inventory and
          hashes == context.plaintext.plaintext_hashes
      )
    end

    def rebuild(context, binding) do
      record(context, :rebuild, binding == context.binding)
      {:ok, context.search}
    end

    def complete(context, command) do
      record(
        context,
        :complete,
        command.manifest_id == context.binding.manifest_id and
          command.vault_id == context.binding.vault_id and command.object_count == 2 and
          command.ciphertext_inventory_sha256 == context.ciphertext.inventory_sha256 and
          command.plaintext_inventory_sha256 == context.plaintext_digest and
          command.search_rebuild_sha256 == context.search.result_sha256
      )
    end

    defp record(context, stage, exact?) do
      send(context.caller, {context.reference, :shape, stage, exact?})
      :ok
    end
  end

  @tag :tmp_dir
  test "adapter contract, not native crypto evidence: typed plaintext summary matrix", %{
    tmp_dir: root
  } do
    mutations = [
      :valid,
      :missing,
      :duplicate,
      :extra,
      :reordered,
      :foreign_owner,
      :wrong_count,
      :wrong_inventory_digest,
      :malformed_pair_hash,
      :foreign_struct,
      :untyped_map,
      :malformed_outer_digest,
      :nonlist_hashes
    ]

    for mutation <- mutations do
      fixture = shape_contract_fixture(root, mutation)

      result =
        Singularity.Runtime.IntegrityAudit.verify_plaintext_and_search(
          fixture.context,
          fixture.rewrapped
        )

      expected_stages =
        if mutation == :valid do
          assert result == :ok, "valid typed adapter pattern did not reach all facade boundaries"
          [:ciphertext, :lease, :documents, :rebuild, :complete, :revoke]
        else
          unavailable? =
            mutation in [
              :foreign_owner,
              :wrong_count,
              :foreign_struct,
              :untyped_map,
              :malformed_outer_digest,
              :nonlist_hashes
            ]

          code = if unavailable?, do: :storage_unavailable, else: :integrity_failure
          assert_native_denial_error!(result, code, unavailable?)
          [:ciphertext, :lease, :revoke]
        end

      events = shape_contract_events(fixture.reference)
      exact? = events == Enum.map(expected_stages, &{&1, true})
      assert exact?, "typed adapter contract changed stage order, arguments or revocation"
    end
  end

  defp shape_contract_fixture(root, mutation) do
    alias Singularity.Storage.Backup.IntegrityAudit, as: StorageAudit
    binding = %{manifest_id: id(920), vault_id: id(921)}

    inventory =
      for {object, position} <- [{id(922), 0}, {id(923), 1}] do
        %{
          asset_object_id: object,
          vault_id: binding.vault_id,
          key_domain_id: id(924),
          classification: :private,
          lookup_digest: :crypto.hash(:sha256, "lookup-#{position}"),
          ciphertext_hash: :crypto.hash(:sha256, "cipher-#{position}"),
          ciphertext_byte_size: 134 + position,
          storage_ref: object,
          inventory_position: position
        }
      end

    {:ok, digest} = StorageAudit.inventory_sha256(binding.vault_id, inventory)

    hashes =
      Enum.map(
        inventory,
        &%{
          asset_object_id: &1.asset_object_id,
          sha256: :crypto.hash(:sha256, "plaintext-#{&1.inventory_position}")
        }
      )

    plaintext = %PlaintextSummary{
      vault_id: binding.vault_id,
      object_count: 2,
      inventory_sha256: digest,
      plaintext_hashes: hashes
    }

    ciphertext = %StorageAudit.CiphertextSummary{
      vault_id: binding.vault_id,
      object_count: 2,
      inventory_sha256: digest,
      ciphertext_hashes:
        Enum.map(
          inventory,
          &%{asset_object_id: &1.asset_object_id, sha256: &1.ciphertext_hash}
        )
    }

    reference = make_ref()

    capability = %Singularity.Runtime.RestoreIntegrityLease.Capability{
      lease: self(),
      token: make_ref()
    }

    storage = {Singularity.Storage.LocalFilesystemAdapter, %{root: root}}

    ports = %{
      caller: self(),
      reference: reference,
      binding: binding,
      inventory: inventory,
      capability: capability,
      storage: storage,
      ciphertext: ciphertext,
      plaintext: plaintext,
      returned_plaintext: change_shape_summary(plaintext, mutation),
      search: %StorageAudit.SearchSummary{
        projection: "postgres_metadata_v1",
        document_count: 2,
        result_sha256: :crypto.hash(:sha256, "shape-search")
      },
      plaintext_digest:
        :crypto.hash(:sha256, [
          "SINGULARITY-PLAINTEXT-INTEGRITY-V1\0",
          Enum.map(hashes, &[Ecto.UUID.dump!(&1.asset_object_id), &1.sha256])
        ])
    }

    context = %{
      object_storage: storage,
      restore_integrity_lease: {ShapeLease, ports},
      ciphertext_auditor: {ShapePorts, ports},
      search_rebuilder: {ShapePorts, ports},
      audit: {ShapePorts, ports}
    }

    rewrapped = %{
      cut: %{
        logical_version: 3,
        manifest_id: binding.manifest_id,
        vault_id: binding.vault_id,
        object_inventory: inventory
      },
      manifest: %{manifest_id: binding.manifest_id},
      object_inventory: inventory,
      integrity_principal_id: id(925),
      integrity_capability: capability
    }

    %{context: context, rewrapped: rewrapped, reference: reference}
  end

  defp change_shape_summary(summary, mutation) do
    [first, second] = summary.plaintext_hashes
    <<head, tail::binary>> = summary.inventory_sha256
    different = <<Bitwise.bxor(head, 1), tail::binary>>

    case mutation do
      :valid ->
        summary

      :missing ->
        %{summary | plaintext_hashes: [first]}

      :duplicate ->
        %{summary | plaintext_hashes: [first, first]}

      :extra ->
        %{summary | plaintext_hashes: [first, second, %{first | asset_object_id: id(926)}]}

      :reordered ->
        %{summary | plaintext_hashes: [second, first]}

      :foreign_owner ->
        %{summary | vault_id: id(927)}

      :wrong_count ->
        %{summary | object_count: 1}

      :wrong_inventory_digest ->
        %{summary | inventory_sha256: different}

      :malformed_pair_hash ->
        %{summary | plaintext_hashes: [%{first | sha256: <<1>>}, second]}

      :foreign_struct ->
        struct(Singularity.Storage.Backup.IntegrityAudit.CiphertextSummary,
          vault_id: summary.vault_id,
          object_count: summary.object_count,
          inventory_sha256: summary.inventory_sha256,
          ciphertext_hashes: summary.plaintext_hashes
        )

      :untyped_map ->
        Map.from_struct(summary)

      :malformed_outer_digest ->
        %{summary | inventory_sha256: <<1>>}

      :nonlist_hashes ->
        %{summary | plaintext_hashes: :untrusted}
    end
  end

  defp shape_contract_events(reference, events \\ []) do
    receive do
      {^reference, :shape, stage, exact?} ->
        shape_contract_events(reference, [{stage, exact?} | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  # END Task8 native denials and separately labelled adapter contracts.

  defp run_uuid_saga!(
         tmp_dir,
         changed_name?,
         reference_mode \\ :uuid,
         probe_documents? \\ false
       ) do
    portable_root = Path.join(tmp_dir, "portable-#{Ecto.UUID.generate()}")
    File.mkdir!(portable_root)
    File.chmod!(portable_root, 0o700)
    saved = fixture_configuration()
    source = KnowledgeBackupRestoreFixture.backup_source!(portable_root, reference_mode)
    reference = make_ref()
    caller = self()
    new_password = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    observe_inventory = fn stage, payload ->
      send(caller, {reference, :inventory_observation, stage, payload})
      :ok
    end

    try do
      assert_closed_lifecycle(source.lifecycle)

      destination_lifecycle =
        KnowledgeBackupRestoreFixture.with_destination(source.lifecycle, fn fixture ->
          expected =
            Map.update!(source.observation.rows, "core.vaults", fn rows ->
              Enum.map(rows, &Map.put(&1, "locked", true))
            end)

          hooks = %{
            diagnostic: fn {stage, event} ->
              send(caller, {reference, :boundary_diagnostic, stage, event})
              :ok
            end,
            after_import: fn imported ->
              diagnose_restore_hook!(caller, reference, :import, fn ->
                observed = Canonical.read_committed!(MigrationRepo, source.owner, imported.cut)
                assert :ok = Canonical.compare(expected, observed)

                if reference_mode != :uuid do
                  send(caller, {reference, :persisted_objects, observed["content.asset_objects"]})

                  :ok =
                    observe_inventory.(
                      :imported,
                      KnowledgeRestoreOracle.inventory_handoff(imported)
                    )

                  :ok =
                    KnowledgeRestoreOracle.assert_saga_commitment!(
                      source,
                      fixture.destination.object_root,
                      imported
                    )

                  for entry <- source.original_inventory do
                    witness =
                      KnowledgeRestoreOracle.reference_witness!(
                        fixture.destination.object_root,
                        entry
                      )

                    same_ciphertext? =
                      Map.take(witness, [:stat, :ciphertext]) ==
                        Map.take(Map.fetch!(source.reference_witnesses, entry.asset_object_id), [
                          :stat,
                          :ciphertext
                        ])

                    assert same_ciphertext?,
                           "import changed genuine source ciphertext across reference spellings"
                  end
                end

                assert imported.manifest.manifest_id == source.operation_id
                assert imported.cut.snapshot_id == source.observation.cut.snapshot_id

                assert imported.cut.outbox_high_water_mark ==
                         source.observation.cut.outbox_high_water_mark

                assert source.observation.worker_backend != source.observation.observer_backend
                assert source.observation.database == source.lifecycle.database
                assert source.observation.worker_role == "singularity_worker"
                assert source.observation.snapshot == source.observation.cut.database_snapshot
                assert_import_secrets_and_seals!(source)

                if changed_name?,
                  do: assert_committed_name_mismatch!(source, imported.cut, expected)

                send(caller, {reference, :stage, :import})
                :ok
              end)
            end,
            after_rewrap: fn rewrapped ->
              diagnose_restore_hook!(caller, reference, :rewrap, fn ->
                assert rewrapped.manifest.manifest_id == source.operation_id
                assert_rewrapped_password!(source, new_password)

                if reference_mode != :uuid,
                  do:
                    observe_inventory.(
                      :rewrapped,
                      KnowledgeRestoreOracle.inventory_handoff(rewrapped)
                    )

                send(caller, {reference, :stage, :rewrap})
                :ok
              end)
            end,
            after_complete: fn :ok ->
              diagnose_restore_hook!(caller, reference, :complete, fn ->
                send(caller, {reference, :stage, :complete})
                :ok
              end)
            end
          }

          hooks =
            if reference_mode == :uuid,
              do: hooks,
              else: Map.put(hooks, :inventory_observer, observe_inventory)

          hooks =
            if probe_documents? do
              Map.put(hooks, :before_documents, fn binding, inventory, plaintext_hashes ->
                send(caller, {reference, :before_documents, binding, inventory, plaintext_hashes})
                :ok
              end)
            else
              hooks
            end

          Application.put_env(
            :singularity_runtime,
            :knowledge_v3_plaintext_observer,
            fn summary ->
              diagnose_restore_hook!(caller, reference, :plaintext, fn ->
                assert_native_summary!(source, summary)
                send(caller, {reference, :stage, :plaintext})
                send(caller, {reference, :summary, summary})
                :ok
              end)
            end
          )

          context =
            KnowledgeBackupRestoreFixture.restore_context(
              fixture.destination,
              portable_root,
              hooks,
              %{}
            )

          result =
            RestoreVault.run(context, %{
              source: source.destination_ref,
              passphrase: source.passphrase,
              new_password: new_password
            })

          success? = result == {:ok, %{manifest_id: source.operation_id}}

          failure_message =
            if success?,
              do: "genuine native UUID restore did not complete",
              else: restore_failure_diagnostic(reference, result)

          assert success?, failure_message

          for stage <- [:import, :rewrap, :plaintext, :complete] do
            assert_receive {^reference, :stage, actual_stage}
            assert actual_stage == stage
          end

          refute_receive {^reference, :stage, _}
          assert_receive {^reference, :summary, %PlaintextSummary{} = summary}
          assert_native_summary!(source, summary)
          refute_receive {^reference, :summary, _}

          if reference_mode != :uuid do
            assert :ok =
                     KnowledgeRestoreOracle.assert_inventory_observations!(
                       source,
                       fixture.destination.object_root,
                       inventory_observations(reference)
                     )
          end

          assert_reconciled_history!(source)

          runtime =
            KnowledgeBackupRestoreFixture.start_controlled_runtime!(
              fixture.owner,
              fixture.destination
            )

          session = NativeAssetFixture.login!(%{source.credentials | password: new_password})
          assert session.unlocked?
          refute session.session_id == source.owner.session_id

          assert :ok =
                   KnowledgeRestoreOracle.assert_originals!(
                     session,
                     KnowledgeBackupRestoreFixture.retained_originals!(source)
                   )

          assert :ok = KnowledgeRestoreOracle.assert_search!(session, source)
          assert_recovered_once!(source, session, runtime)

          %{fixture.lifecycle | infrastructure: runtime.infrastructure}
        end)

      assert_closed_lifecycle(destination_lifecycle)
      same_configuration? = fixture_configuration() == saved
      assert same_configuration?, "UUID native saga did not restore exact application settings"
      assert File.ls!(portable_root) == [source.destination_ref]
    after
      File.rm!(source.bundle_path)
      File.rmdir!(portable_root)
    end

    if reference_mode != :uuid do
      persisted_objects =
        receive do
          {^reference, :persisted_objects, rows} -> rows
        after
          0 -> flunk("completed historical compatibility saga did not capture persisted objects")
        end

      assert_historical_reference_inventory!(source, persisted_objects, reference_mode)
    end

    if probe_documents? do
      observation =
        receive do
          {^reference, :before_documents, binding, inventory, plaintext_hashes} ->
            {binding, inventory, plaintext_hashes}
        after
          0 -> nil
        end

      observed? = not is_nil(observation)

      assert observed?,
             "observer-wiring contract did not invoke before_documents after native saga completion"

      expected_bytes = source.sources |> Map.values() |> Map.new(&{&1.object_id, &1.bytes})

      expected_hashes =
        Enum.map(source.observation.cut.object_inventory, fn entry ->
          %{
            asset_object_id: entry.asset_object_id,
            sha256: :crypto.hash(:sha256, Map.fetch!(expected_bytes, entry.asset_object_id))
          }
        end)

      exact_arguments? =
        observation ==
          {%{manifest_id: source.operation_id, vault_id: source.owner.vault_id},
           source.observation.cut.object_inventory, expected_hashes}

      assert exact_arguments?,
             "observer-wiring contract changed native binding, original inventory or plaintext hashes"

      extra_observation? =
        receive do
          {^reference, :before_documents, _, _, _} -> true
        after
          0 -> false
        end

      refute extra_observation?,
             "observer-wiring contract invoked before_documents more than once"
    end
  end

  defp assert_historical_reference_inventory!(source, persisted_objects, reference_mode) do
    selected_objects =
      case reference_mode do
        :canonical_compatibility -> Map.keys(source.native_inventory)
        :mixed_compatibility -> [source.sources.pdf.object_id, source.sources.empty.object_id]
      end

    # Expected historical spellings are derived independently from source SQL.
    # Normal publication remains the separate untouched UUID case.
    expected =
      Enum.map(source.original_inventory, fn object ->
        entry = Map.new(@inventory_fields, &{&1, Map.fetch!(object, &1)})

        if object.asset_object_id in selected_objects do
          {:ok, canonical_path} =
            Singularity.Storage.Local.PathGuard.object_path(
              source.lifecycle.object_root,
              object.vault_id,
              object.key_domain_id,
              Base.encode16(object.lookup_digest, case: :lower)
            )

          Map.put(
            entry,
            :storage_ref,
            Path.relative_to(canonical_path, source.lifecycle.object_root)
          )
        else
          Map.put(entry, :storage_ref, object.asset_object_id)
        end
      end)

    persisted_inventory =
      persisted_objects
      |> Enum.sort_by(& &1["id"])
      |> Enum.with_index()
      |> Enum.map(fn {row, position} ->
        %{
          asset_object_id: row["id"],
          vault_id: row["vault_id"],
          key_domain_id: row["key_domain_id"],
          classification: String.to_existing_atom(row["classification"]),
          lookup_digest: row["lookup_digest"],
          ciphertext_hash: row["ciphertext_hash"],
          ciphertext_byte_size: row["ciphertext_byte_size"],
          storage_ref: row["storage_ref"],
          inventory_position: position
        }
      end)

    worker_matches? = source.observation.cut.object_inventory == expected
    persisted_matches? = persisted_inventory == expected

    assert worker_matches? and persisted_matches?,
           "historical compatibility source worker and persisted nine-field storage references differ"
  end

  defp inventory_observations(reference, events \\ []) do
    receive do
      {^reference, :inventory_observation, stage, payload} ->
        inventory_observations(reference, [{stage, payload} | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp diagnose_restore_hook!(caller, reference, stage, fun) do
    send(caller, {reference, :hook_diagnostic, stage, :entered})
    result = fun.()
    send(caller, {reference, :hook_diagnostic, stage, :completed})
    result
  rescue
    exception ->
      stack = __STACKTRACE__

      category =
        if exception.__struct__ in [
             ExUnit.AssertionError,
             MatchError,
             KeyError,
             ArgumentError,
             FunctionClauseError,
             CaseClauseError,
             BadMapError,
             RuntimeError,
             Postgrex.Error,
             DBConnection.ConnectionError
           ],
           do: exception.__struct__,
           else: :unknown

      line =
        Enum.find_value(stack, :unknown, fn
          {__MODULE__, _function, _arity, location} when is_list(location) ->
            case Keyword.get(location, :line) do
              line when is_integer(line) and line > 0 -> line
              _ -> nil
            end

          _ ->
            nil
        end)

      send(caller, {reference, :hook_diagnostic, stage, {:exception, category, line}})
      reraise exception, stack
  end

  defp restore_failure_diagnostic(reference, result) do
    public =
      case result do
        {:error, %Singularity.Core.Error{code: code, retryable?: retryable?}}
        when code in [
               :unauthenticated,
               :vault_locked,
               :forbidden,
               :not_found,
               :conflict,
               :invalid,
               :upload_expired,
               :upload_too_large,
               :unsupported_media_type,
               :integrity_failure,
               :storage_unavailable,
               :job_failed,
               :backup_invalid,
               :backup_unsupported
             ] and is_boolean(retryable?) ->
          "code=#{code} retryable=#{retryable?}"

        _ ->
          "code=unknown retryable=unknown"
      end

    events = restore_hook_diagnostics(reference, 12)
    "genuine native UUID restore did not complete (#{public}; hooks=#{Enum.join(events, ",")})"
  end

  defp restore_hook_diagnostics(_reference, 0), do: ["diagnostic_limit"]

  defp restore_hook_diagnostics(reference, remaining) do
    receive do
      {^reference, :boundary_diagnostic, stage, event}
      when stage in [:authenticate, :native_import] ->
        safe =
          case event do
            :entered ->
              "#{stage}:entered"

            {:returned, :ok} ->
              "#{stage}:returned:ok"

            {:returned, {:error, code, retryable?}}
            when code in [
                   :unauthenticated,
                   :vault_locked,
                   :forbidden,
                   :not_found,
                   :conflict,
                   :invalid,
                   :upload_expired,
                   :upload_too_large,
                   :unsupported_media_type,
                   :integrity_failure,
                   :storage_unavailable,
                   :job_failed,
                   :backup_invalid,
                   :backup_unsupported
                 ] and is_boolean(retryable?) ->
              "#{stage}:returned:error:#{code}:retryable=#{retryable?}"

            _ ->
              "#{stage}:returned:unknown"
          end

        [safe | restore_hook_diagnostics(reference, remaining - 1)]

      {^reference, :hook_diagnostic, stage, event}
      when stage in [:import, :rewrap, :plaintext, :complete] ->
        safe =
          case event do
            marker when marker in [:entered, :completed] ->
              "#{stage}:#{marker}"

            {:exception, category, line}
            when category in [
                   ExUnit.AssertionError,
                   MatchError,
                   KeyError,
                   ArgumentError,
                   FunctionClauseError,
                   CaseClauseError,
                   BadMapError,
                   RuntimeError,
                   Postgrex.Error,
                   DBConnection.ConnectionError,
                   :unknown
                 ] and
                   (is_integer(line) or line == :unknown) ->
              "#{stage}:exception:#{category}:line=#{line}"

            _ ->
              "#{stage}:unknown"
          end

        [safe | restore_hook_diagnostics(reference, remaining - 1)]
    after
      0 -> []
    end
  end

  defp assert_import_secrets_and_seals!(source) do
    %{rows: [[credentials, pending_wrappers]]} =
      NativeAssetFixture.observe!(
        """
        SELECT
          (SELECT count(*) FROM identity.credentials c CROSS JOIN identity.security_settings s
            WHERE c.account_id=$1 AND c.verifier=s.dummy_verifier AND c.verifier_version=1
              AND c.updated_at=c.inserted_at AND s.singleton),
          (SELECT count(*) FROM core.vault_key_wrappers w WHERE w.vault_id=$2
            AND w.account_id=$1 AND w.kdf_version=1 AND w.kdf_salt=$3
            AND w.kdf_parameters='{"state":"restore_pending","version":1}'::jsonb
            AND w.wrapper_algorithm='restore_pending' AND w.wrapped_key=$3)
        """,
        [
          Ecto.UUID.dump!(source.owner.account_id),
          Ecto.UUID.dump!(source.owner.vault_id),
          "restore-pending"
        ]
      )

    assert credentials == length(source.observation.rows["identity.credentials"])
    assert pending_wrappers == length(source.observation.rows["core.vault_key_wrappers"])

    %{rows: seals} =
      NativeAssetFixture.observe!(
        """
        SELECT note_resource_version_id::text,attachment_count,citation_count
        FROM content.note_source_set_seals WHERE vault_id=$1 ORDER BY note_resource_version_id
        """,
        [Ecto.UUID.dump!(source.owner.vault_id)]
      )

    same_seals? = seals == source.source_set_seals
    assert same_seals?, "import did not regenerate exact immutable Note source-set seals"
    assert is_nil(Process.whereis(Singularity.Runtime.Documents.ExtractionReconciler))
    assert is_nil(Process.whereis(Singularity.Runtime.KeyCustodian))
  end

  defp assert_rewrapped_password!(source, new_password) do
    result =
      NativeAssetFixture.observe!(
        """
        SELECT c.verifier, NOT EXISTS(SELECT 1 FROM core.vault_key_wrappers w
          WHERE w.account_id=c.account_id AND w.wrapper_algorithm='restore_pending')
        FROM identity.credentials c WHERE c.account_id=$1 AND c.revoked_at IS NULL
        """,
        [Ecto.UUID.dump!(source.owner.account_id)]
      )

    bootstrap = Application.fetch_env!(:singularity_runtime, :bootstrap_owner)

    changed? =
      case result.rows do
        [[verifier, true]] ->
          bootstrap.password_hasher.verify(
            bootstrap.password_hasher_context,
            new_password,
            verifier
          ) == {:ok, true} and
            bootstrap.password_hasher.verify(
              bootstrap.password_hasher_context,
              source.credentials.password,
              verifier
            ) == {:ok, false}

        _ ->
          false
      end

    assert changed?, "restore did not replace pending credential and password wrapper"
  end

  defp assert_committed_name_mismatch!(source, cut, expected) do
    [person] = expected["identity.people"]
    replacement = "Disposable canonical mismatch #{Ecto.UUID.generate()}"
    update_person_name!(source.owner.account_id, replacement)
    changed = Canonical.read_committed!(MigrationRepo, source.owner, cut)

    assert {:error, {:canonical_mismatch, ["identity.people"]}} =
             Canonical.compare(expected, changed)

    counts_unchanged? =
      Enum.all?(expected, fn {table, rows} -> length(rows) == length(changed[table]) end)

    identities_unchanged? =
      Enum.all?(Canonical.projection(), fn {table, _columns, pk} ->
        Enum.map(expected[table], &Map.take(&1, pk)) ==
          Enum.map(changed[table], &Map.take(&1, pk))
      end)

    assert counts_unchanged? and identities_unchanged?,
           "mutable mismatch changed canonical row membership"

    update_person_name!(source.owner.account_id, person["display_name"])
    restored = Canonical.read_committed!(MigrationRepo, source.owner, cut)
    assert :ok = Canonical.compare(expected, restored)
  end

  defp update_person_name!(account, name) do
    owner_query(fn ->
      result =
        SafeSQL.query!(
          MigrationRepo,
          """
          UPDATE identity.people p SET display_name=$1 FROM identity.accounts a
          WHERE a.id=$2 AND p.id=a.person_id RETURNING p.id
          """,
          [name, Ecto.UUID.dump!(account)]
        )

      assert result.num_rows == 1
    end)
  end

  defp assert_native_summary!(source, %PlaintextSummary{} = summary) do
    assert summary.vault_id == source.owner.vault_id
    assert summary.object_count == 5
    expected_ids = Enum.map(source.observation.cut.object_inventory, & &1.asset_object_id)
    assert Enum.map(summary.plaintext_hashes, & &1.asset_object_id) == expected_ids
    expected_bytes = source.sources |> Map.values() |> Map.new(&{&1.object_id, &1.bytes})

    actual_hashes? =
      Enum.all?(summary.plaintext_hashes, fn item ->
        item.sha256 == :crypto.hash(:sha256, Map.fetch!(expected_bytes, item.asset_object_id))
      end)

    assert actual_hashes?,
           "actual native authenticated plaintext hashes differ from independent originals"

    {:ok, inventory_hash} =
      Singularity.Storage.Backup.IntegrityAudit.inventory_sha256(
        source.owner.vault_id,
        KnowledgeRestoreOracle.projected_inventory!(source)
      )

    exact_inventory? = summary.inventory_sha256 == inventory_hash

    assert exact_inventory?,
           "actual native plaintext summary lost exact ordered inventory binding"
  end

  defp assert_reconciled_history!(source) do
    rows = Canonical.read_committed!(MigrationRepo, source.owner, source.observation.cut)

    for table <- [
          "content.document_versions",
          "content.document_fragments",
          "content.document_import_receipts",
          "jobs.job_progress",
          "jobs.effect_receipts"
        ] do
      same_rows? = rows[table] == source.observation.rows[table]

      assert same_rows?,
             "restore reconciliation changed immutable or retained history in #{table}"
    end

    [before_event] =
      Enum.filter(
        source.observation.rows["core.outbox_events"],
        &(&1["id"] == source.work.submission_id)
      )

    [event] = Enum.filter(rows["core.outbox_events"], &(&1["id"] == source.work.submission_id))
    assert event["retirement_reason"] == "restore_effect_already_reflected"
    refute is_nil(event["retired_at"])

    for column <- ~w(claim_token claimed_until runner_job_id delivered_at),
        do: assert(is_nil(event[column]))

    mutable =
      ~w(claim_token claimed_until runner_job_id delivered_at retired_at retirement_reason updated_at)

    unchanged_event? = Map.drop(before_event, mutable) == Map.drop(event, mutable)
    assert unchanged_event?, "restore retirement changed the original Document event envelope"

    [before_submission] =
      Enum.filter(
        source.observation.rows["jobs.job_submissions"],
        &(&1["id"] == source.work.submission_id)
      )

    [submission] =
      Enum.filter(rows["jobs.job_submissions"], &(&1["id"] == source.work.submission_id))

    assert is_nil(submission["runner_job_id"])

    unchanged_submission? =
      Map.drop(before_submission, ~w(runner_job_id updated_at)) ==
        Map.drop(submission, ~w(runner_job_id updated_at))

    assert unchanged_submission?, "restore retirement changed the original Document submission"
  end

  defp assert_recovered_once!(source, session, runtime) do
    alias Singularity.Runtime.Documents.ExtractionReconciler
    alias Singularity.Storage.Postgres.DocumentRepository
    context = %{repo: WorkerRepo}
    assert {:ok, 1} = ExtractionReconciler.run(context)
    rows = Canonical.read_committed!(MigrationRepo, source.owner, source.observation.cut)

    expected =
      Enum.map(source.observation.rows["content.document_versions"], fn row ->
        if row["resource_version_id"] == source.ids.extracting_version_id do
          Map.merge(row, %{
            "state" => "pending",
            "attempt_generation" => 2,
            "attempt_job_id" => nil,
            "attempt_started_at" => nil,
            "attempt_deadline_at" => nil,
            "extraction_adapter" => nil,
            "extraction_format" => nil,
            "extracted_text_digest" => nil,
            "detected_language" => nil,
            "failure_code" => nil,
            "attempt_finished_at" => nil
          })
        else
          row
        end
      end)

    same_versions? = rows["content.document_versions"] == expected

    assert same_versions?,
           "lawful abandoned extraction recovery changed unexpected Document history"

    key = "document-extraction:#{source.ids.extracting_version_id}:2"

    %{rows: [values], columns: columns} =
      NativeAssetFixture.observe!(
        "SELECT * FROM core.outbox_events WHERE vault_id=$1 AND idempotency_key=$2",
        [Ecto.UUID.dump!(source.owner.vault_id), key]
      )

    [event] = Canonical.normalize_rows("core.outbox_events", %{rows: [values], columns: columns})
    assert event["event_type"] == "document.extraction_requested"
    assert event["causation_id"] == source.work.submission_id
    assert event["correlation_id"] == source.ids.extracting_version_id
    assert event["principal_id"] == session.principal_id
    assert event["vault_id"] == session.vault_id
    assert event["classification"] == "private"
    assert event["required_capability"] == "asset.read"
    assert event["envelope_version"] == 1
    assert event["expected_entity_revision"] == 2
    assert event["principal_authorization_epoch"] == session.principal_authorization_epoch
    assert event["vault_authorization_epoch"] == session.vault_authorization_epoch

    exact_payload? =
      event["payload"] == %{
        "resource_id" => source.ids.extracting_document_id,
        "resource_version_id" => source.ids.extracting_version_id
      }

    assert exact_payload?, "recovery successor lost its exact immutable Document identity"
    assert is_nil(event["retired_at"]) and is_nil(event["retirement_reason"])
    recovered_work = successor_work!(source, key)
    assert {:ok, 0} = ExtractionReconciler.run(context)

    assert {:ok, false} =
             DocumentRepository.recover_expired_with_event(
               context,
               source.ids.extracting_version_id,
               source.owner.vault_id
             )

    same_recovered_work? = successor_work!(source, key) == recovered_work

    assert same_recovered_work?,
           "repeated recovery changed persisted successor event or work rows"

    after_retry = Canonical.read_committed!(MigrationRepo, source.owner, source.observation.cut)
    unchanged? = after_retry["content.document_versions"] == rows["content.document_versions"]
    assert unchanged?, "repeated recovery changed Document state again"
    NativeAssetFixture.dispatch!()
    dispatched_work = successor_work!(source, key)
    assert_successor_runner!(dispatched_work, event)
    NativeAssetFixture.dispatch!()
    same_dispatched_work? = successor_work!(source, key) == dispatched_work

    assert same_dispatched_work?,
           "repeated dispatch changed successor event, submission, or actual runner rows"

    assert {:ok, reconciler} =
             Supervisor.start_child(runtime.infrastructure, runtime.deferred_extraction)

    assert Process.alive?(reconciler)
    assert {:ok, 0} = ExtractionReconciler.run(context)

    assert {:ok, false} =
             DocumentRepository.recover_expired_with_event(
               context,
               source.ids.extracting_version_id,
               source.owner.vault_id
             )

    same_final_work? = successor_work!(source, key) == dispatched_work
    assert same_final_work?, "enabled recovery duplicated or changed persisted successor work"
    final_rows = Canonical.read_committed!(MigrationRepo, source.owner, source.observation.cut)

    same_final_documents? =
      final_rows["content.document_versions"] == rows["content.document_versions"]

    assert same_final_documents?, "enabled recovery changed retained Document versions again"
    # No document_extract queue is drained: original-byte verification is not extraction.
  end

  defp successor_work!(source, key) do
    queries = [
      event:
        "SELECT e.* FROM core.outbox_events e WHERE e.vault_id=$1 AND e.idempotency_key=$2 ORDER BY e.id",
      submissions:
        "SELECT s.* FROM jobs.job_submissions s JOIN core.outbox_events e ON e.id=s.outbox_event_id AND e.vault_id=s.vault_id WHERE e.vault_id=$1 AND e.idempotency_key=$2 ORDER BY s.id",
      progress:
        "SELECT p.* FROM jobs.job_progress p JOIN jobs.job_submissions s ON s.id=p.submission_id AND s.vault_id=p.vault_id JOIN core.outbox_events e ON e.id=s.outbox_event_id AND e.vault_id=s.vault_id WHERE e.vault_id=$1 AND e.idempotency_key=$2 ORDER BY p.id",
      effects:
        "SELECT f.* FROM jobs.effect_receipts f JOIN jobs.job_submissions s ON s.id=f.submission_id AND s.vault_id=f.vault_id JOIN core.outbox_events e ON e.id=s.outbox_event_id AND e.vault_id=s.vault_id WHERE e.vault_id=$1 AND e.idempotency_key=$2 ORDER BY f.id",
      runners: """
      SELECT j.* FROM jobs.oban_jobs j
      WHERE j.args->>'vault_id'=$1::uuid::text AND
        (j.args->>'idempotency_key'=$2 OR j.args->>'job_id' IN
          (SELECT e.id::text FROM core.outbox_events e WHERE e.vault_id=$1 AND e.idempotency_key=$2))
      ORDER BY j.id
      """
    ]

    Map.new(queries, fn {name, sql} ->
      result = NativeAssetFixture.observe!(sql, [Ecto.UUID.dump!(source.owner.vault_id), key])
      {name, Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))}
    end)
  end

  defp assert_successor_runner!(work, expected_event) do
    exactly_one? =
      length(work.event) == 1 and length(work.submissions) == 1 and length(work.runners) == 1

    assert exactly_one?,
           "successor does not own exactly one persisted event, submission, and Oban job"

    [event] = work.event
    [submission] = work.submissions
    [job] = work.runners
    job_id = Integer.to_string(job["id"])

    bound? =
      Ecto.UUID.load!(event["id"]) == expected_event["id"] and
        submission["id"] == event["id"] and submission["outbox_event_id"] == event["id"] and
        submission["vault_id"] == event["vault_id"] and submission["classification"] == "private" and
        submission["job_type"] == "document_extract" and
        submission["idempotency_key"] == event["idempotency_key"] and
        submission["runner_job_id"] == job_id and event["runner_job_id"] == job_id and
        job["queue"] == "document_extract" and
        job["worker"] == "Singularity.Storage.Jobs.GenericWorker"

    assert bound?,
           "actual successor runner identity does not bind its persisted event and submission"

    expected_args = %{
      "version" => 1,
      "job_id" => expected_event["id"],
      "job_type" => "document_extract",
      "idempotency_key" => expected_event["idempotency_key"],
      "vault_id" => expected_event["vault_id"],
      "principal_id" => expected_event["principal_id"],
      "required_capability" => expected_event["required_capability"],
      "principal_authorization_epoch" => expected_event["principal_authorization_epoch"],
      "vault_authorization_epoch" => expected_event["vault_authorization_epoch"],
      "classification" => "private",
      "correlation_id" => expected_event["correlation_id"],
      "causation_id" => expected_event["causation_id"],
      "expected_entity_revision" => 2,
      "attempt" => 0,
      "payload" => expected_event["payload"]
    }

    exact_args? = job["args"] == expected_args

    assert exact_args?,
           "actual Oban runner arguments do not preserve the exact successor envelope"
  end

  defp fixture_configuration do
    Map.new([:singularity_runtime, :singularity_storage], fn app ->
      {app, Map.new(Application.get_all_env(app))}
    end)
  end

  defp assert_closed_lifecycle(lifecycle) do
    if lifecycle.infrastructure, do: refute(Process.alive?(lifecycle.infrastructure))
    if lifecycle.observer, do: refute(Process.alive?(lifecycle.observer))

    assert Enum.all?(lifecycle.repositories, fn {_repo, {pid, _database}} ->
             not Process.alive?(pid)
           end)

    refute File.exists?(lifecycle.object_root)
  end

  defp run_fixture_outcome(:return, fun), do: assert(fun.() == :callback_returned)

  defp run_fixture_outcome(:error, fun),
    do: assert_raise(RuntimeError, "knowledge fixture callback interrupted", fun)

  defp run_fixture_outcome(:throw, fun), do: assert(catch_throw(fun.()) == :callback_thrown)

  defp finish_fixture_callback(:return), do: :callback_returned
  defp finish_fixture_callback(:error), do: raise("knowledge fixture callback interrupted")
  defp finish_fixture_callback(:throw), do: throw(:callback_thrown)

  defp take_ok!({:ok, value}, _stage), do: value
  defp take_ok!(_result, stage), do: flunk("native knowledge fixture failed at #{stage}")

  defp with_sql_foundation(fun) do
    KnowledgeBackupFixtures.with_destination(:current, fn destination ->
      fixture =
        KnowledgeBackupFixtures.seed!(Map.merge(destination, %{ids: @ids, originals: @originals}))

      fun.(fixture)
    end)
  end

  defp cut!(repo, owner) do
    %{rows: [[snapshot, high_water]]} =
      SafeSQL.query!(
        repo,
        """
        SELECT txid_current_snapshot()::text,
          (SELECT COALESCE(max(sequence), 0) FROM core.outbox_events WHERE vault_id=$1)
        """,
        [Ecto.UUID.dump!(owner.vault_id)]
      )

    %{database_snapshot: snapshot, outbox_high_water_mark: high_water}
  end

  defp role_and_backend(repo) do
    %{rows: [[role, backend]]} = SafeSQL.query!(repo, "SELECT current_user,pg_backend_pid()", [])
    {role, backend}
  end

  defp owner_query(fun) do
    {:ok, result} =
      MigrationRepo.transaction(fn ->
        SafeSQL.query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner", [])
        fun.()
      end)

    result
  end

  defp seed_foreign_scope!(owner) do
    query!(
      "INSERT INTO identity.people(id,display_name) VALUES($1,'SQL foundation foreign owner')",
      [
        id(900)
      ]
    )

    query!("INSERT INTO identity.accounts(id,person_id) VALUES($1,$2)", [id(901), id(900)])

    query!("INSERT INTO identity.principals(id,account_id,kind) VALUES($1,$2,'owner')", [
      id(902),
      id(901)
    ])

    query!("INSERT INTO core.vaults(id) VALUES($1)", [id(903)])

    query!("INSERT INTO core.vault_members(principal_id,vault_id) VALUES($1,$2)", [
      id(902),
      id(903)
    ])

    query!("INSERT INTO core.vault_members(principal_id,vault_id) VALUES($1,$2)", [
      id(902),
      owner.vault_id
    ])

    query!("INSERT INTO core.capabilities(id,name) VALUES($1,'sql.foundation.foreign')", [id(904)])

    query!(
      "INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id) VALUES($1,$2,$3)",
      [id(902), id(903), id(904)]
    )

    query!(
      "INSERT INTO identity.credentials(id,account_id,normalized_login,verifier) VALUES($1,$2,'sql-foundation-foreign@example.test','sql-foundation-verifier')",
      [id(905), id(901)]
    )

    query!(
      "INSERT INTO identity.devices(id,principal_id,vault_id,label) VALUES($1,$2,$3,'SQL foundation foreign device')",
      [id(906), id(902), id(903)]
    )

    query!("INSERT INTO identity.principals(id,account_id,kind) VALUES($1,$2,'owner')", [
      id(907),
      owner.account_id
    ])
  end

  defp seed_unselected_wrappers!(owner) do
    query!(
      """
      INSERT INTO core.vault_key_versions(id,vault_id,generation,state,algorithm)
      VALUES($1,$2,2,'retired','aes_256_gcm')
      """,
      [id(910), owner.vault_id]
    )

    for {wrapper, version, account, generation} <- [
          {id(911), id(910), owner.account_id, 2},
          {id(912), fixture_id(107), id(901), 1}
        ] do
      result =
        query!(
          """
          INSERT INTO core.vault_key_wrappers(id,vault_id,vault_key_version_id,account_id,
            generation,kdf_version,kdf_salt,kdf_parameters,wrapper_algorithm,wrapped_key)
          SELECT $1,vault_id,$2,$3,$4,kdf_version,kdf_salt,kdf_parameters,wrapper_algorithm,wrapped_key
          FROM core.vault_key_wrappers WHERE id=$5
          """,
          [wrapper, version, account, generation, fixture_id(108)]
        )

      assert result.num_rows == 1
    end
  end

  defp query!(sql, ids) do
    parameters =
      Enum.map(ids, fn
        value when is_integer(value) -> value
        value -> Ecto.UUID.dump!(value)
      end)

    SafeSQL.query!(MigrationRepo, sql, parameters)
  end

  defp id(number),
    do: "70000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(number), 12, "0")

  defp fixture_id(number),
    do: "60000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(number), 12, "0")

  # BEGIN Task11 actual Runtime fault order and honest continuation contracts.
  @task11_stages ~w(maintenance admission authentication import claim rewrap early_cipher reconcile final_cipher plaintext documents rebuild integrity_complete restore_complete)a

  for fault <- [
        :admission,
        :wrong_passphrase,
        :preflight,
        :canonical,
        :empty_seal,
        :before_publish,
        :after_publish,
        :commit_uncertainty,
        :rewrap_sql,
        :rewrap_reply,
        :early_cipher,
        :reconcile_before,
        :reconcile_after,
        :final_cipher,
        :plaintext_revoked,
        :plaintext_after,
        :documents,
        :rebuild_before,
        :rebuild_after,
        :integrity_before,
        :integrity_after,
        :restore_before,
        :restore_after
      ] do
    @tag :tmp_dir
    test "Task11 actual Runtime #{fault} preserves native order, custody and maintenance barriers",
         %{tmp_dir: tmp_dir} do
      task11_with_source!(tmp_dir, fn source, portable_root ->
        lifecycle =
          KnowledgeBackupRestoreFixture.with_destination(source.lifecycle, fn fixture ->
            task11_fault_attempt!(source, portable_root, fixture, unquote(fault))
            fixture.lifecycle
          end)

        assert_closed_lifecycle(lifecycle)
      end)
    end
  end

  @tag :tmp_dir
  test "Task11 fresh authentication retries the identical initially empty destination to full native publication",
       %{tmp_dir: tmp_dir} do
    task11_with_source!(tmp_dir, fn source, portable_root ->
      lifecycle =
        KnowledgeBackupRestoreFixture.with_destination(source.lifecycle, fn fixture ->
          identity = {fixture.destination.database, fixture.destination.object_root}
          before = KnowledgeRestoreOracle.installation_snapshot!(MigrationRepo, elem(identity, 1))
          task11_fault_attempt!(source, portable_root, fixture, :wrong_passphrase, false)

          assert :ok =
                   KnowledgeRestoreOracle.assert_installation_unchanged!(
                     before,
                     MigrationRepo,
                     fixture.destination.object_root
                   )

          same? = identity == {fixture.destination.database, fixture.destination.object_root}
          assert same?, "authentication retry changed destination identity"
          runtime = task11_full_success!(source, portable_root, fixture)
          %{fixture.lifecycle | infrastructure: runtime.infrastructure}
        end)

      assert_closed_lifecycle(lifecycle)
    end)
  end

  @tag :tmp_dir
  test "Task11 preflight failure before native staging supports full fresh-authentication retry in place",
       %{tmp_dir: tmp_dir} do
    task11_with_source!(tmp_dir, fn source, portable_root ->
      lifecycle =
        KnowledgeBackupRestoreFixture.with_destination(source.lifecycle, fn fixture ->
          task11_fault_attempt!(source, portable_root, fixture, :preflight, false)
          assert File.ls!(fixture.destination.object_root) == []
          runtime = task11_full_success!(source, portable_root, fixture)
          %{fixture.lifecycle | infrastructure: runtime.infrastructure}
        end)

      assert_closed_lifecycle(lifecycle)
    end)
  end

  @tag :tmp_dir
  @tag timeout: 120_000
  test "Task11 a new-target RESTART preserves a genuinely published parked sentinel installation",
       %{tmp_dir: tmp_dir} do
    task11_with_source!(tmp_dir, fn source, portable_root ->
      task11_phase(:sentinel_lifetime, :begin)

      sentinel_lifecycle =
        KnowledgeBackupRestoreFixture.with_destination(source.lifecycle, fn sentinel ->
          task11_phase(:sentinel_publication, :begin)
          runtime = task11_full_success!(source, portable_root, sentinel)
          task11_phase(:sentinel_publication, :returned)
          task11_phase(:sentinel_parking, :begin)

          KnowledgeBackupRestoreFixture.task11_with_parked_installation!(runtime, fn repo ->
            task11_phase(:sentinel_parking, :returned)
            task11_phase(:sentinel_snapshot, :begin)

            snapshot =
              KnowledgeRestoreOracle.installation_snapshot!(
                repo,
                sentinel.destination.object_root
              )

            task11_phase(:sentinel_snapshot, :returned)
            task11_phase(:failed_target_lifetime, :begin)

            failed_lifecycle =
              KnowledgeBackupRestoreFixture.task11_with_child_destination!(
                source.lifecycle,
                sentinel.owner,
                fn failed ->
                  task11_phase(:failed_attempt, :begin)
                  task11_fault_attempt!(source, portable_root, failed, :plaintext_after)
                  task11_phase(:failed_attempt, :returned)
                  task11_phase(:failed_target_close, :begin)
                  failed.lifecycle
                end
              )

            assert_closed_lifecycle(failed_lifecycle)
            task11_phase(:failed_target_close, :returned)
            task11_phase(:failed_target_lifetime, :returned)
            task11_phase(:sentinel_after_failure, :begin)

            assert :ok =
                     KnowledgeRestoreOracle.assert_installation_unchanged!(
                       snapshot,
                       repo,
                       sentinel.destination.object_root
                     )

            task11_phase(:sentinel_after_failure, :returned)
            task11_phase(:restart_lifetime, :begin)

            restarted_lifecycle =
              KnowledgeBackupRestoreFixture.task11_with_child_destination!(
                source.lifecycle,
                sentinel.owner,
                fn fresh ->
                  separate? =
                    fresh.destination.database != sentinel.destination.database and
                      fresh.destination.object_root != sentinel.destination.object_root and
                      fresh.destination.database != failed_lifecycle.database and
                      fresh.destination.object_root != failed_lifecycle.object_root

                  assert separate?, "RESTART reused a failed or sentinel installation"
                  task11_phase(:restart_publication, :begin)
                  restarted = task11_full_success!(source, portable_root, fresh)
                  task11_phase(:restart_publication, :returned)
                  task11_phase(:restart_close, :begin)
                  %{fresh.lifecycle | infrastructure: restarted.infrastructure}
                end
              )

            assert_closed_lifecycle(restarted_lifecycle)
            task11_phase(:restart_close, :returned)
            task11_phase(:restart_lifetime, :returned)
            task11_phase(:sentinel_after_restart, :begin)

            assert :ok =
                     KnowledgeRestoreOracle.assert_installation_unchanged!(
                       snapshot,
                       repo,
                       sentinel.destination.object_root
                     )

            task11_phase(:sentinel_after_restart, :returned)
          end)

          task11_phase(:sentinel_close, :begin)
          %{sentinel.lifecycle | infrastructure: runtime.infrastructure}
        end)

      assert_closed_lifecycle(sentinel_lifecycle)
      task11_phase(:sentinel_close, :returned)
      task11_phase(:sentinel_lifetime, :returned)
    end)
  end

  defp task11_with_source!(tmp_dir, fun) do
    epoch_key = {__MODULE__, :task11_diagnostic_epoch}
    Process.put(epoch_key, System.monotonic_time(:millisecond))

    try do
      task11_phase(:source_prepare, :begin)
      portable_root = Path.join(tmp_dir, "task11-#{Ecto.UUID.generate()}")
      saved = fixture_configuration()
      primary_failure = {__MODULE__, make_ref()}
      File.mkdir!(portable_root)

      try do
        File.chmod!(portable_root, 0o700)
        source = KnowledgeBackupRestoreFixture.backup_source!(portable_root, :uuid)
        assert_closed_lifecycle(source.lifecycle)
        assert_native_denial_source!(source, :valid)
        encrypted = :crypto.hash(:sha256, File.read!(source.bundle_path))
        task11_phase(:source_prepare, :returned)
        fun.(source, portable_root)
        task11_phase(:final_source_checks, :begin)
        unchanged? = encrypted == :crypto.hash(:sha256, File.read!(source.bundle_path))
        assert unchanged?, "Task11 changed the identical encrypted backup source"
        same_configuration? = fixture_configuration() == saved
        assert same_configuration?, "Task11 changed exact application configuration"
        task11_phase(:final_source_checks, :returned)
      catch
        kind, reason ->
          Process.put(primary_failure, true)
          :erlang.raise(kind, reason, __STACKTRACE__)
      after
        task11_phase(:source_close, :begin)
        failures = task11_close_portable_source(portable_root)
        had_primary? = Process.delete(primary_failure) == true

        if failures != [] do
          # Never replace the primary acquisition/assertion failure. A separate
          # fixed marker keeps cleanup failure visible without content or paths.
          IO.puts(:stderr, "Task11 exclusive portability cleanup failed")
          unless had_primary?, do: flunk("Task11 exclusive portability cleanup failed")
        end

        task11_phase(:source_close, :returned)
      end
    after
      Process.delete(epoch_key)
    end
  end

  defp task11_phase(stage, status)
       when stage in ~w(source_prepare source_close final_source_checks sentinel_lifetime
         sentinel_publication sentinel_parking sentinel_snapshot failed_target_lifetime
         failed_attempt failed_target_close same_target_retry sentinel_after_failure
         restart_lifetime restart_publication restart_close sentinel_after_restart
         sentinel_close native_restore controlled_runtime login native_originals
         public_originals public_search)a and status in [:begin, :returned] do
    case Process.get({__MODULE__, :task11_diagnostic_epoch}) do
      epoch when is_integer(epoch) ->
        elapsed = System.monotonic_time(:millisecond) - epoch
        IO.puts(:stderr, "task11_phase=#{stage} status=#{status} elapsed_ms=#{elapsed}")

      _absent ->
        :ok
    end
  end

  defp task11_close_portable_source(root) do
    failures =
      case File.ls(root) do
        {:ok, names} ->
          Enum.flat_map(names, fn name ->
            path = Path.join(root, name)
            basename = Path.rootname(name, ".bundle")

            owned_name? =
              Path.extname(name) == ".bundle" and Ecto.UUID.cast(basename) == {:ok, basename}

            case {owned_name?, File.lstat(path)} do
              {true, {:ok, %{type: :regular}}} ->
                if File.rm(path) == :ok, do: [], else: [:bundle_cleanup]

              _ ->
                [:unrecognized_artifact_retained]
            end
          end)

        {:error, _reason} ->
          [:portability_inventory]
      end

    if File.rmdir(root) == :ok, do: failures, else: [:portability_root | failures]
  end

  defp task11_fault_attempt!(source, portable_root, fixture, fault, probe_retry? \\ true) do
    reference = make_ref()
    caller = self()

    record = fn event ->
      send(caller, {reference, :task11, event})
      :ok
    end

    password = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    checks = task11_checks(source, fixture.destination.object_root, password, record)

    admission_snapshot =
      if fault == :admission do
        File.write!(
          Path.join(fixture.destination.object_root, "foreign-installation-sentinel"),
          "Task11 independently owned foreign artifact"
        )

        KnowledgeRestoreOracle.installation_snapshot!(
          MigrationRepo,
          fixture.destination.object_root
        )
      end

    {result, seam} =
      KnowledgeBackupRestoreFixture.task11_with_fault_context!(
        fixture.destination,
        portable_root,
        source,
        fault,
        record,
        checks,
        fn context ->
          RestoreVault.run(context, %{
            source: source.destination_ref,
            passphrase:
              if(fault == :wrong_passphrase,
                do: source.passphrase <> "wrong",
                else: source.passphrase
              ),
            new_password: password
          })
        end
      )

    {code, retryable?} = task11_error(fault)
    assert_native_denial_error!(result, code, retryable?)
    events = task11_events(reference)
    trace = for {:trace, event} <- events, do: event
    exact_order? = trace == task11_expected_trace(fault)
    assert exact_order?, "Task11 actual delegate trace reached an unexpected or downstream stage"

    succeeded = for {:returned, stage, :ok} <- trace, do: stage
    checked = for {:checked, stage} <- events, do: stage
    assert checked == succeeded, "Task11 missed an independent check of actual successful work"
    expected_auth = if fault == :admission, do: 0, else: 1
    actual_auth = Enum.count(events, &match?({:backup_lease, _, _}, &1))
    assert actual_auth == expected_auth, "Task11 did not observe every actual backup lease"
    expected_integrity = if :claim in succeeded, do: 1, else: 0
    actual_integrity = Enum.count(events, &match?({:integrity_capability, _, _}, &1))

    assert actual_integrity == expected_integrity,
           "Task11 did not observe actual issued integrity custody"

    claimed = Enum.count(events, &match?({:claimed_recovered_key, _}, &1))
    assert claimed == expected_integrity, "Task11 missed the actual claimed recovered-key handle"
    task11_assert_custody!(events)
    task11_assert_document_arguments!(source, events)
    task11_assert_maintenance!()
    task11_assert_durable_fault!(source, fixture, fault, succeeded, seam)

    storage = for {:storage, event} <- events, do: event

    case fault do
      :preflight ->
        assert storage == [:stage_denied]

      kind when kind in [:canonical, :empty_seal, :before_publish, :after_publish] ->
        assert Enum.count(storage, &(&1 == :staged)) == 5
        assert Enum.count(storage, &(&1 == :sealed)) == 5

        if kind == :before_publish,
          do:
            assert(
              Enum.take(storage, -3) == [:finalize_entered, :validated_graph, :publish_denied]
            )

      _ ->
        :ok
    end

    if admission_snapshot do
      assert :ok =
               KnowledgeRestoreOracle.assert_installation_unchanged!(
                 admission_snapshot,
                 MigrationRepo,
                 fixture.destination.object_root
               )
    end

    if fault == :commit_uncertainty do
      task11_committed_storage_replay!(source, portable_root, fixture, seam.imported)
    end

    if probe_retry? do
      snapshot =
        KnowledgeRestoreOracle.installation_snapshot!(
          MigrationRepo,
          fixture.destination.object_root
        )

      retry_ref = make_ref()

      retry_record = fn event ->
        send(caller, {retry_ref, :task11, event})
        :ok
      end

      if fault not in [:admission, :wrong_passphrase, :preflight],
        do: task11_phase(:same_target_retry, :begin)

      {retry, _seam} =
        KnowledgeBackupRestoreFixture.task11_with_fault_context!(
          fixture.destination,
          portable_root,
          source,
          :none,
          retry_record,
          task11_checks(source, fixture.destination.object_root, password, retry_record),
          fn context ->
            if fault in [:admission, :wrong_passphrase, :preflight] do
              # Supported retries are completed by the dedicated full-publication
              # contracts above; this branch must not consume another input here.
              :not_attempted
            else
              RestoreVault.run(context, %{
                source: source.destination_ref,
                passphrase: source.passphrase,
                new_password: password
              })
            end
          end
        )

      if fault not in [:admission, :wrong_passphrase, :preflight] do
        assert_native_denial_error!(retry, :conflict, false)
        retry_events = task11_events(retry_ref)

        expected = [
          {:entered, :maintenance},
          {:returned, :maintenance, :ok},
          {:entered, :admission},
          {:returned, :admission, {:error, :conflict, false}}
        ]

        actual = for {:trace, event} <- retry_events, do: event
        assert actual == expected, "nonempty whole Runtime continuation reached authentication"
        task11_assert_custody!(retry_events)

        assert :ok =
                 KnowledgeRestoreOracle.assert_installation_unchanged!(
                   snapshot,
                   MigrationRepo,
                   fixture.destination.object_root
                 )

        task11_phase(:same_target_retry, :returned)
      end
    end

    :ok
  end

  defp task11_committed_storage_replay!(source, portable_root, fixture, initial_verified) do
    reference = make_ref()
    caller = self()

    record = fn event ->
      send(caller, {reference, :task11, event})
      :ok
    end

    root = fixture.destination.object_root
    snapshot = KnowledgeRestoreOracle.installation_snapshot!(MigrationRepo, root)

    {result, _seam} =
      KnowledgeBackupRestoreFixture.task11_with_fault_context!(
        fixture.destination,
        portable_root,
        source,
        :none,
        record,
        fn stage, _result -> record.({:checked, stage}) end,
        fn adapters ->
          {_module, native} = adapters.authenticator

          authenticated =
            take_ok!(
              KnowledgeBackupRestoreFixture.Task11Ports.authenticate_all(
                native,
                source.destination_ref,
                source.passphrase
              ),
              "fresh Storage imported replay authentication"
            )

          try do
            storage =
              {KnowledgeBackupRestoreFixture.Task11ImportedReadOnlyStorage,
               %{root: root, record: record}}

            restorer = Map.put(native.restorer, :object_storage, storage)

            imported =
              take_ok!(
                Singularity.Storage.Backup.Restorer.import(
                  restorer,
                  MigrationRepo,
                  Map.take(authenticated, [:binding, :cut, :verified])
                ),
                "same-target native Storage imported replay"
              )

            exact? =
              imported.manifest.manifest_id == source.operation_id and
                imported.manifest_hash == initial_verified.manifest_hash and
                imported.manifest_tag == initial_verified.manifest_tag and
                imported.cut == authenticated.cut and
                imported.object_inventory == source.original_inventory

            assert exact?,
                   "Task11 Storage replay changed the identical authenticated manifest or inventory"

            assert :ok = KnowledgeRestoreOracle.assert_saga_commitment!(source, root, imported)
            :ok
          after
            assert :ok =
                     Singularity.Runtime.RestoreAuthenticator.revoke(
                       native.authenticator,
                       authenticated
                     )
          end
        end
      )

    assert result == :ok, "Task11 exact native Storage imported replay did not succeed"
    events = task11_events(reference)
    assert Enum.count(events, &match?({:backup_lease, _, _}, &1)) == 1
    assert Enum.any?(events, &(&1 == :storage_replay_read))

    refute Enum.any?(events, &(&1 == :storage_replay_write_denied)),
           "Task11 imported replay attempted a physical write"

    refute Enum.any?(events, &match?({:integrity_capability, _, _}, &1)),
           "Task11 Storage replay issued rewrap authority"

    refute Enum.any?(events, &match?({:claimed_recovered_key, _}, &1)),
           "Task11 Storage replay claimed recovered-key authority"

    task11_assert_custody!(events)
    task11_assert_maintenance!()

    assert :ok =
             KnowledgeRestoreOracle.assert_installation_unchanged!(snapshot, MigrationRepo, root)

    :ok
  end

  defp task11_checks(source, root, password, record) do
    fn stage, result ->
      case {stage, result} do
        {:import, {:ok, imported}} ->
          expected =
            Map.update!(
              source.observation.rows,
              "core.vaults",
              &Enum.map(&1, fn row -> Map.put(row, "locked", true) end)
            )

          observed = Canonical.read_committed!(MigrationRepo, source.owner, imported.cut)
          assert :ok = Canonical.compare(expected, observed)
          assert_import_secrets_and_seals!(source)
          assert :ok = KnowledgeRestoreOracle.assert_saga_commitment!(source, root, imported)
          task11_assert_native_files!(source, root)
          record.({:imported, imported})

        {:rewrap, {:ok, rewrapped}} ->
          assert_rewrapped_password!(source, password)
          [original] = source.observation.rows["core.vault_key_wrappers"]
          generation? = rewrapped.owner.wrapper_generation == original["generation"] + 1
          assert generation?, "Task11 rewrap did not advance the actual source wrapper generation"

          owner_query(fn ->
            %{rows: [[generation, algorithm]]} =
              SafeSQL.query!(
                MigrationRepo,
                "SELECT generation,wrapper_algorithm FROM core.vault_key_wrappers WHERE id=$1",
                [Ecto.UUID.dump!(rewrapped.owner.vault_key_wrapper_id)]
              )

            exact? =
              generation == rewrapped.owner.wrapper_generation and algorithm != "restore_pending"

            assert exact?,
                   "Task11 committed rewrap reply lacks its real persisted wrapper generation"
          end)

          assert :ok = KnowledgeRestoreOracle.assert_saga_commitment!(source, root, rewrapped)
          record.({:rewrapped, rewrapped})

        {:reconcile, :ok} ->
          assert_reconciled_history!(source)

        {:plaintext, {:ok, %PlaintextSummary{} = summary}} ->
          assert_native_summary!(source, summary)

        _ ->
          :ok
      end

      record.({:checked, stage})
    end
  end

  defp task11_full_success!(source, portable_root, fixture) do
    reference = make_ref()
    caller = self()

    record = fn event ->
      send(caller, {reference, :task11, event})
      :ok
    end

    password = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    task11_phase(:native_restore, :begin)

    {result, _seam} =
      KnowledgeBackupRestoreFixture.task11_with_fault_context!(
        fixture.destination,
        portable_root,
        source,
        :none,
        record,
        task11_checks(source, fixture.destination.object_root, password, record),
        fn context ->
          RestoreVault.run(context, %{
            source: source.destination_ref,
            passphrase: source.passphrase,
            new_password: password
          })
        end
      )

    success? = result == {:ok, %{manifest_id: source.operation_id}}
    assert success?, "Task11 fresh native Runtime restore did not fully complete"
    events = task11_events(reference)
    trace = for {:trace, event} <- events, do: event
    expected = Enum.flat_map(@task11_stages, &[{:entered, &1}, {:returned, &1, :ok}])
    assert trace == expected, "Task11 success omitted or duplicated a native saga stage"
    checked = for {:checked, stage} <- events, do: stage
    assert checked == @task11_stages, "Task11 success missed full independent stage evidence"
    assert Enum.count(events, &match?({:backup_lease, _, _}, &1)) == 1
    assert Enum.count(events, &match?({:integrity_capability, _, _}, &1)) == 1
    assert Enum.count(events, &match?({:claimed_recovered_key, _}, &1)) == 1
    task11_assert_custody!(events)
    task11_assert_document_arguments!(source, events)
    task11_assert_maintenance!()
    task11_assert_completion!(source, true, true, true)
    assert_reconciled_history!(source)
    task11_phase(:native_restore, :returned)
    task11_phase(:controlled_runtime, :begin)

    runtime =
      KnowledgeBackupRestoreFixture.start_controlled_runtime!(fixture.owner, fixture.destination)

    task11_phase(:controlled_runtime, :returned)
    task11_phase(:login, :begin)
    session = NativeAssetFixture.login!(%{source.credentials | password: password})
    assert session.unlocked?
    task11_phase(:login, :returned)
    task11_phase(:native_originals, :begin)

    assert :ok =
             KnowledgeRestoreOracle.assert_originals!(
               session,
               KnowledgeBackupRestoreFixture.retained_originals!(source)
             )

    task11_phase(:native_originals, :returned)
    task11_phase(:public_originals, :begin)
    task11_assert_public_originals!(source, session)
    task11_phase(:public_originals, :returned)
    task11_phase(:public_search, :begin)
    assert :ok = KnowledgeRestoreOracle.assert_search!(session, source)
    task11_phase(:public_search, :returned)
    runtime
  end

  defp task11_assert_public_originals!(source, session) do
    for name <- [:empty, :plain, :unicode, :markdown] do
      original = Map.fetch!(source.sources, name)
      result = Api.download(session, original.asset_id, nil)

      exact? =
        case result do
          {:ok, %{body: bytes, content_length: size, status: 200}} ->
            bytes == original.bytes and size == byte_size(original.bytes)

          _ ->
            false
        end

      assert exact?, "Task11 public Asset original differs from actual retained upload bytes"
    end

    original =
      take_ok!(
        Api.download_document_original(session, source.ids.ready_document_id),
        "public retained PDF original"
      )

    expected = source.sources.pdf.bytes
    assert original.byte_size == byte_size(expected) and original.chunk_count == 1
    bytes = take_ok!(original.read_chunk.(0), "public retained PDF chunk")
    exact? = bytes == expected
    assert exact?, "Task11 public Document original differs from actual retained PDF upload bytes"
    :ok
  end

  defp task11_assert_custody!(events) do
    for {:backup_lease, pid, monitor} <- events do
      closed? =
        receive do
          {:DOWN, ^monitor, :process, ^pid, :normal} -> true
        after
          1_000 -> false
        end

      assert closed?, "Task11 actual backup custody did not close normally per attempt"
      refute Process.alive?(pid), "Task11 retained actual backup custody"
    end

    for {:integrity_capability, capability, monitor} <- events,
        do: assert_native_denial_capability_closed!(capability, monitor)

    for {:authenticated, authenticated} <- events do
      replay = authenticated.verified.replay
      closed? = replay.file_system.verify_snapshot.(replay.snapshot, replay.source_size) != :ok
      assert closed?, "Task11 retained a usable authenticated source snapshot"
    end

    for {:claimed_recovered_key, capability} <- events do
      refute Process.alive?(capability.lease),
             "Task11 claimed recovered-key authority is still live"

      assert :ok = Singularity.Storage.Crypto.RecoveredVaultKey.revoke(capability)
    end

    for {:integrity_owner_is_caller, correct?} <- events,
        do: assert(correct?, "Task11 native integrity authority changed caller ownership")
  end

  defp task11_assert_document_arguments!(source, events) do
    observations =
      for {:validated_documents, binding, inventory, hashes} <- events,
          do: {binding, inventory, hashes}

    for observation <- observations do
      expected =
        {%{manifest_id: source.operation_id, vault_id: source.owner.vault_id},
         source.original_inventory, native_denial_expected_hashes(source)}

      exact? = observation == expected
      assert exact?, "Task11 Document boundary lost native typed and validated plaintext evidence"
    end

    expected_count =
      if Enum.any?(events, &match?({:trace, {:entered, :documents}}, &1)), do: 1, else: 0

    assert length(observations) == expected_count,
           "Task11 missed or repeated native Document verification"
  end

  defp task11_assert_maintenance! do
    withheld? =
      Application.fetch_env!(:singularity_runtime, :maintenance_mode) == true and
        Application.fetch_env!(:singularity_runtime, :start_infrastructure) == false and
        Enum.all?(
          [
            Singularity.Runtime.KeyCustodian,
            Singularity.Runtime.OutboxDispatcher,
            Singularity.Runtime.Documents.ExtractionReconciler
          ],
          &is_nil(Process.whereis(&1))
        ) and is_nil(Oban.whereis(Singularity.Oban))

    assert withheld?, "Task11 fault exposed ordinary runtime, extraction or dispatch"
  end

  defp task11_assert_durable_fault!(source, fixture, fault, succeeded, seam) do
    imported? = :import in succeeded or fault == :commit_uncertainty
    rebuilt? = :rebuild in succeeded
    integrity? = :integrity_complete in succeeded
    completed? = :restore_complete in succeeded
    task11_assert_completion!(source, imported?, integrity?, completed?)

    if imported? do
      assert :ok =
               KnowledgeRestoreOracle.assert_saga_commitment!(
                 source,
                 fixture.destination.object_root,
                 seam.imported
               )

      exact_seals? = task11_seals!(source) == source.source_set_seals
      assert exact_seals?, "Task11 failure lost an exact immutable Note seal"
      task11_assert_imported_graph!(source, fixture.destination.object_root, succeeded)
    else
      empty? =
        Enum.all?(
          Canonical.read_committed!(MigrationRepo, source.owner, source.observation.cut),
          fn {_table, rows} -> rows == [] end
        )

      assert empty?, "Task11 pre-import fault retained canonical rows"

      if fault != :admission,
        do:
          assert(
            task11_files!(fixture.destination.object_root) == [],
            "Task11 rollback retained an owned stage, receipt or Object"
          )
    end

    owner_query(fn ->
      %{rows: [[knowledge, assets, notes]]} =
        SafeSQL.query!(
          MigrationRepo,
          "SELECT (SELECT count(*) FROM content.search_entries),(SELECT count(*) FROM content.asset_search_documents),(SELECT count(*) FROM content.note_search_documents)",
          []
        )

      actual? =
        if rebuilt?,
          do: knowledge > 0 and assets > 0 and notes > 0,
          else: knowledge == 0 and assets == 0 and notes == 0

      assert actual?, "Task11 projection publication did not match actual native rebuild"
    end)

    case fault do
      kind when kind in [:canonical, :empty_seal, :rewrap_sql] ->
        assert seam.sql_hits == 1

      :commit_uncertainty ->
        assert seam.commit_hits == 1
        assert seam.committed_result == {:ok, :imported}

      :before_publish ->
        assert seam.published == 0

      :after_publish ->
        assert seam.published == 1 and seam.verified_stat == 1 and seam.rolled_back == 1

      :rewrap_reply ->
        assert seam.reply_owned_cleanup? and seam.rewrap_calls == 1

      _ ->
        :ok
    end
  end

  defp task11_assert_imported_graph!(source, root, succeeded) do
    rows = Canonical.read_committed!(MigrationRepo, source.owner, source.observation.cut)

    mutable =
      ~w(identity.credentials identity.principals core.capabilities core.principal_capabilities core.vault_key_wrappers core.vault_members core.vaults audit.events core.outbox_events jobs.job_submissions)

    if :rewrap not in succeeded do
      expected =
        Map.update!(
          source.observation.rows,
          "core.vaults",
          &Enum.map(&1, fn row -> Map.put(row, "locked", true) end)
        )

      assert :ok = Canonical.compare(expected, rows)
      assert_import_secrets_and_seals!(source)
    end

    for {table, expected} <- source.observation.rows, table not in mutable do
      same? = Map.fetch!(rows, table) == expected
      assert same?, "Task11 failure changed immutable canonical rows in #{table}"
    end

    if :reconcile in succeeded do
      assert_reconciled_history!(source)
    else
      for table <-
            ~w(core.outbox_events jobs.job_submissions jobs.job_progress jobs.effect_receipts) do
        same? = rows[table] == source.observation.rows[table]
        assert same?, "Task11 fault committed durable work before actual reconciliation"
      end
    end

    task11_assert_native_files!(source, root)
  end

  defp task11_assert_native_files!(source, root) do
    expected_files =
      Enum.flat_map(KnowledgeRestoreOracle.projected_inventory!(source), fn entry ->
        witness = KnowledgeRestoreOracle.reference_witness!(root, entry)
        object_path = Path.join(root, witness.canonical_ref)
        mode = File.lstat!(object_path).mode
        assert mode == 0o100400, "Task11 imported native Object changed immutable permissions"

        {:ok, receipt} =
          Singularity.Storage.Local.PathGuard.finalization_receipt_path(
            root,
            entry.asset_object_id
          )

        receipt_stat = File.lstat!(receipt)

        assert receipt_stat.type == :regular and receipt_stat.mode == 0o100400,
               "Task11 native publication lost an immutable ownership receipt"

        [object_path, receipt]
      end)

    assert {:ok, []} = Singularity.Storage.LocalFilesystemAdapter.list_staged(%{root: root})
    exact_files? = Enum.sort(task11_files!(root)) == Enum.sort(expected_files)
    assert exact_files?, "Task11 native import retained missing or extra physical artifacts"
  end

  defp task11_assert_completion!(source, imported?, integrity?, completed?) do
    owner_query(fn ->
      %{rows: [[integrity_count, complete_count, completed_status, marker, admission]]} =
        SafeSQL.query!(
          MigrationRepo,
          """
          SELECT
            (SELECT count(*) FROM audit.events WHERE target_id=$1 AND operation='integrity.audit_completed'),
            (SELECT count(*) FROM audit.events WHERE target_id=$1 AND operation='backup.restore_completed'),
            (SELECT count(*) FROM audit.events WHERE target_id=$1 AND operation='backup.restore_completed' AND result='completed'),
            (SELECT state FROM audit.restore_import_sagas WHERE singleton),
            (SELECT state FROM audit.knowledge_restore_admissions WHERE singleton)
          """,
          [Ecto.UUID.dump!(source.operation_id)]
        )

      exact? =
        integrity_count == if(integrity?, do: 1, else: 0) and
          complete_count == if(completed?, do: 1, else: 0) and completed_status == complete_count

      assert exact?, "Task11 audit/status counts differ from real delegate completion"
      if imported?, do: assert(marker == "imported" and admission == "validated")
    end)
  end

  defp task11_seals!(source) do
    NativeAssetFixture.observe!(
      "SELECT note_resource_version_id::text,attachment_count,citation_count FROM content.note_source_set_seals WHERE vault_id=$1 ORDER BY note_resource_version_id",
      [Ecto.UUID.dump!(source.owner.vault_id)]
    ).rows
  end

  defp task11_files!(root) do
    for name <- File.ls!(root),
        path = Path.join(root, name),
        nested <- if(File.dir?(path), do: task11_files!(path), else: [path]),
        do: nested
  end

  defp task11_error(:admission), do: {:conflict, false}

  defp task11_error(fault) when fault in [:wrong_passphrase, :preflight, :plaintext_revoked],
    do: {:backup_invalid, false}

  defp task11_error(fault)
       when fault in [
              :canonical,
              :empty_seal,
              :before_publish,
              :after_publish,
              :commit_uncertainty,
              :rewrap_sql
            ],
       do: {:storage_unavailable, false}

  defp task11_error(_fault), do: {:storage_unavailable, true}

  defp task11_expected_trace(fault) do
    # Independent expected barriers; do not derive the oracle from the adapter.
    {stage, mode} =
      case fault do
        :admission ->
          {:admission, :native}

        :wrong_passphrase ->
          {:authentication, :native}

        kind
        when kind in [
               :preflight,
               :canonical,
               :empty_seal,
               :before_publish,
               :after_publish,
               :commit_uncertainty
             ] ->
          {:import, :native}

        :rewrap_sql ->
          {:rewrap, :native}

        :rewrap_reply ->
          {:rewrap, :after}

        :early_cipher ->
          {:early_cipher, :before}

        :reconcile_before ->
          {:reconcile, :before}

        :reconcile_after ->
          {:reconcile, :after}

        :final_cipher ->
          {:final_cipher, :before}

        :plaintext_revoked ->
          {:plaintext, :native}

        :plaintext_after ->
          {:plaintext, :after}

        :documents ->
          {:documents, :before}

        :rebuild_before ->
          {:rebuild, :before}

        :rebuild_after ->
          {:rebuild, :after}

        :integrity_before ->
          {:integrity_complete, :before}

        :integrity_after ->
          {:integrity_complete, :after}

        :restore_before ->
          {:restore_complete, :before}

        :restore_after ->
          {:restore_complete, :after}
      end

    prior = Enum.take_while(@task11_stages, &(&1 != stage))
    prefix = Enum.flat_map(prior, &[{:entered, &1}, {:returned, &1, :ok}])
    {code, retryable?} = task11_error(fault)

    ending =
      case mode do
        :before -> [{:entered, stage}]
        :after -> [{:entered, stage}, {:returned, stage, :ok}]
        :native -> [{:entered, stage}, {:returned, stage, {:error, code, retryable?}}]
      end

    prefix ++ ending
  end

  defp task11_events(reference, events \\ []) do
    receive do
      {^reference, :task11, event} -> task11_events(reference, [event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  # END Task11 actual Runtime fault order and honest continuation contracts.
end
