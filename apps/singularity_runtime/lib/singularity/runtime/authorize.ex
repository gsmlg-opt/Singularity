defmodule Singularity.Runtime.Authorize do
  @moduledoc """
  Reloads live authority at the point of use.

  Session and job values are treated only as binding hints. Membership,
  revocation, capability, classification, epoch, and custody are always read
  from the injected authoritative adapters.
  """

  alias Singularity.Core.Error
  alias Singularity.Runtime.AuthorizationDependencies

  @classification_rank %{private: 0, sensitive: 1, restricted: 2}
  @system_jobs %{
    "maintenance" => "maintenance.run",
    "integrity_audit" => "integrity.audit"
  }

  @spec check(AuthorizationDependencies.t(), term(), map(), map()) ::
          :ok | {:error, Error.t()}
  def check(
        %AuthorizationDependencies{} = dependencies,
        repo,
        %{session_id: session_id} = session,
        requirement
      )
      when is_binary(session_id) and is_map(requirement) do
    with {:ok, live} <- load_session(dependencies.store, repo, session_id),
         :ok <- check_authenticated(live),
         :ok <- check_session_binding(live, session),
         :ok <- check_authority(live, session, requirement),
         :ok <- check_unlock(dependencies.custodian, live, requirement) do
      :ok
    end
  rescue
    _error -> forbidden()
  end

  def check(_dependencies, _repo, _session, _requirement), do: forbidden()

  @spec check_job(AuthorizationDependencies.t(), term(), map()) ::
          :ok | {:error, Error.t()}
  def check_job(
        %AuthorizationDependencies{} = dependencies,
        repo,
        %{
          principal_id: principal_id,
          vault_id: vault_id,
          principal_authorization_epoch: principal_authorization_epoch,
          vault_authorization_epoch: vault_authorization_epoch
        } = envelope
      )
      when is_binary(principal_id) and is_binary(vault_id) and
             is_integer(principal_authorization_epoch) and
             is_integer(vault_authorization_epoch) do
    with {:ok, live} <-
           load_principal(dependencies.store, repo, principal_id, vault_id),
         :ok <- check_live_principal(live),
         :ok <- check_job_binding(live, envelope),
         :ok <- check_job_principal_kind(live, envelope),
         :ok <- check_capability(live, envelope),
         :ok <- check_classification(live, envelope) do
      :ok
    end
  rescue
    _error -> forbidden()
  end

  def check_job(_dependencies, _repo, _envelope), do: forbidden()

  defp load_session(store, repo, session_id) do
    case call_adapter(store, :load_live_session, [repo, session_id]) do
      {:ok, nil} -> unauthenticated()
      {:ok, live} when is_map(live) -> {:ok, live}
      {:error, %Error{}} = error -> error
      _invalid -> forbidden()
    end
  end

  defp load_principal(store, repo, principal_id, vault_id) do
    case call_adapter(store, :load_live_principal, [repo, principal_id, vault_id]) do
      {:ok, nil} -> forbidden()
      {:ok, live} when is_map(live) -> {:ok, live}
      {:error, %Error{}} = error -> error
      _invalid -> forbidden()
    end
  end

  defp check_authenticated(live) do
    expires_at = Map.get(live, :session_expires_at, Map.get(live, :expires_at))

    cond do
      present?(live, :session_revoked_at) ->
        unauthenticated()

      not match?(%DateTime{}, expires_at) ->
        unauthenticated()

      DateTime.compare(expires_at, DateTime.utc_now()) != :gt ->
        unauthenticated()

      true ->
        :ok
    end
  end

  defp check_session_binding(live, session) do
    if live[:session_id] == session.session_id and
         live[:principal_id] == session.principal_id and
         live[:vault_id] == session.vault_id do
      :ok
    else
      forbidden()
    end
  end

  defp check_authority(live, session, requirement) do
    with :ok <- check_live_principal(live),
         :ok <- check_requirement_binding(live, session, requirement),
         :ok <- check_capability(live, requirement),
         :ok <- check_classification(live, requirement) do
      :ok
    end
  end

  defp check_live_principal(live) do
    if present?(live, :principal_revoked_at) or
         present?(live, :membership_revoked_at) do
      forbidden()
    else
      :ok
    end
  end

  defp check_job_binding(live, envelope) do
    with true <- live[:principal_id] == envelope.principal_id,
         true <- live[:vault_id] == envelope.vault_id,
         :ok <-
           check_principal_epoch(
             live,
             envelope.principal_authorization_epoch
           ),
         :ok <-
           check_vault_epoch(
             live,
             envelope.vault_authorization_epoch
           ) do
      :ok
    else
      _denial -> forbidden()
    end
  end

  defp check_requirement_binding(live, session, requirement) do
    principal_epoch = session_principal_epoch(session)
    vault_epoch = Map.get(session, :vault_authorization_epoch)

    with true <- Map.get(requirement, :vault_id) == session.vault_id,
         true <-
           Map.get(requirement, :principal_authorization_epoch) ==
             principal_epoch,
         true <-
           Map.get(requirement, :vault_authorization_epoch) == vault_epoch,
         :ok <- check_principal_epoch(live, principal_epoch),
         :ok <- check_vault_epoch(live, vault_epoch) do
      :ok
    else
      _denial -> forbidden()
    end
  end

  defp check_principal_epoch(live, expected_epoch) do
    live_epoch =
      Map.get(
        live,
        :principal_authorization_epoch,
        Map.get(live, :authorization_epoch)
      )

    if is_integer(live_epoch) and live_epoch >= 0 and live_epoch == expected_epoch do
      :ok
    else
      forbidden()
    end
  end

  defp check_vault_epoch(live, expected_epoch) do
    live_epoch = live[:vault_authorization_epoch]

    if is_integer(live_epoch) and live_epoch >= 0 and live_epoch == expected_epoch do
      :ok
    else
      forbidden()
    end
  end

  defp check_job_principal_kind(live, %{job_type: job_type} = envelope)
       when is_binary(job_type) do
    case Map.fetch(@system_jobs, job_type) do
      {:ok, exact_capability} ->
        if live[:principal_kind] == :system and
             Map.get(envelope, :required_capability) == exact_capability do
          :ok
        else
          forbidden()
        end

      :error ->
        if live[:principal_kind] == :system do
          forbidden()
        else
          :ok
        end
    end
  end

  defp check_job_principal_kind(live, _envelope) do
    if live[:principal_kind] == :system, do: forbidden(), else: :ok
  end

  defp session_principal_epoch(%{
         principal_authorization_epoch: epoch
       })
       when is_integer(epoch),
       do: epoch

  defp session_principal_epoch(session), do: Map.get(session, :authorization_epoch)

  defp check_capability(live, requirement) do
    required =
      Map.get(
        requirement,
        :required_capability,
        Map.get(requirement, :capability)
      )

    capabilities = Map.get(live, :capabilities)

    if nonempty_binary?(required) and is_list(capabilities) and required in capabilities do
      :ok
    else
      forbidden()
    end
  end

  defp check_classification(live, requirement) do
    with {:ok, clearance} <- classification(live[:clearance]),
         {:ok, required} <- classification(Map.get(requirement, :classification)),
         true <-
           Map.fetch!(@classification_rank, clearance) >=
             Map.fetch!(@classification_rank, required) do
      :ok
    else
      _denial -> forbidden()
    end
  end

  defp check_unlock(_custodian, _live, %{requires_unlocked?: false}), do: :ok

  defp check_unlock(custodian, live, _requirement) do
    if live[:vault_locked] == false do
      case call_adapter(
             custodian,
             :assert_unlocked,
             [live.session_id, live.principal_id, live.vault_id]
           ) do
        :ok -> :ok
        true -> :ok
        {:error, %Error{}} = error -> error
        _locked -> {:error, Error.new(:vault_locked)}
      end
    else
      {:error, Error.new(:vault_locked)}
    end
  end

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, arguments)
  end

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, [context | arguments])
  end

  defp classification(value) when value in [:private, "private"],
    do: {:ok, :private}

  defp classification(value) when value in [:sensitive, "sensitive"],
    do: {:ok, :sensitive}

  defp classification(value) when value in [:restricted, "restricted"],
    do: {:ok, :restricted}

  defp classification(_value), do: :error

  defp present?(map, key), do: not is_nil(Map.get(map, key))

  defp nonempty_binary?(value),
    do: is_binary(value) and byte_size(String.trim(value)) > 0

  defp unauthenticated, do: {:error, Error.new(:unauthenticated)}
  defp forbidden, do: {:error, Error.new(:forbidden)}
end
