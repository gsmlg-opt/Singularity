defmodule Singularity.Runtime.Notes.Projection do
  @moduledoc "Reconciles current private note projection under live durable-job authority."

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope

  @spec run(map(), JobEnvelope.t()) :: :ok | {:error, Error.t()}
  def run(context, %JobEnvelope{} = envelope) when is_map(context) do
    with :ok <- validate_envelope(envelope),
         {:ok, values} <- values(context) do
      values.transact.([], fn repo ->
        with :ok <-
               call_adapter(values.authorize, :check_job, [
                 values.authorization,
                 repo,
                 envelope
               ]),
             :ok <-
               call_adapter(values.note_projection, :reconcile, [
                 repo,
                 %{
                   vault_id: envelope.vault_id,
                   resource_id: envelope.payload["resource_id"]
                 }
               ]) do
          :ok
        else
          {:error, %Error{}} = error -> error
          _malformed -> {:error, Error.new(:job_failed)}
        end
      end)
    end
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  catch
    _kind, _reason -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def run(_context, _envelope), do: {:error, Error.new(:job_failed)}

  defp validate_envelope(%JobEnvelope{
         version: 1,
         job_type: "note_projection",
         required_capability: "note.write",
         classification: :private,
         vault_id: vault_id,
         payload: %{"resource_id" => resource_id} = payload
       })
       when map_size(payload) == 1 do
    if canonical_uuid?(vault_id) and canonical_uuid?(resource_id),
      do: :ok,
      else: {:error, Error.new(:job_failed)}
  end

  defp validate_envelope(_envelope), do: {:error, Error.new(:job_failed)}

  defp values(context) do
    values = Map.take(context, [:authorization, :authorize, :note_projection, :transact])

    if Map.keys(values) |> MapSet.new() ==
         MapSet.new([:authorization, :authorize, :note_projection, :transact]) and
         Enum.all?(
           Map.take(values, [:authorization, :authorize, :note_projection]) |> Map.values(),
           &(&1 not in [nil, false])
         ) and is_function(values.transact, 2) do
      {:ok, values}
    else
      {:error, Error.new(:invalid)}
    end
  end

  defp canonical_uuid?(value), do: Ecto.UUID.cast(value) == {:ok, value}

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, arguments)

  defp call_adapter({module, adapter_context}, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, [adapter_context | arguments])
end
