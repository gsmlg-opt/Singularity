defmodule Singularity.Core.NoteSaveResult do
  @moduledoc "Internal note-save outcome containing only canonical references."

  alias Singularity.Core.Error
  alias Singularity.Core.Types

  @enforce_keys [:outcome, :resource_id, :canonical_version_id, :submitted_version_id]
  defstruct @enforce_keys ++ [:conflict_id]

  @type outcome :: :saved | :conflict

  @type t :: %__MODULE__{
          outcome: outcome(),
          resource_id: Types.id(),
          canonical_version_id: Types.id(),
          submitted_version_id: Types.id(),
          conflict_id: Types.id() | nil
        }

  @spec saved(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def saved(attrs), do: build(attrs, :saved)

  @spec conflict(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def conflict(attrs), do: build(attrs, :conflict)

  defp build(attrs, outcome) do
    with {:ok, attrs} <- Types.attrs(attrs),
         {:ok, resource_id} <- Types.canonical_uuid(attrs, :resource_id),
         {:ok, canonical_version_id} <- Types.canonical_uuid(attrs, :canonical_version_id),
         {:ok, submitted_version_id} <- Types.canonical_uuid(attrs, :submitted_version_id),
         {:ok, conflict_id} <-
           conflict_id(attrs, outcome, canonical_version_id, submitted_version_id) do
      {:ok,
       %__MODULE__{
         outcome: outcome,
         resource_id: resource_id,
         canonical_version_id: canonical_version_id,
         submitted_version_id: submitted_version_id,
         conflict_id: conflict_id
       }}
    end
  end

  defp conflict_id(attrs, :saved, canonical_version_id, submitted_version_id)
       when canonical_version_id == submitted_version_id do
    if is_nil(Map.get(attrs, :conflict_id)), do: {:ok, nil}, else: invalid()
  end

  defp conflict_id(_attrs, :saved, _canonical_version_id, _submitted_version_id), do: invalid()

  defp conflict_id(attrs, :conflict, canonical_version_id, submitted_version_id)
       when canonical_version_id != submitted_version_id do
    Types.canonical_uuid(attrs, :conflict_id)
  end

  defp conflict_id(_attrs, :conflict, _canonical_version_id, _submitted_version_id), do: invalid()

  defp invalid, do: {:error, Error.new(:invalid)}
end
