defmodule Singularity.Runtime.DTO.NoteSearchPage do
  @moduledoc "One bounded page of private note summaries."

  alias Singularity.Runtime.DTO.NoteSummary
  alias Singularity.Runtime.DTO.NoteValidation

  @fields [:items, :next_cursor]
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{items: [NoteSummary.t()], next_cursor: String.t() | nil}

  @spec new(map()) :: {:ok, t()} | {:error, Singularity.Core.Error.t()}
  def new(attrs) do
    with {:ok, attrs} <- NoteValidation.exact_attrs(attrs, @fields),
         true <- is_list(attrs.items) and length(attrs.items) <= 50,
         {:ok, items} <- validate_items(attrs.items),
         true <- NoteValidation.cursor?(attrs.next_cursor) do
      {:ok, %__MODULE__{items: items, next_cursor: attrs.next_cursor}}
    else
      _invalid -> NoteValidation.integrity_failure()
    end
  end

  defp validate_items(items) do
    Enum.reduce_while(items, {:ok, []}, fn
      %NoteSummary{deleted?: false} = item, {:ok, checked} ->
        case NoteSummary.new(Map.from_struct(item)) do
          {:ok, rebuilt} -> {:cont, {:ok, [rebuilt | checked]}}
          _invalid -> {:halt, NoteValidation.integrity_failure()}
        end

      _item, _checked ->
        {:halt, NoteValidation.integrity_failure()}
    end)
    |> case do
      {:ok, checked} -> {:ok, Enum.reverse(checked)}
      error -> error
    end
  end
end
