defmodule Singularity.Collection do
  @moduledoc "Runs collections, tracks fetch runs and broadcasts their state."

  import Ecto.Query

  alias Singularity.Collection.{CollectSourceWorker, FetchRun}
  alias Singularity.Collector.Result
  alias Singularity.{Collector, Knowledge, Repo}
  alias Singularity.Sources.Source

  @topic "collection"

  def subscribe, do: Phoenix.PubSub.subscribe(Singularity.PubSub, @topic)

  def enqueue(source_id) when is_integer(source_id),
    do: %{source_id: source_id} |> CollectSourceWorker.new() |> Styx.insert()

  @spec run(Source.t(), DateTime.t()) ::
          {:ok, FetchRun.t()} | {:error, term(), FetchRun.t()} | {:error, :unavailable}
  def run(%Source{} = source, now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)

    case Collector.fetch_module(source.kind) do
      :error ->
        {:error, :unavailable}

      {:ok, collector} ->
        run = start_run!(source, now)
        outcome = collect(collector, source, now)
        run = finish_run!(run, outcome)

        case outcome do
          {:ok, _count, _skipped} -> {:ok, run}
          {:error, reason} -> {:error, reason, run}
        end
    end
  end

  defp collect(collector, source, now) do
    case collector.fetch(source.config, now) do
      {:ok, %Result{entries: []}} -> {:error, :no_entries}
      {:ok, %Result{} = result} -> record(source, result, now)
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, {:exception, exception.__struct__}}
  end

  defp record(source, result, now) do
    case Knowledge.record(source, result, now) do
      {:ok, count} -> {:ok, count, result.skipped}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_run!(source, now) do
    %FetchRun{source_id: source.id, status: "running", started_at: now}
    |> Repo.insert!()
    |> broadcast()
  end

  defp finish_run!(run, outcome) do
    changes =
      case outcome do
        {:ok, count, skipped} -> [status: "ok", item_count: count, skipped_count: skipped]
        {:error, reason} -> [status: "failed", error: format_error(reason)]
      end

    run
    |> Ecto.Changeset.change(
      [finished_at: DateTime.utc_now() |> DateTime.truncate(:second)] ++ changes
    )
    |> Repo.update!()
    |> broadcast()
  end

  defp broadcast(%FetchRun{} = run) do
    Phoenix.PubSub.broadcast(Singularity.PubSub, @topic, {:fetch_run, run})
    run
  end

  def format_error(:no_entries), do: "no entries parsed (page structure may have changed)"
  def format_error({:http_status, status}), do: "HTTP #{status}"

  def format_error({:transport, message}) when is_binary(message),
    do: "transport error: " <> String.slice(message, 0, 300)

  def format_error(other), do: other |> inspect() |> String.slice(0, 300)

  def list_runs(source_id, limit \\ 20) do
    FetchRun
    |> where(source_id: ^source_id)
    |> order_by(desc: :started_at, desc: :id)
    |> limit(^limit)
    |> Repo.all()
  end

  def latest_runs do
    FetchRun
    |> distinct([r], r.source_id)
    |> order_by([r], asc: r.source_id, desc: r.started_at, desc: r.id)
    |> Repo.all()
    |> Map.new(&{&1.source_id, &1})
  end

  @doc "The most recent runs across all sources, newest first, with sources preloaded."
  def list_recent_runs(limit \\ 50) do
    FetchRun
    |> order_by(desc: :started_at, desc: :id)
    |> limit(^limit)
    |> preload(:source)
    |> Repo.all()
  end
end
