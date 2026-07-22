defmodule Singularity.Storage.Postgres.AssetRepository do
  @moduledoc false

  @behaviour Singularity.Domains.Assets.Repository

  import Ecto.Query

  alias Ecto.Multi
  alias Singularity.Core.Asset
  alias Singularity.Core.AssetState
  alias Singularity.Core.Classification
  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope
  alias Singularity.Core.ObjectRef
  alias Singularity.Core.StageRef
  alias Singularity.Core.Types
  alias Singularity.Storage.Jobs.Progress
  alias Singularity.Storage.Crypto.Format
  alias Singularity.Storage.Schema.Audit.Event, as: AuditEvent
  alias Singularity.Storage.Schema.Content.Asset, as: StoredAsset
  alias Singularity.Storage.Schema.Content.AssetKeyEnvelope
  alias Singularity.Storage.Schema.Content.AssetMetadata
  alias Singularity.Storage.Schema.Content.AssetObject
  alias Singularity.Storage.Schema.Content.AssetStage
  alias Singularity.Storage.Schema.Content.Resource
  alias Singularity.Storage.Schema.Content.ResourceAsset
  alias Singularity.Storage.Schema.Content.ResourceVersion
  alias Singularity.Storage.Schema.Content.SourceReference
  alias Singularity.Storage.Schema.Content.Tombstone
  alias Singularity.Storage.Schema.Content.UploadGrant
  alias Singularity.Storage.Schema.Core.DomainKeyVersion
  alias Singularity.Storage.Schema.Core.OutboxEvent
  alias Singularity.Storage.Schema.Jobs.EffectReceipt
  alias Singularity.Storage.Postgres.CustodyRepository
  alias Singularity.Storage.Postgres.UUID
  alias Singularity.Storage.Postgres.AssetSearchStore

  @max_bigint 9_223_372_036_854_775_807
  @metadata_result_keys ~w[
    detected_media_type plaintext_bytes width height pdf_version extractor_version
  ]

  @impl true
  def create_upload_grant(repo, command) when is_map(command) do
    with :ok <- validate_upload_grant_command(command) do
      Multi.new()
      |> Multi.run(:idempotency_lock, fn transaction_repo, _changes ->
        lock_upload_grant_idempotency(transaction_repo, command)
      end)
      |> Multi.run(:existing_grant, fn transaction_repo, _changes ->
        lock_existing_upload_grant(transaction_repo, command)
      end)
      |> Multi.merge(fn
        %{existing_grant: nil} ->
          new_upload_grant_multi(command)

        %{existing_grant: %UploadGrant{} = grant} ->
          replay_upload_grant_multi(grant, command)
      end)
      |> repo.transaction()
      |> case do
        {:ok, %{grant: grant, source: source}} ->
          {:ok, upload_grant_result(grant, source, command)}

        {:error, _operation, %Error{} = error, _changes} ->
          {:error, error}

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

  def create_upload_grant(_repo, _command),
    do: {:error, Error.new(:invalid)}

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
    with {:ok, authorization_epochs} <-
           authorization_epochs(repo, provenance.principal_id, asset.vault_id) do
      do_persist_upload_intent(repo, intent, authorization_epochs)
    end
  end

  defp do_persist_upload_intent(
         repo,
         %{asset: asset, provenance: provenance} = intent,
         authorization_epochs
       ) do
    correlation_id = Ecto.UUID.generate()

    outbox =
      outbox_changeset(
        %{
          event_type: "asset.upload_intent_created",
          idempotency_key: "upload-intent:#{intent.idempotency_key}",
          vault_id: asset.vault_id,
          principal_id: provenance.principal_id,
          required_capability: "assets.upload",
          classification: asset.classification,
          correlation_id: correlation_id,
          causation_id: provenance.source_reference_id,
          expected_entity_revision: 0,
          payload: %{
            "asset_id" => asset.asset_id,
            "resource_version_id" => asset.resource_version_id
          },
          occurred_at: provenance.observed_at
        },
        authorization_epochs
      )

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
  def consume_grant_and_create_stage(repo, command) when is_map(command) do
    with :ok <- validate_grant_stage_command(command) do
      token_digest = :crypto.hash(:sha256, command.token)

      Multi.new()
      |> Multi.run(:grant, fn transaction_repo, _changes ->
        lock_eligible_grant(
          transaction_repo,
          command.grant_id,
          command.principal_id
        )
      end)
      |> Multi.run(:asset, fn transaction_repo, %{grant: grant} ->
        lock_upload_asset(transaction_repo, grant, command)
      end)
      |> Multi.run(
        :authorization_epochs,
        fn transaction_repo, %{grant: grant} ->
          authorization_epochs(
            transaction_repo,
            grant.principal_id,
            grant.vault_id
          )
        end
      )
      |> Multi.run(
        :binding,
        fn _transaction_repo, %{grant: grant, authorization_epochs: authorization_epochs} ->
          validate_grant_stage_binding(
            grant,
            command,
            token_digest,
            authorization_epochs
          )
        end
      )
      |> Multi.run(:consumed_grant, fn transaction_repo, %{grant: grant} ->
        consume_locked_grant(transaction_repo, grant.id)
      end)
      |> Multi.insert(:stage, fn _changes ->
        AssetStage.open_changeset(%AssetStage{}, stage_attrs(command))
      end)
      |> repo.transaction()
      |> case do
        {:ok, %{stage: stage}} ->
          {:ok, stage}

        {:error, _operation, %Error{} = error, _changes} ->
          {:error, error}

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

  def consume_grant_and_create_stage(_repo, _command),
    do: {:error, Error.new(:invalid)}

  @impl true
  def mark_stage_abandoned(repo, command) when is_map(command) do
    with :ok <- validate_stage_abandonment(command) do
      correlation_id = Ecto.UUID.generate()

      Multi.new()
      |> Multi.run(:grant, fn transaction_repo, _changes ->
        lock_upload_grant(
          transaction_repo,
          command.grant_id,
          command.principal_id
        )
      end)
      |> Multi.run(:stage, fn transaction_repo, _changes ->
        lock_asset_stage(transaction_repo, command.stage_id)
      end)
      |> Multi.run(:asset, fn transaction_repo, _changes ->
        lock_stored_asset(transaction_repo, command.asset_id)
      end)
      |> Multi.run(:authorization_epochs, fn transaction_repo, _changes ->
        authorization_epochs(
          transaction_repo,
          command.principal_id,
          command.vault_id
        )
      end)
      |> Multi.run(:abandonment_mode, fn _transaction_repo, locked ->
        validate_stage_abandonment_binding(locked, command)
      end)
      |> Multi.merge(fn locked ->
        stage_abandonment_effects(locked, command, correlation_id)
      end)
      |> repo.transaction()
      |> case do
        {:ok, %{abandoned_stage: stage}} ->
          {:ok, stage}

        {:error, _operation, %Error{} = error, _changes} ->
          {:error, error}

        {:error, _operation, %Ecto.Changeset{} = changeset, _changes} ->
          {:error, changeset_error(changeset)}

        {:error, _operation, _reason, _changes} ->
          {:error, Error.new(:storage_unavailable, retryable?: true)}
      end
    end
  rescue
    _error in [Ecto.Query.CastError, Ecto.StaleEntryError] ->
      {:error, Error.new(:conflict)}

    error in [Ecto.ConstraintError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  def mark_stage_abandoned(_repo, _command),
    do: {:error, Error.new(:invalid)}

  @impl true
  def record_sealed_stage(
        repo,
        %{stage_ref: %StageRef{stage_id: stage_id}} = command
      )
      when is_map(command) do
    with :ok <- validate_sealed_checkpoint(command) do
      correlation_id = Ecto.UUID.generate()

      Multi.new()
      |> Multi.run(:grant, fn transaction_repo, _changes ->
        lock_upload_grant(
          transaction_repo,
          command.grant_id,
          command.principal_id
        )
      end)
      |> Multi.run(:stage, fn transaction_repo, _changes ->
        lock_asset_stage(transaction_repo, stage_id)
      end)
      |> Multi.run(:asset, fn transaction_repo, _changes ->
        lock_stored_asset(transaction_repo, command.asset_id)
      end)
      |> Multi.run(:source, fn transaction_repo, %{asset: asset, grant: grant} ->
        lock_upload_source(transaction_repo, asset, grant)
      end)
      |> Multi.run(:authorization_epochs, fn transaction_repo, _changes ->
        authorization_epochs(
          transaction_repo,
          command.principal_id,
          command.vault_id
        )
      end)
      |> Multi.run(:checkpoint_mode, fn _transaction_repo, locked ->
        validate_sealed_checkpoint_binding(locked, command)
      end)
      |> Multi.merge(fn locked ->
        sealed_checkpoint_effects(locked, command, correlation_id)
      end)
      |> repo.transaction()
      |> case do
        {:ok, %{checkpoint_asset: asset, checkpoint_stage: stage}} ->
          {:ok, %{asset: asset, stage: stage}}

        {:error, _operation, %Error{} = error, _changes} ->
          {:error, error}

        {:error, _operation, %Ecto.Changeset{} = changeset, _changes} ->
          {:error, changeset_error(changeset)}

        {:error, _operation, _reason, _changes} ->
          {:error, Error.new(:storage_unavailable, retryable?: true)}
      end
    end
  rescue
    _error in [Ecto.Query.CastError] ->
      {:error, Error.new(:invalid)}

    _error in [Ecto.StaleEntryError] ->
      {:error, Error.new(:conflict)}

    error in [Ecto.ConstraintError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  @impl true
  def record_sealed_stage(repo, %{asset: asset} = intent) do
    now = DateTime.utc_now(:microsecond)
    correlation_id = Ecto.UUID.generate()

    with :ok <- validate_sealed_stage_ids(intent),
         {:ok, current} <- fetch_asset(repo, asset.asset_id),
         :ok <- validate_sealed_asset(current, asset),
         {:ok, transitioned} <-
           AssetState.transition(current, :uploaded, current.state_revision),
         {:ok, authorization_epochs} <-
           authorization_epochs(repo, asset.principal_id, asset.vault_id) do
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
        outbox_changeset(
          %{
            event_type: intent.outbox.event_type,
            idempotency_key: "sealed-upload:#{asset.asset_id}",
            vault_id: asset.vault_id,
            principal_id: asset.principal_id,
            required_capability: "assets.verify",
            classification: intent.outbox.classification,
            correlation_id: correlation_id,
            causation_id: asset.asset_id,
            expected_entity_revision: transitioned.state_revision,
            payload: %{"asset_id" => asset.asset_id},
            occurred_at: now
          },
          authorization_epochs
        )

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
  def prepare_verification(repo, %JobEnvelope{} = envelope) do
    with :ok <- validate_asset_job(envelope, "asset_verify"),
         {:ok, receipt} <- lock_effect_receipt(repo, envelope) do
      case receipt do
        %EffectReceipt{} ->
          completed_job_result(repo, envelope, receipt)

        nil ->
          prepare_pending_verification(repo, envelope)
      end
    end
  rescue
    _error in [Ecto.Query.CastError] ->
      {:error, Error.new(:invalid)}

    error in [Ecto.ConstraintError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  def prepare_verification(_repo, _envelope),
    do: {:error, Error.new(:invalid)}

  @impl true
  def record_verified_stage(
        repo,
        %{
          envelope: %JobEnvelope{} = envelope,
          stage_id: stage_id,
          sealed?: true,
          ciphertext_byte_size: ciphertext_byte_size,
          ciphertext_hash: <<_::binary-size(32)>>
        } = command
      ) do
    with :ok <- validate_asset_job(envelope, "asset_verify"),
         :ok <- UUID.validate(stage_id),
         true <- is_integer(ciphertext_byte_size) and ciphertext_byte_size >= 0 do
      transact_callback(repo, fn ->
        do_record_verified_stage(repo, envelope, command)
      end)
    else
      false -> {:error, Error.new(:invalid)}
      {:error, %Error{}} = error -> error
    end
  rescue
    _error in [Ecto.Query.CastError, Ecto.StaleEntryError] ->
      {:error, Error.new(:conflict)}

    error in [Ecto.ConstraintError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  def record_verified_stage(_repo, _command),
    do: {:error, Error.new(:invalid)}

  @impl true
  def resolve_finalization(repo, %JobEnvelope{} = envelope) do
    with :ok <- validate_asset_job(envelope, "asset_finalize"),
         {:ok, receipt} <- lock_effect_receipt(repo, envelope) do
      case receipt do
        %EffectReceipt{} ->
          completed_job_result(repo, envelope, receipt)

        nil ->
          resolve_pending_finalization(repo, envelope)
      end
    end
  rescue
    _error in [Ecto.Query.CastError] ->
      {:error, Error.new(:invalid)}

    error in [Ecto.ConstraintError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  def resolve_finalization(_repo, _envelope),
    do: {:error, Error.new(:invalid)}

  @impl true
  def reserve_finalization(
        repo,
        %{
          envelope: %JobEnvelope{} = envelope,
          object_id: object_id
        }
      ) do
    with :ok <- validate_asset_job(envelope, "asset_finalize"),
         :ok <- UUID.validate(object_id) do
      transact_callback(repo, fn ->
        do_reserve_finalization(repo, envelope, object_id)
      end)
    end
  rescue
    _error in [Ecto.Query.CastError, Ecto.StaleEntryError] ->
      {:error, Error.new(:conflict)}

    error in [Ecto.ConstraintError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  def reserve_finalization(_repo, _command),
    do: {:error, Error.new(:invalid)}

  @impl true
  def acknowledge_finalization(
        repo,
        %{
          envelope: %JobEnvelope{} = envelope,
          object_id: object_id,
          stage_id: stage_id,
          action: action,
          observed_ciphertext_byte_size: observed_size,
          observed_ciphertext_hash: <<_::binary-size(32)>>
        } = command
      )
      when action in [:publish, :reuse] and is_integer(observed_size) and
             observed_size >= 0 do
    with :ok <- validate_asset_job(envelope, "asset_finalize"),
         :ok <- UUID.validate([object_id, stage_id]) do
      transact_callback(repo, fn ->
        do_acknowledge_finalization(repo, command)
      end)
    end
  rescue
    _error in [Ecto.Query.CastError, Ecto.StaleEntryError] ->
      {:error, Error.new(:conflict)}

    error in [Ecto.ConstraintError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  def acknowledge_finalization(_repo, _command),
    do: {:error, Error.new(:invalid)}

  @spec status(module(), String.t()) ::
          {:ok, Asset.t()} | {:error, Error.t()}
  def status(repo, asset_id) when is_binary(asset_id) do
    with :ok <- UUID.validate(asset_id) do
      fetch_discoverable_asset(repo, asset_id)
    end
  rescue
    _error in [Ecto.Query.CastError] ->
      {:error, Error.new(:invalid)}

    _error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def status(_repo, _asset_id), do: {:error, Error.new(:invalid)}

  @spec rebuild_search_document(module(), String.t()) ::
          :ok | {:error, Error.t()}
  def rebuild_search_document(repo, asset_id) when is_binary(asset_id) do
    with :ok <- UUID.validate(asset_id),
         {:ok, source} <- lock_search_document_source(repo, asset_id) do
      rebuild_locked_search_document(repo, asset_id, source)
    end
  rescue
    _error in [Ecto.Query.CastError] ->
      {:error, Error.new(:invalid)}

    _error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def rebuild_search_document(_repo, _asset_id),
    do: {:error, Error.new(:invalid)}

  defp lock_search_document_source(repo, asset_id) do
    case repo.one(
           from(asset in StoredAsset,
             where: asset.id == ^asset_id,
             select: %{state: asset.state, vault_id: asset.vault_id},
             lock: "FOR UPDATE"
           )
         ) do
      nil -> {:error, Error.new(:not_found)}
      source -> {:ok, source}
    end
  end

  defp rebuild_locked_search_document(repo, asset_id, %{state: :ready, vault_id: vault_id}) do
    case canonical_search_document(repo, asset_id) do
      {:ok, attrs} ->
        AssetSearchStore.upsert(repo, attrs)

      {:error, %Error{code: :not_found}} ->
        AssetSearchStore.delete(repo, %{asset_id: asset_id, vault_id: vault_id})

      {:error, %Error{}} = error ->
        error
    end
  end

  defp rebuild_locked_search_document(repo, asset_id, %{vault_id: vault_id}),
    do: AssetSearchStore.delete(repo, %{asset_id: asset_id, vault_id: vault_id})

  @spec begin_or_resume_processing(module(), JobEnvelope.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def begin_or_resume_processing(
        repo,
        %JobEnvelope{job_type: "asset_metadata"} = envelope
      ) do
    with :ok <- validate_metadata_job(envelope),
         {:ok, receipt} <- lock_effect_receipt(repo, envelope) do
      case receipt do
        %EffectReceipt{result: :failed} ->
          completed_metadata_job_result(repo, envelope, receipt)

        %EffectReceipt{} ->
          completed_job_result(repo, envelope, receipt)

        nil ->
          begin_or_resume_metadata(repo, envelope)
      end
    end
  rescue
    _error in [Ecto.Query.CastError, Ecto.StaleEntryError] ->
      {:error, Error.new(:conflict)}

    error in [Ecto.ConstraintError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  def begin_or_resume_processing(_repo, _envelope),
    do: {:error, Error.new(:invalid)}

  @spec complete_metadata(module(), JobEnvelope.t(), pos_integer(), map(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def complete_metadata(
        repo,
        %JobEnvelope{job_type: "asset_metadata"} = envelope,
        processing_revision,
        metadata,
        final_checkpoint
      )
      when is_integer(processing_revision) and processing_revision > 0 and
             is_map(metadata) and is_map(final_checkpoint) do
    with :ok <- validate_metadata_job(envelope),
         :ok <- validate_extracted_metadata(metadata),
         :ok <-
           validate_terminal_metadata_checkpoint(
             final_checkpoint,
             envelope,
             processing_revision,
             {:done, metadata}
           ) do
      transact_callback(repo, fn ->
        do_complete_metadata(
          repo,
          envelope,
          processing_revision,
          metadata,
          final_checkpoint
        )
      end)
    end
  rescue
    _error in [Ecto.Query.CastError, Ecto.StaleEntryError] ->
      {:error, Error.new(:conflict)}

    error in [Ecto.ConstraintError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  def complete_metadata(_repo, _envelope, _processing_revision, _metadata, _checkpoint),
    do: {:error, Error.new(:invalid)}

  @spec record_metadata_failure(
          module(),
          JobEnvelope.t(),
          pos_integer(),
          Error.t(),
          map()
        ) :: {:ok, map()} | {:error, Error.t()}
  def record_metadata_failure(
        repo,
        %JobEnvelope{job_type: "asset_metadata"} = envelope,
        processing_revision,
        %Error{retryable?: false} = failure,
        final_checkpoint
      )
      when is_integer(processing_revision) and processing_revision > 0 and
             is_map(final_checkpoint) do
    with :ok <- validate_metadata_job(envelope),
         :ok <- validate_metadata_failure(failure),
         :ok <-
           validate_terminal_metadata_checkpoint(
             final_checkpoint,
             envelope,
             processing_revision,
             {:error, failure}
           ) do
      transact_callback(repo, fn ->
        do_record_metadata_failure(
          repo,
          envelope,
          processing_revision,
          failure,
          final_checkpoint
        )
      end)
    end
  rescue
    _error in [Ecto.Query.CastError, Ecto.StaleEntryError] ->
      {:error, Error.new(:conflict)}

    error in [Ecto.ConstraintError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  def record_metadata_failure(
        _repo,
        _envelope,
        _processing_revision,
        _failure,
        _checkpoint
      ),
      do: {:error, Error.new(:invalid)}

  @spec record_metadata_exhaustion(module(), JobEnvelope.t(), Error.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def record_metadata_exhaustion(
        repo,
        %JobEnvelope{job_type: "asset_metadata"} = envelope,
        %Error{} = failure
      ) do
    with :ok <- validate_metadata_job(envelope) do
      transact_callback(repo, fn ->
        do_record_metadata_exhaustion(repo, envelope, failure)
      end)
    end
  rescue
    _error in [Ecto.Query.CastError, Ecto.StaleEntryError] ->
      {:error, Error.new(:conflict)}

    error in [Ecto.ConstraintError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  def record_metadata_exhaustion(_repo, _envelope, _failure),
    do: {:error, Error.new(:invalid)}

  @spec authorized_object(module(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def authorized_object(repo, asset_id) when is_binary(asset_id) do
    with :ok <- UUID.validate(asset_id) do
      query =
        from asset in StoredAsset,
          join: object in AssetObject,
          on:
            object.id == asset.asset_object_id and
              object.vault_id == asset.vault_id and
              object.classification == asset.classification,
          join: envelope in AssetKeyEnvelope,
          on:
            envelope.asset_object_id == object.id and
              envelope.vault_id == object.vault_id and
              envelope.key_domain_id == object.key_domain_id and
              envelope.classification == object.classification,
          join: domain_version in DomainKeyVersion,
          on:
            domain_version.id == envelope.domain_key_version_id and
              domain_version.vault_id == envelope.vault_id and
              domain_version.key_domain_id == envelope.key_domain_id,
          where: asset.id == ^asset_id,
          where:
            fragment(
              "core.current_principal_can_discover_classification(?)",
              asset.classification
            ),
          where: asset.state in [:available, :processing, :ready],
          where: object.lifecycle == :available,
          where: domain_version.state == :active,
          order_by: [desc: envelope.key_generation, desc: envelope.inserted_at],
          limit: 2,
          select: %{
            asset_id: asset.id,
            vault_id: asset.vault_id,
            classification: asset.classification,
            object_id: object.id,
            object_generation: envelope.key_generation
          }

      case repo.all(query) do
        [binding] -> {:ok, binding}
        [] -> {:error, Error.new(:not_found)}
        [_first, _second] -> {:error, Error.new(:integrity_failure)}
      end
    end
  rescue
    _error in [Ecto.Query.CastError] ->
      {:error, Error.new(:invalid)}

    _error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def authorized_object(_repo, _asset_id),
    do: {:error, Error.new(:invalid)}

  defp begin_or_resume_metadata(repo, envelope) do
    with {:ok, asset} <- lock_job_asset(repo, envelope) do
      cond do
        asset.state == :available and
            asset.state_revision == envelope.expected_entity_revision ->
          claim_metadata_processing(repo, asset, envelope)

        asset.state == :processing and
            asset.state_revision == envelope.expected_entity_revision + 1 ->
          resume_metadata_processing(repo, asset, envelope)

        true ->
          record_stale_job(repo, envelope, asset)
      end
    end
  end

  defp claim_metadata_processing(repo, asset, envelope) do
    with {:ok, target} <- metadata_target(repo, asset),
         {:ok, processing_asset} <-
           asset
           |> StoredAsset.transition_changeset(%{
             state: :processing,
             state_revision: asset.state_revision
           })
           |> Ecto.Changeset.optimistic_lock(:state_revision)
           |> repo.update()
           |> map_changeset_result(),
         checkpoint = metadata_checkpoint(envelope, processing_asset, target),
         {:ok, _progress} <-
           Progress.begin_metadata(
             repo,
             envelope,
             processing_asset.state_revision,
             checkpoint
           ) do
      {:ok,
       metadata_processing_result(
         processing_asset,
         target,
         checkpoint
       )}
    end
  end

  defp resume_metadata_processing(repo, asset, envelope) do
    case Progress.lock_metadata(repo, envelope, asset.state_revision) do
      {:ok, progress} ->
        with {:ok, target} <- metadata_target(repo, asset),
             :ok <-
               validate_metadata_checkpoint_binding(
                 progress.checkpoint,
                 envelope,
                 asset,
                 target
               ),
             :ok <- validate_checkpoint_target(progress.checkpoint, target),
             {:ok, resumed} <-
               Progress.resume_metadata(repo, envelope, asset.state_revision) do
          {:ok, metadata_processing_result(asset, target, resumed.checkpoint)}
        end

      {:error, %Error{code: :not_found}} ->
        record_stale_job(repo, envelope, asset)

      {:error, %Error{}} = error ->
        error
    end
  end

  defp metadata_processing_result(asset, target, checkpoint) do
    %{
      status: :pending,
      asset: asset,
      processing_revision: asset.state_revision,
      checkpoint: checkpoint,
      object_id: target.object_id,
      object_generation: target.object_generation,
      original_filename: target.original_filename,
      declared_media_type: target.declared_media_type,
      plaintext_byte_size: target.plaintext_byte_size,
      resource_version_id: asset.resource_version_id
    }
  end

  defp metadata_target(repo, asset) do
    query =
      from object in AssetObject,
        join: envelope in AssetKeyEnvelope,
        on:
          envelope.asset_object_id == object.id and
            envelope.vault_id == object.vault_id and
            envelope.key_domain_id == object.key_domain_id and
            envelope.classification == object.classification,
        join: domain_version in DomainKeyVersion,
        on:
          domain_version.id == envelope.domain_key_version_id and
            domain_version.vault_id == envelope.vault_id and
            domain_version.key_domain_id == envelope.key_domain_id,
        join: metadata in AssetMetadata,
        on:
          metadata.asset_id == ^asset.id and
            metadata.resource_version_id == ^asset.resource_version_id and
            metadata.vault_id == object.vault_id and
            metadata.classification == object.classification,
        where: object.id == ^asset.asset_object_id,
        where: object.vault_id == ^asset.vault_id,
        where: object.classification == ^asset.classification,
        where: object.lifecycle == :available,
        where: domain_version.state == :active,
        where: metadata.extraction_state == :pending,
        order_by: [desc: envelope.key_generation],
        limit: 2,
        lock: "FOR SHARE",
        select: %{
          metadata_id: metadata.id,
          object_id: object.id,
          object_generation: envelope.key_generation,
          object_classification: object.classification,
          envelope_classification: envelope.classification,
          metadata_classification: metadata.classification,
          plaintext_byte_size: object.plaintext_byte_size,
          metadata_byte_size: metadata.plaintext_byte_size,
          original_filename: metadata.original_filename,
          declared_media_type: metadata.declared_media_type
        }

    case repo.all(query) do
      [target] -> validate_metadata_target(target, asset)
      [] -> {:error, Error.new(:conflict)}
      [_first, _second] -> {:error, Error.new(:integrity_failure)}
    end
  end

  defp validate_metadata_target(
         %{
           object_id: object_id,
           object_generation: object_generation,
           object_classification: classification,
           envelope_classification: classification,
           metadata_classification: classification,
           plaintext_byte_size: plaintext_byte_size,
           metadata_byte_size: plaintext_byte_size,
           original_filename: original_filename,
           declared_media_type: declared_media_type
         } = target,
         %StoredAsset{classification: classification}
       )
       when is_integer(object_generation) and object_generation > 0 and
              is_integer(plaintext_byte_size) and plaintext_byte_size >= 0 and
              is_binary(original_filename) and byte_size(original_filename) > 0 and
              is_binary(declared_media_type) and byte_size(declared_media_type) > 0 do
    with :ok <- UUID.validate([target.metadata_id, object_id]) do
      {:ok, target}
    end
  end

  defp validate_metadata_target(_target, _asset),
    do: {:error, Error.new(:integrity_failure)}

  defp metadata_checkpoint(envelope, asset, target) do
    %{
      "version" => 3,
      "protocol" => "asset_metadata_v1",
      "next_chunk_index" => 0,
      "processing_revision" => asset.state_revision,
      "extractor_state" => %{
        "phase" => "start",
        "declared_media_type" => target.declared_media_type,
        "plaintext_bytes" => target.plaintext_byte_size
      },
      "job_id" => envelope.job_id,
      "vault_id" => envelope.vault_id,
      "principal_id" => envelope.principal_id,
      "required_capability" => envelope.required_capability,
      "principal_authorization_epoch" => envelope.principal_authorization_epoch,
      "vault_authorization_epoch" => envelope.vault_authorization_epoch,
      "object_id" => target.object_id,
      "object_generation" => target.object_generation
    }
  end

  defp validate_metadata_checkpoint_binding(
         checkpoint,
         %JobEnvelope{
           job_id: job_id,
           vault_id: vault_id,
           principal_id: principal_id,
           required_capability: required_capability,
           principal_authorization_epoch: principal_epoch,
           vault_authorization_epoch: vault_epoch
         },
         %StoredAsset{state_revision: processing_revision},
         %{
           object_id: object_id,
           object_generation: object_generation,
           declared_media_type: declared_media_type,
           plaintext_byte_size: plaintext_byte_size
         }
       ) do
    CustodyRepository.validate_metadata_checkpoint(checkpoint, %{
      job_id: job_id,
      vault_id: vault_id,
      principal_id: principal_id,
      required_capability: required_capability,
      principal_authorization_epoch: principal_epoch,
      vault_authorization_epoch: vault_epoch,
      object_id: object_id,
      object_generation: object_generation,
      processing_revision: processing_revision,
      declared_media_type: declared_media_type,
      plaintext_byte_size: plaintext_byte_size
    })
  end

  defp validate_metadata_checkpoint_binding(_checkpoint, _envelope, _asset, _target),
    do: {:error, Error.new(:conflict)}

  defp do_complete_metadata(
         repo,
         envelope,
         processing_revision,
         metadata,
         final_checkpoint
       ) do
    with {:ok, receipt} <- lock_effect_receipt(repo, envelope) do
      case receipt do
        %EffectReceipt{} ->
          completed_job_result(repo, envelope, receipt)

        nil ->
          apply_metadata_completion(
            repo,
            envelope,
            processing_revision,
            metadata,
            final_checkpoint
          )
      end
    end
  end

  defp apply_metadata_completion(
         repo,
         envelope,
         processing_revision,
         metadata,
         final_checkpoint
       ) do
    with {:ok, asset} <- lock_job_asset(repo, envelope),
         true <-
           asset.state == :processing and
             asset.state_revision == processing_revision,
         {:ok, target} <- metadata_target(repo, asset),
         :ok <-
           validate_metadata_checkpoint_binding(
             final_checkpoint,
             envelope,
             asset,
             target
           ),
         :ok <- validate_checkpoint_target(final_checkpoint, target),
         :ok <- validate_metadata_matches_target(metadata, target),
         {:ok, stored_metadata} <- lock_pending_metadata(repo, asset, target),
         {:ok, ready} <-
           persist_metadata_completion(
             repo,
             asset,
             stored_metadata,
             envelope,
             processing_revision,
             metadata,
             final_checkpoint
           ) do
      {:ok,
       %{
         status: :complete,
         effect_result: :applied,
         asset: ready
       }}
    else
      false -> {:error, Error.new(:conflict)}
      {:error, %Error{}} = error -> error
    end
  end

  defp persist_metadata_completion(
         repo,
         asset,
         stored_metadata,
         envelope,
         processing_revision,
         metadata,
         final_checkpoint
       ) do
    now = DateTime.utc_now(:microsecond)

    with {:ok, _completed_metadata} <-
           stored_metadata
           |> AssetMetadata.upsert_changeset(%{
             detected_media_type: metadata.detected_media_type,
             pdf_header_version: metadata.pdf_version,
             image_width: metadata.width,
             image_height: metadata.height,
             extraction_state: :completed,
             extractor_version: Integer.to_string(metadata.extractor_version),
             completed_at: now
           })
           |> repo.update()
           |> map_changeset_result(),
         {:ok, ready} <-
           asset
           |> StoredAsset.transition_changeset(%{
             state: :ready,
             state_revision: processing_revision
           })
           |> Ecto.Changeset.optimistic_lock(:state_revision)
           |> repo.update()
           |> map_changeset_result(),
         :ok <- rebuild_search_document(repo, asset.id),
         {:ok, _audit} <-
           repo.insert(
             audit_changeset(%{
               operation: "asset.metadata_completed",
               vault_id: asset.vault_id,
               principal_id: envelope.principal_id,
               classification: asset.classification,
               correlation_id: envelope.correlation_id,
               target_id: asset.id,
               metadata: %{
                 "detected_media_type" => metadata.detected_media_type,
                 "extractor_version" => metadata.extractor_version,
                 "job_id" => envelope.job_id,
                 "state" => "ready"
               },
               occurred_at: now
             })
           ),
         {:ok, _receipt} <-
           Progress.record_effect(repo, envelope, %{
             effect_key: envelope.idempotency_key,
             result: :applied,
             entity_revision: ready.state_revision
           }),
         {:ok, _progress} <-
           Progress.transition_metadata(
             repo,
             envelope,
             processing_revision,
             final_checkpoint,
             :completed
           ) do
      {:ok, ready}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset_error(changeset)}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp do_record_metadata_failure(
         repo,
         envelope,
         processing_revision,
         failure,
         final_checkpoint
       ) do
    with {:ok, receipt} <- lock_effect_receipt(repo, envelope) do
      case receipt do
        %EffectReceipt{} ->
          completed_job_result(repo, envelope, receipt)

        nil ->
          apply_metadata_failure(
            repo,
            envelope,
            processing_revision,
            failure,
            final_checkpoint
          )
      end
    end
  end

  defp do_record_metadata_exhaustion(repo, envelope, failure) do
    with {:ok, receipt} <- lock_effect_receipt(repo, envelope) do
      case receipt do
        %EffectReceipt{result: :failed} ->
          completed_metadata_job_result(repo, envelope, receipt)

        %EffectReceipt{} ->
          completed_job_result(repo, envelope, receipt)

        nil ->
          apply_metadata_exhaustion(repo, envelope, failure)
      end
    end
  end

  defp apply_metadata_exhaustion(repo, envelope, failure) do
    with {:ok, asset} <- lock_job_asset(repo, envelope),
         true <-
           asset.state == :processing and
             asset.state_revision == envelope.expected_entity_revision + 1,
         {:ok, target} <- metadata_target(repo, asset),
         {:ok, progress} <-
           Progress.lock_metadata(repo, envelope, asset.state_revision),
         :ok <-
           validate_metadata_checkpoint_binding(
             progress.checkpoint,
             envelope,
             asset,
             target
           ),
         :ok <- validate_checkpoint_target(progress.checkpoint, target),
         {:ok, stored_metadata} <- lock_pending_metadata(repo, asset, target),
         terminal_failure = %{failure | retryable?: false},
         {:ok, failed_asset} <-
           persist_metadata_failure(
             repo,
             asset,
             stored_metadata,
             envelope,
             asset.state_revision,
             terminal_failure,
             progress.checkpoint
           ) do
      {:ok,
       %{
         status: :complete,
         effect_result: :failed,
         asset: failed_asset
       }}
    else
      false -> {:error, Error.new(:conflict)}
      {:error, %Error{}} = error -> error
    end
  end

  defp apply_metadata_failure(
         repo,
         envelope,
         processing_revision,
         failure,
         final_checkpoint
       ) do
    with {:ok, asset} <- lock_job_asset(repo, envelope),
         true <-
           asset.state == :processing and
             asset.state_revision == processing_revision,
         {:ok, target} <- metadata_target(repo, asset),
         :ok <-
           validate_metadata_checkpoint_binding(
             final_checkpoint,
             envelope,
             asset,
             target
           ),
         :ok <- validate_checkpoint_target(final_checkpoint, target),
         {:ok, stored_metadata} <- lock_pending_metadata(repo, asset, target),
         {:ok, failed_asset} <-
           persist_metadata_failure(
             repo,
             asset,
             stored_metadata,
             envelope,
             processing_revision,
             failure,
             final_checkpoint
           ) do
      {:ok,
       %{
         status: :complete,
         effect_result: :failed,
         asset: failed_asset
       }}
    else
      false -> {:error, Error.new(:conflict)}
      {:error, %Error{}} = error -> error
    end
  end

  defp persist_metadata_failure(
         repo,
         asset,
         stored_metadata,
         envelope,
         processing_revision,
         failure,
         final_checkpoint
       ) do
    now = DateTime.utc_now(:microsecond)

    with {:ok, _failed_metadata} <-
           stored_metadata
           |> AssetMetadata.upsert_changeset(%{
             extraction_state: :failed,
             completed_at: now
           })
           |> repo.update()
           |> map_changeset_result(),
         {:ok, failed_asset} <-
           asset
           |> StoredAsset.record_failure_changeset(%{
             failure_code: Atom.to_string(failure.code),
             retryable?: false,
             failed_operation: "asset_metadata",
             attempt: asset.attempt
           })
           |> repo.update()
           |> map_changeset_result(),
         :ok <- AssetSearchStore.delete(repo, %{asset_id: asset.id, vault_id: asset.vault_id}),
         {:ok, _audit} <-
           repo.insert(
             audit_changeset(%{
               operation: "asset.metadata_failed",
               result: :failed,
               vault_id: asset.vault_id,
               principal_id: envelope.principal_id,
               classification: asset.classification,
               correlation_id: envelope.correlation_id,
               target_id: asset.id,
               metadata: %{
                 "failure_code" => Atom.to_string(failure.code),
                 "job_id" => envelope.job_id,
                 "operation" => "asset_metadata",
                 "retryable" => false
               },
               occurred_at: now
             })
           ),
         {:ok, _receipt} <-
           Progress.record_effect(repo, envelope, %{
             effect_key: envelope.idempotency_key,
             result: :failed,
             entity_revision: processing_revision
           }),
         {:ok, _progress} <-
           Progress.transition_metadata(
             repo,
             envelope,
             processing_revision,
             final_checkpoint,
             :failed
           ) do
      {:ok, failed_asset}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset_error(changeset)}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp lock_pending_metadata(repo, asset, target) do
    query =
      from metadata in AssetMetadata,
        where:
          metadata.id == ^target.metadata_id and
            metadata.asset_id == ^asset.id and
            metadata.resource_version_id == ^asset.resource_version_id and
            metadata.vault_id == ^asset.vault_id and
            metadata.classification == ^asset.classification and
            metadata.extraction_state == :pending,
        lock: "FOR UPDATE"

    case repo.all(query) do
      [%AssetMetadata{} = metadata] -> {:ok, metadata}
      [] -> {:error, Error.new(:conflict)}
      [_first, _second] -> {:error, Error.new(:integrity_failure)}
    end
  end

  defp validate_metadata_matches_target(metadata, target) do
    if metadata.plaintext_bytes == target.plaintext_byte_size and
         metadata.detected_media_type == target.declared_media_type do
      :ok
    else
      {:error, Error.new(:conflict)}
    end
  end

  defp validate_checkpoint_target(
         %{
           "extractor_state" => %{
             "declared_media_type" => declared_media_type,
             "plaintext_bytes" => plaintext_bytes
           }
         },
         %{
           declared_media_type: declared_media_type,
           plaintext_byte_size: plaintext_bytes
         }
       ),
       do: :ok

  defp validate_checkpoint_target(
         %{
           "extractor_state" => %{
             "phase" => "done",
             "result" => %{
               "detected_media_type" => detected_media_type,
               "plaintext_bytes" => plaintext_bytes
             }
           }
         },
         %{
           declared_media_type: detected_media_type,
           plaintext_byte_size: plaintext_bytes
         }
       ),
       do: :ok

  defp validate_checkpoint_target(_checkpoint, _target),
    do: {:error, Error.new(:conflict)}

  defp validate_extracted_metadata(metadata) do
    exact_keys? =
      Enum.sort(Map.keys(metadata)) ==
        Enum.sort([
          :detected_media_type,
          :plaintext_bytes,
          :width,
          :height,
          :pdf_version,
          :extractor_version
        ])

    common? =
      exact_keys? and is_integer(metadata.plaintext_bytes) and
        metadata.plaintext_bytes >= 0 and metadata.plaintext_bytes <= @max_bigint and
        metadata.extractor_version == 1

    typed? =
      case metadata do
        %{
          detected_media_type: "application/pdf",
          width: nil,
          height: nil,
          pdf_version: version
        } ->
          valid_pdf_version?(version)

        %{
          detected_media_type: "image/jpeg",
          width: width,
          height: height,
          pdf_version: nil
        } ->
          metadata_dimension?(width, 65_535) and metadata_dimension?(height, 65_535)

        %{
          detected_media_type: "image/png",
          width: width,
          height: height,
          pdf_version: nil
        } ->
          metadata_dimension?(width, 2_147_483_647) and
            metadata_dimension?(height, 2_147_483_647)

        _other ->
          false
      end

    if common? and typed?,
      do: :ok,
      else: {:error, Error.new(:integrity_failure)}
  end

  defp validate_terminal_metadata_checkpoint(
         checkpoint,
         envelope,
         processing_revision,
         terminal
       ) do
    with :ok <- validate_terminal_checkpoint_binding(checkpoint, envelope, processing_revision),
         :ok <- validate_terminal_extractor_state(checkpoint["extractor_state"], terminal),
         plaintext_bytes <-
           terminal_plaintext_bytes(terminal, checkpoint["extractor_state"]),
         true <-
           valid_terminal_chunk_index?(
             checkpoint["next_chunk_index"],
             plaintext_bytes
           ) do
      :ok
    else
      false -> {:error, Error.new(:integrity_failure)}
      {:error, %Error{}} = error -> error
    end
  end

  defp validate_terminal_checkpoint_binding(
         %{
           "object_id" => object_id,
           "object_generation" => object_generation,
           "extractor_state" => extractor_state
         } = checkpoint,
         envelope,
         processing_revision
       ) do
    with {:ok, target} <- terminal_checkpoint_target(extractor_state) do
      binding = %{
        job_id: envelope.job_id,
        vault_id: envelope.vault_id,
        principal_id: envelope.principal_id,
        required_capability: envelope.required_capability,
        principal_authorization_epoch: envelope.principal_authorization_epoch,
        vault_authorization_epoch: envelope.vault_authorization_epoch,
        object_id: object_id,
        object_generation: object_generation,
        processing_revision: processing_revision,
        declared_media_type: target.declared_media_type,
        plaintext_byte_size: target.plaintext_byte_size
      }

      case CustodyRepository.validate_metadata_checkpoint(checkpoint, binding) do
        :ok -> :ok
        {:error, %Error{code: :invalid}} -> {:error, Error.new(:integrity_failure)}
        {:error, %Error{}} = error -> error
      end
    end
  end

  defp validate_terminal_checkpoint_binding(_checkpoint, _envelope, _processing_revision),
    do: {:error, Error.new(:integrity_failure)}

  defp terminal_checkpoint_target(%{
         "phase" => "done",
         "result" => %{
           "detected_media_type" => declared_media_type,
           "plaintext_bytes" => plaintext_byte_size
         }
       }),
       do:
         {:ok,
          %{
            declared_media_type: declared_media_type,
            plaintext_byte_size: plaintext_byte_size
          }}

  defp terminal_checkpoint_target(%{
         "phase" => "failed",
         "declared_media_type" => declared_media_type,
         "plaintext_bytes" => plaintext_byte_size
       }),
       do:
         {:ok,
          %{
            declared_media_type: declared_media_type,
            plaintext_byte_size: plaintext_byte_size
          }}

  defp terminal_checkpoint_target(_extractor_state),
    do: {:error, Error.new(:integrity_failure)}

  defp valid_pdf_version?(<<major, ?., minor>>),
    do: major in ?0..?9 and minor in ?0..?9

  defp valid_pdf_version?(_version), do: false

  defp metadata_dimension?(value, maximum),
    do: is_integer(value) and value in 1..maximum

  defp validate_terminal_extractor_state(
         %{"phase" => "done", "result" => result} = state,
         {:done, metadata}
       )
       when is_map(result) do
    expected = %{
      "detected_media_type" => metadata.detected_media_type,
      "plaintext_bytes" => metadata.plaintext_bytes,
      "width" => metadata.width,
      "height" => metadata.height,
      "pdf_version" => metadata.pdf_version,
      "extractor_version" => metadata.extractor_version
    }

    if Enum.sort(Map.keys(state)) == ["phase", "result"] and
         Enum.sort(Map.keys(result)) == Enum.sort(@metadata_result_keys) and
         result == expected,
       do: :ok,
       else: {:error, Error.new(:integrity_failure)}
  end

  defp validate_terminal_extractor_state(
         %{
           "phase" => "failed",
           "error_code" => error_code,
           "declared_media_type" => declared_media_type,
           "plaintext_bytes" => plaintext_bytes
         } = state,
         {:error, %Error{code: error_code_atom}}
       ) do
    if Enum.sort(Map.keys(state)) ==
         Enum.sort([
           "phase",
           "error_code",
           "declared_media_type",
           "plaintext_bytes"
         ]) and
         error_code == Atom.to_string(error_code_atom) and
         is_binary(declared_media_type) and declared_media_type != "" and
         byte_size(declared_media_type) <= 255 and
         is_integer(plaintext_bytes) and plaintext_bytes >= 0 and
         plaintext_bytes <= @max_bigint,
       do: :ok,
       else: {:error, Error.new(:integrity_failure)}
  end

  defp validate_terminal_extractor_state(_state, _terminal),
    do: {:error, Error.new(:integrity_failure)}

  defp terminal_plaintext_bytes({:done, metadata}, _state), do: metadata.plaintext_bytes

  defp terminal_plaintext_bytes(
         {:error, _failure},
         %{"plaintext_bytes" => plaintext_bytes}
       ),
       do: plaintext_bytes

  defp terminal_plaintext_bytes({:error, _failure}, _state), do: :invalid

  defp valid_terminal_chunk_index?(next_chunk_index, plaintext_bytes)
       when is_integer(next_chunk_index) and next_chunk_index > 0 and
              is_integer(plaintext_bytes) and plaintext_bytes >= 0 do
    next_chunk_index <= max(1, chunk_count(plaintext_bytes))
  end

  defp valid_terminal_chunk_index?(_next_chunk_index, _plaintext_bytes), do: false

  defp validate_metadata_failure(%Error{code: code, retryable?: false})
       when code in [:integrity_failure, :unsupported_media_type],
       do: :ok

  defp validate_metadata_failure(_failure),
    do: {:error, Error.new(:invalid)}

  @impl true
  def record_job_failure(
        repo,
        %JobEnvelope{} = envelope,
        %Error{} = failure
      ) do
    with {:ok, operation} <- failure_operation(envelope.job_type),
         :ok <- validate_asset_job(envelope, envelope.job_type) do
      transact_callback(repo, fn ->
        do_record_job_failure(
          repo,
          envelope,
          failure,
          operation
        )
      end)
    end
  rescue
    _error in [Ecto.Query.CastError, Ecto.StaleEntryError] ->
      {:error, Error.new(:conflict)}

    error in [Ecto.ConstraintError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  def record_job_failure(_repo, _envelope, _failure),
    do: {:error, Error.new(:invalid)}

  @spec retry(module(), map()) ::
          {:ok, :accepted | :stale} | {:error, Error.t()}
  def retry(repo, command) when is_map(command) do
    with :ok <- validate_retry_command(command) do
      transact_callback(repo, fn ->
        with {:ok, asset} <- lock_retry_asset(repo, command) do
          retry_locked_asset(repo, asset, command)
        end
      end)
    end
  rescue
    _error in [Ecto.Query.CastError, Ecto.StaleEntryError] ->
      {:error, Error.new(:conflict)}

    error in [Ecto.ConstraintError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  def retry(_repo, _command), do: {:error, Error.new(:invalid)}

  defp do_record_job_failure(
         repo,
         envelope,
         failure,
         operation
       ) do
    with {:ok, receipt} <- lock_effect_receipt(repo, envelope),
         {:ok, asset} <- lock_job_asset(repo, envelope) do
      case receipt do
        %EffectReceipt{} ->
          fetch_asset(repo, asset.id)

        nil ->
          persist_job_failure(
            repo,
            asset,
            envelope,
            failure,
            operation
          )
      end
    end
  end

  defp persist_job_failure(
         repo,
         asset,
         envelope,
         failure,
         operation
       ) do
    if asset.state_revision == envelope.expected_entity_revision and
         failure_state?(asset.state, envelope.job_type) do
      now = DateTime.utc_now(:microsecond)

      with {:ok, _failed_asset} <-
             asset
             |> StoredAsset.record_failure_changeset(%{
               failure_code: Atom.to_string(failure.code),
               retryable?: failure.retryable?,
               failed_operation: envelope.job_type,
               attempt: asset.attempt
             })
             |> repo.update()
             |> map_changeset_result(),
           {:ok, _audit} <-
             repo.insert(
               audit_changeset(%{
                 operation: operation,
                 result: :failed,
                 vault_id: asset.vault_id,
                 principal_id: envelope.principal_id,
                 classification: asset.classification,
                 correlation_id: envelope.correlation_id,
                 target_id: asset.id,
                 metadata: %{
                   "failure_code" => Atom.to_string(failure.code),
                   "job_id" => envelope.job_id,
                   "operation" => envelope.job_type,
                   "retryable" => failure.retryable?
                 },
                 occurred_at: now
               })
             ),
           {:ok, _receipt} <-
             Progress.record_effect(repo, envelope, %{
               effect_key: envelope.idempotency_key,
               result: :failed,
               entity_revision: asset.state_revision
             }) do
        fetch_asset(repo, asset.id)
      else
        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset_error(changeset)}

        {:error, %Error{}} = error ->
          error
      end
    else
      fetch_asset(repo, asset.id)
    end
  end

  defp failure_operation("asset_verify"),
    do: {:ok, "asset.verify_failed"}

  defp failure_operation("asset_finalize"),
    do: {:ok, "asset.finalize_failed"}

  defp failure_operation("asset_cleanup"),
    do: {:ok, "asset.cleanup_failed"}

  defp failure_operation(_job_type),
    do: {:error, Error.new(:invalid)}

  defp failure_state?(:uploaded, "asset_verify"), do: true
  defp failure_state?(:verified, "asset_finalize"), do: true
  defp failure_state?(:pending_delete, "asset_cleanup"), do: true
  defp failure_state?(_state, _job_type), do: false

  defp prepare_pending_verification(repo, envelope) do
    with {:ok, asset} <- lock_job_asset(repo, envelope) do
      if asset.state == :uploaded and
           asset.state_revision == envelope.expected_entity_revision do
        with {:ok, stage} <- lock_verification_stage(repo, asset.id, asset.vault_id),
             :ok <- validate_stage_envelope(stage) do
          {:ok,
           %{
             status: :pending,
             asset: asset,
             stage_id: stage.id,
             stage_ref: %StageRef{stage_id: stage.id},
             ciphertext_byte_size: stage.ciphertext_byte_size,
             ciphertext_hash: stage.ciphertext_hash,
             format_envelope: %{
               algorithm: :aes_256_gcm,
               chunk_count: chunk_count(stage.plaintext_byte_size),
               chunk_size: 4_194_304,
               encryption_domain_id: stage.key_domain_id,
               final_record?: true,
               format_version: stage.format_version,
               object_id: stage.candidate_object_id,
               vault_id: stage.vault_id
             }
           }}
        end
      else
        record_stale_job(repo, envelope, asset)
      end
    end
  end

  defp do_record_verified_stage(repo, envelope, command) do
    with {:ok, receipt} <- lock_effect_receipt(repo, envelope) do
      case receipt do
        %EffectReceipt{} ->
          completed_job_result(repo, envelope, receipt)

        nil ->
          apply_verified_stage(repo, envelope, command)
      end
    end
  end

  defp apply_verified_stage(repo, envelope, command) do
    with {:ok, asset} <- lock_job_asset(repo, envelope) do
      if asset.state == :uploaded and
           asset.state_revision == envelope.expected_entity_revision do
        with {:ok, stage} <- lock_asset_stage(repo, command.stage_id),
             :ok <- validate_stage_envelope(stage),
             :ok <- validate_verified_stage_binding(stage, asset, command),
             {:ok, verified} <- persist_verified_effect(repo, asset, envelope) do
          {:ok,
           %{
             status: :complete,
             effect_result: :applied,
             asset: verified
           }}
        end
      else
        record_stale_job(repo, envelope, asset)
      end
    end
  end

  defp persist_verified_effect(repo, asset, envelope) do
    now = DateTime.utc_now(:microsecond)

    changeset =
      asset
      |> StoredAsset.transition_changeset(%{
        state: :verified,
        state_revision: asset.state_revision
      })
      |> Ecto.Changeset.optimistic_lock(:state_revision)

    with {:ok, verified} <- repo.update(changeset),
         {:ok, _audit} <-
           repo.insert(
             audit_changeset(%{
               operation: "asset.verified",
               vault_id: asset.vault_id,
               principal_id: envelope.principal_id,
               classification: asset.classification,
               correlation_id: envelope.correlation_id,
               target_id: asset.id,
               metadata: %{"state" => "verified"},
               occurred_at: now
             })
           ),
         {:ok, _outbox} <-
           repo.insert(
             outbox_changeset(
               %{
                 event_type: "asset.finalize_requested",
                 idempotency_key: "asset-finalize:#{asset.id}:#{verified.state_revision}",
                 vault_id: asset.vault_id,
                 principal_id: envelope.principal_id,
                 required_capability: "asset.write",
                 classification: asset.classification,
                 correlation_id: envelope.correlation_id,
                 causation_id: envelope.job_id,
                 expected_entity_revision: verified.state_revision,
                 payload: %{"asset_id" => asset.id},
                 occurred_at: now
               },
               %{
                 principal_authorization_epoch: envelope.principal_authorization_epoch,
                 vault_authorization_epoch: envelope.vault_authorization_epoch
               }
             )
           ),
         {:ok, _receipt} <-
           Progress.record_effect(repo, envelope, %{
             effect_key: envelope.idempotency_key,
             result: :applied,
             entity_revision: verified.state_revision
           }) do
      {:ok, verified}
    else
      {:error, %Ecto.Changeset{} = changeset_error} ->
        {:error, changeset_error(changeset_error)}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp validate_verified_stage_binding(stage, asset, command) do
    exact? =
      stage.id == command.stage_id and
        stage.asset_id == asset.id and
        stage.vault_id == asset.vault_id and
        stage.classification == asset.classification and
        stage.state == :sealed and
        stage.state_revision == 1 and
        stage.ciphertext_byte_size == command.ciphertext_byte_size and
        digest_matches?(stage.ciphertext_hash, command.ciphertext_hash)

    if exact?,
      do: :ok,
      else: {:error, Error.new(:conflict)}
  end

  defp validate_stage_envelope(%AssetStage{} = stage) do
    with :ok <-
           UUID.validate([
             stage.id,
             stage.asset_id,
             stage.vault_id,
             stage.key_domain_id,
             stage.candidate_object_id,
             stage.domain_key_version_id
           ]),
         true <- stage.state == :sealed,
         true <- stage.state_revision == 1,
         true <- stage.format_version == 1,
         true <-
           is_integer(stage.ciphertext_byte_size) and
             stage.ciphertext_byte_size >= 0,
         true <-
           is_binary(stage.ciphertext_hash) and
             byte_size(stage.ciphertext_hash) == 32,
         true <- stage.wrapper_algorithm == "aes_256_gcm",
         true <- is_integer(stage.key_generation) and stage.key_generation > 0,
         true <- is_binary(stage.dek_wrapper) and byte_size(stage.dek_wrapper) > 0 do
      :ok
    else
      _invalid -> {:error, Error.new(:integrity_failure)}
    end
  end

  defp lock_verification_stage(repo, asset_id, vault_id) do
    query =
      from stage in AssetStage,
        where:
          stage.asset_id == ^asset_id and
            stage.vault_id == ^vault_id and
            stage.state == :sealed,
        order_by: [asc: stage.inserted_at, asc: stage.id],
        limit: 2,
        lock: "FOR SHARE"

    case repo.all(query) do
      [%AssetStage{} = stage] -> {:ok, stage}
      [] -> {:error, Error.new(:conflict)}
      [_first, _second] -> {:error, Error.new(:conflict)}
    end
  end

  defp lock_job_asset(repo, envelope) do
    asset_id = envelope.payload["asset_id"]

    query =
      from asset in StoredAsset,
        where:
          asset.id == ^asset_id and
            asset.vault_id == ^envelope.vault_id and
            asset.classification == ^envelope.classification,
        lock: "FOR UPDATE"

    case repo.one(query) do
      %StoredAsset{} = asset -> {:ok, asset}
      nil -> {:error, Error.new(:conflict)}
    end
  end

  defp lock_effect_receipt(repo, envelope) do
    query =
      from receipt in EffectReceipt,
        where:
          receipt.vault_id == ^envelope.vault_id and
            receipt.effect_key == ^envelope.idempotency_key,
        lock: "FOR UPDATE"

    case repo.one(query) do
      nil ->
        {:ok, nil}

      %EffectReceipt{} = receipt ->
        if receipt.submission_id == envelope.job_id and
             receipt.classification == envelope.classification do
          {:ok, receipt}
        else
          {:error, Error.new(:conflict)}
        end
    end
  end

  defp completed_job_result(repo, envelope, receipt) do
    if receipt.result == :failed do
      {:error, Error.new(:job_failed)}
    else
      with {:ok, asset} <- lock_job_asset(repo, envelope),
           true <- receipt.entity_revision <= asset.state_revision,
           true <- receipt.result in [:applied, :stale] do
        {:ok,
         %{
           status: :complete,
           effect_result: receipt.result,
           asset: asset
         }}
      else
        false -> {:error, Error.new(:conflict)}
        {:error, %Error{}} = error -> error
      end
    end
  end

  defp completed_metadata_job_result(repo, envelope, %EffectReceipt{result: :failed} = receipt) do
    with {:ok, asset} <- lock_job_asset(repo, envelope),
         true <- receipt.entity_revision == asset.state_revision do
      {:ok,
       %{
         status: :complete,
         effect_result: :failed,
         asset: asset
       }}
    else
      false -> {:error, Error.new(:conflict)}
      {:error, %Error{}} = error -> error
    end
  end

  defp record_stale_job(repo, envelope, asset) do
    with {:ok, _receipt} <-
           Progress.record_effect(repo, envelope, %{
             effect_key: envelope.idempotency_key,
             result: :stale,
             entity_revision: asset.state_revision
           }) do
      {:ok,
       %{
         status: :complete,
         effect_result: :stale,
         asset: asset
       }}
    end
  end

  defp resolve_pending_finalization(repo, envelope) do
    with {:ok, asset} <- lock_job_asset(repo, envelope) do
      if asset.state == :verified and
           asset.state_revision == envelope.expected_entity_revision do
        with {:ok, stage} <- lock_verification_stage(repo, asset.id, asset.vault_id),
             :ok <- validate_stage_envelope(stage),
             {:ok, canonical} <-
               lock_live_canonical_object(repo, stage, "FOR SHARE") do
          {:ok,
           %{
             status: :lock,
             asset: asset,
             object_id: if(canonical, do: canonical.id, else: stage.candidate_object_id),
             stage_id: stage.id
           }}
        end
      else
        record_stale_job(repo, envelope, asset)
      end
    end
  end

  defp do_reserve_finalization(repo, envelope, requested_object_id) do
    with {:ok, receipt} <- lock_effect_receipt(repo, envelope) do
      case receipt do
        %EffectReceipt{} ->
          completed_job_result(repo, envelope, receipt)

        nil ->
          reserve_pending_finalization(repo, envelope, requested_object_id)
      end
    end
  end

  defp reserve_pending_finalization(repo, envelope, requested_object_id) do
    with {:ok, asset} <- lock_job_asset(repo, envelope) do
      if asset.state == :verified and
           asset.state_revision == envelope.expected_entity_revision do
        with {:ok, stage} <- lock_verification_stage(repo, asset.id, asset.vault_id),
             :ok <- validate_stage_envelope(stage),
             {:ok, canonical} <-
               lock_live_canonical_object(repo, stage, "FOR UPDATE") do
          reserve_canonical_object(
            repo,
            stage,
            canonical,
            requested_object_id
          )
        end
      else
        record_stale_job(repo, envelope, asset)
      end
    end
  end

  defp reserve_canonical_object(
         repo,
         stage,
         nil,
         requested_object_id
       )
       when requested_object_id == stage.candidate_object_id do
    with {:ok, object} <- insert_staged_object(repo, stage),
         {:ok, _envelope} <- insert_candidate_key_envelope(repo, stage, object.id) do
      {:ok, finalization_reservation(:publish, stage, object)}
    end
  end

  defp reserve_canonical_object(_repo, stage, nil, _requested_object_id) do
    {:ok,
     %{
       status: :retry_lock,
       object_id: stage.candidate_object_id
     }}
  end

  defp reserve_canonical_object(
         _repo,
         %AssetStage{} = _stage,
         %AssetObject{id: canonical_id},
         requested_object_id
       )
       when canonical_id != requested_object_id do
    {:ok, %{status: :retry_lock, object_id: canonical_id}}
  end

  defp reserve_canonical_object(
         repo,
         stage,
         %AssetObject{lifecycle: :available} = object,
         _requested_object_id
       ) do
    with :ok <- validate_reusable_object(object, stage),
         :ok <- validate_canonical_key_envelope(repo, object) do
      {:ok, finalization_reservation(:reuse, stage, object)}
    end
  end

  defp reserve_canonical_object(
         repo,
         stage,
         %AssetObject{lifecycle: :staged} = object,
         _requested_object_id
       ) do
    with true <- object.id == stage.candidate_object_id,
         :ok <- validate_publishing_object(object, stage),
         :ok <- validate_candidate_key_envelope(repo, object, stage) do
      {:ok, finalization_reservation(:publish, stage, object)}
    else
      false -> {:error, Error.new(:storage_unavailable, retryable?: true)}
      {:error, %Error{}} = error -> error
    end
  end

  defp reserve_canonical_object(
         _repo,
         _stage,
         %AssetObject{},
         _requested_object_id
       ),
       do: {:error, Error.new(:storage_unavailable, retryable?: true)}

  defp insert_staged_object(repo, stage) do
    %AssetObject{}
    |> AssetObject.create_changeset(%{
      id: stage.candidate_object_id,
      vault_id: stage.vault_id,
      key_domain_id: stage.key_domain_id,
      classification: stage.classification,
      lookup_digest: stage.lookup_digest,
      ciphertext_hash: stage.ciphertext_hash,
      plaintext_byte_size: stage.plaintext_byte_size,
      ciphertext_byte_size: stage.ciphertext_byte_size,
      storage_ref: stage.candidate_object_id,
      format_version: stage.format_version,
      lifecycle: :staged,
      lifecycle_revision: 0
    })
    |> repo.insert()
    |> map_reservation_insert_result()
  end

  defp insert_candidate_key_envelope(repo, stage, object_id) do
    %AssetKeyEnvelope{}
    |> AssetKeyEnvelope.create_changeset(%{
      id: Ecto.UUID.generate(),
      vault_id: stage.vault_id,
      asset_object_id: object_id,
      domain_key_version_id: stage.domain_key_version_id,
      key_domain_id: stage.key_domain_id,
      classification: stage.classification,
      algorithm: stage.wrapper_algorithm,
      key_generation: stage.key_generation,
      wrapped_dek: stage.dek_wrapper
    })
    |> repo.insert()
    |> map_changeset_result()
  end

  defp finalization_reservation(action, stage, object)
       when action in [:publish, :reuse] do
    %{
      status: :reserved,
      action: action,
      object_id: object.id,
      object_ref: %ObjectRef{object_id: object.id},
      stage_id: stage.id,
      stage_ref: %StageRef{stage_id: stage.id},
      vault_id: object.vault_id,
      key_domain_id: object.key_domain_id,
      lookup_digest: object.lookup_digest,
      ciphertext_byte_size: object.ciphertext_byte_size,
      ciphertext_hash: object.ciphertext_hash
    }
  end

  defp do_acknowledge_finalization(repo, command) do
    envelope = command.envelope

    with {:ok, receipt} <- lock_effect_receipt(repo, envelope) do
      case receipt do
        %EffectReceipt{} ->
          completed_job_result(repo, envelope, receipt)

        nil ->
          acknowledge_pending_finalization(repo, command)
      end
    end
  end

  defp acknowledge_pending_finalization(repo, command) do
    envelope = command.envelope

    with {:ok, asset} <- lock_job_asset(repo, envelope) do
      if asset.state == :verified and
           asset.state_revision == envelope.expected_entity_revision do
        with {:ok, stage} <- lock_asset_stage(repo, command.stage_id),
             {:ok, object} <-
               lock_asset_object(
                 repo,
                 command.object_id,
                 envelope.vault_id
               ),
             :ok <- validate_stage_envelope(stage),
             :ok <-
               validate_finalization_acknowledgement(
                 repo,
                 asset,
                 stage,
                 object,
                 command
               ),
             {:ok, available} <-
               persist_available_effect(
                 repo,
                 asset,
                 stage,
                 object,
                 command
               ) do
          {:ok,
           %{
             status: :complete,
             effect_result: :applied,
             asset: available
           }}
        end
      else
        record_stale_job(repo, envelope, asset)
      end
    end
  end

  defp validate_finalization_acknowledgement(
         repo,
         asset,
         stage,
         object,
         command
       ) do
    exact_binding? =
      stage.id == command.stage_id and
        stage.asset_id == asset.id and
        stage.vault_id == asset.vault_id and
        stage.classification == asset.classification and
        stage.state == :sealed and
        stage.state_revision == 1 and
        object.id == command.object_id and
        object.vault_id == stage.vault_id and
        object.key_domain_id == stage.key_domain_id and
        object.classification == stage.classification and
        digest_matches?(object.lookup_digest, stage.lookup_digest) and
        object.plaintext_byte_size == stage.plaintext_byte_size and
        object.format_version == stage.format_version and
        object.ciphertext_byte_size ==
          command.observed_ciphertext_byte_size and
        digest_matches?(
          object.ciphertext_hash,
          command.observed_ciphertext_hash
        )

    with true <- exact_binding?,
         :ok <-
           validate_acknowledgement_action(
             repo,
             object,
             stage,
             command.action
           ) do
      :ok
    else
      false -> {:error, Error.new(:conflict)}
      {:error, %Error{}} = error -> error
    end
  end

  defp validate_acknowledgement_action(
         repo,
         %AssetObject{lifecycle: :staged} = object,
         stage,
         :publish
       ) do
    with true <- object.id == stage.candidate_object_id,
         :ok <- validate_publishing_object(object, stage),
         :ok <- validate_candidate_key_envelope(repo, object, stage) do
      :ok
    else
      false -> {:error, Error.new(:conflict)}
      {:error, %Error{}} = error -> error
    end
  end

  defp validate_acknowledgement_action(
         repo,
         %AssetObject{lifecycle: :available} = object,
         stage,
         :reuse
       ) do
    with :ok <- validate_reusable_object(object, stage),
         :ok <- validate_canonical_key_envelope(repo, object) do
      :ok
    end
  end

  defp validate_acknowledgement_action(
         _repo,
         _object,
         _stage,
         _action
       ),
       do: {:error, Error.new(:conflict)}

  defp persist_available_effect(repo, asset, stage, object, command) do
    envelope = command.envelope
    now = DateTime.utc_now(:microsecond)

    with {:ok, available_object} <-
           make_object_available(repo, object, command.action),
         {:ok, _finalized_stage} <-
           stage
           |> AssetStage.finalize_changeset()
           |> repo.update()
           |> map_changeset_result(),
         {:ok, available_asset} <-
           asset
           |> StoredAsset.attach_object_changeset(%{
             asset_object_id: available_object.id
           })
           |> StoredAsset.transition_changeset(%{
             state: :available,
             state_revision: asset.state_revision
           })
           |> Ecto.Changeset.optimistic_lock(:state_revision)
           |> repo.update()
           |> map_changeset_result(),
         {:ok, _audit} <-
           repo.insert(
             audit_changeset(%{
               operation: "asset.available",
               vault_id: asset.vault_id,
               principal_id: envelope.principal_id,
               classification: asset.classification,
               correlation_id: envelope.correlation_id,
               target_id: asset.id,
               metadata: %{"state" => "available"},
               occurred_at: now
             })
           ),
         {:ok, _outbox} <-
           repo.insert(
             outbox_changeset(
               %{
                 event_type: "asset.metadata_requested",
                 idempotency_key: "asset-metadata:#{asset.id}:#{available_asset.state_revision}",
                 vault_id: asset.vault_id,
                 principal_id: envelope.principal_id,
                 required_capability: "asset.read",
                 classification: asset.classification,
                 correlation_id: envelope.correlation_id,
                 causation_id: envelope.job_id,
                 expected_entity_revision: available_asset.state_revision,
                 payload: %{"asset_id" => asset.id},
                 occurred_at: now
               },
               %{
                 principal_authorization_epoch: envelope.principal_authorization_epoch,
                 vault_authorization_epoch: envelope.vault_authorization_epoch
               }
             )
           ),
         {:ok, _receipt} <-
           Progress.record_effect(repo, envelope, %{
             effect_key: envelope.idempotency_key,
             result: :applied,
             entity_revision: available_asset.state_revision
           }) do
      {:ok, available_asset}
    else
      {:error, %Ecto.Changeset{} = changeset_error} ->
        {:error, changeset_error(changeset_error)}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp make_object_available(
         repo,
         %AssetObject{lifecycle: :staged} = object,
         :publish
       ) do
    object
    |> AssetObject.lifecycle_changeset(%{
      lifecycle: :available,
      lifecycle_revision: object.lifecycle_revision
    })
    |> Ecto.Changeset.optimistic_lock(:lifecycle_revision)
    |> repo.update()
    |> map_changeset_result()
  end

  defp make_object_available(
         _repo,
         %AssetObject{lifecycle: :available} = object,
         :reuse
       ),
       do: {:ok, object}

  defp make_object_available(_repo, _object, _action),
    do: {:error, Error.new(:conflict)}

  defp validate_publishing_object(object, stage) do
    exact? =
      object.id == stage.candidate_object_id and
        object.vault_id == stage.vault_id and
        object.key_domain_id == stage.key_domain_id and
        object.classification == stage.classification and
        digest_matches?(object.lookup_digest, stage.lookup_digest) and
        digest_matches?(object.ciphertext_hash, stage.ciphertext_hash) and
        object.plaintext_byte_size == stage.plaintext_byte_size and
        object.ciphertext_byte_size == stage.ciphertext_byte_size and
        object.storage_ref == stage.candidate_object_id and
        object.format_version == stage.format_version and
        object.lifecycle == :staged and
        object.lifecycle_revision == 0

    if exact?,
      do: :ok,
      else: {:error, Error.new(:conflict)}
  end

  defp validate_reusable_object(object, stage) do
    exact? =
      object.vault_id == stage.vault_id and
        object.key_domain_id == stage.key_domain_id and
        object.classification == stage.classification and
        digest_matches?(object.lookup_digest, stage.lookup_digest) and
        object.plaintext_byte_size == stage.plaintext_byte_size and
        object.format_version == stage.format_version and
        object.lifecycle == :available and
        valid_text?(object.storage_ref)

    if exact?,
      do: :ok,
      else: {:error, Error.new(:conflict)}
  end

  defp validate_candidate_key_envelope(repo, object, stage) do
    query =
      from envelope in AssetKeyEnvelope,
        where:
          envelope.asset_object_id == ^object.id and
            envelope.vault_id == ^object.vault_id and
            envelope.key_domain_id == ^object.key_domain_id and
            envelope.domain_key_version_id == ^stage.domain_key_version_id and
            envelope.classification == ^stage.classification and
            envelope.algorithm == ^stage.wrapper_algorithm and
            envelope.key_generation == ^stage.key_generation,
        lock: "FOR SHARE"

    case repo.one(query) do
      %AssetKeyEnvelope{wrapped_dek: wrapped_dek}
      when is_binary(wrapped_dek) and byte_size(wrapped_dek) > 0 ->
        if :crypto.hash_equals(wrapped_dek, stage.dek_wrapper),
          do: :ok,
          else: {:error, Error.new(:conflict)}

      _missing_or_invalid ->
        {:error, Error.new(:conflict)}
    end
  end

  defp validate_canonical_key_envelope(repo, object) do
    query =
      from envelope in AssetKeyEnvelope,
        where:
          envelope.asset_object_id == ^object.id and
            envelope.vault_id == ^object.vault_id and
            envelope.key_domain_id == ^object.key_domain_id and
            envelope.classification == ^object.classification and
            envelope.key_generation > 0,
        order_by: [desc: envelope.key_generation, desc: envelope.inserted_at],
        limit: 1,
        lock: "FOR SHARE"

    case repo.one(query) do
      %AssetKeyEnvelope{
        algorithm: algorithm,
        wrapped_dek: wrapped_dek
      }
      when is_binary(algorithm) and algorithm != "" and
             is_binary(wrapped_dek) and byte_size(wrapped_dek) > 0 ->
        :ok

      _missing_or_invalid ->
        {:error, Error.new(:conflict)}
    end
  end

  defp lock_live_canonical_object(repo, stage, "FOR SHARE") do
    query =
      from object in AssetObject,
        where:
          object.vault_id == ^stage.vault_id and
            object.key_domain_id == ^stage.key_domain_id and
            object.lookup_digest == ^stage.lookup_digest and
            object.lifecycle != :deleted,
        lock: "FOR SHARE"

    {:ok, repo.one(query)}
  end

  defp lock_live_canonical_object(repo, stage, "FOR UPDATE") do
    query =
      from object in AssetObject,
        where:
          object.vault_id == ^stage.vault_id and
            object.key_domain_id == ^stage.key_domain_id and
            object.lookup_digest == ^stage.lookup_digest and
            object.lifecycle != :deleted,
        lock: "FOR UPDATE"

    {:ok, repo.one(query)}
  end

  defp lock_asset_object(repo, object_id, vault_id) do
    query =
      from object in AssetObject,
        where:
          object.id == ^object_id and
            object.vault_id == ^vault_id,
        lock: "FOR UPDATE"

    case repo.one(query) do
      %AssetObject{} = object -> {:ok, object}
      nil -> {:error, Error.new(:conflict)}
    end
  end

  defp map_changeset_result({:ok, value}), do: {:ok, value}

  defp map_changeset_result({:error, %Ecto.Changeset{} = changeset}),
    do: {:error, changeset_error(changeset)}

  defp map_reservation_insert_result({:ok, value}), do: {:ok, value}

  defp map_reservation_insert_result({:error, %Ecto.Changeset{} = changeset}) do
    if Enum.any?(changeset.errors, fn
         {_field, {_message, metadata}} ->
           metadata[:constraint] == :unique and
             to_string(metadata[:constraint_name]) ==
               "asset_objects_live_lookup_key"
       end) do
      {:error, Error.new(:storage_unavailable, retryable?: true)}
    else
      {:error, changeset_error(changeset)}
    end
  end

  defp validate_metadata_job(
         %JobEnvelope{
           job_type: "asset_metadata",
           required_capability: "asset.read",
           payload: %{"asset_id" => asset_id} = payload,
           classification: classification,
           expected_entity_revision: expected_revision
         } = envelope
       ) do
    with true <- Map.keys(payload) == ["asset_id"],
         :ok <-
           UUID.validate([
             envelope.job_id,
             envelope.vault_id,
             envelope.principal_id,
             envelope.correlation_id,
             envelope.causation_id,
             asset_id
           ]),
         true <- classification in [:private, :sensitive, :restricted],
         true <- is_integer(expected_revision) and expected_revision >= 0,
         true <- valid_text?(envelope.idempotency_key) do
      :ok
    else
      {:error, %Error{}} = error -> error
      _invalid -> {:error, Error.new(:invalid)}
    end
  end

  defp validate_metadata_job(_envelope), do: {:error, Error.new(:invalid)}

  defp validate_asset_job(
         %JobEnvelope{
           job_type: job_type,
           required_capability: required_capability,
           payload: %{"asset_id" => asset_id},
           classification: classification,
           expected_entity_revision: expected_revision
         } = envelope,
         expected_job_type
       ) do
    with true <- job_type == expected_job_type,
         true <- required_capability == "asset.write",
         :ok <-
           UUID.validate([
             envelope.job_id,
             envelope.vault_id,
             envelope.principal_id,
             envelope.correlation_id,
             envelope.causation_id,
             asset_id
           ]),
         true <- classification in [:private, :sensitive, :restricted],
         true <- is_integer(expected_revision) and expected_revision >= 0,
         true <- valid_text?(envelope.idempotency_key),
         false <- Map.has_key?(envelope.payload, "object_dek"),
         false <- Map.has_key?(envelope.payload, "dek_wrapper"),
         false <- Map.has_key?(envelope.payload, "plaintext_sha256") do
      :ok
    else
      {:error, %Error{}} = error -> error
      _invalid -> {:error, Error.new(:invalid)}
    end
  end

  defp transact_callback(repo, callback) do
    case repo.transaction(fn ->
           case callback.() do
             {:error, reason} -> repo.rollback(reason)
             result -> result
           end
         end) do
      {:ok, result} -> result
      {:error, %Error{}} = error -> error
      {:error, _reason} -> {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  defp chunk_count(0), do: 0

  defp chunk_count(plaintext_byte_size)
       when is_integer(plaintext_byte_size) and plaintext_byte_size > 0,
       do:
         div(
           plaintext_byte_size + Format.chunk_size() - 1,
           Format.chunk_size()
         )

  defp validate_retry_command(
         %{
           asset_id: asset_id,
           vault_id: vault_id,
           principal_id: principal_id,
           classification: classification,
           expected_state_revision: expected_state_revision
         } = command
       ) do
    with :ok <- UUID.validate([asset_id, vault_id, principal_id]),
         true <- classification in [:private, :sensitive, :restricted],
         true <-
           is_integer(expected_state_revision) and
             expected_state_revision >= 0,
         true <-
           Map.keys(command)
           |> Enum.sort() ==
             [
               :asset_id,
               :classification,
               :expected_state_revision,
               :principal_id,
               :vault_id
             ] do
      :ok
    else
      {:error, %Error{}} = error -> error
      _invalid -> {:error, Error.new(:invalid)}
    end
  end

  defp validate_retry_command(_command),
    do: {:error, Error.new(:invalid)}

  defp lock_retry_asset(repo, command) do
    query =
      from asset in StoredAsset,
        where:
          asset.id == ^command.asset_id and
            asset.vault_id == ^command.vault_id and
            asset.classification == ^command.classification,
        lock: "FOR UPDATE"

    case repo.one(query) do
      %StoredAsset{} = asset -> {:ok, asset}
      nil -> {:error, Error.new(:not_found)}
    end
  end

  defp retry_locked_asset(repo, asset, command) do
    cond do
      asset.state_revision != command.expected_state_revision ->
        {:ok, :stale}

      retryable_failure?(asset) ->
        apply_retry(repo, asset, command)

      replayed_retry?(repo, asset, command) ->
        {:ok, :accepted}

      true ->
        {:error, Error.new(:conflict)}
    end
  end

  defp retryable_failure?(%StoredAsset{
         failure_code: failure_code,
         retryable?: true,
         failed_operation: failed_operation
       }),
       do: valid_text?(failure_code) and valid_text?(failed_operation)

  defp retryable_failure?(_asset), do: false

  defp apply_retry(repo, asset, command) do
    with {:ok, job} <- retry_job(asset),
         {:ok, epochs} <-
           authorization_epochs(
             repo,
             command.principal_id,
             command.vault_id
           ) do
      next_attempt = asset.attempt + 1
      idempotency_key = retry_idempotency_key(asset, next_attempt)
      now = DateTime.utc_now(:microsecond)
      correlation_id = Ecto.UUID.generate()

      with {:ok, _cleared} <-
             asset
             |> StoredAsset.retry_changeset(%{
               failure_code: nil,
               retryable?: nil,
               failed_operation: nil,
               attempt: next_attempt
             })
             |> repo.update()
             |> map_changeset_result(),
           {:ok, _audit} <-
             repo.insert(
               audit_changeset(%{
                 operation: "asset.retry_requested",
                 vault_id: asset.vault_id,
                 principal_id: command.principal_id,
                 classification: asset.classification,
                 correlation_id: correlation_id,
                 target_id: asset.id,
                 metadata: %{
                   "attempt" => next_attempt,
                   "operation" => job.job_type
                 },
                 occurred_at: now
               })
             ),
           {:ok, _outbox} <-
             repo.insert(
               outbox_changeset(
                 %{
                   event_type: job.event_type,
                   idempotency_key: idempotency_key,
                   vault_id: asset.vault_id,
                   principal_id: command.principal_id,
                   required_capability: "asset.write",
                   classification: asset.classification,
                   correlation_id: correlation_id,
                   causation_id: asset.id,
                   expected_entity_revision: asset.state_revision,
                   payload: %{"asset_id" => asset.id},
                   occurred_at: now
                 },
                 epochs
               )
             ) do
        {:ok, :accepted}
      else
        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset_error(changeset)}

        {:error, %Error{}} = error ->
          error
      end
    end
  end

  defp retry_job(%StoredAsset{
         state: :uploaded,
         failed_operation: operation
       })
       when operation in ["asset_verify", "verify"],
       do:
         {:ok,
          %{
            event_type: "asset.verify_requested",
            job_type: "asset_verify"
          }}

  defp retry_job(%StoredAsset{
         state: :verified,
         failed_operation: operation
       })
       when operation in ["asset_finalize", "finalize"],
       do:
         {:ok,
          %{
            event_type: "asset.finalize_requested",
            job_type: "asset_finalize"
          }}

  defp retry_job(%StoredAsset{
         state: :pending_delete,
         failed_operation: operation
       })
       when operation in ["asset_cleanup", "cleanup"],
       do:
         {:ok,
          %{
            event_type: "asset.cleanup_requested",
            job_type: "asset_cleanup"
          }}

  defp retry_job(_asset), do: {:error, Error.new(:conflict)}

  defp replayed_retry?(repo, asset, command) do
    if is_nil(asset.failure_code) and is_nil(asset.retryable?) and
         is_nil(asset.failed_operation) and asset.attempt > 0 do
      key = retry_idempotency_key(asset, asset.attempt)

      repo.exists?(
        from event in OutboxEvent,
          where:
            event.vault_id == ^command.vault_id and
              event.principal_id == ^command.principal_id and
              event.classification == ^command.classification and
              event.idempotency_key == ^key and
              event.expected_entity_revision ==
                ^command.expected_state_revision and
              fragment("? ->> 'asset_id'", event.payload) ==
                ^command.asset_id
      )
    else
      false
    end
  end

  defp retry_idempotency_key(asset, attempt) do
    "asset-retry:#{asset.id}:#{asset.state_revision}:#{attempt}"
  end

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
           ),
         {:ok, authorization_epochs} <-
           authorization_epochs(repo, intent.principal_id, current.vault_id) do
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
        outbox_changeset(
          %{
            event_type: intent.outbox.event_type,
            idempotency_key:
              "asset-transition:#{intent.asset_id}:#{intent.expected_state_revision}:#{intent.to}",
            vault_id: current.vault_id,
            principal_id: intent.principal_id,
            required_capability: "assets.transition",
            classification: intent.outbox.classification,
            correlation_id: correlation_id,
            causation_id: intent.asset_id,
            expected_entity_revision: intent.expected_state_revision,
            payload: %{
              "asset_id" => intent.asset_id,
              "to" => Atom.to_string(intent.to)
            },
            occurred_at: now
          },
          authorization_epochs
        )

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
    with {:ok, authorization_epochs} <-
           authorization_epochs(repo, intent.principal_id, current.vault_id) do
      do_persist_tombstone(repo, current, tombstoned, intent, authorization_epochs)
    end
  end

  defp do_persist_tombstone(repo, current, tombstoned, intent, authorization_epochs) do
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
      outbox_changeset(
        %{
          event_type: intent.outbox.event_type,
          idempotency_key: "asset-release:#{intent.asset_id}:#{intent.expected_state_revision}",
          vault_id: current.vault_id,
          principal_id: intent.principal_id,
          required_capability: "assets.release",
          classification: intent.outbox.classification,
          correlation_id: correlation_id,
          causation_id: intent.asset_id,
          expected_entity_revision: intent.expected_state_revision,
          payload: %{"asset_id" => intent.asset_id},
          occurred_at: now
        },
        authorization_epochs
      )
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
        stored_asset(stored)
    end
  end

  defp canonical_search_document(repo, asset_id) do
    query =
      from asset in StoredAsset,
        join: resource_version in ResourceVersion,
        on:
          resource_version.id == asset.resource_version_id and
            resource_version.vault_id == asset.vault_id,
        join: resource in Resource,
        on:
          resource.id == resource_version.resource_id and
            resource.vault_id == resource_version.vault_id,
        join: metadata in AssetMetadata,
        on:
          metadata.asset_id == asset.id and
            metadata.resource_version_id == asset.resource_version_id and
            metadata.vault_id == asset.vault_id,
        where: asset.id == ^asset_id,
        where: asset.state == :ready,
        where: metadata.extraction_state == :completed,
        select: %{
          asset_id: asset.id,
          resource_version_id: resource_version.id,
          vault_id: asset.vault_id,
          classification_chain: [
            resource.classification,
            resource_version.classification,
            asset.classification,
            metadata.classification
          ],
          state: asset.state,
          detected_media_type: metadata.detected_media_type,
          resource_title: resource.title,
          original_filename: metadata.original_filename,
          updated_at:
            fragment(
              "GREATEST(?, ?, ?, ?)",
              asset.updated_at,
              resource_version.updated_at,
              resource.updated_at,
              metadata.updated_at
            )
        }

    case repo.one(query) do
      nil ->
        {:error, Error.new(:not_found)}

      %{classification_chain: classifications} = attrs ->
        with {:ok, classification} <- strictest_classification(classifications) do
          {:ok,
           attrs
           |> Map.delete(:classification_chain)
           |> Map.put(:classification, classification)}
        end
    end
  end

  defp strictest_classification(classifications) when is_list(classifications) do
    ranks =
      Classification.values()
      |> Enum.with_index()
      |> Map.new()

    if classifications != [] and
         Enum.all?(classifications, &Map.has_key?(ranks, &1)) do
      {:ok, Enum.max_by(classifications, &Map.fetch!(ranks, &1))}
    else
      {:error, Error.new(:integrity_failure)}
    end
  end

  defp fetch_discoverable_asset(repo, asset_id) do
    query =
      from asset in StoredAsset,
        where: asset.id == ^asset_id,
        where:
          fragment(
            "core.current_principal_can_discover_classification(?)",
            asset.classification
          )

    case repo.one(query) do
      nil -> {:error, Error.new(:not_found)}
      stored -> stored_asset(stored)
    end
  end

  defp stored_asset(stored) do
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
      result: Map.get(attrs, :result, :completed),
      classification: attrs.classification,
      correlation_id: attrs.correlation_id,
      target_type: "asset",
      target_id: attrs.target_id,
      metadata: attrs.metadata,
      occurred_at: attrs.occurred_at
    })
  end

  defp outbox_changeset(attrs, authorization_epochs) do
    OutboxEvent.create_changeset(
      %OutboxEvent{},
      attrs
      |> Map.merge(authorization_epochs)
      |> Map.merge(%{id: Ecto.UUID.generate(), envelope_version: 1})
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

  defp validate_stage_abandonment(
         %{
           stage_id: stage_id,
           grant_id: grant_id,
           asset_id: asset_id,
           session_id: session_id,
           principal_id: principal_id,
           vault_id: vault_id,
           classification: classification,
           storage_ref: storage_ref,
           expected_stage_revision: expected_stage_revision,
           failure_code: failure_code,
           abandoned_at: abandoned_at
         } = command
       ) do
    with :ok <-
           UUID.validate([
             stage_id,
             grant_id,
             asset_id,
             session_id,
             principal_id,
             vault_id
           ]),
         true <- classification in [:private, :sensitive, :restricted],
         true <- valid_text?(storage_ref),
         true <-
           valid_text?(failure_code) and
             failure_code == String.trim(failure_code) and
             byte_size(failure_code) <= 128,
         true <-
           is_integer(expected_stage_revision) and
             expected_stage_revision >= 0,
         {:ok, ^abandoned_at} <- Types.utc_datetime(command, :abandoned_at),
         false <- Map.has_key?(command, :token),
         false <- Map.has_key?(command, :token_digest),
         false <- Map.has_key?(command, :object_dek),
         false <- Map.has_key?(command, :dek_wrapper),
         false <- Map.has_key?(command, :plaintext_sha256) do
      :ok
    else
      {:error, %Error{}} = error -> error
      _invalid -> {:error, Error.new(:invalid)}
    end
  end

  defp validate_stage_abandonment(_command),
    do: {:error, Error.new(:invalid)}

  defp validate_stage_abandonment_binding(
         %{
           stage: stage,
           grant: grant,
           asset: asset,
           authorization_epochs: authorization_epochs
         },
         command
       ) do
    exact_binding? =
      stage.id == command.stage_id and
        stage.upload_grant_id == grant.id and
        stage.asset_id == asset.id and
        stage.vault_id == command.vault_id and
        stage.classification == command.classification and
        stage.storage_ref == command.storage_ref and
        grant.id == command.grant_id and
        grant.session_id == command.session_id and
        grant.principal_id == command.principal_id and
        grant.vault_id == command.vault_id and
        grant.asset_id == command.asset_id and
        grant.classification == command.classification and
        not is_nil(grant.consumed_at) and
        grant.principal_authorization_epoch ==
          authorization_epochs.principal_authorization_epoch and
        grant.vault_authorization_epoch ==
          authorization_epochs.vault_authorization_epoch and
        asset.id == command.asset_id and
        asset.vault_id == command.vault_id and
        asset.classification == command.classification and
        asset.state == :staging and
        asset.state_revision == 0

    cond do
      not exact_binding? ->
        {:error, Error.new(:conflict)}

      stage.state == :open and
          stage.state_revision == command.expected_stage_revision ->
        {:ok, :apply}

      stage.state == :abandoned and
        stage.state_revision == command.expected_stage_revision + 1 and
        stage.failure_code == command.failure_code and
          DateTime.compare(stage.abandoned_at, command.abandoned_at) == :eq ->
        {:ok, :replay}

      true ->
        {:error, Error.new(:conflict)}
    end
  end

  defp stage_abandonment_effects(
         %{abandonment_mode: :replay, stage: stage},
         _command,
         _correlation_id
       ) do
    Multi.new()
    |> Multi.put(:abandoned_stage, stage)
  end

  defp stage_abandonment_effects(
         %{abandonment_mode: :apply, stage: stage, grant: grant},
         command,
         correlation_id
       ) do
    audit =
      audit_changeset(%{
        operation: "asset.upload_abandoned",
        vault_id: grant.vault_id,
        principal_id: grant.principal_id,
        classification: grant.classification,
        correlation_id: correlation_id,
        target_id: grant.asset_id,
        metadata: %{
          "failure_code" => command.failure_code,
          "grant_id" => grant.id,
          "stage_id" => stage.id
        },
        occurred_at: command.abandoned_at
      })

    Multi.new()
    |> Multi.update(
      :abandoned_stage,
      AssetStage.abandon_changeset(stage, %{
        abandoned_at: command.abandoned_at,
        failure_code: command.failure_code
      })
    )
    |> Multi.insert(:abandonment_audit, audit)
  end

  defp validate_sealed_checkpoint(
         %{
           stage_ref: %StageRef{stage_id: stage_id},
           storage_ref: storage_ref,
           grant_id: grant_id,
           session_id: session_id,
           principal_id: principal_id,
           vault_id: vault_id,
           asset_id: asset_id,
           classification: classification,
           expected_stage_revision: expected_stage_revision,
           expected_asset_revision: expected_asset_revision,
           format_version: format_version,
           plaintext_byte_size: plaintext_byte_size,
           ciphertext_byte_size: ciphertext_byte_size,
           lookup_digest: lookup_digest,
           ciphertext_hash: ciphertext_hash,
           sealed_at: sealed_at
         } = command
       ) do
    with :ok <-
           UUID.validate([
             stage_id,
             grant_id,
             session_id,
             principal_id,
             vault_id,
             asset_id
           ]),
         true <- valid_text?(storage_ref),
         true <- classification in [:private, :sensitive, :restricted],
         true <- expected_stage_revision == 0,
         true <- expected_asset_revision == 0,
         true <- is_integer(format_version) and format_version > 0,
         true <-
           is_integer(plaintext_byte_size) and plaintext_byte_size >= 0 and
             plaintext_byte_size <= @max_bigint,
         true <-
           is_integer(ciphertext_byte_size) and ciphertext_byte_size >= 0 and
             ciphertext_byte_size <= @max_bigint,
         true <- is_binary(lookup_digest) and byte_size(lookup_digest) == 32,
         true <- is_binary(ciphertext_hash) and byte_size(ciphertext_hash) == 32,
         {:ok, ^sealed_at} <- Types.utc_datetime(command, :sealed_at),
         false <- Map.has_key?(command, :object_dek),
         false <- Map.has_key?(command, :plaintext_sha256) do
      :ok
    else
      {:error, %Error{}} = error -> error
      _invalid -> {:error, Error.new(:invalid)}
    end
  end

  defp validate_sealed_checkpoint(_command),
    do: {:error, Error.new(:invalid)}

  defp lock_asset_stage(repo, stage_id) do
    query =
      from stage in AssetStage,
        where: stage.id == ^stage_id,
        lock: "FOR UPDATE"

    case repo.one(query) do
      %AssetStage{} = stage -> {:ok, stage}
      nil -> {:error, Error.new(:not_found)}
    end
  end

  defp lock_upload_grant(repo, grant_id, principal_id) do
    query =
      from grant in UploadGrant,
        where:
          grant.id == ^grant_id and
            grant.principal_id == ^principal_id and
            grant.principal_id ==
              fragment("NULLIF(current_setting('singularity.principal_id', true), '')::uuid"),
        lock: "FOR UPDATE"

    case repo.one(query) do
      %UploadGrant{} = grant -> {:ok, grant}
      nil -> {:error, Error.new(:conflict)}
    end
  end

  defp lock_stored_asset(repo, asset_id) do
    query =
      from asset in StoredAsset,
        where: asset.id == ^asset_id,
        lock: "FOR UPDATE"

    case repo.one(query) do
      %StoredAsset{} = asset -> {:ok, asset}
      nil -> {:error, Error.new(:not_found)}
    end
  end

  defp lock_upload_asset(repo, grant, command) do
    with true <- command.asset_id == grant.asset_id,
         true <- command.vault_id == grant.vault_id,
         true <- command.classification == grant.classification,
         {:ok, asset} <- lock_stored_asset(repo, grant.asset_id),
         true <- asset.vault_id == grant.vault_id,
         true <- asset.classification == grant.classification,
         true <- asset.state == :staging,
         true <- asset.state_revision == 0 do
      {:ok, asset}
    else
      {:error, %Error{}} = error -> error
      false -> {:error, Error.new(:conflict)}
    end
  end

  defp lock_upload_source(repo, asset, grant) do
    idempotency_digest = :crypto.hash(:sha256, grant.idempotency_key)

    query =
      from source in SourceReference,
        where:
          source.id == ^grant.source_reference_id and
            source.vault_id == ^grant.vault_id and
            source.resource_version_id == ^asset.resource_version_id and
            source.principal_id == ^grant.principal_id and
            source.classification == ^grant.classification and
            source.kind == :browser_upload and
            source.original_filename == ^grant.filename and
            source.declared_media_type == ^grant.declared_media_type and
            source.byte_size == ^grant.byte_size and
            source.idempotency_key_digest == ^idempotency_digest,
        lock: "FOR SHARE"

    case repo.one(query) do
      %SourceReference{} = source -> {:ok, source}
      nil -> {:error, Error.new(:conflict)}
    end
  end

  defp validate_sealed_checkpoint_binding(
         %{
           stage: stage,
           grant: grant,
           asset: asset,
           source: source,
           authorization_epochs: authorization_epochs
         },
         command
       ) do
    exact_binding? =
      stage.id == command.stage_ref.stage_id and
        stage.storage_ref == command.storage_ref and
        stage.upload_grant_id == grant.id and
        stage.asset_id == asset.id and
        stage.vault_id == command.vault_id and
        stage.classification == command.classification and
        grant.id == command.grant_id and
        grant.session_id == command.session_id and
        grant.principal_id == command.principal_id and
        grant.vault_id == command.vault_id and
        grant.asset_id == command.asset_id and
        grant.classification == command.classification and
        grant.byte_size == command.plaintext_byte_size and
        not is_nil(grant.consumed_at) and
        grant.principal_authorization_epoch ==
          authorization_epochs.principal_authorization_epoch and
        grant.vault_authorization_epoch ==
          authorization_epochs.vault_authorization_epoch and
        asset.id == command.asset_id and
        asset.vault_id == command.vault_id and
        asset.classification == command.classification and
        source.vault_id == command.vault_id and
        source.id == grant.source_reference_id and
        source.resource_version_id == asset.resource_version_id and
        source.principal_id == command.principal_id and
        source.classification == command.classification and
        source.original_filename == grant.filename and
        source.declared_media_type == grant.declared_media_type and
        source.byte_size == grant.byte_size

    cond do
      not exact_binding? ->
        {:error, Error.new(:conflict)}

      open_checkpoint?(stage, asset, command) ->
        {:ok, :apply}

      replayed_checkpoint?(stage, asset, command) ->
        {:ok, :replay}

      true ->
        {:error, Error.new(:conflict)}
    end
  end

  defp open_checkpoint?(stage, asset, command) do
    stage.state == :open and
      stage.state_revision == command.expected_stage_revision and
      asset.state == :staging and
      asset.state_revision == command.expected_asset_revision
  end

  defp replayed_checkpoint?(stage, asset, command) do
    stage.state == :sealed and
      stage.state_revision == command.expected_stage_revision + 1 and
      stage.format_version == command.format_version and
      stage.plaintext_byte_size == command.plaintext_byte_size and
      stage.ciphertext_byte_size == command.ciphertext_byte_size and
      digest_matches?(stage.lookup_digest, command.lookup_digest) and
      digest_matches?(stage.ciphertext_hash, command.ciphertext_hash) and
      DateTime.compare(stage.sealed_at, command.sealed_at) == :eq and
      asset.state == :uploaded and
      asset.state_revision == command.expected_asset_revision + 1
  end

  defp sealed_checkpoint_effects(
         %{checkpoint_mode: :replay, stage: stage, asset: asset},
         _command,
         _correlation_id
       ) do
    Multi.new()
    |> Multi.put(:checkpoint_stage, stage)
    |> Multi.put(:checkpoint_asset, asset)
  end

  defp sealed_checkpoint_effects(
         %{
           checkpoint_mode: :apply,
           stage: stage,
           asset: asset,
           grant: grant,
           authorization_epochs: authorization_epochs
         },
         command,
         correlation_id
       ) do
    stage_changeset =
      AssetStage.seal_changeset(stage, %{
        format_version: command.format_version,
        plaintext_byte_size: command.plaintext_byte_size,
        ciphertext_byte_size: command.ciphertext_byte_size,
        lookup_digest: command.lookup_digest,
        ciphertext_hash: command.ciphertext_hash,
        sealed_at: command.sealed_at
      })

    asset_changeset =
      asset
      |> StoredAsset.transition_changeset(%{
        state: :uploaded,
        state_revision: asset.state_revision
      })
      |> Ecto.Changeset.optimistic_lock(:state_revision)

    metadata =
      AssetMetadata.upsert_changeset(%AssetMetadata{}, %{
        id: Ecto.UUID.generate(),
        asset_id: asset.id,
        resource_version_id: asset.resource_version_id,
        vault_id: asset.vault_id,
        classification: asset.classification,
        projection_version: 1,
        original_filename: grant.filename,
        declared_media_type: grant.declared_media_type,
        plaintext_byte_size: grant.byte_size,
        extraction_state: :pending
      })

    audit =
      audit_changeset(%{
        operation: "asset.uploaded",
        vault_id: asset.vault_id,
        principal_id: grant.principal_id,
        classification: asset.classification,
        correlation_id: correlation_id,
        target_id: asset.id,
        metadata: %{
          "stage_id" => stage.id,
          "state" => "uploaded"
        },
        occurred_at: command.sealed_at
      })

    outbox =
      outbox_changeset(
        %{
          event_type: "asset.verify_requested",
          idempotency_key: "asset-verify:#{asset.id}:#{command.expected_asset_revision + 1}",
          vault_id: asset.vault_id,
          principal_id: grant.principal_id,
          required_capability: "asset.write",
          classification: asset.classification,
          correlation_id: correlation_id,
          causation_id: grant.id,
          expected_entity_revision: command.expected_asset_revision + 1,
          payload: %{"asset_id" => asset.id},
          occurred_at: command.sealed_at
        },
        authorization_epochs
      )

    Multi.new()
    |> Multi.update(:checkpoint_stage, stage_changeset)
    |> Multi.update(:checkpoint_asset, asset_changeset)
    |> Multi.insert(:checkpoint_metadata, metadata)
    |> Multi.insert(:checkpoint_audit, audit)
    |> Multi.insert(:checkpoint_outbox, outbox)
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

  defp validate_grant_stage_command(%{
         grant_id: grant_id,
         token: token,
         session_id: session_id,
         principal_id: principal_id,
         vault_id: vault_id,
         asset_id: asset_id,
         filename: filename,
         byte_size: byte_size,
         declared_media_type: declared_media_type,
         idempotency_key: idempotency_key,
         classification: classification,
         principal_authorization_epoch: principal_authorization_epoch,
         vault_authorization_epoch: vault_authorization_epoch,
         stage_id: stage_id,
         candidate_object_id: candidate_object_id,
         key_domain_id: key_domain_id,
         domain_key_version_id: domain_key_version_id,
         storage_ref: storage_ref,
         wrapper_algorithm: wrapper_algorithm,
         key_generation: key_generation,
         dek_wrapper: dek_wrapper
       }) do
    with :ok <-
           UUID.validate([
             grant_id,
             session_id,
             principal_id,
             vault_id,
             asset_id,
             stage_id,
             candidate_object_id,
             key_domain_id,
             domain_key_version_id
           ]),
         true <- is_binary(token) and byte_size(token) == 32,
         true <- valid_text?(filename),
         true <- is_integer(byte_size) and byte_size >= 0,
         true <- valid_text?(declared_media_type),
         true <- valid_text?(idempotency_key),
         true <- classification in [:private, :sensitive, :restricted],
         true <-
           is_integer(principal_authorization_epoch) and
             principal_authorization_epoch >= 0,
         true <-
           is_integer(vault_authorization_epoch) and
             vault_authorization_epoch >= 0,
         true <- valid_text?(storage_ref),
         true <- valid_text?(wrapper_algorithm),
         true <- is_integer(key_generation) and key_generation > 0,
         true <- is_binary(dek_wrapper) and byte_size(dek_wrapper) > 0 do
      :ok
    else
      {:error, %Error{}} = error -> error
      _invalid -> {:error, Error.new(:invalid)}
    end
  end

  defp validate_grant_stage_command(_command),
    do: {:error, Error.new(:invalid)}

  defp lock_eligible_grant(repo, grant_id, principal_id) do
    eligible =
      from grant in UploadGrant,
        where:
          grant.id == ^grant_id and
            grant.principal_id == ^principal_id and
            grant.principal_id ==
              fragment("NULLIF(current_setting('singularity.principal_id', true), '')::uuid") and
            is_nil(grant.consumed_at) and
            grant.expires_at > fragment("statement_timestamp()"),
        lock: "FOR UPDATE"

    case repo.one(eligible) do
      %UploadGrant{} = grant -> {:ok, grant}
      nil -> {:error, Error.new(:conflict)}
    end
  end

  defp validate_grant_stage_binding(
         grant,
         command,
         token_digest,
         authorization_epochs
       ) do
    exact_binding? =
      digest_matches?(grant.token_digest, token_digest) and
        grant.id == command.grant_id and
        grant.session_id == command.session_id and
        grant.principal_id == command.principal_id and
        grant.vault_id == command.vault_id and
        grant.asset_id == command.asset_id and
        grant.filename == command.filename and
        grant.byte_size == command.byte_size and
        grant.declared_media_type == command.declared_media_type and
        grant.idempotency_key == command.idempotency_key and
        grant.classification == command.classification and
        grant.principal_authorization_epoch ==
          command.principal_authorization_epoch and
        grant.vault_authorization_epoch ==
          command.vault_authorization_epoch and
        grant.principal_authorization_epoch ==
          authorization_epochs.principal_authorization_epoch and
        grant.vault_authorization_epoch ==
          authorization_epochs.vault_authorization_epoch

    if exact_binding?,
      do: {:ok, :exact},
      else: {:error, Error.new(:conflict)}
  end

  defp consume_locked_grant(repo, grant_id) do
    eligible =
      from grant in UploadGrant,
        where:
          grant.id == ^grant_id and
            is_nil(grant.consumed_at) and
            grant.expires_at > fragment("statement_timestamp()"),
        update: [set: [consumed_at: fragment("statement_timestamp()")]]

    case repo.update_all(eligible, []) do
      {1, _rows} ->
        {:ok, :consumed}

      {0, _rows} ->
        {:error, Error.new(:conflict)}

      {_unexpected_count, _rows} ->
        {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  defp stage_attrs(command) do
    command
    |> Map.take([
      :asset_id,
      :vault_id,
      :key_domain_id,
      :candidate_object_id,
      :domain_key_version_id,
      :classification,
      :storage_ref,
      :wrapper_algorithm,
      :key_generation,
      :dek_wrapper
    ])
    |> Map.put(:id, command.stage_id)
    |> Map.put(:upload_grant_id, command.grant_id)
    |> Map.put(:state_revision, 0)
  end

  defp digest_matches?(
         <<_::binary-size(32)>> = expected,
         <<_::binary-size(32)>> = candidate
       ),
       do: :crypto.hash_equals(expected, candidate)

  defp digest_matches?(_expected, _candidate), do: false

  defp valid_text?(value) when is_binary(value) do
    String.valid?(value) and
      not String.contains?(value, <<0>>) and
      String.trim(value) != ""
  end

  defp valid_text?(_value), do: false

  defp validate_upload_grant_command(
         %{
           grant_id: grant_id,
           asset_id: asset_id,
           source_reference_id: source_reference_id,
           session_id: session_id,
           principal_id: principal_id,
           vault_id: vault_id,
           resource_version_id: resource_version_id,
           filename: filename,
           byte_size: byte_size,
           declared_media_type: declared_media_type,
           idempotency_key: idempotency_key,
           classification: classification,
           token_digest: token_digest,
           expires_at: expires_at,
           observed_at: observed_at
         } = command
       ) do
    with :ok <-
           UUID.validate([
             grant_id,
             asset_id,
             source_reference_id,
             session_id,
             principal_id,
             vault_id,
             resource_version_id
           ]),
         true <- valid_text?(filename),
         true <-
           is_integer(byte_size) and byte_size >= 0 and
             byte_size <= @max_bigint,
         true <- valid_text?(declared_media_type),
         true <- valid_text?(idempotency_key),
         true <- classification in [:private, :sensitive, :restricted],
         true <- is_binary(token_digest) and byte_size(token_digest) == 32,
         {:ok, ^expires_at} <- Types.utc_datetime(command, :expires_at),
         {:ok, ^observed_at} <- Types.utc_datetime(command, :observed_at),
         :gt <- DateTime.compare(expires_at, observed_at) do
      :ok
    else
      {:error, %Error{}} = error -> error
      _invalid -> {:error, Error.new(:invalid)}
    end
  end

  defp validate_upload_grant_command(_command),
    do: {:error, Error.new(:invalid)}

  defp lock_upload_grant_idempotency(repo, command) do
    lock_key = command.vault_id <> ":" <> command.idempotency_key

    case Ecto.Adapters.SQL.query(
           repo,
           "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
           [lock_key],
           log: false
         ) do
      {:ok, %{rows: [[:void]]}} ->
        {:ok, :locked}

      {:ok, _unexpected_result} ->
        {:error, Error.new(:storage_unavailable, retryable?: true)}

      {:error, _reason} ->
        {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  defp lock_existing_upload_grant(repo, command) do
    query =
      from grant in UploadGrant,
        where:
          grant.vault_id == ^command.vault_id and
            grant.idempotency_key == ^command.idempotency_key,
        order_by: [desc: grant.inserted_at, desc: grant.id],
        limit: 1,
        lock: "FOR UPDATE"

    {:ok, repo.one(query)}
  end

  defp new_upload_grant_multi(command) do
    Multi.new()
    |> Multi.run(:resource_classification, fn repo, _changes ->
      lock_resource_version_classification(repo, command)
    end)
    |> Multi.run(:classification, fn _repo, %{resource_classification: canonical} ->
      validate_upload_grant_classification(canonical, command.classification)
    end)
    |> Multi.run(:authorization_epochs, fn repo, _changes ->
      authorization_epochs(repo, command.principal_id, command.vault_id)
    end)
    |> Multi.run(:valid_expiry, fn repo, _changes ->
      validate_server_expiry(repo, command.expires_at)
    end)
    |> Multi.insert(
      :asset,
      StoredAsset.create_changeset(%StoredAsset{}, %{
        id: command.asset_id,
        vault_id: command.vault_id,
        resource_version_id: command.resource_version_id,
        classification: command.classification,
        state: :staging,
        state_revision: 0,
        attempt: 0
      })
    )
    |> Multi.insert(
      :source,
      SourceReference.create_changeset(%SourceReference{}, %{
        id: command.source_reference_id,
        vault_id: command.vault_id,
        resource_version_id: command.resource_version_id,
        principal_id: command.principal_id,
        classification: command.classification,
        kind: :browser_upload,
        observed_at: command.observed_at,
        original_filename: command.filename,
        declared_media_type: command.declared_media_type,
        byte_size: command.byte_size,
        idempotency_key_digest: :crypto.hash(:sha256, command.idempotency_key)
      })
    )
    |> Multi.insert(
      :resource_asset,
      ResourceAsset.create_changeset(%ResourceAsset{}, %{
        resource_version_id: command.resource_version_id,
        asset_id: command.asset_id,
        vault_id: command.vault_id,
        classification: command.classification
      })
    )
    |> Multi.insert(:grant, fn %{authorization_epochs: authorization_epochs} ->
      UploadGrant.create_changeset(
        %UploadGrant{},
        upload_grant_attrs(command, authorization_epochs)
      )
    end)
  end

  defp replay_upload_grant_multi(grant, command) do
    Multi.new()
    |> Multi.run(:replay_asset, fn repo, _changes ->
      validate_upload_grant_replay(repo, grant, command)
    end)
    |> Multi.run(:resource_classification, fn repo, _changes ->
      lock_resource_version_classification(repo, command)
    end)
    |> Multi.run(:classification, fn _repo, %{resource_classification: canonical} ->
      validate_upload_grant_classification(canonical, command.classification)
    end)
    |> Multi.run(:authorization_epochs, fn repo, _changes ->
      authorization_epochs(repo, command.principal_id, command.vault_id)
    end)
    |> Multi.run(:valid_expiry, fn repo, _changes ->
      validate_server_expiry(repo, command.expires_at)
    end)
    |> Multi.run(:source, fn repo, _changes ->
      fetch_upload_grant_source(repo, grant, command)
    end)
    |> Multi.run(:resource_asset, fn repo, _changes ->
      validate_upload_grant_resource_asset(repo, grant, command)
    end)
    |> Multi.run(:grant, fn repo,
                            %{
                              authorization_epochs: authorization_epochs,
                              replay_asset: replay
                            } ->
      replay_upload_grant(repo, grant, command, authorization_epochs, replay)
    end)
  end

  defp validate_upload_grant_classification(canonical, requested) do
    case Classification.assert_not_downgraded(canonical, requested) do
      :ok -> {:ok, requested}
      {:error, %Error{}} = error -> error
    end
  end

  defp validate_server_expiry(repo, expires_at) do
    case Ecto.Adapters.SQL.query(
           repo,
           "SELECT $1::timestamptz > statement_timestamp()",
           [expires_at],
           log: false
         ) do
      {:ok, %{rows: [[true]]}} ->
        {:ok, expires_at}

      {:ok, %{rows: [[false]]}} ->
        {:error, Error.new(:invalid)}

      {:ok, _unexpected_result} ->
        {:error, Error.new(:storage_unavailable, retryable?: true)}

      {:error, _reason} ->
        {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  defp validate_upload_grant_replay(repo, grant, command) do
    exact_grant? =
      grant.session_id == command.session_id and
        grant.principal_id == command.principal_id and
        grant.vault_id == command.vault_id and
        grant.filename == command.filename and
        grant.byte_size == command.byte_size and
        grant.declared_media_type == command.declared_media_type and
        grant.idempotency_key == command.idempotency_key and
        grant.classification == command.classification

    if exact_grant? do
      query =
        from asset in StoredAsset,
          where:
            asset.id == ^grant.asset_id and
              asset.vault_id == ^command.vault_id,
          lock: "FOR SHARE"

      case repo.one(query) do
        %StoredAsset{
          resource_version_id: resource_version_id,
          classification: classification,
          state: :staging,
          state_revision: 0
        } = asset
        when resource_version_id == command.resource_version_id and
               classification == command.classification ->
          upload_grant_replay_mode(repo, grant, command, asset)

        %StoredAsset{} ->
          {:error, Error.new(:conflict)}

        nil ->
          {:error, Error.new(:conflict)}
      end
    else
      {:error, Error.new(:conflict)}
    end
  end

  defp upload_grant_replay_mode(_repo, %UploadGrant{consumed_at: nil}, _command, _asset),
    do: {:error, Error.new(:conflict)}

  defp upload_grant_replay_mode(repo, grant, command, asset) do
    abandoned_attempt =
      from stage in AssetStage,
        where:
          stage.upload_grant_id == ^grant.id and
            stage.asset_id == ^grant.asset_id and
            stage.vault_id == ^grant.vault_id and
            stage.state == :abandoned

    conflicting_attempt =
      from other in UploadGrant,
        left_join: stage in AssetStage,
        on:
          stage.upload_grant_id == other.id and
            stage.vault_id == other.vault_id,
        where:
          other.id != ^grant.id and
            other.vault_id == ^command.vault_id and
            other.idempotency_key == ^command.idempotency_key and
            (is_nil(other.consumed_at) or stage.state in [:open, :sealed])

    if repo.exists?(abandoned_attempt) and not repo.exists?(conflicting_attempt) do
      {:ok, %{asset: asset, mode: :replace}}
    else
      {:error, Error.new(:conflict)}
    end
  end

  defp fetch_upload_grant_source(repo, grant, command) do
    idempotency_digest = :crypto.hash(:sha256, command.idempotency_key)

    query =
      from source in SourceReference,
        where:
          source.id == ^grant.source_reference_id and
            source.vault_id == ^command.vault_id and
            source.resource_version_id == ^command.resource_version_id and
            source.principal_id == ^command.principal_id and
            source.classification == ^command.classification and
            source.kind == :browser_upload and
            source.original_filename == ^command.filename and
            source.declared_media_type == ^command.declared_media_type and
            source.byte_size == ^command.byte_size and
            source.idempotency_key_digest == ^idempotency_digest

    case repo.one(query) do
      %SourceReference{} = source -> {:ok, source}
      nil -> {:error, Error.new(:conflict)}
    end
  end

  defp validate_upload_grant_resource_asset(repo, grant, command) do
    query =
      from reference in ResourceAsset,
        where:
          reference.resource_version_id == ^command.resource_version_id and
            reference.asset_id == ^grant.asset_id and
            reference.vault_id == ^command.vault_id and
            reference.classification == ^command.classification and
            is_nil(reference.released_at)

    if repo.exists?(query),
      do: {:ok, :linked},
      else: {:error, Error.new(:conflict)}
  end

  defp replay_upload_grant(
         repo,
         grant,
         command,
         authorization_epochs,
         %{mode: :replace}
       ) do
    if command.grant_id == grant.id do
      {:error, Error.new(:conflict)}
    else
      attrs =
        command
        |> upload_grant_attrs(authorization_epochs)
        |> Map.merge(%{
          asset_id: grant.asset_id,
          source_reference_id: grant.source_reference_id
        })

      repo.insert(UploadGrant.create_changeset(%UploadGrant{}, attrs))
    end
  end

  defp upload_grant_attrs(command, authorization_epochs) do
    command
    |> Map.take([
      :grant_id,
      :vault_id,
      :session_id,
      :principal_id,
      :asset_id,
      :source_reference_id,
      :classification,
      :token_digest,
      :filename,
      :byte_size,
      :declared_media_type,
      :idempotency_key,
      :expires_at
    ])
    |> Map.put(:id, command.grant_id)
    |> Map.delete(:grant_id)
    |> Map.merge(authorization_epochs)
  end

  defp upload_grant_result(grant, source, command) do
    grant
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> Map.merge(%{
      source_reference_id: source.id,
      resource_version_id: command.resource_version_id
    })
  end

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

  defp authorization_epochs(repo, principal_id, vault_id) do
    with {:ok, dumped_principal_id} <- UUID.dump(principal_id),
         {:ok, dumped_vault_id} <- UUID.dump(vault_id) do
      case Ecto.Adapters.SQL.query(
             repo,
             """
             SELECT
               principal_authorization_epoch,
               vault_authorization_epoch
             FROM core.live_principal_authorization()
             WHERE principal_id = $1 AND vault_id = $2
             """,
             [dumped_principal_id, dumped_vault_id],
             log: false
           ) do
        {:ok, %{rows: [[principal_epoch, vault_epoch]]}}
        when is_integer(principal_epoch) and principal_epoch >= 0 and
               is_integer(vault_epoch) and vault_epoch >= 0 ->
          {:ok,
           %{
             principal_authorization_epoch: principal_epoch,
             vault_authorization_epoch: vault_epoch
           }}

        {:ok, %{rows: []}} ->
          {:error, Error.new(:forbidden)}

        {:ok, _unexpected_result} ->
          {:error, Error.new(:storage_unavailable, retryable?: true)}

        {:error, _reason} ->
          {:error, Error.new(:storage_unavailable, retryable?: true)}
      end
    else
      :error -> {:error, Error.new(:invalid)}
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
