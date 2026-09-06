defmodule Singularity.Core.Tag do
  @moduledoc "Private tag spelling and its canonical Unicode casefold key."
  alias Singularity.Core.{Error, KnowledgeValidation, Types}
  @enforce_keys [:tag_id, :owner_scope_id, :classification, :display_value, :normalized_key]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          tag_id: Types.id(),
          owner_scope_id: Types.id(),
          classification: :private,
          display_value: String.t(),
          normalized_key: String.t()
        }
  @spec new(term()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = input), do: new(Map.from_struct(input))

  def new(input) do
    with {:ok, attrs} <- KnowledgeValidation.attrs(input, @enforce_keys),
         {:ok, _} <- Types.canonical_uuid(attrs, :tag_id),
         {:ok, _} <- Types.canonical_uuid(attrs, :owner_scope_id),
         :private <- attrs[:classification],
         raw when is_binary(raw) <- attrs[:display_value],
         true <- String.valid?(raw),
         false <- Regex.match?(~r/\p{Cc}/u, raw),
         display = raw |> String.trim() |> String.normalize(:nfc),
         {:ok, display} <- KnowledgeValidation.string(display, 255),
         true <- display != "",
         key = display |> :string.casefold() |> IO.chardata_to_string() |> String.normalize(:nfc),
         {:ok, key} <- KnowledgeValidation.string(key, 1024),
         true <- not Map.has_key?(attrs, :normalized_key) or attrs.normalized_key === key do
      {:ok, struct(__MODULE__, Map.merge(attrs, %{display_value: display, normalized_key: key}))}
    else
      _ -> Types.invalid()
    end
  end
end
