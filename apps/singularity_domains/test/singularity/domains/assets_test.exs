Code.require_file("../../support/fake/asset_repository.ex", __DIR__)
Code.require_file("../../support/fake/audit_sink.ex", __DIR__)
Code.require_file("../../support/fake/outbox.ex", __DIR__)

defmodule Singularity.Domains.AssetsTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Asset
  alias Singularity.Core.Error
  alias Singularity.Core.SourceReference
  alias Singularity.Domains.Assets
  alias Singularity.Domains.Assets.Repository, as: AssetRepository
  alias Singularity.Domains.Identity.Repository, as: IdentityRepository
  alias Singularity.Domains.Vaults.Repository, as: VaultRepository

  @asset_repository_callbacks [
    acknowledge_finalization: 2,
    consume_grant_and_create_stage: 2,
    consume_upload_grant: 2,
    create_upload_grant: 2,
    create_upload_intent: 2,
    mark_stage_abandoned: 2,
    prepare_verification: 2,
    record_job_failure: 3,
    record_sealed_stage: 2,
    record_verified_stage: 2,
    reserve_finalization: 2,
    resolve_finalization: 2,
    tombstone_and_release: 2,
    transition: 2
  ]

  setup do
    repository = start_fake(Fake.AssetRepository)
    audit = start_fake(Fake.AuditSink)
    outbox = start_fake(Fake.Outbox)

    context = %{repository: repository, audit: audit, outbox: outbox}

    {:ok,
     adapters: %{
       repository: Fake.AssetRepository,
       context: context,
       audit: Fake.AuditSink,
       outbox: Fake.Outbox
     }}
  end

  test "records a sealed upload and requests verification", %{adapters: adapters} do
    command = %{
      asset_id: "asset-001",
      vault_id: "vault-001",
      resource_version_id: "version-001",
      identity_id: "identity-001",
      sealed_ref: "sealed://vault-001/asset-001",
      filename: "evidence.bin",
      content_type: "application/octet-stream",
      byte_size: 4,
      checksum: "sha256:9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a",
      classification: :private
    }

    assert {:ok, %{asset: %{state: :uploaded}, outbox: outbox, audit: audit}} =
             Singularity.Domains.Assets.record_sealed_upload(adapters, command)

    assert outbox.event_type == "asset.verify_requested"
    assert outbox.vault_id == command.vault_id
    assert audit.operation == "asset.uploaded"
    assert audit.classification == :private

    assert [{:record_sealed_stage, _intent}] =
             Fake.AssetRepository.calls(adapters.context)

    assert [] = Fake.AuditSink.entries(adapters.context)
    assert [] = Fake.Outbox.entries(adapters.context)
  end

  test "a sealed upload can transition without manually seeding the repository", %{
    adapters: adapters
  } do
    command = %{
      asset_id: "asset-sealed-transition",
      vault_id: "vault-001",
      resource_version_id: "version-001",
      identity_id: "identity-001",
      sealed_ref: "sealed://vault-001/asset-sealed-transition",
      filename: "evidence.bin",
      content_type: "application/octet-stream",
      byte_size: 4,
      checksum: "sha256:9f64",
      classification: :private
    }

    assert {:ok, %{asset: uploaded}} =
             Assets.record_sealed_upload(adapters, command)

    transition_command = %{
      asset_id: command.asset_id,
      principal_id: command.identity_id,
      classification: :private,
      expected_state_revision: 0,
      to: :verified
    }

    assert {:ok, :applied,
            %Asset{
              asset_id: "asset-sealed-transition",
              state: :verified,
              state_revision: 1
            }} = Assets.transition(adapters, transition_command)

    assert uploaded.state == :uploaded
  end

  test "a sealed upload without a resource version remains transition-capable", %{
    adapters: adapters
  } do
    command = %{
      asset_id: "asset-without-version",
      vault_id: "vault-001",
      identity_id: "identity-001",
      sealed_ref: "sealed://vault-001/asset-without-version",
      filename: "evidence.bin",
      content_type: "application/octet-stream",
      byte_size: 4,
      checksum: "sha256:9f64",
      classification: :private
    }

    assert {:ok,
            %{
              asset: %Asset{
                resource_version_id: "sealed-upload/asset-without-version",
                state: :uploaded,
                state_revision: 0
              }
            }} = Assets.record_sealed_upload(adapters, command)

    assert {:ok, :applied,
            %Asset{
              asset_id: "asset-without-version",
              state: :verified,
              state_revision: 1
            }} =
             Assets.transition(adapters, %{
               asset_id: command.asset_id,
               principal_id: command.identity_id,
               classification: :private,
               expected_state_revision: 0,
               to: :verified
             })
  end

  test "domain repositories expose only intent-oriented callbacks" do
    assert Enum.sort(AssetRepository.behaviour_info(:callbacks)) ==
             Enum.sort(@asset_repository_callbacks)

    assert IdentityRepository.behaviour_info(:callbacks) == [bootstrap_owner: 2]
    assert VaultRepository.behaviour_info(:callbacks) == [resolve_authorization: 2]
  end

  test "creates a staged upload intent with minimal server-observed provenance", %{
    adapters: adapters
  } do
    observed_at = ~U[2026-07-18 08:00:00Z]

    command = %{
      idempotency_key: "upload-intent-001",
      asset_id: "asset-001",
      vault_id: "vault-001",
      resource_version_id: "version-001",
      source_reference_id: "source-001",
      resource_version_classification: :private,
      classification: :sensitive,
      principal_id: "principal-001",
      filename: "evidence.bin",
      declared_media_type: "application/octet-stream",
      byte_size: 4,
      digest: "sha256:9f64",
      server_observed_at: observed_at,
      client_path: "/Users/alice/Documents/evidence.bin"
    }

    assert {:ok,
            %{
              asset: %Asset{
                asset_id: "asset-001",
                classification: :sensitive,
                state: :staging,
                state_revision: 0
              },
              provenance: %SourceReference{
                kind: :browser_upload,
                principal_id: "principal-001",
                observed_at: ^observed_at,
                metadata: %{
                  "byte_size" => 4,
                  "declared_media_type" => "application/octet-stream",
                  "digest" => "sha256:9f64",
                  "filename" => "evidence.bin"
                }
              }
            } = intent} = Assets.create_upload_intent(adapters, command)

    refute Map.has_key?(intent.provenance.metadata, "client_path")

    assert [{:create_upload_intent, ^intent}] =
             Fake.AssetRepository.calls(adapters.context)
  end

  test "a stale transition is a successful no-op without audit or outbox duplication", %{
    adapters: adapters
  } do
    assert {:ok, asset} =
             Asset.new(%{
               asset_id: "asset-stale",
               vault_id: "vault-001",
               resource_version_id: "version-001",
               classification: :private,
               state: :staging,
               state_revision: 1
             })

    Agent.update(adapters.context.repository, fn state ->
      put_in(state, [:assets, asset.asset_id], asset)
    end)

    command = %{
      asset_id: asset.asset_id,
      principal_id: "principal-001",
      classification: :private,
      expected_state_revision: 0,
      to: :uploaded
    }

    assert {:ok, :stale, ^asset} = Assets.transition(adapters, command)
    assert [] = Fake.AssetRepository.audit_entries(adapters.context)
    assert [] = Fake.AssetRepository.outbox_entries(adapters.context)
    assert [] = Fake.AuditSink.entries(adapters.context)
    assert [] = Fake.Outbox.entries(adapters.context)
  end

  test "an applied transition records the asset audit and outbox atomically", %{
    adapters: adapters
  } do
    assert {:ok, asset} =
             Asset.new(%{
               asset_id: "asset-applied",
               vault_id: "vault-001",
               resource_version_id: "version-001",
               classification: :private,
               state: :staging,
               state_revision: 0
             })

    Agent.update(adapters.context.repository, fn state ->
      put_in(state, [:assets, asset.asset_id], asset)
    end)

    command = %{
      asset_id: asset.asset_id,
      principal_id: "principal-001",
      classification: :private,
      expected_state_revision: 0,
      to: :uploaded
    }

    assert {:ok, :applied,
            %Asset{
              asset_id: "asset-applied",
              state: :uploaded,
              state_revision: 1
            } = transitioned} = Assets.transition(adapters, command)

    assert [%{asset_id: "asset-applied", classification: :private}] =
             Fake.AssetRepository.audit_entries(adapters.context)

    assert [%{asset_id: "asset-applied", classification: :private}] =
             Fake.AssetRepository.outbox_entries(adapters.context)

    assert [
             {:transition, :applied,
              %{
                asset_id: "asset-applied",
                audit: %{asset_id: "asset-applied"},
                outbox: %{asset_id: "asset-applied"}
              }}
           ] = Fake.AssetRepository.calls(adapters.context)

    assert transitioned.classification == asset.classification
    assert [] = Fake.AuditSink.entries(adapters.context)
    assert [] = Fake.Outbox.entries(adapters.context)
  end

  test "deletion records a tombstone before its release follow-up without filesystem access", %{
    adapters: adapters
  } do
    assert {:ok, asset} =
             Asset.new(%{
               asset_id: "asset-delete",
               vault_id: "vault-001",
               resource_version_id: "version-001",
               classification: :sensitive,
               state: :ready,
               state_revision: 4
             })

    Agent.update(adapters.context.repository, fn state ->
      put_in(state, [:assets, asset.asset_id], asset)
    end)

    command = %{
      asset_id: asset.asset_id,
      principal_id: "principal-001",
      classification: :sensitive,
      expected_state_revision: 4
    }

    assert {:ok,
            %{
              asset: %Asset{state: :pending_delete, state_revision: 5},
              outbox: %{event_type: "asset.release_requested"}
            }} = Assets.tombstone_and_release(adapters, command)

    assert [
             {:tombstone, "asset-delete"},
             {:release_outbox, "asset.release_requested"}
           ] = Fake.AssetRepository.ordering(adapters.context)

    assert [{:tombstone_and_release, _intent}] =
             Fake.AssetRepository.calls(adapters.context)

    refute Map.has_key?(adapters, :filesystem)
    refute Map.has_key?(adapters, :object_storage)
    assert [] = Fake.AuditSink.entries(adapters.context)
    assert [] = Fake.Outbox.entries(adapters.context)
  end

  test "classification is preserved or strengthened across the asset event and audit chain", %{
    adapters: adapters
  } do
    command = %{
      asset_id: "asset-classification",
      vault_id: "vault-001",
      resource_version_id: "version-001",
      identity_id: "identity-001",
      sealed_ref: "sealed://vault-001/asset-classification",
      filename: "evidence.bin",
      content_type: "application/octet-stream",
      byte_size: 4,
      checksum: "sha256:9f64",
      resource_version_classification: :private,
      classification: :sensitive,
      outbox_classification: :restricted,
      audit_classification: :restricted
    }

    assert {:ok,
            %{
              asset: %{classification: :sensitive},
              outbox: %{classification: :restricted},
              audit: %{classification: :restricted}
            }} = Assets.record_sealed_upload(adapters, command)

    assert {:error, %Error{code: :forbidden}} =
             Assets.record_sealed_upload(adapters, %{
               command
               | resource_version_classification: :sensitive,
                 classification: :private,
                 outbox_classification: :private,
                 audit_classification: :private
             })

    assert {:error, %Error{code: :forbidden}} =
             Assets.record_sealed_upload(adapters, %{
               command
               | classification: :sensitive,
                 outbox_classification: :private,
                 audit_classification: :private
             })

    assert {:error, %Error{code: :forbidden}} =
             Assets.record_sealed_upload(adapters, %{
               command
               | classification: :private,
                 outbox_classification: :sensitive,
                 audit_classification: :private
             })

    assert [{:record_sealed_stage, _intent}] =
             Fake.AssetRepository.calls(adapters.context)
  end

  defp start_fake(module) do
    start_supervised!(%{
      id: make_ref(),
      start: {module, :start_link, [[]]}
    })
  end
end
