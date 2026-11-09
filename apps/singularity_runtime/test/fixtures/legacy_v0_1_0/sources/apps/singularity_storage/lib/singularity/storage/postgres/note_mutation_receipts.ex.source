defmodule Singularity.Storage.Postgres.NoteMutationReceipts do
  @moduledoc false

  alias Singularity.Core.Error
  alias Singularity.Storage.Postgres.UUID
  alias Singularity.Storage.SafeSQL

  @operations ~w(create save merge tombstone restore)
  @constraint_codes [
    :integrity_constraint_violation,
    :restrict_violation,
    :not_null_violation,
    :foreign_key_violation,
    :unique_violation,
    :check_violation,
    :exclusion_violation,
    :invalid_text_representation
  ]

  @spec with_claim(Ecto.Repo.t(), map(), (-> term())) ::
          {:ok, map()} | {:error, Error.t()}
  def with_claim(repo, claim, callback) when is_map(claim) and is_function(callback, 0) do
    with true <- repo.in_transaction?(),
         {:ok, canonical} <- canonical_claim(claim),
         {:ok, owner?} <- insert_pending(repo, canonical) do
      if owner?,
        do: complete_owned_claim(repo, canonical, claim, callback),
        else: replay(repo, canonical)
    else
      false -> invalid()
      {:error, %Error{}} = error -> error
    end
  rescue
    _error in [Ecto.Query.CastError, Ecto.CastError] ->
      {:error, Error.new(:invalid)}

    error in [Ecto.ConstraintError, DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  def with_claim(_repo, _claim, _callback), do: invalid()

  defp canonical_claim(%{
         vault_id: vault_id,
         principal_id: principal_id,
         mutation_id: mutation_id,
         operation: operation,
         request_fingerprint: <<_::binary-size(32)>> = request_fingerprint,
         resource_id: resource_id
       }) do
    with :ok <- UUID.validate([vault_id, principal_id, mutation_id, resource_id]),
         {:ok, operation} <- operation(operation) do
      {:ok,
       %{
         vault_id: vault_id,
         principal_id: principal_id,
         mutation_id: mutation_id,
         operation: operation,
         request_fingerprint: request_fingerprint,
         resource_id: resource_id
       }}
    end
  end

  defp canonical_claim(_claim), do: invalid()

  defp operation(operation) when is_atom(operation), do: operation(Atom.to_string(operation))
  defp operation(operation) when operation in @operations, do: {:ok, operation}
  defp operation(_operation), do: invalid()

  defp insert_pending(repo, claim) do
    now = DateTime.utc_now(:microsecond)

    case SafeSQL.query(
           repo,
           """
           INSERT INTO content.note_mutation_receipts (
             vault_id, principal_id, mutation_id, operation, request_fingerprint,
             state, resource_id, inserted_at
           ) VALUES ($1, $2, $3, $4, $5, 'pending', $6, $7)
           ON CONFLICT (vault_id, principal_id, mutation_id) DO NOTHING
           RETURNING mutation_id
           """,
           [
             Ecto.UUID.dump!(claim.vault_id),
             Ecto.UUID.dump!(claim.principal_id),
             Ecto.UUID.dump!(claim.mutation_id),
             claim.operation,
             claim.request_fingerprint,
             Ecto.UUID.dump!(claim.resource_id),
             now
           ]
         ) do
      {:ok, %{rows: [[mutation_id]]}} ->
        if Ecto.UUID.load!(mutation_id) == claim.mutation_id,
          do: {:ok, true},
          else: {:error, Error.new(:integrity_failure)}

      {:ok, %{rows: []}} ->
        {:ok, false}

      {:ok, _unexpected} ->
        {:error, Error.new(:integrity_failure)}

      {:error, error} ->
        {:error, database_error(error)}
    end
  end

  defp complete_owned_claim(repo, canonical, original_claim, callback) do
    case callback.() do
      {:ok, result} ->
        with {:ok, result} <- validate_result(canonical, original_claim, result),
             :ok <- complete(repo, canonical, result) do
          {:ok, result}
        end

      {:error, %Error{}} = error ->
        error

      _invalid ->
        invalid()
    end
  end

  defp validate_result(claim, original_claim, result) when is_map(result) do
    with {:ok, outcome} <- result_outcome(result),
         :ok <- validate_result_shape(outcome, result),
         :ok <- validate_result_operation(claim.operation, outcome),
         :ok <- UUID.validate(result.resource_id),
         true <- result.resource_id == claim.resource_id,
         :ok <- validate_result_ids(result),
         :ok <- validate_candidate_version(original_claim, result) do
      {:ok, result}
    else
      false -> invalid()
      {:error, %Error{}} = error -> error
    end
  end

  defp validate_result(_claim, _original_claim, _result), do: invalid()

  defp result_outcome(%{outcome: outcome})
       when outcome in ["saved", "conflict", "tombstoned", "restored"],
       do: {:ok, outcome}

  defp result_outcome(_result), do: invalid()

  defp validate_result_shape("saved", result),
    do: exact_keys(result, [:outcome, :resource_id, :version_id])

  defp validate_result_shape("conflict", result),
    do: exact_keys(result, [:outcome, :resource_id, :version_id, :conflict_id])

  defp validate_result_shape("tombstoned", result),
    do: exact_keys(result, [:outcome, :resource_id])

  defp validate_result_shape("restored", result),
    do: exact_keys(result, [:outcome, :resource_id, :version_id])

  defp exact_keys(result, keys) do
    if MapSet.new(Map.keys(result)) == MapSet.new(keys), do: :ok, else: invalid()
  end

  defp validate_result_operation(operation, "saved") when operation in ~w(create save merge),
    do: :ok

  defp validate_result_operation("save", "conflict"), do: :ok
  defp validate_result_operation("tombstone", "tombstoned"), do: :ok
  defp validate_result_operation("restore", "restored"), do: :ok
  defp validate_result_operation(_operation, _outcome), do: invalid()

  defp validate_result_ids(%{
         outcome: "conflict",
         version_id: version_id,
         conflict_id: conflict_id
       }),
       do: UUID.validate([version_id, conflict_id])

  defp validate_result_ids(%{outcome: outcome, version_id: version_id})
       when outcome in ["saved", "restored"],
       do: UUID.validate(version_id)

  defp validate_result_ids(%{outcome: "tombstoned"}), do: :ok

  defp validate_candidate_version(%{version_id: version_id}, %{version_id: version_id}),
    do: UUID.validate(version_id)

  defp validate_candidate_version(%{version_id: _candidate}, %{version_id: _result}),
    do: invalid()

  defp validate_candidate_version(_claim, _result), do: :ok

  defp complete(repo, claim, result) do
    version_id = Map.get(result, :version_id)
    conflict_id = Map.get(result, :conflict_id)

    case SafeSQL.query(
           repo,
           """
           UPDATE content.note_mutation_receipts
           SET state = 'completed', outcome = $4, version_id = $5, conflict_id = $6
           WHERE vault_id = $1
             AND principal_id = $2
             AND mutation_id = $3
             AND state = 'pending'
             AND resource_id = $7
           RETURNING outcome, resource_id, version_id, conflict_id
           """,
           [
             Ecto.UUID.dump!(claim.vault_id),
             Ecto.UUID.dump!(claim.principal_id),
             Ecto.UUID.dump!(claim.mutation_id),
             result.outcome,
             dump_optional(version_id),
             dump_optional(conflict_id),
             Ecto.UUID.dump!(claim.resource_id)
           ]
         ) do
      {:ok, %{rows: [[outcome, resource_id, stored_version_id, stored_conflict_id]]}} ->
        stored = result_map(outcome, resource_id, stored_version_id, stored_conflict_id)

        if stored == result,
          do: enforce_completed_constraints(repo),
          else: {:error, Error.new(:integrity_failure)}

      {:ok, _unexpected} ->
        {:error, Error.new(:integrity_failure)}

      {:error, error} ->
        {:error, database_error(error)}
    end
  end

  defp enforce_completed_constraints(repo) do
    constraints =
      """
      content.note_mutation_receipts_resource_fkey,
      content.note_mutation_receipts_version_fkey,
      content.note_mutation_receipts_conflict_fkey,
      content.note_mutation_receipts_resource_check
      """
      |> String.replace("\n", " ")

    case SafeSQL.query(repo, "SET CONSTRAINTS #{constraints} IMMEDIATE", []) do
      {:ok, _result} -> restore_deferred_constraints(repo, constraints)
      {:error, error} -> {:error, database_error(error)}
    end
  end

  defp restore_deferred_constraints(repo, constraints) do
    case SafeSQL.query(repo, "SET CONSTRAINTS #{constraints} DEFERRED", []) do
      {:ok, _result} -> :ok
      {:error, error} -> {:error, database_error(error)}
    end
  end

  defp replay(repo, claim) do
    case SafeSQL.query(
           repo,
           """
           SELECT vault_id, principal_id, mutation_id, operation, request_fingerprint,
                  state, outcome, resource_id, version_id, conflict_id
           FROM content.note_mutation_receipts
           WHERE vault_id = $1 AND principal_id = $2 AND mutation_id = $3
           FOR UPDATE
           """,
           [
             Ecto.UUID.dump!(claim.vault_id),
             Ecto.UUID.dump!(claim.principal_id),
             Ecto.UUID.dump!(claim.mutation_id)
           ]
         ) do
      {:ok,
       %{
         rows: [
           [
             vault_id,
             principal_id,
             mutation_id,
             operation,
             request_fingerprint,
             "completed",
             outcome,
             resource_id,
             version_id,
             conflict_id
           ]
         ]
       }} ->
        with true <- Ecto.UUID.load!(vault_id) == claim.vault_id,
             true <- Ecto.UUID.load!(principal_id) == claim.principal_id,
             true <- Ecto.UUID.load!(mutation_id) == claim.mutation_id,
             true <- operation == claim.operation,
             true <- request_fingerprint == claim.request_fingerprint,
             true <- resource_matches?(operation, resource_id, claim.resource_id),
             result <- result_map(outcome, resource_id, version_id, conflict_id),
             {:ok, ^result} <- validate_replayed_result(operation, result) do
          {:ok, result}
        else
          false -> invalid()
          {:error, %Error{}} = error -> error
        end

      {:ok, %{rows: [_pending_or_malformed]}} ->
        {:error, Error.new(:integrity_failure)}

      {:ok, %{rows: []}} ->
        {:error, Error.new(:integrity_failure)}

      {:ok, _unexpected} ->
        {:error, Error.new(:integrity_failure)}

      {:error, error} ->
        {:error, database_error(error)}
    end
  end

  defp resource_matches?("create", _stored_resource_id, _candidate_resource_id), do: true

  defp resource_matches?(_operation, stored_resource_id, candidate_resource_id),
    do: Ecto.UUID.load!(stored_resource_id) == candidate_resource_id

  defp validate_replayed_result(operation, result) do
    with {:ok, outcome} <- result_outcome(result),
         :ok <- validate_result_shape(outcome, result),
         :ok <- validate_result_operation(operation, outcome),
         :ok <- UUID.validate(Map.values(Map.drop(result, [:outcome]))) do
      {:ok, result}
    end
  end

  defp result_map("saved", resource_id, version_id, nil),
    do: %{
      outcome: "saved",
      resource_id: load_uuid(resource_id),
      version_id: load_uuid(version_id)
    }

  defp result_map("conflict", resource_id, version_id, conflict_id),
    do: %{
      outcome: "conflict",
      resource_id: load_uuid(resource_id),
      version_id: load_uuid(version_id),
      conflict_id: load_uuid(conflict_id)
    }

  defp result_map("tombstoned", resource_id, nil, nil),
    do: %{outcome: "tombstoned", resource_id: load_uuid(resource_id)}

  defp result_map("restored", resource_id, version_id, nil),
    do: %{
      outcome: "restored",
      resource_id: load_uuid(resource_id),
      version_id: load_uuid(version_id)
    }

  defp result_map(_outcome, _resource_id, _version_id, _conflict_id),
    do: %{outcome: "invalid", resource_id: "invalid"}

  defp dump_optional(nil), do: nil
  defp dump_optional(uuid), do: Ecto.UUID.dump!(uuid)
  defp load_uuid(nil), do: nil
  defp load_uuid(uuid), do: Ecto.UUID.load!(uuid)

  defp database_error(%Ecto.ConstraintError{type: :unique}), do: Error.new(:conflict)
  defp database_error(%Ecto.ConstraintError{}), do: Error.new(:invalid)

  defp database_error(%Postgrex.Error{postgres: %{code: :unique_violation}}),
    do: Error.new(:conflict)

  defp database_error(%Postgrex.Error{postgres: %{code: code}}) when code in @constraint_codes,
    do: Error.new(:invalid)

  defp database_error(_error), do: Error.new(:storage_unavailable, retryable?: true)

  defp invalid, do: {:error, Error.new(:invalid)}
end
