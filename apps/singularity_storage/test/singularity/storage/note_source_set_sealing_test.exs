defmodule Singularity.Storage.NoteSourceSetSealingTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration

  alias Singularity.Storage.{
    Fixtures,
    KnowledgeFixtures,
    KnowledgeTestGrants,
    MigrationRepo,
    MigrationTestEnvironment,
    ScopedRepo
  }

  alias Singularity.Storage.Postgres.KnowledgeLinkRepository

  @previous 20_261_009_000_300
  @version 20_261_011_000_000
  @seal_constraints "content.note_versions_source_set_seal_check, content.note_attachments_source_set_seal_check, content.note_citations_source_set_seal_check"

  test "committed empty source sets reject later attachments and citations" do
    source = KnowledgeFixtures.source!()
    {document, fragment} = KnowledgeFixtures.ready_document!(source)
    note = create_note!(source)

    for {table, row} <- [
          {"note_attachments", attachment(note, source)},
          {"note_citations", citation(note, document, fragment)}
        ] do
      rejects(fn -> insert!(table, row) end, :check_violation, table <> "_sealed_check")
    end

    assert_seal(note, 0, 0)
  end

  test "committed nonempty sets reject later append without changing their exact counts" do
    source = KnowledgeFixtures.source!()
    {document, fragment} = KnowledgeFixtures.ready_document!(source)
    note = allocate_note(source)
    attached = attachment(note, source)
    cited = citation(note, document, fragment)

    owner(fn ->
      insert_note!(source, note)
      insert!("note_attachments", attached)
      insert!("note_citations", cited)
    end)

    rejects(
      fn ->
        insert!(
          "note_attachments",
          attachment(note, document, %{target_kind: "document", ordinal: 1})
        )
      end,
      :check_violation,
      "note_attachments_sealed_check"
    )

    rejects(
      fn -> insert!("note_citations", %{cited | id: uuid(), ordinal: 1}) end,
      :check_violation,
      "note_citations_sealed_check"
    )

    assert_seal(note, 1, 1)
  end

  test "seals are exact typed Note identities with forced owner RLS and narrow runtime ACLs" do
    source = KnowledgeFixtures.source!()
    other = KnowledgeFixtures.source!()
    note = create_note!(source)
    assert_seal(note, 0, 0)

    assert %{rows: [[true, true, "singularity_table_owner"]]} =
             query!(
               RequestRepo,
               "SELECT relrowsecurity,relforcerowsecurity,pg_get_userbyid(relowner) FROM pg_class WHERE oid=to_regclass('content.note_source_set_seals')"
             )

    assert %{rows: [["content.note_versions", true, true, "a"]]} =
             query!(
               RequestRepo,
               "SELECT confrelid::regclass::text,condeferrable,condeferred,confdeltype::text FROM pg_constraint WHERE conrelid=to_regclass('content.note_source_set_seals') AND contype='f'"
             )

    assert %{rows: [[false, "singularity_table_owner", true]]} =
             query!(
               RequestRepo,
               "SELECT prosecdef,pg_get_userbyid(proowner),proconfig @> ARRAY['search_path=pg_catalog, content'] FROM pg_proc WHERE oid='content.reject_sealed_note_source_insert()'::regprocedure"
             )

    for signature <- [
          "finalize_note_source_set(uuid)",
          "enforce_note_source_seal()",
          "note_source_parent_is_valid(uuid,uuid)"
        ] do
      assert %{rows: [[true, "singularity_table_owner", true, false, false]]} =
               query!(
                 RequestRepo,
                 "SELECT prosecdef,pg_get_userbyid(proowner),proconfig @> ARRAY['search_path=pg_catalog, content'],has_function_privilege('singularity_web',oid,'EXECUTE'),has_function_privilege('singularity_worker',oid,'EXECUTE') FROM pg_proc WHERE oid=$1::text::regprocedure",
                 ["content.#{signature}"]
               )
    end

    for role <- ~w(singularity_web singularity_worker singularity_dispatcher singularity_pre_auth) do
      assert %{rows: [[false, false, false, false]]} =
               query!(
                 RequestRepo,
                 "SELECT has_table_privilege($1,'content.note_source_set_seals','INSERT'),has_table_privilege($1,'content.note_source_set_seals','UPDATE'),has_table_privilege($1,'content.note_source_set_seals','DELETE'),has_table_privilege($1,'content.note_source_set_seals','TRUNCATE')",
                 [role]
               )
    end

    assert %{rows: []} =
             query!(
               RequestRepo,
               "SELECT note_resource_version_id FROM content.note_source_set_seals"
             )

    assert %{rows: [[version]]} =
             ScopedRepo.transact(RequestRepo, source, fn repo ->
               query!(
                 repo,
                 "SELECT note_resource_version_id FROM content.note_source_set_seals WHERE note_resource_version_id=$1",
                 [note.resource_version_id]
               )
             end)

    assert version == note.resource_version_id

    assert %{rows: []} =
             ScopedRepo.transact(RequestRepo, other, fn repo ->
               query!(
                 repo,
                 "SELECT note_resource_version_id FROM content.note_source_set_seals WHERE note_resource_version_id=$1",
                 [note.resource_version_id]
               )
             end)

    rejects(
      fn -> insert!("note_source_set_seals", seal_row(source, source, 0, 0)) end,
      :foreign_key_violation,
      "note_source_set_seals_note_fkey"
    )
  end

  test "seal rows cannot update, delete, reseal, change owner/private identity or falsify counts" do
    source = KnowledgeFixtures.source!()
    note = create_note!(source)

    for statement <- [
          "UPDATE content.note_source_set_seals SET attachment_count=attachment_count",
          "DELETE FROM content.note_source_set_seals"
        ] do
      rejects(
        fn ->
          query!(MigrationRepo, statement <> " WHERE note_resource_version_id=$1", [
            note.resource_version_id
          ])
        end,
        :check_violation,
        "note_source_set_seals_immutable_check"
      )
    end

    rejects(
      fn -> insert!("note_source_set_seals", seal_row(note, source, 0, 0)) end,
      :unique_violation,
      "note_source_set_seals_pkey"
    )

    for override <- [
          %{vault_id: uuid()},
          %{classification: "public"},
          %{attachment_count: -1},
          %{citation_count: 101}
        ] do
      fresh = allocate_note(source)

      rejects(fn ->
        insert_note!(source, fresh)
        insert!("note_source_set_seals", Map.merge(seal_row(fresh, source, 0, 0), override))
      end)
    end

    fresh = allocate_note(source)

    rejects(
      fn ->
        insert_note!(source, fresh)
        insert!("note_source_set_seals", seal_row(fresh, source, 1, 0))
      end,
      :check_violation,
      "note_source_set_seals_consistency_check"
    )

    assert_seal(note, 0, 0)
  end

  test "unauthorized source inserts reach RLS before revealing whether the Note set is sealed" do
    source = KnowledgeFixtures.source!()
    other = KnowledgeFixtures.source!()
    {document, fragment} = KnowledgeFixtures.ready_document!(source)
    sealed = create_note!(source)
    absent = allocate_note(source)
    other_sealed = create_note!(other)
    other_absent = allocate_note(other)

    KnowledgeTestGrants.with_grants(~w(note_attachments note_citations), fn ->
      for note <- [sealed, absent],
          {table, row} <- [
            {"note_attachments", attachment(note, source)},
            {"note_citations", citation(note, document, fragment)}
          ],
          repo <- [RequestRepo, WorkerRepo] do
        unauthenticated = assert_raise Postgrex.Error, fn -> insert!(table, row, repo) end
        assert unauthenticated.postgres.code == :insufficient_privilege

        for context <- [
              other,
              %{source | principal_id: other.principal_id},
              %{source | vault_id: other.vault_id}
            ] do
          rejected =
            assert_raise Postgrex.Error, fn ->
              ScopedRepo.transact(repo, context, fn scoped -> insert!(table, row, scoped) end)
            end

          assert rejected.postgres.code == :insufficient_privilege
        end
      end

      for {table, row} <- [
            {"note_attachments", attachment(sealed, source)},
            {"note_citations", citation(sealed, document, fragment)}
          ] do
        rejected =
          assert_raise Postgrex.Error, fn ->
            ScopedRepo.transact(RequestRepo, source, fn scoped -> insert!(table, row, scoped) end)
          end

        assert rejected.postgres.code == :check_violation
        assert rejected.postgres.constraint == table <> "_sealed_check"
      end

      # An authenticated caller cannot learn another owner's seal state by
      # supplying its own permitted row scope with a guessed foreign Note pin.
      for note <- [other_sealed, other_absent] do
        row = %{
          attachment(sealed, source)
          | note_resource_id: note.resource_id,
            note_resource_version_id: note.resource_version_id
        }

        rejected =
          assert_raise Postgrex.Error, fn ->
            ScopedRepo.transact(RequestRepo, source, fn scoped ->
              insert!("note_attachments", row, scoped)
            end)
          end

        assert rejected.postgres.code == :foreign_key_violation
        assert rejected.postgres.constraint == "note_attachments_note_fkey"
      end

      Fixtures.revoke_membership!(source)

      for note <- [sealed, absent], repo <- [RequestRepo, WorkerRepo] do
        rejected =
          assert_raise Postgrex.Error, fn ->
            ScopedRepo.transact(repo, source, fn scoped ->
              insert!("note_attachments", attachment(note, source), scoped)
            end)
          end

        assert rejected.postgres.code == :insufficient_privilege
      end
    end)
  end

  test "deferred construction accepts children before typed Note and reverse ordinals" do
    source = KnowledgeFixtures.source!()
    {document, fragment} = KnowledgeFixtures.ready_document!(source)
    note = allocate_note(source)

    owner(fn ->
      insert!(
        "note_attachments",
        attachment(note, document, %{target_kind: "document", ordinal: 1})
      )

      insert!("note_attachments", attachment(note, source))
      insert!("note_citations", citation(note, document, fragment, %{ordinal: 1}))
      insert!("note_citations", citation(note, document, fragment))
      insert_note!(source, note)
    end)

    assert_seal(note, 2, 2)
  end

  test "sealed children cannot be updated or deleted even without changing their count" do
    source = KnowledgeFixtures.source!()
    {document, fragment} = KnowledgeFixtures.ready_document!(source)
    note = allocate_note(source)

    owner(fn ->
      insert_note!(source, note)
      insert!("note_attachments", attachment(note, source))
      insert!("note_citations", citation(note, document, fragment))
    end)

    for table <- ~w(note_attachments note_citations),
        operation <- [
          "UPDATE content.#{table} SET ordinal=ordinal",
          "DELETE FROM content.#{table}"
        ] do
      rejects(
        fn ->
          query!(MigrationRepo, operation <> " WHERE note_resource_version_id=$1", [
            note.resource_version_id
          ])
        end,
        :check_violation,
        table <> "_immutable_check"
      )
    end

    assert_seal(note, 1, 1)
  end

  test "named immediate finalization seals even empty sets and re-deferring never reopens them" do
    source = KnowledgeFixtures.source!()
    {document, fragment} = KnowledgeFixtures.ready_document!(source)

    for nonempty? <- [false, true] do
      note = allocate_note(source)
      row = attachment(note, source)

      rejects(
        fn ->
          insert_note!(source, note)
          if nonempty?, do: insert!("note_attachments", row)
          query!(MigrationRepo, "SET CONSTRAINTS " <> @seal_constraints <> " IMMEDIATE")
          query!(MigrationRepo, "SET CONSTRAINTS " <> @seal_constraints <> " DEFERRED")
          insert!("note_citations", citation(note, document, fragment))
        end,
        :check_violation,
        "note_citations_sealed_check"
      )

      assert_absent(note)
    end
  end

  test "the adapter immediately seals an empty new Note and preserves unrelated immediate modes" do
    source = KnowledgeFixtures.source!()
    note = allocate_note(source)

    context = %{
      repo: RequestRepo,
      principal_id: text(source.principal_id),
      owner_scope_id: text(source.vault_id)
    }

    set = %{
      note_resource_id: text(note.resource_id),
      note_resource_version_id: text(note.resource_version_id),
      owner_scope_id: context.owner_scope_id,
      classification: :private,
      attachments: [],
      citations: [],
      targets: [],
      fragments: []
    }

    # Note publication uses the real scoped request connection, including typed rows.
    assert {:error, :observed_immediate_parent_constraint} =
             with_link_read_grants(fn ->
               ScopedRepo.transact(RequestRepo, source, fn repo ->
                 query!(repo, "SET CONSTRAINTS content.note_versions_parent_fkey IMMEDIATE")
                 insert_note!(source, note, repo)
                 assert {:ok, _} = KnowledgeLinkRepository.insert_set(context, set)

                 assert %{rows: [[0, 0]]} =
                          query!(
                            repo,
                            "SELECT attachment_count,citation_count FROM content.note_source_set_seals WHERE note_resource_version_id=$1",
                            [note.resource_version_id]
                          )

                 later =
                   allocate_note(source, %{
                     resource_id: note.resource_id,
                     revision: 1,
                     parent_version_id: uuid()
                   })

                 error = assert_raise Postgrex.Error, fn -> insert_note!(source, later, repo) end
                 assert error.postgres.constraint == "note_versions_parent_fkey"
                 repo.rollback(:observed_immediate_parent_constraint)
               end)
             end)

    assert_absent(note)
  end

  test "gaps and more than 100 actual members abort full construction" do
    source = KnowledgeFixtures.source!()
    {document, fragment} = KnowledgeFixtures.ready_document!(source)

    for {amount, first_ordinal} <- [{1, 1}, {101, 0}] do
      note = allocate_note(source)

      rejects(
        fn ->
          insert_note!(source, note)

          for ordinal <- first_ordinal..(first_ordinal + amount - 1),
              do:
                insert!("note_citations", citation(note, document, fragment, %{ordinal: ordinal}))

          assert %{rows: [[^amount]]} =
                   query!(
                     MigrationRepo,
                     "SELECT count(*) FROM content.note_citations WHERE note_resource_version_id=$1",
                     [note.resource_version_id]
                   )
        end,
        :check_violation
      )

      assert_absent(note)
    end
  end

  test "the union of attachment and citation targets is bounded independently of each collection" do
    source = KnowledgeFixtures.source!()
    {document, fragment} = KnowledgeFixtures.ready_document!(source)
    targets = for _ <- 1..100, do: create_note!(source)
    note = allocate_note(source)

    rejects(
      fn ->
        insert_note!(source, note)

        for {target, ordinal} <- Enum.with_index(targets),
            do:
              insert!(
                "note_attachments",
                attachment(note, target, %{target_kind: "note", ordinal: ordinal})
              )

        insert!("note_citations", citation(note, document, fragment))
      end,
      :check_violation,
      "note_source_set_seals_bounds_check"
    )

    assert_absent(note)
  end

  test "rollback removes the new Note, both source collections and their derived seal" do
    source = KnowledgeFixtures.source!()
    note = allocate_note(source)

    with_repo(fn ->
      assert {:error, :deliberate} =
               MigrationRepo.transaction(fn ->
                 query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")
                 insert_note!(source, note)
                 insert!("note_attachments", attachment(note, source))
                 query!(MigrationRepo, "SET CONSTRAINTS " <> @seal_constraints <> " IMMEDIATE")
                 MigrationRepo.rollback(:deliberate)
               end)
    end)

    assert_absent(note)
  end

  test "a child inserted while the containing Note and seal are invisible cannot append at commit" do
    source = KnowledgeFixtures.source!()
    note = allocate_note(source)
    parent = self()

    with_repo(fn ->
      writer =
        Task.async(fn ->
          transaction_outcome(fn ->
            insert_note!(source, note)
            send(parent, {:note_uncommitted, self()})

            receive do
              :publish -> :ok
            after
              10_000 -> raise "Note publication barrier timed out"
            end
          end)
        end)

      try do
        assert_receive {:note_uncommitted, writer_pid}, 10_000

        appender =
          Task.async(fn ->
            transaction_outcome(fn ->
              insert!("note_attachments", attachment(note, source))
              send(parent, {:child_uncommitted, self()})

              receive do
                :finalize -> :ok
              after
                10_000 -> raise "child finalization barrier timed out"
              end
            end)
          end)

        try do
          assert_receive {:child_uncommitted, appender_pid}, 10_000
          send(writer_pid, :publish)
          assert {:ok, :ok} = Task.await(writer, 10_000)
          send(appender_pid, :finalize)

          assert {:rejected, :check_violation, "note_source_set_seals_consistency_check"} =
                   Task.await(appender, 10_000)
        after
          Task.shutdown(appender, :brutal_kill)
        end
      after
        Task.shutdown(writer, :brutal_kill)
      end
    end)

    assert_seal(note, 0, 0)
  end

  test "exact deleted parent members retain evidence independently and can reorder" do
    source = KnowledgeFixtures.source!()
    {document, fragment} = KnowledgeFixtures.ready_document!(source)
    note = allocate_note(source)
    attached = attachment(note, source)
    doc_attached = attachment(note, document, %{target_kind: "document", ordinal: 1})
    cited = citation(note, document, fragment)

    owner(fn ->
      insert_note!(source, note)
      insert!("note_attachments", attached)
      insert!("note_attachments", doc_attached)
      insert!("note_citations", cited)
    end)

    tombstone!(source, document)

    next =
      allocate_note(source, %{
        resource_id: note.resource_id,
        revision: 1,
        parent_version_id: note.resource_version_id
      })

    owner(fn ->
      insert_note!(source, next)
      insert!("note_attachments", repin(doc_attached, next, 0))
      insert!("note_attachments", repin(attached, next, 1))
      insert!("note_citations", repin(cited, next, 0))
    end)

    assert_seal(next, 2, 1)
    assert_seal(note, 2, 1)
  end

  test "a merge can retain exact tombstoned members from either direct lower parent" do
    source = KnowledgeFixtures.source!()
    {document, fragment} = KnowledgeFixtures.ready_document!(source)
    note = allocate_note(source)
    attached = attachment(note, source)

    owner(fn ->
      insert_note!(source, note)
      insert!("note_attachments", attached)
    end)

    competing =
      allocate_note(source, %{
        resource_id: note.resource_id,
        revision: 1,
        parent_version_id: note.resource_version_id
      })

    cited = citation(competing, document, fragment)

    owner(fn ->
      insert_note!(source, competing)
      insert!("note_citations", cited)
    end)

    tombstone!(source, document)

    merged =
      allocate_note(source, %{
        resource_id: note.resource_id,
        revision: 2,
        parent_version_id: note.resource_version_id,
        merge_parent_version_id: competing.resource_version_id
      })

    owner(fn ->
      insert_note!(source, merged)
      insert!("note_attachments", repin(attached, merged, 0))
      insert!("note_citations", repin(cited, merged, 0))
    end)

    assert_seal(merged, 1, 1)
  end

  test "the real adapter accepts retained deleted evidence and still validates each changed or mixed member live" do
    source = KnowledgeFixtures.source!()
    {document, fragment} = KnowledgeFixtures.ready_document!(source)
    note = allocate_note(source)

    owner(fn ->
      insert_note!(source, note)
      insert!("note_attachments", attachment(note, source))

      insert!(
        "note_attachments",
        attachment(note, document, %{target_kind: "document", ordinal: 1})
      )

      insert!("note_citations", citation(note, document, fragment))
    end)

    context = %{
      repo: RequestRepo,
      principal_id: text(source.principal_id),
      owner_scope_id: text(source.vault_id)
    }

    KnowledgeTestGrants.with_grants(
      ~w(note_attachments note_citations document_versions document_fragments),
      fn ->
        assert {:ok, old} =
                 KnowledgeLinkRepository.list_set(
                   context,
                   text(note.resource_id),
                   text(note.resource_version_id)
                 )

        tombstone!(source, document)

        next =
          allocate_note(source, %{
            resource_id: note.resource_id,
            revision: 1,
            parent_version_id: note.resource_version_id
          })

        copy = copy_set(old, next)

        copy = %{
          copy
          | attachments:
              copy.attachments
              |> Enum.reverse()
              |> Enum.with_index()
              |> Enum.map(fn {member, ordinal} -> %{member | ordinal: ordinal} end)
        }

        assert {:ok, stored} =
                 ScopedRepo.transact(RequestRepo, source, fn repo ->
                   insert_note!(source, next, repo)
                   KnowledgeLinkRepository.insert_set(context, copy)
                 end)

        assert stored.attachments == copy.attachments
        assert stored.citations == copy.citations
        assert_seal(next, 2, 1)

        for mode <- [:changed_label, :new_citation_on_retained_target] do
          fresh =
            allocate_note(source, %{
              resource_id: note.resource_id,
              revision: 2,
              parent_version_id: next.resource_version_id
            })

          input = copy_set(stored, fresh)

          input =
            case mode do
              :changed_label ->
                %{
                  input
                  | attachments: Enum.map(input.attachments, &%{&1 | label: "new evidence"})
                }

              :new_citation_on_retained_target ->
                %{
                  input
                  | citations:
                      Enum.map(input.citations, &%{&1 | citation_id: Ecto.UUID.generate()})
                }
            end

          assert {:error, %Singularity.Core.Error{code: :not_found}} =
                   ScopedRepo.transact(RequestRepo, source, fn repo ->
                     insert_note!(source, fresh, repo)
                     KnowledgeLinkRepository.insert_set(context, input)
                   end)

          assert_absent(fresh)
        end
      end
    )
  end

  test "new or changed attachment fields require live evidence even beside a retained member of the same target" do
    source = KnowledgeFixtures.source!()
    {document, fragment} = KnowledgeFixtures.ready_document!(source)
    note = allocate_note(source)
    attached = attachment(note, source)

    owner(fn ->
      insert_note!(source, note)
      insert!("note_attachments", attached)
    end)

    tombstone!(source)

    for override <- [
          %{id: uuid()},
          %{label: "changed"},
          %{target_resource_id: uuid()},
          %{target_resource_version_id: uuid()},
          %{target_kind: "note"},
          %{role: "other"}
        ] do
      next =
        allocate_note(source, %{
          resource_id: note.resource_id,
          revision: 1,
          parent_version_id: note.resource_version_id
        })

      rejects(fn ->
        insert_note!(source, next)
        insert!("note_attachments", Map.merge(repin(attached, next, 0), override))
      end)

      assert_absent(next)
    end

    next =
      allocate_note(source, %{
        resource_id: note.resource_id,
        revision: 1,
        parent_version_id: note.resource_version_id
      })

    # Restore source while constructing the independent Document, then retain a
    # tombstoned Document attachment beside a NEW citation to that same Document.
    owner(fn ->
      query!(MigrationRepo, "UPDATE content.resources SET deleted_at=NULL WHERE id=$1", [
        source.resource_id
      ])
    end)

    parent = allocate_note(source)

    owner(fn ->
      insert_note!(source, parent)
      insert!("note_attachments", attachment(parent, document, %{target_kind: "document"}))
    end)

    tombstone!(document)

    mixed = %{
      next
      | resource_id: parent.resource_id,
        parent_version_id: parent.resource_version_id
    }

    rejects(
      fn ->
        insert_note!(source, mixed)

        %{rows: [[id]]} =
          query!(
            MigrationRepo,
            "SELECT id FROM content.note_attachments WHERE note_resource_version_id=$1",
            [parent.resource_version_id]
          )

        insert!(
          "note_attachments",
          attachment(mixed, document, %{id: id, target_kind: "document"})
        )

        insert!("note_citations", citation(mixed, document, fragment))
      end,
      :check_violation,
      "note_citations_source_check"
    )
  end

  test "every changed citation identity, pin, fragment or locator requires fresh live evidence" do
    source = KnowledgeFixtures.source!()
    {document, fragment} = KnowledgeFixtures.ready_document!(source)
    note = allocate_note(source)
    cited = citation(note, document, fragment)

    owner(fn ->
      insert_note!(source, note)
      insert!("note_citations", cited)
    end)

    tombstone!(document)

    for override <- [
          %{id: uuid()},
          %{source_resource_id: uuid()},
          %{source_resource_version_id: uuid()},
          %{fragment_id: String.duplicate("f", 64)},
          %{locator: %{"version" => 1, "kind" => "text", "start_line" => 2, "end_line" => 2}}
        ] do
      next =
        allocate_note(source, %{
          resource_id: note.resource_id,
          revision: 1,
          parent_version_id: note.resource_version_id
        })

      rejects(fn ->
        insert_note!(source, next)
        insert!("note_citations", Map.merge(repin(cited, next, 0), override))
      end)

      assert_absent(next)
    end
  end

  test "self, non-lower and cyclic ancestry cannot establish retained source evidence" do
    source = KnowledgeFixtures.source!()
    note = create_note!(source)

    for shape <- [:self, :higher_parent, :cycle] do
      first = allocate_note(source, %{resource_id: note.resource_id, revision: 1})
      second = allocate_note(source, %{resource_id: note.resource_id, revision: 2})

      rejects(
        fn ->
          case shape do
            :self ->
              insert_note!(source, %{first | parent_version_id: first.resource_version_id})

            :higher_parent ->
              insert_note!(source, %{second | parent_version_id: note.resource_version_id})
              insert_note!(source, %{first | parent_version_id: second.resource_version_id})

            :cycle ->
              insert_note!(source, %{first | parent_version_id: second.resource_version_id})
              insert_note!(source, %{second | parent_version_id: first.resource_version_id})
          end
        end,
        :check_violation,
        "note_versions_source_parent_check"
      )

      assert_absent(first)
      assert_absent(second)
    end
  end

  test "deferred ancestry can construct a lower direct parent after its child" do
    source = KnowledgeFixtures.source!()
    note = allocate_note(source)

    next =
      allocate_note(source, %{
        resource_id: note.resource_id,
        revision: 1,
        parent_version_id: note.resource_version_id
      })

    owner(fn ->
      insert_resource!(note)
      insert_note!(source, next)
      insert_note_version!(source, note, MigrationRepo)
    end)

    assert_seal(note, 0, 0)
    assert_seal(next, 0, 0)
  end

  test "historical migration backfills empty and nonempty sets without rewriting children or checking deleted targets" do
    MigrationTestEnvironment.with_database(@previous, fn _ ->
      source = KnowledgeFixtures.source!()
      {document, fragment} = KnowledgeFixtures.ready_document!(source)
      empty = create_note!(source)
      note = allocate_note(source)

      owner(fn ->
        insert_note!(source, note)
        insert!("note_attachments", attachment(note, source))
        insert!("note_citations", citation(note, document, fragment))
      end)

      before = children(note)
      tombstone!(source, document)
      migrate!()
      assert_seal(empty, 0, 0)
      assert_seal(note, 1, 1)
      assert children(note) == before
    end)
  end

  test "historical oversized membership aborts the entire forward migration" do
    MigrationTestEnvironment.with_database(@previous, fn _ ->
      source = KnowledgeFixtures.source!()
      {document, fragment} = KnowledgeFixtures.ready_document!(source)
      note = allocate_note(source)

      owner(fn ->
        insert_note!(source, note)

        for ordinal <- 0..100,
            do: insert!("note_citations", citation(note, document, fragment, %{ordinal: ordinal}))
      end)

      before = children(note)
      error = assert_raise Postgrex.Error, &migrate!/0
      assert error.postgres.constraint == "note_source_set_seals_preflight_check"

      assert %{rows: [[nil]]} =
               query!(RequestRepo, "SELECT to_regclass('content.note_source_set_seals')")

      assert children(note) == before
    end)
  end

  test "the seal migration is forward-only" do
    module = Singularity.Storage.Migrations.SealNoteSourceSets
    assert Code.ensure_loaded?(module)

    assert_raise Ecto.MigrationError, "Note source set sealing migration is forward-only", fn ->
      apply(module, :down, [])
    end
  end

  defp allocate_note(source, attrs \\ %{}) do
    Map.merge(
      %{
        resource_id: uuid(),
        resource_version_id: uuid(),
        vault_id: source.vault_id,
        revision: 0,
        parent_version_id: nil,
        merge_parent_version_id: nil
      },
      attrs
    )
  end

  defp create_note!(source) do
    note = allocate_note(source)
    owner(fn -> insert_note!(source, note) end)
    note
  end

  defp insert_note!(source, note, repo \\ MigrationRepo) do
    if note.revision == 0, do: insert_resource!(note, repo)
    insert_note_version!(source, note, repo)
  end

  defp insert_resource!(note, repo \\ MigrationRepo) do
    query!(
      repo,
      "INSERT INTO content.resources(id,vault_id,classification,kind,current_version_id,title) VALUES($1,$2,'private','note',$3,'Note')",
      [note.resource_id, note.vault_id, note.resource_version_id]
    )
  end

  defp insert_note_version!(source, note, repo) do
    query!(
      repo,
      "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',$4)",
      [note.resource_version_id, note.resource_id, note.vault_id, note.revision]
    )

    query!(
      repo,
      "INSERT INTO content.note_versions(resource_version_id,resource_id,vault_id,classification,title,markdown,created_by_principal_id,parent_version_id,merge_parent_version_id,inserted_at) VALUES($1,$2,$3,'private','Note','body',$4,$5,$6,CURRENT_TIMESTAMP)",
      [
        note.resource_version_id,
        note.resource_id,
        note.vault_id,
        source.principal_id,
        note.parent_version_id,
        note.merge_parent_version_id
      ]
    )
  end

  defp attachment(note, source, attrs \\ %{}) do
    Map.merge(
      %{
        id: uuid(),
        note_resource_id: note.resource_id,
        note_resource_version_id: note.resource_version_id,
        vault_id: note.vault_id,
        classification: "private",
        target_resource_id: source.resource_id,
        target_resource_version_id: source.resource_version_id,
        target_kind: "asset",
        ordinal: 0,
        role: "source",
        label: nil
      },
      attrs
    )
  end

  defp citation(note, document, fragment, attrs \\ %{}) do
    Map.merge(
      %{
        id: uuid(),
        note_resource_id: note.resource_id,
        note_resource_version_id: note.resource_version_id,
        vault_id: note.vault_id,
        classification: "private",
        source_resource_id: document.resource_id,
        source_resource_version_id: document.resource_version_id,
        fragment_id: fragment.fragment_id,
        locator: Singularity.Core.SourceLocator.to_map(fragment.locator),
        ordinal: 0
      },
      attrs
    )
  end

  defp seal_row(note, source, attachments, citations),
    do: %{
      note_resource_version_id: note.resource_version_id,
      note_resource_id: note.resource_id,
      vault_id: source.vault_id,
      classification: "private",
      attachment_count: attachments,
      citation_count: citations
    }

  defp repin(row, note, ordinal),
    do: %{
      row
      | note_resource_id: note.resource_id,
        note_resource_version_id: note.resource_version_id,
        ordinal: ordinal
    }

  defp copy_set(set, note) do
    version = text(note.resource_version_id)

    %{
      set
      | note_resource_version_id: version,
        attachments: Enum.map(set.attachments, &%{&1 | note_resource_version_id: version}),
        citations: Enum.map(set.citations, &%{&1 | note_resource_version_id: version})
    }
  end

  defp uuid, do: KnowledgeFixtures.uuid()
  defp text(id), do: Ecto.UUID.load!(id)
  defp owner(fun), do: Fixtures.with_owner(fun)

  defp insert!(table, row, repo \\ MigrationRepo) do
    {fields, values} = row |> Enum.sort() |> Enum.unzip()

    query!(
      repo,
      "INSERT INTO content.#{table}(#{Enum.join(fields, ",")},inserted_at) VALUES(#{Enum.map_join(1..length(fields), ",", &"$#{&1}")},CURRENT_TIMESTAMP)",
      values
    )
  end

  defp rejects(fun, code \\ nil, constraint \\ nil) do
    error = assert_raise Postgrex.Error, fn -> owner(fun) end
    assert error.postgres.code in [:check_violation, :foreign_key_violation, :unique_violation]
    if code, do: assert(error.postgres.code == code)
    if constraint, do: assert(error.postgres.constraint == constraint)
  end

  defp assert_seal(note, attached, cited) do
    owner(fn ->
      assert %{rows: [[resource, owner_id, "private", ^attached, ^cited]]} =
               query!(
                 MigrationRepo,
                 "SELECT note_resource_id,vault_id,classification,attachment_count,citation_count FROM content.note_source_set_seals WHERE note_resource_version_id=$1",
                 [note.resource_version_id]
               )

      assert resource == note.resource_id
      assert owner_id == note.vault_id

      assert %{rows: [[^attached, ^cited]]} =
               query!(
                 MigrationRepo,
                 "SELECT (SELECT count(*) FROM content.note_attachments WHERE note_resource_version_id=$1),(SELECT count(*) FROM content.note_citations WHERE note_resource_version_id=$1)",
                 [note.resource_version_id]
               )
    end)
  end

  defp assert_absent(note) do
    owner(fn ->
      assert %{rows: [[0, 0, 0, 0, 0]]} =
               query!(
                 MigrationRepo,
                 "SELECT (SELECT count(*) FROM content.resource_versions WHERE id=$1),(SELECT count(*) FROM content.note_versions WHERE resource_version_id=$1),(SELECT count(*) FROM content.note_attachments WHERE note_resource_version_id=$1),(SELECT count(*) FROM content.note_citations WHERE note_resource_version_id=$1),(SELECT count(*) FROM content.note_source_set_seals WHERE note_resource_version_id=$1)",
                 [note.resource_version_id]
               )
    end)
  end

  defp tombstone!(first, second \\ nil) do
    identities = if second, do: [first.resource_id, second.resource_id], else: [first.resource_id]

    owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id=ANY($1::uuid[])",
        [identities]
      )
    end)
  end

  defp children(note) do
    owner(fn ->
      query!(
        MigrationRepo,
        "SELECT (SELECT jsonb_agg(to_jsonb(a) ORDER BY ordinal) FROM content.note_attachments a WHERE note_resource_version_id=$1),(SELECT jsonb_agg(to_jsonb(c) ORDER BY ordinal) FROM content.note_citations c WHERE note_resource_version_id=$1)",
        [note.resource_version_id]
      ).rows
    end)
  end

  defp with_repo(fun) do
    {:ok, pid} = MigrationRepo.start_link(pool_size: 3)

    try do
      fun.()
    after
      Supervisor.stop(pid)
    end
  end

  defp owner_transaction(fun),
    do:
      MigrationRepo.transaction(fn ->
        query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")
        fun.()
      end)

  defp transaction_outcome(fun) do
    owner_transaction(fun)
  rescue
    error in Postgrex.Error ->
      postgres = error.postgres || %{}
      {:rejected, Map.get(postgres, :code), Map.get(postgres, :constraint)}

    exception ->
      {:unexpected_error, exception.__struct__}
  catch
    kind, _reason -> {:unexpected_exit, kind}
  end

  defp with_link_read_grants(fun) do
    tables = ~w(note_attachments note_citations document_fragments)

    existing =
      owner(fn ->
        assert %{rows: [[database]]} = query!(MigrationRepo, "SELECT current_database()")
        assert database =~ ~r/\Asingularity_test_[0-9a-f]{24}\z/

        Map.new(tables, fn table ->
          assert %{rows: [[allowed?]]} =
                   query!(
                     MigrationRepo,
                     "SELECT has_table_privilege('singularity_web',$1,'SELECT')",
                     ["content.#{table}"]
                   )

          query!(MigrationRepo, "GRANT SELECT ON content.#{table} TO singularity_web")
          {table, allowed?}
        end)
      end)

    try do
      fun.()
    after
      owner(fn ->
        for {table, false} <- existing,
            do: query!(MigrationRepo, "REVOKE SELECT ON content.#{table} FROM singularity_web")
      end)
    end
  end

  defp migrate! do
    with_repo(fn ->
      options = Code.compiler_options()
      Code.compiler_options(ignore_module_conflict: true)

      try do
        path =
          :singularity_storage |> :code.priv_dir() |> to_string() |> Path.join("repo/migrations")

        Ecto.Migrator.run(MigrationRepo, path, :up, to: @version, log: false)
      after
        Code.compiler_options(options)
      end
    end)
  end
end
