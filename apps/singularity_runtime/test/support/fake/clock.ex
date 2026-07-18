defmodule Fake.Clock do
  @moduledoc false

  use Agent

  @behaviour Singularity.Core.Clock

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(options) do
    Agent.start_link(fn -> Keyword.fetch!(options, :now) end)
  end

  @impl true
  def utc_now(%{clock: clock}) do
    Agent.get(clock, & &1)
  end

  @spec advance(map(), integer()) :: :ok
  def advance(%{clock: clock}, seconds) when is_integer(seconds) do
    Agent.update(clock, &DateTime.add(&1, seconds, :second))
  end
end
