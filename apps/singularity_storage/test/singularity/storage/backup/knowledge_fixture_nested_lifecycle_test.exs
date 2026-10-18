defmodule Singularity.Storage.Backup.KnowledgeFixtureNestedLifecycleTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Singularity.Storage.Backup.KnowledgeFixtureResourceOwner, as: ResourceOwner
  alias Singularity.Storage.MigrationRepo

  @repos [
    MigrationRepo,
    Singularity.Storage.RequestRepo,
    Singularity.Storage.PreAuthRepo,
    Singularity.Storage.DispatcherRepo,
    Singularity.Storage.WorkerRepo
  ]
  @apps [:singularity_storage, :singularity_runtime]

  test "shared caller death waits for child native cleanup before parent cleanup" do
    result =
      run_scenario(fn scenario ->
        parent_gate = hold_cleanup(scenario)
        ordered_teardown(scenario)

        # Check the observed ordering only after both real lifetimes are clean.
        # The unordered RED shim reaches :owner_cleanup_begin as its first gate.
        assert parent_gate.stage == :waiting_for_child_cleanup,
               "parent must reach its child-cleanup wait before beginning native cleanup"

        chronological = Enum.reverse(progress(scenario.token).events)

        child_first? =
          before?(
            chronological,
            {:child, :owner_cleanup_completed},
            {:parent, :owner_cleanup_begin}
          )

        assert child_first?, "parent native cleanup must begin after child native completion"
      end)

    finish_scenario(result)
  end

  test "an assertion with both native barriers held preserves its primary failure and cleans in order" do
    result =
      run_scenario(fn scenario ->
        hold_cleanup(scenario)

        primary =
          capture(fn ->
            assert false, "nested fixture primary abort probe"
          end)

        update_progress(scenario.token, &Map.put(&1, :primary, primary))
        replay(primary)
      end)

    primary_preserved? =
      match?(
        {:raised, :error, %ExUnit.AssertionError{message: "nested fixture primary abort probe"},
         _},
        result.outcome
      ) and result.outcome == Map.get(result.progress, :primary)

    assert primary_preserved?,
           "ordered teardown must preserve the original assertion kind, reason and stack"

    assert_teardown(result)

    chronological = Enum.reverse(result.progress.events)

    ordered_release? =
      before?(chronological, {:child, :owner_cleanup_completed}, {:parent, :released}) and
        before?(chronological, {:parent, :released}, {:parent, :before_database_drop})

    assert ordered_release?,
           "abort teardown must join child native cleanup before parent release and DROP"
  end

  test "parent release rejects an unconfirmed child and leaves both native barriers held" do
    result =
      run_scenario(fn scenario ->
        hold_cleanup(scenario)
        token = scenario.token
        rejection = capture(fn -> release_owner(token, :parent) end)

        rejected? =
          match?(
            {:raised, :error,
             %ExUnit.AssertionError{
               message: "parent release requires exact child whole native cleanup confirmation"
             }, _},
            rejection
          )

        assert rejected?, "unconfirmed child cleanup must reject parent release explicitly"
        state = progress(token)
        gate = parent_gate_state(token, state.owners.parent)

        still_held? =
          not MapSet.member?(state.released, :parent) and
            not child_native_completed?(state) and
            gate.owner == state.owners.parent and gate.child == state.owners.child and
            not gate.child_completed? and not gate.continue_requested?

        assert still_held?, "rejected release must preserve the exact parent's held native gate"

        assert_parent_intact(
          scenario.maintenance,
          state.checkpoints[{:parent, :ready}],
          state.owners.parent
        )

        child = state.checkpoints[{:child, :ready}]

        child_intact? =
          database_exists?(scenario.maintenance, child.names.database) == true and
            File.dir?(child.names.storage_root) and
            application_configs() == state.checkpoints[:nested_ready].child_configs

        assert child_intact?, "rejected release must preserve child resources and configuration"
      end)

    finish_scenario(result)
    chronological = Enum.reverse(result.progress.events)

    ordered_release? =
      before?(chronological, {:child, :owner_cleanup_completed}, {:parent, :released}) and
        before?(chronological, {:parent, :released}, {:parent, :before_database_drop})

    assert ordered_release?,
           "confirmed child completion must precede eventual parent release and DROP"
  end

  test "normal child close acknowledges completion before immediate sibling admission" do
    registered_scenario(fn context ->
      {parent, _} = registered_open(context, :parent)
      park_repos(registered_resources(context, :parent))
      {child, _} = registered_open(context, :child, parent)
      assert :ok = ResourceOwner.close(child)
      {sibling, _} = registered_open(context, :sibling, parent)
      assert :ok = ResourceOwner.close(sibling)
      assert :ok = ResourceOwner.close(parent)
      events = registered_events(context)

      assert before?(
               events,
               {:child, :owner_cleanup_completed},
               {:child, :child_cleanup_acknowledged}
             )

      assert before?(
               events,
               {:child, :child_cleanup_acknowledged},
               {:sibling, :before_allocation}
             )

      assert before?(
               events,
               {:sibling, :child_cleanup_acknowledged},
               {:parent, :owner_cleanup_begin}
             )
    end)
  end

  test "the actual caller closes an ancestor and leaves registered child receipts intact" do
    registered_scenario(fn context ->
      {parent, _} = registered_open(context, :parent)
      park_repos(registered_resources(context, :parent))
      {child, _} = registered_open(context, :child, parent)
      assert {:error, :active_child} = ResourceOwner.start_infrastructure(parent, [])
      assert :ok = ResourceOwner.close(parent)
      assert Process.alive?(child)
      assert :ok = ResourceOwner.close(child)
      assert :ok = ResourceOwner.close(parent)
      events = registered_events(context)

      assert before?(
               events,
               {:parent, :waiting_for_child_cleanup},
               {:child, :owner_cleanup_completed}
             )

      assert before?(events, {:child, :owner_cleanup_completed}, {:parent, :owner_cleanup_begin})
      assert Enum.count(events, &(&1 == {:child, :before_database_drop})) == 1
      assert Enum.count(events, &(&1 == {:parent, :owner_cleanup_completed})) == 1
    end)
  end

  test "foreign caller and active child admission reject before configuration capture or allocation" do
    registered_scenario(fn context ->
      {parent, _} = registered_open(context, :parent)
      park_repos(registered_resources(context, :parent))
      configs = application_configs()
      test_pid = self()
      token = context.token

      {foreign, monitor} =
        spawn_monitor(fn ->
          controller_monitor = Process.monitor(test_pid)
          checkpoint = fn stage, _ -> send(test_pid, {token, :foreign_stage, stage}) end

          result =
            capture(fn ->
              ResourceOwner.with_checkpoint(checkpoint, fn ->
                ResourceOwner.open_child(parent, migration_pool_size: 2)
              end)
            end)

          send(test_pid, {token, :foreign_result, result})

          receive do
            {^token, :foreign_done} -> :ok
            {:DOWN, ^controller_monitor, :process, ^test_pid, _} -> :ok
          end
        end)

      result = private_message(token, :foreign_result)
      assert_relationship(result, :different_caller)
      foreign_stages = collect_foreign_stages(token, [])
      refute :before_allocation in foreign_stages
      assert_configuration(configs)
      {child, _} = registered_open(context, :child, parent)
      configs = application_configs()

      assert_relationship(
        capture(fn -> registered_open(context, :rejected, parent) end),
        :active_child
      )

      assert_configuration(configs)
      refute {:rejected, :before_allocation} in registered_events(context)
      assert :ok = ResourceOwner.close(child)
      assert :ok = ResourceOwner.close(parent)
      assert Process.alive?(foreign)
      send(foreign, {token, :foreign_done})
      assert_down(monitor, foreign, :normal, 1_000)
    end)
  end

  test "a live foreign process cannot release an ancestor with an active child" do
    registered_scenario(fn context ->
      {parent, _} = registered_open(context, :parent)
      park_repos(registered_resources(context, :parent))
      {child, _} = registered_open(context, :child, parent)
      controller = self()
      token = context.token
      {_id, actual_finish} = registered_state(context).arms.parent.on_exit

      {foreign, monitor} =
        spawn_monitor(fn ->
          controller_monitor = Process.monitor(controller)
          results = [capture(fn -> ResourceOwner.close(parent) end), capture(actual_finish)]
          send(controller, {token, :foreign_result, results})

          receive do
            {^token, :foreign_done} -> :ok
            {:DOWN, ^controller_monitor, :process, ^controller, _} -> :ok
          end
        end)

      for result <- private_message(token, :foreign_result),
          do: assert_relationship(result, :not_owner)

      assert Process.alive?(child)
      assert :ok = ResourceOwner.close(child)
      assert :ok = ResourceOwner.close(parent)
      assert Process.alive?(foreign)
      send(foreign, {token, :foreign_done})
      assert_down(monitor, foreign, :normal, 1_000)
    end)
  end

  test "foreign terminal peers and references cannot detach the actual child or consume its receipt" do
    registered_scenario(fn context ->
      {parent, _} = registered_open(context, :parent)
      park_repos(registered_resources(context, :parent))
      {child, _} = registered_open(context, :child, parent)
      edge = registered_resources(context, :child).parent.ref
      send(parent, {:child_cleanup_completed, child, make_ref(), [:foreign_receipt]})
      send(parent, {:child_cleanup_completed, self(), edge, [:foreign_receipt]})
      send(parent, {:DOWN, make_ref(), :process, child, :foreign_down})
      send(child, {:child_cleanup_acknowledged, self(), edge})
      send(child, {:child_cleanup_acknowledged, parent, make_ref()})
      # The request follows the forged signals from this exact sender. Its
      # positive active-child reply proves the actual edge remains installed.
      assert {:error, :active_child} = ResourceOwner.start_infrastructure(parent, [])

      assert_relationship(
        capture(fn -> registered_open(context, :rejected, parent) end),
        :active_child
      )

      assert :ok = ResourceOwner.close(child)
      assert :ok = ResourceOwner.close(parent)
    end)
  end

  test "invalid dead unarmed and closed parents reject without native entry" do
    registered_scenario(fn context ->
      configs = application_configs()

      for parent <- [:invalid, self()] do
        assert_relationship(
          capture(fn -> registered_open(context, make_ref(), parent) end),
          :invalid_parent
        )
      end

      {dead, dead_monitor} = spawn_monitor(fn -> :ok end)
      assert_down(dead_monitor, dead, :normal, 1_000)
      assert_relationship(capture(fn -> registered_open(context, :dead, dead) end), :parent_down)
      assert_configuration(configs)
      {parent, _} = registered_open(context, :parent)
      assert :ok = ResourceOwner.close(parent)

      assert_relationship(
        capture(fn -> registered_open(context, :closed, parent) end),
        :parent_closed
      )

      assert_configuration(configs)
      configs = application_configs()

      unarmed_probe = fn
        :before_arm, resources ->
          assert_relationship(
            capture(fn -> registered_open(context, :unarmed_child, resources.owner) end),
            :parent_not_ready
          )

          throw(:unarmed_probe)

        _, _ ->
          :ok
      end

      assert {:raised, :throw, :unarmed_probe, _} =
               capture(fn -> registered_open(context, :unarmed, nil, unarmed_probe) end)

      assert_configuration(configs)
      events = registered_events(context)

      for role <- [:dead, :closed, :unarmed_child, :unarmed],
          do: refute({role, :before_allocation} in events)
    end)
  end

  for stage <- [:before_allocation, :root_created, {:repo_started, MigrationRepo, :migration}] do
    test "partial child acquisition at #{inspect(stage)} preserves the exact primary error and parent" do
      registered_scenario(fn context ->
        {parent, _} = registered_open(context, :parent)
        parent_resources = registered_resources(context, :parent)
        park_repos(parent_resources)
        configs = application_configs()
        primary = make_ref()

        probe = fn stage, _resources ->
          if stage == unquote(Macro.escape(stage)), do: primary_acquisition(context, primary)
        end

        result = capture(fn -> registered_open(context, :child, parent, probe) end)
        assert {:raised, :throw, {:primary_acquisition, ^primary}, stack} = result
        assert stack != []
        preserved? = result == private_message(context.token, :primary_probe)

        assert preserved?,
               "partial acquisition must preserve the exact original kind, reason and stack"

        assert_configuration(configs)
        assert_parent_intact(context.maintenance, parent_resources, parent)
        {sibling, _} = registered_open(context, :sibling, parent)
        assert :ok = ResourceOwner.close(sibling)
        assert :ok = ResourceOwner.close(parent)
      end)
    end
  end

  test "primary acquisition and independent cleanup errors survive both actual registered callbacks" do
    registered_scenario(fn context ->
      {parent, _} = registered_open(context, :parent)
      park_repos(registered_resources(context, :parent))
      primary = make_ref()

      probe = fn
        :root_created, _ -> primary_acquisition(context, primary)
        :owner_cleanup_completed, _ -> throw(:cleanup_observation_probe)
        _, _ -> :ok
      end

      result = capture(fn -> registered_open(context, :child, parent, probe) end)
      assert {:raised, :throw, {:primary_acquisition, ^primary}, stack} = result
      assert stack != []
      preserved? = result == private_message(context.token, :primary_probe)
      assert preserved?, "independent cleanup failure must not replace the exact primary stack"
      failures = [{:checkpoint_failed, :owner_cleanup_completed, :throw}]
      expect_registered_failures(context, :child, failures)
      expect_registered_failures(context, :parent, failures)
      configs = application_configs()

      assert_relationship(
        capture(fn -> registered_open(context, :rejected, parent) end),
        :parent_cleanup_failed
      )

      assert_configuration(configs)
      refute {:rejected, :before_allocation} in registered_events(context)
      error = capture(fn -> ResourceOwner.close(parent) end)
      assert_cleanup_failure(error, failures)
      assert_cleanup_failure(capture(fn -> ResourceOwner.close(parent) end), failures)
    end)
  end

  test "a throwing parent wait observation records failure without bypassing its child drain" do
    registered_scenario(fn context ->
      probe = fn
        :waiting_for_child_cleanup, resources -> throw({:private_observer_payload, resources})
        _, _ -> :ok
      end

      {parent, _} = registered_open(context, :parent, nil, probe)
      park_repos(registered_resources(context, :parent))
      {child, _} = registered_open(context, :child, parent)
      failures = [{:checkpoint_failed, :waiting_for_child_cleanup, :throw}]
      expect_registered_failures(context, :parent, failures)
      result = capture(fn -> ResourceOwner.close(parent) end)
      assert_cleanup_failure(result, failures)
      {:raised, :error, error, _} = result
      refute String.contains?(Exception.message(error), "private_observer_payload")
      assert :ok = ResourceOwner.close(child)
      events = registered_events(context)
      assert before?(events, {:child, :owner_cleanup_completed}, {:parent, :owner_cleanup_begin})
    end)
  end

  test "an owned dependency EXIT during an already accepted close remains observable after the child drain" do
    registered_scenario(fn context ->
      controller = self()
      token = context.token

      probe = fn
        :waiting_for_child_cleanup, resources ->
          child = private_message(token, :child_drop_for_exit)
          maintenance = private_message(token, :parent_maintenance_for_exit)
          monitor = Process.monitor(maintenance)
          Process.exit(maintenance, :kill)
          assert_down(monitor, maintenance, :killed, 1_000)
          send(resources.child.pid, {token, :continue})
          child_matches? = child == resources.child.pid

          assert child_matches?,
                 "the drain probe must release the exact child's native DROP barrier"

        _, _ ->
          :ok
      end

      {parent, _} = registered_open(context, :parent, nil, probe)
      parent_resources = registered_resources(context, :parent)
      park_repos(parent_resources)
      send(parent, {token, :parent_maintenance_for_exit, parent_resources.maintenance})

      child_probe = fn
        :before_database_drop, resources ->
          send(parent, {token, :child_drop_for_exit, resources.owner})
          barrier(controller, token, :child_drop_for_exit_held, resources)

        _, _ ->
          :ok
      end

      {child, _} = registered_open(context, :child, parent, child_probe)
      failures = [{:owned_process_exited, parent_resources.maintenance}]
      expect_registered_failures(context, :parent, failures)
      assert_cleanup_failure(capture(fn -> ResourceOwner.close(parent) end), failures)
      assert :ok = ResourceOwner.close(child)
      events = registered_events(context)
      assert before?(events, {:child, :owner_cleanup_completed}, {:parent, :owner_cleanup_begin})
    end)
  end

  test "a parent owned dependency failure drains its active child before its own native cleanup" do
    registered_scenario(fn context ->
      {parent, _} = registered_open(context, :parent)
      resources = registered_resources(context, :parent)
      park_repos(resources)
      {child, _} = registered_open(context, :child, parent)
      monitor = Process.monitor(resources.maintenance)
      Process.exit(resources.maintenance, :kill)
      assert_down(monitor, resources.maintenance, :killed, 1_000)
      await_registered_stage(context, :parent, :owner_cleanup_completed)
      failures = [{:owned_process_exited, resources.maintenance}]
      expect_registered_failures(context, :parent, failures)
      assert_cleanup_failure(capture(fn -> ResourceOwner.close(parent) end), failures)
      assert :ok = ResourceOwner.close(child)
      events = registered_events(context)

      assert before?(
               events,
               {:parent, :waiting_for_child_cleanup},
               {:child, :owner_cleanup_completed}
             )

      assert before?(events, {:child, :owner_cleanup_completed}, {:parent, :owner_cleanup_begin})
    end)
  end

  test "owned child Repo failure is retained once and closes subsequent parent admission" do
    registered_scenario(fn context ->
      {parent, _} = registered_open(context, :parent)
      park_repos(registered_resources(context, :parent))
      {child, _} = registered_open(context, :child, parent)
      resources = registered_resources(context, :child)
      repo = resources.repos[MigrationRepo]
      monitor = Process.monitor(repo)
      Process.exit(repo, :kill)
      assert_down(monitor, repo, :killed, 5_000)
      await_registered_stage(context, :child, :child_cleanup_acknowledged)
      failures = [{:owned_process_exited, repo}]
      expect_registered_failures(context, :child, failures)
      expect_registered_failures(context, :parent, failures)
      assert_cleanup_failure(capture(fn -> ResourceOwner.close(child) end), failures)

      assert_relationship(
        capture(fn -> registered_open(context, :rejected, parent) end),
        :parent_cleanup_failed
      )

      assert_cleanup_failure(capture(fn -> ResourceOwner.close(parent) end), failures)
    end)
  end

  test "a post-ACK observation failure stays in the child's actual close and callback receipt" do
    registered_scenario(fn context ->
      {parent, _} = registered_open(context, :parent)
      park_repos(registered_resources(context, :parent))

      probe = fn
        :child_cleanup_acknowledged, _ -> throw(:post_ack_observation_probe)
        _, _ -> :ok
      end

      {child, _} = registered_open(context, :child, parent, probe)
      failures = [{:checkpoint_failed, :child_cleanup_acknowledged, :throw}]
      expect_registered_failures(context, :child, failures)
      assert_cleanup_failure(capture(fn -> ResourceOwner.close(child) end), failures)
      assert_cleanup_failure(capture(fn -> ResourceOwner.close(child) end), failures)
      # P already accepted the pre-ACK receipt. The later observation belongs
      # to K's retained result; it must neither reopen nor poison P's edge.
      {sibling, _} = registered_open(context, :sibling, parent)
      assert :ok = ResourceOwner.close(sibling)
      assert :ok = ResourceOwner.close(parent)
    end)
  end

  test "an admitted child lost before allocation poisons its parent's completion exactly once" do
    registered_scenario(fn context ->
      {parent, _} = registered_open(context, :parent)
      park_repos(registered_resources(context, :parent))

      probe = fn
        :before_arm, resources ->
          monitor = Process.monitor(resources.owner)
          Process.exit(resources.owner, :kill)
          assert_down(monitor, resources.owner, :killed, 1_000)
          throw(:lost_before_allocation)

        _, _ ->
          :ok
      end

      assert {:raised, :throw, :lost_before_allocation, _} =
               capture(fn -> registered_open(context, :child, parent, probe) end)

      arm = registered_state(context).arms.child
      {id, callback} = arm.on_exit
      actual = capture(callback)
      on_exit(id, fn -> :ok end)
      update_registered(context, &%{&1 | consumed: MapSet.put(&1.consumed, :child)})
      assert {:raised, :exit, {:fixture_owner_down, :noproc}, _} = actual
      failures = [{:unconfirmed_child_cleanup, arm.owner}]
      expect_registered_failures(context, :parent, failures)
      await_failed_parent(context, parent, System.monotonic_time(:millisecond) + 5_000)
      assert_cleanup_failure(capture(fn -> ResourceOwner.close(parent) end), failures)
      assert_cleanup_failure(capture(fn -> ResourceOwner.close(parent) end), failures)
      refute {:child, :before_allocation} in registered_events(context)
    end)
  end

  for stage <- [
        :child_attach_requested,
        :before_allocation,
        :root_created,
        {:repo_started, MigrationRepo, :migration}
      ] do
    test "shared caller death during child #{inspect(stage)} settles admission and partial native work" do
      partial_death_scenario(unquote(Macro.escape(stage)))
    end
  end

  test "unnested acquisition and native cleanup failures retain the qualified release stack" do
    registered_scenario(fn context ->
      controller = self()
      token = context.token
      foreign_ref = make_ref()
      primary = make_ref()

      {foreign, foreign_monitor} =
        spawn_monitor(fn ->
          controller_monitor = Process.monitor(controller)

          try do
            receive do
              {^token, :register_repository, owner, ^foreign_ref} ->
                true = Process.register(self(), MigrationRepo)
                send(owner, {token, :repository_registered, self(), foreign_ref})

                receive do
                  {^token, :release_repository, ^owner, ^foreign_ref} -> :ok
                  {^token, :release_repository, ^controller, ^foreign_ref} -> :ok
                  {:DOWN, ^controller_monitor, :process, ^controller, _} -> :ok
                end

              {^token, :release_repository, ^controller, ^foreign_ref} ->
                :ok

              {:DOWN, ^controller_monitor, :process, ^controller, _} ->
                :ok
            end
          after
            Process.demonitor(controller_monitor, [:flush])
          end
        end)

      failures = [{:unexpected_repository, MigrationRepo, foreign}]
      expect_registered_failures(context, :unnested, failures)

      outcome =
        capture(fn ->
          probe = fn
            :root_created, resources ->
              send(foreign, {token, :register_repository, resources.owner, foreign_ref})

              receive do
                {^token, :repository_registered, ^foreign, ^foreign_ref} -> :ok
              after
                30_000 -> flunk("exact foreign repository registration was not observed")
              end

              primary_acquisition(context, primary)

            :before_database_drop, resources ->
              # MTE has already recorded the foreign identity. Join it before
              # native cleanup restores the original named repositories.
              monitor = Process.monitor(foreign)
              send(foreign, {token, :release_repository, resources.owner, foreign_ref})
              assert_down(monitor, foreign, :normal, 1_000)

            _, _ ->
              :ok
          end

          result = capture(fn -> registered_open(context, :unnested, nil, probe) end)

          assert {:raised, :throw, {:primary_acquisition, ^primary}, _} =
                   private_message(token, :primary_probe)

          assert_cleanup_failure(result, failures)

          release_stack? =
            match?(
              {:raised, :error, %ResourceOwner.CleanupError{},
               [{ResourceOwner, :release, 2, _} | _]},
              result
            )

          assert release_stack?,
                 "unnested simultaneous failures must retain the qualified release/2 stack"
        end)

      # Always attempt the exact foreign teardown, including acquisition and
      # intended RED failures; registered_scenario independently joins callbacks
      # and verifies the complete native baseline before replaying this result.
      send(foreign, {token, :release_repository, controller, foreign_ref})
      foreign_join = capture(fn -> assert_down(foreign_monitor, foreign, :normal, 1_000) end)
      replay_outcomes([outcome, foreign_join])
    end)
  end

  test "registered pre-arm cancellation rejects child acquisition after retained completion" do
    registered_scenario(fn context ->
      {parent, _} = registered_open(context, :parent)
      parent_resources = registered_resources(context, :parent)
      park_repos(parent_resources)
      failures = [{:owned_process_exited, parent_resources.maintenance}]
      expect_registered_failures(context, :parent, failures)
      controller = self()
      token = context.token

      probe = fn
        :before_arm, arm ->
          child = arm.owner
          {id, actual_finish} = arm.on_exit

          {guardian, guardian_monitor} =
            spawn_monitor(fn ->
              controller_monitor = Process.monitor(controller)
              child_monitor = Process.monitor(child)

              try do
                rescued? =
                  receive do
                    {^token, :retained_child_closed, ^controller, ^child, ^id} ->
                      receive do
                        {^token, :prearm_terminal, ^controller, ^child, ^id} -> false
                        {^token, :prearm_abort, ^controller, ^child, ^id} -> true
                        {:DOWN, ^controller_monitor, :process, ^controller, _} -> true
                      after
                        30_000 -> true
                      end

                    {^token, :prearm_abort, ^controller, ^child, ^id} ->
                      true

                    {:DOWN, ^controller_monitor, :process, ^controller, _} ->
                      true
                  end

                # Always attempt the captured real callback, even on an abort
                # or controller death; its receipt and the exact DOWN are separate.
                actual = capture(actual_finish)

                down =
                  capture(fn ->
                    assert_down(child_monitor, child, :normal, 1_000)
                    :ok
                  end)

                send(
                  controller,
                  {token, :prearm_finish_receipt, {self(), child, id, actual, down, rescued?}}
                )
              after
                Process.demonitor(controller_monitor, [:flush])
                Process.demonitor(child_monitor, [:flush])
              end
            end)

          update_registered(context, fn state ->
            Map.put(state, :prearm_guardian, %{
              pid: guardian,
              monitor: guardian_monitor,
              child: child,
              callback_id: id
            })
          end)

          prepared =
            capture(fn ->
              attached = registered_resources(context, :child)

              exact_owned? =
                arm.caller == controller and attached.parent.pid == parent and
                  attached.owner == child and parent_resources.owner == parent and
                  parent_resources.maintenance != context.maintenance and
                  Process.alive?(parent_resources.maintenance)

              assert exact_owned?,
                     "pre-arm cancellation must use the exact admitted native owners"

              monitor = Process.monitor(parent_resources.maintenance)
              Process.exit(parent_resources.maintenance, :kill)
              assert_down(monitor, parent_resources.maintenance, :killed, 1_000)
              await_registered_stage(context, :parent, :owner_cleanup_completed)

              # A real close reply followed by a live registered owner proves
              # retained completion before the caller resumes open_child/2.
              assert :ok = ResourceOwner.close(child)
              assert Process.alive?(child)
              refute {:child, :before_allocation} in registered_events(context)
              :ok
            end)

          stage =
            if prepared == {:returned, :ok}, do: :retained_child_closed, else: :prearm_abort

          send(guardian, {token, stage, controller, child, id})
          replay(prepared)

        _, _ ->
          :ok
      end

      outcome = capture(fn -> registered_open(context, :child, parent, probe) end)

      completion =
        capture(fn ->
          guardian = Map.fetch!(registered_state(context), :prearm_guardian)
          child = guardian.child
          id = guardian.callback_id
          guardian_pid = guardian.pid
          send(guardian_pid, {token, :prearm_terminal, controller, child, id})
          receipt = private_message(token, :prearm_finish_receipt)

          guardian_down =
            capture(fn ->
              assert_down(guardian.monitor, guardian_pid, :normal, 1_000)
              :ok
            end)

          confirmed? =
            match?(
              {^guardian_pid, ^child, ^id, {:returned, :ok}, {:returned, :ok}, _},
              receipt
            ) and guardian_down == {:returned, :ok}

          # Only the original registered caller consumes this exact callback ID,
          # after positive callback, child normal-DOWN and guardian normal-DOWN.
          if confirmed? do
            on_exit(id, fn -> :ok end)
            update_registered(context, &%{&1 | consumed: MapSet.put(&1.consumed, :child)})
          end

          replay_outcomes([
            capture(fn ->
              assert confirmed?, "the actual pre-arm callback and both exact owners must finish"
            end),
            guardian_down
          ])

          {^guardian_pid, ^child, ^id, _, _, rescued?} = receipt
          rescued?
        end)

      # Capture acquisition before checking it so intended RED still joins the
      # guardian and registered_scenario verifies every native baseline binding.
      rescued? = replay(completion)
      assert_relationship(outcome, :parent_closed)
      refute rescued?, "terminal child rejection must complete without the test rescue"
      refute {:child, :before_allocation} in registered_events(context)
      assert_cleanup_failure(capture(fn -> ResourceOwner.close(parent) end), failures)
    end)
  end

  defp registered_scenario(fun) do
    token = make_ref()
    context = %{token: token, caller: self(), baseline: baseline(), maintenance: maintenance()}

    Process.put({__MODULE__, token, :registered}, %{
      arms: %{},
      resources: %{},
      events: [],
      failures: %{},
      consumed: MapSet.new()
    })

    try do
      outcome = capture(fn -> fun.(context) end)
      cleanup = capture(fn -> finish_registered(context) end)
      replay_outcomes([outcome, cleanup])
    after
      Process.delete({__MODULE__, token, :registered})
    end
  end

  defp registered_open(context, role, parent \\ nil, probe \\ fn _, _ -> :ok end) do
    controller = self()
    token = context.token

    checkpoint = fn stage, resources ->
      if stage == :before_arm do
        update_registered(context, fn state ->
          %{state | arms: Map.put(state.arms, role, resources)}
        end)
      end

      send(controller, {token, :registered_stage, role, stage, resources})
      probe.(stage, resources)
    end

    ResourceOwner.with_checkpoint(checkpoint, fn ->
      if is_nil(parent),
        do: ResourceOwner.open(migration_pool_size: 2),
        else: ResourceOwner.open_child(parent, migration_pool_size: 2)
    end)
  end

  defp registered_state(context) do
    drain_registered(context)
    Process.get({__MODULE__, context.token, :registered})
  end

  defp update_registered(context, fun) do
    key = {__MODULE__, context.token, :registered}
    Process.put(key, fun.(Process.get(key)))
  end

  defp drain_registered(context) do
    token = context.token

    receive do
      {^token, :registered_stage, role, stage, resources} ->
        record_registered(context, role, stage, resources)
        drain_registered(context)
    after
      0 -> :ok
    end
  end

  defp record_registered(context, role, stage, resources) do
    update_registered(context, fn state ->
      prior = Map.get(state.resources, role, %{})

      %{
        state
        | events: state.events ++ [{role, stage}],
          resources: Map.put(state.resources, role, Map.merge(prior, resources))
      }
    end)
  end

  defp await_registered_stage(context, role, stage) do
    if {role, stage} not in registered_state(context).events do
      token = context.token

      receive do
        {^token, :registered_stage, observed_role, observed_stage, resources} ->
          record_registered(context, observed_role, observed_stage, resources)
          await_registered_stage(context, role, stage)
      after
        30_000 -> flunk("exact registered lifecycle stage was not observed")
      end
    end

    :ok
  end

  defp registered_resources(context, role),
    do: Map.fetch!(registered_state(context).resources, role)

  defp registered_events(context), do: registered_state(context).events

  defp expect_registered_failures(context, role, failures) do
    update_registered(context, &%{&1 | failures: Map.put(&1.failures, role, failures)})
  end

  defp finish_registered(context) do
    state = registered_state(context)

    roles =
      state.events
      |> Enum.filter(&(elem(&1, 1) == :before_arm))
      |> Enum.map(&elem(&1, 0))
      |> Enum.reverse()

    joins =
      for role <- roles do
        capture(fn ->
          arm = state.arms[role]
          failures = Map.get(state.failures, role, [])

          if MapSet.member?(registered_state(context).consumed, role) do
            alive? = Process.alive?(arm.owner)
            refute alive?, "an already consumed exact callback must have terminated its owner"
          else
            closed = capture(fn -> ResourceOwner.close(arm.owner) end)
            {id, callback} = arm.on_exit
            monitor = Process.monitor(arm.owner)
            actual = capture(callback)
            # Always attempt and consume the actual callback before checking
            # either result, so one unexpected outcome cannot strand siblings.
            on_exit(id, fn -> :ok end)
            update_registered(context, &%{&1 | consumed: MapSet.put(&1.consumed, role)})
            down = capture(fn -> assert_down(monitor, arm.owner, :normal, 1_000) end)

            replay_outcomes([
              capture(fn -> assert_expected_cleanup(closed, failures) end),
              capture(fn -> assert_expected_cleanup(actual, failures) end),
              down
            ])
          end
        end)
      end

    final_baseline =
      capture(fn ->
        resources =
          for {_role, resource} <- registered_state(context).resources,
              not is_nil(Map.get(resource, :names)),
              do: resource

        assert_cleanup(context.maintenance, resources, context.baseline)
      end)

    replay_outcomes(joins ++ [final_baseline])
  end

  defp replay_outcomes(outcomes) do
    errors = for {:raised, kind, reason, stack} <- outcomes, do: {kind, reason, stack}

    case errors do
      [] -> :ok
      [{kind, reason, stack}] -> :erlang.raise(kind, reason, stack)
      errors -> raise ExUnit.MultiError, errors: errors
    end
  end

  defp assert_expected_cleanup(result, []), do: assert(match?({:returned, :ok}, result))
  defp assert_expected_cleanup(result, failures), do: assert_cleanup_failure(result, failures)

  defp assert_cleanup_failure(result, failures) do
    valid? =
      case result do
        {:raised, :error, %ResourceOwner.CleanupError{failures: actual}, _} -> actual == failures
        _ -> false
      end

    assert valid?, "exact cleanup failure must remain independently observable"
  end

  defp assert_relationship(result, reason) do
    valid? =
      case result do
        {:raised, :error, %{__struct__: module, reason: actual_reason} = exception, _} ->
          module == ResourceOwner.RelationshipError and actual_reason == reason and
            Exception.message(exception) == "knowledge fixture relationship rejected: #{reason}"

        _ ->
          false
      end

    assert valid?, "relationship rejection must retain its exact content-free reason"
  end

  defp assert_configuration(configs) do
    restored? = application_configs() == configs

    assert restored?,
           "relationship rejection or child cleanup must preserve the complete configuration"
  end

  defp primary_acquisition(context, primary) do
    original = capture(fn -> throw({:primary_acquisition, primary}) end)
    send(context.caller, {context.token, :primary_probe, original})
    replay(original)
  end

  defp await_failed_parent(context, parent, deadline) do
    result = capture(fn -> registered_open(context, :rejected, parent) end)

    case result do
      {:raised, :error, %ResourceOwner.RelationshipError{reason: :active_child}, _} ->
        within_deadline? = System.monotonic_time(:millisecond) < deadline

        assert within_deadline?,
               "the exact child DOWN must close the parent admission slot as failed"

        await_failed_parent(context, parent, deadline)

      other ->
        assert_relationship(other, :parent_cleanup_failed)
    end
  end

  defp private_message(token, stage) do
    receive do
      {^token, ^stage, value} -> value
    after
      30_000 -> flunk("exact private lifecycle reply was not observed")
    end
  end

  defp assert_down(monitor, pid, expected, timeout) do
    try do
      receive do
        {:DOWN, ^monitor, :process, ^pid, actual} ->
          expected? = actual == expected
          assert expected?, "the exact lifecycle process must terminate with its expected outcome"
      after
        timeout -> flunk("the exact lifecycle process did not terminate")
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp collect_foreign_stages(token, stages) do
    receive do
      {^token, :foreign_stage, stage} -> collect_foreign_stages(token, [stage | stages])
    after
      0 -> stages
    end
  end

  defp partial_death_scenario(stage) do
    baseline = baseline()
    maintenance = maintenance()
    controller = self()
    token = make_ref()

    {actor, actor_monitor} =
      spawn_monitor(fn ->
        checkpoint = fn observed, resources ->
          send(controller, {token, :parent_stage, observed, resources})
        end

        {parent, _} =
          ResourceOwner.with_checkpoint(checkpoint, fn ->
            ResourceOwner.open(migration_pool_size: 2)
          end)

        resources = private_message(token, :parent_resources)
        park_repos(resources)

        checkpoint = fn observed, resources ->
          send(controller, {token, :child_stage, observed, resources})
          if observed == stage, do: barrier(controller, token, :partial_gate, resources)
        end

        ResourceOwner.with_checkpoint(checkpoint, fn ->
          ResourceOwner.open_child(parent, migration_pool_size: 2)
        end)
      end)

    parent = partial_stage(token, :parent_stage, :ready)
    parent_monitor = Process.monitor(parent.owner)
    send(actor, {token, :parent_resources, parent})
    gate = private_message(token, :partial_gate)
    child_monitor = Process.monitor(gate.owner)
    actor_monitor_ref = Process.monitor(actor)
    Process.exit(actor, :nested_partial_caller_failure)
    assert_down(actor_monitor_ref, actor, :nested_partial_caller_failure, 1_000)
    send(gate.owner, {token, :continue})

    child =
      if stage == :child_attach_requested,
        do: gate,
        else: partial_stage(token, :child_stage, :owner_cleanup_completed, gate)

    parent_completed = partial_stage(token, :parent_stage, :owner_cleanup_completed, parent)
    assert_down(child_monitor, gate.owner, :normal, 15_000)
    assert_down(parent_monitor, parent.owner, :normal, 15_000)
    assert_down(actor_monitor, actor, :nested_partial_caller_failure, 1_000)
    resources = Enum.filter([child, parent_completed], &(not is_nil(Map.get(&1, :names))))
    assert_cleanup(maintenance, resources, baseline)
  end

  defp partial_stage(token, kind, wanted, accumulated \\ %{}) do
    receive do
      {^token, ^kind, stage, resources} ->
        accumulated = Map.merge(accumulated, resources)
        if stage == wanted, do: accumulated, else: partial_stage(token, kind, wanted, accumulated)
    after
      30_000 -> flunk("exact partial acquisition stage was not observed")
    end
  end

  defp run_scenario(fun) do
    baseline = baseline()
    maintenance = maintenance()
    token = make_ref()
    controller = self()
    {actor, actor_monitor} = spawn_monitor(fn -> nested_actor(controller, token) end)

    Process.put(progress_key(token), %{
      actor: actor,
      monitors: %{actor_monitor => {:actor, actor}},
      owners: %{},
      checkpoints: %{},
      downs: %{},
      released: MapSet.new(),
      events: [],
      baseline_verified?: false
    })

    scenario = %{token: token, baseline: baseline, maintenance: maintenance}

    try do
      outcome =
        capture(fn ->
          receive_checkpoint(token, {:parent, :before_arm})
          receive_checkpoint(token, {:parent, :ready})
          receive_checkpoint(token, {:child, :before_arm})
          receive_checkpoint(token, {:child, :ready})
          receive_checkpoint(token, :nested_ready)
          fun.(scenario)
        end)

      # Keep the primary exception intact and the independent teardown outcome
      # observable. In particular, a cleanup exception cannot replace it.
      cleanup = capture(fn -> ordered_teardown(scenario) end)
      %{outcome: outcome, cleanup: cleanup, progress: progress(token)}
    after
      state = Process.delete(progress_key(token))
      for {monitor, _identity} <- state.monitors, do: Process.demonitor(monitor, [:flush])
    end
  end

  defp hold_cleanup(%{token: token, maintenance: maintenance}) do
    state = progress(token)
    actor = state.actor
    parent_arm = state.checkpoints[{:parent, :before_arm}]
    child_arm = state.checkpoints[{:child, :before_arm}]
    parent_resources = state.checkpoints[{:parent, :ready}]
    child_resources = state.checkpoints[{:child, :ready}]
    snapshots = state.checkpoints[:nested_ready]

    same_unregistered_caller? =
      parent_arm.caller == actor and child_arm.caller == actor and
        is_nil(parent_arm.on_exit) and is_nil(child_arm.on_exit)

    assert same_unregistered_caller?, "both owners must monitor the same non-ExUnit actor"

    distinct_destinations? =
      snapshots.parent_destination.database == parent_resources.names.database and
        snapshots.child_destination.database == child_resources.names.database and
        snapshots.parent_destination.object_root ==
          Path.join(parent_resources.names.storage_root, "objects") and
        snapshots.child_destination.object_root ==
          Path.join(child_resources.names.storage_root, "objects") and
        parent_resources.names.database != child_resources.names.database and
        parent_resources.names.storage_root != child_resources.names.storage_root

    assert distinct_destinations?, "nested fixtures must acquire distinct actual resources"

    child_repos_bound? =
      Enum.all?(@repos, fn repo ->
        pid = child_resources.repos[repo]

        is_pid(pid) and Process.whereis(repo) == pid and Process.alive?(pid) and
          current_database(repo) == child_resources.names.database
      end)

    assert child_repos_bound?, "child Repos must use the actual child database"
    send(actor, {token, :exit})
    join_process(token, :actor, :nested_fixture_caller_exit)
    parent_gate = receive_checkpoint(token, {:parent, :cleanup_gate})
    child_drop = receive_checkpoint(token, {:child, :before_database_drop})

    exact_gates? =
      parent_gate.owner == parent_arm.owner and child_drop.owner == child_arm.owner and
        child_drop.names == child_resources.names

    assert exact_gates?, "cleanup barriers must belong to the acquired owners"

    child_held? =
      Process.alive?(child_arm.owner) and Process.alive?(child_drop.maintenance) and
        database_exists?(maintenance, child_resources.names.database) == true and
        File.dir?(child_resources.names.storage_root)

    assert child_held?, "child must remain held at its actual native pre-DROP boundary"
    assert_parent_intact(maintenance, parent_resources, parent_arm.owner)
    child_configs_intact? = application_configs() == snapshots.child_configs
    assert child_configs_intact?, "held child configuration must not rewind unexpectedly"
    parent_gate
  end

  defp ordered_teardown(%{token: token} = scenario) do
    send(progress(token).actor, {token, :exit})
    actor_join = capture(fn -> join_process(token, :actor) end)

    child_cleanup =
      capture(fn ->
        release_owner(token, :child)
        join_native_cleanup(token, :child)

        state = progress(token)

        if not MapSet.member?(state.released, :parent) and
             Map.has_key?(state.checkpoints, :nested_ready) do
          restored? = application_configs() == state.checkpoints[:nested_ready].parent_configs

          assert restored?,
                 "whole child native cleanup must restore the parked parent configuration"

          assert_parent_intact(
            scenario.maintenance,
            state.checkpoints[{:parent, :ready}],
            state.owners.parent
          )
        end
      end)

    # A failed observation does not settle a native lifetime. Keep the parent
    # held unless the exact child's whole-MTE completion was positively recorded.
    unless child_native_completed?(progress(token)) do
      replay(actor_join)
      replay(child_cleanup)
      flunk("parent release requires exact child whole native cleanup confirmation")
    end

    parent_cleanup =
      capture(fn ->
        release_owner(token, :parent)
        join_native_cleanup(token, :parent)
      end)

    child_join = capture(fn -> join_process(token, :child, :normal) end)
    parent_join = capture(fn -> join_process(token, :parent, :normal) end)

    for outcome <- [actor_join, child_cleanup, parent_cleanup, child_join, parent_join],
        do: replay(outcome)

    unless progress(token).baseline_verified? do
      resources =
        for role <- [:parent, :child],
            resources = progress(token).checkpoints[{role, :ready}],
            not is_nil(resources),
            do: resources

      assert_cleanup(scenario.maintenance, resources, scenario.baseline)
      update_progress(token, &%{&1 | baseline_verified?: true})
    end

    :ok
  end

  defp nested_actor(controller, token) do
    controller_monitor = Process.monitor(controller)
    caller = self()

    {parent_owner, parent_destination} =
      ResourceOwner.with_checkpoint(parent_checkpoint(controller, caller, token), fn ->
        ResourceOwner.open(migration_pool_size: 2)
      end)

    parent_resources =
      receive do
        {^token, :parent_acquired, resources} -> resources
      after
        30_000 -> exit(:nested_parent_ready_not_observed)
      end

    parent_configs = application_configs()
    park_repos(parent_resources)

    {_child_owner, child_destination} =
      ResourceOwner.with_checkpoint(child_checkpoint(controller, token, parent_owner), fn ->
        ResourceOwner.open_child(parent_owner, migration_pool_size: 2)
      end)

    send(
      controller,
      {token, :nested_ready,
       %{
         parent_destination: parent_destination,
         child_destination: child_destination,
         parent_configs: parent_configs,
         child_configs: application_configs()
       }}
    )

    try do
      receive do
        {^token, :exit} ->
          exit(:nested_fixture_caller_exit)

        {:DOWN, ^controller_monitor, :process, ^controller, _reason} ->
          exit(:nested_fixture_controller_down)
      end
    after
      Process.demonitor(controller_monitor, [:flush])
    end
  end

  defp parent_checkpoint(controller, caller, token) do
    first_gate = {__MODULE__, token, :parent_gate}

    fn
      :before_arm, resources ->
        send(controller, {token, {:parent, :before_arm}, resources})

      :ready, resources ->
        send(controller, {token, {:parent, :ready}, resources})
        send(caller, {token, :parent_acquired, resources})

      stage, resources when stage in [:waiting_for_child_cleanup, :owner_cleanup_begin] ->
        if stage == :owner_cleanup_begin,
          do: send(controller, {token, {:parent, :owner_cleanup_begin}, resources})

        unless Process.get(first_gate, false) do
          Process.put(first_gate, true)
          parent_barrier(controller, caller, token, Map.put(resources, :stage, stage))
        end

      :owner_cleanup_completed, resources ->
        send(controller, {token, {:parent, :owner_cleanup_completed}, resources})

      :before_database_drop, resources ->
        send(controller, {token, {:parent, :before_database_drop}, resources})

      _stage, _resources ->
        :ok
    end
  end

  defp child_checkpoint(controller, token, parent_owner) do
    fn
      :before_arm, resources ->
        send(parent_owner, {token, :child_owner, resources.owner, resources.caller})
        send(controller, {token, {:child, :before_arm}, resources})

      :ready, resources ->
        send(controller, {token, {:child, :ready}, resources})

      :before_database_drop, resources ->
        barrier(controller, token, {:child, :before_database_drop}, resources)

      :owner_cleanup_completed, resources ->
        send(controller, {token, {:child, :owner_cleanup_completed}, resources})
        send(parent_owner, {token, :child_native_completed, self()})

      _stage, _resources ->
        :ok
    end
  end

  # Keep the held test gate behind actual child MTE completion even when its
  # controller dies; this private observation does not alter helper admission.
  defp parent_barrier(controller, caller, token, resources) do
    monitor = Process.monitor(controller)
    send(controller, {token, {:parent, :cleanup_gate}, resources})

    try do
      await_parent_release(controller, caller, monitor, token, %{
        child: nil,
        child_monitor: nil,
        child_completed?: false,
        continue_requested?: false,
        controller_down?: false
      })
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp await_parent_release(_controller, _caller, _monitor, _token, %{
         child_completed?: true,
         continue_requested?: true
       }),
       do: :ok

  defp await_parent_release(_controller, _caller, _monitor, _token, %{
         child_completed?: true,
         controller_down?: true
       }),
       do: :ok

  defp await_parent_release(controller, caller, monitor, token, state) do
    receive do
      {^token, :child_owner, child, ^caller} when is_pid(child) and is_nil(state.child) ->
        child_monitor = Process.monitor(child)

        try do
          await_parent_release(controller, caller, monitor, token, %{
            state
            | child: child,
              child_monitor: child_monitor
          })
        after
          Process.demonitor(child_monitor, [:flush])
        end

      {^token, :child_native_completed, child} when is_pid(child) and child == state.child ->
        await_parent_release(controller, caller, monitor, token, %{state | child_completed?: true})

      {^token, :continue} ->
        await_parent_release(controller, caller, monitor, token, %{
          state
          | continue_requested?: true
        })

      {^token, :parent_gate_state, from, ref} when from == controller ->
        send(
          controller,
          {token, :parent_gate_state, ref,
           %{
             owner: self(),
             child: state.child,
             child_completed?: state.child_completed?,
             continue_requested?: state.continue_requested?
           }}
        )

        await_parent_release(controller, caller, monitor, token, state)

      {:DOWN, ^monitor, :process, ^controller, _reason} ->
        await_parent_release(controller, caller, monitor, token, %{state | controller_down?: true})

      {:DOWN, child_monitor, :process, child, _reason}
      when child_monitor == state.child_monitor and child == state.child ->
        unless state.child_completed? do
          send(
            controller,
            {token, {:parent, :unconfirmed_child_cleanup},
             %{
               owner: self(),
               child: child
             }}
          )
        end

        # A peer DOWN is failure evidence, never whole native completion. If the
        # controller also dies, remain fail-closed rather than restoring early.
        await_parent_release(controller, caller, monitor, token, state)
    end
  end

  defp parent_gate_state(token, parent_owner) do
    ref = make_ref()
    send(parent_owner, {token, :parent_gate_state, self(), ref})

    receive do
      {^token, :parent_gate_state, ^ref, state} -> state
    after
      30_000 -> flunk("exact parent native gate state was not observed")
    end
  end

  defp barrier(controller, token, stage, resources) do
    monitor = Process.monitor(controller)
    send(controller, {token, stage, resources})

    try do
      receive do
        {^token, :continue} -> :ok
        {:DOWN, ^monitor, :process, ^controller, _reason} -> :ok
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp park_repos(resources) do
    for repo <- Enum.reverse(@repos) do
      pid = Map.fetch!(resources.repos, repo)

      unless Process.whereis(repo) == pid and Process.alive?(pid),
        do: raise("parked parent repository identity changed")

      Supervisor.stop(pid)
    end
  end

  # Plain receives keep private checkpoint/configuration maps out of ExUnit's
  # automatic mailbox and failed-pattern diagnostics.
  defp receive_checkpoint(token, stage) do
    await_checkpoint(token, stage, System.monotonic_time(:millisecond) + 30_000)
  end

  defp await_checkpoint(token, stage, deadline) do
    state = progress(token)

    case Map.fetch(state.checkpoints, stage) do
      {:ok, resources} ->
        resources

      :error ->
        case stage do
          {:child, :owner_cleanup_completed} ->
            confirmed? =
              not Map.has_key?(state.downs, :child) and
                not Map.has_key?(state.checkpoints, {:parent, :unconfirmed_child_cleanup})

            assert confirmed?, "child terminated without whole native cleanup confirmation"

          {role, :owner_cleanup_completed} ->
            confirmed? = not Map.has_key?(state.downs, role)
            assert confirmed?, "nested owner ended without whole native cleanup confirmation"

          _ ->
            :ok
        end

        receive_progress(token, max(deadline - System.monotonic_time(:millisecond), 0))
        await_checkpoint(token, stage, deadline)
    end
  end

  defp receive_progress(token, timeout) do
    monitors = progress(token).monitors

    receive do
      {^token, stage, resources} ->
        record_checkpoint(token, stage, resources)

      {:DOWN, monitor, :process, pid, reason} when is_map_key(monitors, monitor) ->
        {role, ^pid} = Map.fetch!(monitors, monitor)
        update_progress(token, &%{&1 | downs: Map.put(&1.downs, role, reason)})
    after
      timeout -> flunk("nested lifecycle progress was not observed")
    end
  end

  defp record_checkpoint(token, stage, resources) do
    update_progress(token, fn state ->
      state =
        case stage do
          {role, :before_arm} when role in [:parent, :child] ->
            owner = resources.owner
            monitor = Process.monitor(owner)

            %{
              state
              | owners: Map.put(state.owners, role, owner),
                monitors: Map.put(state.monitors, monitor, {role, owner})
            }

          _ ->
            state
        end

      %{
        state
        | checkpoints: Map.put(state.checkpoints, stage, resources),
          events: [stage | state.events]
      }
    end)
  end

  defp release_owner(token, role) do
    state = progress(token)

    if Map.has_key?(state.owners, role) and not MapSet.member?(state.released, role) do
      if role == :parent do
        confirmed? = child_native_completed?(state)
        assert confirmed?, "parent release requires exact child whole native cleanup confirmation"
      end

      update_progress(
        token,
        &%{&1 | released: MapSet.put(&1.released, role), events: [{role, :released} | &1.events]}
      )

      send(state.owners[role], {token, :continue})
    end
  end

  defp child_native_completed?(state) do
    case Map.fetch(state.owners, :child) do
      {:ok, child} ->
        match?(%{owner: ^child}, Map.get(state.checkpoints, {:child, :owner_cleanup_completed}))

      :error ->
        false
    end
  end

  defp join_native_cleanup(token, role) do
    if Map.has_key?(progress(token).owners, role),
      do: receive_checkpoint(token, {role, :owner_cleanup_completed})
  end

  defp join_process(token, role, expected_reason \\ nil) do
    if role == :actor or Map.has_key?(progress(token).owners, role) do
      reason = await_down(token, role, System.monotonic_time(:millisecond) + 15_000)
      expected? = is_nil(expected_reason) or reason == expected_reason
      assert expected?, "nested fixture process did not terminate with the expected outcome"
    end
  end

  defp await_down(token, role, deadline) do
    case Map.fetch(progress(token).downs, role) do
      {:ok, reason} ->
        reason

      :error ->
        receive_progress(token, max(deadline - System.monotonic_time(:millisecond), 0))
        await_down(token, role, deadline)
    end
  end

  defp before?(events, first, second) do
    first_index = Enum.find_index(events, &(&1 == first))
    second_index = Enum.find_index(events, &(&1 == second))
    is_integer(first_index) and is_integer(second_index) and first_index < second_index
  end

  defp assert_teardown(result) do
    clean? = teardown_complete?(result)
    assert clean?, "ordered nested fixture teardown must complete and verify its full baseline"
  end

  defp finish_scenario(result) do
    if teardown_complete?(result) do
      replay(result.outcome)
    else
      case result.outcome do
        {:raised, kind, reason, stack} ->
          cleanup_error = %ExUnit.AssertionError{
            message: "ordered nested fixture teardown must complete and verify its full baseline"
          }

          raise ExUnit.MultiError,
            errors: [{kind, reason, stack}, {:error, cleanup_error, []}]

        {:returned, _value} ->
          assert_teardown(result)
      end
    end
  end

  defp teardown_complete?(result),
    do: match?({:returned, :ok}, result.cleanup) and result.progress.baseline_verified?

  defp capture(fun) do
    try do
      {:returned, fun.()}
    catch
      kind, reason -> {:raised, kind, reason, __STACKTRACE__}
    end
  end

  defp replay({:returned, value}), do: value
  defp replay({:raised, kind, reason, stack}), do: :erlang.raise(kind, reason, stack)

  defp progress_key(token), do: {__MODULE__, token, :progress}
  defp progress(token), do: Process.get(progress_key(token))

  defp update_progress(token, fun) do
    Process.put(progress_key(token), fun.(progress(token)))
  end

  defp assert_parent_intact(maintenance, resources, owner) do
    intact? =
      Process.alive?(owner) and database_exists?(maintenance, resources.names.database) == true and
        File.dir?(resources.names.storage_root) and
        Enum.all?(resources.owned_repos, fn {_repo, pid} -> not Process.alive?(pid) end)

    assert intact?, "parked parent resources must remain intact before its native cleanup"
  end

  defp assert_cleanup(maintenance, resources, baseline) do
    configs_restored? = application_configs() == baseline.configs
    compiler_restored? = Code.compiler_options() == baseline.compiler_options
    runtime_restored? = runtime_started?() == baseline.runtime_started?
    assert configs_restored?, "nested cleanup must restore the complete application baseline"
    assert compiler_restored?, "nested cleanup must restore the complete compiler baseline"
    assert runtime_restored?, "nested cleanup must restore the Runtime started baseline"

    for acquired <- resources do
      database_removed? = database_exists?(maintenance, acquired.names.database) == false
      root_removed? = not File.exists?(acquired.names.storage_root)

      acquired_pids_dead? =
        not Process.alive?(acquired.maintenance) and
          Enum.all?(acquired.owned_repos, fn {_repo, pid} -> not Process.alive?(pid) end)

      assert database_removed?, "nested cleanup must remove each actual owned database"
      assert root_removed?, "nested cleanup must remove each actual owned root"
      assert acquired_pids_dead?, "nested cleanup must stop every exact acquired PID"
    end

    for {repo, previous_pid} <- baseline.repos do
      restored? =
        case {previous_pid, Process.whereis(repo)} do
          {nil, nil} ->
            true

          {previous, current} when is_pid(previous) and is_pid(current) ->
            Process.alive?(current) and current_database(repo) == baseline.repo_databases[repo]

          _ ->
            false
        end

      assert restored?, "restored baseline Repo must retain its original database binding"
    end
  end

  defp baseline do
    %{
      configs: application_configs(),
      compiler_options: Code.compiler_options(),
      repos: Map.new(@repos, &{&1, Process.whereis(&1)}),
      repo_databases:
        Map.new(
          for repo <- @repos, is_pid(Process.whereis(repo)), do: {repo, current_database(repo)}
        ),
      runtime_started?: runtime_started?()
    }
  end

  defp maintenance do
    options =
      MigrationRepo.config() |> Keyword.drop([:url, :name]) |> Keyword.put(:database, "postgres")

    start_supervised!({Postgrex, options})
  end

  defp current_database(repo) do
    %{rows: [[database]]} =
      Ecto.Adapters.SQL.query!(repo, "SELECT current_database()", [], log: false, timeout: 1_000)

    database
  end

  defp database_exists?(connection, database) do
    case Postgrex.query(
           connection,
           "SELECT EXISTS(SELECT 1 FROM pg_catalog.pg_database WHERE datname=$1)",
           [database],
           timeout: 1_000
         ) do
      {:ok, %{rows: [[exists?]]}} -> exists?
      {:error, _reason} -> :observation_failed
    end
  end

  defp application_configs do
    Map.new(@apps, &{&1, Map.new(Application.get_all_env(&1))})
  end

  defp runtime_started? do
    Enum.any?(Application.started_applications(), &(elem(&1, 0) == :singularity_runtime))
  end
end
