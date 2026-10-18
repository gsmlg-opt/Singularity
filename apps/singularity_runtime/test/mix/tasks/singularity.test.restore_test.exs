defmodule Mix.Tasks.Singularity.Test.RestoreTest do
  use ExUnit.Case, async: false

  @oracle :"Elixir.Singularity.Runtime.KnowledgeRestoreOracle"
  @task_path Path.expand("../../../lib/mix/tasks/singularity.test.restore.ex", __DIR__)

  test "the test-only knowledge restore oracle exports its required entry" do
    assert Code.ensure_loaded?(@oracle), "knowledge restore oracle must be available in test"

    assert function_exported?(@oracle, :run!, 0),
           "knowledge restore oracle must export run!/0"
  end

  test "the sole restore task enters the oracle dynamically after complete legacy cleanup" do
    task = @task_path |> File.read!() |> parse!()

    run_bodies =
      case task do
        {:defmodule, [],
         [{:__aliases__, [], [:Mix, :Tasks, :Singularity, :Test, :Restore]}, [do: body]]} ->
          for {:def, [], [{:run, [], [[]]}, [do: run_body]]} <- expressions(body),
              do: expressions(run_body)

        _other ->
          []
      end

    require_contract!(match?([_body], run_bodies), "restore task must define exactly one run([])")
    [body] = run_bodies

    cleanup =
      parse!("""
      cleanup!(source_names, destination_names, v1_destination_names, bundle_path, previous_env)
      """)

    legacy_positions =
      body
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {{:try, [], [clauses]}, index} ->
          if Keyword.get(clauses, :after) == cleanup, do: [index], else: []

        _other ->
          []
      end)

    require_contract!(
      match?([_index], legacy_positions),
      "restore task must retain one top-level legacy try/after cleanup!/5"
    )

    [legacy_position] = legacy_positions

    require_contract!(
      {:assert_test_environment!, [], []} in Enum.take(body, legacy_position),
      "restore task must require its test environment before legacy work"
    )

    expected_entry =
      parse!("""
      oracle = :"Elixir.Singularity.Runtime.KnowledgeRestoreOracle"
      unless Code.ensure_loaded?(oracle) and function_exported?(oracle, :run!, 0) do
        Mix.raise("knowledge restore oracle is unavailable in the required test environment")
      end
      :ok = apply(oracle, :run!, [])
      """)
      |> expressions()

    require_contract!(
      Enum.drop(body, legacy_position + 1) == expected_entry,
      "restore task must end with the guarded dynamic oracle entry after legacy cleanup"
    )

    {_task, counts} =
      Macro.prewalk(task, %{oracle_atoms: 0, entries: 0, forbidden: false}, fn node, counts ->
        counts =
          case node do
            @oracle ->
              Map.update!(counts, :oracle_atoms, &(&1 + 1))

            {:apply, [], [{:oracle, [], nil}, :run!, []]} ->
              Map.update!(counts, :entries, &(&1 + 1))

            _other ->
              counts
          end

        {node, %{counts | forbidden: counts.forbidden or forbidden_entry?(node)}}
      end)

    require_contract!(
      counts.oracle_atoms == 1 and counts.entries == 1,
      "restore task must contain exactly one knowledge oracle dynamic entry"
    )

    require_contract!(
      not counts.forbidden,
      "restore task must not statically reference test support or execute ExUnit files"
    )
  end

  defp parse!(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        Macro.prewalk(ast, fn
          {form, metadata, arguments} when is_list(metadata) -> {form, [], arguments}
          node -> node
        end)

      {:error, _details} ->
        flunk("restore task contract source must parse")
    end
  end

  defp expressions({:__block__, [], expressions}), do: expressions
  defp expressions(expression), do: [expression]

  defp forbidden_entry?({:__aliases__, [], parts}) do
    Enum.any?(parts, fn part ->
      part in [
        :KnowledgeRestoreOracle,
        :KnowledgeBackupRestoreFixture,
        :KnowledgeCanonicalOracle,
        :KnowledgeBackupFixtures,
        :KnowledgeFixtureResourceOwner,
        :NativeAssetFixture
      ]
    end)
  end

  defp forbidden_entry?({{:., [], [{:__aliases__, [], [:Code]}, function]}, [], _arguments})
       when function in [:require_file, :compile_file, :eval_file, :eval_string],
       do: true

  defp forbidden_entry?(
         {{:., [], [{:__aliases__, [], [:ExUnit | _parts]}, :run]}, [], _arguments}
       ),
       do: true

  defp forbidden_entry?({{:., [], [{:__aliases__, [], [:Mix, :Task]}, :run]}, [], ["test" | _]}),
    do: true

  defp forbidden_entry?({{:., [], [{:__aliases__, [], [:Mix, :Tasks, :Test]}, :run]}, [], _}),
    do: true

  defp forbidden_entry?(_node), do: false

  defp require_contract!(condition, message), do: assert(condition, message)
  # BEGIN internal saga12 PostgreSQL transport contracts

  @transport_repo_roles [
    {Singularity.Storage.MigrationRepo, "singularity_migration"},
    {Singularity.Storage.RequestRepo, "singularity_web"},
    {Singularity.Storage.PreAuthRepo, "singularity_pre_auth"},
    {Singularity.Storage.DispatcherRepo, "singularity_dispatcher"},
    {Singularity.Storage.WorkerRepo, "singularity_worker"}
  ]
  @transport_socket "/tmp/singularity-transport-contract-socket"
  @transport_port 55432

  test "PostgreSQL transport materializes five roles and restores controlled options on return" do
    assert_transport_entry!()

    with_controlled_transport_environment(fn ->
      assert {:transport_callback, :returned} =
               apply(@oracle, :with_postgres_transport!, [
                 fn ->
                   assert_materialized_transport!()
                   {:transport_callback, :returned}
                 end
               ])

      assert_controlled_transport_restored!()
    end)
  end

  test "PostgreSQL transport restores controlled options and absence when its callback raises" do
    assert_transport_entry!()

    with_controlled_transport_environment(fn ->
      assert_raise RuntimeError, "transport callback contract failure", fn ->
        apply(@oracle, :with_postgres_transport!, [
          fn ->
            assert_materialized_transport!()
            raise "transport callback contract failure"
          end
        ])
      end

      assert_controlled_transport_restored!()
    end)
  end

  test "PostgreSQL transport rejects invalid ports before callback or configuration mutation" do
    assert_transport_entry!()

    with_controlled_transport_environment(fn ->
      for invalid_port <- ["0", "65536", "abc", "5432junk"] do
        System.put_env("PGPORT", invalid_port)

        assert_raise ArgumentError, "PGPORT must be a valid PostgreSQL port", fn ->
          apply(@oracle, :with_postgres_transport!, [
            fn ->
              send(self(), :transport_contract_callback_called)
              :unexpected_callback
            end
          ])
        end

        refute_received :transport_contract_callback_called
        assert_controlled_transport_restored!()
      end
    end)
  end

  defp assert_transport_entry! do
    require_contract!(
      Code.ensure_loaded?(@oracle) and function_exported?(@oracle, :with_postgres_transport!, 1),
      "knowledge restore oracle must export with_postgres_transport!/1"
    )
  end

  defp with_controlled_transport_environment(callback) do
    original_repositories =
      Enum.map(@transport_repo_roles, fn {repo, _role} ->
        {repo, Application.fetch_env(:singularity_storage, repo)}
      end)

    original_transport =
      Enum.map(["PGHOST", "PGPORT"], fn key -> {key, System.fetch_env(key)} end)

    try do
      for {repo, _role} <- @transport_repo_roles do
        restore_transport_repository(repo, controlled_transport_configuration(repo))
      end

      System.put_env("PGHOST", @transport_socket)
      System.put_env("PGPORT", Integer.to_string(@transport_port))
      callback.()
    after
      Enum.each(original_repositories, fn {repo, value} ->
        restore_transport_repository(repo, value)
      end)

      Enum.each(original_transport, fn
        {key, {:ok, value}} -> System.put_env(key, value)
        {key, :error} -> System.delete_env(key)
      end)
    end
  end

  defp controlled_transport_configuration(Singularity.Storage.WorkerRepo), do: :error

  defp controlled_transport_configuration(_repo) do
    {:ok,
     [
       url: "ecto://transport.invalid/controlled",
       hostname: "transport.invalid",
       socket_dir: "/tmp/singularity-stale-contract-socket",
       port: 1,
       username: "controlled_stale_role",
       database: "controlled_transport_database",
       pool_size: 3,
       telemetry_prefix: [:controlled, :transport],
       show_sensitive_data_on_connection_error: false
     ]}
  end

  defp assert_materialized_transport! do
    for {repo, role} <- @transport_repo_roles do
      controlled =
        case controlled_transport_configuration(repo) do
          {:ok, options} -> options
          :error -> []
        end

      expected =
        controlled
        |> Keyword.drop([:url, :hostname, :socket_dir, :port, :username])
        |> Keyword.merge(
          url: nil,
          socket_dir: @transport_socket,
          port: @transport_port,
          username: role
        )
        |> Map.new()

      assert {:ok, actual} = Application.fetch_env(:singularity_storage, repo)
      assert Map.new(actual) == expected
      refute Keyword.has_key?(actual, :hostname)
    end
  end

  defp assert_controlled_transport_restored! do
    for {repo, _role} <- @transport_repo_roles do
      assert Application.fetch_env(:singularity_storage, repo) ==
               controlled_transport_configuration(repo)
    end
  end

  defp restore_transport_repository(repo, {:ok, options}),
    do: Application.put_env(:singularity_storage, repo, options)

  defp restore_transport_repository(repo, :error),
    do: Application.delete_env(:singularity_storage, repo)

  # END internal saga12 PostgreSQL transport contracts
end
