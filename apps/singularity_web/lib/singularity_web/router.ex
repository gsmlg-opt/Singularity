defmodule SingularityWeb.Router do
  use SingularityWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SingularityWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
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
    live "/sources", SourceLive.Index, :index
    live "/sources/new", SourceLive.Form, :new
    live "/sources/:id/edit", SourceLive.Form, :edit
    live "/sources/:id", SourceLive.Show, :show
  end

  # Other scopes may use custom stacks.
  # scope "/api", SingularityWeb do
  #   pipe_through :api
  # end
end
