defmodule Singularity.Runtime.AssetVerificationFinalizationTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope
  alias Singularity.Core.ObjectRef
  alias Singularity.Core.StageRef
  alias Singularity.Runtime.Assets.Finalize
  alias Singularity.Runtime.Assets.Verify
  alias Singularity.Storage.Crypto.ChunkedAEAD
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.Jobs.ObanAdapter
  alias Singularity.Storage.Jobs.WorkerScope
  alias Singularity.Storage.LocalFilesystemAdapter
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.ObjectLock
  alias Singularity.Storage.Postgres.AssetRepository
  alias Singularity.Storage.Schema.Content.AssetStage
  alias Singularity.Storage.ScopedRepo

  defmodule AllowAuthorization do
    def check_job(_authorization, _repo, _envelope), do: :ok
  end

  defmodule RejectKeyLease do
    def lease(_request), do: raise("verification must not request a key lease")
  end

  defmodule FailOnceAcknowledgement do
    def resolve_finalization(_failure, repo, envelope) do
      apply(AssetRepository, :resolve_finalization, [repo, envelope])
    end

    def reserve_finalization(_failure, repo, command) do
      apply(AssetRepository, :reserve_finalization, [repo, command])
    end

    def acknowledge_finalization(failure, repo, command) do
      fail? =
        Agent.get_and_update(failure, fn
          :pending -> {true, :failed}
          :failed -> {false, :failed}
        end)

      if fail? do
        {:error, Error.new(:storage_unavailable, retryable?: true)}
      else
        apply(AssetRepository, :acknowledge_finalization, [repo, command])
      end
    end
  end

  defmodule ReservationBarrierRepository do
    def resolve_finalization(_owner, repo, envelope) do
      AssetRepository.resolve_finalization(repo, envelope)
    end

    def reserve_finalization(owner, repo, command) do
      send(owner, {:reservation_ready, self(), command.envelope.job_id})

      receive do
        {:release_reservation, job_id}
        when job_id == command.envelope.job_id ->
          AssetRepository.reserve_finalization(repo, command)
      end
    end

    def acknowledge_finalization(_owner, repo, command) do
      AssetRepository.acknowledge_finalization(repo, command)
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

  test "verification checks sealed ciphertext and atomically records its durable effect", %{
    fixture: fixture,
    storage_root: storage_root
  } do
    upload =
      sealed_upload!(fixture, storage_root,
        plaintext: "verify-bytes",
        lookup_digest: :binary.copy(<<0x1A>>, 32)
      )

    envelope = submitted_envelope!(fixture, upload.asset_id, "asset.verify_requested")

    assert {:ok, %{id: asset_id, state: :verified, state_revision: 2}} =
             run_job(Verify, envelope, storage_root)

    assert asset_id == upload.asset_id

    scoped(fixture, fn repo ->
      assert %{
               rows: [
                 [
                   "verified",
                   2,
                   "sealed",
                   1,
                   1,
                   ciphertext_size,
                   ciphertext_hash,
                   wrapper_algorithm,
                   wrapped_dek
                 ]
               ]
             } =
               query!(
                 repo,
                 """
                 SELECT
                   asset.state,
                   asset.state_revision,
                   stage.state,
                   stage.state_revision,
                   stage.format_version,
                   stage.ciphertext_byte_size,
                   stage.ciphertext_hash,
                   stage.wrapper_algorithm,
                   stage.dek_wrapper
                 FROM content.assets AS asset
                 JOIN content.asset_stages AS stage
                   ON stage.asset_id = asset.id
                  AND stage.vault_id = asset.vault_id
                 WHERE asset.id = $1
                 """,
                 [Ecto.UUID.dump!(upload.asset_id)]
               )

      assert ciphertext_size == upload.ciphertext_byte_size
      assert ciphertext_hash == upload.ciphertext_hash
      assert wrapper_algorithm == "aes_256_gcm"
      assert byte_size(wrapped_dek) == 60

      assert %{rows: [[1, 1, 1]]} =
               query!(
                 repo,
                 """
                 SELECT
                   (
                     SELECT count(*)
                     FROM audit.events
                     WHERE target_id = $1
                       AND operation = 'asset.verified'
                   ),
                   (
                     SELECT count(*)
                     FROM core.outbox_events
                     WHERE event_type = 'asset.finalize_requested'
                       AND payload ->> 'asset_id' = $2
                       AND expected_entity_revision = 2
                   ),
                   (
                     SELECT count(*)
                     FROM jobs.effect_receipts
                     WHERE submission_id = $3
                       AND result = 'applied'
                       AND entity_revision = 2
                   )
                 """,
                 [
                   Ecto.UUID.dump!(upload.asset_id),
                   upload.asset_id,
                   Ecto.UUID.dump!(envelope.job_id)
                 ]
               )

      assert %{rows: [["asset.write"]]} =
               query!(
                 repo,
                 """
                 SELECT required_capability
                 FROM core.outbox_events
                 WHERE event_type = 'asset.finalize_requested'
                   AND payload ->> 'asset_id' = $1
                 """,
                 [upload.asset_id]
               )

      :ok
    end)

    assert {:ok, %{state: :verified, state_revision: 2}} =
             run_job(Verify, envelope, storage_root)

    scoped(fixture, fn repo ->
      assert %{rows: [[1, 1, 1]]} =
               query!(
                 repo,
                 """
                 SELECT
                   (
                     SELECT count(*)
                     FROM audit.events
                     WHERE target_id = $1
                       AND operation = 'asset.verified'
                   ),
                   (
                     SELECT count(*)
                     FROM core.outbox_events
                     WHERE event_type = 'asset.finalize_requested'
                       AND payload ->> 'asset_id' = $2
                   ),
                   (
                     SELECT count(*)
                     FROM jobs.effect_receipts
                     WHERE submission_id = $3
                   )
                 """,
                 [
                   Ecto.UUID.dump!(upload.asset_id),
                   upload.asset_id,
                   Ecto.UUID.dump!(envelope.job_id)
                 ]
               )

      :ok
    end)
  end

  test "ciphertext integrity mismatch leaves uploaded state and every effect absent", %{
    fixture: fixture,
    storage_root: storage_root
  } do
    upload =
      sealed_upload!(fixture, storage_root,
        plaintext: "verify-bytes",
        lookup_digest: :binary.copy(<<0x2B>>, 32),
        recorded_ciphertext_hash: :binary.copy(<<0xEE>>, 32)
      )

    envelope = submitted_envelope!(fixture, upload.asset_id, "asset.verify_requested")

    assert {:error, %Error{code: :integrity_failure}} =
             run_job(Verify, envelope, storage_root)

    scoped(fixture, fn repo ->
      assert %{rows: [["uploaded", 1, "sealed", 1]]} =
               query!(
                 repo,
                 """
                 SELECT
                   asset.state,
                   asset.state_revision,
                   stage.state,
                   stage.state_revision
                 FROM content.assets AS asset
                 JOIN content.asset_stages AS stage
                   ON stage.asset_id = asset.id
                  AND stage.vault_id = asset.vault_id
                 WHERE asset.id = $1
                 """,
                 [Ecto.UUID.dump!(upload.asset_id)]
               )

      assert %{rows: [[0, 0, 0]]} =
               query!(
                 repo,
                 """
                 SELECT
                   (
                     SELECT count(*)
                     FROM audit.events
                     WHERE target_id = $1
                       AND operation = 'asset.verified'
                   ),
                   (
                     SELECT count(*)
                     FROM core.outbox_events
                     WHERE event_type = 'asset.finalize_requested'
                       AND payload ->> 'asset_id' = $2
                   ),
                   (
                     SELECT count(*)
                     FROM jobs.effect_receipts
                     WHERE submission_id = $3
                   )
                 """,
                 [
                   Ecto.UUID.dump!(upload.asset_id),
                   upload.asset_id,
                   Ecto.UUID.dump!(envelope.job_id)
                 ]
               )

      :ok
    end)
  end

  test "matching size and hash cannot substitute arbitrary bytes for the format envelope", %{
    fixture: fixture,
    storage_root: storage_root
  } do
    upload =
      sealed_upload!(fixture, storage_root,
        ciphertext: :binary.copy(<<0xC7>>, 170),
        lookup_digest: :binary.copy(<<0x3C>>, 32)
      )

    envelope = submitted_envelope!(fixture, upload.asset_id, "asset.verify_requested")

    assert {:error, %Error{code: :integrity_failure}} =
             run_job(Verify, envelope, storage_root)

    scoped(fixture, fn repo ->
      assert %{rows: [["uploaded", 1, 0, 0, 0]]} =
               query!(
                 repo,
                 """
                 SELECT
                   asset.state,
                   asset.state_revision,
                   (
                     SELECT count(*)
                     FROM audit.events
                     WHERE target_id = asset.id
                       AND operation = 'asset.verified'
                   ),
                   (
                     SELECT count(*)
                     FROM core.outbox_events
                     WHERE event_type = 'asset.finalize_requested'
                       AND payload ->> 'asset_id' = asset.id::text
                   ),
                   (
                     SELECT count(*)
                     FROM jobs.effect_receipts
                     WHERE submission_id = $2
                   )
                 FROM content.assets AS asset
                 WHERE asset.id = $1
                 """,
                 [
                   Ecto.UUID.dump!(upload.asset_id),
                   Ecto.UUID.dump!(envelope.job_id)
                 ]
               )

      :ok
    end)
  end

  test "verification rejects a job whose capability was substituted", %{
    fixture: fixture,
    storage_root: storage_root
  } do
    upload =
      sealed_upload!(fixture, storage_root,
        plaintext: "verify-bytes",
        lookup_digest: :binary.copy(<<0x4D>>, 32)
      )

    envelope = submitted_envelope!(fixture, upload.asset_id, "asset.verify_requested")
    substituted = %{envelope | required_capability: "asset.read"}

    assert {:error, %Error{code: :invalid}} =
             run_job(Verify, substituted, storage_root)

    scoped(fixture, fn repo ->
      assert %{rows: [["uploaded", 1, 0]]} =
               query!(
                 repo,
                 """
                 SELECT
                   state,
                   state_revision,
                   (
                     SELECT count(*)
                     FROM jobs.effect_receipts
                     WHERE submission_id = $2
                   )
                 FROM content.assets
                 WHERE id = $1
                 """,
                 [
                   Ecto.UUID.dump!(upload.asset_id),
                   Ecto.UUID.dump!(envelope.job_id)
                 ]
               )

      :ok
    end)
  end

  test "finalization reserves, publishes, and atomically acknowledges one canonical object", %{
    fixture: fixture,
    storage_root: storage_root
  } do
    {upload, verify_envelope} =
      verified_upload!(fixture, storage_root,
        plaintext: "canonical bytes",
        lookup_digest: :binary.copy(<<0x5E>>, 32)
      )

    envelope =
      submitted_envelope!(fixture, upload.asset_id, "asset.finalize_requested")

    assert {:ok,
            %{
              id: asset_id,
              asset_object_id: object_id,
              state: :available,
              state_revision: 3
            } = available} =
             run_job(Finalize, envelope, storage_root)

    assert asset_id == upload.asset_id
    assert object_id == upload.candidate_object_id
    refute Map.has_key?(Map.from_struct(available), :deduplicated?)

    assert {:ok,
            %{
              byte_size: ciphertext_size,
              ciphertext_hash: ciphertext_hash
            }} =
             LocalFilesystemAdapter.stat(
               object_storage_context(storage_root, upload, object_id),
               %ObjectRef{object_id: object_id}
             )

    assert ciphertext_size == upload.ciphertext_byte_size
    assert ciphertext_hash == upload.ciphertext_hash

    scoped(fixture, fn repo ->
      assert %{
               rows: [
                 [
                   "available",
                   3,
                   stored_object_id,
                   "finalized",
                   2,
                   "available",
                   1,
                   object_storage_ref,
                   envelope_algorithm,
                   envelope_generation,
                   wrapped_dek
                 ]
               ]
             } =
               query!(
                 repo,
                 """
                 SELECT
                   asset.state,
                   asset.state_revision,
                   asset.asset_object_id,
                   stage.state,
                   stage.state_revision,
                   object.lifecycle,
                   object.lifecycle_revision,
                   object.storage_ref,
                   key_envelope.algorithm,
                   key_envelope.key_generation,
                   key_envelope.wrapped_dek
                 FROM content.assets AS asset
                 JOIN content.asset_stages AS stage
                   ON stage.asset_id = asset.id
                  AND stage.vault_id = asset.vault_id
                 JOIN content.asset_objects AS object
                   ON object.id = asset.asset_object_id
                  AND object.vault_id = asset.vault_id
                 JOIN content.asset_key_envelopes AS key_envelope
                   ON key_envelope.asset_object_id = object.id
                  AND key_envelope.vault_id = object.vault_id
                 WHERE asset.id = $1
                 """,
                 [Ecto.UUID.dump!(upload.asset_id)]
               )

      assert load_uuid(stored_object_id) == object_id
      assert object_storage_ref == object_id
      assert envelope_algorithm == "aes_256_gcm"
      assert envelope_generation == 1
      assert byte_size(wrapped_dek) == 60

      assert %{rows: [[1, 1, 1, 1, 1]]} =
               finalization_effect_counts(
                 repo,
                 upload.asset_id,
                 object_id,
                 envelope.job_id
               )

      :ok
    end)

    assert {:ok, %{state: :available, state_revision: 3}} =
             run_job(Finalize, envelope, storage_root)

    assert {:ok, %{state: :available, state_revision: 3}} =
             run_job(Verify, verify_envelope, storage_root)

    scoped(fixture, fn repo ->
      assert %{rows: [[1, 1, 1, 1, 1]]} =
               finalization_effect_counts(
                 repo,
                 upload.asset_id,
                 object_id,
                 envelope.job_id
               )

      :ok
    end)
  end

  test "a failed acknowledgement after publication resumes from reservation and receipt", %{
    fixture: fixture,
    storage_root: storage_root
  } do
    {upload, _verify_envelope} =
      verified_upload!(fixture, storage_root,
        plaintext: "restartable bytes",
        lookup_digest: :binary.copy(<<0x6F>>, 32)
      )

    envelope =
      submitted_envelope!(fixture, upload.asset_id, "asset.finalize_requested")

    failure = start_supervised!({Agent, fn -> :pending end})

    assert {:error, %Error{code: :storage_unavailable, retryable?: true}} =
             run_job(Finalize, envelope, storage_root, assets: {FailOnceAcknowledgement, failure})

    scoped(fixture, fn repo ->
      assert %{rows: [["verified", 2, nil, "sealed", 1, "staged", 0, 1]]} =
               query!(
                 repo,
                 """
                 SELECT
                   asset.state,
                   asset.state_revision,
                   asset.asset_object_id,
                   stage.state,
                   stage.state_revision,
                   object.lifecycle,
                   object.lifecycle_revision,
                   (
                     SELECT count(*)
                     FROM content.asset_key_envelopes
                     WHERE asset_object_id = object.id
                       AND vault_id = object.vault_id
                   )
                 FROM content.assets AS asset
                 JOIN content.asset_stages AS stage
                   ON stage.asset_id = asset.id
                  AND stage.vault_id = asset.vault_id
                 JOIN content.asset_objects AS object
                   ON object.id = stage.candidate_object_id
                  AND object.vault_id = stage.vault_id
                 WHERE asset.id = $1
                 """,
                 [Ecto.UUID.dump!(upload.asset_id)]
               )

      :ok
    end)

    assert {:error, %Error{code: :not_found}} =
             LocalFilesystemAdapter.stat_stage(
               %{root: storage_root},
               %StageRef{stage_id: upload.stage_id}
             )

    assert {:ok, %{byte_size: byte_size, ciphertext_hash: ciphertext_hash}} =
             LocalFilesystemAdapter.stat(
               object_storage_context(
                 storage_root,
                 upload,
                 upload.candidate_object_id
               ),
               %ObjectRef{object_id: upload.candidate_object_id}
             )

    assert byte_size == upload.ciphertext_byte_size
    assert ciphertext_hash == upload.ciphertext_hash

    assert {:ok,
            %{
              asset_object_id: object_id,
              state: :available,
              state_revision: 3
            }} =
             run_job(Finalize, envelope, storage_root)

    assert object_id == upload.candidate_object_id

    scoped(fixture, fn repo ->
      assert %{rows: [[1, 1, 1, 1, 1]]} =
               finalization_effect_counts(
                 repo,
                 upload.asset_id,
                 object_id,
                 envelope.job_id
               )

      :ok
    end)
  end

  test "deduplication reuses only an available same-vault and same-domain object", %{
    fixture: fixture,
    other: other,
    storage_root: storage_root
  } do
    digest = :binary.copy(<<0x7A>>, 32)

    {first, _first_verify} =
      verified_upload!(fixture, storage_root,
        plaintext: "duplicate bytes",
        lookup_digest: digest
      )

    {second, _second_verify} =
      verified_upload!(fixture, storage_root,
        plaintext: "duplicate bytes",
        lookup_digest: digest
      )

    first_envelope =
      submitted_envelope!(fixture, first.asset_id, "asset.finalize_requested")

    second_envelope =
      submitted_envelope!(fixture, second.asset_id, "asset.finalize_requested")

    assert {:ok, %{asset_object_id: canonical_id, state: :available}} =
             run_job(Finalize, first_envelope, storage_root)

    assert {:ok, %{asset_object_id: reused_id, state: :available} = reused} =
             run_job(Finalize, second_envelope, storage_root)

    assert reused_id == canonical_id
    refute Map.has_key?(Map.from_struct(reused), :deduplicated?)

    assert {:error, %Error{code: :not_found}} =
             LocalFilesystemAdapter.stat_stage(
               %{root: storage_root},
               %StageRef{stage_id: second.stage_id}
             )

    scoped(fixture, fn repo ->
      assert %{rows: [[1, 1, 2, 0]]} =
               query!(
                 repo,
                 """
                 SELECT
                   (
                     SELECT count(*)
                     FROM content.asset_objects
                     WHERE vault_id = $1
                       AND key_domain_id = $2
                       AND lookup_digest = $3
                       AND lifecycle = 'available'
                   ),
                   (
                     SELECT count(*)
                     FROM content.asset_key_envelopes
                     WHERE asset_object_id = $4
                       AND vault_id = $1
                   ),
                   (
                     SELECT count(*)
                     FROM content.assets
                     WHERE asset_object_id = $4
                       AND vault_id = $1
                       AND state = 'available'
                   ),
                   (
                     SELECT count(*)
                     FROM content.asset_key_envelopes
                     WHERE asset_object_id = $5
                       AND vault_id = $1
                   )
                 """,
                 [
                   Ecto.UUID.dump!(fixture.vault_id),
                   Ecto.UUID.dump!(fixture.key_domain_id),
                   digest,
                   Ecto.UUID.dump!(canonical_id),
                   Ecto.UUID.dump!(second.candidate_object_id)
                 ]
               )

      :ok
    end)

    {isolated, _isolated_verify} =
      verified_upload!(other, storage_root,
        plaintext: "duplicate bytes",
        lookup_digest: digest
      )

    isolated_envelope =
      submitted_envelope!(other, isolated.asset_id, "asset.finalize_requested")

    assert {:ok, %{asset_object_id: isolated_id, state: :available}} =
             run_job(Finalize, isolated_envelope, storage_root)

    refute isolated_id == canonical_id

    Fixtures.with_owner(fn ->
      assert %{rows: [[2, 2]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT
                   count(*),
                   count(DISTINCT vault_id)
                 FROM content.asset_objects
                 WHERE lookup_digest = $1
                   AND lifecycle = 'available'
                 """,
                 [digest]
               )
    end)
  end

  test "concurrent first reservations retry the unique-index loser and converge", %{
    fixture: fixture,
    storage_root: storage_root
  } do
    digest = :binary.copy(<<0x8B>>, 32)

    {first, _first_verify} =
      verified_upload!(fixture, storage_root,
        plaintext: "concurrent duplicate",
        lookup_digest: digest
      )

    {second, _second_verify} =
      verified_upload!(fixture, storage_root,
        plaintext: "concurrent duplicate",
        lookup_digest: digest
      )

    first_envelope =
      submitted_envelope!(fixture, first.asset_id, "asset.finalize_requested")

    second_envelope =
      submitted_envelope!(fixture, second.asset_id, "asset.finalize_requested")

    install_reservation_pause!(digest)
    owner = self()
    barrier = {ReservationBarrierRepository, owner}

    tasks =
      for envelope <- [first_envelope, second_envelope] do
        Task.async(fn ->
          {envelope, run_job(Finalize, envelope, storage_root, assets: barrier)}
        end)
      end

    reservations =
      for _index <- 1..2 do
        assert_receive {:reservation_ready, worker, job_id}, 2_000
        {worker, job_id}
      end

    Enum.each(reservations, fn {worker, job_id} ->
      send(worker, {:release_reservation, job_id})
    end)

    results = Enum.map(tasks, &Task.await(&1, 10_000))

    assert [{winner_envelope, {:ok, winner}}] =
             Enum.filter(results, fn {_envelope, result} ->
               match?({:ok, %{state: :available}}, result)
             end)

    assert [
             {loser_envelope,
              {:error,
               %Error{
                 code: :storage_unavailable,
                 retryable?: true
               }}}
           ] =
             Enum.reject(results, fn {_envelope, result} ->
               match?({:ok, %{state: :available}}, result)
             end)

    assert winner_envelope.job_id != loser_envelope.job_id

    assert {:ok,
            %{
              asset_object_id: converged_object_id,
              state: :available
            }} =
             run_job(Finalize, loser_envelope, storage_root)

    assert converged_object_id == winner.asset_object_id

    scoped(fixture, fn repo ->
      assert %{rows: [[1, 2]]} =
               query!(
                 repo,
                 """
                 SELECT
                   (
                     SELECT count(*)
                     FROM content.asset_objects
                     WHERE vault_id = $1
                       AND key_domain_id = $2
                       AND lookup_digest = $3
                       AND lifecycle = 'available'
                   ),
                   (
                     SELECT count(*)
                     FROM content.assets
                     WHERE vault_id = $1
                       AND asset_object_id = $4
                       AND state = 'available'
                   )
                 """,
                 [
                   Ecto.UUID.dump!(fixture.vault_id),
                   Ecto.UUID.dump!(fixture.key_domain_id),
                   digest,
                   Ecto.UUID.dump!(converged_object_id)
                 ]
               )

      :ok
    end)
  end

  defp run_job(module, envelope, storage_root, options \\ []) do
    WorkerScope.run(envelope, fn worker_context ->
      context =
        Map.merge(worker_context, %{
          assets: Keyword.get(options, :assets, AssetRepository),
          authorization: :test_authorization,
          authorize: AllowAuthorization,
          custodian: RejectKeyLease,
          object_lock: ObjectLock,
          storage: {LocalFilesystemAdapter, %{root: storage_root}}
        })

      module.run(context, envelope)
    end)
  end

  defp verified_upload!(fixture, storage_root, options) do
    upload = sealed_upload!(fixture, storage_root, options)
    envelope = submitted_envelope!(fixture, upload.asset_id, "asset.verify_requested")

    assert {:ok, %{state: :verified, state_revision: 2}} =
             run_job(Verify, envelope, storage_root)

    {upload, envelope}
  end

  defp sealed_upload!(fixture, storage_root, options) do
    token = :crypto.strong_rand_bytes(32)
    observed_at = DateTime.utc_now(:microsecond)
    stage_id = Ecto.UUID.generate()
    candidate_object_id = Ecto.UUID.generate()
    lookup_digest = Keyword.fetch!(options, :lookup_digest)

    ciphertext =
      Keyword.get_lazy(options, :ciphertext, fn ->
        assert {:ok, ciphertext} =
                 ChunkedAEAD.encode(%{
                   key: :crypto.strong_rand_bytes(32),
                   plaintext: Keyword.fetch!(options, :plaintext),
                   format_version: 1,
                   algorithm: :aes_256_gcm,
                   chunk_size: 4_194_304,
                   vault_id: fixture.vault_id,
                   encryption_domain_id: fixture.key_domain_id,
                   object_id: candidate_object_id,
                   chunk_index: 0
                 })

        ciphertext
      end)

    grant_command = %{
      grant_id: Ecto.UUID.generate(),
      asset_id: Ecto.UUID.generate(),
      source_reference_id: Ecto.UUID.generate(),
      session_id: fixture.session_id,
      principal_id: fixture.principal_id,
      vault_id: fixture.vault_id,
      resource_version_id: fixture.resource_version_id,
      filename: "verification-evidence.pdf",
      byte_size: 12,
      declared_media_type: "application/pdf",
      idempotency_key: "verify-#{Ecto.UUID.generate()}",
      classification: :private,
      token_digest: :crypto.hash(:sha256, token),
      expires_at: DateTime.add(observed_at, 300, :second),
      observed_at: observed_at
    }

    assert {:ok, grant} =
             scoped(fixture, fn repo ->
               AssetRepository.create_upload_grant(repo, grant_command)
             end)

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
      candidate_object_id: candidate_object_id,
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

    storage_context = %{root: storage_root}
    stage_ref = %StageRef{stage_id: stage.id}

    assert {:ok, ^stage_ref} =
             LocalFilesystemAdapter.stage(storage_context, %{stage_id: stage.id})

    assert :ok =
             LocalFilesystemAdapter.append_encrypted_chunk(
               storage_context,
               stage_ref,
               ciphertext
             )

    assert {:ok, stat} =
             LocalFilesystemAdapter.seal_stage(storage_context, stage_ref, %{})

    recorded_hash =
      Keyword.get(options, :recorded_ciphertext_hash, stat.ciphertext_hash)

    checkpoint = %{
      stage_ref: stage_ref,
      storage_ref: stage.storage_ref,
      grant_id: grant.id,
      session_id: grant.session_id,
      principal_id: grant.principal_id,
      vault_id: grant.vault_id,
      asset_id: grant.asset_id,
      classification: grant.classification,
      expected_stage_revision: 0,
      expected_asset_revision: 0,
      format_version: 1,
      plaintext_byte_size: grant.byte_size,
      ciphertext_byte_size: stat.byte_size,
      lookup_digest: lookup_digest,
      ciphertext_hash: recorded_hash,
      sealed_at: DateTime.utc_now(:microsecond)
    }

    assert {:ok,
            %{
              asset: %{state: :uploaded, state_revision: 1},
              stage: %{state: :sealed, state_revision: 1}
            }} =
             scoped(fixture, fn repo ->
               AssetRepository.record_sealed_stage(repo, checkpoint)
             end)

    %{
      asset_id: grant.asset_id,
      candidate_object_id: candidate_object_id,
      ciphertext_byte_size: stat.byte_size,
      ciphertext_hash: recorded_hash,
      key_domain_id: fixture.key_domain_id,
      lookup_digest: lookup_digest,
      stage_id: stage.id,
      vault_id: fixture.vault_id
    }
  end

  defp submitted_envelope!(fixture, asset_id, event_type) do
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

        {:ok, envelope} =
          JobEnvelope.new(%{
            version: 1,
            job_id: load_uuid(id),
            job_type: job_type(event_type),
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

  defp job_type("asset.verify_requested"), do: "asset_verify"
  defp job_type("asset.finalize_requested"), do: "asset_finalize"

  defp finalization_effect_counts(repo, asset_id, object_id, job_id) do
    query!(
      repo,
      """
      SELECT
        (
          SELECT count(*)
          FROM content.asset_objects
          WHERE id = $1
            AND lifecycle = 'available'
        ),
        (
          SELECT count(*)
          FROM content.asset_key_envelopes
          WHERE asset_object_id = $1
        ),
        (
          SELECT count(*)
          FROM audit.events
          WHERE target_id = $2
            AND operation = 'asset.available'
        ),
        (
          SELECT count(*)
          FROM core.outbox_events
          WHERE event_type = 'asset.metadata_requested'
            AND payload ->> 'asset_id' = $3
            AND expected_entity_revision = 3
        ),
        (
          SELECT count(*)
          FROM jobs.effect_receipts
          WHERE submission_id = $4
            AND result = 'applied'
            AND entity_revision = 3
        )
      """,
      [
        Ecto.UUID.dump!(object_id),
        Ecto.UUID.dump!(asset_id),
        asset_id,
        Ecto.UUID.dump!(job_id)
      ]
    )
  end

  defp object_storage_context(storage_root, upload, object_id) do
    %{
      root: storage_root,
      vault_namespace: upload.vault_id,
      domain_namespace: upload.key_domain_id,
      lookup_digest: Base.encode16(upload.lookup_digest, case: :lower),
      ciphertext_hash: upload.ciphertext_hash,
      object_id: object_id
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

  defp storage_root do
    Application.fetch_env!(:singularity_storage, :storage_root)
  end

  defp install_reservation_pause!(digest) do
    digest_hex = Base.encode16(digest, case: :lower)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        CREATE OR REPLACE FUNCTION content.test_pause_asset_reservation()
        RETURNS trigger
        LANGUAGE plpgsql
        SET search_path = pg_catalog
        AS $$
        BEGIN
          IF NEW.lookup_digest = decode('#{digest_hex}', 'hex') THEN
            PERFORM pg_sleep(0.5);
          END IF;
          RETURN NEW;
        END
        $$
        """
      )

      query!(
        MigrationRepo,
        """
        CREATE TRIGGER test_pause_asset_reservation
        BEFORE INSERT ON content.asset_objects
        FOR EACH ROW
        EXECUTE FUNCTION content.test_pause_asset_reservation()
        """
      )
    end)
  end
end
