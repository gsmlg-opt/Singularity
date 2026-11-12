defmodule Singularity.Test.FakeExtractor do
  @moduledoc """
  Test document extractor. Sends `{:fake_extractor_called, path, opts}` to the
  calling process and returns a fixed result.
  """

  @behaviour Singularity.Documents.Extractor

  @impl true
  def extract(path, opts) do
    send(self(), {:fake_extractor_called, path, opts})
    {:ok, %{content: "# Fake", mime_type: "text/markdown", title: "Fake", metadata: %{}}}
  end
end
