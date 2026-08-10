defmodule Singularity.Runtime.BackupStatusTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Runtime.Backups.Status
  alias Singularity.Runtime.SessionContext

  @session_id "00000000-0000-4000-8000-000000001801"
  @principal_id "00000000-0000-4000-8000-000000001802"
  @vault_id "00000000-0000-4000-8000-000000001803"
  @other_vault_id "00000000-0000-4000-8000-000000001804"
  @operation_id "00000000-0000-4000-8000-000000001805"
  @requested_at ~U[2026-08-10 08:00:00.000000Z]
  @updated_at ~U[2026-08-10 08:01:00.000000Z]

  defmodule Scope do
    def with_read_request(owner, runtime, session, requirement, callback) do
      send(owner, {:scope, runtime, session, requirement})

      case Process.get(:backup_status_scope_result) do
        nil -> callback.(:scoped_repo)
        :raise -> raise "scope-secret"
        :throw -> throw("scope-secret")
        result -> result
      end
    end
  end

  defmodule Store do
    def fetch(owner, repo, selector) do
      send(owner, {:store, repo, selector})

      case Process.get(:backup_status_store_result) do
        nil ->
          {:ok,
           %{
             operation_id: selector.operation_id,
             vault_id: selector.vault_id,
             status: :pending,
             requested_at: ~U[2026-08-10 08:00:00.000000Z],
             updated_at: ~U[2026-08-10 08:01:00.000000Z]
           }}

        :raise ->
          raise "store-secret"

        :throw ->
          throw("store-secret")

        result ->
          result
      end
    end
  end

  setup do
    on_exit(fn ->
      Process.delete(:backup_status_scope_result)
      Process.delete(:backup_status_store_result)
    end)
  end

  test "authorizes one unlocked private backup read and fetches under the scoped repo" do
    runtime = runtime()
    session = session()

    assert {:ok,
            %{
              operation_id: @operation_id,
              vault_id: @vault_id,
              status: :pending,
              requested_at: @requested_at,
              updated_at: @updated_at
            }} = Status.run(runtime, session, @operation_id)

    assert_receive {:scope, ^runtime, ^session,
                    %{
                      vault_id: @vault_id,
                      classification: :private,
                      required_capability: "backup.create",
                      requires_unlocked?: true
                    }}

    assert_receive {:store, :scoped_repo,
                    %{operation_id: @operation_id, vault_id: @vault_id} = selector}

    assert map_size(selector) == 2
  end

  test "preserves stable scope and storage errors without their secret details" do
    for code <- [:unauthenticated, :vault_locked, :forbidden, :not_found] do
      Process.put(
        :backup_status_scope_result,
        {:error, Error.new(code, message: "scope-secret", details: %{secret: "scope-secret"})}
      )

      assert {:error, %Error{code: ^code, message: nil, details: %{}}} =
               Status.run(runtime(), session(), @operation_id)

      refute_received {:store, _repo, _selector}
    end

    Process.delete(:backup_status_scope_result)

    Process.put(
      :backup_status_store_result,
      {:error,
       Error.new(:storage_unavailable,
         message: "storage-secret",
         details: %{secret: "storage-secret"},
         retryable?: true
       )}
    )

    assert {:error,
            %Error{
              code: :storage_unavailable,
              message: nil,
              details: %{},
              retryable?: true
            }} = Status.run(runtime(), session(), @operation_id)
  end

  test "missing and cross-vault storage lookups remain the same not_found result" do
    for lookup <- [:missing, :cross_vault] do
      Process.put(
        :backup_status_store_result,
        {:error,
         Error.new(:not_found,
           message: "#{lookup}-secret",
           details: %{lookup: lookup}
         )}
      )

      assert {:error, %Error{code: :not_found, message: nil, details: %{}}} =
               Status.run(runtime(), session(), @operation_id)
    end
  end

  test "rejects invalid arguments and missing or false adapters before authorization" do
    invalid_session = Map.from_struct(session())

    for {runtime, session, operation_id} <- [
          {runtime(), invalid_session, @operation_id},
          {runtime(), session(), "not-a-uuid"},
          {runtime(), session(), nil},
          {Map.put(runtime(), :operation_scope, nil), session(), @operation_id},
          {Map.put(runtime(), :backup_status_store, false), session(), @operation_id},
          {:not_a_runtime, session(), @operation_id}
        ] do
      assert {:error, %Error{code: :invalid, message: nil, details: %{}}} =
               Status.run(runtime, session, operation_id)
    end

    refute_received {:scope, _runtime, _session, _requirement}
    refute_received {:store, _repo, _selector}
  end

  test "rejects malformed and mismatched status records without returning their data" do
    secret = "BACKUP_STATUS_RECORD_SECRET"

    malformed = [
      %{status_record() | operation_id: Ecto.UUID.generate()},
      %{status_record() | vault_id: @other_vault_id},
      %{status_record() | status: :valid},
      %{status_record() | requested_at: NaiveDateTime.utc_now()},
      %{status_record() | updated_at: struct(DateTime)},
      Map.put(status_record(), :destination_ref, secret),
      %{operation_id: @operation_id},
      {:status, secret},
      {:error, secret}
    ]

    for value <- malformed do
      Process.put(:backup_status_store_result, {:ok, value})

      assert {:error, %Error{code: :integrity_failure} = error} =
               Status.run(runtime(), session(), @operation_id)

      refute inspect(error) =~ secret
    end
  end

  test "contains adapter exceptions and throws as sanitized storage failures" do
    for {key, value} <- [
          {:backup_status_scope_result, :raise},
          {:backup_status_scope_result, :throw},
          {:backup_status_store_result, :raise},
          {:backup_status_store_result, :throw}
        ] do
      Process.put(key, value)

      assert {:error,
              %Error{
                code: :storage_unavailable,
                message: nil,
                details: %{},
                retryable?: true
              } = error} = Status.run(runtime(), session(), @operation_id)

      refute inspect(error) =~ "secret"
      Process.delete(key)
    end
  end

  defp runtime do
    %{
      backup_status_store: {Store, self()},
      operation_scope: {Scope, self()},
      sentinel: make_ref()
    }
  end

  defp session do
    %SessionContext{
      session_id: @session_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      expires_at: ~U[2026-08-10 09:00:00.000000Z],
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 11,
      authorization_epoch: 7,
      unlocked?: true
    }
  end

  defp status_record do
    %{
      operation_id: @operation_id,
      vault_id: @vault_id,
      status: :pending,
      requested_at: @requested_at,
      updated_at: @updated_at
    }
  end
end
