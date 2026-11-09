defmodule Singularity.Core.JobRunner do
  @moduledoc "Port for submitting versioned jobs and waking vault-scoped waiting work."

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope

  @type context :: term()

  @callback submit(context(), JobEnvelope.t()) :: {:ok, String.t()} | {:error, Error.t()}
  @callback wake_vault(context(), String.t()) :: :ok | {:error, Error.t()}
end
