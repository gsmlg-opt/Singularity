defmodule Singularity.Runtime.Assets.ExtractMetadata do
  @moduledoc "Runs resumable technical metadata extraction through trusted key custody."

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope
  alias Singularity.Runtime.Authorize

  @contention_snooze_seconds 1
  @snooze_seconds 60

  @spec run(map(), JobEnvelope.t()) ::
          {:ok, map()} | {:snooze, pos_integer()} | {:error, Error.t()}
  def run(context, %JobEnvelope{job_type: "asset_metadata"} = envelope)
      when is_map(context) do
    with {:ok, adapters} <- adapters(context),
         {:ok, target} <-
           transact_authorized(adapters, envelope, fn repo ->
             call_adapter(adapters.assets, :begin_or_resume_processing, [
               repo,
               envelope
             ])
           end) do
      run_target(adapters, envelope, target)
    end
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  catch
    _kind, _reason -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def run(_context, _envelope), do: {:error, Error.new(:invalid)}

  defp run_target(_adapters, _envelope, %{
         status: :complete,
         asset: asset,
         effect_result: effect_result
       })
       when effect_result in [:applied, :stale, :failed],
       do: {:ok, asset}

  defp run_target(
         adapters,
         envelope,
         %{
           status: :pending,
           processing_revision: processing_revision,
           checkpoint: _checkpoint,
           object_id: object_id,
           object_generation: object_generation,
           declared_media_type: declared_media_type,
           plaintext_byte_size: plaintext_byte_size
         }
       ) do
    target = %{
      object_id: object_id,
      object_generation: object_generation,
      declared_media_type: declared_media_type,
      plaintext_byte_size: plaintext_byte_size
    }

    request = %{
      purpose: :metadata,
      job_id: envelope.job_id,
      vault_id: envelope.vault_id,
      principal_id: envelope.principal_id,
      required_capability: envelope.required_capability,
      principal_authorization_epoch: envelope.principal_authorization_epoch,
      vault_authorization_epoch: envelope.vault_authorization_epoch,
      object_id: object_id,
      object_generation: object_generation,
      processing_revision: processing_revision,
      declared_media_type: declared_media_type,
      plaintext_byte_size: plaintext_byte_size
    }

    case call_adapter(adapters.custodian, :lease, [request]) do
      {:ok, lease} ->
        extract_steps(
          adapters,
          envelope,
          processing_revision,
          target,
          lease
        )

      {:error, :waiting_for_unlock} ->
        wait_for_unlock(adapters, envelope, processing_revision, target)

      {:error, %Error{}} = error ->
        error

      _invalid ->
        {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  defp run_target(_adapters, _envelope, _target),
    do: {:error, Error.new(:integrity_failure)}

  defp extract_steps(
         adapters,
         envelope,
         processing_revision,
         target,
         lease
       ) do
    case call_adapter(adapters.key_lease, :metadata_step, [lease]) do
      {:continue, next_checkpoint} when is_map(next_checkpoint) ->
        extract_steps(
          adapters,
          envelope,
          processing_revision,
          target,
          lease
        )

      {:done, metadata, final_checkpoint}
      when is_map(metadata) and is_map(final_checkpoint) ->
        with {:ok, %{asset: asset}} <-
               transact_authorized(adapters, envelope, fn repo ->
                 call_adapter(adapters.assets, :complete_metadata, [
                   repo,
                   envelope,
                   processing_revision,
                   metadata,
                   final_checkpoint
                 ])
               end) do
          {:ok, asset}
        end

      {:error, :waiting_for_unlock} ->
        wait_for_unlock(adapters, envelope, processing_revision, target)

      {:retry, :checkpoint_advanced} ->
        {:snooze, @contention_snooze_seconds}

      {:error, %Error{retryable?: false} = failure, final_checkpoint}
      when is_map(final_checkpoint) ->
        with {:ok, %{asset: asset}} <-
               transact_authorized(adapters, envelope, fn repo ->
                 call_adapter(adapters.assets, :record_metadata_failure, [
                   repo,
                   envelope,
                   processing_revision,
                   failure,
                   final_checkpoint
                 ])
               end) do
          {:ok, asset}
        end

      {:error, %Error{}} = error ->
        error

      _invalid ->
        {:error, Error.new(:integrity_failure)}
    end
  end

  defp wait_for_unlock(
         adapters,
         envelope,
         processing_revision,
         target
       ) do
    case transact_authorized(adapters, envelope, fn repo ->
           call_adapter(adapters.job_progress, :wait_metadata_for_unlock, [
             repo,
             envelope,
             processing_revision,
             target
           ])
         end) do
      {:ok, _progress} -> {:snooze, @snooze_seconds}
      {:error, %Error{}} = error -> error
      _invalid -> {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

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
    adapters = %{
      assets: Map.get(context, :assets),
      authorization: Map.get(context, :authorization),
      authorize: Map.get(context, :authorize, Authorize),
      custodian: Map.get(context, :custodian),
      job_progress: Map.get(context, :job_progress),
      key_lease: Map.get(context, :key_lease),
      transact: Map.get(context, :transact)
    }

    if Enum.all?(
         Map.take(adapters, [
           :assets,
           :authorization,
           :authorize,
           :custodian,
           :job_progress,
           :key_lease
         ]),
         fn {_key, value} -> value not in [nil, false] end
       ) and is_function(adapters.transact, 2) do
      {:ok, adapters}
    else
      {:error, Error.new(:invalid)}
    end
  end

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, arguments)

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, [context | arguments])
end
