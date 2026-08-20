defmodule Singularity.Web.SecretCanaryTest do
  use Singularity.Web.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Singularity.Runtime.DTO.BackupStatus
  alias Singularity.Runtime.DTO.NoteSearchPage
  alias Singularity.Runtime.DTO.NoteSummary

  @asset_id "019f9f65-acde-7a31-bf09-9238cb428701"
  @grant_id "019f9f65-acde-7a31-bf09-9238cb428702"
  @operation_id "019f9f65-acde-7a31-bf09-9238cb428703"

  @canaries %{
    password: "WEB_PASSWORD_CANARY_271f",
    vault_key: "WEB_VAULT_KEY_CANARY_e59d",
    domain_key: "WEB_DOMAIN_KEY_CANARY_d881",
    dek: "WEB_DEK_CANARY_a175",
    backup_passphrase: "WEB_BACKUP_PASSPHRASE_CANARY_e2aa"
  }

  setup %{conn: conn, runtime_api: runtime_api} do
    current_session = %{
      session(true)
      | session_id: @canaries.vault_key,
        account_id: @canaries.domain_key,
        principal_id: @canaries.dek
    }

    TestRuntimeApi.put(runtime_api, :sessions, %{
      "opaque-session" => {:ok, current_session}
    })

    {:ok, conn: put_session_id(conn, "opaque-session"), current_session: current_session}
  end

  test "initial HTML, data props, and server-pushed LiveView payloads omit secret canaries", %{
    conn: conn,
    current_session: current_session,
    runtime_api: runtime_api
  } do
    initial_login_response = build_conn() |> get("/login")

    assert_secret_free(
      [initial_login_response.resp_body, initial_login_response.resp_headers],
      :initial_login_response
    )

    assert_response_metadata(
      initial_login_response,
      200,
      "text/html; charset=utf-8",
      :initial_login
    )

    TestRuntimeApi.put(runtime_api, :login, {:ok, "opaque-login", session(false)})

    login_logs =
      capture_log(fn ->
        send(
          self(),
          {:login_response,
           post(build_conn(), "/login", %{
             "login" => "owner@example.test",
             "password" => @canaries.password
           })}
        )
      end)

    assert_receive {:login_response, login_response}

    assert_secret_free(
      [login_response.resp_body, login_response.resp_headers, login_logs],
      :login_return
    )

    login_location = get_resp_header(login_response, "location")
    if login_response.status != 302, do: flunk("login redirect status mismatch")
    if login_location != ["/vault/unlock"], do: flunk("login redirect location mismatch")

    assert Enum.count(TestRuntimeApi.calls(runtime_api), fn
             {:login, %{password: password}} -> password == @canaries.password
             _other -> false
           end) == 1

    locked_session = %{current_session | unlocked?: false}
    unlocked_session = %{locked_session | unlocked?: true}

    TestRuntimeApi.put(runtime_api, :sessions, %{
      "opaque-session" => {:ok, locked_session}
    })

    TestRuntimeApi.put(runtime_api, :unlock, {:ok, unlocked_session})

    {unlock_conn, unlock_csrf} = put_issued_csrf(conn)
    unlock_conn = update_in(unlock_conn.private, &Map.delete(&1, :plug_skip_csrf_protection))

    unlock_logs =
      capture_log(fn ->
        send(
          self(),
          {:unlock_response,
           post(unlock_conn, "/vault/unlock", %{
             "_csrf_token" => unlock_csrf,
             "password" => @canaries.password
           })}
        )
      end)

    assert_receive {:unlock_response, unlock_response}
    unlock_surface = [unlock_response.resp_body, unlock_response.resp_headers, unlock_logs]

    assert_secret_free(unlock_surface, :unlock_return)
    assert_no_occurrences(unlock_surface, unlock_csrf, :unlock_csrf_return)

    unlock_location = get_resp_header(unlock_response, "location")
    if unlock_response.status != 302, do: flunk("unlock redirect status mismatch")
    if unlock_location != ["/assets"], do: flunk("unlock redirect location mismatch")

    assert Enum.count(TestRuntimeApi.calls(runtime_api), fn
             {:unlock, ^locked_session, password} -> password == @canaries.password
             _other -> false
           end) == 1

    TestRuntimeApi.put(runtime_api, :sessions, %{
      "opaque-session" => {:ok, unlocked_session}
    })

    {:ok, view, returned_html} = live(conn, "/assets")
    assert_secret_free(returned_html, :returned_assets_html)

    [{"div", attributes, []}] =
      returned_html
      |> Floki.parse_document!()
      |> Floki.find("#asset-workspace")

    data_props =
      attributes
      |> Map.new()
      |> Map.fetch!("data-props")
      |> JSON.decode!()

    assert_secret_free(data_props, :asset_data_props)

    assert_push_event(view, "asset:snapshot", snapshot)
    assert_secret_free(snapshot, :asset_snapshot_payload)

    calls = TestRuntimeApi.calls(runtime_api)
    assert Enum.any?(calls, &match?({:list_assets, _, _}, &1))
    assert Enum.any?(calls, &match?({:subscribe_assets, _}, &1))
  end

  test "upload token is confined to the grant reply and application JSON is secret-free", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    upload_token = "WEB_UPLOAD_TOKEN_CANARY_ad3f"
    csrf_token = "WEB_CSRF_TOKEN_CANARY_64c2"
    expires_at = DateTime.add(DateTime.utc_now(), 300, :second)

    grant = %UploadGrant{
      grant_id: @grant_id,
      asset_id: @asset_id,
      filename: "canary.pdf",
      byte_size: 5,
      declared_media_type: "application/pdf",
      classification: :private,
      expires_at: expires_at
    }

    TestRuntimeApi.put(
      runtime_api,
      :create_upload_grant,
      {:ok, upload_token, grant}
    )

    {:ok, view, _html} =
      conn
      |> put_connect_params(%{"_csrf_token" => csrf_token})
      |> live("/assets")

    reply =
      hook_reply(view, "upload:grant", %{
        "version" => 1,
        "filename" => "canary.pdf",
        "size" => 5,
        "mediaType" => "application/pdf",
        "idempotencyKey" => "secret-canary-upload"
      })

    assert_occurrence_paths(reply, upload_token, [[:uploadToken]], :upload_token_reply)
    assert_no_occurrences(reply, csrf_token, :csrf_grant_reply)

    assert Enum.any?(TestRuntimeApi.calls(runtime_api), fn
             {:create_upload_grant, _session, _attrs, ^csrf_token} -> true
             _other -> false
           end)

    handle = make_ref()
    TestRuntimeApi.put(runtime_api, :begin_upload, {:ok, handle})

    {upload_conn, issued_csrf} = put_issued_csrf(conn)

    response =
      upload_conn
      |> put_req_header("content-type", "application/pdf")
      |> put_req_header("content-length", "5")
      |> put_req_header("x-upload-token", upload_token)
      |> put_req_header("x-csrf-token", issued_csrf)
      |> put("/api/v1/uploads/#{@grant_id}", "%PDF-")

    response_surface = [response.resp_body, response.resp_headers]
    assert_secret_free(response_surface, :upload_application_response)
    assert_no_occurrences(response_surface, upload_token, :upload_token_application_response)
    assert_no_occurrences(response_surface, csrf_token, :live_view_csrf_application_response)
    assert_no_occurrences(response_surface, issued_csrf, :issued_csrf_application_response)

    assert_response_metadata(
      response,
      201,
      "application/json; charset=utf-8",
      :upload_application
    )

    application_json = JSON.decode!(response.resp_body)
    assert application_json["ok"]
    assert_no_occurrences(application_json, upload_token, :upload_token_application_json)
    assert_no_occurrences(application_json, csrf_token, :live_view_csrf_application_json)
    assert_no_occurrences(application_json, issued_csrf, :issued_csrf_application_json)
    assert_secret_free(application_json, :upload_application_json)
  end

  test "backup passphrase reaches one runtime call and is absent from logs and returned HTML", %{
    conn: conn,
    current_session: current_session,
    runtime_api: runtime_api
  } do
    TestRuntimeApi.put(runtime_api, :request_backup, {
      :ok,
      %BackupStatus{
        operation_id: @operation_id,
        status: :pending,
        requested_at: ~U[2026-08-10 08:00:00Z],
        updated_at: ~U[2026-08-10 08:00:01Z]
      }
    })

    {conn, csrf_token} = put_issued_csrf(conn)
    conn = update_in(conn.private, &Map.delete(&1, :plug_skip_csrf_protection))

    logs =
      capture_log(fn ->
        send(
          self(),
          {:backup_response,
           post(conn, "/backups", %{
             "_csrf_token" => csrf_token,
             "passphrase" => @canaries.backup_passphrase
           })}
        )
      end)

    assert_receive {:backup_response, response}
    backup_surface = [response.resp_body, response.resp_headers, logs]

    assert_secret_free(backup_surface, :backup_return)
    assert_no_occurrences(backup_surface, csrf_token, :backup_csrf_return)

    backup_location = get_resp_header(response, "location")
    if response.status != 302, do: flunk("backup redirect status mismatch")

    if backup_location != ["/backups?operation_id=#{@operation_id}"],
      do: flunk("backup redirect location mismatch")

    assert Enum.count(TestRuntimeApi.calls(runtime_api), fn
             {:request_backup, ^current_session, passphrase} ->
               passphrase == @canaries.backup_passphrase

             _other ->
               false
           end) == 1

    returned = response |> recycle() |> get(hd(backup_location))

    assert_secret_free(
      [returned.resp_body, returned.resp_headers],
      :returned_backup_response
    )

    assert_response_metadata(returned, 200, "text/html; charset=utf-8", :returned_backup)

    [password_input] =
      returned.resp_body
      |> Floki.parse_document!()
      |> Floki.find("#backup-passphrase")

    if Floki.attribute(password_input, "value") != [],
      do: flunk("returned backup passphrase value attribute was present")
  end

  test "note content is confined to authorized calls and never enters props, errors, or logs", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    title = "NOTE_TITLE_CANARY_4d2f"
    markdown = "# NOTE_MARKDOWN_CANARY_18aa"
    mutation_id = "019f9f65-acde-7a31-bf09-9238cb428704"

    TestRuntimeApi.put(runtime_api, :search_notes, {
      :ok,
      %NoteSearchPage{
        items: [
          %NoteSummary{
            resource_id: @asset_id,
            resource_version_id: @grant_id,
            title: title,
            revision: 0,
            display_version: 1,
            updated_at: ~U[2026-08-20 12:00:00Z],
            deleted?: false,
            open_conflict_count: 0
          }
        ],
        next_cursor: nil
      }
    })

    {:ok, view, html} = live(conn, "/notes")
    assert html =~ title
    refute html =~ markdown

    TestRuntimeApi.put(runtime_api, :create_note, {:error, :storage_unavailable})

    logs =
      capture_log(fn ->
        send(
          self(),
          {:note_reply,
           hook_reply(view, "note:create", %{
             "version" => 1,
             "mutationId" => mutation_id,
             "title" => title,
             "markdown" => markdown
           })}
        )
      end)

    assert_receive {:note_reply, reply}
    refute inspect(reply) =~ title
    refute inspect(reply) =~ markdown
    refute logs =~ title
    refute logs =~ markdown

    assert Enum.any?(TestRuntimeApi.calls(runtime_api), fn
             {:create_note, _session, %{title: ^title, markdown: ^markdown}} -> true
             _other -> false
           end)
  end

  defp assert_occurrence_paths(surface, canary, expected, label) do
    if occurrence_paths(surface, canary) != expected,
      do: flunk("#{label} occurrence path mismatch")
  end

  defp assert_no_occurrences(surface, canary, label) do
    count = length(occurrence_paths(surface, canary))
    if count != 0, do: flunk("#{label} retained secret occurrence count: #{count}")
  end

  defp hook_reply(view, event, payload) do
    _html = render_hook(view, event, payload)
    %{proxy: {ref, _topic, _target}} = view
    assert_receive {^ref, {:reply, reply}}
    reply
  end

  defp assert_secret_free(surface, label) do
    leaks =
      for {category, canary} <- @canaries,
          occurrence_paths(surface, canary) != [],
          do: category

    if leaks != [] do
      flunk("#{label} retained secret categories: #{inspect(leaks)}")
    end

    :ok
  end

  defp assert_response_metadata(response, expected_status, expected_content_type, label) do
    if response.status != expected_status, do: flunk("#{label} status mismatch")

    if get_resp_header(response, "content-type") != [expected_content_type],
      do: flunk("#{label} content type mismatch")
  end

  defp occurrence_paths(value, canary), do: occurrence_paths(value, canary, [])

  defp occurrence_paths(value, canary, path) when is_binary(value) do
    if String.contains?(value, canary), do: [path], else: []
  end

  defp occurrence_paths(%_{} = value, canary, path) do
    value
    |> Map.from_struct()
    |> occurrence_paths(canary, path)
  end

  defp occurrence_paths(value, canary, path) when is_map(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {{key, entry}, index} ->
      secret_bearing_key? = occurrence_paths(key, canary, []) != []
      key_occurrences = if secret_bearing_key?, do: [path ++ [{:map_key, index}]], else: []

      key_occurrences ++ occurrence_paths(entry, canary, path ++ [key])
    end)
  end

  defp occurrence_paths(value, canary, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, index} ->
      occurrence_paths(entry, canary, path ++ [index])
    end)
  end

  defp occurrence_paths(value, canary, path) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> occurrence_paths(canary, path)
  end

  defp occurrence_paths(_value, _canary, _path), do: []
end
