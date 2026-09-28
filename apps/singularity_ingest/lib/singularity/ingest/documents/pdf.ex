defmodule Singularity.Ingest.Documents.PDF do
  @moduledoc "Bounded extraction of text-bearing PDF bytes with page provenance."

  alias Singularity.Ingest.Documents.Poppler

  @source_limit 67_108_864
  @text_limit 16_777_216
  @page_limit 4_096
  @timeout_ms 120_000
  @minimum_timeout_ms 800
  @unsupported_codes ~w(
    encrypted_document
    malformed_document
    no_extractable_text
    source_too_large
    page_limit_exceeded
    output_too_large
    invalid_utf8
    invalid_input
  )
  @failed_codes ~w(extractor_timeout extractor_failed)

  @spec extract(binary(), keyword()) ::
          {:ok, [map()]} | {:error, {:unsupported | :failed, String.t()}}
  def extract(bytes, opts \\ [])

  def extract(bytes, opts) when is_binary(bytes) and is_list(opts) do
    runner = Keyword.get(opts, :runner, Poppler)

    with :ok <- runner_limits(opts),
         :ok <- source_limit(bytes),
         {:ok, info} <- information(runner, bytes, opts),
         {:ok, pages} <- page_count(info),
         :ok <- page_limit(pages),
         {:ok, text} <- text(runner, bytes, opts),
         :ok <- text_limit(text),
         {:ok, blocks} <- pages(text) do
      {:ok, blocks}
    else
      :timeout -> failed("extractor_timeout")
      {:error, :output_limit} -> unsupported("output_too_large")
      {:error, {:unsupported, code}} when code in @unsupported_codes -> unsupported(code)
      {:error, {:failed, code}} when code in @failed_codes -> failed(code)
      {:error, _reason} -> failed("extractor_failed")
    end
  end

  def extract(_, _), do: unsupported("invalid_input")

  defp information(runner, bytes, opts) do
    case runner.run(:info, bytes, opts) do
      {:exit, _status} -> classify_invalid_pdf(bytes)
      other -> other
    end
  end

  defp text(runner, bytes, opts) do
    case runner.run(:text, bytes, opts) do
      {:exit, _status} -> failed("extractor_failed")
      other -> other
    end
  end

  defp source_limit(bytes) when byte_size(bytes) <= @source_limit, do: :ok
  defp source_limit(_bytes), do: unsupported("source_too_large")

  defp runner_limits(opts) do
    with :ok <- runner_limit(opts, :timeout_ms, @timeout_ms),
         :ok <- runner_limit(opts, :output_limit, @text_limit) do
      :ok
    else
      :error -> {:error, :invalid_runner_limit}
    end
  end

  defp runner_limit(opts, key, maximum) do
    minimum = if key == :timeout_ms, do: @minimum_timeout_ms, else: 1

    case Keyword.fetch(opts, key) do
      :error ->
        :ok

      {:ok, value} when is_integer(value) and value >= minimum and value <= maximum ->
        :ok

      {:ok, _value} ->
        :error
    end
  end

  defp text_limit(text) when is_binary(text) and byte_size(text) <= @text_limit, do: :ok
  defp text_limit(_text), do: unsupported("output_too_large")

  defp page_count(info) when is_binary(info) do
    case Regex.run(~r/^Pages:\s+(\d+)$/m, info, capture: :all_but_first) do
      [count] ->
        case Integer.parse(count) do
          {pages, ""} when pages > 0 -> {:ok, pages}
          _ -> unsupported("malformed_document")
        end

      _ ->
        unsupported("malformed_document")
    end
  end

  defp page_count(_), do: unsupported("malformed_document")

  defp page_limit(pages) when pages <= @page_limit, do: :ok
  defp page_limit(_pages), do: unsupported("page_limit_exceeded")

  defp pages(text) do
    if String.valid?(text) do
      blocks =
        text
        |> String.replace("\r\n", "\n")
        |> String.replace("\r", "\n")
        |> String.split("\f")
        |> Enum.with_index(1)
        |> Enum.reduce([], fn {page, number}, acc ->
          normalized = page |> String.normalize(:nfc) |> String.trim()

          if normalized == "" do
            acc
          else
            [
              %{
                text: normalized,
                locator: %{
                  version: 1,
                  kind: "pdf",
                  page: number,
                  start_char: 0,
                  end_char: String.length(normalized)
                }
              }
              | acc
            ]
          end
        end)
        |> Enum.reverse()

      if blocks == [], do: unsupported("no_extractable_text"), else: {:ok, blocks}
    else
      unsupported("invalid_utf8")
    end
  end

  defp classify_invalid_pdf(bytes) do
    if structurally_encrypted_pdf?(bytes) do
      unsupported("encrypted_document")
    else
      unsupported("malformed_document")
    end
  end

  defp structurally_encrypted_pdf?(bytes) do
    with true <- pdf_header?(bytes),
         {:ok, xref_offset} <- final_startxref(bytes),
         {:ok, trailer, size, true, %{}} <- scan_xref(bytes, xref_offset, %{}),
         {:ok, metadata, rest} <- parse_trailer_dictionary(skip_pdf_space(trailer)),
         %{size: ^size, root: root, encrypt: encrypt}
         when not is_nil(root) and not is_nil(encrypt) <-
           metadata,
         true <- valid_trailer_suffix?(rest, xref_offset),
         targets = %{root => :root, encrypt => :encrypt},
         {:ok, _trailer, ^size, true, found} <- scan_xref(bytes, xref_offset, targets),
         %{root: root_offset, encrypt: encrypt_offset} <- found,
         true <- root_offset < xref_offset and encrypt_offset < xref_offset,
         true <- valid_dictionary_object?(bytes, root_offset, root, ~r/\/Type\s+\/Catalog\b/),
         true <-
           valid_dictionary_object?(bytes, encrypt_offset, encrypt, ~r/\/Filter\s+\/Standard\b/) do
      true
    else
      _ -> false
    end
  end

  defp pdf_header?(<<"%PDF-1.", version, newline, _rest::binary>>)
       when version in ?0..?7 and newline in [10, 13],
       do: true

  defp pdf_header?(_bytes), do: false

  defp final_startxref(bytes) do
    tail_size = min(byte_size(bytes), 1_024)
    tail = binary_part(bytes, byte_size(bytes) - tail_size, tail_size)

    case Regex.run(~r/startxref\s+([0-9]+)\s+%%EOF\s*\z/, tail, capture: :all_but_first) do
      [offset] ->
        case Integer.parse(offset) do
          {value, ""} when value < byte_size(bytes) -> {:ok, value}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp scan_xref(bytes, offset, targets) do
    case binary_part(bytes, offset, byte_size(bytes) - offset) do
      <<"xref", rest::binary>> ->
        parse_xref_sections(skip_pdf_whitespace(rest), targets, 0, false, %{})

      _ ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  defp parse_xref_sections(<<"trailer", rest::binary>>, _targets, size, zero_free?, found),
    do: {:ok, rest, size, zero_free?, found}

  defp parse_xref_sections(bytes, targets, size, zero_free?, found) do
    with {:ok, first, rest} <- parse_unsigned(bytes),
         true <- horizontal_space_prefix?(rest),
         {:ok, count, rest} <- parse_unsigned(skip_horizontal_space(rest)),
         {:ok, rest} <- consume_eol(rest),
         {:ok, rest, zero_free?, found} <-
           parse_xref_entries(rest, first, count, targets, zero_free?, found) do
      parse_xref_sections(
        skip_pdf_whitespace(rest),
        targets,
        max(size, first + count),
        zero_free?,
        found
      )
    else
      _ -> :error
    end
  end

  defp parse_xref_entries(rest, _first, 0, _targets, zero_free?, found),
    do: {:ok, rest, zero_free?, found}

  defp parse_xref_entries(
         <<offset::binary-size(10), " ", generation::binary-size(5), " ", flag, rest::binary>>,
         first,
         count,
         targets,
         zero_free?,
         found
       )
       when flag in [?f, ?n] do
    with true <- decimal_binary?(offset) and decimal_binary?(generation),
         {:ok, rest} <- consume_eol(skip_horizontal_space(rest)) do
      object = first
      generation = String.to_integer(generation)
      offset = String.to_integer(offset)
      zero_free? = zero_free? or (object == 0 and generation == 65_535 and flag == ?f)

      found =
        case {flag, Map.get(targets, {object, generation})} do
          {?n, role} when not is_nil(role) -> Map.put(found, role, offset)
          _ -> found
        end

      parse_xref_entries(rest, first + 1, count - 1, targets, zero_free?, found)
    else
      _ -> :error
    end
  end

  defp parse_xref_entries(_bytes, _first, _count, _targets, _zero_free?, _found), do: :error

  defp parse_trailer_dictionary(<<"<<", rest::binary>>), do: parse_trailer_entries(rest, %{})
  defp parse_trailer_dictionary(_bytes), do: :error

  defp parse_trailer_entries(bytes, metadata) do
    case skip_pdf_space(bytes) do
      <<">>", rest::binary>> ->
        {:ok, metadata, rest}

      <<"/", rest::binary>> ->
        {key, rest} = take_name(rest, [])

        with true <- key != "",
             {:ok, value, rest} <- parse_trailer_value(skip_pdf_space(rest)),
             {:ok, metadata} <- put_trailer_value(metadata, key, value) do
          parse_trailer_entries(rest, metadata)
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp put_trailer_value(metadata, "Size", {:integer, value})
       when not is_map_key(metadata, :size),
       do: {:ok, Map.put(metadata, :size, value)}

  defp put_trailer_value(metadata, "Root", {:reference, object, generation})
       when not is_map_key(metadata, :root),
       do: {:ok, Map.put(metadata, :root, {object, generation})}

  defp put_trailer_value(metadata, "Encrypt", {:reference, object, generation})
       when not is_map_key(metadata, :encrypt),
       do: {:ok, Map.put(metadata, :encrypt, {object, generation})}

  defp put_trailer_value(_metadata, key, _value) when key in ["Size", "Root", "Encrypt"],
    do: :error

  defp put_trailer_value(metadata, _key, _value), do: {:ok, metadata}

  defp parse_trailer_value(bytes) do
    case parse_indirect_reference(bytes) do
      {:ok, object, generation, rest} -> {:ok, {:reference, object, generation}, rest}
      :error -> parse_direct_trailer_value(bytes)
    end
  end

  defp parse_direct_trailer_value(<<"[", rest::binary>>), do: parse_array(rest)

  defp parse_direct_trailer_value(<<"<", rest::binary>>) do
    case skip_hex_string(rest, false) do
      {:ok, rest} -> {:ok, :direct, rest}
      :error -> :error
    end
  end

  defp parse_direct_trailer_value(<<"/", rest::binary>>) do
    case take_name(rest, []) do
      {"", _rest} -> :error
      {_name, rest} -> {:ok, :direct, rest}
    end
  end

  defp parse_direct_trailer_value(bytes) do
    case parse_unsigned(bytes) do
      {:ok, value, rest} -> {:ok, {:integer, value}, rest}
      :error -> :error
    end
  end

  defp parse_array(bytes) do
    case skip_pdf_space(bytes) do
      <<"]", rest::binary>> -> {:ok, :direct, rest}
      rest -> with {:ok, _value, rest} <- parse_trailer_value(rest), do: parse_array(rest)
    end
  end

  defp skip_hex_string(<<>>, _seen?), do: :error
  defp skip_hex_string(<<">", rest::binary>>, true), do: {:ok, rest}

  defp skip_hex_string(<<byte, rest::binary>>, _seen?)
       when byte in ?0..?9 or byte in ?a..?f or byte in ?A..?F,
       do: skip_hex_string(rest, true)

  defp skip_hex_string(<<byte, rest::binary>>, seen?) when byte in [0, 9, 10, 12, 13, 32],
    do: skip_hex_string(rest, seen?)

  defp skip_hex_string(_bytes, _seen?), do: :error

  defp parse_indirect_reference(bytes) do
    with {:ok, object, rest} <- parse_unsigned(bytes),
         true <- pdf_whitespace_prefix?(rest),
         {:ok, generation, rest} <- parse_unsigned(skip_pdf_whitespace(rest)),
         true <- pdf_whitespace_prefix?(rest),
         <<"R", rest::binary>> <- skip_pdf_whitespace(rest),
         true <- rest == <<>> or delimiter_prefix?(rest) do
      {:ok, object, generation, rest}
    else
      _ -> :error
    end
  end

  defp parse_unsigned(bytes), do: take_digits(bytes, 0, 0)

  defp take_digits(<<digit, rest::binary>>, value, count) when digit in ?0..?9,
    do: take_digits(rest, value * 10 + digit - ?0, count + 1)

  defp take_digits(rest, value, count) when count > 0, do: {:ok, value, rest}
  defp take_digits(_rest, _value, 0), do: :error

  defp valid_trailer_suffix?(rest, xref_offset) do
    with <<"startxref", rest::binary>> <- skip_pdf_space(rest),
         {:ok, ^xref_offset, rest} <- parse_unsigned(skip_pdf_space(rest)),
         <<"%%EOF", rest::binary>> <- skip_pdf_whitespace(rest),
         <<>> <- skip_pdf_whitespace(rest) do
      true
    else
      _ -> false
    end
  end

  defp valid_dictionary_object?(bytes, offset, {object, generation}, required_pattern) do
    with source <- binary_part(bytes, offset, byte_size(bytes) - offset),
         {:ok, ^object, rest} <- parse_unsigned(source),
         true <- pdf_whitespace_prefix?(rest),
         {:ok, ^generation, rest} <- parse_unsigned(skip_pdf_whitespace(rest)),
         true <- pdf_whitespace_prefix?(rest),
         <<"obj", rest::binary>> <- skip_pdf_whitespace(rest),
         rest <- skip_pdf_space(rest),
         {end_offset, 6} <- :binary.match(rest, "endobj"),
         dictionary <- binary_part(rest, 0, end_offset),
         true <- Regex.match?(~r/\A<<.*>>\s*\z/s, dictionary),
         true <- Regex.match?(required_pattern, dictionary) do
      true
    else
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  defp decimal_binary?(bytes), do: decimal_binary?(bytes, true)
  defp decimal_binary?(<<>>, seen?), do: seen?

  defp decimal_binary?(<<digit, rest::binary>>, _seen?) when digit in ?0..?9,
    do: decimal_binary?(rest, true)

  defp decimal_binary?(_bytes, _seen?), do: false

  defp consume_eol(<<"\r\n", rest::binary>>), do: {:ok, rest}
  defp consume_eol(<<byte, rest::binary>>) when byte in [10, 13], do: {:ok, rest}
  defp consume_eol(_bytes), do: :error

  defp skip_horizontal_space(<<byte, rest::binary>>) when byte in [0, 9, 12, 32],
    do: skip_horizontal_space(rest)

  defp skip_horizontal_space(rest), do: rest

  defp horizontal_space_prefix?(<<byte, _rest::binary>>), do: byte in [0, 9, 12, 32]
  defp horizontal_space_prefix?(<<>>), do: false

  defp take_name(<<byte, _rest::binary>> = bytes, acc)
       when byte in [0, 9, 10, 12, 13, 32, ?(, ?), ?<, ?>, ?[, ?], ?{, ?}, ?/, ?%],
       do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), bytes}

  defp take_name(<<byte, rest::binary>>, acc), do: take_name(rest, [byte | acc])
  defp take_name(<<>>, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), <<>>}

  defp skip_pdf_space(<<"%", rest::binary>>), do: rest |> skip_comment() |> skip_pdf_space()

  defp skip_pdf_space(<<byte, rest::binary>>)
       when byte in [0, 9, 10, 12, 13, 32],
       do: skip_pdf_space(rest)

  defp skip_pdf_space(rest), do: rest

  defp skip_pdf_whitespace(<<byte, rest::binary>>)
       when byte in [0, 9, 10, 12, 13, 32],
       do: skip_pdf_whitespace(rest)

  defp skip_pdf_whitespace(rest), do: rest

  defp skip_comment(<<>>), do: <<>>
  defp skip_comment(<<byte, rest::binary>>) when byte in [10, 13], do: rest
  defp skip_comment(<<_byte, rest::binary>>), do: skip_comment(rest)

  defp pdf_whitespace_prefix?(<<byte, _rest::binary>>), do: byte in [0, 9, 10, 12, 13, 32]
  defp pdf_whitespace_prefix?(<<>>), do: false

  defp delimiter_prefix?(<<byte, _rest::binary>>),
    do: byte in [0, 9, 10, 12, 13, 32, ?(, ?), ?<, ?>, ?[, ?], ?{, ?}, ?/, ?%]

  defp unsupported(code), do: {:error, {:unsupported, code}}
  defp failed(code), do: {:error, {:failed, code}}
end
