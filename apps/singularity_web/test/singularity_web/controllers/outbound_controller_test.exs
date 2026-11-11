defmodule SingularityWeb.OutboundControllerTest do
  use SingularityWeb.ConnCase, async: true

  test "shows the destination and continues only on click", %{conn: conn} do
    to = "https://example.com/path?q=1"
    conn = get(conn, ~p"/out?#{[to: to]}")
    html = html_response(conn, 200)

    assert html =~ ~s(id="outbound-host")
    assert html =~ "example.com"
    assert html =~ "https://example.com/path?q=1"
    assert html =~ ~s(href="https://example.com/path?q=1")
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    refute get_resp_header(conn, "location") != []
  end

  test "goes back only to a page of this site", %{conn: conn} do
    to = "https://example.com"

    local =
      conn
      |> put_req_header("referer", "http://www.example.com/knowledge/projects/7?tab=x")
      |> get(~p"/out?#{[to: to]}")

    assert local |> html_response(200) |> back_href() == ["/knowledge/projects/7?tab=x"]

    foreign =
      build_conn()
      |> put_req_header("referer", "https://evil.example/phish")
      |> get(~p"/out?#{[to: to]}")

    html = html_response(foreign, 200)
    refute html =~ "evil.example"
    assert back_href(html) == ["/"]
  end

  test "rejects addresses that are not web addresses", %{conn: conn} do
    for to <- ["javascript:alert(1)", "ftp://example.com/x", "example.com", ""] do
      html = conn |> get(~p"/out?#{[to: to]}") |> html_response(400)
      assert html =~ "This is not a web address."
      refute html =~ "outbound-continue"
    end

    assert conn |> get(~p"/out") |> html_response(400) =~ "This is not a web address."
  end

  defp back_href(html),
    do: html |> Floki.parse_document!() |> Floki.attribute("#outbound-back", "href")
end
