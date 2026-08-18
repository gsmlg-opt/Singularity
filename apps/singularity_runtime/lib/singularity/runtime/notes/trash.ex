defmodule Singularity.Runtime.Notes.Trash do
  @moduledoc "Lists tombstoned private notes independently of lexical search."

  alias Singularity.Core.Error
  alias Singularity.Core.Types
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.SessionContext
  alias Singularity.Storage.Postgres.NoteRepository

  @fields [:limit, :cursor]
  @string_fields Enum.map(@fields, &Atom.to_string/1)

  @spec run(map(), SessionContext.t(), map() | keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def run(runtime, %SessionContext{} = session, params) when is_map(runtime) do
    with {:ok, page} <- page_params(params),
         {:ok, adapters} <- adapters(runtime) do
      call_adapter(adapters.operation_scope, :with_read_request, [
        runtime,
        session,
        requirement(session),
        fn repo ->
          call_adapter(adapters.note_repository, :trash, [repo, session.vault_id, page])
        end
      ])
    end
  rescue
    _error -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  def run(_runtime, _session, _params), do: invalid()

  defp page_params(params) do
    with {:ok, params} <- Types.attrs(params),
         true <- Enum.all?(Map.keys(params), &(&1 in @fields or &1 in @string_fields)),
         {:ok, normalized} <- normalize_keys(params),
         limit when is_integer(limit) and limit in 1..50 <- Map.get(normalized, :limit, 20),
         {:ok, cursor} <- cursor(Map.get(normalized, :cursor)) do
      {:ok, %{limit: limit, cursor: cursor}}
    else
      _invalid -> invalid()
    end
  end

  defp normalize_keys(params) do
    Enum.reduce_while(@fields, {:ok, %{}}, fn key, {:ok, normalized} ->
      string_key = Atom.to_string(key)

      case {Map.fetch(params, key), Map.fetch(params, string_key)} do
        {:error, :error} -> {:cont, {:ok, normalized}}
        {{:ok, value}, :error} -> {:cont, {:ok, Map.put(normalized, key, value)}}
        {:error, {:ok, value}} -> {:cont, {:ok, Map.put(normalized, key, value)}}
        {{:ok, value}, {:ok, value}} -> {:cont, {:ok, Map.put(normalized, key, value)}}
        _mismatch -> {:halt, invalid()}
      end
    end)
  end

  defp cursor(nil), do: {:ok, nil}

  defp cursor(value) when is_binary(value) do
    if byte_size(value) <= 2_048 and String.valid?(value) and String.trim(value) != "" and
         :binary.match(value, <<0>>) == :nomatch,
       do: {:ok, value},
       else: invalid()
  end

  defp cursor(_value), do: invalid()

  defp requirement(session) do
    %{
      vault_id: session.vault_id,
      required_capability: "note.read",
      classification: :private,
      requires_unlocked?: true
    }
  end

  defp adapters(runtime) do
    values = %{
      note_repository: Map.get(runtime, :note_repository, NoteRepository),
      operation_scope: Map.get(runtime, :operation_scope, OperationScope)
    }

    if Enum.all?(Map.values(values), &concrete?/1), do: {:ok, values}, else: invalid()
  end

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, arguments)

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, [context | arguments])

  defp concrete?(value), do: value not in [nil, false]
  defp invalid, do: {:error, Error.new(:invalid)}
  defp storage_unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
