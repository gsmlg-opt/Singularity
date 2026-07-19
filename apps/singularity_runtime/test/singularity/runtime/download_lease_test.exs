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
