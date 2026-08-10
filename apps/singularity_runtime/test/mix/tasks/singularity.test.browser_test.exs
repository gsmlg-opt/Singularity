defmodule Mix.Tasks.Singularity.Test.BrowserTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Singularity.Test.Browser
  alias Mix.Tasks.Singularity.Test.Browser.SignalHandler

  @run_id "123e4567-e89b-42d3-a456-426614174000"
  @repositories [
    Singularity.Storage.MigrationRepo,
    Singularity.Storage.RequestRepo,
    Singularity.Storage.PreAuthRepo,
    Singularity.Storage.DispatcherRepo,
    Singularity.Storage.WorkerRepo
  ]

  test "derives the browser owner password from a stable domain-separated vector" do
    assert Browser.derive_owner_password(@run_id) ==
             "singularity-test-SbzAvdwHUTRt8F8Z2hEBuYS5RPQfDg9vhPB2A2gDVHk"

    assert Browser.derive_owner_password(@run_id) == Browser.derive_owner_password(@run_id)
  end

  test "password derivation rejects non-canonical IDs and emits or stores no password" do
    assert_raise ArgumentError,
                 "Playwright run ID must be a canonical crypto.randomUUID value",
                 fn ->
                   Browser.derive_owner_password("not-canonical")
                 end

    password = Browser.derive_owner_password(@run_id)
    assert capture_io(fn -> assert Browser.derive_owner_password(@run_id) == password end) == ""

    refute Enum.any?([:singularity_runtime, :singularity_storage, :singularity_web], fn app ->
             inspect(Application.get_all_env(app)) =~ password
           end)

    refute Enum.any?(System.get_env(), fn {key, value} -> key == password or value == password end)

    refute inspect(:init.get_plain_arguments()) =~ password
  end

  test "builds the fixed browser owner credential without transporting the password" do
    output =
      capture_io(fn -> send(self(), {:owner_attrs, Browser.__owner_attributes__(@run_id)}) end)

    assert output == ""

    assert_receive {:owner_attrs,
                    %{
                      display_name: "Browser Test Owner",
                      login: "owner@singularity.local",
                      password: password
                    }}

    assert password == Browser.derive_owner_password(@run_id)
    refute inspect(Application.get_all_env(:singularity_runtime)) =~ password
    refute Enum.any?(System.get_env(), fn {_key, value} -> value == password end)
  end

  test "accepts only serve and refuses every non-test Mix environment" do
    for args <- [[], ["start"], ["serve", "extra"]] do
      assert_raise Mix.Error, "usage: mix singularity.test.browser serve", fn ->
        Browser.run(args)
      end
    end

    previous_env = Mix.env()

    try do
      Mix.env(:dev)

      assert_raise Mix.Error, "singularity.test.browser requires MIX_ENV=test", fn ->
        Browser.run(["serve"])
      end
    after
      Mix.env(previous_env)
    end
  end

  test "runs provision through foreground wait before one cleanup" do
    recorder = start_supervised!({Agent, fn -> [] end})
    lifecycle = recording_lifecycle(recorder)

    assert :ok = Browser.__run_lifecycle__(@run_id, lifecycle)

    assert Agent.get(recorder, &Enum.reverse/1) == [
             :environment,
             :snapshot,
             :register_cleanup,
             :provision,
             :configure,
             :bootstrap,
             :stop_provisioning_repos,
             :start,
             :wait,
             :cleanup,
             :unregister_cleanup
           ]
  end

  test "cleans a partial provisioning failure after cleanup registration" do
    recorder = start_supervised!({Agent, fn -> [] end})

    lifecycle =
      recorder
      |> recording_lifecycle()
      |> Map.put(:provision, fn _context ->
        Agent.update(recorder, &[:provision | &1])
        raise "partial provisioning"
      end)

    assert_raise RuntimeError, "partial provisioning", fn ->
      Browser.__run_lifecycle__(@run_id, lifecycle)
    end

    assert Agent.get(recorder, &Enum.reverse/1) == [
             :environment,
             :snapshot,
             :register_cleanup,
             :provision,
             :cleanup,
             :unregister_cleanup
           ]
  end

  test "cleanup is idempotent across foreground and normal after paths" do
    recorder = start_supervised!({Agent, fn -> [] end})

    lifecycle =
      recorder
      |> recording_lifecycle()
      |> Map.put(:wait, fn _context, cleanup ->
        Agent.update(recorder, &[:wait | &1])
        assert :ok = cleanup.()
        assert :ok = cleanup.()
      end)

    assert :ok = Browser.__run_lifecycle__(@run_id, lifecycle)

    events = Agent.get(recorder, &Enum.reverse/1)
    assert Enum.count(events, &(&1 == :cleanup)) == 1
  end

  test "failed cleanup remains retryable for the lifecycle after path" do
    recorder = start_supervised!({Agent, fn -> [] end})
    attempts = start_supervised!({Agent, fn -> 0 end}, id: :cleanup_attempts)

    lifecycle =
      recorder
      |> recording_lifecycle()
      |> Map.put(:wait, fn _context, cleanup -> cleanup.() end)
      |> Map.put(:cleanup, fn _context ->
        attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})
        Agent.update(recorder, &[:cleanup | &1])

        if attempt == 1, do: raise("destructive cleanup failed")
        :ok
      end)

    assert_raise RuntimeError, "destructive cleanup failed", fn ->
      Browser.__run_lifecycle__(@run_id, lifecycle)
    end

    assert Agent.get(attempts, & &1) == 2
  end

  test "concurrent cleanup callers join the in-progress destructive attempt" do
    test_process = self()
    attempts = start_supervised!({Agent, fn -> 0 end})
    recorder = start_supervised!({Agent, fn -> [] end}, id: :cleanup_race_recorder)

    lifecycle =
      recorder
      |> recording_lifecycle()
      |> Map.put(:cleanup, fn _context ->
        Agent.update(attempts, &(&1 + 1))
        send(test_process, {:cleanup_started, self()})

        receive do
          :release_cleanup -> :ok
        end
      end)
      |> Map.put(:wait, fn _context, cleanup ->
        first = Task.async(cleanup)
        assert_receive {:cleanup_started, cleanup_worker}
        second = Task.async(cleanup)

        assert Task.yield(second, 20) == nil
        send(cleanup_worker, :release_cleanup)
        assert Task.await(first) == :ok
        assert Task.await(second) == :ok
      end)

    assert :ok = Browser.__run_lifecycle__(@run_id, lifecycle)
    assert Agent.get(attempts, & &1) == 1
  end

  test "cleanup failure propagates to its owner while a joiner retries" do
    test_process = self()
    attempts = start_supervised!({Agent, fn -> 0 end})
    recorder = start_supervised!({Agent, fn -> [] end}, id: :cleanup_failure_recorder)

    lifecycle =
      recorder
      |> recording_lifecycle()
      |> Map.put(:cleanup, fn _context ->
        attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})
        send(test_process, {:cleanup_attempt_started, attempt, self()})

        if attempt == 1 do
          receive do
            :fail_cleanup -> raise "force drop failed"
          end
        else
          :ok
        end
      end)
      |> Map.put(:wait, fn _context, cleanup ->
        spawn_cleanup_call(test_process, :owner, cleanup)
        assert_receive {:cleanup_attempt_started, 1, first_worker}
        joiner = spawn_cleanup_call(test_process, :joiner, cleanup)
        refute_receive {:cleanup_call_result, :joiner, _result}, 20
        send(first_worker, :fail_cleanup)

        assert_receive {:cleanup_call_result, :owner,
                        {:error, :error, %RuntimeError{message: "force drop failed"}}}

        assert_receive {:cleanup_attempt_started, 2, _retry_worker}
        assert_receive {:cleanup_call_result, :joiner, {:ok, :ok}}
        assert_receive {:DOWN, _monitor, :process, ^joiner, :normal}
      end)

    assert :ok = Browser.__run_lifecycle__(@run_id, lifecycle)
    assert Agent.get(attempts, & &1) == 2
    assert_cleanup_mailbox_empty()
  end

  test "a dead cleanup worker is reclaimed and retried by its caller" do
    test_process = self()
    attempts = start_supervised!({Agent, fn -> 0 end})
    recorder = start_supervised!({Agent, fn -> [] end}, id: :cleanup_death_recorder)

    lifecycle =
      recorder
      |> recording_lifecycle()
      |> Map.put(:cleanup, fn _context ->
        attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})
        send(test_process, {:cleanup_attempt_started, attempt, self()})

        if attempt == 1 do
          receive do: (:never -> :ok)
        else
          :ok
        end
      end)
      |> Map.put(:wait, fn _context, cleanup ->
        caller = spawn_cleanup_call(test_process, :reclaimer, cleanup)
        assert_receive {:cleanup_attempt_started, 1, dead_worker}
        Process.exit(dead_worker, :kill)
        assert_receive {:cleanup_attempt_started, 2, _replacement_worker}
        assert_receive {:cleanup_call_result, :reclaimer, {:ok, :ok}}
        assert_receive {:DOWN, _monitor, :process, ^caller, :normal}
      end)

    assert :ok = Browser.__run_lifecycle__(@run_id, lifecycle)
    assert Agent.get(attempts, & &1) == 2
    assert_cleanup_mailbox_empty()
  end

  test "restores every snapped application environment key exactly" do
    original = Browser.__snapshot_environment__()
    on_exit(fn -> Browser.__restore_environment__(original) end)

    Application.put_env(:singularity_runtime, :maintenance_mode, :sentinel)
    Application.delete_env(:singularity_runtime, :outbox_dispatcher_options)
    snapshot = Browser.__snapshot_environment__()

    Application.put_env(:singularity_runtime, :maintenance_mode, false)
    Application.put_env(:singularity_runtime, :outbox_dispatcher_options, interval_ms: 1)

    assert :ok = Browser.__restore_environment__(snapshot)
    assert Application.fetch_env(:singularity_runtime, :maintenance_mode) == {:ok, :sentinel}
    assert Application.fetch_env(:singularity_runtime, :outbox_dispatcher_options) == :error
  end

  test "SIGTERM handler waits for cleanup acknowledgement and times out boundedly" do
    owner = self()
    state = %{owner: owner, timeout_ms: 100}
    handler = Task.async(fn -> SignalHandler.handle_event(:sigterm, state) end)

    assert_receive {:singularity_browser_sigterm, handler_pid, reference}
    assert Task.yield(handler, 0) == nil
    send(handler_pid, {:singularity_browser_cleanup_complete, reference})
    assert Task.await(handler) == {:ok, state}

    timeout_state = %{owner: self(), timeout_ms: 1}
    timeout_handler = Task.async(fn -> SignalHandler.handle_event(:sigterm, timeout_state) end)
    assert_receive {:singularity_browser_sigterm, timeout_handler_pid, _reference}
    assert timeout_handler_pid == timeout_handler.pid
    assert Task.await(timeout_handler, 1_000) == {:ok, timeout_state}

    refute inspect(SignalHandler.format_status(:normal, [[], state])) =~
             "CANARY_BROWSER_PASSWORD"
  end

  test "SIGTERM acknowledgement is emitted only after successful cleanup" do
    reference = make_ref()

    assert_raise RuntimeError, "drop failed", fn ->
      Browser.__cleanup_and_acknowledge__(self(), reference, fn -> raise("drop failed") end)
    end

    refute_receive {:singularity_browser_cleanup_complete, ^reference}

    assert :ok = Browser.__cleanup_and_acknowledge__(self(), reference, fn -> :ok end)
    assert_receive {:singularity_browser_cleanup_complete, ^reference}
  end

  test "destructive cleanup operations terminate at their explicit bound" do
    test_process = self()

    assert_raise Mix.Error, "browser destructive cleanup exceeded its bounded timeout", fn ->
      Browser.__run_bounded__(
        fn ->
          send(test_process, {:bounded_worker, self()})
          receive do: (:never -> :ok)
        end,
        10,
        "browser destructive cleanup exceeded its bounded timeout"
      )
    end

    assert_receive {:bounded_worker, worker}
    refute Process.alive?(worker)
  end

  test "configures real infrastructure and the loopback browser endpoint before startup" do
    snapshot = Browser.__snapshot_environment__()
    on_exit(fn -> Browser.__restore_environment__(snapshot) end)

    context = %{environment: %{storage_root: "/tmp/singularity/browser/canonical"}}
    assert ^context = Browser.__configure_environment__(context)

    assert Application.fetch_env!(:singularity_storage, :backup_root) ==
             "/tmp/singularity/browser/canonical/backups"

    assert Application.fetch_env!(:singularity_runtime, :start_infrastructure)
    refute Application.fetch_env!(:singularity_runtime, :maintenance_mode)

    assert Application.fetch_env!(:singularity_runtime, :authorization_dependencies) == %{
             store: Singularity.Storage.Postgres.IdentityRepository,
             custodian: Singularity.Runtime.KeyCustodian
           }

    custodian = Application.fetch_env!(:singularity_runtime, :key_custodian)
    assert custodian.authorization == Singularity.Runtime.CustodyReader

    assert custodian.backup_recovery_wrapper ==
             Singularity.Storage.Crypto.BackupRecoveryWrapper

    assert Application.fetch_env!(:singularity_runtime, :oban_options) == []
    assert Application.fetch_env!(:singularity_runtime, :outbox_dispatcher_options) == []

    endpoint =
      Application.fetch_env!(:singularity_web, :"Elixir.Singularity.Web.Endpoint")

    assert endpoint[:server]
    assert endpoint[:http][:ip] == {127, 0, 0, 1}
    assert endpoint[:http][:port] == 4002
    assert endpoint[:url] == [scheme: "http", host: "127.0.0.1", port: 4002]
  end

  test "validates the exact generated database and storage root before runtime startup" do
    snapshot = Browser.__snapshot_environment__()
    on_exit(fn -> Browser.__restore_environment__(snapshot) end)
    environment = Singularity.Storage.TestEnvironment.from_playwright_run_id!(@run_id)

    Application.put_env(:singularity_storage, :storage_root, environment.storage_root)

    Enum.each(@repositories, fn repository ->
      Application.put_env(:singularity_storage, repository, database: environment.database)
    end)

    assert :ok = Browser.__validate_generated_environment__(environment)

    Application.put_env(:singularity_storage, Singularity.Storage.WorkerRepo,
      database: "not_the_generated_database"
    )

    assert_raise Mix.Error, "browser test environment repository configuration is invalid", fn ->
      Browser.__validate_generated_environment__(environment)
    end
  end

  test "validates active real Oban queues rather than test-manual or disabled options" do
    storage_oban = Application.fetch_env!(:singularity_storage, Oban)
    runtime_oban = Application.fetch_env(:singularity_runtime, :oban_options)

    on_exit(fn ->
      Application.put_env(:singularity_storage, Oban, storage_oban)

      case runtime_oban do
        {:ok, options} -> Application.put_env(:singularity_runtime, :oban_options, options)
        :error -> Application.delete_env(:singularity_runtime, :oban_options)
      end
    end)

    Application.put_env(:singularity_runtime, :oban_options, [])
    assert :ok = Browser.__validate_active_oban__()

    queues = Keyword.fetch!(storage_oban, :queues)
    assert is_list(queues) and queues != []
    assert Enum.all?(queues, fn {_queue, limit} -> is_integer(limit) and limit > 0 end)

    Application.put_env(:singularity_runtime, :oban_options,
      testing: :manual,
      queues: false
    )

    assert_raise Mix.Error, "browser Oban configuration must use active real queues", fn ->
      Browser.__validate_active_oban__()
    end
  end

  test "test config keeps the ordinary endpoint reloadable and browser compilation static" do
    previous_run_id = System.fetch_env("SINGULARITY_TEST_RUN_ID")

    try do
      System.delete_env("SINGULARITY_TEST_RUN_ID")
      ordinary = read_test_endpoint_config()

      System.put_env("SINGULARITY_TEST_RUN_ID", @run_id)
      browser = read_test_endpoint_config()

      assert ordinary[:code_reloader]
      refute ordinary[:server]
      refute browser[:code_reloader]
      refute browser[:server]
    after
      case previous_run_id do
        {:ok, run_id} -> System.put_env("SINGULARITY_TEST_RUN_ID", run_id)
        :error -> System.delete_env("SINGULARITY_TEST_RUN_ID")
      end
    end
  end

  defp recording_lifecycle(recorder) do
    record = fn event -> Agent.update(recorder, &[event | &1]) end

    %{
      environment: fn run_id ->
        record.(:environment)
        %{run_id: run_id, storage_root: "/tmp/browser-test"}
      end,
      snapshot: fn ->
        record.(:snapshot)
        []
      end,
      register_cleanup: fn _owner, _cleanup ->
        record.(:register_cleanup)
        :handler
      end,
      unregister_cleanup: fn :handler -> record.(:unregister_cleanup) end,
      provision: fn context ->
        record.(:provision)
        context
      end,
      configure: fn context ->
        record.(:configure)
        context
      end,
      bootstrap: fn context ->
        record.(:bootstrap)
        context
      end,
      stop_provisioning_repos: fn context ->
        record.(:stop_provisioning_repos)
        context
      end,
      start: fn context ->
        record.(:start)
        context
      end,
      wait: fn _context, _cleanup -> record.(:wait) end,
      cleanup: fn _context -> record.(:cleanup) end
    }
  end

  defp read_test_endpoint_config do
    config_path = Path.expand("../../../../../config/test.exs", __DIR__)

    config_path
    |> Config.Reader.read!(env: :test)
    |> Keyword.fetch!(:singularity_web)
    |> Keyword.fetch!(:"Elixir.Singularity.Web.Endpoint")
  end

  defp spawn_cleanup_call(test_process, label, cleanup) do
    {caller, _monitor} =
      spawn_monitor(fn ->
        result =
          try do
            {:ok, cleanup.()}
          catch
            kind, reason -> {:error, kind, reason}
          end

        send(test_process, {:cleanup_call_result, label, result})
      end)

    caller
  end

  defp assert_cleanup_mailbox_empty do
    {:messages, messages} = Process.info(self(), :messages)

    refute Enum.any?(messages, fn
             {:singularity_browser_cleanup_result, _reference, _result} -> true
             {:singularity_browser_bounded_result, _reference, _result} -> true
             _message -> false
           end)
  end
end
