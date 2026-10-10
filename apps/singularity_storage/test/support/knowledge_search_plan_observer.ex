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
