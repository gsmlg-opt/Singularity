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

  test "lists GitHub under accounts and configures it in a modal", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/system/accounts")
    assert html =~ "Not set"
    assert has_element?(view, "#accounts-entry-github[aria-current='page']")

    assert has_element?(
             view,
             "#configure-github[command='show-modal'][commandfor='github-modal']"
           )

    assert has_element?(view, "dialog#github-modal #github-token-form")
    refute has_element?(view, "#clear-token")

    {:ok, view, html} =
      view
      |> form("#github-token-form", github: %{token: "ghp_secretabcd"})
      |> render_submit()
      |> follow_redirect(conn, ~p"/system/accounts/github")

    assert html =~ "Token saved"
    assert html =~ "••••abcd"
    refute html =~ "ghp_secretabcd"
    assert Settings.get_github_token() == "ghp_secretabcd"

    view |> element("#clear-token") |> render_click()
    assert Settings.github_token_status() == :unset
    assert render(view) =~ "Not set"
  end

  test "reports a token from the environment", %{conn: conn} do
    System.put_env("GITHUB_TOKEN", "env-token-9876")
    {:ok, view, html} = live(conn, ~p"/system/accounts/github")
    assert html =~ "GITHUB_TOKEN"
    assert html =~ "••••9876"
    refute has_element?(view, "#clear-token")
  end

  test "rejects a blank token", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/system/accounts/github")
    html = view |> form("#github-token-form", github: %{token: "  "}) |> render_submit()
    assert html =~ "can&#39;t be blank"
  end

  test "appearance saves the colour theme and the root layout uses it", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/system/appearance")
    assert html =~ ~s(data-theme="moonlight")
    assert has_element?(view, "dialog#theme-modal #theme-moonlight[checked]")

    assert {:error, {:redirect, %{to: "/system/appearance"}}} =
             view |> form("#theme-form", appearance: %{theme: "sunshine"}) |> render_submit()

    assert Settings.theme() == "sunshine"
    assert html_response(get(conn, ~p"/system/appearance"), 200) =~ ~s(data-theme="sunshine")
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
