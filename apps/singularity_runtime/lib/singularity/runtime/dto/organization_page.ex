defmodule Singularity.Runtime.DTO.OrganizationPage do
  @moduledoc "One bounded organization page with a public nil terminal."

  alias Singularity.Runtime.DTO.{OrganizationRelationship, OrganizationResource, OrganizationTag}

  @enforce_keys [:items, :next_cursor]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          items: [OrganizationTag.t() | OrganizationResource.t() | OrganizationRelationship.t()],
          next_cursor: String.t() | nil
        }
end
