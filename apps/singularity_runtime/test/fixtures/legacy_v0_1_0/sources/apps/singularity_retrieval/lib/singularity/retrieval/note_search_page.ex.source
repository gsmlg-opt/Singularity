defmodule Singularity.Retrieval.NoteSearchPage do
  @moduledoc "One bounded page of private note search summaries."

  alias Singularity.Core.Error

  @max_cursor_bytes 2_048

  @enforce_keys [:items, :next_cursor]
  defstruct [:items, :next_cursor]

  @type t :: %__MODULE__{
          items: list(),
          next_cursor: String.t() | nil
        }

  @spec new(list(), :done | String.t()) :: {:ok, t()} | {:error, Error.t()}
  def new(items, cursor) when is_list(items) do
    case normalize_cursor(cursor) do
      {:ok, next_cursor} -> {:ok, %__MODULE__{items: items, next_cursor: next_cursor}}
      {:error, %Error{}} = error -> error
    end
  end

  def new(_items, _cursor), do: integrity_failure()

  defp normalize_cursor(:done), do: {:ok, nil}

  defp normalize_cursor(cursor) when is_binary(cursor) do
    if byte_size(cursor) <= @max_cursor_bytes and String.valid?(cursor) and
         :binary.match(cursor, <<0>>) == :nomatch and String.trim(cursor) != "" do
      {:ok, cursor}
    else
      integrity_failure()
    end
  end

  defp normalize_cursor(_cursor), do: integrity_failure()

  defp integrity_failure, do: {:error, Error.new(:integrity_failure)}
end
