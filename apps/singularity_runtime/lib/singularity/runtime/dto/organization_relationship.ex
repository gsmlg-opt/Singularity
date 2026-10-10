defmodule Singularity.Runtime.DTO.OrganizationRelationship do
  @moduledoc "Owner-free directed relationship with an explicit nullable version pin."

  @enforce_keys [
    :relationship_id,
    :source_resource_id,
    :target_resource_id,
    :target_resource_version_id,
    :type
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          relationship_id: String.t(),
          source_resource_id: String.t(),
          target_resource_id: String.t(),
          target_resource_version_id: String.t() | nil,
          type: :related_to | :references | :derived_from
        }
end
