defmodule Singularity.Runtime.Backups.Status do
  @moduledoc "Reads one redacted backup status inside an authorized vault scope."

  alias Singularity.Core.Error
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.SessionContext
  alias Singularity.Storage.Postgres.BackupStatusStore

  @statuses [:pending, :waiting_for_backup_key, :copying, :sealed, :failed]
  @error_codes Error.codes()

  @spec run(map(), SessionContext.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def run(runtime, %SessionContext{} = session, operation_id)
      when is_map(runtime) and is_binary(operation_id) do
    with true <- valid_session?(session),
         {:ok, ^operation_id} <- Ecto.UUID.cast(operation_id),
         {:ok, adapters} <- adapters(runtime) do
      adapters.operation_scope
      |> call_adapter(:with_read_request, [
        runtime,
        session,
        requirement(session),
        fn repo ->
          call_adapter(adapters.backup_status_store, :fetch, [
            repo,
            %{operation_id: operation_id, vault_id: session.vault_id}
          ])
        end
      ])
      |> normalize_result(operation_id, session.vault_id)
    else
      _invalid -> invalid()
    end
  rescue
    _error -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  def run(_runtime, _session, _operation_id), do: invalid()

  defp requirement(session) do
    %{
      vault_id: session.vault_id,
      classification: :private,
      required_capability: "backup.create",
      requires_unlocked?: true
    }
  end

  defp adapters(runtime) do
    values = %{
      backup_status_store: Map.get(runtime, :backup_status_store, BackupStatusStore),
      operation_scope: Map.get(runtime, :operation_scope, OperationScope)
    }

    if Enum.all?(Map.values(values), &concrete?/1),
      do: {:ok, values},
      else: invalid()
  end

  defp normalize_result({:ok, status}, operation_id, vault_id),
    do: safe_status(status, operation_id, vault_id)

  defp normalize_result(
         {:error, %Error{code: code, retryable?: retryable?}},
         _operation_id,
         _vault_id
       )
       when code in @error_codes and is_boolean(retryable?),
       do: {:error, Error.new(code, retryable?: retryable?)}

  defp normalize_result({:error, _invalid}, _operation_id, _vault_id),
    do: storage_unavailable()

  defp normalize_result(_invalid, _operation_id, _vault_id),
    do: storage_unavailable()

  defp safe_status(
         %{
           operation_id: operation_id,
           vault_id: vault_id,
           status: status,
           requested_at: %DateTime{} = requested_at,
           updated_at: %DateTime{} = updated_at
         } = record,
         operation_id,
         vault_id
       )
       when not is_struct(record) and map_size(record) == 5 and status in @statuses do
    if valid_datetime?(requested_at) and valid_datetime?(updated_at) do
      {:ok,
       %{
         operation_id: operation_id,
         vault_id: vault_id,
         status: status,
         requested_at: requested_at,
         updated_at: updated_at
       }}
    else
      {:error, Error.new(:integrity_failure)}
    end
  end

  defp safe_status(_record, _operation_id, _vault_id),
    do: {:error, Error.new(:integrity_failure)}

  defp valid_session?(session) do
    valid_uuid?(session.session_id) and
      (is_nil(session.account_id) or valid_uuid?(session.account_id)) and
      valid_uuid?(session.principal_id) and valid_uuid?(session.vault_id) and
      valid_datetime?(session.expires_at) and
      valid_epoch?(session.principal_authorization_epoch) and
      valid_epoch?(session.vault_authorization_epoch) and
      valid_epoch?(session.authorization_epoch) and is_boolean(session.unlocked?)
  end

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, arguments)

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, [context | arguments])

  defp valid_uuid?(value), do: Ecto.UUID.cast(value) == {:ok, value}

  defp valid_datetime?(%DateTime{} = value) do
    with encoded when is_binary(encoded) <- DateTime.to_iso8601(value),
         {:ok, ^value, 0} <- DateTime.from_iso8601(encoded) do
      true
    else
      _invalid -> false
    end
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp valid_datetime?(_value), do: false

  defp valid_epoch?(value), do: is_integer(value) and value >= 0
  defp concrete?(value), do: value not in [nil, false]
  defp invalid, do: {:error, Error.new(:invalid)}
  defp storage_unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
