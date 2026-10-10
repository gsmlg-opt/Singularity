defmodule Singularity.Storage.Postgres.KnowledgeSearchPlanObserverTest do
  use Singularity.Storage.DataCase, async: false

  alias Singularity.Core.Error

  alias Singularity.Storage.{
    Fixtures,
    KnowledgeFixtures,
    KnowledgeSearchPlanObserver,
    MigrationRepo,
    SafeSQL,
    ScopedRepo
  }

  alias Singularity.Storage.KnowledgeSearchPlanObserver.Repo, as: ObserverRepo

  import ExUnit.CaptureLog

  @summary_keys ~w(backend parameter_count candidate_calls nested_statements executed_nodes actual_rows actual_loops buffer_nodes indexes entry_rows_inspected entry_access)a
  @content_indexes ~w(search_entries_fts search_entries_title_trigram search_entries_body_trigram)
  @entry_nodes [
    "Seq Scan",
    "Index Scan",
    "Index Only Scan",
    "Bitmap Heap Scan",
    "Bitmap Index Scan"
  ]

  for {fault, kind, first_error} <- [
        {:admin_setup_and_cleanup, :admin, :observer_admin_failed},
        {:repo_setup_and_cleanup, :repo, :observer_setup_failed}
      ] do
    @fault fault
    @owned_kind kind
    @first_error first_error
    @tag :integration
    @tag :observer_diagnostics
    @tag :observer_first_error
    test "#{kind} setup evidence survives actual owned cleanup followed by cleanup failure" do
      require_diagnostics!()
      state = observer_state()
      watch_query_events!()
      before = Map.new(Process.get())
      kind = @owned_kind

      callback = fn _repo ->
        send(self(), :unexpected_first_error_fault_callback)
        :unexpected_result
      end

      stdout =
        ExUnit.CaptureIO.capture_io(fn ->
          log =
            capture_log(fn ->
              # The old public after-error precedence is deliberately retained
              # both without and with diagnostic collection.
              assert {:error, :observer_cleanup_failed} =
                       KnowledgeSearchPlanObserver.with_observer(state.database, callback, @fault)

              assert_receive {:observer_fault_owned_stopped, ^kind, ordinary_owned}
              refute Process.alive?(ordinary_owned)
              assert_observer_restored(state)

              assert {{:error, :observer_cleanup_failed}, diagnostic} =
                       observer(:with_diagnostics, [
                         fn ->
                           KnowledgeSearchPlanObserver.with_observer(
                             state.database,
                             callback,
                             @fault
                           )
                         end
                       ])

              assert_receive {:observer_fault_owned_stopped, ^kind, diagnostic_owned}
              refute Process.alive?(diagnostic_owned)
              assert_observer_restored(state)
              refute_receive :unexpected_first_error_fault_callback
              refute_receive :unexpected_observer_query_event
              restored? = Map.new(Process.get()) == before

              assert restored?,
                     "first-error diagnostic state was not restored (contents withheld)"

              assert_closed_diagnostic(diagnostic)
              assert diagnostic.stage == :setup
              assert diagnostic.error == @first_error
              assert diagnostic.exception_class == nil
              assert diagnostic.source == :knowledge_search_plan_observer
              assert is_integer(diagnostic.line) and diagnostic.line in 1..1_000_000_000
            end)

          assert_no_diagnostics(log)
        end)

      assert_no_diagnostics(stdout)
      assert_observer_restored(state)
      refute_receive :unexpected_first_error_fault_callback
      refute_receive :unexpected_observer_query_event
    end
  end

  @tag :observer_diagnostics
  test "diagnostics are opt-in and preserve successful validator results without process residue" do
    require_diagnostics!()
    require_envelope_validator!()
    envelope = search_envelope()
    expected = observer(:validate_search_envelope, [envelope])
    assert {:ok, summary} = expected
    assert closed_search_summary?(summary)
    before = Map.new(Process.get())

    assert {^expected, nil} =
             observer(:with_diagnostics, [
               fn ->
                 observer(:validate_search_envelope, [envelope])
               end
             ])

    assert_envelope_missing(%{envelope | calls: []})
    assert {:ok, nil} = observer(:with_diagnostics, [fn -> :ok end])
    restored? = Map.new(Process.get()) == before
    assert restored?, "diagnostic process state was not restored (contents withheld)"
  end

  @tag :observer_diagnostics
  test "malformed real validator envelopes produce only closed bounded content-free diagnostics" do
    require_diagnostics!()
    require_envelope_validator!()
    envelope = search_envelope()
    canary = "CANARY_OBSERVER_DIAGNOSTIC_" <> String.duplicate("private", 1_024)
    before = Map.new(Process.get())

    stdout =
      ExUnit.CaptureIO.capture_io(fn ->
        log =
          capture_log(fn ->
            for invalid <- [
                  nil,
                  %{envelope | q: canary, calls: []},
                  change_envelope_notice(envelope, 0, &Map.put(&1, :message, canary)),
                  change_envelope_notice(envelope, 0, &Map.put(&1, :where, canary))
                ] do
              assert {{:error, :observer_evidence_missing}, diagnostic} =
                       observer(:with_diagnostics, [
                         fn ->
                           observer(:validate_search_envelope, [invalid])
                         end
                       ])

              assert_closed_diagnostic(diagnostic)
              assert diagnostic.stage == :plan_validation
              assert diagnostic.error == :observer_evidence_missing
              assert diagnostic.source == :knowledge_search_plan_observer
              assert is_integer(diagnostic.line) and diagnostic.line in 1..1_000_000_000
              refute closed_diagnostic?(Map.put(diagnostic, :message, canary))
              refute closed_diagnostic?(%{diagnostic | stage: :untrusted_stage})
              refute closed_diagnostic?(%{diagnostic | error: :untrusted_error})
              refute closed_diagnostic?(%{diagnostic | source: canary})
              refute closed_diagnostic?(%{diagnostic | line: 1_000_000_001})
            end
          end)

        assert_no_diagnostics(log)
      end)

    assert_no_diagnostics(stdout)
    restored? = Map.new(Process.get()) == before
    assert restored?, "diagnostic process state was not restored (contents withheld)"
  end

  @tag :observer_diagnostics
  test "first validator failure survives later failures and isolated nested diagnostic scopes" do
    require_diagnostics!()
    require_envelope_validator!()
    invalid = %{search_envelope() | calls: []}
    before = Map.new(Process.get())

    assert {{:error, :observer_evidence_missing}, first} =
             observer(:with_diagnostics, [
               fn ->
                 observer(:validate_search_envelope, [invalid])
               end
             ])

    assert_closed_diagnostic(first)
    assert first.exception_class == nil

    assert {{:error, :observer_evidence_missing}, second} =
             observer(:with_diagnostics, [
               fn ->
                 observer(:validate_search_envelope, [nil])
               end
             ])

    assert_closed_diagnostic(second)
    assert second.exception_class == MatchError
    refute first == second

    assert {{{:error, :observer_evidence_missing}, {:error, :observer_evidence_missing}}, ^first} =
             observer(:with_diagnostics, [
               fn ->
                 {observer(:validate_search_envelope, [invalid]),
                  observer(:validate_search_envelope, [nil])}
               end
             ])

    assert {{{:error, :observer_evidence_missing}, ^second}, ^first} =
             observer(:with_diagnostics, [
               fn ->
                 assert_envelope_missing(invalid)

                 observer(:with_diagnostics, [
                   fn ->
                     observer(:validate_search_envelope, [nil])
                   end
                 ])
               end
             ])

    assert {{{:error, :observer_evidence_missing}, ^second}, nil} =
             observer(:with_diagnostics, [
               fn ->
                 observer(:with_diagnostics, [
                   fn ->
                     observer(:validate_search_envelope, [nil])
                   end
                 ])
               end
             ])

    restored? = Map.new(Process.get()) == before
    assert restored?, "nested diagnostic process state was not restored (contents withheld)"
  end

  @tag :observer_diagnostics
  test "diagnostic scopes preserve raises throws and exits and restore state on every unwind" do
    require_diagnostics!()
    require_envelope_validator!()
    invalid = %{search_envelope() | calls: []}
    canary = "CANARY_OBSERVER_DIAGNOSTIC_UNWIND"
    before = Map.new(Process.get())

    error =
      assert_raise RuntimeError, fn ->
        observer(:with_diagnostics, [
          fn ->
            assert_envelope_missing(invalid)
            raise RuntimeError, message: canary
          end
        ])
      end

    unchanged? = error.message == canary
    assert unchanged?, "diagnostic wrapper changed the original exception (contents withheld)"
    thrown = catch_throw(observer(:with_diagnostics, [fn -> throw(canary) end]))
    unchanged? = thrown == canary
    assert unchanged?, "diagnostic wrapper changed the original throw (contents withheld)"
    exited = catch_exit(observer(:with_diagnostics, [fn -> exit(canary) end]))
    unchanged? = exited == canary
    assert unchanged?, "diagnostic wrapper changed the original exit (contents withheld)"

    assert {{:error, :observer_evidence_missing}, first} =
             observer(:with_diagnostics, [
               fn ->
                 observer(:validate_search_envelope, [invalid])
               end
             ])

    assert {:outer_result, ^first} =
             observer(:with_diagnostics, [
               fn ->
                 assert_envelope_missing(invalid)

                 assert_raise RuntimeError, fn ->
                   observer(:with_diagnostics, [fn -> raise RuntimeError, message: canary end])
                 end

                 :outer_result
               end
             ])

    assert {:ok, nil} = observer(:with_diagnostics, [fn -> :ok end])
    restored? = Map.new(Process.get()) == before
    assert restored?, "unwound diagnostic process state was not restored (contents withheld)"
  end

  @tag :integration
  @tag :observer_diagnostics
  test "real observer callback exceptions return unchanged errors and only their owned source line" do
    require_diagnostics!()
    state = observer_state()
    watch_query_events!()
    canary = "CANARY_OBSERVER_DIAGNOSTIC_RUNTIME_ERROR"

    stdout =
      ExUnit.CaptureIO.capture_io(fn ->
        log =
          capture_log(fn ->
            assert {{:error, :observer_callback_failed}, diagnostic} =
                     observer(:with_diagnostics, [
                       fn ->
                         KnowledgeSearchPlanObserver.with_observer(state.database, fn _repo ->
                           raise_line = __ENV__.line + 2
                           send(self(), {:diagnostic_callback_line, raise_line})
                           raise RuntimeError, message: canary
                         end)
                       end
                     ])

            assert_closed_diagnostic(diagnostic)
            assert diagnostic.stage == :callback
            assert diagnostic.error == :observer_callback_failed
            assert diagnostic.exception_class == RuntimeError
            assert diagnostic.source == :knowledge_search_plan_observer_test
            assert_receive {:diagnostic_callback_line, line}
            assert diagnostic.line == line
          end)

        assert_no_diagnostics(log)
      end)

    assert_no_diagnostics(stdout)
    assert_observer_restored(state)
    refute_receive :unexpected_observer_query_event
  end

  @tag :integration
  @tag :observer_diagnostics
  test "inner validation diagnostic survives callback failure after real search and owned cleanup" do
    require_diagnostics!()
    fixture = search_fixture!()
    state = observer_state()
    watch_query_events!()
    invalid = %{search_envelope() | calls: []}
    canary = "CANARY_OBSERVER_DIAGNOSTIC_FIRST_FAILURE"

    stdout =
      ExUnit.CaptureIO.capture_io(fn ->
        log =
          capture_log(fn ->
            assert {{:error, :observer_callback_failed}, diagnostic} =
                     observer(:with_diagnostics, [
                       fn ->
                         KnowledgeSearchPlanObserver.with_observer(state.database, fn repo ->
                           assert_search_summary(repo, fixture)
                           assert_envelope_missing(invalid)
                           raise RuntimeError, message: canary
                         end)
                       end
                     ])

            assert_closed_diagnostic(diagnostic)
            assert diagnostic.stage == :plan_validation
            assert diagnostic.error == :observer_evidence_missing
            assert diagnostic.exception_class == nil
            assert diagnostic.source == :knowledge_search_plan_observer
          end)

        assert_no_diagnostics(log)
      end)

    assert_no_diagnostics(stdout)
    assert_observer_restored(state)
    refute_receive :unexpected_observer_query_event
  end

  @tag :integration
  @tag :observer_diagnostics
  test "real forbidden Store search retains its missing-evidence result and sanitized error diagnostic" do
    require_diagnostics!()
    fixture = search_fixture!([])
    state = observer_state()
    watch_query_events!()

    stdout =
      ExUnit.CaptureIO.capture_io(fn ->
        log =
          capture_log(fn ->
            assert {{:ok, {:error, :observer_evidence_missing}}, diagnostic} =
                     observer(:with_diagnostics, [
                       fn ->
                         KnowledgeSearchPlanObserver.with_observer(state.database, fn repo ->
                           monitors = caller_monitors()

                           result =
                             observer(:search_summary, [repo, fixture.scope, fixture.query])

                           missing? = result == {:error, :observer_evidence_missing}

                           assert missing?,
                                  "failed search changed its closed error (contents withheld)"

                           assert_search_trace_clean(monitors)
                           result
                         end)
                       end
                     ])

            assert_closed_diagnostic(diagnostic)
            assert diagnostic.stage == :search_result
            assert diagnostic.error == :forbidden
            assert diagnostic.exception_class == nil
            assert diagnostic.source == :knowledge_search_plan_observer
          end)

        assert_no_diagnostics(log)
      end)

    assert_no_diagnostics(stdout)
    assert_observer_restored(state)
    refute_receive :unexpected_observer_query_event
  end

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

  @tag :integration
  test "actual Store call returns the unchanged canonical page and closed executed search evidence" do
    fixture = search_fixture!()
    state = observer_state()
    watch_query_events!()

    log =
      capture_log(fn ->
        assert {:ok, :verified} =
                 KnowledgeSearchPlanObserver.with_observer(state.database, fn repo ->
                   assert_search_summary(repo, fixture)
                   :verified
                 end)
      end)

    assert_observer_restored(state)
    refute_receive :unexpected_observer_query_event
    assert_no_diagnostics(log)
  end

  @tag :integration
  test "empty Store query keeps rank zero and executes no candidate function with thirteen parameters" do
    fixture = search_fixture!()
    [item] = fixture.page.items
    page = %{fixture.page | items: [%{item | rank: 0}]}
    fixture = %{fixture | query: %{fixture.query | q: ""}, page: page}

    ordinary =
      ScopedRepo.transact(RequestRepo, fixture.scope, fn repo ->
        Singularity.Storage.Postgres.KnowledgeSearchStore.search(repo, fixture.query)
      end)

    same_page? = ordinary == {:ok, page}
    assert same_page?, "ordinary empty Store query changed its exact canonical page"
    state = observer_state()
    watch_query_events!()

    log =
      capture_log(fn ->
        assert {:ok, :verified} =
                 KnowledgeSearchPlanObserver.with_observer(state.database, fn repo ->
                   assert_search_summary(repo, fixture, 0)
                   :verified
                 end)
      end)

    assert_observer_restored(state)
    refute_receive :unexpected_observer_query_event
    assert_no_diagnostics(log)
  end

  @tag :integration
  test "callback faults after actual search capture leave no trace collector or observation state" do
    fixture = search_fixture!()
    state = observer_state()
    watch_query_events!()

    log =
      capture_log(fn ->
        assert {:error, :observer_callback_failed} =
                 KnowledgeSearchPlanObserver.with_observer(state.database, fn repo ->
                   assert_search_summary(repo, fixture)
                   send(self(), :search_verified_before_callback_fault)
                   raise "synthetic observer search callback fault"
                 end)
      end)

    assert_receive :search_verified_before_callback_fault
    assert_observer_restored(state)
    refute_receive :unexpected_observer_query_event
    assert_no_diagnostics(log)
  end

  @tag :integration
  test "a failed actual Store search returns only the closed missing-evidence error and cleans tracing" do
    fixture = search_fixture!([])
    state = observer_state()
    watch_query_events!()

    log =
      capture_log(fn ->
        assert {:ok, :verified} =
                 KnowledgeSearchPlanObserver.with_observer(state.database, fn repo ->
                   monitors = caller_monitors()
                   result = observer(:search_summary, [repo, fixture.scope, fixture.query])
                   missing? = result == {:error, :observer_evidence_missing}
                   assert missing?, "failed search did not return closed missing evidence"
                   assert_search_trace_clean(monitors)
                   :verified
                 end)
      end)

    assert_observer_restored(state)
    refute_receive :unexpected_observer_query_event
    assert_no_diagnostics(log)
  end

  @tag :integration
  test "actual search capture rejects another observer's trace pattern without replacing it" do
    fixture = search_fixture!()
    state = observer_state()
    function = {SafeSQL, :query, 4}
    watch_query_events!()
    assert_search_trace_clean(caller_monitors())

    log =
      capture_log(fn ->
        try do
          assert :erlang.trace_pattern(function, true, [:local]) == 1

          assert {:ok, :verified} =
                   KnowledgeSearchPlanObserver.with_observer(state.database, fn repo ->
                     monitors = caller_monitors()
                     result = observer(:search_summary, [repo, fixture.scope, fixture.query])
                     missing? = result == {:error, :observer_evidence_missing}
                     assert missing?, "owned tracing was not rejected with a closed error"
                     assert {:traced, :local} = :erlang.trace_info(function, :traced)
                     assert {:flags, []} = :erlang.trace_info(self(), :flags)
                     assert caller_monitors() == monitors
                     :verified
                   end)
        after
          :erlang.trace_pattern(function, false, [:local])
        end
      end)

    assert_observer_restored(state)
    refute_receive :unexpected_observer_query_event
    assert_no_diagnostics(log)
  end

  test "the private two-result validator returns only exact closed original-call metadata" do
    require_envelope_validator!()
    envelope = search_envelope()

    expected = %{
      backend: 101,
      parameter_count: 13,
      candidate_calls: 1,
      nested_statements: 1,
      executed_nodes: 5,
      actual_rows: 1,
      actual_loops: 1,
      buffer_nodes: 5,
      indexes: ["search_entries_fts"],
      entry_rows_inspected: 7,
      entry_access: [{"Seq Scan", 4}, {"Bitmap Heap Scan", 3}]
    }

    assert_envelope_summary(envelope, expected)

    for qualification <- ["", "content."], suffix <- ["", opaque_parameter_frame()] do
      context = candidate_context(envelope.candidate_sql, qualification) <> suffix
      changed = change_envelope_notice(envelope, 0, &Map.put(&1, :where, context))
      assert_envelope_summary(changed, expected)
    end

    empty = empty_search_envelope(envelope)

    assert_envelope_summary(empty, %{
      expected
      | candidate_calls: 0,
        nested_statements: 0,
        executed_nodes: 2,
        buffer_nodes: 2,
        indexes: [],
        entry_rows_inspected: 4,
        entry_access: [{"Seq Scan", 4}]
    })
  end

  test "the private envelope rejects missing duplicate wrong-channel and non-adjacent proof" do
    require_envelope_validator!()
    envelope = search_envelope()
    [search, drain] = envelope.calls
    candidate = elem(search, 4) |> elem(1) |> Map.fetch!(:messages) |> hd()
    outer = elem(drain, 4) |> elem(1) |> Map.fetch!(:messages) |> hd()

    for invalid <- [nil, [], %{}, Map.delete(envelope, :candidate_sql)] do
      assert_envelope_missing(invalid)
    end

    for invalid <- [
          %{envelope | calls: []},
          %{envelope | calls: [search]},
          %{envelope | calls: [drain, search]},
          %{envelope | calls: [search, drain, search, drain]},
          %{envelope | calls: [search, drain, drain]},
          %{
            envelope
            | calls: [search, {ObserverRepo, "SELECT 1", [], [], elem(drain, 4)}, drain]
          },
          change_envelope_result(envelope, 0, &Map.put(&1, :messages, [])),
          change_envelope_result(envelope, 1, &Map.put(&1, :messages, [])),
          change_envelope_result(envelope, 0, &Map.put(&1, :messages, [candidate, candidate])),
          change_envelope_result(envelope, 1, &Map.put(&1, :messages, [outer, outer])),
          change_envelope_result(envelope, 0, &Map.put(&1, :messages, [candidate, outer])),
          change_envelope_result(envelope, 1, &Map.put(&1, :messages, [outer, candidate])),
          change_envelope_result(envelope, 0, &Map.put(&1, :messages, [outer])),
          change_envelope_result(envelope, 1, &Map.put(&1, :messages, [candidate])),
          change_envelope_notice(envelope, 0, &Map.put(&1, :severity, "LOG")),
          change_envelope_notice(envelope, 1, &Map.put(&1, :message, "duration: 0 ms plan:\n{}")),
          change_envelope_notice(envelope, 0, &Map.put(&1, :message, "duration: 0 ms plan:\n{"))
        ] do
      assert_envelope_missing(invalid)
    end

    for index <- [0, 1] do
      for pair <- [
            put_elem(Enum.at(envelope.calls, index), 0, RequestRepo),
            put_elem(Enum.at(envelope.calls, index), 4, {:error, :synthetic_private_fault})
          ] do
        assert_envelope_missing(%{envelope | calls: List.replace_at(envelope.calls, index, pair)})
      end
    end

    for parameters <- [[], List.duplicate(nil, 12), List.duplicate(nil, 14)] do
      assert_envelope_missing(%{envelope | calls: [put_elem(search, 2, parameters), drain]})
    end

    assert_envelope_missing(%{envelope | calls: [search, put_elem(drain, 2, [101])]})
    assert_envelope_missing(%{envelope | calls: [search, put_elem(drain, 1, "SELECT 101")]})

    assert_envelope_missing(%{
      envelope
      | calls: [search, put_elem(drain, 3, cache_statement: "drain")]
    })

    assert_envelope_missing(%{envelope | calls: [search, put_elem(drain, 3, query_type: :text)]})
  end

  test "the private envelope binds original drain and returned PID to one verified backend" do
    require_envelope_validator!()
    envelope = search_envelope()

    for backend <- [nil, 0, -1, 1.0, 1_000_000_001, 102] do
      assert_envelope_missing(%{envelope | backend: backend})
    end

    for index <- [0, 1], backend <- [nil, 0, 102] do
      assert_envelope_missing(
        change_envelope_result(envelope, index, &Map.put(&1, :connection_id, backend))
      )
    end

    for rows <- [[], [[102]], [[101.0]], [[101, 101]], [[101], [101]]] do
      assert_envelope_missing(change_envelope_result(envelope, 1, &Map.put(&1, :rows, rows)))
    end

    assert_envelope_missing(change_envelope_result(envelope, 1, &Map.put(&1, :num_rows, 2)))
    assert_envelope_missing(change_envelope_result(envelope, 0, &Map.put(&1, :num_rows, 2)))
  end

  test "the private candidate context requires exact ordered source and function frames" do
    require_envelope_validator!()
    envelope = search_envelope()
    sql = envelope.candidate_sql

    function =
      "PL/pgSQL function content.search_candidate_ids(text,text,uuid[]) line 2 at RETURN QUERY"

    spi = "SQL statement \"" <> sql <> "\"\n"

    for context <- [
          nil,
          "",
          function,
          function <> "\n" <> spi,
          spi,
          spi <> function <> "\n" <> function,
          spi <> String.replace(function, "line 2", "line 0"),
          spi <> String.replace(function, "line 2", "line 1000000001"),
          spi <> String.replace(function, "content.", "pg_temp."),
          spi <> String.replace(function, "RETURN QUERY", "EXECUTE"),
          spi <> String.replace(function, "uuid[]", "text[]"),
          String.replace(spi, "matched AS", "matched  AS") <> function,
          spi <> function <> "\nunknown context frame",
          spi <> "unnamed portal with parameters: " <> function,
          spi <>
            "PL/pgSQL function content.other(text) line 2 at RETURN QUERY\n" <>
            "unnamed portal with parameters: " <> function,
          "unnamed portal with parameters: " <> spi <> function
        ] do
      assert_envelope_missing(change_envelope_notice(envelope, 0, &Map.put(&1, :where, context)))
    end

    for changed_sql <- [String.replace(sql, "matched AS", "matched  AS"), sql <> ";"] do
      changed =
        change_envelope_plan(envelope, 0, fn record ->
          Map.put(record, "Query Text", changed_sql)
        end)

      changed =
        change_envelope_notice(changed, 0, &Map.put(&1, :where, candidate_context(changed_sql)))

      assert_envelope_missing(changed)
    end

    assert_envelope_missing(
      change_envelope_plan(envelope, 1, &Map.put(&1, "Query Text", "SELECT 1"))
    )
  end

  test "the private original plans fail closed on invalid metrics and evidence resource ceilings" do
    require_envelope_validator!()
    envelope = search_envelope()

    for index <- [0, 1],
        field <- ["Actual Rows", "Actual Loops", "Shared Hit Blocks"],
        value <- [nil, -1, 1.0, "1", 1_000_000_001] do
      invalid =
        change_envelope_plan(envelope, index, fn record ->
          update_in(record, ["Plan"], &Map.put(&1, field, value))
        end)

      assert_envelope_missing(invalid)
    end

    for index <- [0, 1], field <- ["Actual Rows", "Actual Loops"] do
      invalid =
        change_envelope_plan(envelope, index, fn record ->
          update_in(record, ["Plan"], &Map.delete(&1, field))
        end)

      assert_envelope_missing(invalid)
    end

    for {index, transform} <- [
          {0, &Map.put(&1, "Actual Loops", 0)},
          {1, &Map.put(&1, "Actual Loops", 0)},
          {0, &Map.put(&1, "Node Type", "Untrusted Scan")},
          {0, &Map.put(&1, "Plans", [nil])},
          {0, &Map.put(&1, "Rows Removed by Filter", -1)},
          {0, &Map.put(&1, "Rows Removed by Filter", 1_000_000_000)},
          {1,
           fn plan ->
             update_in(plan, ["Plans", Access.at(0)], &Map.put(&1, "Actual Loops", 2))
           end},
          {1, fn plan -> Map.put(plan, "Plans", plan["Plans"] ++ [hd(plan["Plans"])]) end}
        ] do
      assert_envelope_missing(
        change_envelope_plan(envelope, index, &update_in(&1, ["Plan"], transform))
      )
    end

    for index <- [0, 1] do
      too_large =
        change_envelope_notice(envelope, index, fn notice ->
          Map.update!(notice, :message, &(&1 <> String.duplicate(" ", 1_048_577)))
        end)

      assert_envelope_missing(too_large)
    end

    too_large_context =
      change_envelope_notice(envelope, 0, fn notice ->
        Map.update!(
          notice,
          :where,
          &(&1 <> "\nunnamed portal with parameters: " <> String.duplicate("x", 1_048_577))
        )
      end)

    assert_envelope_missing(too_large_context)

    too_many_nodes =
      change_envelope_plan(envelope, 0, fn record ->
        update_in(
          record,
          ["Plan"],
          &Map.put(&1, "Plans", List.duplicate(envelope_node("Result"), 4_096))
        )
      end)

    assert_envelope_missing(too_many_nodes)

    too_deep =
      Enum.reduce(1..65, envelope_node("Result"), fn _, child ->
        Map.put(envelope_node("Result"), "Plans", [child])
      end)

    assert_envelope_missing(change_envelope_plan(envelope, 0, &Map.put(&1, "Plan", too_deep)))
  end

  @tag :integration
  test "successive actual searches keep original-call evidence isolated on the same web backend" do
    fixture = search_fixture!()
    state = observer_state()
    watch_query_events!()

    log =
      capture_log(fn ->
        assert {:ok, :verified} =
                 KnowledgeSearchPlanObserver.with_observer(state.database, fn repo ->
                   assert %{rows: [["singularity_web", "singularity_web", backend]]} =
                            fixture_query!(
                              repo,
                              "SELECT session_user,current_user,pg_backend_pid()"
                            )

                   for _ <- 1..3 do
                     monitors = caller_monitors()

                     case observer(:search_summary, [repo, fixture.scope, fixture.query]) do
                       {:ok, page, summary} ->
                         exact? = page == fixture.page and closed_search_summary?(summary)

                         assert exact?,
                                "successive search changed its canonical page or closed evidence"

                         assert summary.backend == backend
                         assert summary.parameter_count == 13
                         assert summary.candidate_calls == 1
                         assert summary.nested_statements == 1
                         assert summary.actual_rows == 1
                         assert summary.actual_loops > 0
                         assert summary.buffer_nodes > 0
                         assert_search_trace_clean(monitors)

                       _ ->
                         flunk("successive original-call evidence missing (contents withheld)")
                     end
                   end

                   :verified
                 end)
      end)

    assert_observer_restored(state)
    refute_receive :unexpected_observer_query_event
    assert_no_diagnostics(log)
  end

  test "original outer evidence requires its own analyzed buffers even when the candidate has buffers" do
    require_envelope_validator!()
    envelope = search_envelope()

    case observer(:validate_search_envelope, [envelope]) do
      {:ok, summary} ->
        valid? =
          closed_search_summary?(summary) and summary.buffer_nodes == 5 and
            summary.candidate_calls == 1 and summary.actual_rows == 1

        assert valid?, "outer-buffer control did not return valid closed evidence"

      _ ->
        flunk("outer-buffer positive control failed (contents withheld)")
    end

    without_outer_buffers =
      change_envelope_plan(envelope, 1, fn record ->
        update_in(record, ["Plan"], &remove_plan_buffers/1)
      end)

    assert_envelope_missing(without_outer_buffers)
  end

  defp require_diagnostics! do
    assert Code.ensure_loaded?(KnowledgeSearchPlanObserver)
    assert function_exported?(KnowledgeSearchPlanObserver, :with_diagnostics, 1)
  end

  defp assert_closed_diagnostic(diagnostic) do
    closed? = closed_diagnostic?(diagnostic)
    assert closed?, "observer diagnostic escaped its closed shape (contents withheld)"
    bounded? = byte_size(:erlang.term_to_binary(diagnostic)) <= 512
    assert bounded?, "observer diagnostic exceeded its fixed-field bound (contents withheld)"
  end

  defp closed_diagnostic?(diagnostic) when is_map(diagnostic) and not is_struct(diagnostic) do
    Enum.sort(Map.keys(diagnostic)) ==
      Enum.sort([:stage, :error, :exception_class, :source, :line]) and
      diagnostic.stage in [
        :setup,
        :callback,
        :search_result,
        :drain_result,
        :trace_delivery,
        :pair_collection,
        :trace_cleanup,
        :plan_validation,
        :local_settings,
        :observer_cleanup
      ] and
      diagnostic.error in [
        :observer_invalid_target,
        :observer_admin_failed,
        :observer_configuration_conflict,
        :observer_setup_failed,
        :observer_callback_failed,
        :observer_cleanup_failed,
        :observer_evidence_missing,
        :forbidden,
        :invalid,
        :conflict,
        :storage_unavailable
      ] and
      diagnostic.exception_class in [
        nil,
        RuntimeError,
        ExUnit.AssertionError,
        MatchError,
        ArgumentError,
        FunctionClauseError,
        KeyError,
        JSON.DecodeError,
        Postgrex.Error,
        DBConnection.ConnectionError
      ] and
      ((diagnostic.source == nil and diagnostic.line == nil) or
         (diagnostic.source in [
            :knowledge_search_plan_observer,
            :knowledge_search_plan_observer_test,
            :knowledge_search_plan_test
          ] and is_integer(diagnostic.line) and diagnostic.line in 1..1_000_000_000))
  end

  defp closed_diagnostic?(_diagnostic), do: false

  defp remove_plan_buffers(plan) do
    plan =
      Map.drop(plan, [
        "Shared Hit Blocks",
        "Shared Read Blocks",
        "Shared Dirtied Blocks",
        "Shared Written Blocks",
        "Local Hit Blocks",
        "Local Read Blocks",
        "Local Dirtied Blocks",
        "Local Written Blocks",
        "Temp Read Blocks",
        "Temp Written Blocks"
      ])

    if Map.has_key?(plan, "Plans"),
      do: %{plan | "Plans" => Enum.map(plan["Plans"], &remove_plan_buffers/1)},
      else: plan
  end

  defp require_envelope_validator! do
    assert Code.ensure_loaded?(KnowledgeSearchPlanObserver)
    assert function_exported?(KnowledgeSearchPlanObserver, :validate_search_envelope, 1)
  end

  defp assert_envelope_summary(envelope, expected) do
    result = observer(:validate_search_envelope, [envelope])
    exact? = result == {:ok, expected}
    assert exact?, "private envelope did not return exact closed metadata (contents withheld)"
  end

  defp assert_envelope_missing(envelope) do
    result = observer(:validate_search_envelope, [envelope])
    closed? = result == {:error, :observer_evidence_missing}
    assert closed?, "invalid private envelope escaped its fixed error (contents withheld)"
  end

  defp search_envelope do
    candidate_sql =
      "WITH /* singularity:search_candidate_ids:v1 */ matched AS (SELECT entry_id FROM content.search_entries) SELECT entry_id FROM matched"

    statement =
      "WITH input AS (SELECT $2::text AS q), scored AS MATERIALIZED (SELECT entry_id FROM content.search_candidate_ids($2,$3,$5)) SELECT entry_id FROM scored"

    index = Map.put(envelope_node("Bitmap Index Scan"), "Index Name", "search_entries_fts")

    candidate =
      envelope_node("Bitmap Heap Scan")
      |> Map.put("Relation Name", "search_entries")
      |> Map.put("Rows Removed by Filter", 2)
      |> Map.put("Plans", [index])

    function = Map.put(envelope_node("Function Scan"), "Function Name", "search_candidate_ids")

    access =
      envelope_node("Seq Scan")
      |> Map.put("Relation Name", "search_entries")
      |> Map.put("Rows Removed by Filter", 3)

    outer = Map.put(envelope_node("Limit"), "Plans", [function, access])

    search = %Postgrex.Result{
      command: :select,
      columns: ["entry_id"],
      rows: [["synthetic-private-row"]],
      num_rows: 1,
      connection_id: 101,
      messages: [envelope_notice(candidate_sql, candidate, candidate_context(candidate_sql))]
    }

    drain = %Postgrex.Result{
      command: :select,
      columns: ["pg_backend_pid"],
      rows: [[101]],
      num_rows: 1,
      connection_id: 101,
      messages: [envelope_notice(statement, outer, "")]
    }

    %{
      repo: ObserverRepo,
      backend: 101,
      candidate_sql: candidate_sql,
      q: "body",
      calls: [
        {ObserverRepo, statement,
         [nil, "body", "note", "%body%", [], false, nil, nil, nil, nil, nil, nil, 21], [],
         {:ok, search}},
        {ObserverRepo, "SELECT pg_catalog.pg_backend_pid()", [], [], {:ok, drain}}
      ]
    }
  end

  defp empty_search_envelope(envelope) do
    envelope = %{envelope | q: ""}
    [search, drain] = envelope.calls

    statement =
      "WITH input AS (SELECT $2::text AS q), scored AS MATERIALIZED (SELECT entry_id FROM content.search_entries) SELECT entry_id FROM scored"

    search =
      search |> put_elem(1, statement) |> put_elem(2, List.replace_at(elem(search, 2), 1, ""))

    envelope = %{envelope | calls: [search, drain]}
    envelope = change_envelope_result(envelope, 0, &Map.put(&1, :messages, []))

    change_envelope_plan(envelope, 1, fn record ->
      record
      |> Map.put("Query Text", statement)
      |> update_in(["Plan", "Plans"], fn [_function, access] -> [access] end)
    end)
  end

  defp envelope_node(type),
    do: %{
      "Node Type" => type,
      "Actual Rows" => 1,
      "Actual Loops" => 1,
      "Shared Hit Blocks" => 1
    }

  defp envelope_notice(sql, plan, context),
    do: %{
      severity: "NOTICE",
      where: context,
      message: "duration: 0 ms plan:\n" <> JSON.encode!(%{"Query Text" => sql, "Plan" => plan})
    }

  defp candidate_context(sql, qualification \\ "content."),
    do:
      "SQL statement \"" <>
        sql <>
        "\"\nPL/pgSQL function " <>
        qualification <>
        "search_candidate_ids(text,text,uuid[]) line 2 at RETURN QUERY"

  defp opaque_parameter_frame,
    do:
      "\nunnamed portal with parameters: $1 = 'synthetic-private-parameter\n" <>
        "PL/pgSQL function content.search_candidate_ids(text,text,uuid[]) line 2 at RETURN QUERY'"

  defp change_envelope_result(envelope, index, transform) do
    pair = Enum.at(envelope.calls, index)
    {:ok, result} = elem(pair, 4)

    %{
      envelope
      | calls:
          List.replace_at(envelope.calls, index, put_elem(pair, 4, {:ok, transform.(result)}))
    }
  end

  defp change_envelope_notice(envelope, index, transform),
    do:
      change_envelope_result(envelope, index, fn result ->
        %{result | messages: Enum.map(result.messages, transform)}
      end)

  defp change_envelope_plan(envelope, index, transform),
    do:
      change_envelope_notice(envelope, index, fn notice ->
        [_prefix, json] = String.split(notice.message, "plan:\n", parts: 2)
        record = JSON.decode!(json) |> transform.()
        %{notice | message: "duration: 0 ms plan:\n" <> JSON.encode!(record)}
      end)

  defp search_fixture!(names \\ ["note.read", "asset.read"]) do
    assert Code.ensure_loaded?(KnowledgeSearchPlanObserver)
    assert function_exported?(KnowledgeSearchPlanObserver, :search_summary, 3)
    source = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)

    Fixtures.with_owner(fn ->
      for name <- names do
        fixture_query!(
          MigrationRepo,
          "INSERT INTO core.capabilities(id,name) VALUES($1,$2) ON CONFLICT(name) DO NOTHING",
          [KnowledgeFixtures.uuid(), name]
        )
      end

      assert %{num_rows: count} =
               fixture_query!(
                 MigrationRepo,
                 """
                 INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id)
                 SELECT $1,$2,capability.id FROM core.capabilities AS capability
                 WHERE capability.name=ANY($3::text[])
                 ON CONFLICT(principal_id,vault_id,capability_id) DO NOTHING
                 """,
                 [source.principal_id, source.vault_id, names]
               )

      assert count == length(names)

      assert %{rows: [[1]]} =
               fixture_query!(
                 MigrationRepo,
                 "SELECT content.reconcile_search_resource_internal($1,$2)",
                 [source.vault_id, note.resource_id]
               )
    end)

    scope = Map.take(source, [:principal_id, :vault_id])

    query = %{
      owner_scope_id: Ecto.UUID.load!(source.vault_id),
      classification: :private,
      q: "body",
      kind: :note,
      tag_ids: [],
      limit: 20,
      cursor: nil,
      policy_version: 1
    }

    result =
      ScopedRepo.transact(RequestRepo, scope, fn repo ->
        Singularity.Storage.Postgres.KnowledgeSearchStore.search(repo, query)
      end)

    page =
      if names == [] do
        forbidden? =
          result ==
            {:error, %Error{code: :forbidden, message: nil, details: %{}, retryable?: false}}

        assert forbidden?, "unauthorized observer fixture was not a real forbidden Store search"
        nil
      else
        case result do
          {:ok, %{items: [item], next_cursor: :done} = page} ->
            same_source? =
              item.resource_id == Ecto.UUID.load!(note.resource_id) and
                item.resource_version_id == Ecto.UUID.load!(note.resource_version_id) and
                item.entry_id == "note:" <> Ecto.UUID.load!(note.resource_version_id) and
                item.title == "Note" and item.snippet == "body" and item.rank > 0

            assert same_source?,
                   "ordinary Store control did not return the exact canonical fixture"

            page

          _other ->
            flunk("ordinary Store positive control failed")
        end
      end

    %{scope: scope, query: query, page: page}
  end

  defp assert_search_summary(repo, fixture, candidate_calls \\ 1) do
    monitors = caller_monitors()

    assert %{rows: [["singularity_web", "singularity_web", backend]]} =
             fixture_query!(repo, "SELECT session_user,current_user,pg_backend_pid()")

    case observer(:search_summary, [repo, fixture.scope, fixture.query]) do
      {:ok, page, summary} ->
        same_page? = page == fixture.page
        assert same_page?, "observed Store page changed the exact canonical control"
        closed? = closed_search_summary?(summary)
        assert closed?, "search observer returned non-closed metadata (contents withheld)"
        assert summary.backend == backend
        assert summary.parameter_count == 13
        assert summary.candidate_calls == candidate_calls
        if candidate_calls > 0, do: assert(summary.nested_statements > 0)
        assert summary.executed_nodes > 0
        assert summary.actual_rows == 1
        assert summary.actual_loops > 0
        assert summary.buffer_nodes > 0
        assert summary.entry_rows_inspected >= 1
        assert summary.entry_access != []
        assert_search_trace_clean(monitors)

      _other ->
        flunk("actual Store search evidence missing (contents withheld)")
    end
  end

  defp closed_search_summary?(summary) when is_map(summary) do
    Enum.sort(Map.keys(summary)) == Enum.sort(@summary_keys) and
      Enum.all?(@summary_keys -- [:indexes, :entry_access], fn key ->
        value = Map.get(summary, key)
        is_integer(value) and value >= 0 and value <= 1_000_000_000
      end) and is_list(summary.indexes) and
      Enum.all?(summary.indexes, &(&1 in @content_indexes)) and
      is_list(summary.entry_access) and Enum.all?(summary.entry_access, &closed_entry_access?/1)
  end

  defp closed_search_summary?(_summary), do: false

  defp closed_entry_access?({name, count}),
    do: name in @entry_nodes and is_integer(count) and count >= 0 and count <= 1_000_000_000

  defp closed_entry_access?(_entry), do: false

  defp caller_monitors do
    {:monitors, monitors} = Process.info(self(), :monitors)
    Enum.sort(monitors)
  end

  defp assert_search_trace_clean(monitors) do
    assert {:flags, []} = :erlang.trace_info(self(), :flags)
    assert {:traced, false} = :erlang.trace_info({SafeSQL, :query, 4}, :traced)
    assert caller_monitors() == monitors
  end

  defp observer_state do
    %{
      database: RequestRepo.config()[:database],
      shared: Process.whereis(RequestRepo),
      dynamic: RequestRepo.get_dynamic_repo(),
      monitors: caller_monitors()
    }
  end

  defp assert_observer_restored(state) do
    assert RequestRepo.get_dynamic_repo() == state.dynamic
    assert Process.whereis(RequestRepo) == state.shared
    assert Process.whereis(ObserverRepo) == nil
    assert observer(:clean?, [state.database])
    assert_search_trace_clean(state.monitors)

    assert %{rows: [["singularity_web", "singularity_web"]]} =
             fixture_query!(RequestRepo, "SELECT session_user,current_user")
  end

  defp watch_query_events! do
    id = "observer-search-#{System.unique_integer([:positive])}"

    events =
      Enum.map(
        [RequestRepo, MigrationRepo, ObserverRepo],
        &(&1.config()[:telemetry_prefix] ++ [:query])
      )

    :ok = :telemetry.attach_many(id, events, &__MODULE__.query_event/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp fixture_query!(repo, statement, parameters \\ []) do
    case SafeSQL.query(repo, statement, parameters) do
      {:ok, %{rows: rows, num_rows: count}} -> %{rows: rows, num_rows: count}
      _other -> flunk("observer fixture query failed (contents withheld)")
    end
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
