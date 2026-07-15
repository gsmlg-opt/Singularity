defmodule Singularity.Core.TestSupport.Fake.Backplane do
  @moduledoc false

  @behaviour Singularity.Core.Embedder
  @behaviour Singularity.Core.Generator

  alias Singularity.Core.Citation
  alias Singularity.Core.Embedding
  alias Singularity.Core.Error
  alias Singularity.Core.GenerationEvent
  alias Singularity.Core.GenerationResult
  alias Singularity.Core.TestSupport.Fake.Control

  def start_link(options) when is_list(options) do
    Control.start_link(%{
      document_embeddings:
        Keyword.get(options, :document_embeddings, default_document_embeddings()),
      query_embedding: Keyword.get(options, :query_embedding, default_query_embedding()),
      generation_events: Keyword.get(options, :generation_events, default_generation_events()),
      generation_result: Keyword.get(options, :generation_result, default_generation_result())
    })
  end

  def calls(context), do: Control.calls(context)
  def fail_next(context, %Error{} = error), do: Control.fail_next(context, error)

  @impl Singularity.Core.Embedder
  def embed_documents(context, inputs) do
    Control.run(context, :embed_documents, [inputs], fn data ->
      result =
        Enum.reduce_while(inputs, {:ok, []}, fn input, {:ok, embeddings} ->
          case Map.fetch(data.document_embeddings, input.input_id) do
            {:ok, embedding} -> {:cont, {:ok, [embedding | embeddings]}}
            :error -> {:halt, {:error, %Error{code: :not_found}}}
          end
        end)

      ordered_result =
        case result do
          {:ok, embeddings} -> {:ok, Enum.reverse(embeddings)}
          {:error, %Error{} = error} -> {:error, error}
        end

      {ordered_result, data}
    end)
  end

  @impl Singularity.Core.Embedder
  def embed_query(context, input) do
    Control.run(context, :embed_query, [input], fn data ->
      result =
        case data.query_embedding do
          %Embedding{} = embedding -> {:ok, %{embedding | input_id: input.input_id}}
          nil -> {:error, %Error{code: :not_found}}
        end

      {result, data}
    end)
  end

  @impl Singularity.Core.Generator
  def generate_answer_stream(context, request, sink) do
    with {:ok, {events, result}} <-
           Control.run(context, :generate_answer_stream, [request, sink], fn data ->
             {{:ok, {data.generation_events, data.generation_result}}, data}
           end) do
      Enum.each(events, fn event -> :ok = sink.(event) end)
      {:ok, result}
    end
  end

  defp default_document_embeddings do
    %{
      "doc-a" => %Embedding{
        input_id: "doc-a",
        vector: [0.1, 0.9],
        model: "embedding-model-1",
        usage: %{"input_tokens" => 2}
      },
      "doc-b" => %Embedding{
        input_id: "doc-b",
        vector: [0.3, 0.7],
        model: "embedding-model-1",
        usage: %{"input_tokens" => 2}
      }
    }
  end

  defp default_query_embedding do
    %Embedding{
      input_id: "query-default",
      vector: [0.5, 0.5],
      model: "embedding-model-1",
      usage: %{"input_tokens" => 3}
    }
  end

  defp default_generation_events do
    [
      %GenerationEvent{kind: :content, data: "Singularity "},
      %GenerationEvent{kind: :content, data: "answer."},
      %GenerationEvent{kind: :usage, data: %{"output_tokens" => 2}}
    ]
  end

  defp default_generation_result do
    citation = %Citation{
      item_id: "item-1",
      revision_id: "revision-1",
      chunk_id: "chunk-1",
      label: 1
    }

    %GenerationResult{
      answer: "Singularity answer.",
      citations: [citation],
      usage: %{"output_tokens" => 2},
      provider_response_id: "fake-generation-1"
    }
  end
end
