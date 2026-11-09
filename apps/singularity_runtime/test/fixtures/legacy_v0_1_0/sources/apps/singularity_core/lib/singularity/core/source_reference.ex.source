defmodule Singularity.Core.SourceReference do
  @moduledoc "Minimal provenance for a vault-scoped resource version."

  alias Singularity.Core.Error
  alias Singularity.Core.Types

  @enforce_keys [
    :source_reference_id,
    :vault_id,
    :resource_version_id,
    :principal_id,
    :kind,
    :observed_at
  ]
  defstruct [
    :source_reference_id,
    :vault_id,
    :resource_version_id,
    :principal_id,
    :kind,
    :observed_at,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          source_reference_id: Types.id(),
          vault_id: Types.id(),
          resource_version_id: Types.id(),
          principal_id: Types.id(),
          kind: atom(),
          observed_at: Types.timestamp(),
          metadata: Types.metadata()
        }

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) do
    with {:ok, attrs} <- Types.attrs(attrs),
         {:ok, source_reference_id} <- Types.opaque_string(attrs, :source_reference_id),
         {:ok, vault_id} <- Types.opaque_string(attrs, :vault_id),
         {:ok, resource_version_id} <- Types.opaque_string(attrs, :resource_version_id),
         {:ok, principal_id} <- Types.opaque_string(attrs, :principal_id),
         {:ok, kind} <- Types.atom_value(attrs, :kind),
         {:ok, observed_at} <- Types.utc_datetime(attrs, :observed_at),
         {:ok, metadata} <- Types.metadata(attrs) do
      {:ok,
       %__MODULE__{
         source_reference_id: source_reference_id,
         vault_id: vault_id,
         resource_version_id: resource_version_id,
         principal_id: principal_id,
         kind: kind,
         observed_at: observed_at,
         metadata: metadata
       }}
    end
  end
end
