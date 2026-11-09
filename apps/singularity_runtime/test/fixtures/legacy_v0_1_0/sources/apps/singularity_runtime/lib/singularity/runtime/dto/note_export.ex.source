defmodule Singularity.Runtime.DTO.NoteExport do
  @moduledoc "Portable byte-exact Markdown export for one live canonical private note."

  alias Singularity.Runtime.DTO.NoteValidation

  @media_type "text/markdown; charset=utf-8"
  @unsafe_filename ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}\/\\]/u
  @fields [:resource_id, :resource_version_id, :filename, :media_type, :markdown]
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          resource_id: String.t(),
          resource_version_id: String.t(),
          filename: String.t(),
          media_type: String.t(),
          markdown: String.t()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Singularity.Core.Error.t()}
  def new(attrs) do
    with {:ok, attrs} <- NoteValidation.exact_attrs(attrs, @fields),
         {:ok, _resource_id} <- NoteValidation.uuid(attrs, :resource_id),
         {:ok, _version_id} <- NoteValidation.uuid(attrs, :resource_version_id),
         true <- safe_filename?(attrs.filename),
         true <- attrs.media_type == @media_type,
         true <- NoteValidation.markdown?(attrs.markdown) do
      {:ok, struct!(__MODULE__, attrs)}
    else
      _invalid -> NoteValidation.integrity_failure()
    end
  end

  defp safe_filename?(filename) when is_binary(filename) do
    byte_size(filename) in 1..258 and String.valid?(filename) and
      String.ends_with?(filename, ".md") and
      filename != ".md" and not Regex.match?(@unsafe_filename, filename)
  end

  defp safe_filename?(_filename), do: false
end
