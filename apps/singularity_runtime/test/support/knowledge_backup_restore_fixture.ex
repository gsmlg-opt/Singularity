defmodule Singularity.Runtime.KnowledgeBackupRestoreFixture do
  @moduledoc false

  alias Singularity.Runtime.{
    BootstrapOwner,
    KeyCustodian,
    KnowledgeRestoreOracle,
    NativeAssetFixture
  }

  alias Singularity.Storage.Backup.KnowledgeFixtureResourceOwner, as: ResourceOwner
  alias Singularity.Storage.{MigrationRepo, SafeSQL}

  @borrowed_repos [
    Singularity.Storage.RequestRepo,
    Singularity.Storage.PreAuthRepo,
    Singularity.Storage.DispatcherRepo,
    Singularity.Storage.WorkerRepo
  ]
  @retained_children [
    Singularity.Runtime.Observability.Telemetry,
    Singularity.Runtime.AssetEvents.Registry,
    Singularity.Runtime.Assets.UploadReconciler,
    Singularity.Runtime.UploadRecoveryTaskSupervisor,
    Singularity.Runtime.KeyLeaseSupervisor,
    KeyCustodian,
    Singularity.Runtime.UploadSessionSupervisor,
    Singularity.Storage.Jobs.ObanAdapter,
    Singularity.Runtime.OutboxDispatcher
  ]
  @runtime_settings [
    :authorization_dependencies,
    :key_custodian,
    :knowledge_v3_test_observer,
    :knowledge_v3_plaintext_observer,
    :maintenance_mode,
    :start_infrastructure,
    :oban_options,
    :outbox_dispatcher_options
  ]
  @storage_settings [MigrationRepo, :storage_root, :backup_root, :job_handler, Oban] ++
                      @borrowed_repos

  defmodule V3Exporter do
    @moduledoc false

    alias Singularity.Storage.Backup.{Exporter, KnowledgeCanonicalOracle}

    def snapshot_cut(repo, vault_id) do
      with {:ok, cut} <- Exporter.snapshot_cut(repo, vault_id) do
        %{owner: owner, receive_cut: receive_cut} =
          Application.fetch_env!(:singularity_runtime, :knowledge_v3_test_observer)

        observation = KnowledgeCanonicalOracle.capture_worker_cut!(repo, owner, cut)
        :ok = receive_cut.(observation)
        {:ok, cut}
      end
    end

    def records(repo, cut), do: Exporter.records(repo, cut)
  end

  defmodule V3JobHandler do
    @moduledoc false
    @behaviour Singularity.Core.JobHandler

    alias Singularity.Runtime.JobDispatcher

    @impl true
    def dependencies do
      Map.put(
        JobDispatcher.dependencies(),
        :exporter,
        Singularity.Runtime.KnowledgeBackupRestoreFixture.V3Exporter
      )
    end

    @impl true
    def handle(context, envelope), do: JobDispatcher.handle(context, envelope)

    @impl true
    def handle_failure(context, envelope, error, attempt),
      do: JobDispatcher.handle_failure(context, envelope, error, attempt)
  end

  defmodule ObservedRestorer do
    @moduledoc false
    alias Singularity.Storage.Backup.Restorer
    alias Singularity.Runtime.KnowledgeBackupRestoreFixture.ObservedAuthenticator

    def import(context, repo, input) do
      :ok = context.diagnostic.({:native_import, :entered})
      result = Restorer.import(context.restorer, repo, input)

      :ok =
        context.diagnostic.(
          {:native_import, {:returned, ObservedAuthenticator.return_category(result)}}
        )

      case result do
        {:ok, %Restorer.Imported{} = imported} -> :ok = context.after_import.(imported)
        _ -> :ok
      end

      result
    end

    def rewrap_owner(context, imported, password, capability) do
      result = Restorer.rewrap_owner(context.restorer, imported, password, capability)

      case result do
        {:ok, rewrapped} -> :ok = context.after_rewrap.(rewrapped)
        _ -> :ok
      end

      result
    end

    def complete_restore(context, rewrapped) do
      result = Restorer.complete_restore(context.restorer, rewrapped)

      case result do
        :ok -> :ok = context.after_complete.(:ok)
        _ -> :ok
      end

      result
    end
  end

  defmodule ObservedAuthenticator do
    @moduledoc false
    alias Singularity.Runtime.RestoreAuthenticator

    def authenticate_all(context, source, passphrase) do
      :ok = context.diagnostic.({:authenticate, :entered})
      result = RestoreAuthenticator.authenticate_all(context.authenticator, source, passphrase)
      :ok = context.diagnostic.({:authenticate, {:returned, return_category(result)}})

      case {result, Map.fetch(context, :inventory_observer)} do
        {{:ok, authenticated}, {:ok, observe}} ->
          :ok =
            observe.(:authenticated, %{
              cut: authenticated.cut,
              verified_cut: authenticated.verified.cut,
              binding: Map.take(authenticated.binding, [:manifest_id, :vault_id]),
              manifest_hash: authenticated.verified.manifest_hash,
              manifest_tag: authenticated.verified.manifest_tag
            })

        _ ->
          :ok
      end

      result
    end

    def claim_recovered_vault_key(context, authenticated),
      do: RestoreAuthenticator.claim_recovered_vault_key(context.authenticator, authenticated)

    def revoke(context, authenticated),
      do: RestoreAuthenticator.revoke(context.authenticator, authenticated)

    def return_category({:ok, _value}), do: :ok

    def return_category({:error, %Singularity.Core.Error{code: code, retryable?: retryable?}})
        when code in [
               :unauthenticated,
               :vault_locked,
               :forbidden,
               :not_found,
               :conflict,
               :invalid,
               :upload_expired,
               :upload_too_large,
               :unsupported_media_type,
               :integrity_failure,
               :storage_unavailable,
               :job_failed,
               :backup_invalid,
               :backup_unsupported
             ] and is_boolean(retryable?),
        do: {:error, code, retryable?}

    def return_category(_result), do: :unknown
  end

  # Optional compatibility observers never replace native authority or material.
  defmodule ObservedIntegrityIssuer do
    @moduledoc false
    alias Singularity.Runtime.RestoreIntegrityLease

    def issue(%{observe: observe}, options) do
      {loader, prepared} = options.material_loader

      forwarded =
        Map.put(
          options,
          :material_loader,
          {Singularity.Runtime.KnowledgeBackupRestoreFixture.ObservedMaterialLoader,
           %{loader: options.material_loader, observe: observe}}
        )

      :ok =
        observe.(:issue, %{
          inventory: options.inventory,
          binding: options.binding,
          owner_is_caller?: options.owner == self(),
          options_preserved?:
            Map.delete(forwarded, :material_loader) === Map.delete(options, :material_loader),
          key_shape?: is_binary(options.vault_key) and byte_size(options.vault_key) == 32,
          storage: options.object_storage,
          key_wrapper: options.key_wrapper,
          ttl_ms: options.ttl_ms,
          loader: loader,
          prepared:
            Map.take(prepared, [
              :repo,
              :storage,
              :original,
              :projected,
              :binding,
              :manifest_hash,
              :manifest_tag,
              :inventory_hash,
              :root_hash
            ])
        })

      result = RestoreIntegrityLease.issue(forwarded)
      :ok = observe.(:issued, match?({:ok, %RestoreIntegrityLease.Capability{}}, result))
      result
    end

    def revoke(_context, capability), do: RestoreIntegrityLease.revoke(capability)
  end

  defmodule ObservedMaterialLoader do
    @moduledoc false

    def load_plaintext_material(%{loader: {module, context}, observe: observe}, binding, entry) do
      result = module.load_plaintext_material(context, binding, entry)

      case result do
        {:ok, material} ->
          :ok =
            observe.(:material, %{
              binding: binding,
              entry: entry,
              format_version: material.format_version,
              material:
                Map.take(material, [
                  :object_id,
                  :vault_id,
                  :key_domain_id,
                  :classification,
                  :lookup_digest,
                  :ciphertext_hash,
                  :ciphertext_byte_size,
                  :vault_key_version_id,
                  :vault_key_generation
                ])
            })

        _ ->
          :ok
      end

      result
    end
  end

  defmodule ObservedCiphertextAudit do
    @moduledoc false

    def verify_ciphertext(%{observe: observe} = context, storage, vault_id, inventory) do
      result =
        Singularity.Storage.Backup.IntegrityAudit.verify_ciphertext(storage, vault_id, inventory)

      case result do
        {:ok, summary} ->
          :ok =
            observe.(:ciphertext, %{
              storage: storage,
              vault_id: vault_id,
              inventory: inventory,
              summary: summary
            })

        _ ->
          :ok
      end

      case Map.fetch(context, :ciphertext_result_observer) do
        {:ok, observe_result} -> :ok = observe_result.(result)
        :error -> :ok
      end

      result
    end
  end

  # BEGIN Task9 transparent native reader observation.
  defmodule ObservedReaderIssuer do
    @moduledoc false
    alias Singularity.Runtime.KnowledgeBackupRestoreFixture.{
      ObservedIntegrityIssuer,
      ObservedReaderStorage
    }

    def issue(context, options) do
      {Singularity.Storage.LocalFilesystemAdapter, storage_context} = options.object_storage

      storage =
        {ObservedReaderStorage,
         Map.merge(storage_context, %{
           observe: context.reader_observer,
           object_id: context.object_id
         })}

      forwarded = Map.replace!(options, :object_storage, storage)

      if Map.delete(forwarded, :object_storage) !== Map.delete(options, :object_storage) do
        raise ArgumentError, "reader observer changed native authority request"
      end

      ObservedIntegrityIssuer.issue(%{observe: context.observe}, forwarded)
    end

    def revoke(context, capability), do: ObservedIntegrityIssuer.revoke(context, capability)
  end

  defmodule ObservedReaderStorage do
    @moduledoc false
    alias Singularity.Storage.LocalFilesystemAdapter
    alias Singularity.Storage.Crypto.Format

    def stat(context, ref) do
      result = LocalFilesystemAdapter.stat(native_context(context), ref)

      case result do
        {:ok, stat} when ref.object_id == context.object_id ->
          :ok =
            context.observe.(:stat, %{byte_size: stat.byte_size, sha256: stat.ciphertext_hash})

        _ ->
          :ok
      end

      result
    end

    def open(context, ref) do
      result = LocalFilesystemAdapter.open(native_context(context), ref)

      if ref.object_id == context.object_id and match?({:ok, _}, result) do
        :ok = context.observe.(:open, :ok)
      end

      result
    end

    def read_range(context, handle, range) do
      result = LocalFilesystemAdapter.read_range(native_context(context), handle, range)

      if handle.object_ref.object_id == context.object_id and
           range == 0..(Format.header_size() - 1) do
        case result do
          {:ok, header} ->
            case Format.split_header(header) do
              {:ok, ^header, "", parsed} ->
                :ok =
                  context.observe.(
                    :header,
                    Map.take(parsed, [:vault_id, :encryption_domain_id, :object_id])
                  )

              _ ->
                :ok = context.observe.(:header, :invalid)
            end

          _ ->
            :ok
        end
      end

      result
    end

    defp native_context(context), do: Map.drop(context, [:observe, :object_id])
  end

  # END Task9 transparent native reader observation.

  defmodule ObservedRuntimeIntegrity do
    @moduledoc false
    alias Singularity.Runtime.{IntegrityAudit, KnowledgeRestoreOracle}

    def verify_ciphertext(context, rewrapped) do
      :ok =
        context.observe.(:saga_ciphertext, KnowledgeRestoreOracle.inventory_handoff(rewrapped))

      IntegrityAudit.verify_ciphertext(context.integrity, rewrapped)
    end

    def verify_plaintext_and_search(context, rewrapped) do
      :ok = context.observe.(:saga_plaintext, KnowledgeRestoreOracle.inventory_handoff(rewrapped))
      IntegrityAudit.verify_plaintext_and_search(context.integrity, rewrapped)
    end

    def revoke(context, rewrapped), do: IntegrityAudit.revoke(context.integrity, rewrapped)
  end

  defmodule ObservedIntegrityLease do
    @moduledoc false
    alias Singularity.Runtime.RestoreIntegrityLease

    def verify_all(capability) do
      result = RestoreIntegrityLease.verify_all(capability)

      case result do
        {:ok, %RestoreIntegrityLease.PlaintextSummary{} = summary} ->
          observer =
            Application.fetch_env!(:singularity_runtime, :knowledge_v3_plaintext_observer)

          :ok = observer.(summary)

        _ ->
          :ok
      end

      result
    end

    def revoke(capability), do: RestoreIntegrityLease.revoke(capability)
  end

  defmodule ObservedNativeIntegrityLease do
    @moduledoc false
    alias Singularity.Runtime.KnowledgeBackupRestoreFixture.{
      ObservedAuthenticator,
      ObservedIntegrityLease
    }

    def verify_all(%{observe: observe}, capability) do
      :ok = observe.(:entered, :ok)
      result = ObservedIntegrityLease.verify_all(capability)
      :ok = observe.(:returned, ObservedAuthenticator.return_category(result))
      result
    end

    def revoke(_context, capability), do: ObservedIntegrityLease.revoke(capability)
  end

  defmodule ObservedKnowledgeAudit do
    @moduledoc false
    alias Singularity.Storage.Backup.KnowledgeIntegrityAudit

    def verify_document_sources(context, binding, inventory, plaintext_hashes) do
      :ok = context.before_documents.(binding, inventory, plaintext_hashes)

      KnowledgeIntegrityAudit.verify_document_sources(
        context.repo,
        binding,
        inventory,
        plaintext_hashes
      )
    end

    def rebuild(context, binding) do
      :ok = context.before_rebuild.(binding)
      result = KnowledgeIntegrityAudit.rebuild(context.repo, binding)

      case result do
        {:ok, summary} -> :ok = context.after_rebuild.(summary)
        _ -> :ok
      end

      result
    end
  end

  def restore_context(destination, portable_root, hooks, faults) do
    bootstrap = Application.fetch_env!(:singularity_runtime, :bootstrap_owner)
    storage = Singularity.Runtime.StorageAdapter.configured()

    hooks =
      Map.merge(
        Map.new(
          [:after_import, :after_rewrap, :after_complete, :diagnostic],
          &{&1, fn _ -> :ok end}
        ),
        hooks
      )

    authenticator = %{
      backup_cipher: Singularity.Storage.Crypto.ChunkedAEAD,
      backup_key_deriver: Singularity.Storage.Crypto.BackupKeyDeriver,
      backup_key_lease: Singularity.Runtime.BackupKeyLease,
      bundle_reader: Singularity.Storage.Backup.BundleReader,
      destination: {Singularity.Storage.Backup.LocalDestination, %{backup_root: portable_root}},
      logical_verifier: Singularity.Storage.Backup.LogicalBundleVerifier,
      recovered_vault_key: Singularity.Storage.Crypto.RecoveredVaultKey,
      restore_crypto_adapter: Singularity.Runtime.BackupKeyLease.StorageAdapter,
      restore_key_ttl_ms: :timer.minutes(5)
    }

    restorer = %{
      integrity_issuer: Singularity.Runtime.RestoreIntegrityLease,
      integrity_ttl_ms: :timer.minutes(5),
      key_deriver: bootstrap.key_deriver,
      key_wrapper: bootstrap.key_wrapper,
      migration_repo: MigrationRepo,
      object_storage: storage,
      password_hasher: bootstrap.password_hasher,
      password_hasher_context: bootstrap.password_hasher_context,
      random_bytes: bootstrap.random_bytes,
      recovered_vault_key: Singularity.Storage.Crypto.RecoveredVaultKey,
      vault_kdf_params: bootstrap.vault_kdf_params
    }

    integrity = %{
      audit: {Singularity.Storage.Backup.IntegrityAudit, MigrationRepo},
      ciphertext_auditor: Singularity.Storage.Backup.IntegrityAudit,
      object_storage: storage,
      restore_integrity_lease: __MODULE__.ObservedIntegrityLease,
      search_rebuilder: {Singularity.Storage.Backup.KnowledgeIntegrityAudit, MigrationRepo}
    }

    integrity =
      if Enum.any?([:before_documents, :before_rebuild, :after_rebuild], &Map.has_key?(hooks, &1)) do
        audit = %{
          repo: MigrationRepo,
          before_documents: Map.get(hooks, :before_documents, fn _, _, _ -> :ok end),
          before_rebuild: Map.get(hooks, :before_rebuild, fn _ -> :ok end),
          after_rebuild: Map.get(hooks, :after_rebuild, fn _ -> :ok end)
        }

        Map.put(integrity, :search_rebuilder, {__MODULE__.ObservedKnowledgeAudit, audit})
      else
        integrity
      end

    integrity =
      case Map.fetch(hooks, :native_lease_observer) do
        {:ok, observe} ->
          Map.put(
            integrity,
            :restore_integrity_lease,
            {__MODULE__.ObservedNativeIntegrityLease, %{observe: observe}}
          )

        :error ->
          integrity
      end

    observed_authenticator = %{authenticator: authenticator, diagnostic: hooks.diagnostic}

    {restorer, integrity_adapter, observed_authenticator} =
      case Map.fetch(hooks, :inventory_observer) do
        {:ok, observe} ->
          observed_restorer =
            Map.put(
              restorer,
              :integrity_issuer,
              {__MODULE__.ObservedIntegrityIssuer, %{observe: observe}}
            )

          observed_integrity =
            Map.put(
              integrity,
              :ciphertext_auditor,
              {__MODULE__.ObservedCiphertextAudit,
               Map.merge(%{observe: observe}, Map.take(hooks, [:ciphertext_result_observer]))}
            )

          {observed_restorer,
           {__MODULE__.ObservedRuntimeIntegrity,
            %{integrity: observed_integrity, observe: observe}},
           Map.put(observed_authenticator, :inventory_observer, observe)}

        :error ->
          {restorer, {Singularity.Runtime.IntegrityAudit, integrity}, observed_authenticator}
      end

    # BEGIN Task9 optional native reader observation selection.
    restorer =
      case Map.fetch(hooks, :reader_observer) do
        {:ok, observe_reader} ->
          Map.put(
            restorer,
            :integrity_issuer,
            {__MODULE__.ObservedReaderIssuer,
             %{
               observe: Map.fetch!(hooks, :inventory_observer),
               reader_observer: observe_reader,
               object_id: Map.fetch!(hooks, :reader_object_id)
             }}
          )

        :error ->
          restorer
      end

    # END Task9 optional native reader observation selection.

    context = %{
      authenticator: {__MODULE__.ObservedAuthenticator, observed_authenticator},
      destination:
        {Mix.Tasks.Singularity.Test.Restore.OracleDestination,
         %{backup_root: portable_root, storage_root: destination.object_root}},
      integrity: integrity_adapter,
      maintenance_mode: {Mix.Tasks.Singularity.Test.Restore.OracleMaintenanceMode, true},
      migration_repo: MigrationRepo,
      reconciler: {Singularity.Storage.Backup.Reconciler, MigrationRepo},
      restorer: {__MODULE__.ObservedRestorer, Map.put(hooks, :restorer, restorer)}
    }

    Map.merge(context, faults)
  end

  def retained_originals!(source) do
    Enum.map(source.sources, fn {_name, original} ->
      row =
        one_observation!(
          """
          SELECT e.key_generation FROM content.asset_objects o
          JOIN content.asset_key_envelopes e ON e.asset_object_id=o.id AND e.vault_id=o.vault_id
            AND e.key_domain_id=o.key_domain_id
          JOIN core.domain_key_versions d ON d.id=e.domain_key_version_id
            AND d.key_domain_id=o.key_domain_id AND d.vault_id=o.vault_id
            AND d.generation=e.key_generation AND d.state='active'
          JOIN core.key_domains k ON k.id=o.key_domain_id AND k.vault_id=o.vault_id
            AND k.kind='content' AND k.state='active'
          WHERE o.id=$1 AND o.vault_id=$2 AND o.lifecycle='available' AND o.deleted_at IS NULL
          """,
          [dump(original.object_id), dump(source.owner.vault_id)]
        )

      %{
        asset_id: original.asset_id,
        object_id: original.object_id,
        object_generation: row["key_generation"],
        bytes: original.bytes
      }
    end)
  end

  # The caller owns a newly allocated private portability directory. Only its
  # explicit callback result crosses this synchronously closed source lifetime.
  def with_source(portable_root, fun) when is_function(fun, 1) do
    saved = save_settings()

    try do
      require_private_directory!(portable_root)
      {owner, destination} = ResourceOwner.open(migration_pool_size: 2)

      try do
        credentials = bootstrap!()
        configure_runtime!(destination)
        {:ok, observer} = Agent.start_link(fn -> %{count: 0, observation: nil} end)

        try do
          Application.put_env(:singularity_runtime, :knowledge_v3_test_observer, %{
            owner: credentials.owner,
            receive_cut: fn observation ->
              Agent.update(observer, fn state ->
                %{count: state.count + 1, observation: observation}
              end)
            end
          })

          runtime = start_controlled_runtime!(owner, destination)
          session = NativeAssetFixture.login!(credentials)

          lifecycle =
            lifecycle(destination, runtime.infrastructure, runtime.repositories, observer)

          fun.(
            Map.merge(runtime, %{
              portable_root: portable_root,
              credentials: credentials,
              session: session,
              lifecycle: lifecycle,
              snapshot_observation: fn -> Agent.get(observer, & &1) end
            })
          )
        after
          if Process.alive?(observer), do: Agent.stop(observer)
        end
      after
        ResourceOwner.close(owner)
      end
    after
      restore_settings(saved)
    end
  end

  # Admission precedes open/1: a live source must never be paused to manufacture
  # a destination. The completion-only ResourceOwner receipt is not a resource.
  def with_destination(source, fun) when is_function(fun, 1) do
    saved = save_settings()

    try do
      require_closed_source!(source)
      {owner, destination} = ResourceOwner.open(migration_pool_size: 2)

      try do
        require!(
          destination.database != source.database,
          "knowledge destination reused source database"
        )

        require!(
          File.ls!(destination.object_root) == [],
          "knowledge destination object root is not empty"
        )

        configure_runtime!(destination)
        Application.put_env(:singularity_runtime, :maintenance_mode, true)
        Application.put_env(:singularity_runtime, :start_infrastructure, false)
        repositories = NativeAssetFixture.repo_identities()

        require!(
          is_nil(Process.whereis(KeyCustodian)) and
            is_nil(Process.whereis(Singularity.Runtime.OutboxDispatcher)) and
            is_nil(Oban.whereis(Singularity.Oban)),
          "knowledge destination started ordinary runtime before restore"
        )

        fun.(%{
          owner: owner,
          destination: destination,
          infrastructure: nil,
          repositories: repositories,
          lifecycle: lifecycle(destination, nil, repositories, nil)
        })
      after
        ResourceOwner.close(owner)
      end
    after
      restore_settings(saved)
    end
  end

  # Used for source startup and, later, only after genuine restore completion.
  # Configuration already belongs to the current with_source/with_destination.
  def start_controlled_runtime!(owner, destination) do
    Application.put_env(:singularity_runtime, :maintenance_mode, false)
    Application.put_env(:singularity_runtime, :start_infrastructure, true)
    repositories = NativeAssetFixture.repo_identities()
    children = Singularity.Runtime.Application.application_children(composition())
    child_id = &Supervisor.child_spec(&1, []).id
    {removed, retained} = Enum.split_with(children, &(child_id.(&1) in @borrowed_repos))

    require!(
      Enum.sort(Enum.map(removed, child_id)) == Enum.sort(@borrowed_repos),
      "knowledge runtime did not borrow exactly its owned repositories"
    )

    {deferred, infrastructure} =
      Enum.split_with(retained, fn child ->
        child_id.(child) == Singularity.Runtime.Documents.ExtractionReconciler
      end)

    require!(length(deferred) == 1, "knowledge runtime must defer exactly extraction recovery")
    retained_ids = Enum.map(infrastructure, child_id)

    require!(
      Enum.sort(retained_ids) == Enum.sort(@retained_children),
      "knowledge runtime omitted or added an infrastructure child"
    )

    supervisor =
      expect_ok!(ResourceOwner.start_infrastructure(owner, infrastructure), "runtime start")

    require!(
      NativeAssetFixture.repo_identities() == repositories,
      "knowledge runtime replaced an owned repository or database"
    )

    for {_repo, {pid, database}} <- repositories do
      require!(
        Process.alive?(pid) and database == destination.database,
        "knowledge runtime repository belongs to a different destination"
      )
    end

    live_children =
      Map.new(Supervisor.which_children(supervisor), fn {id, pid, _type, _modules} ->
        {id, pid}
      end)

    # UploadReconciler is a synchronous temporary child returning :ignore after
    # real reconciliation; retaining its specification does not invent a PID.
    ignored = Singularity.Runtime.Assets.UploadReconciler

    require!(
      Enum.sort(Map.keys(live_children) -- [ignored]) == Enum.sort(retained_ids -- [ignored]),
      "knowledge runtime running-child inventory differs"
    )

    require!(
      Map.get(live_children, ignored, :undefined) == :undefined,
      "knowledge upload reconciliation did not complete synchronously"
    )

    for {id, pid} <- live_children, id != ignored do
      require!(is_pid(pid) and Process.alive?(pid), "knowledge runtime child is not live")
    end

    require!(
      is_nil(Process.whereis(Singularity.Runtime.Documents.ExtractionReconciler)),
      "knowledge extraction recovery started before canonical observation"
    )

    %{
      owner: owner,
      destination: destination,
      infrastructure: supervisor,
      repositories: repositories,
      deferred_extraction: hd(deferred),
      runtime_child_ids: retained_ids,
      runtime_children: live_children
    }
  end

  # This construction path uses only actual native publication/cleanup/backup.
  # Compatibility modes compose historical aliases only after genuine UUID
  # publication. The portable result holds no live capability or unwrapped key.
  # BEGIN Task9 explicit source-material composition entry.
  def backup_source!(portable_root, reference_mode, metadata_mode \\ :valid)
      when reference_mode in [:uuid, :canonical_compatibility, :mixed_compatibility] and
             metadata_mode in [:valid, :wrong_pdf_size, :wrong_pdf_digest] and
             (metadata_mode == :valid or reference_mode == :uuid) do
    backup_source!(portable_root, reference_mode, metadata_mode, :native)
  end

  def backup_source!(portable_root, reference_mode, metadata_mode, source_material)
      # END Task9 explicit source-material composition entry.
      when reference_mode in [:uuid, :canonical_compatibility, :mixed_compatibility] and
             metadata_mode in [:valid, :wrong_pdf_size, :wrong_pdf_digest] and
             (metadata_mode == :valid or reference_mode == :uuid) do
    source =
      with_source(portable_root, fn fixture ->
        sources = publish_sources!(fixture)
        sources = compose_pdf_metadata!(fixture, sources, metadata_mode)
        native_material_witness = compose_pdf_material!(fixture, sources, source_material)
        reference_witnesses = compose_historical_references!(fixture, sources, reference_mode)
        pdf_before = retained_pdf!(fixture, sources.pdf.object_id)
        hierarchy_before = bootstrap_hierarchy!(fixture.credentials.owner)
        ids = knowledge_ids()
        session = fixture.session
        owner = Map.put(fixture.credentials.owner, :session_id, session.session_id)

        work = %{
          submission_id: "60000000-0000-4000-8000-000000000700",
          principal_authorization_epoch: session.principal_authorization_epoch,
          vault_authorization_epoch: session.vault_authorization_epoch
        }

        Singularity.Storage.Backup.KnowledgeBackupFixtures.seed_graph!(%{
          owner: owner,
          ids: ids,
          sources: sources,
          work: work
        })

        hierarchy_unchanged? = hierarchy_before == bootstrap_hierarchy!(owner)
        require!(hierarchy_unchanged?, "knowledge graph replaced bootstrap key hierarchy")
        seals = source_set_seals!(owner)
        require!(length(seals) == 6, "knowledge graph did not seal every Note version")

        deletions =
          for name <- [:pdf, :pdf_duplicate] do
            delete_pdf!(fixture, Map.fetch!(sources, name))
          end

        retire_metadata!(owner, ids, sources)
        pdf_after = retained_pdf!(fixture, sources.pdf.object_id)
        retention_unchanged? = pdf_before == pdf_after
        require!(retention_unchanged?, "Document pins did not preserve native PDF storage")
        pin_count = document_pin_count!(session, sources.pdf.object_id)
        require!(pin_count == 3, "native PDF does not have three immutable Document pins")

        [[live_references, orphan_events]] =
          observe_rows!(
            """
            SELECT (SELECT count(*) FROM content.assets WHERE vault_id=$1 AND asset_object_id=$2),
              (SELECT count(*) FROM core.outbox_events WHERE vault_id=$1
                AND event_type='object.cleanup_requested' AND payload->>'object_id'=$3)
            """,
            [dump(owner.vault_id), dump(sources.pdf.object_id), sources.pdf.object_id]
          ).rows

        require!(
          live_references == 0 and orphan_events == 0,
          "Document-only PDF retention scheduled orphan cleanup or retained an Asset pointer"
        )

        legacy_errors = legacy_backup_guards!(session)
        passphrase = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

        requested =
          expect_ok!(
            Singularity.Runtime.Api.request_backup(session, passphrase),
            "backup request"
          )

        operation_id = requested.operation_id
        NativeAssetFixture.dispatch!()
        drain_one!(:backup)

        status =
          expect_ok!(
            Singularity.Runtime.Api.backup_status(session, operation_id),
            "backup status"
          )

        require!(
          status.operation_id == operation_id and status.status == :sealed,
          "native knowledge backup did not seal its requested operation"
        )

        observed = fixture.snapshot_observation.()

        require!(
          observed.count == 1 and is_map(observed.observation),
          "native knowledge backup did not capture exactly one actual worker cut"
        )

        observation = observed.observation

        original_inventory =
          KnowledgeRestoreOracle.original_inventory!(observation.rows["content.asset_objects"])

        require!(
          observation.cut.object_inventory == original_inventory,
          "native worker inventory differs from independently observed source SQL"
        )

        manifest =
          one_observation!(
            """
            SELECT id::text, snapshot_id::text, outbox_high_water AS high_water,
              destination_ref, status FROM audit.backup_manifests
            WHERE id=$1 AND vault_id=$2 AND status='sealed'
            """,
            [dump(operation_id), dump(owner.vault_id)]
          )

        require!(
          manifest["snapshot_id"] == observation.cut.snapshot_id and
            manifest["high_water"] == observation.cut.outbox_high_water_mark and
            observation.cut.vault_id == owner.vault_id and
            observation.database == fixture.destination.database,
          "sealed manifest does not bind the actual observed worker cut"
        )

        published =
          expect_ok!(
            Singularity.Storage.Backup.LocalDestination.reader_source(
              %{backup_root: Application.fetch_env!(:singularity_storage, :backup_root)},
              manifest["destination_ref"]
            ),
            "published bundle lookup"
          )

        preserved_ref = operation_id <> ".bundle"
        preserved_path = Path.join(portable_root, preserved_ref)
        require!(not File.exists?(preserved_path), "portable bundle target already exists")
        File.cp!(published.path, preserved_path)
        File.chmod!(preserved_path, 0o600)
        stat = File.lstat!(preserved_path)

        require!(
          stat.type == :regular and stat.size > 0 and
            Bitwise.band(stat.mode, 0o777) == 0o600,
          "portable bundle is not a private nonempty file"
        )

        %{
          reference_mode: reference_mode,
          credentials: fixture.credentials,
          passphrase: passphrase,
          owner: owner,
          ids: ids,
          work: work,
          sources: sources,
          originals: Map.new(sources, fn {name, source} -> {name, source.bytes} end),
          native_inventory: native_inventory!(owner),
          native_material_witness: native_material_witness,
          reference_witnesses: reference_witnesses,
          original_inventory: original_inventory,
          observation: observation,
          canonical_counts:
            Map.new(observation.rows, fn {table, rows} -> {table, length(rows)} end),
          operation_id: operation_id,
          manifest: %{
            id: manifest["id"],
            snapshot_id: manifest["snapshot_id"],
            high_water: manifest["high_water"],
            status: manifest["status"]
          },
          destination_ref: preserved_ref,
          bundle_path: preserved_path,
          lifecycle: fixture.lifecycle,
          source_set_seals: seals,
          deletions: deletions,
          pdf_pin_count: pin_count,
          live_pdf_asset_references: live_references,
          orphan_cleanup_events: orphan_events,
          bootstrap_hierarchy_unchanged?: hierarchy_unchanged?,
          pdf_retention_unchanged?: retention_unchanged?,
          legacy_backup_errors: legacy_errors
        }
      end)

    require_closed_source!(source.lifecycle)
    source
  end

  def set_object_plaintext_size!(owner, object_id, expected_size, replacement_size)
      when is_integer(expected_size) and expected_size >= 0 and is_integer(replacement_size) and
             replacement_size >= 0 do
    result =
      MigrationRepo.transaction(fn ->
        SafeSQL.query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner", [])

        updated =
          SafeSQL.query!(
            MigrationRepo,
            """
            UPDATE content.asset_objects SET plaintext_byte_size=$1
            WHERE id=$2 AND vault_id=$3 AND plaintext_byte_size=$4
            RETURNING plaintext_byte_size
            """,
            [replacement_size, dump(object_id), dump(owner.vault_id), expected_size]
          )

        require!(
          updated.num_rows == 1 and updated.rows == [[replacement_size]],
          "PDF size composition did not update exactly one owned Object at its expected size"
        )

        :ok
      end)

    require!(result == {:ok, :ok}, "PDF size composition did not commit")
    :ok
  end

  # BEGIN Task9 owned native material construction and late format fault.
  def foreign_pdf_witness!(portable_root) do
    witness =
      with_source(portable_root, fn fixture ->
        bytes = "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n"
        upload = NativeAssetFixture.upload!(fixture, "application/pdf", [bytes], "donor.pdf")
        NativeAssetFixture.verify_and_finalize!()
        published = publication!(fixture, upload.asset_id, "donor.pdf", "application/pdf", bytes)
        retained = retained_pdf!(fixture, published.object_id)
        object = retained.object

        {:ok, _header, _records, parsed} =
          Singularity.Storage.Crypto.Format.split_header(retained.ciphertext)

        identity = %{
          vault_id: fixture.session.vault_id,
          object_id: published.object_id,
          key_domain_id: Ecto.UUID.load!(object["key_domain_id"])
        }

        header_identity = Map.take(parsed, [:vault_id, :encryption_domain_id, :object_id])

        require!(
          header_identity == %{
            vault_id: dump(identity.vault_id),
            encryption_domain_id: dump(identity.key_domain_id),
            object_id: dump(identity.object_id)
          },
          "genuine donor header did not bind its published owner, domain and Object"
        )

        %{
          identity: identity,
          header_identity: header_identity,
          ciphertext: retained.ciphertext,
          ciphertext_sha256: object["ciphertext_hash"],
          ciphertext_byte_size: object["ciphertext_byte_size"],
          plaintext_sha256: published.digest,
          plaintext_byte_size: published.byte_size,
          lifecycle: fixture.lifecycle
        }
      end)

    require_closed_source!(witness.lifecycle)
    witness
  end

  def set_object_format!(owner, object_id, expected_format, replacement_format)
      when is_integer(expected_format) and expected_format > 0 and
             is_integer(replacement_format) and replacement_format > 0 do
    result =
      MigrationRepo.transaction(fn ->
        SafeSQL.query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner", [])

        updated =
          SafeSQL.query!(
            MigrationRepo,
            """
            UPDATE content.asset_objects SET format_version=$1
            WHERE id=$2 AND vault_id=$3 AND format_version=$4
            RETURNING format_version
            """,
            [replacement_format, dump(object_id), dump(owner.vault_id), expected_format]
          )

        require!(
          updated.num_rows == 1 and updated.rows == [[replacement_format]],
          "native format fault did not update exactly one expected owned Object"
        )

        :ok
      end)

    require!(result == {:ok, :ok}, "native format fault did not commit")
    :ok
  end

  defp compose_pdf_material!(_fixture, _sources, :native), do: :native

  defp compose_pdf_material!(fixture, sources, donor) when is_map(donor) do
    require_closed_source!(donor.lifecycle)
    owner = fixture.credentials.owner
    root = fixture.destination.object_root
    before_objects = native_inventory!(owner)
    pdf = sources.pdf
    before_pdf = Map.fetch!(before_objects, pdf.object_id)
    entry = physical_entry!(before_pdf)

    before_envelopes =
      observation_maps!(
        "SELECT * FROM content.asset_key_envelopes WHERE vault_id=$1 ORDER BY id",
        [dump(owner.vault_id)]
      )

    before_hierarchy = bootstrap_hierarchy!(owner)

    require!(
      map_size(before_objects) == 5 and sources.pdf_duplicate.object_id == pdf.object_id and
        owner.vault_id != donor.identity.vault_id and pdf.object_id != donor.identity.object_id and
        entry.key_domain_id != donor.identity.key_domain_id and
        pdf.digest == donor.plaintext_sha256 and pdf.byte_size == donor.plaintext_byte_size and
        entry.ciphertext_byte_size == donor.ciphertext_byte_size and
        entry.ciphertext_hash != donor.ciphertext_sha256 and
        :crypto.hash(:sha256, donor.ciphertext) == donor.ciphertext_sha256,
      "foreign composition did not begin with two distinct genuine equal-length PDF publications"
    )

    physical = KnowledgeRestoreOracle.replace_ciphertext!(root, entry, donor.ciphertext)

    result =
      MigrationRepo.transaction(fn ->
        SafeSQL.query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner", [])

        updated =
          SafeSQL.query!(
            MigrationRepo,
            """
            UPDATE content.asset_objects SET ciphertext_hash=$1
            WHERE id=$2 AND vault_id=$3 AND ciphertext_hash=$4
            RETURNING ciphertext_hash
            """,
            [
              donor.ciphertext_sha256,
              dump(pdf.object_id),
              dump(owner.vault_id),
              entry.ciphertext_hash
            ]
          )

        require!(
          updated.num_rows == 1 and updated.rows == [[donor.ciphertext_sha256]],
          "foreign composition did not update exactly one expected owned ciphertext hash"
        )

        :ok
      end)

    require!(result == {:ok, :ok}, "foreign ciphertext evidence composition did not commit")

    expected =
      Map.put(
        before_objects,
        pdf.object_id,
        Map.put(before_pdf, "ciphertext_hash", donor.ciphertext_sha256)
      )

    after_envelopes =
      observation_maps!(
        "SELECT * FROM content.asset_key_envelopes WHERE vault_id=$1 ORDER BY id",
        [dump(owner.vault_id)]
      )

    after_witness =
      KnowledgeRestoreOracle.reference_witness!(
        root,
        Map.replace!(entry, :ciphertext_hash, donor.ciphertext_sha256)
      )

    require!(
      native_inventory!(owner) == expected and before_envelopes == after_envelopes and
        bootstrap_hierarchy!(owner) == before_hierarchy and
        after_witness.ciphertext == donor.ciphertext and
        after_witness.physical == physical.after.physical,
      "foreign composition changed native identity, hierarchy, envelope or physical evidence"
    )

    Map.put(physical, :donor_identity, donor.identity)
  end

  # END Task9 owned native material construction and late format fault.

  defp compose_pdf_metadata!(_fixture, sources, :valid), do: sources

  defp compose_pdf_metadata!(fixture, sources, metadata_mode) do
    owner = fixture.credentials.owner
    root = fixture.destination.object_root
    before_objects = native_inventory!(owner)
    pdf = sources.pdf
    duplicate = sources.pdf_duplicate
    actual_size = byte_size(pdf.bytes)
    actual_digest = :crypto.hash(:sha256, pdf.bytes)

    require!(
      map_size(before_objects) == 5 and pdf.object_id == duplicate.object_id and
        pdf.bytes == duplicate.bytes and pdf.byte_size == actual_size and
        duplicate.byte_size == actual_size and pdf.digest == actual_digest and
        duplicate.digest == actual_digest,
      "PDF metadata composition did not begin with genuine shared publication"
    )

    before_pdf = Map.fetch!(before_objects, pdf.object_id)
    before_physical = KnowledgeRestoreOracle.reference_witness!(root, physical_entry!(before_pdf))

    envelopes = fn ->
      observe_rows!(
        "SELECT * FROM content.asset_key_envelopes WHERE vault_id=$1 ORDER BY id",
        [dump(owner.vault_id)]
      ).rows
    end

    before_envelopes = envelopes.()

    {field, replacement, expected_objects} =
      case metadata_mode do
        :wrong_pdf_size ->
          :ok = set_object_plaintext_size!(owner, pdf.object_id, actual_size, actual_size + 1)
          changed_pdf = Map.put(before_pdf, "plaintext_byte_size", actual_size + 1)
          {:byte_size, actual_size + 1, Map.put(before_objects, pdf.object_id, changed_pdf)}

        :wrong_pdf_digest ->
          <<first, rest::binary>> = actual_digest
          wrong_digest = <<Bitwise.bxor(first, 1), rest::binary>>
          {:digest, wrong_digest, before_objects}
      end

    require!(
      native_inventory!(owner) == expected_objects and envelopes.() == before_envelopes and
        KnowledgeRestoreOracle.reference_witness!(root, physical_entry!(before_pdf)) ==
          before_physical,
      "PDF metadata composition changed native storage beyond the selected plaintext size"
    )

    Enum.reduce([:pdf, :pdf_duplicate], sources, fn name, composed ->
      Map.update!(composed, name, &Map.replace!(&1, field, replacement))
    end)
  end

  defp compose_historical_references!(_fixture, _sources, :uuid), do: :ok

  defp compose_historical_references!(fixture, sources, reference_mode) do
    owner = fixture.credentials.owner
    root = fixture.destination.object_root
    before_objects = native_inventory!(owner)
    require!(map_size(before_objects) == 5, "historical source does not own five objects")

    require!(
      Singularity.Runtime.StorageAdapter.configured() ==
        {Singularity.Storage.LocalFilesystemAdapter, %{root: root}},
      "historical source requires actual local adapter"
    )

    envelopes = fn ->
      observe_rows!(
        "SELECT * FROM content.asset_key_envelopes WHERE vault_id=$1 ORDER BY id",
        [dump(owner.vault_id)]
      ).rows
    end

    before_envelopes = envelopes.()

    witnesses =
      Map.new(before_objects, fn {id, object} ->
        entry = physical_entry!(object)

        require!(
          object["storage_ref"] == id,
          "historical composition did not begin at genuine UUID publication"
        )

        {id, KnowledgeRestoreOracle.reference_witness!(root, entry)}
      end)

    selected =
      case reference_mode do
        :canonical_compatibility -> Map.keys(before_objects)
        :mixed_compatibility -> [sources.pdf.object_id, sources.empty.object_id]
      end

    for id <- selected do
      before = Map.fetch!(before_objects, id)
      witness = Map.fetch!(witnesses, id)

      updated =
        observe_rows!(
          """
          UPDATE content.asset_objects SET storage_ref=$1
          WHERE id=$2 AND vault_id=$3 AND storage_ref=$4
          """,
          [witness.canonical_ref, dump(id), dump(owner.vault_id), before["storage_ref"]]
        )

      require!(
        updated.num_rows == 1,
        "historical composition did not update exactly one owned UUID reference"
      )
    end

    expected =
      Map.new(before_objects, fn {id, object} ->
        if id in selected,
          do: {id, Map.put(object, "storage_ref", witnesses[id].canonical_ref)},
          else: {id, object}
      end)

    after_objects = native_inventory!(owner)

    require!(
      after_objects == expected,
      "historical composition changed a complete object field beyond selected references"
    )

    require!(
      envelopes.() == before_envelopes,
      "historical composition changed native envelope rows"
    )

    for {id, object} <- after_objects do
      unchanged? =
        KnowledgeRestoreOracle.reference_witness!(root, physical_entry!(object)) == witnesses[id]

      require!(unchanged?, "historical composition changed ciphertext or physical identity")
    end

    witnesses
  end

  defp physical_entry!(object) do
    %{
      asset_object_id: Ecto.UUID.load!(object["id"]),
      vault_id: Ecto.UUID.load!(object["vault_id"]),
      key_domain_id: Ecto.UUID.load!(object["key_domain_id"]),
      lookup_digest: object["lookup_digest"],
      ciphertext_hash: object["ciphertext_hash"],
      ciphertext_byte_size: object["ciphertext_byte_size"]
    }
  end

  defp publish_sources!(fixture) do
    pdf = "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n"

    inputs = [
      {:pdf, "application/pdf", [pdf], "native.pdf"},
      {:pdf_duplicate, "application/pdf", [pdf], "duplicate.pdf"},
      {:empty, "text/plain", [], "empty.txt"},
      {:plain, "text/plain", ["plain original\r\nsecond line\n"], "plain.txt"},
      {:unicode, "text/plain", [<<0xEF>>, <<0xBB, 0xBF, 0xE4>>, <<0xB8, 0xAD>>, "é\r\n"],
       "unicode.txt"},
      {:markdown, "text/markdown",
       ["# Original Markdown\r\n", "[source](https://example.test/)\n"], "original.md"}
    ]

    sources =
      Map.new(inputs, fn {name, media_type, chunks, filename} ->
        upload = NativeAssetFixture.upload!(fixture, media_type, chunks, filename)
        NativeAssetFixture.verify_and_finalize!()
        bytes = IO.iodata_to_binary(chunks)
        {name, publication!(fixture, upload.asset_id, filename, media_type, bytes)}
      end)

    require!(
      sources.pdf.object_id == sources.pdf_duplicate.object_id and
        sources.pdf.asset_id != sources.pdf_duplicate.asset_id and
        sources.pdf.resource_id != sources.pdf_duplicate.resource_id and
        sources.pdf.resource_version_id != sources.pdf_duplicate.resource_version_id,
      "native duplicate PDF did not deduplicate only its immutable object"
    )

    require!(
      sources |> Map.values() |> Enum.map(& &1.object_id) |> Enum.uniq() |> length() == 5,
      "native originals do not own exactly five published objects"
    )

    sources
  end

  defp publication!(fixture, asset_id, filename, media_type, bytes) do
    row =
      one_observation!(
        """
        SELECT r.id::text AS resource_id, v.id::text AS resource_version_id,
          s.id::text AS source_reference_id, a.id::text AS asset_id,
          o.id::text AS object_id, r.kind, r.current_version_id, r.deleted_at,
          a.classification, a.state, a.state_revision, st.state AS stage_state,
          ra.released_at, s.original_filename, s.declared_media_type, s.byte_size,
          m.original_filename AS metadata_filename, m.declared_media_type AS metadata_media_type,
          m.plaintext_byte_size, m.projection_version, m.extraction_state,
          m.extractor_version, m.detected_media_type, m.completed_at,
          m.pdf_header_version, m.image_width, m.image_height,
          o.storage_ref, o.format_version, o.lifecycle, o.deleted_at AS object_deleted_at,
          o.plaintext_byte_size AS object_plaintext_size, o.ciphertext_byte_size,
          o.lookup_digest, o.ciphertext_hash, e.algorithm, e.key_generation,
          d.generation AS domain_generation, e.wrapped_dek,
          e.key_domain_id=o.key_domain_id AS envelope_domain_matches
        FROM content.assets a
        JOIN content.resource_versions v ON v.id=a.resource_version_id AND v.vault_id=a.vault_id
        JOIN content.resources r ON r.id=v.resource_id AND r.vault_id=a.vault_id
        JOIN content.resource_assets ra ON ra.asset_id=a.id AND ra.resource_version_id=v.id AND ra.vault_id=a.vault_id
        JOIN content.source_references s ON s.resource_version_id=v.id AND s.vault_id=a.vault_id
        JOIN content.asset_metadata m ON m.asset_id=a.id AND m.resource_version_id=v.id AND m.vault_id=a.vault_id
        JOIN content.asset_stages st ON st.asset_id=a.id AND st.vault_id=a.vault_id
        JOIN content.asset_objects o ON o.id=a.asset_object_id AND o.vault_id=a.vault_id
        JOIN content.asset_key_envelopes e ON e.asset_object_id=o.id AND e.vault_id=a.vault_id
        JOIN core.domain_key_versions d ON d.id=e.domain_key_version_id AND d.vault_id=a.vault_id
        WHERE a.id=$1 AND a.vault_id=$2
        """,
        [dump(asset_id), dump(fixture.session.vault_id)]
      )

    require!(
      row["kind"] == "asset" and is_nil(row["current_version_id"]) and
        is_nil(row["deleted_at"]) and is_nil(row["released_at"]) and
        row["classification"] == "private" and row["stage_state"] == "finalized" and
        row["original_filename"] == filename and row["metadata_filename"] == filename and
        row["declared_media_type"] == media_type and row["metadata_media_type"] == media_type and
        row["byte_size"] == byte_size(bytes) and row["plaintext_byte_size"] == byte_size(bytes) and
        row["object_plaintext_size"] == byte_size(bytes) and row["projection_version"] == 1,
      "native finalized source association or metadata differs from its input"
    )

    expected_metadata =
      if media_type == "application/pdf" do
        row["state"] == "available" and row["state_revision"] == 3 and
          row["extraction_state"] == "pending" and is_nil(row["extractor_version"]) and
          is_nil(row["detected_media_type"]) and is_nil(row["completed_at"])
      else
        row["state"] == "ready" and row["state_revision"] == 5 and
          row["extraction_state"] == "completed" and row["extractor_version"] == "upload_text_v1" and
          row["detected_media_type"] == media_type and not is_nil(row["completed_at"])
      end

    require!(
      expected_metadata and is_nil(row["pdf_header_version"]) and
        is_nil(row["image_width"]) and is_nil(row["image_height"]),
      "native text completion or pending PDF metadata is not genuine"
    )

    require!(
      row["storage_ref"] == row["object_id"] and row["format_version"] == 1 and
        row["lifecycle"] == "available" and is_nil(row["object_deleted_at"]) and
        row["algorithm"] == "aes_256_gcm" and row["key_generation"] == 1 and
        row["domain_generation"] == 1 and row["envelope_domain_matches"] and
        is_binary(row["wrapped_dek"]) and byte_size(row["wrapped_dek"]) > 0 and
        byte_size(row["lookup_digest"]) == 32 and byte_size(row["ciphertext_hash"]) == 32 and
        row["ciphertext_byte_size"] > 0,
      "native publication object or key envelope is invalid"
    )

    for column <- ~w(resource_id resource_version_id source_reference_id asset_id object_id) do
      require!(
        match?({:ok, _}, Ecto.UUID.cast(row[column])),
        "native publication identity is not a UUID"
      )
    end

    if media_type != "application/pdf" do
      download =
        expect_ok!(
          Singularity.Runtime.Api.download(fixture.session, asset_id, nil),
          "native source download"
        )

      require!(
        download.status == 200 and download.body == bytes and
          download.content_length == byte_size(bytes) and
          download.detected_media_type == media_type,
        "native pre-cut download changed original bytes"
      )
    end

    %{
      resource_id: row["resource_id"],
      resource_version_id: row["resource_version_id"],
      source_reference_id: row["source_reference_id"],
      asset_id: asset_id,
      object_id: row["object_id"],
      digest: :crypto.hash(:sha256, bytes),
      byte_size: byte_size(bytes),
      filename: filename,
      media_type: media_type,
      bytes: bytes
    }
  end

  defp knowledge_ids do
    ~w(live_note_id deleted_note_id initial_note_version_id canonical_note_version_id
      competing_note_version_id merge_note_version_id open_competing_note_version_id
      deleted_note_version_id resolved_conflict_id open_conflict_id ready_document_id
      ready_old_version_id ready_current_version_id deleted_document_id deleted_document_version_id
      pending_document_id pending_version_id extracting_document_id extracting_version_id
      failed_document_id failed_version_id unsupported_document_id unsupported_version_id
      attachment_id citation_id deleted_attachment_id deleted_citation_id tag_id relationship_id)a
    |> Map.new(&{&1, Ecto.UUID.generate()})
  end

  defp bootstrap_hierarchy!(owner) do
    tables = ~w(core.key_domains core.vault_key_versions core.vault_key_wrappers
      core.domain_key_versions core.domain_dedup_key_wrappers)

    Map.new(tables, fn table ->
      # Literal module-owned identifiers, never caller-controlled SQL.
      {table,
       observe_rows!("SELECT * FROM #{table} WHERE vault_id=$1 ORDER BY id", [
         dump(owner.vault_id)
       ]).rows}
    end)
  end

  defp source_set_seals!(owner) do
    observe_rows!(
      """
      SELECT note_resource_version_id::text,attachment_count,citation_count
      FROM content.note_source_set_seals WHERE vault_id=$1 ORDER BY note_resource_version_id
      """,
      [dump(owner.vault_id)]
    ).rows
  end

  defp native_inventory!(owner) do
    rows =
      observation_maps!("SELECT * FROM content.asset_objects WHERE vault_id=$1 ORDER BY id", [
        dump(owner.vault_id)
      ])

    Map.new(rows, &{Ecto.UUID.load!(&1["id"]), &1})
  end

  defp retained_pdf!(fixture, object_id) do
    object =
      one_observation!(
        "SELECT * FROM content.asset_objects WHERE id=$1 AND vault_id=$2",
        [dump(object_id), dump(fixture.session.vault_id)]
      )

    envelopes =
      observe_rows!(
        "SELECT * FROM content.asset_key_envelopes WHERE asset_object_id=$1 AND vault_id=$2 ORDER BY id",
        [dump(object_id), dump(fixture.session.vault_id)]
      ).rows

    require!(
      object["lifecycle"] == "available" and envelopes != [],
      "native PDF object or envelope is unavailable"
    )

    context = %{
      root: fixture.destination.object_root,
      vault_namespace: fixture.session.vault_id,
      domain_namespace: Ecto.UUID.load!(object["key_domain_id"]),
      lookup_digest: Base.encode16(object["lookup_digest"], case: :lower),
      ciphertext_hash: object["ciphertext_hash"]
    }

    ref = %Singularity.Core.ObjectRef{object_id: object_id}

    stat =
      expect_ok!(
        Singularity.Storage.LocalFilesystemAdapter.stat(context, ref),
        "PDF ciphertext stat"
      )

    require!(
      stat.byte_size == object["ciphertext_byte_size"] and stat.byte_size > 0 and
        stat.ciphertext_hash == object["ciphertext_hash"],
      "native PDF ciphertext stat differs"
    )

    handle =
      expect_ok!(
        Singularity.Storage.LocalFilesystemAdapter.open(context, ref),
        "PDF ciphertext open"
      )

    ciphertext =
      expect_ok!(
        Singularity.Storage.LocalFilesystemAdapter.read_range(
          context,
          handle,
          0..(stat.byte_size - 1)
        ),
        "PDF ciphertext read"
      )

    require!(
      byte_size(ciphertext) == stat.byte_size and
        :crypto.hash(:sha256, ciphertext) == stat.ciphertext_hash,
      "native PDF ciphertext bytes differ from their real stat"
    )

    %{object: object, envelopes: envelopes, ciphertext: ciphertext}
  end

  defp delete_pdf!(fixture, source) do
    session = fixture.session

    summary =
      expect_ok!(
        Singularity.Runtime.Api.asset_summary(session, source.asset_id),
        "PDF deletion summary"
      )

    before_revision = summary.state_revision
    require!(before_revision == 3, "PDF deletion did not start from finalized native state")

    require!(
      Singularity.Runtime.Api.delete_asset(session, source.asset_id, before_revision) ==
        {:ok, true},
      "public PDF deletion did not apply its expected revision"
    )

    pending =
      one_observation!(
        "SELECT state,state_revision FROM content.assets WHERE id=$1 AND vault_id=$2",
        [dump(source.asset_id), dump(session.vault_id)]
      )

    require!(
      pending["state"] == "pending_delete" and pending["state_revision"] == before_revision + 1,
      "public PDF deletion did not produce its pending revision"
    )

    NativeAssetFixture.dispatch!()
    cleanup = drain_one!(:asset_cleanup)

    row =
      one_observation!(
        """
        SELECT t.id::text AS tombstone_id, t.principal_id::text, t.classification,
          t.reason, t.retention_metadata, t.deleted_at, a.state, a.state_revision,
          a.asset_object_id, ra.released_at, e.id::text AS event_id,
          e.required_capability, e.principal_id::text AS event_principal_id,
          e.principal_authorization_epoch,e.vault_authorization_epoch,
          e.classification AS event_classification,e.expected_entity_revision,
          e.idempotency_key,e.payload,e.causation_id=t.id AS causation_matches,
          s.id::text AS submission_id,s.job_type,j.state AS runner_state,
          f.result AS effect_result,f.entity_revision AS effect_revision,
          f.effect_key=e.idempotency_key AS effect_key_matches,
          EXISTS(SELECT 1 FROM audit.events audit WHERE audit.vault_id=t.vault_id
            AND audit.principal_id=t.principal_id AND audit.target_id=t.asset_id
            AND audit.correlation_id=e.correlation_id AND audit.operation='asset.tombstoned') AS tombstone_audit,
          EXISTS(SELECT 1 FROM audit.events audit WHERE audit.vault_id=t.vault_id
            AND audit.principal_id=t.principal_id AND audit.target_id=t.asset_id
            AND audit.correlation_id=e.correlation_id AND audit.operation='asset.deleted') AS deleted_audit
        FROM content.tombstones t
        JOIN content.assets a ON a.id=t.asset_id AND a.vault_id=t.vault_id
        JOIN content.resource_assets ra ON ra.asset_id=a.id AND ra.vault_id=a.vault_id
        JOIN core.outbox_events e ON e.causation_id=t.id AND e.vault_id=t.vault_id
          AND e.event_type='asset.cleanup_requested'
        JOIN jobs.job_submissions s ON s.outbox_event_id=e.id AND s.vault_id=t.vault_id
        JOIN jobs.oban_jobs j ON j.id::text=s.runner_job_id
        JOIN jobs.effect_receipts f ON f.submission_id=s.id AND f.vault_id=t.vault_id
          AND f.effect_key=e.idempotency_key
        WHERE t.asset_id=$1 AND t.vault_id=$2
        """,
        [dump(source.asset_id), dump(session.vault_id)]
      )

    require!(
      row["principal_id"] == session.principal_id and row["classification"] == "private" and
        row["reason"] == "asset deletion requested" and not is_nil(row["deleted_at"]) and
        row["retention_metadata"] == %{"expected_state_revision" => before_revision} and
        row["state"] == "deleted" and row["state_revision"] == before_revision + 2 and
        is_nil(row["asset_object_id"]) and not is_nil(row["released_at"]),
      "native PDF tombstone or released association lost its exact binding"
    )

    require!(
      row["required_capability"] == "asset.write" and
        row["event_principal_id"] == session.principal_id and
        row["principal_authorization_epoch"] == session.principal_authorization_epoch and
        row["vault_authorization_epoch"] == session.vault_authorization_epoch and
        row["event_classification"] == "private" and
        row["expected_entity_revision"] == before_revision + 1 and
        row["idempotency_key"] == "asset-cleanup:#{source.asset_id}:#{before_revision + 1}" and
        row["payload"] == %{"asset_id" => source.asset_id} and row["causation_matches"] and
        row["submission_id"] == row["event_id"] and
        row["job_type"] == "asset_cleanup" and row["runner_state"] == "completed" and
        row["effect_result"] == "applied" and row["effect_revision"] == before_revision + 2 and
        row["effect_key_matches"] and row["tombstone_audit"] and row["deleted_audit"],
      "actual PDF cleanup worker admission, effect, or audit causality differs"
    )

    %{
      asset_id: source.asset_id,
      tombstone_id: row["tombstone_id"],
      event_id: row["event_id"],
      submission_id: row["submission_id"],
      before_revision: before_revision,
      pending_revision: pending["state_revision"],
      deleted_revision: row["state_revision"],
      worker_effect_revision: row["effect_revision"],
      cleanup_success: cleanup.success
    }
  end

  defp retire_metadata!(owner, ids, sources) do
    result =
      MigrationRepo.transaction(fn ->
        SafeSQL.query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner", [])

        for resource <- [
              sources.pdf.resource_id,
              sources.pdf_duplicate.resource_id,
              ids.deleted_note_id,
              ids.deleted_document_id
            ] do
          result =
            SafeSQL.query!(
              MigrationRepo,
              "UPDATE content.resources SET deleted_at=$1 WHERE id=$2 AND vault_id=$3",
              [DateTime.utc_now(:microsecond), dump(resource), dump(owner.vault_id)]
            )

          require!(result.num_rows == 1, "metadata retirement did not update one owned resource")
        end

        for resource <- [ids.live_note_id, ids.ready_document_id] do
          SafeSQL.query!(
            MigrationRepo,
            "SELECT content.reconcile_search_resource_internal($1,$2)",
            [dump(owner.vault_id), dump(resource)]
          )
        end

        :ok
      end)

    require!(result == {:ok, :ok}, "knowledge metadata retirement did not commit")
  end

  defp document_pin_count!(session, object_id) do
    Singularity.Storage.ScopedRepo.transact(Singularity.Storage.WorkerRepo, session, fn repo ->
      authorize_asset_write!(repo, session)

      %{rows: [[count]]} =
        SafeSQL.query!(repo, "SELECT content.document_source_pin_count($1,$2)", [
          dump(object_id),
          dump(session.vault_id)
        ])

      count
    end)
  end

  defp legacy_backup_guards!(session) do
    result =
      Singularity.Storage.ScopedRepo.transact(
        Singularity.Storage.WorkerRepo,
        session,
        [isolation: :repeatable_read],
        fn repo ->
          authorize_asset_write!(repo, session)

          with {:ok, cut} <-
                 Singularity.Storage.Backup.Exporter.snapshot_cut(repo, session.vault_id) do
            cut = Map.put(cut, :manifest_id, Ecto.UUID.generate())

            Map.new([1, 2], fn version ->
              {:error, %{code: :backup_unsupported}} =
                Singularity.Storage.Backup.Exporter.snapshot_cut(repo, session.vault_id, version)

              {:error, %{code: :backup_unsupported}} =
                Singularity.Storage.Backup.Exporter.records(repo, cut, version)

              {version, :backup_unsupported}
            end)
          end
        end
      )

    case result do
      %{1 => :backup_unsupported, 2 => :backup_unsupported} = errors when map_size(errors) == 2 ->
        errors

      _other ->
        raise "default V3 cut or explicit V1/V2 unsupported-canonical guards failed"
    end
  end

  defp authorize_asset_write!(repo, session) do
    dependencies = Singularity.Runtime.JobDispatcher.dependencies()

    # Read-only worker authority binding, not a fabricated submitted job. The
    # worker role cannot invoke the request-only live session snapshot.
    requirement = %{
      principal_id: session.principal_id,
      vault_id: session.vault_id,
      principal_authorization_epoch: session.principal_authorization_epoch,
      vault_authorization_epoch: session.vault_authorization_epoch,
      required_capability: "asset.write",
      classification: :private
    }

    require!(
      Singularity.Runtime.Authorize.check_job(dependencies.authorization, repo, requirement) ==
        :ok,
      "native observation did not reload live Asset authority"
    )
  end

  defp drain_one!(queue) do
    result = Oban.drain_queue(Singularity.Oban, queue: queue)

    require!(
      match?(%{failure: 0, success: 1}, result),
      "native owned queue did not complete exactly one job"
    )

    result
  end

  defp one_observation!(sql, parameters) do
    case observation_maps!(sql, parameters) do
      [row] -> row
      _rows -> raise "native knowledge observation did not select exactly one row"
    end
  end

  defp observation_maps!(sql, parameters) do
    result = observe_rows!(sql, parameters)
    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end

  defp observe_rows!(sql, parameters), do: NativeAssetFixture.observe!(sql, parameters)
  defp dump(id), do: Ecto.UUID.dump!(id)

  defp lifecycle(destination, infrastructure, repositories, observer) do
    %{
      database: destination.database,
      object_root: destination.object_root,
      infrastructure: infrastructure,
      repositories: repositories,
      observer: observer
    }
  end

  defp require_closed_source!(%{
         database: database,
         object_root: root,
         infrastructure: infrastructure,
         repositories: repositories,
         observer: observer
       }) do
    require!(
      is_binary(database) and is_binary(root) and is_pid(infrastructure) and is_pid(observer) and
        is_map(repositories) and
        Enum.sort(Map.keys(repositories)) == Enum.sort([MigrationRepo | @borrowed_repos]),
      "knowledge source lifecycle is invalid"
    )

    closed? =
      not Process.alive?(infrastructure) and not Process.alive?(observer) and
        Enum.all?(repositories, fn {_repo, {pid, actual_database}} ->
          is_pid(pid) and not Process.alive?(pid) and actual_database == database
        end)

    require!(closed?, "knowledge source resources are still live")
    require!(not File.exists?(root), "knowledge source object root was not removed")
  end

  defp require_closed_source!(_source),
    do: raise(ArgumentError, "knowledge source lifecycle is invalid")

  defp require_private_directory!(root) do
    case File.lstat(root) do
      {:ok, %{type: :directory, mode: mode}} ->
        require!(
          Bitwise.band(mode, 0o777) == 0o700,
          "knowledge portability directory is not private"
        )

        require!(File.ls!(root) == [], "knowledge portability directory is not newly empty")

      _other ->
        raise ArgumentError, "knowledge portability directory is not an owned directory"
    end
  end

  defp save_settings do
    for {app, keys} <- [
          singularity_runtime: @runtime_settings,
          singularity_storage: @storage_settings
        ],
        key <- keys,
        do: {app, key, Application.fetch_env(app, key)}
  end

  defp restore_settings(saved) do
    for {app, key, previous} <- saved do
      case previous do
        {:ok, value} -> Application.put_env(app, key, value)
        :error -> Application.delete_env(app, key)
      end
    end
  end

  defp bootstrap! do
    login = "native-knowledge-#{Ecto.UUID.generate()}@example.test"
    password = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    adapters = Application.fetch_env!(:singularity_runtime, :bootstrap_owner)

    adapters =
      Map.put(adapters, :initial_capabilities, [
        "asset.read",
        "asset.write",
        "backup.create",
        "note.export",
        "note.read",
        "note.write",
        "vault.lock",
        "vault.unlock",
        "vault.password_change"
      ])

    result =
      MigrationRepo.transaction(fn ->
        SafeSQL.query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner", [])

        expect_ok!(
          BootstrapOwner.run(adapters, %{
            display_name: "Native Knowledge Fixture",
            login: login,
            password: password
          }),
          "owner bootstrap"
        )
      end)

    %{owner: expect_ok!(result, "bootstrap transaction"), login: login, password: password}
  end

  defp configure_runtime!(destination) do
    Application.put_env(
      :singularity_storage,
      :job_handler,
      Singularity.Runtime.KnowledgeBackupRestoreFixture.V3JobHandler
    )

    Application.put_env(:singularity_runtime, :authorization_dependencies, %{
      store: Singularity.Storage.Postgres.IdentityRepository,
      custodian: KeyCustodian
    })

    Application.put_env(:singularity_runtime, :key_custodian, %{
      authorization: Singularity.Runtime.CustodyReader,
      backup_cipher: Singularity.Storage.Crypto.ChunkedAEAD,
      backup_recovery_wrapper: Singularity.Storage.Crypto.BackupRecoveryWrapper,
      clock: Singularity.Runtime.CustodyReader,
      context: %{
        repo: Singularity.Storage.WorkerRepo,
        repository_adapter: Singularity.Storage.Postgres.CustodyRepository,
        key_wrapper: Singularity.Storage.Crypto.KeyWrapper,
        storage: Singularity.Runtime.StorageAdapter
      },
      idle_lock: Singularity.Runtime.LockVault,
      key_reader: Singularity.Runtime.CustodyReader,
      object_key_loader: Singularity.Runtime.CustodyReader,
      wake_waiting: Singularity.Runtime.JobDispatcher
    })

    backup_root = Path.join(Path.dirname(destination.object_root), "backups")
    File.mkdir!(backup_root)
    File.chmod!(backup_root, 0o700)
    Application.put_env(:singularity_storage, :backup_root, backup_root)
  end

  defp composition do
    %{
      start_infrastructure: true,
      job_handler: Application.fetch_env!(:singularity_storage, :job_handler),
      authorization: Application.fetch_env!(:singularity_runtime, :authorization_dependencies),
      key_custodian: Application.fetch_env!(:singularity_runtime, :key_custodian),
      oban: Application.fetch_env!(:singularity_runtime, :oban_options),
      outbox_dispatcher: Application.fetch_env!(:singularity_runtime, :outbox_dispatcher_options)
    }
  end

  defp require!(true, _message), do: :ok
  defp require!(false, message), do: raise(ArgumentError, message)

  defp expect_ok!({:ok, value}, _stage), do: value
  defp expect_ok!(_result, stage), do: raise("native knowledge fixture failed at #{stage}")

  # BEGIN Task11 transparent native Runtime fault and lifecycle seams.
  def task11_with_child_destination!(source, parent_owner, fun) when is_function(fun, 1) do
    require_closed_source!(source)
    apps = [:singularity_storage, :singularity_runtime]
    saved = Map.new(apps, &{&1, Map.new(Application.get_all_env(&1))})
    {owner, destination} = ResourceOwner.open_child(parent_owner, migration_pool_size: 2)

    outcome =
      try do
        require!(
          destination.database != source.database,
          "knowledge destination reused source database"
        )

        require!(
          File.ls!(destination.object_root) == [],
          "knowledge destination object root is not empty"
        )

        configure_runtime!(destination)
        Application.put_env(:singularity_runtime, :maintenance_mode, true)
        Application.put_env(:singularity_runtime, :start_infrastructure, false)
        repositories = NativeAssetFixture.repo_identities()

        require!(
          is_nil(Process.whereis(KeyCustodian)) and
            is_nil(Process.whereis(Singularity.Runtime.OutboxDispatcher)) and
            is_nil(Oban.whereis(Singularity.Oban)),
          "knowledge destination started ordinary runtime before restore"
        )

        {:return,
         fun.(%{
           owner: owner,
           destination: destination,
           infrastructure: nil,
           repositories: repositories,
           lifecycle: lifecycle(destination, nil, repositories, nil)
         })}
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      end

    cleanup =
      try do
        :ok = ResourceOwner.close(owner)
        :ok
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      end

    case {outcome, cleanup} do
      {{:raised, kind, reason, stack}, _} ->
        if cleanup != :ok, do: IO.puts(:stderr, "Task11 child destination cleanup failed")
        :erlang.raise(kind, reason, stack)

      {{:return, _}, {:raised, kind, reason, stack}} ->
        :erlang.raise(kind, reason, stack)

      {{:return, result}, :ok} ->
        restored = Map.new(apps, &{&1, Map.new(Application.get_all_env(&1))})
        require!(restored == saved, "Task11 child destination configuration differs")
        result
    end
  end

  defmodule Task11CommitUncertaintyRepo do
    use Ecto.Repo, otp_app: :singularity_storage, adapter: Ecto.Adapters.Postgres
    def default_options(_operation), do: [telemetry_event: nil]
    defoverridable transact: 2

    def transact(fun, options) do
      result = super(fun, options)

      if result == {:ok, :imported} and Process.get({__MODULE__, :armed}, false) do
        false = in_transaction?()
        Process.put({__MODULE__, :armed}, false)
        Process.put({__MODULE__, :hits}, Process.get({__MODULE__, :hits}, 0) + 1)
        Process.put({__MODULE__, :committed_result}, result)
        {:error, :task11_actual_committed_result_uncertainty}
      else
        result
      end
    end
  end

  defmodule Task11SentinelReadRepo do
    use Ecto.Repo, otp_app: :singularity_storage, adapter: Ecto.Adapters.Postgres
    def default_options(_operation), do: [telemetry_event: nil]
  end

  defmodule Task11BackupLease do
    alias Singularity.Runtime.BackupKeyLease

    def start_restore_link(context, options) do
      result = BackupKeyLease.start_restore_link(options)

      case result do
        {:ok, pid} -> context.record.({:backup_lease, pid, Process.monitor(pid)})
        _ -> :ok
      end

      result
    end

    def claim_recovered_vault_key(context, lease, proof) do
      result = BackupKeyLease.claim_recovered_vault_key(lease, proof)

      case result do
        {:ok, capability} -> context.record.({:claimed_recovered_key, capability})
        _ -> :ok
      end

      result
    end

    def revoke(_context, lease), do: BackupKeyLease.revoke(lease)
  end

  defmodule Task11IntegrityIssuer do
    alias Singularity.Runtime.RestoreIntegrityLease

    def issue(context, options) do
      # Forward the exact native options, including ownership, keys and TTL.
      result = RestoreIntegrityLease.issue(options)

      case result do
        {:ok, %RestoreIntegrityLease.Capability{} = capability} ->
          context.record.({:integrity_owner_is_caller, options.owner == self()})
          context.record.({:integrity_capability, capability, Process.monitor(capability.lease)})

        _ ->
          :ok
      end

      result
    end

    def revoke(_context, capability), do: RestoreIntegrityLease.revoke(capability)
  end

  defmodule Task11Ports do
    alias Singularity.Runtime.{IntegrityAudit, RestoreAuthenticator, RestoreIntegrityLease}
    alias Singularity.Runtime.KnowledgeBackupRestoreFixture, as: Fixture
    alias Singularity.Storage.Backup.{KnowledgeIntegrityAudit, Reconciler, Restorer}

    def require_maintenance(context),
      do:
        Fixture.task11_boundary(context, :maintenance, fn ->
          call(context.maintenance_mode, :require_maintenance, [])
        end)

    def require_empty(context, repo),
      do:
        Fixture.task11_boundary(context, :admission, fn ->
          call(context.destination, :require_empty, [repo])
        end)

    def authenticate_all(context, source, passphrase) do
      Fixture.task11_boundary(context, :authentication, fn ->
        result = RestoreAuthenticator.authenticate_all(context.authenticator, source, passphrase)

        case result do
          {:ok, authenticated} ->
            context.record.({:authenticated, authenticated})
            Process.put({Fixture, context.reference, :authenticated}, authenticated)

          _ ->
            :ok
        end

        result
      end)
    end

    def claim_recovered_vault_key(context, authenticated),
      do:
        Fixture.task11_boundary(context, :claim, fn ->
          RestoreAuthenticator.claim_recovered_vault_key(context.authenticator, authenticated)
        end)

    def revoke(context, %RestoreAuthenticator.Authenticated{} = authenticated),
      do: RestoreAuthenticator.revoke(context.authenticator, authenticated)

    def revoke(_context, %RestoreIntegrityLease.Capability{} = capability),
      do: RestoreIntegrityLease.revoke(capability)

    def revoke(context, rewrapped), do: IntegrityAudit.revoke(context.integrity, rewrapped)

    def import(context, repo, input) do
      Fixture.task11_boundary(context, :import, fn ->
        result = Restorer.import(context.import_restorer, repo, input)

        case result do
          {:ok, imported} -> Process.put({Fixture, context.reference, :imported}, imported)
          _ -> :ok
        end

        result
      end)
    end

    def rewrap_owner(context, imported, password, capability),
      do:
        Fixture.task11_boundary(context, :rewrap, fn ->
          Restorer.rewrap_owner(context.restorer, imported, password, capability)
        end)

    def complete_restore(context, rewrapped),
      do:
        Fixture.task11_boundary(context, :restore_complete, fn ->
          Restorer.complete_restore(context.restorer, rewrapped)
        end)

    def verify_ciphertext(context, rewrapped),
      do:
        Fixture.task11_boundary(context, :early_cipher, fn ->
          IntegrityAudit.verify_ciphertext(context.integrity, rewrapped)
        end)

    def verify_plaintext_and_search(context, rewrapped),
      do: IntegrityAudit.verify_plaintext_and_search(context.integrity, rewrapped)

    def reconcile(context, cut),
      do:
        Fixture.task11_boundary(context, :reconcile, fn ->
          Reconciler.reconcile(context.repo, cut)
        end)

    def verify_ciphertext(context, storage, owner, inventory) do
      stage =
        if Process.get({Fixture, context.reference, :cipher_calls}, 0) == 0,
          do: :early_native_cipher,
          else: :final_cipher

      Process.put({Fixture, context.reference, :cipher_calls}, 1)

      native = fn ->
        Singularity.Storage.Backup.IntegrityAudit.verify_ciphertext(storage, owner, inventory)
      end

      if stage == :early_native_cipher,
        do: native.(),
        else: Fixture.task11_boundary(context, stage, native)
    end

    def verify_all(context, capability) do
      Fixture.task11_boundary(context, :plaintext, fn ->
        if context.fault == :plaintext_revoked, do: RestoreIntegrityLease.revoke(capability)
        RestoreIntegrityLease.verify_all(capability)
      end)
    end

    def verify_document_sources(context, binding, inventory, hashes) do
      # Runtime reached this callback only after its actual typed validation.
      context.record.({:validated_documents, binding, inventory, hashes})

      Fixture.task11_boundary(context, :documents, fn ->
        KnowledgeIntegrityAudit.verify_document_sources(context.repo, binding, inventory, hashes)
      end)
    end

    def rebuild(context, binding),
      do:
        Fixture.task11_boundary(context, :rebuild, fn ->
          KnowledgeIntegrityAudit.rebuild(context.repo, binding)
        end)

    def complete(context, command),
      do:
        Fixture.task11_boundary(context, :integrity_complete, fn ->
          Singularity.Storage.Backup.IntegrityAudit.complete(context.repo, command)
        end)

    defp call(module, function, arguments) when is_atom(module),
      do: apply(module, function, arguments)

    defp call({module, context}, function, arguments),
      do: apply(module, function, [context | arguments])
  end

  defmodule Task11CommittedRewrapReplyFault do
    alias Singularity.Runtime.KnowledgeBackupRestoreFixture, as: Fixture
    alias Singularity.Runtime.RestoreIntegrityLease
    alias Singularity.Storage.Backup.Restorer

    def import(context, repo, input), do: Fixture.Task11Ports.import(context, repo, input)
    def complete_restore(context, value), do: Fixture.Task11Ports.complete_restore(context, value)

    def rewrap_owner(context, imported, password, recovered_capability) do
      context.record.({:trace, {:entered, :rewrap}})
      key = {Fixture, context.reference, :rewrap_calls}
      Process.put(key, Process.get(key, 0) + 1)

      # This adapter owns the successful reply. The caller never receives its
      # authority, so this explicit native revoke is adapter-owned cleanup.
      case Restorer.rewrap_owner(context.restorer, imported, password, recovered_capability) do
        {:ok, %Restorer.Rewrapped{} = rewrapped} = result ->
          try do
            context.record.({:trace, {:returned, :rewrap, :ok}})
            context.check.(:rewrap, result)
            {:error, context.error}
          after
            :ok = RestoreIntegrityLease.revoke(rewrapped.integrity_capability)
            Process.put({Fixture, context.reference, :reply_owned_cleanup?}, true)
          end

        native_error ->
          context.record.(
            {:trace,
             {:returned, :rewrap, Fixture.ObservedAuthenticator.return_category(native_error)}}
          )

          native_error
      end
    end
  end

  defmodule Task11FaultStorage do
    alias Singularity.Core.Error
    alias Singularity.Runtime.KnowledgeBackupRestoreFixture, as: Fixture
    alias Singularity.Storage.LocalFilesystemAdapter, as: Native
    alias Singularity.Storage.Local.PathGuard

    def stage(context, options) do
      if context.task11.fault == :preflight do
        :ok = Fixture.task11_storage_guard!(context.task11, :before_canonical)
        context.task11.record.({:storage, :stage_denied})
        {:error, Error.new(:storage_unavailable)}
      else
        result = Native.stage(context, options)
        if match?({:ok, _}, result), do: context.task11.record.({:storage, :staged})
        result
      end
    end

    def finalize(context, stage, object) do
      context.task11.record.({:storage, :finalize_entered})
      :ok = Fixture.task11_storage_guard!(context.task11, :validated)
      context.task11.record.({:storage, :validated_graph})

      if context.task11.fault == :before_publish do
        context.task11.record.({:storage, :publish_denied})
        {:error, Error.new(:storage_unavailable)}
      else
        result = Native.finalize(context, stage, object)

        if match?({:ok, _}, result) do
          key = {Fixture, context.task11.reference, :published}
          Process.put(key, Process.get(key, 0) + 1)
          {:ok, receipt} = PathGuard.finalization_receipt_path(context.root, stage.stage_id)
          true = File.lstat!(receipt).type == :regular
          context.task11.record.({:storage, :real_publication_and_receipt})
        end

        result
      end
    end

    def stat(context, object) do
      result = Native.stat(context, object)

      if context.task11.fault == :after_publish and
           Process.get({Fixture, context.task11.reference, :published}, 0) > 0 and
           Process.get({Fixture, context.task11.reference, :verified_stat}, 0) == 0 and
           match?({:ok, _}, result) do
        {:ok, stat} = result
        true = stat.ciphertext_hash == context.ciphertext_hash
        true = stat.byte_size == Map.fetch!(context.task11.expected_sizes, object.object_id)
        :ok = Fixture.task11_storage_guard!(context.task11, :validated)
        Process.put({Fixture, context.task11.reference, :verified_stat}, 1)
        context.task11.record.({:storage, :real_postpublication_stat})
        {:error, Error.new(:storage_unavailable)}
      else
        result
      end
    end

    def rollback_finalize(context, stage, object) do
      published? = match?({:ok, _}, Native.stat(context, object))
      result = Native.rollback_finalize(context, stage, object)

      if published? and result == :ok do
        key = {Fixture, context.task11.reference, :rolled_back}
        Process.put(key, Process.get(key, 0) + 1)
        context.task11.record.({:storage, :owned_publication_removed})
      end

      result
    end

    defdelegate append_encrypted_chunk(context, stage, bytes), to: Native

    def seal_stage(context, stage, metadata) do
      result = Native.seal_stage(context, stage, metadata)

      if result == :ok or match?({:ok, _}, result),
        do: context.task11.record.({:storage, :sealed})

      result
    end

    defdelegate stat_stage(context, stage), to: Native
    defdelegate abort_stage(context, stage), to: Native
    defdelegate delete(context, object), to: Native
    defdelegate list_staged(context), to: Native
  end

  defmodule Task11ImportedReadOnlyStorage do
    alias Singularity.Core.Error
    alias Singularity.Storage.LocalFilesystemAdapter, as: Native

    def stage(context, _options), do: deny(context)
    def append_encrypted_chunk(context, _stage, _bytes), do: deny(context)
    def seal_stage(context, _stage, _metadata), do: deny(context)
    def finalize(context, _stage, _object), do: deny(context)
    def abort_stage(context, _stage), do: deny(context)
    def rollback_finalize(context, _stage, _object), do: deny(context)
    def delete(context, _object), do: deny(context)

    def stat(context, object) do
      context.record.(:storage_replay_read)
      Native.stat(context, object)
    end

    def list_staged(context) do
      context.record.(:storage_replay_read)
      Native.list_staged(context)
    end

    defp deny(context) do
      context.record.(:storage_replay_write_denied)
      {:error, Error.new(:storage_unavailable)}
    end
  end

  def task11_fault_boundary(fault) do
    case fault do
      :admission ->
        {:admission, :native}

      :wrong_passphrase ->
        {:authentication, :native}

      kind
      when kind in [
             :preflight,
             :canonical,
             :empty_seal,
             :before_publish,
             :after_publish,
             :commit_uncertainty
           ] ->
        {:import, :native}

      :rewrap_sql ->
        {:rewrap, :native}

      :rewrap_reply ->
        {:rewrap, :after}

      :early_cipher ->
        {:early_cipher, :before}

      :reconcile_before ->
        {:reconcile, :before}

      :reconcile_after ->
        {:reconcile, :after}

      :final_cipher ->
        {:final_cipher, :before}

      :plaintext_revoked ->
        {:plaintext, :native}

      :plaintext_after ->
        {:plaintext, :after}

      :documents ->
        {:documents, :before}

      :rebuild_before ->
        {:rebuild, :before}

      :rebuild_after ->
        {:rebuild, :after}

      :integrity_before ->
        {:integrity_complete, :before}

      :integrity_after ->
        {:integrity_complete, :after}

      :restore_before ->
        {:restore_complete, :before}

      :restore_after ->
        {:restore_complete, :after}

      :none ->
        {:none, :before}
    end
  end

  def task11_boundary(context, stage, fun) do
    context.record.({:trace, {:entered, stage}})

    if task11_fault_boundary(context.fault) == {stage, :before} do
      {:error, context.error}
    else
      result = fun.()
      category = if result == :ok, do: :ok, else: ObservedAuthenticator.return_category(result)
      context.record.({:trace, {:returned, stage, category}})

      if category == :ok do
        :ok = context.check.(stage, result)

        if task11_fault_boundary(context.fault) == {stage, :after},
          do: {:error, context.error},
          else: result
      else
        result
      end
    end
  end

  def task11_with_fault_context!(destination, portable_root, source, fault, record, check, fun) do
    base = restore_context(destination, portable_root, %{}, %{})
    reference = make_ref()

    context = %{
      fault: fault,
      reference: reference,
      record: record,
      check: check,
      error: Singularity.Core.Error.new(:storage_unavailable, retryable?: true),
      repo: MigrationRepo,
      source: source,
      destination: base.destination,
      maintenance_mode: base.maintenance_mode
    }

    try do
      task11_with_repo!(fault, fn repo ->
        context = %{context | repo: repo}
        {_observed_auth, observed_auth} = base.authenticator

        authenticator =
          Map.put(observed_auth.authenticator, :backup_key_lease, {Task11BackupLease, context})

        {_observed_restorer, observed_restorer} = base.restorer
        {storage, storage_context} = observed_restorer.restorer.object_storage

        require!(
          storage == Singularity.Storage.LocalFilesystemAdapter,
          "Task11 expected native local storage"
        )

        storage_observation =
          Map.take(context, [:fault, :reference, :record, :repo])
          |> Map.put(:source, %{canonical_counts: source.canonical_counts})
          |> Map.put(
            :expected_sizes,
            Map.new(source.original_inventory, &{&1.asset_object_id, &1.ciphertext_byte_size})
          )

        storage = {Task11FaultStorage, Map.put(storage_context, :task11, storage_observation)}

        restorer =
          observed_restorer.restorer
          |> Map.put(:migration_repo, repo)
          |> Map.put(:integrity_issuer, {Task11IntegrityIssuer, context})

        import_restorer = Map.put(restorer, :object_storage, storage)

        integrity = %{
          audit: {Task11Ports, context},
          ciphertext_auditor: {Task11Ports, context},
          object_storage: Singularity.Runtime.StorageAdapter.configured(),
          restore_integrity_lease: {Task11Ports, context},
          search_rebuilder: {Task11Ports, context}
        }

        context =
          Map.merge(context, %{
            authenticator: authenticator,
            restorer: restorer,
            import_restorer: import_restorer,
            integrity: integrity
          })

        restorer_adapter =
          if fault == :rewrap_reply, do: Task11CommittedRewrapReplyFault, else: Task11Ports

        adapters = %{
          authenticator: {Task11Ports, context},
          destination: {Task11Ports, context},
          integrity: {Task11Ports, context},
          maintenance_mode: {Task11Ports, context},
          migration_repo: repo,
          reconciler: {Task11Ports, context},
          restorer: {restorer_adapter, context}
        }

        task11_with_sql_fault!(context, fn sql_hits ->
          result = fun.(adapters)
          authenticated = Process.get({__MODULE__, reference, :authenticated})
          imported = Process.get({__MODULE__, reference, :imported})
          # Verified is an actual native authenticated result, not an invented
          # Imported reply, when COMMIT uncertainty deliberately suppresses it.
          handoff = imported || if(authenticated, do: authenticated.verified)

          {result,
           %{
             imported: handoff,
             sql_hits: sql_hits.(),
             commit_hits: Process.get({Task11CommitUncertaintyRepo, :hits}, 0),
             committed_result: Process.get({Task11CommitUncertaintyRepo, :committed_result}),
             published: Process.get({__MODULE__, reference, :published}, 0),
             verified_stat: Process.get({__MODULE__, reference, :verified_stat}, 0),
             rolled_back: Process.get({__MODULE__, reference, :rolled_back}, 0),
             rewrap_calls: Process.get({__MODULE__, reference, :rewrap_calls}, 0),
             reply_owned_cleanup?:
               Process.get({__MODULE__, reference, :reply_owned_cleanup?}, false)
           }}
        end)
      end)
    after
      for key <- [
            :authenticated,
            :imported,
            :cipher_calls,
            :published,
            :verified_stat,
            :rolled_back,
            :rewrap_calls,
            :reply_owned_cleanup?
          ],
          do: Process.delete({__MODULE__, reference, key})
    end
  end

  defp task11_with_repo!(:commit_uncertainty, fun) do
    options = MigrationRepo.config() |> Keyword.put(:name, Task11CommitUncertaintyRepo)
    {:ok, pid} = Task11CommitUncertaintyRepo.start_link(options)
    Process.unlink(pid)

    try do
      Process.put({Task11CommitUncertaintyRepo, :armed}, true)
      fun.(Task11CommitUncertaintyRepo)
    after
      if Process.whereis(Task11CommitUncertaintyRepo) == pid, do: Supervisor.stop(pid)
      require!(not Process.alive?(pid), "Task11 owned COMMIT repository did not stop")

      for key <- [:armed, :hits, :committed_result],
          do: Process.delete({Task11CommitUncertaintyRepo, key})
    end
  end

  defp task11_with_repo!(_fault, fun), do: fun.(MigrationRepo)

  def task11_storage_guard!(context, :validated) do
    total = task11_total_sql()

    %{rows: [[rows, notes, attachments, citations, seals, admission, marker]]} =
      SafeSQL.query!(
        context.repo,
        "SELECT (#{total}),(SELECT count(*) FROM content.note_versions),(SELECT count(*) FROM content.note_attachments),(SELECT count(*) FROM content.note_citations),(SELECT count(*) FROM content.note_source_set_seals),(SELECT state FROM audit.knowledge_restore_admissions),(SELECT state FROM audit.restore_import_sagas)",
        []
      )

    expected_total = Enum.sum(Map.values(context.source.canonical_counts))

    require!(
      {rows, notes, attachments, citations, seals, admission, marker} ==
        {expected_total, 6, 4, 3, 6, "validated", "pending"},
      "Task11 storage fault did not reach actual admitted canonical graph"
    )

    :ok
  end

  def task11_storage_guard!(context, :before_canonical) do
    total = task11_total_sql()

    %{rows: rows} =
      SafeSQL.query!(
        context.repo,
        "SELECT (#{total}),(SELECT count(*) FROM audit.knowledge_restore_admissions),(SELECT count(*) FROM content.note_source_set_seals),(SELECT state FROM audit.restore_import_sagas)",
        []
      )

    require!(
      rows == [[0, 0, 0, "pending"]],
      "Task11 preflight fault was not before actual canonical insertion"
    )

    :ok
  end

  defp task11_total_sql,
    do:
      Enum.map_join(
        Singularity.Storage.Backup.KnowledgeCanonicalOracle.projection(),
        "+",
        fn {table, _columns, _pk} -> "(SELECT count(*) FROM #{table})" end
      )

  defp task11_with_sql_fault!(%{fault: fault} = context, fun)
       when fault in [:canonical, :empty_seal, :rewrap_sql] do
    suffix = "task11_" <> String.replace(Ecto.UUID.generate(), "-", "")
    sequence = "audit.#{suffix}_hits"
    function = "audit.#{suffix}_fail"
    trigger = "#{suffix}_trigger"
    total = task11_total_sql()
    expected_total = Enum.sum(Map.values(context.source.canonical_counts))

    graph =
      "(#{total})=#{expected_total} AND (SELECT count(*) FROM content.note_versions)=6 AND (SELECT count(*) FROM content.note_attachments)=4 AND (SELECT count(*) FROM content.note_citations)=3"

    loading =
      "(SELECT state FROM audit.knowledge_restore_admissions)='loading' AND (SELECT state FROM audit.restore_import_sagas)='pending'"

    {table, operation, predicate} =
      case fault do
        :canonical ->
          person = hd(context.source.observation.rows["identity.people"])["id"]

          {"identity.people", "INSERT",
           "#{loading} AND NEW.id='#{person}'::uuid AND (#{total})=0 AND (SELECT count(*) FROM content.note_source_set_seals)=0"}

        :empty_seal ->
          version = context.source.ids.initial_note_version_id

          predecessors =
            context.source.source_set_seals
            |> Enum.sort_by(&hd/1)
            |> Enum.take_while(fn [id, _attachments, _citations] -> id < version end)

          predecessor_ids =
            Enum.map_join(predecessors, ",", fn [id, _attachments, _citations] ->
              "'#{id}'::uuid"
            end)

          prefix =
            "(SELECT count(*) FROM content.note_source_set_seals)=#{length(predecessors)} AND NOT EXISTS (SELECT 1 FROM content.note_source_set_seals WHERE note_resource_version_id>=NEW.note_resource_version_id) AND COALESCE((SELECT array_agg(note_resource_version_id ORDER BY note_resource_version_id) FROM content.note_source_set_seals),ARRAY[]::uuid[])=ARRAY[#{predecessor_ids}]::uuid[]"

          {"content.note_source_set_seals", "INSERT",
           "#{loading} AND #{graph} AND NEW.note_resource_version_id='#{version}'::uuid AND NEW.attachment_count=0 AND NEW.citation_count=0 AND (SELECT count(*) FROM content.note_attachments WHERE note_resource_version_id=NEW.note_resource_version_id)=0 AND (SELECT count(*) FROM content.note_citations WHERE note_resource_version_id=NEW.note_resource_version_id)=0 AND #{prefix}"}

        :rewrap_sql ->
          {"identity.credentials", "UPDATE",
           "#{graph} AND (SELECT count(*) FROM content.note_source_set_seals)=6 AND (SELECT state FROM audit.knowledge_restore_admissions)='validated' AND (SELECT state FROM audit.restore_import_sagas)='imported' AND OLD.verifier=(SELECT dummy_verifier FROM identity.security_settings WHERE singleton) AND NEW.verifier<>OLD.verifier"}
      end

    selection =
      if fault == :empty_seal,
        do:
          "WHEN (NEW.note_resource_version_id='#{context.source.ids.initial_note_version_id}'::uuid)",
        else: ""

    task11_owner!(context.repo, fn ->
      SafeSQL.query!(context.repo, "CREATE SEQUENCE #{sequence}", [])

      SafeSQL.query!(
        context.repo,
        "CREATE FUNCTION #{function}() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $fault$ BEGIN IF (#{predicate}) IS NOT TRUE THEN RAISE EXCEPTION 'task11_wrong_fault_stage'; END IF; PERFORM pg_catalog.nextval(TG_ARGV[0]::regclass); RAISE EXCEPTION 'task11_owned_sql_fault'; END $fault$",
        []
      )

      SafeSQL.query!(
        context.repo,
        "CREATE TRIGGER #{trigger} BEFORE #{operation} ON #{table} FOR EACH ROW #{selection} EXECUTE FUNCTION #{function}('#{sequence}')",
        []
      )
    end)

    try do
      fun.(fn ->
        task11_owner!(context.repo, fn ->
          [[count, called?]] =
            SafeSQL.query!(context.repo, "SELECT last_value,is_called FROM #{sequence}", []).rows

          if called?, do: count, else: 0
        end)
      end)
    after
      task11_owner!(context.repo, fn ->
        SafeSQL.query!(context.repo, "DROP TRIGGER #{trigger} ON #{table}", [])
        SafeSQL.query!(context.repo, "DROP FUNCTION #{function}()", [])
        SafeSQL.query!(context.repo, "DROP SEQUENCE #{sequence}", [])
      end)
    end
  end

  defp task11_with_sql_fault!(_context, fun), do: fun.(fn -> 0 end)

  defp task11_owner!(repo, fun) do
    {:ok, value} =
      repo.transaction(fn ->
        SafeSQL.query!(repo, "SET LOCAL ROLE singularity_table_owner", [])
        fun.()
      end)

    value
  end

  def task11_with_parked_installation!(runtime, fun) do
    repositories = runtime.repositories
    config = MigrationRepo.config()

    require!(
      NativeAssetFixture.repo_identities() == repositories,
      "Task11 sentinel repository ownership changed before parking"
    )

    require!(
      is_pid(runtime.infrastructure) and Process.alive?(runtime.infrastructure),
      "Task11 sentinel was not genuinely published"
    )

    :ok = Supervisor.stop(runtime.infrastructure)

    for {repo, {pid, database}} <- repositories do
      require!(
        database == runtime.destination.database and Process.whereis(repo) == pid,
        "Task11 refuses to stop an unowned sentinel repository"
      )

      :ok = Supervisor.stop(pid)

      require!(
        not Process.alive?(pid) and is_nil(Process.whereis(repo)),
        "Task11 sentinel repository did not park naturally"
      )
    end

    require!(
      Keyword.fetch!(config, :database) == runtime.destination.database,
      "Task11 sentinel reader database differs"
    )

    require!(
      is_nil(Process.whereis(Task11SentinelReadRepo)),
      "Task11 sentinel reader is already owned elsewhere"
    )

    options = config |> Keyword.put(:name, Task11SentinelReadRepo) |> Keyword.put(:pool_size, 2)
    previous = Application.fetch_env(:singularity_storage, Task11SentinelReadRepo)
    owner = runtime.owner

    ExUnit.Callbacks.on_exit(fn ->
      try do
        ResourceOwner.close(owner)
      after
        case previous do
          {:ok, value} -> Application.put_env(:singularity_storage, Task11SentinelReadRepo, value)
          :error -> Application.delete_env(:singularity_storage, Task11SentinelReadRepo)
        end
      end
    end)

    try do
      Application.put_env(:singularity_storage, Task11SentinelReadRepo, options)
      {:ok, reader} = Task11SentinelReadRepo.start_link(options)

      try do
        result = fun.(Task11SentinelReadRepo)

        require!(
          Process.whereis(Task11SentinelReadRepo) == reader and Process.alive?(reader),
          "Task11 sentinel read repository was replaced"
        )

        require!(
          Enum.all?(repositories, fn {repo, {pid, _}} ->
            not Process.alive?(pid) and is_nil(Process.whereis(repo))
          end),
          "Task11 resurrected parked sentinel repositories"
        )

        result
      after
        if Process.whereis(Task11SentinelReadRepo) == reader, do: Supervisor.stop(reader)
        require!(not Process.alive?(reader), "Task11 owned sentinel reader did not stop")
      end
    after
      case previous do
        {:ok, value} -> Application.put_env(:singularity_storage, Task11SentinelReadRepo, value)
        :error -> Application.delete_env(:singularity_storage, Task11SentinelReadRepo)
      end
    end
  end

  # END Task11 transparent native Runtime fault and lifecycle seams.
end
