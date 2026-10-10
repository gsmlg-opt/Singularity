defmodule Singularity.Runtime.DTO.NoteCitation do
  @moduledoc "Owner-free citation reference to an exact immutable source fragment."

  alias Singularity.Core.NoteCitationReference
  alias Singularity.Core.SourceLocator
  alias Singularity.Core.Error

  @fields ~w(citation_id source_resource_id source_resource_version_id fragment_id locator)a
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          citation_id: String.t(),
          source_resource_id: String.t(),
          source_resource_version_id: String.t(),
          fragment_id: String.t(),
          locator: SourceLocator.t()
        }

  @spec new(term()) :: {:ok, t()} | {:error, Singularity.Core.Error.t()}
  def new(%__MODULE__{} = value) do
    attrs = Map.from_struct(value)

    with {:ok, reference} <- NoteCitationReference.new(attrs),
         true <- Map.from_struct(reference) == attrs do
      {:ok, value}
    else
      _invalid -> integrity_failure()
    end
  end

  def new(%NoteCitationReference{} = value) do
    with {:ok, ^value} <- NoteCitationReference.new(value) do
      {:ok, struct!(__MODULE__, Map.from_struct(value))}
    else
      _invalid -> integrity_failure()
    end
  end

  def new(value) do
    with {:ok, reference} <- NoteCitationReference.new(value) do
      {:ok, struct!(__MODULE__, Map.from_struct(reference))}
    else
      _invalid -> integrity_failure()
    end
  end

  defp integrity_failure, do: {:error, Error.new(:integrity_failure)}
end
