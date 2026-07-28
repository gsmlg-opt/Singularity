defmodule Singularity.Web.DownloadControllerTest do
  use Singularity.Web.ConnCase, async: false

  @asset_id "019f9f1c-26f7-71a0-9cb2-2c22c49fe334"

  setup %{conn: conn, runtime_api: runtime_api} do
    current_session = session(true)

    TestRuntimeApi.put(runtime_api, :sessions, %{
      "opaque-session" => {:ok, current_session}
    })

    {:ok, conn: put_session_id(conn, "opaque-session"), current_session: current_session}
  end

  test "delegates a range read and returns runtime-owned bytes", %{
    conn: conn,
    runtime_api: runtime_api,
    current_session: current_session
  } do
    TestRuntimeApi.put(
      runtime_api,
      :download,
      {:ok,
       %{
         body: "plain",
         content_length: 5,
         content_range: "bytes 2-6/10",
         detected_media_type: "application/pdf",
         status: 206
       }}
    )

    response =
      conn
      |> put_req_header("range", "bytes=2-6")
      |> get("/api/v1/assets/#{@asset_id}/content")

    assert response.status == 206
    assert response.resp_body == "plain"
    assert get_resp_header(response, "content-range") == ["bytes 2-6/10"]
    assert get_resp_header(response, "content-type") == ["application/pdf"]

    assert Enum.any?(
             TestRuntimeApi.calls(runtime_api),
             &match?(
               {:download, ^current_session, @asset_id, "bytes=2-6"},
               &1
             )
           )
  end

  test "delegates a full read when Range is absent", %{
    conn: conn,
    runtime_api: runtime_api,
    current_session: current_session
  } do
    TestRuntimeApi.put(
      runtime_api,
      :download,
      {:ok,
       %{
         body: "complete",
         content_length: 8,
         content_range: nil,
         detected_media_type: "application/pdf",
         status: 200
       }}
    )

    response = get(conn, "/api/v1/assets/#{@asset_id}/content")

    assert response.status == 200
    assert response.resp_body == "complete"
    assert get_resp_header(response, "content-range") == []

    assert Enum.any?(
             TestRuntimeApi.calls(runtime_api),
             &match?({:download, ^current_session, @asset_id, nil}, &1)
           )
  end

  test "maps download failures to stable JSON", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    mappings = [
      invalid: 400,
      not_found: 404,
      conflict: 409,
      range_not_satisfiable: 416,
      storage_unavailable: 503
    ]

    for {code, status} <- mappings do
      TestRuntimeApi.put(runtime_api, :download, {:error, code})

      response = get(conn, "/api/v1/assets/#{@asset_id}/content")

      assert json_response(response, status) == %{
               "error" => %{"code" => Atom.to_string(code)}
             }
    end
  end
end
