defmodule Singularity.Storage.SearchExtensionBootstrapTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @bootstrap Singularity.Storage.SearchExtensionBootstrap
  @wrapper Path.expand("../../../priv/repo/bootstrap_search_extensions.sh", __DIR__)
  @database "singularity_bootstrap_transport"
  @canary "private-provisioner-password-canary"

  @tag :tmp_dir
  test "wrapper uses an explicit application database and an anonymous credential service", %{
    tmp_dir: tmp_dir
  } do
    assert File.regular?(@wrapper)
    fake_psql!(tmp_dir)
    credentials = "postgresql://admin:#{@canary}@db.example/postgres?sslmode=require"

    {output, status} = wrapper([@database], transport_env(tmp_dir, credentials))
    assert status == 0
    refute output =~ @canary

    arguments = File.read!(Path.join(tmp_dir, "arguments")) |> String.split("\n", trim: true)
    assert ("--dbname=" <> @database) in arguments
    assert "--no-psqlrc" in arguments
    assert "--set=ON_ERROR_STOP=1" in arguments
    assert Enum.any?(arguments, &String.ends_with?(&1, "/bootstrap_search_extensions.sql"))
    refute Enum.join(arguments) =~ @canary
    refute Enum.join(arguments) =~ "postgresql://"
    refute File.read!(Path.join(tmp_dir, "environment")) =~ @canary

    refute File.read!(Path.join(tmp_dir, "environment")) =~
             "SINGULARITY_ROLE_PROVISIONER_DATABASE_URL="

    service = File.read!(Path.join(tmp_dir, "service"))
    assert service =~ "[singularity_role_provisioner]"
    assert service =~ "dbname=postgres"
    assert service =~ "host=db.example"
    assert service =~ "password=" <> @canary
    assert service =~ "sslmode=require"
    assert File.read!(Path.join(tmp_dir, "service_descriptor")) =~ ~r/\Apipe:\[[0-9]+\]\n\z/
  end

  @tag :tmp_dir
  test "large credential services use a pipe rather than a temporary secret file", %{
    tmp_dir: tmp_dir
  } do
    assert File.regular?(@wrapper)
    fake_psql!(tmp_dir)
    password = @canary <> String.duplicate("x", 98_304)

    {output, status} =
      wrapper([@database], transport_env(tmp_dir, "postgresql://admin:#{password}@host/postgres"))

    assert status == 0
    refute output =~ @canary
    assert File.read!(Path.join(tmp_dir, "service")) =~ "password=" <> password
    assert File.read!(Path.join(tmp_dir, "service_descriptor")) =~ ~r/\Apipe:\[[0-9]+\]\n\z/
    refute File.read!(Path.join(tmp_dir, "environment")) =~ @canary
    refute File.read!(Path.join(tmp_dir, "arguments")) =~ @canary
  end

  @tag :tmp_dir
  test "invalid missing or extra database arguments never launch psql", %{tmp_dir: tmp_dir} do
    assert File.regular?(@wrapper)
    fake_psql!(tmp_dir)

    for args <- [
          [],
          [@database, "extra"],
          [""],
          ["postgres"],
          ["template0"],
          ["template1"],
          ["--dbname=postgres"],
          ["postgresql://admin:secret@host/db"],
          ["dbname=postgres user=admin"],
          ["app;DROP DATABASE other"],
          ["app\nother"],
          [String.duplicate("a", 64)]
        ] do
      {_output, status} =
        wrapper(args, transport_env(tmp_dir, "postgresql://admin:secret@host/postgres"))

      refute status == 0
      refute File.exists?(Path.join(tmp_dir, "arguments"))
    end
  end

  @tag :tmp_dir
  test "a failing connection helper cannot fall through to psql", %{tmp_dir: tmp_dir} do
    assert File.regular?(@wrapper)
    fake_psql!(tmp_dir)

    executable!(
      Path.join(tmp_dir, "elixir"),
      "#!/usr/bin/env bash\nprintf '%s' '#{@canary}'\nexit 17\n"
    )

    {output, status} =
      wrapper([@database], transport_env(tmp_dir, "postgresql://admin:secret@host/postgres"))

    refute status == 0
    refute output =~ @canary
    refute File.exists?(Path.join(tmp_dir, "arguments"))
  end

  @tag :tmp_dir
  test "invalid credential helper input fails without psql or credential output", %{
    tmp_dir: tmp_dir
  } do
    assert File.regular?(@wrapper)
    fake_psql!(tmp_dir)

    for credentials <- [
          nil,
          "https://admin:#{@canary}@host/postgres",
          "postgresql://admin:#{@canary}@host/postgres?password=bad%0Asecret"
        ] do
      {output, status} = wrapper([@database], transport_env(tmp_dir, credentials))
      refute status == 0
      refute output =~ @canary
      refute File.exists?(Path.join(tmp_dir, "arguments"))
    end
  end

  @tag :tmp_dir
  test "task adapter validates targets and sanitizes subprocess failures", %{tmp_dir: tmp_dir} do
    assert Code.ensure_loaded?(@bootstrap)

    executable!(
      Path.join(tmp_dir, "psql"),
      "#!/usr/bin/env bash\nprintf '%s' '#{@canary}'\nexit 23\n"
    )

    log =
      capture_log(fn ->
        with_environment(
          transport_env(tmp_dir, "postgresql://admin:#{@canary}@host/postgres"),
          fn ->
            for database <- [
                  nil,
                  :database,
                  "postgres",
                  "template0",
                  "template1",
                  "--flag",
                  "dbname=postgres",
                  String.duplicate("a", 64)
                ] do
              assert_raise ArgumentError,
                           "search extension bootstrap requires an application database name",
                           fn ->
                             apply(@bootstrap, :run!, [database])
                           end
            end

            assert_raise RuntimeError, "search extension bootstrap failed", fn ->
              apply(@bootstrap, :run!, [@database])
            end
          end
        )
      end)

    refute log =~ @canary
  end

  @tag :tmp_dir
  test "task adapter succeeds without persisting an administrator repository configuration", %{
    tmp_dir: tmp_dir
  } do
    assert Code.ensure_loaded?(@bootstrap)
    fake_psql!(tmp_dir)
    configuration = Application.get_all_env(:singularity_storage)

    with_environment(transport_env(tmp_dir, "postgresql://admin:secret@host/postgres"), fn ->
      assert :ok = apply(@bootstrap, :run!, [@database])
    end)

    assert Application.get_all_env(:singularity_storage) |> Enum.sort() ==
             Enum.sort(configuration)

    refute Code.ensure_loaded?(Singularity.Storage.RoleProvisionerRepo)
  end

  defp wrapper(args, env),
    do: System.cmd("bash", [@wrapper | args], env: env, stderr_to_stdout: true)

  defp fake_psql!(tmp_dir) do
    executable!(Path.join(tmp_dir, "psql"), """
    #!/usr/bin/env bash
    set -euo pipefail
    printf '%s\\n' "$@" > "$CAPTURE_DIRECTORY/arguments"
    env > "$CAPTURE_DIRECTORY/environment"
    test -p "$PGSERVICEFILE"
    readlink "$PGSERVICEFILE" > "$CAPTURE_DIRECTORY/service_descriptor"
    cat "$PGSERVICEFILE" > "$CAPTURE_DIRECTORY/service"
    """)
  end

  defp executable!(path, source) do
    File.write!(path, source)
    File.chmod!(path, 0o755)
  end

  defp transport_env(tmp_dir, credentials) do
    [
      {"PATH", tmp_dir <> ":" <> System.fetch_env!("PATH")},
      {"CAPTURE_DIRECTORY", tmp_dir},
      {"SINGULARITY_ROLE_PROVISIONER_DATABASE_URL", credentials}
    ]
  end

  defp with_environment(environment, fun) do
    previous = Enum.map(environment, fn {name, _} -> {name, System.get_env(name)} end)
    Enum.each(environment, &restore_env/1)

    try do
      fun.()
    after
      Enum.each(previous, &restore_env/1)
    end
  end

  defp restore_env({name, nil}), do: System.delete_env(name)
  defp restore_env({name, value}), do: System.put_env(name, value)
end

defmodule Singularity.Storage.SearchExtensionBootstrapIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  alias Singularity.Storage.{MigrationTestEnvironment, TestEnvironment}

  @bootstrap Singularity.Storage.SearchExtensionBootstrap
  @functions ["similarity(text,text)", "similarity_op(text,text)"]
  @runtime_roles ~w(singularity_web singularity_pre_auth singularity_dispatcher singularity_worker)
  @managed_roles ~w(singularity_table_owner singularity_auth_definer singularity_authorization_definer singularity_outbox_definer singularity_migration singularity_web singularity_pre_auth singularity_dispatcher singularity_worker)
  @repos [
    Singularity.Storage.MigrationRepo,
    Singularity.Storage.RequestRepo,
    Singularity.Storage.PreAuthRepo,
    Singularity.Storage.DispatcherRepo,
    Singularity.Storage.WorkerRepo
  ]

  test "fresh application provisioning has exact extension ownership and minimal catalog delegation" do
    bootstrap_module!()

    with_database(fn database, connection ->
      roles = role_snapshot(connection)
      assert :ok = bootstrap!(database)
      assert_extension!(connection)
      assert role_snapshot(connection) == roles

      before = snapshot(connection)
      assert :ok = bootstrap!(database)
      assert snapshot(connection) == before
    end)
  end

  test "compatible final web grants remain unchanged on an administrator rerun" do
    bootstrap_module!()

    with_database(fn database, connection ->
      bootstrap!(database)
      query!(connection, "SET ROLE singularity_table_owner")
      query!(connection, "GRANT USAGE ON SCHEMA search_extensions TO singularity_web")

      query!(
        connection,
        "GRANT EXECUTE ON FUNCTION search_extensions.similarity(text,text), search_extensions.similarity_op(text,text) TO singularity_web"
      )

      query!(connection, "RESET ROLE")

      before = snapshot(connection)
      assert :ok = bootstrap!(database)
      assert snapshot(connection) == before

      with_role(database, "singularity_web", fn web ->
        assert [[true]] ==
                 query!(web, "SELECT search_extensions.similarity('knowledge','knowledge') = 1")

        assert [[true]] ==
                 query!(web, "SELECT 'knowledge' OPERATOR(search_extensions.%) 'knowledge'")
      end)
    end)
  end

  test "stock PUBLIC execution and wrong namespaces are rejected without adopting the extension" do
    bootstrap_module!()

    for namespace <- ["public", "search_extensions"] do
      with_database(fn database, connection ->
        if namespace == "search_extensions",
          do:
            query!(
              connection,
              "CREATE SCHEMA search_extensions AUTHORIZATION singularity_table_owner"
            )

        query!(connection, "SET ROLE singularity_table_owner")
        query!(connection, "CREATE EXTENSION pg_trgm WITH SCHEMA #{namespace} VERSION '1.6'")
        query!(connection, "RESET ROLE")

        before = snapshot(connection)
        assert_bootstrap_failure(database)
        assert snapshot(connection) == before
      end)
    end
  end

  test "wrong schema extension function owners version ACLs and objects fail without changes" do
    bootstrap_module!()

    for alteration <- [
          "ALTER SCHEMA search_extensions OWNER TO CURRENT_USER",
          "UPDATE pg_catalog.pg_extension SET extowner = (SELECT oid FROM pg_roles WHERE rolname = CURRENT_USER) WHERE extname = 'pg_trgm'",
          "UPDATE pg_catalog.pg_extension SET extversion = '1.5' WHERE extname = 'pg_trgm'",
          "ALTER FUNCTION search_extensions.similarity(text,text) OWNER TO singularity_table_owner",
          "GRANT USAGE ON SCHEMA search_extensions TO PUBLIC",
          "GRANT EXECUTE ON FUNCTION search_extensions.similarity(text,text) TO PUBLIC",
          "REVOKE GRANT OPTION FOR EXECUTE ON FUNCTION search_extensions.similarity(text,text) FROM singularity_table_owner",
          "GRANT EXECUTE ON FUNCTION search_extensions.show_trgm(text) TO singularity_table_owner",
          "GRANT EXECUTE ON FUNCTION search_extensions.similarity(text,text) TO singularity_worker",
          "GRANT EXECUTE ON FUNCTION search_extensions.similarity(text,text) TO singularity_web WITH GRANT OPTION",
          "CREATE TABLE search_extensions.unexpected (id integer)",
          "CREATE FUNCTION search_extensions.unexpected() RETURNS integer LANGUAGE SQL AS 'SELECT 1'",
          "ALTER EXTENSION pg_trgm DROP FUNCTION search_extensions.similarity(text,text)"
        ] do
      with_database(fn database, connection ->
        bootstrap!(database)
        query!(connection, alteration)
        before = snapshot(connection)
        assert_bootstrap_failure(database)
        assert snapshot(connection) == before
      end)
    end
  end

  describe "nonfunction member and operator-binding drift" do
    for {name, alteration} <- [
          {"detached similarity operator",
           "ALTER EXTENSION pg_trgm DROP OPERATOR search_extensions.% (text,text)"},
          {"detached gtrgm type", "ALTER EXTENSION pg_trgm DROP TYPE search_extensions.gtrgm"},
          {"detached GIN opclass",
           "ALTER EXTENSION pg_trgm DROP OPERATOR CLASS search_extensions.gin_trgm_ops USING gin"},
          {"detached GIN family",
           "ALTER EXTENSION pg_trgm DROP OPERATOR FAMILY search_extensions.gin_trgm_ops USING gin"},
          {"substituted similarity operator",
           "UPDATE pg_catalog.pg_operator SET oprcode = 'search_extensions.word_similarity_op(text,text)'::regprocedure WHERE oid = 'search_extensions.%(text,text)'::regoperator"}
        ] do
      @member_alteration alteration

      test "#{name} fails unchanged" do
        bootstrap_module!()

        with_database(fn database, connection ->
          bootstrap!(database)
          query!(connection, @member_alteration)
          before = snapshot(connection)
          assert_bootstrap_failure(database)
          assert snapshot(connection) == before
        end)
      end
    end
  end

  test "nonadministrator and missing installation authority fail without partial installation" do
    bootstrap_module!()

    with_database(fn database, connection ->
      before = snapshot(connection)
      with_nonadministrator(fn -> assert_bootstrap_failure(database) end)
      assert snapshot(connection) == before

      query!(connection, "REVOKE CREATE ON DATABASE \"#{database}\" FROM singularity_table_owner")
      before = snapshot(connection)
      assert_bootstrap_failure(database)
      assert snapshot(connection) == before
    end)
  end

  test "an extension member attached outside its controlled namespace is rejected unchanged" do
    bootstrap_module!()

    with_database(fn database, connection ->
      bootstrap!(database)

      query!(
        connection,
        "CREATE FUNCTION public.unexpected_extension_member() RETURNS integer LANGUAGE SQL AS 'SELECT 1'"
      )

      query!(
        connection,
        "ALTER EXTENSION pg_trgm ADD FUNCTION public.unexpected_extension_member()"
      )

      before = snapshot(connection)
      assert_bootstrap_failure(database)
      assert snapshot(connection) == before
    end)
  end

  test "fresh provisioning failure removes only its allocation and leaves outer repos running" do
    bootstrap_module!()
    names = TestEnvironment.allocate!()
    sibling = names.storage_root <> "-sibling"
    File.mkdir_p!(sibling)
    File.write!(Path.join(sibling, "sentinel"), "safe")
    configuration = Application.get_all_env(:singularity_storage)
    running = Enum.map(@repos, &{&1, Process.whereis(&1)})

    try do
      with_nonadministrator(fn ->
        assert_raise RuntimeError, "search extension bootstrap failed", fn ->
          TestEnvironment.create!(names)
        end
      end)

      with_admin("postgres", fn connection ->
        assert [[false]] ==
                 query!(
                   connection,
                   "SELECT EXISTS (SELECT FROM pg_database WHERE datname = $1)",
                   [names.database]
                 )
      end)

      refute File.exists?(names.storage_root)
      assert File.read!(Path.join(sibling, "sentinel")) == "safe"
      assert Enum.sort(Application.get_all_env(:singularity_storage)) == Enum.sort(configuration)
      assert Enum.map(@repos, &{&1, Process.whereis(&1)}) == running
    after
      Enum.each(running, fn {repo, original_pid} ->
        if pid = Process.whereis(repo), do: if(pid != original_pid, do: Supervisor.stop(pid))
      end)

      with_admin(
        "postgres",
        &query!(&1, "DROP DATABASE IF EXISTS \"#{names.database}\" WITH (FORCE)")
      )

      File.rm_rf!(names.storage_root)
      restore_configuration(configuration)

      Enum.each(running, fn {repo, original_pid} ->
        if original_pid && Process.whereis(repo) == nil do
          {:ok, pid} = repo.start_link()
          Process.unlink(pid)
        end
      end)

      File.rm_rf!(sibling)
    end
  end

  test "historical databases provision the extension before the migration ceiling" do
    bootstrap_module!()

    MigrationTestEnvironment.with_database(20_260_901_000_200, fn environment ->
      with_admin(environment.database, &assert_extension!/1)
    end)
  end

  test "historical provisioning failure drops its database and restores the outer fixture" do
    bootstrap_module!()
    configuration = Application.get_all_env(:singularity_storage)
    running = Enum.filter(@repos, &(Process.whereis(&1) != nil))
    runtime_started? = runtime_started?()
    roots = Path.wildcard(Path.join([System.tmp_dir!(), "singularity", "integration", "*"]))
    before_databases = with_admin("postgres", &test_databases/1)

    outer =
      Ecto.Adapters.SQL.query!(Singularity.Storage.RequestRepo, "SELECT current_database()", [],
        log: false
      ).rows

    with_nonadministrator(fn ->
      assert_raise RuntimeError, "search extension bootstrap failed", fn ->
        MigrationTestEnvironment.open!(20_260_901_000_200)
      end
    end)

    assert with_admin("postgres", &test_databases/1) == before_databases

    assert Path.wildcard(Path.join([System.tmp_dir!(), "singularity", "integration", "*"])) ==
             roots

    assert Enum.sort(Application.get_all_env(:singularity_storage)) == Enum.sort(configuration)
    assert Enum.filter(@repos, &(Process.whereis(&1) != nil)) == running
    assert runtime_started?() == runtime_started?

    assert Ecto.Adapters.SQL.query!(
             Singularity.Storage.RequestRepo,
             "SELECT current_database()",
             [],
             log: false
           ).rows == outer
  end

  defp bootstrap_module!, do: assert(Code.ensure_loaded?(@bootstrap))
  defp bootstrap!(database), do: apply(@bootstrap, :run!, [database])

  defp assert_bootstrap_failure(database) do
    assert_raise RuntimeError, "search extension bootstrap failed", fn -> bootstrap!(database) end
  end

  defp assert_extension!(connection) do
    assert [["search_extensions", "singularity_table_owner", "singularity_table_owner", "1.6"]] ==
             query!(connection, """
             SELECT namespace.nspname, pg_get_userbyid(namespace.nspowner),
                    pg_get_userbyid(extension.extowner), extension.extversion
             FROM pg_extension AS extension JOIN pg_namespace AS namespace ON namespace.oid = extension.extnamespace
             WHERE extension.extname = 'pg_trgm'
             """)

    assert [[0]] ==
             query!(connection, """
             SELECT count(*) FROM pg_proc AS procedure JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
             CROSS JOIN LATERAL aclexplode(COALESCE(procedure.proacl, acldefault('f', procedure.proowner))) AS acl
             WHERE namespace.nspname = 'search_extensions' AND acl.grantee = 0
             """)

    assert [[0]] ==
             query!(connection, """
             SELECT count(*) FROM pg_proc AS procedure JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
             JOIN pg_roles AS owner ON owner.oid = procedure.proowner
             WHERE namespace.nspname = 'search_extensions' AND (owner.oid <> 10 OR NOT owner.rolsuper)
             """)

    assert [["similarity(text,text)", true], ["similarity_op(text,text)", true]] ==
             query!(connection, """
             SELECT procedure.proname || '(' || oidvectortypes(procedure.proargtypes) || ')', acl.is_grantable
             FROM pg_proc AS procedure JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
             CROSS JOIN LATERAL aclexplode(procedure.proacl) AS acl
             WHERE namespace.nspname = 'search_extensions' AND acl.grantee = 'singularity_table_owner'::regrole
             ORDER BY procedure.proname
             """)
             |> Enum.map(fn [signature, grantable] ->
               [String.replace(signature, ", ", ","), grantable]
             end)

    assert [[true]] ==
             query!(connection, """
             SELECT EXISTS (SELECT FROM pg_opclass AS class JOIN pg_namespace AS namespace ON namespace.oid = class.opcnamespace
                            JOIN pg_am AS method ON method.oid = class.opcmethod
                            WHERE namespace.nspname = 'search_extensions' AND class.opcname = 'gin_trgm_ops' AND method.amname = 'gin')
             """)

    assert [[31]] ==
             query!(
               connection,
               "SELECT count(*) FROM pg_proc WHERE pronamespace = 'search_extensions'::regnamespace"
             )

    functions =
      query!(
        connection,
        "SELECT proname FROM pg_proc WHERE pronamespace = 'search_extensions'::regnamespace ORDER BY proname"
      )

    [[installer]] = query!(connection, "SELECT rolname FROM pg_roles WHERE oid = 10")

    expected_acls =
      Enum.map(functions, fn [name] -> [name, installer, installer, "EXECUTE", false] end) ++
        Enum.map(@functions, fn signature ->
          [
            String.split(signature, "(") |> hd(),
            "singularity_table_owner",
            installer,
            "EXECUTE",
            true
          ]
        end)

    actual_acls =
      query!(connection, """
      SELECT procedure.proname, pg_get_userbyid(acl.grantee), pg_get_userbyid(acl.grantor), acl.privilege_type, acl.is_grantable
      FROM pg_proc AS procedure CROSS JOIN LATERAL aclexplode(procedure.proacl) AS acl
      WHERE procedure.pronamespace = 'search_extensions'::regnamespace
      ORDER BY procedure.proname, acl.grantee, acl.grantor
      """)

    assert Enum.sort(actual_acls) == Enum.sort(expected_acls)

    for role <- @runtime_roles do
      assert [[false, false]] ==
               query!(
                 connection,
                 "SELECT has_schema_privilege($1, 'search_extensions', 'USAGE'), has_schema_privilege($1, 'search_extensions', 'CREATE')",
                 [role]
               )

      assert [[0]] ==
               query!(
                 connection,
                 "SELECT count(*) FROM pg_proc WHERE pronamespace = 'search_extensions'::regnamespace AND has_function_privilege($1, oid, 'EXECUTE')",
                 [role]
               )
    end

    assert [[false]] ==
             query!(
               connection,
               "SELECT EXISTS (SELECT FROM pg_namespace AS namespace CROSS JOIN LATERAL aclexplode(namespace.nspacl) AS acl WHERE namespace.nspname = 'search_extensions' AND acl.grantee = 0)"
             )
  end

  defp snapshot(connection) do
    Enum.map(
      [
        "SELECT nspname, nspowner, nspacl::text FROM pg_namespace WHERE nspname = 'search_extensions'",
        "SELECT extname, extowner, extnamespace, extversion FROM pg_extension WHERE extname = 'pg_trgm'",
        "SELECT procedure.oid, procedure.proowner, procedure.proacl::text, procedure.prosrc FROM pg_proc AS procedure JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace WHERE namespace.nspname IN ('search_extensions', 'public') ORDER BY procedure.oid",
        "SELECT relation.oid, relation.relowner, relation.relacl::text FROM pg_class AS relation JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace WHERE namespace.nspname = 'search_extensions' ORDER BY relation.oid",
        "SELECT oid, typname, typowner, typnamespace, typarray, typelem FROM pg_type WHERE typnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'search_extensions') ORDER BY oid",
        "SELECT oid, oprname, oprowner, oprnamespace, oprleft, oprright, oprresult, oprcode FROM pg_operator WHERE oprnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'search_extensions') ORDER BY oid",
        "SELECT oid, opcname, opcowner, opcnamespace, opcmethod, opcfamily, opcintype, opckeytype FROM pg_opclass WHERE opcnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'search_extensions') ORDER BY oid",
        "SELECT oid, opfname, opfowner, opfnamespace, opfmethod FROM pg_opfamily WHERE opfnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'search_extensions') ORDER BY oid",
        "SELECT classid, objid, refclassid, refobjid, deptype FROM pg_depend WHERE refclassid = 'pg_extension'::regclass AND refobjid = (SELECT oid FROM pg_extension WHERE extname = 'pg_trgm') ORDER BY classid, objid, deptype"
      ],
      &query!(connection, &1)
    )
  end

  defp role_snapshot(connection) do
    [
      query!(
        connection,
        "SELECT rolname, rolcanlogin, rolsuper, rolcreatedb, rolcreaterole, rolinherit, rolbypassrls, rolreplication FROM pg_roles WHERE rolname = ANY($1) ORDER BY rolname",
        [@managed_roles]
      ),
      query!(
        connection,
        "SELECT roleid, member, grantor, admin_option, inherit_option, set_option FROM pg_auth_members ORDER BY roleid, member, grantor"
      )
    ]
  end

  defp with_database(fun) do
    database = "singularity_search_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    assert database =~ ~r/\Asingularity_search_[0-9a-f]{24}\z/

    with_admin("postgres", fn connection ->
      query!(connection, "CREATE DATABASE \"#{database}\"")
    end)

    try do
      with_admin(database, fn connection ->
        query!(connection, "GRANT CREATE ON DATABASE \"#{database}\" TO singularity_table_owner")
        fun.(database, connection)
      end)
    after
      with_admin("postgres", &query!(&1, "DROP DATABASE \"#{database}\""))
    end
  end

  defp with_admin(database, fun) do
    url = URI.parse(System.fetch_env!("SINGULARITY_ROLE_PROVISIONER_DATABASE_URL"))
    params = URI.decode_query(url.query || "")
    userinfo = String.split(url.userinfo || "", ":", parts: 2) |> Enum.map(&URI.decode/1)

    username =
      params["user"] || presence(List.first(userinfo)) || System.get_env("PGUSER") ||
        System.fetch_env!("USER")

    host = params["host"] || url.host || System.fetch_env!("PGHOST")
    port = String.to_integer(params["port"] || to_string(url.port || System.fetch_env!("PGPORT")))
    password = params["password"] || Enum.at(userinfo, 1)
    address = if String.starts_with?(host, "/"), do: [socket_dir: host], else: [hostname: host]

    with_connection(
      address ++
        [username: username, password: password, database: database, port: port, log: false],
      fun
    )
  end

  defp presence(""), do: nil
  defp presence(value), do: value

  defp with_role(database, username, fun) do
    with_connection(
      [
        username: username,
        database: database,
        socket_dir: System.fetch_env!("PGHOST"),
        port: String.to_integer(System.fetch_env!("PGPORT")),
        log: false
      ],
      fun
    )
  end

  defp with_connection(options, fun) do
    assert {:ok, connection} = Postgrex.start_link(options)
    Process.unlink(connection)

    try do
      fun.(connection)
    after
      if Process.alive?(connection), do: GenServer.stop(connection)
    end
  end

  defp with_nonadministrator(fun) do
    previous = System.fetch_env!("SINGULARITY_ROLE_PROVISIONER_DATABASE_URL")
    url = URI.parse(previous)

    query =
      url.query
      |> then(&URI.decode_query(&1 || ""))
      |> Map.put("user", "singularity_migration")
      |> Map.delete("password")
      |> URI.encode_query()

    System.put_env(
      "SINGULARITY_ROLE_PROVISIONER_DATABASE_URL",
      URI.to_string(%{url | userinfo: nil, query: query})
    )

    try do
      fun.()
    after
      System.put_env("SINGULARITY_ROLE_PROVISIONER_DATABASE_URL", previous)
    end
  end

  defp test_databases(connection),
    do:
      query!(
        connection,
        "SELECT datname FROM pg_database WHERE datname ~ '^singularity_test_[0-9a-f]{24}$' ORDER BY datname"
      )

  defp query!(connection, sql, params \\ []), do: Postgrex.query!(connection, sql, params).rows

  defp runtime_started?,
    do: Enum.any?(Application.started_applications(), &(elem(&1, 0) == :singularity_runtime))

  defp restore_configuration(configuration) do
    current_keys = Keyword.keys(Application.get_all_env(:singularity_storage))

    Enum.each(
      current_keys -- Keyword.keys(configuration),
      &Application.delete_env(:singularity_storage, &1)
    )

    Enum.each(configuration, fn {key, value} ->
      Application.put_env(:singularity_storage, key, value)
    end)
  end
end
