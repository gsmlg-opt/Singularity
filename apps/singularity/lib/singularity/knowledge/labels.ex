defmodule Singularity.Knowledge.Labels do
  @moduledoc "Pure rules for a software project's automatic labels."

  @doc """
  Labels derived from GitHub attributes and the `since` values of the project's
  trending observations: `lang:<language>`, `topic:<topic>`, `trending:<since>`
  and `archived`. Lowercase, no duplicates.
  """
  @spec auto_labels(map(), [String.t() | nil]) :: [String.t()]
  def auto_labels(attributes, observation_sinces)
      when is_map(attributes) and is_list(observation_sinces) do
    (prefixed("lang:", attributes["language"]) ++
       Enum.flat_map(List.wrap(attributes["topics"]), &prefixed("topic:", &1)) ++
       Enum.flat_map(observation_sinces, &prefixed("trending:", &1)) ++
       archived(attributes["archived"]))
    |> Enum.uniq()
  end

  defp prefixed(prefix, value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> []
      value -> [prefix <> value]
    end
  end

  defp prefixed(_prefix, _value), do: []

  defp archived(true), do: ["archived"]
  defp archived(_archived), do: []
end
