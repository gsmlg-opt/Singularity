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

  test "canonical rebuild keeps a logically deleted asset out of search", %{
    fixture: fixture,
    raw_fixture: raw_fixture
  } do
    install_metadata!(raw_fixture)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.assets SET state = 'deleted' WHERE id = $1",
        [raw_fixture.asset_id]
      )
    end)

    assert {:ok, {[stale], :done}} =
             search(fixture, %{query: "annual", state: :ready})

    assert stale.asset_id == fixture.asset_id

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

  defp install_stricter_classification_chain!(raw_fixture) do
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
