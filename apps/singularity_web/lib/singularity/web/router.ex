defmodule Singularity.Web.Router do
  use Phoenix.Router

  import Phoenix.Controller
  import Phoenix.LiveView.Router

  alias Singularity.Web.Auth

  pipeline :browser do
    plug :accepts, ["html"]

    plug Plug.Parsers,
      parsers: [:urlencoded],
      pass: ["application/x-www-form-urlencoded"],
      json_decoder: JSON

    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {Singularity.Web.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug Auth, :fetch_current_session
  end

  pipeline :browser_authenticated do
    plug Auth, :require_authenticated
  end

  pipeline :browser_vault_unlocked do
    plug Auth, :require_unlocked
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
end
