defmodule SingularityWeb.KnowledgeLiveTest do
  use SingularityWeb.ConnCase, async: true
  use Styx.Testing, repo: Singularity.Repo

  import Phoenix.LiveViewTest
  import Singularity.Fixtures

  alias Singularity.Knowledge
  alias Singularity.Knowledge.FetchDetailsWorker

  describe "index" do
    setup do
      rocket =
        project_fixture(
          title: "acme/rocket",
          summary: "A fast rocket engine",
          attributes: %{"stars" => 12_345, "language" => "Rust"},
          details_fetched_at: now(),
          first_seen_at: DateTime.add(now(), -60, :second)
        )

      tool = project_fixture(title: "solo/tool", details_error: "repository not found")
      label_fixture(rocket, "lang:rust")
      label_fixture(rocket, "favorite", "manual")
      %{rocket: rocket, tool: tool}
    end

    test "shows project cards with stars, language, labels and details state", %{
      conn: conn,
      rocket: rocket
    } do
      {:ok, view, html} = live(conn, ~p"/knowledge")
      card = "#project-#{rocket.id}"

      assert html =~ "Software projects"

      assert has_element?(
               view,
               "#{card} a[href='/knowledge/projects/#{rocket.id}']",
               "acme/rocket"
             )

      assert has_element?(view, card, "A fast rocket engine")
      assert has_element?(view, card, "12,345")
      assert has_element?(view, card, "Rust")
      assert has_element?(view, "#{card} [data-origin='manual']", "favorite")
      assert has_element?(view, "#{card} [data-origin='auto']", "lang:rust")
      assert has_element?(view, "#projects [data-role='details-status']", "Details failed")
    end

    test "uses the Knowledge section menu with browse items only", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/knowledge")

      assert has_element?(view, "#top-nav-knowledge[aria-current='page']")
      assert has_element?(view, "#section-menu-navigation[data-active-nav='knowledge-all']")
      assert has_element?(view, "#section-menu a[href='/knowledge']", "All knowledge")

      assert has_element?(
               view,
               "#section-menu a[href='/knowledge/projects']",
               "Software projects"
             )

      refute has_element?(view, "#section-menu a[href^='/knowledge?label=']")

      {:ok, view, _html} = live(conn, ~p"/knowledge/projects")
      assert has_element?(view, "#section-menu-navigation[data-active-nav='knowledge-projects']")
    end

    test "filters by label and clears the filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/knowledge?label=favorite")

      assert has_element?(view, "#active-label", "favorite")
      assert has_element?(view, "#projects", "acme/rocket")
      refute has_element?(view, "#projects", "solo/tool")

      view |> element("#clear-label") |> render_click()
      assert_patch(view, ~p"/knowledge")
      assert has_element?(view, "#projects", "solo/tool")
    end

    test "searches and sorts through the toolbar", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/knowledge")

      view
      |> element("#project-filters")
      |> render_change(%{"filters" => %{"q" => "rocket", "sort" => "stars"}})

      assert_patch(view, ~p"/knowledge?q=rocket&sort=stars")
      assert has_element?(view, "#projects", "acme/rocket")
      refute has_element?(view, "#projects", "solo/tool")
    end

    test "reloads when a project is updated", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/knowledge")
      late = project_fixture(title: "late/arrival")
      send(view.pid, {:project_updated, late.id})
      assert has_element?(view, "#projects", "late/arrival")
    end
  end

  describe "show" do
    setup do
      source = source_fixture(name: "Trending daily")

      project =
        project_fixture(
          title: "elixir-lang/elixir",
          summary: "Simple from zero to scale",
          attributes: %{
            "stars" => 26_710,
            "forks" => 3_717,
            "language" => "Elixir",
            "license" => "Apache-2.0",
            "homepage" => "https://elixir-lang.org/",
            "archived" => false,
            "created_at" => "2011-01-09T08:43:57Z",
            "pushed_at" => "2026-11-10T15:13:02Z"
          },
          details_fetched_at: now()
        )

      observation_fixture(project, source,
        period: "2026-11-09",
        rank: 3,
        observed_at: ~U[2026-11-09 08:00:00Z],
        attributes: %{"since" => "daily", "stars_in_period" => 45}
      )

      observation_fixture(project, nil,
        period: "2026-11-10",
        observed_at: ~U[2026-11-10 08:00:00Z],
        attributes: %{"via" => "manual"}
      )

      label_fixture(project, "lang:elixir")
      label_fixture(project, "mine", "manual")
      %{project: project}
    end

    test "shows GitHub details and source records", %{conn: conn, project: project} do
      {:ok, view, html} = live(conn, ~p"/knowledge/projects/#{project.id}")

      assert html =~ "Simple from zero to scale"
      assert has_element?(view, "#project-facts", "26,710")
      assert has_element?(view, "#project-facts", "Apache-2.0")
      assert has_element?(view, "#github-details", "2011-01-09")
      assert has_element?(view, "#project-facts a[href='https://elixir-lang.org/']")
      assert has_element?(view, "#project-facts a[href='https://github.com/elixir-lang/elixir']")
      assert has_element?(view, "#observations", "Trending daily")
      assert has_element?(view, "#observations", "Added manually")
      assert has_element?(view, "#observations", "45")
      assert has_element?(view, "#section-menu-navigation[data-active-nav='knowledge-projects']")
    end

    test "adds and removes manual labels; automatic labels are read-only", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/knowledge/projects/#{project.id}")

      view |> form("#label-form", label: %{name: "Favorite"}) |> render_submit()
      assert has_element?(view, "#project-labels [data-origin='manual']", "favorite")

      labels = Knowledge.get_project!(project.id).labels
      mine = Enum.find(labels, &(&1.name == "mine"))
      auto = Enum.find(labels, &(&1.name == "lang:elixir"))

      view |> element("#remove-label-#{mine.id}") |> render_click()
      refute has_element?(view, "#project-labels", "mine")
      refute has_element?(view, "#remove-label-#{auto.id}")
      assert has_element?(view, "#project-labels [data-origin='auto']", "lang:elixir")
    end

    test "shows label validation errors", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/knowledge/projects/#{project.id}")
      html = view |> form("#label-form", label: %{name: " "}) |> render_submit()
      assert html =~ "can&#39;t be blank"
    end

    test "a project on another host shows its repository instead of GitHub details", %{
      conn: conn
    } do
      {:ok, project} =
        Knowledge.add_project(%{
          "name" => "Tool",
          "address" => "git@git.example.com:team/tool.git"
        })

      {:ok, view, _html} = live(conn, ~p"/knowledge/projects/#{project.id}")
      assert has_element?(view, "#repository", "git.example.com")
      assert has_element?(view, "#repository code", "git@git.example.com:team/tool.git")
      assert has_element?(view, "[data-role='details-status']", "No automatic details")
      refute has_element?(view, "#github-details")
      refute has_element?(view, "#refetch")
    end

    test "fetch again queues a details fetch", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/knowledge/projects/#{project.id}")
      view |> element("#refetch") |> render_click()
      assert_enqueued(worker: FetchDetailsWorker, args: %{item_id: project.id})
    end

    test "reloads when its project is updated", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/knowledge/projects/#{project.id}")

      {:ok, _project} =
        Knowledge.put_details(
          project,
          %{title: "elixir-lang/elixir", summary: "Updated summary", attributes: %{}},
          now()
        )

      send(view.pid, {:project_updated, project.id})
      assert render(view) =~ "Updated summary"
    end
  end

  describe "sources and removal" do
    setup do
      stars = source_fixture(name: "GitHub Stars · gsmlg")
      project = project_fixture(title: "acme/leaving", removal_due_at: ~U[2026-12-10 08:00:00Z])

      Singularity.Repo.insert!(%Singularity.Knowledge.ItemSource{
        item_id: project.id,
        source_id: stars.id,
        added_at: ~U[2026-11-01 08:00:00Z],
        removed_at: ~U[2026-11-10 08:00:00Z]
      })

      Singularity.Repo.insert!(%Singularity.Knowledge.ItemSource{
        item_id: project_fixture(title: "acme/kept").id,
        source_id: nil,
        added_at: ~U[2026-11-01 08:00:00Z]
      })

      %{project: project, stars: stars}
    end

    test "the project page shows how it was added and when it will be removed", %{
      conn: conn,
      project: project,
      stars: stars
    } do
      {:ok, view, _html} = live(conn, ~p"/knowledge/projects/#{project.id}")

      assert has_element?(view, "#item-sources a[href='/source/sources/#{stars.id}']", "gsmlg")
      assert has_element?(view, "#item-sources", "2026-11-01 08:00 UTC")
      assert has_element?(view, "#item-sources", "Left on 2026-11-10")
      assert has_element?(view, "#removal-notice", "removed on 2026-12-10")
    end

    test "a project added by hand shows as active", %{conn: conn} do
      kept = Knowledge.list_projects(q: "acme/kept") |> hd()
      {:ok, view, _html} = live(conn, ~p"/knowledge/projects/#{kept.id}")

      assert has_element?(view, "#item-sources", "Added manually")
      assert has_element?(view, "#item-sources", "Active")
      refute has_element?(view, "#removal-notice")
    end

    test "lists flag projects due for removal", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/knowledge")

      assert has_element?(
               view,
               "#project-#{project.id} [data-role='removal-status']",
               "Removal on 2026-12-10"
             )
    end
  end

  describe "README, instruction and deprecation" do
    test "renders the README sanitized and shows the README states", %{conn: conn} do
      with_readme =
        project_fixture(
          readme: "# Rocket\n\nGoes **up**.<script>alert(1)</script>",
          readme_fetched_at: now()
        )

      {:ok, view, _html} = live(conn, ~p"/knowledge/projects/#{with_readme.id}")
      assert has_element?(view, "#readme-body h1", "Rocket")
      assert has_element?(view, "#readme-body strong", "up")
      refute render(view) =~ "alert(1)"

      none = project_fixture(readme_fetched_at: now())
      {:ok, view, _html} = live(conn, ~p"/knowledge/projects/#{none.id}")
      assert has_element?(view, "#readme-state", "This repository has no README.")

      pending = project_fixture()
      {:ok, view, _html} = live(conn, ~p"/knowledge/projects/#{pending.id}")
      assert has_element?(view, "#readme-state", "README not fetched yet.")

      off_github = project_fixture(external_id: "gitlab.com/a/b", url: "https://gitlab.com/a/b")
      {:ok, view, _html} = live(conn, ~p"/knowledge/projects/#{off_github.id}")
      assert has_element?(view, "#readme-state", "only for GitHub")
    end

    test "renders emoji shortcodes in the description, sanitized", %{conn: conn} do
      project = project_fixture(summary: "Charts :bar_chart: for all <script>x()</script>:tada:")
      {:ok, view, _html} = live(conn, ~p"/knowledge/projects/#{project.id}")

      assert has_element?(view, "#project-summary", "Charts 📊 for all")
      assert has_element?(view, "#project-summary", "🎉")
      refute render(view) =~ "x()"
    end

    test "README addresses resolve into the repository; lines are not hard breaks", %{conn: conn} do
      readme = """
      <p align="center"><img src="./assets/logo.png" alt="Logo"></p>

      ![CI](https://example.com/ci.svg)
      ![Shot](docs/shot.png)
      [Guide](/docs/guide.md) [Top](#top) [Site](https://site.example)
      """

      project =
        project_fixture(
          title: "acme/rocket",
          readme: readme,
          readme_fetched_at: now(),
          attributes: %{"default_branch" => "main"}
        )

      {:ok, view, _html} = live(conn, ~p"/knowledge/projects/#{project.id}")
      raw = "https://raw.githubusercontent.com/acme/rocket/main/"
      blob = "https://github.com/acme/rocket/blob/main/"

      assert has_element?(view, ~s(#readme-body img[src="#{raw}assets/logo.png"]))
      assert has_element?(view, ~s(#readme-body img[src="#{raw}docs/shot.png"]))
      assert has_element?(view, ~s(#readme-body img[src="https://example.com/ci.svg"]))
      assert has_element?(view, ~s(#readme-body a[href="#{blob}docs/guide.md"]))
      assert has_element?(view, ~s(#readme-body a[href="https://site.example"]))
      refute has_element?(view, "#readme-body br")
    end

    test "edits the instruction in a modal", %{conn: conn} do
      project = project_fixture()
      {:ok, view, _html} = live(conn, ~p"/knowledge/projects/#{project.id}")

      assert has_element?(view, "#instruction", "No instruction yet.")
      assert has_element?(view, "#edit-instruction[commandfor='instruction-modal']")

      {:ok, view, _html} =
        view
        |> form("#instruction-form", project: %{instruction: "A **rocket** engine."})
        |> render_submit()
        |> follow_redirect(conn)

      assert has_element?(view, "#instruction-body strong", "rocket")
      assert Knowledge.get_project!(project.id).instruction == "A **rocket** engine."

      view
      |> form("#instruction-form", project: %{instruction: String.duplicate("x", 20_001)})
      |> render_submit()

      assert has_element?(view, "#instruction-modal", "should be at most")
    end

    test "marks and clears deprecation", %{conn: conn} do
      project = project_fixture()
      {:ok, view, _html} = live(conn, ~p"/knowledge/projects/#{project.id}")
      refute has_element?(view, "#deprecation-notice")

      {:ok, view, _html} =
        view
        |> form("#deprecate-form", deprecation: %{reason: "Superseded by acme/next"})
        |> render_submit()
        |> follow_redirect(conn)

      assert has_element?(view, "#deprecation-notice", "Superseded by acme/next")
      assert has_element?(view, "[data-role='deprecated-status']", "Deprecated")

      view |> element("#undeprecate") |> render_click()
      refute has_element?(view, "#deprecation-notice")
      assert has_element?(view, "#open-deprecate")
    end

    test "an archived GitHub project is deprecated without an undo", %{conn: conn} do
      project = project_fixture(attributes: %{"archived" => true})
      {:ok, view, _html} = live(conn, ~p"/knowledge/projects/#{project.id}")

      assert has_element?(view, "#deprecation-notice", "archived on GitHub")
      refute has_element?(view, "#undeprecate")
    end

    test "lists flag deprecated projects and filter by status", %{conn: conn} do
      old = project_fixture(title: "acme/old", deprecated_at: now())
      fresh = project_fixture(title: "acme/fresh")

      {:ok, view, _html} = live(conn, ~p"/knowledge")
      assert has_element?(view, "#project-#{old.id} [data-role='deprecated-status']")
      refute has_element?(view, "#project-#{fresh.id} [data-role='deprecated-status']")

      view |> form("#project-filters", filters: %{status: "deprecated"}) |> render_change()
      assert_patch(view, ~p"/knowledge?status=deprecated")
      assert has_element?(view, "#project-#{old.id}")
      refute has_element?(view, "#project-#{fresh.id}")

      {:ok, view, _html} = live(conn, ~p"/knowledge?status=active")
      refute has_element?(view, "#project-#{old.id}")
      assert has_element?(view, "#project-#{fresh.id}")
    end
  end
end
