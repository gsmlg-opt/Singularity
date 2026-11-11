defmodule SingularityWeb.KnowledgeLive.Index do
  use SingularityWeb, :live_view

  import SingularityWeb.ItemComponents

  alias Singularity.{Collection, Knowledge}

  @per_page 30

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Knowledge.subscribe()
      Collection.subscribe()
    end

    {:ok, assign(socket, page_title: dgettext("knowledge", "Software projects"))}
  end

  @impl true
  def handle_params(params, _uri, socket),
    do: {:noreply, socket |> assign(filters: parse_filters(params)) |> load()}

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    filters = %{
      socket.assigns.filters
      | q: blank_to_nil(params["q"]),
        sort: parse_sort(params["sort"]),
        page: 1
    }

    {:noreply, push_patch(socket, to: knowledge_path(socket.assigns.live_action, filters))}
  end

  @impl true
  def handle_info({:project_updated, _id}, socket), do: {:noreply, load(socket)}
  def handle_info({:fetch_run, %{status: "ok"}}, socket), do: {:noreply, load(socket)}
  def handle_info({:fetch_run, _run}, socket), do: {:noreply, socket}

  defp load(%{assigns: %{filters: filters}} = socket) do
    projects =
      Knowledge.list_projects(
        label: filters.label,
        q: filters.q,
        sort: filters.sort,
        page: filters.page,
        per_page: @per_page
      )

    assign(socket,
      projects: projects,
      has_next: length(projects) == @per_page,
      top_labels: Knowledge.top_labels(12)
    )
  end

  defp parse_filters(params) do
    %{
      label: blank_to_nil(params["label"]),
      q: blank_to_nil(params["q"]),
      sort: parse_sort(params["sort"]),
      page: parse_page(params["page"])
    }
  end

  defp parse_sort("stars"), do: :stars
  defp parse_sort(_recent), do: :recent

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} when page > 1 -> page
      _other -> 1
    end
  end

  defp parse_page(_value), do: 1

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  # The empty filter state has no query string at all.
  defp knowledge_path(action, filters) do
    query =
      [
        {"label", filters.label},
        {"q", filters.q},
        {"sort", if(filters.sort == :stars, do: "stars")},
        {"page", if(filters.page > 1, do: filters.page)}
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    case {action, query == %{}} do
      {:projects, true} -> ~p"/knowledge/projects"
      {:projects, false} -> ~p"/knowledge/projects?#{query}"
      {_index, true} -> ~p"/knowledge"
      {_index, false} -> ~p"/knowledge?#{query}"
    end
  end

  defp active_item(live_action, top_labels, label) do
    case Layouts.label_menu_id(top_labels, label) do
      nil when live_action == :projects -> "knowledge-projects"
      nil -> "knowledge-all"
      id -> id
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      socket={@socket}
      section={:knowledge}
      labels={@top_labels}
      active={active_item(@live_action, @top_labels, @filters.label)}
    >
      <h1 class="text-2xl font-bold">{dgettext("knowledge", "Software projects")}</h1>

      <div class="flex flex-wrap items-end gap-4">
        <form
          id="project-filters"
          phx-change="filter"
          phx-submit="filter"
          class="flex flex-wrap items-end gap-3"
        >
          <.dm_input
            id="filter-q"
            name="filters[q]"
            label={dgettext("knowledge", "Search")}
            placeholder={dgettext("knowledge", "owner/repo or description")}
            value={@filters.q}
            phx-debounce="300"
          />
          <.dm_select
            id="filter-sort"
            name="filters[sort]"
            label={dgettext("knowledge", "Sort by")}
            value={Atom.to_string(@filters.sort)}
            options={[
              {"recent", dgettext("knowledge", "Recently added")},
              {"stars", dgettext("knowledge", "Stars")}
            ]}
          />
        </form>
        <div :if={@filters.label} id="active-label" class="flex items-center gap-2">
          <span class="text-sm">{dgettext("knowledge", "Label")}</span>
          <.dm_badge variant="primary">{@filters.label}</.dm_badge>
          <.link
            id="clear-label"
            patch={knowledge_path(@live_action, %{@filters | label: nil, page: 1})}
            aria-label={dgettext("knowledge", "Clear label filter")}
          >
            <.dm_mdi name="close" class="h-4 w-4" />
          </.link>
        </div>
      </div>

      <p :if={@projects == []} id="projects-empty">
        {dgettext("knowledge", "No software projects match.")}
      </p>
      <div id="projects" class="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
        <.project_card :for={project <- @projects} project={project} />
      </div>

      <nav class="flex gap-3" aria-label={dgettext("knowledge", "Pagination")}>
        <.link
          :if={@filters.page > 1}
          id="page-prev"
          patch={knowledge_path(@live_action, %{@filters | page: @filters.page - 1})}
        >
          {dgettext("knowledge", "Previous")}
        </.link>
        <.link
          :if={@has_next}
          id="page-next"
          patch={knowledge_path(@live_action, %{@filters | page: @filters.page + 1})}
        >
          {dgettext("knowledge", "Next")}
        </.link>
      </nav>
    </Layouts.app>
    """
  end
end
