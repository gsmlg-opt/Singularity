defmodule Singularity.Storage.Postgres.KnowledgeLinkRepositoryTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  alias Singularity.Core.{Error, NoteAttachment, NoteCitation, NoteSourceSet}

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
