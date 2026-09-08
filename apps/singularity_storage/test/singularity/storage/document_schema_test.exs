defmodule Singularity.Storage.DocumentSchemaTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  alias Singularity.Storage.{Fixtures, KnowledgeFixtures, MigrationRepo}

  test "an association to another version cannot replace the Asset's own source version" do
    source = KnowledgeFixtures.source!()
    alternative = KnowledgeFixtures.uuid()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.resource_versions (id, resource_id, vault_id, classification, revision) VALUES ($1,$2,$3,'private',1)",
        [alternative, source.resource_id, source.vault_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.resource_assets (resource_version_id,asset_id,vault_id,classification) VALUES ($1,$2,$3,'private')",
        [alternative, source.asset_id, source.vault_id]
      )
    end)

    assert_constraint("document_versions_source_check", fn ->
      KnowledgeFixtures.document!(source, %{source_resource_version_id: alternative})
    end)
  end

  test "receipt fingerprints, mutation uniqueness and cross-owner results are enforced" do
    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)
    other = KnowledgeFixtures.document!(KnowledgeFixtures.source!())

    assert_constraint("document_import_receipts_fingerprint_check", fn ->
      Fixtures.with_owner(fn ->
        receipt!(
          %{source | digest: <<1>>},
          "completed",
          document.resource_id,
          document.resource_version_id
        )
      end)
    end)

    assert_constraint("document_import_receipts_version_fkey", fn ->
      Fixtures.with_owner(fn ->
        receipt!(source, "completed", other.resource_id, other.resource_version_id)
      end)
    end)

    Fixtures.with_owner(fn ->
      receipt!(source, "completed", document.resource_id, document.resource_version_id)
    end)

    error =
      assert_raise Postgrex.Error, fn ->
        Fixtures.with_owner(fn ->
          query!(
            MigrationRepo,
            "INSERT INTO content.document_import_receipts SELECT * FROM content.document_import_receipts WHERE vault_id = $1",
            [source.vault_id]
          )
        end)
      end

    assert error.postgres.code == :unique_violation
    assert error.postgres.constraint == "document_import_receipts_pkey"
  end

  test "Document and import receipt schemas expose only operation-specific changesets" do
    for module <- [
          Singularity.Storage.Schema.Content.DocumentVersion,
          Singularity.Storage.Schema.Content.DocumentImportReceipt
        ] do
      assert Code.ensure_loaded?(module)
      assert function_exported?(module, :create_changeset, 2)
      refute function_exported?(module, :update_changeset, 2)
      changeset = apply(module, :create_changeset, [struct(module), %{unexpected: "private"}])
      refute changeset.valid?
      refute Map.has_key?(changeset.changes, :unexpected)
      assert changeset.constraints != []
    end
  end

  test "Document columns, deferred aggregate keys and preserved Note keys are exact" do
    assert %{rows: columns} =
             query!(RequestRepo, """
             SELECT attribute.attname, format_type(attribute.atttypid, attribute.atttypmod), attribute.attnotnull
             FROM pg_attribute AS attribute WHERE attrelid = 'content.document_versions'::regclass
               AND attnum > 0 AND NOT attisdropped ORDER BY attnum
             """)

    assert columns ==
             Enum.map(
               [
                 {"resource_version_id", "uuid"},
                 {"resource_id", "uuid"},
                 {"vault_id", "uuid"},
                 {"classification", "text"},
                 {"source_asset_id", "uuid"},
                 {"source_resource_id", "uuid"},
                 {"source_resource_version_id", "uuid"},
                 {"source_object_id", "uuid"},
                 {"source_digest", "bytea"},
                 {"source_byte_size", "bigint"},
                 {"media_type", "text"},
                 {"title", "text"},
                 {"created_by_principal_id", "uuid"},
                 {"state", "text"},
                 {"attempt_generation", "bigint"}
               ],
               fn {name, type} -> [name, type, true] end
             ) ++
               [
                 ["extraction_adapter", "text", false],
                 ["extraction_format", "integer", false],
                 ["extracted_text_digest", "bytea", false],
                 ["detected_language", "text", false],
                 ["failure_code", "text", false],
                 ["attempt_finished_at", "timestamp(6) with time zone", false],
                 ["inserted_at", "timestamp(6) with time zone", true]
               ]

    for name <-
          ~w(resources_version_head_fkey document_versions_resource_version_fkey document_import_receipts_version_fkey resource_versions_resource_classification_fkey) do
      assert %{rows: [[true, true]]} =
               query!(
                 RequestRepo,
                 "SELECT condeferrable, condeferred FROM pg_constraint WHERE conname = $1",
                 [name]
               )
    end

    for name <-
          ~w(resources_head_vault_classification_key note_versions_identity_aggregate_key note_search_documents_resource_head_fkey) do
      assert %{rows: [[1]]} =
               query!(RequestRepo, "SELECT count(*) FROM pg_constraint WHERE conname = $1", [name])
    end
  end

  test "Document title, media, state and generation bounds are enforced in SQL" do
    source = KnowledgeFixtures.source!()

    for {attrs, constraint} <- [
          {%{title: " "}, "document_versions_title_check"},
          {%{title: String.duplicate("é", 128)}, "document_versions_title_check"},
          {%{media_type: "application/octet-stream"}, "document_versions_media_type_check"}
        ] do
      assert_constraint(constraint, fn -> KnowledgeFixtures.document!(source, attrs) end)
    end

    document = KnowledgeFixtures.document!(source)

    for {assignment, constraint} <- [
          {"state = 'invented'", "document_versions_state_check"},
          {"attempt_generation = -1", "document_versions_attempt_generation_check"}
        ] do
      assert_constraint(constraint, fn ->
        Fixtures.with_owner(fn ->
          query!(
            MigrationRepo,
            "UPDATE content.document_versions SET #{assignment} WHERE resource_version_id = $1",
            [document.resource_version_id]
          )
        end)
      end)
    end
  end

  test "Asset heads stay null and Document heads reject null, other aggregate and other owner" do
    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)
    other = KnowledgeFixtures.document!(source)
    foreign = KnowledgeFixtures.document!(KnowledgeFixtures.source!())

    assert_constraint("resources_note_head_check", fn ->
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "UPDATE content.resources SET current_version_id = $1 WHERE id = $2",
          [source.resource_version_id, source.resource_id]
        )
      end)
    end)

    assert_constraint("resources_note_head_check", fn ->
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "UPDATE content.resources SET current_version_id = NULL WHERE id = $1",
          [document.resource_id]
        )
      end)
    end)

    for target <- [other, foreign] do
      assert_constraint("resources_version_head_fkey", fn ->
        Fixtures.with_owner(fn ->
          query!(
            MigrationRepo,
            "UPDATE content.resources SET current_version_id = $1 WHERE id = $2",
            [target.resource_version_id, document.resource_id]
          )
        end)
      end)
    end
  end

  test "pending receipt can complete before commit and rollbacks leave no pending claim" do
    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)
    mutation_id = KnowledgeFixtures.uuid()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.document_import_receipts (vault_id,principal_id,mutation_id,request_fingerprint,inserted_at) VALUES ($1,$2,$3,$4,CURRENT_TIMESTAMP)",
        [source.vault_id, source.principal_id, mutation_id, source.digest]
      )

      query!(
        MigrationRepo,
        "UPDATE content.document_import_receipts SET state = 'completed', resource_id = $1, version_id = $2 WHERE mutation_id = $3",
        [document.resource_id, document.resource_version_id, mutation_id]
      )
    end)

    assert_constraint("document_import_receipts_completed_check", fn ->
      Fixtures.with_owner(fn -> receipt!(source, "pending", nil, nil) end)
    end)

    Fixtures.with_owner(fn ->
      assert %{rows: [[1, 0]]} =
               query!(
                 MigrationRepo,
                 "SELECT count(*), count(*) FILTER (WHERE state = 'pending') FROM content.document_import_receipts WHERE vault_id = $1",
                 [source.vault_id]
               )
    end)
  end

  test "existing Notes parent-first locking coexists with typed-row deletion guards" do
    note = Singularity.Storage.NoteFixtures.note!()
    next = Singularity.Storage.NoteFixtures.insert_note_version!(note, %{})
    resource = Ecto.UUID.dump!(note.resource_id)
    version = Ecto.UUID.dump!(next.resource_version_id)
    # The search projection pins the old head; the existing save transaction
    # removes it before changing that head as well.
    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "DELETE FROM content.note_search_documents WHERE resource_id = $1", [
        resource
      ])
    end)

    race_head!(
      resource,
      version,
      {"DELETE FROM content.note_versions WHERE resource_version_id = $1", [version]}
    )
  end

  test "a Document commits with its exact typed head and immutable accepted source" do
    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)

    Fixtures.with_owner(fn ->
      assert %{rows: [["pending", 0, digest, 12]]} =
               query!(
                 MigrationRepo,
                 "SELECT state, attempt_generation, source_digest, source_byte_size FROM content.document_versions WHERE resource_version_id = $1",
                 [document.resource_version_id]
               )

      assert digest == source.digest
    end)
  end

  test "generic-only Note and Document heads fail at commit" do
    source = KnowledgeFixtures.source!()

    for kind <- ["note", "document"] do
      assert_constraint("resources_typed_head_check", fn ->
        Fixtures.with_owner(fn ->
          resource = KnowledgeFixtures.uuid()
          version = KnowledgeFixtures.uuid()

          query!(
            MigrationRepo,
            "INSERT INTO content.resources (id, vault_id, classification, kind, current_version_id, title) VALUES ($1,$2,'private',$3,$4,'Head')",
            [resource, source.vault_id, kind, version]
          )

          query!(
            MigrationRepo,
            "INSERT INTO content.resource_versions (id,resource_id,vault_id,classification,revision) VALUES ($1,$2,$3,'private',0)",
            [version, resource, source.vault_id]
          )
        end)
      end)
    end
  end

  test "Document source tuple rejects wrong owner, resource, version, object and actor" do
    source = KnowledgeFixtures.source!()
    other = KnowledgeFixtures.source!()

    for attrs <- [
          %{vault_id: other.vault_id},
          %{source_resource_id: other.resource_id},
          %{source_resource_version_id: other.resource_version_id},
          %{source_asset_id: other.asset_id},
          %{source_object_id: other.object_id},
          %{created_by_principal_id: other.principal_id},
          %{source_byte_size: 13},
          %{source_byte_size: -1},
          %{source_byte_size: 67_108_865}
        ] do
      expected =
        if Map.has_key?(attrs, :created_by_principal_id),
          do: "document_versions_created_by_membership_fkey",
          else: "document_versions_source_check"

      assert_constraint(expected, fn -> KnowledgeFixtures.document!(source, attrs) end)
    end

    assert_constraint("document_versions_source_digest_check", fn ->
      KnowledgeFixtures.document!(source, %{source_digest: <<1>>})
    end)

    assert_constraint("document_versions_private_check", fn ->
      KnowledgeFixtures.document!(source, %{classification: "sensitive"})
    end)
  end

  test "Document source requires live association, Asset and object at acceptance" do
    for {table, assignment, id_key} <- [
          {"resource_assets", "released_at = CURRENT_TIMESTAMP", :resource_version_id},
          {"assets", "state = 'staging'", :asset_id},
          {"asset_objects", "lifecycle = 'staged'", :object_id},
          {"resources", "deleted_at = CURRENT_TIMESTAMP", :resource_id}
        ] do
      source = KnowledgeFixtures.source!()

      Fixtures.with_owner(fn ->
        column = if table == "resource_assets", do: "resource_version_id", else: "id"

        query!(MigrationRepo, "UPDATE content.#{table} SET #{assignment} WHERE #{column} = $1", [
          Map.fetch!(source, id_key)
        ])
      end)

      assert_constraint("document_versions_source_check", fn ->
        KnowledgeFixtures.document!(source)
      end)
    end
  end

  test "accepted source object pin does not constrain the Asset's later mutable object pointer" do
    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.assets SET asset_object_id = NULL, state = 'deleted' WHERE id = $1",
        [source.asset_id]
      )

      assert %{rows: [[object_id]]} =
               query!(
                 MigrationRepo,
                 "SELECT source_object_id FROM content.document_versions WHERE resource_version_id = $1",
                 [document.resource_version_id]
               )

      assert object_id == source.object_id
    end)
  end

  test "head validation uses final state after obsolete intermediate heads" do
    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.resources SET current_version_id = $1 WHERE id = $2",
        [KnowledgeFixtures.uuid(), document.resource_id]
      )

      query!(
        MigrationRepo,
        "UPDATE content.resources SET current_version_id = $1 WHERE id = $2",
        [document.resource_version_id, document.resource_id]
      )
    end)
  end

  test "generic Document version identity cannot change" do
    document = KnowledgeFixtures.document!(KnowledgeFixtures.source!())

    assert_constraint("resource_versions_document_identity_immutable_check", fn ->
      Fixtures.with_owner(fn ->
        query!(MigrationRepo, "UPDATE content.resource_versions SET revision = 1 WHERE id = $1", [
          document.resource_version_id
        ])
      end)
    end)
  end

  test "pending receipts cannot commit, completed receipts pin one exact typed result" do
    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)

    for {state, resource, version, constraint} <- [
          {"pending", nil, nil, "document_import_receipts_completed_check"},
          {"completed", nil, nil, "document_import_receipts_result_shape_check"},
          {"pending", document.resource_id, document.resource_version_id,
           "document_import_receipts_result_shape_check"},
          {"completed", source.resource_id, source.resource_version_id,
           "document_import_receipts_version_fkey"},
          {"completed", document.resource_id, source.resource_version_id,
           "document_import_receipts_version_fkey"}
        ] do
      assert_constraint(constraint, fn ->
        Fixtures.with_owner(fn -> receipt!(source, state, resource, version) end)
      end)
    end

    Fixtures.with_owner(fn ->
      receipt!(source, "completed", document.resource_id, document.resource_version_id)
    end)
  end

  defp receipt!(source, state, resource, version) do
    query!(
      MigrationRepo,
      "INSERT INTO content.document_import_receipts (vault_id,principal_id,mutation_id,request_fingerprint,state,resource_id,version_id,inserted_at) VALUES ($1,$2,$3,$4,$5,$6,$7,CURRENT_TIMESTAMP)",
      [
        source.vault_id,
        source.principal_id,
        KnowledgeFixtures.uuid(),
        source.digest,
        state,
        resource,
        version
      ]
    )
  end

  defp assert_constraint(expected, fun) do
    error = assert_raise Postgrex.Error, fun
    assert error.postgres.constraint == expected
    assert error.postgres.code in [:check_violation, :foreign_key_violation]
  end

  defp race_head!(resource, version, {statement, parameters}) do
    config = MigrationRepo.config() |> Keyword.put(:pool_size, 1)
    {:ok, first} = Postgrex.start_link(config)
    {:ok, second} = Postgrex.start_link(config)

    try do
      for connection <- [first, second] do
        Postgrex.query!(connection, "BEGIN", [])
        Postgrex.query!(connection, "SET LOCAL ROLE singularity_table_owner", [])
        Postgrex.query!(connection, "SET LOCAL lock_timeout = '5s'", [])
      end

      %{rows: [[first_pid]]} = Postgrex.query!(first, "SELECT pg_backend_pid()", [])
      %{rows: [[second_pid]]} = Postgrex.query!(second, "SELECT pg_backend_pid()", [])
      refute first_pid == second_pid

      Postgrex.query!(
        first,
        "UPDATE content.resources SET current_version_id = $1 WHERE id = $2",
        [version, resource]
      )

      Postgrex.query!(second, statement, parameters)
      contender = Task.async(fn -> Postgrex.query(second, "COMMIT", []) end)
      assert wait_for_blocker(second_pid, first_pid, 200)
      assert {:ok, _} = Postgrex.query(first, "COMMIT", [])

      assert {:error, %Postgrex.Error{postgres: %{constraint: "resources_typed_head_check"}}} =
               Task.await(contender, 6_000)

      Fixtures.with_owner(fn ->
        assert %{rows: [[^version]]} =
                 query!(
                   MigrationRepo,
                   "SELECT current_version_id FROM content.resources WHERE id = $1",
                   [resource]
                 )
      end)
    after
      for connection <- [first, second] do
        if Process.alive?(connection), do: GenServer.stop(connection)
      end
    end
  end

  defp wait_for_blocker(_, _, 0), do: false

  defp wait_for_blocker(blocked, blocker, attempts) do
    case query!(RequestRepo, "SELECT $1::integer = ANY(pg_blocking_pids($2::integer))", [
           blocker,
           blocked
         ]) do
      %{rows: [[true]]} ->
        true

      _ ->
        Process.sleep(10)
        wait_for_blocker(blocked, blocker, attempts - 1)
    end
  end
end

defmodule Singularity.Storage.DocumentTypedHeadMigrationTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  alias Singularity.Storage.{Fixtures, KnowledgeFixtures, MigrationRepo, MigrationTestEnvironment}

  # Preserve deferred typed-head enforcement before the later immediate
  # Document identity and deletion guards are installed.
  setup_all do
    environment = MigrationTestEnvironment.open!(20_260_906_000_100)
    on_exit(fn -> MigrationTestEnvironment.close!(environment) end)
    :ok
  end

  test "two connections serialize Document head changes against typed deletion and reparenting" do
    for operation <- [:delete, :reparent] do
      source = KnowledgeFixtures.source!()
      document = KnowledgeFixtures.document!(source)
      next = %{document | resource_version_id: KnowledgeFixtures.uuid()}
      target = KnowledgeFixtures.document!(source)
      target_version = KnowledgeFixtures.uuid()

      Fixtures.with_owner(fn ->
        for {id, resource} <- [
              {next.resource_version_id, document.resource_id},
              {target_version, target.resource_id}
            ] do
          query!(
            MigrationRepo,
            "INSERT INTO content.resource_versions (id, resource_id, vault_id, classification, revision) VALUES ($1,$2,$3,'private',1)",
            [id, resource, source.vault_id]
          )
        end

        KnowledgeFixtures.insert_typed!(next)
      end)

      mutation =
        case operation do
          :delete ->
            {"DELETE FROM content.document_versions WHERE resource_version_id = $1",
             [next.resource_version_id]}

          :reparent ->
            {"UPDATE content.document_versions SET resource_version_id = $1, resource_id = $2 WHERE resource_version_id = $3",
             [target_version, target.resource_id, next.resource_version_id]}
        end

      race_head!(document.resource_id, next.resource_version_id, mutation)
    end
  end

  test "deleting a Document typed head fails at commit" do
    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)

    assert_constraint("resources_typed_head_check", fn ->
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "DELETE FROM content.document_versions WHERE resource_version_id = $1",
          [document.resource_version_id]
        )
      end)
    end)
  end

  defp assert_constraint(expected, fun) do
    error = assert_raise Postgrex.Error, fun
    assert error.postgres.constraint == expected
    assert error.postgres.code in [:check_violation, :foreign_key_violation]
  end

  defp race_head!(resource, version, {statement, parameters}) do
    config = MigrationRepo.config() |> Keyword.put(:pool_size, 1)
    {:ok, first} = Postgrex.start_link(config)
    {:ok, second} = Postgrex.start_link(config)

    try do
      for connection <- [first, second] do
        Postgrex.query!(connection, "BEGIN", [])
        Postgrex.query!(connection, "SET LOCAL ROLE singularity_table_owner", [])
        Postgrex.query!(connection, "SET LOCAL lock_timeout = '5s'", [])
      end

      %{rows: [[first_pid]]} = Postgrex.query!(first, "SELECT pg_backend_pid()", [])
      %{rows: [[second_pid]]} = Postgrex.query!(second, "SELECT pg_backend_pid()", [])
      refute first_pid == second_pid

      Postgrex.query!(
        first,
        "UPDATE content.resources SET current_version_id = $1 WHERE id = $2",
        [version, resource]
      )

      Postgrex.query!(second, statement, parameters)
      contender = Task.async(fn -> Postgrex.query(second, "COMMIT", []) end)
      assert wait_for_blocker(second_pid, first_pid, 200)
      assert {:ok, _} = Postgrex.query(first, "COMMIT", [])

      assert {:error, %Postgrex.Error{postgres: %{constraint: "resources_typed_head_check"}}} =
               Task.await(contender, 6_000)

      Fixtures.with_owner(fn ->
        assert %{rows: [[^version]]} =
                 query!(
                   MigrationRepo,
                   "SELECT current_version_id FROM content.resources WHERE id = $1",
                   [resource]
                 )
      end)
    after
      for connection <- [first, second] do
        if Process.alive?(connection), do: GenServer.stop(connection)
      end
    end
  end

  defp wait_for_blocker(_, _, 0), do: false

  defp wait_for_blocker(blocked, blocker, attempts) do
    case query!(RequestRepo, "SELECT $1::integer = ANY(pg_blocking_pids($2::integer))", [
           blocker,
           blocked
         ]) do
      %{rows: [[true]]} ->
        true

      _ ->
        Process.sleep(10)
        wait_for_blocker(blocked, blocker, attempts - 1)
    end
  end
end
