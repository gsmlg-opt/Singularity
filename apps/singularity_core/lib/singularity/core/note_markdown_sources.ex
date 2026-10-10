defmodule Singularity.Core.NoteMarkdownSources do
  @moduledoc "Pure, bounded Markdown inventory of exact immutable Note sources."

  alias Singularity.Core.{Error, NoteAttachmentReference, NoteCitationReference}

  @canonical_limit 1_048_576
  @rendered_limit 16_777_216
  @punctuation ~c"!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
  @controls Enum.to_list(0..31) ++ [127] ++ Enum.to_list(128..159)
  @escape_tokens Map.new(@punctuation, &{<<&1>>, "\\" <> <<&1>>})
                 |> Map.merge(
                   Map.new(@controls, fn codepoint ->
                     visible =
                       case codepoint do
                         9 ->
                           "\\t"

                         10 ->
                           "\\n"

                         13 ->
                           "\\r"

                         value ->
                           "\\u" <> (value |> Integer.to_string(16) |> String.pad_leading(4, "0"))
                       end

                     {<<codepoint::utf8>>, visible}
                   end)
                 )
  @escape_patterns Map.keys(@escape_tokens)
  @section "\n\n## Sources\n\nText-only source inventory; no source files included.\n\n"

  @spec render(term(), term()) :: {:ok, String.t()} | {:error, Error.t()}
  def render(markdown, descriptors) do
    with true <- valid_text?(markdown, @canonical_limit),
         true <- exact_map?(descriptors, [:attachments, :citations]),
         {:ok, state} <-
           validate_collection(descriptors.attachments, :attachment, {MapSet.new(), 0}),
         {:ok, _state} <- validate_collection(descriptors.citations, :citation, state) do
      if descriptors.attachments == [] and descriptors.citations == [] do
        {:ok, markdown}
      else
        render_sources(markdown, descriptors)
      end
    else
      _invalid -> invalid()
    end
  end

  @spec valid_rendered?(term()) :: boolean()
  def valid_rendered?(markdown), do: valid_text?(markdown, @rendered_limit)

  defp render_sources(markdown, descriptors) do
    with {:ok, fence} <- scan_lines(markdown, :outside) do
      {citations, _occupied} =
        Enum.map_reduce(descriptors.citations, occupied_labels(markdown), fn descriptor,
                                                                             occupied ->
          base = "singularity-source-" <> descriptor.reference.citation_id
          label = unoccupied_label(base, occupied, 0)
          {{descriptor, label}, MapSet.put(occupied, label)}
        end)

      tokens = [
        markdown,
        closer(markdown, fence),
        @section,
        Enum.map(descriptors.attachments, &attachment_line/1),
        Enum.map(citations, fn {descriptor, label} -> citation_line(descriptor, label) end),
        if(citations == [], do: [], else: "\n"),
        Enum.map(citations, fn {descriptor, label} -> citation_definition(descriptor, label) end)
      ]

      escape_pattern = :binary.compile_pattern(@escape_patterns)

      with {:ok, _size} <- count_tokens(tokens, 0, escape_pattern),
           output <- tokens |> emit_tokens(escape_pattern) |> IO.iodata_to_binary(),
           true <- valid_rendered?(output) do
        {:ok, output}
      else
        _invalid -> invalid()
      end
    else
      _invalid -> invalid()
    end
  end

  defp validate_collection(items, kind, state),
    do: validate_collection(items, kind, state, 0, MapSet.new(), MapSet.new())

  defp validate_collection([], _kind, state, _count, _ids, _natural), do: {:ok, state}

  defp validate_collection([item | rest], kind, {targets, title_bytes}, count, ids, natural)
       when count < 100 do
    with true <- exact_map?(item, [:reference, :source, :href]),
         {:ok, id, target, natural_key, target_kind} <- reference_identity(item.reference, kind),
         true <- not MapSet.member?(ids, id),
         true <- kind != :attachment or not MapSet.member?(natural, natural_key),
         true <- valid_source?(item.source, target_kind, target),
         true <- item.href === href(target_kind, target),
         next_title_bytes <- title_bytes + byte_size(item.source.title),
         true <- next_title_bytes <= @rendered_limit,
         next_targets <- MapSet.put(targets, target),
         true <- MapSet.size(next_targets) <= 100 do
      validate_collection(
        rest,
        kind,
        {next_targets, next_title_bytes},
        count + 1,
        MapSet.put(ids, id),
        MapSet.put(natural, natural_key)
      )
    else
      _invalid -> invalid()
    end
  end

  defp validate_collection(_items, _kind, _state, _count, _ids, _natural), do: invalid()

  defp reference_identity(%NoteAttachmentReference{} = reference, :attachment) do
    with {:ok, canonical} <- NoteAttachmentReference.new(reference),
         true <- canonical === reference do
      target = {reference.target_resource_id, reference.target_resource_version_id}
      {:ok, reference.attachment_id, target, {target, reference.role}, reference.target_kind}
    else
      _invalid -> invalid()
    end
  end

  defp reference_identity(%NoteCitationReference{} = reference, :citation) do
    with {:ok, canonical} <- NoteCitationReference.new(reference),
         true <- canonical === reference do
      {:ok, reference.citation_id,
       {reference.source_resource_id, reference.source_resource_version_id}, nil, :document}
    else
      _invalid -> invalid()
    end
  end

  defp reference_identity(_reference, _kind), do: invalid()

  defp valid_source?(source, kind, {resource, version}) do
    exact_map?(source, [:kind, :resource_id, :resource_version_id, :title, :deleted?]) and
      source.kind === kind and source.resource_id === resource and
      source.resource_version_id === version and is_boolean(source.deleted?) and
      valid_text?(source.title, @rendered_limit) and String.trim(source.title) != ""
  end

  defp exact_map?(value, keys) when is_map(value) and not is_struct(value),
    do: map_size(value) == length(keys) and Enum.all?(keys, &Map.has_key?(value, &1))

  defp exact_map?(_value, _keys), do: false

  defp valid_text?(value, limit) when is_binary(value),
    do:
      byte_size(value) <= limit and String.valid?(value) and
        :binary.match(value, <<0>>) == :nomatch

  defp valid_text?(_value, _limit), do: false

  defp href(kind, {resource, version}) do
    extension =
      case kind do
        :asset -> "bin"
        :note -> "md"
        :document -> "txt"
      end

    "sources/#{kind}-#{resource}-#{version}.#{extension}"
  end

  defp attachment_line(%{reference: reference, source: source} = descriptor) do
    label =
      if reference.label in [nil, ""], do: [], else: ["; label: ", {:escape, reference.label}]

    [
      main_link(descriptor),
      "; attachment: ",
      reference.attachment_id,
      label,
      historical(source),
      "\n"
    ]
  end

  defp citation_line(%{reference: reference, source: source} = descriptor, label),
    do: [
      main_link(descriptor),
      " [^",
      label,
      "]; citation: ",
      reference.citation_id,
      historical(source),
      "\n"
    ]

  defp main_link(%{source: source, href: href}),
    do: [
      "- [",
      {:escape, source.title},
      "](",
      href,
      ") — ",
      Atom.to_string(source.kind),
      "; resource: ",
      source.resource_id,
      "; version: ",
      source.resource_version_id
    ]

  defp historical(%{deleted?: true}), do: "; deleted historical source"
  defp historical(%{deleted?: false}), do: []

  defp citation_definition(%{reference: reference, source: source}, label),
    do: [
      "[^",
      label,
      "]: citation: ",
      reference.citation_id,
      "; resource: ",
      source.resource_id,
      "; version: ",
      source.resource_version_id,
      "; fragment: ",
      reference.fragment_id,
      "; ",
      locator_tokens(reference.locator),
      historical(source),
      "\n"
    ]

  defp locator_tokens(%{kind: "pdf", fields: fields}),
    do: [
      "PDF page ",
      Integer.to_string(fields.page),
      optional_range(fields, :start_char, :end_char, "; characters ")
    ]

  defp locator_tokens(%{kind: "markdown", fields: fields}),
    do: [
      "Markdown heading ",
      Enum.intersperse(Enum.map(fields.heading_path, &{:escape, &1}), " > "),
      optional_range(fields, :start_line, :end_line, "; lines ")
    ]

  defp locator_tokens(%{kind: "text", fields: fields}),
    do: [
      "Text lines ",
      Integer.to_string(fields.start_line),
      "–",
      Integer.to_string(fields.end_line)
    ]

  defp locator_tokens(%{kind: "fragment", fields: fields}),
    do: ["Fragment ordinal ", Integer.to_string(fields.ordinal)]

  defp optional_range(fields, first, last, prefix) do
    if Map.has_key?(fields, first),
      do: [prefix, Integer.to_string(fields[first]), "–", Integer.to_string(fields[last])],
      else: []
  end

  defp occupied_labels(markdown) do
    ~r/\[\^([^\]\r\n]*)\]/u
    |> Regex.scan(markdown, capture: :all_but_first)
    |> Enum.reduce(MapSet.new(), fn [label], occupied ->
      folded = label |> String.trim() |> :string.casefold() |> :unicode.characters_to_binary()
      MapSet.put(occupied, folded)
    end)
  end

  defp unoccupied_label(base, occupied, suffix) do
    candidate = if suffix == 0, do: base, else: base <> "-" <> Integer.to_string(suffix)

    if MapSet.member?(occupied, candidate),
      do: unoccupied_label(base, occupied, suffix + 1),
      else: candidate
  end

  defp scan_lines(<<>>, state), do: {:ok, state}

  defp scan_lines(markdown, state) do
    case :binary.match(markdown, ["\r", "\n"]) do
      :nomatch ->
        scan_line(markdown, state)

      {position, 1} ->
        <<line::binary-size(position), ending, rest::binary>> = markdown

        rest =
          if ending == ?\r and String.starts_with?(rest, "\n"),
            do: binary_part(rest, 1, byte_size(rest) - 1),
            else: rest

        with {:ok, next_state} <- scan_line(line, state), do: scan_lines(rest, next_state)
    end
  end

  defp scan_line(<<marker, rest::binary>> = line, :outside) when marker in [?`, ?~] do
    {length, info} = marker_run(rest, marker, 1)

    if length >= 3 do
      if marker == ?` and :binary.match(info, "`") != :nomatch,
        do: invalid(),
        else: {:ok, {:fence, marker, length}}
    else
      outside_line(line)
    end
  end

  defp scan_line(line, :outside), do: outside_line(line)

  defp scan_line(line, {:fence, marker, opening_length} = state) do
    case leading_spaces(line, 0) do
      <<^marker, rest::binary>> ->
        {length, suffix} = marker_run(rest, marker, 1)

        if length >= opening_length and ascii_whitespace?(suffix),
          do: {:ok, :outside},
          else: {:ok, state}

      _literal ->
        {:ok, state}
    end
  end

  defp outside_line(line),
    do:
      if(:binary.match(line, ["<", "```", "~~~"]) == :nomatch,
        do: {:ok, :outside},
        else: invalid()
      )

  defp marker_run(<<marker, rest::binary>>, marker, length),
    do: marker_run(rest, marker, length + 1)

  defp marker_run(rest, _marker, length), do: {length, rest}

  defp leading_spaces(<<32, rest::binary>>, count) when count < 3,
    do: leading_spaces(rest, count + 1)

  defp leading_spaces(line, _count), do: line
  defp ascii_whitespace?(<<>>), do: true

  defp ascii_whitespace?(<<space, rest::binary>>) when space in [32, 9],
    do: ascii_whitespace?(rest)

  defp ascii_whitespace?(_line), do: false

  defp closer(_markdown, :outside), do: []

  defp closer(markdown, {:fence, marker, length}) do
    newline = if :binary.last(markdown) in [?\r, ?\n], do: [], else: "\n"
    [newline, {:repeat, marker, length}]
  end

  # The count pass uses the same escape table as emission, without expanding
  # titles or the final output. Ordinary text remains binary chunks in iodata.
  defp count_tokens({:escape, text}, size, pattern), do: count_escaped(text, size, pattern)
  defp count_tokens({:repeat, _marker, length}, size, _pattern), do: bounded_size(size + length)

  defp count_tokens(text, size, _pattern) when is_binary(text),
    do: bounded_size(size + byte_size(text))

  defp count_tokens(tokens, size, pattern) when is_list(tokens) do
    Enum.reduce_while(tokens, {:ok, size}, fn token, {:ok, acc} ->
      case count_tokens(token, acc, pattern) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp count_escaped(text, size, pattern) do
    case :binary.match(text, pattern) do
      :nomatch ->
        bounded_size(size + byte_size(text))

      {position, length} ->
        token = binary_part(text, position, length)

        with {:ok, next} <-
               bounded_size(size + position + byte_size(Map.fetch!(@escape_tokens, token))) do
          count_escaped(
            binary_part(text, position + length, byte_size(text) - position - length),
            next,
            pattern
          )
        end
    end
  end

  defp bounded_size(size) when size <= @rendered_limit, do: {:ok, size}
  defp bounded_size(_size), do: invalid()

  defp emit_tokens({:escape, text}, pattern), do: escape_chunks(text, [], pattern)
  defp emit_tokens({:repeat, marker, length}, _pattern), do: :binary.copy(<<marker>>, length)
  defp emit_tokens(text, _pattern) when is_binary(text), do: text

  defp emit_tokens(tokens, pattern) when is_list(tokens),
    do: Enum.map(tokens, &emit_tokens(&1, pattern))

  defp escape_chunks(text, chunks, pattern) do
    case :binary.match(text, pattern) do
      :nomatch ->
        Enum.reverse([text | chunks])

      {position, length} ->
        token = binary_part(text, position, length)
        prefix = binary_part(text, 0, position)
        rest = binary_part(text, position + length, byte_size(text) - position - length)
        escape_chunks(rest, [Map.fetch!(@escape_tokens, token), prefix | chunks], pattern)
    end
  end

  defp invalid, do: {:error, Error.new(:invalid)}
end
