defmodule Singularity.Storage.Task14BackupIdentityExportSecurityTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Ecto.Adapters.SQL
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.ScopedRepo

  @function "identity.export_current_vault_owner(uuid)"
  @result_fields ~w(
    person_id
    person_display_name
    person_metadata
    person_inserted_at
    person_updated_at
    account_id
    account_person_id
    account_status
    account_metadata
    account_inserted_at
    account_updated_at
    credential_id
    credential_account_id
    credential_normalized_login
    credential_revoked_at
    credential_inserted_at
    principal_id
    principal_account_id
    principal_kind
    principal_authorization_epoch
    principal_revoked_at
    principal_metadata
    principal_inserted_at
    principal_updated_at
  )
  @result_types [
    "uuid",
    "text",
    "jsonb",
    "timestamp with time zone",
    "timestamp with time zone",
    "uuid",
    "uuid",
    "text",
    "jsonb",
    "timestamp with time zone",
    "timestamp with time zone",
    "uuid",
    "uuid",
    "text",
    "timestamp with time zone",
    "timestamp with time zone",
    "uuid",
    "uuid",
    "text",
    "bigint",
    "timestamp with time zone",
    "jsonb",
    "timestamp with time zone",
    "timestamp with time zone"
  ]

  setup do
    Fixtures.two_vaults!()
  end

  test "scoped owner exports the exact same-account identity closure", %{one: one, two: two} do
    closure = prepare_identity_closure!(one, two)

    %{columns: columns, rows: rows} = export(one, one.vault_id)

    assert columns == @result_fields

    for forbidden <- ~w(session token auth_attempt security_setting verifier) do
      refute Enum.any?(columns, &String.contains?(&1, forbidden))
    end

    refute Enum.any?(
             List.flatten(rows),
             &(&1 in ["backup-verifier-revoked", "backup-verifier-active"])
           )

    assert length(rows) == 4

    principal_credential_order =
      Enum.map(rows, fn row ->
        {Enum.at(row, 16), Enum.at(row, 11)}
      end)

    assert principal_credential_order == Enum.sort(principal_credential_order)

    assert MapSet.new(principal_credential_order) ==
             MapSet.new(
               for principal_id <- [one.principal_id, closure.system_principal_id],
                   credential_id <- [one.credential_id, closure.extra_credential_id] do
                 {principal_id, credential_id}
               end
             )

    mapped_rows = Enum.map(rows, &row_map/1)

    for row <- mapped_rows do
      assert row.person_id == closure.person_id
      assert row.person_display_name == "Backup Owner"
      assert row.person_metadata == %{"source" => "task14-person"}
      assert_datetime(row.person_inserted_at, ~U[2026-07-20 01:00:00Z])
      assert_datetime(row.person_updated_at, ~U[2026-07-20 01:01:00Z])
      assert row.account_id == one.account_id
      assert row.account_person_id == closure.person_id
      assert row.account_status == "active"
      assert row.account_metadata == %{"source" => "task14-account"}
      assert_datetime(row.account_inserted_at, ~U[2026-07-20 02:00:00Z])
      assert_datetime(row.account_updated_at, ~U[2026-07-20 02:01:00Z])
      assert row.credential_account_id == one.account_id
      assert row.principal_account_id == one.account_id
    end

    owner_rows = Enum.filter(mapped_rows, &(&1.principal_id == one.principal_id))
    system_rows = Enum.filter(mapped_rows, &(&1.principal_id == closure.system_principal_id))

    assert length(owner_rows) == 2
    assert length(system_rows) == 2

    for row <- owner_rows do
      assert row.principal_kind == "owner"
      assert row.principal_authorization_epoch == 41
      assert row.principal_revoked_at == nil
      assert row.principal_metadata == %{"source" => "task14-owner"}
      assert_datetime(row.principal_inserted_at, ~U[2026-07-20 04:00:00Z])
      assert_datetime(row.principal_updated_at, ~U[2026-07-20 04:01:00Z])
    end

    for row <- system_rows do
      assert row.principal_kind == "system"
      assert row.principal_authorization_epoch == 73
      assert_datetime(row.principal_revoked_at, ~U[2026-07-20 05:02:00Z])
      assert row.principal_metadata == %{"source" => "task14-system"}
      assert_datetime(row.principal_inserted_at, ~U[2026-07-20 05:00:00Z])
      assert_datetime(row.principal_updated_at, ~U[2026-07-20 05:01:00Z])
    end

    revoked_credential_rows =
      Enum.filter(mapped_rows, &(&1.credential_id == one.credential_id))

    assert length(revoked_credential_rows) == 2

    for row <- revoked_credential_rows do
      assert row.credential_normalized_login == one.normalized_login
      assert_datetime(row.credential_revoked_at, ~U[2026-07-20 03:02:00Z])
      assert_datetime(row.credential_inserted_at, ~U[2026-07-20 03:00:00Z])
    end

    active_credential_rows =
      Enum.filter(mapped_rows, &(&1.credential_id == closure.extra_credential_id))

    assert length(active_credential_rows) == 2

    for row <- active_credential_rows do
      assert row.credential_normalized_login == closure.extra_normalized_login
      assert row.credential_revoked_at == nil
      assert_datetime(row.credential_inserted_at, ~U[2026-07-20 03:10:00Z])
    end

    refute Enum.any?(mapped_rows, &(&1.account_id == two.account_id))
    refute Enum.any?(mapped_rows, &(&1.credential_id == two.credential_id))
    refute Enum.any?(mapped_rows, &(&1.principal_id == two.principal_id))

    refute Enum.any?(
             mapped_rows,
             &(&1.principal_id == closure.other_vault_principal_id)
           )
  end

  test "scope and current-owner guards fail closed", %{one: one, two: two} do
    assert export(one, nil).rows == []
    assert export(one, two.vault_id).rows == []

    assert query!(WorkerRepo, "SELECT * FROM identity.export_current_vault_owner($1)", [
             one.vault_id
           ]).rows == []

    update_owner!(one, "kind = 'system'")
    assert export(one, one.vault_id).rows == []
    update_owner!(one, "kind = 'owner'")

    update_owner!(one, "revoked_at = CURRENT_TIMESTAMP")
    assert export(one, one.vault_id).rows == []
    update_owner!(one, "revoked_at = NULL")

    update_membership!(one, "revoked_at = CURRENT_TIMESTAMP")
    assert export(one, one.vault_id).rows == []
    update_membership!(one, "revoked_at = NULL")

    update_account!(one, "status = 'disabled'")
    assert export(one, one.vault_id).rows == []
  end

  test "an account without credentials exports zero rows", %{one: one} do
    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "DELETE FROM identity.sessions WHERE account_id = $1", [
        one.account_id
      ])

      query!(MigrationRepo, "DELETE FROM identity.credentials WHERE account_id = $1", [
        one.account_id
      ])
    end)

    assert export(one, one.vault_id).rows == []
  end

  test "function signature, result types, owner, stability, and search path are exact" do
    %{rows: rows} =
      query!(
        RequestRepo,
        """
        SELECT
          owner.rolname,
          language.lanname,
          procedure.prosecdef,
          procedure.provolatile::text,
          procedure.proconfig,
          procedure.pronargs,
          pg_get_function_identity_arguments(procedure.oid)
        FROM pg_catalog.pg_proc AS procedure
        JOIN pg_catalog.pg_roles AS owner ON owner.oid = procedure.proowner
        JOIN pg_catalog.pg_language AS language ON language.oid = procedure.prolang
        WHERE procedure.oid = to_regprocedure($1)
        """,
        [@function]
      )

    assert rows == [
             [
               "singularity_authorization_definer",
               "sql",
               true,
               "s",
               ["search_path=pg_catalog, identity, core"],
               1,
               "requested_vault uuid"
             ]
           ]

    %{rows: argument_rows} =
      query!(
        RequestRepo,
        """
        SELECT
          argument.mode::text,
          argument.name,
          pg_catalog.format_type(argument.type_oid, NULL)
        FROM pg_catalog.pg_proc AS procedure
        CROSS JOIN LATERAL unnest(
          procedure.proallargtypes,
          procedure.proargmodes,
          procedure.proargnames
        ) WITH ORDINALITY AS argument(type_oid, mode, name, position)
        WHERE procedure.oid = to_regprocedure($1)
        ORDER BY argument.position
        """,
        [@function]
      )

    assert argument_rows ==
             [["i", "requested_vault", "uuid"]] ++
               Enum.zip_with(@result_fields, @result_types, fn name, type ->
                 ["t", name, type]
               end)
  end

  test "only worker can execute and runtime roles cannot read identity tables", %{one: one} do
    assert %{rows: [_ | _]} = export(one, one.vault_id)

    for repo <- [RequestRepo, PreAuthRepo, DispatcherRepo] do
      assert_raise Postgrex.Error, ~r/permission denied/, fn ->
        query!(repo, "SELECT * FROM identity.export_current_vault_owner($1)", [one.vault_id])
      end
    end

    %{rows: execute_matrix} =
      query!(
        RequestRepo,
        """
        SELECT role.role_name,
          has_function_privilege(role.role_name, $1, 'EXECUTE')
        FROM unnest($2::text[]) AS role(role_name)
        ORDER BY role.role_name
        """,
        [
          @function,
          ~w(public singularity_dispatcher singularity_pre_auth singularity_web singularity_worker)
        ]
      )

    assert execute_matrix == [
             ["public", false],
             ["singularity_dispatcher", false],
             ["singularity_pre_auth", false],
             ["singularity_web", false],
             ["singularity_worker", true]
           ]

    runtime_roles =
      ~w(singularity_dispatcher singularity_pre_auth singularity_web singularity_worker)

    identity_tables = ~w(accounts auth_attempts credentials people principals sessions)

    %{rows: table_select_matrix} =
      query!(
        RequestRepo,
        """
        SELECT
          runtime.role_name,
          identity_table.table_name,
          has_table_privilege(
            runtime.role_name,
            'identity.' || identity_table.table_name,
            'SELECT'
          )
        FROM unnest($1::text[]) AS runtime(role_name)
        CROSS JOIN unnest($2::text[]) AS identity_table(table_name)
        ORDER BY runtime.role_name, identity_table.table_name
        """,
        [runtime_roles, identity_tables]
      )

    expected_table_select_matrix =
      for role <- runtime_roles, table <- identity_tables do
        [
          role,
          table,
          table == "sessions" and
            role in ["singularity_web", "singularity_worker"]
        ]
      end

    assert table_select_matrix == expected_table_select_matrix

    for table <- ~w(people accounts credentials principals auth_attempts) do
      assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
               SQL.query(WorkerRepo, "SELECT * FROM identity.#{table}", [], log: false)
    end

    assert {:ok, %{rows: []}} =
             SQL.query(WorkerRepo, "SELECT * FROM identity.sessions", [], log: false)
  end

  test "definer grants stay column-only and Task 14 adds only the people policy" do
    closure_privileges =
      authorization_column_privileges(~w(people accounts credentials principals))

    assert closure_privileges == [
             ["accounts", "id", "SELECT"],
             ["accounts", "inserted_at", "SELECT"],
             ["accounts", "metadata", "SELECT"],
             ["accounts", "person_id", "SELECT"],
             ["accounts", "status", "SELECT"],
             ["accounts", "updated_at", "SELECT"],
             ["credentials", "account_id", "SELECT"],
             ["credentials", "id", "SELECT"],
             ["credentials", "inserted_at", "SELECT"],
             ["credentials", "normalized_login", "SELECT"],
             ["credentials", "revoked_at", "SELECT"],
             ["credentials", "updated_at", "SELECT"],
             ["people", "display_name", "SELECT"],
             ["people", "id", "SELECT"],
             ["people", "inserted_at", "SELECT"],
             ["people", "metadata", "SELECT"],
             ["people", "updated_at", "SELECT"],
             ["principals", "account_id", "SELECT"],
             ["principals", "authorization_epoch", "SELECT"],
             ["principals", "id", "SELECT"],
             ["principals", "inserted_at", "SELECT"],
             ["principals", "kind", "SELECT"],
             ["principals", "metadata", "SELECT"],
             ["principals", "revoked_at", "SELECT"],
             ["principals", "updated_at", "SELECT"]
           ]

    %{rows: table_privileges} =
      query!(
        RequestRepo,
        """
        SELECT table_name,
          has_table_privilege(
            'singularity_authorization_definer',
            'identity.' || table_name,
            'SELECT'
          )
        FROM unnest($1::text[]) AS table_name
        ORDER BY table_name
        """,
        [~w(accounts credentials people principals)]
      )

    assert table_privileges == [
             ["accounts", false],
             ["credentials", false],
             ["people", false],
             ["principals", false]
           ]

    assert authorization_column_privileges(~w(auth_attempts sessions)) == [
             ["sessions", "account_id", "SELECT"],
             ["sessions", "credential_id", "SELECT"],
             ["sessions", "expires_at", "SELECT"],
             ["sessions", "id", "SELECT"],
             ["sessions", "principal_id", "SELECT"],
             ["sessions", "revoked_at", "SELECT"],
             ["sessions", "vault_id", "SELECT"]
           ]

    %{rows: policies} =
      query!(
        RequestRepo,
        """
        SELECT tablename, policyname, roles::text[], cmd
        FROM pg_catalog.pg_policies
        WHERE schemaname = 'identity'
          AND tablename = ANY($1)
          AND roles::text[] && $2::text[]
        ORDER BY tablename, policyname
        """,
        [
          ~w(accounts auth_attempts credentials people principals sessions),
          ~w(public singularity_authorization_definer)
        ]
      )

    assert policies == [
             [
               "accounts",
               "task11_authorization_reads_accounts",
               ["singularity_authorization_definer"],
               "SELECT"
             ],
             [
               "credentials",
               "task11_authorization_reads_credentials",
               ["singularity_authorization_definer"],
               "SELECT"
             ],
             [
               "credentials",
               "task11_authorization_updates_credentials",
               ["singularity_authorization_definer"],
               "UPDATE"
             ],
             [
               "people",
               "task14_authorization_reads_people",
               ["singularity_authorization_definer"],
               "SELECT"
             ],
             [
               "principals",
               "task11_authorization_reads_principals",
               ["singularity_authorization_definer"],
               "SELECT"
             ],
             [
               "sessions",
               "task11_authorization_reads_sessions",
               ["singularity_authorization_definer"],
               "SELECT"
             ]
           ]
  end

  defp prepare_identity_closure!(one, two) do
    extra_credential_id = uuid()
    other_vault_principal_id = uuid()
    system_principal_id = uuid()
    extra_normalized_login = "backup-#{Ecto.UUID.generate()}@example.test"

    Fixtures.with_owner(fn ->
      %{rows: [[person_id]]} =
        query!(
          MigrationRepo,
          """
          UPDATE identity.people
          SET
            display_name = 'Backup Owner',
            metadata = '{"source":"task14-person"}'::jsonb,
            inserted_at = '2026-07-20 01:00:00+00',
            updated_at = '2026-07-20 01:01:00+00'
          WHERE id = (SELECT person_id FROM identity.accounts WHERE id = $1)
          RETURNING id
          """,
          [one.account_id]
        )

      query!(
        MigrationRepo,
        """
        UPDATE identity.accounts
        SET
          metadata = '{"source":"task14-account"}'::jsonb,
          inserted_at = '2026-07-20 02:00:00+00',
          updated_at = '2026-07-20 02:01:00+00'
        WHERE id = $1
        """,
        [one.account_id]
      )

      query!(
        MigrationRepo,
        """
        UPDATE identity.credentials
        SET
          verifier = 'backup-verifier-revoked',
          verifier_version = 7,
          revoked_at = '2026-07-20 03:02:00+00',
          inserted_at = '2026-07-20 03:00:00+00',
          updated_at = '2026-07-20 03:01:00+00'
        WHERE id = $1
        """,
        [one.credential_id]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO identity.credentials (
          id,
          account_id,
          normalized_login,
          verifier,
          verifier_version,
          inserted_at,
          updated_at
        ) VALUES (
          $1,
          $2,
          $3,
          'backup-verifier-active',
          11,
          '2026-07-20 03:10:00+00',
          '2026-07-20 03:11:00+00'
        )
        """,
        [extra_credential_id, one.account_id, extra_normalized_login]
      )

      query!(
        MigrationRepo,
        """
        UPDATE identity.principals
        SET
          authorization_epoch = 41,
          metadata = '{"source":"task14-owner"}'::jsonb,
          inserted_at = '2026-07-20 04:00:00+00',
          updated_at = '2026-07-20 04:01:00+00'
        WHERE id = $1
        """,
        [one.principal_id]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO identity.principals (
          id,
          account_id,
          kind,
          authorization_epoch,
          revoked_at,
          metadata,
          inserted_at,
          updated_at
        ) VALUES (
          $1,
          $2,
          'system',
          73,
          '2026-07-20 05:02:00+00',
          '{"source":"task14-system"}'::jsonb,
          '2026-07-20 05:00:00+00',
          '2026-07-20 05:01:00+00'
        )
        """,
        [system_principal_id, one.account_id]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO identity.principals (id, account_id, kind)
        VALUES ($1, $2, 'system')
        """,
        [other_vault_principal_id, one.account_id]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.vault_members (principal_id, vault_id, revoked_at)
        VALUES ($1, $2, '2026-07-20 05:03:00+00')
        """,
        [system_principal_id, one.vault_id]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.vault_members (principal_id, vault_id)
        VALUES ($1, $2)
        """,
        [two.principal_id, one.vault_id]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.vault_members (principal_id, vault_id)
        VALUES ($1, $2)
        """,
        [other_vault_principal_id, two.vault_id]
      )

      person_id
    end)
    |> then(fn person_id ->
      %{
        extra_credential_id: extra_credential_id,
        extra_normalized_login: extra_normalized_login,
        other_vault_principal_id: other_vault_principal_id,
        person_id: person_id,
        system_principal_id: system_principal_id
      }
    end)
  end

  defp export(fixture, requested_vault) do
    WorkerRepo.checkout(fn ->
      ScopedRepo.transact(
        WorkerRepo,
        %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
        [isolation: :repeatable_read],
        fn repo ->
          query!(repo, "SELECT * FROM identity.export_current_vault_owner($1)", [requested_vault])
        end
      )
    end)
  end

  defp row_map(row) do
    @result_fields
    |> Enum.map(&String.to_atom/1)
    |> Enum.zip(row)
    |> Map.new()
  end

  defp authorization_column_privileges(tables) do
    query!(
      RequestRepo,
      """
      SELECT relation.relname, attribute.attname, privilege.privilege_type
      FROM pg_catalog.pg_attribute AS attribute
      JOIN pg_catalog.pg_class AS relation ON relation.oid = attribute.attrelid
      JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
      CROSS JOIN LATERAL aclexplode(attribute.attacl) AS privilege
      JOIN pg_catalog.pg_roles AS grantee ON grantee.oid = privilege.grantee
      WHERE namespace.nspname = 'identity'
        AND relation.relname = ANY($1)
        AND grantee.rolname = 'singularity_authorization_definer'
        AND privilege.privilege_type = 'SELECT'
      ORDER BY relation.relname, attribute.attname, privilege.privilege_type
      """,
      [tables]
    ).rows
  end

  defp update_owner!(fixture, assignment) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE identity.principals SET #{assignment} WHERE id = $1",
        [fixture.principal_id]
      )
    end)
  end

  defp update_membership!(fixture, assignment) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE core.vault_members
        SET #{assignment}
        WHERE principal_id = $1 AND vault_id = $2
        """,
        [fixture.principal_id, fixture.vault_id]
      )
    end)
  end

  defp update_account!(fixture, assignment) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE identity.accounts SET #{assignment} WHERE id = $1",
        [fixture.account_id]
      )
    end)
  end

  defp assert_datetime(actual, expected) do
    assert DateTime.compare(actual, expected) == :eq
  end

  defp uuid do
    Ecto.UUID.generate()
    |> Ecto.UUID.dump!()
  end
end
