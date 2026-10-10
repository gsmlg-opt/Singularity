defmodule Singularity.Storage.Postgres.KnowledgeSearchPlanTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration
  @moduletag timeout: 60_000

  alias Singularity.Core.Error
  alias Singularity.Storage.Postgres.KnowledgeSearchStore

  alias Singularity.Storage.{
    Fixtures,
    KnowledgeFixtures,
    KnowledgeSearchPlanObserver,
    MigrationRepo,
    SafeSQL,
    ScopedRepo
  }

  alias Singularity.Storage.KnowledgeSearchPlanObserver.Repo, as: ObserverRepo

  @fixture_size 8_192
  @fts_query "needle bridge"
  @trigram_query "postgreql"
  @summary_keys ~w(backend parameter_count candidate_calls nested_statements executed_nodes actual_rows actual_loops buffer_nodes indexes entry_rows_inspected entry_access)a
  @content_indexes ~w(search_entries_fts search_entries_title_trigram search_entries_body_trigram)
  @entry_nodes [
    "Seq Scan",
    "Index Scan",
    "Index Only Scan",
    "Bitmap Heap Scan",
    "Bitmap Index Scan"
  ]

  setup_all do
    {:ok, fixture: canonical_fixture!()}
  end

  for {shape, q, ordinal, index} <- [
        {:fts, @fts_query, 1, "search_entries_fts"},
        {:title_similarity, @trigram_query, 2, "search_entries_title_trigram"}
      ] do
    @query q
    @ordinal ordinal
    @index index

    test "selective #{shape} has an unforced indexed production-role plan", %{fixture: fixture} do
      version_id =
        :crypto.hash(
          :md5,
          fixture.owner_scope_id <> ":knowledge-plan:version:" <> to_string(@ordinal)
        )
        |> Ecto.UUID.load!()

      with_plan_observer(fn repo ->
        Enum.reduce(1..7, nil, fn sample, backend ->
          {page, summary} = observed_search(repo, fixture, @query)
          assert %{items: [item], next_cursor: :done} = page
          assert item.resource_id == resource_id(fixture, @ordinal)
          assert item.resource_version_id == version_id
          assert item.entry_id == "note:" <> version_id
          assert item.rank > 0
          assert summary.parameter_count == 13
          assert summary.candidate_calls == 1
          assert summary.nested_statements == 1
          assert summary.actual_rows == 1
          assert summary.actual_loops > 0
          assert summary.buffer_nodes > 0

          assert @index in summary.indexes,
                 "selective production-role search did not use #{@index}; indexes=#{inspect(summary.indexes)}"

          if backend != nil, do: assert(summary.backend === backend)
          phase = if sample == 1, do: :cold, else: if(sample >= 6, do: :warm, else: :warmup)

          IO.puts(
            "knowledge_search_plan shape=#{@index} sample=#{sample} phase=#{phase} " <>
              "backend=#{summary.backend} candidate_calls=#{summary.candidate_calls} " <>
              "actual_rows=#{summary.actual_rows} actual_loops=#{summary.actual_loops} " <>
              "buffer_nodes=#{summary.buffer_nodes} indexes=#{inspect(summary.indexes)}"
          )

          summary.backend
        end)
      end)
    end
  end

  test "one- and two-character literals honestly inspect most canonical candidates", %{
    fixture: fixture
  } do
    for q <- ["o", "ol"] do
      {page, summary} = executed_plan(fixture, q)

      assert %{items: items, next_cursor: cursor} = page
      assert length(items) == 20
      assert is_binary(cursor)
      assert Enum.all?(items, &(&1.rank >= 1_000_000))
      assert summary.parameter_count == 13
      assert summary.candidate_calls == 1
      assert summary.actual_rows == 21
      assert summary.actual_loops > 0
      assert summary.buffer_nodes > 0
      assert summary.entry_access != []
      inspected = summary.entry_rows_inspected

      # These literals occur in virtually every background title. A sequential
      # or owner-index scan is legitimate; a selective content-index claim is not.
      assert inspected >= div(@fixture_size * 9, 10)

      IO.puts(
        "knowledge_search_plan shape=short_literal codepoints=#{length(String.codepoints(q))} " <>
          "candidate_rows=#{inspected} access=#{inspect(Enum.map(summary.entry_access, &elem(&1, 0)))}"
      )
    end
  end

  test "the fixed five-second deadline fails closed after an observed relation-lock barrier", %{
    fixture: fixture
  } do
    {positive, _plan} = executed_plan(fixture, @fts_query)
    assert %{items: [_], next_cursor: :done} = positive

    start_supervised!({MigrationRepo, pool_size: 2})
    observer = self()
    reference = make_ref()

    blocker =
      Task.async(fn ->
        MigrationRepo.transaction(fn ->
          SafeSQL.query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

          SafeSQL.query!(
            MigrationRepo,
            "LOCK TABLE content.search_entries IN ACCESS EXCLUSIVE MODE"
          )

          %{rows: [[backend, relation]]} =
            SafeSQL.query!(
              MigrationRepo,
              "SELECT pg_backend_pid(), 'content.search_entries'::regclass::oid"
            )

          send(observer, {reference, :locked, backend, relation})

          receive do
            {^reference, :release} -> :ok
          after
            15_000 -> raise "knowledge search plan deadline barrier expired"
          end
        end)
      end)

    try do
      assert_receive {^reference, :locked, blocker_backend, relation}, 5_000

      reader =
        Task.async(fn ->
          RequestRepo.checkout(fn ->
            SafeSQL.query!(RequestRepo, "SELECT search_extensions.similarity('','')")
            before_settings = connection_settings(RequestRepo)

            result =
              ScopedRepo.transact(RequestRepo, scope(fixture), fn repo ->
                SafeSQL.query!(repo, "SET LOCAL statement_timeout = '30s'")
                %{rows: [[backend]]} = SafeSQL.query!(repo, "SELECT pg_backend_pid()")
                send(observer, {reference, :reader, backend})
                KnowledgeSearchStore.search(repo, filters(fixture, @fts_query))
              end)

            assert connection_settings(RequestRepo) == before_settings

            assert %{rows: [[nil, nil]]} =
                     SafeSQL.query!(
                       RequestRepo,
                       "SELECT NULLIF(current_setting('singularity.principal_id',true),''), " <>
                         "NULLIF(current_setting('singularity.vault_id',true),'')"
                     )

            result
          end)
        end)

      try do
        assert_receive {^reference, :reader, reader_backend}, 5_000

        assert await_lock_wait(
                 reader_backend,
                 blocker_backend,
                 relation,
                 System.monotonic_time(:millisecond) + 4_000
               )

        assert {:error,
                %Error{code: :storage_unavailable, retryable?: true, message: nil, details: %{}}} =
                 Task.await(reader, 7_000)
      after
        send(blocker.pid, {reference, :release})
        drain_task(blocker)
        drain_task(reader)
      end
    after
      send(blocker.pid, {reference, :release})
      drain_task(blocker)
    end

    {after_release, _plan} = executed_plan(fixture, @fts_query)
    assert %{items: [_], next_cursor: :done} = after_release
  end

  defp executed_plan(fixture, q) do
    with_plan_observer(fn repo -> observed_search(repo, fixture, q) end)
  end

  defp observed_search(repo, fixture, q) do
    monitors = caller_monitors()

    case KnowledgeSearchPlanObserver.search_summary(repo, scope(fixture), filters(fixture, q)) do
      {:ok, page, summary} ->
        closed? = closed_summary?(summary)
        assert closed?, "plan observer returned non-closed evidence (contents withheld)"
        assert summary.backend > 0
        assert_search_trace_clean(monitors)
        {page, summary}

      _ ->
        flunk("actual production-role search evidence missing (contents withheld)")
    end
  end

  defp with_plan_observer(callback) do
    database = RequestRepo.config()[:database]
    shared = Process.whereis(RequestRepo)
    dynamic = RequestRepo.get_dynamic_repo()
    monitors = caller_monitors()

    {result, diagnostic} =
      KnowledgeSearchPlanObserver.with_diagnostics(fn ->
        KnowledgeSearchPlanObserver.with_observer(database, fn repo ->
          assert repo == ObserverRepo
          assert Process.whereis(RequestRepo) == shared
          assert RequestRepo.get_dynamic_repo() == dynamic
          callback.(repo)
        end)
      end)

    assert Process.whereis(RequestRepo) == shared
    assert RequestRepo.get_dynamic_repo() == dynamic
    assert Process.whereis(ObserverRepo) == nil
    assert KnowledgeSearchPlanObserver.clean?(database)
    assert_search_trace_clean(monitors)

    case result do
      {:ok, value} -> value
      _ -> observer_failure(diagnostic)
    end
  end

  # Validate independently before reporting, and only after the original cleanup
  # assertions. Never inspect an unvalidated diagnostic or the failed result.
  defp observer_failure(nil),
    do: flunk("plan observer failed or leaked state (contents withheld)")

  defp observer_failure(diagnostic) do
    closed? = closed_diagnostic?(diagnostic)
    assert closed?, "plan observer returned non-closed diagnostic (contents withheld)"

    flunk(
      "plan observer failed or leaked state (contents withheld); diagnostic=" <>
        inspect(diagnostic)
    )
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

  defp closed_summary?(summary) when is_map(summary) do
    Enum.sort(Map.keys(summary)) == Enum.sort(@summary_keys) and
      Enum.all?(@summary_keys -- [:indexes, :entry_access], fn key ->
        value = Map.get(summary, key)
        is_integer(value) and value >= 0 and value <= 1_000_000_000
      end) and is_list(summary.indexes) and length(summary.indexes) <= 3 and
      Enum.all?(summary.indexes, &(&1 in @content_indexes)) and
      is_list(summary.entry_access) and length(summary.entry_access) <= 4_096 and
      Enum.all?(summary.entry_access, fn
        {name, count} ->
          name in @entry_nodes and is_integer(count) and count >= 0 and count <= 1_000_000_000

        _ ->
          false
      end)
  end

  defp closed_summary?(_summary), do: false

  defp caller_monitors do
    {:monitors, monitors} = Process.info(self(), :monitors)
    Enum.sort(monitors)
  end

  defp assert_search_trace_clean(monitors) do
    assert {:flags, []} = :erlang.trace_info(self(), :flags)
    assert {:traced, false} = :erlang.trace_info({SafeSQL, :query, 4}, :traced)
    assert caller_monitors() == monitors
  end

  defp authorized_source! do
    source = KnowledgeFixtures.source!()
    capabilities = ["note.read", "asset.read"]

    Fixtures.with_owner(fn ->
      for name <- capabilities do
        SafeSQL.query!(
          MigrationRepo,
          "INSERT INTO core.capabilities(id,name) VALUES($1,$2) ON CONFLICT(name) DO NOTHING",
          [KnowledgeFixtures.uuid(), name]
        )
      end

      result =
        SafeSQL.query!(
          MigrationRepo,
          """
          INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id)
          SELECT $1,$2,capability.id FROM core.capabilities AS capability
          WHERE capability.name=ANY($3::text[])
          ON CONFLICT(principal_id,vault_id,capability_id) DO NOTHING
          """,
          [source.principal_id, source.vault_id, capabilities]
        )

      assert result.num_rows == length(capabilities)
    end)

    source
  end

  defp canonical_fixture! do
    source = authorized_source!()
    owner = Ecto.UUID.load!(source.vault_id)
    fixture = Map.put(source, :owner_scope_id, owner)

    Fixtures.with_owner(fn ->
      assert %{num_rows: @fixture_size} =
               SafeSQL.query!(
                 MigrationRepo,
                 """
                 INSERT INTO content.resources
                   (id,vault_id,classification,kind,current_version_id,title)
                 SELECT md5($1::uuid::text || ':knowledge-plan:resource:' || ordinal)::uuid,
                        $1, 'private', 'note',
                        md5($1::uuid::text || ':knowledge-plan:version:' || ordinal)::uuid,
                        CASE ordinal WHEN 1 THEN 'Neutral heading'
                                     WHEN 2 THEN 'postgresql'
                                     ELSE 'Archive folio ' || ordinal END
                 FROM generate_series(1,$2::integer) AS fixture(ordinal)
                 """,
                 [source.vault_id, @fixture_size]
               )

      assert %{num_rows: @fixture_size} =
               SafeSQL.query!(
                 MigrationRepo,
                 """
                 INSERT INTO content.resource_versions
                   (id,resource_id,vault_id,classification,revision,inserted_at)
                 SELECT current_version_id,id,vault_id,classification,0,
                        '2026-10-09T00:00:00Z'::timestamptz
                 FROM content.resources WHERE vault_id=$1 AND kind='note'
                 """,
                 [source.vault_id]
               )

      assert %{num_rows: @fixture_size} =
               SafeSQL.query!(
                 MigrationRepo,
                 """
                 INSERT INTO content.note_versions
                   (resource_version_id,resource_id,vault_id,classification,title,markdown,
                    created_by_principal_id,inserted_at)
                 SELECT current_version_id,id,vault_id,classification,title,
                        CASE WHEN title='Neutral heading' THEN 'needle disconnected bridge'
                             ELSE 'routine catalog material' END,
                        $2, '2026-10-09T00:00:00Z'::timestamptz
                 FROM content.resources WHERE vault_id=$1 AND kind='note'
                 """,
                 [source.vault_id, source.principal_id]
               )
    end)

    for ordinals <- Enum.chunk_every(1..@fixture_size, 512) do
      ids = Enum.map(ordinals, &(fixture |> resource_id(&1) |> Ecto.UUID.dump!()))
      batch_size = length(ids)

      Fixtures.with_owner(fn ->
        assert %{rows: rows, num_rows: ^batch_size} =
                 SafeSQL.query!(
                   MigrationRepo,
                   """
                   SELECT content.reconcile_search_resource_internal($1,id)
                   FROM content.resources
                   WHERE vault_id=$1 AND kind='note' AND id=ANY($2::uuid[])
                   ORDER BY id
                   """,
                   [source.vault_id, ids]
                 )

        assert Enum.all?(rows, &(&1 == [1]))
      end)
    end

    Fixtures.with_owner(fn ->
      # Finish normal post-load maintenance uniformly before measuring plans.
      for index <- @content_indexes do
        assert %{rows: [[pages]]} =
                 SafeSQL.query!(
                   MigrationRepo,
                   "SELECT pg_catalog.gin_clean_pending_list($1::text::regclass)",
                   ["content." <> index]
                 )

        assert is_integer(pages) and pages >= 0 and pages <= 1_000_000_000
        IO.puts("knowledge_search_plan index=#{index} pending_pages_cleaned=#{pages}")
      end

      for table <- ["resources", "resource_versions", "note_versions", "search_entries"] do
        SafeSQL.query!(MigrationRepo, "ANALYZE content." <> table)
      end

      assert %{rows: [[@fixture_size]]} =
               SafeSQL.query!(
                 MigrationRepo,
                 "SELECT count(*) FROM content.search_entries WHERE vault_id=$1",
                 [source.vault_id]
               )
    end)

    fixture
  end

  defp resource_id(fixture, ordinal) do
    :crypto.hash(
      :md5,
      fixture.owner_scope_id <> ":knowledge-plan:resource:" <> to_string(ordinal)
    )
    |> Ecto.UUID.load!()
  end

  defp scope(fixture), do: Map.take(fixture, [:principal_id, :vault_id])

  defp filters(fixture, q) do
    %{
      owner_scope_id: fixture.owner_scope_id,
      classification: :private,
      q: q,
      kind: :note,
      tag_ids: [],
      limit: 20,
      cursor: nil,
      policy_version: 1
    }
  end

  defp connection_settings(repo) do
    %{rows: [settings]} =
      SafeSQL.query!(repo, """
      SELECT current_setting('statement_timeout'),
             current_setting('pg_trgm.similarity_threshold',true)
      """)

    settings
  end

  defp await_lock_wait(reader, blocker, relation, deadline) do
    %{rows: [[waiting]]} =
      SafeSQL.query!(
        MigrationRepo,
        """
        SELECT EXISTS (
          SELECT FROM pg_locks
          WHERE pid=$1 AND relation=$3::oid AND mode='AccessShareLock' AND NOT granted
        ) AND $2::integer = ANY(pg_blocking_pids($1))
        """,
        [reader, blocker, relation]
      )

    cond do
      waiting -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> await_lock_wait(reader, blocker, relation, deadline)
    end
  end

  defp drain_task(task) do
    if Process.alive?(task.pid),
      do: Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill),
      else: Task.shutdown(task, :brutal_kill)
  end
end
