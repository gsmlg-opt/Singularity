defmodule Singularity.Storage.Jobs.EnvelopeCodec do
  @moduledoc false

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope

  @fields JobEnvelope.required_fields()
  @string_fields Enum.map(@fields, &Atom.to_string/1)
  @asset_jobs %{
    "asset_finalize" => {"asset.write", "asset-finalize"},
    "asset_verify" => {"asset.write", "asset-verify"},
    "asset_metadata" => {"asset.read", "asset-metadata"},
    "asset_cleanup" => {"asset.write", "asset-cleanup"}
  }
  @job_types Map.keys(@asset_jobs) ++ ~w[object_cleanup backup]

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
      "principal_authorization_epoch" => envelope.principal_authorization_epoch,
      "vault_authorization_epoch" => envelope.vault_authorization_epoch,
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
  rescue
    _error -> job_failed()
  catch
    _kind, _reason -> job_failed()
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
         {:ok, %JobEnvelope{} = envelope} <- JobEnvelope.new(attrs),
         true <- safe_envelope?(envelope) do
      {:ok, envelope}
    else
      _invalid -> job_failed()
    end
  rescue
    _error -> job_failed()
  catch
    _kind, _reason -> job_failed()
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

  defp safe_envelope?(%JobEnvelope{} = envelope) do
    Enum.all?(
      [
        envelope.job_id,
        envelope.vault_id,
        envelope.principal_id,
        envelope.correlation_id,
        envelope.causation_id
      ],
      &canonical_uuid?/1
    ) and safe_job_contract?(envelope)
  end

  defp safe_job_contract?(%JobEnvelope{
         job_type: job_type,
         required_capability: capability,
         idempotency_key: idempotency_key,
         expected_entity_revision: revision,
         payload: %{"asset_id" => asset_id} = payload
       })
       when map_size(payload) == 1 and is_map_key(@asset_jobs, job_type) do
    {expected_capability, key_prefix} = Map.fetch!(@asset_jobs, job_type)

    canonical_uuid?(asset_id) and
      ((capability == expected_capability and
          safe_asset_idempotency?(
            job_type,
            idempotency_key,
            key_prefix,
            asset_id,
            revision
          )) or
         legacy_sealed_upload?(
           job_type,
           capability,
           idempotency_key,
           asset_id
         ))
  end

  defp safe_job_contract?(%JobEnvelope{
         job_type: "object_cleanup",
         required_capability: "object.cleanup",
         idempotency_key: idempotency_key,
         principal_authorization_epoch: principal_epoch,
         vault_authorization_epoch: vault_epoch,
         expected_entity_revision: revision,
         payload:
           %{
             "asset_id" => asset_id,
             "object_id" => object_id
           } = payload
       })
       when map_size(payload) == 2 do
    canonical_uuid?(asset_id) and
      canonical_uuid?(object_id) and
      safe_object_cleanup_idempotency?(
        idempotency_key,
        object_id,
        principal_epoch,
        vault_epoch,
        revision
      )
  end

  defp safe_job_contract?(%JobEnvelope{
         job_type: "backup",
         required_capability: "backup.create",
         idempotency_key: idempotency_key,
         payload: %{"pending_manifest_id" => manifest_id} = payload
       })
       when map_size(payload) == 1 do
    canonical_uuid?(manifest_id) and
      idempotency_key == "backup:#{manifest_id}"
  end

  defp safe_job_contract?(_envelope), do: false

  defp safe_asset_idempotency?(job_type, key, prefix, asset_id, revision) do
    key == "#{prefix}:#{asset_id}:#{revision}" or
      (job_type in ["asset_verify", "asset_finalize", "asset_cleanup"] and
         safe_asset_retry_idempotency?(key, asset_id, revision))
  end

  defp legacy_sealed_upload?(
         "asset_verify",
         "assets.verify",
         key,
         asset_id
       ),
       do: key == "sealed-upload:#{asset_id}"

  defp legacy_sealed_upload?(_job_type, _capability, _key, _asset_id), do: false

  defp safe_asset_retry_idempotency?(key, asset_id, revision) do
    case String.split(key, ":") do
      ["asset-retry", ^asset_id, encoded_revision, encoded_attempt] ->
        integer_text?(encoded_revision, revision) and
          positive_integer_text?(encoded_attempt)

      _invalid ->
        false
    end
  end

  defp safe_object_cleanup_idempotency?(
         key,
         object_id,
         principal_epoch,
         vault_epoch,
         revision
       ) do
    key == "object-cleanup:#{object_id}:#{revision}" or
      key ==
        "object-cleanup:#{object_id}:authority:#{principal_epoch}:#{vault_epoch}:revision:#{revision}"
  end

  defp integer_text?(encoded, expected) do
    case Integer.parse(encoded) do
      {^expected, ""} -> true
      _invalid -> false
    end
  end

  defp positive_integer_text?(encoded) do
    case Integer.parse(encoded) do
      {value, ""} when value > 0 -> true
      _invalid -> false
    end
  end

  defp canonical_uuid?(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, ^value} -> true
      _invalid -> false
    end
  end

  defp canonical_uuid?(_value), do: false

  defp job_failed, do: {:error, Error.new(:job_failed)}
end
