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

  # Marks the collectors' field labels for `mix gettext.extract`; never called.
  @doc false
  def collector_field_labels,
    do: [
      dgettext_noop("source", "Language (leave blank for all)"),
      dgettext_noop("source", "Range")
    ]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:source} active="source-sources">
      <h1 class="text-2xl font-semibold">{@page_title}</h1>

      <ul :if={is_nil(@type)} id="source-types" class="space-y-2">
        <li :for={type <- @types}>
          <.link navigate={~p"/source/sources/new?kind=#{type.kind}"} id={"type-#{type.kind}"}>
            {type.label}
          </.link>
        </li>
      </ul>

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
