defmodule Singularity.Retrieval.AssetSearchQuery do
  @moduledoc """
  Validated, vault-bound filters for technical asset metadata search.

  Query text is limited to 1,024 UTF-8 bytes and opaque cursors to 2,048 bytes.
  """

  alias Singularity.Core.Error
  alias Singularity.Core.Types

  @states [
    :staging,
    :uploaded,
    :verified,
    :available,
    :processing,
    :ready,
    :pending_delete,
    :deleted
  ]
  @media_types ["application/pdf", "image/jpeg", "image/png"]
  @fields [:vault_id, :q, :state, :media_type, :limit, :cursor]
  @string_fields Enum.map(@fields, &Atom.to_string/1)
  @max_query_bytes 1_024
  @max_cursor_bytes 2_048

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          vault_id: String.t(),
          q: String.t(),
          state: atom() | nil,
          media_type: String.t() | nil,
          limit: 1..50,
          cursor: String.t() | nil
        }

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(params) do
    with {:ok, params} <- Types.attrs(params),
         {:ok, params} <- canonical_params(params),
         {:ok, vault_id} <- required_nonblank(params, :vault_id),
         {:ok, q} <- query_text(params),
         {:ok, state} <- state(params),
         {:ok, media_type} <- media_type(params),
         {:ok, limit} <- limit(params),
         {:ok, cursor} <- optional_nonblank(params, :cursor) do
      {:ok,
       %__MODULE__{
         vault_id: vault_id,
         q: q,
         state: state,
         media_type: media_type,
         limit: limit,
         cursor: cursor
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

  defp required_nonblank(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) ->
        if String.valid?(value) and String.trim(value) != "",
          do: {:ok, value},
          else: invalid()

      _other ->
        invalid()
    end
  end

  defp optional_nonblank(params, key) do
    case Map.get(params, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        if byte_size(value) <= @max_cursor_bytes do
          required_nonblank(%{key => value}, key)
        else
          invalid()
        end

      _other ->
        invalid()
    end
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

  defp state(params) do
    case Map.get(params, :state) do
      nil ->
        {:ok, nil}

      value when value in @states ->
        {:ok, value}

      value when is_binary(value) ->
        case Enum.find(@states, &(Atom.to_string(&1) == value)) do
          nil -> invalid()
          state -> {:ok, state}
        end

      _other ->
        invalid()
    end
  end

  defp media_type(params) do
    case Map.get(params, :media_type) do
      nil -> {:ok, nil}
      value when value in @media_types -> {:ok, value}
      _other -> invalid()
    end
  end

  defp limit(params) do
    case Map.get(params, :limit, 20) do
      value when is_integer(value) and value in 1..50 -> {:ok, value}
      _other -> invalid()
    end
  end

  defp invalid, do: {:error, Error.new(:invalid)}
end
