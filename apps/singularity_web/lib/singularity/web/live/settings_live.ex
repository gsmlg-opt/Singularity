defmodule Singularity.Web.SettingsLive do
  use Singularity.Web, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.page title="Settings">
      <p>Vault settings.</p>
    </.page>
    """
  end
end
