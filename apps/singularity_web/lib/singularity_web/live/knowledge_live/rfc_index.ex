defmodule SingularityWeb.KnowledgeLive.RfcIndex do
  use SingularityWeb, :live_view

  import SingularityWeb.ItemComponents, only: [label_badges: 1, format_count: 1]
  import SingularityWeb.RfcComponents

  alias Singularity.{Collection, Knowledge}

  @per_page 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Knowledge.subscribe()
      Collection.subscribe()
    end

    {:ok,
     socket
     |> assign(page_title: dgettext("knowledge", "IETF RFCs"))
     |> stream_configure(:rfcs, dom_id: &"rfc-#{&1.attributes["number"]}")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = %{
      q: blank_to_nil(params["q"]),
      label: blank_to_nil(params["label"]),
      page: parse_page(params["page"])
    }

    {:noreply, socket |> assign(filters: filters) |> load()}
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    filters = %{socket.assigns.filters | q: blank_to_nil(params["q"]), page: 1}
    {:noreply, push_patch(socket, to: rfcs_path(filters))}
  end

  @impl true
  def handle_info({:project_updated, _id}, socket), do: {:noreply, load(socket)}
  def handle_info({:fetch_run, %{status: "ok"}}, socket), do: {:noreply, load(socket)}
  def handle_info({:fetch_run, _run}, socket), do: {:noreply, socket}

  defp load(%{assigns: %{filters: filters}} = socket) do
    opts = [q: filters.q, label: filters.label]
    rfcs = Knowledge.list_rfcs(opts ++ [page: filters.page, per_page: @per_page])
    total = Knowledge.count_rfcs(opts)

    socket
    |> stream(:rfcs, rfcs, reset: true)
    |> assign(
      rfcs_empty?: rfcs == [],
      total: total,
      has_next: filters.page * @per_page < total
    )
  end

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
  defp rfcs_path(filters) do
    query =
      [
        {"q", filters.q},
        {"label", filters.label},
        {"page", if(filters.page > 1, do: filters.page)}
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    if query == %{}, do: ~p"/knowledge/ietf-rfcs", else: ~p"/knowledge/ietf-rfcs?#{query}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:knowledge} active="knowledge-rfcs">
      <div class="space-y-1">
        <h1 class="text-2xl font-bold">{dgettext("knowledge", "IETF RFCs")}</h1>
        <p id="rfcs-total" class="text-sm text-on-surface-variant">
          {dgettext("knowledge", "%{count} RFCs", count: format_count(@total))}
        </p>
      </div>

      <div class="flex flex-wrap items-end gap-4">
        <form id="rfc-filters" phx-change="filter" phx-submit="filter" class="flex items-end gap-3">
          <.dm_input
            id="filter-q"
            name="filters[q]"
            label={dgettext("knowledge", "Search")}
            placeholder={dgettext("knowledge", "Number or title")}
            value={@filters.q}
            phx-debounce="300"
          />
        </form>
        <div :if={@filters.label} id="active-label" class="flex items-center gap-2">
          <span class="text-sm">{dgettext("knowledge", "Label")}</span>
          <.dm_badge variant="primary">{@filters.label}</.dm_badge>
          <.link
            id="clear-label"
            patch={rfcs_path(%{@filters | label: nil, page: 1})}
            aria-label={dgettext("knowledge", "Clear label filter")}
          >
            <.dm_mdi name="close" class="h-4 w-4" />
          </.link>
        </div>
      </div>

      <p :if={@rfcs_empty?} id="rfcs-empty">{dgettext("knowledge", "No RFCs match.")}</p>
      <.dm_table :if={!@rfcs_empty?} id="rfcs" data={@streams.rfcs} stream hover>
        <:col :let={rfc} label={dgettext("knowledge", "RFC")}>
          <div class="min-w-0 max-w-2xl">
            <.link navigate={item_path(rfc)} class="font-medium">{rfc_name(rfc)}</.link>
            <p class="text-sm text-on-surface-variant line-clamp-1">{rfc.title}</p>
          </div>
        </:col>
        <:col :let={rfc} label={dgettext("knowledge", "Status")}>
          <.rfc_status status={rfc.attributes["status"]} />
        </:col>
        <:col :let={rfc} label={dgettext("knowledge", "Published")}>
          {published_month(rfc.published_at)}
        </:col>
        <:col :let={rfc} label={dgettext("knowledge", "Labels")}>
          <.label_badges labels={rfc.labels} />
        </:col>
      </.dm_table>

      <nav class="flex gap-3" aria-label={dgettext("knowledge", "Pagination")}>
        <.link
          :if={@filters.page > 1}
          id="page-prev"
          patch={rfcs_path(%{@filters | page: @filters.page - 1})}
        >
          {dgettext("knowledge", "Previous")}
        </.link>
        <.link :if={@has_next} id="page-next" patch={rfcs_path(%{@filters | page: @filters.page + 1})}>
          {dgettext("knowledge", "Next")}
        </.link>
      </nav>
    </Layouts.app>
    """
  end
end
