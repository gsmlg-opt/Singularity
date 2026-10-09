defmodule Singularity.Runtime.KnowledgeSearchApiTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Singularity.Core.{Error, SearchPolicy, SourceLocator}
  alias Singularity.Retrieval.{KnowledgeSearchPage, KnowledgeSearchQuery, KnowledgeSearchResult}
  alias Singularity.Runtime.DTO.KnowledgeSearchPage, as: PageDTO
  alias Singularity.Runtime.DTO.KnowledgeSearchResult, as: ResultDTO

  @owner "00000000-0000-4000-8000-000000000b01"
  @other_owner "00000000-0000-4000-8000-000000000b02"
  @resource "00000000-0000-4000-8000-000000000b03"
  @version "00000000-0000-4000-8000-000000000b04"
  @document_resource "00000000-0000-4000-8000-000000000b05"
  @document_version "00000000-0000-4000-8000-000000000b06"
  @fragment String.duplicate("ab01", 16)
  @timestamp ~U[2026-10-09 12:00:00.123456Z]
  @canary "private-query-title-body-locator-tag-canary"
  @result_fields [
    :kind,
    :resource_id,
    :resource_version_id,
    :fragment_id,
    :title,
    :snippet,
    :locator,
    :source_inserted_at,
    :rank
  ]

  test "pure conversion exposes exactly the approved mixed result and page fields" do
    query = query!()
    note = result!(:note, query)
    document = result!(:document, query)
    page = page!([note, document], "next-page", query)

    assert {:ok, public_page} = convert_page(page, query)
    assert public_page.__struct__ == PageDTO
    assert_fields(public_page, [:items, :next_cursor])
    assert public_page.next_cursor == "next-page"
    assert [public_note, public_document] = public_page.items

    for {public, internal} <- [{public_note, note}, {public_document, document}] do
      assert public.__struct__ == ResultDTO
      assert_fields(public, @result_fields)
      assert Map.from_struct(public) === Map.take(internal, @result_fields)

      for field <- [:owner_scope_id, :classification, :entry_id, :ordinal, :body, :tag_labels] do
        refute Map.has_key?(public, field)
      end
    end

    assert public_note.fragment_id == nil
    assert public_document.fragment_id == @fragment
    assert public_note.resource_version_id == @version
    assert public_document.resource_version_id == @document_version
  end

  test "conversion retains title snippet canonical locator and lossless timestamp bytes" do
    query = query!(q: "知识")
    title = "e\u0301 知识"
    snippet = " <em>e\u0301</em>\n知识 📝 "

    for timestamp <- [~U[2026-10-09 12:00:00Z], ~U[2026-10-09 12:00:00.123Z], @timestamp] do
      internal =
        result!(:document, query, %{
          title: title,
          snippet: snippet,
          source_inserted_at: timestamp,
          rank: 7_000_000,
          locator: %{
            "version" => 1,
            "kind" => "markdown",
            "heading_path" => ["知识", "é"],
            "start_line" => 2,
            "end_line" => 9
          }
        })

      assert {:ok, public} = convert_result(internal, query)
      assert public.title === title
      assert public.snippet === snippet
      assert public.locator === internal.locator
      assert SourceLocator.encode(public.locator) === SourceLocator.encode(internal.locator)
      assert public.source_inserted_at === timestamp
      assert DateTime.to_iso8601(public.source_inserted_at) === DateTime.to_iso8601(timestamp)
      assert public.rank == 7_000_000
    end
  end

  test "owner classification and query kind are checked before stripping private fields" do
    query = query!()
    note = result!(:note, query)
    document = result!(:document, query)

    for internal <- [note, document],
        {field, value} <- [owner_scope_id: @other_owner, classification: :public] do
      assert_unavailable(convert_result(Map.put(internal, field, value), query))

      assert_unavailable(
        convert_page(%{page!([], nil, query) | items: [Map.put(internal, field, value)]}, query)
      )
    end

    assert_unavailable(convert_result(document, query!(kind: :note)))
    assert_unavailable(convert_result(note, query!(kind: :document)))
  end

  test "source selector entry identity and ordinal are revalidated on typed results" do
    query = query!()
    note = result!(:note, query)

    document =
      result!(:document, query, %{
        locator: %{"version" => 1, "kind" => "fragment", "ordinal" => 0}
      })

    for internal <- [
          %{note | fragment_id: @fragment},
          %{document | fragment_id: nil},
          %{document | fragment_id: String.upcase(@fragment)},
          %{note | resource_id: String.upcase(@resource)},
          %{note | resource_version_id: "bad"},
          %{note | entry_id: "note:" <> @resource},
          %{document | entry_id: "document:" <> String.duplicate("f", 64)},
          %{note | ordinal: 1},
          %{document | ordinal: 1},
          %{document | ordinal: -1},
          %{document | ordinal: 1.0}
        ] do
      assert_unavailable(convert_result(internal, query))
    end
  end

  test "result seam rejects raw maps foreign structs extra fields and missing fields" do
    query = query!()
    internal = result!(:note, query)

    for malformed <-
          [
            nil,
            [],
            @canary,
            Map.from_struct(internal),
            Error.new(:invalid, message: @canary),
            Map.put(internal, :body, @canary),
            Map.put(internal, "title", @canary),
            %{__struct__: KnowledgeSearchResult}
          ] ++ Enum.map(Map.keys(Map.from_struct(internal)), &Map.delete(internal, &1)) do
      assert_unavailable(convert_result(malformed, query))
    end
  end

  test "typed locators reject extra metadata missing fields and noncanonical forged values" do
    query = query!()

    internal =
      result!(:document, query, %{
        locator: %{"version" => 1, "kind" => "markdown", "heading_path" => ["é"]}
      })

    for locator <- [
          nil,
          SourceLocator.to_map(internal.locator),
          Map.put(internal.locator, :body, @canary),
          Map.delete(internal.locator, :fields),
          %{__struct__: SourceLocator},
          %{internal.locator | fields: Map.put(internal.locator.fields, :body, @canary)},
          %{internal.locator | fields: %{heading_path: ["e\u0301"]}},
          %{internal.locator | fields: %{heading_path: [@canary | :improper]}},
          %{internal.locator | fields: %{heading_path: ["secret\0"]}}
        ] do
      assert_unavailable(convert_result(%{internal | locator: locator}, query))
    end
  end

  test "timestamp shape metadata UTC validity and lossless precision are revalidated" do
    query = query!()
    internal = result!(:note, query)

    for timestamp <- [
          nil,
          ~N[2026-10-09 12:00:00],
          Map.from_struct(@timestamp),
          Map.put(@timestamp, :body, @canary),
          Map.put(@timestamp, "year", 2026),
          Map.delete(@timestamp, :zone_abbr),
          %{__struct__: DateTime},
          %{@timestamp | zone_abbr: @canary},
          %{@timestamp | time_zone: "Other"},
          %{@timestamp | utc_offset: 1},
          %{@timestamp | month: 13},
          %{@timestamp | calendar: :not_a_calendar},
          %{@timestamp | microsecond: {1, 0}},
          %{@timestamp | microsecond: {123_456, 3}},
          %{@timestamp | microsecond: {1_000_000, 6}}
        ] do
      assert_unavailable(convert_result(%{internal | source_inserted_at: timestamp}, query))
    end
  end

  test "typed results retain enforced title snippet and integer rank bounds" do
    query = query!(q: "query")
    internal = result!(:note, query)

    for {field, value} <- [
          title: " untrimmed ",
          title: String.duplicate("a", 256),
          title: @canary <> "\0",
          snippet: String.duplicate("📝", 161),
          snippet: String.duplicate("e\u0301", 81),
          snippet: <<255>>,
          rank: -1,
          rank: 7_000_001,
          rank: 1.0
        ] do
      assert_unavailable(convert_result(Map.put(internal, field, value), query))
    end

    assert_unavailable(convert_result(%{internal | rank: 1}, query!()))
  end

  test "query validation happens before any malformed internal conversion" do
    query = query!()

    for malformed_query <- [
          nil,
          Map.from_struct(query),
          Map.put(query, :owner_scope_id, "bad"),
          Map.put(query, :classification, :public),
          Map.put(query, :q, " untrimmed "),
          Map.put(query, :policy_version, 2),
          Map.put(query, :limit, 51),
          Map.put(query, :body, @canary),
          Map.delete(query, :cursor),
          %{__struct__: KnowledgeSearchQuery}
        ] do
      assert convert_result(@canary, malformed_query) == {:error, Error.new(:invalid)}
      assert convert_page(@canary, malformed_query) == {:error, Error.new(:invalid)}
    end
  end

  test "typed terminal pages expose nil without weakening the raw done-only contract" do
    query = query!()

    for items <- [[], [result!(:note, query)]] do
      internal = page!(items, nil, query)
      assert {:ok, public} = convert_page(internal, query)
      assert public.next_cursor == nil
      assert_unavailable(KnowledgeSearchPage.new(%{items: items, next_cursor: nil}, query))
      assert_unavailable(convert_page(%{internal | next_cursor: :done}, query))
    end
  end

  test "pages revalidate exact typed shape proper lists limit and distinct entry identities" do
    query = query!(limit: 1)
    note = result!(:note, query)
    document = result!(:document, query)
    internal = page!([], nil, query)

    for malformed <- [
          nil,
          [],
          @canary,
          Map.from_struct(internal),
          Error.new(:invalid),
          Map.put(internal, :body, @canary),
          Map.put(internal, "items", []),
          Map.delete(internal, :items),
          Map.delete(internal, :next_cursor),
          %{__struct__: KnowledgeSearchPage},
          %{internal | items: nil},
          %{internal | items: [note | :improper]},
          %{internal | items: [note, document]},
          %{internal | items: [Map.from_struct(note)]},
          %{internal | items: [Map.put(note, :body, @canary)]}
        ] do
      assert_unavailable(convert_page(malformed, query))
    end

    assert_unavailable(convert_page(%{internal | items: [note, note]}, query!(limit: 2)))
  end

  test "page cursors stay opaque byte-exact nonblank and bounded" do
    query = query!()
    internal = page!([], nil, query)

    for cursor <- [
          "opaque",
          " token ",
          String.duplicate("a", SearchPolicy.current().cursor_bytes)
        ] do
      assert {:ok, %{next_cursor: ^cursor}} =
               convert_page(%{internal | next_cursor: cursor}, query)
    end

    for cursor <- [
          "",
          " \t\n",
          :done,
          1,
          false,
          <<255>>,
          @canary <> "\0",
          String.duplicate("a", SearchPolicy.current().cursor_bytes + 1)
        ] do
      assert_unavailable(convert_page(%{internal | next_cursor: cursor}, query))
    end
  end

  test "malformed internal values produce content-free retryable errors and no content logs" do
    query = query!()
    internal = result!(:note, query, %{title: @canary, snippet: @canary})

    log =
      capture_log(fn ->
        assert_unavailable(convert_result(%{internal | owner_scope_id: @other_owner}, query))

        assert_unavailable(
          convert_result(Error.new(:invalid, message: @canary, details: %{body: @canary}), query)
        )

        assert_unavailable(
          convert_page(%{page!([], nil, query) | items: [internal, internal]}, query)
        )
      end)

    refute log =~ @canary
  end

  defp query!(params \\ %{}) do
    assert {:ok, query} = KnowledgeSearchQuery.new(@owner, params)
    query
  end

  defp result!(kind, query, overrides \\ %{}) do
    attrs = %{
      owner_scope_id: @owner,
      classification: :private,
      kind: kind,
      resource_id: if(kind == :note, do: @resource, else: @document_resource),
      resource_version_id: if(kind == :note, do: @version, else: @document_version),
      fragment_id: if(kind == :note, do: nil, else: @fragment),
      entry_id: if(kind == :note, do: "note:" <> @version, else: "document:" <> @fragment),
      ordinal: 0,
      title: "Knowledge",
      snippet: "source text",
      locator:
        if(kind == :note,
          do: %{"version" => 1, "kind" => "markdown", "heading_path" => []},
          else: %{"version" => 1, "kind" => "text", "start_line" => 1, "end_line" => 2}
        ),
      source_inserted_at: @timestamp,
      rank: 0
    }

    assert {:ok, result} = KnowledgeSearchResult.new(Map.merge(attrs, overrides), query)
    result
  end

  defp page!(items, cursor, query) do
    raw_cursor = if is_nil(cursor), do: :done, else: cursor
    assert {:ok, page} = KnowledgeSearchPage.new(%{items: items, next_cursor: raw_cursor}, query)
    page
  end

  defp convert_result(result, query) do
    assert Code.ensure_loaded?(ResultDTO)
    apply(ResultDTO, :from_result, [result, query])
  end

  defp convert_page(page, query) do
    assert Code.ensure_loaded?(PageDTO)
    apply(PageDTO, :from_page, [page, query])
  end

  defp assert_fields(value, fields) do
    assert Map.keys(Map.from_struct(value)) |> Enum.sort() == Enum.sort(fields)
  end

  defp assert_unavailable(result) do
    assert result == {:error, Error.new(:storage_unavailable, retryable?: true)}
  end
end
