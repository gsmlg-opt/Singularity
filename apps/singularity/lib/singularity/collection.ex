defmodule Singularity.Collection do
  @moduledoc "Runs collections, tracks fetch runs and broadcasts their state."

  import Ecto.Query

  alias Singularity.Collection.{CollectSourceWorker, FetchRun}
  alias Singularity.Knowledge.ItemChange
  alias Singularity.Collector.Result
  alias Singularity.{Collector, Knowledge, Repo}
  alias Singularity.Sources.Source

  @topic "collection"

  def subscribe, do: Phoenix.PubSub.subscribe(Singularity.PubSub, @topic)

  @doc "Queues a collection in the queue of the source's collector (see `Collector.queue/1`)."
  def enqueue(source_id) when is_integer(source_id) do
    queue =
      with %Source{kind: kind} <- Repo.get(Source, source_id),
           {:ok, collector} <- Collector.fetch_module(kind) do
        Collector.queue(collector)
      else
        _unknown -> :collect
      end

    %{source_id: source_id} |> CollectSourceWorker.new(queue: queue) |> Styx.insert()
  end

  @spec run(Source.t(), DateTime.t()) ::
          {:ok, FetchRun.t()} | {:error, term(), FetchRun.t()} | {:error, :unavailable}
  def run(%Source{} = source, now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)

    case Collector.fetch_module(source.kind) do
      :error ->
        {:error, :unavailable}

      {:ok, collector} ->
        run = start_run!(source, now)
        outcome = collect(collector, source, now, run.id)
        run = finish_run!(run, outcome)

        case outcome do
          {:ok, _counts, _skipped} -> {:ok, run}
          {:error, reason} -> {:error, reason, run}
        end
    end
  end

  defp collect(collector, source, now, run_id) do
    case collector.fetch(source.config, now) do
      {:ok, %Result{entries: []}} -> {:error, :no_entries}
      {:ok, %Result{} = result} -> record(source, result, now, run_id)
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, {:exception, exception.__struct__}}
  end

  defp record(source, result, now, run_id) do
    case Knowledge.record(source, result, now, run_id) do
      {:ok, counts} -> {:ok, counts, result.skipped}
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
        {:ok, counts, skipped} ->
          [
            status: "ok",
            item_count: counts.count,
            skipped_count: skipped,
            added_count: counts.added,
            updated_count: counts.updated,
            removed_count: counts.removed
          ]

        {:error, reason} ->
          [status: "failed", error: format_error(reason)]
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

  @doc "The run with its source."
  @spec get_run!(integer()) :: FetchRun.t()
  def get_run!(id), do: FetchRun |> preload(:source) |> Repo.get!(id)

  @doc """
  The run's item changes, by change type then external id. Options: `:change`
  (`"added"`, `"updated"` or `"removed"`), `:page` (default 1) and `:per_page`
  (default 50).
  """
  @spec list_run_changes(integer(), keyword()) :: [ItemChange.t()]
  def list_run_changes(run_id, opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    per_page = Keyword.get(opts, :per_page, 50)

    run_id
    |> run_changes_query(opts[:change])
    |> order_by([c], asc: c.change, asc: c.external_id, asc: c.id)
    |> limit(^per_page)
    |> offset(^((page - 1) * per_page))
    |> Repo.all()
  end

  @doc "How many changes `list_run_changes/2` would list across all pages."
  @spec count_run_changes(integer(), keyword()) :: non_neg_integer()
  def count_run_changes(run_id, opts \\ []),
    do: run_id |> run_changes_query(opts[:change]) |> Repo.aggregate(:count)

  defp run_changes_query(run_id, change) when change in [nil, ""],
    do: where(ItemChange, fetch_run_id: ^run_id)

  defp run_changes_query(run_id, change),
    do: where(ItemChange, fetch_run_id: ^run_id, change: ^change)
end
