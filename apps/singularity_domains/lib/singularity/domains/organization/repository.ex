defmodule Singularity.Domains.Organization.Repository do
  @moduledoc """
  Existing-scope metadata boundary for authenticated organization operations.

  Resource selectors are one or two canonical, sorted, unique UUIDs. Results
  contain the complete requested live private set, without content hydration.
  Selected relationships preserve historical endpoints and their nullable pin.
  """
  alias Singularity.Core.{Error, Types}

  @type context :: term()
  @type resource_kind :: :asset | :note | :document
  @type resource_metadata :: %{resource_id: Types.id(), kind: resource_kind()}
  @type relationship_metadata :: %{
          relationship_id: Types.id(),
          source_resource_id: Types.id(),
          target_resource_id: Types.id(),
          target_resource_version_id: Types.id() | nil,
          type: :related_to | :references | :derived_from
        }

  @callback resources_in_scope(context(), [Types.id()]) ::
              {:ok, [resource_metadata()]} | {:error, Error.t()}
  @callback relationship_in_scope(context(), Types.id()) ::
              {:ok, relationship_metadata() | nil} | {:error, Error.t()}
end
