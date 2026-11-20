defmodule SingularityWeb.KnowledgeLive.RfcIndex do
  use SingularityWeb, :live_view

  import SingularityWeb.ItemComponents, only: [label_badges: 1, format_count: 1]
  import SingularityWeb.KnowledgeSearch
  import SingularityWeb.RfcComponents

  alias Singularity.{Collection, Knowledge}

  @per_page 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Knowledge.subscribe()
      Collection.subscribe()
    end

    {:ok,
     socket
     |> assign(page_title: dgettext("knowledge", "IETF RFCs"))
     |> stream_configure(:rfcs, dom_id: &"rfc-#{&1.attributes["number"]}")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = %{
      q: blank_to_nil(params["q"]),
      label: blank_to_nil(params["label"]),
      page: parse_page(params["page"])
    }

    {:noreply, socket |> assign(filters: filters) |> load()}
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    filters = %{socket.assigns.filters | q: blank_to_nil(params["q"]), page: 1}
    {:noreply, push_patch(socket, to: rfcs_path(filters))}
  end

  @impl true
  def handle_info({:project_updated, _id}, socket), do: {:noreply, load(socket)}
  def handle_info({:fetch_run, %{status: "ok"}}, socket), do: {:noreply, load(socket)}
  def handle_info({:fetch_run, _run}, socket), do: {:noreply, socket}

  defp load(%{assigns: %{filters: filters}} = socket) do
    opts = [q: filters.q, label: filters.label]
    rfcs = Knowledge.list_rfcs(opts ++ [page: filters.page, per_page: @per_page])
    total = Knowledge.count_rfcs(opts)

    socket
    |> stream(:rfcs, rfcs, reset: true)
    |> assign(
      rfcs_empty?: rfcs == [],
      total: total,
      has_next: filters.page * @per_page < total
    )
  end

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} when page > 1 -> page
      _other -> 1
    end
  end

  defp parse_page(_value), do: 1

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  # The empty filter state has no query string at all.
  defp rfcs_path(filters) do
    query =
      [
        {"q", filters.q},
        {"label", filters.label},
        {"page", if(filters.page > 1, do: filters.page)}
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    if query == %{}, do: ~p"/knowledge/ietf-rfcs", else: ~p"/knowledge/ietf-rfcs?#{query}"
  end

  attr :rfc, :map, required: true
  attr :filters, :map, required: true

  defp classification(assigns) do
    status = assigns.rfc.attributes["status"]
    labels = assigns.rfc.labels

    status_label =
      status &&
        Enum.find(labels, &(&1.origin == "auto" && String.starts_with?(&1.name, "status:")))

    assigns =
      assign(assigns,
        status: status,
        status_label: status_label,
        labels: List.delete(labels, status_label)
      )

    ~H"""
    <div class="flex flex-wrap items-center gap-1.5">
      <.link
        :if={@status_label}
        patch={rfcs_path(%{@filters | label: @status_label.name, page: 1})}
        aria-label={dgettext("knowledge", "Filter by %{status}", status: @status)}
        title={dgettext("knowledge", "Filter by %{status}", status: @status)}
        class="inline-flex min-h-8 items-center rounded hover:underline focus-visible:outline-2 focus-visible:outline-offset-2"
      >
        <.rfc_status status={@status} size="md" />
      </.link>
      <.rfc_status :if={!@status_label} status={@status} size="md" />
      <.label_badges labels={@labels} />
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} section={:knowledge} active="knowledge-rfcs">
      <.search_toolbar
        id="rfc-filters"
        title={@page_title}
        icon="file-document-multiple-outline"
        count_id="rfcs-total"
        count_text={
          dngettext("knowledge", "%{number} RFC", "%{number} RFCs", @total,
            number: format_count(@total)
          )
        }
        query={@filters.q}
        placeholder={dgettext("knowledge", "RFC number or title (e.g. 8446 or TLS)")}
        reset_path={if @filters.q || @filters.label, do: ~p"/knowledge/ietf-rfcs"}
        label={@filters.label}
        clear_label_path={rfcs_path(%{@filters | label: nil, page: 1})}
      />

      <p
        :if={@rfcs_empty?}
        id="rfcs-empty"
        class="flex flex-col items-center gap-3 rounded-xl border border-dashed border-outline-variant px-4 py-10 text-sm text-on-surface-variant"
      >
        <.dm_mdi name="magnify" class="size-7" aria-hidden="true" />
        {dgettext("knowledge", "No RFCs match.")}
      </p>

      <div :if={!@rfcs_empty?} class="overflow-hidden rounded-xl border border-outline-variant">
        <.dm_table
          id="rfcs"
          data={@streams.rfcs}
          stream
          hover
          class="knowledge-result-table table-fixed"
        >
          <:col :let={rfc} label={dgettext("knowledge", "RFC")}>
            <.link
              navigate={item_path(rfc)}
              class="group block w-fit max-w-full space-y-1 rounded focus-visible:outline-2 focus-visible:outline-offset-2"
            >
              <span class="block font-mono text-xs font-semibold text-on-surface-variant">
                {rfc_name(rfc)}
              </span>
              <span class="block text-base font-medium [overflow-wrap:anywhere] group-hover:underline">
                {rfc.title}
              </span>
            </.link>
          </:col>
          <:col :let={rfc} label={dgettext("knowledge", "Status")} label_class="w-52">
            <.classification rfc={rfc} filters={@filters} />
          </:col>
          <:col
            :let={rfc}
            label={dgettext("knowledge", "Published")}
            label_class="w-28"
            class="whitespace-nowrap tabular-nums text-on-surface-variant"
          >
            {published_month(rfc.published_at)}
          </:col>
        </.dm_table>
      </div>

      <nav class="flex gap-3" aria-label={dgettext("knowledge", "Pagination")}>
        <.link
          :if={@filters.page > 1}
          id="page-prev"
          patch={rfcs_path(%{@filters | page: @filters.page - 1})}
        >
          {dgettext("knowledge", "Previous")}
        </.link>
        <.link :if={@has_next} id="page-next" patch={rfcs_path(%{@filters | page: @filters.page + 1})}>
          {dgettext("knowledge", "Next")}
        </.link>
      </nav>
    </Layouts.app>
    """
  end
end
