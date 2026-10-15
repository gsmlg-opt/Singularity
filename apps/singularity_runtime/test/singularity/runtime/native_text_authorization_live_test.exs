defmodule Singularity.Runtime.NativeTextAuthorizationLiveTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Singularity.Core.{Error, ObjectRef, StageRef}
  alias Singularity.Runtime.{Authorize, JobDispatcher, NativeAssetFixture}

  alias Singularity.Storage.{
    LocalFilesystemAdapter,
    MigrationRepo,
    SafeSQL,
    ScopedRepo,
    WorkerRepo
  }

  alias Singularity.Storage.Jobs.EnvelopeCodec

  for media_type <- ["text/plain", "text/markdown"],
      mutation <- [:revoke_asset_write, :principal_epoch, :owner_epoch] do
    test "submitted #{media_type} finalization refuses live #{mutation} without publication" do
      media_type = unquote(media_type)
      mutation = unquote(mutation)

      NativeAssetFixture.with_fixture(fn fixture ->
        assert Application.fetch_env!(:singularity_storage, :job_handler) == JobDispatcher
        upload = NativeAssetFixture.upload!(fixture, media_type, ["# Owned original\r\n中\n"])
        NativeAssetFixture.verify!()

        # Submit while authority is still current. A dispatcher-only refusal
        # would not exercise the worker's point-of-use authorization.
        NativeAssetFixture.dispatch!()
        {runner_id, envelope} = submitted_finalization!(fixture, upload.asset_id)
        assert :ok = authorize_job(envelope)
        storage = sealed_storage!(fixture, upload.asset_id, media_type)
        before = snapshot(upload.asset_id, envelope.job_id)
        assert_no_finalization_effects!(upload.asset_id, envelope.job_id)

        corrupt_owned_authority!(mutation, envelope)

        assert authorize_job(envelope) == {:error, Error.new(:forbidden)}

        # GenericWorker deliberately hides the domain refusal behind a bounded
        # non-retryable cancellation; it must not succeed or retry this job.
        _summary = Oban.drain_queue(Singularity.Oban, queue: :asset_finalize)

        assert %{rows: [["cancelled", 1, true]]} =
                 NativeAssetFixture.observe!(
                   """
                   SELECT state, attempt, cancelled_at IS NOT NULL
                   FROM jobs.oban_jobs WHERE id = $1
                   """,
                   [runner_id]
                 )

        assert snapshot(upload.asset_id, envelope.job_id) == before
        assert_no_finalization_effects!(upload.asset_id, envelope.job_id)

        assert {:ok, stage_stat} =
                 LocalFilesystemAdapter.stat_stage(storage.context, storage.stage_ref)

        assert stage_stat == storage.stage_stat

        assert {:error, %Error{code: :not_found}} =
                 LocalFilesystemAdapter.stat(storage.context, storage.object_ref)

        assert NativeAssetFixture.repo_identities() == fixture.repositories
      end)
    end
  end

  defp submitted_finalization!(fixture, asset_id) do
    assert %{rows: [[runner_id, encoded]]} =
             NativeAssetFixture.observe!(
               """
               SELECT job.id, job.args
               FROM core.outbox_events event
               JOIN jobs.job_submissions submission ON submission.outbox_event_id = event.id
               JOIN jobs.oban_jobs job ON job.id::text = submission.runner_job_id
               WHERE event.event_type = 'asset.finalize_requested'
                 AND event.payload->>'asset_id' = $1
                 AND job.queue = 'asset_finalize' AND job.state = 'available'
                 AND job.attempt = 0
               """,
               [asset_id]
             )

    assert {:ok, envelope} = EnvelopeCodec.decode(encoded)
    assert envelope.job_type == "asset_finalize"
    assert envelope.required_capability == "asset.write"
    assert envelope.principal_id == fixture.session.principal_id
    assert envelope.vault_id == fixture.session.vault_id
    assert envelope.principal_authorization_epoch == fixture.session.principal_authorization_epoch
    assert envelope.vault_authorization_epoch == fixture.session.vault_authorization_epoch
    assert envelope.expected_entity_revision == 2
    assert envelope.classification == :private
    assert envelope.payload == %{"asset_id" => asset_id}
    {runner_id, envelope}
  end

  defp authorize_job(envelope) do
    dependencies = JobDispatcher.dependencies()

    ScopedRepo.transact(WorkerRepo, envelope, fn repo ->
      Authorize.check_job(dependencies.authorization, repo, envelope)
    end)
  end

  defp sealed_storage!(fixture, asset_id, media_type) do
    assert %{
             rows: [
               [
                 "verified",
                 2,
                 nil,
                 "sealed",
                 "pending",
                 "upload_text_v1",
                 ^media_type,
                 nil,
                 nil,
                 stage_id,
                 object_id,
                 owner_id,
                 domain_id,
                 lookup_digest
               ]
             ]
           } =
             NativeAssetFixture.observe!(
               """
               SELECT asset.state, asset.state_revision, asset.asset_object_id,
                 stage.state, metadata.extraction_state, metadata.extractor_version,
                 metadata.declared_media_type, metadata.detected_media_type,
                 metadata.completed_at, stage.id, stage.candidate_object_id,
                 stage.vault_id, stage.key_domain_id, stage.lookup_digest
               FROM content.assets asset
               JOIN content.asset_stages stage ON stage.asset_id = asset.id
               JOIN content.asset_metadata metadata ON metadata.asset_id = asset.id
               WHERE asset.id = $1
               """,
               [Ecto.UUID.dump!(asset_id)]
             )

    context = %{
      root: fixture.destination.object_root,
      vault_namespace: Ecto.UUID.load!(owner_id),
      domain_namespace: Ecto.UUID.load!(domain_id),
      lookup_digest: Base.encode16(lookup_digest, case: :lower)
    }

    stage_ref = %StageRef{stage_id: Ecto.UUID.load!(stage_id)}
    object_ref = %ObjectRef{object_id: Ecto.UUID.load!(object_id)}

    assert {:ok, %{sealed?: true} = stage_stat} =
             LocalFilesystemAdapter.stat_stage(context, stage_ref)

    assert {:error, %Error{code: :not_found}} = LocalFilesystemAdapter.stat(context, object_ref)
    %{context: context, stage_ref: stage_ref, object_ref: object_ref, stage_stat: stage_stat}
  end

  # These are negative-fixture mutations of exactly one acquired owner's row.
  # No authorization, custody or key adapter is substituted or restored.
  defp corrupt_owned_authority!(:revoke_asset_write, envelope) do
    assert %{num_rows: 1} =
             mutate_owned!(
               """
               UPDATE core.principal_capabilities assignment
               SET revoked_at = CURRENT_TIMESTAMP
               FROM core.capabilities capability
               WHERE assignment.capability_id = capability.id
                 AND assignment.principal_id = $1 AND assignment.vault_id = $2
                 AND capability.name = 'asset.write' AND assignment.revoked_at IS NULL
               """,
               [Ecto.UUID.dump!(envelope.principal_id), Ecto.UUID.dump!(envelope.vault_id)]
             )
  end

  defp corrupt_owned_authority!(:principal_epoch, envelope) do
    expected = envelope.principal_authorization_epoch + 1

    assert %{num_rows: 1, rows: [[^expected]]} =
             mutate_owned!(
               """
               UPDATE identity.principals SET authorization_epoch = authorization_epoch + 1
               WHERE id = $1 AND authorization_epoch = $2
               RETURNING authorization_epoch
               """,
               [Ecto.UUID.dump!(envelope.principal_id), envelope.principal_authorization_epoch]
             )
  end

  defp corrupt_owned_authority!(:owner_epoch, envelope) do
    expected = envelope.vault_authorization_epoch + 1

    assert %{num_rows: 1, rows: [[^expected]]} =
             mutate_owned!(
               """
               UPDATE core.vaults SET authorization_epoch = authorization_epoch + 1
               WHERE id = $1 AND authorization_epoch = $2
               RETURNING authorization_epoch
               """,
               [Ecto.UUID.dump!(envelope.vault_id), envelope.vault_authorization_epoch]
             )
  end

  defp mutate_owned!(statement, parameters) do
    assert {:ok, result} =
             MigrationRepo.transaction(fn ->
               SafeSQL.query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner", [])
               SafeSQL.query!(MigrationRepo, statement, parameters)
             end)

    result
  end

  defp snapshot(asset_id, job_id) do
    NativeAssetFixture.observe!(
      """
      SELECT to_jsonb(asset), to_jsonb(stage), to_jsonb(metadata), to_jsonb(source),
        (SELECT count(*) FROM audit.events WHERE target_id = asset.id),
        (SELECT count(*) FROM core.outbox_events WHERE payload->>'asset_id' = asset.id::text),
        (SELECT count(*) FROM jobs.effect_receipts WHERE submission_id = $2)
      FROM content.assets asset
      JOIN content.asset_stages stage ON stage.asset_id = asset.id
      JOIN content.asset_metadata metadata ON metadata.asset_id = asset.id
      JOIN content.source_references source ON source.resource_version_id = asset.resource_version_id
      WHERE asset.id = $1
      """,
      [Ecto.UUID.dump!(asset_id), Ecto.UUID.dump!(job_id)]
    ).rows
  end

  defp assert_no_finalization_effects!(asset_id, job_id) do
    assert %{rows: [[0, 0, 0, 0, 0, 0]]} =
             NativeAssetFixture.observe!(
               """
               SELECT
                 (SELECT count(*) FROM content.asset_objects object
                   JOIN content.asset_stages stage ON stage.candidate_object_id = object.id
                   WHERE stage.asset_id = $1),
                 (SELECT count(*) FROM content.asset_key_envelopes envelope
                   JOIN content.asset_stages stage ON stage.candidate_object_id = envelope.asset_object_id
                   WHERE stage.asset_id = $1),
                 (SELECT count(*) FROM jobs.effect_receipts WHERE submission_id = $2),
                 (SELECT count(*) FROM audit.events WHERE target_id = $1
                   AND operation IN ('asset.available', 'asset.metadata_completed')),
                 (SELECT count(*) FROM core.outbox_events
                   WHERE payload->>'asset_id' = $3 AND event_type = 'asset.metadata_requested'),
                 (SELECT count(*) FROM jobs.oban_jobs
                   WHERE args->'payload'->>'asset_id' = $3 AND args->>'job_type' = 'asset_metadata')
               """,
               [Ecto.UUID.dump!(asset_id), Ecto.UUID.dump!(job_id), asset_id]
             )
  end
end
