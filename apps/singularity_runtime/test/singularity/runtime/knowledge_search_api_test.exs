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

defmodule Singularity.Runtime.KnowledgeSearchUseCaseTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.{DocumentFragment, Error, SearchSource, SourceLocator}
  alias Singularity.Retrieval.{KnowledgeSearchPage, KnowledgeSearchQuery, KnowledgeSearchResult}
  alias Singularity.Runtime.Api
  alias Singularity.Runtime.DTO.Session
  alias Singularity.Runtime.SessionContext

  @owner "00000000-0000-4000-8000-000000000c01"
  @principal "00000000-0000-4000-8000-000000000c02"
  @session "00000000-0000-4000-8000-000000000c03"
  @resource "00000000-0000-4000-8000-000000000c04"
  @version "00000000-0000-4000-8000-000000000c05"
  @other "00000000-0000-4000-8000-000000000c06"
  @timestamp ~U[2026-10-10 12:00:00.123456Z]
  @canary "source-body-query-canary"

  defmodule Scope do
    def with_read_request(owner, _runtime, _session, requirement, callback) do
      send(owner, {:scope, requirement})
      Process.get(:knowledge_scope_result) || callback.(:scoped_repo)
    end
  end

  defmodule Retrieval do
    def search(owner, _store, repo, query) do
      send(owner, {:search, repo, query})

      Process.get(
        :knowledge_page_result,
        {:ok, %KnowledgeSearchPage{items: [], next_cursor: nil}}
      )
    end
  end

  defmodule Store do
    def resolve(owner, repo, selector) do
      send(owner, {:resolve, repo, selector})
      Process.get(:knowledge_source_result)
    end
  end

  setup do
    assert Code.ensure_loaded?(Api)
    :ok
  end

  test "public API rejects all owner and policy overrides before invoking search" do
    config = %{search_knowledge: fn _, _ -> flunk("invalid input reached search") end}
    assert Code.ensure_loaded?(Api)

    for {key, value} <- [
          owner_scope_id: @owner,
          vault_id: @owner,
          principal_id: @principal,
          classification: :private,
          rank: 0,
          timeout: 5_000,
          policy_version: 1
        ],
        key <- [key, Atom.to_string(key)] do
      assert function_exported?(Api, :search_knowledge, 3)

      assert apply(Api, :search_knowledge, [config, session(), %{key => value}]) ==
               {:error, :invalid}
    end
  end

  test "mixed search binds trusted owner and conjunctive read requirements" do
    runtime = %{operation_scope: {Scope, self()}, knowledge_search: {Retrieval, self()}}
    context = struct!(SessionContext, Map.from_struct(session()))

    assert Code.ensure_loaded?(Singularity.Runtime.Search.Search)

    assert {:ok, %KnowledgeSearchPage{items: [], next_cursor: nil}} =
             apply(Singularity.Runtime.Search.Search, :run, [runtime, context, %{q: " text "}])

    assert_received {:scope,
                     %{
                       required_capabilities: ["asset.read", "note.read"],
                       requires_unlocked?: true,
                       classification: :private,
                       vault_id: @owner
                     }}

    assert_received {:search, :scoped_repo,
                     %KnowledgeSearchQuery{owner_scope_id: @owner, q: "text", kind: :all}}
  end

  test "injected API converts only validated typed pages to owner-free public DTOs" do
    config = %{
      search_knowledge: fn _, _ ->
        {:ok, %KnowledgeSearchPage{items: [], next_cursor: nil}}
      end
    }

    assert Code.ensure_loaded?(Api)
    assert function_exported?(Api, :search_knowledge, 3)

    assert {:ok, %Singularity.Runtime.DTO.KnowledgeSearchPage{items: [], next_cursor: nil}} =
             apply(Api, :search_knowledge, [config, session(), %{}])

    assert apply(Api, :search_knowledge, [
             %{search_knowledge: fn _, _ -> {:ok, %{items: [], next_cursor: nil}} end},
             session(),
             %{}
           ]) == {:error, :storage_unavailable}
  end

  test "each kind uses its precise existing read authority and unlock boundary" do
    runtime = runtime()
    context = struct!(SessionContext, Map.from_struct(session()))

    for {kind, capability, unlocked?} <- [
          {:note, "note.read", true},
          {:document, "asset.read", false}
        ] do
      assert {:ok, _} =
               apply(Singularity.Runtime.Search.Search, :run, [runtime, context, %{kind: kind}])

      assert_received {:scope,
                       %{
                         required_capability: ^capability,
                         requires_unlocked?: ^unlocked?,
                         vault_id: @owner
                       }}

      refute_received {:scope, _}
      assert_received {:search, :scoped_repo, %KnowledgeSearchQuery{kind: ^kind}}

      source = source(kind)
      Process.put(:knowledge_source_result, {:ok, source})

      assert {:ok, ^source} =
               apply(Singularity.Runtime.Search.Resolve, :run, [
                 runtime,
                 context,
                 selector(source)
               ])

      assert_received {:scope,
                       %{
                         required_capability: ^capability,
                         requires_unlocked?: ^unlocked?,
                         vault_id: @owner
                       }}

      assert_received {:resolve, :scoped_repo, %SearchSource{kind: ^kind}}
    end
  end

  test "public resolution accepts only the exact whole selector before any content callback" do
    config = %{resolve_search_source: fn _, _ -> flunk("malformed selector reached content") end}
    valid = selector(source(:note))

    assert function_exported?(Api, :resolve_search_source, 3)

    for input <-
          [
            nil,
            [],
            %{},
            Map.put(valid, :kind, :all),
            Map.put(valid, :fragment_id, String.duplicate("f", 64)),
            Map.put(valid, :resource_id, "bad"),
            Map.put(valid, :resource_version_id, String.upcase(@version)),
            Map.put(valid, "resource_id", @other)
          ] ++
            Enum.map(Map.keys(valid), &Map.delete(valid, &1)) ++
            Enum.map(
              [
                :owner_scope_id,
                :vault_id,
                :principal_id,
                :classification,
                :locator,
                :body,
                :digest,
                :storage_ref,
                :key
              ],
              &Map.put(valid, &1, @canary)
            ) do
      assert apply(Api, :resolve_search_source, [config, session(), input]) == {:error, :invalid}
    end

    assert {:ok, typed} = SearchSource.new(valid)

    for input <- [
          Map.put(typed, :body, @canary),
          Map.delete(typed, :fragment_id),
          %{typed | kind: "note"},
          %{typed | resource_id: "bad"}
        ] do
      assert apply(Api, :resolve_search_source, [config, session(), input]) == {:error, :invalid}
    end
  end

  test "exact-source DTO exposes exactly nine fields and preserves source bytes" do
    for kind <- [:note, :document] do
      source = source(kind)
      assert {:ok, dto} = convert_source(source, selector(source))

      fields =
        ~w(kind resource_id resource_version_id fragment_id ordinal title body locator source_inserted_at)a

      assert Map.keys(Map.from_struct(dto)) |> Enum.sort() == Enum.sort(fields)
      assert dto.__struct__ == Singularity.Runtime.DTO.KnowledgeSource
      assert dto.body === source.body
      assert dto.title === source.title
      assert dto.source_inserted_at === @timestamp
      assert SourceLocator.to_map(dto.locator) === source.locator

      config = %{resolve_search_source: fn _, _ -> {:ok, source} end}

      assert apply(Api, :resolve_search_source, [config, session(), selector(source)]) ==
               {:ok, dto}
    end
  end

  test "untrusted exact content owner and full immutable identity are revalidated before stripping" do
    for kind <- [:note, :document] do
      source = source(kind)

      invalid =
        [
          nil,
          [],
          @canary,
          Map.put(source, :extra, @canary),
          Map.put(source, :owner_scope_id, @other),
          Map.put(source, :classification, :public),
          Map.put(source, :resource_id, @other),
          Map.put(source, :resource_version_id, @other),
          Map.put(source, :kind, if(kind == :note, do: :document, else: :note)),
          Map.put(source, :fragment_id, String.duplicate("f", 64)),
          Map.put(source, :title, " untrimmed "),
          Map.put(source, :title, String.duplicate("x", 256)),
          Map.put(source, :title, @canary <> "\0"),
          Map.put(source, :body, <<255>>),
          Map.put(source, :body, @canary <> "\0"),
          Map.put(
            source,
            :body,
            String.duplicate("x", if(kind == :note, do: 1_048_577, else: 65_537))
          ),
          Map.put(source, :ordinal, -1),
          Map.put(source, :source_inserted_at, Map.put(@timestamp, :body, @canary)),
          Map.put(source, :source_inserted_at, %{@timestamp | microsecond: {1, 0}}),
          Map.put(source, :locator, Map.put(source.locator, "body", @canary))
        ] ++
          Enum.map(Map.keys(source), &Map.delete(source, &1))

      for malformed <- invalid do
        assert convert_source(malformed, selector(source)) == unavailable()
        config = %{resolve_search_source: fn _, _ -> {:ok, malformed} end}

        assert apply(Api, :resolve_search_source, [config, session(), selector(source)]) ==
                 {:error, :storage_unavailable}
      end
    end
  end

  test "source bounds and fragment-derived content identity do not silently normalize provenance" do
    note = %{
      source(:note)
      | body: String.duplicate("x", 1_048_576),
        title: String.duplicate("x", 255)
    }

    assert {:ok, %{body: body}} = convert_source(note, selector(note))
    assert body === note.body
    assert convert_source(%{note | ordinal: 1}, selector(note)) == unavailable()

    assert convert_source(
             %{
               note
               | locator: %{"version" => 1, "kind" => "markdown", "heading_path" => ["heading"]}
             },
             selector(note)
           ) == unavailable()

    document = source(:document, String.duplicate("x", 65_536))
    assert {:ok, %{body: body}} = convert_source(document, selector(document))
    assert body === document.body

    for malformed <- [
          %{document | body: "changed"},
          %{document | body: "line\r\n"},
          %{document | ordinal: 1},
          %{
            document
            | locator: %{"version" => 1, "kind" => "markdown", "heading_path" => ["e\u0301"]}
          }
        ] do
      assert convert_source(malformed, selector(document)) == unavailable()
    end
  end

  test "malformed and foreign typed search values cannot escape injected runtime adapters" do
    assert {:ok, query} = KnowledgeSearchQuery.new(@owner, %{})
    raw = source(:note)

    assert {:ok, result} =
             KnowledgeSearchResult.new(
               raw
               |> Map.drop([:body])
               |> Map.put(:snippet, "text")
               |> Map.put(:entry_id, "note:" <> @version)
               |> Map.put(:rank, 0),
               query
             )

    page = %KnowledgeSearchPage{items: [result], next_cursor: nil}

    for malformed <- [
          %{page | items: [%{result | owner_scope_id: @other}]},
          %{page | items: [Map.put(result, :body, @canary)]},
          %{page | items: [%{result | resource_version_id: @other}]},
          %{page | items: [result, result]}
        ] do
      config = %{search_knowledge: fn _, _ -> {:ok, malformed} end}

      assert apply(Api, :search_knowledge, [config, session(), %{}]) ==
               {:error, :storage_unavailable}

      Process.put(:knowledge_page_result, {:ok, malformed})

      assert apply(Singularity.Runtime.Search.Search, :run, [
               runtime(),
               struct!(SessionContext, Map.from_struct(session())),
               %{}
             ]) == unavailable()
    end
  end

  test "authorization errors retain stable distinctions and adapter diagnostics stay sanitized" do
    for code <- [:unauthenticated, :forbidden, :vault_locked, :not_found, :invalid] do
      error = Error.new(code, message: @canary, details: %{body: @canary})

      config = %{
        search_knowledge: fn _, _ -> {:error, error} end,
        resolve_search_source: fn _, _ -> {:error, error} end
      }

      assert apply(Api, :search_knowledge, [config, session(), %{}]) == {:error, code}

      assert apply(Api, :resolve_search_source, [config, session(), selector(source(:note))]) ==
               {:error, code}

      Process.put(:knowledge_scope_result, {:error, error})
      context = struct!(SessionContext, Map.from_struct(session()))

      assert apply(Singularity.Runtime.Search.Search, :run, [runtime(), context, %{}]) ==
               {:error, Error.new(code)}

      assert apply(Singularity.Runtime.Search.Resolve, :run, [
               runtime(),
               context,
               selector(source(:note))
             ]) == {:error, Error.new(code)}
    end
  end

  defp runtime do
    %{
      operation_scope: {Scope, self()},
      knowledge_search: {Retrieval, self()},
      knowledge_search_store: {Store, self()}
    }
  end

  defp source(kind, body \\ "e\u0301 source\n知识") do
    locator =
      if kind == :note,
        do: %{"version" => 1, "kind" => "markdown", "heading_path" => []},
        else: %{"version" => 1, "kind" => "text", "start_line" => 1, "end_line" => 2}

    attrs = %{
      owner_scope_id: @owner,
      classification: :private,
      kind: kind,
      resource_id: @resource,
      resource_version_id: @version,
      fragment_id: nil,
      ordinal: 0,
      title: "e\u0301 Knowledge",
      body: body,
      locator: locator,
      source_inserted_at: @timestamp
    }

    if kind == :note do
      attrs
    else
      assert {:ok, fragment} =
               DocumentFragment.new(
                 attrs
                 |> Map.drop([:kind, :title, :body, :source_inserted_at, :fragment_id])
                 |> Map.put(:text, body)
               )

      %{attrs | fragment_id: fragment.fragment_id}
    end
  end

  defp selector(source),
    do: Map.take(source, [:kind, :resource_id, :resource_version_id, :fragment_id])

  defp convert_source(source, selector) do
    assert Code.ensure_loaded?(Singularity.Runtime.DTO.KnowledgeSource)
    apply(Singularity.Runtime.DTO.KnowledgeSource, :from_source, [source, @owner, selector])
  end

  defp unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}

  defp session do
    %Session{
      session_id: @session,
      account_id: nil,
      principal_id: @principal,
      vault_id: @owner,
      expires_at: ~U[2099-01-01 00:00:00Z],
      principal_authorization_epoch: 0,
      vault_authorization_epoch: 0,
      authorization_epoch: 0,
      unlocked?: false
    }
  end
end

defmodule Singularity.Runtime.KnowledgeSourceIntegrationTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration

  alias Singularity.Core.{Error, SearchSource, SourceLocator}

  alias Singularity.Runtime.{
    Api,
    AuthorizationDependencies,
    CustodyReader,
    KeyCustodian,
    KeyLeaseSupervisor,
    OperationScope
  }

  alias Singularity.Runtime.DTO.Session
  alias Singularity.Storage.{Fixtures, KnowledgeFixtures, MigrationRepo, RequestRepo, ScopedRepo}
  alias Singularity.Storage.{AuthorizationLock, VaultLock}
  alias Singularity.Storage.Postgres.{IdentityRepository, KnowledgeSearchStore}

  defmodule ContentObserver do
    def search({observer, tag}, store, repo, query) do
      send(observer, {:knowledge_content_callback, tag, :search})
      Singularity.Retrieval.KnowledgeSearch.search(store, repo, query)
    end

    def resolve({observer, tag}, repo, selector) do
      send(observer, {:knowledge_content_callback, tag, :resolve})
      Singularity.Storage.Postgres.KnowledgeSearchStore.resolve(repo, selector)
    end
  end

  test "canonical exact sources resolve with no projection through the actual request role" do
    source = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    {document, fragment} = KnowledgeFixtures.ready_document!(source)

    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "DELETE FROM content.search_entries WHERE vault_id=$1", [
        source.vault_id
      ])
    end)

    for {row, kind, fragment_id, body} <- [
          {note, :note, nil, "body"},
          {document, :document, fragment.fragment_id, "text"}
        ] do
      assert {:ok, selector} =
               SearchSource.new(%{
                 kind: kind,
                 resource_id: Ecto.UUID.load!(row.resource_id),
                 resource_version_id: Ecto.UUID.load!(row.resource_version_id),
                 fragment_id: fragment_id
               })

      assert Code.ensure_loaded?(KnowledgeSearchStore)
      assert function_exported?(KnowledgeSearchStore, :resolve, 2)

      assert {:ok, resolved} =
               ScopedRepo.transact(
                 RequestRepo,
                 %{
                   principal_id: Ecto.UUID.load!(source.principal_id),
                   vault_id: Ecto.UUID.load!(source.vault_id)
                 },
                 fn repo ->
                   apply(KnowledgeSearchStore, :resolve, [repo, selector])
                 end
               )

      assert resolved.body == body
      assert resolved.owner_scope_id == Ecto.UUID.load!(source.vault_id)
      assert resolved.classification == :private
      assert resolved.kind == kind
      assert resolved.resource_version_id == selector.resource_version_id
      assert resolved.fragment_id == fragment_id

      assert Enum.sort(Map.keys(resolved)) ==
               Enum.sort(
                 ~w(owner_scope_id classification kind resource_id resource_version_id fragment_id ordinal title body locator source_inserted_at)a
               )
    end
  end

  test "public results resolve their historical Note and ready Document after both heads advance" do
    source = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    {document, fragment} = KnowledgeFixtures.ready_document!(source)
    project!(source, [note, document])
    {runtime, session, _custodian} = live_runtime(source, ["asset.read", "note.read"], true)
    config = config(runtime)

    assert {:ok, %{items: items}} = search(config, session, %{})
    assert [document_result, note_result] = Enum.sort_by(items, & &1.kind)
    note_selector = selector(note_result)
    document_selector = selector(document_result)
    assert {:ok, original_note} = resolve(config, session, note_selector)
    assert {:ok, original_document} = resolve(config, session, document_selector)
    assert original_document.fragment_id == fragment.fragment_id

    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "DELETE FROM content.search_entries WHERE vault_id=$1", [
        source.vault_id
      ])

      query!(MigrationRepo, "DELETE FROM content.note_search_documents WHERE resource_id=$1", [
        note.resource_id
      ])

      advance_note!(source, note)
      advance_document!(document)
    end)

    assert {:ok, ^original_note} = resolve(config, session, note_selector)
    assert {:ok, ^original_document} = resolve(config, session, document_selector)
    assert original_note.body == "body"
    assert original_note.title == "Note"

    assert SourceLocator.to_map(original_document.locator) ==
             SourceLocator.to_map(fragment.locator)

    assert {:ok, %{items: [], next_cursor: nil}} = search(config, session, %{})
  end

  test "exact canonical reads hide every forged identity kind nonready source and foreign owner" do
    source = KnowledgeFixtures.source!()
    foreign = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    {document, fragment} = KnowledgeFixtures.ready_document!(source)
    {foreign_document, foreign_fragment} = KnowledgeFixtures.ready_document!(foreign)
    pending = KnowledgeFixtures.document!(source)
    {runtime, session, _} = live_runtime(source, ["asset.read", "note.read"], true)
    config = config(runtime)
    n = canonical_selector(note, :note, nil)
    d = canonical_selector(document, :document, fragment.fragment_id)

    for forged <- [
          %{n | resource_id: uuid(document.resource_id)},
          %{n | resource_version_id: uuid(document.resource_version_id)},
          %{n | resource_id: Ecto.UUID.generate()},
          %{n | kind: :document, fragment_id: fragment.fragment_id},
          %{d | resource_id: uuid(note.resource_id)},
          %{d | resource_version_id: uuid(note.resource_version_id)},
          %{d | fragment_id: String.duplicate("f", 64)},
          %{d | kind: :note, fragment_id: nil},
          canonical_selector(pending, :document, fragment.fragment_id),
          canonical_selector(foreign_document, :document, foreign_fragment.fragment_id)
        ] do
      actual = resolve(config, session, forged)

      assert actual == {:error, :not_found},
             "forged selector #{inspect(forged)} returned #{inspect(actual)}"
    end

    Fixtures.with_owner(fn ->
      for row <- [note, document] do
        query!(
          MigrationRepo,
          "UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id=$1",
          [row.resource_id]
        )
      end
    end)

    assert resolve(config, session, n) == {:error, :not_found}
    assert resolve(config, session, d) == {:error, :not_found}
  end

  test "resolve port rejects malformed selectors and missing scoped transactions before reads" do
    source = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    raw = canonical_selector(note, :note, nil)
    assert {:ok, typed} = SearchSource.new(raw)
    assert Code.ensure_loaded?(KnowledgeSearchStore)
    assert function_exported?(KnowledgeSearchStore, :resolve, 2)

    assert apply(KnowledgeSearchStore, :resolve, [RequestRepo, typed]) ==
             {:error, Error.new(:invalid)}

    for malformed <- [
          raw,
          nil,
          Map.put(typed, :owner_scope_id, uuid(source.vault_id)),
          Map.delete(typed, :fragment_id),
          %{typed | kind: "note"}
        ] do
      assert apply(KnowledgeSearchStore, :resolve, [RequestRepo, malformed]) ==
               {:error, Error.new(:invalid)}
    end

    assert {:ok, {:error, %Error{code: :invalid}}} =
             RequestRepo.transaction(fn ->
               apply(KnowledgeSearchStore, :resolve, [RequestRepo, typed])
             end)
  end

  test "real authority requires both capabilities for mixed results and authorizes kind before content" do
    source = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    {document, fragment} = KnowledgeFixtures.ready_document!(source)
    project!(source, [note, document])
    {runtime, session, _} = live_runtime(source, [], true)
    config = config(runtime)

    for {capabilities, allowed} <- [
          {[], []},
          {["note.read"], [:note]},
          {["asset.read"], [:document]},
          {["asset.read", "note.read"], [:note, :document, :all]}
        ] do
      capabilities!(source, capabilities)

      for kind <- [:note, :document, :all] do
        case search(config, session, %{kind: kind}) do
          {:ok, %{items: items}} ->
            assert kind in allowed

            assert Enum.sort(Enum.uniq(Enum.map(items, & &1.kind))) ==
                     if(kind == :all, do: [:document, :note], else: [kind])

          {:error, code} ->
            refute kind in allowed
            assert code == :forbidden
        end
      end

      for {kind, selected} <- [
            {:note, canonical_selector(note, :note, nil)},
            {:document, canonical_selector(document, :document, fragment.fragment_id)}
          ] do
        if kind in allowed do
          assert {:ok, _} = resolve(config, session, selected)
        else
          assert resolve(config, session, selected) == {:error, :forbidden}

          assert resolve(config, session, %{selected | resource_id: Ecto.UUID.generate()}) ==
                   {:error, :forbidden}
        end
      end
    end
  end

  test "existing live unlock is required for Note and mixed while Document works locked" do
    source = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    {document, fragment} = KnowledgeFixtures.ready_document!(source)
    project!(source, [note, document])
    {runtime, session, custodian} = live_runtime(source, ["asset.read", "note.read"], false)
    config = config(runtime)
    n = canonical_selector(note, :note, nil)
    d = canonical_selector(document, :document, fragment.fragment_id)
    assert {:ok, %{items: [_]}} = search(config, session, %{kind: :document})
    assert {:ok, _} = resolve(config, session, d)
    assert search(config, session, %{kind: :note}) == {:error, :vault_locked}
    assert search(config, session, %{}) == {:error, :vault_locked}
    assert resolve(config, session, n) == {:error, :vault_locked}

    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "UPDATE core.vaults SET locked=false WHERE id=$1", [source.vault_id])
    end)

    # A DTO hint and a live database unlock cannot manufacture process-local custody.
    hinted = %{session | unlocked?: true}
    assert search(config, hinted, %{kind: :note}) == {:error, :vault_locked}
    activate_unlock(custodian, session)
    assert {:ok, %{items: [_]}} = search(config, session, %{kind: :note})
    assert {:ok, %{items: [_, _]}} = search(config, session, %{})
    assert {:ok, _} = resolve(config, session, n)

    fresh = custodian!()

    assert {:ok, authorization} =
             AuthorizationDependencies.new(%{
               store: IdentityRepository,
               custodian: {KeyCustodian, fresh}
             })

    fresh_config = config(%{runtime | authorization: authorization})
    assert search(fresh_config, hinted, %{}) == {:error, :vault_locked}
    assert {:ok, _} = resolve(fresh_config, hinted, d)
    assert {:ok, revoke} = KeyCustodian.begin_revoke(custodian, %{session_id: session.session_id})
    assert :ok = KeyCustodian.finish_revoke(custodian, revoke)
    assert resolve(config, hinted, n) == {:error, :vault_locked}
  end

  test "live revocation expiry capability and stale epochs are rechecked for every public read" do
    for {statement, code} <- [
          {"UPDATE identity.sessions SET revoked_at=CURRENT_TIMESTAMP WHERE id=$1",
           :unauthenticated},
          {"UPDATE identity.sessions SET expires_at=CURRENT_TIMESTAMP-interval '1 second' WHERE id=$1",
           :unauthenticated},
          {"UPDATE identity.principals SET revoked_at=CURRENT_TIMESTAMP WHERE id=$1", :forbidden},
          {"UPDATE identity.principals SET authorization_epoch=authorization_epoch+1 WHERE id=$1",
           :forbidden},
          {"UPDATE core.vaults SET authorization_epoch=authorization_epoch+1 WHERE id=$1",
           :forbidden},
          {"UPDATE core.vault_members SET revoked_at=CURRENT_TIMESTAMP WHERE principal_id=$1",
           :storage_unavailable},
          {"UPDATE core.principal_capabilities SET revoked_at=CURRENT_TIMESTAMP WHERE principal_id=$1",
           :forbidden}
        ] do
      source = KnowledgeFixtures.source!()
      {document, fragment} = KnowledgeFixtures.ready_document!(source)
      project!(source, [document])
      {runtime, session, _} = live_runtime(source, ["asset.read", "note.read"], true)
      tag = make_ref()
      observer = {ContentObserver, {self(), tag}}
      search_config = config(Map.put(runtime, :knowledge_search, observer))
      resolve_config = config(Map.put(runtime, :knowledge_search_store, observer))
      d = canonical_selector(document, :document, fragment.fragment_id)
      assert {:ok, _} = search(search_config, session, %{kind: :document})
      assert_received {:knowledge_content_callback, ^tag, :search}
      assert {:ok, _} = resolve(resolve_config, session, d)
      assert_received {:knowledge_content_callback, ^tag, :resolve}

      id =
        cond do
          String.contains?(statement, "identity.sessions") -> source.session_id
          String.contains?(statement, "UPDATE core.vaults") -> source.vault_id
          true -> source.principal_id
        end

      Fixtures.with_owner(fn -> query!(MigrationRepo, statement, [id]) end)
      actual_search = search(search_config, session, %{kind: :document})
      actual_resolve = resolve(resolve_config, session, d)
      context = struct!(Singularity.Runtime.SessionContext, Map.from_struct(session))

      legacy =
        Singularity.Runtime.Documents.Read.get(runtime, context, uuid(document.resource_id))

      direct_authority =
        ScopedRepo.transact(
          RequestRepo,
          %{principal_id: context.principal_id, vault_id: context.vault_id},
          fn repo ->
            Singularity.Runtime.Authorize.check(runtime.authorization, repo, context, %{
              vault_id: context.vault_id,
              classification: :private,
              required_capability: "asset.read",
              requires_unlocked?: false,
              principal_authorization_epoch: context.principal_authorization_epoch,
              vault_authorization_epoch: context.vault_authorization_epoch
            })
          end
        )

      diagnostic =
        "mutation=#{statement}, legacy_document=#{inspect(outcome(legacy))}, " <>
          "direct_authority=#{inspect(outcome(direct_authority))}, " <>
          "search=#{inspect(actual_search)}, resolve=#{inspect(actual_resolve)}"

      authority_code = if code == :storage_unavailable, do: :forbidden, else: code
      assert direct_authority == {:error, Error.new(authority_code)}, diagnostic

      assert legacy == {:error, Error.new(code, retryable?: code == :storage_unavailable)},
             diagnostic

      assert actual_search == {:error, code}, diagnostic
      assert actual_resolve == {:error, code}, diagnostic
      refute_received {:knowledge_content_callback, ^tag, _}
    end
  end

  defp live_runtime(source, capabilities, unlocked?) do
    capabilities!(source, capabilities)

    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "UPDATE core.vaults SET locked=$2 WHERE id=$1", [
        source.vault_id,
        not unlocked?
      ])
    end)

    custodian = custodian!()

    session = %Session{
      session_id: uuid(source.session_id),
      account_id: uuid(source.account_id),
      principal_id: uuid(source.principal_id),
      vault_id: uuid(source.vault_id),
      expires_at: DateTime.add(DateTime.utc_now(), 600, :second),
      principal_authorization_epoch: 0,
      vault_authorization_epoch: 0,
      authorization_epoch: 0,
      unlocked?: unlocked?
    }

    if unlocked?, do: activate_unlock(custodian, session)

    assert {:ok, authorization} =
             AuthorizationDependencies.new(%{
               store: IdentityRepository,
               custodian: {KeyCustodian, custodian}
             })

    runtime = %{
      authorization: authorization,
      authorization_lock: AuthorizationLock,
      operation_scope: OperationScope,
      request_repo: RequestRepo,
      scoped_repo: ScopedRepo,
      vault_lock: VaultLock
    }

    {runtime, session, custodian}
  end

  defp custodian! do
    lease_supervisor = start_supervised!({KeyLeaseSupervisor, name: nil}, id: make_ref())

    start_supervised!(
      {KeyCustodian,
       %{
         authorization: CustodyReader,
         clock: CustodyReader,
         context: %{},
         idle_lock: fn _ -> :ok end,
         key_reader: CustodyReader,
         object_key_loader: CustodyReader,
         lease_supervisor: lease_supervisor
       }},
      id: make_ref()
    )
  end

  defp activate_unlock(custodian, session) do
    assert {:ok, pending} =
             KeyCustodian.prepare_unlock(
               custodian,
               session |> Map.from_struct() |> Map.put(:vault_key, :crypto.strong_rand_bytes(32))
             )

    assert :ok = KeyCustodian.activate_unlock(custodian, pending)
  end

  defp capabilities!(source, names) do
    Fixtures.with_owner(fn ->
      for name <- ["asset.read", "note.read"] do
        query!(
          MigrationRepo,
          "INSERT INTO core.capabilities(id,name) VALUES($1,$2) ON CONFLICT(name) DO NOTHING",
          [KnowledgeFixtures.uuid(), name]
        )
      end

      query!(
        MigrationRepo,
        "DELETE FROM core.principal_capabilities WHERE principal_id=$1 AND vault_id=$2",
        [source.principal_id, source.vault_id]
      )

      for name <- names do
        query!(
          MigrationRepo,
          "INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name=$3",
          [source.principal_id, source.vault_id, name]
        )
      end
    end)
  end

  defp project!(source, rows) do
    Fixtures.with_owner(fn ->
      for row <- rows do
        query!(MigrationRepo, "SELECT content.reconcile_search_resource_internal($1,$2)", [
          source.vault_id,
          row.resource_id
        ])
      end
    end)
  end

  defp advance_note!(source, note) do
    version = KnowledgeFixtures.uuid()

    query!(
      MigrationRepo,
      "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',1)",
      [version, note.resource_id, source.vault_id]
    )

    query!(
      MigrationRepo,
      "INSERT INTO content.note_versions(resource_version_id,resource_id,vault_id,classification,title,markdown,created_by_principal_id,parent_version_id,inserted_at) VALUES($1,$2,$3,'private','New Note','new body',$4,$5,CURRENT_TIMESTAMP)",
      [version, note.resource_id, source.vault_id, source.principal_id, note.resource_version_id]
    )

    query!(
      MigrationRepo,
      "UPDATE content.resources SET current_version_id=$2,title='New Note' WHERE id=$1",
      [note.resource_id, version]
    )
  end

  defp advance_document!(document) do
    version = KnowledgeFixtures.uuid()

    query!(
      MigrationRepo,
      "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',1)",
      [version, document.resource_id, document.vault_id]
    )

    KnowledgeFixtures.insert_typed!(%{
      document
      | resource_version_id: version,
        title: "New Document"
    })

    query!(
      MigrationRepo,
      "UPDATE content.resources SET current_version_id=$2,title='New Document' WHERE id=$1",
      [document.resource_id, version]
    )
  end

  defp config(runtime),
    do: %{
      search_knowledge: fn session, params ->
        apply(Singularity.Runtime.Search.Search, :run, [runtime, session, params])
      end,
      resolve_search_source: fn session, selected ->
        apply(Singularity.Runtime.Search.Resolve, :run, [runtime, session, selected])
      end
    }

  defp search(config, session, params),
    do: apply(Api, :search_knowledge, [config, session, params])

  defp resolve(config, session, selected),
    do: apply(Api, :resolve_search_source, [config, session, selected])

  defp selector(result),
    do: Map.take(result, [:kind, :resource_id, :resource_version_id, :fragment_id])

  defp canonical_selector(row, kind, fragment),
    do: %{
      kind: kind,
      resource_id: uuid(row.resource_id),
      resource_version_id: uuid(row.resource_version_id),
      fragment_id: fragment
    }

  defp uuid(id), do: Ecto.UUID.load!(id)
  defp outcome({:error, %Error{code: code}}), do: {:error, code}
  defp outcome({:error, code}) when is_atom(code), do: {:error, code}
  defp outcome({:ok, _}), do: :ok
  defp outcome(:ok), do: :ok
  defp outcome(_), do: :malformed
end
