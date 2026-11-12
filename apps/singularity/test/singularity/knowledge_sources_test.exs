defmodule Singularity.KnowledgeSourcesTest do
  use Singularity.DataCase, async: true
  use Styx.Testing, repo: Singularity.Repo

  import Singularity.Fixtures

  alias Singularity.Collector.{Entry, Result}
  alias Singularity.Knowledge
  alias Singularity.Knowledge.{FetchDetailsWorker, Item, ItemSource, Observation}
  alias Singularity.Repo
  alias Singularity.Test.FakeCollector

  @t1 ~U[2026-11-09 08:00:00Z]
  @t2 ~U[2026-11-10 08:00:00Z]
  @t3 ~U[2026-11-11 08:00:00Z]

  # Records within a fetch run; returns the item count.
  defp record(source, result, now) do
    run = fetch_run_fixture(source)
    with {:ok, %{count: count}} <- Knowledge.record(source, result, now, run.id), do: {:ok, count}
  end

  defp list(ids, opts \\ []) do
    %Result{
      period: Keyword.get(opts, :period, "2026-11-09"),
      complete: Keyword.get(opts, :complete, true),
      skipped: Keyword.get(opts, :skipped, 0),
      entries: Enum.map(ids, &FakeCollector.entry(&1, nil))
    }
  end

  defp projects(names, opts \\ []) do
    result = list([], opts)

    entries =
      for name <- names,
          do: %Entry{
            item_kind: "software_project",
            external_id: "github.com/acme/" <> name,
            title: "acme/" <> name,
            url: "https://github.com/acme/" <> name
          }

    %{result | entries: entries}
  end

  defp item(external_id), do: Repo.get_by!(Item, external_id: external_id)

  defp item_source(external_id, source) do
    %{id: item_id} = item(external_id)

    ItemSource
    |> where(item_id: ^item_id)
    |> where([s], s.source_id == ^source.id)
    |> Repo.one!()
  end

  test "every recorded item is kept by its source" do
    source = source_fixture()
    {:ok, 2} = record(source, list(["a", "b"], complete: false), @t1)

    assert %ItemSource{added_at: @t1, removed_at: nil} = item_source("a", source)
    assert %ItemSource{added_at: @t1, removed_at: nil} = item_source("b", source)
  end

  test "an item a complete list no longer has leaves the source and is due for removal" do
    source = source_fixture()
    {:ok, _} = record(source, list(["a", "b"]), @t1)
    {:ok, _} = record(source, list(["a"]), @t2)

    assert %ItemSource{removed_at: @t2} = item_source("b", source)
    assert item("b").removal_due_at == DateTime.add(@t2, 30, :day)
    assert %ItemSource{removed_at: nil} = item_source("a", source)
    assert item("a").removal_due_at == nil
  end

  test "an incomplete list never makes items leave" do
    source = source_fixture()
    {:ok, _} = record(source, list(["a", "b"], complete: false), @t1)
    {:ok, _} = record(source, list(["a"], complete: false), @t2)

    assert %ItemSource{removed_at: nil} = item_source("b", source)
    assert item("b").removal_due_at == nil
  end

  test "a complete list with skipped entries does not make items leave" do
    source = source_fixture()
    {:ok, _} = record(source, list(["a", "b"]), @t1)
    {:ok, _} = record(source, list(["a"], skipped: 1), @t2)

    assert %ItemSource{removed_at: nil} = item_source("b", source)
    assert item("b").removal_due_at == nil
  end

  test "an item another source keeps is not due for removal" do
    stars = source_fixture(name: "Stars")
    trending = source_fixture(name: "Trending")
    {:ok, _} = record(trending, list(["a"], complete: false), @t1)
    {:ok, _} = record(stars, list(["a", "b"]), @t1)
    {:ok, _} = record(stars, list(["b"]), @t2)

    assert %ItemSource{removed_at: @t2} = item_source("a", stars)
    assert %ItemSource{removed_at: nil} = item_source("a", trending)
    assert item("a").removal_due_at == nil
  end

  test "an item added by hand is not due for removal when a list drops it" do
    stars = source_fixture(name: "Stars")
    {:ok, project} = Knowledge.add_project(%{"name" => "Kept", "address" => "acme/kept"}, @t1)
    {:ok, _} = record(stars, projects(["kept"]), @t1)
    {:ok, _} = record(stars, projects(["other"]), @t2)

    assert Repo.reload!(project).removal_due_at == nil

    assert [%ItemSource{source_id: nil, removed_at: nil}, %ItemSource{removed_at: @t2} = left] =
             Knowledge.list_item_sources(project.id)

    assert left.source.id == stars.id
  end

  test "being listed again calls off the removal and keeps the first added_at" do
    source = source_fixture()
    {:ok, _} = record(source, list(["a", "b"]), @t1)
    {:ok, _} = record(source, list(["a"]), @t2)
    {:ok, _} = record(source, list(["a", "b"]), @t3)

    assert %ItemSource{added_at: @t1, removed_at: nil} = item_source("b", source)
    assert item("b").removal_due_at == nil
  end

  test "adding a project due for removal by hand calls off the removal" do
    source = source_fixture()
    {:ok, _} = record(source, projects(["x", "b"]), @t1)
    {:ok, _} = record(source, projects(["b"]), @t2)
    assert item("github.com/acme/x").removal_due_at

    {:existing, _} = Knowledge.add_project(%{"name" => "x", "address" => "acme/x"}, @t3)

    assert item("github.com/acme/x").removal_due_at == nil
  end

  test "an entry's period overrides the result's for its observation" do
    source = source_fixture()
    entry = %{FakeCollector.entry("a", nil) | period: "2024-01-02"}
    result = %Result{period: "2026-11-09", entries: [entry, FakeCollector.entry("b", nil)]}
    {:ok, 2} = record(source, result, @t1)

    periods = Observation |> select([o], o.period) |> order_by(:id) |> Repo.all()
    assert periods == ["2024-01-02", "2026-11-09"]
  end

  test "entries carrying details store them and queue no fetch" do
    source = source_fixture()

    details = %{
      title: "Acme/Rocket",
      summary: "Goes up",
      attributes: %{"stars" => 7, "language" => "Elixir", "topics" => ["space"]}
    }

    entry = %Entry{
      item_kind: "software_project",
      external_id: "github.com/acme/rocket",
      title: "acme/rocket",
      url: "https://github.com/acme/rocket",
      details: details
    }

    {:ok, 1} = record(source, %Result{period: "p", entries: [entry]}, @t1)

    project = Knowledge.get_project!(item("github.com/acme/rocket").id)
    assert project.title == "Acme/Rocket"
    assert project.summary == "Goes up"
    assert project.attributes["stars"] == 7
    assert project.details_fetched_at == @t1
    assert Enum.map(project.labels, & &1.name) == ["lang:elixir", "topic:space"]
    refute_enqueued(worker: FetchDetailsWorker)
  end

  test "purge_removed deletes only the projects whose removal is due" do
    due = project_fixture(removal_due_at: @t2)
    later = project_fixture(removal_due_at: @t3)
    kept = project_fixture()
    label_fixture(due, "lang:x")
    observation_fixture(due, nil)

    assert Knowledge.purge_removed(@t2) == 1
    refute Repo.get(Item, due.id)
    assert Repo.get(Item, later.id)
    assert Repo.get(Item, kept.id)
  end

  test "one row per item and source, however often it is recorded" do
    source = source_fixture()
    {:ok, _} = record(source, list(["a"], period: "1"), @t1)
    {:ok, _} = record(source, list(["a"], period: "2"), @t2)

    assert Repo.aggregate(ItemSource, :count) == 1
  end

  test "purges via the worker" do
    project_fixture(removal_due_at: ~U[2000-01-01 00:00:00Z])
    assert :ok = perform_job(Singularity.Knowledge.PurgeWorker, %{})
    assert Repo.aggregate(Item, :count) == 0
  end
end
