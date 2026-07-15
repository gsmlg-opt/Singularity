defmodule Singularity.Core.Citation do
  @moduledoc "Identifies the exact knowledge chunk cited by an answer."

  alias Singularity.Core.Types

  @enforce_keys [:item_id, :revision_id, :chunk_id]
  defstruct [:item_id, :revision_id, :chunk_id, label: nil]

  @type t :: %__MODULE__{
          item_id: Types.id(),
          revision_id: Types.id(),
          chunk_id: Types.id(),
          label: pos_integer() | nil
        }
end
