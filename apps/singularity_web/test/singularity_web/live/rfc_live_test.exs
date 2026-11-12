defmodule SingularityWeb.RfcLiveTest do
  use SingularityWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Singularity.Fixtures

  alias Singularity.Knowledge.Label
  alias Singularity.Repo

  defp tls_fixture do
    rfc_fixture(8446,
      title: "The Transport Layer Security (TLS) Protocol Version 1.3",
      summary: "This document specifies version 1.3 of TLS.",
      published_at: ~U[2018-08-01 00:00:00Z],
      content: "# RFC 8446\n\nThe primary goal of TLS is a secure channel.\n",
      attributes: %{
        "number" => 8446,
        "status" => "PROPOSED STANDARD",
        "authors" => ["E. Rescorla"],
        "stream_source" => "Transport Layer Security",
        "doi" => "10.17487/RFC8446",
        "errata_url" => "https://www.rfc-editor.org/errata/rfc8446",
        "page_count" => 160,
        "obsoletes" => ["rfc5246", "rfc5077"],
        "obsoleted_by" => ["rfc9846"]
      }
    )
  end

  describe "index" do
    test "lists RFCs in the IETF RFCs menu, highest number first", %{conn: conn} do
      tls_fixture()
      rfc_fixture(791, title: "Internet Protocol")
      project_fixture(title: "acme/rocket")

      {:ok, view, html} = live(conn, ~p"/knowledge/ietf-rfcs")

      assert has_element?(view, "#section-menu-navigation[data-active-nav='knowledge-rfcs']")
      assert has_element?(view, "#rfcs-total", "2 RFCs")
      assert has_element?(view, "#rfc-8446 a[href='/knowledge/ietf-rfcs/8446']", "RFC 8446")
      assert has_element?(view, "#rfc-8446 [data-role='rfc-status']", "PROPOSED STANDARD")
      assert has_element?(view, "#rfc-8446", "2018-08")
      refute html =~ "acme/rocket"

      [first, second] = Regex.scan(~r/id="rfc-(\d+)"/, html, capture: :all_but_first)
      assert {first, second} == {["8446"], ["791"]}
    end

    test "searches by number or title", %{conn: conn} do
      tls_fixture()
      rfc_fixture(791, title: "Internet Protocol")
      {:ok, view, _html} = live(conn, ~p"/knowledge/ietf-rfcs")

      view |> form("#rfc-filters", filters: %{q: "791"}) |> render_change()
      assert_patch(view, ~p"/knowledge/ietf-rfcs?q=791")
      assert has_element?(view, "#rfc-791")
      refute has_element?(view, "#rfc-8446")

      view |> form("#rfc-filters", filters: %{q: "transport"}) |> render_change()
      assert has_element?(view, "#rfc-8446")
      refute has_element?(view, "#rfc-791")

      view |> form("#rfc-filters", filters: %{q: "nothing like this"}) |> render_change()
      assert has_element?(view, "#rfcs-empty")
    end

    test "filters by label and clears the filter", %{conn: conn} do
      tls = tls_fixture()
      rfc_fixture(791)
      label_fixture(tls, "obsoleted")

      {:ok, view, _html} = live(conn, ~p"/knowledge/ietf-rfcs?label=obsoleted")
      assert has_element?(view, "#active-label", "obsoleted")
      assert has_element?(view, "#rfc-8446")
      refute has_element?(view, "#rfc-791")

      view |> element("#clear-label") |> render_click()
      assert_patch(view, ~p"/knowledge/ietf-rfcs")
      assert has_element?(view, "#rfc-791")
    end
  end

  describe "show" do
    test "shows metadata, abstract and full text", %{conn: conn} do
      tls_fixture()
      {:ok, view, _html} = live(conn, ~p"/knowledge/ietf-rfcs/8446")

      assert has_element?(view, "h1", "RFC 8446")
      assert has_element?(view, "#rfc-title", "Transport Layer Security")
      assert has_element?(view, "#rfc-header [data-role='rfc-status']", "PROPOSED STANDARD")
      assert has_element?(view, "#rfc-facts", "2018-08")
      assert has_element?(view, "#rfc-facts", "160")
      assert has_element?(view, "#rfc-facts a[href^='/out?']", "DOI")
      assert has_element?(view, "#rfc-abstract", "version 1.3 of TLS")
      assert has_element?(view, "#rfc-about", "E. Rescorla")
      assert has_element?(view, "#rfc-about", "Transport Layer Security")
      assert has_element?(view, "#rfc-content-body h1", "RFC 8446")
      assert has_element?(view, "#rfc-content-body", "secure channel")
    end

    test "links related RFCs that are in the knowledge base", %{conn: conn} do
      tls_fixture()
      rfc_fixture(5246, title: "TLS 1.2")
      {:ok, view, _html} = live(conn, ~p"/knowledge/ietf-rfcs/8446")

      assert has_element?(
               view,
               "#related-obsoletes a[href='/knowledge/ietf-rfcs/5246']",
               "RFC 5246"
             )

      assert has_element?(view, "#related-obsoletes [data-missing]", "RFC 5077")
      assert has_element?(view, "#related-obsoleted_by [data-missing]", "RFC 9846")
      refute has_element?(view, "#related-updates")
    end

    test "says when the full text is not synced", %{conn: conn} do
      rfc_fixture(1)
      {:ok, view, _html} = live(conn, ~p"/knowledge/ietf-rfcs/1")

      assert has_element?(view, "#rfc-content-empty", "Full text not synced yet.")
      assert has_element?(view, "#rfc-history-empty")
    end

    test "adds and removes manual labels, keeps automatic ones", %{conn: conn} do
      tls = tls_fixture()
      auto = label_fixture(tls, "status:proposed-standard")
      {:ok, view, _html} = live(conn, ~p"/knowledge/ietf-rfcs/8446")

      view |> form("#label-form", label: %{name: "Crypto"}) |> render_submit()
      manual = Repo.get_by!(Label, item_id: tls.id, name: "crypto")
      assert has_element?(view, "#rfc-label-#{manual.id} [data-origin='manual']")
      refute has_element?(view, "#remove-label-#{auto.id}")

      view |> element("#remove-label-#{manual.id}") |> render_click()
      refute has_element?(view, "#rfc-label-#{manual.id}")
      assert has_element?(view, "#rfc-label-#{auto.id}")
    end

    test "lists the RFC's changes with links to their runs", %{conn: conn} do
      tls = tls_fixture()
      run = fetch_run_fixture(source_fixture(name: "IETF RFCs"))

      item_change_fixture(run, tls,
        fields: %{"attributes.obsoleted_by" => %{"old" => [], "new" => ["rfc9846"]}},
        content_diff: "@@ -1 +1 @@\n-a\n+b\n"
      )

      {:ok, view, _html} = live(conn, ~p"/knowledge/ietf-rfcs/8446")

      assert has_element?(view, "#rfc-history a[href='/source/runs/#{run.id}']")
      assert has_element?(view, "#rfc-history [data-change='updated']")
      assert has_element?(view, "#rfc-history", "attributes.obsoleted_by, full text")
    end

    test "an unknown or malformed number is not found", %{conn: conn} do
      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/knowledge/ietf-rfcs/9999") end
      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/knowledge/ietf-rfcs/abc") end
    end
  end

  describe "runs" do
    test "the runs page shows change counts and links to each run", %{conn: conn} do
      run =
        fetch_run_fixture(source_fixture(),
          added_count: 3,
          updated_count: 2,
          removed_count: 1
        )

      {:ok, view, _html} = live(conn, ~p"/source/runs")

      assert has_element?(view, "[data-role='run-changes']", "+3 ~2 −1")
      assert has_element?(view, "#view-run-#{run.id}[href='/source/runs/#{run.id}']")
    end

    test "a run's page lists its changes with fields and diffs, filtered by type", %{conn: conn} do
      tls = tls_fixture()
      source = source_fixture(name: "IETF RFCs")
      run = fetch_run_fixture(source, added_count: 1, updated_count: 1, removed_count: 1)

      updated =
        item_change_fixture(run, tls,
          fields: %{"title" => %{"old" => "Old title", "new" => "New title"}},
          content_diff: "@@ -1 +1 @@\n-old line\n+new line\n"
        )

      item_change_fixture(run, rfc_fixture(791), change: "added")
      item_change_fixture(run, nil, change: "removed", external_id: "rfc1", title: "Gone RFC")

      {:ok, view, _html} = live(conn, ~p"/source/runs/#{run.id}")

      assert has_element?(
               view,
               "#run-details a[href='/source/sources/#{source.id}']",
               "IETF RFCs"
             )

      assert has_element?(view, "#filter-all", "All · 3")
      assert has_element?(view, "#run-changes a[href='/knowledge/ietf-rfcs/8446']")
      assert has_element?(view, "#run-changes", "Gone RFC")
      refute has_element?(view, "#run-changes a[href='/knowledge/ietf-rfcs/1']")
      assert has_element?(view, "#run-changes", "Old title")
      assert has_element?(view, "#diff-#{updated.id} .text-error", "-old line")
      assert has_element?(view, "#diff-#{updated.id} .text-success", "+new line")

      view |> element("#filter-updated") |> render_click()
      assert_patch(view, ~p"/source/runs/#{run.id}?change=updated")
      assert has_element?(view, "#filter-updated[aria-current='page']")
      refute has_element?(view, "#run-changes", "Gone RFC")
    end

    test "a run without changes says so", %{conn: conn} do
      run = fetch_run_fixture(source_fixture())
      {:ok, view, _html} = live(conn, ~p"/source/runs/#{run.id}")
      assert has_element?(view, "#changes-empty")
    end
  end
end
