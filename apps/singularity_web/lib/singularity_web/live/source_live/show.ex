defmodule SingularityWeb.SourceLive.Show do
  use SingularityWeb, :live_view

  import SingularityWeb.ItemComponents, only: [format_time: 1]

  alias Singularity.{Collection, Sources}
  alias SingularityWeb.SourceLive.Index

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Collection.subscribe()
    source = Sources.get_source!(id)
    {:ok, assign(socket, source: source, runs: Collection.list_runs(source.id))}
  end

  @impl true
  def handle_event("collect", _params, socket) do
    {:ok, _job} = Collection.enqueue(socket.assigns.source.id)
    {:noreply, put_flash(socket, :info, "已加入采集队列")}
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
    <Layouts.app flash={@flash} current={:sources}>
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">{@source.name}</h1>
        <div class="flex gap-2">
          <.dm_btn :if={@source.enabled} size="sm" id="collect-now" phx-click="collect">立即采集</.dm_btn>
          <.link navigate={~p"/sources/#{@source.id}/edit"}><.dm_btn size="sm">编辑</.dm_btn></.link>
        </div>
      </div>

      <dl class="grid grid-cols-[8rem_1fr] gap-1 text-sm">
        <dt>类型</dt><dd>{Sources.type_label(@source)}</dd>
        <dt>配置</dt><dd><code>{Jason.encode!(@source.config)}</code></dd>
        <dt>间隔</dt><dd>{@source.interval_minutes} 分钟</dd>
        <dt>状态</dt><dd>{if @source.enabled, do: "启用", else: "停用"}</dd>
        <dt>下次采集</dt><dd>{format_time(@source.next_run_at)}</dd>
      </dl>

      <h2 class="text-lg font-semibold">最近采集</h2>
      <.dm_table id="runs" data={@runs}>
        <:col :let={run} label="状态">
          <.dm_badge size="sm" variant={Index.run_variant(run.status)}>{run.status}</.dm_badge>
        </:col>
        <:col :let={run} label="开始">{format_time(run.started_at)}</:col>
        <:col :let={run} label="结束">{format_time(run.finished_at)}</:col>
        <:col :let={run} label="条数">{run.item_count}</:col>
        <:col :let={run} label="跳过">{run.skipped_count}</:col>
        <:col :let={run} label="错误">{run.error}</:col>
      </.dm_table>
    </Layouts.app>
    """
  end
end
