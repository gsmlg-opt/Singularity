defmodule Singularity.Runtime.DTO.NoteConflict do
  @moduledoc "Web-safe references for one private note conflict."

  alias Singularity.Runtime.DTO.NoteValidation

  @fields ~w(
    conflict_id base_version_id observed_canonical_version_id competing_version_id
  )a
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          conflict_id: String.t(),
          base_version_id: String.t(),
          observed_canonical_version_id: String.t(),
          competing_version_id: String.t()
        }

  @spec fields() :: [atom()]
  def fields, do: @fields

  @spec new(map()) :: {:ok, t()} | {:error, Singularity.Core.Error.t()}
  def new(attrs) do
    with {:ok, attrs} <- NoteValidation.exact_attrs(attrs, @fields),
         {:ok, _conflict_id} <- NoteValidation.uuid(attrs, :conflict_id),
         {:ok, base_id} <- NoteValidation.uuid(attrs, :base_version_id),
         {:ok, canonical_id} <- NoteValidation.uuid(attrs, :observed_canonical_version_id),
         {:ok, competing_id} <- NoteValidation.uuid(attrs, :competing_version_id),
         true <- length(Enum.uniq([base_id, canonical_id, competing_id])) == 3 do
      {:ok, struct!(__MODULE__, attrs)}
    else
      _invalid -> NoteValidation.integrity_failure()
    end
  end
end
