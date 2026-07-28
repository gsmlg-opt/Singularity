defmodule Singularity.Runtime.Assets.Download do
  @moduledoc "Authorizes and authenticates a full or ranged plaintext asset read."

  alias Singularity.Core.Error
  alias Singularity.Runtime.Audit
  alias Singularity.Runtime.KeyCustodian
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.SessionContext
  alias Singularity.Storage.Postgres.AssetRepository
  alias Singularity.Storage.Postgres.AuditSink

  @safe_media_types ["application/pdf", "image/jpeg", "image/png"]
  @download_media_types @safe_media_types ++ ["application/octet-stream"]
  @download_descriptor_keys MapSet.new([
                              :asset_id,
                              :vault_id,
                              :classification,
                              :plaintext_byte_size,
                              :detected_media_type
                            ])

  @spec describe(map(), SessionContext.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def describe(
        runtime,
        %SessionContext{} = session,
        asset_id
      )
      when is_map(runtime) do
    with true <- session.unlocked? and valid_uuid?(asset_id),
         {:ok, adapters} <- descriptor_adapters(runtime) do
      case load_descriptor(
             adapters,
             runtime,
             session,
             asset_id,
             :private
           ) do
        {:reauthorize, object} ->
          reauthorize_descriptor(
            adapters,
            runtime,
            session,
            asset_id,
            object
          )

        result ->
          result
      end
    else
      false -> {:error, Error.new(:invalid)}
      {:error, %Error{}} = error -> error
      _invalid -> {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  catch
    _kind, _reason ->
      {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def describe(_runtime, _session, _asset_id),
    do: {:error, Error.new(:invalid)}

  @spec run(
          map(),
          SessionContext.t(),
          String.t(),
          :all | Range.t()
        ) ::
          {:ok, binary()} | {:error, Error.t()}
  def run(
        runtime,
        %SessionContext{} = session,
        asset_id,
        range
      )
      when is_map(runtime),
      do: run(runtime, session, asset_id, range, Ecto.UUID.generate())

  def run(_runtime, _session, _asset_id, _range),
    do: {:error, Error.new(:invalid)}

  @spec run(
          map(),
          SessionContext.t(),
          String.t(),
          :all | Range.t(),
          String.t()
        ) ::
          {:ok, binary()} | {:error, Error.t()}
  def run(
        runtime,
        %SessionContext{} = session,
        asset_id,
        range,
        correlation_id
      )
      when is_map(runtime) do
    with :ok <- validate_request(session, asset_id, range, correlation_id),
         {:ok, adapters} <- adapters(runtime) do
      case load_or_read(
             adapters,
             runtime,
             session,
             asset_id,
             range,
             :private,
             correlation_id
           ) do
        {:reauthorize, object} ->
          reauthorize_and_read(
            adapters,
            runtime,
            session,
            asset_id,
            range,
            object,
            correlation_id
          )

        result ->
          result
      end
    end
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  catch
    _kind, _reason ->
      {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def run(_runtime, _session, _asset_id, _range, _correlation_id),
    do: {:error, Error.new(:invalid)}

  defp validate_request(session, asset_id, range, correlation_id) do
    valid? =
      session.unlocked? and valid_uuid?(asset_id) and
        valid_range?(range) and valid_uuid?(correlation_id)

    if valid?, do: :ok, else: {:error, Error.new(:invalid)}
  end

  defp valid_range?(:all), do: true

  defp valid_range?(%Range{first: first, last: last, step: 1}),
    do:
      is_integer(first) and first >= 0 and is_integer(last) and
        last >= first

  defp valid_range?(_range), do: false

  defp load_or_read(
         adapters,
         runtime,
         session,
         asset_id,
         range,
         classification,
         correlation_id
       ) do
    call_adapter(adapters.operation_scope, :with_read_request, [
      runtime,
      session,
      requirement(session, classification),
      fn repo ->
        with {:ok, object} <-
               call_adapter(adapters.assets, :authorized_object, [
                 repo,
                 asset_id
               ]),
             :ok <- validate_object(object, session, asset_id) do
          if object.classification == classification do
            read_object(
              adapters,
              repo,
              session,
              object,
              range,
              correlation_id
            )
          else
            {:reauthorize, object}
          end
        end
      end
    ])
  end

  defp load_descriptor(
         adapters,
         runtime,
         session,
         asset_id,
         classification
       ) do
    call_adapter(adapters.operation_scope, :with_read_request, [
      runtime,
      session,
      requirement(session, classification),
      fn repo ->
        with {:ok, object} <-
               call_adapter(
                 adapters.assets,
                 :authorized_download_descriptor,
                 [
                   repo,
                   asset_id
                 ]
               ),
             :ok <- validate_download_descriptor(object, session, asset_id),
             {:ok, descriptor} <- descriptor(object) do
          if object.classification == classification,
            do: {:ok, descriptor},
            else: {:reauthorize, object}
        end
      end
    ])
  end

  defp reauthorize_descriptor(
         adapters,
         runtime,
         session,
         asset_id,
         discovered
       ) do
    call_adapter(adapters.operation_scope, :with_read_request, [
      runtime,
      session,
      requirement(session, discovered.classification),
      fn repo ->
        with {:ok, object} <-
               call_adapter(
                 adapters.assets,
                 :authorized_download_descriptor,
                 [
                   repo,
                   asset_id
                 ]
               ),
             :ok <- validate_download_descriptor(object, session, asset_id),
             true <- object == discovered,
             {:ok, descriptor} <- descriptor(object) do
          {:ok, descriptor}
        else
          false -> {:error, Error.new(:conflict)}
          {:error, %Error{}} = error -> error
          _invalid -> {:error, Error.new(:integrity_failure)}
        end
      end
    ])
  end

  defp reauthorize_and_read(
         adapters,
         runtime,
         session,
         asset_id,
         range,
         discovered,
         correlation_id
       ) do
    call_adapter(adapters.operation_scope, :with_read_request, [
      runtime,
      session,
      requirement(session, discovered.classification),
      fn repo ->
        with {:ok, object} <-
               call_adapter(adapters.assets, :authorized_object, [
                 repo,
                 asset_id
               ]),
             :ok <- validate_object(object, session, asset_id),
             true <- object == discovered do
          read_object(
            adapters,
            repo,
            session,
            object,
            range,
            correlation_id
          )
        else
          false -> {:error, Error.new(:conflict)}
          {:error, %Error{}} = error -> error
          _invalid -> {:error, Error.new(:integrity_failure)}
        end
      end
    ])
  end

  defp read_object(
         adapters,
         repo,
         session,
         object,
         range,
         correlation_id
       ) do
    with {:ok, lease} <-
           call_adapter(adapters.custodian, :lease, [
             lease_request(session, object)
           ]),
         {:ok, plaintext} <-
           call_adapter(adapters.authenticated_reader, :read, [
             lease,
             range
           ]),
         true <- is_binary(plaintext),
         :ok <-
           append_read_audit(
             adapters.audit,
             repo,
             session,
             object,
             correlation_id
           ) do
      {:ok, plaintext}
    else
      {:error, :waiting_for_unlock} ->
        {:error, Error.new(:vault_locked)}

      {:error, %Error{}} = error ->
        error

      false ->
        {:error, Error.new(:integrity_failure)}

      _invalid ->
        {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  defp append_read_audit(audit, repo, session, object, correlation_id) do
    attrs = %{
      action: "asset.downloaded",
      result: :completed,
      classification: object.classification,
      correlation_id: correlation_id,
      target_type: "asset",
      target_id: object.asset_id,
      metadata: %{}
    }

    with :ok <- Audit.append_principal(audit, repo, session, attrs) do
      append_sensitive_read_audit(
        audit,
        repo,
        session,
        object,
        correlation_id
      )
    end
  end

  defp append_sensitive_read_audit(
         _audit,
         _repo,
         _session,
         %{classification: :private},
         _correlation_id
       ),
       do: :ok

  defp append_sensitive_read_audit(
         audit,
         repo,
         session,
         %{classification: classification, asset_id: asset_id},
         correlation_id
       )
       when classification in [:sensitive, :restricted] do
    Audit.append_principal(audit, repo, session, %{
      action: "asset.sensitive_read",
      result: :completed,
      classification: classification,
      correlation_id: correlation_id,
      target_type: "asset",
      target_id: asset_id,
      metadata: %{}
    })
  end

  defp requirement(session, classification) do
    %{
      vault_id: session.vault_id,
      required_capability: "asset.read",
      classification: classification,
      requires_unlocked?: true
    }
  end

  defp validate_object(
         %{
           asset_id: asset_id,
           vault_id: vault_id,
           classification: classification,
           object_id: object_id,
           object_generation: object_generation
         },
         %{vault_id: vault_id},
         asset_id
       )
       when classification in [:private, :sensitive, :restricted] and
              is_integer(object_generation) and object_generation > 0 do
    if valid_uuid?(object_id),
      do: :ok,
      else: {:error, Error.new(:integrity_failure)}
  end

  defp validate_object(_object, _session, _asset_id),
    do: {:error, Error.new(:integrity_failure)}

  defp validate_download_descriptor(
         %{
           asset_id: asset_id,
           vault_id: vault_id,
           classification: classification,
           plaintext_byte_size: plaintext_byte_size,
           detected_media_type: detected_media_type
         } = descriptor,
         %{vault_id: vault_id},
         asset_id
       )
       when classification in [:private, :sensitive, :restricted] and
              is_integer(plaintext_byte_size) and plaintext_byte_size >= 0 and
              detected_media_type in @download_media_types do
    if descriptor |> Map.keys() |> MapSet.new() == @download_descriptor_keys,
      do: :ok,
      else: {:error, Error.new(:integrity_failure)}
  end

  defp validate_download_descriptor(_descriptor, _session, _asset_id),
    do: {:error, Error.new(:integrity_failure)}

  defp lease_request(session, object) do
    %{
      job_id: object.asset_id,
      purpose: :download,
      session_id: session.session_id,
      principal_id: session.principal_id,
      vault_id: session.vault_id,
      required_capability: "asset.read",
      principal_authorization_epoch: session.principal_authorization_epoch,
      vault_authorization_epoch: session.vault_authorization_epoch,
      object_id: object.object_id,
      object_generation: object.object_generation
    }
  end

  defp adapters(runtime) do
    values = %{
      assets: Map.get(runtime, :assets, AssetRepository),
      authenticated_reader:
        Map.get(
          runtime,
          :authenticated_reader,
          Singularity.Runtime.DownloadLease
        ),
      audit: Map.get(runtime, :audit, AuditSink),
      custodian: Map.get(runtime, :custodian, {KeyCustodian, KeyCustodian}),
      operation_scope: Map.get(runtime, :operation_scope, OperationScope)
    }

    if Enum.all?(Map.values(values), &concrete?/1),
      do: {:ok, values},
      else: {:error, Error.new(:invalid)}
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

  defp descriptor(%{
         plaintext_byte_size: plaintext_byte_size,
         detected_media_type: detected_media_type
       })
       when is_integer(plaintext_byte_size) and plaintext_byte_size >= 0 and
              detected_media_type in @download_media_types do
    {:ok,
     %{
       plaintext_byte_size: plaintext_byte_size,
       detected_media_type: detected_media_type
     }}
  end

  defp descriptor(_object),
    do: {:error, Error.new(:integrity_failure)}

  defp valid_uuid?(value),
    do: match?({:ok, _uuid}, Ecto.UUID.cast(value))

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
