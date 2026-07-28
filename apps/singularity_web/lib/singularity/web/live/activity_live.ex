defmodule Singularity.Web.ActivityLive do
  use Singularity.Web, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.page title="Activity">
      <p>Activity overview.</p>
    </.page>
    """
  end
end
