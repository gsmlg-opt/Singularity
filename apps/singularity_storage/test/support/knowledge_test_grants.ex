defmodule Singularity.Storage.KnowledgeTestGrants do
  @moduledoc false
  import Singularity.Storage.DataCase, only: [query!: 2, query!: 3]
  alias Singularity.Storage.{Fixtures, MigrationRepo}

  @tables ~w(document_versions document_import_receipts document_fragments note_attachments note_citations tags resource_tags relationships)
  # Lifecycle execution is a separate scope from all direct table privileges.
  @functions [
    "claim_document_extraction(uuid,bigint,uuid,text,integer)",
    "complete_document_extraction(uuid,uuid,bigint,jsonb,bytea,text)",
    "fail_document_extraction(uuid,uuid,bigint,text,text)",
    "reset_document_extraction(uuid,bigint,text,integer)",
    "recover_document_extraction(uuid,bigint)"
  ]
  @roles ~w(singularity_web singularity_worker)

  def with_grants(tables, fun) when is_list(tables) and is_function(fun, 0) do
    unless tables != [] and Enum.all?(tables, &(&1 in @tables)) and Enum.uniq(tables) == tables do
      raise ArgumentError, "knowledge grants require explicit allowlisted tables"
    end

    permissions =
      for(
        table <- tables,
        role <- @roles,
        privilege <- ~w(SELECT INSERT),
        do: {"TABLE content.#{table}", role, privilege}
      ) ++
        if "document_versions" in tables do
          for role <- @roles,
              do: {"FUNCTION content.document_trim_name(text)", role, "EXECUTE"}
        else
          []
        end

    with_preserved_permissions(permissions, fun)
  end

  def with_lifecycle_grants(fun) when is_function(fun, 0) do
    with_permissions(
      for(
        function <- @functions,
        role <- @roles,
        do: {"EXECUTE ON FUNCTION content.#{function}", role}
      ),
      fun
    )
  end

  def with_receipt_grants(fun) when is_function(fun, 0) do
    with_permissions(
      for(
        role <- @roles,
        do: {"SELECT, INSERT, UPDATE ON content.document_import_receipts", role}
      ),
      fun
    )
  end

  def with_fragment_read_grants(fun) when is_function(fun, 0) do
    with_preserved_permissions(
      for(role <- @roles, do: {"TABLE content.document_fragments", role, "SELECT"}),
      fun
    )
  end

  def with_organization_delete_grants(fun) when is_function(fun, 0) do
    with_permissions(
      for(
        table <- ~w(resource_tags relationships),
        role <- @roles,
        do: {"DELETE ON content.#{table}", role}
      ),
      fun
    )
  end

  def with_direct_mutation_grants(fun) when is_function(fun, 0) do
    with_permissions(
      for(
        table <- ~w(document_versions document_fragments),
        role <- @roles,
        do: {"SELECT, INSERT, UPDATE, DELETE ON content.#{table}", role}
      ),
      fun
    )
  end

  defp with_permissions(permissions, fun) do
    Fixtures.with_owner(fn ->
      assert_isolated_database!()

      for {permission, role} <- permissions do
        query!(MigrationRepo, "GRANT #{permission} TO #{role}")
      end
    end)

    try do
      fun.()
    after
      Fixtures.with_owner(fn ->
        assert_isolated_database!()

        for {permission, role} <- permissions do
          query!(MigrationRepo, "REVOKE #{permission} FROM #{role}")
        end
      end)
    end
  end

  defp with_preserved_permissions(permissions, fun) do
    existing =
      Fixtures.with_owner(fn ->
        assert_isolated_database!()

        Map.new(permissions, fn {object, role, privilege} = permission ->
          [kind, object_name] = String.split(object, " ", parts: 2)

          function =
            case kind do
              "TABLE" -> "has_table_privilege"
              "FUNCTION" -> "has_function_privilege"
            end

          %{rows: [[allowed?]]} =
            query!(MigrationRepo, "SELECT pg_catalog.#{function}($1,$2,$3)", [
              role,
              object_name,
              privilege
            ])

          query!(MigrationRepo, "GRANT #{privilege} ON #{object} TO #{role}")
          {permission, allowed?}
        end)
      end)

    try do
      fun.()
    after
      Fixtures.with_owner(fn ->
        assert_isolated_database!()

        for {{object, role, privilege}, false} <- existing do
          query!(MigrationRepo, "REVOKE #{privilege} ON #{object} FROM #{role}")
        end
      end)
    end
  end

  defp assert_isolated_database! do
    %{rows: [[database]]} = query!(MigrationRepo, "SELECT current_database()")

    unless database =~ ~r/\Asingularity_test_[0-9a-f]{24}\z/ do
      raise ArgumentError, "knowledge grants require an allocated isolated test database"
    end
  end
end
