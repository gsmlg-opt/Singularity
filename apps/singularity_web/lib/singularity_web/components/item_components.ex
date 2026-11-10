defmodule SingularityWeb.ItemComponents do
  @moduledoc """
  Knowledge item rendering. Software projects are the only kind in v2; a new
  item kind gets its own component here.
  """

  use SingularityWeb, :html

  attr :item, :map, required: true

  def item_meta(%{item: %{kind: "github_repo"}} = assigns) do
    ~H"""
    <span data-role="item-meta">
      {@item.attributes["language"] || "—"} · ★ {format_count(@item.attributes["stars"])} · forks {format_count(
        @item.attributes["forks"]
      )}
    </span>
    """
  end

  def item_meta(assigns), do: ~H""

  attr :kind, :string, required: true
  attr :attributes, :map, required: true

  def observation_meta(%{kind: "github_repo"} = assigns) do
    ~H"""
    <span>★ {format_count(@attributes["stars"])} · +{format_count(@attributes["stars_in_period"])} ({@attributes[
      "since"
    ]})</span>
    """
  end

  def observation_meta(assigns) do
    ~H"""
    <span>{Enum.map_join(@attributes || %{}, " · ", fn {key, value} -> "#{key}: #{value}" end)}</span>
    """
  end

  attr :project, :map, required: true

  def project_card(assigns) do
    ~H"""
    <.dm_card id={"project-#{@project.id}"} class="h-full" shadow="sm">
      <:title>
        <.link navigate={~p"/knowledge/projects/#{@project.id}"} class="hover:underline">
          {@project.title}
        </.link>
      </:title>
      <p :if={@project.summary} class="text-sm text-on-surface-variant line-clamp-3">
        {@project.summary}
      </p>
      <div class="flex flex-wrap items-center gap-3 text-xs text-on-surface-variant">
        <span class="inline-flex items-center gap-1">
          <.dm_mdi name="star-outline" class="h-4 w-4" />{format_count(@project.attributes["stars"])}
        </span>
        <span :if={@project.attributes["language"]} class="inline-flex items-center gap-1">
          <.dm_mdi name="code-tags" class="h-4 w-4" />{@project.attributes["language"]}
        </span>
        <.details_status project={@project} />
      </div>
      <.label_badges labels={@project.labels} />
    </.dm_card>
    """
  end

  attr :project, :map, required: true

  def details_status(assigns) do
    ~H"""
    <.dm_badge :if={@project.details_error} variant="error" size="sm" data-role="details-status">
      {dgettext("knowledge", "Details failed")}
    </.dm_badge>
    <.dm_badge
      :if={!@project.details_error && !@project.details_fetched_at}
      variant="info"
      size="sm"
      data-role="details-status"
    >
      {dgettext("knowledge", "Fetching details")}
    </.dm_badge>
    """
  end

  attr :labels, :list, required: true

  def label_badges(assigns) do
    ~H"""
    <div :if={@labels != []} class="flex flex-wrap gap-1">
      <.dm_badge
        :for={label <- @labels}
        size="sm"
        variant={label_variant(label.origin)}
        soft={label.origin == "auto"}
        data-origin={label.origin}
      >
        {label.name}
      </.dm_badge>
    </div>
    """
  end

  @doc "Manual labels use a different style from automatic ones."
  def label_variant("manual"), do: "secondary"
  def label_variant(_auto), do: "neutral"

  def format_count(nil), do: "—"

  def format_count(number) when is_integer(number),
    do: number |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")

  def format_count(other), do: to_string(other)

  def format_time(nil), do: "—"
  def format_time(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  def format_date(nil), do: "—"
  def format_date(iso8601) when is_binary(iso8601), do: String.slice(iso8601, 0, 10)
end
