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
    conn = update_in(conn.private, &Map.delete(&1, :plug_skip_csrf_protection))

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      post(conn, "/backups", %{"passphrase" => @passphrase_canary})
    end

    refute Enum.any?(
             TestRuntimeApi.calls(runtime_api),
             &match?({:request_backup, _, _}, &1)
           )
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

  defp backup_status(status) do
    %BackupStatus{
      operation_id: @operation_id,
      status: status,
      requested_at: ~U[2026-08-10 08:00:00Z],
      updated_at: ~U[2026-08-10 08:00:01Z]
    }
  end
end
