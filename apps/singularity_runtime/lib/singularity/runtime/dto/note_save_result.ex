defmodule Singularity.Runtime.DTO.NoteSaveResult do
  @moduledoc "Web-safe saved or preserved-conflict result for a private note mutation."

  alias Singularity.Runtime.DTO.Note
  alias Singularity.Runtime.DTO.NoteValidation

  @fields [:outcome, :canonical, :submitted_version_id, :conflict_id]
  @enforce_keys [:outcome, :canonical, :submitted_version_id]
  defstruct @fields

  @type t :: %__MODULE__{
          outcome: :saved | :conflict,
          canonical: Note.t(),
          submitted_version_id: String.t(),
          conflict_id: String.t() | nil
        }

  @spec new(map()) :: {:ok, t()} | {:error, Singularity.Core.Error.t()}
  def new(attrs) when is_map(attrs) do
    attrs = if is_struct(attrs), do: Map.from_struct(attrs), else: attrs
    keys = MapSet.new(Map.keys(attrs))
    saved_keys = MapSet.new([:outcome, :canonical, :submitted_version_id])
    complete_keys = MapSet.new(@fields)

    with true <- keys == saved_keys or keys == complete_keys,
         %Note{} = canonical <- Map.get(attrs, :canonical),
         {:ok, ^canonical} <- Note.new(Map.from_struct(canonical)),
         false <- canonical.deleted?,
         {:ok, submitted_id} <- NoteValidation.uuid(attrs, :submitted_version_id),
         {:ok, conflict_id} <- NoteValidation.optional_uuid(attrs, :conflict_id),
         :ok <- validate_outcome(Map.get(attrs, :outcome), canonical, submitted_id, conflict_id) do
      {:ok,
       %__MODULE__{
         outcome: attrs.outcome,
         canonical: canonical,
         submitted_version_id: submitted_id,
         conflict_id: conflict_id
       }}
    else
      _invalid -> NoteValidation.integrity_failure()
    end
  end

  def new(_attrs), do: NoteValidation.integrity_failure()

  defp validate_outcome(:saved, canonical, submitted_id, nil)
       when canonical.resource_version_id == submitted_id,
       do: :ok

  defp validate_outcome(:conflict, canonical, submitted_id, conflict_id)
       when canonical.resource_version_id != submitted_id and not is_nil(conflict_id),
       do: :ok

  defp validate_outcome(_outcome, _canonical, _submitted_id, _conflict_id),
    do: NoteValidation.integrity_failure()
end
