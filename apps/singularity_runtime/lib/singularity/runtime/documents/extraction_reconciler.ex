defmodule Singularity.Runtime.Documents.ExtractionReconciler do
  @moduledoc "Recovers expired Document extraction attempts without reading source bytes."
  use GenServer

  alias Singularity.Core.Error
  alias Singularity.Storage.Postgres.DocumentRepository
  alias Singularity.Storage.WorkerRepo

  @interval_ms 30_000
  @batch_size 100

  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @impl true
  def init(options) do
    context = Keyword.get(options, :context, %{repo: WorkerRepo})
    send(self(), :reconcile)
    {:ok, context}
  end

  @impl true
  def handle_info(:reconcile, context) do
    _result = run(context)
    Process.send_after(self(), :reconcile, @interval_ms)
    {:noreply, context}
  end

  @spec run(map()) :: {:ok, non_neg_integer()} | {:error, Error.t()}
  def run(%{repo: _} = context) do
    with {:ok, ids} <- DocumentRepository.list_expired_recovery_ids(context, @batch_size) do
      Enum.reduce_while(ids, {:ok, 0}, fn {version, owner}, {:ok, count} ->
        case DocumentRepository.recover_expired_with_event(context, version, owner) do
          {:ok, true} -> {:cont, {:ok, count + 1}}
          {:ok, false} -> {:cont, {:ok, count}}
          {:error, %Error{} = reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  def run(_), do: {:error, Error.new(:invalid)}
end
