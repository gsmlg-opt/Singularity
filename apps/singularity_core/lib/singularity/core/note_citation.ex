defmodule Singularity.Core.NoteCitation do
  @moduledoc "Validated private knowledge link shape; live target checks belong to persistence."
  alias Singularity.Core.{Error, KnowledgeValidation, Types}

  @enforce_keys [
    :note_resource_id,
    :note_resource_version_id,
    :owner_scope_id,
    :citation_id,
    :source_resource_id,
    :source_resource_version_id,
    :classification,
    :fragment_id,
    :locator,
    :ordinal
  ]
  defstruct [
    :note_resource_id,
    :note_resource_version_id,
    :owner_scope_id,
    :citation_id,
    :source_resource_id,
    :source_resource_version_id,
    :classification,
    :fragment_id,
    :locator,
    :ordinal
  ]

  @type t :: %__MODULE__{
          note_resource_id: Types.id(),
          note_resource_version_id: Types.id(),
          owner_scope_id: Types.id(),
          citation_id: Types.id(),
          source_resource_id: Types.id(),
          source_resource_version_id: Types.id(),
          classification: :private,
          fragment_id: String.t(),
          locator: Singularity.Core.SourceLocator.t(),
          ordinal: non_neg_integer()
        }
  @spec new(term()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = input), do: new(Map.from_struct(input))

  def new(input) do
    with {:ok, attrs} <-
           KnowledgeValidation.attrs(input, [
             :note_resource_id,
             :note_resource_version_id,
             :owner_scope_id,
             :citation_id,
             :source_resource_id,
             :source_resource_version_id,
             :classification,
             :fragment_id,
             :locator,
             :ordinal
           ]),
         {:ok, _} <- Types.canonical_uuid(attrs, :note_resource_id),
         {:ok, _} <- Types.canonical_uuid(attrs, :note_resource_version_id),
         {:ok, _} <- Types.canonical_uuid(attrs, :owner_scope_id),
         {:ok, _} <- Types.canonical_uuid(attrs, :citation_id),
         {:ok, _} <- Types.canonical_uuid(attrs, :source_resource_id),
         {:ok, _} <- Types.canonical_uuid(attrs, :source_resource_version_id),
         :private <- attrs[:classification],
         true <- attrs.note_resource_id != attrs.source_resource_id,
         true <-
           is_binary(attrs[:fragment_id]) and
             Regex.match?(~r/\A[0-9a-f]{64}\z/, attrs.fragment_id),
         {:ok, ordinal} <- KnowledgeValidation.integer(attrs[:ordinal]),
         {:ok, locator} <- Singularity.Core.SourceLocator.new(attrs[:locator]) do
      {:ok, struct(__MODULE__, Map.merge(attrs, %{ordinal: ordinal, locator: locator}))}
    else
      _ -> Types.invalid()
    end
  end
end
