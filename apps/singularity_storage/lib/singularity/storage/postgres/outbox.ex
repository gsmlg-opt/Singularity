defmodule Singularity.Storage.Postgres.Outbox do
  @moduledoc false

  @behaviour Singularity.Core.Outbox

  alias Ecto.Adapters.SQL
  alias Singularity.Core.Error
  alias Singularity.Core.OutboxEvent
  alias Singularity.Storage.Postgres.UUID
  alias Singularity.Storage.Schema.Core.OutboxEvent, as: StoredEvent

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
  def append(repo, %OutboxEvent{} = event) do
    with :ok <-
           UUID.validate([
             event.outbox_event_id,
             event.vault_id,
             event.principal_id,
             event.correlation_id,
             event.causation_id
           ]) do
      attrs = %{
        id: event.outbox_event_id,
        event_type: event.event_type,
        idempotency_key: event.idempotency_key,
        vault_id: event.vault_id,
        principal_id: event.principal_id,
        required_capability: event.required_capability,
        authorization_epoch: event.authorization_epoch,
        classification: event.classification,
        correlation_id: event.correlation_id,
        causation_id: event.causation_id,
        expected_entity_revision: event.expected_entity_revision,
        envelope_version: 1,
        payload: event.payload,
        occurred_at: event.occurred_at
      }

      case repo.insert(StoredEvent.create_changeset(%StoredEvent{}, attrs)) do
        {:ok, _stored} -> {:ok, event}
        {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset_error(changeset)}
      end
    end
  rescue
    _error in [Ecto.Query.CastError] ->
      {:error, Error.new(:invalid)}

    error in [Ecto.ConstraintError, DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  def append(_repo, _event), do: {:error, Error.new(:invalid)}

  @impl true
  def claim(
        repo,
        %{limit: limit, lease_seconds: lease_seconds, claim_token: claim_token}
      )
      when limit in 1..100 and lease_seconds in 1..3600 and is_binary(claim_token) do
    with {:ok, dumped_claim_token} <- UUID.dump(claim_token) do
      case SQL.query(
             repo,
             "SELECT * FROM core.claim_outbox_events($1, $2, $3)",
             [limit, lease_seconds, dumped_claim_token],
             log: false
           ) do
        {:ok, %{rows: rows}} ->
          rows
          |> Enum.reduce_while({:ok, []}, fn row, {:ok, events} ->
            case claimed_event(row) do
              {:ok, event} -> {:cont, {:ok, [event | events]}}
              {:error, %Error{}} = error -> {:halt, error}
            end
          end)
          |> case do
            {:ok, events} -> {:ok, Enum.reverse(events)}
            error -> error
          end

        {:error, _reason} ->
          {:error, Error.new(:storage_unavailable, retryable?: true)}
      end
    else
      :error -> {:error, Error.new(:invalid)}
    end
  end

  def claim(_repo, _options), do: {:error, Error.new(:invalid)}

  @impl true
  def acknowledge(
        repo,
        event_id,
        %{claim_token: claim_token, runner_job_id: runner_job_id}
      )
      when is_binary(event_id) and is_binary(claim_token) and is_binary(runner_job_id) do
    with {:ok, dumped_event_id} <- UUID.dump(event_id),
         {:ok, dumped_claim_token} <- UUID.dump(claim_token) do
      case SQL.query(
             repo,
             "SELECT core.acknowledge_outbox_event($1, $2, $3)",
             [dumped_event_id, dumped_claim_token, runner_job_id],
             log: false
           ) do
        {:ok, %{rows: [[true]]}} -> :ok
        {:ok, %{rows: [[false]]}} -> {:error, Error.new(:conflict)}
        {:error, _reason} -> {:error, Error.new(:storage_unavailable, retryable?: true)}
      end
    else
      :error -> {:error, Error.new(:invalid)}
    end
  end

  def acknowledge(_repo, _event_id, _options), do: {:error, Error.new(:invalid)}

  defp claimed_event([
         event_id,
         event_type,
         idempotency_key,
         vault_id,
         principal_id,
         required_capability,
         authorization_epoch,
         classification,
         correlation_id,
         causation_id,
         expected_entity_revision,
         _envelope_version,
         payload,
         occurred_at,
         _claim_token
       ]) do
    OutboxEvent.new(%{
      outbox_event_id: load_uuid(event_id),
      event_type: event_type,
      idempotency_key: idempotency_key,
      vault_id: load_uuid(vault_id),
      principal_id: load_uuid(principal_id),
      required_capability: required_capability,
      authorization_epoch: authorization_epoch,
      classification: classification(classification),
      correlation_id: load_uuid(correlation_id),
      causation_id: load_uuid(causation_id || event_id),
      expected_entity_revision: expected_entity_revision,
      payload: payload,
      occurred_at: occurred_at
    })
  end

  defp classification("private"), do: :private
  defp classification("sensitive"), do: :sensitive
  defp classification("restricted"), do: :restricted

  defp load_uuid(uuid), do: Ecto.UUID.load!(uuid)

  defp changeset_error(changeset) do
    if Enum.any?(changeset.errors, fn {_field, {_message, metadata}} ->
         metadata[:constraint] == :unique
       end),
       do: Error.new(:conflict),
       else: Error.new(:invalid)
  end

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
