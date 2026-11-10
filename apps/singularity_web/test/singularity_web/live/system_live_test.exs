defmodule SingularityWeb.SystemLiveTest do
  # Not async: these tests change the GITHUB_TOKEN environment variable.
  use SingularityWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Singularity.Fixtures

  alias Singularity.{Knowledge, Settings}

  setup do
    previous = System.get_env("GITHUB_TOKEN")
    System.delete_env("GITHUB_TOKEN")

    on_exit(fn ->
      if previous,
        do: System.put_env("GITHUB_TOKEN", previous),
        else: System.delete_env("GITHUB_TOKEN")
    end)
  end

  test "sets and clears the GitHub token without echoing it", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/system/github")
    assert html =~ "Not set"
    refute has_element?(view, "#clear-token")

    html =
      view |> form("#github-token-form", github: %{token: "ghp_secretabcd"}) |> render_submit()

    assert html =~ "••••abcd"
    refute html =~ "ghp_secretabcd"
    assert Settings.get_github_token() == "ghp_secretabcd"

    view |> element("#clear-token") |> render_click()
    assert Settings.github_token_status() == :unset
    assert render(view) =~ "Not set"
  end

  test "reports a token from the environment", %{conn: conn} do
    System.put_env("GITHUB_TOKEN", "env-token-9876")
    {:ok, view, html} = live(conn, ~p"/system/github")
    assert html =~ "GITHUB_TOKEN"
    assert html =~ "••••9876"
    refute has_element?(view, "#clear-token")
  end

  test "rejects a blank token", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/system/github")
    html = view |> form("#github-token-form", github: %{token: "  "}) |> render_submit()
    assert html =~ "can&#39;t be blank"
  end

  test "status shows the version and queue counts", %{conn: conn} do
    {:ok, _job} = Knowledge.enqueue_details(project_fixture().id)

    {:ok, view, html} = live(conn, ~p"/system/status")
    assert html =~ to_string(Application.spec(:singularity, :vsn))
    assert has_element?(view, "#queue-details-available", "1")
    assert has_element?(view, "#queue-collect-available", "0")
    assert has_element?(view, "#section-menu-navigation[data-active-nav='system-status']")
  end
end
