defmodule SingularityWeb.ItemLiveTest do
  use SingularityWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Singularity.Fixtures

  alias Singularity.Collection.FetchRun
  alias Singularity.Collector.{Entry, Result}
  alias Singularity.Knowledge
  alias Singularity.Test.FakeCollector

  defp gh_entry(id, rank) do
    %Entry{
      item_kind: "github_repo",
      external_id: id,
      title: id,
      url: "https://github.com/" <> id,
      summary: "About " <> id,
      rank: rank,
      item_attributes: %{"language" => "Elixir", "stars" => 1200, "forks" => 3},
      observation_attributes: %{"stars" => 1200, "stars_in_period" => 45, "since" => "daily"}
    }
  end

  defp record!(source, period, at, entries),
    do: {:ok, _} = Knowledge.record(source, %Result{period: period, entries: entries}, at)

  test "shows an empty state", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "还没有采集到条目"
  end

  test "lists recently observed items with kind-specific meta", %{conn: conn} do
    record!(source_fixture(), "2026-11-09", ~U[2026-11-09 08:00:00Z], [gh_entry("acme/rocket", 1)])

    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "acme/rocket"
    assert html =~ "About acme/rocket"
    assert html =~ "Elixir · ★ 1,200"
  end

  test "falls back to the generic display for kinds without a component", %{conn: conn} do
    record!(source_fixture(), "p", ~U[2026-11-09 08:00:00Z], [FakeCollector.entry("plain", 1)])

    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Item plain"
  end

  test "a selected source shows its latest period ranked", %{conn: conn} do
    source = source_fixture()
    record!(source, "2026-11-09", ~U[2026-11-09 08:00:00Z], [gh_entry("old/one", 1)])

    record!(source, "2026-11-10", ~U[2026-11-10 08:00:00Z], [
      gh_entry("new/b", 2),
      gh_entry("new/a", 1)
    ])

    {:ok, _view, html} = live(conn, ~p"/?source_id=#{source.id}")
    assert html =~ "2026-11-10"
    refute html =~ "old/one"
    assert :binary.match(html, "new/a") < :binary.match(html, "new/b")
  end

  test "changing filters patches the URL", %{conn: conn} do
    source = source_fixture()
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#item-filters")
    |> render_change(%{"filters" => %{"source_id" => to_string(source.id), "kind" => ""}})

    assert_patch(view, ~p"/?source_id=#{source.id}")
  end

  test "reloads when a fetch run completes", %{conn: conn} do
    source = source_fixture()
    {:ok, view, _html} = live(conn, ~p"/")

    record!(source, "p", ~U[2026-11-09 08:00:00Z], [gh_entry("late/arrival", 1)])
    send(view.pid, {:fetch_run, %FetchRun{status: "ok", source_id: source.id}})

    assert render(view) =~ "late/arrival"
  end

  test "item detail shows the observation history", %{conn: conn} do
    source = source_fixture()
    record!(source, "2026-11-09", ~U[2026-11-09 08:00:00Z], [gh_entry("acme/rocket", 3)])
    [%{item: item}] = Knowledge.list_items()

    {:ok, _view, html} = live(conn, ~p"/items/#{item.id}")
    assert html =~ "https://github.com/acme/rocket"
    assert html =~ "2026-11-09"
    assert html =~ "Fake source"
    assert html =~ "+45"
  end
end
