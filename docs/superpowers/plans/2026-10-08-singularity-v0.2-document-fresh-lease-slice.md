# Document Fresh Source Lease Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Issue consumer-bound Document extraction leases that always start at zero, authenticate empty originals, and cancel owned readers on every terminal event.

**Architecture:** Extend the existing KeyCustodian and DownloadLease only for the closed `:document_extraction_source` purpose and private `:document_worker_source` mode. Reuse unchanged CustodyReader, WorkerRepo storage binding and object-key authorization. New readers are linked and monitored; completion and cancellation await their death before delivering a result.

**Tech Stack:** Elixir/OTP GenServer, ExUnit, PostgreSQL WorkerRepo, existing ChunkedAEAD and filesystem storage.

---

## Authority and scope

Approved design: `docs/superpowers/specs/2026-10-08-singularity-v0.2-document-source-replay-design.md`.
This is the bounded shared Runtime portion of Phase 2 Tasks 8/12, after accepted worker adapter/SQL commit `0cc65c0`.
Checkout: `/home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-2-import-extraction`.
Branch: `codex/v0.2-phase-2-import-extraction`; initial clean baseline `bde0101e8883636e9beac545b9038d3c56d01b1f`.

Owned modifications:
- `apps/singularity_runtime/lib/singularity/runtime/key_custodian.ex`: closed issuance, trusted session selection and private startup values.
- `apps/singularity_runtime/lib/singularity/runtime/download_lease.ex`: fresh sequential mode, empty-source authentication and reader lifecycle.
- `apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs`: new contracts plus real retained object/session/event/WorkerRepo fixtures.
- `apps/singularity_runtime/test/singularity/runtime/download_lease_test.exs`: deterministic process contracts.
- This plan.

No commits, pushes, migrations, grants, key/capability/Vault/unlock changes, storage/CustodyReader/KeyLease/v4 changes, generic progress changes or extraction wiring. Existing assertions remain intact. Parent owns other documentation.

Nonempty chunk reads authenticate original plaintext data records; they do not authenticate the container final record. Whole worker claim/outcome, death/restart, deadline and waiting/running progress integration remain in the later Runtime/storage slices. This slice cannot establish those acceptance claims.

## Task 1: Characterize existing behavior and write contracts

- [x] Inspect approved design, exact owned files, TDD anti-patterns, Elixir/OTP and writing-plans skills.
- [x] Run focused unit baseline before test edits.

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/download_lease_test.exs apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs
```

Actual baseline: seed 47244, 0.3 seconds, 5 reported, 1 excluded, 4 executed, 0 failures. Exact UTC start timestamp was not recorded.

- [x] Run initial focused integration baseline before test edits.

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/download_lease_test.exs apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs
```

Actual baseline: seed 184465, 0.4 seconds, 5 reported, 4 excluded, 1 executed, 0 failures. Isolated database `singularity_test_80c24269853bf36322f508ff`; alias completed its automatic cleanup. Exact UTC start timestamp was not recorded.

- [x] Add the exact executable tests below. This is the complete test diff already written; apply only when reconstructing from the recorded baseline.

```diff
diff --git i/apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs w/apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs
index 06d0aa3..b789037 100644
--- i/apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs
+++ w/apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs
@@ -46,6 +46,121 @@ defmodule Singularity.Runtime.DocumentCustodyTest do
     def utc_now(%{now: now}), do: now
   end
-
+
+  defmodule FreshReader do
+    def load_object_key(context, binding, hierarchy) do
+      send(context.owner, {:fresh_document_key, binding, hierarchy})
+
+      {:ok,
+       %{
+         object_dek: :binary.copy(<<1>>, 32),
+         reader_binding: Map.put(binding, :plaintext_byte_size, 6)
+       }}
+    end
+
+    def load_checkpoint(_context, _binding), do: raise("fresh source must not load checkpoints")
+    def persist_checkpoint(_, _, _, _), do: raise("fresh source must not persist checkpoints")
+    def read_chunk(context, binding, index), do: Reader.read_chunk(context, binding, index)
+    def read_range(context, binding, range), do: Reader.read_range(context, binding, range)
+  end
+
+  test "fresh extraction selects a session, preserves exact storage binding and restarts at zero" do
+    {custodian, request, session} = fresh_custodian()
+    assert {:error, :waiting_for_unlock} = KeyCustodian.lease(custodian, request)
+    assert :ok = activate_session(custodian, session)
+
+    for _attempt <- 1..2 do
+      assert {:ok, lease} = KeyCustodian.lease(custodian, request)
+      assert {:ok, "source"} = DownloadLease.read_document_chunk(lease, 0)
+      assert_receive {:fresh_document_key, binding, _hierarchy}
+
+      assert binding ==
+               request |> Map.delete(:purpose) |> Map.put(:session_id, session.session_id)
+
+      assert_receive {:read_document_chunk, ^binding, 0}
+      assert :ok = DownloadLease.revoke(lease)
+    end
+  end
+
+  test "fresh extraction rejects every caller-selected startup field and malformed binding" do
+    {custodian, request, session} = fresh_custodian()
+    assert :ok = activate_session(custodian, session)
+
+    for {key, value} <- [
+          {:session_id, session.session_id},
+          {:mode, :document_worker_source},
+          {:index, 0},
+          {:range, :all},
+          {:checkpoint, %{}},
+          {:consumer_pid, self()},
+          {"job_id", request.job_id},
+          {:unexpected, true}
+        ] do
+      assert {:error, %Error{code: :invalid}} =
+               KeyCustodian.lease(custodian, Map.put(request, key, value))
+    end
+
+    for key <- Map.keys(request) do
+      assert {:error, %Error{code: :invalid}} =
+               KeyCustodian.lease(custodian, Map.delete(request, key))
+    end
+
+    for {key, value} <- [
+          {:access, :request},
+          {:access, :forged},
+          {:required_capability, "asset.write"},
+          {:object_generation, 0},
+          {:object_generation, -1},
+          {:object_generation, 1.0},
+          {:principal_authorization_epoch, -1},
+          {:principal_authorization_epoch, 9_223_372_036_854_775_808},
+          {:vault_authorization_epoch, 9_223_372_036_854_775_808},
+          {:object_generation, 9_223_372_036_854_775_808},
+          {:vault_authorization_epoch, "0"}
+        ] do
+      assert {:error, %Error{code: :invalid}} =
+               KeyCustodian.lease(custodian, Map.put(request, key, value))
+    end
+
+    for key <- [:job_id, :resource_version_id, :object_id, :vault_id, :principal_id],
+        value <- ["not-a-uuid", String.upcase(request[key]), Ecto.UUID.dump!(request[key])] do
+      assert {:error, %Error{code: :invalid}} =
+               KeyCustodian.lease(custodian, Map.put(request, key, value))
+    end
+
+    plausible_generic = Map.put(request, :session_id, session.session_id)
+
+    for malformed <- [
+          %{plausible_generic | purpose: "document_extraction_source"},
+          plausible_generic
+          |> Map.delete(:purpose)
+          |> Map.put("purpose", :document_extraction_source),
+          plausible_generic
+          |> Map.delete(:purpose)
+          |> Map.put("purpose", "document_extraction_source"),
+          plausible_generic
+          |> Map.put(:purpose, :download)
+          |> Map.put("purpose", "document_extraction_source")
+        ] do
+      assert {:error, %Error{code: :invalid}} = KeyCustodian.lease(custodian, malformed)
+    end
+
+    refute_received {:fresh_document_key, _, _}
+  end
+
+  test "fresh extraction binds the consumer to issuance and registers for session revocation" do
+    {custodian, request, session} = fresh_custodian()
+    assert :ok = activate_session(custodian, session)
+    assert {:ok, lease} = KeyCustodian.lease(custodian, request)
+
+    assert {:error, %Error{code: :forbidden}} =
+             Task.async(fn -> DownloadLease.read_document_chunk(lease, 0) end) |> Task.await()
+
+    monitor = Process.monitor(lease)
+    assert {:ok, token} = KeyCustodian.begin_revoke(custodian, %{session_id: session.session_id})
+    assert :ok = KeyCustodian.finish_revoke(custodian, token)
+    assert_receive {:DOWN, ^monitor, :process, ^lease, :normal}
+  end
+
   test "worker source lease requires unlock and pins version in checkpoint" do
     {custodian, request} = setup_custodian()
-
+
@@ -127,6 +242,56 @@ defmodule Singularity.Runtime.DocumentCustodyTest do
     {custodian, request}
   end
-
+
+  defp fresh_custodian do
+    request = %{
+      purpose: :document_extraction_source,
+      access: :worker,
+      job_id: Ecto.UUID.generate(),
+      resource_version_id: Ecto.UUID.generate(),
+      vault_id: Ecto.UUID.generate(),
+      principal_id: Ecto.UUID.generate(),
+      required_capability: "asset.read",
+      principal_authorization_epoch: 0,
+      vault_authorization_epoch: 0,
+      object_id: Ecto.UUID.generate(),
+      object_generation: 1
+    }
+
+    session = %{
+      session_id: Ecto.UUID.generate(),
+      principal_id: request.principal_id,
+      vault_id: request.vault_id,
+      principal_authorization_epoch: 0,
+      vault_authorization_epoch: 0,
+      expires_at: DateTime.add(@now, 300, :second),
+      vault_key: :binary.copy(<<1>>, 32)
+    }
+
+    supervisor = start_supervised!({KeyLeaseSupervisor, name: nil}, id: make_ref())
+
+    custodian =
+      start_supervised!(
+        {KeyCustodian,
+         %{
+           authorization: Authorization,
+           clock: Clock,
+           context: %{owner: self(), now: @now},
+           idle_lock: {IdleLock, self()},
+           key_reader: FreshReader,
+           lease_supervisor: supervisor,
+           object_key_loader: FreshReader
+         }},
+        id: make_ref()
+      )
+
+    {custodian, request, session}
+  end
+
+  defp activate_session(custodian, session) do
+    with {:ok, pending} <- KeyCustodian.prepare_unlock(custodian, session),
+         do: KeyCustodian.activate_unlock(custodian, pending)
+  end
+
   defp unlock(custodian) do
     session = %{
       session_id: "session-1",
@@ -151,6 +316,434 @@ defmodule Singularity.Runtime.DocumentCustodyTest do
   end
 end
-
+
+defmodule Singularity.Runtime.DocumentFreshCustodyIntegrationTest do
+  use Singularity.Storage.DataCase, async: false
+
+  @moduletag :integration
+  @moduletag :tmp_dir
+
+  alias Singularity.Core.{Error, ObjectRef}
+
+  alias Singularity.Runtime.{
+    CustodyReader,
+    DownloadLease,
+    KeyCustodian,
+    KeyLease,
+    KeyLeaseSupervisor
+  }
+
+  alias Singularity.Storage.{
+    Fixtures,
+    KnowledgeFixtures,
+    LocalFilesystemAdapter,
+    MigrationRepo,
+    ScopedRepo
+  }
+
+  alias Singularity.Storage.Crypto.{ChunkedAEAD, Format, KeyWrapper}
+  alias Singularity.Storage.Local.PathGuard
+  alias Singularity.Storage.Postgres.CustodyRepository
+
+  setup context do
+    plaintext = Map.get(context, :plaintext, "")
+    fixture = source_fixture!(context.tmp_dir, plaintext)
+    supervisor = start_supervised!({KeyLeaseSupervisor, name: nil}, id: make_ref())
+
+    custody_context = %{
+      key_wrapper: KeyWrapper,
+      repo: WorkerRepo,
+      repository_adapter: CustodyRepository,
+      scope: ScopedRepo,
+      storage: %{adapter: LocalFilesystemAdapter, context: %{root: context.tmp_dir}}
+    }
+
+    custodian =
+      start_supervised!(
+        {KeyCustodian,
+         %{
+           authorization: CustodyReader,
+           clock: CustodyReader,
+           context: custody_context,
+           idle_lock: fn _ -> :ok end,
+           key_reader: CustodyReader,
+           object_key_loader: CustodyReader,
+           lease_supervisor: supervisor
+         }},
+        id: make_ref()
+      )
+
+    session =
+      Map.merge(
+        Map.take(fixture, [
+          :session_id,
+          :principal_id,
+          :vault_id,
+          :key_domain_id,
+          :domain_key_version_id,
+          :domain_key
+        ]),
+        %{
+          principal_authorization_epoch: 0,
+          vault_authorization_epoch: 0,
+          expires_at: DateTime.add(DateTime.utc_now(), 300, :second),
+          domain_key_generation: 1,
+          domain_classification: :private,
+          domain_dedup_key: :crypto.strong_rand_bytes(32),
+          vault_key: :crypto.strong_rand_bytes(32)
+        }
+      )
+
+    assert {:ok, pending} = KeyCustodian.prepare_unlock(custodian, session)
+    assert :ok = KeyCustodian.activate_unlock(custodian, pending)
+    {:ok, fixture: fixture, custodian: custodian, plaintext: plaintext}
+  end
+
+  @tag plaintext: :binary.copy("a", 4_194_304) <> "tail"
+  test "real partial and full fresh reads restart at zero without touching existing v4 progress",
+       context do
+    %{fixture: fixture, custodian: custodian, plaintext: plaintext} = context
+    legacy_request = %{fixture.request | purpose: :document_source}
+    assert {:ok, old_lease} = KeyCustodian.lease(custodian, legacy_request)
+    assert {:ok, first} = KeyLease.read_chunk(old_lease, 0)
+    snapshot = progress(fixture)
+    assert [[4, 0, %{"protocol" => "document_source_v1", "next_chunk_index" => 1}]] = snapshot
+
+    assert {:ok, partial} = KeyCustodian.lease(custodian, fixture.request)
+    assert {:ok, ^first} = DownloadLease.read_document_chunk(partial, 0)
+    assert :ok = DownloadLease.revoke(partial)
+
+    for _ <- 1..2 do
+      assert {:ok, fresh} = KeyCustodian.lease(custodian, fixture.request)
+      assert {:ok, ^first} = DownloadLease.read_document_chunk(fresh, 0)
+      assert {:ok, "tail"} = DownloadLease.read_document_chunk(fresh, 1)
+      assert :crypto.hash(:sha256, first <> "tail") == :crypto.hash(:sha256, plaintext)
+      assert :ok = DownloadLease.revoke(fresh)
+      assert progress(fixture) == snapshot
+    end
+
+    assert {:ok, resumed} = KeyCustodian.lease(custodian, legacy_request)
+    assert {:ok, "tail"} = KeyLease.read_chunk(resumed, 1)
+    assert [[4, 0, %{"next_chunk_index" => 2}]] = progress(fixture)
+    assert :ok = KeyLease.revoke(old_lease)
+    assert :ok = KeyLease.revoke(resumed)
+  end
+
+  test "real empty original authenticates the retained object and creates no progress", %{
+    fixture: fixture,
+    custodian: custodian
+  } do
+    assert progress(fixture) == []
+    assert {:ok, lease} = KeyCustodian.lease(custodian, fixture.request)
+    assert :ok = empty(lease)
+    refute Process.alive?(lease)
+    assert progress(fixture) == []
+  end
+
+  for corruption <- [:missing, :header, :final] do
+    test "real #{corruption} empty original fails storage authentication", %{
+      fixture: fixture,
+      custodian: custodian
+    } do
+      case unquote(corruption) do
+        :missing -> File.rename!(fixture.path, fixture.path <> ".missing")
+        :header -> corrupt_byte!(fixture.path, 0)
+        :final -> corrupt_byte!(fixture.path, File.stat!(fixture.path).size - 1)
+      end
+
+      assert {:ok, lease} = KeyCustodian.lease(custodian, fixture.request)
+      assert {:error, %Error{}} = empty(lease)
+      refute Process.alive?(lease)
+      assert progress(fixture) == []
+    end
+  end
+
+  @tag plaintext: "original"
+  test "real nonempty binding denies empty authentication and forged original bindings", %{
+    fixture: fixture,
+    custodian: custodian
+  } do
+    assert {:ok, lease} = KeyCustodian.lease(custodian, fixture.request)
+    assert {:error, %Error{code: :invalid}} = empty(lease)
+    assert {:ok, "original"} = DownloadLease.read_document_chunk(lease, 0)
+    assert :ok = DownloadLease.revoke(lease)
+
+    for request <- [
+          %{fixture.request | resource_version_id: Ecto.UUID.generate()},
+          %{fixture.request | object_id: Ecto.UUID.generate()},
+          %{fixture.request | object_generation: 2}
+        ] do
+      assert {:error, %Error{code: :forbidden}} = KeyCustodian.lease(custodian, request)
+    end
+
+    assert progress(fixture) == []
+  end
+
+  @tag plaintext: :binary.copy("b", 4_194_304) <> "tail"
+  test "real authority changes fence a subsequent chunk", %{
+    fixture: fixture,
+    custodian: custodian
+  } do
+    assert {:ok, lease} = KeyCustodian.lease(custodian, fixture.request)
+    assert {:ok, _first} = DownloadLease.read_document_chunk(lease, 0)
+
+    Fixtures.with_owner(fn ->
+      query!(MigrationRepo, "UPDATE identity.principals SET authorization_epoch=1 WHERE id=$1", [
+        Ecto.UUID.dump!(fixture.principal_id)
+      ])
+    end)
+
+    assert {:error, %Error{code: :forbidden}} = DownloadLease.read_document_chunk(lease, 1)
+    refute Process.alive?(lease)
+  end
+
+  @tag plaintext: "retained original"
+  test "source Asset deletion retains bytes while Document deletion fences pending reads", %{
+    fixture: fixture,
+    custodian: custodian
+  } do
+    Fixtures.with_owner(fn ->
+      query!(
+        MigrationRepo,
+        "UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id=$1",
+        [fixture.source.resource_id]
+      )
+    end)
+
+    assert {:ok, lease} = KeyCustodian.lease(custodian, fixture.request)
+    assert {:ok, "retained original"} = DownloadLease.read_document_chunk(lease, 0)
+    assert :ok = DownloadLease.revoke(lease)
+
+    Fixtures.with_owner(fn ->
+      query!(
+        MigrationRepo,
+        "UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id=$1",
+        [fixture.document.resource_id]
+      )
+    end)
+
+    assert {:error, %Error{code: :forbidden}} = KeyCustodian.lease(custodian, fixture.request)
+  end
+
+  defp source_fixture!(root, plaintext) do
+    %{one: source} = Fixtures.two_vaults!()
+
+    ids =
+      Map.new(
+        [:object_id, :key_domain_id, :domain_key_version_id, :vault_key_version_id, :job_id],
+        &{&1, Ecto.UUID.generate()}
+      )
+
+    vault_id = Ecto.UUID.load!(source.vault_id)
+    domain_key = :crypto.strong_rand_bytes(32)
+    dek = :crypto.strong_rand_bytes(32)
+    lookup_digest = :crypto.strong_rand_bytes(32)
+
+    {:ok, ciphertext} =
+      ChunkedAEAD.encode(%{
+        key: dek,
+        plaintext: plaintext,
+        chunk_index: 0,
+        format_version: Format.format_version(),
+        algorithm: Format.algorithm(),
+        chunk_size: Format.chunk_size(),
+        vault_id: vault_id,
+        encryption_domain_id: ids.key_domain_id,
+        object_id: ids.object_id
+      })
+
+    storage = %{
+      root: root,
+      vault_namespace: vault_id,
+      domain_namespace: ids.key_domain_id,
+      lookup_digest: Base.encode16(lookup_digest, case: :lower)
+    }
+
+    assert {:ok, stage} = LocalFilesystemAdapter.stage(storage, %{})
+    assert :ok = LocalFilesystemAdapter.append_encrypted_chunk(storage, stage, ciphertext)
+    assert {:ok, %{sealed?: true}} = LocalFilesystemAdapter.seal_stage(storage, stage, %{})
+    object_ref = %ObjectRef{object_id: ids.object_id}
+    assert {:ok, ^object_ref} = LocalFilesystemAdapter.finalize(storage, stage, object_ref)
+
+    assert {:ok, path} =
+             PathGuard.object_path(root, vault_id, ids.key_domain_id, storage.lookup_digest)
+
+    assert {:ok, wrapper} =
+             KeyWrapper.wrap(domain_key, dek, %{
+               purpose: :object_dek,
+               generation: 1,
+               aad: "object:" <> ids.object_id
+             })
+
+    digest = :crypto.hash(:sha256, plaintext)
+
+    Fixtures.with_owner(fn ->
+      query!(MigrationRepo, "UPDATE core.vaults SET locked=false WHERE id=$1", [source.vault_id])
+
+      query!(
+        MigrationRepo,
+        "INSERT INTO core.capabilities(id,name) VALUES($1,'asset.read') ON CONFLICT(name) DO NOTHING",
+        [KnowledgeFixtures.uuid()]
+      )
+
+      query!(
+        MigrationRepo,
+        "INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name='asset.read'",
+        [source.principal_id, source.vault_id]
+      )
+
+      query!(
+        MigrationRepo,
+        "INSERT INTO core.vault_key_versions(id,vault_id,generation,state,algorithm,activated_at) VALUES($1,$2,1,'active','aes_256_gcm',CURRENT_TIMESTAMP)",
+        [Ecto.UUID.dump!(ids.vault_key_version_id), source.vault_id]
+      )
+
+      query!(
+        MigrationRepo,
+        "INSERT INTO core.key_domains(id,vault_id,classification,kind,state) VALUES($1,$2,'private','content','active')",
+        [Ecto.UUID.dump!(ids.key_domain_id), source.vault_id]
+      )
+
+      query!(
+        MigrationRepo,
+        "INSERT INTO core.domain_key_versions(id,vault_id,key_domain_id,vault_key_version_id,generation,state,algorithm,wrapped_key) VALUES($1,$2,$3,$4,1,'active','aes_256_gcm',$5)",
+        [
+          Ecto.UUID.dump!(ids.domain_key_version_id),
+          source.vault_id,
+          Ecto.UUID.dump!(ids.key_domain_id),
+          Ecto.UUID.dump!(ids.vault_key_version_id),
+          :crypto.strong_rand_bytes(60)
+        ]
+      )
+
+      query!(
+        MigrationRepo,
+        "INSERT INTO content.asset_objects(id,vault_id,key_domain_id,classification,lookup_digest,ciphertext_hash,plaintext_byte_size,ciphertext_byte_size,storage_ref,format_version,lifecycle) VALUES($1,$2,$3,'private',$4,$5,$6,$7,$8,1,'available')",
+        [
+          Ecto.UUID.dump!(ids.object_id),
+          source.vault_id,
+          Ecto.UUID.dump!(ids.key_domain_id),
+          lookup_digest,
+          :crypto.hash(:sha256, ciphertext),
+          byte_size(plaintext),
+          byte_size(ciphertext),
+          ids.object_id
+        ]
+      )
+
+      query!(
+        MigrationRepo,
+        "INSERT INTO content.asset_key_envelopes(id,vault_id,asset_object_id,domain_key_version_id,key_domain_id,classification,algorithm,key_generation,wrapped_dek) VALUES($1,$2,$3,$4,$5,'private','aes_256_gcm',1,$6)",
+        [
+          KnowledgeFixtures.uuid(),
+          source.vault_id,
+          Ecto.UUID.dump!(ids.object_id),
+          Ecto.UUID.dump!(ids.domain_key_version_id),
+          Ecto.UUID.dump!(ids.key_domain_id),
+          wrapper.encoded
+        ]
+      )
+
+      query!(
+        MigrationRepo,
+        "UPDATE content.assets SET state='available',asset_object_id=$1 WHERE id=$2",
+        [Ecto.UUID.dump!(ids.object_id), source.asset_id]
+      )
+
+      query!(
+        MigrationRepo,
+        "INSERT INTO content.resource_assets(resource_version_id,asset_id,vault_id,classification) VALUES($1,$2,$3,'private')",
+        [source.resource_version_id, source.asset_id, source.vault_id]
+      )
+    end)
+
+    source =
+      Map.merge(source, %{
+        object_id: Ecto.UUID.dump!(ids.object_id),
+        digest: digest,
+        byte_size: byte_size(plaintext)
+      })
+
+    document = KnowledgeFixtures.document!(source)
+
+    Fixtures.with_owner(fn ->
+      query!(
+        MigrationRepo,
+        "INSERT INTO core.outbox_events(id,event_type,idempotency_key,vault_id,principal_id,required_capability,principal_authorization_epoch,vault_authorization_epoch,classification,correlation_id,expected_entity_revision,envelope_version,payload,occurred_at) VALUES($1,'document.extraction_requested',$2,$3,$4,'asset.read',0,0,'private',$1,0,1,$5::text::jsonb,CURRENT_TIMESTAMP)",
+        [
+          Ecto.UUID.dump!(ids.job_id),
+          "document-extraction:" <> Ecto.UUID.load!(document.resource_version_id),
+          source.vault_id,
+          source.principal_id,
+          JSON.encode!(%{
+            "resource_id" => Ecto.UUID.load!(document.resource_id),
+            "resource_version_id" => Ecto.UUID.load!(document.resource_version_id)
+          })
+        ]
+      )
+
+      query!(
+        MigrationRepo,
+        "INSERT INTO jobs.job_submissions(id,vault_id,outbox_event_id,classification,idempotency_key,job_type) VALUES($1,$2,$1,'private',$3,'document_extract')",
+        [Ecto.UUID.dump!(ids.job_id), source.vault_id, "document-extract:" <> ids.job_id]
+      )
+    end)
+
+    request = %{
+      purpose: :document_extraction_source,
+      access: :worker,
+      job_id: ids.job_id,
+      resource_version_id: Ecto.UUID.load!(document.resource_version_id),
+      vault_id: vault_id,
+      principal_id: Ecto.UUID.load!(source.principal_id),
+      required_capability: "asset.read",
+      principal_authorization_epoch: 0,
+      vault_authorization_epoch: 0,
+      object_id: ids.object_id,
+      object_generation: 1
+    }
+
+    Map.merge(ids, %{
+      source: source,
+      document: document,
+      request: request,
+      path: path,
+      vault_id: vault_id,
+      principal_id: request.principal_id,
+      session_id: Ecto.UUID.load!(source.session_id),
+      domain_key: domain_key
+    })
+  end
+
+  defp progress(fixture) do
+    ScopedRepo.transact(
+      WorkerRepo,
+      %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
+      fn repo ->
+        query!(
+          repo,
+          "SELECT checkpoint_version,processing_revision,checkpoint FROM jobs.job_progress WHERE submission_id=$1",
+          [Ecto.UUID.dump!(fixture.job_id)]
+        ).rows
+      end
+    )
+  end
+
+  defp corrupt_byte!(path, offset) do
+    File.chmod!(path, 0o600)
+    {:ok, io} = :file.open(path, [:read, :write, :binary])
+
+    try do
+      {:ok, <<byte>>} = :file.pread(io, offset, 1)
+      :ok = :file.pwrite(io, offset, <<Bitwise.bxor(byte, 1)>>)
+      :ok = :file.sync(io)
+    after
+      :ok = :file.close(io)
+    end
+  end
+
+  defp empty(lease), do: apply(DownloadLease, :authenticate_empty_document_source, [lease])
+end
+
 defmodule Singularity.Runtime.DocumentCustodyPermissionTest do
   use ExUnit.Case, async: false
   @moduletag :integration
diff --git i/apps/singularity_runtime/test/singularity/runtime/download_lease_test.exs w/apps/singularity_runtime/test/singularity/runtime/download_lease_test.exs
index 9354ce9..58f5708 100644
--- i/apps/singularity_runtime/test/singularity/runtime/download_lease_test.exs
+++ w/apps/singularity_runtime/test/singularity/runtime/download_lease_test.exs
@@ -179,3 +179,238 @@ defmodule Singularity.Runtime.DownloadLeaseTest do
     ]
   end
 end
+
+defmodule Singularity.Runtime.DocumentFreshDownloadLeaseTest do
+  use ExUnit.Case, async: true
+
+  alias Singularity.Core.Error
+  alias Singularity.Runtime.DownloadLease
+
+  defmodule Clock do
+    def utc_now(%{clock: clock}), do: Agent.get(clock, & &1)
+  end
+
+  defmodule Authorization do
+    def revalidate(context, _binding) do
+      send(context.owner, :fresh_revalidated)
+      Agent.get(context.authority, & &1)
+    end
+  end
+
+  defmodule Reader do
+    def read_chunk(context, _binding, index), do: read(context, {:chunk, index})
+    def read_range(context, _binding, range), do: read(context, range)
+
+    defp read(context, range) do
+      send(context.owner, {:fresh_reader, self(), range})
+
+      if context.block? do
+        receive do
+          :release -> context.result
+        end
+      else
+        context.result
+      end
+    end
+  end
+
+  setup do
+    clock = start_supervised!({Agent, fn -> DateTime.utc_now() end}, id: make_ref())
+    authority = start_supervised!({Agent, fn -> :ok end}, id: make_ref())
+
+    custodian =
+      spawn(fn ->
+        receive do
+          :stop -> :ok
+        end
+      end)
+
+    on_exit(fn -> Process.exit(custodian, :kill) end)
+    {:ok, clock: clock, authority: authority, custodian: custodian}
+  end
+
+  test "fresh worker reads are consumer-bound, sequential and never public ranges", context do
+    lease = fresh_lease(context)
+    assert {:error, %Error{code: :invalid}} = DownloadLease.read(lease, :all)
+    assert {:error, %Error{code: :invalid}} = DownloadLease.read(lease, 0..3)
+    assert {:error, %Error{code: :invalid}} = DownloadLease.read_document_chunk(lease, -1)
+    assert {:error, %Error{code: :conflict}} = DownloadLease.read_document_chunk(lease, 1)
+
+    assert {:error, %Error{code: :forbidden}} =
+             Task.async(fn -> DownloadLease.read_document_chunk(lease, 0) end) |> Task.await()
+
+    assert {:ok, "source"} = DownloadLease.read_document_chunk(lease, 0)
+    assert {:error, %Error{code: :conflict}} = DownloadLease.read_document_chunk(lease, 0)
+    assert {:ok, "source"} = DownloadLease.read_document_chunk(lease, 1)
+    assert :ok = DownloadLease.revoke(lease)
+    refute Process.alive?(lease)
+  end
+
+  test "concurrent requests cannot read ahead or authenticate empty while a read is pending",
+       context do
+    lease = fresh_lease(context, block?: true)
+    request = :gen_server.send_request(lease, {:read_document_chunk, 0})
+    assert_receive {:fresh_reader, reader, {:chunk, 0}}
+    assert {:error, %Error{code: :conflict}} = DownloadLease.read_document_chunk(lease, 0)
+    assert {:error, %Error{code: :conflict}} = empty(lease)
+    assert :ok = DownloadLease.revoke(lease)
+    assert {:reply, {:error, :waiting_for_unlock}} = :gen_server.wait_response(request, 1_000)
+    refute Process.alive?(reader)
+  end
+
+  test "trusted empty source authenticates a full storage read and consumes the lease", context do
+    lease = fresh_lease(context, size: 0, result: {:ok, ""}, block?: true)
+    monitor = Process.monitor(lease)
+    request = :gen_server.send_request(lease, :authenticate_empty_document_source)
+    assert_receive {:fresh_reader, reader, :all}
+    reader_monitor = Process.monitor(reader)
+    send(reader, :release)
+    assert_receive {:DOWN, ^reader_monitor, :process, ^reader, _reason}
+    assert {:reply, :ok} = :gen_server.wait_response(request, 1_000)
+    refute Process.alive?(reader)
+    assert_receive :fresh_revalidated
+    assert_receive :fresh_revalidated
+    assert_receive {:DOWN, ^monitor, :process, ^lease, :normal}
+  end
+
+  test "empty authentication denies nonempty, missing trusted size, old modes and other consumers",
+       context do
+    for opts <- [[size: 1], [size: nil], [mode: nil, size: 0]] do
+      lease = fresh_lease(context, opts)
+      assert {:error, %Error{code: :invalid}} = empty(lease)
+      refute_received {:fresh_reader, _, _}
+    end
+
+    lease = fresh_lease(context, size: 0)
+    assert {:error, %Error{code: :forbidden}} = Task.async(fn -> empty(lease) end) |> Task.await()
+    refute_received {:fresh_reader, _, _}
+  end
+
+  test "empty authentication rejects unexpected plaintext and sanitizes storage failures",
+       context do
+    content_canary = "empty-source-error-content-canary"
+
+    storage_error =
+      Error.new(:integrity_failure,
+        message: content_canary,
+        details: %{plaintext: content_canary},
+        retryable?: true
+      )
+
+    for {result, retryable?} <- [{{:ok, "unexpected"}, false}, {{:error, storage_error}, true}] do
+      lease = fresh_lease(context, size: 0, result: result)
+      assert {:error, error} = empty(lease)
+
+      assert error == %Error{
+               code: :integrity_failure,
+               message: nil,
+               details: %{},
+               retryable?: retryable?
+             }
+
+      refute Process.alive?(lease)
+    end
+  end
+
+  test "empty authentication is denied after a chunk has been consumed", context do
+    lease = fresh_lease(context, size: 0)
+    assert {:ok, "source"} = DownloadLease.read_document_chunk(lease, 0)
+    assert {:error, %Error{code: :invalid}} = empty(lease)
+  end
+
+  for reason <- [:revoke, :expire, :custodian_death, :consumer_death, :lease_kill, :reader_death] do
+    test "#{reason} terminates the owned reader without late plaintext", context do
+      consumer = spawn(fn -> consumer_loop() end)
+      on_exit(fn -> Process.exit(consumer, :kill) end)
+      lease = fresh_lease(context, block?: true, consumer: consumer)
+      lease_monitor = Process.monitor(lease)
+      send(consumer, {:read, lease, self()})
+      assert_receive {:fresh_reader, reader, {:chunk, 0}}
+      reader_monitor = Process.monitor(reader)
+
+      case unquote(reason) do
+        :revoke -> assert :ok = DownloadLease.revoke(lease)
+        :expire -> send(lease, :expire)
+        :custodian_death -> Process.exit(context.custodian, :kill)
+        :consumer_death -> Process.exit(consumer, :kill)
+        :lease_kill -> Process.exit(lease, :kill)
+        :reader_death -> Process.exit(reader, :kill)
+      end
+
+      assert_receive {:DOWN, ^reader_monitor, :process, ^reader, :killed}
+      assert_receive {:DOWN, ^lease_monitor, :process, ^lease, _reason}
+      refute Process.alive?(reader)
+      send(reader, :release)
+      refute_receive {:consumer_result, {:ok, _plaintext}}
+    end
+  end
+
+  test "expiry and authority changes during a read fence its returned bytes", context do
+    for change <- [:expiry, :authority] do
+      lease = fresh_lease(context, block?: true)
+      request = :gen_server.send_request(lease, {:read_document_chunk, 0})
+      assert_receive {:fresh_reader, reader, {:chunk, 0}}
+
+      case change do
+        :expiry -> Agent.update(context.clock, &DateTime.add(&1, 61, :second))
+        :authority -> Agent.update(context.authority, fn _ -> {:error, Error.new(:forbidden)} end)
+      end
+
+      send(reader, :release)
+      assert {:reply, {:error, _reason}} = :gen_server.wait_response(request, 1_000)
+      refute Process.alive?(lease)
+      Agent.update(context.authority, fn _ -> :ok end)
+    end
+  end
+
+  test "authority rejection before reading releases no source bytes", context do
+    lease = fresh_lease(context)
+    Agent.update(context.authority, fn _ -> {:error, Error.new(:forbidden)} end)
+    assert {:error, %Error{code: :forbidden}} = DownloadLease.read_document_chunk(lease, 0)
+    refute_received {:fresh_reader, _, _}
+  end
+
+  test "expiry before reading cancels the lease without storage access", context do
+    lease = fresh_lease(context)
+    Agent.update(context.clock, &DateTime.add(&1, 61, :second))
+    assert {:error, :waiting_for_unlock} = DownloadLease.read_document_chunk(lease, 0)
+    refute_received {:fresh_reader, _, _}
+  end
+
+  defp fresh_lease(context, opts \\ []) do
+    reader_context = %{
+      owner: self(),
+      clock: context.clock,
+      authority: context.authority,
+      block?: Keyword.get(opts, :block?, false),
+      result: Keyword.get(opts, :result, {:ok, "source"}),
+      object_binding: %{plaintext_byte_size: Keyword.get(opts, :size, 6)}
+    }
+
+    start_supervised!(
+      {DownloadLease,
+       %{
+         authorization: Authorization,
+         binding: %{access: :worker, resource_version_id: "version", session_id: "session"},
+         clock: Clock,
+         context: reader_context,
+         custodian: context.custodian,
+         key_material: :binary.copy(<<1>>, 32),
+         key_reader: Reader,
+         mode: Keyword.get(opts, :mode, :document_worker_source),
+         consumer_pid: Keyword.get(opts, :consumer, self())
+       }},
+      id: make_ref()
+    )
+  end
+
+  defp consumer_loop do
+    receive do
+      {:read, lease, owner} ->
+        send(owner, {:consumer_result, DownloadLease.read_document_chunk(lease, 0)})
+        consumer_loop()
+    end
+  end
+
+  defp empty(lease), do: apply(DownloadLease, :authenticate_empty_document_source, [lease])
+end
```

- [x] Observe missing-feature RED before production changes.

The four blank context lines in the embedded test diff are represented as
equivalent empty-line delete/add pairs so this Markdown has no trailing spaces.
When reconstructing or checking this patch with Git, use `--unidiff-zero` to
permit its shortened leading context. The coordinating agent checked the
embedded diff against the committed tests with this read-only command:

```sh
awk '/^diff --git i\/apps\/singularity_runtime\/test/{capture=1} capture && /^```$/{exit} capture{print}' docs/superpowers/plans/2026-10-08-singularity-v0.2-document-fresh-lease-slice.md | git apply --reverse --check --unidiff-zero -
```

Initial unit RED seed 236044: 1.6 seconds, 21 reported, 1 excluded, 20 executed, 16 new failures and 4 existing passes.
Current expanded unit RED seed 640789: 3.2 seconds, 31 reported, 9 excluded, 22 executed, 18 new failures and 4 existing passes.
Failures demonstrate missing purpose, missing empty API, permitted public full reads and generic fallback loading a checkpoint for injected session. The test double deliberately raises if a fresh path reaches checkpoint loading.

Real integration RED seed 505319: 9.1 seconds, 29 reported, 20 excluded, 9 executed, 8 new failures and 1 existing permission pass. Every new failure is fresh-purpose `:invalid`. The partial replay test first successfully authenticated the first chunk of a real source >4 MiB under WorkerRepo and persisted a v4 index-one checkpoint. That first chunk is exactly 4 MiB.
Isolated database `singularity_test_e4b7a2826424612d1e41cd6d`; command exited and cleanup completed.
The current tests add two unit contracts after that integration invocation; they do not change its eight integration cases.

Test-fixture corrections before production: separate module tags; correct existing PathGuard namespace; include the established required domain dedup key in trusted activation; use the direct callback return from ScopedRepo.transact. Earlier fixture-only runs were not claimed as missing-feature RED. The outbox idempotency key now exactly matches `document-extraction:<document-version-uuid>`.

At this RED checkpoint Sol production repair rounds were 0 and no production edits had occurred.

## Task 2: Parent personally reviews the complete production patch

- [x] Parent checks spec coverage, exact types/field names, no placeholders, complete executable code, preserved old-mode behavior and reader ownership.
- [x] Parent sends explicit GO before applying any production change. Parent personally reviewed the complete plan against the amendment and baseline APIs, then approved the bounded patch.

The following is the exact production patch. All helper functions used by it are defined in the patch or exist at baseline. Private options never enter SQL bindings or checkpoints. Canonical UUID validation is bounded to the new purpose; old fixtures and old purposes keep their existing validation.

```diff
*** Begin Patch
*** Update File: /home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-2-import-extraction/apps/singularity_runtime/lib/singularity/runtime/key_custodian.ex
@@
-  def handle_call({:lease, %{purpose: :download} = request}, _from, state) do
+  def handle_call({:lease, %{"purpose" => purpose}}, _from, state)
+      when purpose in [:document_extraction_source, "document_extraction_source"],
+      do: {:reply, {:error, Error.new(:invalid)}, state}
+
+  def handle_call({:lease, %{purpose: "document_extraction_source"}}, _from, state),
+    do: {:reply, {:error, Error.new(:invalid)}, state}
+
+  def handle_call(
+        {:lease, %{purpose: :document_extraction_source, access: :worker} = request},
+        {consumer, _tag},
+        state
+      ) do
+    with :ok <- validate_document_extraction_request(request),
+         %{} = session <- metadata_session(state, request),
+         binding =
+           request
+           |> Map.take(@document_worker_fields)
+           |> Map.put(:session_id, session.session_id),
+         {:ok, %{object_dek: object_dek, reader_binding: reader_binding}} <-
+           object_key(state, session, binding),
+         reader_context = Map.put(state.context, :object_binding, reader_binding),
+         {:ok, lease} <-
+           start_download_lease(state, binding, object_dek, reader_context, %{
+             mode: :document_worker_source,
+             consumer_pid: consumer
+           }) do
+      {:reply, {:ok, lease}, register_lease(state, session.session_id, lease)}
+    else
+      nil -> {:reply, {:error, :waiting_for_unlock}, state}
+      {:error, :waiting_for_unlock} -> {:reply, {:error, :waiting_for_unlock}, state}
+      {:error, %Error{}} = error -> {:reply, error, state}
+      {:error, _reason} -> {:reply, {:error, Error.new(:storage_unavailable)}, state}
+    end
+  end
+
+  def handle_call({:lease, %{purpose: :document_extraction_source}}, _from, state),
+    do: {:reply, {:error, Error.new(:invalid)}, state}
+
+  def handle_call({:lease, %{purpose: :download} = request}, _from, state) do
@@
-         reader_context
+         reader_context,
+         private_options \\ %{}
        ) do
-    KeyLeaseSupervisor.start_download_lease(state.lease_supervisor, %{
+    options = %{
       authorization: state.adapters.authorization,
       binding: request,
       clock: state.adapters.clock,
       context: reader_context,
       custodian: self(),
       key_material: object_dek,
       key_reader: state.adapters.key_reader
-    })
+    }
+
+    KeyLeaseSupervisor.start_download_lease(
+      state.lease_supervisor,
+      Map.merge(options, private_options)
+    )
@@
-  defp validate_document_request(request, fields) do
+  defp validate_document_extraction_request(request) do
+    maximum = 9_223_372_036_854_775_807
+
+    with :ok <- validate_document_request(request, @document_worker_fields),
+         true <-
+           Enum.all?(
+             [:job_id, :resource_version_id, :vault_id, :principal_id, :object_id],
+             fn field ->
+               value = Map.fetch!(request, field)
+               is_binary(value) and byte_size(value) == 36 and
+                 match?({:ok, ^value}, Ecto.UUID.cast(value))
+             end
+           ),
+         true <- request.principal_authorization_epoch <= maximum,
+         true <- request.vault_authorization_epoch <= maximum,
+         true <- request.object_generation <= maximum do
+      :ok
+    else
+      _invalid -> {:error, Error.new(:invalid)}
+    end
+  end
+
+  defp validate_document_request(request, fields) do
*** Update File: /home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-2-import-extraction/apps/singularity_runtime/lib/singularity/runtime/download_lease.ex
@@
   def read_document_chunk(_lease, _index), do: {:error, Error.new(:invalid)}
+
+  @spec authenticate_empty_document_source(pid()) ::
+          :ok | {:error, :waiting_for_unlock | Error.t()}
+  def authenticate_empty_document_source(lease) when is_pid(lease) do
+    GenServer.call(lease, :authenticate_empty_document_source, :infinity)
+  catch
+    :exit, _reason -> unavailable()
+  end
+
+  def authenticate_empty_document_source(_lease), do: {:error, Error.new(:invalid)}
@@
-      })
+      } = options)
       when is_map(binding) and is_pid(custodian) do
+    mode = Map.get(options, :mode)
+    consumer = Map.get(options, :consumer_pid)
+
+    consumer_monitor =
+      if mode == :document_worker_source do
+        Process.flag(:trap_exit, true)
+        Process.monitor(consumer)
+      end
+
@@
        key_reader: key_reader,
+       mode: mode,
+       consumer_pid: consumer,
+       consumer_monitor: consumer_monitor,
@@
   @impl true
+  def handle_call({:read, _range}, _from, %{mode: :document_worker_source} = state),
+    do: {:reply, {:error, Error.new(:invalid)}, state}
+
   def handle_call({:read, _range}, _from, %{pending: pending} = state)
@@
-  def handle_call({:read_document_chunk, _index}, _from, %{pending: pending} = state)
+  def handle_call(
+        {:read_document_chunk, _index},
+        {caller, _tag},
+        %{mode: :document_worker_source, consumer_pid: consumer} = state
+      )
+      when caller != consumer,
+      do: {:reply, {:error, Error.new(:forbidden)}, state}
+
+  def handle_call({:read_document_chunk, _index}, _from, %{pending: pending} = state)
@@
   def handle_call(
+        {:read_document_chunk, index},
+        from,
+        %{mode: :document_worker_source} = state
+      ) do
+    with :active <- lease_status(state),
+         true <- is_integer(index) and index >= 0 and index == state.next_index do
+      {:noreply, start_read(state, from, {:document_chunk, index})}
+    else
+      :revoked -> {:stop, :normal, {:error, :waiting_for_unlock}, revoke_state(state)}
+      :expired -> {:stop, :normal, {:error, :waiting_for_unlock}, revoke_state(state)}
+      false -> {:reply, {:error, Error.new(:conflict)}, state}
+    end
+  end
+
+  def handle_call(
         {:read_document_chunk, index},
@@
   def handle_call({:read_document_chunk, _index}, _from, state),
     do: {:reply, {:error, Error.new(:invalid)}, state}
+
+  def handle_call(
+        :authenticate_empty_document_source,
+        {caller, _tag},
+        %{mode: :document_worker_source, consumer_pid: consumer} = state
+      )
+      when caller != consumer,
+      do: {:reply, {:error, Error.new(:forbidden)}, state}
+
+  def handle_call(
+        :authenticate_empty_document_source,
+        _from,
+        %{mode: :document_worker_source, pending: pending} = state
+      )
+      when not is_nil(pending),
+      do: {:reply, {:error, Error.new(:conflict)}, state}
+
+  def handle_call(
+        :authenticate_empty_document_source,
+        from,
+        %{
+          mode: :document_worker_source,
+          next_index: 0,
+          reader_context: %{object_binding: %{plaintext_byte_size: 0}}
+        } = state
+      ) do
+    case lease_status(state) do
+      :active -> {:noreply, start_read(state, from, :empty_document_source)}
+      _inactive -> {:stop, :normal, {:error, :waiting_for_unlock}, revoke_state(state)}
+    end
+  end
+
+  def handle_call(:authenticate_empty_document_source, _from, state),
+    do: {:reply, {:error, Error.new(:invalid)}, state}
+
+  def handle_call(:revoke, _from, %{mode: :document_worker_source} = state),
+    do: {:stop, :normal, :ok, revoke_state(state)}
@@
   @impl true
+  def handle_info(
+        {:download_read_complete, operation_ref, result},
+        %{
+          mode: :document_worker_source,
+          pending: %{operation_ref: operation_ref, range: :empty_document_source} = pending
+        } = state
+      ) do
+    finish_reader(state, pending)
+    state = %{state | pending: nil}
+
+    reply =
+      case {lease_status(state), result} do
+        {:active, {:ok, ""}} ->
+          send(state.custodian, {:authorized_activity, state.binding.session_id})
+          :ok
+
+        {:active, {:error, :waiting_for_unlock}} -> {:error, :waiting_for_unlock}
+        {:active, {:error, %Error{} = error}} -> {:error, public_error(error)}
+        {:active, _invalid} -> {:error, Error.new(:integrity_failure)}
+        {_inactive, _result} -> {:error, :waiting_for_unlock}
+      end
+
+    state = revoke_state(state)
+    GenServer.reply(pending.from, reply)
+    {:stop, :normal, state}
+  end
+
   def handle_info(
@@
-    Process.demonitor(pending.monitor, [:flush])
+    finish_reader(state, pending)
@@
-    Process.demonitor(pending.monitor, [:flush])
+    finish_reader(state, pending)
@@
   def handle_info(
+        {:DOWN, monitor, :process, consumer, _reason},
+        %{
+          mode: :document_worker_source,
+          consumer_pid: consumer,
+          consumer_monitor: monitor
+        } = state
+      ),
+      do: {:stop, :normal, revoke_state(state)}
+
+  def handle_info(
         {:DOWN, monitor, :process, custodian, _reason},
@@
-  def handle_info(:expire, state),
+  def handle_info(:expire, %{mode: :document_worker_source} = state),
+    do: {:stop, :normal, revoke_state(state)}
+
+  def handle_info(
+        {:EXIT, reader, _reason},
+        %{mode: :document_worker_source, pending: %{pid: reader}} = state
+      ),
+      do: {:noreply, state}
+
+  def handle_info(:expire, state),
@@
-    {worker, monitor} =
-      spawn_monitor(fn ->
-        result = perform_read(operation)
-        send(lease, {:download_read_complete, operation_ref, result})
-      end)
+    reader = fn ->
+      result = perform_read(operation)
+      send(lease, {:download_read_complete, operation_ref, result})
+    end
+
+    {worker, monitor} =
+      if state.mode == :document_worker_source,
+        do: :erlang.spawn_opt(reader, [:link, :monitor]),
+        else: spawn_monitor(reader)
@@
   defp read_operation(%{range: {:document_chunk, index}} = operation),
     do: operation.key_reader.read_chunk(operation.reader_context, operation.binding, index)
+
+  defp read_operation(%{range: :empty_document_source} = operation),
+    do: operation.key_reader.read_range(operation.reader_context, operation.binding, :all)
@@
-  defp cancel_pending(%{pending: nil} = state), do: state
+  defp finish_reader(%{mode: :document_worker_source}, pending) do
+    Process.exit(pending.pid, :kill)
+
+    receive do
+      {:DOWN, monitor, :process, reader, _reason}
+      when monitor == pending.monitor and reader == pending.pid ->
+        :ok
+    end
+  end
+
+  defp finish_reader(_state, pending), do: Process.demonitor(pending.monitor, [:flush])
+
+  defp cancel_pending(%{pending: nil} = state), do: state
*** End Patch
```

## Task 3: Apply the reviewed implementation and verify

- [x] After GO apply Task 2 patch exactly, then format only the four owned Elixir files.

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix format apps/singularity_runtime/lib/singularity/runtime/key_custodian.ex apps/singularity_runtime/lib/singularity/runtime/download_lease.ex apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs apps/singularity_runtime/test/singularity/runtime/download_lease_test.exs
```

- [x] Run the exact Task 1 unit command. Actual: seed 845083, 3.1 seconds, 31 reported, 9 excluded, 22 executed, zero failures. Command started 2026-10-08T14:53:58Z and exited 0.
- [x] Run the exact Task 1 integration command. Actual: seed 852326, 9.6 seconds, 31 reported, 22 excluded, 9 executed, zero failures. Command started 2026-10-08T14:54:11Z and exited 0. Isolated database `singularity_test_ff4c0e0d19aeee4e5ca97fd9`; alias cleanup completed.
- [x] Review the exact diff and run formatting/diff checks. Both `git diff --check` and the command below exited 0.

```sh
git diff --check
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix format --check-formatted apps/singularity_runtime/lib/singularity/runtime/key_custodian.ex apps/singularity_runtime/lib/singularity/runtime/download_lease.ex apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs apps/singularity_runtime/test/singularity/runtime/download_lease_test.exs
```

- [x] Report actual commands/results, changed files, initial baseline, no Vault feature work, no migrations, remaining later-slice gates and command shutdown.
- [x] Stop this bounded slice when its checks pass. Parent controls independent reviews, wider scoped regressions, phase/release acceptance and later integration. No commit was made.

Production patch applied after explicit parent GO and passed on its initial implementation: cumulative Sol repair rounds 0; no Astra repair counter received. All owned commands have exited. Existing borrowed services were not stopped or restarted. Parent-owned verification documentation was preserved. The four Elixir files plus this plan are the complete task changes; there are no migrations or Vault feature changes.

## Coverage review

Closed purpose: exact atom keys, canonical UUIDs and bounded bigint epochs/generation, malformed purpose/string aliases, injected startup state, selected session and unchanged worker binding.
Fresh behavior: repeated real leases start at zero after partial/full reads; existing v4 persists and resumes independently.
Empty original: trusted zero size, no caller range/size, storage full read with before/after auth, real missing/header/final corruption failures, no progress mutation.
Lifetime: new-mode reader link plus monitor, finish-reader kill/await before delivery, consumer monitoring, revoke/expiry/custodian/reader death and arbitrary lease kill, no late success.
Regression: all pre-existing tests/assertions retained; old request and ordinary Asset reader spawning/completion/revoke behavior remains.
No placeholder code remains. Test-local doubles establish process contracts; real WorkerRepo fixtures establish live custody. Neither claims worker extraction/claim integration.
