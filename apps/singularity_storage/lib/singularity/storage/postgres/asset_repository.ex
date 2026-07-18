defmodule Singularity.Storage.Postgres.AssetRepository do
  @moduledoc false

  @behaviour Singularity.Domains.Assets.Repository

  import Ecto.Query

  alias Ecto.Multi
  alias Singularity.Core.Asset
  alias Singularity.Core.AssetState
  alias Singularity.Core.Classification
  alias Singularity.Core.Error
  alias Singularity.Core.Types
  alias Singularity.Storage.Schema.Audit.Event, as: AuditEvent
  alias Singularity.Storage.Schema.Content.Asset, as: StoredAsset
  alias Singularity.Storage.Schema.Content.AssetMetadata
  alias Singularity.Storage.Schema.Content.ResourceAsset
  alias Singularity.Storage.Schema.Content.ResourceVersion
  alias Singularity.Storage.Schema.Content.SourceReference
  alias Singularity.Storage.Schema.Content.Tombstone
  alias Singularity.Storage.Schema.Content.UploadGrant
  alias Singularity.Storage.Schema.Core.OutboxEvent
  alias Singularity.Storage.Postgres.UUID

  @impl true
  def create_upload_intent(repo, %{asset: asset, provenance: provenance} = intent) do
    with :ok <- validate_upload_intent_ids(asset, provenance),
         {:ok, canonical_classification} <-
           lock_resource_version_classification(repo, asset),
         :ok <-
           Classification.assert_not_downgraded(
             canonical_classification,
             asset.classification
           ) do
      persist_upload_intent(repo, intent)
    end
  rescue
    _error in [Ecto.Query.CastError] ->
      {:error, Error.new(:invalid)}

    error in [Ecto.ConstraintError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  def create_upload_intent(_repo, _intent), do: {:error, Error.new(:invalid)}

  defp persist_upload_intent(repo, %{asset: asset, provenance: provenance} = intent) do
    correlation_id = Ecto.UUID.generate()

    outbox =
      outbox_changeset(%{
        event_type: "asset.upload_intent_created",
        idempotency_key: "upload-intent:#{intent.idempotency_key}",
        vault_id: asset.vault_id,
        principal_id: provenance.principal_id,
        required_capability: "assets.upload",
        authorization_epoch: authorization_epoch(repo, asset.vault_id),
        classification: asset.classification,
        correlation_id: correlation_id,
        causation_id: provenance.source_reference_id,
        expected_entity_revision: 0,
        payload: %{
          "asset_id" => asset.asset_id,
          "resource_version_id" => asset.resource_version_id
        },
        occurred_at: provenance.observed_at
      })

    asset_changeset =
      StoredAsset.create_changeset(%StoredAsset{}, %{
        id: asset.asset_id,
        vault_id: asset.vault_id,
        resource_version_id: asset.resource_version_id,
        classification: asset.classification,
        state: asset.state,
        state_revision: asset.state_revision,
        attempt: asset.attempt
      })

    provenance_changeset =
      SourceReference.create_changeset(%SourceReference{}, %{
        id: provenance.source_reference_id,
        vault_id: provenance.vault_id,
        resource_version_id: provenance.resource_version_id,
        principal_id: provenance.principal_id,
        classification: asset.classification,
        kind: provenance.kind,
        observed_at: provenance.observed_at,
        original_filename: provenance.metadata["filename"],
        declared_media_type: provenance.metadata["declared_media_type"],
        byte_size: provenance.metadata["byte_size"],
        idempotency_key_digest: :crypto.hash(:sha256, intent.idempotency_key)
      })

    reference_changeset =
      ResourceAsset.create_changeset(%ResourceAsset{}, %{
        resource_version_id: asset.resource_version_id,
        asset_id: asset.asset_id,
        vault_id: asset.vault_id,
        classification: asset.classification
      })

    Multi.new()
    |> Multi.insert(:outbox, outbox)
    |> Multi.insert(:asset, asset_changeset)
    |> Multi.insert(:provenance, provenance_changeset)
    |> Multi.insert(:resource_asset, reference_changeset)
    |> repo.transaction()
    |> case do
      {:ok, _changes} ->
        {:ok, intent}

      {:error, _operation, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset_error(changeset)}

      {:error, _operation, _reason, _changes} ->
        {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  @impl true
  def consume_upload_grant(repo, %{grant_id: grant_id, consumed_at: consumed_at} = intent) do
    with :ok <- UUID.validate(grant_id),
         {:ok, ^consumed_at} <- Types.utc_datetime(intent, :consumed_at) do
      eligible =
        from(grant in UploadGrant,
          where:
            grant.id == ^grant_id and
              is_nil(grant.consumed_at) and
              grant.expires_at > fragment("statement_timestamp()"),
          update: [set: [consumed_at: fragment("statement_timestamp()")]],
          select: grant.consumed_at
        )

      case repo.update_all(eligible, []) do
        {1, [server_consumed_at]} ->
          {:ok, %{intent | consumed_at: server_consumed_at}}

        {0, _rows} ->
          case repo.get(UploadGrant, grant_id) do
            nil -> {:error, Error.new(:not_found)}
            %UploadGrant{} -> {:error, Error.new(:conflict)}
          end
      end
    end
  rescue
    _error in [Ecto.Query.CastError] ->
      {:error, Error.new(:invalid)}

    error in [Ecto.ConstraintError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  def consume_upload_grant(_repo, _intent), do: {:error, Error.new(:invalid)}

  @impl true
  def record_sealed_stage(repo, %{asset: asset} = intent) do
    now = DateTime.utc_now(:microsecond)
    correlation_id = Ecto.UUID.generate()

    with :ok <- validate_sealed_stage_ids(intent),
         {:ok, current} <- fetch_asset(repo, asset.asset_id),
         :ok <- validate_sealed_asset(current, asset),
         {:ok, transitioned} <-
           AssetState.transition(current, :uploaded, current.state_revision) do
      persisted_asset = %{
        transitioned
        | metadata: %{
            "byte_size" => asset.byte_size,
            "checksum" => asset.checksum,
            "content_type" => asset.content_type,
            "filename" => asset.filename,
            "principal_id" => asset.principal_id,
            "sealed_ref" => asset.sealed_ref
          }
      }

      outbox =
        outbox_changeset(%{
          event_type: intent.outbox.event_type,
          idempotency_key: "sealed-upload:#{asset.asset_id}",
          vault_id: asset.vault_id,
          principal_id: asset.principal_id,
          required_capability: "assets.verify",
          authorization_epoch: authorization_epoch(repo, asset.vault_id),
          classification: intent.outbox.classification,
          correlation_id: correlation_id,
          causation_id: asset.asset_id,
          expected_entity_revision: transitioned.state_revision,
          payload: %{"asset_id" => asset.asset_id},
          occurred_at: now
        })

      audit =
        audit_changeset(%{
          operation: intent.audit.operation,
          vault_id: asset.vault_id,
          principal_id: asset.principal_id,
          classification: intent.audit.classification,
          correlation_id: correlation_id,
          target_id: asset.asset_id,
          metadata: %{"state" => "uploaded"},
          occurred_at: now
        })

      update =
        from(stored_asset in StoredAsset,
          where:
            stored_asset.id == ^current.asset_id and
              stored_asset.vault_id == ^current.vault_id and
              stored_asset.state == :staging and
              stored_asset.state_revision == ^current.state_revision
        )

      metadata =
        AssetMetadata.upsert_changeset(%AssetMetadata{}, %{
          id: Ecto.UUID.generate(),
          asset_id: asset.asset_id,
          resource_version_id: current.resource_version_id,
          vault_id: current.vault_id,
          classification: asset.classification,
          projection_version: 1,
          original_filename: asset.filename,
          declared_media_type: asset.content_type,
          plaintext_byte_size: asset.byte_size,
          extraction_state: :pending
        })

      Multi.new()
      |> Multi.update_all(
        :asset,
        update,
        set: [
          state: :uploaded,
          state_revision: transitioned.state_revision,
          updated_at: now
        ]
      )
      |> Multi.run(:revision, fn _repo, %{asset: {count, _rows}} ->
        if count == 1, do: {:ok, :applied}, else: {:error, :conflict}
      end)
      # Task 8 supplies authenticated ciphertext sizes and protected digests.
      # This Task 7 intent cannot safely create an asset_stages row without them.
      |> Multi.insert(:metadata, metadata)
      |> Multi.insert(:audit, audit)
      |> Multi.insert(:outbox, outbox)
      |> repo.transaction()
      |> case do
        {:ok, _changes} ->
          {:ok, %{intent | asset: persisted_asset}}

        {:error, :revision, :conflict, _changes} ->
          {:error, Error.new(:conflict)}

        {:error, _operation, %Ecto.Changeset{} = changeset, _changes} ->
          {:error, changeset_error(changeset)}

        {:error, _operation, _reason, _changes} ->
          {:error, Error.new(:storage_unavailable, retryable?: true)}
      end
    end
  rescue
    _error in [Ecto.Query.CastError] ->
      {:error, Error.new(:invalid)}

    error in [Ecto.ConstraintError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  def record_sealed_stage(_repo, _intent), do: {:error, Error.new(:invalid)}

  @impl true
  def transition(repo, intent) do
    with :ok <- validate_transition_ids(intent),
         {:ok, current} <- fetch_asset(repo, intent.asset_id),
         :ok <- same_classification(current, intent.classification) do
      if current.state_revision != intent.expected_state_revision do
        {:ok, :stale, current}
      else
        apply_transition(repo, current, intent)
      end
    end
  rescue
    _error in [Ecto.Query.CastError] ->
      {:error, Error.new(:invalid)}
  end

  @impl true
  def tombstone_and_release(repo, intent) do
    with :ok <- validate_tombstone_ids(intent),
         {:ok, current} <- fetch_asset(repo, intent.asset_id),
         :ok <- same_classification(current, intent.classification),
         {:ok, tombstoned} <-
           AssetState.transition(
             current,
             :pending_delete,
             intent.expected_state_revision
           ) do
      persist_tombstone(repo, current, tombstoned, intent)
    end
  rescue
    _error in [Ecto.Query.CastError] ->
      {:error, Error.new(:invalid)}
  end

  defp apply_transition(repo, current, intent) do
    with {:ok, transitioned} <-
           AssetState.transition(
             current,
             intent.to,
             intent.expected_state_revision
           ) do
      now = DateTime.utc_now(:microsecond)
      correlation_id = Ecto.UUID.generate()

      update =
        from(asset in StoredAsset,
          where:
            asset.id == ^intent.asset_id and
              asset.vault_id == ^current.vault_id and
              asset.state_revision == ^intent.expected_state_revision
        )

      audit =
        audit_changeset(%{
          operation: intent.audit.operation,
          vault_id: current.vault_id,
          principal_id: intent.principal_id,
          classification: intent.audit.classification,
          correlation_id: correlation_id,
          target_id: intent.asset_id,
          metadata: %{"state" => Atom.to_string(intent.to)},
          occurred_at: now
        })

      outbox =
        outbox_changeset(%{
          event_type: intent.outbox.event_type,
          idempotency_key:
            "asset-transition:#{intent.asset_id}:#{intent.expected_state_revision}:#{intent.to}",
          vault_id: current.vault_id,
          principal_id: intent.principal_id,
          required_capability: "assets.transition",
          authorization_epoch: authorization_epoch(repo, current.vault_id),
          classification: intent.outbox.classification,
          correlation_id: correlation_id,
          causation_id: intent.asset_id,
          expected_entity_revision: intent.expected_state_revision,
          payload: %{
            "asset_id" => intent.asset_id,
            "to" => Atom.to_string(intent.to)
          },
          occurred_at: now
        })

      Multi.new()
      |> Multi.update_all(
        :asset,
        update,
        set: [
          state: intent.to,
          state_revision: intent.expected_state_revision + 1,
          updated_at: now
        ]
      )
      |> Multi.merge(fn
        %{asset: {1, _rows}} ->
          Multi.new()
          |> Multi.put(:revision, :applied)
          |> Multi.insert(:audit, audit)
          |> Multi.insert(:outbox, outbox)

        %{asset: {0, _rows}} ->
          Multi.put(Multi.new(), :revision, :stale)
      end)
      |> repo.transaction()
      |> case do
        {:ok, %{revision: :applied}} ->
          {:ok, :applied, transitioned}

        {:ok, %{revision: :stale}} ->
          case fetch_asset(repo, intent.asset_id) do
            {:ok, stale} -> {:ok, :stale, stale}
            {:error, %Error{}} = error -> error
          end

        {:error, _operation, %Ecto.Changeset{} = changeset, _changes} ->
          {:error, changeset_error(changeset)}

        {:error, _operation, _reason, _changes} ->
          {:error, Error.new(:storage_unavailable, retryable?: true)}
      end
    end
  end

  defp persist_tombstone(repo, current, tombstoned, intent) do
    now = DateTime.utc_now(:microsecond)
    correlation_id = Ecto.UUID.generate()

    update =
      from(asset in StoredAsset,
        where:
          asset.id == ^intent.asset_id and
            asset.vault_id == ^current.vault_id and
            asset.state_revision == ^intent.expected_state_revision
      )

    references =
      from(reference in ResourceAsset,
        where:
          reference.asset_id == ^intent.asset_id and
            reference.vault_id == ^current.vault_id and
            is_nil(reference.released_at)
      )

    Multi.new()
    |> Multi.update_all(
      :asset,
      update,
      set: [
        state: :pending_delete,
        state_revision: intent.expected_state_revision + 1,
        updated_at: now
      ]
    )
    |> Multi.run(:revision, fn _repo, %{asset: {count, _rows}} ->
      if count == 1, do: {:ok, :applied}, else: {:error, :conflict}
    end)
    |> Multi.insert(
      :tombstone,
      Tombstone.create_changeset(%Tombstone{}, %{
        id: Ecto.UUID.generate(),
        vault_id: current.vault_id,
        asset_id: intent.asset_id,
        principal_id: intent.principal_id,
        classification: intent.classification,
        reason: "asset deletion requested",
        retention_metadata: %{},
        deleted_at: now
      })
    )
    |> Multi.update_all(:released_references, references, set: [released_at: now])
    |> Multi.insert(
      :audit,
      audit_changeset(%{
        operation: intent.audit.operation,
        vault_id: current.vault_id,
        principal_id: intent.principal_id,
        classification: intent.audit.classification,
        correlation_id: correlation_id,
        target_id: intent.asset_id,
        metadata: %{"state" => "pending_delete"},
        occurred_at: now
      })
    )
    |> Multi.insert(
      :outbox,
      outbox_changeset(%{
        event_type: intent.outbox.event_type,
        idempotency_key: "asset-release:#{intent.asset_id}:#{intent.expected_state_revision}",
        vault_id: current.vault_id,
        principal_id: intent.principal_id,
        required_capability: "assets.release",
        authorization_epoch: authorization_epoch(repo, current.vault_id),
        classification: intent.outbox.classification,
        correlation_id: correlation_id,
        causation_id: intent.asset_id,
        expected_entity_revision: intent.expected_state_revision,
        payload: %{"asset_id" => intent.asset_id},
        occurred_at: now
      })
    )
    |> repo.transaction()
    |> case do
      {:ok, _changes} ->
        {:ok, %{asset: tombstoned, audit: intent.audit, outbox: intent.outbox}}

      {:error, :revision, :conflict, _changes} ->
        {:error, Error.new(:conflict)}

      {:error, _operation, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset_error(changeset)}

      {:error, _operation, _reason, _changes} ->
        {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  defp validate_sealed_asset(current, asset) do
    cond do
      current.vault_id != asset.vault_id ->
        {:error, Error.new(:forbidden)}

      current.classification != asset.classification ->
        {:error, Error.new(:forbidden)}

      is_binary(asset.resource_version_id) and
          current.resource_version_id != asset.resource_version_id ->
        {:error, Error.new(:conflict)}

      current.state != :staging ->
        {:error, Error.new(:conflict)}

      true ->
        :ok
    end
  end

  defp fetch_asset(repo, asset_id) do
    case repo.get(StoredAsset, asset_id) do
      nil ->
        {:error, Error.new(:not_found)}

      stored ->
        Asset.new(%{
          asset_id: stored.id,
          vault_id: stored.vault_id,
          resource_version_id: stored.resource_version_id,
          classification: stored.classification,
          state: stored.state,
          state_revision: stored.state_revision,
          failure_code: failure_code(stored.failure_code),
          retryable?: stored.retryable? || false,
          failed_operation: stored.failed_operation,
          attempt: stored.attempt
        })
    end
  end

  defp same_classification(%Asset{classification: classification}, classification),
    do: :ok

  defp same_classification(_asset, _classification),
    do: {:error, Error.new(:forbidden)}

  defp failure_code(nil), do: nil
  defp failure_code(code), do: String.to_existing_atom(code)

  defp audit_changeset(attrs) do
    AuditEvent.append_changeset(%AuditEvent{}, %{
      id: Ecto.UUID.generate(),
      vault_id: attrs.vault_id,
      actor_kind: :principal,
      principal_id: attrs.principal_id,
      operation: attrs.operation,
      result: :completed,
      classification: attrs.classification,
      correlation_id: attrs.correlation_id,
      target_type: "asset",
      target_id: attrs.target_id,
      metadata: attrs.metadata,
      occurred_at: attrs.occurred_at
    })
  end

  defp outbox_changeset(attrs) do
    OutboxEvent.create_changeset(
      %OutboxEvent{},
      Map.merge(attrs, %{id: Ecto.UUID.generate(), envelope_version: 1})
    )
  end

  defp validate_upload_intent_ids(asset, provenance) do
    UUID.validate([
      asset.asset_id,
      asset.vault_id,
      asset.resource_version_id,
      provenance.source_reference_id,
      provenance.vault_id,
      provenance.resource_version_id,
      provenance.principal_id
    ])
  end

  defp validate_sealed_stage_ids(%{
         asset: asset,
         audit: audit,
         outbox: outbox
       }) do
    with :ok <-
           UUID.validate([
             asset.asset_id,
             asset.vault_id,
             asset.principal_id,
             audit.asset_id,
             audit.vault_id,
             audit.principal_id,
             outbox.asset_id,
             outbox.vault_id,
             outbox.principal_id
           ]) do
      UUID.validate_optional([asset.resource_version_id])
    end
  end

  defp validate_sealed_stage_ids(_intent), do: {:error, Error.new(:invalid)}

  defp validate_transition_ids(%{
         asset_id: asset_id,
         principal_id: principal_id,
         audit: audit,
         outbox: outbox
       }) do
    UUID.validate([
      asset_id,
      principal_id,
      audit.asset_id,
      audit.principal_id,
      outbox.asset_id,
      outbox.principal_id
    ])
  end

  defp validate_transition_ids(_intent), do: {:error, Error.new(:invalid)}

  defp validate_tombstone_ids(%{
         asset_id: asset_id,
         principal_id: principal_id,
         tombstone: tombstone,
         audit: audit,
         outbox: outbox
       }) do
    UUID.validate([
      asset_id,
      principal_id,
      tombstone.asset_id,
      audit.asset_id,
      audit.principal_id,
      outbox.asset_id,
      outbox.principal_id
    ])
  end

  defp validate_tombstone_ids(_intent), do: {:error, Error.new(:invalid)}

  defp lock_resource_version_classification(repo, asset) do
    query =
      from resource_version in ResourceVersion,
        where:
          resource_version.id == ^asset.resource_version_id and
            resource_version.vault_id == ^asset.vault_id,
        select: resource_version.classification,
        lock: "FOR SHARE"

    case repo.one(query) do
      nil -> {:error, Error.new(:not_found)}
      classification -> {:ok, classification}
    end
  end

  defp authorization_epoch(repo, vault_id) do
    with {:ok, dumped_vault_id} <- UUID.dump(vault_id),
         {:ok, %{rows: [[epoch]]}} <-
           Ecto.Adapters.SQL.query(
             repo,
             "SELECT authorization_epoch FROM core.vaults WHERE id = $1",
             [dumped_vault_id],
             log: false
           ) do
      epoch
    else
      _other -> 0
    end
  end

  defp changeset_error(changeset) do
    cond do
      Enum.any?(changeset.errors, &constraint?(&1, :unique)) ->
        Error.new(:conflict)

      Enum.any?(changeset.errors, &constraint?(&1, :foreign)) ->
        Error.new(:not_found)

      true ->
        Error.new(:invalid)
    end
  end

  defp constraint?({_field, {_message, metadata}}, type),
    do: metadata[:constraint] == type

  defp database_error(%Ecto.ConstraintError{type: :unique}),
    do: Error.new(:conflict)

  defp database_error(%Postgrex.Error{postgres: %{code: :unique_violation}}),
    do: Error.new(:conflict)

  defp database_error(%Postgrex.Error{postgres: %{code: :foreign_key_violation}}),
    do: Error.new(:not_found)

  defp database_error(_error),
    do: Error.new(:storage_unavailable, retryable?: true)
end
