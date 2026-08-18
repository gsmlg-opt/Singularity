defmodule Singularity.Runtime.AuthorizationTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Runtime.AuthorizationDependencies
  alias Singularity.Runtime.Authorize
  alias Singularity.Runtime.SessionContext

  defmodule Store do
    def load_live_session(context, _repo, session_id) do
      Agent.get(context, fn state ->
        case state.sessions[session_id] do
          nil -> {:ok, nil}
          live -> {:ok, live}
        end
      end)
    end

    def load_live_principal(context, _repo, principal_id, vault_id) do
      Agent.get(context, fn state ->
        case state.principals[{principal_id, vault_id}] do
          nil -> {:ok, nil}
          live -> {:ok, live}
        end
      end)
    end
  end

  defmodule Custodian do
    def assert_unlocked(
          context,
          session_id,
          principal_id,
          vault_id,
          principal_authorization_epoch,
          vault_authorization_epoch
        ) do
      Agent.get(context, fn state ->
        if MapSet.member?(
             state,
             {session_id, principal_id, vault_id, principal_authorization_epoch,
              vault_authorization_epoch}
           ) do
          :ok
        else
          {:error, Error.new(:vault_locked)}
        end
      end)
    end
  end

  @session_id "session-1"
  @principal_id "principal-1"
  @vault_id "vault-1"

  setup do
    live = live_session()

    store =
      start_agent!(fn ->
        %{
          sessions: %{@session_id => live},
          principals: %{
            {@principal_id, @vault_id} => Map.drop(live, [:session_id, :expires_at])
          }
        }
      end)

    custodian =
      start_agent!(fn ->
        MapSet.new([{@session_id, @principal_id, @vault_id, 7, 23}])
      end)

    dependencies = %AuthorizationDependencies{
      store: {Store, store},
      custodian: {Custodian, custodian}
    }

    {:ok, dependencies: dependencies, store: store, custodian: custodian}
  end

  test "reloads live session authority and accepts exact current bindings", %{
    dependencies: dependencies
  } do
    assert :ok =
             Authorize.check(
               dependencies,
               :repo,
               session(),
               requirement()
             )
  end

  test "plural requirements authorize only when every sorted unique capability is active", %{
    dependencies: dependencies,
    store: store
  } do
    requirement = plural_requirement(["asset.read", "vault.unlock"])

    assert :ok = Authorize.check(dependencies, :repo, session(), requirement)

    put_live(store, %{live_session() | capabilities: ["asset.read"]})

    assert {:error, %Error{code: :forbidden, retryable?: false}} =
             Authorize.check(dependencies, :repo, session(), requirement)
  end

  test "plural requirements retain principal membership and epoch revocation checks", %{
    dependencies: dependencies,
    store: store
  } do
    requirement = plural_requirement(["asset.read", "vault.unlock"])

    assert :ok = Authorize.check(dependencies, :repo, session(), requirement)

    for live <- [
          %{live_session() | principal_revoked_at: DateTime.utc_now()},
          %{live_session() | membership_revoked_at: DateTime.utc_now()},
          %{live_session() | principal_authorization_epoch: 8},
          %{live_session() | vault_authorization_epoch: 24}
        ] do
      put_live(store, live)

      assert {:error, %Error{code: :forbidden, retryable?: false}} =
               Authorize.check(dependencies, :repo, session(), requirement)
    end
  end

  test "plural requirements reject malformed and non-exclusive shapes as invalid", %{
    dependencies: dependencies
  } do
    base = requirement()

    malformed = [
      base |> Map.delete(:required_capability),
      base |> Map.delete(:required_capability) |> Map.put(:required_capabilities, []),
      base
      |> Map.delete(:required_capability)
      |> Map.put(:required_capabilities, ["vault.unlock", "asset.read"]),
      base
      |> Map.delete(:required_capability)
      |> Map.put(:required_capabilities, ["asset.read", "asset.read"]),
      base
      |> Map.delete(:required_capability)
      |> Map.put(:required_capabilities, ["asset.read", "  "]),
      base
      |> Map.delete(:required_capability)
      |> Map.put(:required_capabilities, ["asset.read", :vault_unlock]),
      Map.put(base, :required_capabilities, ["asset.read", "vault.unlock"])
    ]

    for requirement <- malformed do
      assert {:error, %Error{code: :invalid, retryable?: false}} =
               Authorize.check(dependencies, :repo, session(), requirement)
    end
  end

  test "singular request and job authorization contracts remain unchanged", %{
    dependencies: dependencies
  } do
    assert :ok = Authorize.check(dependencies, :repo, session(), requirement())

    legacy_requirement =
      requirement()
      |> Map.delete(:required_capability)
      |> Map.put(:capability, "asset.read")

    assert :ok = Authorize.check(dependencies, :repo, session(), legacy_requirement)

    for malformed <- [
          Map.put(requirement(), :required_capability, "  "),
          Map.put(requirement(), :required_capability, :asset_read)
        ] do
      assert {:error, %Error{code: :invalid}} =
               Authorize.check(dependencies, :repo, session(), malformed)
    end

    assert :ok =
             Authorize.check_job(dependencies, :repo, %{
               principal_id: @principal_id,
               vault_id: @vault_id,
               principal_authorization_epoch: 7,
               vault_authorization_epoch: 23,
               required_capability: "asset.read",
               classification: :sensitive
             })
  end

  test "rejects stale, revoked, cross-vault, capability, and classification state", %{
    dependencies: dependencies,
    store: store
  } do
    assert_denied(dependencies, store, fn live ->
      %{live | principal_id: "other-principal"}
    end)

    assert_denied(dependencies, store, fn live ->
      %{live | vault_id: "other-vault"}
    end)

    assert_denied(dependencies, store, fn live ->
      %{
        live
        | principal_authorization_epoch: live.principal_authorization_epoch + 1
      }
    end)

    assert_denied(dependencies, store, fn live ->
      %{
        live
        | vault_authorization_epoch: live.vault_authorization_epoch + 1
      }
    end)

    assert_denied(dependencies, store, fn live ->
      %{live | capabilities: []}
    end)

    assert_denied(dependencies, store, fn live ->
      %{live | clearance: :private}
    end)

    assert_denied(dependencies, store, fn live ->
      %{live | principal_revoked_at: DateTime.utc_now()}
    end)

    assert_denied(dependencies, store, fn live ->
      %{live | membership_revoked_at: DateTime.utc_now()}
    end)
  end

  test "missing, expired, or revoked sessions are unauthenticated", %{
    dependencies: dependencies,
    store: store
  } do
    Agent.update(store, &put_in(&1, [:sessions, @session_id], nil))

    assert {:error, %Error{code: :unauthenticated}} =
             Authorize.check(dependencies, :repo, session(), requirement())

    put_live(store, %{live_session() | expires_at: DateTime.add(DateTime.utc_now(), -1)})

    assert {:error, %Error{code: :unauthenticated}} =
             Authorize.check(dependencies, :repo, session(), requirement())

    put_live(store, %{live_session() | session_revoked_at: DateTime.utc_now()})

    assert {:error, %Error{code: :unauthenticated}} =
             Authorize.check(dependencies, :repo, session(), requirement())
  end

  test "normal operations require both live unlocked state and custody", %{
    dependencies: dependencies,
    store: store,
    custodian: custodian
  } do
    put_live(store, %{live_session() | vault_locked: true})

    assert {:error, %Error{code: :vault_locked}} =
             Authorize.check(dependencies, :repo, session(), requirement())

    put_live(store, live_session())

    Agent.update(
      custodian,
      &MapSet.delete(&1, {@session_id, @principal_id, @vault_id, 7, 23})
    )

    assert {:error, %Error{code: :vault_locked}} =
             Authorize.check(dependencies, :repo, session(), requirement())
  end

  test "key-establishing operations may explicitly bypass only the unlock check", %{
    dependencies: dependencies,
    store: store,
    custodian: custodian
  } do
    put_live(store, %{live_session() | vault_locked: true})

    Agent.update(
      custodian,
      &MapSet.delete(&1, {@session_id, @principal_id, @vault_id})
    )

    assert :ok =
             Authorize.check(
               dependencies,
               :repo,
               session(),
               requirement(requires_unlocked?: false)
             )
  end

  test "jobs bind both authorization epochs and reject revoke-regrant staleness", %{
    dependencies: dependencies,
    store: store
  } do
    envelope = %{
      principal_id: @principal_id,
      vault_id: @vault_id,
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 23,
      required_capability: "asset.read",
      classification: :sensitive
    }

    assert :ok = Authorize.check_job(dependencies, :repo, envelope)

    assert {:error, %Error{code: :forbidden}} =
             Authorize.check_job(
               dependencies,
               :repo,
               %{envelope | principal_authorization_epoch: 6}
             )

    principal =
      live_session()
      |> Map.drop([:session_id, :expires_at])
      |> Map.put(:principal_authorization_epoch, 8)

    put_principal(store, principal)

    assert {:error, %Error{code: :forbidden}} =
             Authorize.check_job(dependencies, :repo, envelope)

    current_principal =
      %{envelope | principal_authorization_epoch: 8}

    assert :ok =
             Authorize.check_job(dependencies, :repo, current_principal)

    put_principal(
      store,
      Map.put(principal, :principal_revoked_at, DateTime.utc_now())
    )

    assert {:error, %Error{code: :forbidden}} =
             Authorize.check_job(dependencies, :repo, envelope)

    regranted =
      principal
      |> Map.put(:principal_revoked_at, nil)
      |> Map.put(:principal_authorization_epoch, 9)

    put_principal(store, regranted)

    assert {:error, %Error{code: :forbidden}} =
             Authorize.check_job(dependencies, :repo, current_principal)

    current_principal =
      %{envelope | principal_authorization_epoch: 9}

    assert :ok =
             Authorize.check_job(dependencies, :repo, current_principal)

    changed_vault =
      regranted
      |> Map.put(:vault_authorization_epoch, 24)

    put_principal(store, changed_vault)

    assert {:error, %Error{code: :forbidden}} =
             Authorize.check_job(dependencies, :repo, current_principal)

    assert :ok =
             Authorize.check_job(
               dependencies,
               :repo,
               %{current_principal | vault_authorization_epoch: 24}
             )
  end

  test "system principals are restricted to named exact-operation job capabilities", %{
    dependencies: dependencies,
    store: store
  } do
    system_live =
      live_session()
      |> Map.drop([:session_id, :expires_at])
      |> Map.merge(%{
        principal_kind: :system,
        capabilities: [
          "maintenance.run",
          "integrity.audit",
          "object.cleanup",
          "asset.read"
        ]
      })

    Agent.update(
      store,
      &put_in(&1, [:principals, {@principal_id, @vault_id}], system_live)
    )

    base = %{
      principal_id: @principal_id,
      vault_id: @vault_id,
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 23,
      classification: :private
    }

    assert :ok =
             Authorize.check_job(
               dependencies,
               :repo,
               Map.merge(base, %{
                 job_type: "maintenance",
                 required_capability: "maintenance.run"
               })
             )

    assert :ok =
             Authorize.check_job(
               dependencies,
               :repo,
               Map.merge(base, %{
                 job_type: "object_cleanup",
                 required_capability: "object.cleanup"
               })
             )

    for denied <- [
          %{job_type: "maintenance", required_capability: "asset.read"},
          %{job_type: "asset_verify", required_capability: "asset.read"},
          %{job_type: "integrity_audit", required_capability: "maintenance.run"},
          %{job_type: "object_cleanup", required_capability: "asset.read"}
        ] do
      assert {:error, %Error{code: :forbidden}} =
               Authorize.check_job(
                 dependencies,
                 :repo,
                 Map.merge(base, denied)
               )
    end
  end

  test "owner principals cannot impersonate named system operations", %{
    dependencies: dependencies
  } do
    for {job_type, capability} <- [
          {"maintenance", "maintenance.run"},
          {"object_cleanup", "object.cleanup"}
        ] do
      assert {:error, %Error{code: :forbidden}} =
               Authorize.check_job(dependencies, :repo, %{
                 job_type: job_type,
                 principal_id: @principal_id,
                 vault_id: @vault_id,
                 principal_authorization_epoch: 7,
                 vault_authorization_epoch: 23,
                 required_capability: capability,
                 classification: :private
               })
    end
  end

  defp assert_denied(dependencies, store, update) do
    put_live(store, update.(live_session()))

    assert {:error, %Error{code: :forbidden}} =
             Authorize.check(dependencies, :repo, session(), requirement())
  end

  defp start_agent!(initial_state) do
    child_spec =
      Supervisor.child_spec(
        {Agent, initial_state},
        id: make_ref()
      )

    start_supervised!(child_spec)
  end

  defp put_live(store, live) do
    Agent.update(store, &put_in(&1, [:sessions, @session_id], live))
  end

  defp put_principal(store, live) do
    Agent.update(
      store,
      &put_in(&1, [:principals, {@principal_id, @vault_id}], live)
    )
  end

  defp session do
    %SessionContext{
      session_id: @session_id,
      account_id: "account-hint",
      principal_id: @principal_id,
      vault_id: @vault_id,
      expires_at: DateTime.add(DateTime.utc_now(), 300),
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 23,
      authorization_epoch: 7,
      unlocked?: true
    }
  end

  defp requirement(overrides \\ []) do
    Map.merge(
      %{
        vault_id: @vault_id,
        principal_authorization_epoch: 7,
        vault_authorization_epoch: 23,
        required_capability: "asset.read",
        classification: :sensitive,
        requires_unlocked?: true
      },
      Map.new(overrides)
    )
  end

  defp plural_requirement(capabilities, overrides \\ []) do
    overrides = Map.new(overrides)

    requirement()
    |> Map.delete(:required_capability)
    |> Map.put(:required_capabilities, capabilities)
    |> Map.merge(overrides)
  end

  defp live_session do
    %{
      session_id: @session_id,
      expires_at: DateTime.add(DateTime.utc_now(), 300),
      session_revoked_at: nil,
      principal_id: @principal_id,
      principal_kind: :owner,
      principal_revoked_at: nil,
      vault_id: @vault_id,
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 23,
      vault_locked: false,
      membership_revoked_at: nil,
      clearance: :restricted,
      capabilities: ["asset.read", "vault.unlock"]
    }
  end
end

defmodule Singularity.Runtime.OperationScopeTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Runtime.OperationScope

  defmodule Recorder do
    use Agent

    def start_link(_options), do: Agent.start_link(fn -> [] end)
    def record(agent, event), do: Agent.update(agent, &(&1 ++ [event]))
    def events(agent), do: Agent.get(agent, & &1)
  end

  defmodule RequestRepo do
    def checkout(recorder, callback) do
      Recorder.record(recorder, :checkout)
      callback.()
    end
  end

  defmodule VaultLock do
    def with_shared(recorder, _repo, _vault_id, callback) do
      around(recorder, :vault_shared, callback)
    end

    def with_exclusive(recorder, _repo, _vault_id, callback) do
      around(recorder, :vault_exclusive, callback)
    end

    defp around(recorder, kind, callback) do
      Recorder.record(recorder, {:acquire, kind})

      try do
        callback.(:pinned_repo)
      after
        Recorder.record(recorder, {:release, kind})
      end
    end
  end

  defmodule AuthorizationLock do
    def with_shared(recorder, _repo, _principal_id, _vault_id, callback) do
      around(recorder, :authorization_shared, callback)
    end

    def with_exclusive(recorder, _repo, _principal_id, _vault_id, callback) do
      around(recorder, :authorization_exclusive, callback)
    end

    defp around(recorder, kind, callback) do
      Recorder.record(recorder, {:acquire, kind})

      try do
        callback.(:pinned_repo)
      after
        Recorder.record(recorder, {:release, kind})
      end
    end
  end

  defmodule ScopedRepo do
    def transact(recorder, _repo, _scope, callback) do
      Recorder.record(recorder, :transaction_begin)
      result = callback.(:scoped_repo)

      case result do
        {:error, _reason} = error ->
          Recorder.record(recorder, :transaction_rollback)
          error

        success ->
          Recorder.record(recorder, :transaction_commit)
          success
      end
    end
  end

  defmodule Authorizer do
    def check(recorder, _repo, _session, _requirement) do
      Recorder.record(recorder, :authorize)
      :ok
    end
  end

  defmodule DenyingAuthorizer do
    def check(recorder, _repo, _session, _requirement) do
      Recorder.record(recorder, :authorize)
      {:error, Error.new(:forbidden)}
    end
  end

  defmodule MalformedAuthorizer do
    def check(recorder, _repo, _session, _requirement) do
      Recorder.record(recorder, :authorize)
      :malformed
    end
  end

  defmodule AuditSink do
    def append(recorder, repo, event) do
      Recorder.record(recorder, {:audit, repo, event})
      :ok
    end
  end

  setup do
    recorder = start_supervised!({Recorder, []})

    runtime = %{
      request_repo: {RequestRepo, recorder},
      vault_lock: {VaultLock, recorder},
      authorization_lock: {AuthorizationLock, recorder},
      scoped_repo: {ScopedRepo, recorder},
      authorizer: Authorizer,
      authorization: recorder,
      audit: {AuditSink, recorder}
    }

    session = %{
      session_id: "session-1",
      principal_id: "principal-1",
      vault_id: "vault-1",
      authorization_epoch: 1
    }

    {:ok, recorder: recorder, runtime: runtime, session: session}
  end

  test "shared mutation holds vault then authorization locks through after-commit work", %{
    recorder: recorder,
    runtime: runtime,
    session: session
  } do
    callback = fn run_scoped ->
      Recorder.record(recorder, :after_commit)

      run_scoped.(fn :scoped_repo ->
        Recorder.record(recorder, :after_commit_cas)
        {:ok, :activated}
      end)
    end

    assert {:ok, :activated} =
             OperationScope.with_shared_request(
               runtime,
               session,
               requirement(),
               fn :scoped_repo ->
                 Recorder.record(recorder, :effect)
                 {:after_commit_scoped, callback}
               end
             )

    assert Recorder.events(recorder) == [
             {:acquire, :vault_shared},
             {:acquire, :authorization_shared},
             :transaction_begin,
             :authorize,
             :effect,
             :transaction_commit,
             :after_commit,
             :transaction_begin,
             :after_commit_cas,
             :transaction_commit,
             {:release, :authorization_shared},
             {:release, :vault_shared}
           ]
  end

  test "after-commit failure rolls back its second scoped transaction while locks remain held", %{
    recorder: recorder,
    runtime: runtime,
    session: session
  } do
    assert {:error, %Error{code: :conflict}} =
             OperationScope.with_shared_request(
               runtime,
               session,
               requirement(),
               fn :scoped_repo ->
                 {:after_commit_scoped,
                  fn run_scoped ->
                    Recorder.record(recorder, :after_commit_failure)

                    run_scoped.(fn :scoped_repo ->
                      {:error, Error.new(:conflict)}
                    end)
                  end}
               end
             )

    assert Recorder.events(recorder) == [
             {:acquire, :vault_shared},
             {:acquire, :authorization_shared},
             :transaction_begin,
             :authorize,
             :transaction_commit,
             :after_commit_failure,
             :transaction_begin,
             :transaction_rollback,
             {:release, :authorization_shared},
             {:release, :vault_shared}
           ]
  end

  test "scoped compensation commits its state while returning the public error", %{
    recorder: recorder,
    runtime: runtime,
    session: session
  } do
    public_error = Error.new(:storage_unavailable, retryable?: true)

    assert {:error, ^public_error} =
             OperationScope.with_shared_request(
               runtime,
               session,
               requirement(),
               fn :scoped_repo ->
                 {:after_commit_scoped,
                  fn run_scoped ->
                    run_scoped.(fn :scoped_repo ->
                      Recorder.record(recorder, :compensate)
                      {:commit, {:error, public_error}}
                    end)
                  end}
               end
             )

    assert Enum.slice(Recorder.events(recorder), 5, 3) == [
             :transaction_begin,
             :compensate,
             :transaction_commit
           ]
  end

  test "zero-arity scoped after-commit callbacks are rejected instead of running unscoped", %{
    recorder: recorder,
    runtime: runtime,
    session: session
  } do
    assert {:error, %Error{code: :invalid}} =
             OperationScope.with_shared_request(
               runtime,
               session,
               requirement(),
               fn :scoped_repo ->
                 {:after_commit_scoped, fn -> Recorder.record(recorder, :unscoped) end}
               end
             )

    refute :unscoped in Recorder.events(recorder)
  end

  test "legacy zero-arity after-commit work remains outside a second transaction", %{
    recorder: recorder,
    runtime: runtime,
    session: session
  } do
    assert {:ok, :activated} =
             OperationScope.with_shared_request(
               runtime,
               session,
               requirement(),
               fn :scoped_repo ->
                 {:after_commit,
                  fn ->
                    Recorder.record(recorder, :legacy_after_commit)
                    {:ok, :activated}
                  end}
               end
             )

    assert Enum.count(Recorder.events(recorder), &(&1 == :transaction_begin)) == 1
    assert :legacy_after_commit in Recorder.events(recorder)
  end

  test "transaction denial never executes an after-commit callback", %{
    recorder: recorder,
    runtime: runtime,
    session: session
  } do
    assert {:error, %Error{code: :conflict}} =
             OperationScope.with_shared_request(
               runtime,
               session,
               requirement(),
               fn :scoped_repo -> {:error, Error.new(:conflict)} end
             )

    refute :after_commit in Recorder.events(recorder)
    assert :transaction_rollback in Recorder.events(recorder)
  end

  test "authorization denial appends in a second scoped transaction after rollback", %{
    recorder: recorder,
    runtime: runtime,
    session: session
  } do
    runtime = %{runtime | authorizer: DenyingAuthorizer}

    assert {:error, %Error{code: :forbidden}} =
             OperationScope.with_shared_request(
               runtime,
               session,
               requirement(),
               fn _repo ->
                 Recorder.record(recorder, :effect)
                 :ok
               end
             )

    refute :effect in Recorder.events(recorder)

    assert [
             {:acquire, :vault_shared},
             {:acquire, :authorization_shared},
             :transaction_begin,
             :authorize,
             :transaction_rollback,
             :transaction_begin,
             {:audit, :scoped_repo, event},
             :transaction_commit,
             {:release, :authorization_shared},
             {:release, :vault_shared}
           ] = Recorder.events(recorder)

    assert event.action == "authorization.denied"
    assert event.result == :denied
    assert event.principal_id == session.principal_id
    assert event.vault_id == session.vault_id
    assert event.target_type == "authorization"
    assert event.target_id == session.vault_id
  end

  test "malformed authorizer responses are storage failures, not unaudited denials", %{
    recorder: recorder,
    runtime: runtime,
    session: session
  } do
    runtime = %{runtime | authorizer: MalformedAuthorizer}

    assert {:error, %Error{code: :storage_unavailable, retryable?: true}} =
             OperationScope.with_shared_request(
               runtime,
               session,
               requirement(),
               fn _repo ->
                 Recorder.record(recorder, :effect)
                 :ok
               end
             )

    refute :effect in Recorder.events(recorder)
    refute Enum.any?(Recorder.events(recorder), &match?({:audit, _, _}, &1))
    assert :transaction_rollback in Recorder.events(recorder)
  end

  test "read scope skips the vault lock but pins checkout and authorization lock", %{
    recorder: recorder,
    runtime: runtime,
    session: session
  } do
    assert {:ok, :read} =
             OperationScope.with_read_request(
               runtime,
               session,
               requirement(),
               fn :scoped_repo -> {:ok, :read} end
             )

    assert Recorder.events(recorder) == [
             :checkout,
             {:acquire, :authorization_shared},
             :transaction_begin,
             :authorize,
             :transaction_commit,
             {:release, :authorization_shared}
           ]
  end

  test "exclusive mutation preserves the same global lock order", %{
    recorder: recorder,
    runtime: runtime,
    session: session
  } do
    assert :ok =
             OperationScope.with_exclusive_request(
               runtime,
               session,
               requirement(),
               fn :scoped_repo -> :ok end
             )

    assert Enum.take(Recorder.events(recorder), 2) == [
             {:acquire, :vault_exclusive},
             {:acquire, :authorization_exclusive}
           ]
  end

  test "a cross-vault requirement is audited under the session vault before any lock", %{
    recorder: recorder,
    runtime: runtime,
    session: session
  } do
    assert {:error, %Error{code: :invalid}} =
             OperationScope.with_shared_request(
               runtime,
               session,
               Map.put(requirement(), :vault_id, "other-vault"),
               fn _repo -> :ok end
             )

    assert [
             :checkout,
             :transaction_begin,
             {:audit, :scoped_repo, event},
             :transaction_commit
           ] = Recorder.events(recorder)

    assert event.action == "authorization.cross_vault_denied"
    assert event.result == :denied
    assert event.vault_id == session.vault_id
    assert event.target_type == "vault"
    assert event.target_id == session.vault_id
  end

  defp requirement do
    %{
      required_capability: "asset.write",
      classification: :private,
      requires_unlocked?: true
    }
  end
end
