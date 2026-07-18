defmodule Singularity.Runtime.KeyCustodian do
  @moduledoc """
  Session-scoped custody and synchronous revocation of opaque key leases.

  Argon2 work is intentionally excluded from this serialized process.
  """

  use GenServer

  alias Singularity.Core.Error
  alias Singularity.Runtime.KeyLease
  alias Singularity.Runtime.KeyLeaseSupervisor

  @request_fields ~w[
    job_id vault_id principal_id required_capability authorization_epoch
    object_id object_generation session_id
  ]a

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(adapters) do
    GenServer.start_link(__MODULE__, adapters)
  end

  @spec unlock(GenServer.server(), map()) :: :ok | {:error, Error.t()}
  def unlock(server, session), do: GenServer.call(server, {:unlock, session}, :infinity)

  @spec lock(GenServer.server(), String.t()) :: :ok
  def lock(server, session_id), do: GenServer.call(server, {:lock, session_id}, :infinity)

  @spec lease(GenServer.server(), map()) ::
          {:ok, KeyLease.ref()} | {:error, :waiting_for_unlock | Error.t()}
  def lease(server, request), do: GenServer.call(server, {:lease, request})

  @impl true
  def init(%{
        authorization: authorization,
        clock: clock,
        context: context,
        key_reader: key_reader,
        lease_supervisor: lease_supervisor
      }) do
    {:ok,
     %{
       adapters: %{
         authorization: authorization,
         clock: clock,
         key_reader: key_reader
       },
       context: context,
       lease_supervisor: lease_supervisor,
       leases: %{},
       monitors: %{},
       sessions: %{}
     }}
  end

  @impl true
  def handle_call({:unlock, session}, _from, state) do
    case validate_session(session) do
      :ok ->
        state = revoke_session_custody(state, session.session_id)

        sanitized =
          Map.take(session, [:session_id, :vault_id, :vault_key, :domain_key, :object_dek])

        {:reply, :ok, put_in(state, [:sessions, session.session_id], sanitized)}

      {:error, %Error{}} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:lock, session_id}, _from, state) do
    {:reply, :ok, revoke_session_custody(state, session_id)}
  end

  def handle_call({:lease, request}, _from, state) do
    with :ok <- validate_request(request),
         binding = Map.take(request, @request_fields),
         %{vault_id: vault_id, object_dek: object_dek} <-
           Map.get(state.sessions, binding.session_id),
         true <- vault_id == binding.vault_id,
         {:ok, checkpoint} <-
           state.adapters.key_reader.load_checkpoint(state.context, binding),
         {:ok, _next_index} <- KeyLease.validate_checkpoint(checkpoint, binding),
         {:ok, lease} <- start_lease(state, binding, checkpoint, object_dek) do
      monitor = Process.monitor(lease)

      leases =
        Map.update(
          state.leases,
          binding.session_id,
          MapSet.new([lease]),
          &MapSet.put(&1, lease)
        )

      monitors = Map.put(state.monitors, monitor, {binding.session_id, lease})
      {:reply, {:ok, lease}, %{state | leases: leases, monitors: monitors}}
    else
      nil -> {:reply, {:error, :waiting_for_unlock}, state}
      false -> {:reply, {:error, :waiting_for_unlock}, state}
      {:error, %Error{}} = error -> {:reply, error, state}
      {:error, _reason} -> {:reply, {:error, Error.new(:storage_unavailable)}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, lease, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {{session_id, ^lease}, monitors} ->
        session_leases =
          state.leases
          |> Map.get(session_id, MapSet.new())
          |> MapSet.delete(lease)

        leases =
          if MapSet.size(session_leases) == 0 do
            Map.delete(state.leases, session_id)
          else
            Map.put(state.leases, session_id, session_leases)
          end

        {:noreply, %{state | leases: leases, monitors: monitors}}

      {nil, _monitors} ->
        {:noreply, state}
    end
  end

  defp start_lease(state, request, checkpoint, object_dek) do
    KeyLeaseSupervisor.start_lease(state.lease_supervisor, %{
      authorization: state.adapters.authorization,
      binding: request,
      checkpoint: checkpoint,
      clock: state.adapters.clock,
      context: state.context,
      custodian: self(),
      key_material: object_dek,
      key_reader: state.adapters.key_reader
    })
  end

  defp validate_session(%{
         session_id: session_id,
         vault_id: vault_id,
         vault_key: <<_::binary-size(32)>>,
         domain_key: <<_::binary-size(32)>>,
         object_dek: <<_::binary-size(32)>>
       })
       when is_binary(session_id) and byte_size(session_id) > 0 and
              is_binary(vault_id) and byte_size(vault_id) > 0,
       do: :ok

  defp validate_session(_session), do: {:error, Error.new(:invalid)}

  defp validate_request(request) when is_map(request) do
    with true <- Enum.all?(@request_fields, &Map.has_key?(request, &1)),
         true <- nonempty_binary?(request.job_id),
         true <- nonempty_binary?(request.vault_id),
         true <- nonempty_binary?(request.principal_id),
         true <- nonempty_binary?(request.required_capability),
         true <- nonempty_binary?(request.object_id),
         true <- nonempty_binary?(request.session_id),
         true <-
           is_integer(request.authorization_epoch) and request.authorization_epoch >= 0,
         true <- is_integer(request.object_generation) and request.object_generation > 0 do
      :ok
    else
      false -> {:error, Error.new(:invalid)}
    end
  end

  defp validate_request(_request), do: {:error, Error.new(:invalid)}

  defp nonempty_binary?(value),
    do: is_binary(value) and byte_size(String.trim(value)) > 0

  defp best_effort_overwrite(session) do
    for field <- [:vault_key, :domain_key, :object_dek] do
      secret = Map.fetch!(session, field)
      :binary.copy(<<0>>, byte_size(secret))
    end

    :ok
  end

  defp revoke_session_custody(state, session_id) do
    state.leases
    |> Map.get(session_id, MapSet.new())
    |> Enum.each(&safe_revoke/1)

    sessions =
      case Map.pop(state.sessions, session_id) do
        {nil, sessions} ->
          sessions

        {session, sessions} ->
          best_effort_overwrite(session)
          sessions
      end

    %{state | sessions: sessions, leases: Map.delete(state.leases, session_id)}
  end

  defp safe_revoke(lease) do
    monitor = Process.monitor(lease)

    if Process.alive?(lease) do
      try do
        KeyLease.revoke(lease)
      catch
        :exit, _reason -> await_lease_termination(monitor, lease)
      end
    else
      await_lease_termination(monitor, lease)
    end

    Process.demonitor(monitor, [:flush])
    :ok
  end

  defp await_lease_termination(monitor, lease) do
    receive do
      {:DOWN, ^monitor, :process, ^lease, _reason} -> :ok
    end
  end
end
