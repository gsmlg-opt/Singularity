defmodule SingularityWeb.SystemLive.Appearance do
  @moduledoc """
  The theme preference: automatic, light or dark. A choice, not data entry, so
  it is shown on the page and applies as soon as it is clicked.
  """
  use SingularityWeb, :live_view

  alias Singularity.Settings

  @impl true
  def mount(_params, _session, socket),
    do:
      {:ok, assign(socket, page_title: dgettext("system", "Appearance"), theme: Settings.theme())}

  @impl true
  def handle_event("set_theme", %{"theme" => theme}, socket) do
    case Settings.put_theme(theme) do
      # The root layout's data-theme is outside LiveView; app.js applies it.
      {:ok, _setting} ->
        {:noreply, socket |> assign(theme: theme) |> push_event("theme-changed", %{theme: theme})}

      {:error, :unknown_theme} ->
        {:noreply, put_flash(socket, :error, dgettext("system", "Unknown theme"))}
    end
  end

  defp options do
    [
      {"auto", "monitor", dgettext("system", "Auto")},
      {"sunshine", "white-balance-sunny", dgettext("system", "Light")},
      {"moonlight", "weather-night", dgettext("system", "Dark")}
    ]
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :options, options())

    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:system} active="system-appearance">
      <div>
        <h1 class="text-2xl font-bold">{dgettext("system", "Appearance")}</h1>
        <p class="mt-1 text-sm text-on-surface-variant">
          {dgettext("system", "Choose the theme: automatic, light or dark.")}
        </p>
      </div>
      <%!--
        TODO(upstream): duskmoon-dev/phoenix-duskmoon-ui#214
        WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#214 — dm_segment_control
        items cannot carry phx-click / phx-value, so the core segment-control classes
        are rendered by hand. Replace with dm_segment_control once items accept them.
      --%>
      <div
        id="theme-preference"
        class="segment-control"
        role="radiogroup"
        aria-label={dgettext("system", "Theme")}
      >
        <button
          :for={{value, icon, label} <- @options}
          id={"theme-#{value}"}
          type="button"
          role="radio"
          aria-checked={to_string(value == @theme)}
          class={["segment-item", value == @theme && "segment-item-active"]}
          phx-click="set_theme"
          phx-value-theme={value}
        >
          <.dm_mdi name={icon} class="segment-icon" />
          <span>{label}</span>
        </button>
      </div>
    </Layouts.app>
    """
  end
end
