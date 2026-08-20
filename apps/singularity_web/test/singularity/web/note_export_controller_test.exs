defmodule Singularity.Web.NoteExportControllerTest do
  use Singularity.Web.ConnCase, async: false

  import ExUnit.CaptureLog

  @resource_id "019f9f0f-f384-78ef-8934-2d798944be01"
  @version_id "019f9f0f-f384-78ef-8934-2d798944be02"

  setup %{conn: conn, runtime_api: runtime_api} do
    current_session = session(true)
    TestRuntimeApi.put(runtime_api, :sessions, %{"opaque-session" => {:ok, current_session}})
    {:ok, conn: put_session_id(conn, "opaque-session"), current_session: current_session}
  end

  test "returns exact markdown bytes with defensive no-store headers and dual safe filename", %{
    conn: conn,
    runtime_api: runtime_api,
    current_session: current_session
  } do
    markdown = <<"# Exact\n", 0xE6, 0xBC, 0xA2, "\n">>

    TestRuntimeApi.put(
      runtime_api,
      :export_note,
      {:ok,
       %NoteExport{
         resource_id: @resource_id,
         resource_version_id: @version_id,
         filename: "報告.md",
         media_type: "text/markdown; charset=utf-8",
         markdown: markdown
       }}
    )

    response = get(conn, "/api/v1/notes/#{@resource_id}/export")
    assert response.status == 200
    assert response.resp_body == markdown
    assert get_resp_header(response, "content-type") == ["text/markdown; charset=utf-8"]
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert get_resp_header(response, "x-content-type-options") == ["nosniff"]
    assert [disposition] = get_resp_header(response, "content-disposition")
    assert disposition =~ ~s(filename="note.md")
    assert disposition =~ "filename*=UTF-8''%E5%A0%B1%E5%91%8A.md"
    assert {:export_note, current_session, @resource_id} in TestRuntimeApi.calls(runtime_api)
  end

  test "defends header construction and falls back without reflecting unsafe filename", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    TestRuntimeApi.put(
      runtime_api,
      :export_note,
      {:ok,
       %NoteExport{
         resource_id: @resource_id,
         resource_version_id: @version_id,
         filename: "safe.md\r\nX-Evil: yes",
         media_type: "text/markdown; charset=utf-8",
         markdown: "bytes"
       }}
    )

    logs =
      capture_log(fn ->
        send(self(), {:response, get(conn, "/api/v1/notes/#{@resource_id}/export")})
      end)

    assert_receive {:response, response}
    assert response.status == 200

    assert get_resp_header(response, "content-disposition") == [
             "attachment; filename=\"note.md\"; filename*=UTF-8''note.md"
           ]

    refute inspect(response.resp_headers) =~ "X-Evil"
    refute logs =~ "X-Evil"
  end

  test "auth, lock, and runtime failures remain stable and content-free", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    assert json_response(get(build_conn(), "/api/v1/notes/#{@resource_id}/export"), 401) == %{
             "error" => %{"code" => "unauthenticated"}
           }

    TestRuntimeApi.put(runtime_api, :sessions, %{"opaque-session" => {:ok, session(false)}})

    assert json_response(get(conn, "/api/v1/notes/#{@resource_id}/export"), 403) == %{
             "error" => %{"code" => "vault_locked"}
           }

    TestRuntimeApi.put(runtime_api, :sessions, %{"opaque-session" => {:ok, session(true)}})

    for {code, status} <- [invalid: 400, forbidden: 403, not_found: 404, storage_unavailable: 503] do
      TestRuntimeApi.put(runtime_api, :export_note, {:error, code})
      response = get(conn, "/api/v1/notes/#{@resource_id}/export")
      assert json_response(response, status) == %{"error" => %{"code" => Atom.to_string(code)}}
      assert get_resp_header(response, "cache-control") == ["no-store"]
    end

    TestRuntimeApi.put(runtime_api, :export_note, {:error, :internal_secret_failure})
    response = get(conn, "/api/v1/notes/#{@resource_id}/export")

    assert json_response(response, 503) == %{
             "error" => %{"code" => "storage_unavailable"}
           }
  end
end
