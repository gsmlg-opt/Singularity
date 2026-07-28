defmodule Singularity.Web do
  @moduledoc "Web interface boundary; all application access goes through `Singularity.Runtime.Api`."

  def static_paths, do: []

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      import Plug.Conn
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      import Singularity.Web.CoreComponents
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView,
        layout: {Singularity.Web.Layouts, :app}

      import Plug.CSRFProtection, only: [get_csrf_token: 0]
      import Singularity.Web.CoreComponents
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: Singularity.Web.Endpoint,
        router: Singularity.Web.Router,
        statics: Singularity.Web.static_paths()
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
