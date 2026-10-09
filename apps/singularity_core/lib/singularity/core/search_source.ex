defmodule Singularity.Core.SearchSource do
  @moduledoc "An exact immutable source selector, without caller-selected owner scope."

  alias Singularity.Core.{Error, KnowledgeValidation, Types}

  @enforce_keys [:kind, :resource_id, :resource_version_id, :fragment_id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          kind: :note | :document,
          resource_id: Types.id(),
          resource_version_id: Types.id(),
          fragment_id: String.t() | nil
        }

  @spec new(term()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = input) do
    if map_size(input) == length(@enforce_keys) + 1 and
         Enum.all?(@enforce_keys, &Map.has_key?(input, &1)),
       do: new(Map.from_struct(input)),
       else: Types.invalid()
  end

  def new(input) do
    with {:ok, attrs} <- KnowledgeValidation.attrs(input, @enforce_keys),
         true <- map_size(attrs) == length(@enforce_keys),
         {:ok, kind} <- kind(attrs.kind),
         {:ok, resource_id} <- Types.canonical_uuid(attrs, :resource_id),
         {:ok, version_id} <- Types.canonical_uuid(attrs, :resource_version_id),
         :ok <- fragment(kind, attrs.fragment_id) do
      {:ok,
       %__MODULE__{
         kind: kind,
         resource_id: resource_id,
         resource_version_id: version_id,
         fragment_id: attrs.fragment_id
       }}
    else
      _ -> Types.invalid()
    end
  end

  @spec entry_id(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def entry_id(input) do
    with {:ok, source} <- new(input) do
      case source.kind do
        :note -> {:ok, "note:" <> source.resource_version_id}
        :document -> {:ok, "document:" <> source.fragment_id}
      end
    end
  end

  defp kind(value) when value in [:note, "note"], do: {:ok, :note}
  defp kind(value) when value in [:document, "document"], do: {:ok, :document}
  defp kind(_), do: Types.invalid()

  defp fragment(:note, nil), do: :ok

  defp fragment(:document, value) when is_binary(value) and byte_size(value) == 64 do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, value), do: :ok, else: Types.invalid()
  end

  defp fragment(_, _), do: Types.invalid()
end
