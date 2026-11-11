defmodule SingularityWeb.ItemComponents do
  @moduledoc """
  Knowledge item rendering. Software projects are the only kind in v2; a new
  item kind gets its own component here.
  """

  use SingularityWeb, :html

  @doc """
  Software projects as a table. `rows` is a stream configured with
  `dom_id: &"project-\#{&1.id}"`.
  """
  attr :id, :string, required: true
  attr :rows, :any, required: true

  def project_table(assigns) do
    ~H"""
    <.dm_table id={@id} data={@rows} stream hover>
      <:col :let={project} label={dgettext("knowledge", "Project")}>
        <div class="min-w-0 max-w-xl">
          <.link navigate={~p"/knowledge/projects/#{project.id}"} class="font-medium">
            {project.title}
          </.link>
          <p :if={project.summary} class="text-sm text-on-surface-variant line-clamp-1">
            {project.summary}
          </p>
        </div>
      </:col>
      <:col :let={project} label={dgettext("knowledge", "Language")}>
        {project.attributes["language"] || "—"}
      </:col>
      <:col :let={project} label={dgettext("knowledge", "Stars")}>
        {format_count(project.attributes["stars"])}
      </:col>
      <:col :let={project} label={dgettext("knowledge", "Labels")}>
        <.label_badges labels={project.labels} />
      </:col>
      <:col :let={project} label={dgettext("knowledge", "Details")}>
        <.details_status project={project} />
      </:col>
    </.dm_table>
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
