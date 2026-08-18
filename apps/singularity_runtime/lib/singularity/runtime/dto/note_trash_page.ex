defmodule Singularity.Runtime.DTO.NoteTrashPage do
  @moduledoc "One bounded page of tombstoned private note summaries."

  alias Singularity.Runtime.DTO.NoteSummary
  alias Singularity.Runtime.DTO.NoteValidation

  @fields [:items, :next_cursor]
  @enforce_keys @fields
  defstruct @fields

  @type item :: %{summary: NoteSummary.t(), deleted_at: DateTime.t()}
  @type t :: %__MODULE__{items: [item()], next_cursor: String.t() | nil}

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
      %{summary: %NoteSummary{} = summary, deleted_at: deleted_at} = item, {:ok, checked}
      when map_size(item) == 2 ->
        case {NoteSummary.new(Map.from_struct(summary)),
              NoteValidation.utc_datetime(%{deleted_at: deleted_at}, :deleted_at)} do
          {{:ok, %{deleted?: true} = rebuilt}, {:ok, timestamp}} ->
            {:cont, {:ok, [%{summary: rebuilt, deleted_at: timestamp} | checked]}}

          _invalid ->
            {:halt, NoteValidation.integrity_failure()}
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
