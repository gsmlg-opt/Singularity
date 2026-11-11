defmodule SingularityWeb.OverviewLive.Index do
  use SingularityWeb, :live_view

  import SingularityWeb.ItemComponents

  alias Singularity.{Collection, Knowledge, Sources}
  alias SingularityWeb.RunComponents

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Knowledge.subscribe()
      Collection.subscribe()
    end

    {:ok,
     socket
     |> assign(page_title: dgettext("overview", "Overview"))
     |> stream_configure(:recent, dom_id: &"project-#{&1.id}")
     |> load()}
  end

  @impl true
  def handle_info({:project_updated, _id}, socket), do: {:noreply, load(socket)}
  def handle_info({:fetch_run, _run}, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    week_ago = DateTime.add(DateTime.utc_now(), -7 * 86_400, :second)

    recent = Knowledge.recent_projects(12)

    socket
    |> stream(:recent, recent, reset: true)
    |> assign(
      recent_empty?: recent == [],
      project_count: Knowledge.count_projects(),
      week_count: Knowledge.count_projects_since(week_ago),
      enabled_sources: Enum.count(Sources.list_sources(), & &1.enabled),
      last_run: List.first(Collection.list_recent_runs(1)),
      labels: Knowledge.top_labels(20)
    )
  end

  defp last_run_value(nil), do: dgettext("overview", "Never")
  defp last_run_value(run), do: RunComponents.status_label(run.status)

  defp last_run_description(nil), do: nil
  defp last_run_description(run), do: "#{run.source.name} · #{format_time(run.started_at)}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:overview} active="overview-home">
      <h1 class="text-2xl font-bold">{dgettext("overview", "Overview")}</h1>

      <div id="overview-stats" class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <.dm_stat
          id="stat-projects"
          title={dgettext("overview", "Software projects")}
          value={Integer.to_string(@project_count)}
        />
        <.dm_stat
          id="stat-week"
          title={dgettext("overview", "Added this week")}
          value={Integer.to_string(@week_count)}
        />
        <.dm_stat
          id="stat-sources"
          title={dgettext("overview", "Enabled sources")}
          value={Integer.to_string(@enabled_sources)}
        />
        <.dm_stat
          id="stat-last-run"
          title={dgettext("overview", "Last collection")}
          value={last_run_value(@last_run)}
          description={last_run_description(@last_run)}
        />
      </div>

      <section class="space-y-3">
        <div class="flex items-center justify-between">
          <h2 class="text-lg font-semibold">{dgettext("overview", "Recently added")}</h2>
          <.link navigate={~p"/knowledge"} id="view-all">{dgettext("overview", "View all")}</.link>
        </div>
        <p :if={@recent_empty?} id="recent-empty">
          {dgettext("overview", "No software projects yet. Add one or run a source.")}
        </p>
        <.project_table :if={!@recent_empty?} id="recent-projects" rows={@streams.recent} />
      </section>

      <section :if={@labels != []} class="space-y-3">
        <h2 class="text-lg font-semibold">{dgettext("overview", "Popular labels")}</h2>
        <div id="label-cloud" class="flex flex-wrap gap-2">
          <.link
            :for={{name, count} <- @labels}
            navigate={~p"/knowledge?#{%{label: name}}"}
            class="no-underline"
          >
            <.dm_badge variant="primary" soft>{name} · {count}</.dm_badge>
          </.link>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
