defmodule Singularity.Storage.Backup.Reconciler do
  @moduledoc "Reconciles restored durable work before dispatch resumes."

  alias Singularity.Storage.SafeSQL, as: SQL
  alias Singularity.Core.Error

  @retirement_reasons [
    "legacy_missing_principal_authorization_epoch_provenance",
    "restore_effect_already_reflected",
    "restore_stale_destructive"
  ]

  @spec reconcile(module(), map()) :: :ok | {:error, Error.t()}
  def reconcile(
        repo,
        %{
          manifest_id: manifest_id,
          outbox_high_water_mark: outbox_high_water_mark,
          vault_id: vault_id
        }
      )
      when is_atom(repo) and is_integer(outbox_high_water_mark) and
             outbox_high_water_mark >= 0 do
    with {:ok, manifest_id} <- canonical_uuid(manifest_id),
         {:ok, vault_id} <- canonical_uuid(vault_id),
         {:ok, dumped_vault_id} <- Ecto.UUID.dump(vault_id) do
      transact(repo, dumped_vault_id, outbox_high_water_mark, manifest_id)
    else
      _invalid -> invalid()
    end
  end

  def reconcile(_repo, _restored_cut), do: invalid()

  defp transact(repo, vault_id, outbox_high_water_mark, manifest_id) do
    case repo.transaction(fn ->
           with :ok <- set_owner_role(repo),
                {:ok, events} <- restored_events(repo, vault_id, outbox_high_water_mark),
                :ok <- reconcile_events(repo, events, vault_id, manifest_id) do
             :ok
           else
             {:error, %Error{} = error} -> repo.rollback(error)
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, %Error{} = error} -> {:error, error}
      _failure -> storage_unavailable()
    end
  rescue
    _exception -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  defp set_owner_role(repo) do
    case SQL.query(repo, "SET LOCAL ROLE singularity_table_owner", [], log: false) do
      {:ok, _result} -> :ok
      {:error, _reason} -> storage_unavailable()
    end
  end

  defp restored_events(repo, vault_id, outbox_high_water_mark) do
    with :ok <- require_vault(repo, vault_id),
         :ok <- require_exact_cut(repo, vault_id, outbox_high_water_mark) do
      case SQL.query(
             repo,
             """
             SELECT
               id,
               event_type,
               idempotency_key,
               classification,
               expected_entity_revision,
               payload,
               retired_at,
               retirement_reason
             FROM core.outbox_events
             WHERE vault_id = $1
             ORDER BY sequence, id
             FOR UPDATE
             """,
             [vault_id],
             log: false
           ) do
        {:ok, %{rows: rows}} when is_list(rows) -> {:ok, rows}
        {:error, _reason} -> storage_unavailable()
        _malformed -> storage_unavailable()
      end
    end
  end

  defp require_vault(repo, vault_id) do
    case SQL.query(
           repo,
           "SELECT id FROM core.vaults WHERE id = $1 FOR UPDATE",
           [vault_id],
           log: false
         ) do
      {:ok, %{rows: [[^vault_id]]}} -> :ok
      {:ok, _missing_or_conflicting} -> integrity_failure()
      {:error, _reason} -> storage_unavailable()
    end
  end

  defp require_exact_cut(repo, vault_id, outbox_high_water_mark) do
    case SQL.query(
           repo,
           """
           SELECT COALESCE(max(sequence), 0)
           FROM core.outbox_events
           WHERE vault_id = $1
           """,
           [vault_id],
           log: false
         ) do
      {:ok, %{rows: [[^outbox_high_water_mark]]}} -> :ok
      {:ok, %{rows: [[mark]]}} when is_integer(mark) and mark >= 0 -> integrity_failure()
      {:error, _reason} -> storage_unavailable()
      _malformed -> storage_unavailable()
    end
  end

  defp reconcile_events(repo, events, vault_id, manifest_id) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      case reconcile_event(repo, event, vault_id, manifest_id) do
        :ok -> {:cont, :ok}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp reconcile_event(
         repo,
         [
           event_id,
           event_type,
           idempotency_key,
           classification,
           _expected_revision,
           _payload,
           %DateTime{},
           retirement_reason
         ],
         vault_id,
         _manifest_id
       )
       when retirement_reason in @retirement_reasons do
    with {:ok, job_type} <- event_job_type(event_type),
         :ok <-
           validate_submission(
             repo,
             event_id,
             vault_id,
             classification,
             idempotency_key,
             job_type
           ),
         :ok <- clear_terminal_runner(repo, event_id) do
      :ok
    end
  end

  defp reconcile_event(
         repo,
         [
           event_id,
           "object.cleanup_requested",
           idempotency_key,
           classification,
           expected_revision,
           payload,
           nil,
           nil
         ],
         vault_id,
         _manifest_id
       ) do
    with true <- is_integer(expected_revision) and expected_revision >= 0,
         {:ok, asset_id, object_id} <- object_cleanup_ids(payload),
         :ok <-
           validate_submission(
             repo,
             event_id,
             vault_id,
             classification,
             idempotency_key,
             "object_cleanup"
           ),
         :ok <- require_no_progress(repo, event_id),
         :ok <- validate_asset_scope(repo, asset_id, vault_id, classification),
         {:ok, ^vault_id, ^classification, lifecycle, revision} <-
           object_state(repo, object_id),
         {:ok, receipt} <-
           receipt_status(
             repo,
             event_id,
             vault_id,
             classification,
             idempotency_key,
             revision
           ),
         {:ok, reference_count} <- object_reference_count(repo, object_id, vault_id) do
      cond do
        receipt == :terminal ->
          retire(repo, event_id, "restore_effect_already_reflected")

        reference_count > 0 ->
          retire(repo, event_id, "restore_stale_destructive")

        lifecycle in ["orphan_pending", "deleting"] and revision == expected_revision ->
          reset_for_dispatch(repo, event_id)

        true ->
          retire(repo, event_id, "restore_stale_destructive")
      end
    else
      {:error, %Error{}} = error -> error
      _invalid -> integrity_failure()
    end
  end

  defp reconcile_event(
         repo,
         [
           event_id,
           "asset.finalize_requested",
           idempotency_key,
           classification,
           expected_revision,
           payload,
           nil,
           nil
         ],
         vault_id,
         _manifest_id
       ) do
    with true <- is_integer(expected_revision) and expected_revision >= 0,
         {:ok, asset_id} <- asset_id(payload),
         :ok <-
           validate_submission(
             repo,
             event_id,
             vault_id,
             classification,
             idempotency_key,
             "asset_finalize"
           ),
         :ok <- require_no_progress(repo, event_id),
         {:ok, ^vault_id, ^classification, state, revision} <- asset_state(repo, asset_id),
         {:ok, receipt} <-
           receipt_status(
             repo,
             event_id,
             vault_id,
             classification,
             idempotency_key,
             revision
           ) do
      cond do
        receipt == :terminal ->
          retire(repo, event_id, "restore_effect_already_reflected")

        state == "verified" and revision == expected_revision ->
          reset_for_dispatch(repo, event_id)

        true ->
          retire(repo, event_id, "restore_effect_already_reflected")
      end
    else
      {:error, %Error{}} = error -> error
      _invalid -> integrity_failure()
    end
  end

  defp reconcile_event(
         repo,
         [
           event_id,
           "backup.requested",
           idempotency_key,
           classification,
           _expected_revision,
           %{"pending_manifest_id" => pending_manifest_id} = payload,
           nil,
           nil
         ],
         vault_id,
         manifest_id
       )
       when map_size(payload) == 1 do
    with {:ok, ^manifest_id} <- canonical_uuid(pending_manifest_id),
         :ok <-
           validate_submission(
             repo,
             event_id,
             vault_id,
             classification,
             idempotency_key,
             "backup"
           ),
         :ok <- require_delivered(repo, event_id),
         :ok <- retire(repo, event_id, "restore_effect_already_reflected") do
      :ok
    else
      {:error, %Error{}} = error -> error
      _invalid -> integrity_failure()
    end
  end

  defp reconcile_event(
         repo,
         [
           event_id,
           "asset.verify_requested",
           idempotency_key,
           classification,
           expected_revision,
           payload,
           nil,
           nil
         ],
         vault_id,
         _manifest_id
       ) do
    with true <- is_integer(expected_revision) and expected_revision >= 0,
         {:ok, asset_id} <- asset_id(payload),
         :ok <-
           validate_submission(
             repo,
             event_id,
             vault_id,
             classification,
             idempotency_key,
             "asset_verify"
           ),
         :ok <- require_no_progress(repo, event_id),
         {:ok, ^vault_id, ^classification, state, revision} <- asset_state(repo, asset_id),
         {:ok, receipt} <-
           receipt_status(
             repo,
             event_id,
             vault_id,
             classification,
             idempotency_key,
             revision
           ) do
      cond do
        receipt == :terminal ->
          retire(repo, event_id, "restore_effect_already_reflected")

        state == "uploaded" and revision == expected_revision ->
          reset_for_dispatch(repo, event_id)

        true ->
          retire(repo, event_id, "restore_effect_already_reflected")
      end
    else
      {:error, %Error{}} = error -> error
      _invalid -> integrity_failure()
    end
  end

  defp reconcile_event(
         repo,
         [
           event_id,
           "asset.cleanup_requested",
           idempotency_key,
           classification,
           expected_revision,
           payload,
           nil,
           nil
         ],
         vault_id,
         _manifest_id
       ) do
    with true <- is_integer(expected_revision) and expected_revision >= 0,
         {:ok, asset_id} <- asset_id(payload),
         :ok <-
           validate_submission(
             repo,
             event_id,
             vault_id,
             classification,
             idempotency_key,
             "asset_cleanup"
           ),
         :ok <- require_no_progress(repo, event_id),
         {:ok, ^vault_id, ^classification, state, revision} <- asset_state(repo, asset_id),
         {:ok, receipt} <-
           receipt_status(
             repo,
             event_id,
             vault_id,
             classification,
             idempotency_key,
             revision
           ) do
      cond do
        receipt == :terminal ->
          retire(repo, event_id, "restore_effect_already_reflected")

        state == "pending_delete" and revision == expected_revision ->
          reset_for_dispatch(repo, event_id)

        true ->
          retire(repo, event_id, "restore_stale_destructive")
      end
    else
      {:error, %Error{}} = error -> error
      _invalid -> integrity_failure()
    end
  end

  defp reconcile_event(
         repo,
         [
           event_id,
           "asset.metadata_requested",
           idempotency_key,
           classification,
           expected_revision,
           payload,
           nil,
           nil
         ],
         vault_id,
         _manifest_id
       ) do
    with true <- is_integer(expected_revision) and expected_revision >= 0,
         {:ok, asset_id} <- asset_id(payload),
         :ok <-
           validate_submission(
             repo,
             event_id,
             vault_id,
             classification,
             idempotency_key,
             "asset_metadata"
           ),
         {:ok, ^vault_id, ^classification, state, revision} <- asset_state(repo, asset_id),
         {:ok, receipt} <-
           receipt_status(
             repo,
             event_id,
             vault_id,
             classification,
             idempotency_key,
             revision
           ),
         {:ok, progress} <-
           metadata_progress(repo, event_id, vault_id, classification) do
      cond do
        receipt == :terminal ->
          retire(repo, event_id, "restore_effect_already_reflected")

        state == "available" and revision == expected_revision and progress == :missing ->
          reset_for_dispatch(repo, event_id)

        state == "processing" and revision == expected_revision + 1 and
            resumable_metadata_progress?(progress, event_id, vault_id, revision) ->
          reset_for_dispatch(repo, event_id)

        state == "processing" ->
          integrity_failure()

        true ->
          retire(repo, event_id, "restore_effect_already_reflected")
      end
    else
      {:error, %Error{}} = error -> error
      _invalid -> integrity_failure()
    end
  end

  defp reconcile_event(_repo, _event, _vault_id, _manifest_id), do: integrity_failure()

  defp validate_submission(
         repo,
         event_id,
         vault_id,
         classification,
         idempotency_key,
         job_type
       ) do
    case SQL.query(
           repo,
           """
           SELECT
             id,
             vault_id,
             outbox_event_id,
             classification,
             idempotency_key,
             job_type
           FROM jobs.job_submissions
           WHERE outbox_event_id = $1
           FOR UPDATE
           """,
           [event_id],
           log: false
         ) do
      {:ok, %{rows: []}} ->
        :ok

      {:ok,
       %{
         rows: [
           [
             ^event_id,
             ^vault_id,
             ^event_id,
             ^classification,
             ^idempotency_key,
             ^job_type
           ]
         ]
       }} ->
        :ok

      {:ok, _conflicting} ->
        integrity_failure()

      {:error, _reason} ->
        storage_unavailable()
    end
  end

  defp asset_state(repo, asset_id) do
    case SQL.query(
           repo,
           """
           SELECT vault_id, classification, state, state_revision
           FROM content.assets
           WHERE id = $1
           FOR UPDATE
           """,
           [asset_id],
           log: false
         ) do
      {:ok, %{rows: [[vault_id, classification, state, revision]]}}
      when is_binary(classification) and is_binary(state) and is_integer(revision) ->
        {:ok, vault_id, classification, state, revision}

      {:ok, _missing_or_conflicting} ->
        integrity_failure()

      {:error, _reason} ->
        storage_unavailable()
    end
  end

  defp validate_asset_scope(repo, asset_id, vault_id, classification) do
    case SQL.query(
           repo,
           """
           SELECT vault_id, classification
           FROM content.assets
           WHERE id = $1
           FOR UPDATE
           """,
           [asset_id],
           log: false
         ) do
      {:ok, %{rows: [[^vault_id, ^classification]]}} -> :ok
      {:ok, _missing_or_conflicting} -> integrity_failure()
      {:error, _reason} -> storage_unavailable()
    end
  end

  defp object_state(repo, object_id) do
    case SQL.query(
           repo,
           """
           SELECT vault_id, classification, lifecycle, lifecycle_revision
           FROM content.asset_objects
           WHERE id = $1
           FOR UPDATE
           """,
           [object_id],
           log: false
         ) do
      {:ok, %{rows: [[vault_id, classification, lifecycle, revision]]}}
      when is_binary(classification) and is_binary(lifecycle) and is_integer(revision) ->
        {:ok, vault_id, classification, lifecycle, revision}

      {:ok, _missing_or_conflicting} ->
        integrity_failure()

      {:error, _reason} ->
        storage_unavailable()
    end
  end

  defp object_reference_count(repo, object_id, vault_id) do
    case SQL.query(
           repo,
           """
           SELECT count(*)
           FROM content.assets
           WHERE asset_object_id = $1 AND vault_id = $2
           """,
           [object_id, vault_id],
           log: false
         ) do
      {:ok, %{rows: [[count]]}} when is_integer(count) and count >= 0 -> {:ok, count}
      {:error, _reason} -> storage_unavailable()
      _malformed -> storage_unavailable()
    end
  end

  defp receipt_status(
         repo,
         event_id,
         vault_id,
         classification,
         idempotency_key,
         current_revision
       ) do
    case SQL.query(
           repo,
           """
           SELECT vault_id, classification, effect_key, result, entity_revision
           FROM jobs.effect_receipts
           WHERE submission_id = $1
           ORDER BY id
           FOR UPDATE
           """,
           [event_id],
           log: false
         ) do
      {:ok, %{rows: []}} ->
        {:ok, :missing}

      {:ok,
       %{
         rows: [
           [
             ^vault_id,
             ^classification,
             ^idempotency_key,
             result,
             entity_revision
           ]
         ]
       }}
      when result in ["applied", "stale", "failed"] and
             is_integer(entity_revision) and entity_revision >= 0 and
             entity_revision <= current_revision ->
        {:ok, :terminal}

      {:ok, _conflicting} ->
        integrity_failure()

      {:error, _reason} ->
        storage_unavailable()
    end
  end

  defp metadata_progress(repo, event_id, vault_id, classification) do
    case SQL.query(
           repo,
           """
           SELECT
             vault_id,
             classification,
             state,
             processing_revision,
             checkpoint_version,
             checkpoint
           FROM jobs.job_progress
           WHERE submission_id = $1
           FOR UPDATE
           """,
           [event_id],
           log: false
         ) do
      {:ok, %{rows: []}} ->
        {:ok, :missing}

      {:ok,
       %{
         rows: [
           [
             ^vault_id,
             ^classification,
             state,
             processing_revision,
             checkpoint_version,
             checkpoint
           ]
         ]
       }}
      when is_binary(state) and is_integer(processing_revision) and
             is_integer(checkpoint_version) and is_map(checkpoint) ->
        {:ok,
         %{
           state: state,
           processing_revision: processing_revision,
           checkpoint_version: checkpoint_version,
           checkpoint: checkpoint
         }}

      {:ok, _conflicting} ->
        integrity_failure()

      {:error, _reason} ->
        storage_unavailable()
    end
  end

  defp require_no_progress(repo, event_id) do
    case SQL.query(
           repo,
           "SELECT id FROM jobs.job_progress WHERE submission_id = $1 FOR UPDATE",
           [event_id],
           log: false
         ) do
      {:ok, %{rows: []}} -> :ok
      {:ok, _conflicting} -> integrity_failure()
      {:error, _reason} -> storage_unavailable()
    end
  end

  defp resumable_metadata_progress?(
         %{
           state: state,
           processing_revision: processing_revision,
           checkpoint_version: 3,
           checkpoint: %{
             "job_id" => checkpoint_job_id,
             "processing_revision" => processing_revision,
             "protocol" => "asset_metadata_v1",
             "version" => 3,
             "vault_id" => checkpoint_vault_id
           }
         },
         dumped_event_id,
         dumped_vault_id,
         processing_revision
       )
       when state in ["running", "waiting_for_unlock"] do
    canonical_uuid_matches?(checkpoint_job_id, dumped_event_id) and
      canonical_uuid_matches?(checkpoint_vault_id, dumped_vault_id)
  end

  defp resumable_metadata_progress?(_progress, _event_id, _vault_id, _revision), do: false

  defp canonical_uuid_matches?(encoded, dumped) when is_binary(encoded) and is_binary(dumped) do
    with {:ok, canonical} <- canonical_uuid(encoded),
         {:ok, ^dumped} <- Ecto.UUID.dump(canonical) do
      true
    else
      _invalid -> false
    end
  end

  defp canonical_uuid_matches?(_encoded, _dumped), do: false

  defp event_job_type("asset.verify_requested"), do: {:ok, "asset_verify"}
  defp event_job_type("asset.finalize_requested"), do: {:ok, "asset_finalize"}
  defp event_job_type("asset.metadata_requested"), do: {:ok, "asset_metadata"}
  defp event_job_type("asset.cleanup_requested"), do: {:ok, "asset_cleanup"}
  defp event_job_type("object.cleanup_requested"), do: {:ok, "object_cleanup"}
  defp event_job_type("backup.requested"), do: {:ok, "backup"}
  defp event_job_type(_event_type), do: integrity_failure()

  defp require_delivered(repo, event_id) do
    case SQL.query(
           repo,
           "SELECT delivered_at FROM core.outbox_events WHERE id = $1 FOR UPDATE",
           [event_id],
           log: false
         ) do
      {:ok, %{rows: [[%DateTime{}]]}} -> :ok
      {:ok, _not_delivered} -> integrity_failure()
      {:error, _reason} -> storage_unavailable()
    end
  end

  defp clear_terminal_runner(repo, event_id) do
    with {:ok, %{num_rows: 1}} <-
           SQL.query(
             repo,
             """
             UPDATE core.outbox_events
             SET
               claim_token = NULL,
               claimed_until = NULL,
               runner_job_id = NULL,
               delivered_at = NULL,
               updated_at = CURRENT_TIMESTAMP
             WHERE id = $1
             """,
             [event_id],
             log: false
           ),
         {:ok, %{num_rows: submission_count}}
         when submission_count in [0, 1] <-
           SQL.query(
             repo,
             """
             UPDATE jobs.job_submissions
             SET runner_job_id = NULL, updated_at = CURRENT_TIMESTAMP
             WHERE outbox_event_id = $1
             """,
             [event_id],
             log: false
           ) do
      :ok
    else
      {:error, _reason} -> storage_unavailable()
      _conflicting -> integrity_failure()
    end
  end

  defp reset_for_dispatch(repo, event_id) do
    with {:ok, %{num_rows: 1}} <-
           SQL.query(
             repo,
             """
             UPDATE core.outbox_events
             SET
               claim_token = NULL,
               claimed_until = NULL,
               runner_job_id = NULL,
               delivered_at = NULL,
               updated_at = CURRENT_TIMESTAMP
             WHERE id = $1
             """,
             [event_id],
             log: false
           ),
         {:ok, %{num_rows: submission_count}}
         when submission_count in [0, 1] <-
           SQL.query(
             repo,
             """
             UPDATE jobs.job_submissions
             SET runner_job_id = NULL, updated_at = CURRENT_TIMESTAMP
             WHERE outbox_event_id = $1
             """,
             [event_id],
             log: false
           ) do
      :ok
    else
      {:error, _reason} -> storage_unavailable()
      _conflicting -> integrity_failure()
    end
  end

  defp retire(repo, event_id, reason) do
    with {:ok, %{num_rows: 1}} <-
           SQL.query(
             repo,
             """
             UPDATE core.outbox_events
             SET
               claim_token = NULL,
               claimed_until = NULL,
               runner_job_id = NULL,
               delivered_at = NULL,
               retired_at = CURRENT_TIMESTAMP,
               retirement_reason = $2,
               updated_at = CURRENT_TIMESTAMP
             WHERE id = $1
             """,
             [event_id, reason],
             log: false
           ),
         {:ok, %{num_rows: submission_count}}
         when submission_count in [0, 1] <-
           SQL.query(
             repo,
             """
             UPDATE jobs.job_submissions
             SET runner_job_id = NULL, updated_at = CURRENT_TIMESTAMP
             WHERE outbox_event_id = $1
             """,
             [event_id],
             log: false
           ) do
      :ok
    else
      {:error, _reason} -> storage_unavailable()
      _conflicting -> integrity_failure()
    end
  end

  defp asset_id(%{"asset_id" => asset_id} = payload) when map_size(payload) == 1,
    do: dumped_uuid(asset_id)

  defp asset_id(_payload), do: integrity_failure()

  defp object_cleanup_ids(%{"asset_id" => asset_id, "object_id" => object_id} = payload)
       when map_size(payload) == 2 do
    with {:ok, asset_id} <- dumped_uuid(asset_id),
         {:ok, object_id} <- dumped_uuid(object_id) do
      {:ok, asset_id, object_id}
    end
  end

  defp object_cleanup_ids(_payload), do: integrity_failure()

  defp dumped_uuid(value) do
    with {:ok, canonical} <- canonical_uuid(value),
         {:ok, dumped} <- Ecto.UUID.dump(canonical) do
      {:ok, dumped}
    else
      _invalid -> integrity_failure()
    end
  end

  defp canonical_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, ^value} -> {:ok, value}
      _invalid -> :error
    end
  end

  defp canonical_uuid(_value), do: :error

  defp invalid, do: {:error, Error.new(:invalid)}
  defp integrity_failure, do: {:error, Error.new(:integrity_failure)}

  defp storage_unavailable,
    do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
