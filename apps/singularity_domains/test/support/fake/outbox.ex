defmodule Fake.Outbox do
  use Agent

  @behaviour Singularity.Core.Outbox

  def start_link(_opts), do: Agent.start_link(fn -> [] end)

  @impl true
  def append(%{outbox: context}, event) do
    Agent.update(context, &[event | &1])
    {:ok, event}
  end

  @impl true
  def claim(_context, _options), do: {:ok, []}

  @impl true
  def acknowledge(_context, _event_id, _options), do: :ok

  def entries(%{outbox: context}), do: Agent.get(context, &Enum.reverse/1)
end
