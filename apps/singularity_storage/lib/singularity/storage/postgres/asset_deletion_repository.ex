defmodule Singularity.Storage.Postgres.AssetDeletionRepository do
  @moduledoc """
  Persists logical asset deletion and independently restartable object cleanup.
  """

  import Ecto.Query

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope
  alias Singularity.Core.ObjectRef
  alias Singularity.Storage.Jobs.Progress
  alias Singularity.Storage.Postgres.UUID
  alias Singularity.Storage.Schema.Audit.Event, as: AuditEvent
  alias Singularity.Storage.Schema.Content.Asset
  alias Singularity.Storage.Schema.Content.AssetObject
  alias Singularity.Storage.Schema.Content.AssetSearchDocument
  alias Singularity.Storage.Schema.Content.AssetStage
  alias Singularity.Storage.Schema.Content.ResourceAsset
  alias Singularity.Storage.Schema.Content.Tombstone
  alias Singularity.Storage.Schema.Core.OutboxEvent
  alias Singularity.Storage.Schema.Jobs.EffectReceipt

  @deletable_states ~w[staging uploaded verified available processing ready]a

  @spec load_delete_target(module(), map()) ::
          {:ok, Asset.t()} | {:error, Error.t()}
  def load_delete_target(repo, %{asset_id: asset_id, vault_id: vault_id}) do
    with :ok <- UUID.validate([asset_id, vault_id]) do
      case repo.one(
             from asset in Asset,
               where: asset.id == ^asset_id and asset.vault_id == ^vault_id,
               where:
                 fragment(
                   "core.current_principal_can_discover_classification(?)",
                   asset.classification
                 )
           ) do
        %Asset{} = asset -> {:ok, asset}
        nil -> {:error, Error.new(:not_found)}
      end
    end
  rescue
    _error in [Ecto.Query.CastError] -> {:error, Error.new(:invalid)}
  end

  def load_delete_target(_repo, _command),
    do: {:error, Error.new(:invalid)}

  @doc """
  Resolves the advisory-lock target without taking any row lock.

  Callers acquire this object lock before entering the row-locked tombstone
  transition and re-run this read after waiting for the lock.
  """
  @spec resolve_delete_lock_target(module(), map()) ::
          {:ok, %{object_id: String.t() | nil}} | {:error, Error.t()}
  def resolve_delete_lock_target(
        repo,
        %{asset_id: asset_id, vault_id: vault_id}
      ) do
    with :ok <- UUID.validate([asset_id, vault_id]) do
      case repo.one(
             from asset in Asset,
               where: asset.id == ^asset_id and asset.vault_id == ^vault_id
           ) do
        %Asset{} = asset ->
          {:ok, %{object_id: delete_lock_object_id(repo, asset)}}

        nil ->
          {:error, Error.new(:not_found)}
      end
    end
  rescue
    _error in [Ecto.Query.CastError] -> {:error, Error.new(:invalid)}
  end

  def resolve_delete_lock_target(_repo, _command),
    do: {:error, Error.new(:invalid)}

  @spec tombstone_and_release(module(), map()) ::
          {:ok, Asset.t()} | {:error, Error.t()}
  def tombstone_and_release(repo, command) when is_map(command) do
    with :ok <- validate_delete_command(command) do
      transact(repo, fn ->
        with {:ok, asset} <- lock_asset(repo, command.asset_id, command.vault_id),
             :ok <- bind_delete_target(asset, command),
             :ok <- reject_open_upload(repo, asset),
             :ok <- bind_delete_lock_target(repo, asset, command) do
          apply_or_replay_tombstone(repo, asset, command)
        end
      end)
    end
  rescue
    _error in [Ecto.Query.CastError] -> {:error, Error.new(:invalid)}
    _error in [Ecto.StaleEntryError] -> {:error, Error.new(:conflict)}
  end

  def tombstone_and_release(_repo, _command),
    do: {:error, Error.new(:invalid)}

  @spec complete_logical_delete(module(), JobEnvelope.t()) ::
          {:ok, Asset.t()} | {:error, Error.t()}
  def complete_logical_delete(
        repo,
        %JobEnvelope{
          job_type: "asset_cleanup",
          required_capability: "asset.write"
        } = envelope
      ) do
    with :ok <- validate_asset_cleanup_envelope(envelope) do
      transact(repo, fn ->
        with {:ok, receipt} <- lock_effect_receipt(repo, envelope) do
          complete_or_replay_logical_delete(repo, envelope, receipt)
        end
      end)
    end
  rescue
    _error in [Ecto.Query.CastError] -> {:error, Error.new(:invalid)}
    _error in [Ecto.StaleEntryError] -> {:error, Error.new(:conflict)}
  end

  def complete_logical_delete(_repo, _envelope),
    do: {:error, Error.new(:invalid)}

  @spec claim_orphan_delete(module(), JobEnvelope.t()) ::
          {:ok, map() | :retained} | {:error, Error.t()}
  def claim_orphan_delete(
        repo,
        %JobEnvelope{
          job_type: "object_cleanup",
          required_capability: "object.cleanup"
        } = envelope
      ) do
    with :ok <- validate_object_cleanup_envelope(envelope) do
      transact(repo, fn ->
        with {:ok, receipt} <- lock_effect_receipt(repo, envelope),
             :ok <- bind_current_scope(repo, envelope),
             {:ok, cleanup} <- cleanup_authorization(repo, envelope.vault_id),
             :ok <- bind_cleanup_authority(cleanup, envelope) do
          claim_or_replay_object_delete(repo, envelope, receipt)
        end
      end)
    end
  rescue
    _error in [Ecto.Query.CastError] -> {:error, Error.new(:invalid)}
    _error in [Ecto.StaleEntryError] -> {:error, Error.new(:conflict)}
  end

  def claim_orphan_delete(_repo, _envelope),
    do: {:error, Error.new(:invalid)}

  @doc """
  Records a terminal cleanup failure and emits one successor envelope.

  This path is invoked only after a terminal retryable failure or a terminal
  stale-authority failure. It does not acknowledge a prior claim or touch
  storage bytes.
  """
  @spec reschedule_orphan_delete(module(), JobEnvelope.t(), Error.t()) ::
          {:ok, JobEnvelope.t() | :retained} | {:error, Error.t()}
  def reschedule_orphan_delete(
        repo,
        %JobEnvelope{
          job_type: "object_cleanup",
          required_capability: "object.cleanup"
        } = stale,
        %Error{} = failure
      ) do
    with :ok <- validate_object_cleanup_envelope(stale),
         :ok <- validate_terminal_cleanup_failure(failure) do
      transact(repo, fn ->
        with :ok <- bind_current_scope(repo, stale),
             {:ok, cleanup} <- cleanup_authorization(repo, stale.vault_id),
             :ok <- bind_rescheduler_principal(cleanup, stale),
             {:ok, prior} <- cleanup_submission(repo, stale.job_id),
             :ok <- bind_cleanup_submission(prior, stale),
             {:ok, object} <- lock_cleanup_object(repo, stale),
             {:ok, receipt} <- lock_effect_receipt(repo, stale),
             :ok <-
               record_or_replay_terminal_cleanup_failure(
                 repo,
                 stale,
                 failure,
                 object,
                 receipt
               ) do
          reschedule_or_retain(repo, stale, cleanup, object)
        end
      end)
    end
  rescue
    _error in [Ecto.Query.CastError] -> {:error, Error.new(:invalid)}
    _error in [Ecto.StaleEntryError] -> {:error, Error.new(:conflict)}
  end

  def reschedule_orphan_delete(_repo, _envelope, _failure),
    do: {:error, Error.new(:invalid)}

  @spec acknowledge_object_deleted(module(), map()) ::
          {:ok, AssetObject.t()} | {:error, Error.t()}
  def acknowledge_object_deleted(
        repo,
        %{
          envelope: %JobEnvelope{} = envelope,
          object_ref: %ObjectRef{object_id: object_id},
          claim_token: claim_token,
          expected_lifecycle_revision: expected_lifecycle_revision
        } = deletion
      ) do
    with :ok <- validate_object_cleanup_envelope(envelope),
         :ok <-
           validate_deletion_receipt(
             envelope,
             object_id,
             claim_token,
             expected_lifecycle_revision
           ) do
      transact(repo, fn ->
        with {:ok, receipt} <- lock_effect_receipt(repo, envelope),
             :ok <- bind_current_scope(repo, envelope),
             {:ok, cleanup} <- cleanup_authorization(repo, envelope.vault_id),
             :ok <- bind_cleanup_authority(cleanup, envelope) do
          acknowledge_or_replay_object_delete(
            repo,
            envelope,
            deletion,
            receipt
          )
        end
      end)
    end
  rescue
    _error in [Ecto.Query.CastError] -> {:error, Error.new(:invalid)}
    _error in [Ecto.StaleEntryError] -> {:error, Error.new(:conflict)}
  end

  def acknowledge_object_deleted(_repo, _deletion),
    do: {:error, Error.new(:invalid)}

  defp claim_or_replay_object_delete(
         repo,
         envelope,
         %EffectReceipt{} = receipt
       ) do
    with {:ok, object} <- lock_cleanup_object(repo, envelope),
         true <- receipt.submission_id == envelope.job_id,
         true <- receipt.classification == envelope.classification,
         true <- receipt.result in [:applied, :stale],
         true <- receipt.entity_revision <= object.lifecycle_revision do
      if object.lifecycle == :deleted do
        {:ok, %{status: :complete, object: object}}
      else
        {:ok, :retained}
      end
    else
      false -> {:error, Error.new(:conflict)}
      {:error, %Error{}} = error -> error
    end
  end

  defp claim_or_replay_object_delete(repo, envelope, nil) do
    with {:ok, object} <- lock_cleanup_object(repo, envelope) do
      references = live_object_references(repo, object)

      cond do
        references > 0 ->
          retain_referenced_object(repo, envelope, object)

        object.lifecycle == :deleting and
            object.delete_claim_token == envelope.job_id ->
          deletion_receipt(repo, envelope, object)

        object.lifecycle == :orphan_pending and
            object.lifecycle_revision == envelope.expected_entity_revision ->
          claim_orphan(repo, envelope, object)

        object.lifecycle == :deleting ->
          take_over_delete_claim(repo, envelope, object)

        object.lifecycle == :deleted and
            get_in(object.deletion_evidence || %{}, ["claim_token"]) ==
              envelope.job_id ->
          {:ok, %{status: :complete, object: object}}

        true ->
          record_stale_object_cleanup(repo, envelope, object)
      end
    end
  end

  defp claim_orphan(repo, envelope, object) do
    now = DateTime.utc_now(:microsecond)

    case object.retained_until do
      %DateTime{} = retained_until ->
        if DateTime.compare(retained_until, now) == :gt do
          {:error, Error.new(:conflict, retryable?: true)}
        else
          persist_orphan_claim(repo, envelope, object, now)
        end

      _missing_retention ->
        {:error, Error.new(:conflict)}
    end
  end

  defp persist_orphan_claim(repo, envelope, object, now) do
    next_revision = object.lifecycle_revision + 1

    with {:ok, deleting} <-
           object
           |> AssetObject.lifecycle_changeset(%{
             lifecycle: :deleting,
             lifecycle_revision: next_revision,
             delete_claim_token: envelope.job_id,
             delete_claimed_at: now
           })
           |> repo.update(),
         {:ok, _audit} <-
           repo.insert(
             audit_changeset(%{
               actor_kind: :system,
               principal_id: envelope.principal_id,
               operation: "object.delete_claimed",
               vault_id: envelope.vault_id,
               classification: envelope.classification,
               correlation_id: envelope.correlation_id,
               target_type: "asset_object",
               target_id: object.id,
               metadata: %{
                 "claim_token" => envelope.job_id,
                 "lifecycle" => "deleting"
               },
               occurred_at: now
             })
           ) do
      deletion_receipt(repo, envelope, deleting)
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset_error(changeset)}
    end
  end

  defp take_over_delete_claim(repo, envelope, object) do
    prior_claim_token = object.delete_claim_token

    with true <-
           object.lifecycle_revision ==
             envelope.expected_entity_revision,
         {:ok, prior} <-
           cleanup_submission(repo, prior_claim_token),
         :ok <-
           bind_prior_cleanup_submission(
             prior,
             envelope,
             object
           ),
         :ok <- bind_prior_cleanup_failure(repo, prior, object),
         {:ok, claimed} <-
           persist_claim_takeover(
             repo,
             envelope,
             object,
             prior_claim_token
           ) do
      deletion_receipt(repo, envelope, claimed)
    else
      false -> {:error, Error.new(:conflict)}
      {:error, %Error{}} = error -> error
    end
  end

  defp bind_prior_cleanup_failure(repo, prior, object) do
    case repo.one(
           from receipt in EffectReceipt,
             where:
               receipt.vault_id == ^object.vault_id and
                 receipt.submission_id == ^prior.id and
                 receipt.effect_key == ^prior.idempotency_key,
             lock: "FOR UPDATE"
         ) do
      %EffectReceipt{
        classification: classification,
        result: :failed,
        entity_revision: entity_revision
      }
      when classification == object.classification and
             entity_revision == object.lifecycle_revision ->
        :ok

      _missing_or_mismatched ->
        {:error, Error.new(:conflict)}
    end
  end

  defp cleanup_submission(repo, job_id) do
    case repo.one(
           from event in OutboxEvent,
             where: event.id == ^job_id
         ) do
      %OutboxEvent{} = event -> {:ok, event}
      nil -> {:error, Error.new(:conflict)}
    end
  end

  defp bind_prior_cleanup_submission(prior, envelope, object) do
    exact? =
      prior.id == object.delete_claim_token and
        prior.event_type == "object.cleanup_requested" and
        prior.vault_id == envelope.vault_id and
        prior.principal_id == envelope.principal_id and
        prior.required_capability == "object.cleanup" and
        prior.classification == envelope.classification and
        prior.payload == envelope.payload and
        prior.expected_entity_revision <
          envelope.expected_entity_revision and
        envelope.causation_id == prior.id

    if exact?, do: :ok, else: {:error, Error.new(:conflict)}
  end

  defp bind_cleanup_submission(submission, envelope) do
    exact? =
      submission.id == envelope.job_id and
        submission.event_type == "object.cleanup_requested" and
        submission.idempotency_key == envelope.idempotency_key and
        submission.vault_id == envelope.vault_id and
        submission.principal_id == envelope.principal_id and
        submission.required_capability ==
          envelope.required_capability and
        submission.principal_authorization_epoch ==
          envelope.principal_authorization_epoch and
        submission.vault_authorization_epoch ==
          envelope.vault_authorization_epoch and
        submission.classification == envelope.classification and
        submission.correlation_id == envelope.correlation_id and
        submission.causation_id == envelope.causation_id and
        submission.expected_entity_revision ==
          envelope.expected_entity_revision and
        submission.envelope_version == envelope.version and
        submission.payload == envelope.payload

    if exact?, do: :ok, else: {:error, Error.new(:conflict)}
  end

  defp bind_rescheduler_principal(cleanup, stale) do
    if cleanup.principal_id == stale.principal_id do
      :ok
    else
      {:error, Error.new(:forbidden)}
    end
  end

  defp validate_terminal_cleanup_failure(%Error{retryable?: true}),
    do: :ok

  defp validate_terminal_cleanup_failure(%Error{code: :forbidden, retryable?: false}),
    do: :ok

  defp validate_terminal_cleanup_failure(_failure),
    do: {:error, Error.new(:invalid)}

  defp record_or_replay_terminal_cleanup_failure(
         _repo,
         stale,
         _failure,
         object,
         %EffectReceipt{} = receipt
       ) do
    exact? =
      receipt.vault_id == stale.vault_id and
        receipt.submission_id == stale.job_id and
        receipt.classification == stale.classification and
        receipt.effect_key == stale.idempotency_key and
        receipt.result == :failed and
        receipt.entity_revision == object.lifecycle_revision

    if exact?, do: :ok, else: {:error, Error.new(:conflict)}
  end

  defp record_or_replay_terminal_cleanup_failure(
         repo,
         stale,
         failure,
         object,
         nil
       ) do
    now = DateTime.utc_now(:microsecond)

    with {:ok, _audit} <-
           repo.insert(
             audit_changeset(%{
               actor_kind: :system,
               principal_id: stale.principal_id,
               operation: "object.delete_failed",
               result: :failed,
               vault_id: stale.vault_id,
               classification: stale.classification,
               correlation_id: stale.correlation_id,
               target_type: "asset_object",
               target_id: object.id,
               metadata: %{
                 "failure_code" => Atom.to_string(failure.code),
                 "job_id" => stale.job_id,
                 "operation" => stale.job_type,
                 "retryable" => failure.retryable?
               },
               occurred_at: now
             })
           ),
         {:ok, _receipt} <-
           Progress.record_effect(repo, stale, %{
             effect_key: stale.idempotency_key,
             result: :failed,
             entity_revision: object.lifecycle_revision
           }) do
      :ok
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset_error(changeset)}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp reschedule_or_retain(repo, stale, cleanup, object) do
    references = live_object_references(repo, object)

    cond do
      references > 0 ->
        {:ok, :retained}

      reschedulable_orphan?(object, stale) ->
        emit_current_cleanup(repo, stale, cleanup, object)

      object.lifecycle == :deleted ->
        {:ok, :retained}

      true ->
        {:error, Error.new(:conflict)}
    end
  end

  defp reschedulable_orphan?(
         %AssetObject{
           lifecycle: :orphan_pending,
           lifecycle_revision: revision,
           delete_claim_token: nil
         },
         envelope
       ),
       do: revision == envelope.expected_entity_revision

  defp reschedulable_orphan?(
         %AssetObject{
           lifecycle: :deleting,
           lifecycle_revision: revision,
           delete_claim_token: claim_token
         },
         envelope
       ),
       do:
         claim_token == envelope.job_id and
           revision > envelope.expected_entity_revision

  defp reschedulable_orphan?(_object, _envelope), do: false

  defp emit_current_cleanup(repo, stale, cleanup, object) do
    key =
      [
        "object-cleanup",
        object.id,
        "authority",
        cleanup.principal_authorization_epoch,
        cleanup.vault_authorization_epoch,
        "revision",
        object.lifecycle_revision
      ]
      |> Enum.join(":")

    attrs = %{
      event_type: "object.cleanup_requested",
      idempotency_key: key,
      vault_id: object.vault_id,
      principal_id: cleanup.principal_id,
      required_capability: "object.cleanup",
      classification: object.classification,
      correlation_id: stale.correlation_id,
      causation_id: stale.job_id,
      expected_entity_revision: object.lifecycle_revision,
      payload: stale.payload,
      occurred_at: DateTime.utc_now(:microsecond)
    }

    with {:ok, event} <-
           insert_or_load_cleanup_event(
             repo,
             attrs,
             cleanup
           ) do
      cleanup_envelope(event)
    end
  end

  defp insert_or_load_cleanup_event(repo, attrs, cleanup) do
    case repo.one(
           from event in OutboxEvent,
             where:
               event.vault_id == ^attrs.vault_id and
                 event.idempotency_key == ^attrs.idempotency_key
         ) do
      %OutboxEvent{} = event ->
        {:ok, event}

      nil ->
        attrs
        |> outbox_changeset(cleanup)
        |> repo.insert()
    end
  end

  defp cleanup_envelope(event) do
    JobEnvelope.new(%{
      version: event.envelope_version,
      job_id: event.id,
      job_type: "object_cleanup",
      idempotency_key: event.idempotency_key,
      vault_id: event.vault_id,
      principal_id: event.principal_id,
      required_capability: event.required_capability,
      principal_authorization_epoch: event.principal_authorization_epoch,
      vault_authorization_epoch: event.vault_authorization_epoch,
      classification: event.classification,
      correlation_id: event.correlation_id,
      causation_id: event.causation_id,
      expected_entity_revision: event.expected_entity_revision,
      attempt: 0,
      payload: event.payload
    })
  end

  defp persist_claim_takeover(
         repo,
         envelope,
         object,
         prior_claim_token
       ) do
    now = DateTime.utc_now(:microsecond)
    next_revision = object.lifecycle_revision + 1

    with {:ok, claimed} <-
           object
           |> AssetObject.lifecycle_changeset(%{
             lifecycle: :deleting,
             lifecycle_revision: next_revision,
             delete_claim_token: envelope.job_id,
             delete_claimed_at: now
           })
           |> repo.update(),
         {:ok, _audit} <-
           repo.insert(
             audit_changeset(%{
               actor_kind: :system,
               principal_id: envelope.principal_id,
               operation: "object.delete_claimed",
               vault_id: envelope.vault_id,
               classification: envelope.classification,
               correlation_id: envelope.correlation_id,
               target_type: "asset_object",
               target_id: object.id,
               metadata: %{
                 "claim_token" => envelope.job_id,
                 "lifecycle" => "deleting",
                 "prior_claim_token" => prior_claim_token
               },
               occurred_at: now
             })
           ) do
      {:ok, claimed}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset_error(changeset)}
    end
  end

  defp deletion_receipt(repo, envelope, object) do
    deletion = %{
      object_ref: %ObjectRef{object_id: object.id},
      object_id: object.id,
      vault_id: object.vault_id,
      key_domain_id: object.key_domain_id,
      classification: object.classification,
      lookup_digest: object.lookup_digest,
      ciphertext_hash: object.ciphertext_hash,
      claim_token: envelope.job_id,
      expected_lifecycle_revision: object.lifecycle_revision
    }

    {:ok, maybe_add_prior_claim(repo, deletion, envelope, object)}
  end

  defp maybe_add_prior_claim(repo, deletion, envelope, object) do
    repo.all(
      from event in AuditEvent,
        where:
          event.target_id == ^object.id and
            event.operation == "object.delete_claimed",
        order_by: [desc: event.occurred_at],
        select: event.metadata
    )
    |> Enum.find_value(deletion, fn
      %{
        "claim_token" => claim_token,
        "prior_claim_token" => prior_claim_token
      }
      when claim_token == envelope.job_id ->
        Map.put(deletion, :prior_claim_token, prior_claim_token)

      _metadata ->
        nil
    end)
  end

  defp retain_referenced_object(repo, envelope, object) do
    with {:ok, retained} <- restore_available_object(repo, object),
         {:ok, _receipt} <-
           Progress.record_effect(repo, envelope, %{
             effect_key: envelope.idempotency_key,
             result: :stale,
             entity_revision: retained.lifecycle_revision
           }) do
      {:ok, :retained}
    end
  end

  defp restore_available_object(_repo, %AssetObject{lifecycle: :available} = object),
    do: {:ok, object}

  defp restore_available_object(repo, object)
       when object.lifecycle in [:orphan_pending, :deleting] do
    object
    |> AssetObject.lifecycle_changeset(%{
      lifecycle: :available,
      lifecycle_revision: object.lifecycle_revision + 1,
      retained_until: nil,
      delete_claim_token: nil,
      delete_claimed_at: nil
    })
    |> repo.update()
  end

  defp restore_available_object(_repo, _object),
    do: {:error, Error.new(:conflict)}

  defp record_stale_object_cleanup(repo, envelope, object) do
    with {:ok, _receipt} <-
           Progress.record_effect(repo, envelope, %{
             effect_key: envelope.idempotency_key,
             result: :stale,
             entity_revision: object.lifecycle_revision
           }) do
      {:ok, :retained}
    end
  end

  defp acknowledge_or_replay_object_delete(
         repo,
         envelope,
         _deletion,
         %EffectReceipt{} = receipt
       ) do
    with {:ok, object} <- lock_cleanup_object(repo, envelope),
         true <- receipt.submission_id == envelope.job_id,
         true <- receipt.classification == envelope.classification,
         true <- receipt.result == :applied,
         true <- receipt.entity_revision <= object.lifecycle_revision,
         true <- object.lifecycle == :deleted do
      {:ok, object}
    else
      false -> {:error, Error.new(:conflict)}
      {:error, %Error{}} = error -> error
    end
  end

  defp acknowledge_or_replay_object_delete(repo, envelope, deletion, nil) do
    with {:ok, object} <- lock_cleanup_object(repo, envelope),
         true <- live_object_references(repo, object) == 0,
         true <- object.lifecycle == :deleting,
         true <- object.delete_claim_token == deletion.claim_token,
         true <-
           object.lifecycle_revision ==
             deletion.expected_lifecycle_revision do
      persist_deleted_object(repo, envelope, object, deletion)
    else
      false -> {:error, Error.new(:conflict)}
      {:error, %Error{}} = error -> error
    end
  end

  defp persist_deleted_object(repo, envelope, object, deletion) do
    now = DateTime.utc_now(:microsecond)
    next_revision = object.lifecycle_revision + 1

    with {:ok, deleted} <-
           object
           |> AssetObject.lifecycle_changeset(%{
             lifecycle: :deleted,
             lifecycle_revision: next_revision,
             delete_claim_token: nil,
             delete_claimed_at: nil,
             deleted_at: now,
             deletion_evidence: deletion_evidence(deletion)
           })
           |> repo.update(),
         {:ok, _audit} <-
           repo.insert(
             audit_changeset(%{
               actor_kind: :system,
               principal_id: envelope.principal_id,
               operation: "object.deleted",
               vault_id: envelope.vault_id,
               classification: envelope.classification,
               correlation_id: envelope.correlation_id,
               target_type: "asset_object",
               target_id: object.id,
               metadata: %{"lifecycle" => "deleted"},
               occurred_at: now
             })
           ),
         {:ok, _receipt} <-
           Progress.record_effect(repo, envelope, %{
             effect_key: envelope.idempotency_key,
             result: :applied,
             entity_revision: next_revision
           }) do
      {:ok, deleted}
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset_error(changeset)}
      {:error, %Error{}} = error -> error
    end
  end

  defp deletion_evidence(deletion) do
    evidence = %{
      "claim_token" => deletion.claim_token,
      "storage_status" => "deleted_or_missing"
    }

    case Map.get(deletion, :prior_claim_token) do
      prior_claim_token when is_binary(prior_claim_token) ->
        Map.put(evidence, "prior_claim_token", prior_claim_token)

      _none ->
        evidence
    end
  end

  defp lock_cleanup_object(repo, envelope) do
    object_id = envelope.payload["object_id"]

    case repo.one(
           from object in AssetObject,
             where:
               object.id == ^object_id and
                 object.vault_id == ^envelope.vault_id and
                 object.classification == ^envelope.classification,
             lock: "FOR UPDATE"
         ) do
      %AssetObject{} = object -> {:ok, object}
      nil -> {:error, Error.new(:conflict)}
    end
  end

  defp live_object_references(repo, object) do
    repo.aggregate(
      from(asset in Asset,
        where:
          asset.asset_object_id == ^object.id and
            asset.vault_id == ^object.vault_id
      ),
      :count
    )
  end

  defp bind_cleanup_authority(cleanup, envelope) do
    if cleanup.principal_id == envelope.principal_id and
         cleanup.principal_authorization_epoch ==
           envelope.principal_authorization_epoch and
         cleanup.vault_authorization_epoch ==
           envelope.vault_authorization_epoch do
      :ok
    else
      {:error, Error.new(:forbidden)}
    end
  end

  defp bind_current_scope(repo, envelope) do
    case Ecto.Adapters.SQL.query(
           repo,
           """
           SELECT
             NULLIF(
               current_setting('singularity.principal_id', true),
               ''
             )::uuid,
             NULLIF(
               current_setting('singularity.vault_id', true),
               ''
             )::uuid
           """,
           [],
           log: false
         ) do
      {:ok, %{rows: [[principal_id, vault_id]]}} ->
        with {:ok, principal_id} <- Ecto.UUID.load(principal_id),
             {:ok, vault_id} <- Ecto.UUID.load(vault_id),
             true <- principal_id == envelope.principal_id,
             true <- vault_id == envelope.vault_id do
          :ok
        else
          _mismatch -> {:error, Error.new(:forbidden)}
        end

      _unavailable ->
        {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  defp validate_object_cleanup_envelope(
         %JobEnvelope{
           job_id: job_id,
           vault_id: vault_id,
           principal_id: principal_id,
           classification: classification,
           expected_entity_revision: expected_entity_revision,
           idempotency_key: idempotency_key,
           payload: %{
             "asset_id" => asset_id,
             "object_id" => object_id
           }
         } = envelope
       )
       when classification in [:private, :sensitive, :restricted] and
              is_integer(expected_entity_revision) and expected_entity_revision >= 0 and
              is_binary(idempotency_key) and byte_size(idempotency_key) > 0 and
              map_size(envelope.payload) == 2,
       do: UUID.validate([job_id, vault_id, principal_id, asset_id, object_id])

  defp validate_object_cleanup_envelope(_envelope),
    do: {:error, Error.new(:invalid)}

  defp validate_deletion_receipt(
         envelope,
         object_id,
         claim_token,
         expected_lifecycle_revision
       )
       when is_integer(expected_lifecycle_revision) and
              expected_lifecycle_revision >= 0 do
    with :ok <- UUID.validate([object_id, claim_token]),
         true <- object_id == envelope.payload["object_id"],
         true <- claim_token == envelope.job_id do
      :ok
    else
      _invalid -> {:error, Error.new(:conflict)}
    end
  end

  defp validate_deletion_receipt(
         _envelope,
         _object_id,
         _claim_token,
         _expected_lifecycle_revision
       ),
       do: {:error, Error.new(:invalid)}

  defp complete_or_replay_logical_delete(
         repo,
         envelope,
         %EffectReceipt{} = receipt
       ) do
    with {:ok, asset} <- lock_cleanup_asset(repo, envelope),
         true <- receipt.submission_id == envelope.job_id,
         true <- receipt.classification == envelope.classification,
         true <- receipt.result in [:applied, :stale],
         true <- receipt.entity_revision <= asset.state_revision do
      {:ok, asset}
    else
      false -> {:error, Error.new(:conflict)}
      {:error, %Error{}} = error -> error
    end
  end

  defp complete_or_replay_logical_delete(repo, envelope, nil) do
    with {:ok, asset} <- lock_cleanup_asset(repo, envelope) do
      cond do
        asset.state_revision != envelope.expected_entity_revision ->
          record_stale_cleanup(repo, envelope, asset)

        asset.state == :pending_delete ->
          apply_logical_delete(repo, envelope, asset)

        true ->
          {:error, Error.new(:conflict)}
      end
    end
  end

  defp apply_logical_delete(repo, envelope, asset) do
    now = DateTime.utc_now(:microsecond)
    next_revision = asset.state_revision + 1

    with {:ok, object} <- lock_referenced_object(repo, envelope, asset),
         {_projection_count, _rows} <-
           repo.delete_all(
             from document in AssetSearchDocument,
               where:
                 document.asset_id == ^asset.id and
                   document.vault_id == ^asset.vault_id
           ),
         {_released_count, _rows} <-
           repo.update_all(
             from(reference in ResourceAsset,
               where:
                 reference.asset_id == ^asset.id and
                   reference.vault_id == ^asset.vault_id and
                   is_nil(reference.released_at)
             ),
             set: [released_at: now]
           ),
         {:ok, deleted} <-
           asset
           |> Ecto.Changeset.change(%{
             state: :deleted,
             state_revision: next_revision,
             asset_object_id: nil
           })
           |> repo.update(),
         {:ok, _object_disposition} <-
           retain_or_schedule_orphan(repo, envelope, object, now),
         {:ok, _audit} <-
           repo.insert(
             audit_changeset(%{
               actor_kind: :principal,
               principal_id: envelope.principal_id,
               operation: "asset.deleted",
               vault_id: envelope.vault_id,
               classification: envelope.classification,
               correlation_id: envelope.correlation_id,
               target_type: "asset",
               target_id: asset.id,
               metadata: %{"state" => "deleted"},
               occurred_at: now
             })
           ),
         {:ok, _receipt} <-
           Progress.record_effect(repo, envelope, %{
             effect_key: envelope.idempotency_key,
             result: :applied,
             entity_revision: next_revision
           }) do
      {:ok, deleted}
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset_error(changeset)}
      {:error, %Error{}} = error -> error
    end
  end

  defp lock_referenced_object(_repo, _envelope, %Asset{asset_object_id: nil}),
    do: {:ok, nil}

  defp lock_referenced_object(repo, envelope, %Asset{asset_object_id: object_id}) do
    case repo.one(
           from object in AssetObject,
             where:
               object.id == ^object_id and
                 object.vault_id == ^envelope.vault_id and
                 object.classification == ^envelope.classification,
             lock: "FOR UPDATE"
         ) do
      %AssetObject{lifecycle: :available} = object -> {:ok, object}
      %AssetObject{} -> {:error, Error.new(:conflict)}
      nil -> {:error, Error.new(:conflict)}
    end
  end

  defp retain_or_schedule_orphan(_repo, _envelope, nil, _now),
    do: {:ok, :none}

  defp retain_or_schedule_orphan(repo, envelope, object, now) do
    live_references =
      repo.aggregate(
        from(asset in Asset,
          where:
            asset.asset_object_id == ^object.id and
              asset.vault_id == ^object.vault_id
        ),
        :count
      )

    if live_references == 0 do
      schedule_orphan(repo, envelope, object, now)
    else
      {:ok, :retained}
    end
  end

  defp schedule_orphan(repo, envelope, object, now) do
    next_revision = object.lifecycle_revision + 1
    retained_until = DateTime.add(now, object_retention_seconds(), :second)

    with {:ok, cleanup} <- cleanup_authorization(repo, object.vault_id),
         {:ok, orphan} <-
           object
           |> AssetObject.lifecycle_changeset(%{
             lifecycle: :orphan_pending,
             lifecycle_revision: next_revision,
             retained_until: retained_until
           })
           |> repo.update(),
         {:ok, _audit} <-
           repo.insert(
             audit_changeset(%{
               actor_kind: :system,
               principal_id: cleanup.principal_id,
               operation: "object.orphaned",
               vault_id: object.vault_id,
               classification: object.classification,
               correlation_id: envelope.correlation_id,
               target_type: "asset_object",
               target_id: object.id,
               metadata: %{
                 "lifecycle" => "orphan_pending",
                 "initiating_principal_id" => envelope.principal_id
               },
               occurred_at: now
             })
           ),
         {:ok, _outbox} <-
           repo.insert(
             outbox_changeset(
               %{
                 event_type: "object.cleanup_requested",
                 idempotency_key: "object-cleanup:#{object.id}:#{next_revision}",
                 vault_id: object.vault_id,
                 principal_id: cleanup.principal_id,
                 required_capability: "object.cleanup",
                 classification: object.classification,
                 correlation_id: envelope.correlation_id,
                 causation_id: envelope.job_id,
                 expected_entity_revision: next_revision,
                 payload: %{
                   "asset_id" => envelope.payload["asset_id"],
                   "object_id" => object.id
                 },
                 occurred_at: now
               },
               cleanup
             )
           ) do
      {:ok, orphan}
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset_error(changeset)}
      {:error, %Error{}} = error -> error
    end
  end

  defp cleanup_authorization(repo, vault_id) do
    with {:ok, dumped_vault_id} <- UUID.dump(vault_id) do
      case Ecto.Adapters.SQL.query(
             repo,
             """
             SELECT
               principal_id,
               principal_authorization_epoch,
               vault_authorization_epoch
             FROM core.object_cleanup_authorization($1)
             """,
             [dumped_vault_id],
             log: false
           ) do
        {:ok, %{rows: [[principal_id, principal_epoch, vault_epoch]]}}
        when is_integer(principal_epoch) and principal_epoch >= 0 and
               is_integer(vault_epoch) and vault_epoch >= 0 ->
          {:ok,
           %{
             principal_id: Ecto.UUID.load!(principal_id),
             principal_authorization_epoch: principal_epoch,
             vault_authorization_epoch: vault_epoch
           }}

        {:ok, %{rows: []}} ->
          {:error, Error.new(:forbidden)}

        _unavailable ->
          {:error, Error.new(:storage_unavailable, retryable?: true)}
      end
    else
      :error -> {:error, Error.new(:invalid)}
    end
  end

  defp object_retention_seconds do
    Application.get_env(
      :singularity_storage,
      :object_retention_seconds,
      0
    )
  end

  defp record_stale_cleanup(repo, envelope, asset) do
    with {:ok, _receipt} <-
           Progress.record_effect(repo, envelope, %{
             effect_key: envelope.idempotency_key,
             result: :stale,
             entity_revision: asset.state_revision
           }) do
      {:ok, asset}
    end
  end

  defp lock_cleanup_asset(repo, envelope) do
    asset_id = envelope.payload["asset_id"]

    case repo.one(
           from asset in Asset,
             where:
               asset.id == ^asset_id and
                 asset.vault_id == ^envelope.vault_id and
                 asset.classification == ^envelope.classification,
             lock: "FOR UPDATE"
         ) do
      %Asset{} = asset -> {:ok, asset}
      nil -> {:error, Error.new(:conflict)}
    end
  end

  defp lock_effect_receipt(repo, envelope) do
    case repo.one(
           from receipt in EffectReceipt,
             where:
               receipt.vault_id == ^envelope.vault_id and
                 receipt.effect_key == ^envelope.idempotency_key,
             lock: "FOR UPDATE"
         ) do
      nil -> {:ok, nil}
      %EffectReceipt{} = receipt -> {:ok, receipt}
    end
  end

  defp validate_asset_cleanup_envelope(
         %JobEnvelope{
           job_id: job_id,
           vault_id: vault_id,
           principal_id: principal_id,
           classification: classification,
           expected_entity_revision: expected_entity_revision,
           idempotency_key: idempotency_key,
           payload: %{"asset_id" => asset_id}
         } = envelope
       )
       when classification in [:private, :sensitive, :restricted] and
              is_integer(expected_entity_revision) and expected_entity_revision >= 0 and
              is_binary(idempotency_key) and byte_size(idempotency_key) > 0 and
              map_size(envelope.payload) == 1,
       do: UUID.validate([job_id, vault_id, principal_id, asset_id])

  defp validate_asset_cleanup_envelope(_envelope),
    do: {:error, Error.new(:invalid)}

  defp apply_or_replay_tombstone(repo, %Asset{} = asset, command) do
    cond do
      asset.state in @deletable_states and
          asset.state_revision == command.expected_state_revision ->
        apply_tombstone(repo, asset, command)

      asset.state in [:pending_delete, :deleted] ->
        replay_tombstone(repo, asset, command)

      true ->
        {:error, Error.new(:conflict)}
    end
  end

  defp apply_tombstone(repo, asset, command) do
    now = DateTime.utc_now(:microsecond)
    correlation_id = Ecto.UUID.generate()
    next_revision = asset.state_revision + 1

    with {:ok, epochs} <-
           authorization_epochs(repo, command.principal_id, command.vault_id),
         {:ok, tombstone} <-
           repo.insert(
             Tombstone.create_changeset(%Tombstone{}, %{
               id: Ecto.UUID.generate(),
               vault_id: command.vault_id,
               asset_id: command.asset_id,
               principal_id: command.principal_id,
               classification: command.classification,
               reason: "asset deletion requested",
               retention_metadata: %{
                 "expected_state_revision" => command.expected_state_revision
               },
               deleted_at: now
             })
           ),
         {_released_count, _rows} <-
           repo.update_all(
             from(reference in ResourceAsset,
               where:
                 reference.asset_id == ^command.asset_id and
                   reference.vault_id == ^command.vault_id and
                   is_nil(reference.released_at)
             ),
             set: [released_at: now]
           ),
         {:ok, pending} <-
           asset
           |> Asset.transition_changeset(%{
             state: :pending_delete,
             state_revision: next_revision
           })
           |> repo.update(),
         {:ok, _audit} <-
           repo.insert(
             audit_changeset(%{
               actor_kind: :principal,
               principal_id: command.principal_id,
               operation: "asset.tombstoned",
               vault_id: command.vault_id,
               classification: command.classification,
               correlation_id: correlation_id,
               target_type: "asset",
               target_id: command.asset_id,
               metadata: %{"state" => "pending_delete"},
               occurred_at: now
             })
           ),
         {:ok, _outbox} <-
           repo.insert(
             outbox_changeset(
               %{
                 event_type: "asset.cleanup_requested",
                 idempotency_key: "asset-cleanup:#{command.asset_id}:#{next_revision}",
                 vault_id: command.vault_id,
                 principal_id: command.principal_id,
                 required_capability: "asset.write",
                 classification: command.classification,
                 correlation_id: correlation_id,
                 causation_id: tombstone.id,
                 expected_entity_revision: next_revision,
                 payload: %{"asset_id" => command.asset_id},
                 occurred_at: now
               },
               epochs
             )
           ) do
      {:ok, pending}
    else
      {:error, %Error{}} = error -> error
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset_error(changeset)}
    end
  end

  defp replay_tombstone(repo, asset, command) do
    expected = command.expected_state_revision

    tombstone =
      repo.one(
        from tombstone in Tombstone,
          where:
            tombstone.asset_id == ^command.asset_id and
              tombstone.vault_id == ^command.vault_id and
              tombstone.principal_id == ^command.principal_id,
          order_by: [asc: tombstone.deleted_at, asc: tombstone.id],
          limit: 1,
          lock: "FOR SHARE"
      )

    if match?(
         %Tombstone{
           classification: classification,
           retention_metadata: %{"expected_state_revision" => ^expected}
         }
         when classification == command.classification,
         tombstone
       ) do
      {:ok, asset}
    else
      {:error, Error.new(:conflict)}
    end
  end

  defp lock_asset(repo, asset_id, vault_id) do
    case repo.one(
           from asset in Asset,
             where: asset.id == ^asset_id and asset.vault_id == ^vault_id,
             lock: "FOR UPDATE"
         ) do
      %Asset{} = asset -> {:ok, asset}
      nil -> {:error, Error.new(:not_found)}
    end
  end

  defp bind_delete_target(asset, command) do
    if asset.vault_id == command.vault_id and
         asset.classification == command.classification do
      :ok
    else
      {:error, Error.new(:forbidden)}
    end
  end

  defp reject_open_upload(repo, asset) do
    open_upload? =
      repo.exists?(
        from stage in AssetStage,
          where:
            stage.asset_id == ^asset.id and
              stage.vault_id == ^asset.vault_id and
              stage.state == :open
      )

    if open_upload?,
      do: {:error, Error.new(:conflict)},
      else: :ok
  end

  defp bind_delete_lock_target(
         repo,
         asset,
         %{locked_object_id: expected_object_id}
       ) do
    if delete_lock_object_id(repo, asset) == expected_object_id do
      :ok
    else
      {:error, Error.new(:conflict)}
    end
  end

  defp bind_delete_lock_target(_repo, _asset, _command), do: :ok

  defp delete_lock_object_id(_repo, %Asset{asset_object_id: object_id})
       when is_binary(object_id),
       do: object_id

  defp delete_lock_object_id(repo, %Asset{} = asset) do
    repo.one(
      from stage in AssetStage,
        where:
          stage.asset_id == ^asset.id and
            stage.vault_id == ^asset.vault_id and
            stage.state in [:sealed, :finalized],
        order_by: [desc: stage.inserted_at, desc: stage.id],
        limit: 1,
        select: stage.candidate_object_id
    )
  end

  defp validate_delete_command(%{
         asset_id: asset_id,
         vault_id: vault_id,
         principal_id: principal_id,
         classification: classification,
         expected_state_revision: expected_state_revision
       })
       when classification in [:private, :sensitive, :restricted] and
              is_integer(expected_state_revision) and expected_state_revision >= 0,
       do: UUID.validate([asset_id, vault_id, principal_id])

  defp validate_delete_command(_command),
    do: {:error, Error.new(:invalid)}

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

        _unavailable ->
          {:error, Error.new(:storage_unavailable, retryable?: true)}
      end
    else
      :error -> {:error, Error.new(:invalid)}
    end
  end

  defp audit_changeset(attrs) do
    AuditEvent.append_changeset(
      %AuditEvent{},
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          result: :completed
        },
        attrs
      )
    )
  end

  defp outbox_changeset(attrs, epochs) do
    OutboxEvent.create_changeset(
      %OutboxEvent{},
      attrs
      |> Map.merge(epochs)
      |> Map.merge(%{id: Ecto.UUID.generate(), envelope_version: 1})
    )
  end

  defp transact(repo, callback) do
    case repo.transaction(fn ->
           case callback.() do
             {:error, reason} -> repo.rollback(reason)
             result -> result
           end
         end) do
      {:ok, result} -> result
      {:error, %Error{}} = error -> error
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset_error(changeset)}
      {:error, _reason} -> {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  defp changeset_error(changeset) do
    if Enum.any?(changeset.errors, fn
         {_field, {_message, metadata}} -> metadata[:constraint] == :foreign
       end) do
      Error.new(:not_found)
    else
      Error.new(:invalid)
    end
  end
end
