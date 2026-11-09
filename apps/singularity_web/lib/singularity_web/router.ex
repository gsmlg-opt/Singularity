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

    live "/", ItemLive.Index, :index
    live "/items/:id", ItemLive.Show, :show
  end

  # Other scopes may use custom stacks.
  # scope "/api", SingularityWeb do
  #   pipe_through :api
  # end
end
