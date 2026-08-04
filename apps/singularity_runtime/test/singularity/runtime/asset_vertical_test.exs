defmodule Singularity.Runtime.AssetVerticalTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration
  @csrf_token "asset-vertical-csrf-token"

  alias Singularity.Core.JobEnvelope
  alias Singularity.Core.ObjectRef
  alias Singularity.Runtime.AuthorizationDependencies
  alias Singularity.Runtime.Assets.AcceptUpload
  alias Singularity.Runtime.Assets.CreateUploadGrant
  alias Singularity.Runtime.Assets.Delete
  alias Singularity.Runtime.Assets.Download
  alias Singularity.Runtime.Assets.UploadSession
  alias Singularity.Runtime.Authorize
  alias Singularity.Runtime.CustodyReader
  alias Singularity.Runtime.JobDispatcher
  alias Singularity.Runtime.KeyCustodian
  alias Singularity.Runtime.KeyLeaseSupervisor
  alias Singularity.Runtime.SessionContext
  alias Singularity.Runtime.UploadSessionSupervisor
  alias Singularity.Storage.AuthorizationLock
  alias Singularity.Storage.Crypto.KeyWrapper
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.Jobs.ObanAdapter
  alias Singularity.Storage.Jobs.WorkerScope
  alias Singularity.Storage.LocalFilesystemAdapter
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.ObjectLock
  alias Singularity.Storage.Postgres.AssetDeletionRepository
  alias Singularity.Storage.Postgres.AssetRepository
  alias Singularity.Storage.Postgres.CustodyRepository
  alias Singularity.Storage.Postgres.IdentityRepository
  alias Singularity.Storage.ScopedRepo
  alias Singularity.Storage.VaultLock

  setup do
    %{one: raw_fixture} = Fixtures.two_vaults!()
    fixture = load_ids(raw_fixture)
    keys = install_vertical_security!(fixture)
    storage_root = vertical_storage_root()

    File.mkdir_p!(storage_root)
    on_exit(fn -> File.rm_rf!(storage_root) end)

    lease_supervisor =
      start_supervised!(
        {KeyLeaseSupervisor, name: nil},
        id: make_ref()
      )

    custody_context = %{
      key_wrapper: KeyWrapper,
      repo: WorkerRepo,
      repository_adapter: CustodyRepository,
      scope: ScopedRepo,
      storage: %{
        adapter: LocalFilesystemAdapter,
        context: %{root: storage_root}
      }
    }

    custodian =
      start_supervised!(
        {KeyCustodian,
         %{
           authorization: CustodyReader,
           clock: CustodyReader,
           context: custody_context,
           idle_lock: fn _session -> :ok end,
           idle_timeout_ms: :timer.minutes(10),
           key_reader: CustodyReader,
           key_wrapper: KeyWrapper,
           lease_supervisor: lease_supervisor,
           object_key_loader: CustodyReader
         }},
        id: make_ref()
      )

    upload_supervisor =
      start_supervised!(
        {UploadSessionSupervisor, name: nil, max_children: 1},
        id: make_ref()
      )

    session = session(fixture)

    assert {:ok, pending} =
             KeyCustodian.prepare_unlock(
               custodian,
               custody_session(session, keys)
             )

    assert :ok = KeyCustodian.activate_unlock(custodian, pending)

    assert {:ok, authorization} =
             AuthorizationDependencies.new(%{
               store: IdentityRepository,
               custodian: {KeyCustodian, custodian}
             })

    asset_storage = %{
      adapter: LocalFilesystemAdapter,
      context: %{root: storage_root},
      dedup_lookup: fn _vault_id, _key_domain_id, _lookup_digest ->
        :miss
      end,
      destroy_dek_wrapper: fn _wrapped_dek -> :ok end
    }

    runtime = %{
      asset_deletions: AssetDeletionRepository,
      assets: AssetRepository,
      asset_storage: asset_storage,
      authorization: authorization,
      authorization_lock: AuthorizationLock,
      authorizer: Authorize,
      custodian: {KeyCustodian, custodian},
      operation_scope: Singularity.Runtime.OperationScope,
      request_repo: RequestRepo,
      scoped_repo: ScopedRepo,
      upload_session_supervisor: upload_supervisor,
      upload_supervisor: UploadSessionSupervisor,
      vault_lock: VaultLock
    }

    {:ok, fixture: fixture, runtime: runtime, session: session, storage_root: storage_root}
  end

  test "runs the encrypted asset lifecycle through request and worker runtime ports", %{
    fixture: fixture,
    runtime: runtime,
    session: session,
    storage_root: storage_root
  } do
    plaintext = "%PDF-1.7\nSingularity vertical evidence\n%%EOF\n"

    grant_request = %{
      declared_media_type: "application/pdf",
      filename: "vertical-evidence.pdf",
      idempotency_key: "asset-vertical-#{Ecto.UUID.generate()}",
      size: byte_size(plaintext)
    }

    grant_results =
      1..2
      |> Task.async_stream(
        fn _attempt ->
          CreateUploadGrant.run(
            runtime,
            session,
            grant_request,
            @csrf_token
          )
        end,
        max_concurrency: 2,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, grant}] =
             Enum.filter(grant_results, &match?({:ok, _grant}, &1))

    assert [{:error, %Singularity.Core.Error{code: :conflict}}] =
             Enum.filter(
               grant_results,
               &match?({:error, %Singularity.Core.Error{code: :conflict}}, &1)
             )

    assert {:ok, upload} =
             AcceptUpload.begin(
               runtime,
               session,
               digest_bound_grant(grant),
               self()
             )

    assert :ok = UploadSession.append(upload, plaintext)

    assert {:ok,
            %{
              asset: %{id: asset_id, state: :uploaded, state_revision: 1},
              stage: %{
                id: stage_id,
                state: :sealed,
                state_revision: 1
              }
            }} = UploadSession.finish(upload)

    assert asset_id == grant.asset_id

    verify =
      submitted_envelope!(
        fixture,
        asset_id,
        "asset.verify_requested",
        "asset_verify"
      )

    assert {:ok, %{id: ^asset_id, state: :verified, state_revision: 2}} =
             run_job(verify, runtime, storage_root)

    finalize =
      submitted_envelope!(
        fixture,
        asset_id,
        "asset.finalize_requested",
        "asset_finalize"
      )

    assert {:ok,
            %{
              id: ^asset_id,
              asset_object_id: object_id,
              state: :available,
              state_revision: 3
            }} = run_job(finalize, runtime, storage_root)

    assert {:ok, %{id: ^asset_id, state: :available, state_revision: 3}} =
             run_job(verify, runtime, storage_root)

    assert {:ok,
            %{
              id: ^asset_id,
              asset_object_id: ^object_id,
              state: :available,
              state_revision: 3
            }} = run_job(finalize, runtime, storage_root)

    assert {:ok, ^plaintext} =
             Download.run(runtime, session, asset_id, :all)

    assert {:ok, range_plaintext} =
             Download.run(runtime, session, asset_id, 5..17)

    assert range_plaintext == binary_part(plaintext, 5, 13)

    assert {:ok, %{id: ^asset_id, state: :pending_delete, state_revision: 4}} =
             Delete.run(runtime, session, asset_id, 3)

    assert {:ok, %{id: ^asset_id, state: :pending_delete, state_revision: 4}} =
             Delete.run(runtime, session, asset_id, 3)

    cleanup =
      submitted_envelope!(
        fixture,
        asset_id,
        "asset.cleanup_requested",
        "asset_cleanup"
      )

    assert {:ok, %{id: ^asset_id, state: :deleted, state_revision: 5}} =
             run_job(cleanup, runtime, storage_root)

    assert {:ok, %{id: ^asset_id, state: :deleted, state_revision: 5}} =
             run_job(cleanup, runtime, storage_root)

    assert_lifecycle_evidence!(
      asset_id,
      stage_id,
      object_id,
      verify,
      finalize,
      cleanup
    )

    object_context = object_storage_context!(object_id, storage_root)

    assert {:ok, %{byte_size: ciphertext_size}} =
             LocalFilesystemAdapter.stat(
               object_context,
               %ObjectRef{object_id: object_id}
             )

    assert ciphertext_size > byte_size(plaintext)

    stale_cleanup =
      insert_stale_cleanup_envelope!(
        fixture,
        cleanup,
        asset_id
      )

    assert {:ok, %{id: ^asset_id, state: :deleted, state_revision: 5}} =
             run_job(stale_cleanup, runtime, storage_root)

    assert_stale_noop!(asset_id, object_id, stale_cleanup)
  end

  test "delete cannot tombstone an asset while its upload stage is open", %{
    runtime: runtime,
    session: session,
    storage_root: storage_root
  } do
    plaintext = "%PDF-1.7\nactive upload\n%%EOF\n"

    request = %{
      declared_media_type: "application/pdf",
      filename: "active-upload.pdf",
      idempotency_key: "active-upload-delete-#{Ecto.UUID.generate()}",
      size: byte_size(plaintext)
    }

    assert {:ok, grant} =
             CreateUploadGrant.run(
               runtime,
               session,
               request,
               @csrf_token
             )

    assert {:ok, upload} =
             AcceptUpload.begin(
               runtime,
               session,
               digest_bound_grant(grant),
               self()
             )

    assert :ok = UploadSession.append(upload, plaintext)

    assert {:ok, [_open_stage]} =
             LocalFilesystemAdapter.list_staged(%{root: storage_root})

    deletion =
      Task.async(fn ->
        Delete.run(runtime, session, grant.asset_id, 0)
      end)

    assert {:error, %Singularity.Core.Error{code: :conflict}} =
             Task.await(deletion, 5_000)

    assert Process.alive?(upload)

    assert {:ok,
            %{
              asset: %{id: asset_id, state: :uploaded, state_revision: 1},
              stage: %{state: :sealed, state_revision: 1}
            }} = UploadSession.finish(upload)

    assert asset_id == grant.asset_id
  end

  defp run_job(envelope, runtime, storage_root) do
    WorkerScope.run(envelope, fn worker_context ->
      context =
        Map.merge(worker_context, %{
          asset_deletions: AssetDeletionRepository,
          assets: AssetRepository,
          authorization: runtime.authorization,
          authorize: Authorize,
          object_lock: ObjectLock,
          storage: {LocalFilesystemAdapter, %{root: storage_root}}
        })

      JobDispatcher.handle(context, envelope)
    end)
  end

  defp submitted_envelope!(
         fixture,
         asset_id,
         event_type,
         job_type
       ) do
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
                   WHERE event_type = $1
                     AND payload ->> 'asset_id' = $2
                   """,
                   [event_type, asset_id]
                 )

        assert {:ok, envelope} =
                 JobEnvelope.new(%{
                   attempt: 0,
                   causation_id: load_uuid(causation_id),
                   classification: String.to_existing_atom(classification),
                   correlation_id: load_uuid(correlation_id),
                   expected_entity_revision: expected_revision,
                   idempotency_key: idempotency_key,
                   job_id: load_uuid(id),
                   job_type: job_type,
                   payload: payload,
                   principal_authorization_epoch: principal_epoch,
                   principal_id: load_uuid(principal_id),
                   required_capability: required_capability,
                   vault_authorization_epoch: vault_epoch,
                   vault_id: load_uuid(vault_id),
                   version: 1
                 })

        envelope
      end)

    assert {:ok, _runner_job_id} = ObanAdapter.submit(%{}, envelope)
    envelope
  end

  defp insert_stale_cleanup_envelope!(
         fixture,
         cleanup,
         asset_id
       ) do
    assert {:ok, envelope} =
             JobEnvelope.new(%{
               attempt: 0,
               causation_id: cleanup.job_id,
               classification: cleanup.classification,
               correlation_id: cleanup.correlation_id,
               expected_entity_revision: 4,
               idempotency_key: "asset-retry:#{asset_id}:4:1",
               job_id: Ecto.UUID.generate(),
               job_type: "asset_cleanup",
               payload: %{"asset_id" => asset_id},
               principal_authorization_epoch: cleanup.principal_authorization_epoch,
               principal_id: cleanup.principal_id,
               required_capability: "asset.write",
               vault_authorization_epoch: cleanup.vault_authorization_epoch,
               vault_id: fixture.vault_id,
               version: 1
             })

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
          $1, 'asset.cleanup_requested', $2, $3, $4, $5, $6, $7,
          $8, $9, $10, $11, 1, $12::text::jsonb, CURRENT_TIMESTAMP
        )
        """,
        [
          Ecto.UUID.dump!(envelope.job_id),
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

    assert {:ok, _runner_job_id} = ObanAdapter.submit(%{}, envelope)
    envelope
  end

  defp assert_lifecycle_evidence!(
         asset_id,
         stage_id,
         object_id,
         verify,
         finalize,
         cleanup
       ) do
    Fixtures.with_owner(fn ->
      assert %{
               rows: [
                 [
                   "deleted",
                   5,
                   nil,
                   "finalized",
                   2,
                   "orphan_pending",
                   2,
                   retained_until,
                   consumed_at,
                   released_at,
                   0
                 ]
               ]
             } =
               query!(
                 MigrationRepo,
                 """
                 SELECT
                   asset.state,
                   asset.state_revision,
                   asset.asset_object_id,
                   stage.state,
                   stage.state_revision,
                   object.lifecycle,
                   object.lifecycle_revision,
                   object.retained_until,
                   upload_grant.consumed_at,
                   resource_asset.released_at,
                   (
                     SELECT count(*)
                     FROM content.asset_search_documents
                     WHERE asset_id = asset.id
                   )
                 FROM content.assets AS asset
                 JOIN content.asset_stages AS stage
                   ON stage.asset_id = asset.id
                  AND stage.vault_id = asset.vault_id
                 JOIN content.upload_grants AS upload_grant
                   ON upload_grant.id = stage.upload_grant_id
                  AND upload_grant.vault_id = stage.vault_id
                 JOIN content.asset_objects AS object
                   ON object.id = $3
                  AND object.vault_id = asset.vault_id
                 JOIN content.resource_assets AS resource_asset
                   ON resource_asset.asset_id = asset.id
                  AND resource_asset.vault_id = asset.vault_id
                 WHERE asset.id = $1
                   AND stage.id = $2
                 """,
                 [
                   Ecto.UUID.dump!(asset_id),
                   Ecto.UUID.dump!(stage_id),
                   Ecto.UUID.dump!(object_id)
                 ]
               )

      assert %DateTime{} = retained_until
      assert %DateTime{} = consumed_at
      assert %DateTime{} = released_at

      assert %{rows: [[1, 1, 1, 1, 1]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT
                   count(*) FILTER (WHERE operation = 'asset.uploaded'),
                   count(*) FILTER (WHERE operation = 'asset.verified'),
                   count(*) FILTER (WHERE operation = 'asset.available'),
                   count(*) FILTER (WHERE operation = 'asset.tombstoned'),
                   count(*) FILTER (WHERE operation = 'asset.deleted')
                 FROM audit.events
                 WHERE target_id = $1
                 """,
                 [Ecto.UUID.dump!(asset_id)]
               )

      assert %{rows: [[1, 1, 1, 1, 1]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT
                   count(*) FILTER (
                     WHERE event_type = 'asset.verify_requested'
                   ),
                   count(*) FILTER (
                     WHERE event_type = 'asset.finalize_requested'
                   ),
                   count(*) FILTER (
                     WHERE event_type = 'asset.metadata_requested'
                   ),
                   count(*) FILTER (
                     WHERE event_type = 'asset.cleanup_requested'
                   ),
                   count(*) FILTER (
                     WHERE event_type = 'object.cleanup_requested'
                   )
                 FROM core.outbox_events
                 WHERE payload ->> 'asset_id' = $1
                 """,
                 [asset_id]
               )

      assert %{rows: [[1, 1, 1]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT
                   count(*) FILTER (
                     WHERE submission_id = $1
                       AND result = 'applied'
                       AND entity_revision = 2
                   ),
                   count(*) FILTER (
                     WHERE submission_id = $2
                       AND result = 'applied'
                       AND entity_revision = 3
                   ),
                   count(*) FILTER (
                     WHERE submission_id = $3
                       AND result = 'applied'
                       AND entity_revision = 5
                   )
                 FROM jobs.effect_receipts
                 """,
                 [
                   Ecto.UUID.dump!(verify.job_id),
                   Ecto.UUID.dump!(finalize.job_id),
                   Ecto.UUID.dump!(cleanup.job_id)
                 ]
               )

      assert %{rows: [[1, 1, 1, 1]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT
                   (
                     SELECT count(*)
                     FROM content.upload_grants
                     WHERE asset_id = $1
                   ),
                   (
                     SELECT count(*)
                     FROM content.source_references
                     WHERE id = (
                       SELECT source_reference_id
                       FROM content.upload_grants
                       WHERE asset_id = $1
                     )
                   ),
                   (
                     SELECT count(*)
                     FROM content.tombstones
                     WHERE asset_id = $1
                   ),
                   (
                     SELECT count(*)
                     FROM content.asset_key_envelopes
                     WHERE asset_object_id = $2
                   )
                 """,
                 [
                   Ecto.UUID.dump!(asset_id),
                   Ecto.UUID.dump!(object_id)
                 ]
               )
    end)
  end

  defp assert_stale_noop!(asset_id, object_id, stale_cleanup) do
    Fixtures.with_owner(fn ->
      assert %{rows: [["deleted", 5, "orphan_pending", 2, "stale", 5]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT
                   asset.state,
                   asset.state_revision,
                   object.lifecycle,
                   object.lifecycle_revision,
                   receipt.result,
                   receipt.entity_revision
                 FROM content.assets AS asset
                 JOIN content.asset_objects AS object
                   ON object.id = $2
                  AND object.vault_id = asset.vault_id
                 JOIN jobs.effect_receipts AS receipt
                   ON receipt.submission_id = $3
                 WHERE asset.id = $1
                 """,
                 [
                   Ecto.UUID.dump!(asset_id),
                   Ecto.UUID.dump!(object_id),
                   Ecto.UUID.dump!(stale_cleanup.job_id)
                 ]
               )

      assert %{rows: [[1, 1, 1]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT
                   (
                     SELECT count(*)
                     FROM audit.events
                     WHERE target_id = $1
                       AND operation = 'asset.deleted'
                   ),
                   (
                     SELECT count(*)
                     FROM audit.events
                     WHERE target_id = $2
                       AND operation = 'object.orphaned'
                   ),
                   (
                     SELECT count(*)
                     FROM core.outbox_events
                     WHERE event_type = 'object.cleanup_requested'
                       AND payload ->> 'object_id' = $3
                   )
                 """,
                 [
                   Ecto.UUID.dump!(asset_id),
                   Ecto.UUID.dump!(object_id),
                   object_id
                 ]
               )
    end)
  end

  defp object_storage_context!(object_id, storage_root) do
    Fixtures.with_owner(fn ->
      assert %{rows: [[vault_id, key_domain_id, lookup_digest, ciphertext_hash]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT
                   vault_id,
                   key_domain_id,
                   lookup_digest,
                   ciphertext_hash
                 FROM content.asset_objects
                 WHERE id = $1
                 """,
                 [Ecto.UUID.dump!(object_id)]
               )

      %{
        ciphertext_hash: ciphertext_hash,
        domain_namespace: load_uuid(key_domain_id),
        lookup_digest: Base.encode16(lookup_digest, case: :lower),
        root: storage_root,
        vault_namespace: load_uuid(vault_id)
      }
    end)
  end

  defp install_vertical_security!(fixture) do
    ids = %{
      cleanup_principal_id: Ecto.UUID.generate(),
      domain_key_version_id: Ecto.UUID.generate(),
      key_domain_id: Ecto.UUID.generate(),
      vault_key_version_id: Ecto.UUID.generate()
    }

    domain_key = :crypto.strong_rand_bytes(32)
    domain_dedup_key = :crypto.strong_rand_bytes(32)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE core.vaults
        SET locked = false
        WHERE id = $1
        """,
        [Ecto.UUID.dump!(fixture.vault_id)]
      )

      for capability <- ["asset.write", "asset.read", "object.cleanup"] do
        query!(
          MigrationRepo,
          """
          INSERT INTO core.capabilities (id, name)
          VALUES ($1, $2)
          ON CONFLICT (name) DO NOTHING
          """,
          [Ecto.UUID.dump!(Ecto.UUID.generate()), capability]
        )
      end

      for capability <- ["asset.write", "asset.read"] do
        query!(
          MigrationRepo,
          """
          INSERT INTO core.principal_capabilities (
            principal_id, vault_id, capability_id
          )
          SELECT $1, $2, id
          FROM core.capabilities
          WHERE name = $3
          """,
          [
            Ecto.UUID.dump!(fixture.principal_id),
            Ecto.UUID.dump!(fixture.vault_id),
            capability
          ]
        )
      end

      query!(
        MigrationRepo,
        """
        INSERT INTO identity.principals (
          id, account_id, kind, metadata
        ) VALUES (
          $1, $2, 'system', '{"name":"object_cleanup"}'::jsonb
        )
        """,
        [
          Ecto.UUID.dump!(ids.cleanup_principal_id),
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
          Ecto.UUID.dump!(ids.cleanup_principal_id),
          Ecto.UUID.dump!(fixture.vault_id)
        ]
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
          Ecto.UUID.dump!(ids.cleanup_principal_id),
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
          Ecto.UUID.dump!(ids.cleanup_principal_id)
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.vault_key_versions (
          id, vault_id, generation, state, algorithm, activated_at
        ) VALUES (
          $1, $2, 1, 'active', 'aes_256_gcm', CURRENT_TIMESTAMP
        )
        """,
        [
          Ecto.UUID.dump!(ids.vault_key_version_id),
          Ecto.UUID.dump!(fixture.vault_id)
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.key_domains (
          id, vault_id, classification, kind, state
        ) VALUES ($1, $2, 'private', 'content', 'active')
        """,
        [
          Ecto.UUID.dump!(ids.key_domain_id),
          Ecto.UUID.dump!(fixture.vault_id)
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.domain_key_versions (
          id,
          vault_id,
          key_domain_id,
          vault_key_version_id,
          generation,
          state,
          algorithm,
          wrapped_key
        ) VALUES (
          $1, $2, $3, $4, 1, 'active', 'aes_256_gcm', $5
        )
        """,
        [
          Ecto.UUID.dump!(ids.domain_key_version_id),
          Ecto.UUID.dump!(fixture.vault_id),
          Ecto.UUID.dump!(ids.key_domain_id),
          Ecto.UUID.dump!(ids.vault_key_version_id),
          :crypto.strong_rand_bytes(60)
        ]
      )
    end)

    Map.merge(ids, %{
      domain_dedup_key: domain_dedup_key,
      domain_key: domain_key
    })
  end

  defp session(fixture) do
    %SessionContext{
      account_id: fixture.account_id,
      authorization_epoch: 0,
      expires_at: DateTime.add(DateTime.utc_now(), 1_800, :second),
      principal_authorization_epoch: 0,
      principal_id: fixture.principal_id,
      session_id: fixture.session_id,
      unlocked?: true,
      vault_authorization_epoch: 0,
      vault_id: fixture.vault_id
    }
  end

  defp custody_session(session, keys) do
    %{
      account_id: session.account_id,
      domain_classification: :private,
      domain_dedup_key: keys.domain_dedup_key,
      domain_key: keys.domain_key,
      domain_key_generation: 1,
      domain_key_version_id: keys.domain_key_version_id,
      expires_at: session.expires_at,
      key_domain_id: keys.key_domain_id,
      principal_authorization_epoch: session.principal_authorization_epoch,
      principal_id: session.principal_id,
      session_id: session.session_id,
      vault_authorization_epoch: session.vault_authorization_epoch,
      vault_id: session.vault_id,
      vault_key: :crypto.strong_rand_bytes(32)
    }
  end

  defp scoped(fixture, callback) do
    ScopedRepo.transact(
      RequestRepo,
      %{
        principal_id: fixture.principal_id,
        vault_id: fixture.vault_id
      },
      callback
    )
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

  defp digest_bound_grant(grant) do
    {:ok, token} =
      Base.url_decode64(grant.token, padding: false)

    grant
    |> Map.delete(:token)
    |> Map.put(:token_digest, :crypto.hash(:sha256, token))
    |> Map.put(
      :csrf_token_digest,
      :crypto.hash(:sha256, @csrf_token)
    )
    |> Map.put(:request_content_length, grant.byte_size)
    |> Map.put(
      :request_declared_media_type,
      grant.declared_media_type
    )
  end

  defp vertical_storage_root do
    Path.join(
      Application.fetch_env!(:singularity_storage, :storage_root),
      "asset-vertical-#{Ecto.UUID.generate()}"
    )
  end
end
