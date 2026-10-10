defmodule Singularity.Storage.Postgres.OrganizationRepositoryTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Storage.{Fixtures, KnowledgeFixtures, MigrationRepo, ScopedRepo}

  @repository Singularity.Storage.Postgres.OrganizationRepository
  @uppercase "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"

  # Actual singularity_web SQL/RLS tests. No Runtime capability, live custody,
  # original-byte or production-activation acceptance is claimed here.
  setup do
    source = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    other_note = KnowledgeFixtures.note!(source)
    document = KnowledgeFixtures.document!(source)

    context = %{
      repo: RequestRepo,
      principal_id: text(source.principal_id),
      owner_scope_id: text(source.vault_id),
      correlation_id: Ecto.UUID.generate()
    }

    %{source: source, note: note, other_note: other_note, document: document, context: context}
  end

  test "metadata uses permanent web SELECT grants without relationship UPDATE privileges", c do
    assert %{rows: [["singularity_web", true, true, false]]} =
             query!(
               RequestRepo,
               "SELECT current_user,has_table_privilege(current_user,'content.resources','SELECT'),has_table_privilege(current_user,'content.relationships','SELECT'),has_table_privilege(current_user,'content.relationships','UPDATE')",
               []
             )

    assert {:ok, [%{resource_id: resource, kind: :note}]} =
             resources(c, [text(c.note.resource_id)])

    assert resource == text(c.note.resource_id)
    edge = seed_edge!(c)
    assert {:ok, ^edge} = selected_edge(c, edge.relationship_id)
  end

  test "singletons return only exact supported live private resource IDs and kinds", c do
    for {row, kind} <- [{c.source, :asset}, {c.note, :note}, {c.document, :document}] do
      expected = [%{resource_id: text(row.resource_id), kind: kind}]
      assert resources(c, [text(row.resource_id)]) == {:ok, expected}
    end
  end

  test "two-resource metadata is complete closed and UUID ordered independent of kind", c do
    for pair <- [
          [{c.source, :asset}, {c.note, :note}],
          [{c.note, :note}, {c.document, :document}],
          [{c.source, :asset}, {c.document, :document}]
        ] do
      expected =
        Enum.map(pair, fn {row, kind} -> %{resource_id: text(row.resource_id), kind: kind} end)
        |> Enum.sort_by(& &1.resource_id)

      ids = Enum.map(expected, & &1.resource_id)
      assert resources(c, ids) == {:ok, expected}
      assert Enum.all?(expected, &(Enum.sort(Map.keys(&1)) == [:kind, :resource_id]))
    end
  end

  test "malformed unbounded duplicate or unsorted resource selectors fail without aborting the SQL transaction",
       c do
    one = text(c.note.resource_id)
    two = text(c.other_note.resource_id)
    ordered = Enum.sort([one, two])

    assert :ok =
             scoped(c, fn context ->
               for ids <- [
                     [],
                     [one, one],
                     Enum.reverse(ordered),
                     ordered ++ [text(c.document.resource_id)],
                     [nil],
                     ["bad"],
                     [@uppercase],
                     [c.note.resource_id],
                     [one | :tail],
                     nil,
                     one,
                     %{resource_id: one}
                   ] do
                 assert call(:resources_in_scope, [context, ids]) == {:error, Error.new(:invalid)}
                 assert %{rows: [[1]]} = query!(context.repo, "SELECT 1", [])
               end

               :ok
             end)
  end

  test "both readers require an existing transaction and both matching principal and owner GUCs",
       c do
    other = KnowledgeFixtures.source!()

    calls = [
      {:resources_in_scope, [[text(c.note.resource_id)]]},
      {:relationship_in_scope, [Ecto.UUID.generate()]}
    ]

    for {method, args} <- calls do
      assert call(method, [c.context | args]) == {:error, Error.new(:invalid)}

      assert {:ok, :ok} =
               RequestRepo.transaction(fn ->
                 assert call(method, [c.context | args]) == {:error, Error.new(:invalid)}
                 :ok
               end)

      for malformed <- [
            %{c.context | principal_id: text(other.principal_id)},
            %{c.context | owner_scope_id: text(other.vault_id)}
          ] do
        assert :ok =
                 scoped(c, fn _context ->
                   assert call(method, [malformed | args]) == {:error, Error.new(:invalid)}
                   :ok
                 end)
      end
    end
  end

  test "missing malformed and noncanonical context identities fail closed", c do
    for field <- [:principal_id, :owner_scope_id, :correlation_id],
        invalid <- [nil, "bad", @uppercase] do
      context = Map.put(c.context, field, invalid)

      for {method, args} <- [
            {:resources_in_scope, [[text(c.note.resource_id)]]},
            {:relationship_in_scope, [Ecto.UUID.generate()]}
          ] do
        assert :ok =
                 scoped(c, fn _context ->
                   assert call(method, [context | args]) == {:error, Error.new(:invalid)}
                   :ok
                 end)
      end
    end

    for context <- [nil, %{}, Map.delete(c.context, :repo)],
        method <- [:resources_in_scope, :relationship_in_scope] do
      selector =
        if method == :resources_in_scope,
          do: [text(c.note.resource_id)],
          else: Ecto.UUID.generate()

      assert call(method, [context, selector]) == {:error, Error.new(:invalid)}
    end
  end

  test "native RLS hides resource and edge metadata when otherwise matching context has no owner membership",
       c do
    other = KnowledgeFixtures.source!()
    edge = seed_edge!(c)

    for context <- [
          %{c.context | principal_id: text(other.principal_id)},
          %{c.context | owner_scope_id: text(other.vault_id)}
        ] do
      altered = %{c | context: context}
      assert resources(altered, [text(c.note.resource_id)]) == {:error, Error.new(:not_found)}
      assert selected_edge(altered, edge.relationship_id) == {:ok, nil}
    end
  end

  test "missing foreign or partly visible resource sets never return partial membership", c do
    other = KnowledgeFixtures.source!()
    foreign = KnowledgeFixtures.note!(other)

    for invisible <- [Ecto.UUID.generate(), text(foreign.resource_id)] do
      assert resources(c, [invisible]) == {:error, Error.new(:not_found)}
      ids = Enum.sort([text(c.note.resource_id), invisible])
      assert resources(c, ids) == {:error, Error.new(:not_found)}
    end
  end

  test "legal sensitive Asset resource is not admitted as private metadata", c do
    resource = KnowledgeFixtures.uuid()
    version = KnowledgeFixtures.uuid()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.resources(id,vault_id,classification,title) VALUES($1,$2,'sensitive','CANARY_SENSITIVE')",
        [resource, c.source.vault_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'sensitive',0)",
        [version, resource, c.source.vault_id]
      )
    end)

    assert resources(c, [text(resource)]) == {:error, Error.new(:not_found)}

    assert resources(c, Enum.sort([text(c.note.resource_id), text(resource)])) ==
             {:error, Error.new(:not_found)}
  end

  test "tombstone and restore hide then restore each supported resource without changing identity",
       c do
    for {row, kind} <- [{c.source, :asset}, {c.note, :note}, {c.document, :document}] do
      set_deleted!(row.resource_id, true)
      assert resources(c, [text(row.resource_id)]) == {:error, Error.new(:not_found)}
      set_deleted!(row.resource_id, false)

      assert resources(c, [text(row.resource_id)]) ==
               {:ok, [%{resource_id: text(row.resource_id), kind: kind}]}
    end
  end

  test "selected relationship returns exactly its requested five fields and nullable historical pin",
       c do
    for type <- [:related_to, :references, :derived_from], pinned? <- [false, true] do
      target = KnowledgeFixtures.note!(c.source)
      pin = if pinned?, do: text(target.resource_version_id), else: nil
      edge = seed_edge!(%{c | other_note: target}, %{type: type, target_resource_version_id: pin})
      assert selected_edge(c, edge.relationship_id) == {:ok, edge}

      assert Enum.sort(Map.keys(edge)) ==
               Enum.sort([
                 :relationship_id,
                 :source_resource_id,
                 :target_resource_id,
                 :target_resource_version_id,
                 :type
               ])
    end
  end

  test "absent and foreign selected edge both return nil without leaking labels or ownership",
       c do
    other = KnowledgeFixtures.source!()
    foreign_note = KnowledgeFixtures.note!(other)
    foreign_target = KnowledgeFixtures.note!(other)
    foreign = %{c | source: other, note: foreign_note, other_note: foreign_target}
    edge = seed_edge!(foreign)

    for id <- [Ecto.UUID.generate(), edge.relationship_id],
        do: assert(selected_edge(c, id) == {:ok, nil})
  end

  test "selected edge remains exact historical metadata when its source is tombstoned", c do
    edge = seed_edge!(c, %{target_resource_version_id: text(c.other_note.resource_version_id)})
    set_deleted!(c.note.resource_id, true)
    assert selected_edge(c, edge.relationship_id) == {:ok, edge}
    assert resources(c, [edge.source_resource_id]) == {:error, Error.new(:not_found)}
    set_deleted!(c.note.resource_id, false)
    assert selected_edge(c, edge.relationship_id) == {:ok, edge}

    assert resources(c, [edge.source_resource_id]) ==
             {:ok, [%{resource_id: edge.source_resource_id, kind: :note}]}
  end

  test "malformed selected edge UUIDs fail before PostgreSQL UUID decoding and leave transaction usable",
       c do
    assert :ok =
             scoped(c, fn context ->
               for id <- [nil, "bad", @uppercase, <<0::128>>, %{}] do
                 assert call(:relationship_in_scope, [context, id]) ==
                          {:error, Error.new(:invalid)}

                 assert %{rows: [[1]]} = query!(context.repo, "SELECT 1", [])
               end

               :ok
             end)
  end

  test "metadata still resolves with all typed-content SELECT privileges removed and restores exact ACLs",
       c do
    edge = seed_edge!(c)

    without_typed_reads(fn ->
      for {row, kind} <- [{c.source, :asset}, {c.note, :note}, {c.document, :document}] do
        assert resources(c, [text(row.resource_id)]) ==
                 {:ok, [%{resource_id: text(row.resource_id), kind: kind}]}
      end

      assert selected_edge(c, edge.relationship_id) == {:ok, edge}
    end)
  end

  test "revoked native owner membership hides both callbacks without a Runtime authority double",
       c do
    edge = seed_edge!(c)
    Fixtures.revoke_membership!(c.source)
    assert resources(c, [text(c.note.resource_id)]) == {:error, Error.new(:not_found)}
    assert selected_edge(c, edge.relationship_id) == {:ok, nil}
  end

  defp resources(c, ids), do: scoped(c, &call(:resources_in_scope, [&1, ids]))
  defp selected_edge(c, id), do: scoped(c, &call(:relationship_in_scope, [&1, id]))
  defp call(method, arguments), do: apply(@repository, method, arguments)

  defp scoped(c, fun),
    do:
      ScopedRepo.transact(
        RequestRepo,
        %{principal_id: c.context.principal_id, vault_id: c.context.owner_scope_id},
        fn repo -> fun.(%{c.context | repo: repo}) end
      )

  defp seed_edge!(c, attrs \\ %{}) do
    edge =
      Map.merge(
        %{
          relationship_id: Ecto.UUID.generate(),
          source_resource_id: text(c.note.resource_id),
          target_resource_id: text(c.other_note.resource_id),
          target_resource_version_id: nil,
          type: :references
        },
        attrs
      )

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.relationships(id,vault_id,classification,source_resource_id,target_resource_id,target_resource_version_id,type,created_by_principal_id,inserted_at) VALUES($1,$2,'private',$3,$4,$5,$6,$7,CURRENT_TIMESTAMP)",
        [
          Ecto.UUID.dump!(edge.relationship_id),
          c.source.vault_id,
          Ecto.UUID.dump!(edge.source_resource_id),
          Ecto.UUID.dump!(edge.target_resource_id),
          dump_optional(edge.target_resource_version_id),
          Atom.to_string(edge.type),
          c.source.principal_id
        ]
      )
    end)

    edge
  end

  defp set_deleted!(resource, deleted?),
    do:
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "UPDATE content.resources SET deleted_at=CASE WHEN $2 THEN CURRENT_TIMESTAMP ELSE NULL END WHERE id=$1",
          [resource, deleted?]
        )
      end)

  defp without_typed_reads(fun) do
    tables = ~w(assets asset_metadata note_versions document_versions document_fragments)

    previous =
      Fixtures.with_owner(fn ->
        %{rows: [[database]]} = query!(MigrationRepo, "SELECT current_database()", [])
        assert Regex.match?(~r/\Asingularity_test_[0-9a-f]{24}\z/, database)

        for table <- tables do
          rows = typed_read_acl(table)

          assert rows in [
                   [],
                   [["singularity_table_owner", false]],
                   [["singularity_table_owner", true]]
                 ]

          {table, rows}
        end
      end)

    try do
      Fixtures.with_owner(fn ->
        for table <- tables do
          query!(MigrationRepo, "REVOKE SELECT ON content.#{table} FROM singularity_web", [])

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
                "GRANT SELECT ON content.#{table} TO singularity_web WITH GRANT OPTION",
                []
              )

            [["singularity_table_owner", false]] ->
              query!(MigrationRepo, "GRANT SELECT ON content.#{table} TO singularity_web", [])

            [] ->
              :ok
          end

          assert typed_read_acl(table) == rows
        end
      end)
    end
  end

  defp typed_read_acl(table),
    do:
      query!(
        MigrationRepo,
        "SELECT a.grantor::regrole::text,a.is_grantable FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace CROSS JOIN LATERAL aclexplode(c.relacl) a JOIN pg_roles r ON r.oid=a.grantee WHERE n.nspname='content' AND c.relname=$1 AND r.rolname='singularity_web' AND a.privilege_type='SELECT'",
        [table]
      ).rows

  defp text(id), do: Ecto.UUID.load!(id)
  defp dump_optional(nil), do: nil
  defp dump_optional(id), do: Ecto.UUID.dump!(id)
end
