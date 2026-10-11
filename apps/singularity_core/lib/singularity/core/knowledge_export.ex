defmodule Singularity.Core.KnowledgeExport do
  @moduledoc "Pure portable-export options, exact-version paths, and fixed limits."

  alias Singularity.Core.Error

  @uuid "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
  @identity Regex.compile!("\\A" <> @uuid <> "\\z")
  @note Regex.compile!("\\Anotes/" <> @uuid <> "--" <> @uuid <> "\\.md\\z")
  @portable_file_path Regex.compile!(
                        "\\A(?:notes/" <>
                          @uuid <>
                          "--" <>
                          @uuid <>
                          "\\.md|assets/" <>
                          @uuid <>
                          "--" <>
                          @uuid <>
                          "\\.bin|documents/originals/" <>
                          @uuid <>
                          "--" <>
                          @uuid <>
                          "\\.(?:pdf|md|txt)|documents/extracted/" <>
                          @uuid <>
                          "--" <> @uuid <> "\\.txt)\\z"
                      )

  @spec options(term()) :: {:ok, map()} | {:error, Error.t()}
  def options(input) when is_map(input) and not is_struct(input) do
    include = Map.get(input, :include_tombstones, false)

    if is_boolean(include) and Enum.all?(Map.keys(input), &(&1 == :include_tombstones)),
      do: {:ok, %{include_tombstones: include}},
      else: invalid()
  end

  def options(_input), do: invalid()

  @spec path(term(), term(), term(), term()) :: {:ok, String.t()} | {:error, Error.t()}
  def path(kind, resource, version, media) do
    with true <- uuid?(resource) and uuid?(version),
         {directory, extension} <- location(kind, media) do
      {:ok, directory <> "/" <> resource <> "--" <> version <> "." <> extension}
    else
      _ -> invalid()
    end
  end

  @spec relative_source_path(term(), term()) :: {:ok, String.t()} | {:error, Error.t()}
  def relative_source_path(note, target) when is_binary(note) and is_binary(target) do
    if byte_size(note) <= 100 and byte_size(target) <= 100 and
         Regex.match?(@note, note) and Regex.match?(@portable_file_path, target) do
      case target do
        "notes/" <> basename -> {:ok, basename}
        _ -> {:ok, "../" <> target}
      end
    else
      invalid()
    end
  end

  def relative_source_path(_note, _target), do: invalid()

  @spec limits() :: map()
  def limits do
    %{
      selected_keys: 100_000,
      metadata_records: 1_000_000,
      metadata_bytes: 1_073_741_824,
      file_bytes: 68_719_476_736,
      execution_ms: 900_000,
      page_rows: 500,
      chunk_bytes: 65_536,
      document_bytes: 67_108_864,
      document_fragments: 4_096,
      fragment_bytes: 65_536,
      extracted_bytes: 16_777_216,
      note_bytes: 1_048_576,
      rendered_note_bytes: 16_777_216,
      source_targets: 100
    }
  end

  defp location(:note, nil), do: {"notes", "md"}
  defp location(:asset, nil), do: {"assets", "bin"}
  defp location(:extracted, nil), do: {"documents/extracted", "txt"}
  defp location(:document, "application/pdf"), do: {"documents/originals", "pdf"}
  defp location(:document, "text/markdown"), do: {"documents/originals", "md"}
  defp location(:document, "text/plain"), do: {"documents/originals", "txt"}
  defp location(_kind, _media), do: :invalid

  defp uuid?(value),
    do: is_binary(value) and byte_size(value) == 36 and Regex.match?(@identity, value)

  defp invalid, do: {:error, Error.new(:invalid)}
end
