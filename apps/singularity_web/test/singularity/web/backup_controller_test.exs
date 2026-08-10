defmodule Singularity.Web.BackupControllerTest do
  use Singularity.Web.ConnCase, async: false

  alias Singularity.Runtime.DTO.BackupStatus

  @operation_id "019f9f24-7aef-7aa4-b970-7ed3cabfc101"
  @passphrase_canary "BACKUP_PASSPHRASE_CANARY_65dc"
  @failure_message "Encrypted backup could not be requested."

  setup %{conn: conn, runtime_api: runtime_api} do
    current_session = session(true)

    TestRuntimeApi.put(runtime_api, :sessions, %{
      "opaque-session" => {:ok, current_session}
    })

    {:ok, conn: put_session_id(conn, "opaque-session"), current_session: current_session}
  end

  test "authenticated unlocked submission calls the public runtime boundary and redirects by UUID only",
       %{conn: conn, runtime_api: runtime_api, current_session: current_session} do
    TestRuntimeApi.put(runtime_api, :request_backup, {:ok, backup_status(:pending)})

    response = post_backup(conn, @passphrase_canary)

    assert redirected_to(response) == "/backups?operation_id=#{@operation_id}"

    assert TestRuntimeApi.calls(runtime_api) == [
             {:resolve_session, "opaque-session"},
             {:request_backup, current_session, @passphrase_canary}
           ]

    refute response.resp_body =~ @passphrase_canary
    refute redirected_to(response) =~ @passphrase_canary
  end

  test "same-origin CSRF rejection happens before the runtime request", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    passphrase_canary = "INVALID_CSRF_PASSPHRASE_CANARY_366e"
    body_csrf_canary = "INVALID_CSRF_BODY_CANARY_218d"
    query_passphrase_canary = "INVALID_CSRF_QUERY_PASSPHRASE_CANARY_900c"
    query_csrf_canary = "INVALID_CSRF_QUERY_CSRF_CANARY_283f"
    telemetry = attach_backup_telemetry()

    conn = update_in(conn.private, &Map.delete(&1, :plug_skip_csrf_protection))

    query =
      URI.encode_query(%{
        "passphrase" => query_passphrase_canary,
        "_csrf_token" => query_csrf_canary
      })

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      post(conn, "/backups?#{query}", %{
        "_csrf_token" => body_csrf_canary,
        "passphrase" => passphrase_canary
      })
    end

    observed = drain_backup_telemetry(telemetry.tag)
    observed_events = MapSet.new(observed, &elem(&1, 0))

    assert [:phoenix, :endpoint, :stop] in observed_events
    assert [:phoenix, :error_rendered] in observed_events

    assert_secret_free_telemetry(observed, [
      passphrase_canary,
      body_csrf_canary,
      query_passphrase_canary,
      query_csrf_canary
    ])

    assert TestRuntimeApi.calls(runtime_api) == []
  end

  test "Phoenix stop telemetry receives no submitted secret parameters", %{
    conn: conn,
    runtime_api: runtime_api,
    current_session: current_session
  } do
    passphrase_canary = "TELEMETRY_PASSPHRASE_CANARY_64ee"
    query_passphrase_canary = "TELEMETRY_QUERY_PASSPHRASE_CANARY_13bc"
    query_csrf_canary = "TELEMETRY_QUERY_CSRF_CANARY_981a"
    events = [[:phoenix, :router_dispatch, :stop], [:phoenix, :endpoint, :stop]]
    handler_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event, _measurements, metadata, owner ->
          send(owner, {:backup_stop_telemetry, event, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    TestRuntimeApi.put(runtime_api, :request_backup, {:ok, backup_status(:pending)})

    {conn, csrf_canary} = put_issued_csrf(conn)
    conn = update_in(conn.private, &Map.delete(&1, :plug_skip_csrf_protection))

    query =
      URI.encode_query(%{
        "passphrase" => query_passphrase_canary,
        "_csrf_token" => query_csrf_canary
      })

    response =
      post(conn, "/backups?#{query}", %{
        "_csrf_token" => csrf_canary,
        "passphrase" => passphrase_canary
      })

    assert redirected_to(response) == "/backups?operation_id=#{@operation_id}"

    assert TestRuntimeApi.calls(runtime_api) == [
             {:resolve_session, "opaque-session"},
             {:request_backup, current_session, passphrase_canary}
           ]

    metadata_by_event =
      Enum.reduce(events, %{}, fn _event, observed ->
        assert_receive {:backup_stop_telemetry, event, metadata}
        Map.put(observed, event, metadata)
      end)

    canaries = [passphrase_canary, csrf_canary, query_passphrase_canary, query_csrf_canary]

    for event <- events do
      assert %{conn: telemetry_conn} = Map.fetch!(metadata_by_event, event)

      for field <- [:body_params, :params, :query_params, :path_params] do
        params = Map.fetch!(telemetry_conn, field)
        serialized = inspect(params, limit: :infinity, printable_limit: :infinity)
        refute Enum.any?(canaries, &String.contains?(serialized, &1))
      end

      leaking_fields =
        telemetry_conn
        |> Map.from_struct()
        |> Enum.filter(fn {_field, value} ->
          serialized = inspect(value, limit: :infinity, printable_limit: :infinity)
          Enum.any?(canaries, &String.contains?(serialized, &1))
        end)
        |> Enum.map(&elem(&1, 0))

      assert leaking_fields == []
      refute telemetry_conn.query_string =~ query_passphrase_canary
      refute telemetry_conn.query_string =~ query_csrf_canary
    end
  end

  test "missing and expired sessions follow authentication without requesting a backup", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    missing = post(build_conn(), "/backups", %{"passphrase" => @passphrase_canary})
    assert redirected_to(missing) == "/login"

    TestRuntimeApi.put(runtime_api, :sessions, %{
      "expired-session" => {:error, :unauthenticated}
    })

    expired =
      conn
      |> put_session_id("expired-session")
      |> post("/backups", %{"passphrase" => @passphrase_canary})

    assert redirected_to(expired) == "/login"

    refute Enum.any?(
             TestRuntimeApi.calls(runtime_api),
             &match?({:request_backup, _, _}, &1)
           )
  end

  test "locked vault follows the unlock flow without requesting a backup", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    TestRuntimeApi.put(runtime_api, :sessions, %{
      "locked-session" => {:ok, session(false)}
    })

    response =
      conn
      |> put_session_id("locked-session")
      |> post("/backups", %{"passphrase" => @passphrase_canary})

    assert redirected_to(response) == "/vault/unlock"

    refute Enum.any?(
             TestRuntimeApi.calls(runtime_api),
             &match?({:request_backup, _, _}, &1)
           )
  end

  test "failure is stable and secret-free outside the one intentional runtime call", %{
    conn: conn,
    runtime_api: runtime_api,
    current_session: current_session
  } do
    TestRuntimeApi.put(runtime_api, :request_backup, {:error, :storage_unavailable})

    response = post_backup(conn, @passphrase_canary)

    assert redirected_to(response) == "/backups"
    assert Phoenix.Flash.get(response.assigns.flash, :error) == @failure_message

    assert TestRuntimeApi.calls(runtime_api) == [
             {:resolve_session, "opaque-session"},
             {:request_backup, current_session, @passphrase_canary}
           ]

    safe_surfaces = [response.resp_body, redirected_to(response), inspect(response.assigns.flash)]
    refute Enum.any?(safe_surfaces, &String.contains?(&1, @passphrase_canary))

    returned = response |> recycle() |> get(redirected_to(response))
    html = html_response(returned, 200)
    document = Floki.parse_document!(html)

    assert [alert] = Floki.find(document, "[role='alert']")
    assert alert |> Floki.text() |> String.trim() == @failure_message
    refute html =~ @passphrase_canary

    assert [password_input] = Floki.find(document, "#backup-passphrase")
    assert Floki.attribute(password_input, "value") == []
  end

  test "missing or query-only passphrases never reach runtime and never repopulate the password",
       %{
         conn: conn,
         runtime_api: runtime_api
       } do
    for path <- ["/backups", "/backups?passphrase=#{@passphrase_canary}"] do
      response = post(conn, path, %{})

      assert redirected_to(response) == "/backups"
      assert Phoenix.Flash.get(response.assigns.flash, :error) == @failure_message
      refute response.resp_body =~ @passphrase_canary
      refute redirected_to(response) =~ @passphrase_canary
    end

    refute Enum.any?(
             TestRuntimeApi.calls(runtime_api),
             &match?({:request_backup, _, _}, &1)
           )
  end

  test "internal manifest maps and malformed public DTOs are never accepted", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    internal = %{
      operation_id: @operation_id,
      status: :sealed,
      destination_ref: "/private/backups/manifest.bundle",
      manifest: %{objects: ["secret"]}
    }

    malformed_dto = %{backup_status(:sealed) | operation_id: "not-a-uuid"}

    for result <- [{:ok, internal}, {:ok, malformed_dto}] do
      TestRuntimeApi.put(runtime_api, :request_backup, result)
      response = post_backup(conn, @passphrase_canary)

      assert redirected_to(response) == "/backups"
      assert Phoenix.Flash.get(response.assigns.flash, :error) == @failure_message
      refute response.resp_body =~ "/private/backups"
      refute response.resp_body =~ "manifest"
    end
  end

  test "malformed, raised, and thrown runtime results share one generic failure", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    results = [
      :malformed,
      {:ok, nil},
      {:test_raise, RuntimeError.exception("BACKUP_INTERNAL_DETAIL")},
      {:test_throw, {:backup_internal, "BACKUP_INTERNAL_DETAIL"}}
    ]

    for result <- results do
      TestRuntimeApi.put(runtime_api, :request_backup, result)
      response = post_backup(conn, @passphrase_canary)

      assert redirected_to(response) == "/backups"
      assert Phoenix.Flash.get(response.assigns.flash, :error) == @failure_message
      refute response.resp_body =~ "BACKUP_INTERNAL_DETAIL"
      refute inspect(response.assigns.flash) =~ "BACKUP_INTERNAL_DETAIL"
    end
  end

  defp post_backup(conn, passphrase) do
    {conn, csrf_token} = put_issued_csrf(conn)
    conn = update_in(conn.private, &Map.delete(&1, :plug_skip_csrf_protection))

    post(conn, "/backups", %{
      "_csrf_token" => csrf_token,
      "passphrase" => passphrase
    })
  end

  defp attach_backup_telemetry do
    events = [
      [:phoenix, :router_dispatch, :stop],
      [:phoenix, :router_dispatch, :exception],
      [:phoenix, :endpoint, :stop],
      [:phoenix, :error_rendered]
    ]

    tag = make_ref()
    handler_id = {__MODULE__, self(), tag}

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event, _measurements, metadata, {owner, telemetry_tag} ->
          case metadata do
            %{conn: %Plug.Conn{method: "POST", request_path: "/backups"}} ->
              send(owner, {telemetry_tag, event, metadata})

            _other_request ->
              :ok
          end
        end,
        {self(), tag}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    %{tag: tag}
  end

  defp drain_backup_telemetry(tag, observed \\ []) do
    receive do
      {^tag, event, metadata} ->
        drain_backup_telemetry(tag, [{event, metadata} | observed])
    after
      0 -> Enum.reverse(observed)
    end
  end

  defp assert_secret_free_telemetry(observed, canaries) do
    assert observed != []

    for {event, metadata} <- observed do
      assert %{conn: %Plug.Conn{method: "POST", request_path: "/backups"}} = metadata
      serialized = inspect(metadata, limit: :infinity, printable_limit: :infinity)

      refute Enum.any?(canaries, &String.contains?(serialized, &1)),
             "#{inspect(event)} telemetry retained a submitted canary"
    end
  end

  defp backup_status(status) do
    %BackupStatus{
      operation_id: @operation_id,
      status: status,
      requested_at: ~U[2026-08-10 08:00:00Z],
      updated_at: ~U[2026-08-10 08:00:01Z]
    }
  end
end
