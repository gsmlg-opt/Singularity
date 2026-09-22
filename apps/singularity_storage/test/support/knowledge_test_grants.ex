defmodule Singularity.Storage.KnowledgeTestGrants do
  @moduledoc false
  import Singularity.Storage.DataCase, only: [query!: 2]
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

    Fixtures.with_owner(fn ->
      assert_isolated_database!()

      for table <- tables, role <- @roles do
        query!(MigrationRepo, "GRANT SELECT, INSERT ON content.#{table} TO #{role}")
      end

      if "document_versions" in tables do
        for role <- @roles do
          query!(
            MigrationRepo,
            "GRANT EXECUTE ON FUNCTION content.document_trim_name(text) TO #{role}"
          )
        end
      end
    end)

    try do
      fun.()
    after
      Fixtures.with_owner(fn ->
        assert_isolated_database!()

        for table <- tables, role <- @roles do
          query!(MigrationRepo, "REVOKE SELECT, INSERT ON content.#{table} FROM #{role}")
        end

        if "document_versions" in tables do
          for role <- @roles do
            query!(
              MigrationRepo,
              "REVOKE EXECUTE ON FUNCTION content.document_trim_name(text) FROM #{role}"
            )
          end
        end
      end)
    end
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
    with_permissions(
      for(role <- @roles, do: {"SELECT ON content.document_fragments", role}),
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

  defp assert_isolated_database! do
    %{rows: [[database]]} = query!(MigrationRepo, "SELECT current_database()")

    unless database =~ ~r/\Asingularity_test_[0-9a-f]{24}\z/ do
      raise ArgumentError, "knowledge grants require an allocated isolated test database"
    end
  end
end
