defmodule Singularity.Storage.KnowledgeExport.RepositoryTest do
  use Singularity.Storage.DataCase, async: false

  alias Singularity.Core.{DocumentFragment, Error, SourceLocator}
  alias Singularity.Runtime.{Authorize, OperationScope}
  alias Singularity.Runtime.KnowledgeExportSnapshotFixture, as: LiveFixture
  alias Singularity.Storage.{Fixtures, KnowledgeFixtures, MigrationRepo, ScopedRepo}
  alias Singularity.Storage.Postgres.KnowledgeLinkRepository

  @moduletag :integration
  @moduletag :tmp_dir
  @repository Singularity.Storage.KnowledgeExport.Repository
  @snapshot Singularity.Runtime.Knowledge.ExportSnapshot
  @spool Singularity.Storage.KnowledgeExport.Spool
  @time "2026-10-11T01:02:03.123456Z"
  @deleted "2026-10-11T02:03:04.123456Z"
  @collections ~w(resources versions fragments tags tag_assignments relationships attachments citations)a

  defmodule PrecommitOwnerScope do
    # Existing fixture authority only; never a RequestRepo grant or policy.
    def transact(repo, context, callback),
      do: transact(repo, context, [isolation: :repeatable_read], callback)

    def transact(repo, context, options, callback) do
      Singularity.Storage.ScopedRepo.transact(repo, context, options, fn scoped ->
        Singularity.Storage.SafeSQL.query!(scoped, "SET LOCAL ROLE singularity_table_owner", [])
        callback.(scoped)
      end)
    end
  end

  defmodule PrecommitIdentity do
    require ExUnit.Assertions
    # Existing migration SET authority, used only around the unchanged native
    # identity store. A savepoint also restores owner after a SQL-aborted read.
    def load_live_session(observer, repo, session_id) do
      try do
        ExUnit.Assertions.assert(self() == observer.caller)
        ExUnit.Assertions.assert(repo == Singularity.Storage.MigrationRepo)
        ExUnit.Assertions.assert(repo.in_transaction?())
        before = backend_binding(repo)
        ExUnit.Assertions.assert(before.backend == observer.backend)
        ExUnit.Assertions.assert(before.role == "singularity_table_owner")
        ExUnit.Assertions.assert(before.session_user == "singularity_migration")
        ExUnit.Assertions.assert(before.isolation == "repeatable read")
        ExUnit.Assertions.assert(before.read_only == "off")
        ExUnit.Assertions.assert(before.principal == observer.principal)
        ExUnit.Assertions.assert(before.owner == observer.owner)

        sql(repo, "SAVEPOINT knowledge_export_native_identity")
        sql(repo, "SET LOCAL ROLE singularity_authorization_definer")
        during = backend_binding(repo)
        ExUnit.Assertions.assert(during == %{before | role: "singularity_authorization_definer"})

        delegated =
          try do
            {module, context} = observer.delegate
            {:returned, apply(module, :load_live_session, [context, repo, session_id])}
          catch
            kind, reason -> {:raised, kind, reason, __STACKTRACE__}
          end

        # The read may return an ordinary storage error after aborting SQL, or
        # raise. Restore in both cases without rolling back earlier owner writes.
        sql(repo, "ROLLBACK TO SAVEPOINT knowledge_export_native_identity")
        sql(repo, "RELEASE SAVEPOINT knowledge_export_native_identity")
        restored = backend_binding(repo)
        ExUnit.Assertions.assert(restored == before)

        observation =
          case delegated do
            {:returned, value} -> {:returned, value}
            {:raised, kind, _reason, _stack} -> {:raised, kind}
          end

        send(
          observer.caller,
          {:precommit_native_identity, observer.token, self(), repo, before, during, restored,
           observation}
        )

        case delegated do
          {:returned, value} -> value
          {:raised, kind, reason, stack} -> :erlang.raise(kind, reason, stack)
        end
      catch
        kind, reason ->
          # Checked outside Authorize's exception-to-forbidden boundary. Setup
          # or restoration failure cannot masquerade as content integrity denial.
          send(observer.caller, {:precommit_native_failure, observer.token})
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end

    def backend_binding(repo) do
      %{rows: [[backend, xid, isolation, read_only, role, login, principal, owner]]} =
        sql(
          repo,
          "SELECT pg_backend_pid(),pg_current_xact_id()::text,current_setting('transaction_isolation'),current_setting('transaction_read_only'),current_user,session_user,current_setting('singularity.principal_id',true),current_setting('singularity.vault_id',true)"
        )

      %{
        backend: backend,
        xid: xid,
        isolation: isolation,
        read_only: read_only,
        role: role,
        session_user: login,
        principal: principal,
        owner: owner
      }
    end

    defp sql(repo, statement), do: Singularity.Storage.SafeSQL.query!(repo, statement, [])
  end

  setup %{tmp_dir: tmp_dir} do
    # The compiled shared fixture uses the real resolver, Authorize, ScopedRepo,
    # existing locks and KeyCustodian without requiring another app's case file.
    c = apply(LiveFixture, :live_fixture!, [tmp_dir])
    %{fixture: c}
  end

  test "requires a live scoped RR transaction and lexical authority, never owner maps or GUC proof",
       %{fixture: c} do
    for proof <- [
          true,
          c.session,
          %{owner_scope_id: c.session.vault_id},
          %{
            authorized?: true,
            principal_id: c.session.principal_id,
            owner_scope_id: c.session.vault_id
          }
        ] do
      spool = open(c)
      assert_error(call(:capture, [RequestRepo, proof, %{}, spool]))
      assert :ok = apply(@spool, :abort, [spool])
      spool = open(c)
      assert_error(with_scope(c, true, fn repo -> call(:capture, [repo, proof, %{}, spool]) end))
      assert :ok = apply(@spool, :abort, [spool])
    end

    spool = open(c)

    assert_error(
      with_scope(c, false, fn repo ->
        call(:capture, [repo, authorization(c, repo), %{}, spool])
      end)
    )

    assert :ok = apply(@spool, :abort, [spool])
  end

  test "RR without matching current principal and owner rejects before selecting content", %{
    fixture: c
  } do
    for field <- ["singularity.principal_id", "singularity.vault_id"] do
      spool = open(c)

      assert_error(
        with_scope(c, true, fn repo ->
          authorize = authorization(c, repo)
          query!(repo, "SELECT set_config($1,$2,true)", [field, Ecto.UUID.generate()])
          call(:capture, [repo, authorize, %{}, spool])
        end)
      )

      assert :ok = apply(@spool, :abort, [spool])
    end
  end

  test "authorization closure must agree with the scoped repo and original caller", %{fixture: c} do
    spool = open(c)

    assert_error(
      with_scope(c, true, fn repo ->
        wrong_repo = authorization(c, WorkerRepo)
        call(:capture, [repo, wrong_repo, %{}, spool])
      end)
    )

    assert :ok = apply(@spool, :abort, [spool])
    spool = open(c)

    assert_error(
      with_scope(c, true, fn repo ->
        wrong_caller = Task.async(fn -> authorization(c, repo) end) |> Task.await()
        call(:capture, [repo, wrong_caller, %{}, spool])
      end)
    )

    assert :ok = apply(@spool, :abort, [spool])
  end

  test "head closure promotes earlier ancestry metadata and terminates exact historical source cycles",
       %{fixture: c} do
    graph = graph!(c)
    sealed = capture!(c)
    versions = records(sealed, :versions)

    expected =
      [
        {graph.old.resource_id, graph.old.resource_version_id, "included"},
        {graph.merge.resource_id, graph.merge.resource_version_id, "metadata_only_unselected"},
        {graph.head.resource_id, graph.head.resource_version_id, "included"},
        {graph.peer.resource_id, graph.peer.resource_version_id, "included"},
        {graph.deleted_note.resource_id, graph.deleted_note.resource_version_id,
         "metadata_only_deleted"},
        {graph.document_old.resource_id, graph.document_old.resource_version_id, "included"},
        {graph.document_head.resource_id, graph.document_head.resource_version_id, "included"},
        {graph.pending.resource_id, graph.pending.resource_version_id, "included"},
        {graph.deleted_document.resource_id, graph.deleted_document.resource_version_id,
         "metadata_only_deleted"},
        {c.source.resource_id, c.source.resource_version_id, "included"},
        {graph.endpoint.resource_id, graph.endpoint.resource_version_id,
         "metadata_only_unselected"}
      ]
      |> Enum.map(fn {resource, version, status} -> {text(resource), text(version), status} end)
      |> Enum.sort()

    actual = Enum.map(versions, &{&1["resource_id"], &1["version_id"], &1["availability"]})
    assert Enum.sort(actual) == expected
    assert length(actual) == length(Enum.uniq(actual))
    refute Enum.any?(versions, &(&1["version_id"] == text(graph.conflict.resource_version_id)))
    refute Enum.any?(versions, &(&1["availability"] == "metadata_only_unavailable"))
    assert_note_version(sealed, graph.old, "included", nil, nil)
    assert_note_version(sealed, graph.head, "included", graph.old, graph.merge)
    assert_note_version(sealed, graph.merge, "metadata_only_unselected", graph.old, nil)
    key = {:note_markdown, text(graph.old.resource_id), text(graph.old.resource_version_id)}
    assert captured_text(sealed, key) == "PROMOTED_OLD_CANONICAL_界"

    assert Map.has_key?(
             sealed.text_refs,
             {:note_markdown, text(graph.peer.resource_id), text(graph.peer.resource_version_id)}
           )

    refute Map.has_key?(
             sealed.text_refs,
             {:note_markdown, text(graph.merge.resource_id),
              text(graph.merge.resource_version_id)}
           )

    refute Map.has_key?(
             sealed.text_refs,
             {:note_markdown, text(graph.conflict.resource_id),
              text(graph.conflict.resource_version_id)}
           )

    assert :ok = apply(@spool, :abort, [sealed])
  end

  test "organization follows settled body selection and does not recursively expand metadata endpoints",
       %{fixture: c} do
    graph = graph!(c)
    sealed = capture!(c)
    resources = records(sealed, :resources)
    reasons = Map.new(resources, &{&1["id"], &1["selection_reason"]})
    assert reasons[text(graph.head.resource_id)] == "head"
    assert reasons[text(graph.peer.resource_id)] == "head"
    assert reasons[c.source.resource_id] == "source"
    assert reasons[text(graph.endpoint.resource_id)] == "relationship_endpoint"
    refute Map.has_key?(reasons, text(graph.unrelated.resource_id))

    assert records(sealed, :relationships) == [
             %{
               "id" => text(graph.edge),
               "source_resource_id" => text(graph.head.resource_id),
               "target_resource_id" => text(graph.endpoint.resource_id),
               "target_version_id" => text(graph.endpoint.resource_version_id),
               "type" => "references"
             }
           ]

    assert records(sealed, :tags) == [
             %{
               "id" => text(graph.tag),
               "display_value" => "Source 界",
               "normalized_key" => "source 界"
             }
           ]

    assert records(sealed, :tag_assignments) == [
             %{"resource_id" => text(graph.head.resource_id), "tag_id" => text(graph.tag)}
           ]

    assert :ok = apply(@spool, :abort, [sealed])
  end

  test "sealed attachments citations and private rendering preserve exact version titles and pins",
       %{fixture: c} do
    graph = graph!(c)
    sealed = capture!(c)

    assert records(sealed, :attachments) ==
             Enum.sort_by(
               graph.expected_attachments,
               &{&1["note_resource_id"], &1["note_version_id"], &1["ordinal"], &1["id"]}
             )

    assert records(sealed, :citations) ==
             Enum.sort_by(
               graph.expected_citations,
               &{&1["note_resource_id"], &1["note_version_id"], &1["ordinal"], &1["id"]}
             )

    key =
      {:render_descriptions, text(graph.peer.resource_id), text(graph.peer.resource_version_id)}

    reference = Map.fetch!(sealed.render_refs, key)
    assert reference.selector == key
    assert reference.capture_id == sealed.capture_id
    {:ok, descriptions} = apply(@spool, :read_chunk, [sealed, reference, 0])
    assert descriptions =~ "Original Note title"
    refute descriptions =~ "CURRENT_NOTE_TITLE"
    assert descriptions =~ text(graph.old.resource_version_id)
    decoded = JSON.decode!(descriptions)
    assert Enum.sort(Map.keys(decoded)) == ["attachments", "citations"]
    [historical | _] = decoded["attachments"]
    assert Enum.sort(Map.keys(historical)) == ["href", "reference", "source"]

    assert historical["source"] == %{
             "kind" => "note",
             "resource_id" => text(graph.old.resource_id),
             "resource_version_id" => text(graph.old.resource_version_id),
             "title" => "Original Note title",
             "deleted?" => false
           }

    assert historical["href"] ==
             "sources/note-#{text(graph.old.resource_id)}-#{text(graph.old.resource_version_id)}.md"

    assert historical["reference"]["target_resource_version_id"] ==
             text(graph.old.resource_version_id)

    assert Enum.map(decoded["citations"], & &1["source"]) == [
             %{
               "kind" => "document",
               "resource_id" => text(graph.document_old.resource_id),
               "resource_version_id" => text(graph.document_old.resource_version_id),
               "title" => "Pinned old Document",
               "deleted?" => false
             },
             %{
               "kind" => "document",
               "resource_id" => text(graph.deleted_document.resource_id),
               "resource_version_id" => text(graph.deleted_document.resource_version_id),
               "title" => "Deleted Document",
               "deleted?" => true
             }
           ]

    assert :ok = apply(@spool, :abort, [sealed])
  end

  test "Document canonical fragments use independent IDs hashes and no-delimiter UTF8 byte offsets",
       %{fixture: c} do
    graph = graph!(c)
    sealed = capture!(c)

    expected =
      Enum.flat_map(
        [{graph.document_old, graph.old_fragments}, {graph.document_head, graph.head_fragments}],
        fn {document, fragments} ->
          {records, _offset} =
            Enum.map_reduce(fragments, 0, fn fragment, offset ->
              record = %{
                "id" =>
                  independent_fragment_id(
                    document.resource_version_id,
                    fragment.ordinal,
                    fragment.text
                  ),
                "resource_id" => text(document.resource_id),
                "version_id" => text(document.resource_version_id),
                "ordinal" => fragment.ordinal,
                "digest" => sha(fragment.text),
                "locator" => locator(fragment.ordinal),
                "extracted_path" => extracted(document),
                "start_byte" => offset,
                "byte_size" => byte_size(fragment.text)
              }

              {record, offset + byte_size(fragment.text)}
            end)

          records
        end
      )

    actual =
      Enum.reject(
        records(sealed, :fragments),
        &(&1["version_id"] == text(graph.deleted_document.resource_version_id))
      )

    assert actual ==
             Enum.sort_by(
               expected,
               &{&1["resource_id"], &1["version_id"], &1["ordinal"], &1["id"]}
             )

    old_version =
      Enum.find(
        records(sealed, :versions),
        &(&1["version_id"] == text(graph.document_old.resource_version_id))
      )

    assert old_version["extracted_digest"] == sha("界\n🙂")
    refute old_version["extracted_digest"] == sha("界\n\n🙂")

    for fragment <- graph.old_fragments do
      key =
        {:fragment_text, text(graph.document_old.resource_id),
         text(graph.document_old.resource_version_id), fragment.ordinal, fragment.fragment_id}

      assert captured_text(sealed, key) == fragment.text
    end

    assert :ok = apply(@spool, :abort, [sealed])
  end

  test "existing membership reader supplies exact sealed counts and contiguous reference ordinals",
       %{fixture: c} do
    graph = graph!(c)

    assert {:ok, :checked} =
             with_scope(c, true, fn repo ->
               context = %{
                 repo: repo,
                 principal_id: c.session.principal_id,
                 owner_scope_id: c.session.vault_id
               }

               assert {:ok, membership} =
                        KnowledgeLinkRepository.read_membership(
                          context,
                          text(graph.peer.resource_id),
                          text(graph.peer.resource_version_id)
                        )

               assert membership.revision == 0

               expected =
                 Enum.filter(
                   graph.expected_attachments,
                   &(&1["note_resource_id"] == text(graph.peer.resource_id))
                 )

               assert Enum.map(membership.attachments, & &1.attachment_id) ==
                        Enum.map(expected, & &1["id"])

               assert Enum.map(membership.citations, & &1.citation_id) ==
                        Enum.map(graph.expected_citations, & &1["id"])

               {:ok, :checked}
             end)
  end

  test "malformed source ordinal cannot become a committed seal or successful truncated capture",
       %{fixture: c} do
    source = binary_source(c.source)
    note = note_identity(source, nil, 0, "Invalid ordinal", "hidden")

    assert_raise Postgrex.Error, fn ->
      Fixtures.with_owner(fn ->
        insert_note!(source, note, nil, nil, true)
        attachment!(source, note, source, :asset, 1)
      end)
    end

    assert %{rows: [[0]]} =
             Fixtures.with_owner(fn ->
               query!(
                 MigrationRepo,
                 "SELECT count(*) FROM content.note_source_set_seals WHERE note_resource_version_id=$1",
                 [note.resource_version_id]
               )
             end)

    sealed = capture!(c)
    assert records(sealed, :versions) == []
    assert records(sealed, :attachments) == []
    assert :ok = apply(@spool, :abort, [sealed])
  end

  test "real authorized precommit unsealed membership is rejected rather than exported", %{
    fixture: c
  } do
    # A legitimate owner-role transaction exposes rows before the existing
    # deferred finalizer. This is NOT proof of committed malformed Runtime data:
    # PostgreSQL prevents that state, as the separate commit-rejection test shows.
    source = binary_source(c.source)
    note = note_identity(source, nil, 0, "Unsealed precommit", "PRECOMMIT_PRIVATE_CANARY")
    spool = open(c)

    result =
      precommit_scope(c, {@snapshot, PrecommitOwnerScope}, 2, fn c, repo ->
        insert_note!(source, note, nil, nil, true)
        attachment!(source, note, source, :asset, 1)

        assert %{rows: [[0]]} =
                 query!(
                   repo,
                   "SELECT count(*) FROM content.note_source_set_seals WHERE note_resource_version_id=$1",
                   [note.resource_version_id]
                 )

        send(self(), :unsealed_precommit_rows_observed)
        assert PrecommitIdentity.backend_binding(repo) == c.precommit_binding

        assert {:error, %Error{code: :not_found}} =
                 KnowledgeLinkRepository.read_membership(
                   %{
                     repo: repo,
                     principal_id: c.session.principal_id,
                     owner_scope_id: c.session.vault_id
                   },
                   text(note.resource_id),
                   text(note.resource_version_id)
                 )

        with_membership_call_witness(fn ->
          call(:capture, [repo, authorization(c, repo), %{}, spool])
        end)
      end)

    assert_receive :unsealed_precommit_rows_observed
    assert_error(result)
    assert {:error, %Error{code: :integrity_failure}} = result
    refute inspect(result) =~ "PRECOMMIT_PRIVATE_CANARY"

    assert %{rows: [[0]]} =
             Fixtures.with_owner(fn ->
               query!(
                 MigrationRepo,
                 "SELECT count(*) FROM content.note_versions WHERE resource_version_id=$1",
                 [note.resource_version_id]
               )
             end)

    assert :ok = apply(@spool, :abort, [spool])
  end

  test "combined source union accepts 100 exact targets and rejects a 101st distinct citation", %{
    fixture: c
  } do
    source = binary_source(c.source)
    document = document!(source, "One cited target", ["citation"])

    assets =
      Fixtures.with_owner(fn ->
        Enum.map(1..100, fn n -> insert_clone_asset!(source, "Source #{n}") end)
      end)

    valid = note_identity(source, nil, 0, "Exactly100", "body")

    Fixtures.with_owner(fn ->
      insert_note!(source, valid, nil, nil, true)

      for {target, ordinal} <- Enum.with_index(assets),
          do: attachment!(source, valid, target, :asset, ordinal)
    end)

    invalid = note_identity(source, nil, 0, "Too many", "hidden")

    assert_raise Postgrex.Error, fn ->
      Fixtures.with_owner(fn ->
        insert_note!(source, invalid, nil, nil, true)

        for {target, ordinal} <- Enum.with_index(assets),
            do: attachment!(source, invalid, target, :asset, ordinal)

        [fragment] = document.fragments
        citation!(source, invalid, document, fragment, 0)
      end)
    end

    sealed = capture!(c)
    attachments = records(sealed, :attachments)
    assert Enum.map(attachments, & &1["ordinal"]) == Enum.to_list(0..99)
    assert length(attachments) == 100
    assert records(sealed, :citations) == []

    assert Enum.count(
             records(sealed, :versions),
             &(&1["kind"] == "asset" and &1["availability"] == "included")
           ) == 100

    refute Enum.any?(
             records(sealed, :versions),
             &(&1["version_id"] == text(invalid.resource_version_id))
           )

    assert :ok = apply(@spool, :abort, [sealed])
  end

  test "included Asset version is a private pending draft with exact binding and no invented plaintext digest",
       %{fixture: c} do
    graph!(c)
    sealed = capture!(c)

    draft =
      Enum.find(records(sealed, :versions), &(&1["version_id"] == c.source.resource_version_id))

    assert draft["availability"] == "included"
    assert draft["kind"] == "asset"
    assert draft["original_byte_size"] == 12
    assert is_nil(draft["original_digest"])
    # Capture-only draft, expressly not a finished Core/public manifest record.
    assert {:error, %Error{code: :invalid}} =
             Singularity.Core.KnowledgeExportManifest.record(:versions, draft)

    key = {:binary_binding, :asset, c.source.resource_id, c.source.resource_version_id}
    reference = Map.fetch!(sealed.binary_refs, key)
    assert reference.capture_id == sealed.capture_id
    assert reference.selector == key
    {:ok, bytes} = apply(@spool, :read_chunk, [sealed, reference, 0])
    binding = JSON.decode!(bytes)
    assert binding["resource_id"] == c.source.resource_id
    assert binding["version_id"] == c.source.resource_version_id
    assert binding["asset_id"] == c.source.asset_id
    assert binding["object_id"] == c.source.object_id
    assert binding["owner_scope_id"] == c.source.vault_id
    assert binding["classification"] == "private"
    assert binding["plaintext_byte_size"] == 12
    assert is_nil(binding["plaintext_sha256"])

    %{
      rows: [
        [
          domain,
          domain_version,
          domain_generation,
          object_generation,
          lookup,
          ciphertext,
          ciphertext_size,
          storage_ref,
          format
        ]
      ]
    } =
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "SELECT o.key_domain_id,e.domain_key_version_id,d.generation,e.key_generation,o.lookup_digest,o.ciphertext_hash,o.ciphertext_byte_size,o.storage_ref,o.format_version FROM content.asset_objects o JOIN content.asset_key_envelopes e ON e.asset_object_id=o.id AND e.vault_id=o.vault_id AND e.key_domain_id=o.key_domain_id JOIN core.domain_key_versions d ON d.id=e.domain_key_version_id AND d.vault_id=e.vault_id AND d.key_domain_id=e.key_domain_id WHERE o.id=$1",
          [dump(c.source.object_id)]
        )
      end)

    assert binding["key_domain_id"] == text(domain)
    assert binding["domain_key_version_id"] == text(domain_version)
    assert binding["domain_key_generation"] == domain_generation
    assert binding["object_generation"] == object_generation
    assert binding["lookup_digest"] == Base.encode16(lookup, case: :lower)
    assert binding["ciphertext_hash"] == Base.encode16(ciphertext, case: :lower)
    assert binding["ciphertext_byte_size"] == ciphertext_size
    assert binding["storage_ref"] == storage_ref
    assert binding["format_version"] == format
    refute binding["lookup_digest"] == draft["original_digest"]
    refute binding["ciphertext_hash"] == draft["original_digest"]

    for record <- records(sealed, :versions) do
      refute Map.has_key?(record, "asset_id")
      refute Map.has_key?(record, "object_id")
      refute Map.has_key?(record, "owner_scope_id")
    end

    assert :ok = apply(@spool, :abort, [sealed])
  end

  test "processing ordinary live Asset pin retains its exact original capture binding", %{
    fixture: c
  } do
    assert_ordinary_asset_state_capture!(c, "processing")
  end

  test "ready ordinary live Asset pin retains its exact original capture binding", %{fixture: c} do
    assert_ordinary_asset_state_capture!(c, "ready")
  end

  test "retired and active envelopes capture only the exact unique active original binding",
       %{fixture: c} do
    graph!(c)
    original = original_binding_evidence!(c.source)

    active_version =
      Fixtures.with_owner(fn ->
        assert %{num_rows: 1} =
                 query!(
                   MigrationRepo,
                   "UPDATE core.domain_key_versions SET state='retired' WHERE id=$1 AND state='active'",
                   [dump(original["domain_key_version_id"])]
                 )

        add_active_envelope!(c.source, original["domain_key_version_id"])
      end)

    assert_envelope_states!(c.source, [
      [original["domain_key_version_id"], "retired", 1, 1],
      [active_version, "active", 2, 2]
    ])

    # SQL metadata selection only: copying existing wrapped values does not
    # prove rotation, decryption or authenticated original-byte availability.
    sealed = capture!(c)

    assert captured_original_binding(sealed, c.source) ==
             %{
               original
               | "domain_key_version_id" => active_version,
                 "domain_key_generation" => 2,
                 "object_generation" => 2
             }

    draft =
      Enum.find(records(sealed, :versions), &(&1["version_id"] == c.source.resource_version_id))

    assert draft["availability"] == "included"
    assert is_nil(draft["original_digest"])
    assert :ok = apply(@spool, :abort, [sealed])
  end

  test "pending or retired only envelopes deny original capture and clean the owned spool",
       %{fixture: c} do
    graph!(c)
    original = original_binding_evidence!(c.source)
    sentinel = Path.join(c.context.root, "inactive-envelope-neighbor")
    File.write!(sentinel, "safe")

    for state <- ["pending", "retired"] do
      Fixtures.with_owner(fn ->
        assert %{num_rows: 1} =
                 query!(
                   MigrationRepo,
                   "UPDATE core.domain_key_versions SET state=$2 WHERE id=$1",
                   [
                     dump(original["domain_key_version_id"]),
                     state
                   ]
                 )
      end)

      assert_envelope_states!(c.source, [[original["domain_key_version_id"], state, 1, 1]])
      assert_integrity_capture_cleanup!(c, sentinel)
    end
  end

  test "two eligible active envelopes deny original capture before sealing", %{fixture: c} do
    graph!(c)
    original = original_binding_evidence!(c.source)

    active_version =
      Fixtures.with_owner(fn ->
        add_active_envelope!(c.source, original["domain_key_version_id"])
      end)

    assert_envelope_states!(c.source, [
      [original["domain_key_version_id"], "active", 1, 1],
      [active_version, "active", 2, 2]
    ])

    sentinel = Path.join(c.context.root, "ambiguous-envelope-neighbor")
    File.write!(sentinel, "safe")
    assert_integrity_capture_cleanup!(c, sentinel)
  end

  test "positively deleted sources expose metadata locator only and optional tombstones add no text",
       %{fixture: c} do
    graph = graph!(c)

    for include <- [false, true] do
      sealed = capture!(c, %{include_tombstones: include})
      versions = records(sealed, :versions)

      for row <- [graph.deleted_note, graph.deleted_document] do
        version = Enum.find(versions, &(&1["version_id"] == text(row.resource_version_id)))
        assert version["availability"] == "metadata_only_deleted"

        for field <- ~w(body_path original_path extracted_path),
            do: assert(is_nil(version[field]))
      end

      [fragment] =
        Enum.filter(
          records(sealed, :fragments),
          &(&1["version_id"] == text(graph.deleted_document.resource_version_id))
        )

      assert fragment["locator"] == locator(0)
      for field <- ~w(extracted_path start_byte byte_size), do: assert(is_nil(fragment[field]))

      refute Map.has_key?(
               sealed.text_refs,
               {:fragment_text, text(graph.deleted_document.resource_id),
                text(graph.deleted_document.resource_version_id), 0,
                hd(graph.deleted_fragments).fragment_id}
             )

      assert Enum.any?(versions, &(&1["version_id"] == text(graph.tombstone.resource_version_id))) ==
               include

      refute Map.has_key?(
               sealed.text_refs,
               {:note_markdown, text(graph.tombstone.resource_id),
                text(graph.tombstone.resource_version_id)}
             )

      refute Map.has_key?(
               sealed.text_refs,
               {:note_markdown, text(graph.deleted_note.resource_id),
                text(graph.deleted_note.resource_version_id)}
             )

      if include do
        assert Enum.any?(
                 records(sealed, :attachments),
                 &(&1["note_version_id"] == text(graph.tombstone.resource_version_id))
               )
      end

      assert :ok = apply(@spool, :abort, [sealed])
    end
  end

  test "a nonready Document includes retained original state but never fabricated extracted text",
       %{fixture: c} do
    pending = document!(binary_source(c.source), "Pending", nil)
    sealed = capture!(c)
    [version] = records(sealed, :versions)
    assert version["version_id"] == text(pending.resource_version_id)
    assert version["state"] == "pending"
    assert version["original_digest"] == Base.encode16(c.source.digest, case: :lower)
    assert version["original_byte_size"] == c.source.byte_size

    assert version["original_path"] ==
             "documents/originals/#{text(pending.resource_id)}--#{text(pending.resource_version_id)}.txt"

    for field <- ~w(extracted_path extracted_digest extraction_adapter extraction_format),
        do: assert(is_nil(version[field]))

    assert records(sealed, :fragments) == []
    assert sealed.text_refs == %{}
    assert :ok = apply(@spool, :abort, [sealed])
  end

  test "live Document retains its exact original binding after source Asset deletion", %{
    fixture: c
  } do
    document = document!(binary_source(c.source), "Retained", nil)
    original = original_binding_evidence!(c.source)
    sentinel = Path.join(c.context.root, "retained-document-neighbor")
    File.write!(sentinel, "safe")

    Fixtures.with_owner(fn ->
      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 "UPDATE content.resource_assets SET released_at=$3 WHERE resource_version_id=$1 AND asset_id=$2 AND released_at IS NULL",
                 [dump(c.source.resource_version_id), dump(c.source.asset_id), datetime(@deleted)]
               )

      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 "UPDATE content.assets SET state='deleted',asset_object_id=NULL WHERE id=$1",
                 [
                   dump(c.source.asset_id)
                 ]
               )

      query!(MigrationRepo, "UPDATE content.resources SET deleted_at=$2 WHERE id=$1", [
        dump(c.source.resource_id),
        datetime(@deleted)
      ])
    end)

    # The ordinary cleanup shape leaves no mutable Asset object pointer. The
    # Document's canonical source identity, digest and size remain authoritative.
    assert %{
             rows: [
               [
                 "deleted",
                 nil,
                 released,
                 deleted,
                 asset,
                 resource,
                 pin,
                 object,
                 digest,
                 size,
                 "available",
                 object_size
               ]
             ]
           } =
             Fixtures.with_owner(fn ->
               query!(
                 MigrationRepo,
                 "SELECT a.state,a.asset_object_id,ra.released_at,r.deleted_at,d.source_asset_id,d.source_resource_id,d.source_resource_version_id,d.source_object_id,d.source_digest,d.source_byte_size,o.lifecycle,o.plaintext_byte_size FROM content.document_versions d JOIN content.assets a ON a.id=d.source_asset_id AND a.vault_id=d.vault_id JOIN content.resource_assets ra ON ra.asset_id=a.id AND ra.resource_version_id=d.source_resource_version_id AND ra.vault_id=d.vault_id JOIN content.resource_versions v ON v.id=d.source_resource_version_id AND v.vault_id=d.vault_id JOIN content.resources r ON r.id=v.resource_id AND r.vault_id=v.vault_id JOIN content.asset_objects o ON o.id=d.source_object_id AND o.vault_id=d.vault_id AND o.classification=d.classification WHERE d.resource_version_id=$1",
                 [document.resource_version_id]
               )
             end)

    assert released == datetime(@deleted)
    assert deleted == datetime(@deleted)
    assert text(asset) == c.source.asset_id
    assert text(resource) == c.source.resource_id
    assert text(pin) == c.source.resource_version_id
    assert text(object) == c.source.object_id
    assert digest == c.source.digest
    assert size == c.source.byte_size
    assert object_size == c.source.byte_size

    sealed = capture!(c)
    [version] = records(sealed, :versions)
    assert version["resource_id"] == text(document.resource_id)
    assert version["availability"] == "included"
    assert version["original_digest"] == Base.encode16(c.source.digest, case: :lower)
    assert version["original_byte_size"] == c.source.byte_size
    assert version["version_id"] == text(document.resource_version_id)

    assert version["original_path"] ==
             "documents/originals/#{text(document.resource_id)}--#{text(document.resource_version_id)}.txt"

    assert captured_original_binding(sealed, c.source) == original

    assert Map.keys(sealed.binary_refs) ==
             [{:binary_binding, :asset, c.source.resource_id, c.source.resource_version_id}]

    assert records(sealed, :fragments) == []
    assert sealed.text_refs == %{}
    refute Enum.any?(records(sealed, :resources), &(&1["id"] == c.source.resource_id))
    assert File.read!(sentinel) == "safe"
    assert :ok = apply(@spool, :abort, [sealed])
    refute File.exists?(Path.join(c.context.root, sealed.capture_id))
    assert File.read!(sentinel) == "safe"
  end

  test "terminal no_extractable_text Document retains its actual original without extracted text",
       %{fixture: c} do
    source = binary_source(c.source)
    document = document!(source, "No extractable text", nil)

    Fixtures.with_owner(fn ->
      set_document_owner!(MigrationRepo, source)
      claim_document!(MigrationRepo, document)

      query!(
        MigrationRepo,
        "SELECT content.fail_document_extraction($1,$1,1,'unsupported','no_extractable_text')",
        [document.resource_version_id]
      )

      assert %{rows: [["unsupported", "no_extractable_text", digest, size, object, pin]]} =
               query!(
                 MigrationRepo,
                 "SELECT state,failure_code,source_digest,source_byte_size,source_object_id,source_resource_version_id FROM content.document_versions WHERE resource_version_id=$1",
                 [document.resource_version_id]
               )

      assert digest == source.digest
      assert size == source.byte_size
      assert object == source.object_id
      assert pin == source.resource_version_id
    end)

    # Legitimate terminal metadata, not authenticated-empty-original proof.
    sealed = capture!(c)
    [version] = records(sealed, :versions)
    assert version["version_id"] == text(document.resource_version_id)
    assert version["resource_id"] == text(document.resource_id)
    assert version["availability"] == "included"
    assert version["state"] == "unsupported"
    assert version["extraction_adapter"] == "plain_text"
    assert version["extraction_format"] == 1
    assert version["original_digest"] == Base.encode16(c.source.digest, case: :lower)
    assert version["original_byte_size"] == c.source.byte_size

    assert version["original_path"] ==
             "documents/originals/#{text(document.resource_id)}--#{text(document.resource_version_id)}.txt"

    for field <- ~w(body_path body_digest extracted_path extracted_digest),
        do: assert(is_nil(version[field]))

    assert records(sealed, :fragments) == []
    assert sealed.text_refs == %{}
    assert :ok = apply(@spool, :abort, [sealed])
  end

  test "existing SQL completion rejects zero fragments and zero aggregate bytes before ready", %{
    fixture: c
  } do
    source = binary_source(c.source)

    for shape <- [:zero_fragments, :zero_bytes] do
      document = document!(source, "Rejected zero ready", nil)

      payload =
        if shape == :zero_fragments do
          []
        else
          [
            %{
              "id" => independent_fragment_id(document.resource_version_id, 0, ""),
              "ordinal" => 0,
              "text" => "",
              "digest" => sha(""),
              "locator" => locator(0)
            }
          ]
        end

      error =
        assert_raise Postgrex.Error, fn ->
          Fixtures.with_owner(fn ->
            set_document_owner!(MigrationRepo, source)
            claim_document!(MigrationRepo, document)
            send(self(), {:zero_ready_input_claimed, shape})

            query!(
              MigrationRepo,
              "SELECT content.complete_document_extraction($1,$1,1,$2,$3,'en')",
              [document.resource_version_id, payload, :crypto.hash(:sha256, "")]
            )
          end)
        end

      assert_receive {:zero_ready_input_claimed, ^shape}
      assert error.postgres.code == :check_violation
      assert error.postgres.constraint == "document_extraction_input_check"
      assert_document_pending!(document)
    end
  end

  test "real owner-role precommit ready-zero state is denied by authenticated Repository capture",
       %{
         fixture: c
       } do
    source = binary_source(c.source)
    document = document!(source, "Malformed precommit ready", nil)
    spool = open(c)
    sentinel = Path.join(c.context.root, "ready-zero-neighbor")
    File.write!(sentinel, "safe")

    result =
      precommit_scope(c, PrecommitOwnerScope, 3, fn c, repo ->
        claim_document!(repo, document)
        mark_ready_zero!(repo, document)
        assert_ready_zero!(repo, document)

        assert %{rows: [["repeatable read", "singularity_table_owner", principal, owner]]} =
                 query!(
                   repo,
                   "SELECT current_setting('transaction_isolation'),current_user,current_setting('singularity.principal_id'),current_setting('singularity.vault_id')"
                 )

        assert principal == c.session.principal_id
        assert owner == c.session.vault_id
        assert PrecommitIdentity.backend_binding(repo) == c.precommit_binding
        authorize = authorization(c, repo)
        assert {:ok, session} = authorize.(repo)
        assert session == c.session
        send(self(), :ready_zero_precommit_witness)
        call(:capture, [repo, authorize, %{}, spool])
      end)

    # Callback denial rolls this owner-role probe back; it is deliberately not
    # the separate deferred-COMMIT proof or a committed Runtime corruption fixture.
    assert_receive :ready_zero_precommit_witness
    assert {:error, %Error{code: :integrity_failure}} = result
    refute File.exists?(Path.join(c.context.root, spool.capture_id))
    assert File.read!(sentinel) == "safe"
    assert_error(apply(@spool, :seal, [spool]))
    assert :ok = apply(@spool, :abort, [spool])
    assert_document_pending!(document)
  end

  test "existing deferred completion constraint rejects ready-zero at the actual COMMIT boundary",
       %{
         fixture: c
       } do
    source = binary_source(c.source)
    document = document!(source, "Rejected deferred ready", nil)
    {:ok, connection} = Postgrex.start_link(MigrationRepo.config())
    test_process = self()
    callback_witness = make_ref()

    try do
      error =
        assert_raise Postgrex.Error, fn ->
          Postgrex.transaction(connection, fn tx ->
            Postgrex.query!(tx, "SET LOCAL ROLE singularity_table_owner", [])

            Postgrex.query!(
              tx,
              "SELECT set_config('singularity.principal_id',$1,true),set_config('singularity.vault_id',$2,true)",
              [text(source.principal_id), text(source.vault_id)]
            )

            Postgrex.query!(
              tx,
              "SELECT content.claim_document_extraction($1,0,$1,'plain_text',1)",
              [document.resource_version_id]
            )

            assert %{num_rows: 1} =
                     Postgrex.query!(
                       tx,
                       "UPDATE content.document_versions SET state='ready',extracted_text_digest=$2,attempt_finished_at=CURRENT_TIMESTAMP WHERE resource_version_id=$1",
                       [document.resource_version_id, :crypto.hash(:sha256, "")]
                     )

            assert %{rows: [["ready", digest, 0, 0]]} =
                     Postgrex.query!(tx, ready_zero_statement(), [document.resource_version_id])

            assert digest == :crypto.hash(:sha256, "")

            # Normal callback return reaches the driver's actual COMMIT; no
            # export module, callback rollback or immediate constraint substitute.
            send(test_process, {callback_witness, :ready_zero_callback_completed})
            :ready_zero_callback_completed
          end)
        end

      assert_receive {^callback_witness, :ready_zero_callback_completed}

      assert %{
               code: :check_violation,
               constraint: "document_versions_completion_check"
             } = error.postgres

      assert {:ok, :pending_after_failed_commit} =
               Postgrex.transaction(connection, fn tx ->
                 Postgrex.query!(tx, "SET LOCAL ROLE singularity_table_owner", [])

                 assert %{rows: [["pending", nil]]} =
                          Postgrex.query!(
                            tx,
                            "SELECT state,extracted_text_digest FROM content.document_versions WHERE resource_version_id=$1",
                            [document.resource_version_id]
                          )

                 :pending_after_failed_commit
               end)
    after
      if Process.alive?(connection), do: GenServer.stop(connection)
    end

    assert_document_pending!(document)
  end

  for corruption <- [:unsupported_format, :missing_envelope] do
    @corruption corruption
    test "live #{@corruption} original binding aborts without reserved unavailable downgrade", %{
      fixture: c
    } do
      graph!(c)

      Fixtures.with_owner(fn ->
        case @corruption do
          :unsupported_format ->
            query!(
              MigrationRepo,
              "UPDATE content.asset_objects SET format_version=99 WHERE id=$1",
              [dump(c.source.object_id)]
            )

          :missing_envelope ->
            query!(
              MigrationRepo,
              "DELETE FROM content.asset_key_envelopes WHERE asset_object_id=$1",
              [dump(c.source.object_id)]
            )
        end
      end)

      spool = open(c)
      assert {:error, %Error{}} = apply(@snapshot, :capture, [c.runtime, c.session, %{}, spool])
      refute File.exists?(Path.join(c.context.root, spool.capture_id))
    end
  end

  test "a real second owner cannot select first-owner content and pages expose no SQL handles", %{
    fixture: c,
    tmp_dir: tmp_dir
  } do
    graph = graph!(c)
    directory = Path.join(tmp_dir, "other-owner")
    File.mkdir!(directory)
    other = apply(LiveFixture, :live_fixture!, [directory])
    sealed = capture!(other)
    for collection <- @collections, do: assert(records(sealed, collection) == [])
    refute Map.has_key?(sealed, :repo)
    refute escaped_sql?(sealed)
    refute inspect(sealed, limit: :infinity) =~ text(graph.head.resource_id)
    assert :ok = apply(@spool, :abort, [sealed])
  end

  test "sealed metadata cursor refuses channel capture mutation and stays unchanged after live SQL changes",
       %{fixture: c} do
    graph = graph!(c)
    sealed = capture!(c)
    expected = records(sealed, :resources)

    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "UPDATE content.resources SET title='After capture' WHERE id=$1", [
        graph.head.resource_id
      ])

      query!(
        MigrationRepo,
        "UPDATE content.tags SET display_value='After',normalized_key='after' WHERE id=$1",
        [graph.tag]
      )
    end)

    assert records(sealed, :resources) == expected

    assert records(sealed, :tags) == [
             %{
               "id" => text(graph.tag),
               "display_value" => "Source 界",
               "normalized_key" => "source 界"
             }
           ]

    for bad <- [
          cursor(sealed, :note_markdown),
          cursor(sealed, :files),
          %{cursor(sealed, :resources) | capture_id: Ecto.UUID.generate()},
          Map.put(cursor(sealed, :resources), :repo, RequestRepo),
          :erlang.term_to_binary(cursor(sealed, :resources))
        ] do
      assert_error(call(:next_page, [sealed, bad, 500]))
    end

    for collection <- @collections do
      for record <- records(sealed, collection) do
        for private <-
              ~w(vault_id owner_scope_id principal_id session_id storage_ref object_id text_ref render_ref),
            do: refute(Map.has_key?(record, private))
      end
    end

    assert :ok = apply(@spool, :abort, [sealed])
  end

  test "barrier changing heads tags and pending extraction after RR cut cannot change capture", %{
    fixture: c
  } do
    graph = graph!(c)
    spool = open(c)
    barrier = make_ref()

    dependency = %{
      c.runtime.authorization
      | store: {LiveFixture.ObservedIdentity, %{parent: self(), barrier: barrier}}
    }

    runtime = %{c.runtime | authorization: dependency}
    task = Task.async(fn -> apply(@snapshot, :capture, [runtime, c.session, %{}, spool]) end)
    assert_receive {:sql_snapshot_cut, pid, ^barrier}, 5_000
    advance_note!(c, graph.head)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.tags SET display_value='AFTER_CUT_TAG',normalized_key='after_cut_tag' WHERE id=$1",
        [graph.tag]
      )
    end)

    complete_document!(binary_source(c.source), graph.pending, ["AFTER_CUT_FRAGMENT"])
    send(pid, {:continue_snapshot, barrier})
    assert {:ok, sealed} = Task.await(task, 5_000)
    head = Enum.find(records(sealed, :resources), &(&1["id"] == text(graph.head.resource_id)))
    assert head["current_version_id"] == text(graph.head.resource_version_id)

    assert captured_text(
             sealed,
             {:note_markdown, text(graph.head.resource_id), text(graph.head.resource_version_id)}
           ) == "HEAD_CANONICAL"

    assert records(sealed, :tags) == [
             %{
               "id" => text(graph.tag),
               "display_value" => "Source 界",
               "normalized_key" => "source 界"
             }
           ]

    pending =
      Enum.find(
        records(sealed, :versions),
        &(&1["version_id"] == text(graph.pending.resource_version_id))
      )

    assert pending["state"] == "pending"
    assert is_nil(pending["extracted_path"])

    assert Enum.filter(
             records(sealed, :fragments),
             &(&1["version_id"] == text(graph.pending.resource_version_id))
           ) == []

    assert :ok = apply(@spool, :abort, [sealed])
  end

  test "concrete spool observes bounded writes metadata pages and retained indexes", %{fixture: c} do
    graph = graph!(c)
    armed = :atomics.new(1, [])
    parent = self()

    writer = fn device, bytes ->
      assert byte_size(bytes) <= 65_536
      if :atomics.get(armed, 1) == 1, do: send(parent, {:bounded_spool_write, byte_size(bytes)})
      IO.binwrite(device, bytes)
    end

    spool = open(%{c | context: Map.put(c.context, :write, writer)})
    :atomics.put(armed, 1, 1)
    assert {:ok, sealed} = apply(@snapshot, :capture, [c.runtime, c.session, %{}, spool])
    assert_receive {:bounded_spool_write, size}
    assert size <= 65_536
    assert sealed.accounting.spool_bytes <= 1_073_741_824
    assert sealed.accounting.metadata_records <= 1_000_000
    assert sealed.accounting.selected_keys <= 100_000
    # References/indexes cannot retain the selected corpus. SQL query shape is
    # separately source-reviewed; this is deterministic retained-state evidence.
    refute inspect(sealed, limit: :infinity, printable_limit: :infinity) =~ graph.old.markdown
    assert :erts_debug.flat_size(sealed) < 100_000
    for collection <- @collections, do: records(sealed, collection)
    assert :ok = apply(@spool, :abort, [sealed])
  end

  test "synthetic append ENOSPC propagates through real SQL capture and cleans without descriptor",
       %{fixture: c} do
    graph!(c)
    armed = :atomics.new(1, [])

    write = fn device, bytes ->
      if :atomics.get(armed, 1) == 1, do: {:error, :enospc}, else: IO.binwrite(device, bytes)
    end

    spool = open(%{c | context: Map.put(c.context, :write, write)})
    :atomics.put(armed, 1, 1)
    sentinel = Path.join(c.context.root, "neighbor")
    File.write!(sentinel, "safe")
    assert {:error, %Error{}} = apply(@snapshot, :capture, [c.runtime, c.session, %{}, spool])
    refute File.exists?(Path.join(c.context.root, spool.capture_id))
    assert File.read!(sentinel) == "safe"
  end

  defp graph!(c) do
    source = binary_source(c.source)
    document_old = document!(source, "Pinned old Document", ["界\n", "🙂"])
    document_head = next_document!(source, document_old, "New Document title", ["NEW_TEXT"])
    pending = document!(source, "Pending", nil)
    deleted_document = document!(source, "Deleted Document", ["HIDDEN_DELETED_FRAGMENT"])
    endpoint = clone_asset!(source, "Metadata endpoint")
    unrelated = clone_asset!(source, "Unrelated endpoint")

    old =
      note_identity(
        source,
        ordered_resource(source, 1),
        0,
        "Original Note title",
        "PROMOTED_OLD_CANONICAL_界"
      )

    merge = note_identity(source, old.resource_id, 1, "Merge ancestry", "HIDDEN_MERGE_BODY")
    head = note_identity(source, old.resource_id, 2, "CURRENT_NOTE_TITLE", "HEAD_CANONICAL")
    conflict = note_identity(source, old.resource_id, 3, "Conflict", "HIDDEN_CONFLICT_BODY")
    peer = note_identity(source, ordered_resource(source, 2), 0, "Peer", "PEER_CANONICAL")
    deleted_note = note_identity(source, nil, 0, "Deleted Note", "HIDDEN_DELETED_NOTE")
    tombstone = note_identity(source, nil, 0, "Optional tombstone", "HIDDEN_TOMBSTONE_BODY")
    tag = KnowledgeFixtures.uuid()
    edge = KnowledgeFixtures.uuid()
    beyond_edge = KnowledgeFixtures.uuid()
    old_fragments = document_old.fragments
    head_fragments = document_head.fragments
    deleted_fragments = deleted_document.fragments

    {attachments, citations} =
      Fixtures.with_owner(fn ->
        insert_note!(source, old, nil, nil, false)
        insert_note!(source, merge, old, nil, false)
        insert_note!(source, head, old, merge, true)
        insert_note!(source, conflict, head, nil, false)

        for note <- [peer, deleted_note, tombstone],
            do: insert_note!(source, note, nil, nil, true)

        attachments = [
          attachment!(source, old, peer, :note, 0),
          attachment!(source, old, source, :asset, 1),
          attachment!(source, peer, old, :note, 0),
          attachment!(source, peer, document_old, :document, 1),
          attachment!(source, peer, document_head, :document, 2),
          attachment!(source, peer, deleted_note, :note, 3)
        ]

        # These memberships must not traverse from ancestry or optional tombstone.
        attachment!(source, merge, endpoint, :asset, 0)
        attachment!(source, tombstone, unrelated, :asset, 0)

        citations = [
          citation!(source, peer, document_old, hd(old_fragments), 0),
          citation!(source, peer, deleted_document, hd(deleted_fragments), 1)
        ]

        query!(
          MigrationRepo,
          "INSERT INTO content.tags(id,vault_id,classification,display_value,normalized_key,created_by_principal_id,inserted_at) VALUES($1,$2,'private','Source 界','source 界',$3,$4)",
          [tag, source.vault_id, source.principal_id, datetime(@time)]
        )

        query!(
          MigrationRepo,
          "INSERT INTO content.resource_tags(resource_id,tag_id,vault_id,classification,inserted_at) VALUES($1,$2,$3,'private',$4)",
          [head.resource_id, tag, source.vault_id, datetime(@time)]
        )

        edge!(source, edge, head, endpoint)
        edge!(source, beyond_edge, endpoint, unrelated)
        {attachments, citations}
      end)

    Fixtures.with_owner(fn ->
      for row <- [deleted_note, deleted_document, tombstone] do
        query!(MigrationRepo, "UPDATE content.resources SET deleted_at=$2 WHERE id=$1", [
          row.resource_id,
          datetime(@deleted)
        ])
      end
    end)

    %{
      old: old,
      merge: merge,
      head: head,
      conflict: conflict,
      peer: peer,
      deleted_note: deleted_note,
      tombstone: tombstone,
      document_old: document_old,
      document_head: document_head,
      pending: pending,
      deleted_document: deleted_document,
      old_fragments: old_fragments,
      head_fragments: head_fragments,
      deleted_fragments: deleted_fragments,
      endpoint: endpoint,
      unrelated: unrelated,
      tag: tag,
      edge: edge,
      expected_attachments: attachments,
      expected_citations: citations
    }
  end

  defp note_identity(source, resource, revision, title, markdown),
    do: %{
      resource_id: resource || KnowledgeFixtures.uuid(),
      resource_version_id: KnowledgeFixtures.uuid(),
      vault_id: source.vault_id,
      revision: revision,
      title: title,
      markdown: markdown
    }

  defp insert_note!(source, row, parent, merge, head?) do
    query!(
      MigrationRepo,
      "INSERT INTO content.resources(id,vault_id,classification,kind,current_version_id,title) VALUES($1,$2,'private','note',$3,$4) ON CONFLICT(id) DO NOTHING",
      [row.resource_id, row.vault_id, row.resource_version_id, row.title]
    )

    query!(
      MigrationRepo,
      "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision,inserted_at) VALUES($1,$2,$3,'private',$4,$5)",
      [row.resource_version_id, row.resource_id, row.vault_id, row.revision, datetime(@time)]
    )

    query!(
      MigrationRepo,
      "INSERT INTO content.note_versions(resource_version_id,resource_id,vault_id,classification,title,markdown,created_by_principal_id,parent_version_id,merge_parent_version_id,inserted_at) VALUES($1,$2,$3,'private',$4,$5,$6,$7,$8,$9)",
      [
        row.resource_version_id,
        row.resource_id,
        row.vault_id,
        row.title,
        row.markdown,
        source.principal_id,
        parent && parent.resource_version_id,
        merge && merge.resource_version_id,
        datetime(@time)
      ]
    )

    if head?,
      do:
        query!(
          MigrationRepo,
          "UPDATE content.resources SET current_version_id=$1,title=$2 WHERE id=$3",
          [row.resource_version_id, row.title, row.resource_id]
        )

    row
  end

  defp document!(source, title, texts) do
    row = %{
      resource_id: KnowledgeFixtures.uuid(),
      resource_version_id: KnowledgeFixtures.uuid(),
      vault_id: source.vault_id,
      classification: "private",
      source_asset_id: source.asset_id,
      source_resource_id: source.resource_id,
      source_resource_version_id: source.resource_version_id,
      source_object_id: source.object_id,
      source_digest: source.digest,
      source_byte_size: source.byte_size,
      media_type: "text/plain",
      title: title,
      created_by_principal_id: source.principal_id
    }

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.resources(id,vault_id,classification,kind,current_version_id,title) VALUES($1,$2,'private','document',$3,$4)",
        [row.resource_id, source.vault_id, row.resource_version_id, title]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision,inserted_at) VALUES($1,$2,$3,'private',0,$4)",
        [row.resource_version_id, row.resource_id, source.vault_id, datetime(@time)]
      )

      KnowledgeFixtures.insert_typed!(row)
    end)

    fragments = if is_nil(texts), do: [], else: complete_document!(source, row, texts)
    Map.put(row, :fragments, fragments)
  end

  defp next_document!(source, old, title, texts) do
    row = %{old | resource_version_id: KnowledgeFixtures.uuid(), title: title}

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision,inserted_at) VALUES($1,$2,$3,'private',1,$4)",
        [row.resource_version_id, row.resource_id, source.vault_id, datetime(@time)]
      )

      KnowledgeFixtures.insert_typed!(row)

      query!(
        MigrationRepo,
        "UPDATE content.resources SET current_version_id=$1,title=$2 WHERE id=$3",
        [row.resource_version_id, title, row.resource_id]
      )
    end)

    %{row | fragments: complete_document!(source, row, texts)}
  end

  defp complete_document!(source, row, texts) do
    fragments =
      Enum.with_index(texts)
      |> Enum.map(fn {body, ordinal} ->
        {:ok, fragment} =
          DocumentFragment.new(%{
            resource_id: text(row.resource_id),
            resource_version_id: text(row.resource_version_id),
            owner_scope_id: text(source.vault_id),
            classification: :private,
            ordinal: ordinal,
            text: body,
            locator: locator(ordinal)
          })

        assert fragment.fragment_id ==
                 independent_fragment_id(row.resource_version_id, ordinal, body)

        fragment
      end)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "SELECT set_config('singularity.principal_id',$1,true),set_config('singularity.vault_id',$2,true)",
        [text(source.principal_id), text(source.vault_id)]
      )

      query!(MigrationRepo, "SELECT content.claim_document_extraction($1,0,$1,'plain_text',1)", [
        row.resource_version_id
      ])

      payload =
        Enum.map(
          fragments,
          &%{
            "id" => &1.fragment_id,
            "ordinal" => &1.ordinal,
            "text" => &1.text,
            "digest" => Base.encode16(&1.digest, case: :lower),
            "locator" => SourceLocator.to_map(&1.locator)
          }
        )

      query!(MigrationRepo, "SELECT content.complete_document_extraction($1,$1,1,$2,$3,'en')", [
        row.resource_version_id,
        payload,
        :crypto.hash(:sha256, Enum.join(texts, ""))
      ])
    end)

    fragments
  end

  defp set_document_owner!(repo, source),
    do:
      query!(
        repo,
        "SELECT set_config('singularity.principal_id',$1,true),set_config('singularity.vault_id',$2,true)",
        [text(source.principal_id), text(source.vault_id)]
      )

  defp claim_document!(repo, document),
    do:
      query!(repo, "SELECT content.claim_document_extraction($1,0,$1,'plain_text',1)", [
        document.resource_version_id
      ])

  defp mark_ready_zero!(repo, document) do
    assert %{num_rows: 1} =
             query!(
               repo,
               "UPDATE content.document_versions SET state='ready',extracted_text_digest=$2,attempt_finished_at=CURRENT_TIMESTAMP WHERE resource_version_id=$1",
               [document.resource_version_id, :crypto.hash(:sha256, "")]
             )
  end

  defp ready_zero_statement,
    do:
      "SELECT d.state,d.extracted_text_digest,(SELECT count(*) FROM content.document_fragments f WHERE f.resource_version_id=d.resource_version_id),(SELECT coalesce(sum(octet_length(f.text)),0) FROM content.document_fragments f WHERE f.resource_version_id=d.resource_version_id) FROM content.document_versions d WHERE d.resource_version_id=$1"

  defp assert_ready_zero!(repo, document) do
    assert %{rows: [["ready", digest, 0, 0]]} =
             query!(repo, ready_zero_statement(), [document.resource_version_id])

    assert digest == :crypto.hash(:sha256, "")
  end

  defp assert_document_pending!(document) do
    Fixtures.with_owner(fn ->
      assert %{rows: [["pending", 0, nil, 0]]} =
               query!(
                 MigrationRepo,
                 "SELECT d.state,d.attempt_generation,d.extracted_text_digest,(SELECT count(*) FROM content.document_fragments f WHERE f.resource_version_id=d.resource_version_id) FROM content.document_versions d WHERE d.resource_version_id=$1",
                 [document.resource_version_id]
               )
    end)
  end

  defp clone_asset!(source, title),
    do: Fixtures.with_owner(fn -> insert_clone_asset!(source, title) end)

  defp insert_clone_asset!(source, title) do
    row = %{
      source
      | resource_id: KnowledgeFixtures.uuid(),
        resource_version_id: KnowledgeFixtures.uuid(),
        asset_id: KnowledgeFixtures.uuid()
    }

    query!(
      MigrationRepo,
      "INSERT INTO content.resources(id,vault_id,classification,kind,title) VALUES($1,$2,'private','asset',$3)",
      [row.resource_id, row.vault_id, title]
    )

    query!(
      MigrationRepo,
      "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision,inserted_at) VALUES($1,$2,$3,'private',0,$4)",
      [row.resource_version_id, row.resource_id, row.vault_id, datetime(@time)]
    )

    query!(
      MigrationRepo,
      "INSERT INTO content.assets(id,vault_id,resource_version_id,classification,state,asset_object_id) VALUES($1,$2,$3,'private','available',$4)",
      [row.asset_id, row.vault_id, row.resource_version_id, row.object_id]
    )

    query!(
      MigrationRepo,
      "INSERT INTO content.resource_assets(resource_version_id,asset_id,vault_id,classification) VALUES($1,$2,$3,'private')",
      [row.resource_version_id, row.asset_id, row.vault_id]
    )

    query!(
      MigrationRepo,
      "INSERT INTO content.asset_metadata(id,asset_id,resource_version_id,vault_id,classification,projection_version,original_filename,declared_media_type,detected_media_type,plaintext_byte_size,extraction_state,completed_at) VALUES($1,$2,$3,$4,'private',1,$5,'text/plain','text/plain',12,'completed',CURRENT_TIMESTAMP)",
      [KnowledgeFixtures.uuid(), row.asset_id, row.resource_version_id, row.vault_id, title]
    )

    row
  end

  defp attachment!(source, note, target, kind, ordinal) do
    id = KnowledgeFixtures.uuid()

    query!(
      MigrationRepo,
      "INSERT INTO content.note_attachments(note_resource_version_id,id,note_resource_id,vault_id,classification,target_resource_id,target_resource_version_id,target_kind,ordinal,role,label,inserted_at) VALUES($1,$2,$3,$4,'private',$5,$6,$7,$8,'source',NULL,$9)",
      [
        note.resource_version_id,
        id,
        note.resource_id,
        source.vault_id,
        target.resource_id,
        target.resource_version_id,
        Atom.to_string(kind),
        ordinal,
        datetime(@time)
      ]
    )

    %{
      "note_resource_id" => text(note.resource_id),
      "note_version_id" => text(note.resource_version_id),
      "id" => text(id),
      "ordinal" => ordinal,
      "target_resource_id" => text(target.resource_id),
      "target_version_id" => text(target.resource_version_id),
      "target_kind" => Atom.to_string(kind),
      "role" => "source",
      "label" => nil
    }
  end

  defp citation!(source, note, target, fragment, ordinal) do
    id = KnowledgeFixtures.uuid()
    loc = SourceLocator.to_map(fragment.locator)

    query!(
      MigrationRepo,
      "INSERT INTO content.note_citations(note_resource_version_id,id,note_resource_id,vault_id,classification,source_resource_id,source_resource_version_id,fragment_id,locator,ordinal,inserted_at) VALUES($1,$2,$3,$4,'private',$5,$6,$7,$8,$9,$10)",
      [
        note.resource_version_id,
        id,
        note.resource_id,
        source.vault_id,
        target.resource_id,
        target.resource_version_id,
        fragment.fragment_id,
        loc,
        ordinal,
        datetime(@time)
      ]
    )

    %{
      "note_resource_id" => text(note.resource_id),
      "note_version_id" => text(note.resource_version_id),
      "id" => text(id),
      "ordinal" => ordinal,
      "source_resource_id" => text(target.resource_id),
      "source_version_id" => text(target.resource_version_id),
      "fragment_id" => fragment.fragment_id,
      "locator" => loc
    }
  end

  defp edge!(source, id, from, to),
    do:
      query!(
        MigrationRepo,
        "INSERT INTO content.relationships(id,vault_id,classification,source_resource_id,target_resource_id,target_resource_version_id,type,created_by_principal_id,inserted_at) VALUES($1,$2,'private',$3,$4,$5,'references',$6,$7)",
        [
          id,
          source.vault_id,
          from.resource_id,
          to.resource_id,
          to.resource_version_id,
          source.principal_id,
          datetime(@time)
        ]
      )

  defp advance_note!(c, head) do
    source = binary_source(c.source)
    row = note_identity(source, head.resource_id, 4, "AFTER_CUT_TITLE", "AFTER_CUT_BODY")
    Fixtures.with_owner(fn -> insert_note!(source, row, head, nil, true) end)
  end

  defp assert_note_version(sealed, row, availability, parent, merge) do
    actual =
      Enum.find(records(sealed, :versions), &(&1["version_id"] == text(row.resource_version_id)))

    expected =
      ~w(resource_id version_id revision kind inserted_at availability body_path original_path extracted_path body_digest original_digest original_byte_size extracted_digest media_type state extraction_adapter extraction_format parent_version_id merge_parent_version_id)
      |> Map.new(&{&1, nil})
      |> Map.merge(%{
        "resource_id" => text(row.resource_id),
        "version_id" => text(row.resource_version_id),
        "revision" => row.revision,
        "kind" => "note",
        "inserted_at" => @time,
        "availability" => availability,
        "parent_version_id" => parent && text(parent.resource_version_id),
        "merge_parent_version_id" => merge && text(merge.resource_version_id)
      })

    expected =
      if availability == "included",
        do:
          Map.merge(
            expected,
            %{
              "body_path" =>
                "notes/#{text(row.resource_id)}--#{text(row.resource_version_id)}.md",
              "body_digest" => sha(row.markdown)
            }
          ),
        else: expected

    assert actual == expected
  end

  defp precommit_scope(c, scope, native_calls, callback) do
    {:ok, owner_repo} = MigrationRepo.start_link(pool_size: 2)

    try do
      MigrationRepo.checkout(fn ->
        assert %{rows: [[backend, "singularity_migration", "singularity_migration"]]} =
                 query!(MigrationRepo, "SELECT pg_backend_pid(),current_user,session_user")

        token = make_ref()
        assert {LiveFixture.ObservedIdentity, _delegate_context} = c.runtime.authorization.store

        observer = %{
          caller: self(),
          backend: backend,
          token: token,
          principal: c.session.principal_id,
          owner: c.session.vault_id,
          delegate: c.runtime.authorization.store
        }

        authorization = %{c.runtime.authorization | store: {PrecommitIdentity, observer}}
        c = %{c | runtime: %{c.runtime | authorization: authorization}}
        runtime = %{c.runtime | request_repo: MigrationRepo, scoped_repo: scope}

        result =
          OperationScope.with_shared_request(
            runtime,
            c.session,
            requirement(c.session),
            fn repo ->
              content_binding = PrecommitIdentity.backend_binding(repo)
              send(self(), {:precommit_content_binding, token, content_binding})
              callback.(Map.put(c, :precommit_binding, content_binding), repo)
            end
          )

        # These assertions are outside Authorize's rescue and still inside the
        # original checkout, including native failures and post-rollback cleanup.
        refute_receive {:precommit_native_failure, ^token}

        bindings =
          for _ <- 1..native_calls do
            assert_receive {:precommit_native_identity, ^token, caller, MigrationRepo, before,
                            during, restored, {:returned, {:ok, live}}}

            assert caller == self()
            assert before.backend == backend
            assert before.role == "singularity_table_owner"
            assert before.session_user == "singularity_migration"
            assert before.isolation == "repeatable read"
            assert before.read_only == "off"
            assert before.principal == c.session.principal_id
            assert before.owner == c.session.vault_id
            assert during == %{before | role: "singularity_authorization_definer"}
            assert restored == before
            assert live.session_id == c.session.session_id
            assert live.principal_id == c.session.principal_id
            assert live.vault_id == c.session.vault_id
            assert live.principal_authorization_epoch == c.session.principal_authorization_epoch
            assert live.vault_authorization_epoch == c.session.vault_authorization_epoch
            assert live.principal_revoked_at == nil
            assert live.membership_revoked_at == nil
            assert live.session_revoked_at == nil
            assert live.vault_locked == false
            assert "asset.read" in live.capabilities
            assert "note.read" in live.capabilities
            before
          end

        assert [binding] = Enum.uniq(bindings)
        assert_receive {:precommit_content_binding, ^token, ^binding}
        refute_receive {:precommit_native_identity, ^token, _, _, _, _, _, _}
        refute MigrationRepo.in_transaction?()

        assert %{
                 rows: [
                   [
                     ^backend,
                     "singularity_migration",
                     "singularity_migration",
                     principal,
                     owner,
                     nil,
                     0
                   ]
                 ]
               } =
                 query!(
                   MigrationRepo,
                   "SELECT pg_backend_pid(),current_user,session_user,current_setting('singularity.principal_id',true),current_setting('singularity.vault_id',true),pg_current_xact_id_if_assigned()::text,(SELECT count(*) FROM pg_catalog.pg_locks WHERE pid=pg_backend_pid() AND locktype='advisory' AND granted)"
                 )

        assert principal in [nil, ""]
        assert owner in [nil, ""]
        result
      end)
    after
      Supervisor.stop(owner_repo)
    end
  end

  defp with_membership_call_witness(callback) do
    mfa = {KnowledgeLinkRepository, :read_membership, 3}
    assert {:module, KnowledgeLinkRepository} = Code.ensure_loaded(KnowledgeLinkRepository)
    original_flags = :erlang.trace_info(self(), :flags)
    original_tracer = :erlang.trace_info(self(), :tracer)
    original_pattern = :erlang.trace_info(mfa, :traced)
    original_match = :erlang.trace_info(mfa, :match_spec)
    assert original_flags == {:flags, []}
    assert original_tracer == {:tracer, []}
    assert original_pattern == {:traced, false}
    assert original_match == {:match_spec, false}
    caller = self()
    token = make_ref()
    tracer = spawn_link(fn -> membership_trace_loop(caller, token, 0) end)

    try do
      assert 1 = :erlang.trace_pattern(mfa, true, [:local])
      assert 1 = :erlang.trace(caller, true, [:call, :arity, {:tracer, tracer}])

      try do
        callback.()
      after
        # Only this PID and this single MFA are traced, with arity instead of
        # argument or return data. Restore before the bounded delivery barrier.
        :erlang.trace(caller, false, [:call, :arity])
        :erlang.trace_pattern(mfa, false, [:local])
        delivered = :erlang.trace_delivered(caller)
        assert_receive {:trace_delivered, ^caller, ^delivered}, 1_000
        send(tracer, {:finish_membership_trace, token})
        assert_receive {:membership_capture_calls, ^token, calls}, 1_000
        assert calls == 1
      end
    after
      :erlang.trace(caller, false, [:call, :arity])
      :erlang.trace_pattern(mfa, false, [:local])
      Process.unlink(tracer)
      if Process.alive?(tracer), do: Process.exit(tracer, :kill)
      assert :erlang.trace_info(caller, :flags) == original_flags
      assert :erlang.trace_info(caller, :tracer) == original_tracer
      assert :erlang.trace_info(mfa, :traced) == original_pattern
      assert :erlang.trace_info(mfa, :match_spec) == original_match
    end
  end

  defp membership_trace_loop(caller, token, calls) do
    receive do
      {:trace, ^caller, :call, {KnowledgeLinkRepository, :read_membership, 3}} ->
        membership_trace_loop(caller, token, calls + 1)

      {:finish_membership_trace, ^token} ->
        send(caller, {:membership_capture_calls, token, calls})
    end
  end

  defp with_scope(c, repeatable?, callback) do
    runtime =
      if repeatable?, do: %{c.runtime | scoped_repo: {@snapshot, ScopedRepo}}, else: c.runtime

    OperationScope.with_shared_request(runtime, c.session, requirement(c.session), callback)
  end

  defp authorization(c, repo) do
    caller = self()

    fn supplied_repo ->
      if self() == caller and supplied_repo == repo do
        case Authorize.check(c.runtime.authorization, repo, c.session, requirement(c.session)) do
          :ok -> {:ok, c.session}
          failure -> failure
        end
      else
        {:error, Error.new(:invalid)}
      end
    end
  end

  defp requirement(session),
    do: %{
      vault_id: session.vault_id,
      classification: :private,
      requires_unlocked?: true,
      required_capabilities: ["asset.read", "note.read"],
      principal_authorization_epoch: session.principal_authorization_epoch,
      vault_authorization_epoch: session.vault_authorization_epoch
    }

  defp assert_ordinary_asset_state_capture!(c, state) do
    source = binary_source(c.source)
    note = note_identity(source, nil, 0, "Ordinary Asset pin", "ORDINARY_ASSET_PIN")

    attachment =
      Fixtures.with_owner(fn ->
        assert %{num_rows: 1} =
                 query!(
                   MigrationRepo,
                   "UPDATE content.assets SET state=$2,state_revision=state_revision+1 WHERE id=$1 AND vault_id=$3 AND state='available' AND asset_object_id=$4 AND resource_version_id=$5",
                   [
                     source.asset_id,
                     state,
                     source.vault_id,
                     source.object_id,
                     source.resource_version_id
                   ]
                 )

        if state == "processing" do
          assert %{num_rows: 1} =
                   query!(
                     MigrationRepo,
                     "UPDATE content.asset_metadata SET extraction_state='pending',detected_media_type=NULL,completed_at=NULL WHERE asset_id=$1 AND resource_version_id=$2 AND vault_id=$3 AND extraction_state='completed'",
                     [source.asset_id, source.resource_version_id, source.vault_id]
                   )
        end

        insert_note!(source, note, nil, nil, true)
        attachment!(source, note, source, :asset, 0)
      end)

    metadata_state = if state == "processing", do: "pending", else: "completed"
    media_type = if state == "processing", do: nil, else: "text/plain"
    completed? = state == "ready"

    # Committed owner SQL witnesses the ordinary mutable association and live
    # resource; no Document or retained-source branch can mask this Asset path.
    # The established Asset fixture has no current head: its Note attachment
    # selects the exact immutable source version, independently of that head.
    assert %{
             rows: [
               [
                 resource,
                 version,
                 nil,
                 asset,
                 object,
                 owner,
                 "private",
                 ^state,
                 nil,
                 nil,
                 "available",
                 12,
                 ^metadata_state,
                 ^completed?,
                 ^media_type
               ]
             ]
           } =
             Fixtures.with_owner(fn ->
               query!(
                 MigrationRepo,
                 "SELECT r.id,v.id,r.current_version_id,a.id,a.asset_object_id,a.vault_id,a.classification,a.state,r.deleted_at,ra.released_at,o.lifecycle,o.plaintext_byte_size,m.extraction_state,m.completed_at IS NOT NULL,m.detected_media_type FROM content.resources r JOIN content.resource_versions v ON (v.resource_id,v.vault_id,v.classification)=(r.id,r.vault_id,r.classification) JOIN content.assets a ON (a.resource_version_id,a.vault_id,a.classification)=(v.id,v.vault_id,v.classification) JOIN content.resource_assets ra ON (ra.resource_version_id,ra.asset_id,ra.vault_id,ra.classification)=(v.id,a.id,a.vault_id,a.classification) JOIN content.asset_objects o ON (o.id,o.vault_id,o.classification)=(a.asset_object_id,a.vault_id,a.classification) JOIN content.asset_metadata m ON (m.asset_id,m.resource_version_id,m.vault_id,m.classification)=(a.id,v.id,a.vault_id,a.classification) WHERE r.id=$1 AND r.vault_id=$2 AND r.kind='asset' AND v.id=$3",
                 [source.resource_id, source.vault_id, source.resource_version_id]
               )
             end)

    assert {resource, version, asset, object, owner} ==
             {source.resource_id, source.resource_version_id, source.asset_id, source.object_id,
              source.vault_id}

    original = original_binding_evidence!(c.source)
    assert_envelope_states!(c.source, [[original["domain_key_version_id"], "active", 1, 1]])

    assert {:ok, :ordinary_asset_readers_authorized} =
             with_scope(c, true, fn repo ->
               assert %{rows: [["repeatable read", "off", principal, owner]]} =
                        query!(
                          repo,
                          "SELECT current_setting('transaction_isolation'),current_setting('transaction_read_only'),current_setting('singularity.principal_id'),current_setting('singularity.vault_id')",
                          []
                        )

               assert principal == c.session.principal_id
               assert owner == c.session.vault_id

               assert :ok =
                        Authorize.check(
                          c.runtime.authorization,
                          repo,
                          c.session,
                          requirement(c.session)
                        )

               assert {:ok, object_binding} =
                        Singularity.Storage.Postgres.AssetRepository.authorized_object(
                          repo,
                          c.source.asset_id
                        )

               assert object_binding == %{
                        asset_id: c.source.asset_id,
                        vault_id: c.source.vault_id,
                        classification: :private,
                        object_id: c.source.object_id,
                        object_generation: 1
                      }

               assert {:ok, download} =
                        Singularity.Storage.Postgres.AssetRepository.authorized_download_descriptor(
                          repo,
                          c.source.asset_id
                        )

               assert download == %{
                        asset_id: c.source.asset_id,
                        vault_id: c.source.vault_id,
                        classification: :private,
                        plaintext_byte_size: 12,
                        detected_media_type:
                          if(state == "processing",
                            do: "application/octet-stream",
                            else: "text/plain"
                          )
                      }

               {:ok, :ordinary_asset_readers_authorized}
             end)

    refute RequestRepo.in_transaction?()

    # Genuine metadata selection only, not extraction, decryption or delivery
    # of authenticated original bytes. Asset digest remains a private draft.
    sentinel = Path.join(c.context.root, "ordinary-#{state}-neighbor")
    File.write!(sentinel, "safe")
    spool = open(c)

    try do
      assert {:ok, sealed} =
               apply(@snapshot, :capture, [c.runtime, c.session, %{}, spool])

      refute RequestRepo.in_transaction?()
      assert captured_original_binding(sealed, c.source) == original
      versions = records(sealed, :versions)

      assert Enum.sort(Enum.map(versions, &{&1["kind"], &1["version_id"]})) ==
               Enum.sort([
                 {"asset", c.source.resource_version_id},
                 {"note", text(note.resource_version_id)}
               ])

      draft = Enum.find(versions, &(&1["version_id"] == c.source.resource_version_id))
      assert draft["resource_id"] == c.source.resource_id
      assert draft["kind"] == "asset"
      assert draft["availability"] == "included"
      assert draft["original_byte_size"] == 12
      assert is_nil(draft["original_digest"])

      assert {:error, %Error{code: :invalid}} =
               Singularity.Core.KnowledgeExportManifest.record(:versions, draft)

      assert records(sealed, :attachments) == [attachment]
      assert records(sealed, :citations) == []
      assert records(sealed, :fragments) == []

      assert Map.keys(sealed.binary_refs) ==
               [{:binary_binding, :asset, c.source.resource_id, c.source.resource_version_id}]

      assert :ok = apply(@spool, :abort, [sealed])
    after
      assert :ok = apply(@spool, :abort, [spool])
      refute RequestRepo.in_transaction?()
      refute File.exists?(Path.join(c.context.root, spool.capture_id))
      assert File.read!(sentinel) == "safe"
    end
  end

  defp original_binding_evidence!(source) do
    %{
      rows: [
        [
          domain,
          version,
          generation,
          object_generation,
          lookup,
          ciphertext,
          ciphertext_size,
          storage_ref,
          format,
          size,
          "active",
          "available"
        ]
      ]
    } =
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "SELECT o.key_domain_id,e.domain_key_version_id,d.generation,e.key_generation,o.lookup_digest,o.ciphertext_hash,o.ciphertext_byte_size,o.storage_ref,o.format_version,o.plaintext_byte_size,d.state,o.lifecycle FROM content.asset_objects o JOIN content.asset_key_envelopes e ON e.asset_object_id=o.id AND e.vault_id=o.vault_id AND e.key_domain_id=o.key_domain_id JOIN core.domain_key_versions d ON d.id=e.domain_key_version_id AND d.vault_id=e.vault_id AND d.key_domain_id=e.key_domain_id WHERE o.id=$1 AND o.vault_id=$2",
          [dump(source.object_id), dump(source.vault_id)]
        )
      end)

    assert size == source.byte_size
    assert generation == 1
    assert object_generation == 1

    %{
      "kind" => "asset",
      "resource_id" => source.resource_id,
      "version_id" => source.resource_version_id,
      "asset_id" => source.asset_id,
      "object_id" => source.object_id,
      "owner_scope_id" => source.vault_id,
      "classification" => "private",
      "key_domain_id" => text(domain),
      "domain_key_version_id" => text(version),
      "domain_key_generation" => 1,
      "object_generation" => 1,
      "lookup_digest" => Base.encode16(lookup, case: :lower),
      "ciphertext_hash" => Base.encode16(ciphertext, case: :lower),
      "plaintext_byte_size" => source.byte_size,
      "ciphertext_byte_size" => ciphertext_size,
      "storage_ref" => storage_ref,
      "format_version" => format,
      "plaintext_sha256" => nil
    }
  end

  defp add_active_envelope!(source, old_version) do
    version = Ecto.UUID.generate()

    assert %{num_rows: 1} =
             query!(
               MigrationRepo,
               "INSERT INTO core.domain_key_versions(id,vault_id,key_domain_id,vault_key_version_id,generation,state,algorithm,wrapped_key) SELECT $1,vault_id,key_domain_id,vault_key_version_id,2,'active',algorithm,wrapped_key FROM core.domain_key_versions WHERE id=$2 AND vault_id=$3 AND generation=1",
               [dump(version), dump(old_version), dump(source.vault_id)]
             )

    assert %{num_rows: 1} =
             query!(
               MigrationRepo,
               "INSERT INTO content.asset_key_envelopes(id,vault_id,asset_object_id,domain_key_version_id,key_domain_id,classification,algorithm,key_generation,wrapped_dek) SELECT $1,vault_id,asset_object_id,$2,key_domain_id,classification,algorithm,2,wrapped_dek FROM content.asset_key_envelopes WHERE asset_object_id=$3 AND domain_key_version_id=$4 AND vault_id=$5",
               [
                 KnowledgeFixtures.uuid(),
                 dump(version),
                 dump(source.object_id),
                 dump(old_version),
                 dump(source.vault_id)
               ]
             )

    version
  end

  defp assert_envelope_states!(source, expected) do
    %{rows: rows} =
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "SELECT d.id,d.state,d.generation,e.key_generation FROM core.domain_key_versions d JOIN content.asset_key_envelopes e ON e.domain_key_version_id=d.id AND e.vault_id=d.vault_id AND e.key_domain_id=d.key_domain_id WHERE e.asset_object_id=$1 AND e.vault_id=$2 ORDER BY d.generation,e.id",
          [dump(source.object_id), dump(source.vault_id)]
        )
      end)

    assert Enum.map(rows, fn [id, state, generation, object_generation] ->
             [text(id), state, generation, object_generation]
           end) == expected
  end

  defp captured_original_binding(sealed, source) do
    key = {:binary_binding, :asset, source.resource_id, source.resource_version_id}
    reference = Map.fetch!(sealed.binary_refs, key)
    assert reference.capture_id == sealed.capture_id
    assert reference.selector == key
    {:ok, bytes} = apply(@spool, :read_chunk, [sealed, reference, 0])
    assert byte_size(bytes) == reference.byte_size
    JSON.decode!(bytes)
  end

  defp assert_integrity_capture_cleanup!(c, sentinel) do
    # A genuine live Authorize decision stays successful with the fixture's
    # existing unlocked generation; envelope eligibility is a separate check.
    assert {:ok, :live_authorized} =
             with_scope(c, true, fn repo ->
               assert :ok =
                        Authorize.check(
                          c.runtime.authorization,
                          repo,
                          c.session,
                          requirement(c.session)
                        )

               {:ok, :live_authorized}
             end)

    spool = open(c)

    assert {:error, %Error{code: :integrity_failure}} =
             apply(@snapshot, :capture, [c.runtime, c.session, %{}, spool])

    refute RequestRepo.in_transaction?()
    refute File.exists?(Path.join(c.context.root, spool.capture_id))
    assert_error(apply(@spool, :seal, [spool]))
    assert File.read!(sentinel) == "safe"
  end

  defp capture!(c, options \\ %{}) do
    spool = open(c)
    assert {:ok, sealed} = apply(@snapshot, :capture, [c.runtime, c.session, options, spool])
    refute RequestRepo.in_transaction?()
    sealed
  end

  defp open(c) do
    {:ok, spool} = apply(@spool, :open, [c.context])
    spool
  end

  defp records(sealed, collection), do: records(sealed, cursor(sealed, collection), [])

  defp records(sealed, cursor, acc) do
    {:ok, %{records: page, next_cursor: next}} = call(:next_page, [sealed, cursor, 500])
    assert length(page) <= 500
    if is_nil(next), do: acc ++ page, else: records(sealed, next, acc ++ page)
  end

  defp cursor(sealed, collection),
    do: %{capture_id: sealed.capture_id, collection: collection, after: nil}

  defp captured_text(sealed, key) do
    ref = Map.fetch!(sealed.text_refs, key)
    count = max(1, div(ref.byte_size + 65_535, 65_536))

    Enum.map_join(0..(count - 1), "", fn ordinal ->
      {:ok, bytes} = apply(@spool, :read_chunk, [sealed, ref, ordinal])
      assert byte_size(bytes) <= 65_536
      bytes
    end)
  end

  defp binary_source(source),
    do:
      Map.new(source, fn {key, value} ->
        {key, if(String.ends_with?(Atom.to_string(key), "_id"), do: dump(value), else: value)}
      end)

  defp ordered_resource(source, ordinal),
    do:
      Ecto.UUID.dump!(
        String.slice(text(source.vault_id), 0, 8) <>
          "-0000-4000-8000-" <>
          String.pad_leading(Integer.to_string(ordinal, 16), 12, "0")
      )

  defp text(<<_::binary-size(16)>> = id), do: Ecto.UUID.load!(id)
  defp text(id), do: id
  defp dump(id), do: Ecto.UUID.dump!(id)
  defp datetime(value), do: DateTime.from_iso8601(value) |> elem(1)
  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp extracted(document),
    do:
      "documents/extracted/#{text(document.resource_id)}--#{text(document.resource_version_id)}.txt"

  defp locator(ordinal),
    do: %{
      "version" => 1,
      "kind" => "text",
      "start_line" => ordinal + 1,
      "end_line" => ordinal + 1
    }

  defp independent_fragment_id(version, ordinal, body) do
    # Independent literal v1 frame oracle, not DocumentFragment.id/4.
    loc =
      ["1", "text", Integer.to_string(ordinal + 1), Integer.to_string(ordinal + 1)]
      |> Enum.map(&frame/1)
      |> IO.iodata_to_binary()

    encoded =
      [text(version), loc, Integer.to_string(ordinal), :crypto.hash(:sha256, body)]
      |> Enum.map(&frame/1)

    sha(["singularity:document-fragment:v1", <<0>>, encoded])
  end

  defp frame(bytes), do: <<byte_size(bytes)::unsigned-big-64, bytes::binary>>
  defp escaped_sql?(%Singularity.Storage.SafeSQL.Stream{}), do: true

  defp escaped_sql?(value) when is_map(value),
    do:
      Map.has_key?(value, :sql_cursor) or Map.has_key?(value, :sql_stream) or
        Enum.any?(Map.values(value), &escaped_sql?/1)

  defp escaped_sql?(value) when is_list(value), do: Enum.any?(value, &escaped_sql?/1)
  defp escaped_sql?(_), do: false
  defp assert_error(result), do: assert(match?({:error, %Error{}}, result))

  defp call(function, args) do
    assert Code.ensure_loaded?(@repository), "missing authenticated KnowledgeExport.Repository"
    assert function_exported?(@repository, function, length(args))
    apply(@repository, function, args)
  end
end
