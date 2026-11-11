defmodule SingularityWeb.SourceLive.Manual do
  @moduledoc """
  Manual: software projects added by hand. The list is a table; "Add project"
  opens a modal with a name and any git repository address.
  """
  use SingularityWeb, :live_view

  import SingularityWeb.ItemComponents

  alias Singularity.Knowledge

  @limit 100

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Knowledge.subscribe()

    {:ok,
     socket
     |> assign(page_title: dgettext("source", "Manual"), form: new_form())
     |> stream_configure(:projects, dom_id: &"manual-project-#{&1.item.id}")
     |> load()}
  end

  @impl true
  def handle_event("add", %{"project" => params}, socket) do
    case Knowledge.add_project(params) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, added_message(project))
         |> push_navigate(to: ~p"/knowledge/projects/#{project.id}")}

      {:existing, project} ->
        {:noreply,
         socket
         |> put_flash(:info, dgettext("source", "Already in the knowledge base"))
         |> push_navigate(to: ~p"/knowledge/projects/#{project.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :project))}
    end
  end

  @impl true
  def handle_info({:project_updated, _id}, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    projects = Knowledge.list_manual_projects(@limit)

    socket
    |> stream(:projects, projects, reset: true)
    |> assign(projects_empty?: projects == [])
  end

  defp new_form, do: to_form(Knowledge.change_manual_project(), as: :project)

  defp added_message(project) do
    if Knowledge.details_supported?(project),
      do: dgettext("source", "Project added; fetching its details"),
      else: dgettext("source", "Project added")
  end

  defp host(%{external_id: external_id}), do: external_id |> String.split("/") |> hd()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:source} active="source-manual">
      <div class="flex items-center justify-between gap-4">
        <div>
          <h1 class="text-2xl font-bold">{dgettext("source", "Manual")}</h1>
          <p class="mt-1 text-sm text-on-surface-variant">
            {dgettext("source", "Software projects added by hand, from any git repository.")}
          </p>
        </div>
        <.dm_btn
          id="open-add-project"
          variant="primary"
          size="sm"
          command="show-modal"
          commandfor="add-project-modal"
        >
          <.dm_mdi name="plus" class="h-4 w-4" />{dgettext("source", "Add project")}
        </.dm_btn>
      </div>

      <p :if={@projects_empty?} id="manual-empty" class="text-sm text-on-surface-variant">
        {dgettext("source", "Nothing added by hand yet.")}
      </p>
      <.dm_table :if={!@projects_empty?} id="manual-projects" data={@streams.projects} stream hover>
        <:col :let={%{item: project}} label={dgettext("source", "Project")}>
          <div class="min-w-0 max-w-xl">
            <.link navigate={~p"/knowledge/projects/#{project.id}"} class="font-medium">
              {project.title}
            </.link>
            <p class="truncate text-sm text-on-surface-variant">{project.url}</p>
          </div>
        </:col>
        <:col :let={%{item: project}} label={dgettext("source", "Host")}>{host(project)}</:col>
        <:col :let={%{item: project}} label={dgettext("source", "Labels")}>
          <.label_badges labels={project.labels} />
        </:col>
        <:col :let={%{item: project}} label={dgettext("source", "Details")}>
          <.details_status project={project} />
        </:col>
        <:col :let={%{manual_added_at: at}} label={dgettext("source", "Added")}>
          <span class="whitespace-nowrap text-sm text-on-surface-variant">{format_time(at)}</span>
        </:col>
      </.dm_table>

      <.dm_modal id="add-project-modal" close_label={gettext("Close")}>
        <:title>{dgettext("source", "Add project")}</:title>
        <:body>
          <.form for={@form} id="add-project-form" phx-submit="add" class="space-y-4">
            <.dm_input
              id="project-name"
              name={@form[:name].name}
              value={@form[:name].value}
              label={dgettext("source", "Name")}
              autocomplete="off"
            />
            <.field_errors form={@form} field={:name} />
            <.dm_input
              id="project-address"
              name={@form[:address].name}
              value={@form[:address].value}
              label={dgettext("source", "Repository address")}
              placeholder="https://gitlab.com/group/project"
              autocomplete="off"
            />
            <p class="text-xs text-on-surface-variant">
              {dgettext(
                "source",
                "Any git address: https://host/path, git@host:path or owner/repo for GitHub. GitHub projects get their details fetched automatically."
              )}
            </p>
            <.field_errors form={@form} field={:address} />
            <div class="flex justify-end gap-2">
              <.dm_btn type="button" variant="ghost" command="close" commandfor="add-project-modal">
                {gettext("Cancel")}
              </.dm_btn>
              <.dm_btn type="submit" variant="primary" id="add-project">
                {dgettext("source", "Add")}
              </.dm_btn>
            </div>
          </.form>
        </:body>
      </.dm_modal>
    </Layouts.app>
    """
  end
end
