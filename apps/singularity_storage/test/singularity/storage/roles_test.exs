defmodule Singularity.Storage.RolesTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.RoleVerifier

  @unexpected_role "singularity_test_unexpected_bypass"

  @owner_roles ~w(
    singularity_table_owner
    singularity_auth_definer
    singularity_authorization_definer
    singularity_outbox_definer
  )
  @runtime_roles ~w(
    singularity_pre_auth
    singularity_web
    singularity_dispatcher
    singularity_worker
  )
  @function_contract %{
    "content.list_open_upload_stages()" => {"singularity_table_owner", ["singularity_worker"]},
    "content.reconcile_open_upload_stage(uuid,text,timestamp with time zone,text)" =>
      {"singularity_table_owner", ["singularity_worker"]},
    "content.upload_stage_recovery_status(uuid,text)" =>
      {"singularity_table_owner", ["singularity_worker"]},
    "core.acknowledge_outbox_event(uuid,uuid,text)" =>
      {"singularity_outbox_definer", ["singularity_dispatcher"]},
    "core.claim_outbox_events(integer,integer,uuid)" =>
      {"singularity_outbox_definer", ["singularity_dispatcher"]},
    "core.current_principal_can_discover_classification(text)" =>
      {"singularity_authorization_definer", ["singularity_web"]},
    "core.principal_is_authorized(uuid,uuid)" =>
      {"singularity_authorization_definer", ["singularity_web", "singularity_worker"]},
    "identity.authentication_candidate(text)" =>
      {"singularity_auth_definer", ["singularity_pre_auth"]},
    "identity.complete_authentication_attempt(uuid,bytea,bytea,uuid)" =>
      {"singularity_auth_definer", ["singularity_web"]},
    "identity.record_auth_attempt(bytea,bytea,text,uuid,uuid)" =>
      {"singularity_auth_definer", ["singularity_pre_auth"]},
    "identity.resolve_session(bytea)" => {"singularity_auth_definer", ["singularity_pre_auth"]}
  }

  test "bootstrap removes and verifier rejects every unexpected managed-role membership" do
    on_exit(&drop_unexpected_role!/0)
    drop_unexpected_role!()

    provisioner_sql!("""
    CREATE ROLE #{@unexpected_role}
      NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
      NOINHERIT BYPASSRLS NOREPLICATION
    """)

    grant_unexpected_role!()
    assert settable_by_web?(@unexpected_role)

    assert_raise Mix.Error, ~r/managed-role memberships do not match the exact contract/, fn ->
      RoleVerifier.verify!()
    end

    run_role_bootstrap!()

    refute settable_by_web?(@unexpected_role)
    RoleVerifier.verify!()

    grant_unexpected_role!()

    assert_raise Mix.Error, ~r/managed-role memberships do not match the exact contract/, fn ->
      RoleVerifier.verify!()
    end
  end

  test "migration has SET-only owner memberships and no cluster-role administration" do
    %{rows: [[true, false, true, false, false, false, false]]} =
      query!(
        RequestRepo,
        """
        SELECT
          rolcanlogin,
          rolsuper,
          rolcreatedb,
          rolcreaterole,
          rolinherit,
          rolbypassrls,
          rolreplication
        FROM pg_catalog.pg_roles
        WHERE rolname = 'singularity_migration'
        """
      )

    %{rows: memberships} =
      query!(
        RequestRepo,
        """
        SELECT
          granted.rolname,
          membership.admin_option,
          membership.inherit_option,
          membership.set_option
        FROM pg_catalog.pg_auth_members AS membership
        JOIN pg_catalog.pg_roles AS granted ON granted.oid = membership.roleid
        JOIN pg_catalog.pg_roles AS member ON member.oid = membership.member
        WHERE member.rolname = 'singularity_migration'
          AND granted.rolname = ANY($1)
        ORDER BY granted.rolname
        """,
        [@owner_roles]
      )

    assert memberships ==
             @owner_roles
             |> Enum.sort()
             |> Enum.map(&[&1, false, false, true])
  end

  test "runtime and definer roles are non-owning no-bypass principals" do
    %{rows: role_rows} =
      query!(
        RequestRepo,
        """
        SELECT
          rolname,
          rolcanlogin,
          rolsuper,
          rolcreatedb,
          rolcreaterole,
          rolbypassrls,
          rolreplication
        FROM pg_catalog.pg_roles
        WHERE rolname = ANY($1)
        ORDER BY rolname
        """,
        [@owner_roles ++ @runtime_roles]
      )

    expected =
      Enum.map(@owner_roles, &[&1, false, false, false, false, false, false]) ++
        Enum.map(@runtime_roles, &[&1, true, false, false, false, false, false])

    assert role_rows == Enum.sort(expected)

    %{rows: [[0]]} =
      query!(
        RequestRepo,
        """
        SELECT count(*)
        FROM pg_catalog.pg_auth_members AS membership
        JOIN pg_catalog.pg_roles AS granted ON granted.oid = membership.roleid
        JOIN pg_catalog.pg_roles AS member ON member.oid = membership.member
        WHERE granted.rolname = ANY($1)
          AND member.rolname = ANY($2)
        """,
        [@owner_roles, @runtime_roles]
      )

    %{rows: [[0]]} =
      query!(
        RequestRepo,
        """
        SELECT count(*)
        FROM unnest($1::text[]) AS runtime(role_name)
        CROSS JOIN unnest($2::text[]) AS owner(role_name)
        WHERE pg_has_role(runtime.role_name, owner.role_name, 'SET')
          OR pg_has_role(runtime.role_name, owner.role_name, 'USAGE')
        """,
        [@runtime_roles, @owner_roles]
      )
  end

  test "security-definer functions have fixed search paths and no PUBLIC execution" do
    %{rows: rows} =
      query!(
        RequestRepo,
        """
        SELECT
          procedure.oid::regprocedure::text,
          owner.rolname,
          procedure.prosecdef,
          procedure.proconfig,
          EXISTS (
            SELECT 1
            FROM aclexplode(
              COALESCE(
                procedure.proacl,
                acldefault('f', procedure.proowner)
              )
            ) AS privilege
            WHERE privilege.grantee = 0
              AND privilege.privilege_type = 'EXECUTE'
          ) AS public_execute
        FROM pg_catalog.pg_proc AS procedure
        JOIN pg_catalog.pg_roles AS owner ON owner.oid = procedure.proowner
        WHERE procedure.oid::regprocedure::text = ANY($1)
        ORDER BY procedure.oid::regprocedure::text
        """,
        [Map.keys(@function_contract)]
      )

    assert length(rows) == map_size(@function_contract)

    for [signature, owner, security_definer?, settings, public_execute?] <- rows do
      {expected_owner, allowed_roles} = Map.fetch!(@function_contract, signature)

      assert owner == expected_owner
      assert security_definer?
      refute public_execute?
      assert Enum.any?(settings, &String.starts_with?(&1, "search_path="))

      for role <- @runtime_roles do
        %{rows: [[can_execute?]]} =
          query!(
            RequestRepo,
            "SELECT has_function_privilege($1, $2, 'EXECUTE')",
            [role, signature]
          )

        assert can_execute? == role in allowed_roles
      end
    end
  end

  test "function owners retain no schema CREATE and authorization reads exact columns" do
    for {role, schema} <- [
          {"singularity_auth_definer", "identity"},
          {"singularity_authorization_definer", "core"},
          {"singularity_outbox_definer", "core"}
        ] do
      %{rows: [[true, false]]} =
        query!(
          RequestRepo,
          """
          SELECT
            has_schema_privilege($1, $2, 'USAGE'),
            has_schema_privilege($1, $2, 'CREATE')
          """,
          [role, schema]
        )
    end

    %{rows: column_privileges} =
      query!(
        RequestRepo,
        """
        SELECT attribute.attname, privilege.privilege_type
        FROM pg_catalog.pg_attribute AS attribute
        JOIN pg_catalog.pg_class AS relation
          ON relation.oid = attribute.attrelid
        JOIN pg_catalog.pg_namespace AS namespace
          ON namespace.oid = relation.relnamespace
        CROSS JOIN LATERAL aclexplode(attribute.attacl) AS privilege
        JOIN pg_catalog.pg_roles AS grantee
          ON grantee.oid = privilege.grantee
        WHERE namespace.nspname = 'core'
          AND relation.relname = 'vault_members'
          AND grantee.rolname = 'singularity_authorization_definer'
        ORDER BY attribute.attname, privilege.privilege_type
        """
      )

    assert column_privileges == [
             ["clearance", "SELECT"],
             ["principal_id", "SELECT"],
             ["revoked_at", "SELECT"],
             ["vault_id", "SELECT"]
           ]

    %{rows: [[false]]} =
      query!(
        RequestRepo,
        """
        SELECT has_table_privilege(
          'singularity_authorization_definer',
          'core.vault_members',
          'SELECT'
        )
        """
      )

    %{rows: outbox_epoch_privileges} =
      query!(
        RequestRepo,
        """
        SELECT attribute.attname, privilege.privilege_type
        FROM pg_catalog.pg_attribute AS attribute
        JOIN pg_catalog.pg_class AS relation
          ON relation.oid = attribute.attrelid
        JOIN pg_catalog.pg_namespace AS namespace
          ON namespace.oid = relation.relnamespace
        CROSS JOIN LATERAL aclexplode(attribute.attacl) AS privilege
        JOIN pg_catalog.pg_roles AS grantee
          ON grantee.oid = privilege.grantee
        WHERE namespace.nspname = 'core'
          AND relation.relname = 'outbox_events'
          AND grantee.rolname = 'singularity_outbox_definer'
          AND attribute.attname LIKE '%authorization_epoch'
        ORDER BY attribute.attname, privilege.privilege_type
        """
      )

    assert outbox_epoch_privileges == [
             ["principal_authorization_epoch", "SELECT"],
             ["vault_authorization_epoch", "SELECT"]
           ]

    %{rows: [[false]]} =
      query!(
        RequestRepo,
        """
        SELECT has_table_privilege(
          'singularity_outbox_definer',
          'core.outbox_events',
          'SELECT'
        )
        """
      )
  end

  test "dispatcher can claim and acknowledge only through the audited definer interface" do
    %{one: one} = Fixtures.two_vaults!()
    event = Fixtures.outbox_event!(one)
    claim_token = Ecto.UUID.generate() |> Ecto.UUID.dump!()

    assert_raise Postgrex.Error, ~r/permission denied/, fn ->
      query!(DispatcherRepo, "SELECT id FROM core.outbox_events")
    end

    assert %{
             rows: [
               [
                 event_id,
                 _event_type,
                 _idempotency_key,
                 _vault_id,
                 _principal_id,
                 _required_capability,
                 7,
                 23
                 | _minimal_envelope
               ]
             ]
           } =
             query!(
               DispatcherRepo,
               "SELECT * FROM core.claim_outbox_events(1, 30, $1)",
               [claim_token]
             )

    assert event_id == event.id

    assert %{rows: [[true]]} =
             query!(
               DispatcherRepo,
               "SELECT core.acknowledge_outbox_event($1, $2, $3)",
               [event.id, claim_token, "runner-job-1"]
             )

    assert %{rows: [[false]]} =
             query!(
               DispatcherRepo,
               "SELECT core.acknowledge_outbox_event($1, $2, $3)",
               [event.id, claim_token, "runner-job-1"]
             )
  end

  test "only WorkerRepo's role receives direct Oban infrastructure privileges" do
    for table <- ["jobs.oban_jobs", "jobs.oban_peers"] do
      %{rows: [[false, false, false, false]]} =
        query!(
          RequestRepo,
          """
          SELECT
            has_table_privilege('singularity_dispatcher', $1, 'SELECT'),
            has_table_privilege('singularity_dispatcher', $1, 'INSERT'),
            has_table_privilege('singularity_dispatcher', $1, 'UPDATE'),
            has_table_privilege('singularity_dispatcher', $1, 'DELETE')
          """,
          [table]
        )

      %{rows: [[true, true, true, true]]} =
        query!(
          RequestRepo,
          """
          SELECT
            has_table_privilege('singularity_worker', $1, 'SELECT'),
            has_table_privilege('singularity_worker', $1, 'INSERT'),
            has_table_privilege('singularity_worker', $1, 'UPDATE'),
            has_table_privilege('singularity_worker', $1, 'DELETE')
          """,
          [table]
        )
    end

    %{rows: [[false, true]]} =
      query!(
        RequestRepo,
        """
        SELECT
          has_sequence_privilege(
            'singularity_dispatcher',
            'jobs.oban_jobs_id_seq',
            'USAGE'
          ),
          has_sequence_privilege(
            'singularity_worker',
            'jobs.oban_jobs_id_seq',
            'USAGE'
          )
        """
      )
  end

  test "only the worker role can resolve object cleanup authority" do
    assert %{rows: [[false, true, false]]} =
             query!(
               RequestRepo,
               """
               SELECT
                 has_function_privilege(
                   'singularity_web',
                   'core.object_cleanup_authorization(uuid)',
                   'EXECUTE'
                 ),
                 has_function_privilege(
                   'singularity_worker',
                   'core.object_cleanup_authorization(uuid)',
                   'EXECUTE'
                 ),
                 has_function_privilege(
                   'public',
                   'core.object_cleanup_authorization(uuid)',
                   'EXECUTE'
                 )
               """
             )
  end

  defp grant_unexpected_role! do
    provisioner_sql!("GRANT #{@unexpected_role} TO singularity_web WITH SET TRUE")
  end

  defp settable_by_web?(role) do
    %{rows: [[settable?]]} =
      query!(
        RequestRepo,
        "SELECT pg_has_role('singularity_web', $1, 'SET')",
        [role]
      )

    settable?
  end

  defp run_role_bootstrap! do
    wrapper =
      :singularity_storage
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("repo/bootstrap_roles.sh")

    {_output, 0} = System.cmd("bash", [wrapper], stderr_to_stdout: true)
    :ok
  end

  defp drop_unexpected_role! do
    provisioner_sql!("""
    DO $cleanup$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles
        WHERE rolname = '#{@unexpected_role}'
      ) THEN
        REVOKE #{@unexpected_role} FROM singularity_web;
        DROP ROLE #{@unexpected_role};
      END IF;
    END
    $cleanup$
    """)
  end

  defp provisioner_sql!(sql) do
    connection_helper =
      :singularity_storage
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("repo/bootstrap_roles.exs")

    shell = """
    exec 9< <(elixir "$1")
    unset SINGULARITY_ROLE_PROVISIONER_DATABASE_URL
    PGSERVICEFILE=/dev/fd/9 PGSERVICE=singularity_role_provisioner \
      exec psql --no-psqlrc --set=ON_ERROR_STOP=1 --command "$2"
    """

    case System.cmd(
           "bash",
           ["-c", shell, "role-membership-test", connection_helper, sql],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, status} -> raise "role provisioner command failed (#{status}): #{output}"
    end
  end
end
