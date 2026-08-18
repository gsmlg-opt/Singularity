defmodule Singularity.Runtime.DTO.Note do
  @moduledoc "Web-safe canonical private note including Markdown."

  alias Singularity.Runtime.DTO.NoteSummary
  alias Singularity.Runtime.DTO.NoteValidation

  @summary_fields ~w(
    resource_id resource_version_id title revision display_version updated_at
    deleted? open_conflict_count
  )a
  @fields @summary_fields ++ [:markdown]
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          resource_id: String.t(),
          resource_version_id: String.t(),
          title: String.t(),
          revision: non_neg_integer(),
          display_version: pos_integer(),
          updated_at: DateTime.t(),
          deleted?: boolean(),
          open_conflict_count: non_neg_integer(),
          markdown: String.t()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Singularity.Core.Error.t()}
  def new(attrs) do
    with {:ok, attrs} <- NoteValidation.exact_attrs(attrs, @fields),
         {:ok, summary} <- NoteSummary.new(Map.take(attrs, @summary_fields)),
         false <- summary.deleted?,
         true <- NoteValidation.markdown?(attrs.markdown) do
      {:ok, struct!(__MODULE__, Map.put(Map.from_struct(summary), :markdown, attrs.markdown))}
    else
      _invalid -> NoteValidation.integrity_failure()
    end
  end
end
