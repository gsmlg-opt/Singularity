defmodule Singularity.Core.Classification do
  @moduledoc "Ordered privacy classifications and their no-downgrade invariant."

  alias Singularity.Core.Error

  @rank %{private: 0, sensitive: 1, restricted: 2}

  @type t :: :private | :sensitive | :restricted

  @spec values() :: [t()]
  def values, do: [:private, :sensitive, :restricted]

  @spec new(term()) :: {:ok, t()} | {:error, Error.t()}
  def new(value) when is_map_key(@rank, value), do: {:ok, value}
  def new(_value), do: {:error, Error.new(:invalid)}

  @spec assert_not_downgraded(t(), t()) :: :ok | {:error, Error.t()}
  def assert_not_downgraded(source, derived) do
    if Map.fetch!(@rank, derived) >= Map.fetch!(@rank, source),
      do: :ok,
      else: {:error, Error.new(:forbidden)}
  end
end
