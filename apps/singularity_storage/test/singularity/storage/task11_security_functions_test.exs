defmodule Singularity.Storage.Task11SecurityFunctionsTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Ecto.Adapters.SQL
  alias Singularity.Core.Error
  alias Singularity.Storage.Crypto.Argon2PasswordHasher
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.Postgres.IdentityRepository
  alias Singularity.Storage.Postgres.PreAuth
  alias Singularity.Storage.ScopedRepo

  @session_fields [
    :session_id,
    :account_id,
    :session_expires_at,
    :session_revoked_at,
    :credential_id,
    :credential_revision,
    :principal_id,
    :principal_kind,
    :principal_authorization_epoch,
    :principal_revoked_at,
    :vault_id,
    :vault_authorization_epoch,
    :vault_locked,
    :membership_revoked_at,
    :clearance,
    :capabilities
  ]

  @principal_fields [
    :principal_id,
    :principal_kind,
    :principal_authorization_epoch,
    :principal_revoked_at,
    :vault_id,
    :vault_authorization_epoch,
    :vault_locked,
    :membership_revoked_at,
    :clearance,
    :capabilities
  ]

  setup do
    Fixtures.two_vaults!()
  end

  test "web session and worker principal snapshots are independently scoped", %{
    one: one,
    two: two
  } do
    assert {:ok, session} = scoped(one, &session_snapshot(&1, one.session_id))
    assert session.session_id == load_uuid(one.session_id)
    assert session.account_id == load_uuid(one.account_id)
    assert session.credential_id == load_uuid(one.credential_id)
    assert session.principal_id == load_uuid(one.principal_id)
    assert session.vault_id == load_uuid(one.vault_id)
    assert %DateTime{} = session.credential_revision

    assert {:ok, nil} = scoped(two, &session_snapshot(&1, one.session_id))

    assert {:ok, principal} = scoped(one, &principal_snapshot/1)
    assert principal.principal_id == load_uuid(one.principal_id)
    assert principal.vault_id == load_uuid(one.vault_id)
    refute Map.has_key?(principal, :session_id)
    refute Map.has_key?(principal, :account_id)
    refute Map.has_key?(principal, :credential_id)
  end

  test "identity repository maps split snapshots and credential CAS", %{
    one: one,
    two: two
  } do
    session_id = load_uuid(one.session_id)
    principal_id = load_uuid(one.principal_id)
    vault_id = load_uuid(one.vault_id)

    assert {:ok, session} =
             scoped(one, &IdentityRepository.load_live_session(&1, session_id))

    assert Enum.sort(Map.keys(session)) == Enum.sort(@session_fields)
    assert session.session_id == session_id
    assert session.account_id == load_uuid(one.account_id)
    assert session.credential_id == load_uuid(one.credential_id)
    assert session.principal_id == principal_id
    assert session.vault_id == vault_id
    assert session.principal_kind == :owner
    assert session.clearance == :private
    assert session.capabilities == []

    assert {:ok, nil} =
             scoped(two, &IdentityRepository.load_live_session(&1, session_id))

    assert {:ok, principal} =
             scoped(
               one,
               &IdentityRepository.load_live_principal(&1, principal_id, vault_id)
             )

    assert Enum.sort(Map.keys(principal)) == Enum.sort(@principal_fields)
    assert principal.principal_id == principal_id
    assert principal.vault_id == vault_id
    assert principal.principal_kind == :owner
    assert principal.clearance == :private
    assert principal.capabilities == []

    assert {:ok, nil} =
             scoped(
               one,
               &IdentityRepository.load_live_principal(
                 &1,
                 load_uuid(two.principal_id),
                 load_uuid(two.vault_id)
               )
             )

    assert {:ok, true} =
             scoped(
               one,
               &IdentityRepository.update_credential_verifier(
                 &1,
                 session.session_id,
                 session.credential_id,
                 session.credential_revision,
                 "repository-verifier"
               )
             )

    assert credential_verifier(one) == "repository-verifier"

    assert {:ok, false} =
             scoped(
               one,
               &IdentityRepository.update_credential_verifier(
                 &1,
                 session.session_id,
                 session.credential_id,
                 session.credential_revision,
                 "stale-repository-verifier"
               )
             )

    assert {:error, %Error{code: :invalid}} =
             scoped(one, &IdentityRepository.load_live_session(&1, "invalid"))

    assert {:error, %Error{code: :invalid}} =
             scoped(
               one,
               &IdentityRepository.load_live_principal(&1, "invalid", vault_id)
             )

    assert {:error, %Error{code: :invalid}} =
             scoped(
               one,
               &IdentityRepository.update_credential_verifier(
                 &1,
                 session.session_id,
                 session.credential_id,
                 nil,
                 "invalid-revision"
               )
             )
  end

  test "snapshots expose every live denial state and remove revoked capabilities", %{one: one} do
    capability_id =
      Fixtures.with_owner(fn ->
        %{rows: [[capability_id]]} =
          query!(
            MigrationRepo,
            """
            INSERT INTO core.capabilities (id, name)
            VALUES ($1, 'asset.read')
            ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name
            RETURNING id
            """,
            [Ecto.UUID.generate() |> Ecto.UUID.dump!()]
          )

        capability_id
      end)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO core.principal_capabilities (
          principal_id,
          vault_id,
          capability_id
        ) VALUES ($1, $2, $3)
        """,
        [one.principal_id, one.vault_id, capability_id]
      )
    end)

    assert {:ok, %{capabilities: ["asset.read"]}} =
             scoped(one, &session_snapshot(&1, one.session_id))

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE identity.sessions SET revoked_at = CURRENT_TIMESTAMP WHERE id = $1",
        [one.session_id]
      )

      query!(
        MigrationRepo,
        """
        UPDATE identity.principals
        SET revoked_at = CURRENT_TIMESTAMP, authorization_epoch = 4
        WHERE id = $1
        """,
        [one.principal_id]
      )

      query!(
        MigrationRepo,
        """
        UPDATE core.vaults
        SET locked = false, authorization_epoch = 7
        WHERE id = $1
        """,
        [one.vault_id]
      )

      query!(
        MigrationRepo,
        """
        UPDATE core.vault_members
        SET revoked_at = CURRENT_TIMESTAMP
        WHERE principal_id = $1 AND vault_id = $2
        """,
        [one.principal_id, one.vault_id]
      )

      query!(
        MigrationRepo,
        """
        UPDATE core.principal_capabilities
        SET revoked_at = CURRENT_TIMESTAMP
        WHERE principal_id = $1 AND vault_id = $2 AND capability_id = $3
        """,
        [one.principal_id, one.vault_id, capability_id]
      )
    end)

    assert {:ok, snapshot} = scoped(one, &session_snapshot(&1, one.session_id))
    assert %DateTime{} = snapshot.session_revoked_at
    assert %DateTime{} = snapshot.principal_revoked_at
    assert %DateTime{} = snapshot.membership_revoked_at
    assert snapshot.principal_authorization_epoch == 4
    assert snapshot.vault_authorization_epoch == 7
    refute snapshot.vault_locked
    assert snapshot.capabilities == []
  end

  test "disabled accounts invalidate opaque sessions and both authorization snapshots", %{
    one: one
  } do
    Fixtures.disable_account!(one)

    assert {:ok, nil} = PreAuth.resolve_session(PreAuthRepo, one.token_digest)
    assert {:ok, nil} = scoped(one, &session_snapshot(&1, one.session_id))
    assert {:ok, nil} = scoped(one, &principal_snapshot/1)
  end

  test "credential CAS is scoped and denied after principal revocation", %{
    one: one,
    two: two
  } do
    assert {:ok, one_snapshot} = scoped(one, &session_snapshot(&1, one.session_id))
    assert {:ok, two_snapshot} = scoped(two, &session_snapshot(&1, two.session_id))

    assert {:ok, true} =
             scoped(one, fn repo ->
               update_verifier(
                 repo,
                 one.session_id,
                 one_snapshot.credential_id,
                 one_snapshot.credential_revision,
                 "new-verifier"
               )
             end)

    assert credential_verifier(one) == "new-verifier"

    assert {:ok, false} =
             scoped(one, fn repo ->
               update_verifier(
                 repo,
                 one.session_id,
                 two_snapshot.credential_id,
                 two_snapshot.credential_revision,
                 "stolen-verifier"
               )
             end)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE identity.principals SET revoked_at = CURRENT_TIMESTAMP WHERE id = $1",
        [two.principal_id]
      )
    end)

    assert {:ok, false} =
             scoped(two, fn repo ->
               update_verifier(
                 repo,
                 two.session_id,
                 two_snapshot.credential_id,
                 two_snapshot.credential_revision,
                 "revoked-verifier"
               )
             end)
  end

  test "credential CAS is denied after membership revocation", %{one: one} do
    assert {:ok, snapshot} = scoped(one, &session_snapshot(&1, one.session_id))

    Fixtures.revoke_membership!(one)

    assert {:ok, false} =
             scoped(one, fn repo ->
               update_verifier(
                 repo,
                 one.session_id,
                 snapshot.credential_id,
                 snapshot.credential_revision,
                 "membership-revoked-verifier"
               )
             end)

    assert credential_verifier(one) == one.verifier
  end

  test "credential CAS definer requires the exact active scoped session", %{
    one: one,
    two: two
  } do
    assert {:ok, snapshot} = scoped(one, &session_snapshot(&1, one.session_id))

    for denied_session <- [two.session_id, Ecto.UUID.generate() |> Ecto.UUID.dump!()] do
      assert {:ok, false} =
               scoped(one, fn repo ->
                 update_verifier_for_session(
                   repo,
                   denied_session,
                   snapshot.credential_id,
                   snapshot.credential_revision,
                   "session-bypass-verifier"
                 )
               end)
    end

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE identity.sessions
        SET expires_at = CURRENT_TIMESTAMP - INTERVAL '1 second'
        WHERE id = $1
        """,
        [one.session_id]
      )
    end)

    assert {:ok, false} =
             scoped(one, fn repo ->
               update_verifier_for_session(
                 repo,
                 one.session_id,
                 snapshot.credential_id,
                 snapshot.credential_revision,
                 "expired-session-verifier"
               )
             end)

    assert credential_verifier(one) == one.verifier
  end

  test "credential update rolls back with the enclosing scoped transaction", %{one: one} do
    assert {:ok, snapshot} = scoped(one, &session_snapshot(&1, one.session_id))

    assert {:error, :injected_rollback} =
             scoped(one, fn repo ->
               assert {:ok, true} =
                        update_verifier(
                          repo,
                          one.session_id,
                          snapshot.credential_id,
                          snapshot.credential_revision,
                          "rolled-back-verifier"
                        )

               repo.rollback(:injected_rollback)
             end)

    assert credential_verifier(one) == one.verifier
  end

  test "concurrent credential revisions permit exactly one winner", %{one: one} do
    assert {:ok, snapshot} = scoped(one, &session_snapshot(&1, one.session_id))
    parent = self()

    tasks =
      for replacement <- ["first-winner", "second-winner"] do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go ->
              scoped(one, fn repo ->
                update_verifier(
                  repo,
                  one.session_id,
                  snapshot.credential_id,
                  snapshot.credential_revision,
                  replacement
                )
              end)
          end
        end)
      end

    pids =
      for _task <- tasks do
        assert_receive {:ready, pid}
        pid
      end

    Enum.each(pids, &send(&1, :go))

    results = Enum.map(tasks, &Task.await(&1, 5_000))
    assert Enum.sort(results) == [{:ok, false}, {:ok, true}]
    assert credential_verifier(one) in ["first-winner", "second-winner"]
  end

  test "dummy verifier matches the fixed Task 11 Argon2 profile" do
    verifier =
      Fixtures.with_owner(fn ->
        %{rows: [[verifier]]} =
          query!(
            MigrationRepo,
            """
            SELECT dummy_verifier
            FROM identity.security_settings
            WHERE singleton
            """
          )

        verifier
      end)

    params = %{version: 1, t_cost: 3, m_cost: 16, parallelism: 1}

    assert {:ok, false} =
             Argon2PasswordHasher.verify(params, "not-the-dummy-password", verifier)
  end

  test "runtime roles retain no direct identity table access", %{one: one} do
    assert_raise Postgrex.Error, ~r/permission denied for table credentials/, fn ->
      query!(RequestRepo, "SELECT verifier FROM identity.credentials")
    end

    assert_raise Postgrex.Error, ~r/permission denied for table principals/, fn ->
      query!(RequestRepo, "SELECT revoked_at FROM identity.principals")
    end

    assert {:ok, nil} = scoped(one, fn _repo -> {:ok, nil} end)
  end

  test "function ownership, execute matrix, and schema ACLs remain least privilege" do
    rows =
      Fixtures.with_owner(fn ->
        %{rows: rows} =
          query!(
            MigrationRepo,
            """
            SELECT
              namespace.nspname,
              procedure.proname,
              owner.rolname,
              procedure.prosecdef,
              procedure.proconfig,
              has_function_privilege('public', procedure.oid, 'EXECUTE'),
              has_function_privilege('singularity_web', procedure.oid, 'EXECUTE'),
              has_function_privilege('singularity_worker', procedure.oid, 'EXECUTE'),
              has_function_privilege('singularity_pre_auth', procedure.oid, 'EXECUTE')
            FROM pg_catalog.pg_proc AS procedure
            JOIN pg_catalog.pg_namespace AS namespace
              ON namespace.oid = procedure.pronamespace
            JOIN pg_catalog.pg_roles AS owner ON owner.oid = procedure.proowner
            WHERE procedure.proname IN (
              'live_session_authorization',
              'live_principal_authorization',
              'update_scoped_credential_verifier'
            )
            ORDER BY procedure.proname
            """
          )

        rows
      end)

    assert [
             [
               "core",
               "live_principal_authorization",
               "singularity_authorization_definer",
               true,
               ["search_path=pg_catalog, identity, core"],
               false,
               true,
               true,
               false
             ],
             [
               "core",
               "live_session_authorization",
               "singularity_authorization_definer",
               true,
               ["search_path=pg_catalog, identity, core"],
               false,
               true,
               false,
               false
             ],
             [
               "identity",
               "update_scoped_credential_verifier",
               "singularity_authorization_definer",
               true,
               ["search_path=pg_catalog, identity, core"],
               false,
               true,
               false,
               false
             ]
           ] = rows

    Fixtures.with_owner(fn ->
      %{rows: [[identity_create, core_create, membership_preexisting, clearance_added]]} =
        query!(
          MigrationRepo,
          """
          SELECT
            has_schema_privilege(
              'singularity_authorization_definer',
              'identity',
              'CREATE'
            ),
            has_schema_privilege(
              'singularity_authorization_definer',
              'core',
              'CREATE'
            ),
            has_column_privilege(
              'singularity_authorization_definer',
              'core.vault_members',
              'principal_id',
              'SELECT'
            ),
            has_column_privilege(
              'singularity_authorization_definer',
              'core.vault_members',
              'clearance',
              'SELECT'
            )
          """
        )

      refute identity_create
      refute core_create
      assert membership_preexisting
      assert clearance_added
    end)

    migration =
      File.read!(
        Path.expand(
          "../../../priv/repo/migrations/20260718000800_add_task11_authorization_functions.exs",
          __DIR__
        )
      )

    assert migration =~ "REVOKE SELECT (clearance)"
    refute migration =~ "REVOKE SELECT (principal_id, vault_id, clearance, revoked_at)"
    assert migration =~ "REVOKE USAGE ON SCHEMA identity"
    refute migration =~ "REVOKE USAGE ON SCHEMA identity, core"
  end

  defp scoped(fixture, fun) do
    RequestRepo.checkout(fn ->
      ScopedRepo.transact(
        RequestRepo,
        %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
        fun
      )
    end)
  end

  defp session_snapshot(repo, session_id) do
    query_snapshot(
      repo,
      "SELECT * FROM core.live_session_authorization($1)",
      [session_id],
      @session_fields
    )
  end

  defp principal_snapshot(repo) do
    query_snapshot(
      repo,
      "SELECT * FROM core.live_principal_authorization()",
      [],
      @principal_fields
    )
  end

  defp query_snapshot(repo, statement, parameters, fields) do
    case SQL.query(repo, statement, parameters, log: false) do
      {:ok, %{rows: []}} ->
        {:ok, nil}

      {:ok, %{columns: columns, rows: [row]}} ->
        assert columns == Enum.map(fields, &Atom.to_string/1)

        {:ok,
         fields
         |> Enum.zip(row)
         |> Map.new()
         |> load_uuids()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_verifier(repo, session_id, credential_id, revision, replacement),
    do:
      update_verifier_for_session(
        repo,
        session_id,
        credential_id,
        revision,
        replacement
      )

  defp update_verifier_for_session(
         repo,
         session_id,
         credential_id,
         revision,
         replacement
       ) do
    case SQL.query(
           repo,
           """
           SELECT identity.update_scoped_credential_verifier($1, $2, $3, $4)
           """,
           [session_id, Ecto.UUID.dump!(credential_id), revision, replacement],
           log: false
         ) do
      {:ok, %{rows: [[updated?]]}} -> {:ok, updated?}
      {:error, reason} -> {:error, reason}
    end
  end

  defp credential_verifier(fixture) do
    Fixtures.with_owner(fn ->
      %{rows: [[verifier]]} =
        query!(
          MigrationRepo,
          "SELECT verifier FROM identity.credentials WHERE id = $1",
          [fixture.credential_id]
        )

      verifier
    end)
  end

  defp load_uuids(snapshot) do
    Enum.reduce(
      [:session_id, :account_id, :credential_id, :principal_id, :vault_id],
      snapshot,
      fn field, acc ->
        if Map.has_key?(acc, field) do
          Map.update!(acc, field, fn
            nil -> nil
            value -> load_uuid(value)
          end)
        else
          acc
        end
      end
    )
  end

  defp load_uuid(value), do: Ecto.UUID.load!(value)
end
