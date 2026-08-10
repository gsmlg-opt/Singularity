defmodule Singularity.Web.AuthenticationTest do
  use Singularity.Web.ConnCase, async: false

  describe "browser authentication" do
    test "unauthenticated routes redirect to login", %{conn: conn} do
      for path <- ~w(/vault/unlock /assets /activity /audit /backups /settings) do
        response = get(conn, path)
        assert redirected_to(response) == "/login"
      end
    end

    test "authenticated locked routes redirect to vault unlock", %{
      conn: conn,
      runtime_api: runtime_api
    } do
      TestRuntimeApi.put(runtime_api, :sessions, %{
        "opaque-session" => {:ok, session(false)}
      })

      for path <- ~w(/assets /activity /audit /backups /settings) do
        response = conn |> put_session_id("opaque-session") |> get(path)
        assert redirected_to(response) == "/vault/unlock"
      end
    end

    test "authenticated unlocked routes render the vault shell", %{
      conn: conn,
      runtime_api: runtime_api
    } do
      TestRuntimeApi.put(runtime_api, :sessions, %{
        "opaque-session" => {:ok, session(true)}
      })

      for path <- ~w(/assets /activity /audit /backups /settings) do
        response = conn |> put_session_id("opaque-session") |> get(path)
        assert html_response(response, 200) =~ "<main"
      end
    end

    test "backup POST follows the same authenticated and unlocked browser gates", %{
      conn: conn,
      runtime_api: runtime_api
    } do
      unauthenticated = post(build_conn(), "/backups", %{"passphrase" => "not-forwarded"})
      assert redirected_to(unauthenticated) == "/login"

      TestRuntimeApi.put(runtime_api, :sessions, %{
        "locked-session" => {:ok, session(false)},
        "unlocked-session" => {:ok, session(true)}
      })

      locked =
        conn
        |> put_session_id("locked-session")
        |> post("/backups", %{"passphrase" => "not-forwarded"})

      assert redirected_to(locked) == "/vault/unlock"

      unlocked =
        conn
        |> put_session_id("unlocked-session")
        |> post("/backups", %{"passphrase" => "forwarded-once"})

      assert redirected_to(unlocked) == "/backups"

      assert Enum.count(
               TestRuntimeApi.calls(runtime_api),
               &match?({:request_backup, _, "forwarded-once"}, &1)
             ) == 1

      refute Enum.any?(
               TestRuntimeApi.calls(runtime_api),
               &match?({:request_backup, _, "not-forwarded"}, &1)
             )
    end

    test "backup authentication redirects scrub submitted secrets before stop telemetry", %{
      conn: conn,
      runtime_api: runtime_api
    } do
      TestRuntimeApi.put(runtime_api, :sessions, %{
        "locked-session" => {:ok, session(false)}
      })

      passphrase_canary = "AUTH_REDIRECT_PASSPHRASE_CANARY_daae"
      body_csrf_canary = "AUTH_REDIRECT_BODY_CSRF_CANARY_c958"
      query_passphrase_canary = "AUTH_REDIRECT_QUERY_PASSPHRASE_CANARY_d4cd"
      query_csrf_canary = "AUTH_REDIRECT_QUERY_CSRF_CANARY_c89c"
      telemetry = attach_backup_stop_telemetry()

      query =
        URI.encode_query(%{
          "passphrase" => query_passphrase_canary,
          "_csrf_token" => query_csrf_canary
        })

      body = %{
        "_csrf_token" => body_csrf_canary,
        "passphrase" => passphrase_canary
      }

      for {request_conn, expected_redirect} <- [
            {build_conn(), "/login"},
            {put_session_id(conn, "locked-session"), "/vault/unlock"}
          ] do
        response = post(request_conn, "/backups?#{query}", body)
        assert redirected_to(response) == expected_redirect
      end

      observed = drain_backup_stop_telemetry(telemetry.tag)

      assert Enum.count(observed, &match?({[:phoenix, :router_dispatch, :stop], _}, &1)) ==
               2

      assert Enum.count(observed, &match?({[:phoenix, :endpoint, :stop], _}, &1)) == 2

      canaries = [
        passphrase_canary,
        body_csrf_canary,
        query_passphrase_canary,
        query_csrf_canary
      ]

      for {event, metadata} <- observed do
        assert %{conn: %Plug.Conn{method: "POST", request_path: "/backups"}} = metadata
        serialized = inspect(metadata, limit: :infinity, printable_limit: :infinity)

        refute Enum.any?(canaries, &String.contains?(serialized, &1)),
               "#{inspect(event)} telemetry retained a submitted canary"
      end

      refute Enum.any?(
               TestRuntimeApi.calls(runtime_api),
               &match?({:request_backup, _, _}, &1)
             )
    end

    test "login stores only the opaque session id and never renders credentials", %{
      conn: conn,
      runtime_api: runtime_api
    } do
      password = "PASSWORD_CANARY_84f4"

      TestRuntimeApi.put(
        runtime_api,
        :login,
        {:ok, "opaque-session", session(false)}
      )

      response =
        post(conn, "/login", %{
          "login" => "owner@example.test",
          "password" => password
        })

      assert redirected_to(response) == "/vault/unlock"
      assert get_session(response) == %{"session_id" => "opaque-session"}
      refute response.resp_body =~ password
      refute response.resp_body =~ "owner@example.test"

      assert Enum.any?(TestRuntimeApi.calls(runtime_api), fn
               {:login, attrs} ->
                 attrs.source == "127.0.0.1" and
                   not Map.has_key?(attrs, :correlation_id) and
                   not Map.has_key?(attrs, :request_id)

               _other ->
                 false
             end)
    end

    test "browser mutations reject missing CSRF before calling runtime", %{
      conn: conn,
      runtime_api: runtime_api
    } do
      conn =
        update_in(
          conn.private,
          &Map.delete(&1, :plug_skip_csrf_protection)
        )

      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        post(conn, "/login", %{
          "login" => "owner@example.test",
          "password" => "secret"
        })
      end

      refute Enum.any?(
               TestRuntimeApi.calls(runtime_api),
               &match?({:login, _attrs}, &1)
             )
    end

    test "logout revokes the resolved session and clears the cookie", %{
      conn: conn,
      runtime_api: runtime_api
    } do
      current_session = session(true)

      TestRuntimeApi.put(runtime_api, :sessions, %{
        "opaque-session" => {:ok, current_session}
      })

      response =
        conn
        |> put_session_id("opaque-session")
        |> delete("/logout")

      assert redirected_to(response) == "/login"
      assert get_session(response, "session_id") == nil

      assert Enum.any?(
               TestRuntimeApi.calls(runtime_api),
               &match?({:logout, ^current_session}, &1)
             )
    end

    test "unlock delegates the password and redirects only after runtime success", %{
      conn: conn,
      runtime_api: runtime_api
    } do
      locked_session = session(false)
      unlocked_session = %{locked_session | unlocked?: true}

      TestRuntimeApi.put(runtime_api, :sessions, %{
        "opaque-session" => {:ok, locked_session}
      })

      TestRuntimeApi.put(runtime_api, :unlock, {:ok, unlocked_session})

      {conn, csrf_token} =
        conn
        |> put_session_id("opaque-session")
        |> put_issued_csrf()

      response =
        conn
        |> update_in(
          [Access.key!(:private)],
          &Map.delete(&1, :plug_skip_csrf_protection)
        )
        |> post("/vault/unlock", %{
          "_csrf_token" => csrf_token,
          "password" => "unlock-password"
        })

      assert redirected_to(response) == "/assets"

      assert Enum.any?(
               TestRuntimeApi.calls(runtime_api),
               &match?({:unlock, ^locked_session, "unlock-password"}, &1)
             )
    end
  end

  describe "API authentication" do
    test "unauthenticated API requests return stable JSON and never redirect", %{conn: conn} do
      response = get(conn, "/api/v1/assets/asset-1/content")

      assert response.status == 401
      assert get_resp_header(response, "location") == []

      assert json_response(response, 401) == %{
               "error" => %{"code" => "unauthenticated"}
             }
    end

    test "locked API requests return stable JSON and never redirect", %{
      conn: conn,
      runtime_api: runtime_api
    } do
      TestRuntimeApi.put(runtime_api, :sessions, %{
        "opaque-session" => {:ok, session(false)}
      })

      response =
        conn
        |> put_session_id("opaque-session")
        |> get("/api/v1/assets/asset-1/content")

      assert response.status == 403
      assert get_resp_header(response, "location") == []

      assert json_response(response, 403) == %{
               "error" => %{"code" => "vault_locked"}
             }
    end
  end

  defp attach_backup_stop_telemetry do
    tag = make_ref()
    handler_id = {__MODULE__, self(), tag}

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:phoenix, :router_dispatch, :stop], [:phoenix, :endpoint, :stop]],
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

  defp drain_backup_stop_telemetry(tag, observed \\ []) do
    receive do
      {^tag, event, metadata} ->
        drain_backup_stop_telemetry(tag, [{event, metadata} | observed])
    after
      0 -> Enum.reverse(observed)
    end
  end
end
