defmodule Singularity.Storage.RestoreReconciliationTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Storage.Backup.Reconciler
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.NoteFixtures

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
    raw_fixture = Fixtures.two_vaults!().one
    note = NoteFixtures.note_with_conflict_in_context!(raw_fixture)
    NoteFixtures.grant_password_change!(note)

    events =
      Enum.map(@note_lifecycle_events, fn _event_type -> Fixtures.outbox_event!(raw_fixture) end)

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

        Enum.zip(events, @note_lifecycle_events)
        |> Enum.each(fn {event, event_type} ->
          set_note_event!(event.id, event_type, note.resource_id, note.conflict_id)
          mark_restored_runner!(event.id)
          insert_submission!(event.id, "note_projection")
        end)

        restored_cut!(raw_fixture.vault_id, List.last(events).id)
      end)

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

  defp set_note_event!(event_id, event_type, resource_id, conflict_id)
       when event_type in ["note.conflict_created", "note.conflict_resolved"] do
    query!(
      MigrationRepo,
      """
      UPDATE core.outbox_events
      SET event_type = $2,
          required_capability = 'note.write',
          payload = jsonb_build_object(
            'resource_id', $3::uuid::text,
            'conflict_id', $4::uuid::text
          )
      WHERE id = $1
      """,
      [event_id, event_type, Ecto.UUID.dump!(resource_id), Ecto.UUID.dump!(conflict_id)]
    )
  end

  defp set_note_event!(event_id, event_type, resource_id, _conflict_id) do
    query!(
      MigrationRepo,
      """
      UPDATE core.outbox_events
      SET event_type = $2,
          required_capability = 'note.write',
          payload = jsonb_build_object('resource_id', $3::uuid::text)
      WHERE id = $1
      """,
      [event_id, event_type, Ecto.UUID.dump!(resource_id)]
    )
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
