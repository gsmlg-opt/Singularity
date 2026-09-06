defmodule Singularity.Core.DocumentSource do
  @moduledoc "A private immutable source tuple; validation does not authenticate Asset custody."
  alias Singularity.Core.{Error, KnowledgeValidation, Types}

  @enforce_keys [
    :asset_id,
    :resource_id,
    :resource_version_id,
    :object_id,
    :owner_scope_id,
    :classification,
    :digest,
    :byte_size,
    :media_type
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          asset_id: Types.id(),
          resource_id: Types.id(),
          resource_version_id: Types.id(),
          object_id: Types.id(),
          owner_scope_id: Types.id(),
          classification: :private,
          digest: binary(),
          byte_size: non_neg_integer(),
          media_type: String.t()
        }

  @spec new(term()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = input), do: new(Map.from_struct(input))

  def new(input) do
    with {:ok, attrs} <- KnowledgeValidation.attrs(input, @enforce_keys),
         true <-
           Enum.all?(
             [:asset_id, :resource_id, :resource_version_id, :object_id, :owner_scope_id],
             &match?({:ok, _}, Types.canonical_uuid(attrs, &1))
           ),
         :private <- attrs[:classification],
         true <- is_binary(attrs[:digest]) and byte_size(attrs[:digest]) == 32,
         {:ok, size} <- KnowledgeValidation.integer(attrs[:byte_size]),
         true <- size <= 67_108_864,
         true <- attrs[:media_type] in ["application/pdf", "text/markdown", "text/plain"] do
      {:ok, struct!(__MODULE__, attrs)}
    else
      _ -> Types.invalid()
    end
  end
end
