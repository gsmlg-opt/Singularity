defmodule Singularity.Runtime.NativeTextBackupRestoreLiveTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Mix.Tasks.Singularity.Test.Restore.{OracleDestination, OracleMaintenanceMode}
  alias Singularity.Runtime.{Api, NativeAssetFixture, RestoreVault}
  alias Singularity.Storage.Backup.KnowledgeFixtureResourceOwner, as: ResourceOwner

  alias Singularity.Storage.Backup.{
    BundleReader,
    LocalDestination,
    Reconciler
  }

  alias Singularity.Storage.Backup.IntegrityAudit, as: StorageIntegrityAudit
  alias Singularity.Storage.Crypto.{BackupKeyDeriver, ChunkedAEAD, RecoveredVaultKey}
  alias Singularity.Storage.MigrationRepo

  defmodule ObservedLogicalVerifier do
    @moduledoc false

    alias Singularity.Storage.Backup.LogicalBundleVerifier

    def init(_context, binding), do: LogicalBundleVerifier.init(binding)

    def handle_event(_context, state, event),
      do: LogicalBundleVerifier.handle_event(state, event)

    def finish(context, state, manifest) do
      result = LogicalBundleVerifier.finish(state, manifest)

      case result do
        {:ok, _cut} -> send(context.observer, {context.reference, :wire_cut, state.cut})
        _error -> :ok
      end

      result
    end
  end

  defmodule ObservedRestorer do
    @moduledoc false

    import ExUnit.Assertions

    alias Singularity.Storage.Backup.Restorer

    def import(%{restorer: context, observer: observer, reference: reference}, repo, input) do
      assert_received {^reference, :wire_cut, wire_cut}
      assert wire_cut.logical_version == 3
      assert wire_cut.manifest_id == input.cut.manifest_id
      assert wire_cut.vault_id == input.cut.vault_id
      assert length(wire_cut.table_count_vector) == 38
      assert Enum.drop(wire_cut.table_count_vector, 30) == List.duplicate(0, 8)

      result = Restorer.import(context, repo, input)

      case result do
        {:ok, %Restorer.Imported{} = imported} ->
          send(observer, {
            reference,
            :imported,
            imported.cut.logical_version,
            imported.manifest.manifest_id
          })

        _error ->
          :ok
      end

      result
    end

    def rewrap_owner(%{restorer: context}, imported, password, capability),
      do: Restorer.rewrap_owner(context, imported, password, capability)

    def complete_restore(%{restorer: context}, rewrapped),
      do: Restorer.complete_restore(context, rewrapped)
  end

  @tag :tmp_dir
  test "default V3 restores genuine text originals into an empty sequentially owned destination",
       %{
         tmp_dir: tmp_dir
       } do
    backup_root = Path.join(tmp_dir, "encrypted-bundle-#{Ecto.UUID.generate()}")
    File.mkdir!(backup_root)
    on_exit(fn -> File.rm_rf!(backup_root) end)

    try do
      File.chmod!(backup_root, 0o700)
      source = backup_source!(backup_root)

      # with_fixture has synchronously released every source-owned resource.
      # Its retained cleanup actor, if any, does not own live infrastructure.
      refute Process.alive?(source.infrastructure)
      refute File.exists?(source.object_root)
      assert File.regular?(Path.join(backup_root, source.destination_ref))

      {owner, destination} = ResourceOwner.open(migration_pool_size: 2)

      try do
        refute destination.database == source.database
        assert {:ok, []} = File.ls(destination.object_root)
        Application.put_env(:singularity_runtime, :maintenance_mode, true)
        Application.put_env(:singularity_runtime, :start_infrastructure, false)
        reference = make_ref()
        new_password = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

        assert {:ok, %{manifest_id: manifest_id}} =
                 RestoreVault.run(restore_context(destination, backup_root, reference), %{
                   source: source.destination_ref,
                   passphrase: source.passphrase,
                   new_password: new_password
                 })

        assert manifest_id == source.operation_id
        assert_received {^reference, :imported, 3, ^manifest_id}

        # No destination bootstrap or runtime worker starts before completion.
        Application.put_env(:singularity_runtime, :maintenance_mode, false)
        runtime = NativeAssetFixture.start_runtime!(owner, destination)
        credentials = %{source.credentials | password: new_password}
        session = NativeAssetFixture.login!(credentials)

        for original <- source.originals do
          assert assert_original!(session, original) == original.identity
        end

        assert_listing!(session, source.originals)
        assert NativeAssetFixture.repo_identities() == runtime.repositories
      after
        ResourceOwner.close(owner)
      end
    after
      # Only the freshly created private directory contains preserved ciphertext.
      File.rm_rf!(backup_root)
    end
  end

  defp backup_source!(backup_root) do
    NativeAssetFixture.with_fixture(fn fixture ->
      originals =
        for {filename, media_type, chunks} <- [
              {"empty.txt", "text/plain", []},
              {"plain.txt", "text/plain", ["native backup original\r\n"]},
              {"unicode.txt", "text/plain",
               [<<0xEF>>, <<0xBB, 0xBF, 0xE4>>, <<0xB8, 0xAD>>, "é\r\n"]},
              {"markdown.md", "text/markdown",
               ["# Native backup original\r\n", "[label](https://example.test)\n"]}
            ] do
          upload = NativeAssetFixture.upload!(fixture, media_type, chunks, filename)
          NativeAssetFixture.verify_and_finalize!()

          original = %{
            asset_id: upload.asset_id,
            filename: filename,
            media_type: media_type,
            bytes: IO.iodata_to_binary(chunks)
          }

          Map.put(original, :identity, assert_original!(fixture.session, original))
        end

      assert_listing!(fixture.session, originals)
      passphrase = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      assert {:ok, requested} = Api.request_backup(fixture.session, passphrase)
      operation_id = requested.operation_id
      assert {:ok, ^operation_id} = Ecto.UUID.cast(operation_id)
      NativeAssetFixture.dispatch!()
      assert %{failure: 0, success: 1} = Oban.drain_queue(Singularity.Oban, queue: :backup)

      assert {:ok, %{operation_id: ^operation_id, status: :sealed}} =
               Api.backup_status(fixture.session, operation_id)

      # Observe only this owned operation's persisted destination. No synthetic
      # manifest, crypto, recovery wrapper or metadata completion is introduced.
      assert %{rows: [[destination_ref]]} =
               NativeAssetFixture.observe!(
                 """
                 SELECT destination_ref FROM audit.backup_manifests
                 WHERE id = $1 AND vault_id = $2 AND status = 'sealed'
                 """,
                 [Ecto.UUID.dump!(operation_id), Ecto.UUID.dump!(fixture.session.vault_id)]
               )

      assert {:ok, source} =
               LocalDestination.reader_source(
                 %{backup_root: Application.fetch_env!(:singularity_storage, :backup_root)},
                 destination_ref
               )

      preserved_ref = "#{operation_id}.bundle"
      preserved_path = Path.join(backup_root, preserved_ref)
      File.cp!(source.path, preserved_path)
      File.chmod!(preserved_path, 0o600)
      assert {:ok, %{type: :regular, size: size}} = File.stat(preserved_path)
      assert size > 0

      assert {:ok, ^preserved_ref} =
               LocalDestination.normalize(%{backup_root: backup_root}, preserved_ref)

      %{
        credentials: fixture.credentials,
        originals: originals,
        passphrase: passphrase,
        operation_id: operation_id,
        destination_ref: preserved_ref,
        infrastructure: fixture.infrastructure,
        object_root: fixture.destination.object_root,
        database: fixture.destination.database
      }
    end)
  end

  defp assert_original!(session, original) do
    %{asset_id: asset_id, filename: filename, media_type: media_type, bytes: bytes} = original
    size = byte_size(bytes)

    assert {:ok,
            %{
              id: ^asset_id,
              resource_version_id: resource_version_id,
              original_filename: ^filename,
              detected_media_type: ^media_type,
              state: :ready,
              state_revision: 5
            }} = Api.asset_summary(session, asset_id)

    assert %{
             rows: [
               [
                 source_reference_id,
                 resource_id,
                 ^resource_version_id,
                 object_id,
                 ^filename,
                 ^media_type,
                 ^size,
                 ^filename,
                 ^media_type,
                 ^size,
                 "completed",
                 "upload_text_v1",
                 ^media_type,
                 true,
                 nil,
                 nil,
                 nil
               ]
             ]
           } =
             NativeAssetFixture.observe!(
               """
               SELECT source.id::text, version.resource_id::text,
                 asset.resource_version_id::text, asset.asset_object_id::text,
                 source.original_filename, source.declared_media_type, source.byte_size,
                 metadata.original_filename, metadata.declared_media_type,
                 metadata.plaintext_byte_size, metadata.extraction_state,
                 metadata.extractor_version, metadata.detected_media_type,
                 metadata.completed_at IS NOT NULL, metadata.pdf_header_version,
                 metadata.image_width, metadata.image_height
               FROM content.assets asset
               JOIN content.resource_versions version ON version.id = asset.resource_version_id
                 AND version.vault_id = asset.vault_id
               JOIN content.source_references source ON source.resource_version_id = version.id
                 AND source.vault_id = asset.vault_id
               JOIN content.asset_metadata metadata ON metadata.asset_id = asset.id
                 AND metadata.resource_version_id = version.id AND metadata.vault_id = asset.vault_id
               WHERE asset.id = $1 AND asset.vault_id = $2
               """,
               [Ecto.UUID.dump!(asset_id), Ecto.UUID.dump!(session.vault_id)]
             )

    for id <- [source_reference_id, resource_id, resource_version_id, object_id] do
      assert {:ok, ^id} = Ecto.UUID.cast(id)
    end

    assert {:ok,
            %{
              status: 200,
              body: ^bytes,
              content_length: ^size,
              detected_media_type: ^media_type
            }} = Api.download(session, asset_id, nil)

    %{
      source_reference_id: source_reference_id,
      resource_id: resource_id,
      resource_version_id: resource_version_id,
      object_id: object_id
    }
  end

  defp assert_listing!(session, originals) do
    assert {:ok, %{items: items, next_cursor: nil}} = Api.list_assets(session, %{state: :ready})

    assert Map.new(items, fn item ->
             {item.id,
              {item.resource_version_id, item.original_filename, item.detected_media_type,
               item.state}}
           end) ==
             Map.new(originals, fn original ->
               {original.asset_id,
                {original.identity.resource_version_id, original.filename, original.media_type,
                 :ready}}
             end)
  end

  defp restore_context(destination, backup_root, reference) do
    bootstrap = Application.fetch_env!(:singularity_runtime, :bootstrap_owner)
    object_storage = Singularity.Runtime.StorageAdapter.configured()

    authenticator = %{
      backup_cipher: ChunkedAEAD,
      backup_key_deriver: BackupKeyDeriver,
      backup_key_lease: Singularity.Runtime.BackupKeyLease,
      bundle_reader: BundleReader,
      destination: {LocalDestination, %{backup_root: backup_root}},
      logical_verifier: {ObservedLogicalVerifier, %{observer: self(), reference: reference}},
      recovered_vault_key: RecoveredVaultKey,
      restore_crypto_adapter: Singularity.Runtime.BackupKeyLease.StorageAdapter,
      restore_key_ttl_ms: :timer.minutes(5)
    }

    restorer = %{
      integrity_issuer: Singularity.Runtime.RestoreIntegrityLease,
      integrity_ttl_ms: :timer.minutes(5),
      key_deriver: bootstrap.key_deriver,
      key_wrapper: bootstrap.key_wrapper,
      migration_repo: MigrationRepo,
      object_storage: object_storage,
      password_hasher: bootstrap.password_hasher,
      password_hasher_context: bootstrap.password_hasher_context,
      random_bytes: bootstrap.random_bytes,
      recovered_vault_key: RecoveredVaultKey,
      vault_kdf_params: bootstrap.vault_kdf_params
    }

    integrity = %{
      audit: {StorageIntegrityAudit, MigrationRepo},
      ciphertext_auditor: StorageIntegrityAudit,
      object_storage: object_storage,
      restore_integrity_lease: Singularity.Runtime.RestoreIntegrityLease,
      search_rebuilder: {Singularity.Storage.Backup.KnowledgeIntegrityAudit, MigrationRepo}
    }

    %{
      authenticator: {Singularity.Runtime.RestoreAuthenticator, authenticator},
      destination:
        {OracleDestination, %{backup_root: backup_root, storage_root: destination.object_root}},
      integrity: {Singularity.Runtime.IntegrityAudit, integrity},
      maintenance_mode: {OracleMaintenanceMode, true},
      migration_repo: MigrationRepo,
      reconciler: {Reconciler, MigrationRepo},
      restorer: {ObservedRestorer, %{restorer: restorer, observer: self(), reference: reference}}
    }
  end
end
