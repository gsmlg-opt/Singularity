defmodule Singularity.Web.AuditLiveTest do
  use Singularity.Web.ConnCase, async: false

  setup %{conn: conn, runtime_api: runtime_api} do
    TestRuntimeApi.put(runtime_api, :sessions, %{
      "opaque-session" => {:ok, session(true)}
    })

    {:ok, conn: put_session_id(conn, "opaque-session")}
  end

  test "names the restore command as the only integrity acceptance proof", %{conn: conn} do
    html = conn |> get("/audit") |> html_response(200)

    assert html =~ "mix singularity.test.restore"
    assert html =~ "only integrity acceptance proof"
    assert html =~ "restore"
    refute html =~ "Integrity audit passed"
    refute html =~ "current vault is valid"
    refute html =~ "live vault is valid"
  end

  test "is read-only and makes no runtime mutation or backup-status calls", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    html = conn |> get("/audit") |> html_response(200)
    document = Floki.parse_document!(html)

    assert Floki.find(document, "form") == []
    assert Floki.find(document, "button") == []
    assert Floki.find(document, "[phx-click]") == []
    assert Floki.find(document, "[phx-submit]") == []

    refute Enum.any?(TestRuntimeApi.calls(runtime_api), fn
             {:request_backup, _, _} -> true
             {:backup_status, _, _} -> true
             {:request_integrity_audit, _, _} -> true
             {:integrity_status, _, _} -> true
             _other -> false
           end)
  end
end
