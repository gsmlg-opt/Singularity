defmodule Singularity.Core.AuditSink do
  @moduledoc "Port for append-only audit records."

  alias Singularity.Core.AuditEvent
  alias Singularity.Core.Error

  @type context :: term()

  @callback append(context(), AuditEvent.t()) :: :ok | {:error, Error.t()}
end
