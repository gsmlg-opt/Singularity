defmodule Singularity.Storage.KnowledgeSearchPlanObserver do
  @moduledoc false

  alias Singularity.Storage.{RequestRepo, SafeSQL, ScopedRepo}

  defmodule Repo do
    @moduledoc false

    use Ecto.Repo,
      otp_app: :singularity_storage,
      adapter: Ecto.Adapters.Postgres

    @impl true
    def default_options(_operation), do: [telemetry_event: nil]
  end

  @defaults [
    {"session_preload_libraries", "auto_explain"},
    {"auto_explain.log_min_duration", "0"},
    {"auto_explain.log_analyze", "on"},
    {"auto_explain.log_nested_statements", "on"},
    {"auto_explain.log_format", "json"},
    {"auto_explain.log_level", "notice"},
    {"auto_explain.log_parameter_max_length", "0"},
    {"auto_explain.log_timing", "off"},
    {"auto_explain.log_buffers", "on"},
    {"auto_explain.log_verbose", "off"},
    {"auto_explain.sample_rate", "1"},
    {"client_min_messages", "notice"},
    {"log_min_messages", "warning"}
  ]
  @keys Enum.map(@defaults, &elem(&1, 0))
  @preloads ~w(session_preload_libraries shared_preload_libraries local_preload_libraries)
  @logging [{"client_min_messages", "notice"}, {"log_min_messages", "warning"}]
  @errors [
    :observer_invalid_target,
    :observer_admin_failed,
    :observer_configuration_conflict,
    :observer_setup_failed,
    :observer_callback_failed,
    :observer_cleanup_failed,
    :observer_evidence_missing
  ]

  def with_observer(database, callback, fault \\ :none)
      when is_function(callback, 1) and fault in [:none, :after_install] do
    with {:ok, target} <- target(database) do
      with_admin(target, fn connection ->
        safe_settings!(settings(connection, target))
        require_ok!(with_fresh_repo(&ordinary_connection!(&1, target)))
        baseline = change_defaults!(connection, target, @defaults, :install)

        # Before reset, this scope owns the installed defaults. After reset,
        # only the dedicated repo remains owned: callback cleanup never resets.
        started =
          protect(:observer_setup_failed, fn ->
            ensure!(fault != :after_install)
            start_observer_repo!()
          end)

        case started do
          {:error, _} ->
            cleanup_before_reset(connection, target, baseline)

          owned when is_pid(owned) ->
            using_owned_repo(owned, fn ->
              ready =
                protect(:observer_setup_failed, fn ->
                  observer_connection!(Repo, target)
                  change_defaults!(connection, target, @defaults, :reset, baseline)
                end)

              case ready do
                :ok -> invoke_callback(callback, Repo)
                {:error, _} -> cleanup_before_reset(connection, target, baseline)
              end
            end)
        end
      end)
    end
  end

  def clean?(database) do
    result =
      with {:ok, target} <- target(database) do
        with_admin(target, fn connection ->
          safe_settings!(settings(connection, target))
          with_fresh_repo(&ordinary_connection!(&1, target))
        end)
      end

    result == :ok
  end

  def with_conflicting_default(database, callback) when is_function(callback, 0) do
    with {:ok, target} <- target(database) do
      with_admin(target, fn connection ->
        Enum.each(
          [{"auto_explain.log_min_duration", "-1"}, {"auto_explain.log_wal", "on"}],
          fn conflict ->
            require_ok!(with_fixture_defaults(connection, target, [conflict], :web, callback))
          end
        )
      end)
    end
  end

  def with_inherited_logging(database, callback) when is_function(callback, 0) do
    with {:ok, target} <- target(database) do
      with_admin(target, &with_fixture_defaults(&1, target, @logging, :database, callback))
    end
  end

  defp with_fixture_defaults(connection, target, defaults, scope, callback) do
    baseline = change_defaults!(connection, target, defaults, :install, nil, scope)

    try do
      before = settings(connection, target)
      result = protect(:observer_callback_failed, callback)
      ensure!(settings(connection, target) == before, :observer_cleanup_failed)
      result
    after
      protect_cleanup!(fn ->
        change_defaults!(connection, target, defaults, :reset, baseline, scope)
      end)
    end
  end

  # Pure validation only: callers cannot inject these options into an observer.
  def startup_safe?(config) do
    Keyword.keyword?(config) and
      Enum.all?(config, fn {key, value} ->
        cond do
          key in [:options, :after_connect, :configure] ->
            is_nil(value)

          key == :parameters ->
            value in [nil, []]

          Atom.to_string(key) in @preloads ->
            false

          String.starts_with?(Atom.to_string(key), "auto_explain.") ->
            false

          key == :url and is_nil(value) ->
            true

          key == :url and is_binary(value) ->
            uri = URI.parse(value)
            uri.scheme in ["postgres", "postgresql"] and uri.query == nil

          key == :url ->
            false

          true ->
            true
        end
      end)
  rescue
    _ -> false
  end

  def authorization_summary(Repo = repo, scope) do
    protect(:observer_evidence_missing, fn ->
      with {:ok, target} <- target(RequestRepo.config()[:database]) do
        backend = observer_connection!(repo, target)

        source =
          case web_query!(repo, """
               SELECT p.prosrc, p.oid::bigint, p.prosecdef, p.provolatile::text,
                      owner.rolname, language.lanname
               FROM pg_catalog.pg_proc AS p
               JOIN pg_catalog.pg_roles AS owner ON owner.oid = p.proowner
               JOIN pg_catalog.pg_language AS language ON language.oid = p.prolang
               WHERE p.oid = 'core.live_principal_authorization()'::regprocedure
               """).rows do
            [[source, oid, true, "s", "singularity_authorization_definer", "sql"]] when oid > 0 ->
              source

            _ ->
              throw(:observer_evidence_missing)
          end

        ScopedRepo.transact(repo, scope, fn repo ->
          case SafeSQL.query(repo, "SELECT principal_id FROM core.live_principal_authorization()") do
            {:ok, raw} -> summarize(raw, source, scope.principal_id, backend)
            _ -> {:error, :observer_evidence_missing}
          end
        end)
      end
    end)
  end

  @candidate_marker "/* singularity:search_candidate_ids:v1 */"
  @candidate_migration Path.expand(
                         "../../priv/repo/migrations/20261010000000_create_guarded_search_candidates.exs",
                         __DIR__
                       )
  @drain_statement "SELECT pg_catalog.pg_backend_pid()"
  @record_limit 1_048_576
  @node_limit 4_096
  @depth_limit 64
  @content_indexes ~w(search_entries_fts search_entries_title_trigram search_entries_body_trigram)
  @entry_access_types [
    "Seq Scan",
    "Index Scan",
    "Index Only Scan",
    "Bitmap Heap Scan",
    "Bitmap Index Scan"
  ]
  @search_node_types @entry_access_types ++
                       [
                         "Limit",
                         "Sort",
                         "Incremental Sort",
                         "CTE Scan",
                         "Nested Loop",
                         "Hash Join",
                         "Merge Join",
                         "Aggregate",
                         "Unique",
                         "Append",
                         "Merge Append",
                         "Result",
                         "BitmapOr",
                         "BitmapAnd",
                         "Materialize",
                         "Memoize",
                         "Hash",
                         "Subquery Scan",
                         "Function Scan",
                         "SetOp"
                       ]
  @buffer_fields [
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
  ]

  def search_summary(Repo = repo, scope, query) do
    protect(:observer_evidence_missing, fn ->
      require_search_trace_free!()

      with {:ok, target} <- target(RequestRepo.config()[:database]) do
        backend = observer_connection!(repo, target)
        candidate_sql = candidate_source!(repo)

        ScopedRepo.transact(repo, scope, fn scoped ->
          case capture_original_search!(scoped, query) do
            {{:ok, page}, calls} ->
              case validate_search_envelope(%{
                     repo: scoped,
                     backend: backend,
                     candidate_sql: candidate_sql,
                     q: query.q,
                     calls: calls
                   }) do
                {:ok, summary} ->
                  # Preserve the original plan test's exact local settings
                  # assertion after the captured pair and owned trace teardown.
                  require_search_trace_free!()

                  case SafeSQL.query(scoped, """
                       SELECT current_user, current_setting('row_security'),
                              current_setting('enable_seqscan'), current_setting('statement_timeout'),
                              current_setting('pg_trgm.similarity_threshold')
                       """) do
                    {:ok, %{rows: [["singularity_web", "on", "on", "5s", "0.3"]]}} ->
                      {:ok, page, summary}

                    _ ->
                      {:error, :observer_evidence_missing}
                  end

                _ ->
                  {:error, :observer_evidence_missing}
              end

            _ ->
              {:error, :observer_evidence_missing}
          end
        end)
      end
    end)
  end

  def search_summary(_repo, _scope, _query), do: {:error, :observer_evidence_missing}

  # Synthetic test envelopes use the same private validator as actual capture.
  # Only search_summary performs the mandatory live catalog/migration proof.
  def validate_search_envelope(envelope) do
    protect(:observer_evidence_missing, fn ->
      %{repo: Repo, backend: backend, candidate_sql: candidate_sql, q: q, calls: calls} = envelope

      ensure!(
        bounded(backend) > 0 and is_binary(candidate_sql) and
          byte_size(candidate_sql) <= @record_limit and is_binary(q),
        :observer_evidence_missing
      )

      {statement, parameters, original, drained} = search_drain_pair!(calls)

      ensure!(
        original.command == :select and original.connection_id === backend and
          drained.command == :select and drained.connection_id === backend and
          drained.num_rows === 1 and drained.rows === [[backend]] and
          length(parameters) == 13 and Enum.at(parameters, 1) == q,
        :observer_evidence_missing
      )

      bounded(original.num_rows)

      {candidate_plans, outer} =
        original_search_plans!(original, drained, statement, candidate_sql)

      candidate_nodes = Enum.flat_map(candidate_plans, &search_nodes!/1)
      outer_nodes = search_nodes!(outer)

      ensure!(
        length(candidate_nodes) + length(outer_nodes) <= @node_limit,
        :observer_evidence_missing
      )

      calls = original_candidate_calls!(outer_nodes, candidate_plans, q)

      {:ok,
       search_metadata!(backend, original, parameters, calls, candidate_nodes, outer, outer_nodes)}
    end)
  end

  defp candidate_source!(repo) do
    rows =
      web_query!(repo, """
      SELECT p.prosrc, p.prosecdef, p.provolatile::text, p.proparallel::text,
             p.proisstrict, p.proretset, owner.rolname, language.lanname,
             pg_catalog.pg_get_function_arguments(p.oid),
             pg_catalog.pg_get_function_result(p.oid), p.proconfig
      FROM pg_catalog.pg_proc AS p
      JOIN pg_catalog.pg_roles AS owner ON owner.oid=p.proowner
      JOIN pg_catalog.pg_language AS language ON language.oid=p.prolang
      WHERE p.oid=pg_catalog.to_regprocedure('content.search_candidate_ids(text,text,uuid[])')
      """).rows

    source =
      case rows do
        [
          [
            source,
            true,
            "v",
            "u",
            false,
            true,
            "singularity_table_owner",
            "plpgsql",
            "requested_q text, requested_kind text, requested_tag_ids uuid[]",
            "TABLE(entry_id text)",
            config
          ]
        ]
        when is_binary(source) and is_list(config) ->
          ensure!(
            Enum.sort(config) == [
              "pg_trgm.similarity_threshold=0.3",
              "search_path=pg_catalog, content, core, identity, pg_temp"
            ],
            :observer_evidence_missing
          )

          source

        _ ->
          throw(:observer_evidence_missing)
      end

    {:ok, ast} = @candidate_migration |> File.read!() |> Code.string_to_quoted()

    {_ast, creates} =
      Macro.prewalk(ast, [], fn
        {:execute, _, [sql]} = node, found when is_binary(sql) ->
          if String.starts_with?(
               String.trim(sql),
               "CREATE FUNCTION content.search_candidate_ids("
             ),
             do: {node, [sql | found]},
             else: {node, found}

        node, found ->
          {node, found}
      end)

    literal =
      case creates do
        [sql] ->
          case String.split(sql, "$function$") do
            [_header, body, _end] -> body
            _ -> throw(:observer_evidence_missing)
          end

        _ ->
          throw(:observer_evidence_missing)
      end

    ensure!(
      String.trim(literal) == String.trim(source) and
        length(String.split(source, @candidate_marker)) == 2,
      :observer_evidence_missing
    )

    # PL/pgSQL preserves interior source bytes from WITH through the final token.
    case String.split(source, "RETURN QUERY") do
      [_guard, select] ->
        case Regex.run(~r/\A\s*(WITH .+);\s*END\s*\z/s, select) do
          [_matched, sql] -> String.trim(sql)
          _ -> throw(:observer_evidence_missing)
        end

      _ ->
        throw(:observer_evidence_missing)
    end
  end

  defp require_search_trace_free! do
    ensure!(
      :erlang.trace_info(self(), :flags) == {:flags, []} and
        :erlang.trace_info({SafeSQL, :query, 4}, :traced) == {:traced, false},
      :observer_evidence_missing
    )
  end

  defp capture_original_search!(repo, query) do
    require_search_trace_free!()
    caller = self()
    reference = make_ref()
    function = {SafeSQL, :query, 4}

    {collector, monitor} =
      spawn_monitor(fn ->
        try do
          collect_search_pairs(caller, reference, [], [], true)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
      end)

    try do
      ensure!(
        :erlang.trace_pattern(function, [{:_, [], [{:return_trace}]}], [:local]) == 1,
        :observer_evidence_missing
      )

      try do
        ensure!(
          :erlang.trace(caller, true, [:call, {:tracer, collector}]) == 1,
          :observer_evidence_missing
        )

        result = Singularity.Storage.Postgres.KnowledgeSearchStore.search(repo, query)

        # This fixed unnamed Bind closes the original portal, without replaying
        # the search. Its result owns the delayed original outer-plan NOTICE.
        case result do
          {:ok, _page} -> SafeSQL.query(repo, @drain_statement, [], [])
          _ -> :ok
        end

        delivered = :erlang.trace_delivered(caller)

        receive do
          {:trace_delivered, ^caller, ^delivered} -> :ok
        after
          5_000 -> throw(:observer_evidence_missing)
        end

        send(collector, {reference, :collect})

        receive do
          {^reference, :pairs, true, pairs} -> {result, pairs}
          {^reference, :pairs, _valid, _pairs} -> throw(:observer_evidence_missing)
        after
          5_000 -> throw(:observer_evidence_missing)
        end
      after
        :erlang.trace(caller, false, [:call])
      end
    after
      try do
        :erlang.trace_pattern(function, false, [:local])
      after
        stop_search_collector!(collector, monitor, reference)
      end
    end
  end

  defp collect_search_pairs(caller, reference, stack, pairs, valid) do
    receive do
      {:trace, ^caller, :call, {SafeSQL, :query, [repo, statement, params, options]}}
      when is_binary(statement) and is_list(params) and is_list(options) ->
        collect_search_pairs(
          caller,
          reference,
          [{repo, statement, params, options} | stack],
          pairs,
          valid and stack == []
        )

      {:trace, ^caller, :return_from, {SafeSQL, :query, 4}, result} ->
        case stack do
          [{repo, statement, params, options} | rest] ->
            collect_search_pairs(
              caller,
              reference,
              rest,
              [{repo, statement, params, options, result} | pairs],
              valid
            )

          [] ->
            collect_search_pairs(caller, reference, [], pairs, false)
        end

      {^reference, :collect} ->
        send(caller, {reference, :pairs, valid and stack == [], Enum.reverse(pairs)})
        collect_search_pairs(caller, reference, stack, pairs, valid)

      {^reference, :stop} ->
        :ok

      _ ->
        collect_search_pairs(caller, reference, stack, pairs, false)
    end
  end

  defp stop_search_collector!(collector, monitor, reference) do
    send(collector, {reference, :stop})

    receive do
      {:DOWN, ^monitor, :process, ^collector, :normal} -> :ok
      {:DOWN, ^monitor, :process, ^collector, _} -> throw(:observer_evidence_missing)
    after
      5_000 ->
        Process.exit(collector, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^collector, _} -> throw(:observer_evidence_missing)
        after
          1_000 -> throw(:observer_evidence_missing)
        end
    end
  end

  defp search_drain_pair!(calls) when is_list(calls) do
    ensure!(
      Enum.all?(calls, fn
        {Repo, statement, params, options, _result}
        when is_binary(statement) and is_list(params) and is_list(options) ->
          true

        _ ->
          false
      end),
      :observer_evidence_missing
    )

    {preceding, pair} = Enum.split(calls, -2)

    ensure!(
      Enum.all?(preceding, fn {_repo, sql, _params, _opts, _result} ->
        not search_statement?(sql) and sql != @drain_statement
      end),
      :observer_evidence_missing
    )

    case pair do
      [
        {Repo, statement, parameters, search_options, {:ok, %Postgrex.Result{} = original}},
        {Repo, @drain_statement, [], drain_options, {:ok, %Postgrex.Result{} = drained}}
      ] ->
        ensure!(
          search_statement?(statement) and unnamed_binary?(search_options) and
            unnamed_binary?(drain_options),
          :observer_evidence_missing
        )

        {statement, parameters, original, drained}

      _ ->
        throw(:observer_evidence_missing)
    end
  end

  defp search_drain_pair!(_calls), do: throw(:observer_evidence_missing)

  defp search_statement?(sql),
    do:
      String.starts_with?(sql, "WITH input AS (") and
        String.contains?(sql, "scored AS MATERIALIZED")

  defp unnamed_binary?(options) do
    Keyword.keyword?(options) and
      Keyword.get_values(options, :cache_statement) in [[], [nil]] and
      Keyword.get_values(options, :query_type) in [[], [:binary]]
  end

  defp original_search_plans!(original, drained, statement, candidate_sql) do
    candidates = selected_search_plans!(original.messages, :original, statement, candidate_sql)
    outer = selected_search_plans!(drained.messages, :drain, statement, candidate_sql)

    case {candidates, outer} do
      {candidate_plans, [{:outer, plan}]} ->
        ensure!(
          Enum.all?(candidate_plans, &match?({:candidate, _}, &1)) and
            bounded(plan["Actual Rows"]) == original.num_rows,
          :observer_evidence_missing
        )

        {Enum.map(candidate_plans, &elem(&1, 1)), plan}

      _ ->
        throw(:observer_evidence_missing)
    end
  end

  defp selected_search_plans!(messages, channel, statement, candidate_sql)
       when is_list(messages) do
    Enum.flat_map(messages, fn message ->
      text = Map.get(message, :message, "")

      selected? =
        Map.get(message, :severity) == "NOTICE" and is_binary(text) and
          String.starts_with?(text, "duration: ") and
          (String.contains?(text, @candidate_marker) or
             (String.contains?(text, "WITH input AS (") and
                String.contains?(text, "scored AS MATERIALIZED")))

      if selected? do
        context = Map.get(message, :where, "")
        ensure!(is_nil(context) or is_binary(context), :observer_evidence_missing)

        ensure!(
          byte_size(text) + if(is_nil(context), do: 0, else: byte_size(context)) <= @record_limit,
          :observer_evidence_missing
        )

        [_prefix, json] = String.split(text, "plan:\n", parts: 2)
        %{"Query Text" => sql, "Plan" => plan} = JSON.decode!(json)
        ensure!(is_binary(sql) and is_map(plan), :observer_evidence_missing)

        cond do
          String.trim(sql) == candidate_sql ->
            ensure!(
              channel == :original and candidate_context?(context, sql),
              :observer_evidence_missing
            )

            [{:candidate, plan}]

          String.trim(sql) == String.trim(statement) ->
            ensure!(channel == :drain, :observer_evidence_missing)
            [{:outer, plan}]

          String.contains?(sql, @candidate_marker) ->
            throw(:observer_evidence_missing)

          true ->
            []
        end
      else
        []
      end
    end)
  end

  defp selected_search_plans!(_messages, _channel, _statement, _candidate_sql),
    do: throw(:observer_evidence_missing)

  defp candidate_context?(context, sql) when is_binary(context) do
    prefix = "SQL statement \"" <> sql <> "\"\n"

    if String.starts_with?(context, prefix) do
      frames = binary_part(context, byte_size(prefix), byte_size(context) - byte_size(prefix))

      case Regex.run(
             ~r/\APL\/pgSQL function (?:content\.)?search_candidate_ids\(text,text,uuid\[\]\) line ([0-9]{1,10}) at RETURN QUERY(?:\nunnamed portal with parameters: [\s\S]*)?\z/,
             frames
           ) do
        [_frame, line] -> bounded(String.to_integer(line)) > 0
        _ -> false
      end
    else
      false
    end
  end

  defp candidate_context?(_context, _sql), do: false

  defp original_candidate_calls!(outer_nodes, candidate_plans, q) do
    scans =
      Enum.filter(outer_nodes, fn node ->
        node["Node Type"] == "Function Scan" and node["Function Name"] == "search_candidate_ids"
      end)

    case {q, candidate_plans, scans} do
      {"", [], []} ->
        0

      {q, [plan], [scan]} when is_binary(q) and q != "" ->
        ensure!(
          bounded(scan["Actual Loops"]) == 1 and bounded(plan["Actual Loops"]) > 0,
          :observer_evidence_missing
        )

        1

      _ ->
        throw(:observer_evidence_missing)
    end
  end

  defp search_nodes!(plan), do: search_nodes!([{plan, 1}], [], 0)

  defp search_nodes!([], nodes, _count), do: Enum.reverse(nodes)

  defp search_nodes!([{node, depth} | remaining], nodes, count) when is_map(node) do
    ensure!(
      depth <= @depth_limit and count < @node_limit and node["Node Type"] in @search_node_types,
      :observer_evidence_missing
    )

    bounded(node["Actual Rows"])
    bounded(node["Actual Loops"])
    bounded(Map.get(node, "Rows Removed by Filter", 0))

    Enum.each(@buffer_fields, fn field ->
      if Map.has_key?(node, field), do: bounded(node[field])
    end)

    children = Map.get(node, "Plans", [])
    ensure!(is_list(children), :observer_evidence_missing)
    pending = Enum.map(children, &{&1, depth + 1}) ++ remaining
    search_nodes!(pending, [node | nodes], count + 1)
  end

  defp search_nodes!(_pending, _nodes, _count), do: throw(:observer_evidence_missing)

  defp search_metadata!(backend, raw, parameters, calls, candidate_nodes, outer, outer_nodes) do
    executed_candidate = Enum.filter(candidate_nodes, &(&1["Actual Loops"] > 0))
    executed_outer = Enum.filter(outer_nodes, &(&1["Actual Loops"] > 0))
    executed = executed_outer ++ executed_candidate

    outer_buffers? =
      Enum.any?(executed_outer, fn node ->
        Enum.any?(@buffer_fields, &Map.has_key?(node, &1))
      end)

    buffers =
      Enum.count(executed, fn node ->
        Enum.any?(@buffer_fields, &Map.has_key?(node, &1))
      end)

    ensure!(
      bounded(outer["Actual Rows"]) == bounded(raw.num_rows) and
        bounded(outer["Actual Loops"]) > 0 and outer_buffers? and buffers > 0,
      :observer_evidence_missing
    )

    indexes =
      executed_candidate
      |> Enum.flat_map(fn node ->
        if node["Index Name"] in @content_indexes, do: [node["Index Name"]], else: []
      end)
      |> Enum.uniq()
      |> Enum.sort()

    access =
      executed
      |> Enum.flat_map(fn node ->
        if node["Relation Name"] == "search_entries" do
          ensure!(node["Node Type"] in @entry_access_types, :observer_evidence_missing)

          count =
            bounded(
              (node["Actual Rows"] + Map.get(node, "Rows Removed by Filter", 0)) *
                node["Actual Loops"]
            )

          [{node["Node Type"], count}]
        else
          []
        end
      end)

    %{
      backend: bounded(backend),
      parameter_count: bounded(length(parameters)),
      candidate_calls: bounded(calls),
      nested_statements: if(candidate_nodes == [], do: 0, else: 1),
      executed_nodes: bounded(length(executed)),
      actual_rows: bounded(outer["Actual Rows"]),
      actual_loops: bounded(outer["Actual Loops"]),
      buffer_nodes: bounded(buffers),
      indexes: indexes,
      entry_rows_inspected:
        bounded(Enum.reduce(access, 0, fn {_name, count}, total -> total + count end)),
      entry_access: access
    }
  end

  defp summarize(raw, source, principal, backend) do
    ensure!(raw.connection_id == backend, :observer_evidence_missing)

    ensure!(
      case raw.rows do
        [[returned]] -> Ecto.UUID.cast(returned) == Ecto.UUID.cast(principal)
        _ -> false
      end,
      :observer_evidence_missing
    )

    plans = Enum.flat_map(raw.messages, &authorization_plan(&1, source))
    ensure!(plans != [], :observer_evidence_missing)
    [root | _] = plans
    executed = plans |> Enum.flat_map(&nodes/1) |> Enum.filter(&(bounded(&1["Actual Loops"]) > 0))

    buffers =
      Enum.count(executed, fn node ->
        Enum.any?(["Shared Hit Blocks", "Shared Read Blocks"], fn key ->
          Map.has_key?(node, key) and bounded(node[key]) >= 0
        end)
      end)

    ensure!(
      root["Actual Rows"] == 1 and bounded(root["Actual Loops"]) > 0 and buffers > 0,
      :observer_evidence_missing
    )

    {:ok,
     %{
       backend: bounded(backend),
       nested_statements: bounded(length(plans)),
       executed_nodes: bounded(length(executed)),
       actual_rows: bounded(root["Actual Rows"]),
       actual_loops: bounded(root["Actual Loops"]),
       buffer_nodes: bounded(buffers),
       indexes: []
     }}
  end

  defp authorization_plan(message, source) do
    text = Map.get(message, :message, "")
    context = Map.get(message, :where, "")

    with true <- Map.get(message, :severity) == "NOTICE",
         true <- String.starts_with?(text, "duration: "),
         true <- String.contains?(context, ~s(SQL function "live_principal_authorization")),
         [_prefix, json] <- String.split(text, "plan:\n", parts: 2),
         {:ok, %{"Query Text" => query, "Plan" => plan}} <- JSON.decode(json),
         true <- normalized_sql(query) == normalized_sql(source) do
      [plan]
    else
      _ -> []
    end
  end

  defp normalized_sql(sql) do
    sql |> String.trim() |> String.trim_trailing(";") |> String.replace(~r/\s+/, " ")
  end

  defp nodes(%{"Plans" => children} = node), do: [node | Enum.flat_map(children, &nodes/1)]
  defp nodes(node) when is_map(node), do: [node]
  defp bounded(value) when is_integer(value) and value in 0..1_000_000_000, do: value
  defp bounded(_), do: throw(:observer_evidence_missing)

  defp with_admin(target, callback) do
    protect(:observer_admin_failed, fn ->
      options =
        admin_options(
          URI.parse(System.fetch_env!("SINGULARITY_ROLE_PROVISIONER_DATABASE_URL")),
          target
        )

      {:ok, connection} = Postgrex.start_link(options)
      Process.unlink(connection)

      try do
        identity =
          private_query!(
            connection,
            """
            SELECT current_database(), current_setting('data_directory'),
                   current_setting('listen_addresses'), rolsuper
            FROM pg_catalog.pg_roles WHERE rolname = session_user
            """,
            []
          ).rows

        ensure!(identity == [[target.database, target.data, "", true]], :observer_admin_failed)

        preloads =
          private_query!(
            connection,
            """
            SELECT name, setting, source, reset_val, pending_restart
            FROM pg_catalog.pg_settings WHERE name = ANY($1::text[]) ORDER BY name
            """,
            [@preloads]
          ).rows

        ensure!(
          length(preloads) == length(@preloads) and
            Enum.all?(preloads, fn [name, setting, source, reset, pending] ->
              name in @preloads and setting == "" and reset == "" and pending == false and
                source in ["default", "configuration file", "command line"]
            end),
          :observer_configuration_conflict
        )

        callback.(connection)
      after
        stop_owned!(connection)
      end
    end)
  end

  defp admin_options(uri, target) do
    parameters = URI.decode_query(uri.query || "")
    userinfo = String.split(uri.userinfo || "", ":", parts: 2) |> Enum.map(&URI.decode/1)

    uri_user =
      case List.first(userinfo) do
        "" -> nil
        value -> value
      end

    username =
      parameters["user"] || uri_user || System.get_env("PGUSER") || System.get_env("USER")

    socket = parameters["host"] || uri.host

    port =
      parameters["port"] ||
        if(uri.port, do: Integer.to_string(uri.port), else: System.get_env("PGPORT"))

    ensure!(
      uri.scheme in ["postgres", "postgresql"] and uri.fragment == nil and
        not String.contains?(uri.authority || "", ",") and
        Enum.all?(Map.keys(parameters), &(&1 in ~w(host port user password dbname))) and
        socket == target.socket and port == Integer.to_string(target.port) and
        is_binary(username) and username != "",
      :observer_admin_failed
    )

    [
      socket_dir: socket,
      port: target.port,
      username: username,
      password: parameters["password"] || Enum.at(userinfo, 1),
      database: target.database,
      backoff_type: :stop
    ]
  end

  defp settings(connection, target) do
    private_query!(
      connection,
      """
      SELECT settings.setdatabase = (SELECT oid FROM pg_catalog.pg_database WHERE datname=$1)
             AND settings.setrole = 'singularity_web'::regrole::oid,
             settings.setdatabase::bigint, settings.setrole::bigint, configuration
      FROM pg_catalog.pg_db_role_setting AS settings
      CROSS JOIN LATERAL unnest(settings.setconfig) AS configuration
      WHERE settings.setdatabase IN (0, (SELECT oid FROM pg_catalog.pg_database WHERE datname=$1))
        AND settings.setrole IN (0, 'singularity_web'::regrole::oid)
      ORDER BY settings.setdatabase, settings.setrole, configuration
      """,
      [target.database]
    ).rows
    |> Enum.map(fn [own, database, role, configuration] ->
      [key, value] = String.split(configuration, "=", parts: 2)
      {own, {database, role}, key, value}
    end)
  end

  defp safe_settings!(settings) do
    Enum.each(settings, fn {own, _scope, key, value} ->
      compatible = not own and {key, value} in @logging

      ensure!(
        (key not in @keys and key not in @preloads and
           not String.starts_with?(key, "auto_explain.")) or compatible,
        :observer_configuration_conflict
      )
    end)
  end

  defp owned_setting?({true, _scope, _key, _value}, :web), do: true
  defp owned_setting?({false, {database, 0}, _key, _value}, :database), do: database > 0
  defp owned_setting?(_setting, _scope), do: false

  defp has_setting?(settings, scope, key, value) do
    Enum.any?(settings, fn {_own, _identity, name, configured} = setting ->
      owned_setting?(setting, scope) and name == key and configured == value
    end)
  end

  defp change_defaults!(connection, target, defaults, mode, baseline \\ nil, scope \\ :web) do
    {:ok, result} =
      Postgrex.transaction(
        connection,
        fn tx ->
          private_query!(
            tx,
            "SELECT pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended($1, 0))",
            ["singularity:test:plan-observer:" <> target.database]
          )

          current = settings(tx, target)

          case mode do
            :install ->
              safe_settings!(current)

              Enum.each(defaults, fn {key, _value} ->
                ensure!(
                  not Enum.any?(current, fn {_own, _identity, name, _value} = setting ->
                    owned_setting?(setting, scope) and name == key
                  end),
                  :observer_configuration_conflict
                )
              end)

            :reset ->
              Enum.each(defaults, fn {key, value} ->
                ensure!(has_setting?(current, scope, key, value), :observer_cleanup_failed)
              end)
          end

          Enum.each(defaults, fn {key, value} ->
            statement =
              case mode do
                :install -> "SET #{key} TO '#{value}'"
                :reset -> "RESET #{key}"
              end

            subject =
              case scope do
                :web -> ~s(ROLE singularity_web IN DATABASE "#{target.database}")
                :database -> ~s(DATABASE "#{target.database}")
              end

            private_query!(tx, "ALTER #{subject} #{statement}", [])
          end)

          after_settings = settings(tx, target)

          Enum.each(defaults, fn {key, value} ->
            ensure!(
              if(mode == :install,
                do: has_setting?(after_settings, scope, key, value),
                else:
                  not Enum.any?(after_settings, fn {_own, _identity, name, _value} = setting ->
                    owned_setting?(setting, scope) and name == key
                  end)
              ),
              :observer_cleanup_failed
            )
          end)

          if mode == :reset do
            ensure!(after_settings == baseline, :observer_cleanup_failed)
            :ok
          else
            current
          end
        end,
        log: nil
      )

    result
  end

  defp private_query!(connection, sql, params) do
    case Postgrex.query(connection, sql, params, log: nil) do
      {:ok, result} -> result
      _ -> throw(:observer_admin_failed)
    end
  end

  defp web_query!(repo, sql, params \\ []) do
    case SafeSQL.query(repo, sql, params) do
      {:ok, result} -> result
      _ -> throw(:observer_setup_failed)
    end
  end

  defp connection_settings!(repo, target) do
    [[session, current, database, backend, address]] =
      web_query!(repo, """
      SELECT session_user, current_user, current_database(), pg_backend_pid(), inet_server_addr()::text
      """).rows

    ensure!(
      session == "singularity_web" and current == session and database == target.database and
        is_integer(backend) and backend > 0 and address == nil
    )

    keys =
      (@keys -- ["session_preload_libraries"]) ++
        ["local_preload_libraries", "row_security", "enable_seqscan"]

    values =
      web_query!(repo, "SELECT key, current_setting(key, true) FROM unnest($1::text[]) AS key", [
        keys
      ]).rows

    {backend, Map.new(values, fn [key, value] -> {key, value} end)}
  end

  defp ordinary_connection!(repo, target) do
    {_backend, values} = connection_settings!(repo, target)

    ensure!(
      values["local_preload_libraries"] == "" and
        values["auto_explain.log_min_duration"] in [nil, "", "-1"] and
        values["auto_explain.log_nested_statements"] in [nil, "", "off"] and
        values["log_min_messages"] == "warning" and values["client_min_messages"] == "notice" and
        values["row_security"] == "on" and values["enable_seqscan"] == "on"
    )

    ensure!(
      web_query!(
        repo,
        "SELECT count(*) FROM pg_catalog.pg_settings WHERE name LIKE 'auto_explain.%'"
      ).rows ==
        [[0]]
    )

    probe = web_query!(repo, "SELECT 1")

    ensure!(
      probe.rows == [[1]] and
        Enum.all?(probe.messages, fn message ->
          not String.contains?(Map.get(message, :message, ""), "plan:\n")
        end)
    )

    :ok
  end

  defp observer_connection!(repo, target) do
    {backend, values} = connection_settings!(repo, target)

    Enum.each(Enum.reject(@defaults, &(elem(&1, 0) == "session_preload_libraries")), fn {key,
                                                                                         value} ->
      ensure!(
        values[key] == value or (key == "auto_explain.log_min_duration" and values[key] == "0ms")
      )
    end)

    ensure!(
      values["local_preload_libraries"] == "" and values["row_security"] == "on" and
        values["enable_seqscan"] == "on"
    )

    backend
  end

  defp start_observer_repo! do
    options =
      Keyword.merge(RequestRepo.config(),
        name: Repo,
        pool_size: 1,
        telemetry_prefix: Repo.config()[:telemetry_prefix]
      )

    {:ok, owned} = Repo.start_link(options)
    Process.unlink(owned)
    owned
  end

  defp with_fresh_repo(callback) do
    protect(:observer_setup_failed, fn ->
      {:ok, owned} = RequestRepo.start_link(name: nil, pool_size: 1)
      Process.unlink(owned)
      using_owned_repo(owned, fn -> callback.(owned) end)
    end)
  end

  defp using_owned_repo(owned, callback) do
    try do
      callback.()
    after
      stop_owned!(owned)
    end
  end

  defp stop_owned!(owned) do
    protect_cleanup!(fn ->
      reference = Process.monitor(owned)
      if Process.alive?(owned), do: GenServer.stop(owned, :normal, 5_000)

      receive do
        {:DOWN, ^reference, :process, ^owned, _reason} -> :ok
      after
        5_000 ->
          Process.demonitor(reference, [:flush])
          throw(:observer_cleanup_failed)
      end
    end)
  end

  defp cleanup_before_reset(connection, target, baseline) do
    protect_cleanup!(fn -> change_defaults!(connection, target, @defaults, :reset, baseline) end)
    {:error, :observer_setup_failed}
  end

  defp protect_cleanup!(callback) do
    case protect(:observer_cleanup_failed, callback) do
      :ok -> :ok
      _ -> throw(:observer_cleanup_failed)
    end
  end

  defp invoke_callback(callback, repo) do
    try do
      {:ok, callback.(repo)}
    rescue
      _ -> {:error, :observer_callback_failed}
    catch
      _, _ -> {:error, :observer_callback_failed}
    end
  end

  defp protect(error, callback) do
    callback.()
  rescue
    _ -> {:error, error}
  catch
    :throw, reason when reason in @errors -> {:error, reason}
    _, _ -> {:error, error}
  end

  defp ensure!(condition, error \\ :observer_setup_failed) do
    unless condition, do: throw(error)
    :ok
  end

  defp require_ok!(:ok), do: :ok
  defp require_ok!({:error, reason}) when reason in @errors, do: throw(reason)

  defp target(database) do
    config = RequestRepo.config()
    socket = System.get_env("PGHOST")
    port = System.get_env("PGPORT")
    root = Application.get_env(:singularity_storage, :storage_root)

    data =
      System.get_env("SINGULARITY_TEST_OBSERVER_PGDATA") || System.get_env("PGDATA")

    checkout_state = Path.expand("../../../../.devenv/", __DIR__) <> "/"

    valid_name =
      is_binary(database) and Regex.match?(~r/\Asingularity_test_[0-9a-f]{24}\z/, database)

    suffix = if valid_name, do: String.replace_prefix(database, "singularity_test_", ""), else: ""
    expected_root = Path.join([System.tmp_dir!(), "singularity", "integration", suffix])

    if Mix.env() == :test and startup_safe?(config) and valid_name and
         database == config[:database] and
         config[:username] == "singularity_web" and is_binary(socket) and
         String.starts_with?(socket, "/") and config[:socket_dir] == socket and
         is_binary(port) and Integer.to_string(config[:port] || 0) == port and
         root == expected_root and File.dir?(root) and is_binary(data) and
         Path.expand(data) == data and String.starts_with?(data, checkout_state) and
         File.read(Path.join(data, "PG_VERSION")) == {:ok, "17\n"} do
      {:ok, %{database: database, socket: socket, port: config[:port], data: data}}
    else
      {:error, :observer_invalid_target}
    end
  rescue
    _ -> {:error, :observer_invalid_target}
  end
end
