defmodule Singularity.Storage.Postgres.NoteSourcesTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration
  @barrier_timeout 5_000

  alias Singularity.Core.{
    DocumentCompletion,
    DocumentFragment,
    DocumentVersion,
    Error,
    NoteAttachmentReference,
    NoteCitationReference,
    NoteSaveResult,
    NoteSnapshot,
    SourceLocator
  }

  alias Singularity.Storage.{
    Fixtures,
    KnowledgeFixtures,
    KnowledgeTestGrants,
    MigrationRepo,
    ScopedRepo
  }

  alias Singularity.Storage.Postgres.{AssetDeletionRepository, DocumentRepository, NoteRepository}

  defmodule PausedLifecycleRepo do
    alias Singularity.Storage.RequestRepo
    defdelegate in_transaction?(), to: RequestRepo
    defdelegate rollback(reason), to: RequestRepo
    defdelegate one(query, options), to: RequestRepo
    defdelegate all(query, options), to: RequestRepo

    # Delegate the real scoped transaction unchanged and pause its callback
    # after the real lifecycle operation, but before the actual database commit.
    def transaction(fun, options) do
      RequestRepo.transaction(
        fn ->
          result = fun.()
          {parent, gate} = Process.get(:note_sources_lifecycle_gate)
          send(parent, {gate, :checkpoint, :held, self()})

          receive do
            {^gate, :continue} -> :ok
          after
            5_000 -> raise "document source commit barrier timed out"
          end

          result
        end,
        options
      )
    end
  end

  setup do
    source = KnowledgeFixtures.source!()
    {document, fragment} = KnowledgeFixtures.ready_document!(source)

    Fixtures.with_owner(fn ->
      for name <- ["note.write", "asset.read"] do
        query!(
          MigrationRepo,
          "INSERT INTO core.capabilities(id,name) VALUES($1,$2) ON CONFLICT(name) DO NOTHING",
          [uuid(Ecto.UUID.generate()), name]
        )

        query!(
          MigrationRepo,
          "INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name=$3 ON CONFLICT DO NOTHING",
          [source.principal_id, source.vault_id, name]
        )
      end
    end)

    %{source: source, fixture: ids(source), document: ids(document), fragment: fragment}
  end

  test "create persists owner-derived ordered references, seal, receipt and canonical effects",
       c do
    grants(fn ->
      refs = references(c)
      request = intent(c, :create, %{}, refs)
      assert {:ok, %NoteSaveResult{outcome: :saved} = result} = mutate(c, :create, request)
      assert_members(c, result.submitted_version_id, refs)
      assert_effects(c, request, result, "saved", 1)

      assert %{rows: [[0, nil, nil]]} =
               scoped(c, fn repo ->
                 query!(
                   repo,
                   "SELECT v.revision,n.parent_version_id,n.merge_parent_version_id FROM content.resource_versions v JOIN content.note_versions n ON n.resource_version_id=v.id WHERE v.id=$1",
                   [uuid(result.submitted_version_id)]
                 )
               end)
    end)
  end

  test "metadata-only save creates a new exact source set and leaves the old rows unchanged", c do
    grants(fn ->
      refs = references(c)
      base = seed_note(c, refs)
      old = stored_members(c, base.version_id)
      request = intent(c, :save, base)
      assert {:ok, %NoteSaveResult{outcome: :saved} = saved} = mutate(c, :save, request)
      refute saved.submitted_version_id == base.version_id
      assert_members(c, saved.submitted_version_id, refs)
      assert stored_members(c, base.version_id) == old
      assert_effects(c, request, saved, "saved", 1)
    end)
  end

  test "stale save inherits exact base rather than the independently advanced head", c do
    grants(fn ->
      refs = references(c)
      base = seed_note(c, refs)
      current = seed_version(c, base, 1, %{attachments: [], citations: []})
      request = intent(c, :save, base)
      assert {:ok, %NoteSaveResult{outcome: :conflict} = competing} = mutate(c, :save, request)
      assert competing.canonical_version_id == current.version_id
      assert_members(c, competing.submitted_version_id, refs)
      assert_members(c, current.version_id, %{attachments: [], citations: []})

      assert %{rows: [[base_id, current_id, submitted_id, "open"]]} =
               scoped(c, fn repo ->
                 query!(
                   repo,
                   "SELECT base_version_id::text,canonical_version_id::text,competing_version_id::text,state FROM content.note_conflicts WHERE id=$1",
                   [uuid(competing.conflict_id)]
                 )
               end)

      assert {base_id, current_id, submitted_id} ==
               {base.version_id, current.version_id, competing.submitted_version_id}

      assert_effects(c, request, competing, "conflict", 1)
    end)
  end

  for cleared <- [:attachments, :citations] do
    @cleared cleared
    test "explicit empty #{@cleared} clears only that collection", c do
      grants(fn ->
        refs = references(c)
        base = seed_note(c, refs)
        request = intent(c, :save, base, %{@cleared => []})
        assert {:ok, %NoteSaveResult{outcome: :saved} = saved} = mutate(c, :save, request)
        assert_members(c, saved.submitted_version_id, Map.put(refs, @cleared, []))
        assert_members(c, base.version_id, refs)
      end)
    end
  end

  test "replacement resolves current live evidence and preserves supplied order and stable ids",
       c do
    grants(fn ->
      refs = references(c)
      base = seed_note(c, refs)
      target = seed_note(c, %{attachments: [], citations: []})
      note_ref = attachment(target, :note, "second")
      [asset_ref] = refs.attachments
      replacement = %{attachments: [note_ref, asset_ref], citations: refs.citations}

      assert {:ok, %NoteSaveResult{} = saved} =
               mutate(c, :save, intent(c, :save, base, replacement))

      assert_members(c, saved.submitted_version_id, replacement)
      assert_members(c, base.version_id, refs)
    end)
  end

  test "merge omission inherits expected current and preserves both conflict parents", c do
    grants(fn ->
      scenario = seed_conflict(c)
      request = intent(c, :merge, scenario)
      assert {:ok, %NoteSaveResult{outcome: :saved} = merged} = mutate(c, :merge, request)
      assert_members(c, merged.submitted_version_id, scenario.current_refs)
      assert_merge(c, scenario, merged)
      assert_effects(c, request, merged, "saved", 2)
    end)
  end

  test "explicit merge retains members from either parent after both targets are deleted", c do
    grants(fn ->
      scenario = seed_conflict(c)
      tombstone(c, c.document.resource_id)
      tombstone(c, scenario.note_target.resource_id)

      refs = %{
        attachments: scenario.competing_refs.attachments ++ scenario.current_refs.attachments,
        citations: []
      }

      assert {:ok, %NoteSaveResult{} = merged} =
               mutate(c, :merge, intent(c, :merge, scenario, refs))

      assert_members(c, merged.submitted_version_id, refs)
      assert_merge(c, scenario, merged)
    end)
  end

  test "retained attachment and citation survive tombstones with exact immutable pins", c do
    grants(fn ->
      refs = references(c)
      base = seed_note(c, refs)
      tombstone(c, c.fixture.resource_id)
      tombstone(c, c.document.resource_id)
      assert {:ok, %NoteSaveResult{} = saved} = mutate(c, :save, intent(c, :save, base))
      assert_members(c, saved.submitted_version_id, refs)
    end)
  end

  test "retained sources can reorder without changing historical semantic identity", c do
    grants(fn ->
      target = seed_note(c, %{attachments: [], citations: []})
      refs = references(c)
      refs = %{refs | attachments: refs.attachments ++ [attachment(target, :note, "note")]}
      base = seed_note(c, refs)
      tombstone(c, c.fixture.resource_id)
      tombstone(c, target.resource_id)
      reordered = %{refs | attachments: Enum.reverse(refs.attachments)}

      assert {:ok, %NoteSaveResult{} = saved} =
               mutate(c, :save, intent(c, :save, base, reordered))

      assert_members(c, saved.submitted_version_id, reordered)
      assert_members(c, base.version_id, refs)
    end)
  end

  for change <- [:new_id, :changed_label, :changed_pin, :changed_kind, :mixed_new] do
    @change change
    test "#{change} is not historical retention and rejects dead source atomically", c do
      grants(fn ->
        refs = references(c)
        base = seed_note(c, refs)
        tombstone(c, c.fixture.resource_id)
        [original] = refs.attachments

        changed =
          case @change do
            :new_id ->
              %{original | attachment_id: Ecto.UUID.generate()}

            :changed_label ->
              %{original | label: "changed"}

            :changed_pin ->
              %{original | target_resource_version_id: Ecto.UUID.generate()}

            :changed_kind ->
              %{original | target_kind: :note}

            :mixed_new ->
              attachment(
                %{
                  resource_id: c.document.resource_id,
                  version_id: c.document.resource_version_id
                },
                :document,
                "new dead reference"
              )
          end

        if @change == :mixed_new, do: tombstone(c, c.document.resource_id)
        attachments = if @change == :mixed_new, do: [original, changed], else: [changed]
        request = intent(c, :save, base, %{attachments: attachments})
        before = state(c)
        assert {:error, %Error{}} = mutate(c, :save, request)
        assert state(c) == before
        assert_no_effects(c, request)
      end)
    end
  end

  for invalid <- [
        :wrong_locator,
        :wrong_fragment,
        :foreign_owner,
        :wrong_resource_pin,
        :self_link
      ] do
    @invalid invalid
    test "#{invalid} source witness fails without partial source, receipt or canonical rows", c do
      grants(fn ->
        refs = references(c)
        base = seed_note(c, %{attachments: [], citations: []})

        replacement =
          case @invalid do
            :wrong_locator ->
              [ref] = refs.citations

              {:ok, locator} =
                SourceLocator.new(%{
                  "version" => 1,
                  "kind" => "text",
                  "start_line" => 2,
                  "end_line" => 2
                })

              %{refs | citations: [%{ref | locator: locator}]}

            :wrong_fragment ->
              [ref] = refs.citations
              %{refs | citations: [%{ref | fragment_id: String.duplicate("a", 64)}]}

            :foreign_owner ->
              %{one: other} = Fixtures.two_vaults!()
              other_note = KnowledgeFixtures.note!(other) |> ids()

              %{
                attachments: [
                  attachment(
                    %{
                      resource_id: other_note.resource_id,
                      version_id: other_note.resource_version_id
                    },
                    :note,
                    "foreign"
                  )
                ],
                citations: []
              }

            :wrong_resource_pin ->
              [ref] = refs.attachments
              %{refs | attachments: [%{ref | target_resource_id: c.document.resource_id}]}

            :self_link ->
              %{attachments: [attachment(base, :note, "self")], citations: []}
          end

        request = intent(c, :save, base, replacement)
        before = state(c)
        assert {:error, %Error{}} = mutate(c, :save, request)
        assert state(c) == before
        assert_no_effects(c, request)
      end)
    end
  end

  test "forged noncanonical source struct is rejected before receipt and effect creation", c do
    grants(fn ->
      base = seed_note(c, %{attachments: [], citations: []})
      request = intent(c, :save, base)
      [ref] = references(c).attachments
      forged = Map.put(ref, :retained?, true)
      request = %{request | snapshot: %{request.snapshot | attachments: [forged]}}
      before = state(c)
      assert {:error, %Error{code: :invalid}} = mutate(c, :save, request)
      assert state(c) == before
      assert_no_effects(c, request)
    end)
  end

  test "resolved inherited and replaced union over 100 targets fails atomically", c do
    grants(fn ->
      targets =
        Fixtures.with_owner(fn ->
          for _ <- 1..100 do
            target = %{resource_id: Ecto.UUID.generate(), version_id: Ecto.UUID.generate()}

            query!(
              MigrationRepo,
              "INSERT INTO content.resources(id,vault_id,classification,kind,current_version_id,title) VALUES($1,$2,'private','note',$3,'Bound target')",
              [uuid(target.resource_id), c.source.vault_id, uuid(target.version_id)]
            )

            insert_version(c, target, 0, nil, %{attachments: [], citations: []})
            target
          end
        end)

      refs = %{attachments: Enum.map(targets, &attachment(&1, :note, "bound")), citations: []}
      base = seed_note(c, refs)
      # Canonical request contains one citation and an omitted attachment mode;
      # only resolving the exact stored parent reveals the forbidden union.
      request = intent(c, :save, base, %{citations: [citation(c)]})
      before = state(c)
      assert {:error, %Error{code: :invalid}} = mutate(c, :save, request)
      assert state(c) == before
      assert_no_effects(c, request)
    end)
  end

  test "completed save replay bypasses source preparation after deletion and changed intent conflicts",
       c do
    grants(fn ->
      refs = references(c)
      base = seed_note(c, refs)
      request = intent(c, :save, base)
      assert {:ok, %NoteSaveResult{} = saved} = mutate(c, :save, request)
      assert_members(c, saved.submitted_version_id, refs)
      tombstone(c, c.fixture.resource_id)
      tombstone(c, c.document.resource_id)

      replay =
        Map.put(request, :failure_injector, %{
          after_source_prepare: fn -> flunk("receipt replay entered source preparation") end,
          after_resource_lock: fn -> flunk("receipt replay entered source locking") end
        })

      before = state(c)
      assert {:ok, ^saved} = mutate(c, :save, replay)
      assert state(c) == before
      changed = intent(c, :save, base, %{attachments: []})
      changed = %{changed | mutation_id: request.mutation_id}
      assert {:error, %Error{code: :conflict}} = mutate(c, :save, changed)
      assert state(c) == before
    end)
  end

  test "source rows and seal roll back at every existing canonical mutation checkpoint", c do
    grants(fn ->
      base = seed_note(c, references(c))

      for point <- [
            :after_snapshot,
            :after_head,
            :after_projection,
            :after_audit,
            :after_outbox,
            :after_receipt
          ] do
        request =
          intent(c, :save, base)
          |> Map.put(:failure_injector, %{
            point => fn -> raise "note source rollback checkpoint" end
          })

        before = state(c)

        assert_raise RuntimeError, "note source rollback checkpoint", fn ->
          mutate(c, :save, request)
        end

        assert state(c) == before
        assert_no_effects(c, request)
      end
    end)
  end

  test "mutual Note attachments prepare before ordered resource locks and converge", c do
    grants(fn ->
      left = seed_note(c, %{attachments: [], citations: []})
      right = seed_note(c, %{attachments: [], citations: []})
      gate = make_ref()
      left_refs = %{attachments: [attachment(right, :note, "right")], citations: []}
      right_refs = %{attachments: [attachment(left, :note, "left")], citations: []}
      parent = self()

      build = fn label, note, refs ->
        intent(c, :save, note, refs)
        |> Map.put(:failure_injector, %{
          after_source_prepare: fn -> hold(parent, gate, {:prepared, label}) end,
          after_resource_lock: fn -> hold(parent, gate, {:locked, label}) end
        })
      end

      with_connection(
        :left,
        gate,
        fn -> mutate(c, :save, build.(:left, left, left_refs)) end,
        fn a ->
          with_connection(
            :right,
            gate,
            fn -> mutate(c, :save, build.(:right, right, right_refs)) end,
            fn b ->
              {ap, ab} = ready(gate, :left)
              {bp, bb} = ready(gate, :right)
              refute ab == bb
              send(ap, {gate, :start})
              send(bp, {gate, :start})
              await_gate(gate, {:prepared, :left})
              await_gate(gate, {:prepared, :right})
              send(ap, {gate, :continue})
              send(bp, {gate, :continue})
              {winner, wp} = await_either_lock(gate)
              {waiter_backend, winner_backend} = if winner == :left, do: {bb, ab}, else: {ab, bb}
              blocked_by!(waiter_backend, winner_backend, gate)
              send(wp, {gate, :continue})
              loser = if winner == :left, do: :right, else: :left
              lp = await_lock(gate, loser)
              send(lp, {gate, :continue})

              assert {:ok, %NoteSaveResult{outcome: :saved} = ls} =
                       Task.await(a, @barrier_timeout)

              assert {:ok, %NoteSaveResult{outcome: :saved} = rs} =
                       Task.await(b, @barrier_timeout)

              assert_members(c, ls.submitted_version_id, left_refs)
              assert_members(c, rs.submitted_version_id, right_refs)
            end
          )
        end
      )
    end)
  end

  for first <- [:save, :delete] do
    @first first
    test "Save versus real Asset deletion serializes with #{@first} first", c do
      grants(fn ->
        base = seed_note(c, %{attachments: [], citations: []})
        refs = %{attachments: references(c).attachments, citations: []}
        gate = make_ref()
        parent = self()
        request = intent(c, :save, base, refs)

        save = fn ->
          request =
            if @first == :save,
              do:
                Map.put(request, :failure_injector, %{
                  after_resource_lock: fn -> hold(parent, gate, :held) end
                }),
              else: request

          mutate(c, :save, request)
        end

        delete = fn ->
          scoped(c, fn repo ->
            result = delete_asset(repo, c)
            if @first == :delete, do: hold(parent, gate, :held)
            result
          end)
        end

        {first_fun, second_fun} = if @first == :save, do: {save, delete}, else: {delete, save}

        with_connection(:first, gate, first_fun, fn a ->
          {ap, ab} = ready(gate, :first)
          send(ap, {gate, :start})
          await_gate(gate, :held)

          with_connection(:second, gate, second_fun, fn b ->
            {bp, bb} = ready(gate, :second)
            send(bp, {gate, :start})
            blocked_by!(bb, ab, gate)
            send(ap, {gate, :continue})
            first_result = Task.await(a, @barrier_timeout)
            second_result = Task.await(b, @barrier_timeout)

            if @first == :save do
              assert {:ok, %NoteSaveResult{outcome: :saved} = saved} = first_result
              assert {:ok, %{state: :pending_delete}} = second_result
              assert_members(c, saved.submitted_version_id, refs)
            else
              assert {:ok, %{state: :pending_delete}} = first_result
              assert {:error, %Error{code: :not_found}} = second_result
              assert_members(c, base.version_id, %{attachments: [], citations: []})
              assert_no_effects(c, request)
            end

            assert %{rows: [["pending_delete", true]]} =
                     scoped(c, fn repo ->
                       query!(
                         repo,
                         "SELECT a.state,ra.released_at IS NOT NULL FROM content.assets a JOIN content.resource_assets ra ON ra.asset_id=a.id WHERE a.id=$1",
                         [c.source.asset_id]
                       )
                     end)
          end)
        end)
      end)
    end
  end

  test "real Document completion commits before blocked Save and readiness is revalidated", c do
    grants(fn ->
      pending = KnowledgeFixtures.document!(c.source) |> ids()
      context = document_context(c)

      assert {:ok, %DocumentVersion{state: :extracting}} =
               DocumentRepository.claim(
                 context,
                 pending.resource_version_id,
                 0,
                 pending.resource_version_id,
                 "plain",
                 1
               )

      completion = completion(c, pending)
      base = seed_note(c, %{attachments: [], citations: []})

      refs = %{
        attachments: [
          attachment(
            %{resource_id: pending.resource_id, version_id: pending.resource_version_id},
            :document,
            "completing"
          )
        ],
        citations: []
      }

      gate = make_ref()
      parent = self()

      with_lifecycle_bridge(fn ->
        with_connection(
          :lifecycle,
          gate,
          fn ->
            Process.put(:note_sources_lifecycle_gate, {parent, gate})

            try do
              DocumentRepository.complete(
                %{context | repo: PausedLifecycleRepo},
                pending.resource_version_id,
                completion
              )
            after
              Process.delete(:note_sources_lifecycle_gate)
            end
          end,
          fn a ->
            {ap, ab} = ready(gate, :lifecycle)
            send(ap, {gate, :start})
            await_gate(gate, :held)

            with_connection(
              :save,
              gate,
              fn -> mutate(c, :save, intent(c, :save, base, refs)) end,
              fn b ->
                {bp, bb} = ready(gate, :save)
                send(bp, {gate, :start})
                blocked_by!(bb, ab, gate)
                send(ap, {gate, :continue})
                assert {:ok, %DocumentVersion{state: :ready}} = Task.await(a, @barrier_timeout)

                assert {:ok, %NoteSaveResult{outcome: :saved} = saved} =
                         Task.await(b, @barrier_timeout)

                assert_members(c, saved.submitted_version_id, refs)
              end
            )
          end
        )
      end)
    end)
  end

  test "Save holds Document resource before exact real completion replay without lock inversion",
       c do
    grants(fn ->
      base = seed_note(c, %{attachments: [], citations: []})

      refs = %{
        attachments: [
          attachment(
            %{resource_id: c.document.resource_id, version_id: c.document.resource_version_id},
            :document,
            "ready"
          )
        ],
        citations: []
      }

      gate = make_ref()
      parent = self()

      request =
        intent(c, :save, base, refs)
        |> Map.put(:failure_injector, %{after_resource_lock: fn -> hold(parent, gate, :held) end})

      with_connection(:save, gate, fn -> mutate(c, :save, request) end, fn a ->
        {ap, ab} = ready(gate, :save)
        send(ap, {gate, :start})
        await_gate(gate, :held)

        with_connection(
          :lifecycle,
          gate,
          fn ->
            DocumentRepository.complete(
              document_context(c),
              c.document.resource_version_id,
              completion(c, c.document, c.fragment)
            )
          end,
          fn b ->
            {bp, bb} = ready(gate, :lifecycle)
            send(bp, {gate, :start})
            blocked_by!(bb, ab, gate)
            send(ap, {gate, :continue})

            assert {:ok, %NoteSaveResult{outcome: :saved} = saved} =
                     Task.await(a, @barrier_timeout)

            assert {:ok, %DocumentVersion{state: :ready, fragments: [fragment]}} =
                     Task.await(b, @barrier_timeout)

            assert fragment == c.fragment
            assert_members(c, saved.submitted_version_id, refs)
          end
        )
      end)
    end)
  end

  test "server context authorizes exact owner-free new Create members before source locks", c do
    grants(fn ->
      target = seed_note(c, %{attachments: [], citations: []})
      refs = references(c)
      [asset_ref] = refs.attachments

      refs = %{
        refs
        | attachments: [
            attachment(target, :note, "note"),
            asset_ref,
            attachment(
              %{resource_id: c.document.resource_id, version_id: c.document.resource_version_id},
              :document,
              "document"
            )
          ]
      }

      request = intent(c, :create, %{}, refs)
      gate = make_ref()
      request = authorization_checkpoint(request, gate)

      assert {:ok, %NoteSaveResult{outcome: :saved} = saved} =
               authorized_mutate(c, :create, request, fn _repo, members ->
                 assert members == refs
                 assert_reference_shapes(members)
                 send(self(), {gate, :authorized})
                 :ok
               end)

      assert_members(c, saved.submitted_version_id, refs)
      assert_effects(c, request, saved, "saved", 1)
      refute_received {^gate, :authorized}
    end)
  end

  test "server context Save authorizes only new members even on a retained citation target", c do
    grants(fn ->
      retained = references(c)
      base = seed_note(c, retained)
      target = seed_note(c, %{attachments: [], citations: []})
      note_ref = attachment(target, :note, "new note")

      document_ref =
        attachment(
          %{resource_id: c.document.resource_id, version_id: c.document.resource_version_id},
          :document,
          "new document attachment"
        )

      new_citation = citation(c)

      refs = %{
        attachments: [note_ref] ++ retained.attachments ++ [document_ref],
        citations: retained.citations ++ [new_citation]
      }

      expected_new = %{attachments: [note_ref, document_ref], citations: [new_citation]}
      request = intent(c, :save, base, refs)
      gate = make_ref()
      request = authorization_checkpoint(request, gate)

      assert {:ok, %NoteSaveResult{outcome: :saved} = saved} =
               authorized_mutate(c, :save, request, fn _repo, members ->
                 assert members == expected_new
                 assert_reference_shapes(members)
                 send(self(), {gate, :authorized})
                 :ok
               end)

      assert_members(c, saved.submitted_version_id, refs)
      assert_members(c, base.version_id, retained)
      assert_effects(c, request, saved, "saved", 1)
      refute_received {^gate, :authorized}
    end)
  end

  test "server context stale Save authorizes new members before publishing its competing version",
       c do
    grants(fn ->
      base = seed_note(c, %{attachments: [], citations: []})
      current = seed_version(c, base, 1, %{attachments: [], citations: []})
      refs = references(c)
      request = intent(c, :save, base, refs)
      gate = make_ref()
      request = authorization_checkpoint(request, gate)

      assert {:ok, %NoteSaveResult{outcome: :conflict} = saved} =
               authorized_mutate(c, :save, request, fn _repo, members ->
                 assert members == refs
                 send(self(), {gate, :authorized})
                 :ok
               end)

      assert saved.canonical_version_id == current.version_id
      assert_members(c, saved.submitted_version_id, refs)
      assert_members(c, current.version_id, %{attachments: [], citations: []})
      assert_effects(c, request, saved, "conflict", 1)
      refute_received {^gate, :authorized}
    end)
  end

  test "server context Merge excludes retained members from both parents from authorization", c do
    grants(fn ->
      scenario = seed_conflict(c)
      new_refs = references(c)

      refs = %{
        attachments:
          scenario.competing_refs.attachments ++
            new_refs.attachments ++ scenario.current_refs.attachments,
        citations: new_refs.citations
      }

      request = intent(c, :merge, scenario, refs)
      gate = make_ref()
      request = authorization_checkpoint(request, gate)

      assert {:ok, %NoteSaveResult{outcome: :saved} = merged} =
               authorized_mutate(c, :merge, request, fn _repo, members ->
                 assert members == new_refs
                 assert_reference_shapes(members)
                 send(self(), {gate, :authorized})
                 :ok
               end)

      assert_members(c, merged.submitted_version_id, refs)
      assert_merge(c, scenario, merged)
      assert_effects(c, request, merged, "saved", 2)
      refute_received {^gate, :authorized}
    end)
  end

  for operation <- [:create, :save, :merge] do
    @authorization_operation operation
    test "server context #{@authorization_operation} source denial rolls back all canonical and effect rows",
         c do
      grants(fn ->
        {request, refs} = authorization_request(c, @authorization_operation)
        before = state(c)
        gate = make_ref()
        denial = Error.new(:forbidden)

        request =
          Map.put(request, :failure_injector, %{
            after_source_prepare: fn ->
              flunk("denial passed the source preparation checkpoint")
            end,
            after_resource_lock: fn -> flunk("denial acquired source resource locks") end
          })

        assert {:error, ^denial} =
                 authorized_mutate(c, @authorization_operation, request, fn _repo, members ->
                   assert members == refs
                   send(self(), {gate, :denied})
                   {:error, denial}
                 end)

        assert_received {^gate, :denied}
        refute_received {^gate, :denied}
        assert state(c) == before
        assert_no_effects(c, request)
      end)
    end
  end

  for mode <- [:inherit, :explicit_retained, :clear, :merge_retained] do
    @retained_mode mode
    test "server context #{@retained_mode} skips new-source authorization after source deletion",
         c do
      grants(fn ->
        {operation, request, expected_refs} =
          if @retained_mode == :merge_retained do
            scenario = seed_conflict(c)
            tombstone(c, c.document.resource_id)
            tombstone(c, scenario.note_target.resource_id)

            refs = %{
              attachments:
                scenario.competing_refs.attachments ++ scenario.current_refs.attachments,
              citations: []
            }

            {:merge, intent(c, :merge, scenario, refs), refs}
          else
            refs = references(c)
            base = seed_note(c, refs)
            tombstone(c, c.fixture.resource_id)
            tombstone(c, c.document.resource_id)

            replacement =
              case @retained_mode do
                :inherit -> %{}
                :explicit_retained -> refs
                :clear -> %{attachments: [], citations: []}
              end

            expected = if @retained_mode == :clear, do: replacement, else: refs
            {:save, intent(c, :save, base, replacement), expected}
          end

        assert {:ok, %NoteSaveResult{outcome: :saved} = saved} =
                 authorized_mutate(c, operation, request, fn _repo, _members ->
                   flunk("retained/clear source set requested current source authority")
                 end)

        assert_members(c, saved.submitted_version_id, expected_refs)
        assert_effects(c, request, saved, "saved", if(operation == :merge, do: 2, else: 1))
      end)
    end
  end

  for operation <- [:create, :save, :merge] do
    @replay_operation operation
    test "server context #{@replay_operation} replay skips deleted sources and a currently denying callback",
         c do
      grants(fn ->
        {request, refs} = authorization_request(c, @replay_operation)
        gate = make_ref()

        assert {:ok, %NoteSaveResult{} = saved} =
                 authorized_mutate(c, @replay_operation, request, fn _repo, members ->
                   assert members == refs
                   send(self(), {gate, :authorized})
                   :ok
                 end)

        assert_received {^gate, :authorized}
        refute_received {^gate, :authorized}
        assert_members(c, saved.submitted_version_id, refs)
        tombstone(c, c.fixture.resource_id)
        tombstone(c, c.document.resource_id)

        replay =
          Map.put(request, :failure_injector, %{
            after_source_prepare: fn -> flunk("replay prepared sources") end,
            after_resource_lock: fn -> flunk("replay acquired source locks") end
          })

        before = state(c)

        assert {:ok, ^saved} =
                 authorized_mutate(c, @replay_operation, replay, fn _repo, _members ->
                   flunk("replay requested currently revoked source read authority")
                   {:error, Error.new(:forbidden)}
                 end)

        assert state(c) == before
        assert_members(c, saved.submitted_version_id, refs)
      end)
    end
  end

  for operation <- [:create, :save, :merge] do
    @invalid_context_operation operation
    test "#{@invalid_context_operation} rejects mapped contexts without a valid two-arity callback",
         c do
      grants(fn ->
        {request, _refs} = authorization_request(c, @invalid_context_operation)
        invalid = Error.new(:invalid)

        for callback <- [
              :missing,
              nil,
              :not_a_function,
              fn -> flunk("zero-arity authorization callback ran") end,
              fn _ -> flunk("one-arity authorization callback ran") end,
              fn _, _, _ -> flunk("three-arity authorization callback ran") end
            ] do
          before = state(c)

          assert {:error, ^invalid} =
                   scoped(c, fn repo ->
                     context =
                       if callback == :missing,
                         do: %{repo: repo},
                         else: %{repo: repo, authorize_new_sources: callback}

                     apply(NoteRepository, @invalid_context_operation, [context, request])
                   end)

          assert state(c) == before
          assert_no_effects(c, request)
        end
      end)
    end
  end

  test "server context empty Create skips source authorization and still seals its version", c do
    grants(fn ->
      refs = %{attachments: [], citations: []}
      request = intent(c, :create, %{}, refs)

      assert {:ok, %NoteSaveResult{outcome: :saved} = saved} =
               authorized_mutate(c, :create, request, fn _repo, _members ->
                 flunk("empty Create requested source authority")
               end)

      assert_members(c, saved.submitted_version_id, refs)
      assert_effects(c, request, saved, "saved", 1)
    end)
  end

  test "server context invalid prepared member fails before invoking source authorization", c do
    grants(fn ->
      base = seed_note(c, %{attachments: [], citations: []})
      refs = %{attachments: [attachment(base, :note, "self")], citations: []}
      request = intent(c, :save, base, refs)
      before = state(c)

      assert {:error, %Error{code: :invalid}} =
               authorized_mutate(c, :save, request, fn _repo, _members ->
                 flunk("unvalidated self-reference reached source authorization")
               end)

      assert state(c) == before
      assert_no_effects(c, request)
    end)
  end

  defp authorization_request(c, :create) do
    refs = references(c)
    {intent(c, :create, %{}, refs), refs}
  end

  defp authorization_request(c, :save) do
    base = seed_note(c, %{attachments: [], citations: []})
    refs = references(c)
    {intent(c, :save, base, refs), refs}
  end

  defp authorization_request(c, :merge) do
    scenario = seed_conflict(c)
    refs = references(c)
    {intent(c, :merge, scenario, refs), refs}
  end

  defp authorization_checkpoint(request, gate) do
    Map.put(request, :failure_injector, %{
      after_source_prepare: fn ->
        assert_received {^gate, :authorized}
        refute_received {^gate, :authorized}
        send(self(), {gate, :checkpoint})
        :ok
      end,
      after_resource_lock: fn ->
        assert_received {^gate, :checkpoint}
        refute_received {^gate, :checkpoint}
        :ok
      end
    })
  end

  defp authorized_mutate(c, operation, request, callback) do
    scoped(c, fn repo ->
      %{rows: [[backend, transaction]]} =
        query!(repo, "SELECT pg_backend_pid(),txid_current()")

      context = %{
        repo: repo,
        authorize_new_sources: fn actual_repo, members ->
          assert actual_repo == repo
          assert actual_repo.in_transaction?()

          assert %{rows: [[^backend, ^transaction, principal, owner]]} =
                   query!(
                     actual_repo,
                     "SELECT pg_backend_pid(),txid_current(),current_setting('singularity.principal_id'),current_setting('singularity.vault_id')"
                   )

          assert {principal, owner} == {c.fixture.principal_id, c.fixture.vault_id}

          assert %{rows: [["pending"]]} =
                   query!(
                     actual_repo,
                     "SELECT state FROM content.note_mutation_receipts WHERE mutation_id=$1",
                     [uuid(request.mutation_id)]
                   )

          assert %{rows: [[0]]} =
                   query!(
                     actual_repo,
                     "SELECT count(*) FROM pg_locks WHERE pid=pg_backend_pid() AND locktype='relation' AND mode='RowShareLock' AND relation IN ('content.assets'::regclass,'content.asset_objects'::regclass,'content.resources'::regclass,'content.resource_versions'::regclass,'content.resource_assets'::regclass)"
                   )

          callback.(actual_repo, members)
        end
      }

      apply(NoteRepository, operation, [context, request])
    end)
  end

  defp assert_reference_shapes(%{attachments: attachments, citations: citations} = members) do
    assert Enum.sort(Map.keys(members)) == [:attachments, :citations]

    for %NoteAttachmentReference{} = ref <- attachments do
      assert Enum.sort(Map.keys(Map.from_struct(ref))) ==
               [
                 :attachment_id,
                 :label,
                 :role,
                 :target_kind,
                 :target_resource_id,
                 :target_resource_version_id
               ]
    end

    for %NoteCitationReference{} = ref <- citations do
      assert Enum.sort(Map.keys(Map.from_struct(ref))) ==
               [
                 :citation_id,
                 :fragment_id,
                 :locator,
                 :source_resource_id,
                 :source_resource_version_id
               ]
    end
  end

  defp grants(fun) do
    KnowledgeTestGrants.with_grants(
      ~w(note_attachments note_citations document_versions document_fragments),
      fn ->
        KnowledgeTestGrants.with_lifecycle_grants(fun)
      end
    )
  end

  defp references(c) do
    %{
      attachments: [
        attachment(
          %{resource_id: c.fixture.resource_id, version_id: c.fixture.resource_version_id},
          :asset,
          "original"
        )
      ],
      citations: [citation(c)]
    }
  end

  defp attachment(target, kind, label) do
    {:ok, ref} =
      NoteAttachmentReference.new(%{
        attachment_id: Ecto.UUID.generate(),
        target_resource_id: target.resource_id,
        target_resource_version_id: target.version_id,
        target_kind: kind,
        role: :source,
        label: label
      })

    ref
  end

  defp citation(c) do
    {:ok, ref} =
      NoteCitationReference.new(%{
        citation_id: Ecto.UUID.generate(),
        source_resource_id: c.document.resource_id,
        source_resource_version_id: c.document.resource_version_id,
        fragment_id: c.fragment.fragment_id,
        locator: c.fragment.locator
      })

    ref
  end

  defp intent(c, operation, note, refs \\ %{}) do
    attrs = Map.merge(%{classification: :private, title: "metadata only", markdown: "body"}, refs)

    attrs =
      case operation do
        :create ->
          attrs

        :save ->
          Map.put(attrs, :parent_version_id, note.version_id)

        :merge ->
          Map.merge(attrs, %{
            parent_version_id: note.current.version_id,
            merge_parent_version_id: note.competing.version_id
          })
      end

    constructor = %{create: :initial, save: :normal, merge: :merge}[operation]
    {:ok, snapshot} = apply(NoteSnapshot, constructor, [attrs])

    request = %{
      mutation_id: Ecto.UUID.generate(),
      principal_id: c.fixture.principal_id,
      vault_id: c.fixture.vault_id,
      classification: :private,
      correlation_id: Ecto.UUID.generate(),
      snapshot: snapshot
    }

    request =
      case operation do
        :create ->
          request

        :save ->
          Map.merge(request, %{resource_id: note.resource_id, base_version_id: note.version_id})

        :merge ->
          Map.merge(request, %{
            resource_id: note.base.resource_id,
            conflict_id: note.conflict_id,
            expected_current_version_id: note.current.version_id,
            competing_version_id: note.competing.version_id
          })
      end

    # Storage contracts use a deterministic test caller fingerprint, without a
    # prohibited dependency on Runtime's independently verified HMAC producer.
    fingerprint =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({operation, Map.drop(request, [:mutation_id, :correlation_id])}, [
          :deterministic
        ])
      )

    Map.put(request, :request_fingerprint, fingerprint)
  end

  defp mutate(c, operation, request),
    do: scoped(c, &apply(NoteRepository, operation, [&1, request]))

  defp scoped(c, fun),
    do:
      ScopedRepo.transact(
        RequestRepo,
        %{principal_id: c.fixture.principal_id, vault_id: c.fixture.vault_id},
        fun
      )

  # Historical fixtures are legal atomic publications, not calls to the missing
  # mutation feature. This lets every inheritance/merge/race contract reach its
  # own assertion independently of source-enabled create.
  defp seed_note(c, refs) do
    note = %{resource_id: Ecto.UUID.generate(), version_id: Ecto.UUID.generate()}

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.resources(id,vault_id,classification,kind,current_version_id,title) VALUES($1,$2,'private','note',$3,'Note')",
        [uuid(note.resource_id), c.source.vault_id, uuid(note.version_id)]
      )

      insert_version(c, note, 0, nil, refs)
    end)

    assert_members(c, note.version_id, refs)
    note
  end

  defp seed_version(c, parent, revision, refs, head? \\ true) do
    note = %{parent | version_id: Ecto.UUID.generate()}

    Fixtures.with_owner(fn ->
      insert_version(c, note, revision, parent.version_id, refs)

      if head?,
        do:
          query!(
            MigrationRepo,
            "UPDATE content.resources SET current_version_id=$1 WHERE id=$2",
            [uuid(note.version_id), uuid(note.resource_id)]
          )
    end)

    assert_members(c, note.version_id, refs)
    note
  end

  defp insert_version(c, note, revision, parent, refs) do
    query!(
      MigrationRepo,
      "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',$4)",
      [uuid(note.version_id), uuid(note.resource_id), c.source.vault_id, revision]
    )

    query!(
      MigrationRepo,
      "INSERT INTO content.note_versions(resource_version_id,resource_id,vault_id,classification,title,markdown,created_by_principal_id,parent_version_id,inserted_at) VALUES($1,$2,$3,'private','Note','body',$4,$5,CURRENT_TIMESTAMP)",
      [
        uuid(note.version_id),
        uuid(note.resource_id),
        c.source.vault_id,
        c.source.principal_id,
        optional_uuid(parent)
      ]
    )

    for {ref, ordinal} <- Enum.with_index(refs.attachments) do
      query!(
        MigrationRepo,
        "INSERT INTO content.note_attachments(note_resource_version_id,id,note_resource_id,vault_id,classification,target_resource_id,target_resource_version_id,target_kind,ordinal,role,label,inserted_at) VALUES($1,$2,$3,$4,'private',$5,$6,$7,$8,'source',$9,CURRENT_TIMESTAMP)",
        [
          uuid(note.version_id),
          uuid(ref.attachment_id),
          uuid(note.resource_id),
          c.source.vault_id,
          uuid(ref.target_resource_id),
          uuid(ref.target_resource_version_id),
          Atom.to_string(ref.target_kind),
          ordinal,
          ref.label
        ]
      )
    end

    for {ref, ordinal} <- Enum.with_index(refs.citations) do
      query!(
        MigrationRepo,
        "INSERT INTO content.note_citations(note_resource_version_id,id,note_resource_id,vault_id,classification,source_resource_id,source_resource_version_id,fragment_id,locator,ordinal,inserted_at) VALUES($1,$2,$3,$4,'private',$5,$6,$7,$8,$9,CURRENT_TIMESTAMP)",
        [
          uuid(note.version_id),
          uuid(ref.citation_id),
          uuid(note.resource_id),
          c.source.vault_id,
          uuid(ref.source_resource_id),
          uuid(ref.source_resource_version_id),
          ref.fragment_id,
          SourceLocator.to_map(ref.locator),
          ordinal
        ]
      )
    end
  end

  defp seed_conflict(c) do
    note_target = seed_note(c, %{attachments: [], citations: []})
    base = seed_note(c, %{attachments: [], citations: []})

    current_refs = %{
      attachments: [
        attachment(
          %{resource_id: c.document.resource_id, version_id: c.document.resource_version_id},
          :document,
          "current"
        )
      ],
      citations: []
    }

    competing_refs = %{attachments: [attachment(note_target, :note, "competing")], citations: []}
    current = seed_version(c, base, 1, current_refs)
    competing = seed_version(c, base, 2, competing_refs, false)
    conflict_id = Ecto.UUID.generate()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.note_conflicts(id,resource_id,vault_id,classification,base_version_id,canonical_version_id,competing_version_id,state,created_at) VALUES($1,$2,$3,'private',$4,$5,$6,'open',CURRENT_TIMESTAMP)",
        [
          uuid(conflict_id),
          uuid(base.resource_id),
          c.source.vault_id,
          uuid(base.version_id),
          uuid(current.version_id),
          uuid(competing.version_id)
        ]
      )
    end)

    %{
      base: base,
      current: current,
      competing: competing,
      conflict_id: conflict_id,
      current_refs: current_refs,
      competing_refs: competing_refs,
      note_target: note_target
    }
  end

  defp assert_members(c, version, refs) do
    {attachments, citations, seals} = stored_members(c, version)

    expected_attachments =
      Enum.with_index(refs.attachments)
      |> Enum.map(fn {r, i} ->
        {r.attachment_id, r.target_resource_id, r.target_resource_version_id,
         Atom.to_string(r.target_kind), i, r.label}
      end)

    expected_citations =
      Enum.with_index(refs.citations)
      |> Enum.map(fn {r, i} ->
        {r.citation_id, r.source_resource_id, r.source_resource_version_id, r.fragment_id,
         SourceLocator.to_map(r.locator), i}
      end)

    assert Enum.map(attachments, fn [
                                      id,
                                      _note,
                                      owner,
                                      classification,
                                      target,
                                      pin,
                                      kind,
                                      ordinal,
                                      role,
                                      label,
                                      _at
                                    ] ->
             assert {owner, classification, role} == {c.fixture.vault_id, "private", "source"}
             {id, target, pin, kind, ordinal, label}
           end) == expected_attachments

    assert Enum.map(citations, fn [
                                    id,
                                    _note,
                                    owner,
                                    classification,
                                    source,
                                    pin,
                                    fragment,
                                    locator,
                                    ordinal,
                                    _at
                                  ] ->
             assert {owner, classification} == {c.fixture.vault_id, "private"}
             {id, source, pin, fragment, locator, ordinal}
           end) == expected_citations

    assert [[note, owner, "private", attachment_count, citation_count]] = seals

    assert {owner, attachment_count, citation_count} ==
             {c.fixture.vault_id, length(refs.attachments), length(refs.citations)}

    assert Enum.all?(attachments, fn [_, n | _] -> n == note end)
    assert Enum.all?(citations, fn [_, n | _] -> n == note end)
  end

  defp stored_members(c, version) do
    scoped(c, fn repo ->
      attachments =
        query!(
          repo,
          "SELECT id::text,note_resource_id::text,vault_id::text,classification,target_resource_id::text,target_resource_version_id::text,target_kind,ordinal,role,label,inserted_at FROM content.note_attachments WHERE note_resource_version_id=$1 ORDER BY ordinal",
          [uuid(version)]
        ).rows

      citations =
        query!(
          repo,
          "SELECT id::text,note_resource_id::text,vault_id::text,classification,source_resource_id::text,source_resource_version_id::text,fragment_id,locator,ordinal,inserted_at FROM content.note_citations WHERE note_resource_version_id=$1 ORDER BY ordinal",
          [uuid(version)]
        ).rows

      seals =
        query!(
          repo,
          "SELECT note_resource_id::text,vault_id::text,classification,attachment_count,citation_count FROM content.note_source_set_seals WHERE note_resource_version_id=$1",
          [uuid(version)]
        ).rows

      {attachments, citations, seals}
    end)
  end

  defp assert_effects(c, request, result, outcome, events) do
    assert %{rows: [["completed", ^outcome, resource, version, 1, ^events, head, projection]]} =
             scoped(c, fn repo ->
               query!(
                 repo,
                 "SELECT receipt.state,receipt.outcome,receipt.resource_id::text,receipt.version_id::text,(SELECT count(*) FROM audit.events WHERE correlation_id=$2),(SELECT count(*) FROM core.outbox_events WHERE correlation_id=$2),r.current_version_id::text,p.resource_version_id::text FROM content.note_mutation_receipts receipt JOIN content.resources r ON r.id=receipt.resource_id LEFT JOIN content.note_search_documents p ON p.resource_id=r.id WHERE receipt.mutation_id=$1",
                 [uuid(request.mutation_id), uuid(request.correlation_id)]
               )
             end)

    assert {resource, version} == {result.resource_id, result.submitted_version_id}
    if outcome == "saved", do: assert({head, projection} == {version, version})
  end

  defp assert_merge(c, scenario, merged) do
    assert %{rows: [[parent, other_parent, "resolved", resolution]]} =
             scoped(c, fn repo ->
               query!(
                 repo,
                 "SELECT n.parent_version_id::text,n.merge_parent_version_id::text,conflict.state,conflict.resolution_version_id::text FROM content.note_versions n JOIN content.note_conflicts conflict ON conflict.id=$2 WHERE n.resource_version_id=$1",
                 [uuid(merged.submitted_version_id), uuid(scenario.conflict_id)]
               )
             end)

    assert {parent, other_parent, resolution} ==
             {scenario.current.version_id, scenario.competing.version_id,
              merged.submitted_version_id}
  end

  defp assert_no_effects(c, request) do
    assert %{rows: [[0, 0, 0]]} =
             scoped(c, fn repo ->
               query!(
                 repo,
                 "SELECT (SELECT count(*) FROM content.note_mutation_receipts WHERE mutation_id=$1),(SELECT count(*) FROM audit.events WHERE correlation_id=$2),(SELECT count(*) FROM core.outbox_events WHERE correlation_id=$2)",
                 [uuid(request.mutation_id), uuid(request.correlation_id)]
               )
             end)
  end

  defp state(c) do
    Fixtures.with_owner(fn ->
      for table <-
            ~w(content.resources content.resource_versions content.note_versions content.note_attachments content.note_citations content.note_source_set_seals content.note_conflicts content.note_mutation_receipts content.note_search_documents content.search_entries audit.events core.outbox_events jobs.job_submissions) do
        # Constants only; deterministic exact JSON snapshots include derived seal
        # timestamps and full effects, not merely plausible aggregate counts.
        query!(
          MigrationRepo,
          "SELECT COALESCE(jsonb_agg(row ORDER BY row::text),'[]'::jsonb) FROM (SELECT to_jsonb(t) row FROM #{table} t WHERE vault_id=$1) s",
          [c.source.vault_id]
        ).rows
      end
    end)
  end

  defp tombstone(_c, resource) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.resources SET deleted_at=clock_timestamp() WHERE id=$1",
        [uuid(resource)]
      )
    end)
  end

  defp delete_asset(repo, c) do
    %{rows: [[revision]]} =
      query!(repo, "SELECT state_revision FROM content.assets WHERE id=$1", [c.source.asset_id])

    AssetDeletionRepository.tombstone_and_release(repo, %{
      asset_id: c.fixture.asset_id,
      principal_id: c.fixture.principal_id,
      vault_id: c.fixture.vault_id,
      classification: :private,
      expected_state_revision: revision
    })
  end

  defp document_context(c),
    do: %{
      repo: RequestRepo,
      principal_id: c.fixture.principal_id,
      owner_scope_id: c.fixture.vault_id
    }

  defp with_lifecycle_bridge(fun) do
    # Same registry bridge as the established immutable source-reader race:
    # every SQL query uses RequestRepo's actual pool and scoped connection.
    {:ok, bridge} = Agent.start_link(fn -> nil end, name: PausedLifecycleRepo)

    try do
      :ok =
        Ecto.Repo.Registry.associate(
          bridge,
          PausedLifecycleRepo,
          Ecto.Adapter.lookup_meta(RequestRepo)
        )

      fun.()
    after
      Agent.stop(bridge)
    end
  end

  defp completion(c, document, fragment \\ nil)

  defp completion(c, document, nil) do
    {:ok, fragment} =
      DocumentFragment.new(%{
        resource_id: document.resource_id,
        resource_version_id: document.resource_version_id,
        owner_scope_id: c.fixture.vault_id,
        classification: :private,
        ordinal: 0,
        text: "text",
        locator: %{"version" => 1, "kind" => "text", "start_line" => 1, "end_line" => 1}
      })

    completion(c, document, fragment)
  end

  defp completion(c, document, fragment) do
    {:ok, completion} =
      DocumentCompletion.new(%{
        resource_id: document.resource_id,
        resource_version_id: document.resource_version_id,
        owner_scope_id: c.fixture.vault_id,
        classification: :private,
        generation: 1,
        outcome: :ready,
        adapter_name: "plain",
        format_version: 1,
        finished_at: ~U[2020-01-01 00:00:00.000000Z],
        media_type: "text/plain",
        fragments: [fragment],
        extracted_text_digest: fragment.digest,
        detected_language: "en"
      })

    completion
  end

  # The entire child lifetime, including ready/start/lock waits and terminal
  # assertions, belongs to this unconditional cleanup boundary. Unexpected SQL
  # failures are returned explicitly instead of linked exits killing the repo.
  defp with_connection(label, gate, operation, callback) do
    parent = self()

    task =
      Task.async(fn ->
        result =
          try do
            RequestRepo.checkout(fn ->
              %{rows: [[backend]]} = query!(RequestRepo, "SELECT pg_backend_pid()")
              send(parent, {gate, :ready, label, self(), backend})
              wait(gate, :start)
              operation.()
            end)
          rescue
            exception -> {:child_exception, exception.__struct__, Exception.message(exception)}
          catch
            kind, reason -> {:child_exit, kind, reason}
          end

        send(parent, {gate, :outcome, label, result})
        result
      end)

    try do
      callback.(task)
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp ready(gate, label) do
    receive do
      {^gate, :ready, ^label, pid, backend} ->
        {pid, backend}

      {^gate, :outcome, ^label, result} ->
        flunk("connection ended before ready: #{inspect(result)}")
    after
      @barrier_timeout -> flunk("connection ready barrier timed out")
    end
  end

  defp hold(parent, gate, checkpoint) do
    send(parent, {gate, :checkpoint, checkpoint, self()})
    wait(gate, :continue)
  end

  defp wait(gate, action) do
    receive do
      {^gate, ^action} -> :ok
    after
      @barrier_timeout -> raise "note source connection barrier timed out"
    end
  end

  defp await_gate(gate, checkpoint) do
    receive do
      {^gate, :checkpoint, ^checkpoint, pid} ->
        pid

      {^gate, :outcome, label, result} ->
        flunk("#{label} ended before checkpoint: #{inspect(result)}")
    after
      @barrier_timeout -> flunk("note source checkpoint timed out")
    end
  end

  defp await_either_lock(gate) do
    receive do
      {^gate, :checkpoint, {:locked, label}, pid} ->
        {label, pid}

      {^gate, :outcome, label, result} ->
        flunk("#{label} ended before ordered locks: #{inspect(result)}")
    after
      @barrier_timeout -> flunk("ordered source lock barrier timed out")
    end
  end

  defp await_lock(gate, label) do
    receive do
      {^gate, :checkpoint, {:locked, ^label}, pid} ->
        pid

      {^gate, :outcome, ^label, result} ->
        flunk("#{label} ended before ordered locks: #{inspect(result)}")
    after
      @barrier_timeout -> flunk("ordered source contender lock barrier timed out")
    end
  end

  defp blocked_by!(waiting, blocking, gate, attempts \\ 200)

  defp blocked_by!(_, _, _, 0),
    do: flunk("source writer did not block on the expected PostgreSQL backend")

  defp blocked_by!(waiting, blocking, gate, attempts) do
    receive do
      {^gate, :outcome, label, result} ->
        flunk("#{label} ended instead of blocking: #{inspect(result)}")
    after
      0 -> :ok
    end

    %{rows: [[blocked?]]} =
      query!(RequestRepo, "SELECT $2::integer=ANY(pg_blocking_pids($1::integer))", [
        waiting,
        blocking
      ])

    unless blocked? do
      Process.sleep(10)
      blocked_by!(waiting, blocking, gate, attempts - 1)
    end
  end

  defp ids(map),
    do:
      Map.new(map, fn {key, value} ->
        {key,
         if(String.ends_with?(Atom.to_string(key), "_id"),
           do: Ecto.UUID.load!(value),
           else: value
         )}
      end)

  defp uuid(text), do: Ecto.UUID.dump!(text)
  defp optional_uuid(nil), do: nil
  defp optional_uuid(text), do: uuid(text)
end
