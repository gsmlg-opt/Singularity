defmodule SingularityWeb.KnowledgeLive.BookShow do
  use SingularityWeb, :live_view

  alias Singularity.Knowledge

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Knowledge.subscribe_book(id)
    {:ok, assign_book(socket, Knowledge.get_book!(id))}
  end

  @impl true
  def handle_info({:book_updated, book}, socket), do: {:noreply, assign_book(socket, book)}

  defp assign_book(socket, book), do: assign(socket, book: book, page_title: book.title)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:knowledge} active="knowledge-books">
      <div class="flex flex-wrap items-start justify-between gap-4">
        <h1 class="min-w-0 text-2xl font-bold [overflow-wrap:anywhere]">{@book.title}</h1>
        <.dm_btn variant="primary" href={~p"/knowledge/books/#{@book.id}/download"}>
          <.dm_mdi name="download" class="size-4" aria-hidden="true" />
          {dgettext("knowledge", "Download EPUB")}
        </.dm_btn>
      </div>

      <div id="book-metadata-status" role="status">
        <p
          :if={@book.attributes["metadata_status"] == "pending"}
          class="text-sm text-on-surface-variant"
        >
          {dgettext("knowledge", "Extracting book details…")}
        </p>
        <p :if={@book.attributes["metadata_status"] == "failed"} class="text-sm text-error">
          {dgettext("knowledge", "Could not extract the book details.")}
        </p>
      </div>

      <dl class="grid max-w-2xl grid-cols-[max-content_minmax(0,1fr)] gap-x-4 gap-y-2 text-sm">
        <dt :if={@book.attributes["author"]} class="text-on-surface-variant">
          {dgettext("knowledge", "Author")}
        </dt>
        <dd :if={@book.attributes["author"]} class="[overflow-wrap:anywhere]">
          {@book.attributes["author"]}
        </dd>
        <dt class="text-on-surface-variant">{dgettext("knowledge", "File")}</dt>
        <dd class="[overflow-wrap:anywhere]">{@book.attributes["filename"]}</dd>
      </dl>
    </Layouts.app>
    """
  end
end
