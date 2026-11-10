defmodule SingularityWeb.KnowledgeLive.Show do
  use SingularityWeb, :live_view

  import SingularityWeb.ItemComponents

  alias Singularity.Knowledge

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    project = Knowledge.get_project!(id)
    if connected?(socket), do: Knowledge.subscribe()

    {:ok,
     socket
     |> assign(page_title: project.title, label_form: empty_label_form())
     |> load(project.id)}
  end

  @impl true
  def handle_event("refetch", _params, socket) do
    {:ok, _job} = Knowledge.enqueue_details(socket.assigns.project.id)

    {:noreply,
     put_flash(socket, :info, dgettext("knowledge", "Details will be fetched again shortly"))}
  end

  # Tracks the typed value so resetting the form after a save reaches the browser.
  def handle_event("edit_label", %{"label" => params}, socket),
    do: {:noreply, assign(socket, label_form: to_form(params, as: :label))}

  def handle_event("add_label", %{"label" => %{"name" => name}}, socket) do
    case Knowledge.add_label(socket.assigns.project, name) do
      {:ok, _label} ->
        {:noreply,
         socket |> assign(label_form: empty_label_form()) |> load(socket.assigns.project.id)}

      {:error, changeset} ->
        {:noreply, assign(socket, label_form: to_form(changeset, as: :label))}
    end
  end

  def handle_event("remove_label", %{"name" => name}, socket) do
    case Knowledge.remove_label(socket.assigns.project, name) do
      {:error, :auto_label} ->
        {:noreply,
         put_flash(socket, :error, dgettext("knowledge", "Automatic labels cannot be removed"))}

      _removed_or_gone ->
        {:noreply, load(socket, socket.assigns.project.id)}
    end
  end

  @impl true
  def handle_info({:project_updated, id}, %{assigns: %{project: %{id: id}}} = socket),
    do: {:noreply, load(socket, id)}

  def handle_info({:project_updated, _other}, socket),
    do: {:noreply, assign(socket, top_labels: Knowledge.top_labels(12))}

  defp load(socket, id) do
    assign(socket,
      project: Knowledge.get_project!(id),
      observations: Knowledge.list_observations(id),
      top_labels: Knowledge.top_labels(12)
    )
  end

  defp empty_label_form, do: to_form(%{"name" => ""}, as: :label)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      socket={@socket}
      section={:knowledge}
      labels={@top_labels}
      active="knowledge-projects"
    >
      <div class="flex flex-wrap items-center justify-between gap-3">
        <h1 class="text-2xl font-semibold">{@project.title}</h1>
        <.details_status project={@project} />
      </div>

      <div class="grid gap-6 lg:grid-cols-3">
        <.dm_card id="github-details" class="lg:col-span-2">
          <:title>{dgettext("knowledge", "GitHub details")}</:title>
          <p :if={@project.summary}>{@project.summary}</p>
          <div class="flex flex-wrap gap-4 text-sm">
            <a
              href={@project.url}
              target="_blank"
              rel="noopener noreferrer"
              class="inline-flex items-center gap-1 text-primary"
            >
              <.dm_mdi name="github" class="h-4 w-4" />GitHub
            </a>
            <a
              :if={@project.attributes["homepage"]}
              href={@project.attributes["homepage"]}
              target="_blank"
              rel="noopener noreferrer"
              class="inline-flex items-center gap-1 text-primary"
            >
              <.dm_mdi name="open-in-new" class="h-4 w-4" />{dgettext("knowledge", "Homepage")}
            </a>
          </div>
          <dl class="grid grid-cols-[10rem_1fr] gap-1 text-sm">
            <dt>{dgettext("knowledge", "Stars")}</dt>
            <dd>{format_count(@project.attributes["stars"])}</dd>
            <dt>{dgettext("knowledge", "Forks")}</dt>
            <dd>{format_count(@project.attributes["forks"])}</dd>
            <dt>{dgettext("knowledge", "Language")}</dt>
            <dd>{@project.attributes["language"] || "—"}</dd>
            <dt>{dgettext("knowledge", "License")}</dt>
            <dd>{@project.attributes["license"] || "—"}</dd>
            <dt>{dgettext("knowledge", "Created")}</dt>
            <dd>{format_date(@project.attributes["created_at"])}</dd>
            <dt>{dgettext("knowledge", "Last pushed")}</dt>
            <dd>{format_date(@project.attributes["pushed_at"])}</dd>
            <dt>{dgettext("knowledge", "Archived")}</dt>
            <dd>
              {if @project.attributes["archived"],
                do: dgettext("knowledge", "Yes"),
                else: dgettext("knowledge", "No")}
            </dd>
            <dt>{dgettext("knowledge", "Details fetched")}</dt>
            <dd>{format_time(@project.details_fetched_at)}</dd>
          </dl>
          <p :if={@project.details_error} id="details-error" class="text-sm text-error">
            {@project.details_error}
          </p>
          <:action>
            <.dm_btn id="refetch" size="sm" phx-click="refetch">
              <.dm_mdi name="refresh" class="h-4 w-4" />{dgettext("knowledge", "Fetch again")}
            </.dm_btn>
          </:action>
        </.dm_card>

        <.dm_card id="project-labels">
          <:title>{dgettext("knowledge", "Labels")}</:title>
          <ul class="flex flex-wrap gap-2">
            <li :for={label <- @project.labels} id={"project-label-#{label.id}"}>
              <.dm_badge
                size="sm"
                variant={label_variant(label.origin)}
                soft={label.origin == "auto"}
                data-origin={label.origin}
              >
                {label.name}
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
          <.form
            for={@label_form}
            id="label-form"
            phx-change="edit_label"
            phx-submit="add_label"
            class="flex items-end gap-2"
          >
            <.dm_input
              id="label-name"
              name={@label_form[:name].name}
              value={@label_form[:name].value}
              label={dgettext("knowledge", "Add label")}
            />
            <.dm_btn type="submit" size="sm" variant="primary">
              {dgettext("knowledge", "Add")}
            </.dm_btn>
          </.form>
          <.field_errors form={@label_form} field={:name} />
        </.dm_card>
      </div>

      <h2 class="text-lg font-semibold">{dgettext("knowledge", "Source records")}</h2>
      <.dm_table id="observations" data={@observations}>
        <:col :let={obs} label={dgettext("knowledge", "Time")}>{format_time(obs.observed_at)}</:col>
        <:col :let={obs} label={dgettext("knowledge", "Source")}>
          {if obs.source, do: obs.source.name, else: dgettext("knowledge", "Added manually")}
        </:col>
        <:col :let={obs} label={dgettext("knowledge", "Period")}>{obs.period}</:col>
        <:col :let={obs} label={dgettext("knowledge", "Rank")}>{obs.rank || "—"}</:col>
        <:col :let={obs} label={dgettext("knowledge", "Stars in period")}>
          {format_count(obs.attributes["stars_in_period"])}
        </:col>
      </.dm_table>
    </Layouts.app>
    """
  end
end
