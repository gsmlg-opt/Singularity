defmodule Singularity.Documents.Extractor do
  @moduledoc """
  Turns a local document file into Markdown and metadata.

  `Singularity.Documents.extract/2` checks the path and size before calling an
  extractor, so implementations only receive existing regular files. The only
  option passed through is `:mime_type`.
  """

  @type result :: %{
          content: String.t(),
          mime_type: String.t(),
          title: String.t() | nil,
          metadata: %{optional(String.t()) => term()}
        }

  @callback extract(path :: Path.t(), opts :: keyword()) ::
              {:ok, result()} | {:error, {:extract_failed, String.t()}}
end
