defmodule Singularity.Knowledge.ReadmeRefreshWorker do
  @moduledoc "Runs hourly; queues README fetches for GitHub projects missing or stale ones."

  use Styx.Worker, queue: :default, max_attempts: 1

  alias Singularity.Knowledge

  @batch 500

  @impl Styx.Worker
  def perform(_job) do
    _queued = Knowledge.enqueue_stale_readmes(DateTime.utc_now(), @batch)
    :ok
  end
end
