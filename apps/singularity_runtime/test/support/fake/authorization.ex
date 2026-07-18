defmodule Fake.Authorization do
  @moduledoc false

  use Agent

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(options) do
    Agent.start_link(fn ->
      options
      |> Keyword.fetch!(:state)
      |> Map.put_new(:checks, [])
    end)
  end

  @spec revalidate(map(), map()) :: :ok | {:error, :waiting_for_unlock}
  def revalidate(%{authorization: authorization}, binding) when is_map(binding) do
    Agent.get_and_update(authorization, fn state ->
      result = authorize(state, binding)
      {result, %{state | checks: [binding | state.checks]}}
    end)
  end

  @spec log_out(map(), String.t()) :: :ok
  def log_out(context, session_id) do
    set_session_status(context, session_id, :logged_out)
  end

  @spec revoke_session(map(), String.t()) :: :ok
  def revoke_session(context, session_id) do
    set_session_status(context, session_id, :revoked)
  end

  @spec add_session(map(), map()) :: :ok
  def add_session(%{authorization: authorization}, session) do
    Agent.update(authorization, fn state ->
      put_in(state, [:sessions, session.session_id], Map.delete(session, :session_id))
    end)
  end

  @spec revoke_principal(map(), String.t()) :: :ok
  def revoke_principal(%{authorization: authorization}, principal_id) do
    Agent.update(authorization, fn state ->
      put_in(state, [:principals, principal_id], :revoked)
    end)
  end

  @spec replace_capabilities(map(), String.t(), String.t(), [String.t()]) :: :ok
  def replace_capabilities(
        %{authorization: authorization},
        principal_id,
        vault_id,
        capabilities
      ) do
    Agent.update(authorization, fn state ->
      put_in(
        state,
        [:authorizations, {principal_id, vault_id}, :capabilities],
        MapSet.new(capabilities)
      )
    end)
  end

  @spec set_principal_authorization_epoch(
          map(),
          String.t(),
          String.t(),
          non_neg_integer()
        ) :: :ok
  def set_principal_authorization_epoch(
        %{authorization: authorization},
        principal_id,
        vault_id,
        epoch
      )
      when is_integer(epoch) and epoch >= 0 do
    Agent.update(authorization, fn state ->
      put_in(
        state,
        [
          :authorizations,
          {principal_id, vault_id},
          :principal_authorization_epoch
        ],
        epoch
      )
    end)
  end

  @spec set_vault_authorization_epoch(
          map(),
          String.t(),
          String.t(),
          non_neg_integer()
        ) :: :ok
  def set_vault_authorization_epoch(
        %{authorization: authorization},
        principal_id,
        vault_id,
        epoch
      )
      when is_integer(epoch) and epoch >= 0 do
    Agent.update(authorization, fn state ->
      put_in(
        state,
        [
          :authorizations,
          {principal_id, vault_id},
          :vault_authorization_epoch
        ],
        epoch
      )
    end)
  end

  @spec set_object_generation(map(), String.t(), String.t(), pos_integer()) :: :ok
  def set_object_generation(
        %{authorization: authorization},
        vault_id,
        object_id,
        generation
      )
      when is_integer(generation) and generation > 0 do
    Agent.update(authorization, fn state ->
      put_in(state, [:object_generations, {vault_id, object_id}], generation)
    end)
  end

  @spec checks(map()) :: [map()]
  def checks(%{authorization: authorization}) do
    Agent.get(authorization, &Enum.reverse(&1.checks))
  end

  defp set_session_status(%{authorization: authorization}, session_id, status) do
    Agent.update(authorization, fn state ->
      put_in(state, [:sessions, session_id, :status], status)
    end)
  end

  defp authorize(state, binding) do
    principal_id = binding.principal_id
    vault_id = binding.vault_id

    with %{
           status: :active,
           principal_id: ^principal_id,
           vault_id: ^vault_id
         } <- state.sessions[binding.session_id],
         :active <- state.principals[principal_id],
         %{
           principal_authorization_epoch: principal_authorization_epoch,
           vault_authorization_epoch: vault_authorization_epoch,
           capabilities: capabilities
         } <- state.authorizations[{principal_id, vault_id}],
         true <-
           principal_authorization_epoch ==
             binding.principal_authorization_epoch,
         true <-
           vault_authorization_epoch == binding.vault_authorization_epoch,
         true <- MapSet.member?(capabilities, binding.required_capability),
         generation when is_integer(generation) <-
           state.object_generations[{vault_id, binding.object_id}],
         true <- generation == binding.object_generation do
      :ok
    else
      _denied -> {:error, :waiting_for_unlock}
    end
  end
end
