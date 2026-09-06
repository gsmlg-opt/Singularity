defmodule Singularity.Core.KnowledgeValidation do
  @moduledoc false
  alias Singularity.Core.{Error, Types}

  @spec attrs(term(), [atom()]) :: {:ok, map()} | {:error, Error.t()}
  def attrs(input, _keys) when is_struct(input), do: Types.invalid()

  def attrs(input, keys) when is_map(input) or is_list(input) do
    aliases = Map.new(keys, &{Atom.to_string(&1), &1})

    if is_map(input) or Keyword.keyword?(input) do
      Enum.reduce_while(input, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        normalized = if key in keys, do: key, else: Map.get(aliases, key)

        cond do
          is_nil(normalized) -> {:halt, Types.invalid()}
          Map.has_key?(acc, normalized) and acc[normalized] !== value -> {:halt, Types.invalid()}
          true -> {:cont, {:ok, Map.put(acc, normalized, value)}}
        end
      end)
    else
      Types.invalid()
    end
  end

  def attrs(_, _), do: Types.invalid()

  @spec integer(term(), non_neg_integer()) :: {:ok, non_neg_integer()} | {:error, Error.t()}
  def integer(value, minimum \\ 0)

  def integer(value, minimum)
      when is_integer(value) and value >= minimum and value <= 9_223_372_036_854_775_807,
      do: {:ok, value}

  def integer(_, _), do: Types.invalid()

  @spec string(term(), non_neg_integer()) :: {:ok, binary()} | {:error, Error.t()}
  def string(value, limit) when is_binary(value) and byte_size(value) <= limit do
    if String.valid?(value) and not String.contains?(value, <<0>>),
      do: {:ok, value},
      else: Types.invalid()
  end

  def string(_, _), do: Types.invalid()

  @spec bounded_name(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def bounded_name(value) when is_binary(value) do
    with true <- String.valid?(value),
         {:ok, trimmed} <- string(String.trim(value), 255),
         true <- trimmed != "" do
      {:ok, trimmed}
    else
      _ -> Types.invalid()
    end
  end

  def bounded_name(_), do: Types.invalid()

  @spec utc_datetime(map(), atom()) :: {:ok, DateTime.t()} | {:error, Error.t()}
  def utc_datetime(attrs, key) do
    with {:ok, value} <- Types.utc_datetime(attrs, key),
         %DateTime{
           calendar: Calendar.ISO,
           year: year,
           month: month,
           day: day,
           hour: hour,
           minute: minute,
           second: second,
           microsecond: {micro, precision}
         } <- value,
         true <-
           Enum.all?([year, month, day, hour, minute, second, micro, precision], &is_integer/1),
         true <- Calendar.ISO.valid_date?(year, month, day),
         true <- Calendar.ISO.valid_time?(hour, minute, second, {micro, precision}) do
      {:ok, value}
    else
      _ -> Types.invalid()
    end
  end
end
