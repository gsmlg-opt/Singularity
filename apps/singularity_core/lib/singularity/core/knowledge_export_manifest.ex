defmodule Singularity.Core.KnowledgeExportManifest do
  @moduledoc "Exact, owner-free JSON-ready portable manifest records; no authorization or I/O."

  alias Singularity.Core.{Error, KnowledgeExport, KnowledgeValidation, SourceLocator}

  @fields %{
    resources: ~w(id kind title current_version_id deleted_at selection_reason),
    versions:
      ~w(resource_id version_id revision kind inserted_at availability body_path original_path extracted_path body_digest original_digest original_byte_size extracted_digest media_type state extraction_adapter extraction_format parent_version_id merge_parent_version_id),
    fragments:
      ~w(id resource_id version_id ordinal digest locator extracted_path start_byte byte_size),
    tags: ~w(id display_value normalized_key),
    tag_assignments: ~w(resource_id tag_id),
    relationships: ~w(id source_resource_id target_resource_id target_version_id type),
    attachments:
      ~w(note_resource_id note_version_id id ordinal target_resource_id target_version_id target_kind role label),
    citations:
      ~w(note_resource_id note_version_id id ordinal source_resource_id source_version_id fragment_id locator),
    files: ~w(path media_type byte_size sha256)
  }
  @kinds ~w(asset note document)
  @metadata ~w(metadata_only_deleted metadata_only_unavailable metadata_only_unselected)
  @states ~w(pending extracting ready failed unsupported)
  @adapters %{
    "application/pdf" => "poppler_text",
    "text/markdown" => "markdown",
    "text/plain" => "plain_text"
  }
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @sha ~r/\A[0-9a-f]{64}\z/
  @timestamp ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z\z/
  @probe_note "notes/00000000-0000-4000-8000-000000000000--00000000-0000-4000-8000-000000000001.md"

  @spec header(term()) :: {:ok, map()} | {:error, Error.t()}
  def header(input) do
    with {:ok, options} <- KnowledgeExport.options(input) do
      arrays = Map.new(@fields, fn {key, _fields} -> {Atom.to_string(key), []} end)

      {:ok,
       Map.merge(arrays, %{
         "format" => "singularity.portable-knowledge",
         "version" => 1,
         "selection" => %{
           "mode" => "live_heads_with_source_closure",
           "include_tombstones" => options.include_tombstones
         }
       })}
    end
  end

  @spec record(term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def record(kind, input) when is_map(input) and not is_struct(input) do
    with fields when is_list(fields) <- Map.get(@fields, kind),
         true <-
           map_size(input) == length(fields) and Enum.all?(fields, &Map.has_key?(input, &1)),
         true <- valid_record?(kind, input) do
      {:ok, Map.take(input, fields)}
    else
      _ -> invalid()
    end
  end

  def record(_kind, _input), do: invalid()

  defp valid_record?(:resources, r) do
    uuid?(r["id"]) and r["kind"] in @kinds and text?(r["title"], 255) and
      String.trim(r["title"]) != "" and optional?(r["current_version_id"], &uuid?/1) and
      optional?(r["deleted_at"], &timestamp?/1) and
      r["selection_reason"] in ~w(head source relationship_endpoint tombstone)
  end

  defp valid_record?(:versions, r) do
    ids?(r, ~w(resource_id version_id)) and integer?(r["revision"]) and
      r["kind"] in @kinds and timestamp?(r["inserted_at"]) and
      optional?(r["parent_version_id"], &uuid?/1) and
      optional?(r["merge_parent_version_id"], &uuid?/1) and
      Enum.all?(
        ~w(body_digest original_digest extracted_digest),
        &optional?(r[&1], fn v -> sha?(v) end)
      ) and
      optional?(r["original_byte_size"], &integer?(&1, original_limit(r["kind"]))) and
      version_shape?(r)
  end

  defp valid_record?(:fragments, r) do
    ids?(r, ~w(resource_id version_id)) and sha?(r["id"]) and sha?(r["digest"]) and
      integer?(r["ordinal"], 4_095) and locator?(r["locator"]) and fragment_file?(r)
  end

  defp valid_record?(:tags, r) do
    value = r["display_value"]

    uuid?(r["id"]) and text?(value, 255) and value != "" and
      not Regex.match?(~r/\p{Cc}/u, value) and value == String.trim(value) and
      value == String.normalize(value, :nfc) and text?(r["normalized_key"], 1_024) and
      r["normalized_key"] ==
        value |> :string.casefold() |> IO.chardata_to_string() |> String.normalize(:nfc)
  end

  defp valid_record?(:tag_assignments, r), do: ids?(r, ~w(resource_id tag_id))

  defp valid_record?(:relationships, r) do
    ids?(r, ~w(id source_resource_id target_resource_id)) and
      r["source_resource_id"] != r["target_resource_id"] and
      optional?(r["target_version_id"], &uuid?/1) and
      r["type"] in ~w(related_to references derived_from)
  end

  defp valid_record?(:attachments, r) do
    ids?(r, ~w(note_resource_id note_version_id id target_resource_id target_version_id)) and
      integer?(r["ordinal"], 99) and r["target_kind"] in @kinds and r["role"] == "source" and
      optional?(r["label"], &text?(&1, 255))
  end

  defp valid_record?(:citations, r) do
    ids?(r, ~w(note_resource_id note_version_id id source_resource_id source_version_id)) and
      integer?(r["ordinal"], 99) and sha?(r["fragment_id"]) and locator?(r["locator"])
  end

  defp valid_record?(:files, r) do
    match?({:ok, _}, KnowledgeExport.relative_source_path(@probe_note, r["path"])) and
      media?(r["media_type"]) and integer?(r["byte_size"], file_limit(r["path"])) and
      sha?(r["sha256"])
  end

  defp version_shape?(%{"availability" => "included", "kind" => "note"} = r) do
    exact_path?(r, "body_path", :note) and sha?(r["body_digest"]) and
      nil_fields?(
        r,
        ~w(original_path extracted_path original_digest original_byte_size extracted_digest media_type state extraction_adapter extraction_format)
      )
  end

  defp version_shape?(%{"availability" => "included", "kind" => "asset"} = r) do
    exact_path?(r, "original_path", :asset) and sha?(r["original_digest"]) and
      integer?(r["original_byte_size"], original_limit("asset")) and media?(r["media_type"]) and
      nil_fields?(
        r,
        ~w(body_path extracted_path body_digest extracted_digest state extraction_adapter extraction_format parent_version_id merge_parent_version_id)
      )
  end

  defp version_shape?(%{"availability" => "included", "kind" => "document"} = r) do
    exact_path?(r, "original_path", :document, r["media_type"]) and
      sha?(r["original_digest"]) and integer?(r["original_byte_size"], original_limit("document")) and
      nil_fields?(r, ~w(body_path body_digest parent_version_id merge_parent_version_id)) and
      document_state?(r, false)
  end

  defp version_shape?(%{"availability" => availability} = r) when availability in @metadata do
    nil_fields?(r, ~w(body_path original_path extracted_path)) and metadata_shape?(r)
  end

  defp version_shape?(_r), do: false

  defp metadata_shape?(%{"kind" => "note"} = r),
    do:
      nil_fields?(
        r,
        ~w(original_digest original_byte_size extracted_digest media_type state extraction_adapter extraction_format)
      )

  defp metadata_shape?(%{"kind" => "asset"} = r),
    do:
      nil_fields?(
        r,
        ~w(body_digest extracted_digest state extraction_adapter extraction_format parent_version_id merge_parent_version_id)
      ) and optional?(r["media_type"], &media?/1)

  defp metadata_shape?(%{"kind" => "document"} = r) do
    nil_fields?(r, ~w(body_digest parent_version_id merge_parent_version_id)) and
      optional?(r["media_type"], &Map.has_key?(@adapters, &1)) and document_state?(r, true)
  end

  defp document_state?(r, metadata?) do
    state = r["state"]

    cond do
      is_nil(state) and metadata? ->
        nil_fields?(r, ~w(extracted_digest extraction_adapter extraction_format))

      state == "pending" ->
        nil_fields?(r, ~w(extracted_path extracted_digest extraction_adapter extraction_format))

      state in @states ->
        adapter?(r, metadata?) and
          if state == "ready" do
            if metadata?,
              do: true,
              else: exact_path?(r, "extracted_path", :extracted) and sha?(r["extracted_digest"])
          else
            nil_fields?(r, ~w(extracted_path extracted_digest))
          end

      true ->
        false
    end
  end

  defp adapter?(r, true) do
    if is_nil(r["extraction_adapter"]) and is_nil(r["extraction_format"]),
      do: true,
      else: adapter?(r, false)
  end

  defp adapter?(r, false),
    do:
      Map.has_key?(@adapters, r["media_type"]) and
        r["extraction_adapter"] == @adapters[r["media_type"]] and r["extraction_format"] === 1

  defp fragment_file?(%{"extracted_path" => nil} = r),
    do: nil_fields?(r, ~w(start_byte byte_size))

  defp fragment_file?(r) do
    exact_path?(r, "extracted_path", :extracted) and integer?(r["start_byte"], 16_777_216) and
      integer?(r["byte_size"], 65_536) and r["start_byte"] + r["byte_size"] <= 16_777_216
  end

  defp exact_path?(r, field, kind, media \\ nil),
    do: KnowledgeExport.path(kind, r["resource_id"], r["version_id"], media) == {:ok, r[field]}

  defp original_limit("document"), do: KnowledgeExport.limits().document_bytes
  defp original_limit(_kind), do: KnowledgeExport.limits().file_bytes

  defp file_limit("documents/originals/" <> _basename),
    do: KnowledgeExport.limits().document_bytes

  defp file_limit("documents/extracted/" <> _basename),
    do: KnowledgeExport.limits().extracted_bytes

  defp file_limit("notes/" <> _basename), do: KnowledgeExport.limits().rendered_note_bytes
  defp file_limit("assets/" <> _basename), do: KnowledgeExport.limits().file_bytes

  defp nil_fields?(r, fields), do: Enum.all?(fields, &is_nil(r[&1]))
  defp ids?(r, fields), do: Enum.all?(fields, &uuid?(r[&1]))
  defp optional?(nil, _predicate), do: true
  defp optional?(value, predicate), do: predicate.(value)
  defp text?(value, limit), do: match?({:ok, _}, KnowledgeValidation.string(value, limit))

  defp integer?(value, limit \\ 9_223_372_036_854_775_807),
    do: is_integer(value) and value >= 0 and value <= limit

  defp uuid?(value),
    do: is_binary(value) and byte_size(value) == 36 and Regex.match?(@uuid, value)

  defp sha?(value), do: is_binary(value) and byte_size(value) == 64 and Regex.match?(@sha, value)

  defp locator?(value),
    do: is_map(value) and not is_struct(value) and SourceLocator.to_map(value) === value

  defp media?(value),
    do: text?(value, 255) and Regex.match?(~r/\A[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+\z/, value)

  defp timestamp?(value) when is_binary(value) and byte_size(value) == 27 do
    Regex.match?(@timestamp, value) and
      match?({:ok, %DateTime{}, 0}, DateTime.from_iso8601(value))
  end

  defp timestamp?(_value), do: false
  defp invalid, do: {:error, Error.new(:invalid)}
end
