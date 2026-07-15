defmodule Singularity.Core.CollectionSpec do
  @moduledoc "Provider-independent identity and vector settings for a collection."

  @enforce_keys [:name, :dimensions, :distance, :embedding_model, :collection_version]
  defstruct [:name, :dimensions, :distance, :embedding_model, :collection_version]

  @type t :: %__MODULE__{
          name: String.t(),
          dimensions: non_neg_integer(),
          distance: :cosine | :dot | :euclid,
          embedding_model: String.t(),
          collection_version: String.t()
        }
end
