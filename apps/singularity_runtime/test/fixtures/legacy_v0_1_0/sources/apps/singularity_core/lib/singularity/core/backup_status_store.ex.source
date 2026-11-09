defmodule Singularity.Core.BackupStatusStore do
  @moduledoc "Port for redacted vault-scoped backup operation status."

  alias Singularity.Core.Error

  @type context :: term()

  @callback fetch(context(), %{operation_id: String.t(), vault_id: String.t()}) ::
              {:ok, map()} | {:error, Error.t()}
end
