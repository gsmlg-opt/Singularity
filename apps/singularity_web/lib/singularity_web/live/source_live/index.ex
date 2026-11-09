defmodule SingularityWeb.SourceLive.Index do
  use SingularityWeb, :live_view

  import SingularityWeb.ItemComponents, only: [format_time: 1]

  alias Singularity.{Collection, Sources}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Collection.subscribe()
    {:ok, load(socket)}
  end

  @impl true
  def handle_event("toggle", %{"id" => id}, socket) do
    source = Sources.get_source!(id)
    {:ok, _} = Sources.set_enabled(source, !source.enabled)
    {:noreply, load(socket)}
  end

  def handle_event("collect", %{"id" => id}, socket) do
    {:ok, _job} = Collection.enqueue(String.to_integer(id))
    {:noreply, put_flash(socket, :info, "已加入采集队列")}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    {:ok, _} = id |> Sources.get_source!() |> Sources.delete_source()
    {:noreply, load(socket)}
  end

  @impl true
  def handle_info({:fetch_run, _run}, socket), do: {:noreply, load(socket)}

  defp load(socket),
    do: assign(socket, sources: Sources.list_sources(), runs: Collection.latest_runs())

  def run_variant("ok"), do: "success"
  def run_variant("failed"), do: "error"
  def run_variant(_running), do: "info"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current={:sources}>
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">来源</h1>
        <.link navigate={~p"/sources/new"} id="new-source"><.dm_btn variant="primary" size="sm">
          新建来源
        </.dm_btn></.link>
      </div>

      <.dm_table id="sources" data={@sources}>
        <:col :let={source} label="名称">
          <.link navigate={~p"/sources/#{source.id}"} id={"source-#{source.id}"}>{source.name}</.link>
        </:col>
        <:col :let={source} label="类型">{Sources.type_label(source)}</:col>
        <:col :let={source} label="间隔">{source.interval_minutes} 分钟</:col>
        <:col :let={source} label="状态">
          <.dm_badge size="sm" variant={if source.enabled, do: "success", else: "warning"}>
            {if source.enabled, do: "启用", else: "停用"}
          </.dm_badge>
        </:col>
        <:col :let={source} label="最近采集">
          <span :if={run = @runs[source.id]}>
            <.dm_badge size="sm" variant={run_variant(run.status)}>{run.status}</.dm_badge>
            {format_time(run.started_at)} · {run.item_count} 条
          </span>
          <span :if={!@runs[source.id]}>—</span>
        </:col>
        <:col :let={source} label="操作">
          <div class="flex gap-2">
            <.dm_btn
              :if={source.enabled}
              size="sm"
              id={"collect-#{source.id}"}
              phx-click="collect"
              phx-value-id={source.id}
            >
              立即采集
            </.dm_btn>
            <.dm_btn size="sm" id={"toggle-#{source.id}"} phx-click="toggle" phx-value-id={source.id}>
              {if source.enabled, do: "停用", else: "启用"}
            </.dm_btn>
            <.link navigate={~p"/sources/#{source.id}/edit"}><.dm_btn size="sm">编辑</.dm_btn></.link>
            <.dm_btn
              size="sm"
              id={"delete-#{source.id}"}
              phx-click="delete"
              phx-value-id={source.id}
              data-confirm="删除该来源及其观测记录？条目会保留。"
            >
              删除
            </.dm_btn>
          </div>
        </:col>
      </.dm_table>
    </Layouts.app>
    """
  end
end
