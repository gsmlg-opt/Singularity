defmodule Singularity.CollectionTest do
  use Singularity.DataCase, async: true
  use Styx.Testing, repo: Singularity.Repo

  import Singularity.Fixtures

  alias Singularity.Collection
  alias Singularity.Collection.{CollectSourceWorker, FetchRun, ScheduleWorker}
  alias Singularity.Collector.Result
  alias Singularity.Knowledge.Item
  alias Singularity.Repo

  @now ~U[2026-11-09 08:00:00Z]

  describe "run/2" do
    test "records entries, marks the run ok and broadcasts both transitions" do
      Collection.subscribe()
      source = source_fixture()

      assert {:ok, %FetchRun{status: "ok", item_count: 1, skipped_count: 0}} =
               Collection.run(source, @now)

      assert Repo.aggregate(Item, :count) == 1
      assert_receive {:fetch_run, %FetchRun{status: "running"}}
      assert_receive {:fetch_run, %FetchRun{status: "ok"}}
    end

    test "treats zero entries as a failure" do
      Process.put(:fake_collector_response, fn _c, _n ->
        {:ok, %Result{period: "p", entries: []}}
      end)

      assert {:error, :no_entries, %FetchRun{status: "failed", error: error}} =
               Collection.run(source_fixture(), @now)

      assert error =~ "no entries"
    end

    test "marks the run failed when the collector raises" do
      Process.put(:fake_collector_response, fn _c, _n -> raise "parser exploded" end)

      assert {:error, {:exception, RuntimeError}, %FetchRun{status: "failed", error: error}} =
               Collection.run(source_fixture(), @now)

      assert error =~ "RuntimeError"
    end

    test "records collector errors and skipped counts" do
      Process.put(:fake_collector_response, fn _c, _n -> {:error, {:http_status, 429}} end)

      assert {:error, _, %FetchRun{status: "failed", error: "HTTP 429"}} =
               Collection.run(source_fixture(), @now)

      Process.put(:fake_collector_response, fn _c, _n ->
        {:ok,
         %Result{period: "p", entries: [Singularity.Test.FakeCollector.entry("x", 1)], skipped: 2}}
      end)

      assert {:ok, %FetchRun{skipped_count: 2}} = Collection.run(source_fixture(), @now)
    end

    test "returns :unavailable without a run for unregistered kinds" do
      assert {:error, :unavailable} = Collection.run(source_fixture(kind: "gone"), @now)
      assert Repo.aggregate(FetchRun, :count) == 0
    end
  end

  describe "CollectSourceWorker" do
    test "collects an enabled source" do
      source = source_fixture()
      assert :ok = perform_job(CollectSourceWorker, %{source_id: source.id})
    end

    test "cancels for disabled or missing sources" do
      source = source_fixture(enabled: false)
      assert {:cancel, _} = perform_job(CollectSourceWorker, %{source_id: source.id})
      assert {:cancel, _} = perform_job(CollectSourceWorker, %{source_id: -1})
    end

    test "snoozes a rate limited collection" do
      Process.put(:fake_collector_response, fn _c, _n -> {:error, {:rate_limited, 120}} end)

      assert {:snooze, 120} =
               perform_job(CollectSourceWorker, %{source_id: source_fixture().id})
    end

    test "returns an error so Styx retries failed collections" do
      Process.put(:fake_collector_response, fn _c, _n -> {:error, :boom} end)
      assert {:error, :boom} = perform_job(CollectSourceWorker, %{source_id: source_fixture().id})
    end
  end

  test "enqueue/1 is unique per source while incomplete" do
    source = source_fixture()
    assert {:ok, _} = Collection.enqueue(source.id)
    assert {:ok, _} = Collection.enqueue(source.id)
    assert length(all_enqueued(worker: CollectSourceWorker)) == 1
  end

  test "enqueue/1 uses the queue of the source's collector" do
    fake = source_fixture()
    trending = source_fixture(kind: "github_trending", config: %{"since" => "daily"})
    stars = source_fixture(kind: "github_stars", config: %{"user" => "gsmlg"})

    for source <- [fake, trending, stars], do: {:ok, _job} = Collection.enqueue(source.id)

    assert_enqueued(worker: CollectSourceWorker, args: %{source_id: fake.id}, queue: :collect)

    assert_enqueued(
      worker: CollectSourceWorker,
      args: %{source_id: trending.id},
      queue: :github_web
    )

    assert_enqueued(worker: CollectSourceWorker, args: %{source_id: stars.id}, queue: :github_api)
  end

  test "ScheduleWorker enqueues due sources" do
    due = source_fixture(next_run_at: DateTime.add(now(), -60, :second))
    assert :ok = perform_job(ScheduleWorker, %{})
    assert_enqueued(worker: CollectSourceWorker, args: %{source_id: due.id})
  end

  test "latest_runs/0 and list_runs/2" do
    source = source_fixture()
    fetch_run_fixture(source, started_at: ~U[2026-11-09 07:00:00Z], status: "failed")
    newest = fetch_run_fixture(source, started_at: ~U[2026-11-09 08:00:00Z])

    assert %{} = runs = Collection.latest_runs()
    assert runs[source.id].id == newest.id
    assert [%{id: id}, _] = Collection.list_runs(source.id)
    assert id == newest.id
  end

  test "list_recent_runs/1 spans sources, newest first, with sources loaded" do
    a = source_fixture(name: "A")
    b = source_fixture(name: "B")
    fetch_run_fixture(a, started_at: ~U[2026-11-09 07:00:00Z])
    fetch_run_fixture(b, started_at: ~U[2026-11-09 08:00:00Z])

    assert [%FetchRun{source: %{name: "B"}}, %FetchRun{source: %{name: "A"}}] =
             Collection.list_recent_runs(10)

    assert [_newest] = Collection.list_recent_runs(1)
  end
end
