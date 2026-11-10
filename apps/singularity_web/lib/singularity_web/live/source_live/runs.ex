defmodule SingularityWeb.SourceLive.Runs do
  use SingularityWeb, :live_view

  import SingularityWeb.ItemComponents, only: [format_time: 1]
  import SingularityWeb.RunComponents

  alias Singularity.Collection

  @limit 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Collection.subscribe()

    {:ok,
     assign(socket,
       page_title: dgettext("source", "Collection runs"),
       runs: Collection.list_recent_runs(@limit)
     )}
  end

  @impl true
  def handle_info({:fetch_run, _run}, socket),
    do: {:noreply, assign(socket, runs: Collection.list_recent_runs(@limit))}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:source} active="source-runs">
      <h1 class="text-2xl font-semibold">{dgettext("source", "Collection runs")}</h1>
      <p :if={@runs == []} id="runs-empty">{dgettext("source", "No collection has run yet.")}</p>
      <.dm_table :if={@runs != []} id="runs" data={@runs}>
        <:col :let={run} label={dgettext("source", "Source")}>
          <.link navigate={~p"/source/sources/#{run.source_id}"}>{run.source.name}</.link>
        </:col>
        <:col :let={run} label={dgettext("source", "Status")}><.run_status run={run} /></:col>
        <:col :let={run} label={dgettext("source", "Started")}>{format_time(run.started_at)}</:col>
        <:col :let={run} label={dgettext("source", "Items")}>{run.item_count}</:col>
        <:col :let={run} label={dgettext("source", "Error")}>{run.error}</:col>
      </.dm_table>
    </Layouts.app>
    """
  end
end
