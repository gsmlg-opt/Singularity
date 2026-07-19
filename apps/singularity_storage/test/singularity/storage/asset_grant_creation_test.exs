defmodule Singularity.Storage.AssetGrantCreationTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.Postgres.AssetRepository
  alias Singularity.Storage.Schema.Content.UploadGrant
  alias Singularity.Storage.ScopedRepo

  setup do
    %{one: fixture} = Fixtures.two_vaults!()
    {:ok, fixture: load_ids(fixture)}
  end

  test "atomically creates the exact grant and provenance with live epochs", %{
    fixture: fixture
  } do
    command = grant_command(fixture)

    assert {:ok, grant} =
             scoped(fixture, fn repo ->
               AssetRepository.create_upload_grant(repo, command)
             end)

    assert grant.id == command.grant_id
    assert grant.asset_id == command.asset_id
    assert grant.token_digest == command.token_digest

    scoped(fixture, fn repo ->
      assert %UploadGrant{} = stored = repo.get!(UploadGrant, command.grant_id)
      assert stored.session_id == command.session_id
      assert stored.principal_id == command.principal_id
      assert stored.vault_id == command.vault_id
      assert stored.asset_id == command.asset_id
      assert stored.source_reference_id == command.source_reference_id
      assert stored.filename == command.filename
      assert stored.byte_size == command.byte_size
      assert stored.declared_media_type == command.declared_media_type
      assert stored.idempotency_key == command.idempotency_key
      assert stored.classification == command.classification
      assert stored.token_digest == command.token_digest
      assert stored.expires_at == command.expires_at
      assert stored.consumed_at == nil

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

      assert stored.principal_authorization_epoch == principal_epoch
      assert stored.vault_authorization_epoch == vault_epoch

      filename = command.filename
      declared_media_type = command.declared_media_type
      byte_size = command.byte_size

      assert %{
               rows: [
                 [
                   "staging",
                   0,
                   "browser_upload",
                   ^filename,
                   ^declared_media_type,
                   ^byte_size,
                   idempotency_digest,
                   1,
                   0
                 ]
               ]
             } =
               query!(
                 repo,
                 """
                 SELECT
                   asset.state,
                   asset.state_revision,
                   source.kind,
                   source.original_filename,
                   source.declared_media_type,
                   source.byte_size,
                   source.idempotency_key_digest,
                   (
                     SELECT count(*)
                     FROM content.resource_assets
                     WHERE asset_id = asset.id
                       AND resource_version_id = asset.resource_version_id
                   ),
                   (
                     SELECT count(*)
                     FROM core.outbox_events
                     WHERE causation_id IN (asset.id, source.id)
                   )
                 FROM content.assets AS asset
                 JOIN content.source_references AS source
                   ON source.id = $2
                 WHERE asset.id = $1
                 """,
                 [
                   Ecto.UUID.dump!(command.asset_id),
                   Ecto.UUID.dump!(command.source_reference_id)
                 ]
               )

      assert idempotency_digest ==
               :crypto.hash(:sha256, command.idempotency_key)

      :ok
    end)
  end

  test "changed metadata under the same idempotency key conflicts without partial rows", %{
    fixture: fixture
  } do
    first = grant_command(fixture)

    assert {:ok, _grant} =
             scoped(fixture, fn repo ->
               AssetRepository.create_upload_grant(repo, first)
             end)

    changed =
      fixture
      |> grant_command()
      |> Map.put(:idempotency_key, first.idempotency_key)
      |> Map.put(:filename, "changed.pdf")

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, fn repo ->
               AssetRepository.create_upload_grant(repo, changed)
             end)

    scoped(fixture, fn repo ->
      assert %{rows: [[1, 0, 0, 0]]} =
               query!(
                 repo,
                 """
                 SELECT
                   (
                     SELECT count(*)
                     FROM content.upload_grants
                     WHERE vault_id = $1 AND idempotency_key = $2
                   ),
                   (SELECT count(*) FROM content.assets WHERE id = $3),
                   (SELECT count(*) FROM content.source_references WHERE id = $4),
                   (SELECT count(*) FROM content.resource_assets WHERE asset_id = $3)
                 """,
                 [
                   Ecto.UUID.dump!(fixture.vault_id),
                   first.idempotency_key,
                   Ecto.UUID.dump!(changed.asset_id),
                   Ecto.UUID.dump!(changed.source_reference_id)
                 ]
               )

      :ok
    end)
  end

  test "an exact retry conflicts while its unconsumed grant remains active", %{
    fixture: fixture
  } do
    first = grant_command(fixture)

    assert {:ok, original} =
             scoped(fixture, fn repo ->
               AssetRepository.create_upload_grant(repo, first)
             end)

    retry =
      fixture
      |> grant_command()
      |> Map.put(:idempotency_key, first.idempotency_key)

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, fn repo ->
               AssetRepository.create_upload_grant(repo, retry)
             end)

    scoped(fixture, fn repo ->
      assert %UploadGrant{token_digest: token_digest} =
               repo.get!(UploadGrant, original.id)

      assert token_digest == first.token_digest

      assert %{rows: [[1, 1, 1, 1]]} =
               query!(
                 repo,
                 """
                 SELECT
                   (
                     SELECT count(*)
                     FROM content.upload_grants
                     WHERE vault_id = $1 AND idempotency_key = $2
                   ),
                   (SELECT count(*) FROM content.assets WHERE id = $3),
                   (
                     SELECT count(*)
                     FROM content.source_references
                     WHERE id = $4
                   ),
                   (
                     SELECT count(*)
                     FROM content.resource_assets
                     WHERE asset_id = $3
                   )
                 """,
                 [
                   Ecto.UUID.dump!(fixture.vault_id),
                   first.idempotency_key,
                   Ecto.UUID.dump!(original.asset_id),
                   Ecto.UUID.dump!(first.source_reference_id)
                 ]
               )

      :ok
    end)
  end

  test "concurrent first creation leaves one complete logical grant", %{
    fixture: fixture
  } do
    first = grant_command(fixture)

    second =
      fixture
      |> grant_command()
      |> Map.put(:idempotency_key, first.idempotency_key)

    results =
      [first, second]
      |> Task.async_stream(
        fn command ->
          result =
            scoped(fixture, fn repo ->
              AssetRepository.create_upload_grant(repo, command)
            end)

          {command.token_digest, result}
        end,
        max_concurrency: 2,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{successful_digest, {:ok, successful}}] =
             Enum.filter(results, &match?({_digest, {:ok, _grant}}, &1))

    assert [_conflict] =
             Enum.filter(
               results,
               &match?({_digest, {:error, %Error{code: :conflict}}}, &1)
             )

    assert %{
             id: grant_id,
             asset_id: asset_id,
             source_reference_id: _source_reference_id
           } = successful

    assert successful.token_digest == successful_digest

    scoped(fixture, fn repo ->
      assert %UploadGrant{token_digest: persisted_digest} =
               repo.get!(UploadGrant, grant_id)

      assert persisted_digest == successful_digest

      assert %{rows: [[1, 1, 1, 1]]} =
               query!(
                 repo,
                 """
                 SELECT
                   (
                     SELECT count(*)
                     FROM content.upload_grants
                     WHERE vault_id = $1 AND idempotency_key = $2
                   ),
                   (
                     SELECT count(*)
                     FROM content.assets
                     WHERE id IN ($3, $4)
                   ),
                   (
                     SELECT count(*)
                     FROM content.source_references
                     WHERE id IN ($5, $6)
                   ),
                   (
                     SELECT count(*)
                     FROM content.resource_assets
                     WHERE asset_id = $7
                   )
                 """,
                 [
                   Ecto.UUID.dump!(fixture.vault_id),
                   first.idempotency_key,
                   Ecto.UUID.dump!(first.asset_id),
                   Ecto.UUID.dump!(second.asset_id),
                   Ecto.UUID.dump!(first.source_reference_id),
                   Ecto.UUID.dump!(second.source_reference_id),
                   Ecto.UUID.dump!(asset_id)
                 ]
               )

      :ok
    end)
  end

  defp grant_command(fixture) do
    now = DateTime.utc_now(:microsecond)

    %{
      grant_id: Ecto.UUID.generate(),
      asset_id: Ecto.UUID.generate(),
      source_reference_id: Ecto.UUID.generate(),
      session_id: fixture.session_id,
      principal_id: fixture.principal_id,
      vault_id: fixture.vault_id,
      resource_version_id: fixture.resource_version_id,
      filename: "evidence.pdf",
      byte_size: 12,
      declared_media_type: "application/pdf",
      idempotency_key: "grant-create-#{Ecto.UUID.generate()}",
      classification: :private,
      token_digest: :crypto.hash(:sha256, :crypto.strong_rand_bytes(32)),
      expires_at: DateTime.add(now, 300, :second),
      observed_at: now
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
        {key, Ecto.UUID.load!(value)}

      pair ->
        pair
    end)
  end
end
