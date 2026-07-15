defmodule Singularity.Core.KnowledgeRevision do
  @moduledoc "An immutable canonical revision of a knowledge item."

  alias Singularity.Core.Block
  alias Singularity.Core.KnowledgeItem
  alias Singularity.Core.Source
  alias Singularity.Core.Types

  @enforce_keys [
    :revision_id,
    :item_id,
    :parent_revision_ids,
    :content_type,
    :canonical_text,
    :structured_content,
    :content_hash,
    :source,
    :parser_version,
    :normalizer_version,
    :created_by,
    :schema_version,
    :created_at,
    :updated_at
  ]

  defstruct [
    :revision_id,
    :item_id,
    :parent_revision_ids,
    :content_type,
    :canonical_text,
    :structured_content,
    :content_hash,
    :source,
    :parser_version,
    :normalizer_version,
    :created_by,
    :schema_version,
    :created_at,
    :updated_at,
    kind: "knowledge_revision"
  ]

  @type t :: %__MODULE__{
          kind: String.t(),
          revision_id: Types.id(),
          item_id: Types.id(),
          parent_revision_ids: [Types.id()],
          content_type: KnowledgeItem.content_type(),
          canonical_text: String.t(),
          structured_content: [Block.t()],
          content_hash: Types.hash(),
          source: Source.t(),
          parser_version: Types.version(),
          normalizer_version: Types.version(),
          created_by: :human | :importer | :model_proposal,
          schema_version: pos_integer(),
          created_at: Types.timestamp(),
          updated_at: Types.timestamp()
        }
end
