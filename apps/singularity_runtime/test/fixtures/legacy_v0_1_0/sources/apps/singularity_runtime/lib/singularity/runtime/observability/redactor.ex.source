defmodule Singularity.Runtime.Observability.Redactor do
  @moduledoc """
  Removes secret values from structured runtime data before it reaches an
  audit, logging, or telemetry boundary.

  Redaction is key based. Callers must still avoid placing secrets in free-form
  strings because an unlabeled binary has no reliable sensitivity signal.
  """

  @behaviour LoggerJSON.Redactor

  @redacted_names ~w[
    password passphrase token csrf audit_fingerprint_secret vault_key
    domain_key domain_dedup_key dek plaintext authorization cookie path key_material
    wrapped_dek object_dek object_key object_keys raw_key wrapping_key recovery_key secret
    mutation_fingerprint_secret title note_title markdown raw_search_query rendered_html export_bytes
  ]
  @redacted_suffixes ~w[
    password passphrase token csrf secret vault_key domain_key dek plaintext
    authorization cookie path key_material object_key object_keys
    title markdown raw_search_query rendered_html export_bytes
  ]
  @replacement "[REDACTED]"

  @spec redact(term()) :: term()
  def redact(term), do: redact_term(term)

  @impl LoggerJSON.Redactor
  def new(options), do: {__MODULE__, options}

  @impl LoggerJSON.Redactor
  def redact(key, value, _options) do
    if sensitive_key?(key), do: @replacement, else: redact_term(value)
  end

  defp redact_term(%DateTime{} = value), do: value
  defp redact_term(%NaiveDateTime{} = value), do: value
  defp redact_term(%Date{} = value), do: value
  defp redact_term(%Time{} = value), do: value

  defp redact_term(%_{} = value) do
    value
    |> Map.from_struct()
    |> redact_term()
  end

  defp redact_term(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      if sensitive_key?(key) do
        {key, @replacement}
      else
        {key, redact_term(nested)}
      end
    end)
  end

  defp redact_term(value) when is_list(value) do
    if Keyword.keyword?(value) do
      Enum.map(value, fn {key, nested} ->
        if sensitive_key?(key) do
          {key, @replacement}
        else
          {key, redact_term(nested)}
        end
      end)
    else
      Enum.map(value, &redact_term/1)
    end
  end

  defp redact_term({key, value}) do
    if sensitive_key?(key) do
      {key, @replacement}
    else
      {redact_term(key), redact_term(value)}
    end
  end

  defp redact_term(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&redact_term/1)
    |> List.to_tuple()
  end

  defp redact_term(value), do: value

  defp sensitive_key?(key) when is_atom(key) or is_binary(key) do
    normalized =
      key
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "_")
      |> String.trim("_")

    normalized in @redacted_names or
      Enum.any?(@redacted_suffixes, &String.ends_with?(normalized, "_#{&1}"))
  end

  defp sensitive_key?(_key), do: false
end
