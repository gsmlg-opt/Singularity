defmodule Singularity.Runtime.Documents.Read do
  @moduledoc "Authenticated, bounded reads of live canonical Documents."

  alias Singularity.Core.{DocumentVersion, Error, Types}
  alias Singularity.Runtime.{DownloadLease, KeyCustodian, OperationScope, SessionContext}
  alias Singularity.Storage.Crypto.Format
  alias Singularity.Storage.Postgres.DocumentRepository

  @max_limit 100
  @max_source_bytes 64 * 1024 * 1024

  def get(runtime, %SessionContext{} = session, resource_id),
    do:
      scoped(
        runtime,
        session,
        &call(repository(runtime), :get_live_scoped, [&1, scope(session), resource_id])
      )

  def list(runtime, %SessionContext{} = session, params) do
    with {:ok, params} <- validate_list_params(params),
         {:ok, cursor} <- decode_cursor(params.cursor),
         {:ok, %{items: items, next_cursor: next}} <-
           scoped(
             runtime,
             session,
             &call(repository(runtime), :list_live_scoped, [
               &1,
               scope(session),
               %{params | cursor: cursor}
             ])
           ) do
      {:ok,
       %{
         items: items,
         next_cursor:
           case next do
             {%DateTime{} = inserted_at, resource_id} -> encode_cursor(inserted_at, resource_id)
             nil -> nil
           end
       }}
    end
  end

  def status(runtime, %SessionContext{} = session, resource_id) do
    with {:ok, %DocumentVersion{} = document} <- get(runtime, session, resource_id) do
      {:ok,
       Map.take(document, [
         :resource_id,
         :resource_version_id,
         :state,
         :generation,
         :adapter_name,
         :format_version,
         :failure_code,
         :finished_at
       ])}
    end
  end

  def fragments(runtime, %SessionContext{} = session, resource_id) do
    scoped(
      runtime,
      session,
      &call(repository(runtime), :fragments_live_scoped, [&1, scope(session), resource_id])
    )
  end

  def download_original(runtime, %SessionContext{unlocked?: true} = session, resource_id) do
    with {:ok, binding} <-
           scoped(
             runtime,
             session,
             &call(repository(runtime), :source_live_scoped, [&1, scope(session), resource_id])
           ),
         true <- binding.source_byte_size in 0..@max_source_bytes,
         {:ok, preflight} <- lease(runtime, session, binding),
         :ok <- authenticate(preflight, runtime, binding),
         {:ok, delivery} <- lease(runtime, session, binding) do
      count = chunk_count(binding.source_byte_size)

      {:ok,
       %{
         byte_size: binding.source_byte_size,
         chunk_count: count,
         read_chunk: fn index -> read_delivery(runtime, delivery, index, count) end
       }}
    else
      false -> {:error, Error.new(:integrity_failure)}
      {:error, :waiting_for_unlock} -> {:error, Error.new(:vault_locked)}
      {:error, %Error{}} = error -> error
      _ -> {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  def download_original(_runtime, %SessionContext{}, _resource_id),
    do: {:error, Error.new(:vault_locked)}

  def download_original(_, _, _), do: {:error, Error.new(:invalid)}

  def validate_list_params(params) when is_map(params) and not is_struct(params) do
    keys = Map.keys(params)

    if Enum.all?(keys, &(&1 in [:limit, :cursor, "limit", "cursor"])) do
      limit = Map.get(params, :limit, Map.get(params, "limit", 50))
      cursor = Map.get(params, :cursor, Map.get(params, "cursor"))

      with true <- is_integer(limit) and limit in 1..@max_limit,
           true <- is_nil(cursor) or valid_cursor?(cursor) do
        {:ok, %{limit: limit, cursor: cursor}}
      else
        false -> {:error, Error.new(:invalid)}
      end
    else
      {:error, Error.new(:invalid)}
    end
  end

  def validate_list_params(_), do: {:error, Error.new(:invalid)}

  def encode_cursor(%DateTime{} = inserted_at, resource_id) do
    with {:ok, _} <- Types.canonical_uuid(%{resource_id: resource_id}, :resource_id) do
      [Integer.to_string(DateTime.to_unix(inserted_at, :microsecond)), resource_id]
      |> Enum.join(":")
      |> Base.url_encode64(padding: false)
    else
      _ -> nil
    end
  end

  def decode_cursor(nil), do: {:ok, nil}

  def decode_cursor(cursor) when is_binary(cursor) and byte_size(cursor) <= 128 do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [micros, resource_id] <- String.split(decoded, ":", parts: 2),
         {micros, ""} <- Integer.parse(micros),
         {:ok, datetime} <- DateTime.from_unix(micros, :microsecond),
         {:ok, _} <- Types.canonical_uuid(%{resource_id: resource_id}, :resource_id) do
      {:ok, {datetime, resource_id}}
    else
      _ -> {:error, Error.new(:invalid)}
    end
  end

  def decode_cursor(_), do: {:error, Error.new(:invalid)}

  defp valid_cursor?(cursor), do: match?({:ok, {_time, _id}}, decode_cursor(cursor))

  defp scoped(runtime, session, callback) do
    operation_scope = Map.get(runtime, :operation_scope, OperationScope)

    call(operation_scope, :with_read_request, [
      runtime,
      session,
      %{
        vault_id: session.vault_id,
        required_capability: "asset.read",
        classification: :private,
        requires_unlocked?: false
      },
      callback
    ])
  end

  defp lease(runtime, session, binding) do
    request = %{
      purpose: :document_source,
      access: :request,
      session_id: session.session_id,
      resource_version_id: binding.resource_version_id,
      vault_id: session.vault_id,
      principal_id: session.principal_id,
      required_capability: "asset.read",
      principal_authorization_epoch: session.principal_authorization_epoch,
      vault_authorization_epoch: session.vault_authorization_epoch,
      object_id: binding.object_id,
      object_generation: binding.object_generation
    }

    call(Map.get(runtime, :custodian, {KeyCustodian, KeyCustodian}), :lease, [request])
  end

  defp authenticate(lease, runtime, binding) do
    reader = Map.get(runtime, :authenticated_reader, DownloadLease)
    count = chunk_count(binding.source_byte_size)

    result =
      Enum.reduce_while(0..max(count - 1, 0), {:ok, :crypto.hash_init(:sha256), 0}, fn
        _index, {:ok, hash, size} when count == 0 ->
          {:halt, {:ok, hash, size}}

        index, {:ok, hash, size} ->
          case call(reader, :read_document_chunk, [lease, index]) do
            {:ok, bytes} when is_binary(bytes) ->
              {:cont, {:ok, :crypto.hash_update(hash, bytes), size + byte_size(bytes)}}

            {:error, reason} ->
              {:halt, {:error, reason}}

            _ ->
              {:halt, {:error, Error.new(:storage_unavailable, retryable?: true)}}
          end
      end)

    _ = call(reader, :revoke, [lease])

    with {:ok, hash, size} <- result,
         true <- size == binding.source_byte_size,
         true <- :crypto.hash_final(hash) == binding.source_digest do
      :ok
    else
      {:error, :waiting_for_unlock} -> {:error, :waiting_for_unlock}
      {:error, %Error{}} = error -> error
      _ -> {:error, Error.new(:integrity_failure)}
    end
  end

  defp read_delivery(_runtime, _lease, index, count)
       when not is_integer(index) or index < 0 or index >= count,
       do: {:error, Error.new(:invalid)}

  defp read_delivery(runtime, lease, index, _count) do
    reader = Map.get(runtime, :authenticated_reader, DownloadLease)
    call(reader, :read_document_chunk, [lease, index])
  end

  defp chunk_count(0), do: 0
  defp chunk_count(bytes), do: div(bytes + Format.chunk_size() - 1, Format.chunk_size())
  defp repository(runtime), do: Map.get(runtime, :document_repository, DocumentRepository)
  defp scope(session), do: %{principal_id: session.principal_id, owner_scope_id: session.vault_id}

  defp call(module, function, args) when is_atom(module), do: apply(module, function, args)
  defp call({module, context}, function, args), do: apply(module, function, [context | args])
end
