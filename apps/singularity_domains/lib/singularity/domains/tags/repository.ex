defmodule Singularity.Domains.Tags.Repository do
  @moduledoc """
  Internal owner-authenticated Tag persistence boundary.
  Legacy lists contain at most 100 tags in deterministic UUID order per internal call.
  Scoped pages use the bounded owner-free organization page contract.
  """
  alias Singularity.Core.{Error, OrganizationPage, OrganizationPageQuery, Tag, Types}
  @type context :: term()
  @callback resolve(context(), Tag.t()) :: {:ok, Tag.t()} | {:error, Error.t()}
  @callback attach(context(), Types.id(), Types.id()) :: :ok | {:error, Error.t()}
  @callback detach(context(), Types.id(), Types.id()) :: :ok | {:error, Error.t()}
  @callback list(context(), Types.id()) :: {:ok, [Tag.t()]} | {:error, Error.t()}
  @callback resolve_in_scope(context(), Tag.t()) :: {:ok, Tag.t()} | {:error, Error.t()}
  @callback attach_in_scope(context(), Types.id(), Types.id()) :: :ok | {:error, Error.t()}
  @callback detach_in_scope(context(), Types.id(), Types.id()) :: :ok | {:error, Error.t()}
  @callback list_page_in_scope(
              context(),
              Types.id(),
              OrganizationPageQuery.t(),
              [:asset | :document | :note]
            ) :: {:ok, OrganizationPage.t()} | {:error, Error.t()}
  @callback browse_in_scope(
              context(),
              Types.id(),
              OrganizationPageQuery.t(),
              [:asset | :document | :note]
            ) :: {:ok, OrganizationPage.t()} | {:error, Error.t()}
end
