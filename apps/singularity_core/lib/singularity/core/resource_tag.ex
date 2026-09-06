defmodule Singularity.Core.ResourceTag do
  @moduledoc "Validated private knowledge link shape; live target checks belong to persistence."
  alias Singularity.Core.{Error, KnowledgeValidation, Types}
  @enforce_keys [:resource_id, :tag_id, :owner_scope_id, :classification]
  defstruct [:resource_id, :tag_id, :owner_scope_id, :classification]

  @type t :: %__MODULE__{
          resource_id: Types.id(),
          tag_id: Types.id(),
          owner_scope_id: Types.id(),
          classification: :private
        }
  @spec new(term()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = input), do: new(Map.from_struct(input))

  def new(input) do
    with {:ok, attrs} <-
           KnowledgeValidation.attrs(input, [
             :resource_id,
             :tag_id,
             :owner_scope_id,
             :classification
           ]),
         {:ok, _} <- Types.canonical_uuid(attrs, :resource_id),
         {:ok, _} <- Types.canonical_uuid(attrs, :tag_id),
         {:ok, _} <- Types.canonical_uuid(attrs, :owner_scope_id),
         :private <- attrs[:classification] do
      {:ok, struct(__MODULE__, attrs)}
    else
      _ -> Types.invalid()
    end
  end
end
