defmodule Singularity.Storage.Postgres.KnowledgeAssetLifecycleGuardsTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration

  alias Singularity.Storage.{
    Fixtures,
    KnowledgeFixtures,
    MigrationRepo,
    MigrationTestEnvironment,
    ScopedRepo
  }

  @previous 20_261_011_000_100
  @version 20_261_011_000_200
  @functions [
    {"knowledge_asset_binding_is_live(uuid,uuid,uuid)", "s"},
    {"knowledge_resource_is_live(uuid,uuid)", "s"},
    {"lock_knowledge_organization_resources(uuid,uuid[])", "v"}
  ]
  @excluded ~w(singularity_worker singularity_dispatcher singularity_pre_auth)
  @states ~w(staging uploaded verified available processing ready)

  alias Singularity.Core.{Error, JobEnvelope, NoteSaveResult, NoteSnapshot}
  alias Singularity.Domains.Assets
  alias Singularity.Storage.ObjectLock

  alias Singularity.Storage.Postgres.{
    AssetDeletionRepository,
    AssetRepository,
    NoteRepository,
    TagRepository
  }

  @barrier_timeout 5_000

  test "new functions are hardened invokers with exact web and table-owner execution only" do
    for {signature, volatility} <- @functions do
      assert %{
               rows: [
                 [
                   false,
                   ^volatility,
                   ["search_path=pg_catalog, content"],
                   "singularity_table_owner"
                 ]
               ]
             } =
               query!(
                 RequestRepo,
                 """
                 SELECT p.prosecdef,p.provolatile::text,p.proconfig,r.rolname
                 FROM pg_proc p JOIN pg_roles r ON r.oid=p.proowner
                 WHERE p.oid=$1::text::regprocedure
                 """,
                 ["content." <> signature]
               )

      assert %{rows: [["singularity_table_owner", false], ["singularity_web", false]]} =
               query!(
                 RequestRepo,
                 """
                 SELECT r.rolname,a.is_grantable
                 FROM pg_proc p
                 CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
                 LEFT JOIN pg_roles r ON r.oid=a.grantee
                 WHERE p.oid=$1::text::regprocedure AND a.privilege_type='EXECUTE'
                 ORDER BY r.rolname
                 """,
                 ["content." <> signature]
               )

      for role <- @excluded do
        assert %{rows: [[false]]} =
                 query!(RequestRepo, "SELECT has_function_privilege($1,$2,'EXECUTE')", [
                   role,
                   "content." <> signature
                 ])
      end
    end
  end

  test "forward migration leaves all table grants role attributes and historical organization rows unchanged" do
    enclosing = security_snapshot()
    enclosing_head = migration_head().rows
    repos = [MigrationRepo, RequestRepo, WorkerRepo, DispatcherRepo, PreAuthRepo]
    configs = Map.new(repos, &{&1, Application.fetch_env!(:singularity_storage, &1)})

    MigrationTestEnvironment.with_database(@previous, fn _environment ->
      source = KnowledgeFixtures.source!()
      note = KnowledgeFixtures.note!(source)
      tag = tag!(source)
      edge = KnowledgeFixtures.uuid()

      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "INSERT INTO content.resource_tags(resource_id,tag_id,vault_id,classification,inserted_at) VALUES($1,$2,$3,'private',CURRENT_TIMESTAMP)",
          [source.resource_id, tag, source.vault_id]
        )

        query!(
          MigrationRepo,
          "INSERT INTO content.relationships(id,vault_id,classification,source_resource_id,target_resource_id,type,created_by_principal_id,inserted_at) VALUES($1,$2,'private',$3,$4,'related_to',$5,CURRENT_TIMESTAMP)",
          [edge, source.vault_id, source.resource_id, note.resource_id, source.principal_id]
        )
      end)

      before_security = security_snapshot()
      before_rows = organization_rows(source)
      migrate!()
      assert security_snapshot() == before_security
      assert organization_rows(source) == before_rows

      assert %{rows: [[@version]]} =
               migration_head()
    end)

    assert security_snapshot() == enclosing

    assert migration_head().rows ==
             enclosing_head

    assert Map.new(repos, &{&1, Application.fetch_env!(:singularity_storage, &1)}) == configs
  end

  test "actual web binding liveness covers all six states and does not require an Asset head or object" do
    source = KnowledgeFixtures.source!()

    for state <- @states do
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "UPDATE content.assets SET state=$1,asset_object_id=NULL WHERE id=$2",
          [state, source.asset_id]
        )

        assert %{rows: [[nil]]} =
                 query!(
                   MigrationRepo,
                   "SELECT current_version_id FROM content.resources WHERE id=$1",
                   [
                     source.resource_id
                   ]
                 )
      end)

      assert liveness(source) == [true, true, true]
    end

    for state <- ~w(pending_delete deleted) do
      Fixtures.with_owner(fn ->
        query!(MigrationRepo, "UPDATE content.assets SET state=$1 WHERE id=$2", [
          state,
          source.asset_id
        ])
      end)

      assert liveness(source) == [false, false, false]
    end
  end

  test "association release and exact private tombstone independently exclude a still available Asset" do
    source = KnowledgeFixtures.source!()
    assert liveness(source) == [true, true, true]

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.resource_assets SET released_at=CURRENT_TIMESTAMP WHERE resource_version_id=$1 AND asset_id=$2",
        [source.resource_version_id, source.asset_id]
      )
    end)

    assert liveness(source) == [false, false, false]

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.resource_assets SET released_at=NULL WHERE resource_version_id=$1 AND asset_id=$2",
        [source.resource_version_id, source.asset_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.tombstones(id,vault_id,asset_id,principal_id,classification,reason) VALUES($1,$2,$3,$4,'private','user_requested')",
        [KnowledgeFixtures.uuid(), source.vault_id, source.asset_id, source.principal_id]
      )
    end)

    assert liveness(source) == [false, false, false]
  end

  test "another exact live version keeps an Asset Resource live without substituting the old binding" do
    source = KnowledgeFixtures.source!()
    second_version = KnowledgeFixtures.uuid()
    second_asset = KnowledgeFixtures.uuid()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) SELECT $1,$2,$3,'private',max(revision)+1 FROM content.resource_versions WHERE resource_id=$2 AND vault_id=$3",
        [second_version, source.resource_id, source.vault_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.assets(id,resource_version_id,vault_id,classification,state) VALUES($1,$2,$3,'private','uploaded')",
        [second_asset, second_version, source.vault_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.resource_assets(resource_version_id,asset_id,vault_id,classification) VALUES($1,$2,$3,'private')",
        [second_version, second_asset, source.vault_id]
      )

      query!(MigrationRepo, "UPDATE content.assets SET state='pending_delete' WHERE id=$1", [
        source.asset_id
      ])
    end)

    assert liveness(source) == [false, true, true]
    assert binding(source, second_version, second_asset)
    refute binding(source, source.resource_version_id, second_asset)
    refute binding(source, second_version, source.asset_id)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.resource_assets SET released_at=CURRENT_TIMESTAMP WHERE asset_id=$1",
        [second_asset]
      )
    end)

    assert liveness(source) == [false, false, false]
  end

  test "guard rejects malformed missing foreign nonlive and unsorted root sets under native RLS" do
    source = KnowledgeFixtures.source!()
    other = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    sorted = Enum.sort([source.resource_id, note.resource_id])

    assert true == guard(source, sorted)

    for roots <- [
          nil,
          [],
          [nil],
          [source.resource_id, source.resource_id],
          Enum.reverse(sorted),
          sorted ++ [other.resource_id],
          [KnowledgeFixtures.uuid()],
          [other.resource_id]
        ] do
      refute guard(source, roots)
    end

    assert %{rows: [[false]]} =
             query!(RequestRepo, "SELECT content.knowledge_resource_is_live($1,$2)", [
               source.vault_id,
               source.resource_id
             ])

    refute binding(source, other.resource_version_id, other.asset_id)
    refute guard(%{source | principal_id: other.principal_id}, [source.resource_id])
    refute guard(%{source | vault_id: other.vault_id}, [source.resource_id])
  end

  test "actual web direct INSERT rejects dead or foreign endpoints including ON CONFLICT" do
    source = KnowledgeFixtures.source!()
    foreign = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    tag = tag!(source)

    assert %{num_rows: 1} =
             scoped(source, fn repo ->
               insert_tag(repo, source, source.resource_id, tag)
             end)

    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "UPDATE content.assets SET state='pending_delete' WHERE id=$1", [
        source.asset_id
      ])
    end)

    for resource <- [source.resource_id, foreign.resource_id, KnowledgeFixtures.uuid()] do
      error =
        assert_raise Postgrex.Error, fn ->
          scoped(source, &insert_tag(&1, source, resource, tag))
        end

      assert error.postgres.constraint == "resource_tags_resource_check"
    end

    for {left, right} <- [
          {source.resource_id, note.resource_id},
          {note.resource_id, source.resource_id},
          {foreign.resource_id, note.resource_id}
        ] do
      error =
        assert_raise Postgrex.Error, fn ->
          scoped(source, fn repo ->
            query!(
              repo,
              "INSERT INTO content.relationships(id,vault_id,classification,source_resource_id,target_resource_id,type,created_by_principal_id,inserted_at) VALUES($1,$2,'private',$3,$4,'related_to',$5,CURRENT_TIMESTAMP) ON CONFLICT DO NOTHING",
              [KnowledgeFixtures.uuid(), source.vault_id, left, right, source.principal_id]
            )
          end)
        end

      assert error.postgres.constraint == "relationships_resource_check"
    end

    assert %{rows: [[1, 0]]} =
             scoped(source, fn repo ->
               query!(
                 repo,
                 "SELECT (SELECT count(*) FROM content.resource_tags WHERE tag_id=$1),(SELECT count(*) FROM content.relationships WHERE vault_id=$2)",
                 [tag, source.vault_id]
               )
             end)
  end

  test "actual web INSERT cannot use missing or foreign authenticated owner context" do
    source = KnowledgeFixtures.source!()
    foreign = KnowledgeFixtures.source!()
    tag = tag!(source)

    missing =
      assert_raise Postgrex.Error, fn ->
        insert_tag(RequestRepo, source, source.resource_id, tag)
      end

    assert missing.postgres.code == :insufficient_privilege

    foreign_context =
      assert_raise Postgrex.Error, fn ->
        scoped(foreign, &insert_tag(&1, source, source.resource_id, tag))
      end

    assert foreign_context.postgres.code == :insufficient_privilege

    assert %{rows: [[0]]} =
             scoped(
               source,
               &query!(&1, "SELECT count(*) FROM content.resource_tags WHERE tag_id=$1", [tag])
             )
  end

  test "global immutable-kind guard protects actual web Asset Document and Note metadata prechecks" do
    source = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    document = KnowledgeFixtures.document!(source)

    for {row, kind, replacement} <- [
          {source, "asset", "note"},
          {document, "document", "asset"},
          {note, "note", "document"}
        ] do
      error =
        assert_raise Postgrex.Error, fn ->
          scoped(source, fn repo ->
            query!(repo, "UPDATE content.resources SET kind=$1 WHERE id=$2", [
              replacement,
              row.resource_id
            ])
          end)
        end

      assert error.postgres.constraint == "resources_note_kind_immutable_check"

      assert %{rows: [[^kind]]} =
               scoped(
                 source,
                 &query!(&1, "SELECT kind FROM content.resources WHERE id=$1", [row.resource_id])
               )
    end
  end

  for missing <- [:metadata, :association, :wrong_version, :foreign_classification] do
    @missing missing
    test "historical Asset resolution fails closed for #{@missing} exact metadata binding" do
      source = prepared_source!()
      reference = historical_reference(source)

      Fixtures.with_owner(fn ->
        case @missing do
          :metadata ->
            query!(MigrationRepo, "DELETE FROM content.asset_metadata WHERE asset_id=$1", [
              source.asset_id
            ])

          :association ->
            query!(
              MigrationRepo,
              "DELETE FROM content.resource_assets WHERE resource_version_id=$1 AND asset_id=$2",
              [source.resource_version_id, source.asset_id]
            )

          :wrong_version ->
            other = KnowledgeFixtures.uuid()

            query!(
              MigrationRepo,
              "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) SELECT $1,$2,$3,'private',max(revision)+1 FROM content.resource_versions WHERE resource_id=$2 AND vault_id=$3",
              [other, source.resource_id, source.vault_id]
            )

            query!(
              MigrationRepo,
              "UPDATE content.asset_metadata SET resource_version_id=$1 WHERE asset_id=$2",
              [other, source.asset_id]
            )

          :foreign_classification ->
            query!(
              MigrationRepo,
              "UPDATE content.asset_metadata SET classification='sensitive' WHERE asset_id=$1",
              [source.asset_id]
            )
        end
      end)

      assert resolve_historical(source, reference) ==
               {:error, Singularity.Core.Error.new(:not_found)}
    end
  end

  for missing_original_association <- [false, true] do
    @missing_original_association missing_original_association
    test "historical Asset resolution rejects multiple bindings rather than substituting B (missing A association=#{missing_original_association})" do
      source = prepared_source!()
      reference = historical_reference(source)
      second_asset = KnowledgeFixtures.uuid()

      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "INSERT INTO content.assets(id,resource_version_id,vault_id,classification,state) VALUES($1,$2,$3,'private','available')",
          [second_asset, source.resource_version_id, source.vault_id]
        )

        query!(
          MigrationRepo,
          "INSERT INTO content.resource_assets(resource_version_id,asset_id,vault_id,classification) VALUES($1,$2,$3,'private')",
          [source.resource_version_id, second_asset, source.vault_id]
        )

        query!(
          MigrationRepo,
          "INSERT INTO content.asset_metadata(id,asset_id,resource_version_id,vault_id,classification,projection_version,original_filename,declared_media_type,plaintext_byte_size,extraction_state) VALUES($1,$2,$3,$4,'private',1,'substitute.txt','text/plain',12,'pending')",
          [KnowledgeFixtures.uuid(), second_asset, source.resource_version_id, source.vault_id]
        )

        if @missing_original_association do
          query!(
            MigrationRepo,
            "DELETE FROM content.resource_assets WHERE resource_version_id=$1 AND asset_id=$2",
            [source.resource_version_id, source.asset_id]
          )
        end
      end)

      assert resolve_historical(source, reference) ==
               {:error, Singularity.Core.Error.new(:invalid)}
    end
  end

  @tag :asset_metadata_bounded
  test "ambiguous historical Asset metadata returns only the bounded SQL ambiguity sentinel" do
    source = prepared_source!()
    reference = historical_reference(source)
    assets = [source.asset_id | Enum.map(1..7, fn _ -> KnowledgeFixtures.uuid() end)]
    security = security_snapshot()

    Fixtures.with_owner(fn ->
      for asset <- tl(assets) do
        query!(
          MigrationRepo,
          "INSERT INTO content.assets(id,resource_version_id,vault_id,classification,state) VALUES($1,$2,$3,'private','available')",
          [asset, source.resource_version_id, source.vault_id]
        )

        query!(
          MigrationRepo,
          "INSERT INTO content.resource_assets(resource_version_id,asset_id,vault_id,classification) VALUES($1,$2,$3,'private')",
          [source.resource_version_id, asset, source.vault_id]
        )

        query!(
          MigrationRepo,
          "INSERT INTO content.asset_metadata(id,asset_id,resource_version_id,vault_id,classification,projection_version,original_filename,declared_media_type,plaintext_byte_size,extraction_state) VALUES($1,$2,$3,$4,'private',1,'ambiguous.txt','text/plain',12,'pending')",
          [KnowledgeFixtures.uuid(), asset, source.resource_version_id, source.vault_id]
        )
      end
    end)

    expected = Enum.map(Enum.sort(assets), &[&1, true, true, true, nil])
    assert metadata_binding_inventory(source) == expected

    {result, summary} = capture_metadata_summary!(source, reference)
    invalid? = result == {:error, Error.new(:invalid)}
    assert invalid?
    assert summary == %{metadata_statements: 1, result_rows: 2}

    assert metadata_binding_inventory(source) == expected
    assert security_snapshot() == security
  end

  for marker <- [:resource, :pending_delete, :deleted, :tombstone, :association] do
    @marker marker
    test "historical Asset metadata retains the exact pin/title after #{@marker} and object cleanup" do
      source = prepared_source!()
      reference = historical_reference(source)

      assert {:ok, %{reference: ^reference, source: %{title: "test.txt", deleted?: false}}} =
               resolve_historical(source, reference)

      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "UPDATE content.resources SET title='Mutable unrelated title' WHERE id=$1",
          [source.resource_id]
        )

        query!(MigrationRepo, "UPDATE content.assets SET asset_object_id=NULL WHERE id=$1", [
          source.asset_id
        ])

        case @marker do
          :resource ->
            query!(
              MigrationRepo,
              "UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id=$1",
              [source.resource_id]
            )

          state when state in [:pending_delete, :deleted] ->
            query!(MigrationRepo, "UPDATE content.assets SET state=$1 WHERE id=$2", [
              Atom.to_string(state),
              source.asset_id
            ])

          :association ->
            query!(
              MigrationRepo,
              "UPDATE content.resource_assets SET released_at=CURRENT_TIMESTAMP WHERE resource_version_id=$1 AND asset_id=$2",
              [source.resource_version_id, source.asset_id]
            )

          :tombstone ->
            query!(
              MigrationRepo,
              "INSERT INTO content.tombstones(id,vault_id,asset_id,principal_id,classification,reason) VALUES($1,$2,$3,$4,'private','user_requested')",
              [KnowledgeFixtures.uuid(), source.vault_id, source.asset_id, source.principal_id]
            )
        end
      end)

      expected = %{
        reference: reference,
        source: %{
          kind: :asset,
          resource_id: Ecto.UUID.load!(source.resource_id),
          resource_version_id: Ecto.UUID.load!(source.resource_version_id),
          title: "test.txt",
          deleted?: true
        }
      }

      assert resolve_historical(source, reference) == {:ok, expected}
    end
  end

  @tag :asset_identity_closed
  test "historical Asset metadata never substitutes private B after native-web reclassification of A" do
    source = prepared_source!()
    reference = historical_reference(source)
    metadata_id = original_metadata_id(source)

    assert {:ok, %{reference: ^reference, source: %{title: "test.txt", deleted?: false}}} =
             resolve_historical(source, reference)

    assert_original_asset_evidence(source, metadata_id, source.resource_version_id, "private")

    result =
      scoped(source, fn repo ->
        query!(
          repo,
          "UPDATE content.assets SET classification='sensitive' WHERE id=$1 AND vault_id=$2 RETURNING current_user,id,resource_version_id,vault_id,classification",
          [source.asset_id, source.vault_id]
        )
      end)

    assert result.num_rows == 1

    assert result.rows == [
             [
               "singularity_web",
               source.asset_id,
               source.resource_version_id,
               source.vault_id,
               "sensitive"
             ]
           ]

    identity_binding_b!(source)
    assert_original_asset_evidence(source, metadata_id, source.resource_version_id, "sensitive")

    assert resolve_historical(source, reference) ==
             {:error, Singularity.Core.Error.new(:invalid)}
  end

  @tag :asset_identity_closed
  test "historical Asset metadata never substitutes private B after native-web reassignment of A" do
    source = prepared_source!()
    reference = historical_reference(source)
    metadata_id = original_metadata_id(source)
    other_version = KnowledgeFixtures.uuid()

    assert {:ok, %{reference: ^reference, source: %{title: "test.txt", deleted?: false}}} =
             resolve_historical(source, reference)

    assert_original_asset_evidence(source, metadata_id, source.resource_version_id, "private")

    result =
      scoped(source, fn repo ->
        query!(
          repo,
          "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) SELECT $1,$2,$3,'private',max(revision)+1 FROM content.resource_versions WHERE resource_id=$2 AND vault_id=$3 RETURNING current_user,id,resource_id,vault_id,classification",
          [other_version, source.resource_id, source.vault_id]
        )
      end)

    assert result.num_rows == 1

    assert result.rows == [
             ["singularity_web", other_version, source.resource_id, source.vault_id, "private"]
           ]

    result =
      scoped(source, fn repo ->
        query!(
          repo,
          "UPDATE content.assets SET resource_version_id=$1 WHERE id=$2 AND vault_id=$3 RETURNING current_user,id,resource_version_id,vault_id,classification",
          [other_version, source.asset_id, source.vault_id]
        )
      end)

    assert result.num_rows == 1

    assert result.rows == [
             ["singularity_web", source.asset_id, other_version, source.vault_id, "private"]
           ]

    identity_binding_b!(source)
    assert_original_asset_evidence(source, metadata_id, other_version, "private")

    assert resolve_historical(source, reference) ==
             {:error, Singularity.Core.Error.new(:invalid)}
  end

  defp original_metadata_id(source) do
    %{rows: [[metadata_id]]} =
      scoped(source, fn repo ->
        query!(repo, "SELECT id FROM content.asset_metadata WHERE asset_id=$1 AND vault_id=$2", [
          source.asset_id,
          source.vault_id
        ])
      end)

    metadata_id
  end

  defp assert_original_asset_evidence(source, metadata_id, current_version, classification) do
    result =
      scoped(source, fn repo ->
        query!(
          repo,
          """
          SELECT current_user,a.id,a.resource_version_id,a.vault_id,a.classification,
            m.id,m.asset_id,m.resource_version_id,m.vault_id,m.classification,m.original_filename,
            ra.asset_id,ra.resource_version_id,ra.vault_id,ra.classification,ra.released_at,
            v.id,v.resource_id,v.vault_id,v.classification,r.id,r.vault_id,r.classification,r.deleted_at
          FROM content.assets a
          JOIN content.asset_metadata m ON (m.asset_id,m.vault_id)=(a.id,a.vault_id)
          JOIN content.resource_assets ra ON (ra.asset_id,ra.vault_id)=(a.id,a.vault_id)
          JOIN content.resource_versions v ON (v.id,v.vault_id)=(m.resource_version_id,m.vault_id)
          JOIN content.resources r ON (r.id,r.vault_id,r.classification)=(v.resource_id,v.vault_id,v.classification)
          WHERE (a.id,a.vault_id,ra.resource_version_id)=($1,$2,$3)
          """,
          [source.asset_id, source.vault_id, source.resource_version_id]
        )
      end)

    assert result.rows == [
             [
               "singularity_web",
               source.asset_id,
               current_version,
               source.vault_id,
               classification,
               metadata_id,
               source.asset_id,
               source.resource_version_id,
               source.vault_id,
               "private",
               "test.txt",
               source.asset_id,
               source.resource_version_id,
               source.vault_id,
               "private",
               nil,
               source.resource_version_id,
               source.resource_id,
               source.vault_id,
               "private",
               source.resource_id,
               source.vault_id,
               "private",
               nil
             ]
           ]
  end

  defp identity_binding_b!(source) do
    asset_id = upload_binding!(source)
    metadata_id = KnowledgeFixtures.uuid()

    assert %{num_rows: 1} =
             scoped(source, fn repo ->
               query!(
                 repo,
                 "INSERT INTO content.asset_metadata(id,asset_id,resource_version_id,vault_id,classification,projection_version,original_filename,declared_media_type,plaintext_byte_size,extraction_state) VALUES($1,$2,$3,$4,'private',1,'substitute.txt','text/plain',12,'pending')",
                 [metadata_id, asset_id, source.resource_version_id, source.vault_id]
               )
             end)

    result =
      scoped(source, fn repo ->
        query!(
          repo,
          """
          SELECT current_user,a.id,a.resource_version_id,a.vault_id,a.classification,a.state,
            m.id,m.asset_id,m.resource_version_id,m.vault_id,m.classification,m.original_filename,
            ra.asset_id,ra.resource_version_id,ra.vault_id,ra.classification,ra.released_at
          FROM content.assets a
          JOIN content.asset_metadata m ON (m.asset_id,m.resource_version_id,m.vault_id,m.classification)=
            (a.id,a.resource_version_id,a.vault_id,a.classification)
          JOIN content.resource_assets ra ON (ra.asset_id,ra.resource_version_id,ra.vault_id,ra.classification)=
            (a.id,a.resource_version_id,a.vault_id,a.classification)
          WHERE (a.id,a.vault_id)=($1,$2)
          """,
          [asset_id, source.vault_id]
        )
      end)

    assert result.rows == [
             [
               "singularity_web",
               asset_id,
               source.resource_version_id,
               source.vault_id,
               "private",
               "staging",
               metadata_id,
               asset_id,
               source.resource_version_id,
               source.vault_id,
               "private",
               "substitute.txt",
               asset_id,
               source.resource_version_id,
               source.vault_id,
               "private",
               nil
             ]
           ]
  end

  defp prepared_source! do
    Map.new(KnowledgeFixtures.prepared_source!(), fn {key, value} ->
      if String.ends_with?(Atom.to_string(key), "_id"),
        do: {key, Ecto.UUID.dump!(value)},
        else: {key, value}
    end)
  end

  defp historical_reference(source) do
    {:ok, reference} =
      Singularity.Core.NoteAttachmentReference.new(%{
        attachment_id: Ecto.UUID.generate(),
        target_resource_id: Ecto.UUID.load!(source.resource_id),
        target_resource_version_id: Ecto.UUID.load!(source.resource_version_id),
        target_kind: :asset,
        role: :source,
        label: "original"
      })

    reference
  end

  defp metadata_binding_inventory(source) do
    scoped(source, fn repo ->
      principal = text(source.principal_id)
      owner = text(source.vault_id)

      assert %{rows: [["singularity_web", ^principal, ^owner]]} =
               query!(
                 repo,
                 "SELECT current_user,current_setting('singularity.principal_id'),current_setting('singularity.vault_id')"
               )

      query!(
        repo,
        """
        SELECT a.id,
          (a.resource_version_id,a.vault_id,a.classification)=(v.id,r.vault_id,'private'),
          (m.asset_id,m.resource_version_id,m.vault_id,m.classification)=(a.id,v.id,r.vault_id,'private'),
          (ra.asset_id,ra.resource_version_id,ra.vault_id,ra.classification)=(a.id,v.id,r.vault_id,'private'),
          ra.released_at
        FROM content.resources r
        JOIN content.resource_versions v ON (v.resource_id,v.vault_id,v.classification)=(r.id,r.vault_id,r.classification)
        JOIN content.assets a ON a.resource_version_id=v.id
        JOIN content.asset_metadata m ON m.asset_id=a.id
        JOIN content.resource_assets ra ON (ra.resource_version_id,ra.asset_id)=(v.id,a.id)
        WHERE (r.id,v.id,r.vault_id,r.classification,r.kind)=($1,$2,$3,'private','asset')
        ORDER BY a.id
        """,
        [source.resource_id, source.resource_version_id, source.vault_id]
      ).rows
    end)
  end

  defp capture_metadata_summary!(source, reference) do
    alias Singularity.Storage.SafeSQL
    Code.ensure_loaded!(SafeSQL)
    caller = self()
    function = {SafeSQL, :query!, 4}
    assert :erlang.trace_info(caller, :flags) == {:flags, []}
    assert :erlang.trace_info(function, :traced) == {:traced, false}
    token = make_ref()
    parameters = [source.resource_id, source.resource_version_id, source.vault_id, "asset"]
    initial = %{metadata_statements: 0, result_rows: nil}

    {collector, monitor} =
      spawn_monitor(fn ->
        collect_metadata_summary(caller, token, parameters, [], initial, true)
      end)

    try do
      try do
        assert :erlang.trace_pattern(function, [{:_, [], [{:return_trace}]}], [:local]) == 1

        try do
          assert :erlang.trace(caller, true, [:call, {:tracer, collector}]) == 1
          result = resolve_historical(source, reference)
          delivered = :erlang.trace_delivered(caller)

          receive do
            {:trace_delivered, ^caller, ^delivered} -> :ok
          after
            @barrier_timeout -> flunk("metadata trace delivery barrier timed out")
          end

          send(collector, {token, :collect})

          receive do
            {^token, :summary, true, summary} -> {result, summary}
            {^token, :summary, false, _summary} -> flunk("metadata trace pairing failed")
          after
            @barrier_timeout -> flunk("metadata trace collection barrier timed out")
          end
        after
          :erlang.trace(caller, false, [:call])
        end
      after
        :erlang.trace_pattern(function, false, [:local])
      end
    after
      stop_metadata_collector!(collector, monitor, token)
      assert :erlang.trace_info(caller, :flags) == {:flags, []}
      assert :erlang.trace_info(function, :traced) == {:traced, false}
    end
  end

  defp collect_metadata_summary(caller, token, parameters, stack, summary, valid) do
    alias Singularity.Storage.SafeSQL

    receive do
      {:trace, ^caller, :call, {SafeSQL, :query!, [repo, sql, params, _options]}}
      when is_binary(sql) and is_list(params) ->
        # Reduce arguments immediately; no SQL, parameters or content leave this collector.
        selected =
          repo == RequestRepo and params == parameters and
            String.contains?(sql, "candidate_assets")

        collect_metadata_summary(
          caller,
          token,
          parameters,
          [selected | stack],
          summary,
          valid and stack == []
        )

      {:trace, ^caller, :return_from, {SafeSQL, :query!, 4}, result} ->
        case stack do
          [selected | rest] ->
            {updated, valid_result} =
              case {selected, result} do
                {true, %Postgrex.Result{num_rows: count, rows: rows}}
                when is_integer(count) and is_list(rows) ->
                  {%{metadata_statements: summary.metadata_statements + 1, result_rows: count},
                   count == length(rows)}

                {false, _} ->
                  {summary, true}

                _ ->
                  {summary, false}
              end

            collect_metadata_summary(
              caller,
              token,
              parameters,
              rest,
              updated,
              valid and valid_result
            )

          [] ->
            collect_metadata_summary(caller, token, parameters, [], summary, false)
        end

      {^token, :collect} ->
        send(caller, {token, :summary, valid and stack == [], summary})
        collect_metadata_summary(caller, token, parameters, stack, summary, valid)

      {^token, :stop} ->
        :ok

      _ ->
        collect_metadata_summary(caller, token, parameters, stack, summary, false)
    end
  end

  defp stop_metadata_collector!(collector, monitor, token) do
    send(collector, {token, :stop})

    receive do
      {:DOWN, ^monitor, :process, ^collector, :normal} -> :ok
      {:DOWN, ^monitor, :process, ^collector, _} -> flunk("metadata collector cleanup failed")
    after
      @barrier_timeout ->
        Process.exit(collector, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^collector, _} ->
            flunk("metadata collector cleanup failed")
        after
          1_000 -> flunk("metadata collector shutdown barrier timed out")
        end
    end
  end

  defp resolve_historical(source, reference) do
    context = %{
      repo: RequestRepo,
      principal_id: Ecto.UUID.load!(source.principal_id),
      owner_scope_id: Ecto.UUID.load!(source.vault_id),
      correlation_id: Ecto.UUID.generate()
    }

    scoped(source, fn _repo ->
      Singularity.Storage.Postgres.KnowledgeLinkRepository.resolve_attachment_in_scope(
        context,
        reference
      )
    end)
  end

  test "a newly committed unheld upload binding cannot rescue a guard waiting on real deletion" do
    source = KnowledgeFixtures.source!()
    context = organization_context(source)
    tag = tag!(source)
    gate = make_ref()
    parent = self()

    with_race_connection(
      :delete,
      gate,
      fn ->
        real_delete(source, fn -> race_hold(parent, gate, :deleted) end)
      end,
      fn deletion ->
        {dp, db} = race_ready(gate, :delete)
        send(dp, {gate, :start})
        race_checkpoint(gate, :deleted)

        with_race_connection(
          :organization,
          gate,
          fn ->
            attach(source, context, tag)
          end,
          fn organization ->
            {op, ob} = race_ready(gate, :organization)
            send(op, {gate, :start})
            observed_block!(ob, db)
            binding_b = upload_binding!(source)
            assert binding(source, source.resource_version_id, binding_b)
            send(dp, {gate, :continue})
            assert {:ok, %{state: :pending_delete}} = Task.await(deletion, @barrier_timeout)

            assert {:error, %Error{code: :invalid, message: nil, details: %{}}} =
                     Task.await(organization, @barrier_timeout)

            assert organization_effects(source, context, tag) == [0, 0]
            assert liveness(source) == [false, true, true]

            assert %{rows: [[nil, true, true]]} =
                     scoped(source, fn repo ->
                       query!(
                         repo,
                         "SELECT r.deleted_at,ra.released_at IS NOT NULL,EXISTS(SELECT 1 FROM content.tombstones t WHERE t.asset_id=a.id AND t.vault_id=a.vault_id) FROM content.resources r JOIN content.resource_versions v ON v.resource_id=r.id JOIN content.assets a ON a.resource_version_id=v.id JOIN content.resource_assets ra ON ra.resource_version_id=v.id AND ra.asset_id=a.id WHERE a.id=$1",
                         [source.asset_id]
                       )
                     end)
          end
        )
      end
    )
  end

  test "a held witness which stays live admits organization despite a later unheld upload binding" do
    source = KnowledgeFixtures.source!()
    context = organization_context(source)
    tag = tag!(source)
    gate = make_ref()
    parent = self()

    with_race_connection(
      :asset,
      gate,
      fn ->
        race_scoped(source, fn repo ->
          query!(repo, "SELECT id FROM content.assets WHERE id=$1 FOR UPDATE", [source.asset_id])
          race_hold(parent, gate, :asset)
          :ok
        end)
      end,
      fn holder ->
        {hp, hb} = race_ready(gate, :asset)
        send(hp, {gate, :start})
        race_checkpoint(gate, :asset)

        with_race_connection(
          :organization,
          gate,
          fn -> attach(source, context, tag) end,
          fn organization ->
            {op, ob} = race_ready(gate, :organization)
            send(op, {gate, :start})
            observed_block!(ob, hb)
            binding_b = upload_binding!(source)
            assert binding(source, source.resource_version_id, binding_b)
            send(hp, {gate, :continue})
            assert :ok = Task.await(holder, @barrier_timeout)
            assert :ok = Task.await(organization, @barrier_timeout)
            assert organization_effects(source, context, tag) == [1, 1]
          end
        )
      end
    )
  end

  test "organization's held witness stalls real deletion until commit then browse omits it" do
    source = KnowledgeFixtures.source!()
    context = organization_context(source)
    tag = tag!(source)
    gate = make_ref()
    parent = self()

    with_race_connection(
      :organization,
      gate,
      fn ->
        race_scoped(source, fn _repo ->
          assert :ok = TagRepository.attach_in_scope(context, text(source.resource_id), text(tag))
          race_hold(parent, gate, :organization)
          :ok
        end)
      end,
      fn organization ->
        {op, ob} = race_ready(gate, :organization)
        send(op, {gate, :start})
        race_checkpoint(gate, :organization)

        with_race_connection(:delete, gate, fn -> real_delete(source) end, fn deletion ->
          {dp, db} = race_ready(gate, :delete)
          send(dp, {gate, :start})
          observed_block!(db, ob)
          send(op, {gate, :continue})
          assert :ok = Task.await(organization, @barrier_timeout)
          assert {:ok, %{state: :pending_delete}} = Task.await(deletion, @barrier_timeout)

          assert {:ok, %{items: [], next_cursor: :done}} =
                   race_scoped(source, fn _repo ->
                     {:ok, query} = Singularity.Core.OrganizationPageQuery.new(%{limit: 1})
                     TagRepository.browse_in_scope(context, text(tag), query, [:asset])
                   end)

          assert organization_effects(source, context, tag) == [1, 1]
        end)
      end
    )
  end

  for duplicate <- [false, true] do
    @duplicate duplicate
    test "INSERT has one Asset acquisition phase before Resource wait (duplicate=#{duplicate})" do
      source = KnowledgeFixtures.source!()
      context = organization_context(source)
      tag = tag!(source)
      if @duplicate, do: assert(:ok = attach(source, context, tag))
      before = organization_effects(source, context, tag)
      gate = make_ref()
      parent = self()

      with_race_connection(
        :resource,
        gate,
        fn ->
          race_scoped(source, fn repo ->
            query!(repo, "SELECT id FROM content.resources WHERE id=$1 FOR UPDATE", [
              source.resource_id
            ])

            race_hold(parent, gate, :resource)
            :ok
          end)
        end,
        fn resource ->
          {rp, rb} = race_ready(gate, :resource)
          send(rp, {gate, :start})
          race_checkpoint(gate, :resource)

          with_race_connection(
            :organization,
            gate,
            fn -> attach(source, context, tag) end,
            fn organization ->
              {op, ob} = race_ready(gate, :organization)
              send(op, {gate, :start})
              observed_block!(ob, rb)
              # B is globally earlier than A, so a repeated discovery would wait on B.
              <<asset_number::unsigned-big-integer-size(128)>> = source.asset_id
              earlier_b = <<asset_number - 1::unsigned-big-integer-size(128)>>
              assert earlier_b < source.asset_id
              assert upload_binding!(source, earlier_b) == earlier_b

              with_race_connection(
                :binding_b,
                gate,
                fn ->
                  race_scoped(source, fn repo ->
                    query!(repo, "SELECT id FROM content.assets WHERE id=$1 FOR UPDATE", [
                      earlier_b
                    ])

                    race_hold(parent, gate, :binding_b)
                    :ok
                  end)
                end,
                fn binding_b ->
                  {bp, _bb} = race_ready(gate, :binding_b)
                  send(bp, {gate, :start})
                  race_checkpoint(gate, :binding_b)
                  send(rp, {gate, :continue})
                  assert :ok = Task.await(resource, @barrier_timeout)
                  # B remains exclusively held until the actual INSERT has completed.
                  assert :ok = Task.await(organization, @barrier_timeout)
                  send(bp, {gate, :continue})
                  assert :ok = Task.await(binding_b, @barrier_timeout)

                  assert organization_effects(source, context, tag) ==
                           if(@duplicate, do: before, else: [1, 1])
                end
              )
            end
          )
        end
      )
    end
  end

  for first <- [:organization, :save] do
    @first first
    test "real Note Save and organization converge with #{@first} holding source locks first" do
      source = prepared_source!()
      note = KnowledgeFixtures.note!(source)
      grant_note_sources!(source)
      context = organization_context(source)
      tag = tag!(source)
      request = save_request(source, note, false)
      gate = make_ref()
      parent = self()

      organization = fn ->
        race_scoped(source, fn _repo ->
          result = TagRepository.attach_in_scope(context, text(source.resource_id), text(tag))
          if @first == :organization, do: race_hold(parent, gate, :first)
          result
        end)
      end

      save = fn ->
        race_scoped(source, fn repo ->
          result = NoteRepository.save(repo, request)
          if @first == :save, do: race_hold(parent, gate, :first)
          result
        end)
      end

      {first, second} =
        if @first == :organization, do: {organization, save}, else: {save, organization}

      ordered_race(gate, first, second, fn first_result, second_result ->
        {organization_result, save_result} =
          if @first == :organization,
            do: {first_result, second_result},
            else: {second_result, first_result}

        assert :ok = organization_result
        assert {:ok, %NoteSaveResult{outcome: :saved} = saved} = save_result
        assert_saved_source(source, saved)
        assert organization_effects(source, context, tag) == [1, 1]
      end)
    end
  end

  test "synthetic finalization storage fixture reserves the existing stage and object for reuse" do
    source = prepared_source!()
    envelope = finalization_fixture!(source)

    assert %{rows: [[stage]]} =
             scoped(source, fn repo ->
               query!(repo, "SELECT id FROM content.asset_stages WHERE asset_id=$1", [
                 source.asset_id
               ])
             end)

    stage_id = text(stage)
    object_id = text(source.object_id)

    assert {:ok,
            %{
              status: :reserved,
              action: :reuse,
              stage_id: ^stage_id,
              stage_ref: %Singularity.Core.StageRef{stage_id: ^stage_id},
              object_id: ^object_id,
              object_ref: %Singularity.Core.ObjectRef{object_id: ^object_id}
            }} =
             scoped(source, fn repo ->
               AssetRepository.reserve_finalization(repo, %{
                 envelope: envelope,
                 object_id: object_id
               })
             end)
  end

  for first <- [:organization, :finalization] do
    @first first
    test "real finalization reservation and organization preserve Asset order with #{@first} first" do
      source = prepared_source!()
      envelope = finalization_fixture!(source)
      context = organization_context(source)
      tag = tag!(source)
      gate = make_ref()
      parent = self()

      organization = fn ->
        race_scoped(source, fn _repo ->
          result = TagRepository.attach_in_scope(context, text(source.resource_id), text(tag))
          if @first == :organization, do: race_hold(parent, gate, :first)
          result
        end)
      end

      finalization = fn ->
        race_scoped(source, fn repo ->
          result =
            AssetRepository.reserve_finalization(repo, %{
              envelope: envelope,
              object_id: text(source.object_id)
            })

          if @first == :finalization, do: race_hold(parent, gate, :first)
          result
        end)
      end

      {first, second} =
        if @first == :organization,
          do: {organization, finalization},
          else: {finalization, organization}

      ordered_race(gate, first, second, fn first_result, second_result ->
        {organization_result, finalization_result} =
          if @first == :organization,
            do: {first_result, second_result},
            else: {second_result, first_result}

        assert :ok = organization_result
        assert {:ok, %{action: :reuse}} = finalization_result
        assert organization_effects(source, context, tag) == [1, 1]
      end)
    end
  end

  for first <- [:save, :finalization] do
    @first first
    test "retained Note Save and real finalization reservation converge with #{@first} first" do
      source = prepared_source!()
      note = retained_note!(source)
      grant_note_sources!(source)
      envelope = finalization_fixture!(source)
      request = save_request(source, note, true)
      gate = make_ref()
      parent = self()

      save = fn ->
        race_scoped(source, fn repo ->
          result = NoteRepository.save(repo, request)
          if @first == :save, do: race_hold(parent, gate, :first)
          result
        end)
      end

      finalization = fn ->
        race_scoped(source, fn repo ->
          result =
            AssetRepository.reserve_finalization(repo, %{
              envelope: envelope,
              object_id: text(source.object_id)
            })

          if @first == :finalization, do: race_hold(parent, gate, :first)
          result
        end)
      end

      {first, second} = if @first == :save, do: {save, finalization}, else: {finalization, save}

      ordered_race(gate, first, second, fn first_result, second_result ->
        {save_result, finalization_result} =
          if @first == :save,
            do: {first_result, second_result},
            else: {second_result, first_result}

        assert {:ok, %NoteSaveResult{outcome: :saved} = saved} = save_result
        assert {:ok, %{action: :reuse}} = finalization_result
        assert_saved_source(source, saved)
      end)
    end
  end

  defp ordered_race(gate, first, second, assert_results) do
    with_race_connection(:first, gate, first, fn a ->
      {ap, ab} = race_ready(gate, :first)
      send(ap, {gate, :start})
      race_checkpoint(gate, :first)

      with_race_connection(:second, gate, second, fn b ->
        {bp, bb} = race_ready(gate, :second)
        refute ab == bb
        send(bp, {gate, :start})
        observed_block!(bb, ab)
        send(ap, {gate, :continue})
        assert_results.(Task.await(a, @barrier_timeout), Task.await(b, @barrier_timeout))
      end)
    end)
  end

  defp with_race_connection(label, gate, operation, callback) do
    parent = self()

    task =
      Task.async(fn ->
        try do
          RequestRepo.checkout(fn ->
            %{rows: [[backend]]} = query!(RequestRepo, "SELECT pg_backend_pid()")
            send(parent, {gate, :ready, label, self(), backend})
            race_wait(gate, :start)
            result = operation.()

            assert %{rows: [[nil, nil]]} =
                     query!(
                       RequestRepo,
                       "SELECT nullif(current_setting('singularity.principal_id',true),''),nullif(current_setting('singularity.vault_id',true),'')"
                     )

            result
          end)
        rescue
          exception -> {:child_exception, exception.__struct__}
        end
      end)

    try do
      callback.(task)
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp race_ready(gate, label) do
    receive do
      {^gate, :ready, ^label, pid, backend} -> {pid, backend}
    after
      @barrier_timeout -> flunk("lifecycle connection ready barrier timed out")
    end
  end

  defp race_hold(parent, gate, checkpoint) do
    send(parent, {gate, :checkpoint, checkpoint, self()})
    race_wait(gate, :continue)
  end

  defp race_checkpoint(gate, checkpoint) do
    receive do
      {^gate, :checkpoint, ^checkpoint, pid} -> pid
    after
      @barrier_timeout -> flunk("lifecycle checkpoint barrier timed out")
    end
  end

  defp race_wait(gate, action) do
    receive do
      {^gate, ^action} -> :ok
    after
      @barrier_timeout -> raise "lifecycle connection barrier timed out"
    end
  end

  defp observed_block!(waiting, blocking),
    do: observe_block(waiting, blocking, System.monotonic_time(:millisecond) + @barrier_timeout)

  defp observe_block(waiting, blocking, deadline) do
    %{rows: [[blocked]]} =
      query!(RequestRepo, "SELECT $2::integer=ANY(pg_blocking_pids($1::integer))", [
        waiting,
        blocking
      ])

    unless blocked do
      assert System.monotonic_time(:millisecond) < deadline,
             "lifecycle writer did not block on the expected backend"

      observe_block(waiting, blocking, deadline)
    end

    :ok
  end

  defp race_scoped(source, fun) do
    scoped(source, fn repo ->
      query!(repo, "SET LOCAL lock_timeout='5s'")
      fun.(repo)
    end)
  end

  defp organization_context(source),
    do: %{
      repo: RequestRepo,
      principal_id: text(source.principal_id),
      owner_scope_id: text(source.vault_id),
      correlation_id: Ecto.UUID.generate()
    }

  defp attach(source, context, tag),
    do:
      race_scoped(source, fn _repo ->
        TagRepository.attach_in_scope(context, text(source.resource_id), text(tag))
      end)

  defp organization_effects(source, context, tag) do
    %{rows: [counts]} =
      scoped(source, fn repo ->
        query!(
          repo,
          "SELECT (SELECT count(*) FROM content.resource_tags WHERE resource_id=$1 AND tag_id=$2),(SELECT count(*) FROM audit.events WHERE correlation_id=$3 AND operation='knowledge.tag_attached')",
          [source.resource_id, tag, Ecto.UUID.dump!(context.correlation_id)]
        )
      end)

    counts
  end

  defp real_delete(source, checkpoint \\ fn -> :ok end) do
    RequestRepo.checkout(fn ->
      ObjectLock.with_exclusive(RequestRepo, text(source.object_id), fn ->
        race_scoped(source, fn repo ->
          %{rows: [[revision]]} =
            query!(repo, "SELECT state_revision FROM content.assets WHERE id=$1", [
              source.asset_id
            ])

          result =
            AssetDeletionRepository.tombstone_and_release(repo, %{
              asset_id: text(source.asset_id),
              vault_id: text(source.vault_id),
              principal_id: text(source.principal_id),
              classification: :private,
              expected_state_revision: revision,
              locked_object_id: text(source.object_id)
            })

          checkpoint.()
          result
        end)
      end)
    end)
  end

  defp upload_binding!(source, asset_id \\ KnowledgeFixtures.uuid()) do
    command = %{
      idempotency_key: "lifecycle-upload:" <> text(asset_id),
      asset_id: text(asset_id),
      vault_id: text(source.vault_id),
      resource_version_id: text(source.resource_version_id),
      source_reference_id: Ecto.UUID.generate(),
      resource_version_classification: :private,
      classification: :private,
      principal_id: text(source.principal_id),
      filename: "lifecycle.txt",
      declared_media_type: "text/plain",
      byte_size: 12,
      digest: "sha256:lifecycle",
      server_observed_at: DateTime.utc_now(:microsecond)
    }

    assert {:ok, _intent} =
             race_scoped(source, fn repo ->
               Assets.create_upload_intent(%{repository: AssetRepository, context: repo}, command)
             end)

    asset_id
  end

  defp grant_note_sources!(source) do
    Fixtures.with_owner(fn ->
      for name <- ["note.write", "asset.read"] do
        query!(
          MigrationRepo,
          "INSERT INTO core.capabilities(id,name) VALUES($1,$2) ON CONFLICT(name) DO NOTHING",
          [KnowledgeFixtures.uuid(), name]
        )

        query!(
          MigrationRepo,
          "INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name=$3 ON CONFLICT DO NOTHING",
          [source.principal_id, source.vault_id, name]
        )
      end
    end)
  end

  defp retained_note!(source) do
    KnowledgeFixtures.note!(source, fn note ->
      query!(
        MigrationRepo,
        "INSERT INTO content.note_attachments(note_resource_version_id,id,note_resource_id,vault_id,classification,target_resource_id,target_resource_version_id,target_kind,ordinal,role,inserted_at) VALUES($1,$2,$3,$4,'private',$5,$6,'asset',0,'source',CURRENT_TIMESTAMP)",
        [
          note.resource_version_id,
          KnowledgeFixtures.uuid(),
          note.resource_id,
          source.vault_id,
          source.resource_id,
          source.resource_version_id
        ]
      )
    end)
  end

  defp save_request(source, note, retained?) do
    attrs = %{
      classification: :private,
      title: "Lifecycle",
      markdown: "body",
      parent_version_id: text(note.resource_version_id)
    }

    attrs =
      if retained?,
        do: attrs,
        else:
          Map.merge(attrs, %{
            attachments: [
              %{
                attachment_id: Ecto.UUID.generate(),
                target_resource_id: text(source.resource_id),
                target_resource_version_id: text(source.resource_version_id),
                target_kind: :asset,
                role: :source,
                label: "original"
              }
            ],
            citations: []
          })

    assert {:ok, snapshot} = NoteSnapshot.normal(attrs)

    request = %{
      mutation_id: Ecto.UUID.generate(),
      correlation_id: Ecto.UUID.generate(),
      principal_id: text(source.principal_id),
      vault_id: text(source.vault_id),
      classification: :private,
      snapshot: snapshot,
      resource_id: text(note.resource_id),
      base_version_id: text(note.resource_version_id)
    }

    Map.put(
      request,
      :request_fingerprint,
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary(Map.drop(request, [:mutation_id, :correlation_id]), [
          :deterministic
        ])
      )
    )
  end

  defp assert_saved_source(source, saved) do
    assert %{rows: [[target, version]]} =
             scoped(source, fn repo ->
               query!(
                 repo,
                 "SELECT target_resource_id,target_resource_version_id FROM content.note_attachments WHERE note_resource_version_id=$1",
                 [Ecto.UUID.dump!(saved.submitted_version_id)]
               )
             end)

    assert target == source.resource_id
    assert version == source.resource_version_id
  end

  defp finalization_fixture!(source) do
    %{rows: [[principal_epoch, owner_epoch]]} =
      scoped(source, fn repo ->
        query!(
          repo,
          "SELECT principal_authorization_epoch,vault_authorization_epoch FROM core.live_principal_authorization()"
        )
      end)

    grant = KnowledgeFixtures.uuid()
    stage = KnowledgeFixtures.uuid()
    source_reference = KnowledgeFixtures.uuid()
    idempotency_key = "lifecycle-finalization:" <> text(grant)

    Fixtures.with_owner(fn ->
      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 "INSERT INTO content.source_references(id,vault_id,resource_version_id,principal_id,classification,kind,observed_at,original_filename,declared_media_type,byte_size,idempotency_key_digest) VALUES($1,$2,$3,$4,'private','browser_upload',CURRENT_TIMESTAMP,'lifecycle.txt','text/plain',12,$5)",
                 [
                   source_reference,
                   source.vault_id,
                   source.resource_version_id,
                   source.principal_id,
                   :crypto.hash(:sha256, idempotency_key)
                 ]
               )

      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 "INSERT INTO content.upload_grants(id,vault_id,session_id,principal_id,asset_id,classification,token_digest,csrf_token_digest,filename,byte_size,declared_media_type,idempotency_key,principal_authorization_epoch,vault_authorization_epoch,expires_at,consumed_at,source_reference_id) VALUES($1,$2,$3,$4,$5,'private',$6,$6,'lifecycle.txt',12,'text/plain',$7,$8,$9,CURRENT_TIMESTAMP+interval '5 minutes',CURRENT_TIMESTAMP,$10)",
                 [
                   grant,
                   source.vault_id,
                   source.session_id,
                   source.principal_id,
                   source.asset_id,
                   :crypto.hash(:sha256, grant),
                   idempotency_key,
                   principal_epoch,
                   owner_epoch,
                   source_reference
                 ]
               )

      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 "UPDATE content.asset_metadata SET projection_version=1,original_filename='lifecycle.txt',declared_media_type='text/plain',plaintext_byte_size=12,extraction_state='pending',extractor_version='upload_text_v1',detected_media_type=NULL,completed_at=NULL,pdf_header_version=NULL,image_width=NULL,image_height=NULL WHERE asset_id=$1 AND resource_version_id=$2 AND vault_id=$3 AND classification='private'",
                 [source.asset_id, source.resource_version_id, source.vault_id]
               )

      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 """
                 INSERT INTO content.asset_stages(id,asset_id,vault_id,key_domain_id,classification,storage_ref,state,state_revision,format_version,plaintext_byte_size,ciphertext_byte_size,lookup_digest,ciphertext_hash,sealed_at,upload_grant_id,candidate_object_id,domain_key_version_id,wrapper_algorithm,key_generation,dek_wrapper)
                 SELECT $1::uuid,$2,o.vault_id,o.key_domain_id,o.classification,$1::uuid::text,'sealed',1,o.format_version,o.plaintext_byte_size,o.ciphertext_byte_size,o.lookup_digest,o.ciphertext_hash,CURRENT_TIMESTAMP,$3,$4,e.domain_key_version_id,e.algorithm,e.key_generation,e.wrapped_dek
                 FROM content.asset_objects o JOIN content.asset_key_envelopes e ON e.asset_object_id=o.id AND e.vault_id=o.vault_id
                 WHERE o.id=$5
                 """,
                 [stage, source.asset_id, grant, KnowledgeFixtures.uuid(), source.object_id]
               )

      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 "UPDATE content.assets SET state='verified',state_revision=2 WHERE id=$1",
                 [source.asset_id]
               )
    end)

    assert {:ok, envelope} =
             JobEnvelope.new(%{
               version: 1,
               job_id: Ecto.UUID.generate(),
               job_type: "asset_finalize",
               idempotency_key: "lifecycle-finalize:" <> text(stage),
               vault_id: text(source.vault_id),
               principal_id: text(source.principal_id),
               required_capability: "asset.write",
               principal_authorization_epoch: principal_epoch,
               vault_authorization_epoch: owner_epoch,
               classification: :private,
               correlation_id: Ecto.UUID.generate(),
               causation_id: Ecto.UUID.generate(),
               expected_entity_revision: 2,
               attempt: 0,
               payload: %{"asset_id" => text(source.asset_id)}
             })

    envelope
  end

  defp text(value), do: Ecto.UUID.load!(value)

  defp liveness(source) do
    %{rows: [values]} =
      scoped(source, fn repo ->
        query!(
          repo,
          "SELECT content.knowledge_asset_binding_is_live($1,$2,$3),content.knowledge_resource_is_live($1,$4),content.lock_knowledge_organization_resources($1,ARRAY[$4]::uuid[])",
          [source.vault_id, source.resource_version_id, source.asset_id, source.resource_id]
        )
      end)

    values
  end

  defp binding(source, version, asset) do
    %{rows: [[live]]} =
      scoped(
        source,
        &query!(&1, "SELECT content.knowledge_asset_binding_is_live($1,$2,$3)", [
          source.vault_id,
          version,
          asset
        ])
      )

    live
  end

  defp guard(source, roots) do
    %{rows: [[live]]} =
      scoped(
        source,
        &query!(&1, "SELECT content.lock_knowledge_organization_resources($1,$2::uuid[])", [
          source.vault_id,
          roots
        ])
      )

    live
  end

  defp scoped(source, fun), do: ScopedRepo.transact(RequestRepo, source, fun)

  defp tag!(source) do
    tag = KnowledgeFixtures.uuid()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.tags(id,vault_id,classification,display_value,normalized_key,created_by_principal_id,inserted_at) VALUES($1,$2,'private','Lifecycle','lifecycle',$3,CURRENT_TIMESTAMP)",
        [tag, source.vault_id, source.principal_id]
      )
    end)

    tag
  end

  defp insert_tag(repo, source, resource, tag) do
    query!(
      repo,
      "INSERT INTO content.resource_tags(resource_id,tag_id,vault_id,classification,inserted_at) VALUES($1,$2,$3,'private',CURRENT_TIMESTAMP) ON CONFLICT (resource_id,tag_id,vault_id) DO NOTHING",
      [resource, tag, source.vault_id]
    )
  end

  defp security_snapshot do
    table_grants =
      query!(
        RequestRepo,
        "SELECT n.nspname,c.relname,c.relowner,c.relacl::text,c.relrowsecurity,c.relforcerowsecurity FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('content','core','identity','audit','jobs') AND c.relkind IN ('r','p','v','m','S') ORDER BY n.nspname,c.relname"
      ).rows

    roles =
      query!(
        RequestRepo,
        "SELECT rolname,rolsuper,rolinherit,rolcreaterole,rolcreatedb,rolcanlogin,rolreplication,rolbypassrls FROM pg_roles WHERE rolname LIKE 'singularity_%' ORDER BY rolname"
      ).rows

    memberships =
      query!(
        RequestRepo,
        "SELECT roleid,member,grantor,admin_option FROM pg_auth_members ORDER BY roleid,member,grantor"
      ).rows

    {table_grants, roles, memberships}
  end

  defp organization_rows(source) do
    Fixtures.with_owner(fn ->
      {
        query!(
          MigrationRepo,
          "SELECT * FROM content.resource_tags WHERE vault_id=$1 ORDER BY resource_id,tag_id",
          [source.vault_id]
        ).rows,
        query!(
          MigrationRepo,
          "SELECT * FROM content.relationships WHERE vault_id=$1 ORDER BY id",
          [source.vault_id]
        ).rows
      }
    end)
  end

  defp migration_head do
    {:ok, pid} = MigrationRepo.start_link()

    try do
      query!(MigrationRepo, "SELECT max(version) FROM schema_migrations")
    after
      Supervisor.stop(pid)
    end
  end

  defp migrate! do
    {:ok, pid} = MigrationRepo.start_link()
    compiler_options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      path =
        :singularity_storage |> :code.priv_dir() |> to_string() |> Path.join("repo/migrations")

      Ecto.Migrator.run(MigrationRepo, path, :up, to: @version, log: false)
    after
      Code.compiler_options(compiler_options)
      Supervisor.stop(pid)
    end
  end
end
