defmodule Singularity.Core.ResourceVersion do
  @moduledoc "An immutable, vault-scoped resource version."

  alias Singularity.Core.Classification
  alias Singularity.Core.Error
  alias Singularity.Core.Types

  @enforce_keys [:resource_version_id, :resource_id, :vault_id, :classification, :revision]
  defstruct [
    :resource_version_id,
    :resource_id,
    :vault_id,
    :classification,
    :revision,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          resource_version_id: Types.id(),
          resource_id: Types.id(),
          vault_id: Types.id(),
          classification: Classification.t(),
          revision: non_neg_integer(),
          metadata: Types.metadata()
        }

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) do
    with {:ok, attrs} <- Types.attrs(attrs),
         {:ok, resource_version_id} <- Types.opaque_string(attrs, :resource_version_id),
         {:ok, resource_id} <- Types.opaque_string(attrs, :resource_id),
         {:ok, vault_id} <- Types.opaque_string(attrs, :vault_id),
         {:ok, classification} <- Classification.new(Map.get(attrs, :classification)),
         {:ok, revision} <- Types.non_neg_integer(attrs, :revision),
         {:ok, metadata} <- Types.metadata(attrs) do
      {:ok,
       %__MODULE__{
         resource_version_id: resource_version_id,
         resource_id: resource_id,
         vault_id: vault_id,
         classification: classification,
         revision: revision,
         metadata: metadata
       }}
    end
  end
end
