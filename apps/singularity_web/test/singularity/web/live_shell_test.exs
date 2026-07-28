defmodule Singularity.Web.LiveShellTest do
  use Singularity.Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "LoginLive renders a password form without reflecting credentials", %{conn: conn} do
    {:ok, view, html} = live(conn, "/login")

    assert html =~ "Sign in"
    assert has_element?(view, "form[action='/login'][method='post']")
    assert has_element?(view, "input[name='login']")
    assert has_element?(view, "input[name='password'][type='password']")
  end

  test "UnlockLive repeats authentication and renders the unlock form", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    TestRuntimeApi.put(runtime_api, :sessions, %{
      "opaque-session" => {:ok, session(false)}
    })

    {:ok, view, html} =
      conn
      |> put_session_id("opaque-session")
      |> live("/vault/unlock")

    assert html =~ "Unlock vault"
    assert has_element?(view, "form[action='/vault/unlock'][method='post']")
    assert has_element?(view, "input[name='password'][type='password']")
  end

  test "LiveView mount hooks reject unauthenticated and locked reconnects", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    assert {:error, {:redirect, %{to: "/login"}}} =
             live(conn, "/vault/unlock")

    TestRuntimeApi.put(runtime_api, :sessions, %{
      "opaque-session" => {:ok, session(false)}
    })

    assert {:error, {:redirect, %{to: "/vault/unlock"}}} =
             conn
             |> put_session_id("opaque-session")
             |> live("/assets")
  end

  test "AssetsLive loads web-safe summaries through Runtime.Api", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    current_session = session(true)

    TestRuntimeApi.put(runtime_api, :sessions, %{
      "opaque-session" => {:ok, current_session}
    })

    TestRuntimeApi.put(
      runtime_api,
      :assets,
      {:ok,
       %SearchPage{
         items: [
           %AssetSummary{
             id: "asset-1",
             resource_version_id: "version-1",
             title: "Annual report",
             original_filename: "report.pdf",
             detected_media_type: "application/pdf",
             state: :available,
             state_revision: 3,
             label: "private",
             progress: 100,
             failure: nil,
             updated_at: DateTime.utc_now()
           }
         ],
         next_cursor: nil
       }}
    )

    {:ok, view, html} =
      conn
      |> put_session_id("opaque-session")
      |> live("/assets")

    assert html =~ "Annual report"
    assert html =~ "report.pdf"
    refute html =~ "opaque-session"

    assert Enum.any?(
             TestRuntimeApi.calls(runtime_api),
             &match?({:list_assets, ^current_session, %{}}, &1)
           )

    assert has_element?(view, "nav a[href='/activity']")
  end
end
