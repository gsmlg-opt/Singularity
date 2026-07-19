defmodule Singularity.Storage.Task12MigrationDowngradeTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Storage.{Fixtures, MigrationRepo}

  setup do
    reset_fixture_state!()
    on_exit(&reset_fixture_state!/0)
    :ok
  end

  test "downgrade refuses an open stage before changing Task 12 schema state" do
    %{one: fixture} = Fixtures.two_vaults!()
    stage_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()

    insert_open_stage!(fixture, stage_id)

    migrations_path =
      :singularity_storage
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("repo/migrations")

    {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 2)
    compiler_options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      assert_raise Postgrex.Error, ~r/cannot downgrade.*unsealed asset stages/i, fn ->
        Ecto.Migrator.run(
          MigrationRepo,
          migrations_path,
          :down,
          step: 1,
          log: false
        )
      end

      assert [] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :up,
                 all: true,
                 log: false
               )

      assert {:ok, {true, "open", nil}} =
               MigrationRepo.transaction(fn ->
                 query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

                 %{rows: [[task12_column_exists]]} =
                   query!(
                     MigrationRepo,
                     """
                     SELECT EXISTS (
                       SELECT 1
                       FROM information_schema.columns
                       WHERE table_schema = 'content'
                         AND table_name = 'asset_stages'
                         AND column_name = 'upload_grant_id'
                     )
                     """
                   )

                 %{rows: [[state, format_version]]} =
                   query!(
                     MigrationRepo,
                     """
                     SELECT state, format_version
                     FROM content.asset_stages
                     WHERE id = $1
                     """,
                     [stage_id]
                   )

                 {task12_column_exists, state, format_version}
               end)
    after
      try do
        Ecto.Migrator.run(
          MigrationRepo,
          migrations_path,
          :up,
          all: true,
          log: false
        )
      after
        Supervisor.stop(migration_repo)
        Code.compiler_options(compiler_options)
      end
    end
  end

  defp insert_open_stage!(fixture, stage_id) do
    grant_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()
    vault_key_version_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()
    key_domain_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()
    domain_key_version_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()
    candidate_object_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO core.vault_key_versions (
          id, vault_id, generation, state, algorithm, activated_at
        ) VALUES ($1, $2, 1, 'active', 'aes-256-gcm', CURRENT_TIMESTAMP)
        """,
        [vault_key_version_id, fixture.vault_id]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.key_domains (
          id, vault_id, classification, kind, state
        ) VALUES ($1, $2, 'private', 'content', 'active')
        """,
        [key_domain_id, fixture.vault_id]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.domain_key_versions (
          id,
          vault_id,
          key_domain_id,
          vault_key_version_id,
          generation,
          state,
          algorithm,
          wrapped_key
        ) VALUES ($1, $2, $3, $4, 1, 'active', 'aes-256-gcm', $5)
        """,
        [
          domain_key_version_id,
          fixture.vault_id,
          key_domain_id,
          vault_key_version_id,
          :crypto.strong_rand_bytes(60)
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO content.upload_grants (
          id,
          vault_id,
          session_id,
          principal_id,
          asset_id,
          classification,
          token_digest,
          filename,
          byte_size,
          declared_media_type,
          idempotency_key,
          principal_authorization_epoch,
          vault_authorization_epoch,
          expires_at
        ) VALUES (
          $1, $2, $3, $4, $5, 'private', $6, 'open.pdf', 12,
          'application/pdf', $7, 0, 0, CURRENT_TIMESTAMP + interval '5 minutes'
        )
        """,
        [
          grant_id,
          fixture.vault_id,
          fixture.session_id,
          fixture.principal_id,
          fixture.asset_id,
          :crypto.strong_rand_bytes(32),
          "downgrade-open-stage-#{Ecto.UUID.generate()}"
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO content.asset_stages (
          id,
          upload_grant_id,
          asset_id,
          vault_id,
          key_domain_id,
          candidate_object_id,
          domain_key_version_id,
          classification,
          storage_ref,
          state,
          wrapper_algorithm,
          key_generation,
          dek_wrapper
        ) VALUES (
          $1, $2, $3, $4, $5, $6, $7, 'private', $8, 'open',
          'aes_256_gcm', 1, $9
        )
        """,
        [
          stage_id,
          grant_id,
          fixture.asset_id,
          fixture.vault_id,
          key_domain_id,
          candidate_object_id,
          domain_key_version_id,
          "stage-#{Ecto.UUID.generate()}",
          :crypto.strong_rand_bytes(60)
        ]
      )
    end)
  end

  defp reset_fixture_state! do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "TRUNCATE TABLE core.vaults, identity.people CASCADE"
      )
    end)
  end
end
