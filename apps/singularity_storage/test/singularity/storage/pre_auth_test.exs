defmodule Singularity.Storage.PreAuthTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.Postgres.PreAuth

  setup do
    Fixtures.two_vaults!()
  end

  test "candidate and session functions return fixed minimal shapes without GUC context", %{
    one: one
  } do
    assert %{columns: candidate_columns, rows: [known]} =
             query!(
               PreAuthRepo,
               "SELECT * FROM identity.authentication_candidate($1)",
               [one.normalized_login]
             )

    assert candidate_columns == [
             "credential_id",
             "account_id",
             "verifier",
             "verifier_version"
           ]

    assert [one.credential_id, one.account_id, one.verifier, 1] == known

    assert %{columns: ^candidate_columns, rows: [[nil, nil, dummy_verifier, 1]]} =
             query!(
               PreAuthRepo,
               "SELECT * FROM identity.authentication_candidate($1)",
               ["unknown@example.test"]
             )

    assert is_binary(dummy_verifier)
    refute dummy_verifier == one.verifier

    assert %{
             columns: [
               "session_id",
               "principal_id",
               "vault_id",
               "expires_at",
               "principal_authorization_epoch",
               "vault_authorization_epoch"
             ],
             rows: [session]
           } =
             query!(
               PreAuthRepo,
               "SELECT * FROM identity.resolve_session($1)",
               [one.token_digest]
             )

    assert [
             session_id,
             principal_id,
             vault_id,
             _expires_at,
             principal_authorization_epoch,
             vault_authorization_epoch
           ] = session

    assert session_id == one.session_id
    assert principal_id == one.principal_id
    assert vault_id == one.vault_id
    assert principal_authorization_epoch == 0
    assert vault_authorization_epoch == 0
  end

  test "pre-auth cannot enumerate identity tables" do
    assert_raise Postgrex.Error, ~r/permission denied/, fn ->
      query!(PreAuthRepo, "SELECT id FROM identity.credentials")
    end

    assert_raise Postgrex.Error, ~r/permission denied/, fn ->
      query!(PreAuthRepo, "SELECT id FROM identity.sessions")
    end
  end

  test "disabled and unknown accounts have the same candidate shape", %{one: one} do
    Fixtures.disable_account!(one)

    assert %{columns: columns, rows: [disabled]} =
             query!(
               PreAuthRepo,
               "SELECT * FROM identity.authentication_candidate($1)",
               [one.normalized_login]
             )

    assert %{columns: ^columns, rows: [unknown]} =
             query!(
               PreAuthRepo,
               "SELECT * FROM identity.authentication_candidate($1)",
               ["unknown@example.test"]
             )

    assert [nil, nil, disabled_verifier, 1] = disabled
    assert [nil, nil, unknown_verifier, 1] = unknown
    assert disabled_verifier == unknown_verifier
  end

  test "attempt recording reserves a bucket and returns uniform failure shapes", %{one: one} do
    login_fingerprint = :crypto.hash(:sha256, one.normalized_login)
    source_fingerprint = :crypto.hash(:sha256, "127.0.0.1")
    known_correlation = Ecto.UUID.generate()

    assert %{columns: ["attempt_id", "accepted"], rows: [[started_id, true]]} =
             record_attempt_query(
               login_fingerprint,
               source_fingerprint,
               "started",
               known_correlation,
               nil
             )

    assert is_binary(started_id)

    assert %{columns: ["attempt_id", "accepted"], rows: [[^started_id, false]]} =
             record_attempt_query(
               login_fingerprint,
               source_fingerprint,
               "failed",
               known_correlation,
               started_id
             )

    unknown_login = :crypto.hash(:sha256, "unknown")
    unknown_correlation = Ecto.UUID.generate()

    assert %{rows: [[unknown_id, true]]} =
             record_attempt_query(
               unknown_login,
               source_fingerprint,
               "started",
               unknown_correlation,
               nil
             )

    assert %{columns: ["attempt_id", "accepted"], rows: [[^unknown_id, false]]} =
             record_attempt_query(
               unknown_login,
               source_fingerprint,
               "failed",
               unknown_correlation,
               unknown_id
             )
  end

  test "adapter persists supplied correlation and completes the reserved attempt", %{one: one} do
    login_fingerprint = :crypto.hash(:sha256, one.normalized_login)
    source_fingerprint = :crypto.hash(:sha256, "correlated-source")

    audit_fingerprint =
      :crypto.hash(:sha256, [login_fingerprint, source_fingerprint])

    correlation_id = Ecto.UUID.generate()

    assert {:ok, %{id: attempt_id, accepted?: true}} =
             PreAuth.reserve_attempt(PreAuthRepo, %{
               login_fingerprint: login_fingerprint,
               source_fingerprint: source_fingerprint,
               audit_fingerprint: audit_fingerprint,
               correlation_id: correlation_id
             })

    assert [^attempt_id, "started", ^correlation_id] =
             persisted_attempt(attempt_id)

    assert :ok =
             PreAuth.record_attempt(PreAuthRepo, %{
               attempt_id: attempt_id,
               login_fingerprint: login_fingerprint,
               source_fingerprint: source_fingerprint,
               audit_fingerprint: audit_fingerprint,
               correlation_id: correlation_id,
               result: "failed"
             })

    assert [^attempt_id, "failed", ^correlation_id] =
             persisted_attempt(attempt_id)

    assert [["anonymous", nil, ^audit_fingerprint, "denied"]] =
             persisted_attempt_audits(correlation_id)
  end

  test "failed outcomes retain the reserved attempt's rate-limit capacity" do
    Fixtures.set_auth_limits!(2, 2)

    on_exit(fn ->
      Fixtures.set_auth_limits!(5, 20)
    end)

    login_fingerprint = :crypto.hash(:sha256, "start-fail-cycle-login")
    source_fingerprint = :crypto.hash(:sha256, "start-fail-cycle-source")
    first_correlation = Ecto.UUID.generate()

    assert %{rows: [[first_started_id, true]]} =
             record_attempt_query(
               login_fingerprint,
               source_fingerprint,
               "started",
               first_correlation,
               nil
             )

    assert %{rows: [[^first_started_id, false]]} =
             record_attempt_query(
               login_fingerprint,
               source_fingerprint,
               "failed",
               first_correlation,
               first_started_id
             )

    assert %{rows: [[_second_started_id, true]]} =
             record_attempt_query(
               login_fingerprint,
               source_fingerprint,
               "started",
               Ecto.UUID.generate(),
               nil
             )

    assert %{rows: [[_limited_id, false]]} =
             record_attempt_query(
               login_fingerprint,
               source_fingerprint,
               "started",
               Ecto.UUID.generate(),
               nil
             )
  end

  test "concurrent started attempts atomically reserve the login bucket" do
    Fixtures.set_auth_limits!(1, 100)

    on_exit(fn ->
      Fixtures.set_auth_limits!(5, 20)
    end)

    login_fingerprint = :crypto.hash(:sha256, "concurrent-login")
    source_fingerprint = :crypto.hash(:sha256, "concurrent-source")
    parent = self()

    tasks =
      for _attempt <- 1..8 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go ->
              %{rows: [[_attempt_id, accepted?]]} =
                record_attempt_query(
                  login_fingerprint,
                  source_fingerprint,
                  "started",
                  Ecto.UUID.generate(),
                  nil
                )

              accepted?
          end
        end)
      end

    task_pids =
      for _attempt <- 1..8 do
        assert_receive {:ready, task_pid}
        task_pid
      end

    Enum.each(task_pids, &send(&1, :go))
    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.count(results, & &1) == 1
  end

  test "attempt recording rejects missing and malformed parameters before writing" do
    valid_fingerprint = :crypto.hash(:sha256, "valid")
    correlation_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()

    for {login_fingerprint, source_fingerprint, result} <- [
          {nil, valid_fingerprint, "started"},
          {valid_fingerprint, nil, "started"},
          {:binary.copy(<<0>>, 31), valid_fingerprint, "started"},
          {valid_fingerprint, :binary.copy(<<0>>, 31), "started"}
        ] do
      assert_raise Postgrex.Error, ~r/authentication fingerprints must be 32 bytes/, fn ->
        query!(
          PreAuthRepo,
          "SELECT * FROM identity.record_auth_attempt($1, $2, $3, $4, $5)",
          [
            login_fingerprint,
            source_fingerprint,
            result,
            correlation_id,
            nil
          ]
        )
      end
    end

    assert_raise Postgrex.Error, ~r/invalid authentication attempt result/, fn ->
      query!(
        PreAuthRepo,
        "SELECT * FROM identity.record_auth_attempt($1, $2, $3, $4, $5)",
        [
          valid_fingerprint,
          valid_fingerprint,
          nil,
          correlation_id,
          nil
        ]
      )
    end
  end

  defp record_attempt_query(
         login_fingerprint,
         source_fingerprint,
         result,
         correlation_id,
         attempt_id
       ) do
    query!(
      PreAuthRepo,
      "SELECT * FROM identity.record_auth_attempt($1, $2, $3, $4, $5)",
      [
        login_fingerprint,
        source_fingerprint,
        result,
        Ecto.UUID.dump!(correlation_id),
        attempt_id
      ]
    )
  end

  defp persisted_attempt(attempt_id) do
    Fixtures.with_owner(fn ->
      %{rows: [row]} =
        query!(
          MigrationRepo,
          """
          SELECT id::text, result, correlation_id::text
          FROM identity.auth_attempts
          WHERE id = $1
          """,
          [Ecto.UUID.dump!(attempt_id)]
        )

      row
    end)
  end

  defp persisted_attempt_audits(correlation_id) do
    Fixtures.with_owner(fn ->
      %{rows: rows} =
        query!(
          MigrationRepo,
          """
          SELECT actor_kind, vault_id, anonymous_fingerprint, result
          FROM audit.events
          WHERE correlation_id = $1
            AND operation = 'identity.authentication_attempt'
          ORDER BY result
          """,
          [Ecto.UUID.dump!(correlation_id)]
        )

      rows
    end)
  end
end
