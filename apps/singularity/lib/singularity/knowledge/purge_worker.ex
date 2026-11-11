defmodule Singularity.Knowledge.PurgeWorker do
  @moduledoc "Runs daily; deletes the projects whose removal is due."

  use Styx.Worker, queue: :default, max_attempts: 3

  alias Singularity.Knowledge

  @impl Styx.Worker
  def perform(_job) do
    _count = Knowledge.purge_removed(DateTime.utc_now())
    :ok
  end
end
