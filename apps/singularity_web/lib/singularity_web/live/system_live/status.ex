defmodule SingularityWeb.SystemLive.Status do
  use SingularityWeb, :live_view

  # Singularity.System is called fully qualified: an alias would shadow Elixir's System.

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: dgettext("system", "System status"),
       status: Singularity.System.status()
     )}
  end

  @impl true
  def handle_event("refresh", _params, socket),
    do: {:noreply, assign(socket, status: Singularity.System.status())}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:system} active="system-status">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">{dgettext("system", "System status")}</h1>
        <.dm_btn id="refresh-status" size="sm" phx-click="refresh">
          <.dm_mdi name="refresh" class="h-4 w-4" />{dgettext("system", "Refresh")}
        </.dm_btn>
      </div>
      <.dm_stat id="app-version" title={dgettext("system", "Version")} value={@status.version} />
      <h2 class="text-lg font-semibold">{dgettext("system", "Job queues")}</h2>
      <.dm_table id="queues" data={@status.queues}>
        <:col :let={queue} label={dgettext("system", "Queue")}>{queue.name}</:col>
        <:col :let={queue} label={dgettext("system", "Available")}>
          <span id={"queue-#{queue.name}-available"}>{queue.available}</span>
        </:col>
        <:col :let={queue} label={dgettext("system", "Executing")}>
          <span id={"queue-#{queue.name}-executing"}>{queue.executing}</span>
        </:col>
        <:col :let={queue} label={dgettext("system", "Retryable")}>
          <span id={"queue-#{queue.name}-retryable"}>{queue.retryable}</span>
        </:col>
      </.dm_table>
    </Layouts.app>
    """
  end
end
