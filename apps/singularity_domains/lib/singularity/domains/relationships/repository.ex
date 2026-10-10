defmodule Singularity.Domains.Relationships.Repository do
  @moduledoc """
  Internal owner-authenticated Relationship persistence boundary.
  Legacy lists contain at most 100 relationships in deterministic UUID order per internal call.
  Scoped pages use bounded relationship-UUID keysets and owner-free items.
  """
  alias Singularity.Core.{Error, OrganizationPage, OrganizationPageQuery, Relationship, Types}
  @type context :: term()
  @type resource_kind :: :asset | :note | :document
  @callback relate(context(), Relationship.t()) :: {:ok, Relationship.t()} | {:error, Error.t()}
  @callback unrelate(context(), Types.id()) :: :ok | {:error, Error.t()}
  @callback outgoing(context(), Types.id()) :: {:ok, [Relationship.t()]} | {:error, Error.t()}
  @callback incoming(context(), Types.id()) :: {:ok, [Relationship.t()]} | {:error, Error.t()}
  @callback relate_in_scope(context(), Relationship.t()) ::
              {:ok, Relationship.t()} | {:error, Error.t()}
  @callback unrelate_in_scope(context(), Types.id()) :: :ok | {:error, Error.t()}
  @callback unrelate_selected_in_scope(
              context(),
              Singularity.Domains.Organization.Repository.relationship_metadata()
            ) :: :ok | {:error, Error.t()}
  @callback outgoing_page_in_scope(
              context(),
              Types.id(),
              OrganizationPageQuery.t(),
              [resource_kind()]
            ) :: {:ok, OrganizationPage.t()} | {:error, Error.t()}
  @callback incoming_page_in_scope(
              context(),
              Types.id(),
              OrganizationPageQuery.t(),
              [resource_kind()]
            ) :: {:ok, OrganizationPage.t()} | {:error, Error.t()}
end
