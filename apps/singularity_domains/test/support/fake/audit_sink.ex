defmodule Fake.AuditSink do
  use Agent

  @behaviour Singularity.Core.AuditSink

  def start_link(_opts), do: Agent.start_link(fn -> [] end)

  @impl true
  def append(%{audit: context}, event) do
    Agent.update(context, &[event | &1])
    :ok
  end

  def entries(%{audit: context}), do: Agent.get(context, &Enum.reverse/1)
end
