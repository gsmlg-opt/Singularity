defmodule Singularity.Runtime.Notes.Delete do
  @moduledoc "Tombstones a private note without exposing retained content."

  alias Singularity.Core.Error
  alias Singularity.Runtime.Notes.Mutation
  alias Singularity.Runtime.SessionContext

  @spec run(map(), SessionContext.t(), String.t(), map() | keyword()) ::
          {:ok, true} | {:error, Error.t()}
  def run(runtime, %SessionContext{} = session, resource_id, attrs),
    do: Mutation.run(:tombstone, runtime, session, resource_id, attrs)

  def run(_runtime, _session, _resource_id, _attrs), do: {:error, Error.new(:invalid)}
end
