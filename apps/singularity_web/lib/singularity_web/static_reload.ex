defmodule SingularityWeb.StaticReload do
  @moduledoc """
  Reloads the page when a deploy changed the tracked static assets.

  A page opened before a deploy keeps its old stylesheet across live
  navigation, so new templates render with missing classes. LiveView only
  reports the change (`static_changed?/1`, readable in mount); this hook turns
  it into a full page load of the same URL.
  """
  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    if static_changed?(socket) do
      {:cont,
       attach_hook(socket, :static_reload, :handle_params, fn _params, uri, socket ->
         {:halt, redirect(socket, external: uri)}
       end)}
    else
      {:cont, socket}
    end
  end
end
