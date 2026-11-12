defmodule Singularity.KnowledgeRecordTest do
  use Singularity.DataCase, async: true
  use Styx.Testing, repo: Singularity.Repo

  import Singularity.Fixtures

  alias Singularity.Collector.{Entry, Result}
  alias Singularity.Knowledge
  alias Singularity.Knowledge.{Address, FetchDetailsWorker, Item, Label, Observation}
  alias Singularity.Repo
  alias Singularity.Test.FakeCollector

  @t1 ~U[2026-11-09 08:00:00Z]
  @t2 ~U[2026-11-10 08:00:00Z]

  # Records within a fetch run; returns the item count.
  defp record(source, result, now) do
    run = fetch_run_fixture(source)
    with {:ok, %{count: count}} <- Knowledge.record(source, result, now, run.id), do: {:ok, count}
  end

  defp result(period, ids),
    do: %Result{
      period: period,
      entries: Enum.with_index(ids, 1) |> Enum.map(fn {id, r} -> FakeCollector.entry(id, r) end)
    }

  test "creates items and observations" do
    source = source_fixture()
    assert {:ok, 2} = record(source, result("2026-11-09", ["a", "b"]), @t1)

    assert Repo.aggregate(Item, :count) == 2
    obs = Repo.all(Observation)
    assert Enum.map(obs, & &1.period) == ["2026-11-09", "2026-11-09"]
    assert Enum.sort(Enum.map(obs, & &1.rank)) == [1, 2]
  end

  test "re-recording the same period is idempotent" do
    source = source_fixture()
    {:ok, _} = record(source, result("2026-11-09", ["a"]), @t1)
    {:ok, _} = record(source, result("2026-11-09", ["a"]), @t1)

    assert Repo.aggregate(Item, :count) == 1
    assert Repo.aggregate(Observation, :count) == 1
  end

  test "a new period appends an observation and updates last_seen_at only" do
    source = source_fixture()
    {:ok, _} = record(source, result("2026-11-09", ["a"]), @t1)
    {:ok, _} = record(source, result("2026-11-10", ["a"]), @t2)

    item = Repo.one!(Item)
    assert item.first_seen_at == @t1
    assert item.last_seen_at == @t2
    assert Repo.aggregate(Observation, :count) == 2
  end

  test "the same item from two sources is one item with two observations" do
    s1 = source_fixture()
    s2 = source_fixture(name: "Other")
    {:ok, _} = record(s1, result("2026-11-09", ["a"]), @t1)
    {:ok, _} = record(s2, result("2026-11-09", ["a"]), @t1)

    assert Repo.aggregate(Item, :count) == 1
    assert Repo.aggregate(Observation, :count) == 2
  end

  defp trending(owner_repo, rank, since) do
    {:ok, address} = Address.normalize(owner_repo)

    %Entry{
      item_kind: "software_project",
      external_id: address.external_id,
      title: owner_repo,
      url: address.url,
      summary: "From the trending page",
      rank: rank,
      item_attributes: %{"language" => "Rust", "stars" => 10},
      observation_attributes: %{"since" => since, "stars_in_period" => 3}
    }
  end

  test "a trending project gets a trending label and a queued details fetch" do
    {:ok, 1} =
      record(
        source_fixture(),
        %Result{period: "2026-11-09", entries: [trending("acme/rocket", 1, "weekly")]},
        @t1
      )

    item = Repo.one!(Item)
    assert item.kind == "software_project"
    assert item.summary == "From the trending page"
    assert [%Label{name: "trending:weekly", origin: "auto"}] = Repo.all(Label)
    assert_enqueued(worker: FetchDetailsWorker, args: %{item_id: item.id})
  end

  test "recording a known project keeps its GitHub details and skips fresh details" do
    project =
      project_fixture(
        title: "Acme/Rocket",
        external_id: "github.com/acme/rocket",
        summary: "From GitHub",
        attributes: %{"stars" => 999},
        details_fetched_at: @t2
      )

    {:ok, 1} =
      record(
        source_fixture(),
        %Result{period: "2026-11-10", entries: [trending("acme/rocket", 2, "daily")]},
        DateTime.add(@t2, 3600, :second)
      )

    item = Repo.get!(Item, project.id)

    assert {item.title, item.summary, item.attributes} ==
             {"Acme/Rocket", "From GitHub", %{"stars" => 999}}

    assert item.last_seen_at == DateTime.add(@t2, 3600, :second)
    refute_enqueued(worker: FetchDetailsWorker)
  end

  test "details older than a day are fetched again" do
    project = project_fixture(external_id: "github.com/acme/rocket", details_fetched_at: @t1)

    {:ok, 1} =
      record(
        source_fixture(),
        %Result{period: "2026-11-10", entries: [trending("acme/rocket", 1, "daily")]},
        DateTime.add(@t1, 25 * 3600, :second)
      )

    assert_enqueued(worker: FetchDetailsWorker, args: %{item_id: project.id})
  end

  test "items of other kinds get neither labels nor details fetches" do
    {:ok, _} = record(source_fixture(), result("2026-11-09", ["a"]), @t1)
    assert Repo.aggregate(Label, :count) == 0
    refute_enqueued(worker: FetchDetailsWorker)
  end
end
