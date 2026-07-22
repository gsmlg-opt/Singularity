defmodule Singularity.Retrieval.AssetMetadataSearchTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Retrieval.AssetMetadataSearch
  alias Singularity.Retrieval.AssetSearchPage
  alias Singularity.Retrieval.AssetSearchQuery

  @vault_id "00000000-0000-4000-8000-000000000301"
  @asset_id "00000000-0000-4000-8000-000000000302"
  @resource_version_id "00000000-0000-4000-8000-000000000303"

  defmodule Store do
    @behaviour Singularity.Core.AssetSearchStore

    @impl true
    def search(owner, filters) do
      send(owner, {:search, filters})
      Process.get(:asset_search_result)
    end

    @impl true
    def upsert(_context, _attrs), do: :ok

    @impl true
    def delete(_context, _attrs), do: :ok
  end

  setup do
    Process.put(:asset_search_result, {:ok, {[item()], :done}})

    on_exit(fn -> Process.delete(:asset_search_result) end)
  end

  test "query normalizes the fixed public fields" do
    params = %{
      vault_id: @vault_id,
      q: "  annual report  ",
      state: :ready,
      media_type: "application/pdf",
      limit: 50,
      cursor: nil
    }

    assert {:ok,
            %AssetSearchQuery{
              vault_id: @vault_id,
              q: "annual report",
              state: :ready,
              media_type: "application/pdf",
              limit: 50,
              cursor: nil
            }} = AssetSearchQuery.new(params)

    assert {:ok,
            %AssetSearchQuery{
              vault_id: @vault_id,
              q: "",
              state: nil,
              media_type: nil,
              limit: 20,
              cursor: nil
            }} = AssetSearchQuery.new(vault_id: @vault_id)
  end

  test "query accepts transport string keys without creating atoms" do
    assert {:ok,
            %AssetSearchQuery{
              vault_id: @vault_id,
              q: "road map",
              state: :processing,
              media_type: "image/png",
              limit: 7,
              cursor: "opaque-cursor"
            }} =
             AssetSearchQuery.new(%{
               "vault_id" => @vault_id,
               "q" => " road map ",
               "state" => "processing",
               "media_type" => "image/png",
               "limit" => 7,
               "cursor" => "opaque-cursor"
             })
  end

  test "query rejects invalid lifecycle, media, limit, cursor, and shape with one stable error" do
    invalid_params = [
      %{},
      %{vault_id: " "},
      %{vault_id: @vault_id, q: :all},
      %{vault_id: @vault_id, state: :unknown},
      %{vault_id: @vault_id, media_type: "text/plain"},
      %{vault_id: @vault_id, limit: 0},
      %{vault_id: @vault_id, limit: 51},
      %{vault_id: @vault_id, cursor: " "},
      [@vault_id],
      :invalid
    ]

    for params <- invalid_params do
      assert {:error, %Error{code: :invalid}} = AssetSearchQuery.new(params)
    end
  end

  test "query bounds UTF-8 text and opaque cursors before adapter work" do
    max_query = :binary.copy("q", 1_024)
    max_cursor = :binary.copy("c", 2_048)

    assert {:ok, %AssetSearchQuery{q: ^max_query, cursor: ^max_cursor}} =
             AssetSearchQuery.new(%{
               vault_id: @vault_id,
               q: max_query,
               cursor: max_cursor
             })

    invalid_params = [
      %{vault_id: @vault_id, q: :binary.copy("q", 1_025)},
      %{vault_id: @vault_id, q: <<0xFF>>},
      %{vault_id: @vault_id, q: "annual\0report"},
      %{vault_id: @vault_id, cursor: :binary.copy("c", 2_049)},
      %{vault_id: @vault_id, cursor: <<0xFF>>}
    ]

    for params <- invalid_params do
      assert {:error, %Error{code: :invalid}} = AssetSearchQuery.new(params)
    end
  end

  test "query rejects unknown keys while preserving duplicate-key semantics" do
    for params <- [
          %{vault_id: @vault_id, media_typo: "image/png"},
          %{"vault_id" => @vault_id, "media_typo" => "image/png"},
          %{42 => "unknown", vault_id: @vault_id}
        ] do
      assert {:error, %Error{code: :invalid}} = AssetSearchQuery.new(params)
    end

    assert {:ok, %AssetSearchQuery{q: "annual"}} =
             AssetSearchQuery.new(%{
               :vault_id => @vault_id,
               "vault_id" => @vault_id,
               :q => "annual",
               "q" => "annual"
             })

    assert {:error, %Error{code: :invalid}} =
             AssetSearchQuery.new(%{
               :vault_id => @vault_id,
               "vault_id" => @vault_id,
               :q => "annual",
               "q" => "different"
             })
  end

  test "search calls the injected core port and normalizes the terminal cursor" do
    assert {:ok, query} =
             AssetSearchQuery.new(%{
               vault_id: @vault_id,
               q: "annual report",
               state: :ready,
               media_type: "application/pdf",
               limit: 50
             })

    assert {:ok, %AssetSearchPage{items: [result], next_cursor: nil}} =
             AssetMetadataSearch.search(Store, self(), query)

    assert result == item()

    assert_receive {:search,
                    %{
                      vault_id: @vault_id,
                      query: "annual report",
                      state: :ready,
                      media_type: "application/pdf",
                      limit: 50,
                      cursor: nil
                    }}
  end

  test "search exposes a valid opaque continuation cursor" do
    Process.put(:asset_search_result, {:ok, {[item()], "next-page"}})
    assert {:ok, query} = AssetSearchQuery.new(vault_id: @vault_id)

    assert {:ok, %AssetSearchPage{next_cursor: "next-page"}} =
             AssetMetadataSearch.search(Store, self(), query)
  end

  test "search fails closed on oversized, cross-vault, or malformed adapter output" do
    assert {:ok, query} = AssetSearchQuery.new(vault_id: @vault_id, limit: 1)

    invalid_results = [
      {:ok, {[item(), item()], :done}},
      {:ok, {[%{item() | vault_id: "other-vault"}], :done}},
      {:ok, {[%{item() | asset_id: " "}], :done}},
      {:ok, {[%{item() | resource_version_id: nil}], :done}},
      {:ok, {[:not_a_map], :done}},
      {:ok, {[item()], " "}},
      {:ok, :invalid_shape},
      :invalid_shape
    ]

    for result <- invalid_results do
      Process.put(:asset_search_result, result)

      assert {:error, %Error{code: :integrity_failure}} =
               AssetMetadataSearch.search(Store, self(), query)
    end
  end

  test "search preserves stable adapter errors" do
    Process.put(:asset_search_result, {:error, Error.new(:storage_unavailable)})
    assert {:ok, query} = AssetSearchQuery.new(vault_id: @vault_id)

    assert {:error, %Error{code: :storage_unavailable}} =
             AssetMetadataSearch.search(Store, self(), query)
  end

  defp item do
    %{
      asset_id: @asset_id,
      resource_version_id: @resource_version_id,
      vault_id: @vault_id,
      classification: :private,
      state: :ready,
      detected_media_type: "application/pdf",
      resource_title: "Annual report",
      original_filename: "annual.pdf",
      updated_at: ~U[2026-07-21 00:00:00.000000Z]
    }
  end
end
