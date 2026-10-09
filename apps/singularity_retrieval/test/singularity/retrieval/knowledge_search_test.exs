defmodule Singularity.Retrieval.KnowledgeSearchTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Singularity.Core.{Error, SourceLocator}
  alias Singularity.Retrieval.{KnowledgeSearch, KnowledgeSearchPage, KnowledgeSearchResult}
  alias Singularity.Retrieval.KnowledgeSearchQuery

  @owner "00000000-0000-4000-8000-000000000a03"
  @tag_a "00000000-0000-4000-8000-000000000a04"
  @tag_b "00000000-0000-4000-8000-000000000a05"
  @resource "00000000-0000-4000-8000-000000000a01"
  @version "00000000-0000-4000-8000-000000000a02"
  @document_resource "00000000-0000-4000-8000-000000000a06"
  @document_version "00000000-0000-4000-8000-000000000a07"
  @fragment String.duplicate("ab01", 16)
  @time ~U[2026-10-09 12:00:00.123456Z]

  defmodule Store do
    @behaviour Singularity.Core.KnowledgeSearchStore

    @impl true
    def search(%{test_pid: pid, result: result}, query) do
      send(pid, {:store_query, query})
      if is_function(result, 0), do: result.(), else: result
    end

    @impl true
    def resolve(_context, _source), do: {:error, Error.new(:not_found)}
  end

  test "query defaults derive private owner scope from a separate trusted argument" do
    assert Code.ensure_loaded?(Singularity.Retrieval.KnowledgeSearchQuery)

    assert {:ok, query} =
             apply(Singularity.Retrieval.KnowledgeSearchQuery, :new, [@owner, %{}])

    assert Map.from_struct(query) == %{
             owner_scope_id: @owner,
             classification: :private,
             q: "",
             kind: :all,
             tag_ids: [],
             limit: 20,
             cursor: nil,
             policy_version: 1
           }
  end

  test "queries normalize only allowed kind aliases, surrounding whitespace and tag order" do
    for {input_kind, kind} <-
          [all: :all, note: :note, document: :document] ++
            [{"all", :all}, {"note", :note}, {"document", :document}] do
      params = %{
        "q" => "  知识  ",
        "kind" => input_kind,
        "tag_ids" => [@tag_b, @tag_a, @tag_b],
        "limit" => 50,
        "cursor" => "opaque"
      }

      assert {:ok, query} = new(params)
      assert query.q == "知识"
      assert query.kind == kind
      assert query.tag_ids == [@tag_a, @tag_b]
      assert query.limit == 50
      assert query.cursor == "opaque"
      assert query.owner_scope_id == @owner
      assert {:ok, ^query} = validate(query)
    end

    assert {:ok, query} = new(q: " e\u0301 OR -token %_\\ ")
    assert query.q == "e\u0301 OR -token %_\\"
  end

  test "query bounds apply to raw UTF-8 bytes before trimming" do
    for q <- ["", "  \t\n", String.duplicate("a", 1_024), String.duplicate("é", 512)] do
      assert {:ok, query} = new(q: q)
      assert query.q == String.trim(q)
    end

    for q <- [
          nil,
          1,
          :q,
          [],
          <<255>>,
          "query\0",
          String.duplicate(" ", 1_025),
          String.duplicate("é", 513)
        ] do
      assert_invalid(q: q)
    end
  end

  test "public parameters never accept caller scope, classification, policy or raw SQL" do
    for key <- [
          :owner_scope_id,
          :vault_id,
          :classification,
          :policy_version,
          :rank,
          :statement_timeout_ms,
          :sql,
          :unknown
        ],
        alias_key <- [key, Atom.to_string(key)] do
      assert_invalid(%{alias_key => "private-query-canary"})
    end
  end

  test "strict alias and keyword duplicate checks happen before normalization" do
    params = %{q: "text", kind: :note, tag_ids: [@tag_a], limit: 20, cursor: nil}
    assert {:ok, expected} = new(params)

    for {key, value} <- params do
      assert new(Map.put(params, Atom.to_string(key), value)) == {:ok, expected}
      assert new([{key, value} | Map.to_list(params)]) == {:ok, expected}
      assert_invalid(Map.put(params, Atom.to_string(key), "different"))
      assert_invalid([{key, "different"} | Map.to_list(params)])
    end

    assert_invalid(%{:q => "text", "q" => " text "})
    assert_invalid(%{:kind => :note, "kind" => "note"})
    assert_invalid(%{:limit => 20, "limit" => 20.0})
    assert_invalid(%{:tag_ids => [@tag_b, @tag_a], "tag_ids" => [@tag_a, @tag_b]})
  end

  test "tag lists are bounded before deduplication and contain only canonical UUIDs" do
    assert {:ok, %{tag_ids: [@tag_a]}} = new(tag_ids: List.duplicate(@tag_a, 20))
    assert_invalid(tag_ids: List.duplicate(@tag_a, 21))

    for tag_ids <- [
          nil,
          @tag_a,
          [nil],
          ["bad"],
          [String.upcase(@tag_a)],
          [<<255>>],
          [@tag_a <> "\0"],
          [@tag_a | :improper]
        ] do
      assert_invalid(tag_ids: tag_ids)
    end
  end

  test "the persistence port contains only scoped search and exact resolution callbacks" do
    assert Code.ensure_loaded?(Singularity.Core.KnowledgeSearchStore)

    assert apply(Singularity.Core.KnowledgeSearchStore, :behaviour_info, [:callbacks])
           |> Enum.sort() == [resolve: 2, search: 2]
  end

  test "mixed results preserve immutable Note and Document identities through a typed page" do
    assert {:ok, query} = new(q: "query")
    assert {:ok, page} = search(query, {:ok, %{items: [note(), document()], next_cursor: "next"}})
    assert page.__struct__ == KnowledgeSearchPage
    assert Map.keys(Map.from_struct(page)) |> Enum.sort() == [:items, :next_cursor]
    assert page.next_cursor == "next"
    assert length(page.items) == 2

    for {result, raw} <- Enum.zip(page.items, [note(), document()]) do
      assert result.__struct__ == KnowledgeSearchResult
      assert SourceLocator.to_map(result.locator) == raw.locator
      assert Map.from_struct(result) |> Map.put(:locator, raw.locator) == raw
      assert result_new(result, query) == {:ok, result}
    end

    assert_received {:store_query, query_map}
    refute is_struct(query_map)
    assert query_map == Map.from_struct(query)
  end

  test "terminal pages expose nil while the raw port uses only the done sentinel" do
    assert {:ok, query} = new(%{})

    assert {:ok, %{items: [], next_cursor: nil}} =
             search(query, {:ok, %{items: [], next_cursor: :done}})

    assert {:ok, %{items: [_], next_cursor: nil}} =
             search(query, {:ok, %{items: [note()], next_cursor: :done}})
  end

  test "adapter result maps have exact keys and cannot inject content or omit nullable fields" do
    assert {:ok, query} = new(%{})

    for row <- [note(), document()], key <- Map.keys(row) do
      assert_invalid_row(Map.delete(row, key), query)
      assert_invalid_row(Map.put(row, Atom.to_string(key), row[key]), query)
    end

    for row <- [
          nil,
          [],
          "content",
          Error.new(:invalid),
          Map.put(note(), :body, "private-body-canary"),
          Map.put(note(), :tag_labels, ["private-tag-canary"]),
          Map.put(note(), :deleted?, false)
        ] do
      assert_invalid_row(row, query)
    end
  end

  test "results reject foreign owners, nonprivate classifications and mismatched kinds" do
    assert {:ok, query} = new(q: "query")

    for {key, value} <- [
          owner_scope_id: @tag_a,
          owner_scope_id: "bad",
          classification: :public,
          classification: "private",
          kind: :asset,
          kind: "note"
        ] do
      assert_invalid_row(Map.put(note(), key, value), query)
    end

    assert {:ok, note_query} = new(kind: :note)
    assert_invalid_row(document(), note_query)
    assert {:ok, document_query} = new(kind: :document)
    assert_invalid_row(note(), document_query)
  end

  test "result entry identity, selector branch and ordinal must agree" do
    assert {:ok, query} = new(%{})

    for row <- [
          Map.put(note(), :fragment_id, @fragment),
          Map.put(document(), :fragment_id, nil),
          Map.put(document(), :fragment_id, String.upcase(@fragment)),
          Map.put(note(), :entry_id, "note:" <> @resource),
          Map.put(document(), :entry_id, "document:" <> String.duplicate("f", 64)),
          Map.put(note(), :entry_id, "document:" <> @fragment),
          Map.put(note(), :ordinal, 1)
        ] do
      assert_invalid_row(row, query)
    end

    for row <- [note(), document()],
        {key, value} <- [
          resource_id: "bad",
          resource_version_id: "bad",
          entry_id: nil,
          ordinal: nil,
          ordinal: -1,
          ordinal: 1.0,
          ordinal: "1",
          ordinal: 9_223_372_036_854_775_808
        ] do
      assert_invalid_row(Map.put(row, key, value), query)
    end
  end

  test "locators are validated and branch-specific provenance cannot be invented" do
    assert {:ok, query} = new(%{})

    assert {:ok, _} =
             result_new(
               document(%{locator: %{"version" => 1, "kind" => "fragment", "ordinal" => 0}}),
               query
             )

    for locator <- [
          nil,
          %{},
          %{"version" => 2, "kind" => "text", "start_line" => 1, "end_line" => 1},
          %{"version" => 1, "kind" => "pdf", "page" => 0},
          %{"version" => 1, "kind" => "fragment", "ordinal" => 1},
          %{"version" => 1, "kind" => "markdown", "heading_path" => ["secret\0"]}
        ] do
      assert_invalid_row(document(%{locator: locator}), query)
    end

    for locator <- [
          document().locator,
          %{"version" => 1, "kind" => "markdown", "heading_path" => ["Heading"]},
          %{
            "version" => 1,
            "kind" => "markdown",
            "heading_path" => [],
            "start_line" => 1,
            "end_line" => 1
          }
        ] do
      assert_invalid_row(note(%{locator: locator}), query)
    end
  end

  test "titles retain canonical bytes and obey source bounds" do
    assert {:ok, query} = new(%{})

    for title <- ["Note", String.duplicate("a", 255), String.duplicate("é", 127)] do
      assert {:ok, %{title: ^title}} = result_new(note(%{title: title}), query)
    end

    for title <- [
          nil,
          "",
          " ",
          " untrimmed ",
          "title\0",
          <<255>>,
          1,
          String.duplicate("a", 256),
          String.duplicate("é", 128)
        ] do
      assert_invalid_row(note(%{title: title}), query)
      assert_invalid_row(document(%{title: title}), query)
    end
  end

  test "snippets bound Unicode codepoints not graphemes and preserve plain source text" do
    assert {:ok, query} = new(%{})

    for snippet <- [
          "",
          "<em>literal source text</em>",
          String.duplicate("a", 160),
          String.duplicate("📝", 160),
          String.duplicate("e\u0301", 80)
        ] do
      assert {:ok, %{snippet: ^snippet}} = result_new(note(%{snippet: snippet}), query)
    end

    for snippet <- [
          nil,
          1,
          <<255>>,
          "text\0",
          String.duplicate("a", 161),
          String.duplicate("📝", 161),
          String.duplicate("e\u0301", 81)
        ] do
      assert_invalid_row(note(%{snippet: snippet}), query)
    end
  end

  test "results require valid immutable UTC timestamps and bounded integer policy ranks" do
    assert {:ok, query} = new(q: "query")

    for rank <- [0, 1, 7_000_000],
        do: assert({:ok, %{rank: ^rank}} = result_new(note(%{rank: rank}), query))

    for rank <- [nil, -1, 7_000_001, 1.0, "1"], do: assert_invalid_row(note(%{rank: rank}), query)

    for time <- [
          nil,
          "2026-10-09",
          ~N[2026-10-09 12:00:00],
          %{@time | month: 13},
          %{@time | microsecond: {1_000_000, 6}},
          %{@time | utc_offset: 1},
          %{@time | time_zone: "Other"}
        ] do
      assert_invalid_row(note(%{source_inserted_at: time}), query)
    end

    assert {:ok, empty_query} = new(%{})
    assert_invalid_row(note(%{rank: 1}), empty_query)
  end

  test "nested UTC timestamps cannot carry additional fields or arbitrary zone labels" do
    assert {:ok, query} = new(%{})

    for time <- [
          Map.put(@time, :body, "private-body-canary"),
          Map.put(@time, "year", 2026),
          %{@time | zone_abbr: "private-body-canary"},
          %{@time | zone_abbr: nil},
          Map.delete(@time, :zone_abbr)
        ] do
      assert_invalid_row(note(%{source_inserted_at: time}), query)
    end
  end

  test "timestamp precision cannot hide microseconds needed by pagination" do
    assert {:ok, query} = new(%{})

    for time <- [~U[2026-10-09 12:00:00Z], ~U[2026-10-09 12:00:00.123Z], @time] do
      assert {:ok, %{source_inserted_at: ^time}} =
               result_new(note(%{source_inserted_at: time}), query)
    end

    for microsecond <- [{1, 0}, {123_456, 3}] do
      assert_invalid_row(note(%{source_inserted_at: %{@time | microsecond: microsecond}}), query)
    end
  end

  test "pages enforce exact shape, the query limit, distinct entries and bounded raw cursors" do
    assert {:ok, query} = new(limit: 1)

    for page <- [
          nil,
          [],
          "canary",
          %{},
          %{items: []},
          %{next_cursor: :done},
          %{items: [], next_cursor: :done, body: "canary"},
          %{"items" => [], "next_cursor" => :done},
          %{items: [note(), document()], next_cursor: :done},
          %{items: [note() | :improper], next_cursor: :done}
        ] do
      assert search(query, {:ok, page}) == unavailable()
      assert page_new(page, query) == unavailable()
    end

    assert {:ok, query} = new(limit: 2)
    assert search(query, {:ok, %{items: [note(), note()], next_cursor: :done}}) == unavailable()

    for cursor <- [nil, "", "  ", "token\0", <<255>>, 1, String.duplicate("a", 2_049)] do
      assert search(query, {:ok, %{items: [note()], next_cursor: cursor}}) == unavailable()
    end

    cursor = String.duplicate("a", 2_048)

    assert {:ok, %{next_cursor: ^cursor}} =
             search(query, {:ok, %{items: [note()], next_cursor: cursor}})
  end

  test "invalid and forged queries stop before any persistence call" do
    assert {:ok, query} = new(%{})

    for input <- [
          nil,
          %{},
          Map.from_struct(query),
          Map.put(query, :limit, 51),
          Map.put(query, :classification, :public),
          Map.put(query, :policy_version, 2),
          Map.put(query, :q, "bad\0"),
          Map.put(query, :extra, "canary")
        ] do
      assert search(input, {:ok, %{items: [], next_cursor: :done}}) ==
               {:error, Error.new(:invalid)}

      refute_received {:store_query, _}
    end
  end

  test "adapter failures cannot leak content through error details, exceptions, throws or logs" do
    assert {:ok, query} = new(%{})
    canary = "private-query-title-body-locator-tag-canary"

    log =
      capture_log(fn ->
        for result <- [
              fn -> raise canary end,
              fn -> throw(canary) end,
              fn -> exit(canary) end,
              {:error, canary},
              {:ok, canary},
              :invalid,
              {:error, %Error{code: :unknown, message: canary}},
              {:error, %Error{code: :forbidden, retryable?: "bad"}}
            ] do
          assert search(query, result) == unavailable()
        end

        for code <- [
              :invalid,
              :forbidden,
              :unauthenticated,
              :vault_locked,
              :not_found,
              :storage_unavailable
            ],
            retryable? <- [false, true] do
          error =
            Error.new(code, retryable?: retryable?, message: canary, details: %{body: canary})

          assert search(query, {:error, error}) ==
                   {:error, Error.new(code, retryable?: retryable?)}
        end
      end)

    refute log =~ canary
  end

  test "forged result structs are revalidated and cannot carry extra fields" do
    assert {:ok, query} = new(%{})
    assert {:ok, result} = result_new(note(), query)

    for input <- [
          Map.put(result, :owner_scope_id, @tag_a),
          Map.put(result, :rank, -1),
          Map.put(result, :text, "canary"),
          Map.put(result, "title", result.title),
          Map.delete(result, :fragment_id),
          %{__struct__: KnowledgeSearchResult}
        ] do
      assert result_new(input, query) == {:error, Error.new(:invalid)}
    end
  end

  defp note(overrides \\ %{}) do
    Map.merge(
      %{
        owner_scope_id: @owner,
        classification: :private,
        kind: :note,
        resource_id: @resource,
        resource_version_id: @version,
        fragment_id: nil,
        entry_id: "note:" <> @version,
        ordinal: 0,
        title: "Note",
        snippet: "body",
        locator: %{"version" => 1, "kind" => "markdown", "heading_path" => []},
        source_inserted_at: @time,
        rank: 0
      },
      overrides
    )
  end

  defp document(overrides \\ %{}) do
    note(%{
      kind: :document,
      resource_id: @document_resource,
      resource_version_id: @document_version,
      fragment_id: @fragment,
      entry_id: "document:" <> @fragment,
      title: "Document",
      locator: %{"version" => 1, "kind" => "text", "start_line" => 1, "end_line" => 1}
    })
    |> Map.merge(overrides)
  end

  defp search(query, result) do
    assert Code.ensure_loaded?(KnowledgeSearch)
    apply(KnowledgeSearch, :search, [Store, %{test_pid: self(), result: result}, query])
  end

  defp result_new(input, query) do
    assert Code.ensure_loaded?(KnowledgeSearchResult)
    apply(KnowledgeSearchResult, :new, [input, query])
  end

  defp page_new(input, query), do: apply(KnowledgeSearchPage, :new, [input, query])

  defp assert_invalid_row(row, query) do
    assert result_new(row, query) == {:error, Error.new(:invalid)}
    assert search(query, {:ok, %{items: [row], next_cursor: :done}}) == unavailable()
  end

  defp unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}

  test "page and kind bounds reject nonintegers, malformed values and unknown kinds" do
    for limit <- [1, 20, 50], do: assert({:ok, %{limit: ^limit}} = new(limit: limit))
    for limit <- [nil, 0, 51, -1, 1.0, "1", false], do: assert_invalid(limit: limit)

    for kind <- [nil, "", :asset, "Note", "ALL", "unknown", "note\0", <<255>>, 1] do
      assert_invalid(kind: kind)
    end
  end

  test "opaque cursors are bounded but are not trimmed or decoded by the query value" do
    for cursor <- [nil, "opaque", " token ", String.duplicate("a", 2_048)] do
      assert {:ok, %{cursor: ^cursor}} = new(cursor: cursor)
    end

    for cursor <- ["", " \t", :done, 1, false, <<255>>, "token\0", String.duplicate("a", 2_049)] do
      assert_invalid(cursor: cursor)
    end
  end

  test "invalid trusted owner identifiers and non-attribute public values fail closed" do
    for owner <- [nil, "", 1, String.upcase(@owner), <<255>>, @owner <> "\0"] do
      assert new(%{}, owner) == {:error, Error.new(:invalid)}
    end

    assert {:ok, query} = new(%{})

    for params <- [
          nil,
          1,
          "query",
          false,
          [:q],
          [{"q", "query"}],
          [{:q, "q"} | :improper],
          Error.new(:invalid),
          query,
          Map.from_struct(query)
        ] do
      assert_invalid(params)
    end
  end

  test "internal query revalidation rejects forged scope, policy, shape and noncanonical values" do
    assert {:ok, query} = new(%{tag_ids: [@tag_a, @tag_b]})
    assert {:ok, ^query} = validate(query)

    for invalid <- [
          Map.put(query, :classification, :public),
          Map.put(query, :policy_version, 2),
          Map.put(query, :owner_scope_id, "bad"),
          Map.put(query, :q, " untrimmed "),
          Map.put(query, :kind, "all"),
          Map.put(query, :tag_ids, [@tag_b, @tag_a]),
          Map.put(query, :tag_ids, [@tag_a, @tag_a]),
          Map.put(query, :limit, 0),
          Map.put(query, :cursor, ""),
          Map.put(query, :unknown, "canary"),
          Map.put(query, "q", ""),
          Map.delete(query, :cursor),
          Map.from_struct(query),
          %{__struct__: KnowledgeSearchQuery},
          nil
        ] do
      assert validate(invalid) == {:error, Error.new(:invalid)}
    end
  end

  defp new(params, owner \\ @owner) do
    assert Code.ensure_loaded?(KnowledgeSearchQuery)
    apply(KnowledgeSearchQuery, :new, [owner, params])
  end

  defp validate(query), do: apply(KnowledgeSearchQuery, :validate, [query])

  defp assert_invalid(params), do: assert(new(params) == {:error, Error.new(:invalid)})
end
