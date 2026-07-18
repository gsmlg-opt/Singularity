defmodule Singularity.Core.Outbox do
  @moduledoc "Port for durable event append, claim, and acknowledgement."

  alias Singularity.Core.Error
  alias Singularity.Core.OutboxEvent

  @type context :: term()

  @callback append(context(), OutboxEvent.t()) ::
              {:ok, OutboxEvent.t()} | {:error, Error.t()}
  @callback claim(context(), map()) :: {:ok, [OutboxEvent.t()]} | {:error, Error.t()}
  @callback acknowledge(context(), String.t(), map()) :: :ok | {:error, Error.t()}
end
