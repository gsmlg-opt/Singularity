defmodule SingularityWeb.KnowledgeLive.Search do
  use SingularityWeb, :live_view

  import SingularityWeb.RfcComponents, only: [item_path: 1, rfc_name: 1]

  alias Singularity.Knowledge

  @per_page 30
  @query_length 256

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: dgettext("knowledge", "Search knowledge"), query_length: @query_length)
     |> stream_configure(:results, dom_id: &"knowledge-result-#{&1.id}")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if Enum.any?(~w(label sort status), &(normalize_query(params[&1]) != "")) do
      filters = Map.take(params, ~w(label sort status q page))
      {:noreply, redirect(socket, to: ~p"/knowledge/projects?#{filters}")}
    else
      q = normalize_query(params["q"])
      page = parse_page(params["page"])

      {items, more?} =
        if q == "", do: {[], false}, else: Knowledge.search_items(q, page, @per_page)

      {:noreply,
       socket
       |> assign(query: q, page: page, more?: more?, result_count: length(items))
       |> stream(:results, items, reset: true)}
    end
  end

  @impl true
  def handle_event("search", params, socket) do
    {:noreply, push_patch(socket, to: search_path(normalize_query(params["q"]), 1))}
  end

  defp normalize_query(q) when is_binary(q),
    do: q |> String.replace(<<0>>, "") |> String.trim() |> String.slice(0, @query_length)

  defp normalize_query(_q), do: ""

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} when page > 1 and page <= 2_147_483_647 -> page
      _invalid -> 1
    end
  end

  defp parse_page(_value), do: 1

  defp search_path("", _page), do: ~p"/knowledge"
  defp search_path(q, 1), do: ~p"/knowledge?#{%{q: q}}"
  defp search_path(q, page), do: ~p"/knowledge?#{%{q: q, page: page}}"

  defp result_title(%{kind: "ietf_rfc"} = rfc), do: "#{rfc_name(rfc)} · #{rfc.title}"
  defp result_title(item), do: item.title

  defp kind_label("software_project"), do: dgettext("knowledge", "Project")
  defp kind_label("ietf_rfc"), do: dgettext("knowledge", "RFC")
  defp kind_label(kind), do: kind

  defp kind_variant("ietf_rfc"), do: "secondary"
  defp kind_variant(_kind), do: "primary"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:knowledge} active="knowledge-all">
      <div class={[
        "mx-auto w-full",
        if(@query == "",
          do: "grid min-h-[40svh] max-w-2xl place-items-center lg:min-h-[65svh]",
          else: "max-w-4xl space-y-4"
        )
      ]}>
        <h1 class="sr-only">{@page_title}</h1>
        <div class="grid w-full max-w-2xl gap-6">
          <svg
            :if={@query == ""}
            id="knowledge-wordmark"
            viewBox="0 12 356 72"
            class="h-auto w-64 max-w-full justify-self-center text-on-surface sm:w-80"
            fill="none"
            aria-hidden="true"
          >
            <g stroke="currentColor" stroke-width="6.5" stroke-linecap="round" stroke-linejoin="round">
              <path
                class="text-secondary"
                d="M43 24C39 20 33 18 26 18C16 18 10 23 10 30C10 37 17 40 26 42C36 44 43 48 43 55C43 62 36 66 26 66C18 66 12 63 8 58"
              />
              <path d="M57 35V63M73 35V63M73 47C73 39 79 35 87 35C95 35 100 40 100 48V63" />
              <path d="M139 49C139 41 134 35 126 35C118 35 112 41 112 49C112 57 118 63 126 63C134 63 139 57 139 49ZM139 35V63C139 74 134 79 125 79C120 79 115 77 112 75" />
              <path d="M153 35V51C153 59 158 63 166 63C174 63 179 58 179 50M179 35V63M193 18V63" />
              <path d="M232 49C232 41 227 35 219 35C211 35 206 41 206 49C206 57 211 63 219 63C227 63 232 57 232 49ZM232 35V63M247 35V63M247 47C247 40 253 35 261 35" />
              <path d="M274 35V63M294 24V53C294 61 300 65 307 63M286 36H306" />
              <path class="text-secondary" d="M319 35L332 62M347 35L332 68C329 75 325 78 319 79" />
            </g>
            <circle class="text-tertiary" fill="currentColor" cx="57" cy="22" r="4.5" />
            <circle class="text-tertiary" fill="currentColor" cx="274" cy="22" r="4.5" />
          </svg>

          <form
            id="knowledge-search"
            action={~p"/knowledge"}
            method="get"
            role="search"
            aria-label={@page_title}
            phx-submit="search"
            class="relative w-full"
          >
            <.dm_input
              id="knowledge-query"
              type="search"
              name="q"
              value={@query}
              placeholder={@page_title}
              aria-label={@page_title}
              maxlength={@query_length}
              class="h-14 w-full rounded-full bg-surface ps-5 pe-16 text-base text-on-surface shadow-sm"
            />
            <.dm_btn
              native_submit
              variant="primary"
              shape="circle"
              aria-label={dgettext("knowledge", "Search")}
              class="absolute end-2 top-1/2 -translate-y-1/2"
            >
              <.dm_mdi name="magnify" class="size-5" aria-hidden="true" />
            </.dm_btn>
          </form>
        </div>

        <p role="status" class="sr-only">
          <%= cond do %>
            <% @query == "" -> %>
            <% @result_count == 0 -> %>
              {dgettext("knowledge", "No knowledge items match this search.")}
            <% true -> %>
              {dngettext(
                "knowledge",
                "%{count} result for %{query} on page %{page}",
                "%{count} results for %{query} on page %{page}",
                @result_count,
                query: @query,
                page: @page
              )}
          <% end %>
        </p>

        <section :if={@query != ""} class="space-y-4" aria-labelledby="knowledge-results-heading">
          <h2 id="knowledge-results-heading" class="text-lg font-semibold">
            {dgettext("knowledge", "Search results")}
          </h2>
          <p
            :if={@result_count == 0}
            id="knowledge-search-empty"
            aria-hidden="true"
            class="text-on-surface-variant"
          >
            {dgettext("knowledge", "No knowledge items match this search.")}
          </p>

          <div
            :if={@result_count > 0}
            class="overflow-hidden rounded-xl border border-outline-variant"
          >
            <.dm_table
              id="knowledge-results"
              data={@streams.results}
              stream
              hover
              class="knowledge-result-table table-fixed"
            >
              <:col :let={item} label={dgettext("knowledge", "Result")}>
                <.link
                  :if={item_path(item)}
                  navigate={item_path(item)}
                  class="rounded font-semibold [overflow-wrap:anywhere] hover:underline focus-visible:outline-2"
                >
                  {result_title(item)}
                </.link>
                <span :if={!item_path(item)} class="font-semibold [overflow-wrap:anywhere]">
                  {result_title(item)}
                </span>
                <p :if={item.summary} class="line-clamp-1 text-sm text-on-surface-variant">
                  {item.summary}
                </p>
              </:col>
              <:col :let={item} label={dgettext("knowledge", "Type")} label_class="w-28">
                <.dm_badge variant={kind_variant(item.kind)} soft>
                  {kind_label(item.kind)}
                </.dm_badge>
              </:col>
            </.dm_table>
          </div>

          <nav
            :if={@page > 1 || @more?}
            class="flex gap-4"
            aria-label={dgettext("knowledge", "Pagination")}
          >
            <.link :if={@page > 1} id="page-prev" patch={search_path(@query, @page - 1)}>
              {dgettext("knowledge", "Previous")}
            </.link>
            <.link :if={@more?} id="page-next" patch={search_path(@query, @page + 1)}>
              {dgettext("knowledge", "Next")}
            </.link>
          </nav>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
