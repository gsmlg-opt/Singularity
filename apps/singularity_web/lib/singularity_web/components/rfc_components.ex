defmodule SingularityWeb.RfcComponents do
  @moduledoc "IETF RFC rendering, and the item changes that collection runs record."
  use SingularityWeb, :html

  @doc "`RFC 8446` for an RFC item."
  def rfc_name(%{attributes: %{"number" => number}}), do: "RFC #{number}"

  @doc "The detail page of a changed or listed item, or nil when it has none."
  def item_path(%{kind: "ietf_rfc", external_id: "rfc" <> number}),
    do: ~p"/knowledge/ietf-rfcs/#{number}"

  def item_path(%{kind: "software_project", item_id: id}) when is_integer(id),
    do: ~p"/knowledge/projects/#{id}"

  def item_path(%{kind: "software_project", id: id}) when is_integer(id),
    do: ~p"/knowledge/projects/#{id}"

  def item_path(_item), do: nil

  attr :status, :string, default: nil

  @doc "An RFC's status. It is a category, not a state: role colors, never semantic ones."
  def rfc_status(assigns) do
    ~H"""
    <.dm_badge :if={@status} size="sm" variant={status_variant(@status)} soft data-role="rfc-status">
      {@status}
    </.dm_badge>
    """
  end

  defp status_variant(status)
       when status in ["INTERNET STANDARD", "DRAFT STANDARD", "PROPOSED STANDARD"],
       do: "primary"

  defp status_variant("BEST CURRENT PRACTICE"), do: "secondary"
  defp status_variant(status) when status in ["INFORMATIONAL", "EXPERIMENTAL"], do: "tertiary"
  defp status_variant(_historic_or_unknown), do: "neutral"

  @doc "The publication month, e.g. `2018-08`."
  def published_month(nil), do: "—"
  def published_month(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m")

  attr :change, :string, required: true

  def change_badge(assigns) do
    ~H"""
    <.dm_badge size="sm" variant={change_variant(@change)} data-change={@change}>
      {change_label(@change)}
    </.dm_badge>
    """
  end

  def change_label("added"), do: dgettext("source", "Added")
  def change_label("updated"), do: dgettext("source", "Updated")
  def change_label("removed"), do: dgettext("source", "Removed")

  defp change_variant("added"), do: "success"
  defp change_variant("updated"), do: "info"
  defp change_variant(_removed), do: "warning"

  @doc "A changed field's value as text."
  def field_value(nil), do: "—"
  def field_value([]), do: "—"
  def field_value(list) when is_list(list), do: Enum.map_join(list, ", ", &field_value/1)
  def field_value(value) when is_binary(value), do: value
  def field_value(value), do: inspect(value)

  attr :fields, :map, required: true

  @doc "Field-level changes, old value then new value."
  def field_changes(assigns) do
    ~H"""
    <dl :if={@fields != %{}} class="grid grid-cols-[10rem_1fr] gap-x-3 gap-y-1 text-sm">
      <%= for {name, %{"old" => old, "new" => new}} <- Enum.sort(@fields) do %>
        <dt class="text-on-surface-variant">{name}</dt>
        <dd class="min-w-0 break-words">
          <span class="text-on-surface-variant line-through">{field_value(old)}</span>
          <.dm_mdi name="arrow-right" class="mx-1 inline h-3 w-3" />
          <span>{field_value(new)}</span>
        </dd>
      <% end %>
    </dl>
    """
  end

  attr :id, :string, required: true
  attr :diff, :string, required: true

  @doc "A collapsible unified diff; added lines read as success, removed ones as error."
  def content_diff(assigns) do
    ~H"""
    <details id={@id} class="text-sm">
      <summary class="cursor-pointer text-primary">{dgettext("source", "Content diff")}</summary>
      <pre class="mt-2 max-h-[32rem] overflow-auto rounded-lg bg-surface-container-high p-3 font-mono text-xs leading-5"><code><%= for line <- String.split(@diff, "\n", trim: true) do %><span class={diff_class(line)}>{line}</span>
    <% end %></code></pre>
    </details>
    """
  end

  defp diff_class("@@" <> _hunk), do: "text-on-surface-variant"
  defp diff_class("+" <> _added), do: "text-success"
  defp diff_class("-" <> _removed), do: "text-error"
  defp diff_class(_context), do: nil
end
