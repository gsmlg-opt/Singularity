defmodule Singularity.Documents.XbergExtractor do
  @moduledoc """
  `Singularity.Documents.Extractor` backed by the xberg NIF. The only module
  that references `Xberg.*`.

  Files are passed by path (`kind: :uri`), never as bytes: in xberg 1.3.10
  `kind: :bytes` fails for every input
  (https://github.com/xberg-io/xberg/issues/3020). OCR is off. Never raises.
  """

  @behaviour Singularity.Documents.Extractor

  # Simple metadata fields worth keeping; nested format details are dropped.
  @metadata_fields ~w(authors subject keywords language category tags created_at
                      modified_at created_by modified_by document_version abstract_text)a

  @impl true
  def extract(path, opts) do
    input = %Xberg.ExtractInput{kind: :uri, uri: path, mime_type: opts[:mime_type]}

    case Xberg.extract(input: input, config: %{"output_format" => "markdown"}) do
      {:ok, %{results: [result | _]}} -> {:ok, to_result(result)}
      {:ok, _} -> failed("no extraction result")
      {:error, reason} -> failed(reason)
    end
  rescue
    exception -> failed(Exception.message(exception))
  end

  defp to_result(result) do
    metadata = result.metadata || %{}

    %{
      content: result.content || "",
      mime_type: result.mime_type,
      title: Map.get(metadata, :title),
      metadata: simple_metadata(metadata)
    }
  end

  defp simple_metadata(metadata) do
    format_type = get_in(metadata, [Access.key(:format), Access.key(:format_type)])

    metadata
    |> Map.take(@metadata_fields)
    |> Map.put(:format_type, format_type)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp failed(reason) when is_binary(reason), do: {:error, {:extract_failed, reason}}
  defp failed(reason), do: {:error, {:extract_failed, inspect(reason)}}
end
