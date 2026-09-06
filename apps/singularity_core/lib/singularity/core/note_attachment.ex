defmodule Singularity.Core.NoteAttachment do
  @moduledoc "Validated private knowledge link shape; live target checks belong to persistence."
  alias Singularity.Core.{Error, KnowledgeValidation, Types}

  @enforce_keys [
    :note_resource_id,
    :note_resource_version_id,
    :owner_scope_id,
    :attachment_id,
    :target_resource_id,
    :target_resource_version_id,
    :classification,
    :target_kind,
    :ordinal,
    :role
  ]
  defstruct [
    :note_resource_id,
    :note_resource_version_id,
    :owner_scope_id,
    :attachment_id,
    :target_resource_id,
    :target_resource_version_id,
    :classification,
    :target_kind,
    :ordinal,
    :role,
    :label
  ]

  @type t :: %__MODULE__{
          note_resource_id: Types.id(),
          note_resource_version_id: Types.id(),
          owner_scope_id: Types.id(),
          attachment_id: Types.id(),
          target_resource_id: Types.id(),
          target_resource_version_id: Types.id(),
          classification: :private,
          target_kind: :asset | :note | :document,
          ordinal: non_neg_integer(),
          role: :source,
          label: String.t() | nil
        }
  @spec new(term()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = input), do: new(Map.from_struct(input))

  def new(input) do
    with {:ok, attrs} <-
           KnowledgeValidation.attrs(input, [
             :note_resource_id,
             :note_resource_version_id,
             :owner_scope_id,
             :attachment_id,
             :target_resource_id,
             :target_resource_version_id,
             :classification,
             :target_kind,
             :ordinal,
             :role,
             :label
           ]),
         {:ok, _} <- Types.canonical_uuid(attrs, :note_resource_id),
         {:ok, _} <- Types.canonical_uuid(attrs, :note_resource_version_id),
         {:ok, _} <- Types.canonical_uuid(attrs, :owner_scope_id),
         {:ok, _} <- Types.canonical_uuid(attrs, :attachment_id),
         {:ok, _} <- Types.canonical_uuid(attrs, :target_resource_id),
         {:ok, _} <- Types.canonical_uuid(attrs, :target_resource_version_id),
         :private <- attrs[:classification],
         true <- attrs[:target_kind] in [:asset, :note, :document],
         :source <- attrs[:role],
         true <- attrs.note_resource_id != attrs.target_resource_id,
         true <- attrs.note_resource_version_id != attrs.target_resource_version_id,
         {:ok, ordinal} <- KnowledgeValidation.integer(attrs[:ordinal]),
         {:ok, label} <- label(attrs[:label]) do
      {:ok, struct(__MODULE__, Map.merge(attrs, %{ordinal: ordinal, label: label}))}
    else
      _ -> Types.invalid()
    end
  end

  defp label(nil), do: {:ok, nil}

  defp label(value) do
    with {:ok, value} <- KnowledgeValidation.string(value, 255),
         {:ok, value} <- KnowledgeValidation.string(String.normalize(value, :nfc), 255),
         do: {:ok, value}
  end
end
