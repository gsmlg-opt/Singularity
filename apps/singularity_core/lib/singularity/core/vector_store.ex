defmodule Singularity.Core.VectorStore do
  @moduledoc """
  Provider-independent collection and vector persistence contract.

  Every operation addresses an explicit collection identity. Fetching a missing
  collection returns `{:error, %Singularity.Core.Error{code: :not_found}}`.
  """

  alias Singularity.Core.CollectionSpec
  alias Singularity.Core.Retrieval
  alias Singularity.Core.VectorMatch
  alias Singularity.Core.VectorPoint

  @type context :: term()
  @type error :: Singularity.Core.Error.t()
  @type result(value) :: {:ok, value} | {:error, error()}

  @doc "Ensures the explicitly named collection matches the supplied specification."
  @callback ensure_collection(context(), CollectionSpec.t()) :: result(CollectionSpec.t())

  @doc "Fetches an explicitly named collection or returns a not-found error."
  @callback fetch_collection(context(), String.t()) :: result(CollectionSpec.t())

  @doc "Upserts points into a collection and returns their point identities."
  @callback upsert_points(context(), String.t(), [VectorPoint.t()]) :: result([String.t()])

  @doc "Fetches points in requested ID order while omitting missing identities."
  @callback fetch_points(context(), String.t(), [String.t()]) :: result([VectorPoint.t()])

  @doc "Deletes the identified points from a collection."
  @callback delete_points(context(), String.t(), [String.t()]) :: result(:ok)

  @doc "Returns matches by descending score, breaking score ties by point ID."
  @callback search(
              context(),
              String.t(),
              [float()],
              Retrieval.Filters.t(),
              pos_integer(),
              keyword()
            ) :: result([VectorMatch.t()])

  @doc "Scrolls points in ascending point-ID order and returns the next cursor or `:done`."
  @callback scroll(context(), String.t(), nil | String.t()) ::
              result({[VectorPoint.t()], :done | String.t()})
end
