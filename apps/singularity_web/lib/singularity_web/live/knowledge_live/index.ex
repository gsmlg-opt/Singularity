defmodule SingularityWeb.KnowledgeLive.Index do
  use SingularityWeb, :live_view

  import SingularityWeb.ItemComponents
  import SingularityWeb.KnowledgeSearch

  alias Singularity.{Collection, Knowledge}

  @per_page 30

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Knowledge.subscribe()
      Collection.subscribe()
    end

    {:ok,
     socket
     |> assign(page_title: dgettext("knowledge", "Software projects"))
     |> stream_configure(:projects, dom_id: &"project-#{&1.id}")}
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
        status: parse_status(params["status"]),
        page: 1
    }

    {:noreply, push_patch(socket, to: knowledge_path(socket.assigns.live_action, filters))}
  end

  @impl true
  def handle_info({:project_updated, _id}, socket), do: {:noreply, load(socket)}
  def handle_info({:fetch_run, %{status: "ok"}}, socket), do: {:noreply, load(socket)}
  def handle_info({:fetch_run, _run}, socket), do: {:noreply, socket}

  defp load(%{assigns: %{filters: filters}} = socket) do
    opts = [label: filters.label, status: filters.status, q: filters.q]
    total = Knowledge.count_projects(opts)

    projects =
      Knowledge.list_projects(
        opts ++ [sort: filters.sort, page: filters.page, per_page: @per_page]
      )

    socket
    |> stream(:projects, projects, reset: true)
    |> assign(
      projects_empty?: projects == [],
      total: total,
      has_next: filters.page * @per_page < total
    )
  end

  defp parse_filters(params) do
    %{
      label: blank_to_nil(params["label"]),
      q: blank_to_nil(params["q"]),
      sort: parse_sort(params["sort"]),
      status: parse_status(params["status"]),
      page: parse_page(params["page"])
    }
  end

  defp parse_sort("stars"), do: :stars
  defp parse_sort(_recent), do: :recent

  defp parse_status("active"), do: :active
  defp parse_status("deprecated"), do: :deprecated
  defp parse_status(_all), do: nil

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
        {"status", filters.status && Atom.to_string(filters.status)},
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

  defp active_item(:projects), do: "knowledge-projects"
  defp active_item(_index), do: "knowledge-all"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      socket={@socket}
      section={:knowledge}
      active={active_item(@live_action)}
    >
      <.search_toolbar
        id="project-filters"
        title={@page_title}
        icon="source-repository"
        count_id="project-result-count"
        count_text={
          dngettext("knowledge", "%{number} project", "%{number} projects", @total,
            number: format_count(@total)
          )
        }
        query={@filters.q}
        placeholder={dgettext("knowledge", "Project name or description")}
        reset_path={
          (@filters.q || @filters.label || @filters.status || @filters.sort != :recent) &&
            knowledge_path(@live_action, parse_filters(%{}))
        }
        label={@filters.label}
        clear_label_path={knowledge_path(@live_action, %{@filters | label: nil, page: 1})}
      >
        <:filters>
          <.dm_select
            id="filter-sort"
            size="sm"
            name="filters[sort]"
            label={dgettext("knowledge", "Sort by")}
            value={Atom.to_string(@filters.sort)}
            options={[
              {"recent", dgettext("knowledge", "Recently added")},
              {"stars", dgettext("knowledge", "Stars")}
            ]}
          />
          <.dm_select
            id="filter-status"
            size="sm"
            name="filters[status]"
            label={dgettext("knowledge", "Status")}
            value={if @filters.status, do: Atom.to_string(@filters.status), else: ""}
            options={[
              {"", dgettext("knowledge", "All")},
              {"active", dgettext("knowledge", "Active")},
              {"deprecated", dgettext("knowledge", "Deprecated")}
            ]}
          />
        </:filters>
      </.search_toolbar>

      <p
        :if={@projects_empty?}
        id="projects-empty"
        class="flex flex-col items-center gap-3 rounded-xl border border-dashed border-outline-variant px-4 py-10 text-sm text-on-surface-variant"
      >
        <.dm_mdi name="magnify" class="size-7" aria-hidden="true" />
        {dgettext("knowledge", "No software projects match.")}
      </p>
      <div :if={!@projects_empty?} class="overflow-hidden rounded-xl border border-outline-variant">
        <.project_table id="projects" rows={@streams.projects} />
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
