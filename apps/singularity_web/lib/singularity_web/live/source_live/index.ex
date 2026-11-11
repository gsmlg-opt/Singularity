defmodule SingularityWeb.SourceLive.Index do
  use SingularityWeb, :live_view

  import SingularityWeb.ItemComponents, only: [format_time: 1]
  import SingularityWeb.RunComponents

  alias Singularity.{Collection, Sources}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Collection.subscribe()
    {:ok, socket |> assign(page_title: dgettext("source", "Sources")) |> load()}
  end

  @impl true
  def handle_event("toggle", %{"id" => id}, socket) do
    source = Sources.get_source!(id)
    {:ok, _} = Sources.set_enabled(source, !source.enabled)
    {:noreply, load(socket)}
  end

  def handle_event("collect", %{"id" => id}, socket) do
    {:ok, _job} = Collection.enqueue(String.to_integer(id))
    {:noreply, put_flash(socket, :info, dgettext("source", "Collection queued"))}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    {:ok, _} = id |> Sources.get_source!() |> Sources.delete_source()
    {:noreply, load(socket)}
  end

  @impl true
  def handle_info({:fetch_run, _run}, socket), do: {:noreply, load(socket)}

  defp load(socket),
    do: assign(socket, sources: Sources.list_sources(), runs: Collection.latest_runs())

  @doc "The source type's label, or a notice when the type is no longer registered."
  def type_label(source) do
    case Sources.fetch_source_type(source.kind) do
      {:ok, type} -> type.label
      :error -> dgettext("source", "Unavailable (%{kind})", kind: source.kind)
    end
  end

  def enabled_label(true), do: dgettext("source", "Enabled")
  def enabled_label(false), do: dgettext("source", "Disabled")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:source} active="source-sources">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold">{dgettext("source", "Sources")}</h1>
        <.link navigate={~p"/source/sources/new"} id="new-source">
          <.dm_btn variant="primary" size="sm">{dgettext("source", "New source")}</.dm_btn>
        </.link>
      </div>

      <.dm_table id="sources" data={@sources}>
        <:col :let={source} label={dgettext("source", "Name")}>
          <.link navigate={~p"/source/sources/#{source.id}"} id={"source-#{source.id}"}>
            {source.name}
          </.link>
        </:col>
        <:col :let={source} label={dgettext("source", "Type")}>{type_label(source)}</:col>
        <:col :let={source} label={dgettext("source", "Interval")}>
          {dngettext("source", "%{count} minute", "%{count} minutes", source.interval_minutes)}
        </:col>
        <:col :let={source} label={dgettext("source", "Status")}>
          <.dm_badge size="sm" variant={if source.enabled, do: "success", else: "warning"}>
            {enabled_label(source.enabled)}
          </.dm_badge>
        </:col>
        <:col :let={source} label={dgettext("source", "Latest run")}>
          <span :if={run = @runs[source.id]}>
            <.run_status run={run} />
            {format_time(run.started_at)} · {dngettext(
              "source",
              "%{count} item",
              "%{count} items",
              run.item_count
            )}
          </span>
          <span :if={!@runs[source.id]}>—</span>
        </:col>
        <:col :let={source} label={dgettext("source", "Actions")} label_class="text-right">
          <.row_actions>
            <.row_action
              :if={source.enabled}
              id={"collect-#{source.id}"}
              icon="play-circle-outline"
              label={dgettext("source", "Collect now")}
              phx-click="collect"
              phx-value-id={source.id}
            />
            <.row_action
              id={"toggle-#{source.id}"}
              icon={if source.enabled, do: "pause-circle-outline", else: "check-circle-outline"}
              label={
                if source.enabled,
                  do: dgettext("source", "Disable"),
                  else: dgettext("source", "Enable")
              }
              phx-click="toggle"
              phx-value-id={source.id}
            />
            <.row_action
              id={"edit-#{source.id}"}
              icon="pencil-outline"
              label={dgettext("source", "Edit")}
              navigate={~p"/source/sources/#{source.id}/edit"}
            />
            <.row_action
              id={"delete-#{source.id}"}
              icon="delete-outline"
              label={dgettext("source", "Delete")}
              destructive
              phx-click="delete"
              phx-value-id={source.id}
              data-confirm={
                dgettext("source", "Delete this source and its records? Projects are kept.")
              }
            />
          </.row_actions>
        </:col>
      </.dm_table>
    </Layouts.app>
    """
  end
end
