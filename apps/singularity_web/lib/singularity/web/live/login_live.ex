defmodule Singularity.Web.LoginLive do
  use Singularity.Web, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, Phoenix.Component.assign(socket, page_title: "Sign in")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page title="Sign in">
      <form action="/login" method="post">
        <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
        <label>
          Login <input name="login" type="text" autocomplete="username" required />
        </label>
        <label>
          Password <input name="password" type="password" autocomplete="current-password" required />
        </label>
        <button type="submit">Sign in</button>
      </form>
    </.page>
    """
  end
end
