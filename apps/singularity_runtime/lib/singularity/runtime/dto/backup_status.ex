defmodule Singularity.Runtime.DTO.BackupStatus do
  @moduledoc "Web-safe status for one authorized backup operation."

  @enforce_keys [:operation_id, :status, :requested_at, :updated_at]
  defstruct @enforce_keys

  @type status :: :pending | :waiting_for_backup_key | :copying | :sealed | :failed

  @type t :: %__MODULE__{
          operation_id: String.t(),
          status: status(),
          requested_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
