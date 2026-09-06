defmodule Singularity.Core.Relationship do
  @moduledoc "Validated private knowledge link shape; live target checks belong to persistence."
  alias Singularity.Core.{Error, KnowledgeValidation, Types}

  @enforce_keys [
    :relationship_id,
    :source_resource_id,
    :target_resource_id,
    :owner_scope_id,
    :classification,
    :type
  ]
  defstruct [
    :relationship_id,
    :source_resource_id,
    :target_resource_id,
    :owner_scope_id,
    :classification,
    :target_resource_version_id,
    :type
  ]

  @type t :: %__MODULE__{
          relationship_id: Types.id(),
          source_resource_id: Types.id(),
          target_resource_id: Types.id(),
          target_resource_version_id: Types.id() | nil,
          owner_scope_id: Types.id(),
          classification: :private,
          type: :related_to | :references | :derived_from
        }
  @spec new(term()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = input), do: new(Map.from_struct(input))

  def new(input) do
    with {:ok, attrs} <-
           KnowledgeValidation.attrs(input, [
             :relationship_id,
             :source_resource_id,
             :target_resource_id,
             :owner_scope_id,
             :classification,
             :target_resource_version_id,
             :type
           ]),
         {:ok, _} <- Types.canonical_uuid(attrs, :relationship_id),
         {:ok, _} <- Types.canonical_uuid(attrs, :source_resource_id),
         {:ok, _} <- Types.canonical_uuid(attrs, :target_resource_id),
         {:ok, _} <- Types.canonical_uuid(attrs, :owner_scope_id),
         :private <- attrs[:classification],
         true <- attrs[:type] in [:related_to, :references, :derived_from],
         true <- attrs.source_resource_id != attrs.target_resource_id,
         true <-
           is_nil(attrs[:target_resource_version_id]) or
             match?({:ok, _}, Types.canonical_uuid(attrs, :target_resource_version_id)) do
      {:ok, struct(__MODULE__, attrs)}
    else
      _ -> Types.invalid()
    end
  end
end
