defmodule Fake.RotationRepository do
  @moduledoc false

  use Agent

  def start_link(options) do
    Agent.start_link(fn ->
      %{
        active: %{id: "generation-1", generation: 1, state: :active},
        calls: [],
        failure_at: Keyword.get(options, :failure_at),
        pending: nil
      }
    end)
  end

  def create_pending_generation(%{repository: repository, rotation: rotation}) do
    Agent.get_and_update(repository, fn state ->
      state = record(state, :create_pending)

      if state.failure_at == :create_pending do
        {{:error, :create_pending_failed}, state}
      else
        pending = %{
          id: "#{rotation}-generation-2",
          generation: 2,
          rotation: rotation,
          state: :pending
        }

        {{:ok, pending}, %{state | pending: pending}}
      end
    end)
  end

  def rewrap_all_children(%{repository: repository}, pending) do
    Agent.get_and_update(repository, fn state ->
      state = record(state, :rewrap)

      if state.failure_at == :rewrap do
        {{:error, :rewrap_failed}, state}
      else
        wrappers = [
          %{child_id: "child-1", generation_id: pending.id},
          %{child_id: "child-2", generation_id: pending.id}
        ]

        {{:ok, wrappers}, state}
      end
    end)
  end

  def verify_all_wrappers(%{repository: repository}, wrappers) do
    Agent.get_and_update(repository, fn state ->
      state = record(state, :verify)

      if state.failure_at == :verify do
        {{:error, :verify_failed}, state}
      else
        {if(length(wrappers) == 2, do: :ok, else: {:error, :incomplete_wrappers}), state}
      end
    end)
  end

  def activate_generation(%{repository: repository}, pending_id) do
    Agent.get_and_update(repository, fn state ->
      state = record(state, :activate)

      if state.failure_at == :activate do
        {{:error, :activate_failed}, state}
      else
        active = %{state.pending | id: pending_id, state: :active}
        {{:ok, active}, %{state | active: active, pending: nil}}
      end
    end)
  end

  def abandon_pending_generation(%{repository: repository}) do
    Agent.update(repository, fn state ->
      pending =
        case state.pending do
          nil -> nil
          pending -> %{pending | state: :abandoned}
        end

      state
      |> record(:abandon)
      |> Map.put(:pending, pending)
    end)

    :ok
  end

  def state(repository), do: Agent.get(repository, & &1)

  defp record(state, call), do: %{state | calls: state.calls ++ [call]}
end

defmodule Singularity.Runtime.KeyRotationTest do
  use ExUnit.Case, async: true

  alias Singularity.Runtime.RotateDomainKey
  alias Singularity.Runtime.RotateVaultKey

  @rotation_modules [
    {:vault, RotateVaultKey},
    {:domain, RotateDomainKey}
  ]

  for {rotation, module} <- @rotation_modules do
    @rotation rotation
    @module module

    test "#{rotation} rotation verifies every child wrapper before activating" do
      repository = start_repository!()
      context = rotation_context(repository, @rotation)

      assert {:ok, %{generation: 2, state: :active}} =
               @module.rotate(%{repository: Fake.RotationRepository}, context)

      assert %{
               active: %{generation: 2, state: :active},
               calls: [:create_pending, :rewrap, :verify, :activate],
               pending: nil
             } = Fake.RotationRepository.state(repository)
    end

    test "#{rotation} rotation abandons every partial failure and leaves the old generation active" do
      for failure_at <- [:create_pending, :rewrap, :verify, :activate] do
        repository = start_repository!(failure_at)
        context = rotation_context(repository, @rotation)
        expected = expected_error(failure_at)

        assert {:error, ^expected} =
                 @module.rotate(%{repository: Fake.RotationRepository}, context)

        state = Fake.RotationRepository.state(repository)

        assert %{id: "generation-1", generation: 1, state: :active} = state.active
        assert List.last(state.calls) == :abandon

        case failure_at do
          :create_pending ->
            refute :rewrap in state.calls
            refute :verify in state.calls
            refute :activate in state.calls

          :rewrap ->
            refute :verify in state.calls
            refute :activate in state.calls

          :verify ->
            refute :activate in state.calls

          :activate ->
            assert :activate in state.calls
        end

        if state.pending do
          assert state.pending.state == :abandoned
        end
      end
    end
  end

  defp start_repository!(failure_at \\ nil) do
    child_spec =
      Supervisor.child_spec(
        {Fake.RotationRepository, failure_at: failure_at},
        id: make_ref()
      )

    start_supervised!(child_spec)
  end

  defp rotation_context(repository, rotation) do
    %{
      repository: repository,
      rotation: rotation,
      vault_id: "vault-1",
      key_domain_id: "domain-1"
    }
  end

  defp expected_error(:create_pending), do: :create_pending_failed
  defp expected_error(:rewrap), do: :rewrap_failed
  defp expected_error(:verify), do: :verify_failed
  defp expected_error(:activate), do: :activate_failed
end
