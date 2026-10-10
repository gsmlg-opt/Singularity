defmodule Singularity.Runtime.DTO.NoteAttachment do
  @moduledoc "Owner-free attachment reference to an exact immutable source version."

  alias Singularity.Core.NoteAttachmentReference
  alias Singularity.Core.Error

  @fields ~w(attachment_id target_resource_id target_resource_version_id target_kind role label)a
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          attachment_id: String.t(),
          target_resource_id: String.t(),
          target_resource_version_id: String.t(),
          target_kind: :asset | :note | :document,
          role: :source,
          label: String.t() | nil
        }

  @spec new(term()) :: {:ok, t()} | {:error, Singularity.Core.Error.t()}
  def new(%__MODULE__{} = value) do
    attrs = Map.from_struct(value)

    with {:ok, reference} <- NoteAttachmentReference.new(attrs),
         true <- Map.from_struct(reference) == attrs do
      {:ok, value}
    else
      _invalid -> integrity_failure()
    end
  end

  def new(%NoteAttachmentReference{} = value) do
    with {:ok, ^value} <- NoteAttachmentReference.new(value) do
      {:ok, struct!(__MODULE__, Map.from_struct(value))}
    else
      _invalid -> integrity_failure()
    end
  end

  def new(value) do
    with {:ok, reference} <- NoteAttachmentReference.new(value) do
      {:ok, struct!(__MODULE__, Map.from_struct(reference))}
    else
      _invalid -> integrity_failure()
    end
  end

  defp integrity_failure, do: {:error, Error.new(:integrity_failure)}
end
