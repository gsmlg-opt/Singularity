defmodule Singularity.Runtime.ExportLeaseOwnershipTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Runtime.{DownloadLease, KeyCustodian, KeyLeaseSupervisor}

  @moduletag :unit
  @acquisition_ms 5_000
  @session_id "00000000-0000-4000-8000-000000000601"
  @principal_id "00000000-0000-4000-8000-000000000602"
  @vault_id "00000000-0000-4000-8000-000000000603"
  @object_id "00000000-0000-4000-8000-000000000604"
  @job_id "00000000-0000-4000-8000-000000000605"
  @version_id "00000000-0000-4000-8000-000000000606"

  # UNIT isolation only: these doubles do not qualify live authorization,
  # encrypted storage, source verification, or plaintext integrity.
  defmodule Authorization do
    def revalidate(context, binding) do
      send(context.observer, {:unit_revalidated, binding})
      Agent.get(context.control, &Map.get(&1, :authority, :ok))
    end
  end

  defmodule Clock do
    def utc_now(context) do
      if Map.has_key?(context, :object_binding) do
        token = make_ref()
        caller = self()

        first? =
          Agent.get_and_update(context.control, fn state ->
            seen = Map.get(state, :clock_seen, MapSet.new())

            {not MapSet.member?(seen, caller),
             Map.put(state, :clock_seen, MapSet.put(seen, caller))}
          end)

        if first?, do: send(context.observer, {:unit_init, self(), token})

        block? =
          Agent.get_and_update(context.control, fn state ->
            {Map.get(state, :block_clock?, false), Map.put(state, :block_clock?, false)}
          end)

        if block? do
          send(context.observer, {:unit_barrier, :clock, self(), token})

          receive do
            {:unit_release, ^token} -> :ok
          end
        end
      end

      DateTime.utc_now()
    end
  end

  defmodule Reader do
    def load_object_key(context, binding, _hierarchy) do
      if Agent.get(context.control, &Map.get(&1, :block_loader?, false)) do
        token = make_ref()
        send(context.observer, {:unit_barrier, :loader, self(), token})

        receive do
          {:unit_release, ^token} -> :ok
        end
      end

      reader_binding =
        binding
        |> Map.put(:plaintext_byte_size, 6)
        |> Map.merge(Agent.get(context.control, &Map.get(&1, :loaded_binding, %{})))

      {:ok, %{object_dek: :binary.copy(<<0xD1>>, 32), reader_binding: reader_binding}}
    end

    def load_checkpoint(_context, _binding), do: raise("request export must not load checkpoints")

    def read_range(context, binding, range), do: read(context, binding, range)
    def read_chunk(context, binding, index), do: read(context, binding, {:chunk, index})

    defp read(context, binding, range) do
      token = make_ref()
      send(context.observer, {:unit_read, self(), token, binding, range})

      if Agent.get(context.control, &Map.get(&1, :block_reader?, false)) do
        receive do
          {:unit_release, ^token} -> :ok
        end
      end

      {:ok, "source"}
    end
  end

  setup do
    # Missing API is the intended RED, before any blocking activity starts.
    assert Code.ensure_loaded?(KeyCustodian)
    assert function_exported?(KeyCustodian, :export_lease, 2), "missing native export_lease/2"
    :ok
  end

  for source <- [:asset, :document] do
    test "UNIT #{source}: accepted export preserves exact binding and authenticated reads" do
      source = unquote(source)
      fixture = fixture()
      request = request(source)
      assert {:ok, lease} = export_lease(fixture.custodian, request)
      assert is_pid(lease)
      assert {:ok, "source"} = read(source, lease)
      assert_receive {:unit_read, _reader, _token, binding, _range}, 1_000
      assert binding == Map.delete(request, :purpose)
      assert_receive {:unit_revalidated, ^binding}, 1_000
      assert_receive {:unit_revalidated, ^binding}, 1_000
    end

    test "UNIT #{source}: death after real return before recording cleans custody" do
      source = unquote(source)
      fixture = fixture()
      owner = acquisition_owner(fixture, source)
      assert_receive {:unit_export_result, ^owner, {:ok, lease}, _elapsed}, 1_000
      lease_monitor = Process.monitor(lease)
      kill_and_await(owner)
      assert_receive {:DOWN, ^lease_monitor, :process, ^lease, _reason}, 1_000
      assert_denied(read(source, lease))
      assert KeyCustodian.unlocked?(fixture.custodian, @session_id)
    end

    test "UNIT #{source}: owner death during a delayed loader cannot create abandoned custody" do
      source = unquote(source)
      fixture = fixture(block_loader?: true)
      owner = acquisition_owner(fixture, source)
      assert_receive {:unit_barrier, :loader, loader, token}, 1_000
      kill_and_await(owner)
      send(loader, {:unit_release, token})
      assert KeyCustodian.unlocked?(fixture.custodian, @session_id)
      assert_observed_inits_terminated()
      refute_received {:unit_export_result, ^owner, {:ok, _lease}, _elapsed}
      refute_received {:unit_read, _, _, _, _}
    end

    test "UNIT #{source}: owner death before init usability terminates the observed child" do
      source = unquote(source)
      fixture = fixture(block_clock?: true)
      owner = acquisition_owner(fixture, source)
      assert_receive {:unit_barrier, :clock, lease, token}, 1_000
      lease_monitor = Process.monitor(lease)
      kill_and_await(owner)
      send(lease, {:unit_release, token})
      assert KeyCustodian.unlocked?(fixture.custodian, @session_id)
      assert_receive {:DOWN, ^lease_monitor, :process, ^lease, _reason}, 1_000
      refute_received {:unit_export_result, ^owner, {:ok, _lease}, _elapsed}
      refute_received {:unit_read, _, _, _, _}
    end

    test "UNIT #{source}: actual five-second loader timeout cancels for a surviving caller" do
      source = unquote(source)
      fixture = fixture(block_loader?: true)
      owner = acquisition_owner(fixture, source)
      assert_receive {:unit_barrier, :loader, loader, token}, 1_000

      assert_receive {:unit_export_result, ^owner,
                      {:error, %Error{code: :storage_unavailable, retryable?: true}}, elapsed},
                     7_000

      assert elapsed >= @acquisition_ms
      assert Process.alive?(owner)
      send(loader, {:unit_release, token})
      assert KeyCustodian.unlocked?(fixture.custodian, @session_id)
      # Rejection before child start is valid. Any observed child must be gone;
      # this observer never revokes an unknown PID or performs recovery.
      assert_observed_inits_terminated()
      refute_received {:unit_read, _, _, _, _}
    end

    test "UNIT #{source}: actual five-second init timeout cleans custody without a read" do
      source = unquote(source)
      fixture = fixture(block_clock?: true)
      owner = acquisition_owner(fixture, source)
      assert_receive {:unit_barrier, :clock, lease, token}, 1_000
      lease_monitor = Process.monitor(lease)

      assert_receive {:unit_export_result, ^owner,
                      {:error, %Error{code: :storage_unavailable, retryable?: true}}, elapsed},
                     7_000

      assert elapsed >= @acquisition_ms
      assert Process.alive?(owner)
      send(lease, {:unit_release, token})
      assert KeyCustodian.unlocked?(fixture.custodian, @session_id)
      assert_receive {:DOWN, ^lease_monitor, :process, ^lease, _reason}, 1_000
      refute_received {:unit_read, _, _, _, _}
    end

    test "UNIT #{source}: expired successful reply waits for known-lease cleanup acknowledgement" do
      source = unquote(source)
      fixture = fixture(block_clock?: true)
      owner = acquisition_owner(fixture, source)
      assert_receive {:unit_barrier, :clock, lease, token}, 1_000
      lease_monitor = Process.monitor(lease)

      on_exit(fn ->
        resume_if_suspended(owner)
        resume_if_suspended(lease)
      end)

      try do
        assert :erlang.suspend_process(owner)
        send(lease, {:unit_release, token})
        # The public custodian fence follows child initialization and the real
        # successful reply, while its actual requester cannot yet accept it.
        assert KeyCustodian.unlocked?(fixture.custodian, @session_id)
        assert :erlang.suspend_process(lease)

        boundary = make_ref()
        Process.send_after(self(), {:unit_acquisition_boundary, boundary}, @acquisition_ms + 10)
        assert_receive {:unit_acquisition_boundary, ^boundary}, 7_000
        assert :erlang.resume_process(owner)

        # Cancellation alone is insufficient: the native wrapper must wait for
        # the known lease's revoke acknowledgement or actual termination.
        refute_receive {:unit_export_result, ^owner, _result, _elapsed}, 100
        assert Process.alive?(owner)
        assert Process.alive?(lease)
        assert :erlang.resume_process(lease)

        assert_receive {:unit_export_result, ^owner,
                        {:error, %Error{code: :storage_unavailable, retryable?: true}}, elapsed},
                       1_000

        assert elapsed >= @acquisition_ms
        assert Process.alive?(owner)
        assert_receive {:DOWN, ^lease_monitor, :process, ^lease, _reason}, 1_000
        assert_denied(read(source, lease))
        assert KeyCustodian.unlocked?(fixture.custodian, @session_id)
        refute_received {:unit_read, _, _, _, _}
      after
        resume_if_suspended(owner)
        resume_if_suspended(lease)
      end
    end

    test "UNIT #{source}: owner death kills the in-flight reader without successful delivery" do
      source = unquote(source)
      fixture = fixture(block_reader?: true)
      owner = acquisition_owner(fixture, source)
      assert_receive {:unit_export_result, ^owner, {:ok, lease}, _elapsed}, 1_000
      lease_monitor = Process.monitor(lease)
      read_task = Task.async(fn -> read(source, lease) end)
      assert_receive {:unit_read, reader, _token, _binding, _range}, 1_000
      reader_monitor = Process.monitor(reader)
      kill_and_await(owner)
      assert_receive {:DOWN, ^reader_monitor, :process, ^reader, :killed}, 1_000
      assert_receive {:DOWN, ^lease_monitor, :process, ^lease, _reason}, 1_000
      assert_denied(Task.await(read_task, 1_000))
    end

    test "UNIT #{source}: known-lease revoke confirms reader death and stops custody" do
      source = unquote(source)
      fixture = fixture(block_reader?: true)
      assert {:ok, lease} = export_lease(fixture.custodian, request(source))
      lease_monitor = Process.monitor(lease)
      read_task = Task.async(fn -> read(source, lease) end)
      assert_receive {:unit_read, reader, _token, _binding, _range}, 1_000
      reader_monitor = Process.monitor(reader)
      assert :ok = DownloadLease.revoke(lease)
      refute Process.alive?(reader)
      assert_receive {:DOWN, ^reader_monitor, :process, ^reader, :killed}, 1_000
      assert_receive {:DOWN, ^lease_monitor, :process, ^lease, _reason}, 1_000
      assert_denied(Task.await(read_task, 1_000))
    end

    test "UNIT #{source}: hard lease death also kills its linked blocked reader" do
      source = unquote(source)
      fixture = fixture(block_reader?: true)
      assert {:ok, lease} = export_lease(fixture.custodian, request(source))
      read_task = Task.async(fn -> read(source, lease) end)
      assert_receive {:unit_read, reader, _token, _binding, _range}, 1_000
      reader_monitor = Process.monitor(reader)
      kill_and_await(lease)
      assert_receive {:DOWN, ^reader_monitor, :process, ^reader, :killed}, 1_000
      assert_denied(Task.await(read_task, 1_000))
    end

    test "UNIT #{source}: owner death during a clock denies storage after the callback" do
      source = unquote(source)
      fixture = fixture()
      owner = acquisition_owner(fixture, source)
      assert_receive {:unit_export_result, ^owner, {:ok, lease}, _elapsed}, 1_000
      lease_monitor = Process.monitor(lease)
      Agent.update(fixture.control, &Map.put(&1, :block_clock?, true))
      read_task = Task.async(fn -> read(source, lease) end)
      assert_receive {:unit_barrier, :clock, ^lease, token}, 1_000
      kill_and_await(owner)
      send(lease, {:unit_release, token})
      assert_receive {:DOWN, ^lease_monitor, :process, ^lease, _reason}, 1_000
      assert_denied(Task.await(read_task, 1_000))
      refute_received {:unit_read, _, _, _, _}
    end

    test "UNIT #{source}: owner death during the delivery clock denies successful delivery" do
      source = unquote(source)
      fixture = fixture(block_reader?: true)
      owner = acquisition_owner(fixture, source)
      assert_receive {:unit_export_result, ^owner, {:ok, lease}, _elapsed}, 1_000
      lease_monitor = Process.monitor(lease)
      read_task = Task.async(fn -> read(source, lease) end)
      assert_receive {:unit_read, reader, reader_token, _binding, _range}, 1_000
      reader_monitor = Process.monitor(reader)
      Agent.update(fixture.control, &Map.put(&1, :block_clock?, true))
      send(reader, {:unit_release, reader_token})
      assert_receive {:unit_barrier, :clock, ^lease, clock_token}, 1_000
      assert_receive {:DOWN, ^reader_monitor, :process, ^reader, _reason}, 1_000
      kill_and_await(owner)
      send(lease, {:unit_release, clock_token})
      assert_receive {:DOWN, ^lease_monitor, :process, ^lease, _reason}, 1_000
      assert_denied(Task.await(read_task, 1_000))
    end

    test "UNIT #{source}: cleanup preserves same-session ordinary and independent exports" do
      source = unquote(source)
      fixture = fixture()
      assert {:ok, ordinary} = KeyCustodian.lease(fixture.custodian, request(source))
      first_owner = acquisition_owner(fixture, source)
      assert_receive {:unit_export_result, ^first_owner, {:ok, first}, _elapsed}, 1_000
      second_owner = acquisition_owner(fixture, source)
      assert_receive {:unit_export_result, ^second_owner, {:ok, second}, _elapsed}, 1_000
      first_monitor = Process.monitor(first)
      kill_and_await(first_owner)
      assert_receive {:DOWN, ^first_monitor, :process, ^first, _reason}, 1_000
      assert KeyCustodian.unlocked?(fixture.custodian, @session_id)
      assert {:ok, "source"} = read(source, ordinary)
      assert {:ok, "source"} = read(source, second)
      assert Process.alive?(second_owner)
    end

    test "UNIT #{source}: caller lifecycle fields and malformed authority remain rejected" do
      source = unquote(source)
      fixture = fixture()
      original = request(source)

      for {field, value} <- [
            {:owner_pid, self()},
            {:consumer_pid, self()},
            {:export_ownership, %{}},
            {:ticket, make_ref()},
            {:timeout, 1},
            {:timeout_ms, 1},
            {:deadline_ms, 0},
            {:clock, Clock},
            {:mode, :document_worker_source},
            {:access, :forged},
            {:unexpected, true},
            {"purpose", :download}
          ] do
        assert {:error, %Error{code: :invalid}} =
                 export_lease(fixture.custodian, Map.put(original, field, value))
      end

      for {field, value} <- [
            {:required_capability, "asset.write"},
            {:object_generation, 0},
            {:principal_authorization_epoch, -1},
            {:vault_authorization_epoch, "11"},
            {:purpose, :metadata},
            {:purpose, :document_extraction_source},
            {:purpose, "download"}
          ] do
        assert {:error, %Error{code: :invalid}} =
                 export_lease(fixture.custodian, Map.put(original, field, value))
      end

      for field <- Map.keys(original) do
        assert {:error, %Error{code: :invalid}} =
                 export_lease(fixture.custodian, Map.delete(original, field))
      end

      for {field, value} <- [
            {:session_id, "another-session"},
            {:principal_id, "another-principal"},
            {:vault_id, "another-owner-scope"},
            {:principal_authorization_epoch, 8},
            {:vault_authorization_epoch, 12}
          ] do
        assert {:error, :waiting_for_unlock} =
                 export_lease(fixture.custodian, Map.put(original, field, value))
      end

      refute_received {:unit_init, _, _}
      refute_received {:unit_read, _, _, _, _}
    end

    test "UNIT #{source}: forged loaded object binding is rejected by native source validation" do
      source = unquote(source)

      for mismatch <- [
            %{object_id: "another-object"},
            %{object_generation: 4},
            %{vault_id: "another-owner-scope"}
          ] do
        fixture = fixture(loaded_binding: mismatch)

        assert {:error, %Error{code: :integrity_failure}} =
                 export_lease(fixture.custodian, request(source))
      end

      refute_received {:unit_init, _, _}
      refute_received {:unit_read, _, _, _, _}
    end
  end

  test "UNIT Document: accepted lease retains original TTL after the acquisition deadline" do
    fixture = fixture()
    boundary = make_ref()
    assert {:ok, lease} = export_lease(fixture.custodian, request(:document))
    Process.send_after(self(), {:unit_acquisition_boundary, boundary}, @acquisition_ms + 10)
    assert_receive {:unit_acquisition_boundary, ^boundary}, 6_000
    assert {:ok, "source"} = DownloadLease.read_document_chunk(lease, 0)
    assert {:ok, "source"} = DownloadLease.read_document_chunk(lease, 1)
    monitor = Process.monitor(lease)
    assert :ok = DownloadLease.revoke(lease)
    assert_receive {:DOWN, ^monitor, :process, ^lease, _reason}, 1_000
  end

  test "UNIT Document: export rejects worker access and worker-only fields" do
    fixture = fixture()

    for malformed <- [
          Map.put(request(:document), :access, :worker),
          Map.put(request(:document), :access, :forged),
          Map.put(request(:document), :job_id, @job_id),
          request(:document)
          |> Map.delete(:session_id)
          |> Map.merge(%{access: :worker, job_id: @job_id})
        ] do
      assert {:error, %Error{code: :invalid}} = export_lease(fixture.custodian, malformed)
    end

    refute_received {:unit_init, _, _}
  end

  test "UNIT authorization denial remains fail-closed before and after storage" do
    for source <- [:asset, :document] do
      fixture = fixture(authority: {:error, Error.new(:forbidden)})
      assert {:ok, lease} = export_lease(fixture.custodian, request(source))
      assert {:error, %Error{code: :forbidden}} = read(source, lease)
      refute_received {:unit_read, _, _, _, _}

      fixture = fixture(block_reader?: true)
      assert {:ok, lease} = export_lease(fixture.custodian, request(source))
      read_task = Task.async(fn -> read(source, lease) end)
      assert_receive {:unit_read, reader, token, _binding, _range}, 1_000
      Agent.update(fixture.control, &Map.put(&1, :authority, {:error, Error.new(:forbidden)}))
      send(reader, {:unit_release, token})
      assert {:error, %Error{code: :forbidden}} = Task.await(read_task, 1_000)
    end
  end

  test "UNIT pending constructor cannot read storage and revoke cancels its ticket" do
    ownership = Singularity.Runtime.DownloadLease.ExportOwnership
    assert Code.ensure_loaded?(ownership)
    assert function_exported?(ownership, :new, 0)
    fixture = fixture()

    for source <- [:asset, :document] do
      ticket = apply(ownership, :new, [])

      assert {:ok, lease} =
               KeyLeaseSupervisor.start_download_lease(fixture.supervisor, %{
                 authorization: Authorization,
                 binding: Map.delete(request(source), :purpose),
                 clock: Clock,
                 context: %{
                   observer: self(),
                   control: fixture.control,
                   object_binding: %{plaintext_byte_size: 6}
                 },
                 custodian: fixture.custodian,
                 key_material: :binary.copy(<<0xD1>>, 32),
                 key_reader: Reader,
                 export_ownership: %{owner_pid: self(), ticket: ticket}
               })

      assert {:error, :waiting_for_unlock} = read(source, lease)
      refute_received {:unit_read, _, _, _, _}
      monitor = Process.monitor(lease)
      assert :ok = DownloadLease.revoke(lease)
      assert_receive {:DOWN, ^monitor, :process, ^lease, _reason}, 1_000
      assert :cancelled = apply(ownership, :status, [ticket])
    end
  end

  test "UNIT public acquisition sanitizes a custody exit without killing its caller" do
    dead_custodian =
      spawn(fn ->
        receive do
          :unit_stop -> :ok
        end
      end)

    kill_and_await(dead_custodian)

    assert {:error, %Error{code: :storage_unavailable, retryable?: true}} =
             export_lease(dead_custodian, request(:asset))

    assert Process.alive?(self())
  end

  defp fixture(options \\ []) do
    control = start_supervised!({Agent, fn -> Map.new(options) end}, id: make_ref())
    supervisor = start_supervised!({KeyLeaseSupervisor, name: nil}, id: make_ref())

    custodian =
      start_supervised!(
        {KeyCustodian,
         %{
           authorization: Authorization,
           clock: Clock,
           context: %{observer: self(), control: control},
           idle_lock: fn _session -> :ok end,
           key_reader: Reader,
           lease_supervisor: supervisor,
           object_key_loader: Reader
         }},
        id: make_ref()
      )

    session = %{
      session_id: @session_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 11,
      expires_at: DateTime.add(DateTime.utc_now(), 300, :second),
      vault_key: :binary.copy(<<0xA1>>, 32)
    }

    assert {:ok, pending} = KeyCustodian.prepare_unlock(custodian, session)
    assert :ok = KeyCustodian.activate_unlock(custodian, pending)
    %{custodian: custodian, control: control, supervisor: supervisor}
  end

  defp request(source) do
    binding = %{
      session_id: @session_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      required_capability: "asset.read",
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 11,
      object_id: @object_id,
      object_generation: 3
    }

    case source do
      :asset ->
        Map.merge(binding, %{purpose: :download, job_id: @job_id})

      :document ->
        Map.merge(binding, %{
          purpose: :document_source,
          access: :request,
          resource_version_id: @version_id
        })
    end
  end

  defp export_lease(custodian, request),
    do: apply(KeyCustodian, :export_lease, [custodian, request])

  defp read(:asset, lease), do: DownloadLease.read(lease, :all)
  defp read(:document, lease), do: DownloadLease.read_document_chunk(lease, 0)

  defp acquisition_owner(fixture, source) do
    observer = self()

    owner =
      spawn(fn ->
        started_at = System.monotonic_time(:millisecond)
        result = export_lease(fixture.custodian, request(source))
        elapsed = System.monotonic_time(:millisecond) - started_at
        send(observer, {:unit_export_result, self(), result, elapsed})

        receive do
          :unit_stop -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
    owner
  end

  defp resume_if_suspended(pid) do
    :erlang.resume_process(pid)
  rescue
    ArgumentError -> :ok
  end

  defp kill_and_await(pid) do
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1_000
  end

  defp assert_observed_inits_terminated do
    receive do
      {:unit_init, pid, _token} ->
        monitor = Process.monitor(pid)
        assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 1_000
        assert_observed_inits_terminated()
    after
      0 -> :ok
    end
  end

  defp assert_denied({:error, :waiting_for_unlock}), do: :ok
  defp assert_denied({:error, %Error{code: :storage_unavailable}}), do: :ok
  defp assert_denied(_result), do: flunk("expected sanitized native read denial")
end

defmodule Singularity.Runtime.ExportLeaseOwnershipTicketTest do
  use ExUnit.Case, async: true

  @moduletag :unit
  @ownership Singularity.Runtime.DownloadLease.ExportOwnership

  setup do
    assert Code.ensure_loaded?(@ownership), "missing internal export ownership helper"

    for {name, arity} <- [
          new: 0,
          remaining_ms: 1,
          status: 1,
          accept: 1,
          cancel: 1,
          expire_pending: 1
        ] do
      assert function_exported?(@ownership, name, arity), "missing internal ownership operation"
    end

    :ok
  end

  test "SYNTHETIC UNIT ticket: new acquisition is pending with the fixed native budget" do
    ticket = call(:new, [])
    assert :pending = call(:status, [ticket])
    assert remaining = call(:remaining_ms, [ticket])
    assert is_integer(remaining) and remaining >= 0 and remaining <= 5_000
  end

  test "SYNTHETIC UNIT ticket: accepted timer is a no-op and cancellation stays terminal" do
    ticket = call(:new, [])
    assert :ok = call(:accept, [ticket])
    assert :accepted = call(:status, [ticket])
    assert :accepted = call(:expire_pending, [ticket])
    assert :accepted = call(:status, [ticket])
    assert :ok = call(:cancel, [ticket])
    assert :cancelled = call(:status, [ticket])
    assert :cancelled = call(:accept, [ticket])
    assert :cancelled = call(:expire_pending, [ticket])
    assert :ok = call(:cancel, [ticket])
  end

  test "SYNTHETIC UNIT ticket: pending expiry and early cancellation can never be accepted" do
    ticket = call(:new, [])
    assert :cancelled = call(:expire_pending, [ticket])
    assert :cancelled = call(:status, [ticket])
    assert :cancelled = call(:accept, [ticket])

    ticket = call(:new, [])
    assert :ok = call(:cancel, [ticket])
    assert :cancelled = call(:accept, [ticket])
    assert :cancelled = call(:status, [ticket])
  end

  test "SYNTHETIC UNIT ticket: expired acceptance cancels shared lifecycle state" do
    ticket = call(:new, [])
    # Pure helper boundary only. No shortened deadline enters export_lease/2.
    expired = Map.put(ticket, :deadline_ms, System.monotonic_time(:millisecond) - 1)
    assert 0 = call(:remaining_ms, [expired])
    assert :cancelled = call(:accept, [expired])
    assert :cancelled = call(:status, [ticket])
    assert :cancelled = call(:accept, [ticket])
  end

  test "SYNTHETIC UNIT ticket: racing expiry never resurrects cancelled state" do
    for _attempt <- 1..32 do
      ticket = call(:new, [])
      token = make_ref()
      observer = self()

      accepter =
        spawn(fn ->
          receive do
            {:unit_race, ^token} ->
              send(observer, {:unit_accepted, token, call(:accept, [ticket])})
          end
        end)

      expirer =
        spawn(fn ->
          receive do
            {:unit_race, ^token} ->
              send(observer, {:unit_expired, token, call(:expire_pending, [ticket])})
          end
        end)

      accepter_monitor = Process.monitor(accepter)
      expirer_monitor = Process.monitor(expirer)
      send(accepter, {:unit_race, token})
      send(expirer, {:unit_race, token})
      assert_receive {:unit_accepted, ^token, accepted}, 1_000
      assert_receive {:unit_expired, ^token, expired}, 1_000
      assert {accepted, expired} in [{:ok, :accepted}, {:cancelled, :cancelled}]
      assert_receive {:DOWN, ^accepter_monitor, :process, ^accepter, :normal}, 1_000
      assert_receive {:DOWN, ^expirer_monitor, :process, ^expirer, :normal}, 1_000
      assert :ok = call(:cancel, [ticket])
      assert :cancelled = call(:accept, [ticket])
      assert :cancelled = call(:status, [ticket])
    end
  end

  defp call(name, arguments), do: apply(@ownership, name, arguments)
end
