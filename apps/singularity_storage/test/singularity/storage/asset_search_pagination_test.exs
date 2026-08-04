defmodule Singularity.Storage.AssetSearchPaginationTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.Postgres.AssetSearchStore
  alias Singularity.Storage.RequestRepo
  alias Singularity.Storage.ScopedRepo

  defmodule RejectingRepo do
    def all(_query), do: raise("invalid search reached repository work")
  end

  setup do
    %{one: raw_fixture} = Fixtures.two_vaults!()
    fixture = load_ids(raw_fixture)
    ids = install_tied_documents!(raw_fixture, 55)

    {:ok, fixture: fixture, ids: ids}
  end

  test "50-item keyset pages do not skip or duplicate tied results", %{
    fixture: fixture,
    ids: expected_ids
  } do
    filters = filters(fixture)

    assert {:ok, {first_page, cursor}} = search(fixture, filters)
    assert length(first_page) == 50
    assert is_binary(cursor)
    assert byte_size(cursor) <= 2_048

    assert {:ok, {second_page, :done}} =
             search(fixture, %{filters | cursor: cursor})

    assert length(second_page) == 5

    items = first_page ++ second_page
    ids = Enum.map(items, & &1.asset_id)

    assert ids == expected_ids
    assert length(Enum.uniq(ids)) == 55
    assert Enum.all?(items, &is_binary(&1.resource_version_id))
  end

  test "empty-query keyset pages do not skip or duplicate tied timestamps", %{
    fixture: fixture,
    ids: expected_ids
  } do
    filters = %{filters(fixture) | query: ""}

    assert {:ok, {first_page, cursor}} = search(fixture, filters)
    assert length(first_page) == 50
    assert is_binary(cursor)

    assert {:ok, {second_page, :done}} =
             search(fixture, %{filters | cursor: cursor})

    assert Enum.map(first_page ++ second_page, & &1.asset_id) == expected_ids
  end

  test "default pages exclude deleted rows while explicit deleted filters retain them", %{
    fixture: fixture,
    ids: expected_ids
  } do
    deleted_ids = Enum.take(expected_ids, 5)
    mark_deleted!(deleted_ids)

    default_filters = %{filters(fixture) | state: nil}

    assert {:ok, {default_page, :done}} = search(fixture, default_filters)
    assert length(default_page) == 50
    assert Enum.map(default_page, & &1.asset_id) == expected_ids -- deleted_ids
    assert Enum.all?(default_page, &(&1.state == :ready))

    assert {:ok, {deleted_page, :done}} =
             search(fixture, %{default_filters | state: :deleted})

    assert Enum.map(deleted_page, & &1.asset_id) == deleted_ids
    assert Enum.all?(deleted_page, &(&1.state == :deleted))
  end

  test "cursor is bound to vault and normalized filters", %{fixture: fixture} do
    filters = filters(fixture)
    assert {:ok, {_items, cursor}} = search(fixture, filters)

    mismatches = [
      %{filters | query: "different"},
      %{filters | state: :processing},
      %{filters | media_type: "image/png"},
      %{filters | vault_id: Ecto.UUID.generate()}
    ]

    for mismatch <- mismatches do
      assert {:error, %Error{code: :invalid}} =
               search(fixture, %{mismatch | cursor: cursor})
    end
  end

  test "tampered or malformed cursors and limits above 50 are rejected", %{
    fixture: fixture
  } do
    filters = filters(fixture)
    assert {:ok, {_items, cursor}} = search(fixture, filters)

    <<first, rest::binary>> = cursor
    replacement = if first == ?A, do: ?B, else: ?A
    tampered = <<replacement, rest::binary>>

    for invalid_cursor <- [tampered, "not-base64url", " "] do
      assert {:error, %Error{code: :invalid}} =
               search(fixture, %{filters | cursor: invalid_cursor})
    end

    assert {:error, %Error{code: :invalid}} =
             search(fixture, %{filters | limit: 51})
  end

  test "a client cannot forge a cursor by recomputing the former public checksum", %{
    fixture: fixture
  } do
    filters = filters(fixture)
    assert {:ok, {_items, cursor}} = search(fixture, filters)

    data =
      cursor
      |> Base.url_decode64!(padding: false)
      |> JSON.decode!()
      |> Map.put("r", 99.0)
      |> Map.put("t", "2030-01-01T00:00:00.000000Z")
      |> Map.put("a", Ecto.UUID.generate())
      |> Map.delete("h")

    forged_cursor =
      data
      |> Map.put("h", former_public_checksum(data))
      |> JSON.encode!()
      |> Base.url_encode64(padding: false)

    assert {:error, %Error{code: :invalid}} =
             search(fixture, %{filters | cursor: forged_cursor})
  end

  test "search fails closed when the configured cursor secret is too short", %{
    fixture: fixture
  } do
    previous =
      Application.fetch_env!(:singularity_runtime, :audit_fingerprint_secret)

    try do
      Application.put_env(
        :singularity_runtime,
        :audit_fingerprint_secret,
        "short"
      )

      assert {:error, %Error{code: :invalid}} =
               search(fixture, filters(fixture))
    after
      Application.put_env(
        :singularity_runtime,
        :audit_fingerprint_secret,
        previous
      )
    end
  end

  test "direct store calls reject unbounded or malformed input before repo work", %{
    fixture: fixture
  } do
    base = filters(fixture)

    invalid_filters = [
      %{base | query: :binary.copy("q", 1_025)},
      %{base | query: <<0xFF>>},
      %{base | query: "pagination\0tie"},
      %{base | cursor: :binary.copy("c", 2_049)},
      %{base | cursor: <<0xFF>>},
      Map.put(base, :media_typo, "image/png"),
      Map.put(base, "query", "pagination tie")
    ]

    for filters <- invalid_filters do
      assert {:error, %Error{code: :invalid}} =
               AssetSearchStore.search(RejectingRepo, filters)
    end
  end

  defp filters(fixture) do
    %{
      vault_id: fixture.vault_id,
      query: "pagination tie",
      state: :ready,
      media_type: "application/pdf",
      limit: 50,
      cursor: nil
    }
  end

  defp search(fixture, filters) do
    ScopedRepo.transact(
      RequestRepo,
      %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
      fn repo -> AssetSearchStore.search(repo, filters) end
    )
  end

  defp install_tied_documents!(raw_fixture, count) do
    timestamp = ~U[2026-07-21 00:00:00.000000Z]

    ids =
      1..count
      |> Enum.map(fn _index -> Ecto.UUID.generate() end)
      |> Enum.sort()

    Fixtures.with_owner(fn ->
      for asset_id <- ids do
        query!(
          MigrationRepo,
          """
          INSERT INTO content.assets (
            id,
            vault_id,
            resource_version_id,
            classification,
            state,
            inserted_at,
            updated_at
          ) VALUES ($1, $2, $3, 'private', 'ready', $4, $4)
          """,
          [
            Ecto.UUID.dump!(asset_id),
            raw_fixture.vault_id,
            raw_fixture.resource_version_id,
            timestamp
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
          ) VALUES (
            $1, $2, $3, 'private', 'ready', 'application/pdf',
            'pagination tie', 'pagination-tie.pdf', $4
          )
          """,
          [
            Ecto.UUID.dump!(asset_id),
            raw_fixture.resource_version_id,
            raw_fixture.vault_id,
            timestamp
          ]
        )
      end
    end)

    ids
  end

  defp mark_deleted!(asset_ids) do
    updated_at = ~U[2026-07-22 00:00:00.000000Z]

    Fixtures.with_owner(fn ->
      for asset_id <- asset_ids do
        query!(
          MigrationRepo,
          """
          UPDATE content.assets
          SET state = 'deleted',
              state_revision = state_revision + 1,
              updated_at = $2
          WHERE id = $1
          """,
          [Ecto.UUID.dump!(asset_id), updated_at]
        )
      end
    end)
  end

  defp former_public_checksum(data) do
    [
      Integer.to_string(data["v"]),
      data["f"],
      :erlang.float_to_binary(data["r"] * 1.0, [:compact]),
      data["t"],
      data["a"]
    ]
    |> Enum.intersperse(<<0>>)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
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
