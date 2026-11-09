defmodule SingularityWeb.PageControllerTest do
  use SingularityWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Self-hosted information collector"
  end
end
