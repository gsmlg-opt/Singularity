defmodule SingularityWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use SingularityWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true
  attr :current, :atom, default: nil
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen flex">
      <nav class="w-48 shrink-0 border-r border-outline-variant p-4 space-y-2" aria-label="主导航">
        <div class="text-lg font-semibold mb-4">Singularity</div>
        <.link navigate={~p"/"} id="nav-items" class={nav_class(@current == :items)}>条目</.link>
        <.link navigate="/sources" id="nav-sources" class={nav_class(@current == :sources)}>来源</.link>
      </nav>
      <main class="flex-1 p-6 space-y-4 min-w-0">
        <.dm_flash_group flash={@flash} />
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end

  defp nav_class(true), do: "block rounded px-3 py-2 bg-primary text-primary-content"
  defp nav_class(false), do: "block rounded px-3 py-2 hover:bg-surface-container"
end
