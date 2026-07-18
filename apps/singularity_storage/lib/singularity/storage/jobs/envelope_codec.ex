defmodule Singularity.Storage.Jobs.EnvelopeCodec do
  @moduledoc false

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope

  @fields JobEnvelope.required_fields()
  @string_fields Enum.map(@fields, &Atom.to_string/1)
  @job_types ~w[
    asset_finalize
    asset_verify
    asset_metadata
    asset_cleanup
    object_cleanup
    backup
    maintenance
    integrity_audit
  ]

  @spec encode(JobEnvelope.t()) :: {:ok, map()} | {:error, Error.t()}
  def encode(%JobEnvelope{} = envelope) do
    encoded = %{
      "version" => envelope.version,
      "job_id" => envelope.job_id,
      "job_type" => envelope.job_type,
      "idempotency_key" => envelope.idempotency_key,
      "vault_id" => envelope.vault_id,
      "principal_id" => envelope.principal_id,
      "required_capability" => envelope.required_capability,
      "authorization_epoch" => envelope.authorization_epoch,
      "classification" => Atom.to_string(envelope.classification),
      "correlation_id" => envelope.correlation_id,
      "causation_id" => envelope.causation_id,
      "expected_entity_revision" => envelope.expected_entity_revision,
      "attempt" => envelope.attempt,
      "payload" => envelope.payload
    }

    case decode(encoded) do
      {:ok, ^envelope} -> {:ok, encoded}
      _error -> job_failed()
    end
  end

  def encode(_envelope), do: job_failed()

  @spec decode(map()) :: {:ok, JobEnvelope.t()} | {:error, Error.t()}
  def decode(encoded) when is_map(encoded) do
    with true <- Enum.sort(Map.keys(encoded)) == Enum.sort(@string_fields),
         1 <- Map.fetch!(encoded, "version"),
         job_type when job_type in @job_types <- Map.fetch!(encoded, "job_type"),
         {:ok, classification} <- classification(Map.fetch!(encoded, "classification")),
         true <- json_value?(encoded),
         attrs =
           @fields
           |> Map.new(fn field -> {field, Map.fetch!(encoded, Atom.to_string(field))} end)
           |> Map.put(:classification, classification),
         {:ok, %JobEnvelope{} = envelope} <- JobEnvelope.new(attrs) do
      {:ok, envelope}
    else
      _invalid -> job_failed()
    end
  end

  def decode(_encoded), do: job_failed()

  @spec known_job_type?(String.t()) :: boolean()
  def known_job_type?(job_type), do: job_type in @job_types

  defp classification("private"), do: {:ok, :private}
  defp classification("sensitive"), do: {:ok, :sensitive}
  defp classification("restricted"), do: {:ok, :restricted}
  defp classification(_classification), do: :error

  defp json_value?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> is_binary(key) and json_value?(nested) end)
  end

  defp json_value?(value) when is_list(value), do: Enum.all?(value, &json_value?/1)
  defp json_value?(value) when is_binary(value) or is_number(value), do: true
  defp json_value?(value) when is_boolean(value) or is_nil(value), do: true
  defp json_value?(_value), do: false

  defp job_failed, do: {:error, Error.new(:job_failed)}
end
