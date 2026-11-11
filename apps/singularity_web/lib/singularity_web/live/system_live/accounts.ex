defmodule SingularityWeb.SystemLive.Accounts do
  @moduledoc """
  External accounts Singularity signs in to, listed on the left; the selected
  account's panel is on the right and its credentials are edited in a modal.
  """
  use SingularityWeb, :live_view

  alias Singularity.Settings

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, socket |> assign(page_title: dgettext("system", "Accounts")) |> load()}

  @impl true
  def handle_params(params, _uri, socket) do
    entries = entries()
    account = Enum.find(entries, hd(entries), &(&1.id == params["account"]))
    {:noreply, assign(socket, entries: entries, account: account.id)}
  end

  @impl true
  def handle_event("save_github", %{"github" => %{"token" => token}}, socket) do
    case Settings.put_github_token(token) do
      # Navigating to the page again remounts it, which closes the modal.
      {:ok, _setting} ->
        {:noreply,
         socket
         |> put_flash(:info, dgettext("system", "Token saved"))
         |> push_navigate(to: ~p"/system/accounts/github")}

      {:error, changeset} ->
        {:noreply, assign(socket, github_form: to_form(changeset, as: :github))}
    end
  end

  def handle_event("clear_github", _params, socket) do
    :ok = Settings.clear_github_token()
    {:noreply, socket |> put_flash(:info, dgettext("system", "Token cleared")) |> load()}
  end

  # One entry per account type; a new account adds an entry and a panel.
  defp entries,
    do: [%{id: "github", label: "GitHub", icon: "github", to: ~p"/system/accounts/github"}]

  defp load(socket),
    do:
      assign(socket,
        github_status: Settings.github_token_status(),
        github_form: to_form(%{}, as: :github)
      )

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:system} active="system-accounts">
      <h1 class="text-2xl font-bold">{dgettext("system", "Accounts")}</h1>
      <.settings_container
        id="accounts"
        title={dgettext("system", "Accounts")}
        entries={@entries}
        active={@account}
      >
        <.github_panel :if={@account == "github"} status={@github_status} form={@github_form} />
      </.settings_container>
    </Layouts.app>
    """
  end

  attr :status, :any, required: true
  attr :form, Phoenix.HTML.Form, required: true

  defp github_panel(assigns) do
    ~H"""
    <.settings_header
      id="account-github"
      icon="github"
      eyebrow={dgettext("system", "Account")}
      title="GitHub"
    >
      <:description>
        {dgettext("system", "Access token for repository details and a higher rate limit.")}
      </:description>
      <:actions>
        <.dm_btn
          :if={match?({:settings, _last4}, @status)}
          id="clear-token"
          variant="error"
          phx-click="clear_github"
          data-confirm={dgettext("system", "Clear the GitHub token?")}
        >
          {dgettext("system", "Clear token")}
        </.dm_btn>
        <.dm_btn
          id="configure-github"
          variant="outline"
          command="show-modal"
          commandfor="github-modal"
        >
          <.dm_mdi name="cog-outline" class="h-4 w-4" />{dgettext("system", "Configure")}
        </.dm_btn>
      </:actions>
    </.settings_header>

    <dl class="grid grid-cols-[10rem_1fr] gap-x-4 gap-y-2 text-sm">
      <dt class="text-on-surface-variant">{dgettext("system", "Status")}</dt>
      <dd><.status_badge id="github-status" status={@status} /></dd>
      <dt class="text-on-surface-variant">{dgettext("system", "Token")}</dt>
      <dd id="token-status">{token_text(@status)}</dd>
      <dt class="text-on-surface-variant">{dgettext("system", "Rate limit")}</dt>
      <dd>{rate_limit_text(@status)}</dd>
    </dl>

    <.dm_modal id="github-modal" close_label={gettext("Close")}>
      <:title>{dgettext("system", "Configure GitHub")}</:title>
      <:body>
        <.form for={@form} id="github-token-form" phx-submit="save_github" class="space-y-4">
          <p class="text-sm text-on-surface-variant">
            {dgettext(
              "system",
              "Create a personal access token on GitHub; read access to public repositories is enough."
            )}
          </p>
          <.dm_input
            id="github-token-input"
            type="password"
            name="github[token]"
            value=""
            label={dgettext("system", "Access token")}
            autocomplete="off"
          />
          <.field_errors form={@form} field={:value} />
          <div class="flex justify-end gap-2">
            <.dm_btn type="button" variant="ghost" command="close" commandfor="github-modal">
              {gettext("Cancel")}
            </.dm_btn>
            <.dm_btn type="submit" variant="primary" id="save-token">
              {dgettext("system", "Save token")}
            </.dm_btn>
          </div>
        </.form>
      </:body>
    </.dm_modal>
    """
  end

  attr :id, :string, required: true
  attr :status, :any, required: true

  defp status_badge(%{status: :unset} = assigns),
    do: ~H|<.dm_badge id={@id} variant="warning">{dgettext("system", "Not set")}</.dm_badge>|

  defp status_badge(%{status: {:env, _last4}} = assigns),
    do:
      ~H|<.dm_badge id={@id} variant="info">{dgettext("system", "From environment")}</.dm_badge>|

  defp status_badge(%{status: {:settings, _last4}} = assigns),
    do: ~H|<.dm_badge id={@id} variant="success">{dgettext("system", "Configured")}</.dm_badge>|

  defp token_text(:unset), do: dgettext("system", "Not set")

  defp token_text({:env, last4}),
    do:
      dgettext("system", "From the GITHUB_TOKEN environment variable (••••%{last4})",
        last4: last4
      )

  defp token_text({:settings, last4}), do: dgettext("system", "Set ••••%{last4}", last4: last4)

  defp rate_limit_text(:unset),
    do:
      dgettext(
        "system",
        "60 requests per hour; detail fetches wait when the limit is reached."
      )

  defp rate_limit_text(_set), do: dgettext("system", "5,000 requests per hour.")
end
