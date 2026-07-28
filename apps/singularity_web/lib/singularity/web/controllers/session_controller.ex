defmodule Singularity.Web.SessionController do
  use Singularity.Web, :controller

  alias Singularity.Runtime.DTO.Session
  alias Singularity.Web.Auth

  def create(conn, %{"login" => login, "password" => password})
      when is_binary(login) and is_binary(password) do
    request = %{
      login: login,
      password: password,
      source: request_source(conn)
    }

    case Auth.call_runtime(:login, [request]) do
      {:ok, opaque_id, %Session{} = session} ->
        conn
        |> Auth.put_opaque_session(opaque_id)
        |> redirect(to: next_path(session))

      _error ->
        redirect(conn, to: "/login")
    end
  end

  def create(conn, _params), do: redirect(conn, to: "/login")

  def unlock(
        %{assigns: %{current_session: %Session{} = session}} = conn,
        %{"password" => password}
      )
      when is_binary(password) do
    case Auth.call_runtime(:unlock, [session, password]) do
      {:ok, %Session{unlocked?: true}} -> redirect(conn, to: "/assets")
      _error -> redirect(conn, to: "/vault/unlock")
    end
  end

  def unlock(conn, _params), do: redirect(conn, to: "/vault/unlock")

  def delete(%{assigns: %{current_session: %Session{} = session}} = conn, _params) do
    _result = Auth.call_runtime(:logout, [session])

    conn
    |> Auth.clear_opaque_session()
    |> redirect(to: "/login")
  end

  def delete(conn, _params) do
    conn
    |> Auth.clear_opaque_session()
    |> redirect(to: "/login")
  end

  defp next_path(%Session{unlocked?: true}), do: "/assets"
  defp next_path(%Session{}), do: "/vault/unlock"

  defp request_source(%Plug.Conn{remote_ip: remote_ip}),
    do: remote_ip |> :inet.ntoa() |> to_string()
end
