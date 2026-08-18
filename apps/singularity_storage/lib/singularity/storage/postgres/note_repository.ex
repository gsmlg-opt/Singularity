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

  @cursor_version 1
  @cursor_secret_bytes 32
  @max_cursor_bytes 2_048

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
  def tombstone(repo, intent) when is_map(intent) do
    with :ok <- validate_tombstone(intent),
         {:ok, _stored} = result <-
           NoteMutationReceipts.with_claim(
             repo,
             Map.put(intent, :operation, :tombstone),
             fn -> persist_tombstone(repo, intent) end
           ),
         :ok <- checkpoint(intent, :after_receipt) do
      lifecycle_result(:tombstone, result, intent)
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

  def tombstone(_repo, _intent), do: invalid()

  @impl true
  def restore(repo, intent) when is_map(intent) do
    with :ok <- validate_restore(intent),
         {:ok, _stored} = result <-
           NoteMutationReceipts.with_claim(
             repo,
             Map.put(intent, :operation, :restore),
             fn -> persist_restore(repo, intent) end
           ),
         :ok <- checkpoint(intent, :after_receipt) do
      lifecycle_result(:restore, result, intent)
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

  def restore(_repo, _intent), do: invalid()

  def get(repo, vault_id, resource_id) do
    with :ok <- UUID.validate([vault_id, resource_id]),
         {:ok, note} <- load_canonical_note(repo, vault_id, resource_id, :live) do
      {:ok, note}
    end
  rescue
    error in [Ecto.Query.CastError, Ecto.CastError] -> {:error, database_error(error)}
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, database_error(error)}
  end

  def get_version(repo, vault_id, resource_id, version_id) do
    with :ok <- UUID.validate([vault_id, resource_id, version_id]),
         {:ok, version} <- load_exact_version(repo, vault_id, version_id),
         :ok <- classify_resource(version.resource_id, resource_id),
         nil <- version.deleted_at do
      {:ok, Map.delete(version, :deleted_at)}
    else
      %DateTime{} -> {:error, Error.new(:not_found)}
      {:error, %Error{}} = error -> error
    end
  rescue
    error in [Ecto.Query.CastError, Ecto.CastError] -> {:error, database_error(error)}
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, database_error(error)}
  end

  def get_conflict(repo, vault_id, resource_id, conflict_id) do
    with :ok <- UUID.validate([vault_id, resource_id, conflict_id]),
         {:ok, conflict} <- load_conflict(repo, vault_id, conflict_id),
         :ok <- classify_resource(conflict.resource_id, resource_id),
         {:ok, current} <- get(repo, vault_id, resource_id),
         {:ok, competing} <-
           get_version(repo, vault_id, resource_id, conflict.competing_version_id) do
      {:ok,
       %{
         conflict: conflict,
         current: current,
         competing: competing
       }}
    end
  end

  def history(repo, vault_id, resource_id, params) do
    with :ok <- UUID.validate([vault_id, resource_id]),
         {:ok, page} <- validate_page_params(params),
         {:ok, current_version_id} <- lock_live_history_resource(repo, vault_id, resource_id),
         {:ok, cursor_secret} <- cursor_secret(),
         {:ok, cursor} <-
           decode_page_cursor(
             page.cursor,
             "note-history-cursor",
             [vault_id, resource_id],
             cursor_secret
           ) do
      rows =
        history_rows(
          repo,
          vault_id,
          resource_id,
          current_version_id,
          cursor,
          page.limit + 1
        )

      page_result(
        rows,
        page.limit,
        "note-history-cursor",
        [vault_id, resource_id],
        cursor_secret,
        fn row -> [row.revision, row.resource_version_id] end
      )
    end
  rescue
    error in [Ecto.Query.CastError, Ecto.CastError] -> {:error, database_error(error)}
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, database_error(error)}
  end

  def trash(repo, vault_id, params) do
    with :ok <- UUID.validate(vault_id),
         {:ok, page} <- validate_page_params(params),
         {:ok, cursor_secret} <- cursor_secret(),
         {:ok, cursor} <-
           decode_page_cursor(page.cursor, "note-trash-cursor", [vault_id], cursor_secret) do
      rows = trash_rows(repo, vault_id, cursor, page.limit + 1)

      page_result(
        rows,
        page.limit,
        "note-trash-cursor",
        [vault_id],
        cursor_secret,
        fn row -> [DateTime.to_iso8601(row.deleted_at), row.resource_id] end
      )
    end
  rescue
    error in [Ecto.Query.CastError, Ecto.CastError] -> {:error, database_error(error)}
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, database_error(error)}
  end

  defp load_canonical_note(repo, vault_id, resource_id, state) do
    state_clause =
      if state == :live,
        do: "resource.deleted_at IS NULL",
        else: "resource.deleted_at IS NOT NULL"

    case SafeSQL.query(
           repo,
           """
           SELECT resource.id, version.id, resource.vault_id, resource.classification,
                  note.title, note.markdown, version.revision, resource.updated_at,
                  resource.deleted_at, note.created_by_principal_id, version.inserted_at,
                  note.parent_version_id, note.merge_parent_version_id,
                  (
                    SELECT count(*)
                    FROM content.note_conflicts AS conflict
                    WHERE conflict.resource_id = resource.id
                      AND conflict.vault_id = resource.vault_id
                      AND conflict.state = 'open'
                  )
           FROM content.resources AS resource
           JOIN content.resource_versions AS version
             ON version.id = resource.current_version_id
            AND version.resource_id = resource.id
            AND version.vault_id = resource.vault_id
            AND version.classification = resource.classification
           JOIN content.note_versions AS note
             ON note.resource_version_id = version.id
            AND note.resource_id = version.resource_id
            AND note.vault_id = version.vault_id
            AND note.classification = version.classification
           WHERE resource.id = $1
             AND resource.vault_id = $2
             AND resource.kind = 'note'
             AND resource.classification = 'private'
             AND #{state_clause}
           """,
           [Ecto.UUID.dump!(resource_id), Ecto.UUID.dump!(vault_id)]
         ) do
      {:ok, %{rows: [row]}} -> {:ok, note_row(row)}
      {:ok, %{rows: []}} -> {:error, Error.new(:not_found)}
      {:ok, _unexpected} -> {:error, Error.new(:integrity_failure)}
      {:error, error} -> {:error, database_error(error)}
    end
  end

  defp note_row([
         resource_id,
         version_id,
         vault_id,
         "private",
         title,
         markdown,
         revision,
         updated_at,
         deleted_at,
         principal_id,
         inserted_at,
         parent_id,
         merge_parent_id,
         open_conflict_count
       ]) do
    %{
      resource_id: load_uuid(resource_id),
      resource_version_id: load_uuid(version_id),
      vault_id: load_uuid(vault_id),
      classification: :private,
      title: title,
      markdown: markdown,
      revision: revision,
      updated_at: updated_at,
      deleted_at: deleted_at,
      deleted?: not is_nil(deleted_at),
      created_by_principal_id: load_uuid(principal_id),
      inserted_at: inserted_at,
      parent_version_id: load_optional_uuid(parent_id),
      merge_parent_version_id: load_optional_uuid(merge_parent_id),
      canonical?: true,
      open_conflict_count: open_conflict_count
    }
  end

  defp load_exact_version(repo, vault_id, version_id) do
    case SafeSQL.query(
           repo,
           """
           SELECT resource.id, version.id, resource.vault_id, resource.classification,
                  note.title, note.markdown, version.revision, resource.deleted_at,
                  note.created_by_principal_id, version.inserted_at,
                  note.parent_version_id, note.merge_parent_version_id,
                  resource.current_version_id = version.id,
                  (
                    SELECT conflict.state
                    FROM content.note_conflicts AS conflict
                    WHERE conflict.competing_version_id = version.id
                      AND conflict.resource_id = resource.id
                      AND conflict.vault_id = resource.vault_id
                    ORDER BY conflict.created_at DESC
                    LIMIT 1
                  )
           FROM content.resource_versions AS version
           JOIN content.resources AS resource
             ON resource.id = version.resource_id
            AND resource.vault_id = version.vault_id
            AND resource.classification = version.classification
           JOIN content.note_versions AS note
             ON note.resource_version_id = version.id
            AND note.resource_id = version.resource_id
            AND note.vault_id = version.vault_id
            AND note.classification = version.classification
           WHERE version.id = $1
             AND version.vault_id = $2
             AND resource.kind = 'note'
             AND resource.classification = 'private'
           """,
           [Ecto.UUID.dump!(version_id), Ecto.UUID.dump!(vault_id)]
         ) do
      {:ok, %{rows: [row]}} -> {:ok, exact_version_row(row)}
      {:ok, %{rows: []}} -> {:error, Error.new(:not_found)}
      {:ok, _unexpected} -> {:error, Error.new(:integrity_failure)}
      {:error, error} -> {:error, database_error(error)}
    end
  end

  defp exact_version_row([
         resource_id,
         version_id,
         vault_id,
         "private",
         title,
         markdown,
         revision,
         deleted_at,
         principal_id,
         inserted_at,
         parent_id,
         merge_parent_id,
         canonical?,
         conflict_state
       ]) do
    %{
      resource_id: load_uuid(resource_id),
      resource_version_id: load_uuid(version_id),
      vault_id: load_uuid(vault_id),
      classification: :private,
      title: title,
      markdown: markdown,
      revision: revision,
      deleted_at: deleted_at,
      created_by_principal_id: load_uuid(principal_id),
      inserted_at: inserted_at,
      parent_version_id: load_optional_uuid(parent_id),
      merge_parent_version_id: load_optional_uuid(merge_parent_id),
      canonical?: canonical?,
      conflict_state: conflict_state && String.to_existing_atom(conflict_state)
    }
  end

  defp load_conflict(repo, vault_id, conflict_id) do
    case SafeSQL.query(
           repo,
           """
           SELECT id, resource_id, vault_id, classification, base_version_id,
                  canonical_version_id, competing_version_id, state,
                  resolution_version_id, created_at, resolved_at
           FROM content.note_conflicts
           WHERE id = $1 AND vault_id = $2 AND classification = 'private'
           """,
           [Ecto.UUID.dump!(conflict_id), Ecto.UUID.dump!(vault_id)]
         ) do
      {:ok,
       %{
         rows: [
           [
             id,
             resource_id,
             vault_id,
             "private",
             base_id,
             canonical_id,
             competing_id,
             state,
             resolution_id,
             created_at,
             resolved_at
           ]
         ]
       }} ->
        {:ok,
         %{
           conflict_id: load_uuid(id),
           resource_id: load_uuid(resource_id),
           vault_id: load_uuid(vault_id),
           classification: :private,
           base_version_id: load_uuid(base_id),
           observed_canonical_version_id: load_uuid(canonical_id),
           competing_version_id: load_uuid(competing_id),
           state: String.to_existing_atom(state),
           resolution_version_id: load_optional_uuid(resolution_id),
           created_at: created_at,
           resolved_at: resolved_at
         }}

      {:ok, %{rows: []}} ->
        {:error, Error.new(:not_found)}

      {:ok, _unexpected} ->
        {:error, Error.new(:integrity_failure)}

      {:error, error} ->
        {:error, database_error(error)}
    end
  end

  defp classify_resource(resource_id, resource_id), do: :ok
  defp classify_resource(_stored_resource_id, _requested_resource_id), do: invalid()

  defp validate_page_params(%{limit: limit, cursor: cursor} = params)
       when map_size(params) == 2 and is_integer(limit) and limit in 1..50 do
    if is_nil(cursor) or
         (is_binary(cursor) and byte_size(cursor) <= @max_cursor_bytes and
            String.valid?(cursor) and String.trim(cursor) != "" and
            :binary.match(cursor, <<0>>) == :nomatch) do
      {:ok, params}
    else
      invalid()
    end
  end

  defp validate_page_params(_params), do: invalid()

  defp lock_live_history_resource(repo, vault_id, resource_id) do
    query =
      from resource in Resource,
        where:
          resource.id == ^resource_id and resource.vault_id == ^vault_id and
            resource.kind == :note and resource.classification == :private and
            is_nil(resource.deleted_at),
        lock: "FOR SHARE",
        select: resource.current_version_id

    case repo.one(query) do
      nil -> {:error, Error.new(:not_found)}
      current_version_id -> {:ok, current_version_id}
    end
  end

  defp history_rows(repo, vault_id, resource_id, current_id, cursor, limit) do
    {cursor_revision, cursor_id} =
      case cursor do
        nil -> {nil, nil}
        [revision, version_id] -> {revision, version_id}
      end

    query =
      from version in ResourceVersion,
        join: note in NoteVersion,
        on:
          note.resource_version_id == version.id and
            note.resource_id == version.resource_id and
            note.vault_id == version.vault_id and
            note.classification == version.classification,
        where:
          version.resource_id == ^resource_id and version.vault_id == ^vault_id and
            version.classification == :private,
        order_by: [desc: version.revision, asc: version.id],
        limit: ^limit,
        select: %{
          resource_version_id: version.id,
          revision: version.revision,
          created_by_principal_id: note.created_by_principal_id,
          inserted_at: version.inserted_at,
          parent_version_id: note.parent_version_id,
          merge_parent_version_id: note.merge_parent_version_id,
          canonical?: false,
          conflict_state:
            fragment(
              "(SELECT state FROM content.note_conflicts WHERE competing_version_id = ? AND resource_id = ? AND vault_id = ? ORDER BY created_at DESC LIMIT 1)",
              version.id,
              version.resource_id,
              version.vault_id
            )
        }

    query =
      if is_nil(cursor) do
        query
      else
        from [version, _note] in query,
          where:
            version.revision < ^cursor_revision or
              (version.revision == ^cursor_revision and version.id > ^cursor_id)
      end

    query
    |> repo.all()
    |> Enum.map(fn row ->
      row
      |> Map.update!(:created_by_principal_id, & &1)
      |> Map.update!(:conflict_state, fn
        nil -> nil
        state when is_atom(state) -> state
        state -> String.to_existing_atom(state)
      end)
      |> Map.put(:canonical?, row.resource_version_id == current_id)
    end)
  end

  defp trash_rows(repo, vault_id, cursor, limit) do
    {cursor_deleted_at, cursor_id} =
      case cursor do
        nil ->
          {nil, nil}

        [deleted_at, resource_id] ->
          {:ok, parsed, 0} = DateTime.from_iso8601(deleted_at)
          {parsed, resource_id}
      end

    query =
      from resource in Resource,
        join: version in ResourceVersion,
        on:
          version.id == resource.current_version_id and
            version.resource_id == resource.id and
            version.vault_id == resource.vault_id,
        join: note in NoteVersion,
        on:
          note.resource_version_id == version.id and
            note.resource_id == version.resource_id and
            note.vault_id == version.vault_id,
        where:
          resource.vault_id == ^vault_id and resource.kind == :note and
            resource.classification == :private and not is_nil(resource.deleted_at),
        order_by: [desc: resource.deleted_at, asc: resource.id],
        limit: ^limit,
        select: %{
          resource_id: resource.id,
          resource_version_id: version.id,
          vault_id: resource.vault_id,
          classification: :private,
          title: resource.title,
          revision: version.revision,
          deleted_at: resource.deleted_at,
          updated_at: resource.updated_at,
          deleted?: true,
          open_conflict_count:
            fragment(
              "(SELECT count(*) FROM content.note_conflicts WHERE resource_id = ? AND vault_id = ? AND state = 'open')",
              resource.id,
              resource.vault_id
            )
        }

    query =
      if is_nil(cursor) do
        query
      else
        from [resource, _version, _note] in query,
          where:
            resource.deleted_at < ^cursor_deleted_at or
              (resource.deleted_at == ^cursor_deleted_at and resource.id > ^cursor_id)
      end

    repo.all(query)
  end

  defp page_result(rows, limit, label, filters, cursor_secret, ordering) do
    items = Enum.take(rows, limit)

    next_cursor =
      if length(rows) > limit do
        encode_page_cursor(List.last(items), label, filters, cursor_secret, ordering)
      else
        :done
      end

    {:ok, %{items: items, next_cursor: next_cursor}}
  end

  defp encode_page_cursor(item, label, filters, secret, ordering) do
    data = %{
      "v" => @cursor_version,
      "f" => page_fingerprint(label, filters),
      "d" => ordering.(item)
    }

    data
    |> Map.put("h", page_integrity(label, data, secret))
    |> JSON.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp decode_page_cursor(nil, _label, _filters, _secret), do: {:ok, nil}

  defp decode_page_cursor(cursor, label, filters, secret) do
    with {:ok, encoded} <- Base.url_decode64(cursor, padding: false),
         {:ok, data} <- JSON.decode(encoded),
         true <- Enum.sort(Map.keys(data)) == ~w[d f h v],
         true <- data["v"] == @cursor_version,
         true <- data["f"] == page_fingerprint(label, filters),
         true <- is_list(data["d"]) and length(data["d"]) == 2,
         true <- secure_compare(data["h"], page_integrity(label, Map.delete(data, "h"), secret)) do
      {:ok, data["d"]}
    else
      _invalid -> invalid()
    end
  rescue
    _error -> invalid()
  end

  defp page_fingerprint(label, filters) do
    [label | filters]
    |> Enum.intersperse(<<0>>)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp page_integrity(label, data, secret) do
    :crypto.mac(:hmac, :sha256, secret, [label, <<0>>, JSON.encode!(data)])
    |> Base.url_encode64(padding: false)
  end

  defp cursor_secret do
    case Application.fetch_env(:singularity_runtime, :audit_fingerprint_secret) do
      {:ok, secret} when is_binary(secret) and byte_size(secret) >= @cursor_secret_bytes ->
        {:ok, secret}

      _invalid ->
        invalid()
    end
  end

  defp secure_compare(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_compare(_left, _right), do: false

  defp load_uuid(uuid), do: Ecto.UUID.load!(uuid)
  defp load_optional_uuid(nil), do: nil
  defp load_optional_uuid(uuid), do: load_uuid(uuid)

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

  defp validate_tombstone(
         %{
           resource_id: resource_id,
           expected_current_version_id: expected_current_version_id
         } = intent
       ) do
    with :ok <- validate_common(intent),
         :ok <- UUID.validate([resource_id, expected_current_version_id]) do
      :ok
    end
  end

  defp validate_tombstone(_intent), do: invalid()

  defp validate_restore(%{resource_id: resource_id} = intent) do
    with :ok <- validate_common(intent),
         :ok <- UUID.validate(resource_id) do
      :ok
    end
  end

  defp validate_restore(_intent), do: invalid()

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

  defp persist_tombstone(repo, intent) do
    with {:ok, resource} <- lock_resource(repo, intent.vault_id, intent.resource_id),
         :ok <- checkpoint(intent, :after_resource_lock),
         :ok <- require_state(resource, :live),
         :ok <- require_expected_head(resource, intent.expected_current_version_id),
         {:ok, revision} <-
           current_revision(
             repo,
             intent.vault_id,
             intent.resource_id,
             resource.current_version_id
           ),
         :ok <-
           set_deleted_at(
             repo,
             intent,
             resource.current_version_id,
             DateTime.utc_now(:microsecond)
           ),
         :ok <- checkpoint(intent, :after_head),
         :ok <- reconcile_projection(repo, intent),
         :ok <- checkpoint(intent, :after_projection),
         {:ok, epochs} <- authorization_epochs(repo, intent.principal_id, intent.vault_id),
         :ok <-
           record_effects(
             repo,
             intent,
             intent.resource_id,
             resource.current_version_id,
             revision,
             "note.delete",
             %{"version_id" => resource.current_version_id},
             [lifecycle_event("note.deleted", intent.resource_id, intent.mutation_id)],
             epochs
           ) do
      {:ok, %{outcome: "tombstoned", resource_id: intent.resource_id}}
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset_error(changeset)}
      {:error, %Error{}} = error -> error
    end
  end

  defp persist_restore(repo, intent) do
    with {:ok, resource} <- lock_resource(repo, intent.vault_id, intent.resource_id),
         :ok <- checkpoint(intent, :after_resource_lock),
         :ok <- require_state(resource, :tombstoned),
         {:ok, revision} <-
           current_revision(
             repo,
             intent.vault_id,
             intent.resource_id,
             resource.current_version_id
           ),
         :ok <- set_deleted_at(repo, intent, resource.current_version_id, nil),
         :ok <- checkpoint(intent, :after_head),
         :ok <- reconcile_projection(repo, intent),
         :ok <- checkpoint(intent, :after_projection),
         {:ok, epochs} <- authorization_epochs(repo, intent.principal_id, intent.vault_id),
         :ok <-
           record_effects(
             repo,
             intent,
             intent.resource_id,
             resource.current_version_id,
             revision,
             "note.restore",
             %{"version_id" => resource.current_version_id},
             [lifecycle_event("note.restored", intent.resource_id, intent.mutation_id)],
             epochs
           ) do
      {:ok,
       %{
         outcome: "restored",
         resource_id: intent.resource_id,
         version_id: resource.current_version_id
       }}
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

  defp require_state(%Resource{deleted_at: nil}, :live), do: :ok
  defp require_state(%Resource{deleted_at: %DateTime{}}, :tombstoned), do: :ok
  defp require_state(%Resource{}, _state), do: {:error, Error.new(:not_found)}

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

  defp current_revision(repo, vault_id, resource_id, version_id) do
    case SafeSQL.query(
           repo,
           """
           SELECT revision
           FROM content.resource_versions
           WHERE id = $1 AND resource_id = $2 AND vault_id = $3
           """,
           [
             Ecto.UUID.dump!(version_id),
             Ecto.UUID.dump!(resource_id),
             Ecto.UUID.dump!(vault_id)
           ]
         ) do
      {:ok, %{rows: [[revision]]}} when is_integer(revision) and revision >= 0 ->
        {:ok, revision}

      {:ok, %{rows: []}} ->
        {:error, Error.new(:not_found)}

      {:ok, _unexpected} ->
        {:error, Error.new(:integrity_failure)}

      {:error, error} ->
        {:error, database_error(error)}
    end
  end

  defp set_deleted_at(repo, intent, expected_version_id, deleted_at) do
    query =
      from resource in Resource,
        where:
          resource.id == ^intent.resource_id and
            resource.vault_id == ^intent.vault_id and
            resource.kind == :note and
            resource.current_version_id == ^expected_version_id

    case repo.update_all(query,
           set: [deleted_at: deleted_at, updated_at: DateTime.utc_now(:microsecond)]
         ) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, Error.new(:conflict)}
      {_count, _rows} -> {:error, Error.new(:integrity_failure)}
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

  defp lifecycle_event(event_type, resource_id, mutation_id) do
    %{
      event_type: event_type,
      idempotency_key: "#{String.replace(event_type, ".", "-")}:#{resource_id}:#{mutation_id}",
      payload: %{"resource_id" => resource_id}
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

  defp lifecycle_result(
         :tombstone,
         {:ok, %{outcome: "tombstoned", resource_id: resource_id}},
         intent
       ) do
    {:ok,
     %{
       state: :tombstoned,
       resource_id: resource_id,
       canonical_version_id: intent.expected_current_version_id
     }}
  end

  defp lifecycle_result(
         :restore,
         {:ok, %{outcome: "restored", resource_id: resource_id, version_id: version_id}},
         _intent
       ) do
    {:ok,
     %{
       state: :restored,
       resource_id: resource_id,
       canonical_version_id: version_id
     }}
  end

  defp lifecycle_result(_operation, _result, _intent), do: invalid()

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
