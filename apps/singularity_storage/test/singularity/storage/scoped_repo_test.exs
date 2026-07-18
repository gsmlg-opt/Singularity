defmodule Singularity.Storage.ScopedRepoTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Storage.ScopedRepo

  setup do
    principal_id = Ecto.UUID.generate()
    vault_id = Ecto.UUID.generate()
    {:ok, context: %{principal_id: principal_id, vault_id: vault_id}}
  end

  test "sets local context on one checked-out connection and unwraps domain results", %{
    context: context
  } do
    principal_id = context.principal_id
    vault_id = context.vault_id

    RequestRepo.checkout(fn ->
      assert {:ok, {^principal_id, ^vault_id}} =
               ScopedRepo.transact(RequestRepo, context, fn repo ->
                 %{rows: [[principal_id, vault_id]]} =
                   query!(
                     repo,
                     """
                     SELECT
                       current_setting('singularity.principal_id', true),
                       current_setting('singularity.vault_id', true)
                     """
                   )

                 {:ok, {principal_id, vault_id}}
               end)

      assert_context_absent!(RequestRepo)

      assert {:error, :rolled_back} =
               ScopedRepo.transact(RequestRepo, context, [timeout: 5_000], fn _repo ->
                 {:error, :rolled_back}
               end)

      assert_context_absent!(RequestRepo)
    end)
  end

  test "rejects a checked-out connection with pre-existing nonempty context", %{
    context: context
  } do
    RequestRepo.checkout(fn ->
      try do
        query!(
          RequestRepo,
          "SELECT set_config('singularity.principal_id', $1, false)",
          [context.principal_id]
        )

        assert_raise RuntimeError, ~r/pre-existing PostgreSQL request context/, fn ->
          ScopedRepo.transact(RequestRepo, context, fn _repo -> :ok end)
        end
      after
        query!(
          RequestRepo,
          """
          SELECT
            set_config('singularity.principal_id', '', false),
            set_config('singularity.vault_id', '', false)
          """
        )
      end
    end)
  end

  defp assert_context_absent!(repo) do
    %{rows: [[principal_id, vault_id]]} =
      query!(
        repo,
        """
        SELECT
          current_setting('singularity.principal_id', true),
          current_setting('singularity.vault_id', true)
        """
      )

    assert principal_id in [nil, ""]
    assert vault_id in [nil, ""]
  end
end
