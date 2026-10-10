defmodule Singularity.Runtime.OrganizationIntegrationTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.{Error, Tag}

  alias Singularity.Runtime.{
    Api,
    AuthorizationDependencies,
    Authorize,
    OperationScope,
    SessionContext
  }

  alias Singularity.Runtime.DTO.Session
  alias Singularity.Runtime.Organization.Operations

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
    OrganizationRepository,
    RelationshipRepository,
    TagRepository
  }

  @capabilities ~w(note.read note.write asset.read asset.write)
  @operations ~w(attach_tag detach_tag list_resource_tags browse_resources_by_tag relate_resource unrelate_resource list_outgoing_relationships list_backlinks)a

  # Real OperationScope, Authorize, IdentityRepository, RLS and organization SQL
  # with permanent web grants. Only the established unlocked-lease fixture is
  # a test adapter: this is NOT live custody, byte delivery or E2E acceptance.
  defmodule Custodian do
    def assert_unlocked(_owner, _session, _principal, _scope, _principal_epoch, _scope_epoch),
      do: :ok
  end

  # Read-only observers; every authorization and persistence result still comes
  # from its real implementation. They cannot supply authority or SQL results.
  defmodule ObservedAuthorize do
    def check(_owner, dependencies, repo, session, requirement) do
      unless Enum.sort(Map.keys(requirement)) ==
               Enum.sort([
                 :vault_id,
                 :classification,
                 :requires_unlocked?,
                 :required_capability,
                 :principal_authorization_epoch,
                 :vault_authorization_epoch
               ]) and
               requirement.vault_id == session.vault_id and requirement.classification == :private and
               requirement.principal_authorization_epoch == session.principal_authorization_epoch and
               requirement.vault_authorization_epoch == session.vault_authorization_epoch,
             do: raise("organization observer requires exact live authorization bindings")

      Singularity.Runtime.OrganizationIntegrationTest.observe(
        repo,
        session.principal_id,
        session.vault_id,
        :authorize,
        requirement.required_capability
      )

      Authorize.check(dependencies, repo, session, requirement)
    end
  end

  defmodule ObservedMetadata do
    def resources_in_scope(context, ids) do
      observe(context, :resources, ids)
      OrganizationRepository.resources_in_scope(context, ids)
    end

    def relationship_in_scope(context, id) do
      observe(context, :relationship, id)
      OrganizationRepository.relationship_in_scope(context, id)
    end

    defp observe(context, stage, selector) do
      unless Enum.sort(Map.keys(context)) ==
               Enum.sort([:repo, :principal_id, :owner_scope_id, :correlation_id]),
             do: raise("organization observer requires the exact metadata context")

      Singularity.Runtime.OrganizationIntegrationTest.observe(
        context.repo,
        context.principal_id,
        context.owner_scope_id,
        stage,
        selector
      )
    end
  end

  defmodule ObservedTags do
    def resolve_in_scope(context, tag) do
      Singularity.Runtime.OrganizationIntegrationTest.observe(
        context.repo,
        context.principal_id,
        context.owner_scope_id,
        :resolve_tag,
        tag.normalized_key
      )

      TagRepository.resolve_in_scope(context, tag)
    end

    def attach_in_scope(context, resource, tag) do
      Singularity.Runtime.OrganizationIntegrationTest.observe(
        context.repo,
        context.principal_id,
        context.owner_scope_id,
        :attach_tag,
        {resource, tag}
      )

      TagRepository.attach_in_scope(context, resource, tag)
    end
  end

  @doc false
  def observe(repo, principal, owner, stage, selector) do
    unless repo == RequestRepo and repo.checked_out?() and repo.in_transaction?(),
      do: raise("organization observer requires the pinned scoped request transaction")

    lock_key = "singularity:authorization:" <> principal <> ":" <> owner

    %{rows: [[^principal, ^owner, connection, true]]} =
      query!(
        repo,
        """
        SELECT current_setting('singularity.principal_id',true),
          current_setting('singularity.vault_id',true), pg_backend_pid(),
          EXISTS(SELECT 1 FROM pg_locks WHERE pid=pg_backend_pid() AND locktype='advisory'
            AND mode='ShareLock' AND granted AND objsubid=1
            AND classid::bigint=((hashtextextended($1::text,0)>>32)&4294967295::bigint)
            AND objid::bigint=(hashtextextended($1::text,0)&4294967295::bigint))
        """,
        [lock_key]
      )

    send(self(), {:organization_sql, stage, selector, repo, principal, owner, connection})
  end

  setup do
    source = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    other_note = KnowledgeFixtures.note!(source)
    document = KnowledgeFixtures.document!(source)
    prepare_authority!(source.vault_id)
    principal = create_principal!(source.vault_id, @capabilities)

    {:ok, authorization} =
      AuthorizationDependencies.new(%{store: IdentityRepository, custodian: {Custodian, self()}})

    runtime = %{
      authorization: authorization,
      authorization_lock: AuthorizationLock,
      authorizer: Authorize,
      audit: AuditSink,
      operation_scope: OperationScope,
      request_repo: RequestRepo,
      scoped_repo: ScopedRepo,
      vault_lock: VaultLock,
      organization_repository: OrganizationRepository,
      tag_repository: TagRepository,
      relationship_repository: RelationshipRepository,
      organization: Singularity.Domains.Organization
    }

    %{
      source: source,
      note: note,
      other_note: other_note,
      document: document,
      runtime: runtime,
      principal: principal,
      session: session(principal)
    }
  end

  test "Note-only authority performs every Note organization operation without Asset capabilities",
       c do
    assert %{rows: [["singularity_web", true, true, true, false]]} =
             query!(
               RequestRepo,
               "SELECT current_user,has_table_privilege(current_user,'content.relationships','SELECT'),has_table_privilege(current_user,'content.relationships','INSERT'),has_table_privilege(current_user,'content.relationships','DELETE'),has_table_privilege(current_user,'content.relationships','UPDATE')",
               []
             )

    assert %{rows: [[true, true, false]]} =
             query!(
               RequestRepo,
               "SELECT has_table_privilege(current_user,'content.tags','SELECT'),has_table_privilege(current_user,'content.tags','INSERT'),has_table_privilege(current_user,'content.tags','UPDATE')",
               []
             )

    principal = create_principal!(c.source.vault_id, ~w(note.read note.write))
    actor = session(principal)
    resource = text(c.note.resource_id)
    target = text(c.other_note.resource_id)
    assert {:ok, tag} = Operations.attach_tag(c.runtime, actor, resource, %{name: "Note only"})
    assert_item(tag, [:tag_id, :display_value])
    assert tag.display_value == "Note only"
    assert {:ok, page} = Operations.list_resource_tags(c.runtime, actor, resource)
    assert_page(page, [tag], nil)
    assert {:ok, browse} = Operations.browse_resources_by_tag(c.runtime, actor, tag.tag_id, %{})
    assert page_maps(browse) == [%{resource_id: resource, kind: :note}]

    assert {:ok, edge} =
             Operations.relate_resource(c.runtime, actor, resource, %{
               target_resource_id: target,
               type: :references
             })

    assert_edge(edge, resource, target, nil, :references)

    assert {:ok, outgoing} =
             Operations.list_outgoing_relationships(c.runtime, actor, resource, %{})

    assert_page(outgoing, [edge], nil)
    assert {:ok, incoming} = Operations.list_backlinks(c.runtime, actor, target, %{})
    assert_page(incoming, [edge], nil)
    assert :ok = Operations.unrelate_resource(c.runtime, actor, edge.relationship_id)
    assert :ok = Operations.detach_tag(c.runtime, actor, resource, tag.tag_id)
    assert {:ok, empty} = Operations.list_resource_tags(c.runtime, actor, resource)
    assert_page(empty, [], nil)
  end

  test "Asset-only authority operates Asset and Document while locked but never admits Note by fallback",
       c do
    principal = create_principal!(c.source.vault_id, ~w(asset.read asset.write))
    set_locked!(c.source.vault_id, true)
    actor = %{session(principal) | unlocked?: false}

    for {row, target, kind} <- [{c.source, c.document, :asset}, {c.document, c.source, :document}] do
      resource = text(row.resource_id)
      target_id = text(target.resource_id)

      assert {:ok, tag} =
               Operations.attach_tag(c.runtime, actor, resource, %{name: "Locked #{kind}"})

      assert {:ok, page} = Operations.list_resource_tags(c.runtime, actor, resource, %{})
      assert_page(page, [tag], nil)
      assert {:ok, browse} = Operations.browse_resources_by_tag(c.runtime, actor, tag.tag_id, %{})
      assert page_maps(browse) == [%{resource_id: resource, kind: kind}]

      assert {:ok, edge} =
               Operations.relate_resource(c.runtime, actor, resource, %{
                 target_resource_id: target_id,
                 type: :derived_from
               })

      assert_edge(edge, resource, target_id, nil, :derived_from)

      assert {:ok, outgoing} =
               Operations.list_outgoing_relationships(c.runtime, actor, resource, %{})

      assert_page(outgoing, [edge], nil)
      assert {:ok, incoming} = Operations.list_backlinks(c.runtime, actor, target_id, %{})
      assert_page(incoming, [edge], nil)
      assert :ok = Operations.unrelate_resource(c.runtime, actor, edge.relationship_id)
      assert :ok = Operations.detach_tag(c.runtime, actor, resource, tag.tag_id)
    end

    before = knowledge_state(c.source.vault_id)
    note = text(c.note.resource_id)

    assert Operations.attach_tag(c.runtime, actor, note, %{name: "Denied Note label"}) ==
             {:error, Error.new(:forbidden)}

    assert Operations.list_resource_tags(c.runtime, actor, note) ==
             {:error, Error.new(:forbidden)}

    assert Operations.relate_resource(c.runtime, actor, text(c.source.resource_id), %{
             target_resource_id: note,
             type: :references
           }) == {:error, Error.new(:forbidden)}

    assert knowledge_state(c.source.vault_id) == before
  end

  test "read-only cannot mutate and write-only cannot read or relate without endpoint read authority",
       c do
    reader = session(create_principal!(c.source.vault_id, ~w(note.read)))
    writer = session(create_principal!(c.source.vault_id, ~w(note.write)))
    resource = text(c.note.resource_id)
    tag = seed_tag!(c.source, "Existing")
    seed_membership!(c.source, c.note, tag.tag_id)
    before = knowledge_state(c.source.vault_id)
    assert {:ok, page} = Operations.list_resource_tags(c.runtime, reader, resource)
    assert page_maps(page) == [%{tag_id: tag.tag_id, display_value: tag.display_value}]

    assert Operations.attach_tag(c.runtime, reader, resource, %{name: "Denied new tag"}) ==
             {:error, Error.new(:forbidden)}

    assert Operations.detach_tag(c.runtime, reader, resource, tag.tag_id) ==
             {:error, Error.new(:forbidden)}

    assert Operations.list_resource_tags(c.runtime, writer, resource) ==
             {:error, Error.new(:forbidden)}

    assert Operations.relate_resource(c.runtime, writer, resource, %{
             target_resource_id: text(c.other_note.resource_id),
             type: :references
           }) == {:error, Error.new(:forbidden)}

    assert knowledge_state(c.source.vault_id) == before

    assert {:ok, _tag} =
             Operations.attach_tag(c.runtime, writer, resource, %{name: "Write allowed"})
  end

  test "relationships require actual source write and both actual endpoint read capabilities",
       c do
    for {source, target, missing} <- [
          {c.note, c.source, "note.write"},
          {c.note, c.source, "note.read"},
          {c.note, c.document, "asset.read"},
          {c.source, c.note, "asset.write"},
          {c.document, c.note, "asset.read"},
          {c.document, c.note, "note.read"}
        ] do
      principal = create_principal!(c.source.vault_id, @capabilities -- [missing])
      before = knowledge_state(c.source.vault_id)

      assert Operations.relate_resource(
               c.runtime,
               session(principal),
               text(source.resource_id),
               %{target_resource_id: text(target.resource_id), type: :references}
             ) == {:error, Error.new(:forbidden)}

      assert knowledge_state(c.source.vault_id) == before
    end

    assert {:ok, edge} =
             relate(c, c.note, c.document, :references, text(c.document.resource_version_id))

    assert_edge(
      edge,
      text(c.note.resource_id),
      text(c.document.resource_id),
      text(c.document.resource_version_id),
      :references
    )
  end

  test "relationship natural-key replay retains UUID and nullable pin with exact ID-only audits",
       c do
    resource = text(c.note.resource_id)
    target = text(c.other_note.resource_id)
    assert {:ok, first} = relate(c, c.note, c.other_note, :references, nil)
    after_first = knowledge_state(c.source.vault_id)
    audits_after_first = all_audits(c.source.vault_id)
    assert {:ok, ^first} = relate(c, c.note, c.other_note, :references, nil)
    assert knowledge_state(c.source.vault_id) == after_first
    assert all_audits(c.source.vault_id) == audits_after_first

    assert Operations.relate_resource(c.runtime, c.session, resource, %{
             target_resource_id: target,
             target_resource_version_id: text(c.other_note.resource_version_id),
             type: :references
           }) == {:error, Error.new(:conflict)}

    assert knowledge_state(c.source.vault_id) == after_first

    assert {:ok, reverse} =
             relate(c, c.other_note, c.note, :references, text(c.note.resource_version_id))

    refute reverse.relationship_id == first.relationship_id
    assert_edge(reverse, target, resource, text(c.note.resource_version_id), :references)

    assert_mutation_audit!(c, "knowledge.related", first.relationship_id, %{
      "source_resource_id" => resource,
      "target_resource_id" => target,
      "type" => "references"
    })

    assert :ok = Operations.unrelate_resource(c.runtime, c.session, first.relationship_id)
    after_delete = knowledge_state(c.source.vault_id)
    audits_after_delete = all_audits(c.source.vault_id)
    assert :ok = Operations.unrelate_resource(c.runtime, c.session, first.relationship_id)
    assert knowledge_state(c.source.vault_id) == after_delete
    assert all_audits(c.source.vault_id) == audits_after_delete

    assert_mutation_audit!(c, "knowledge.unrelated", first.relationship_id, %{
      "source_resource_id" => resource,
      "target_resource_id" => target,
      "type" => "references"
    })

    assert_mutation_audit!(c, "knowledge.related", reverse.relationship_id, %{
      "source_resource_id" => target,
      "target_resource_id" => resource,
      "target_resource_version_id" => text(c.note.resource_version_id),
      "type" => "references"
    })
  end

  test "Unicode tag replay preserves first spelling and UUID without extra mutation audit", c do
    resource = text(c.note.resource_id)
    assert {:ok, first} = Operations.attach_tag(c.runtime, c.session, resource, %{name: "Straße"})
    assert first.display_value == "Straße"
    assert_item(first, [:tag_id, :display_value])
    after_first = knowledge_state(c.source.vault_id)
    audits_after_first = all_audits(c.source.vault_id)

    assert {:ok, ^first} =
             Operations.attach_tag(c.runtime, c.session, resource, %{name: "STRASSE"})

    assert knowledge_state(c.source.vault_id) == after_first
    assert all_audits(c.source.vault_id) == audits_after_first
    assert_mutation_audit!(c, "knowledge.tag_created", first.tag_id, %{})

    assert_mutation_audit!(c, "knowledge.tag_attached", first.tag_id, %{"resource_id" => resource})

    assert :ok = Operations.detach_tag(c.runtime, c.session, resource, first.tag_id)
    after_detach = knowledge_state(c.source.vault_id)
    audits_after_detach = all_audits(c.source.vault_id)
    assert :ok = Operations.detach_tag(c.runtime, c.session, resource, first.tag_id)
    assert knowledge_state(c.source.vault_id) == after_detach
    assert all_audits(c.source.vault_id) == audits_after_detach

    assert_mutation_audit!(c, "knowledge.tag_detached", first.tag_id, %{"resource_id" => resource})

    assert Enum.map(knowledge_audits(c.source.vault_id), &hd/1) ==
             ["knowledge.tag_created", "knowledge.tag_attached", "knowledge.tag_detached"]

    refute inspect(knowledge_audits(c.source.vault_id)) =~ "Straße"
  end

  test "resource tag pages return all 105 memberships with bounded ordered unique pages", c do
    tags =
      for index <- 1..105 do
        tag = seed_tag!(c.source, "Page tag #{index}")
        seed_membership!(c.source, c.note, tag.tag_id)
        %{tag_id: tag.tag_id, display_value: tag.display_value}
      end

    before = knowledge_state(c.source.vault_id)
    items = collect(c, :list_resource_tags, text(c.note.resource_id), 13)
    assert items == Enum.sort_by(tags, & &1.tag_id)
    assert length(items) == 105
    assert Enum.uniq_by(items, & &1.tag_id) == items
    assert knowledge_state(c.source.vault_id) == before
  end

  test "tag browse pages exceed 100 and exclude tombstoned or currently denied kinds before admission",
       c do
    notes = seed_notes!(c.source, 105)
    tag = seed_tag!(c.source, "Large browse")
    for row <- notes ++ [c.source, c.document], do: seed_membership!(c.source, row, tag.tag_id)
    [deleted | live] = notes
    set_deleted!(deleted.resource_id, true)
    note_actor = session(create_principal!(c.source.vault_id, ~w(note.read)))
    restricted = %{c | session: note_actor}
    expected = Enum.map(live, &%{resource_id: text(&1.resource_id), kind: :note})
    assert collect(restricted, :browse_resources_by_tag, tag.tag_id, 17) == expected

    full =
      expected ++
        [
          %{resource_id: text(c.source.resource_id), kind: :asset},
          %{resource_id: text(c.document.resource_id), kind: :document}
        ]

    assert collect(c, :browse_resources_by_tag, tag.tag_id, 17) ==
             Enum.sort_by(full, & &1.resource_id)

    set_deleted!(deleted.resource_id, false)
    restored = Enum.map(notes, &%{resource_id: text(&1.resource_id), kind: :note})
    assert collect(restricted, :browse_resources_by_tag, tag.tag_id, 17) == restored
  end

  test "outgoing and incoming pages return every one of 105 directed edges without legacy truncation",
       c do
    notes = seed_notes!(c.source, 105)
    outgoing = seed_edges!(c, notes, :outgoing)
    incoming = seed_edges!(c, notes, :incoming)
    resource = text(c.note.resource_id)
    before = knowledge_state(c.source.vault_id)
    assert collect(c, :list_outgoing_relationships, resource, 17) == outgoing
    assert collect(c, :list_backlinks, resource, 17) == incoming
    assert length(outgoing) == 105
    assert length(incoming) == 105
    assert knowledge_state(c.source.vault_id) == before
  end

  test "continuations recalculate current allowed kinds and never inherit cursor capability snapshots",
       c do
    notes = seed_notes!(c.source, 3)
    tag = seed_tag!(c.source, "Changing kinds")
    for row <- notes ++ [c.source, c.document], do: seed_membership!(c.source, row, tag.tag_id)

    assert {:ok, first} =
             Operations.browse_resources_by_tag(c.runtime, c.session, tag.tag_id, %{limit: 1})

    assert [%{resource_id: after_id}] =
             page_maps(first) |> Enum.map(&Map.take(&1, [:resource_id]))

    assert is_binary(first.next_cursor)
    revoke!(c.principal, "asset.read")

    expected =
      notes
      |> Enum.map(&%{resource_id: text(&1.resource_id), kind: :note})
      |> Enum.filter(&(&1.resource_id > after_id))

    assert collect(c, :browse_resources_by_tag, tag.tag_id, 1, first.next_cursor) == expected

    assert Operations.list_resource_tags(c.runtime, c.session, text(c.source.resource_id)) ==
             {:error, Error.new(:forbidden)}

    grant!(c.principal, "asset.read")

    all =
      Enum.map(notes, &%{resource_id: text(&1.resource_id), kind: :note}) ++
        [
          %{resource_id: text(c.source.resource_id), kind: :asset},
          %{resource_id: text(c.document.resource_id), kind: :document}
        ]

    expected_all =
      all |> Enum.filter(&(&1.resource_id > after_id)) |> Enum.sort_by(& &1.resource_id)

    assert collect(c, :browse_resources_by_tag, tag.tag_id, 1, first.next_cursor) == expected_all
    revoke!(c.principal, "note.read")
    revoke!(c.principal, "asset.read")

    assert Operations.browse_resources_by_tag(c.runtime, c.session, tag.tag_id, %{
             limit: 1,
             cursor: first.next_cursor
           }) == {:error, Error.new(:forbidden)}
  end

  for epoch <- [:principal, :owner] do
    @epoch epoch
    test "#{@epoch} epoch changes deny stale continuation and allow only a fresh bound session",
         c do
      tag = seed_tag!(c.source, "Epoch page")
      notes = seed_notes!(c.source, 3)
      for row <- notes, do: seed_membership!(c.source, row, tag.tag_id)

      assert {:ok, first} =
               Operations.browse_resources_by_tag(c.runtime, c.session, tag.tag_id, %{limit: 1})

      assert is_binary(first.next_cursor)
      increment_epoch!(c.principal, @epoch)

      assert Operations.browse_resources_by_tag(c.runtime, c.session, tag.tag_id, %{
               limit: 1,
               cursor: first.next_cursor
             }) == {:error, Error.new(:forbidden)}

      fresh = %{c | session: session(c.principal)}
      expected = notes |> tl() |> Enum.map(&%{resource_id: text(&1.resource_id), kind: :note})

      assert collect(fresh, :browse_resources_by_tag, tag.tag_id, 1, first.next_cursor) ==
               expected
    end
  end

  test "real cursors bind owner selector operation and edge direction and reject malformed envelopes",
       c do
    tags =
      for index <- 1..3 do
        tag = seed_tag!(c.source, "Cursor #{index}")
        seed_membership!(c.source, c.note, tag.tag_id)
        tag
      end

    resource = text(c.note.resource_id)

    assert {:ok, first} =
             Operations.list_resource_tags(c.runtime, c.session, resource, %{limit: 1})

    assert is_binary(first.next_cursor)
    params = %{limit: 1, cursor: first.next_cursor}

    assert Operations.list_resource_tags(
             c.runtime,
             c.session,
             text(c.other_note.resource_id),
             params
           ) == {:error, Error.new(:invalid)}

    assert Operations.browse_resources_by_tag(c.runtime, c.session, resource, params) ==
             {:error, Error.new(:invalid)}

    assert Operations.list_resource_tags(c.runtime, c.session, resource, %{
             params
             | cursor: "!" <> first.next_cursor
           }) == {:error, Error.new(:invalid)}

    other = KnowledgeFixtures.source!()
    prepare_authority!(other.vault_id)
    principal = create_principal!(other.vault_id, @capabilities)
    selected_tag = hd(tags).tag_id
    seed_membership!(c.source, c.other_note, selected_tag)

    assert {:ok, browse} =
             Operations.browse_resources_by_tag(c.runtime, c.session, selected_tag, %{limit: 1})

    assert is_binary(browse.next_cursor)
    # Same operation and selector: only the authenticated owner binding differs.
    assert Operations.browse_resources_by_tag(c.runtime, session(principal), selected_tag, %{
             limit: 1,
             cursor: browse.next_cursor
           }) == {:error, Error.new(:invalid)}

    notes = seed_notes!(c.source, 3)
    seed_edges!(c, notes, :outgoing)
    seed_edges!(c, notes, :incoming)

    assert {:ok, edges} =
             Operations.list_outgoing_relationships(c.runtime, c.session, resource, %{limit: 1})

    assert is_binary(edges.next_cursor)

    assert Operations.list_backlinks(c.runtime, c.session, resource, %{
             limit: 1,
             cursor: edges.next_cursor
           }) == {:error, Error.new(:invalid)}
  end

  test "missing and foreign selected unrelate are no-ops without knowledge audits or row effects",
       c do
    other = KnowledgeFixtures.source!()
    prepare_authority!(other.vault_id)
    principal = create_principal!(other.vault_id, @capabilities)
    foreign_note = KnowledgeFixtures.note!(other)
    foreign_target = KnowledgeFixtures.note!(other)
    foreign = %{c | source: other, principal: principal, session: session(principal)}
    assert {:ok, edge} = relate(foreign, foreign_note, foreign_target, :references, nil)
    own_before = knowledge_state(c.source.vault_id)
    foreign_before = knowledge_state(other.vault_id)

    for id <- [Ecto.UUID.generate(), edge.relationship_id],
        do: assert(Operations.unrelate_resource(c.runtime, c.session, id) == :ok)

    assert knowledge_state(c.source.vault_id) == own_before
    assert knowledge_state(other.vault_id) == foreign_before

    assert Operations.list_resource_tags(c.runtime, c.session, text(foreign_note.resource_id)) ==
             {:error, Error.new(:not_found)}

    assert Operations.browse_resources_by_tag(c.runtime, c.session, Ecto.UUID.generate(), %{}) ==
             {:error, Error.new(:not_found)}
  end

  test "tombstoned selected source prevents unrelate until restore and preserves exact pinned identity",
       c do
    pin = text(c.other_note.resource_version_id)
    assert {:ok, edge} = relate(c, c.note, c.other_note, :derived_from, pin)
    set_deleted!(c.note.resource_id, true)
    before = knowledge_state(c.source.vault_id)

    assert Operations.unrelate_resource(c.runtime, c.session, edge.relationship_id) ==
             {:error, Error.new(:not_found)}

    assert knowledge_state(c.source.vault_id) == before

    assert {:ok, hidden} =
             Operations.list_backlinks(c.runtime, c.session, text(c.other_note.resource_id), %{})

    assert_page(hidden, [], nil)
    set_deleted!(c.note.resource_id, false)

    assert {:ok, restored} =
             Operations.list_backlinks(c.runtime, c.session, text(c.other_note.resource_id), %{})

    assert_page(restored, [edge], nil)
    assert :ok = Operations.unrelate_resource(c.runtime, c.session, edge.relationship_id)

    assert_mutation_audit!(c, "knowledge.unrelated", edge.relationship_id, %{
      "source_resource_id" => text(c.note.resource_id),
      "target_resource_id" => text(c.other_note.resource_id),
      "target_resource_version_id" => pin,
      "type" => "derived_from"
    })
  end

  test "successful Asset write entry cannot delete a selected Note edge without current Note write",
       c do
    assert {:ok, edge} = relate(c, c.note, c.other_note, :references, nil)
    principal = create_principal!(c.source.vault_id, ~w(note.read asset.read asset.write))
    before = knowledge_state(c.source.vault_id)

    assert Operations.unrelate_resource(c.runtime, session(principal), edge.relationship_id) ==
             {:error, Error.new(:forbidden)}

    assert knowledge_state(c.source.vault_id) == before
    revoke!(c.principal, "note.write")

    assert Operations.unrelate_resource(c.runtime, c.session, edge.relationship_id) ==
             {:error, Error.new(:forbidden)}

    assert knowledge_state(c.source.vault_id) == before
  end

  test "entry exact-kind checks metadata and mutation share one live authorization-locked SQL connection",
       c do
    runtime = %{
      c.runtime
      | authorizer: {ObservedAuthorize, self()},
        organization_repository: ObservedMetadata,
        tag_repository: ObservedTags
    }

    resource = text(c.note.resource_id)
    assert {:ok, tag} = Operations.attach_tag(runtime, c.session, resource, %{name: "Observed"})
    principal = c.principal.principal_id
    owner = c.principal.vault_id
    assert [entry, metadata, exact_kind, resolve, attach] = observations()

    assert {:organization_sql, :authorize, "note.write", RequestRepo, ^principal, ^owner,
            connection} = entry

    assert {:organization_sql, :resources, [^resource], RequestRepo, ^principal, ^owner,
            ^connection} = metadata

    assert {:organization_sql, :authorize, "note.write", RequestRepo, ^principal, ^owner,
            ^connection} = exact_kind

    assert {:organization_sql, :resolve_tag, "observed", RequestRepo, ^principal, ^owner,
            ^connection} = resolve

    assert {:organization_sql, :attach_tag, {^resource, selected_tag}, RequestRepo, ^principal,
            ^owner, ^connection} = attach

    assert selected_tag == tag.tag_id
    assert is_integer(connection)
    refute RequestRepo.in_transaction?()

    assert %{rows: [[principal_guc, owner_guc]]} =
             query!(
               RequestRepo,
               "SELECT current_setting('singularity.principal_id',true),current_setting('singularity.vault_id',true)",
               []
             )

    assert principal_guc in [nil, ""]
    assert owner_guc in [nil, ""]
  end

  test "public Api owner-free results traverse all eight actual scoped organization operations",
       c do
    config = api_config(c.runtime)
    public = struct!(Session, Map.from_struct(c.session))
    resource = text(c.note.resource_id)
    target = text(c.other_note.resource_id)
    assert {:ok, tag} = Api.attach_tag(config, public, resource, %{name: "Public real SQL"})
    assert_item(tag, [:tag_id, :display_value])
    assert {:ok, tags} = Api.list_resource_tags(config, public, resource, %{})
    assert_page(tags, [tag], nil)
    assert {:ok, resources} = Api.browse_resources_by_tag(config, public, tag.tag_id, %{})
    assert page_maps(resources) == [%{resource_id: resource, kind: :note}]

    assert {:ok, edge} =
             Api.relate_resource(config, public, resource, %{
               target_resource_id: target,
               target_resource_version_id: text(c.other_note.resource_version_id),
               type: :related_to
             })

    assert_edge(edge, resource, target, text(c.other_note.resource_version_id), :related_to)
    assert {:ok, outgoing} = Api.list_outgoing_relationships(config, public, resource, %{})
    assert_page(outgoing, [edge], nil)
    assert {:ok, incoming} = Api.list_backlinks(config, public, target, %{})
    assert_page(incoming, [edge], nil)
    assert :ok = Api.unrelate_resource(config, public, edge.relationship_id)
    assert :ok = Api.detach_tag(config, public, resource, tag.tag_id)

    assert Api.attach_tag(config, public, Ecto.UUID.generate(), %{name: "Missing"}) ==
             {:error, :not_found}
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

  defp create_principal!(owner, capabilities) do
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
        "INSERT INTO identity.people(id,display_name) VALUES($1,'Organization principal')",
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
          "organization-#{ids.principal_id}@example.test"
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

      for capability <- capabilities do
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

  defp grant!(principal, capability),
    do:
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name=$3 ON CONFLICT(principal_id,vault_id,capability_id) DO UPDATE SET revoked_at=NULL",
          [dump(principal.principal_id), dump(principal.vault_id), capability]
        )
      end)

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

  defp set_locked!(owner, locked?),
    do:
      Fixtures.with_owner(fn ->
        query!(MigrationRepo, "UPDATE core.vaults SET locked=$2 WHERE id=$1", [owner, locked?])
      end)

  defp set_deleted!(resource, deleted?),
    do:
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "UPDATE content.resources SET deleted_at=CASE WHEN $2 THEN CURRENT_TIMESTAMP ELSE NULL END WHERE id=$1",
          [resource, deleted?]
        )
      end)

  defp seed_tag!(source, display) do
    assert {:ok, tag} =
             Tag.new(%{
               tag_id: Ecto.UUID.generate(),
               owner_scope_id: text(source.vault_id),
               classification: :private,
               display_value: display
             })

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.tags(id,vault_id,classification,display_value,normalized_key,created_by_principal_id,inserted_at) VALUES($1,$2,'private',$3,$4,$5,CURRENT_TIMESTAMP)",
        [
          dump(tag.tag_id),
          source.vault_id,
          tag.display_value,
          tag.normalized_key,
          source.principal_id
        ]
      )
    end)

    tag
  end

  defp seed_membership!(source, row, tag),
    do:
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "INSERT INTO content.resource_tags(resource_id,tag_id,vault_id,classification,inserted_at) VALUES($1,$2,$3,'private',CURRENT_TIMESTAMP)",
          [row.resource_id, dump(tag), source.vault_id]
        )
      end)

  defp seed_notes!(source, count) do
    resources = Ecto.UUID.generate() |> String.slice(0, 24)
    versions = Ecto.UUID.generate() |> String.slice(0, 24)

    Fixtures.with_owner(fn ->
      for index <- 1..count do
        row = %{
          resource_id: dump(ordered_id(resources, index)),
          resource_version_id: dump(ordered_id(versions, index)),
          vault_id: source.vault_id
        }

        KnowledgeFixtures.insert_note!(MigrationRepo, source, row)
        row
      end
    end)
  end

  defp seed_edges!(c, notes, direction) do
    prefix = Ecto.UUID.generate() |> String.slice(0, 24)

    Fixtures.with_owner(fn ->
      for {row, index} <- Enum.with_index(notes, 1) do
        {source, target, pin} =
          if direction == :outgoing,
            do: {c.note.resource_id, row.resource_id, row.resource_version_id},
            else: {row.resource_id, c.note.resource_id, c.note.resource_version_id}

        edge = %{
          relationship_id: ordered_id(prefix, index),
          source_resource_id: text(source),
          target_resource_id: text(target),
          target_resource_version_id: text(pin),
          type: :references
        }

        assert Ecto.UUID.cast(edge.relationship_id) == {:ok, edge.relationship_id}

        query!(
          MigrationRepo,
          "INSERT INTO content.relationships(id,vault_id,classification,source_resource_id,target_resource_id,target_resource_version_id,type,created_by_principal_id,inserted_at) VALUES($1,$2,'private',$3,$4,$5,'references',$6,CURRENT_TIMESTAMP)",
          [
            dump(edge.relationship_id),
            c.source.vault_id,
            source,
            target,
            pin,
            c.source.principal_id
          ]
        )

        edge
      end
    end)
  end

  defp relate(c, source, target, type, pin),
    do:
      Operations.relate_resource(c.runtime, c.session, text(source.resource_id), %{
        target_resource_id: text(target.resource_id),
        target_resource_version_id: pin,
        type: type
      })

  defp collect(c, operation, selector, limit, cursor \\ nil, accumulated \\ [], pages \\ 0) do
    assert pages < 120

    assert {:ok, page} =
             apply(Operations, operation, [
               c.runtime,
               c.session,
               selector,
               %{limit: limit, cursor: cursor}
             ])

    assert_item(page, [:items, :next_cursor])
    items = page_maps(page)
    assert length(items) <= limit
    key = page_key(operation)
    ids = Enum.map(items, &Map.fetch!(&1, key))
    assert ids == Enum.sort(ids)
    assert ids == Enum.uniq(ids)

    if accumulated != [] and items != [],
      do: assert(Map.fetch!(List.last(accumulated), key) < Map.fetch!(hd(items), key))

    case page.next_cursor do
      nil ->
        accumulated ++ items

      next when is_binary(next) ->
        assert length(items) == limit
        refute next == cursor
        collect(c, operation, selector, limit, next, accumulated ++ items, pages + 1)
    end
  end

  defp page_key(:list_resource_tags), do: :tag_id
  defp page_key(:browse_resources_by_tag), do: :resource_id
  defp page_key(_edges), do: :relationship_id
  defp page_maps(page), do: Enum.map(page.items, &Map.from_struct/1)

  defp assert_page(page, items, next) do
    assert_item(page, [:items, :next_cursor])
    assert page.__struct__ == Singularity.Runtime.DTO.OrganizationPage
    assert page.items == items
    assert page.next_cursor == next
  end

  defp assert_item(item, keys),
    do: assert(Enum.sort(Map.keys(Map.from_struct(item))) == Enum.sort(keys))

  defp assert_edge(edge, source, target, pin, type) do
    assert_item(edge, [
      :relationship_id,
      :source_resource_id,
      :target_resource_id,
      :target_resource_version_id,
      :type
    ])

    assert edge.__struct__ == Singularity.Runtime.DTO.OrganizationRelationship
    assert Ecto.UUID.cast(edge.relationship_id) == {:ok, edge.relationship_id}

    assert Map.from_struct(edge) == %{
             relationship_id: edge.relationship_id,
             source_resource_id: source,
             target_resource_id: target,
             target_resource_version_id: pin,
             type: type
           }
  end

  defp knowledge_state(owner),
    do:
      Fixtures.with_owner(fn ->
        %{
          tags:
            query!(MigrationRepo, "SELECT * FROM content.tags WHERE vault_id=$1 ORDER BY id", [
              owner
            ]).rows,
          memberships:
            query!(
              MigrationRepo,
              "SELECT * FROM content.resource_tags WHERE vault_id=$1 ORDER BY resource_id,tag_id",
              [owner]
            ).rows,
          relationships:
            query!(
              MigrationRepo,
              "SELECT * FROM content.relationships WHERE vault_id=$1 ORDER BY id",
              [owner]
            ).rows,
          audits: knowledge_audits_query(owner)
        }
      end)

  defp knowledge_audits(owner), do: Fixtures.with_owner(fn -> knowledge_audits_query(owner) end)

  defp all_audits(owner),
    do:
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "SELECT * FROM audit.events WHERE vault_id=$1 ORDER BY occurred_at,id",
          [owner]
        ).rows
      end)

  defp knowledge_audits_query(owner),
    do:
      query!(
        MigrationRepo,
        "SELECT operation,target_id::text,metadata,principal_id::text,vault_id::text FROM audit.events WHERE vault_id=$1 AND operation LIKE 'knowledge.%' ORDER BY occurred_at,id",
        [owner]
      ).rows

  defp assert_mutation_audit!(c, operation, target, metadata) do
    event =
      Fixtures.with_owner(fn ->
        assert_persisted_audit!(MigrationRepo, operation, [target_id: target],
          target_type:
            if(operation in ["knowledge.related", "knowledge.unrelated"],
              do: "relationship",
              else: "tag"
            ),
          result: "completed"
        )
      end)

    assert event.principal_id == c.principal.principal_id
    assert event.vault_id == c.principal.vault_id
    assert event.classification == "private"
    assert event.metadata == metadata
  end

  defp observations(accumulated \\ []) do
    receive do
      {:organization_sql, _, _, _, _, _, _} = observation ->
        observations([observation | accumulated])
    after
      0 -> Enum.reverse(accumulated)
    end
  end

  defp api_config(runtime),
    do:
      Map.new(@operations, fn
        :unrelate_resource ->
          {:unrelate_resource,
           fn actor, selector -> Operations.unrelate_resource(runtime, actor, selector) end}

        operation ->
          {operation,
           fn actor, selector, params ->
             apply(Operations, operation, [runtime, actor, selector, params])
           end}
      end)

  defp ordered_id(prefix, index),
    do: prefix <> String.pad_leading(String.downcase(Integer.to_string(index, 16)), 12, "0")

  defp text(id), do: Ecto.UUID.load!(id)
  defp dump(id), do: Ecto.UUID.dump!(id)
end
