defmodule Singularity.Runtime.DTO.NoteConflictDetail do
  @moduledoc "Authorized merge sources for one private note conflict."

  alias Singularity.Runtime.DTO.NoteVersion
  alias Singularity.Runtime.DTO.NoteValidation

  @fields [
    :conflict_id,
    :base_version_id,
    :observed_canonical_version_id,
    :current,
    :competing
  ]
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          conflict_id: String.t(),
          base_version_id: String.t(),
          observed_canonical_version_id: String.t(),
          current: NoteVersion.t(),
          competing: NoteVersion.t()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Singularity.Core.Error.t()}
  def new(attrs) do
    with {:ok, attrs} <- NoteValidation.exact_attrs(attrs, @fields),
         {:ok, _conflict_id} <- NoteValidation.uuid(attrs, :conflict_id),
         {:ok, base_id} <- NoteValidation.uuid(attrs, :base_version_id),
         {:ok, observed_id} <- NoteValidation.uuid(attrs, :observed_canonical_version_id),
         %NoteVersion{} = current <- attrs.current,
         {:ok, ^current} <- NoteVersion.new(Map.from_struct(current)),
         %NoteVersion{} = competing <- attrs.competing,
         {:ok, ^competing} <- NoteVersion.new(Map.from_struct(competing)),
         true <- current.resource_id == competing.resource_id,
         true <- current.canonical?,
         true <- not competing.canonical?,
         true <- competing.conflict_state in [:open, :resolved],
         true <- current.resource_version_id != competing.resource_version_id,
         true <- length(Enum.uniq([base_id, observed_id, competing.resource_version_id])) == 3 do
      {:ok, struct!(__MODULE__, attrs)}
    else
      _invalid -> NoteValidation.integrity_failure()
    end
  end
end
