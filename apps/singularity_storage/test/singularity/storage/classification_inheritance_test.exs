defmodule Singularity.Storage.ClassificationInheritanceTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.AuditEvent, as: CoreAuditEvent
  alias Singularity.Core.OutboxEvent, as: CoreOutboxEvent
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.Postgres.AssetSearchStore
  alias Singularity.Storage.Postgres.AuditSink
  alias Singularity.Storage.Postgres.Outbox
  alias Singularity.Storage.Schema.Audit.BackupManifest
  alias Singularity.Storage.Schema.Audit.BackupManifestObject
  alias Singularity.Storage.Schema.Audit.Event, as: StoredAuditEvent
  alias Singularity.Storage.Schema.Content.Asset
  alias Singularity.Storage.Schema.Content.AssetMetadata
  alias Singularity.Storage.Schema.Content.AssetObject
  alias Singularity.Storage.Schema.Content.AssetSearchDocument
  alias Singularity.Storage.Schema.Content.ResourceVersion
  alias Singularity.Storage.Schema.Core.KeyDomain
  alias Singularity.Storage.Schema.Core.OutboxEvent, as: StoredOutboxEvent
  alias Singularity.Storage.Schema.Jobs.JobSubmission
  alias Singularity.Storage.ScopedRepo

  @schemas [
    {Singularity.Storage.Schema.Identity.Person, "identity", "people"},
    {Singularity.Storage.Schema.Identity.Account, "identity", "accounts"},
    {Singularity.Storage.Schema.Identity.Credential, "identity", "credentials"},
    {Singularity.Storage.Schema.Identity.Principal, "identity", "principals"},
    {Singularity.Storage.Schema.Identity.Session, "identity", "sessions"},
    {Singularity.Storage.Schema.Identity.Device, "identity", "devices"},
    {Singularity.Storage.Schema.Identity.AuthAttempt, "identity", "auth_attempts"},
    {Singularity.Storage.Schema.Identity.SecuritySetting, "identity", "security_settings"},
    {Singularity.Storage.Schema.Core.Vault, "core", "vaults"},
    {Singularity.Storage.Schema.Core.VaultMember, "core", "vault_members"},
    {Singularity.Storage.Schema.Core.Capability, "core", "capabilities"},
    {Singularity.Storage.Schema.Core.PrincipalCapability, "core", "principal_capabilities"},
    {Singularity.Storage.Schema.Core.DataClassification, "core", "data_classifications"},
    {Singularity.Storage.Schema.Core.KeyDomain, "core", "key_domains"},
    {Singularity.Storage.Schema.Core.VaultKeyVersion, "core", "vault_key_versions"},
    {Singularity.Storage.Schema.Core.VaultKeyWrapper, "core", "vault_key_wrappers"},
    {Singularity.Storage.Schema.Core.DomainKeyVersion, "core", "domain_key_versions"},
    {Singularity.Storage.Schema.Core.DomainDedupKeyWrapper, "core", "domain_dedup_key_wrappers"},
    {Singularity.Storage.Schema.Core.OutboxEvent, "core", "outbox_events"},
    {Singularity.Storage.Schema.Content.Resource, "content", "resources"},
    {Singularity.Storage.Schema.Content.ResourceVersion, "content", "resource_versions"},
    {Singularity.Storage.Schema.Content.Asset, "content", "assets"},
    {Singularity.Storage.Schema.Content.AssetStage, "content", "asset_stages"},
    {Singularity.Storage.Schema.Content.AssetObject, "content", "asset_objects"},
    {Singularity.Storage.Schema.Content.AssetKeyEnvelope, "content", "asset_key_envelopes"},
    {Singularity.Storage.Schema.Content.AssetMetadata, "content", "asset_metadata"},
    {Singularity.Storage.Schema.Content.AssetSearchDocument, "content", "asset_search_documents"},
    {Singularity.Storage.Schema.Content.ResourceAsset, "content", "resource_assets"},
    {Singularity.Storage.Schema.Content.SourceReference, "content", "source_references"},
    {Singularity.Storage.Schema.Content.Tombstone, "content", "tombstones"},
    {Singularity.Storage.Schema.Content.UploadGrant, "content", "upload_grants"},
    {Singularity.Storage.Schema.Jobs.JobSubmission, "jobs", "job_submissions"},
    {Singularity.Storage.Schema.Jobs.JobProgress, "jobs", "job_progress"},
    {Singularity.Storage.Schema.Jobs.EffectReceipt, "jobs", "effect_receipts"},
    {Singularity.Storage.Schema.Audit.Event, "audit", "events"},
    {Singularity.Storage.Schema.Audit.BackupManifest, "audit", "backup_manifests"},
    {Singularity.Storage.Schema.Audit.BackupManifestObject, "audit", "backup_manifest_objects"}
  ]

  test "maps exactly one internal schema to every foundation table" do
    assert Enum.map(@schemas, fn {schema, _prefix, _source} ->
             {schema.__schema__(:prefix), schema.__schema__(:source)}
           end) ==
             Enum.map(@schemas, fn {_schema, prefix, source} -> {prefix, source} end)
  end

  test "classification and vault identity survive the complete persistence chain" do
    %{one: fixture} = Fixtures.two_vaults!()
    fixture = load_ids(fixture)

    chain =
      ScopedRepo.transact(
        RequestRepo,
        %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
        fn repo -> persist_chain(repo, fixture) end
      )

    assert Enum.all?(
             [
               chain.resource_version,
               chain.asset,
               chain.object,
               chain.metadata,
               chain.search_document,
               chain.outbox_event,
               chain.job_submission,
               chain.audit_event,
               chain.backup_entry
             ],
             &(&1.vault_id == fixture.vault_id and &1.classification == :private)
           )
  end

  defp persist_chain(repo, fixture) do
    key_domain_id = Ecto.UUID.generate()
    object_id = Ecto.UUID.generate()
    outbox_event_id = Ecto.UUID.generate()
    audit_event_id = Ecto.UUID.generate()
    manifest_id = Ecto.UUID.generate()
    digest = :crypto.hash(:sha256, "classification-chain")

    {:ok, _key_domain} =
      repo.insert(
        KeyDomain.create_changeset(%KeyDomain{}, %{
          id: key_domain_id,
          vault_id: fixture.vault_id,
          classification: :private,
          kind: "content",
          state: :active
        })
      )

    {:ok, object} =
      repo.insert(
        AssetObject.create_changeset(%AssetObject{}, %{
          id: object_id,
          vault_id: fixture.vault_id,
          key_domain_id: key_domain_id,
          classification: :private,
          lookup_digest: digest,
          ciphertext_hash: digest,
          plaintext_byte_size: 4,
          ciphertext_byte_size: 20,
          storage_ref: "objects/classification-chain",
          format_version: 1,
          lifecycle: :available
        })
      )

    asset = repo.get!(Asset, fixture.asset_id)

    {:ok, asset} =
      repo.update(
        Asset.attach_object_changeset(asset, %{
          asset_object_id: object.id
        })
      )

    {:ok, metadata} =
      repo.insert(
        AssetMetadata.upsert_changeset(%AssetMetadata{}, %{
          id: Ecto.UUID.generate(),
          asset_id: fixture.asset_id,
          resource_version_id: fixture.resource_version_id,
          vault_id: fixture.vault_id,
          classification: :private,
          projection_version: 1,
          original_filename: "classification.bin",
          declared_media_type: "application/octet-stream",
          plaintext_byte_size: 4,
          extraction_state: :completed
        })
      )

    :ok =
      AssetSearchStore.upsert(repo, %{
        asset_id: fixture.asset_id,
        resource_version_id: fixture.resource_version_id,
        vault_id: fixture.vault_id,
        classification: :private,
        state: :ready,
        detected_media_type: "application/octet-stream",
        resource_title: "Classification chain",
        original_filename: "classification.bin"
      })

    {:ok, outbox_value} =
      CoreOutboxEvent.new(%{
        outbox_event_id: outbox_event_id,
        event_type: "asset.classification_checked",
        idempotency_key: "classification-#{fixture.asset_id}",
        vault_id: fixture.vault_id,
        principal_id: fixture.principal_id,
        required_capability: "assets.read",
        authorization_epoch: 0,
        classification: :private,
        correlation_id: Ecto.UUID.generate(),
        causation_id: fixture.asset_id,
        expected_entity_revision: asset.state_revision,
        payload: %{"asset_id" => fixture.asset_id},
        occurred_at: DateTime.utc_now(:microsecond)
      })

    {:ok, ^outbox_value} = Outbox.append(repo, outbox_value)

    {:ok, job_submission} =
      repo.insert(
        JobSubmission.reserve_changeset(%JobSubmission{}, %{
          id: Ecto.UUID.generate(),
          vault_id: fixture.vault_id,
          outbox_event_id: outbox_event_id,
          classification: :private,
          idempotency_key: "classification-job-#{fixture.asset_id}",
          job_type: "classification_check"
        })
      )

    {:ok, audit_value} =
      CoreAuditEvent.new(%{
        audit_event_id: audit_event_id,
        actor_kind: :principal,
        principal_id: fixture.principal_id,
        vault_id: fixture.vault_id,
        action: "asset.classification_checked",
        classification: :private,
        correlation_id: outbox_value.correlation_id,
        occurred_at: outbox_value.occurred_at,
        metadata: %{"asset_id" => fixture.asset_id}
      })

    :ok = AuditSink.append(repo, audit_value)

    {:ok, _manifest} =
      repo.insert(
        BackupManifest.create_changeset(%BackupManifest{}, %{
          id: manifest_id,
          vault_id: fixture.vault_id,
          classification: :private,
          status: :pending,
          destination_ref: "backup/classification-chain",
          kdf_version: 1,
          kdf_salt: <<0::128>>,
          kdf_parameters: %{"memory" => 1},
          recovery_wrapper: <<0::128>>
        })
      )

    {:ok, backup_entry} =
      repo.insert(
        BackupManifestObject.create_changeset(%BackupManifestObject{}, %{
          id: Ecto.UUID.generate(),
          manifest_id: manifest_id,
          asset_object_id: object.id,
          vault_id: fixture.vault_id,
          classification: :private,
          inventory_position: 0,
          storage_ref: object.storage_ref,
          ciphertext_byte_size: object.ciphertext_byte_size,
          ciphertext_hash: object.ciphertext_hash
        })
      )

    %{
      resource_version: repo.get!(ResourceVersion, fixture.resource_version_id),
      asset: asset,
      object: object,
      metadata: metadata,
      search_document: repo.get!(AssetSearchDocument, fixture.asset_id),
      outbox_event: repo.get!(StoredOutboxEvent, outbox_event_id),
      job_submission: job_submission,
      audit_event: repo.get!(StoredAuditEvent, audit_event_id),
      backup_entry: backup_entry
    }
  end

  defp load_ids(fixture) do
    Map.new(fixture, fn
      {key, value}
      when key in [
             :account_id,
             :asset_id,
             :credential_id,
             :principal_id,
             :resource_id,
             :resource_version_id,
             :session_id,
             :vault_id
           ] ->
        {key, Ecto.UUID.load!(value)}

      pair ->
        pair
    end)
  end
end
