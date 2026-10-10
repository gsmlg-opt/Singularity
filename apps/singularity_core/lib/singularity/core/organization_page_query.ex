defmodule Singularity.Core.OrganizationPageQuery do
  @moduledoc "Bounded organization page parameters without owner or selector fields."

  alias Singularity.Core.{Error, KnowledgeValidation, Types}

  @keys [:limit, :cursor]
  @enforce_keys @keys
  defstruct limit: 20, cursor: nil

  @type t :: %__MODULE__{
          limit: 1..50,
          cursor: String.t() | nil
        }

  @spec new(term()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = query), do: validate(query)

  def new(input) do
    with {:ok, attrs} <- KnowledgeValidation.attrs(input, @keys),
         {:ok, limit} <- KnowledgeValidation.integer(Map.get(attrs, :limit, 20), 1),
         true <- limit <= 50,
         {:ok, cursor} <- cursor(Map.get(attrs, :cursor)) do
      {:ok, %__MODULE__{limit: limit, cursor: cursor}}
    else
      _invalid -> Types.invalid()
    end
  end

  @doc "Revalidates the exact internal query shape without accepting public overrides."
  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = query) do
    with true <- Enum.sort(Map.keys(query)) == Enum.sort([:__struct__ | @keys]),
         {:ok, ^query} <- new(Map.from_struct(query)) do
      {:ok, query}
    else
      _invalid -> Types.invalid()
    end
  end

  def validate(_query), do: Types.invalid()

  defp cursor(nil), do: {:ok, nil}

  defp cursor(value) do
    with {:ok, value} <- KnowledgeValidation.string(value, 2048),
         true <- String.trim(value) != "" do
      {:ok, value}
    else
      _invalid -> Types.invalid()
    end
  end
end
