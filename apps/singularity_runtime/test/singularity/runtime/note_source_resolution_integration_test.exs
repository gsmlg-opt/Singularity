defmodule Singularity.Runtime.NoteSourceResolutionIntegrationTest do
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

  alias Singularity.Runtime.DTO.{NoteAttachment, NoteCitation, Session}
  alias Singularity.Runtime.Notes.{Create, Get, ResolveSource, Save}
  alias Singularity.Runtime.NoteAuthorizationIntegrationTest.{AuditSink, Custodian}

  alias Singularity.Storage.{
    AuthorizationLock,
    Fixtures,
    KnowledgeFixtures,
    MigrationRepo,
    RequestRepo,
    ScopedRepo,
    VaultLock
  }

  alias Singularity.Storage.Postgres.{IdentityRepository, KnowledgeLinkRepository, NoteRepository}

  # Run alongside NoteAuthorizationIntegrationTest: its established Custodian
  # and AuditSink are integration-only adapters. This suite qualifies actual
  # PostgreSQL source reads and live IdentityRepository authorization, NOT live
  # custody, original-byte delivery, production grants, browser behavior or E2E.
  defmodule ObservedReader do
    alias Singularity.Storage.Postgres.KnowledgeLinkRepository

    def read_membership(context, note, version),
      do: KnowledgeLinkRepository.read_membership(context, note, version)

    def select_attachment_in_scope(context, note, version, member) do
      observe(context, :select_attachment, member)
      KnowledgeLinkRepository.select_attachment_in_scope(context, note, version, member)
    end

    def select_citation_in_scope(context, note, version, member) do
      observe(context, :select_citation, member)
      KnowledgeLinkRepository.select_citation_in_scope(context, note, version, member)
    end

    def resolve_attachment_in_scope(context, reference) do
      observe(context, :hydrate_attachment, reference.attachment_id)
      KnowledgeLinkRepository.resolve_attachment_in_scope(context, reference)
    end

    def resolve_citation_in_scope(context, reference) do
      observe(context, :hydrate_citation, reference.citation_id)
      KnowledgeLinkRepository.resolve_citation_in_scope(context, reference)
    end

    defp observe(
           %{repo: repo, principal_id: principal, owner_scope_id: owner} = context,
           stage,
           id
         ) do
      unless map_size(context) == 3 and repo.in_transaction?(),
        do: raise("resolution observer requires the existing scoped transaction")

      %{rows: [[^principal, ^owner, connection]]} =
        Ecto.Adapters.SQL.query!(
          repo,
          "SELECT current_setting('singularity.principal_id',true),current_setting('singularity.vault_id',true),pg_backend_pid()",
          [],
          log: false
        )

      send(self(), {:source_resolution_sql, stage, id, repo, principal, owner, connection})
    end
  end

  test "attachments preserve exact pins after newer typed heads and a mutable Asset title" do
    with_fixture(fn c ->
      advance_heads!(c)

      for {kind, reference} <- Enum.zip([:asset, :note, :document], c.note.attachments) do
        assert {:ok, result} = resolve(c, :attachment, reference.attachment_id)
        assert result == expected(c, kind, false)
        assert_resolution_steps(c, :attachment, reference.attachment_id)
      end
    end)
  end

  test "public facade resolves persisted Asset Note Document and selected citation without private fields" do
    with_fixture(fn c ->
      config = %{
        resolve_note_attachment: fn session, note, version, member ->
          ResolveSource.attachment(c.runtime, session, note, version, member)
        end,
        resolve_note_citation: fn session, note, version, member ->
          ResolveSource.citation(c.runtime, session, note, version, member)
        end
      }

      public_session = struct!(Session, Map.from_struct(c.session))

      for kind <- [:asset, :note, :document, :citation] do
        {operation, member} = selector(c, kind)

        function =
          if operation == :attachment, do: :resolve_note_attachment, else: :resolve_note_citation

        assert {:ok, result} =
                 apply(Api, function, [
                   config,
                   public_session,
                   c.note.resource_id,
                   c.note.resource_version_id,
                   member
                 ])

        assert result == expected(c, kind, false)
        assert_resolution_steps(c, operation, member)
      end
    end)
  end

  test "historical attachments and citation survive source tombstone and restore with exact status" do
    with_fixture(fn c ->
      for deleted? <- [true, false] do
        for row <- [c.source, c.target_note, c.document],
            do: set_deleted!(row.resource_id, deleted?)

        for kind <- [:asset, :note, :document, :citation] do
          {operation, member} = selector(c, kind)
          assert {:ok, result} = resolve(c, operation, member)
          assert result == expected(c, kind, deleted?)
          assert_resolution_steps(c, operation, member)
        end
      end
    end)
  end

  test "revoked asset.read denies retained and deleted Asset Document and citation before hydration" do
    with_fixture(fn c ->
      set_deleted!(c.source.resource_id, true)
      set_deleted!(c.document.resource_id, true)
      revoke!(c.principal, "asset.read")

      for kind <- [:asset, :document, :citation] do
        {operation, member} = selector(c, kind)
        assert resolve(c, operation, member) == {:error, Error.new(:forbidden)}
        assert_selected_only(c, operation, member)
      end

      {operation, member} = selector(c, :note)
      assert {:ok, result} = resolve(c, operation, member)
      assert result == expected(c, :note, false)
      assert_resolution_steps(c, operation, member)
    end)
  end

  test "revoked containing note.read denies every source before selection or target hydration" do
    with_fixture(fn c ->
      revoke!(c.principal, "note.read")

      for kind <- [:asset, :note, :document, :citation] do
        {operation, member} = selector(c, kind)
        assert resolve(c, operation, member) == {:error, Error.new(:forbidden)}
        refute_received {:source_resolution_sql, _, _, _, _, _, _}
      end
    end)
  end

  for epoch <- [:principal, :owner] do
    @epoch epoch
    test "changed #{@epoch} epoch rejects the old session before any selected-source SQL" do
      with_fixture(fn c ->
        increment_epoch!(c.principal, @epoch)

        for kind <- [:asset, :note, :document, :citation] do
          {operation, member} = selector(c, kind)
          assert resolve(c, operation, member) == {:error, Error.new(:forbidden)}
          refute_received {:source_resolution_sql, _, _, _, _, _, _}
        end

        fresh = %{c | session: session(c.principal)}
        {operation, member} = selector(c, :citation)
        assert {:ok, result} = resolve(fresh, operation, member)
        assert result == expected(c, :citation, false)
        assert_resolution_steps(fresh, operation, member)
      end)
    end
  end

  test "foreign owner and missing containing Note version or member are nondisclosing not-found" do
    with_fixture(fn c ->
      foreign_source = KnowledgeFixtures.source!()
      prepare_authority!(foreign_source.vault_id)
      foreign = create_principal!(foreign_source.vault_id)
      foreign_context = %{c | principal: foreign, session: session(foreign)}

      for kind <- [:asset, :citation] do
        {operation, member} = selector(c, kind)
        assert resolve(foreign_context, operation, member) == {:error, Error.new(:not_found)}
        assert_selected_only(foreign_context, operation, member)

        for {note, version, requested_member} <- [
              {Ecto.UUID.generate(), c.note.resource_version_id, member},
              {c.note.resource_id, Ecto.UUID.generate(), member},
              {c.note.resource_id, c.note.resource_version_id, Ecto.UUID.generate()},
              {c.note.resource_id, text(c.target_note.resource_version_id), member}
            ] do
          assert apply(ResolveSource, operation, [
                   c.runtime,
                   c.session,
                   note,
                   version,
                   requested_member
                 ]) == {:error, Error.new(:not_found)}

          assert_selected_only(c, operation, requested_member)
        end
      end
    end)
  end

  test "tombstoned containing Note hides stored members until restored without changing source pins" do
    with_fixture(fn c ->
      set_deleted!(Ecto.UUID.dump!(c.note.resource_id), true)

      for kind <- [:asset, :citation] do
        {operation, member} = selector(c, kind)
        assert resolve(c, operation, member) == {:error, Error.new(:not_found)}
        assert_selected_only(c, operation, member)
      end

      set_deleted!(Ecto.UUID.dump!(c.note.resource_id), false)
      {operation, member} = selector(c, :citation)
      assert {:ok, result} = resolve(c, operation, member)
      assert result == expected(c, :citation, false)
      assert_resolution_steps(c, operation, member)
    end)
  end

  test "citation returns only the selected canonical fragment after a newer Document head" do
    with_fixture(fn c ->
      advance_document!(c)
      {operation, member} = selector(c, :citation)
      assert {:ok, result} = resolve(c, operation, member)
      assert result == expected(c, :citation, false)
      assert result.fragment.text == "Selected evidence\nSecond selected line"
      assert result.fragment.ordinal == 1
      assert result.fragment.fragment_id == c.fragment.fragment_id
      assert result.fragment.locator == c.fragment.locator

      assert {:ok, rebuilt} =
               DocumentFragment.new(%{
                 resource_id: result.source.resource_id,
                 resource_version_id: result.source.resource_version_id,
                 owner_scope_id: c.session.vault_id,
                 classification: :private,
                 ordinal: result.fragment.ordinal,
                 text: result.fragment.text,
                 locator: result.fragment.locator
               })

      assert rebuilt == c.fragment
      refute Map.has_key?(result, :fragments)
      assert_resolution_steps(c, operation, member)
    end)
  end

  test "real current and exact-version Get compose ordered metadata references without target read authority" do
    with_fixture(fn c ->
      assert {:ok, latest} =
               Save.run(c.runtime, c.session, c.note.resource_id, %{
                 mutation_id: Ecto.UUID.generate(),
                 base_version_id: c.note.resource_version_id,
                 title: "Later containing Note",
                 markdown: "Later containing body"
               })

      refute latest.canonical.resource_version_id == c.note.resource_version_id
      revoke!(c.principal, "asset.read")

      assert {:ok, current} = Get.run(c.runtime, c.session, c.note.resource_id)

      assert {:ok, historical} =
               Get.version(c.runtime, c.session, c.note.resource_id, c.note.resource_version_id)

      assert current.resource_version_id == latest.canonical.resource_version_id
      assert current.revision == 1
      assert historical.resource_version_id == c.note.resource_version_id
      assert historical.revision == 0
      assert current.attachments == c.note.attachments
      assert current.citations == c.note.citations
      assert historical.attachments == c.note.attachments
      assert historical.citations == c.note.citations
      refute_received {:source_resolution_sql, _, _, _, _, _, _}
    end)
  end

  defp with_fixture(fun) do
    fun.(fixture!())
  end

  defp fixture! do
    source = KnowledgeFixtures.source!()
    {document, fragment} = two_fragment_document!(source)
    target_note = KnowledgeFixtures.note!(source)
    prepare_authority!(source.vault_id)
    filename = String.duplicate("original-", 40) <> "evidence.txt"
    seed_metadata!(source, filename)
    principal = create_principal!(source.vault_id)
    principal_session = session(principal)

    {:ok, authorization} =
      AuthorizationDependencies.new(%{
        store: IdentityRepository,
        custodian: {Custodian, self()}
      })

    runtime = %{
      audit: {AuditSink, self()},
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

    attachments =
      for {row, kind} <- [{source, :asset}, {target_note, :note}, {document, :document}] do
        %{
          attachment_id: Ecto.UUID.generate(),
          target_resource_id: text(row.resource_id),
          target_resource_version_id: text(row.resource_version_id),
          target_kind: kind,
          role: :source,
          label: "Pinned #{kind}"
        }
      end

    citation = %{
      citation_id: Ecto.UUID.generate(),
      source_resource_id: text(document.resource_id),
      source_resource_version_id: text(document.resource_version_id),
      fragment_id: fragment.fragment_id,
      locator: SourceLocator.to_map(fragment.locator)
    }

    assert {:ok, created} =
             Create.run(runtime, principal_session, %{
               mutation_id: Ecto.UUID.generate(),
               title: "Containing Note",
               markdown: "Containing body",
               attachments: attachments,
               citations: [citation]
             })

    assert Enum.map(created.attachments, &Map.from_struct/1) == attachments
    assert [%NoteCitation{fragment_id: selected_fragment}] = created.citations
    assert selected_fragment == fragment.fragment_id

    # A real mutation publishes the complete set; no raw unsealed fixture,
    # disabled trigger or weakened provenance constraint establishes membership.
    assert %{rows: [[3, 1]]} =
             Fixtures.with_owner(fn ->
               query!(
                 MigrationRepo,
                 "SELECT attachment_count,citation_count FROM content.note_source_set_seals WHERE note_resource_version_id=$1",
                 [dump(created.resource_version_id)]
               )
             end)

    %{
      runtime: %{runtime | knowledge_link_repository: ObservedReader},
      principal: principal,
      session: principal_session,
      note: created,
      source: source,
      document: document,
      target_note: target_note,
      fragment: fragment,
      filename: filename
    }
  end

  defp resolve(c, operation, member),
    do:
      apply(ResolveSource, operation, [
        c.runtime,
        c.session,
        c.note.resource_id,
        c.note.resource_version_id,
        member
      ])

  defp selector(c, :citation), do: {:citation, hd(c.note.citations).citation_id}

  defp selector(c, kind),
    do: {:attachment, Enum.find(c.note.attachments, &(&1.target_kind == kind)).attachment_id}

  defp expected(c, :citation, deleted?) do
    %{
      reference: hd(c.note.citations),
      source: %{
        kind: :document,
        resource_id: text(c.document.resource_id),
        resource_version_id: text(c.document.resource_version_id),
        title: "Document",
        deleted?: deleted?
      },
      fragment: %{
        fragment_id: c.fragment.fragment_id,
        ordinal: c.fragment.ordinal,
        text: c.fragment.text,
        locator: c.fragment.locator
      }
    }
  end

  defp expected(c, kind, deleted?) do
    reference = Enum.find(c.note.attachments, &(&1.target_kind == kind))
    assert %NoteAttachment{} = reference

    title =
      case kind do
        :asset -> c.filename
        :note -> "Note"
        :document -> "Document"
      end

    %{
      reference: reference,
      source: %{
        kind: kind,
        resource_id: reference.target_resource_id,
        resource_version_id: reference.target_resource_version_id,
        title: title,
        deleted?: deleted?
      }
    }
  end

  defp assert_resolution_steps(c, operation, member) do
    select = if operation == :attachment, do: :select_attachment, else: :select_citation
    hydrate = if operation == :attachment, do: :hydrate_attachment, else: :hydrate_citation
    principal = c.session.principal_id
    owner = c.session.vault_id

    assert_received {:source_resolution_sql, ^select, ^member, RequestRepo, ^principal, ^owner,
                     connection}

    assert_received {:source_resolution_sql, ^hydrate, ^member, RequestRepo, ^principal, ^owner,
                     ^connection}

    refute_received {:source_resolution_sql, _, _, _, _, _, _}
  end

  defp assert_selected_only(c, operation, member) do
    select = if operation == :attachment, do: :select_attachment, else: :select_citation
    principal = c.session.principal_id
    owner = c.session.vault_id

    assert_received {:source_resolution_sql, ^select, ^member, RequestRepo, ^principal, ^owner,
                     _connection}

    refute_received {:source_resolution_sql, _, _, _, _, _, _}
  end

  defp prepare_authority!(owner) do
    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "UPDATE core.vaults SET locked=false WHERE id=$1", [owner])

      for capability <- ["note.write", "note.read", "asset.read"] do
        query!(
          MigrationRepo,
          "INSERT INTO core.capabilities(id,name) VALUES($1,$2) ON CONFLICT(name) DO NOTHING",
          [KnowledgeFixtures.uuid(), capability]
        )
      end
    end)
  end

  defp create_principal!(owner) do
    ids = %{
      person_id: Ecto.UUID.generate(),
      account_id: Ecto.UUID.generate(),
      credential_id: Ecto.UUID.generate(),
      principal_id: Ecto.UUID.generate(),
      session_id: Ecto.UUID.generate(),
      vault_id: text(owner)
    }

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO identity.people(id,display_name) VALUES($1,'Source resolution principal')",
        [dump(ids.person_id)]
      )

      query!(MigrationRepo, "INSERT INTO identity.accounts(id,person_id) VALUES($1,$2)", [
        dump(ids.account_id),
        dump(ids.person_id)
      ])

      query!(
        MigrationRepo,
        "INSERT INTO identity.credentials(id,account_id,normalized_login,verifier) VALUES($1,$2,$3,'verifier')",
        [dump(ids.credential_id), dump(ids.account_id), "source-#{ids.principal_id}@example.test"]
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

      for capability <- ["note.write", "note.read", "asset.read"] do
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

  defp revoke!(principal, capability) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE core.principal_capabilities a SET revoked_at=CURRENT_TIMESTAMP FROM core.capabilities c WHERE a.capability_id=c.id AND a.principal_id=$1 AND a.vault_id=$2 AND c.name=$3",
        [dump(principal.principal_id), dump(principal.vault_id), capability]
      )
    end)
  end

  defp increment_epoch!(principal, :principal),
    do:
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "UPDATE identity.principals SET authorization_epoch=authorization_epoch+1 WHERE id=$1",
          [dump(principal.principal_id)]
        )
      end)

  defp increment_epoch!(principal, :owner),
    do:
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "UPDATE core.vaults SET authorization_epoch=authorization_epoch+1 WHERE id=$1",
          [dump(principal.vault_id)]
        )
      end)

  defp seed_metadata!(source, filename) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.asset_metadata(id,asset_id,resource_version_id,vault_id,classification,projection_version,original_filename,declared_media_type,detected_media_type,plaintext_byte_size,extraction_state,completed_at) VALUES($1,$2,$3,$4,'private',1,$5,'text/plain','text/plain',12,'completed',CURRENT_TIMESTAMP)",
        [
          KnowledgeFixtures.uuid(),
          source.asset_id,
          source.resource_version_id,
          source.vault_id,
          filename
        ]
      )
    end)
  end

  defp set_deleted!(resource, deleted?) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.resources SET deleted_at=CASE WHEN $2 THEN clock_timestamp() ELSE NULL END WHERE id=$1",
        [resource, deleted?]
      )
    end)
  end

  defp advance_heads!(c) do
    advance_document!(c)
    version = KnowledgeFixtures.uuid()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',1)",
        [version, c.target_note.resource_id, c.source.vault_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.note_versions(resource_version_id,resource_id,vault_id,classification,title,markdown,created_by_principal_id,parent_version_id,inserted_at) VALUES($1,$2,$3,'private','Later Note','Later body',$4,$5,CURRENT_TIMESTAMP)",
        [
          version,
          c.target_note.resource_id,
          c.source.vault_id,
          c.source.principal_id,
          c.target_note.resource_version_id
        ]
      )

      query!(
        MigrationRepo,
        "UPDATE content.resources SET current_version_id=$1,title='Later Note' WHERE id=$2",
        [version, c.target_note.resource_id]
      )

      # The unchanged resources_note_head_check requires an Asset's head ID
      # to remain NULL. Its mutable Resource.title is not pinned metadata.
      query!(
        MigrationRepo,
        "UPDATE content.resources SET title='Mutable Asset head title' WHERE id=$1",
        [c.source.resource_id]
      )
    end)
  end

  defp advance_document!(c) do
    version = KnowledgeFixtures.uuid()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',1)",
        [version, c.document.resource_id, c.source.vault_id]
      )

      KnowledgeFixtures.insert_typed!(%{
        c.document
        | resource_version_id: version,
          title: "Later Document"
      })

      query!(
        MigrationRepo,
        "UPDATE content.resources SET current_version_id=$1,title='Later Document' WHERE id=$2",
        [version, c.document.resource_id]
      )
    end)
  end

  defp two_fragment_document!(source) do
    document = KnowledgeFixtures.document!(source)

    fragments =
      for {body, ordinal, start_line, end_line} <- [
            {"Unrelated fragment must stay unreturned", 0, 1, 1},
            {"Selected evidence\nSecond selected line", 1, 2, 3}
          ] do
        {:ok, fragment} =
          DocumentFragment.new(%{
            resource_id: text(document.resource_id),
            resource_version_id: text(document.resource_version_id),
            owner_scope_id: text(source.vault_id),
            classification: :private,
            ordinal: ordinal,
            text: body,
            locator: %{version: 1, kind: "text", start_line: start_line, end_line: end_line}
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

    {document, Enum.at(fragments, 1)}
  end

  defp text(id), do: Ecto.UUID.load!(id)
  defp dump(id), do: Ecto.UUID.dump!(id)
end
