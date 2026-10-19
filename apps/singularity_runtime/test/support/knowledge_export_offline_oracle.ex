defmodule Singularity.Runtime.KnowledgeExportOfflineOracle do
  @moduledoc false
  import ExUnit.Assertions

  # Deliberately literal: this consumer does not share the producer's schema,
  # renderer, repositories, source resolver or validation implementation.
  @top ~w(format version selection resources versions fragments tags tag_assignments relationships attachments citations files)
  @fields %{
    "resources" => ~w(id kind title current_version_id deleted_at selection_reason),
    "versions" =>
      ~w(resource_id version_id revision kind inserted_at availability body_path original_path extracted_path body_digest original_digest original_byte_size extracted_digest media_type state extraction_adapter extraction_format parent_version_id merge_parent_version_id),
    "fragments" =>
      ~w(id resource_id version_id ordinal digest locator extracted_path start_byte byte_size),
    "tags" => ~w(id display_value normalized_key),
    "tag_assignments" => ~w(resource_id tag_id),
    "relationships" => ~w(id source_resource_id target_resource_id target_version_id type),
    "attachments" =>
      ~w(note_resource_id note_version_id id ordinal target_resource_id target_version_id target_kind role label),
    "citations" =>
      ~w(note_resource_id note_version_id id ordinal source_resource_id source_version_id fragment_id locator),
    "files" => ~w(path media_type byte_size sha256)
  }
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @digest ~r/\A[0-9a-f]{64}\z/

  def verify!(root, expected) do
    manifest_bytes = File.read!(Path.join(root, "manifest.json"))
    ordered_schema!(Jason.decode!(manifest_bytes, objects: :ordered_objects))
    manifest = Jason.decode!(manifest_bytes)
    schema!(manifest, expected.include_tombstones)
    inventory!(root, manifest, expected.entries, manifest_bytes)
    references!(manifest)
    selection!(manifest, expected)
    originals!(root, manifest, expected)
    fragments!(root, manifest, expected.fragments)
    markdown!(root, manifest, expected.notes, Map.get(expected, :rendered_snippets, %{}))

    for body <- expected.absent_bodies, path <- inventory(root) do
      refute String.contains?(File.read!(Path.join(root, path)), body), "absent body boundary"
    end

    manifest
  end

  def inventory(root), do: walk(root, "") |> Enum.sort()
  def sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp ordered_schema!(%Jason.OrderedObject{values: fields} = object) do
    assert Enum.map(fields, &elem(&1, 0)) == @top, "manifest key ordering boundary"
    ordered_unique!(object)

    for {collection, keys} <- @fields do
      for %Jason.OrderedObject{values: fields} <- Map.fetch!(Map.new(object.values), collection) do
        assert Enum.map(fields, &elem(&1, 0)) == keys, "record key ordering boundary"
      end
    end
  end

  defp ordered_unique!(%Jason.OrderedObject{values: fields}) do
    assert length(fields) == MapSet.size(MapSet.new(fields, &elem(&1, 0))),
           "duplicate JSON key boundary"

    Enum.each(fields, fn {_, value} -> ordered_unique!(value) end)
  end

  defp ordered_unique!(values) when is_list(values), do: Enum.each(values, &ordered_unique!/1)
  defp ordered_unique!(_), do: :ok

  defp schema!(m, tombstones) do
    assert Enum.sort(Map.keys(m)) == Enum.sort(@top), "manifest schema boundary"
    assert m["format"] == "singularity.portable-knowledge"
    assert m["version"] === 1

    assert m["selection"] == %{
             "mode" => "live_heads_with_source_closure",
             "include_tombstones" => tombstones
           }

    for {collection, keys} <- @fields do
      assert is_list(m[collection]), "array schema boundary"

      for row <- m[collection] do
        assert is_map(row) and Enum.sort(Map.keys(row)) == Enum.sort(keys),
               "record schema boundary"
      end

      identities = Enum.map(m[collection], &identity(collection, &1))
      assert identities == Enum.sort(identities), "record ordering boundary"

      assert length(identities) == MapSet.size(MapSet.new(identities)),
             "duplicate identity boundary"
    end

    for row <- m["versions"] do
      assert row["kind"] in ~w(note document asset)
      assert row["availability"] in ~w(included metadata_only_deleted metadata_only_unselected)
      assert is_integer(row["revision"]) and row["revision"] >= 0
      assert row["inserted_at"] =~ ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z\z/

      for key <- ~w(body_digest original_digest extracted_digest),
          not is_nil(row[key]),
          do: assert(row[key] =~ @digest)

      if row["availability"] != "included" do
        assert Enum.all?(~w(body_path original_path extracted_path), &is_nil(row[&1])),
               "metadata file boundary"
      end

      if row["kind"] != "note",
        do: assert(is_nil(row["parent_version_id"]) and is_nil(row["merge_parent_version_id"]))

      if row["kind"] == "note" do
        assert Enum.all?(
                 ~w(original_path extracted_path original_digest original_byte_size extracted_digest media_type state extraction_adapter extraction_format),
                 &is_nil(row[&1])
               )
      end

      if row["kind"] == "asset",
        do:
          assert(
            Enum.all?(
              ~w(body_path extracted_path body_digest extracted_digest state extraction_adapter extraction_format),
              &is_nil(row[&1])
            )
          )

      if row["kind"] == "document" and row["availability"] == "included" do
        assert row["state"] in ~w(pending extracting ready failed unsupported)

        if row["state"] != "ready",
          do: assert(is_nil(row["extracted_path"]) and is_nil(row["extracted_digest"]))

        if row["state"] == "pending",
          do: assert(is_nil(row["extraction_adapter"]) and is_nil(row["extraction_format"]))
      end

      if row["availability"] == "included" do
        base = row["resource_id"] <> "--" <> row["version_id"]

        case row["kind"] do
          "note" ->
            assert row["body_path"] == "notes/" <> base <> ".md", "version path boundary"

          "asset" ->
            assert row["original_path"] == "assets/" <> base <> ".bin", "version path boundary"

          "document" ->
            extension =
              Map.fetch!(
                %{"application/pdf" => "pdf", "text/markdown" => "md", "text/plain" => "txt"},
                row["media_type"]
              )

            assert row["original_path"] == "documents/originals/" <> base <> "." <> extension,
                   "version path boundary"

            if row["state"] == "ready",
              do:
                assert(
                  row["extracted_path"] == "documents/extracted/" <> base <> ".txt",
                  "version path boundary"
                )
        end
      end
    end
  end

  defp inventory!(root, m, entries, manifest_bytes) do
    listed = Map.new(m["files"], &{&1["path"], &1})
    refute Map.has_key?(listed, "manifest.json")

    assert inventory(root) == Enum.sort(["manifest.json" | Map.keys(listed)]),
           "file inventory boundary"

    assert MapSet.new(Map.keys(entries)) == MapSet.new(["manifest.json" | Map.keys(listed)]),
           "entry inventory boundary"

    for {path, row} <- listed do
      safe!(path)
      assert row == entries[path], "entry descriptor boundary"
      bytes = File.read!(Path.join(root, path))
      assert row["byte_size"] == byte_size(bytes), "file size boundary"
      assert row["sha256"] == sha(bytes), "file hash boundary"
    end

    assert entries["manifest.json"] == %{
             "path" => "manifest.json",
             "media_type" => "application/json",
             "byte_size" => byte_size(manifest_bytes),
             "sha256" => sha(manifest_bytes)
           },
           "manifest descriptor boundary"

    declared =
      for v <- m["versions"],
          key <- ~w(body_path original_path extracted_path),
          path = v[key],
          not is_nil(path),
          do: path

    assert MapSet.new(declared) == MapSet.new(Map.keys(listed)), "declared inventory boundary"
  end

  defp references!(m) do
    resources = Map.new(m["resources"], &{&1["id"], &1})
    versions = Map.new(m["versions"], &{{&1["resource_id"], &1["version_id"]}, &1})
    fragments = Map.new(m["fragments"], &{{&1["resource_id"], &1["version_id"], &1["id"]}, &1})
    tags = MapSet.new(m["tags"], & &1["id"])
    for r <- m["resources"], do: assert(r["id"] =~ @uuid)

    for v <- m["versions"] do
      assert Map.has_key?(resources, v["resource_id"]), "resource reference boundary"
      assert v["version_id"] =~ @uuid

      for key <- ~w(parent_version_id merge_parent_version_id),
          id = v[key],
          not is_nil(id),
          do:
            assert(Map.has_key?(versions, {v["resource_id"], id}), "ancestor reference boundary")

      for key <- ~w(body_path original_path extracted_path), path = v[key], not is_nil(path) do
        safe!(path)

        assert String.contains?(path, v["resource_id"] <> "--" <> v["version_id"]),
               "version path boundary"
      end
    end

    for f <- m["fragments"],
        do:
          assert(
            Map.has_key?(versions, {f["resource_id"], f["version_id"]}),
            "fragment version boundary"
          )

    for a <- m["attachments"] do
      assert Map.has_key?(versions, {a["note_resource_id"], a["note_version_id"]}),
             "attachment note boundary"

      assert Map.has_key?(versions, {a["target_resource_id"], a["target_version_id"]}),
             "attachment source boundary"

      assert versions[{a["target_resource_id"], a["target_version_id"]}]["kind"] ==
               a["target_kind"]
    end

    for c <- m["citations"] do
      assert Map.has_key?(versions, {c["note_resource_id"], c["note_version_id"]}),
             "citation note boundary"

      assert Map.has_key?(
               fragments,
               {c["source_resource_id"], c["source_version_id"], c["fragment_id"]}
             ),
             "citation fragment boundary"

      assert fragments[{c["source_resource_id"], c["source_version_id"], c["fragment_id"]}][
               "locator"
             ] == c["locator"]
    end

    for a <- m["tag_assignments"],
        do:
          assert(
            Map.has_key?(resources, a["resource_id"]) and MapSet.member?(tags, a["tag_id"]),
            "tag reference boundary"
          )

    for r <- m["relationships"] do
      assert Map.has_key?(resources, r["source_resource_id"]) and
               Map.has_key?(resources, r["target_resource_id"]),
             "relationship resource boundary"

      if r["target_version_id"],
        do:
          assert(
            Map.has_key?(versions, {r["target_resource_id"], r["target_version_id"]}),
            "relationship version boundary"
          )
    end
  end

  defp selection!(m, e) do
    assert MapSet.new(m["versions"], & &1["version_id"]) ==
             MapSet.union(e.included_versions, e.metadata_versions),
           "exact version selection boundary"

    assert MapSet.new(m["resources"], & &1["id"]) == e.resource_ids,
           "exact resource selection boundary"

    assert MapSet.new(m["tags"], & &1["id"]) == MapSet.new(e.tags), "exact tag selection boundary"

    assert MapSet.new(m["relationships"], & &1["id"]) == MapSet.new(e.relationships),
           "exact relationship selection boundary"

    if tags = e[:tag_records],
      do: assert(MapSet.new(m["tags"]) == MapSet.new(tags), "exact tag bytes boundary")

    if relationships = e[:relationship_records],
      do:
        assert(
          MapSet.new(m["relationships"]) == MapSet.new(relationships),
          "exact relationship pins boundary"
        )

    attachments =
      for {note_version, members} <- e.memberships, a <- members.attachments do
        {note_version, a.attachment_id, a.target_resource_id, a.target_resource_version_id,
         to_string(a.target_kind), to_string(Map.get(a, :role, :source)), a.label}
      end

    actual_attachments =
      Enum.map(
        m["attachments"],
        &{&1["note_version_id"], &1["id"], &1["target_resource_id"], &1["target_version_id"],
         &1["target_kind"], &1["role"], &1["label"]}
      )

    assert MapSet.new(actual_attachments) == MapSet.new(attachments),
           "exact attachment membership boundary"

    citations =
      for {note_version, members} <- e.memberships, c <- members.citations do
        {note_version, c.citation_id, c.source_resource_id, c.source_resource_version_id,
         c.fragment_id, locator(c.locator)}
      end

    actual_citations =
      Enum.map(
        m["citations"],
        &{&1["note_version_id"], &1["id"], &1["source_resource_id"], &1["source_version_id"],
         &1["fragment_id"], &1["locator"]}
      )

    assert MapSet.new(actual_citations) == MapSet.new(citations),
           "exact citation membership boundary"

    for v <- m["versions"] do
      assert v["availability"] == "included" ==
               MapSet.member?(e.included_versions, v["version_id"]),
             "availability selection boundary"
    end

    for {resource, version} <- e.deleted_sources do
      assert Enum.any?(
               m["versions"],
               &(&1["resource_id"] == resource and &1["version_id"] == version and
                   &1["availability"] == "metadata_only_deleted")
             )
    end

    for {resource, version} <- e.historical_pins do
      assert Enum.any?(
               m["versions"],
               &(&1["resource_id"] == resource and &1["version_id"] == version and
                   &1["availability"] == "included")
             )
    end

    pins =
      Enum.filter(m["versions"], &({&1["resource_id"], &1["version_id"]} in e.historical_pins))

    assert length(Enum.uniq(Enum.map(pins, & &1["original_path"]))) == length(e.historical_pins)
  end

  defp locator(%{version: version, kind: kind, fields: fields}),
    do:
      fields
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.merge(%{"version" => version, "kind" => kind})

  defp locator(value), do: value

  defp originals!(root, m, e) do
    for {version, key} <- Map.merge(e.original_inputs, e.asset_inputs) do
      row = Enum.find(m["versions"], &(&1["version_id"] == version))
      input = Map.fetch!(e.inputs, key)

      assert row["original_digest"] == input.sha256 and
               row["original_byte_size"] == input.byte_size

      assert Enum.find(m["files"], &(&1["path"] == row["original_path"]))["media_type"] ==
               input.media_type

      assert File.read!(Path.join(root, row["original_path"])) == input.bytes,
             "original bytes boundary"
    end
  end

  defp fragments!(root, m, expected) do
    actual_versions =
      m["fragments"] |> Enum.filter(& &1["extracted_path"]) |> MapSet.new(& &1["version_id"])

    assert actual_versions == MapSet.new(Map.keys(expected)), "exact fragment selection boundary"

    for {version, texts} <- expected do
      rows = Enum.filter(m["fragments"], &(&1["version_id"] == version))
      assert Enum.map(rows, & &1["ordinal"]) == Enum.to_list(0..(length(texts) - 1))
      version_row = Enum.find(m["versions"], &(&1["version_id"] == version))
      bytes = File.read!(Path.join(root, version_row["extracted_path"]))
      assert bytes == Enum.join(texts), "fragment concatenation boundary"
      assert version_row["extracted_digest"] == sha(bytes)

      Enum.zip(rows, texts)
      |> Enum.reduce(0, fn {row, text}, offset ->
        assert row["start_byte"] == offset and row["byte_size"] == byte_size(text),
               "fragment byte offset boundary"

        assert binary_part(bytes, offset, byte_size(text)) == text
        assert row["digest"] == sha(text)
        offset + byte_size(text)
      end)
    end
  end

  defp markdown!(root, m, expected, snippets) do
    for {version, canonical} <- expected do
      row = Enum.find(m["versions"], &(&1["version_id"] == version))
      path = row["body_path"]
      body = File.read!(Path.join(root, path))
      assert row["body_digest"] == sha(canonical)
      assert String.starts_with?(body, canonical), "canonical Markdown boundary"
      generated = binary_part(body, byte_size(canonical), byte_size(body) - byte_size(canonical))

      for snippet <- Map.get(snippets, version, []),
          do: assert(String.contains?(body, snippet), "literal rendered Markdown boundary")

      refs = Enum.filter(m["attachments"] ++ m["citations"], &(&1["note_version_id"] == version))

      if refs != [] do
        assert String.contains?(
                 body,
                 "\n\n## Sources\n\nPortable source inventory; links identify included exact-version files.\n\n"
               ),
               "source section boundary"

        for ref <- refs do
          resource = ref["target_resource_id"] || ref["source_resource_id"]
          pin = ref["target_version_id"] || ref["source_version_id"]

          assert String.contains?(body, "; resource: " <> resource <> "; version: " <> pin),
                 "rendered pin boundary"

          assert String.contains?(body, ref["id"]), "rendered reference boundary"
        end
      else
        assert body == canonical
      end

      for c <- Enum.filter(m["citations"], &(&1["note_version_id"] == version)) do
        label = "singularity-source-" <> c["id"]

        assert String.contains?(body, "[^" <> label <> "]; citation: " <> c["id"]),
               "footnote use boundary"

        assert String.contains?(body, "[^" <> label <> "]: "), "footnote definition boundary"
        assert String.contains?(body, "; fragment: " <> c["fragment_id"])
        generated_citation!(generated, c)
      end

      refute String.contains?(body, ["singularity://", "singularity-source://"]),
             "proprietary link boundary"

      for [_, href] <- Regex.scan(~r/(?<!\\)\]\(([^)\s]+)\)/u, body) do
        if URI.parse(href).scheme in ["http", "https", "mailto"] do
          :ok
        else
          assert Path.type(href) == :relative and not String.contains?(href, ["\\", <<0>>]),
                 "relative link boundary"

          destination = Path.expand(href, Path.dirname(Path.join(root, path)))

          assert String.starts_with?(destination, Path.expand(root) <> "/"),
                 "relative link boundary"

          assert File.regular?(destination), "relative link boundary"
        end
      end

      for reference <- refs, do: generated_source!(generated, m, reference)
    end
  end

  # These checks bind one generated inventory record to one expected immutable
  # membership. Canonical user Markdown is deliberately outside this parser.
  # selection!/2 already equates memberships/locators with independent inputs;
  # references!/1 already binds each citation to its exact fragment/locator.
  defp generated_source!(generated, manifest, reference) do
    citation? = Map.has_key?(reference, "source_resource_id")
    type = if citation?, do: "citation", else: "attachment"
    resource = reference["source_resource_id"] || reference["target_resource_id"]
    version = reference["source_version_id"] || reference["target_version_id"]

    target =
      Enum.find(manifest["versions"], fn row ->
        row["resource_id"] == resource and row["version_id"] == version
      end)

    assert target != nil, "exact source link boundary"

    records =
      generated
      |> String.split("\n")
      |> Enum.filter(fn line ->
        String.starts_with?(line, "- ") and
          String.contains?(line, "; " <> type <> ": " <> reference["id"])
      end)

    assert [record] = records, "exact source link boundary"

    assert String.contains?(
             record,
             " — " <> target["kind"] <> "; resource: " <> resource <> "; version: " <> version
           ),
           "exact source link boundary"

    hrefs = Regex.scan(~r/(?<!\\)\]\(([^)\s]+)\)/u, record, capture: :all_but_first)

    if target["availability"] == "included" do
      assert hrefs == [[source_href(target)]], "exact source link boundary"
    else
      assert hrefs == [], "exact source link boundary"
    end
  end

  defp source_href(%{"kind" => kind} = version) do
    basename = version["resource_id"] <> "--" <> version["version_id"]

    case kind do
      "note" ->
        basename <> ".md"

      "asset" ->
        "../assets/" <> basename <> ".bin"

      "document" ->
        if version["state"] == "ready" do
          "../documents/extracted/" <> basename <> ".txt"
        else
          extension =
            Map.fetch!(
              %{"application/pdf" => "pdf", "text/markdown" => "md", "text/plain" => "txt"},
              version["media_type"]
            )

          "../documents/originals/" <> basename <> "." <> extension
        end
    end
  end

  defp generated_citation!(generated, citation) do
    label = "singularity-source-" <> citation["id"]

    definitions =
      generated
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "[^" <> label <> "]: "))

    assert [definition] = definitions, "exact citation pin boundary"

    assert String.contains?(
             definition,
             "; citation: " <>
               citation["id"] <>
               "; resource: " <>
               citation["source_resource_id"] <>
               "; version: " <>
               citation["source_version_id"] <> "; fragment: " <> citation["fragment_id"]
           ),
           "exact citation pin boundary"
  end

  defp identity("resources", r), do: r["id"]
  defp identity("versions", r), do: {r["resource_id"], r["version_id"]}
  defp identity("fragments", r), do: {r["resource_id"], r["version_id"], r["ordinal"], r["id"]}
  defp identity(c, r) when c in ["tags", "relationships"], do: r["id"]
  defp identity("tag_assignments", r), do: {r["resource_id"], r["tag_id"]}

  defp identity(c, r) when c in ["attachments", "citations"],
    do: {r["note_resource_id"], r["note_version_id"], r["ordinal"], r["id"]}

  defp identity("files", r), do: r["path"]

  defp safe!(path) do
    assert is_binary(path) and path != "" and Path.type(path) == :relative, "safe path boundary"
    refute String.contains?(path, ["\\", <<0>>]), "safe path boundary"
    assert Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."])), "safe path boundary"
  end

  defp walk(root, prefix) do
    Enum.flat_map(File.ls!(Path.join(root, prefix)), fn name ->
      relative = Path.join(prefix, name)

      case File.lstat!(Path.join(root, relative)) do
        %{type: :directory} -> walk(root, relative)
        %{type: :regular} -> [relative]
        _ -> flunk("offline file type boundary")
      end
    end)
  end
end
