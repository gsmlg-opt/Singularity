defmodule Singularity.Core.DocumentFragment do
  @moduledoc "Immutable private text with source provenance and a canonical content identity."
  alias Singularity.Core.{Error, KnowledgeEncoding, KnowledgeValidation, SourceLocator, Types}

  @enforce_keys [
    :resource_id,
    :resource_version_id,
    :owner_scope_id,
    :classification,
    :ordinal,
    :text,
    :digest,
    :locator,
    :fragment_id
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          resource_id: Types.id(),
          resource_version_id: Types.id(),
          owner_scope_id: Types.id(),
          classification: :private,
          ordinal: non_neg_integer(),
          text: String.t(),
          digest: binary(),
          locator: SourceLocator.t(),
          fragment_id: String.t()
        }

  @spec new(term()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = input), do: new(Map.from_struct(input))

  def new(input) do
    with {:ok, attrs} <- KnowledgeValidation.attrs(input, @enforce_keys),
         {:ok, resource_id} <- Types.canonical_uuid(attrs, :resource_id),
         {:ok, version_id} <- Types.canonical_uuid(attrs, :resource_version_id),
         {:ok, owner_id} <- Types.canonical_uuid(attrs, :owner_scope_id),
         :private <- Map.get(attrs, :classification),
         {:ok, ordinal} <- KnowledgeValidation.integer(attrs[:ordinal]),
         {:ok, text} <- KnowledgeValidation.string(attrs[:text], 65_536),
         false <- String.contains?(text, "\r"),
         {:ok, locator} <- SourceLocator.new(attrs[:locator]),
         true <- locator.kind != "fragment" or locator.fields.ordinal == ordinal,
         digest = :crypto.hash(:sha256, text),
         fragment_id = id(version_id, locator, ordinal, digest),
         true <- supplied_matches?(attrs, :digest, digest),
         true <- supplied_matches?(attrs, :fragment_id, fragment_id) do
      {:ok,
       %__MODULE__{
         resource_id: resource_id,
         resource_version_id: version_id,
         owner_scope_id: owner_id,
         classification: :private,
         ordinal: ordinal,
         text: text,
         digest: digest,
         locator: locator,
         fragment_id: fragment_id
       }}
    else
      _ -> Types.invalid()
    end
  end

  @spec id(term(), term(), term(), term()) :: String.t() | {:error, Error.t()}
  def id(version_id, locator, ordinal, digest) do
    with {:ok, version_id} <- Types.canonical_uuid(%{version_id: version_id}, :version_id),
         {:ok, locator} <- SourceLocator.new(locator),
         {:ok, ordinal} <- KnowledgeValidation.integer(ordinal),
         true <- is_binary(digest) and byte_size(digest) == 32 do
      encoded =
        Enum.map(
          [version_id, SourceLocator.encode(locator), Integer.to_string(ordinal), digest],
          &KnowledgeEncoding.frame/1
        )

      :crypto.hash(:sha256, ["singularity:document-fragment:v1", <<0>>, encoded])
      |> Base.encode16(case: :lower)
    else
      _ -> Types.invalid()
    end
  end

  defp supplied_matches?(attrs, key, expected),
    do: not Map.has_key?(attrs, key) or attrs[key] === expected
end
