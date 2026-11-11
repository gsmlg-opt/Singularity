defmodule SingularityWeb.OverviewLive.Activity do
  use SingularityWeb, :live_view

  import SingularityWeb.ItemComponents, only: [format_time: 1]
  import SingularityWeb.RunComponents

  alias Singularity.{Collection, Knowledge}

  @limit 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Knowledge.subscribe()
      Collection.subscribe()
    end

    {:ok, socket |> assign(page_title: dgettext("overview", "Activity")) |> load()}
  end

  @impl true
  def handle_info({:project_updated, _id}, socket), do: {:noreply, load(socket)}
  def handle_info({:fetch_run, _run}, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    additions = Enum.map(Knowledge.list_additions(@limit), &{:addition, &1.at, &1})
    runs = Enum.map(Collection.list_recent_runs(@limit), &{:run, &1.started_at, &1})

    events =
      (additions ++ runs)
      |> Enum.sort_by(fn {_type, at, _event} -> at end, {:desc, DateTime})
      |> Enum.take(@limit)

    assign(socket, events: events)
  end

  defp event_id(:addition, %{item: item}), do: "addition-#{item.id}"
  defp event_id(:run, run), do: "run-#{run.id}"

  defp added_via(nil), do: dgettext("overview", "Added manually")
  defp added_via(source), do: dgettext("overview", "Added from %{source}", source: source.name)

  attr :addition, :map, required: true

  defp addition_event(assigns) do
    ~H"""
    <.dm_mdi name="plus-box-outline" class="h-5 w-5" />
    <.link navigate={~p"/knowledge/projects/#{@addition.item.id}"}>{@addition.item.title}</.link>
    <span class="text-sm text-on-surface-variant">{added_via(@addition.source)}</span>
    """
  end

  attr :run, :map, required: true

  defp run_event(assigns) do
    ~H"""
    <.dm_mdi name="history" class="h-5 w-5" />
    <span>{dgettext("overview", "Collected %{source}", source: @run.source.name)}</span>
    <.run_status run={@run} />
    <span class="text-sm text-on-surface-variant">
      {dngettext("overview", "%{count} item", "%{count} items", @run.item_count)}
    </span>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:overview} active="overview-activity">
      <h1 class="text-2xl font-bold">{dgettext("overview", "Activity")}</h1>
      <p :if={@events == []} id="activity-empty">
        {dgettext("overview", "Nothing has happened yet.")}
      </p>
      <ol id="activity" class="space-y-2">
        <li
          :for={{type, at, event} <- @events}
          id={event_id(type, event)}
          class="flex flex-wrap items-center gap-3 rounded border border-outline-variant p-3"
        >
          <span class="w-44 shrink-0 text-xs text-on-surface-variant">{format_time(at)}</span>
          <.addition_event :if={type == :addition} addition={event} />
          <.run_event :if={type == :run} run={event} />
        </li>
      </ol>
    </Layouts.app>
    """
  end
end
