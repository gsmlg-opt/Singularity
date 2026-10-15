defmodule Singularity.Storage.RestoreReconciliationTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.NoteSaveResult
  alias Singularity.Core.NoteSnapshot
  alias Singularity.Storage.Backup.Reconciler
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.KnowledgeFixtures
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.NoteFixtures
  alias Singularity.Storage.Postgres.NoteRepository
  alias Singularity.Storage.ScopedRepo

  @note_lifecycle_events ~w[
    note.current_changed
    note.conflict_created
    note.conflict_resolved
    note.deleted
    note.restored
  ]

  test "rejects a malformed restored cut" do
    assert {:error, %Singularity.Core.Error{code: :invalid}} =
             Reconciler.reconcile(MigrationRepo, %{})
  end

  test "restores note capabilities and resets every lifecycle event to current-state projection" do
    %{raw_fixture: raw_fixture, events: events, cut: cut} = restored_note_scenario!()

    assert :ok = reconcile(cut)
    assert :ok = reconcile(cut)

    Fixtures.with_owner(fn ->
      assert %{rows: [["note.export"], ["note.read"], ["note.write"]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT capability.name
                 FROM core.principal_capabilities AS assignment
                 JOIN core.capabilities AS capability ON capability.id = assignment.capability_id
                 WHERE assignment.principal_id = $1
                   AND assignment.vault_id = $2
                   AND assignment.revoked_at IS NULL
                   AND capability.name LIKE 'note.%'
                 ORDER BY capability.name
                 """,
                 [raw_fixture.principal_id, raw_fixture.vault_id]
               )

      Enum.each(events, &assert_note_event_reset/1)
    end)
  end

  test "invalid restored note envelopes roll back every event and submission reset" do
    %{events: events, cut: cut} = restored_note_scenario!()
    target = List.last(events)
    baseline = note_event_contract!(target.id)

    variants = [
      {:idempotency_key, "asset-retry:#{baseline.resource_id}:0:1"},
      {:required_capability, "asset.write"},
      {:envelope_version, 2},
      {:payload, Map.put(baseline.payload, "unexpected", Ecto.UUID.generate())},
      {:causation_id, nil}
    ]

    Enum.each(variants, fn {field, value} ->
      restore_note_event_contract!(target.id, baseline)
      corrupt_note_event_contract!(target.id, field, value)

      assert {:error, %Singularity.Core.Error{code: :integrity_failure}} = reconcile(cut)

      Enum.each(events, &assert_restored_runner_unchanged(&1.id))
    end)
  end

  test "preserves an unapplied effect after the restored Oban runner is lost" do
    fixture = Fixtures.two_vaults!().one
    event = Fixtures.outbox_event!(fixture)

    cut =
      Fixtures.with_owner(fn ->
        set_asset_state!(fixture.asset_id, "uploaded", 0)
        mark_restored_runner!(event.id)
        insert_submission!(event.id, "asset_verify")
        restored_cut!(fixture.vault_id, event.id)
      end)

    audit_count_before = audit_count(fixture.vault_id)

    assert :ok = reconcile(cut)

    Fixtures.with_owner(fn ->
      assert %{rows: [[nil, nil, nil, nil, nil]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT
                   event.claim_token,
                   event.claimed_until,
                   event.runner_job_id,
                   event.delivered_at,
                   submission.runner_job_id
                 FROM core.outbox_events AS event
                 JOIN jobs.job_submissions AS submission
                   ON submission.outbox_event_id = event.id
                 WHERE event.id = $1
                 """,
                 [event.id]
               )

      assert %{rows: [[nil, nil]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT retired_at, retirement_reason
                 FROM core.outbox_events
                 WHERE id = $1
                 """,
                 [event.id]
               )
    end)

    assert audit_count(fixture.vault_id) == audit_count_before
  end

  test "retires work whose effect is already reflected in canonical state" do
    fixture = Fixtures.two_vaults!().one
    event = Fixtures.outbox_event!(fixture)

    cut =
      Fixtures.with_owner(fn ->
        set_asset_state!(fixture.asset_id, "ready", 3)
        mark_restored_runner!(event.id)
        insert_submission!(event.id, "asset_verify")
        restored_cut!(fixture.vault_id, event.id)
      end)

    audit_count_before = audit_count(fixture.vault_id)

    assert :ok = reconcile(cut)
    assert_event_retired(event.id, "restore_effect_already_reflected")
    first_retired_at = retired_at(event.id)

    assert :ok = reconcile(cut)
    assert retired_at(event.id) == first_retired_at
    assert audit_count(fixture.vault_id) == audit_count_before
  end

  test "retires stale destructive asset cleanup without running it" do
    fixture = Fixtures.two_vaults!().one
    event = Fixtures.outbox_event!(fixture)

    cut =
      Fixtures.with_owner(fn ->
        set_asset_state!(fixture.asset_id, "ready", 0)

        query!(
          MigrationRepo,
          """
          UPDATE core.outbox_events
          SET event_type = 'asset.cleanup_requested',
              required_capability = 'asset.write'
          WHERE id = $1
          """,
          [event.id]
        )

        mark_restored_runner!(event.id)
        insert_submission!(event.id, "asset_cleanup")
        restored_cut!(fixture.vault_id, event.id)
      end)

    audit_count_before = audit_count(fixture.vault_id)

    assert :ok = reconcile(cut)
    assert_event_retired(event.id, "restore_stale_destructive")
    assert audit_count(fixture.vault_id) == audit_count_before
  end

  test "rolls back all changes when restored outbox contains a row beyond the cut" do
    fixture = Fixtures.two_vaults!().one
    first = Fixtures.outbox_event!(fixture)
    beyond_cut = Fixtures.outbox_event!(fixture)

    cut =
      Fixtures.with_owner(fn ->
        set_asset_state!(fixture.asset_id, "uploaded", 0)
        mark_restored_runner!(first.id)
        insert_submission!(first.id, "asset_verify")
        restored_cut!(fixture.vault_id, first.id)
      end)

    assert {:error, %Singularity.Core.Error{code: :integrity_failure}} = reconcile(cut)

    Fixtures.with_owner(fn ->
      assert %{rows: [["restored-runner", %DateTime{}, "restored-runner"]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT
                   event.runner_job_id,
                   event.delivered_at,
                   submission.runner_job_id
                 FROM core.outbox_events AS event
                 JOIN jobs.job_submissions AS submission
                   ON submission.outbox_event_id = event.id
                 WHERE event.id = $1
                 """,
                 [first.id]
               )

      assert %{rows: [[1]]} =
               query!(
                 MigrationRepo,
                 "SELECT count(*) FROM core.outbox_events WHERE id = $1",
                 [beyond_cut.id]
               )
    end)
  end

  test "rejects a cut whose high-water mark is not present in the restored vault" do
    fixture = Fixtures.two_vaults!().one
    event = Fixtures.outbox_event!(fixture)

    cut =
      Fixtures.with_owner(fn ->
        set_asset_state!(fixture.asset_id, "uploaded", 0)
        mark_restored_runner!(event.id)
        insert_submission!(event.id, "asset_verify")

        fixture.vault_id
        |> restored_cut!(event.id)
        |> Map.update!(:outbox_high_water_mark, &(&1 + 1))
      end)

    assert {:error, %Singularity.Core.Error{code: :integrity_failure}} = reconcile(cut)
    assert_restored_runner_unchanged(event.id)
  end

  test "keeps an exact effect receipt terminal instead of replaying it" do
    fixture = Fixtures.two_vaults!().one
    event = Fixtures.outbox_event!(fixture)

    cut =
      Fixtures.with_owner(fn ->
        set_asset_state!(fixture.asset_id, "uploaded", 0)
        mark_restored_runner!(event.id)
        insert_submission!(event.id, "asset_verify")
        insert_receipt!(event.id, "applied", 0)
        restored_cut!(fixture.vault_id, event.id)
      end)

    assert :ok = reconcile(cut)
    assert_event_retired(event.id, "restore_effect_already_reflected")

    Fixtures.with_owner(fn ->
      assert %{rows: [["applied", 0]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT result, entity_revision
                 FROM jobs.effect_receipts
                 WHERE submission_id = $1
                 """,
                 [event.id]
               )
    end)
  end

  test "rolls back when an effect receipt conflicts with its submission" do
    fixture = Fixtures.two_vaults!().one
    event = Fixtures.outbox_event!(fixture)

    cut =
      Fixtures.with_owner(fn ->
        set_asset_state!(fixture.asset_id, "uploaded", 0)
        mark_restored_runner!(event.id)
        insert_submission!(event.id, "asset_verify")
        insert_receipt!(event.id, "applied", 0, classification: "sensitive")
        restored_cut!(fixture.vault_id, event.id)
      end)

    assert {:error, %Singularity.Core.Error{code: :integrity_failure}} = reconcile(cut)
    assert_restored_runner_unchanged(event.id)
  end

  test "rolls back an event whose target classification conflicts" do
    fixture = Fixtures.two_vaults!().one
    event = Fixtures.outbox_event!(fixture)

    cut =
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          """
          UPDATE content.assets
          SET state = 'uploaded', classification = 'sensitive'
          WHERE id = $1
          """,
          [fixture.asset_id]
        )

        mark_restored_runner!(event.id)
        insert_submission!(event.id, "asset_verify")
        restored_cut!(fixture.vault_id, event.id)
      end)

    assert {:error, %Singularity.Core.Error{code: :integrity_failure}} = reconcile(cut)
    assert_restored_runner_unchanged(event.id)
  end

  test "preserves a resumable metadata checkpoint while replacing its missing runner" do
    fixture = Fixtures.two_vaults!().one
    event = Fixtures.outbox_event!(fixture)

    checkpoint = %{
      "asset_id" => Ecto.UUID.load!(fixture.asset_id),
      "job_id" => Ecto.UUID.load!(event.id),
      "next_chunk_index" => 2,
      "processing_revision" => 1,
      "protocol" => "asset_metadata_v1",
      "version" => 3,
      "vault_id" => Ecto.UUID.load!(fixture.vault_id)
    }

    cut =
      Fixtures.with_owner(fn ->
        set_asset_state!(fixture.asset_id, "processing", 1)
        set_event_type!(event.id, "asset.metadata_requested", "asset.read")
        mark_restored_runner!(event.id)
        insert_submission!(event.id, "asset_metadata")
        insert_progress!(event.id, "waiting_for_unlock", 1, 3, checkpoint)
        restored_cut!(fixture.vault_id, event.id)
      end)

    assert :ok = reconcile(cut)

    Fixtures.with_owner(fn ->
      assert %{rows: [[nil, nil, nil, "waiting_for_unlock", 1, 3, ^checkpoint]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT
                   event.runner_job_id,
                   event.delivered_at,
                   submission.runner_job_id,
                   progress.state,
                   progress.processing_revision,
                   progress.checkpoint_version,
                   progress.checkpoint
                 FROM core.outbox_events AS event
                 JOIN jobs.job_submissions AS submission
                   ON submission.outbox_event_id = event.id
                 JOIN jobs.job_progress AS progress
                   ON progress.submission_id = submission.id
                 WHERE event.id = $1
                 """,
                 [event.id]
               )
    end)
  end

  test "preserves an unapplied asset finalization" do
    fixture = Fixtures.two_vaults!().one
    event = Fixtures.outbox_event!(fixture)

    cut =
      Fixtures.with_owner(fn ->
        set_asset_state!(fixture.asset_id, "verified", 0)
        set_event_type!(event.id, "asset.finalize_requested", "asset.write")
        mark_restored_runner!(event.id)
        insert_submission!(event.id, "asset_finalize")
        restored_cut!(fixture.vault_id, event.id)
      end)

    assert :ok = reconcile(cut)

    Fixtures.with_owner(fn ->
      assert %{rows: [[nil, nil, nil, nil]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT
                   event.runner_job_id,
                   event.delivered_at,
                   submission.runner_job_id,
                   event.retired_at
                 FROM core.outbox_events AS event
                 JOIN jobs.job_submissions AS submission
                   ON submission.outbox_event_id = event.id
                 WHERE event.id = $1
                 """,
                 [event.id]
               )
    end)
  end

  test "retires the backup request that produced the restored manifest" do
    fixture = Fixtures.two_vaults!().one
    event = Fixtures.outbox_event!(fixture)
    manifest_id = Ecto.UUID.generate()

    cut =
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          """
          UPDATE core.outbox_events
          SET
            event_type = 'backup.requested',
            required_capability = 'backup.create',
            payload = jsonb_build_object('pending_manifest_id', $2::text)
          WHERE id = $1
          """,
          [event.id, manifest_id]
        )

        mark_restored_runner!(event.id)
        insert_submission!(event.id, "backup")
        restored_cut!(fixture.vault_id, event.id, manifest_id)
      end)

    assert :ok = reconcile(cut)
    assert_event_retired(event.id, "restore_effect_already_reflected")
  end

  test "preserves unapplied cleanup for an unreferenced orphan object" do
    fixture = Fixtures.two_vaults!().one
    event = Fixtures.outbox_event!(fixture)

    cut =
      Fixtures.with_owner(fn ->
        object_id = insert_object!(fixture, "orphan_pending", 0)
        set_asset_state!(fixture.asset_id, "deleted", 1)
        set_object_cleanup_event!(event.id, fixture.asset_id, object_id)
        mark_restored_runner!(event.id)
        insert_submission!(event.id, "object_cleanup")
        restored_cut!(fixture.vault_id, event.id)
      end)

    assert :ok = reconcile(cut)

    Fixtures.with_owner(fn ->
      assert %{rows: [[nil, nil, nil, nil, "orphan_pending", 0]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT
                   event.runner_job_id,
                   event.delivered_at,
                   submission.runner_job_id,
                   event.retired_at,
                   object.lifecycle,
                   object.lifecycle_revision
                 FROM core.outbox_events AS event
                 JOIN jobs.job_submissions AS submission
                   ON submission.outbox_event_id = event.id
                 JOIN content.asset_objects AS object
                   ON object.id = (event.payload ->> 'object_id')::uuid
                 WHERE event.id = $1
                 """,
                 [event.id]
               )
    end)
  end

  test "retires object cleanup when the object has a live reference" do
    fixture = Fixtures.two_vaults!().one
    event = Fixtures.outbox_event!(fixture)

    {cut, object_id} =
      Fixtures.with_owner(fn ->
        object_id = insert_object!(fixture, "available", 0)

        query!(
          MigrationRepo,
          """
          UPDATE content.assets
          SET state = 'ready', asset_object_id = $2
          WHERE id = $1
          """,
          [fixture.asset_id, object_id]
        )

        set_object_cleanup_event!(event.id, fixture.asset_id, object_id)
        mark_restored_runner!(event.id)
        insert_submission!(event.id, "object_cleanup")
        {restored_cut!(fixture.vault_id, event.id), object_id}
      end)

    assert :ok = reconcile(cut)
    assert_event_retired(event.id, "restore_stale_destructive")

    Fixtures.with_owner(fn ->
      assert %{rows: [["available", ^object_id]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT object.lifecycle, asset.asset_object_id
                 FROM content.asset_objects AS object
                 JOIN content.assets AS asset ON asset.asset_object_id = object.id
                 WHERE object.id = $1
                 """,
                 [object_id]
               )
    end)
  end

  test "rolls back malformed restored payloads" do
    fixture = Fixtures.two_vaults!().one
    event = Fixtures.outbox_event!(fixture)

    cut =
      Fixtures.with_owner(fn ->
        set_asset_state!(fixture.asset_id, "uploaded", 0)
        mark_restored_runner!(event.id)
        insert_submission!(event.id, "asset_verify")

        query!(
          MigrationRepo,
          "UPDATE core.outbox_events SET payload = '{}'::jsonb WHERE id = $1",
          [event.id]
        )

        restored_cut!(fixture.vault_id, event.id)
      end)

    assert {:error, %Singularity.Core.Error{code: :integrity_failure}} = reconcile(cut)
    assert_restored_runner_unchanged(event.id)
  end

  test "rolls back a cross-vault target" do
    fixtures = Fixtures.two_vaults!()
    event = Fixtures.outbox_event!(fixtures.one)

    cut =
      Fixtures.with_owner(fn ->
        set_asset_state!(fixtures.one.asset_id, "uploaded", 0)
        mark_restored_runner!(event.id)
        insert_submission!(event.id, "asset_verify")
        set_asset_payload!(event.id, fixtures.two.asset_id)
        restored_cut!(fixtures.one.vault_id, event.id)
      end)

    assert {:error, %Singularity.Core.Error{code: :integrity_failure}} = reconcile(cut)
    assert_restored_runner_unchanged(event.id)
  end

  test "rolls back an orphan target" do
    fixture = Fixtures.two_vaults!().one
    event = Fixtures.outbox_event!(fixture)

    cut =
      Fixtures.with_owner(fn ->
        set_asset_state!(fixture.asset_id, "uploaded", 0)
        mark_restored_runner!(event.id)
        insert_submission!(event.id, "asset_verify")
        set_asset_payload!(event.id, Ecto.UUID.dump!(Ecto.UUID.generate()))
        restored_cut!(fixture.vault_id, event.id)
      end)

    assert {:error, %Singularity.Core.Error{code: :integrity_failure}} = reconcile(cut)
    assert_restored_runner_unchanged(event.id)
  end

  test "rolls back progress that conflicts with a non-resumable job" do
    fixture = Fixtures.two_vaults!().one
    event = Fixtures.outbox_event!(fixture)

    cut =
      Fixtures.with_owner(fn ->
        set_asset_state!(fixture.asset_id, "uploaded", 0)
        mark_restored_runner!(event.id)
        insert_submission!(event.id, "asset_verify")
        insert_progress!(event.id, "running", 0, 1, %{})
        restored_cut!(fixture.vault_id, event.id)
      end)

    assert {:error, %Singularity.Core.Error{code: :integrity_failure}} = reconcile(cut)
    assert_restored_runner_unchanged(event.id)
  end

  for {event_type, job_type} <- [
        {"document.extraction_requested", "document_extract"},
        {"document.ready", "document_projection"},
        {"document.deleted", "document_projection"},
        {"document.restored", "document_projection"}
      ],
      cause <- [:null, :uuid] do
    test "reconciles #{event_type} as #{job_type} with raw #{cause} causation" do
      source = KnowledgeFixtures.source!()
      document = KnowledgeFixtures.document!(source)
      event_type = unquote(event_type)
      job_type = unquote(job_type)
      cause = if unquote(cause) == :null, do: nil, else: Ecto.UUID.dump!(Ecto.UUID.generate())
      event = document_event!(source, document, event_type, job_type, cause)
      canonical = document_canonical_rows!(source.vault_id)

      assert :ok = reconcile(event.cut)
      assert document_canonical_rows!(source.vault_id) === canonical

      after_first = document_work_rows!(source.vault_id)
      assert :ok = reconcile(event.cut)
      assert document_work_rows!(source.vault_id) === after_first
      assert document_canonical_rows!(source.vault_id) === canonical

      Fixtures.with_owner(fn ->
        assert %{rows: [[^cause, nil, nil, nil, nil, nil, nil, ^job_type]]} =
                 query!(
                   MigrationRepo,
                   """
                   SELECT e.causation_id,e.claim_token,e.claimed_until,e.runner_job_id,
                     e.delivered_at,e.retired_at,s.runner_job_id,s.job_type
                   FROM core.outbox_events e JOIN jobs.job_submissions s ON s.id=e.id
                   WHERE e.id=$1
                   """,
                   [event.id]
                 )
      end)

      event_id = Ecto.UUID.load!(event.id)
      expected_cause = Ecto.UUID.load!(cause || event.id)

      attrs =
        Fixtures.with_owner(fn ->
          %{rows: [[key, principal_epoch, owner_epoch]]} =
            query!(
              MigrationRepo,
              "SELECT idempotency_key,principal_authorization_epoch,vault_authorization_epoch FROM core.outbox_events WHERE id=$1",
              [event.id]
            )

          %{
            version: 1,
            job_id: event_id,
            job_type: job_type,
            idempotency_key: key,
            vault_id: Ecto.UUID.load!(source.vault_id),
            principal_id: Ecto.UUID.load!(source.principal_id),
            required_capability: "asset.read",
            principal_authorization_epoch: principal_epoch,
            vault_authorization_epoch: owner_epoch,
            classification: :private,
            correlation_id: event_id,
            causation_id: expected_cause,
            expected_entity_revision: 0,
            attempt: 0,
            payload: %{
              "resource_id" => Ecto.UUID.load!(document.resource_id),
              "resource_version_id" => Ecto.UUID.load!(document.resource_version_id)
            }
          }
        end)

      assert {:ok, envelope} = Singularity.Core.JobEnvelope.new(attrs)
      assert {:ok, encoded} = Singularity.Storage.Jobs.EnvelopeCodec.encode(envelope)
      assert encoded["causation_id"] == expected_cause
      assert {:ok, ^envelope} = Singularity.Storage.Jobs.EnvelopeCodec.decode(encoded)
      assert document_work_rows!(source.vault_id) === after_first
    end
  end

  for state <- ~w(extracting ready failed unsupported deleted_pending obsolete_generation) do
    test "Document #{state} work is retired without rewriting canonical history or waking twice" do
      source = KnowledgeFixtures.source!()
      document = KnowledgeFixtures.document!(source)

      event =
        document_event!(
          source,
          document,
          "document.extraction_requested",
          "document_extract",
          nil
        )

      state = unquote(state)

      Fixtures.with_owner(fn ->
        if state in ~w(extracting ready failed unsupported) do
          query!(
            MigrationRepo,
            "SELECT set_config('singularity.principal_id',$1,true),set_config('singularity.vault_id',$2,true)",
            [Ecto.UUID.load!(source.principal_id), Ecto.UUID.load!(source.vault_id)]
          )

          assert %{rows: [[1]]} =
                   query!(
                     MigrationRepo,
                     "SELECT (content.claim_document_extraction($1,0,$2,'plain_text',1)).attempt_generation",
                     [document.resource_version_id, event.id]
                   )

          if state == "ready" do
            locator = %{"version" => 1, "kind" => "text", "start_line" => 1, "end_line" => 1}

            {:ok, fragment} =
              Singularity.Core.DocumentFragment.new(%{
                resource_id: Ecto.UUID.load!(document.resource_id),
                resource_version_id: Ecto.UUID.load!(document.resource_version_id),
                owner_scope_id: Ecto.UUID.load!(source.vault_id),
                classification: :private,
                ordinal: 0,
                text: "restored document",
                locator: locator
              })

            query!(
              MigrationRepo,
              """
              INSERT INTO content.document_fragments
                (id,resource_id,resource_version_id,vault_id,classification,ordinal,text,digest,locator,inserted_at)
              VALUES($1,$2,$3,$4,'private',0,$5,$6,$7,clock_timestamp())
              """,
              [
                fragment.fragment_id,
                document.resource_id,
                document.resource_version_id,
                source.vault_id,
                fragment.text,
                fragment.digest,
                locator
              ]
            )

            query!(
              MigrationRepo,
              """
              UPDATE content.document_versions SET state='ready',extracted_text_digest=$2,
                attempt_finished_at=clock_timestamp() WHERE resource_version_id=$1
              """,
              [document.resource_version_id, fragment.digest]
            )
          end

          if state in ~w(failed unsupported) do
            query!(
              MigrationRepo,
              """
              UPDATE content.document_versions SET state=$2,failure_code=$3,
                attempt_finished_at=clock_timestamp() WHERE resource_version_id=$1
              """,
              [
                document.resource_version_id,
                state,
                if(state == "failed", do: "extractor_failed", else: "no_extractable_text")
              ]
            )
          end
        end

        if state == "deleted_pending",
          do:
            query!(
              MigrationRepo,
              "UPDATE content.resources SET deleted_at=clock_timestamp() WHERE id=$1",
              [document.resource_id]
            )

        if state == "obsolete_generation",
          do:
            query!(
              MigrationRepo,
              "UPDATE content.document_versions SET attempt_generation=1 WHERE resource_version_id=$1",
              [document.resource_version_id]
            )
      end)

      canonical = document_canonical_rows!(source.vault_id)
      assert :ok = reconcile(event.cut)

      reason =
        if state in ~w(deleted_pending obsolete_generation),
          do: "restore_stale_destructive",
          else: "restore_effect_already_reflected"

      assert_event_retired(event.id, reason)
      first = document_work_rows!(source.vault_id)
      assert :ok = reconcile(event.cut)
      assert document_work_rows!(source.vault_id) === first
      assert document_canonical_rows!(source.vault_id) === canonical
    end
  end

  for retired? <- [false, true],
      {field, invalid} <- [
        {:event_type, "document.unknown"},
        {:required_capability, "asset.write"},
        {:classification, "sensitive"},
        {:envelope_version, 2},
        {:idempotency_key, "document-extraction:wrong"},
        {:expected_entity_revision, 99},
        {:payload, %{"resource_id" => "foreign", "resource_version_id" => "foreign"}},
        {:payload, %{"resource_id" => "extra", "resource_version_id" => "extra", "extra" => true}}
      ] do
    test "invalid #{field}=#{inspect(invalid)} is checked before retired=#{retired?} shortcut and rolls back earlier work" do
      source = KnowledgeFixtures.source!()

      earlier =
        document_event!(
          source,
          KnowledgeFixtures.document!(source),
          "document.ready",
          "document_projection",
          nil
        )

      later =
        document_event!(
          source,
          KnowledgeFixtures.document!(source),
          "document.extraction_requested",
          "document_extract",
          nil
        )

      field = unquote(field)
      invalid = unquote(Macro.escape(invalid))

      Fixtures.with_owner(fn ->
        query!(MigrationRepo, "UPDATE core.outbox_events SET #{field}=$2 WHERE id=$1", [
          later.id,
          invalid
        ])

        mirror_document_submission!(field, later.id, invalid)

        if unquote(retired?),
          do:
            query!(
              MigrationRepo,
              """
              UPDATE core.outbox_events SET retired_at=clock_timestamp(),
                retirement_reason='restore_effect_already_reflected' WHERE id=$1
              """,
              [later.id]
            )
      end)

      canonical = document_canonical_rows!(source.vault_id)
      work = document_work_rows!(source.vault_id)
      assert {:error, %Singularity.Core.Error{code: :integrity_failure}} = reconcile(later.cut)
      assert document_work_rows!(source.vault_id) === work
      assert document_canonical_rows!(source.vault_id) === canonical
      assert_restored_runner_unchanged(earlier.id)
    end
  end

  test "an exact old-head extraction is destructive even though its own generation and authority are valid" do
    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)

    event =
      document_event!(source, document, "document.extraction_requested", "document_extract", nil)

    Fixtures.with_owner(fn ->
      successor = Ecto.UUID.dump!(Ecto.UUID.generate())

      query!(
        MigrationRepo,
        """
        INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision)
        VALUES($1,$2,$3,'private',1)
        """,
        [successor, document.resource_id, source.vault_id]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO content.document_versions SELECT (jsonb_populate_record(NULL::content.document_versions,
          to_jsonb(d)||jsonb_build_object('resource_version_id',$2::uuid))).*
        FROM content.document_versions d WHERE resource_version_id=$1
        """,
        [document.resource_version_id, successor]
      )

      query!(MigrationRepo, "UPDATE content.resources SET current_version_id=$2 WHERE id=$1", [
        document.resource_id,
        successor
      ])
    end)

    canonical = document_canonical_rows!(source.vault_id)
    assert :ok = reconcile(event.cut)
    assert_event_retired(event.id, "restore_stale_destructive")
    first = document_work_rows!(source.vault_id)
    assert :ok = reconcile(event.cut)
    assert document_work_rows!(source.vault_id) === first
    assert document_canonical_rows!(source.vault_id) === canonical
  end

  for type <- ~w(document.ready document.deleted document.restored) do
    test "#{type} projection wake uses final deleted state rather than resurrecting its serialized state" do
      source = KnowledgeFixtures.source!()
      {document, _fragment} = KnowledgeFixtures.ready_document!(source)

      Fixtures.with_owner(fn ->
        assert %{rows: [[ready_event_id]]} =
                 query!(
                   MigrationRepo,
                   """
                   SELECT id FROM core.outbox_events
                   WHERE event_type='document.ready' AND vault_id=$1
                     AND payload=jsonb_build_object('resource_id',$2::uuid::text,'resource_version_id',$3::uuid::text)
                   """,
                   [source.vault_id, document.resource_id, document.resource_version_id]
                 )

        assert %{num_rows: 1} = insert_submission!(ready_event_id, "document_projection")
      end)

      event = document_event!(source, document, unquote(type), "document_projection", nil)

      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "UPDATE content.resources SET deleted_at=clock_timestamp() WHERE id=$1",
          [document.resource_id]
        )
      end)

      canonical = document_canonical_rows!(source.vault_id)
      assert :ok = reconcile(event.cut)

      Fixtures.with_owner(fn ->
        assert %{rows: [[nil, nil, nil, nil, nil, "document_projection"]]} =
                 query!(
                   MigrationRepo,
                   """
                   SELECT e.runner_job_id,e.delivered_at,e.retired_at,e.retirement_reason,s.runner_job_id,s.job_type
                   FROM core.outbox_events e JOIN jobs.job_submissions s ON s.id=e.id WHERE e.id=$1
                   """,
                   [event.id]
                 )

        # The established projection reconciler reads final canonical state;
        # all three valid wake labels remove a deleted head's derived rows.
        assert %{rows: [[0]]} =
                 query!(
                   MigrationRepo,
                   "SELECT content.reconcile_search_resource_internal($1,$2)",
                   [source.vault_id, document.resource_id]
                 )

        assert %{rows: [[0]]} =
                 query!(
                   MigrationRepo,
                   "SELECT count(*) FROM content.search_entries WHERE resource_id=$1",
                   [document.resource_id]
                 )
      end)

      first = document_work_rows!(source.vault_id)
      assert :ok = reconcile(event.cut)
      assert document_work_rows!(source.vault_id) === first
      assert document_canonical_rows!(source.vault_id) === canonical
    end
  end

  for retired? <- [false, true] do
    test "restored Document missing submission retired=#{retired?} rolls back earlier projection work" do
      source = KnowledgeFixtures.source!()

      earlier =
        document_event!(
          source,
          KnowledgeFixtures.document!(source),
          "document.ready",
          "document_projection",
          nil
        )

      later =
        document_event!(
          source,
          KnowledgeFixtures.document!(source),
          "document.extraction_requested",
          "document_extract",
          nil
        )

      Fixtures.with_owner(fn ->
        query!(MigrationRepo, "DELETE FROM jobs.job_submissions WHERE id=$1", [later.id])

        if unquote(retired?),
          do:
            query!(
              MigrationRepo,
              "UPDATE core.outbox_events SET retired_at=clock_timestamp(),retirement_reason='restore_effect_already_reflected' WHERE id=$1",
              [later.id]
            )
      end)

      canonical = document_canonical_rows!(source.vault_id)
      work = document_work_rows!(source.vault_id)
      assert {:error, %Singularity.Core.Error{code: :integrity_failure}} = reconcile(later.cut)
      assert document_work_rows!(source.vault_id) === work
      assert document_canonical_rows!(source.vault_id) === canonical
      assert_restored_runner_unchanged(earlier.id)
    end
  end

  test "mismatched Document submission type or creator cannot reset any earlier event" do
    for fault <- [:job_type, :creator] do
      source = KnowledgeFixtures.source!()

      earlier =
        document_event!(
          source,
          KnowledgeFixtures.document!(source),
          "document.ready",
          "document_projection",
          nil
        )

      later =
        document_event!(
          source,
          KnowledgeFixtures.document!(source),
          "document.extraction_requested",
          "document_extract",
          nil
        )

      Fixtures.with_owner(fn ->
        case fault do
          :job_type ->
            query!(
              MigrationRepo,
              "UPDATE jobs.job_submissions SET job_type='document_projection' WHERE id=$1",
              [later.id]
            )

          :creator ->
            alternate = Ecto.UUID.dump!(Ecto.UUID.generate())

            query!(
              MigrationRepo,
              """
              INSERT INTO identity.principals(id,account_id,kind,authorization_epoch)
              SELECT $2,account_id,'owner',authorization_epoch FROM identity.principals WHERE id=$1
              """,
              [source.principal_id, alternate]
            )

            query!(
              MigrationRepo,
              "INSERT INTO core.vault_members(principal_id,vault_id) VALUES($1,$2)",
              [alternate, source.vault_id]
            )

            query!(MigrationRepo, "UPDATE core.outbox_events SET principal_id=$2 WHERE id=$1", [
              later.id,
              alternate
            ])
        end
      end)

      before = document_work_rows!(source.vault_id)
      assert {:error, %Singularity.Core.Error{code: :integrity_failure}} = reconcile(later.cut)
      assert document_work_rows!(source.vault_id) === before
      assert_restored_runner_unchanged(earlier.id)
    end
  end

  defmodule RawContractSQL do
    alias Ecto.Adapters.Postgres.Connection, as: Native
    alias Singularity.Storage.RestoreReconciliationTest, as: Owner

    for {name, arity} <- Native.__info__(:functions), {name, arity} != {:query, 4} do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(unquote_splicing(args)),
        do: apply(Native, unquote(name), [unquote_splicing(args)])
    end

    def query(connection, statement, parameters, options) do
      # UUID and nonnegative-epoch storage cannot natively return these bad
      # values. This is an INJECTED_CONTRACT_FAULT after the actual native SQL.
      native = Native.query(connection, statement, parameters, options)
      config = Process.get({Owner, :raw_fault})

      case {config, native} do
        {%{event: event, field: field, value: value},
         {:ok, %{columns: columns, rows: rows} = result}}
        when is_list(columns) and is_list(rows) ->
          position = Enum.find_index(columns, &(&1 == field))
          identity = Enum.find_index(columns, &(&1 == "id"))
          query = IO.iodata_to_binary(statement)

          selected? =
            position != nil and
              String.contains?(query, Map.get(config, :table, "core.outbox_events")) and
              (event in parameters or
                 (identity != nil and Enum.any?(rows, &(Enum.at(&1, identity) == event))))

          if selected? do
            changed =
              Enum.map(rows, fn row ->
                if identity == nil or Enum.at(row, identity) == event,
                  do: List.replace_at(row, position, value),
                  else: row
              end)

            {:ok, %{rows: witness}} =
              Native.query(
                connection,
                """
                SELECT pg_backend_pid(),session_user,current_user,
                  NULLIF(current_setting('singularity.principal_id',true),''),
                  NULLIF(current_setting('singularity.vault_id',true),'')
                """,
                [],
                options
              )

            {:ok, %{rows: earlier}} =
              Native.query(
                connection,
                "SELECT runner_job_id,delivered_at FROM core.outbox_events WHERE id=$1",
                [config.earlier],
                options
              )

            Process.put({Owner, :raw_observed}, %{
              native: native,
              injected: changed,
              field: field,
              witness: witness,
              earlier: earlier
            })

            {:ok, %{result | rows: changed}}
          else
            native
          end

        _ ->
          native
      end
    end
  end

  defmodule RawContractRepo do
    alias Singularity.Storage.MigrationRepo
    alias Singularity.Storage.RestoreReconciliationTest.RawContractSQL
    def __adapter__, do: MigrationRepo.__adapter__()
    def get_dynamic_repo, do: MigrationRepo.get_dynamic_repo()
    def in_transaction?, do: MigrationRepo.in_transaction?()
    def rollback(reason), do: MigrationRepo.rollback(reason)
    def checkout(callback, options \\ []), do: MigrationRepo.checkout(callback, options)

    def transaction(callback, options \\ []) do
      {:ok, address} = Agent.start_link(fn -> nil end, name: __MODULE__)

      try do
        native = Ecto.Adapter.lookup_meta(MigrationRepo.get_dynamic_repo())
        true = native.sql == Ecto.Adapters.Postgres.Connection
        :ok = Ecto.Repo.Registry.associate(address, __MODULE__, %{native | sql: RawContractSQL})
        true = Map.delete(Ecto.Adapter.lookup_meta(__MODULE__), :sql) === Map.delete(native, :sql)

        MigrationRepo.checkout(fn ->
          result = MigrationRepo.transaction(callback, options)

          witness =
            Singularity.Storage.SafeSQL.query!(MigrationRepo, """
            SELECT pg_backend_pid(),session_user,current_user,
              NULLIF(current_setting('singularity.principal_id',true),''),
              NULLIF(current_setting('singularity.vault_id',true),'')
            """).rows

          Process.put({Singularity.Storage.RestoreReconciliationTest, :raw_exit}, witness)
          result
        end)
      after
        Agent.stop(address)
        await_cleanup(address, System.monotonic_time(:millisecond) + 5_000)
      end
    end

    defp await_cleanup(address, deadline) do
      if :ets.lookup(Ecto.Repo.Registry, address) != [] do
        if System.monotonic_time(:millisecond) >= deadline,
          do: raise("raw SQL alias cleanup timed out")

        receive do
        after
          1 -> await_cleanup(address, deadline)
        end
      end

      :ok
    end
  end

  for {field, value} <- [
        {"correlation_id", nil},
        {"correlation_id", "not-a-uuid"},
        {"causation_id", false},
        {"causation_id", "not-a-uuid"},
        {"principal_authorization_epoch", -1},
        {"vault_authorization_epoch", "0"},
        {"retired_at", nil},
        {"retirement_reason", nil}
      ] do
    test "INJECTED_CONTRACT_FAULT raw #{field}=#{inspect(value)} validates the native result before codec or retirement" do
      source = KnowledgeFixtures.source!()

      earlier =
        document_event!(
          source,
          KnowledgeFixtures.document!(source),
          "document.ready",
          "document_projection",
          nil
        )

      later =
        document_event!(
          source,
          KnowledgeFixtures.document!(source),
          "document.extraction_requested",
          "document_extract",
          nil
        )

      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "UPDATE core.outbox_events SET retired_at=clock_timestamp(),retirement_reason='restore_effect_already_reflected' WHERE id=$1",
          [later.id]
        )
      end)

      work = document_work_rows!(source.vault_id)
      canonical = document_canonical_rows!(source.vault_id)
      {:ok, repo} = MigrationRepo.start_link(pool_size: 2)
      refute Process.get({__MODULE__, :raw_fault})

      Process.put({__MODULE__, :raw_fault}, %{
        event: later.id,
        earlier: earlier.id,
        field: unquote(field),
        value: unquote(value)
      })

      try do
        assert {:error, %Singularity.Core.Error{code: :integrity_failure}} =
                 Reconciler.reconcile(RawContractRepo, later.cut)

        assert %{native: {:ok, %{rows: native}}, injected: injected, field: field} =
                 Process.get({__MODULE__, :raw_observed})

        assert field == unquote(field)
        refute native === injected
        assert_raw_native_exit!()
      after
        Process.delete({__MODULE__, :raw_fault})
        Process.delete({__MODULE__, :raw_observed})
        Process.delete({__MODULE__, :raw_exit})
        Supervisor.stop(repo)
      end

      refute Process.whereis(RawContractRepo)
      assert document_work_rows!(source.vault_id) === work
      assert document_canonical_rows!(source.vault_id) === canonical
      assert_restored_runner_unchanged(earlier.id)
    end
  end

  for {field, value} <- [
        {"id", <<0::128>>},
        {"vault_id", <<0::128>>},
        {"outbox_event_id", <<0::128>>},
        {"classification", "sensitive"},
        {"idempotency_key", "foreign-request"},
        {"job_type", "document_projection"}
      ] do
    test "INJECTED_CONTRACT_FAULT matching Document submission checks #{field} on a genuine native row" do
      source = KnowledgeFixtures.source!()

      earlier =
        document_event!(
          source,
          KnowledgeFixtures.document!(source),
          "document.ready",
          "document_projection",
          nil
        )

      later =
        document_event!(
          source,
          KnowledgeFixtures.document!(source),
          "document.extraction_requested",
          "document_extract",
          nil
        )

      work = document_work_rows!(source.vault_id)
      canonical = document_canonical_rows!(source.vault_id)
      {:ok, repo} = MigrationRepo.start_link(pool_size: 2)

      Process.put({__MODULE__, :raw_fault}, %{
        event: later.id,
        earlier: earlier.id,
        field: unquote(field),
        value: unquote(value),
        table: "jobs.job_submissions"
      })

      try do
        assert {:error, %Singularity.Core.Error{code: :integrity_failure}} =
                 Reconciler.reconcile(RawContractRepo, later.cut)

        assert %{native: {:ok, %{rows: native}}, injected: injected, earlier: [[nil, nil]]} =
                 Process.get({__MODULE__, :raw_observed})

        refute native === injected
        assert_raw_native_exit!()
      after
        Process.delete({__MODULE__, :raw_fault})
        Process.delete({__MODULE__, :raw_observed})
        Process.delete({__MODULE__, :raw_exit})
        Supervisor.stop(repo)
      end

      refute Process.whereis(RawContractRepo)
      assert document_work_rows!(source.vault_id) === work
      assert document_canonical_rows!(source.vault_id) === canonical
      assert_restored_runner_unchanged(earlier.id)
    end
  end

  test "real foreign Document UUID payload is not a malformed-string substitute for cross-owner denial" do
    source = KnowledgeFixtures.source!()
    foreign = KnowledgeFixtures.source!()
    foreign_document = KnowledgeFixtures.document!(foreign)

    earlier =
      document_event!(
        source,
        KnowledgeFixtures.document!(source),
        "document.ready",
        "document_projection",
        nil
      )

    later =
      document_event!(
        source,
        KnowledgeFixtures.document!(source),
        "document.extraction_requested",
        "document_extract",
        nil
      )

    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "UPDATE core.outbox_events SET payload=$2 WHERE id=$1", [
        later.id,
        %{
          "resource_id" => Ecto.UUID.load!(foreign_document.resource_id),
          "resource_version_id" => Ecto.UUID.load!(foreign_document.resource_version_id)
        }
      ])
    end)

    canonical = document_canonical_rows!(source.vault_id)
    foreign_canonical = document_canonical_rows!(foreign.vault_id)
    work = document_work_rows!(source.vault_id)
    assert {:error, %Singularity.Core.Error{code: :integrity_failure}} = reconcile(later.cut)
    assert document_work_rows!(source.vault_id) === work
    assert document_canonical_rows!(source.vault_id) === canonical
    assert document_canonical_rows!(foreign.vault_id) === foreign_canonical
    assert_restored_runner_unchanged(earlier.id)
  end

  defp mirror_document_submission!(:idempotency_key, event, value) do
    query!(MigrationRepo, "UPDATE jobs.job_submissions SET idempotency_key=$2 WHERE id=$1", [
      event,
      value
    ])
  end

  defp mirror_document_submission!(:classification, event, value) do
    query!(MigrationRepo, "UPDATE jobs.job_submissions SET classification=$2 WHERE id=$1", [
      event,
      value
    ])
  end

  defp mirror_document_submission!(_field, _event, _value), do: :ok

  defp assert_raw_native_exit! do
    assert %{witness: [[backend, login, "singularity_table_owner", nil, nil]]} =
             Process.get({__MODULE__, :raw_observed})

    assert [[^backend, ^login, ^login, nil, nil]] = Process.get({__MODULE__, :raw_exit})
    refute MigrationRepo.in_transaction?()
  end

  defp document_event!(source, document, type, job_type, cause) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO core.capabilities(id,name) VALUES($1,'asset.read') ON CONFLICT(name) DO NOTHING",
        [Ecto.UUID.dump!(Ecto.UUID.generate())]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id)
        SELECT $1,$2,id FROM core.capabilities WHERE name='asset.read'
        ON CONFLICT (principal_id,vault_id,capability_id) DO NOTHING
        """,
        [source.principal_id, source.vault_id]
      )

      id = Ecto.UUID.dump!(Ecto.UUID.generate())

      key =
        if type == "document.extraction_requested",
          do: "document-extraction:#{Ecto.UUID.load!(document.resource_version_id)}",
          else: "document-projection:#{Ecto.UUID.load!(id)}"

      query!(
        MigrationRepo,
        """
        INSERT INTO core.outbox_events(id,event_type,idempotency_key,vault_id,principal_id,
          required_capability,principal_authorization_epoch,vault_authorization_epoch,
          classification,correlation_id,causation_id,expected_entity_revision,envelope_version,payload,occurred_at)
        SELECT $1,$2,$3,$4,$5,'asset.read',p.authorization_epoch,v.authorization_epoch,
          'private',$1,$6,0,1,$7,clock_timestamp()
        FROM identity.principals p CROSS JOIN core.vaults v WHERE p.id=$5 AND v.id=$4
        """,
        [
          id,
          type,
          key,
          source.vault_id,
          source.principal_id,
          cause,
          %{
            "resource_id" => Ecto.UUID.load!(document.resource_id),
            "resource_version_id" => Ecto.UUID.load!(document.resource_version_id)
          }
        ]
      )

      mark_restored_runner!(id)
      insert_submission!(id, job_type)
      %{id: id, cut: restored_cut!(source.vault_id, id)}
    end)
  end

  defp document_canonical_rows!(owner) do
    Fixtures.with_owner(fn ->
      Map.new(
        [
          {"content.resources", "id"},
          {"content.resource_versions", "id"},
          {"content.document_versions", "resource_version_id"},
          {"content.document_fragments", "id"},
          {"content.document_import_receipts", "principal_id,mutation_id"}
        ],
        fn {table, order} ->
          {table,
           query!(MigrationRepo, "SELECT * FROM #{table} WHERE vault_id=$1 ORDER BY #{order}", [
             owner
           ]).rows}
        end
      )
    end)
  end

  defp document_work_rows!(owner) do
    Fixtures.with_owner(fn ->
      Map.new(
        [
          "core.outbox_events",
          "jobs.job_submissions",
          "jobs.job_progress",
          "jobs.effect_receipts"
        ],
        fn table ->
          {table,
           query!(MigrationRepo, "SELECT * FROM #{table} WHERE vault_id=$1 ORDER BY id", [owner]).rows}
        end
      )
    end)
  end

  defp reconcile(cut) do
    {:ok, repo} = MigrationRepo.start_link(pool_size: 2)

    try do
      Reconciler.reconcile(MigrationRepo, cut)
    after
      Supervisor.stop(repo)
    end
  end

  defp set_asset_state!(asset_id, state, revision) do
    query!(
      MigrationRepo,
      "UPDATE content.assets SET state = $2, state_revision = $3 WHERE id = $1",
      [asset_id, state, revision]
    )
  end

  defp mark_restored_runner!(event_id) do
    query!(
      MigrationRepo,
      """
      UPDATE core.outbox_events
      SET
        runner_job_id = 'restored-runner',
        delivered_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
      WHERE id = $1
      """,
      [event_id]
    )
  end

  defp insert_submission!(event_id, job_type) do
    query!(
      MigrationRepo,
      """
      INSERT INTO jobs.job_submissions (
        id,
        vault_id,
        outbox_event_id,
        classification,
        idempotency_key,
        job_type,
        runner_job_id
      )
      SELECT
        id,
        vault_id,
        id,
        classification,
        idempotency_key,
        $2,
        'restored-runner'
      FROM core.outbox_events
      WHERE id = $1
      """,
      [event_id, job_type]
    )
  end

  defp insert_receipt!(event_id, result, entity_revision, options \\ []) do
    classification = Keyword.get(options, :classification, "private")

    query!(
      MigrationRepo,
      """
      INSERT INTO jobs.effect_receipts (
        id,
        vault_id,
        submission_id,
        classification,
        effect_key,
        result,
        entity_revision
      )
      SELECT
        $2,
        vault_id,
        id,
        $3,
        idempotency_key,
        $4,
        $5
      FROM jobs.job_submissions
      WHERE id = $1
      """,
      [event_id, Ecto.UUID.dump!(Ecto.UUID.generate()), classification, result, entity_revision]
    )
  end

  defp insert_progress!(event_id, state, processing_revision, checkpoint_version, checkpoint) do
    query!(
      MigrationRepo,
      """
      INSERT INTO jobs.job_progress (
        id,
        vault_id,
        submission_id,
        classification,
        state,
        processing_revision,
        checkpoint_version,
        checkpoint
      )
      SELECT
        $2,
        vault_id,
        id,
        classification,
        $3,
        $4,
        $5,
        $6::text::jsonb
      FROM jobs.job_submissions
      WHERE id = $1
      """,
      [
        event_id,
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        state,
        processing_revision,
        checkpoint_version,
        JSON.encode!(checkpoint)
      ]
    )
  end

  defp set_event_type!(event_id, event_type, required_capability) do
    query!(
      MigrationRepo,
      """
      UPDATE core.outbox_events
      SET event_type = $2, required_capability = $3
      WHERE id = $1
      """,
      [event_id, event_type, required_capability]
    )
  end

  defp restored_note_scenario! do
    raw_fixture = Fixtures.two_vaults!().one
    fixture = load_fixture_ids(raw_fixture)
    NoteFixtures.grant_password_change!(fixture)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO core.capabilities(id, name) VALUES($1, 'note.write') ON CONFLICT(name) DO NOTHING",
        [Ecto.UUID.dump!(Ecto.UUID.generate())]
      )

      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 """
                 INSERT INTO core.principal_capabilities(principal_id, vault_id, capability_id)
                 SELECT $1, $2, id FROM core.capabilities WHERE name = 'note.write'
                 """,
                 [raw_fixture.principal_id, raw_fixture.vault_id]
               )
    end)

    {:ok, %NoteSaveResult{} = created} =
      scoped_note(fixture, &NoteRepository.create(&1, create_intent(fixture)))

    {:ok, %NoteSaveResult{} = saved} =
      scoped_note(
        fixture,
        &NoteRepository.save(
          &1,
          save_intent(fixture, created.resource_id, created.canonical_version_id, "canonical")
        )
      )

    {:ok, %NoteSaveResult{outcome: :conflict} = conflict} =
      scoped_note(
        fixture,
        &NoteRepository.save(
          &1,
          save_intent(fixture, created.resource_id, created.canonical_version_id, "competing")
        )
      )

    {:ok, %NoteSaveResult{} = merged} =
      scoped_note(
        fixture,
        &NoteRepository.merge(
          &1,
          merge_intent(fixture, created.resource_id, saved, conflict)
        )
      )

    {:ok, %{state: :tombstoned}} =
      scoped_note(
        fixture,
        &NoteRepository.tombstone(
          &1,
          tombstone_intent(fixture, created.resource_id, merged.canonical_version_id)
        )
      )

    {:ok, %{state: :restored}} =
      scoped_note(
        fixture,
        &NoteRepository.restore(&1, restore_intent(fixture, created.resource_id))
      )

    events = note_events!(raw_fixture.vault_id, created.resource_id)
    assert MapSet.new(events, & &1.event_type) == MapSet.new(@note_lifecycle_events)

    cut =
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          """
          DELETE FROM core.principal_capabilities AS assignment
          USING core.capabilities AS capability
          WHERE assignment.capability_id = capability.id
            AND assignment.principal_id = $1
            AND assignment.vault_id = $2
            AND capability.name LIKE 'note.%'
          """,
          [raw_fixture.principal_id, raw_fixture.vault_id]
        )

        assert %{rows: []} =
                 query!(
                   MigrationRepo,
                   """
                   SELECT capability.name
                   FROM core.principal_capabilities AS assignment
                   JOIN core.capabilities AS capability ON capability.id = assignment.capability_id
                   WHERE assignment.principal_id = $1
                     AND assignment.vault_id = $2
                     AND capability.name LIKE 'note.%'
                   """,
                   [raw_fixture.principal_id, raw_fixture.vault_id]
                 )

        Enum.each(events, fn event ->
          mark_restored_runner!(event.id)
          insert_submission!(event.id, "note_projection")
        end)

        restored_cut!(raw_fixture.vault_id, List.last(events).id)
      end)

    %{raw_fixture: raw_fixture, events: events, cut: cut}
  end

  defp create_intent(fixture) do
    {:ok, snapshot} =
      NoteSnapshot.initial(%{classification: :private, title: "created", markdown: "# created"})

    base_intent(fixture)
    |> Map.merge(%{
      mutation_id: Ecto.UUID.generate(),
      snapshot: snapshot,
      request_fingerprint: :crypto.hash(:sha256, "create")
    })
  end

  defp save_intent(fixture, resource_id, base_version_id, label) do
    {:ok, snapshot} =
      NoteSnapshot.normal(%{
        classification: :private,
        title: label,
        markdown: "# #{label}",
        parent_version_id: base_version_id
      })

    base_intent(fixture)
    |> Map.merge(%{
      mutation_id: Ecto.UUID.generate(),
      resource_id: resource_id,
      base_version_id: base_version_id,
      snapshot: snapshot,
      request_fingerprint: :crypto.hash(:sha256, label)
    })
  end

  defp merge_intent(fixture, resource_id, saved, conflict) do
    {:ok, snapshot} =
      NoteSnapshot.merge(%{
        classification: :private,
        title: "merged",
        markdown: "# merged",
        parent_version_id: saved.canonical_version_id,
        merge_parent_version_id: conflict.submitted_version_id
      })

    base_intent(fixture)
    |> Map.merge(%{
      mutation_id: Ecto.UUID.generate(),
      resource_id: resource_id,
      conflict_id: conflict.conflict_id,
      expected_current_version_id: saved.canonical_version_id,
      competing_version_id: conflict.submitted_version_id,
      snapshot: snapshot,
      request_fingerprint: :crypto.hash(:sha256, "merge")
    })
  end

  defp tombstone_intent(fixture, resource_id, version_id) do
    base_intent(fixture)
    |> Map.merge(%{
      mutation_id: Ecto.UUID.generate(),
      resource_id: resource_id,
      expected_current_version_id: version_id,
      request_fingerprint: :crypto.hash(:sha256, "tombstone")
    })
  end

  defp restore_intent(fixture, resource_id) do
    base_intent(fixture)
    |> Map.merge(%{
      mutation_id: Ecto.UUID.generate(),
      resource_id: resource_id,
      request_fingerprint: :crypto.hash(:sha256, "restore")
    })
  end

  defp base_intent(fixture),
    do: %{
      principal_id: fixture.principal_id,
      vault_id: fixture.vault_id,
      classification: :private,
      correlation_id: Ecto.UUID.generate()
    }

  defp scoped_note(fixture, callback) do
    ScopedRepo.transact(
      Singularity.Storage.RequestRepo,
      %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
      callback
    )
  end

  defp note_events!(vault_id, resource_id) do
    Fixtures.with_owner(fn ->
      %{rows: rows} =
        query!(
          MigrationRepo,
          """
          SELECT id, event_type
          FROM core.outbox_events
          WHERE vault_id = $1
            AND event_type = ANY($2)
            AND payload ->> 'resource_id' = $3
          ORDER BY sequence, id
          """,
          [vault_id, @note_lifecycle_events, resource_id]
        )

      Enum.map(rows, fn [id, event_type] -> %{id: id, event_type: event_type} end)
    end)
  end

  defp load_fixture_ids(fixture) do
    Map.new(fixture, fn
      {key, <<_::128>> = value} -> {key, Ecto.UUID.load!(value)}
      entry -> entry
    end)
  end

  defp note_event_contract!(event_id) do
    Fixtures.with_owner(fn ->
      %{rows: [[idempotency_key, capability, version, payload, causation_id]]} =
        query!(
          MigrationRepo,
          """
          SELECT idempotency_key, required_capability, envelope_version, payload, causation_id
          FROM core.outbox_events
          WHERE id = $1
          """,
          [event_id]
        )

      %{
        idempotency_key: idempotency_key,
        required_capability: capability,
        envelope_version: version,
        payload: payload,
        resource_id: payload["resource_id"],
        causation_id: causation_id
      }
    end)
  end

  defp restore_note_event_contract!(event_id, baseline) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE core.outbox_events SET idempotency_key=$2, required_capability=$3, envelope_version=$4, payload=$5, causation_id=$6 WHERE id=$1",
        [
          event_id,
          baseline.idempotency_key,
          baseline.required_capability,
          baseline.envelope_version,
          baseline.payload,
          baseline.causation_id
        ]
      )
    end)
  end

  defp corrupt_note_event_contract!(event_id, field, value) do
    column = Atom.to_string(field)

    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "UPDATE core.outbox_events SET #{column} = $2 WHERE id = $1", [
        event_id,
        value
      ])
    end)
  end

  defp insert_object!(fixture, lifecycle, lifecycle_revision) do
    key_domain_id = Ecto.UUID.dump!(Ecto.UUID.generate())
    object_id = Ecto.UUID.dump!(Ecto.UUID.generate())

    query!(
      MigrationRepo,
      """
      INSERT INTO core.key_domains (id, vault_id, classification)
      VALUES ($1, $2, 'private')
      """,
      [key_domain_id, fixture.vault_id]
    )

    query!(
      MigrationRepo,
      """
      INSERT INTO content.asset_objects (
        id,
        vault_id,
        key_domain_id,
        classification,
        lookup_digest,
        ciphertext_hash,
        plaintext_byte_size,
        ciphertext_byte_size,
        storage_ref,
        format_version,
        lifecycle,
        lifecycle_revision,
        retained_until
      ) VALUES (
        $1,
        $2,
        $3,
        'private',
        $4,
        $5,
        0,
        0,
        $6,
        1,
        $7,
        $8,
        CASE WHEN $7 = 'orphan_pending' THEN CURRENT_TIMESTAMP - interval '1 second' END
      )
      """,
      [
        object_id,
        fixture.vault_id,
        key_domain_id,
        :crypto.hash(:sha256, "lookup-#{Ecto.UUID.load!(object_id)}"),
        :crypto.hash(:sha256, "ciphertext-#{Ecto.UUID.load!(object_id)}"),
        "objects/#{Ecto.UUID.load!(object_id)}",
        lifecycle,
        lifecycle_revision
      ]
    )

    object_id
  end

  defp set_object_cleanup_event!(event_id, asset_id, object_id) do
    query!(
      MigrationRepo,
      """
      UPDATE core.outbox_events
      SET
        event_type = 'object.cleanup_requested',
        required_capability = 'object.cleanup',
        payload = jsonb_build_object(
          'asset_id', $2::uuid::text,
          'object_id', $3::uuid::text
        )
      WHERE id = $1
      """,
      [event_id, asset_id, object_id]
    )
  end

  defp set_asset_payload!(event_id, asset_id) do
    query!(
      MigrationRepo,
      """
      UPDATE core.outbox_events
      SET payload = jsonb_build_object('asset_id', $2::uuid::text)
      WHERE id = $1
      """,
      [event_id, asset_id]
    )
  end

  defp restored_cut!(vault_id, event_id, manifest_id \\ Ecto.UUID.generate()) do
    %{rows: [[outbox_high_water_mark]]} =
      query!(
        MigrationRepo,
        "SELECT sequence FROM core.outbox_events WHERE id = $1",
        [event_id]
      )

    %{
      manifest_id: manifest_id,
      outbox_high_water_mark: outbox_high_water_mark,
      vault_id: Ecto.UUID.load!(vault_id)
    }
  end

  defp assert_event_retired(event_id, reason) do
    Fixtures.with_owner(fn ->
      assert %{rows: [[%DateTime{}, ^reason, nil, nil, nil, nil, nil]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT
                   event.retired_at,
                   event.retirement_reason,
                   event.claim_token,
                   event.claimed_until,
                   event.runner_job_id,
                   event.delivered_at,
                   submission.runner_job_id
                 FROM core.outbox_events AS event
                 JOIN jobs.job_submissions AS submission
                   ON submission.outbox_event_id = event.id
                 WHERE event.id = $1
                 """,
                 [event_id]
               )
    end)
  end

  defp retired_at(event_id) do
    Fixtures.with_owner(fn ->
      %{rows: [[retired_at]]} =
        query!(
          MigrationRepo,
          "SELECT retired_at FROM core.outbox_events WHERE id = $1",
          [event_id]
        )

      retired_at
    end)
  end

  defp assert_restored_runner_unchanged(event_id) do
    Fixtures.with_owner(fn ->
      assert %{rows: [["restored-runner", %DateTime{}, "restored-runner", nil]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT
                   event.runner_job_id,
                   event.delivered_at,
                   submission.runner_job_id,
                   event.retired_at
                 FROM core.outbox_events AS event
                 JOIN jobs.job_submissions AS submission
                   ON submission.outbox_event_id = event.id
                 WHERE event.id = $1
                 """,
                 [event_id]
               )
    end)
  end

  defp assert_note_event_reset(event) do
    assert %{rows: [[nil, nil, nil, nil, nil, nil, nil]]} =
             query!(
               MigrationRepo,
               """
               SELECT
                 event.claim_token,
                 event.claimed_until,
                 event.runner_job_id,
                 event.delivered_at,
                 event.retired_at,
                 event.retirement_reason,
                 submission.runner_job_id
               FROM core.outbox_events AS event
               JOIN jobs.job_submissions AS submission ON submission.outbox_event_id = event.id
               WHERE event.id = $1
               """,
               [event.id]
             )
  end

  defp audit_count(vault_id) do
    Fixtures.with_owner(fn ->
      %{rows: [[count]]} =
        query!(
          MigrationRepo,
          "SELECT count(*) FROM audit.events WHERE vault_id = $1",
          [vault_id]
        )

      count
    end)
  end
end
