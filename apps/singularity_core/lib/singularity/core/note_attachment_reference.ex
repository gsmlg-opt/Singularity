defmodule Singularity.Core.NoteAttachmentReference do
  @moduledoc "An owner-free attachment reference to an immutable source version."

  alias Singularity.Core.{Error, KnowledgeValidation, Types}

  @keys [
    :attachment_id,
    :target_resource_id,
    :target_resource_version_id,
    :target_kind,
    :role,
    :label
  ]
  @enforce_keys [:attachment_id, :target_resource_id, :target_resource_version_id, :target_kind]
  defstruct @enforce_keys ++ [role: :source, label: nil]

  @type t :: %__MODULE__{
          attachment_id: Types.id(),
          target_resource_id: Types.id(),
          target_resource_version_id: Types.id(),
          target_kind: :asset | :note | :document,
          role: :source,
          label: String.t() | nil
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
         {:ok, attachment_id} <- Types.canonical_uuid(attrs, :attachment_id),
         {:ok, target_resource_id} <- Types.canonical_uuid(attrs, :target_resource_id),
         {:ok, target_resource_version_id} <-
           Types.canonical_uuid(attrs, :target_resource_version_id),
         {:ok, target_kind} <- kind(attrs[:target_kind]),
         :ok <- role(Map.get(attrs, :role, :source)),
         {:ok, label} <- label(attrs[:label]) do
      {:ok,
       %__MODULE__{
         attachment_id: attachment_id,
         target_resource_id: target_resource_id,
         target_resource_version_id: target_resource_version_id,
         target_kind: target_kind,
         role: :source,
         label: label
       }}
    else
      _invalid -> Types.invalid()
    end
  end

  defp kind(value) when value in [:asset, :note, :document], do: {:ok, value}
  defp kind("asset"), do: {:ok, :asset}
  defp kind("note"), do: {:ok, :note}
  defp kind("document"), do: {:ok, :document}
  defp kind(_value), do: Types.invalid()

  defp role(value) when value in [:source, "source"], do: :ok
  defp role(_value), do: Types.invalid()

  defp label(nil), do: {:ok, nil}

  defp label(value) do
    with {:ok, value} <- KnowledgeValidation.string(value, 255),
         {:ok, normalized} <- KnowledgeValidation.string(String.normalize(value, :nfc), 255),
         do: {:ok, normalized}
  end
end
