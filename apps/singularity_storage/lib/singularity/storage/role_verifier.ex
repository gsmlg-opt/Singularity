defmodule Singularity.Storage.RoleVerifier do
  @moduledoc "Read-only verification for externally provisioned PostgreSQL roles."

  alias Ecto.Adapters.SQL
  alias Singularity.Storage.MigrationRepo

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
  @all_roles @owner_roles ++ ["singularity_migration"] ++ @runtime_roles

  @spec verify!() :: :ok
  def verify! do
    with_repo(fn ->
      verify_attributes!()
      verify_memberships!()
      verify_set_only_memberships!()
      verify_runtime_role_isolation!()
    end)
  rescue
    error ->
      Mix.raise("""
      PostgreSQL roles are not provisioned with the required least-privilege contract.
      Run:
        devenv shell -- bash apps/singularity_storage/priv/repo/bootstrap_roles.sh

      Verification failed: #{Exception.message(error)}
      """)
  end

  defp verify_attributes! do
    %{rows: rows} =
      SQL.query!(
        MigrationRepo,
        """
        SELECT
          rolname,
          rolcanlogin,
          rolsuper,
          rolcreatedb,
          rolcreaterole,
          rolinherit,
          rolbypassrls,
          rolreplication
        FROM pg_catalog.pg_roles
        WHERE rolname = ANY($1)
        """,
        [@all_roles],
        log: false
      )

    actual =
      Map.new(rows, fn [
                         name,
                         login?,
                         superuser?,
                         createdb?,
                         createrole?,
                         inherit?,
                         bypass_rls?,
                         replication?
                       ] ->
        {name, {login?, superuser?, createdb?, createrole?, inherit?, bypass_rls?, replication?}}
      end)

    expected =
      Map.new(@owner_roles, &{&1, {false, false, false, false, false, false, false}})
      |> Map.put("singularity_migration", {true, false, true, false, false, false, false})
      |> Map.merge(
        Map.new(@runtime_roles, &{&1, {true, false, false, false, false, false, false}})
      )

    unless actual == expected do
      raise "role attributes do not match the required contract"
    end
  end

  defp verify_memberships! do
    %{rows: rows} =
      SQL.query!(
        MigrationRepo,
        """
        SELECT
          granted.rolname,
          member.rolname,
          membership.admin_option,
          membership.inherit_option,
          membership.set_option
        FROM pg_catalog.pg_auth_members AS membership
        JOIN pg_catalog.pg_roles AS granted ON granted.oid = membership.roleid
        JOIN pg_catalog.pg_roles AS member ON member.oid = membership.member
        WHERE granted.rolname = ANY($1)
          OR member.rolname = ANY($1)
        ORDER BY
          granted.rolname,
          member.rolname,
          membership.admin_option,
          membership.inherit_option,
          membership.set_option
        """,
        [@all_roles],
        log: false
      )

    expected =
      @owner_roles
      |> Enum.map(&[&1, "singularity_migration", false, false, true])
      |> Enum.sort()

    unless rows == expected do
      raise "managed-role memberships do not match the exact contract"
    end
  end

  defp verify_set_only_memberships! do
    Enum.each(@owner_roles, fn owner ->
      %{rows: [[can_set?, inherits?]]} =
        SQL.query!(
          MigrationRepo,
          """
          SELECT
            pg_has_role(current_user, $1, 'SET'),
            pg_has_role(current_user, $1, 'USAGE')
          """,
          [owner],
          log: false
        )

      unless can_set? and not inherits? do
        raise "migration role cannot SET without inheriting #{owner}"
      end
    end)
  end

  defp verify_runtime_role_isolation! do
    %{rows: [[reachable_owner_count]]} =
      SQL.query!(
        MigrationRepo,
        """
        SELECT count(*)
        FROM unnest($1::text[]) AS runtime(role_name)
        CROSS JOIN unnest($2::text[]) AS owner(role_name)
        WHERE pg_has_role(runtime.role_name, owner.role_name, 'SET')
          OR pg_has_role(runtime.role_name, owner.role_name, 'USAGE')
        """,
        [@runtime_roles, @owner_roles],
        log: false
      )

    unless reachable_owner_count == 0 do
      raise "a runtime role can SET or inherit an owner role"
    end
  end

  defp with_repo(fun) do
    {:ok, _started} = Application.ensure_all_started(:ecto_sql)
    {:ok, _started} = Application.ensure_all_started(:postgrex)

    case Process.whereis(MigrationRepo) do
      nil ->
        {:ok, pid} =
          MigrationRepo.start_link(
            url: nil,
            username: "singularity_migration",
            database: "postgres",
            socket_dir: System.fetch_env!("PGHOST"),
            port: pg_port!(),
            pool_size: 1
          )

        try do
          fun.()
        after
          GenServer.stop(pid)
        end

      _pid ->
        fun.()
    end
  end

  defp pg_port! do
    case Integer.parse(System.fetch_env!("PGPORT")) do
      {port, ""} when port in 1..65_535 -> port
      _other -> raise "PGPORT must be a valid PostgreSQL port"
    end
  end
end
