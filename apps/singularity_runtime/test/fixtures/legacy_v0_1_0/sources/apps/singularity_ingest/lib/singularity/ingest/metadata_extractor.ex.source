defmodule Singularity.Ingest.MetadataExtractor do
  @moduledoc "Deterministic technical metadata extraction over authenticated range reads."

  alias Singularity.Core.Error
  alias Singularity.Ingest.Metadata.JPEG
  alias Singularity.Ingest.Metadata.PDF
  alias Singularity.Ingest.Metadata.PNG

  @prefix_bytes 64
  @chunk_size 4_194_304
  @max_bigint 9_223_372_036_854_775_807
  @max_media_type_bytes 255
  @supported_media_types ["application/pdf", "image/jpeg", "image/png"]

  @type reader :: %{
          required(:declared_media_type) => String.t(),
          required(:plaintext_byte_size) => non_neg_integer(),
          required(:read_range) => (non_neg_integer(), pos_integer() ->
                                      {:ok, binary()} | {:error, Error.t()})
        }

  @type metadata :: %{
          required(:detected_media_type) => String.t(),
          required(:plaintext_bytes) => non_neg_integer(),
          required(:width) => pos_integer() | nil,
          required(:height) => pos_integer() | nil,
          required(:pdf_version) => String.t() | nil,
          required(:extractor_version) => pos_integer()
        }

  @spec extract(reader()) :: {:ok, metadata()} | {:error, Error.t()}
  def extract(
        %{
          declared_media_type: declared_media_type,
          plaintext_byte_size: plaintext_byte_size,
          read_range: read_range
        } = reader
      )
      when is_binary(declared_media_type) and is_integer(plaintext_byte_size) and
             plaintext_byte_size >= 0 and is_function(read_range, 2) do
    with {:ok, prefix} <- read_prefix(reader),
         {:ok, detected_media_type, parser} <- detect(prefix),
         :ok <- declared_type_matches(declared_media_type, detected_media_type) do
      parser.extract(reader, prefix)
    end
  end

  def extract(_reader), do: {:error, Error.new(:invalid)}

  @doc "Builds the bounded, JSON-safe initial state used by custody-backed extraction."
  @spec initial_state(String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, Error.t()}
  def initial_state(declared_media_type, plaintext_byte_size)
      when is_binary(declared_media_type) and declared_media_type != "" and
             byte_size(declared_media_type) <= @max_media_type_bytes and
             is_integer(plaintext_byte_size) and plaintext_byte_size >= 0 and
             plaintext_byte_size <= @max_bigint do
    {:ok,
     %{
       "phase" => "start",
       "declared_media_type" => declared_media_type,
       "plaintext_bytes" => plaintext_byte_size
     }}
  end

  def initial_state(_declared_media_type, _plaintext_byte_size),
    do: {:error, Error.new(:invalid)}

  @doc "Consumes one authenticated object chunk without retaining raw bytes in the state."
  @spec step(map(), binary(), non_neg_integer()) ::
          {:continue, map()}
          | {:done, metadata(), map()}
          | {:error, Error.t(), map()}
  def step(state, chunk, chunk_offset)
      when is_map(state) and is_binary(chunk) and is_integer(chunk_offset) and
             chunk_offset >= 0 do
    with :ok <- validate_step_chunk(state, chunk, chunk_offset) do
      do_step(state, chunk, chunk_offset)
    else
      {:error, %Error{} = error} -> {:error, error, failed_state(state, error.code)}
    end
  end

  def step(state, _chunk, _chunk_offset) when is_map(state),
    do: {:error, Error.new(:invalid), failed_state(state, :integrity_failure)}

  def step(_state, _chunk, _chunk_offset),
    do: {:error, Error.new(:invalid), %{"phase" => "failed", "error_code" => "invalid"}}

  @doc false
  @spec state_result(map()) ::
          :continue | {:done, metadata()} | {:error, Error.t()}
  def state_result(%{"phase" => "start"}), do: :continue
  def state_result(%{"phase" => "jpeg_scan"}), do: :continue

  def state_result(%{"phase" => "done", "result" => result}) when is_map(result) do
    with {:ok, metadata} <- metadata_from_json(result) do
      {:done, metadata}
    end
  end

  def state_result(%{"phase" => "failed", "error_code" => error_code})
      when error_code in ["integrity_failure", "unsupported_media_type"] do
    {:error, Error.new(String.to_existing_atom(error_code))}
  end

  def state_result(_state), do: {:error, Error.new(:integrity_failure)}

  @doc false
  @spec validate_state(map()) :: :ok | {:error, Error.t()}
  def validate_state(
        %{
          "phase" => "start",
          "declared_media_type" => declared_media_type,
          "plaintext_bytes" => plaintext_byte_size
        } = state
      ) do
    if Enum.sort(Map.keys(state)) ==
         Enum.sort(["phase", "declared_media_type", "plaintext_bytes"]) and
         valid_media_type?(declared_media_type) and
         valid_plaintext_size?(plaintext_byte_size),
       do: :ok,
       else: {:error, Error.new(:integrity_failure)}
  end

  def validate_state(%{"phase" => "jpeg_scan"} = state) do
    if JPEG.valid_incremental_state?(state),
      do: :ok,
      else: {:error, Error.new(:integrity_failure)}
  end

  def validate_state(%{"phase" => "done", "result" => result} = state) do
    with true <- Enum.sort(Map.keys(state)) == ["phase", "result"],
         {:ok, _metadata} <- metadata_from_json(result) do
      :ok
    else
      _invalid -> {:error, Error.new(:integrity_failure)}
    end
  end

  def validate_state(
        %{
          "phase" => "failed",
          "error_code" => error_code,
          "declared_media_type" => declared_media_type,
          "plaintext_bytes" => plaintext_byte_size
        } = state
      ) do
    if Enum.sort(Map.keys(state)) ==
         Enum.sort([
           "phase",
           "error_code",
           "declared_media_type",
           "plaintext_bytes"
         ]) and
         error_code in ["integrity_failure", "unsupported_media_type"] and
         valid_media_type?(declared_media_type) and
         valid_plaintext_size?(plaintext_byte_size),
       do: :ok,
       else: {:error, Error.new(:integrity_failure)}
  end

  def validate_state(_state), do: {:error, Error.new(:integrity_failure)}

  defp do_step(
         %{
           "phase" => "start",
           "declared_media_type" => declared_media_type,
           "plaintext_bytes" => plaintext_byte_size
         } = state,
         chunk,
         0
       ) do
    with {:ok, detected_media_type, parser} <- detect(chunk),
         :ok <- declared_type_matches(declared_media_type, detected_media_type) do
      case parser do
        JPEG ->
          state
          |> JPEG.incremental_state()
          |> JPEG.step(chunk, 0)

        parser when parser in [PDF, PNG] ->
          parser
          |> apply(:extract, [%{plaintext_byte_size: plaintext_byte_size}, chunk])
          |> terminal_result(state)
      end
    else
      {:error, %Error{} = error} ->
        {:error, error, failed_state(state, error.code)}
    end
  end

  defp do_step(%{"phase" => "jpeg_scan"} = state, chunk, chunk_offset),
    do: JPEG.step(state, chunk, chunk_offset)

  defp do_step(%{"phase" => "done"} = state, _chunk, _chunk_offset) do
    case state_result(state) do
      {:done, metadata} -> {:done, metadata, state}
      {:error, %Error{} = error} -> {:error, error, failed_state(state, error.code)}
    end
  end

  defp do_step(%{"phase" => "failed"} = state, _chunk, _chunk_offset) do
    case state_result(state) do
      {:error, %Error{} = error} -> {:error, error, state}
    end
  end

  defp do_step(state, _chunk, _chunk_offset),
    do: {:error, Error.new(:integrity_failure), failed_state(state, :integrity_failure)}

  defp terminal_result({:ok, metadata}, _state) do
    final_state = done_state(metadata)
    {:done, metadata, final_state}
  end

  defp terminal_result({:error, %Error{} = error}, state),
    do: {:error, error, failed_state(state, error.code)}

  defp terminal_result(_invalid, state) do
    error = Error.new(:integrity_failure)
    {:error, error, failed_state(state, error.code)}
  end

  defp validate_step_chunk(
         %{"plaintext_bytes" => plaintext_byte_size},
         chunk,
         chunk_offset
       )
       when is_integer(plaintext_byte_size) and plaintext_byte_size >= 0 and
              rem(chunk_offset, @chunk_size) == 0 and chunk_offset <= plaintext_byte_size do
    expected_size = min(@chunk_size, plaintext_byte_size - chunk_offset)

    if byte_size(chunk) == expected_size,
      do: :ok,
      else: {:error, Error.new(:integrity_failure)}
  end

  defp validate_step_chunk(%{"phase" => phase}, _chunk, _chunk_offset)
       when phase in ["done", "failed"],
       do: :ok

  defp validate_step_chunk(_state, _chunk, _chunk_offset),
    do: {:error, Error.new(:integrity_failure)}

  defp done_state(metadata) do
    %{
      "phase" => "done",
      "result" => %{
        "detected_media_type" => metadata.detected_media_type,
        "plaintext_bytes" => metadata.plaintext_bytes,
        "width" => metadata.width,
        "height" => metadata.height,
        "pdf_version" => metadata.pdf_version,
        "extractor_version" => metadata.extractor_version
      }
    }
  end

  defp failed_state(state, error_code) do
    state
    |> Map.take(["declared_media_type", "plaintext_bytes"])
    |> Map.merge(%{
      "phase" => "failed",
      "error_code" => Atom.to_string(error_code)
    })
  end

  defp metadata_from_json(
         %{
           "detected_media_type" => detected_media_type,
           "plaintext_bytes" => plaintext_bytes,
           "width" => width,
           "height" => height,
           "pdf_version" => pdf_version,
           "extractor_version" => extractor_version
         } = result
       ) do
    valid? =
      Enum.sort(Map.keys(result)) ==
        Enum.sort(
          ~w[detected_media_type plaintext_bytes width height pdf_version extractor_version]
        ) and detected_media_type in @supported_media_types and
        valid_plaintext_size?(plaintext_bytes) and
        extractor_version == 1 and
        valid_typed_metadata?(detected_media_type, width, height, pdf_version)

    if valid? do
      {:ok,
       %{
         detected_media_type: detected_media_type,
         plaintext_bytes: plaintext_bytes,
         width: width,
         height: height,
         pdf_version: pdf_version,
         extractor_version: extractor_version
       }}
    else
      {:error, Error.new(:integrity_failure)}
    end
  end

  defp metadata_from_json(_result), do: {:error, Error.new(:integrity_failure)}

  defp read_prefix(%{plaintext_byte_size: 0}), do: integrity_failure()

  defp read_prefix(reader) do
    requested_bytes = min(@prefix_bytes, reader.plaintext_byte_size)

    case reader.read_range.(0, requested_bytes) do
      {:ok, prefix} when is_binary(prefix) and byte_size(prefix) == requested_bytes ->
        {:ok, prefix}

      {:error, %Error{}} = error ->
        error

      _invalid ->
        integrity_failure()
    end
  end

  defp detect(<<"%PDF-", _rest::binary>>),
    do: {:ok, "application/pdf", PDF}

  defp detect(<<0xFF, 0xD8, _rest::binary>>),
    do: {:ok, "image/jpeg", JPEG}

  defp detect(<<137, "PNG\r\n", 26, 10, _rest::binary>>),
    do: {:ok, "image/png", PNG}

  defp detect(_prefix), do: {:error, Error.new(:unsupported_media_type)}

  defp declared_type_matches(media_type, media_type), do: :ok

  defp declared_type_matches(_declared_media_type, _detected_media_type),
    do: {:error, Error.new(:unsupported_media_type)}

  defp valid_typed_metadata?("application/pdf", nil, nil, pdf_version),
    do: valid_pdf_version?(pdf_version)

  defp valid_typed_metadata?("image/jpeg", width, height, nil),
    do: dimension?(width, 65_535) and dimension?(height, 65_535)

  defp valid_typed_metadata?("image/png", width, height, nil),
    do: dimension?(width, 2_147_483_647) and dimension?(height, 2_147_483_647)

  defp valid_typed_metadata?(_media_type, _width, _height, _pdf_version), do: false

  defp valid_media_type?(value),
    do:
      is_binary(value) and byte_size(value) > 0 and
        byte_size(value) <= @max_media_type_bytes

  defp valid_plaintext_size?(value),
    do: is_integer(value) and value >= 0 and value <= @max_bigint

  defp valid_pdf_version?(<<major, ?., minor>>),
    do: major in ?0..?9 and minor in ?0..?9

  defp valid_pdf_version?(_version), do: false

  defp dimension?(value, maximum),
    do: is_integer(value) and value in 1..maximum

  defp integrity_failure, do: {:error, Error.new(:integrity_failure)}
end
