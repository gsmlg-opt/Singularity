defmodule SingularityWeb.SourceLive.Add do
  use SingularityWeb, :live_view

  alias Singularity.Knowledge

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: dgettext("source", "Add project"),
       form: to_form(%{"address" => ""}, as: :project),
       error: nil
     )}
  end

  @impl true
  def handle_event("add", %{"project" => %{"address" => address}}, socket) do
    case Knowledge.add_project(address) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, dgettext("source", "Project added; fetching its GitHub details"))
         |> push_navigate(to: ~p"/knowledge/projects/#{project.id}")}

      {:existing, project} ->
        {:noreply,
         socket
         |> put_flash(:info, dgettext("source", "Already in the knowledge base"))
         |> push_navigate(to: ~p"/knowledge/projects/#{project.id}")}

      {:error, :unsupported_address} ->
        {:noreply,
         failed(
           socket,
           address,
           dgettext(
             "source",
             "Only GitHub repositories are supported for now, e.g. owner/repo or https://github.com/owner/repo"
           )
         )}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         failed(socket, address, dgettext("source", "The project could not be added; try again"))}
    end
  end

  defp failed(socket, address, message),
    do: assign(socket, form: to_form(%{"address" => address}, as: :project), error: message)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:source} active="source-add">
      <h1 class="text-2xl font-semibold">{dgettext("source", "Add project")}</h1>
      <p class="text-sm text-on-surface-variant">
        {dgettext(
          "source",
          "Enter a GitHub repository; its details and labels are fetched automatically."
        )}
      </p>
      <.form for={@form} id="add-project-form" phx-submit="add" class="max-w-xl space-y-3">
        <.dm_input
          id="project-address"
          name={@form[:address].name}
          value={@form[:address].value}
          label={dgettext("source", "Repository address")}
          placeholder="owner/repo"
          errors={List.wrap(@error)}
        />
        <.dm_btn type="submit" variant="primary" id="add-project">
          {dgettext("source", "Add")}
        </.dm_btn>
      </.form>
    </Layouts.app>
    """
  end
end
