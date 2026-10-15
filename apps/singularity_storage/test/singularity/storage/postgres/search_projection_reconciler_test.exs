defmodule Singularity.Storage.Postgres.SearchProjectionReconcilerTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.{DocumentFragment, Error, SourceLocator}
  alias Singularity.Storage.{Fixtures, KnowledgeFixtures, MigrationRepo, SafeSQL, ScopedRepo}

  @reconciler Singularity.Storage.Postgres.SearchProjectionReconciler
  @read_function "reconcile_search_resource"
  @write_function "reconcile_note_search_resource"

  @projection_fields "entry_id, vault_id, classification, resource_id, resource_version_id, " <>
                       "kind, note_resource_version_id, fragment_id, ordinal, title, body, " <>
                       "locator, source_inserted_at, projection_version"

  test "the private canonical builder reconstructs exactly one immutable Note entry repeatedly" do
    source = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    version_id = note.resource_version_id
    resource_id = note.resource_id
    owner_id = source.vault_id

    Fixtures.with_owner(fn ->
      assert %{rows: [[^version_id, "Note", "body", source_inserted_at]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT version.id, note.title, note.markdown, version.inserted_at
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
                 WHERE resource.id = $1 AND resource.vault_id = $2
                 """,
                 [resource_id, owner_id]
               )

      expected = [
        [
          "note:" <> Ecto.UUID.load!(version_id),
          owner_id,
          "private",
          resource_id,
          version_id,
          "note",
          version_id,
          nil,
          0,
          "Note",
          "body",
          %{"version" => 1, "kind" => "markdown", "heading_path" => []},
          source_inserted_at,
          1
        ]
      ]

      assert projection_rows(resource_id) == []
      assert {:ok, %{rows: [[1]]}} = reconcile_internal(owner_id, resource_id)
      assert projection_rows(resource_id) == expected

      corrupt_title!(resource_id)

      for _attempt <- 1..2 do
        assert {:ok, %{rows: [[1]]}} = reconcile_internal(owner_id, resource_id)
        assert projection_rows(resource_id) == expected
      end
    end)
  end

  test "the private canonical builder reconstructs every ready Document fragment exactly" do
    source = KnowledgeFixtures.source!()
    {document, fragment} = KnowledgeFixtures.ready_document!(source)
    resource_id = document.resource_id
    version_id = document.resource_version_id
    owner_id = source.vault_id
    fragment_id = fragment.fragment_id
    locator = SourceLocator.to_map(fragment.locator)

    Fixtures.with_owner(fn ->
      assert %{rows: [[^fragment_id, 0, "Document", "text", ^locator, source_inserted_at]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT fragment.id, fragment.ordinal, document.title, fragment.text,
                        fragment.locator, version.inserted_at
                 FROM content.resources AS resource
                 JOIN content.resource_versions AS version
                   ON version.id = resource.current_version_id
                  AND version.resource_id = resource.id
                  AND version.vault_id = resource.vault_id
                  AND version.classification = resource.classification
                 JOIN content.document_versions AS document
                   ON document.resource_version_id = version.id
                  AND document.resource_id = version.resource_id
                  AND document.vault_id = version.vault_id
                  AND document.classification = version.classification
                 JOIN content.document_fragments AS fragment
                   ON fragment.resource_version_id = document.resource_version_id
                  AND fragment.resource_id = document.resource_id
                  AND fragment.vault_id = document.vault_id
                  AND fragment.classification = document.classification
                 WHERE resource.id = $1 AND resource.vault_id = $2
                   AND document.state = 'ready'
                 ORDER BY fragment.ordinal, fragment.id COLLATE "C"
                 """,
                 [resource_id, owner_id]
               )

      expected = [
        [
          "document:" <> fragment_id,
          owner_id,
          "private",
          resource_id,
          version_id,
          "document",
          nil,
          fragment_id,
          0,
          "Document",
          "text",
          locator,
          source_inserted_at,
          1
        ]
      ]

      assert projection_rows(resource_id) == []
      assert {:ok, %{rows: [[1]]}} = reconcile_internal(owner_id, resource_id)
      assert projection_rows(resource_id) == expected

      corrupt_title!(resource_id)

      for _attempt <- 1..2 do
        assert {:ok, %{rows: [[1]]}} = reconcile_internal(owner_id, resource_id)
        assert projection_rows(resource_id) == expected
      end
    end)
  end

  test "the canonical builder projects all fragments without replacing source identity or recency" do
    source = KnowledgeFixtures.source!()

    {document, fragments} =
      ready_document_with_fragments!(source, ["First body", "第二段", "Last body"])

    Fixtures.with_owner(fn ->
      %{rows: [[source_inserted_at]]} =
        query!(MigrationRepo, "SELECT inserted_at FROM content.resource_versions WHERE id=$1", [
          document.resource_version_id
        ])

      expected =
        Enum.map(fragments, fn fragment ->
          [
            "document:" <> fragment.fragment_id,
            source.vault_id,
            "private",
            document.resource_id,
            document.resource_version_id,
            "document",
            nil,
            fragment.fragment_id,
            fragment.ordinal,
            "Document",
            fragment.text,
            SourceLocator.to_map(fragment.locator),
            source_inserted_at,
            1
          ]
        end)

      for _attempt <- 1..2 do
        assert {:ok, %{rows: [[3]]}} = reconcile_internal(source.vault_id, document.resource_id)
        assert projection_rows(document.resource_id) == expected
      end
    end)
  end

  test "missing and foreign resources return only not-found status without changing another owner" do
    source = KnowledgeFixtures.source!()
    foreign = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(foreign)

    Fixtures.with_owner(fn ->
      assert {:ok, %{rows: [[1]]}} = reconcile_internal(foreign.vault_id, note.resource_id)
      original = projection_rows(note.resource_id)
      assert {:ok, %{rows: [[-1]]}} = reconcile_internal(source.vault_id, note.resource_id)

      assert {:ok, %{rows: [[-1]]}} =
               reconcile_internal(source.vault_id, KnowledgeFixtures.uuid())

      assert projection_rows(note.resource_id) == original
    end)
  end

  test "tombstoned Notes and ready Documents lose all derived entries repeatedly" do
    source = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    {document, _fragment} = KnowledgeFixtures.ready_document!(source)

    Fixtures.with_owner(fn ->
      for resource <- [note, document] do
        assert {:ok, %{rows: [[1]]}} = reconcile_internal(source.vault_id, resource.resource_id)

        query!(
          MigrationRepo,
          "UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id=$1",
          [
            resource.resource_id
          ]
        )

        for _attempt <- 1..2 do
          assert {:ok, %{rows: [[0]]}} = reconcile_internal(source.vault_id, resource.resource_id)
          assert projection_rows(resource.resource_id) == []
        end
      end
    end)
  end

  test "advancing a Document head to a non-ready canonical version removes old ready entries" do
    source = KnowledgeFixtures.source!()
    {document, _fragment} = KnowledgeFixtures.ready_document!(source)
    next_version = KnowledgeFixtures.uuid()

    Fixtures.with_owner(fn ->
      assert {:ok, %{rows: [[1]]}} = reconcile_internal(source.vault_id, document.resource_id)

      query!(
        MigrationRepo,
        "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',1)",
        [next_version, document.resource_id, source.vault_id]
      )

      KnowledgeFixtures.insert_typed!(%{document | resource_version_id: next_version})

      query!(MigrationRepo, "UPDATE content.resources SET current_version_id=$1 WHERE id=$2", [
        next_version,
        document.resource_id
      ])

      for _attempt <- 1..2 do
        assert {:ok, %{rows: [[0]]}} = reconcile_internal(source.vault_id, document.resource_id)
        assert projection_rows(document.resource_id) == []
      end
    end)
  end

  test "reconciliation selects the current typed Note rather than an old or competing version" do
    source = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    next_version = KnowledgeFixtures.uuid()
    competing_version = KnowledgeFixtures.uuid()

    Fixtures.with_owner(fn ->
      assert {:ok, %{rows: [[1]]}} = reconcile_internal(source.vault_id, note.resource_id)
      insert_note_version!(source, note, next_version, 1, "Current canonical", "Current body")

      insert_note_version!(
        source,
        note,
        competing_version,
        2,
        "Competing title",
        "Competing body"
      )

      query!(MigrationRepo, "UPDATE content.resources SET current_version_id=$1 WHERE id=$2", [
        next_version,
        note.resource_id
      ])

      assert {:ok, %{rows: [[1]]}} = reconcile_internal(source.vault_id, note.resource_id)

      assert %{rows: [[entry_id, ^next_version, "Current canonical", "Current body", true]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT entry.entry_id, entry.resource_version_id, entry.title, entry.body,
                        entry.source_inserted_at = version.inserted_at
                 FROM content.search_entries AS entry
                 JOIN content.resource_versions AS version ON version.id=entry.resource_version_id
                 WHERE entry.resource_id=$1
                 """,
                 [note.resource_id]
               )

      assert entry_id == "note:" <> Ecto.UUID.load!(next_version)
    end)
  end

  test "rolling back canonical reconciliation restores the previous head and projection together" do
    source = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)

    Fixtures.with_owner(fn ->
      assert {:ok, %{rows: [[1]]}} = reconcile_internal(source.vault_id, note.resource_id)
      original = projection_rows(note.resource_id)
      query!(MigrationRepo, "SAVEPOINT reconciliation_rollback")
      next_version = KnowledgeFixtures.uuid()
      insert_note_version!(source, note, next_version, 1, "Rolled back title", "Rolled back body")

      query!(MigrationRepo, "UPDATE content.resources SET current_version_id=$1 WHERE id=$2", [
        next_version,
        note.resource_id
      ])

      assert {:ok, %{rows: [[1]]}} = reconcile_internal(source.vault_id, note.resource_id)
      refute projection_rows(note.resource_id) == original
      query!(MigrationRepo, "ROLLBACK TO SAVEPOINT reconciliation_rollback")
      assert projection_rows(note.resource_id) == original

      assert %{rows: [[head]]} =
               query!(
                 MigrationRepo,
                 "SELECT current_version_id FROM content.resources WHERE id=$1",
                 [note.resource_id]
               )

      assert head == note.resource_version_id

      assert %{rows: [[0]]} =
               query!(
                 MigrationRepo,
                 "SELECT count(*) FROM content.resource_versions WHERE id=$1",
                 [next_version]
               )

      query!(MigrationRepo, "RELEASE SAVEPOINT reconciliation_rollback")
    end)
  end

  test "all runtime roles are denied direct execution of the private owner-selecting helper" do
    source = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)

    for repo <- [RequestRepo, WorkerRepo, DispatcherRepo, PreAuthRepo] do
      assert_denied(
        SafeSQL.query(repo, "SELECT content.reconcile_search_resource_internal($1,$2)", [
          source.vault_id,
          note.resource_id
        ])
      )
    end

    Fixtures.with_owner(fn -> assert projection_rows(note.resource_id) == [] end)
  end

  test "public read and Note-write entrypoints have exact owner search-path and production EXECUTE ACLs" do
    for {function, worker_allowed?} <- [{@read_function, false}, {@write_function, true}] do
      assert %{
               rows: [
                 [
                   "singularity_table_owner",
                   true,
                   ["search_path=pg_catalog, content, core, identity"],
                   true,
                   ^worker_allowed?,
                   false,
                   false,
                   false
                 ]
               ]
             } =
               query!(
                 RequestRepo,
                 """
                 SELECT pg_get_userbyid(procedure.proowner), procedure.prosecdef, procedure.proconfig,
                   has_function_privilege('singularity_web',procedure.oid,'EXECUTE'),
                   has_function_privilege('singularity_worker',procedure.oid,'EXECUTE'),
                   has_function_privilege('singularity_dispatcher',procedure.oid,'EXECUTE'),
                   has_function_privilege('singularity_pre_auth',procedure.oid,'EXECUTE'),
                   EXISTS(SELECT FROM aclexplode(COALESCE(procedure.proacl,acldefault('f',procedure.proowner))) AS acl
                          WHERE acl.grantee=0 AND acl.privilege_type='EXECUTE')
                 FROM pg_proc AS procedure
                 WHERE procedure.oid=to_regprocedure($1)
                 """,
                 ["content.#{function}(uuid)"]
               )
    end
  end

  test "web read maintenance requires only the corresponding existing Note or Document read capability" do
    source = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    grant_capabilities!(source, ["note.read"])

    assert {:ok, %{rows: [[1]]}} =
             scoped_sql(source, RequestRepo, @read_function, note.resource_id)

    document_source = KnowledgeFixtures.source!()
    {document, _fragment} = KnowledgeFixtures.ready_document!(document_source)
    grant_capabilities!(document_source, ["asset.read"])

    assert {:ok, %{rows: [[1]]}} =
             scoped_sql(document_source, RequestRepo, @read_function, document.resource_id)
  end

  test "Document read maintenance allows a different authorized owner principal without custody changes" do
    source = KnowledgeFixtures.source!()
    {document, _fragment} = KnowledgeFixtures.ready_document!(source)
    %{one: other} = Fixtures.two_vaults!()
    reader = %{principal_id: other.principal_id, vault_id: source.vault_id}

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO core.vault_members(principal_id,vault_id) VALUES($1,$2)",
        [reader.principal_id, reader.vault_id]
      )
    end)

    grant_capabilities!(reader, ["asset.read"])
    refute reader.principal_id == source.principal_id

    assert {:ok, %{rows: [[1]]}} =
             scoped_sql(reader, RequestRepo, @read_function, document.resource_id)
  end

  test "web and worker Note-write maintenance succeeds with note.write and no note.read" do
    source = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    grant_capabilities!(source, ["note.write"])

    for repo <- [RequestRepo, WorkerRepo] do
      assert {:ok, %{rows: [[1]]}} = scoped_sql(source, repo, @write_function, note.resource_id)
    end

    Fixtures.with_owner(fn ->
      assert %{rows: [[false]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT EXISTS(SELECT FROM core.principal_capabilities AS assignment
                   JOIN core.capabilities AS capability ON capability.id=assignment.capability_id
                   WHERE assignment.principal_id=$1 AND assignment.vault_id=$2
                     AND assignment.revoked_at IS NULL AND capability.name='note.read')
                 """,
                 [source.principal_id, source.vault_id]
               )
    end)
  end

  test "read and write entrypoints reject underprivileged and wrong-capability principals" do
    for {kind, function, capabilities} <- [
          {:note, @read_function, []},
          {:note, @read_function, ["note.write"]},
          {:document, @read_function, ["note.read"]},
          {:note, @write_function, []},
          {:note, @write_function, ["note.read"]}
        ] do
      source = KnowledgeFixtures.source!()
      resource = canonical_resource!(source, kind)
      grant_capabilities!(source, capabilities)
      assert_denied(scoped_sql(source, RequestRepo, function, resource.resource_id))
      Fixtures.with_owner(fn -> assert projection_rows(resource.resource_id) == [] end)
    end
  end

  test "revoked capability principal and membership authority cannot rebuild either public path" do
    for {function, capability} <- [{@read_function, "note.read"}, {@write_function, "note.write"}],
        revocation <- [:capability, :principal, :membership] do
      source = KnowledgeFixtures.source!()
      note = KnowledgeFixtures.note!(source)
      grant_capabilities!(source, [capability])
      revoke_authority!(source, revocation)
      assert_denied(scoped_sql(source, RequestRepo, function, note.resource_id))
      Fixtures.with_owner(fn -> assert projection_rows(note.resource_id) == [] end)
    end
  end

  test "public entrypoints reject missing and forged scoped context" do
    source = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    grant_capabilities!(source, ["note.read", "note.write"])

    for function <- [@read_function, @write_function] do
      assert_denied(public_sql(RequestRepo, function, note.resource_id))

      assert_denied(
        scoped_sql(
          %{source | principal_id: KnowledgeFixtures.uuid()},
          RequestRepo,
          function,
          note.resource_id
        )
      )

      assert_denied(
        scoped_sql(
          %{source | vault_id: KnowledgeFixtures.uuid()},
          RequestRepo,
          function,
          note.resource_id
        )
      )
    end
  end

  test "authorized public read and Note-write paths hide missing and foreign resources" do
    source = KnowledgeFixtures.source!()
    foreign = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(foreign)
    grant_capabilities!(source, ["note.read", "note.write", "asset.read"])

    for function <- [@read_function, @write_function],
        resource_id <- [KnowledgeFixtures.uuid(), note.resource_id] do
      assert {:ok, %{rows: [[-1]]}} = scoped_sql(source, RequestRepo, function, resource_id)
    end

    Fixtures.with_owner(fn -> assert projection_rows(note.resource_id) == [] end)
  end

  test "workers cannot use read maintenance or project Documents through the Note-write path" do
    source = KnowledgeFixtures.source!()
    {document, _fragment} = KnowledgeFixtures.ready_document!(source)
    grant_capabilities!(source, ["note.write", "note.read", "asset.read"])
    assert_denied(scoped_sql(source, WorkerRepo, @read_function, document.resource_id))

    assert {:ok, %{rows: [[-1]]}} =
             scoped_sql(source, WorkerRepo, @write_function, document.resource_id)

    assert_denied(SafeSQL.query(WorkerRepo, "SELECT 1 FROM content.search_entries LIMIT 1"))

    Singularity.Storage.WorkerDocumentReadAssertions.assert_read_only_rls!()

    Fixtures.with_owner(fn -> assert projection_rows(document.resource_id) == [] end)
  end

  test "public maintenance rejects a transaction isolation that can retain stale authorization" do
    source = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    grant_capabilities!(source, ["note.read", "note.write"])

    for function <- [@read_function, @write_function] do
      assert_denied(
        ScopedRepo.transact(RequestRepo, scope(source), [isolation: :repeatable_read], fn repo ->
          public_sql(repo, function, note.resource_id)
        end)
      )
    end
  end

  test "read maintenance waits for the shared authorization lock and rechecks committed revocation" do
    source = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    grant_capabilities!(source, ["note.read"])

    assert {:ok, %{rows: [[1]]}} =
             scoped_sql(source, RequestRepo, @read_function, note.resource_id)

    start_supervised!({MigrationRepo, pool_size: 2})
    parent = self()
    reference = make_ref()

    revoker =
      Task.async(fn ->
        {:ok, :ok} =
          MigrationRepo.transaction(fn ->
            query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

            query!(MigrationRepo, "SELECT pg_advisory_xact_lock(hashtextextended($1,0))", [
              authorization_key(source)
            ])

            query!(
              MigrationRepo,
              "UPDATE core.principal_capabilities SET revoked_at=CURRENT_TIMESTAMP WHERE principal_id=$1 AND vault_id=$2",
              [source.principal_id, source.vault_id]
            )

            send(parent, {reference, :revocation_locked})

            receive do
              {^reference, :commit} -> :ok
            after
              5_000 -> raise "search authorization barrier timed out"
            end
          end)

        :ok
      end)

    try do
      assert_receive {^reference, :revocation_locked}, 5_000

      reader =
        Task.async(fn ->
          ScopedRepo.transact(RequestRepo, scope(source), fn repo ->
            %{rows: [[backend]]} = SafeSQL.query!(repo, "SELECT pg_backend_pid()")
            send(parent, {reference, :reader, backend})
            public_sql(repo, @read_function, note.resource_id)
          end)
        end)

      try do
        assert_receive {^reference, :reader, backend}, 5_000
        assert await_authorization_wait(backend, System.monotonic_time(:millisecond) + 4_000)

        assert %{rows: [[false]]} =
                 query!(
                   RequestRepo,
                   """
                   SELECT EXISTS(SELECT FROM pg_locks WHERE pid=$1 AND relation='content.resources'::regclass
                     AND mode='RowShareLock' AND granted)
                   """,
                   [backend]
                 )

        send(revoker.pid, {reference, :commit})
        assert :ok = Task.await(revoker, 5_000)
        assert_denied(Task.await(reader, 5_000))
      after
        send(revoker.pid, {reference, :commit})
        drain_task(revoker)
        drain_task(reader)
      end
    after
      send(revoker.pid, {reference, :commit})
      drain_task(revoker)
    end
  end

  test "the scoped UUID-only adapter returns bounded counts and sanitizes authorization errors" do
    assert {:module, @reconciler} = Code.ensure_loaded(@reconciler)
    source = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    grant_capabilities!(source, ["note.read"])
    id = Ecto.UUID.load!(note.resource_id)
    assert {:ok, 1} = scoped_adapter(source, RequestRepo, :reconcile, id)

    assert {:error, %Error{code: :forbidden, retryable?: false}} =
             scoped_adapter(source, RequestRepo, :reconcile_note, id)

    assert {:error, %Error{code: :not_found, retryable?: false}} =
             scoped_adapter(source, RequestRepo, :reconcile, Ecto.UUID.generate())
  end

  test "the Note-write adapter works in the existing worker scoped transaction without note.read" do
    assert {:module, @reconciler} = Code.ensure_loaded(@reconciler)
    source = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    grant_capabilities!(source, ["note.write"])

    assert {:ok, 1} =
             scoped_adapter(
               source,
               WorkerRepo,
               :reconcile_note,
               Ecto.UUID.load!(note.resource_id)
             )
  end

  test "the adapter rejects owner content locator and malformed UUID inputs before SQL" do
    assert {:module, @reconciler} = Code.ensure_loaded(@reconciler)

    for function <- [:reconcile, :reconcile_note],
        input <- [
          nil,
          "not-a-uuid",
          KnowledgeFixtures.uuid(),
          %{},
          %{resource_id: Ecto.UUID.generate(), owner_scope_id: Ecto.UUID.generate()},
          %{resource_id: Ecto.UUID.generate(), body: "BODY_CANARY", locator: %{}}
        ] do
      assert {:error, %Error{code: :invalid, retryable?: false}} =
               apply(@reconciler, function, [RequestRepo, input])
    end
  end

  defp canonical_resource!(source, :note), do: KnowledgeFixtures.note!(source)

  defp canonical_resource!(source, :document) do
    {document, _fragment} = KnowledgeFixtures.ready_document!(source)
    document
  end

  defp ready_document_with_fragments!(source, bodies) do
    document = KnowledgeFixtures.document!(source)

    fragments =
      Enum.map(Enum.with_index(bodies), fn {body, ordinal} ->
        {:ok, fragment} =
          DocumentFragment.new(%{
            resource_id: Ecto.UUID.load!(document.resource_id),
            resource_version_id: Ecto.UUID.load!(document.resource_version_id),
            owner_scope_id: Ecto.UUID.load!(source.vault_id),
            classification: :private,
            ordinal: ordinal,
            text: body,
            locator: %{"version" => 1, "kind" => "fragment", "ordinal" => ordinal}
          })

        fragment
      end)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "SELECT set_config('singularity.principal_id',$1,true),set_config('singularity.vault_id',$2,true)",
        [Ecto.UUID.load!(source.principal_id), Ecto.UUID.load!(source.vault_id)]
      )

      query!(MigrationRepo, "SELECT content.claim_document_extraction($1,0,$1,'plain',1)", [
        document.resource_version_id
      ])

      payload =
        Enum.map(fragments, fn fragment ->
          %{
            "id" => fragment.fragment_id,
            "ordinal" => fragment.ordinal,
            "text" => fragment.text,
            "digest" => Base.encode16(fragment.digest, case: :lower),
            "locator" => SourceLocator.to_map(fragment.locator)
          }
        end)

      query!(MigrationRepo, "SELECT content.complete_document_extraction($1,$1,1,$2,$3,'en')", [
        document.resource_version_id,
        payload,
        :crypto.hash(:sha256, Enum.join(bodies))
      ])
    end)

    {document, fragments}
  end

  defp insert_note_version!(source, note, version_id, revision, title, body) do
    query!(
      MigrationRepo,
      "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',$4)",
      [version_id, note.resource_id, source.vault_id, revision]
    )

    query!(
      MigrationRepo,
      """
      INSERT INTO content.note_versions(resource_version_id,resource_id,vault_id,classification,title,markdown,created_by_principal_id,parent_version_id)
      VALUES($1,$2,$3,'private',$4,$5,$6,$7)
      """,
      [
        version_id,
        note.resource_id,
        source.vault_id,
        title,
        body,
        source.principal_id,
        note.resource_version_id
      ]
    )
  end

  defp grant_capabilities!(source, capabilities) do
    Fixtures.with_owner(fn ->
      for capability <- capabilities do
        query!(
          MigrationRepo,
          "INSERT INTO core.capabilities(id,name) VALUES($1,$2) ON CONFLICT(name) DO NOTHING",
          [KnowledgeFixtures.uuid(), capability]
        )

        query!(
          MigrationRepo,
          """
          INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id)
          SELECT $1,$2,id FROM core.capabilities WHERE name=$3
          ON CONFLICT(principal_id,vault_id,capability_id) DO UPDATE SET revoked_at=NULL
          """,
          [source.principal_id, source.vault_id, capability]
        )
      end
    end)
  end

  defp revoke_authority!(source, :capability) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE core.principal_capabilities SET revoked_at=CURRENT_TIMESTAMP WHERE principal_id=$1 AND vault_id=$2",
        [source.principal_id, source.vault_id]
      )
    end)
  end

  defp revoke_authority!(source, :principal) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE identity.principals SET revoked_at=CURRENT_TIMESTAMP WHERE id=$1",
        [source.principal_id]
      )
    end)
  end

  defp revoke_authority!(source, :membership), do: Fixtures.revoke_membership!(source)
  defp scope(source), do: Map.take(source, [:principal_id, :vault_id])

  defp scoped_sql(source, repo, function, resource_id) do
    ScopedRepo.transact(repo, scope(source), fn scoped_repo ->
      public_sql(scoped_repo, function, resource_id)
    end)
  end

  defp public_sql(repo, function, resource_id),
    do: SafeSQL.query(repo, "SELECT content.#{function}($1)", [resource_id])

  defp scoped_adapter(source, repo, function, resource_id) do
    ScopedRepo.transact(repo, scope(source), fn scoped_repo ->
      apply(@reconciler, function, [scoped_repo, resource_id])
    end)
  end

  defp assert_denied(result) do
    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} = result
  end

  defp authorization_key(source),
    do:
      "singularity:authorization:#{Ecto.UUID.load!(source.principal_id)}:#{Ecto.UUID.load!(source.vault_id)}"

  defp await_authorization_wait(backend, deadline) do
    %{rows: [[waiting]]} =
      query!(
        MigrationRepo,
        "SELECT EXISTS(SELECT FROM pg_locks WHERE pid=$1 AND locktype='advisory' AND NOT granted)",
        [backend]
      )

    cond do
      waiting -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> await_authorization_wait(backend, deadline)
    end
  end

  defp drain_task(task) do
    if Process.alive?(task.pid) do
      Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)
    else
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp reconcile_internal(owner_id, resource_id) do
    SafeSQL.query(
      MigrationRepo,
      "SELECT content.reconcile_search_resource_internal($1, $2)",
      [owner_id, resource_id]
    )
  end

  defp projection_rows(resource_id) do
    %{rows: rows} =
      query!(
        MigrationRepo,
        "SELECT #{@projection_fields} FROM content.search_entries " <>
          "WHERE resource_id = $1 ORDER BY ordinal, entry_id COLLATE \"C\"",
        [resource_id]
      )

    rows
  end

  defp corrupt_title!(resource_id) do
    assert %{num_rows: 1} =
             query!(
               MigrationRepo,
               "UPDATE content.search_entries SET title = 'Stale derived title' WHERE resource_id = $1",
               [resource_id]
             )
  end
end
