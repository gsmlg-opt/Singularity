defmodule Singularity.Runtime.DocumentCustodyTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Runtime.{DownloadLease, KeyCustodian, KeyLease, KeyLeaseSupervisor}

  @now ~U[2026-09-22 08:00:00Z]

  defmodule IdleLock do
    def idle_lock(_owner, _session), do: :ok
  end

  defmodule Reader do
    def load_object_key(context, binding, _hierarchy) do
      send(context.owner, {:load_document_key, binding})
      {:ok, %{object_dek: :binary.copy(<<1>>, 32), reader_binding: binding}}
    end

    def load_checkpoint(_context, binding) do
      {:ok, Singularity.Runtime.KeyLease.document_checkpoint(binding, 0)}
    end

    def read_chunk(context, binding, index) do
      send(context.owner, {:read_document_chunk, binding, index})
      {:ok, "source"}
    end

    def persist_checkpoint(_context, _binding, _expected, _next) do
      :ok
    end

    def read_range(context, binding, range) do
      send(context.owner, {:read_document_range, binding, range})
      {:ok, "source"}
    end
  end

  defmodule Authorization do
    def revalidate(context, binding) do
      send(context.owner, {:revalidate_document, binding})
      :ok
    end
  end

  defmodule Clock do
    def utc_now(%{now: now}), do: now
  end

  defmodule FreshReader do
    def load_object_key(context, binding, hierarchy) do
      send(context.owner, {:fresh_document_key, binding, hierarchy})

      {:ok,
       %{
         object_dek: :binary.copy(<<1>>, 32),
         reader_binding: Map.put(binding, :plaintext_byte_size, 6)
       }}
    end

    def load_checkpoint(_context, _binding), do: raise("fresh source must not load checkpoints")
    def persist_checkpoint(_, _, _, _), do: raise("fresh source must not persist checkpoints")
    def read_chunk(context, binding, index), do: Reader.read_chunk(context, binding, index)
    def read_range(context, binding, range), do: Reader.read_range(context, binding, range)
  end

  test "fresh extraction selects a session, preserves exact storage binding and restarts at zero" do
    {custodian, request, session} = fresh_custodian()
    assert {:error, :waiting_for_unlock} = KeyCustodian.lease(custodian, request)
    assert :ok = activate_session(custodian, session)

    for _attempt <- 1..2 do
      assert {:ok, lease} = KeyCustodian.lease(custodian, request)
      assert {:ok, "source"} = DownloadLease.read_document_chunk(lease, 0)
      assert_receive {:fresh_document_key, binding, _hierarchy}

      assert binding ==
               request |> Map.delete(:purpose) |> Map.put(:session_id, session.session_id)

      assert_receive {:read_document_chunk, ^binding, 0}
      assert :ok = DownloadLease.revoke(lease)
    end
  end

  test "fresh extraction rejects every caller-selected startup field and malformed binding" do
    {custodian, request, session} = fresh_custodian()
    assert :ok = activate_session(custodian, session)

    for {key, value} <- [
          {:session_id, session.session_id},
          {:mode, :document_worker_source},
          {:index, 0},
          {:range, :all},
          {:checkpoint, %{}},
          {:consumer_pid, self()},
          {"job_id", request.job_id},
          {:unexpected, true}
        ] do
      assert {:error, %Error{code: :invalid}} =
               KeyCustodian.lease(custodian, Map.put(request, key, value))
    end

    for key <- Map.keys(request) do
      assert {:error, %Error{code: :invalid}} =
               KeyCustodian.lease(custodian, Map.delete(request, key))
    end

    for {key, value} <- [
          {:access, :request},
          {:access, :forged},
          {:required_capability, "asset.write"},
          {:object_generation, 0},
          {:object_generation, -1},
          {:object_generation, 1.0},
          {:principal_authorization_epoch, -1},
          {:principal_authorization_epoch, 9_223_372_036_854_775_808},
          {:vault_authorization_epoch, 9_223_372_036_854_775_808},
          {:object_generation, 9_223_372_036_854_775_808},
          {:vault_authorization_epoch, "0"}
        ] do
      assert {:error, %Error{code: :invalid}} =
               KeyCustodian.lease(custodian, Map.put(request, key, value))
    end

    for key <- [:job_id, :resource_version_id, :object_id, :vault_id, :principal_id],
        value <- ["not-a-uuid", String.upcase(request[key]), Ecto.UUID.dump!(request[key])] do
      assert {:error, %Error{code: :invalid}} =
               KeyCustodian.lease(custodian, Map.put(request, key, value))
    end

    plausible_generic = Map.put(request, :session_id, session.session_id)

    for malformed <- [
          %{plausible_generic | purpose: "document_extraction_source"},
          plausible_generic
          |> Map.delete(:purpose)
          |> Map.put("purpose", :document_extraction_source),
          plausible_generic
          |> Map.delete(:purpose)
          |> Map.put("purpose", "document_extraction_source"),
          plausible_generic
          |> Map.put(:purpose, :download)
          |> Map.put("purpose", "document_extraction_source")
        ] do
      assert {:error, %Error{code: :invalid}} = KeyCustodian.lease(custodian, malformed)
    end

    refute_received {:fresh_document_key, _, _}
  end

  test "fresh extraction binds the consumer to issuance and registers for session revocation" do
    {custodian, request, session} = fresh_custodian()
    assert :ok = activate_session(custodian, session)
    assert {:ok, lease} = KeyCustodian.lease(custodian, request)

    assert {:error, %Error{code: :forbidden}} =
             Task.async(fn -> DownloadLease.read_document_chunk(lease, 0) end) |> Task.await()

    monitor = Process.monitor(lease)
    assert {:ok, token} = KeyCustodian.begin_revoke(custodian, %{session_id: session.session_id})
    assert :ok = KeyCustodian.finish_revoke(custodian, token)
    assert_receive {:DOWN, ^monitor, :process, ^lease, :normal}
  end

  test "worker source lease requires unlock and pins version in checkpoint" do
    {custodian, request} = setup_custodian()

    assert {:error, %Error{code: :invalid}} =
             KeyCustodian.lease(custodian, Map.put(request, :session_id, "session-1"))

    assert {:error, :waiting_for_unlock} = KeyCustodian.lease(custodian, request)
    assert :ok = unlock(custodian)
    assert {:ok, lease} = KeyCustodian.lease(custodian, request)
    assert {:ok, "source"} = KeyLease.read_chunk(lease, 0)
    assert_receive {:revalidate_document, revalidated}
    assert revalidated.resource_version_id == request.resource_version_id
    assert_receive {:read_document_chunk, binding, 0}
    assert binding.resource_version_id == request.resource_version_id
    assert binding.session_id == "session-1"
    expected = KeyLease.document_checkpoint(request, 0)
    next = KeyLease.document_checkpoint(request, 1)
    assert expected["protocol"] == "document_source_v1"
    assert expected["resource_version_id"] == request.resource_version_id
    assert next["next_chunk_index"] == 1
  end

  test "request source lease is session-bound and does not accept worker fields" do
    {custodian, worker_request} = setup_custodian()
    assert :ok = unlock(custodian)

    request =
      worker_request
      |> Map.delete(:job_id)
      |> Map.merge(%{access: :request, session_id: "session-1"})

    assert {:error, %Error{code: :invalid}} =
             KeyCustodian.lease(custodian, Map.put(request, :job_id, "job-1"))

    assert {:ok, lease} = KeyCustodian.lease(custodian, request)
    assert {:ok, "source"} = DownloadLease.read_document_chunk(lease, 0)
    assert_receive {:revalidate_document, revalidated}
    assert revalidated.resource_version_id == request.resource_version_id
    assert_receive {:read_document_chunk, binding, 0}
    assert binding.resource_version_id == request.resource_version_id
    assert {:ok, token} = KeyCustodian.begin_revoke(custodian, %{session_id: "session-1"})
    assert :ok = KeyCustodian.finish_revoke(custodian, token)
    assert {:error, :waiting_for_unlock} = DownloadLease.read_document_chunk(lease, 1)
  end

  defp setup_custodian do
    context = %{owner: self(), now: @now}
    supervisor = start_supervised!({KeyLeaseSupervisor, name: nil}, id: make_ref())

    custodian =
      start_supervised!(
        {KeyCustodian,
         %{
           authorization: Authorization,
           clock: Clock,
           context: context,
           idle_lock: {IdleLock, self()},
           key_reader: Reader,
           lease_supervisor: supervisor,
           object_key_loader: Reader
         }},
        id: make_ref()
      )

    request = %{
      purpose: :document_source,
      access: :worker,
      job_id: "job-1",
      resource_version_id: "version-1",
      vault_id: "vault-1",
      principal_id: "principal-1",
      required_capability: "asset.read",
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 23,
      object_id: "object-1",
      object_generation: 3
    }

    {custodian, request}
  end

  defp fresh_custodian do
    request = %{
      purpose: :document_extraction_source,
      access: :worker,
      job_id: Ecto.UUID.generate(),
      resource_version_id: Ecto.UUID.generate(),
      vault_id: Ecto.UUID.generate(),
      principal_id: Ecto.UUID.generate(),
      required_capability: "asset.read",
      principal_authorization_epoch: 0,
      vault_authorization_epoch: 0,
      object_id: Ecto.UUID.generate(),
      object_generation: 1
    }

    session = %{
      session_id: Ecto.UUID.generate(),
      principal_id: request.principal_id,
      vault_id: request.vault_id,
      principal_authorization_epoch: 0,
      vault_authorization_epoch: 0,
      expires_at: DateTime.add(@now, 300, :second),
      vault_key: :binary.copy(<<1>>, 32)
    }

    supervisor = start_supervised!({KeyLeaseSupervisor, name: nil}, id: make_ref())

    custodian =
      start_supervised!(
        {KeyCustodian,
         %{
           authorization: Authorization,
           clock: Clock,
           context: %{owner: self(), now: @now},
           idle_lock: {IdleLock, self()},
           key_reader: FreshReader,
           lease_supervisor: supervisor,
           object_key_loader: FreshReader
         }},
        id: make_ref()
      )

    {custodian, request, session}
  end

  defp activate_session(custodian, session) do
    with {:ok, pending} <- KeyCustodian.prepare_unlock(custodian, session),
         do: KeyCustodian.activate_unlock(custodian, pending)
  end

  defp unlock(custodian) do
    session = %{
      session_id: "session-1",
      expires_at: DateTime.add(@now, 300, :second),
      principal_id: "principal-1",
      vault_id: "vault-1",
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 23,
      vault_key: :binary.copy(<<1>>, 32),
      domain_key: :binary.copy(<<2>>, 32),
      domain_dedup_key: :binary.copy(<<3>>, 32),
      key_domain_id: "domain-1",
      domain_key_version_id: "domain-version-1",
      domain_key_generation: 5,
      domain_classification: :private,
      object_keys: %{{"object-1", 3} => :binary.copy(<<4>>, 32)}
    }

    with {:ok, pending} <- KeyCustodian.prepare_unlock(custodian, session) do
      KeyCustodian.activate_unlock(custodian, pending)
    end
  end
end

defmodule Singularity.Runtime.DocumentFreshCustodyIntegrationTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration
  @moduletag :tmp_dir

  alias Singularity.Core.{Error, ObjectRef}

  alias Singularity.Runtime.{
    CustodyReader,
    DownloadLease,
    KeyCustodian,
    KeyLease,
    KeyLeaseSupervisor
  }

  alias Singularity.Storage.{
    Fixtures,
    KnowledgeFixtures,
    LocalFilesystemAdapter,
    MigrationRepo,
    ScopedRepo
  }

  alias Singularity.Storage.Crypto.{ChunkedAEAD, Format, KeyWrapper}
  alias Singularity.Storage.Local.PathGuard
  alias Singularity.Storage.Postgres.CustodyRepository

  setup context do
    plaintext = Map.get(context, :plaintext, "")
    fixture = source_fixture!(context.tmp_dir, plaintext)
    supervisor = start_supervised!({KeyLeaseSupervisor, name: nil}, id: make_ref())

    custody_context = %{
      key_wrapper: KeyWrapper,
      repo: WorkerRepo,
      repository_adapter: CustodyRepository,
      scope: ScopedRepo,
      storage: %{adapter: LocalFilesystemAdapter, context: %{root: context.tmp_dir}}
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
           object_key_loader: CustodyReader,
           lease_supervisor: supervisor
         }},
        id: make_ref()
      )

    session =
      Map.merge(
        Map.take(fixture, [
          :session_id,
          :principal_id,
          :vault_id,
          :key_domain_id,
          :domain_key_version_id,
          :domain_key
        ]),
        %{
          principal_authorization_epoch: 0,
          vault_authorization_epoch: 0,
          expires_at: DateTime.add(DateTime.utc_now(), 300, :second),
          domain_key_generation: 1,
          domain_classification: :private,
          domain_dedup_key: :crypto.strong_rand_bytes(32),
          vault_key: :crypto.strong_rand_bytes(32)
        }
      )

    assert {:ok, pending} = KeyCustodian.prepare_unlock(custodian, session)
    assert :ok = KeyCustodian.activate_unlock(custodian, pending)
    {:ok, fixture: fixture, custodian: custodian, plaintext: plaintext}
  end

  @tag plaintext: :binary.copy("a", 4_194_304) <> "tail"
  test "real partial and full fresh reads restart at zero without touching existing v4 progress",
       context do
    %{fixture: fixture, custodian: custodian, plaintext: plaintext} = context
    legacy_request = %{fixture.request | purpose: :document_source}
    assert {:ok, old_lease} = KeyCustodian.lease(custodian, legacy_request)
    assert {:ok, first} = KeyLease.read_chunk(old_lease, 0)
    snapshot = progress(fixture)
    assert [[4, 0, %{"protocol" => "document_source_v1", "next_chunk_index" => 1}]] = snapshot

    assert {:ok, partial} = KeyCustodian.lease(custodian, fixture.request)
    assert {:ok, ^first} = DownloadLease.read_document_chunk(partial, 0)
    assert :ok = DownloadLease.revoke(partial)

    for _ <- 1..2 do
      assert {:ok, fresh} = KeyCustodian.lease(custodian, fixture.request)
      assert {:ok, ^first} = DownloadLease.read_document_chunk(fresh, 0)
      assert {:ok, "tail"} = DownloadLease.read_document_chunk(fresh, 1)
      assert :crypto.hash(:sha256, first <> "tail") == :crypto.hash(:sha256, plaintext)
      assert :ok = DownloadLease.revoke(fresh)
      assert progress(fixture) == snapshot
    end

    assert {:ok, resumed} = KeyCustodian.lease(custodian, legacy_request)
    assert {:ok, "tail"} = KeyLease.read_chunk(resumed, 1)
    assert [[4, 0, %{"next_chunk_index" => 2}]] = progress(fixture)
    assert :ok = KeyLease.revoke(old_lease)
    assert :ok = KeyLease.revoke(resumed)
  end

  test "real empty original authenticates the retained object and creates no progress", %{
    fixture: fixture,
    custodian: custodian
  } do
    assert progress(fixture) == []
    assert {:ok, lease} = KeyCustodian.lease(custodian, fixture.request)
    assert :ok = empty(lease)
    refute Process.alive?(lease)
    assert progress(fixture) == []
  end

  for corruption <- [:missing, :header, :final] do
    test "real #{corruption} empty original fails storage authentication", %{
      fixture: fixture,
      custodian: custodian
    } do
      case unquote(corruption) do
        :missing -> File.rename!(fixture.path, fixture.path <> ".missing")
        :header -> corrupt_byte!(fixture.path, 0)
        :final -> corrupt_byte!(fixture.path, File.stat!(fixture.path).size - 1)
      end

      assert {:ok, lease} = KeyCustodian.lease(custodian, fixture.request)
      assert {:error, %Error{}} = empty(lease)
      refute Process.alive?(lease)
      assert progress(fixture) == []
    end
  end

  @tag plaintext: "original"
  test "real nonempty binding denies empty authentication and forged original bindings", %{
    fixture: fixture,
    custodian: custodian
  } do
    assert {:ok, lease} = KeyCustodian.lease(custodian, fixture.request)
    assert {:error, %Error{code: :invalid}} = empty(lease)
    assert {:ok, "original"} = DownloadLease.read_document_chunk(lease, 0)
    assert :ok = DownloadLease.revoke(lease)

    for request <- [
          %{fixture.request | resource_version_id: Ecto.UUID.generate()},
          %{fixture.request | object_id: Ecto.UUID.generate()},
          %{fixture.request | object_generation: 2}
        ] do
      assert {:error, %Error{code: :forbidden}} = KeyCustodian.lease(custodian, request)
    end

    assert progress(fixture) == []
  end

  @tag plaintext: :binary.copy("b", 4_194_304) <> "tail"
  test "real authority changes fence a subsequent chunk", %{
    fixture: fixture,
    custodian: custodian
  } do
    assert {:ok, lease} = KeyCustodian.lease(custodian, fixture.request)
    assert {:ok, _first} = DownloadLease.read_document_chunk(lease, 0)

    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "UPDATE identity.principals SET authorization_epoch=1 WHERE id=$1", [
        Ecto.UUID.dump!(fixture.principal_id)
      ])
    end)

    assert {:error, %Error{code: :forbidden}} = DownloadLease.read_document_chunk(lease, 1)
    refute Process.alive?(lease)
  end

  @tag plaintext: "retained original"
  test "source Asset deletion retains bytes while Document deletion fences pending reads", %{
    fixture: fixture,
    custodian: custodian
  } do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id=$1",
        [fixture.source.resource_id]
      )
    end)

    assert {:ok, lease} = KeyCustodian.lease(custodian, fixture.request)
    assert {:ok, "retained original"} = DownloadLease.read_document_chunk(lease, 0)
    assert :ok = DownloadLease.revoke(lease)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id=$1",
        [fixture.document.resource_id]
      )
    end)

    assert {:error, %Error{code: :forbidden}} = KeyCustodian.lease(custodian, fixture.request)
  end

  defp source_fixture!(root, plaintext) do
    %{one: source} = Fixtures.two_vaults!()

    ids =
      Map.new(
        [:object_id, :key_domain_id, :domain_key_version_id, :vault_key_version_id, :job_id],
        &{&1, Ecto.UUID.generate()}
      )

    vault_id = Ecto.UUID.load!(source.vault_id)
    domain_key = :crypto.strong_rand_bytes(32)
    dek = :crypto.strong_rand_bytes(32)
    lookup_digest = :crypto.strong_rand_bytes(32)

    {:ok, ciphertext} =
      ChunkedAEAD.encode(%{
        key: dek,
        plaintext: plaintext,
        chunk_index: 0,
        format_version: Format.format_version(),
        algorithm: Format.algorithm(),
        chunk_size: Format.chunk_size(),
        vault_id: vault_id,
        encryption_domain_id: ids.key_domain_id,
        object_id: ids.object_id
      })

    storage = %{
      root: root,
      vault_namespace: vault_id,
      domain_namespace: ids.key_domain_id,
      lookup_digest: Base.encode16(lookup_digest, case: :lower)
    }

    assert {:ok, stage} = LocalFilesystemAdapter.stage(storage, %{})
    assert :ok = LocalFilesystemAdapter.append_encrypted_chunk(storage, stage, ciphertext)
    assert {:ok, %{sealed?: true}} = LocalFilesystemAdapter.seal_stage(storage, stage, %{})
    object_ref = %ObjectRef{object_id: ids.object_id}
    assert {:ok, ^object_ref} = LocalFilesystemAdapter.finalize(storage, stage, object_ref)

    assert {:ok, path} =
             PathGuard.object_path(root, vault_id, ids.key_domain_id, storage.lookup_digest)

    assert {:ok, wrapper} =
             KeyWrapper.wrap(domain_key, dek, %{
               purpose: :object_dek,
               generation: 1,
               aad: "object:" <> ids.object_id
             })

    digest = :crypto.hash(:sha256, plaintext)

    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "UPDATE core.vaults SET locked=false WHERE id=$1", [source.vault_id])

      query!(
        MigrationRepo,
        "INSERT INTO core.capabilities(id,name) VALUES($1,'asset.read') ON CONFLICT(name) DO NOTHING",
        [KnowledgeFixtures.uuid()]
      )

      query!(
        MigrationRepo,
        "INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name='asset.read'",
        [source.principal_id, source.vault_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO core.vault_key_versions(id,vault_id,generation,state,algorithm,activated_at) VALUES($1,$2,1,'active','aes_256_gcm',CURRENT_TIMESTAMP)",
        [Ecto.UUID.dump!(ids.vault_key_version_id), source.vault_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO core.key_domains(id,vault_id,classification,kind,state) VALUES($1,$2,'private','content','active')",
        [Ecto.UUID.dump!(ids.key_domain_id), source.vault_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO core.domain_key_versions(id,vault_id,key_domain_id,vault_key_version_id,generation,state,algorithm,wrapped_key) VALUES($1,$2,$3,$4,1,'active','aes_256_gcm',$5)",
        [
          Ecto.UUID.dump!(ids.domain_key_version_id),
          source.vault_id,
          Ecto.UUID.dump!(ids.key_domain_id),
          Ecto.UUID.dump!(ids.vault_key_version_id),
          :crypto.strong_rand_bytes(60)
        ]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.asset_objects(id,vault_id,key_domain_id,classification,lookup_digest,ciphertext_hash,plaintext_byte_size,ciphertext_byte_size,storage_ref,format_version,lifecycle) VALUES($1,$2,$3,'private',$4,$5,$6,$7,$8,1,'available')",
        [
          Ecto.UUID.dump!(ids.object_id),
          source.vault_id,
          Ecto.UUID.dump!(ids.key_domain_id),
          lookup_digest,
          :crypto.hash(:sha256, ciphertext),
          byte_size(plaintext),
          byte_size(ciphertext),
          ids.object_id
        ]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.asset_key_envelopes(id,vault_id,asset_object_id,domain_key_version_id,key_domain_id,classification,algorithm,key_generation,wrapped_dek) VALUES($1,$2,$3,$4,$5,'private','aes_256_gcm',1,$6)",
        [
          KnowledgeFixtures.uuid(),
          source.vault_id,
          Ecto.UUID.dump!(ids.object_id),
          Ecto.UUID.dump!(ids.domain_key_version_id),
          Ecto.UUID.dump!(ids.key_domain_id),
          wrapper.encoded
        ]
      )

      query!(
        MigrationRepo,
        "UPDATE content.assets SET state='available',asset_object_id=$1 WHERE id=$2",
        [Ecto.UUID.dump!(ids.object_id), source.asset_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.resource_assets(resource_version_id,asset_id,vault_id,classification) VALUES($1,$2,$3,'private')",
        [source.resource_version_id, source.asset_id, source.vault_id]
      )
    end)

    source =
      Map.merge(source, %{
        object_id: Ecto.UUID.dump!(ids.object_id),
        digest: digest,
        byte_size: byte_size(plaintext)
      })

    document = KnowledgeFixtures.document!(source)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO core.outbox_events(id,event_type,idempotency_key,vault_id,principal_id,required_capability,principal_authorization_epoch,vault_authorization_epoch,classification,correlation_id,expected_entity_revision,envelope_version,payload,occurred_at) VALUES($1,'document.extraction_requested',$2,$3,$4,'asset.read',0,0,'private',$1,0,1,$5::text::jsonb,CURRENT_TIMESTAMP)",
        [
          Ecto.UUID.dump!(ids.job_id),
          "document-extraction:" <> Ecto.UUID.load!(document.resource_version_id),
          source.vault_id,
          source.principal_id,
          JSON.encode!(%{
            "resource_id" => Ecto.UUID.load!(document.resource_id),
            "resource_version_id" => Ecto.UUID.load!(document.resource_version_id)
          })
        ]
      )

      query!(
        MigrationRepo,
        "INSERT INTO jobs.job_submissions(id,vault_id,outbox_event_id,classification,idempotency_key,job_type) VALUES($1,$2,$1,'private',$3,'document_extract')",
        [Ecto.UUID.dump!(ids.job_id), source.vault_id, "document-extract:" <> ids.job_id]
      )
    end)

    request = %{
      purpose: :document_extraction_source,
      access: :worker,
      job_id: ids.job_id,
      resource_version_id: Ecto.UUID.load!(document.resource_version_id),
      vault_id: vault_id,
      principal_id: Ecto.UUID.load!(source.principal_id),
      required_capability: "asset.read",
      principal_authorization_epoch: 0,
      vault_authorization_epoch: 0,
      object_id: ids.object_id,
      object_generation: 1
    }

    Map.merge(ids, %{
      source: source,
      document: document,
      request: request,
      path: path,
      vault_id: vault_id,
      principal_id: request.principal_id,
      session_id: Ecto.UUID.load!(source.session_id),
      domain_key: domain_key
    })
  end

  defp progress(fixture) do
    ScopedRepo.transact(
      WorkerRepo,
      %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
      fn repo ->
        query!(
          repo,
          "SELECT checkpoint_version,processing_revision,checkpoint FROM jobs.job_progress WHERE submission_id=$1",
          [Ecto.UUID.dump!(fixture.job_id)]
        ).rows
      end
    )
  end

  defp corrupt_byte!(path, offset) do
    File.chmod!(path, 0o600)
    {:ok, io} = :file.open(path, [:read, :write, :binary])

    try do
      {:ok, <<byte>>} = :file.pread(io, offset, 1)
      :ok = :file.pwrite(io, offset, <<Bitwise.bxor(byte, 1)>>)
      :ok = :file.sync(io)
    after
      :ok = :file.close(io)
    end
  end

  defp empty(lease), do: apply(DownloadLease, :authenticate_empty_document_source, [lease])
end

defmodule Singularity.Runtime.DocumentCustodyPermissionTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  import Singularity.Storage.DataCase, only: [query!: 3]
  alias Singularity.Storage.{Fixtures, KnowledgeFixtures, MigrationRepo, ScopedRepo, WorkerRepo}

  test "worker backup reads require active matching RLS scope and never permit direct Document mutation" do
    # Disposable SQL metadata establishes permissions and immutable pins only,
    # not authenticated original bytes or a replacement for native custody.
    source = KnowledgeFixtures.source!()
    foreign = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)
    other_document = KnowledgeFixtures.document!(foreign)
    KnowledgeFixtures.retire_document_on_exit!(document)
    KnowledgeFixtures.retire_document_on_exit!(other_document)
    versions = [document.resource_version_id, other_document.resource_version_id]
    original_rows = owner_rows(versions)

    WorkerRepo.checkout(fn ->
      assert %{rows: [[backend, "singularity_worker", true, false, false, false, false]]} =
               query!(
                 WorkerRepo,
                 """
                 SELECT pg_backend_pid(), current_user,
                   has_table_privilege(current_user,'content.document_versions','SELECT'),
                   has_table_privilege(current_user,'content.document_versions','INSERT'),
                   has_table_privilege(current_user,'content.document_versions','UPDATE'),
                   has_table_privilege(current_user,'content.document_versions','DELETE'),
                   has_table_privilege(current_user,'content.document_versions','TRUNCATE')
                 """,
                 []
               )

      assert %{rows: [[true, true]]} =
               query!(
                 WorkerRepo,
                 """
                 SELECT relrowsecurity, relforcerowsecurity
                 FROM pg_class WHERE oid = 'content.document_versions'::regclass
                 """,
                 []
               )

      assert_context_absent!(backend)
      assert %{rows: []} = pin_rows(WorkerRepo, versions)

      assert scoped_rows(source, versions, backend) == [pin(document, source)]
      assert_context_absent!(backend)
      assert scoped_rows(foreign, versions, backend) == [pin(other_document, foreign)]
      assert_context_absent!(backend)

      for context <- [
            foreign,
            %{source | vault_id: foreign.vault_id},
            %{source | principal_id: foreign.principal_id}
          ] do
        assert scoped_rows(context, [document.resource_version_id], backend) == []
        assert_context_absent!(backend)
      end

      assert {:error, :document_scope_rollback} =
               ScopedRepo.transact(WorkerRepo, source, fn scoped ->
                 assert_scope!(scoped, backend, source)
                 assert %{rows: rows} = pin_rows(scoped, versions)
                 assert rows == [pin(document, source)]
                 {:error, :document_scope_rollback}
               end)

      assert_context_absent!(backend)
      assert %{rows: []} = pin_rows(WorkerRepo, versions)

      # Each native denial runs in a separate real transaction. An unexpected
      # successful statement is still rolled back before its assertion fails.
      for {statement, params} <- [
            {"INSERT INTO content.document_versions SELECT * FROM content.document_versions WHERE resource_version_id=$1",
             [document.resource_version_id]},
            {"UPDATE content.document_versions SET title='forbidden mutation' WHERE resource_version_id=$1",
             [document.resource_version_id]},
            {"DELETE FROM content.document_versions WHERE resource_version_id=$1",
             [document.resource_version_id]},
            {"TRUNCATE TABLE content.document_versions", []}
          ] do
        result =
          ScopedRepo.transact(WorkerRepo, source, fn scoped ->
            assert_scope!(scoped, backend, source)

            case Singularity.Storage.SafeSQL.query(scoped, statement, params) do
              {:error, %Postgrex.Error{} = error} -> {:error, error}
              {:ok, _result} -> {:error, :unexpected_direct_mutation_success}
            end
          end)

        assert {:error,
                %Postgrex.Error{
                  postgres: %{code: :insufficient_privilege, pg_code: "42501"}
                }} = result

        assert_context_absent!(backend)
        assert owner_rows(versions) == original_rows
      end

      Fixtures.revoke_membership!(source)
      assert scoped_rows(source, versions, backend) == []
      assert_context_absent!(backend)
      assert scoped_rows(foreign, versions, backend) == [pin(other_document, foreign)]
      assert_context_absent!(backend)
      assert %{rows: []} = pin_rows(WorkerRepo, versions)
      assert owner_rows(versions) == original_rows
    end)
  end

  defp scoped_rows(context, versions, backend) do
    ScopedRepo.transact(WorkerRepo, context, fn scoped ->
      assert_scope!(scoped, backend, context)
      %{rows: rows} = pin_rows(scoped, versions)
      rows
    end)
  end

  defp pin_rows(repo, versions) do
    query!(
      repo,
      """
      SELECT resource_version_id, resource_id, vault_id, source_asset_id,
        source_resource_id, source_resource_version_id, source_object_id,
        source_digest, source_byte_size
      FROM content.document_versions
      WHERE resource_version_id = ANY($1::uuid[]) ORDER BY resource_version_id
      """,
      [versions]
    )
  end

  defp pin(document, source) do
    [
      document.resource_version_id,
      document.resource_id,
      source.vault_id,
      source.asset_id,
      source.resource_id,
      source.resource_version_id,
      source.object_id,
      source.digest,
      source.byte_size
    ]
  end

  defp owner_rows(versions) do
    Fixtures.with_owner(fn ->
      %{rows: rows} =
        query!(
          MigrationRepo,
          """
          SELECT * FROM content.document_versions
          WHERE resource_version_id = ANY($1::uuid[]) ORDER BY resource_version_id
          """,
          [versions]
        )

      rows
    end)
  end

  defp assert_scope!(repo, backend, context) do
    principal = Ecto.UUID.load!(context.principal_id)
    owner = Ecto.UUID.load!(context.vault_id)
    assert repo == WorkerRepo
    assert WorkerRepo.in_transaction?()

    assert %{rows: [[^backend, "singularity_worker", ^principal, ^owner]]} =
             query!(
               repo,
               """
               SELECT pg_backend_pid(), current_user,
                 current_setting('singularity.principal_id',true),
                 current_setting('singularity.vault_id',true)
               """,
               []
             )
  end

  defp assert_context_absent!(backend) do
    refute WorkerRepo.in_transaction?()

    assert %{rows: [[^backend, "singularity_worker", principal, owner]]} =
             query!(
               WorkerRepo,
               """
               SELECT pg_backend_pid(), current_user,
                 current_setting('singularity.principal_id',true),
                 current_setting('singularity.vault_id',true)
               """,
               []
             )

    assert principal in [nil, ""]
    assert owner in [nil, ""]
  end
end
