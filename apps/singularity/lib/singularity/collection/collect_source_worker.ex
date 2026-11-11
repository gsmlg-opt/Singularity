defmodule Singularity.Collection.CollectSourceWorker do
  # The queue is chosen per source type when enqueued (`Collection.enqueue/1`).
  use Styx.Worker,
    queue: :collect,
    max_attempts: 3,
    unique: [keys: [:source_id], states: :incomplete, period: :infinity]

  alias Singularity.{Collection, Sources}

  @impl Styx.Worker
  def perform(%Styx.Job{args: %{"source_id" => source_id}}) do
    case Sources.get_source(source_id) do
      %{enabled: true} = source ->
        case Collection.run(source) do
          {:ok, _run} -> :ok
          {:error, :unavailable} -> {:cancel, :source_type_unavailable}
          {:error, {:rate_limited, seconds}, _run} -> {:snooze, seconds}
          {:error, reason, _run} -> {:error, reason}
        end

      _missing_or_disabled ->
        {:cancel, :source_unavailable}
    end
  end
end
