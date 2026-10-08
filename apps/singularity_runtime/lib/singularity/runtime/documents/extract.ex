defmodule Singularity.Runtime.Documents.Extract do
  @moduledoc "Composes bounded, authenticated Document extraction outside SQL transactions."

  alias Singularity.Core.{DocumentCompletion, DocumentFragmentation, Error, JobEnvelope}
  alias Singularity.Storage.Jobs.EnvelopeCodec

  @max_revision 9_223_372_036_854_775_807
  @source_limit 67_108_864
  @unsupported ~w(invalid_utf8 malformed_document encrypted_document no_extractable_text output_too_large)

  @spec run(map(), JobEnvelope.t()) :: {:ok, map()} | {:snooze, 60} | {:error, Error.t()}
  def run(context, %JobEnvelope{job_type: "document_extract"} = envelope)
      when is_map(context) do
    with :ok <- validate_envelope(envelope),
         :ok <- validate_context(context),
         :ok <- authorize(context, envelope),
         {:ok, target} <- call(context.document_worker, :describe, [context, envelope]) do
      run_target(context, envelope, target)
    end
    |> sanitize_result()
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  def run(_, _), do: {:error, Error.new(:invalid)}

  @doc false
  def record_exhaustion(
        context,
        %JobEnvelope{job_type: "document_extract"} = envelope,
        %Error{} = failure,
        metadata
      )
      when is_map(context) do
    with :ok <- validate_envelope(envelope),
         :ok <- validate_context(context),
         :ok <- authorize(context, envelope) do
      call(context.document_worker, :record_exhaustion, [
        context,
        envelope,
        sanitize_error(failure),
        metadata
      ])
    end
    |> sanitize_result()
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  def record_exhaustion(_, _, _, _), do: {:error, Error.new(:invalid)}

  defp run_target(_context, _envelope, {:terminal, receipt}), do: {:ok, receipt}

  defp run_target(context, envelope, {:source, source}) do
    with :ok <- validate_source(source),
         {:ok, extractor, adapter_name, format_version} <- extractor(context, source) do
      case acquire_source(context, envelope, source) do
        {:ok, bytes} ->
          with {:ok, :saved} <-
                 call(context.document_worker, :put_progress_state, [context, envelope, :running]),
               {:ok, attempt} <-
                 call(context.document_worker, :claim, [
                   context,
                   envelope,
                   adapter_name,
                   format_version
                 ]),
               {:ok, completion} <-
                 completion(envelope, source, attempt, extract(extractor, bytes)) do
            call(context.document_worker, :complete, [
              context,
              envelope,
              source,
              attempt,
              completion
            ])
          end

        {:error, %Error{code: :integrity_failure}} = error ->
          error

        failure ->
          source_failure(context, envelope, source, failure)
      end
    end
  end

  defp run_target(_, _, _), do: {:error, Error.new(:integrity_failure)}

  defp source_failure(context, envelope, %{state: :pending}, {:error, :waiting_for_unlock}) do
    with {:ok, :saved} <-
           call(context.document_worker, :put_progress_state, [
             context,
             envelope,
             :waiting_for_unlock
           ]) do
      {:snooze, 60}
    end
  end

  defp source_failure(context, envelope, %{state: :extracting} = source, {:error, _}) do
    attempt =
      Map.take(
        source,
        ~w(resource_id resource_version_id job_id generation state adapter_name format_version started_at deadline_at)a
      )

    with {:ok, completion} <-
           completion(envelope, source, attempt, {:error, {:failed, "extractor_failed"}}) do
      call(context.document_worker, :complete, [context, envelope, source, attempt, completion])
    end
  end

  defp source_failure(_context, _envelope, _source, failure), do: failure

  defp acquire_source(context, envelope, source) do
    request = %{
      purpose: :document_extraction_source,
      access: :worker,
      job_id: envelope.job_id,
      resource_version_id: source.resource_version_id,
      vault_id: envelope.vault_id,
      principal_id: envelope.principal_id,
      required_capability: "asset.read",
      principal_authorization_epoch: envelope.principal_authorization_epoch,
      vault_authorization_epoch: envelope.vault_authorization_epoch,
      object_id: source.object_id,
      object_generation: source.object_generation
    }

    with {:ok, lease} <- call(context.custodian, :lease, [request]) do
      try do
        with {:ok, bytes} <-
               read_source(context.document_source_lease, lease, source.source_byte_size),
             true <- :crypto.hash(:sha256, bytes) === source.source_digest do
          {:ok, bytes}
        else
          false -> {:error, Error.new(:integrity_failure)}
          other -> other
        end
      after
        revoke(context.document_source_lease, lease)
      end
    end
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  defp read_source(adapter, lease, 0) do
    case call(adapter, :authenticate_empty_document_source, [lease]) do
      :ok -> {:ok, ""}
      other -> other
    end
  end

  defp read_source(adapter, lease, size), do: read_chunks(adapter, lease, 0, size, [])

  defp read_chunks(_adapter, _lease, _index, 0, chunks),
    do: {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

  defp read_chunks(adapter, lease, index, remaining, chunks) do
    case call(adapter, :read_document_chunk, [lease, index]) do
      {:ok, bytes}
      when is_binary(bytes) and byte_size(bytes) > 0 and byte_size(bytes) <= remaining ->
        read_chunks(adapter, lease, index + 1, remaining - byte_size(bytes), [bytes | chunks])

      {:error, _} = error ->
        error

      _ ->
        {:error, Error.new(:integrity_failure)}
    end
  end

  defp revoke(adapter, lease) do
    case call(adapter, :revoke, [lease]) do
      :ok -> :ok
      _ -> throw(:document_source_cleanup_failed)
    end
  catch
    :exit, {reason, {GenServer, :call, [^lease, :revoke, :infinity]}}
    when reason in [:noproc, :normal] and is_pid(lease) and node(lease) == node() ->
      :ok
  end

  defp extractor(context, source) do
    case Map.fetch(context.document_extractors, source.media_type) do
      {:ok, {adapter, name, format}}
      when is_binary(name) and is_integer(format) and format > 0 ->
        if source.state == :pending or
             {source.adapter_name, source.format_version} == {name, format} do
          {:ok, adapter, name, format}
        else
          {:error, Error.new(:conflict)}
        end

      _ ->
        {:error, Error.new(:invalid)}
    end
  end

  defp extract(adapter, bytes) do
    call(adapter, :extract, [bytes])
  rescue
    _ -> {:error, {:failed, "extractor_failed"}}
  catch
    _, _ -> {:error, {:failed, "extractor_failed"}}
  end

  defp completion(envelope, source, attempt, extraction) do
    identity = %{
      resource_id: source.resource_id,
      resource_version_id: source.resource_version_id,
      owner_scope_id: envelope.vault_id,
      classification: :private
    }

    attrs =
      Map.merge(identity, %{
        generation: attempt.generation,
        adapter_name: attempt.adapter_name,
        format_version: attempt.format_version,
        finished_at: DateTime.utc_now(),
        media_type: source.media_type
      })

    result =
      with {:ok, blocks} when is_list(blocks) <- extraction,
           {:ok, fragments} <- DocumentFragmentation.build(identity, source.media_type, blocks) do
        {:ready, fragments}
      else
        reason -> outcome(reason)
      end

    case result do
      {:ready, fragments} ->
        DocumentCompletion.new(
          Map.merge(attrs, %{
            outcome: :ready,
            fragments: fragments,
            extracted_text_digest: :crypto.hash(:sha256, Enum.map(fragments, & &1.text))
          })
        )

      {state, code} ->
        DocumentCompletion.new(Map.merge(attrs, %{outcome: state, failure_code: code}))
    end
  rescue
    _ -> failed_completion(envelope, source, attempt)
  catch
    _, _ -> failed_completion(envelope, source, attempt)
  end

  defp failed_completion(envelope, source, attempt) do
    DocumentCompletion.new(%{
      resource_id: source.resource_id,
      resource_version_id: source.resource_version_id,
      owner_scope_id: envelope.vault_id,
      classification: :private,
      generation: attempt.generation,
      adapter_name: attempt.adapter_name,
      format_version: attempt.format_version,
      finished_at: DateTime.utc_now(),
      media_type: source.media_type,
      outcome: :failed,
      failure_code: "extractor_failed"
    })
  end

  defp outcome({:error, {:unsupported, code}}) when code in @unsupported,
    do: {:unsupported, code}

  defp outcome({:error, {:unsupported, "source_too_large"}}),
    do: {:unsupported, "input_too_large"}

  defp outcome({:error, {:unsupported, "page_limit_exceeded"}}), do: {:unsupported, "page_limit"}
  defp outcome({:error, {:failed, "extractor_timeout"}}), do: {:failed, "timeout"}
  defp outcome(_), do: {:failed, "extractor_failed"}

  defp authorize(context, envelope) do
    context.transact.([], fn repo ->
      call(context.authorize, :check_job, [context.authorization, repo, envelope])
    end)
  end

  defp validate_envelope(envelope) do
    with true <- envelope.expected_entity_revision < @max_revision,
         true <- envelope.principal_authorization_epoch <= @max_revision,
         true <- envelope.vault_authorization_epoch <= @max_revision,
         {:ok, encoded} <- EnvelopeCodec.encode(envelope),
         {:ok, ^envelope} <- EnvelopeCodec.decode(encoded) do
      :ok
    else
      _ -> {:error, Error.new(:invalid)}
    end
  end

  defp validate_context(context) do
    required = [
      :document_worker,
      :authorization,
      :authorize,
      :custodian,
      :document_source_lease,
      :document_extractors
    ]

    if Enum.all?(required, &(Map.get(context, &1) not in [nil, false])) and
         is_map(context.document_extractors) and is_function(Map.get(context, :transact), 2),
       do: :ok,
       else: {:error, Error.new(:invalid)}
  end

  defp validate_source(%{source_byte_size: size, source_digest: digest})
       when is_integer(size) and size in 0..@source_limit and
              is_binary(digest) and byte_size(digest) == 32,
       do: :ok

  defp validate_source(_), do: {:error, Error.new(:integrity_failure)}

  defp sanitize_result({:error, %Error{} = error}), do: {:error, sanitize_error(error)}
  defp sanitize_result({:ok, _} = result), do: result
  defp sanitize_result({:snooze, 60} = result), do: result
  defp sanitize_result(_), do: unavailable()

  defp sanitize_error(%Error{code: code, retryable?: retryable?}) do
    if code in Error.codes() and is_boolean(retryable?),
      do: Error.new(code, retryable?: retryable?),
      else: Error.new(:storage_unavailable, retryable?: true)
  end

  defp unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}

  defp call(module, function, arguments) when is_atom(module) and not is_nil(module),
    do: apply(module, function, arguments)

  defp call({module, adapter_context}, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, [adapter_context | arguments])
end
