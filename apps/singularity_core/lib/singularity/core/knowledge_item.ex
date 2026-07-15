defmodule Singularity.Core.KnowledgeItem do
  @moduledoc "The canonical identity and current heads of a knowledge item."

  alias Singularity.Core.Types

  @enforce_keys [
    :item_id,
    :content_type,
    :title,
    :head_revision_ids,
    :status,
    :schema_version,
    :created_at,
    :updated_at
  ]

  defstruct [
    :item_id,
    :content_type,
    :title,
    :head_revision_ids,
    :status,
    :schema_version,
    :created_at,
    :updated_at,
    kind: "knowledge_item",
    tags: [],
    metadata: %{},
    deleted_at: nil
  ]

  @type content_type :: :note | :markdown | :text

  @type t :: %__MODULE__{
          kind: String.t(),
          item_id: Types.id(),
          content_type: content_type(),
          title: String.t(),
          head_revision_ids: [Types.id()],
          status: :active | :conflicted | :deleted,
          tags: [String.t()],
          metadata: Types.metadata(),
          schema_version: pos_integer(),
          created_at: Types.timestamp(),
          updated_at: Types.timestamp(),
          deleted_at: Types.timestamp() | nil
        }
end
