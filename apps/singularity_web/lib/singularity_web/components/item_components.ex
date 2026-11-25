defmodule SingularityWeb.ItemComponents do
  @moduledoc "Knowledge item rendering and links."

  use SingularityWeb, :html

  @doc "The detail page of a changed or listed item, or nil when it has none."
  def item_path(%{kind: "ietf_rfc", external_id: "rfc" <> number}),
    do: ~p"/knowledge/ietf-rfcs/#{number}"

  def item_path(%{kind: "software_project", item_id: id}) when is_integer(id),
    do: ~p"/knowledge/projects/#{id}"

  def item_path(%{kind: "software_project", id: id}) when is_integer(id),
    do: ~p"/knowledge/projects/#{id}"

  def item_path(%{kind: "published_book", id: id}), do: ~p"/knowledge/books/#{id}"

  def item_path(_item), do: nil

  @doc """
  Software projects as a table. `rows` is a stream configured with
  `dom_id: &"project-\#{&1.id}"`.
  """
  attr :id, :string, required: true
  attr :rows, :any, required: true

  def project_table(assigns) do
    ~H"""
    <.dm_table id={@id} data={@rows} stream hover class="knowledge-result-table table-fixed">
      <:col :let={project} label={dgettext("knowledge", "Project")}>
        <div class="min-w-0 space-y-1">
          <.link
            navigate={~p"/knowledge/projects/#{project.id}"}
            class="rounded text-base font-semibold [overflow-wrap:anywhere] hover:underline focus-visible:outline-2"
          >
            {project.title}
          </.link>
          <p :if={project.summary} class="text-sm text-on-surface-variant line-clamp-1">
            {inline_markdown(project.summary)}
          </p>
          <div class="flex flex-wrap gap-1 empty:hidden">
            <.details_status project={project} />
          </div>
        </div>
      </:col>
      <:col
        :let={project}
        label={dgettext("knowledge", "Language")}
        label_class="w-[15%]"
        class="text-on-surface-variant [overflow-wrap:anywhere]"
      >
        {project.attributes["language"] || "—"}
      </:col>
      <:col
        :let={project}
        label={dgettext("knowledge", "Stars")}
        label_class="w-[13%]"
        class="tabular-nums"
      >
        <span class="inline-flex items-center gap-1.5 whitespace-nowrap">
          <.dm_mdi name="star-outline" class="size-4 text-on-surface-variant" aria-hidden="true" />
          {format_count(project.attributes["stars"])}
        </span>
      </:col>
      <:col
        :let={project}
        label={dgettext("knowledge", "Labels")}
        label_class="w-[29%]"
        class="result-labels"
      >
        <.project_labels labels={project.labels} />
      </:col>
    </.dm_table>
    """
  end

  attr :labels, :list, required: true

  defp project_labels(assigns) do
    {preview, more} =
      assigns.labels
      |> Enum.sort_by(fn label ->
        {label.origin != "manual", String.starts_with?(label.name, "lang:")}
      end)
      |> Enum.split(2)

    assigns = assign(assigns, preview: preview, more: more)

    ~H"""
    <div :if={@preview != []} class="flex flex-wrap items-center gap-1.5">
      <.label_badges labels={@preview} size="md" />
      <details :if={@more != []} class="min-w-0 open:basis-full">
        <summary
          aria-label={
            dngettext(
              "knowledge",
              "%{count} additional label",
              "%{count} additional labels",
              length(@more)
            )
          }
          class="w-fit cursor-pointer rounded-full bg-secondary-container px-2 py-0.5 text-xs font-medium text-on-secondary-container focus-visible:outline-2"
        >
          +{length(@more)}
        </summary>
        <div class="mt-1.5"><.label_badges labels={@more} size="md" /></div>
      </details>
    </div>
    """
  end

  attr :project, :map, required: true

  def details_status(assigns) do
    assigns =
      assign(assigns, :supported?, Singularity.Knowledge.details_supported?(assigns.project))

    ~H"""
    <.dm_badge
      :if={Singularity.Knowledge.deprecated?(@project)}
      variant="warning"
      size="sm"
      data-role="deprecated-status"
    >
      {dgettext("knowledge", "Deprecated")}
    </.dm_badge>
    <.dm_badge
      :if={@project.removal_due_at}
      variant="warning"
      size="sm"
      data-role="removal-status"
    >
      {dgettext("knowledge", "Removal on %{date}", date: format_date(@project.removal_due_at))}
    </.dm_badge>
    <.dm_badge :if={!@supported?} variant="neutral" size="sm" data-role="details-status">
      {dgettext("knowledge", "No automatic details")}
    </.dm_badge>
    <.dm_badge
      :if={@supported? && @project.details_error}
      variant="error"
      size="sm"
      data-role="details-status"
    >
      {dgettext("knowledge", "Details failed")}
    </.dm_badge>
    <.dm_badge
      :if={@supported? && !@project.details_error && !@project.details_fetched_at}
      variant="info"
      size="sm"
      data-role="details-status"
    >
      {dgettext("knowledge", "Fetching details")}
    </.dm_badge>
    """
  end

  @markdown_options [
    extension: [shortcodes: true],
    render: [unsafe: true, hardbreaks: false],
    sanitize: MDEx.Document.default_sanitize_options()
  ]

  attr :id, :string, required: true
  attr :source, :string, required: true

  attr :repository, :map,
    default: nil,
    doc:
      "`%{raw: base, blob: base}` from `repository_bases/1`: relative images and links resolve against it"

  @doc """
  Markdown rendered on the server, styled by the design system's `markdown-body`.
  Sources are untrusted (READMEs come from other people's repositories): only
  GFM is enabled and the HTML is sanitized. With `repository`, relative image
  and link addresses point into that repository, as they do on GitHub.
  """
  def markdown(assigns) do
    assigns = assign(assigns, :html, render_markdown(assigns.source, assigns.repository))

    ~H"""
    <div id={@id} class="markdown-body">{@html}</div>
    """
  end

  defp render_markdown(source, repository) do
    source
    |> MDEx.parse_document!(@markdown_options ++ [plugins: [MDExGFM]])
    |> resolve_addresses(repository)
    |> route_outbound()
    |> MDEx.to_html!(@markdown_options)
    |> Phoenix.HTML.raw()
  end

  @doc "Where a GitHub project's relative README addresses point, or nil off GitHub."
  def repository_bases(%{external_id: "github.com/" <> path, attributes: attributes}) do
    branch = attributes["default_branch"] || "HEAD"

    %{
      raw: "https://raw.githubusercontent.com/#{path}/#{branch}/",
      blob: "https://github.com/#{path}/blob/#{branch}/"
    }
  end

  def repository_bases(_project), do: nil

  @html_href ~r/\b(href)\s*=\s*(["'])([^"']*)\2/i
  @html_address ~r/\b(src|href)\s*=\s*(["'])([^"']*)\2/i

  defp resolve_addresses(document, nil), do: document

  defp resolve_addresses(document, %{raw: raw, blob: blob}) do
    MDEx.traverse_and_update(document, fn
      %MDEx.Image{url: url} = node ->
        %{node | url: absolute(url, raw)}

      %MDEx.Link{url: url} = node ->
        %{node | url: absolute(url, blob)}

      %{__struct__: html, literal: literal} = node
      when html in [MDEx.HtmlBlock, MDEx.HtmlInline] ->
        literal =
          Regex.replace(@html_address, literal, fn _all, attribute, quote, url ->
            base = if String.downcase(attribute) == "src", do: raw, else: blob
            "#{attribute}=#{quote}#{absolute(url, base)}#{quote}"
          end)

        %{node | literal: literal}

      node ->
        node
    end)
  end

  # Links to other sites go through the confirmation page; images load directly.
  defp route_outbound(document) do
    MDEx.traverse_and_update(document, fn
      %MDEx.Link{url: url} = node ->
        %{node | url: outbound(url)}

      %{__struct__: html, literal: literal} = node
      when html in [MDEx.HtmlBlock, MDEx.HtmlInline] ->
        literal =
          Regex.replace(@html_href, literal, fn _all, attribute, quote, url ->
            "#{attribute}=#{quote}#{url |> unescape_html() |> outbound() |> escape_html()}#{quote}"
          end)

        %{node | literal: literal}

      node ->
        node
    end)
  end

  defp outbound(url) do
    if SingularityWeb.Outbound.web?(url), do: SingularityWeb.Outbound.path(url), else: url
  end

  defp unescape_html(url), do: String.replace(url, "&amp;", "&")
  defp escape_html(url), do: String.replace(url, "&", "&amp;")

  # Absolute URLs, protocol-relative ones and fragments stay; "/x" is the repository root.
  defp absolute(url, base) do
    cond do
      url == "" or String.starts_with?(url, ["#", "//"]) -> url
      Regex.match?(~r/^[a-z][a-z0-9+.-]*:/i, url) -> url
      String.starts_with?(url, "/") -> base <> String.trim_leading(url, "/")
      true -> base |> URI.merge(url) |> URI.to_string()
    end
  end

  @doc "One line of Markdown (a GitHub description): emoji shortcodes and inline marks, sanitized."
  def inline_markdown(text) when is_binary(text) do
    text
    |> MDEx.parse_document!(@markdown_options)
    |> route_outbound()
    |> MDEx.to_html!(@markdown_options)
    |> String.trim()
    |> String.replace_prefix("<p>", "")
    |> String.replace_suffix("</p>", "")
    |> Phoenix.HTML.raw()
  end

  attr :labels, :list, required: true
  attr :size, :string, default: "sm"

  def label_badges(assigns) do
    ~H"""
    <div :if={@labels != []} class="flex flex-wrap gap-1">
      <.dm_badge
        :for={label <- @labels}
        size={@size}
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
  def format_date(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d")
end
