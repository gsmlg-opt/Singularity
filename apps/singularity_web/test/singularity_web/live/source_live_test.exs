defmodule SingularityWeb.SourceLiveTest do
  use SingularityWeb.ConnCase, async: true
  use Styx.Testing, repo: Singularity.Repo

  import Phoenix.LiveViewTest
  import Singularity.Fixtures

  alias Singularity.{Knowledge, Sources}
  alias Singularity.Collection.{CollectSourceWorker, FetchRun}
  alias Singularity.Knowledge.FetchDetailsWorker

  describe "index" do
    test "lists sources with type and latest run status", %{conn: conn} do
      source = source_fixture(name: "My fake")
      fetch_run_fixture(source, status: "failed", error: "HTTP 500")

      {:ok, view, html} = live(conn, ~p"/source/sources")
      assert html =~ "My fake"
      assert html =~ "Fake"
      assert html =~ "Failed"
      assert has_element?(view, "#top-nav-source[aria-current='page']")
      assert has_element?(view, "#section-menu-navigation[data-active-nav='source-sources']")
    end

    test "reports unavailable source types", %{conn: conn} do
      source_fixture(kind: "gone")
      {:ok, _view, html} = live(conn, ~p"/source/sources")
      assert html =~ "Unavailable (gone)"
    end

    test "collect now enqueues a job", %{conn: conn} do
      source = source_fixture()
      {:ok, view, _html} = live(conn, ~p"/source/sources")

      view |> element("#collect-#{source.id}") |> render_click()
      assert_enqueued(worker: CollectSourceWorker, args: %{source_id: source.id})
    end

    test "row actions are icon buttons titled with their names", %{conn: conn} do
      source = source_fixture()
      {:ok, view, _html} = live(conn, ~p"/source/sources")

      for {id, title} <- [
            {"collect", "Collect now"},
            {"toggle", "Disable"},
            {"edit", "Edit"},
            {"delete", "Delete"}
          ] do
        assert has_element?(view, "##{id}-#{source.id}[title='#{title}'][aria-label='#{title}']")
        refute has_element?(view, "##{id}-#{source.id}", title)
      end

      assert has_element?(view, "#edit-#{source.id}[href='/source/sources/#{source.id}/edit']")
    end

    test "toggle and delete", %{conn: conn} do
      source = source_fixture()
      {:ok, view, _html} = live(conn, ~p"/source/sources")

      view |> element("#toggle-#{source.id}") |> render_click()
      refute Sources.get_source!(source.id).enabled

      view |> element("#delete-#{source.id}") |> render_click()
      assert Sources.get_source(source.id) == nil
    end
  end

  describe "form" do
    test "new: choose a type, then fill type-specific fields", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/source/sources/new")
      assert html =~ "GitHub Trending"
      assert html =~ "Fake"

      {:ok, view, html} = live(conn, ~p"/source/sources/new?kind=fake")
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
      assert_redirect(view, ~p"/source/sources/#{source.id}")
    end

    test "edit updates the source", %{conn: conn} do
      source = source_fixture()
      {:ok, view, _html} = live(conn, ~p"/source/sources/#{source.id}/edit")

      view |> form("#source-form", source: %{name: "Renamed"}) |> render_submit()
      assert Sources.get_source!(source.id).name == "Renamed"
    end
  end

  describe "show" do
    test "lists runs and refreshes on broadcasts", %{conn: conn} do
      source = source_fixture()
      fetch_run_fixture(source, status: "failed", error: "HTTP 429")

      {:ok, view, html} = live(conn, ~p"/source/sources/#{source.id}")
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

  describe "manual" do
    test "lists hand-added projects and adds one in a modal", %{conn: conn} do
      {:ok, existing} =
        Knowledge.add_project(%{
          "name" => "Inkscape",
          "address" => "gitlab.com/inkscape/inkscape"
        })

      {:ok, view, _html} = live(conn, ~p"/source/manual")
      assert has_element?(view, "#section-menu-navigation[data-active-nav='source-manual']")
      assert has_element?(view, "#manual-project-#{existing.id}", "Inkscape")
      assert has_element?(view, "#manual-project-#{existing.id}", "gitlab.com")
      assert has_element?(view, "#manual-project-#{existing.id}", "No automatic details")

      assert has_element?(
               view,
               "#open-add-project[command='show-modal'][commandfor='add-project-modal']"
             )

      view
      |> form("#add-project-form",
        project: %{name: "Elixir", address: "https://github.com/elixir-lang/elixir"}
      )
      |> render_submit()

      project = Enum.find(Knowledge.list_projects(), &(&1.title == "Elixir"))
      {path, flash} = assert_redirect(view)
      assert path == ~p"/knowledge/projects/#{project.id}"
      assert flash["info"] =~ "fetching its details"
      assert_enqueued(worker: FetchDetailsWorker, args: %{item_id: project.id})
    end

    test "adds a project from any git host", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/source/manual")

      view
      |> form("#add-project-form",
        project: %{name: "Tool", address: "git@git.example.com:team/tool.git"}
      )
      |> render_submit()

      [project] = Knowledge.list_projects()
      assert project.external_id == "git.example.com/team/tool"
      {_path, flash} = assert_redirect(view)
      assert flash["info"] == "Project added"
    end

    test "opens a known project with a notice", %{conn: conn} do
      {:ok, project} =
        Knowledge.add_project(%{"name" => "Elixir", "address" => "elixir-lang/elixir"})

      {:ok, view, _html} = live(conn, ~p"/source/manual")

      view
      |> form("#add-project-form",
        project: %{name: "Again", address: "git@github.com:elixir-lang/elixir.git"}
      )
      |> render_submit()

      {path, flash} = assert_redirect(view)
      assert path == ~p"/knowledge/projects/#{project.id}"
      assert flash["info"] == "Already in the knowledge base"
    end

    test "keeps the modal form with errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/source/manual")
      assert has_element?(view, "#manual-empty")

      html =
        view
        |> form("#add-project-form", project: %{name: "", address: "not an address"})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert html =~ "is not a repository address"
      assert has_element?(view, "dialog#add-project-modal #add-project-form")
      assert Knowledge.list_projects() == []
    end
  end

  describe "runs" do
    test "lists recent runs across sources", %{conn: conn} do
      fetch_run_fixture(source_fixture(name: "Daily"), status: "failed", error: "HTTP 500")
      fetch_run_fixture(source_fixture(name: "Weekly"), status: "ok", item_count: 25)

      {:ok, view, html} = live(conn, ~p"/source/runs")
      assert html =~ "Daily"
      assert html =~ "Weekly"
      assert has_element?(view, "#runs", "HTTP 500")
      assert has_element?(view, "#runs", "25")
      assert has_element?(view, "#section-menu-navigation[data-active-nav='source-runs']")
    end
  end
end
