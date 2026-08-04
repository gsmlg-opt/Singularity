defmodule Singularity.Storage.OrphanCleanupTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.JobEnvelope
  alias Singularity.Core.Error
  alias Singularity.Runtime.Api
  alias Singularity.Runtime.Assets.ObjectCleanup
  alias Singularity.Runtime.DTO.Session
  alias Singularity.Runtime.JobDispatcher
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.Jobs.EnvelopeCodec
  alias Singularity.Storage.Jobs.GenericWorker
  alias Singularity.Storage.Jobs.ObanAdapter
  alias Singularity.Storage.Jobs.WorkerScope
  alias Singularity.Storage.LocalFilesystemAdapter
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.Postgres.AssetDeletionRepository
  alias Singularity.Storage.Postgres.AssetSearchStore
  alias Singularity.Storage.ScopedRepo

  defmodule AllowJobAuthorization do
    def check_job(_authorization, _repo, _envelope), do: :ok
  end

  defmodule TransientDeleteFailure do
    def delete(test_pid, object_ref) do
      send(test_pid, {:delete_attempt, :transient, object_ref})
      {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  defmodule IdempotentMissingDelete do
    def delete(test_pid, object_ref) do
      send(test_pid, {:delete_attempt, :missing, object_ref})
      :ok
    end
  end

  defmodule TerminalDeleteFailure do
    alias Singularity.Core.Error

    def delete(_context, object_ref) do
      send(self(), {:delete_attempt, :terminal, object_ref})
      {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  defmodule TerminalAckFailureRepository do
    alias Singularity.Core.Error
    alias Singularity.Storage.Postgres.AssetDeletionRepository

    def claim_orphan_delete(repo, envelope),
      do: AssetDeletionRepository.claim_orphan_delete(repo, envelope)

    def reschedule_orphan_delete(repo, envelope, failure),
      do:
        AssetDeletionRepository.reschedule_orphan_delete(
          repo,
          envelope,
          failure
        )

    def acknowledge_object_deleted(_repo, deletion) do
      send(self(), {:acknowledge_attempt, :terminal, deletion})
      {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  defmodule TerminalAckFailureHandler do
    @behaviour Singularity.Core.JobHandler

    alias Singularity.Runtime.Application, as: RuntimeApplication
    alias Singularity.Runtime.JobDispatcher

    @impl true
    def dependencies do
      RuntimeApplication.job_dependencies()
      |> Map.put(
        :asset_deletions,
        Singularity.Storage.OrphanCleanupTest.TerminalAckFailureRepository
      )
    end

    @impl true
    def handle(context, envelope),
      do: JobDispatcher.handle(context, envelope)

    @impl true
    def handle_failure(context, envelope, failure, attempt),
      do:
        JobDispatcher.handle_failure(
          context,
          envelope,
          failure,
          attempt
        )
  end

  setup do
    %{one: fixture} = Fixtures.two_vaults!()
    fixture = load_ids(fixture)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE content.assets
        SET state = 'ready', state_revision = 5
        WHERE id = $1
        """,
        [Ecto.UUID.dump!(fixture.asset_id)]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO content.resource_assets (
          resource_version_id, asset_id, vault_id, classification
        ) VALUES ($1, $2, $3, 'private')
        """,
        [
          Ecto.UUID.dump!(fixture.resource_version_id),
          Ecto.UUID.dump!(fixture.asset_id),
          Ecto.UUID.dump!(fixture.vault_id)
        ]
      )
    end)

    {:ok, fixture: fixture}
  end

  test "tombstone and reference release are atomic and exact retry is idempotent", %{
    fixture: fixture
  } do
    command = %{
      asset_id: fixture.asset_id,
      vault_id: fixture.vault_id,
      principal_id: fixture.principal_id,
      classification: :private,
      expected_state_revision: 5
    }

    assert {:ok, %{state: :pending_delete, state_revision: 6}} =
             scoped(fixture, fn repo ->
               assert {:ok, %{classification: :private, state: :ready}} =
                        AssetDeletionRepository.load_delete_target(repo, %{
                          asset_id: fixture.asset_id,
                          vault_id: fixture.vault_id
                        })

               AssetDeletionRepository.tombstone_and_release(repo, command)
             end)

    assert {:ok, %{state: :pending_delete, state_revision: 6}} =
             scoped(fixture, fn repo ->
               AssetDeletionRepository.tombstone_and_release(repo, command)
             end)

    scoped(fixture, fn repo ->
      assert %{rows: [["pending_delete", 6, 1, 1, 1, 1]]} =
               query!(
                 repo,
                 """
                 SELECT
                   asset.state,
                   asset.state_revision,
                   (
                     SELECT count(*)
                     FROM content.tombstones
                     WHERE asset_id = asset.id
                   ),
                   (
                     SELECT count(*)
                     FROM content.resource_assets
                     WHERE asset_id = asset.id
                       AND released_at IS NOT NULL
                   ),
                   (
                     SELECT count(*)
                     FROM audit.events
                     WHERE target_id = asset.id
                       AND operation = 'asset.tombstoned'
                   ),
                   (
                     SELECT count(*)
                     FROM core.outbox_events
                     WHERE event_type = 'asset.cleanup_requested'
                       AND payload ->> 'asset_id' = asset.id::text
                       AND expected_entity_revision = 6
                       AND required_capability = 'asset.write'
                   )
                 FROM content.assets AS asset
                 WHERE asset.id = $1
                 """,
                 [Ecto.UUID.dump!(fixture.asset_id)]
               )

      assert_persisted_audit!(
        repo,
        "asset.tombstoned",
        [target_id: fixture.asset_id],
        actor_kind: "principal",
        result: "completed",
        target_type: "asset"
      )

      :ok
    end)
  end

  test "stale delete revision is distinguishable to the API without publishing", %{
    fixture: fixture
  } do
    test_pid = self()
    asset_id = fixture.asset_id
    vault_id = fixture.vault_id

    config = %{
      delete_asset: fn context, asset_id, expected_state_revision ->
        result =
          scoped(fixture, fn repo ->
            AssetDeletionRepository.tombstone_and_release(repo, %{
              asset_id: asset_id,
              vault_id: context.vault_id,
              principal_id: context.principal_id,
              classification: :private,
              expected_state_revision: expected_state_revision
            })
          end)

        send(test_pid, {:production_delete_result, result})
        result
      end,
      publish_asset: fn vault_id, asset_id ->
        send(test_pid, {:delete_published, vault_id, asset_id})
        :ok
      end
    }

    result =
      Api.delete_asset(
        config,
        struct(Session, %{
          session_id: fixture.session_id,
          account_id: fixture.account_id,
          principal_id: fixture.principal_id,
          vault_id: fixture.vault_id,
          expires_at: DateTime.add(DateTime.utc_now(:microsecond), 300, :second),
          principal_authorization_epoch: 0,
          vault_authorization_epoch: 0,
          authorization_epoch: 0,
          unlocked?: false
        }),
        asset_id,
        4
      )

    assert_receive {:production_delete_result,
                    {:error,
                     %Error{
                       code: :conflict,
                       details: %{reason: :state_revision_mismatch}
                     }}}

    assert result == {:ok, false}
    refute_receive {:delete_published, ^vault_id, ^asset_id}
  end

  test "tombstoning keeps the pending asset searchable until logical cleanup", %{
    fixture: fixture
  } do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.asset_search_documents SET state = 'ready' WHERE asset_id = $1",
        [Ecto.UUID.dump!(fixture.asset_id)]
      )
    end)

    search = fn state ->
      scoped(fixture, fn repo ->
        AssetSearchStore.search(repo, %{
          vault_id: fixture.vault_id,
          query: "",
          state: state,
          media_type: nil,
          limit: 20,
          cursor: nil
        })
      end)
    end

    assert {:ok, {[visible], :done}} = search.(:ready)
    assert visible.asset_id == fixture.asset_id

    assert {:ok, %{state: :pending_delete, state_revision: 6}} =
             scoped(fixture, fn repo ->
               AssetDeletionRepository.tombstone_and_release(repo, %{
                 asset_id: fixture.asset_id,
                 vault_id: fixture.vault_id,
                 principal_id: fixture.principal_id,
                 classification: :private,
                 expected_state_revision: 5
               })
             end)

    assert {:ok, {[pending], :done}} = search.(nil)
    assert pending.asset_id == fixture.asset_id
    assert pending.state == :pending_delete
    assert pending.state_revision == 6

    assert {:ok, {[], :done}} = search.(:ready)
    assert {:ok, {[filtered_pending], :done}} = search.(:pending_delete)
    assert filtered_pending.asset_id == fixture.asset_id

    envelope = submitted_cleanup_envelope!(fixture)

    assert {:ok, %{state: :deleted, state_revision: 7}} =
             scoped_worker(fixture, fn repo ->
               AssetDeletionRepository.complete_logical_delete(repo, envelope)
             end)

    for state <- [nil, :pending_delete, :deleted] do
      assert {:ok, {[], :done}} = search.(state)
    end
  end

  test "logical cleanup removes the projection and records one durable effect", %{
    fixture: fixture
  } do
    assert {:ok, %{state: :pending_delete, state_revision: 6}} =
             scoped(fixture, fn repo ->
               AssetDeletionRepository.tombstone_and_release(repo, %{
                 asset_id: fixture.asset_id,
                 vault_id: fixture.vault_id,
                 principal_id: fixture.principal_id,
                 classification: :private,
                 expected_state_revision: 5
               })
             end)

    envelope = submitted_cleanup_envelope!(fixture)

    assert {:ok, %{state: :deleted, state_revision: 7}} =
             scoped_worker(fixture, fn repo ->
               AssetDeletionRepository.complete_logical_delete(repo, envelope)
             end)

    assert {:ok, %{state: :deleted, state_revision: 7}} =
             scoped_worker(fixture, fn repo ->
               AssetDeletionRepository.complete_logical_delete(repo, envelope)
             end)

    scoped(fixture, fn repo ->
      assert %{rows: [["deleted", 7, 0, 1, 1, 0]]} =
               query!(
                 repo,
                 """
                 SELECT
                   asset.state,
                   asset.state_revision,
                   (
                     SELECT count(*)
                     FROM content.asset_search_documents
                     WHERE asset_id = asset.id
                   ),
                   (
                     SELECT count(*)
                     FROM audit.events
                     WHERE target_id = asset.id
                       AND operation = 'asset.deleted'
                   ),
                   (
                     SELECT count(*)
                     FROM jobs.effect_receipts
                     WHERE submission_id = $2
                       AND result = 'applied'
                       AND entity_revision = 7
                   ),
                   (
                     SELECT count(*)
                     FROM core.outbox_events
                     WHERE event_type = 'object.cleanup_requested'
                       AND payload ->> 'asset_id' = asset.id::text
                   )
                 FROM content.assets AS asset
                 WHERE asset.id = $1
                 """,
                 [
                   Ecto.UUID.dump!(fixture.asset_id),
                   Ecto.UUID.dump!(envelope.job_id)
                 ]
               )

      assert_persisted_audit!(
        repo,
        "asset.deleted",
        [target_id: fixture.asset_id],
        actor_kind: "principal",
        result: "completed",
        target_type: "asset"
      )

      :ok
    end)
  end

  test "a stale logical cleanup is a no-op with one stale effect receipt", %{
    fixture: fixture
  } do
    assert {:ok, %{state: :pending_delete}} =
             scoped(fixture, fn repo ->
               AssetDeletionRepository.tombstone_and_release(repo, %{
                 asset_id: fixture.asset_id,
                 vault_id: fixture.vault_id,
                 principal_id: fixture.principal_id,
                 classification: :private,
                 expected_state_revision: 5
               })
             end)

    applied = submitted_cleanup_envelope!(fixture)

    assert {:ok, %{state: :deleted, state_revision: 7}} =
             scoped_worker(fixture, fn repo ->
               AssetDeletionRepository.complete_logical_delete(repo, applied)
             end)

    stale =
      %{
        applied
        | job_id: Ecto.UUID.generate(),
          idempotency_key: "asset-retry:#{fixture.asset_id}:#{applied.expected_entity_revision}:1"
      }

    insert_outbox_for_envelope!(stale, "asset.cleanup_requested")
    assert {:ok, _runner_job_id} = ObanAdapter.submit(%{}, stale)

    assert {:ok, %{state: :deleted, state_revision: 7}} =
             scoped_worker(fixture, fn repo ->
               AssetDeletionRepository.complete_logical_delete(repo, stale)
             end)

    scoped(fixture, fn repo ->
      assert %{rows: [[1, 1, 1]]} =
               query!(
                 repo,
                 """
                 SELECT
                   (
                     SELECT count(*)
                     FROM jobs.effect_receipts
                     WHERE submission_id = $2
                       AND result = 'stale'
                       AND entity_revision = 7
                   ),
                   (
                     SELECT count(*)
                     FROM audit.events
                     WHERE target_id = $1
                       AND operation = 'asset.deleted'
                   ),
                   (
                     SELECT count(*)
                     FROM content.tombstones
                     WHERE asset_id = $1
                   )
                 """,
                 [
                   Ecto.UUID.dump!(fixture.asset_id),
                   Ecto.UUID.dump!(stale.job_id)
                 ]
               )

      :ok
    end)
  end

  test "deleting one of two shared assets retains the canonical object", %{
    fixture: fixture
  } do
    %{object_id: object_id, retained_asset_id: retained_asset_id} =
      attach_shared_object!(fixture)

    assert {:ok, %{state: :pending_delete, state_revision: 6}} =
             scoped(fixture, fn repo ->
               AssetDeletionRepository.tombstone_and_release(repo, %{
                 asset_id: fixture.asset_id,
                 vault_id: fixture.vault_id,
                 principal_id: fixture.principal_id,
                 classification: :private,
                 expected_state_revision: 5
               })
             end)

    envelope = submitted_cleanup_envelope!(fixture)

    assert {:ok, %{state: :deleted, state_revision: 7, asset_object_id: nil}} =
             scoped_worker(fixture, fn repo ->
               AssetDeletionRepository.complete_logical_delete(repo, envelope)
             end)

    scoped(fixture, fn repo ->
      assert %{rows: [["deleted", nil, "ready", retained_object_id, "available", 0]]} =
               query!(
                 repo,
                 """
                 SELECT
                   deleted.state,
                   deleted.asset_object_id,
                   retained.state,
                   retained.asset_object_id,
                   object.lifecycle,
                   (
                     SELECT count(*)
                     FROM core.outbox_events
                     WHERE event_type = 'object.cleanup_requested'
                       AND payload ->> 'object_id' = object.id::text
                   )
                 FROM content.assets AS deleted
                 JOIN content.assets AS retained
                   ON retained.id = $2
                  AND retained.vault_id = deleted.vault_id
                 JOIN content.asset_objects AS object
                   ON object.id = retained.asset_object_id
                  AND object.vault_id = retained.vault_id
                 WHERE deleted.id = $1
                 """,
                 [
                   Ecto.UUID.dump!(fixture.asset_id),
                   Ecto.UUID.dump!(retained_asset_id)
                 ]
               )

      assert load_uuid(retained_object_id) == object_id
      :ok
    end)
  end

  test "an orphan reaches logical deleted before separately scheduled physical cleanup", %{
    fixture: fixture
  } do
    cleanup_principal_id = install_cleanup_principal!(fixture)
    object_id = attach_object!(fixture)

    assert {:ok, %{state: :pending_delete, state_revision: 6}} =
             scoped(fixture, fn repo ->
               AssetDeletionRepository.tombstone_and_release(repo, %{
                 asset_id: fixture.asset_id,
                 vault_id: fixture.vault_id,
                 principal_id: fixture.principal_id,
                 classification: :private,
                 expected_state_revision: 5
               })
             end)

    envelope = submitted_cleanup_envelope!(fixture)

    scoped_worker(fixture, fn repo ->
      assert %{rows: [[resolved_principal_id, 0, 0]]} =
               query!(
                 repo,
                 """
                 SELECT
                   principal_id,
                   principal_authorization_epoch,
                   vault_authorization_epoch
                 FROM core.object_cleanup_authorization($1)
                 """,
                 [Ecto.UUID.dump!(fixture.vault_id)]
               )

      assert load_uuid(resolved_principal_id) == cleanup_principal_id
      :ok
    end)

    assert {:ok, %{state: :deleted, state_revision: 7, asset_object_id: nil}} =
             scoped_worker(fixture, fn repo ->
               AssetDeletionRepository.complete_logical_delete(repo, envelope)
             end)

    assert {:ok, %{state: :deleted, state_revision: 7}} =
             scoped_worker(fixture, fn repo ->
               AssetDeletionRepository.complete_logical_delete(repo, envelope)
             end)

    scoped(fixture, fn repo ->
      assert %{rows: [["deleted", "orphan_pending", 2, retained_until, 1, 1]]} =
               query!(
                 repo,
                 """
                 SELECT
                   asset.state,
                   object.lifecycle,
                   object.lifecycle_revision,
                   object.retained_until,
                   (
                     SELECT count(*)
                     FROM core.outbox_events
                     WHERE event_type = 'object.cleanup_requested'
                       AND payload ->> 'object_id' = object.id::text
                       AND principal_id = $3
                       AND required_capability = 'object.cleanup'
                       AND expected_entity_revision = 2
                   ),
                   (
                     SELECT count(*)
                     FROM audit.events
                     WHERE target_id = object.id
                       AND operation = 'object.orphaned'
                   )
                 FROM content.assets AS asset
                 JOIN content.asset_objects AS object
                   ON object.id = $2
                  AND object.vault_id = asset.vault_id
                 WHERE asset.id = $1
                 """,
                 [
                   Ecto.UUID.dump!(fixture.asset_id),
                   Ecto.UUID.dump!(object_id),
                   Ecto.UUID.dump!(cleanup_principal_id)
                 ]
               )

      assert DateTime.compare(retained_until, DateTime.utc_now()) in [:lt, :eq]
      :ok
    end)
  end

  test "cleanup authority resolution rejects a revoked principal or disabled account", %{
    fixture: fixture
  } do
    cleanup_principal_id = install_cleanup_principal!(fixture)

    assert_cleanup_authority!(
      fixture,
      cleanup_principal_id
    )

    Fixtures.with_owner(fn ->
      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 """
                 UPDATE identity.principals
                 SET revoked_at = CURRENT_TIMESTAMP
                 WHERE id = $1
                 """,
                 [Ecto.UUID.dump!(fixture.principal_id)]
               )
    end)

    assert_cleanup_authority_missing!(fixture)

    Fixtures.with_owner(fn ->
      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 """
                 UPDATE identity.principals
                 SET revoked_at = NULL
                 WHERE id = $1
                 """,
                 [Ecto.UUID.dump!(fixture.principal_id)]
               )

      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 """
                 UPDATE identity.accounts
                 SET status = 'disabled'
                 WHERE id = $1
                 """,
                 [Ecto.UUID.dump!(fixture.account_id)]
               )
    end)

    assert_cleanup_authority_missing!(fixture)
  end

  test "logical deletion survives a transient byte failure and physical retry converges", %{
    fixture: fixture
  } do
    %{object_id: object_id} = orphaned_asset!(fixture)

    envelope = submitted_object_cleanup_envelope!(fixture, object_id)

    assert {:error, %Error{code: :storage_unavailable, retryable?: true}} =
             run_object_cleanup(
               envelope,
               {TransientDeleteFailure, self()}
             )

    assert_receive {:delete_attempt, :transient, %{object_id: ^object_id}}

    scoped(fixture, fn repo ->
      assert %{rows: [["deleted", "deleting", 3, claim_token, nil, 0]]} =
               query!(
                 repo,
                 """
                 SELECT
                   asset.state,
                   object.lifecycle,
                   object.lifecycle_revision,
                   object.delete_claim_token,
                   object.deleted_at,
                   (
                     SELECT count(*)
                     FROM jobs.effect_receipts
                     WHERE submission_id = $3
                   )
                 FROM content.assets AS asset
                 JOIN content.asset_objects AS object
                   ON object.id = $2
                  AND object.vault_id = asset.vault_id
                 WHERE asset.id = $1
                 """,
                 [
                   Ecto.UUID.dump!(fixture.asset_id),
                   Ecto.UUID.dump!(object_id),
                   Ecto.UUID.dump!(envelope.job_id)
                 ]
               )

      assert load_uuid(claim_token) == envelope.job_id
      :ok
    end)

    assert {:ok, %{id: ^object_id, lifecycle: :deleted, lifecycle_revision: 4}} =
             run_object_cleanup(
               envelope,
               {IdempotentMissingDelete, self()}
             )

    assert_receive {:delete_attempt, :missing, %{object_id: ^object_id}}

    assert {:ok, %{id: ^object_id, lifecycle: :deleted, lifecycle_revision: 4}} =
             run_object_cleanup(
               envelope,
               {IdempotentMissingDelete, self()}
             )

    refute_receive {:delete_attempt, :missing, %{object_id: ^object_id}}

    scoped(fixture, fn repo ->
      assert %{rows: [["deleted", 4, deleted_at, evidence, nil, nil, 1, 1]]} =
               query!(
                 repo,
                 """
                 SELECT
                   object.lifecycle,
                   object.lifecycle_revision,
                   object.deleted_at,
                   object.deletion_evidence,
                   object.delete_claim_token,
                   object.delete_claimed_at,
                   (
                     SELECT count(*)
                     FROM jobs.effect_receipts
                     WHERE submission_id = $2
                       AND result = 'applied'
                       AND entity_revision = 4
                   ),
                   (
                     SELECT count(*)
                     FROM audit.events
                     WHERE target_id = object.id
                       AND operation = 'object.deleted'
                       AND actor_kind = 'system'
                       AND system_principal_name = 'object_cleanup'
                       AND principal_id IS NULL
                   )
                 FROM content.asset_objects AS object
                 WHERE object.id = $1
                 """,
                 [
                   Ecto.UUID.dump!(object_id),
                   Ecto.UUID.dump!(envelope.job_id)
                 ]
               )

      assert %{"storage_status" => "deleted_or_missing"} = evidence
      assert %{"claim_token" => claim_token} = evidence
      assert claim_token == envelope.job_id
      assert DateTime.compare(deleted_at, DateTime.utc_now()) in [:lt, :eq]

      assert_persisted_audit!(
        repo,
        "object.deleted",
        [target_id: object_id],
        actor_kind: "system",
        result: "completed",
        system_principal_name: "object_cleanup",
        target_type: "asset_object"
      )

      :ok
    end)
  end

  test "max-attempt worker failure durably hands a claimed object to one successor", %{
    fixture: fixture
  } do
    %{object_id: object_id} = orphaned_asset!(fixture)

    storage_root =
      Application.fetch_env!(:singularity_storage, :storage_root)

    storage = materialize_object!(fixture, object_id, storage_root)
    exhausted = submitted_object_cleanup_envelope!(fixture, object_id)

    with_production_cleanup_handler(TerminalDeleteFailure, fn ->
      assert {:ok, encoded} = EnvelopeCodec.encode(exhausted)

      assert {:error, %{code: :job_failed}} =
               GenericWorker.perform(%Oban.Job{
                 args: encoded,
                 attempt: 3,
                 max_attempts: 3
               })

      assert_receive {:delete_attempt, :terminal, %{object_id: ^object_id}}

      assert {:ok, %{byte_size: byte_size}} =
               LocalFilesystemAdapter.stat(
                 storage,
                 %Singularity.Core.ObjectRef{object_id: object_id}
               )

      assert byte_size > 0

      assert_terminal_cleanup_handoff!(
        fixture,
        object_id,
        exhausted
      )

      successor = successor_object_cleanup_envelope!(exhausted)

      assert {:ok, ^successor} =
               reschedule_terminal_cleanup(
                 exhausted,
                 Error.new(:storage_unavailable, retryable?: true)
               )

      assert {:ok, _runner_job_id} = ObanAdapter.submit(%{}, successor)

      Application.put_env(
        :singularity_runtime,
        :storage_adapter,
        LocalFilesystemAdapter
      )

      assert {:ok, successor_encoded} =
               EnvelopeCodec.encode(successor)

      assert :ok =
               GenericWorker.perform(%Oban.Job{
                 args: successor_encoded,
                 attempt: 1,
                 max_attempts: 3
               })

      assert {:error, %Error{code: :not_found}} =
               LocalFilesystemAdapter.stat(
                 storage,
                 %Singularity.Core.ObjectRef{object_id: object_id}
               )

      assert_terminal_cleanup_recovery!(
        fixture,
        object_id,
        exhausted,
        successor
      )
    end)
  end

  test "max-attempt acknowledgment failure recovers after bytes are already missing", %{
    fixture: fixture
  } do
    %{object_id: object_id} = orphaned_asset!(fixture)

    storage_root =
      Application.fetch_env!(:singularity_storage, :storage_root)

    storage = materialize_object!(fixture, object_id, storage_root)
    exhausted = submitted_object_cleanup_envelope!(fixture, object_id)

    with_production_cleanup_handler(LocalFilesystemAdapter, fn ->
      Application.put_env(
        :singularity_storage,
        :job_handler,
        TerminalAckFailureHandler
      )

      assert {:ok, encoded} = EnvelopeCodec.encode(exhausted)

      assert {:error, %{code: :job_failed}} =
               GenericWorker.perform(%Oban.Job{
                 args: encoded,
                 attempt: 3,
                 max_attempts: 3
               })

      assert_receive {:acknowledge_attempt, :terminal, %{object_ref: %{object_id: ^object_id}}}

      assert {:error, %Error{code: :not_found}} =
               LocalFilesystemAdapter.stat(
                 storage,
                 %Singularity.Core.ObjectRef{object_id: object_id}
               )

      assert_terminal_cleanup_handoff!(
        fixture,
        object_id,
        exhausted
      )

      successor = successor_object_cleanup_envelope!(exhausted)
      assert {:ok, _runner_job_id} = ObanAdapter.submit(%{}, successor)

      Application.put_env(
        :singularity_storage,
        :job_handler,
        JobDispatcher
      )

      assert {:ok, successor_encoded} =
               EnvelopeCodec.encode(successor)

      assert :ok =
               GenericWorker.perform(%Oban.Job{
                 args: successor_encoded,
                 attempt: 1,
                 max_attempts: 3
               })

      assert_terminal_cleanup_recovery!(
        fixture,
        object_id,
        exhausted,
        successor
      )
    end)
  end

  test "fresh cleanup authority claims an orphan after rotation while the stale envelope stays forbidden",
       %{fixture: fixture} do
    %{cleanup_principal_id: cleanup_principal_id, object_id: object_id} =
      orphaned_asset!(fixture)

    storage_root =
      Application.fetch_env!(:singularity_storage, :storage_root)

    storage = materialize_object!(fixture, object_id, storage_root)
    stale = submitted_object_cleanup_envelope!(fixture, object_id)

    rotate_cleanup_authority_epochs!(
      fixture,
      cleanup_principal_id
    )

    assert {:error, %Error{code: :forbidden} = failure} =
             run_object_cleanup(
               stale,
               {LocalFilesystemAdapter, %{root: storage_root}}
             )

    assert {:ok, %{byte_size: byte_size}} =
             LocalFilesystemAdapter.stat(
               storage,
               %Singularity.Core.ObjectRef{object_id: object_id}
             )

    assert byte_size > 0

    assert {:ok, %JobEnvelope{} = fresh} =
             reschedule_terminal_cleanup(stale, failure)

    assert {:ok,
            %{
              id: ^object_id,
              lifecycle: :deleted,
              lifecycle_revision: 4
            }} =
             run_object_cleanup(
               fresh,
               {LocalFilesystemAdapter, %{root: storage_root}}
             )

    assert {:error, %Error{code: :not_found}} =
             LocalFilesystemAdapter.stat(
               storage,
               %Singularity.Core.ObjectRef{object_id: object_id}
             )

    scoped_worker(fixture, fn repo ->
      assert %{rows: [["deleted", 4, evidence, 1, 1, 1]]} =
               query!(
                 repo,
                 """
                 SELECT
                   object.lifecycle,
                   object.lifecycle_revision,
                   object.deletion_evidence,
                   (
                     SELECT count(*)
                     FROM jobs.effect_receipts
                     WHERE submission_id = $2
                   ),
                   (
                     SELECT count(*)
                     FROM audit.events
                     WHERE target_id = object.id
                       AND operation = 'object.deleted'
                   ),
                   (
                     SELECT count(*)
                     FROM jobs.effect_receipts
                     WHERE submission_id = $3
                       AND result = 'applied'
                       AND entity_revision = 4
                   )
                 FROM content.asset_objects AS object
                 WHERE object.id = $1
                 """,
                 [
                   Ecto.UUID.dump!(object_id),
                   Ecto.UUID.dump!(stale.job_id),
                   Ecto.UUID.dump!(fresh.job_id)
                 ]
               )

      assert %{"claim_token" => claim_token} = evidence
      assert claim_token == fresh.job_id
      :ok
    end)
  end

  test "fresh cleanup authority takes over a failed durable claim and preserves its evidence",
       %{fixture: fixture} do
    %{cleanup_principal_id: cleanup_principal_id, object_id: object_id} =
      orphaned_asset!(fixture)

    storage_root =
      Application.fetch_env!(:singularity_storage, :storage_root)

    storage = materialize_object!(fixture, object_id, storage_root)
    stale = submitted_object_cleanup_envelope!(fixture, object_id)

    assert {:error, %Error{code: :storage_unavailable, retryable?: true}} =
             run_object_cleanup(
               stale,
               {TransientDeleteFailure, self()}
             )

    assert_receive {:delete_attempt, :transient, %{object_id: ^object_id}}

    rotate_cleanup_authority_epochs!(
      fixture,
      cleanup_principal_id
    )

    assert {:error, %Error{code: :forbidden} = failure} =
             run_object_cleanup(
               stale,
               {LocalFilesystemAdapter, %{root: storage_root}}
             )

    assert {:ok, %{byte_size: byte_size}} =
             LocalFilesystemAdapter.stat(
               storage,
               %Singularity.Core.ObjectRef{
                 object_id: object_id
               }
             )

    assert byte_size > 0

    assert {:ok, %JobEnvelope{} = fresh} =
             reschedule_terminal_cleanup(stale, failure)

    assert {:ok,
            %{
              id: ^object_id,
              lifecycle: :deleted,
              lifecycle_revision: 5
            }} =
             run_object_cleanup(
               fresh,
               {LocalFilesystemAdapter, %{root: storage_root}}
             )

    assert {:ok,
            %{
              id: ^object_id,
              lifecycle: :deleted,
              lifecycle_revision: 5
            }} =
             run_object_cleanup(
               fresh,
               {LocalFilesystemAdapter, %{root: storage_root}}
             )

    assert {:error, %Error{code: :not_found}} =
             LocalFilesystemAdapter.stat(
               storage,
               %Singularity.Core.ObjectRef{object_id: object_id}
             )

    scoped_worker(fixture, fn repo ->
      assert %{
               rows: [
                 [
                   "deleted",
                   5,
                   evidence,
                   nil,
                   1,
                   1,
                   1,
                   2
                 ]
               ]
             } =
               query!(
                 repo,
                 """
                 SELECT
                   object.lifecycle,
                   object.lifecycle_revision,
                   object.deletion_evidence,
                   object.delete_claim_token,
                   (
                     SELECT count(*)
                     FROM jobs.effect_receipts
                     WHERE submission_id = $2
                   ),
                   (
                     SELECT count(*)
                     FROM jobs.effect_receipts
                     WHERE submission_id = $3
                       AND result = 'applied'
                       AND entity_revision = 5
                   ),
                   (
                     SELECT count(*)
                     FROM audit.events
                     WHERE target_id = object.id
                       AND operation = 'object.deleted'
                   ),
                   (
                     SELECT count(*)
                     FROM audit.events
                     WHERE target_id = object.id
                       AND operation = 'object.delete_claimed'
                   )
                 FROM content.asset_objects AS object
                 WHERE object.id = $1
                 """,
                 [
                   Ecto.UUID.dump!(object_id),
                   Ecto.UUID.dump!(stale.job_id),
                   Ecto.UUID.dump!(fresh.job_id)
                 ]
               )

      assert %{
               "claim_token" => fresh_claim_token,
               "prior_claim_token" => prior_claim_token,
               "storage_status" => "deleted_or_missing"
             } = evidence

      assert fresh_claim_token == fresh.job_id
      assert prior_claim_token == stale.job_id
      :ok
    end)
  end

  test "physical cleanup rejects any principal except the vault's named cleanup system principal",
       %{
         fixture: fixture
       } do
    %{object_id: object_id} = orphaned_asset!(fixture)
    envelope = submitted_object_cleanup_envelope!(fixture, object_id)
    substituted = %{envelope | principal_id: fixture.principal_id}

    assert {:error, %Error{code: :forbidden}} =
             run_object_cleanup(
               substituted,
               {IdempotentMissingDelete, self()}
             )

    refute_receive {:delete_attempt, _mode, _object_ref}

    scoped(fixture, fn repo ->
      assert %{rows: [["orphan_pending", 2, nil, nil, 0]]} =
               query!(
                 repo,
                 """
                 SELECT
                   object.lifecycle,
                   object.lifecycle_revision,
                   object.delete_claim_token,
                   object.deleted_at,
                   (
                     SELECT count(*)
                     FROM jobs.effect_receipts
                     WHERE submission_id = $2
                   )
                 FROM content.asset_objects AS object
                 WHERE object.id = $1
                 """,
                 [
                   Ecto.UUID.dump!(object_id),
                   Ecto.UUID.dump!(envelope.job_id)
                 ]
               )

      :ok
    end)
  end

  defp scoped(fixture, callback) do
    ScopedRepo.transact(
      RequestRepo,
      %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
      callback
    )
  end

  defp scoped_worker(fixture, callback) do
    ScopedRepo.transact(
      WorkerRepo,
      %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
      callback
    )
  end

  defp submitted_cleanup_envelope!(fixture) do
    envelope =
      scoped(fixture, fn repo ->
        assert %{
                 rows: [
                   [
                     id,
                     idempotency_key,
                     vault_id,
                     principal_id,
                     required_capability,
                     principal_epoch,
                     vault_epoch,
                     classification,
                     correlation_id,
                     causation_id,
                     expected_revision,
                     payload
                   ]
                 ]
               } =
                 query!(
                   repo,
                   """
                   SELECT
                     id,
                     idempotency_key,
                     vault_id,
                     principal_id,
                     required_capability,
                     principal_authorization_epoch,
                     vault_authorization_epoch,
                     classification,
                     correlation_id,
                     causation_id,
                     expected_entity_revision,
                     payload
                   FROM core.outbox_events
                   WHERE event_type = 'asset.cleanup_requested'
                     AND payload ->> 'asset_id' = $1
                   """,
                   [fixture.asset_id]
                 )

        {:ok, envelope} =
          JobEnvelope.new(%{
            version: 1,
            job_id: load_uuid(id),
            job_type: "asset_cleanup",
            idempotency_key: idempotency_key,
            vault_id: load_uuid(vault_id),
            principal_id: load_uuid(principal_id),
            required_capability: required_capability,
            principal_authorization_epoch: principal_epoch,
            vault_authorization_epoch: vault_epoch,
            classification: String.to_existing_atom(classification),
            correlation_id: load_uuid(correlation_id),
            causation_id: load_uuid(causation_id),
            expected_entity_revision: expected_revision,
            attempt: 0,
            payload: payload
          })

        envelope
      end)

    assert {:ok, _runner_job_id} = ObanAdapter.submit(%{}, envelope)
    envelope
  end

  defp submitted_object_cleanup_envelope!(fixture, object_id) do
    envelope =
      ScopedRepo.transact(
        RequestRepo,
        %{
          principal_id: cleanup_principal_id!(fixture),
          vault_id: fixture.vault_id
        },
        fn repo ->
          assert %{
                   rows: [
                     [
                       id,
                       idempotency_key,
                       vault_id,
                       principal_id,
                       required_capability,
                       principal_epoch,
                       vault_epoch,
                       classification,
                       correlation_id,
                       causation_id,
                       expected_revision,
                       payload
                     ]
                   ]
                 } =
                   query!(
                     repo,
                     """
                     SELECT
                       id,
                       idempotency_key,
                       vault_id,
                       principal_id,
                       required_capability,
                       principal_authorization_epoch,
                       vault_authorization_epoch,
                       classification,
                       correlation_id,
                       causation_id,
                       expected_entity_revision,
                       payload
                     FROM core.outbox_events
                     WHERE event_type = 'object.cleanup_requested'
                       AND payload ->> 'object_id' = $1
                     """,
                     [object_id]
                   )

          {:ok, envelope} =
            JobEnvelope.new(%{
              version: 1,
              job_id: load_uuid(id),
              job_type: "object_cleanup",
              idempotency_key: idempotency_key,
              vault_id: load_uuid(vault_id),
              principal_id: load_uuid(principal_id),
              required_capability: required_capability,
              principal_authorization_epoch: principal_epoch,
              vault_authorization_epoch: vault_epoch,
              classification: String.to_existing_atom(classification),
              correlation_id: load_uuid(correlation_id),
              causation_id: load_uuid(causation_id),
              expected_entity_revision: expected_revision,
              attempt: 0,
              payload: payload
            })

          envelope
        end
      )

    assert {:ok, _runner_job_id} = ObanAdapter.submit(%{}, envelope)
    envelope
  end

  defp reschedule_terminal_cleanup(envelope, failure) do
    WorkerScope.run(envelope, fn worker_context ->
      context =
        Map.put(
          worker_context,
          :asset_deletions,
          AssetDeletionRepository
        )

      with {:ok, %JobEnvelope{} = fresh} <-
             JobDispatcher.handle_failure(
               context,
               envelope,
               failure,
               %{attempt: 1, max_attempts: 1}
             ),
           {:ok, _runner_job_id} <- ObanAdapter.submit(%{}, fresh) do
        {:ok, fresh}
      end
    end)
  end

  defp successor_object_cleanup_envelope!(exhausted) do
    Fixtures.with_owner(fn ->
      assert %{
               rows: [
                 [
                   id,
                   idempotency_key,
                   vault_id,
                   principal_id,
                   required_capability,
                   principal_epoch,
                   vault_epoch,
                   classification,
                   correlation_id,
                   causation_id,
                   expected_revision,
                   payload
                 ]
               ]
             } =
               query!(
                 MigrationRepo,
                 """
                 SELECT
                   id,
                   idempotency_key,
                   vault_id,
                   principal_id,
                   required_capability,
                   principal_authorization_epoch,
                   vault_authorization_epoch,
                   classification,
                   correlation_id,
                   causation_id,
                   expected_entity_revision,
                   payload
                 FROM core.outbox_events
                 WHERE event_type = 'object.cleanup_requested'
                   AND causation_id = $1
                 """,
                 [Ecto.UUID.dump!(exhausted.job_id)]
               )

      {:ok, envelope} =
        JobEnvelope.new(%{
          version: 1,
          job_id: load_uuid(id),
          job_type: "object_cleanup",
          idempotency_key: idempotency_key,
          vault_id: load_uuid(vault_id),
          principal_id: load_uuid(principal_id),
          required_capability: required_capability,
          principal_authorization_epoch: principal_epoch,
          vault_authorization_epoch: vault_epoch,
          classification: String.to_existing_atom(classification),
          correlation_id: load_uuid(correlation_id),
          causation_id: load_uuid(causation_id),
          expected_entity_revision: expected_revision,
          attempt: 0,
          payload: payload
        })

      envelope
    end)
  end

  defp assert_terminal_cleanup_recovery!(
         fixture,
         object_id,
         exhausted,
         successor
       ) do
    scoped_worker(fixture, fn repo ->
      assert %{rows: [["deleted", 5, evidence, nil, 1, 1, 2, 1]]} =
               query!(
                 repo,
                 """
                 SELECT
                   object.lifecycle,
                   object.lifecycle_revision,
                   object.deletion_evidence,
                   object.delete_claim_token,
                   (
                     SELECT count(*)
                     FROM jobs.effect_receipts
                     WHERE submission_id = $2
                       AND result = 'failed'
                       AND entity_revision = 3
                   ),
                   (
                     SELECT count(*)
                     FROM jobs.effect_receipts
                     WHERE submission_id = $3
                       AND result = 'applied'
                       AND entity_revision = 5
                   ),
                   (
                     SELECT count(*)
                     FROM audit.events
                     WHERE target_id = object.id
                       AND operation = 'object.delete_claimed'
                   ),
                   (
                     SELECT count(*)
                     FROM audit.events
                     WHERE target_id = object.id
                       AND operation = 'object.deleted'
                   )
                 FROM content.asset_objects AS object
                 WHERE object.id = $1
                 """,
                 [
                   Ecto.UUID.dump!(object_id),
                   Ecto.UUID.dump!(exhausted.job_id),
                   Ecto.UUID.dump!(successor.job_id)
                 ]
               )

      assert %{
               "claim_token" => successor_claim,
               "prior_claim_token" => exhausted_claim,
               "storage_status" => "deleted_or_missing"
             } = evidence

      assert successor_claim == successor.job_id
      assert exhausted_claim == exhausted.job_id
      :ok
    end)
  end

  defp assert_terminal_cleanup_handoff!(
         fixture,
         object_id,
         exhausted
       ) do
    scoped_worker(fixture, fn repo ->
      assert %{rows: [["deleting", 3, claim_token, 1, 1, 1]]} =
               query!(
                 repo,
                 """
                 SELECT
                   object.lifecycle,
                   object.lifecycle_revision,
                   object.delete_claim_token,
                   (
                     SELECT count(*)
                     FROM jobs.effect_receipts
                     WHERE submission_id = $2
                       AND result = 'failed'
                       AND entity_revision = 3
                   ),
                   (
                     SELECT count(*)
                     FROM audit.events
                     WHERE target_id = object.id
                       AND operation = 'object.delete_failed'
                       AND result = 'failed'
                       AND metadata ->> 'job_id' = $3
                   ),
                   (
                     SELECT count(*)
                     FROM core.outbox_events
                     WHERE event_type = 'object.cleanup_requested'
                       AND causation_id = $2
                       AND expected_entity_revision = 3
                   )
                 FROM content.asset_objects AS object
                 WHERE object.id = $1
                 """,
                 [
                   Ecto.UUID.dump!(object_id),
                   Ecto.UUID.dump!(exhausted.job_id),
                   exhausted.job_id
                 ]
               )

      assert load_uuid(claim_token) == exhausted.job_id
      :ok
    end)
  end

  defp with_production_cleanup_handler(storage_adapter, callback) do
    previous_handler =
      Application.get_env(:singularity_storage, :job_handler)

    previous_adapter =
      Application.get_env(:singularity_runtime, :storage_adapter)

    previous_authorization =
      Application.fetch_env!(
        :singularity_runtime,
        :authorization_dependencies
      )

    Application.put_env(
      :singularity_storage,
      :job_handler,
      JobDispatcher
    )

    Application.put_env(
      :singularity_runtime,
      :storage_adapter,
      storage_adapter
    )

    Application.put_env(
      :singularity_runtime,
      :authorization_dependencies,
      Map.put(
        previous_authorization,
        :store,
        Singularity.Storage.Postgres.IdentityRepository
      )
    )

    try do
      callback.()
    after
      Application.put_env(
        :singularity_runtime,
        :authorization_dependencies,
        previous_authorization
      )

      restore_env(
        :singularity_runtime,
        :storage_adapter,
        previous_adapter
      )

      restore_env(
        :singularity_storage,
        :job_handler,
        previous_handler
      )
    end
  end

  defp restore_env(app, key, nil),
    do: Application.delete_env(app, key)

  defp restore_env(app, key, value),
    do: Application.put_env(app, key, value)

  defp insert_outbox_for_envelope!(envelope, event_type) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO core.outbox_events (
          id,
          event_type,
          idempotency_key,
          vault_id,
          principal_id,
          required_capability,
          principal_authorization_epoch,
          vault_authorization_epoch,
          classification,
          correlation_id,
          causation_id,
          expected_entity_revision,
          envelope_version,
          payload,
          occurred_at
        ) VALUES (
          $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, 1,
          $13::text::jsonb, CURRENT_TIMESTAMP
        )
        """,
        [
          Ecto.UUID.dump!(envelope.job_id),
          event_type,
          envelope.idempotency_key,
          Ecto.UUID.dump!(envelope.vault_id),
          Ecto.UUID.dump!(envelope.principal_id),
          envelope.required_capability,
          envelope.principal_authorization_epoch,
          envelope.vault_authorization_epoch,
          Atom.to_string(envelope.classification),
          Ecto.UUID.dump!(envelope.correlation_id),
          Ecto.UUID.dump!(envelope.causation_id),
          envelope.expected_entity_revision,
          JSON.encode!(envelope.payload)
        ]
      )
    end)
  end

  defp run_object_cleanup(
         envelope,
         storage,
         deletions \\ AssetDeletionRepository
       ) do
    WorkerScope.run(envelope, fn worker_context ->
      context =
        Map.merge(worker_context, %{
          asset_deletions: deletions,
          authorization: :test_authorization,
          authorize: AllowJobAuthorization,
          storage: storage
        })

      ObjectCleanup.run(context, envelope)
    end)
  end

  defp materialize_object!(fixture, object_id, storage_root) do
    object =
      scoped_worker(fixture, fn repo ->
        assert %{rows: [[key_domain_id, lookup_digest]]} =
                 query!(
                   repo,
                   """
                   SELECT key_domain_id, lookup_digest
                   FROM content.asset_objects
                   WHERE id = $1
                   """,
                   [Ecto.UUID.dump!(object_id)]
                 )

        %{
          key_domain_id: load_uuid(key_domain_id),
          lookup_digest: lookup_digest
        }
      end)

    context = %{
      root: storage_root,
      vault_namespace: fixture.vault_id,
      domain_namespace: object.key_domain_id,
      lookup_digest: Base.encode16(object.lookup_digest, case: :lower)
    }

    stage_id = Ecto.UUID.generate()
    stage_ref = %Singularity.Core.StageRef{stage_id: stage_id}
    object_ref = %Singularity.Core.ObjectRef{object_id: object_id}

    assert {:ok, ^stage_ref} =
             LocalFilesystemAdapter.stage(context, %{
               stage_id: stage_id
             })

    assert :ok =
             LocalFilesystemAdapter.append_encrypted_chunk(
               context,
               stage_ref,
               "claimed-object-ciphertext"
             )

    assert {:ok, %{sealed?: true}} =
             LocalFilesystemAdapter.seal_stage(
               context,
               stage_ref,
               %{}
             )

    assert {:ok, ^object_ref} =
             LocalFilesystemAdapter.finalize(
               context,
               stage_ref,
               object_ref
             )

    context
  end

  defp rotate_cleanup_authority_epochs!(
         fixture,
         cleanup_principal_id
       ) do
    Fixtures.with_owner(fn ->
      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 """
                 UPDATE identity.principals
                 SET authorization_epoch = authorization_epoch + 1
                 WHERE id = $1
                 """,
                 [Ecto.UUID.dump!(cleanup_principal_id)]
               )

      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 """
                 UPDATE core.vaults
                 SET authorization_epoch = authorization_epoch + 1
                 WHERE id = $1
                 """,
                 [Ecto.UUID.dump!(fixture.vault_id)]
               )
    end)
  end

  defp assert_cleanup_authority!(
         fixture,
         cleanup_principal_id
       ) do
    scoped_worker(fixture, fn repo ->
      assert %{rows: [[principal_id, 0, 0]]} =
               query!(
                 repo,
                 """
                 SELECT
                   principal_id,
                   principal_authorization_epoch,
                   vault_authorization_epoch
                 FROM core.object_cleanup_authorization($1)
                 """,
                 [Ecto.UUID.dump!(fixture.vault_id)]
               )

      assert load_uuid(principal_id) == cleanup_principal_id
      :ok
    end)
  end

  defp assert_cleanup_authority_missing!(fixture) do
    scoped_worker(fixture, fn repo ->
      assert %{rows: []} =
               query!(
                 repo,
                 """
                 SELECT *
                 FROM core.object_cleanup_authorization($1)
                 """,
                 [Ecto.UUID.dump!(fixture.vault_id)]
               )

      :ok
    end)
  end

  defp orphaned_asset!(fixture) do
    cleanup_principal_id = install_cleanup_principal!(fixture)
    object_id = attach_object!(fixture)

    assert {:ok, %{state: :pending_delete}} =
             scoped(fixture, fn repo ->
               AssetDeletionRepository.tombstone_and_release(repo, %{
                 asset_id: fixture.asset_id,
                 vault_id: fixture.vault_id,
                 principal_id: fixture.principal_id,
                 classification: :private,
                 expected_state_revision: 5
               })
             end)

    logical_envelope = submitted_cleanup_envelope!(fixture)

    assert {:ok, %{state: :deleted}} =
             scoped_worker(fixture, fn repo ->
               AssetDeletionRepository.complete_logical_delete(
                 repo,
                 logical_envelope
               )
             end)

    %{
      cleanup_principal_id: cleanup_principal_id,
      object_id: object_id
    }
  end

  defp cleanup_principal_id!(fixture) do
    scoped(fixture, fn repo ->
      assert %{rows: [[principal_id]]} =
               query!(
                 repo,
                 """
                 SELECT object_cleanup_principal_id
                 FROM core.vaults
                 WHERE id = $1
                 """,
                 [Ecto.UUID.dump!(fixture.vault_id)]
               )

      load_uuid(principal_id)
    end)
  end

  defp attach_shared_object!(fixture) do
    object_id = attach_object!(fixture)
    retained_asset_id = Ecto.UUID.generate()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO content.assets (
          id,
          vault_id,
          resource_version_id,
          asset_object_id,
          classification,
          state,
          state_revision
        ) VALUES ($1, $2, $3, $4, 'private', 'ready', 5)
        """,
        [
          Ecto.UUID.dump!(retained_asset_id),
          Ecto.UUID.dump!(fixture.vault_id),
          Ecto.UUID.dump!(fixture.resource_version_id),
          Ecto.UUID.dump!(object_id)
        ]
      )
    end)

    %{object_id: object_id, retained_asset_id: retained_asset_id}
  end

  defp attach_object!(fixture) do
    key_domain_id = Ecto.UUID.generate()
    object_id = Ecto.UUID.generate()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO core.key_domains (
          id, vault_id, classification, kind, state
        ) VALUES ($1, $2, 'private', 'content', 'active')
        """,
        [
          Ecto.UUID.dump!(key_domain_id),
          Ecto.UUID.dump!(fixture.vault_id)
        ]
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
          lifecycle_revision
        ) VALUES (
          $1, $2, $3, 'private', $4, $5, 12, 64, $6, 1, 'available', 1
        )
        """,
        [
          Ecto.UUID.dump!(object_id),
          Ecto.UUID.dump!(fixture.vault_id),
          Ecto.UUID.dump!(key_domain_id),
          :crypto.hash(:sha256, object_id <> ":lookup"),
          :crypto.hash(:sha256, object_id <> ":ciphertext"),
          object_id
        ]
      )

      query!(
        MigrationRepo,
        """
        UPDATE content.assets
        SET asset_object_id = $2
        WHERE id = $1
        """,
        [
          Ecto.UUID.dump!(fixture.asset_id),
          Ecto.UUID.dump!(object_id)
        ]
      )
    end)

    object_id
  end

  defp install_cleanup_principal!(fixture) do
    cleanup_principal_id = Ecto.UUID.generate()
    capability_id = Ecto.UUID.generate()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO identity.principals (
          id, account_id, kind, metadata
        ) VALUES ($1, $2, 'system', '{"name":"object_cleanup"}'::jsonb)
        """,
        [
          Ecto.UUID.dump!(cleanup_principal_id),
          Ecto.UUID.dump!(fixture.account_id)
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.vault_members (
          principal_id, vault_id, clearance
        ) VALUES ($1, $2, 'private')
        """,
        [
          Ecto.UUID.dump!(cleanup_principal_id),
          Ecto.UUID.dump!(fixture.vault_id)
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.capabilities (id, name)
        VALUES ($1, 'object.cleanup')
        ON CONFLICT (name) DO NOTHING
        """,
        [Ecto.UUID.dump!(capability_id)]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.principal_capabilities (
          principal_id, vault_id, capability_id
        )
        SELECT $1, $2, id
        FROM core.capabilities
        WHERE name = 'object.cleanup'
        """,
        [
          Ecto.UUID.dump!(cleanup_principal_id),
          Ecto.UUID.dump!(fixture.vault_id)
        ]
      )

      query!(
        MigrationRepo,
        """
        UPDATE core.vaults
        SET object_cleanup_principal_id = $2
        WHERE id = $1
        """,
        [
          Ecto.UUID.dump!(fixture.vault_id),
          Ecto.UUID.dump!(cleanup_principal_id)
        ]
      )
    end)

    cleanup_principal_id
  end

  defp load_ids(fixture) do
    Map.new(fixture, fn
      {key, value}
      when key in [
             :account_id,
             :asset_id,
             :credential_id,
             :principal_id,
             :resource_id,
             :resource_version_id,
             :session_id,
             :vault_id
           ] ->
        {key, load_uuid(value)}

      pair ->
        pair
    end)
  end

  defp load_uuid(value) do
    case Ecto.UUID.load(value) do
      {:ok, uuid} -> uuid
      :error -> value
    end
  end
end
