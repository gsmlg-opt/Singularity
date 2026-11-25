defmodule SingularityWeb.KnowledgeSearchLiveTest do
  use SingularityWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Singularity.Fixtures

  test "starts with the wordmark, one search field and no results", %{conn: conn} do
    project_fixture()
    rfc_fixture(8446)

    {:ok, view, _html} = live(conn, ~p"/knowledge")
    assert has_element?(view, "main svg#knowledge-wordmark")
    assert has_element?(view, "main form[role='search'] input[type='search']")
    refute has_element?(view, "main table")
    refute has_element?(view, "#knowledge-search-empty")
  end

  test "submits a search across item types and excludes unrelated items", %{conn: conn} do
    project =
      project_fixture(
        title: "acme/tls",
        summary: "A protocol implementation",
        readme: "Supports the encrypted transport."
      )

    rfc_fixture(8446,
      title: "TLS 1.3",
      summary: "A secure channel.\n\nThe second paragraph.",
      content: "The transport protocol provides encryption."
    )

    rfc_fixture(791, title: "Internet Protocol")

    {:ok, view, _html} = live(conn, ~p"/knowledge")
    view |> form("#knowledge-search", q: " TLS protocol ") |> render_submit()

    assert_patch(view, ~p"/knowledge?#{%{q: "TLS protocol"}}")

    refute has_element?(view, "#knowledge-wordmark")
    assert has_element?(view, "#knowledge-results a[href='/knowledge/projects/#{project.id}']")
    assert has_element?(view, "#knowledge-results a[href='/knowledge/ietf-rfcs/8446']")
    assert has_element?(view, "#knowledge-results tr .line-clamp-1", "The second paragraph.")
    refute has_element?(view, "#knowledge-results a[href='/knowledge/ietf-rfcs/791']")

    render_patch(view, ~p"/knowledge?#{%{q: "acme/tls transport"}}")
    assert has_element?(view, "#knowledge-results a[href='/knowledge/projects/#{project.id}']")

    view |> form("#knowledge-search", q: "  ") |> render_submit()
    assert_patch(view, ~p"/knowledge")
    assert has_element?(view, "#knowledge-wordmark")
    refute has_element?(view, "main table")
    refute has_element?(view, "#knowledge-search-empty")
  end

  test "handles direct search URLs, RFC numbers, and README matches", %{conn: conn} do
    rfc_fixture(8446, title: "Transport Layer Security")
    project_fixture(title: "acme/tool", readme: "Set mode to 100%_safe to configure it.")
    project_fixture(title: "acme/other", readme: "Set mode to 100xXsafe to configure it.")

    {:ok, view, _html} = live(conn, ~p"/knowledge?#{%{q: "RFC 8446"}}")
    assert has_element?(view, "#knowledge-results a", "RFC 8446")

    render_patch(view, ~p"/knowledge?#{%{q: "100%_safe"}}")
    assert has_element?(view, "#knowledge-results a", "acme/tool")
    refute has_element?(view, "#knowledge-results a", "acme/other")

    render_patch(view, ~p"/knowledge?q=unmatched")
    assert has_element?(view, "#knowledge-search-empty")
    refute has_element?(view, "main table")
  end

  test "redirects bookmarked project filters to the project list", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/knowledge/projects?label=favorite"}}} =
             live(conn, ~p"/knowledge?label=favorite")
  end

  test "searches the entire text of an RFC that exceeds the tsvector limit", %{conn: conn} do
    middle = Enum.map_join(1..100_000, " ", &"documentword#{&1}")
    rfc_fixture(8446, title: "Transport Layer Security", content: "firstterm #{middle} lastterm")

    {:ok, view, _html} = live(conn, ~p"/knowledge?#{%{q: "firstterm lastterm"}}")
    assert has_element?(view, "#knowledge-results a", "RFC 8446")
  end

  test "puts a title match before body matches and keeps the query on the next page", %{
    conn: conn
  } do
    top = project_fixture(title: "acme/sparrow")

    for number <- 1..30 do
      rfc_fixture(number, content: "References the sparrow implementation.")
    end

    {:ok, view, _html} = live(conn, ~p"/knowledge?q=sparrow")

    assert has_element?(
             view,
             "#knowledge-results tbody tr:first-child a[href='/knowledge/projects/#{top.id}']"
           )

    view |> element("#page-next") |> render_click()
    assert_patch(view, ~p"/knowledge?#{%{q: "sparrow", page: 2}}")
    assert has_element?(view, "#knowledge-results a[href='/knowledge/ietf-rfcs/1']")
    refute has_element?(view, "#page-next")
  end
end
