defmodule Singularity.Runtime.AssetDiscoveryClearanceTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Runtime.AuthorizationDependencies
  alias Singularity.Runtime.Assets.Delete
  alias Singularity.Runtime.Assets.Download
  alias Singularity.Runtime.Assets.Status
  alias Singularity.Runtime.Authorize
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.SessionContext
  alias Singularity.Storage.AuthorizationLock
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.ObjectLock
  alias Singularity.Storage.Postgres.AssetDeletionRepository
  alias Singularity.Storage.Postgres.AssetRepository
  alias Singularity.Storage.Postgres.IdentityRepository
  alias Singularity.Storage.ScopedRepo
  alias Singularity.Storage.VaultLock

  defmodule CustodianSpy do
    def assert_unlocked(
          owner,
          session_id,
          principal_id,
          vault_id,
          principal_epoch,
          vault_epoch
        ) do
      send(
        owner,
        {:assert_unlocked, session_id, principal_id, vault_id, principal_epoch, vault_epoch}
      )

      :ok
    end

    def lease(owner, request) do
      send(owner, {:lease, request})
      {:ok, {:opaque_lease, request.object_id}}
    end
  end

  defmodule ReaderSpy do
    def read(owner, lease, range) do
      send(owner, {:read, lease, range})
      {:ok, "authorized bytes"}
    end
  end

  setup do
    %{one: raw_fixture} = Fixtures.two_vaults!()
    fixture = load_ids(raw_fixture)
    assets = install_discovery_fixtures!(raw_fixture, fixture)

    assert {:ok, authorization} =
             AuthorizationDependencies.new(%{
               store: IdentityRepository,
               custodian: {CustodianSpy, self()}
             })

    session = %SessionContext{
      session_id: fixture.session_id,
      principal_id: fixture.principal_id,
      vault_id: fixture.vault_id,
      expires_at: DateTime.add(DateTime.utc_now(:microsecond), 600, :second),
      principal_authorization_epoch: 0,
      vault_authorization_epoch: 0,
      authorization_epoch: 0,
      unlocked?: true
    }

    runtime = %{
      asset_deletions: AssetDeletionRepository,
      assets: AssetRepository,
      authenticated_reader: {ReaderSpy, self()},
      authorization: authorization,
      authorization_lock: AuthorizationLock,
      authorizer: Authorize,
      custodian: {CustodianSpy, self()},
      object_lock: ObjectLock,
      operation_scope: OperationScope,
      request_repo: RequestRepo,
      scoped_repo: ScopedRepo,
      vault_lock: VaultLock
    }

    {:ok, assets: assets, fixture: fixture, runtime: runtime, session: session}
  end

  test "discovery hides above-clearance asset ids exactly like nonexistent ids", %{
    assets: assets,
    fixture: fixture,
    runtime: runtime,
    session: session
  } do
    assert {:ok, %{asset_id: private_id, classification: :private}} =
             Status.run(runtime, session, assets.private.asset_id)

    assert private_id == assets.private.asset_id

    assert {:ok, "authorized bytes"} =
             Download.run(runtime, session, assets.private.asset_id, :all)

    assert_receive {:lease, %{object_id: private_object_id}}
    assert private_object_id == assets.private.object_id
    assert_receive {:read, {:opaque_lease, ^private_object_id}, :all}

    hidden_ids = [
      assets.sensitive.asset_id,
      assets.restricted.asset_id
    ]

    for asset_id <- hidden_ids do
      assert {:error, %Error{code: :not_found}} =
               Status.run(runtime, session, asset_id)

      assert {:error, %Error{code: :not_found}} =
               Download.run(runtime, session, asset_id, :all)

      assert {:error, %Error{code: :not_found}} =
               Delete.run(runtime, session, asset_id, 3)
    end

    missing_id = Ecto.UUID.generate()

    assert {:error, %Error{code: :not_found}} =
             Status.run(runtime, session, missing_id)

    assert {:error, %Error{code: :not_found}} =
             Download.run(runtime, session, missing_id, :all)

    assert {:error, %Error{code: :not_found}} =
             Delete.run(runtime, session, missing_id, 3)

    refute_received {:lease, _request}
    refute_received {:read, _lease, _range}

    assert_hidden_assets_unchanged!(hidden_ids)

    set_clearance!(fixture, :restricted)

    assert {:ok, %{asset_id: sensitive_id, classification: :sensitive}} =
             Status.run(runtime, session, assets.sensitive.asset_id)

    assert sensitive_id == assets.sensitive.asset_id

    assert {:ok, %{asset_id: restricted_id, classification: :restricted}} =
             Status.run(runtime, session, assets.restricted.asset_id)

    assert restricted_id == assets.restricted.asset_id

    download_correlation_id = Ecto.UUID.generate()

    assert {:ok, "authorized bytes"} =
             Download.run(
               runtime,
               session,
               assets.restricted.asset_id,
               :all,
               download_correlation_id
             )

    assert_receive {:lease, %{object_id: restricted_object_id}}
    assert restricted_object_id == assets.restricted.object_id
    assert_receive {:read, {:opaque_lease, ^restricted_object_id}, :all}

    Fixtures.with_owner(fn ->
      for operation <- ["asset.downloaded", "asset.sensitive_read"] do
        assert_persisted_audit!(
          MigrationRepo,
          operation,
          [correlation_id: download_correlation_id],
          actor_kind: "principal",
          result: "completed",
          target_type: "asset",
          target_id: assets.restricted.asset_id
        )
      end

      :ok
    end)

    assert {:ok, %{id: delete_id, state: :pending_delete, state_revision: 4}} =
             Delete.run(runtime, session, assets.restricted_delete.asset_id, 3)

    assert delete_id == assets.restricted_delete.asset_id
  end

  defp install_discovery_fixtures!(raw_fixture, fixture) do
    vault_key_version_id = Ecto.UUID.generate()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE core.vaults
        SET locked = false
        WHERE id = $1
        """,
        [raw_fixture.vault_id]
      )

      for capability <- ["asset.read", "asset.write"] do
        query!(
          MigrationRepo,
          """
          INSERT INTO core.capabilities (id, name)
          VALUES ($1, $2)
          ON CONFLICT (name) DO NOTHING
          """,
          [Ecto.UUID.dump!(Ecto.UUID.generate()), capability]
        )

        query!(
          MigrationRepo,
          """
          INSERT INTO core.principal_capabilities (
            principal_id, vault_id, capability_id
          )
          SELECT $1, $2, id
          FROM core.capabilities
          WHERE name = $3
          """,
          [raw_fixture.principal_id, raw_fixture.vault_id, capability]
        )
      end

      query!(
        MigrationRepo,
        """
        INSERT INTO core.vault_key_versions (
          id, vault_id, generation, state, algorithm, activated_at
        ) VALUES ($1, $2, 1, 'active', 'aes_256_gcm', CURRENT_TIMESTAMP)
        """,
        [Ecto.UUID.dump!(vault_key_version_id), raw_fixture.vault_id]
      )
    end)

    %{
      private:
        insert_available_asset!(
          raw_fixture,
          fixture,
          vault_key_version_id,
          :private
        ),
      sensitive:
        insert_available_asset!(
          raw_fixture,
          fixture,
          vault_key_version_id,
          :sensitive
        ),
      restricted:
        insert_available_asset!(
          raw_fixture,
          fixture,
          vault_key_version_id,
          :restricted
        ),
      restricted_delete:
        insert_available_asset!(
          raw_fixture,
          fixture,
          vault_key_version_id,
          :restricted
        )
    }
  end

  defp insert_available_asset!(
         raw_fixture,
         fixture,
         vault_key_version_id,
         classification
       ) do
    ids = %{
      asset_id: Ecto.UUID.generate(),
      domain_key_version_id: Ecto.UUID.generate(),
      envelope_id: Ecto.UUID.generate(),
      key_domain_id: Ecto.UUID.generate(),
      object_id: Ecto.UUID.generate(),
      resource_id: Ecto.UUID.generate(),
      resource_version_id: Ecto.UUID.generate()
    }

    classification = Atom.to_string(classification)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO content.resources (
          id, vault_id, classification, title
        ) VALUES ($1, $2, $3, $4)
        """,
        [
          Ecto.UUID.dump!(ids.resource_id),
          raw_fixture.vault_id,
          classification,
          "Discovery #{classification}"
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO content.resource_versions (
          id, resource_id, vault_id, classification, revision
        ) VALUES ($1, $2, $3, $4, 0)
        """,
        [
          Ecto.UUID.dump!(ids.resource_version_id),
          Ecto.UUID.dump!(ids.resource_id),
          raw_fixture.vault_id,
          classification
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.key_domains (
          id, vault_id, classification, kind, state
        ) VALUES ($1, $2, $3, 'content', 'active')
        """,
        [
          Ecto.UUID.dump!(ids.key_domain_id),
          raw_fixture.vault_id,
          classification
        ]
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
          Ecto.UUID.dump!(ids.domain_key_version_id),
          raw_fixture.vault_id,
          Ecto.UUID.dump!(ids.key_domain_id),
          Ecto.UUID.dump!(vault_key_version_id),
          :crypto.strong_rand_bytes(60)
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO content.asset_objects (
          id,
          vault_id,
          key_domain_id,
          classification,
          lookup_digest,
          ciphertext_hash,
          plaintext_byte_size,
          ciphertext_byte_size,
          storage_ref,
          format_version,
          lifecycle,
          lifecycle_revision
        ) VALUES (
          $1, $2, $3, $4, $5, $6, 16, 174, $7, 1, 'available', 1
        )
        """,
        [
          Ecto.UUID.dump!(ids.object_id),
          raw_fixture.vault_id,
          Ecto.UUID.dump!(ids.key_domain_id),
          classification,
          :crypto.strong_rand_bytes(32),
          :crypto.strong_rand_bytes(32),
          ids.object_id
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO content.asset_key_envelopes (
          id,
          vault_id,
          asset_object_id,
          domain_key_version_id,
          key_domain_id,
          classification,
          algorithm,
          key_generation,
          wrapped_dek
        ) VALUES (
          $1, $2, $3, $4, $5, $6, 'aes_256_gcm', 1, $7
        )
        """,
        [
          Ecto.UUID.dump!(ids.envelope_id),
          raw_fixture.vault_id,
          Ecto.UUID.dump!(ids.object_id),
          Ecto.UUID.dump!(ids.domain_key_version_id),
          Ecto.UUID.dump!(ids.key_domain_id),
          classification,
          :crypto.strong_rand_bytes(60)
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO content.assets (
          id,
          vault_id,
          resource_version_id,
          asset_object_id,
          classification,
          state,
          state_revision
        ) VALUES ($1, $2, $3, $4, $5, 'available', 3)
        """,
        [
          Ecto.UUID.dump!(ids.asset_id),
          raw_fixture.vault_id,
          Ecto.UUID.dump!(ids.resource_version_id),
          Ecto.UUID.dump!(ids.object_id),
          classification
        ]
      )
    end)

    %{
      asset_id: ids.asset_id,
      object_id: ids.object_id,
      vault_id: fixture.vault_id
    }
  end

  defp assert_hidden_assets_unchanged!(hidden_ids) do
    Fixtures.with_owner(fn ->
      %{rows: rows} =
        query!(
          MigrationRepo,
          """
          SELECT id, state, state_revision
          FROM content.assets
          WHERE id = ANY($1::uuid[])
          ORDER BY id
          """,
          [Enum.map(hidden_ids, &Ecto.UUID.dump!/1)]
        )

      assert Enum.map(rows, fn [id, state, revision] ->
               {Ecto.UUID.load!(id), state, revision}
             end) ==
               hidden_ids
               |> Enum.sort()
               |> Enum.map(&{&1, "available", 3})

      %{rows: [[0]]} =
        query!(
          MigrationRepo,
          """
          SELECT count(*)
          FROM content.tombstones
          WHERE asset_id = ANY($1::uuid[])
          """,
          [Enum.map(hidden_ids, &Ecto.UUID.dump!/1)]
        )

      :ok
    end)
  end

  defp set_clearance!(fixture, clearance) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE core.vault_members
        SET clearance = $3
        WHERE principal_id = $1 AND vault_id = $2
        """,
        [
          Ecto.UUID.dump!(fixture.principal_id),
          Ecto.UUID.dump!(fixture.vault_id),
          Atom.to_string(clearance)
        ]
      )
    end)
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
