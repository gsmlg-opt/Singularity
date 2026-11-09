defmodule SingularityWeb.SourceLiveTest do
  use SingularityWeb.ConnCase, async: true
  use Styx.Testing, repo: Singularity.Repo

  import Phoenix.LiveViewTest
  import Singularity.Fixtures

  alias Singularity.Collection.{CollectSourceWorker, FetchRun}
  alias Singularity.Sources

  describe "index" do
    test "lists sources with type and latest run status", %{conn: conn} do
      source = source_fixture(name: "My fake")
      fetch_run_fixture(source, status: "failed", error: "HTTP 500")

      {:ok, _view, html} = live(conn, ~p"/sources")
      assert html =~ "My fake"
      assert html =~ "Fake"
      assert html =~ "failed"
    end

    test "collect now enqueues a job", %{conn: conn} do
      source = source_fixture()
      {:ok, view, _html} = live(conn, ~p"/sources")

      view |> element("#collect-#{source.id}") |> render_click()
      assert_enqueued(worker: CollectSourceWorker, args: %{source_id: source.id})
    end

    test "toggle and delete", %{conn: conn} do
      source = source_fixture()
      {:ok, view, _html} = live(conn, ~p"/sources")

      view |> element("#toggle-#{source.id}") |> render_click()
      refute Sources.get_source!(source.id).enabled

      view |> element("#delete-#{source.id}") |> render_click()
      assert Sources.get_source(source.id) == nil
    end
  end

  describe "form" do
    test "new: choose a type, then fill type-specific fields", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/sources/new")
      assert html =~ "GitHub Trending"
      assert html =~ "Fake"

      {:ok, view, html} = live(conn, ~p"/sources/new?kind=fake")
      assert html =~ "Topic"

      html =
        view
        |> form("#source-form", source: %{name: "N", config: %{topic: ""}})
        |> render_submit()

      assert html =~ "topic can&#39;t be blank"

      view
      |> form("#source-form", source: %{name: "N", config: %{topic: "x"}})
      |> render_submit()

      [source] = Sources.list_sources()
      assert source.config == %{"topic" => "x"}
      assert_redirect(view, ~p"/sources/#{source.id}")
    end

    test "edit updates the source", %{conn: conn} do
      source = source_fixture()
      {:ok, view, _html} = live(conn, ~p"/sources/#{source.id}/edit")

      view |> form("#source-form", source: %{name: "Renamed"}) |> render_submit()
      assert Sources.get_source!(source.id).name == "Renamed"
    end
  end

  describe "show" do
    test "lists runs and refreshes on broadcasts", %{conn: conn} do
      source = source_fixture()
      fetch_run_fixture(source, status: "failed", error: "HTTP 429")

      {:ok, view, html} = live(conn, ~p"/sources/#{source.id}")
      assert html =~ "HTTP 429"

      fetch_run_fixture(source,
        status: "ok",
        item_count: 25,
        started_at: DateTime.add(now(), 60, :second)
      )

      send(view.pid, {:fetch_run, %FetchRun{source_id: source.id, status: "ok"}})
      assert render(view) =~ "25"
    end
  end
end
