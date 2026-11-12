defmodule Singularity.Knowledge.Changes do
  @moduledoc """
  Field-level differences between an item's authoritative values before and
  after a collection run, as stored in `item_changes.fields`.
  """

  @whole [:title, :url, :summary, :published_at]

  @doc """
  `%{"title" => %{"old" => ..., "new" => ...}, "attributes.<key>" => ...}` for
  the authoritative fields that differ; attributes are compared key by key.
  Dates are stored as ISO 8601 strings.
  """
  @spec fields(map(), map()) :: %{String.t() => %{String.t() => term()}}
  def fields(before, after_) do
    whole = Enum.map(@whole, &{Atom.to_string(&1), Map.get(before, &1), Map.get(after_, &1)})

    old_attributes = Map.get(before, :attributes) || %{}
    new_attributes = Map.get(after_, :attributes) || %{}

    attributes =
      (Map.keys(old_attributes) ++ Map.keys(new_attributes))
      |> Enum.uniq()
      |> Enum.map(&{"attributes.#{&1}", Map.get(old_attributes, &1), Map.get(new_attributes, &1)})

    (whole ++ attributes)
    |> Enum.map(fn {name, old, new} -> {name, value(old), value(new)} end)
    |> Enum.reject(fn {_name, old, new} -> old == new end)
    |> Map.new(fn {name, old, new} -> {name, %{"old" => old, "new" => new}} end)
  end

  defp value(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp value(other), do: other
end
