defmodule Singularity.Runtime.DTO.OrganizationResource do
  @moduledoc "Owner-free resource identity and actual knowledge kind."

  @enforce_keys [:resource_id, :kind]
  defstruct @enforce_keys

  @type t :: %__MODULE__{resource_id: String.t(), kind: :asset | :document | :note}
end
