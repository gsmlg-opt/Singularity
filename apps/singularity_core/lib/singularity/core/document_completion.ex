defmodule Singularity.Core.DocumentCompletion do
  @moduledoc "Validated immutable extraction outcome, without lifecycle orchestration."
  alias Singularity.Core.{DocumentFragment, Error, KnowledgeValidation, Types}

  @enforce_keys [
    :resource_id,
    :resource_version_id,
    :owner_scope_id,
    :classification,
    :generation,
    :outcome,
    :adapter_name,
    :format_version,
    :finished_at,
    :media_type
  ]
  @optional [:fragments, :extracted_text_digest, :detected_language, :failure_code]
  defstruct @enforce_keys ++ @optional

  @type t :: %__MODULE__{
          resource_id: Types.id(),
          resource_version_id: Types.id(),
          owner_scope_id: Types.id(),
          classification: :private,
          generation: pos_integer(),
          outcome: :ready | :failed | :unsupported,
          adapter_name: String.t(),
          format_version: pos_integer(),
          finished_at: DateTime.t(),
          media_type: String.t(),
          fragments: [DocumentFragment.t()] | nil,
          extracted_text_digest: binary() | nil,
          detected_language: String.t() | nil,
          failure_code: String.t() | nil
        }
  @codes ~w(invalid_utf8 malformed_document encrypted_document no_extractable_text input_too_large output_too_large page_limit timeout extractor_failed)

  @spec new(term()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = input), do: new(Map.from_struct(input))

  def new(input) do
    with {:ok, attrs} <- KnowledgeValidation.attrs(input, @enforce_keys ++ @optional),
         true <-
           Enum.all?(
             [:resource_id, :resource_version_id, :owner_scope_id],
             &match?({:ok, _}, Types.canonical_uuid(attrs, &1))
           ),
         :private <- attrs[:classification],
         {:ok, _} <- KnowledgeValidation.integer(attrs[:generation], 1),
         {:ok, adapter} <- KnowledgeValidation.bounded_name(attrs[:adapter_name]),
         {:ok, _} <- KnowledgeValidation.integer(attrs[:format_version], 1),
         true <- attrs.format_version <= 2_147_483_647,
         {:ok, _} <- KnowledgeValidation.utc_datetime(attrs, :finished_at),
         true <- attrs[:media_type] in ["application/pdf", "text/markdown", "text/plain"],
         true <-
           is_nil(attrs[:detected_language]) or
             (match?({:ok, _}, KnowledgeValidation.string(attrs[:detected_language], 255)) and
                String.trim(attrs[:detected_language]) != ""),
         {:ok, attrs} <- outcome(attrs) do
      {:ok, struct!(__MODULE__, Map.put(attrs, :adapter_name, adapter))}
    else
      _ -> Types.invalid()
    end
  end

  defp outcome(%{outcome: :ready} = attrs) do
    with nil <- attrs[:failure_code],
         fragments when is_list(fragments) and length(fragments) in 1..4096 <- attrs[:fragments],
         {:ok, fragments, bytes} <- fragments(fragments, attrs),
         true <- bytes > 0,
         digest = :crypto.hash(:sha256, Enum.map(fragments, & &1.text)),
         true <- attrs[:extracted_text_digest] === digest do
      {:ok, Map.put(attrs, :fragments, fragments)}
    else
      _ -> Types.invalid()
    end
  end

  defp outcome(%{outcome: outcome} = attrs) when outcome in [:failed, :unsupported] do
    if attrs[:failure_code] in @codes and is_nil(attrs[:fragments]) and
         is_nil(attrs[:extracted_text_digest]) and is_nil(attrs[:detected_language]),
       do: {:ok, attrs},
       else: Types.invalid()
  end

  defp outcome(_), do: Types.invalid()

  defp fragments(fragments, attrs) do
    kind =
      %{"application/pdf" => "pdf", "text/markdown" => "markdown", "text/plain" => "text"}[
        attrs.media_type
      ]

    fragments
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], 0}, fn {input, ordinal}, {:ok, acc, bytes} ->
      with {:ok, fragment} <- DocumentFragment.new(input),
           true <-
             Enum.all?(
               [:resource_id, :resource_version_id, :owner_scope_id, :classification],
               &(Map.fetch!(fragment, &1) === Map.fetch!(attrs, &1))
             ),
           true <- fragment.ordinal == ordinal and fragment.locator.kind in [kind, "fragment"],
           total = bytes + byte_size(fragment.text),
           true <- total <= 16_777_216 do
        {:cont, {:ok, [fragment | acc], total}}
      else
        _ -> {:halt, Types.invalid()}
      end
    end)
    |> case do
      {:ok, values, bytes} -> {:ok, Enum.reverse(values), bytes}
      error -> error
    end
  end
end
