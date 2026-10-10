defmodule Singularity.Runtime.NoteMarkdownExportIntegrationTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.{DocumentFragment, Error, SourceLocator}

  alias Singularity.Runtime.{
    Api,
    AuthorizationDependencies,
    Authorize,
    OperationScope,
    SessionContext
  }

  alias Singularity.Runtime.DTO.{NoteExport, Session}
  alias Singularity.Runtime.Notes.{Create, Export, Save}
  alias Singularity.Runtime.NoteAuthorizationIntegrationTest.Custodian

  alias Singularity.Storage.{
    AuthorizationLock,
    Fixtures,
    KnowledgeFixtures,
    MigrationRepo,
    ScopedRepo,
    VaultLock
  }

  alias Singularity.Storage.Postgres.{
    AuditSink,
    IdentityRepository,
    KnowledgeLinkRepository,
    NoteRepository
  }

  @capabilities ~w(note.write note.read note.export asset.read)
  @canonical_limit 1_048_576
  @rendered_limit 16_777_216

  # This qualifies real PostgreSQL authorization, sealed membership, source
  # metadata and persisted audits under permanent grants. The established
  # integration Custodian supplies only an unlocked lease: no live custody,
  # original-byte delivery, portable package, browser or E2E proof is claimed.
  defmodule ObservedAuthorize do
    import ExUnit.Assertions

    def check(dependencies, repo, session, requirement) do
      assert requirement.vault_id == session.vault_id
      assert requirement.classification == :private
      assert requirement.requires_unlocked?
      assert requirement.principal_authorization_epoch == session.principal_authorization_epoch
      assert requirement.vault_authorization_epoch == session.vault_authorization_epoch
      capability = requirement[:required_capabilities] || requirement[:required_capability]

      Singularity.Runtime.NoteMarkdownExportIntegrationTest.observe(
        repo,
        session.principal_id,
        session.vault_id,
        :authorize,
        capability
      )

      Authorize.check(dependencies, repo, session, requirement)
    end
  end

  defmodule ObservedSources do
    def read_membership(context, note, version) do
      observe(context, :membership, {note, version})
      KnowledgeLinkRepository.read_membership(context, note, version)
    end

    def select_attachment_in_scope(context, note, version, id) do
      observe(context, :select_attachment, id)
      KnowledgeLinkRepository.select_attachment_in_scope(context, note, version, id)
    end

    def select_citation_in_scope(context, note, version, id) do
      observe(context, :select_citation, id)
      KnowledgeLinkRepository.select_citation_in_scope(context, note, version, id)
    end

    def resolve_attachment_in_scope(context, reference) do
      observe(context, :hydrate_attachment, reference.attachment_id)
      KnowledgeLinkRepository.resolve_attachment_in_scope(context, reference)
    end

    def resolve_citation_in_scope(context, reference) do
      observe(context, :hydrate_citation, reference.citation_id)
      KnowledgeLinkRepository.resolve_citation_in_scope(context, reference)
    end

    defp observe(context, stage, selector) do
      unless Enum.sort(Map.keys(context)) == [:owner_scope_id, :principal_id, :repo],
        do: raise("export observer requires the exact owner-bound source context")

      Singularity.Runtime.NoteMarkdownExportIntegrationTest.observe(
        context.repo,
        context.principal_id,
        context.owner_scope_id,
        stage,
        selector
      )
    end
  end

  @doc false
  def observe(repo, principal, owner, stage, selector) do
    assert repo == RequestRepo
    assert repo.checked_out?() and repo.in_transaction?()
    lock_key = "singularity:authorization:" <> principal <> ":" <> owner

    assert %{rows: [[^principal, ^owner, connection, true]]} =
             query!(
               repo,
               """
               SELECT current_setting('singularity.principal_id',true),
                 current_setting('singularity.vault_id',true),pg_backend_pid(),
                 EXISTS(SELECT 1 FROM pg_locks WHERE pid=pg_backend_pid() AND locktype='advisory'
                   AND mode='ShareLock' AND granted AND objsubid=1
                   AND classid::bigint=((hashtextextended($1::text,0)>>32)&4294967295::bigint)
                   AND objid::bigint=(hashtextextended($1::text,0)&4294967295::bigint))
               """,
               [lock_key]
             )

    send(self(), {:markdown_export_sql, stage, selector, repo, principal, owner, connection})
  end

  setup do
    {:ok, fixture!()}
  end

  test "mixed sealed sources preserve descending order pins locators and deterministic ordinary Markdown",
       c do
    assert %{rows: [["singularity_web", true, false]]} =
             query!(
               RequestRepo,
               "SELECT current_user,has_table_privilege(current_user,'content.note_source_set_seals','SELECT'),has_table_privilege(current_user,'content.note_source_set_seals','INSERT')",
               []
             )

    assert {:ok, first} = export(c)
    assert_export_steps(c)
    assert {:ok, ^first} = export(c)
    assert_export_steps(c)

    assert %NoteExport{
             resource_id: note_id,
             resource_version_id: version,
             media_type: "text/markdown; charset=utf-8"
           } = first

    assert note_id == c.note.resource_id and version == c.note.resource_version_id
    assert String.starts_with?(first.markdown, c.note.markdown <> "\n\n## Sources\n")
    assert_source_inventory(first.markdown, c)
    assert_audits(c, 2)
  end

  test "new Note Document heads and mutable Resource titles cannot replace pinned historical metadata",
       c do
    advance_heads!(c)
    assert {:ok, result} = export(c)
    assert_export_steps(c)
    assert_source_inventory(result.markdown, c)
    assert result.markdown =~ "Pinned Asset 界"
    assert result.markdown =~ "[Note]("
    assert result.markdown =~ "[Document]("
    refute result.markdown =~ "Later Note"
    refute result.markdown =~ "Later Document"
    refute result.markdown =~ "Mutable Asset"
    assert_audits(c, 1)
  end

  test "tombstoned targets stay historical with exact source pins and restore without rewriting membership",
       c do
    before = stored_version(c.note.resource_version_id)

    for deleted? <- [true, false] do
      for row <- [c.source, c.target_note | c.documents],
          do: set_deleted!(row.resource_id, deleted?)

      assert {:ok, result} = export(c)
      assert_export_steps(c)
      assert_source_inventory(result.markdown, c)

      if deleted?,
        do: assert(result.markdown =~ "deleted historical source"),
        else: refute(result.markdown =~ "deleted historical source")

      assert stored_version(c.note.resource_version_id) == before
    end

    assert_audits(c, 2)
  end

  test "public facade and Save reorder sealed membership while historical bytes remain exact",
       c do
    before = stored_version(c.note.resource_version_id)
    attachments = c.note.attachments |> Enum.reverse() |> Enum.map(&Map.from_struct/1)
    citations = c.note.citations |> Enum.reverse() |> Enum.map(&Map.from_struct/1)
    config = facade_config(c)
    public_session = struct!(Session, Map.from_struct(c.session))

    assert {:ok, saved} =
             Api.save_note(config, public_session, c.note.resource_id, %{
               mutation_id: Ecto.UUID.generate(),
               base_version_id: c.note.resource_version_id,
               title: c.note.title,
               markdown: c.note.markdown,
               attachments: attachments,
               citations: citations
             })

    assert saved.outcome == :saved
    assert Enum.map(saved.canonical.attachments, &Map.from_struct/1) == attachments
    assert Enum.map(saved.canonical.citations, &Map.from_struct/1) == citations
    assert saved.canonical.resource_version_id != c.note.resource_version_id
    assert stored_version(c.note.resource_version_id) == before
    assert_seal(saved.canonical, 3, 4)
    updated = %{c | note: saved.canonical}
    assert {:ok, result} = Api.export_note(config, public_session, c.note.resource_id)
    assert_export_steps(updated)
    assert result.resource_version_id == saved.canonical.resource_version_id
    assert {:ok, ^result} = NoteExport.new(Map.from_struct(result))

    assert Enum.sort(Map.keys(Map.from_struct(result))) == [
             :filename,
             :markdown,
             :media_type,
             :resource_id,
             :resource_version_id
           ]

    assert_source_inventory(result.markdown, updated)
    assert_audits(updated, 1)
  end

  for capability <- ~w(asset.read note.read note.export) do
    @capability capability
    test "revoked #{@capability} rejects export before any selected-source or hydration SQL", c do
      revoke!(c.principal, @capability)
      assert export(c) == {:error, Error.new(:forbidden)}
      steps = observed_steps(c)
      assert [{:authorize, ["note.export", "note.read"]} | rest] = steps

      if @capability == "asset.read" do
        assert rest == [
                 {:membership, {c.note.resource_id, c.note.resource_version_id}},
                 {:authorize, "asset.read"}
               ]
      else
        assert rest == []
      end

      assert_audits(c, 0)
    end
  end

  for epoch <- [:principal, :owner] do
    @epoch epoch
    test "stale #{@epoch} epoch denies before referenced SQL while a freshly bound session succeeds",
         c do
      increment_epoch!(c.principal, @epoch)
      assert export(c) == {:error, Error.new(:forbidden)}
      assert observed_steps(c) == [{:authorize, ["note.export", "note.read"]}]
      assert_audits(c, 0)
      fresh = %{c | session: session(c.principal)}
      assert {:ok, result} = export(fresh)
      assert_export_steps(fresh)
      assert_source_inventory(result.markdown, fresh)
      assert_audits(fresh, 1)
    end
  end

  test "empty membership preserves BOM HTML CRLF and bare CR with no source checks or hydration",
       c do
    body = "\uFEFF<div>CANARY_EMPTY</div>\r\n~~~ambiguous\rfinal"
    empty = create_note!(c.runtime_plain, c.session, body, [], [])
    context = %{c | note: empty}
    assert {:ok, %NoteExport{markdown: ^body}} = export(context)

    assert observed_steps(context) == [
             {:authorize, ["note.export", "note.read"]},
             {:membership, {empty.resource_id, empty.resource_version_id}}
           ]

    assert_audits(context, 1)
  end

  test "a public Save retains a canonical 1 MiB body and exports the complete appended sources",
       c do
    body = String.duplicate("a", @canonical_limit)

    assert {:ok, saved} =
             Api.save_note(
               facade_config(c),
               struct!(Session, Map.from_struct(c.session)),
               c.note.resource_id,
               %{
                 mutation_id: Ecto.UUID.generate(),
                 base_version_id: c.note.resource_version_id,
                 title: "Large canonical Note",
                 markdown: body
               }
             )

    assert saved.canonical.markdown == body
    context = %{c | note: saved.canonical}
    assert_seal(context.note, 3, 4)
    assert {:ok, result} = export(context)
    assert_export_steps(context)
    assert String.starts_with?(result.markdown, body <> "\n\n## Sources\n")
    assert byte_size(result.markdown) > @canonical_limit
    assert byte_size(result.markdown) <= @rendered_limit
    assert_source_inventory(result.markdown, context)
    assert_audits(context, 1)
  end

  test "nonempty opaque body admission failure returns no partial export or success audit", c do
    body = "<div>CANARY_OPAQUE_BODY</div>"

    assert {:ok, saved} =
             Save.run(c.runtime_plain, c.session, c.note.resource_id, %{
               mutation_id: Ecto.UUID.generate(),
               base_version_id: c.note.resource_version_id,
               title: c.note.title,
               markdown: body
             })

    context = %{c | note: saved.canonical}
    assert export(context) == {:error, Error.new(:integrity_failure)}
    assert_export_steps(context)
    assert_audits(context, 0)
    assert stored_version(context.note.resource_version_id).markdown == body
  end

  test "unbounded SQL filenames fail raw and escaped output budgets without success audits", c do
    for {character, size, early?} <- [
          {"a", @rendered_limit + 1, true},
          {"<", div(@rendered_limit, 2) + 1, false}
        ] do
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "UPDATE content.asset_metadata SET original_filename=repeat($2::text,$3::integer) WHERE asset_id=$1 AND resource_version_id=$4",
          [c.source.asset_id, character, size, c.source.resource_version_id]
        )
      end)

      assert export(c) == {:error, Error.new(:integrity_failure)}

      if early? do
        [first | _] = c.note.attachments

        assert observed_steps(c) ==
                 source_prefix(c) ++ [{:hydrate_attachment, first.attachment_id}]
      else
        assert_export_steps(c)
      end

      assert_audits(c, 0)
    end
  end

  defp fixture! do
    source = KnowledgeFixtures.source!()
    target_note = KnowledgeFixtures.note!(source)
    {document, documents, fragments} = documents_with_fragments!(source)
    prepare_authority!(source.vault_id)
    principal = create_principal!(source.vault_id)
    actor = session(principal)
    seed_metadata!(source)

    assert {:ok, authorization} =
             AuthorizationDependencies.new(%{
               store: IdentityRepository,
               custodian: {Custodian, self()}
             })

    runtime = %{
      audit: AuditSink,
      authorization: authorization,
      authorization_lock: AuthorizationLock,
      authorizer: Authorize,
      fingerprint_secret: :binary.copy(<<0xC7>>, 32),
      note_repository: NoteRepository,
      knowledge_link_repository: KnowledgeLinkRepository,
      operation_scope: OperationScope,
      request_repo: RequestRepo,
      scoped_repo: ScopedRepo,
      vault_lock: VaultLock
    }

    ids = Enum.sort(Enum.map(1..3, fn _ -> Ecto.UUID.generate() end), :desc)

    attachments =
      Enum.zip([{source, :asset}, {target_note, :note}, {document, :document}], ids)
      |> Enum.map(fn {{row, kind}, id} ->
        %{
          attachment_id: id,
          target_resource_id: text(row.resource_id),
          target_resource_version_id: text(row.resource_version_id),
          target_kind: kind,
          role: :source,
          label: "Pinned #{kind}"
        }
      end)

    citation_ids = Enum.sort(Enum.map(1..4, fn _ -> Ecto.UUID.generate() end), :desc)

    citations =
      Enum.zip(fragments, citation_ids)
      |> Enum.map(fn {fragment, id} ->
        %{
          citation_id: id,
          source_resource_id: fragment.resource_id,
          source_resource_version_id: fragment.resource_version_id,
          fragment_id: fragment.fragment_id,
          locator: SourceLocator.to_map(fragment.locator)
        }
      end)

    note = create_note!(runtime, actor, "CANARY_CONTAINING_BODY\r\n", attachments, citations)
    assert Enum.map(note.attachments, & &1.attachment_id) == ids
    assert Enum.map(note.citations, & &1.citation_id) == citation_ids
    assert_seal(note, 3, 4)

    %{
      runtime_plain: runtime,
      runtime: %{
        runtime
        | authorizer: ObservedAuthorize,
          knowledge_link_repository: ObservedSources
      },
      source: source,
      target_note: target_note,
      document: document,
      documents: documents,
      fragments: fragments,
      principal: principal,
      session: actor,
      note: note
    }
  end

  defp create_note!(runtime, actor, body, attachments, citations) do
    assert {:ok, note} =
             Create.run(runtime, actor, %{
               mutation_id: Ecto.UUID.generate(),
               title: "Containing Note",
               markdown: body,
               attachments: attachments,
               citations: citations
             })

    note
  end

  defp facade_config(c),
    do: %{
      export_note: fn actor, id -> Export.run(c.runtime, actor, id) end,
      save_note: fn actor, id, attrs -> Save.run(c.runtime_plain, actor, id, attrs) end
    }

  defp export(c), do: Export.run(c.runtime, c.session, c.note.resource_id)

  defp assert_source_inventory(markdown, c) do
    for attachment <- c.note.attachments do
      extension = %{asset: "bin", note: "md", document: "txt"}[attachment.target_kind]

      assert markdown =~
               "](sources/#{attachment.target_kind}-#{attachment.target_resource_id}-#{attachment.target_resource_version_id}.#{extension})"

      assert markdown =~ attachment.attachment_id
    end

    ids =
      Enum.map(c.note.attachments, & &1.attachment_id) ++
        Enum.map(c.note.citations, & &1.citation_id)

    for [first, second] <- Enum.chunk_every(ids, 2, 1, :discard) do
      {a, _} = :binary.match(markdown, first)
      {b, _} = :binary.match(markdown, second)
      assert a < b
    end

    for citation <- c.note.citations do
      label = "singularity-source-" <> citation.citation_id

      assert markdown =~
               "[Document](sources/document-#{citation.source_resource_id}-#{citation.source_resource_version_id}.txt)"

      assert markdown =~ "[^#{label}]:"
      assert markdown =~ citation.fragment_id
    end

    for fragment <- c.fragments, do: refute(markdown =~ fragment.text)
    assert markdown =~ "PDF page 7; characters 3–19"
    assert markdown =~ "Markdown heading Top > Nested 界; lines 2–9"
    assert markdown =~ "Text lines 4–11"
    assert markdown =~ "Fragment ordinal 1"
    assert markdown =~ "Text-only source inventory; no source files included."
  end

  defp source_prefix(c) do
    [first | _] = c.note.attachments

    capabilities =
      c.note.attachments
      |> Enum.map(fn a -> if a.target_kind == :note, do: "note.read", else: "asset.read" end)
      |> Kernel.++(Enum.map(c.note.citations, fn _ -> "asset.read" end))
      |> Enum.uniq()

    [
      {:authorize, ["note.export", "note.read"]},
      {:membership, {c.note.resource_id, c.note.resource_version_id}}
    ] ++
      Enum.map(capabilities, &{:authorize, &1}) ++ [{:select_attachment, first.attachment_id}]
  end

  defp assert_export_steps(c) do
    expected =
      source_prefix(c) ++
        Enum.map(c.note.attachments, &{:hydrate_attachment, &1.attachment_id}) ++
        Enum.map(c.note.citations, &{:hydrate_citation, &1.citation_id})

    assert observed_steps(c) == expected
  end

  defp observed_steps(c), do: observed_steps(c, nil, [])

  defp observed_steps(c, connection, acc) do
    receive do
      {:markdown_export_sql, stage, selector, repo, principal, owner, backend} ->
        assert repo == RequestRepo
        assert principal == c.session.principal_id and owner == c.session.vault_id
        if connection != nil, do: assert(backend == connection)
        observed_steps(c, backend, [{stage, selector} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp assert_audits(c, expected_count) do
    Fixtures.with_owner(fn ->
      %{rows: rows} =
        query!(
          MigrationRepo,
          "SELECT id::text FROM audit.events WHERE operation='note.export' AND target_id=$1 AND vault_id=$2 ORDER BY id",
          [dump(c.note.resource_id), dump(c.session.vault_id)]
        )

      assert length(rows) == expected_count

      for [id] <- rows do
        %{rows: [[correlation]]} =
          query!(MigrationRepo, "SELECT correlation_id::text FROM audit.events WHERE id=$1", [
            dump(id)
          ])

        event =
          assert_persisted_audit!(MigrationRepo, "note.export", [correlation_id: correlation],
            principal_id: c.session.principal_id,
            vault_id: c.session.vault_id,
            target_id: c.note.resource_id,
            target_type: "note",
            result: "completed",
            classification: "private",
            metadata: %{"resource_version_id" => c.note.resource_version_id}
          )

        refute inspect(event) =~ "CANARY_"
      end
    end)
  end

  defp assert_seal(note, attachments, citations) do
    assert %{rows: [[^attachments, ^citations]]} =
             Fixtures.with_owner(fn ->
               query!(
                 MigrationRepo,
                 "SELECT attachment_count,citation_count FROM content.note_source_set_seals WHERE note_resource_version_id=$1",
                 [dump(note.resource_version_id)]
               )
             end)
  end

  defp stored_version(version) do
    Fixtures.with_owner(fn ->
      %{rows: [[title, markdown, attachments, citations]]} =
        query!(
          MigrationRepo,
          """
          SELECT n.title,n.markdown,
            (SELECT jsonb_agg(to_jsonb(a) ORDER BY a.ordinal) FROM content.note_attachments a WHERE a.note_resource_version_id=n.resource_version_id),
            (SELECT jsonb_agg(to_jsonb(c) ORDER BY c.ordinal) FROM content.note_citations c WHERE c.note_resource_version_id=n.resource_version_id)
          FROM content.note_versions n WHERE n.resource_version_id=$1
          """,
          [dump(version)]
        )

      %{title: title, markdown: markdown, attachments: attachments, citations: citations}
    end)
  end

  defp prepare_authority!(owner) do
    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "UPDATE core.vaults SET locked=false WHERE id=$1", [owner])

      for capability <- @capabilities do
        query!(
          MigrationRepo,
          "INSERT INTO core.capabilities(id,name) VALUES($1,$2) ON CONFLICT(name) DO NOTHING",
          [KnowledgeFixtures.uuid(), capability]
        )
      end
    end)
  end

  defp create_principal!(owner) do
    ids =
      Map.new(
        [:person_id, :account_id, :credential_id, :principal_id, :session_id],
        &{&1, Ecto.UUID.generate()}
      )
      |> Map.put(:vault_id, text(owner))

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO identity.people(id,display_name) VALUES($1,'Markdown export principal')",
        [dump(ids.person_id)]
      )

      query!(MigrationRepo, "INSERT INTO identity.accounts(id,person_id) VALUES($1,$2)", [
        dump(ids.account_id),
        dump(ids.person_id)
      ])

      query!(
        MigrationRepo,
        "INSERT INTO identity.credentials(id,account_id,normalized_login,verifier) VALUES($1,$2,$3,'verifier')",
        [
          dump(ids.credential_id),
          dump(ids.account_id),
          "markdown-#{ids.principal_id}@example.test"
        ]
      )

      query!(
        MigrationRepo,
        "INSERT INTO identity.principals(id,account_id,kind) VALUES($1,$2,'owner')",
        [dump(ids.principal_id), dump(ids.account_id)]
      )

      query!(
        MigrationRepo,
        "INSERT INTO core.vault_members(principal_id,vault_id) VALUES($1,$2)",
        [dump(ids.principal_id), owner]
      )

      query!(
        MigrationRepo,
        "INSERT INTO identity.sessions(id,account_id,credential_id,principal_id,vault_id,token_digest,expires_at) VALUES($1,$2,$3,$4,$5,$6,CURRENT_TIMESTAMP+interval '1 hour')",
        [
          dump(ids.session_id),
          dump(ids.account_id),
          dump(ids.credential_id),
          dump(ids.principal_id),
          owner,
          :crypto.hash(:sha256, ids.session_id)
        ]
      )

      for capability <- @capabilities do
        query!(
          MigrationRepo,
          "INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name=$3",
          [dump(ids.principal_id), owner, capability]
        )
      end
    end)

    ids
  end

  defp session(principal) do
    %{rows: [[principal_epoch, owner_epoch]]} =
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "SELECT p.authorization_epoch,v.authorization_epoch FROM identity.principals p JOIN core.vaults v ON v.id=$2 WHERE p.id=$1",
          [dump(principal.principal_id), dump(principal.vault_id)]
        )
      end)

    %SessionContext{
      session_id: principal.session_id,
      account_id: principal.account_id,
      principal_id: principal.principal_id,
      vault_id: principal.vault_id,
      expires_at: DateTime.add(DateTime.utc_now(), 600, :second),
      principal_authorization_epoch: principal_epoch,
      vault_authorization_epoch: owner_epoch,
      authorization_epoch: principal_epoch,
      unlocked?: true
    }
  end

  defp revoke!(principal, capability),
    do:
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "UPDATE core.principal_capabilities a SET revoked_at=CURRENT_TIMESTAMP FROM core.capabilities c WHERE a.capability_id=c.id AND a.principal_id=$1 AND a.vault_id=$2 AND c.name=$3",
          [dump(principal.principal_id), dump(principal.vault_id), capability]
        )
      end)

  defp increment_epoch!(principal, epoch),
    do:
      Fixtures.with_owner(fn ->
        case epoch do
          :principal ->
            query!(
              MigrationRepo,
              "UPDATE identity.principals SET authorization_epoch=authorization_epoch+1 WHERE id=$1",
              [dump(principal.principal_id)]
            )

          :owner ->
            query!(
              MigrationRepo,
              "UPDATE core.vaults SET authorization_epoch=authorization_epoch+1 WHERE id=$1",
              [dump(principal.vault_id)]
            )
        end
      end)

  defp seed_metadata!(source),
    do:
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "INSERT INTO content.asset_metadata(id,asset_id,resource_version_id,vault_id,classification,projection_version,original_filename,declared_media_type,detected_media_type,plaintext_byte_size,extraction_state,completed_at) VALUES($1,$2,$3,$4,'private',1,'Pinned Asset 界.txt','text/plain','text/plain',12,'completed',CURRENT_TIMESTAMP)",
          [KnowledgeFixtures.uuid(), source.asset_id, source.resource_version_id, source.vault_id]
        )
      end)

  defp set_deleted!(resource, deleted?),
    do:
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "UPDATE content.resources SET deleted_at=CASE WHEN $2 THEN clock_timestamp() ELSE NULL END WHERE id=$1",
          [resource, deleted?]
        )
      end)

  defp advance_heads!(c),
    do:
      Fixtures.with_owner(fn ->
        for {row, title} <- [{c.target_note, "Later Note"}, {c.document, "Later Document"}] do
          version = KnowledgeFixtures.uuid()

          query!(
            MigrationRepo,
            "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',1)",
            [version, row.resource_id, row.vault_id]
          )

          if row == c.target_note do
            query!(
              MigrationRepo,
              "INSERT INTO content.note_versions(resource_version_id,resource_id,vault_id,classification,title,markdown,created_by_principal_id,parent_version_id,inserted_at) VALUES($1,$2,$3,'private',$4,'Later body',$5,$6,CURRENT_TIMESTAMP)",
              [
                version,
                row.resource_id,
                row.vault_id,
                title,
                c.source.principal_id,
                row.resource_version_id
              ]
            )
          else
            KnowledgeFixtures.insert_typed!(%{row | resource_version_id: version, title: title})
          end

          query!(
            MigrationRepo,
            "UPDATE content.resources SET current_version_id=$1,title=$2 WHERE id=$3",
            [version, title, row.resource_id]
          )
        end

        query!(
          MigrationRepo,
          "UPDATE content.resources SET title='Mutable Asset title' WHERE id=$1",
          [c.source.resource_id]
        )
      end)

  defp documents_with_fragments!(source) do
    # SQL binds locator kind to each Document's declared media and requires
    # contiguous fragment ordinals. Preserve that production extraction contract.
    {pdf, pdf_fragments} =
      extracted_document!(source, "application/pdf", [
        %{version: 1, kind: "pdf", page: 7, start_char: 3, end_char: 19}
      ])

    {markdown, markdown_fragments} =
      extracted_document!(source, "text/markdown", [
        %{
          version: 1,
          kind: "markdown",
          heading_path: ["Top", "Nested 界"],
          start_line: 2,
          end_line: 9
        }
      ])

    {text, text_fragments} =
      extracted_document!(source, "text/plain", [
        %{version: 1, kind: "text", start_line: 4, end_line: 11},
        %{version: 1, kind: "fragment", ordinal: 1}
      ])

    {text, [pdf, markdown, text], pdf_fragments ++ markdown_fragments ++ text_fragments}
  end

  defp extracted_document!(source, media_type, locators) do
    document = KnowledgeFixtures.document!(source, %{media_type: media_type})

    fragments =
      locators
      |> Enum.with_index()
      |> Enum.map(fn {locator, ordinal} ->
        assert {:ok, fragment} =
                 DocumentFragment.new(%{
                   resource_id: text(document.resource_id),
                   resource_version_id: text(document.resource_version_id),
                   owner_scope_id: text(source.vault_id),
                   classification: :private,
                   ordinal: ordinal,
                   text: "CANARY_FRAGMENT_#{media_type}_#{ordinal}",
                   locator: locator
                 })

        fragment
      end)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "SELECT set_config('singularity.principal_id',$1,true),set_config('singularity.vault_id',$2,true)",
        [text(source.principal_id), text(source.vault_id)]
      )

      query!(MigrationRepo, "SELECT content.claim_document_extraction($1,0,$1,'plain',1)", [
        document.resource_version_id
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
        document.resource_version_id,
        payload,
        :crypto.hash(:sha256, Enum.map_join(fragments, "", & &1.text))
      ])
    end)

    {document, fragments}
  end

  defp text(id), do: Ecto.UUID.load!(id)
  defp dump(id), do: Ecto.UUID.dump!(id)
end
