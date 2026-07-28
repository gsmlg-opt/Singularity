defmodule Singularity.Web.UnlockLive do
  use Singularity.Web, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, Phoenix.Component.assign(socket, page_title: "Unlock vault")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page title="Unlock vault">
      <form action="/vault/unlock" method="post">
        <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
        <label>
          Password <input name="password" type="password" autocomplete="current-password" required />
        </label>
        <button type="submit">Unlock</button>
      </form>
    </.page>
    """
  end
end
