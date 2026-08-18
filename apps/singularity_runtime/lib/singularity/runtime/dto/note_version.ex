defmodule Singularity.Runtime.DTO.NoteVersion do
  @moduledoc "Authorized immutable private note version including source text."

  alias Singularity.Runtime.DTO.NoteVersionSummary
  alias Singularity.Runtime.DTO.NoteValidation

  @summary_fields ~w(
    resource_version_id revision display_version created_by_principal_id inserted_at
    parent_version_id merge_parent_version_id canonical? conflict_state
  )a
  @fields @summary_fields ++ [:resource_id, :title, :markdown]
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{}

  @spec new(map()) :: {:ok, t()} | {:error, Singularity.Core.Error.t()}
  def new(attrs) do
    with {:ok, attrs} <- NoteValidation.exact_attrs(attrs, @fields),
         {:ok, summary} <- NoteVersionSummary.new(Map.take(attrs, @summary_fields)),
         {:ok, _resource_id} <- NoteValidation.uuid(attrs, :resource_id),
         true <- NoteValidation.title?(attrs.title),
         true <- NoteValidation.markdown?(attrs.markdown) do
      {:ok,
       struct!(
         __MODULE__,
         Map.merge(Map.from_struct(summary), Map.take(attrs, [:resource_id, :title, :markdown]))
       )}
    else
      _invalid -> NoteValidation.integrity_failure()
    end
  end
end
