defmodule Singularity.Runtime.KnowledgeExportLiveFixture do
  @moduledoc false

  import ExUnit.Assertions

  alias Singularity.Runtime.{Api, AuthorizationDependencies, Authorize}
  alias Singularity.Runtime.{KeyCustodian, NativeAssetFixture, OperationScope, OutboxDispatcher}
  alias Singularity.Runtime.Knowledge.Export
  alias Singularity.Runtime.KnowledgeExportQualificationRoot
  alias Singularity.Storage.Backup.KnowledgeFixtureResourceOwner, as: ResourceOwner
  alias Singularity.Storage.{AuthorizationLock, MigrationRepo, ObjectLock, RequestRepo, SafeSQL}
  alias Singularity.Storage.VaultLock
  alias Singularity.Storage.Postgres.{AssetRepository, AuditSink, IdentityRepository}

  @chunk 65_536
  @settings [
    {:singularity_runtime, :authorization_dependencies},
    {:singularity_runtime, :key_custodian},
    {:singularity_runtime, :knowledge_export_root},
    {:singularity_storage, :backup_root}
  ]
  @plain "第一段 café\n\nSecond paragraph 🌍"
  @markdown "# 标题\n\nUnicode café 🌍\n\n[ordinary URL](https://example.test/knowledge)"
  @label "../资料/[source](escape) 🧪"
  @fixture_apps [:singularity_runtime, :singularity_storage]
  @identity_keys [:major_device, :minor_device, :inode, :uid, :gid, :mode, :type]
  @global_tasks Singularity.Runtime.UploadRecoveryTaskSupervisor

  # The observer is private test state, not telemetry. It retains identities,
  # scalar bounds and real outcomes; no captured descriptor or delivered bytes.
  defmodule Observer do
    import ExUnit.Assertions

    def event(context, point, values \\ %{}) do
      event = Map.merge(values, %{point: point, pid: self()})
      Agent.update(context.control, &Map.update!(&1, :events, fn events -> [event | events] end))
      send(context.parent, {:knowledge_export, context.token, point, self(), values})
      # Retain real empty EOF observations, but optional native-piece operation
      # controls require positive bytes already checked by ObservedReader.
      if point != :native_piece or values.byte_size > 0 do
        if callback = context[:on_event], do: callback.(point, values)
        barrier(context, point)
      end

      :ok
    end

    def barrier(context, point) do
      if point in Map.get(context, :barriers, []) and
           not Process.get({__MODULE__, context.token, point}, false) do
        Process.put({__MODULE__, context.token, point}, true)
        send(context.parent, {:knowledge_export_barrier, context.token, point, self()})

        receive do
          {:knowledge_export_continue, token, ^point} when token == context.token -> :ok
        after
          15_000 -> raise "live export observer barrier timed out"
        end
      end
    end

    def events(fixture), do: Agent.get(fixture.observer.control, &Enum.reverse(&1.events))
    def issued(fixture), do: Agent.get(fixture.observer.control, & &1.issued)
    def handles(fixture), do: Agent.get(fixture.observer.control, & &1.handles)

    # Only the actual configured companion may register and produce outcomes.
    # All Agent callbacks below transform data only; supervision is checked here.
    def register_companion(context) do
      lifecycle = Agent.get(context.control, & &1.lifecycle)
      private = lifecycle.child_specs.private
      tracker = lifecycle.child_specs.tracker
      assert lifecycle.phase == :active
      assert private.id == {Task.Supervisor, context.token} and private.status == :started

      assert tracker.id ==
               {Singularity.Runtime.KnowledgeExportLiveFixture.IssuedLeases, context.token}

      assert tracker.status == :started and is_pid(tracker.pid)
      assert is_pid(private.pid) and self() in Task.Supervisor.children(private.pid)

      binding = %{
        token: context.token,
        owner: context.owner,
        caller: context.parent,
        control: context.control,
        collector: tracker.pid,
        custodian: context.custodian
      }

      assert lifecycle.token == binding.token and lifecycle.owner == binding.owner
      assert lifecycle.caller == binding.caller
      assert lifecycle.fixture.custodian == binding.custodian
      assert lifecycle.fixture.lease_tracker == binding.collector
      registration = %{binding: binding, producer: self(), supervisor: private.pid}
      reference = make_ref()
      monitor = Process.monitor(binding.collector)

      try do
        send(binding.collector, {:task17_companion_register, registration, reference})

        receive do
          {:task17_companion_monitored, ^reference, collector}
          when collector == binding.collector ->
            :ok

          {:DOWN, ^monitor, :process, collector, _} when collector == binding.collector ->
            flunk("companion monitor registration lost its collector")
        after
          5_000 -> flunk("companion monitor registration was not acknowledged")
        end
      after
        Process.demonitor(monitor, [:flush])
      end

      registration
    end

    # Executed by the actual collector after its monitor is installed, never in
    # an Agent callback. Only data publication occurs inside control.
    def install_companion_registration(context, registration) do
      assert self() == registration.binding.collector
      producer = registration.producer
      binding = registration.binding
      initial = empty_companion_ledger(binding, registration.supervisor)

      registered? =
        Agent.get_and_update(context.control, fn state ->
          ledger = Map.get(state, :companion_ack_ledger, initial)

          if state.lifecycle.phase == :active and not ledger.sealed? and
               state.lifecycle.child_specs.private.pid == registration.supervisor and
               state.lifecycle.child_specs.tracker.pid == binding.collector and
               ledger.binding == binding and ledger.supervisor == registration.supervisor do
            ledger = %{ledger | producers: Map.put_new(ledger.producers, producer, MapSet.new())}
            {true, Map.put(state, :companion_ack_ledger, ledger)}
          else
            {false, state}
          end
        end)

      assert registered?, "configured companion registration was not admitted"
      :ok
    end

    def associate_companion_lease(context, registration, lease) do
      assert registration.producer == self() and is_pid(lease)
      producer = self()

      associated? =
        Agent.get_and_update(context.control, fn state ->
          ledger = Map.get(state, :companion_ack_ledger)

          if is_map(ledger) and not ledger.sealed? and
               ledger.binding == registration.binding and
               ledger.supervisor == registration.supervisor and
               is_map_key(ledger.producers, producer) do
            leases = MapSet.put(Map.fetch!(ledger.producers, producer), lease)
            ledger = %{ledger | producers: Map.put(ledger.producers, producer, leases)}
            {true, Map.put(state, :companion_ack_ledger, ledger)}
          else
            {false, state}
          end
        end)

      assert associated?, "actual companion lease association was not admitted"
      :ok
    end

    # Called only after the unchanged native revoke has returned in this process.
    # Controllers can replay an ID notification, never supply an outcome.
    def record_companion_revoke(context, lease, outcome) do
      producer = self()
      ledger = Agent.get(context.control, &Map.get(&1, :companion_ack_ledger))
      assert is_map(ledger) and is_pid(lease) and is_atom(outcome)
      assert MapSet.member?(Map.get(ledger.producers, producer, MapSet.new()), lease)
      reference = make_ref()

      record = %{
        id: reference,
        binding: ledger.binding,
        producer: producer,
        supervisor: ledger.supervisor,
        lease: lease,
        outcome: outcome,
        source: :companion
      }

      persisted? =
        Agent.get_and_update(context.control, fn state ->
          current = Map.get(state, :companion_ack_ledger)

          if is_map(current) and not current.sealed? and
               current.binding == record.binding and current.supervisor == record.supervisor and
               MapSet.member?(Map.get(current.producers, producer, MapSet.new()), lease) do
            current = %{current | records: Map.put(current.records, reference, record)}
            {true, Map.put(state, :companion_ack_ledger, current)}
          else
            {false, state}
          end
        end)

      assert persisted?, "actual companion revoke observation was not persisted"

      Singularity.Runtime.KnowledgeExportLiveFixture.IssuedLeases.notify_companion_record(
        record.binding,
        reference
      )

      :ok
    end

    def companion_records(fixture),
      do: companion_snapshot(fixture.observer.control) |> Map.fetch!(:records) |> Map.values()

    def companion_progress(fixture) do
      Agent.get(fixture.observer.control, &Map.get(&1, :companion_ack_progress))
    end

    def companion_snapshot(control) do
      Agent.get(control, &Map.get(&1, :companion_ack_ledger, %{records: %{}}))
    end

    # This SAME validator checks real stored records before pending/application,
    # and is exposed only for regression rejection of altered record copies.
    def assert_companion_record!(binding, record) do
      assert is_map(binding) and is_pid(Map.get(binding, :control))
      assert is_map(record)

      assert Enum.sort(Map.keys(record)) ==
               [:binding, :id, :lease, :outcome, :producer, :source, :supervisor]

      assert record.binding == binding and record.source == :companion
      assert is_reference(record.id) and is_pid(record.producer) and is_pid(record.lease)
      assert is_pid(record.supervisor) and is_atom(record.outcome)
      ledger = companion_snapshot(binding.control)
      assert Map.get(ledger, :binding) == binding
      assert Map.get(ledger, :supervisor) == record.supervisor
      actual? = Map.get(ledger.records, record.id) == record
      assert actual?, "companion observation is not the exact persisted actual record"

      assert MapSet.member?(
               Map.get(ledger.producers, record.producer, MapSet.new()),
               record.lease
             )

      :ok
    end

    def seal_companion_records(context, binding, producer_down) do
      lifecycle = Agent.get(context.control, & &1.lifecycle)
      assert self() == binding.collector
      assert lifecycle.token == binding.token and lifecycle.owner == binding.owner
      assert lifecycle.caller == binding.caller
      assert lifecycle.fence_receipt.binding == binding
      assert is_boolean(lifecycle.fence_receipt.result)
      ledger = Agent.get(context.control, &Map.get(&1, :companion_ack_ledger))
      private = lifecycle.child_specs.private.pid
      global = lifecycle.fixture.global_supervisor

      for {kind, pid} <- [private: private, global: global], is_pid(pid) do
        receipt = Map.get(lifecycle.stop_receipts, kind)
        assert is_map(receipt) and receipt.pid == pid
        assert Map.get(lifecycle.stopped, kind) == pid
        refute receipt.reason in [:noproc, :killed]
        refute Process.alive?(pid)
      end

      if ledger do
        assert ledger.binding == binding and ledger.supervisor == private
        assert MapSet.new(Map.keys(ledger.producers)) == producer_down
        for {producer, _leases} <- ledger.producers, do: refute(Process.alive?(producer))
      end

      initial = empty_companion_ledger(binding, private)

      Agent.get_and_update(context.control, fn state ->
        current = Map.get(state, :companion_ack_ledger, initial)
        sealed = %{current | sealed?: true}
        {sealed.records, Map.put(state, :companion_ack_ledger, sealed)}
      end)
    end

    defp empty_companion_ledger(binding, supervisor),
      do: %{
        binding: binding,
        supervisor: supervisor,
        sealed?: false,
        producers: %{},
        records: %{}
      }

    # Regression-only observation: no callback runs in control, and no outcome
    # can be supplied by the controller. The owner sends its real result while
    # the captured custodian is still live, then waits for this exact observer.
    def register_cleanup_probe(fixture, controller) do
      assert self() == fixture.observer.parent
      assert is_pid(controller) and controller != self() and Process.alive?(controller)
      reference = make_ref()

      lifecycle = Agent.get(fixture.observer.control, & &1.lifecycle)
      assert lifecycle.probe == nil and lifecycle.phase == :active

      Agent.update(
        fixture.observer.control,
        &put_in(&1, [:lifecycle, :probe], %{pid: controller, reference: reference})
      )

      reference
    end

    @acquisition_probe {__MODULE__, :acquisition_probe}
    def with_acquisition_probe(point, controller, callback)
        when point in [
               :initial_registered,
               :native_registered,
               :private_start_returned,
               :tracker_start_returned
             ] and is_function(callback, 1) do
      assert is_pid(controller) and controller != self() and Process.alive?(controller)
      assert Process.get(@acquisition_probe) == nil
      reference = make_ref()
      Process.put(@acquisition_probe, %{point: point, pid: controller, reference: reference})

      try do
        callback.(reference)
      after
        Process.delete(@acquisition_probe)
      end
    end

    def acquisition_probe, do: Process.get(@acquisition_probe)

    def acquisition_checkpoint(probe, point, values) do
      if probe && probe.point == point do
        controller = probe.pid
        reference = probe.reference
        monitor = Process.monitor(controller)

        try do
          send(controller, {:task17_acquisition_checkpoint, reference, point, self(), values})

          receive do
            {:task17_acquisition_continue, ^reference, ^controller} ->
              :ok

            {:DOWN, ^monitor, :process, ^controller, _} ->
              flunk("fixture acquisition observer exited")
          after
            5_000 -> flunk("fixture acquisition observation was not released")
          end
        after
          Process.demonitor(monitor, [:flush])
        end
      end

      :ok
    end

    def register_sync_probe(fixture, controller) do
      assert self() == fixture.observer.parent
      assert is_pid(controller) and controller != self() and Process.alive?(controller)
      reference = make_ref()
      lifecycle = Agent.get(fixture.observer.control, & &1.lifecycle)
      assert lifecycle.phase == :active and lifecycle.sync_probe == nil

      Agent.update(
        fixture.observer.control,
        &put_in(&1, [:lifecycle, :sync_probe], %{pid: controller, reference: reference})
      )

      reference
    end

    def await_sync_probe(context, deadline, state, register) do
      probe =
        Agent.get_and_update(context.control, fn observed ->
          {observed.lifecycle.sync_probe, put_in(observed, [:lifecycle, :sync_probe], nil)}
        end)

      if probe do
        controller = probe.pid
        reference = probe.reference
        monitor = Process.monitor(controller)

        binding = %{
          token: context.token,
          owner: context.owner,
          caller: context.parent,
          control: context.control,
          collector: self(),
          custodian: context.custodian
        }

        try do
          send(controller, {:task17_collector_sync_ready, reference, self(), binding})
          await_sync_release(controller, reference, monitor, deadline, state, register)
        after
          Process.demonitor(monitor, [:flush])
        end
      else
        state
      end
    end

    defp await_sync_release(controller, reference, monitor, deadline, state, register) do
      receive do
        {:task17_collector_sync_continue, ^reference, ^controller} ->
          state

        # A new configured producer must install its actual collector monitor
        # before acquisition, even while ordinary trace/result folding is held.
        {:task17_companion_register, _registration, _reference} = message ->
          updated = register.(message, state)
          await_sync_release(controller, reference, monitor, deadline, updated, register)

        {:DOWN, ^monitor, :process, ^controller, _} ->
          flunk("collector sync observer exited")
      after
        max(0, deadline - System.monotonic_time(:millisecond)) ->
          flunk("collector sync observation was not released")
      end
    end

    def assert_sync_receipt!(binding, receipt, positive?) do
      assert is_map(receipt)
      assert Enum.sort(Map.keys(receipt)) == [:binding, :consumed, :result]
      assert receipt == Agent.get(binding.control, & &1.lifecycle.sync_receipt)
      assert receipt.binding == binding and receipt.result == :ok
      assert is_map(receipt.consumed)

      assert Enum.sort(Map.keys(receipt.consumed)) ==
               [:native_down, :native_issued, :native_revoke_ack]

      for {_kind, count} <- receipt.consumed do
        assert is_integer(count) and count >= 0
        if positive?, do: assert(count > 0)
      end

      :ok
    end

    def assert_collector_receipt!(binding, receipt) do
      assert receipt == Agent.get(binding.control, & &1.lifecycle.collector_receipt)
      assert_collector_fields!(binding, receipt)
      assert receipt.issued == Agent.get(binding.control, &MapSet.new(Map.keys(&1.issued)))
      :ok
    end

    def assert_completion_receipt!(binding, receipt) do
      assert is_map(receipt)

      assert Enum.sort(Map.keys(receipt)) ==
               [
                 :begin,
                 :caller,
                 :collector,
                 :control,
                 :control_down,
                 :copy,
                 :environments,
                 :owner,
                 :paths,
                 :retirement,
                 :stopped,
                 :token
               ]

      assert receipt.token == binding.token and receipt.owner == binding.owner
      assert receipt.caller == binding.caller and receipt.control == binding.control
      assert receipt.begin == :ok and receipt.environments == :ok and receipt.control_down == :ok
      assert receipt.copy == :ok
      assert_collector_fields!(binding, receipt.collector)
      assert is_map(receipt.retirement) and is_map(receipt.stopped)

      assert Enum.sort(Map.keys(receipt.retirement)) ==
               [:binding, :fence, :global, :private, :result, :task_down]

      assert receipt.retirement.binding == binding and receipt.retirement.result == :ok
      assert is_map(receipt.retirement.fence)
      assert Enum.sort(Map.keys(receipt.retirement.fence)) == [:binding, :result]
      assert receipt.retirement.fence.binding == binding
      assert is_boolean(receipt.retirement.fence.result)
      assert receipt.stopped.tracker == binding.collector
      refute Process.alive?(binding.collector)
      refute Process.alive?(binding.control)

      for kind <- [:private, :global] do
        pid = Map.fetch!(receipt.retirement, kind)
        assert Map.fetch!(receipt.stopped, kind) == pid
        refute Process.alive?(pid)
      end

      for path <- receipt.paths, do: assert(File.lstat(path) == {:error, :enoent})

      for {target, original} <- receipt.collector.originals do
        assert :erlang.trace_info(target, :match_spec) == original.match_spec
        assert :erlang.trace_info(target, :traced) == original.traced
      end

      :ok
    end

    defp assert_collector_fields!(binding, receipt) do
      assert is_map(receipt)

      assert Enum.sort(Map.keys(receipt)) ==
               [
                 :acknowledgements,
                 :binding,
                 :down,
                 :enabled?,
                 :issued,
                 :originals,
                 :restoration,
                 :terminal
               ]

      assert receipt.binding == binding
      assert receipt.terminal == :ok and receipt.restoration == :ok
      assert is_struct(receipt.issued, MapSet) and is_struct(receipt.down, MapSet)
      assert is_struct(receipt.acknowledgements, MapSet)
      assert receipt.issued == receipt.down
      :ok
    end

    def register_lease(context, lease, kind) do
      Agent.update(context.control, fn state ->
        %{state | issued: Map.put(state.issued, lease, kind)}
      end)

      event(context, :native_lease, %{lease: lease, kind: kind, companion: self()})
    end

    def register_handle(context, handle) do
      Agent.update(context.control, fn state ->
        %{state | handles: [handle | state.handles]}
      end)

      event(context, :completed, %{owner: handle.owner, operation_ref: handle.operation_ref})
    end

    def assert_issued_terminal!(fixture) do
      for {lease, kind} <- issued(fixture) do
        monitor = Process.monitor(lease)

        result =
          case kind do
            :asset -> Singularity.Runtime.DownloadLease.read(lease, 0..0)
            :document -> Singularity.Runtime.DownloadLease.read_document_chunk(lease, 0)
            :unknown -> Singularity.Runtime.DownloadLease.read_document_chunk(lease, 0)
          end

        assert {:error, %Singularity.Core.Error{code: :storage_unavailable}} = result
        assert_receive {:DOWN, ^monitor, :process, ^lease, _reason}, 5_000
      end

      :ok
    end

    # This runs synchronously in the capture owner after real transact returns.
    # Consumers can derive their stricter schema model here without copying the
    # descriptor into the observing process.
    def capture_summary(sealed) do
      collections = Map.fetch!(sealed, :_collections)
      texts = Map.fetch!(sealed, :_texts)

      %{
        accounting: sealed.accounting,
        selected: MapSet.size(sealed._selected),
        collection_keys: Enum.reduce(collections, 0, fn {_, rows}, n -> n + map_size(rows) end),
        versions: map_size(sealed._versions),
        drafts: map_size(sealed._drafts),
        bindings: map_size(sealed._bindings),
        texts: map_size(texts),
        documents: map_size(sealed._documents),
        ordinals:
          Enum.reduce(sealed._documents, 0, fn {_, doc}, n -> n + map_size(doc.ordinals) end),
        frames:
          Enum.reduce(texts, 0, fn {_, text}, n -> n + length(text.frames) end) +
            Enum.reduce(collections, 0, fn {_, rows}, n -> n + map_size(rows) end),
        max_binary_backing: binary_backing(sealed),
        logical_bytes: :erlang.external_size(sealed)
      }
    end

    defp binary_backing(value) when is_binary(value), do: :binary.referenced_byte_size(value)

    defp binary_backing(value) when is_map(value) do
      :maps.fold(fn k, v, n -> max(n, max(binary_backing(k), binary_backing(v))) end, 0, value)
    end

    defp binary_backing(value) when is_tuple(value),
      do: value |> Tuple.to_list() |> binary_backing()

    defp binary_backing(value) when is_list(value),
      do: Enum.reduce(value, 0, fn item, n -> max(n, binary_backing(item)) end)

    defp binary_backing(_value), do: 0
  end

  # Suppress call traces: native options contain key material. Only actual
  # return values (opaque lease PIDs) from this fixture's custodian are observed,
  # including issuance after a timeout or before a dead caller receives its PID.
  defmodule IssuedLeases do
    use GenServer
    import ExUnit.Assertions
    alias Singularity.Runtime.KnowledgeExportLiveFixture.Observer

    @mfa {Singularity.Runtime.KeyLeaseSupervisor, :start_download_lease, 2}
    @revoke {Singularity.Runtime.DownloadLease, :revoke, 1}
    @specs [
      {@mfa, [{:_, [], [{:message, false}, {:return_trace}]}]},
      {@revoke, [{:_, [], [{:return_trace}]}]}
    ]
    @journal {__MODULE__, :trace_journal}
    @draining {__MODULE__, :draining}

    def start_link(context), do: GenServer.start_link(__MODULE__, context)
    def enable(pid), do: GenServer.call(pid, :enable)

    def finalize(pid, binding, deadline),
      do:
        GenServer.call(
          pid,
          {:finalize, binding, deadline},
          max(0, deadline - System.monotonic_time(:millisecond))
        )

    def sync(pid), do: GenServer.call(pid, :delivered)

    def notify_companion_record(binding, reference) do
      send(binding.collector, {:task17_companion_revoke_observed, binding, reference})
      :ok
    end

    def assert_companion_ack!(binding, record, issued) do
      Observer.assert_companion_record!(binding, record)
      assert is_struct(issued, MapSet) and MapSet.member?(issued, record.lease)
      assert record.outcome == :ok

      actual_issued? =
        Agent.get(binding.control, fn observed ->
          Enum.any?(observed.events, fn event ->
            event.point == :native_issued and event.pid == binding.collector and
              event.lease == record.lease
          end)
        end)

      assert actual_issued?, "companion ACK has no actual collector issuance"
      :ok
    end

    # Independently called by the surviving owner before native shutdown.
    def assert_restored!(receipt) do
      assert is_map(receipt)

      assert Enum.sort(Map.keys(receipt)) ==
               [
                 :acknowledgements,
                 :binding,
                 :down,
                 :enabled?,
                 :issued,
                 :originals,
                 :restoration,
                 :terminal
               ]

      assert receipt.restoration == :ok
      assert is_map(receipt.originals)

      for {target, original} <- receipt.originals do
        assert :erlang.trace_info(target, :match_spec) == original.match_spec
        assert :erlang.trace_info(target, :traced) == original.traced
      end

      if receipt.enabled? do
        assert :erlang.trace_info(receipt.binding.custodian, :flags) == {:flags, []}
        assert :erlang.trace_info(receipt.binding.custodian, :tracer) == {:tracer, []}
      end

      :ok
    end

    def assert_unowned!(custodian) do
      assert is_pid(custodian)
      assert Process.whereis(Singularity.Runtime.KeyCustodian) == custodian
      assert Process.alive?(custodian)
      assert {:flags, []} = :erlang.trace_info(custodian, :flags)
      assert {:tracer, []} = :erlang.trace_info(custodian, :tracer)
      # Whole-set preflight before the first mutation, including the second
      # MFA. Keep the exact no-foreign-pattern assertion.
      Map.new(@specs, fn {target, _installed} ->
        assert {:match_spec, previous} = :erlang.trace_info(target, :match_spec)
        assert previous == false
        assert {:traced, false} = :erlang.trace_info(target, :traced)
        {target, %{match_spec: {:match_spec, previous}, traced: {:traced, false}}}
      end)
    end

    @impl true
    def init(context) do
      {:ok,
       %{
         context: context,
         custodian: context.custodian,
         enabled?: false,
         enable_failed?: false,
         originals: %{},
         monitors: %{},
         issued: MapSet.new(),
         down: MapSet.new(),
         acknowledgements: MapSet.new(),
         companion_monitors: %{},
         companion_registered: MapSet.new(),
         companion_down: MapSet.new(),
         companion_pending: %{},
         companion_processed: MapSet.new(),
         companion_pending_seen: MapSet.new(),
         companion_applied: MapSet.new(),
         revoking: nil,
         receipt: nil
       }}
    end

    @impl true
    def handle_call(:enable, _from, %{enabled?: false, receipt: nil} = state) do
      try do
        assert state.enable_failed? == false
        custodian = state.custodian
        originals = assert_unowned!(custodian)

        journal = %{
          custodian: custodian,
          originals: originals,
          acquired: [],
          flags?: false,
          restored?: false
        }

        Process.put(@journal, journal)

        for {target, installed} <- @specs do
          :erlang.trace_pattern(target, installed, [:local])
          Process.put(@journal, Map.update!(Process.get(@journal), :acquired, &[target | &1]))
          assert :erlang.trace_info(target, :match_spec) == {:match_spec, installed}
          assert {:traced, :local} = :erlang.trace_info(target, :traced)
        end

        assert 1 = :erlang.trace(custodian, true, [:call, {:tracer, self()}])
        Process.put(@journal, %{Process.get(@journal) | flags?: true})
        assert_owned!(Process.get(@journal))
        {:reply, :ok, %{state | enabled?: true, originals: originals}}
      catch
        kind, _reason ->
          restoration = outcome(fn -> restore!() end)

          Agent.update(state.context.control, fn observed ->
            put_in(observed, [:lifecycle, :enable_failure], %{
              kind: kind,
              restoration: restoration
            })
          end)

          originals =
            case Process.get(@journal) do
              nil -> %{}
              journal -> journal.originals
            end

          {:reply, {:error, :trace_enable_failed},
           %{state | enable_failed?: true, originals: originals}}
      end
    end

    def handle_call(:enable, _from, %{enabled?: true, receipt: nil} = state),
      do: {:reply, :ok, state}

    def handle_call(:enable, _from, state),
      do: {:reply, {:error, :trace_collector_closed}, state}

    def handle_call(:delivered, _from, %{enabled?: false} = state), do: {:reply, :ok, state}

    def handle_call(:delivered, _from, state) do
      deadline = System.monotonic_time(:millisecond) + 5_000
      before = state
      Process.put(@draining, state)

      gate =
        outcome(fn ->
          updated =
            Observer.await_sync_probe(state.context, deadline, state, fn message, current ->
              registered = register_companion(message, current)
              Process.put(@draining, registered)
              registered
            end)

          Process.put(@draining, updated)
          :ok
        end)

      state = Process.get(@draining, state)
      Process.delete(@draining)

      {result, state} =
        if gate == :ok do
          drain(state, false, deadline)
        else
          {gate, state}
        end

      receipt = %{
        binding: lease_binding(state),
        result: result,
        consumed: %{
          native_issued: MapSet.size(state.issued) - MapSet.size(before.issued),
          native_revoke_ack:
            MapSet.size(state.acknowledgements) - MapSet.size(before.acknowledgements),
          native_down: MapSet.size(state.down) - MapSet.size(before.down)
        }
      }

      Agent.update(state.context.control, &put_in(&1, [:lifecycle, :sync_receipt], receipt))
      {:reply, result, state}
    end

    def handle_call({:finalize, binding, deadline}, {caller, _tag}, state) do
      assert caller in [state.context.parent, state.context.owner]
      assert binding == lease_binding(state)

      if state.receipt do
        {:reply, state.receipt, state}
      else
        Process.put(@draining, state)

        seal =
          outcome(fn ->
            updated = drain_companion_down(state, deadline)
            Process.put(@draining, updated)
            Observer.seal_companion_records(state.context, binding, updated.companion_down)
            :ok
          end)

        state = Process.get(@draining, state)
        Process.delete(@draining)

        {terminal, state} =
          cond do
            seal != :ok -> {seal, state}
            state.enable_failed? -> {{:error, :trace_enable_failed}, state}
            state.enabled? -> drain(state, true, deadline)
            true -> {:ok, state}
          end

        restoration = outcome(fn -> restore!() end)

        receipt = %{
          binding: binding,
          enabled?: state.enabled?,
          originals: state.originals,
          issued: state.issued,
          down: state.down,
          acknowledgements: state.acknowledgements,
          terminal: terminal,
          restoration: restoration
        }

        Agent.update(
          state.context.control,
          &put_in(&1, [:lifecycle, :collector_receipt], receipt)
        )

        {:reply, receipt, %{state | receipt: receipt}}
      end
    end

    @impl true
    def handle_info(message, state), do: {:noreply, reduce(message, state)}

    @impl true
    def terminate(_reason, state) do
      # Best effort containment only. A missing explicit receipt stays FAIL.
      outcome(fn -> restore!() end)
      for {monitor, _lease} <- state.monitors, do: Process.demonitor(monitor, [:flush])

      for {monitor, _producer} <- state.companion_monitors,
          do: Process.demonitor(monitor, [:flush])

      :ok
    end

    defp reduce(
           {:trace, custodian, :return_from, @mfa, {:ok, lease}},
           %{custodian: custodian} = state
         )
         when is_pid(lease) do
      if MapSet.member?(state.issued, lease) do
        state
      else
        monitor = Process.monitor(lease)

        Agent.update(state.context.control, fn observed ->
          %{observed | issued: Map.put_new(observed.issued, lease, :unknown)}
        end)

        observed(state, :native_issued, self(), %{lease: lease})

        state = %{
          state
          | monitors: Map.put(state.monitors, monitor, lease),
            issued: MapSet.put(state.issued, lease)
        }

        Enum.reduce(state.companion_pending, state, fn {_id, record}, current ->
          companion_record(record, current)
        end)
      end
    end

    defp reduce({:task17_companion_register, _registration, _reference} = message, state),
      do: register_companion(message, state)

    defp reduce({:task17_companion_revoke_observed, binding, reference}, state) do
      assert binding == lease_binding(state) and is_reference(reference)
      snapshot = Observer.companion_snapshot(state.context.control)
      record = Map.get(snapshot.records, reference)
      companion_record(record, state)
    end

    defp reduce(
           {:trace, custodian, :call, {Singularity.Runtime.DownloadLease, :revoke, [lease]}},
           %{custodian: custodian} = state
         )
         when is_pid(lease),
         do: %{state | revoking: lease}

    defp reduce(
           {:trace, custodian, :return_from, @revoke, :ok},
           %{custodian: custodian, revoking: lease} = state
         )
         when is_pid(lease) do
      observed(state, :native_revoke_ack, custodian, %{
        lease: lease,
        outcome: :ok,
        source: :custodian
      })

      %{state | revoking: nil, acknowledgements: MapSet.put(state.acknowledgements, lease)}
    end

    defp reduce(
           {:trace, custodian, :return_from, @revoke, _failure},
           %{custodian: custodian} = state
         ),
         do: %{state | revoking: nil}

    defp reduce({:DOWN, monitor, :process, pid, reason}, state) do
      cond do
        Map.get(state.monitors, monitor) == pid ->
          observed(state, :native_down, self(), %{lease: pid})

          %{
            state
            | monitors: Map.delete(state.monitors, monitor),
              down: MapSet.put(state.down, pid)
          }

        Map.get(state.companion_monitors, monitor) == pid ->
          refute reason == :noproc
          observed(state, :companion_down, self(), %{producer: pid, monitor: monitor})

          %{
            state
            | companion_monitors: Map.delete(state.companion_monitors, monitor),
              companion_down: MapSet.put(state.companion_down, pid)
          }

        true ->
          state
      end
    end

    # Do not inspect, retain or log unexpected/foreign trace payloads.
    defp reduce(_unexpected, state), do: state

    defp observed(state, point, pid, values) do
      event = Map.merge(values, %{point: point, pid: pid})

      Agent.update(
        state.context.control,
        &Map.update!(&1, :events, fn events -> [event | events] end)
      )

      send(
        state.context.parent,
        {:knowledge_export, state.context.token, point, pid, values}
      )
    end

    defp register_companion(
           {:task17_companion_register, registration, reference},
           state
         ) do
      assert is_map(registration) and is_reference(reference)
      binding = lease_binding(state)
      assert registration.binding == binding
      lifecycle = Agent.get(state.context.control, & &1.lifecycle)
      private = lifecycle.child_specs.private
      tracker = lifecycle.child_specs.tracker
      assert private.id == {Task.Supervisor, binding.token}
      assert tracker.id == {__MODULE__, binding.token} and tracker.pid == self()
      assert private.pid == registration.supervisor
      assert lifecycle.owner == binding.owner and lifecycle.caller == binding.caller
      assert lifecycle.fixture.custodian == binding.custodian
      producer = registration.producer
      assert is_pid(producer)

      cond do
        lifecycle.phase != :active or not Process.alive?(producer) ->
          # No monitor ACK means this abandoned attempt could not acquire.
          # It earns neither registration nor native/producers-DOWN credit.
          state

        MapSet.member?(state.companion_registered, producer) ->
          assert producer in Task.Supervisor.children(registration.supervisor)
          send(producer, {:task17_companion_monitored, reference, self()})
          state

        true ->
          assert producer in Task.Supervisor.children(registration.supervisor)
          monitor = Process.monitor(producer)

          if Process.alive?(producer) do
            try do
              Observer.install_companion_registration(state.context, registration)
            catch
              kind, reason ->
                Process.demonitor(monitor, [:flush])
                :erlang.raise(kind, reason, __STACKTRACE__)
            end

            updated = %{
              state
              | companion_monitors: Map.put(state.companion_monitors, monitor, producer),
                companion_registered: MapSet.put(state.companion_registered, producer)
            }

            send(producer, {:task17_companion_monitored, reference, self()})
            updated
          else
            Process.demonitor(monitor, [:flush])
            state
          end
      end
    end

    defp drain_companion_down(state, deadline) do
      Process.put(@draining, state)

      if map_size(state.companion_monitors) == 0 do
        state
      else
        receive do
          {:DOWN, monitor, :process, _producer, _reason} = message
          when is_map_key(state.companion_monitors, monitor) ->
            drain_companion_down(reduce(message, state), deadline)
        after
          max(0, deadline - System.monotonic_time(:millisecond)) ->
            flunk("actual configured companion DOWN was not observed")
        end
      end
    end

    defp companion_record(record, state) do
      binding = lease_binding(state)
      Observer.assert_companion_record!(binding, record)

      cond do
        MapSet.member?(state.companion_processed, record.id) ->
          state

        not MapSet.member?(state.issued, record.lease) ->
          state = %{
            state
            | companion_pending: Map.put(state.companion_pending, record.id, record),
              companion_pending_seen: MapSet.put(state.companion_pending_seen, record.id)
          }

          publish_companion_progress(state)

        true ->
          state = %{
            state
            | companion_pending: Map.delete(state.companion_pending, record.id),
              companion_processed: MapSet.put(state.companion_processed, record.id)
          }

          state =
            if record.outcome == :ok do
              assert_companion_ack!(binding, record, state.issued)

              unless MapSet.member?(state.acknowledgements, record.lease) do
                observed(state, :native_revoke_ack, record.producer, %{
                  lease: record.lease,
                  outcome: :ok,
                  source: :companion
                })
              end

              %{
                state
                | acknowledgements: MapSet.put(state.acknowledgements, record.lease),
                  companion_applied: MapSet.put(state.companion_applied, record.id)
              }
            else
              state
            end

          publish_companion_progress(state)
      end
    end

    defp publish_companion_progress(state) do
      progress = %{
        binding: lease_binding(state),
        pending_before_issuance: state.companion_pending_seen,
        applied: state.companion_applied
      }

      Agent.update(state.context.control, &Map.put(&1, :companion_ack_progress, progress))
      state
    end

    defp reconcile_companion_records(state) do
      snapshot = Observer.companion_snapshot(state.context.control)

      Enum.reduce(snapshot.records, state, fn {_id, record}, current ->
        companion_record(record, current)
      end)
    end

    defp drain(state, terminal?, deadline) do
      Process.put(@draining, state)

      try do
        # This is a persisted snapshot, not a fence over future live producers.
        # Reconcile before folding the actual queued native issuance traces.
        state = reconcile_companion_records(state)
        Process.put(@draining, state)
        reference = :erlang.trace_delivered(state.custodian)
        state = drain_loop(state, reference, false, terminal?, deadline)
        {:ok, state}
      catch
        kind, _reason -> {{:error, kind}, Process.get(@draining)}
      after
        Process.delete(@draining)
      end
    end

    defp drain_loop(state, reference, delivered?, terminal?, deadline) do
      Process.put(@draining, state)

      if delivered? and
           (not terminal? or
              (map_size(state.monitors) == 0 and state.revoking == nil and
                 map_size(state.companion_pending) == 0)) do
        state
      else
        custodian = state.custodian
        remaining = max(0, deadline - System.monotonic_time(:millisecond))

        receive do
          {:task17_companion_register, _registration, _id} = message ->
            drain_loop(reduce(message, state), reference, delivered?, terminal?, deadline)

          {:task17_companion_revoke_observed, _binding, _id} = message ->
            drain_loop(reduce(message, state), reference, delivered?, terminal?, deadline)

          {:trace_delivered, ^custodian, ^reference} ->
            drain_loop(state, reference, true, terminal?, deadline)

          {:trace, _pid, _point, _payload} = message ->
            drain_loop(reduce(message, state), reference, delivered?, terminal?, deadline)

          {:trace, _pid, _point, _target, _result} = message ->
            drain_loop(reduce(message, state), reference, delivered?, terminal?, deadline)

          {:DOWN, monitor, :process, lease, _reason} = message
          when is_map_key(state.monitors, monitor) or
                 is_map_key(state.companion_monitors, monitor) ->
            _ = lease
            drain_loop(reduce(message, state), reference, delivered?, terminal?, deadline)
        after
          remaining -> raise "native lease trace delivery/terminal drain was not acknowledged"
        end
      end
    end

    defp lease_binding(state),
      do: %{
        token: state.context.token,
        owner: state.context.owner,
        caller: state.context.parent,
        control: state.context.control,
        collector: self(),
        custodian: state.custodian
      }

    defp assert_owned!(journal) do
      # All targets and untouched partial-journal entries are checked before
      # disabling ANY flags or restoring ANY pattern.
      for {target, installed} <- @specs do
        if target in journal.acquired and not journal.restored? do
          assert :erlang.trace_info(target, :match_spec) == {:match_spec, installed}
          assert {:traced, :local} = :erlang.trace_info(target, :traced)
        else
          original = Map.fetch!(journal.originals, target)
          assert :erlang.trace_info(target, :match_spec) == original.match_spec
          assert :erlang.trace_info(target, :traced) == original.traced
        end
      end

      if journal.flags? and not journal.restored? do
        assert :erlang.trace_info(journal.custodian, :flags) == {:flags, [:call]}
        assert :erlang.trace_info(journal.custodian, :tracer) == {:tracer, self()}
      else
        assert :erlang.trace_info(journal.custodian, :flags) == {:flags, []}
        assert :erlang.trace_info(journal.custodian, :tracer) == {:tracer, []}
      end

      :ok
    end

    defp restore! do
      case Process.get(@journal) do
        nil ->
          :ok

        journal ->
          assert_owned!(journal)

          unless journal.restored? do
            if journal.flags?, do: assert(1 = :erlang.trace(journal.custodian, false, [:call]))

            for target <- journal.acquired do
              {:match_spec, original} = Map.fetch!(journal.originals, target).match_spec
              :erlang.trace_pattern(target, original, [:local])
            end

            Process.put(@journal, %{journal | restored?: true})
          end

          assert_owned!(Process.get(@journal))
      end

      :ok
    end

    defp outcome(callback) do
      try do
        :ok = callback.()
      catch
        kind, _reason -> {:error, kind}
      end
    end
  end

  defmodule ObservedScoped do
    alias Singularity.Runtime.KnowledgeExportLiveFixture.Observer

    def transact(context, repo, scope, callback), do: transact(context, repo, scope, [], callback)

    def transact(context, repo, scope, options, callback) do
      result = Singularity.Storage.ScopedRepo.transact(repo, scope, options, callback)

      case result do
        {:ok, %{capture_id: _} = sealed} ->
          false = repo.in_transaction?()
          summary = Observer.capture_summary(sealed)
          if summarize = context[:summarize_capture], do: summarize.(sealed)
          Observer.event(context, :capture_committed, summary)

        {:after_commit, callback} when is_function(callback, 0) ->
          false = repo.in_transaction?()
          Observer.event(context, :completion_committed)

        _ ->
          :ok
      end

      result
    end
  end

  defmodule ObservedCustodian do
    alias Singularity.Runtime.KnowledgeExportLiveFixture.Observer

    def export_lease(context, request) do
      kind = if request.purpose == :download, do: :asset, else: :document
      registration = Observer.register_companion(context)
      Observer.event(context, :before_native_lease, %{kind: kind, companion: self()})

      result =
        Singularity.Runtime.KeyCustodian.export_lease(Singularity.Runtime.KeyCustodian, request)

      case result do
        {:ok, lease} ->
          Observer.associate_companion_lease(context, registration, lease)
          Observer.register_lease(context, lease, kind)

        {:error, _} ->
          Observer.event(context, :native_lease_denied, %{kind: kind})
      end

      result
    end

    def lease(context, request), do: export_lease(context, request)
  end

  defmodule ObservedReader do
    alias Singularity.Runtime.{DownloadLease, KnowledgeExportLiveFixture.Observer}

    def read(context, lease, range) do
      Observer.event(context, :before_native_read, %{kind: :asset, lease: lease})
      result = DownloadLease.read(lease, range)
      observe(context, lease, :asset, result)
      result
    end

    def read_document_chunk(context, lease, ordinal) do
      Observer.event(context, :before_native_read, %{
        kind: :document,
        lease: lease,
        ordinal: ordinal
      })

      result = DownloadLease.read_document_chunk(lease, ordinal)
      observe(context, lease, :document, result)
      result
    end

    def authenticate_empty_document_original(context, lease) do
      result = DownloadLease.authenticate_empty_document_original(lease)

      Observer.event(context, :native_empty_authenticated, %{
        lease: lease,
        outcome: outcome(result)
      })

      result
    end

    def revoke(context, lease) do
      result = DownloadLease.revoke(lease)
      Observer.record_companion_revoke(context, lease, outcome(result))
      Observer.event(context, :native_revoke_ack, %{lease: lease, outcome: outcome(result)})
      result
    end

    defp observe(context, lease, kind, {:ok, bytes}) when is_binary(bytes) do
      ceiling = if kind == :document, do: 4_194_304, else: 65_536
      true = byte_size(bytes) <= ceiling

      Observer.event(context, :native_piece, %{
        lease: lease,
        kind: kind,
        byte_size: byte_size(bytes)
      })
    end

    defp observe(context, lease, kind, result),
      do:
        Observer.event(context, :native_read_result, %{
          lease: lease,
          kind: kind,
          outcome: outcome(result)
        })

    defp outcome(:ok), do: :ok
    defp outcome({:ok, _}), do: :ok
    defp outcome({:error, %Singularity.Core.Error{code: code}}), do: code
    defp outcome({:error, _}), do: :error
  end

  def with_fixture(callback) when is_function(callback, 1) do
    settings =
      Map.new(@settings, fn {app, key} -> {{app, key}, Application.fetch_env(app, key)} end)

    environments = Map.new(@fixture_apps, &{&1, Map.new(Application.get_all_env(&1))})
    caller = self()
    token = make_ref()
    acquisition_probe = Observer.acquisition_probe()

    checkpoint = fn stage, resources ->
      fixture_checkpoint(token, caller, settings, environments, stage, resources)

      if stage == :ready && acquisition_probe do
        initial = Process.get({__MODULE__, token})

        Agent.update(initial.control, fn state ->
          put_in(state, [:lifecycle, :probe], Map.take(acquisition_probe, [:pid, :reference]))
        end)

        Observer.acquisition_checkpoint(acquisition_probe, :initial_registered, %{
          token: token,
          owner: initial.owner,
          caller: caller,
          control: initial.control,
          roots: initial.roots,
          child_specs: %{}
        })
      end
    end

    try do
      ResourceOwner.with_checkpoint(checkpoint, fn ->
        NativeAssetFixture.with_fixture(fn native ->
          {control, roots} =
            receive do
              {:task17_fixture_ready, ^token, owner, control, roots} when owner == native.owner ->
                {control, roots}
            after
              5_000 -> flunk("fixture acquisition receipt is missing")
            end

          observer = %{parent: caller, token: token, owner: native.owner, control: control}
          fixture = register_native!(native, observer, roots)
          acquisition_checkpoint!(fixture, :native_registered)
          fixture = start_fixture_children!(fixture)
          assert_owned_repo!(fixture)
          assert_private_disjoint_roots!(fixture)
          write_sentinels!(fixture)
          permissions = permission_snapshot(fixture)
          assert_denied_write_guard!(permissions)

          Agent.update(control, fn state ->
            state
            |> put_in([:lifecycle, :permissions], permissions)
            |> put_in([:lifecycle, :sentinels?], true)
          end)

          fixture =
            Map.merge(fixture, %{
              permission_baseline: permissions,
              permission_snapshot: fn -> permission_snapshot(fixture) end,
              permission_scope: fn controls, fun -> permission_scope(fixture, controls, fun) end,
              with_preowner_recovery: fn name, fun ->
                with_preowner_recovery(fixture, name, fun)
              end
            })

          Agent.update(control, &put_in(&1, [:lifecycle, :fixture], cleanup_context(fixture)))
          Process.put({__MODULE__, token, :binding}, collector_binding(fixture))
          callback.(fixture)
        end)
      end)
    after
      owner = Process.delete({__MODULE__, token, :owner})
      binding = Process.delete({__MODULE__, token, :binding})
      if owner, do: require_completion!(token, caller, owner, binding, environments)
    end
  end

  defp fixture_checkpoint(token, caller, _settings, _environments, :before_arm, resources) do
    assert self() == caller
    assert resources.caller == caller
    Process.put({__MODULE__, token, :owner}, resources.owner)
    :ok
  end

  defp fixture_checkpoint(token, caller, settings, environments, :ready, resources) do
    assert self() == resources.owner
    assert resources.caller == caller
    key = {__MODULE__, token}

    initial = %{
      owner: self(),
      caller: caller,
      token: token,
      control: nil,
      native_root: resources.names.storage_root,
      paths: [],
      roots: nil,
      begin?: false,
      begin_result: nil
    }

    Process.put(key, initial)
    fallback = Path.join(resources.names.storage_root, "task17")
    private_directory!(fallback)
    register_initial_path!(key, fallback)
    qualified = KnowledgeExportQualificationRoot.allocate!(fallback)
    if qualified != fallback, do: register_initial_path!(key, qualified)
    artifact = Path.join(qualified, "artifacts")
    offline = Path.join(qualified, "offline")
    for root <- [artifact, offline], do: private_directory!(root)

    roots = %{
      qualified: qualified,
      artifact: artifact,
      offline: offline,
      storage: Path.join(resources.names.storage_root, "objects")
    }

    Process.put(key, %{Process.get(key) | roots: roots})
    initial = Process.get(key)

    {:ok, control} =
      Agent.start_link(fn ->
        %{
          events: [],
          issued: %{},
          handles: [],
          lifecycle: %{
            owner: initial.owner,
            caller: caller,
            token: token,
            phase: :initial,
            stopped: %{},
            stop_receipts: %{},
            task_down: %{},
            fence_receipt: nil,
            sync_probe: nil,
            sync_receipt: nil,
            child_specs: %{},
            native: nil,
            fixture: nil,
            startup: nil,
            startup_attempted?: false,
            permissions: nil,
            permission_scopes: [],
            sentinels?: false,
            root_snapshots: nil,
            collector_receipt: nil,
            retirement_receipt: nil,
            enable_failure: nil,
            probe: nil,
            begin_result: nil
          }
        }
      end)

    Process.put(key, %{Process.get(key) | control: control})
    # Settings are changed only after their surviving cleanup owner exists.
    Application.put_env(:singularity_runtime, :knowledge_export_root, artifact)
    send(caller, {:task17_fixture_ready, token, self(), control, roots})

    exact? =
      settings ==
        Map.new(@settings, fn {app, setting} ->
          {{app, setting}, Map.fetch(environments[app], setting)}
        end)

    assert exact?, "fixture initial settings differ from captured environments"
    :ok
  end

  defp fixture_checkpoint(token, _caller, settings, _environments, :owner_cleanup_begin, _r) do
    key = {__MODULE__, token}

    case Process.get(key) do
      nil ->
        :ok

      initial ->
        assert self() == initial.owner
        Process.put(key, %{initial | begin?: true})
        result = fixed_outcome(fn -> finish_fixture!(key, settings) end)
        Process.put(key, %{Process.get(key) | begin_result: result})

        if initial.control && Process.alive?(initial.control),
          do: Agent.update(initial.control, &put_in(&1, [:lifecycle, :begin_result], result))

        assert result == :ok
    end
  end

  defp fixture_checkpoint(token, caller, settings, environments, :owner_cleanup_completed, r) do
    key = {__MODULE__, token}
    initial = Process.get(key)
    # A failed full finalizer is never retried as successful initial cleanup.
    initial_result =
      fixed_outcome(fn ->
        if initial && not initial.begin? do
          assert initial.control == nil or
                   Agent.get(initial.control, & &1.lifecycle.native) == nil

          cleanup_initial_paths!(initial, true)
          restore_settings!(settings)
        end
      end)

    env_result = fixed_outcome(fn -> assert_environments!(environments) end)
    begin_result = if initial && initial.begin?, do: initial.begin_result, else: initial_result
    control = if initial, do: initial.control

    {copy_result, copied} =
      try do
        copied =
          if control && Process.alive?(control),
            do:
              Agent.get(
                control,
                &Map.take(
                  &1.lifecycle,
                  [:collector_receipt, :retirement_receipt, :stopped, :probe]
                )
              ),
            else: %{}

        {:ok, copied}
      catch
        kind, _reason -> {{:error, kind}, %{}}
      end

    control_result =
      fixed_outcome(fn ->
        if control do
          monitor = Process.monitor(control)

          try do
            assert Process.alive?(control)
            assert :ok = Agent.stop(control, :normal, 5_000)
            assert_receive {:DOWN, ^monitor, :process, ^control, :normal}, 5_000
            refute Process.alive?(control)
          after
            Process.demonitor(monitor, [:flush])
          end
        end
      end)

    receipt = %{
      token: token,
      owner: self(),
      caller: caller,
      control: control,
      begin: begin_result,
      environments: env_result,
      control_down: control_result,
      copy: copy_result,
      collector: copied[:collector_receipt],
      retirement: copied[:retirement_receipt],
      stopped: Map.get(copied, :stopped, %{}),
      paths: if(initial, do: Enum.map(initial.paths, & &1.path), else: [])
    }

    Process.delete(key)
    send(caller, {:task17_fixture_completed, token, self(), receipt})

    if probe = copied[:probe],
      do: send(probe.pid, {:task17_fixture_completed, probe.reference, self(), receipt})

    assert r.owner == self()

    assert begin_result == :ok and env_result == :ok and control_result == :ok and
             copy_result == :ok

    :ok
  end

  defp fixture_checkpoint(_token, _caller, _settings, _environments, _stage, _r), do: :ok

  defp register_native!(native, observer, roots) do
    assert native.owner == observer.owner
    assert Process.alive?(native.owner) and Process.alive?(native.infrastructure)
    custodian = Process.whereis(KeyCustodian)
    assert is_pid(custodian) and Process.alive?(custodian)
    children = Supervisor.which_children(native.infrastructure)

    assert Enum.count(children, fn {id, pid, _, _} ->
             id == KeyCustodian and pid == custodian
           end) == 1

    [{@global_tasks, global, :supervisor, _}] =
      Enum.filter(children, fn {id, _, _, _} -> id == @global_tasks end)

    assert Process.whereis(@global_tasks) == global
    assert Task.Supervisor.children(global) == []
    exact_root? = native.destination.object_root == roots.storage
    assert exact_root?, "native fixture object root differs from registered cleanup root"

    roots =
      roots
      |> Map.put(:storage, native.destination.object_root)
      |> Map.put(:backup, Application.fetch_env!(:singularity_storage, :backup_root))

    fixture =
      Map.merge(native, %{
        observer: Map.put(observer, :custodian, custodian),
        custodian: custodian,
        global_supervisor: global,
        roots: roots,
        supervisor: nil,
        lease_tracker: nil,
        inputs: independent_inputs(),
        sources: %{},
        graph: %{}
      })

    # The native references and both planned child IDs are published together.
    specs = %{
      private: %{id: {Task.Supervisor, observer.token}, status: :planned, pid: nil},
      tracker: %{id: {IssuedLeases, observer.token}, status: :planned, pid: nil}
    }

    assert Agent.get(observer.control, & &1.lifecycle.phase) == :initial
    cleanup = cleanup_context(fixture)

    Agent.update(observer.control, fn state ->
      state
      |> put_in([:lifecycle, :native], cleanup)
      |> put_in([:lifecycle, :fixture], cleanup)
      |> put_in([:lifecycle, :child_specs], specs)
      |> put_in([:lifecycle, :phase], :starting)
    end)

    fixture
  end

  defp start_fixture_children!(fixture) do
    for {kind, specification} <- [
          {:private, {Task.Supervisor, []}},
          {:tracker, {IssuedLeases, fixture.observer}}
        ] do
      planned = Agent.get(fixture.observer.control, &Map.fetch!(&1.lifecycle.child_specs, kind))

      Agent.update(
        fixture.observer.control,
        &put_in(&1, [:lifecycle, :child_specs, kind, :status], :starting)
      )

      spec =
        Supervisor.child_spec(specification, id: planned.id, restart: :temporary, shutdown: 5_000)

      assert {:ok, pid} = Supervisor.start_child(fixture.infrastructure, spec)
      point = if kind == :private, do: :private_start_returned, else: :tracker_start_returned
      acquisition_checkpoint!(fixture, point, %{kind: kind, id: planned.id, pid: pid})

      Agent.update(fixture.observer.control, fn state ->
        state
        |> put_in([:lifecycle, :child_specs, kind, :pid], pid)
        |> put_in([:lifecycle, :child_specs, kind, :status], :started)
      end)
    end

    fixture = resolve_fixture_children!(fixture)

    Agent.update(fixture.observer.control, fn state ->
      state
      |> put_in([:lifecycle, :fixture], cleanup_context(fixture))
      |> put_in([:lifecycle, :phase], :active)
    end)

    fixture
  end

  defp cleanup_context(fixture) do
    fixture
    |> Map.take([
      :owner,
      :destination,
      :infrastructure,
      :repositories,
      :session,
      :custodian,
      :global_supervisor,
      :roots,
      :supervisor,
      :lease_tracker,
      :permission_baseline
    ])
    |> Map.put(:destination, Map.take(fixture.destination, [:database, :object_root]))
    |> Map.put(
      :observer,
      Map.take(fixture.observer, [:parent, :token, :owner, :control, :custodian])
    )
  end

  defp acquisition_checkpoint!(fixture, point, returned_child \\ nil) do
    probe = Observer.acquisition_probe()

    if probe do
      values =
        fixture |> Map.take([:owner, :infrastructure, :custodian, :global_supervisor, :roots])

      values =
        Map.merge(values, %{
          token: fixture.observer.token,
          caller: fixture.observer.parent,
          control: fixture.observer.control,
          returned_child: returned_child,
          child_specs: Agent.get(fixture.observer.control, & &1.lifecycle.child_specs)
        })

      Observer.acquisition_checkpoint(probe, point, values)
    end

    :ok
  end

  defp resolve_fixture_children!(fixture) do
    children = Supervisor.which_children(fixture.infrastructure)
    journal = Agent.get(fixture.observer.control, & &1.lifecycle.child_specs)

    Enum.reduce([:private, :tracker], fixture, fn kind, current ->
      entry = Map.fetch!(journal, kind)
      found = Enum.filter(children, fn {id, _, _, _} -> id == entry.id end)

      pid =
        case {entry.status, found} do
          {:planned, []} ->
            nil

          {status, [{id, pid, _, _}]} when status in [:starting, :started] and is_pid(pid) ->
            assert id == entry.id
            assert entry.pid == nil or entry.pid == pid
            assert Process.alive?(pid)

            Agent.update(fixture.observer.control, fn state ->
              state
              |> put_in([:lifecycle, :child_specs, kind, :pid], pid)
              |> put_in([:lifecycle, :child_specs, kind, :status], :started)
            end)

            pid

          _ ->
            flunk("fixture child acquisition is ambiguous or replaced")
        end

      field = if kind == :private, do: :supervisor, else: :lease_tracker
      Map.put(current, field, pid)
    end)
  end

  defp finish_fixture!(key, settings) do
    initial = Process.get(key)

    if initial.control do
      fixture = Agent.get(initial.control, fn state -> state.lifecycle.fixture end)

      if fixture do
        Agent.update(initial.control, &put_in(&1, [:lifecycle, :phase], :closing))
        fixture = resolve_fixture_children_for_cleanup!(fixture)
        deadline = System.monotonic_time(:millisecond) + 5_000
        # Continue to an ownership-safe explicit collector restoration even
        # when retirement/terminal proof fails. Both outcomes remain failures.
        retirement =
          fixed_outcome(fn ->
            close_handles!(fixture)
            stop_startup!(fixture, deadline)
            stop_tasks!(fixture, deadline)
            native_completion_fence!(fixture, deadline)
          end)

        collector = fixed_outcome(fn -> finalize_collector!(fixture, deadline) end)

        Agent.update(initial.control, fn state ->
          put_in(state, [:lifecycle, :retirement_receipt], %{
            binding: collector_binding(fixture),
            result: retirement,
            fence: state.lifecycle.fence_receipt,
            task_down: state.lifecycle.task_down,
            private: fixture.supervisor,
            global: fixture.global_supervisor
          })
        end)

        proof =
          fixed_outcome(fn ->
            assert retirement == :ok and collector == :ok
            Observer.assert_issued_terminal!(fixture)
            restore_permission_scopes!(fixture)
            assert_owned_repo!(fixture)
            baseline = Agent.get(initial.control, & &1.lifecycle.permissions)

            if baseline do
              assert permission_snapshot(fixture) == baseline
              assert_denied_write_guard!(baseline)
            end

            assert_fixture_neighbors!(fixture)
            observe_cleanup!(fixture, deadline)
            cleanup_initial_paths!(initial)
            restore_settings!(settings)
          end)

        assert retirement == :ok and collector == :ok and proof == :ok
      else
        cleanup_initial_paths!(initial)
        restore_settings!(settings)
      end
    else
      cleanup_initial_paths!(initial)
      restore_settings!(settings)
    end

    :ok
  end

  defp resolve_fixture_children_for_cleanup!(fixture) do
    if stopped?(fixture, :infrastructure, fixture.infrastructure) do
      refute Process.alive?(fixture.infrastructure)
      fixture
    else
      resolve_fixture_children!(fixture)
    end
  end

  defp native_completion_fence!(fixture, deadline) do
    if stopped?(fixture, :infrastructure, fixture.infrastructure) do
      retirement = Agent.get(fixture.observer.control, & &1.lifecycle.retirement_receipt)
      assert retirement.binding == collector_binding(fixture) and retirement.result == :ok
      assert retirement.fence.binding == collector_binding(fixture)
      assert is_boolean(retirement.fence.result)
      assert stopped?(fixture, :private, fixture.supervisor)
      assert stopped?(fixture, :global, fixture.global_supervisor)
      assert stopped?(fixture, :tracker, fixture.lease_tracker)
      assert Agent.get(fixture.observer.control, & &1.lifecycle.collector_receipt).terminal == :ok
    else
      assert Process.whereis(KeyCustodian) == fixture.custodian
      assert Process.alive?(fixture.custodian)
      # Boolean only. False is valid after a real revocation; this does not
      # expose state, renew a session or rely on cross-sender FIFO.
      result =
        bounded_stop_call!(
          fn ->
            KeyCustodian.unlocked?(fixture.custodian, fixture.session.session_id)
          end,
          deadline
        )

      assert is_boolean(result)

      Agent.update(
        fixture.observer.control,
        &put_in(&1, [:lifecycle, :fence_receipt], %{
          binding: collector_binding(fixture),
          result: result
        })
      )
    end

    :ok
  end

  defp finalize_collector!(%{lease_tracker: nil}, _deadline), do: :ok

  defp finalize_collector!(fixture, deadline) do
    binding = collector_binding(fixture)

    receipt =
      if stopped?(fixture, :tracker, fixture.lease_tracker) do
        refute Process.alive?(fixture.lease_tracker)
        Agent.get(fixture.observer.control, & &1.lifecycle.collector_receipt)
      else
        receipt = IssuedLeases.finalize(fixture.lease_tracker, binding, deadline)
        assert receipt == Agent.get(fixture.observer.control, & &1.lifecycle.collector_receipt)
        receipt
      end

    proof =
      fixed_outcome(fn ->
        Observer.assert_collector_receipt!(binding, receipt)
      end)

    restoration =
      fixed_outcome(fn ->
        assert is_map(receipt) and receipt.binding == binding

        unless stopped?(fixture, :infrastructure, fixture.infrastructure),
          do: IssuedLeases.assert_restored!(receipt)
      end)

    stopped =
      fixed_outcome(fn ->
        stop_owned!(
          fixture,
          :tracker,
          fixture.lease_tracker,
          fn ->
            GenServer.stop(fixture.lease_tracker, :normal, remaining(deadline))
          end,
          deadline
        )
      end)

    assert proof == :ok and restoration == :ok and stopped == :ok
    :ok
  end

  defp collector_binding(fixture),
    do: %{
      token: fixture.observer.token,
      owner: fixture.owner,
      caller: fixture.observer.parent,
      control: fixture.observer.control,
      collector: fixture.lease_tracker,
      custodian: fixture.custodian
    }

  defp observe_cleanup!(fixture, deadline) do
    probe = Agent.get(fixture.observer.control, & &1.lifecycle.probe)

    if probe do
      assert Process.alive?(probe.pid)

      receipt =
        Agent.get(fixture.observer.control, fn state ->
          %{
            binding: collector_binding(fixture),
            collector: state.lifecycle.collector_receipt,
            retirement: state.lifecycle.retirement_receipt,
            stopped: state.lifecycle.stopped
          }
        end)

      reference = probe.reference
      controller = probe.pid
      monitor = Process.monitor(controller)

      try do
        send(controller, {:task17_fixture_restored, reference, self(), receipt})

        receive do
          {:task17_fixture_restored_checked, ^reference, ^controller} ->
            :ok

          {:DOWN, ^monitor, :process, ^controller, _} ->
            flunk("fixture cleanup observer exited before checking restoration")
        after
          remaining(deadline) -> flunk("fixture cleanup observer did not check restoration")
        end
      after
        Process.demonitor(monitor, [:flush])
      end
    end

    :ok
  end

  defp assert_fixture_neighbors!(fixture) do
    if Agent.get(fixture.observer.control, & &1.lifecycle.sentinels?) do
      assert File.read!(Path.join(fixture.roots.artifact, "foreign-neighbor")) ==
               "foreign unchanged"

      assert File.read!(Path.join([fixture.roots.artifact, "malformed-neighbor", "sentinel"])) ==
               "malformed unchanged"

      assert File.read!(Path.join(fixture.roots.backup, "task17-sentinel")) == "backup unchanged"

      assert Enum.sort(File.ls!(fixture.roots.artifact)) == [
               "foreign-neighbor",
               "malformed-neighbor"
             ]
    end

    :ok
  end

  defp register_initial_path!(key, path) do
    parent = Path.dirname(path)

    record = %{
      path: path,
      identity: directory_identity!(path),
      chain: directory_chain!(parent),
      siblings: sibling_identities!(parent, Path.basename(path))
    }

    assert Bitwise.band(record.identity.mode, 0o7777) == 0o700
    Process.put(key, Map.update!(Process.get(key), :paths, &[record | &1]))
  end

  defp cleanup_initial_paths!(initial, native_finished? \\ false) do
    for record <- initial.paths do
      if native_finished? and record.path == Path.join(initial.native_root, "task17") and
           File.lstat(record.path) == {:error, :enoent} do
        # Only the frozen native owner could remove its own parent here. This
        # is delegated native cleanup, not an A terminal/native-lease receipt.
        assert File.lstat(Path.dirname(record.path)) == {:error, :enoent}

        assert directory_chain!(Path.dirname(Path.dirname(record.path))) ==
                 Enum.drop(record.chain, -1)
      else
        assert directory_chain!(Path.dirname(record.path)) == record.chain
        assert directory_identity!(record.path) == record.identity
        parent = Path.dirname(record.path)
        name = Path.basename(record.path)
        siblings = sibling_identities!(parent, name)
        assert Map.take(siblings, Map.keys(record.siblings)) == record.siblings
        # No broad root removal: these are only the exact registered allocated
        # children, newest first (qualified external child, then native fallback).
        assert {:ok, _} = File.rm_rf(record.path)
        assert File.lstat(record.path) == {:error, :enoent}
        assert directory_chain!(parent) == record.chain
        assert sibling_identities!(parent, name) == siblings
      end
    end

    :ok
  end

  defp directory_identity!(path) do
    assert is_binary(path) and Path.type(path) == :absolute and Path.expand(path) == path
    refute String.contains?(path, <<0>>)
    assert {:ok, %{type: :directory} = stat} = File.lstat(path)
    Map.take(stat, @identity_keys)
  end

  defp directory_chain!("/"), do: [{"/", directory_identity!("/")}]

  defp directory_chain!(path),
    do: directory_chain!(Path.dirname(path)) ++ [{path, directory_identity!(path)}]

  defp sibling_identities!(parent, own_name) do
    Map.new(File.ls!(parent) -- [own_name], fn name ->
      assert {:ok, stat} = File.lstat(Path.join(parent, name))
      {name, Map.take(stat, @identity_keys)}
    end)
  end

  defp restore_settings!(settings) do
    for {{app, key}, prior} <- settings do
      case prior do
        {:ok, value} -> Application.put_env(app, key, value)
        :error -> Application.delete_env(app, key)
      end

      exact? = Application.fetch_env(app, key) == prior
      assert exact?, "fixture setting was not restored exactly"
    end

    :ok
  end

  defp assert_environments!(environments) do
    exact? = Map.new(@fixture_apps, &{&1, Map.new(Application.get_all_env(&1))}) == environments
    assert exact?, "fixture application environments were not restored exactly"
    :ok
  end

  defp require_completion!(token, caller, owner, binding, environments) do
    receipt =
      receive do
        {:task17_fixture_completed, ^token, ^owner, receipt} -> receipt
      after
        5_000 -> flunk("fixture owner completion receipt is missing")
      end

    if binding, do: Observer.assert_completion_receipt!(binding, receipt)
    assert receipt.token == token and receipt.owner == owner and receipt.caller == caller
    assert receipt.begin == :ok and receipt.environments == :ok and receipt.control_down == :ok
    assert receipt.copy == :ok
    assert_environments!(environments)
    if receipt.control, do: refute(Process.alive?(receipt.control))
    for path <- receipt.paths, do: assert(File.lstat(path) == {:error, :enoent})

    if collector = receipt.collector do
      assert collector.binding.token == token and collector.binding.owner == owner
      assert collector.binding.caller == caller and collector.binding.control == receipt.control
      assert collector.terminal == :ok and collector.restoration == :ok
      assert collector.issued == collector.down
      assert receipt.stopped.tracker == collector.binding.collector
      refute Process.alive?(collector.binding.collector)

      for {target, original} <- collector.originals do
        assert :erlang.trace_info(target, :match_spec) == original.match_spec
        assert :erlang.trace_info(target, :traced) == original.traced
      end
    end

    :ok
  end

  defp fixed_outcome(callback) do
    try do
      callback.()
      :ok
    catch
      kind, _reason -> {:error, kind}
    end
  end

  def publish_sources!(fixture) do
    permission_scope(fixture, %{purpose: :import}, fn ->
      sources =
        Map.new([:pdf, :plain, :markdown, :empty], fn key ->
          input = Map.fetch!(fixture.inputs, key)

          asset =
            NativeAssetFixture.upload!(
              fixture,
              input.media_type,
              chunks(input.bytes),
              "#{key}.dat"
            )

          NativeAssetFixture.verify_and_finalize!()
          if key == :pdf, do: dispatch_and_drain!(:asset_metadata, 1)
          source = %{asset: asset, input: key}

          source =
            if key == :empty do
              source
            else
              assert {:ok, document} =
                       Api.import_document(fixture.session, %{
                         asset_id: asset.asset_id,
                         title: "Duplicate ../标题",
                         mutation_id: Ecto.UUID.generate()
                       })

              assert document.source.digest == :crypto.hash(:sha256, input.bytes)
              assert document.source.byte_size == input.byte_size
              dispatch_and_drain!(:document_extract, 1)
              assert {:ok, ready} = Api.get_document(fixture.session, document.resource_id)
              assert ready.state == :ready

              assert {:ok, fragments} =
                       Api.document_fragments(fixture.session, document.resource_id)

              assert Enum.map(fragments, & &1.text) == input.fragments

              assert Enum.map(fragments, & &1.ordinal) ==
                       Enum.to_list(0..(length(input.fragments) - 1))

              for fragment <- fragments do
                assert fragment.resource_id == ready.resource_id
                assert fragment.resource_version_id == ready.resource_version_id
                assert fragment.digest == :crypto.hash(:sha256, fragment.text)
              end

              Map.merge(source, %{document: ready, fragments: fragments})
            end

          {key, source}
        end)

      fixture |> Map.put(:sources, sources) |> snapshot_roots()
    end)
  end

  def build_graph!(
        %{sources: %{pdf: pdf, plain: plain, markdown: markdown, empty: empty}} = fixture
      ) do
    permission_scope(fixture, %{purpose: :graph}, fn ->
      second_pending = pending_head!(pdf.document, 1)
      request_extraction!(fixture, second_pending)
      dispatch_and_drain!(:document_extract, 1)
      assert {:ok, second_pdf} = Api.get_document(fixture.session, pdf.document.resource_id)
      assert second_pdf.resource_version_id == second_pending.resource_version_id
      assert second_pdf.state == :ready
      assert second_pdf.source == pdf.document.source

      assert {:ok, second_fragments} =
               Api.document_fragments(fixture.session, second_pdf.resource_id)

      assert Enum.map(second_fragments, & &1.text) == fixture.inputs.pdf.fragments

      assert Enum.map(second_fragments, & &1.fragment_id) !=
               Enum.map(pdf.fragments, & &1.fragment_id)

      [first_fragment | _] = markdown.fragments

      attachments = [
        attachment(pdf.document, :document),
        attachment(second_pdf, :document),
        attachment(plain.document, :document),
        asset_attachment!(pdf.asset.asset_id),
        asset_attachment!(markdown.asset.asset_id),
        asset_attachment!(empty.asset.asset_id)
      ]

      citations = [
        %{
          citation_id: Ecto.UUID.generate(),
          source_resource_id: markdown.document.resource_id,
          source_resource_version_id: markdown.document.resource_version_id,
          fragment_id: first_fragment.fragment_id,
          locator: first_fragment.locator
        }
      ]

      note =
        create_note!(
          fixture,
          "Duplicate ../标题",
          "# Portable 笔记\n\n[ordinary URL](https://example.test/knowledge)",
          attachments,
          citations
        )

      ancestor = create_note!(fixture, "History", "UNSELECTED_ANCESTOR_BODY")
      current = save_note!(fixture, ancestor, "Current history body")

      assert {:ok, conflict} =
               Api.save_note(fixture.session, ancestor.resource_id, %{
                 mutation_id: Ecto.UUID.generate(),
                 base_version_id: ancestor.resource_version_id,
                 title: ancestor.title,
                 markdown: "UNSELECTED_CONFLICT_BODY"
               })

      assert conflict.outcome == :conflict

      assert {:ok, merged} =
               Api.merge_note(fixture.session, ancestor.resource_id, %{
                 mutation_id: Ecto.UUID.generate(),
                 conflict_id: conflict.conflict_id,
                 expected_current_version_id: current.resource_version_id,
                 competing_version_id: conflict.submitted_version_id,
                 title: ancestor.title,
                 markdown: "Merged current body"
               })

      assert merged.outcome == :saved
      tombstone = create_note!(fixture, "Deleted title", "DELETED_NOTE_BODY")

      assert {:ok, _} =
               Api.delete_note(fixture.session, tombstone.resource_id, %{
                 mutation_id: Ecto.UUID.generate(),
                 expected_current_version_id: tombstone.resource_version_id
               })

      # A separate deleted source is positively resolved through a live Note.
      deleted = create_note!(fixture, "Deleted source", "DELETED_SOURCE_BODY")
      reference = attachment(deleted, :note)

      retained =
        create_note!(fixture, "Retained deleted source", "Deleted historical source metadata", [
          reference
        ])

      assert {:ok, relationship} =
               Api.relate_resource(fixture.session, note.resource_id, %{
                 target_resource_id: deleted.resource_id,
                 target_resource_version_id: deleted.resource_version_id,
                 type: :related_to
               })

      assert {:ok, _} =
               Api.delete_note(fixture.session, deleted.resource_id, %{
                 mutation_id: Ecto.UUID.generate(),
                 expected_current_version_id: deleted.resource_version_id
               })

      assert {:ok, resolved} =
               Api.resolve_note_attachment(
                 fixture.session,
                 retained.resource_id,
                 retained.resource_version_id,
                 reference.attachment_id
               )

      assert resolved.source.resource_id == deleted.resource_id
      assert resolved.source.deleted? == true

      assert {:ok, tag} = Api.attach_tag(fixture.session, note.resource_id, %{name: @label})

      # Only these cycles/later heads require owner SQL. Source publication and
      # extraction above remain public and genuine. No ready Document is forged.
      cycles = cycle_notes!(fixture)
      historical_heads = [pending_head!(second_pdf, 2)]

      # Actual Asset deletion leaves the imported Document's retained source.
      assert {:ok, descriptor} = Api.asset_summary(fixture.session, plain.asset.asset_id)

      assert {:ok, _} =
               Api.delete_asset(fixture.session, plain.asset.asset_id, descriptor.state_revision)

      dispatch_and_drain!(:asset_cleanup, 1)

      assert {:ok, retained_document} =
               Api.get_document(fixture.session, plain.document.resource_id)

      assert retained_document.source.object_id == plain.document.source.object_id

      notes = [note, merged.canonical, retained] ++ cycles

      asset_sources =
        Map.new([pdf, markdown, empty], fn source ->
          reference = asset_attachment!(source.asset.asset_id)

          {reference.target_resource_id,
           %{version_id: reference.target_resource_version_id, input: source.input}}
        end)

      included_versions =
        MapSet.new(
          Enum.map(notes, & &1.resource_version_id) ++
            Enum.map(
              [pdf.document, second_pdf, plain.document, markdown.document],
              & &1.resource_version_id
            ) ++
            Enum.map(historical_heads, & &1.resource_version_id) ++
            Enum.map(asset_sources, fn {_, source} -> source.version_id end)
        )

      metadata_versions =
        MapSet.new([
          ancestor.resource_version_id,
          current.resource_version_id,
          conflict.submitted_version_id,
          deleted.resource_version_id
        ])

      expected = %{
        notes: Map.new(notes, &{&1.resource_version_id, &1.markdown}),
        original_inputs:
          Map.new([pdf, plain, markdown], &{&1.document.resource_version_id, &1.input})
          |> Map.put(second_pdf.resource_version_id, :pdf)
          |> Map.put(hd(historical_heads).resource_version_id, :pdf),
        asset_inputs:
          Map.new([pdf, markdown, empty], fn source ->
            {asset_version!(source.asset.asset_id), source.input}
          end),
        historical_pins:
          Enum.map([pdf.document, second_pdf], &{&1.resource_id, &1.resource_version_id}),
        deleted_sources: [{deleted.resource_id, deleted.resource_version_id}],
        tombstones: [tombstone.resource_id, deleted.resource_id],
        absent_bodies: [
          "UNSELECTED_ANCESTOR_BODY",
          "Current history body",
          "UNSELECTED_CONFLICT_BODY",
          "DELETED_NOTE_BODY",
          "DELETED_SOURCE_BODY"
        ],
        tags: [tag.tag_id],
        relationships: [relationship.relationship_id],
        included_versions: included_versions,
        metadata_versions: metadata_versions,
        resource_ids:
          MapSet.new(
            Enum.map(notes, & &1.resource_id) ++
              Enum.map(
                [pdf.document, plain.document, markdown.document, deleted],
                & &1.resource_id
              ) ++
              Map.keys(asset_sources)
          ),
        fragments:
          Map.new([pdf, plain, markdown] ++ [%{document: second_pdf, input: :pdf}], fn source ->
            {source.document.resource_version_id,
             Map.fetch!(fixture.inputs, source.input).fragments}
          end),
        memberships:
          Map.new(notes, fn value ->
            {value.resource_version_id,
             %{
               attachments: Map.get(value, :attachments, []),
               citations: Map.get(value, :citations, [])
             }}
          end)
      }

      graph = %{
        note: note,
        ancestor: ancestor,
        current: merged.canonical,
        conflict: conflict,
        tombstone: tombstone,
        deleted_source: deleted,
        retained: retained,
        cycles: cycles,
        historical_heads: historical_heads,
        second_pdf: second_pdf,
        second_fragments: second_fragments,
        asset_sources: asset_sources,
        tag: tag,
        relationship: relationship,
        expected: expected
      }

      fixture |> Map.put(:graph, graph) |> snapshot_roots()
    end)
  end

  def export_config(fixture, controls) when is_map(controls) do
    allowed = [:barriers, :clock, :write, :on_event, :summarize_capture]
    assert Enum.all?(Map.keys(controls), &(&1 in allowed))

    observer =
      Map.merge(fixture.observer, Map.take(controls, [:barriers, :on_event, :summarize_capture]))

    assert {:ok, authorization} =
             AuthorizationDependencies.new(%{
               store: IdentityRepository,
               custodian: KeyCustodian
             })

    task_supervisor = fixture.supervisor
    lease_tracker = fixture.lease_tracker
    clock_source = Map.get(controls, :clock, fn -> System.monotonic_time(:millisecond) end)

    clock = fn ->
      caller = self()

      if caller in Task.Supervisor.children(task_supervisor) and
           not Process.get({__MODULE__, observer.token, :clock_seen}, false) do
        Process.put({__MODULE__, observer.token, :clock_seen}, true)
        Observer.event(observer, :task_first_clock, %{task: caller})
      end

      clock_source.()
    end

    runtime = %{
      request_repo: RequestRepo,
      scoped_repo: {ObservedScoped, observer},
      operation_scope: OperationScope,
      authorizer: Authorize,
      authorization: authorization,
      authorization_lock: AuthorizationLock,
      vault_lock: VaultLock,
      object_lock: ObjectLock,
      audit: AuditSink,
      assets: AssetRepository,
      identity: IdentityRepository,
      vaults: IdentityRepository,
      custodian: {ObservedCustodian, observer},
      authenticated_reader: {ObservedReader, observer},
      knowledge_export: %{
        root: fixture.roots.artifact,
        storage_root: fixture.roots.storage,
        backup_root: fixture.roots.backup,
        task_supervisor: task_supervisor,
        clock: clock
      }
    }

    runtime =
      if write = controls[:write],
        do: Map.put(runtime, :knowledge_export_write, write),
        else: runtime

    %{
      export_knowledge: fn session, options ->
        assert Agent.get(observer.control, & &1.lifecycle.phase) == :active
        :ok = IssuedLeases.enable(lease_tracker)
        result = Export.run(runtime, session, options)

        if match?({:ok, _}, result) do
          {:ok, handle} = result
          Observer.register_handle(observer, handle)
        end

        result
      end,
      knowledge_export_entries: fn session, handle, cursor ->
        result = Export.entries(runtime, session, handle, cursor)

        case result do
          {:ok, page} -> Observer.event(observer, :public_page, %{count: length(page.entries)})
          _ -> :ok
        end

        result
      end,
      read_knowledge_export_chunk: fn session, handle, path, ordinal ->
        result = Export.read_chunk(runtime, session, handle, path, ordinal)

        case result do
          {:ok, bytes} ->
            Observer.event(observer, :public_chunk, %{
              byte_size: byte_size(bytes),
              ordinal: ordinal
            })

          _ ->
            :ok
        end

        result
      end,
      close_knowledge_export: &Export.close(runtime, &1, &2)
    }
  end

  def materialize!(fixture, config, handle) do
    root = Path.join(fixture.roots.offline, Ecto.UUID.generate())
    private_directory!(root)

    try do
      entries = materialize_pages!(fixture, config, handle, nil, MapSet.new(), %{}, root)
      %{root: root, entries: entries}
    after
      assert :ok = Api.close_knowledge_export(config, fixture.session, handle)
    end
  end

  def assert_quiescent!(fixture) do
    if stopped?(fixture, :private, fixture.supervisor) do
      refute Process.alive?(fixture.supervisor)
    else
      assert Task.Supervisor.children(fixture.supervisor) == []
    end

    sync_leases!(fixture)
    Observer.assert_issued_terminal!(fixture)
    assert_owned_repo!(fixture)
    assert permission_snapshot(fixture) == fixture.permission_baseline
    assert_denied_write_guard!(fixture.permission_baseline)

    assert File.ls!(fixture.roots.artifact) |> Enum.sort() == [
             "foreign-neighbor",
             "malformed-neighbor"
           ]

    assert File.read!(Path.join(fixture.roots.artifact, "foreign-neighbor")) ==
             "foreign unchanged"

    assert File.read!(Path.join([fixture.roots.artifact, "malformed-neighbor", "sentinel"])) ==
             "malformed unchanged"

    if snapshots = fixture[:root_snapshots] do
      assert inventory(fixture.roots.storage) == snapshots.storage
      assert inventory(fixture.roots.backup) == snapshots.backup
    end

    :ok
  end

  defp independent_inputs do
    pdf =
      File.read!(
        Path.expand("../../../singularity_ingest/test/fixtures/documents/two_pages.pdf", __DIR__)
      )

    Map.new(
      [
        {:pdf, pdf, "application/pdf", ["First page", "Second page"]},
        {:plain, @plain, "text/plain", ["第一段 café", "Second paragraph 🌍"]},
        {:markdown, @markdown, "text/markdown",
         ["# 标题", "Unicode café 🌍", "[ordinary URL](https://example.test/knowledge)"]},
        {:empty, <<>>, "text/plain", []}
      ],
      fn {key, bytes, media_type, fragments} ->
        {key,
         %{
           bytes: bytes,
           sha256: sha(bytes),
           byte_size: byte_size(bytes),
           media_type: media_type,
           fragments: fragments
         }}
      end
    )
  end

  defp chunks(<<>>), do: []
  defp chunks(bytes) when byte_size(bytes) <= @chunk, do: [bytes]
  defp chunks(<<head::binary-size(@chunk), tail::binary>>), do: [head | chunks(tail)]

  defp dispatch_and_drain!(queue, expected) do
    assert {:ok, %{failed: 0}} = OutboxDispatcher.dispatch_once(%{})
    assert %{failure: 0, success: ^expected} = Oban.drain_queue(Singularity.Oban, queue: queue)
  end

  defp create_note!(fixture, title, markdown, attachments \\ [], citations \\ []) do
    assert {:ok, result} =
             Api.create_note(fixture.session, %{
               mutation_id: Ecto.UUID.generate(),
               title: title,
               markdown: markdown,
               attachments: attachments,
               citations: citations
             })

    result
  end

  defp save_note!(fixture, note, markdown) do
    assert {:ok, result} =
             Api.save_note(fixture.session, note.resource_id, %{
               mutation_id: Ecto.UUID.generate(),
               base_version_id: note.resource_version_id,
               title: note.title,
               markdown: markdown
             })

    assert result.outcome == :saved
    result.canonical
  end

  defp attachment(target, kind),
    do: %{
      attachment_id: Ecto.UUID.generate(),
      target_resource_id: target.resource_id,
      target_resource_version_id: target.resource_version_id,
      target_kind: kind,
      role: :source,
      label: @label
    }

  defp asset_attachment!(asset) do
    %{rows: [[resource, version]]} =
      owner_sql!(
        "SELECT version.resource_id,asset.resource_version_id FROM content.assets asset JOIN content.resource_versions version ON version.id=asset.resource_version_id AND version.vault_id=asset.vault_id WHERE asset.id=$1",
        [dump(asset)]
      )

    attachment(%{resource_id: text(resource), resource_version_id: text(version)}, :asset)
  end

  defp asset_version!(asset) do
    %{rows: [[version]]} =
      owner_sql!("SELECT resource_version_id FROM content.assets WHERE id=$1", [dump(asset)])

    text(version)
  end

  defp pending_head!(document, revision) do
    version = Ecto.UUID.generate()

    owner_transaction!(fn ->
      query!(
        "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',$4)",
        [dump(version), dump(document.resource_id), dump(document.owner_scope_id), revision]
      )

      query!(
        """
        INSERT INTO content.document_versions(resource_version_id,resource_id,vault_id,classification,
          source_asset_id,source_resource_id,source_resource_version_id,source_object_id,source_digest,
          source_byte_size,media_type,title,created_by_principal_id,inserted_at)
        SELECT $1,resource_id,vault_id,classification,source_asset_id,source_resource_id,
          source_resource_version_id,source_object_id,source_digest,source_byte_size,media_type,
          'Later pending head',created_by_principal_id,clock_timestamp()
        FROM content.document_versions WHERE resource_version_id=$2
        """,
        [dump(version), dump(document.resource_version_id)]
      )

      query!(
        "UPDATE content.resources SET current_version_id=$2,title='Later pending head' WHERE id=$1",
        [dump(document.resource_id), dump(version)]
      )
    end)

    %{resource_id: document.resource_id, resource_version_id: version, state: :pending}
  end

  defp request_extraction!(fixture, document) do
    # The worker requires this ordinary persisted outbox/job bridge. Merely
    # inserting a pending graph version cannot manufacture a ready completion.
    owner_transaction!(fn ->
      alias Singularity.Storage.Schema.Core.OutboxEvent
      now = DateTime.utc_now(:microsecond)

      event =
        OutboxEvent.create_changeset(%OutboxEvent{}, %{
          id: Ecto.UUID.generate(),
          event_type: "document.extraction_requested",
          idempotency_key: "document-extraction:#{document.resource_version_id}",
          vault_id: fixture.session.vault_id,
          principal_id: fixture.session.principal_id,
          required_capability: "asset.read",
          classification: :private,
          principal_authorization_epoch: fixture.session.principal_authorization_epoch,
          vault_authorization_epoch: fixture.session.vault_authorization_epoch,
          correlation_id: Ecto.UUID.generate(),
          causation_id: Ecto.UUID.generate(),
          expected_entity_revision: 0,
          envelope_version: 1,
          payload: %{
            "resource_id" => document.resource_id,
            "resource_version_id" => document.resource_version_id
          },
          occurred_at: now
        })

      assert {:ok, _} = MigrationRepo.insert(event, log: false)
    end)
  end

  defp cycle_notes!(fixture) do
    notes =
      for suffix <- ["A", "B"],
          do: %{
            resource_id: Ecto.UUID.generate(),
            resource_version_id: Ecto.UUID.generate(),
            title: "Cycle " <> suffix,
            markdown: "Cycle " <> suffix <> " body"
          }

    [first, second] = notes

    notes = [
      Map.put(first, :attachments, [attachment(second, :note)]),
      Map.put(second, :attachments, [attachment(first, :note)])
    ]

    owner_transaction!(fn ->
      for note <- notes do
        query!(
          "INSERT INTO content.resources(id,vault_id,classification,kind,current_version_id,title) VALUES($1,$2,'private','note',$3,$4)",
          [
            dump(note.resource_id),
            dump(fixture.session.vault_id),
            dump(note.resource_version_id),
            note.title
          ]
        )

        query!(
          "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',0)",
          [dump(note.resource_version_id), dump(note.resource_id), dump(fixture.session.vault_id)]
        )

        query!(
          "INSERT INTO content.note_versions(resource_version_id,resource_id,vault_id,classification,title,markdown,created_by_principal_id) VALUES($1,$2,$3,'private',$4,$5,$6)",
          [
            dump(note.resource_version_id),
            dump(note.resource_id),
            dump(fixture.session.vault_id),
            note.title,
            note.markdown,
            dump(fixture.session.principal_id)
          ]
        )
      end

      for note <- notes do
        [reference] = note.attachments

        query!(
          "INSERT INTO content.note_attachments(note_resource_version_id,id,note_resource_id,vault_id,classification,target_resource_id,target_resource_version_id,target_kind,ordinal,role,label,inserted_at) VALUES($1,$2,$3,$4,'private',$5,$6,'note',0,'source',$7,clock_timestamp())",
          [
            dump(note.resource_version_id),
            dump(reference.attachment_id),
            dump(note.resource_id),
            dump(fixture.session.vault_id),
            dump(reference.target_resource_id),
            dump(reference.target_resource_version_id),
            @label
          ]
        )
      end

      for note <- notes,
          do:
            query!("SELECT content.finalize_note_source_set($1)", [dump(note.resource_version_id)])
    end)

    notes
  end

  # The permission inventory is deliberately private and fixed. In particular,
  # Document/fragment UPDATE/DELETE and reset/recovery EXECUTE are absent.
  defp permissions do
    imports =
      for table <- ~w(document_versions document_import_receipts),
          privilege <- ~w(SELECT INSERT),
          do: {"TABLE", "content." <> table, "singularity_web", privilege}

    graph =
      for table <- ~w(note_attachments note_citations tags resource_tags relationships),
          privilege <- ~w(SELECT INSERT),
          do: {"TABLE", "content." <> table, "singularity_web", privilege}

    reads =
      for role <- ~w(singularity_web),
          do: {"TABLE", "content.document_fragments", role, "SELECT"}

    # The genuine worker calls its permanently granted SECURITY DEFINER bridge;
    # it does not require caller EXECUTE on the lower-level lifecycle functions.
    imports ++
      graph ++
      reads ++
      [
        {"TABLE", "content.document_import_receipts", "singularity_web", "UPDATE"},
        {"FUNCTION", "content.document_trim_name(text)", "singularity_web", "EXECUTE"}
      ]
  end

  defp permission_scope(fixture, controls, callback) do
    assert Enum.all?(Map.keys(controls), &(&1 in [:purpose, :after_grant]))
    purpose = Map.get(controls, :purpose, :import)
    assert purpose in [:import, :graph]
    required = purpose_permissions(purpose)
    assert_owned_repo!(fixture)
    before = permission_snapshot(fixture)
    # GRANT/REVOKE cannot reproduce a NULL ACL without a forbidden catalog
    # rewrite. Existing canonical objects have explicit ACLs: fail closed if
    # that prerequisite ever changes, before registering or applying a delta.
    for {kind, object, _, _} = permission <- required,
        not Map.fetch!(before.effective, permission) do
      assert is_binary(Map.fetch!(before.acls, {kind, object}))
    end

    scope = make_ref()

    Agent.update(fixture.observer.control, fn state ->
      entry = %{reference: scope, before: before, owned: []}
      update_in(state, [:lifecycle, :permission_scopes], &[entry | &1])
    end)

    try do
      for permission <- required, not Map.fetch!(before.effective, permission) do
        {kind, object, role, privilege} = permission
        # Register before this delta; even a partial setup exception unwinds it.
        assert Agent.get(
                 fixture.observer.control,
                 &hd(&1.lifecycle.permission_scopes).reference
               ) == scope

        count =
          Agent.get_and_update(fixture.observer.control, fn state ->
            [entry | rest] = state.lifecycle.permission_scopes
            entry = %{entry | owned: [permission | entry.owned]}
            {length(entry.owned), put_in(state, [:lifecycle, :permission_scopes], [entry | rest])}
          end)

        owner_sql!("GRANT #{privilege} ON #{kind} #{object} TO #{role}")
        if after_grant = controls[:after_grant], do: after_grant.(count)
      end

      callback.()
    after
      restore_permission_scope!(fixture, scope)
    end
  end

  defp restore_permission_scope!(fixture, reference) do
    [entry | rest] = Agent.get(fixture.observer.control, & &1.lifecycle.permission_scopes)
    assert entry.reference == reference
    assert_owned_repo!(fixture)

    for {kind, object, role, privilege} <- entry.owned do
      owner_sql!("REVOKE #{privilege} ON #{kind} #{object} FROM #{role}")
    end

    assert_owned_repo!(fixture)
    assert permission_snapshot(fixture) == entry.before
    assert_denied_write_guard!(entry.before)

    [current | current_rest] =
      Agent.get(fixture.observer.control, & &1.lifecycle.permission_scopes)

    assert current.reference == reference and current_rest == rest

    Agent.update(
      fixture.observer.control,
      &put_in(&1, [:lifecycle, :permission_scopes], rest)
    )

    :ok
  end

  defp restore_permission_scopes!(fixture) do
    case Agent.get(fixture.observer.control, & &1.lifecycle.permission_scopes) do
      [] ->
        :ok

      [entry | _] ->
        restore_permission_scope!(fixture, entry.reference)
        restore_permission_scopes!(fixture)
    end
  end

  defp purpose_permissions(:import) do
    Enum.filter(permissions(), fn {_, object, _, _} ->
      object in [
        "content.document_versions",
        "content.document_import_receipts",
        "content.document_fragments",
        "content.document_trim_name(text)"
      ]
    end)
  end

  defp purpose_permissions(:graph) do
    Enum.filter(permissions(), fn
      {"TABLE", object, _, privilege}
      when object in ["content.document_versions", "content.document_fragments"] ->
        privilege == "SELECT"

      {"TABLE", object, _, _} ->
        object in [
          "content.note_attachments",
          "content.note_citations",
          "content.tags",
          "content.resource_tags",
          "content.relationships"
        ]

      _ ->
        false
    end)
  end

  defp permission_snapshot(fixture) do
    assert_owned_repo!(fixture)

    owner_transaction!(fn ->
      effective =
        Map.new(permissions(), fn {kind, object, role, privilege} = permission ->
          function = if kind == "TABLE", do: "has_table_privilege", else: "has_function_privilege"

          %{rows: [[allowed]]} =
            query!("SELECT pg_catalog.#{function}($1,$2,$3)", [role, object, privilege])

          {permission, allowed}
        end)

      acls =
        permissions()
        |> Enum.map(fn {kind, object, _, _} -> {kind, object} end)
        |> Enum.uniq()
        |> Map.new(fn {kind, object} = key ->
          sql =
            if kind == "TABLE",
              do: "SELECT relacl::text FROM pg_catalog.pg_class WHERE oid=$1::text::regclass",
              else: "SELECT proacl::text FROM pg_catalog.pg_proc WHERE oid=$1::text::regprocedure"

          %{rows: [[acl]]} = query!(sql, [object])
          {key, acl}
        end)

      roles =
        query!(
          "SELECT (to_jsonb(r)-'rolpassword')::text FROM pg_catalog.pg_roles r WHERE rolname IN ('singularity_web','singularity_worker') ORDER BY rolname"
        ).rows

      memberships =
        query!(
          "SELECT to_jsonb(m)::text FROM pg_catalog.pg_auth_members m ORDER BY roleid,member,grantor"
        ).rows

      guard =
        for role <- ~w(singularity_web singularity_worker),
            table <- ~w(document_versions document_fragments),
            privilege <- ~w(UPDATE DELETE),
            into: %{} do
          %{rows: [[allowed]]} =
            query!("SELECT has_table_privilege($1,$2,$3)", [role, "content." <> table, privilege])

          {{role, table, privilege}, allowed}
        end

      %{
        effective: effective,
        acls: acls,
        roles: roles,
        memberships: memberships,
        guard: guard,
        migration_repo: Process.whereis(MigrationRepo),
        database: fixture.destination.database
      }
    end)
  end

  defp assert_denied_write_guard!(snapshot) do
    assert Enum.all?(snapshot.guard, fn {_, allowed} -> allowed == false end)
    :ok
  end

  defp assert_owned_repo!(fixture) do
    {pid, database} = Map.fetch!(fixture.repositories, MigrationRepo)
    assert Process.whereis(MigrationRepo) == pid
    assert Process.alive?(fixture.owner)
    assert database == fixture.destination.database
    assert database =~ ~r/\Asingularity_test_[0-9a-f]{24}\z/
    assert %{rows: [[^database]]} = SafeSQL.query!(MigrationRepo, "SELECT current_database()", [])
    :ok
  end

  defp materialize_pages!(fixture, config, handle, cursor, cursors, entries, root) do
    assert {:ok, %{entries: page, next_cursor: next}} =
             Api.knowledge_export_entries(config, fixture.session, handle, cursor)

    assert length(page) <= 500

    entries =
      Enum.reduce(page, entries, fn descriptor, acc ->
        assert Enum.sort(Map.keys(descriptor)) == ["byte_size", "media_type", "path", "sha256"]
        assert is_integer(descriptor["byte_size"]) and descriptor["byte_size"] >= 0
        path = descriptor["path"]
        safe_path!(path)
        refute Map.has_key?(acc, path)
        destination = Path.join(root, path)
        safe_parents!(root, Path.split(path) |> Enum.drop(-1))
        assert {:ok, file} = File.open(destination, [:write, :binary, :exclusive])
        File.chmod!(destination, 0o600)

        try do
          size = descriptor["byte_size"]
          count = max(1, div(size + @chunk - 1, @chunk))

          copied =
            Enum.reduce(0..(count - 1), 0, fn ordinal, written ->
              assert {:ok, bytes} =
                       Api.read_knowledge_export_chunk(
                         config,
                         fixture.session,
                         handle,
                         path,
                         ordinal
                       )

              expected = min(@chunk, max(0, size - ordinal * @chunk))
              assert byte_size(bytes) == expected
              assert :ok = IO.binwrite(file, bytes)
              written + byte_size(bytes)
            end)

          assert copied == size
        after
          assert :ok = File.close(file)
        end

        Map.put(acc, path, descriptor)
      end)

    if is_nil(next) do
      entries
    else
      refute MapSet.member?(cursors, next)
      assert page != []
      materialize_pages!(fixture, config, handle, next, MapSet.put(cursors, next), entries, root)
    end
  end

  defp safe_path!(path) do
    assert is_binary(path) and path != "" and Path.type(path) == :relative
    refute String.contains?(path, ["\\", <<0>>])
    assert Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
    :ok
  end

  defp safe_parents!(_root, []), do: :ok

  defp safe_parents!(root, [part | rest]) do
    next = Path.join(root, part)

    case File.lstat(next) do
      {:error, :enoent} -> private_directory!(next)
      {:ok, %{type: :directory}} -> :ok
      _ -> flunk("offline materialization parent is not a real directory")
    end

    safe_parents!(next, rest)
  end

  defp private_directory!(root) do
    assert :ok = File.mkdir(root)
    assert :ok = File.chmod(root, 0o700)
    assert {:ok, %{type: :directory, mode: mode}} = File.lstat(root)
    assert Bitwise.band(mode, 0o777) == 0o700
    root
  end

  defp assert_private_disjoint_roots!(fixture) do
    roots = fixture.roots |> Map.take([:artifact, :offline, :storage, :backup]) |> Map.values()

    for root <- roots do
      assert Path.expand(root) == root
      assert {:ok, %{type: :directory, mode: mode}} = File.lstat(root)
      assert Bitwise.band(mode, 0o7777) == 0o700

      for other <- roots, other != root do
        refute String.starts_with?(root <> "/", other <> "/")
      end
    end

    assert length(Enum.uniq(roots)) == 4
    :ok
  end

  defp write_sentinels!(fixture) do
    File.write!(Path.join(fixture.roots.artifact, "foreign-neighbor"), "foreign unchanged", [
      :exclusive
    ])

    malformed = Path.join(fixture.roots.artifact, "malformed-neighbor")
    private_directory!(malformed)
    File.write!(Path.join(malformed, "sentinel"), "malformed unchanged", [:exclusive])

    File.write!(Path.join(fixture.roots.backup, "task17-sentinel"), "backup unchanged", [
      :exclusive
    ])
  end

  defp snapshot_roots(fixture) do
    snapshots = %{
      storage: inventory(fixture.roots.storage),
      backup: inventory(fixture.roots.backup)
    }

    Agent.update(fixture.observer.control, &put_in(&1, [:lifecycle, :root_snapshots], snapshots))
    Map.put(fixture, :root_snapshots, snapshots)
  end

  defp inventory(root), do: inventory(root, "", %{})

  defp inventory(root, relative, acc) do
    Enum.reduce(File.ls!(Path.join(root, relative)), acc, fn name, result ->
      path = Path.join(relative, name)

      case File.lstat!(Path.join(root, path)) do
        %{type: :directory} ->
          inventory(root, path, Map.put(result, path, :directory))

        %{type: :regular, size: size} ->
          Map.put(result, path, {size, sha(File.read!(Path.join(root, path)))})

        _ ->
          flunk("fixture storage inventory contains an unsupported entry")
      end
    end)
  end

  defp close_handles!(fixture) do
    for handle <- Observer.handles(fixture), Process.alive?(handle.owner) do
      result = Api.close_knowledge_export(export_config(fixture, %{}), fixture.session, handle)
      assert result == :ok or match?({:error, _}, result)
    end
  end

  defp stop_tasks!(fixture, deadline) do
    retire_admissions!(fixture, deadline)
  end

  defp retire_admissions!(fixture, deadline) do
    for {kind, pid, id} <- [
          {:private, fixture.supervisor, {Task.Supervisor, fixture.observer.token}},
          {:global, fixture.global_supervisor, @global_tasks}
        ],
        is_pid(pid) do
      unless stopped?(fixture, kind, pid) do
        assert Process.alive?(fixture.infrastructure)

        assert Enum.count(Supervisor.which_children(fixture.infrastructure), fn
                 {^id, ^pid, :supervisor, _} -> true
                 _ -> false
               end) == 1

        if kind == :global, do: assert(Process.whereis(@global_tasks) == pid)
        retire_tasks!(fixture, pid, deadline)

        stop_owned!(
          fixture,
          kind,
          pid,
          fn ->
            # The parent knows the exact ID. A permanent global child is
            # terminated through that parent, never stopped/re-resolved by name.
            bounded_stop_call!(
              fn -> Supervisor.terminate_child(fixture.infrastructure, id) end,
              deadline
            )
          end,
          deadline
        )

        refute Enum.any?(Supervisor.which_children(fixture.infrastructure), fn
                 {^id, child, _, _} when is_pid(child) -> true
                 _ -> false
               end)
      end
    end

    :ok
  end

  defp retire_tasks!(fixture, supervisor, deadline) do
    case Task.Supervisor.children(supervisor) do
      [] ->
        :ok

      children ->
        monitored = Enum.map(children, &{&1, Process.monitor(&1)})

        try do
          for {child, monitor} <- monitored do
            assert System.monotonic_time(:millisecond) < deadline

            result =
              bounded_stop_call!(
                fn -> Task.Supervisor.terminate_child(supervisor, child) end,
                deadline
              )

            assert result in [:ok, {:error, :not_found}]
            remaining = max(0, deadline - System.monotonic_time(:millisecond))
            assert_receive {:DOWN, ^monitor, :process, ^child, reason}, remaining
            refute Process.alive?(child)
            refute child in Task.Supervisor.children(supervisor)

            Agent.update(
              fixture.observer.control,
              &put_in(&1, [:lifecycle, :task_down, child], %{
                supervisor: supervisor,
                reason: reason
              })
            )
          end
        after
          for {_child, monitor} <- monitored, do: Process.demonitor(monitor, [:flush])
        end

        # The accepted companion-loss path can create a cleanup replacement.
        # Account for it instead of crediting the first emptying attempt.
        retire_tasks!(fixture, supervisor, deadline)
    end
  end

  defp bounded_stop_call!(callback, deadline) do
    # Public Supervisor APIs have no timeout argument. This linked call worker
    # is not an issuance task; its return is never a resource DOWN receipt.
    caller = self()
    start = make_ref()

    task =
      Task.async(fn ->
        receive do
          {:task17_cleanup_call, ^start, ^caller} -> callback.()
        after
          5_000 -> exit(:cleanup_call_not_started)
        end
      end)

    monitor = Process.monitor(task.pid)
    send(task.pid, {:task17_cleanup_call, start, caller})

    try do
      case Task.yield(task, remaining(deadline)) do
        {:ok, result} -> result
        _ -> flunk("owned cleanup call was not acknowledged")
      end
    after
      # On timeout this synchronously consumes Task's own actual DOWN. Also
      # require the independently armed monitor; failure stays failure.
      Task.shutdown(task, :brutal_kill)

      try do
        pid = task.pid
        assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, remaining(deadline)
        refute reason == :noproc
        refute Process.alive?(pid)
      after
        Process.demonitor(monitor, [:flush])
      end
    end
  end

  defp remaining(nil), do: 5_000

  defp remaining(deadline) do
    max(0, deadline - System.monotonic_time(:millisecond))
  end

  # Only a fresh pre-owner failure can close the live infrastructure before the
  # enclosing native fixture. All shutdown credit is an exact monitored DOWN.
  # The orphan directory is deliberately retained for actual guarded startup.
  defp with_preowner_recovery(fixture, startup_name, callback) do
    assert self() == fixture.observer.parent
    assert is_atom(startup_name) and startup_name not in [nil, false, true]
    assert Process.whereis(startup_name) == nil
    assert is_function(callback, 1)
    assert Observer.handles(fixture) == []
    assert Task.Supervisor.children(fixture.supervisor) == []
    global = Process.whereis(Singularity.Runtime.UploadRecoveryTaskSupervisor)
    assert is_pid(global)
    assert global == fixture.global_supervisor
    assert Task.Supervisor.children(global) == []
    :ok = IssuedLeases.sync(fixture.lease_tracker)
    assert Observer.issued(fixture) == %{}
    refute Enum.any?(Observer.events(fixture), &(&1.point == :before_native_lease))
    assert Agent.get(fixture.observer.control, & &1.lifecycle.stopped) == %{}
    before = permission_snapshot(fixture)
    assert_denied_write_guard!(before)

    roots_before = %{
      storage: inventory(fixture.roots.storage),
      backup: inventory(fixture.roots.backup)
    }

    try do
      deadline = System.monotonic_time(:millisecond) + 5_000
      stop_tasks!(fixture, deadline)
      native_completion_fence!(fixture, deadline)
      finalize_collector!(fixture, deadline)

      Agent.update(fixture.observer.control, fn state ->
        put_in(state, [:lifecycle, :retirement_receipt], %{
          binding: collector_binding(fixture),
          result: :ok,
          fence: state.lifecycle.fence_receipt,
          task_down: state.lifecycle.task_down,
          private: fixture.supervisor,
          global: fixture.global_supervisor
        })
      end)

      stop_owned!(
        fixture,
        :infrastructure,
        fixture.infrastructure,
        fn ->
          Supervisor.stop(fixture.infrastructure, :normal, remaining(deadline))
        end,
        deadline
      )

      assert Process.whereis(Singularity.Runtime.UploadRecoveryTaskSupervisor) == nil
      assert_owned_repo!(fixture)
      assert permission_snapshot(fixture) == before

      starter = fn ->
        assert self() == fixture.observer.parent

        attempted =
          Agent.get_and_update(fixture.observer.control, fn state ->
            {state.lifecycle.startup_attempted?,
             put_in(state, [:lifecycle, :startup_attempted?], true)}
          end)

        refute attempted

        case Singularity.Runtime.Knowledge.ExportArtifact.start_runtime(
               [],
               [strategy: :one_for_one, name: startup_name],
               true
             ) do
          {:ok, pid} = result ->
            Agent.update(
              fixture.observer.control,
              &put_in(&1, [:lifecycle, :startup], %{pid: pid})
            )

            result

          error ->
            error
        end
      end

      callback.(starter)
    after
      try do
        stop_startup!(fixture)
      after
        assert_owned_repo!(fixture)
        assert permission_snapshot(fixture) == before
        assert_denied_write_guard!(before)
        assert inventory(fixture.roots.storage) == roots_before.storage
        assert inventory(fixture.roots.backup) == roots_before.backup

        assert File.read!(Path.join(fixture.roots.artifact, "foreign-neighbor")) ==
                 "foreign unchanged"

        assert File.read!(Path.join([fixture.roots.artifact, "malformed-neighbor", "sentinel"])) ==
                 "malformed unchanged"
      end
    end
  end

  defp stop_startup!(fixture, deadline \\ nil) do
    case Agent.get(fixture.observer.control, & &1.lifecycle.startup) do
      nil ->
        refute Agent.get(fixture.observer.control, & &1.lifecycle.startup_attempted?)
        :ok

      %{pid: pid} ->
        stop_owned!(
          fixture,
          :startup,
          pid,
          fn ->
            Supervisor.stop(pid, :normal, remaining(deadline))
          end,
          deadline
        )
    end
  end

  defp sync_leases!(fixture) do
    if stopped?(fixture, :tracker, fixture.lease_tracker) do
      assert Observer.issued(fixture) == %{}
      :ok
    else
      IssuedLeases.sync(fixture.lease_tracker)
    end
  end

  defp stopped?(fixture, kind, pid) do
    {stopped, receipt} =
      Agent.get(fixture.observer.control, fn state ->
        {Map.get(state.lifecycle.stopped, kind), Map.get(state.lifecycle.stop_receipts, kind)}
      end)

    if stopped == pid do
      assert is_map(receipt) and receipt.pid == pid
      true
    else
      false
    end
  end

  defp stop_owned!(fixture, kind, pid, stop, deadline) do
    if stopped?(fixture, kind, pid) do
      refute Process.alive?(pid)
    else
      monitor = Process.monitor(pid)

      result =
        fixed_outcome(fn ->
          assert Process.alive?(pid)
          assert :ok = stop.()
        end)

      try do
        assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, remaining(deadline)
        refute reason == :noproc
        refute reason == :killed
        refute Process.alive?(pid)
        assert result == :ok

        Agent.update(fixture.observer.control, fn state ->
          state
          |> put_in([:lifecycle, :stopped, kind], pid)
          |> put_in([:lifecycle, :stop_receipts, kind], %{pid: pid, reason: reason})
        end)
      after
        Process.demonitor(monitor, [:flush])
      end
    end

    :ok
  end

  defp owner_transaction!(callback) do
    assert {:ok, result} =
             MigrationRepo.transaction(fn ->
               query!("SET LOCAL ROLE singularity_table_owner")
               callback.()
             end)

    result
  end

  defp owner_sql!(sql, params \\ []), do: owner_transaction!(fn -> query!(sql, params) end)
  defp query!(sql, params \\ []), do: SafeSQL.query!(MigrationRepo, sql, params)
  defp dump(id), do: Ecto.UUID.dump!(id)
  defp text(id), do: Ecto.UUID.load!(id)
  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  # TASK18_EXISTING_RUNTIME_POPULATION_BEGIN
  defmodule PopulationError do
    @derive {Inspect, only: []}
    defexception [:primary, :cleanup]
    def message(_error), do: "existing_runtime_population"
  end

  # Borrow only this already-running installation. Its ResourceOwner remains
  # the sole lifetime authority, including when the original caller disappears.
  def with_existing_runtime(native, callback) when is_map(native) and is_function(callback, 1) do
    binding = existing_runtime_identity!(native)

    fixture =
      Map.merge(native, %{
        inputs: independent_inputs(),
        sources: %{},
        graph: %{},
        roots: %{storage: native.destination.object_root, backup: binding.backup},
        observer: %{control: nil}
      })

    permissions = permission_snapshot(fixture)
    assert_denied_write_guard!(permissions)
    child = {__MODULE__, make_ref()}

    specification = %{
      id: child,
      restart: :temporary,
      shutdown: 5_000,
      start:
        {Agent, :start_link,
         [fn -> %{lifecycle: %{permission_scopes: [], root_snapshots: nil}} end]}
    }

    control =
      case Supervisor.start_child(native.infrastructure, specification) do
        {:ok, pid} when is_pid(pid) -> pid
        _other -> raise ArgumentError, "existing_runtime_population"
      end

    monitor = Process.monitor(control)
    fixture = put_in(fixture.observer.control, control)
    caller = self()

    fixture =
      Map.merge(fixture, %{
        permission_baseline: permissions,
        permission_snapshot: fn -> permission_snapshot(fixture) end,
        permission_scope: fn controls, fun ->
          unless self() == caller, do: raise(ArgumentError, "existing_runtime_identity")
          # The existing private scope's internal try/after semantics stay intact;
          # the constructor retains the outcome actually observed at its boundary.
          permission_scope(fixture, controls, fun)
        end
      })

    try do
      outcome = existing_population_outcome(fn -> callback.(fixture) end)

      cleanup =
        existing_population_cleanup(fixture, binding, permissions, child, control, monitor)

      case {outcome, cleanup} do
        {{:returned, value}, []} ->
          value

        {{:raised, kind, reason, stack}, []} ->
          :erlang.raise(kind, reason, stack)

        {primary, failures} ->
          primary =
            case primary do
              {:raised, kind, reason, stack} -> {kind, reason, stack}
              {:returned, _private_value} -> :returned
            end

          raise PopulationError, primary: primary, cleanup: failures
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  def with_existing_runtime(_native, _callback),
    do: raise(ArgumentError, "existing_runtime_identity")

  defp existing_runtime_identity!(native) do
    try do
      true =
        Enum.sort(Map.keys(native)) == [
          :credentials,
          :destination,
          :infrastructure,
          :owner,
          :repositories,
          :session
        ]

      true = is_pid(native.owner) and Process.alive?(native.owner)
      {:dictionary, dictionary} = Process.info(native.owner, :dictionary)

      state =
        Map.fetch!(
          Map.new(dictionary),
          {Singularity.Storage.MigrationTestEnvironment, :owned_destination}
        )

      true = native.owner != self() and state.caller == self()
      true = state.database_status == :created and state.root_claimed?

      true =
        state.infrastructure == native.infrastructure and Process.alive?(native.infrastructure)

      true = native.destination.repo == MigrationRepo
      names = state.names
      true = names.database =~ ~r/\Asingularity_test_[0-9a-f]{24}\z/
      true = names.database == "singularity_test_" <> names.suffix

      true =
        names.storage_root ==
          Path.join([System.tmp_dir!(), "singularity", "integration", names.suffix])

      true = native.destination.database == names.database
      true = native.destination.object_root == Path.join(names.storage_root, "objects")
      true = state.root_identity == existing_population_directory!(names.storage_root)

      true =
        Application.fetch_env!(:singularity_storage, :storage_root) ==
          native.destination.object_root

      backup = Path.join(names.storage_root, "backups")
      true = Application.fetch_env!(:singularity_storage, :backup_root) == backup

      roots =
        Map.new(
          [names.storage_root, native.destination.object_root, backup],
          &{&1, existing_population_directory!(&1)}
        )

      repos = [
        MigrationRepo,
        RequestRepo,
        Singularity.Storage.PreAuthRepo,
        Singularity.Storage.DispatcherRepo,
        Singularity.Storage.WorkerRepo
      ]

      true = Enum.sort(Map.keys(native.repositories)) == Enum.sort(repos)
      true = Enum.sort(Map.keys(state.active_repos)) == Enum.sort(repos)

      for repo <- repos do
        {pid, database} = Map.fetch!(native.repositories, repo)
        true = is_pid(pid) and Process.alive?(pid) and Process.whereis(repo) == pid
        true = state.active_repos[repo] == pid and {repo, pid} in state.owned_repos
        true = database == names.database
        true = Keyword.fetch!(repo.config(), :database) == database
      end

      databases =
        Enum.map(repos, fn repo ->
          %{rows: [[database, oid]]} =
            SafeSQL.query!(
              repo,
              "SELECT current_database(),oid::bigint FROM pg_catalog.pg_database WHERE datname=current_database()",
              [],
              log: false
            )

          true = database == names.database
          oid
        end)

      true = length(Enum.uniq(databases)) == 1
      children = Supervisor.which_children(native.infrastructure) |> Enum.sort()
      custodian = Process.whereis(KeyCustodian)
      true = is_pid(custodian) and Process.alive?(custodian)

      true =
        Enum.count(children, fn {id, pid, _, _} -> id == KeyCustodian and pid == custodian end) ==
          1

      true = Enum.all?(children, fn {_, pid, _, _} -> is_pid(pid) and Process.alive?(pid) end)

      true =
        not Enum.any?(Application.started_applications(), &(elem(&1, 0) == :singularity_runtime))

      configuration = Application.fetch_env!(:singularity_runtime, :authorization_dependencies)
      true = configuration == %{store: IdentityRepository, custodian: KeyCustodian}
      {:ok, dependencies} = AuthorizationDependencies.new(configuration)
      # Normal native authorization intentionally retains its existing idle touch.
      # Before-effects means before this constructor's child/GRANT/root/config work,
      # not a claim that existing authenticated authorization is side-effect-free.
      :ok =
        RequestRepo.checkout(fn ->
          Singularity.Storage.ScopedRepo.transact(
            RequestRepo,
            Map.take(native.session, [:principal_id, :vault_id]),
            fn repo ->
              {:ok, live} = IdentityRepository.load_live_session(repo, native.session.session_id)
              true = is_map(live)

              for key <- [:account_id, :credential_id, :principal_id, :vault_id] do
                true = Map.fetch!(live, key) == Map.fetch!(native.credentials.owner, key)
              end

              true =
                native.session.principal_id == live.principal_id and
                  native.session.vault_id == live.vault_id

              true =
                native.session.principal_authorization_epoch == live.principal_authorization_epoch

              true = native.session.vault_authorization_epoch == live.vault_authorization_epoch
              true = native.session.unlocked? == true and live.vault_locked == false

              :ok =
                Authorize.check(dependencies, repo, native.session, %{
                  vault_id: live.vault_id,
                  principal_authorization_epoch: live.principal_authorization_epoch,
                  vault_authorization_epoch: live.vault_authorization_epoch,
                  required_capabilities: ["asset.read", "asset.write", "note.read", "note.write"],
                  classification: :private
                })

              :ok
            end
          )
        end)

      %{
        backup: backup,
        roots: roots,
        oid: hd(databases),
        children: children,
        environments: Map.new(@fixture_apps, &{&1, Map.new(Application.get_all_env(&1))})
      }
    catch
      _kind, _private_reason -> raise ArgumentError, "existing_runtime_identity"
    end
  end

  defp existing_population_directory!(path) do
    true = is_binary(path) and Path.type(path) == :absolute and Path.expand(path) == path
    directory_chain!(path)

    %File.Stat{
      type: :directory,
      uid: uid,
      mode: mode,
      major_device: major,
      minor_device: minor,
      inode: inode
    } = File.lstat!(path)

    true = uid == File.stat!(__DIR__).uid
    true = Bitwise.band(mode, 0o777) == 0o700
    {major, minor, inode}
  end

  defp existing_population_cleanup(fixture, binding, permissions, child, control, monitor) do
    failures =
      existing_population_cleanup_step([], :permission_restore, fn ->
        {migration, database} = Map.fetch!(fixture.repositories, MigrationRepo)
        true = Process.whereis(MigrationRepo) == migration and Process.alive?(migration)

        %{rows: [[^database, oid]]} =
          SafeSQL.query!(
            MigrationRepo,
            "SELECT current_database(),oid::bigint FROM pg_catalog.pg_database WHERE datname=current_database()",
            [],
            log: false
          )

        true = oid == binding.oid
        restore_permission_scopes!(fixture)
        true = permission_snapshot(fixture) == permissions
        true = Agent.get(control, & &1.lifecycle.permission_scopes) == []
      end)

    failures =
      existing_population_cleanup_step(failures, :journal_stop, fn ->
        case Enum.find(Supervisor.which_children(fixture.infrastructure), &(elem(&1, 0) == child)) do
          {^child, ^control, :worker, _modules} ->
            :ok = Supervisor.terminate_child(fixture.infrastructure, child)

          nil ->
            true = not Process.alive?(control)

          _replacement ->
            raise ArgumentError, "existing_runtime_population"
        end

        receive do
          {:DOWN, ^monitor, :process, ^control, _reason} -> :ok
        after
          5_000 -> raise ArgumentError, "existing_runtime_population"
        end
      end)

    failures =
      existing_population_cleanup_step(failures, :journal_remove, fn ->
        # Temporary children lose their specification on termination. Never
        # delete a replacement's specification merely because its ID matches.
        true = not Process.alive?(control)

        true =
          not Enum.any?(
            Supervisor.which_children(fixture.infrastructure),
            &(elem(&1, 0) == child or elem(&1, 1) == control)
          )
      end)

    existing_population_cleanup_step(failures, :installation_identity, fn ->
      true =
        existing_runtime_identity!(
          Map.take(fixture, [
            :credentials,
            :destination,
            :infrastructure,
            :owner,
            :repositories,
            :session
          ])
        ) == binding
    end)
  end

  defp existing_population_cleanup_step(failures, category, callback) do
    case existing_population_outcome(callback) do
      {:returned, _} -> failures
      {:raised, _, _, _} -> failures ++ [category]
    end
  end

  defp existing_population_outcome(callback) do
    try do
      {:returned, callback.()}
    catch
      kind, reason -> {:raised, kind, reason, __STACKTRACE__}
    end
  end

  # TASK18_EXISTING_RUNTIME_POPULATION_END
end
