defmodule Singularity.Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :singularity_web

  @session_options [
    store: :cookie,
    key: "_singularity_web_session",
    signing_salt: "web-session-signing",
    encryption_salt: "web-session-encryption",
    same_site: "Lax",
    http_only: true,
    secure: Mix.env() == :prod
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug Singularity.Web.Router
end
