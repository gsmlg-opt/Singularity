defmodule Singularity.Core.KnowledgeSearchStore do
  @moduledoc "Ports for owner-scoped lexical search and exact canonical source reads."

  alias Singularity.Core.{Error, SearchSource}

  @type page :: %{items: [map()], next_cursor: String.t() | :done}

  @doc "Searches a validated query map; authorization context is supplied separately."
  @callback search(term(), map()) :: {:ok, page()} | {:error, Error.t()}

  @doc "Resolves the entire immutable selector independently of projection presence."
  @callback resolve(term(), SearchSource.t()) :: {:ok, map()} | {:error, Error.t()}
end
