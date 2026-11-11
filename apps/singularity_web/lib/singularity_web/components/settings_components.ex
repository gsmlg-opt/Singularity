defmodule SingularityWeb.SettingsComponents do
  @moduledoc """
  The layout of configuration pages (see DESIGN.md): one container with an
  optional list of entries on the left and the selected entry's panel on the
  right. The panel starts with a header card holding its actions; the data
  itself is edited in a modal form.
  """
  use Phoenix.Component

  import PhoenixDuskmoon.Component.Icon.Icons

  @doc """
  The configuration container. Pass `entries` (maps with `:id`, `:label`,
  `:icon` and `:to`) to list them on the left; leave it empty for single-entry
  pages.
  """
  attr :id, :string, required: true
  attr :title, :string, default: nil, doc: "heading of the entry list"
  attr :entries, :list, default: []
  attr :active, :string, default: nil, doc: "id of the selected entry"
  slot :inner_block, required: true

  def settings_container(assigns) do
    ~H"""
    <div
      id={@id}
      class="rounded-xl border border-outline-variant bg-surface-container-low p-4 lg:flex lg:gap-6"
    >
      <nav
        :if={@entries != []}
        class="mb-4 shrink-0 overflow-hidden rounded-lg border border-outline-variant bg-surface-container lg:mb-0 lg:w-60 lg:self-start"
        aria-label={@title}
      >
        <h2 :if={@title} class="border-b border-outline-variant px-4 py-3 text-lg font-semibold">
          {@title}
        </h2>
        <.link
          :for={entry <- @entries}
          id={"#{@id}-entry-#{entry.id}"}
          patch={entry.to}
          aria-current={entry.id == @active && "page"}
          class={[
            "flex items-center gap-2 px-4 py-2 text-sm font-medium no-underline",
            if(entry.id == @active,
              do: "bg-primary-container text-on-primary-container",
              else: "text-on-surface hover:bg-surface-container-high"
            )
          ]}
        >
          <.dm_mdi name={entry.icon} class="h-4 w-4" />{entry.label}
        </.link>
      </nav>
      <div class="min-w-0 flex-1 space-y-6">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc "The header card of a configuration panel: eyebrow, title, description and actions."
  attr :id, :string, required: true
  attr :eyebrow, :string, required: true
  attr :title, :string, required: true
  attr :icon, :string, default: nil
  slot :description
  slot :actions

  def settings_header(assigns) do
    ~H"""
    <section
      id={@id}
      class="rounded-lg border border-outline-variant bg-surface-container p-5 text-on-surface"
    >
      <div class="flex flex-wrap items-start gap-4">
        <div
          :if={@icon}
          class="flex h-12 w-12 shrink-0 items-center justify-center rounded-lg bg-primary-container text-on-primary-container"
        >
          <.dm_mdi name={@icon} class="h-7 w-7" />
        </div>
        <div class="min-w-0 flex-1 space-y-1">
          <p class="text-xs font-semibold text-on-surface-variant">{@eyebrow}</p>
          <h2 class="text-lg font-semibold">{@title}</h2>
          <div :if={@description != []} class="text-sm text-on-surface-variant">
            {render_slot(@description)}
          </div>
        </div>
        <div :if={@actions != []} class="flex flex-wrap items-center gap-2">
          {render_slot(@actions)}
        </div>
      </div>
    </section>
    """
  end
end
