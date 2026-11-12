defmodule SingularityWeb.KnowledgeLive.RfcShow do
  use SingularityWeb, :live_view

  import SingularityWeb.ItemComponents,
    only: [markdown: 1, label_variant: 1, format_date: 1, format_time: 1, format_count: 1]

  import SingularityWeb.RfcComponents

  alias Singularity.Knowledge

  @related [
    {"obsoletes", "Obsoletes"},
    {"obsoleted_by", "Obsoleted by"},
    {"updates", "Updates"},
    {"updated_by", "Updated by"},
    {"see_also", "See also"}
  ]

  @impl true
  def mount(%{"number" => number}, _session, socket) do
    rfc = Knowledge.get_rfc!(parse_number(number))
    if connected?(socket), do: Knowledge.subscribe()

    {:ok,
     socket
     |> assign(page_title: "#{rfc_name(rfc)}: #{rfc.title}", label_form: empty_label_form())
     |> load(rfc)}
  end

  # Anything but a positive number finds no RFC, so the page is a 404.
  defp parse_number(number) do
    case Integer.parse(number) do
      {number, ""} when number > 0 -> number
      _other -> 0
    end
  end

  @impl true
  def handle_event("edit_label", %{"label" => params}, socket),
    do: {:noreply, assign(socket, label_form: to_form(params, as: :label))}

  def handle_event("add_label", %{"label" => %{"name" => name}}, socket) do
    case Knowledge.add_label(socket.assigns.rfc, name) do
      {:ok, _label} ->
        {:noreply, socket |> assign(label_form: empty_label_form()) |> reload()}

      {:error, changeset} ->
        {:noreply, assign(socket, label_form: to_form(changeset, as: :label))}
    end
  end

  def handle_event("remove_label", %{"name" => name}, socket) do
    case Knowledge.remove_label(socket.assigns.rfc, name) do
      {:error, :auto_label} ->
        {:noreply,
         put_flash(socket, :error, dgettext("knowledge", "Automatic labels cannot be removed"))}

      _removed_or_gone ->
        {:noreply, reload(socket)}
    end
  end

  @impl true
  def handle_info({:project_updated, id}, %{assigns: %{rfc: %{id: id}}} = socket),
    do: {:noreply, reload(socket)}

  def handle_info({:project_updated, _other}, socket), do: {:noreply, socket}

  defp reload(socket),
    do: load(socket, Knowledge.get_rfc!(socket.assigns.rfc.attributes["number"]))

  defp load(socket, rfc) do
    related_ids = Enum.flat_map(@related, fn {key, _label} -> rfc.attributes[key] || [] end)

    assign(socket,
      rfc: rfc,
      related: Knowledge.get_rfcs_by_external_ids(related_ids),
      changes: Knowledge.list_item_changes(rfc.id)
    )
  end

  defp empty_label_form, do: to_form(%{"name" => ""}, as: :label)

  defp related_groups(attributes) do
    for {key, label} <- @related, (ids = attributes[key] || []) != [], do: {key, label, ids}
  end

  defp related_label("Obsoletes"), do: dgettext("knowledge", "Obsoletes")
  defp related_label("Obsoleted by"), do: dgettext("knowledge", "Obsoleted by")
  defp related_label("Updates"), do: dgettext("knowledge", "Updates")
  defp related_label("Updated by"), do: dgettext("knowledge", "Updated by")
  defp related_label("See also"), do: dgettext("knowledge", "See also")

  defp related_name("rfc" <> number), do: "RFC #{number}"
  defp related_name(other), do: String.upcase(other)

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :attributes, assigns.rfc.attributes)

    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:knowledge} active="knowledge-rfcs">
      <header id="rfc-header" class="space-y-3">
        <div class="space-y-2">
          <div class="flex flex-wrap items-center gap-2">
            <h1 class="text-2xl font-bold">{rfc_name(@rfc)}</h1>
            <.rfc_status status={@attributes["status"]} />
          </div>
          <p id="rfc-title" class="max-w-3xl text-lg">{@rfc.title}</p>
        </div>

        <ul
          id="rfc-facts"
          class="flex flex-wrap items-center gap-x-5 gap-y-2 text-sm text-on-surface-variant"
        >
          <li class="inline-flex items-center gap-1" title={dgettext("knowledge", "Published")}>
            <.dm_mdi name="calendar-month-outline" class="h-4 w-4" />
            <span class="text-on-surface">{published_month(@rfc.published_at)}</span>
          </li>
          <li
            :if={@attributes["page_count"]}
            class="inline-flex items-center gap-1"
            title={dgettext("knowledge", "Pages")}
          >
            <.dm_mdi name="file-outline" class="h-4 w-4" />
            <span class="text-on-surface">{format_count(@attributes["page_count"])}</span>
          </li>
          <li>
            <.external_link href={@rfc.url} class="inline-flex items-center gap-1 text-primary">
              <.dm_mdi name="open-in-new" class="h-4 w-4" />rfc-editor.org
            </.external_link>
          </li>
          <li :if={@attributes["doi"]}>
            <.external_link
              href={"https://doi.org/" <> @attributes["doi"]}
              class="inline-flex items-center gap-1 text-primary"
            >
              <.dm_mdi name="link-variant" class="h-4 w-4" />DOI
            </.external_link>
          </li>
          <li :if={@attributes["errata_url"]}>
            <.external_link
              href={@attributes["errata_url"]}
              class="inline-flex items-center gap-1 text-primary"
            >
              <.dm_mdi name="alert-circle-outline" class="h-4 w-4" />{dgettext("knowledge", "Errata")}
            </.external_link>
          </li>
        </ul>
      </header>

      <.dm_alert :if={@rfc.removal_due_at} id="removal-notice" variant="warning">
        {dgettext(
          "knowledge",
          "The RFC Editor no longer lists this RFC. It will be removed on %{date} unless it is listed again.",
          date: format_date(@rfc.removal_due_at)
        )}
      </.dm_alert>

      <div class="grid items-start gap-6 lg:grid-cols-3">
        <div class="space-y-6 lg:col-span-2">
          <.dm_card :if={@rfc.summary} id="rfc-abstract">
            <h2 class="text-lg font-semibold">{dgettext("knowledge", "Abstract")}</h2>
            <p class="whitespace-pre-line">{@rfc.summary}</p>
          </.dm_card>

          <.dm_card id="rfc-content">
            <h2 class="text-lg font-semibold">{dgettext("knowledge", "Full text")}</h2>
            <div :if={@rfc.content} class="max-h-[48rem] overflow-y-auto pr-2">
              <.markdown id="rfc-content-body" source={@rfc.content} />
            </div>
            <div
              :if={!@rfc.content}
              id="rfc-content-empty"
              class="rounded-lg border border-dashed border-outline-variant px-4 py-6 text-center text-sm text-on-surface-variant"
            >
              {dgettext("knowledge", "Full text not synced yet.")}
            </div>
          </.dm_card>
        </div>

        <aside class="space-y-6">
          <.dm_card id="rfc-about">
            <h2 class="text-lg font-semibold">{dgettext("knowledge", "About")}</h2>
            <dl class="grid grid-cols-[8rem_1fr] gap-x-3 gap-y-2 text-sm">
              <dt class="text-on-surface-variant">{dgettext("knowledge", "Authors")}</dt>
              <dd>{field_value(@attributes["authors"])}</dd>
              <dt class="text-on-surface-variant">{dgettext("knowledge", "Working group")}</dt>
              <dd>{@attributes["stream_source"] || "—"}</dd>
              <dt class="text-on-surface-variant">{dgettext("knowledge", "Draft")}</dt>
              <dd class="break-all">{@attributes["draft"] || "—"}</dd>
              <dt class="text-on-surface-variant">{dgettext("knowledge", "Keywords")}</dt>
              <dd>{field_value(@attributes["keywords"])}</dd>
              <dt class="text-on-surface-variant">{dgettext("knowledge", "Text updated")}</dt>
              <dd>{format_time(@rfc.content_updated_at)}</dd>
            </dl>
          </.dm_card>

          <.dm_card id="rfc-related">
            <h2 class="text-lg font-semibold">{dgettext("knowledge", "Related RFCs")}</h2>
            <dl
              :if={related_groups(@attributes) != []}
              class="grid grid-cols-[8rem_1fr] gap-x-3 gap-y-2 text-sm"
            >
              <%= for {key, label, ids} <- related_groups(@attributes) do %>
                <dt class="text-on-surface-variant">{related_label(label)}</dt>
                <dd id={"related-#{key}"} class="flex flex-wrap gap-x-2">
                  <%= for id <- ids do %>
                    <.link
                      :if={@related[id]}
                      navigate={item_path(@related[id])}
                      class="text-primary"
                      title={@related[id].title}
                    >
                      {related_name(id)}
                    </.link>
                    <span :if={!@related[id]} data-missing>{related_name(id)}</span>
                  <% end %>
                </dd>
              <% end %>
            </dl>
            <p :if={related_groups(@attributes) == []} class="text-sm text-on-surface-variant">
              {dgettext("knowledge", "No related RFCs.")}
            </p>
          </.dm_card>

          <.dm_card id="rfc-labels">
            <h2 class="text-lg font-semibold">{dgettext("knowledge", "Labels")}</h2>
            <ul :if={@rfc.labels != []} class="flex flex-wrap gap-2">
              <li :for={label <- @rfc.labels} id={"rfc-label-#{label.id}"}>
                <.dm_badge
                  variant={label_variant(label.origin)}
                  soft={label.origin == "auto"}
                  data-origin={label.origin}
                >
                  <.link navigate={~p"/knowledge/ietf-rfcs?#{%{label: label.name}}"}>
                    {label.name}
                  </.link>
                  <button
                    :if={label.origin == "manual"}
                    type="button"
                    id={"remove-label-#{label.id}"}
                    phx-click="remove_label"
                    phx-value-name={label.name}
                    aria-label={dgettext("knowledge", "Remove label %{name}", name: label.name)}
                  >
                    <.dm_mdi name="close" class="h-3 w-3" />
                  </button>
                </.dm_badge>
              </li>
            </ul>
            <p :if={@rfc.labels == []} class="text-sm text-on-surface-variant">
              {dgettext("knowledge", "No labels yet.")}
            </p>
            <.form
              for={@label_form}
              id="label-form"
              phx-change="edit_label"
              phx-submit="add_label"
              class="flex items-center gap-2"
            >
              <div class="min-w-0 flex-1">
                <.dm_input
                  id="label-name"
                  name={@label_form[:name].name}
                  value={@label_form[:name].value}
                  size="sm"
                  placeholder={dgettext("knowledge", "Add label")}
                  aria-label={dgettext("knowledge", "Add label")}
                  autocomplete="off"
                />
              </div>
              <.dm_btn type="submit" size="sm" variant="outline">
                <.dm_mdi name="plus" class="h-4 w-4" />{dgettext("knowledge", "Add")}
              </.dm_btn>
            </.form>
            <.field_errors form={@label_form} field={:name} />
          </.dm_card>
        </aside>
      </div>

      <section class="space-y-3">
        <h2 class="text-lg font-semibold">{dgettext("knowledge", "History")}</h2>
        <p :if={@changes == []} id="rfc-history-empty" class="text-sm text-on-surface-variant">
          {dgettext("knowledge", "No recorded changes.")}
        </p>
        <.dm_table :if={@changes != []} id="rfc-history" data={@changes} hover>
          <:col :let={change} label={dgettext("knowledge", "Run")}>
            <.link navigate={~p"/source/runs/#{change.fetch_run_id}"} class="text-primary">
              {format_time(change.fetch_run.started_at)}
            </.link>
          </:col>
          <:col :let={change} label={dgettext("knowledge", "Change")}>
            <.change_badge change={change.change} />
          </:col>
          <:col :let={change} label={dgettext("knowledge", "What changed")}>
            {change_summary(change)}
          </:col>
        </.dm_table>
      </section>
    </Layouts.app>
    """
  end

  defp change_summary(%{fields: fields, content_diff: diff}) do
    names = fields |> Map.keys() |> Enum.sort()
    names = if diff in [nil, ""], do: names, else: names ++ [dgettext("knowledge", "full text")]
    if names == [], do: "—", else: Enum.join(names, ", ")
  end
end
