defmodule Singularity.Runtime.KnowledgeUpgradePopulationTest do
  use ExUnit.Case, async: false

  alias Singularity.Runtime.{Api, NativeAssetFixture}
  alias Singularity.Runtime.KnowledgeExportLiveFixture, as: Live

  @moduletag :integration

  test "existing native A population restores authority and retains the original installation" do
    # A missing-interface RED must not Inspect the private native argument map.
    assert Code.ensure_loaded?(Live)

    assert function_exported?(Live, :with_existing_runtime, 2),
           "existing-runtime population interface missing"

    NativeAssetFixture.with_fixture(fn native ->
      witness = NativeAssetFixture.upload!(native, "text/plain", ["preexisting original\n"])
      NativeAssetFixture.verify_and_finalize!()
      before = installation(native)
      permissions = authority()
      files = retained_files(native.destination.object_root)
      row = asset_row(witness.asset_id)

      population =
        apply(Live, :with_existing_runtime, [
          native,
          fn fixture ->
            assert fixture.owner == native.owner
            assert fixture.infrastructure == native.infrastructure
            assert fixture.repositories == native.repositories
            fixture = Live.publish_sources!(fixture)
            fixture = Live.build_graph!(fixture)
            Map.take(fixture, [:inputs, :sources, :graph])
          end
        ])

      assert Map.keys(population) |> Enum.sort() == [:graph, :inputs, :sources]
      assert map_size(population.sources) == 4
      assert population.graph.second_pdf.state == :ready
      assert installation(native) == before
      assert authority() == permissions
      assert asset_row(witness.asset_id) == row

      current_files = retained_files(native.destination.object_root)

      assert Enum.all?(files, fn {path, identity} ->
               Map.get(current_files, path) == identity
             end)

      assert {:ok, summary} = Api.asset_summary(native.session, witness.asset_id)
      assert summary.state == :ready
      assert Process.alive?(native.owner)
      assert Process.alive?(native.infrastructure)
    end)
  end

  defp installation(native) do
    root = File.lstat!(native.destination.object_root)
    assert root.type == :directory

    assert %{rows: [[oid]]} =
             NativeAssetFixture.observe!(
               "SELECT oid FROM pg_catalog.pg_database WHERE datname=current_database()"
             )

    %{
      owner: native.owner,
      infrastructure: native.infrastructure,
      children: Supervisor.which_children(native.infrastructure) |> Enum.sort(),
      repositories: NativeAssetFixture.repo_identities(),
      database_oid: oid,
      root: {root.major_device, root.minor_device, root.inode},
      environments:
        Map.new([:singularity_storage, :singularity_runtime], fn app ->
          {app, Map.new(Application.get_all_env(app))}
        end)
    }
  end

  defp authority do
    # Independent catalog observations, not the constructor's own cleanup receipt.
    relation_acls =
      NativeAssetFixture.observe!("""
      SELECT n.nspname,c.relname,c.relowner,c.relacl::text
      FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname NOT LIKE 'pg_%' AND n.nspname <> 'information_schema'
      ORDER BY n.nspname,c.relname
      """).rows

    function_acls =
      NativeAssetFixture.observe!("""
      SELECT n.nspname,p.oid::regprocedure::text,p.proowner,p.proacl::text
      FROM pg_catalog.pg_proc p
      JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname NOT LIKE 'pg_%' AND n.nspname <> 'information_schema'
      ORDER BY n.nspname,p.oid
      """).rows

    effective =
      NativeAssetFixture.observe!("""
      SELECT r.rolname,n.nspname,c.relname,v.privilege,
             pg_catalog.has_table_privilege(r.rolname,c.oid,v.privilege)
      FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
      CROSS JOIN pg_catalog.pg_roles r
      CROSS JOIN (VALUES ('SELECT'),('INSERT'),('UPDATE'),('DELETE'),('TRUNCATE'),
                         ('REFERENCES'),('TRIGGER')) v(privilege)
      WHERE n.nspname NOT LIKE 'pg_%' AND n.nspname <> 'information_schema'
        AND c.relkind IN ('r','p','v','m','f')
        AND r.rolname IN ('singularity_web','singularity_worker')
      ORDER BY r.rolname,n.nspname,c.relname,v.privilege
      """).rows

    roles =
      NativeAssetFixture.observe!("""
      SELECT (to_jsonb(r)-'rolpassword')::text FROM pg_catalog.pg_roles r
      WHERE rolname IN ('singularity_web','singularity_worker') ORDER BY rolname
      """).rows

    memberships =
      NativeAssetFixture.observe!(
        "SELECT to_jsonb(m)::text FROM pg_catalog.pg_auth_members m ORDER BY roleid,member,grantor"
      ).rows

    %{
      relations: relation_acls,
      functions: function_acls,
      effective: effective,
      roles: roles,
      memberships: memberships
    }
  end

  defp asset_row(asset_id) do
    %{rows: [[row]]} =
      NativeAssetFixture.observe!(
        "SELECT to_jsonb(asset)::text FROM content.assets asset WHERE id=$1",
        [Ecto.UUID.dump!(asset_id)]
      )

    # An assertion failure must not Inspect the private original row.
    :crypto.hash(:sha256, row)
  end

  defp retained_files(root, relative \\ "", found \\ %{}) do
    root
    |> Path.join(relative)
    |> File.ls!()
    |> Enum.reduce(found, fn name, acc ->
      path = Path.join(relative, name)
      absolute = Path.join(root, path)

      case File.lstat!(absolute) do
        %{type: :directory} ->
          retained_files(root, path, acc)

        %{type: :regular} = stat ->
          Map.put(acc, path, {
            stat.major_device,
            stat.minor_device,
            stat.inode,
            stat.mode,
            :crypto.hash(:sha256, File.read!(absolute))
          })
      end
    end)
  end

  test "existing-runtime identity validation closes its request scope on one pinned connection" do
    alias Singularity.Storage.{RequestRepo, SafeSQL, ScopedRepo}
    alias Singularity.Storage.Postgres.IdentityRepository

    NativeAssetFixture.with_fixture(fn native ->
      RequestRepo.checkout(fn ->
        %{rows: [[backend]]} =
          SafeSQL.query!(RequestRepo, "SELECT pg_backend_pid()", [], log: false)

        assert_context_absent = fn ->
          %{rows: [[current, principal, vault]]} =
            SafeSQL.query!(
              RequestRepo,
              "SELECT pg_backend_pid(),current_setting('singularity.principal_id',true),current_setting('singularity.vault_id',true)",
              [],
              log: false
            )

          assert current == backend
          context_absent? = principal in [nil, ""] and vault in [nil, ""]
          assert context_absent?
        end

        assert_context_absent.()

        assert {:ok, nil} =
                 IdentityRepository.load_live_session(RequestRepo, native.session.session_id)

        assert :scoped_positive =
                 ScopedRepo.transact(
                   RequestRepo,
                   Map.take(native.session, [:principal_id, :vault_id]),
                   fn repo ->
                     {:ok, live} =
                       IdentityRepository.load_live_session(repo, native.session.session_id)

                     live_matches? =
                       live.session_id == native.session.session_id and
                         Enum.all?(
                           [:account_id, :credential_id, :principal_id, :vault_id],
                           fn key ->
                             Map.fetch!(live, key) == Map.fetch!(native.credentials.owner, key)
                           end
                         )

                     assert live_matches?
                     :scoped_positive
                   end
                 )

        assert_context_absent.()

        assert :populated =
                 population(native, fn _fixture ->
                   refute RequestRepo.in_transaction?()
                   assert_context_absent.()
                   :populated
                 end)

        assert_context_absent.()
        rejected = put_in(native.credentials.owner.credential_id, Ecto.UUID.generate())

        assert_raise ArgumentError, "existing_runtime_identity", fn ->
          population(rejected, fn _ -> flunk("invalid binding reached population") end)
        end

        assert_context_absent.()

        outcome =
          capture_population(fn ->
            population(native, fn _fixture ->
              refute RequestRepo.in_transaction?()
              assert_context_absent.()
              throw(:scoped_population_probe)
            end)
          end)

        throw_preserved? = match?({:raised, :throw, :scoped_population_probe, [_ | _]}, outcome)
        assert throw_preserved?
        assert_context_absent.()
      end)

      refreshed = NativeAssetFixture.login!(native.credentials)

      assert :fresh_session =
               population(%{native | session: refreshed}, fn _ -> :fresh_session end)
    end)
  end

  # These additional vectors are prospective until the root runs this whole owner.
  for failure <- [:raise, :throw, :partial_grant] do
    test "#{failure} population restores actual grants and removes its exact helper" do
      assert_population_failure(unquote(failure))
    end
  end

  test "invalid identity bindings reject without added authority or helper children" do
    NativeAssetFixture.with_fixture(fn native ->
      {foreign, foreign_monitor} =
        spawn_monitor(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {dead, dead_monitor} = spawn_monitor(fn -> :ok end)

      try do
        assert_receive {:DOWN, ^dead_monitor, :process, ^dead, :normal}, 1_000

        invalid = [
          nil,
          Map.put(native, :owner, foreign),
          Map.put(native, :owner, dead),
          Map.put(native, :infrastructure, foreign),
          Map.put(native, :infrastructure, dead),
          put_in(native.destination.repo, Singularity.Storage.RequestRepo),
          put_in(native.destination.database, "singularity_test_000000000000000000000000"),
          put_in(native.destination.object_root, Path.dirname(native.destination.object_root)),
          put_in(
            native.repositories[Singularity.Storage.RequestRepo],
            {foreign, native.destination.database}
          ),
          put_in(
            native.repositories[Singularity.Storage.MigrationRepo],
            {dead, native.destination.database}
          ),
          put_in(native.credentials.owner.account_id, Ecto.UUID.generate()),
          put_in(native.credentials.owner.credential_id, Ecto.UUID.generate()),
          put_in(native.credentials.owner.principal_id, Ecto.UUID.generate()),
          put_in(native.credentials.owner.vault_id, Ecto.UUID.generate()),
          put_in(native.session.session_id, Ecto.UUID.generate()),
          put_in(native.session.principal_id, Ecto.UUID.generate()),
          put_in(native.session.vault_id, Ecto.UUID.generate()),
          put_in(native.session.principal_authorization_epoch, -1),
          put_in(native.session.vault_authorization_epoch, -1)
        ]

        for rejected <- invalid do
          assert :positive_control = population(native, fn _ -> :positive_control end)
          before = installation(native)
          permissions = authority()
          token = make_ref()
          caller = self()

          assert_raise ArgumentError, "existing_runtime_identity", fn ->
            population(rejected, fn _ -> send(caller, token) end)
          end

          refute_receive ^token, 0
          assert installation(native) == before
          assert authority() == permissions
        end

        for invalid_callback <- [nil, fn -> :invalid end, fn _, _ -> :invalid end] do
          assert_raise ArgumentError, "existing_runtime_identity", fn ->
            apply(Live, :with_existing_runtime, [native, invalid_callback])
          end
        end
      after
        send(foreign, :stop)
        assert_receive {:DOWN, ^foreign_monitor, :process, ^foreign, :normal}, 1_000
      end
    end)
  end

  test "a registered replacement is rejected while the exact original repository stays live" do
    NativeAssetFixture.with_fixture(fn native ->
      assert :positive_control = population(native, fn _ -> :positive_control end)
      before = installation(native)
      permissions = authority()
      repo = Singularity.Storage.RequestRepo
      {original, _database} = Map.fetch!(native.repositories, repo)

      {placeholder, monitor} =
        spawn_monitor(fn ->
          receive do
            :stop -> :ok
          end
        end)

      try do
        assert Process.whereis(repo) == original and Process.alive?(original)
        assert Process.unregister(repo)
        assert Process.register(placeholder, repo)

        assert_raise ArgumentError, "existing_runtime_identity", fn ->
          population(native, fn _ -> flunk("replacement reached population") end)
        end

        assert Process.whereis(repo) == placeholder
        assert Process.alive?(original)
      after
        try do
          registered = Process.whereis(repo)
          assert registered in [placeholder, original, nil]
          assert Process.alive?(original)
          if registered == placeholder, do: assert(Process.unregister(repo))
          if Process.whereis(repo) == nil, do: assert(Process.register(original, repo))
          assert Process.whereis(repo) == original
        after
          send(placeholder, :stop)
          assert_receive {:DOWN, ^monitor, :process, ^placeholder, :normal}, 1_000
        end
      end

      assert installation(native) == before
      assert authority() == permissions
      assert :usable = population(native, fn _ -> :usable end)
    end)
  end

  test "callback primary survives a separate outer cleanup identity failure without disclosure" do
    NativeAssetFixture.with_fixture(fn native ->
      before = installation(native)
      permissions = authority()
      repo = Singularity.Storage.RequestRepo
      {original, _database} = Map.fetch!(native.repositories, repo)
      journal_key = make_ref()

      outcome =
        try do
          capture_population(fn ->
            population(native, fn fixture ->
              Process.put(journal_key, fixture.observer.control)
              assert Process.whereis(repo) == original and Process.alive?(original)
              assert Process.unregister(repo)
              raise "population-private-primary-probe"
            end)
          end)
        after
          assert Process.whereis(repo) == nil and Process.alive?(original)
          assert Process.register(original, repo)
        end

      {error, stack} = population_error!(outcome)

      primary_preserved? =
        match?(
          {:error, %RuntimeError{message: "population-private-primary-probe"}, [_ | _]},
          error.primary
        )

      assert primary_preserved?
      assert :installation_identity in error.cleanup
      assert Exception.message(error) == "existing_runtime_population"
      refute inspect(error) =~ "population-private-primary-probe"
      refute Exception.format(:error, error, stack) =~ "population-private-primary-probe"
      journal = Process.delete(journal_key)
      refute Process.alive?(journal)

      refute Enum.any?(
               Supervisor.which_children(native.infrastructure),
               &(elem(&1, 1) == journal)
             )

      assert installation(native) == before
      assert authority() == permissions
      assert :usable = population(native, fn _ -> :usable end)
    end)
  end

  for terminal <- [:caller_loss, :journal_loss] do
    test "#{terminal} during a real grant requires genuine ResourceOwner final cleanup" do
      assert_native_terminal_cleanup(unquote(terminal))
    end
  end

  defp assert_population_failure(failure) do
    NativeAssetFixture.with_fixture(fn native ->
      before = installation(native)
      permissions = authority()
      journal_key = make_ref()

      outcome =
        capture_population(fn ->
          population(native, fn fixture ->
            journal = fixture.observer.control
            Process.put(journal_key, journal)
            assert Process.alive?(journal)

            assert Enum.count(
                     Supervisor.which_children(native.infrastructure),
                     &(elem(&1, 1) == journal)
                   ) == 1

            controls = %{
              purpose: :import,
              after_grant: fn count ->
                assert count >= 1
                refute authority() == permissions
                if failure == :partial_grant, do: throw(:population_partial_grant)
              end
            }

            fixture.permission_scope.(controls, fn ->
              case failure do
                :raise -> raise "population callback probe"
                :throw -> throw(:population_callback_probe)
                :partial_grant -> flunk("partial GRANT did not interrupt setup")
              end
            end)
          end)
        end)

      expected? =
        case failure do
          :raise ->
            match?(
              {:raised, :error, %RuntimeError{message: "population callback probe"}, [_ | _]},
              outcome
            )

          :throw ->
            match?({:raised, :throw, :population_callback_probe, [_ | _]}, outcome)

          :partial_grant ->
            match?({:raised, :throw, :population_partial_grant, [_ | _]}, outcome)
        end

      assert expected?

      journal = Process.delete(journal_key)
      refute Process.alive?(journal)

      refute Enum.any?(
               Supervisor.which_children(native.infrastructure),
               &(elem(&1, 1) == journal)
             )

      assert installation(native) == before
      assert authority() == permissions
      assert :usable = population(native, fn _ -> :usable end)
    end)
  end

  defp assert_native_terminal_cleanup(terminal) do
    alias Singularity.Storage.MigrationRepo
    alias Singularity.Storage.Backup.KnowledgeFixtureResourceOwner, as: ResourceOwner

    config =
      MigrationRepo.config() |> Keyword.drop([:url, :name]) |> Keyword.put(:database, "postgres")

    connection = start_supervised!({Postgrex, config})

    environments =
      Map.new(
        [:singularity_storage, :singularity_runtime],
        &{&1, Map.new(Application.get_all_env(&1))}
      )

    controller = self()
    token = make_ref()
    owner_key = make_ref()

    {actor, actor_monitor} =
      spawn_monitor(fn ->
        outcome =
          capture_population(fn ->
            checkpoint = fn
              :before_arm, %{owner: owner} ->
                send(controller, {token, :owner, owner})
                :ok

              _, _ ->
                :ok
            end

            ResourceOwner.with_checkpoint(checkpoint, fn ->
              NativeAssetFixture.with_fixture(fn native ->
                result =
                  capture_population(fn ->
                    population(native, fn fixture ->
                      fixture.permission_scope.(
                        %{
                          purpose: :import,
                          after_grant: fn count ->
                            assert count >= 1

                            send(
                              controller,
                              {token, :grant,
                               Map.merge(native, %{journal: fixture.observer.control})}
                            )

                            case terminal do
                              :caller_loss ->
                                receive do
                                  ^token -> :not_sent
                                end

                              :journal_loss ->
                                Agent.stop(fixture.observer.control, :normal)
                                throw(:discarded_inner_probe)
                            end
                          end
                        },
                        fn -> flunk("terminal grant unexpectedly completed") end
                      )
                    end)
                  end)

                if terminal == :journal_loss do
                  {error, _stack} = population_error!(result)
                  assert error.cleanup != []
                  # The unchanged inner try/after can discard its callback throw.
                  # Assert only the actual outer observation; never invent that throw.
                  observed_primary? = match?({:exit, _, _}, error.primary)
                  assert observed_primary?
                  send(controller, {token, :misuse_failed})
                end
              end)
            end)
          end)

        send(controller, {token, :finished, outcome})
      end)

    try do
      owner =
        receive do
          {^token, :owner, owner} -> owner
        after
          30_000 -> flunk("population did not expose its actual owner")
        end

      Process.put(owner_key, owner)

      native =
        receive do
          {^token, :grant, native} -> native
        after
          30_000 -> flunk("population did not reach its actual grant")
        end

      assert native.owner == owner

      pids =
        [native.owner, native.infrastructure, native.journal] ++
          Enum.map(native.repositories, fn {_, {pid, _}} -> pid end)

      monitors = Enum.map(pids, &{&1, Process.monitor(&1)})
      if terminal == :caller_loss, do: Process.exit(actor, :kill)
      reason = await_population_down!(actor, actor_monitor)
      expected_reason? = reason == if(terminal == :caller_loss, do: :killed, else: :normal)
      assert expected_reason?
      for {pid, monitor} <- monitors, do: await_population_down!(pid, monitor)

      if terminal == :journal_loss do
        misuse_failed? =
          receive do
            {^token, :misuse_failed} -> true
          after
            0 -> false
          end

        assert misuse_failed?

        finished? =
          receive do
            {^token, :finished, result} -> match?({:returned, _}, result)
          after
            0 -> false
          end

        assert finished?
      end

      %{rows: [[databases, connections]]} =
        Postgrex.query!(
          connection,
          "SELECT (SELECT count(*) FROM pg_database WHERE datname=$1),(SELECT count(*) FROM pg_stat_activity WHERE datname=$1)",
          [native.destination.database]
        )

      assert databases == 0 and connections == 0
      refute File.exists?(Path.dirname(native.destination.object_root))

      assert Map.new(
               [:singularity_storage, :singularity_runtime],
               &{&1, Map.new(Application.get_all_env(&1))}
             ) == environments

      assert Enum.all?(pids, &(not Process.alive?(&1)))
    after
      # Assertion-failure containment only, never ACL-restoration/acceptance credit.
      # Stop only this exact test-owned actor; A still closes through its owner.
      if Process.alive?(actor), do: Process.exit(actor, :kill)
      stopped = Process.monitor(actor)
      await_population_down!(actor, stopped)
      Process.demonitor(actor_monitor, [:flush])

      owner =
        Process.delete(owner_key) ||
          receive do
            {^token, :owner, owner} -> owner
          after
            0 -> nil
          end

      if is_pid(owner) do
        owner_down = Process.monitor(owner)
        await_population_down!(owner, owner_down)
      end
    end
  end

  defp await_population_down!(pid, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, reason} -> reason
    after
      15_000 -> flunk("exact owned population process did not stop")
    end
  end

  defp population_error!(outcome) do
    case outcome do
      {:raised, :error, %{__struct__: module} = error, stack}
      when module == Live.PopulationError ->
        {error, stack}

      _private_outcome ->
        flunk("population did not preserve a separate cleanup failure")
    end
  end

  defp population(native, callback), do: apply(Live, :with_existing_runtime, [native, callback])

  defp capture_population(callback) do
    try do
      {:returned, callback.()}
    catch
      kind, reason -> {:raised, kind, reason, __STACKTRACE__}
    end
  end
end
