defmodule SingularityWeb.SourceLive.RunShow do
  use SingularityWeb, :live_view

  import SingularityWeb.ItemComponents, only: [format_time: 1, format_count: 1]
  import SingularityWeb.RfcComponents
  import SingularityWeb.RunComponents

  alias Singularity.Collection
  alias Singularity.Knowledge.ItemChange

  @per_page 50

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    run = Collection.get_run!(id)
    if connected?(socket), do: Collection.subscribe()

    {:ok,
     assign(socket,
       page_title: dgettext("source", "Collection run"),
       run: run
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    change = if params["change"] in ItemChange.changes(), do: params["change"]
    {:noreply, socket |> assign(change: change, page: parse_page(params["page"])) |> load()}
  end

  # A running run's counters and changes appear when it finishes.
  @impl true
  def handle_info({:fetch_run, %{id: id}}, %{assigns: %{run: %{id: id}}} = socket),
    do: {:noreply, socket |> assign(run: Collection.get_run!(id)) |> load()}

  def handle_info({:fetch_run, _other}, socket), do: {:noreply, socket}

  defp load(%{assigns: %{run: run, change: change, page: page}} = socket) do
    total = Collection.count_run_changes(run.id, change: change)

    assign(socket,
      changes:
        Collection.list_run_changes(run.id, change: change, page: page, per_page: @per_page),
      total: total,
      has_next: page * @per_page < total
    )
  end

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} when page > 1 -> page
      _other -> 1
    end
  end

  defp parse_page(_value), do: 1

  defp run_path(run, change, page) do
    query =
      [{"change", change}, {"page", if(page > 1, do: page)}]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    if query == %{}, do: ~p"/source/runs/#{run.id}", else: ~p"/source/runs/#{run.id}?#{query}"
  end

  defp filters(run) do
    [
      {nil, dgettext("source", "All"), run.added_count + run.updated_count + run.removed_count},
      {"added", change_label("added"), run.added_count},
      {"updated", change_label("updated"), run.updated_count},
      {"removed", change_label("removed"), run.removed_count}
    ]
  end

  defp changed_item_path(%ItemChange{item_id: nil}), do: nil
  defp changed_item_path(%ItemChange{} = change), do: item_path(change)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:source} active="source-runs">
      <header class="flex flex-wrap items-center gap-2">
        <h1 class="text-2xl font-bold">{dgettext("source", "Collection run")}</h1>
        <.run_status run={@run} />
      </header>

      <dl id="run-details" class="grid grid-cols-[10rem_1fr] gap-1 text-sm">
        <dt class="text-on-surface-variant">{dgettext("source", "Source")}</dt>
        <dd>
          <.link navigate={~p"/source/sources/#{@run.source_id}"} class="text-primary">
            {@run.source.name}
          </.link>
        </dd>
        <dt class="text-on-surface-variant">{dgettext("source", "Started")}</dt>
        <dd>{format_time(@run.started_at)}</dd>
        <dt class="text-on-surface-variant">{dgettext("source", "Finished")}</dt>
        <dd>{format_time(@run.finished_at)}</dd>
        <dt class="text-on-surface-variant">{dgettext("source", "Items")}</dt>
        <dd>{format_count(@run.item_count)}</dd>
        <dt class="text-on-surface-variant">{dgettext("source", "Skipped")}</dt>
        <dd>{format_count(@run.skipped_count)}</dd>
        <dt :if={@run.error} class="text-on-surface-variant">{dgettext("source", "Error")}</dt>
        <dd :if={@run.error} class="text-error">{@run.error}</dd>
      </dl>

      <section class="space-y-3">
        <h2 class="text-lg font-semibold">{dgettext("source", "Changes")}</h2>
        <nav
          id="change-filters"
          class="flex flex-wrap gap-2"
          aria-label={dgettext("source", "Change type")}
        >
          <.link
            :for={{change, label, count} <- filters(@run)}
            id={"filter-#{change || "all"}"}
            patch={run_path(@run, change, 1)}
            aria-current={if @change == change, do: "page"}
          >
            <.dm_badge
              variant={if @change == change, do: "primary", else: "neutral"}
              soft={@change != change}
            >
              {label} · {format_count(count)}
            </.dm_badge>
          </.link>
        </nav>

        <p :if={@changes == []} id="changes-empty" class="text-sm text-on-surface-variant">
          {dgettext("source", "This run changed nothing.")}
        </p>
        <.dm_table :if={@changes != []} id="run-changes" data={@changes} hover>
          <:col :let={change} label={dgettext("source", "Item")}>
            <div class="min-w-0 max-w-xl">
              <.link
                :if={changed_item_path(change)}
                navigate={changed_item_path(change)}
                class="font-medium"
              >
                {change.title}
              </.link>
              <span :if={!changed_item_path(change)} class="font-medium">{change.title}</span>
              <p class="text-sm text-on-surface-variant line-clamp-1">{change.external_id}</p>
            </div>
          </:col>
          <:col :let={change} label={dgettext("source", "Change")}>
            <.change_badge change={change.change} />
          </:col>
          <:col :let={change} label={dgettext("source", "Details")}>
            <div class="min-w-0 max-w-3xl space-y-2">
              <.field_changes fields={change.fields} />
              <.content_diff
                :if={change.content_diff not in [nil, ""]}
                id={"diff-#{change.id}"}
                diff={change.content_diff}
              />
            </div>
          </:col>
        </.dm_table>

        <nav class="flex gap-3" aria-label={dgettext("source", "Pagination")}>
          <.link :if={@page > 1} id="page-prev" patch={run_path(@run, @change, @page - 1)}>
            {dgettext("source", "Previous")}
          </.link>
          <.link :if={@has_next} id="page-next" patch={run_path(@run, @change, @page + 1)}>
            {dgettext("source", "Next")}
          </.link>
        </nav>
      </section>
    </Layouts.app>
    """
  end
end
