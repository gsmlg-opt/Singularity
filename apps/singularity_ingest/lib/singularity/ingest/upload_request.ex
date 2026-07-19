defmodule Singularity.Ingest.UploadRequest do
  @moduledoc "Validated, immutable binding for one browser upload."

  alias Singularity.Core.Error
  alias Singularity.Core.Types

  @default_max_bytes 512 * 1024 * 1024
  @media_types ["application/pdf", "image/jpeg", "image/png"]
  @classifications [:private, :sensitive, :restricted]

  @enforce_keys [
    :filename,
    :size,
    :declared_media_type,
    :idempotency_key,
    :resource_version_id,
    :classification,
    :max_bytes
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          filename: String.t(),
          size: non_neg_integer(),
          declared_media_type: String.t(),
          idempotency_key: String.t(),
          resource_version_id: String.t(),
          classification: :private | :sensitive | :restricted,
          max_bytes: non_neg_integer()
        }

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) do
    with {:ok, attrs} <- Types.attrs(attrs),
         {:ok, filename} <- Types.opaque_string(attrs, :filename),
         {:ok, size} <- Types.non_neg_integer(attrs, :size),
         {:ok, declared_media_type} <-
           Types.normalized_string(attrs, :declared_media_type),
         :ok <- supported_media_type(declared_media_type),
         {:ok, idempotency_key} <- Types.opaque_string(attrs, :idempotency_key),
         {:ok, resource_version_id} <-
           Types.opaque_string(attrs, :resource_version_id),
         {:ok, classification} <- classification(Map.get(attrs, :classification)),
         {:ok, max_bytes} <- max_bytes(attrs),
         :ok <- within_limit(size, max_bytes) do
      {:ok,
       %__MODULE__{
         filename: filename,
         size: size,
         declared_media_type: declared_media_type,
         idempotency_key: idempotency_key,
         resource_version_id: resource_version_id,
         classification: classification,
         max_bytes: max_bytes
       }}
    end
  end

  @spec detect_media_type(binary()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def detect_media_type(<<"%PDF-", _rest::binary>>), do: {:ok, "application/pdf"}
  def detect_media_type(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: {:ok, "image/jpeg"}

  def detect_media_type(<<137, 80, 78, 71, 13, 10, 26, 10, _rest::binary>>),
    do: {:ok, "image/png"}

  def detect_media_type(_bytes),
    do: {:error, Error.new(:unsupported_media_type)}

  @spec validate_magic(t(), binary()) :: :ok | {:error, Error.t()}
  def validate_magic(%__MODULE__{declared_media_type: expected}, bytes)
      when is_binary(bytes) do
    with {:ok, detected} <- detect_media_type(bytes),
         true <- detected == expected do
      :ok
    else
      false -> {:error, Error.new(:unsupported_media_type)}
      {:error, %Error{}} = error -> error
    end
  end

  def validate_magic(_request, _bytes),
    do: {:error, Error.new(:invalid)}

  @spec default_max_bytes() :: pos_integer()
  def default_max_bytes, do: @default_max_bytes

  defp max_bytes(attrs) do
    case Map.get(attrs, :max_bytes, @default_max_bytes) do
      max when is_integer(max) and max >= 0 -> {:ok, max}
      _invalid -> {:error, Error.new(:invalid)}
    end
  end

  defp supported_media_type(media_type) when media_type in @media_types, do: :ok

  defp supported_media_type(_media_type),
    do: {:error, Error.new(:unsupported_media_type)}

  defp classification(value) when value in @classifications, do: {:ok, value}
  defp classification(_value), do: {:error, Error.new(:invalid)}

  defp within_limit(size, maximum) when size <= maximum, do: :ok
  defp within_limit(_size, _maximum), do: {:error, Error.new(:upload_too_large)}
end
