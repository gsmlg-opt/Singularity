defmodule Singularity.Runtime.KeyLeaseSupervisor do
  @moduledoc "Supervises short-lived, independently revocable key leases."

  use DynamicSupervisor

  alias Singularity.Runtime.DownloadLease
  alias Singularity.Runtime.KeyLease

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options) do
    DynamicSupervisor.start_link(__MODULE__, options)
  end

  @spec start_lease(Supervisor.supervisor(), map()) ::
          DynamicSupervisor.on_start_child()
  def start_lease(supervisor, options) do
    DynamicSupervisor.start_child(supervisor, {KeyLease, options})
  end

  @spec start_download_lease(Supervisor.supervisor(), map()) ::
          DynamicSupervisor.on_start_child()
  def start_download_lease(supervisor, options) do
    DynamicSupervisor.start_child(supervisor, {DownloadLease, options})
  end

  @impl true
  def init(_options) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
