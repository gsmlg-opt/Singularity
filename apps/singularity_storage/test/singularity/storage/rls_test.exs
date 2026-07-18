defmodule Singularity.Storage.RLSTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.ScopedRepo

  setup do
    Fixtures.two_vaults!()
  end

  test "missing and empty-reset context fail closed without UUID cast errors" do
    for repo <- [RequestRepo, WorkerRepo] do
      assert %{rows: [[0]]} = query!(repo, "SELECT count(*) FROM content.assets")

      repo.checkout(fn ->
        try do
          query!(
            repo,
            """
            SELECT
              set_config('singularity.principal_id', '', false),
              set_config('singularity.vault_id', '', false)
            """
          )

          assert %{rows: [[0]]} = query!(repo, "SELECT count(*) FROM content.assets")
        after
          query!(
            repo,
            """
            SELECT
              set_config('singularity.principal_id', '', false),
              set_config('singularity.vault_id', '', false)
            """
          )
        end
      end)
    end
  end

  test "request and worker roles cannot read, mutate, search, count, or infer another vault", %{
    one: one,
    two: two
  } do
    for repo <- [RequestRepo, WorkerRepo] do
      assert :ok =
               ScopedRepo.transact(
                 repo,
                 %{principal_id: one.principal_id, vault_id: one.vault_id},
                 fn checked_out_repo ->
                   assert %{rows: [[one_asset]]} =
                            query!(
                              checked_out_repo,
                              "SELECT id FROM content.assets ORDER BY id"
                            )

                   assert one_asset == one.asset_id

                   assert %{rows: [[1]]} =
                            query!(
                              checked_out_repo,
                              "SELECT count(*) FROM content.asset_search_documents"
                            )

                   assert %{num_rows: 0} =
                            query!(
                              checked_out_repo,
                              "UPDATE content.assets SET state = 'deleted' WHERE id = $1",
                              [two.asset_id]
                            )

                   assert %{rows: [[0]]} =
                            query!(
                              checked_out_repo,
                              "SELECT count(*) FROM content.assets WHERE vault_id = $1",
                              [two.vault_id]
                            )

                   :ok
                 end
               )
    end
  end

  test "authorization helper is live, non-recursive, and not a cross-context oracle", %{
    one: one,
    two: two
  } do
    assert :ok =
             ScopedRepo.transact(
               RequestRepo,
               %{principal_id: one.principal_id, vault_id: one.vault_id},
               fn repo ->
                 assert authorized?(repo, one.principal_id, one.vault_id)
                 refute authorized?(repo, one.principal_id, two.vault_id)
                 refute authorized?(repo, two.principal_id, one.vault_id)
                 :ok
               end
             )

    Fixtures.revoke_membership!(one)

    assert :ok =
             RequestRepo.checkout(fn ->
               RequestRepo.transaction(fn ->
                 query!(
                   RequestRepo,
                   """
                   SELECT
                     set_config('singularity.principal_id', $1, true),
                     set_config('singularity.vault_id', $2, true)
                   """,
                   [
                     Ecto.UUID.load!(one.principal_id),
                     Ecto.UUID.load!(one.vault_id)
                   ]
                 )

                 refute authorized?(RequestRepo, one.principal_id, one.vault_id)
               end)

               :ok
             end)
  end

  defp authorized?(repo, principal_id, vault_id) do
    %{rows: [[authorized?]]} =
      query!(
        repo,
        "SELECT core.principal_is_authorized($1::uuid, $2::uuid)",
        [principal_id, vault_id]
      )

    authorized?
  end
end
