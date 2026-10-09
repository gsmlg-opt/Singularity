defmodule Singularity.Runtime.DocumentImportLiveTest do
  use Singularity.Storage.DataCase, async: false

  import ExUnit.CaptureLog

  @moduletag :integration
  @moduletag :tmp_dir

  alias Singularity.Core.{DocumentVersion, ObjectRef}
  alias Singularity.Runtime.Api
  alias Singularity.Runtime.AuthorizationDependencies
  alias Singularity.Runtime.Authorize
  alias Singularity.Runtime.CustodyReader
  alias Singularity.Runtime.DownloadLease
  alias Singularity.Runtime.DTO.Session
  alias Singularity.Runtime.KeyCustodian
  alias Singularity.Runtime.KeyLeaseSupervisor
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.SessionContext
  alias Singularity.Storage.AuthorizationLock
  alias Singularity.Storage.Crypto.{ChunkedAEAD, Format, KeyWrapper}
  alias Singularity.Storage.Documents.PrepareSource
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.KnowledgeFixtures
  alias Singularity.Storage.KnowledgeTestGrants
  alias Singularity.Storage.Local.PathGuard
  alias Singularity.Storage.LocalFilesystemAdapter
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.ObjectLock
  alias Singularity.Storage.Postgres.AssetDeletionRepository
  alias Singularity.Storage.Postgres.AssetRepository
  alias Singularity.Storage.Postgres.AuditSink
  alias Singularity.Storage.Postgres.CustodyRepository
  alias Singularity.Storage.Postgres.DocumentRepository
  alias Singularity.Storage.Postgres.IdentityRepository
  alias Singularity.Storage.ScopedRepo
  alias Singularity.Storage.VaultLock

  test "public import authenticates encrypted Asset bytes and commits one pinned Document",
       %{tmp_dir: tmp_dir} do
    f = live_fixture!(tmp_dir)

    assert %{resources: [], versions: [], documents: [], receipts: [], events: []} =
             import_rows(f.source.vault_id)

    effects_before = effects(f.source.vault_id)

    assert %{
             fragments: [],
             note_search: [],
             asset_search: [[%{"asset_id" => source_asset_id}]],
             submissions: [],
             runners: []
           } = effects_before

    assert source_asset_id == f.source.asset_id

    attrs = %{
      asset_id: f.source.asset_id,
      title: f.title,
      mutation_id: Ecto.UUID.generate()
    }

    with_import_grants(f, fn f ->
      assert {:ok, %DocumentVersion{} = document} = public_import(f, attrs)

      assert document.title == f.title
      assert document.owner_scope_id == f.source.vault_id
      assert document.created_by_principal_id == f.source.principal_id
      assert document.classification == :private
      assert document.state == :pending
      assert document.generation == 0
      assert document.revision == 0
      assert document.source.digest == :crypto.hash(:sha256, f.plaintext)
      assert document.source.byte_size == byte_size(f.plaintext)
      assert document.source.media_type == "text/plain"
      assert document.source.classification == :private
      assert document.source.owner_scope_id == f.source.vault_id
      assert document.source.object_id == f.source.object_id
      assert document.source.asset_id == f.source.asset_id
      assert document.source.resource_id == f.source.resource_id
      assert document.source.resource_version_id == f.source.resource_version_id
      assert document.resource_id != f.source.resource_id
      assert document.resource_version_id != f.source.resource_version_id

      assert_persisted_import(f, attrs, document)
      assert effects(f.source.vault_id) == effects_before
      assert_fresh_request_scope()
    end)
  end

  test "exact replay preserves the import and changed input conflicts without another source read",
       %{tmp_dir: tmp_dir} do
    f = live_fixture!(tmp_dir)
    attrs = import_attrs(f)

    with_import_grants(f, fn f ->
      assert {:ok, document} = public_import(f, %{attrs | title: "  " <> f.title <> "  "})
      rows = import_rows(f.source.vault_id)
      effects_before = effects(f.source.vault_id)
      downloads = download_audits(f.source.vault_id)
      refute downloads == []
      assert_persisted_import(f, attrs, document)

      assert {:ok, ^document} =
               public_import(f, %{
                 "asset_id" => f.source.asset_id,
                 "title" => f.title,
                 "mutation_id" => attrs.mutation_id
               })

      assert {:error, :conflict} =
               public_import(f, %{attrs | title: f.title <> " changed"})

      assert {:error, :conflict} =
               public_import(f, %{attrs | asset_id: Ecto.UUID.generate()})

      assert import_rows(f.source.vault_id) == rows
      assert effects(f.source.vault_id) == effects_before
      assert download_audits(f.source.vault_id) == downloads
    end)
  end

  test "a second valid unlocked owner cannot import the first owner's Asset",
       %{tmp_dir: tmp_dir} do
    first = live_fixture!(Path.join(tmp_dir, "first"))
    second = live_fixture!(Path.join(tmp_dir, "second"))
    second = %{second | key_canaries: first.key_canaries ++ second.key_canaries}
    assert first.source.vault_id != second.source.vault_id
    assert KeyCustodian.unlocked?(first.custodian, first.source.session_id)
    assert KeyCustodian.unlocked?(second.custodian, second.source.session_id)
    first_effects = effects(first.source.vault_id)
    second_effects = effects(second.source.vault_id)
    assert_no_import(first.source.vault_id)
    assert_no_import(second.source.vault_id)

    with_import_grants(second, fn second ->
      assert {:error, :not_found} =
               public_import(second, %{import_attrs(second) | asset_id: first.source.asset_id})

      assert_no_import(first.source.vault_id)
      assert_no_import(second.source.vault_id)
      assert effects(first.source.vault_id) == first_effects
      assert effects(second.source.vault_id) == second_effects
      assert download_audits(first.source.vault_id) == []
      assert download_audits(second.source.vault_id) == []
    end)

    assert_private_surface(second, privacy_rows(first.source.vault_id))
  end

  test "an unlocked session hint cannot import while actual custody is locked",
       %{tmp_dir: tmp_dir} do
    f = live_fixture!(tmp_dir, activate?: false)
    assert f.session.unlocked?
    refute KeyCustodian.unlocked?(f.custodian, f.source.session_id)
    effects_before = effects(f.source.vault_id)
    assert_no_import(f.source.vault_id)

    with_import_grants(f, fn f ->
      assert {:error, :vault_locked} = public_import(f, import_attrs(f))
      assert_no_import(f.source.vault_id)
      assert effects(f.source.vault_id) == effects_before
      assert download_audits(f.source.vault_id) == []
    end)
  end

  test "revoking the live session refuses a stale unlocked import without canonical writes",
       %{tmp_dir: tmp_dir} do
    f = live_fixture!(tmp_dir)
    assert KeyCustodian.unlocked?(f.custodian, f.source.session_id)
    effects_before = effects(f.source.vault_id)
    assert_no_import(f.source.vault_id)

    Fixtures.with_owner(fn ->
      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 "UPDATE identity.sessions SET revoked_at=CURRENT_TIMESTAMP WHERE id=$1",
                 [Ecto.UUID.dump!(f.source.session_id)]
               )
    end)

    with_import_grants(f, fn f ->
      assert {:error, :unauthenticated} = public_import(f, import_attrs(f))
      assert_no_import(f.source.vault_id)
      assert effects(f.source.vault_id) == effects_before
      assert download_audits(f.source.vault_id) == []
    end)
  end

  test "corrupt ciphertext fails real authentication without a partial import",
       %{tmp_dir: tmp_dir} do
    f = live_fixture!(tmp_dir)
    effects_before = effects(f.source.vault_id)
    object_before = source_object(f)
    assert_no_import(f.source.vault_id)

    <<first, rest::binary>> = File.read!(f.object_path)
    File.chmod!(f.object_path, 0o600)
    File.write!(f.object_path, <<Bitwise.bxor(first, 1), rest::binary>>)

    with_import_grants(f, fn f ->
      assert {:error, :integrity_failure} = public_import(f, import_attrs(f))
      assert_no_import(f.source.vault_id)
      assert effects(f.source.vault_id) == effects_before
      assert source_object(f) == object_before
      assert download_audits(f.source.vault_id) == []
    end)
  end

  test "an imported Document replays after actual Asset deletion without rereading the source",
       %{tmp_dir: tmp_dir} do
    f = live_fixture!(tmp_dir)
    grant_asset_write!(f.source)
    attrs = import_attrs(f)

    with_import_grants(f, fn f ->
      assert {:ok, document} = public_import(f, attrs)
      assert_persisted_import(f, attrs, document)
      rows = import_rows(f.source.vault_id)
      downloads = download_audits(f.source.vault_id)
      refute downloads == []
      object_before = source_object(f)
      ciphertext_before = File.read!(f.object_path)

      %{rows: [[state_revision]]} =
        Fixtures.with_owner(fn ->
          query!(MigrationRepo, "SELECT state_revision FROM content.assets WHERE id=$1", [
            Ecto.UUID.dump!(f.source.asset_id)
          ])
        end)

      assert {:ok, %{state: :pending_delete, state_revision: next_revision}} =
               Singularity.Runtime.Assets.Delete.run(
                 f.runtime,
                 f.context,
                 f.source.asset_id,
                 state_revision
               )

      assert next_revision == state_revision + 1
      assert_fresh_request_scope()
      assert_deleted_asset(f)
      effects_after_delete = effects(f.source.vault_id)

      assert %{
               fragments: [],
               note_search: [],
               submissions: [],
               runners: []
             } = effects_after_delete

      assert {:ok, ^document} = public_import(f, attrs)

      assert {:error, :conflict} =
               public_import(f, %{attrs | title: f.title <> " changed"})

      assert {:error, :conflict} =
               public_import(f, %{attrs | asset_id: Ecto.UUID.generate()})

      assert import_rows(f.source.vault_id) == rows
      assert effects(f.source.vault_id) == effects_after_delete
      assert download_audits(f.source.vault_id) == downloads
      assert source_object(f) == object_before
      assert File.read!(f.object_path) == ciphertext_before
      assert_persisted_import(f, attrs, document)
    end)
  end

  defp live_fixture!(tmp_dir, options \\ []) do
    source = KnowledgeFixtures.prepared_source!()
    plaintext = "LIVE_IMPORT_PRIVATE_BYTES_7a42\n"
    title = "LIVE_IMPORT_PRIVATE_TITLE_839c"
    storage_root = Path.expand(tmp_dir)
    on_exit(fn -> File.rm_rf!(storage_root) end)
    object_dek = :crypto.strong_rand_bytes(32)
    domain_key = :crypto.strong_rand_bytes(32)
    domain_dedup_key = :crypto.strong_rand_bytes(32)
    vault_key = :crypto.strong_rand_bytes(32)
    material = install_live_object!(source, plaintext, object_dek, domain_key, storage_root)
    grant_runtime!(source)

    lease_supervisor = start_supervised!({KeyLeaseSupervisor, name: nil}, id: make_ref())

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

    context = live_session(source)

    if Keyword.get(options, :activate?, true) do
      assert {:ok, pending} =
               KeyCustodian.prepare_unlock(custodian, %{
                 account_id: source.account_id,
                 domain_classification: :private,
                 domain_dedup_key: domain_dedup_key,
                 domain_key: domain_key,
                 domain_key_generation: 1,
                 domain_key_version_id: material.domain_version_id,
                 expires_at: context.expires_at,
                 key_domain_id: material.domain_id,
                 principal_authorization_epoch: context.principal_authorization_epoch,
                 principal_id: source.principal_id,
                 session_id: source.session_id,
                 vault_authorization_epoch: context.vault_authorization_epoch,
                 vault_id: source.vault_id,
                 vault_key: vault_key
               })

      assert :ok = KeyCustodian.activate_unlock(custodian, pending)
    end

    assert {:ok, authorization} =
             AuthorizationDependencies.new(%{
               store: IdentityRepository,
               custodian: {KeyCustodian, custodian}
             })

    runtime = %{
      operation_scope: OperationScope,
      request_repo: RequestRepo,
      vault_lock: VaultLock,
      authorization_lock: AuthorizationLock,
      scoped_repo: ScopedRepo,
      authorizer: Authorize,
      authorization: authorization,
      audit: AuditSink,
      assets: AssetRepository,
      asset_deletions: AssetDeletionRepository,
      object_lock: ObjectLock,
      prepare_source: PrepareSource,
      document_repository: DocumentRepository,
      custodian: {KeyCustodian, custodian},
      authenticated_reader: DownloadLease,
      fingerprint_secret: :binary.copy(<<0x6D>>, 32)
    }

    config = %{
      import_document: fn session, attrs ->
        Singularity.Runtime.Documents.Import.run(runtime, session, attrs)
      end
    }

    assert {:ok, object_path} =
             PathGuard.object_path(
               storage_root,
               source.vault_id,
               material.domain_id,
               Base.encode16(material.lookup_digest, case: :lower)
             )

    %{
      source: source,
      plaintext: plaintext,
      title: title,
      config: config,
      runtime: runtime,
      session: struct(Session, Map.from_struct(context)),
      context: context,
      custodian: custodian,
      object_path: object_path,
      key_canaries: [domain_key, object_dek, domain_dedup_key, vault_key]
    }
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
      assert %{num_rows: 1} =
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

      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 "UPDATE content.asset_key_envelopes SET wrapped_dek=$2 WHERE asset_object_id=$1 AND key_generation=1",
                 [Ecto.UUID.dump!(source.object_id), wrapped_dek]
               )

      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 "UPDATE content.asset_metadata SET plaintext_byte_size=$3 WHERE asset_id=$1 AND resource_version_id=$2",
                 [
                   Ecto.UUID.dump!(source.asset_id),
                   Ecto.UUID.dump!(source.resource_version_id),
                   byte_size(plaintext)
                 ]
               )
    end)

    %{domain_id: domain_id, domain_version_id: domain_version_id, lookup_digest: lookup_digest}
  end

  defp grant_runtime!(source) do
    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "UPDATE core.vaults SET locked=false WHERE id=$1", [
        Ecto.UUID.dump!(source.vault_id)
      ])

      query!(
        MigrationRepo,
        "INSERT INTO core.capabilities(id,name) VALUES($1,'asset.read') ON CONFLICT(name) DO NOTHING",
        [KnowledgeFixtures.uuid()]
      )

      query!(
        MigrationRepo,
        "INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name='asset.read' ON CONFLICT DO NOTHING",
        [Ecto.UUID.dump!(source.principal_id), Ecto.UUID.dump!(source.vault_id)]
      )
    end)
  end

  defp live_session(source) do
    %{rows: [[principal_epoch, vault_epoch, expires_at]]} =
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          """
          SELECT principal.authorization_epoch,vault.authorization_epoch,session.expires_at
          FROM identity.sessions session
          JOIN identity.principals principal ON principal.id=session.principal_id
          JOIN core.vaults vault ON vault.id=session.vault_id
          WHERE session.id=$1
          """,
          [Ecto.UUID.dump!(source.session_id)]
        )
      end)

    %SessionContext{
      account_id: source.account_id,
      authorization_epoch: principal_epoch,
      expires_at: expires_at,
      principal_authorization_epoch: principal_epoch,
      principal_id: source.principal_id,
      session_id: source.session_id,
      unlocked?: true,
      vault_authorization_epoch: vault_epoch,
      vault_id: source.vault_id
    }
  end

  defp import_attrs(f),
    do: %{asset_id: f.source.asset_id, title: f.title, mutation_id: Ecto.UUID.generate()}

  defp public_import(f, attrs) do
    try do
      {result, _events} =
        capture_runtime_call(f, :import, fn ->
          Api.import_document(f.config, f.session, attrs)
        end)

      result
    after
      assert_fresh_request_scope()
    end
  end

  defp with_import_grants(f, callback) do
    privileges_before = canonical_privileges()
    assert_canonical_writes_denied(privileges_before)

    try do
      KnowledgeTestGrants.with_grants(
        ~w(document_versions document_import_receipts),
        fn -> KnowledgeTestGrants.with_receipt_grants(fn -> callback.(f) end) end
      )
    after
      privileges_after = canonical_privileges()
      assert privileges_after == privileges_before
      assert_canonical_writes_denied(privileges_after)
    end

    # This separate real denial checks the capture mechanism after grants unwind.
    # Its event is never attributed to an import invocation.
    {control_result, control_events} =
      capture_runtime_call(f, :denial_control, fn ->
        Singularity.Storage.SafeSQL.query(
          WorkerRepo,
          "SELECT title FROM content.document_versions WHERE title=$1",
          [f.title]
        )
      end)

    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} = control_result

    denial_event = [:singularity, :authorization, :rls_denial]
    assert {denial_event, %{count: 1}, %{repo: :worker}} in control_events

    assert Enum.count(control_events, fn {event, _measurements, _metadata} ->
             event == denial_event
           end) == 1

    assert_private_surface(f, privacy_rows(f.source.vault_id))
  end

  defp capture_runtime_call(f, label, callback) do
    token = make_ref()
    handler = {__MODULE__, token}
    owner = self()

    query_events =
      [RequestRepo, WorkerRepo, DispatcherRepo, PreAuthRepo, MigrationRepo]
      |> Enum.map(&(&1.config()[:telemetry_prefix] ++ [:query]))
      |> Enum.uniq()

    assert :ok =
             :telemetry.attach_many(
               handler,
               query_events ++ [[:singularity, :authorization, :rls_denial]],
               &__MODULE__.capture_telemetry/4,
               {owner, token}
             )

    on_exit(fn -> :telemetry.detach(handler) end)

    try do
      logs = capture_log(fn -> send(owner, {token, :result, callback.()}) end)
      events = drain_telemetry(token)
      :telemetry.detach(handler)

      # Capture has ended before assertions, fixture observations, or fresh-scope SQL.
      assert_receive {^token, :result, result}

      query_count =
        Enum.count(events, fn {event, _measurements, _metadata} -> event in query_events end)

      IO.puts("live_import_capture=#{label} query_events=#{query_count}")
      assert_private_surface(f, events)
      assert_private_surface(f, logs)

      case result do
        {:error, _reason} -> assert_private_surface(f, result)
        {:ok, _value} -> :ok
      end

      {result, events}
    after
      :telemetry.detach(handler)
    end
  end

  def capture_telemetry(event, measurements, metadata, {owner, token}) do
    send(owner, {token, :telemetry, event, measurements, metadata})
  end

  defp drain_telemetry(token, events \\ []) do
    receive do
      {^token, :telemetry, event, measurements, metadata} ->
        drain_telemetry(token, [{event, measurements, metadata} | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp assert_private_surface(f, surface) do
    rendered = inspect(surface, limit: :infinity, printable_limit: :infinity)

    binaries = [
      f.plaintext,
      String.trim_trailing(f.plaintext),
      f.title,
      f.runtime.fingerprint_secret | f.key_canaries
    ]

    for binary <- binaries,
        canary <- [
          binary,
          inspect(binary, limit: :infinity, printable_limit: :infinity),
          Base.encode16(binary),
          Base.encode16(binary, case: :lower),
          Base.encode64(binary)
        ] do
      refute String.contains?(rendered, canary)

      if is_binary(surface) do
        refute String.contains?(surface, canary)
      end
    end
  end

  defp privacy_rows(owner) do
    Fixtures.with_owner(fn ->
      owner_id = Ecto.UUID.dump!(owner)

      %{
        audits:
          query!(
            MigrationRepo,
            "SELECT to_jsonb(e) FROM audit.events e WHERE vault_id=$1 ORDER BY id",
            [owner_id]
          ).rows,
        outbox:
          query!(
            MigrationRepo,
            "SELECT to_jsonb(e) FROM core.outbox_events e WHERE vault_id=$1 ORDER BY id",
            [owner_id]
          ).rows,
        submissions:
          query!(
            MigrationRepo,
            "SELECT to_jsonb(s) FROM jobs.job_submissions s WHERE vault_id=$1 ORDER BY id",
            [owner_id]
          ).rows,
        runners:
          query!(
            MigrationRepo,
            "SELECT to_jsonb(j) FROM jobs.oban_jobs j WHERE args->>'vault_id'=$1 ORDER BY id",
            [owner]
          ).rows
      }
    end)
  end

  defp assert_no_import(owner) do
    assert %{resources: [], versions: [], documents: [], receipts: [], events: []} =
             import_rows(owner)
  end

  defp download_audits(owner) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "SELECT to_jsonb(e) FROM audit.events e WHERE vault_id=$1 AND operation='asset.downloaded' ORDER BY id",
        [Ecto.UUID.dump!(owner)]
      ).rows
    end)
  end

  defp source_object(f) do
    Fixtures.with_owner(fn ->
      result =
        query!(
          MigrationRepo,
          "SELECT lifecycle,ciphertext_hash,ciphertext_byte_size,plaintext_byte_size,lifecycle_revision FROM content.asset_objects WHERE id=$1 AND vault_id=$2",
          [Ecto.UUID.dump!(f.source.object_id), Ecto.UUID.dump!(f.source.vault_id)]
        )

      assert %{rows: [["available", _hash, _ciphertext_size, _plaintext_size, _revision]]} =
               result

      result.rows
    end)
  end

  defp grant_asset_write!(source) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO core.capabilities(id,name) VALUES($1,'asset.write') ON CONFLICT(name) DO NOTHING",
        [KnowledgeFixtures.uuid()]
      )

      query!(
        MigrationRepo,
        "INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name='asset.write' ON CONFLICT DO NOTHING",
        [Ecto.UUID.dump!(source.principal_id), Ecto.UUID.dump!(source.vault_id)]
      )
    end)
  end

  defp assert_deleted_asset(f) do
    Fixtures.with_owner(fn ->
      assert %{rows: [[principal, %DateTime{}, %DateTime{}]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT tombstone.principal_id::text,tombstone.deleted_at,association.released_at
                 FROM content.tombstones tombstone
                 JOIN content.resource_assets association
                   ON association.asset_id=tombstone.asset_id
                   AND association.vault_id=tombstone.vault_id
                 WHERE tombstone.asset_id=$1 AND tombstone.vault_id=$2
                   AND association.resource_version_id=$3
                 """,
                 [
                   Ecto.UUID.dump!(f.source.asset_id),
                   Ecto.UUID.dump!(f.source.vault_id),
                   Ecto.UUID.dump!(f.source.resource_version_id)
                 ]
               )

      assert principal == f.source.principal_id
    end)
  end

  defp assert_persisted_import(f, attrs, document) do
    assert %{
             resources: [[resource]],
             versions: [[version]],
             documents: [[stored]],
             receipts: [[receipt]],
             events: [[event]]
           } = import_rows(f.source.vault_id)

    assert Map.take(resource, ~w(id current_version_id kind title vault_id classification)) == %{
             "id" => document.resource_id,
             "current_version_id" => document.resource_version_id,
             "kind" => "document",
             "title" => f.title,
             "vault_id" => f.source.vault_id,
             "classification" => "private"
           }

    assert Map.take(version, ~w(id resource_id vault_id classification revision)) == %{
             "id" => document.resource_version_id,
             "resource_id" => document.resource_id,
             "vault_id" => f.source.vault_id,
             "classification" => "private",
             "revision" => 0
           }

    assert Map.take(
             stored,
             ~w(resource_version_id resource_id vault_id classification source_asset_id source_resource_id source_resource_version_id source_object_id source_digest source_byte_size media_type title created_by_principal_id state attempt_generation)
           ) == %{
             "resource_version_id" => document.resource_version_id,
             "resource_id" => document.resource_id,
             "vault_id" => f.source.vault_id,
             "classification" => "private",
             "source_asset_id" => f.source.asset_id,
             "source_resource_id" => f.source.resource_id,
             "source_resource_version_id" => f.source.resource_version_id,
             "source_object_id" => f.source.object_id,
             "source_digest" => "\\x" <> Base.encode16(document.source.digest, case: :lower),
             "source_byte_size" => byte_size(f.plaintext),
             "media_type" => "text/plain",
             "title" => f.title,
             "created_by_principal_id" => f.source.principal_id,
             "state" => "pending",
             "attempt_generation" => 0
           }

    assert Map.take(receipt, ~w(vault_id principal_id mutation_id state resource_id version_id)) ==
             %{
               "vault_id" => f.source.vault_id,
               "principal_id" => f.source.principal_id,
               "mutation_id" => attrs.mutation_id,
               "state" => "completed",
               "resource_id" => document.resource_id,
               "version_id" => document.resource_version_id
             }

    assert event["payload"] == %{
             "resource_id" => document.resource_id,
             "resource_version_id" => document.resource_version_id
           }

    assert event["idempotency_key"] == "document-extraction:#{document.resource_version_id}"
    assert event["principal_id"] == f.source.principal_id
    assert event["vault_id"] == f.source.vault_id
    assert event["required_capability"] == "asset.read"
    assert event["principal_authorization_epoch"] == f.context.principal_authorization_epoch
    assert event["vault_authorization_epoch"] == f.context.vault_authorization_epoch
    assert event["expected_entity_revision"] == 0
  end

  defp import_rows(owner) do
    Fixtures.with_owner(fn ->
      owner_id = Ecto.UUID.dump!(owner)

      %{
        resources:
          query!(
            MigrationRepo,
            "SELECT to_jsonb(r) FROM content.resources r WHERE vault_id=$1 AND kind='document' ORDER BY id",
            [owner_id]
          ).rows,
        versions:
          query!(
            MigrationRepo,
            "SELECT to_jsonb(v) FROM content.resource_versions v JOIN content.resources r ON r.id=v.resource_id WHERE v.vault_id=$1 AND r.kind='document' ORDER BY v.id",
            [owner_id]
          ).rows,
        documents:
          query!(
            MigrationRepo,
            "SELECT to_jsonb(d) FROM content.document_versions d WHERE vault_id=$1 ORDER BY resource_version_id",
            [owner_id]
          ).rows,
        receipts:
          query!(
            MigrationRepo,
            "SELECT to_jsonb(r) FROM content.document_import_receipts r WHERE vault_id=$1 ORDER BY mutation_id",
            [owner_id]
          ).rows,
        events:
          query!(
            MigrationRepo,
            "SELECT to_jsonb(e) FROM core.outbox_events e WHERE vault_id=$1 AND event_type='document.extraction_requested' ORDER BY id",
            [owner_id]
          ).rows
      }
    end)
  end

  defp effects(owner) do
    Fixtures.with_owner(fn ->
      owner_id = Ecto.UUID.dump!(owner)

      %{
        fragments:
          query!(
            MigrationRepo,
            "SELECT to_jsonb(f) FROM content.document_fragments f WHERE vault_id=$1 ORDER BY id",
            [owner_id]
          ).rows,
        asset_search:
          query!(
            MigrationRepo,
            "SELECT to_jsonb(s) FROM content.asset_search_documents s WHERE vault_id=$1 ORDER BY asset_id",
            [owner_id]
          ).rows,
        note_search:
          query!(
            MigrationRepo,
            "SELECT to_jsonb(s) FROM content.note_search_documents s WHERE vault_id=$1 ORDER BY resource_id",
            [owner_id]
          ).rows,
        submissions:
          query!(
            MigrationRepo,
            "SELECT to_jsonb(s) FROM jobs.job_submissions s WHERE vault_id=$1 ORDER BY id",
            [owner_id]
          ).rows,
        runners:
          query!(
            MigrationRepo,
            "SELECT to_jsonb(j) FROM jobs.oban_jobs j WHERE args->>'vault_id'=$1 ORDER BY id",
            [owner]
          ).rows
      }
    end)
  end

  defp canonical_privileges do
    Fixtures.with_owner(fn ->
      for role <- ~w(singularity_web singularity_worker),
          table <- ~w(document_versions document_import_receipts document_fragments),
          privilege <- ~w(SELECT INSERT UPDATE DELETE),
          into: %{} do
        assert %{rows: [[allowed?]]} =
                 query!(MigrationRepo, "SELECT has_table_privilege($1,$2,$3)", [
                   role,
                   "content." <> table,
                   privilege
                 ])

        {{role, table, privilege}, allowed?}
      end
    end)
  end

  defp assert_canonical_writes_denied(privileges) do
    for {{_role, _table, privilege}, allowed?} <- privileges,
        privilege in ~w(INSERT UPDATE DELETE) do
      refute allowed?
    end
  end

  defp assert_fresh_request_scope do
    RequestRepo.checkout(fn ->
      refute RequestRepo.in_transaction?()

      assert %{rows: [[principal, owner]]} =
               query!(
                 RequestRepo,
                 "SELECT current_setting('singularity.principal_id',true),current_setting('singularity.vault_id',true)"
               )

      assert principal in [nil, ""]
      assert owner in [nil, ""]
    end)
  end
end
