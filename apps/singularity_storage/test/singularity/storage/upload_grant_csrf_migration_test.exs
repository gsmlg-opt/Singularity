defmodule Singularity.Storage.UploadGrantCsrfMigrationTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Storage.{Fixtures, MigrationRepo, MigrationTestEnvironment}
  alias Singularity.Storage.Migrations.SecureUploadGrantCsrf

  @version 20_260_728_000_100
  @previous_version 20_260_722_001_000

  test "legacy grants fail closed and the migration round-trips their prior consumption state" do
    MigrationTestEnvironment.with_database(@previous_version, fn _environment ->
      %{one: fixture} = Fixtures.two_vaults!()
      {:ok, _migration_repo} = MigrationRepo.start_link(pool_size: 2)

      assert Code.ensure_loaded?(SecureUploadGrantCsrf)

      unconsumed_id = insert_legacy_grant!(fixture, nil)
      consumed_at = DateTime.add(DateTime.utc_now(:microsecond), -60, :second)
      consumed_id = insert_legacy_grant!(fixture, consumed_at)

      assert :ok =
               Ecto.Migrator.up(
                 MigrationRepo,
                 @version,
                 SecureUploadGrantCsrf,
                 log: false
               )

      assert {:ok, %{rows: [[false, 32]]}} =
               with_owner(fn ->
                 query!(
                   MigrationRepo,
                   """
                   SELECT consumed_at IS NULL, octet_length(csrf_token_digest)
                   FROM content.upload_grants
                   WHERE id = $1
                   """,
                   [unconsumed_id]
                 )
               end)

      assert {:ok, %{rows: [[false, 32]]}} =
               with_owner(fn ->
                 query!(
                   MigrationRepo,
                   """
                   SELECT consumed_at IS NULL, octet_length(csrf_token_digest)
                   FROM content.upload_grants
                   WHERE id = $1
                   """,
                   [consumed_id]
                 )
               end)

      assert_raise Postgrex.Error, fn ->
        with_owner(fn ->
          query!(
            MigrationRepo,
            """
            UPDATE content.upload_grants
            SET csrf_token_digest = $2
            WHERE id = $1
            """,
            [unconsumed_id, :binary.copy(<<1>>, 31)]
          )
        end)
      end

      assert :ok =
               Ecto.Migrator.down(
                 MigrationRepo,
                 @version,
                 SecureUploadGrantCsrf,
                 log: false
               )

      assert {:ok, %{rows: [[true, nil]]}} =
               with_owner(fn ->
                 query!(
                   MigrationRepo,
                   """
                   SELECT consumed_at IS NULL, consumed_at
                   FROM content.upload_grants
                   WHERE id = $1
                   """,
                   [unconsumed_id]
                 )
               end)

      assert {:ok, %{rows: [[false, ^consumed_at]]}} =
               with_owner(fn ->
                 query!(
                   MigrationRepo,
                   """
                   SELECT consumed_at IS NULL, consumed_at
                   FROM content.upload_grants
                   WHERE id = $1
                   """,
                   [consumed_id]
                 )
               end)

      assert :ok =
               Ecto.Migrator.up(
                 MigrationRepo,
                 @version,
                 SecureUploadGrantCsrf,
                 log: false
               )
    end)
  end

  defp insert_legacy_grant!(fixture, consumed_at) do
    grant_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()

    assert {:ok, _result} =
             with_owner(fn ->
               query!(
                 MigrationRepo,
                 """
                 INSERT INTO content.upload_grants (
                   id, vault_id, session_id, principal_id, asset_id, classification,
                   token_digest, filename, byte_size, declared_media_type,
                   idempotency_key, principal_authorization_epoch,
                   vault_authorization_epoch, expires_at, consumed_at
                 ) VALUES (
                   $1, $2, $3, $4, $5, 'private', $6, 'legacy.bin', 12,
                   'application/octet-stream', $7, 0, 0,
                   CURRENT_TIMESTAMP + interval '5 minutes', $8
                 )
                 """,
                 [
                   grant_id,
                   fixture.vault_id,
                   fixture.session_id,
                   fixture.principal_id,
                   fixture.asset_id,
                   :crypto.strong_rand_bytes(32),
                   "legacy-grant-#{Ecto.UUID.generate()}",
                   consumed_at
                 ]
               )
             end)

    grant_id
  end

  defp with_owner(callback) do
    MigrationRepo.transaction(fn ->
      query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")
      callback.()
    end)
  end
end
