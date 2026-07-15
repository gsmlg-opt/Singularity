defmodule Singularity.Core.Retrieval do
  @moduledoc "Provider-independent semantic retrieval values."
end

defmodule Singularity.Core.Retrieval.Filters do
  @moduledoc "Provider-independent filters applied to semantic retrieval."

  alias Singularity.Core.KnowledgeItem

  @enforce_keys []
  defstruct content_types: [], tags: [], include_non_head?: false

  @type t :: %__MODULE__{
          content_types: [KnowledgeItem.content_type()],
          tags: [String.t()],
          include_non_head?: boolean()
        }
end

defmodule Singularity.Core.Retrieval.Candidate do
  @moduledoc "A scored knowledge chunk returned by semantic retrieval."

  alias Singularity.Core.Types

  @enforce_keys [:item_id, :revision_id, :chunk_id, :score]
  defstruct [:item_id, :revision_id, :chunk_id, :score, metadata: %{}]

  @type t :: %__MODULE__{
          item_id: Types.id(),
          revision_id: Types.id(),
          chunk_id: Types.id(),
          score: float(),
          metadata: Types.metadata()
        }
end

defmodule Singularity.Core.Retrieval.Result do
  @moduledoc "A provider-independent semantic retrieval result."

  alias Singularity.Core.Retrieval.Candidate
  alias Singularity.Core.Retrieval.Filters

  @enforce_keys [:query, :candidates]
  defstruct [:query, :candidates, filters: %Filters{}]

  @type t :: %__MODULE__{
          query: String.t(),
          candidates: [Candidate.t()],
          filters: Filters.t()
        }
end
