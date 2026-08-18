defmodule Singularity.Retrieval.NoteSearchQuery do
  @moduledoc """
  Validated, vault-bound filters for private note lexical search.

  Query text is limited to 1,024 UTF-8 bytes and opaque cursors to 2,048 bytes.
  Classification is composed by the server and is never accepted from input.
  """

  alias Singularity.Core.Error
  alias Singularity.Core.Types

  @fields [:vault_id, :q, :limit, :cursor]
  @string_fields Enum.map(@fields, &Atom.to_string/1)
  @max_query_bytes 1_024
  @max_cursor_bytes 2_048

  @enforce_keys @fields ++ [:classification]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          vault_id: String.t(),
          q: String.t(),
          limit: 1..50,
          cursor: String.t() | nil,
          classification: :private
        }

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) do
    with {:ok, params} <- Types.attrs(params),
         {:ok, params} <- canonical_params(params),
         {:ok, vault_id} <- Types.canonical_uuid(params, :vault_id),
         {:ok, q} <- query_text(params),
         {:ok, limit} <- limit(params),
         {:ok, cursor} <- cursor(params) do
      {:ok,
       %__MODULE__{
         vault_id: vault_id,
         q: q,
         limit: limit,
         cursor: cursor,
         classification: :private
       }}
    end
  end

  defp canonical_params(params) do
    with :ok <- validate_keys(params) do
      Enum.reduce_while(@fields, {:ok, %{}}, fn key, {:ok, normalized} ->
        string_key = Atom.to_string(key)

        case {Map.fetch(params, key), Map.fetch(params, string_key)} do
          {:error, :error} ->
            {:cont, {:ok, normalized}}

          {{:ok, value}, :error} ->
            {:cont, {:ok, Map.put(normalized, key, value)}}

          {:error, {:ok, value}} ->
            {:cont, {:ok, Map.put(normalized, key, value)}}

          {{:ok, value}, {:ok, value}} ->
            {:cont, {:ok, Map.put(normalized, key, value)}}

          {{:ok, _atom_value}, {:ok, _string_value}} ->
            {:halt, invalid()}
        end
      end)
    end
  end

  defp validate_keys(params) do
    if Enum.all?(Map.keys(params), &(&1 in @fields or &1 in @string_fields)),
      do: :ok,
      else: invalid()
  end

  defp query_text(params) do
    case Map.get(params, :q, "") do
      value when is_binary(value) ->
        if byte_size(value) <= @max_query_bytes and String.valid?(value) and
             :binary.match(value, <<0>>) == :nomatch do
          {:ok, String.trim(value)}
        else
          invalid()
        end

      _other ->
        invalid()
    end
  end

  defp limit(params) do
    case Map.get(params, :limit, 20) do
      value when is_integer(value) and value in 1..50 -> {:ok, value}
      _other -> invalid()
    end
  end

  defp cursor(params) do
    case Map.get(params, :cursor) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        if byte_size(value) <= @max_cursor_bytes and String.valid?(value) and
             :binary.match(value, <<0>>) == :nomatch and String.trim(value) != "" do
          {:ok, value}
        else
          invalid()
        end

      _other ->
        invalid()
    end
  end

  defp invalid, do: {:error, Error.new(:invalid)}
end
