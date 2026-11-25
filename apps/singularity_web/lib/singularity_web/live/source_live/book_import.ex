defmodule SingularityWeb.SourceLive.BookImport do
  use SingularityWeb, :live_view

  alias Singularity.Knowledge

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: refresh_later()

    {:ok,
     socket
     |> assign(page_title: dgettext("source", "Import books via SSH"), location: "", error: nil)
     |> load_imports()}
  end

  @impl true
  def handle_event("import", %{"location" => location}, socket) do
    case Knowledge.queue_book_import(location) do
      {:ok, _job} ->
        {:noreply, socket |> assign(location: location, error: nil) |> load_imports()}

      {:error, reason} ->
        {:noreply, assign(socket, location: location, error: error_message(reason))}
    end
  end

  @impl true
  def handle_info(:refresh_imports, socket) do
    refresh_later()
    {:noreply, load_imports(socket)}
  end

  defp refresh_later, do: Process.send_after(self(), :refresh_imports, :timer.seconds(5))
  defp load_imports(socket), do: assign(socket, imports: Knowledge.list_book_imports())

  defp error_message(:invalid_location),
    do: dgettext("source", "Enter an SSH target and an absolute directory path.")

  defp error_message(:ssh_host_not_allowed),
    do: dgettext("source", "This SSH target is not configured on the server.")

  defp error_message(_reason), do: dgettext("source", "Could not queue the import.")

  defp state_label("executing"), do: dgettext("source", "Importing")
  defp state_label("completed"), do: dgettext("source", "Completed")
  defp state_label("discarded"), do: dgettext("source", "Failed")
  defp state_label("cancelled"), do: dgettext("source", "Cancelled")
  defp state_label(_state), do: dgettext("source", "Queued")

  defp count(job, key), do: get_in(job.meta, ["book_import", key]) || 0

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:source} active="source-manual">
      <h1 class="text-2xl font-bold">{@page_title}</h1>

      <form id="book-ssh-form" phx-submit="import" class="max-w-lg space-y-4">
        <.dm_input
          id="book-ssh-location"
          label={dgettext("source", "SSH directory")}
          name="location"
          value={@location}
          placeholder="user@host:/path/to/Calibre Library"
          autocomplete="off"
          spellcheck="false"
          required
        />
        <p class="text-sm text-on-surface-variant">
          {dgettext(
            "source",
            "Use an SSH target configured on the server. EPUB files in subdirectories are included."
          )}
        </p>
        <p :if={@error} id="book-ssh-error" role="alert" class="text-sm text-error">{@error}</p>
        <.dm_btn native_submit variant="primary">{dgettext("source", "Start import")}</.dm_btn>
      </form>

      <section :if={@imports != []} class="space-y-3">
        <h2 class="text-lg font-semibold">{dgettext("source", "Recent book imports")}</h2>
        <div class="overflow-x-auto">
          <.dm_table id="book-imports" data={@imports} hover>
            <:col :let={job} label={dgettext("source", "SSH directory")}>
              <span class="break-all">{job.args["location"]}</span>
            </:col>
            <:col :let={job} label={dgettext("source", "Status")}>
              {state_label(job.state)}
            </:col>
            <:col :let={job} label={dgettext("source", "Imported")}>
              {count(job, "imported")} / {count(job, "total")}
            </:col>
            <:col :let={job} label={dgettext("source", "Duplicates")}>
              {count(job, "duplicates")}
            </:col>
            <:col :let={job} label={dgettext("source", "Failed")}>
              {count(job, "failed")}
            </:col>
          </.dm_table>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
