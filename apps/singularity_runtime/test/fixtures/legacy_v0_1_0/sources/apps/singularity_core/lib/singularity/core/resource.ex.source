defmodule Singularity.Core.Resource do
  @moduledoc "A vault-scoped logical resource."

  alias Singularity.Core.Classification
  alias Singularity.Core.Error
  alias Singularity.Core.Types

  @enforce_keys [:resource_id, :vault_id, :classification]
  defstruct [:resource_id, :vault_id, :classification, metadata: %{}]

  @type t :: %__MODULE__{
          resource_id: Types.id(),
          vault_id: Types.id(),
          classification: Classification.t(),
          metadata: Types.metadata()
        }

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) do
    with {:ok, attrs} <- Types.attrs(attrs),
         {:ok, resource_id} <- Types.opaque_string(attrs, :resource_id),
         {:ok, vault_id} <- Types.opaque_string(attrs, :vault_id),
         {:ok, classification} <- Classification.new(Map.get(attrs, :classification)),
         {:ok, metadata} <- Types.metadata(attrs) do
      {:ok,
       %__MODULE__{
         resource_id: resource_id,
         vault_id: vault_id,
         classification: classification,
         metadata: metadata
       }}
    end
  end
end
