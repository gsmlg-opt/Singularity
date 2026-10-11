defmodule Singularity.Core.NoteMarkdownSourcesTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.{Error, NoteAttachmentReference, NoteCitationReference, SourceLocator}

  @renderer Singularity.Core.NoteMarkdownSources
  @canonical_limit 1_048_576
  @rendered_limit 16_777_216
  @fragment String.duplicate("a1", 32)

  test "generated fixture UUIDs and references are canonical before renderer calls" do
    assert uuid(1_001) == "00000000-0000-4000-8000-0000000003e9"
    assert uuid(2_001) == "00000000-0000-4000-8000-0000000007d1"

    for number <- [1, 10, 100, 101] do
      attachment = attachment(number)
      citation = citation(number)
      assert {:ok, attachment_reference} = NoteAttachmentReference.new(attachment.reference)
      assert attachment_reference === attachment.reference
      assert {:ok, citation_reference} = NoteCitationReference.new(citation.reference)
      assert citation_reference === citation.reference
    end
  end

  test "empty membership preserves canonical bytes including BOM and every line ending" do
    for markdown <- ["", "plain", "\uFEFFplain\r\nnext\rfinal\n", "# Heading\r\n\r\ntext"] do
      assert {:ok, ^markdown} = render(markdown, empty())
    end

    markdown = String.duplicate("a", @canonical_limit)
    assert {:ok, ^markdown} = render(markdown, empty())
  end

  test "empty membership bypasses appendix admission without changing otherwise valid bytes" do
    for markdown <- rejected_bodies() ++ ["```open", "~~~open\r\n<literal>", "\uFEFF```\n"] do
      assert {:ok, ^markdown} = render(markdown, empty())
    end
  end

  test "canonical input remains UTF-8 NUL-free and bounded for empty and nonempty sets" do
    for descriptors <- [empty(), sources([attachment()])],
        markdown <- [
          nil,
          :markdown,
          [],
          <<255>>,
          "private-canary\0",
          String.duplicate("a", @canonical_limit + 1)
        ] do
      assert_invalid(render(markdown, descriptors))
    end
  end

  test "rendered validation has a separate exact 16 MiB UTF-8 NUL-free ceiling" do
    assert valid_rendered?("")
    assert valid_rendered?(String.duplicate("a", @canonical_limit + 1))
    assert valid_rendered?(String.duplicate("a", @rendered_limit))

    for markdown <- [
          nil,
          [],
          :markdown,
          <<255>>,
          "private-canary\0",
          String.duplicate("a", @rendered_limit + 1)
        ] do
      refute valid_rendered?(markdown)
    end
  end

  test "attachments emit ordinary exact pinned links for all three source kinds" do
    for kind <- [:asset, :note, :document] do
      descriptor = attachment(1, kind: kind, title: "旧 source 界", label: "evidence")
      assert {:ok, output} = render("Original\r\n", sources([descriptor]))
      assert String.starts_with?(output, "Original\r\n\n\n## Sources\n")
      assert output =~ "[旧 source 界](#{descriptor.href})"
      assert output =~ "evidence"
      assert output =~ Atom.to_string(kind)
      assert output =~ descriptor.reference.attachment_id
      assert output =~ descriptor.source.resource_id
      assert output =~ descriptor.source.resource_version_id
    end
  end

  test "the appendix explicitly describes a text-only inventory with no included source files" do
    assert {:ok, output} = render("Body", sources([attachment()]))
    assert output =~ ~r/text.only.*source.*inventory/is
    assert output =~ ~r/no (?:included )?source files|source files (?:are )?not included/i
  end

  test "attachments precede citations and caller order is retained even for descending IDs" do
    attachments = [
      attachment(9, title: "Attachment Nine"),
      attachment(2, title: "Attachment Two")
    ]

    citations = [citation(8, title: "Citation Eight"), citation(1, title: "Citation One")]
    assert {:ok, output} = render("Body", sources(attachments, citations))
    assert_before(output, "Attachment Nine", "Attachment Two")
    assert_before(output, "Attachment Two", "Citation Eight")
    assert_before(output, "Citation Eight", "Citation One")

    assert {:ok, reordered} =
             render("Body", sources(Enum.reverse(attachments), Enum.reverse(citations)))

    assert_before(reordered, "Attachment Two", "Attachment Nine")
    assert_before(reordered, "Citation One", "Citation Eight")
  end

  test "citations have an ordinary main link and a standard footnote containing exact identities" do
    descriptor = citation()
    label = footnote(descriptor)
    assert {:ok, output} = render("Body", sources([], [descriptor]))
    assert output =~ "[Source 1](#{descriptor.href})"
    assert output =~ "[^#{label}]"
    assert output =~ "[^#{label}]:"
    assert output =~ descriptor.reference.citation_id
    assert output =~ descriptor.reference.source_resource_id
    assert output =~ descriptor.reference.source_resource_version_id
    assert output =~ descriptor.reference.fragment_id
    refute output =~ "singularity://"
  end

  test "all four locator forms are human-readable including optional PDF and Markdown ranges" do
    vectors = [
      {%{version: 1, kind: "pdf", page: 7}, ~r/page\s+7/i},
      {%{version: 1, kind: "pdf", page: 7, start_char: 3, end_char: 19},
       ~r/page\s+7.*char.*3.*19/i},
      {%{version: 1, kind: "markdown", heading_path: ["Top", "Nested 界"]}, ~r/Top.*Nested 界/},
      {%{version: 1, kind: "markdown", heading_path: ["Top"], start_line: 2, end_line: 9},
       ~r/Top.*line.*2.*9/i},
      {%{version: 1, kind: "text", start_line: 4, end_line: 11}, ~r/line.*4.*11/i},
      {%{version: 1, kind: "fragment", ordinal: 0}, ~r/fragment.*0/i}
    ]

    for {locator, readable} <- vectors do
      descriptor = citation(1, locator: locator)
      assert {:ok, output} = render("Body", sources([], [descriptor]))
      [_main, definition] = String.split(output, "[^#{footnote(descriptor)}]:", parts: 2)
      assert definition =~ readable
    end
  end

  test "deleted attachments and citations retain exact pins and are explicitly historical" do
    for descriptors <- [
          sources([attachment(1, deleted?: true)]),
          sources([], [citation(1, deleted?: true)])
        ] do
      assert {:ok, output} = render("Body", descriptors)
      assert output =~ ~r/deleted.*historical|historical.*deleted/i
      assert output =~ uuid(1_001)
      assert output =~ uuid(2_001)
    end
  end

  test "titles labels and heading paths preserve Unicode while escaping Markdown HTML and controls" do
    # The minimal emission style escapes ASCII Markdown punctuation with a
    # backslash and displays controls as ASCII \n/\r/\t/\uXXXX tokens.
    title = "界 [brackets](javascript:bad) <img> & `code` *bold* _em_ #heading ! \\\n\r\t\u0001"
    label = "Label [x] <b>\n\t"
    heading = "Heading [x] <script> *em*\n\u007F"

    descriptors =
      sources([attachment(1, title: title, label: label)], [
        citation(2, locator: %{version: 1, kind: "markdown", heading_path: [heading]})
      ])

    assert {:ok, output} = render("Body", descriptors)
    assert output =~ "界"
    assert output =~ "\\[brackets\\]"
    assert output =~ "\\(javascript\\:bad\\)"
    assert output =~ "\\<img\\>"
    assert output =~ "\\&"
    assert output =~ "\\`code\\`"
    assert output =~ "\\*bold\\*"
    assert output =~ "\\_em\\_"
    assert output =~ "\\#heading"
    assert output =~ "\\!"
    assert output =~ "\\n"
    assert output =~ "\\r"
    assert output =~ "\\t"
    assert output =~ "\\u0001"
    assert output =~ "\\u007F"
    assert output =~ "Label \\[x\\] \\<b\\>\\n\\t"
    assert output =~ "Heading \\[x\\] \\<script\\> \\*em\\*\\n\\u007F"
    refute output =~ "<img>"
    refute output =~ "<script>"
    refute output =~ <<1>>
    refute output =~ <<127>>
  end

  test "optional attachment labels remain optional and source titles are not normalized" do
    title = "e\u0301"

    for label <- [nil, "", "é"] do
      descriptor = attachment(1, title: title, label: label)
      assert {:ok, output} = render("Body", sources([descriptor]))
      assert output =~ "[#{title}](#{descriptor.href})"
      if label == "é", do: assert(output =~ "é")
    end
  end

  test "existing footnote collisions are trimmed casefolded and deterministically suffixed" do
    descriptor = citation()
    label = footnote(descriptor)

    body =
      "User [^ #{String.upcase(label)} ].\n\n[^#{label}-1]: Existing one\n[^#{label}-2]: Existing two"

    assert {:ok, output} = render(body, sources([], [descriptor]))
    assert String.starts_with?(output, body <> "\n\n## Sources\n")
    assert output =~ "[^#{label}-3]:"
    assert {:ok, ^output} = render(body, sources([], [descriptor]))
  end

  test "empty descriptors are exact plain maps and never accept aliases missing keys or structs" do
    for descriptors <- [
          nil,
          [],
          %{},
          %{attachments: []},
          %{citations: []},
          %{"attachments" => [], "citations" => []},
          Map.put(empty(), :owner, "private-canary"),
          Map.put(empty(), :__struct__, Error)
        ] do
      assert_invalid(render("Body", descriptors))
    end
  end

  test "collections must be proper lists containing at most 100 exact items" do
    for collection <- [nil, %{}, [attachment() | :tail], [nil], [attachment(), "private-canary"]] do
      assert_invalid(render("Body", sources(collection)))
    end

    for collection <- [nil, %{}, [citation() | :tail], [nil], [citation(), "private-canary"]] do
      assert_invalid(render("Body", sources([], collection)))
    end

    assert {:ok, _} = render("Body", sources(Enum.map(1..100, &attachment/1)))
    assert {:ok, _} = render("Body", sources([], Enum.map(1..100, &citation/1)))
    assert_invalid(render("Body", sources(Enum.map(1..101, &attachment/1))))
    assert_invalid(render("Body", sources([], Enum.map(1..101, &citation/1))))
  end

  test "member IDs are unique within each collection" do
    first = attachment()
    other = attachment(2)

    other = %{
      other
      | reference: %{other.reference | attachment_id: first.reference.attachment_id}
    }

    assert_invalid(render("Body", sources([first, other])))

    first = citation()
    other = citation(2)
    other = %{other | reference: %{other.reference | citation_id: first.reference.citation_id}}
    assert_invalid(render("Body", sources([], [first, other])))
  end

  test "references cannot be substituted across attachment and citation collections" do
    assert_invalid(render("Body", sources([citation()])))
    assert_invalid(render("Body", sources([], [attachment()])))
  end

  test "attachment natural keys are unique despite different member IDs and labels" do
    first = attachment(1, title: "One", label: "first")

    other =
      attachment(2,
        resource_id: first.source.resource_id,
        version_id: first.source.resource_version_id,
        label: "second"
      )

    assert_invalid(render("Body", sources([first, other])))
  end

  test "different pins are distinct and attachment citation overlap counts one target identity" do
    attachments = Enum.map(1..100, &attachment(&1, kind: :document))
    citations = Enum.map(1..100, &citation/1)
    assert {:ok, _} = render("Body", sources(attachments, citations))

    first = attachment()
    second = attachment(2, resource_id: first.source.resource_id)
    assert {:ok, _} = render("Body", sources([first, second]))
  end

  test "the combined target resource version union is limited to 100" do
    attachments = Enum.map(1..100, &attachment/1)
    assert_invalid(render("Body", sources(attachments, [citation(101)])))
  end

  test "each item is an exact plain map with no content owner or authority fields" do
    for {collection, descriptor} <- [{:attachments, attachment()}, {:citations, citation()}] do
      malformed = [
        nil,
        %{},
        Map.delete(descriptor, :href),
        Map.put(descriptor, :__struct__, Error),
        string_keys(descriptor)
      ]

      malformed =
        malformed ++
          Enum.map(
            [:body, :fragment, :text, :owner_id, :vault_id, :authorized?, :private?, :path],
            &Map.put(descriptor, &1, "private-canary")
          )

      for item <- malformed,
          do: assert_invalid(render("Body", Map.put(empty(), collection, [item])))
    end
  end

  test "source metadata is an exact five-key plain map bound to every reference pin and kind" do
    for {collection, descriptor} <- [{:attachments, attachment()}, {:citations, citation()}] do
      malformed = [
        nil,
        %{},
        string_keys(descriptor.source),
        Map.put(descriptor.source, :__struct__, Error)
      ]

      malformed =
        malformed ++ Enum.map(Map.keys(descriptor.source), &Map.delete(descriptor.source, &1))

      malformed =
        malformed ++
          Enum.map(
            [:body, :text, :fragment, :owner_id, :authorized?, :classification],
            &Map.put(descriptor.source, &1, "private-canary")
          )

      malformed =
        malformed ++
          [
            Map.put(descriptor.source, :resource_id, uuid(8_001)),
            Map.put(descriptor.source, :resource_version_id, uuid(8_002)),
            Map.put(descriptor.source, :kind, :note),
            Map.put(descriptor.source, :kind, "asset")
          ]

      for source <- malformed,
          do:
            assert_invalid(
              render("Body", Map.put(empty(), collection, [%{descriptor | source: source}]))
            )
    end
  end

  test "titles must be nonblank UTF-8 NUL-free strings and deletion must be boolean" do
    for title <- [nil, 1, :title, "", " \r\n\t ", <<255>>, "private-canary\0"] do
      assert_invalid(render("Body", sources([attachment(1, title: title)])))
    end

    for deleted <- [nil, 0, "false", :deleted] do
      assert_invalid(render("Body", sources([], [citation(1, deleted?: deleted)])))
    end
  end

  test "reference structs are revalidated exactly without converting Runtime maps or normalizing" do
    descriptor = attachment(1, label: "é")
    reference = descriptor.reference

    for forged <- [
          Map.from_struct(reference),
          Map.delete(reference, :role),
          %{reference | role: "source"},
          %{reference | target_kind: "asset"},
          %{reference | label: "e\u0301"},
          %{reference | attachment_id: String.upcase(uuid(10))},
          Map.put(reference, :text, "private-canary"),
          Map.put(reference, :__struct__, Singularity.Runtime.DTO.NoteAttachment)
        ] do
      assert_invalid(render("Body", sources([%{descriptor | reference: forged}])))
    end

    descriptor = citation()
    reference = descriptor.reference

    for forged <- [
          Map.from_struct(reference),
          Map.delete(reference, :fragment_id),
          %{reference | fragment_id: String.upcase(@fragment)},
          Map.put(reference, :text, "private-canary"),
          Map.put(reference, :__struct__, Singularity.Runtime.DTO.NoteCitation)
        ] do
      assert_invalid(render("Body", sources([], [%{descriptor | reference: forged}])))
    end
  end

  test "nested locators require exact canonical structs fields and bounds" do
    descriptor = citation(1, locator: %{version: 1, kind: "markdown", heading_path: ["é"]})
    locator = descriptor.reference.locator

    for forged <- [
          SourceLocator.to_map(locator),
          Map.put(locator, :text, "private-canary"),
          %{locator | version: 2},
          %{locator | fields: %{heading_path: ["e\u0301"]}},
          %{locator | fields: %{"heading_path" => ["é"]}},
          %{locator | kind: "pdf", fields: %{page: 0}},
          %{locator | kind: "text", fields: %{start_line: 3, end_line: 1}},
          %{locator | kind: "fragment", fields: %{ordinal: -1}}
        ] do
      reference = %{descriptor.reference | locator: forged}
      assert_invalid(render("Body", sources([], [%{descriptor | reference: reference}])))
    end
  end

  test "href grammar binds exact kind resource version and extension" do
    for descriptor <- [
          attachment(),
          attachment(1, kind: :note),
          attachment(1, kind: :document),
          citation()
        ] do
      collection =
        if is_struct(descriptor.reference, NoteCitationReference),
          do: :citations,
          else: :attachments

      for href <- [
            nil,
            "",
            "https://example.com/source",
            "javascript:alert(1)",
            "/" <> descriptor.href,
            "../" <> descriptor.href,
            "sources/../x",
            String.replace(descriptor.href, "/", "\\"),
            String.replace(descriptor.href, "/", "%2F"),
            descriptor.href <> "?download=1",
            descriptor.href <> "#fragment",
            String.replace(descriptor.href, uuid(1_001), uuid(9_001)),
            String.replace(descriptor.href, uuid(2_001), uuid(9_002)),
            descriptor.href <> ".md"
          ] do
        assert_invalid(render("Body", Map.put(empty(), collection, [%{descriptor | href: href}])))
      end
    end
  end

  test "safe prose links containers and single or double backticks preserve exact body prefixes" do
    for body <- [
          "# Heading\n\n- item\n> quote\n[ordinary](https://example.com)\n`code` and ``code``",
          "\uFEFFordinary\rtext",
          "  prose\ttext",
          "a > b"
        ] do
      assert {:ok, output} = render(body, sources([attachment()]))
      assert String.starts_with?(output, body <> "\n\n## Sources\n")
    end
  end

  test "nonempty sources fail closed for every raw HTML class autolinks and literal angle brackets" do
    for body <- rejected_bodies(), do: assert_invalid(render(body, sources([attachment()])))
  end

  test "closed column-zero fences permit literal HTML and keep the appendix outside the fence" do
    for marker <- ["`", "~"],
        ending <- ["\n", "\r\n", "\r"],
        spaces <- ["", " ", "  ", "   "],
        extra <- ["", marker <> marker],
        terminator <- ["", ending] do
      opening = String.duplicate(marker, 4)

      body =
        opening <>
          "lang" <>
          ending <>
          "<script>literal</script>" <>
          ending <> spaces <> opening <> extra <> " \t" <> terminator

      assert {:ok, output} = render(body, sources([attachment()]))
      assert String.starts_with?(output, body <> "\n\n## Sources\n")
    end
  end

  test "proven open fences append exactly the opener length and only a necessary LF" do
    for marker <- ["`", "~"],
        length <- [3, 5],
        ending <- ["\n", "\r\n", "\r"],
        terminator <- ["", ending] do
      opening = String.duplicate(marker, length)
      body = opening <> "lang" <> ending <> "<literal>" <> terminator
      newline = if terminator == "", do: "\n", else: ""
      assert {:ok, output} = render(body, sources([attachment()]))
      assert String.starts_with?(output, body <> newline <> opening <> "\n\n## Sources\n")
    end
  end

  test "shorter wrong content-bearing four-space and tab-prefixed closers remain literal" do
    for marker <- ["`", "~"],
        ending <- ["\n", "\r\n", "\r"],
        terminator <- ["", ending] do
      opening = String.duplicate(marker, 5)
      wrong = if marker == "`", do: "~~~~~", else: "`````"

      for candidate <- [
            String.duplicate(marker, 4),
            wrong,
            opening <> "text",
            "    " <> opening,
            "\t" <> opening
          ] do
        body = opening <> ending <> candidate <> terminator
        newline = if terminator == "", do: "\n", else: ""
        assert {:ok, output} = render(body, sources([attachment()]))
        assert String.starts_with?(output, body <> newline <> opening <> "\n\n## Sources\n")
      end
    end
  end

  test "a closing line cannot simultaneously reopen and nested apparent fences stay literal" do
    for marker <- ["`", "~"] do
      opening = String.duplicate(marker, 3)
      other = if marker == "`", do: "~~~~", else: "````"
      body = opening <> "\n" <> other <> "\n" <> opening
      assert {:ok, output} = render(body, sources([attachment()]))
      assert String.starts_with?(output, body <> "\n\n## Sources\n")
    end
  end

  test "backtick info rejects backticks while tilde info can contain arbitrary remaining text" do
    assert_invalid(render("```info`invalid\ntext", sources([attachment()])))
    body = "~~~ arbitrary ``` <tag>\n<literal>\n~~~"
    assert {:ok, output} = render(body, sources([attachment()]))
    assert String.starts_with?(output, body <> "\n\n## Sources\n")
  end

  test "a canonical 1 MiB body with sources is accepted without truncation" do
    body = String.duplicate("a", @canonical_limit)
    assert {:ok, output} = render(body, sources([attachment()]))
    assert String.starts_with?(output, body <> "\n\n## Sources\n")
    assert byte_size(output) > @canonical_limit
    assert valid_rendered?(output)
  end

  test "the renderer accepts the exact output ceiling and rejects one byte more" do
    assert {:ok, minimal} = render("Body", sources([attachment(1, title: "a")]))
    title_length = @rendered_limit - byte_size(minimal) + 1
    title = String.duplicate("a", title_length)
    assert {:ok, output} = render("Body", sources([attachment(1, title: title)]))
    assert byte_size(output) == @rendered_limit
    assert output =~ "[#{title}]("
    assert_invalid(render("Body", sources([attachment(1, title: title <> "a")])))
  end

  test "output accounting includes the exact appended fence closer" do
    body = "`````\ncontent"
    assert {:ok, minimal} = render(body, sources([attachment(1, title: "a")]))
    title = String.duplicate("a", @rendered_limit - byte_size(minimal) + 1)
    assert {:ok, output} = render(body, sources([attachment(1, title: title)]))
    assert byte_size(output) == @rendered_limit
    assert String.starts_with?(output, body <> "\n`````\n\n## Sources\n")
    assert_invalid(render(body, sources([attachment(1, title: title <> "a")])))
  end

  test "huge raw titles and aggregate retained title payloads fail without truncation" do
    assert_invalid(
      render("Body", sources([attachment(1, title: String.duplicate("a", @rendered_limit + 1))]))
    )

    descriptors =
      Enum.map(1..3, &attachment(&1, title: String.duplicate("a", div(@rendered_limit, 2))))

    assert_invalid(render("Body", sources(descriptors)))
  end

  test "escape expansion is included in the budget before returning a partial appendix" do
    title = String.duplicate("<", div(@rendered_limit, 2) + 1)
    assert_invalid(render("Body", sources([attachment(1, title: title)])))
    title = String.duplicate("\u0001", div(@rendered_limit, 6) + 1)
    assert_invalid(render("Body", sources([attachment(1, title: title)])))
  end

  test "maximum escaped heading vectors fit the separate rendered budget without truncation" do
    heading = String.duplicate("[", 255)
    locator = %{version: 1, kind: "markdown", heading_path: List.duplicate(heading, 64)}
    citations = Enum.map(1..100, &citation(&1, locator: locator))
    assert {:ok, output} = render(String.duplicate("a", @canonical_limit), sources([], citations))
    assert valid_rendered?(output)
    assert byte_size(output) < @rendered_limit
    assert count(output, String.duplicate("\\[", 255)) == 100 * 64
    assert count(output, ~r/^\[\^singularity-source-[^\]]+\]:/m) == 100
  end

  describe "portable source rendering is additive to the frozen text-only contract" do
    test "empty membership retains canonical bytes without inventing files" do
      for body <- ["", "\uFEFFbody\r\nnext\r", "<script>literal</script>", "```open"] do
        assert {:ok, ^body} = render_portable(body, empty(), %{})
      end
    end

    test "live exact pins render ordinary relative links for every source kind" do
      for kind <- [:asset, :note, :document] do
        source = attachment(1, kind: kind, title: "Same title 界")
        files = portable_files([source])
        %{path: path} = Map.fetch!(files, portable_key(source))

        relative =
          if kind == :note, do: String.replace_prefix(path, "notes/", ""), else: "../" <> path

        assert {:ok, output} = render_portable("Original\r\n", sources([source]), files)
        assert String.starts_with?(output, "Original\r\n\n\n## Sources\n")
        assert output =~ "[Same title 界](#{relative})"
        assert output =~ source.source.resource_version_id
        refute output =~ "no source files included"
        refute output =~ "singularity://"
        refute output =~ "](sources/"

        assert {:ok, legacy} = render("Original\r\n", sources([source]))
        assert legacy =~ "Text-only source inventory; no source files included."
        assert legacy =~ "](#{source.href})"
      end
    end

    test "two historical versions sharing one resource and title never follow a newer pin" do
      first = citation(1, title: "Same title", locator: %{version: 1, kind: "pdf", page: 3})

      second =
        citation(2,
          resource_id: first.source.resource_id,
          title: "Same title",
          locator: %{version: 1, kind: "pdf", page: 9}
        )

      files = portable_files([first, second])
      assert {:ok, output} = render_portable("Body", sources([], [first, second]), files)

      for descriptor <- [first, second] do
        assert output =~ "](../#{files[portable_key(descriptor)].path})"
        assert output =~ "[^#{footnote(descriptor)}]:"
        assert output =~ descriptor.source.resource_version_id
        assert output =~ descriptor.reference.fragment_id
        [_before, definition] = String.split(output, "[^#{footnote(descriptor)}]:", parts: 2)
        assert definition =~ descriptor.source.title
      end

      assert output =~ ~r/PDF page 3/
      assert output =~ ~r/PDF page 9/
      assert count(output, "[Same title](") == 2
    end

    test "deleted unavailable and unselected metadata show reasons and locators without file links" do
      for {availability, deleted, reason} <- [
            {"metadata_only_deleted", true, "Deleted source"},
            {"metadata_only_unavailable", false, "Source unavailable"},
            {"metadata_only_unselected", false, "Body not selected"}
          ] do
        source = citation(1, deleted?: deleted, locator: %{version: 1, kind: "pdf", page: 7})

        files = %{
          portable_key(source) => %{availability: availability, path: nil, reason: reason}
        }

        assert {:ok, output} = render_portable("Body", sources([], [source]), files)
        assert output =~ reason
        assert output =~ "Source 1"
        assert output =~ source.source.resource_id
        assert output =~ source.source.resource_version_id
        assert output =~ ~r/PDF page 7/
        assert output =~ "[^#{footnote(source)}]:"
        [_before, definition] = String.split(output, "[^#{footnote(source)}]:", parts: 2)
        assert definition =~ reason
        assert definition =~ "Source 1"
        refute output =~ "]("
        refute output =~ "documents/originals/"
        refute output =~ "sources/document-"
      end
    end

    test "missing live mappings or wrong exact pin paths fail rather than becoming unavailable" do
      source = citation()
      key = portable_key(source)
      files = portable_files([source])
      value = files[key]

      assert_invalid(render_portable("Body", sources([], [source]), %{}))

      for path <- [
            nil,
            "../" <> value.path,
            "/" <> value.path,
            String.replace(value.path, source.source.resource_version_id, uuid(9_002)),
            String.replace(value.path, source.source.resource_id, uuid(9_001)),
            "assets/#{source.source.resource_id}--#{source.source.resource_version_id}.bin",
            String.upcase(value.path),
            "documents/originals/Title [x](bad).pdf",
            value.path <> "?download=1",
            value.path <> "\0",
            %{symlink: value.path}
          ] do
        assert_invalid(
          render_portable("Body", sources([], [source]), %{key => %{value | path: path}})
        )
      end

      other_key = {:document, source.source.resource_id, uuid(9_002)}
      assert_invalid(render_portable("Body", sources([], [source]), %{other_key => value}))
    end

    test "file availability records are exact bounded values without caller authority" do
      source = citation(1, deleted?: true)
      key = portable_key(source)
      metadata = %{availability: "metadata_only_deleted", path: nil, reason: "Deleted source"}

      for value <- [
            nil,
            %{},
            Map.put(metadata, :__struct__, Error),
            Map.put(metadata, :authorized?, true),
            Map.put(metadata, :storage_ref, "private-canary"),
            %{metadata | availability: "included"},
            %{metadata | availability: "unknown"},
            %{metadata | path: portable_path(source)},
            %{metadata | reason: nil},
            %{metadata | reason: ""},
            %{metadata | reason: " \t"},
            %{metadata | reason: "private-canary\0"},
            %{metadata | reason: <<255>>},
            %{metadata | reason: String.duplicate("x", 256)}
          ] do
        assert_invalid(render_portable("Body", sources([], [source]), %{key => value}))
      end

      live = citation()
      live_files = portable_files([live])
      included = %{live_files[portable_key(live)] | reason: "pretend unavailable"}

      assert_invalid(
        render_portable("Body", sources([], [live]), %{portable_key(live) => included})
      )

      assert_invalid(render_portable("Body", sources([], [source]), portable_files([source])))

      for invalid <- [nil, [], %{__struct__: Error}] do
        assert_invalid(render_portable("Body", sources([], [source]), invalid))
      end
    end

    test "portable labels headings and reasons escape hostile Markdown HTML and controls" do
      attachment = attachment(1, title: "界 [x](javascript:bad) <img>\n\t", label: "[label](x)")

      citation =
        citation(2, locator: %{version: 1, kind: "markdown", heading_path: ["<heading> [x]"]})

      files = portable_files([attachment, citation])
      assert {:ok, output} = render_portable("Body", sources([attachment], [citation]), files)
      assert output =~ "界 \\[x\\]\\(javascript\\:bad\\) \\<img\\>\\n\\t"
      assert output =~ "\\[label\\]\\(x\\)"
      assert output =~ "\\<heading\\> \\[x\\]"
      refute output =~ "<img>"

      metadata = %{
        portable_key(citation) => %{
          availability: "metadata_only_unavailable",
          path: nil,
          reason: "Missing [source](javascript:bad) <b>\n"
        }
      }

      assert {:ok, output} = render_portable("Body", sources([], [citation]), metadata)
      assert output =~ "Missing \\[source\\]\\(javascript\\:bad\\) \\<b\\>\\n"
      refute output =~ "](javascript:"
    end

    test "portable footnotes avoid existing labels and open fences without altering original body" do
      source = citation()
      label = footnote(source)

      body =
        "User [^#{String.upcase(label)}].\r\n\r\n[^#{label}-1]: existing\r\n```text\n<literal>"

      files = portable_files([source])
      assert {:ok, output} = render_portable(body, sources([], [source]), files)
      assert String.starts_with?(output, body <> "\n```\n\n## Sources\n")
      assert output =~ "[^#{label}-2]:"
      assert {:ok, ^output} = render_portable(body, sources([], [source]), files)
    end

    test "portable rendering preserves typed-source and canonical body limits" do
      source = attachment()
      files = portable_files([source])

      for body <-
            [<<255>>, "canary\0", String.duplicate("a", @canonical_limit + 1)] ++
              rejected_bodies() do
        assert_invalid(render_portable(body, sources([source]), files))
      end

      body = String.duplicate("a", @canonical_limit)
      assert {:ok, output} = render_portable(body, sources([source]), files)
      assert String.starts_with?(output, body)
      assert valid_rendered?(output)

      forged = %{source | reference: Map.put(source.reference, :authorized?, true)}
      assert_invalid(render_portable("Body", sources([forged]), files))
      assert_invalid(render_portable("Body", sources([source, source]), files))
      too_many = Enum.map(1..101, &attachment/1)
      assert_invalid(render_portable("Body", sources(too_many), portable_files(too_many)))
    end
  end

  defp render_portable(markdown, descriptors, files) do
    assert Code.ensure_loaded?(@renderer), "missing Core Markdown source renderer"

    assert function_exported?(@renderer, :render_portable, 3),
           "missing render_portable/3 contract"

    apply(@renderer, :render_portable, [markdown, descriptors, files])
  end

  defp portable_key(descriptor),
    do:
      {descriptor.source.kind, descriptor.source.resource_id,
       descriptor.source.resource_version_id}

  defp portable_path(descriptor) do
    basename = descriptor.source.resource_id <> "--" <> descriptor.source.resource_version_id

    case descriptor.source.kind do
      :asset -> "assets/#{basename}.bin"
      :note -> "notes/#{basename}.md"
      :document -> "documents/originals/#{basename}.pdf"
    end
  end

  defp portable_files(descriptors) do
    Map.new(descriptors, fn descriptor ->
      {portable_key(descriptor),
       %{availability: "included", path: portable_path(descriptor), reason: nil}}
    end)
  end

  defp render(markdown, descriptors) do
    assert Code.ensure_loaded?(@renderer), "missing Core Markdown source renderer"
    assert function_exported?(@renderer, :render, 2), "missing render/2 contract"
    apply(@renderer, :render, [markdown, descriptors])
  end

  defp valid_rendered?(markdown) do
    assert Code.ensure_loaded?(@renderer), "missing Core Markdown source renderer"

    assert function_exported?(@renderer, :valid_rendered?, 1),
           "missing valid_rendered?/1 contract"

    apply(@renderer, :valid_rendered?, [markdown])
  end

  defp empty, do: %{attachments: [], citations: []}

  defp sources(attachments, citations \\ []),
    do: %{attachments: attachments, citations: citations}

  defp assert_invalid(result), do: assert(result == {:error, Error.new(:invalid)})
  defp footnote(descriptor), do: "singularity-source-" <> descriptor.reference.citation_id

  defp attachment(number \\ 1, opts \\ []) do
    kind = Keyword.get(opts, :kind, :asset)
    resource = Keyword.get(opts, :resource_id, uuid(1_000 + number))
    version = Keyword.get(opts, :version_id, uuid(2_000 + number))

    assert {:ok, reference} =
             NoteAttachmentReference.new(%{
               attachment_id: uuid(number),
               target_resource_id: resource,
               target_resource_version_id: version,
               target_kind: kind,
               label: Keyword.get(opts, :label)
             })

    descriptor(reference, kind, resource, version, number, opts)
  end

  defp citation(number \\ 1, opts \\ []) do
    resource = Keyword.get(opts, :resource_id, uuid(1_000 + number))
    version = Keyword.get(opts, :version_id, uuid(2_000 + number))
    locator = Keyword.get(opts, :locator, %{version: 1, kind: "fragment", ordinal: number - 1})

    assert {:ok, reference} =
             NoteCitationReference.new(%{
               citation_id: uuid(number),
               source_resource_id: resource,
               source_resource_version_id: version,
               fragment_id: @fragment,
               locator: locator
             })

    descriptor(reference, :document, resource, version, number, opts)
  end

  defp descriptor(reference, kind, resource, version, number, opts) do
    extension = %{asset: "bin", note: "md", document: "txt"}[kind]

    %{
      reference: reference,
      source: %{
        kind: kind,
        resource_id: resource,
        resource_version_id: version,
        title: Keyword.get(opts, :title, "Source #{number}"),
        deleted?: Keyword.get(opts, :deleted?, false)
      },
      href: "sources/#{kind}-#{resource}-#{version}.#{extension}"
    }
  end

  defp uuid(number),
    do:
      "00000000-0000-4000-8000-" <>
        (number |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(12, "0"))

  defp string_keys(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)

  defp assert_before(output, first, second) do
    {first_position, _} = :binary.match(output, first)
    {second_position, _} = :binary.match(output, second)
    assert first_position < second_position
  end

  defp count(output, %Regex{} = pattern), do: pattern |> Regex.scan(output) |> length()
  defp count(output, text), do: length(:binary.matches(output, text))

  defp rejected_bodies do
    [
      "<script>alert(1)</script>",
      "<pre>literal</pre>",
      "<style>x</style>",
      "<textarea>x</textarea>",
      "<!-- comment -->",
      "<?instruction?>",
      "<!DOCTYPE html>",
      "<![CDATA[text]]>",
      "<div>block</div>",
      "<custom-tag>closed</custom-tag>",
      "</tag>",
      "<https://example.com>",
      "<user@example.com>",
      "a < b",
      "`<inline>`",
      " ```\nindented",
      "  ~~~\nindented",
      "   ```\nindented",
      "    ~~~\nindented",
      "\t```\nindented",
      "> ```\nquote",
      "- ~~~\nlist",
      "text ``` inline",
      "text ~~~ inline",
      "\\``` escaped",
      "\\~~~ escaped",
      "\uFEFF```\nBOM fence",
      "\uFEFF~~~\nBOM fence"
    ]
  end
end
