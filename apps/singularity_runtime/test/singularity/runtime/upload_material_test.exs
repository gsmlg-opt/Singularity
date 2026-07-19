defmodule Singularity.Runtime.UploadMaterialTest do
  use ExUnit.Case, async: false

  alias Singularity.Core.Error
  alias Singularity.Runtime.KeyCustodian
  alias Singularity.Runtime.KeyLeaseSupervisor
  alias Singularity.Storage.Crypto.KeyWrapper

  @session_id "00000000-0000-4000-8000-000000000201"
  @principal_id "00000000-0000-4000-8000-000000000202"
  @vault_id "00000000-0000-4000-8000-000000000203"
  @grant_id "00000000-0000-4000-8000-000000000204"
  @asset_id "00000000-0000-4000-8000-000000000205"
  @key_domain_id "00000000-0000-4000-8000-000000000206"
  @domain_key_version_id "00000000-0000-4000-8000-000000000207"
  @domain_key :binary.copy(<<0xA1>>, 32)
  @domain_dedup_key :binary.copy(<<0xB2>>, 32)

  defmodule Adapter do
    def utc_now(_context), do: DateTime.utc_now()
    def idle_lock(_session), do: :ok
    def revalidate(_context, _binding), do: :ok

    def load_checkpoint(_context, _binding),
      do: {:error, Singularity.Core.Error.new(:conflict)}

    def load_object_key(_context, _binding, _hierarchy), do: {:error, :waiting_for_unlock}
  end

  defmodule ExactStageReconciler do
    def reconcile_stage(
          %{attempts: attempts, test: test},
          recovery,
          reason
        ) do
      attempt =
        Agent.get_and_update(attempts, fn current ->
          {current + 1, current + 1}
        end)

      send(
        test,
        {:exact_stage_recovery_started, self(), attempt, recovery, reason}
      )

      receive do
        {:release_exact_stage_recovery, ^attempt} ->
          if attempt == 1 do
            {:error,
             Singularity.Core.Error.new(
               :storage_unavailable,
               retryable?: true
             )}
          else
            {:ok,
             %{
               stage_id: recovery.stage_id,
               state: :abandoned,
               state_revision: 1
             }}
          end
      end
    end
  end

  defmodule TerminalConflictReconciler do
    def reconcile_stage(%{test: test}, recovery, reason) do
      send(
        test,
        {:terminal_conflict_recovery, self(), recovery, reason}
      )

      {:error, Singularity.Core.Error.new(:conflict)}
    end
  end

  defmodule IdleAdapter do
    def idle_lock(%{attempts: attempts, test: test}, session) do
      attempt =
        Agent.get_and_update(attempts, fn current ->
          {current + 1, current + 1}
        end)

      send(test, {:idle_lock_attempted, attempt, session})

      if attempt == 1 do
        {:error,
         Singularity.Core.Error.new(
           :storage_unavailable,
           retryable?: true
         )}
      else
        :ok
      end
    end
  end

  setup do
    lease_supervisor = start_supervised!(KeyLeaseSupervisor)

    recovery_supervisor =
      start_supervised!(
        {Task.Supervisor, name: nil},
        id: make_ref()
      )

    custodian =
      start_supervised!(
        {KeyCustodian,
         %{
           authorization: Adapter,
           clock: Adapter,
           context: %{},
           idle_lock: Adapter,
           key_reader: Adapter,
           object_key_loader: Adapter,
           key_wrapper: KeyWrapper,
           lease_supervisor: lease_supervisor,
           upload_recovery_supervisor: recovery_supervisor,
           pending_ttl_ms: 500,
           upload_material_ttl_ms: 500
         }}
      )

    assert {:ok, pending} =
             KeyCustodian.prepare_unlock(custodian, unlocked_session())

    assert :ok = KeyCustodian.activate_unlock(custodian, pending)

    {:ok,
     custodian: custodian,
     lease_supervisor: lease_supervisor,
     recovery_supervisor: recovery_supervisor}
  end

  test "issues an opaque one-time upload material reference and reveals keys only on exact claim",
       %{custodian: custodian} do
    assert {:ok, prepared} =
             KeyCustodian.prepare_upload(custodian, upload_request())

    assert is_reference(prepared.material_ref)
    assert is_binary(prepared.stage_id)
    assert is_binary(prepared.candidate_object_id)
    assert prepared.storage_ref == prepared.stage_id
    assert prepared.key_domain_id == @key_domain_id
    assert prepared.domain_key_version_id == @domain_key_version_id
    assert prepared.key_generation == 3
    assert prepared.wrapper_algorithm == "aes_256_gcm"
    assert is_binary(prepared.dek_wrapper)

    refute Map.has_key?(prepared, :object_dek)
    refute Map.has_key?(prepared, :domain_dedup_key)
    refute inspect(prepared) =~ Base.encode16(@domain_dedup_key)

    assert {:error, %Error{code: :conflict}} =
             KeyCustodian.claim_upload(
               custodian,
               prepared.material_ref,
               %{
                 claim_request(prepared)
                 | asset_id: Ecto.UUID.generate()
               }
             )

    assert {:error, %Error{code: :conflict}} =
             KeyCustodian.claim_upload(
               custodian,
               prepared.material_ref,
               %{
                 claim_request(prepared)
                 | stage_id: Ecto.UUID.generate()
               }
             )

    assert {:error, %Error{code: :conflict}} =
             KeyCustodian.claim_upload(
               custodian,
               prepared.material_ref,
               %{
                 claim_request(prepared)
                 | storage_ref: Ecto.UUID.generate()
               }
             )

    assert {:ok, material} =
             KeyCustodian.claim_upload(
               custodian,
               prepared.material_ref,
               claim_request(prepared)
             )

    assert <<_::binary-size(32)>> = material.object_dek
    assert material.domain_dedup_key == @domain_dedup_key
    object_dek = material.object_dek

    assert {:ok, ^object_dek} =
             KeyWrapper.unwrap(@domain_key, prepared.dek_wrapper, %{
               purpose: :object_dek,
               generation: 3,
               aad: "object:" <> prepared.candidate_object_id
             })

    assert {:error, %Error{code: :conflict}} =
             KeyCustodian.claim_upload(
               custodian,
               prepared.material_ref,
               claim_request(prepared)
             )
  end

  test "revocation destroys unclaimed upload material", %{custodian: custodian} do
    assert {:ok, prepared} =
             KeyCustodian.prepare_upload(custodian, upload_request())

    assert {:ok, token} =
             KeyCustodian.begin_revoke(custodian, %{vault_id: @vault_id})

    assert {:error, %Error{code: :conflict}} =
             KeyCustodian.claim_upload(
               custodian,
               prepared.material_ref,
               upload_request()
             )

    assert :ok = KeyCustodian.finish_revoke(custodian, token)
  end

  test "authenticated terminal upload evidence releases custody before owner DOWN", %{
    custodian: custodian
  } do
    assert {:ok, prepared} =
             KeyCustodian.prepare_upload(custodian, upload_request())

    test = self()

    upload =
      spawn(fn ->
        assert {:ok, material} =
                 KeyCustodian.claim_upload(
                   custodian,
                   prepared.material_ref,
                   claim_request(prepared)
                 )

        send(test, {:terminal_upload_claimed, self(), material.custody_ref})

        receive do
          :report_sealed ->
            send(
              custodian,
              {:upload_terminal, self(), material.custody_ref, :sealed}
            )
        end

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:terminal_upload_claimed, ^upload, custody_ref}
    assert Map.has_key?(:sys.get_state(custodian).uploads, upload)

    send(upload, :report_sealed)

    assert_eventually(fn ->
      not Map.has_key?(
        :sys.get_state(custodian).uploads,
        upload
      )
    end)

    assert Process.alive?(upload)
    send(upload, :stop)
    assert is_reference(custody_ref)
  end

  test "revocation synchronously terminates an upload that claimed key material", %{
    custodian: custodian
  } do
    assert {:ok, prepared} =
             KeyCustodian.prepare_upload(custodian, upload_request())

    test = self()

    upload =
      spawn(fn ->
        result =
          KeyCustodian.claim_upload(
            custodian,
            prepared.material_ref,
            claim_request(prepared)
          )

        send(test, {:upload_claimed, self(), result})

        case result do
          {:ok, material} ->
            receive do
              {:custody_revoke, custody_ref, revocation_ref, ^custodian}
              when custody_ref == material.custody_ref ->
                send(
                  custodian,
                  {:custody_revoke_result, self(), custody_ref, revocation_ref, :ok}
                )
            end

          _error ->
            :ok
        end
      end)

    monitor = Process.monitor(upload)

    assert_receive {:upload_claimed, ^upload, {:ok, material}}
    assert <<_::binary-size(32)>> = material.object_dek

    assert {:ok, token} =
             KeyCustodian.begin_revoke(custodian, %{session_id: @session_id})

    assert_receive {:DOWN, ^monitor, :process, ^upload, :normal}

    assert :ok =
             KeyCustodian.await_revoking(
               custodian,
               %{session_id: @session_id}
             )

    assert :ok = KeyCustodian.finish_revoke(custodian, token)
  end

  test "revocation cannot deadlock behind a claimed upload waiting on assert_unlocked", %{
    custodian: custodian
  } do
    assert {:ok, prepared} =
             KeyCustodian.prepare_upload(custodian, upload_request())

    test = self()

    upload =
      spawn(fn ->
        assert {:ok, material} =
                 KeyCustodian.claim_upload(
                   custodian,
                   prepared.material_ref,
                   claim_request(prepared)
                 )

        writer =
          spawn(fn ->
            send(test, {:key_worker_ready, self(), material.object_dek})
            Process.sleep(:infinity)
          end)

        send(
          test,
          {:upload_claim_ready, self(), writer, material.custody_ref}
        )

        receive do
          :attach_worker ->
            assert :ok =
                     KeyCustodian.attach_upload_worker(
                       custodian,
                       material.custody_ref,
                       writer
                     )

            cooperative_upload_loop(
              custodian,
              material.custody_ref,
              writer,
              test
            )
        end
      end)

    upload_monitor = Process.monitor(upload)
    assert_receive {:upload_claim_ready, ^upload, writer, _custody_ref}
    writer_monitor = Process.monitor(writer)
    assert_receive {:key_worker_ready, ^writer, <<_::binary-size(32)>>}

    :ok = :sys.suspend(custodian)
    on_exit(fn -> resume_if_suspended(custodian) end)

    revocation =
      Task.async(fn ->
        KeyCustodian.begin_revoke(custodian, %{session_id: @session_id})
      end)

    assert_queued_call(custodian, :begin_revoke)
    send(upload, :attach_worker)
    assert_queued_call(custodian, :attach_upload_worker)

    assertion =
      Task.async(fn ->
        KeyCustodian.assert_unlocked(
          custodian,
          @session_id,
          @principal_id,
          @vault_id,
          7,
          11
        )
      end)

    assert_queued_call(custodian, :assert_unlocked)

    :ok = :sys.resume(custodian)

    assert {:ok, token} = Task.await(revocation, 1_000)

    assert {:error, %Error{code: :vault_locked}} =
             Task.await(assertion, 1_000)

    assert_receive {:DOWN, ^upload_monitor, :process, ^upload, :normal}
    assert_receive {:DOWN, ^writer_monitor, :process, ^writer, :killed}

    assert :ok =
             KeyCustodian.await_revoking(
               custodian,
               %{session_id: @session_id}
             )

    assert :ok = KeyCustodian.finish_revoke(custodian, token)
  end

  test "timeout recovers only the claimed stage and keeps revocation pending across retry", %{
    lease_supervisor: lease_supervisor,
    recovery_supervisor: recovery_supervisor
  } do
    attempts =
      start_supervised!(
        {Agent, fn -> 0 end},
        id: make_ref()
      )

    custodian =
      start_supervised!(
        {KeyCustodian,
         custodian_options(lease_supervisor,
           upload_reconciler: ExactStageReconciler,
           upload_recovery: %{
             attempts: attempts,
             test: self()
           },
           upload_recovery_supervisor: recovery_supervisor,
           upload_revoke_retry_ms: 50,
           upload_revoke_timeout_ms: 25
         )},
        id: make_ref()
      )

    unlock!(custodian)

    assert {:ok, prepared} =
             KeyCustodian.prepare_upload(custodian, upload_request())

    test = self()

    upload =
      spawn(fn ->
        assert {:ok, material} =
                 KeyCustodian.claim_upload(
                   custodian,
                   prepared.material_ref,
                   claim_request(prepared)
                 )

        writer = spawn(fn -> Process.sleep(:infinity) end)

        assert :ok =
                 KeyCustodian.attach_upload_worker(
                   custodian,
                   material.custody_ref,
                   writer
                 )

        send(test, {:uncooperative_upload_ready, self(), writer})
        Process.sleep(:infinity)
      end)

    upload_monitor = Process.monitor(upload)
    assert_receive {:uncooperative_upload_ready, ^upload, writer}
    writer_monitor = Process.monitor(writer)

    revocation =
      Task.async(fn ->
        KeyCustodian.begin_revoke(custodian, %{session_id: @session_id})
      end)

    expected_recovery = %{
      stage_id: prepared.stage_id,
      storage_ref: prepared.storage_ref
    }

    assert_receive {:exact_stage_recovery_started, first_recovery, 1, ^expected_recovery,
                    :custody_revoked}

    responsiveness =
      Task.async(fn ->
        KeyCustodian.unlocked?(
          custodian,
          Ecto.UUID.generate()
        )
      end)

    refute Task.await(responsiveness, 100)
    send(first_recovery, {:release_exact_stage_recovery, 1})

    refute Task.yield(revocation, 0)
    assert_receive {:DOWN, ^upload_monitor, :process, ^upload, :killed}
    assert_receive {:DOWN, ^writer_monitor, :process, ^writer, :killed}

    assert_receive {:exact_stage_recovery_started, second_recovery, 2, ^expected_recovery,
                    :custody_revoked}

    send(second_recovery, {:release_exact_stage_recovery, 2})

    assert {:ok, token} = Task.await(revocation, 1_000)
    assert :ok = KeyCustodian.finish_revoke(custodian, token)
  end

  test "terminal recovery conflict reports failure and leaves the selector fail-closed", %{
    lease_supervisor: lease_supervisor,
    recovery_supervisor: recovery_supervisor
  } do
    custodian =
      start_supervised!(
        {KeyCustodian,
         custodian_options(lease_supervisor,
           upload_reconciler: TerminalConflictReconciler,
           upload_recovery: %{test: self()},
           upload_recovery_supervisor: recovery_supervisor,
           upload_revoke_retry_ms: 25,
           upload_revoke_timeout_ms: 25
         )},
        id: make_ref()
      )

    unlock!(custodian)

    assert {:ok, prepared} =
             KeyCustodian.prepare_upload(custodian, upload_request())

    test = self()

    upload =
      spawn(fn ->
        assert {:ok, material} =
                 KeyCustodian.claim_upload(
                   custodian,
                   prepared.material_ref,
                   claim_request(prepared)
                 )

        writer = spawn(fn -> Process.sleep(:infinity) end)

        assert :ok =
                 KeyCustodian.attach_upload_worker(
                   custodian,
                   material.custody_ref,
                   writer
                 )

        send(test, {:terminal_conflict_upload_ready, self()})
        Process.sleep(:infinity)
      end)

    assert_receive {:terminal_conflict_upload_ready, ^upload}

    assert {:error, %Error{code: :conflict, retryable?: false}} =
             KeyCustodian.begin_revoke(
               custodian,
               %{session_id: @session_id}
             )

    assert_receive {:terminal_conflict_recovery, _task, recovery, :custody_revoked}

    assert recovery == %{
             stage_id: prepared.stage_id,
             storage_ref: prepared.storage_ref
           }

    refute_receive {:terminal_conflict_recovery, _task, _recovery, _reason}, 100

    assert_eventually(fn ->
      state = :sys.get_state(custodian)

      state.revocation_waiters == %{} and
        state.upload_revocations == %{} and
        state.uploads == %{}
    end)

    state = :sys.get_state(custodian)

    assert [{failed_gate, %{session_id: @session_id}}] =
             Map.to_list(state.revoking)

    assert is_reference(failed_gate)

    assert {:error, %Error{code: :vault_locked}} =
             KeyCustodian.assert_unlocked(
               custodian,
               @session_id,
               @principal_id,
               @vault_id,
               7,
               11
             )

    assert {:error, :waiting_for_unlock} =
             KeyCustodian.lease(custodian, lease_request())

    assert {:error, %Error{code: :vault_locked}} =
             KeyCustodian.prepare_upload(
               custodian,
               upload_request()
             )

    assert {:error, %Error{code: :conflict}} =
             KeyCustodian.prepare_unlock(
               custodian,
               unlocked_session()
             )

    refute Process.alive?(upload)
  end

  test "caller death keeps cleanup gated and removes the orphaned token after recovery", %{
    lease_supervisor: lease_supervisor,
    recovery_supervisor: recovery_supervisor
  } do
    attempts =
      start_supervised!(
        {Agent, fn -> 0 end},
        id: make_ref()
      )

    custodian =
      start_supervised!(
        {KeyCustodian,
         custodian_options(lease_supervisor,
           upload_reconciler: ExactStageReconciler,
           upload_recovery: %{
             attempts: attempts,
             test: self()
           },
           upload_recovery_supervisor: recovery_supervisor,
           upload_revoke_retry_ms: 50,
           upload_revoke_timeout_ms: 25
         )},
        id: make_ref()
      )

    unlock!(custodian)

    assert {:ok, prepared} =
             KeyCustodian.prepare_upload(custodian, upload_request())

    test = self()

    upload =
      spawn(fn ->
        assert {:ok, material} =
                 KeyCustodian.claim_upload(
                   custodian,
                   prepared.material_ref,
                   claim_request(prepared)
                 )

        writer = spawn(fn -> Process.sleep(:infinity) end)

        assert :ok =
                 KeyCustodian.attach_upload_worker(
                   custodian,
                   material.custody_ref,
                   writer
                 )

        send(test, :orphaned_caller_upload_ready)
        Process.sleep(:infinity)
      end)

    assert_receive :orphaned_caller_upload_ready

    caller =
      spawn(fn ->
        KeyCustodian.begin_revoke(
          custodian,
          %{session_id: @session_id}
        )
      end)

    caller_monitor = Process.monitor(caller)

    assert_receive {:exact_stage_recovery_started, first_recovery, 1, _recovery, :custody_revoked}

    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}

    assert {:error, %Error{code: :conflict}} =
             KeyCustodian.prepare_unlock(
               custodian,
               unlocked_session()
             )

    send(first_recovery, {:release_exact_stage_recovery, 1})

    assert_receive {:exact_stage_recovery_started, second_recovery, 2, _recovery,
                    :custody_revoked}

    assert {:error, %Error{code: :conflict}} =
             KeyCustodian.prepare_unlock(
               custodian,
               unlocked_session()
             )

    send(second_recovery, {:release_exact_stage_recovery, 2})

    assert_eventually(fn ->
      :sys.get_state(custodian).revoking == %{}
    end)

    assert {:ok, reopened} =
             KeyCustodian.prepare_unlock(
               custodian,
               unlocked_session()
             )

    assert :ok = KeyCustodian.discard_pending(custodian, reopened)
    refute Process.alive?(upload)
  end

  test "idle locking waits for claimed upload cleanup before persisting", %{
    lease_supervisor: lease_supervisor
  } do
    attempts =
      start_supervised!(
        {Agent, fn -> 0 end},
        id: make_ref()
      )

    custodian =
      start_supervised!(
        {KeyCustodian,
         custodian_options(lease_supervisor,
           idle_lock:
             {IdleAdapter,
              %{
                attempts: attempts,
                test: self()
              }},
           idle_lock_retry_ms: 50,
           idle_timeout_ms: 100
         )},
        id: make_ref()
      )

    unlock!(custodian)

    assert {:ok, prepared} =
             KeyCustodian.prepare_upload(custodian, upload_request())

    test = self()

    upload =
      spawn(fn ->
        assert {:ok, material} =
                 KeyCustodian.claim_upload(
                   custodian,
                   prepared.material_ref,
                   claim_request(prepared)
                 )

        writer = spawn(fn -> Process.sleep(:infinity) end)

        assert :ok =
                 KeyCustodian.attach_upload_worker(
                   custodian,
                   material.custody_ref,
                   writer
                 )

        send(test, {:idle_upload_ready, self(), writer})

        receive do
          {:custody_revoke, custody_ref, revocation_ref, ^custodian}
          when custody_ref == material.custody_ref ->
            Process.exit(writer, :kill)

            send(
              custodian,
              {:custody_revoke_result, self(), custody_ref, revocation_ref, :ok}
            )
        end
      end)

    upload_monitor = Process.monitor(upload)
    assert_receive {:idle_upload_ready, ^upload, writer}
    writer_monitor = Process.monitor(writer)

    assert_receive {:idle_lock_attempted, 1,
                    %{
                      session_id: @session_id,
                      reason: :idle_timeout
                    }},
                   1_000

    assert_receive {:DOWN, ^upload_monitor, :process, ^upload, :normal}
    assert_receive {:DOWN, ^writer_monitor, :process, ^writer, :killed}

    assert {:error, %Error{code: :conflict}} =
             KeyCustodian.prepare_unlock(
               custodian,
               unlocked_session()
             )

    assert_receive {:idle_lock_attempted, 2,
                    %{
                      session_id: @session_id,
                      reason: :idle_timeout
                    }},
                   1_000

    state = :sys.get_state(custodian)
    refute Map.has_key?(state.sessions, @session_id)
    assert state.revoking == %{}
    assert state.upload_revocations == %{}

    assert {:ok, reopened} =
             KeyCustodian.prepare_unlock(
               custodian,
               unlocked_session()
             )

    assert :ok = KeyCustodian.discard_pending(custodian, reopened)
  end

  defp unlocked_session do
    %{
      session_id: @session_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 11,
      vault_key: :binary.copy(<<0xC3>>, 32),
      domain_key: @domain_key,
      domain_dedup_key: @domain_dedup_key,
      key_domain_id: @key_domain_id,
      domain_key_version_id: @domain_key_version_id,
      domain_key_generation: 3,
      domain_classification: :private,
      object_keys: %{}
    }
  end

  defp upload_request do
    %{
      grant_id: @grant_id,
      asset_id: @asset_id,
      session_id: @session_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 11,
      classification: :private
    }
  end

  defp claim_request(prepared) do
    upload_request()
    |> Map.put(:stage_id, prepared.stage_id)
    |> Map.put(:storage_ref, prepared.storage_ref)
  end

  defp lease_request do
    %{
      job_id: Ecto.UUID.generate(),
      vault_id: @vault_id,
      principal_id: @principal_id,
      required_capability: "asset.read",
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 11,
      object_id: Ecto.UUID.generate(),
      object_generation: 1,
      session_id: @session_id
    }
  end

  defp custodian_options(lease_supervisor, overrides) do
    Map.merge(
      %{
        authorization: Adapter,
        clock: Adapter,
        context: %{},
        idle_lock: Adapter,
        key_reader: Adapter,
        object_key_loader: Adapter,
        key_wrapper: KeyWrapper,
        lease_supervisor: lease_supervisor,
        pending_ttl_ms: 500,
        upload_material_ttl_ms: 500
      },
      Map.new(overrides)
    )
  end

  defp unlock!(custodian) do
    assert {:ok, pending} =
             KeyCustodian.prepare_unlock(custodian, unlocked_session())

    assert :ok = KeyCustodian.activate_unlock(custodian, pending)
  end

  defp cooperative_upload_loop(custodian, custody_ref, writer, test) do
    receive do
      :assert_unlocked ->
        result =
          KeyCustodian.assert_unlocked(
            custodian,
            @session_id,
            @principal_id,
            @vault_id,
            7,
            11
          )

        send(test, {:assert_unlocked_result, result})
        cooperative_upload_loop(custodian, custody_ref, writer, test)

      {:custody_revoke, ^custody_ref, revocation_ref, ^custodian} ->
        Process.exit(writer, :kill)

        send(
          custodian,
          {:custody_revoke_result, self(), custody_ref, revocation_ref, :ok}
        )
    end
  end

  defp assert_queued_call(custodian, request, attempts \\ 100)

  defp assert_queued_call(_custodian, request, 0) do
    flunk("expected #{inspect(request)} call to be queued")
  end

  defp assert_queued_call(custodian, request, attempts) do
    {:messages, messages} = Process.info(custodian, :messages)

    if Enum.any?(messages, &queued_call?(&1, request)) do
      :ok
    else
      receive do
      after
        1 -> assert_queued_call(custodian, request, attempts - 1)
      end
    end
  end

  defp queued_call?({:"$gen_call", _from, {:begin_revoke, _selector}}, :begin_revoke),
    do: true

  defp queued_call?(
         {:"$gen_call", _from, {:attach_upload_worker, _custody_ref, _worker}},
         :attach_upload_worker
       ),
       do: true

  defp queued_call?(
         {:"$gen_call", _from,
          {:assert_unlocked, _session_id, _principal_id, _vault_id, _principal_epoch,
           _vault_epoch}},
         :assert_unlocked
       ),
       do: true

  defp queued_call?(_message, _request), do: false

  defp resume_if_suspended(custodian) do
    if Process.alive?(custodian) do
      :sys.resume(custodian)
    end
  catch
    :exit, _reason -> :ok
  end

  defp assert_eventually(callback, attempts \\ 100)

  defp assert_eventually(_callback, 0),
    do: flunk("condition did not become true")

  defp assert_eventually(callback, attempts) do
    if callback.() do
      :ok
    else
      receive do
      after
        5 -> assert_eventually(callback, attempts - 1)
      end
    end
  end
end
