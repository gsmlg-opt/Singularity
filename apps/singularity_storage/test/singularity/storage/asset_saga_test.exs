defmodule Singularity.Storage.AssetSagaTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration
  @raw_secret_aliases [
    :token,
    :upload_token,
    :csrf_token,
    "token",
    "upload_token",
    "csrf_token"
  ]

  import Ecto.Query

  alias Singularity.Core.Error
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.Postgres.AssetRepository
  alias Singularity.Storage.Schema.Content.AssetStage
  alias Singularity.Storage.Schema.Content.UploadGrant
  alias Singularity.Storage.ScopedRepo

  setup do
    %{one: raw_fixture, two: raw_other} = Fixtures.two_vaults!()

    fixture =
      raw_fixture
      |> load_ids()
      |> Map.merge(insert_key_domain!(raw_fixture.vault_id))

    {:ok, fixture: fixture, other: load_ids(raw_other)}
  end

  test "atomically consumes an exactly bound grant and creates its durable open stage", %{
    fixture: fixture
  } do
    {grant, token} = insert_grant!(fixture)
    command = stage_command(fixture, grant, token)

    assert {:ok, %AssetStage{} = stage} =
             scoped(fixture, fn repo ->
               AssetRepository.consume_grant_and_create_stage(repo, command)
             end)

    assert stage.id == command.stage_id
    assert stage.upload_grant_id == grant.id
    assert stage.asset_id == grant.asset_id
    assert stage.vault_id == grant.vault_id
    assert stage.key_domain_id == command.key_domain_id
    assert stage.candidate_object_id == command.candidate_object_id
    assert stage.domain_key_version_id == command.domain_key_version_id
    assert stage.storage_ref == command.storage_ref
    assert stage.wrapper_algorithm == command.wrapper_algorithm
    assert stage.key_generation == command.key_generation
    assert stage.dek_wrapper == command.dek_wrapper
    assert stage.state == :open
    assert stage.state_revision == 0

    scoped(fixture, fn repo ->
      assert %UploadGrant{consumed_at: %DateTime{}} =
               repo.get!(UploadGrant, grant.id)

      assert %AssetStage{id: stage_id, state: :open, state_revision: 0} =
               repo.get_by!(AssetStage,
                 upload_grant_id: grant.id,
                 vault_id: fixture.vault_id
               )

      assert stage_id == command.stage_id
      :ok
    end)

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, fn repo ->
               AssetRepository.consume_grant_and_create_stage(repo, command)
             end)
  end

  test "rejects every changed grant binding without consuming it or creating a stage", %{
    fixture: fixture
  } do
    {grant, token} = insert_grant!(fixture)
    command = stage_command(fixture, grant, token)

    for raw_field <- @raw_secret_aliases do
      assert {:error, %Error{code: :invalid}} =
               scoped(fixture, fn repo ->
                 AssetRepository.consume_grant_and_create_stage(
                   repo,
                   Map.put(command, raw_field, :crypto.strong_rand_bytes(32))
                 )
               end)
    end

    changed_bindings = [
      %{command | token_digest: :crypto.strong_rand_bytes(32)},
      %{command | csrf_token_digest: :crypto.strong_rand_bytes(32)},
      %{command | session_id: Ecto.UUID.generate()},
      %{command | principal_id: Ecto.UUID.generate()},
      %{command | vault_id: Ecto.UUID.generate()},
      %{command | asset_id: Ecto.UUID.generate()},
      %{command | filename: "changed.pdf"},
      %{command | byte_size: command.byte_size + 1},
      %{command | declared_media_type: "image/png"},
      %{command | idempotency_key: command.idempotency_key <> "-changed"},
      %{
        command
        | principal_authorization_epoch: command.principal_authorization_epoch + 1
      },
      %{
        command
        | vault_authorization_epoch: command.vault_authorization_epoch + 1
      }
    ]

    for changed <- changed_bindings do
      assert {:error, %Error{code: :conflict}} =
               scoped(fixture, fn repo ->
                 AssetRepository.consume_grant_and_create_stage(repo, changed)
               end)
    end

    assert {:error,
            %Error{
              code: :invalid,
              details: %{reason: "size_mismatch"}
            }} =
             scoped(fixture, fn repo ->
               AssetRepository.consume_grant_and_create_stage(
                 repo,
                 %{command | request_content_length: command.request_content_length + 1}
               )
             end)

    assert {:error, %Error{code: :unsupported_media_type}} =
             scoped(fixture, fn repo ->
               AssetRepository.consume_grant_and_create_stage(
                 repo,
                 %{command | request_declared_media_type: "image/png"}
               )
             end)

    scoped(fixture, fn repo ->
      assert %UploadGrant{consumed_at: nil} = repo.get!(UploadGrant, grant.id)
      assert repo.get_by(AssetStage, upload_grant_id: grant.id) == nil
      :ok
    end)
  end

  test "same-vault principals cannot distinguish another principal's grant from a missing grant",
       %{
         fixture: fixture,
         other: other
       } do
    victim = add_principal_to_vault!(fixture, other)
    {grant, token} = insert_grant!(victim)
    command = stage_command(victim, grant, token)

    other_principal_result =
      scoped(fixture, fn repo ->
        AssetRepository.consume_grant_and_create_stage(repo, command)
      end)

    missing_grant_result =
      scoped(fixture, fn repo ->
        AssetRepository.consume_grant_and_create_stage(
          repo,
          %{command | grant_id: Ecto.UUID.generate()}
        )
      end)

    assert_grant_unused!(fixture, grant.id)
    assert {:error, %Error{code: :conflict}} = missing_grant_result
    assert {:error, %Error{code: :conflict}} = other_principal_result
  end

  test "changed classification binding cannot consume the grant or create a stage", %{
    fixture: fixture
  } do
    {grant, token} = insert_grant!(fixture)

    changed_classification =
      fixture
      |> stage_command(grant, token)
      |> Map.put(:classification, :sensitive)

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, fn repo ->
               AssetRepository.consume_grant_and_create_stage(
                 repo,
                 changed_classification
               )
             end)

    assert_grant_unused!(fixture, grant.id)
  end

  test "advanced live principal and vault epochs invalidate grants issued under earlier epochs",
       %{
         fixture: fixture
       } do
    {principal_grant, principal_token} = insert_grant!(fixture)
    advance_authorization_epoch!(fixture, :principal)

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, fn repo ->
               AssetRepository.consume_grant_and_create_stage(
                 repo,
                 stage_command(fixture, principal_grant, principal_token)
               )
             end)

    assert_grant_unused!(fixture, principal_grant.id)

    {vault_grant, vault_token} = insert_grant!(fixture)
    advance_authorization_epoch!(fixture, :vault)

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, fn repo ->
               AssetRepository.consume_grant_and_create_stage(
                 repo,
                 stage_command(fixture, vault_grant, vault_token)
               )
             end)

    assert_grant_unused!(fixture, vault_grant.id)
  end

  test "only an exact live binding observes an expired grant", %{fixture: fixture} do
    {grant, token} =
      insert_grant!(fixture, %{
        expires_at: DateTime.add(DateTime.utc_now(:microsecond), -1, :second)
      })

    command = stage_command(fixture, grant, token)

    opaque_bindings = [
      %{command | token_digest: :crypto.strong_rand_bytes(32)},
      %{command | csrf_token_digest: :crypto.strong_rand_bytes(32)},
      %{command | session_id: Ecto.UUID.generate()},
      %{command | principal_id: Ecto.UUID.generate()},
      %{command | vault_id: Ecto.UUID.generate()},
      %{command | grant_id: Ecto.UUID.generate()}
    ]

    for changed <- opaque_bindings do
      assert {:error, %Error{code: :conflict}} =
               scoped(fixture, fn repo ->
                 AssetRepository.consume_grant_and_create_stage(repo, changed)
               end)
    end

    assert {:error, %Error{code: :upload_expired}} =
             scoped(fixture, fn repo ->
               AssetRepository.consume_grant_and_create_stage(repo, command)
             end)

    assert_grant_unused!(fixture, grant.id)

    advance_authorization_epoch!(fixture, :principal)

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, fn repo ->
               AssetRepository.consume_grant_and_create_stage(repo, command)
             end)

    assert_grant_unused!(fixture, grant.id)
  end

  test "stage insert failure rolls grant consumption back atomically", %{fixture: fixture} do
    {first_grant, first_token} = insert_grant!(fixture)
    first_command = stage_command(fixture, first_grant, first_token)

    assert {:ok, %AssetStage{} = existing_stage} =
             scoped(fixture, fn repo ->
               AssetRepository.consume_grant_and_create_stage(repo, first_command)
             end)

    {second_grant, second_token} = insert_grant!(fixture)

    duplicate_stage_command =
      fixture
      |> stage_command(second_grant, second_token)
      |> Map.put(:stage_id, existing_stage.id)

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, fn repo ->
               AssetRepository.consume_grant_and_create_stage(
                 repo,
                 duplicate_stage_command
               )
             end)

    assert_grant_unused!(fixture, second_grant.id)

    scoped(fixture, fn repo ->
      assert repo.aggregate(AssetStage, :count) == 1
      assert repo.get!(AssetStage, existing_stage.id).upload_grant_id == first_grant.id
      :ok
    end)
  end

  test "expiry at the conditional consume update remains upload_expired", %{
    fixture: fixture
  } do
    {grant, token} = insert_grant!(fixture)
    command = stage_command(fixture, grant, token)

    assert {:error, %Error{code: :upload_expired}} =
             expire_while_consume_waits_for_asset!(fixture, grant, command)

    assert_grant_unused!(fixture, grant.id)
  end

  test "concurrent exact consumers create one stage and consume the token once", %{
    fixture: fixture
  } do
    {grant, token} = insert_grant!(fixture)
    command = stage_command(fixture, grant, token)

    results =
      1..2
      |> Task.async_stream(
        fn _attempt ->
          scoped(fixture, fn repo ->
            AssetRepository.consume_grant_and_create_stage(repo, command)
          end)
        end,
        max_concurrency: 2,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, %AssetStage{}}, &1)) == 1

    assert Enum.count(
             results,
             &match?({:error, %Error{code: :conflict}}, &1)
           ) == 1

    scoped(fixture, fn repo ->
      assert %UploadGrant{consumed_at: %DateTime{}} =
               repo.get!(UploadGrant, grant.id)

      assert repo.aggregate(
               from(stage in AssetStage,
                 where: stage.upload_grant_id == ^grant.id
               ),
               :count
             ) == 1

      :ok
    end)
  end

  defp insert_grant!(fixture, overrides \\ %{}) do
    token = :crypto.strong_rand_bytes(32)
    csrf_token = :crypto.strong_rand_bytes(32)

    grant =
      scoped(fixture, fn repo ->
        {principal_epoch, vault_epoch} = live_epochs(repo)

        attrs =
          %{
            id: Ecto.UUID.generate(),
            vault_id: fixture.vault_id,
            session_id: fixture.session_id,
            principal_id: fixture.principal_id,
            asset_id: fixture.asset_id,
            classification: :private,
            token_digest: :crypto.hash(:sha256, token),
            csrf_token_digest: :crypto.hash(:sha256, csrf_token),
            filename: "evidence.pdf",
            byte_size: 12,
            declared_media_type: "application/pdf",
            idempotency_key: "grant-#{Ecto.UUID.generate()}",
            principal_authorization_epoch: principal_epoch,
            vault_authorization_epoch: vault_epoch,
            expires_at: DateTime.add(DateTime.utc_now(:microsecond), 300, :second)
          }
          |> Map.merge(overrides)

        %UploadGrant{}
        |> UploadGrant.create_changeset(attrs)
        |> repo.insert!()
      end)

    {grant, %{upload: token, csrf: csrf_token}}
  end

  defp stage_command(fixture, grant, tokens) do
    %{
      grant_id: grant.id,
      token_digest: :crypto.hash(:sha256, tokens.upload),
      csrf_token_digest: :crypto.hash(:sha256, tokens.csrf),
      session_id: grant.session_id,
      principal_id: grant.principal_id,
      vault_id: grant.vault_id,
      asset_id: grant.asset_id,
      filename: grant.filename,
      byte_size: grant.byte_size,
      declared_media_type: grant.declared_media_type,
      request_content_length: grant.byte_size,
      request_declared_media_type: grant.declared_media_type,
      idempotency_key: grant.idempotency_key,
      classification: grant.classification,
      principal_authorization_epoch: grant.principal_authorization_epoch,
      vault_authorization_epoch: grant.vault_authorization_epoch,
      stage_id: Ecto.UUID.generate(),
      candidate_object_id: Ecto.UUID.generate(),
      key_domain_id: fixture.key_domain_id,
      domain_key_version_id: fixture.domain_key_version_id,
      storage_ref: Ecto.UUID.generate(),
      wrapper_algorithm: "aes_256_gcm",
      key_generation: 1,
      dek_wrapper: :crypto.strong_rand_bytes(60)
    }
  end

  defp live_epochs(repo) do
    assert %{rows: [[principal_epoch, vault_epoch]]} =
             query!(
               repo,
               """
               SELECT
                 principal_authorization_epoch,
                 vault_authorization_epoch
               FROM core.live_principal_authorization()
               """
             )

    {principal_epoch, vault_epoch}
  end

  defp add_principal_to_vault!(fixture, other) do
    session_id = Ecto.UUID.generate()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO core.vault_members (principal_id, vault_id)
        VALUES ($1, $2)
        """,
        [
          Ecto.UUID.dump!(other.principal_id),
          Ecto.UUID.dump!(fixture.vault_id)
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO identity.sessions (
          id,
          account_id,
          credential_id,
          principal_id,
          vault_id,
          token_digest,
          expires_at
        ) VALUES ($1, $2, $3, $4, $5, $6, CURRENT_TIMESTAMP + interval '1 hour')
        """,
        [
          Ecto.UUID.dump!(session_id),
          Ecto.UUID.dump!(other.account_id),
          Ecto.UUID.dump!(other.credential_id),
          Ecto.UUID.dump!(other.principal_id),
          Ecto.UUID.dump!(fixture.vault_id),
          :crypto.hash(:sha256, "victim-session-#{session_id}")
        ]
      )
    end)

    %{fixture | principal_id: other.principal_id, session_id: session_id}
  end

  defp advance_authorization_epoch!(fixture, :principal) do
    Fixtures.with_owner(fn ->
      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 """
                 UPDATE identity.principals
                 SET authorization_epoch = authorization_epoch + 1
                 WHERE id = $1
                 """,
                 [Ecto.UUID.dump!(fixture.principal_id)]
               )
    end)
  end

  defp advance_authorization_epoch!(fixture, :vault) do
    Fixtures.with_owner(fn ->
      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 """
                 UPDATE core.vaults
                 SET authorization_epoch = authorization_epoch + 1
                 WHERE id = $1
                 """,
                 [Ecto.UUID.dump!(fixture.vault_id)]
               )
    end)
  end

  defp assert_grant_unused!(fixture, grant_id) do
    scoped(fixture, fn repo ->
      assert %UploadGrant{consumed_at: nil} = repo.get!(UploadGrant, grant_id)
      assert repo.get_by(AssetStage, upload_grant_id: grant_id) == nil
      :ok
    end)
  end

  defp expire_while_consume_waits_for_asset!(fixture, grant, command) do
    {:ok, owner_repo} = MigrationRepo.start_link(pool_size: 2)
    parent = self()

    set_database_expiry!(grant.id)

    asset_lock =
      Task.async(fn ->
        owner_transaction!(fn ->
          query!(
            MigrationRepo,
            "SELECT id FROM content.assets WHERE id = $1 FOR UPDATE",
            [Ecto.UUID.dump!(grant.asset_id)]
          )

          send(parent, :asset_locked_for_expiry)

          receive do
            :release_asset_after_expiry -> :released
          after
            10_000 -> flunk("timed out waiting to release asset lock")
          end
        end)
      end)

    assert_receive :asset_locked_for_expiry, 1_000

    consumer =
      Task.async(fn ->
        scoped(fixture, fn repo ->
          AssetRepository.consume_grant_and_create_stage(repo, command)
        end)
      end)

    try do
      wait_until_grant_locked!(grant.id, 100)
      wait_until_database_expired!(grant.id, 400)
      send(asset_lock.pid, :release_asset_after_expiry)
      assert Task.await(asset_lock, 5_000) == :released
      Task.await(consumer, 5_000)
    after
      if Process.alive?(asset_lock.pid) do
        send(asset_lock.pid, :release_asset_after_expiry)
        Task.shutdown(asset_lock, :brutal_kill)
      end

      if Process.alive?(consumer.pid), do: Task.shutdown(consumer, :brutal_kill)
      if Process.alive?(owner_repo), do: GenServer.stop(owner_repo)
    end
  end

  defp set_database_expiry!(grant_id) do
    owner_transaction!(fn ->
      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 """
                 UPDATE content.upload_grants
                 SET expires_at = statement_timestamp() + interval '2 seconds'
                 WHERE id = $1
                 """,
                 [Ecto.UUID.dump!(grant_id)]
               )
    end)
  end

  defp wait_until_grant_locked!(_grant_id, 0),
    do: flunk("consume transaction did not lock the grant before expiry")

  defp wait_until_grant_locked!(grant_id, attempts_left) do
    if grant_locked?(grant_id) do
      :ok
    else
      Process.sleep(10)
      wait_until_grant_locked!(grant_id, attempts_left - 1)
    end
  end

  defp grant_locked?(grant_id) do
    result =
      MigrationRepo.transaction(fn ->
        query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

        case Ecto.Adapters.SQL.query(
               MigrationRepo,
               "SELECT id FROM content.upload_grants WHERE id = $1 FOR UPDATE NOWAIT",
               [Ecto.UUID.dump!(grant_id)],
               log: false
             ) do
          {:ok, _result} -> :acquired
          {:error, error} -> MigrationRepo.rollback(error)
        end
      end)

    case result do
      {:ok, :acquired} ->
        false

      {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} ->
        true

      unexpected ->
        flunk("unexpected grant lock probe result: #{inspect(unexpected)}")
    end
  end

  defp wait_until_database_expired!(_grant_id, 0),
    do: flunk("database expiry did not elapse while consume was blocked")

  defp wait_until_database_expired!(grant_id, attempts_left) do
    expired? =
      owner_transaction!(fn ->
        assert %{rows: [[expired?]]} =
                 query!(
                   MigrationRepo,
                   """
                   SELECT expires_at <= statement_timestamp()
                   FROM content.upload_grants
                   WHERE id = $1
                   """,
                   [Ecto.UUID.dump!(grant_id)]
                 )

        expired?
      end)

    if expired? do
      :ok
    else
      Process.sleep(10)
      wait_until_database_expired!(grant_id, attempts_left - 1)
    end
  end

  defp owner_transaction!(callback) do
    assert {:ok, result} =
             MigrationRepo.transaction(fn ->
               query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")
               callback.()
             end)

    result
  end

  defp scoped(fixture, callback) do
    ScopedRepo.transact(
      RequestRepo,
      %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
      callback
    )
  end

  defp insert_key_domain!(raw_vault_id) do
    key_domain_id = Ecto.UUID.generate()
    vault_key_version_id = Ecto.UUID.generate()
    domain_key_version_id = Ecto.UUID.generate()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO core.vault_key_versions (
          id, vault_id, generation, state, algorithm, activated_at
        ) VALUES ($1, $2, 1, 'active', 'aes_256_gcm', CURRENT_TIMESTAMP)
        """,
        [Ecto.UUID.dump!(vault_key_version_id), raw_vault_id]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.key_domains (
          id, vault_id, classification, kind, state
        ) VALUES ($1, $2, 'private', 'content', 'active')
        """,
        [Ecto.UUID.dump!(key_domain_id), raw_vault_id]
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
        ) VALUES (
          $1, $2, $3, $4, 1, 'active', 'aes_256_gcm', $5
        )
        """,
        [
          Ecto.UUID.dump!(domain_key_version_id),
          raw_vault_id,
          Ecto.UUID.dump!(key_domain_id),
          Ecto.UUID.dump!(vault_key_version_id),
          :crypto.strong_rand_bytes(60)
        ]
      )
    end)

    %{
      key_domain_id: key_domain_id,
      domain_key_version_id: domain_key_version_id
    }
  end

  defp load_ids(fixture) do
    Map.new(fixture, fn
      {key, value}
      when key in [
             :account_id,
             :asset_id,
             :credential_id,
             :principal_id,
             :resource_id,
             :resource_version_id,
             :session_id,
             :vault_id
           ] ->
        {key, Ecto.UUID.load!(value)}

      pair ->
        pair
    end)
  end
end
