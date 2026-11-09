defmodule Singularity.Ingest.Metadata.PDF do
  @moduledoc "Bounded parser for the PDF header version."

  alias Singularity.Core.Error

  @extractor_version 1

  @spec extract(map(), binary()) :: {:ok, map()} | {:error, Error.t()}
  def extract(
        %{plaintext_byte_size: plaintext_byte_size},
        <<"%PDF-", major, ?., minor, line_end, _rest::binary>>
      )
      when major in ?0..?9 and minor in ?0..?9 and line_end in [?\r, ?\n] and
             plaintext_byte_size >= 9 do
    {:ok,
     %{
       detected_media_type: "application/pdf",
       plaintext_bytes: plaintext_byte_size,
       width: nil,
       height: nil,
       pdf_version: <<major, ?., minor>>,
       extractor_version: @extractor_version
     }}
  end

  def extract(_reader, _prefix), do: {:error, Error.new(:integrity_failure)}
end
