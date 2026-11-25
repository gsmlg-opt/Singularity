defmodule SingularityWeb.KnowledgeLive.BookIndex do
  use SingularityWeb, :live_view

  import SingularityWeb.ItemComponents, only: [item_path: 1, format_date: 1]

  alias Singularity.Knowledge

  @per_page 30

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: dgettext("knowledge", "Published books"))
     |> stream_configure(:books, dom_id: &"book-#{&1.id}")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = parse_page(params["page"])
    {books, more?} = Knowledge.list_books(page, @per_page)

    {:noreply,
     socket
     |> assign(page: page, more?: more?, empty?: books == [])
     |> stream(:books, books, reset: true)}
  end

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} when page in 2..2_147_483_647 -> page
      _invalid -> 1
    end
  end

  defp parse_page(_value), do: 1

  defp books_path(1), do: ~p"/knowledge/books"
  defp books_path(page), do: ~p"/knowledge/books?#{%{page: page}}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:knowledge} active="knowledge-books">
      <h1 class="text-2xl font-bold">{@page_title}</h1>

      <p :if={@empty?} id="books-empty" class="text-sm text-on-surface-variant">
        {dgettext("knowledge", "No books to show.")}
      </p>
      <div :if={!@empty?} class="overflow-hidden rounded-xl border border-outline-variant">
        <.dm_table id="books" data={@streams.books} stream hover class="table-fixed">
          <:col :let={book} label={dgettext("knowledge", "Book")}>
            <.link
              navigate={item_path(book)}
              class="rounded font-semibold [overflow-wrap:anywhere] hover:underline focus-visible:outline-2"
            >
              {book.title}
            </.link>
            <p :if={book.attributes["author"]} class="line-clamp-1 text-sm text-on-surface-variant">
              {book.attributes["author"]}
            </p>
          </:col>
          <:col :let={book} label={dgettext("knowledge", "Added")} label_class="w-32">
            <span class="text-sm tabular-nums">{format_date(book.first_seen_at)}</span>
          </:col>
        </.dm_table>
      </div>

      <nav
        :if={@page > 1 || @more?}
        class="flex gap-4"
        aria-label={dgettext("knowledge", "Pagination")}
      >
        <.link :if={@page > 1} patch={books_path(@page - 1)}>{dgettext("knowledge", "Previous")}</.link>
        <.link :if={@more?} patch={books_path(@page + 1)}>{dgettext("knowledge", "Next")}</.link>
      </nav>
    </Layouts.app>
    """
  end
end
