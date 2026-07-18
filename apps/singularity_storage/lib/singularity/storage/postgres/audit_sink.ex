defmodule Singularity.Storage.Postgres.AuditSink do
  @moduledoc false

  @behaviour Singularity.Core.AuditSink

  alias Singularity.Core.AuditEvent
  alias Singularity.Core.Error
  alias Singularity.Storage.Postgres.UUID
  alias Singularity.Storage.Schema.Audit.Event

  @postgres_constraint_codes [
    :integrity_constraint_violation,
    :restrict_violation,
    :not_null_violation,
    :foreign_key_violation,
    :unique_violation,
    :check_violation,
    :exclusion_violation
  ]

  @impl true
  def append(repo, %AuditEvent{} = event) do
    with :ok <- UUID.validate([event.audit_event_id, event.correlation_id]),
         :ok <- UUID.validate_optional([event.vault_id, event.principal_id]) do
      changeset =
        Event.append_changeset(%Event{}, %{
          id: event.audit_event_id,
          vault_id: event.vault_id,
          actor_kind: event.actor_kind,
          principal_id: event.principal_id,
          operation: event.action,
          result: :completed,
          classification: event.classification,
          correlation_id: event.correlation_id,
          metadata: event.metadata,
          occurred_at: event.occurred_at
        })

      case repo.insert(changeset) do
        {:ok, _stored} -> :ok
        {:error, %Ecto.Changeset{}} -> {:error, Error.new(:invalid)}
      end
    end
  rescue
    _error in [Ecto.Query.CastError] ->
      {:error, Error.new(:invalid)}

    error in [Ecto.ConstraintError, DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  def append(_repo, _event), do: {:error, Error.new(:invalid)}

  defp database_error(%Ecto.ConstraintError{type: :unique}), do: Error.new(:conflict)
  defp database_error(%Ecto.ConstraintError{}), do: Error.new(:invalid)

  defp database_error(%Postgrex.Error{postgres: %{code: :unique_violation}}),
    do: Error.new(:conflict)

  defp database_error(%Postgrex.Error{postgres: %{code: code}})
       when code in @postgres_constraint_codes,
       do: Error.new(:invalid)

  defp database_error(_error),
    do: Error.new(:storage_unavailable, retryable?: true)
end
