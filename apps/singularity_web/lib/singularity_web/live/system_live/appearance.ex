defmodule SingularityWeb.SystemLive.Appearance do
  @moduledoc "The colour theme of the interface, chosen in a modal form."
  use SingularityWeb, :live_view

  alias Singularity.Settings

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: dgettext("system", "Appearance"),
       theme: Settings.theme(),
       themes: Settings.themes()
     )}
  end

  @impl true
  def handle_event("save_theme", %{"appearance" => %{"theme" => theme}}, socket) do
    case Settings.put_theme(theme) do
      # The theme lives on the root layout, so reload the page to apply it.
      {:ok, _setting} ->
        {:noreply,
         socket
         |> put_flash(:info, dgettext("system", "Theme saved"))
         |> redirect(to: ~p"/system/appearance")}

      {:error, :unknown_theme} ->
        {:noreply, put_flash(socket, :error, dgettext("system", "Unknown theme"))}
    end
  end

  defp theme_label("moonlight"), do: dgettext("system", "Moonlight (dark)")
  defp theme_label("sunshine"), do: dgettext("system", "Sunshine (light)")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:system} active="system-appearance">
      <h1 class="text-2xl font-bold">{dgettext("system", "Appearance")}</h1>
      <.settings_container id="appearance">
        <.settings_header
          id="appearance-theme"
          icon="palette-outline"
          eyebrow={dgettext("system", "Appearance")}
          title={dgettext("system", "Colour theme")}
        >
          <:description>
            {dgettext("system", "The theme applies to every page of this Singularity.")}
          </:description>
          <:actions>
            <.dm_btn
              id="configure-theme"
              variant="outline"
              command="show-modal"
              commandfor="theme-modal"
            >
              <.dm_mdi name="cog-outline" class="h-4 w-4" />{dgettext("system", "Configure")}
            </.dm_btn>
          </:actions>
        </.settings_header>

        <dl class="grid grid-cols-[10rem_1fr] gap-x-4 gap-y-2 text-sm">
          <dt class="text-on-surface-variant">{dgettext("system", "Current theme")}</dt>
          <dd id="current-theme">{theme_label(@theme)}</dd>
        </dl>
      </.settings_container>

      <.dm_modal id="theme-modal" close_label={gettext("Close")}>
        <:title>{dgettext("system", "Colour theme")}</:title>
        <:body>
          <.form for={%{}} as={:appearance} id="theme-form" phx-submit="save_theme" class="space-y-4">
            <fieldset class="grid gap-3 sm:grid-cols-2">
              <legend class="sr-only">{dgettext("system", "Colour theme")}</legend>
              <label
                :for={theme <- @themes}
                data-theme={theme}
                class="group/theme flex cursor-pointer flex-col gap-3 rounded-lg border border-outline bg-surface p-3 text-on-surface has-[:checked]:ring-2 has-[:checked]:ring-primary has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-primary"
              >
                <input
                  type="radio"
                  id={"theme-#{theme}"}
                  name="appearance[theme]"
                  value={theme}
                  checked={theme == @theme}
                  class="sr-only"
                />
                <span class="flex gap-1" aria-hidden="true">
                  <span class="h-6 flex-1 rounded bg-primary"></span>
                  <span class="h-6 flex-1 rounded bg-secondary"></span>
                  <span class="h-6 flex-1 rounded bg-tertiary"></span>
                  <span class="h-6 flex-1 rounded bg-surface-container-high"></span>
                </span>
                <span class="flex items-center justify-between gap-2 text-sm font-medium">
                  {theme_label(theme)}
                  <.dm_mdi
                    name="check-circle"
                    class="invisible h-5 w-5 text-primary group-has-[:checked]/theme:visible"
                  />
                </span>
              </label>
            </fieldset>
            <div class="flex justify-end gap-2">
              <.dm_btn type="button" variant="ghost" command="close" commandfor="theme-modal">
                {gettext("Cancel")}
              </.dm_btn>
              <.dm_btn type="submit" variant="primary" id="save-theme">
                {dgettext("system", "Save theme")}
              </.dm_btn>
            </div>
          </.form>
        </:body>
      </.dm_modal>
    </Layouts.app>
    """
  end
end
