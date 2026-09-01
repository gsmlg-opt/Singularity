defmodule Singularity.Storage.NoteSchemaTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  import ExUnit.CaptureLog

  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.NoteFixtures
  alias Singularity.Storage.Postgres.NoteCapabilityReconciler

  @tables ~w(note_conflicts note_mutation_receipts note_search_documents note_versions)

  @constraints ~w(
    resources_kind_check
    resources_note_head_check
    resources_id_vault_classification_key
    resources_head_vault_classification_key
    resources_note_version_head_fkey
    resource_versions_identity_aggregate_key
    resource_versions_resource_classification_fkey
    note_versions_pkey
    note_versions_private_check
    note_versions_title_check
    note_versions_markdown_check
    note_versions_parent_shape_check
    note_versions_merge_parents_distinct_check
    note_versions_identity_aggregate_key
    note_versions_resource_version_fkey
    note_versions_parent_fkey
    note_versions_merge_parent_fkey
    note_versions_created_by_principal_fkey
    note_versions_receipt_identity_key
    note_conflicts_pkey
    note_conflicts_private_check
    note_conflicts_state_check
    note_conflicts_lineage_distinct_check
    note_conflicts_resolution_shape_check
    note_conflicts_resolution_distinct_check
    note_conflicts_base_version_fkey
    note_conflicts_canonical_version_fkey
    note_conflicts_competing_version_fkey
    note_conflicts_resolution_version_fkey
    note_conflicts_receipt_identity_key
    note_search_documents_pkey
    note_search_documents_private_check
    note_search_documents_title_check
    note_search_documents_markdown_check
    note_search_documents_resource_head_fkey
    note_search_documents_note_version_fkey
    note_mutation_receipts_pkey
    note_mutation_receipts_operation_check
    note_mutation_receipts_fingerprint_check
    note_mutation_receipts_state_check
    note_mutation_receipts_result_shape_check
    note_mutation_receipts_membership_fkey
    note_mutation_receipts_resource_fkey
    note_mutation_receipts_version_fkey
    note_mutation_receipts_conflict_fkey
  )

  @indexes ~w(
    note_conflicts_resource_idx
    note_conflicts_open_idx
    note_conflicts_history_idx
    note_search_documents_vector_index
    note_search_documents_vault_head
    note_mutation_receipts_principal_history
    note_mutation_receipts_pending
    resource_versions_note_history
    resources_note_trash
  )

  @conflict_export_columns ~w[
    id resource_id vault_id classification base_version_id canonical_version_id
    competing_version_id state resolution_version_id created_at resolved_at
  ]

  test "creates the exact note columns, defaults, generated vector, and indexes" do
    assert column!("content", "resources", "kind") == {"text", false, "'asset'::text", ""}
    assert column!("content", "resources", "current_version_id") == {"uuid", true, nil, ""}

    assert columns!("content", "note_versions") == [
             ["resource_version_id", "uuid", false],
             ["resource_id", "uuid", false],
             ["vault_id", "uuid", false],
             ["classification", "text", false],
             ["title", "text", false],
             ["markdown", "text", false],
             ["created_by_principal_id", "uuid", false],
             ["parent_version_id", "uuid", true],
             ["merge_parent_version_id", "uuid", true],
             ["inserted_at", "timestamp(6) with time zone", false]
           ]

    assert columns!("content", "note_conflicts") == [
             ["id", "uuid", false],
             ["resource_id", "uuid", false],
             ["vault_id", "uuid", false],
             ["classification", "text", false],
             ["base_version_id", "uuid", false],
             ["canonical_version_id", "uuid", false],
             ["competing_version_id", "uuid", false],
             ["state", "text", false],
             ["resolution_version_id", "uuid", true],
             ["created_at", "timestamp(6) with time zone", false],
             ["resolved_at", "timestamp(6) with time zone", true]
           ]

    assert columns!("content", "note_search_documents") == [
             ["resource_id", "uuid", false],
             ["resource_version_id", "uuid", false],
             ["vault_id", "uuid", false],
             ["classification", "text", false],
             ["title", "text", false],
             ["markdown", "text", false],
             ["head_inserted_at", "timestamp(6) with time zone", false],
             ["search_vector", "tsvector", true],
             ["updated_at", "timestamp(6) with time zone", false]
           ]

    assert columns!("content", "note_mutation_receipts") == [
             ["vault_id", "uuid", false],
             ["principal_id", "uuid", false],
             ["mutation_id", "uuid", false],
             ["operation", "text", false],
             ["request_fingerprint", "bytea", false],
             ["state", "text", false],
             ["outcome", "text", true],
             ["resource_id", "uuid", false],
             ["version_id", "uuid", true],
             ["conflict_id", "uuid", true],
             ["inserted_at", "timestamp(6) with time zone", false]
           ]

    assert {"tsvector", true, vector_expression, "s"} =
             column!("content", "note_search_documents", "search_vector")

    assert vector_expression =~ "to_tsvector('simple'::regconfig"

    for {table, column} <- [
          {"note_versions", "inserted_at"},
          {"note_conflicts", "created_at"},
          {"note_search_documents", "updated_at"},
          {"note_mutation_receipts", "inserted_at"}
        ] do
      assert {_type, false, "CURRENT_TIMESTAMP", ""} = column!("content", table, column)
    end

    assert catalog_names("pg_catalog.pg_indexes", "indexname", @indexes) == Enum.sort(@indexes)
  end

  test "installs every named aggregate, note, conflict, search, and receipt constraint" do
    assert catalog_names("pg_catalog.pg_constraint", "conname", @constraints) ==
             Enum.sort(@constraints)

    assert constraint_definition!("resources_note_version_head_fkey") =~
             "DEFERRABLE INITIALLY DEFERRED"

    assert constraint_definition!("resource_versions_resource_classification_fkey") =~
             "DEFERRABLE INITIALLY DEFERRED"

    assert constraint_definition!("note_versions_parent_fkey") =~
             "DEFERRABLE INITIALLY DEFERRED"

    assert constraint_definition!("note_versions_merge_parent_fkey") =~
             "DEFERRABLE INITIALLY DEFERRED"

    for constraint <- ~w(
          note_mutation_receipts_resource_fkey
          note_mutation_receipts_version_fkey
          note_mutation_receipts_conflict_fkey
        ) do
      assert constraint_definition!(constraint) =~ "DEFERRABLE INITIALLY DEFERRED"
    end

    assert %{rows: trigger_rows} =
             query!(
               RequestRepo,
               """
               SELECT trigger.tgname, trigger.tgdeferrable, trigger.tginitdeferred
               FROM pg_trigger AS trigger
               WHERE trigger.tgname = ANY($1)
                 AND NOT trigger.tgisinternal
               ORDER BY trigger.tgname
               """,
               [
                 [
                   "note_versions_aggregate_check",
                   "note_mutation_receipts_resource_check",
                   "resource_versions_note_identity_immutable",
                   "resources_note_kind_immutable"
                 ]
               ]
             )

    assert trigger_rows == [
             ["note_mutation_receipts_resource_check", true, true],
             ["note_versions_aggregate_check", true, true],
             ["resource_versions_note_identity_immutable", false, false],
             ["resources_note_kind_immutable", false, false]
           ]
  end

  test "forces RLS and creates owner plus vault policies on every note table" do
    for table <- @tables do
      assert %{rows: [[true, true]]} =
               query!(
                 RequestRepo,
                 "SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE oid = to_regclass($1)",
                 ["content.#{table}"]
               )

      assert %{rows: policies} =
               query!(
                 RequestRepo,
                 "SELECT policyname FROM pg_policies WHERE schemaname = 'content' AND tablename = $1 ORDER BY policyname",
                 [table]
               )

      assert policies == [["#{table}_table_owner"], ["#{table}_vault_isolation"]]
    end
  end

  test "backup worker exports only authorized own-vault conflicts through the hardened function" do
    note = NoteFixtures.note_with_conflict!()
    second_conflict = NoteFixtures.insert_conflict!(note, %{id: Ecto.UUID.generate()})
    cross_vault = NoteFixtures.note_with_conflict!()

    assert %{columns: @conflict_export_columns, rows: []} =
             query!(
               WorkerRepo,
               "SELECT * FROM content.export_note_conflicts_for_backup($1)",
               [Ecto.UUID.dump!(note.vault_id)]
             )

    capture_log(fn ->
      assert_raise Postgrex.Error, fn ->
        Singularity.Storage.ScopedRepo.transact(
          WorkerRepo,
          %{principal_id: note.principal_id, vault_id: note.vault_id},
          fn repo -> query!(repo, "SELECT * FROM content.note_conflicts") end
        )
      end
    end)

    grant_backup_create!(note)

    assert_raise Postgrex.Error, fn ->
      NoteFixtures.scoped(note, RequestRepo, fn repo ->
        query!(repo, "SELECT * FROM content.export_note_conflicts_for_backup($1)", [
          Ecto.UUID.dump!(note.vault_id)
        ])
      end)
    end

    assert %{columns: @conflict_export_columns, rows: rows} =
             export_conflicts(note, note.vault_id)

    assert length(rows) == 2

    assert Enum.map(rows, fn [id | _columns] -> Ecto.UUID.load!(id) end) ==
             Enum.sort([note.conflict_id, second_conflict.id])

    assert Enum.all?(rows, fn row ->
             length(row) == 11 and Enum.at(row, 2) == Ecto.UUID.dump!(note.vault_id) and
               Enum.at(row, 3) == "private"
           end)

    assert %{rows: []} = export_conflicts(note, cross_vault.vault_id)
    refute Enum.any?(rows, fn [id | _rest] -> id == Ecto.UUID.dump!(cross_vault.conflict_id) end)

    revoke_backup_create!(note)
    assert %{rows: []} = export_conflicts(note, note.vault_id)
    grant_backup_create!(note)

    for state <- [:revoked_principal, :revoked_membership, :inactive_account] do
      set_backup_export_authority_state!(note, state)
      assert %{rows: []} = export_conflicts(note, note.vault_id)
      reset_backup_export_authority_state!(note, state)
    end
  end

  test "database rejects asset heads, classification mismatches, invalid lineage, and invalid receipts" do
    %{one: asset} = Fixtures.two_vaults!()

    capture_log(fn ->
      assert_raise Postgrex.Error, fn ->
        Fixtures.with_owner(fn ->
          query!(
            MigrationRepo,
            "UPDATE content.resources SET kind = 'note', current_version_id = $1 WHERE id = $2",
            [asset.resource_version_id, asset.resource_id]
          )
        end)
      end
    end)

    assert_constraint(fn ->
      Singularity.Storage.ScopedRepo.transact(
        RequestRepo,
        %{principal_id: asset.principal_id, vault_id: asset.vault_id},
        fn repo ->
          query!(
            repo,
            """
            INSERT INTO content.note_versions (
              resource_version_id, resource_id, vault_id, classification,
              title, markdown, created_by_principal_id,
              parent_version_id, merge_parent_version_id
            ) VALUES ($1, $2, $3, 'private', 'Asset snapshot', '# Asset', $4, NULL, NULL)
            """,
            [
              asset.resource_version_id,
              asset.resource_id,
              asset.vault_id,
              asset.principal_id
            ]
          )

          query!(repo, "SET CONSTRAINTS content.note_versions_aggregate_check IMMEDIATE")
        end
      )
    end)

    note = NoteFixtures.note_with_conflict!()

    assert_constraint(fn ->
      NoteFixtures.insert_note_version!(note, %{classification: "sensitive"})
    end)

    assert_constraint(fn ->
      NoteFixtures.insert_note_version!(note, %{
        parent_version_id: note.initial_version_id,
        merge_parent_version_id: note.initial_version_id
      })
    end)

    assert_constraint(fn ->
      NoteFixtures.insert_note_version!(note, %{
        parent_version_id: nil,
        merge_parent_version_id: nil
      })
    end)

    assert_constraint(fn ->
      NoteFixtures.insert_conflict!(note, %{state: "resolved", resolution_version_id: nil})
    end)

    assert_constraint(fn ->
      NoteFixtures.insert_receipt!(note, %{request_fingerprint: :binary.copy(<<1>>, 31)})
    end)

    assert_constraint(fn ->
      NoteFixtures.scoped(note, RequestRepo, fn repo ->
        query!(repo, "UPDATE content.resources SET kind = 'asset' WHERE id = $1", [
          Ecto.UUID.dump!(note.resource_id)
        ])
      end)
    end)

    assert_constraint(fn ->
      NoteFixtures.scoped(note, RequestRepo, fn repo ->
        query!(repo, "UPDATE content.resource_versions SET revision = 99 WHERE id = $1", [
          Ecto.UUID.dump!(note.initial_version_id)
        ])
      end)
    end)
  end

  test "classification cannot diverge across resource, generic version, typed version, conflict, or search" do
    note = NoteFixtures.note_with_conflict!()

    assert_constraint(fn ->
      NoteFixtures.insert_note_version!(note, %{classification: "sensitive"})
    end)

    assert_constraint(fn ->
      NoteFixtures.insert_conflict!(note, %{classification: "sensitive"})
    end)

    assert_constraint(fn ->
      NoteFixtures.scoped(note, RequestRepo, fn repo ->
        query!(repo, "DELETE FROM content.note_search_documents WHERE resource_id = $1", [
          Ecto.UUID.dump!(note.resource_id)
        ])

        query!(
          repo,
          """
          INSERT INTO content.note_search_documents (
            resource_id, resource_version_id, vault_id, classification,
            title, markdown, head_inserted_at
          ) VALUES ($1, $2, $3, 'sensitive', 'Mismatch', '# Mismatch', CURRENT_TIMESTAMP)
          """,
          [
            Ecto.UUID.dump!(note.resource_id),
            Ecto.UUID.dump!(note.canonical_version_id),
            Ecto.UUID.dump!(note.vault_id)
          ]
        )
      end)
    end)
  end

  test "receipt result references are deferred and stay within one private note aggregate" do
    note = NoteFixtures.note_with_conflict!()
    other = NoteFixtures.note_with_conflict_in_context!(note)
    cross_vault = NoteFixtures.note_with_conflict!()

    assert_constraint(fn ->
      NoteFixtures.insert_receipt!(note, %{
        state: "pending",
        outcome: nil,
        resource_id: Ecto.UUID.generate(),
        version_id: nil,
        conflict_id: nil
      })
    end)

    assert_constraint(fn ->
      NoteFixtures.insert_receipt!(note, %{
        operation: "save",
        state: "completed",
        outcome: "saved",
        resource_id: note.resource_id,
        version_id: Ecto.UUID.generate(),
        conflict_id: nil
      })
    end)

    assert_constraint(fn ->
      NoteFixtures.insert_receipt!(note, %{
        operation: "save",
        state: "completed",
        outcome: "conflict",
        resource_id: note.resource_id,
        version_id: note.competing_version_id,
        conflict_id: Ecto.UUID.generate()
      })
    end)

    %{one: asset} = Fixtures.two_vaults!()

    assert_constraint(fn ->
      insert_pending_receipt_for_raw_fixture!(asset)
    end)

    assert_constraint(fn ->
      NoteFixtures.insert_receipt!(note, %{
        state: "pending",
        outcome: nil,
        resource_id: cross_vault.resource_id,
        version_id: nil,
        conflict_id: nil
      })
    end)

    assert_constraint(fn ->
      NoteFixtures.insert_receipt!(note, %{
        operation: "save",
        state: "completed",
        outcome: "saved",
        resource_id: note.resource_id,
        version_id: cross_vault.competing_version_id,
        conflict_id: nil
      })
    end)

    assert_constraint(fn ->
      NoteFixtures.insert_receipt!(note, %{
        operation: "save",
        state: "completed",
        outcome: "conflict",
        resource_id: note.resource_id,
        version_id: note.competing_version_id,
        conflict_id: cross_vault.conflict_id
      })
    end)

    assert_constraint(fn ->
      NoteFixtures.insert_receipt!(note, %{
        operation: "save",
        state: "completed",
        outcome: "saved",
        resource_id: note.resource_id,
        version_id: other.competing_version_id,
        conflict_id: nil
      })
    end)

    assert_constraint(fn ->
      NoteFixtures.insert_receipt!(note, %{
        operation: "save",
        state: "completed",
        outcome: "conflict",
        resource_id: note.resource_id,
        version_id: note.competing_version_id,
        conflict_id: other.conflict_id
      })
    end)

    assert %{resource_id: resource_id, mutation_id: mutation_id} =
             insert_pending_receipt_before_note!()

    assert Ecto.UUID.cast!(resource_id)
    assert Ecto.UUID.cast!(mutation_id)
  end

  test "web cannot update or delete immutable note snapshots" do
    note = NoteFixtures.note_with_conflict!()

    assert_raise Postgrex.Error, fn ->
      NoteFixtures.scoped(note, RequestRepo, fn repo ->
        query!(
          repo,
          "UPDATE content.note_versions SET title = 'changed' WHERE resource_version_id = $1",
          [Ecto.UUID.dump!(note.initial_version_id)]
        )
      end)
    end

    assert_raise Postgrex.Error, fn ->
      NoteFixtures.scoped(note, RequestRepo, fn repo ->
        query!(repo, "DELETE FROM content.note_versions WHERE resource_version_id = $1", [
          Ecto.UUID.dump!(note.initial_version_id)
        ])
      end)
    end
  end

  test "strict schemas cast only declared fields and expose operation-specific changesets" do
    assert Code.ensure_loaded?(Singularity.Storage.Schema.Content.NoteVersion)

    refute function_exported?(
             Singularity.Storage.Schema.Content.NoteVersion,
             :update_changeset,
             2
           )

    for {schema, function, attrs} <- [
          {Singularity.Storage.Schema.Content.NoteVersion, :create_changeset,
           NoteFixtures.note_version_attrs()},
          {Singularity.Storage.Schema.Content.NoteConflict, :create_changeset,
           NoteFixtures.conflict_attrs()},
          {Singularity.Storage.Schema.Content.NoteSearchDocument, :upsert_changeset,
           NoteFixtures.search_document_attrs()},
          {Singularity.Storage.Schema.Content.NoteMutationReceipt, :create_changeset,
           NoteFixtures.receipt_attrs()}
        ] do
      changeset = apply(schema, function, [struct(schema), Map.put(attrs, :unknown, "ignored")])
      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :unknown)
      assert changeset.constraints != []
    end

    conflict_changeset =
      Singularity.Storage.Schema.Content.NoteConflict.create_changeset(
        %Singularity.Storage.Schema.Content.NoteConflict{},
        Map.merge(NoteFixtures.conflict_attrs(), %{
          state: "resolved",
          resolution_version_id: Ecto.UUID.generate(),
          resolved_at: DateTime.utc_now()
        })
      )

    assert Ecto.Changeset.get_field(conflict_changeset, :state) == :open
    refute Map.has_key?(conflict_changeset.changes, :resolution_version_id)
    refute Map.has_key?(conflict_changeset.changes, :resolved_at)

    receipt_changeset =
      Singularity.Storage.Schema.Content.NoteMutationReceipt.create_changeset(
        %Singularity.Storage.Schema.Content.NoteMutationReceipt{},
        Map.merge(NoteFixtures.receipt_attrs(), %{
          state: "completed",
          outcome: "saved",
          version_id: Ecto.UUID.generate()
        })
      )

    assert Ecto.Changeset.get_field(receipt_changeset, :state) == :pending
    refute Map.has_key?(receipt_changeset.changes, :outcome)
    refute Map.has_key?(receipt_changeset.changes, :version_id)
  end

  test "capability reconciliation is empty-safe, exact, and idempotent" do
    Fixtures.reset_bootstrap_state!()
    reset_note_capabilities!()

    on_exit(fn ->
      Fixtures.reset_bootstrap_state!()
      reset_note_capabilities!()
    end)

    assert capability_names() == []

    %{one: eligible, two: ordinary} = NoteFixtures.two_notes!()
    NoteFixtures.grant_password_change!(eligible)

    assert [:ok, :ok] = concurrent_reconcile_capabilities!()
    assert capability_names() == ~w(note.export note.read note.write)
    assert note_capability_recipients() == [{eligible.principal_id, eligible.vault_id}]
    assert authorization_epochs(eligible) == [1, 1]
    assert authorization_epochs(ordinary) == [0, 0]

    assert :ok = reconcile_capabilities!()
    assert note_capability_recipients() == [{eligible.principal_id, eligible.vault_id}]
    assert authorization_epochs(eligible) == [1, 1]

    NoteFixtures.grant_password_change!(ordinary)

    for state <- [:disabled_account, :revoked_principal, :revoked_membership, :revoked_assignment] do
      set_capability_candidate_state!(ordinary, state)
      assert :ok = reconcile_capabilities!()
      assert note_capability_recipients() == [{eligible.principal_id, eligible.vault_id}]
      reset_capability_candidate_state!(ordinary, state)
    end
  end

  defp assert_constraint(fun) do
    capture_log(fn -> assert_raise(Postgrex.Error, fun) end)
  end

  defp column!(schema, table, column) do
    assert %{rows: [[type, nullable, default, generated]]} =
             query!(
               RequestRepo,
               """
               SELECT format_type(attribute.atttypid, attribute.atttypmod),
                      NOT attribute.attnotnull,
                      pg_get_expr(default_value.adbin, default_value.adrelid),
                      attribute.attgenerated::text
               FROM pg_attribute AS attribute
               JOIN pg_class AS relation ON relation.oid = attribute.attrelid
               JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
               LEFT JOIN pg_attrdef AS default_value
                 ON default_value.adrelid = relation.oid
                AND default_value.adnum = attribute.attnum
               WHERE namespace.nspname = $1 AND relation.relname = $2
                 AND attribute.attname = $3 AND attribute.attnum > 0
               """,
               [schema, table, column]
             )

    {type, nullable, default, generated}
  end

  defp columns!(schema, table) do
    %{rows: rows} =
      query!(
        RequestRepo,
        """
        SELECT attribute.attname,
               format_type(attribute.atttypid, attribute.atttypmod),
               NOT attribute.attnotnull
        FROM pg_attribute AS attribute
        JOIN pg_class AS relation ON relation.oid = attribute.attrelid
        JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname = $1 AND relation.relname = $2
          AND attribute.attnum > 0 AND NOT attribute.attisdropped
        ORDER BY attribute.attnum
        """,
        [schema, table]
      )

    rows
  end

  defp catalog_names(catalog, column, names) do
    %{rows: rows} =
      query!(
        RequestRepo,
        "SELECT #{column} FROM #{catalog} WHERE #{column} = ANY($1) ORDER BY #{column}",
        [names]
      )

    List.flatten(rows)
  end

  defp constraint_definition!(name) do
    assert %{rows: [[definition]]} =
             query!(
               RequestRepo,
               "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = $1",
               [name]
             )

    definition
  end

  defp capability_names do
    %{rows: rows} =
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "SELECT name FROM core.capabilities WHERE name LIKE 'note.%' ORDER BY name"
        )
      end)

    List.flatten(rows)
  end

  defp reconcile_capabilities! do
    {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 2)

    try do
      NoteCapabilityReconciler.reconcile(MigrationRepo)
    after
      Supervisor.stop(migration_repo)
    end
  end

  defp concurrent_reconcile_capabilities! do
    {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 4)
    parent = self()

    tasks =
      for _index <- 1..2 do
        Task.async(fn ->
          send(parent, {:reconciler_ready, self()})
          receive do: (:reconcile -> NoteCapabilityReconciler.reconcile(MigrationRepo))
        end)
      end

    workers =
      for _index <- 1..2 do
        receive do: ({:reconciler_ready, worker} -> worker)
      end

    Enum.each(workers, &send(&1, :reconcile))

    try do
      tasks
      |> Enum.map(&Task.await(&1, 5_000))
      |> Enum.sort()
    after
      Supervisor.stop(migration_repo)
    end
  end

  defp note_capability_recipients do
    %{rows: rows} =
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          """
          SELECT assignment.principal_id, assignment.vault_id
          FROM core.principal_capabilities AS assignment
          JOIN core.capabilities AS capability ON capability.id = assignment.capability_id
          WHERE capability.name LIKE 'note.%' AND assignment.revoked_at IS NULL
          GROUP BY assignment.principal_id, assignment.vault_id
          HAVING count(*) = 3
          ORDER BY assignment.principal_id, assignment.vault_id
          """
        )
      end)

    Enum.map(rows, fn [principal_id, vault_id] ->
      {Ecto.UUID.load!(principal_id), Ecto.UUID.load!(vault_id)}
    end)
  end

  defp authorization_epochs(note) do
    Fixtures.with_owner(fn ->
      assert %{rows: [[principal_epoch, vault_epoch]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT principal.authorization_epoch, vault.authorization_epoch
                 FROM identity.principals AS principal
                 CROSS JOIN core.vaults AS vault
                 WHERE principal.id = $1 AND vault.id = $2
                 """,
                 [Ecto.UUID.dump!(note.principal_id), Ecto.UUID.dump!(note.vault_id)]
               )

      [principal_epoch, vault_epoch]
    end)
  end

  defp reset_note_capabilities! do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        DELETE FROM core.principal_capabilities
        WHERE capability_id IN (
          SELECT id FROM core.capabilities WHERE name LIKE 'note.%'
        )
        """
      )

      query!(MigrationRepo, "DELETE FROM core.capabilities WHERE name LIKE 'note.%'")
    end)
  end

  defp set_capability_candidate_state!(note, :disabled_account) do
    owner_query!("UPDATE identity.accounts SET status = 'disabled' WHERE id = $1", [
      Ecto.UUID.dump!(note.account_id)
    ])
  end

  defp set_capability_candidate_state!(note, :revoked_principal) do
    owner_query!("UPDATE identity.principals SET revoked_at = CURRENT_TIMESTAMP WHERE id = $1", [
      Ecto.UUID.dump!(note.principal_id)
    ])
  end

  defp set_capability_candidate_state!(note, :revoked_membership) do
    owner_query!(
      "UPDATE core.vault_members SET revoked_at = CURRENT_TIMESTAMP WHERE principal_id = $1 AND vault_id = $2",
      [Ecto.UUID.dump!(note.principal_id), Ecto.UUID.dump!(note.vault_id)]
    )
  end

  defp set_capability_candidate_state!(note, :revoked_assignment) do
    owner_query!(
      """
      UPDATE core.principal_capabilities AS assignment
      SET revoked_at = CURRENT_TIMESTAMP
      FROM core.capabilities AS capability
      WHERE assignment.capability_id = capability.id
        AND assignment.principal_id = $1
        AND assignment.vault_id = $2
        AND capability.name = 'vault.password_change'
      """,
      [Ecto.UUID.dump!(note.principal_id), Ecto.UUID.dump!(note.vault_id)]
    )
  end

  defp reset_capability_candidate_state!(note, :disabled_account) do
    owner_query!("UPDATE identity.accounts SET status = 'active' WHERE id = $1", [
      Ecto.UUID.dump!(note.account_id)
    ])
  end

  defp reset_capability_candidate_state!(note, :revoked_principal) do
    owner_query!("UPDATE identity.principals SET revoked_at = NULL WHERE id = $1", [
      Ecto.UUID.dump!(note.principal_id)
    ])
  end

  defp reset_capability_candidate_state!(note, :revoked_membership) do
    owner_query!(
      "UPDATE core.vault_members SET revoked_at = NULL WHERE principal_id = $1 AND vault_id = $2",
      [Ecto.UUID.dump!(note.principal_id), Ecto.UUID.dump!(note.vault_id)]
    )
  end

  defp reset_capability_candidate_state!(_note, :revoked_assignment), do: :ok

  defp owner_query!(statement, params) do
    Fixtures.with_owner(fn -> query!(MigrationRepo, statement, params) end)
  end

  defp insert_pending_receipt_before_note! do
    %{one: fixture} = Fixtures.two_vaults!()
    resource_id = Ecto.UUID.generate()
    version_id = Ecto.UUID.generate()
    mutation_id = Ecto.UUID.generate()

    Singularity.Storage.ScopedRepo.transact(
      RequestRepo,
      %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
      fn repo ->
        query!(repo, "SET CONSTRAINTS ALL DEFERRED")

        query!(
          repo,
          """
          INSERT INTO content.note_mutation_receipts (
            vault_id, principal_id, mutation_id, operation,
            request_fingerprint, state, resource_id
          ) VALUES ($1, $2, $3, 'create', $4, 'pending', $5)
          """,
          [
            fixture.vault_id,
            fixture.principal_id,
            Ecto.UUID.dump!(mutation_id),
            :crypto.hash(:sha256, "receipt-before-note"),
            Ecto.UUID.dump!(resource_id)
          ]
        )

        query!(
          repo,
          """
          INSERT INTO content.resources (
            id, vault_id, classification, title, kind, current_version_id
          ) VALUES ($1, $2, 'private', 'Deferred receipt note', 'note', $3)
          """,
          [Ecto.UUID.dump!(resource_id), fixture.vault_id, Ecto.UUID.dump!(version_id)]
        )

        query!(
          repo,
          """
          INSERT INTO content.resource_versions (
            id, resource_id, vault_id, classification, revision
          ) VALUES ($1, $2, $3, 'private', 0)
          """,
          [Ecto.UUID.dump!(version_id), Ecto.UUID.dump!(resource_id), fixture.vault_id]
        )

        query!(
          repo,
          """
          INSERT INTO content.note_versions (
            resource_version_id, resource_id, vault_id, classification,
            title, markdown, created_by_principal_id,
            parent_version_id, merge_parent_version_id
          ) VALUES ($1, $2, $3, 'private', 'Deferred receipt note', '# Deferred', $4, NULL, NULL)
          """,
          [
            Ecto.UUID.dump!(version_id),
            Ecto.UUID.dump!(resource_id),
            fixture.vault_id,
            fixture.principal_id
          ]
        )

        %{resource_id: resource_id, mutation_id: mutation_id}
      end
    )
  end

  defp insert_pending_receipt_for_raw_fixture!(fixture) do
    Singularity.Storage.ScopedRepo.transact(
      RequestRepo,
      %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
      fn repo ->
        query!(
          repo,
          """
          INSERT INTO content.note_mutation_receipts (
            vault_id, principal_id, mutation_id, operation,
            request_fingerprint, state, resource_id
          ) VALUES ($1, $2, $3, 'save', $4, 'pending', $5)
          """,
          [
            fixture.vault_id,
            fixture.principal_id,
            Ecto.UUID.dump!(Ecto.UUID.generate()),
            :crypto.hash(:sha256, "asset-receipt"),
            fixture.resource_id
          ]
        )
      end
    )
  end

  defp export_conflicts(note, requested_vault_id) do
    Singularity.Storage.ScopedRepo.transact(
      WorkerRepo,
      %{principal_id: note.principal_id, vault_id: note.vault_id},
      fn repo ->
        query!(repo, "SELECT * FROM content.export_note_conflicts_for_backup($1)", [
          Ecto.UUID.dump!(requested_vault_id)
        ])
      end
    )
  end

  defp grant_backup_create!(note) do
    owner_query!(
      "INSERT INTO core.capabilities (id, name) VALUES ($1, 'backup.create') ON CONFLICT (name) DO NOTHING",
      [Ecto.UUID.dump!(Ecto.UUID.generate())]
    )

    owner_query!(
      """
      INSERT INTO core.principal_capabilities (principal_id, vault_id, capability_id)
      SELECT $1, $2, capability.id
      FROM core.capabilities AS capability
      WHERE capability.name = 'backup.create'
      ON CONFLICT (principal_id, vault_id, capability_id)
      DO UPDATE SET revoked_at = NULL
      """,
      [Ecto.UUID.dump!(note.principal_id), Ecto.UUID.dump!(note.vault_id)]
    )
  end

  defp revoke_backup_create!(note) do
    owner_query!(
      """
      UPDATE core.principal_capabilities AS assignment
      SET revoked_at = CURRENT_TIMESTAMP
      FROM core.capabilities AS capability
      WHERE assignment.capability_id = capability.id
        AND assignment.principal_id = $1
        AND assignment.vault_id = $2
        AND capability.name = 'backup.create'
      """,
      [Ecto.UUID.dump!(note.principal_id), Ecto.UUID.dump!(note.vault_id)]
    )
  end

  defp set_backup_export_authority_state!(note, :revoked_principal) do
    owner_query!("UPDATE identity.principals SET revoked_at = CURRENT_TIMESTAMP WHERE id = $1", [
      Ecto.UUID.dump!(note.principal_id)
    ])
  end

  defp set_backup_export_authority_state!(note, :revoked_membership) do
    owner_query!(
      "UPDATE core.vault_members SET revoked_at = CURRENT_TIMESTAMP WHERE principal_id = $1 AND vault_id = $2",
      [Ecto.UUID.dump!(note.principal_id), Ecto.UUID.dump!(note.vault_id)]
    )
  end

  defp set_backup_export_authority_state!(note, :inactive_account) do
    owner_query!("UPDATE identity.accounts SET status = 'disabled' WHERE id = $1", [
      Ecto.UUID.dump!(note.account_id)
    ])
  end

  defp reset_backup_export_authority_state!(note, :revoked_principal) do
    owner_query!("UPDATE identity.principals SET revoked_at = NULL WHERE id = $1", [
      Ecto.UUID.dump!(note.principal_id)
    ])
  end

  defp reset_backup_export_authority_state!(note, :revoked_membership) do
    owner_query!(
      "UPDATE core.vault_members SET revoked_at = NULL WHERE principal_id = $1 AND vault_id = $2",
      [Ecto.UUID.dump!(note.principal_id), Ecto.UUID.dump!(note.vault_id)]
    )
  end

  defp reset_backup_export_authority_state!(note, :inactive_account) do
    owner_query!("UPDATE identity.accounts SET status = 'active' WHERE id = $1", [
      Ecto.UUID.dump!(note.account_id)
    ])
  end
end
