defmodule Singularity.Storage.NoteFixtures do
  @moduledoc false

  alias Ecto.Adapters.SQL
  alias Singularity.Storage.{Fixtures, MigrationRepo, RequestRepo, ScopedRepo}

  @uuid_fields ~w(
    account_id
    asset_id
    credential_id
    principal_id
    resource_id
    resource_version_id
    session_id
    vault_id
  )a

  def note! do
    %{one: fixture} = Fixtures.two_vaults!()
    create_note!(fixture)
  end

  def note_with_conflict! do
    note = note!()

    accepted =
      insert_note_version!(note, %{
        title: "Accepted fixture note",
        markdown: "# Accepted fixture note"
      })

    note = Map.put(note, :canonical_version_id, accepted.resource_version_id)

    scoped(note, RequestRepo, fn repo ->
      query!(
        repo,
        "DELETE FROM content.note_search_documents WHERE resource_id = $1",
        [dump!(note.resource_id)]
      )

      query!(
        repo,
        """
        UPDATE content.resources
        SET current_version_id = $1, title = $2, updated_at = CURRENT_TIMESTAMP
        WHERE id = $3
        """,
        [dump!(accepted.resource_version_id), accepted.title, dump!(note.resource_id)]
      )

      query!(
        repo,
        """
        INSERT INTO content.note_search_documents (
          resource_id,
          resource_version_id,
          vault_id,
          classification,
          title,
          markdown,
          head_inserted_at,
          updated_at
        ) VALUES ($1, $2, $3, 'private', $4, $5, $6, CURRENT_TIMESTAMP)
        """,
        [
          dump!(note.resource_id),
          dump!(accepted.resource_version_id),
          dump!(note.vault_id),
          accepted.title,
          accepted.markdown,
          accepted.inserted_at
        ]
      )
    end)

    competing =
      insert_note_version!(note, %{
        title: "Competing fixture note",
        markdown: "# Competing fixture note"
      })

    note = Map.put(note, :competing_version_id, competing.resource_version_id)
    conflict = insert_conflict!(note, %{})
    note = Map.put(note, :conflict_id, conflict.id)
    receipt = insert_receipt!(note, %{})

    Map.put(note, :mutation_id, receipt.mutation_id)
  end

  def two_notes! do
    %{one: one, two: two} = Fixtures.two_vaults!()
    %{one: create_note!(one), two: create_note!(two)}
  end

  def scoped(note, repo, fun) do
    ScopedRepo.transact(
      repo,
      %{principal_id: note.principal_id, vault_id: note.vault_id},
      fun
    )
  end

  def insert_note_version!(note, overrides) do
    attrs =
      Map.merge(
        %{
          resource_version_id: Ecto.UUID.generate(),
          resource_id: note.resource_id,
          vault_id: note.vault_id,
          classification: "private",
          title: "Fixture note revision",
          markdown: "# Fixture note revision",
          created_by_principal_id: note.principal_id,
          parent_version_id: note.initial_version_id,
          merge_parent_version_id: nil,
          inserted_at: DateTime.utc_now()
        },
        overrides
      )

    scoped(note, RequestRepo, fn repo ->
      %{rows: [[revision]]} =
        query!(
          repo,
          """
          SELECT COALESCE(max(revision), -1) + 1
          FROM content.resource_versions
          WHERE resource_id = $1
          """,
          [dump!(attrs.resource_id)]
        )

      query!(
        repo,
        """
        INSERT INTO content.resource_versions (
          id, resource_id, vault_id, classification, revision
        ) VALUES ($1, $2, $3, $4, $5)
        """,
        [
          dump!(attrs.resource_version_id),
          dump!(attrs.resource_id),
          dump!(attrs.vault_id),
          attrs.classification,
          revision
        ]
      )

      query!(
        repo,
        """
        INSERT INTO content.note_versions (
          resource_version_id,
          resource_id,
          vault_id,
          classification,
          title,
          markdown,
          created_by_principal_id,
          parent_version_id,
          merge_parent_version_id,
          inserted_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
        """,
        [
          dump!(attrs.resource_version_id),
          dump!(attrs.resource_id),
          dump!(attrs.vault_id),
          attrs.classification,
          attrs.title,
          attrs.markdown,
          dump!(attrs.created_by_principal_id),
          dump_nullable(attrs.parent_version_id),
          dump_nullable(attrs.merge_parent_version_id),
          attrs.inserted_at
        ]
      )

      query!(repo, "SET CONSTRAINTS content.note_versions_aggregate_check IMMEDIATE", [])

      attrs
    end)
  end

  def insert_conflict!(note, overrides) do
    attrs =
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          resource_id: note.resource_id,
          vault_id: note.vault_id,
          classification: "private",
          base_version_id: note.initial_version_id,
          canonical_version_id: note.canonical_version_id,
          competing_version_id: note.competing_version_id,
          state: "open",
          resolution_version_id: nil,
          created_at: DateTime.utc_now(),
          resolved_at: nil
        },
        overrides
      )

    scoped(note, RequestRepo, fn repo ->
      query!(
        repo,
        """
        INSERT INTO content.note_conflicts (
          id,
          resource_id,
          vault_id,
          classification,
          base_version_id,
          canonical_version_id,
          competing_version_id,
          state,
          resolution_version_id,
          created_at,
          resolved_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
        """,
        [
          dump!(attrs.id),
          dump!(attrs.resource_id),
          dump!(attrs.vault_id),
          attrs.classification,
          dump!(attrs.base_version_id),
          dump!(attrs.canonical_version_id),
          dump!(attrs.competing_version_id),
          attrs.state,
          dump_nullable(attrs.resolution_version_id),
          attrs.created_at,
          attrs.resolved_at
        ]
      )

      attrs
    end)
  end

  def insert_receipt!(note, overrides) do
    attrs =
      Map.merge(
        %{
          vault_id: note.vault_id,
          principal_id: note.principal_id,
          mutation_id: Ecto.UUID.generate(),
          operation: "save",
          request_fingerprint: :crypto.hash(:sha256, "fixture-note-mutation"),
          state: "completed",
          outcome: "conflict",
          resource_id: note.resource_id,
          version_id: note.competing_version_id,
          conflict_id: note.conflict_id,
          inserted_at: DateTime.utc_now()
        },
        overrides
      )

    scoped(note, RequestRepo, fn repo ->
      query!(
        repo,
        """
        INSERT INTO content.note_mutation_receipts (
          vault_id,
          principal_id,
          mutation_id,
          operation,
          request_fingerprint,
          state,
          outcome,
          resource_id,
          version_id,
          conflict_id,
          inserted_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
        """,
        [
          dump!(attrs.vault_id),
          dump!(attrs.principal_id),
          dump!(attrs.mutation_id),
          attrs.operation,
          attrs.request_fingerprint,
          attrs.state,
          attrs.outcome,
          dump!(attrs.resource_id),
          dump_nullable(attrs.version_id),
          dump_nullable(attrs.conflict_id),
          attrs.inserted_at
        ]
      )

      attrs
    end)
  end

  def note_version_attrs do
    %{
      resource_version_id: Ecto.UUID.generate(),
      resource_id: Ecto.UUID.generate(),
      vault_id: Ecto.UUID.generate(),
      classification: "private",
      title: "Fixture note",
      markdown: "# Fixture note",
      created_by_principal_id: Ecto.UUID.generate(),
      parent_version_id: nil,
      merge_parent_version_id: nil,
      inserted_at: DateTime.utc_now()
    }
  end

  def conflict_attrs do
    %{
      id: Ecto.UUID.generate(),
      resource_id: Ecto.UUID.generate(),
      vault_id: Ecto.UUID.generate(),
      classification: "private",
      base_version_id: Ecto.UUID.generate(),
      canonical_version_id: Ecto.UUID.generate(),
      competing_version_id: Ecto.UUID.generate(),
      state: "open",
      resolution_version_id: nil,
      created_at: DateTime.utc_now(),
      resolved_at: nil
    }
  end

  def search_document_attrs do
    %{
      resource_id: Ecto.UUID.generate(),
      resource_version_id: Ecto.UUID.generate(),
      vault_id: Ecto.UUID.generate(),
      classification: "private",
      title: "Fixture note",
      markdown: "# Fixture note",
      head_inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }
  end

  def receipt_attrs do
    %{
      vault_id: Ecto.UUID.generate(),
      principal_id: Ecto.UUID.generate(),
      mutation_id: Ecto.UUID.generate(),
      operation: "save",
      request_fingerprint: :crypto.hash(:sha256, "fixture-receipt"),
      state: "pending",
      outcome: nil,
      resource_id: Ecto.UUID.generate(),
      version_id: nil,
      conflict_id: nil,
      inserted_at: DateTime.utc_now()
    }
  end

  def grant_password_change!(note) do
    with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO core.capabilities (id, name)
        VALUES ($1, 'vault.password_change')
        ON CONFLICT (name) DO NOTHING
        """,
        [dump!(Ecto.UUID.generate())]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.principal_capabilities (
          principal_id, vault_id, capability_id
        )
        SELECT $1, $2, capability.id
        FROM core.capabilities AS capability
        WHERE capability.name = 'vault.password_change'
        ON CONFLICT (principal_id, vault_id, capability_id)
        DO UPDATE SET revoked_at = NULL
        """,
        [dump!(note.principal_id), dump!(note.vault_id)]
      )
    end)

    :ok
  end

  def cleanup_notes! do
    with_owner(fn ->
      query!(MigrationRepo, "SET CONSTRAINTS ALL DEFERRED", [])
      query!(MigrationRepo, "DELETE FROM content.note_mutation_receipts", [])
      query!(MigrationRepo, "DELETE FROM content.note_search_documents", [])
      query!(MigrationRepo, "DELETE FROM content.note_conflicts", [])
      query!(MigrationRepo, "DELETE FROM content.note_versions", [])

      query!(
        MigrationRepo,
        """
        DELETE FROM content.resource_versions AS version
        USING content.resources AS resource
        WHERE version.resource_id = resource.id
          AND resource.kind = 'note'
        """,
        []
      )

      query!(MigrationRepo, "DELETE FROM content.resources WHERE kind = 'note'", [])
    end)

    :ok
  end

  defp create_note!(raw_fixture) do
    fixture = load_ids(raw_fixture)
    resource_id = Ecto.UUID.generate()
    initial_version_id = Ecto.UUID.generate()
    title = "Fixture note #{System.unique_integer([:positive])}"
    markdown = "# #{title}"

    note =
      fixture
      |> Map.merge(%{
        resource_id: resource_id,
        initial_version_id: initial_version_id,
        title: title,
        markdown: markdown
      })

    scoped(note, RequestRepo, fn repo ->
      query!(repo, "SET CONSTRAINTS ALL DEFERRED", [])

      query!(
        repo,
        """
        INSERT INTO content.resources (
          id, vault_id, classification, title, kind, current_version_id
        ) VALUES ($1, $2, 'private', $3, 'note', $4)
        """,
        [dump!(resource_id), dump!(note.vault_id), title, dump!(initial_version_id)]
      )

      query!(
        repo,
        """
        INSERT INTO content.resource_versions (
          id, resource_id, vault_id, classification, revision
        ) VALUES ($1, $2, $3, 'private', 0)
        """,
        [dump!(initial_version_id), dump!(resource_id), dump!(note.vault_id)]
      )

      query!(
        repo,
        """
        INSERT INTO content.note_versions (
          resource_version_id,
          resource_id,
          vault_id,
          classification,
          title,
          markdown,
          created_by_principal_id,
          parent_version_id,
          merge_parent_version_id,
          inserted_at
        ) VALUES ($1, $2, $3, 'private', $4, $5, $6, NULL, NULL, CURRENT_TIMESTAMP)
        """,
        [
          dump!(initial_version_id),
          dump!(resource_id),
          dump!(note.vault_id),
          title,
          markdown,
          dump!(note.principal_id)
        ]
      )

      query!(
        repo,
        """
        INSERT INTO content.note_search_documents (
          resource_id,
          resource_version_id,
          vault_id,
          classification,
          title,
          markdown,
          head_inserted_at,
          updated_at
        ) VALUES ($1, $2, $3, 'private', $4, $5, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        """,
        [dump!(resource_id), dump!(initial_version_id), dump!(note.vault_id), title, markdown]
      )

      note
    end)
  end

  defp load_ids(fixture) do
    Map.new(fixture, fn
      {key, value} when key in @uuid_fields -> {key, Ecto.UUID.load!(value)}
      pair -> pair
    end)
  end

  defp dump!(uuid), do: Ecto.UUID.dump!(uuid)
  defp dump_nullable(nil), do: nil
  defp dump_nullable(uuid), do: dump!(uuid)

  defp with_owner(fun) do
    if Process.whereis(MigrationRepo) do
      {:ok, result} =
        MigrationRepo.transaction(fn ->
          query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner", [])
          fun.()
        end)

      result
    else
      Fixtures.with_owner(fun)
    end
  end

  defp query!(repo, statement, parameters) do
    SQL.query!(repo, statement, parameters, log: false)
  end
end
