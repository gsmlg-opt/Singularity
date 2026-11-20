defmodule SingularityWeb.KnowledgeSearch do
  @moduledoc "Search toolbar for the knowledge indexes. The LiveView owns the URL and filters."
  use SingularityWeb, :html

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :icon, :string, required: true
  attr :count_id, :string, required: true
  attr :count_text, :string, required: true
  attr :query, :string, required: true
  attr :placeholder, :string, required: true
  attr :reset_path, :string, required: true
  attr :label, :string, required: true
  attr :clear_label_path, :string, required: true
  slot :filters

  def search_toolbar(assigns) do
    ~H"""
    <header class="flex flex-wrap items-center justify-between gap-3">
      <div class="flex items-center gap-3">
        <span class="grid size-10 shrink-0 place-items-center rounded-lg bg-tertiary-container text-on-tertiary-container">
          <.dm_mdi name={@icon} class="size-5" aria-hidden="true" />
        </span>
        <h1 class="text-2xl font-bold">{@title}</h1>
      </div>
      <div class="flex flex-wrap items-center gap-3">
        <.link
          :if={@reset_path}
          id={"reset-#{@id}"}
          patch={@reset_path}
          class="inline-flex items-center gap-1 rounded px-2 py-1 text-sm font-medium hover:underline focus-visible:outline-2"
        >
          <.dm_mdi name="restore" class="size-4" aria-hidden="true" />
          {dgettext("knowledge", "Reset filters")}
        </.link>
        <p
          id={@count_id}
          role="status"
          class="text-sm tabular-nums text-on-surface-variant"
        >
          {@count_text}
        </p>
      </div>
    </header>

    <div class="rounded-xl border border-outline-variant bg-surface-container text-on-surface">
      <form
        id={@id}
        role="search"
        aria-label={@title}
        phx-change="filter"
        phx-submit="filter"
        class={[
          "grid items-end gap-3 p-4",
          @filters != [] &&
            "min-[360px]:grid-cols-[minmax(0,1.3fr)_minmax(0,1fr)] md:grid-cols-[minmax(0,1fr)_12rem_9rem]"
        ]}
      >
        <div class="col-span-full grid min-w-0 gap-1 md:col-span-1">
          <label for="filter-q" class="form-label">{dgettext("knowledge", "Search")}</label>
          <div class="relative">
            <.dm_mdi
              name="magnify"
              class="pointer-events-none absolute start-3 top-1/2 z-10 size-5 -translate-y-1/2 text-on-surface-variant"
              aria-hidden="true"
            />
            <.dm_input
              type="search"
              size="sm"
              id="filter-q"
              name="filters[q]"
              placeholder={@placeholder}
              value={@query}
              phx-debounce="300"
              class="ps-10"
            />
          </div>
        </div>
        {render_slot(@filters)}
      </form>
      <div
        :if={@label}
        id="active-label"
        class="flex min-w-0 items-center gap-2 border-t border-outline-variant px-4 py-2"
      >
        <span class="text-sm">{dgettext("knowledge", "Label")}</span>
        <.dm_badge variant="primary" class="min-w-0 max-w-full">
          <span class="truncate">{@label}</span>
        </.dm_badge>
        <.link
          id="clear-label"
          patch={@clear_label_path}
          aria-label={dgettext("knowledge", "Clear label filter")}
        >
          <.dm_mdi name="close" class="h-4 w-4" aria-hidden="true" />
        </.link>
      </div>
    </div>
    """
  end
end
