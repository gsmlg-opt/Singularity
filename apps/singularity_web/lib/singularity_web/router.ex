defmodule SingularityWeb.Router do
  use SingularityWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SingularityWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :assign_theme
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", SingularityWeb do
    pipe_through :browser

    live "/", OverviewLive.Index, :index
    live "/overview/activity", OverviewLive.Activity, :index
    live "/knowledge", KnowledgeLive.Index, :index
    live "/knowledge/projects", KnowledgeLive.Index, :projects
    live "/knowledge/projects/:id", KnowledgeLive.Show, :show
    live "/source/sources", SourceLive.Index, :index
    live "/source/sources/new", SourceLive.Form, :new
    live "/source/sources/:id/edit", SourceLive.Form, :edit
    live "/source/sources/:id", SourceLive.Show, :show
    live "/source/add", SourceLive.Add, :new
    live "/source/runs", SourceLive.Runs, :index
    live "/system/accounts", SystemLive.Accounts, :show
    live "/system/accounts/:account", SystemLive.Accounts, :show
    live "/system/appearance", SystemLive.Appearance, :show
    live "/system/status", SystemLive.Status, :show
  end

  # Other scopes may use custom stacks.
  # scope "/api", SingularityWeb do
  #   pipe_through :api
  # end

  # The root layout renders `data-theme` from the chosen colour theme.
  defp assign_theme(conn, _opts), do: assign(conn, :theme, Singularity.Settings.theme())
end
