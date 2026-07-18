defmodule Fake.IdentityRepository do
  @behaviour Singularity.Domains.Identity.Repository

  def start_link do
    Agent.start_link(fn ->
      %{bootstraps_by_key: %{}, bootstraps_by_owner: %{}}
    end)
  end

  @impl true
  def bootstrap_owner(context, command) do
    Agent.get_and_update(context, fn state ->
      case lookup_bootstrap(state, command) do
        nil ->
          bootstrap = %{owner: command.owner, credential: command.credential}

          state =
            state
            |> put_in([:bootstraps_by_key, command.idempotency_key], bootstrap)
            |> put_in([:bootstraps_by_owner, command.owner.id], bootstrap)

          {{:ok, bootstrap}, state}

        bootstrap ->
          state =
            put_in(
              state,
              [:bootstraps_by_key, command.idempotency_key],
              bootstrap
            )

          {{:ok, bootstrap}, state}
      end
    end)
  end

  defp lookup_bootstrap(state, command) do
    state.bootstraps_by_key[command.idempotency_key] ||
      state.bootstraps_by_owner[command.owner.id]
  end
end
