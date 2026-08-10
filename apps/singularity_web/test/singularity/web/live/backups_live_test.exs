defmodule Singularity.Web.BackupsLiveTest do
  use Singularity.Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Singularity.Runtime.DTO.BackupStatus

  @operation_id "019f9f24-7aef-7aa4-b970-7ed3cabfc101"
  @other_operation_id "019f9f24-7aef-7aa4-b970-7ed3cabfc102"
  @passphrase_canary "BACKUP_PASSPHRASE_CANARY_65dc"

  setup %{conn: conn, runtime_api: runtime_api} do
    current_session = session(true)

    TestRuntimeApi.put(runtime_api, :sessions, %{
      "opaque-session" => {:ok, current_session}
    })

    {:ok, conn: put_session_id(conn, "opaque-session"), current_session: current_session}
  end

  test "renders an ordinary same-origin secret-free POST form with Phoenix CSRF", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    {:ok, view, html} = live(conn, "/backups")
    document = Floki.parse_document!(html)

    assert [{"form", form_attrs, _children}] = Floki.find(document, "form[action='/backups']")
    assert {"method", "post"} in form_attrs
    refute Enum.any?(form_attrs, fn {name, _value} -> name == "phx-submit" end)

    assert [{"input", csrf_attrs, []}] = Floki.find(document, "input[name='_csrf_token']")
    assert {"type", "hidden"} in csrf_attrs
    assert csrf_attrs |> attribute!("value") |> String.trim() != ""

    assert [{"input", passphrase_attrs, []}] = Floki.find(document, "#backup-passphrase")
    assert {"name", "passphrase"} in passphrase_attrs
    assert {"type", "password"} in passphrase_attrs
    assert {"autocomplete", "new-password"} in passphrase_attrs
    assert Enum.any?(passphrase_attrs, fn {name, _value} -> name == "required" end)
    refute Enum.any?(passphrase_attrs, fn {name, _value} -> name == "value" end)

    assert has_element?(view, "button[type='submit']", "Create encrypted backup")
    refute html =~ @passphrase_canary
    refute html =~ "phx-submit"

    %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)
    refute Map.has_key?(assigns, :passphrase)
    refute inspect(assigns) =~ @passphrase_canary

    refute Enum.any?(
             TestRuntimeApi.calls(runtime_api),
             &match?({:backup_status, _, _}, &1)
           )
  end

  test "reads status only through the public runtime call with the current session", %{
    conn: conn,
    runtime_api: runtime_api,
    current_session: current_session
  } do
    TestRuntimeApi.put(runtime_api, :backup_status, {:ok, backup_status(:sealed)})

    response = get(conn, "/backups?operation_id=#{@operation_id}")
    html = html_response(response, 200)

    assert html =~ "Encrypted backup sealed."
    assert backup_status_calls(runtime_api) == [{:backup_status, current_session, @operation_id}]

    assert Enum.count(
             TestRuntimeApi.calls(runtime_api),
             &match?({:resolve_session, "opaque-session"}, &1)
           ) == 2

    refute html =~ "valid"
  end

  test "renders every in-progress state without claiming completion", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    expected = [
      pending: "Encrypted backup is pending.",
      waiting_for_backup_key: "Encrypted backup is waiting for its backup key.",
      copying: "Encrypted backup is being copied."
    ]

    for {status, message} <- expected do
      TestRuntimeApi.put(runtime_api, :backup_status, {:ok, backup_status(status)})
      html = conn |> get("/backups?operation_id=#{@operation_id}") |> html_response(200)

      assert html =~ message
      refute html =~ "Encrypted backup sealed."
      refute html =~ "valid"
    end
  end

  test "connected polling is bounded and rejects duplicate, stale, and out-of-range messages", %{
    conn: conn,
    runtime_api: runtime_api,
    current_session: current_session
  } do
    pending = {:ok, backup_status(:pending)}
    TestRuntimeApi.put_sequence(runtime_api, :backup_status, List.duplicate(pending, 5))

    {:ok, view, html} = live(conn, "/backups?operation_id=#{@operation_id}")
    assert html =~ "Encrypted backup is pending."

    %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)
    generation = assigns.backup_poll_generation

    send(view.pid, {:backup_status_poll, make_ref(), 1})
    send(view.pid, {:backup_status_poll, generation, 2})
    send(view.pid, {:backup_status_poll, generation, 1})
    _html = render(view)

    send(view.pid, {:backup_status_poll, generation, 1})
    send(view.pid, {:backup_status_poll, generation, 2})
    send(view.pid, {:backup_status_poll, generation, 3})
    _html = render(view)

    calls = backup_status_calls(runtime_api)

    assert calls == [
             {:backup_status, current_session, @operation_id},
             {:backup_status, current_session, @operation_id},
             {:backup_status, current_session, @operation_id},
             {:backup_status, current_session, @operation_id},
             {:backup_status, current_session, @operation_id}
           ]

    send(view.pid, {:backup_status_poll, generation, 3})
    send(view.pid, {:backup_status_poll, generation, 4})
    _html = render(view)
    assert backup_status_calls(runtime_api) == calls
  end

  test "polling moves through each progress state and stops at sealed", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    TestRuntimeApi.put_sequence(runtime_api, :backup_status, [
      {:ok, backup_status(:pending)},
      {:ok, backup_status(:pending)},
      {:ok, backup_status(:waiting_for_backup_key)},
      {:ok, backup_status(:copying)},
      {:ok, backup_status(:sealed)}
    ])

    {:ok, view, _html} = live(conn, "/backups?operation_id=#{@operation_id}")
    %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)
    generation = assigns.backup_poll_generation

    send(view.pid, {:backup_status_poll, generation, 1})
    assert render(view) =~ "Encrypted backup is waiting for its backup key."

    send(view.pid, {:backup_status_poll, generation, 2})
    assert render(view) =~ "Encrypted backup is being copied."

    send(view.pid, {:backup_status_poll, generation, 3})
    html = render(view)
    assert html =~ "Encrypted backup sealed."
    refute html =~ "valid"

    calls = backup_status_calls(runtime_api)
    send(view.pid, {:backup_status_poll, generation, 4})
    _html = render(view)
    assert backup_status_calls(runtime_api) == calls
  end

  test "failed backup renders the exact stable terminal failure and stops", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    TestRuntimeApi.put(runtime_api, :backup_status, {:ok, backup_status(:failed)})
    {:ok, view, html} = live(conn, "/backups?operation_id=#{@operation_id}")

    assert html =~ "Encrypted backup could not be completed."
    refute html =~ "valid"

    calls = backup_status_calls(runtime_api)
    %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)
    send(view.pid, {:backup_status_poll, assigns.backup_poll_generation, 1})
    _html = render(view)
    assert backup_status_calls(runtime_api) == calls
  end

  test "missing and cross-vault not-found results are indistinguishable", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    missing_html = conn |> get("/backups") |> html_response(200)

    TestRuntimeApi.put(runtime_api, :backup_status, {:error, :not_found})

    cross_vault_html =
      conn
      |> get("/backups?operation_id=#{@other_operation_id}")
      |> html_response(200)

    assert status_text(missing_html) == "Backup operation was not found."
    assert status_text(cross_vault_html) == status_text(missing_html)
    refute cross_vault_html =~ @other_operation_id
  end

  test "malformed operation IDs are not sent to runtime and match not-found output", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    missing_html = conn |> get("/backups") |> html_response(200)
    malformed_html = conn |> get("/backups?operation_id=not-a-uuid") |> html_response(200)

    assert status_text(malformed_html) == status_text(missing_html)

    refute Enum.any?(
             TestRuntimeApi.calls(runtime_api),
             &match?({:backup_status, _, _}, &1)
           )
  end

  test "storage errors and non-DTO internals render one stable detail-free status", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    results = [
      {:error, {:storage_unavailable, "/private/backups/manifest.bundle"}},
      {:ok,
       %{
         operation_id: @operation_id,
         status: :sealed,
         destination_ref: "/private/backups/manifest.bundle"
       }},
      {:test_raise, RuntimeError.exception("/private/backups/manifest.bundle")},
      {:test_throw, {:storage, "/private/backups/manifest.bundle"}}
    ]

    for result <- results do
      TestRuntimeApi.put(runtime_api, :backup_status, result)

      html = conn |> get("/backups?operation_id=#{@operation_id}") |> html_response(200)

      assert status_text(html) == "Backup status is unavailable."
      refute html =~ "/private/backups"
      refute html =~ "manifest.bundle"
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

  defp backup_status_calls(runtime_api) do
    Enum.filter(
      TestRuntimeApi.calls(runtime_api),
      &match?({:backup_status, _, _}, &1)
    )
  end

  defp status_text(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("#backup-status")
    |> Floki.text()
    |> String.trim()
  end

  defp attribute!(attributes, name) do
    {^name, value} = List.keyfind(attributes, name, 0)
    value
  end
end
