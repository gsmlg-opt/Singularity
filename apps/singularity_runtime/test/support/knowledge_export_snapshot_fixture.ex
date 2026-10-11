defmodule Singularity.Runtime.KnowledgeExportSnapshotFixture do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [start_supervised!: 2]
  import Singularity.Storage.DataCase, only: [query!: 2, query!: 3]

  alias Singularity.Runtime.{
    AuthorizationDependencies,
    Authorize,
    CustodyReader,
    KeyCustodian,
    KeyLeaseSupervisor,
    OperationScope,
    ResolveSession
  }

  alias Singularity.Storage.{
    AuthorizationLock,
    Fixtures,
    KnowledgeFixtures,
    MigrationRepo,
    PreAuthRepo,
    RequestRepo,
    ScopedRepo,
    VaultLock,
    WorkerRepo
  }

  alias Singularity.Storage.Crypto.KeyWrapper
  alias Singularity.Storage.Postgres.{AuditSink, CustodyRepository, IdentityRepository, PreAuth}

  # This adapter delegates the authorization result unchanged to the real SQL
  # repository. Its observation/barrier neither grants nor fabricates authority.
  defmodule ObservedIdentity do
    def load_live_session(observer, repo, session_id) do
      import Singularity.Storage.DataCase, only: [query!: 2]

      %{rows: [[isolation, read_only]]} =
        query!(
          repo,
          "SELECT current_setting('transaction_isolation'),current_setting('transaction_read_only')"
        )

      send(observer.parent, {:sql_snapshot_authorization, self(), isolation, read_only})

      if not is_nil(observer[:barrier]) and is_nil(Process.get({__MODULE__, observer.barrier})) do
        Process.put({__MODULE__, observer.barrier}, true)
        send(observer.parent, {:sql_snapshot_cut, self(), observer.barrier})

        receive do
          {:continue_snapshot, token} when token == observer.barrier -> :ok
        after
          5_000 -> raise "snapshot barrier timed out"
        end
      end

      IdentityRepository.load_live_session(repo, session_id)
    end
  end

  # Shared Task13 fixture compiled in test/support before umbrella suites run.
  # It resolves a real opaque session and activates established custody unchanged.
  def live_fixture!(tmp_dir) do
    source = KnowledgeFixtures.prepared_source!()
    token = :crypto.strong_rand_bytes(32)

    Fixtures.with_owner(fn ->
      %{rows: [[stored_ref]]} =
        query!(
          MigrationRepo,
          "UPDATE content.asset_objects SET storage_ref=$2 WHERE id=$1 AND vault_id=$3 AND storage_ref=$4 RETURNING storage_ref",
          [
            dump(source.object_id),
            source.object_id,
            dump(source.vault_id),
            "knowledge-test/#{source.object_id}"
          ]
        )

      assert stored_ref == source.object_id

      query!(MigrationRepo, "UPDATE identity.sessions SET token_digest=$2 WHERE id=$1", [
        dump(source.session_id),
        :crypto.hash(:sha256, token)
      ])

      query!(MigrationRepo, "UPDATE core.vaults SET locked=false WHERE id=$1", [
        dump(source.vault_id)
      ])

      for capability <- ["asset.read", "note.read"] do
        query!(
          MigrationRepo,
          "INSERT INTO core.capabilities(id,name) VALUES($1,$2) ON CONFLICT(name) DO NOTHING",
          [KnowledgeFixtures.uuid(), capability]
        )

        query!(
          MigrationRepo,
          "INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name=$3 ON CONFLICT DO NOTHING",
          [dump(source.principal_id), dump(source.vault_id), capability]
        )
      end
    end)

    for name <- ~w(export storage backup) do
      path = Path.join(tmp_dir, name)
      File.mkdir!(path)
      File.chmod!(path, 0o700)
    end

    lease_supervisor = start_supervised!({KeyLeaseSupervisor, name: nil}, id: make_ref())

    custody_context = %{
      repo: WorkerRepo,
      repository_adapter: CustodyRepository,
      scope: ScopedRepo
    }

    custodian =
      start_supervised!(
        {KeyCustodian,
         %{
           authorization: CustodyReader,
           clock: CustodyReader,
           context: custody_context,
           idle_lock: fn _ -> :ok end,
           key_reader: CustodyReader,
           key_wrapper: KeyWrapper,
           lease_supervisor: lease_supervisor,
           object_key_loader: CustodyReader
         }},
        id: make_ref()
      )

    resolver = %{
      pre_auth: PreAuth,
      pre_auth_context: PreAuthRepo,
      custodian: KeyCustodian,
      custodian_context: custodian
    }

    assert {:ok, session} = ResolveSession.run(resolver, token)

    %{rows: [[domain, domain_version]]} =
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "SELECT o.key_domain_id,e.domain_key_version_id FROM content.asset_objects o JOIN content.asset_key_envelopes e ON e.asset_object_id=o.id WHERE o.id=$1",
          [dump(source.object_id)]
        )
      end)

    assert {:ok, pending} =
             KeyCustodian.prepare_unlock(
               custodian,
               %{
                 account_id: source.account_id,
                 domain_classification: :private,
                 domain_dedup_key: :crypto.strong_rand_bytes(32),
                 domain_key: :crypto.strong_rand_bytes(32),
                 domain_key_generation: 1,
                 domain_key_version_id: Ecto.UUID.load!(domain_version),
                 expires_at: session.expires_at,
                 key_domain_id: Ecto.UUID.load!(domain),
                 principal_authorization_epoch: session.principal_authorization_epoch,
                 principal_id: source.principal_id,
                 session_id: source.session_id,
                 vault_authorization_epoch: session.vault_authorization_epoch,
                 vault_id: source.vault_id,
                 vault_key: :crypto.strong_rand_bytes(32)
               }
             )

    assert :ok = KeyCustodian.activate_unlock(custodian, pending)
    assert {:ok, session} = ResolveSession.run(resolver, token)
    assert session.unlocked?

    assert {:ok, authorization} =
             AuthorizationDependencies.new(%{
               store: {ObservedIdentity, %{parent: self()}},
               custodian: {KeyCustodian, custodian}
             })

    runtime = %{
      request_repo: RequestRepo,
      vault_lock: VaultLock,
      authorization_lock: AuthorizationLock,
      scoped_repo: ScopedRepo,
      operation_scope: OperationScope,
      authorizer: Authorize,
      authorization: authorization,
      audit: AuditSink
    }

    context = %{
      root: Path.join(tmp_dir, "export"),
      storage_root: Path.join(tmp_dir, "storage"),
      backup_root: Path.join(tmp_dir, "backup")
    }

    %{
      source: source,
      session: session,
      runtime: runtime,
      context: context,
      custodian: custodian,
      token: token,
      resolver: resolver
    }
  end

  defp dump(id), do: Ecto.UUID.dump!(id)
end
