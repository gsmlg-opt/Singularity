defmodule Singularity.Domains.Documents.Command do
  @moduledoc "Internal private Document creation intent. Principal and owner require independent storage authentication."
  alias Singularity.Core.{DocumentSource, Error, KnowledgeValidation, Types}

  @enforce_keys [
    :mutation_id,
    :resource_id,
    :resource_version_id,
    :title,
    :source,
    :principal_id,
    :owner_scope_id,
    :classification,
    :correlation_id,
    :inserted_at
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          mutation_id: Types.id(),
          resource_id: Types.id(),
          resource_version_id: Types.id(),
          title: String.t(),
          source: DocumentSource.t(),
          principal_id: Types.id(),
          owner_scope_id: Types.id(),
          classification: :private,
          correlation_id: Types.id(),
          inserted_at: DateTime.t()
        }

  @spec new(term()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = input), do: new(Map.from_struct(input))

  def new(input) do
    with {:ok, attrs} <- KnowledgeValidation.attrs(input, @enforce_keys),
         true <-
           Enum.all?(
             [
               :mutation_id,
               :resource_id,
               :resource_version_id,
               :principal_id,
               :owner_scope_id,
               :correlation_id
             ],
             &match?({:ok, _}, Types.canonical_uuid(attrs, &1))
           ),
         :private <- attrs[:classification],
         %DocumentSource{} = source <- attrs[:source],
         {:ok, ^source} <- DocumentSource.new(source),
         true <- source.owner_scope_id == attrs.owner_scope_id,
         true <-
           source.resource_id != attrs.resource_id and
             source.resource_version_id != attrs.resource_version_id,
         {:ok, title} <- KnowledgeValidation.bounded_name(attrs[:title]),
         {:ok, _} <- KnowledgeValidation.utc_datetime(attrs, :inserted_at) do
      {:ok, struct!(__MODULE__, Map.put(attrs, :title, title))}
    else
      _ -> Types.invalid()
    end
  end

  @doc "Canonical fingerprint input; storage applies its private HMAC and owner/principal receipt scope."
  @spec fingerprint_term(t()) :: tuple()
  def fingerprint_term(%__MODULE__{} = command) do
    source = command.source

    {:document_import_v1, command.mutation_id, source.asset_id, source.resource_id,
     source.resource_version_id, source.object_id, source.digest, source.byte_size,
     source.media_type, command.title, :private}
  end
end
