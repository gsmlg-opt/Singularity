defmodule Singularity.Runtime.Notes.Save do
  @moduledoc "Saves a private note or preserves a stale edit as a conflict."

  alias Singularity.Core.Error
  alias Singularity.Runtime.Notes.Mutation
  alias Singularity.Runtime.SessionContext

  @spec run(map(), SessionContext.t(), String.t(), map() | keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def run(runtime, %SessionContext{} = session, resource_id, attrs),
    do: Mutation.run(:save, runtime, session, resource_id, attrs)

  def run(_runtime, _session, _resource_id, _attrs), do: {:error, Error.new(:invalid)}
end
