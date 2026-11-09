defmodule Singularity.Runtime.DTO.NoteVersionSummary do
  @moduledoc "Web-safe metadata for one immutable private note version."

  alias Singularity.Runtime.DTO.NoteValidation

  @fields ~w(
    resource_version_id revision display_version created_by_principal_id inserted_at
    parent_version_id merge_parent_version_id canonical? conflict_state
  )a
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          resource_version_id: String.t(),
          revision: non_neg_integer(),
          display_version: pos_integer(),
          created_by_principal_id: String.t(),
          inserted_at: DateTime.t(),
          parent_version_id: String.t() | nil,
          merge_parent_version_id: String.t() | nil,
          canonical?: boolean(),
          conflict_state: :open | :resolved | nil
        }

  @spec new(map()) :: {:ok, t()} | {:error, Singularity.Core.Error.t()}
  def new(attrs) do
    with {:ok, attrs} <- NoteValidation.exact_attrs(attrs, @fields),
         {:ok, _version_id} <- NoteValidation.uuid(attrs, :resource_version_id),
         true <- is_integer(attrs.revision) and attrs.revision >= 0,
         true <- attrs.display_version == attrs.revision + 1,
         {:ok, _principal_id} <- NoteValidation.uuid(attrs, :created_by_principal_id),
         {:ok, _inserted_at} <- NoteValidation.utc_datetime(attrs, :inserted_at),
         {:ok, parent_id} <- NoteValidation.optional_uuid(attrs, :parent_version_id),
         {:ok, merge_parent_id} <- NoteValidation.optional_uuid(attrs, :merge_parent_version_id),
         true <- is_boolean(attrs.canonical?),
         true <- attrs.conflict_state in [nil, :open, :resolved],
         true <- is_nil(attrs.conflict_state) or not attrs.canonical?,
         true <- valid_parent_shape?(attrs.revision, parent_id, merge_parent_id) do
      {:ok, struct!(__MODULE__, attrs)}
    else
      _invalid -> NoteValidation.integrity_failure()
    end
  end

  defp valid_parent_shape?(0, nil, nil), do: true

  defp valid_parent_shape?(revision, parent_id, merge_parent_id)
       when is_integer(revision) and revision > 0 and not is_nil(parent_id) do
    is_nil(merge_parent_id) or merge_parent_id != parent_id
  end

  defp valid_parent_shape?(_revision, _parent_id, _merge_parent_id), do: false
end
