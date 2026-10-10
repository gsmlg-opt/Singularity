defmodule Singularity.Storage.Postgres.KnowledgeSearchPlanObserverTest do
  use Singularity.Storage.DataCase, async: false

  alias Singularity.Storage.{Fixtures, KnowledgeSearchPlanObserver, MigrationRepo}
  alias Singularity.Storage.KnowledgeSearchPlanObserver.Repo, as: ObserverRepo

  import ExUnit.CaptureLog

  test "missing, malformed, non-test and mismatched targets fail before callback" do
    assert Code.ensure_loaded?(KnowledgeSearchPlanObserver)
    assert function_exported?(KnowledgeSearchPlanObserver, :with_observer, 2)

    for database <- [
          nil,
          "postgres",
          "singularity_test_bad",
          "singularity_test_000000000000000000000000"
        ] do
      assert {:error, :observer_invalid_target} =
               apply(KnowledgeSearchPlanObserver, :with_observer, [
                 database,
                 fn _repo -> flunk("invalid target reached callback") end
               ])
    end

    assert observer(:startup_safe?, [[]])

    for options <- [
          [options: "-c auto_explain.log_analyze=on"],
          [parameters: [{"session_preload_libraries", "auto_explain"}]],
          [parameters: [{"auto_explain.log_wal", "on"}]],
          [session_preload_libraries: "auto_explain"],
          [shared_preload_libraries: "auto_explain"],
          [local_preload_libraries: "auto_explain"],
          [{:"auto_explain.log_wal", "on"}],
          [after_connect: fn _connection -> :ok end],
          [configure: fn options -> options end],
          [url: "postgresql://singularity_web@localhost/test?options=override"],
          [url: 123],
          [url: "not-a-postgresql-uri"]
        ] do
      refute observer(:startup_safe?, [options])
    end
  end

  @tag :integration
  test "startup defaults are removed before the callback and only the owned repo changes" do
    database = RequestRepo.config()[:database]
    shared = Process.whereis(RequestRepo)
    previous = RequestRepo.get_dynamic_repo()

    log =
      capture_log(fn ->
        assert :ok =
                 observer(:with_inherited_logging, [
                   database,
                   fn ->
                     assert {:ok, :verified} =
                              KnowledgeSearchPlanObserver.with_observer(database, fn repo ->
                                assert repo == ObserverRepo
                                owned = Process.whereis(repo)
                                assert is_pid(owned) and owned != shared
                                assert Process.whereis(RequestRepo) == shared
                                assert RequestRepo.get_dynamic_repo() == previous
                                monitor = Process.monitor(owned)
                                send(self(), {:observer_owned, owned, monitor})
                                assert observer(:clean?, [database])

                                assert {:error, :observer_setup_failed} =
                                         KnowledgeSearchPlanObserver.with_observer(
                                           database,
                                           fn _repo ->
                                             flunk("name collision reached callback")
                                           end
                                         )

                                assert Process.whereis(repo) == owned
                                assert Process.alive?(owned)
                                assert observer(:clean?, [database])
                                :verified
                              end)

                     assert observer(:clean?, [database])
                     :ok
                   end
                 ])
      end)

    assert RequestRepo.get_dynamic_repo() == previous
    assert Process.whereis(RequestRepo) == shared
    assert_receive {:observer_owned, owned, monitor}
    assert_receive {:DOWN, ^monitor, :process, ^owned, :normal}
    assert Process.whereis(ObserverRepo) == nil
    assert observer(:clean?, [database])
    assert_no_diagnostics(log)
  end

  @tag :integration
  test "the real web login observes executed nested authorization SQL privately" do
    scope = Fixtures.two_vaults!().one |> Map.take([:principal_id, :vault_id])
    database = RequestRepo.config()[:database]
    id = "observer-prerequisite-#{System.unique_integer([:positive])}"

    events =
      Enum.map(
        [RequestRepo, MigrationRepo, ObserverRepo],
        &(&1.config()[:telemetry_prefix] ++ [:query])
      )

    :ok = :telemetry.attach_many(id, events, &__MODULE__.query_event/4, self())
    on_exit(fn -> :telemetry.detach(id) end)

    log =
      capture_log(fn ->
        assert {:ok, {:ok, summary}} =
                 KnowledgeSearchPlanObserver.with_observer(database, fn repo ->
                   observer(:authorization_summary, [repo, scope])
                 end)

        assert Enum.sort(Map.keys(summary)) ==
                 Enum.sort([
                   :backend,
                   :nested_statements,
                   :executed_nodes,
                   :actual_rows,
                   :actual_loops,
                   :buffer_nodes,
                   :indexes
                 ])

        assert summary.backend > 0
        assert summary.nested_statements > 0
        assert summary.executed_nodes > 0
        assert summary.actual_rows == 1
        assert summary.actual_loops > 0
        assert summary.buffer_nodes > 0
        assert summary.indexes == []
        send(self(), {:observer_proof, summary})
      end)

    assert_receive {:observer_proof, summary}
    IO.puts("knowledge_search_observer proof=#{inspect(summary)}")
    assert observer(:clean?, [database])
    refute_receive :unexpected_observer_query_event
    assert_no_diagnostics(log)
  end

  @tag :integration
  test "callback exceptions restore dynamic repo and defaults" do
    database = RequestRepo.config()[:database]
    previous = RequestRepo.get_dynamic_repo()
    shared = Process.whereis(RequestRepo)

    log =
      capture_log(fn ->
        assert {:error, :observer_callback_failed} =
                 KnowledgeSearchPlanObserver.with_observer(database, fn _repo ->
                   raise "synthetic observer callback fault"
                 end)
      end)

    assert RequestRepo.get_dynamic_repo() == previous
    assert Process.whereis(RequestRepo) == shared
    assert Process.whereis(ObserverRepo) == nil
    assert observer(:clean?, [database])
    assert_no_diagnostics(log)
  end

  @tag :integration
  test "failure after committed install removes defaults before any callback" do
    database = RequestRepo.config()[:database]
    previous = RequestRepo.get_dynamic_repo()

    log =
      capture_log(fn ->
        assert {:error, :observer_setup_failed} =
                 KnowledgeSearchPlanObserver.with_observer(
                   database,
                   fn _repo -> flunk("early setup failure reached callback") end,
                   :after_install
                 )
      end)

    assert RequestRepo.get_dynamic_repo() == previous
    assert observer(:clean?, [database])
    assert_no_diagnostics(log)
  end

  @tag :integration
  test "pre-existing observation state is rejected without mutation or diagnostic leakage" do
    database = RequestRepo.config()[:database]

    log =
      capture_log(fn ->
        assert :ok =
                 observer(:with_conflicting_default, [
                   database,
                   fn ->
                     assert {:error, :observer_configuration_conflict} =
                              KnowledgeSearchPlanObserver.with_observer(database, fn _repo ->
                                flunk("conflict reached callback")
                              end)

                     send(self(), :conflict_rejected)
                     :ok
                   end
                 ])
      end)

    assert_receive :conflict_rejected
    assert_receive :conflict_rejected
    refute_receive :conflict_rejected
    assert observer(:clean?, [database])
    assert_no_diagnostics(log)
  end

  def query_event(_event, _measurements, _metadata, owner) do
    send(owner, :unexpected_observer_query_event)
  end

  defp observer(function, arguments), do: apply(KnowledgeSearchPlanObserver, function, arguments)

  defp assert_no_diagnostics(log) do
    empty? = log == ""
    assert empty?, "observer emitted diagnostics (contents withheld)"
  end
end
