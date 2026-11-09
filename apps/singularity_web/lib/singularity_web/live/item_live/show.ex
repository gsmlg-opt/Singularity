defmodule SingularityWeb.ItemLive.Show do
  use SingularityWeb, :live_view

  import SingularityWeb.ItemComponents

  alias Singularity.Knowledge

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    item = Knowledge.get_item!(id)
    {:ok, assign(socket, item: item, observations: Knowledge.list_observations(item.id))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current={:items}>
      <div class="space-y-2">
        <h1 class="text-2xl font-semibold">{@item.title}</h1>
        <a href={@item.url} target="_blank" rel="noopener noreferrer" class="text-primary">{@item.url}</a>
        <p :if={@item.summary}>{@item.summary}</p>
        <div class="text-sm flex flex-wrap gap-3">
          <.dm_badge size="sm">{@item.kind}</.dm_badge>
          <.item_meta item={@item} />
          <span :if={@item.published_at}>发布于 {format_time(@item.published_at)}</span>
          <span>首次观测 {format_time(@item.first_seen_at)}</span>
          <span>最近观测 {format_time(@item.last_seen_at)}</span>
        </div>
      </div>

      <h2 class="text-lg font-semibold">观测历史</h2>
      <.dm_table id="observations" data={@observations}>
        <:col :let={obs} label="时间">{format_time(obs.observed_at)}</:col>
        <:col :let={obs} label="来源">{obs.source.name}</:col>
        <:col :let={obs} label="期次">{obs.period}</:col>
        <:col :let={obs} label="排名">{obs.rank || "—"}</:col>
        <:col :let={obs} label="指标">
          <.observation_meta kind={@item.kind} attributes={obs.attributes} />
        </:col>
      </.dm_table>
    </Layouts.app>
    """
  end
end
