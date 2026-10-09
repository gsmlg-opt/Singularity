defmodule Singularity.Runtime.Documents.Projection do
  @moduledoc "Reconciles current Document search entries under live retained-job authority."

  alias Singularity.Core.{Error, JobEnvelope}
  alias Singularity.Storage.Jobs.EnvelopeCodec

  @spec run(map(), JobEnvelope.t()) :: :ok | {:error, Error.t()}
  def run(context, %JobEnvelope{job_type: "document_projection"} = envelope)
      when is_map(context) do
    with {:ok, _encoded} <- EnvelopeCodec.encode(envelope),
         {:ok, values} <- values(context) do
      values.transact.([], fn repo ->
        with :ok <-
               call_adapter(values.authorize, :check_job, [values.authorization, repo, envelope]),
             {:ok, count} when is_integer(count) and count >= 0 <-
               call_adapter(values.document_projection, :reconcile_document, [repo, envelope]) do
          :ok
        else
          {:error, %Error{}} = error -> sanitize(error)
          _ -> {:error, Error.new(:job_failed)}
        end
      end)
      |> sanitize()
    end
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  def run(_context, _envelope), do: {:error, Error.new(:job_failed)}

  defp values(context) do
    keys = [:authorization, :authorize, :document_projection, :transact]
    values = Map.take(context, keys)

    if map_size(values) == length(keys) and is_function(values.transact, 2) and
         Enum.all?(
           Map.take(values, [:authorization, :authorize, :document_projection]),
           fn {_key, value} -> value not in [nil, false] end
         ) do
      {:ok, values}
    else
      {:error, Error.new(:invalid)}
    end
  end

  defp sanitize(:ok), do: :ok

  defp sanitize({:error, %Error{code: code, retryable?: retryable}}),
    do: {:error, Error.new(code, retryable?: retryable)}

  defp sanitize(_), do: {:error, Error.new(:job_failed)}
  defp unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}

  defp call_adapter(module, function, arguments) when is_atom(module) and not is_nil(module),
    do: apply(module, function, arguments)

  defp call_adapter({module, adapter_context}, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, [adapter_context | arguments])
end
