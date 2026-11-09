defmodule SingularityWeb.ItemComponents do
  @moduledoc """
  Kind-specific item rendering. Add a clause per item kind; kinds without a
  clause fall back to the generic display.
  """

  use Phoenix.Component

  attr :item, :map, required: true

  def item_meta(%{item: %{kind: "github_repo"}} = assigns) do
    ~H"""
    <span data-role="item-meta">
      {@item.attributes["language"] || "—"} · ★ {format_count(@item.attributes["stars"])} · forks {format_count(
        @item.attributes["forks"]
      )}
    </span>
    """
  end

  def item_meta(assigns), do: ~H""

  attr :kind, :string, required: true
  attr :attributes, :map, required: true

  def observation_meta(%{kind: "github_repo"} = assigns) do
    ~H"""
    <span>★ {format_count(@attributes["stars"])} · +{format_count(@attributes["stars_in_period"])} ({@attributes[
      "since"
    ]})</span>
    """
  end

  def observation_meta(assigns) do
    ~H"""
    <span>{Enum.map_join(@attributes || %{}, " · ", fn {key, value} -> "#{key}: #{value}" end)}</span>
    """
  end

  def format_count(nil), do: "—"

  def format_count(number) when is_integer(number),
    do: number |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")

  def format_count(other), do: to_string(other)

  def format_time(nil), do: "—"
  def format_time(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
end
