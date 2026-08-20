defmodule Singularity.Web.Router do
  use Phoenix.Router

  import Phoenix.Controller
  import Phoenix.LiveView.Router

  alias Singularity.Runtime.DTO.Session
  alias Singularity.Web.Auth

  @sensitive_parameter_keys [
    "password",
    :password,
    "passphrase",
    :passphrase,
    "token",
    :token,
    "csrf",
    :csrf,
    "csrf_token",
    :csrf_token,
    "_csrf_token",
    :_csrf_token,
    "upload_token",
    :upload_token,
    "x-csrf-token",
    :"x-csrf-token",
    "x-upload-token",
    :"x-upload-token"
  ]
  @sensitive_request_headers ["x-csrf-token", "x-upload-token"]

  pipeline :browser do
    plug :accepts, ["html"]

    plug Plug.Parsers,
      parsers: [:urlencoded],
      pass: ["application/x-www-form-urlencoded"],
      json_decoder: JSON

    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {Singularity.Web.Layouts, :root}
    plug :protect_from_forgery_with_safe_telemetry
    plug :put_secure_browser_headers
    plug Auth, :fetch_current_session
  end

  pipeline :browser_authenticated do
    plug :require_authenticated_with_safe_telemetry
  end

  pipeline :browser_vault_unlocked do
    plug :require_unlocked_with_safe_telemetry
  end

  pipeline :api_session do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :put_secure_browser_headers
    plug Auth, :fetch_current_session
  end

  pipeline :api_authenticated do
    plug Auth, :require_api_authenticated
  end

  pipeline :api_vault_unlocked do
    plug Auth, :require_api_unlocked
  end

  pipeline :private_no_store do
    plug :put_private_no_store
  end

  defp put_private_no_store(conn, _options),
    do: Plug.Conn.put_resp_header(conn, "cache-control", "no-store")

  defp protect_from_forgery_with_safe_telemetry(conn, options) do
    Phoenix.Controller.protect_from_forgery(conn, options)
  rescue
    exception in Plug.CSRFProtection.InvalidCSRFTokenError ->
      scrubbed_conn = scrub_sensitive_request(conn)

      Plug.Conn.WrapperError.reraise(
        scrubbed_conn,
        :error,
        exception,
        __STACKTRACE__
      )
  end

  defp require_authenticated_with_safe_telemetry(
         %{assigns: %{current_session: %Session{}}} = conn,
         options
       ),
       do: Auth.require_authenticated(conn, options)

  defp require_authenticated_with_safe_telemetry(conn, options) do
    conn
    |> register_secret_safe_before_send()
    |> Auth.require_authenticated(options)
    |> scrub_halted_request()
  end

  defp require_unlocked_with_safe_telemetry(
         %{assigns: %{current_session: %Session{unlocked?: true}}} = conn,
         options
       ),
       do: Auth.require_unlocked(conn, options)

  defp require_unlocked_with_safe_telemetry(conn, options) do
    conn
    |> register_secret_safe_before_send()
    |> Auth.require_unlocked(options)
    |> scrub_halted_request()
  end

  defp register_secret_safe_before_send(conn),
    do: Plug.Conn.register_before_send(conn, &scrub_sensitive_request/1)

  defp scrub_halted_request(%Plug.Conn{halted: true} = conn),
    do: scrub_sensitive_request(conn)

  defp scrub_halted_request(conn), do: conn

  defp scrub_sensitive_request(conn) do
    conn
    |> Map.update!(:body_params, &scrub_parameter_value/1)
    |> Map.update!(:params, &scrub_parameter_value/1)
    |> Map.update!(:query_params, &scrub_parameter_value/1)
    |> Map.update!(:path_params, &scrub_parameter_value/1)
    |> Map.update!(:req_headers, &scrub_request_headers/1)
    |> Map.update!(:adapter, &scrub_test_adapter/1)
    |> Map.put(:query_string, "")
  end

  defp scrub_parameter_value(%Plug.Conn.Unfetched{} = value), do: value
  defp scrub_parameter_value(value) when is_struct(value), do: value

  defp scrub_parameter_value(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested_value}, scrubbed ->
      if key in @sensitive_parameter_keys do
        scrubbed
      else
        Map.put(scrubbed, key, scrub_parameter_value(nested_value))
      end
    end)
  end

  defp scrub_parameter_value(value) when is_list(value),
    do: Enum.map(value, &scrub_parameter_value/1)

  defp scrub_parameter_value(value), do: value

  defp scrub_request_headers(headers),
    do: Enum.reject(headers, fn {name, _value} -> name in @sensitive_request_headers end)

  defp scrub_test_adapter({Plug.Adapters.Test.Conn, %{params: params} = state}) do
    state =
      state
      |> Map.put(:params, scrub_parameter_value(params))
      |> Map.put(:req_body, "")

    {Plug.Adapters.Test.Conn, state}
  end

  defp scrub_test_adapter(adapter), do: adapter

  scope "/", Singularity.Web do
    pipe_through :browser

    live_session :public do
      live "/login", LoginLive
    end

    post "/login", SessionController, :create
  end

  scope "/", Singularity.Web do
    pipe_through [:browser, :browser_authenticated]

    post "/vault/unlock", SessionController, :unlock
    delete "/logout", SessionController, :delete

    live_session :authenticated,
      on_mount: [{Auth, :require_authenticated}] do
      live "/vault/unlock", UnlockLive
    end
  end

  scope "/", Singularity.Web do
    pipe_through [
      :browser,
      :browser_authenticated,
      :browser_vault_unlocked
    ]

    post "/backups", BackupController, :create

    live_session :unlocked,
      on_mount: [
        {Auth, :require_authenticated},
        {Auth, :require_unlocked}
      ] do
      live "/assets", AssetsLive
      live "/activity", ActivityLive
      live "/audit", AuditLive
      live "/backups", BackupsLive
      live "/settings", SettingsLive
    end
  end

  scope "/api/v1", Singularity.Web do
    pipe_through [
      :api_session,
      :api_authenticated,
      :api_vault_unlocked
    ]

    put "/uploads/:grant_id", UploadController, :update
    get "/assets/:asset_id/content", DownloadController, :show
  end

  scope "/", Singularity.Web do
    pipe_through [
      :browser,
      :browser_authenticated,
      :browser_vault_unlocked,
      :private_no_store
    ]

    live_session :notes_unlocked,
      on_mount: [
        {Auth, :require_authenticated},
        {Auth, :require_unlocked}
      ] do
      live "/notes", NotesLive
    end
  end

  scope "/api/v1", Singularity.Web do
    pipe_through [
      :api_session,
      :api_authenticated,
      :api_vault_unlocked,
      :private_no_store
    ]

    get "/notes/:resource_id/export", NoteExportController, :show
  end
end
