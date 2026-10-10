defmodule Singularity.Runtime.DTO.OrganizationTag do
  @moduledoc "Owner-free canonical tag identity and its first stored spelling."

  @enforce_keys [:tag_id, :display_value]
  defstruct @enforce_keys

  @type t :: %__MODULE__{tag_id: String.t(), display_value: String.t()}
end
