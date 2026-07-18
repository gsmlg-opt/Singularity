defmodule Singularity.Runtime.LoginTest.PreAuth do
  def reserve_attempt(owner, command) do
    send(owner, {:pre_auth, :reserve_attempt, command})
    {:ok, %{id: "attempt-1", accepted?: Process.get(:attempt_accepted, true)}}
  end

  def authentication_candidate(owner, normalized_login) do
    send(owner, {:pre_auth, :authentication_candidate, normalized_login})

    if normalized_login == "owner@example.test" do
      {:ok,
       %{
         verifier: "known-verifier",
         scoped_context: %{
           account_id: "account-1",
           principal_id: "principal-1",
           vault_id: "vault-1"
         }
       }}
    else
      {:ok, %{verifier: "dummy-verifier", scoped_context: nil}}
    end
  end

  def record_attempt(owner, command) do
    send(owner, {:pre_auth, :record_attempt, command})
    Process.get(:record_attempt_result, :ok)
  end
end

defmodule Singularity.Runtime.LoginTest.PasswordHasher do
  def verify(owner, password, verifier) do
    send(owner, {:password_verify, password, verifier})
    {:ok, password == "correct-password" and verifier == "known-verifier"}
  end
end

defmodule Singularity.Runtime.LoginTest.Identity do
  def create_session_and_audit(owner, scoped_context, command, options) do
    send(owner, {:identity, :create_session_and_audit, scoped_context, command, options})

    case Process.get(:session_audit_result, :ok) do
      :ok ->
        {:ok,
         %{
           id: "session-1",
           account_id: scoped_context.account_id,
           principal_id: scoped_context.principal_id,
           vault_id: scoped_context.vault_id,
           token_digest: command.token_digest
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

defmodule Singularity.Runtime.LoginTest.SessionResolver do
  def resolve_session(owner, digest) do
    send(owner, {:resolve_session, digest})

    {:ok,
     %{
       session_id: "session-1",
       principal_id: "principal-1",
       vault_id: "vault-1",
       expires_at: ~U[2026-07-19 00:00:00Z],
       principal_authorization_epoch: 11,
       vault_authorization_epoch: 17
     }}
  end
end

defmodule Singularity.Runtime.LoginTest.Custodian do
  def unlocked?(owner, session_id) do
    send(owner, {:custodian_unlocked, session_id})
    false
  end
end

defmodule Singularity.Runtime.LoginTest do
  use ExUnit.Case, async: false

  alias Singularity.Core.Error
  alias Singularity.Runtime.Login
  alias Singularity.Runtime.ResolveSession
  alias Singularity.Runtime.SessionContext

  @fingerprint_secret "CANARY_AUDIT_FINGERPRINT_SECRET_32_BYTES"
  @opaque_token "CANARY_OPAQUE_SESSION_TOKEN_32B!"

  setup do
    adapters = %{
      pre_auth: Singularity.Runtime.LoginTest.PreAuth,
      pre_auth_context: self(),
      identity: Singularity.Runtime.LoginTest.Identity,
      identity_context: self(),
      password_hasher: Singularity.Runtime.LoginTest.PasswordHasher,
      password_hasher_context: self(),
      audit_fingerprint_secret: @fingerprint_secret,
      random_bytes: fn 32 -> @opaque_token end
    }

    {:ok, adapters: adapters}
  end

  @tag :integration
  test "PostgreSQL login atomically persists a digest-only session and allowed audit" do
    login = "login-#{Ecto.UUID.generate()}@example.test"
    password = "database-login-password"
    bootstrap = postgres_bootstrap_adapters()

    assert {:ok, owner} =
             Singularity.Storage.Fixtures.with_owner(fn ->
               Singularity.Runtime.BootstrapOwner.run(bootstrap, %{
                 display_name: "Login Owner",
                 login: login,
                 password: password
               })
             end)

    token = :binary.copy(<<0xD3>>, 32)

    adapters = %{
      pre_auth: Singularity.Storage.Postgres.PreAuth,
      pre_auth_context: Singularity.Storage.PreAuthRepo,
      identity: Singularity.Storage.Postgres.IdentityRepository,
      identity_context: %{
        repo: Singularity.Storage.RequestRepo,
        clock: fn -> DateTime.utc_now() end,
        session_ttl_seconds: 900
      },
      password_hasher: Singularity.Storage.Crypto.Argon2PasswordHasher,
      password_hasher_context: password_params(),
      audit_fingerprint_secret: :binary.copy(<<0xA7>>, 32),
      random_bytes: fn 32 -> token end
    }

    assert {:ok, result} =
             Login.run(adapters, request(login, password, "127.0.0.1"))

    assert result.opaque_token == token
    assert result.session.account_id == owner.account_id
    assert result.session.principal_id == owner.principal_id
    assert result.session.vault_id == owner.vault_id

    Singularity.Storage.Fixtures.with_owner(fn ->
      %{rows: [[stored_digest, session_count, audit_count]]} =
        Ecto.Adapters.SQL.query!(
          Singularity.Storage.MigrationRepo,
          """
          SELECT
            (SELECT token_digest FROM identity.sessions WHERE id = $1),
            (SELECT count(*) FROM identity.sessions WHERE id = $1),
            (SELECT count(*) FROM audit.events
             WHERE operation = 'identity.login'
               AND result = 'allowed'
               AND principal_id = $2
               AND vault_id = $3)
          """,
          [
            Ecto.UUID.dump!(result.session.id),
            Ecto.UUID.dump!(owner.principal_id),
            Ecto.UUID.dump!(owner.vault_id)
          ],
          log: false
        )

      assert stored_digest == :crypto.hash(:sha256, token)
      assert session_count == 1
      assert audit_count == 1
    end)
  end

  test "reserves rate limit before verifier work and persists only sanitized commands", %{
    adapters: adapters
  } do
    request = request(" Owner@Example.Test ", "wrong-password", " 127.0.0.1 ")

    assert {:error, %Error{code: :unauthenticated}} = Login.run(adapters, request)

    assert_receive {:pre_auth, :reserve_attempt, reserve}
    assert_receive {:pre_auth, :authentication_candidate, "owner@example.test"}
    assert_receive {:password_verify, "wrong-password", "known-verifier"}
    assert_receive {:pre_auth, :record_attempt, failure}

    assert map_size(reserve) == 3
    assert map_size(failure) == 5
    assert byte_size(reserve.login_fingerprint) == 32
    assert byte_size(reserve.source_fingerprint) == 32
    assert reserve.login_fingerprint != reserve.source_fingerprint
    assert failure.login_fingerprint == reserve.login_fingerprint
    assert failure.source_fingerprint == reserve.source_fingerprint
    assert failure.result == "failed"

    sanitized = inspect([reserve, failure])
    refute sanitized =~ request.password
    refute sanitized =~ @fingerprint_secret
    refute sanitized =~ request.login
    refute sanitized =~ request.source
  end

  test "unknown and wrong credentials have one public result and constant verifier shape", %{
    adapters: adapters
  } do
    unknown = Login.run(adapters, request("missing@example.test", "wrong-password", "source"))
    assert_receive {:pre_auth, :reserve_attempt, _}
    assert_receive {:pre_auth, :authentication_candidate, "missing@example.test"}
    assert_receive {:password_verify, "wrong-password", "dummy-verifier"}
    assert_receive {:pre_auth, :record_attempt, unknown_audit}

    invalid = Login.run(adapters, request("owner@example.test", "wrong-password", "source"))
    assert_receive {:pre_auth, :reserve_attempt, _}
    assert_receive {:pre_auth, :authentication_candidate, "owner@example.test"}
    assert_receive {:password_verify, "wrong-password", "known-verifier"}
    assert_receive {:pre_auth, :record_attempt, invalid_audit}

    assert unknown == {:error, Error.new(:unauthenticated)}
    assert invalid == unknown

    assert Map.keys(unknown_audit) |> Enum.sort() ==
             Map.keys(invalid_audit) |> Enum.sort()
  end

  test "successful login stores only a token digest and emits an opaque cookie payload", %{
    adapters: adapters
  } do
    assert {:ok, result} =
             Login.run(
               adapters,
               request("owner@example.test", "correct-password", "source")
             )

    assert_receive {:pre_auth, :reserve_attempt, _}
    assert_receive {:pre_auth, :authentication_candidate, "owner@example.test"}
    assert_receive {:password_verify, "correct-password", "known-verifier"}

    assert_receive {
      :identity,
      :create_session_and_audit,
      scoped_context,
      command,
      [audit_result: "allowed"]
    }

    assert scoped_context == %{
             account_id: "account-1",
             principal_id: "principal-1",
             vault_id: "vault-1"
           }

    assert command.token_digest == :crypto.hash(:sha256, @opaque_token)
    refute inspect(command) =~ @opaque_token
    refute Map.has_key?(result.session, :unlocked?)
    assert result.opaque_token == @opaque_token

    assert %{"session" => encoded} = Login.cookie_payload(result)
    assert {:ok, @opaque_token} == Base.url_decode64(encoded, padding: false)
    assert map_size(Login.cookie_payload(result)) == 1
  end

  test "successful-auth audit failure creates no public session", %{adapters: adapters} do
    Process.put(:session_audit_result, {:error, :audit_failed})

    assert {:error, %Error{code: :unauthenticated}} =
             Login.run(
               adapters,
               request("owner@example.test", "correct-password", "source")
             )

    assert_receive {:identity, :create_session_and_audit, _, _, _}
    refute_receive {:session_issued, _}
  end

  test "anonymous audit failure never permits login or changes its response", %{
    adapters: adapters
  } do
    Process.put(:record_attempt_result, {:error, :audit_failed})

    assert Login.run(
             adapters,
             request("missing@example.test", "wrong-password", "source")
           ) == {:error, Error.new(:unauthenticated)}
  end

  test "rejected reservation performs no verifier work", %{adapters: adapters} do
    Process.put(:attempt_accepted, false)

    assert {:error, %Error{code: :unauthenticated}} =
             Login.run(
               adapters,
               request("owner@example.test", "correct-password", "source")
             )

    assert_receive {:pre_auth, :reserve_attempt, _}
    refute_receive {:pre_auth, :authentication_candidate, _}
    refute_receive {:password_verify, _, _}
  end

  test "fingerprint labels produce independent HMAC buckets" do
    fingerprints =
      Login.fingerprints(
        @fingerprint_secret,
        "owner@example.test",
        "owner@example.test"
      )

    assert byte_size(fingerprints.login) == 32
    assert byte_size(fingerprints.source) == 32
    refute fingerprints.login == fingerprints.source
  end

  test "opaque resolution hashes the token and returns only a locked identity hint" do
    token = :binary.copy(<<0xB4>>, 32)

    adapters = %{
      pre_auth: Singularity.Runtime.LoginTest.SessionResolver,
      pre_auth_context: self(),
      custodian: Singularity.Runtime.LoginTest.Custodian,
      custodian_context: self()
    }

    assert {:ok,
            %SessionContext{
              session_id: "session-1",
              principal_id: "principal-1",
              vault_id: "vault-1",
              principal_authorization_epoch: 11,
              vault_authorization_epoch: 17,
              authorization_epoch: 11,
              unlocked?: false
            }} = ResolveSession.run(adapters, token)

    assert_receive {:resolve_session, digest}
    assert digest == :crypto.hash(:sha256, token)
    assert_receive {:custodian_unlocked, "session-1"}
  end

  defp request(login, password, source) do
    %{
      login: login,
      password: password,
      source: source,
      correlation_id: "00000000-0000-0000-0000-000000000111"
    }
  end

  defp postgres_bootstrap_adapters do
    %{
      repository: Singularity.Storage.Postgres.IdentityRepository,
      repository_context: Singularity.Storage.MigrationRepo,
      password_hasher: Singularity.Storage.Crypto.Argon2PasswordHasher,
      password_hasher_context: password_params(),
      key_deriver: Singularity.Storage.Crypto.Argon2KeyDeriver,
      key_wrapper: Singularity.Storage.Crypto.KeyWrapper,
      id_generator: &Ecto.UUID.generate/0,
      random_bytes: &:crypto.strong_rand_bytes/1,
      vault_kdf_params: password_params(),
      initial_capabilities: ["asset.read", "asset.write", "vault.unlock"]
    }
  end

  defp password_params do
    %{version: 1, t_cost: 1, m_cost: 8, parallelism: 1}
  end
end
