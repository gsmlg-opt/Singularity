defmodule Singularity.Storage.AssetSealedCheckpointTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Core.StageRef
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.Postgres.AssetRepository
  alias Singularity.Storage.Schema.Content.AssetStage
  alias Singularity.Storage.ScopedRepo

  setup do
    %{one: raw_fixture} = Fixtures.two_vaults!()

    fixture =
      raw_fixture
      |> load_ids()
      |> Map.merge(insert_key_domain!(raw_fixture.vault_id))

    {:ok, fixture: fixture}
  end

  test "durably acknowledges an exact sealed stage and schedules verification atomically", %{
    fixture: fixture
  } do
    upload = open_stage!(fixture)
    command = sealed_checkpoint(upload)

    assert {:ok,
            %{
              asset: %{state: :uploaded, state_revision: 1},
              stage: %{state: :sealed, state_revision: 1}
            } = checkpoint} =
             scoped(fixture, fn repo ->
               AssetRepository.record_sealed_stage(repo, command)
             end)

    refute Map.has_key?(checkpoint, :object_dek)
    refute Map.has_key?(checkpoint, :plaintext_sha256)

    scoped(fixture, fn repo ->
      assert %{
               rows: [
                 [
                   "sealed",
                   1,
                   1,
                   plaintext_byte_size,
                   ciphertext_byte_size,
                   lookup_digest,
                   ciphertext_hash,
                   sealed_at,
                   storage_ref,
                   wrapper_algorithm,
                   key_generation,
                   dek_wrapper,
                   "uploaded",
                   1
                 ]
               ]
             } =
               query!(
                 repo,
                 """
                 SELECT
                   stage.state,
                   stage.state_revision,
                   stage.format_version,
                   stage.plaintext_byte_size,
                   stage.ciphertext_byte_size,
                   stage.lookup_digest,
                   stage.ciphertext_hash,
                   stage.sealed_at,
                   stage.storage_ref,
                   stage.wrapper_algorithm,
                   stage.key_generation,
                   stage.dek_wrapper,
                   asset.state,
                   asset.state_revision
                 FROM content.asset_stages AS stage
                 JOIN content.assets AS asset
                   ON asset.id = stage.asset_id
                  AND asset.vault_id = stage.vault_id
                 WHERE stage.id = $1
                 """,
                 [Ecto.UUID.dump!(upload.stage.id)]
               )

      assert plaintext_byte_size == command.plaintext_byte_size
      assert ciphertext_byte_size == command.ciphertext_byte_size
      assert lookup_digest == command.lookup_digest
      assert ciphertext_hash == command.ciphertext_hash
      assert sealed_at == command.sealed_at
      assert storage_ref == command.storage_ref
      assert wrapper_algorithm == upload.stage.wrapper_algorithm
      assert key_generation == upload.stage.key_generation
      assert dek_wrapper == upload.stage.dek_wrapper

      assert %{
               rows: [
                 [
                   original_filename,
                   declared_media_type,
                   plaintext_size,
                   "pending",
                   1,
                   source_filename,
                   source_media_type,
                   source_size
                 ]
               ]
             } =
               query!(
                 repo,
                 """
                 SELECT
                   metadata.original_filename,
                   metadata.declared_media_type,
                   metadata.plaintext_byte_size,
                   metadata.extraction_state,
                   metadata.projection_version,
                   source.original_filename,
                   source.declared_media_type,
                   source.byte_size
                 FROM content.asset_metadata AS metadata
                 JOIN content.source_references AS source
                   ON source.id = $2
                  AND source.resource_version_id = metadata.resource_version_id
                  AND source.vault_id = metadata.vault_id
                 WHERE metadata.asset_id = $1
                 """,
                 [
                   Ecto.UUID.dump!(command.asset_id),
                   Ecto.UUID.dump!(upload.grant.source_reference_id)
                 ]
               )

      assert original_filename == upload.grant.filename
      assert original_filename == source_filename
      assert declared_media_type == upload.grant.declared_media_type
      assert declared_media_type == source_media_type
      assert plaintext_size == upload.grant.byte_size
      assert plaintext_size == source_size

      assert %{rows: [[principal_epoch, vault_epoch]]} =
               query!(
                 repo,
                 """
                 SELECT
                   principal_authorization_epoch,
                   vault_authorization_epoch
                 FROM core.live_principal_authorization()
                 """
               )

      assert %{
               rows: [
                 [
                   "asset.uploaded",
                   "completed",
                   "principal",
                   audit_principal_id,
                   "private",
                   audit_target_id,
                   audit_metadata
                 ]
               ]
             } =
               query!(
                 repo,
                 """
                 SELECT
                   operation,
                   result,
                   actor_kind,
                   principal_id,
                   classification,
                   target_id,
                   metadata
                 FROM audit.events
                 WHERE target_id = $1
                 """,
                 [Ecto.UUID.dump!(command.asset_id)]
               )

      assert Ecto.UUID.load!(audit_principal_id) == command.principal_id
      assert Ecto.UUID.load!(audit_target_id) == command.asset_id
      refute Map.has_key?(audit_metadata, "object_dek")
      refute Map.has_key?(audit_metadata, "plaintext_sha256")

      assert_persisted_audit!(
        repo,
        "asset.uploaded",
        [target_id: command.asset_id],
        actor_kind: "principal",
        result: "completed",
        target_type: "asset"
      )

      assert %{
               rows: [
                 [
                   "asset.verify_requested",
                   "asset.write",
                   outbox_principal_id,
                   "private",
                   ^principal_epoch,
                   ^vault_epoch,
                   1,
                   payload
                 ]
               ]
             } =
               query!(
                 repo,
                 """
                 SELECT
                   event_type,
                   required_capability,
                   principal_id,
                   classification,
                   principal_authorization_epoch,
                   vault_authorization_epoch,
                   expected_entity_revision,
                   payload
                 FROM core.outbox_events
                 WHERE event_type = 'asset.verify_requested'
                   AND payload ->> 'asset_id' = $1
                 """,
                 [command.asset_id]
               )

      assert Ecto.UUID.load!(outbox_principal_id) == command.principal_id
      assert payload["asset_id"] == command.asset_id
      refute Map.has_key?(payload, "object_dek")
      refute Map.has_key?(payload, "plaintext_sha256")
      :ok
    end)
  end

  test "an exact retry with stale expected revisions is a no-op", %{fixture: fixture} do
    upload = open_stage!(fixture)
    command = sealed_checkpoint(upload)

    assert {:ok,
            %{
              asset: %{state: :uploaded, state_revision: 1},
              stage: %{state: :sealed, state_revision: 1}
            }} =
             scoped(fixture, fn repo ->
               AssetRepository.record_sealed_stage(repo, command)
             end)

    assert {:ok,
            %{
              asset: %{state: :uploaded, state_revision: 1},
              stage: %{state: :sealed, state_revision: 1}
            }} =
             scoped(fixture, fn repo ->
               AssetRepository.record_sealed_stage(repo, command)
             end)

    scoped(fixture, fn repo ->
      assert %{rows: [[1, 1, 1]]} =
               checkpoint_effect_counts(repo, command.asset_id)

      assert %{rows: [["sealed", 1, "uploaded", 1]]} =
               query!(
                 repo,
                 """
                 SELECT
                   stage.state,
                   stage.state_revision,
                   asset.state,
                   asset.state_revision
                 FROM content.asset_stages AS stage
                 JOIN content.assets AS asset
                   ON asset.id = stage.asset_id
                  AND asset.vault_id = stage.vault_id
                 WHERE stage.id = $1
                 """,
                 [Ecto.UUID.dump!(upload.stage.id)]
               )

      :ok
    end)
  end

  test "a final byte-count mismatch rolls back every sealed-stage effect", %{
    fixture: fixture
  } do
    upload = open_stage!(fixture)

    command =
      upload
      |> sealed_checkpoint()
      |> Map.update!(:plaintext_byte_size, &(&1 + 1))

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, fn repo ->
               AssetRepository.record_sealed_stage(repo, command)
             end)

    scoped(fixture, fn repo ->
      assert %{
               rows: [
                 [
                   "open",
                   0,
                   nil,
                   nil,
                   nil,
                   nil,
                   nil,
                   nil,
                   wrapper_algorithm,
                   key_generation,
                   dek_wrapper,
                   "staging",
                   0,
                   consumed_at
                 ]
               ]
             } =
               query!(
                 repo,
                 """
                 SELECT
                   stage.state,
                   stage.state_revision,
                   stage.format_version,
                   stage.plaintext_byte_size,
                   stage.ciphertext_byte_size,
                   stage.lookup_digest,
                   stage.ciphertext_hash,
                   stage.sealed_at,
                   stage.wrapper_algorithm,
                   stage.key_generation,
                   stage.dek_wrapper,
                   asset.state,
                   asset.state_revision,
                   upload_grant.consumed_at
                 FROM content.asset_stages AS stage
                 JOIN content.assets AS asset
                   ON asset.id = stage.asset_id
                  AND asset.vault_id = stage.vault_id
                 JOIN content.upload_grants AS upload_grant
                   ON upload_grant.id = stage.upload_grant_id
                  AND upload_grant.vault_id = stage.vault_id
                 WHERE stage.id = $1
                 """,
                 [Ecto.UUID.dump!(upload.stage.id)]
               )

      assert wrapper_algorithm == upload.stage.wrapper_algorithm
      assert key_generation == upload.stage.key_generation
      assert dek_wrapper == upload.stage.dek_wrapper
      assert %DateTime{} = consumed_at

      assert %{rows: [[0, 0, 0]]} =
               checkpoint_effect_counts(repo, command.asset_id)

      :ok
    end)
  end

  defp open_stage!(fixture) do
    token = :crypto.strong_rand_bytes(32)
    csrf_token = :crypto.strong_rand_bytes(32)
    observed_at = DateTime.utc_now(:microsecond)

    grant_command = %{
      grant_id: Ecto.UUID.generate(),
      asset_id: Ecto.UUID.generate(),
      source_reference_id: Ecto.UUID.generate(),
      session_id: fixture.session_id,
      principal_id: fixture.principal_id,
      vault_id: fixture.vault_id,
      resource_version_id: fixture.resource_version_id,
      filename: "sealed-evidence.pdf",
      byte_size: 12,
      declared_media_type: "application/pdf",
      idempotency_key: "sealed-checkpoint-#{Ecto.UUID.generate()}",
      classification: :private,
      token_digest: :crypto.hash(:sha256, token),
      csrf_token_digest: :crypto.hash(:sha256, csrf_token),
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
      csrf_token_digest: :crypto.hash(:sha256, csrf_token),
      session_id: grant.session_id,
      principal_id: grant.principal_id,
      vault_id: grant.vault_id,
      asset_id: grant.asset_id,
      filename: grant.filename,
      byte_size: grant.byte_size,
      declared_media_type: grant.declared_media_type,
      request_content_length: grant.byte_size,
      request_declared_media_type: grant.declared_media_type,
      idempotency_key: grant.idempotency_key,
      classification: grant.classification,
      principal_authorization_epoch: grant.principal_authorization_epoch,
      vault_authorization_epoch: grant.vault_authorization_epoch,
      stage_id: Ecto.UUID.generate(),
      candidate_object_id: Ecto.UUID.generate(),
      key_domain_id: fixture.key_domain_id,
      domain_key_version_id: fixture.domain_key_version_id,
      storage_ref: Ecto.UUID.generate(),
      wrapper_algorithm: "aes_256_gcm",
      key_generation: 1,
      dek_wrapper: :crypto.strong_rand_bytes(60)
    }

    assert {:ok, %AssetStage{state: :open, state_revision: 0} = stage} =
             scoped(fixture, fn repo ->
               AssetRepository.consume_grant_and_create_stage(repo, stage_command)
             end)

    %{grant: grant, grant_command: grant_command, stage: stage}
  end

  defp sealed_checkpoint(upload) do
    %{
      stage_ref: %StageRef{stage_id: upload.stage.id},
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

  defp checkpoint_effect_counts(repo, asset_id) do
    query!(
      repo,
      """
      SELECT
        (SELECT count(*) FROM content.asset_metadata WHERE asset_id = $1),
        (
          SELECT count(*)
          FROM audit.events
          WHERE target_id = $1
            AND operation = 'asset.uploaded'
        ),
        (
          SELECT count(*)
          FROM core.outbox_events
          WHERE event_type = 'asset.verify_requested'
            AND payload ->> 'asset_id' = $2
        )
      """,
      [Ecto.UUID.dump!(asset_id), asset_id]
    )
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
end
