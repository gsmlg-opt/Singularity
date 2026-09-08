defmodule Singularity.Storage.KnowledgeTestGrants do
  @moduledoc false
  import Singularity.Storage.DataCase, only: [query!: 2]
  alias Singularity.Storage.{Fixtures, MigrationRepo}

  @tables ~w(document_versions document_import_receipts)
  # Trigger functions never need caller EXECUTE. Lifecycle functions may be
  # explicitly added only with the separately implemented lifecycle contract.
  @functions []
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

      for function <- @functions, role <- @roles do
        query!(MigrationRepo, "GRANT EXECUTE ON FUNCTION content.#{function} TO #{role}")
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

        for function <- @functions, role <- @roles do
          query!(MigrationRepo, "REVOKE EXECUTE ON FUNCTION content.#{function} FROM #{role}")
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
