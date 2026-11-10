defmodule SingularityWeb.ItemLive.Index do
  use SingularityWeb, :live_view

  import SingularityWeb.ItemComponents

  alias Singularity.{Collection, Knowledge, Sources}

  @per_page 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Collection.subscribe()
    {:ok, assign_options(socket)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket |> assign(filters: parse_filters(params), query: clean(params)) |> load_rows()}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply, push_patch(socket, to: ~p"/?#{clean(filters)}")}
  end

  @impl true
  def handle_info({:fetch_run, %{status: "ok"}}, socket),
    do: {:noreply, socket |> assign_options() |> load_rows()}

  def handle_info({:fetch_run, _run}, socket), do: {:noreply, socket}

  defp assign_options(socket),
    do: assign(socket, sources: Sources.list_sources(), kinds: Knowledge.list_item_kinds())

  defp load_rows(%{assigns: %{filters: %{source_id: source_id}}} = socket)
       when is_integer(source_id) do
    period = Knowledge.latest_period(source_id)
    rows = if period, do: Knowledge.list_period(source_id, period), else: []
    assign(socket, mode: :period, period: period, rows: rows, has_next: false)
  end

  defp load_rows(%{assigns: %{filters: filters}} = socket) do
    rows =
      Knowledge.list_items(
        kind: filters.kind,
        from: filters.from,
        to: filters.to,
        page: filters.page,
        per_page: @per_page
      )

    assign(socket, mode: :recent, period: nil, rows: rows, has_next: length(rows) == @per_page)
  end

  defp parse_filters(params) do
    %{
      source_id: parse_int(params["source_id"]),
      kind: blank_to_nil(params["kind"]),
      from: parse_date(params["from"]),
      to: parse_date(params["to"]),
      page: max(parse_int(params["page"]) || 1, 1)
    }
  end

  defp clean(params) do
    params
    |> Map.take(~w(source_id kind from to page))
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp parse_int(nil), do: nil

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_date(nil), do: nil

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp page_query(query, page), do: Map.put(query, "page", page)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:overview} active="overview-home">
      <h1 class="text-2xl font-semibold">条目</h1>

      <form id="item-filters" phx-change="filter" class="flex flex-wrap gap-3 items-end">
        <.dm_select
          id="filter-source"
          name="filters[source_id]"
          label="来源"
          value={@filters.source_id}
          prompt="全部来源"
          options={Enum.map(@sources, &{&1.id, &1.name})}
        />
        <.dm_select
          id="filter-kind"
          name="filters[kind]"
          label="类型"
          value={@filters.kind}
          prompt="全部类型"
          options={Enum.map(@kinds, &{&1, &1})}
        />
        <.dm_input
          :if={@mode == :recent}
          id="filter-from"
          type="date"
          name="filters[from]"
          label="从"
          value={@filters.from}
        />
        <.dm_input
          :if={@mode == :recent}
          id="filter-to"
          type="date"
          name="filters[to]"
          label="到"
          value={@filters.to}
        />
      </form>

      <p :if={@mode == :period && @period} id="period-label" class="text-sm">期次：{@period}</p>
      <p :if={@rows == []} id="items-empty">还没有采集到条目。</p>

      <ol id="items" class="space-y-3">
        <li
          :for={row <- @rows}
          id={"item-#{row.item.id}"}
          class="rounded border border-outline-variant p-3 space-y-1"
        >
          <div class="flex items-baseline gap-2">
            <span :if={row.rank} class="font-mono text-sm">#{row.rank}</span>
            <.link navigate={~p"/knowledge/projects/#{row.item.id}"} class="font-medium">{row.item.title}</.link>
            <.dm_badge size="sm">{row.item.kind}</.dm_badge>
          </div>
          <p :if={row.item.summary} class="text-sm text-on-surface-variant">{row.item.summary}</p>
          <div class="text-xs flex flex-wrap gap-3">
            <.item_meta item={row.item} />
            <.observation_meta
              :if={row.observation_attributes}
              kind={row.item.kind}
              attributes={row.observation_attributes}
            />
            <span>最近观测 {format_time(row.observed_at)}</span>
          </div>
        </li>
      </ol>

      <nav :if={@mode == :recent} class="flex gap-3" aria-label="分页">
        <.link
          :if={@filters.page > 1}
          patch={~p"/?#{page_query(@query, @filters.page - 1)}"}
          id="page-prev"
        >上一页</.link>
        <.link :if={@has_next} patch={~p"/?#{page_query(@query, @filters.page + 1)}"} id="page-next">下一页</.link>
      </nav>
    </Layouts.app>
    """
  end
end
