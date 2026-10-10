defmodule Singularity.Core.NoteCitationReference do
  @moduledoc "An owner-free citation reference to an immutable source fragment."

  alias Singularity.Core.{Error, KnowledgeValidation, SourceLocator, Types}

  @keys [:citation_id, :source_resource_id, :source_resource_version_id, :fragment_id, :locator]
  @enforce_keys @keys
  defstruct @enforce_keys

  @fragment_id ~r/\A[0-9a-f]{64}\z/

  @type t :: %__MODULE__{
          citation_id: Types.id(),
          source_resource_id: Types.id(),
          source_resource_version_id: Types.id(),
          fragment_id: String.t(),
          locator: SourceLocator.t()
        }

  @spec new(term()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = reference) do
    with true <- Map.keys(reference) |> Enum.sort() == Enum.sort([:__struct__ | @keys]),
         {:ok, ^reference} <- new(Map.from_struct(reference)) do
      {:ok, reference}
    else
      _invalid -> Types.invalid()
    end
  end

  def new(input) do
    with {:ok, attrs} <- KnowledgeValidation.attrs(input, @keys),
         {:ok, citation_id} <- Types.canonical_uuid(attrs, :citation_id),
         {:ok, source_resource_id} <- Types.canonical_uuid(attrs, :source_resource_id),
         {:ok, source_resource_version_id} <-
           Types.canonical_uuid(attrs, :source_resource_version_id),
         {:ok, fragment_id} <- fragment(attrs[:fragment_id]),
         {:ok, locator} <- locator(attrs[:locator]) do
      {:ok,
       %__MODULE__{
         citation_id: citation_id,
         source_resource_id: source_resource_id,
         source_resource_version_id: source_resource_version_id,
         fragment_id: fragment_id,
         locator: locator
       }}
    else
      _invalid -> Types.invalid()
    end
  end

  defp fragment(value) when is_binary(value) and byte_size(value) == 64 do
    if Regex.match?(@fragment_id, value), do: {:ok, value}, else: Types.invalid()
  end

  defp fragment(_value), do: Types.invalid()

  defp locator(%SourceLocator{} = locator) do
    with {:ok, ^locator} <- SourceLocator.new(locator) do
      {:ok, locator}
    else
      _invalid -> Types.invalid()
    end
  end

  defp locator(input), do: SourceLocator.new(input)
end
