defmodule Singularity.Storage.ObjectCleanupConcurrencyTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.JobEnvelope
  alias Singularity.Core.ObjectRef
  alias Singularity.Runtime.Assets.ObjectCleanup
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.KnowledgeFixtures
  alias Singularity.Storage.KnowledgeTestGrants
  alias Singularity.Storage.LocalFilesystemAdapter
  alias Singularity.Storage.Jobs.ObanAdapter
  alias Singularity.Storage.Jobs.WorkerScope
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.ObjectLock
  alias Singularity.Storage.Postgres.AssetDeletionRepository
  alias Singularity.Storage.Postgres.DocumentRepository
  alias Singularity.Storage.ScopedRepo

  defmodule AllowJobAuthorization do
    def check_job(_authorization, _repo, _envelope), do: :ok
  end

  defmodule BlockingDelete do
    def delete({test_pid, gate}, object_ref) do
      send(test_pid, {:delete_started, gate, object_ref})

      receive do
        {^gate, :continue} -> :ok
      after
        5_000 -> raise "cleanup test gate timed out"
      end
    end
  end

  defmodule RejectDelete do
    def delete(test_pid, object_ref) do
      send(test_pid, {:unexpected_delete, object_ref})
      raise "stale cleanup must not reach object storage"
    end
  end

  setup do
    %{one: fixture} = Fixtures.two_vaults!()
    fixture = load_ids(fixture)
    cleanup_principal_id = install_cleanup_principal!(fixture)
    object_id = insert_orphan_object!(fixture)
    envelope = object_cleanup_envelope(fixture, cleanup_principal_id, object_id)

    insert_cleanup_outbox!(envelope)
    assert {:ok, _runner_job_id} = ObanAdapter.submit(%{}, envelope)

    {:ok,
     fixture: fixture,
     cleanup_principal_id: cleanup_principal_id,
     object_id: object_id,
     envelope: envelope}
  end

  test "ObjectLock prevents finalization from referencing bytes during physical cleanup", %{
    fixture: fixture,
    object_id: object_id,
    envelope: envelope
  } do
    gate = make_ref()
    test_pid = self()

    cleanup =
      Task.async(fn ->
        run_object_cleanup(envelope, {BlockingDelete, {test_pid, gate}})
      end)

    assert_receive {:delete_started, ^gate, %{object_id: ^object_id}}, 1_000

    finalizer =
      Task.async(fn ->
        scoped(fixture, fn repo ->
          ObjectLock.with_exclusive(repo, object_id, fn ->
            assert %{rows: [[lifecycle]]} =
                     query!(
                       repo,
                       """
                       SELECT lifecycle
                       FROM content.asset_objects
                       WHERE id = $1
                       """,
                       [Ecto.UUID.dump!(object_id)]
                     )

            send(test_pid, {:finalizer_acquired, lifecycle})

            if lifecycle == "deleted",
              do: :reserve_new_object,
              else: :reuse_existing_object
          end)
        end)
      end)

    refute_receive {:finalizer_acquired, _lifecycle}, 200

    send(cleanup.pid, {gate, :continue})

    assert {:ok, %{id: ^object_id, lifecycle: :deleted}} =
             Task.await(cleanup, 5_000)

    assert_receive {:finalizer_acquired, "deleted"}
    assert :reserve_new_object = Task.await(finalizer, 5_000)

    scoped(fixture, fn repo ->
      assert %{rows: [["deleted", 0]]} =
               query!(
                 repo,
                 """
                 SELECT
                   object.lifecycle,
                   (
                     SELECT count(*)
                     FROM content.assets
                     WHERE asset_object_id = object.id
                   )
                 FROM content.asset_objects AS object
                 WHERE object.id = $1
                 """,
                 [Ecto.UUID.dump!(object_id)]
               )

      :ok
    end)
  end

  test "a stale cleanup cannot delete an object that gained a live reference", %{
    fixture: fixture,
    object_id: object_id,
    envelope: envelope
  } do
    referenced_asset_id = Ecto.UUID.generate()

    scoped(fixture, fn repo ->
      ObjectLock.with_exclusive(repo, object_id, fn ->
        assert %{num_rows: 1} =
                 query!(
                   repo,
                   """
                   UPDATE content.asset_objects
                   SET
                     lifecycle = 'available',
                     lifecycle_revision = 3,
                     retained_until = NULL,
                     updated_at = CURRENT_TIMESTAMP
                   WHERE id = $1
                     AND lifecycle = 'orphan_pending'
                     AND lifecycle_revision = 2
                   """,
                   [Ecto.UUID.dump!(object_id)]
                 )

        query!(
          repo,
          """
          INSERT INTO content.assets (
            id,
            vault_id,
            resource_version_id,
            asset_object_id,
            classification,
            state,
            state_revision
          ) VALUES ($1, $2, $3, $4, 'private', 'available', 3)
          """,
          [
            Ecto.UUID.dump!(referenced_asset_id),
            Ecto.UUID.dump!(fixture.vault_id),
            Ecto.UUID.dump!(fixture.resource_version_id),
            Ecto.UUID.dump!(object_id)
          ]
        )
      end)
    end)

    assert {:ok, :noop} =
             run_object_cleanup(envelope, {RejectDelete, self()})

    assert {:ok, :noop} =
             run_object_cleanup(envelope, {RejectDelete, self()})

    refute_receive {:unexpected_delete, _object_ref}

    scoped(fixture, fn repo ->
      assert %{rows: [["available", 3, nil, 1, 1]]} =
               query!(
                 repo,
                 """
                 SELECT
                   object.lifecycle,
                   object.lifecycle_revision,
                   object.delete_claim_token,
                   (
                     SELECT count(*)
                     FROM content.assets
                     WHERE asset_object_id = object.id
                   ),
                   (
                     SELECT count(*)
                     FROM jobs.effect_receipts
                     WHERE submission_id = $2
                       AND result = 'stale'
                       AND entity_revision = 3
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

  test "retention prevents a cleanup claim and any storage effect", %{
    fixture: fixture,
    object_id: object_id,
    envelope: envelope
  } do
    scoped(fixture, fn repo ->
      assert %{num_rows: 1} =
               query!(
                 repo,
                 """
                 UPDATE content.asset_objects
                 SET retained_until = CURRENT_TIMESTAMP + interval '1 hour'
                 WHERE id = $1
                 """,
                 [Ecto.UUID.dump!(object_id)]
               )

      :ok
    end)

    assert {:error, %Singularity.Core.Error{code: :conflict, retryable?: true}} =
             run_object_cleanup(envelope, {RejectDelete, self()})

    refute_receive {:unexpected_delete, _object_ref}

    scoped(fixture, fn repo ->
      assert %{rows: [["orphan_pending", 2, nil, 0]]} =
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

  test "import-first source lock retains bytes after Asset cleanup" do
    source = prepared_cleanup_source!()
    storage = materialize_source!(source)
    object_ref = %ObjectRef{object_id: source.object_id}
    assert {:ok, ciphertext_before} = LocalFilesystemAdapter.stat(storage, object_ref)

    KnowledgeTestGrants.with_grants(["document_versions"], fn ->
      KnowledgeTestGrants.with_receipt_grants(fn ->
        assert {:ok, document} =
                 DocumentRepository.create_pending(
                   KnowledgeFixtures.document_context(source),
                   KnowledgeFixtures.document_command(source)
                 )

        assert document.source.object_id == source.object_id
        assert {:ok, %{state: :deleted}} = delete_asset_and_finish_cleanup(source)

        assert_import_cleanup_rows(source, "available", 1, 1)
        assert {:ok, ^ciphertext_before} = LocalFilesystemAdapter.stat(storage, object_ref)
      end)
    end)
  end

  test "cleanup-first source lock rejects the import without deleting ciphertext" do
    source = prepared_cleanup_source!()
    storage = materialize_source!(source)
    object_ref = %ObjectRef{object_id: source.object_id}
    assert {:ok, ciphertext_before} = LocalFilesystemAdapter.stat(storage, object_ref)

    KnowledgeTestGrants.with_grants(["document_versions"], fn ->
      KnowledgeTestGrants.with_receipt_grants(fn ->
        assert {:ok, %{state: :deleted}} = delete_asset_and_finish_cleanup(source)

        assert {:error, %Singularity.Core.Error{}} =
                 DocumentRepository.create_pending(
                   KnowledgeFixtures.document_context(source),
                   KnowledgeFixtures.document_command(source)
                 )

        assert_import_cleanup_rows(source, "orphan_pending", 0, 0)
        assert {:ok, ^ciphertext_before} = LocalFilesystemAdapter.stat(storage, object_ref)
      end)
    end)
  end

  defp run_object_cleanup(envelope, storage) do
    WorkerScope.run(envelope, fn worker_context ->
      context =
        Map.merge(worker_context, %{
          asset_deletions: AssetDeletionRepository,
          authorization: :test_authorization,
          authorize: AllowJobAuthorization,
          storage: storage
        })

      ObjectCleanup.run(context, envelope)
    end)
  end

  defp delete_asset_and_finish_cleanup(source) do
    assert {:ok, %{state: :pending_delete}} =
             scoped(source, fn repo ->
               AssetDeletionRepository.tombstone_and_release(repo, %{
                 asset_id: source.asset_id,
                 vault_id: source.vault_id,
                 principal_id: source.principal_id,
                 classification: :private,
                 expected_state_revision: 5
               })
             end)

    envelope =
      scoped(source, fn repo ->
        assert %{rows: [[id, idempotency_key, correlation_id, causation_id, payload]]} =
                 query!(
                   repo,
                   "SELECT id, idempotency_key, correlation_id, causation_id, payload FROM core.outbox_events WHERE event_type='asset.cleanup_requested' AND payload ->> 'asset_id'=$1",
                   [source.asset_id]
                 )

        {:ok, envelope} =
          JobEnvelope.new(%{
            version: 1,
            job_id: Ecto.UUID.load!(id),
            job_type: "asset_cleanup",
            idempotency_key: idempotency_key,
            vault_id: source.vault_id,
            principal_id: source.principal_id,
            required_capability: "asset.write",
            principal_authorization_epoch: 0,
            vault_authorization_epoch: 0,
            classification: :private,
            correlation_id: Ecto.UUID.load!(correlation_id),
            causation_id: Ecto.UUID.load!(causation_id),
            expected_entity_revision: 6,
            attempt: 0,
            payload: payload
          })

        envelope
      end)

    assert {:ok, _runner_job_id} = ObanAdapter.submit(%{}, envelope)

    ScopedRepo.transact(
      WorkerRepo,
      %{principal_id: source.principal_id, vault_id: source.vault_id},
      fn repo -> AssetDeletionRepository.complete_logical_delete(repo, envelope) end
    )
  end

  defp grant_asset_write!(fixture) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO core.capabilities (id, name) VALUES ($1, 'asset.write') ON CONFLICT (name) DO NOTHING",
        [Ecto.UUID.dump!(Ecto.UUID.generate())]
      )

      query!(
        MigrationRepo,
        "INSERT INTO core.principal_capabilities (principal_id, vault_id, capability_id) SELECT $1, $2, id FROM core.capabilities WHERE name='asset.write'",
        [Ecto.UUID.dump!(fixture.principal_id), Ecto.UUID.dump!(fixture.vault_id)]
      )
    end)
  end

  defp prepared_cleanup_source! do
    source = KnowledgeFixtures.prepared_source!()
    install_cleanup_principal!(source)
    grant_asset_write!(source)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.assets SET state='ready', state_revision=5 WHERE id=$1",
        [Ecto.UUID.dump!(source.asset_id)]
      )
    end)

    source
  end

  defp assert_import_cleanup_rows(source, lifecycle, documents, receipts) do
    Fixtures.with_owner(fn ->
      assert %{rows: [[^lifecycle, ^documents, ^receipts]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT object.lifecycle,
                   (SELECT count(*) FROM content.document_versions WHERE source_object_id=object.id),
                   (SELECT count(*) FROM content.document_import_receipts WHERE vault_id=object.vault_id AND principal_id=$2)
                 FROM content.asset_objects AS object WHERE object.id=$1
                 """,
                 [Ecto.UUID.dump!(source.object_id), Ecto.UUID.dump!(source.principal_id)]
               )
    end)
  end

  defp materialize_source!(source) do
    root = Application.fetch_env!(:singularity_storage, :storage_root)

    %{rows: [[domain_id, lookup_digest]]} =
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "SELECT key_domain_id, lookup_digest FROM content.asset_objects WHERE id=$1",
          [Ecto.UUID.dump!(source.object_id)]
        )
      end)

    context = %{
      root: root,
      vault_namespace: source.vault_id,
      domain_namespace: Ecto.UUID.load!(domain_id),
      lookup_digest: Base.encode16(lookup_digest, case: :lower)
    }

    stage = %Singularity.Core.StageRef{stage_id: Ecto.UUID.generate()}
    object = %ObjectRef{object_id: source.object_id}
    assert {:ok, ^stage} = LocalFilesystemAdapter.stage(context, %{stage_id: stage.stage_id})
    assert :ok = LocalFilesystemAdapter.append_encrypted_chunk(context, stage, "race-ciphertext")
    assert {:ok, %{sealed?: true}} = LocalFilesystemAdapter.seal_stage(context, stage, %{})
    assert {:ok, ^object} = LocalFilesystemAdapter.finalize(context, stage, object)
    context
  end

  defp scoped(fixture, callback) do
    ScopedRepo.transact(
      RequestRepo,
      %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
      callback
    )
  end

  defp object_cleanup_envelope(
         fixture,
         cleanup_principal_id,
         object_id
       ) do
    {:ok, envelope} =
      JobEnvelope.new(%{
        version: 1,
        job_id: Ecto.UUID.generate(),
        job_type: "object_cleanup",
        idempotency_key: "object-cleanup:#{object_id}:2",
        vault_id: fixture.vault_id,
        principal_id: cleanup_principal_id,
        required_capability: "object.cleanup",
        principal_authorization_epoch: 0,
        vault_authorization_epoch: 0,
        classification: :private,
        correlation_id: Ecto.UUID.generate(),
        causation_id: Ecto.UUID.generate(),
        expected_entity_revision: 2,
        attempt: 0,
        payload: %{
          "asset_id" => fixture.asset_id,
          "object_id" => object_id
        }
      })

    envelope
  end

  defp insert_cleanup_outbox!(envelope) do
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
          $1, 'object.cleanup_requested', $2, $3, $4, 'object.cleanup',
          $5, $6, 'private', $7, $8, $9, 1, $10::text::jsonb,
          CURRENT_TIMESTAMP
        )
        """,
        [
          Ecto.UUID.dump!(envelope.job_id),
          envelope.idempotency_key,
          Ecto.UUID.dump!(envelope.vault_id),
          Ecto.UUID.dump!(envelope.principal_id),
          envelope.principal_authorization_epoch,
          envelope.vault_authorization_epoch,
          Ecto.UUID.dump!(envelope.correlation_id),
          Ecto.UUID.dump!(envelope.causation_id),
          envelope.expected_entity_revision,
          JSON.encode!(envelope.payload)
        ]
      )
    end)
  end

  defp insert_orphan_object!(fixture) do
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
          lifecycle_revision,
          retained_until
        ) VALUES (
          $1, $2, $3, 'private', $4, $5, 12, 64, $6, 1,
          'orphan_pending', 2, CURRENT_TIMESTAMP - interval '1 second'
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
