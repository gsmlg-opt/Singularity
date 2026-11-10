defmodule SingularityWeb.SystemLive.Github do
  use SingularityWeb, :live_view

  alias Singularity.Settings

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, socket |> assign(page_title: dgettext("system", "GitHub")) |> load()}

  @impl true
  def handle_event("save", %{"github" => %{"token" => token}}, socket) do
    case Settings.put_github_token(token) do
      {:ok, _setting} ->
        {:noreply, socket |> put_flash(:info, dgettext("system", "Token saved")) |> load()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :github))}
    end
  end

  def handle_event("clear", _params, socket) do
    :ok = Settings.clear_github_token()
    {:noreply, socket |> put_flash(:info, dgettext("system", "Token cleared")) |> load()}
  end

  defp load(socket),
    do: assign(socket, status: Settings.github_token_status(), form: to_form(%{}, as: :github))

  defp status_text(:unset), do: dgettext("system", "Not set")

  defp status_text({:env, last4}),
    do:
      dgettext("system", "From the GITHUB_TOKEN environment variable (••••%{last4})",
        last4: last4
      )

  defp status_text({:settings, last4}), do: dgettext("system", "Set ••••%{last4}", last4: last4)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:system} active="system-github">
      <h1 class="text-2xl font-semibold">{dgettext("system", "GitHub")}</h1>
      <.dm_card id="github-token">
        <:title>{dgettext("system", "Access token")}</:title>
        <p class="text-sm text-on-surface-variant">
          {dgettext(
            "system",
            "Without a token GitHub allows 60 requests per hour; detail fetches wait when the limit is reached."
          )}
        </p>
        <p id="token-status">{status_text(@status)}</p>
        <.form
          for={@form}
          id="github-token-form"
          phx-submit="save"
          class="flex flex-wrap items-end gap-2"
        >
          <.dm_input
            id="github-token-input"
            type="password"
            name="github[token]"
            value=""
            label={dgettext("system", "New token")}
            autocomplete="off"
          />
          <.dm_btn type="submit" variant="primary" id="save-token">
            {dgettext("system", "Save token")}
          </.dm_btn>
        </.form>
        <.field_errors form={@form} field={:value} />
        <:action :if={match?({:settings, _last4}, @status)}>
          <.dm_btn id="clear-token" phx-click="clear">{dgettext("system", "Clear token")}</.dm_btn>
        </:action>
      </.dm_card>
    </Layouts.app>
    """
  end
end
