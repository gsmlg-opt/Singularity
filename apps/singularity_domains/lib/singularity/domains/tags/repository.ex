defmodule Singularity.Domains.Tags.Repository do
  @moduledoc """
  Internal owner-authenticated Tag persistence boundary.
  Lists contain at most 100 tags in deterministic UUID order per internal call.
  """
  alias Singularity.Core.{Error, Tag, Types}
  @type context :: term()
  @callback resolve(context(), Tag.t()) :: {:ok, Tag.t()} | {:error, Error.t()}
  @callback attach(context(), Types.id(), Types.id()) :: :ok | {:error, Error.t()}
  @callback detach(context(), Types.id(), Types.id()) :: :ok | {:error, Error.t()}
  @callback list(context(), Types.id()) :: {:ok, [Tag.t()]} | {:error, Error.t()}
end
