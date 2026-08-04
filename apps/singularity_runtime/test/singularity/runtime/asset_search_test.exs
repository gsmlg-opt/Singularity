defmodule Singularity.Runtime.AssetSearchTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Retrieval.AssetSearchPage
  alias Singularity.Retrieval.AssetSearchQuery
  alias Singularity.Runtime.Assets.Search
  alias Singularity.Runtime.SessionContext

  @session_id "00000000-0000-4000-8000-000000000401"
  @principal_id "00000000-0000-4000-8000-000000000402"
  @vault_id "00000000-0000-4000-8000-000000000403"
  @asset_id "00000000-0000-4000-8000-000000000404"

  defmodule Scope do
    def with_read_request(owner, runtime, session, requirement, callback) do
      send(owner, {:scope, runtime, session, requirement})

      case Process.get(:asset_search_scope_result) do
        nil -> callback.(:scoped_repo)
        result -> result
      end
    end
  end

  defmodule Retrieval do
    def search(owner, store, store_context, query) do
      send(owner, {:retrieval, store, store_context, query})

      Process.get(
        :asset_search_retrieval_result,
        {:ok, %AssetSearchPage{items: [], next_cursor: nil}}
      )
    end

    def fetch(owner, store, store_context, vault_id, asset_id) do
      send(
        owner,
        {:fetch_retrieval, store, store_context, vault_id, asset_id}
      )

      Process.get(:asset_fetch_retrieval_result, {
        :ok,
        %{
          asset_id: asset_id,
          resource_version_id: "00000000-0000-4000-8000-000000000405",
          vault_id: vault_id
        }
      })
    end
  end

  defmodule Store do
  end

  setup do
    on_exit(fn ->
      Process.delete(:asset_search_scope_result)
      Process.delete(:asset_search_retrieval_result)
      Process.delete(:asset_fetch_retrieval_result)
    end)
  end

  test "binds the session vault and authorizes unlocked asset.read before retrieval" do
    runtime = runtime()
    session = session()

    assert {:ok, %AssetSearchPage{items: [], next_cursor: nil}} =
             Search.run(runtime, session, %{
               q: " annual report ",
               state: :ready,
               media_type: "application/pdf",
               limit: 50
             })

    assert_receive {:scope, ^runtime, ^session, requirement}
    assert requirement.vault_id == @vault_id
    assert requirement.required_capability == "asset.read"
    assert requirement.classification == :private
    assert requirement.requires_unlocked?

    assert_receive {:retrieval, Store, :scoped_repo,
                    %AssetSearchQuery{
                      vault_id: @vault_id,
                      q: "annual report",
                      state: :ready,
                      media_type: "application/pdf",
                      limit: 50
                    }}
  end

  test "preserves the stable locked result and never enters retrieval" do
    Process.put(:asset_search_scope_result, {:error, Error.new(:vault_locked)})

    assert {:error, %Error{code: :vault_locked}} =
             Search.run(runtime(), session(), %{q: "annual"})

    refute_received {:retrieval, _store, _context, _query}
  end

  test "rejects a caller-supplied cross-vault binding before authorization" do
    assert {:error, %Error{code: :invalid}} =
             Search.run(runtime(), session(), %{
               vault_id: "00000000-0000-4000-8000-000000000499"
             })

    refute_received {:scope, _runtime, _session, _requirement}
    refute_received {:retrieval, _store, _context, _query}
  end

  test "accepts the exact session vault transport binding" do
    assert {:ok, %AssetSearchPage{}} =
             Search.run(runtime(), session(), %{"vault_id" => @vault_id})

    assert_receive {:retrieval, Store, :scoped_repo, %AssetSearchQuery{vault_id: @vault_id}}
  end

  test "requires concrete injected adapters and valid query input" do
    assert {:error, %Error{code: :invalid}} =
             Search.run(%{}, session(), %{})

    assert {:error, %Error{code: :invalid}} =
             Search.run(runtime(), session(), %{limit: 51})

    assert {:error, %Error{code: :invalid}} =
             Search.run(runtime(), session(), %{
               q: :binary.copy("q", 1_025)
             })

    assert {:error, %Error{code: :invalid}} =
             Search.run(runtime(), session(), %{media_typo: "image/png"})

    refute_received {:scope, _runtime, _session, _requirement}
  end

  test "exact fetch authorizes the session vault before calling retrieval" do
    runtime = runtime()
    session = session()

    assert {:ok, %{asset_id: @asset_id, vault_id: @vault_id}} =
             Search.fetch(runtime, session, @asset_id)

    assert_receive {:scope, ^runtime, ^session,
                    %{
                      vault_id: @vault_id,
                      required_capability: "asset.read",
                      classification: :private,
                      requires_unlocked?: true
                    }}

    assert_receive {:fetch_retrieval, Store, :scoped_repo, @vault_id, @asset_id}
  end

  test "exact fetch rejects malformed identifiers before authorization" do
    assert {:error, %Error{code: :invalid}} =
             Search.fetch(runtime(), session(), "not-a-uuid")

    refute_received {:scope, _runtime, _session, _requirement}
    refute_received {:fetch_retrieval, _store, _context, _vault_id, _asset_id}
  end

  defp runtime do
    %{
      asset_search: {Retrieval, self()},
      asset_search_store: Store,
      operation_scope: {Scope, self()}
    }
  end

  defp session do
    %SessionContext{
      session_id: @session_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      expires_at: DateTime.add(DateTime.utc_now(), 600, :second),
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 11,
      authorization_epoch: 7,
      unlocked?: true
    }
  end
end

defmodule Singularity.Runtime.AssetSearchIntegrationTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Retrieval.AssetMetadataSearch
  alias Singularity.Retrieval.AssetSearchPage
  alias Singularity.Runtime.AuthorizationDependencies
  alias Singularity.Runtime.Assets.Search
  alias Singularity.Runtime.Authorize
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.SessionContext
  alias Singularity.Storage.AuthorizationLock
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.Postgres.AssetSearchStore
  alias Singularity.Storage.Postgres.IdentityRepository
  alias Singularity.Storage.RequestRepo
  alias Singularity.Storage.ScopedRepo
  alias Singularity.Storage.VaultLock

  defmodule Custodian do
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
  end

  setup do
    %{one: raw_fixture} = Fixtures.two_vaults!()
    fixture = load_ids(raw_fixture)

    assert {:ok, authorization} =
             AuthorizationDependencies.new(%{
               store: IdentityRepository,
               custodian: {Custodian, self()}
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
      asset_search: AssetMetadataSearch,
      asset_search_store: AssetSearchStore,
      authorization: authorization,
      authorization_lock: AuthorizationLock,
      authorizer: Authorize,
      operation_scope: OperationScope,
      request_repo: RequestRepo,
      scoped_repo: ScopedRepo,
      vault_lock: VaultLock
    }

    {:ok, fixture: fixture, raw_fixture: raw_fixture, runtime: runtime, session: session}
  end

  test "live capability and unlock checks gate search before PostgreSQL retrieval", %{
    fixture: fixture,
    raw_fixture: raw_fixture,
    runtime: runtime,
    session: session
  } do
    assert {:error, %Error{code: :forbidden}} =
             Search.run(runtime, session, %{q: "Resource"})

    grant_asset_read!(raw_fixture)

    assert {:error, %Error{code: :vault_locked}} =
             Search.run(runtime, session, %{q: "Resource"})

    unlock_vault!(raw_fixture)

    assert {:ok, %AssetSearchPage{items: [item], next_cursor: nil}} =
             Search.run(runtime, session, %{q: "Resource"})

    assert item.asset_id == fixture.asset_id
    assert item.vault_id == fixture.vault_id

    assert_receive {:assert_unlocked, session_id, principal_id, vault_id, 0, 0}
    assert session_id == fixture.session_id
    assert principal_id == fixture.principal_id
    assert vault_id == fixture.vault_id
  end

  defp grant_asset_read!(fixture) do
    Fixtures.with_owner(fn ->
      capability_id = Ecto.UUID.generate()

      query!(
        MigrationRepo,
        """
        INSERT INTO core.capabilities (id, name)
        VALUES ($1, 'asset.read')
        ON CONFLICT (name) DO NOTHING
        """,
        [Ecto.UUID.dump!(capability_id)]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.principal_capabilities (
          principal_id, vault_id, capability_id
        )
        SELECT $1, $2, id
        FROM core.capabilities
        WHERE name = 'asset.read'
        """,
        [fixture.principal_id, fixture.vault_id]
      )
    end)
  end

  defp unlock_vault!(fixture) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE core.vaults SET locked = false WHERE id = $1",
        [fixture.vault_id]
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
