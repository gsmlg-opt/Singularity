defmodule Singularity.Core.BehavioursTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Citation
  alias Singularity.Core.CollectionSpec
  alias Singularity.Core.Embedding
  alias Singularity.Core.EmbeddingInput
  alias Singularity.Core.GenerationEvent
  alias Singularity.Core.GenerationEvidence
  alias Singularity.Core.GenerationRequest
  alias Singularity.Core.GenerationResult
  alias Singularity.Core.KnowledgeChunk
  alias Singularity.Core.VectorMatch
  alias Singularity.Core.VectorPoint

  @created_at ~U[2026-07-16 08:00:00Z]
  @updated_at ~U[2026-07-16 08:05:00Z]

  @callbacks %{
    Singularity.Core.KnowledgeStore => [
      append_answer_run: 2,
      create_item: 2,
      create_revision: 2,
      fetch_answer_run: 2,
      fetch_chunk: 2,
      fetch_item: 2,
      fetch_projection_state: 2,
      fetch_revision: 2,
      list_chunks: 2,
      list_revisions: 2,
      put_chunks: 3,
      put_projection_state: 2,
      replace_item: 2,
      scan_current_revisions: 2
    ],
    Singularity.Core.BlobStore => [fetch: 2, put: 3],
    Singularity.Core.VectorStore => [
      delete_points: 3,
      ensure_collection: 2,
      fetch_collection: 2,
      fetch_points: 3,
      scroll: 3,
      search: 6,
      upsert_points: 3
    ],
    Singularity.Core.Embedder => [embed_documents: 2, embed_query: 2],
    Singularity.Core.Generator => [generate_answer_stream: 3]
  }

  test "behaviours expose the exact callback inventory" do
    for {behaviour, expected_callbacks} <- @callbacks do
      assert Enum.sort(behaviour.behaviour_info(:callbacks)) == Enum.sort(expected_callbacks)
    end
  end

  test "provider-independent DTOs expose their complete public shapes and defaults" do
    assert %CollectionSpec{
             name: "knowledge-v1",
             dimensions: 1_536,
             distance: :cosine,
             embedding_model: "embedding-model-1",
             collection_version: "collection-1"
           } =
             %CollectionSpec{
               name: "knowledge-v1",
               dimensions: 1_536,
               distance: :cosine,
               embedding_model: "embedding-model-1",
               collection_version: "collection-1"
             }

    assert %VectorPoint{
             point_id: "point-1",
             vector: [0.25, 0.75],
             payload: %{"chunk_id" => "chunk-1"}
           } =
             %VectorPoint{
               point_id: "point-1",
               vector: [0.25, 0.75],
               payload: %{"chunk_id" => "chunk-1"}
             }

    assert %VectorMatch{
             point_id: "point-1",
             score: 0.98,
             payload: %{"chunk_id" => "chunk-1"}
           } =
             %VectorMatch{
               point_id: "point-1",
               score: 0.98,
               payload: %{"chunk_id" => "chunk-1"}
             }

    assert %EmbeddingInput{
             input_id: "chunk-1",
             text: "Knowledge text",
             metadata: %{}
           } = %EmbeddingInput{input_id: "chunk-1", text: "Knowledge text"}

    assert %Embedding{
             input_id: "chunk-1",
             vector: [0.25, 0.75],
             model: "embedding-model-1",
             usage: %{}
           } =
             %Embedding{
               input_id: "chunk-1",
               vector: [0.25, 0.75],
               model: "embedding-model-1"
             }

    chunk = knowledge_chunk()

    evidence = %GenerationEvidence{label: 1, chunk: chunk}

    assert %GenerationEvidence{label: 1, chunk: ^chunk} = evidence

    assert %GenerationRequest{
             question: "What is Singularity?",
             evidence: [^evidence],
             prompt_program_version: "prompt-1",
             model_route: "model-route-1",
             metadata: %{}
           } =
             %GenerationRequest{
               question: "What is Singularity?",
               evidence: [evidence],
               prompt_program_version: "prompt-1",
               model_route: "model-route-1"
             }

    assert %GenerationEvent{kind: :content, data: "Singularity is a knowledge core."} =
             %GenerationEvent{kind: :content, data: "Singularity is a knowledge core."}

    citation = %Citation{
      item_id: "item-1",
      revision_id: "revision-1",
      chunk_id: "chunk-1",
      label: 1
    }

    assert %GenerationResult{
             answer: "Singularity is a knowledge core.",
             citations: [^citation],
             usage: %{"output_tokens" => 7},
             provider_response_id: nil
           } =
             %GenerationResult{
               answer: "Singularity is a knowledge core.",
               citations: [citation],
               usage: %{"output_tokens" => 7}
             }
  end

  defp knowledge_chunk do
    %KnowledgeChunk{
      chunk_id: "chunk-1",
      item_id: "item-1",
      revision_id: "revision-1",
      position: 0,
      heading_path: ["Introduction"],
      text: "Knowledge text",
      start_offset: 0,
      end_offset: 14,
      token_count: 2,
      content_hash: "chunk-content-hash",
      chunker_version: "chunker-1",
      schema_version: 1,
      created_at: @created_at,
      updated_at: @updated_at
    }
  end
end
