defmodule Singularity.Core.TestSupport.Fake.Control do
  @moduledoc false

  alias Singularity.Core.Error

  def start_link(initial_data) do
    Agent.start_link(fn -> %{data: initial_data, calls: [], next_error: nil} end)
  end

  def calls(pid), do: Agent.get(pid, & &1.calls)

  def fail_next(pid, %Error{} = error) do
    Agent.update(pid, &%{&1 | next_error: error})
  end

  def run(pid, callback_name, arguments, state_function) do
    Agent.get_and_update(pid, fn state ->
      calls = state.calls ++ [{callback_name, arguments}]

      case state.next_error do
        %Error{} = error ->
          {{:error, error}, %{state | calls: calls, next_error: nil}}

        nil ->
          {result, new_data} = state_function.(state.data)
          {result, %{state | data: new_data, calls: calls}}
      end
    end)
  end
end
