defmodule Singularity.Core.KnowledgeChunk do
  @moduledoc "A position-addressed retrieval chunk derived from a knowledge revision."

  alias Singularity.Core.Types

  @enforce_keys [
    :chunk_id,
    :item_id,
    :revision_id,
    :position,
    :heading_path,
    :text,
    :start_offset,
    :end_offset,
    :token_count,
    :content_hash,
    :chunker_version,
    :schema_version,
    :created_at,
    :updated_at
  ]

  defstruct [
    :chunk_id,
    :item_id,
    :revision_id,
    :position,
    :heading_path,
    :text,
    :start_offset,
    :end_offset,
    :token_count,
    :content_hash,
    :chunker_version,
    :schema_version,
    :created_at,
    :updated_at,
    kind: "knowledge_chunk"
  ]

  @type t :: %__MODULE__{
          kind: String.t(),
          chunk_id: Types.id(),
          item_id: Types.id(),
          revision_id: Types.id(),
          position: non_neg_integer(),
          heading_path: [String.t()],
          text: String.t(),
          start_offset: non_neg_integer(),
          end_offset: non_neg_integer(),
          token_count: non_neg_integer(),
          content_hash: Types.hash(),
          chunker_version: Types.version(),
          schema_version: pos_integer(),
          created_at: Types.timestamp(),
          updated_at: Types.timestamp()
        }
end
