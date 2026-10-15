defmodule Singularity.Runtime.NativeAssetFixture do
  @moduledoc false

  import ExUnit.Assertions

  alias Singularity.Runtime.{Api, BootstrapOwner, KeyCustodian, OutboxDispatcher}
  alias Singularity.Storage.Backup.KnowledgeFixtureResourceOwner, as: ResourceOwner
  alias Singularity.Storage.{MigrationRepo, SafeSQL}

  @owned_repos [
    Singularity.Storage.RequestRepo,
    Singularity.Storage.PreAuthRepo,
    Singularity.Storage.DispatcherRepo,
    Singularity.Storage.WorkerRepo
  ]

  def with_fixture(fun) when is_function(fun, 1) do
    {owner, destination} = ResourceOwner.open(migration_pool_size: 2)

    try do
      credentials = bootstrap!()
      runtime = start_runtime!(owner, destination)
      session = login!(credentials)
      fun.(Map.merge(runtime, %{credentials: credentials, session: session}))
    after
      ResourceOwner.close(owner)
    end
  end

  # Restore callers acquire an empty owner themselves and invoke this only after
  # ordinary RestoreVault completion. It never bootstraps a destination.
  def start_runtime!(owner, destination) do
    configure_runtime!(destination)
    repositories = repo_identities()
    children = Singularity.Runtime.Application.application_children(composition())
    {borrowed, infrastructure} = Enum.split_with(children, &(&1 in @owned_repos))
    assert borrowed == @owned_repos
    assert {:ok, supervisor} = ResourceOwner.start_infrastructure(owner, infrastructure)
    assert repo_identities() == repositories
    assert is_pid(Oban.whereis(Singularity.Oban))
    assert is_pid(Process.whereis(KeyCustodian))
    assert is_pid(Process.whereis(OutboxDispatcher))

    %{
      owner: owner,
      destination: destination,
      infrastructure: supervisor,
      repositories: repositories
    }
  end

  def login!(credentials) do
    assert {:ok, token, logged_in} =
             Api.login(%{
               login: credentials.login,
               password: credentials.password,
               source: "127.0.0.1"
             })

    refute logged_in.unlocked?
    assert {:ok, resolved} = Api.resolve_session(token)
    assert resolved.session_id == logged_in.session_id
    assert {:ok, session} = Api.unlock(resolved, credentials.password)
    assert session.unlocked?
    assert session.principal_id == credentials.owner.principal_id
    assert session.vault_id == credentials.owner.vault_id
    session
  end

  def upload!(fixture, media_type, chunks, filename \\ "native-original.txt")
      when is_list(chunks) do
    fixture
    |> begin_upload!(media_type, chunks, filename)
    |> finish_upload!()
  end

  def begin_upload!(fixture, media_type, chunks, filename \\ "native-original.txt")
      when is_list(chunks) do
    byte_size = Enum.reduce(chunks, 0, &(byte_size(&1) + &2))
    csrf = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    assert {:ok, token, grant} =
             Api.create_upload_grant(
               fixture.session,
               %{
                 filename: filename,
                 size: byte_size,
                 declared_media_type: media_type,
                 idempotency_key: Ecto.UUID.generate()
               },
               csrf
             )

    assert {:ok, handle} =
             Api.begin_upload(
               fixture.session,
               grant.grant_id,
               %{
                 upload_token: token,
                 csrf_token: csrf,
                 content_length: byte_size,
                 declared_media_type: media_type
               },
               self()
             )

    for chunk <- chunks, do: assert(:ok = Api.append_upload(handle, chunk))

    %{asset_id: grant.asset_id, grant_id: grant.grant_id, handle: handle}
  end

  def finish_upload!(upload) do
    assert {:ok, result} = Api.finish_upload(upload.handle, "")
    assert result.asset_id == upload.asset_id
    assert result.state == :uploaded
    assert result.state_revision == 1
    %{asset_id: upload.asset_id, grant_id: upload.grant_id, result: result}
  end

  def verify_and_finalize! do
    verify!()
    finalize!()
  end

  def verify! do
    dispatch!()
    assert %{failure: 0, success: 1} = Oban.drain_queue(Singularity.Oban, queue: :asset_verify)
  end

  def finalize! do
    dispatch!()
    assert %{failure: 0, success: 1} = Oban.drain_queue(Singularity.Oban, queue: :asset_finalize)
  end

  def dispatch! do
    assert {:ok, %{failed: 0} = summary} = OutboxDispatcher.dispatch_once(%{})
    summary
  end

  # Observation only: public operations above create every positive witness.
  # The table-owner role is confined to the already-owned disposable database.
  def observe!(statement, parameters \\ []) do
    assert {:ok, result} =
             MigrationRepo.transaction(fn ->
               SafeSQL.query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner", [])
               SafeSQL.query!(MigrationRepo, statement, parameters)
             end)

    result
  end

  def repo_identities do
    Map.new([MigrationRepo | @owned_repos], fn repo ->
      assert %{rows: [[database]]} = SafeSQL.query!(repo, "SELECT current_database()", [])
      assert database == Keyword.fetch!(repo.config(), :database)
      {repo, {Process.whereis(repo), database}}
    end)
  end

  defp bootstrap! do
    login = "native-assets-#{Ecto.UUID.generate()}@example.test"
    password = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    adapters = Application.fetch_env!(:singularity_runtime, :bootstrap_owner)

    adapters =
      Map.put(adapters, :initial_capabilities, [
        "asset.read",
        "asset.write",
        "backup.create",
        "note.export",
        "note.read",
        "note.write",
        "vault.lock",
        "vault.unlock",
        "vault.password_change"
      ])

    assert {:ok, owner} =
             MigrationRepo.transaction(fn ->
               SafeSQL.query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner", [])

               assert {:ok, owner} =
                        BootstrapOwner.run(adapters, %{
                          display_name: "Native Asset Fixture",
                          login: login,
                          password: password
                        })

               owner
             end)

    %{owner: owner, login: login, password: password}
  end

  defp configure_runtime!(destination) do
    Application.put_env(:singularity_runtime, :authorization_dependencies, %{
      store: Singularity.Storage.Postgres.IdentityRepository,
      custodian: KeyCustodian
    })

    Application.put_env(:singularity_runtime, :key_custodian, %{
      authorization: Singularity.Runtime.CustodyReader,
      backup_cipher: Singularity.Storage.Crypto.ChunkedAEAD,
      backup_recovery_wrapper: Singularity.Storage.Crypto.BackupRecoveryWrapper,
      clock: Singularity.Runtime.CustodyReader,
      context: %{
        repo: Singularity.Storage.WorkerRepo,
        repository_adapter: Singularity.Storage.Postgres.CustodyRepository,
        key_wrapper: Singularity.Storage.Crypto.KeyWrapper,
        storage: Singularity.Runtime.StorageAdapter
      },
      idle_lock: Singularity.Runtime.LockVault,
      key_reader: Singularity.Runtime.CustodyReader,
      object_key_loader: Singularity.Runtime.CustodyReader,
      wake_waiting: Singularity.Runtime.JobDispatcher
    })

    backup_root = Path.join(Path.dirname(destination.object_root), "backups")
    File.mkdir!(backup_root)
    File.chmod!(backup_root, 0o700)
    Application.put_env(:singularity_storage, :backup_root, backup_root)
  end

  defp composition do
    %{
      start_infrastructure: true,
      job_handler: Application.fetch_env!(:singularity_storage, :job_handler),
      authorization: Application.fetch_env!(:singularity_runtime, :authorization_dependencies),
      key_custodian: Application.fetch_env!(:singularity_runtime, :key_custodian),
      oban: Application.fetch_env!(:singularity_runtime, :oban_options),
      outbox_dispatcher: Application.fetch_env!(:singularity_runtime, :outbox_dispatcher_options)
    }
  end
end
