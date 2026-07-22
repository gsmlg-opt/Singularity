defmodule Singularity.Ingest.Metadata.JPEG do
  @moduledoc "Bounded JPEG marker scanner for start-of-frame dimensions."

  alias Singularity.Core.Error

  @extractor_version 1
  @max_bigint 9_223_372_036_854_775_807
  @max_segment_headers 256
  @scan_keys ~w[
    phase declared_media_type plaintext_bytes cursor segments_seen mode segment_kind
    segment_length_acc segment_length height_acc height width_acc width
  ]
  @sof_markers [
    0xC0,
    0xC1,
    0xC2,
    0xC3,
    0xC5,
    0xC6,
    0xC7,
    0xC9,
    0xCA,
    0xCB,
    0xCD,
    0xCE,
    0xCF
  ]

  @spec extract(map(), binary()) :: {:ok, map()} | {:error, Error.t()}
  def extract(
        %{plaintext_byte_size: plaintext_byte_size} = reader,
        <<0xFF, 0xD8, _rest::binary>> = prefix
      )
      when plaintext_byte_size >= 2 do
    scan_segments(reader, prefix, 2, 0)
  end

  def extract(_reader, _prefix), do: integrity_failure()

  @doc false
  @spec incremental_state(map()) :: map()
  def incremental_state(%{
        "phase" => "start",
        "declared_media_type" => "image/jpeg",
        "plaintext_bytes" => plaintext_byte_size
      })
      when is_integer(plaintext_byte_size) and plaintext_byte_size >= 2 do
    %{
      "phase" => "jpeg_scan",
      "declared_media_type" => "image/jpeg",
      "plaintext_bytes" => plaintext_byte_size,
      "cursor" => 0,
      "segments_seen" => 0,
      "mode" => "soi_first"
    }
  end

  def incremental_state(state), do: state

  @doc false
  @spec step(map(), binary(), non_neg_integer()) ::
          {:continue, map()}
          | {:done, map(), map()}
          | {:error, Error.t(), map()}
  def step(state, chunk, chunk_offset)
      when is_map(state) and is_binary(chunk) and is_integer(chunk_offset) and
             chunk_offset >= 0 do
    if valid_incremental_state?(state) do
      scan_chunk(state, chunk, chunk_offset)
    else
      terminal_error(state)
    end
  end

  def step(state, _chunk, _chunk_offset), do: terminal_error(state)

  defp scan_segments(_reader, _prefix, _offset, segments_seen)
       when segments_seen >= @max_segment_headers,
       do: integrity_failure()

  defp scan_segments(reader, prefix, offset, segments_seen) do
    case read_exact(reader, prefix, offset, 2) do
      {:ok, <<0xFF, marker>>} ->
        handle_marker(reader, prefix, offset, marker, segments_seen)

      {:error, %Error{}} = error ->
        error

      _invalid ->
        integrity_failure()
    end
  end

  defp handle_marker(reader, prefix, offset, 0xFF, segments_seen),
    do: scan_segments(reader, prefix, offset + 1, segments_seen + 1)

  defp handle_marker(reader, prefix, offset, 0x01, segments_seen),
    do: scan_segments(reader, prefix, offset + 2, segments_seen + 1)

  defp handle_marker(reader, prefix, offset, marker, _segments_seen)
       when marker in @sof_markers do
    with {:ok, segment_length} <- read_segment_length(reader, prefix, offset) do
      extract_dimensions(reader, prefix, offset, marker, segment_length)
    end
  end

  defp handle_marker(reader, prefix, offset, marker, segments_seen) do
    if variable_length_marker?(marker) do
      with {:ok, segment_length} <- read_segment_length(reader, prefix, offset) do
        skip_segment(reader, prefix, offset, segment_length, segments_seen)
      end
    else
      integrity_failure()
    end
  end

  defp read_segment_length(reader, prefix, offset) do
    case read_exact(reader, prefix, offset + 2, 2) do
      {:ok, <<segment_length::unsigned-big-16>>} -> {:ok, segment_length}
      {:error, %Error{}} = error -> error
      _invalid -> integrity_failure()
    end
  end

  defp skip_segment(reader, prefix, offset, segment_length, segments_seen) do
    next_offset = offset + 2 + segment_length

    if segment_length >= 2 and next_offset <= reader.plaintext_byte_size do
      scan_segments(reader, prefix, next_offset, segments_seen + 1)
    else
      integrity_failure()
    end
  end

  defp extract_dimensions(reader, prefix, offset, marker, segment_length) do
    segment_end = offset + 2 + segment_length

    with true <- segment_length >= 8 and segment_end <= reader.plaintext_byte_size,
         {:ok,
          <<0xFF, ^marker, ^segment_length::unsigned-big-16, precision, height::unsigned-big-16,
            width::unsigned-big-16,
            components>>} <-
           read_exact(reader, prefix, offset, 10),
         true <- precision > 0 and width > 0 and height > 0 and components > 0,
         true <- segment_length == 8 + components * 3 do
      {:ok,
       %{
         detected_media_type: "image/jpeg",
         plaintext_bytes: reader.plaintext_byte_size,
         width: width,
         height: height,
         pdf_version: nil,
         extractor_version: @extractor_version
       }}
    else
      {:error, %Error{}} = error -> error
      _invalid -> integrity_failure()
    end
  end

  defp read_exact(_reader, prefix, offset, length)
       when offset >= 0 and length > 0 and offset + length <= byte_size(prefix) do
    {:ok, binary_part(prefix, offset, length)}
  end

  defp read_exact(reader, _prefix, offset, length)
       when offset >= 0 and length > 0 and offset + length <= reader.plaintext_byte_size do
    case reader.read_range.(offset, length) do
      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) == length -> {:ok, bytes}
      {:error, %Error{}} = error -> error
      _invalid -> integrity_failure()
    end
  end

  defp read_exact(_reader, _prefix, _offset, _length), do: integrity_failure()

  defp variable_length_marker?(marker) do
    marker not in [0x00, 0x01, 0xD8, 0xD9, 0xDA] and marker not in 0xD0..0xD7
  end

  defp scan_chunk(state, chunk, chunk_offset) do
    chunk_end = chunk_offset + byte_size(chunk)

    cond do
      state["cursor"] < chunk_offset ->
        terminal_error(state)

      state["cursor"] >= state["plaintext_bytes"] ->
        terminal_error(state)

      state["cursor"] >= chunk_end ->
        {:continue, state}

      true ->
        consume(state, chunk, chunk_offset, chunk_end)
    end
  end

  defp consume(state, chunk, chunk_offset, chunk_end) do
    if state["cursor"] >= chunk_end do
      if state["cursor"] == state["plaintext_bytes"] do
        terminal_error(state)
      else
        {:continue, state}
      end
    else
      byte = :binary.at(chunk, state["cursor"] - chunk_offset)

      case consume_byte(state, byte) do
        {:next, next_state} -> consume(next_state, chunk, chunk_offset, chunk_end)
        {:skip, next_state} -> consume(next_state, chunk, chunk_offset, chunk_end)
        {:done, metadata, final_state} -> {:done, metadata, final_state}
        :error -> terminal_error(state)
      end
    end
  end

  defp consume_byte(%{"mode" => "soi_first", "cursor" => cursor} = state, 0xFF),
    do: {:next, %{state | "cursor" => cursor + 1, "mode" => "soi_second"}}

  defp consume_byte(%{"mode" => "soi_second", "cursor" => cursor} = state, 0xD8),
    do: {:next, %{state | "cursor" => cursor + 1, "mode" => "marker_prefix"}}

  defp consume_byte(
         %{
           "mode" => "marker_prefix",
           "cursor" => cursor,
           "segments_seen" => segments_seen
         } = state,
         0xFF
       )
       when segments_seen < @max_segment_headers,
       do: {:next, %{state | "cursor" => cursor + 1, "mode" => "marker_code"}}

  defp consume_byte(
         %{
           "mode" => "marker_code",
           "cursor" => cursor,
           "segments_seen" => segments_seen
         } = state,
         0xFF
       )
       when segments_seen < @max_segment_headers do
    {:next,
     %{
       state
       | "cursor" => cursor + 1,
         "segments_seen" => segments_seen + 1
     }}
  end

  defp consume_byte(
         %{
           "mode" => "marker_code",
           "cursor" => cursor,
           "segments_seen" => segments_seen
         } = state,
         0x01
       )
       when segments_seen < @max_segment_headers do
    {:next,
     %{
       state
       | "cursor" => cursor + 1,
         "segments_seen" => segments_seen + 1,
         "mode" => "marker_prefix"
     }}
  end

  defp consume_byte(
         %{
           "mode" => "marker_code",
           "cursor" => cursor,
           "segments_seen" => segments_seen
         } = state,
         marker
       )
       when segments_seen < @max_segment_headers do
    case segment_kind(marker) do
      {:ok, segment_kind} ->
        {:next,
         state
         |> Map.merge(%{
           "cursor" => cursor + 1,
           "mode" => "length_high",
           "segment_kind" => segment_kind
         })}

      :error ->
        :error
    end
  end

  defp consume_byte(
         %{"mode" => "length_high", "cursor" => cursor} = state,
         byte
       ) do
    {:next,
     state
     |> Map.merge(%{
       "cursor" => cursor + 1,
       "mode" => "length_low",
       "segment_length_acc" => byte * 256
     })}
  end

  defp consume_byte(
         %{
           "mode" => "length_low",
           "cursor" => cursor,
           "segment_kind" => segment_kind,
           "segment_length_acc" => segment_length_accumulator,
           "plaintext_bytes" => plaintext_byte_size,
           "segments_seen" => segments_seen
         } = state,
         length_low
       ) do
    segment_length = segment_length_accumulator + length_low
    segment_end = cursor + segment_length - 1

    cond do
      segment_length < 2 or
        (segment_kind == "sof" and segment_length < 8) or
          segment_end > plaintext_byte_size ->
        :error

      segment_kind == "sof" ->
        {:next,
         state
         |> Map.drop(["segment_length_acc"])
         |> Map.merge(%{
           "cursor" => cursor + 1,
           "mode" => "sof_precision",
           "segment_length" => segment_length
         })}

      true ->
        {:skip,
         state
         |> Map.drop(["segment_kind", "segment_length_acc"])
         |> Map.merge(%{
           "cursor" => segment_end,
           "segments_seen" => segments_seen + 1,
           "mode" => "marker_prefix"
         })}
    end
  end

  defp consume_byte(%{"mode" => "sof_precision", "cursor" => cursor} = state, precision)
       when precision > 0 do
    {:next, %{state | "cursor" => cursor + 1, "mode" => "sof_height_high"}}
  end

  defp consume_byte(%{"mode" => "sof_height_high", "cursor" => cursor} = state, byte) do
    {:next,
     state
     |> Map.merge(%{
       "cursor" => cursor + 1,
       "mode" => "sof_height_low",
       "height_acc" => byte * 256
     })}
  end

  defp consume_byte(
         %{
           "mode" => "sof_height_low",
           "cursor" => cursor,
           "height_acc" => height_accumulator
         } = state,
         low
       ) do
    height = height_accumulator + low

    if height > 0 do
      {:next,
       state
       |> Map.drop(["height_acc"])
       |> Map.merge(%{
         "cursor" => cursor + 1,
         "mode" => "sof_width_high",
         "height" => height
       })}
    else
      :error
    end
  end

  defp consume_byte(%{"mode" => "sof_width_high", "cursor" => cursor} = state, byte) do
    {:next,
     state
     |> Map.merge(%{
       "cursor" => cursor + 1,
       "mode" => "sof_width_low",
       "width_acc" => byte * 256
     })}
  end

  defp consume_byte(
         %{
           "mode" => "sof_width_low",
           "cursor" => cursor,
           "width_acc" => width_accumulator
         } = state,
         low
       ) do
    width = width_accumulator + low

    if width > 0 do
      {:next,
       state
       |> Map.drop(["width_acc"])
       |> Map.merge(%{
         "cursor" => cursor + 1,
         "mode" => "sof_components",
         "width" => width
       })}
    else
      :error
    end
  end

  defp consume_byte(
         %{
           "mode" => "sof_components",
           "segment_length" => segment_length,
           "height" => height,
           "width" => width,
           "plaintext_bytes" => plaintext_byte_size
         },
         components
       )
       when components > 0 and segment_length == 8 + components * 3 do
    metadata = %{
      detected_media_type: "image/jpeg",
      plaintext_bytes: plaintext_byte_size,
      width: width,
      height: height,
      pdf_version: nil,
      extractor_version: @extractor_version
    }

    {:done, metadata,
     %{
       "phase" => "done",
       "result" => %{
         "detected_media_type" => "image/jpeg",
         "plaintext_bytes" => plaintext_byte_size,
         "width" => width,
         "height" => height,
         "pdf_version" => nil,
         "extractor_version" => @extractor_version
       }
     }}
  end

  defp consume_byte(_state, _byte), do: :error

  @doc false
  @spec valid_incremental_state?(map()) :: boolean()
  def valid_incremental_state?(
        %{
          "phase" => "jpeg_scan",
          "declared_media_type" => "image/jpeg",
          "plaintext_bytes" => plaintext_byte_size,
          "cursor" => cursor,
          "segments_seen" => segments_seen,
          "mode" => mode
        } = state
      ) do
    Map.keys(state) -- @scan_keys == [] and
      is_integer(plaintext_byte_size) and plaintext_byte_size >= 2 and
      plaintext_byte_size <= @max_bigint and
      is_integer(cursor) and cursor >= 0 and cursor < plaintext_byte_size and
      is_integer(segments_seen) and segments_seen >= 0 and
      segments_seen < @max_segment_headers and
      mode in [
        "soi_first",
        "soi_second",
        "marker_prefix",
        "marker_code",
        "length_high",
        "length_low",
        "sof_precision",
        "sof_height_high",
        "sof_height_low",
        "sof_width_high",
        "sof_width_low",
        "sof_components"
      ] and valid_mode_fields?(state, mode)
  end

  def valid_incremental_state?(_state), do: false

  defp valid_mode_fields?(state, "soi_first"),
    do: exact_mode_keys?(state, []) and state["cursor"] == 0

  defp valid_mode_fields?(state, "soi_second"),
    do: exact_mode_keys?(state, []) and state["cursor"] == 1

  defp valid_mode_fields?(state, "marker_prefix"),
    do: exact_mode_keys?(state, []) and state["cursor"] >= 2

  defp valid_mode_fields?(state, "marker_code"),
    do: exact_mode_keys?(state, []) and state["cursor"] >= 3

  defp valid_mode_fields?(state, "length_high"),
    do:
      exact_mode_keys?(state, ["segment_kind"]) and valid_segment_kind?(state["segment_kind"]) and
        state["cursor"] + 2 <= state["plaintext_bytes"]

  defp valid_mode_fields?(state, "length_low"),
    do:
      exact_mode_keys?(state, ["segment_kind", "segment_length_acc"]) and
        valid_segment_kind?(state["segment_kind"]) and
        shifted_accumulator?(state["segment_length_acc"]) and
        state["cursor"] + 1 <= state["plaintext_bytes"]

  defp valid_mode_fields?(state, mode) when mode in ["sof_precision", "sof_height_high"] do
    exact_mode_keys?(state, ["segment_kind", "segment_length"]) and
      state["segment_kind"] == "sof" and valid_segment_length?(state["segment_length"]) and
      valid_sof_bounds?(state, mode)
  end

  defp valid_mode_fields?(state, "sof_height_low") do
    exact_mode_keys?(state, ["segment_kind", "segment_length", "height_acc"]) and
      state["segment_kind"] == "sof" and valid_segment_length?(state["segment_length"]) and
      shifted_accumulator?(state["height_acc"]) and
      valid_sof_bounds?(state, "sof_height_low")
  end

  defp valid_mode_fields?(state, "sof_width_high") do
    exact_mode_keys?(state, ["segment_kind", "segment_length", "height"]) and
      state["segment_kind"] == "sof" and valid_segment_length?(state["segment_length"]) and
      positive_dimension?(state["height"]) and valid_sof_bounds?(state, "sof_width_high")
  end

  defp valid_mode_fields?(state, "sof_width_low") do
    exact_mode_keys?(state, ["segment_kind", "segment_length", "height", "width_acc"]) and
      state["segment_kind"] == "sof" and valid_segment_length?(state["segment_length"]) and
      positive_dimension?(state["height"]) and shifted_accumulator?(state["width_acc"]) and
      valid_sof_bounds?(state, "sof_width_low")
  end

  defp valid_mode_fields?(state, "sof_components") do
    exact_mode_keys?(state, ["segment_kind", "segment_length", "height", "width"]) and
      state["segment_kind"] == "sof" and valid_segment_length?(state["segment_length"]) and
      positive_dimension?(state["height"]) and positive_dimension?(state["width"]) and
      valid_sof_bounds?(state, "sof_components")
  end

  defp exact_mode_keys?(state, additional) do
    base = ~w[phase declared_media_type plaintext_bytes cursor segments_seen mode]
    Enum.sort(Map.keys(state)) == Enum.sort(base ++ additional)
  end

  defp segment_kind(marker) when marker in @sof_markers, do: {:ok, "sof"}

  defp segment_kind(marker) do
    if variable_length_marker?(marker), do: {:ok, "skip"}, else: :error
  end

  defp valid_segment_kind?(segment_kind), do: segment_kind in ["sof", "skip"]

  defp valid_segment_length?(value), do: is_integer(value) and value in 8..65_535

  defp positive_dimension?(value), do: is_integer(value) and value in 1..65_535

  defp shifted_accumulator?(value),
    do: is_integer(value) and value in 0..65_280 and rem(value, 256) == 0

  defp valid_sof_bounds?(state, mode) do
    consumed_after_length = %{
      "sof_precision" => 0,
      "sof_height_high" => 1,
      "sof_height_low" => 2,
      "sof_width_high" => 3,
      "sof_width_low" => 4,
      "sof_components" => 5
    }

    remaining = state["segment_length"] - 2 - Map.fetch!(consumed_after_length, mode)
    remaining >= 1 and state["cursor"] + remaining <= state["plaintext_bytes"]
  end

  defp terminal_error(state) do
    error = Error.new(:integrity_failure)

    failed =
      state
      |> Map.take(["declared_media_type", "plaintext_bytes"])
      |> Map.merge(%{
        "phase" => "failed",
        "error_code" => "integrity_failure"
      })

    {:error, error, failed}
  end

  defp integrity_failure, do: {:error, Error.new(:integrity_failure)}
end
