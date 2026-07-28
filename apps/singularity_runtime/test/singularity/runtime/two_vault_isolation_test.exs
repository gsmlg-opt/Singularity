defmodule Singularity.Runtime.TwoVaultIsolationTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope
  alias Singularity.Core.StageRef
  alias Singularity.Runtime.Assets.Finalize
  alias Singularity.Runtime.Assets.Verify
  alias Singularity.Storage.Crypto.ChunkedAEAD
  alias Singularity.Storage.Crypto.KeyWrapper
  alias Singularity.Storage.Crypto.ObjectIdentity
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.Jobs.ObanAdapter
  alias Singularity.Storage.Jobs.WorkerScope
  alias Singularity.Storage.LocalFilesystemAdapter
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.ObjectLock
  alias Singularity.Storage.Postgres.AssetRepository
  alias Singularity.Storage.Schema.Content.AssetObject
  alias Singularity.Storage.Schema.Content.AssetStage
  alias Singularity.Storage.ScopedRepo

  defmodule AllowAuthorization do
    def check_job(_authorization, _repo, _envelope), do: :ok
  end

  setup do
    %{one: raw_one, two: raw_two} = Fixtures.two_vaults!()

    one =
      raw_one
      |> load_ids()
      |> Map.merge(insert_crypto_domain!(raw_one.vault_id))

    two =
      raw_two
      |> load_ids()
      |> Map.merge(insert_crypto_domain!(raw_two.vault_id))

    {:ok, one: one, two: two, storage_root: storage_root()}
  end

  test "rotation preserves same-vault canonical reuse without a cross-vault existence signal",
       %{one: one, two: two, storage_root: storage_root} do
    plaintext = "%PDF-1.7\nidentical private bytes\n%%EOF"
    plaintext_sha256 = :crypto.hash(:sha256, plaintext)

    assert {:ok, one_lookup_digest} =
             ObjectIdentity.lookup_digest(
               one.domain_dedup_key,
               plaintext_sha256
             )

    assert {:ok, two_lookup_digest} =
             ObjectIdentity.lookup_digest(
               two.domain_dedup_key,
               plaintext_sha256
             )

    refute one_lookup_digest == two_lookup_digest

    {first, _first_verify} =
      verified_upload!(one, storage_root,
        plaintext: plaintext,
        lookup_digest: one_lookup_digest
      )

    first_finalize =
      submitted_envelope!(one, first.asset_id, "asset.finalize_requested")

    assert {:ok,
            %{
              asset_object_id: canonical_object_id,
              state: :available,
              state_revision: 3
            } = first_available} =
             run_job(Finalize, first_finalize, storage_root)

    assert canonical_object_id == first.candidate_object_id

    rotated = rotate_crypto_domain!(one, first)

    assert rotated.domain_dedup_key == one.domain_dedup_key
    assert rotated.domain_key != one.domain_key
    assert rotated.key_generation == 2

    assert {:ok, rotated_lookup_digest} =
             ObjectIdentity.lookup_digest(
               rotated.domain_dedup_key,
               plaintext_sha256
             )

    assert rotated_lookup_digest == one_lookup_digest

    {second, _second_verify} =
      verified_upload!(rotated, storage_root,
        plaintext: plaintext,
        lookup_digest: rotated_lookup_digest
      )

    second_finalize =
      submitted_envelope!(rotated, second.asset_id, "asset.finalize_requested")

    assert {:ok,
            %{
              asset_object_id: reused_object_id,
              state: :available,
              state_revision: 3
            } = reused_available} =
             run_job(Finalize, second_finalize, storage_root)

    assert reused_object_id == canonical_object_id
    refute second.candidate_object_id == canonical_object_id

    assert {:error, %Error{code: :not_found}} =
             LocalFilesystemAdapter.stat_stage(
               %{root: storage_root},
               %StageRef{stage_id: second.stage_id}
             )

    {isolated, _isolated_verify} =
      verified_upload!(two, storage_root,
        plaintext: plaintext,
        lookup_digest: two_lookup_digest
      )

    isolated_finalize =
      submitted_envelope!(two, isolated.asset_id, "asset.finalize_requested")

    assert {:ok,
            %{
              asset_object_id: isolated_object_id,
              state: :available,
              state_revision: 3
            } = isolated_available} =
             run_job(Finalize, isolated_finalize, storage_root)

    refute isolated_object_id == canonical_object_id
    assert isolated_object_id == isolated.candidate_object_id

    for public_asset <- [
          first_available,
          reused_available,
          isolated_available
        ] do
      refute Map.has_key?(Map.from_struct(public_asset), :deduplicated?)
      refute Map.has_key?(Map.from_struct(public_asset), :lookup_digest)
    end

    assert Map.keys(Map.from_struct(reused_available)) ==
             Map.keys(Map.from_struct(isolated_available))

    scoped(rotated, fn repo ->
      assert {:ok,
              %{
                object_id: ^canonical_object_id,
                object_generation: 2
              }} =
               AssetRepository.authorized_object(repo, second.asset_id)

      assert [%AssetObject{id: ^canonical_object_id}] =
               repo.all(AssetObject)

      assert repo.get(AssetObject, isolated_object_id) == nil
      :ok
    end)

    cross_vault_observation =
      scoped(two, fn repo ->
        AssetRepository.authorized_object(repo, first.asset_id)
      end)

    missing_observation =
      scoped(two, fn repo ->
        AssetRepository.authorized_object(repo, Ecto.UUID.generate())
      end)

    assert {:error, %Error{code: :not_found}} = cross_vault_observation
    assert cross_vault_observation == missing_observation

    scoped(two, fn repo ->
      assert [%AssetObject{id: ^isolated_object_id}] = repo.all(AssetObject)
      assert repo.get(AssetObject, canonical_object_id) == nil
      :ok
    end)

    Fixtures.with_owner(fn ->
      assert %{rows: [[2, 2, 3, 2]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT
                   count(*),
                   count(DISTINCT object.vault_id),
                   (
                     SELECT count(*)
                     FROM content.assets
                     WHERE state = 'available'
                       AND asset_object_id IN ($1, $2)
                   ),
                   (
                     SELECT count(*)
                     FROM content.asset_key_envelopes
                     WHERE asset_object_id = $1
                   )
                 FROM content.asset_objects AS object
                 WHERE object.id IN ($1, $2)
                   AND object.lifecycle = 'available'
                 """,
                 [
                   Ecto.UUID.dump!(canonical_object_id),
                   Ecto.UUID.dump!(isolated_object_id)
                 ]
               )

      assert %{rows: [[0]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT count(*)
                 FROM content.asset_objects
                 WHERE id = $1
                 """,
                 [Ecto.UUID.dump!(second.candidate_object_id)]
               )
    end)
  end

  defp run_job(module, envelope, storage_root) do
    WorkerScope.run(envelope, fn worker_context ->
      context =
        Map.merge(worker_context, %{
          assets: AssetRepository,
          authorization: :test_authorization,
          authorize: AllowAuthorization,
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
    plaintext = Keyword.fetch!(options, :plaintext)
    lookup_digest = Keyword.fetch!(options, :lookup_digest)
    object_dek = :crypto.strong_rand_bytes(32)

    assert {:ok, ciphertext} =
             ChunkedAEAD.encode(%{
               key: object_dek,
               plaintext: plaintext,
               format_version: 1,
               algorithm: :aes_256_gcm,
               chunk_size: 4_194_304,
               vault_id: fixture.vault_id,
               encryption_domain_id: fixture.key_domain_id,
               object_id: candidate_object_id,
               chunk_index: 0
             })

    assert {:ok, dek_wrapper} =
             KeyWrapper.wrap(
               fixture.domain_key,
               object_dek,
               object_metadata(candidate_object_id, fixture.key_generation)
             )

    grant_command = %{
      grant_id: Ecto.UUID.generate(),
      asset_id: Ecto.UUID.generate(),
      source_reference_id: Ecto.UUID.generate(),
      session_id: fixture.session_id,
      principal_id: fixture.principal_id,
      vault_id: fixture.vault_id,
      resource_version_id: fixture.resource_version_id,
      filename: "dedup-isolation.pdf",
      byte_size: byte_size(plaintext),
      declared_media_type: "application/pdf",
      idempotency_key: "dedup-isolation-#{Ecto.UUID.generate()}",
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
      token_digest: :crypto.hash(:sha256, token),
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
      key_generation: fixture.key_generation,
      dek_wrapper: dek_wrapper.encoded
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
      ciphertext_hash: stat.ciphertext_hash,
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
      ciphertext_hash: stat.ciphertext_hash,
      key_domain_id: fixture.key_domain_id,
      lookup_digest: lookup_digest,
      object_dek: object_dek,
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

  defp rotate_crypto_domain!(fixture, canonical_upload) do
    next_version_id = Ecto.UUID.generate()
    next_domain_key = :crypto.strong_rand_bytes(32)
    next_generation = fixture.key_generation + 1

    assert {:ok, next_domain_wrapper} =
             KeyWrapper.wrap(
               fixture.vault_key,
               next_domain_key,
               domain_metadata(fixture.key_domain_id, next_generation)
             )

    assert {:ok, next_dedup_wrapper} =
             KeyWrapper.wrap(
               next_domain_key,
               fixture.domain_dedup_key,
               dedup_metadata(fixture.key_domain_id, next_generation)
             )

    assert {:ok, next_object_wrapper} =
             KeyWrapper.wrap(
               next_domain_key,
               canonical_upload.object_dek,
               object_metadata(
                 canonical_upload.candidate_object_id,
                 next_generation
               )
             )

    Fixtures.with_owner(fn ->
      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 """
                 UPDATE core.domain_key_versions
                 SET state = 'retired'
                 WHERE id = $1
                   AND vault_id = $2
                   AND key_domain_id = $3
                   AND generation = $4
                   AND state = 'active'
                 """,
                 [
                   Ecto.UUID.dump!(fixture.domain_key_version_id),
                   Ecto.UUID.dump!(fixture.vault_id),
                   Ecto.UUID.dump!(fixture.key_domain_id),
                   fixture.key_generation
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
          $1, $2, $3, $4, $5, 'active', 'aes_256_gcm', $6
        )
        """,
        [
          Ecto.UUID.dump!(next_version_id),
          Ecto.UUID.dump!(fixture.vault_id),
          Ecto.UUID.dump!(fixture.key_domain_id),
          Ecto.UUID.dump!(fixture.vault_key_version_id),
          next_generation,
          next_domain_wrapper.encoded
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.domain_dedup_key_wrappers (
          id,
          vault_id,
          key_domain_id,
          domain_key_version_id,
          algorithm,
          wrapped_key
        ) VALUES ($1, $2, $3, $4, 'aes_256_gcm', $5)
        """,
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          Ecto.UUID.dump!(fixture.vault_id),
          Ecto.UUID.dump!(fixture.key_domain_id),
          Ecto.UUID.dump!(next_version_id),
          next_dedup_wrapper.encoded
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO content.asset_key_envelopes (
          id,
          vault_id,
          asset_object_id,
          domain_key_version_id,
          key_domain_id,
          classification,
          algorithm,
          key_generation,
          wrapped_dek
        ) VALUES (
          $1, $2, $3, $4, $5, 'private', 'aes_256_gcm', $6, $7
        )
        """,
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          Ecto.UUID.dump!(fixture.vault_id),
          Ecto.UUID.dump!(canonical_upload.candidate_object_id),
          Ecto.UUID.dump!(next_version_id),
          Ecto.UUID.dump!(fixture.key_domain_id),
          next_generation,
          next_object_wrapper.encoded
        ]
      )
    end)

    %{
      fixture
      | domain_key: next_domain_key,
        domain_key_version_id: next_version_id,
        key_generation: next_generation
    }
  end

  defp insert_crypto_domain!(raw_vault_id) do
    vault_id = load_uuid(raw_vault_id)
    key_domain_id = Ecto.UUID.generate()
    vault_key_version_id = Ecto.UUID.generate()
    domain_key_version_id = Ecto.UUID.generate()
    vault_key = :crypto.strong_rand_bytes(32)
    domain_key = :crypto.strong_rand_bytes(32)
    domain_dedup_key = :crypto.strong_rand_bytes(32)

    assert {:ok, domain_wrapper} =
             KeyWrapper.wrap(
               vault_key,
               domain_key,
               domain_metadata(key_domain_id, 1)
             )

    assert {:ok, dedup_wrapper} =
             KeyWrapper.wrap(
               domain_key,
               domain_dedup_key,
               dedup_metadata(key_domain_id, 1)
             )

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
          domain_wrapper.encoded
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.domain_dedup_key_wrappers (
          id,
          vault_id,
          key_domain_id,
          domain_key_version_id,
          algorithm,
          wrapped_key
        ) VALUES ($1, $2, $3, $4, 'aes_256_gcm', $5)
        """,
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          raw_vault_id,
          Ecto.UUID.dump!(key_domain_id),
          Ecto.UUID.dump!(domain_key_version_id),
          dedup_wrapper.encoded
        ]
      )
    end)

    %{
      vault_id: vault_id,
      vault_key: vault_key,
      vault_key_version_id: vault_key_version_id,
      key_domain_id: key_domain_id,
      domain_key: domain_key,
      domain_key_version_id: domain_key_version_id,
      domain_dedup_key: domain_dedup_key,
      key_generation: 1
    }
  end

  defp domain_metadata(key_domain_id, generation) do
    %{
      purpose: :domain_key,
      generation: generation,
      aad: "domain:#{key_domain_id}"
    }
  end

  defp dedup_metadata(key_domain_id, generation) do
    %{
      purpose: :domain_dedup_key,
      generation: generation,
      aad: "dedup:#{key_domain_id}"
    }
  end

  defp object_metadata(object_id, generation) do
    %{
      purpose: :object_dek,
      generation: generation,
      aad: "object:#{object_id}"
    }
  end

  defp scoped(fixture, callback) do
    ScopedRepo.transact(
      RequestRepo,
      %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
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

  defp storage_root do
    Application.fetch_env!(:singularity_storage, :storage_root)
  end
end
