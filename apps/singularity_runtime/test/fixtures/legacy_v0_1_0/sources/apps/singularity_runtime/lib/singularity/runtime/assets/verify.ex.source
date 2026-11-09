defmodule Singularity.Runtime.Assets.Verify do
  @moduledoc "Verifies sealed ciphertext without requesting plaintext key custody."

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope
  alias Singularity.Runtime.Authorize
  alias Singularity.Runtime.Observability.Telemetry

  @spec run(map(), JobEnvelope.t()) :: {:ok, map()} | {:error, Error.t()}
  def run(context, envelope) do
    Telemetry.span([:asset, :verify], %{}, fn ->
      do_run(context, envelope)
    end)
  end

  defp do_run(context, %JobEnvelope{job_type: "asset_verify"} = envelope)
       when is_map(context) do
    with {:ok, adapters} <- adapters(context),
         {:ok, target} <-
           transact_authorized(adapters, envelope, fn repo ->
             call_adapter(adapters.assets, :prepare_verification, [
               repo,
               envelope
             ])
           end) do
      verify_target(adapters, envelope, target)
    end
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  defp do_run(_context, _envelope), do: {:error, Error.new(:invalid)}

  defp verify_target(_adapters, _envelope, %{
         status: :complete,
         asset: asset
       }),
       do: {:ok, asset}

  defp verify_target(
         adapters,
         envelope,
         %{
           status: :pending,
           stage_id: stage_id,
           stage_ref: stage_ref,
           ciphertext_byte_size: expected_size,
           ciphertext_hash: expected_hash,
           format_envelope: expected_envelope
         }
       ) do
    with {:ok, stat} <-
           call_adapter(adapters.storage, :stat_stage, [stage_ref]),
         :ok <-
           verify_stat(
             stat,
             expected_size,
             expected_hash,
             expected_envelope
           ),
         {:ok, %{asset: asset}} <-
           transact_authorized(adapters, envelope, fn repo ->
             call_adapter(adapters.assets, :record_verified_stage, [
               repo,
               %{
                 envelope: envelope,
                 stage_id: stage_id,
                 sealed?: stat.sealed?,
                 ciphertext_byte_size: stat.byte_size,
                 ciphertext_hash: stat.ciphertext_hash
               }
             ])
           end) do
      {:ok, asset}
    end
  end

  defp verify_target(_adapters, _envelope, _target),
    do: {:error, Error.new(:integrity_failure)}

  defp verify_stat(
         %{
           sealed?: true,
           byte_size: actual_size,
           ciphertext_hash: <<_::binary-size(32)>> = actual_hash
         } = stat,
         expected_size,
         <<_::binary-size(32)>> = expected_hash,
         expected_envelope
       )
       when is_integer(actual_size) and actual_size >= 0 and
              is_integer(expected_size) and expected_size >= 0 do
    if actual_size == expected_size and
         secure_compare(actual_hash, expected_hash) and
         format_envelope_matches?(
           Map.get(stat, :format_envelope),
           expected_envelope
         ),
       do: :ok,
       else: {:error, Error.new(:integrity_failure)}
  end

  defp verify_stat(_stat, _expected_size, _expected_hash, _expected_envelope),
    do: {:error, Error.new(:integrity_failure)}

  defp format_envelope_matches?(observed, expected)
       when is_map(observed) and is_map(expected) do
    Map.take(observed, Map.keys(expected)) == expected
  end

  defp format_envelope_matches?(_observed, _expected), do: false

  defp transact_authorized(adapters, envelope, callback) do
    adapters.transact.([], fn repo ->
      with :ok <-
             call_adapter(adapters.authorize, :check_job, [
               adapters.authorization,
               repo,
               envelope
             ]) do
        callback.(repo)
      end
    end)
  end

  defp adapters(context) do
    assets = Map.get(context, :assets)
    authorization = Map.get(context, :authorization)
    authorize = Map.get(context, :authorize, Authorize)
    storage = Map.get(context, :storage)
    transact = Map.get(context, :transact)

    if assets not in [nil, false] and
         authorization not in [nil, false] and
         authorize not in [nil, false] and
         storage not in [nil, false] and
         is_function(transact, 2) do
      {:ok,
       %{
         assets: assets,
         authorization: authorization,
         authorize: authorize,
         storage: storage,
         transact: transact
       }}
    else
      {:error, Error.new(:invalid)}
    end
  end

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, arguments)
  end

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, [context | arguments])
  end

  defp secure_compare(left, right)
       when is_binary(left) and is_binary(right) and
              byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_compare(_left, _right), do: false
end
