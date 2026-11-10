defmodule SingularityWeb.OverviewLiveTest do
  use SingularityWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Singularity.Fixtures

  test "shows an empty knowledge base in English", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "Recently added"
    assert has_element?(view, "#recent-empty")
    assert has_element?(view, "#stat-projects", "0")
    assert has_element?(view, "#stat-last-run", "Never")
    assert has_element?(view, "#top-nav-overview[aria-current='page']")
    assert has_element?(view, "#section-menu-navigation[data-active-nav='overview-home']")
  end

  test "shows statistics, recently added projects and popular labels", %{conn: conn} do
    source = source_fixture(name: "Trending")
    source_fixture(name: "Paused", enabled: false)
    fetch_run_fixture(source, status: "ok", item_count: 25)

    old =
      project_fixture(
        title: "acme/old",
        first_seen_at: DateTime.add(now(), -10 * 86_400, :second)
      )

    new = project_fixture(title: "acme/new")
    label_fixture(old, "lang:rust")
    label_fixture(new, "lang:rust")

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#stat-projects", "2")
    assert has_element?(view, "#stat-week", "1")
    assert has_element?(view, "#stat-sources", "1")
    assert has_element?(view, "#stat-last-run", "OK")
    assert has_element?(view, "#recent-projects #project-#{new.id}", "acme/new")

    assert has_element?(
             view,
             "#label-cloud a[href='/knowledge?label=lang%3Arust']",
             "lang:rust · 2"
           )

    assert has_element?(view, "#view-all[href='/knowledge']")
  end

  test "updates when projects or runs change", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    project = project_fixture(title: "late/arrival")
    send(view.pid, {:project_updated, project.id})
    assert has_element?(view, "#recent-projects", "late/arrival")

    run = fetch_run_fixture(source_fixture(), status: "failed", error: "HTTP 500")
    send(view.pid, {:fetch_run, run})
    assert has_element?(view, "#stat-last-run", "Failed")
  end

  test "activity merges project additions and collection runs, newest first", %{conn: conn} do
    source = source_fixture(name: "Trending")
    trending = project_fixture(title: "acme/rocket", first_seen_at: ~U[2026-11-10 08:00:00Z])
    observation_fixture(trending, source, observed_at: ~U[2026-11-10 08:00:00Z])
    manual = project_fixture(title: "solo/tool", first_seen_at: ~U[2026-11-11 08:00:00Z])
    observation_fixture(manual, nil, observed_at: ~U[2026-11-11 08:00:00Z])

    run =
      fetch_run_fixture(source,
        status: "failed",
        item_count: 0,
        started_at: ~U[2026-11-10 09:00:00Z]
      )

    {:ok, view, html} = live(conn, ~p"/overview/activity")

    assert has_element?(view, "#addition-#{trending.id}", "Added from Trending")
    assert has_element?(view, "#addition-#{manual.id}", "Added manually")
    assert has_element?(view, "#run-#{run.id}", "Failed")
    assert :binary.match(html, "addition-#{manual.id}") < :binary.match(html, "run-#{run.id}")
    assert :binary.match(html, "run-#{run.id}") < :binary.match(html, "addition-#{trending.id}")
    assert has_element?(view, "#section-menu-navigation[data-active-nav='overview-activity']")
  end
end
