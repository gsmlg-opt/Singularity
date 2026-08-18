defmodule Singularity.Core.NoteSearchStore do
  @moduledoc "Port for the rebuildable private note search projection."

  alias Singularity.Core.Error

  @callback search(term(), term()) :: {:ok, map()} | {:error, Error.t()}
  @callback upsert(term(), map()) :: :ok | {:error, Error.t()}
  @callback delete(term(), map()) :: :ok | {:error, Error.t()}
end
