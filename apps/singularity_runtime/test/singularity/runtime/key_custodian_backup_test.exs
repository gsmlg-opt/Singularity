defmodule Singularity.Runtime.KeyCustodianBackupTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Runtime.BackupKeyLease
  alias Singularity.Runtime.KeyCustodian
  alias Singularity.Runtime.KeyLeaseSupervisor
  alias Singularity.Storage.Crypto.ChunkedAEAD

  @now ~U[2026-08-10 08:00:00Z]
  @expires_at ~U[2026-08-10 08:05:00Z]
  @manifest_id "00000000-0000-4000-8000-000000001801"
  @other_manifest_id "00000000-0000-4000-8000-000000001802"
  @session_id "00000000-0000-4000-8000-000000001803"
  @principal_id "00000000-0000-4000-8000-000000001804"
  @vault_id "00000000-0000-4000-8000-000000001805"
  @derived_key :binary.copy(<<0xD8>>, 32)
  @vault_key :binary.copy(<<0xB8>>, 32)
  @kdf %{
    "domain" => "singularity.backup.bundle.v1",
    "parameters" => %{
      "m_cost" => 65_536,
      "parallelism" => 2,
      "t_cost" => 5,
      "version" => 4
    },
    "salt" => Base.encode64(:binary.copy(<<0x58>>, 16))
  }

  defmodule Clock do
    use Agent

    def start_link(now), do: Agent.start_link(fn -> now end)
    def utc_now(clock), do: Agent.get(clock, & &1)
    def put(clock, now), do: Agent.update(clock, fn _previous -> now end)
  end

  defmodule RecoveryWrapper do
    def wrap(owner, derived_key, vault_key, binding) do
      send(
        owner,
        {:recovery_wrap, self(), :crypto.hash(:sha256, derived_key),
         :crypto.hash(:sha256, vault_key), binding}
      )

      {:ok, "custodian-recovery-wrapper"}
    end
  end

  defmodule Unused do
    def load_object_key(_context, _binding, _hierarchy), do: {:error, :unused}
    def load_checkpoint(_context, _binding), do: {:error, :unused}
    def idle_lock(_owner, _session), do: :ok
  end

  setup do
    clock = start_supervised!({Clock, @now})
    lease_supervisor = start_supervised!({KeyLeaseSupervisor, name: nil}, id: make_ref())
    custodian = start_custodian(clock, lease_supervisor)
    assert :ok = unlock(custodian)

    {:ok, clock: clock, custodian: custodian, lease_supervisor: lease_supervisor}
  end

  test "prepares recovery metadata with the vault key already held in active custody", context do
    caller_session = request_session()
    refute Map.has_key?(caller_session, :vault_key)

    assert {:ok, %BackupKeyLease.Prepared{} = prepared} =
             KeyCustodian.prepare_backup_key(context.custodian, caller_session, derived())

    assert is_binary(prepared.opaque_ref)
    assert prepared.public_metadata == public_metadata("custodian-recovery-wrapper")

    assert_receive {:recovery_wrap, wrapper_process, derived_hash, vault_hash,
                    %{
                      label: :backup_recovery,
                      manifest_id: @manifest_id,
                      vault_id: @vault_id
                    }}

    assert wrapper_process == context.custodian
    assert derived_hash == :crypto.hash(:sha256, @derived_key)
    assert vault_hash == :crypto.hash(:sha256, @vault_key)

    assert KeyCustodian.backup_key_state(context.custodian) == %{
             active_refs: [],
             pending_refs: [prepared.opaque_ref]
           }

    refute secret_leaked?(prepared, [@derived_key, @vault_key])
  end

  test "rejects mismatched caller, custody, command, and manifest bindings without pending custody",
       context do
    cases = [
      {Map.put(request_session(), :session_id, "other-session"), derived()},
      {Map.put(request_session(), :principal_id, "other-principal"), derived()},
      {Map.put(request_session(), :vault_id, "other-vault"), derived()},
      {Map.put(request_session(), :principal_authorization_epoch, 8), derived()},
      {Map.put(request_session(), :vault_authorization_epoch, 12), derived()},
      {Map.put(request_session(), :expires_at, DateTime.add(@expires_at, 1)), derived()},
      {request_session(), derived_binding(:session_id, "other-session")},
      {request_session(), derived_binding(:principal_id, "other-principal")},
      {request_session(), derived_binding(:vault_id, "other-vault")},
      {request_session(), derived_binding(:principal_authorization_epoch, 8)},
      {request_session(), derived_binding(:vault_authorization_epoch, 12)},
      {request_session(), derived_binding(:expires_at, DateTime.add(@expires_at, 1))},
      {request_session(), mismatched_manifest_binding()},
      {request_session(), %{derived() | key_material: :binary.copy(<<0xD8>>, 31)}}
    ]

    for {caller_session, command} <- cases do
      assert {:error, %Error{code: :backup_invalid}} =
               KeyCustodian.prepare_backup_key(context.custodian, caller_session, command)

      assert KeyCustodian.backup_key_state(context.custodian) == %{
               active_refs: [],
               pending_refs: []
             }
    end

    refute_receive {:recovery_wrap, _, _, _, _}
  end

  test "rejects expired, actively revoked, and missing custody without installing a ref",
       context do
    Clock.put(context.clock, @expires_at)

    assert_backup_invalid(context.custodian)

    Clock.put(context.clock, @now)

    assert {:ok, token} =
             KeyCustodian.begin_revoke(context.custodian, %{session_id: @session_id})

    assert_backup_invalid(context.custodian)
    assert :ok = KeyCustodian.finish_revoke(context.custodian, token)

    missing = start_custodian(context.clock, context.lease_supervisor)
    assert_backup_invalid(missing)
  end

  defp assert_backup_invalid(custodian) do
    assert {:error, %Error{code: :backup_invalid}} =
             KeyCustodian.prepare_backup_key(custodian, request_session(), derived())

    assert KeyCustodian.backup_key_state(custodian) == %{active_refs: [], pending_refs: []}
    refute_receive {:recovery_wrap, _, _, _, _}
  end

  defp start_custodian(clock, lease_supervisor) do
    start_supervised!(
      {KeyCustodian,
       %{
         authorization: Unused,
         backup_cipher: ChunkedAEAD,
         backup_recovery_wrapper: {RecoveryWrapper, self()},
         clock: Clock,
         context: clock,
         idle_lock: {Unused, self()},
         key_reader: Unused,
         lease_supervisor: lease_supervisor,
         object_key_loader: Unused,
         wake_waiting: nil
       }},
      id: make_ref()
    )
  end

  defp unlock(custodian) do
    with {:ok, pending} <- KeyCustodian.prepare_unlock(custodian, custody_session()) do
      KeyCustodian.activate_unlock(custodian, pending)
    end
  end

  defp custody_session do
    request_session()
    |> Map.put(:vault_key, @vault_key)
  end

  defp request_session do
    %{
      expires_at: @expires_at,
      principal_authorization_epoch: 7,
      principal_id: @principal_id,
      session_id: @session_id,
      vault_authorization_epoch: 11,
      vault_id: @vault_id
    }
  end

  defp derived do
    %{
      __struct__: BackupKeyLease.Derived,
      binding: Map.put(request_session(), :manifest_id, @manifest_id),
      key_material: @derived_key,
      public_metadata: public_metadata(nil)
    }
  end

  defp public_metadata(wrapper) do
    %{
      "kdf" => @kdf,
      "recovery" => %{
        "binding" => %{
          "manifest_id" => @manifest_id,
          "vault_id" => @vault_id
        },
        "label" => "backup_recovery",
        "wrapper" => wrapper
      }
    }
  end

  defp derived_binding(field, value) do
    command = derived()
    %{command | binding: Map.put(command.binding, field, value)}
  end

  defp mismatched_manifest_binding do
    command = derived()
    recovery = command.public_metadata["recovery"]
    binding = Map.put(recovery["binding"], "manifest_id", @other_manifest_id)
    recovery = Map.put(recovery, "binding", binding)

    %{command | public_metadata: Map.put(command.public_metadata, "recovery", recovery)}
  end

  defp secret_leaked?(value, secrets) do
    encoded = :erlang.term_to_binary(value)
    Enum.any?(secrets, &(:binary.match(encoded, &1) != :nomatch))
  end
end
