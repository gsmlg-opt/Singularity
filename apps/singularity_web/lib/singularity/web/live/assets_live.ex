defmodule Singularity.Web.AssetsLive do
  use Singularity.Web, :live_view

  alias Singularity.Runtime.DTO.SearchPage
  alias Singularity.Web.Auth

  @impl true
  def mount(_params, _session, socket) do
    result =
      Auth.call_runtime(:list_assets, [
        socket.assigns.current_session,
        %{}
      ])

    case result do
      {:ok, %SearchPage{items: items} = page} ->
        {:ok,
         Phoenix.Component.assign(socket,
           assets: items,
           next_cursor: page.next_cursor,
           page_title: "Assets"
         )}

      _error ->
        {:ok,
         Phoenix.Component.assign(socket,
           assets: [],
           next_cursor: nil,
           page_title: "Assets"
         )}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page title="Assets">
      <p :if={@assets == []}>No assets yet.</p>
      <ul :if={@assets != []}>
        <li :for={asset <- @assets}>
          <strong>{asset.title || asset.original_filename}</strong>
          <span>{asset.original_filename}</span>
          <span>{asset.state}</span>
        </li>
      </ul>
    </.page>
    """
  end
end
