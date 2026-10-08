defmodule Singularity.Runtime.DownloadLeaseTest do
  use ExUnit.Case, async: true

  alias Singularity.Runtime.DownloadLease
  alias Singularity.Runtime.KeyCustodian
  alias Singularity.Runtime.KeyLeaseSupervisor

  @session_id "00000000-0000-4000-8000-000000000501"
  @principal_id "00000000-0000-4000-8000-000000000502"
  @vault_id "00000000-0000-4000-8000-000000000503"
  @object_id "00000000-0000-4000-8000-000000000504"
  @job_id "00000000-0000-4000-8000-000000000505"

  defmodule Authorization do
    def revalidate(%{owner: owner}, binding) do
      send(owner, {:download_revalidated, binding})
      :ok
    end
  end

  defmodule Clock do
    def utc_now(_context), do: DateTime.utc_now()
  end

  defmodule Reader do
    def load_checkpoint(_context, _binding) do
      raise "download leases must not use job checkpoints"
    end

    def read_range(%{owner: owner} = context, binding, range) do
      send(owner, {:download_read_started, self(), binding, range})

      if Map.get(context, :block_read?, false) do
        receive do
          :release_download_read -> {:ok, "released bytes"}
        end
      else
        {:ok, "authenticated range"}
      end
    end
  end

  defmodule ObjectKeyLoader do
    def load_object_key(context, binding, _hierarchy) do
      {:ok,
       %{
         object_dek: context.object_dek,
         reader_binding: %{
           object_id: binding.object_id,
           object_generation: binding.object_generation,
           vault_id: binding.vault_id
         }
       }}
    end
  end

  test "a custody-issued download lease skips job checkpoints and returns authenticated bytes" do
    lease_supervisor =
      start_supervised!(
        {KeyLeaseSupervisor, name: nil},
        id: make_ref()
      )

    custodian =
      start_supervised!(
        {KeyCustodian, custodian_options(lease_supervisor, %{owner: self()})},
        id: make_ref()
      )

    assert :ok = activate(custodian)

    assert {:ok, lease} =
             KeyCustodian.lease(custodian, lease_request())

    assert is_pid(lease)
    refute match?(%{object_dek: _secret}, lease)

    assert {:ok, "authenticated range"} =
             DownloadLease.read(lease, 2..8)

    assert_receive {:download_read_started, _worker, binding, 2..8}
    assert binding == Map.take(lease_request(), request_fields())
    assert_receive {:download_revalidated, ^binding}
    assert_receive {:download_revalidated, ^binding}
  end

  test "custody revocation wins against a blocked download and returns no plaintext" do
    lease_supervisor =
      start_supervised!(
        {KeyLeaseSupervisor, name: nil},
        id: make_ref()
      )

    context = %{owner: self(), block_read?: true}

    custodian =
      start_supervised!(
        {KeyCustodian, custodian_options(lease_supervisor, context)},
        id: make_ref()
      )

    assert :ok = activate(custodian)
    assert {:ok, lease} = KeyCustodian.lease(custodian, lease_request())

    read = Task.async(fn -> DownloadLease.read(lease, :all) end)

    assert_receive {:download_read_started, worker, _binding, :all}
    monitor = Process.monitor(worker)

    assert {:ok, _token} =
             KeyCustodian.begin_revoke(custodian, %{session_id: @session_id})

    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    assert {:error, :waiting_for_unlock} = Task.await(read)
    refute_receive {:download_plaintext, _bytes}
  end

  defp activate(custodian) do
    with {:ok, pending} <-
           KeyCustodian.prepare_unlock(custodian, %{
             session_id: @session_id,
             principal_id: @principal_id,
             vault_id: @vault_id,
             principal_authorization_epoch: 7,
             vault_authorization_epoch: 11,
             vault_key: :binary.copy(<<0xA1>>, 32)
           }) do
      KeyCustodian.activate_unlock(custodian, pending)
    end
  end

  defp custodian_options(lease_supervisor, context) do
    Map.merge(
      %{
        authorization: Authorization,
        clock: Clock,
        idle_lock: fn _session -> :ok end,
        key_reader: Reader,
        lease_supervisor: lease_supervisor,
        object_key_loader: ObjectKeyLoader
      },
      %{
        context:
          Map.put(
            context,
            :object_dek,
            :binary.copy(<<0xD1>>, 32)
          )
      }
    )
  end

  defp lease_request do
    %{
      job_id: @job_id,
      purpose: :download,
      session_id: @session_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      required_capability: "asset.read",
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 11,
      object_id: @object_id,
      object_generation: 3
    }
  end

  defp request_fields do
    [
      :job_id,
      :vault_id,
      :principal_id,
      :required_capability,
      :principal_authorization_epoch,
      :vault_authorization_epoch,
      :object_id,
      :object_generation,
      :session_id
    ]
  end
end

defmodule Singularity.Runtime.DocumentFreshDownloadLeaseTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Runtime.DownloadLease

  defmodule Clock do
    def utc_now(%{clock: clock}), do: Agent.get(clock, & &1)
  end

  defmodule Authorization do
    def revalidate(context, _binding) do
      send(context.owner, :fresh_revalidated)
      Agent.get(context.authority, & &1)
    end
  end

  defmodule Reader do
    def read_chunk(context, _binding, index), do: read(context, {:chunk, index})
    def read_range(context, _binding, range), do: read(context, range)

    defp read(context, range) do
      send(context.owner, {:fresh_reader, self(), range})

      if context.block? do
        receive do
          :release -> context.result
        end
      else
        context.result
      end
    end
  end

  setup do
    clock = start_supervised!({Agent, fn -> DateTime.utc_now() end}, id: make_ref())
    authority = start_supervised!({Agent, fn -> :ok end}, id: make_ref())

    custodian =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(custodian, :kill) end)
    {:ok, clock: clock, authority: authority, custodian: custodian}
  end

  test "fresh worker reads are consumer-bound, sequential and never public ranges", context do
    lease = fresh_lease(context)
    assert {:error, %Error{code: :invalid}} = DownloadLease.read(lease, :all)
    assert {:error, %Error{code: :invalid}} = DownloadLease.read(lease, 0..3)
    assert {:error, %Error{code: :invalid}} = DownloadLease.read_document_chunk(lease, -1)
    assert {:error, %Error{code: :conflict}} = DownloadLease.read_document_chunk(lease, 1)

    assert {:error, %Error{code: :forbidden}} =
             Task.async(fn -> DownloadLease.read_document_chunk(lease, 0) end) |> Task.await()

    assert {:ok, "source"} = DownloadLease.read_document_chunk(lease, 0)
    assert {:error, %Error{code: :conflict}} = DownloadLease.read_document_chunk(lease, 0)
    assert {:ok, "source"} = DownloadLease.read_document_chunk(lease, 1)
    assert :ok = DownloadLease.revoke(lease)
    refute Process.alive?(lease)
  end

  test "concurrent requests cannot read ahead or authenticate empty while a read is pending",
       context do
    lease = fresh_lease(context, block?: true)
    request = :gen_server.send_request(lease, {:read_document_chunk, 0})
    assert_receive {:fresh_reader, reader, {:chunk, 0}}
    assert {:error, %Error{code: :conflict}} = DownloadLease.read_document_chunk(lease, 0)
    assert {:error, %Error{code: :conflict}} = empty(lease)
    assert :ok = DownloadLease.revoke(lease)
    assert {:reply, {:error, :waiting_for_unlock}} = :gen_server.wait_response(request, 1_000)
    refute Process.alive?(reader)
  end

  test "trusted empty source authenticates a full storage read and consumes the lease", context do
    lease = fresh_lease(context, size: 0, result: {:ok, ""}, block?: true)
    monitor = Process.monitor(lease)
    request = :gen_server.send_request(lease, :authenticate_empty_document_source)
    assert_receive {:fresh_reader, reader, :all}
    reader_monitor = Process.monitor(reader)
    send(reader, :release)
    assert_receive {:DOWN, ^reader_monitor, :process, ^reader, _reason}
    assert {:reply, :ok} = :gen_server.wait_response(request, 1_000)
    refute Process.alive?(reader)
    assert_receive :fresh_revalidated
    assert_receive :fresh_revalidated
    assert_receive {:DOWN, ^monitor, :process, ^lease, :normal}
  end

  test "empty authentication denies nonempty, missing trusted size, old modes and other consumers",
       context do
    for opts <- [[size: 1], [size: nil], [mode: nil, size: 0]] do
      lease = fresh_lease(context, opts)
      assert {:error, %Error{code: :invalid}} = empty(lease)
      refute_received {:fresh_reader, _, _}
    end

    lease = fresh_lease(context, size: 0)
    assert {:error, %Error{code: :forbidden}} = Task.async(fn -> empty(lease) end) |> Task.await()
    refute_received {:fresh_reader, _, _}
  end

  test "empty authentication rejects unexpected plaintext and sanitizes storage failures",
       context do
    content_canary = "empty-source-error-content-canary"

    storage_error =
      Error.new(:integrity_failure,
        message: content_canary,
        details: %{plaintext: content_canary},
        retryable?: true
      )

    for {result, retryable?} <- [{{:ok, "unexpected"}, false}, {{:error, storage_error}, true}] do
      lease = fresh_lease(context, size: 0, result: result)
      assert {:error, error} = empty(lease)

      assert error == %Error{
               code: :integrity_failure,
               message: nil,
               details: %{},
               retryable?: retryable?
             }

      refute Process.alive?(lease)
    end
  end

  test "empty authentication is denied after a chunk has been consumed", context do
    lease = fresh_lease(context, size: 0)
    assert {:ok, "source"} = DownloadLease.read_document_chunk(lease, 0)
    assert {:error, %Error{code: :invalid}} = empty(lease)
  end

  for reason <- [:revoke, :expire, :custodian_death, :consumer_death, :lease_kill, :reader_death] do
    test "#{reason} terminates the owned reader without late plaintext", context do
      consumer = spawn(fn -> consumer_loop() end)
      on_exit(fn -> Process.exit(consumer, :kill) end)
      lease = fresh_lease(context, block?: true, consumer: consumer)
      lease_monitor = Process.monitor(lease)
      send(consumer, {:read, lease, self()})
      assert_receive {:fresh_reader, reader, {:chunk, 0}}
      reader_monitor = Process.monitor(reader)

      case unquote(reason) do
        :revoke -> assert :ok = DownloadLease.revoke(lease)
        :expire -> send(lease, :expire)
        :custodian_death -> Process.exit(context.custodian, :kill)
        :consumer_death -> Process.exit(consumer, :kill)
        :lease_kill -> Process.exit(lease, :kill)
        :reader_death -> Process.exit(reader, :kill)
      end

      assert_receive {:DOWN, ^reader_monitor, :process, ^reader, :killed}
      assert_receive {:DOWN, ^lease_monitor, :process, ^lease, _reason}
      refute Process.alive?(reader)
      send(reader, :release)
      refute_receive {:consumer_result, {:ok, _plaintext}}
    end
  end

  test "expiry and authority changes during a read fence its returned bytes", context do
    for change <- [:expiry, :authority] do
      lease = fresh_lease(context, block?: true)
      request = :gen_server.send_request(lease, {:read_document_chunk, 0})
      assert_receive {:fresh_reader, reader, {:chunk, 0}}

      case change do
        :expiry -> Agent.update(context.clock, &DateTime.add(&1, 61, :second))
        :authority -> Agent.update(context.authority, fn _ -> {:error, Error.new(:forbidden)} end)
      end

      send(reader, :release)
      assert {:reply, {:error, _reason}} = :gen_server.wait_response(request, 1_000)
      refute Process.alive?(lease)
      Agent.update(context.authority, fn _ -> :ok end)
    end
  end

  test "authority rejection before reading releases no source bytes", context do
    lease = fresh_lease(context)
    Agent.update(context.authority, fn _ -> {:error, Error.new(:forbidden)} end)
    assert {:error, %Error{code: :forbidden}} = DownloadLease.read_document_chunk(lease, 0)
    refute_received {:fresh_reader, _, _}
  end

  test "expiry before reading cancels the lease without storage access", context do
    lease = fresh_lease(context)
    Agent.update(context.clock, &DateTime.add(&1, 61, :second))
    assert {:error, :waiting_for_unlock} = DownloadLease.read_document_chunk(lease, 0)
    refute_received {:fresh_reader, _, _}
  end

  defp fresh_lease(context, opts \\ []) do
    reader_context = %{
      owner: self(),
      clock: context.clock,
      authority: context.authority,
      block?: Keyword.get(opts, :block?, false),
      result: Keyword.get(opts, :result, {:ok, "source"}),
      object_binding: %{plaintext_byte_size: Keyword.get(opts, :size, 6)}
    }

    start_supervised!(
      {DownloadLease,
       %{
         authorization: Authorization,
         binding: %{access: :worker, resource_version_id: "version", session_id: "session"},
         clock: Clock,
         context: reader_context,
         custodian: context.custodian,
         key_material: :binary.copy(<<1>>, 32),
         key_reader: Reader,
         mode: Keyword.get(opts, :mode, :document_worker_source),
         consumer_pid: Keyword.get(opts, :consumer, self())
       }},
      id: make_ref()
    )
  end

  defp consumer_loop do
    receive do
      {:read, lease, owner} ->
        send(owner, {:consumer_result, DownloadLease.read_document_chunk(lease, 0)})
        consumer_loop()
    end
  end

  defp empty(lease), do: apply(DownloadLease, :authenticate_empty_document_source, [lease])
end
