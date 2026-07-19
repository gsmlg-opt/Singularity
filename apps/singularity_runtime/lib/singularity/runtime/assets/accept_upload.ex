defmodule Singularity.Runtime.Assets.AcceptUpload do
  @moduledoc """
  Exchanges an exact upload grant for an opaque, bounded upload process.

  Object key material remains inside the runtime custody boundary. The upload
  session receives only a one-time material reference and claims the secrets
  after the grant has been consumed durably.
  """

  alias Singularity.Core.Error
  alias Singularity.Runtime.KeyCustodian
  alias Singularity.Runtime.SessionContext
  alias Singularity.Runtime.UploadSessionSupervisor

  @binding_fields [
    :grant_id,
    :asset_id,
    :session_id,
    :principal_id,
    :vault_id,
    :principal_authorization_epoch,
    :vault_authorization_epoch,
    :classification
  ]

  @spec begin(map(), SessionContext.t(), map(), pid()) ::
          {:ok, pid()} | {:error, Error.t()}
  def begin(
        runtime,
        %SessionContext{} = session,
        grant,
        controller
      )
      when is_map(runtime) and is_map(grant) and is_pid(controller) do
    with {:ok, normalized_grant} <- normalize_grant(grant),
         :ok <- validate_binding(session, normalized_grant),
         {:ok, adapters} <- adapters(runtime),
         request = Map.take(normalized_grant, @binding_fields),
         {:ok, prepared} <-
           call_adapter(adapters.custodian, :prepare_upload, [request]) do
      internal_grant = Map.put(normalized_grant, :upload, prepared)

      case start_upload(
             adapters.upload_supervisor,
             runtime,
             session,
             internal_grant,
             controller
           ) do
        {:ok, upload} when is_pid(upload) ->
          {:ok, upload}

        {:error, %Error{}} = error ->
          discard(adapters.custodian, prepared)
          error

        _invalid ->
          discard(adapters.custodian, prepared)
          {:error, Error.new(:storage_unavailable, retryable?: true)}
      end
    else
      {:error, %Error{}} = error -> error
      _invalid -> {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  catch
    _kind, _reason ->
      {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def begin(_runtime, _session, _grant, _controller),
    do: {:error, Error.new(:invalid)}

  defp normalize_grant(grant) do
    grant_id = Map.get(grant, :grant_id, Map.get(grant, :id))

    with true <- valid_uuid?(grant_id),
         true <- compatible_id?(Map.get(grant, :id), grant_id),
         true <- compatible_id?(Map.get(grant, :grant_id), grant_id),
         true <- valid_uuid?(Map.get(grant, :asset_id)),
         true <- valid_uuid?(Map.get(grant, :session_id)),
         true <- valid_uuid?(Map.get(grant, :principal_id)),
         true <- valid_uuid?(Map.get(grant, :vault_id)),
         true <-
           Map.get(grant, :classification) in [
             :private,
             :sensitive,
             :restricted
           ],
         true <-
           valid_epoch?(Map.get(grant, :principal_authorization_epoch)),
         true <- valid_epoch?(Map.get(grant, :vault_authorization_epoch)) do
      {:ok, Map.put(grant, :grant_id, grant_id)}
    else
      false -> {:error, Error.new(:invalid)}
    end
  end

  defp validate_binding(session, grant) do
    exact? =
      session.unlocked? and
        grant.session_id == session.session_id and
        grant.principal_id == session.principal_id and
        grant.vault_id == session.vault_id and
        grant.principal_authorization_epoch ==
          session.principal_authorization_epoch and
        grant.vault_authorization_epoch ==
          session.vault_authorization_epoch

    if exact?, do: :ok, else: {:error, Error.new(:invalid)}
  end

  defp adapters(runtime) do
    custodian = Map.get(runtime, :custodian, {KeyCustodian, KeyCustodian})

    upload_supervisor =
      Map.get(runtime, :upload_supervisor, UploadSessionSupervisor)

    if concrete?(custodian) and concrete?(upload_supervisor) do
      {:ok, %{custodian: custodian, upload_supervisor: upload_supervisor}}
    else
      {:error, Error.new(:invalid)}
    end
  end

  defp discard(custodian, %{material_ref: material_ref})
       when is_reference(material_ref) do
    _result = call_adapter(custodian, :discard_upload, [material_ref])
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp discard(_custodian, _prepared), do: :ok

  defp start_upload(
         upload_supervisor,
         runtime,
         session,
         internal_grant,
         controller
       ) do
    call_adapter(upload_supervisor, :begin_upload, [
      runtime,
      session,
      internal_grant,
      controller
    ])
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  catch
    _kind, _reason ->
      {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  defp valid_uuid?(value),
    do: match?({:ok, _uuid}, Ecto.UUID.cast(value))

  defp compatible_id?(nil, _grant_id), do: true
  defp compatible_id?(value, grant_id), do: value == grant_id

  defp valid_epoch?(value), do: is_integer(value) and value >= 0

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, arguments)
  end

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, [context | arguments])
  end

  defp concrete?(value), do: value not in [nil, false]
end
