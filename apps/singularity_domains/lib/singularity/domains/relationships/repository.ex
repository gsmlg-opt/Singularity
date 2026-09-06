defmodule Singularity.Domains.Relationships.Repository do
  @moduledoc """
  Internal owner-authenticated Relationship persistence boundary.
  Lists contain at most 100 relationships in deterministic UUID order per internal call.
  """
  alias Singularity.Core.{Error, Relationship, Types}
  @type context :: term()
  @callback relate(context(), Relationship.t()) :: {:ok, Relationship.t()} | {:error, Error.t()}
  @callback unrelate(context(), Types.id()) :: :ok | {:error, Error.t()}
  @callback outgoing(context(), Types.id()) :: {:ok, [Relationship.t()]} | {:error, Error.t()}
  @callback incoming(context(), Types.id()) :: {:ok, [Relationship.t()]} | {:error, Error.t()}
end
