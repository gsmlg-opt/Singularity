defmodule Singularity.Web.DownloadController do
  use Singularity.Web, :controller

  alias Singularity.Web.Auth

  @status_by_error %{
    invalid: 400,
    invalid_range: 400,
    unauthenticated: 401,
    forbidden: 403,
    vault_locked: 403,
    not_found: 404,
    conflict: 409,
    range_not_satisfiable: 416,
    storage_unavailable: 503
  }

  def show(conn, %{"asset_id" => asset_id}) do
    with {:ok, range_header} <- range_header(conn),
         {:ok, download} <-
           Auth.call_runtime(:download, [
             conn.assigns.current_session,
             asset_id,
             range_header
           ]) do
      send_runtime_download(conn, download)
    else
      {:error, code} when is_atom(code) -> error(conn, code)
      _invalid -> error(conn, :storage_unavailable)
    end
  end

  defp range_header(conn) do
    case get_req_header(conn, "range") do
      [] -> {:ok, nil}
      [value] -> {:ok, value}
      _ambiguous -> {:error, :invalid_range}
    end
  end

  defp send_runtime_download(conn, download) do
    conn =
      conn
      |> put_resp_content_type(download.detected_media_type, nil)
      |> put_resp_header("content-length", Integer.to_string(download.content_length))
      |> maybe_put_content_range(download)

    send_resp(conn, download.status, download.body)
  end

  defp maybe_put_content_range(conn, %{content_range: nil}), do: conn

  defp maybe_put_content_range(conn, %{content_range: content_range}),
    do: put_resp_header(conn, "content-range", content_range)

  defp error(conn, code) do
    status = Map.get(@status_by_error, code, 503)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(%{error: %{code: Atom.to_string(code)}}))
  end
end
