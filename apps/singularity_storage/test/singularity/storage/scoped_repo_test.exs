defmodule Singularity.Storage.ScopedRepoTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  import Ecto.Query

  alias Singularity.Storage.ScopedRepo
  alias Singularity.Storage.SafeSQL
  alias Singularity.Storage.Schema.Content.Asset

  setup do
    principal_id = Ecto.UUID.generate()
    vault_id = Ecto.UUID.generate()
    {:ok, context: %{principal_id: principal_id, vault_id: vault_id}}
  end

  test "sets local context on one checked-out connection and unwraps domain results", %{
    context: context
  } do
    principal_id = context.principal_id
    vault_id = context.vault_id

    RequestRepo.checkout(fn ->
      assert {:ok, {^principal_id, ^vault_id}} =
               ScopedRepo.transact(RequestRepo, context, fn repo ->
                 %{rows: [[principal_id, vault_id]]} =
                   query!(
                     repo,
                     """
                     SELECT
                       current_setting('singularity.principal_id', true),
                       current_setting('singularity.vault_id', true)
                     """
                   )

                 {:ok, {principal_id, vault_id}}
               end)

      assert_context_absent!(RequestRepo)

      assert {:error, :rolled_back} =
               ScopedRepo.transact(RequestRepo, context, [timeout: 5_000], fn _repo ->
                 {:error, :rolled_back}
               end)

      assert_context_absent!(RequestRepo)
    end)
  end

  test "applies repeatable-read isolation before scoped context queries", %{context: context} do
    RequestRepo.checkout(fn ->
      assert {:ok, "repeatable read"} =
               ScopedRepo.transact(
                 RequestRepo,
                 context,
                 [isolation: :repeatable_read],
                 fn repo ->
                   %{rows: [[isolation]]} = query!(repo, "SHOW transaction_isolation")
                   {:ok, isolation}
                 end
               )

      assert_context_absent!(RequestRepo)
    end)
  end

  test "rejects unsupported transaction isolation", %{context: context} do
    assert_raise ArgumentError, ~r/unsupported transaction isolation/, fn ->
      ScopedRepo.transact(
        RequestRepo,
        context,
        [isolation: :serializable],
        fn _repo -> :ok end
      )
    end
  end

  test "rejects duplicate transaction isolation options", %{context: context} do
    assert_raise ArgumentError, ~r/exactly once/, fn ->
      ScopedRepo.transact(
        RequestRepo,
        context,
        [isolation: :repeatable_read, isolation: :repeatable_read],
        fn _repo -> :ok end
      )
    end
  end

  test "rejects a checked-out connection with pre-existing nonempty context", %{
    context: context
  } do
    RequestRepo.checkout(fn ->
      try do
        query!(
          RequestRepo,
          "SELECT set_config('singularity.principal_id', $1, false)",
          [context.principal_id]
        )

        assert_raise RuntimeError, ~r/pre-existing PostgreSQL request context/, fn ->
          ScopedRepo.transact(RequestRepo, context, fn _repo -> :ok end)
        end
      after
        query!(
          RequestRepo,
          """
          SELECT
            set_config('singularity.principal_id', '', false),
            set_config('singularity.vault_id', '', false)
          """
        )
      end
    end)
  end

  test "database boundaries suppress raw query telemetry and emit only safe RLS denials" do
    request_raw_event = [:singularity, :storage, :request_repo, :query]
    worker_raw_event = [:singularity, :storage, :worker_repo, :query]
    safe_event = [:singularity, :authorization, :rls_denial]
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        [request_raw_event, worker_raw_event, safe_event],
        fn event, measurements, metadata, owner ->
          send(owner, {:database_telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    canary = "CANARY_DATABASE_TELEMETRY_SECRET_f12a"

    assert %{rows: [[^canary]]} =
             SafeSQL.query!(RequestRepo, "SELECT $1::text", [canary])

    assert [] =
             RequestRepo.all(
               from asset in Asset,
                 where: false
             )

    refute_receive {:database_telemetry, ^request_raw_event, _, _}

    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
             SafeSQL.query(
               WorkerRepo,
               "SELECT * FROM identity.people",
               []
             )

    assert_receive {:database_telemetry, ^safe_event, %{count: 1}, metadata}
    refute_receive {:database_telemetry, ^worker_raw_event, _, _}
    assert metadata == %{repo: :worker}
    refute inspect(metadata) =~ canary

    assert_raise Postgrex.Error, fn ->
      WorkerRepo.transaction(fn ->
        WorkerRepo
        |> SafeSQL.stream("SELECT * FROM identity.people")
        |> Enum.to_list()
      end)
    end

    assert_receive {:database_telemetry, ^safe_event, %{count: 1}, %{repo: :worker}}
    refute_receive {:database_telemetry, ^worker_raw_event, _, _}
  end

  defp assert_context_absent!(repo) do
    %{rows: [[principal_id, vault_id]]} =
      query!(
        repo,
        """
        SELECT
          current_setting('singularity.principal_id', true),
          current_setting('singularity.vault_id', true)
        """
      )

    assert principal_id in [nil, ""]
    assert vault_id in [nil, ""]
  end
end
