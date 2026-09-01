defmodule Singularity.Storage.AssetSearchProjectionTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.Postgres.AssetRepository
  alias Singularity.Storage.Postgres.AssetSearchStore
  alias Singularity.Storage.RequestRepo
  alias Singularity.Storage.ScopedRepo

  setup do
    %{one: raw_fixture, two: raw_other} = Fixtures.two_vaults!()
    fixture = load_ids(raw_fixture)
    other = load_ids(raw_other)

    set_projection!(raw_fixture, %{
      title: "Annual financial report",
      filename: "annual-2026.pdf",
      media_type: "application/pdf",
      state: "ready",
      updated_at: ~U[2026-07-20 12:00:00.000000Z]
    })

    set_projection!(raw_other, %{
      title: "Annual report from another vault",
      filename: "annual-other.pdf",
      media_type: "application/pdf",
      state: "ready",
      updated_at: ~U[2026-07-21 12:00:00.000000Z]
    })

    {:ok, fixture: fixture, other: other, raw_fixture: raw_fixture, raw_other: raw_other}
  end

  test "generated vector supports websearch syntax and typed filters", %{
    fixture: fixture,
    raw_fixture: raw_fixture
  } do
    roadmap =
      insert_asset!(raw_fixture,
        id: "10000000-0000-4000-8000-000000000101",
        title: "Product roadmap",
        filename: "needlefilename.png",
        state: "available",
        media_type: "image/png",
        updated_at: ~U[2026-07-20 13:00:00.000000Z]
      )

    assert {:ok, {[annual, found_roadmap], :done}} =
             search(fixture, %{
               query: "\"annual financial\" OR roadmap",
               state: nil,
               media_type: nil
             })

    by_asset_id = Map.new([annual, found_roadmap], &{&1.asset_id, &1})
    assert by_asset_id[fixture.asset_id].resource_version_id == fixture.resource_version_id
    assert Map.has_key?(by_asset_id, roadmap.asset_id)

    assert {:ok, {[filename_match], :done}} =
             search(fixture, %{query: "needlefilename.png"})

    assert filename_match.asset_id == roadmap.asset_id

    assert {:ok, {[filtered], :done}} =
             search(fixture, %{
               query: "annual",
               state: :ready,
               media_type: "application/pdf"
             })

    assert filtered.asset_id == fixture.asset_id

    assert {:ok, {[], :done}} =
             search(fixture, %{
               query: "annual",
               state: :processing,
               media_type: "application/pdf"
             })
  end

  test "search is explicitly vault scoped and filters above live clearance", %{
    fixture: fixture,
    other: other,
    raw_fixture: raw_fixture
  } do
    sensitive =
      insert_asset!(raw_fixture,
        id: "10000000-0000-4000-8000-000000000111",
        title: "Sensitive annual plan",
        filename: "sensitive-annual.pdf",
        classification: "sensitive",
        state: "ready",
        media_type: "application/pdf",
        updated_at: ~U[2026-07-21 13:00:00.000000Z]
      )

    assert {:ok, {private_items, :done}} = search(fixture, %{query: "annual"})
    assert Enum.map(private_items, & &1.asset_id) == [fixture.asset_id]

    assert {:ok, {other_items, :done}} = search(other, %{query: "annual"})
    assert Enum.map(other_items, & &1.vault_id) == [other.vault_id]

    set_clearance!(fixture, "restricted")

    assert {:ok, {[visible_sensitive, visible_private], :done}} =
             search(fixture, %{query: "annual"})

    assert visible_sensitive.asset_id == sensitive.asset_id
    assert visible_sensitive.classification == :sensitive
    assert visible_private.asset_id == fixture.asset_id
  end

  test "exact fetch returns current lifecycle fields and hides inaccessible existence", %{
    fixture: fixture,
    other: other,
    raw_fixture: raw_fixture
  } do
    install_source!(raw_fixture)
    install_metadata!(raw_fixture)

    sensitive =
      insert_asset!(raw_fixture,
        id: "10000000-0000-4000-8000-000000000112",
        title: "Sensitive exact result",
        filename: "sensitive-exact.pdf",
        classification: "sensitive",
        state: "ready",
        media_type: "application/pdf",
        updated_at: ~U[2026-07-21 14:00:00.000000Z]
      )

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE content.assets
        SET state = 'processing',
            state_revision = 7,
            failure_code = 'storage_unavailable',
            retryable = true,
            failed_operation = 'asset_metadata',
            attempt = 2
        WHERE id = $1
        """,
        [raw_fixture.asset_id]
      )
    end)

    assert {:ok, fetched} = fetch(fixture, fixture.asset_id)

    assert fetched == %{
             asset_id: fixture.asset_id,
             resource_version_id: fixture.resource_version_id,
             vault_id: fixture.vault_id,
             classification: :private,
             state: :processing,
             state_revision: 7,
             detected_media_type: "application/pdf",
             resource_title: "Annual financial report",
             original_filename: "annual-2026.pdf",
             failure: %{
               code: "storage_unavailable",
               retryable: true,
               operation: "asset_metadata",
               attempt: 2
             },
             updated_at: ~U[2026-07-20 12:00:00.000000Z]
           }

    assert {:error, %Singularity.Core.Error{code: :not_found}} =
             fetch(fixture, sensitive.asset_id)

    assert {:error, %Singularity.Core.Error{code: :not_found}} =
             fetch(fixture, other.asset_id)

    set_clearance!(fixture, "restricted")

    assert {:ok, %{asset_id: sensitive_id, classification: :sensitive}} =
             fetch(fixture, sensitive.asset_id)

    assert sensitive_id == sensitive.asset_id
  end

  test "exact fetch rejects malformed or over-shaped selectors before repository work" do
    for selector <- [
          %{vault_id: "not-a-uuid", asset_id: Ecto.UUID.generate()},
          %{vault_id: Ecto.UUID.generate(), asset_id: "not-a-uuid"},
          %{
            vault_id: Ecto.UUID.generate(),
            asset_id: Ecto.UUID.generate(),
            unexpected: true
          }
        ] do
      assert {:error, %Singularity.Core.Error{code: :invalid}} =
               AssetSearchStore.fetch(:repository_must_not_be_called, selector)
    end
  end

  test "exact fetch survives a missing search document and uses the live asset timestamp", %{
    fixture: fixture,
    raw_fixture: raw_fixture
  } do
    transition_time = ~U[2026-07-22 15:00:00.000000Z]

    install_source!(raw_fixture)
    install_metadata!(raw_fixture)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE content.assets
        SET state = 'processing',
            state_revision = 8,
            updated_at = $2
        WHERE id = $1
        """,
        [raw_fixture.asset_id, transition_time]
      )

      query!(
        MigrationRepo,
        "DELETE FROM content.asset_search_documents WHERE asset_id = $1",
        [raw_fixture.asset_id]
      )
    end)

    assert {:ok,
            %{
              asset_id: asset_id,
              resource_version_id: resource_version_id,
              vault_id: vault_id,
              classification: :private,
              state: :processing,
              state_revision: 8,
              detected_media_type: "application/pdf",
              resource_title: "Annual financial report",
              original_filename: "annual-2026.pdf",
              failure: nil,
              updated_at: ^transition_time
            }} = fetch(fixture, fixture.asset_id)

    assert asset_id == fixture.asset_id
    assert resource_version_id == fixture.resource_version_id
    assert vault_id == fixture.vault_id
  end

  test "exact fetch enforces and returns the strictest contributor classification", %{
    fixture: fixture,
    raw_fixture: raw_fixture
  } do
    insert_grant_bound_source!(raw_fixture,
      classification: "restricted",
      filename: "restricted-source.pdf",
      observed_at: ~U[2026-07-20 11:00:00.000000Z]
    )

    install_metadata!(raw_fixture)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.resources SET classification = 'restricted' WHERE id = $1",
        [raw_fixture.resource_id]
      )

      query!(
        MigrationRepo,
        """
        UPDATE content.resource_versions
        SET classification = 'restricted'
        WHERE id = $1 AND vault_id = $2
        """,
        [raw_fixture.resource_version_id, raw_fixture.vault_id]
      )

      query!(
        MigrationRepo,
        """
        UPDATE content.assets
        SET classification = 'sensitive'
        WHERE id = $1 AND vault_id = $2
        """,
        [raw_fixture.asset_id, raw_fixture.vault_id]
      )

      query!(
        MigrationRepo,
        """
        UPDATE content.asset_metadata
        SET classification = 'restricted'
        WHERE asset_id = $1 AND vault_id = $2
        """,
        [raw_fixture.asset_id, raw_fixture.vault_id]
      )
    end)

    set_clearance!(fixture, "sensitive")

    assert {:error, %Singularity.Core.Error{code: :not_found}} =
             fetch(fixture, fixture.asset_id)

    set_clearance!(fixture, "restricted")

    assert {:ok,
            %{
              asset_id: asset_id,
              classification: :restricted,
              resource_title: "Annual financial report",
              original_filename: "annual-2026.pdf"
            }} = fetch(fixture, fixture.asset_id)

    assert asset_id == fixture.asset_id
  end

  test "exact fetch binds grant sources and rejects ambiguous legacy associations", %{
    fixture: fixture,
    raw_fixture: raw_fixture
  } do
    on_exit(&Fixtures.reset_bootstrap_state!/0)

    second_asset_id = "10000000-0000-4000-8000-000000000181"
    legacy_asset_id = "10000000-0000-4000-8000-000000000182"

    insert_shared_version_asset!(raw_fixture, second_asset_id)
    insert_shared_version_asset!(raw_fixture, legacy_asset_id)

    insert_grant_bound_source!(raw_fixture,
      filename: "first-bound.pdf",
      observed_at: ~U[2026-07-20 12:00:00.000000Z],
      grant_count: 2
    )

    insert_grant_bound_source!(raw_fixture,
      asset_id: Ecto.UUID.dump!(second_asset_id),
      filename: "second-bound.pdf",
      observed_at: ~U[2026-07-19 12:00:00.000000Z]
    )

    assert {:ok, %{asset_id: first_id, original_filename: "first-bound.pdf"}} =
             fetch(fixture, fixture.asset_id)

    assert first_id == fixture.asset_id

    assert {:ok, %{asset_id: ^second_asset_id, original_filename: "second-bound.pdf"}} =
             fetch(fixture, second_asset_id)

    assert {:error, %Singularity.Core.Error{code: :not_found}} =
             fetch(fixture, legacy_asset_id)

    insert_grant_bound_source!(raw_fixture,
      filename: "conflicting-bound.pdf",
      observed_at: ~U[2026-07-18 12:00:00.000000Z]
    )

    assert {:error, %Singularity.Core.Error{code: :not_found}} =
             fetch(fixture, fixture.asset_id)
  end

  test "rank precedes recency and ties use update time then asset id", %{
    fixture: fixture,
    raw_fixture: raw_fixture
  } do
    older_ranked =
      insert_asset!(raw_fixture,
        id: "10000000-0000-4000-8000-000000000121",
        title: "meteor meteor meteor",
        filename: "ranked.pdf",
        state: "ready",
        media_type: "application/pdf",
        updated_at: ~U[2026-07-18 00:00:00.000000Z]
      )

    newer_tie_a =
      insert_asset!(raw_fixture,
        id: "10000000-0000-4000-8000-000000000122",
        title: "meteor",
        filename: "tie.pdf",
        state: "ready",
        media_type: "application/pdf",
        updated_at: ~U[2026-07-21 00:00:00.000000Z]
      )

    newer_tie_b =
      insert_asset!(raw_fixture,
        id: "10000000-0000-4000-8000-000000000123",
        title: "meteor",
        filename: "tie.pdf",
        state: "ready",
        media_type: "application/pdf",
        updated_at: ~U[2026-07-21 00:00:00.000000Z]
      )

    assert {:ok, {items, :done}} = search(fixture, %{query: "meteor"})

    assert Enum.map(items, & &1.asset_id) == [
             older_ranked.asset_id,
             newer_tie_a.asset_id,
             newer_tie_b.asset_id
           ]
  end

  test "empty query orders by update time then asset id", %{
    fixture: fixture,
    raw_fixture: raw_fixture
  } do
    newer_a =
      insert_asset!(raw_fixture,
        id: "10000000-0000-4000-8000-000000000131",
        title: "Newest A",
        filename: "a.png",
        state: "ready",
        media_type: "image/png",
        updated_at: ~U[2026-07-21 00:00:00.000000Z]
      )

    newer_b =
      insert_asset!(raw_fixture,
        id: "10000000-0000-4000-8000-000000000132",
        title: "Newest B",
        filename: "b.png",
        state: "ready",
        media_type: "image/png",
        updated_at: ~U[2026-07-21 00:00:00.000000Z]
      )

    assert {:ok, {items, :done}} = search(fixture, %{query: ""})

    assert Enum.take(Enum.map(items, & &1.asset_id), 2) == [
             newer_a.asset_id,
             newer_b.asset_id
           ]
  end

  test "deleting and canonically rebuilding the projection preserves results", %{
    fixture: fixture,
    raw_fixture: raw_fixture
  } do
    install_source!(raw_fixture)
    install_metadata!(raw_fixture)

    assert :ok =
             scoped(fixture, fn repo ->
               AssetRepository.rebuild_search_document(repo, fixture.asset_id)
             end)

    assert {:ok, {[before], :done}} =
             search(fixture, %{query: "annual", state: :ready})

    assert :ok =
             scoped(fixture, fn repo ->
               AssetSearchStore.delete(repo, %{
                 asset_id: fixture.asset_id,
                 vault_id: fixture.vault_id
               })
             end)

    assert {:ok, {[], :done}} = search(fixture, %{query: "annual", state: :ready})

    assert :ok =
             scoped(fixture, fn repo ->
               AssetRepository.rebuild_search_document(repo, fixture.asset_id)
             end)

    assert {:ok, {[after_rebuild], :done}} =
             search(fixture, %{query: "annual", state: :ready})

    assert after_rebuild == before
    assert after_rebuild.resource_version_id == fixture.resource_version_id
  end

  test "canonical state keeps a logically deleted asset out of stale search results", %{
    fixture: fixture,
    raw_fixture: raw_fixture
  } do
    install_source!(raw_fixture)
    install_metadata!(raw_fixture)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.assets SET state = 'deleted' WHERE id = $1",
        [raw_fixture.asset_id]
      )
    end)

    assert {:ok, {[], :done}} =
             search(fixture, %{query: "annual", state: :ready})

    assert :ok =
             scoped(fixture, fn repo ->
               AssetRepository.rebuild_search_document(repo, fixture.asset_id)
             end)

    assert {:ok, {[], :done}} = search(fixture, %{query: "annual"})
  end

  test "canonical rebuild locks lifecycle state before updating the projection", %{
    fixture: fixture,
    raw_fixture: raw_fixture
  } do
    install_source!(raw_fixture)
    install_metadata!(raw_fixture)
    owner = self()

    transition =
      Task.async(fn ->
        ScopedRepo.transact(
          RequestRepo,
          %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
          fn repo ->
            Ecto.Adapters.SQL.query!(
              repo,
              "SELECT id FROM content.assets WHERE id = $1 FOR UPDATE",
              [Ecto.UUID.dump!(fixture.asset_id)]
            )

            assert %{num_rows: 1} =
                     Ecto.Adapters.SQL.query!(
                       repo,
                       "UPDATE content.assets SET state = 'deleted' WHERE id = $1",
                       [Ecto.UUID.dump!(fixture.asset_id)]
                     )

            send(owner, :asset_transition_locked)

            receive do
              :commit_asset_transition -> :ok
            end
          end
        )
      end)

    assert_receive :asset_transition_locked

    rebuild =
      Task.async(fn ->
        scoped(fixture, fn repo ->
          AssetRepository.rebuild_search_document(repo, fixture.asset_id)
        end)
      end)

    assert Task.yield(rebuild, 100) == nil
    send(transition.pid, :commit_asset_transition)
    assert :ok = Task.await(transition)
    assert :ok = Task.await(rebuild)
    assert {:ok, {[], :done}} = search(fixture, %{query: "annual"})
  end

  test "projection writes cannot downgrade a stricter metadata contributor", %{
    fixture: fixture,
    raw_fixture: raw_fixture
  } do
    install_stricter_classification_chain!(raw_fixture)

    assert {:error, %Singularity.Core.Error{code: :forbidden}} =
             scoped(fixture, fn repo ->
               AssetSearchStore.upsert(repo, %{
                 asset_id: fixture.asset_id,
                 resource_version_id: fixture.resource_version_id,
                 vault_id: fixture.vault_id,
                 classification: :sensitive,
                 state: :ready,
                 detected_media_type: "application/pdf",
                 resource_title: "Annual financial report",
                 original_filename: "annual-2026.pdf"
               })
             end)
  end

  test "canonical rebuild uses the strictest valid chain classification", %{
    fixture: fixture,
    raw_fixture: raw_fixture
  } do
    install_stricter_classification_chain!(raw_fixture)

    assert :ok =
             scoped(fixture, fn repo ->
               AssetRepository.rebuild_search_document(repo, fixture.asset_id)
             end)

    set_clearance!(fixture, "restricted")

    assert {:ok, {[rebuilt], :done}} =
             search(fixture, %{query: "annual", state: :ready})

    assert rebuilt.classification == :restricted
    assert rebuilt.asset_id == fixture.asset_id
  end

  defp search(fixture, filters) do
    filters =
      Map.merge(
        %{
          vault_id: fixture.vault_id,
          query: "",
          state: nil,
          media_type: nil,
          limit: 20,
          cursor: nil
        },
        filters
      )

    scoped(fixture, fn repo -> AssetSearchStore.search(repo, filters) end)
  end

  defp fetch(fixture, asset_id) do
    scoped(fixture, fn repo ->
      AssetSearchStore.fetch(repo, %{
        vault_id: fixture.vault_id,
        asset_id: asset_id
      })
    end)
  end

  defp scoped(fixture, callback) do
    ScopedRepo.transact(
      RequestRepo,
      %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
      callback
    )
  end

  defp set_projection!(raw_fixture, attrs) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.resources SET title = $2, updated_at = $3 WHERE id = $1",
        [raw_fixture.resource_id, attrs.title, attrs.updated_at]
      )

      query!(
        MigrationRepo,
        "UPDATE content.assets SET state = $2, updated_at = $3 WHERE id = $1",
        [raw_fixture.asset_id, attrs.state, attrs.updated_at]
      )

      query!(
        MigrationRepo,
        """
        UPDATE content.asset_search_documents
        SET
          state = $2,
          detected_media_type = $3,
          resource_title = $4,
          original_filename = $5,
          updated_at = $6
        WHERE asset_id = $1
        """,
        [
          raw_fixture.asset_id,
          attrs.state,
          attrs.media_type,
          attrs.title,
          attrs.filename,
          attrs.updated_at
        ]
      )
    end)
  end

  defp insert_asset!(raw_fixture, options) do
    asset_id = Keyword.fetch!(options, :id)
    resource_id = Ecto.UUID.generate()
    resource_version_id = Ecto.UUID.generate()
    classification = Keyword.get(options, :classification, "private")

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO content.resources (
          id, vault_id, classification, title, inserted_at, updated_at
        ) VALUES ($1, $2, $3, $4, $5, $5)
        """,
        [
          Ecto.UUID.dump!(resource_id),
          raw_fixture.vault_id,
          classification,
          Keyword.fetch!(options, :title),
          Keyword.fetch!(options, :updated_at)
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO content.resource_versions (
          id, resource_id, vault_id, classification, revision, inserted_at, updated_at
        ) VALUES ($1, $2, $3, $4, 0, $5, $5)
        """,
        [
          Ecto.UUID.dump!(resource_version_id),
          Ecto.UUID.dump!(resource_id),
          raw_fixture.vault_id,
          classification,
          Keyword.fetch!(options, :updated_at)
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO content.source_references (
          id,
          vault_id,
          resource_version_id,
          principal_id,
          classification,
          kind,
          observed_at,
          original_filename,
          declared_media_type,
          byte_size,
          idempotency_key_digest,
          inserted_at
        ) VALUES ($1, $2, $3, $4, $5, 'browser_upload', $6, $7, $8, 1, $9, $6)
        """,
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          raw_fixture.vault_id,
          Ecto.UUID.dump!(resource_version_id),
          raw_fixture.principal_id,
          classification,
          Keyword.fetch!(options, :updated_at),
          Keyword.fetch!(options, :filename),
          Keyword.fetch!(options, :media_type),
          :crypto.hash(:sha256, asset_id)
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO content.assets (
          id, vault_id, resource_version_id, classification, state, inserted_at, updated_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $6)
        """,
        [
          Ecto.UUID.dump!(asset_id),
          raw_fixture.vault_id,
          Ecto.UUID.dump!(resource_version_id),
          classification,
          Keyword.fetch!(options, :state),
          Keyword.fetch!(options, :updated_at)
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO content.asset_search_documents (
          asset_id,
          resource_version_id,
          vault_id,
          classification,
          state,
          detected_media_type,
          resource_title,
          original_filename,
          updated_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        """,
        [
          Ecto.UUID.dump!(asset_id),
          Ecto.UUID.dump!(resource_version_id),
          raw_fixture.vault_id,
          classification,
          Keyword.fetch!(options, :state),
          Keyword.fetch!(options, :media_type),
          Keyword.fetch!(options, :title),
          Keyword.fetch!(options, :filename),
          Keyword.fetch!(options, :updated_at)
        ]
      )
    end)

    %{asset_id: asset_id, resource_version_id: resource_version_id}
  end

  defp install_metadata!(raw_fixture) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO content.asset_metadata (
          id,
          asset_id,
          resource_version_id,
          vault_id,
          classification,
          projection_version,
          original_filename,
          declared_media_type,
          detected_media_type,
          plaintext_byte_size,
          extraction_state,
          extractor_version,
          completed_at,
          inserted_at,
          updated_at
        ) VALUES (
          $1, $2, $3, $4, 'private', 1, 'annual-2026.pdf',
          'application/pdf', 'application/pdf', 42, 'completed', '1', $5, $5, $5
        )
        ON CONFLICT (asset_id) DO UPDATE SET
          original_filename = EXCLUDED.original_filename,
          detected_media_type = EXCLUDED.detected_media_type,
          extraction_state = EXCLUDED.extraction_state,
          completed_at = EXCLUDED.completed_at,
          updated_at = EXCLUDED.updated_at
        """,
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          raw_fixture.asset_id,
          raw_fixture.resource_version_id,
          raw_fixture.vault_id,
          ~U[2026-07-20 12:00:00.000000Z]
        ]
      )
    end)
  end

  defp install_source!(raw_fixture) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO content.source_references (
          id,
          vault_id,
          resource_version_id,
          principal_id,
          classification,
          kind,
          observed_at,
          original_filename,
          declared_media_type,
          byte_size,
          idempotency_key_digest,
          inserted_at
        ) VALUES (
          $1, $2, $3, $4, 'private', 'browser_upload', $5,
          'annual-2026.pdf', 'application/pdf', 42, $6, $5
        )
        """,
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          raw_fixture.vault_id,
          raw_fixture.resource_version_id,
          raw_fixture.principal_id,
          ~U[2026-07-20 12:00:00.000000Z],
          :crypto.hash(:sha256, raw_fixture.asset_id)
        ]
      )
    end)
  end

  defp insert_shared_version_asset!(raw_fixture, asset_id) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO content.assets (
          id,
          vault_id,
          resource_version_id,
          classification,
          state,
          state_revision,
          inserted_at,
          updated_at
        ) VALUES ($1, $2, $3, 'private', 'processing', 2, $4, $4)
        """,
        [
          Ecto.UUID.dump!(asset_id),
          raw_fixture.vault_id,
          raw_fixture.resource_version_id,
          ~U[2026-07-20 12:00:00.000000Z]
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO content.resource_assets (
          resource_version_id,
          asset_id,
          vault_id,
          classification
        ) VALUES ($1, $2, $3, 'private')
        """,
        [
          raw_fixture.resource_version_id,
          Ecto.UUID.dump!(asset_id),
          raw_fixture.vault_id
        ]
      )
    end)
  end

  defp insert_grant_bound_source!(raw_fixture, options) do
    asset_id = Keyword.get(options, :asset_id, raw_fixture.asset_id)
    classification = Keyword.get(options, :classification, "private")
    filename = Keyword.fetch!(options, :filename)
    grant_count = Keyword.get(options, :grant_count, 1)
    observed_at = Keyword.fetch!(options, :observed_at)
    source_id = Ecto.UUID.generate()
    idempotency_key = "exact-source-#{source_id}"

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO content.source_references (
          id,
          vault_id,
          resource_version_id,
          principal_id,
          classification,
          kind,
          observed_at,
          original_filename,
          declared_media_type,
          byte_size,
          idempotency_key_digest,
          inserted_at
        ) VALUES (
          $1, $2, $3, $4, $5, 'browser_upload', $6,
          $7, 'application/pdf', 42, $8, $6
        )
        """,
        [
          Ecto.UUID.dump!(source_id),
          raw_fixture.vault_id,
          raw_fixture.resource_version_id,
          raw_fixture.principal_id,
          classification,
          observed_at,
          filename,
          :crypto.hash(:sha256, idempotency_key)
        ]
      )

      for index <- 1..grant_count do
        consumed_at = if index < grant_count, do: observed_at, else: nil
        inserted_at = DateTime.add(observed_at, index, :microsecond)
        retired_at = if consumed_at, do: inserted_at, else: nil

        query!(
          MigrationRepo,
          """
          INSERT INTO content.upload_grants (
            id,
            vault_id,
            session_id,
            principal_id,
            asset_id,
            source_reference_id,
            classification,
            token_digest,
            csrf_token_digest,
            filename,
            byte_size,
            declared_media_type,
            idempotency_key,
            principal_authorization_epoch,
            vault_authorization_epoch,
            expires_at,
            consumed_at,
            retired_at,
            inserted_at
          ) VALUES (
            $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, 42,
            'application/pdf', $11, 0, 0, $12, $13, $14, $15
          )
          """,
          [
            Ecto.UUID.dump!(Ecto.UUID.generate()),
            raw_fixture.vault_id,
            raw_fixture.session_id,
            raw_fixture.principal_id,
            asset_id,
            Ecto.UUID.dump!(source_id),
            classification,
            :crypto.hash(:sha256, "#{source_id}:token:#{index}"),
            :crypto.hash(:sha256, "#{source_id}:csrf:#{index}"),
            filename,
            idempotency_key,
            DateTime.add(DateTime.utc_now(:microsecond), 3_600, :second),
            consumed_at,
            retired_at,
            inserted_at
          ]
        )
      end
    end)

    source_id
  end

  defp install_stricter_classification_chain!(raw_fixture) do
    install_source!(raw_fixture)
    install_metadata!(raw_fixture)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE content.resource_versions
        SET classification = 'sensitive'
        WHERE id = $1 AND vault_id = $2
        """,
        [raw_fixture.resource_version_id, raw_fixture.vault_id]
      )

      query!(
        MigrationRepo,
        """
        UPDATE content.resources
        SET classification = 'sensitive'
        WHERE id = $1 AND vault_id = $2
        """,
        [raw_fixture.resource_id, raw_fixture.vault_id]
      )

      query!(
        MigrationRepo,
        """
        UPDATE content.assets
        SET classification = 'sensitive'
        WHERE id = $1 AND vault_id = $2
        """,
        [raw_fixture.asset_id, raw_fixture.vault_id]
      )

      query!(
        MigrationRepo,
        """
        UPDATE content.asset_metadata
        SET classification = 'restricted'
        WHERE asset_id = $1 AND vault_id = $2
        """,
        [raw_fixture.asset_id, raw_fixture.vault_id]
      )
    end)
  end

  defp set_clearance!(fixture, clearance) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE core.vault_members
        SET clearance = $3
        WHERE principal_id = $1 AND vault_id = $2
        """,
        [
          Ecto.UUID.dump!(fixture.principal_id),
          Ecto.UUID.dump!(fixture.vault_id),
          clearance
        ]
      )
    end)
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
