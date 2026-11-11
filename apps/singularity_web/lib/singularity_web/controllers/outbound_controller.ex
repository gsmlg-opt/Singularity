defmodule SingularityWeb.OutboundController do
  @moduledoc "The confirmation page shown before leaving the site; it never redirects by itself."
  use SingularityWeb, :controller
  use Gettext, backend: SingularityWeb.Gettext

  alias SingularityWeb.Outbound

  def show(conn, params) do
    to = params["to"]
    back = back_path(conn)
    conn = put_resp_header(conn, "referrer-policy", "no-referrer")
    title = gettext("Leaving Singularity")

    if Outbound.web?(to) do
      render(conn, :show, to: to, host: URI.parse(to).host, back: back, page_title: title)
    else
      conn
      |> put_status(:bad_request)
      |> render(:invalid, back: back, page_title: title)
    end
  end

  # Only a page of this site is a place to go back to.
  defp back_path(conn) do
    with [referer | _] <- get_req_header(conn, "referer"),
         %URI{host: host, path: "/" <> _ = path} = uri <- URI.parse(referer),
         true <- host == conn.host do
      if uri.query, do: path <> "?" <> uri.query, else: path
    else
      _other -> "/"
    end
  end
end
