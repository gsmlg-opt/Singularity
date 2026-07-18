defmodule Singularity.Core.JobHandler do
  @moduledoc "Injected runtime handler for a storage-owned generic job worker."

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope

  @callback dependencies() :: map()
  @callback handle(map(), JobEnvelope.t()) ::
              :ok | {:ok, term()} | {:error, Error.t()} | {:snooze, pos_integer()}
end
