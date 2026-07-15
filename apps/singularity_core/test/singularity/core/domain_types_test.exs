defmodule Singularity.Core.DomainTypesTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.AnswerRun
  alias Singularity.Core.BlobRef
  alias Singularity.Core.Block
  alias Singularity.Core.Citation
  alias Singularity.Core.Error
  alias Singularity.Core.KnowledgeChunk
  alias Singularity.Core.KnowledgeItem
  alias Singularity.Core.KnowledgeRevision
  alias Singularity.Core.ProjectionState
  alias Singularity.Core.Retrieval.Candidate
  alias Singularity.Core.Retrieval.Filters
  alias Singularity.Core.Retrieval.Result
  alias Singularity.Core.Source
  alias Singularity.Core.Stored

  @created_at ~U[2026-07-16 08:00:00Z]
  @updated_at ~U[2026-07-16 08:05:00Z]

  test "common domain structs expose their complete public shapes and defaults" do
    assert %Error{
             code: :invalid,
             message: nil,
             details: %{},
             retryable?: false
           } = %Error{code: :invalid}

    assert %Stored{value: "value", version: "opaque-version-1"} =
             %Stored{value: "value", version: "opaque-version-1"}
  end

  test "canonical knowledge structs expose their complete public shapes and defaults" do
    assert %BlobRef{
             blob_id: "blob-1",
             sha256: "blob-sha256",
             byte_size: 128,
             media_type: nil,
             original_filename: nil
           } = %BlobRef{blob_id: "blob-1", sha256: "blob-sha256", byte_size: 128}

    assert %Source{
             kind: :note,
             original_filename: nil,
             media_type: nil,
             byte_size: nil,
             sha256: nil,
             blob_ref: nil,
             metadata: %{}
           } = %Source{kind: :note}

    assert %KnowledgeItem{
             kind: "knowledge_item",
             item_id: "item-1",
             content_type: :note,
             title: "Representative note",
             head_revision_ids: ["revision-1"],
             status: :active,
             tags: [],
             metadata: %{},
             schema_version: 1,
             created_at: @created_at,
             updated_at: @updated_at,
             deleted_at: nil
           } =
             %KnowledgeItem{
               item_id: "item-1",
               content_type: :note,
               title: "Representative note",
               head_revision_ids: ["revision-1"],
               status: :active,
               schema_version: 1,
               created_at: @created_at,
               updated_at: @updated_at
             }

    block = %Block{kind: :paragraph, text: "Knowledge text", start_offset: 0, end_offset: 14}
    source = %Source{kind: :note}

    assert %Block{
             kind: :paragraph,
             text: "Knowledge text",
             start_offset: 0,
             end_offset: 14,
             heading_path: [],
             metadata: %{}
           } = block

    assert %KnowledgeRevision{
             kind: "knowledge_revision",
             revision_id: "revision-1",
             item_id: "item-1",
             parent_revision_ids: [],
             content_type: :note,
             canonical_text: "Knowledge text",
             structured_content: [^block],
             content_hash: "revision-content-hash",
             source: ^source,
             parser_version: "parser-1",
             normalizer_version: "normalizer-1",
             created_by: :human,
             schema_version: 1,
             created_at: @created_at,
             updated_at: @updated_at
           } =
             %KnowledgeRevision{
               revision_id: "revision-1",
               item_id: "item-1",
               parent_revision_ids: [],
               content_type: :note,
               canonical_text: "Knowledge text",
               structured_content: [block],
               content_hash: "revision-content-hash",
               source: source,
               parser_version: "parser-1",
               normalizer_version: "normalizer-1",
               created_by: :human,
               schema_version: 1,
               created_at: @created_at,
               updated_at: @updated_at
             }

    assert %KnowledgeChunk{
             kind: "knowledge_chunk",
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
           } =
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

    assert %Citation{
             item_id: "item-1",
             revision_id: "revision-1",
             chunk_id: "chunk-1",
             label: nil
           } = %Citation{item_id: "item-1", revision_id: "revision-1", chunk_id: "chunk-1"}

    assert %ProjectionState{
             kind: "projection_state",
             revision_id: "revision-1",
             pipeline_version: "pipeline-1",
             embedding_model: "embedding-model-1",
             embedding_dimensions: 1_536,
             collection_version: "collection-1",
             status: :pending,
             attempts: 0,
             last_error: nil,
             indexed_at: nil,
             schema_version: 1,
             created_at: @created_at,
             updated_at: @updated_at
           } =
             %ProjectionState{
               revision_id: "revision-1",
               pipeline_version: "pipeline-1",
               embedding_model: "embedding-model-1",
               embedding_dimensions: 1_536,
               collection_version: "collection-1",
               status: :pending,
               attempts: 0,
               schema_version: 1,
               created_at: @created_at,
               updated_at: @updated_at
             }
  end

  test "retrieval and answer structs expose their complete public shapes and defaults" do
    assert %Filters{content_types: [], tags: [], include_non_head?: false} = %Filters{}

    candidate =
      %Candidate{
        item_id: "item-1",
        revision_id: "revision-1",
        chunk_id: "chunk-1",
        score: 0.98
      }

    assert %Candidate{
             item_id: "item-1",
             revision_id: "revision-1",
             chunk_id: "chunk-1",
             score: 0.98,
             metadata: %{}
           } = candidate

    assert %Result{
             query: "What is Singularity?",
             candidates: [^candidate],
             filters: %Filters{content_types: [], tags: [], include_non_head?: false}
           } = %Result{query: "What is Singularity?", candidates: [candidate]}

    filters = %Filters{content_types: [:note], tags: ["elixir"], include_non_head?: true}

    retrieval_snapshot =
      %Result{
        query: "What is Singularity?",
        candidates: [candidate],
        filters: filters
      }

    assert %AnswerRun{
             kind: "answer_run",
             run_id: "run-1",
             question: "What is Singularity?",
             filters: ^filters,
             retrieval_snapshot: ^retrieval_snapshot,
             selected_chunk_ids: ["chunk-1"],
             prompt_program_version: "prompt-1",
             model_route: "model-route-1",
             status: :complete,
             answer: nil,
             citations: [],
             usage: %{},
             latency_ms: nil,
             error: nil,
             schema_version: 1,
             created_at: @created_at,
             updated_at: @updated_at
           } =
             %AnswerRun{
               run_id: "run-1",
               question: "What is Singularity?",
               filters: filters,
               retrieval_snapshot: retrieval_snapshot,
               selected_chunk_ids: ["chunk-1"],
               prompt_program_version: "prompt-1",
               model_route: "model-route-1",
               status: :complete,
               schema_version: 1,
               created_at: @created_at,
               updated_at: @updated_at
             }
  end

  test "schema versions accept only the current positive version" do
    assert 1 == Singularity.Core.SchemaVersion.current()
    assert :ok == Singularity.Core.SchemaVersion.validate(1)

    assert {:error, %Singularity.Core.Error{code: :invalid}} =
             Singularity.Core.SchemaVersion.validate(0)

    assert {:error, %Singularity.Core.Error{code: :unsupported}} =
             Singularity.Core.SchemaVersion.validate(2)
  end
end
