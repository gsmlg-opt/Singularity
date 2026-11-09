defmodule Singularity.Retrieval.AssetSearchPage do
  @moduledoc "One bounded page of authorized asset metadata results."

  alias Singularity.Core.Error

  @enforce_keys [:items, :next_cursor]
  defstruct [:items, :next_cursor]

  @type t :: %__MODULE__{
          items: [map()],
          next_cursor: String.t() | nil
        }

  @spec new([map()], :done | String.t()) :: {:ok, t()} | {:error, Error.t()}
  def new(items, :done) when is_list(items),
    do: {:ok, %__MODULE__{items: items, next_cursor: nil}}

  def new(items, cursor) when is_list(items) and is_binary(cursor) do
    if String.trim(cursor) == "" do
      {:error, Error.new(:integrity_failure)}
    else
      {:ok, %__MODULE__{items: items, next_cursor: cursor}}
    end
  end

  def new(_items, _cursor), do: {:error, Error.new(:integrity_failure)}
end
