defmodule Singularity.Runtime.Assets.AcceptUpload do
  @moduledoc """
  Exchanges an exact upload grant for an opaque, bounded upload process.

  Object key material remains inside the runtime custody boundary. The upload
  session receives only a one-time material reference and claims the secrets
  after the grant has been consumed durably.
  """

  alias Singularity.Core.Error
  alias Singularity.Runtime.KeyCustodian
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.SessionContext
  alias Singularity.Runtime.UploadSessionSupervisor
  alias Singularity.Storage.Postgres.AssetRepository

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
  @safe_media_types ["application/pdf", "image/jpeg", "image/png"]

  @spec load_grant_descriptor(map(), SessionContext.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def load_grant_descriptor(
        runtime,
        %SessionContext{} = session,
        selector
      )
      when is_map(runtime) and is_map(selector) do
    with :ok <- validate_selector(session, selector),
         {:ok, adapters} <- descriptor_adapters(runtime) do
      case load_descriptor(
             adapters,
             runtime,
             session,
             selector,
             :private
           ) do
        {:ok, %{classification: :private}} = result ->
          result

        {:ok, %{classification: classification} = discovered}
        when classification in [:sensitive, :restricted] ->
          with {:ok, reloaded} <-
                 load_descriptor(
                   adapters,
                   runtime,
                   session,
                   selector,
                   classification
                 ),
               true <- reloaded == discovered do
            {:ok, reloaded}
          else
            false -> {:error, Error.new(:conflict)}
            {:error, %Error{}} = error -> error
            _invalid -> {:error, Error.new(:integrity_failure)}
          end

        result ->
          result
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

  def load_grant_descriptor(_runtime, _session, _selector),
    do: {:error, Error.new(:invalid)}

  @spec begin(map(), SessionContext.t(), map(), pid()) ::
          {:ok, pid()} | {:error, Error.t()}
  def begin(
        runtime,
        %SessionContext{} = session,
        grant,
        controller
      )
      when is_map(runtime) and is_map(grant) and is_pid(controller) do
    with :ok <- raw_credentials_absent(grant),
         {:ok, normalized_grant} <- normalize_grant(grant),
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
      validate_request_binding(Map.put(grant, :grant_id, grant_id))
    else
      false -> {:error, Error.new(:invalid)}
    end
  end

  defp validate_request_binding(grant) do
    valid? =
      valid_digest?(Map.get(grant, :token_digest)) and
        valid_digest?(Map.get(grant, :csrf_token_digest)) and
        valid_content_length?(Map.get(grant, :request_content_length)) and
        Map.get(grant, :request_declared_media_type) in @safe_media_types

    if valid?, do: {:ok, grant}, else: {:error, Error.new(:invalid)}
  end

  defp validate_selector(session, selector) do
    valid? =
      raw_credential_fields_absent?(selector) and session.unlocked? and
        valid_uuid?(Map.get(selector, :grant_id)) and
        Map.get(selector, :session_id) == session.session_id and
        Map.get(selector, :principal_id) == session.principal_id and
        Map.get(selector, :vault_id) == session.vault_id and
        valid_digest?(Map.get(selector, :token_digest)) and
        valid_digest?(Map.get(selector, :csrf_token_digest)) and
        valid_content_length?(Map.get(selector, :request_content_length)) and
        Map.get(selector, :request_declared_media_type) in @safe_media_types

    if valid?, do: :ok, else: {:error, Error.new(:invalid)}
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

  defp descriptor_adapters(runtime) do
    values = %{
      assets: Map.get(runtime, :assets, AssetRepository),
      operation_scope: Map.get(runtime, :operation_scope, OperationScope)
    }

    if Enum.all?(Map.values(values), &concrete?/1),
      do: {:ok, values},
      else: {:error, Error.new(:invalid)}
  end

  defp load_descriptor(
         adapters,
         runtime,
         session,
         selector,
         classification
       ) do
    call_adapter(adapters.operation_scope, :with_read_request, [
      runtime,
      session,
      %{
        vault_id: session.vault_id,
        required_capability: "asset.write",
        classification: classification,
        requires_unlocked?: true
      },
      fn repo ->
        call_adapter(
          adapters.assets,
          :load_upload_grant_descriptor,
          [repo, selector]
        )
      end
    ])
    |> normalize_descriptor_result()
  end

  defp normalize_descriptor_result({:ok, descriptor})
       when is_map(descriptor) do
    if credential_fields_absent?(descriptor) and
         Map.get(descriptor, :classification) in [
           :private,
           :sensitive,
           :restricted
         ] do
      {:ok, descriptor}
    else
      {:error, Error.new(:integrity_failure)}
    end
  end

  defp normalize_descriptor_result({:error, %Error{}} = error), do: error

  defp normalize_descriptor_result(_result),
    do: {:error, Error.new(:storage_unavailable, retryable?: true)}

  defp raw_credentials_absent(grant) do
    if raw_credential_fields_absent?(grant),
      do: :ok,
      else: {:error, Error.new(:invalid)}
  end

  defp raw_credential_fields_absent?(value) do
    Enum.all?(
      [
        :token,
        "token",
        :upload_token,
        "upload_token",
        :csrf_token,
        "csrf_token"
      ],
      &(not Map.has_key?(value, &1))
    )
  end

  defp credential_fields_absent?(descriptor) do
    raw_credential_fields_absent?(descriptor) and
      Enum.all?(
        [
          :token_digest,
          "token_digest",
          :csrf_token_digest,
          "csrf_token_digest"
        ],
        &(not Map.has_key?(descriptor, &1))
      )
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
  defp valid_digest?(value), do: is_binary(value) and byte_size(value) == 32

  defp valid_content_length?(value),
    do:
      is_integer(value) and value >= 0 and
        value <= max_upload_bytes()

  defp max_upload_bytes do
    Application.get_env(
      :singularity_runtime,
      :max_upload_bytes,
      512 * 1024 * 1024
    )
  end

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
