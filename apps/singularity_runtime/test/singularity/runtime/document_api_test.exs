defmodule Singularity.Runtime.DocumentApiTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.{DocumentSource, DocumentVersion, Error}
  alias Singularity.Runtime.Api
  alias Singularity.Runtime.DTO.Session
  alias Singularity.Runtime.Documents.Read
  alias Singularity.Runtime.SessionContext

  @principal "00000000-0000-4000-8000-000000000901"
  @owner "00000000-0000-4000-8000-000000000902"
  @resource "00000000-0000-4000-8000-000000000903"
  @version "00000000-0000-4000-8000-000000000904"
  @asset "00000000-0000-4000-8000-000000000905"
  @source_resource "00000000-0000-4000-8000-000000000906"
  @source_version "00000000-0000-4000-8000-000000000907"
  @object "00000000-0000-4000-8000-000000000908"

  defmodule ReadScope do
    def with_read_request(owner, _runtime, _session, requirement, callback) do
      send(owner, {:document_read_scope, requirement})
      callback.(:scoped_repo)
    end
  end

  defmodule ReadRepository do
    def source_live_scoped(owner, :scoped_repo, _context, resource_id) do
      send(owner, {:source_binding, resource_id})

      {:ok,
       %{
         resource_id: resource_id,
         resource_version_id: "00000000-0000-4000-8000-000000000904",
         object_id: "00000000-0000-4000-8000-000000000908",
         object_generation: 7,
         source_digest: :crypto.hash(:sha256, "source bytes"),
         source_byte_size: 12
       }}
    end
  end

  defmodule ReadCustodian do
    def lease(owner, request) do
      count = Process.get(:document_lease_count, 0) + 1
      Process.put(:document_lease_count, count)
      send(owner, {:document_lease, count, request})
      {:ok, {count, owner}}
    end
  end

  defmodule DocumentReader do
    def read_document_chunk(owner, {lease, owner}, index) do
      send(owner, {:document_chunk, lease, index})
      {:ok, Process.get(:document_bytes, "source bytes")}
    end

    def revoke(owner, {lease, owner}) do
      send(owner, {:document_revoke, lease})
      :ok
    end
  end

  test "exposes bounded live reads through paired public seams" do
    document = document()

    config = %{
      get_document: fn context, @resource ->
        send(self(), {:get, context})
        {:ok, document}
      end,
      list_documents: fn context, params ->
        send(self(), {:list, context, params})
        {:ok, %{items: [document], next_cursor: "cursor"}}
      end,
      document_status: fn context, @resource ->
        send(self(), {:status, context})
        {:ok, %{resource_id: @resource, state: :pending, generation: 0}}
      end,
      document_fragments: fn _context, @resource -> {:error, Error.new(:conflict)} end,
      download_document_original: fn context, @resource ->
        send(self(), {:download, context})
        {:ok, %{byte_size: 12, chunks: ["source bytes"]}}
      end
    }

    assert {:ok, ^document} = Api.get_document(config, session(), @resource)

    assert {:ok, %{items: [^document], next_cursor: "cursor"}} =
             Api.list_documents(config, session(), %{limit: 1})

    assert {:ok, %{resource_id: @resource, state: :pending, generation: 0}} =
             Api.document_status(config, session(), @resource)

    assert {:error, :conflict} = Api.document_fragments(config, session(), @resource)

    assert {:ok, %{byte_size: 12, chunks: ["source bytes"]}} =
             Api.download_document_original(config, session(), @resource)

    for action <- [:get, :status, :download] do
      assert_received {^action, %{principal_id: @principal, vault_id: @owner}}
    end

    assert_received {:list, %{principal_id: @principal, vault_id: @owner}, %{limit: 1}}
  end

  test "rejects invalid IDs, unbounded pages, cursors, and caller-owned canonical fields" do
    reject = fn _, _ -> flunk("invalid input crossed the facade") end

    config = %{
      get_document: reject,
      list_documents: reject,
      document_status: reject,
      document_fragments: reject,
      download_document_original: reject,
      retry_document: reject,
      delete_document: reject,
      restore_document: reject
    }

    assert {:error, :invalid} = Api.get_document(config, session(), "not-a-uuid")
    assert {:error, :invalid} = Api.list_documents(config, session(), %{limit: 0})
    assert {:error, :invalid} = Api.list_documents(config, session(), %{limit: 101})
    assert {:error, :invalid} = Api.list_documents(config, session(), %{cursor: "forged"})

    forged = %{state: :ready, generation: 9, owner_scope_id: @owner, object_id: @object}
    assert {:error, :invalid} = Api.retry_document(config, session(), @resource, forged)
    assert {:error, :invalid} = Api.delete_document(config, session(), @resource, forged)
    assert {:error, :invalid} = Api.restore_document(config, session(), @resource, forged)
  end

  test "normalizes idempotent lifecycle mutations" do
    config = %{
      retry_document: fn context, @resource ->
        send(self(), {:retry, context})
        {:ok, document()}
      end,
      delete_document: fn context, @resource ->
        send(self(), {:delete, context})
        :ok
      end,
      restore_document: fn context, @resource ->
        send(self(), {:restore, context})
        {:ok, document()}
      end
    }

    assert {:ok, %DocumentVersion{resource_id: @resource}} =
             Api.retry_document(config, session(), @resource)

    assert :ok = Api.delete_document(config, session(), @resource)

    assert {:ok, %DocumentVersion{resource_id: @resource}} =
             Api.restore_document(config, session(), @resource)

    assert_received {:retry, %{vault_id: @owner}}
    assert_received {:delete, %{vault_id: @owner}}
    assert_received {:restore, %{vault_id: @owner}}
  end

  test "original download preflights digest before returning a fresh bounded reader" do
    runtime = read_runtime()
    context = session_context()

    assert {:ok, %{byte_size: 12, chunk_count: 1, read_chunk: read_chunk}} =
             Read.download_original(runtime, context, @resource)

    assert_received {:document_lease, 1, %{access: :request, object_id: @object}}
    assert_received {:document_chunk, 1, 0}
    assert_received {:document_revoke, 1}
    assert_received {:document_lease, 2, %{access: :request, object_id: @object}}

    assert {:ok, "source bytes"} = read_chunk.(0)
    assert_received {:document_chunk, 2, 0}
    assert {:error, %Error{code: :invalid}} = read_chunk.(1)
  end

  test "digest mismatch returns no delivery reader or chunks" do
    Process.put(:document_bytes, "wrong bytes!")

    assert {:error, %Error{code: :integrity_failure}} =
             Read.download_original(read_runtime(), session_context(), @resource)

    assert_received {:document_lease, 1, _request}
    assert_received {:document_chunk, 1, 0}
    assert_received {:document_revoke, 1}
    refute_received {:document_lease, 2, _request}
  end

  defp read_runtime do
    %{
      operation_scope: {ReadScope, self()},
      document_repository: {ReadRepository, self()},
      custodian: {ReadCustodian, self()},
      authenticated_reader: {DocumentReader, self()}
    }
  end

  defp session_context do
    struct(SessionContext, Map.from_struct(session()))
  end

  defp session do
    %Session{
      session_id: "00000000-0000-4000-8000-000000000909",
      account_id: nil,
      principal_id: @principal,
      vault_id: @owner,
      expires_at: ~U[2026-09-23 12:00:00Z],
      principal_authorization_epoch: 3,
      vault_authorization_epoch: 5,
      authorization_epoch: 3,
      unlocked?: true
    }
  end

  defp document do
    source = %DocumentSource{
      asset_id: @asset,
      resource_id: @source_resource,
      resource_version_id: @source_version,
      object_id: @object,
      owner_scope_id: @owner,
      classification: :private,
      digest: :crypto.hash(:sha256, "source bytes"),
      byte_size: 12,
      media_type: "text/plain"
    }

    %DocumentVersion{
      resource_id: @resource,
      resource_version_id: @version,
      owner_scope_id: @owner,
      classification: :private,
      revision: 0,
      source: source,
      title: "Document",
      created_by_principal_id: @principal,
      inserted_at: ~U[2026-09-23 00:00:00Z],
      state: :pending,
      generation: 0
    }
  end
end

defmodule Singularity.Runtime.DocumentApiIntegrationTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration

  alias Singularity.Core.{DocumentCompletion, DocumentVersion, Error, ObjectRef}
  alias Singularity.Runtime.{CustodyReader, KeyCustodian, KeyLeaseSupervisor, SessionContext}
  alias Singularity.Runtime.Documents.Read

  alias Singularity.Storage.{
    Fixtures,
    KnowledgeFixtures,
    KnowledgeTestGrants,
    MigrationRepo,
    RequestRepo,
    ScopedRepo
  }

  alias Singularity.Storage.Crypto.{ChunkedAEAD, Format, KeyWrapper}
  alias Singularity.Storage.{LocalFilesystemAdapter, WorkerRepo}
  alias Singularity.Storage.Postgres.{CustodyRepository, DocumentRepository}

  defmodule LiveReadScope do
    def with_read_request(runtime, session, _requirement, callback) do
      Singularity.Storage.ScopedRepo.transact(
        runtime.request_repo,
        %{principal_id: session.principal_id, vault_id: session.vault_id},
        callback
      )
    end
  end

  test "live reads use a stable bounded cursor and expose only ordered ready fragments" do
    source = KnowledgeFixtures.source!()
    other = KnowledgeFixtures.source!()
    first = KnowledgeFixtures.document!(source)
    {ready, fragment} = KnowledgeFixtures.ready_document!(source)
    grant_runtime!(source)

    context = context(source)

    assert {:error, %Error{code: :not_found}} =
             scoped(
               context(other),
               &DocumentRepository.get_live_scoped(&1, context(other), uuid(first.resource_id))
             )

    assert {:ok, %{items: [%DocumentVersion{}], next_cursor: {_time, _id} = cursor}} =
             scoped(
               context,
               &DocumentRepository.list_live_scoped(&1, context, %{limit: 1, cursor: nil})
             )

    assert {:ok, %{items: [%DocumentVersion{}], next_cursor: nil}} =
             scoped(
               context,
               &DocumentRepository.list_live_scoped(&1, context, %{limit: 1, cursor: cursor})
             )

    assert {:error, %Error{code: :conflict}} =
             scoped(
               context,
               &DocumentRepository.fragments_live_scoped(&1, context, uuid(first.resource_id))
             )

    assert {:ok, [loaded]} =
             scoped(
               context,
               &DocumentRepository.fragments_live_scoped(&1, context, uuid(ready.resource_id))
             )

    assert loaded.ordinal == 0
    assert loaded.fragment_id == fragment.fragment_id

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id=$1",
        [
          ready.resource_id
        ]
      )
    end)

    assert {:error, %Error{code: :not_found}} =
             scoped(
               context,
               &DocumentRepository.get_live_scoped(&1, context, uuid(ready.resource_id))
             )
  end

  test "retry and delete restore are atomic and idempotent with one IDs-only event" do
    source = KnowledgeFixtures.source!()
    failed = KnowledgeFixtures.document!(source)
    pending = KnowledgeFixtures.document!(source)
    grant_runtime!(source)
    fail_document!(failed)
    context = context(source)
    versions = %{"text/plain" => %{adapter_name: "plain", format_version: 1}}

    assert {:ok, %DocumentVersion{state: :pending, generation: 2}} =
             scoped(
               context,
               &DocumentRepository.retry_live_scoped(
                 &1,
                 context,
                 uuid(failed.resource_id),
                 versions
               )
             )

    assert {:ok, %DocumentVersion{state: :pending, generation: 2}} =
             scoped(
               context,
               &DocumentRepository.retry_live_scoped(
                 &1,
                 context,
                 uuid(failed.resource_id),
                 versions
               )
             )

    assert :ok =
             scoped(
               context,
               &DocumentRepository.delete_live_scoped(
                 &1,
                 context,
                 uuid(pending.resource_id),
                 versions
               )
             )

    assert :ok =
             scoped(
               context,
               &DocumentRepository.delete_live_scoped(
                 &1,
                 context,
                 uuid(pending.resource_id),
                 versions
               )
             )

    assert {:error, %Error{code: :not_found}} =
             scoped(
               context,
               &DocumentRepository.get_live_scoped(&1, context, uuid(pending.resource_id))
             )

    assert {:ok, %DocumentVersion{resource_id: restored, state: :pending}} =
             scoped(
               context,
               &DocumentRepository.restore_live_scoped(
                 &1,
                 context,
                 uuid(pending.resource_id),
                 versions
               )
             )

    assert restored == uuid(pending.resource_id)

    assert {:ok, %DocumentVersion{state: :pending}} =
             scoped(
               context,
               &DocumentRepository.restore_live_scoped(
                 &1,
                 context,
                 uuid(pending.resource_id),
                 versions
               )
             )

    Fixtures.with_owner(fn ->
      assert %{rows: [[1]]} =
               query!(
                 MigrationRepo,
                 "SELECT count(*) FROM core.outbox_events WHERE idempotency_key=$1",
                 [
                   "document-extraction:#{uuid(failed.resource_version_id)}:2"
                 ]
               )

      assert %{rows: [[1, payload]]} =
               query!(
                 MigrationRepo,
                 "SELECT count(*),max(payload::text) FROM core.outbox_events WHERE idempotency_key=$1",
                 [
                   "document-extraction:#{uuid(pending.resource_version_id)}:1"
                 ]
               )

      assert payload =~ uuid(pending.resource_id)
      refute payload =~ "Document"
      refute payload =~ "source bytes"
    end)
  end

  test "restore advances the generation beyond a delivered attempt and fences stale work" do
    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)
    grant_runtime!(source)
    context = context(source)
    same = %{"text/plain" => %{adapter_name: "plain", format_version: 1}}
    changed = %{"text/plain" => %{adapter_name: "plain", format_version: 2}}

    assert :ok =
             scoped(
               context,
               &DocumentRepository.delete_live_scoped(
                 &1,
                 context,
                 uuid(document.resource_id),
                 same
               )
             )

    assert {:ok, %DocumentVersion{state: :pending, generation: 1}} =
             scoped(
               context,
               &DocumentRepository.restore_live_scoped(
                 &1,
                 context,
                 uuid(document.resource_id),
                 same
               )
             )

    old_job = KnowledgeFixtures.uuid()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE core.outbox_events SET delivered_at=clock_timestamp() WHERE vault_id=$1 AND idempotency_key=$2",
        [
          document.vault_id,
          "document-extraction:#{uuid(document.resource_version_id)}:1"
        ]
      )

      query!(
        MigrationRepo,
        "SELECT set_config('singularity.principal_id',$1,true),set_config('singularity.vault_id',$2,true)",
        [uuid(document.created_by_principal_id), uuid(document.vault_id)]
      )

      query!(
        MigrationRepo,
        "SELECT content.claim_document_extraction($1,1,$2,'plain',1)",
        [document.resource_version_id, old_job]
      )

      query!(
        MigrationRepo,
        "SELECT content.fail_document_extraction($1,$2,2,'unsupported','malformed_document')",
        [document.resource_version_id, old_job]
      )

      query!(
        MigrationRepo,
        "UPDATE content.resources SET deleted_at=clock_timestamp() WHERE id=$1",
        [
          document.resource_id
        ]
      )
    end)

    assert {:ok, %DocumentVersion{state: :pending, generation: 3}} =
             scoped(
               context,
               &DocumentRepository.restore_live_scoped(
                 &1,
                 context,
                 uuid(document.resource_id),
                 changed
               )
             )

    Fixtures.with_owner(fn ->
      assert %{rows: [[true, 1]]} =
               query!(
                 MigrationRepo,
                 "SELECT delivered_at IS NOT NULL,expected_entity_revision FROM core.outbox_events WHERE vault_id=$1 AND idempotency_key=$2",
                 [
                   document.vault_id,
                   "document-extraction:#{uuid(document.resource_version_id)}:1"
                 ]
               )

      assert %{rows: [[3]]} =
               query!(
                 MigrationRepo,
                 "SELECT expected_entity_revision FROM core.outbox_events WHERE vault_id=$1 AND idempotency_key=$2",
                 [
                   document.vault_id,
                   "document-extraction:#{uuid(document.resource_version_id)}:3"
                 ]
               )
    end)

    worker_context = Map.put(context, :repo, WorkerRepo)

    {:ok, stale_completion} =
      DocumentCompletion.new(%{
        resource_id: uuid(document.resource_id),
        resource_version_id: uuid(document.resource_version_id),
        owner_scope_id: uuid(document.vault_id),
        classification: :private,
        generation: 2,
        outcome: :unsupported,
        adapter_name: "plain",
        format_version: 1,
        finished_at: DateTime.utc_now(:microsecond),
        media_type: "text/plain",
        failure_code: "malformed_document"
      })

    KnowledgeTestGrants.with_lifecycle_grants(fn ->
      KnowledgeTestGrants.with_grants(["document_versions"], fn ->
        assert {:error, %Error{code: :conflict}} =
                 DocumentRepository.claim(
                   worker_context,
                   uuid(document.resource_version_id),
                   1,
                   uuid(old_job),
                   "plain",
                   1
                 )

        assert {:error, %Error{code: :conflict}} =
                 DocumentRepository.complete(worker_context, uuid(old_job), stale_completion)
      end)
    end)
  end

  test "original download retains bytes after Asset deletion and a live lease revokes with its session" do
    source = KnowledgeFixtures.prepared_source!()

    document_source =
      Map.new(source, fn {key, value} ->
        {key,
         if(String.ends_with?(Atom.to_string(key), "_id"),
           do: Ecto.UUID.dump!(value),
           else: value
         )}
      end)

    document = KnowledgeFixtures.document!(document_source)
    grant_runtime!(document_source)
    plaintext = "source bytes"
    object_dek = :crypto.strong_rand_bytes(32)
    domain_key = :crypto.strong_rand_bytes(32)

    storage_root =
      Path.join(System.tmp_dir!(), "document-api-#{System.unique_integer([:positive])}")

    File.mkdir_p!(storage_root)
    on_exit(fn -> File.rm_rf!(storage_root) end)

    %{domain_id: domain_id, domain_version_id: domain_version_id, lookup_digest: _lookup_digest} =
      install_live_object!(source, plaintext, object_dek, domain_key, storage_root)

    lease_supervisor =
      start_supervised!({KeyLeaseSupervisor, name: nil}, id: make_ref())

    custody_context = %{
      key_wrapper: KeyWrapper,
      repo: WorkerRepo,
      repository_adapter: CustodyRepository,
      scope: ScopedRepo,
      storage: %{adapter: LocalFilesystemAdapter, context: %{root: storage_root}}
    }

    custodian =
      start_supervised!(
        {KeyCustodian,
         %{
           authorization: CustodyReader,
           clock: CustodyReader,
           context: custody_context,
           idle_lock: fn _session -> :ok end,
           key_reader: CustodyReader,
           key_wrapper: KeyWrapper,
           lease_supervisor: lease_supervisor,
           object_key_loader: CustodyReader
         }},
        id: make_ref()
      )

    session = live_session(source)

    assert {:ok, pending} =
             KeyCustodian.prepare_unlock(custodian, %{
               account_id: source.account_id,
               domain_classification: :private,
               domain_dedup_key: :crypto.strong_rand_bytes(32),
               domain_key: domain_key,
               domain_key_generation: 1,
               domain_key_version_id: domain_version_id,
               expires_at: session.expires_at,
               key_domain_id: domain_id,
               principal_authorization_epoch: 0,
               principal_id: source.principal_id,
               session_id: source.session_id,
               vault_authorization_epoch: 0,
               vault_id: source.vault_id,
               vault_key: :crypto.strong_rand_bytes(32)
             })

    assert :ok = KeyCustodian.activate_unlock(custodian, pending)

    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "UPDATE content.assets SET state='deleted' WHERE id=$1", [
        Ecto.UUID.dump!(source.asset_id)
      ])
    end)

    runtime = %{
      operation_scope: LiveReadScope,
      request_repo: RequestRepo,
      document_repository: DocumentRepository,
      custodian: {KeyCustodian, custodian},
      authenticated_reader: Singularity.Runtime.DownloadLease
    }

    assert {:ok, %{chunk_count: 1, read_chunk: read_chunk}} =
             Read.download_original(runtime, session, uuid(document.resource_id))

    assert {:ok, ^plaintext} = read_chunk.(0)
    assert {:ok, token} = KeyCustodian.begin_revoke(custodian, %{session_id: session.session_id})
    assert :ok = KeyCustodian.finish_revoke(custodian, token)
    assert {:error, :waiting_for_unlock} = read_chunk.(0)
  end

  test "unsupported retry requires a changed adapter or format and ready never reopens" do
    source = KnowledgeFixtures.source!()
    unsupported = KnowledgeFixtures.document!(source)
    {ready, _fragment} = KnowledgeFixtures.ready_document!(source)
    grant_runtime!(source)
    fail_document!(unsupported, "unsupported", "malformed_document")
    context = context(source)

    same = %{"text/plain" => %{adapter_name: "plain", format_version: 1}}
    changed = %{"text/plain" => %{adapter_name: "plain", format_version: 2}}

    assert {:error, %Error{code: :conflict}} =
             scoped(
               context,
               &DocumentRepository.retry_live_scoped(
                 &1,
                 context,
                 uuid(unsupported.resource_id),
                 same
               )
             )

    assert {:ok, %DocumentVersion{state: :pending}} =
             scoped(
               context,
               &DocumentRepository.retry_live_scoped(
                 &1,
                 context,
                 uuid(unsupported.resource_id),
                 changed
               )
             )

    assert {:error, %Error{code: :conflict}} =
             scoped(
               context,
               &DocumentRepository.retry_live_scoped(&1, context, uuid(ready.resource_id), same)
             )
  end

  test "runtime mutation definers are hardened and only the web role can execute public entrypoints" do
    signatures = [
      {"content.document_runtime_target(uuid,boolean)", []},
      {"content.delete_document_runtime(uuid)", ["singularity_web"]},
      {"content.retry_document_runtime(uuid,text,integer)", ["singularity_web"]},
      {"content.restore_document_runtime(uuid,text,integer)", ["singularity_web"]}
    ]

    for {signature, executors} <- signatures do
      assert %{rows: [[true, "singularity_table_owner", config]]} =
               query!(
                 RequestRepo,
                 "SELECT p.prosecdef,pg_get_userbyid(p.proowner),p.proconfig FROM pg_proc p WHERE p.oid=to_regprocedure($1)",
                 [signature]
               )

      assert "search_path=pg_catalog, content, core, identity" in config

      for role <-
            ~w(singularity_web singularity_worker singularity_dispatcher singularity_pre_auth) do
        assert %{rows: [[allowed?]]} =
                 query!(
                   RequestRepo,
                   "SELECT has_function_privilege($1,$2,'EXECUTE')",
                   [role, signature]
                 )

        assert allowed? == role in executors
      end

      assert %{rows: [[false]]} =
               query!(RequestRepo, "SELECT has_function_privilege('public',$1,'EXECUTE')", [
                 signature
               ])
    end

    for role <-
          ~w(singularity_web singularity_worker singularity_dispatcher singularity_pre_auth),
        table <- ~w(content.document_versions content.document_fragments),
        privilege <- ~w(INSERT UPDATE DELETE) do
      assert %{rows: [[false]]} =
               query!(RequestRepo, "SELECT has_table_privilege($1,$2,$3)", [
                 role,
                 table,
                 privilege
               ])
    end
  end

  defp fail_document!(document, outcome \\ "failed", reason \\ "timeout") do
    job = KnowledgeFixtures.uuid()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "SELECT set_config('singularity.principal_id',$1,true),set_config('singularity.vault_id',$2,true)",
        [Ecto.UUID.load!(document.created_by_principal_id), Ecto.UUID.load!(document.vault_id)]
      )

      query!(MigrationRepo, "SELECT content.claim_document_extraction($1,0,$2,'plain',1)", [
        document.resource_version_id,
        job
      ])

      query!(MigrationRepo, "SELECT content.fail_document_extraction($1,$2,1,$3,$4)", [
        document.resource_version_id,
        job,
        outcome,
        reason
      ])
    end)
  end

  defp grant_runtime!(source) do
    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "UPDATE core.vaults SET locked=false WHERE id=$1", [source.vault_id])

      query!(
        MigrationRepo,
        "INSERT INTO core.capabilities(id,name) VALUES($1,'asset.read') ON CONFLICT(name) DO NOTHING",
        [KnowledgeFixtures.uuid()]
      )

      query!(
        MigrationRepo,
        "INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name='asset.read' ON CONFLICT DO NOTHING",
        [source.principal_id, source.vault_id]
      )
    end)
  end

  defp install_live_object!(source, plaintext, object_dek, domain_key, storage_root) do
    %{rows: [[domain_id, domain_version_id, lookup_digest]]} =
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          """
          SELECT object.key_domain_id,envelope.domain_key_version_id,object.lookup_digest
          FROM content.asset_objects object
          JOIN content.asset_key_envelopes envelope ON envelope.asset_object_id=object.id
          WHERE object.id=$1
          """,
          [Ecto.UUID.dump!(source.object_id)]
        )
      end)

    domain_id = Ecto.UUID.load!(domain_id)
    domain_version_id = Ecto.UUID.load!(domain_version_id)
    lookup_digest_hex = Base.encode16(lookup_digest, case: :lower)

    assert {:ok, ciphertext} =
             ChunkedAEAD.encode(%{
               key: object_dek,
               plaintext: plaintext,
               format_version: Format.format_version(),
               algorithm: Format.algorithm(),
               chunk_size: Format.chunk_size(),
               vault_id: source.vault_id,
               encryption_domain_id: domain_id,
               object_id: source.object_id,
               chunk_index: 0
             })

    storage_context = %{
      root: storage_root,
      vault_namespace: source.vault_id,
      domain_namespace: domain_id,
      lookup_digest: lookup_digest_hex
    }

    assert {:ok, stage} = LocalFilesystemAdapter.stage(storage_context, %{})
    assert :ok = LocalFilesystemAdapter.append_encrypted_chunk(storage_context, stage, ciphertext)

    assert {:ok, %{sealed?: true}} =
             LocalFilesystemAdapter.seal_stage(storage_context, stage, %{})

    assert {:ok, %ObjectRef{}} =
             LocalFilesystemAdapter.finalize(
               storage_context,
               stage,
               %ObjectRef{object_id: source.object_id}
             )

    assert {:ok, %{encoded: wrapped_dek}} =
             KeyWrapper.wrap(domain_key, object_dek, %{
               purpose: :object_dek,
               generation: 1,
               aad: "object:" <> source.object_id
             })

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.asset_objects SET ciphertext_hash=$2,ciphertext_byte_size=$3,plaintext_byte_size=$4 WHERE id=$1",
        [
          Ecto.UUID.dump!(source.object_id),
          :crypto.hash(:sha256, ciphertext),
          byte_size(ciphertext),
          byte_size(plaintext)
        ]
      )

      query!(
        MigrationRepo,
        "UPDATE content.asset_key_envelopes SET wrapped_dek=$2 WHERE asset_object_id=$1 AND key_generation=1",
        [Ecto.UUID.dump!(source.object_id), wrapped_dek]
      )
    end)

    %{domain_id: domain_id, domain_version_id: domain_version_id, lookup_digest: lookup_digest}
  end

  defp live_session(source) do
    %SessionContext{
      account_id: source.account_id,
      authorization_epoch: 0,
      expires_at: DateTime.add(DateTime.utc_now(), 600, :second),
      principal_authorization_epoch: 0,
      principal_id: source.principal_id,
      session_id: source.session_id,
      unlocked?: true,
      vault_authorization_epoch: 0,
      vault_id: source.vault_id
    }
  end

  defp context(source),
    do: %{principal_id: uuid(source.principal_id), owner_scope_id: uuid(source.vault_id)}

  defp scoped(context, callback),
    do:
      ScopedRepo.transact(
        RequestRepo,
        %{principal_id: context.principal_id, vault_id: context.owner_scope_id},
        callback
      )

  defp uuid(<<_::binary-size(16)>> = value), do: Ecto.UUID.load!(value)
  defp uuid(value), do: value
end
