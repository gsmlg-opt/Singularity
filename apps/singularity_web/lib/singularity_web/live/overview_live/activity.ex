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

    {:ok,
     socket
     |> assign(page_title: dgettext("overview", "Activity"))
     |> stream_configure(:events, dom_id: fn {type, _at, event} -> event_id(type, event) end)
     |> load()}
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

    socket |> stream(:events, events, reset: true) |> assign(events_empty?: events == [])
  end

  defp event_id(:addition, %{item: item}), do: "addition-#{item.id}"
  defp event_id(:run, run), do: "run-#{run.id}"

  defp added_via(nil), do: dgettext("overview", "Added manually")
  defp added_via(source), do: dgettext("overview", "Added from %{source}", source: source.name)

  defp event_icon(:addition), do: "plus-box-outline"
  defp event_icon(:run), do: "history"

  attr :type, :atom, required: true
  attr :event, :map, required: true

  defp event_summary(%{type: :addition} = assigns) do
    ~H"""
    <.link navigate={~p"/knowledge/projects/#{@event.item.id}"}>{@event.item.title}</.link>
    """
  end

  defp event_summary(%{type: :run} = assigns) do
    ~H"""
    <span>{dgettext("overview", "Collected %{source}", source: @event.source.name)}</span>
    """
  end

  attr :type, :atom, required: true
  attr :event, :map, required: true

  defp event_details(%{type: :addition} = assigns) do
    ~H"""
    <span class="text-sm text-on-surface-variant">{added_via(@event.source)}</span>
    """
  end

  defp event_details(%{type: :run} = assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2">
      <.run_status run={@event} />
      <span class="text-sm text-on-surface-variant">
        {dngettext("overview", "%{count} item", "%{count} items", @event.item_count)}
      </span>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:overview} active="overview-activity">
      <h1 class="text-2xl font-bold">{dgettext("overview", "Activity")}</h1>
      <p :if={@events_empty?} id="activity-empty">
        {dgettext("overview", "Nothing has happened yet.")}
      </p>
      <.dm_table :if={!@events_empty?} id="activity" data={@streams.events} stream hover>
        <:col :let={{_type, at, _event}} label={dgettext("overview", "Time")}>
          <span class="whitespace-nowrap text-sm text-on-surface-variant">{format_time(at)}</span>
        </:col>
        <:col :let={{type, _at, event}} label={dgettext("overview", "Event")}>
          <div class="flex items-center gap-2">
            <.dm_mdi name={event_icon(type)} class="h-5 w-5 shrink-0" />
            <.event_summary type={type} event={event} />
          </div>
        </:col>
        <:col :let={{type, _at, event}} label={dgettext("overview", "Details")}>
          <.event_details type={type} event={event} />
        </:col>
      </.dm_table>
    </Layouts.app>
    """
  end
end
