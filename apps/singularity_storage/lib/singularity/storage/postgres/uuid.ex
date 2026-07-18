defmodule Singularity.Storage.Postgres.UUID do
  @moduledoc false

  alias Singularity.Core.Error

  @spec validate(term() | [term()]) :: :ok | {:error, Error.t()}
  def validate(values) when is_list(values) do
    if Enum.all?(values, &valid?/1),
      do: :ok,
      else: {:error, Error.new(:invalid)}
  end

  def validate(value), do: validate([value])

  @spec validate_optional([term()]) :: :ok | {:error, Error.t()}
  def validate_optional(values) when is_list(values) do
    values
    |> Enum.reject(&is_nil/1)
    |> validate()
  end

  @spec dump(term()) :: {:ok, binary()} | :error
  def dump(value) do
    with {:ok, uuid} <- cast(value) do
      Ecto.UUID.dump(uuid)
    end
  end

  @spec cast(term()) :: {:ok, Ecto.UUID.t()} | :error
  def cast(value) when is_binary(value) and byte_size(value) == 36,
    do: Ecto.UUID.cast(value)

  def cast(_value), do: :error

  defp valid?(value), do: match?({:ok, _uuid}, cast(value))
end
