defmodule Singularity.Storage.DocumentWorkerScopeTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration

  alias Singularity.Core.{Error, JobEnvelope}
  alias Singularity.Storage.{Fixtures, KnowledgeFixtures, MigrationRepo, SafeSQL}
  alias Singularity.Storage.Jobs.{EnvelopeCodec, WorkerScope}

  @settings_options [query_type: :text, timeout: 15_000]

  setup do
    source = KnowledgeFixtures.prepared_source!()

    binary_source =
      Map.new(source, fn {key, value} ->
        {key,
         if(String.ends_with?(Atom.to_string(key), "_id"),
           do: Ecto.UUID.dump!(value),
           else: value
         )}
      end)

    document = KnowledgeFixtures.document!(binary_source)
    job = Ecto.UUID.generate()
    key = "document-extraction:#{Ecto.UUID.load!(document.resource_version_id)}"

    payload = %{
      "resource_id" => Ecto.UUID.load!(document.resource_id),
      "resource_version_id" => Ecto.UUID.load!(document.resource_version_id)
    }

    {principal_epoch, owner_epoch} =
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "INSERT INTO core.capabilities(id,name) VALUES($1,'asset.read') ON CONFLICT(name) DO NOTHING",
          [KnowledgeFixtures.uuid()]
        )

        query!(
          MigrationRepo,
          "INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name='asset.read'",
          [binary_source.principal_id, binary_source.vault_id]
        )

        %{rows: [[pe, oe]]} =
          query!(
            MigrationRepo,
            "SELECT p.authorization_epoch,v.authorization_epoch FROM identity.principals p CROSS JOIN core.vaults v WHERE p.id=$1 AND v.id=$2",
            [binary_source.principal_id, binary_source.vault_id]
          )

        query!(
          MigrationRepo,
          """
          INSERT INTO core.outbox_events(id,event_type,idempotency_key,vault_id,principal_id,required_capability,
            principal_authorization_epoch,vault_authorization_epoch,classification,correlation_id,causation_id,
            expected_entity_revision,envelope_version,payload,occurred_at)
          VALUES($1,'document.extraction_requested',$2,$3,$4,'asset.read',$5,$6,'private',$1,$1,0,1,$7,CURRENT_TIMESTAMP)
          """,
          [
            Ecto.UUID.dump!(job),
            key,
            binary_source.vault_id,
            binary_source.principal_id,
            pe,
            oe,
            payload
          ]
        )

        query!(
          MigrationRepo,
          """
          INSERT INTO jobs.job_submissions(id,vault_id,outbox_event_id,classification,idempotency_key,job_type)
          VALUES($1,$2,$1,'private',$3,'document_extract')
          """,
          [Ecto.UUID.dump!(job), binary_source.vault_id, key]
        )

        {pe, oe}
      end)

    {:ok, envelope} =
      JobEnvelope.new(%{
        version: 1,
        job_id: job,
        job_type: "document_extract",
        idempotency_key: key,
        vault_id: source.vault_id,
        principal_id: source.principal_id,
        required_capability: "asset.read",
        principal_authorization_epoch: principal_epoch,
        vault_authorization_epoch: owner_epoch,
        classification: :private,
        correlation_id: job,
        causation_id: job,
        expected_entity_revision: 0,
        attempt: 0,
        payload: payload
      })

    {:ok, encoded} = EnvelopeCodec.encode(envelope)
    {:ok, ^envelope} = EnvelopeCodec.decode(encoded)
    assert WorkerRepo.get_dynamic_repo() == WorkerRepo
    named = Process.whereis(WorkerRepo)
    config = Application.fetch_env!(:singularity_storage, WorkerRepo)
    original = fresh_snapshot()

    f = %{
      backend: original.backend,
      envelope: envelope,
      source: binary_source,
      document: document
    }

    # Registered before runner cleanup callbacks, which execute first.
    on_exit(fn ->
      restore_backend!(original)
      assert Process.whereis(WorkerRepo) == named
      assert Process.alive?(named)
      assert Application.fetch_env!(:singularity_storage, WorkerRepo) == config
    end)

    assert %{role: "singularity_worker", timeout: 0} = original
    {:ok, fixture: f}
  end

  test "fresh Document checkout caps server statements outside transactions and restores its session",
       %{fixture: f} do
    before = snapshot(f)

    assert :done =
             run(f, fn context ->
               assert context.repo_handle === WorkerRepo
               assert context.lock_mode == :shared
               assert WorkerRepo.checked_out?()
               refute WorkerRepo.in_transaction?()
               assert timeout_ms() == 15_000
               assert backend() == before.backend
               locks!(f, false)

               assert :done =
                        context.transact.([], fn repo ->
                          assert repo === WorkerRepo
                          assert WorkerRepo.in_transaction?()

                          assert [[principal, owner]] =
                                   SafeSQL.query!(
                                     repo,
                                     "SELECT current_setting('singularity.principal_id'),current_setting('singularity.vault_id')"
                                   ).rows

                          assert {principal, owner} ==
                                   {f.envelope.principal_id, f.envelope.vault_id}

                          :done
                        end)

               :done
             end)

    assert snapshot(f) == before
    locks!(f, true)
  end

  @tag timeout: 60_000
  test "real Document borrower survives 15 seconds with same backend and both shared locks", %{
    fixture: f
  } do
    parent = self()
    token = make_ref()

    runner =
      spawn_owned(f, fn ->
        run(f, fn _context ->
          initial = backend()
          assert timeout_ms() == 15_000
          started = System.monotonic_time(:millisecond)
          send(parent, {token, :entered, initial})
          wait_until(started + 16_000)
          assert backend() == initial
          assert WorkerRepo.checked_out?()
          refute WorkerRepo.in_transaction?()
          :done
        end)
      end)

    assert_receive {^token, :entered, pid}, 5_000
    locks!(f, false)
    assert :done = result!(runner, 22_000)
    assert snapshot(f).backend == pid
    assert snapshot(f).timeout == 0
    locks!(f, true)
  end

  @tag timeout: 60_000
  test "actual statement above 15 seconds is cancelled without losing the Document backend", %{
    fixture: f
  } do
    before = snapshot(f)

    assert :cancelled =
             run(f, fn _context ->
               started = System.monotonic_time(:millisecond)

               assert {:error, %Postgrex.Error{postgres: %{code: :query_canceled}}} =
                        SafeSQL.query(WorkerRepo, "SELECT pg_sleep(20)")

               elapsed = System.monotonic_time(:millisecond) - started
               assert elapsed >= 14_000 and elapsed < 20_000
               assert backend() == before.backend
               :cancelled
             end)

    assert snapshot(f) == before
    locks!(f, true)
  end

  test "stricter existing 75 ms statement cap stays effective and is restored exactly", %{
    fixture: f
  } do
    set_prior!(f, 75)
    before = snapshot(f)

    assert :cancelled =
             run(f, fn _context ->
               assert timeout_ms() == 75

               assert {:error, %Postgrex.Error{postgres: %{code: :query_canceled}}} =
                        SafeSQL.query(WorkerRepo, "SELECT pg_sleep(1)")

               :cancelled
             end)

    assert snapshot(f) == before
    locks!(f, true)
  end

  for mode <- [:success, :returned_failure, :raise, :throw, :rollback] do
    test "exact prior setting and request GUCs restore after #{mode}", %{fixture: f} do
      set_prior!(f, 30_000)
      before = snapshot(f)
      mode = unquote(mode)

      result =
        try do
          {:returned,
           run(f, fn context ->
             assert timeout_ms() == 15_000
             assert backend() == before.backend
             callback_outcome(mode, context, f)
           end)}
        rescue
          error in RuntimeError -> {:raised, error.message}
        catch
          :throw, reason -> {:thrown, reason}
        end

      assert_outcome(mode, result)
      assert snapshot(f) == before
      assert WorkerRepo.get_dynamic_repo() == WorkerRepo
      locks!(f, true)
    end
  end

  test "borrower death disconnects only its backend and releases locks and temporary settings", %{
    fixture: f
  } do
    parent = self()
    token = make_ref()

    runner =
      spawn_owned(f, fn ->
        run(f, fn _context ->
          assert timeout_ms() == 15_000
          send(parent, {token, :entered, backend()})

          receive do
            {^token, :continue} -> :unexpected_success
          after
            5_000 -> flunk("borrower kill barrier exceeded bound")
          end
        end)
      end)

    assert_receive {^token, :entered, pid}, 5_000
    locks!(f, false)
    Process.exit(runner.pid, :kill)
    down!(runner, :killed)
    backend_gone!(pid)
    next = fresh_snapshot()
    assert %{role: "singularity_worker", timeout: 0} = next
    refute next.backend == pid
    locks!(f, true)
  end

  test "loss of exactly the owned backend makes restoration kill its borrower rather than return success",
       %{fixture: f} do
    parent = self()
    token = make_ref()

    runner =
      spawn_owned(f, fn ->
        run(f, fn _context ->
          assert timeout_ms() == 15_000
          send(parent, {token, :entered, backend()})

          result =
            try do
              SafeSQL.query(WorkerRepo, "SELECT pg_terminate_backend(pg_backend_pid())")
            rescue
              error in DBConnection.ConnectionError -> {:error, error}
            end

          assert match?({:error, %Postgrex.Error{postgres: %{code: :admin_shutdown}}}, result) or
                   match?({:error, %DBConnection.ConnectionError{}}, result)

          send(parent, {token, :owned_connection_lost})
          :unexpected_success
        end)
      end)

    assert_receive {^token, :entered, pid}, 5_000
    assert_receive {^token, :owned_connection_lost}, 5_000
    down!(runner, :killed)
    backend_gone!(pid)
    next = fresh_snapshot()
    assert %{role: "singularity_worker", timeout: 0} = next
    refute next.backend == pid
    locks!(f, true)
  end

  test "nested Document entry is rejected before session settings locks or callback change", %{
    fixture: f
  } do
    at_backend!(f.backend, fn ->
      before = {backend(), timeout_ms()}

      assert {:error, %Error{code: :invalid, message: nil, details: %{}}} =
               WorkerScope.run(f.envelope, fn _context ->
                 flunk("nested callback must not execute")
               end)

      assert {backend(), timeout_ms()} == before
      locks!(f, true)
    end)

    assert snapshot(f).timeout == 0
  end

  @tag timeout: 60_000
  test "non-Document worker retains its existing statement setting and 15-second checkout", %{
    fixture: f
  } do
    asset = asset_envelope!(f)
    parent = self()
    token = make_ref()

    runner =
      spawn_owned(f, fn ->
        try do
          WorkerScope.run(asset, fn _context ->
            assert timeout_ms() == 0
            send(parent, {token, :entered, backend()})
            wait_until(System.monotonic_time(:millisecond) + 16_000)
            SafeSQL.query!(WorkerRepo, "SELECT 1")
            :unexpected_success
          end)
        rescue
          _error in DBConnection.ConnectionError -> :legacy_checkout_expired
        end
      end)

    assert_receive {^token, :entered, pid}, 5_000
    assert :legacy_checkout_expired = result!(runner, 22_000)
    backend_gone!(pid)
    next = fresh_snapshot()
    assert %{role: "singularity_worker", timeout: 0} = next
    refute next.backend == pid
    locks!(f, true)
  end

  @tag timeout: 360_000
  test "real fixed five-minute checkout expiry prevents late scoped mutation and releases owned backend",
       %{fixture: f} do
    parent = self()
    token = make_ref()

    runner =
      spawn_owned(f, fn ->
        run(f, fn context ->
          assert timeout_ms() == 15_000
          assert :written = bump_wake(context, f)
          started = System.monotonic_time(:millisecond)
          send(parent, {token, :entered, backend()})
          wait_until(started + 300_750)
          send(parent, {token, :late_attempt})
          bump_wake(context, f)
          :unexpected_success
        end)
      end)

    assert_receive {^token, :entered, pid}, 5_000
    assert wake_count(f) == 1
    locks!(f, false)
    assert_receive {^token, :late_attempt}, 310_000
    down!(runner, :killed)
    backend_gone!(pid)
    assert wake_count(f) == 1

    assert [["pending", 0, nil, nil]] ==
             owner_query(
               "SELECT state,attempt_generation,attempt_started_at,attempt_deadline_at FROM content.document_versions WHERE resource_version_id=$1",
               [f.document.resource_version_id]
             ).rows

    next = fresh_snapshot()
    assert %{role: "singularity_worker", timeout: 0} = next
    refute next.backend == pid
    locks!(f, true)
  end

  defp run(f, callback) do
    assert WorkerRepo.get_dynamic_repo() == WorkerRepo
    refute WorkerRepo.checked_out?()

    select_backend!(fn ->
      WorkerScope.run(f.envelope, fn context ->
        if backend() == f.backend, do: {:selected, callback.(context)}, else: :not_selected
      end)
    end)
  end

  defp asset_envelope!(f) do
    id = Ecto.UUID.generate()

    asset = %{
      f.envelope
      | job_id: id,
        job_type: "asset_metadata",
        correlation_id: id,
        causation_id: id,
        idempotency_key: "asset-metadata:#{Ecto.UUID.load!(f.source.asset_id)}:0",
        payload: %{"asset_id" => Ecto.UUID.load!(f.source.asset_id)}
    }

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO core.outbox_events(id,event_type,idempotency_key,vault_id,principal_id,required_capability,
          principal_authorization_epoch,vault_authorization_epoch,classification,correlation_id,causation_id,
          expected_entity_revision,envelope_version,payload,occurred_at)
        VALUES($1,'asset.metadata_requested',$2,$3,$4,'asset.read',$5,$6,'private',$1,$1,0,1,$7,CURRENT_TIMESTAMP)
        """,
        [
          Ecto.UUID.dump!(id),
          asset.idempotency_key,
          f.source.vault_id,
          f.source.principal_id,
          asset.principal_authorization_epoch,
          asset.vault_authorization_epoch,
          asset.payload
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO jobs.job_submissions(id,vault_id,outbox_event_id,classification,idempotency_key,job_type)
        VALUES($1,$2,$1,'private',$3,'asset_metadata')
        """,
        [Ecto.UUID.dump!(id), f.source.vault_id, asset.idempotency_key]
      )
    end)

    {:ok, encoded} = EnvelopeCodec.encode(asset)
    {:ok, ^asset} = EnvelopeCodec.decode(encoded)
    asset
  end

  defp callback_outcome(:success, _context, _f), do: :done

  defp callback_outcome(:returned_failure, _context, _f),
    do: {:error, Error.new(:storage_unavailable, retryable?: true)}

  defp callback_outcome(:raise, _context, _f), do: raise("bounded checkout callback")
  defp callback_outcome(:throw, _context, _f), do: throw(:bounded_checkout_callback)

  defp callback_outcome(:rollback, context, f) do
    context.transact.([], fn repo ->
      assert WorkerRepo.in_transaction?()

      assert [[f.envelope.principal_id, f.envelope.vault_id]] ==
               SafeSQL.query!(
                 repo,
                 "SELECT current_setting('singularity.principal_id'),current_setting('singularity.vault_id')"
               ).rows

      repo.rollback(:bounded_checkout_rollback)
    end)
  end

  defp assert_outcome(:success, result), do: assert(result == {:returned, :done})

  defp assert_outcome(:returned_failure, result),
    do: assert({:returned, {:error, %Error{code: :storage_unavailable}}} = result)

  defp assert_outcome(:raise, result),
    do: assert(result == {:raised, "bounded checkout callback"})

  defp assert_outcome(:throw, result), do: assert(result == {:thrown, :bounded_checkout_callback})

  defp assert_outcome(:rollback, result),
    do: assert(result == {:returned, {:error, :bounded_checkout_rollback}})

  @selection_attempts 256
  @selection_window_ms 5_000

  defp select_backend!(attempt) do
    deadline = System.monotonic_time(:millisecond) + @selection_window_ms
    select_backend!(attempt, deadline, @selection_attempts)
  end

  defp select_backend!(_attempt, _deadline, 0),
    do: flunk("exact backend was not selected within the bounded checkout count")

  defp select_backend!(attempt, deadline, remaining) do
    assert System.monotonic_time(:millisecond) < deadline,
           "exact backend selection exceeded its admission deadline"

    case attempt.() do
      {:selected, result} -> result
      :not_selected -> select_backend!(attempt, deadline, remaining - 1)
      _unexpected -> flunk("backend selection returned an unexpected scope result")
    end
  end

  defp at_backend!(target, callback) do
    assert WorkerRepo.get_dynamic_repo() == WorkerRepo
    refute WorkerRepo.checked_out?()

    select_backend!(fn ->
      WorkerRepo.checkout(fn ->
        if backend() == target, do: {:selected, callback.()}, else: :not_selected
      end)
    end)
  end

  defp snapshot(f), do: at_backend!(f.backend, &snapshot_checked_out/0)

  defp fresh_snapshot do
    assert WorkerRepo.get_dynamic_repo() == WorkerRepo
    refute WorkerRepo.checked_out?()
    WorkerRepo.checkout(&snapshot_checked_out/0)
  end

  defp snapshot_checked_out do
    assert WorkerRepo.checked_out?()
    refute WorkerRepo.in_transaction?()

    assert [[pid, "singularity_worker", principal, owner]] =
             SafeSQL.query!(
               WorkerRepo,
               "SELECT pg_backend_pid(),current_user,current_setting('singularity.principal_id',true),current_setting('singularity.vault_id',true)"
             ).rows

    assert principal in [nil, ""] and owner in [nil, ""]
    %{backend: pid, role: "singularity_worker", timeout: timeout_ms()}
  end

  defp backend, do: SafeSQL.query!(WorkerRepo, "SELECT pg_backend_pid()").rows |> hd() |> hd()

  defp timeout_ms do
    assert [[value]] =
             SafeSQL.query!(
               WorkerRepo,
               "SELECT setting FROM pg_catalog.pg_settings WHERE name='statement_timeout'",
               [],
               @settings_options
             ).rows

    {integer, ""} = Integer.parse(value)
    assert integer >= 0
    integer
  end

  defp set_timeout!(milliseconds) do
    assert is_integer(milliseconds) and milliseconds >= 0

    SafeSQL.query!(
      WorkerRepo,
      "SELECT set_config('statement_timeout','#{milliseconds}ms',false)",
      [],
      @settings_options
    )

    assert timeout_ms() == milliseconds
    :ok
  end

  defp set_prior!(f, milliseconds),
    do: at_backend!(f.backend, fn -> set_timeout!(milliseconds) end)

  defp restore_backend!(original) do
    assert WorkerRepo.get_dynamic_repo() == WorkerRepo
    refute WorkerRepo.checked_out?()

    if backend_present?(original.backend) do
      at_backend!(original.backend, fn ->
        set_timeout!(original.timeout)
        assert snapshot_checked_out() == original
        :restored
      end)
    else
      # Cleanup only: disappearance cannot satisfy same-backend restoration tests.
      :backend_gone
    end
  end

  defp locks!(f, expected) do
    borrower_backend = if WorkerRepo.checked_out?(), do: backend(), else: nil
    excluded_backends = [f.backend, borrower_backend]

    observe!(fn ->
      select_backend!(fn ->
        WorkerRepo.checkout(fn ->
          observer_backend = backend()

          if observer_backend in excluded_backends do
            :not_selected
          else
            assert [["singularity_worker"]] =
                     SafeSQL.query!(WorkerRepo, "SELECT current_user").rows

            for key <- [
                  "singularity:vault:" <> f.envelope.vault_id,
                  "singularity:authorization:" <>
                    f.envelope.principal_id <> ":" <> f.envelope.vault_id
                ] do
              assert [[available]] =
                       SafeSQL.query!(
                         WorkerRepo,
                         "SELECT pg_try_advisory_lock(hashtextextended($1::text,0))",
                         [key]
                       ).rows

              if available do
                assert [[true]] =
                         SafeSQL.query!(
                           WorkerRepo,
                           "SELECT pg_advisory_unlock(hashtextextended($1::text,0))",
                           [key]
                         ).rows
              end

              assert available == expected
            end

            {:selected, :ok}
          end
        end)
      end)
    end)
  end

  defp observe!(callback) do
    parent = self()
    token = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        assert WorkerRepo.get_dynamic_repo() == WorkerRepo
        refute WorkerRepo.checked_out?()
        result = callback.()
        send(parent, {token, :observed, result})
      end)

    try do
      receive do
        {^token, :observed, result} ->
          assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
          result

        {:DOWN, ^monitor, :process, ^pid, _reason} ->
          flunk("independent backend observer failed")
      after
        5_000 -> flunk("independent backend observer exceeded its bound")
      end
    after
      if Process.alive?(pid) do
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 5_000
      end

      Process.demonitor(monitor, [:flush])
    end
  end

  defp spawn_owned(_f, callback) do
    parent = self()
    token = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        assert WorkerRepo.get_dynamic_repo() == WorkerRepo
        refute WorkerRepo.checked_out?()
        result = callback.()
        send(parent, {token, :result, result})
      end)

    on_exit(fn ->
      monitor = Process.monitor(pid)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
    end)

    %{pid: pid, monitor: monitor, token: token}
  end

  defp result!(%{pid: pid, monitor: monitor, token: token}, timeout) do
    assert_receive {^token, :result, result}, timeout
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
    result
  end

  defp down!(%{pid: pid, monitor: monitor, token: token}, reason) do
    assert_receive {:DOWN, ^monitor, :process, ^pid, ^reason}, 5_000
    refute_receive {^token, :result, _}, 0
  end

  defp backend_present?(pid) do
    observe!(fn ->
      assert [[count]] =
               SafeSQL.query!(
                 WorkerRepo,
                 "SELECT count(*) FROM pg_catalog.pg_stat_activity WHERE pid=$1",
                 [pid]
               ).rows

      assert count in [0, 1]
      count == 1
    end)
  end

  defp backend_gone!(pid), do: backend_gone(pid, System.monotonic_time(:millisecond) + 5_000)

  defp backend_gone(pid, bound) do
    if backend_present?(pid) do
      assert System.monotonic_time(:millisecond) < bound
      wait_until(min(bound, System.monotonic_time(:millisecond) + 10))
      backend_gone(pid, bound)
    end
  end

  defp wait_until(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      token = make_ref()
      interval = min(remaining, 30_000)
      timer = Process.send_after(self(), {:scope_tick, token}, interval)

      receive do
        {:scope_tick, ^token} -> :ok
      after
        interval + 1_000 ->
          Process.cancel_timer(timer)
          flunk("owned scope timer exceeded bound")
      end

      wait_until(deadline)
    end
  end

  defp bump_wake(context, f) do
    context.transact.([], fn repo ->
      assert %{num_rows: 1} =
               SafeSQL.query!(
                 repo,
                 "UPDATE jobs.job_submissions SET wake_requested_generation=wake_requested_generation+1 WHERE id=$1",
                 [Ecto.UUID.dump!(f.envelope.job_id)]
               )

      :written
    end)
  end

  defp wake_count(f) do
    [[count]] =
      owner_query(
        "SELECT wake_requested_generation FROM jobs.job_submissions WHERE id=$1",
        [Ecto.UUID.dump!(f.envelope.job_id)]
      ).rows

    count
  end

  defp owner_query(sql, params),
    do: Fixtures.with_owner(fn -> query!(MigrationRepo, sql, params) end)
end
