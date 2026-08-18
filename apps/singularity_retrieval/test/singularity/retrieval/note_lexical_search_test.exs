defmodule Singularity.Retrieval.NoteLexicalSearchTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Retrieval.NoteLexicalSearch
  alias Singularity.Retrieval.NoteSearchPage
  alias Singularity.Retrieval.NoteSearchQuery

  @vault_id "00000000-0000-4000-8000-000000000401"
  @other_vault_id "00000000-0000-4000-8000-000000000402"
  @resource_id "00000000-0000-4000-8000-000000000403"
  @resource_version_id "00000000-0000-4000-8000-000000000404"

  defmodule Store do
    @behaviour Singularity.Core.NoteSearchStore

    @impl true
    def search(context, query) do
      send(owner(context), {:search, context, query})
      Process.get(:note_search_result)
    end

    @impl true
    def upsert(_context, _attrs), do: :ok

    @impl true
    def delete(_context, _attrs), do: :ok

    defp owner({:note_search_context, owner}), do: owner
    defp owner(owner), do: owner
  end

  defmodule RaisingStore do
    @behaviour Singularity.Core.NoteSearchStore

    @impl true
    def search(_context, _query), do: raise("unavailable")

    @impl true
    def upsert(_context, _attrs), do: :ok

    @impl true
    def delete(_context, _attrs), do: :ok
  end

  defmodule ThrowingStore do
    @behaviour Singularity.Core.NoteSearchStore

    @impl true
    def search(_context, _query), do: throw(:unavailable)

    @impl true
    def upsert(_context, _attrs), do: :ok

    @impl true
    def delete(_context, _attrs), do: :ok
  end

  setup do
    Process.put(:note_search_result, {:ok, %{items: [item()], next_cursor: :done}})

    on_exit(fn ->
      Process.delete(:note_search_result)
    end)
  end

  test "query defaults and normalizes the server-composed private selector" do
    assert {:ok,
            %NoteSearchQuery{
              vault_id: @vault_id,
              q: "",
              limit: 20,
              cursor: nil,
              classification: :private
            }} = NoteSearchQuery.new(%{vault_id: @vault_id})

    assert {:ok,
            %NoteSearchQuery{
              vault_id: @vault_id,
              q: "road map",
              limit: 50,
              cursor: "next-page",
              classification: :private
            }} =
             NoteSearchQuery.new(%{
               "vault_id" => @vault_id,
               "q" => " road map ",
               "limit" => 50,
               "cursor" => "next-page"
             })
  end

  test "query enforces canonical IDs, limit bounds, and input-only fields" do
    for params <- [
          %{},
          %{vault_id: "00000000-0000-4000-8000-00000000040A"},
          %{vault_id: @vault_id, limit: 0},
          %{vault_id: @vault_id, limit: 51},
          %{vault_id: @vault_id, limit: "20"},
          %{vault_id: @vault_id, classification: :private},
          %{vault_id: @vault_id, state: "deleted"}
        ] do
      assert {:error, %Error{code: :invalid}} = NoteSearchQuery.new(params)
    end

    assert {:ok, %NoteSearchQuery{limit: 1}} =
             NoteSearchQuery.new(vault_id: @vault_id, limit: 1)
  end

  test "query accepts identical atom and string keys but rejects conflicts and unknown keys" do
    assert {:ok, %NoteSearchQuery{q: "annual"}} =
             NoteSearchQuery.new(%{
               "vault_id" => @vault_id,
               "q" => "annual",
               vault_id: @vault_id,
               q: "annual"
             })

    for params <- [
          %{"vault_id" => @other_vault_id, vault_id: @vault_id},
          %{"q" => "different", vault_id: @vault_id, q: "annual"},
          %{vault_id: @vault_id, typo: true},
          %{"vault_id" => @vault_id, "typo" => true},
          %{42 => true, vault_id: @vault_id}
        ] do
      assert {:error, %Error{code: :invalid}} = NoteSearchQuery.new(params)
    end
  end

  test "query validates UTF-8, NULs, and byte bounds" do
    max_query = :binary.copy("q", 1_024)
    max_cursor = :binary.copy("c", 2_048)
    multibyte_query = :binary.copy("é", 512)
    multibyte_cursor = :binary.copy("é", 1_024)

    for params <- [
          %{vault_id: @vault_id, q: max_query, cursor: max_cursor},
          %{vault_id: @vault_id, q: multibyte_query},
          %{vault_id: @vault_id, cursor: multibyte_cursor}
        ] do
      assert {:ok, %NoteSearchQuery{}} = NoteSearchQuery.new(params)
    end

    for params <- [
          %{vault_id: @vault_id, q: :binary.copy("q", 1_025)},
          %{vault_id: @vault_id, cursor: :binary.copy("c", 2_049)},
          %{vault_id: @vault_id, q: :binary.copy("é", 513)},
          %{vault_id: @vault_id, cursor: :binary.copy("é", 1_025)},
          %{vault_id: @vault_id, q: <<0xFF>>},
          %{vault_id: @vault_id, cursor: <<0xFF>>},
          %{vault_id: @vault_id, q: "note\0text"},
          %{vault_id: @vault_id, cursor: "next\0page"}
        ] do
      assert {:error, %Error{code: :invalid}} = NoteSearchQuery.new(params)
    end
  end

  test "query only accepts nil or a nonblank cursor" do
    for cursor <- [nil, "next-page"] do
      assert {:ok, %NoteSearchQuery{cursor: ^cursor}} =
               NoteSearchQuery.new(vault_id: @vault_id, cursor: cursor)
    end

    for cursor <- ["", " \t\n", 42, :done] do
      assert {:error, %Error{code: :invalid}} =
               NoteSearchQuery.new(vault_id: @vault_id, cursor: cursor)
    end
  end

  test "page accepts lists and normalizes the terminal cursor" do
    assert {:ok, %NoteSearchPage{items: [:summary], next_cursor: nil}} =
             NoteSearchPage.new([:summary], :done)

    assert {:ok, %NoteSearchPage{next_cursor: "next-page"}} =
             NoteSearchPage.new([], "next-page")
  end

  test "page rejects malformed or unsafe cursors" do
    for {items, cursor} <- [
          {:not_a_list, :done},
          {[], nil},
          {[], ""},
          {[], " \t"},
          {[], <<0xFF>>},
          {[], "next\0page"},
          {[], :binary.copy("c", 2_049)},
          {[], 42}
        ] do
      assert {:error, %Error{code: :integrity_failure}} = NoteSearchPage.new(items, cursor)
    end
  end

  test "search forwards the exact context and query then returns a normalized page" do
    context = {:note_search_context, self()}

    assert {:ok, query} =
             NoteSearchQuery.new(vault_id: @vault_id, q: " annual ", limit: 1, cursor: "cursor")

    assert {:ok, %NoteSearchPage{items: [result], next_cursor: nil}} =
             NoteLexicalSearch.search(Store, context, query)

    assert result == item()
    assert_receive {:search, ^context, ^query}
  end

  test "search preserves stable core errors" do
    Process.put(:note_search_result, {:error, Error.new(:not_found)})
    assert {:ok, query} = NoteSearchQuery.new(vault_id: @vault_id)

    assert {:error, %Error{code: :not_found}} = NoteLexicalSearch.search(Store, self(), query)
  end

  test "search fails closed as retryable storage unavailability on exceptions, throws, and malformed pages" do
    assert {:ok, query} = NoteSearchQuery.new(vault_id: @vault_id)

    assert_storage_unavailable(NoteLexicalSearch.search(RaisingStore, self(), query))
    assert_storage_unavailable(NoteLexicalSearch.search(ThrowingStore, self(), query))

    for result <- [
          :invalid,
          {:ok, :invalid},
          {:ok, %{items: :not_a_list, next_cursor: :done}},
          {:ok, %{items: [:not_a_map], next_cursor: :done}},
          {:ok, %{items: [item()]}},
          {:ok, %{items: [item()], next_cursor: :done, unexpected: true}},
          {:ok, %{items: [item()], next_cursor: nil}},
          {:ok, %{items: [item()], next_cursor: " "}},
          {:ok, %{items: [item()], next_cursor: <<0xFF>>}},
          {:ok, %{items: [item()], next_cursor: :unexpected}}
        ] do
      Process.put(:note_search_result, result)
      assert_storage_unavailable(NoteLexicalSearch.search(Store, self(), query))
    end
  end

  test "search rejects pages larger than the requested limit" do
    Process.put(:note_search_result, {:ok, %{items: [item(), item()], next_cursor: :done}})
    assert {:ok, query} = NoteSearchQuery.new(vault_id: @vault_id, limit: 1)

    assert_storage_unavailable(NoteLexicalSearch.search(Store, self(), query))
  end

  test "search rejects summary items outside the bound private vault" do
    assert {:ok, query} = NoteSearchQuery.new(vault_id: @vault_id)

    for item <- [
          %{item() | vault_id: @other_vault_id},
          %{item() | classification: :internal}
        ] do
      Process.put(:note_search_result, {:ok, %{items: [item], next_cursor: :done}})
      assert_storage_unavailable(NoteLexicalSearch.search(Store, self(), query))
    end
  end

  test "search rejects malformed summary fields and any additional data" do
    assert {:ok, query} = NoteSearchQuery.new(vault_id: @vault_id)

    invalid_items = [
      %{item() | resource_id: "not-a-uuid"},
      %{item() | resource_version_id: "not-a-uuid"},
      %{item() | vault_id: "not-a-uuid"},
      %{item() | title: " \t"},
      %{item() | title: <<0xFF>>},
      %{item() | title: :binary.copy("t", 256)},
      %{item() | revision: -1},
      %{item() | revision: "1"},
      %{item() | open_conflict_count: -1},
      %{item() | open_conflict_count: "0"},
      %{
        item()
        | updated_at: DateTime.add(item().updated_at, 1, :second) |> Map.put(:time_zone, "UTC")
      },
      %{item() | deleted?: true},
      Map.put(item(), :markdown, "private body"),
      Map.put(item(), :snippet, "private excerpt"),
      Map.put(item(), :unexpected, true)
    ]

    for invalid_item <- invalid_items do
      Process.put(:note_search_result, {:ok, %{items: [invalid_item], next_cursor: :done}})
      assert_storage_unavailable(NoteLexicalSearch.search(Store, self(), query))
    end
  end

  defp assert_storage_unavailable(result) do
    assert {:error, %Error{code: :storage_unavailable, retryable?: true}} = result
  end

  defp item do
    %{
      resource_id: @resource_id,
      resource_version_id: @resource_version_id,
      vault_id: @vault_id,
      classification: :private,
      title: "Annual plan",
      revision: 2,
      updated_at: ~U[2026-08-18 00:00:00.000000Z],
      deleted?: false,
      open_conflict_count: 0
    }
  end
end
