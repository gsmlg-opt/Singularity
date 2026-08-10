defmodule Mix.Tasks.Singularity.Test.Browser do
  use Mix.Task

  alias Singularity.Runtime.BootstrapOwner
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.SafeSQL
  alias Singularity.Storage.TestEnvironment

  @password_domain "singularity-browser-test-owner-password:v1:"
  @password_prefix "singularity-test-"
  @playwright_run_id_pattern ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  @project_root Path.expand("../../../../..", __DIR__)
  @endpoint :"Elixir.Singularity.Web.Endpoint"
  @signal_cleanup_timeout_ms 12_000
  @cleanup_attempt_timeout_ms 11_000
  @application_stop_timeout_ms 1_000
  @repository_stop_timeout_ms 1_750
  @force_drop_timeout_ms 5_000
  @runtime_applications [:singularity_web, :singularity_runtime]
  @repositories [
    Singularity.Storage.MigrationRepo,
    Singularity.Storage.RequestRepo,
    Singularity.Storage.PreAuthRepo,
    Singularity.Storage.DispatcherRepo,
    Singularity.Storage.WorkerRepo
  ]
  @environment_keys [
    {:singularity_runtime, :start_infrastructure},
    {:singularity_runtime, :maintenance_mode},
    {:singularity_runtime, :authorization_dependencies},
    {:singularity_runtime, :key_custodian},
    {:singularity_runtime, :oban_options},
    {:singularity_runtime, :outbox_dispatcher_options},
    {:singularity_storage, :backup_root},
    {:singularity_storage, :storage_root},
    {:singularity_storage, Singularity.Storage.MigrationRepo},
    {:singularity_storage, Singularity.Storage.RequestRepo},
    {:singularity_storage, Singularity.Storage.PreAuthRepo},
    {:singularity_storage, Singularity.Storage.DispatcherRepo},
    {:singularity_storage, Singularity.Storage.WorkerRepo},
    {:singularity_web, :asset_page_limit},
    {:singularity_web, @endpoint}
  ]

  @impl Mix.Task
  def run(["serve"]) do
    if Mix.env() != :test do
      Mix.raise("singularity.test.browser requires MIX_ENV=test")
    end

    run_id =
      case System.fetch_env("SINGULARITY_TEST_RUN_ID") do
        {:ok, run_id} -> run_id
        :error -> Mix.raise("SINGULARITY_TEST_RUN_ID is required")
      end

    compile_browser_endpoint!()
    __run_lifecycle__(run_id, default_lifecycle())
  end

  def run(_args), do: Mix.raise("usage: mix singularity.test.browser serve")

  @doc false
  def __run_lifecycle__(run_id, lifecycle) do
    environment = lifecycle.environment.(run_id)
    snapshot = lifecycle.snapshot.()

    {:ok, cleanup_state} =
      Agent.start(fn ->
        {:pending, %{environment: environment, run_id: run_id, snapshot: snapshot}}
      end)

    cleanup = fn -> cleanup_once(cleanup_state, lifecycle.cleanup) end
    registration = lifecycle.register_cleanup.(self(), cleanup)

    try do
      %{environment: environment, run_id: run_id, snapshot: snapshot}
      |> lifecycle_step(cleanup_state, lifecycle.provision)
      |> lifecycle_step(cleanup_state, lifecycle.configure)
      |> lifecycle_step(cleanup_state, lifecycle.bootstrap)
      |> lifecycle_step(cleanup_state, lifecycle.stop_provisioning_repos)
      |> lifecycle_step(cleanup_state, lifecycle.start)
      |> then(&lifecycle.wait.(&1, cleanup))

      :ok
    after
      try do
        cleanup.()
      after
        try do
          lifecycle.unregister_cleanup.(registration)
        after
          unless keep_cleanup_state?(registration) do
            if Process.alive?(cleanup_state), do: Agent.stop(cleanup_state)
          end
        end
      end
    end
  end

  defp default_lifecycle do
    %{
      environment: &TestEnvironment.from_playwright_run_id!/1,
      snapshot: &__snapshot_environment__/0,
      register_cleanup: &register_cleanup/2,
      unregister_cleanup: &unregister_cleanup/1,
      provision: &provision/1,
      configure: &__configure_environment__/1,
      bootstrap: &bootstrap_owner/1,
      stop_provisioning_repos: &stop_provisioning_repositories/1,
      start: &start_browser_applications/1,
      wait: &wait_foreground/2,
      cleanup: &cleanup/1
    }
  end

  defp compile_browser_endpoint! do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Quiet)

    try do
      Mix.Project.in_project(
        :singularity_web,
        Path.join(@project_root, "apps/singularity_web"),
        fn _module ->
          Mix.Task.reenable("compile")
          Mix.Task.run("compile", ["--force"])
        end
      )
    after
      Mix.shell(previous_shell)
    end
  end

  @doc false
  def __snapshot_environment__ do
    Enum.map(@environment_keys, fn {application, key} ->
      {application, key, Application.fetch_env(application, key)}
    end)
  end

  @doc false
  def __restore_environment__(snapshot) when is_list(snapshot) do
    Enum.each(snapshot, fn
      {application, key, {:ok, value}} -> Application.put_env(application, key, value)
      {application, key, :error} -> Application.delete_env(application, key)
    end)

    :ok
  end

  @doc false
  def __validate_generated_environment__(environment) do
    storage_root_matches? =
      Application.get_env(:singularity_storage, :storage_root) == environment.storage_root

    repositories_match? =
      Enum.all?(@repositories, fn repository ->
        case Application.fetch_env(:singularity_storage, repository) do
          {:ok, config} -> Keyword.get(config, :database) == environment.database
          :error -> false
        end
      end)

    if storage_root_matches? and repositories_match? do
      :ok
    else
      Mix.raise("browser test environment repository configuration is invalid")
    end
  end

  @doc false
  def __configure_environment__(%{environment: %{storage_root: storage_root}} = context) do
    backup_root = Path.join(storage_root, "backups")
    File.mkdir_p!(backup_root)
    Application.put_env(:singularity_storage, :backup_root, backup_root)
    Application.put_env(:singularity_web, :asset_page_limit, 2)

    Application.put_env(:singularity_runtime, :authorization_dependencies, %{
      store: Singularity.Storage.Postgres.IdentityRepository,
      custodian: Singularity.Runtime.KeyCustodian
    })

    Application.put_env(:singularity_runtime, :key_custodian, %{
      authorization: Singularity.Runtime.CustodyReader,
      backup_cipher: Singularity.Storage.Crypto.ChunkedAEAD,
      backup_recovery_wrapper: Singularity.Storage.Crypto.BackupRecoveryWrapper,
      clock: Singularity.Runtime.CustodyReader,
      context: %{
        repo: Singularity.Storage.WorkerRepo,
        repository_adapter: Singularity.Storage.Postgres.CustodyRepository,
        key_wrapper: Singularity.Storage.Crypto.KeyWrapper,
        storage: Singularity.Runtime.StorageAdapter
      },
      idle_lock: Singularity.Runtime.LockVault,
      key_reader: Singularity.Runtime.CustodyReader,
      object_key_loader: Singularity.Runtime.CustodyReader,
      wake_waiting: Singularity.Runtime.JobDispatcher
    })

    Application.put_env(:singularity_runtime, :start_infrastructure, true)
    Application.put_env(:singularity_runtime, :maintenance_mode, false)
    Application.put_env(:singularity_runtime, :oban_options, [])
    Application.put_env(:singularity_runtime, :outbox_dispatcher_options, [])
    :ok = __validate_active_oban__()

    endpoint =
      :singularity_web
      |> Application.get_env(@endpoint, [])
      |> Keyword.put(:http, ip: {127, 0, 0, 1}, port: 4002)
      |> Keyword.put(:url, scheme: "http", host: "127.0.0.1", port: 4002)
      |> Keyword.put(:server, true)

    Application.put_env(:singularity_web, @endpoint, endpoint)
    context
  end

  @doc false
  def __validate_active_oban__ do
    storage_options = Application.fetch_env!(:singularity_storage, Oban)
    runtime_options = Application.fetch_env!(:singularity_runtime, :oban_options)
    queues = Keyword.get(storage_options, :queues)

    active_queues? =
      is_list(queues) and queues != [] and
        Enum.all?(queues, fn
          {_queue, limit} when is_integer(limit) and limit > 0 -> true
          _invalid -> false
        end)

    real_runtime? =
      not Keyword.has_key?(runtime_options, :testing) and
        Keyword.get(runtime_options, :queues, :configured) != false

    if active_queues? and real_runtime? do
      :ok
    else
      Mix.raise("browser Oban configuration must use active real queues")
    end
  end

  @doc false
  def __owner_attributes__(run_id) do
    %{
      capabilities:
        ~w[asset.read asset.write backup.create vault.lock vault.unlock vault.password_change],
      display_name: "Browser Test Owner",
      login: "owner@singularity.local",
      password: derive_owner_password(run_id)
    }
  end

  defp register_cleanup(owner, cleanup) do
    handler_id = {__MODULE__.SignalHandler, make_ref()}

    case :gen_event.add_handler(
           :erl_signal_server,
           handler_id,
           %{owner: owner, timeout_ms: @signal_cleanup_timeout_ms}
         ) do
      :ok -> :ok
      {:error, _reason} -> Mix.raise("could not install browser SIGTERM cleanup handler")
    end

    System.at_exit(fn _exit_status -> cleanup.() end)
    %{handler_id: handler_id, keep_cleanup_state?: true}
  end

  defp unregister_cleanup(%{handler_id: handler_id}) do
    :gen_event.delete_handler(:erl_signal_server, handler_id, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp keep_cleanup_state?(%{keep_cleanup_state?: true}), do: true
  defp keep_cleanup_state?(_registration), do: false

  defp provision(context) do
    :ok = TestEnvironment.create!(context.environment)
    :ok = __validate_generated_environment__(context.environment)
    context
  end

  defp bootstrap_owner(context) do
    adapters = Application.fetch_env!(:singularity_runtime, :bootstrap_owner)
    attrs = __owner_attributes__(context.run_id)
    {capabilities, attrs} = Map.pop!(attrs, :capabilities)
    adapters = Map.put(adapters, :initial_capabilities, capabilities)

    {:ok, repo} = MigrationRepo.start_link(pool_size: 2)

    result =
      try do
        MigrationRepo.transaction(fn ->
          SafeSQL.query!(
            MigrationRepo,
            "SET LOCAL ROLE singularity_table_owner",
            [],
            log: false
          )

          case BootstrapOwner.run(adapters, attrs) do
            {:ok, owner} -> owner
            {:error, error} -> MigrationRepo.rollback(error)
          end
        end)
      after
        if Process.alive?(repo), do: Supervisor.stop(repo)
      end

    case result do
      {:ok, _owner} -> context
      {:error, _error} -> Mix.raise("browser owner bootstrap failed")
    end
  end

  defp stop_provisioning_repositories(context) do
    stop_known_repositories()
    context
  end

  defp start_browser_applications(context) do
    {:ok, started} = Application.ensure_all_started(:singularity_web)
    started = Enum.filter(@runtime_applications, &(&1 in started))
    Map.put(context, :started_applications, started)
  end

  defp wait_foreground(_context, cleanup) do
    receive do
      {:singularity_browser_sigterm, handler, reference} ->
        __cleanup_and_acknowledge__(handler, reference, cleanup)
    end

    :ok
  end

  @doc false
  def __cleanup_and_acknowledge__(handler, reference, cleanup) do
    result = cleanup.()
    send(handler, {:singularity_browser_cleanup_complete, reference})
    result
  end

  defp cleanup(context) do
    context
    |> Map.get(:started_applications, [])
    |> Enum.each(fn application ->
      safely(fn ->
        __run_bounded__(
          fn -> Application.stop(application) end,
          @application_stop_timeout_ms,
          "browser application stop exceeded its bounded timeout"
        )
      end)
    end)

    stop_known_repositories()

    try do
      __run_bounded__(
        fn -> TestEnvironment.force_drop!(context.environment) end,
        @force_drop_timeout_ms,
        "browser destructive cleanup exceeded its bounded timeout"
      )
    after
      __restore_environment__(context.snapshot)
    end
  end

  defp stop_known_repositories do
    workers =
      Enum.flat_map(@repositories, fn repository ->
        case Process.whereis(repository) do
          nil -> []
          repository_pid -> [start_repository_stop(repository_pid)]
        end
      end)

    await_repository_stops(workers, @repository_stop_timeout_ms)
  end

  defp start_repository_stop(repository_pid) do
    {worker, monitor} = spawn_monitor(fn -> stop_repository(repository_pid) end)
    {worker, monitor, repository_pid}
  end

  defp await_repository_stops(workers, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Enum.each(workers, fn {worker, monitor, repository_pid} ->
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
      after
        remaining ->
          Process.exit(worker, :kill)
          if Process.alive?(repository_pid), do: Process.exit(repository_pid, :kill)
          Process.demonitor(monitor, [:flush])
      end
    end)
  end

  defp stop_repository(pid) do
    monitor = Process.monitor(pid)

    try do
      Supervisor.stop(pid, :normal, 1_000)
    catch
      :exit, _reason ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        after
          500 -> :ok
        end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp safely(callback) do
    callback.()
  rescue
    _error -> :error
  catch
    :exit, _reason -> :error
  end

  @doc false
  def __run_bounded__(callback, timeout_ms, timeout_message)
      when is_function(callback, 0) and is_integer(timeout_ms) and timeout_ms > 0 and
             is_binary(timeout_message) do
    caller = self()
    reference = make_ref()

    {worker, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            {:ok, callback.()}
          catch
            kind, reason -> {:error, kind, reason, __STACKTRACE__}
          end

        send(caller, {:singularity_browser_bounded_result, reference, result})
      end)

    receive do
      {:singularity_browser_bounded_result, ^reference, {:ok, result}} ->
        Process.demonitor(monitor, [:flush])
        result

      {:singularity_browser_bounded_result, ^reference, {:error, kind, reason, stacktrace}} ->
        Process.demonitor(monitor, [:flush])
        :erlang.raise(kind, reason, stacktrace)

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        exit(reason)
    after
      timeout_ms ->
        Process.exit(worker, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
        after
          100 -> Process.demonitor(monitor, [:flush])
        end

        Mix.raise(timeout_message)
    end
  end

  defp lifecycle_step(context, cleanup_state, callback) do
    context = callback.(context)

    Agent.update(cleanup_state, fn
      {:pending, _previous} ->
        {:pending, context}

      {:starting, starter, reference, _previous} ->
        {:starting, starter, reference, context}

      {:cleaning, worker, _previous, waiters} ->
        {:cleaning, worker, context, waiters}

      {:done, _previous} ->
        {:done, context}
    end)

    context
  end

  defp cleanup_once(cleanup_state, callback) do
    unless Process.alive?(cleanup_state) do
      Mix.raise("browser cleanup coordinator is unavailable")
    end

    caller = self()
    reference = make_ref()

    case claim_cleanup(cleanup_state, caller, reference) do
      :done ->
        :ok

      {:start, context} ->
        start_cleanup_attempt(cleanup_state, callback, context, caller, reference)

      {:wait_for_start, starter} ->
        await_cleanup_start(cleanup_state, callback, starter)

      {:wait, worker, role} ->
        await_cleanup(cleanup_state, callback, worker, reference, role)
    end
  end

  defp claim_cleanup(cleanup_state, caller, reference) do
    Agent.get_and_update(cleanup_state, fn
      {:pending, context} ->
        {{:start, context}, {:starting, caller, reference, context}}

      {:starting, starter, _starter_reference, context} = state ->
        if Process.alive?(starter) do
          {{:wait_for_start, starter}, state}
        else
          {{:start, context}, {:starting, caller, reference, context}}
        end

      {:cleaning, worker, context, waiters} ->
        if Process.alive?(worker) do
          {{:wait, worker, :joiner},
           {:cleaning, worker, context, [{caller, reference} | waiters]}}
        else
          {{:start, context}, {:starting, caller, reference, context}}
        end

      {:done, context} ->
        {:done, {:done, context}}
    end)
  end

  defp start_cleanup_attempt(cleanup_state, callback, context, caller, reference) do
    worker =
      spawn(fn ->
        receive do
          :run_cleanup -> run_cleanup_attempt(cleanup_state, callback, context)
        end
      end)

    installed? =
      Agent.get_and_update(cleanup_state, fn
        {:starting, ^caller, ^reference, current} ->
          {true, {:cleaning, worker, current, [{caller, reference}]}}

        state ->
          {false, state}
      end)

    if installed? do
      send(worker, :run_cleanup)
      await_cleanup(cleanup_state, callback, worker, reference, :owner)
    else
      Process.exit(worker, :kill)
      cleanup_once(cleanup_state, callback)
    end
  end

  defp await_cleanup_start(cleanup_state, callback, starter) do
    monitor = Process.monitor(starter)

    receive do
      {:DOWN, ^monitor, :process, ^starter, _reason} ->
        cleanup_once(cleanup_state, callback)
    after
      10 ->
        Process.demonitor(monitor, [:flush])
        cleanup_once(cleanup_state, callback)
    end
  end

  defp run_cleanup_attempt(cleanup_state, callback, context) do
    result =
      try do
        {:ok, callback.(context)}
      catch
        kind, reason -> {:error, kind, reason, __STACKTRACE__}
      end

    worker = self()

    waiters =
      Agent.get_and_update(cleanup_state, fn
        {:cleaning, ^worker, current, waiters} ->
          next_state =
            if match?({:ok, _result}, result), do: {:done, current}, else: {:pending, current}

          {waiters, next_state}

        state ->
          {[], state}
      end)

    Enum.each(waiters, fn {caller, reference} ->
      send(caller, {:singularity_browser_cleanup_result, reference, result})
    end)
  end

  defp await_cleanup(cleanup_state, callback, worker, reference, role) do
    monitor = Process.monitor(worker)

    receive do
      {:singularity_browser_cleanup_result, ^reference, {:ok, result}} ->
        Process.demonitor(monitor, [:flush])
        result

      {:singularity_browser_cleanup_result, ^reference, {:error, kind, reason, stacktrace}} ->
        Process.demonitor(monitor, [:flush])
        handle_cleanup_failure(cleanup_state, callback, role, kind, reason, stacktrace)

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        reclaim_cleanup_worker(cleanup_state, worker)
        cleanup_once(cleanup_state, callback)
    after
      @cleanup_attempt_timeout_ms ->
        Process.exit(worker, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
        after
          100 -> Process.demonitor(monitor, [:flush])
        end

        reclaim_cleanup_worker(cleanup_state, worker)

        case role do
          :owner -> Mix.raise("browser cleanup attempt exceeded its bounded timeout")
          :joiner -> cleanup_once(cleanup_state, callback)
        end
    end
  end

  defp handle_cleanup_failure(_cleanup_state, _callback, :owner, kind, reason, stacktrace) do
    :erlang.raise(kind, reason, stacktrace)
  end

  defp handle_cleanup_failure(cleanup_state, callback, :joiner, _kind, _reason, _stacktrace) do
    cleanup_once(cleanup_state, callback)
  end

  defp reclaim_cleanup_worker(cleanup_state, worker) do
    Agent.update(cleanup_state, fn
      {:cleaning, ^worker, context, _waiters} -> {:pending, context}
      state -> state
    end)
  end

  @doc """
  Derives the test-only browser owner password from a canonical Playwright run ID.

  The derivation is SHA-256 over a fixed domain-separated prefix and the run ID,
  encoded as unpadded Base64URL with a fixed, non-secret prefix. Browser tests
  independently implement this derivation; the password is never transported.
  """
  @spec derive_owner_password(String.t()) :: String.t()
  def derive_owner_password(run_id) when is_binary(run_id) do
    unless Regex.match?(@playwright_run_id_pattern, run_id) do
      raise ArgumentError, "Playwright run ID must be a canonical crypto.randomUUID value"
    end

    digest = :crypto.hash(:sha256, @password_domain <> run_id)
    @password_prefix <> Base.url_encode64(digest, padding: false)
  end

  def derive_owner_password(_run_id) do
    raise ArgumentError, "Playwright run ID must be a canonical crypto.randomUUID value"
  end
end

defmodule Mix.Tasks.Singularity.Test.Browser.SignalHandler do
  @moduledoc false

  @behaviour :gen_event

  @impl :gen_event
  def init(state), do: {:ok, state}

  @impl :gen_event
  def handle_event(:sigterm, %{owner: owner, timeout_ms: timeout_ms} = state) do
    reference = make_ref()
    send(owner, {:singularity_browser_sigterm, self(), reference})

    receive do
      {:singularity_browser_cleanup_complete, ^reference} -> :ok
    after
      timeout_ms -> :ok
    end

    {:ok, state}
  end

  def handle_event(_event, state), do: {:ok, state}

  @impl :gen_event
  def handle_call(_request, state), do: {:ok, :unsupported, state}

  @impl :gen_event
  def handle_info(_message, state), do: {:ok, state}

  @impl :gen_event
  def terminate(_reason, _state), do: :ok

  @impl :gen_event
  def code_change(_old_version, state, _extra), do: {:ok, state}

  @impl :gen_event
  def format_status(_reason, [_process_dictionary, %{timeout_ms: timeout_ms}]) do
    [data: [{~c"State", %{status: :waiting_for_cleanup, timeout_ms: timeout_ms}}]]
  end

  @impl :gen_event
  def format_status(_status), do: %{status: :waiting_for_cleanup}
end
