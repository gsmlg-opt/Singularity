defmodule Singularity.Storage.Postgres.NoteRepository do
  @moduledoc false

  @behaviour Singularity.Domains.Notes.Repository

  import Ecto.Query

  alias Singularity.Core.Error
  alias Singularity.Core.NoteSaveResult
  alias Singularity.Core.NoteSnapshot
  alias Singularity.Storage.Postgres.NoteMutationReceipts
  alias Singularity.Storage.Postgres.NoteProjectionReconciler
  alias Singularity.Storage.Postgres.NoteSearchStore
  alias Singularity.Storage.Postgres.UUID
  alias Singularity.Storage.SafeSQL
  alias Singularity.Storage.Schema.Audit.Event, as: AuditEvent
  alias Singularity.Storage.Schema.Content.NoteConflict
  alias Singularity.Storage.Schema.Content.NoteVersion
  alias Singularity.Storage.Schema.Content.Resource
  alias Singularity.Storage.Schema.Content.ResourceVersion
  alias Singularity.Storage.Schema.Core.OutboxEvent

  @impl true
  def create(repo, intent) when is_map(intent) do
    resource_id = Ecto.UUID.generate()
    version_id = Ecto.UUID.generate()

    with :ok <- validate_create(intent),
         {:ok, _stored} = result <-
           NoteMutationReceipts.with_claim(
             repo,
             Map.merge(intent, %{
               operation: :create,
               resource_id: resource_id,
               version_id: version_id
             }),
             fn -> persist_create(repo, intent, resource_id, version_id) end
           ),
         :ok <- checkpoint(intent, :after_receipt) do
      save_result(repo, :create, result)
    end
  rescue
    error in [Ecto.Query.CastError, Ecto.CastError] ->
      {:error, database_error(error)}

    error in [
      Ecto.ConstraintError,
      Ecto.StaleEntryError,
      DBConnection.ConnectionError,
      Postgrex.Error
    ] ->
      {:error, database_error(error)}
  end

  def create(_repo, _intent), do: invalid()

  @impl true
  def save(repo, intent) when is_map(intent) do
    version_id = Ecto.UUID.generate()

    with :ok <- validate_save(intent),
         {:ok, _stored} = result <-
           NoteMutationReceipts.with_claim(
             repo,
             Map.merge(intent, %{operation: :save, version_id: version_id}),
             fn -> persist_save(repo, intent, version_id) end
           ),
         :ok <- checkpoint(intent, :after_receipt) do
      save_result(repo, :save, result)
    end
  rescue
    error in [Ecto.Query.CastError, Ecto.CastError] ->
      {:error, database_error(error)}

    error in [
      Ecto.ConstraintError,
      Ecto.StaleEntryError,
      DBConnection.ConnectionError,
      Postgrex.Error
    ] ->
      {:error, database_error(error)}
  end

  def save(_repo, _intent), do: invalid()

  @impl true
  def merge(repo, intent) when is_map(intent) do
    version_id = Ecto.UUID.generate()

    with :ok <- validate_merge(intent),
         {:ok, _stored} = result <-
           NoteMutationReceipts.with_claim(
             repo,
             Map.merge(intent, %{operation: :merge, version_id: version_id}),
             fn -> persist_merge(repo, intent, version_id) end
           ),
         :ok <- checkpoint(intent, :after_receipt) do
      save_result(repo, :merge, result)
    end
  rescue
    error in [Ecto.Query.CastError, Ecto.CastError] ->
      {:error, database_error(error)}

    error in [
      Ecto.ConstraintError,
      Ecto.StaleEntryError,
      DBConnection.ConnectionError,
      Postgrex.Error
    ] ->
      {:error, database_error(error)}
  end

  def merge(_repo, _intent), do: invalid()

  @impl true
  def tombstone(_repo, _intent), do: invalid()

  @impl true
  def restore(_repo, _intent), do: invalid()

  defp validate_create(intent) do
    with :ok <- validate_common(intent),
         %NoteSnapshot{} = snapshot <- Map.get(intent, :snapshot),
         {:ok, ^snapshot} <-
           NoteSnapshot.initial(%{
             classification: snapshot.classification,
             title: snapshot.title,
             markdown: snapshot.markdown,
             parent_version_id: snapshot.parent_version_id,
             merge_parent_version_id: snapshot.merge_parent_version_id
           }) do
      :ok
    else
      _invalid -> invalid()
    end
  end

  defp validate_save(%{resource_id: resource_id, base_version_id: base_version_id} = intent) do
    with :ok <- validate_common(intent),
         :ok <- UUID.validate([resource_id, base_version_id]),
         %NoteSnapshot{} = snapshot <- Map.get(intent, :snapshot),
         true <- snapshot.parent_version_id == base_version_id,
         {:ok, ^snapshot} <-
           NoteSnapshot.normal(%{
             classification: snapshot.classification,
             title: snapshot.title,
             markdown: snapshot.markdown,
             parent_version_id: snapshot.parent_version_id,
             merge_parent_version_id: snapshot.merge_parent_version_id
           }) do
      :ok
    else
      _invalid -> invalid()
    end
  end

  defp validate_save(_intent), do: invalid()

  defp validate_merge(
         %{
           resource_id: resource_id,
           conflict_id: conflict_id,
           expected_current_version_id: expected_current_version_id,
           competing_version_id: competing_version_id
         } = intent
       ) do
    with :ok <- validate_common(intent),
         :ok <-
           UUID.validate([
             resource_id,
             conflict_id,
             expected_current_version_id,
             competing_version_id
           ]),
         %NoteSnapshot{} = snapshot <- Map.get(intent, :snapshot),
         true <- snapshot.parent_version_id == expected_current_version_id,
         true <- snapshot.merge_parent_version_id == competing_version_id,
         {:ok, ^snapshot} <-
           NoteSnapshot.merge(%{
             classification: snapshot.classification,
             title: snapshot.title,
             markdown: snapshot.markdown,
             parent_version_id: snapshot.parent_version_id,
             merge_parent_version_id: snapshot.merge_parent_version_id
           }) do
      :ok
    else
      _invalid -> invalid()
    end
  end

  defp validate_merge(_intent), do: invalid()

  defp validate_common(%{
         mutation_id: mutation_id,
         principal_id: principal_id,
         vault_id: vault_id,
         classification: :private,
         correlation_id: correlation_id,
         request_fingerprint: <<_::binary-size(32)>>
       }) do
    UUID.validate([mutation_id, principal_id, vault_id, correlation_id])
  end

  defp validate_common(_intent), do: invalid()

  defp persist_create(repo, intent, resource_id, version_id) do
    with {:ok, _resource} <- insert_resource(repo, intent, resource_id, version_id),
         {:ok, version} <- insert_resource_version(repo, intent, resource_id, version_id, 0),
         {:ok, _snapshot} <- insert_note_version(repo, intent, resource_id, version, nil),
         :ok <-
           NoteProjectionReconciler.reconcile(repo, %{
             vault_id: intent.vault_id,
             resource_id: resource_id
           }),
         {:ok, epochs} <- authorization_epochs(repo, intent.principal_id, intent.vault_id),
         :ok <- record_effects(repo, intent, resource_id, version_id, 0, "note.create", epochs) do
      {:ok, %{outcome: "saved", resource_id: resource_id, version_id: version_id}}
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset_error(changeset)}
      {:error, %Error{}} = error -> error
    end
  end

  defp persist_save(repo, intent, version_id) do
    with {:ok, resource} <- lock_resource(repo, intent.vault_id, intent.resource_id),
         :ok <- checkpoint(intent, :after_resource_lock),
         :ok <- require_live(resource),
         :ok <- require_base(repo, intent),
         {:ok, revision} <- next_revision(repo, intent.vault_id, intent.resource_id) do
      if resource.current_version_id == intent.base_version_id do
        persist_canonical_save(repo, intent, version_id, revision)
      else
        persist_competing_save(
          repo,
          intent,
          resource.current_version_id,
          version_id,
          revision
        )
      end
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset_error(changeset)}
      {:error, %Error{}} = error -> error
    end
  end

  defp persist_canonical_save(repo, intent, version_id, revision) do
    with {:ok, version} <-
           insert_resource_version(repo, intent, intent.resource_id, version_id, revision),
         {:ok, _snapshot} <-
           insert_note_version(
             repo,
             intent,
             intent.resource_id,
             version,
             intent.base_version_id,
             nil
           ),
         :ok <- checkpoint(intent, :after_snapshot),
         :ok <- delete_projection(repo, intent),
         :ok <- update_head(repo, intent, version_id, intent.base_version_id),
         :ok <- checkpoint(intent, :after_head),
         :ok <- reconcile_projection(repo, intent),
         :ok <- checkpoint(intent, :after_projection),
         {:ok, epochs} <- authorization_epochs(repo, intent.principal_id, intent.vault_id),
         :ok <-
           record_effects(
             repo,
             intent,
             intent.resource_id,
             version_id,
             revision,
             "note.save",
             %{"version_id" => version_id},
             [current_changed_event(intent.resource_id, revision)],
             epochs
           ) do
      {:ok, %{outcome: "saved", resource_id: intent.resource_id, version_id: version_id}}
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset_error(changeset)}
      {:error, %Error{}} = error -> error
    end
  end

  defp persist_competing_save(
         repo,
         intent,
         canonical_version_id,
         version_id,
         revision
       ) do
    conflict_id = Ecto.UUID.generate()
    created_at = DateTime.utc_now(:microsecond)

    with {:ok, version} <-
           insert_resource_version(repo, intent, intent.resource_id, version_id, revision),
         {:ok, _snapshot} <-
           insert_note_version(
             repo,
             intent,
             intent.resource_id,
             version,
             intent.base_version_id,
             nil
           ),
         :ok <- checkpoint(intent, :after_snapshot),
         {:ok, _conflict} <-
           insert_conflict(
             repo,
             intent,
             conflict_id,
             canonical_version_id,
             version_id,
             created_at
           ),
         :ok <- checkpoint(intent, :after_conflict),
         {:ok, epochs} <- authorization_epochs(repo, intent.principal_id, intent.vault_id),
         :ok <-
           record_effects(
             repo,
             intent,
             intent.resource_id,
             version_id,
             revision,
             "note.save",
             %{"version_id" => version_id, "conflict_id" => conflict_id},
             [conflict_created_event(intent.resource_id, conflict_id, revision)],
             epochs
           ) do
      {:ok,
       %{
         outcome: "conflict",
         resource_id: intent.resource_id,
         version_id: version_id,
         conflict_id: conflict_id
       }}
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset_error(changeset)}
      {:error, %Error{}} = error -> error
    end
  end

  defp persist_merge(repo, intent, version_id) do
    with {:ok, resource} <- lock_resource(repo, intent.vault_id, intent.resource_id),
         :ok <- checkpoint(intent, :after_resource_lock),
         :ok <- require_live(resource),
         :ok <- require_expected_head(resource, intent.expected_current_version_id),
         {:ok, conflict} <- lock_merge_conflict(repo, intent),
         {:ok, revision} <- next_revision(repo, intent.vault_id, intent.resource_id),
         {:ok, version} <-
           insert_resource_version(repo, intent, intent.resource_id, version_id, revision),
         {:ok, _snapshot} <-
           insert_note_version(
             repo,
             intent,
             intent.resource_id,
             version,
             resource.current_version_id,
             intent.competing_version_id
           ),
         :ok <- checkpoint(intent, :after_snapshot),
         :ok <- delete_projection(repo, intent),
         :ok <-
           update_head(
             repo,
             intent,
             version_id,
             intent.expected_current_version_id
           ),
         :ok <- checkpoint(intent, :after_head),
         :ok <- reconcile_projection(repo, intent),
         :ok <- checkpoint(intent, :after_projection),
         :ok <- resolve_conflict(repo, conflict, version_id),
         :ok <- checkpoint(intent, :after_conflict),
         {:ok, epochs} <- authorization_epochs(repo, intent.principal_id, intent.vault_id),
         :ok <-
           record_effects(
             repo,
             intent,
             intent.resource_id,
             version_id,
             revision,
             "note.merge",
             %{"version_id" => version_id, "conflict_id" => intent.conflict_id},
             [
               conflict_resolved_event(
                 intent.resource_id,
                 intent.conflict_id,
                 revision
               ),
               current_changed_event(intent.resource_id, revision)
             ],
             epochs
           ) do
      {:ok, %{outcome: "saved", resource_id: intent.resource_id, version_id: version_id}}
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset_error(changeset)}
      {:error, %Error{}} = error -> error
    end
  end

  defp insert_resource(repo, intent, resource_id, version_id) do
    %Resource{}
    |> Resource.create_changeset(%{
      id: resource_id,
      vault_id: intent.vault_id,
      classification: :private,
      kind: :note,
      current_version_id: version_id,
      title: intent.snapshot.title,
      metadata: %{}
    })
    |> repo.insert()
  end

  defp insert_resource_version(repo, intent, resource_id, version_id, revision) do
    %ResourceVersion{}
    |> ResourceVersion.create_changeset(%{
      id: version_id,
      resource_id: resource_id,
      vault_id: intent.vault_id,
      classification: :private,
      revision: revision
    })
    |> repo.insert()
  end

  defp insert_note_version(
         repo,
         intent,
         resource_id,
         version,
         parent_version_id,
         merge_parent_version_id \\ nil
       ) do
    %NoteVersion{}
    |> NoteVersion.create_changeset(%{
      resource_version_id: version.id,
      resource_id: resource_id,
      vault_id: intent.vault_id,
      classification: :private,
      title: intent.snapshot.title,
      markdown: intent.snapshot.markdown,
      created_by_principal_id: intent.principal_id,
      parent_version_id: parent_version_id,
      merge_parent_version_id: merge_parent_version_id,
      inserted_at: version.inserted_at
    })
    |> repo.insert()
  end

  defp insert_conflict(
         repo,
         intent,
         conflict_id,
         canonical_version_id,
         competing_version_id,
         created_at
       ) do
    %NoteConflict{}
    |> NoteConflict.create_changeset(%{
      id: conflict_id,
      resource_id: intent.resource_id,
      vault_id: intent.vault_id,
      classification: :private,
      base_version_id: intent.base_version_id,
      canonical_version_id: canonical_version_id,
      competing_version_id: competing_version_id,
      created_at: created_at
    })
    |> repo.insert()
  end

  defp lock_resource(repo, vault_id, resource_id) do
    query =
      from resource in Resource,
        where:
          resource.id == ^resource_id and
            resource.vault_id == ^vault_id and
            resource.kind == :note,
        lock: "FOR UPDATE"

    case repo.one(query) do
      nil -> {:error, Error.new(:not_found)}
      resource -> {:ok, resource}
    end
  end

  defp require_live(%Resource{deleted_at: nil}), do: :ok
  defp require_live(%Resource{deleted_at: %DateTime{}}), do: {:error, Error.new(:not_found)}

  defp require_expected_head(
         %Resource{current_version_id: expected_version_id},
         expected_version_id
       ),
       do: :ok

  defp require_expected_head(%Resource{}, _expected_version_id),
    do: {:error, Error.new(:conflict)}

  defp require_base(repo, intent) do
    query =
      from note in NoteVersion,
        where:
          note.resource_version_id == ^intent.base_version_id and
            note.classification == :private,
        select: %{resource_id: note.resource_id, vault_id: note.vault_id}

    case repo.one(query) do
      nil -> {:error, Error.new(:not_found)}
      %{vault_id: vault_id} when vault_id != intent.vault_id -> {:error, Error.new(:not_found)}
      %{resource_id: resource_id} when resource_id != intent.resource_id -> invalid()
      %{resource_id: _resource_id, vault_id: _vault_id} -> :ok
    end
  end

  defp lock_merge_conflict(repo, intent) do
    query =
      from conflict in NoteConflict,
        where:
          conflict.id == ^intent.conflict_id and
            conflict.vault_id == ^intent.vault_id and
            conflict.classification == :private,
        lock: "FOR UPDATE"

    case repo.one(query) do
      nil ->
        {:error, Error.new(:not_found)}

      %NoteConflict{resource_id: resource_id} when resource_id != intent.resource_id ->
        invalid()

      %NoteConflict{
        state: :open,
        competing_version_id: competing_version_id
      } = conflict
      when competing_version_id == intent.competing_version_id ->
        {:ok, conflict}

      %NoteConflict{} ->
        invalid()
    end
  end

  defp resolve_conflict(repo, conflict, resolution_version_id) do
    changeset =
      NoteConflict.resolve_changeset(conflict, %{
        resolution_version_id: resolution_version_id,
        resolved_at: DateTime.utc_now(:microsecond)
      })

    case repo.update(changeset) do
      {:ok, _conflict} -> :ok
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
    end
  end

  defp next_revision(repo, vault_id, resource_id) do
    case SafeSQL.query(
           repo,
           """
           SELECT COALESCE(max(revision), -1) + 1
           FROM content.resource_versions
           WHERE vault_id = $1 AND resource_id = $2
           """,
           [Ecto.UUID.dump!(vault_id), Ecto.UUID.dump!(resource_id)]
         ) do
      {:ok, %{rows: [[revision]]}} when is_integer(revision) and revision > 0 ->
        {:ok, revision}

      {:ok, _unexpected} ->
        {:error, Error.new(:integrity_failure)}

      {:error, _error} ->
        {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  defp update_head(repo, intent, version_id, expected_version_id) do
    query =
      from resource in Resource,
        where:
          resource.id == ^intent.resource_id and
            resource.vault_id == ^intent.vault_id and
            resource.kind == :note and
            is_nil(resource.deleted_at) and
            resource.current_version_id == ^expected_version_id

    case repo.update_all(query,
           set: [
             current_version_id: version_id,
             title: intent.snapshot.title,
             updated_at: DateTime.utc_now(:microsecond)
           ]
         ) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, Error.new(:conflict)}
      {_count, _rows} -> {:error, Error.new(:integrity_failure)}
    end
  end

  defp delete_projection(repo, intent) do
    NoteSearchStore.delete(repo, %{
      vault_id: intent.vault_id,
      resource_id: intent.resource_id
    })
  end

  defp reconcile_projection(repo, intent) do
    NoteProjectionReconciler.reconcile(repo, %{
      vault_id: intent.vault_id,
      resource_id: intent.resource_id
    })
  end

  defp authorization_epochs(repo, principal_id, vault_id) do
    case SafeSQL.query(
           repo,
           """
           SELECT principal_authorization_epoch, vault_authorization_epoch
           FROM core.live_principal_authorization()
           WHERE principal_id = $1 AND vault_id = $2
           """,
           [Ecto.UUID.dump!(principal_id), Ecto.UUID.dump!(vault_id)]
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

      {:ok, _unexpected} ->
        {:error, Error.new(:integrity_failure)}

      {:error, _error} ->
        {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  defp record_effects(repo, intent, resource_id, version_id, revision, operation, epochs) do
    record_effects(
      repo,
      intent,
      resource_id,
      version_id,
      revision,
      operation,
      %{"version_id" => version_id},
      [current_changed_event(resource_id, revision)],
      epochs
    )
  end

  defp record_effects(
         repo,
         intent,
         resource_id,
         _version_id,
         revision,
         operation,
         metadata,
         events,
         epochs
       ) do
    occurred_at = DateTime.utc_now(:microsecond)

    audit =
      AuditEvent.append_changeset(%AuditEvent{}, %{
        id: Ecto.UUID.generate(),
        vault_id: intent.vault_id,
        actor_kind: :principal,
        principal_id: intent.principal_id,
        operation: operation,
        result: :completed,
        classification: :private,
        correlation_id: intent.correlation_id,
        target_type: "note",
        target_id: resource_id,
        metadata: metadata,
        occurred_at: occurred_at
      })

    with {:ok, _audit} <- repo.insert(audit),
         :ok <- checkpoint(intent, :after_audit),
         :ok <- insert_outbox_events(repo, intent, events, revision, epochs, occurred_at) do
      :ok
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset_error(changeset)}
      {:error, %Error{}} = error -> error
    end
  end

  defp insert_outbox_events(repo, intent, events, revision, epochs, occurred_at) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      outbox =
        OutboxEvent.create_changeset(
          %OutboxEvent{},
          Map.merge(epochs, %{
            id: Ecto.UUID.generate(),
            event_type: event.event_type,
            idempotency_key: event.idempotency_key,
            vault_id: intent.vault_id,
            principal_id: intent.principal_id,
            required_capability: "note.write",
            classification: :private,
            correlation_id: intent.correlation_id,
            causation_id: intent.mutation_id,
            expected_entity_revision: revision,
            envelope_version: 1,
            payload: event.payload,
            occurred_at: occurred_at
          })
        )

      case repo.insert(outbox) do
        {:ok, _outbox} ->
          case checkpoint(intent, :after_outbox) do
            :ok -> {:cont, :ok}
            {:error, %Error{}} = error -> {:halt, error}
          end

        {:error, %Ecto.Changeset{} = changeset} ->
          {:halt, {:error, changeset_error(changeset)}}
      end
    end)
  end

  defp current_changed_event(resource_id, revision) do
    %{
      event_type: "note.current_changed",
      idempotency_key: "note-current-changed:#{resource_id}:#{revision}",
      payload: %{"resource_id" => resource_id}
    }
  end

  defp conflict_created_event(resource_id, conflict_id, revision) do
    %{
      event_type: "note.conflict_created",
      idempotency_key: "note-conflict-created:#{resource_id}:#{revision}",
      payload: %{"resource_id" => resource_id, "conflict_id" => conflict_id}
    }
  end

  defp conflict_resolved_event(resource_id, conflict_id, revision) do
    %{
      event_type: "note.conflict_resolved",
      idempotency_key: "note-conflict-resolved:#{resource_id}:#{revision}",
      payload: %{"resource_id" => resource_id, "conflict_id" => conflict_id}
    }
  end

  defp checkpoint(intent, name) do
    intent
    |> Map.get(:failure_injector, %{})
    |> Map.get(name, fn -> :ok end)
    |> then(fn callback -> callback.() end)
  end

  defp save_result(_repo, :create, {:ok, %{outcome: "saved"} = result}),
    do: saved_result(result)

  defp save_result(_repo, :save, {:ok, %{outcome: "saved"} = result}),
    do: saved_result(result)

  defp save_result(repo, :save, {:ok, %{outcome: "conflict"} = result}),
    do: conflict_result(repo, result)

  defp save_result(_repo, :merge, {:ok, %{outcome: "saved"} = result}),
    do: saved_result(result)

  defp save_result(_repo, _operation, _result), do: invalid()

  defp saved_result(result) do
    NoteSaveResult.saved(%{
      resource_id: result.resource_id,
      canonical_version_id: result.version_id,
      submitted_version_id: result.version_id
    })
  end

  defp conflict_result(repo, result) do
    query =
      from conflict in NoteConflict,
        where:
          conflict.id == ^result.conflict_id and
            conflict.resource_id == ^result.resource_id and
            conflict.competing_version_id == ^result.version_id,
        select: conflict.canonical_version_id

    case repo.one(query) do
      nil ->
        {:error, Error.new(:integrity_failure)}

      canonical_version_id ->
        NoteSaveResult.conflict(%{
          resource_id: result.resource_id,
          canonical_version_id: canonical_version_id,
          submitted_version_id: result.version_id,
          conflict_id: result.conflict_id
        })
    end
  end

  defp changeset_error(changeset) do
    cond do
      Enum.any?(changeset.errors, &constraint?(&1, :unique)) -> Error.new(:conflict)
      Enum.any?(changeset.errors, &constraint?(&1, :foreign)) -> Error.new(:not_found)
      true -> Error.new(:invalid)
    end
  end

  defp constraint?({_field, {_message, metadata}}, type), do: metadata[:constraint] == type

  defp database_error(%Ecto.Query.CastError{}), do: Error.new(:invalid)
  defp database_error(%Ecto.CastError{}), do: Error.new(:invalid)
  defp database_error(%Ecto.StaleEntryError{}), do: Error.new(:conflict)
  defp database_error(%Ecto.ConstraintError{type: :unique}), do: Error.new(:conflict)
  defp database_error(%Ecto.ConstraintError{}), do: Error.new(:invalid)

  defp database_error(%Postgrex.Error{postgres: %{code: :unique_violation}}),
    do: Error.new(:conflict)

  defp database_error(%Postgrex.Error{postgres: %{code: :foreign_key_violation}}),
    do: Error.new(:not_found)

  defp database_error(%Postgrex.Error{postgres: %{code: code}})
       when code in [
              :integrity_constraint_violation,
              :restrict_violation,
              :not_null_violation,
              :check_violation,
              :exclusion_violation,
              :invalid_text_representation
            ],
       do: Error.new(:invalid)

  defp database_error(_error), do: Error.new(:storage_unavailable, retryable?: true)
  defp invalid, do: {:error, Error.new(:invalid)}
end
