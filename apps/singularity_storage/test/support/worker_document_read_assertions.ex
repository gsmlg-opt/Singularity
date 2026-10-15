defmodule Singularity.Storage.WorkerDocumentReadAssertions do
  @moduledoc false

  import ExUnit.Assertions
  import Singularity.Storage.DataCase, only: [query!: 3]

  alias Singularity.Storage.{Fixtures, KnowledgeFixtures, MigrationRepo, ScopedRepo, WorkerRepo}

  @document_fields ~w(resource_version_id resource_id vault_id classification source_asset_id source_resource_id source_resource_version_id source_object_id source_digest source_byte_size media_type title created_by_principal_id state extracted_text_digest detected_language)
  @fragment_fields ~w(id resource_id resource_version_id vault_id classification ordinal text digest locator)
  @tables [{"document_versions", @document_fields}, {"document_fragments", @fragment_fields}]
  @text_digest Base.decode16!("982d9e3eb996f559e633f4d194def3761d909f5a3b647d1a851fead67c32c9d1",
                 case: :lower
               )
  @locator %{"version" => 1, "kind" => "text", "start_line" => 1, "end_line" => 1}
  @empty %{"document_versions" => [], "document_fragments" => []}

  def assert_read_only_rls! do
    own_source = KnowledgeFixtures.source!()
    {own_document, _own_fragment} = KnowledgeFixtures.ready_document!(own_source)
    KnowledgeFixtures.retire_document_on_exit!(own_document)

    foreign_source = KnowledgeFixtures.source!()
    {foreign_document, _foreign_fragment} = KnowledgeFixtures.ready_document!(foreign_source)
    KnowledgeFixtures.retire_document_on_exit!(foreign_document)

    versions = [own_document.resource_version_id, foreign_document.resource_version_id]
    own_rows = expected_rows(own_source, own_document)
    foreign_rows = expected_rows(foreign_source, foreign_document)
    snapshot = full_rows(versions)

    WorkerRepo.checkout(fn ->
      %{rows: [[backend, "singularity_worker"]]} =
        query!(WorkerRepo, "SELECT pg_backend_pid(), current_user::text", [])

      assert_catalog!()
      assert_clean!(backend, versions, snapshot)

      for {context, expected} <- [
            {scope(own_source), own_rows},
            {scope(foreign_source), foreign_rows},
            {%{scope(own_source) | vault_id: foreign_source.vault_id}, @empty},
            {%{scope(foreign_source) | vault_id: own_source.vault_id}, @empty}
          ] do
        assert_scoped_rows!(context, expected, backend, versions, snapshot)
      end

      for setting <- ["singularity.principal_id", "singularity.vault_id"] do
        assert :ok =
                 ScopedRepo.transact(WorkerRepo, scope(own_source), fn repo ->
                   assert_backend!(backend)
                   assert repo.in_transaction?()

                   assert %{rows: [[""]]} =
                            query!(repo, "SELECT set_config($1,'',true)", [setting])

                   assert projected_rows(versions) == @empty
                   :ok
                 end)

        assert_clean!(backend, versions, snapshot)
      end

      assert {:error, :read_probe_rollback} =
               ScopedRepo.transact(WorkerRepo, scope(own_source), fn repo ->
                 assert_backend!(backend)
                 assert repo.in_transaction?()
                 assert projected_rows(versions) == own_rows
                 repo.rollback(:read_probe_rollback)
               end)

      assert_clean!(backend, versions, snapshot)

      for {table, _fields} <- @tables,
          {statement, parameters} <- [
            {"INSERT INTO content.#{table} SELECT * FROM content.#{table} WHERE resource_version_id=$1",
             [own_document.resource_version_id]},
            {"UPDATE content.#{table} SET classification='private' WHERE resource_version_id=$1",
             [own_document.resource_version_id]},
            {"DELETE FROM content.#{table} WHERE resource_version_id=$1",
             [own_document.resource_version_id]},
            {"TRUNCATE content.#{table}", []}
          ] do
        result =
          ScopedRepo.transact(WorkerRepo, scope(own_source), fn repo ->
            assert_backend!(backend)
            assert repo.in_transaction?()

            case Ecto.Adapters.SQL.query(repo, statement, parameters, log: false) do
              {:ok, _result} -> repo.rollback(:unexpected_write_success)
              {:error, error} -> {:error, error}
            end
          end)

        assert_clean!(backend, versions, snapshot)

        assert {:error,
                %Postgrex.Error{
                  postgres: %{code: :insufficient_privilege, pg_code: "42501"}
                }} = result
      end

      Fixtures.revoke_membership!(own_source)
      assert_clean!(backend, versions, snapshot)
      assert_scoped_rows!(scope(own_source), @empty, backend, versions, snapshot)
      assert_scoped_rows!(scope(foreign_source), foreign_rows, backend, versions, snapshot)
      :ok
    end)
  end

  defp expected_rows(source, document) do
    %{
      "document_versions" => [
        [
          document.resource_version_id,
          document.resource_id,
          source.vault_id,
          "private",
          source.asset_id,
          source.resource_id,
          source.resource_version_id,
          source.object_id,
          :crypto.hash(:sha256, "source bytes"),
          12,
          "text/plain",
          "Document",
          source.principal_id,
          "ready",
          @text_digest,
          "en"
        ]
      ],
      "document_fragments" => [
        [
          expected_fragment_id(document.resource_version_id),
          document.resource_id,
          document.resource_version_id,
          source.vault_id,
          "private",
          0,
          "text",
          @text_digest,
          @locator
        ]
      ]
    }
  end

  # Independent fixed v1 framing for the literal text locator, not the fixture's
  # DocumentFragment constructor or an owner SELECT used as the expected value.
  defp expected_fragment_id(version) do
    locator = <<1::64, "1", 4::64, "text", 1::64, "1", 1::64, "1">>
    version = Ecto.UUID.load!(version)

    :crypto.hash(:sha256, [
      "singularity:document-fragment:v1",
      <<0, 36::64, version::binary, byte_size(locator)::64, locator::binary, 1::64, "0", 32::64,
        @text_digest::binary>>
    ])
    |> Base.encode16(case: :lower)
  end

  defp assert_catalog! do
    for {table, fields} <- @tables do
      relation = "content." <> table

      assert %{rows: [[true, true, false, false]]} =
               query!(
                 WorkerRepo,
                 """
                 SELECT c.relrowsecurity, c.relforcerowsecurity,
                   EXISTS (SELECT 1 FROM aclexplode(COALESCE(c.relacl, acldefault('r',c.relowner))) a
                     WHERE a.grantee=0 AND a.privilege_type='SELECT'),
                   EXISTS (SELECT 1 FROM pg_attribute att CROSS JOIN LATERAL aclexplode(att.attacl) a
                     WHERE att.attrelid=c.oid AND att.attnum>0 AND NOT att.attisdropped
                       AND a.grantee=0 AND a.privilege_type='SELECT')
                 FROM pg_class c WHERE c.oid=$1::text::regclass
                 """,
                 [relation]
               )

      for role <-
            ~w(singularity_web singularity_worker singularity_pre_auth singularity_dispatcher) do
        expected_read = role in ~w(singularity_web singularity_worker)

        assert %{rows: [[can_read, false, false, false, false, false, false]]} =
                 query!(
                   WorkerRepo,
                   """
                   SELECT has_table_privilege($1,$2,'SELECT'),
                     has_table_privilege($1,$2,'INSERT'),
                     has_table_privilege($1,$2,'UPDATE'),
                     has_table_privilege($1,$2,'DELETE'),
                     has_table_privilege($1,$2,'TRUNCATE'),
                     has_any_column_privilege($1,$2,'INSERT'),
                     has_any_column_privilege($1,$2,'UPDATE')
                   """,
                   [role, relation]
                 )

        assert can_read == expected_read

        for field <- fields do
          assert %{rows: [[can_read_column]]} =
                   query!(WorkerRepo, "SELECT has_column_privilege($1,$2,$3,'SELECT')", [
                     role,
                     relation,
                     field
                   ])

          assert can_read_column == expected_read
        end
      end
    end
  end

  defp assert_scoped_rows!(context, expected, backend, versions, snapshot) do
    assert :ok =
             ScopedRepo.transact(WorkerRepo, context, fn repo ->
               assert_backend!(backend)
               assert repo.in_transaction?()
               assert projected_rows(versions) == expected
               :ok
             end)

    assert_clean!(backend, versions, snapshot)
  end

  defp assert_clean!(backend, versions, snapshot) do
    assert_backend!(backend)
    refute WorkerRepo.in_transaction?()

    assert %{rows: [[principal, owner]]} =
             query!(
               WorkerRepo,
               "SELECT current_setting('singularity.principal_id',true), current_setting('singularity.vault_id',true)",
               []
             )

    assert principal in [nil, ""]
    assert owner in [nil, ""]
    assert projected_rows(versions) == @empty
    assert full_rows(versions) == snapshot
    assert_backend!(backend)
  end

  defp assert_backend!(backend) do
    assert %{rows: [[^backend, "singularity_worker"]]} =
             query!(WorkerRepo, "SELECT pg_backend_pid(), current_user::text", [])
  end

  defp projected_rows(versions) do
    Map.new(@tables, fn {table, fields} ->
      result =
        query!(
          WorkerRepo,
          "SELECT #{Enum.join(fields, ",")} FROM content.#{table} WHERE resource_version_id IN ($1,$2) ORDER BY resource_version_id",
          versions
        )

      assert result.columns == fields
      {table, result.rows}
    end)
  end

  defp full_rows(versions) do
    Fixtures.with_owner(fn ->
      Map.new(@tables, fn {table, _fields} ->
        result =
          query!(
            MigrationRepo,
            "SELECT * FROM content.#{table} WHERE resource_version_id IN ($1,$2) ORDER BY resource_version_id",
            versions
          )

        assert [_, _] = result.rows
        {table, {result.columns, result.rows}}
      end)
    end)
  end

  defp scope(source), do: Map.take(source, [:principal_id, :vault_id])
end
