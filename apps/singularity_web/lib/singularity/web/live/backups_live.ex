defmodule Singularity.Web.BackupsLive do
  use Singularity.Web, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.page title="Backups">
      <p>Backup controls.</p>
    </.page>
    """
  end
end
