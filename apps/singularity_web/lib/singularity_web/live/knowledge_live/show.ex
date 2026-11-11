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
  def handle_event("refetch", _params, %{assigns: %{details_supported?: true}} = socket) do
    {:ok, _job} = Knowledge.enqueue_details(socket.assigns.project.id)
    {:ok, _job} = Knowledge.enqueue_readme(socket.assigns.project.id)

    {:noreply,
     put_flash(socket, :info, dgettext("knowledge", "Details will be fetched again shortly"))}
  end

  def handle_event("save_instruction", %{"project" => params}, socket) do
    case Knowledge.update_instruction(socket.assigns.project, params) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, dgettext("knowledge", "Instruction saved"))
         |> push_navigate(to: ~p"/knowledge/projects/#{project.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, instruction_form: to_form(changeset, as: :project))}
    end
  end

  def handle_event("deprecate", %{"deprecation" => %{"reason" => reason}}, socket) do
    {:ok, project} = Knowledge.deprecate(socket.assigns.project, reason)

    {:noreply,
     socket
     |> put_flash(:info, dgettext("knowledge", "Marked as deprecated"))
     |> push_navigate(to: ~p"/knowledge/projects/#{project.id}")}
  end

  def handle_event("undeprecate", _params, socket) do
    {:ok, project} = Knowledge.undeprecate(socket.assigns.project)
    {:noreply, load(socket, project.id)}
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

  def handle_info({:project_updated, _other}, socket), do: {:noreply, socket}

  defp load(socket, id) do
    project = Knowledge.get_project!(id)

    assign(socket,
      project: project,
      details_supported?: Knowledge.details_supported?(project),
      deprecated?: Knowledge.deprecated?(project),
      instruction_form: to_form(Knowledge.change_instruction(project), as: :project),
      item_sources: Knowledge.list_item_sources(id),
      observations: Knowledge.list_observations(id)
    )
  end

  defp empty_label_form, do: to_form(%{"name" => ""}, as: :label)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:knowledge} active="knowledge-projects">
      <header id="project-header" class="space-y-3">
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div class="min-w-0 space-y-2">
            <div class="flex flex-wrap items-center gap-2">
              <h1 class="break-all text-2xl font-bold">{@project.title}</h1>
              <.details_status project={@project} />
            </div>
            <p :if={@project.summary} id="project-summary" class="max-w-3xl text-on-surface-variant">
              {inline_markdown(@project.summary)}
            </p>
          </div>
          <div class="flex shrink-0 flex-wrap gap-2">
            <.dm_btn
              :if={@details_supported?}
              id="refetch"
              size="sm"
              variant="secondary"
              phx-click="refetch"
            >
              <.dm_mdi name="refresh" class="h-4 w-4" />{dgettext("knowledge", "Fetch again")}
            </.dm_btn>
            <.dm_btn
              :if={!@project.deprecated_at}
              id="open-deprecate"
              size="sm"
              variant="outline"
              command="show-modal"
              commandfor="deprecate-modal"
            >
              <.dm_mdi name="archive-alert-outline" class="h-4 w-4" />
              {dgettext("knowledge", "Mark deprecated")}
            </.dm_btn>
            <.dm_btn
              :if={@project.deprecated_at}
              id="undeprecate"
              size="sm"
              variant="outline"
              phx-click="undeprecate"
              data-confirm={dgettext("knowledge", "Clear the deprecated mark?")}
            >
              <.dm_mdi name="archive-arrow-up-outline" class="h-4 w-4" />
              {dgettext("knowledge", "Not deprecated")}
            </.dm_btn>
          </div>
        </div>

        <ul
          id="project-facts"
          class="flex flex-wrap items-center gap-x-5 gap-y-2 text-sm text-on-surface-variant"
        >
          <li
            :if={@details_supported?}
            class="inline-flex items-center gap-1"
            title={dgettext("knowledge", "Stars")}
          >
            <.dm_mdi name="star-outline" class="h-4 w-4" />
            <span class="font-medium text-on-surface">{format_count(@project.attributes["stars"])}</span>
          </li>
          <li
            :if={@details_supported?}
            class="inline-flex items-center gap-1"
            title={dgettext("knowledge", "Forks")}
          >
            <.dm_mdi name="source-fork" class="h-4 w-4" />
            <span class="font-medium text-on-surface">{format_count(@project.attributes["forks"])}</span>
          </li>
          <li
            :if={@project.attributes["language"]}
            class="inline-flex items-center gap-1"
            title={dgettext("knowledge", "Language")}
          >
            <.dm_mdi name="code-tags" class="h-4 w-4" />{@project.attributes["language"]}
          </li>
          <li
            :if={@project.attributes["license"]}
            class="inline-flex items-center gap-1"
            title={dgettext("knowledge", "License")}
          >
            <.dm_mdi name="scale-balance" class="h-4 w-4" />{@project.attributes["license"]}
          </li>
          <li :if={web_url?(@project.url)}>
            <a
              href={@project.url}
              target="_blank"
              rel="noopener noreferrer"
              class="inline-flex items-center gap-1 text-primary"
            >
              <.dm_mdi
                name={if @details_supported?, do: "github", else: "source-repository"}
                class="h-4 w-4"
              />
              {if @details_supported?, do: "GitHub", else: dgettext("knowledge", "Repository")}
            </a>
          </li>
          <li :if={@project.attributes["homepage"]}>
            <a
              href={@project.attributes["homepage"]}
              target="_blank"
              rel="noopener noreferrer"
              class="inline-flex items-center gap-1 text-primary"
            >
              <.dm_mdi name="open-in-new" class="h-4 w-4" />{dgettext("knowledge", "Homepage")}
            </a>
          </li>
        </ul>
      </header>

      <.dm_alert :if={@project.removal_due_at} id="removal-notice" variant="warning">
        {dgettext(
          "knowledge",
          "No source keeps this project any more. It will be removed on %{date} unless a source adds it again.",
          date: format_date(@project.removal_due_at)
        )}
      </.dm_alert>

      <.dm_alert :if={@deprecated?} id="deprecation-notice" variant="warning">
        <span :if={@project.deprecated_at}>
          {dgettext("knowledge", "Deprecated since %{date}.",
            date: format_date(@project.deprecated_at)
          )}
          {@project.deprecation_reason}
        </span>
        <span :if={!@project.deprecated_at}>
          {dgettext("knowledge", "Deprecated: archived on GitHub.")}
        </span>
      </.dm_alert>

      <div class="grid items-start gap-6 lg:grid-cols-3">
        <div class="space-y-6 lg:col-span-2">
          <.dm_card id="instruction">
            <.card_header title={dgettext("knowledge", "Instruction")}>
              <.dm_btn
                id="edit-instruction"
                size="sm"
                variant="outline"
                command="show-modal"
                commandfor="instruction-modal"
              >
                <.dm_mdi name="pencil-outline" class="h-4 w-4" />{dgettext("knowledge", "Edit")}
              </.dm_btn>
            </.card_header>
            <.markdown :if={@project.instruction} id="instruction-body" source={@project.instruction} />
            <div
              :if={!@project.instruction}
              class="rounded-lg border border-dashed border-outline-variant px-4 py-6 text-center text-sm text-on-surface-variant"
            >
              {dgettext(
                "knowledge",
                "No instruction yet. Write what this software is and what it is good for."
              )}
            </div>
          </.dm_card>

          <.dm_card id="readme">
            <.card_header title="README" />
            <div :if={@project.readme} class="max-h-[48rem] overflow-y-auto pr-2">
              <.markdown
                id="readme-body"
                source={@project.readme}
                repository={repository_bases(@project)}
              />
            </div>
            <p :if={!@project.readme} id="readme-state" class="text-sm text-on-surface-variant">
              {readme_state(@project, @details_supported?)}
            </p>
          </.dm_card>
        </div>

        <aside class="space-y-6">
          <.dm_card :if={@details_supported?} id="github-details">
            <.card_header title={dgettext("knowledge", "About")} />
            <dl class="grid grid-cols-[8rem_1fr] gap-x-3 gap-y-2 text-sm">
              <dt class="text-on-surface-variant">{dgettext("knowledge", "Created")}</dt>
              <dd>{format_date(@project.attributes["created_at"])}</dd>
              <dt class="text-on-surface-variant">{dgettext("knowledge", "Last pushed")}</dt>
              <dd>{format_date(@project.attributes["pushed_at"])}</dd>
              <dt class="text-on-surface-variant">{dgettext("knowledge", "Default branch")}</dt>
              <dd>{@project.attributes["default_branch"] || "—"}</dd>
              <dt class="text-on-surface-variant">{dgettext("knowledge", "Archived")}</dt>
              <dd>
                {if @project.attributes["archived"],
                  do: dgettext("knowledge", "Yes"),
                  else: dgettext("knowledge", "No")}
              </dd>
              <dt class="text-on-surface-variant">{dgettext("knowledge", "Details fetched")}</dt>
              <dd>{format_time(@project.details_fetched_at)}</dd>
            </dl>
            <p :if={@project.details_error} id="details-error" class="text-sm text-error">
              {@project.details_error}
            </p>
          </.dm_card>

          <.dm_card :if={!@details_supported?} id="repository">
            <.card_header title={dgettext("knowledge", "Repository")} />
            <dl class="grid grid-cols-[8rem_1fr] gap-x-3 gap-y-2 text-sm">
              <dt class="text-on-surface-variant">{dgettext("knowledge", "Host")}</dt>
              <dd>{@project.external_id |> String.split("/") |> hd()}</dd>
              <dt class="text-on-surface-variant">{dgettext("knowledge", "Address")}</dt>
              <dd class="break-all">
                <a
                  :if={web_url?(@project.url)}
                  href={@project.url}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="text-primary"
                >
                  {@project.url}
                </a>
                <code :if={!web_url?(@project.url)}>{@project.url}</code>
              </dd>
            </dl>
            <p class="text-sm text-on-surface-variant">
              {dgettext(
                "knowledge",
                "Details are fetched automatically only for GitHub; labels for this project are added by hand."
              )}
            </p>
          </.dm_card>

          <.dm_card id="project-labels">
            <.card_header title={dgettext("knowledge", "Labels")} />
            <ul :if={@project.labels != []} class="flex flex-wrap gap-2">
              <li :for={label <- @project.labels} id={"project-label-#{label.id}"}>
                <.dm_badge
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
            <p :if={@project.labels == []} class="text-sm text-on-surface-variant">
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
        <h2 class="text-lg font-semibold">{dgettext("knowledge", "Sources")}</h2>
        <.dm_table id="item-sources" data={@item_sources} hover>
          <:col :let={kept} label={dgettext("knowledge", "Source")}>
            <.link
              :if={kept.source}
              navigate={~p"/source/sources/#{kept.source.id}"}
              class="text-primary"
            >
              {kept.source.name}
            </.link>
            <span :if={!kept.source}>{dgettext("knowledge", "Added manually")}</span>
          </:col>
          <:col :let={kept} label={dgettext("knowledge", "Added")}>
            {format_time(kept.added_at)}
          </:col>
          <:col :let={kept} label={dgettext("knowledge", "Status")}>
            <.dm_badge :if={!kept.removed_at} variant="success" size="sm">
              {dgettext("knowledge", "Active")}
            </.dm_badge>
            <.dm_badge :if={kept.removed_at} variant="neutral" size="sm">
              {dgettext("knowledge", "Left on %{date}", date: format_date(kept.removed_at))}
            </.dm_badge>
          </:col>
        </.dm_table>
      </section>

      <section class="space-y-3">
        <h2 class="text-lg font-semibold">{dgettext("knowledge", "Source records")}</h2>
        <.dm_table id="observations" data={@observations} hover>
          <:col :let={obs} label={dgettext("knowledge", "Time")}>
            {format_time(obs.observed_at)}
          </:col>
          <:col :let={obs} label={dgettext("knowledge", "Source")}>
            {if obs.source, do: obs.source.name, else: dgettext("knowledge", "Added manually")}
          </:col>
          <:col :let={obs} label={dgettext("knowledge", "Period")}>{obs.period}</:col>
          <:col :let={obs} label={dgettext("knowledge", "Rank")}>{obs.rank || "—"}</:col>
          <:col :let={obs} label={dgettext("knowledge", "Stars in period")}>
            {format_count(obs.attributes["stars_in_period"])}
          </:col>
        </.dm_table>
      </section>

      <.dm_modal id="instruction-modal" close_label={gettext("Close")}>
        <:title>{dgettext("knowledge", "Edit instruction")}</:title>
        <:body>
          <.form
            for={@instruction_form}
            id="instruction-form"
            phx-submit="save_instruction"
            class="space-y-4"
          >
            <.dm_textarea
              id="instruction-text"
              name={@instruction_form[:instruction].name}
              value={@instruction_form[:instruction].value}
              label={dgettext("knowledge", "What this software is and does (Markdown)")}
              rows={12}
            />
            <.field_errors form={@instruction_form} field={:instruction} />
            <div class="flex justify-end gap-2">
              <.dm_btn type="button" variant="ghost" command="close" commandfor="instruction-modal">
                {gettext("Cancel")}
              </.dm_btn>
              <.dm_btn type="submit" variant="primary" id="save-instruction">
                {gettext("Save")}
              </.dm_btn>
            </div>
          </.form>
        </:body>
      </.dm_modal>

      <.dm_modal id="deprecate-modal" close_label={gettext("Close")}>
        <:title>{dgettext("knowledge", "Mark deprecated")}</:title>
        <:body>
          <.form
            for={%{}}
            as={:deprecation}
            id="deprecate-form"
            phx-submit="deprecate"
            class="space-y-4"
          >
            <.dm_input
              id="deprecation-reason"
              name="deprecation[reason]"
              value=""
              label={dgettext("knowledge", "Reason (optional)")}
              autocomplete="off"
            />
            <div class="flex justify-end gap-2">
              <.dm_btn type="button" variant="ghost" command="close" commandfor="deprecate-modal">
                {gettext("Cancel")}
              </.dm_btn>
              <.dm_btn type="submit" variant="primary" id="confirm-deprecate">
                {dgettext("knowledge", "Mark deprecated")}
              </.dm_btn>
            </div>
          </.form>
        </:body>
      </.dm_modal>
    </Layouts.app>
    """
  end

  defp web_url?(url), do: String.starts_with?(url, ["https://", "http://"])

  attr :title, :string, required: true
  slot :inner_block

  defp card_header(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-3">
      <h2 class="text-lg font-semibold">{@title}</h2>
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp readme_state(_project, false),
    do: dgettext("knowledge", "README is fetched automatically only for GitHub.")

  defp readme_state(%{readme_fetched_at: nil}, true),
    do: dgettext("knowledge", "README not fetched yet.")

  defp readme_state(_project, true), do: dgettext("knowledge", "This repository has no README.")
end
