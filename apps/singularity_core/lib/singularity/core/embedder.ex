defmodule Singularity.Core.Embedder do
  @moduledoc "Provider-independent contract for document and query embeddings."

  alias Singularity.Core.Embedding
  alias Singularity.Core.EmbeddingInput

  @type context :: term()
  @type error :: Singularity.Core.Error.t()
  @type result(value) :: {:ok, value} | {:error, error()}

  @doc "Embeds documents while preserving the input order in the returned embeddings."
  @callback embed_documents(context(), [EmbeddingInput.t()]) :: result([Embedding.t()])

  @doc "Embeds a query and returns an embedding with the same input ID."
  @callback embed_query(context(), EmbeddingInput.t()) :: result(Embedding.t())
end
