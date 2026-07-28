defmodule Singularity.Runtime.AuditAcceptanceTest do
  use Singularity.Storage.DataCase, async: false

  alias Singularity.Core.AuditEvent
  alias Singularity.Core.Error
  alias Singularity.Runtime.AccessPolicy
  alias Singularity.Runtime.Audit
  alias Singularity.Runtime.AuthorizationDependencies
  alias Singularity.Runtime.Authorize
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.SessionContext
  alias Singularity.Storage.AuthorizationLock
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.Postgres.IdentityRepository
  alias Singularity.Storage.ScopedRepo
  alias Singularity.Storage.VaultLock

  @session_id "00000000-0000-4000-8000-000000001501"
  @principal_id "00000000-0000-4000-8000-000000001502"
  @target_principal_id "00000000-0000-4000-8000-000000001503"
  @vault_id "00000000-0000-4000-8000-000000001504"
  @correlation_id "00000000-0000-4000-8000-000000001505"
  @audit_event_id "00000000-0000-4000-8000-000000001506"

  @required_operations ~w[
    identity.login
    identity.authentication_attempt
    authorization.denied
    authorization.cross_vault_denied
    vault.unlock
    vault.lock
    asset.uploaded
    asset.verified
    asset.downloaded
    asset.sensitive_read
    asset.tombstoned
    asset.deleted
    object.deleted
    backup.requested
    backup.restore_completed
    integrity.audit_completed
    identity.password_change
    credential.rewrapped_after_restore
    vault.key_rotated
    domain.key_rotated
    authorization.capability_changed
    authorization.policy_changed
  ]

  @scenario_operations %{
    authentication: ~w[
      identity.login
      identity.authentication_attempt
    ],
    authorization: ~w[
      authorization.denied
      authorization.cross_vault_denied
    ],
    vault_access: ~w[
      vault.unlock
      vault.lock
    ],
    asset_lifecycle: ~w[
      asset.uploaded
      asset.verified
      asset.downloaded
      asset.sensitive_read
      asset.tombstoned
      asset.deleted
      object.deleted
    ],
    backup_restore: ~w[
      backup.requested
      backup.restore_completed
      integrity.audit_completed
      credential.rewrapped_after_restore
    ],
    key_management: ~w[
      identity.password_change
      vault.key_rotated
      domain.key_rotated
    ],
    policy: ~w[
      authorization.capability_changed
      authorization.policy_changed
    ]
  }

  defmodule AuditSink do
    def append(owner, repo, event) do
      send(owner, {:audit, repo, event})
      :ok
    end
  end

  defmodule FailingAuditSink do
    def append(:raise, _repo, _event), do: raise("CANARY_AUDIT_SINK_FAILURE")
    def append(:exit, _repo, _event), do: exit(:audit_sink_down)
  end

  defmodule Scope do
    def with_read_request(owner, runtime, session, requirement, callback) do
      send(owner, {:preflight_scope, runtime, session, requirement})
      callback.(:preflight_repo)
    end

    def with_exclusive_request(owner, runtime, session, requirement, callback) do
      send(owner, {:exclusive_scope, runtime, session, requirement})
      callback.(:scoped_repo)
    end
  end

  defmodule Custodian do
    def begin_revoke(owner, selector) do
      token = make_ref()
      send(owner, {:begin_revoke, selector, token})
      {:ok, token}
    end

    def await_revoking(owner, selector) do
      send(owner, {:await_revoking, selector})
      :ok
    end

    def finish_revoke(owner, token) do
      send(owner, {:finish_revoke, token})
      :ok
    end
  end

  defmodule PolicyRepository do
    def change_capability_and_audit(owner, repo, command) do
      send(owner, {:capability_change, repo, command})
      :ok
    end

    def change_clearance_and_audit(owner, repo, command) do
      send(owner, {:policy_change, repo, command})
      :ok
    end
  end

  defmodule AuthorizationCustodian do
    def assert_unlocked(
          _session_id,
          _principal_id,
          _vault_id,
          _principal_authorization_epoch,
          _vault_authorization_epoch
        ),
        do: :ok
  end

  test "production audit scenarios cover the exact required operation matrix" do
    covered =
      @scenario_operations
      |> Map.values()
      |> List.flatten()
      |> Enum.sort()

    assert covered == Enum.sort(@required_operations)
    assert length(covered) == 22
  end

  @tag :integration
  test "production authorization denials persist one complete immutable event" do
    %{one: raw_one, two: raw_two} = Fixtures.two_vaults!()
    one = load_fixture_ids(raw_one)
    two = load_fixture_ids(raw_two)
    live = load_live_session!(one)
    session = session_from_live(live)

    assert {:ok, authorization} =
             AuthorizationDependencies.new(%{
               store: IdentityRepository,
               custodian: AuthorizationCustodian
             })

    runtime = %{
      authorization: authorization,
      authorization_lock: AuthorizationLock,
      authorizer: Authorize,
      request_repo: RequestRepo,
      scoped_repo: ScopedRepo,
      vault_lock: VaultLock
    }

    denial_correlation_id = Ecto.UUID.generate()

    assert {:error, %Error{code: :forbidden}} =
             OperationScope.with_shared_request(
               runtime,
               session,
               %{
                 required_capability: "audit.matrix.missing",
                 classification: :private,
                 requires_unlocked?: false,
                 correlation_id: denial_correlation_id,
                 audit_target_type: "authorization",
                 audit_target_id: one.vault_id
               },
               fn _repo -> flunk("denied operation ran") end
             )

    Fixtures.with_owner(fn ->
      assert_persisted_audit!(
        MigrationRepo,
        "authorization.denied",
        [correlation_id: denial_correlation_id],
        result: "denied",
        actor_kind: "principal",
        principal_id: one.principal_id,
        vault_id: one.vault_id,
        target_type: "authorization",
        target_id: one.vault_id,
        metadata: %{}
      )
    end)

    assert {:error, %Error{code: :invalid}} =
             OperationScope.with_shared_request(
               runtime,
               session,
               %{
                 required_capability: "audit.matrix.missing",
                 classification: :private,
                 requires_unlocked?: false,
                 vault_id: two.vault_id
               },
               fn _repo -> flunk("cross-vault operation ran") end
             )

    Fixtures.with_owner(fn ->
      assert_persisted_audit!(
        MigrationRepo,
        "authorization.cross_vault_denied",
        [target_id: one.vault_id],
        result: "denied",
        actor_kind: "principal",
        principal_id: one.principal_id,
        vault_id: one.vault_id,
        target_type: "vault",
        target_id: one.vault_id,
        metadata: %{}
      )
    end)
  end

  test "principal audit events have the complete immutable shape and redact metadata first" do
    assert :ok =
             Audit.append_principal(
               {AuditSink, self()},
               :scoped_repo,
               session(),
               %{
                 audit_event_id: @audit_event_id,
                 action: "asset.downloaded",
                 result: :completed,
                 correlation_id: @correlation_id,
                 classification: :sensitive,
                 target_type: "asset",
                 target_id: @target_principal_id,
                 occurred_at: ~U[2026-07-27 09:10:11.123456Z],
                 metadata: %{
                   "range" => "all",
                   "password" => "CANARY_PASSWORD_8e4a"
                 }
               }
             )

    assert_receive {:audit, :scoped_repo, %AuditEvent{} = event}
    assert event.audit_event_id == @audit_event_id
    assert event.actor_kind == :principal
    assert event.principal_id == @principal_id
    assert event.vault_id == @vault_id
    assert event.action == "asset.downloaded"
    assert event.result == :completed
    assert event.correlation_id == @correlation_id
    assert event.classification == :sensitive
    assert event.target_type == "asset"
    assert event.target_id == @target_principal_id
    assert event.occurred_at == ~U[2026-07-27 09:10:11.123456Z]
    assert event.metadata == %{"range" => "all", "password" => "[REDACTED]"}
    assert actor_shape_count(event) == 1
  end

  test "anonymous and named-system builders enforce their distinct actor shapes" do
    attrs = %{
      audit_event_id: Ecto.UUID.generate(),
      action: "identity.authentication_attempt",
      result: :denied,
      correlation_id: Ecto.UUID.generate(),
      classification: :private,
      target_type: "authentication",
      target_id: Ecto.UUID.generate(),
      occurred_at: ~U[2026-07-27 09:10:11.123456Z],
      metadata: %{"token" => "CANARY_UPLOAD_TOKEN_6b21"}
    }

    fingerprint = :crypto.hash(:sha256, "anonymous")

    assert :ok =
             Audit.append_anonymous(
               {AuditSink, self()},
               :scoped_repo,
               fingerprint,
               attrs
             )

    assert_receive {:audit, :scoped_repo, %AuditEvent{} = anonymous}
    assert anonymous.actor_kind == :anonymous
    assert anonymous.anonymous_fingerprint == fingerprint
    assert anonymous.vault_id == nil
    assert anonymous.metadata == %{"token" => "[REDACTED]"}
    assert actor_shape_count(anonymous) == 1

    assert :ok =
             Audit.append_system(
               {AuditSink, self()},
               :scoped_repo,
               "object_cleanup",
               @vault_id,
               %{
                 attrs
                 | audit_event_id: Ecto.UUID.generate(),
                   action: "object.deleted",
                   result: :completed,
                   target_type: "object"
               }
             )

    assert_receive {:audit, :scoped_repo, %AuditEvent{} = system}
    assert system.actor_kind == :system
    assert system.system_principal_name == "object_cleanup"
    assert system.vault_id == @vault_id
    assert system.metadata == %{"token" => "[REDACTED]"}
    assert actor_shape_count(system) == 1
  end

  test "audit sink exceptions and exits fail as retryable storage errors" do
    attrs = %{
      audit_event_id: @audit_event_id,
      action: "asset.downloaded",
      result: :completed,
      correlation_id: @correlation_id,
      classification: :sensitive,
      target_type: "asset",
      target_id: @target_principal_id,
      occurred_at: ~U[2026-07-27 09:10:11.123456Z],
      metadata: %{}
    }

    for mode <- [:raise, :exit] do
      assert {:error, %{code: :storage_unavailable, retryable?: true} = error} =
               Audit.append_principal(
                 {FailingAuditSink, mode},
                 :scoped_repo,
                 session(),
                 attrs
               )

      refute inspect(error) =~ "CANARY_AUDIT_SINK_FAILURE"
      refute inspect(error) =~ "audit_sink_down"
    end
  end

  test "capability and policy changes revoke vault custody before exclusive persistence" do
    runtime = %{
      operation_scope: {Scope, self()},
      custodian: {Custodian, self()},
      policies: {PolicyRepository, self()}
    }

    assert :ok =
             AccessPolicy.change_capability(
               runtime,
               session(),
               @target_principal_id,
               "asset.read",
               :revoke,
               @correlation_id
             )

    assert_receive {:preflight_scope, ^runtime, _session, preflight_requirement}
    assert preflight_requirement.required_capability == "vault.password_change"
    assert preflight_requirement.classification == :restricted
    assert preflight_requirement.requires_unlocked?
    assert preflight_requirement.correlation_id == @correlation_id
    assert preflight_requirement.audit_target_type == "principal"
    assert preflight_requirement.audit_target_id == @target_principal_id

    assert_receive {:begin_revoke, %{vault_id: @vault_id}, revoke_token}
    assert_receive {:await_revoking, %{vault_id: @vault_id}}

    assert_receive {:exclusive_scope, ^runtime, _session, persist_requirement}
    assert persist_requirement.required_capability == "vault.password_change"
    assert persist_requirement.classification == :restricted
    refute persist_requirement.requires_unlocked?
    assert persist_requirement.correlation_id == @correlation_id
    assert persist_requirement.audit_target_type == "principal"
    assert persist_requirement.audit_target_id == @target_principal_id

    assert_receive {:capability_change, :scoped_repo, capability_command}
    assert capability_command.actor_principal_id == @principal_id
    assert capability_command.target_principal_id == @target_principal_id
    assert capability_command.vault_id == @vault_id
    assert capability_command.capability == "asset.read"
    assert capability_command.change == :revoke
    assert capability_command.correlation_id == @correlation_id
    assert_receive {:finish_revoke, ^revoke_token}

    assert :ok =
             AccessPolicy.change_clearance(
               runtime,
               session(),
               @target_principal_id,
               :sensitive,
               @correlation_id
             )

    assert_receive {:preflight_scope, ^runtime, _session, ^preflight_requirement}
    assert_receive {:begin_revoke, %{vault_id: @vault_id}, policy_revoke_token}
    assert_receive {:await_revoking, %{vault_id: @vault_id}}
    assert_receive {:exclusive_scope, ^runtime, _session, ^persist_requirement}
    assert_receive {:policy_change, :scoped_repo, policy_command}
    assert policy_command.actor_principal_id == @principal_id
    assert policy_command.target_principal_id == @target_principal_id
    assert policy_command.vault_id == @vault_id
    assert policy_command.clearance == :sensitive
    assert policy_command.correlation_id == @correlation_id
    assert_receive {:finish_revoke, ^policy_revoke_token}
  end

  test "administrative mutation inputs fail closed before entering the scope" do
    runtime = %{
      operation_scope: {Scope, self()},
      custodian: {Custodian, self()},
      policies: {PolicyRepository, self()}
    }

    assert {:error, %{code: :invalid}} =
             AccessPolicy.change_capability(
               runtime,
               session(),
               "not-a-uuid",
               "asset.read",
               :grant,
               @correlation_id
             )

    assert {:error, %{code: :invalid}} =
             AccessPolicy.change_clearance(
               runtime,
               session(),
               @target_principal_id,
               :top_secret,
               @correlation_id
             )

    refute_received {:preflight_scope, _, _, _}
    refute_received {:exclusive_scope, _, _, _}
    refute_received {:begin_revoke, _, _}
  end

  defp session do
    %SessionContext{
      session_id: @session_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      expires_at: DateTime.add(DateTime.utc_now(), 600, :second),
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 11,
      authorization_epoch: 7,
      unlocked?: true
    }
  end

  defp load_live_session!(fixture) do
    assert {:ok, live} =
             RequestRepo.checkout(fn ->
               ScopedRepo.transact(
                 RequestRepo,
                 %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
                 &IdentityRepository.load_live_session(&1, fixture.session_id)
               )
             end)

    live
  end

  defp session_from_live(live) do
    %SessionContext{
      session_id: live.session_id,
      account_id: live.account_id,
      principal_id: live.principal_id,
      vault_id: live.vault_id,
      expires_at: live.session_expires_at,
      principal_authorization_epoch: live.principal_authorization_epoch,
      vault_authorization_epoch: live.vault_authorization_epoch,
      authorization_epoch: live.principal_authorization_epoch,
      unlocked?: false
    }
  end

  defp load_fixture_ids(fixture) do
    Map.new(fixture, fn
      {key, value}
      when key in [
             :account_id,
             :asset_id,
             :credential_id,
             :principal_id,
             :resource_id,
             :resource_version_id,
             :session_id,
             :vault_id
           ] ->
        {key, Ecto.UUID.load!(value)}

      pair ->
        pair
    end)
  end

  defp actor_shape_count(event) do
    [
      event.actor_kind == :principal and is_binary(event.principal_id) and
        is_binary(event.vault_id),
      event.actor_kind == :system and is_binary(event.system_principal_name) and
        is_binary(event.vault_id),
      event.actor_kind == :anonymous and is_binary(event.anonymous_fingerprint) and
        is_nil(event.vault_id)
    ]
    |> Enum.count(& &1)
  end
end
