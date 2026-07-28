defmodule Singularity.Web.UploadControllerTest do
  use Singularity.Web.ConnCase, async: false

  import ExUnit.CaptureLog

  @one_mib 1_048_576
  @grant_id "019f9f16-f163-7bd8-8e83-207591b5c948"

  setup %{conn: conn, runtime_api: runtime_api} do
    current_session = session(true)

    TestRuntimeApi.put(runtime_api, :sessions, %{
      "opaque-session" => {:ok, current_session}
    })

    conn =
      conn
      |> put_session_id("opaque-session")
      |> put_req_header("content-type", "application/pdf")

    {conn, csrf_token} = put_issued_csrf(conn)

    conn =
      conn
      |> put_req_header("x-upload-token", "UPLOAD_TOKEN_CANARY_11d8")
      |> put_req_header("x-csrf-token", csrf_token)

    {:ok, conn: conn, csrf_token: csrf_token, current_session: current_session}
  end

  test "unauthenticated and locked uploads return JSON without redirects", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    unauthenticated =
      build_conn()
      |> put_req_header("content-type", "application/pdf")
      |> put_req_header("content-length", "5")
      |> put("/api/v1/uploads/#{@grant_id}", "%PDF-")

    assert json_response(unauthenticated, 401) == %{
             "error" => %{"code" => "unauthenticated"}
           }

    assert get_resp_header(unauthenticated, "location") == []

    TestRuntimeApi.put(runtime_api, :sessions, %{
      "locked-session" => {:ok, session(false)}
    })

    locked =
      conn
      |> put_session_id("locked-session")
      |> put_req_header("content-length", "5")
      |> put("/api/v1/uploads/#{@grant_id}", "%PDF-")

    assert json_response(locked, 403) == %{
             "error" => %{"code" => "vault_locked"}
           }

    assert get_resp_header(locked, "location") == []
  end

  test "streams bounded chunks and always ends a successful upload", %{
    conn: conn,
    csrf_token: csrf_token,
    runtime_api: runtime_api,
    current_session: current_session
  } do
    body = "%PDF-" <> :binary.copy("x", 2 * @one_mib + 17)
    handle = make_ref()
    controller = self()

    TestRuntimeApi.put(runtime_api, :begin_upload, {:ok, handle})

    response =
      conn
      |> put_req_header("content-length", Integer.to_string(byte_size(body)))
      |> put("/api/v1/uploads/#{@grant_id}", body)

    assert json_response(response, 201) == %{
             "ok" => true,
             "assetId" => "asset-1",
             "state" => "uploaded",
             "stateRevision" => 1
           }

    calls = TestRuntimeApi.calls(runtime_api)

    assert {:begin_upload, ^current_session, @grant_id,
            %{
              content_length: content_length,
              declared_media_type: "application/pdf",
              csrf_token: ^csrf_token,
              upload_token: "UPLOAD_TOKEN_CANARY_11d8"
            }, ^controller} = Enum.at(calls, 1)

    assert content_length == byte_size(body)

    chunks =
      for {:append_upload, ^handle, chunk} <- calls do
        chunk
      end

    assert {:finish_upload, ^handle, final_chunk} =
             Enum.find(calls, &match?({:finish_upload, ^handle, _chunk}, &1))

    assert IO.iodata_to_binary(chunks ++ [final_chunk]) == body
    assert Enum.all?(chunks, &(byte_size(&1) <= @one_mib))
    assert byte_size(final_chunk) <= @one_mib
    assert Enum.count(calls, &match?({:end_upload, ^handle}, &1)) == 1
    refute Enum.any?(calls, &match?({:abandon_upload, ^handle, _reason}, &1))
  end

  test "an interrupted stream abandons and still ends exactly once", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    body = "%PDF-" <> :binary.copy("x", @one_mib + 1)
    handle = make_ref()

    TestRuntimeApi.put(runtime_api, :begin_upload, {:ok, handle})
    TestRuntimeApi.put(runtime_api, :append_upload, {:error, :storage_unavailable})

    response =
      conn
      |> put_req_header("content-length", Integer.to_string(byte_size(body)))
      |> put("/api/v1/uploads/#{@grant_id}", body)

    assert json_response(response, 503) == %{
             "error" => %{"code" => "storage_unavailable"}
           }

    calls = TestRuntimeApi.calls(runtime_api)

    assert Enum.count(
             calls,
             &match?({:abandon_upload, ^handle, :stream_interrupted}, &1)
           ) == 1

    assert Enum.count(calls, &match?({:end_upload, ^handle}, &1)) == 1
  end

  test "missing CSRF is rejected before begin and credentials are not rendered", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    upload_token = "UPLOAD_TOKEN_CANARY_11d8"

    response =
      conn
      |> delete_req_header("x-csrf-token")
      |> put_req_header("content-length", "5")
      |> put("/api/v1/uploads/#{@grant_id}", "%PDF-")

    assert json_response(response, 403) == %{
             "error" => %{"code" => "csrf_failed"}
           }

    refute response.resp_body =~ upload_token

    refute Enum.any?(
             TestRuntimeApi.calls(runtime_api),
             &match?({:begin_upload, _, _, _, _}, &1)
           )
  end

  test "invalid CSRF is rejected before begin", %{
    conn: conn,
    csrf_token: csrf_token,
    runtime_api: runtime_api
  } do
    first = String.first(csrf_token)
    replacement = if first == "A", do: "B", else: "A"
    invalid_token = replacement <> String.slice(csrf_token, 1..-1//1)

    response =
      conn
      |> delete_req_header("x-csrf-token")
      |> put_req_header("x-csrf-token", invalid_token)
      |> put_req_header("content-length", "5")
      |> put("/api/v1/uploads/#{@grant_id}", "%PDF-")

    assert json_response(response, 403) == %{
             "error" => %{"code" => "csrf_failed"}
           }

    refute Enum.any?(
             TestRuntimeApi.calls(runtime_api),
             &match?({:begin_upload, _, _, _, _}, &1)
           )
  end

  test "missing or invalid Content-Length is rejected before begin", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    for content_length <- [nil, "", "not-an-integer", "-1", "5, 6"] do
      request =
        if is_nil(content_length),
          do: delete_req_header(conn, "content-length"),
          else: put_req_header(conn, "content-length", content_length)

      response = put(request, "/api/v1/uploads/#{@grant_id}", "%PDF-")

      assert json_response(response, 400) == %{
               "error" => %{"code" => "invalid_content_length"}
             }
    end

    refute Enum.any?(
             TestRuntimeApi.calls(runtime_api),
             &match?({:begin_upload, _, _, _, _}, &1)
           )
  end

  test "runtime rejects Content-Length that mismatches the canonical grant", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    TestRuntimeApi.put(runtime_api, :begin_upload, {:error, :integrity_failure})

    response =
      conn
      |> put_req_header("content-length", "5")
      |> put("/api/v1/uploads/#{@grant_id}", "%PDF-")

    assert json_response(response, 422) == %{
             "error" => %{"code" => "integrity_failure"}
           }
  end

  test "runtime rejects declared Content-Type that mismatches the canonical grant", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    TestRuntimeApi.put(runtime_api, :begin_upload, {:error, :unsupported_media_type})

    response =
      conn
      |> delete_req_header("content-type")
      |> put_req_header("content-type", "image/png")
      |> put_req_header("content-length", "5")
      |> put("/api/v1/uploads/#{@grant_id}", "%PDF-")

    assert json_response(response, 415) == %{
             "error" => %{"code" => "unsupported_media_type"}
           }

    assert Enum.any?(TestRuntimeApi.calls(runtime_api), fn
             {:begin_upload, _session, @grant_id, %{declared_media_type: "image/png"}, owner}
             when is_pid(owner) ->
               true

             _other ->
               false
           end)
  end

  test "maps upload errors to the stable HTTP contract", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    mappings = [
      invalid: 400,
      unauthenticated: 401,
      forbidden: 403,
      vault_locked: 403,
      conflict: 409,
      upload_expired: 410,
      upload_too_large: 413,
      unsupported_media_type: 415,
      integrity_failure: 422,
      storage_unavailable: 503
    ]

    for {code, status} <- mappings do
      TestRuntimeApi.put(runtime_api, :begin_upload, {:error, code})

      response =
        conn
        |> put_req_header("content-length", "5")
        |> put("/api/v1/uploads/#{@grant_id}", "%PDF-")

      assert json_response(response, status) == %{
               "error" => %{"code" => Atom.to_string(code)}
             }
    end
  end

  test "endpoint request logs emit status proof without upload or CSRF headers", %{
    conn: conn,
    csrf_token: csrf_token,
    runtime_api: runtime_api
  } do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    success_log =
      capture_log([level: :info], fn ->
        response =
          conn
          |> put_req_header("content-length", "5")
          |> put("/api/v1/uploads/#{@grant_id}", "%PDF-")

        assert response.status == 201
      end)

    assert success_log =~ "PUT /api/v1/uploads/#{@grant_id}"
    assert success_log =~ "Sent 201"
    refute success_log =~ "UPLOAD_TOKEN_CANARY_11d8"
    refute success_log =~ csrf_token

    TestRuntimeApi.put(
      runtime_api,
      :begin_upload,
      {:error, :storage_unavailable}
    )

    failure_token = "UPLOAD_TOKEN_FAILURE_CANARY_9c72"

    failure_log =
      capture_log([level: :info], fn ->
        response =
          conn
          |> delete_req_header("x-upload-token")
          |> put_req_header("x-upload-token", failure_token)
          |> put_req_header("content-length", "5")
          |> put("/api/v1/uploads/#{@grant_id}", "%PDF-")

        assert response.status == 503
      end)

    assert failure_log =~ "PUT /api/v1/uploads/#{@grant_id}"
    assert failure_log =~ "Sent 503"
    refute failure_log =~ failure_token
    refute failure_log =~ csrf_token
  end
end
