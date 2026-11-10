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

        socket
        |> assign(page_title: "新建来源 · #{type.label}", source: source, type: type)
        |> assign(form: to_form(Sources.change_source(source)))

      _ ->
        assign(socket,
          page_title: "选择来源类型",
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
          page_title: "编辑来源",
          source: source,
          type: type,
          form: to_form(Sources.change_source(source))
        )

      :error ->
        socket
        |> put_flash(:error, "来源类型 #{source.kind} 不可用，无法编辑")
        |> push_navigate(to: ~p"/sources")
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
         socket |> put_flash(:info, "已保存") |> push_navigate(to: ~p"/sources/#{source.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp config_value(form, name) do
    config = form[:config].value || %{}
    Map.get(config, to_string(name)) || Map.get(config, name)
  end

  attr :form, :any, required: true
  attr :field, :atom, required: true

  defp field_errors(assigns) do
    changeset = assigns.form.source

    messages =
      if changeset.action do
        for {field, {message, opts}} <- changeset.errors, field == assigns.field do
          Enum.reduce(opts, message, fn {key, value}, acc ->
            String.replace(acc, "%{#{key}}", to_string(value))
          end)
        end
      else
        []
      end

    assigns = assign(assigns, :messages, messages)

    ~H"""
    <p :for={message <- @messages} class="text-sm text-error" data-role="error">{message}</p>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current={:sources}>
      <h1 class="text-2xl font-semibold">{@page_title}</h1>

      <ul :if={is_nil(@type)} id="source-types" class="space-y-2">
        <li :for={type <- @types}>
          <.link navigate={~p"/sources/new?kind=#{type.kind}"} id={"type-#{type.kind}"}>{type.label}</.link>
        </li>
      </ul>

      <.form
        :if={@type}
        for={@form}
        id="source-form"
        phx-change="validate"
        phx-submit="save"
        class="space-y-3 max-w-lg"
      >
        <.dm_input id="source-name" name="source[name]" label="名称" value={@form[:name].value} />
        <.field_errors form={@form} field={:name} />

        <div :for={field <- @type.fields}>
          <.dm_select
            :if={field.type == :select}
            id={"config-#{field.name}"}
            name={"source[config][#{field.name}]"}
            label={field.label}
            value={config_value(@form, field.name)}
            options={Enum.map(field.options, &{&1, &1})}
          />
          <.dm_input
            :if={field.type != :select}
            id={"config-#{field.name}"}
            type={if field.type == :integer, do: "number", else: "text"}
            name={"source[config][#{field.name}]"}
            label={field.label}
            value={config_value(@form, field.name)}
          />
        </div>
        <.field_errors form={@form} field={:config} />

        <.dm_input
          id="source-interval"
          type="number"
          name="source[interval_minutes]"
          label="采集间隔（分钟）"
          value={@form[:interval_minutes].value}
        />
        <.field_errors form={@form} field={:interval_minutes} />

        <.dm_btn type="submit" variant="primary" id="source-save">保存</.dm_btn>
      </.form>
    </Layouts.app>
    """
  end
end
