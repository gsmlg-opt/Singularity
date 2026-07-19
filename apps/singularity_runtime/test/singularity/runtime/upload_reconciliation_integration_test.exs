defmodule Singularity.Runtime.UploadReconciliationIntegrationTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Runtime.Assets.UploadReconciler
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.LocalFilesystemAdapter
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.Postgres.AssetRepository
  alias Singularity.Storage.Postgres.AssetUploadRecoveryRepository
  alias Singularity.Storage.Schema.Content.AssetStage
  alias Singularity.Storage.ScopedRepo

  defmodule FailOnceRepository do
    alias Singularity.Core.Error
    alias Singularity.Storage.Postgres.AssetUploadRecoveryRepository

    def list_open_stages(%{repo: repo}),
      do: AssetUploadRecoveryRepository.list_open_stages(repo)

    def with_locked_stage(
          %{repo: repo},
          stage_id,
          storage_ref,
          callback
        ),
        do:
          AssetUploadRecoveryRepository.with_locked_stage(
            repo,
            stage_id,
            storage_ref,
            callback
          )

    def mark_abandoned(
          %{repo: repo, failure: failure},
          stage_id,
          storage_ref,
          abandoned_at,
          reason
        ) do
      if Agent.get_and_update(failure, fn pending? ->
           {pending?, false}
         end) do
        {:error, Error.new(:storage_unavailable, retryable?: true)}
      else
        AssetUploadRecoveryRepository.mark_abandoned(
          repo,
          stage_id,
          storage_ref,
          abandoned_at,
          reason
        )
      end
    end
  end

  defmodule BlockingStorage do
    alias Singularity.Storage.LocalFilesystemAdapter

    def abort_stage(
          %{
            gate: gate,
            storage: storage,
            test: test
          },
          stage_ref
        ) do
      send(test, {:recovery_abort_entered, gate, stage_ref})

      receive do
        {:allow_recovery_abort, ^gate} ->
          LocalFilesystemAdapter.abort_stage(storage, stage_ref)
      end
    end
  end

  setup do
    %{one: raw_fixture, two: raw_other} = Fixtures.two_vaults!()

    fixture =
      raw_fixture
      |> load_ids()
      |> Map.merge(insert_key_domain!(raw_fixture.vault_id))

    other =
      raw_other
      |> load_ids()
      |> Map.merge(insert_key_domain!(raw_other.vault_id))

    {:ok, fixture: fixture, other: other, storage_root: storage_root()}
  end

  test "restart retry removes bytes, preserves consumed grant, and records one effect", %{
    fixture: fixture,
    storage_root: storage_root
  } do
    upload = open_upload!(fixture)
    storage = {LocalFilesystemAdapter, %{root: storage_root}}
    stage_ref = %Singularity.Core.StageRef{stage_id: upload.stage.storage_ref}

    assert {:ok, ^stage_ref} =
             LocalFilesystemAdapter.stage(
               %{root: storage_root},
               %{stage_id: stage_ref.stage_id}
             )

    assert :ok =
             LocalFilesystemAdapter.append_encrypted_chunk(
               %{root: storage_root},
               stage_ref,
               "partial-ciphertext"
             )

    failure = start_supervised!({Agent, fn -> true end})

    context = %{
      repository: {FailOnceRepository, %{repo: WorkerRepo, failure: failure}},
      storage: storage,
      clock: fn -> ~U[2026-07-19 05:30:00.000000Z] end
    }

    assert {:error, %Error{code: :storage_unavailable, retryable?: true}} =
             UploadReconciler.run(context)

    assert {:error, %Error{code: :not_found}} =
             LocalFilesystemAdapter.stat_stage(%{root: storage_root}, stage_ref)

    assert_stage_effects(fixture, upload,
      state: "open",
      revision: 0,
      failure_code: nil,
      audits: 0
    )

    assert {:ok, 1} = UploadReconciler.run(context)

    assert_stage_effects(fixture, upload,
      state: "abandoned",
      revision: 1,
      failure_code: "runtime_restarted",
      audits: 1
    )

    assert {:ok, 0} = UploadReconciler.run(context)

    assert_stage_effects(fixture, upload,
      state: "abandoned",
      revision: 1,
      failure_code: "runtime_restarted",
      audits: 1
    )

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, fn repo ->
               AssetRepository.consume_grant_and_create_stage(
                 repo,
                 upload.stage_command
               )
             end)
  end

  test "global recovery finds database-only open stages across vaults", %{
    fixture: fixture,
    other: other,
    storage_root: storage_root
  } do
    first = open_upload!(fixture)
    second = open_upload!(other)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE identity.principals
        SET authorization_epoch = authorization_epoch + 1
        WHERE id = $1
        """,
        [Ecto.UUID.dump!(first.grant.principal_id)]
      )
    end)

    context = %{
      repository: {AssetUploadRecoveryRepository, WorkerRepo},
      storage: {LocalFilesystemAdapter, %{root: storage_root}},
      clock: fn -> ~U[2026-07-19 05:31:00.000000Z] end
    }

    assert {:ok, 2} = UploadReconciler.run(context)

    assert_stage_effects(fixture, first,
      state: "abandoned",
      revision: 1,
      failure_code: "runtime_restarted",
      audits: 1
    )

    assert_stage_effects(other, second,
      state: "abandoned",
      revision: 1,
      failure_code: "runtime_restarted",
      audits: 1
    )
  end

  test "custody fallback abandons only the exact stage and is idempotent", %{
    fixture: fixture,
    other: other,
    storage_root: storage_root
  } do
    selected = open_upload!(fixture)
    unrelated = open_upload!(other)
    storage_context = %{root: storage_root}

    selected_ref = %Singularity.Core.StageRef{
      stage_id: selected.stage.storage_ref
    }

    unrelated_ref = %Singularity.Core.StageRef{
      stage_id: unrelated.stage.storage_ref
    }

    for stage_ref <- [selected_ref, unrelated_ref] do
      assert {:ok, ^stage_ref} =
               LocalFilesystemAdapter.stage(
                 storage_context,
                 %{stage_id: stage_ref.stage_id}
               )

      assert :ok =
               LocalFilesystemAdapter.append_encrypted_chunk(
                 storage_context,
                 stage_ref,
                 "partial-ciphertext"
               )
    end

    context = %{
      repository: {AssetUploadRecoveryRepository, WorkerRepo},
      storage: {LocalFilesystemAdapter, storage_context},
      clock: fn -> ~U[2026-07-19 05:32:00.000000Z] end
    }

    recovery = %{
      stage_id: selected.stage.id,
      storage_ref: selected.stage.storage_ref
    }

    assert {:ok, %{state: :abandoned, applied?: true}} =
             UploadReconciler.reconcile_stage(
               context,
               recovery,
               :custody_revoked
             )

    assert {:error, %Error{code: :not_found}} =
             LocalFilesystemAdapter.stat_stage(
               storage_context,
               selected_ref
             )

    assert {:ok, %{sealed?: false}} =
             LocalFilesystemAdapter.stat_stage(
               storage_context,
               unrelated_ref
             )

    assert_stage_effects(fixture, selected,
      state: "abandoned",
      revision: 1,
      failure_code: "custody_revoked",
      audits: 1
    )

    assert_stage_effects(other, unrelated,
      state: "open",
      revision: 0,
      failure_code: nil,
      audits: 0
    )

    assert {:ok, %{state: :abandoned, applied?: false}} =
             UploadReconciler.reconcile_stage(
               context,
               recovery,
               :custody_revoked
             )

    assert_stage_effects(fixture, selected,
      state: "abandoned",
      revision: 1,
      failure_code: "custody_revoked",
      audits: 1
    )

    assert :ok =
             LocalFilesystemAdapter.abort_stage(
               storage_context,
               unrelated_ref
             )
  end

  test "custody fallback preserves bytes after the upload has sealed", %{
    fixture: fixture,
    storage_root: storage_root
  } do
    upload = open_upload!(fixture)
    storage_context = %{root: storage_root}
    stage_ref = %Singularity.Core.StageRef{stage_id: upload.stage.storage_ref}

    assert {:ok, ^stage_ref} =
             LocalFilesystemAdapter.stage(
               storage_context,
               %{stage_id: stage_ref.stage_id}
             )

    assert :ok =
             LocalFilesystemAdapter.append_encrypted_chunk(
               storage_context,
               stage_ref,
               "sealed-ciphertext"
             )

    test = self()
    seal_gate = make_ref()

    sealing =
      Task.async(fn ->
        scoped(fixture, fn repo ->
          assert %{num_rows: 1} =
                   query!(
                     repo,
                     """
                     SELECT id
                     FROM content.upload_grants
                     WHERE id = $1
                     FOR UPDATE
                     """,
                     [Ecto.UUID.dump!(upload.grant.id)]
                   )

          assert %{num_rows: 1} =
                   query!(
                     repo,
                     """
                     SELECT id
                     FROM content.asset_stages
                     WHERE id = $1
                     FOR UPDATE
                     """,
                     [Ecto.UUID.dump!(upload.stage.id)]
                   )

          assert %{num_rows: 1} =
                   query!(
                     repo,
                     """
                     SELECT id
                     FROM content.assets
                     WHERE id = $1
                     FOR UPDATE
                     """,
                     [Ecto.UUID.dump!(upload.grant.asset_id)]
                   )

          send(test, {:seal_row_locked, seal_gate})

          receive do
            {:allow_seal, ^seal_gate} ->
              AssetRepository.record_sealed_stage(
                repo,
                sealed_checkpoint(upload)
              )
          end
        end)
      end)

    assert_receive {:seal_row_locked, ^seal_gate}

    context = %{
      repository: {AssetUploadRecoveryRepository, WorkerRepo},
      storage:
        {BlockingStorage,
         %{
           gate: seal_gate,
           storage: storage_context,
           test: self()
         }},
      clock: fn -> ~U[2026-07-19 05:33:00.000000Z] end
    }

    recovery =
      Task.async(fn ->
        UploadReconciler.reconcile_stage(
          context,
          %{
            stage_id: upload.stage.id,
            storage_ref: upload.stage.storage_ref
          },
          :custody_revoked
        )
      end)

    refute Task.yield(recovery, 50)
    refute_receive {:recovery_abort_entered, ^seal_gate, _stage_ref}
    send(sealing.pid, {:allow_seal, seal_gate})

    assert {:ok, %{stage: %AssetStage{state: :sealed, state_revision: 1}}} =
             Task.await(sealing, 1_000)

    assert {:ok, %{state: :sealed, applied?: false}} =
             Task.await(recovery, 1_000)

    assert {:ok, %{byte_size: byte_size, sealed?: false}} =
             LocalFilesystemAdapter.stat_stage(
               storage_context,
               stage_ref
             )

    assert byte_size == byte_size("sealed-ciphertext")

    assert_stage_effects(fixture, upload,
      state: "sealed",
      revision: 1,
      failure_code: nil,
      audits: 0,
      outbox: 1
    )

    assert :ok =
             LocalFilesystemAdapter.abort_stage(
               storage_context,
               stage_ref
             )
  end

  test "custody recovery lock wins before sealing and yields one abandonment", %{
    fixture: fixture,
    storage_root: storage_root
  } do
    upload = open_upload!(fixture)
    storage_context = %{root: storage_root}
    stage_ref = %Singularity.Core.StageRef{stage_id: upload.stage.storage_ref}

    assert {:ok, ^stage_ref} =
             LocalFilesystemAdapter.stage(
               storage_context,
               %{stage_id: stage_ref.stage_id}
             )

    assert :ok =
             LocalFilesystemAdapter.append_encrypted_chunk(
               storage_context,
               stage_ref,
               "recovery-first"
             )

    gate = make_ref()

    context = %{
      repository: {AssetUploadRecoveryRepository, WorkerRepo},
      storage:
        {BlockingStorage,
         %{
           gate: gate,
           storage: storage_context,
           test: self()
         }},
      clock: fn -> ~U[2026-07-19 05:33:30.000000Z] end
    }

    recovery =
      Task.async(fn ->
        UploadReconciler.reconcile_stage(
          context,
          %{
            stage_id: upload.stage.id,
            storage_ref: upload.stage.storage_ref
          },
          :custody_revoked
        )
      end)

    assert_receive {:recovery_abort_entered, ^gate, ^stage_ref}

    sealing =
      Task.async(fn ->
        scoped(fixture, fn repo ->
          AssetRepository.record_sealed_stage(
            repo,
            sealed_checkpoint(upload)
          )
        end)
      end)

    refute Task.yield(sealing, 50)
    send(recovery.pid, {:allow_recovery_abort, gate})

    assert {:ok, %{state: :abandoned, applied?: true}} =
             Task.await(recovery, 1_000)

    assert {:error, %Error{code: :conflict}} =
             Task.await(sealing, 1_000)

    assert {:error, %Error{code: :not_found}} =
             LocalFilesystemAdapter.stat_stage(
               storage_context,
               stage_ref
             )

    assert_stage_effects(fixture, upload,
      state: "abandoned",
      revision: 1,
      failure_code: "custody_revoked",
      audits: 1
    )
  end

  test "exact recovery rejects an abandoned stage with different causal evidence", %{
    fixture: fixture,
    storage_root: storage_root
  } do
    upload = open_upload!(fixture)
    storage_context = %{root: storage_root}
    stage_ref = %Singularity.Core.StageRef{stage_id: upload.stage.storage_ref}

    assert {:ok, ^stage_ref} =
             LocalFilesystemAdapter.stage(
               storage_context,
               %{stage_id: stage_ref.stage_id}
             )

    context = %{
      repository: {AssetUploadRecoveryRepository, WorkerRepo},
      storage: {LocalFilesystemAdapter, storage_context},
      clock: fn -> ~U[2026-07-19 05:34:00.000000Z] end
    }

    recovery = %{
      stage_id: upload.stage.id,
      storage_ref: upload.stage.storage_ref
    }

    assert {:ok, %{state: :abandoned, applied?: true}} =
             UploadReconciler.reconcile_stage(
               context,
               recovery,
               :runtime_restarted
             )

    assert {:error, %Error{code: :conflict}} =
             UploadReconciler.reconcile_stage(
               context,
               recovery,
               :custody_revoked
             )

    assert_stage_effects(fixture, upload,
      state: "abandoned",
      revision: 1,
      failure_code: "runtime_restarted",
      audits: 1
    )
  end

  test "runtime restart blocks new infrastructure until open stages reconcile", %{
    fixture: fixture,
    storage_root: storage_root
  } do
    upload = open_upload!(fixture)
    stage_ref = %Singularity.Core.StageRef{stage_id: upload.stage.storage_ref}
    storage_context = %{root: storage_root}

    assert {:ok, ^stage_ref} =
             LocalFilesystemAdapter.stage(
               storage_context,
               %{stage_id: stage_ref.stage_id}
             )

    assert :ok =
             LocalFilesystemAdapter.append_encrypted_chunk(
               storage_context,
               stage_ref,
               "runtime-restart"
             )

    on_exit(fn ->
      {:ok, _started} = Application.ensure_all_started(:singularity_runtime)
    end)

    assert :ok = Application.stop(:singularity_runtime)
    assert {:ok, _started} = Application.ensure_all_started(:singularity_runtime)

    assert {:error, %Error{code: :not_found}} =
             LocalFilesystemAdapter.stat_stage(storage_context, stage_ref)

    assert_stage_effects(fixture, upload,
      state: "abandoned",
      revision: 1,
      failure_code: "runtime_restarted",
      audits: 1
    )
  end

  defp open_upload!(fixture) do
    token = :crypto.strong_rand_bytes(32)
    observed_at = DateTime.utc_now(:microsecond)

    grant_command = %{
      grant_id: Ecto.UUID.generate(),
      asset_id: Ecto.UUID.generate(),
      source_reference_id: Ecto.UUID.generate(),
      session_id: fixture.session_id,
      principal_id: fixture.principal_id,
      vault_id: fixture.vault_id,
      resource_version_id: fixture.resource_version_id,
      filename: "restart-recovery.pdf",
      byte_size: 18,
      declared_media_type: "application/pdf",
      idempotency_key: "restart-recovery-#{Ecto.UUID.generate()}",
      classification: :private,
      token_digest: :crypto.hash(:sha256, token),
      expires_at: DateTime.add(observed_at, 300, :second),
      observed_at: observed_at
    }

    assert {:ok, %{id: _, asset_id: _} = grant} =
             scoped(fixture, fn repo ->
               AssetRepository.create_upload_grant(repo, grant_command)
             end)

    stage_id = Ecto.UUID.generate()

    stage_command = %{
      grant_id: grant.id,
      token: token,
      session_id: grant.session_id,
      principal_id: grant.principal_id,
      vault_id: grant.vault_id,
      asset_id: grant.asset_id,
      filename: grant.filename,
      byte_size: grant.byte_size,
      declared_media_type: grant.declared_media_type,
      idempotency_key: grant.idempotency_key,
      classification: grant.classification,
      principal_authorization_epoch: grant.principal_authorization_epoch,
      vault_authorization_epoch: grant.vault_authorization_epoch,
      stage_id: stage_id,
      candidate_object_id: Ecto.UUID.generate(),
      key_domain_id: fixture.key_domain_id,
      domain_key_version_id: fixture.domain_key_version_id,
      storage_ref: stage_id,
      wrapper_algorithm: "aes_256_gcm",
      key_generation: 1,
      dek_wrapper: :crypto.strong_rand_bytes(60)
    }

    assert {:ok, %AssetStage{state: :open, state_revision: 0} = stage} =
             scoped(fixture, fn repo ->
               AssetRepository.consume_grant_and_create_stage(repo, stage_command)
             end)

    %{grant: grant, stage: stage, stage_command: stage_command}
  end

  defp assert_stage_effects(fixture, upload, expected) do
    scoped(fixture, fn repo ->
      assert %{
               rows: [
                 [
                   state,
                   revision,
                   failure_code,
                   consumed_at,
                   audit_count,
                   outbox_count
                 ]
               ]
             } =
               query!(
                 repo,
                 """
                 SELECT
                   stage.state,
                   stage.state_revision,
                   stage.failure_code,
                   upload_grant.consumed_at,
                   (
                     SELECT count(*)
                     FROM audit.events
                     WHERE operation = 'asset.upload_abandoned'
                       AND target_id = stage.asset_id
                   ),
                   (
                     SELECT count(*)
                     FROM core.outbox_events
                     WHERE causation_id = upload_grant.id
                        OR payload ->> 'asset_id' = stage.asset_id::text
                   )
                 FROM content.asset_stages AS stage
                 JOIN content.upload_grants AS upload_grant
                   ON upload_grant.id = stage.upload_grant_id
                  AND upload_grant.vault_id = stage.vault_id
                 WHERE stage.id = $1
                 """,
                 [Ecto.UUID.dump!(upload.stage.id)]
               )

      assert state == expected[:state]
      assert revision == expected[:revision]
      assert failure_code == expected[:failure_code]
      assert %DateTime{} = consumed_at
      assert audit_count == expected[:audits]
      assert outbox_count == Keyword.get(expected, :outbox, 0)
      :ok
    end)
  end

  defp sealed_checkpoint(upload) do
    %{
      stage_ref: %Singularity.Core.StageRef{
        stage_id: upload.stage.id
      },
      storage_ref: upload.stage.storage_ref,
      grant_id: upload.grant.id,
      session_id: upload.grant.session_id,
      principal_id: upload.grant.principal_id,
      vault_id: upload.grant.vault_id,
      asset_id: upload.grant.asset_id,
      classification: upload.grant.classification,
      expected_stage_revision: 0,
      expected_asset_revision: 0,
      format_version: 1,
      plaintext_byte_size: upload.grant.byte_size,
      ciphertext_byte_size: 170,
      lookup_digest: :binary.copy(<<0xA1>>, 32),
      ciphertext_hash: :binary.copy(<<0xB2>>, 32),
      sealed_at: DateTime.utc_now(:microsecond)
    }
  end

  defp scoped(fixture, callback) do
    ScopedRepo.transact(
      RequestRepo,
      %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
      callback
    )
  end

  defp insert_key_domain!(raw_vault_id) do
    key_domain_id = Ecto.UUID.generate()
    vault_key_version_id = Ecto.UUID.generate()
    domain_key_version_id = Ecto.UUID.generate()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO core.vault_key_versions (
          id, vault_id, generation, state, algorithm, activated_at
        ) VALUES ($1, $2, 1, 'active', 'aes_256_gcm', CURRENT_TIMESTAMP)
        """,
        [Ecto.UUID.dump!(vault_key_version_id), raw_vault_id]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.key_domains (
          id, vault_id, classification, kind, state
        ) VALUES ($1, $2, 'private', 'content', 'active')
        """,
        [Ecto.UUID.dump!(key_domain_id), raw_vault_id]
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
          Ecto.UUID.dump!(domain_key_version_id),
          raw_vault_id,
          Ecto.UUID.dump!(key_domain_id),
          Ecto.UUID.dump!(vault_key_version_id),
          :crypto.strong_rand_bytes(60)
        ]
      )
    end)

    %{
      key_domain_id: key_domain_id,
      domain_key_version_id: domain_key_version_id
    }
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
        {key, Ecto.UUID.load!(value)}

      pair ->
        pair
    end)
  end

  defp storage_root do
    Application.fetch_env!(:singularity_storage, :storage_root)
  end
end
