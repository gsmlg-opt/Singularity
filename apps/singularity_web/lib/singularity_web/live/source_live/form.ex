defmodule SingularityWeb.SourceLive.Form do
  use SingularityWeb, :live_view

  alias Singularity.Sources

  @impl true
  def mount(params, _session, socket),
    do: {:ok, apply_action(socket, socket.assigns.live_action, params)}

  defp apply_action(socket, :new, params) do
    case params["kind"] && Sources.fetch_source_type(params["kind"]) do
      {:ok, type} ->
        source = Sources.new_source(type.kind)

        assign(socket,
          page_title: dgettext("source", "New source: %{type}", type: type.label),
          source: source,
          type: type,
          form: to_form(Sources.change_source(source))
        )

      _no_type ->
        assign(socket,
          page_title: dgettext("source", "Choose a source type"),
          source: nil,
          type: nil,
          form: nil,
          types: Sources.list_source_types()
        )
    end
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    source = Sources.get_source!(id)

    case Sources.fetch_source_type(source.kind) do
      {:ok, type} ->
        assign(socket,
          page_title: dgettext("source", "Edit source"),
          source: source,
          type: type,
          form: to_form(Sources.change_source(source))
        )

      :error ->
        socket
        |> put_flash(
          :error,
          dgettext("source", "Source type %{kind} is unavailable, so the source cannot be edited",
            kind: source.kind
          )
        )
        |> push_navigate(to: ~p"/source/sources")
    end
  end

  @impl true
  def handle_event("validate", %{"source" => params}, socket) do
    changeset =
      socket.assigns.source |> Sources.change_source(params) |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"source" => params}, socket) do
    result =
      case socket.assigns.live_action do
        :new -> Sources.create_source(Map.put(params, "kind", socket.assigns.source.kind))
        :edit -> Sources.update_source(socket.assigns.source, params)
      end

    case result do
      {:ok, source} ->
        {:noreply,
         socket
         |> put_flash(:info, dgettext("source", "Saved"))
         |> push_navigate(to: ~p"/source/sources/#{source.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp config_value(form, name) do
    config = form[:config].value || %{}
    Map.get(config, to_string(name)) || Map.get(config, name)
  end

  # Collector field labels are English data; translate them at runtime.
  defp field_label(field), do: Gettext.dgettext(SingularityWeb.Gettext, "source", field.label)

  # Marks the collectors' type and field labels for `mix gettext.extract`; never called.
  @doc false
  def collector_field_labels,
    do: [
      dgettext_noop("source", "Language (leave blank for all)"),
      dgettext_noop("source", "Range"),
      dgettext_noop("source", "GitHub Trending"),
      dgettext_noop("source", "GitHub Stars"),
      dgettext_noop("source", "IETF RFCs")
    ]

  defp type_presentation("github_trending") do
    %{
      icon: "trending-up",
      tone: "bg-tertiary-container text-on-tertiary-container",
      category: dgettext("source", "Software projects"),
      description:
        dgettext(
          "source",
          "Track repositories on GitHub’s daily, weekly, or monthly trending charts."
        ),
      setup: dgettext("source", "Choose a time range and an optional language")
    }
  end

  defp type_presentation("github_stars") do
    %{
      icon: "star-outline",
      tone: "bg-secondary-container text-on-secondary-container",
      category: dgettext("source", "Software projects"),
      description:
        dgettext(
          "source",
          "Follow the repositories a GitHub user stars as their collection changes."
        ),
      setup: dgettext("source", "Enter a GitHub username")
    }
  end

  defp type_presentation("ietf_rfc") do
    %{
      icon: "file-document-multiple-outline",
      tone: "bg-primary-container text-on-primary-container",
      category: dgettext("source", "Reference documents"),
      description:
        dgettext(
          "source",
          "Read full-text RFCs from the RFC Editor and track changes to each document."
        ),
      setup: dgettext("source", "Set a name and collection interval")
    }
  end

  defp type_presentation(_kind) do
    %{
      icon: "rss",
      tone: "bg-primary-container text-on-primary-container",
      category: nil,
      description: dgettext("source", "Collect items from this source into your knowledge base."),
      setup: dgettext("source", "Configure the source in the next step")
    }
  end

  attr :type, :map, required: true

  defp source_type_card(assigns) do
    assigns = assign(assigns, :presentation, type_presentation(assigns.type.kind))

    ~H"""
    <.link
      navigate={~p"/source/sources/new?kind=#{@type.kind}"}
      id={"type-#{@type.kind}"}
      aria-labelledby={"type-#{@type.kind}-title"}
      aria-describedby={"type-#{@type.kind}-description type-#{@type.kind}-setup"}
      class="group block h-full rounded-xl no-underline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-on-surface"
    >
      <.dm_card
        padding="none"
        class="h-full overflow-hidden border border-outline group-hover:border-primary group-focus-visible:border-primary motion-safe:transition-[border-color]"
        body_class="flex h-full flex-col gap-0"
      >
        <div class={[
          "source-type-banner flex items-center justify-between px-5 py-4 sm:px-6",
          @presentation.tone
        ]}>
          <.dm_mdi name={@presentation.icon} class="size-9" aria-hidden="true" />
          <span :if={@presentation.category} class="text-xs font-medium">{@presentation.category}</span>
        </div>
        <div class="flex flex-1 flex-col gap-3 bg-surface-container p-5 text-on-surface sm:p-6">
          <h2 id={"type-#{@type.kind}-title"} class="text-lg font-semibold">
            {Gettext.dgettext(SingularityWeb.Gettext, "source", @type.label)}
          </h2>
          <p
            id={"type-#{@type.kind}-description"}
            class="flex-1 text-sm leading-relaxed text-on-surface-variant"
          >
            {@presentation.description}
          </p>
          <div class="mt-2 flex min-h-14 items-center justify-between gap-4 border-t border-outline-variant pt-4">
            <p id={"type-#{@type.kind}-setup"} class="text-xs leading-relaxed text-on-surface-variant">
              {@presentation.setup}
            </p>
            <span class="inline-flex size-8 shrink-0 items-center justify-center rounded-full bg-primary-container text-on-primary-container group-hover:bg-primary group-hover:text-primary-content group-focus-visible:bg-primary group-focus-visible:text-primary-content">
              <.dm_mdi name="arrow-right" class="size-4" aria-hidden="true" />
            </span>
          </div>
        </div>
      </.dm_card>
    </.link>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:source} active="source-sources">
      <div class="space-y-6">
        <.link
          :if={is_nil(@type)}
          id="back-to-sources"
          navigate={~p"/source/sources"}
          class="inline-flex items-center gap-2 rounded text-sm text-on-surface-variant hover:text-primary focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-on-surface"
        >
          <.dm_mdi name="arrow-left" class="h-4 w-4" aria-hidden="true" />
          {dgettext("source", "Back to sources")}
        </.link>
        <.link
          :if={@type && @live_action == :new}
          id="change-source-type"
          navigate={~p"/source/sources/new"}
          class="inline-flex items-center gap-2 rounded text-sm text-on-surface-variant hover:text-primary focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-on-surface"
        >
          <.dm_mdi name="arrow-left" class="h-4 w-4" aria-hidden="true" />
          {dgettext("source", "Choose another source type")}
        </.link>
        <div class="space-y-3">
          <h1 class="text-2xl font-bold">{@page_title}</h1>
          <p :if={is_nil(@type)} class="max-w-2xl text-sm leading-relaxed text-on-surface-variant">
            {dgettext(
              "source",
              "Select a source to start adding projects or reference documents to your knowledge base."
            )}
          </p>
        </div>
      </div>

      <div :if={is_nil(@type)} class="space-y-6">
        <div
          id="source-types"
          class="grid grid-cols-[repeat(auto-fit,minmax(min(100%,16rem),1fr))] items-stretch gap-6"
        >
          <.source_type_card :for={type <- @types} type={type} />
        </div>
        <div class="flex flex-col gap-4 border-t border-outline-variant pt-6 sm:flex-row sm:items-center sm:justify-between">
          <div class="flex items-center gap-3 text-sm text-on-surface-variant">
            <.dm_mdi name="hand-back-right-outline" class="h-5 w-5 shrink-0" aria-hidden="true" />
            <p>{dgettext("source", "Have a specific project in mind?")}</p>
          </div>
          <.link
            id="add-project-manually"
            navigate={~p"/source/manual"}
            class="inline-flex items-center gap-2 self-start rounded-md bg-primary-container px-3 py-2 text-sm font-medium text-on-primary-container hover:underline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-on-surface sm:self-auto"
          >
            {dgettext("source", "Add a project manually")}
            <.dm_mdi name="arrow-right" class="h-4 w-4" aria-hidden="true" />
          </.link>
        </div>
      </div>

      <.form
        :if={@type}
        for={@form}
        id="source-form"
        phx-change="validate"
        phx-submit="save"
        class="max-w-lg space-y-3"
      >
        <.dm_input
          id="source-name"
          name="source[name]"
          label={dgettext("source", "Name")}
          value={@form[:name].value}
        />
        <.field_errors form={@form} field={:name} />

        <div :for={field <- @type.fields}>
          <.dm_select
            :if={field.type == :select}
            id={"config-#{field.name}"}
            name={"source[config][#{field.name}]"}
            label={field_label(field)}
            value={config_value(@form, field.name)}
            options={Enum.map(field.options, &{&1, &1})}
          />
          <.dm_input
            :if={field.type != :select}
            id={"config-#{field.name}"}
            type={if field.type == :integer, do: "number", else: "text"}
            name={"source[config][#{field.name}]"}
            label={field_label(field)}
            value={config_value(@form, field.name)}
          />
        </div>
        <.field_errors form={@form} field={:config} />

        <.dm_input
          id="source-interval"
          type="number"
          name="source[interval_minutes]"
          label={dgettext("source", "Collection interval (minutes)")}
          value={@form[:interval_minutes].value}
        />
        <.field_errors form={@form} field={:interval_minutes} />

        <.dm_btn type="submit" variant="primary" id="source-save">
          {dgettext("source", "Save")}
        </.dm_btn>
      </.form>
    </Layouts.app>
    """
  end
end
