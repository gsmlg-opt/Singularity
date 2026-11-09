defmodule Singularity.Collection.ScheduleWorker do
  @moduledoc "Runs every minute; enqueues a collection for each due source."

  use Styx.Worker, queue: :default, max_attempts: 1

  alias Singularity.{Collection, Sources}

  @impl Styx.Worker
  def perform(_job) do
    DateTime.utc_now()
    |> Sources.claim_due_sources()
    |> Enum.each(fn source -> {:ok, _job} = Collection.enqueue(source.id) end)
  end
end
