defmodule Singularity.Web.Auth do
  @moduledoc false

  import Phoenix.Controller
  import Plug.Conn

  alias Phoenix.LiveView.Socket
  alias Singularity.Runtime.DTO.Session

  @session_key "session_id"
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

  def init(action) when is_atom(action), do: action
  def call(conn, action) when is_atom(action), do: apply(__MODULE__, action, [conn, []])

  def fetch_current_session(conn, _options) do
    assign(conn, :current_session, resolve_session(get_session(conn, @session_key)))
  end

  def require_authenticated(%{assigns: %{current_session: %Session{}}} = conn, _options),
    do: conn

  def require_authenticated(conn, _options) do
    conn
    |> scrub_sensitive_request()
    |> redirect(to: "/login")
    |> halt()
  end

  def require_unlocked(
        %{assigns: %{current_session: %Session{unlocked?: true}}} = conn,
        _options
      ),
      do: conn

  def require_unlocked(conn, _options) do
    conn
    |> scrub_sensitive_request()
    |> redirect(to: "/vault/unlock")
    |> halt()
  end

  @doc false
  def scrub_sensitive_request(%Plug.Conn{} = conn) do
    conn
    |> Map.update!(:body_params, &scrub_parameter_map/1)
    |> Map.update!(:params, &scrub_parameter_map/1)
    |> Map.update!(:query_params, &scrub_parameter_map/1)
    |> Map.update!(:path_params, &scrub_parameter_map/1)
    |> Map.update!(:adapter, &scrub_test_adapter/1)
    |> Map.put(:query_string, "")
  end

  def require_api_authenticated(
        %{assigns: %{current_session: %Session{}}} = conn,
        _options
      ),
      do: conn

  def require_api_authenticated(conn, _options),
    do: api_error(conn, 401, :unauthenticated)

  def require_api_unlocked(
        %{assigns: %{current_session: %Session{unlocked?: true}}} = conn,
        _options
      ),
      do: conn

  def require_api_unlocked(conn, _options),
    do: api_error(conn, 403, :vault_locked)

  def verify_api_csrf(conn, _options) do
    with [csrf_token] <- get_req_header(conn, "x-csrf-token"),
         csrf_state when is_binary(csrf_state) <- get_session(conn, "_csrf_token"),
         true <-
           Plug.CSRFProtection.valid_state_and_csrf_token?(
             csrf_state,
             csrf_token
           ) do
      assign(conn, :csrf_token, csrf_token)
    else
      _invalid -> api_error(conn, 403, :csrf_failed)
    end
  end

  def api_error(conn, status, code) when is_integer(status) and is_atom(code),
    do: send_api_error(conn, status, code)

  def put_opaque_session(conn, opaque_id)
      when is_binary(opaque_id) and byte_size(opaque_id) > 0 do
    put_session(conn, @session_key, opaque_id)
  end

  def clear_opaque_session(conn), do: delete_session(conn, @session_key)

  def call_runtime(function, arguments) when is_atom(function) and is_list(arguments) do
    case Application.fetch_env!(:singularity_web, :runtime_api) do
      module when is_atom(module) ->
        apply(module, function, arguments)

      {module, context} when is_atom(module) ->
        apply(module, function, [context | arguments])
    end
  end

  def on_mount(:require_authenticated, _params, live_session, socket) do
    case resolved_live_session(live_session) do
      %Session{} = current_session ->
        {:cont, Phoenix.Component.assign(socket, :current_session, current_session)}

      nil ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}
    end
  end

  def on_mount(:require_unlocked, _params, _live_session, %Socket{} = socket) do
    case socket.assigns do
      %{current_session: %Session{unlocked?: true}} ->
        {:cont, socket}

      %{current_session: %Session{}} ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/vault/unlock")}

      _missing ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}
    end
  end

  defp resolved_live_session(%{@session_key => opaque_id}),
    do: resolve_session(opaque_id)

  defp resolved_live_session(_live_session), do: nil

  defp resolve_session(opaque_id) when is_binary(opaque_id) do
    case call_runtime(:resolve_session, [opaque_id]) do
      {:ok, %Session{} = session} -> session
      _error -> nil
    end
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp resolve_session(_opaque_id), do: nil

  defp scrub_parameter_map(%Plug.Conn.Unfetched{} = params), do: params
  defp scrub_parameter_map(nil), do: nil

  defp scrub_parameter_map(params) when is_map(params),
    do: Map.drop(params, @sensitive_parameter_keys)

  defp scrub_test_adapter({Plug.Adapters.Test.Conn, %{params: params} = state}) do
    state =
      state
      |> Map.put(:params, scrub_parameter_map(params))
      |> Map.put(:req_body, "")

    {Plug.Adapters.Test.Conn, state}
  end

  defp scrub_test_adapter(adapter), do: adapter

  defp send_api_error(conn, status, code) do
    body = JSON.encode!(%{error: %{code: Atom.to_string(code)}})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end
end
