defmodule Singularity.Storage.KnowledgeRlsTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  alias Singularity.Storage.{
    Fixtures,
    KnowledgeFixtures,
    KnowledgeTestGrants,
    MigrationRepo,
    ScopedRepo
  }

  @tables ~w(note_attachments note_citations tags resource_tags relationships)

  test "all knowledge organization policies require an active authenticated matching owner" do
    for table <- @tables do
      assert %{rows: [[true, true]]} =
               query!(
                 RequestRepo,
                 "SELECT relrowsecurity,relforcerowsecurity FROM pg_class WHERE oid=to_regclass($1)",
                 ["content.#{table}"]
               )
    end

    source = KnowledgeFixtures.source!()
    other = KnowledgeFixtures.source!()
    rows = organization!(source)

    KnowledgeTestGrants.with_grants(@tables, fn ->
      for repo <- [RequestRepo, WorkerRepo], {table, attrs} <- rows do
        statement = "SELECT vault_id FROM content.#{table} WHERE vault_id = $1"
        assert %{rows: []} = query!(repo, statement, [source.vault_id])

        assert %{rows: [[owner_id]]} =
                 ScopedRepo.transact(repo, source, fn scoped ->
                   query!(scoped, statement, [source.vault_id])
                 end)

        assert owner_id == source.vault_id

        for context <- [
              other,
              %{source | vault_id: other.vault_id},
              %{source | principal_id: other.principal_id}
            ] do
          assert %{rows: []} =
                   ScopedRepo.transact(repo, context, fn scoped ->
                     query!(scoped, statement, [source.vault_id])
                   end)
        end

        error =
          assert_raise Postgrex.Error, fn ->
            ScopedRepo.transact(repo, other, fn scoped ->
              insert!(scoped, table, attrs)
            end)
          end

        assert error.postgres.code == :insufficient_privilege
      end

      Fixtures.revoke_membership!(source)

      for repo <- [RequestRepo, WorkerRepo], table <- @tables do
        assert %{rows: []} =
                 ScopedRepo.transact(repo, source, fn scoped ->
                   query!(scoped, "SELECT vault_id FROM content.#{table} WHERE vault_id = $1", [
                     source.vault_id
                   ])
                 end)
      end
    end)
  end

  test "rollback clears context on the same connection and temporary grants restore production denial" do
    source = KnowledgeFixtures.source!()

    KnowledgeTestGrants.with_grants(["tags"], fn ->
      for repo <- [RequestRepo, WorkerRepo] do
        repo.checkout(fn ->
          %{rows: [[backend]]} = query!(repo, "SELECT pg_backend_pid()", [])

          assert {:error, :boundary_rollback} =
                   ScopedRepo.transact(repo, source, fn scoped ->
                     insert!(scoped, "tags", %{
                       id: KnowledgeFixtures.uuid(),
                       vault_id: source.vault_id,
                       classification: "private",
                       display_value: "Rollback",
                       normalized_key: "rollback",
                       created_by_principal_id: source.principal_id
                     })

                     {:error, :boundary_rollback}
                   end)

          assert %{rows: [[^backend, principal, owner]]} =
                   query!(
                     repo,
                     "SELECT pg_backend_pid(), current_setting('singularity.principal_id',true), current_setting('singularity.vault_id',true)",
                     []
                   )

          assert principal in [nil, ""]
          assert owner in [nil, ""]

          assert %{rows: [[0]]} =
                   ScopedRepo.transact(repo, source, fn scoped ->
                     query!(scoped, "SELECT count(*) FROM content.tags WHERE vault_id=$1", [
                       source.vault_id
                     ])
                   end)
        end)
      end
    end)

    for repo <- [RequestRepo, WorkerRepo] do
      assert %{rows: [[false, false]]} =
               query!(
                 repo,
                 "SELECT has_table_privilege(current_user,'content.tags','SELECT'), has_table_privilege(current_user,'content.tags','INSERT')",
                 []
               )

      error =
        assert_raise Postgrex.Error, fn ->
          ScopedRepo.transact(repo, source, fn scoped ->
            query!(scoped, "SELECT id FROM content.tags", [])
          end)
        end

      assert error.postgres.code == :insufficient_privilege
    end
  end

  defp organization!(source) do
    document = KnowledgeFixtures.document!(source)
    note_id = KnowledgeFixtures.uuid()
    note_version = KnowledgeFixtures.uuid()
    tag_id = KnowledgeFixtures.uuid()
    locator = %{"version" => 1, "kind" => "text", "start_line" => 1, "end_line" => 1}
    digest = :crypto.hash(:sha256, "text")

    fragment_id =
      Singularity.Core.DocumentFragment.id(
        Ecto.UUID.load!(document.resource_version_id),
        locator,
        0,
        digest
      )

    fragment = %{
      "id" => fragment_id,
      "ordinal" => 0,
      "text" => "text",
      "digest" => Base.encode16(digest, case: :lower),
      "locator" => locator
    }

    common = %{vault_id: source.vault_id, classification: "private"}

    rows = [
      {"tags",
       Map.merge(common, %{
         id: tag_id,
         display_value: "Tag",
         normalized_key: "tag",
         created_by_principal_id: source.principal_id
       })},
      {"resource_tags", Map.merge(common, %{resource_id: note_id, tag_id: tag_id})},
      {"relationships",
       Map.merge(common, %{
         id: KnowledgeFixtures.uuid(),
         source_resource_id: note_id,
         target_resource_id: source.resource_id,
         type: "references",
         created_by_principal_id: source.principal_id
       })},
      {"note_attachments",
       Map.merge(common, %{
         id: KnowledgeFixtures.uuid(),
         note_resource_id: note_id,
         note_resource_version_id: note_version,
         target_resource_id: source.resource_id,
         target_resource_version_id: source.resource_version_id,
         target_kind: "asset",
         ordinal: 0,
         role: "source"
       })},
      {"note_citations",
       Map.merge(common, %{
         id: KnowledgeFixtures.uuid(),
         note_resource_id: note_id,
         note_resource_version_id: note_version,
         source_resource_id: document.resource_id,
         source_resource_version_id: document.resource_version_id,
         fragment_id: fragment_id,
         locator: locator,
         ordinal: 0
       })}
    ]

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.resources(id,vault_id,classification,kind,current_version_id,title) VALUES($1,$2,'private','note',$3,'Note')",
        [note_id, source.vault_id, note_version]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',0)",
        [note_version, note_id, source.vault_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.note_versions(resource_version_id,resource_id,vault_id,classification,title,markdown,created_by_principal_id,inserted_at) VALUES($1,$2,$3,'private','Note','body',$4,CURRENT_TIMESTAMP)",
        [note_version, note_id, source.vault_id, source.principal_id]
      )

      query!(
        MigrationRepo,
        "SELECT set_config('singularity.principal_id',$1,true),set_config('singularity.vault_id',$2,true)",
        [Ecto.UUID.load!(source.principal_id), Ecto.UUID.load!(source.vault_id)]
      )

      query!(MigrationRepo, "SELECT content.claim_document_extraction($1,0,'plain',1)", [
        document.resource_version_id
      ])

      query!(MigrationRepo, "SELECT content.complete_document_extraction($1,1,$2,$3,'en')", [
        document.resource_version_id,
        [fragment],
        digest
      ])

      for {table, attrs} <- rows, do: insert!(MigrationRepo, table, attrs)
    end)

    rows
  end

  defp insert!(repo, table, attrs) do
    {fields, values} = attrs |> Enum.sort() |> Enum.unzip()

    query!(
      repo,
      "INSERT INTO content.#{table} (#{Enum.join(fields, ",")},inserted_at) VALUES (#{Enum.map_join(1..length(fields), ",", &"$#{&1}")},CURRENT_TIMESTAMP)",
      values
    )
  end
end
