defmodule Singularity.Storage.AssetStageAbandonmentTest do
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

  test "durably abandons an exact open stage without making its grant reusable", %{
    fixture: fixture
  } do
    upload = open_stage!(fixture)
    command = abandonment_command(upload)

    assert {:ok, %AssetStage{state: :abandoned, state_revision: 1}} =
             scoped(fixture, fn repo ->
               AssetRepository.mark_stage_abandoned(repo, command)
             end)

    scoped(fixture, fn repo ->
      assert %{
               rows: [
                 [
                   "abandoned",
                   1,
                   abandoned_at,
                   failure_code,
                   storage_ref,
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
                   stage.abandoned_at,
                   stage.failure_code,
                   stage.storage_ref,
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

      assert abandoned_at == command.abandoned_at
      assert failure_code == command.failure_code
      assert storage_ref == command.storage_ref
      assert %DateTime{} = consumed_at

      assert %{
               rows: [
                 [
                   "asset.upload_abandoned",
                   "principal",
                   principal_id,
                   vault_id,
                   "private",
                   "asset",
                   target_id,
                   metadata
                 ]
               ]
             } =
               query!(
                 repo,
                 """
                 SELECT
                   operation,
                   actor_kind,
                   principal_id,
                   vault_id,
                   classification,
                   target_type,
                   target_id,
                   metadata
                 FROM audit.events
                 WHERE operation = 'asset.upload_abandoned'
                   AND target_id = $1
                 """,
                 [Ecto.UUID.dump!(upload.grant.asset_id)]
               )

      assert Ecto.UUID.load!(principal_id) == upload.grant.principal_id
      assert Ecto.UUID.load!(vault_id) == upload.grant.vault_id
      assert Ecto.UUID.load!(target_id) == upload.grant.asset_id
      assert metadata["stage_id"] == upload.stage.id
      assert metadata["grant_id"] == upload.grant.id
      assert metadata["failure_code"] == command.failure_code
      refute Map.has_key?(metadata, "token")
      refute Map.has_key?(metadata, "token_digest")
      refute Map.has_key?(metadata, "object_dek")
      refute Map.has_key?(metadata, "dek_wrapper")
      refute Map.has_key?(metadata, "plaintext_sha256")

      assert %{rows: [[0]]} =
               query!(
                 repo,
                 """
                 SELECT count(*)
                 FROM core.outbox_events
                 WHERE causation_id = $1
                    OR payload ->> 'asset_id' = $2
                 """,
                 [
                   Ecto.UUID.dump!(upload.grant.id),
                   upload.grant.asset_id
                 ]
               )

      :ok
    end)

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, fn repo ->
               AssetRepository.consume_grant_and_create_stage(
                 repo,
                 upload.stage_command
               )
             end)
  end

  test "exact retry is idempotent while changed reason or evidence conflicts", %{
    fixture: fixture
  } do
    upload = open_stage!(fixture)
    command = abandonment_command(upload)

    for _attempt <- 1..2 do
      assert {:ok,
              %AssetStage{
                state: :abandoned,
                state_revision: 1,
                failure_code: "controller_disconnected"
              }} =
               scoped(fixture, fn repo ->
                 AssetRepository.mark_stage_abandoned(repo, command)
               end)
    end

    changed_commands = [
      %{command | failure_code: "writer_timeout"},
      %{command | abandoned_at: DateTime.add(command.abandoned_at, 1, :second)},
      %{command | storage_ref: Ecto.UUID.generate()}
    ]

    for changed <- changed_commands do
      assert {:error, %Error{code: :conflict}} =
               scoped(fixture, fn repo ->
                 AssetRepository.mark_stage_abandoned(repo, changed)
               end)
    end

    assert_effect_counts(fixture, upload, %{audits: 1, outbox: 0})
  end

  test "an abandoned attempt retains its evidence while the same idempotency key gets a fresh grant",
       %{fixture: fixture} do
    upload = open_stage!(fixture)

    assert {:ok, %AssetStage{state: :abandoned}} =
             scoped(fixture, fn repo ->
               AssetRepository.mark_stage_abandoned(
                 repo,
                 abandonment_command(upload)
               )
             end)

    replacement_token = :crypto.strong_rand_bytes(32)

    replacement_command =
      upload.grant_command
      |> Map.merge(%{
        grant_id: Ecto.UUID.generate(),
        asset_id: Ecto.UUID.generate(),
        source_reference_id: Ecto.UUID.generate(),
        token_digest: :crypto.hash(:sha256, replacement_token),
        expires_at: DateTime.add(DateTime.utc_now(:microsecond), 300, :second)
      })

    assert {:ok, replacement} =
             scoped(fixture, fn repo ->
               AssetRepository.create_upload_grant(repo, replacement_command)
             end)

    refute replacement.id == upload.grant.id
    assert replacement.asset_id == upload.grant.asset_id
    assert replacement.source_reference_id == upload.grant.source_reference_id
    assert is_nil(replacement.consumed_at)

    scoped(fixture, fn repo ->
      assert %{rows: [[2, 1, 1, 1, 1]]} =
               query!(
                 repo,
                 """
                 SELECT
                   count(*),
                   count(*) FILTER (WHERE upload_grant.consumed_at IS NOT NULL),
                   count(*) FILTER (WHERE upload_grant.consumed_at IS NULL),
                   count(DISTINCT upload_grant.asset_id),
                   count(DISTINCT upload_grant.source_reference_id)
                 FROM content.upload_grants AS upload_grant
                 WHERE upload_grant.vault_id = $1
                   AND upload_grant.idempotency_key = $2
                 """,
                 [
                   Ecto.UUID.dump!(fixture.vault_id),
                   upload.grant.idempotency_key
                 ]
               )

      assert %{rows: [[1, 1]]} =
               query!(
                 repo,
                 """
                 SELECT
                   count(DISTINCT asset.id),
                   count(DISTINCT resource_asset.asset_id)
                 FROM content.assets AS asset
                 JOIN content.resource_assets AS resource_asset
                   ON resource_asset.asset_id = asset.id
                  AND resource_asset.vault_id = asset.vault_id
                 WHERE asset.id = $1
                   AND asset.vault_id = $2
                   AND resource_asset.released_at IS NULL
                 """,
                 [
                   Ecto.UUID.dump!(upload.grant.asset_id),
                   Ecto.UUID.dump!(fixture.vault_id)
                 ]
               )

      :ok
    end)

    replacement_stage_command =
      upload.stage_command
      |> Map.merge(%{
        grant_id: replacement.id,
        token_digest: :crypto.hash(:sha256, replacement_token),
        stage_id: Ecto.UUID.generate(),
        candidate_object_id: Ecto.UUID.generate(),
        storage_ref: Ecto.UUID.generate(),
        principal_authorization_epoch: replacement.principal_authorization_epoch,
        vault_authorization_epoch: replacement.vault_authorization_epoch
      })

    assert {:ok, %AssetStage{state: :open, upload_grant_id: replacement_id}} =
             scoped(fixture, fn repo ->
               AssetRepository.consume_grant_and_create_stage(
                 repo,
                 replacement_stage_command
               )
             end)

    assert replacement_id == replacement.id

    scoped(fixture, fn repo ->
      assert %{rows: [[1, 1]]} =
               query!(
                 repo,
                 """
                 SELECT
                   count(*) FILTER (WHERE state = 'abandoned'),
                   count(*) FILTER (WHERE state = 'open')
                 FROM content.asset_stages
                 WHERE asset_id = $1
                   AND vault_id = $2
                 """,
                 [
                   Ecto.UUID.dump!(upload.grant.asset_id),
                   Ecto.UUID.dump!(fixture.vault_id)
                 ]
               )

      :ok
    end)
  end

  test "a sealed stage cannot be abandoned", %{fixture: fixture} do
    upload = open_stage!(fixture)

    assert {:ok, %{stage: %AssetStage{state: :sealed, state_revision: 1}}} =
             scoped(fixture, fn repo ->
               AssetRepository.record_sealed_stage(repo, sealed_checkpoint(upload))
             end)

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, fn repo ->
               AssetRepository.mark_stage_abandoned(
                 repo,
                 abandonment_command(upload)
               )
             end)

    assert_effect_counts(fixture, upload, %{audits: 0, outbox: 1})
  end

  test "concurrent controller and reconciler abandonment records one transition and audit", %{
    fixture: fixture
  } do
    upload = open_stage!(fixture)
    command = abandonment_command(upload)

    results =
      [:controller, :reconciler]
      |> Task.async_stream(
        fn _caller ->
          scoped(fixture, fn repo ->
            AssetRepository.mark_stage_abandoned(repo, command)
          end)
        end,
        max_concurrency: 2,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert [
             {:ok, %AssetStage{state: :abandoned, state_revision: 1}},
             {:ok, %AssetStage{state: :abandoned, state_revision: 1}}
           ] = results

    assert_effect_counts(fixture, upload, %{audits: 1, outbox: 0})
  end

  defp open_stage!(fixture) do
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
      filename: "abandoned-evidence.pdf",
      byte_size: 12,
      declared_media_type: "application/pdf",
      idempotency_key: "stage-abandonment-#{Ecto.UUID.generate()}",
      classification: :private,
      token_digest: :crypto.hash(:sha256, token),
      expires_at: DateTime.add(observed_at, 300, :second),
      observed_at: observed_at
    }

    assert {:ok, %{id: _, asset_id: _} = grant} =
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

    %{
      grant: grant,
      grant_command: grant_command,
      stage: stage,
      stage_command: stage_command
    }
  end

  defp abandonment_command(upload) do
    %{
      stage_id: upload.stage.id,
      grant_id: upload.grant.id,
      asset_id: upload.grant.asset_id,
      session_id: upload.grant.session_id,
      principal_id: upload.grant.principal_id,
      vault_id: upload.grant.vault_id,
      classification: upload.grant.classification,
      storage_ref: upload.stage.storage_ref,
      expected_stage_revision: 0,
      failure_code: "controller_disconnected",
      abandoned_at: DateTime.utc_now(:microsecond)
    }
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

  defp assert_effect_counts(fixture, upload, expected) do
    scoped(fixture, fn repo ->
      assert %{rows: [[stage_state, stage_revision, audit_count, outbox_count]]} =
               query!(
                 repo,
                 """
                 SELECT
                   stage.state,
                   stage.state_revision,
                   (
                     SELECT count(*)
                     FROM audit.events
                     WHERE operation = 'asset.upload_abandoned'
                       AND target_id = stage.asset_id
                   ),
                   (
                     SELECT count(*)
                     FROM core.outbox_events
                     WHERE causation_id = $2
                        OR payload ->> 'asset_id' = $3
                   )
                 FROM content.asset_stages AS stage
                 WHERE stage.id = $1
                 """,
                 [
                   Ecto.UUID.dump!(upload.stage.id),
                   Ecto.UUID.dump!(upload.grant.id),
                   upload.grant.asset_id
                 ]
               )

      expected_stage = if expected.audits == 1, do: {"abandoned", 1}, else: {"sealed", 1}
      assert {stage_state, stage_revision} == expected_stage
      assert audit_count == expected.audits
      assert outbox_count == expected.outbox
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
