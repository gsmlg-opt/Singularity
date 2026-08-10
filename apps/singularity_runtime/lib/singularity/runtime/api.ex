defmodule Singularity.Runtime.Api.UploadHandle do
  @moduledoc false

  @enforce_keys [:session, :vault_id, :asset_id]
  defstruct [:session, :vault_id, :asset_id]

  @type t :: %__MODULE__{
          session: term(),
          vault_id: String.t(),
          asset_id: String.t()
        }
end

defmodule Singularity.Runtime.Api do
  @moduledoc """
  The sole application-facing runtime facade.

  It converts internal structs and errors into non-secret runtime DTOs and
  stable atoms. Extra leading-config arities are deterministic test seams.
  """

  alias Singularity.Core.Error
  alias Singularity.Retrieval.AssetMetadataSearch
  alias Singularity.Runtime.Api.UploadHandle
  alias Singularity.Runtime.AssetEvents
  alias Singularity.Runtime.Assets.AcceptUpload
  alias Singularity.Runtime.Assets.CancelUploadGrant
  alias Singularity.Runtime.Assets.CreateUploadGrant
  alias Singularity.Runtime.Assets.Delete
  alias Singularity.Runtime.Assets.Download
  alias Singularity.Runtime.Assets.Retry
  alias Singularity.Runtime.Assets.Search
  alias Singularity.Runtime.Assets.UploadSession
  alias Singularity.Runtime.AuthorizationDependencies
  alias Singularity.Runtime.Authorize
  alias Singularity.Runtime.BackupKeyLease
  alias Singularity.Runtime.Backups.Status, as: BackupStatusReader
  alias Singularity.Runtime.BackupVault
  alias Singularity.Runtime.DTO.AssetSummary
  alias Singularity.Runtime.DTO.BackupStatus
  alias Singularity.Runtime.DTO.SearchPage
  alias Singularity.Runtime.DTO.Session
  alias Singularity.Runtime.DTO.UploadGrant
  alias Singularity.Runtime.KeyCustodian
  alias Singularity.Runtime.Login
  alias Singularity.Runtime.Logout
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.ResolveSession
  alias Singularity.Runtime.SessionContext
  alias Singularity.Runtime.StorageAdapter
  alias Singularity.Runtime.UnlockVault
  alias Singularity.Runtime.UploadSessionSupervisor
  alias Singularity.Storage.AuthorizationLock
  alias Singularity.Storage.Backup.LocalDestination
  alias Singularity.Storage.Crypto.Argon2KeyDeriver
  alias Singularity.Storage.Crypto.Argon2PasswordHasher
  alias Singularity.Storage.Crypto.BackupKeyDeriver
  alias Singularity.Storage.Crypto.BackupRecoveryWrapper
  alias Singularity.Storage.Crypto.KeyWrapper
  alias Singularity.Storage.EncryptedStageWriter
  alias Singularity.Storage.ObjectLock
  alias Singularity.Storage.Postgres.AssetDeletionRepository
  alias Singularity.Storage.Postgres.AssetRepository
  alias Singularity.Storage.Postgres.AssetSearchStore
  alias Singularity.Storage.Postgres.AuditSink
  alias Singularity.Storage.Postgres.BackupRepository
  alias Singularity.Storage.Postgres.BackupStatusStore
  alias Singularity.Storage.Postgres.IdentityRepository
  alias Singularity.Storage.Postgres.PreAuth
  alias Singularity.Storage.PreAuthRepo
  alias Singularity.Storage.RequestRepo
  alias Singularity.Storage.Schema.Content.Asset, as: StoredAsset
  alias Singularity.Storage.Schema.Content.AssetStage
  alias Singularity.Storage.ScopedRepo
  alias Singularity.Storage.VaultLock
  alias Singularity.Storage.Jobs.ObanAdapter

  @safe_media_types ["application/pdf", "image/jpeg", "image/png"]
  @asset_states [
    :staging,
    :uploaded,
    :verified,
    :available,
    :processing,
    :ready,
    :pending_delete,
    :deleted
  ]
  @classifications [:private, :sensitive, :restricted]
  @backup_statuses [:pending, :waiting_for_backup_key, :copying, :sealed, :failed]
  @classification_labels Enum.map(@classifications, &Atom.to_string/1)
  @failure_codes Enum.map(Error.codes(), &Atom.to_string/1)
  @stable_errors Error.codes() ++
                   [
                     :csrf_failed,
                     :invalid_content_length,
                     :range_not_satisfiable
                   ]

  @spec login(map()) :: {:ok, String.t(), Session.t()} | {:error, atom()}
  def login(attrs), do: with_production(&login(&1, attrs))

  @doc false
  def login(config, attrs) when is_map(config) and is_map(attrs) do
    attrs =
      attrs
      |> Map.take([:login, :password, :source])
      |> Map.put(:correlation_id, Ecto.UUID.generate())

    with {:ok, %{opaque_token: <<_::binary-size(32)>> = token}} <-
           invoke(config, :login, [attrs]),
         {:ok, resolved} <- invoke(config, :resolve_session, [token]),
         {:ok, session} <- session_dto(resolved) do
      {:ok, Base.url_encode64(token, padding: false), session}
    else
      result -> normalize_error(result)
    end
  end

  def login(_config, _attrs), do: {:error, :invalid}

  @spec resolve_session(String.t()) :: {:ok, Session.t()} | {:error, atom()}
  def resolve_session(opaque_id),
    do: with_production(&resolve_session(&1, opaque_id))

  @doc false
  def resolve_session(config, opaque_id) when is_map(config) do
    with {:ok, token} <- decode_token(opaque_id),
         {:ok, resolved} <- invoke(config, :resolve_session, [token]),
         {:ok, session} <- session_dto(resolved) do
      {:ok, session}
    else
      result -> normalize_error(result)
    end
  end

  @spec unlock(Session.t(), binary()) ::
          {:ok, Session.t()} | {:error, atom()}
  def unlock(session, password),
    do: with_production(&unlock(&1, session, password))

  @doc false
  def unlock(config, %Session{} = session, password)
      when is_map(config) and is_binary(password) do
    with {:ok, context} <- session_context(session),
         {:ok, unlocked} <- invoke(config, :unlock, [context, password]),
         {:ok, dto} <- session_dto(unlocked) do
      {:ok, dto}
    else
      result -> normalize_error(result)
    end
  end

  def unlock(_config, _session, _password), do: {:error, :invalid}

  @spec logout(Session.t()) :: :ok | {:error, atom()}
  def logout(session), do: with_production(&logout(&1, session))

  @doc false
  def logout(config, %Session{} = session) when is_map(config) do
    with {:ok, context} <- session_context(session),
         :ok <- invoke(config, :logout, [context]) do
      :ok
    else
      result -> normalize_error(result)
    end
  end

  def logout(_config, _session), do: {:error, :invalid}

  @spec request_backup(Session.t(), binary()) ::
          {:ok, BackupStatus.t()} | {:error, atom()}
  def request_backup(session, passphrase),
    do: with_production(&request_backup(&1, session, passphrase))

  @doc false
  def request_backup(config, %Session{} = session, passphrase)
      when is_map(config) and is_binary(passphrase) and byte_size(passphrase) > 0 do
    with {:ok, %SessionContext{unlocked?: true} = context} <- session_context(session),
         :ok <- invoke(config, :authorize_backup_request, [context]),
         {:ok, created} <- invoke(config, :request_backup, [context, passphrase]),
         {:ok, operation_id} <- backup_operation_identity(created),
         {:ok, status} <- invoke(config, :backup_status, [context, operation_id]),
         {:ok, dto} <- backup_status_dto(status, context, operation_id) do
      {:ok, dto}
    else
      {:ok, %SessionContext{unlocked?: false}} -> {:error, :vault_locked}
      result -> normalize_error(result)
    end
  end

  def request_backup(_config, _session, _passphrase), do: {:error, :invalid}

  @spec backup_status(Session.t(), String.t()) ::
          {:ok, BackupStatus.t()} | {:error, atom()}
  def backup_status(session, operation_id),
    do: with_production(&backup_status(&1, session, operation_id))

  @doc false
  def backup_status(config, %Session{} = session, operation_id)
      when is_map(config) and is_binary(operation_id) do
    with true <- valid_uuid?(operation_id),
         {:ok, %SessionContext{unlocked?: true} = context} <- session_context(session),
         {:ok, status} <- invoke(config, :backup_status, [context, operation_id]),
         {:ok, dto} <- backup_status_dto(status, context, operation_id) do
      {:ok, dto}
    else
      false -> {:error, :invalid}
      {:ok, %SessionContext{unlocked?: false}} -> {:error, :vault_locked}
      result -> normalize_error(result)
    end
  end

  def backup_status(_config, _session, _operation_id), do: {:error, :invalid}

  @spec list_assets(Session.t(), map() | keyword()) ::
          {:ok, SearchPage.t()} | {:error, atom()}
  def list_assets(session, params),
    do: with_production(&list_assets(&1, session, params))

  @doc false
  def list_assets(config, %Session{} = session, params) when is_map(config) do
    with {:ok, context} <- session_context(session),
         {:ok, page} <- invoke(config, :list_assets, [context, params]),
         {:ok, dto} <- search_page_dto(page) do
      {:ok, dto}
    else
      result -> normalize_error(result)
    end
  end

  def list_assets(_config, _session, _params), do: {:error, :invalid}

  @spec subscribe_assets(Session.t()) :: :ok | {:error, atom()}
  def subscribe_assets(session),
    do: with_production(&subscribe_assets(&1, session))

  @doc false
  def subscribe_assets(config, %Session{} = session) when is_map(config) do
    with {:ok, %SessionContext{unlocked?: true, vault_id: vault_id} = context} <-
           session_context(session),
         :ok <- invoke(config, :authorize_asset_subscription, [context]),
         :ok <- invoke(config, :subscribe_assets, [vault_id]) do
      :ok
    else
      {:ok, %SessionContext{unlocked?: false}} -> {:error, :vault_locked}
      result -> normalize_error(result)
    end
  end

  def subscribe_assets(_config, _session), do: {:error, :invalid}

  @spec asset_summary(Session.t(), String.t()) ::
          {:ok, AssetSummary.t()} | {:error, atom()}
  def asset_summary(session, asset_id),
    do: with_production(&asset_summary(&1, session, asset_id))

  @doc false
  def asset_summary(config, %Session{} = session, asset_id)
      when is_map(config) do
    with true <- valid_uuid?(asset_id),
         {:ok, context} <- session_context(session),
         {:ok, item} <-
           invoke(config, :asset_summary, [context, asset_id]),
         {:ok, summary} <-
           authorized_asset_summary(item, context, asset_id) do
      {:ok, summary}
    else
      false -> {:error, :invalid}
      result -> normalize_error(result)
    end
  end

  def asset_summary(_config, _session, _asset_id), do: {:error, :invalid}

  @spec retry_asset(Session.t(), String.t(), non_neg_integer()) ::
          {:ok, boolean()} | {:error, atom()}
  def retry_asset(session, asset_id, state_revision),
    do: with_production(&retry_asset(&1, session, asset_id, state_revision))

  @doc false
  def retry_asset(config, %Session{} = session, asset_id, state_revision)
      when is_map(config) do
    with :ok <- validate_asset_mutation(asset_id, state_revision),
         {:ok, context} <- session_context(session) do
      case invoke(
             config,
             :retry_asset,
             [context, asset_id, state_revision]
           ) do
        {:ok, :accepted} ->
          publish_asset(config, context.vault_id, asset_id)
          {:ok, true}

        {:ok, :stale} ->
          {:ok, false}

        {:ok, _invalid_result} ->
          {:error, :integrity_failure}

        result ->
          normalize_error(result)
      end
    else
      result -> normalize_error(result)
    end
  end

  def retry_asset(_config, _session, _asset_id, _state_revision),
    do: {:error, :invalid}

  @spec delete_asset(Session.t(), String.t(), non_neg_integer()) ::
          {:ok, boolean()} | {:error, atom()}
  def delete_asset(session, asset_id, state_revision),
    do: with_production(&delete_asset(&1, session, asset_id, state_revision))

  @doc false
  def delete_asset(config, %Session{} = session, asset_id, state_revision)
      when is_map(config) do
    with :ok <- validate_asset_mutation(asset_id, state_revision),
         {:ok, context} <- session_context(session) do
      result =
        config
        |> invoke(
          :delete_asset,
          [context, asset_id, state_revision]
        )
        |> normalize_delete_result(asset_id)

      case result do
        {:ok, true} = accepted ->
          publish_asset(config, context.vault_id, asset_id)
          accepted

        other ->
          other
      end
    else
      result -> normalize_error(result)
    end
  end

  def delete_asset(_config, _session, _asset_id, _state_revision),
    do: {:error, :invalid}

  @spec create_upload_grant(Session.t(), map(), binary()) ::
          {:ok, binary(), UploadGrant.t()} | {:error, atom()}
  def create_upload_grant(session, attrs, csrf_token),
    do: with_production(&create_upload_grant(&1, session, attrs, csrf_token))

  @doc false
  def create_upload_grant(config, %Session{} = session, attrs, csrf_token)
      when is_map(config) and is_map(attrs) and is_binary(csrf_token) do
    with {:ok, context} <- session_context(session),
         {:ok, grant} <-
           invoke(config, :create_upload_grant, [context, attrs, csrf_token]),
         {:ok, token} <- grant_token(grant),
         {:ok, dto} <- upload_grant_dto(grant) do
      publish_asset(config, context.vault_id, dto.asset_id)
      {:ok, token, dto}
    else
      result -> normalize_error(result)
    end
  end

  def create_upload_grant(_config, _session, _attrs, _csrf_token),
    do: {:error, :invalid}

  @spec cancel_upload_grant(Session.t(), String.t()) ::
          {:ok, boolean()} | {:error, atom()}
  def cancel_upload_grant(session, grant_id),
    do: with_production(&cancel_upload_grant(&1, session, grant_id))

  @doc false
  def cancel_upload_grant(config, %Session{} = session, grant_id)
      when is_map(config) and is_binary(grant_id) do
    with {:ok, ^grant_id} <- Ecto.UUID.cast(grant_id),
         {:ok, context} <- session_context(session),
         result <- invoke(config, :cancel_upload_grant, [context, grant_id]) do
      normalize_cancel_upload_result(result, config, context, grant_id)
    else
      :error -> {:error, :invalid}
      result -> normalize_error(result)
    end
  end

  def cancel_upload_grant(_config, _session, _grant_id),
    do: {:error, :invalid}

  @spec begin_upload(Session.t(), String.t(), map(), pid()) ::
          {:ok, UploadHandle.t()} | {:error, atom()}
  def begin_upload(session, grant_id, request, owner),
    do: with_production(&begin_upload(&1, session, grant_id, request, owner))

  @doc false
  def begin_upload(
        config,
        %Session{} = session,
        grant_id,
        request,
        owner
      )
      when is_map(config) and is_map(request) and is_pid(owner) do
    with {:ok, context} <- session_context(session),
         {:ok, selector} <-
           upload_selector(config, context, grant_id, request),
         {:ok, descriptor} <-
           invoke(
             config,
             :load_upload_grant_descriptor,
             [context, selector]
           ),
         {:ok, internal_grant} <-
           internal_upload_grant(descriptor, selector),
         {:ok, expected_vault_id, expected_asset_id} <-
           upload_identity(internal_grant),
         {:ok, upload} <-
           invoke(config, :begin_upload, [context, internal_grant, owner]) do
      {:ok, upload_handle(upload, expected_vault_id, expected_asset_id)}
    else
      result -> normalize_upload_error(result)
    end
  end

  def begin_upload(_config, _session, _grant_id, _request, _owner),
    do: {:error, :invalid}

  @spec append_upload(UploadHandle.t(), binary()) :: :ok | {:error, atom()}
  def append_upload(upload, chunk),
    do: with_production(&append_upload(&1, upload, chunk))

  @doc false
  def append_upload(config, %UploadHandle{session: upload}, chunk)
      when is_map(config) and is_binary(chunk) do
    config
    |> invoke(:append_upload, [upload, chunk])
    |> normalize_upload_unit()
  end

  def append_upload(_config, _upload, _chunk), do: {:error, :invalid}

  @spec finish_upload(UploadHandle.t(), binary()) ::
          {:ok, map()} | {:error, atom()}
  def finish_upload(upload, final_chunk),
    do: with_production(&finish_upload(&1, upload, final_chunk))

  @doc false
  def finish_upload(config, %UploadHandle{} = handle, final_chunk)
      when is_map(config) and is_binary(final_chunk) do
    with :ok <- append_upload(config, handle, final_chunk),
         {:ok, result} <-
           invoke(config, :finish_upload, [handle.session]),
         {:ok, response} <-
           upload_response(result, handle.vault_id, handle.asset_id) do
      publish_asset(config, handle.vault_id, handle.asset_id)
      {:ok, response}
    else
      result -> normalize_upload_error(result)
    end
  end

  def finish_upload(_config, _upload, _final_chunk),
    do: {:error, :invalid}

  @spec abandon_upload(UploadHandle.t(), term()) :: :ok | {:error, atom()}
  def abandon_upload(upload, reason),
    do: with_production(&abandon_upload(&1, upload, reason))

  @doc false
  def abandon_upload(config, %UploadHandle{session: upload}, reason)
      when is_map(config) do
    config
    |> invoke(:abandon_upload, [upload, reason])
    |> normalize_upload_unit()
  end

  def abandon_upload(_config, _upload, _reason), do: {:error, :invalid}

  @spec end_upload(UploadHandle.t()) :: :ok
  def end_upload(upload), do: with_production(&end_upload(&1, upload))

  @doc false
  def end_upload(config, %UploadHandle{} = upload) when is_map(config) do
    _result = abandon_upload(config, upload, :controller_ended)
    :ok
  end

  def end_upload(_config, _upload), do: :ok

  @spec download(Session.t(), String.t(), nil | binary()) ::
          {:ok, map()} | {:error, atom()}
  def download(session, asset_id, range_header),
    do: with_production(&download(&1, session, asset_id, range_header))

  @doc false
  def download(config, %Session{} = session, asset_id, range_header)
      when is_map(config) do
    with {:ok, context} <- session_context(session),
         {:ok, descriptor} <-
           invoke(config, :download_descriptor, [context, asset_id]),
         {:ok, total, media_type} <- download_metadata(descriptor),
         {:ok, range, status, content_range, expected_length} <-
           download_range(range_header, total),
         {:ok, body} <- invoke(config, :download, [context, asset_id, range]),
         true <- is_binary(body) and byte_size(body) == expected_length do
      {:ok,
       %{
         status: status,
         body: body,
         content_length: expected_length,
         content_range: content_range,
         detected_media_type: safe_media_type(media_type)
       }}
    else
      false -> {:error, :integrity_failure}
      result -> normalize_error(result)
    end
  end

  def download(_config, _session, _asset_id, _range_header),
    do: {:error, :invalid}

  @doc false
  def upload_handle(session, vault_id, asset_id) do
    %UploadHandle{
      session: session,
      vault_id: vault_id,
      asset_id: asset_id
    }
  end

  defp production_config do
    runtime = production_runtime()

    %{
      abandon_upload: &UploadSession.abandon/2,
      append_upload: &UploadSession.append/2,
      authorize_asset_subscription: fn session ->
        case Search.run(runtime, session, %{limit: 1}) do
          {:ok, _page} -> :ok
          {:error, %Error{}} = error -> error
        end
      end,
      authorize_backup_request: fn session ->
        OperationScope.with_read_request(
          runtime,
          session,
          backup_request_requirement(session),
          fn _repo -> :ok end
        )
      end,
      asset_summary: fn session, asset_id ->
        Search.fetch(runtime, session, asset_id)
      end,
      backup_status: fn session, operation_id ->
        BackupStatusReader.run(runtime, session, operation_id)
      end,
      begin_upload: fn session, grant, owner ->
        AcceptUpload.begin(runtime, session, grant, owner)
      end,
      cancel_upload_grant: fn session, grant_id ->
        CancelUploadGrant.run(runtime, session, grant_id)
      end,
      create_upload_grant: fn session, attrs, csrf_token ->
        CreateUploadGrant.run(runtime, session, attrs, csrf_token)
      end,
      delete_asset: fn session, asset_id, state_revision ->
        Delete.run(runtime, session, asset_id, state_revision)
      end,
      download: fn session, asset_id, range ->
        Download.run(runtime, session, asset_id, range)
      end,
      download_descriptor: fn session, asset_id ->
        Download.describe(runtime, session, asset_id)
      end,
      finish_upload: &UploadSession.finish/1,
      list_assets: fn session, params ->
        Search.run(runtime, session, params)
      end,
      load_upload_grant_descriptor: fn session, selector ->
        AcceptUpload.load_grant_descriptor(runtime, session, selector)
      end,
      max_upload_bytes:
        Application.get_env(
          :singularity_runtime,
          :max_upload_bytes,
          512 * 1024 * 1024
        ),
      login: &Login.run(login_adapters(), &1),
      logout: fn session ->
        Logout.run(runtime, session, Ecto.UUID.generate())
      end,
      publish_asset: &AssetEvents.publish/2,
      request_backup: fn session, passphrase ->
        relative_destination = "web/" <> Ecto.UUID.generate() <> ".bundle"

        with {:ok, destination_ref} <-
               call_adapter(runtime.backup_destination, :normalize, [
                 relative_destination
               ]),
             {:ok, manifest} <-
               BackupVault.request(runtime, session, passphrase, destination_ref),
             {:ok, identity} <- internal_backup_identity(manifest) do
          {:ok, identity}
        end
      end,
      resolve_session: &ResolveSession.run(resolve_session_adapters(), &1),
      retry_asset: fn session, asset_id, state_revision ->
        Retry.run(runtime, session, asset_id, state_revision)
      end,
      subscribe_assets: &AssetEvents.subscribe/1,
      unlock: fn session, password ->
        UnlockVault.run(
          runtime,
          session,
          password,
          Ecto.UUID.generate()
        )
      end
    }
  end

  defp login_adapters do
    %{
      pre_auth: PreAuth,
      pre_auth_context: PreAuthRepo,
      identity: IdentityRepository,
      identity_context: %{
        repo: RequestRepo,
        clock: fn -> DateTime.utc_now(:microsecond) end,
        session_ttl_seconds:
          Application.get_env(
            :singularity_runtime,
            :session_ttl_seconds,
            900
          )
      },
      password_hasher: Argon2PasswordHasher,
      password_hasher_context:
        Application.fetch_env!(
          :singularity_runtime,
          :password_hash_params
        ),
      audit_fingerprint_secret:
        Application.fetch_env!(
          :singularity_runtime,
          :audit_fingerprint_secret
        ),
      random_bytes: &:crypto.strong_rand_bytes/1
    }
  end

  defp resolve_session_adapters do
    %{
      pre_auth: PreAuth,
      pre_auth_context: PreAuthRepo,
      custodian: KeyCustodian,
      custodian_context: KeyCustodian
    }
  end

  defp production_runtime do
    authorization =
      case AuthorizationDependencies.new(
             Application.fetch_env!(
               :singularity_runtime,
               :authorization_dependencies
             )
           ) do
        {:ok, dependencies} -> dependencies
        {:error, _error} -> nil
      end

    backup_root = Application.fetch_env!(:singularity_storage, :backup_root)
    backup_profile = BackupKeyDeriver.profile()
    {storage_adapter, storage_context} = StorageAdapter.configured()

    %{
      asset_deletions: AssetDeletionRepository,
      asset_search: AssetMetadataSearch,
      asset_search_store: AssetSearchStore,
      # Stage-only uploads defer deduplication, finalization, and wrapper cleanup
      # to the authorized runtime saga.
      asset_storage: %{
        adapter: storage_adapter,
        context: storage_context,
        dedup_lookup: fn _vault_id, _domain_id, _digest -> :miss end,
        destroy_dek_wrapper: fn _wrapper -> :ok end
      },
      assets: AssetRepository,
      authenticated_reader: Singularity.Runtime.DownloadLease,
      audit: AuditSink,
      authorization: authorization,
      authorization_lock: AuthorizationLock,
      authorizer: Authorize,
      backup_destination: {LocalDestination, %{backup_root: backup_root}},
      backup_kdf_domain: backup_profile.domain,
      backup_kdf_parameters: backup_profile.parameters,
      backup_key_deriver: BackupKeyDeriver,
      backup_key_lease: BackupKeyLease,
      backup_key_wrapper: BackupRecoveryWrapper,
      backup_status_store: BackupStatusStore,
      backups: BackupRepository,
      custodian: {KeyCustodian, KeyCustodian},
      identity: IdentityRepository,
      ids: Ecto.UUID,
      jobs: {ObanAdapter, %{}},
      key_deriver: Argon2KeyDeriver,
      key_wrapper: KeyWrapper,
      operation_scope: OperationScope,
      object_lock: ObjectLock,
      request_repo: RequestRepo,
      random_bytes: &:crypto.strong_rand_bytes/1,
      scoped_repo: ScopedRepo,
      stage_writer: EncryptedStageWriter,
      upload_session_supervisor: UploadSessionSupervisor,
      upload_supervisor: UploadSessionSupervisor,
      vault_lock: VaultLock,
      vaults: IdentityRepository
    }
  end

  defp session_dto(%SessionContext{} = session) do
    values =
      Map.take(
        session,
        Map.keys(Session.__struct__()) -- [:__struct__]
      )

    validate_session(values, Session)
  end

  defp session_dto(session) when is_map(session) do
    session
    |> normalize_session_map()
    |> validate_session(Session)
  end

  defp session_dto(_session), do: {:error, :integrity_failure}

  defp session_context(%Session{} = session) do
    session
    |> Map.from_struct()
    |> validate_session(SessionContext)
  end

  defp backup_operation_identity(%{operation_id: operation_id} = identity)
       when not is_struct(identity) and map_size(identity) == 1 do
    if valid_uuid?(operation_id),
      do: {:ok, operation_id},
      else: {:error, :integrity_failure}
  end

  defp backup_operation_identity(_identity), do: {:error, :integrity_failure}

  defp backup_request_requirement(session) do
    %{
      vault_id: session.vault_id,
      classification: :private,
      required_capability: "backup.create",
      requires_unlocked?: true
    }
  end

  defp internal_backup_identity(%{id: operation_id}) do
    if valid_uuid?(operation_id),
      do: {:ok, %{operation_id: operation_id}},
      else: {:error, Error.new(:integrity_failure)}
  end

  defp internal_backup_identity(_manifest),
    do: {:error, Error.new(:integrity_failure)}

  defp backup_status_dto(
         %{
           operation_id: operation_id,
           vault_id: vault_id,
           status: status,
           requested_at: %DateTime{} = requested_at,
           updated_at: %DateTime{} = updated_at
         } = record,
         %SessionContext{vault_id: vault_id},
         operation_id
       )
       when not is_struct(record) and map_size(record) == 5 and status in @backup_statuses do
    if valid_datetime?(requested_at) and valid_datetime?(updated_at) do
      {:ok,
       %BackupStatus{
         operation_id: operation_id,
         status: status,
         requested_at: requested_at,
         updated_at: updated_at
       }}
    else
      {:error, :integrity_failure}
    end
  end

  defp backup_status_dto(_record, _context, _operation_id),
    do: {:error, :integrity_failure}

  defp validate_session(values, module) do
    valid? =
      valid_uuid?(values[:session_id]) and
        (is_nil(values[:account_id]) or valid_uuid?(values[:account_id])) and
        valid_uuid?(values[:principal_id]) and valid_uuid?(values[:vault_id]) and
        valid_datetime?(values[:expires_at]) and
        valid_epoch?(values[:principal_authorization_epoch]) and
        valid_epoch?(values[:vault_authorization_epoch]) and
        valid_epoch?(values[:authorization_epoch]) and
        is_boolean(values[:unlocked?])

    if valid?, do: {:ok, struct!(module, values)}, else: {:error, :integrity_failure}
  end

  defp normalize_session_map(session) do
    %{
      session_id: Map.get(session, :session_id, Map.get(session, :id)),
      account_id: Map.get(session, :account_id),
      principal_id: Map.get(session, :principal_id),
      vault_id: Map.get(session, :vault_id),
      expires_at: Map.get(session, :expires_at),
      principal_authorization_epoch: Map.get(session, :principal_authorization_epoch),
      vault_authorization_epoch: Map.get(session, :vault_authorization_epoch),
      authorization_epoch:
        Map.get(
          session,
          :authorization_epoch,
          Map.get(session, :principal_authorization_epoch)
        ),
      unlocked?: Map.get(session, :unlocked?, false)
    }
  end

  defp search_page_dto(%{items: items, next_cursor: next_cursor})
       when is_list(items) and
              (is_binary(next_cursor) or is_nil(next_cursor)) do
    with {:ok, summaries} <- map_summaries(items) do
      {:ok, %SearchPage{items: summaries, next_cursor: next_cursor}}
    end
  end

  defp search_page_dto(_page), do: {:error, :integrity_failure}

  defp authorized_asset_summary(item, context, asset_id)
       when is_map(item) do
    projected_asset_id = Map.get(item, :asset_id, Map.get(item, :id))

    if item[:vault_id] == context.vault_id and
         projected_asset_id == asset_id do
      asset_summary_dto(item)
    else
      {:error, :integrity_failure}
    end
  end

  defp authorized_asset_summary(_item, _context, _asset_id),
    do: {:error, :integrity_failure}

  defp map_summaries(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, summaries} ->
      case asset_summary_dto(item) do
        {:ok, summary} -> {:cont, {:ok, [summary | summaries]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, summaries} -> {:ok, Enum.reverse(summaries)}
      error -> error
    end
  end

  defp asset_summary_dto(item) when is_map(item) do
    values = %{
      id: Map.get(item, :id, Map.get(item, :asset_id)),
      resource_version_id: Map.get(item, :resource_version_id),
      title: Map.get(item, :title, Map.get(item, :resource_title)),
      original_filename: Map.get(item, :original_filename),
      detected_media_type: Map.get(item, :detected_media_type),
      state: Map.get(item, :state),
      state_revision: Map.get(item, :state_revision),
      label:
        classification_label(Map.get(item, :classification)) ||
          Map.get(item, :label),
      progress: Map.get(item, :progress),
      failure: Map.get(item, :failure),
      updated_at: Map.get(item, :updated_at)
    }

    valid? =
      valid_uuid?(values.id) and valid_uuid?(values.resource_version_id) and
        nonblank?(values.title) and nonblank?(values.original_filename) and
        values.detected_media_type in [nil | @safe_media_types] and
        values.state in @asset_states and
        valid_epoch?(values.state_revision) and
        values.label in @classification_labels and
        valid_progress?(values.progress) and valid_failure?(values.failure) and
        is_struct(values.updated_at, DateTime)

    if valid?,
      do: {:ok, struct!(AssetSummary, values)},
      else: {:error, :integrity_failure}
  end

  defp asset_summary_dto(_item), do: {:error, :integrity_failure}

  defp classification_label(classification)
       when classification in @classifications,
       do: Atom.to_string(classification)

  defp classification_label(_classification), do: nil

  defp valid_progress?(nil), do: true

  defp valid_progress?(%{kind: :bytes, sent: sent, total: total} = progress)
       when map_size(progress) == 3 and is_integer(sent) and sent >= 0 and
              is_integer(total) and total >= sent,
       do: true

  defp valid_progress?(%{kind: kind} = progress)
       when map_size(progress) == 1 and
              kind in [:indeterminate, :complete, :waiting_for_unlock],
       do: true

  defp valid_progress?(_progress), do: false

  defp valid_failure?(nil), do: true

  defp valid_failure?(
         %{
           code: code,
           retryable: retryable,
           operation: operation,
           attempt: attempt
         } = failure
       )
       when map_size(failure) == 4 and code in @failure_codes and
              is_boolean(retryable) and is_binary(operation) and
              byte_size(operation) > 0 and is_integer(attempt) and attempt >= 0,
       do: true

  defp valid_failure?(_failure), do: false

  defp upload_grant_dto(grant) when is_map(grant) do
    values = %{
      grant_id: Map.get(grant, :grant_id, Map.get(grant, :id)),
      asset_id: Map.get(grant, :asset_id),
      filename: Map.get(grant, :filename),
      byte_size: Map.get(grant, :byte_size),
      declared_media_type: Map.get(grant, :declared_media_type),
      classification: Map.get(grant, :classification),
      expires_at: Map.get(grant, :expires_at)
    }

    valid? =
      valid_uuid?(values.grant_id) and valid_uuid?(values.asset_id) and
        nonblank?(values.filename) and valid_epoch?(values.byte_size) and
        values.declared_media_type in @safe_media_types and
        values.classification in [:private, :sensitive, :restricted] and
        is_struct(values.expires_at, DateTime)

    if valid?,
      do: {:ok, struct!(UploadGrant, values)},
      else: {:error, :integrity_failure}
  end

  defp upload_grant_dto(_grant), do: {:error, :integrity_failure}

  defp grant_token(grant) when is_map(grant) do
    case Map.get(grant, :token) do
      token when is_binary(token) and byte_size(token) > 0 -> {:ok, token}
      _invalid -> {:error, :integrity_failure}
    end
  end

  defp grant_token(_grant), do: {:error, :integrity_failure}

  defp upload_selector(config, context, grant_id, request) do
    with true <- context.unlocked?,
         true <- valid_uuid?(grant_id),
         {:ok, upload_token} <-
           decode_token(Map.get(request, :upload_token)),
         {:ok, csrf_token} <- csrf_token(Map.get(request, :csrf_token)),
         content_length when is_integer(content_length) and content_length >= 0 <-
           Map.get(request, :content_length),
         :ok <- validate_content_length(config, content_length),
         {:ok, declared_media_type} <-
           upload_media_type(Map.get(request, :declared_media_type)) do
      {:ok,
       %{
         grant_id: grant_id,
         session_id: context.session_id,
         principal_id: context.principal_id,
         vault_id: context.vault_id,
         token_digest: :crypto.hash(:sha256, upload_token),
         csrf_token_digest: :crypto.hash(:sha256, csrf_token),
         request_content_length: content_length,
         request_declared_media_type: declared_media_type
       }}
    else
      {:error, reason}
      when reason in [:invalid, :upload_too_large, :unsupported_media_type] ->
        {:error, reason}

      false ->
        {:error, :invalid}

      nil ->
        {:error, :invalid}

      _invalid ->
        {:error, :invalid}
    end
  end

  defp upload_media_type(media_type) when media_type in @safe_media_types,
    do: {:ok, media_type}

  defp upload_media_type(media_type) when is_binary(media_type),
    do: {:error, :unsupported_media_type}

  defp upload_media_type(_media_type), do: {:error, :invalid}

  defp validate_content_length(config, content_length) do
    max_upload_bytes =
      Map.get(
        config,
        :max_upload_bytes,
        Application.get_env(
          :singularity_runtime,
          :max_upload_bytes,
          512 * 1024 * 1024
        )
      )

    cond do
      not is_integer(max_upload_bytes) or max_upload_bytes < 0 ->
        {:error, :invalid}

      content_length > max_upload_bytes ->
        {:error, :upload_too_large}

      true ->
        :ok
    end
  end

  defp internal_upload_grant(descriptor, selector) when is_map(descriptor) do
    if credential_fields_absent?(descriptor) do
      grant =
        Map.merge(
          descriptor,
          Map.take(selector, [
            :token_digest,
            :csrf_token_digest,
            :request_content_length,
            :request_declared_media_type
          ])
        )

      exact? =
        Map.get(grant, :grant_id, Map.get(grant, :id)) ==
          selector.grant_id and
          grant.session_id == selector.session_id and
          grant.principal_id == selector.principal_id and
          grant.vault_id == selector.vault_id

      if exact?, do: {:ok, grant}, else: {:error, :integrity_failure}
    else
      {:error, :integrity_failure}
    end
  end

  defp internal_upload_grant(_descriptor, _selector),
    do: {:error, :integrity_failure}

  defp upload_identity(%{vault_id: vault_id, asset_id: asset_id}) do
    if valid_uuid?(vault_id) and valid_uuid?(asset_id),
      do: {:ok, vault_id, asset_id},
      else: {:error, :integrity_failure}
  end

  defp upload_identity(_grant), do: {:error, :integrity_failure}

  defp credential_fields_absent?(descriptor) do
    Enum.all?(
      [
        :token,
        "token",
        :upload_token,
        "upload_token",
        :csrf_token,
        "csrf_token",
        :token_digest,
        "token_digest",
        :csrf_token_digest,
        "csrf_token_digest"
      ],
      &(not Map.has_key?(descriptor, &1))
    )
  end

  defp download_metadata(%{
         plaintext_byte_size: total,
         detected_media_type: media_type
       })
       when is_integer(total) and total >= 0 and is_binary(media_type),
       do: {:ok, total, media_type}

  defp download_metadata(_descriptor), do: {:error, :integrity_failure}

  defp download_range(nil, total),
    do: {:ok, :all, 200, nil, total}

  defp download_range("bytes=" <> specification, total) do
    case String.split(specification, "-", parts: 2) do
      [first, last] ->
        with {first, ""} when first >= 0 <- Integer.parse(first),
             {last, ""} when last >= first <- Integer.parse(last),
             true <- last < total do
          {:ok, first..last//1, 206, "bytes #{first}-#{last}/#{total}", last - first + 1}
        else
          _invalid -> {:error, :range_not_satisfiable}
        end

      _invalid ->
        {:error, :range_not_satisfiable}
    end
  end

  defp download_range(_range_header, _total),
    do: {:error, :range_not_satisfiable}

  defp decode_token(token) when is_binary(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, <<_::binary-size(32)>> = decoded} -> {:ok, decoded}
      _invalid -> {:error, :invalid}
    end
  end

  defp decode_token(_token), do: {:error, :invalid}

  defp csrf_token(token)
       when is_binary(token) and byte_size(token) > 0 and
              byte_size(token) <= 1_024,
       do: {:ok, token}

  defp csrf_token(_token), do: {:error, :invalid}

  defp safe_media_type(media_type) when media_type in @safe_media_types,
    do: media_type

  defp safe_media_type(_media_type), do: "application/octet-stream"

  defp normalize_upload_unit(:ok), do: :ok
  defp normalize_upload_unit({:ok, _value}), do: :ok
  defp normalize_upload_unit(result), do: normalize_upload_error(result)

  defp upload_response(result, expected_vault_id, expected_asset_id)
       when is_map(result) and map_size(result) == 2 do
    case result do
      %{
        asset: %StoredAsset{
          id: ^expected_asset_id,
          vault_id: ^expected_vault_id,
          state: :uploaded,
          state_revision: state_revision
        },
        stage: %AssetStage{
          asset_id: ^expected_asset_id,
          vault_id: ^expected_vault_id,
          state: :sealed
        }
      } ->
        if valid_uuid?(expected_asset_id) and valid_uuid?(expected_vault_id) and
             valid_epoch?(state_revision) do
          {:ok,
           %{
             asset_id: expected_asset_id,
             state: :uploaded,
             state_revision: state_revision
           }}
        else
          {:error, :integrity_failure}
        end

      _invalid ->
        {:error, :integrity_failure}
    end
  end

  defp upload_response(_result, _expected_vault_id, _expected_asset_id),
    do: {:error, :integrity_failure}

  defp validate_asset_mutation(asset_id, state_revision) do
    if valid_uuid?(asset_id) and valid_epoch?(state_revision),
      do: :ok,
      else: {:error, :invalid}
  end

  defp normalize_delete_result(
         {:ok,
          %{
            id: asset_id,
            state: state,
            state_revision: state_revision
          }},
         asset_id
       )
       when state in [:pending_delete, :deleted] and
              is_integer(state_revision) and state_revision >= 0,
       do: {:ok, true}

  defp normalize_delete_result(
         {:error,
          %Error{
            code: :conflict,
            details: %{reason: reason}
          }},
         _asset_id
       )
       when reason in [
              :state_revision_mismatch,
              "state_revision_mismatch"
            ],
       do: {:ok, false}

  defp normalize_delete_result({:ok, _invalid}, _asset_id),
    do: {:error, :integrity_failure}

  defp normalize_delete_result(result, _asset_id),
    do: normalize_error(result)

  defp normalize_cancel_upload_result(
         {:ok,
          %{
            status: :cancelled,
            grant_id: grant_id,
            asset_id: asset_id,
            vault_id: vault_id
          } = result},
         config,
         context,
         expected_grant_id
       )
       when map_size(result) == 4 do
    with {:ok, ^expected_grant_id} <- Ecto.UUID.cast(grant_id),
         {:ok, asset_id} <- Ecto.UUID.cast(asset_id),
         {:ok, vault_id} <- Ecto.UUID.cast(vault_id),
         true <- vault_id == context.vault_id do
      publish_asset(config, context.vault_id, asset_id)
      {:ok, true}
    else
      _invalid -> {:error, :integrity_failure}
    end
  end

  defp normalize_cancel_upload_result(
         {:ok,
          %{
            status: status,
            grant_id: grant_id,
            asset_id: asset_id,
            vault_id: vault_id
          } = result},
         _config,
         context,
         expected_grant_id
       )
       when status in [:in_progress, :retired] and map_size(result) == 4 do
    with {:ok, ^expected_grant_id} <- Ecto.UUID.cast(grant_id),
         {:ok, _asset_id} <- Ecto.UUID.cast(asset_id),
         {:ok, vault_id} <- Ecto.UUID.cast(vault_id),
         true <- vault_id == context.vault_id do
      {:ok, false}
    else
      _invalid -> {:error, :integrity_failure}
    end
  end

  defp normalize_cancel_upload_result(
         {:ok, _invalid},
         _config,
         _context,
         _grant_id
       ),
       do: {:error, :integrity_failure}

  defp normalize_cancel_upload_result(result, _config, _context, _grant_id),
    do: normalize_error(result)

  defp publish_asset(config, vault_id, asset_id) do
    _notification =
      invoke(config, :publish_asset, [vault_id, asset_id])

    :ok
  end

  defp normalize_error({:error, %Error{code: code}}) when code in @stable_errors,
    do: {:error, code}

  defp normalize_error({:error, %Error{}}), do: {:error, :storage_unavailable}

  defp normalize_error({:error, code}) when code in @stable_errors,
    do: {:error, code}

  defp normalize_error({:error, _reason}), do: {:error, :storage_unavailable}
  defp normalize_error(_invalid), do: {:error, :storage_unavailable}

  defp normalize_upload_error({:error, %Error{code: :not_found}}),
    do: {:error, :forbidden}

  defp normalize_upload_error(
         {:error,
          %Error{
            code: :invalid,
            details: %{reason: reason}
          }}
       )
       when reason in [:size_mismatch, "size_mismatch"],
       do: {:error, :integrity_failure}

  defp normalize_upload_error({:error, :size_mismatch}),
    do: {:error, :integrity_failure}

  defp normalize_upload_error(result), do: normalize_error(result)

  defp invoke(config, key, arguments) do
    case Map.get(config, key) do
      function when is_function(function) ->
        apply(function, arguments)

      _missing ->
        {:error, :invalid}
    end
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    _kind, _reason -> {:error, :storage_unavailable}
  end

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, arguments)

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, [context | arguments])

  defp with_production(callback) do
    callback.(production_config())
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    _kind, _reason -> {:error, :storage_unavailable}
  end

  defp valid_uuid?(value),
    do: match?({:ok, _uuid}, Ecto.UUID.cast(value))

  defp valid_datetime?(%DateTime{} = value) do
    with encoded when is_binary(encoded) <- DateTime.to_iso8601(value),
         {:ok, ^value, 0} <- DateTime.from_iso8601(encoded) do
      true
    else
      _invalid -> false
    end
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp valid_datetime?(_value), do: false

  defp valid_epoch?(value), do: is_integer(value) and value >= 0
  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
end
