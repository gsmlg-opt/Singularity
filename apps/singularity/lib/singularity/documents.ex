defmodule Singularity.Documents do
  @moduledoc """
  Document extraction: local files (PDF, Office, HTML, Markdown, ...) to
  Markdown and metadata, groundwork for importing documents as knowledge.

  Only local regular files are accepted. URLs are rejected so that every
  network request still goes through `Singularity.HttpClient` and the
  rate-limited queues. The extractor is read from
  `config :singularity, :document_extractor`.
  """

  alias Singularity.Documents.Extractor

  @default_max_bytes 52_428_800

  @spec extract(Path.t(), keyword()) ::
          {:ok, Extractor.result()}
          | {:error, :not_a_file | :too_large | {:extract_failed, String.t()}}
  def extract(path, opts \\ []) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    with :ok <- check_local(path),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(path),
         :ok <- check_size(size, max_bytes) do
      extractor().extract(path, Keyword.take(opts, [:mime_type]))
    else
      {:error, :too_large} -> {:error, :too_large}
      _ -> {:error, :not_a_file}
    end
  end

  defp check_local(path) when is_binary(path) do
    if String.contains?(path, "://"), do: {:error, :not_a_file}, else: :ok
  end

  defp check_local(_path), do: {:error, :not_a_file}

  defp check_size(size, max_bytes) when size > max_bytes, do: {:error, :too_large}
  defp check_size(_size, _max_bytes), do: :ok

  defp extractor do
    Application.get_env(:singularity, :document_extractor, Singularity.Documents.XbergExtractor)
  end
end
