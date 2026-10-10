defmodule Singularity.Storage.Postgres.KnowledgeLinkRepositoryTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  alias Singularity.Core.{
    DocumentFragment,
    Error,
    NoteAttachment,
    NoteAttachmentReference,
    NoteCitation,
    NoteCitationReference,
    NoteSourceSet,
    SourceLocator
  }

  alias Singularity.Storage.{
    Fixtures,
    KnowledgeFixtures,
    KnowledgeTestGrants,
    MigrationRepo,
    ScopedRepo
  }

  alias Singularity.Storage.Postgres.KnowledgeLinkRepository

  defmodule PausedReadRepo do
    alias Singularity.Storage.RequestRepo
    defdelegate in_transaction?(), to: RequestRepo
    defdelegate rollback(reason), to: RequestRepo
    defdelegate all(query, options), to: RequestRepo

    def transaction(fun, options) do
      RequestRepo.transaction(
        fn ->
          parent = Process.get(:source_set_reader_parent)

          %{rows: [[backend]]} =
            Singularity.Storage.SafeSQL.query!(RequestRepo, "SELECT pg_backend_pid()", [])

          send(parent, {:reader_started, backend})
          fun.()
        end,
        options
      )
    end
  end

  setup do
    source = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note_identity!(source)
    {document, fragment} = KnowledgeFixtures.ready_document!(source)

    context = %{
      repo: RequestRepo,
      principal_id: text(source.principal_id),
      owner_scope_id: text(source.vault_id),
      correlation_id: Ecto.UUID.generate()
    }

    identity = %{
      note_resource_id: text(note.resource_id),
      note_resource_version_id: text(note.resource_version_id),
      owner_scope_id: context.owner_scope_id,
      classification: :private
    }

    targets =
      [target(source, :asset), target(document, :document)]
      |> Enum.sort_by(&{&1.resource_id, &1.resource_version_id})

    {:ok, attachment} =
      NoteAttachment.new(
        Map.merge(identity, %{
          attachment_id: Ecto.UUID.generate(),
          target_resource_id: text(source.resource_id),
          target_resource_version_id: text(source.resource_version_id),
          target_kind: :asset,
          role: :source,
          ordinal: 0,
          label: "Original"
        })
      )

    {:ok, citation} =
      NoteCitation.new(
        Map.merge(identity, %{
          citation_id: Ecto.UUID.generate(),
          source_resource_id: text(document.resource_id),
          source_resource_version_id: text(document.resource_version_id),
          fragment_id: fragment.fragment_id,
          locator: fragment.locator,
          ordinal: 0
        })
      )

    {:ok, set} =
      NoteSourceSet.new(
        Map.merge(identity, %{
          attachments: [attachment],
          citations: [citation],
          targets: targets,
          fragments: [fragment]
        })
      )

    %{source: source, note: note, document: document, context: context, set: set}
  end

  test "requires an authenticated existing scoped transaction", c do
    grants(fn ->
      assert {:error, %Error{code: :invalid}} =
               KnowledgeLinkRepository.insert_set(c.context, c.set)

      assert {:ok, {:error, %Error{code: :invalid}}} =
               RequestRepo.transaction(fn ->
                 KnowledgeLinkRepository.insert_set(c.context, c.set)
               end)
    end)
  end

  test "context identifiers require canonical lowercase UUID text", c do
    grants(fn ->
      context = %{c.context | principal_id: String.upcase(c.context.principal_id)}

      assert {:error, %Error{code: :invalid}} =
               KnowledgeLinkRepository.list_set(
                 context,
                 c.set.note_resource_id,
                 c.set.note_resource_version_id
               )
    end)
  end

  test "inserts and reads the complete immutable exact-version source set and replays", c do
    grants(fn ->
      assert {:ok, set} =
               create_note_and_transact(c, fn ->
                 KnowledgeLinkRepository.insert_set(c.context, c.set)
               end)

      assert set == c.set

      assert {:ok, ^set} =
               KnowledgeLinkRepository.list_set(
                 c.context,
                 set.note_resource_id,
                 set.note_resource_version_id
               )

      assert {:ok, ^set} =
               transact(c, fn -> KnowledgeLinkRepository.insert_set(c.context, c.set) end)

      assert {:error, %Error{code: :not_found}} =
               KnowledgeLinkRepository.list_set(
                 c.context,
                 set.note_resource_id,
                 Ecto.UUID.generate()
               )
    end)
  end

  test "partial and changed stored sets conflict without changing old rows", c do
    grants(fn ->
      partial = %{
        c.set
        | citations: [],
          fragments: [],
          targets: Enum.filter(c.set.targets, &(&1.kind == :asset))
      }

      assert {:ok, _} =
               create_note_and_transact(c, fn ->
                 KnowledgeLinkRepository.insert_set(c.context, partial)
               end)

      assert {:error, %Error{code: :conflict}} =
               transact(c, fn -> KnowledgeLinkRepository.insert_set(c.context, c.set) end)

      [attachment] = partial.attachments
      changed = %{partial | attachments: [%{attachment | label: "Changed"}]}

      assert {:error, %Error{code: :conflict}} =
               transact(c, fn -> KnowledgeLinkRepository.insert_set(c.context, changed) end)

      assert {:ok, ^partial} =
               KnowledgeLinkRepository.list_set(
                 c.context,
                 partial.note_resource_id,
                 partial.note_resource_version_id
               )
    end)
  end

  test "duplicate and reordered validated witnesses do not alter persisted membership", c do
    grants(fn ->
      witnesses = %{
        c.set
        | targets: Enum.reverse(c.set.targets) ++ c.set.targets,
          fragments: c.set.fragments ++ c.set.fragments
      }

      assert {:ok, _} = NoteSourceSet.new(witnesses)

      assert {:ok, set} =
               create_note_and_transact(c, fn ->
                 KnowledgeLinkRepository.insert_set(c.context, witnesses)
               end)

      assert set == c.set

      assert {:ok, ^set} =
               transact(c, fn -> KnowledgeLinkRepository.insert_set(c.context, witnesses) end)
    end)
  end

  test "equal replay still forces pending named source constraints", c do
    other_note = KnowledgeFixtures.note_identity!(c.source)

    grants(fn ->
      assert {:ok, _} =
               create_note_and_transact(c, fn ->
                 KnowledgeLinkRepository.insert_set(c.context, c.set)
               end)

      assert {:error, %Error{}} =
               transact(c, fn ->
                 KnowledgeFixtures.insert_note!(RequestRepo, c.source, other_note)

                 query!(
                   RequestRepo,
                   "INSERT INTO content.note_attachments(note_resource_version_id,id,note_resource_id,vault_id,classification,target_resource_id,target_resource_version_id,target_kind,ordinal,role,inserted_at) VALUES($1,$2,$3,$4,'private',$5,$6,'note',0,'source',CURRENT_TIMESTAMP)",
                   [
                     other_note.resource_version_id,
                     KnowledgeFixtures.uuid(),
                     other_note.resource_id,
                     c.source.vault_id,
                     c.source.resource_id,
                     c.source.resource_version_id
                   ]
                 )

                 case KnowledgeLinkRepository.insert_set(c.context, c.set) do
                   {:ok, _} -> RequestRepo.rollback(:incorrect_replay_success)
                   result -> result
                 end
               end)
    end)
  end

  for outer_scope <- [false, true] do
    @tag outer_scope: outer_scope
    test "fresh version publication stays atomic with outer scope #{outer_scope}", c do
      # Ecto SQL looks up repo metadata directly; the alias shares RequestRepo's
      # pool while reporting the reader backend before its resource lock.
      {:ok, bridge} = Agent.start_link(fn -> nil end, name: PausedReadRepo)

      :ok =
        Ecto.Repo.Registry.associate(
          bridge,
          PausedReadRepo,
          Ecto.Adapter.lookup_meta(RequestRepo)
        )

      on_exit(fn -> if Process.alive?(bridge), do: Agent.stop(bridge) end)

      grants(fn ->
        parent = self()

        Fixtures.with_owner(fn ->
          KnowledgeFixtures.insert_note!(MigrationRepo, c.source, c.note)
        end)

        published = %{c.note | resource_version_id: KnowledgeFixtures.uuid()}
        set = set_for_version(c.set, published)

        writer =
          Task.async(fn ->
            transact(c, fn ->
              query!(RequestRepo, "SELECT id FROM content.resources WHERE id=$1 FOR UPDATE", [
                c.note.resource_id
              ])

              insert_next_version!(c, published)
              assert {:ok, ^set} = KnowledgeLinkRepository.insert_set(c.context, set)
              %{rows: [[backend]]} = query!(RequestRepo, "SELECT pg_backend_pid()")
              send(parent, {:writer_ready, self(), backend})

              receive do
                :commit_source_set -> {:ok, set}
              after
                10_000 -> raise "source-set writer handshake timed out"
              end
            end)
          end)

        try do
          assert_receive {:writer_ready, writer_pid, writer_backend}, 5_000

          task =
            Task.async(fn ->
              Process.put(:source_set_reader_parent, parent)

              read = fn ->
                KnowledgeLinkRepository.list_set(
                  %{c.context | repo: PausedReadRepo},
                  c.set.note_resource_id,
                  c.set.note_resource_version_id
                )
              end

              if c.outer_scope do
                ScopedRepo.transact(
                  PausedReadRepo,
                  %{principal_id: c.context.principal_id, vault_id: c.context.owner_scope_id},
                  fn _ -> read.() end
                )
              else
                read.()
              end
            end)

          try do
            assert_receive {:reader_started, reader_backend}, 5_000

            try do
              assert writer_blocked?(writer_backend, reader_backend, 100)
            after
              send(writer_pid, :commit_source_set)
            end

            empty = %{c.set | attachments: [], citations: [], targets: [], fragments: []}
            assert {:ok, ^empty} = Task.await(task, 10_000)
            assert {:ok, ^set} = Task.await(writer, 10_000)

            assert {:ok, ^empty} =
                     KnowledgeLinkRepository.list_set(
                       c.context,
                       c.set.note_resource_id,
                       c.set.note_resource_version_id
                     )

            assert {:ok, ^set} =
                     KnowledgeLinkRepository.list_set(
                       c.context,
                       set.note_resource_id,
                       set.note_resource_version_id
                     )
          after
            Task.shutdown(task, :brutal_kill)
          end
        after
          Task.shutdown(writer, :brutal_kill)
        end
      end)
    end
  end

  defp writer_blocked?(_reader, _writer, 0), do: false

  defp writer_blocked?(reader, writer, attempts) do
    case query!(RequestRepo, "SELECT $1::integer=ANY(pg_blocking_pids($2::integer))", [
           reader,
           writer
         ]) do
      %{rows: [[true]]} ->
        true

      %{rows: [[false]]} ->
        receive do
        after
          10 -> writer_blocked?(reader, writer, attempts - 1)
        end
    end
  end

  test "database typed targets are revalidated before success and all inserts roll back", c do
    grants(fn ->
      [attachment] = c.set.attachments

      forged = %{
        c.set
        | attachments: [%{attachment | target_kind: :note}],
          targets:
            Enum.map(c.set.targets, fn
              %{kind: :asset} = target -> %{target | kind: :note}
              target -> target
            end)
      }

      assert {:ok, _} = NoteSourceSet.new(forged)

      assert {:error, %Error{message: nil, details: %{}}} =
               create_note_and_transact(c, fn ->
                 result = KnowledgeLinkRepository.insert_set(c.context, forged)
                 send(self(), {:incorrect_success, result})
                 result
               end)

      refute_received {:incorrect_success, {:ok, _}}
      assert_empty(c)
    end)
  end

  test "revalidates canonical fragment locator and rolls back an earlier attachment", c do
    grants(fn ->
      [fragment] = c.set.fragments
      [citation] = c.set.citations

      {:ok, changed_fragment} =
        Singularity.Core.DocumentFragment.new(%{
          Map.from_struct(fragment)
          | text: "forged",
            digest: :crypto.hash(:sha256, "forged"),
            fragment_id:
              Singularity.Core.DocumentFragment.id(
                fragment.resource_version_id,
                Singularity.Core.SourceLocator.to_map(fragment.locator),
                0,
                :crypto.hash(:sha256, "forged")
              )
        })

      forged = %{
        c.set
        | fragments: [changed_fragment],
          citations: [%{citation | fragment_id: changed_fragment.fragment_id}]
      }

      assert {:ok, _} = NoteSourceSet.new(forged)

      assert {:error, %Error{}} =
               create_note_and_transact(c, fn ->
                 KnowledgeLinkRepository.insert_set(c.context, forged)
               end)

      assert_empty(c)
    end)
  end

  test "forged struct, owner mismatch and oversized lists fail closed", c do
    grants(fn ->
      for set <- [
            %{c.set | classification: :secret},
            %{c.set | owner_scope_id: Ecto.UUID.generate()},
            %{c.set | targets: List.duplicate(hd(c.set.targets), 101)}
          ] do
        assert {:error, %Error{}} =
                 create_note_and_transact(c, fn ->
                   KnowledgeLinkRepository.insert_set(c.context, set)
                 end)
      end

      assert_empty(c)
    end)
  end

  test "source release invalidates a replay rather than returning stale acceptance", c do
    grants(fn ->
      assert {:ok, _} =
               create_note_and_transact(c, fn ->
                 KnowledgeLinkRepository.insert_set(c.context, c.set)
               end)

      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "UPDATE content.resource_assets SET released_at=CURRENT_TIMESTAMP WHERE asset_id=$1",
          [c.source.asset_id]
        )
      end)

      assert {:error, %Error{}} =
               transact(c, fn -> KnowledgeLinkRepository.insert_set(c.context, c.set) end)
    end)
  end

  test "validates only source-set deferred constraints inside the enclosing transaction", c do
    grants(fn ->
      assert {:error, :test_rollback} =
               create_note_and_transact(c, fn ->
                 query!(
                   RequestRepo,
                   "INSERT INTO content.resources(id,vault_id,classification,kind,current_version_id,title) VALUES($1,$2,'private','note',$3,'Incomplete enclosing work')",
                   [KnowledgeFixtures.uuid(), c.source.vault_id, KnowledgeFixtures.uuid()]
                 )

                 assert {:ok, _} = KnowledgeLinkRepository.insert_set(c.context, c.set)
                 RequestRepo.rollback(:test_rollback)
               end)

      assert_empty(c)
    end)
  end

  test "historical source evidence remains readable after tombstoning", c do
    grants(fn ->
      assert {:ok, set} =
               create_note_and_transact(c, fn ->
                 KnowledgeLinkRepository.insert_set(c.context, c.set)
               end)

      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id=$1",
          [c.document.resource_id]
        )
      end)

      assert {:ok, ^set} =
               KnowledgeLinkRepository.list_set(
                 c.context,
                 set.note_resource_id,
                 set.note_resource_version_id
               )
    end)
  end

  test "oversized stored source sets are rejected rather than truncated", c do
    [citation] = c.set.citations

    grants(fn ->
      assert {:error, :oversize_read_checked} =
               create_note_and_transact(c, fn ->
                 for ordinal <- 0..100 do
                   query!(
                     RequestRepo,
                     "INSERT INTO content.note_citations(note_resource_version_id,id,note_resource_id,vault_id,classification,source_resource_id,source_resource_version_id,fragment_id,locator,ordinal,inserted_at) VALUES($1,$2,$3,$4,'private',$5,$6,$7,$8,$9,CURRENT_TIMESTAMP)",
                     [
                       c.note.resource_version_id,
                       KnowledgeFixtures.uuid(),
                       c.note.resource_id,
                       c.source.vault_id,
                       c.document.resource_id,
                       c.document.resource_version_id,
                       citation.fragment_id,
                       Singularity.Core.SourceLocator.to_map(citation.locator),
                       ordinal
                     ]
                   )
                 end

                 assert %{rows: [[101]]} =
                          query!(
                            RequestRepo,
                            "SELECT count(*) FROM content.note_citations WHERE note_resource_version_id=$1",
                            [c.note.resource_version_id]
                          )

                 assert {:error, %Error{code: :invalid}} =
                          KnowledgeLinkRepository.list_set(
                            c.context,
                            c.set.note_resource_id,
                            c.set.note_resource_version_id
                          )

                 RequestRepo.rollback(:oversize_read_checked)
               end)

      assert %{rows: [[principal, owner]]} =
               query!(
                 RequestRepo,
                 "SELECT current_setting('singularity.principal_id',true),current_setting('singularity.vault_id',true)"
               )

      assert principal in [nil, ""]
      assert owner in [nil, ""]
      assert_empty(c)
    end)
  end

  test "selected references are exact owner-free members and lock the live containing Note", c do
    grants(fn ->
      publish_selected_set(c)
      attachment = selected_reference(c, :attachment)
      citation = selected_reference(c, :citation)

      assert {:ok, {^attachment, ^citation}} =
               transact(c, fn ->
                 assert {:ok, ^attachment} =
                          select_member(c, :attachment, attachment.attachment_id)

                 assert {:ok, ^citation} = select_member(c, :citation, citation.citation_id)

                 assert %{rows: [[true]]} =
                          query!(
                            RequestRepo,
                            "SELECT EXISTS(SELECT 1 FROM pg_locks WHERE pid=pg_backend_pid() AND locktype='relation' AND relation='content.resources'::regclass AND mode='RowShareLock' AND granted)"
                          )

                 {:ok, {attachment, citation}}
               end)
    end)
  end

  test "selection needs no target metadata, document state or fragment text SELECT", c do
    grants(fn ->
      publish_selected_set(c)
      attachment = selected_reference(c, :attachment)
      citation = selected_reference(c, :citation)

      without_target_hydration_select(fn ->
        assert {:ok, ^attachment} =
                 transact(c, fn ->
                   select_member(c, :attachment, attachment.attachment_id)
                 end)

        assert {:ok, ^citation} =
                 transact(c, fn ->
                   select_member(c, :citation, citation.citation_id)
                 end)
      end)
    end)
  end

  test "selection returns only the requested member from a sealed multi-member version", c do
    grants(fn ->
      [attachment] = c.set.attachments
      [citation] = c.set.citations

      second_attachment = %{
        attachment
        | attachment_id: Ecto.UUID.generate(),
          target_resource_id: text(c.document.resource_id),
          target_resource_version_id: text(c.document.resource_version_id),
          target_kind: :document,
          ordinal: 1,
          label: "Second"
      }

      second_citation = %{citation | citation_id: Ecto.UUID.generate(), ordinal: 1}

      c = %{
        c
        | set: %{
            c.set
            | attachments: [attachment, second_attachment],
              citations: [citation, second_citation]
          }
      }

      publish_selected_set(c)
      expected_attachment = attachment_reference(second_attachment)
      expected_citation = citation_reference(second_citation)

      without_target_hydration_select(fn ->
        assert {:ok, ^expected_attachment} =
                 transact(c, fn ->
                   select_member(c, :attachment, second_attachment.attachment_id)
                 end)

        assert {:ok, ^expected_citation} =
                 transact(c, fn ->
                   select_member(c, :citation, second_citation.citation_id)
                 end)
      end)
    end)
  end

  test "all selected readers reject calls outside an existing authenticated scoped transaction",
       c do
    grants(fn ->
      publish_selected_set(c)

      for {function, arguments} <- selected_reader_calls(c) do
        assert {:error, %Error{code: :invalid}} =
                 apply(KnowledgeLinkRepository, function, [c.context | arguments])

        assert {:ok, {:error, %Error{code: :invalid}}} =
                 RequestRepo.transaction(fn ->
                   apply(KnowledgeLinkRepository, function, [c.context | arguments])
                 end)
      end
    end)
  end

  for mismatch <- [:principal_id, :owner_scope_id] do
    @selected_scope_mismatch mismatch
    test "all selected readers reject #{@selected_scope_mismatch} GUC/context mismatch", c do
      grants(fn ->
        publish_selected_set(c)
        context = Map.put(c.context, @selected_scope_mismatch, Ecto.UUID.generate())

        for {function, arguments} <- selected_reader_calls(c) do
          assert {:error, %Error{code: :invalid}} =
                   transact(c, fn ->
                     apply(KnowledgeLinkRepository, function, [context | arguments])
                   end)
        end
      end)
    end
  end

  test "all selected readers reject malformed canonical IDs and reference structs", c do
    grants(fn ->
      publish_selected_set(c)
      attachment = selected_reference(c, :attachment)
      citation = selected_reference(c, :citation)

      for kind <- [:attachment, :citation],
          field <- [:note_id, :version_id, :member_id],
          invalid <- [nil, "bad", "00000000-0000-4000-8000-00000000000A"] do
        member_id =
          if kind == :attachment, do: attachment.attachment_id, else: citation.citation_id

        identifiers =
          Map.put(
            %{
              note_id: c.set.note_resource_id,
              version_id: c.set.note_resource_version_id,
              member_id: member_id
            },
            field,
            invalid
          )

        assert {:error, %Error{code: :invalid}} =
                 transact(c, fn ->
                   apply(KnowledgeLinkRepository, select_function(kind), [
                     c.context,
                     identifiers.note_id,
                     identifiers.version_id,
                     identifiers.member_id
                   ])
                 end)
      end

      for field <- [:principal_id, :owner_scope_id],
          {function, arguments} <- selected_reader_calls(c) do
        context = Map.put(c.context, field, "00000000-0000-4000-8000-00000000000A")

        assert {:error, %Error{code: :invalid}} =
                 transact(c, fn ->
                   apply(KnowledgeLinkRepository, function, [context | arguments])
                 end)
      end

      for {function, reference} <- [
            {:resolve_attachment_in_scope, %{attachment | target_resource_version_id: "bad"}},
            {:resolve_attachment_in_scope,
             Map.put(attachment, :owner_scope_id, c.context.owner_scope_id)},
            {:resolve_citation_in_scope, %{citation | source_resource_id: "bad"}},
            {:resolve_citation_in_scope, Map.put(citation, :retained?, true)}
          ] do
        assert {:error, %Error{code: :invalid}} =
                 transact(c, fn ->
                   apply(KnowledgeLinkRepository, function, [c.context, reference])
                 end)
      end
    end)
  end

  test "missing and mismatched containing Note/version/member tuples are nondisclosing", c do
    grants(fn ->
      publish_selected_set(c)
      other = KnowledgeFixtures.note!(c.source)

      for kind <- [:attachment, :citation] do
        member_id =
          case kind do
            :attachment -> selected_reference(c, kind).attachment_id
            :citation -> selected_reference(c, kind).citation_id
          end

        for {note_id, version_id, id} <- [
              {Ecto.UUID.generate(), c.set.note_resource_version_id, member_id},
              {c.set.note_resource_id, Ecto.UUID.generate(), member_id},
              {c.set.note_resource_id, c.set.note_resource_version_id, Ecto.UUID.generate()},
              {text(other.resource_id), c.set.note_resource_version_id, member_id},
              {c.set.note_resource_id, text(other.resource_version_id), member_id}
            ] do
          assert {:error, %Error{code: :not_found, message: nil, details: %{}, retryable?: false}} =
                   transact(c, fn ->
                     apply(KnowledgeLinkRepository, select_function(kind), [
                       c.context,
                       note_id,
                       version_id,
                       id
                     ])
                   end)
        end
      end
    end)
  end

  test "foreign containing membership and historical target readers are nondisclosing", c do
    grants(fn ->
      publish_selected_set(c)
      foreign_source = KnowledgeFixtures.source!()
      {foreign_document, foreign_fragment} = KnowledgeFixtures.ready_document!(foreign_source)
      foreign_member_id = KnowledgeFixtures.uuid()

      foreign_note =
        KnowledgeFixtures.note!(foreign_source, fn note ->
          query!(
            MigrationRepo,
            "INSERT INTO content.note_attachments(note_resource_version_id,id,note_resource_id,vault_id,classification,target_resource_id,target_resource_version_id,target_kind,ordinal,role,inserted_at) VALUES($1,$2,$3,$4,'private',$5,$6,'asset',0,'source',CURRENT_TIMESTAMP)",
            [
              note.resource_version_id,
              foreign_member_id,
              note.resource_id,
              foreign_source.vault_id,
              foreign_source.resource_id,
              foreign_source.resource_version_id
            ]
          )
        end)

      assert {:error, %Error{code: :not_found}} =
               transact(c, fn ->
                 apply(KnowledgeLinkRepository, :select_attachment_in_scope, [
                   c.context,
                   text(foreign_note.resource_id),
                   text(foreign_note.resource_version_id),
                   text(foreign_member_id)
                 ])
               end)

      attachment = %{
        selected_reference(c, :attachment)
        | target_resource_id: text(foreign_source.resource_id),
          target_resource_version_id: text(foreign_source.resource_version_id)
      }

      citation = %{
        selected_reference(c, :citation)
        | source_resource_id: text(foreign_document.resource_id),
          source_resource_version_id: text(foreign_document.resource_version_id),
          fragment_id: foreign_fragment.fragment_id,
          locator: foreign_fragment.locator
      }

      for {function, reference} <- [
            {:resolve_attachment_in_scope, attachment},
            {:resolve_citation_in_scope, citation}
          ] do
        assert {:error, %Error{code: :not_found, message: nil, details: %{}, retryable?: false}} =
                 transact(c, fn ->
                   apply(KnowledgeLinkRepository, function, [c.context, reference])
                 end)
      end
    end)
  end

  test "selectors preserve historical containing versions and reject a tombstoned containing Note",
       c do
    grants(fn ->
      publish_selected_set(c)
      advance_selected_note(c, c.note)

      for kind <- [:attachment, :citation] do
        reference = selected_reference(c, kind)
        id = if kind == :attachment, do: reference.attachment_id, else: reference.citation_id
        assert {:ok, ^reference} = transact(c, fn -> select_member(c, kind, id) end)
      end

      set_selected_deleted(c.note.resource_id, true)

      for kind <- [:attachment, :citation] do
        reference = selected_reference(c, kind)
        id = if kind == :attachment, do: reference.attachment_id, else: reference.citation_id

        assert {:error, %Error{code: :not_found}} =
                 transact(c, fn -> select_member(c, kind, id) end)
      end

      set_selected_deleted(c.note.resource_id, false)
      attachment = selected_reference(c, :attachment)

      assert {:ok, ^attachment} =
               transact(c, fn -> select_member(c, :attachment, attachment.attachment_id) end)
    end)
  end

  test "a legal unsealed containing version is rejected before its publication boundary", c do
    grants(fn ->
      [attachment] = c.set.attachments

      assert {:error, :unsealed_selection_checked} =
               create_note_and_transact(c, fn ->
                 query!(
                   RequestRepo,
                   "INSERT INTO content.note_attachments(note_resource_version_id,id,note_resource_id,vault_id,classification,target_resource_id,target_resource_version_id,target_kind,ordinal,role,label,inserted_at) VALUES($1,$2,$3,$4,'private',$5,$6,'asset',0,'source',$7,CURRENT_TIMESTAMP)",
                   [
                     c.note.resource_version_id,
                     Ecto.UUID.dump!(attachment.attachment_id),
                     c.note.resource_id,
                     c.source.vault_id,
                     c.source.resource_id,
                     c.source.resource_version_id,
                     attachment.label
                   ]
                 )

                 assert %{rows: [[0]]} =
                          query!(
                            RequestRepo,
                            "SELECT count(*) FROM content.note_source_set_seals WHERE note_resource_version_id=$1",
                            [c.note.resource_version_id]
                          )

                 assert {:error, %Error{code: :not_found}} =
                          select_member(c, :attachment, attachment.attachment_id)

                 RequestRepo.rollback(:unsealed_selection_checked)
               end)

      assert_empty(c)
    end)
  end

  test "Asset resolution takes only the pinned metadata filename and never mutable resource title",
       c do
    grants(fn ->
      publish_selected_set(c)
      seed_selected_asset_metadata(c, "original-evidence.txt")

      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "UPDATE content.resources SET title='Mutable latest head title' WHERE id=$1",
          [c.source.resource_id]
        )
      end)

      reference = selected_reference(c, :attachment)

      expected = %{
        reference: reference,
        source: source_metadata(reference, :asset, "original-evidence.txt", false)
      }

      assert {:ok, ^expected} =
               transact(c, fn ->
                 apply(KnowledgeLinkRepository, :resolve_attachment_in_scope, [
                   c.context,
                   reference
                 ])
               end)
    end)
  end

  for metadata <- [:missing, :wrong_version] do
    @selected_metadata metadata
    test "#{@selected_metadata} AssetMetadata binding fails closed without a resource-title fallback",
         c do
      grants(fn ->
        publish_selected_set(c)

        if @selected_metadata == :wrong_version do
          seed_selected_asset_metadata(c, "wrong-binding.txt")

          Fixtures.with_owner(fn ->
            query!(
              MigrationRepo,
              "UPDATE content.asset_metadata SET resource_version_id=$1 WHERE asset_id=$2",
              [c.document.resource_version_id, c.source.asset_id]
            )
          end)
        end

        reference = selected_reference(c, :attachment)

        assert {:error, %Error{code: :not_found, message: nil, details: %{}, retryable?: false}} =
                 transact(c, fn ->
                   apply(KnowledgeLinkRepository, :resolve_attachment_in_scope, [
                     c.context,
                     reference
                   ])
                 end)
      end)
    end
  end

  for kind <- [:note, :document] do
    @selected_kind kind
    test "#{@selected_kind} attachment resolves its exact historical typed version, not current head",
         c do
      grants(fn ->
        target_row =
          if @selected_kind == :note, do: KnowledgeFixtures.note!(c.source), else: c.document

        c = selected_attachment_set(c, target_row, @selected_kind)
        publish_selected_set(c)

        if @selected_kind == :note,
          do: advance_selected_note(c, target_row),
          else: advance_selected_document(c, target_row)

        reference = selected_reference(c, :attachment)
        title = if @selected_kind == :note, do: "Note", else: "Document"

        expected = %{
          reference: reference,
          source: source_metadata(reference, @selected_kind, title, false)
        }

        assert {:ok, ^expected} =
                 transact(c, fn ->
                   apply(KnowledgeLinkRepository, :resolve_attachment_in_scope, [
                     c.context,
                     reference
                   ])
                 end)
      end)
    end
  end

  for kind <- [:asset, :note, :document] do
    @deleted_selected_kind kind
    test "#{@deleted_selected_kind} attachment keeps its pin across source tombstone and restore",
         c do
      grants(fn ->
        target_row =
          case @deleted_selected_kind do
            :asset -> c.source
            :note -> KnowledgeFixtures.note!(c.source)
            :document -> c.document
          end

        c = selected_attachment_set(c, target_row, @deleted_selected_kind)
        if @deleted_selected_kind == :asset, do: seed_selected_asset_metadata(c, "original.txt")
        publish_selected_set(c)
        reference = selected_reference(c, :attachment)

        title =
          case @deleted_selected_kind do
            :asset -> "original.txt"
            :note -> "Note"
            :document -> "Document"
          end

        for deleted? <- [true, false] do
          set_selected_deleted(target_row.resource_id, deleted?)
          # Stage 1 selects retained membership without looking at target liveness.
          assert {:ok, ^reference} =
                   transact(c, fn -> select_member(c, :attachment, reference.attachment_id) end)

          expected = %{
            reference: reference,
            source: source_metadata(reference, @deleted_selected_kind, title, deleted?)
          }

          assert {:ok, ^expected} =
                   transact(c, fn ->
                     apply(KnowledgeLinkRepository, :resolve_attachment_in_scope, [
                       c.context,
                       reference
                     ])
                   end)
        end
      end)
    end
  end

  test "citation resolution returns only its selected canonical fragment and exact locator", c do
    grants(fn ->
      {document, fragments} = selected_two_fragment_document(c.source)
      [first, selected] = fragments
      [citation] = c.set.citations

      citation = %{
        citation
        | source_resource_id: text(document.resource_id),
          source_resource_version_id: text(document.resource_version_id),
          fragment_id: selected.fragment_id,
          locator: selected.locator
      }

      c = %{
        c
        | set: %{
            c.set
            | citations: [citation],
              targets:
                [target(c.source, :asset), target(document, :document)]
                |> Enum.sort_by(&{&1.resource_id, &1.resource_version_id}),
              fragments: [selected]
          }
      }

      publish_selected_set(c)
      advance_selected_document(c, document)
      reference = citation_reference(citation)

      expected = %{
        reference: reference,
        source: citation_source_metadata(reference, "Document", false),
        fragment: %{
          fragment_id: selected.fragment_id,
          ordinal: selected.ordinal,
          text: selected.text,
          locator: selected.locator
        }
      }

      assert {:ok, ^expected} =
               transact(c, fn ->
                 apply(KnowledgeLinkRepository, :resolve_citation_in_scope, [c.context, reference])
               end)

      refute first.text == selected.text
      refute first.fragment_id == selected.fragment_id
    end)
  end

  test "citation resolution preserves its historical fragment through source tombstone and restore",
       c do
    grants(fn ->
      publish_selected_set(c)
      reference = selected_reference(c, :citation)
      [fragment] = c.set.fragments

      for deleted? <- [true, false] do
        set_selected_deleted(c.document.resource_id, deleted?)

        assert {:ok, ^reference} =
                 transact(c, fn -> select_member(c, :citation, reference.citation_id) end)

        expected = %{
          reference: reference,
          source: citation_source_metadata(reference, "Document", deleted?),
          fragment: %{
            fragment_id: fragment.fragment_id,
            ordinal: fragment.ordinal,
            text: fragment.text,
            locator: fragment.locator
          }
        }

        assert {:ok, ^expected} =
                 transact(c, fn ->
                   apply(KnowledgeLinkRepository, :resolve_citation_in_scope, [
                     c.context,
                     reference
                   ])
                 end)
      end
    end)
  end

  test "historical readers reject wrong typed pins and nonmatching citation fragment witnesses",
       c do
    grants(fn ->
      publish_selected_set(c)
      seed_selected_asset_metadata(c, "original.txt")
      attachment = selected_reference(c, :attachment)
      citation = selected_reference(c, :citation)

      {:ok, other_locator} =
        SourceLocator.new(%{version: 1, kind: "text", start_line: 2, end_line: 2})

      for {function, reference} <- [
            {:resolve_attachment_in_scope, %{attachment | target_kind: :note}},
            {:resolve_attachment_in_scope,
             %{attachment | target_resource_version_id: text(c.document.resource_version_id)}},
            {:resolve_citation_in_scope, %{citation | fragment_id: String.duplicate("a", 64)}},
            {:resolve_citation_in_scope, %{citation | locator: other_locator}}
          ] do
        assert {:error, %Error{} = error} =
                 transact(c, fn ->
                   apply(KnowledgeLinkRepository, function, [c.context, reference])
                 end)

        assert error.message == nil
        assert error.details == %{}
        refute error.retryable?
      end
    end)
  end

  defp publish_selected_set(c) do
    assert {:ok, set} =
             create_note_and_transact(c, fn ->
               KnowledgeLinkRepository.insert_set(c.context, c.set)
             end)

    assert set == c.set
  end

  defp selected_reference(c, :attachment) do
    [reference] = c.set.attachments
    attachment_reference(reference)
  end

  defp selected_reference(c, :citation) do
    [reference] = c.set.citations
    citation_reference(reference)
  end

  defp attachment_reference(reference) do
    {:ok, value} =
      NoteAttachmentReference.new(
        Map.take(
          reference,
          [
            :attachment_id,
            :target_resource_id,
            :target_resource_version_id,
            :target_kind,
            :role,
            :label
          ]
        )
      )

    value
  end

  defp citation_reference(reference) do
    {:ok, value} =
      NoteCitationReference.new(
        Map.take(
          reference,
          [:citation_id, :source_resource_id, :source_resource_version_id, :fragment_id, :locator]
        )
      )

    value
  end

  defp select_member(c, kind, id),
    do:
      apply(KnowledgeLinkRepository, select_function(kind), [
        c.context,
        c.set.note_resource_id,
        c.set.note_resource_version_id,
        id
      ])

  defp select_function(:attachment), do: :select_attachment_in_scope
  defp select_function(:citation), do: :select_citation_in_scope

  defp selected_reader_calls(c) do
    attachment = selected_reference(c, :attachment)
    citation = selected_reference(c, :citation)

    [
      {:select_attachment_in_scope,
       [c.set.note_resource_id, c.set.note_resource_version_id, attachment.attachment_id]},
      {:select_citation_in_scope,
       [c.set.note_resource_id, c.set.note_resource_version_id, citation.citation_id]},
      {:resolve_attachment_in_scope, [attachment]},
      {:resolve_citation_in_scope, [citation]}
    ]
  end

  defp source_metadata(reference, kind, title, deleted?),
    do: %{
      kind: kind,
      resource_id: reference.target_resource_id,
      resource_version_id: reference.target_resource_version_id,
      title: title,
      deleted?: deleted?
    }

  defp citation_source_metadata(reference, title, deleted?),
    do: %{
      kind: :document,
      resource_id: reference.source_resource_id,
      resource_version_id: reference.source_resource_version_id,
      title: title,
      deleted?: deleted?
    }

  defp selected_attachment_set(c, target_row, kind) do
    [attachment] = c.set.attachments

    reference = %{
      attachment
      | target_resource_id: text(target_row.resource_id),
        target_resource_version_id: text(target_row.resource_version_id),
        target_kind: kind
    }

    %{
      c
      | set: %{
          c.set
          | attachments: [reference],
            citations: [],
            fragments: [],
            targets: [target(target_row, kind)]
        }
    }
  end

  defp seed_selected_asset_metadata(c, filename) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.asset_metadata(id,asset_id,resource_version_id,vault_id,classification,projection_version,original_filename,declared_media_type,detected_media_type,plaintext_byte_size,extraction_state,completed_at) VALUES($1,$2,$3,$4,'private',1,$5,'text/plain','text/plain',12,'completed',CURRENT_TIMESTAMP)",
        [
          KnowledgeFixtures.uuid(),
          c.source.asset_id,
          c.source.resource_version_id,
          c.source.vault_id,
          filename
        ]
      )
    end)
  end

  defp set_selected_deleted(resource, true),
    do:
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "UPDATE content.resources SET deleted_at=clock_timestamp() WHERE id=$1",
          [resource]
        )
      end)

  defp set_selected_deleted(resource, false),
    do:
      Fixtures.with_owner(fn ->
        query!(MigrationRepo, "UPDATE content.resources SET deleted_at=NULL WHERE id=$1", [
          resource
        ])
      end)

  defp advance_selected_note(c, note) do
    version = KnowledgeFixtures.uuid()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',1)",
        [version, note.resource_id, c.source.vault_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.note_versions(resource_version_id,resource_id,vault_id,classification,title,markdown,created_by_principal_id,parent_version_id,inserted_at) VALUES($1,$2,$3,'private','Later Note','Later body',$4,$5,CURRENT_TIMESTAMP)",
        [
          version,
          note.resource_id,
          c.source.vault_id,
          c.source.principal_id,
          note.resource_version_id
        ]
      )

      query!(
        MigrationRepo,
        "UPDATE content.resources SET current_version_id=$1,title='Later Note' WHERE id=$2",
        [version, note.resource_id]
      )
    end)
  end

  defp advance_selected_document(c, document) do
    version = KnowledgeFixtures.uuid()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',1)",
        [version, document.resource_id, c.source.vault_id]
      )

      KnowledgeFixtures.insert_typed!(%{
        document
        | resource_version_id: version,
          title: "Later Document"
      })

      query!(
        MigrationRepo,
        "UPDATE content.resources SET current_version_id=$1,title='Later Document' WHERE id=$2",
        [version, document.resource_id]
      )
    end)
  end

  defp selected_two_fragment_document(source) do
    document = KnowledgeFixtures.document!(source)

    fragments =
      for {fragment_text, ordinal} <- [{"First unrelated fragment", 0}, {"Selected evidence", 1}] do
        {:ok, fragment} =
          DocumentFragment.new(%{
            resource_id: text(document.resource_id),
            resource_version_id: text(document.resource_version_id),
            owner_scope_id: text(source.vault_id),
            classification: :private,
            ordinal: ordinal,
            text: fragment_text,
            locator: %{version: 1, kind: "text", start_line: ordinal + 1, end_line: ordinal + 1}
          })

        fragment
      end

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "SELECT set_config('singularity.principal_id',$1,true),set_config('singularity.vault_id',$2,true)",
        [text(source.principal_id), text(source.vault_id)]
      )

      query!(MigrationRepo, "SELECT content.claim_document_extraction($1,0,$1,'plain',1)", [
        document.resource_version_id
      ])

      query!(MigrationRepo, "SELECT content.complete_document_extraction($1,$1,1,$2,$3,'en')", [
        document.resource_version_id,
        Enum.map(fragments, fn fragment ->
          %{
            "id" => fragment.fragment_id,
            "ordinal" => fragment.ordinal,
            "text" => fragment.text,
            "digest" => Base.encode16(fragment.digest, case: :lower),
            "locator" => SourceLocator.to_map(fragment.locator)
          }
        end),
        :crypto.hash(:sha256, Enum.map_join(fragments, "", & &1.text))
      ])
    end)

    {document, fragments}
  end

  defp without_target_hydration_select(fun) do
    tables = ~w(asset_metadata document_versions document_fragments)

    previous =
      Fixtures.with_owner(fn ->
        %{rows: [[database]]} = query!(MigrationRepo, "SELECT current_database()")
        assert String.starts_with?(database, "singularity_test_")

        for table <- tables do
          %{rows: rows} =
            query!(
              MigrationRepo,
              "SELECT a.grantor::regrole::text,a.is_grantable FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace CROSS JOIN LATERAL aclexplode(c.relacl) a JOIN pg_roles r ON r.oid=a.grantee WHERE n.nspname='content' AND c.relname=$1 AND r.rolname='singularity_web' AND a.privilege_type='SELECT'",
              [table]
            )

          assert rows in [
                   [],
                   [["singularity_table_owner", true]],
                   [["singularity_table_owner", false]]
                 ]

          {table, rows}
        end
      end)

    try do
      Fixtures.with_owner(fn ->
        for table <- tables do
          query!(MigrationRepo, "REVOKE SELECT ON content.#{table} FROM singularity_web")

          assert %{rows: [[false]]} =
                   query!(
                     MigrationRepo,
                     "SELECT has_table_privilege('singularity_web',$1,'SELECT')",
                     ["content.#{table}"]
                   )
        end
      end)

      fun.()
    after
      Fixtures.with_owner(fn ->
        for {table, rows} <- previous do
          case rows do
            [["singularity_table_owner", true]] ->
              query!(
                MigrationRepo,
                "GRANT SELECT ON content.#{table} TO singularity_web WITH GRANT OPTION"
              )

            [["singularity_table_owner", false]] ->
              query!(MigrationRepo, "GRANT SELECT ON content.#{table} TO singularity_web")

            [] ->
              :ok
          end

          assert %{rows: ^rows} =
                   query!(
                     MigrationRepo,
                     "SELECT a.grantor::regrole::text,a.is_grantable FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace CROSS JOIN LATERAL aclexplode(c.relacl) a JOIN pg_roles r ON r.oid=a.grantee WHERE n.nspname='content' AND c.relname=$1 AND r.rolname='singularity_web' AND a.privilege_type='SELECT'",
                     [table]
                   )
        end
      end)
    end
  end

  defp target(row, kind) do
    value = %{
      resource_id: text(row.resource_id),
      resource_version_id: text(row.resource_version_id),
      owner_scope_id: text(row.vault_id),
      classification: :private,
      kind: kind
    }

    if kind == :document, do: Map.put(value, :state, :ready), else: value
  end

  defp text(id), do: Ecto.UUID.load!(id)

  defp transact(c, fun),
    do:
      ScopedRepo.transact(
        RequestRepo,
        %{principal_id: c.context.principal_id, vault_id: c.context.owner_scope_id},
        fn _ -> fun.() end
      )

  defp create_note_and_transact(c, fun) do
    transact(c, fn ->
      KnowledgeFixtures.insert_note!(RequestRepo, c.source, c.note)
      fun.()
    end)
  end

  defp set_for_version(set, note) do
    version = text(note.resource_version_id)

    %{
      set
      | note_resource_version_id: version,
        attachments: Enum.map(set.attachments, &%{&1 | note_resource_version_id: version}),
        citations: Enum.map(set.citations, &%{&1 | note_resource_version_id: version})
    }
  end

  defp insert_next_version!(c, note) do
    query!(
      RequestRepo,
      "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',1)",
      [note.resource_version_id, note.resource_id, note.vault_id]
    )

    query!(
      RequestRepo,
      "INSERT INTO content.note_versions(resource_version_id,resource_id,vault_id,classification,title,markdown,created_by_principal_id,parent_version_id,inserted_at) VALUES($1,$2,$3,'private','Note','body',$4,$5,CURRENT_TIMESTAMP)",
      [
        note.resource_version_id,
        note.resource_id,
        note.vault_id,
        c.source.principal_id,
        c.note.resource_version_id
      ]
    )
  end

  defp grants(fun),
    do:
      KnowledgeTestGrants.with_grants(
        ~w(note_attachments note_citations document_versions document_fragments),
        fun
      )

  defp assert_empty(c) do
    Fixtures.with_owner(fn ->
      for table <- ~w(note_attachments note_citations) do
        assert %{rows: [[0]]} =
                 query!(
                   MigrationRepo,
                   "SELECT count(*) FROM content.#{table} WHERE note_resource_version_id=$1",
                   [c.note.resource_version_id]
                 )
      end
    end)
  end
end
