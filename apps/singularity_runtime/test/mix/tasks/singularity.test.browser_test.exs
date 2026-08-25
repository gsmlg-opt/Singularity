defmodule Mix.Tasks.Singularity.Test.BrowserTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Singularity.Test.Browser
  alias Mix.Tasks.Singularity.Test.BrowserRestore
  alias Mix.Tasks.Singularity.Test.Browser.SignalHandler
  alias Singularity.Storage.TestEnvironment

  @run_id "123e4567-e89b-42d3-a456-426614174000"
  @repositories [
    Singularity.Storage.MigrationRepo,
    Singularity.Storage.RequestRepo,
    Singularity.Storage.PreAuthRepo,
    Singularity.Storage.DispatcherRepo,
    Singularity.Storage.WorkerRepo
  ]

  test "derives distinct browser owner passwords from stable role-separated vectors" do
    assert Browser.derive_owner_password(@run_id, :primary) ==
             "singularity-test-o6rHNPLKQwhPQnNLXwzWIhvwp6jPlSyS4hK0wYSpt30"

    assert Browser.derive_owner_password(@run_id, :secondary) ==
             "singularity-test-Un2wbw6zaOb4a_pToU3a8b6iCOBwU_Aj6VFgW7bOvhY"

    assert Browser.derive_owner_password(@run_id) ==
             Browser.derive_owner_password(@run_id, :primary)

    refute Browser.derive_owner_password(@run_id, :primary) ==
             Browser.derive_owner_password(@run_id, :secondary)
  end

  test "password derivation rejects non-canonical IDs and emits or stores no password" do
    assert_raise ArgumentError,
                 "Playwright run ID must be a canonical crypto.randomUUID value",
                 fn ->
                   Browser.derive_owner_password("not-canonical")
                 end

    password = Browser.derive_owner_password(@run_id, :primary)

    assert capture_io(fn ->
             assert Browser.derive_owner_password(@run_id, :primary) == password
           end) == ""

    refute Enum.any?([:singularity_runtime, :singularity_storage, :singularity_web], fn app ->
             inspect(Application.get_all_env(app)) =~ password
           end)

    refute Enum.any?(System.get_env(), fn {key, value} -> key == password or value == password end)

    refute inspect(:init.get_plain_arguments()) =~ password
  end

  test "builds two fixed note-capable browser owners without transporting passwords" do
    output =
      capture_io(fn ->
        send(self(), {
          :owner_attrs,
          Browser.__owner_attributes__(@run_id, :primary),
          Browser.__owner_attributes__(@run_id, :secondary)
        })
      end)

    assert output == ""

    assert_receive {
      :owner_attrs,
      %{
        capabilities: primary_capabilities,
        display_name: "Browser Test Owner",
        login: "owner@singularity.local",
        password: primary_password
      },
      %{
        capabilities: secondary_capabilities,
        display_name: "Secondary Browser Test Owner",
        login: "secondary-owner@singularity.local",
        password: secondary_password
      }
    }

    expected_capabilities =
      ~w[asset.read asset.write backup.create note.export note.read note.write vault.lock vault.unlock vault.password_change]

    assert primary_capabilities == expected_capabilities
    assert secondary_capabilities == expected_capabilities
    refute "integrity.audit" in primary_capabilities
    assert primary_password == Browser.derive_owner_password(@run_id, :primary)
    assert secondary_password == Browser.derive_owner_password(@run_id, :secondary)
    refute primary_password == secondary_password

    for password <- [primary_password, secondary_password] do
      refute inspect(Application.get_all_env(:singularity_runtime)) =~ password
      refute Enum.any?(System.get_env(), fn {_key, value} -> value == password end)
    end
  end

  test "browser capability override leaves production bootstrap defaults untouched" do
    production = Application.fetch_env!(:singularity_runtime, :bootstrap_owner)

    refute Map.has_key?(production, :initial_capabilities)
    refute inspect(production) =~ "integrity.audit"

    assert Browser.__owner_attributes__(@run_id, :primary).capabilities ==
             ~w[asset.read asset.write backup.create note.export note.read note.write vault.lock vault.unlock vault.password_change]
  end

  @tag :tmp_dir
  test "writes only public browser coordinates to an owned mode-0600 state file", %{
    tmp_dir: tmp_dir
  } do
    state_file_path = Path.join(tmp_dir, "browser-state.json")
    backup_root = Path.join(tmp_dir, "backups")

    primary = %{
      account_id: "10000000-0000-4000-8000-000000000001",
      principal_id: "10000000-0000-4000-8000-000000000002",
      vault_id: "10000000-0000-4000-8000-000000000003"
    }

    secondary = %{
      account_id: "20000000-0000-4000-8000-000000000001",
      principal_id: "20000000-0000-4000-8000-000000000002",
      vault_id: "20000000-0000-4000-8000-000000000003"
    }

    context = %{
      run_id: @run_id,
      state_file_path: state_file_path,
      backup_root: backup_root,
      owners: %{primary: primary, secondary: secondary}
    }

    assert %{state_file_owned?: true} = Browser.__write_state_file__(context)
    assert {:ok, stat} = File.stat(state_file_path)
    assert Bitwise.band(stat.mode, 0o777) == 0o600

    assert {:ok,
            %{
              "version" => 1,
              "run_id" => @run_id,
              "backup_root" => ^backup_root,
              "owners" => %{
                "primary" => %{
                  "login" => "owner@singularity.local",
                  "account_id" => "10000000-0000-4000-8000-000000000001",
                  "principal_id" => "10000000-0000-4000-8000-000000000002",
                  "vault_id" => "10000000-0000-4000-8000-000000000003"
                },
                "secondary" => %{
                  "login" => "secondary-owner@singularity.local",
                  "account_id" => "20000000-0000-4000-8000-000000000001",
                  "principal_id" => "20000000-0000-4000-8000-000000000002",
                  "vault_id" => "20000000-0000-4000-8000-000000000003"
                }
              }
            }} = JSON.decode(File.read!(state_file_path))

    state = File.read!(state_file_path)

    for forbidden <- [
          Browser.derive_owner_password(@run_id, :primary),
          Browser.derive_owner_password(@run_id, :secondary),
          "passphrase",
          "markdown",
          "CANARY_PRIVATE_MARKDOWN"
        ] do
      refute String.downcase(state) =~ String.downcase(forbidden)
    end
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

  test "snapshots and restores present and absent backup-root and page-limit settings exactly" do
    original_backup_root = Application.fetch_env(:singularity_storage, :backup_root)
    original_page_limit = Application.fetch_env(:singularity_web, :asset_page_limit)

    on_exit(fn ->
      restore_setting(:singularity_storage, :backup_root, original_backup_root)
      restore_setting(:singularity_web, :asset_page_limit, original_page_limit)
    end)

    for prior <- [:present, :absent] do
      expected =
        case prior do
          :present ->
            Application.put_env(:singularity_storage, :backup_root, "/prior/backups")
            Application.put_env(:singularity_web, :asset_page_limit, 37)
            {{:ok, "/prior/backups"}, {:ok, 37}}

          :absent ->
            Application.delete_env(:singularity_storage, :backup_root)
            Application.delete_env(:singularity_web, :asset_page_limit)
            {:error, :error}
        end

      snapshot = Browser.__snapshot_environment__()

      Application.put_env(:singularity_storage, :backup_root, "/generated/backups")
      Application.put_env(:singularity_web, :asset_page_limit, 2)

      assert :ok = Browser.__restore_environment__(snapshot)
      {expected_backup_root, expected_page_limit} = expected
      assert Application.fetch_env(:singularity_storage, :backup_root) == expected_backup_root
      assert Application.fetch_env(:singularity_web, :asset_page_limit) == expected_page_limit
    end
  end

  test "partial, normal, SIGTERM, and VM-at-exit cleanup restore both browser settings" do
    original_backup_root = Application.fetch_env(:singularity_storage, :backup_root)
    original_page_limit = Application.fetch_env(:singularity_web, :asset_page_limit)

    on_exit(fn ->
      restore_setting(:singularity_storage, :backup_root, original_backup_root)
      restore_setting(:singularity_web, :asset_page_limit, original_page_limit)
    end)

    for cleanup_path <- [:partial_setup, :normal, :sigterm, :vm_at_exit],
        prior <- [:present, :absent] do
      expected = set_prior_browser_settings(prior)

      cleanup_registration =
        start_supervised!({Agent, fn -> nil end},
          id: {:cleanup_registration, cleanup_path, prior}
        )

      lifecycle = restoring_lifecycle(cleanup_path, cleanup_registration)

      case cleanup_path do
        :partial_setup ->
          assert_raise RuntimeError, "partial setup", fn ->
            Browser.__run_lifecycle__(@run_id, lifecycle)
          end

        _other ->
          assert :ok = Browser.__run_lifecycle__(@run_id, lifecycle)
      end

      {expected_backup_root, expected_page_limit} = expected
      assert Application.fetch_env(:singularity_storage, :backup_root) == expected_backup_root
      assert Application.fetch_env(:singularity_web, :asset_page_limit) == expected_page_limit
    end
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

  test "coordinator removes the canonical generated root when force-drop times out" do
    environment = TestEnvironment.from_playwright_run_id!(@run_id)
    backup_root = Path.join(environment.storage_root, "backups")
    backup_canary = Path.join(backup_root, "cleanup-canary")

    File.rm_rf!(environment.storage_root)
    File.mkdir_p!(backup_root)
    File.write!(backup_canary, "generated browser backup")
    on_exit(fn -> File.rm_rf!(environment.storage_root) end)

    test_process = self()

    force_drop = fn actual_environment ->
      send(test_process, {:force_drop_started, actual_environment, self()})
      receive do: (:never -> :ok)
    end

    assert_raise Mix.Error, "browser destructive cleanup exceeded its bounded timeout", fn ->
      Browser.__cleanup_generated_environment__(
        %{run_id: @run_id, environment: environment},
        force_drop,
        10
      )
    end

    assert_receive {:force_drop_started, ^environment, worker}
    refute Process.alive?(worker)
    refute File.exists?(environment.storage_root)
    refute File.exists?(backup_canary)
  end

  test "generated-root cleanup rejects tampered context without removing caller paths" do
    environment = TestEnvironment.from_playwright_run_id!(@run_id)
    caller_root = environment.storage_root <> "-caller-controlled"
    caller_canary = Path.join(caller_root, "must-survive")

    File.rm_rf!(caller_root)
    File.mkdir_p!(caller_root)
    File.write!(caller_canary, "caller data")
    on_exit(fn -> File.rm_rf!(caller_root) end)

    tampered_environment = %{environment | storage_root: caller_root}
    test_process = self()

    assert_raise Mix.Error, "browser cleanup context does not match generated environment", fn ->
      Browser.__cleanup_generated_environment__(
        %{run_id: @run_id, environment: tampered_environment},
        fn _environment -> send(test_process, :tampered_force_drop_called) end,
        10
      )
    end

    refute_receive :tampered_force_drop_called
    assert File.read!(caller_canary) == "caller data"
  end

  test "generated cleanup removes the external browser state file on every path" do
    environment = TestEnvironment.from_playwright_run_id!(@run_id)
    state_file_path = Path.join(System.tmp_dir!(), "singularity-browser-state-#{@run_id}.json")

    File.rm_rf!(environment.storage_root)
    File.write!(state_file_path, ~s({"version":1}))

    on_exit(fn ->
      File.rm_rf!(environment.storage_root)
      File.rm(state_file_path)
    end)

    assert :ok =
             Browser.__cleanup_generated_environment__(
               %{
                 run_id: @run_id,
                 environment: environment,
                 state_file_path: state_file_path,
                 state_file_owned?: true
               },
               fn _environment -> :ok end,
               100
             )

    refute File.exists?(state_file_path)
  end

  @tag :tmp_dir
  test "state-file collision never modifies or removes the caller-owned file", %{tmp_dir: tmp_dir} do
    environment = TestEnvironment.from_playwright_run_id!(@run_id)
    state_file_path = Path.join(tmp_dir, "caller-state.json")
    canary = "CALLER_OWNED_STATE_CANARY"
    previous_state_file = System.fetch_env("SINGULARITY_BROWSER_STATE_FILE")
    System.put_env("SINGULARITY_BROWSER_STATE_FILE", state_file_path)

    on_exit(fn ->
      case previous_state_file do
        {:ok, path} -> System.put_env("SINGULARITY_BROWSER_STATE_FILE", path)
        :error -> System.delete_env("SINGULARITY_BROWSER_STATE_FILE")
      end
    end)

    File.write!(state_file_path, canary)
    File.chmod!(state_file_path, 0o600)

    context = %{
      backup_root: Path.join(environment.storage_root, "backups"),
      environment: environment,
      owners: %{
        primary: %{
          account_id: "10000000-0000-4000-8000-000000000001",
          principal_id: "10000000-0000-4000-8000-000000000002",
          vault_id: "10000000-0000-4000-8000-000000000003"
        },
        secondary: %{
          account_id: "20000000-0000-4000-8000-000000000001",
          principal_id: "20000000-0000-4000-8000-000000000002",
          vault_id: "20000000-0000-4000-8000-000000000003"
        }
      },
      run_id: @run_id,
      state_file_owned?: false,
      state_file_path: System.fetch_env!("SINGULARITY_BROWSER_STATE_FILE")
    }

    assert_raise Mix.Error, "browser state file could not be created", fn ->
      Browser.__write_state_file__(context)
    end

    assert :ok =
             Browser.__cleanup_generated_environment__(
               context,
               fn _environment -> :ok end,
               100
             )

    assert File.read!(state_file_path) == canary
    assert Bitwise.band(File.stat!(state_file_path).mode, 0o777) == 0o600
  end

  for stage <- [:chmod, :write, :sync] do
    @tag :tmp_dir
    test "lifecycle cleanup removes a run-created state file after #{stage} failure", %{
      tmp_dir: tmp_dir
    } do
      stage = unquote(stage)
      state_file_path = Path.join(tmp_dir, "partial-#{stage}.json")
      environment = TestEnvironment.from_playwright_run_id!(@run_id)
      test_process = self()
      File.rm_rf!(environment.storage_root)
      on_exit(fn -> File.rm_rf!(environment.storage_root) end)

      file_operations = failing_state_file_operations(stage, test_process)

      lifecycle = state_file_failure_lifecycle(environment, file_operations)

      assert_raise RuntimeError, "injected #{stage} failure", fn ->
        Browser.__run_lifecycle__(@run_id, state_file_path, lifecycle)
      end

      refute File.exists?(state_file_path)
      assert_receive {:state_file_closed, ^stage}
    end
  end

  @tag :tmp_dir
  test "browser restore parses only canonical state-owned paths and inherited passphrase", %{
    tmp_dir: tmp_dir
  } do
    %{arguments: arguments, state: state, source: source, expected: expected} =
      browser_restore_fixture!(tmp_dir)

    assert {:ok,
            %{
              source: ^source,
              expected_snapshot: ^expected,
              passphrase_fd: 0,
              run_id: @run_id,
              primary_vault_id: "10000000-0000-4000-8000-000000000003"
            }} = BrowserRestore.parse(arguments, state)

    nonzero_descriptor_arguments = List.replace_at(arguments, 5, "7")

    assert {:ok, %{passphrase_fd: 7}} =
             BrowserRestore.parse(nonzero_descriptor_arguments, state)

    for invalid <- [
          [],
          arguments ++ ["extra"],
          List.replace_at(arguments, 1, Path.relative_to(source, File.cwd!())),
          List.replace_at(arguments, 3, Path.join(tmp_dir, "missing.json")),
          List.replace_at(arguments, 5, "-1"),
          ["--source", source, "--expected", expected, "--passphrase", "secret"],
          ["--source", source, "--expected", expected, "--passphrase-fd", "0", "--extra"]
        ] do
      assert {:error, :invalid} = BrowserRestore.parse(invalid, state)
    end

    outside = Path.join(tmp_dir, "outside.bundle")
    File.write!(outside, "bundle")
    outside_arguments = List.replace_at(arguments, 1, outside)
    assert {:error, :invalid} = BrowserRestore.parse(outside_arguments, state)
  end

  @tag :tmp_dir
  test "browser restore rejects malformed and extra expected data before destination writes", %{
    tmp_dir: tmp_dir
  } do
    %{expected: expected} = browser_restore_fixture!(tmp_dir)

    assert {:ok, snapshot} = BrowserRestore.load_expected(expected)
    assert snapshot.version == 1

    for malformed <- [
          %{},
          Map.put(JSON.decode!(File.read!(expected)), "extra", true),
          put_in(JSON.decode!(File.read!(expected)), ["notes", Access.at(0), "markdown"], 17)
        ] do
      File.write!(expected, JSON.encode!(malformed))
      File.chmod!(expected, 0o600)
      assert {:error, :invalid} = BrowserRestore.load_expected(expected)
    end
  end

  test "browser restore destination lifecycle is isolated, listener-free, and always dropped" do
    primary_vault_id = "10000000-0000-4000-8000-000000000003"

    request = %{
      source: "/canonical/source.bundle",
      passphrase_fd: 0,
      primary_vault_id: primary_vault_id
    }

    expected = %{version: 1, vault_id: primary_vault_id}
    recorder = start_supervised!({Agent, fn -> [] end}, id: :browser_restore_recorder)
    record = fn event -> Agent.update(recorder, &[event | &1]) end

    adapters = %{
      allocate: fn ->
        record.(:allocate)
        %{database: "isolated", storage_root: "/isolated", suffix: "isolated"}
      end,
      create: fn destination ->
        record.({:create, destination})
        :ok
      end,
      drop: fn destination ->
        record.({:drop, destination})
        :ok
      end,
      assert_no_listener: fn ->
        record.(:assert_no_listener)
        :ok
      end,
      read_descriptor_once: fn 0 ->
        record.(:read_descriptor_once)
        {:ok, "CANARY_RESTORE_PASSPHRASE"}
      end,
      restore: fn destination, ^request, "CANARY_RESTORE_PASSPHRASE" ->
        record.({:restore, destination})
        {:ok, %{manifest_id: "10000000-0000-4000-8000-000000000004"}}
      end,
      compare: fn destination, _restored, ^expected ->
        record.({:compare, destination})
        :ok
      end
    }

    assert :ok = BrowserRestore.__execute__(request, expected, adapters)

    events = Agent.get(recorder, &Enum.reverse/1)

    assert [
             :read_descriptor_once,
             :allocate,
             :assert_no_listener,
             {:create, destination},
             :assert_no_listener,
             {:restore, destination},
             :assert_no_listener,
             {:compare, destination},
             :assert_no_listener,
             {:drop, destination}
           ] = events

    failing =
      put_in(adapters.restore, fn destination, ^request, "CANARY_RESTORE_PASSPHRASE" ->
        record.({:restore_failure, destination})
        raise "CANARY_PRIVATE_MARKDOWN"
      end)

    assert_raise RuntimeError, "CANARY_PRIVATE_MARKDOWN", fn ->
      BrowserRestore.__execute__(request, expected, failing)
    end

    assert {:drop, ^destination} = Agent.get(recorder, &hd/1)
  end

  test "browser restore rejects a started local listener and still drops its destination" do
    primary_vault_id = "10000000-0000-4000-8000-000000000003"
    request = %{passphrase_fd: 0, primary_vault_id: primary_vault_id}
    expected = %{vault_id: primary_vault_id}
    listener = start_supervised!({Agent, fn -> false end}, id: :browser_restore_listener)
    recorder = start_supervised!({Agent, fn -> [] end}, id: :listener_restore_recorder)
    record = fn event -> Agent.update(recorder, &[event | &1]) end

    adapters = %{
      allocate: fn ->
        record.(:allocate)
        :destination
      end,
      create: fn :destination ->
        record.(:create)
        Agent.update(listener, fn _stopped -> true end)
      end,
      drop: fn :destination ->
        record.(:drop)
        Agent.update(listener, fn _started -> false end)
      end,
      assert_no_listener: fn ->
        record.(:assert_no_listener)
        if Agent.get(listener, & &1), do: raise("local listener started"), else: :ok
      end,
      read_descriptor_once: fn 0 -> {:ok, "descriptor-only-secret"} end,
      restore: fn _destination, _request, _secret ->
        record.(:restore)
        {:ok, %{}}
      end,
      compare: fn _destination, _restored, _expected -> record.(:compare) end
    }

    assert_raise RuntimeError, "local listener started", fn ->
      BrowserRestore.__execute__(request, expected, adapters)
    end

    assert [:allocate, :assert_no_listener, :create, :assert_no_listener, :drop] =
             Agent.get(recorder, &Enum.reverse/1)

    refute Agent.get(listener, & &1)
  end

  test "actual browser restore listener guard rejects the registered web endpoint" do
    endpoint = :"Elixir.Singularity.Web.Endpoint"

    web_started? =
      Enum.any?(Application.started_applications(), fn {application, _description, _version} ->
        application == :singularity_web
      end)

    if web_started?, do: assert(:ok = Application.stop(:singularity_web))

    on_exit(fn ->
      if web_started?,
        do: assert({:ok, _started} = Application.ensure_all_started(:singularity_web))
    end)

    assert Process.whereis(endpoint) == nil
    assert :ok = BrowserRestore.__assert_no_listener__()

    endpoint_process = spawn(fn -> receive do: (:stop -> :ok) end)
    true = Process.register(endpoint_process, endpoint)
    monitor = Process.monitor(endpoint_process)

    on_exit(fn ->
      if Process.whereis(endpoint) == endpoint_process, do: Process.unregister(endpoint)
      if Process.alive?(endpoint_process), do: send(endpoint_process, :stop)
    end)

    assert_raise Mix.Error, "notes browser restore failed", fn ->
      BrowserRestore.__assert_no_listener__()
    end

    Process.unregister(endpoint)
    send(endpoint_process, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^endpoint_process, :normal}
    assert :ok = BrowserRestore.__assert_no_listener__()
  end

  test "browser restore binds expected vault before writes and drops allocated destination" do
    request = %{
      passphrase_fd: 0,
      primary_vault_id: "10000000-0000-4000-8000-000000000003"
    }

    expected = %{vault_id: "20000000-0000-4000-8000-000000000003"}
    recorder = start_supervised!({Agent, fn -> [] end}, id: :vault_binding_recorder)
    record = fn event -> Agent.update(recorder, &[event | &1]) end

    adapters = %{
      allocate: fn ->
        record.(:allocate)
        :destination
      end,
      create: fn _destination -> record.(:create) end,
      drop: fn :destination -> record.(:drop) end,
      assert_no_listener: fn -> record.(:assert_no_listener) end,
      read_descriptor_once: fn 0 -> {:ok, "descriptor-only-secret"} end,
      restore: fn _destination, _request, _secret -> record.(:restore) end,
      compare: fn _destination, _restored, _expected -> record.(:compare) end
    }

    assert_raise Mix.Error, "notes browser restore failed", fn ->
      BrowserRestore.__execute__(request, expected, adapters)
    end

    assert [:allocate, :drop] = Agent.get(recorder, &Enum.reverse/1)
  end

  test "browser restore is test-only, preferred by Mix, and reports generic secret-safe errors" do
    root_mix = File.read!(Path.expand("../../../../../mix.exs", __DIR__))
    assert root_mix =~ ~s("singularity.test.browser_restore": :test)

    previous_env = Mix.env()

    try do
      Mix.env(:dev)

      assert_raise Mix.Error, "notes browser restore failed", fn ->
        BrowserRestore.run(["--passphrase", "CANARY_RESTORE_SECRET"])
      end
    after
      Mix.env(previous_env)
    end
  end

  @tag :tmp_dir
  test "test-environment restore comparison failure is generic, marker-free, and dropped", %{
    tmp_dir: tmp_dir
  } do
    %{arguments: arguments, state: state} = browser_restore_fixture!(tmp_dir)
    canary = "CANARY_PRIVATE_RESTORE_COMPARISON"
    recorder = start_supervised!({Agent, fn -> [] end}, id: :restore_failure_recorder)
    record = fn event -> Agent.update(recorder, &[event | &1]) end

    adapters = %{
      allocate: fn ->
        record.(:allocate)
        :destination
      end,
      create: fn :destination -> record.(:create) end,
      drop: fn :destination -> record.(:drop) end,
      assert_no_listener: fn -> record.(:assert_no_listener) end,
      read_descriptor_once: fn 0 -> {:ok, "descriptor-only-secret"} end,
      restore: fn :destination, _request, _secret ->
        record.(:restore)
        {:ok, %{manifest_id: "10000000-0000-4000-8000-000000000004"}}
      end,
      compare: fn :destination, _restored, expected ->
        assert expected.notes |> hd() |> Map.fetch!(:markdown) =~ "CANARY_PRIVATE_MARKDOWN"
        record.(:compare)
        raise canary
      end
    }

    dependencies = %{
      execute: fn request, expected ->
        BrowserRestore.__execute__(request, expected, adapters)
      end,
      load_application_config: fn -> :ok end,
      load_expected: &BrowserRestore.load_expected/1,
      load_state: fn -> {:ok, state} end
    }

    output =
      capture_io(fn ->
        assert_raise Mix.Error, "notes browser restore failed", fn ->
          BrowserRestore.__run__(arguments, dependencies)
        end
      end)

    assert output == ""
    refute output =~ canary
    refute output =~ "notes_browser_restore_ok=true"

    assert [
             :allocate,
             :assert_no_listener,
             :create,
             :assert_no_listener,
             :restore,
             :assert_no_listener,
             :compare,
             :drop
           ] = Agent.get(recorder, &Enum.reverse/1)
  end

  @tag :tmp_dir
  test "configures generated backup storage, page size, real infrastructure, and the endpoint",
       %{tmp_dir: tmp_dir} do
    snapshot = Browser.__snapshot_environment__()
    on_exit(fn -> Browser.__restore_environment__(snapshot) end)

    storage_root = Path.join(tmp_dir, "generated-storage")
    File.mkdir_p!(storage_root)
    backup_root = Path.join(storage_root, "backups")
    refute File.exists?(backup_root)

    context = %{environment: %{storage_root: storage_root}}

    assert %{environment: %{storage_root: ^storage_root}, backup_root: ^backup_root} =
             Browser.__configure_environment__(context)

    assert Application.fetch_env!(:singularity_storage, :backup_root) == backup_root
    assert File.dir?(backup_root)
    assert Path.dirname(backup_root) == storage_root
    assert Application.fetch_env!(:singularity_web, :asset_page_limit) == 2

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

  defp restoring_lifecycle(cleanup_path, cleanup_registration) do
    %{
      environment: fn run_id -> %{run_id: run_id, storage_root: "/generated/storage"} end,
      snapshot: &Browser.__snapshot_environment__/0,
      register_cleanup: fn _owner, cleanup ->
        Agent.update(cleanup_registration, fn _previous -> cleanup end)
        :handler
      end,
      unregister_cleanup: fn :handler -> :ok end,
      provision: & &1,
      configure: fn context ->
        Application.put_env(:singularity_storage, :backup_root, "/generated/storage/backups")
        Application.put_env(:singularity_web, :asset_page_limit, 2)

        if cleanup_path == :partial_setup, do: raise("partial setup")
        context
      end,
      bootstrap: & &1,
      stop_provisioning_repos: & &1,
      start: & &1,
      wait: fn _context, cleanup ->
        case cleanup_path do
          :sigterm ->
            reference = make_ref()
            assert :ok = Browser.__cleanup_and_acknowledge__(self(), reference, cleanup)
            assert_receive {:singularity_browser_cleanup_complete, ^reference}

          :vm_at_exit ->
            at_exit_cleanup = Agent.get(cleanup_registration, & &1)
            assert is_function(at_exit_cleanup, 0)
            assert :ok = at_exit_cleanup.()

          _normal ->
            :ok
        end
      end,
      cleanup: fn context -> Browser.__restore_environment__(context.snapshot) end
    }
  end

  defp state_file_failure_lifecycle(environment, file_operations) do
    %{
      environment: fn @run_id -> environment end,
      snapshot: fn -> [] end,
      register_cleanup: fn _owner, _cleanup -> :handler end,
      unregister_cleanup: fn :handler -> :ok end,
      provision: & &1,
      configure: fn context ->
        Map.merge(context, %{
          backup_root: Path.join(environment.storage_root, "backups"),
          owners: %{
            primary: %{
              account_id: "10000000-0000-4000-8000-000000000001",
              principal_id: "10000000-0000-4000-8000-000000000002",
              vault_id: "10000000-0000-4000-8000-000000000003"
            },
            secondary: %{
              account_id: "20000000-0000-4000-8000-000000000001",
              principal_id: "20000000-0000-4000-8000-000000000002",
              vault_id: "20000000-0000-4000-8000-000000000003"
            }
          }
        })
      end,
      bootstrap: fn context -> Browser.__write_state_file__(context, file_operations) end,
      stop_provisioning_repos: & &1,
      start: & &1,
      wait: fn _context, _cleanup -> :ok end,
      cleanup: fn context ->
        Browser.__cleanup_generated_environment__(context, fn _environment -> :ok end, 100)
      end
    }
  end

  defp failing_state_file_operations(stage, test_process) do
    operations = %{
      chmod: &File.chmod!/2,
      close: fn file ->
        result = File.close(file)
        send(test_process, {:state_file_closed, stage})
        result
      end,
      mkdir_p: &File.mkdir_p!/1,
      open: &File.open(&1, [:write, :exclusive, :binary]),
      sync: &:file.sync/1,
      write: &IO.binwrite/2
    }

    failing_state_file_operation(operations, stage)
  end

  defp failing_state_file_operation(operations, :chmod),
    do: Map.put(operations, :chmod, fn _path, _mode -> raise "injected chmod failure" end)

  defp failing_state_file_operation(operations, :write),
    do: Map.put(operations, :write, fn _file, _content -> raise "injected write failure" end)

  defp failing_state_file_operation(operations, :sync),
    do: Map.put(operations, :sync, fn _file -> raise "injected sync failure" end)

  defp set_prior_browser_settings(:present) do
    Application.put_env(:singularity_storage, :backup_root, "/prior/backups")
    Application.put_env(:singularity_web, :asset_page_limit, 37)
    {{:ok, "/prior/backups"}, {:ok, 37}}
  end

  defp set_prior_browser_settings(:absent) do
    Application.delete_env(:singularity_storage, :backup_root)
    Application.delete_env(:singularity_web, :asset_page_limit)
    {:error, :error}
  end

  defp restore_setting(application, key, {:ok, value}),
    do: Application.put_env(application, key, value)

  defp restore_setting(application, key, :error), do: Application.delete_env(application, key)

  defp read_test_endpoint_config do
    config_path = Path.expand("../../../../../config/test.exs", __DIR__)

    config_path
    |> Config.Reader.read!(env: :test)
    |> Keyword.fetch!(:singularity_web)
    |> Keyword.fetch!(:"Elixir.Singularity.Web.Endpoint")
  end

  defp browser_restore_fixture!(tmp_dir) do
    backup_root = Path.join(tmp_dir, "backups")
    File.mkdir_p!(backup_root)
    source = Path.join(backup_root, "single.bundle")
    expected = Path.join(tmp_dir, "expected.json")
    File.write!(source, "bundle")

    snapshot = %{
      "version" => 1,
      "vault_id" => "10000000-0000-4000-8000-000000000003",
      "notes" => [
        %{
          "resource_id" => "10000000-0000-4000-8000-000000000010",
          "current_version_id" => "10000000-0000-4000-8000-000000000011",
          "title" => "Acceptance note",
          "markdown" => "# CANARY_PRIVATE_MARKDOWN\n",
          "deleted" => false,
          "versions" => [
            %{
              "resource_version_id" => "10000000-0000-4000-8000-000000000011",
              "revision" => 0,
              "parent_version_id" => nil,
              "merge_parent_version_id" => nil,
              "title" => "Acceptance note",
              "markdown" => "initial"
            }
          ],
          "conflicts" => [],
          "export" => %{
            "bytes" => "# CANARY_PRIVATE_MARKDOWN\n",
            "content_type" => "text/markdown; charset=utf-8",
            "content_disposition" => "attachment; filename=\"acceptance-note.md\"",
            "x_content_type_options" => "nosniff"
          }
        }
      ]
    }

    File.write!(expected, JSON.encode!(snapshot))
    File.chmod!(expected, 0o600)

    state = %{
      "version" => 1,
      "run_id" => @run_id,
      "backup_root" => backup_root,
      "owners" => %{
        "primary" => %{
          "login" => "owner@singularity.local",
          "account_id" => "10000000-0000-4000-8000-000000000001",
          "principal_id" => "10000000-0000-4000-8000-000000000002",
          "vault_id" => "10000000-0000-4000-8000-000000000003"
        },
        "secondary" => %{
          "login" => "secondary-owner@singularity.local",
          "account_id" => "20000000-0000-4000-8000-000000000001",
          "principal_id" => "20000000-0000-4000-8000-000000000002",
          "vault_id" => "20000000-0000-4000-8000-000000000003"
        }
      }
    }

    %{
      arguments: [
        "--source",
        source,
        "--expected",
        expected,
        "--passphrase-fd",
        "0"
      ],
      state: state,
      source: source,
      expected: expected
    }
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
