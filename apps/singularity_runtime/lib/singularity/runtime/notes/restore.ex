defmodule Singularity.Runtime.Notes.Restore do
  @moduledoc "Restores a tombstoned private note and reloads its canonical head."

  alias Singularity.Core.Error
  alias Singularity.Runtime.Notes.Mutation
  alias Singularity.Runtime.SessionContext

  @spec run(map(), SessionContext.t(), String.t(), map() | keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def run(runtime, %SessionContext{} = session, resource_id, attrs),
    do: Mutation.run(:restore, runtime, session, resource_id, attrs)

  def run(_runtime, _session, _resource_id, _attrs), do: {:error, Error.new(:invalid)}
end
