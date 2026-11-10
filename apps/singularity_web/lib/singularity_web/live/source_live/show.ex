defmodule SingularityWeb.SourceLive.Show do
  use SingularityWeb, :live_view

  import SingularityWeb.ItemComponents, only: [format_time: 1]
  import SingularityWeb.RunComponents

  alias Singularity.{Collection, Sources}
  alias SingularityWeb.SourceLive.Index

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Collection.subscribe()
    source = Sources.get_source!(id)

    {:ok,
     assign(socket,
       page_title: source.name,
       source: source,
       runs: Collection.list_runs(source.id)
     )}
  end

  @impl true
  def handle_event("collect", _params, socket) do
    {:ok, _job} = Collection.enqueue(socket.assigns.source.id)
    {:noreply, put_flash(socket, :info, dgettext("source", "Collection queued"))}
  end

  @impl true
  def handle_info(
        {:fetch_run, %{source_id: source_id}},
        %{assigns: %{source: %{id: source_id}}} = socket
      ) do
    {:noreply, assign(socket, runs: Collection.list_runs(source_id))}
  end

  def handle_info({:fetch_run, _run}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:source} active="source-sources">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">{@source.name}</h1>
        <div class="flex gap-2">
          <.dm_btn :if={@source.enabled} size="sm" id="collect-now" phx-click="collect">
            {dgettext("source", "Collect now")}
          </.dm_btn>
          <.link navigate={~p"/source/sources/#{@source.id}/edit"}>
            <.dm_btn size="sm">{dgettext("source", "Edit")}</.dm_btn>
          </.link>
        </div>
      </div>

      <dl class="grid grid-cols-[10rem_1fr] gap-1 text-sm">
        <dt>{dgettext("source", "Type")}</dt>
        <dd>{Index.type_label(@source)}</dd>
        <dt>{dgettext("source", "Config")}</dt>
        <dd><code>{Jason.encode!(@source.config)}</code></dd>
        <dt>{dgettext("source", "Interval")}</dt>
        <dd>
          {dngettext("source", "%{count} minute", "%{count} minutes", @source.interval_minutes)}
        </dd>
        <dt>{dgettext("source", "Status")}</dt>
        <dd>{Index.enabled_label(@source.enabled)}</dd>
        <dt>{dgettext("source", "Next run")}</dt>
        <dd>{format_time(@source.next_run_at)}</dd>
      </dl>

      <h2 class="text-lg font-semibold">{dgettext("source", "Recent runs")}</h2>
      <.dm_table id="runs" data={@runs}>
        <:col :let={run} label={dgettext("source", "Status")}><.run_status run={run} /></:col>
        <:col :let={run} label={dgettext("source", "Started")}>{format_time(run.started_at)}</:col>
        <:col :let={run} label={dgettext("source", "Finished")}>{format_time(run.finished_at)}</:col>
        <:col :let={run} label={dgettext("source", "Items")}>{run.item_count}</:col>
        <:col :let={run} label={dgettext("source", "Skipped")}>{run.skipped_count}</:col>
        <:col :let={run} label={dgettext("source", "Error")}>{run.error}</:col>
      </.dm_table>
    </Layouts.app>
    """
  end
end
