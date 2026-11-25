defmodule SingularityWeb.SourceLive.BookForm do
  use SingularityWeb, :live_view

  import SingularityWeb.ItemComponents, only: [item_path: 1]

  alias Singularity.Knowledge

  @impl true
  def mount(_params, _session, socket) do
    max_bytes = Knowledge.book_upload_limit()

    {:ok,
     socket
     |> assign(
       page_title: dgettext("source", "Add book"),
       error: nil,
       max_mib: div(max_bytes, 1024 * 1024)
     )
     |> allow_upload(:epub, accept: ~w(.epub), max_entries: 1, max_file_size: max_bytes)}
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, assign(socket, error: nil)}

  def handle_event("remove", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :epub, ref)}

  def handle_event("upload", _params, socket) do
    case uploaded_entries(socket, :epub) do
      {[_entry], []} ->
        [outcome] =
          consume_uploaded_entries(socket, :epub, fn %{path: path}, entry ->
            {:ok, Knowledge.upload_book(path, entry.client_name)}
          end)

        {:noreply, finish_upload(socket, outcome)}

      {[], []} ->
        {:noreply, assign(socket, error: dgettext("source", "Choose an EPUB file."))}

      {_completed, _in_progress} ->
        {:noreply, socket}
    end
  end

  defp finish_upload(socket, {:ok, book}) do
    socket
    |> put_flash(:info, dgettext("source", "Book uploaded."))
    |> push_navigate(to: item_path(book))
  end

  defp finish_upload(socket, {:existing, book}) do
    socket
    |> put_flash(:info, dgettext("source", "This EPUB is already in your knowledge base."))
    |> push_navigate(to: item_path(book))
  end

  defp finish_upload(socket, {:error, reason}), do: assign(socket, error: error_message(reason))

  defp error_message(:invalid_epub), do: dgettext("source", "This file is not a valid EPUB.")
  defp error_message(:too_large), do: dgettext("source", "This EPUB exceeds the upload limit.")
  defp error_message(:not_accepted), do: dgettext("source", "Choose an EPUB file.")

  defp error_message(:too_many_files),
    do: dgettext("source", "Choose one EPUB file at a time.")

  defp error_message(_error), do: dgettext("source", "Could not save the EPUB. Try again.")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:source} active="source-manual">
      <h1 class="text-2xl font-bold">{@page_title}</h1>

      <form id="book-form" phx-change="validate" phx-submit="upload" class="max-w-lg space-y-6">
        <div class="form-group">
          <label for={@uploads.epub.ref} class="label">{dgettext("source", "EPUB file")}</label>
          <.live_file_input
            upload={@uploads.epub}
            aria-describedby="epub-hint"
            class="input file-upload w-full"
          />
          <p id="epub-hint" class="text-xs text-on-surface-variant">
            {dgettext("source", "Choose an EPUB up to %{size} MiB.", size: @max_mib)}
          </p>
          <p :for={error <- upload_errors(@uploads.epub)} class="text-sm text-error" role="alert">
            {error_message(error)}
          </p>
        </div>

        <div :for={entry <- @uploads.epub.entries} id={"epub-#{entry.ref}"} class="space-y-2">
          <div class="flex items-center justify-between gap-4">
            <span class="min-w-0 truncate text-sm" title={entry.client_name}>{entry.client_name}</span>
            <.dm_btn
              type="button"
              variant="ghost"
              size="sm"
              phx-click="remove"
              phx-value-ref={entry.ref}
            >
              {dgettext("source", "Remove file")}
            </.dm_btn>
          </div>
          <progress
            :if={entry.progress > 0}
            value={entry.progress}
            max="100"
            class="progress w-full"
            aria-label={dgettext("source", "Upload progress")}
          />
          <p
            :for={error <- upload_errors(@uploads.epub, entry)}
            class="text-sm text-error"
            role="alert"
          >
            {error_message(error)}
          </p>
        </div>

        <p :if={@error} id="book-upload-error" role="alert" class="text-sm text-error">{@error}</p>

        <div class="flex gap-3">
          <.dm_btn variant="ghost" navigate={~p"/source/manual"}>{gettext("Cancel")}</.dm_btn>
          <.dm_btn
            native_submit
            variant="primary"
            phx-disable-with={dgettext("source", "Uploading…")}
          >
            {dgettext("source", "Upload EPUB")}
          </.dm_btn>
        </div>
      </form>
    </Layouts.app>
    """
  end
end
