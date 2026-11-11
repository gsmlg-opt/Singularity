defmodule SingularityWeb.TableComponents do
  @moduledoc "Pieces shared by data tables (see DESIGN.md)."
  use Phoenix.Component

  import PhoenixDuskmoon.Component.Action.Button
  import PhoenixDuskmoon.Component.Icon.Icons

  @doc """
  A row action: an icon-only button whose `title` (and accessible name) is the
  action's name. Destructive actions set `destructive` (a red icon on the same
  ghost button) and `data-confirm`.
  """
  attr :icon, :string, required: true
  attr :label, :string, required: true, doc: "the action's name, shown as the tooltip"
  attr :destructive, :boolean, default: false
  attr :navigate, :string, default: nil
  attr :rest, :global

  def row_action(assigns) do
    ~H"""
    <.dm_btn
      variant="ghost"
      size="sm"
      shape="square"
      navigate={@navigate}
      title={@label}
      aria-label={@label}
      {@rest}
    >
      <.dm_mdi name={@icon} class={["h-4 w-4", @destructive && "text-error"]} />
    </.dm_btn>
    """
  end

  @doc "The actions cell of a table row."
  slot :inner_block, required: true

  def row_actions(assigns) do
    ~H"""
    <div class="flex items-center justify-end gap-1">{render_slot(@inner_block)}</div>
    """
  end
end
