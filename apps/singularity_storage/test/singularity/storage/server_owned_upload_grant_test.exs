defmodule Singularity.Storage.ServerOwnedUploadGrantTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.Postgres.AssetRepository
  alias Singularity.Storage.Postgres.AssetSearchStore
  alias Singularity.Storage.Schema.Content.UploadGrant
  alias Singularity.Storage.ScopedRepo

  setup do
    %{one: raw_fixture} = Fixtures.two_vaults!()

    fixture =
      raw_fixture
      |> load_ids()
      |> Map.merge(insert_key_domain!(raw_fixture.vault_id))

    {:ok, fixture: fixture}
  end

  test "one transaction creates the private logical aggregate, staging projection, and grant",
       %{fixture: fixture} do
    command = server_owned_command(fixture)

    assert {:ok, grant} =
             scoped(fixture, fn repo ->
               AssetRepository.create_upload_grant(repo, command)
             end)

    assert grant.id == command.grant_id
    assert grant.asset_id == command.asset_id
    assert grant.resource_version_id == command.resource_version_id
    assert grant.classification == :private

    scoped(fixture, fn repo ->
      assert %{
               rows: [
                 [
                   title,
                   "private",
                   0,
                   "private",
                   "staging",
                   0,
                   "browser_upload",
                   filename,
                   "private",
                   "staging",
                   1
                 ]
               ]
             } =
               query!(
                 repo,
                 """
                 SELECT
                   resource.title,
                   resource.classification,
                   resource_version.revision,
                   resource_version.classification,
                   asset.state,
                   asset.state_revision,
                   source.kind,
                   source.original_filename,
                   document.classification,
                   document.state,
                   count(resource_asset.asset_id) OVER ()
                 FROM content.resources AS resource
                 JOIN content.resource_versions AS resource_version
                   ON resource_version.resource_id = resource.id
                  AND resource_version.vault_id = resource.vault_id
                 JOIN content.assets AS asset
                   ON asset.resource_version_id = resource_version.id
                  AND asset.vault_id = resource_version.vault_id
                 JOIN content.source_references AS source
                   ON source.id = $4
                  AND source.resource_version_id = resource_version.id
                 JOIN content.resource_assets AS resource_asset
                   ON resource_asset.asset_id = asset.id
                  AND resource_asset.resource_version_id = resource_version.id
                 JOIN content.asset_search_documents AS document
                   ON document.asset_id = asset.id
                  AND document.vault_id = asset.vault_id
                 WHERE resource.id = $1
                   AND resource_version.id = $2
                   AND asset.id = $3
                 """,
                 [
                   Ecto.UUID.dump!(command.resource_id),
                   Ecto.UUID.dump!(command.resource_version_id),
                   Ecto.UUID.dump!(command.asset_id),
                   Ecto.UUID.dump!(command.source_reference_id)
                 ]
               )

      assert title == command.filename
      assert filename == command.filename
      :ok
    end)

    assert {:ok, {[visible], :done}} =
             search(fixture, %{
               query: command.filename,
               state: :staging
             })

    assert visible.asset_id == command.asset_id
    assert visible.resource_version_id == command.resource_version_id
    assert visible.resource_title == command.filename
    assert visible.original_filename == command.filename
    assert visible.classification == :private
  end

  test "aggregate failure rolls back every generated authority row", %{fixture: fixture} do
    command =
      fixture
      |> server_owned_command()
      |> Map.put(:resource_id, fixture.resource_id)

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, fn repo ->
               AssetRepository.create_upload_grant(repo, command)
             end)

    scoped(fixture, fn repo ->
      assert %{rows: [[0, 0, 0, 0, 0, 0]]} =
               query!(
                 repo,
                 """
                 SELECT
                   (SELECT count(*) FROM content.resource_versions WHERE id = $1),
                   (SELECT count(*) FROM content.assets WHERE id = $2),
                   (SELECT count(*) FROM content.source_references WHERE id = $3),
                   (SELECT count(*) FROM content.resource_assets WHERE asset_id = $2),
                   (SELECT count(*) FROM content.asset_search_documents WHERE asset_id = $2),
                   (SELECT count(*) FROM content.upload_grants WHERE id = $4)
                 """,
                 [
                   Ecto.UUID.dump!(command.resource_version_id),
                   Ecto.UUID.dump!(command.asset_id),
                   Ecto.UUID.dump!(command.source_reference_id),
                   Ecto.UUID.dump!(command.grant_id)
                 ]
               )

      :ok
    end)
  end

  test "concurrent same-key creation persists one logical aggregate and no generated orphans",
       %{fixture: fixture} do
    first = server_owned_command(fixture)

    second =
      fixture
      |> server_owned_command()
      |> Map.merge(%{
        idempotency_key: first.idempotency_key,
        filename: first.filename,
        byte_size: first.byte_size,
        declared_media_type: first.declared_media_type
      })

    results =
      [first, second]
      |> Task.async_stream(
        fn command ->
          scoped(fixture, fn repo ->
            AssetRepository.create_upload_grant(repo, command)
          end)
        end,
        max_concurrency: 2,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert [_success] = Enum.filter(results, &match?({:ok, _}, &1))

    assert [_conflict] =
             Enum.filter(
               results,
               &match?({:error, %Error{code: :conflict}}, &1)
             )

    scoped(fixture, fn repo ->
      assert %{rows: [[1, 1, 1, 1, 1, 1]]} =
               query!(
                 repo,
                 """
                 SELECT
                   count(DISTINCT upload_grant.asset_id),
                   count(DISTINCT upload_grant.source_reference_id),
                   count(DISTINCT asset.resource_version_id),
                   count(DISTINCT resource_version.resource_id),
                   count(DISTINCT document.asset_id),
                   count(*)
                 FROM content.upload_grants AS upload_grant
                 JOIN content.assets AS asset
                   ON asset.id = upload_grant.asset_id
                  AND asset.vault_id = upload_grant.vault_id
                 JOIN content.resource_versions AS resource_version
                   ON resource_version.id = asset.resource_version_id
                  AND resource_version.vault_id = asset.vault_id
                 JOIN content.asset_search_documents AS document
                   ON document.asset_id = asset.id
                  AND document.vault_id = asset.vault_id
                 WHERE upload_grant.vault_id = $1
                   AND upload_grant.idempotency_key = $2
                 """,
                 [
                   Ecto.UUID.dump!(fixture.vault_id),
                   first.idempotency_key
                 ]
               )

      assert_generated_loser_absent!(repo, first, second)
      :ok
    end)
  end

  test "a renewed session cannot displace an active unconsumed grant", %{
    fixture: fixture
  } do
    first = server_owned_command(fixture)

    assert {:ok, original} =
             scoped(fixture, fn repo ->
               AssetRepository.create_upload_grant(repo, first)
             end)

    retry =
      fixture
      |> server_owned_command()
      |> Map.merge(%{
        idempotency_key: first.idempotency_key,
        session_id: insert_session!(fixture),
        filename: first.filename,
        byte_size: first.byte_size,
        declared_media_type: first.declared_media_type
      })

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, fn repo ->
               AssetRepository.create_upload_grant(repo, retry)
             end)

    scoped(fixture, fn repo ->
      assert %UploadGrant{retired_at: nil, consumed_at: nil} =
               repo.get!(UploadGrant, original.id)

      assert_generated_command_absent!(repo, retry)
      :ok
    end)
  end

  test "cancelling an exact unconsumed grant retires it and tombstones the staging asset",
       %{fixture: fixture} do
    command = server_owned_command(fixture)

    assert {:ok, grant} =
             scoped(fixture, fn repo ->
               AssetRepository.create_upload_grant(repo, command)
             end)

    assert {:ok, %{status: :cancelled, asset_id: asset_id}} =
             scoped(fixture, fn repo ->
               AssetRepository.cancel_upload_grant(repo, %{
                 grant_id: grant.id,
                 session_id: grant.session_id,
                 principal_id: grant.principal_id,
                 vault_id: grant.vault_id
               })
             end)

    assert asset_id == grant.asset_id

    assert {:ok, %{status: :cancelled, asset_id: ^asset_id}} =
             scoped(fixture, fn repo ->
               AssetRepository.cancel_upload_grant(repo, %{
                 grant_id: grant.id,
                 session_id: grant.session_id,
                 principal_id: grant.principal_id,
                 vault_id: grant.vault_id
               })
             end)

    scoped(fixture, fn repo ->
      assert %{
               rows: [
                 [
                   cancelled_at,
                   retired_at,
                   nil,
                   "pending_delete",
                   1,
                   released_at,
                   0,
                   1,
                   1
                 ]
               ]
             } =
               query!(
                 repo,
                 """
                 SELECT
                   upload_grant.cancelled_at,
                   upload_grant.retired_at,
                   upload_grant.consumed_at,
                   asset.state,
                   asset.state_revision,
                   resource_asset.released_at,
                   (SELECT count(*) FROM content.asset_search_documents WHERE asset_id = asset.id),
                   (SELECT count(*) FROM content.tombstones WHERE asset_id = asset.id),
                   (SELECT count(*) FROM core.outbox_events
                    WHERE event_type = 'asset.cleanup_requested'
                      AND payload ->> 'asset_id' = asset.id::text)
                 FROM content.upload_grants AS upload_grant
                 JOIN content.assets AS asset
                   ON asset.id = upload_grant.asset_id
                  AND asset.vault_id = upload_grant.vault_id
                 JOIN content.resource_assets AS resource_asset
                   ON resource_asset.asset_id = asset.id
                  AND resource_asset.vault_id = asset.vault_id
                 WHERE upload_grant.id = $1
                 """,
                 [Ecto.UUID.dump!(grant.id)]
               )

      assert %DateTime{} = cancelled_at
      assert cancelled_at == retired_at
      assert %DateTime{} = released_at
      :ok
    end)

    replacement =
      fixture
      |> server_owned_command()
      |> Map.merge(%{
        idempotency_key: command.idempotency_key,
        filename: command.filename,
        byte_size: command.byte_size,
        declared_media_type: command.declared_media_type
      })

    assert {:ok, retry_grant} =
             scoped(fixture, fn repo ->
               AssetRepository.create_upload_grant(repo, replacement)
             end)

    refute retry_grant.id == grant.id
    refute retry_grant.asset_id == grant.asset_id
    assert is_nil(retry_grant.retired_at)
  end

  test "mismatched cancellation authority is indistinguishable and changes nothing", %{
    fixture: fixture
  } do
    command = server_owned_command(fixture)

    assert {:ok, grant} =
             scoped(fixture, fn repo ->
               AssetRepository.create_upload_grant(repo, command)
             end)

    exact = %{
      grant_id: grant.id,
      session_id: grant.session_id,
      principal_id: grant.principal_id,
      vault_id: grant.vault_id
    }

    for changed <- [
          %{session_id: Ecto.UUID.generate()},
          %{principal_id: Ecto.UUID.generate()},
          %{vault_id: Ecto.UUID.generate()}
        ] do
      assert {:error, %Error{code: :not_found}} =
               scoped(fixture, fn repo ->
                 AssetRepository.cancel_upload_grant(repo, Map.merge(exact, changed))
               end)
    end

    scoped(fixture, fn repo ->
      assert %UploadGrant{
               consumed_at: nil,
               retired_at: nil,
               cancelled_at: nil
             } = repo.get!(UploadGrant, grant.id)

      assert %{rows: [["staging", 0, nil, 1, 0, 0]]} =
               query!(
                 repo,
                 """
                 SELECT
                   asset.state,
                   asset.state_revision,
                   resource_asset.released_at,
                   (SELECT count(*) FROM content.asset_search_documents WHERE asset_id = asset.id),
                   (SELECT count(*) FROM content.tombstones WHERE asset_id = asset.id),
                   (SELECT count(*) FROM core.outbox_events
                    WHERE event_type = 'asset.cleanup_requested'
                      AND payload ->> 'asset_id' = asset.id::text)
                 FROM content.assets AS asset
                 JOIN content.resource_assets AS resource_asset
                   ON resource_asset.asset_id = asset.id
                  AND resource_asset.vault_id = asset.vault_id
                 WHERE asset.id = $1
                 """,
                 [Ecto.UUID.dump!(grant.asset_id)]
               )

      :ok
    end)
  end

  test "a tombstone conflict rolls back early grant retirement", %{fixture: fixture} do
    command = server_owned_command(fixture)

    assert {:ok, grant} =
             scoped(fixture, fn repo ->
               AssetRepository.create_upload_grant(repo, command)
             end)

    Fixtures.with_owner(fn ->
      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 """
                 UPDATE content.assets
                 SET state_revision = 1
                 WHERE id = $1
                 """,
                 [Ecto.UUID.dump!(grant.asset_id)]
               )
    end)

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, fn repo ->
               AssetRepository.cancel_upload_grant(repo, %{
                 grant_id: grant.id,
                 session_id: grant.session_id,
                 principal_id: grant.principal_id,
                 vault_id: grant.vault_id
               })
             end)

    scoped(fixture, fn repo ->
      assert %UploadGrant{
               consumed_at: nil,
               retired_at: nil,
               cancelled_at: nil
             } = repo.get!(UploadGrant, grant.id)

      assert %{rows: [["staging", 1, nil, 1, 0, 0]]} =
               query!(
                 repo,
                 """
                 SELECT
                   asset.state,
                   asset.state_revision,
                   resource_asset.released_at,
                   (SELECT count(*) FROM content.asset_search_documents WHERE asset_id = asset.id),
                   (SELECT count(*) FROM content.tombstones WHERE asset_id = asset.id),
                   (SELECT count(*) FROM core.outbox_events
                    WHERE event_type = 'asset.cleanup_requested'
                      AND payload ->> 'asset_id' = asset.id::text)
                 FROM content.assets AS asset
                 JOIN content.resource_assets AS resource_asset
                   ON resource_asset.asset_id = asset.id
                  AND resource_asset.vault_id = asset.vault_id
                 WHERE asset.id = $1
                 """,
                 [Ecto.UUID.dump!(grant.asset_id)]
               )

      :ok
    end)
  end

  test "cancelling a superseded expired grant is a stable no-op for its active replacement", %{
    fixture: fixture
  } do
    original_command = server_owned_command(fixture)

    assert {:ok, original} =
             scoped(fixture, fn repo ->
               AssetRepository.create_upload_grant(repo, original_command)
             end)

    expire_grant!(original.id)

    replacement_command =
      fixture
      |> server_owned_command()
      |> Map.merge(%{
        idempotency_key: original_command.idempotency_key,
        filename: original_command.filename,
        byte_size: original_command.byte_size,
        declared_media_type: original_command.declared_media_type
      })

    assert {:ok, replacement} =
             scoped(fixture, fn repo ->
               AssetRepository.create_upload_grant(repo, replacement_command)
             end)

    assert replacement.asset_id == original.asset_id

    assert {:ok,
            %{
              status: :retired,
              grant_id: grant_id,
              asset_id: asset_id,
              vault_id: vault_id
            }} =
             scoped(fixture, fn repo ->
               AssetRepository.cancel_upload_grant(repo, %{
                 grant_id: original.id,
                 session_id: original.session_id,
                 principal_id: original.principal_id,
                 vault_id: original.vault_id
               })
             end)

    assert grant_id == original.id
    assert asset_id == original.asset_id
    assert vault_id == original.vault_id

    scoped(fixture, fn repo ->
      assert %UploadGrant{retired_at: %DateTime{}, cancelled_at: nil} =
               repo.get!(UploadGrant, original.id)

      assert %UploadGrant{retired_at: nil, cancelled_at: nil, consumed_at: nil} =
               repo.get!(UploadGrant, replacement.id)

      assert %{rows: [["staging", 0, nil, 1, 0, 0]]} =
               query!(
                 repo,
                 """
                 SELECT
                   asset.state,
                   asset.state_revision,
                   resource_asset.released_at,
                   (SELECT count(*) FROM content.asset_search_documents WHERE asset_id = asset.id),
                   (SELECT count(*) FROM content.tombstones WHERE asset_id = asset.id),
                   (SELECT count(*) FROM core.outbox_events
                    WHERE event_type = 'asset.cleanup_requested'
                      AND payload ->> 'asset_id' = asset.id::text)
                 FROM content.assets AS asset
                 JOIN content.resource_assets AS resource_asset
                   ON resource_asset.asset_id = asset.id
                  AND resource_asset.vault_id = asset.vault_id
                 WHERE asset.id = $1
                 """,
                 [Ecto.UUID.dump!(original.asset_id)]
               )

      :ok
    end)
  end

  test "cancelling a consumed grant leaves its open upload and aggregate untouched", %{
    fixture: fixture
  } do
    command = server_owned_command(fixture)

    assert {:ok, grant} =
             scoped(fixture, fn repo ->
               AssetRepository.create_upload_grant(repo, command)
             end)

    stage = consume!(fixture, grant, command)

    assert {:ok, %{status: :in_progress, asset_id: asset_id}} =
             scoped(fixture, fn repo ->
               AssetRepository.cancel_upload_grant(repo, %{
                 grant_id: grant.id,
                 session_id: grant.session_id,
                 principal_id: grant.principal_id,
                 vault_id: grant.vault_id
               })
             end)

    assert asset_id == grant.asset_id

    scoped(fixture, fn repo ->
      assert %UploadGrant{
               consumed_at: %DateTime{},
               retired_at: nil,
               cancelled_at: nil
             } = repo.get!(UploadGrant, grant.id)

      assert %{rows: [["staging", 0, nil, "open"]]} =
               query!(
                 repo,
                 """
                 SELECT asset.state, asset.state_revision, resource_asset.released_at, stage.state
                 FROM content.assets AS asset
                 JOIN content.resource_assets AS resource_asset
                   ON resource_asset.asset_id = asset.id
                  AND resource_asset.vault_id = asset.vault_id
                 JOIN content.asset_stages AS stage
                   ON stage.asset_id = asset.id
                  AND stage.vault_id = asset.vault_id
                 WHERE asset.id = $1 AND stage.id = $2
                 """,
                 [Ecto.UUID.dump!(grant.asset_id), Ecto.UUID.dump!(stage.id)]
               )

      :ok
    end)
  end

  test "an expired exact retry retires the old token and reuses the aggregate from a renewed session",
       %{fixture: fixture} do
    on_exit(&Fixtures.reset_bootstrap_state!/0)

    first = server_owned_command(fixture)

    assert {:ok, original} =
             scoped(fixture, fn repo ->
               AssetRepository.create_upload_grant(repo, first)
             end)

    expire_grant!(original.id)
    renewed_session_id = insert_session!(fixture)

    replacement =
      fixture
      |> server_owned_command()
      |> Map.merge(%{
        idempotency_key: first.idempotency_key,
        session_id: renewed_session_id,
        filename: first.filename,
        byte_size: first.byte_size,
        declared_media_type: first.declared_media_type
      })

    assert {:ok, retried} =
             scoped(fixture, fn repo ->
               AssetRepository.create_upload_grant(repo, replacement)
             end)

    refute retried.id == original.id
    assert retried.asset_id == original.asset_id
    assert retried.source_reference_id == original.source_reference_id
    assert retried.resource_version_id == original.resource_version_id
    assert retried.session_id == renewed_session_id
    assert is_nil(retried.consumed_at)

    scoped(fixture, fn repo ->
      assert %UploadGrant{consumed_at: nil, retired_at: %DateTime{}} =
               repo.get!(UploadGrant, original.id)

      assert %UploadGrant{
               consumed_at: nil,
               retired_at: nil,
               session_id: ^renewed_session_id
             } = repo.get!(UploadGrant, retried.id)

      assert %{rows: [[2, 1, 1, 1, 1, 1]]} =
               query!(
                 repo,
                 """
                 SELECT
                   count(*),
                   count(*) FILTER (WHERE retired_at IS NOT NULL),
                   count(DISTINCT asset_id),
                   count(DISTINCT source_reference_id),
                   count(DISTINCT asset.resource_version_id),
                   count(DISTINCT resource_version.resource_id)
                 FROM content.upload_grants AS upload_grant
                 JOIN content.assets AS asset
                   ON asset.id = upload_grant.asset_id
                  AND asset.vault_id = upload_grant.vault_id
                 JOIN content.resource_versions AS resource_version
                   ON resource_version.id = asset.resource_version_id
                  AND resource_version.vault_id = asset.vault_id
                 WHERE upload_grant.vault_id = $1
                   AND upload_grant.idempotency_key = $2
                 GROUP BY upload_grant.vault_id
                 """,
                 [
                   Ecto.UUID.dump!(fixture.vault_id),
                   first.idempotency_key
                 ]
               )

      assert_generated_authority_absent!(repo, replacement)
      :ok
    end)

    old_selector = grant_selector(original, first)

    assert {:error, %Error{code: :upload_expired}} =
             scoped(fixture, fn repo ->
               AssetRepository.load_upload_grant_descriptor(repo, old_selector)
             end)
  end

  test "a consumed abandoned server-owned attempt is retired and replaced without replay ID orphans",
       %{fixture: fixture} do
    on_exit(&Fixtures.reset_bootstrap_state!/0)

    first = server_owned_command(fixture)

    assert {:ok, original} =
             scoped(fixture, fn repo ->
               AssetRepository.create_upload_grant(repo, first)
             end)

    stage = consume_and_abandon!(fixture, original, first)
    renewed_session_id = insert_session!(fixture)

    replacement =
      fixture
      |> server_owned_command()
      |> Map.merge(%{
        idempotency_key: first.idempotency_key,
        session_id: renewed_session_id,
        filename: first.filename,
        byte_size: first.byte_size,
        declared_media_type: first.declared_media_type
      })

    assert {:ok, retried} =
             scoped(fixture, fn repo ->
               AssetRepository.create_upload_grant(repo, replacement)
             end)

    assert retried.asset_id == original.asset_id
    assert retried.source_reference_id == original.source_reference_id
    assert retried.resource_version_id == original.resource_version_id
    assert retried.session_id == renewed_session_id
    refute retried.token_digest == original.token_digest
    refute retried.csrf_token_digest == original.csrf_token_digest

    scoped(fixture, fn repo ->
      assert %UploadGrant{consumed_at: %DateTime{}, retired_at: %DateTime{}} =
               repo.get!(UploadGrant, original.id)

      assert %UploadGrant{consumed_at: nil, retired_at: nil} =
               repo.get!(UploadGrant, retried.id)

      assert_generated_authority_absent!(repo, replacement)
      :ok
    end)

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, fn repo ->
               AssetRepository.load_upload_grant_descriptor(
                 repo,
                 grant_selector(original, first)
               )
             end)

    assert stage.state == :abandoned
  end

  test "changed browser or principal binding conflicts without generated aggregate rows",
       %{fixture: fixture} do
    first = server_owned_command(fixture)

    assert {:ok, _original} =
             scoped(fixture, fn repo ->
               AssetRepository.create_upload_grant(repo, first)
             end)

    for changed <-
          [
            %{filename: "changed.pdf"},
            %{byte_size: first.byte_size + 1},
            %{declared_media_type: "image/png"},
            %{principal_id: Ecto.UUID.generate()}
          ] do
      retry =
        fixture
        |> server_owned_command()
        |> Map.put(:idempotency_key, first.idempotency_key)
        |> Map.merge(changed)

      assert {:error, %Error{code: :conflict}} =
               scoped(fixture, fn repo ->
                 AssetRepository.create_upload_grant(repo, retry)
               end)

      scoped(fixture, fn repo ->
        assert_generated_command_absent!(repo, retry)
        :ok
      end)
    end
  end

  test "search uses live pending state and canonical asset updated_at while retaining the projection",
       %{fixture: fixture} do
    command = server_owned_command(fixture)

    assert {:ok, _grant} =
             scoped(fixture, fn repo ->
               AssetRepository.create_upload_grant(repo, command)
             end)

    uploaded_at = DateTime.add(command.observed_at, 30, :second)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE content.assets
        SET
          state = 'uploaded',
          state_revision = 1,
          failure_code = 'storage_unavailable',
          retryable = true,
          failed_operation = 'verify',
          attempt = 1,
          updated_at = $2
        WHERE id = $1
        """,
        [Ecto.UUID.dump!(command.asset_id), uploaded_at]
      )
    end)

    assert :ok =
             scoped(fixture, fn repo ->
               AssetRepository.rebuild_search_document(repo, command.asset_id)
             end)

    assert {:ok, {[visible], :done}} =
             search(fixture, %{state: :uploaded})

    assert visible.asset_id == command.asset_id
    assert visible.state == :uploaded
    assert visible.state_revision == 1
    assert visible.updated_at == uploaded_at

    assert visible.failure == %{
             code: "storage_unavailable",
             retryable: true,
             operation: "verify",
             attempt: 1
           }

    pending_delete_at = DateTime.add(uploaded_at, 30, :second)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE content.assets
        SET
          state = 'pending_delete',
          state_revision = 2,
          updated_at = $2
        WHERE id = $1
        """,
        [Ecto.UUID.dump!(command.asset_id), pending_delete_at]
      )
    end)

    assert :ok =
             scoped(fixture, fn repo ->
               AssetRepository.rebuild_search_document(repo, command.asset_id)
             end)

    assert {:ok, {[], :done}} =
             search(fixture, %{state: :pending_delete})

    assert {:ok, %{state: :pending_delete, updated_at: ^pending_delete_at}} =
             scoped(fixture, fn repo ->
               AssetSearchStore.fetch(repo, %{
                 vault_id: fixture.vault_id,
                 asset_id: command.asset_id
               })
             end)
  end

  test "migration exposes truthful retirement and the active-key predicate", %{fixture: fixture} do
    scoped(fixture, fn repo ->
      assert %{rows: [["cancelled_at", "YES"], ["retired_at", "YES"]]} =
               query!(
                 repo,
                 """
                 SELECT column_name, is_nullable
                 FROM information_schema.columns
                 WHERE table_schema = 'content'
                   AND table_name = 'upload_grants'
                   AND column_name IN ('cancelled_at', 'retired_at')
                 ORDER BY column_name
                 """
               )

      assert %{rows: [[constraint_definition]]} =
               query!(
                 repo,
                 """
                 SELECT pg_get_constraintdef(oid)
                 FROM pg_constraint
                 WHERE conrelid = 'content.upload_grants'::regclass
                   AND conname = 'upload_grants_retirement_check'
                 """
               )

      assert %{rows: [[definition]]} =
               query!(
                 repo,
                 """
                 SELECT indexdef
                 FROM pg_indexes
                 WHERE schemaname = 'content'
                   AND tablename = 'upload_grants'
                   AND indexname = 'upload_grants_active_idempotency_key'
                 """
               )

      assert definition =~ "retired_at IS NULL"
      refute definition =~ "consumed_at IS NULL"
      assert constraint_definition =~ "cancelled_at IS NULL"
      assert constraint_definition =~ "consumed_at IS NULL"
      assert constraint_definition =~ "retired_at = cancelled_at"
      assert constraint_definition =~ "cancelled_at = retired_at"
      assert constraint_definition =~ "expires_at <= retired_at"
      :ok
    end)
  end

  defp server_owned_command(fixture) do
    now = DateTime.utc_now(:microsecond)

    %{
      grant_id: Ecto.UUID.generate(),
      asset_id: Ecto.UUID.generate(),
      source_reference_id: Ecto.UUID.generate(),
      resource_id: Ecto.UUID.generate(),
      resource_version_id: Ecto.UUID.generate(),
      server_owned_resource?: true,
      session_id: fixture.session_id,
      principal_id: fixture.principal_id,
      vault_id: fixture.vault_id,
      filename: "server-owned-#{Ecto.UUID.generate()}.pdf",
      byte_size: 12,
      declared_media_type: "application/pdf",
      idempotency_key: "server-owned-#{Ecto.UUID.generate()}",
      classification: :private,
      token_digest: :crypto.hash(:sha256, :crypto.strong_rand_bytes(32)),
      csrf_token_digest: :crypto.hash(:sha256, :crypto.strong_rand_bytes(32)),
      expires_at: DateTime.add(now, 300, :second),
      observed_at: now
    }
  end

  defp grant_selector(grant, command) do
    %{
      grant_id: grant.id,
      token_digest: command.token_digest,
      csrf_token_digest: command.csrf_token_digest,
      session_id: grant.session_id,
      principal_id: grant.principal_id,
      vault_id: grant.vault_id,
      request_content_length: command.byte_size,
      request_declared_media_type: command.declared_media_type
    }
  end

  defp search(fixture, overrides) do
    filters =
      Map.merge(
        %{
          vault_id: fixture.vault_id,
          query: "",
          state: nil,
          media_type: nil,
          limit: 50,
          cursor: nil
        },
        overrides
      )

    scoped(fixture, fn repo -> AssetSearchStore.search(repo, filters) end)
  end

  defp expire_grant!(grant_id) do
    Fixtures.with_owner(fn ->
      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 """
                 UPDATE content.upload_grants
                 SET expires_at = statement_timestamp() - interval '1 second'
                 WHERE id = $1
                 """,
                 [Ecto.UUID.dump!(grant_id)]
               )
    end)
  end

  defp consume_and_abandon!(fixture, grant, command) do
    stage = consume!(fixture, grant, command)

    assert {:ok, abandoned} =
             scoped(fixture, fn repo ->
               AssetRepository.mark_stage_abandoned(repo, %{
                 stage_id: stage.id,
                 grant_id: grant.id,
                 asset_id: grant.asset_id,
                 session_id: grant.session_id,
                 principal_id: grant.principal_id,
                 vault_id: grant.vault_id,
                 classification: grant.classification,
                 storage_ref: stage.storage_ref,
                 expected_stage_revision: 0,
                 failure_code: "controller_disconnected",
                 abandoned_at: DateTime.utc_now(:microsecond)
               })
             end)

    abandoned
  end

  defp consume!(fixture, grant, command) do
    stage_command = %{
      grant_id: grant.id,
      token_digest: command.token_digest,
      csrf_token_digest: command.csrf_token_digest,
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

    assert {:ok, stage} =
             scoped(fixture, fn repo ->
               AssetRepository.consume_grant_and_create_stage(repo, stage_command)
             end)

    stage
  end

  defp insert_session!(fixture) do
    session_id = Ecto.UUID.generate()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO identity.sessions (
          id,
          account_id,
          credential_id,
          principal_id,
          vault_id,
          token_digest,
          expires_at
        ) VALUES ($1, $2, $3, $4, $5, $6, statement_timestamp() + interval '1 hour')
        """,
        [
          Ecto.UUID.dump!(session_id),
          Ecto.UUID.dump!(fixture.account_id),
          Ecto.UUID.dump!(fixture.credential_id),
          Ecto.UUID.dump!(fixture.principal_id),
          Ecto.UUID.dump!(fixture.vault_id),
          :crypto.hash(:sha256, "renewed-session-#{session_id}")
        ]
      )
    end)

    session_id
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

  defp assert_generated_loser_absent!(repo, first, second) do
    counts = fn command ->
      query!(
        repo,
        """
        SELECT
          (SELECT count(*) FROM content.resources WHERE id = $1),
          (SELECT count(*) FROM content.resource_versions WHERE id = $2),
          (SELECT count(*) FROM content.assets WHERE id = $3),
          (SELECT count(*) FROM content.source_references WHERE id = $4)
        """,
        [
          Ecto.UUID.dump!(command.resource_id),
          Ecto.UUID.dump!(command.resource_version_id),
          Ecto.UUID.dump!(command.asset_id),
          Ecto.UUID.dump!(command.source_reference_id)
        ]
      ).rows
    end

    assert Enum.sort([counts.(first), counts.(second)]) ==
             Enum.sort([[[0, 0, 0, 0]], [[1, 1, 1, 1]]])
  end

  defp assert_generated_command_absent!(repo, command) do
    assert %{rows: [[0, 0, 0, 0, 0]]} =
             query!(
               repo,
               """
               SELECT
                 (SELECT count(*) FROM content.resources WHERE id = $1),
                 (SELECT count(*) FROM content.resource_versions WHERE id = $2),
                 (SELECT count(*) FROM content.assets WHERE id = $3),
                 (SELECT count(*) FROM content.source_references WHERE id = $4),
                 (SELECT count(*) FROM content.upload_grants WHERE id = $5)
               """,
               [
                 Ecto.UUID.dump!(command.resource_id),
                 Ecto.UUID.dump!(command.resource_version_id),
                 Ecto.UUID.dump!(command.asset_id),
                 Ecto.UUID.dump!(command.source_reference_id),
                 Ecto.UUID.dump!(command.grant_id)
               ]
             )
  end

  defp assert_generated_authority_absent!(repo, command) do
    assert %{rows: [[0, 0, 0, 0]]} =
             query!(
               repo,
               """
               SELECT
                 (SELECT count(*) FROM content.resources WHERE id = $1),
                 (SELECT count(*) FROM content.resource_versions WHERE id = $2),
                 (SELECT count(*) FROM content.assets WHERE id = $3),
                 (SELECT count(*) FROM content.source_references WHERE id = $4)
               """,
               [
                 Ecto.UUID.dump!(command.resource_id),
                 Ecto.UUID.dump!(command.resource_version_id),
                 Ecto.UUID.dump!(command.asset_id),
                 Ecto.UUID.dump!(command.source_reference_id)
               ]
             )
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
