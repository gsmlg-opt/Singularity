# Document extraction Runtime B source integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. The assigned worker does not spawn agents; the parent owns independent review and routing.

**Goal:** Qualify Task 12's real source acquisition, claim, restart, progress, and retained-original composition under actual WorkerRepo privileges.

**Architecture:** Append integration-only modules to the existing Runtime worker test file. Compose the actual Core, Authorize, WorkerScope, DocumentWorkerRepository, KeyCustodian, DownloadLease, CustodyReader, local encrypted storage, and existing text/Markdown/Poppler extractors. Test-only delegates record bounded observations and pause at owned message barriers without supplying authorization, plaintext, descriptors, attempts, or extractor successes.

**Tech Stack:** Elixir/ExUnit, Ecto/Postgrex, actual PostgreSQL role policies, Oban 2.24, AES-256-GCM chunked storage, Poppler, existing devenv integration alias.

---

## Preparation checkpoint and authority

Preparation began 2026-10-08 and continued 2026-10-09. The agreed filename retains the start date. Worktree: `/home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-2-import-extraction`; branch: `codex/v0.2-phase-2-import-extraction`; preparation baseline: `e39bba9f93d183e76a1eee56d5734d5dbdebce71`. It was clean before inspection. The parent subsequently created `docs/verification/2026-10-08-document-runtime-source-integration.md`; preserve that parent-owned path.

Runtime A production source is `d5ea128f3423e54df2381d78b941cafff291a62a`, independently SPEC_COMPLIANT then QUALITY_APPROVED. Its exact-source gate executed 80 unit/architecture contracts, all passing, with 17 historical integration exclusions. Its 735-line test file and production files are frozen for this B assignment. One successful A test-harness accessor correction occurred; failed Sol production repair rounds remain 0 and Astra attempts remain 0.

The parent must personally read this entire complete-code plan and issue B test GO before any test edits. This preparation authorizes only this plan file and the scoped baseline. No production GO is implied. On an unexpected B contract failure, retain the failing contract and evidence and stop before a production edit. Do not manufacture RED by removing production behavior. Already implemented A behavior may pass a new characterization immediately; report that honestly. Production behavior changes, if later authorized, require a focused failing contract first. Two unsuccessful cumulative Sol production repair rounds, or an evidenced technical impasse, require parent-managed Astra routing; do not reset the counter or spawn Astra.

Governing documents read for this plan:

- `AGENTS.md` and the supplied global repository instructions.
- `docs/superpowers/specs/2026-09-22-singularity-v0.2-phase-2-import-extraction-design.md`.
- `docs/superpowers/specs/2026-10-08-singularity-v0.2-phase-2-worker-bridge-proposal.md`.
- `docs/superpowers/specs/2026-10-08-singularity-v0.2-document-source-replay-design.md`.
- Full Task 12 in `docs/superpowers/plans/2026-09-22-singularity-v0.2-phase-2-import-extraction.md`.
- Runtime A plan, especially its mandatory B/C ledgers: `docs/superpowers/plans/2026-10-08-singularity-v0.2-document-extraction-runtime.md`.
- Runtime A evidence: `docs/verification/2026-10-08-document-extraction-runtime.md`.

The writing-plans, executing-plans, test-driven-development, using-elixir-skills, elixir-thinking, ecto-thinking, oban-thinking, and verification-before-completion instructions were read completely, including the TDD testing-anti-patterns reference. Parent instructions take precedence over a skill's generic commit/delegation suggestions. `unbuffer` is unavailable; do not install it. No E2E, commit, push, tag, release, deployment, dependency, migration, schema, Vault feature or compatibility patch, custody/key/capability semantic change, generic job/wake change, public repository change, backup/search/browser change, or C test edits are authorized here.

## Existing fixture characterization and fresh baseline

`DocumentFreshCustodyIntegrationTest` in `apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs:319` uses actual WorkerRepo custody, a per-test local custodian/lease supervisor, actual AEAD bytes, actual key wrapping, complete KnowledgeFixtures Document rows, and retained extraction event/submission rows. Its `source_fixture!/2` at line 527 is the basis for B fixture administration. The worker repository tests use actual `WorkerScope.run/2`, assert a checked-out WorkerRepo outside transactions, and delegate each phase to short envelope-bound transactions. Their progress fixture stores version 4/revision 37 and compares `checkpoint::text` before and after transitions. Their existing wake test exercises `WakeHandshake` without changing Oban metadata.

Actual storage chunks are 4,194,304 bytes. `Text.extract/1` retains spaces within a nonblank line, but discards a wholly blank line. Therefore the death fixture is exactly 4 MiB spaces followed by `"\nrestart tail\n"`: it has two real encrypted data records and normalizes to one small text block on line 2. The new test explicitly verifies this instead of assuming it.

Fresh scoped baseline, exit 0, seed 1208:

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs --seed 1208
```

Storage: 73 reported/executed, 0 failures, no exclusions. Runtime: 14 reported, 5 excluded, 9 executed, 0 failures. Total: 82 executed, 0 failures. Exact isolated names printed by the alias: database `singularity_test_b428cc96a1bf603ede076c12`; root `/tmp/singularity/integration/b428cc96a1bf603ede076c12`.

Independent read-only cleanup verification, exit 0, printed `0` and `storage_root_absent`:

```sh
devenv shell -- zsh -c 'psql -U singularity_migration -d postgres -At -c "SELECT count(*) FROM pg_database WHERE datname = '\''singularity_test_b428cc96a1bf603ede076c12'\''"; test ! -e /tmp/singularity/integration/b428cc96a1bf603ede076c12 && print storage_root_absent'
```

The parent independently rechecked both names, also absent. All owned preparation commands finished. The shared Mix slot was explicitly released; reacquire it from the parent before any future Mix command. Borrowed devenv/PostgreSQL services were not stopped or restarted.

## File ownership and execution discipline

Only after B test GO, append the complete blocks below, in order, to `apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs`. Preserve its existing first 735 lines byte-for-byte. The new support module belongs in this test file, not production or shared support. Each following module is independently tagged `:integration`, uses a unique temporary directory and owned supervisor children, and executes serially because existing fixture administration starts the named MigrationRepo. Fixture administration and inspection use `Fixtures.with_owner/1`; verified calls always use actual WorkerScope/WorkerRepo. No grants or RequestRepo substitution occur.

Tests deliberately use a named owned Oban instance only for the wake test. It runs in manual mode with queues/plugins disabled. The callback delegates to existing `ObanAdapter.wake_vault/2`; it does not implement a replacement wake handshake. The existing KeyCustodian activation calls it synchronously, so completed activation is the wake barrier.

The test observer stores no raw source bytes or keys. It records hashes, sizes, bounded receipt/attempt maps, PIDs, call order, and transaction observations. A lease is requested and consumed by the same runner PID. The real reader child delegates CustodyReader before a post-read barrier. Each barrier has a unique token and 5-second bound. Runner, lease, and blocked reader are monitored; killing a runner and observing its DOWN is followed by explicit lease/reader DOWN checks. Cleanup only touches owned processes, using monitors. No sleeps or production test hooks are introduced.

### Task B1: Append delegate-only support and full encrypted canonical fixtures

**Files:** Append only `apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs`.

- [x] Recheck branch/HEAD/current diff; verify the original 735 lines against baseline before appending.

```sh
git status --short
git branch --show-current
git rev-parse HEAD
git diff -- apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs
```

- [x] Append this complete support block. Its public functions are test-local helpers used by the later complete modules.

```elixir
defmodule Singularity.Runtime.DocumentSourceIntegrationSupport do
  import ExUnit.Assertions
  import Singularity.Storage.DataCase, only: [query!: 3]

  alias Singularity.Core.{
    DocumentCompletion,
    DocumentFragmentation,
    JobEnvelope,
    ObjectRef,
    SourceLocator
  }

  alias Singularity.Ingest.Documents.{Markdown, PDF, Text}

  alias Singularity.Runtime.{
    AuthorizationDependencies,
    Authorize,
    CustodyReader,
    KeyCustodian,
    KeyLease,
    KeyLeaseSupervisor
  }

  alias Singularity.Runtime.Documents.Extract

  alias Singularity.Storage.{
    Fixtures,
    KnowledgeFixtures,
    LocalFilesystemAdapter,
    MigrationRepo,
    ScopedRepo,
    WorkerRepo
  }

  alias Singularity.Storage.Crypto.{ChunkedAEAD, Format, KeyWrapper}
  alias Singularity.Storage.Jobs.{EnvelopeCodec, WorkerScope}
  alias Singularity.Storage.Local.PathGuard

  alias Singularity.Storage.Postgres.{
    CustodyRepository,
    DocumentWorkerRepository,
    IdentityRepository
  }

  defmodule Probe do
    def start_link(owner),
      do: Agent.start_link(fn -> %{owner: owner, events: [], barriers: %{}} end)

    def barrier(probe, key) do
      token = make_ref()
      Agent.update(probe, &put_in(&1.barriers[key], token))
      token
    end

    def event(probe, key, value) do
      caller = self()

      {owner, token} =
        Agent.get_and_update(probe, fn state ->
          {token, barriers} = Map.pop(state.barriers, key)

          {{state.owner, token},
           %{state | barriers: barriers, events: state.events ++ [{key, caller, value}]}}
        end)

      if token do
        send(owner, {probe, :barrier, key, caller, token, value})

        receive do
          {^token, :continue} -> :ok
        after
          5_000 -> raise "Document integration barrier expired"
        end
      end

      :ok
    end

    def events(probe), do: Agent.get(probe, & &1.events)
    def clear(probe), do: Agent.update(probe, &%{&1 | events: []})
  end

  defmodule Reader do
    alias Singularity.Runtime.CustodyReader
    alias Singularity.Runtime.DocumentSourceIntegrationSupport.Probe
    alias Singularity.Storage.WorkerRepo

    def read_chunk(context, binding, index) do
      result = CustodyReader.read_chunk(context, binding, index)

      summary =
        case result do
          {:ok, bytes} -> %{size: byte_size(bytes), digest: :crypto.hash(:sha256, bytes)}
          {:error, _} -> :error
        end

      Probe.event(context.b_probe, {:reader_after, index}, %{
        summary: summary,
        transaction?: WorkerRepo.in_transaction?()
      })

      result
    end

    def read_range(context, binding, range) do
      result = CustodyReader.read_range(context, binding, range)

      Probe.event(context.b_probe, :reader_empty_after, %{
        result: if(result == {:ok, ""}, do: :authenticated_empty, else: :error),
        transaction?: WorkerRepo.in_transaction?()
      })

      result
    end
  end

  defmodule Custodian do
    alias Singularity.Runtime.KeyCustodian
    alias Singularity.Runtime.DocumentSourceIntegrationSupport.Probe

    def lease(%{probe: probe, pid: pid}, request) do
      result = KeyCustodian.lease(pid, request)
      Probe.event(probe, :leased, result)
      result
    end
  end

  defmodule Lease do
    alias Singularity.Runtime.DownloadLease
    alias Singularity.Runtime.DocumentSourceIntegrationSupport.Probe
    alias Singularity.Storage.WorkerRepo

    def read_document_chunk(probe, lease, index) do
      false = WorkerRepo.in_transaction?()
      result = DownloadLease.read_document_chunk(lease, index)

      Probe.event(
        probe,
        {:delivered, index},
        case result do
          {:ok, bytes} -> %{size: byte_size(bytes), digest: :crypto.hash(:sha256, bytes)}
          {:error, _} -> :error
        end
      )

      result
    end

    def authenticate_empty_document_source(probe, lease) do
      false = WorkerRepo.in_transaction?()
      result = DownloadLease.authenticate_empty_document_source(lease)
      Probe.event(probe, :empty_authenticated, result)
      result
    end

    def revoke(probe, lease) do
      false = WorkerRepo.in_transaction?()
      result = DownloadLease.revoke(lease)
      Probe.event(probe, :revoked, %{lease: lease, result: result})
      result
    end
  end

  defmodule Worker do
    alias Singularity.Runtime.DocumentSourceIntegrationSupport.Probe
    alias Singularity.Storage.{DataCase, WorkerRepo}
    alias Singularity.Storage.Postgres.DocumentWorkerRepository

    def describe(probe, context, envelope) do
      result = DocumentWorkerRepository.describe(context, envelope)
      Probe.event(probe, :described, result)
      result
    end

    def put_progress_state(probe, context, envelope, state) do
      false = WorkerRepo.in_transaction?()

      context =
        if Map.get(context, :b_fail_progress?, false) do
          Map.put(context, :transact, fn options, phase ->
            context.transact.(options, fn repo ->
              result = phase.(repo)
              DataCase.query!(repo, "SELECT runtime_b_private_progress_failure()", [])
              result
            end)
          end)
        else
          context
        end

      result = DocumentWorkerRepository.put_progress_state(context, envelope, state)
      Probe.event(probe, {:progress, state}, result)
      result
    end

    def claim(probe, context, envelope, adapter, format) do
      false = WorkerRepo.in_transaction?()
      Probe.event(probe, :claim_before, {adapter, format})
      result = DocumentWorkerRepository.claim(context, envelope, adapter, format)
      Probe.event(probe, :claimed, result)
      result
    end

    def complete(probe, context, envelope, source, attempt, completion) do
      false = WorkerRepo.in_transaction?()
      result = DocumentWorkerRepository.complete(context, envelope, source, attempt, completion)
      Probe.event(probe, :completed, result)
      result
    end
  end

  defmodule Extractor do
    alias Singularity.Runtime.DocumentSourceIntegrationSupport.Probe
    alias Singularity.Storage.WorkerRepo

    def extract(%{probe: probe, module: module}, bytes) do
      true = WorkerRepo.checked_out?()
      false = WorkerRepo.in_transaction?()
      result = module.extract(bytes)

      Probe.event(probe, :extracted, %{
        digest: :crypto.hash(:sha256, bytes),
        size: byte_size(bytes),
        module: module
      })

      result
    end
  end

  defmodule Wake do
    alias Singularity.Storage.Jobs.ObanAdapter

    def wake_waiting(name, %{vault_id: owner, limit: limit}) do
      ObanAdapter.wake_vault(%{oban_name: name, limit: limit}, owner)
    end
  end

  def setup(context) do
    fixture =
      source_fixture!(
        context.tmp_dir,
        Map.get(context, :plaintext, "first\n\nsecond\n"),
        Map.get(context, :media_type, "text/plain"),
        Map.get(context, :pin, :matching)
      )

    probe =
      ExUnit.Callbacks.start_supervised!(%{id: make_ref(), start: {Probe, :start_link, [self()]}})

    supervisor =
      ExUnit.Callbacks.start_supervised!({KeyLeaseSupervisor, name: nil}, id: make_ref())

    custody = %{
      key_wrapper: KeyWrapper,
      repo: WorkerRepo,
      repository_adapter: CustodyRepository,
      scope: ScopedRepo,
      b_probe: probe,
      storage: %{adapter: LocalFilesystemAdapter, context: %{root: context.tmp_dir}}
    }

    wake =
      if Map.get(context, :wake?, false) do
        name = Singularity.Runtime.DocumentSourceIntegrationSupport.OwnedOban

        ExUnit.Callbacks.start_supervised!(
          {Oban,
           name: name,
           repo: WorkerRepo,
           prefix: "jobs",
           testing: :manual,
           queues: false,
           plugins: false},
          id: make_ref()
        )

        {Wake, name}
      else
        nil
      end

    custodian =
      ExUnit.Callbacks.start_supervised!(
        {KeyCustodian,
         %{
           authorization: CustodyReader,
           clock: CustodyReader,
           context: custody,
           idle_lock: fn _ -> :ok end,
           key_reader: Reader,
           object_key_loader: CustodyReader,
           lease_supervisor: supervisor,
           wake_waiting: wake
         }},
        id: make_ref()
      )

    session =
      Map.merge(
        Map.take(
          fixture,
          [
            :session_id,
            :principal_id,
            :vault_id,
            :key_domain_id,
            :domain_key_version_id,
            :domain_key
          ]
        ),
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

    fixture =
      Map.merge(fixture, %{
        probe: probe,
        custodian: custodian,
        session: session,
        lease_supervisor: supervisor,
        wake: wake
      })

    unless Map.get(context, :locked?, false), do: activate!(fixture)
    {:ok, fixture: fixture}
  end

  def activate!(fixture) do
    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "UPDATE core.vaults SET locked=false WHERE id=$1", [
        fixture.source.vault_id
      ])
    end)

    assert {:ok, pending} = KeyCustodian.prepare_unlock(fixture.custodian, fixture.session)
    assert :ok = KeyCustodian.activate_unlock(fixture.custodian, pending)
    :ok
  end

  def run(fixture, options \\ []) do
    envelope = Keyword.get(options, :envelope, fixture.envelope)

    WorkerScope.run(envelope, fn scope ->
      assert scope.repo_handle === WorkerRepo
      assert WorkerRepo.checked_out?()
      refute WorkerRepo.in_transaction?()

      authorization = %AuthorizationDependencies{
        store: IdentityRepository,
        custodian: {KeyCustodian, fixture.custodian}
      }

      extractors =
        Map.new(
          [
            {"text/plain", Text, "plain_text"},
            {"text/markdown", Markdown, "markdown"},
            {"application/pdf", PDF, "poppler_text"}
          ],
          fn {type, module, name} ->
            {type, {{Extractor, %{probe: fixture.probe, module: module}}, name, 1}}
          end
        )

      context =
        Map.merge(scope, %{
          authorize: Authorize,
          authorization: authorization,
          document_worker: {Worker, fixture.probe},
          custodian: {Custodian, %{probe: fixture.probe, pid: fixture.custodian}},
          document_source_lease: {Lease, fixture.probe},
          document_extractors: extractors,
          b_fail_progress?: Keyword.get(options, :fail_progress?, false)
        })

      Extract.run(context, envelope)
    end)
  end

  def spawn_run(fixture, options \\ []) do
    owner = self()
    token = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result = run(fixture, options)
        send(owner, {token, :result, result})
      end)

    ExUnit.Callbacks.on_exit(fn -> stop_owned(pid) end)
    %{pid: pid, monitor: monitor, token: token}
  end

  def stop_owned(pid) do
    monitor = Process.monitor(pid)
    if Process.alive?(pid), do: Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _} -> :ok
    after
      5_000 -> raise "owned Document integration process did not terminate"
    end
  end

  def kill_runner!(runner) do
    %{pid: pid, monitor: monitor, token: token} = runner
    Process.exit(runner.pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000
    refute_receive {^token, :result, _}, 0
  end

  def await_result!(runner) do
    assert_receive {token, :result, result} when token == runner.token, 5_000

    assert_receive {:DOWN, monitor, :process, pid, :normal}
                   when monitor == runner.monitor and pid == runner.pid,
                   5_000

    result
  end

  def barrier!(fixture, key), do: Probe.barrier(fixture.probe, key)

  def await_barrier!(fixture, key, token) do
    probe = fixture.probe
    assert_receive {^probe, :barrier, ^key, pid, ^token, value}, 5_000
    {pid, value}
  end

  def events(fixture), do: Probe.events(fixture.probe)
  def clear(fixture), do: Probe.clear(fixture.probe)
  def keys(fixture), do: Enum.map(events(fixture), &elem(&1, 0))

  def pending!(fixture) do
    assert [["pending", 0, nil, nil, nil, nil, nil, nil]] = attempt_rows(fixture)
    assert fragments(fixture) == []
  end

  def attempt_rows(fixture) do
    owner_query(
      """
      SELECT state,attempt_generation,attempt_job_id,extraction_adapter,extraction_format,
        attempt_started_at,attempt_deadline_at,extracted_text_digest
      FROM content.document_versions WHERE resource_version_id=$1
      """,
      [fixture.document.resource_version_id]
    ).rows
  end

  def fragments(fixture) do
    owner_query(
      """
      SELECT id,ordinal,text,digest,locator FROM content.document_fragments
      WHERE resource_version_id=$1 ORDER BY ordinal
      """,
      [fixture.document.resource_version_id]
    ).rows
  end

  def progress(fixture) do
    owner_query(
      """
      SELECT checkpoint_version,processing_revision,checkpoint::text,state
      FROM jobs.job_progress WHERE submission_id=$1
      """,
      [Ecto.UUID.dump!(fixture.envelope.job_id)]
    ).rows
  end

  def tombstone!(fixture, target) do
    id =
      case target do
        :asset -> fixture.source.resource_id
        :document -> fixture.document.resource_id
      end

    assert %{num_rows: 1} =
             owner_query(
               "UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id=$1",
               [id]
             )
  end

  def owner_query(sql, params),
    do: Fixtures.with_owner(fn -> query!(MigrationRepo, sql, params) end)

  def expected_fragments!(fixture, adapter) do
    assert {:ok, blocks} = adapter.extract(fixture.plaintext)

    identity = %{
      resource_id: fixture.envelope.payload["resource_id"],
      resource_version_id: fixture.envelope.payload["resource_version_id"],
      owner_scope_id: fixture.vault_id,
      classification: :private
    }

    assert {:ok, fragments} = DocumentFragmentation.build(identity, fixture.media_type, blocks)

    Enum.map(fragments, fn fragment ->
      [
        fragment.fragment_id,
        fragment.ordinal,
        fragment.text,
        fragment.digest,
        SourceLocator.to_map(fragment.locator)
      ]
    end)
  end

  def ready!(fixture, adapter) do
    assert {:ok, receipt} = run(fixture)

    assert receipt == %{
             resource_id: fixture.envelope.payload["resource_id"],
             resource_version_id: fixture.envelope.payload["resource_version_id"],
             job_id: fixture.envelope.job_id,
             generation: 1,
             state: :ready
           }

    assert fragments(fixture) == expected_fragments!(fixture, adapter)
    assert [["ready", 1, job, name, 1, started, deadline, digest]] = attempt_rows(fixture)
    assert job == Ecto.UUID.dump!(fixture.envelope.job_id)
    assert name in ["plain_text", "markdown", "poppler_text"]
    assert DateTime.diff(deadline, started, :microsecond) == 180_000_000
    texts = Enum.map(fragments(fixture), fn [_, _, text, _, _] -> text end)
    assert digest == :crypto.hash(:sha256, texts)

    assert Enum.any?(events(fixture), fn
             {:extracted, _, %{digest: hash, size: size, module: ^adapter}} ->
               hash == :crypto.hash(:sha256, fixture.plaintext) and
                 size == byte_size(fixture.plaintext)

             _ ->
               false
           end)

    assert DynamicSupervisor.which_children(fixture.lease_supervisor) == []
    receipt
  end

  def seed_terminal!(fixture, state) when state in [:failed, :unsupported] do
    WorkerScope.run(fixture.envelope, fn context ->
      assert {:ok, {:source, source}} =
               DocumentWorkerRepository.describe(context, fixture.envelope)

      assert {:ok, attempt} =
               DocumentWorkerRepository.claim(context, fixture.envelope, "plain_text", 1)

      assert {:ok, completion} =
               DocumentCompletion.new(%{
                 resource_id: source.resource_id,
                 resource_version_id: source.resource_version_id,
                 owner_scope_id: fixture.vault_id,
                 classification: :private,
                 generation: attempt.generation,
                 adapter_name: attempt.adapter_name,
                 format_version: attempt.format_version,
                 media_type: fixture.media_type,
                 finished_at: DateTime.utc_now(),
                 outcome: state,
                 failure_code: if(state == :failed, do: "extractor_failed", else: "invalid_utf8")
               })

      assert {:ok, receipt} =
               DocumentWorkerRepository.complete(
                 context,
                 fixture.envelope,
                 source,
                 attempt,
                 completion
               )

      receipt
    end)
  end

  def terminal_receipt!(fixture, :ready), do: ready!(fixture, Text)

  def terminal_receipt!(fixture, state) when state in [:failed, :unsupported],
    do: seed_terminal!(fixture, state)

  def seed_v4!(fixture) do
    binding = Map.delete(fixture.request, :purpose)
    checkpoint = KeyLease.document_checkpoint(binding, 1)

    assert %{num_rows: 1} =
             owner_query(
               """
               INSERT INTO jobs.job_progress(id,vault_id,submission_id,classification,state,
                 processing_revision,checkpoint_version,checkpoint,inserted_at,updated_at)
               VALUES($1,$2,$3,'private','running',37,4,$4::jsonb,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)
               """,
               [
                 KnowledgeFixtures.uuid(),
                 fixture.source.vault_id,
                 Ecto.UUID.dump!(fixture.envelope.job_id),
                 checkpoint
               ]
             )

    progress(fixture)
  end

  def corrupt!(fixture, kind) do
    case kind do
      :missing ->
        File.rename!(fixture.path, fixture.path <> ".missing")

      :truncated ->
        File.chmod!(fixture.path, 0o600)
        bytes = File.read!(fixture.path)
        cut = Format.header_size() + 8 + 1
        assert cut < byte_size(bytes)
        File.write!(fixture.path, binary_part(bytes, 0, cut))

      kind when kind in [:header, :final, :data] ->
        offset =
          case kind do
            :header -> 0
            :final -> File.stat!(fixture.path).size - 1
            :data -> Format.header_size() + 8
          end

        File.chmod!(fixture.path, 0o600)
        {:ok, io} = :file.open(fixture.path, [:read, :write, :binary])

        try do
          {:ok, <<byte>>} = :file.pread(io, offset, 1)
          :ok = :file.pwrite(io, offset, <<Bitwise.bxor(byte, 1)>>)
          :ok = :file.sync(io)
        after
          :ok = :file.close(io)
        end
    end
  end

  def pdf_bytes do
    File.read!(
      Path.expand(
        "../../../../singularity_ingest/test/fixtures/documents/two_pages.pdf",
        __DIR__
      )
    )
  end

  def restart_bytes, do: :binary.copy(" ", Format.chunk_size()) <> "\nrestart tail\n"

  def source_fixture!(root, plaintext, media_type, pin) do
    %{one: source, two: other} = Fixtures.two_vaults!()

    ids =
      Map.new(
        [:object_id, :key_domain_id, :domain_key_version_id, :vault_key_version_id, :job_id],
        &{&1, Ecto.UUID.generate()}
      )

    vault_id = Ecto.UUID.load!(source.vault_id)
    domain_key = :crypto.strong_rand_bytes(32)
    dek = :crypto.strong_rand_bytes(32)
    lookup = :crypto.strong_rand_bytes(32)

    assert {:ok, ciphertext} =
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
      lookup_digest: Base.encode16(lookup, case: :lower)
    }

    assert {:ok, stage} = LocalFilesystemAdapter.stage(storage, %{})
    assert :ok = LocalFilesystemAdapter.append_encrypted_chunk(storage, stage, ciphertext)
    assert {:ok, %{sealed?: true}} = LocalFilesystemAdapter.seal_stage(storage, stage, %{})
    object = %ObjectRef{object_id: ids.object_id}
    assert {:ok, ^object} = LocalFilesystemAdapter.finalize(storage, stage, object)

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
          lookup,
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

      query!(
        MigrationRepo,
        "INSERT INTO content.asset_metadata(id,asset_id,resource_version_id,vault_id,classification,projection_version,original_filename,declared_media_type,detected_media_type,plaintext_byte_size,extraction_state,completed_at) VALUES($1,$2,$3,$4,'private',1,'source',$5,$5,$6,'completed',CURRENT_TIMESTAMP)",
        [
          KnowledgeFixtures.uuid(),
          source.asset_id,
          source.resource_version_id,
          source.vault_id,
          media_type,
          byte_size(plaintext)
        ]
      )
    end)

    source =
      Map.merge(source, %{
        object_id: Ecto.UUID.dump!(ids.object_id),
        digest: digest,
        byte_size: byte_size(plaintext)
      })

    pin_attrs =
      case pin do
        :matching -> %{}
        :wrong_digest -> %{source_digest: :crypto.hash(:sha256, "different immutable original")}
      end

    document = KnowledgeFixtures.document!(source, Map.put(pin_attrs, :media_type, media_type))
    key = "document-extraction:" <> Ecto.UUID.load!(document.resource_version_id)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO core.outbox_events(id,event_type,idempotency_key,vault_id,principal_id,required_capability,principal_authorization_epoch,vault_authorization_epoch,classification,correlation_id,expected_entity_revision,envelope_version,payload,occurred_at) VALUES($1,'document.extraction_requested',$2,$3,$4,'asset.read',0,0,'private',$1,0,1,$5::jsonb,CURRENT_TIMESTAMP)",
        [
          Ecto.UUID.dump!(ids.job_id),
          key,
          source.vault_id,
          source.principal_id,
          %{
            "resource_id" => Ecto.UUID.load!(document.resource_id),
            "resource_version_id" => Ecto.UUID.load!(document.resource_version_id)
          }
        ]
      )

      query!(
        MigrationRepo,
        "INSERT INTO jobs.job_submissions(id,vault_id,outbox_event_id,classification,idempotency_key,job_type) VALUES($1,$2,$1,'private',$3,'document_extract')",
        [Ecto.UUID.dump!(ids.job_id), source.vault_id, key]
      )
    end)

    %{rows: [[job, event_key, owner, principal, pe, oe, correlation, revision, version, payload]]} =
      owner_query(
        "SELECT id,idempotency_key,vault_id,principal_id,principal_authorization_epoch,vault_authorization_epoch,correlation_id,expected_entity_revision,envelope_version,payload FROM core.outbox_events WHERE id=$1",
        [Ecto.UUID.dump!(ids.job_id)]
      )

    assert {:ok, envelope} =
             JobEnvelope.new(%{
               version: version,
               job_id: Ecto.UUID.load!(job),
               job_type: "document_extract",
               idempotency_key: event_key,
               vault_id: Ecto.UUID.load!(owner),
               principal_id: Ecto.UUID.load!(principal),
               required_capability: "asset.read",
               principal_authorization_epoch: pe,
               vault_authorization_epoch: oe,
               classification: :private,
               correlation_id: Ecto.UUID.load!(correlation),
               causation_id: Ecto.UUID.load!(job),
               expected_entity_revision: revision,
               attempt: 1,
               payload: payload
             })

    assert {:ok, encoded} = EnvelopeCodec.encode(envelope)
    assert {:ok, ^envelope} = EnvelopeCodec.decode(encoded)

    request = %{
      purpose: :document_extraction_source,
      access: :worker,
      job_id: envelope.job_id,
      resource_version_id: envelope.payload["resource_version_id"],
      vault_id: envelope.vault_id,
      principal_id: envelope.principal_id,
      required_capability: "asset.read",
      principal_authorization_epoch: pe,
      vault_authorization_epoch: oe,
      object_id: ids.object_id,
      object_generation: 1
    }

    Map.merge(ids, %{
      source: source,
      other: other,
      document: document,
      envelope: envelope,
      request: request,
      path: path,
      plaintext: plaintext,
      media_type: media_type,
      vault_id: envelope.vault_id,
      principal_id: envelope.principal_id,
      session_id: Ecto.UUID.load!(source.session_id),
      domain_key: domain_key,
      root: root
    })
  end
end
```

- [x] Before adding behavior tests, inspect this support block for API spelling and exact source identities; its delegates must return the actual result. No support-only test run establishes B acceptance.

### Task B2: Real ready formats, terminal receipt replay, and worker privileges

**Files:** Append only `apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs`.

- [x] Append the complete ready/replay module below.

```elixir
defmodule Singularity.Runtime.DocumentSourceReadyIntegrationTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  @moduletag :tmp_dir
  alias Singularity.Ingest.Documents.{Markdown, PDF, Text}
  alias Singularity.Runtime.DocumentSourceIntegrationSupport, as: S
  setup context, do: S.setup(context)

  test "actual WorkerRepo denies direct canonical Document access", %{fixture: f} do
    for operation <- [
          "SELECT resource_version_id FROM content.document_versions LIMIT 0",
          "DELETE FROM content.document_versions WHERE false",
          "UPDATE content.document_versions SET title=title WHERE false",
          "INSERT INTO content.document_versions DEFAULT VALUES"
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
               Ecto.Adapters.SQL.query(WorkerRepo, operation, [], log: false)
    end

    S.pending!(f)
  end

  test "real text persists exact ordered provenance and deterministic fragments", %{fixture: f} do
    receipt = S.ready!(f, Text)

    assert [
             [_, 0, "first", _, %{"kind" => "text", "start_line" => 1, "end_line" => 1}],
             [_, 1, "second", _, %{"kind" => "text", "start_line" => 3, "end_line" => 3}]
           ] = S.fragments(f)

    before = S.fragments(f)
    assert {:ok, ^receipt} = S.run(f)
    assert S.fragments(f) == before
  end

  @tag plaintext: "# One\r\n\r\nCafe\u0301\r\n\r\n## Two\r\nbody\r\n"
  @tag media_type: "text/markdown"
  test "real Markdown preserves normalized heading and source line provenance", %{fixture: f} do
    S.ready!(f, Markdown)

    assert [
             [_, 0, "# One", _, %{"heading_path" => ["One"], "start_line" => 1}],
             [_, 1, "Café", _, %{"heading_path" => ["One"], "start_line" => 3}],
             [_, 2, "## Two", _, %{"heading_path" => ["One", "Two"], "start_line" => 5}],
             [_, 3, "body", _, %{"heading_path" => ["One", "Two"], "start_line" => 6}]
           ] = S.fragments(f)
  end

  @tag plaintext: S.pdf_bytes()
  @tag media_type: "application/pdf"
  test "real multipage Poppler source persists page and character provenance", %{fixture: f} do
    S.ready!(f, PDF)

    assert [
             [
               _,
               0,
               first,
               _,
               %{"kind" => "pdf", "page" => 1, "start_char" => 0, "end_char" => a}
             ],
             [
               _,
               1,
               second,
               _,
               %{"kind" => "pdf", "page" => 2, "start_char" => 0, "end_char" => b}
             ]
           ] = S.fragments(f)

    assert first =~ "First page"
    assert second =~ "Second page"
    assert a > 0 and b > 0
  end

  for terminal <- [:ready, :failed, :unsupported] do
    test "#{terminal} replay returns only receipt without any source access", %{fixture: f} do
      receipt = S.terminal_receipt!(f, unquote(terminal))
      before = {S.attempt_rows(f), S.fragments(f), S.progress(f)}
      S.clear(f)
      File.rename!(f.path, f.path <> ".terminal-replay")
      assert {:ok, ^receipt} = S.run(f)

      assert Enum.sort(Map.keys(receipt)) ==
               Enum.sort(~w(resource_id resource_version_id job_id generation state)a)

      assert S.keys(f) == [:described]
      assert {S.attempt_rows(f), S.fragments(f), S.progress(f)} == before
    end
  end
end
```

- [x] Acquire the shared Mix slot, run the exact focused integration command, record actual outcomes, then release the slot.

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs --seed 1208
```

Expected at this append checkpoint: 7 new ready/replay integration contracts execute and pass; A's 43 unit tests remain excluded under the integration alias. The alias already prepends `--only integration`; do not add an OR-style module include and mistake it for a narrowing filter. A new failure is evidence to diagnose, never a reason to weaken an assertion or change production without parent decision.

### Task B3: Authentication before claim and actual authority denial before bytes

**Files:** Append only `apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs`.

- [x] Append this complete module.

```elixir
defmodule Singularity.Runtime.DocumentSourceAuthenticationIntegrationTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  @moduletag :tmp_dir
  alias Singularity.Core.Error
  alias Singularity.Runtime.DocumentSourceIntegrationSupport, as: S
  setup context, do: S.setup(context)

  @tag plaintext: ""
  test "valid empty original is authenticated before claim and extraction", %{fixture: f} do
    assert {:ok, %{state: :unsupported, generation: 1}} = S.run(f)

    assert [
             {:described, _, _},
             {:leased, _, {:ok, _}},
             {:reader_empty_after, _, %{result: :authenticated_empty, transaction?: false}},
             {:empty_authenticated, _, :ok},
             {{:progress, :running}, _, {:ok, :saved}},
             {:claim_before, _, _},
             {:claimed, _, {:ok, %{generation: 1}}},
             {:extracted, _, %{size: 0}},
             {:completed, _, {:ok, %{state: :unsupported}}}
           ] = S.events(f)

    assert S.fragments(f) == []
    assert DynamicSupervisor.which_children(f.lease_supervisor) == []
  end

  for corruption <- [:missing, :header, :final] do
    @tag plaintext: ""
    test "#{corruption} empty original fails authentication without attempt or extractor", %{
      fixture: f
    } do
      S.corrupt!(f, unquote(corruption))
      assert {:error, %Error{message: nil, details: %{}}} = S.run(f)
      S.pending!(f)
      refute :claim_before in S.keys(f)
      refute :extracted in S.keys(f)
      assert S.progress(f) == []
      assert DynamicSupervisor.which_children(f.lease_supervisor) == []
    end
  end

  @tag pin: :wrong_digest
  test "wrong immutable digest rejects authenticated plaintext before attempt and extractor", %{
    fixture: f
  } do
    assert {:error, %Error{code: :integrity_failure, message: nil, details: %{}}} = S.run(f)
    assert :leased in S.keys(f)
    assert {:delivered, 0} in S.keys(f)
    S.pending!(f)
    refute :claim_before in S.keys(f)
    refute :extracted in S.keys(f)
    assert S.progress(f) == []
    assert DynamicSupervisor.which_children(f.lease_supervisor) == []
  end

  test "actual object versus pin length mismatch denies descriptor before bytes", %{fixture: f} do
    assert %{num_rows: 1} =
             S.owner_query(
               "UPDATE content.asset_objects SET plaintext_byte_size=plaintext_byte_size+1 WHERE id=$1",
               [f.source.object_id]
             )

    assert {:error, %Error{code: :conflict, message: nil, details: %{}}} = S.run(f)
    refute :leased in S.keys(f)
    refute :claim_before in S.keys(f)
    refute :extracted in S.keys(f)
    S.pending!(f)
  end

  test "actual truncation inside expected data record fails before attempt", %{fixture: f} do
    S.corrupt!(f, :truncated)
    assert {:error, %Error{code: :integrity_failure, message: nil, details: %{}}} = S.run(f)
    assert :leased in S.keys(f)

    assert Enum.any?(S.events(f), fn
             {{:reader_after, 0}, _, %{summary: :error}} -> true
             _ -> false
           end)

    S.pending!(f)
    refute :claim_before in S.keys(f)
    refute :extracted in S.keys(f)
    assert DynamicSupervisor.which_children(f.lease_supervisor) == []
  end

  test "actual data AEAD authentication failure never claims or extracts", %{fixture: f} do
    S.corrupt!(f, :data)
    assert {:error, %Error{code: :integrity_failure, message: nil, details: %{}}} = S.run(f)
    S.pending!(f)

    assert Enum.any?(S.events(f), fn
             {{:reader_after, 0}, _, %{summary: :error}} -> true
             _ -> false
           end)

    refute :claim_before in S.keys(f)
    refute :extracted in S.keys(f)
    assert DynamicSupervisor.which_children(f.lease_supervisor) == []
  end

  test "malformed envelopes, owner injection and extra payload fields deny before bytes", %{
    fixture: f
  } do
    env = f.envelope

    for invalid <- [
          %{
            env
            | payload: %{
                "resource_id" => "not-a-uuid",
                "resource_version_id" => env.payload["resource_version_id"]
              }
          },
          %{env | payload: Map.put(env.payload, "owner_scope_id", f.vault_id)},
          %{env | payload: Map.put(env.payload, "extra", true)},
          Map.put(env, :owner_scope_id, Ecto.UUID.generate()),
          %{env | vault_id: Ecto.UUID.load!(f.other.vault_id)},
          %{env | principal_authorization_epoch: env.principal_authorization_epoch + 1},
          %{env | vault_authorization_epoch: env.vault_authorization_epoch + 1},
          %{env | job_id: Ecto.UUID.generate()},
          %{env | payload: Map.put(env.payload, "resource_version_id", Ecto.UUID.generate())}
        ] do
      S.clear(f)
      assert {:error, %Error{message: nil, details: %{}}} = S.run(f, envelope: invalid)
      refute :leased in S.keys(f)
      refute :claim_before in S.keys(f)
      refute :extracted in S.keys(f)
      S.pending!(f)
    end
  end

  test "coherent other-owner retained event cannot be consumed by original authenticated scope",
       %{fixture: f} do
    other =
      S.source_fixture!(
        Path.join(f.root, "other-owner"),
        "other original",
        "text/plain",
        :matching
      )

    assert {:ok, {:source, %{state: :pending}}} =
             Singularity.Storage.Jobs.WorkerScope.run(other.envelope, fn context ->
               Singularity.Storage.Postgres.DocumentWorkerRepository.describe(
                 context,
                 other.envelope
               )
             end)

    forged = %{
      other.envelope
      | vault_id: f.envelope.vault_id,
        principal_id: f.envelope.principal_id
    }

    assert {:error, %Error{message: nil, details: %{}}} = S.run(f, envelope: forged)
    refute :leased in S.keys(f)
    refute :claim_before in S.keys(f)
    refute :extracted in S.keys(f)
    S.pending!(f)
    S.pending!(other)
  end

  test "constraint-valid alternate-member retained principal and changed creator deny before bytes",
       %{fixture: f} do
    S.owner_query(
      "INSERT INTO core.vault_members(principal_id,vault_id) VALUES($1,$2)",
      [f.other.principal_id, f.source.vault_id]
    )

    S.owner_query(
      "INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name='asset.read'",
      [f.other.principal_id, f.source.vault_id]
    )

    S.owner_query(
      "UPDATE core.outbox_events SET principal_id=$2 WHERE id=$1",
      [Ecto.UUID.dump!(f.envelope.job_id), f.other.principal_id]
    )

    for envelope <- [
          f.envelope,
          %{f.envelope | principal_id: Ecto.UUID.load!(f.other.principal_id)}
        ] do
      S.clear(f)
      assert {:error, %Error{message: nil, details: %{}}} = S.run(f, envelope: envelope)
      refute :leased in S.keys(f)
      refute :claim_before in S.keys(f)
      refute :extracted in S.keys(f)
      S.pending!(f)
    end
  end

  for corruption <- [:extras, :revision, :principal_epoch, :owner_epoch] do
    test "actual retained #{corruption} mismatch denies before lease and mutation", %{fixture: f} do
      {field, value} =
        case unquote(corruption) do
          :extras -> {"payload", Map.put(f.envelope.payload, "extra", true)}
          :revision -> {"expected_entity_revision", 1}
          :principal_epoch -> {"principal_authorization_epoch", 1}
          :owner_epoch -> {"vault_authorization_epoch", 1}
        end

      S.owner_query(
        "UPDATE core.outbox_events SET #{field}=$2 WHERE id=$1",
        [Ecto.UUID.dump!(f.envelope.job_id), value]
      )

      assert {:error, %Error{message: nil, details: %{}}} = S.run(f)
      refute :leased in S.keys(f)
      refute :claim_before in S.keys(f)
      refute :extracted in S.keys(f)
      S.pending!(f)
    end
  end
end
```

- [x] Run the cumulative scoped authentication-stage command, record actual results and cleanup, then release the Mix slot.

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs --seed 1208
```

Expected at this append checkpoint: 7 ready/replay plus 15 authentication/authority contracts execute (22 B total), 43 A unit exclusions, 0 failures. SQL independently refuses an object/pin size disagreement before a lease; truncating the actual retained ciphertext after the header, first data-record prefix, and one ciphertext byte separately proves an incomplete expected data record cannot reach claim. This is not a final-record-only corruption expectation. Empty success may stop its lease before revoke; Runtime A's narrow closed-call cleanup handling must allow claim only after the real successful authentication. Nonempty data-record authentication plus exact length and digest is the claim; do not claim final-record authentication for a nonempty ranged read.

### Task B4: Existing unlock wake, progress preservation, and persistence rollback

**Files:** Append only `apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs`.

- [x] Append the complete progress module below.

```elixir
defmodule Singularity.Runtime.DocumentSourceProgressIntegrationTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  @moduletag :tmp_dir
  import ExUnit.CaptureLog
  alias Singularity.Core.Error
  alias Singularity.Ingest.Documents.Text
  alias Singularity.Runtime.DocumentSourceIntegrationSupport, as: S
  alias Singularity.Storage.Jobs.ObanAdapter
  setup context, do: S.setup(context)

  @tag locked?: true
  @tag wake?: true
  test "locked pending work saves waiting, wakes through existing unlock, resumes running and preserves v4",
       %{fixture: f} do
    assert [[4, 37, json, "running"]] = S.seed_v4!(f)
    assert {:ok, runner} = ObanAdapter.submit(%{oban_name: elem(f.wake, 1)}, f.envelope)
    runner = String.to_integer(runner)

    S.owner_query(
      "UPDATE jobs.oban_jobs SET state='scheduled',scheduled_at=CURRENT_TIMESTAMP+INTERVAL '1 hour' WHERE id=$1",
      [runner]
    )

    S.owner_query("UPDATE core.vaults SET locked=true WHERE id=$1", [f.source.vault_id])

    assert {:snooze, 60} = S.run(f)
    S.pending!(f)
    assert [[4, 37, ^json, "waiting_for_unlock"]] = S.progress(f)
    refute :claim_before in S.keys(f)
    refute :extracted in S.keys(f)

    assert S.owner_query(
             "SELECT wake_requested_generation,wake_consumed_generation FROM jobs.job_submissions WHERE id=$1",
             [Ecto.UUID.dump!(f.envelope.job_id)]
           ).rows == [[0, 0]]

    assert :ok = S.activate!(f)

    assert S.owner_query(
             "SELECT wake_requested_generation,wake_consumed_generation FROM jobs.job_submissions WHERE id=$1",
             [Ecto.UUID.dump!(f.envelope.job_id)]
           ).rows == [[1, 1]]

    assert [["available"]] =
             S.owner_query("SELECT state FROM jobs.oban_jobs WHERE id=$1", [runner]).rows

    assert [[4, 37, ^json, "waiting_for_unlock"]] = S.progress(f)

    S.clear(f)
    S.ready!(f, Text)
    assert [[4, 37, ^json, "running"]] = S.progress(f)

    assert {{:progress, :running}, _, {:ok, :saved}} =
             Enum.find(S.events(f), &(elem(&1, 0) == {:progress, :running}))

    assert S.owner_query("SELECT meta FROM jobs.oban_jobs WHERE id=$1", [runner]).rows == [[%{}]]
  end

  for locked <- [true, false] do
    @tag locked?: locked
    test "real #{if locked, do: "waiting", else: "running"} progress SQL failure rolls back and stays sanitized",
         %{fixture: f} do
      before = S.seed_v4!(f)
      state = if unquote(locked), do: :waiting_for_unlock, else: :running

      log =
        capture_log(fn ->
          assert {:error,
                  %Error{code: :storage_unavailable, retryable?: true, message: nil, details: %{}}} =
                   S.run(f, fail_progress?: true)
        end)

      refute log =~ "runtime_b_private_progress_failure"
      assert S.progress(f) == before

      assert {{:progress, ^state}, _, {:error, %Error{code: :storage_unavailable}}} =
               Enum.find(S.events(f), &(elem(&1, 0) == {:progress, state}))

      refute :claim_before in S.keys(f)
      refute :extracted in S.keys(f)
      S.pending!(f)
    end
  end
end
```

- [x] Run the exact progress command and release the Mix slot after observing completion and cleanup.

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs --seed 1208
```

Expected at this append checkpoint: 3 new progress contracts plus the prior 22 B execute (25 B total), 43 A unit exclusions, 0 failures. The SQL fault executes after the real progress write inside the original trusted scoped transaction, then causes actual PostgreSQL rollback. It does not fake a repository error or replace WorkerRepo. Both waiting and resumed-running failures propagate a sanitized error without a claim. Broader application/telemetry privacy canaries remain mandatory C work.

### Task B5: Owned real readers and worker death/restart without deadline reset

**Files:** Append only `apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs`.

- [x] Append this complete restart module. Monitor the blocked child before killing the consumer; no sleep is an ordering mechanism.

```elixir
defmodule Singularity.Runtime.DocumentSourceRestartIntegrationTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag plaintext: Singularity.Runtime.DocumentSourceIntegrationSupport.restart_bytes()
  alias Singularity.Ingest.Documents.Text
  alias Singularity.Runtime.DocumentSourceIntegrationSupport, as: S
  setup context, do: S.setup(context)

  test "death fixture spans actual storage records but extracts only the tail", %{fixture: f} do
    assert byte_size(f.plaintext) > 4_194_304

    assert {:ok, [%{text: "restart tail", locator: %{start_line: 2, end_line: 2}}]} =
             Text.extract(f.plaintext)
  end

  test "partial preclaim worker death cleans owned reader and rereads full identical original from zero",
       %{fixture: f} do
    token = S.barrier!(f, {:reader_after, 1})
    runner = S.spawn_run(f)

    {reader, %{summary: %{size: tail_size}, transaction?: false}} =
      S.await_barrier!(f, {:reader_after, 1}, token)

    assert tail_size == byte_size("\nrestart tail\n")
    assert [{:leased, _, {:ok, lease}}] = Enum.filter(S.events(f), &(elem(&1, 0) == :leased))

    assert {{:delivered, 0}, pid, %{size: 4_194_304}} =
             Enum.find(S.events(f), &(elem(&1, 0) == {:delivered, 0}))

    assert pid == runner.pid
    refute {:delivered, 1} in S.keys(f)
    lease_monitor = Process.monitor(lease)
    reader_monitor = Process.monitor(reader)
    S.kill_runner!(runner)
    assert_receive {:DOWN, ^lease_monitor, :process, ^lease, _}, 5_000
    assert_receive {:DOWN, ^reader_monitor, :process, ^reader, _}, 5_000
    assert DynamicSupervisor.which_children(f.lease_supervisor) == []
    S.pending!(f)
    assert S.progress(f) == []
    S.clear(f)
    S.ready!(f, Text)

    assert Enum.filter(S.keys(f), &match?({:delivered, _}, &1)) ==
             [{:delivered, 0}, {:delivered, 1}]
  end

  test "complete read preclaim death reauthenticates full source and leaves legacy v4 bytes untouched",
       %{fixture: f} do
    before = S.seed_v4!(f)
    token = S.barrier!(f, :revoked)
    runner = S.spawn_run(f)
    {pid, %{lease: lease, result: :ok}} = S.await_barrier!(f, :revoked, token)
    assert pid == runner.pid
    lease_monitor = Process.monitor(lease)
    assert_receive {:DOWN, ^lease_monitor, :process, ^lease, _}, 5_000

    assert Enum.filter(S.keys(f), &match?({:delivered, _}, &1)) ==
             [{:delivered, 0}, {:delivered, 1}]

    refute :claim_before in S.keys(f)
    S.kill_runner!(runner)
    S.pending!(f)
    assert S.progress(f) == before
    assert DynamicSupervisor.which_children(f.lease_supervisor) == []
    S.clear(f)
    S.ready!(f, Text)

    assert Enum.filter(S.keys(f), &match?({:delivered, _}, &1)) ==
             [{:delivered, 0}, {:delivered, 1}]

    assert S.progress(f) == before
  end

  test "claimed worker death resumes exact job generation adapter format and database deadline",
       %{fixture: f} do
    token = S.barrier!(f, :extracted)
    runner = S.spawn_run(f)
    {pid, %{digest: digest, module: Text}} = S.await_barrier!(f, :extracted, token)
    assert pid == runner.pid
    assert digest == :crypto.hash(:sha256, f.plaintext)
    assert [before] = S.attempt_rows(f)
    assert ["extracting", 1, job, "plain_text", 1, started, deadline, nil] = before
    assert job == Ecto.UUID.dump!(f.envelope.job_id)
    assert DateTime.diff(deadline, started, :microsecond) == 180_000_000
    assert DynamicSupervisor.which_children(f.lease_supervisor) == []
    S.kill_runner!(runner)
    assert S.attempt_rows(f) == [before]
    S.clear(f)
    S.ready!(f, Text)
    assert [["ready", 1, ^job, "plain_text", 1, ^started, ^deadline, _]] = S.attempt_rows(f)
    assert [{:claimed, _, {:ok, resumed}}] = Enum.filter(S.events(f), &(elem(&1, 0) == :claimed))
    assert resumed.job_id == f.envelope.job_id

    assert resumed.generation == 1 and resumed.adapter_name == "plain_text" and
             resumed.format_version == 1

    assert resumed.started_at == started and resumed.deadline_at == deadline

    assert Enum.filter(S.keys(f), &match?({:delivered, _}, &1)) ==
             [{:delivered, 0}, {:delivered, 1}]
  end
end
```

- [x] Run the exact restart command and release the shared Mix slot after completion and independent cleanup proof.

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs --seed 1208
```

Expected at this append checkpoint: 4 new restart contracts plus the prior 25 B execute (29 B total), 43 A unit exclusions, 0 failures. The post-read child barrier is reached only after the real authenticated read. First-chunk delivery and absent second-chunk delivery establish partial consumer state. The complete-read barrier is after actual lease revocation and before progress/claim. The extractor barrier follows a real extractor result while the DB still has the active claim; returning it is what was interrupted. Restart verifies unchanged database timestamps, not an approximate deadline duration.

### Task B6: Retained source Asset tombstone and Document delete-before-claim race

**Files:** Append only `apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs`.

- [x] Append the complete tombstone module.

```elixir
defmodule Singularity.Runtime.DocumentSourceTombstoneIntegrationTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  @moduletag :tmp_dir
  alias Singularity.Core.Error
  alias Singularity.Ingest.Documents.Text
  alias Singularity.Runtime.DocumentSourceIntegrationSupport, as: S
  setup context, do: S.setup(context)

  test "source Asset tombstone retains original for the entire actual worker composition", %{
    fixture: f
  } do
    ciphertext_before = File.read!(f.path)
    S.tombstone!(f, :asset)
    S.ready!(f, Text)
    assert File.read!(f.path) == ciphertext_before

    assert [[source_object]] =
             S.owner_query(
               "SELECT source_object_id FROM content.document_versions WHERE resource_version_id=$1",
               [f.document.resource_version_id]
             ).rows

    assert source_object == f.source.object_id

    assert Enum.filter(
             S.keys(f),
             &(&1 in [:described, :leased, :claimed, :extracted, :completed])
           ) ==
             [:described, :leased, :claimed, :extracted, :completed]
  end

  test "Document deletion after full read before first claim denies extraction and fragments", %{
    fixture: f
  } do
    token = S.barrier!(f, :claim_before)
    runner = S.spawn_run(f)
    {pid, {"plain_text", 1}} = S.await_barrier!(f, :claim_before, token)
    assert pid == runner.pid
    S.pending!(f)
    S.tombstone!(f, :document)
    send(pid, {token, :continue})
    assert {:error, %Error{message: nil, details: %{}}} = S.await_result!(runner)
    S.pending!(f)
    assert :claim_before in S.keys(f)

    assert [{:claimed, _, {:error, %Error{}}}] =
             Enum.filter(S.events(f), &(elem(&1, 0) == :claimed))

    refute :extracted in S.keys(f)
    assert DynamicSupervisor.which_children(f.lease_supervisor) == []
    assert File.exists?(f.path)
  end
end
```

- [x] Run the exact tombstone command, capture actual results/cleanup, then release the Mix slot.

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs --seed 1208
```

Expected at this append checkpoint: 2 new tombstone contracts plus the prior 29 B execute (31 B total), 43 A unit exclusions, 0 failures. The deletion barrier is immediately before the actual claim, after the real running-progress transaction (which itself re-describes the Document), so the assertion exercises claim denial. An already-claimed Document finishing after deletion is separate mandatory C evidence; this block covers only source tombstone and first-claim denial.

### Task B7: Combined B gate, old regressions, evidence, and parent handoff

**Files:** No additional test/production paths. The parent owns verification/status documents and any acceptance decision.

- [x] Run the complete new B integration file without module filtering. Expected: 31 new B integration contracts execute and pass, A's 43 unit contracts are excluded by the integration alias. Record actual reported/executed/excluded numbers; never substitute this expected count for output.

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs --seed 1208
```

- [x] Run the existing custody/worker-repository regressions with B included, using the shared slot serially.

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs --seed 1208
```

Expected: new 31 B plus baseline 82 executed (113 total), 0 failures; excluded historical tests stay excluded and their counts are reported honestly. If an outside-scope required gate fails, preserve evidence, list it, and stop instead of fixing outside scope.

- [x] For every integration invocation, capture the alias's exact printed `database=` and `storage_root=`. Independently query `pg_database` and test the exact root after the command exits. Use the concrete baseline cleanup command above with the newly observed exact names substituted; do not stop/restart borrowed services, recursively delete a workspace, or infer cleanup from exit 0. This is an observation-driven command target, not an invented database name. A leaked owned environment is an environment/cleanup blocker for the parent.

- [x] Run the A unit/regression commands and scoped formatting after the B source is formatted. New B integration tests remain excluded under plain `mix test`; do not claim they executed there.

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix format apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix format --check-formatted apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_unlock_resume_test.exs apps/singularity_runtime/test/singularity/runtime/job_dispatcher_asset_events_test.exs apps/singularity_runtime/test/singularity/runtime/application_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs --seed 1208
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix xref graph --format cycles --fail-above 0
git diff --check
```

Expected: A's 80 existing executed unit/architecture contracts still pass, and zero xref cycles. Format only the new additions if a whole-file formatter would change the first 735 historical lines. Preserve them; do not accept unrelated formatting as B work.

- [x] Prove the historical prefix is unchanged using exact bytes from the baseline, and inspect the final scoped diff.

```sh
elixir -e 'path = "apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs"; {baseline, 0} = System.cmd("git", ["show", "e39bba9f93d183e76a1eee56d5734d5dbdebce71:" <> path]); true = String.starts_with?(File.read!(path), baseline); IO.puts("historical A prefix byte-identical to baseline")'
git diff --numstat -- apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs
git diff -- apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs
git status --short
```

- [x] Report new test source and production source separately, exact commands/counts/exclusions, fixture/reader/runner/database/root cleanup, no Vault feature/compatibility patch, all counters, and remaining C work. Release the Mix slot explicitly. The parent arranges independent spec review, then quality review. No commit is made by this worker. Stop at the B handoff even if B is green; Task 12 and Phase 2 remain unaccepted until their complete gates.

## Mandatory B ledger mapped to complete code

| Required contract | Complete code location |
| --- | --- |
| Actual role, Core, retained event/submission, real crypto/custody/extractors | B1 setup/run/source_fixture; B2 privilege and ready tests |
| Real text/Markdown/multipage PDF provenance and deterministic fragments/digest | B2 ready tests; B1 expected_fragments!/ready! |
| Terminal ready/failed/unsupported replay without source | B2 three replay tests; actual typed Core completion fixture for failed/unsupported |
| Malformed/injected owner/extras/stale epochs/wrong retained scope before bytes | B3 envelope matrix, coherent other-owner event and valid alternate-member principal tests, four retained-field mismatch tests |
| Empty authenticated before claim; missing/corrupt header/final no attempt | B3 valid-empty and three corruption tests |
| Pinned digest/full-length mismatch and actual data AEAD failure before claim | B3 immutable digest, object/pin length disagreement, real truncated retained object, and data AEAD corruption tests |
| Locked custody pending0/waiting/snooze60/actual unlock wake/running/ready | B4 wake test through owned Oban plus actual KeyCustodian callback |
| Existing v4 version/revision/JSON byte preservation | B4 wake test and B5 complete-read death/resume test |
| Real progress persistence error sanitized and rolled back | B4 waiting/running SQL-fault tests |
| Actual partial-read death and whole-source restart from zero; owned reader cleanup | B5 partial-read test; digest/size asserted by real extractor observation |
| Complete-read preclaim death and whole-source restart | B5 revoke barrier test |
| Claimed worker death/resume exact same job/generation/adapter/format/deadline | B5 extractor-after-delegation barrier test |
| Asset tombstone retains original and ready completion | B6 source Asset tombstone test |
| Document delete after read before first claim denied/no extractor/fragments | B6 delete-before-claim race |
| No long SQL transaction across plaintext or extraction; owned processes only | B1 delegate assertions, message barriers/monitors, all modules |

## Mandatory C ledger retained without C edits

B does not waive any C requirement from the Runtime A plan. C needs its own complete-code plan, parent read/GO, implementation, fresh scoped evidence, and independent spec then quality review. Its remaining required contracts are:

- Actual unsupported inputs/caps and transient timeout/tool errors with allowlisted canonical outcomes.
- Existing-claim custody/storage loss, sanitized failure persistence, no re-claim or deadline extension.
- Post-claim persistence failure, atomic rollback/no partial fragments, and no failed-attempt search rows.
- Ready and failed completion after already-claimed Document tombstone while ordinary reads remain hidden.
- Actual recovery, manual retry, and restore races fencing stale claim/complete/fail/exhaustion.
- Actual GenericWorker terminal dispatch: immediate nonretryable and final retryable active-attempt exhaustion only.
- Pending locked, terminal, expired, recovered, and other-job exhaustion unchanged; authority/storage failures propagated.
- Nonterminal retry/snooze behavior, unchanged Oban Basic attempt restoration, unchanged max_attempts, existing wake shortening.
- Exact replay/conflicting replay and invalid fragment set/final persistence rollback.
- Actual application logs, telemetry metadata, public errors, Oban/outbox/progress/audit privacy canaries across source/extractor/SQL/runner failures.

Only A+B+C with the required Asset regressions can establish Task 12. Full Phase 2 additionally needs the complete README gate and checklist; release needs later approved phases and exact-source artifact/image qualification. E2E remains prohibited and unrun. No phase/release acceptance is asserted by this plan.

## Preparation-only stop checkpoint

- [x] Parent personally reads the complete plan, including every code block and mandatory B/C ledger.
- [x] Parent issues explicit B test GO and grants the shared Mix slot before implementation.
- [x] Until then, leave production and tests unchanged; only this new plan is worker-owned dirt.

Preparation is complete only after syntax/API/path/coverage/placeholder checks on this document and a final ownership diff. Passing the old baseline is preparation evidence, not evidence that the proposed B code has run. No B integration implementation or production behavior has been validated at this checkpoint.

### Preparation validation and plan-only corrections

All six embedded Elixir blocks parsed and compiled in memory against the existing test build, with `ExUnit.start(autorun: false)`. No test executed and no database was allocated by this check. Registered module counts were 7 ready/replay, 15 authentication/authority, 3 progress, 4 restart, and 2 tombstone contracts: 31 total. The complete code is intentionally held inside this plan until parent test GO.

```sh
elixir -pa '_build/test/lib/*/ebin' -e 'ExUnit.start(autorun: false); path = "docs/superpowers/plans/2026-10-08-singularity-v0.2-document-extraction-runtime-source-integration.md"; target = Path.expand("apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs"); blocks = Regex.scan(~r/```elixir\n(.*?)\n```/s, File.read!(path), capture: :all_but_first); Enum.with_index(blocks, 1) |> Enum.each(fn {[code], index} -> Code.string_to_quoted!(code); modules = Code.compile_string(code, target); Enum.each(modules, fn {module, _} -> if function_exported?(module, :__ex_unit__, 0), do: IO.puts("#{inspect(module)} tests=#{length(module.__ex_unit__().tests)}") end); IO.puts("compiled block #{index}") end)'
elixir -pa '_build/test/lib/*/ebin' -e 'bytes = :binary.copy(" ", 4_194_304) <> "\nrestart tail\n"; {:ok, [%{text: "restart tail", locator: %{start_line: 2, end_line: 2}}]} = Singularity.Ingest.Documents.Text.extract(bytes); IO.puts("actual Text.extract/1: two-record source bytes=#{byte_size(bytes)}, tail-only block on line2"); path = "apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs"; {baseline, 0} = System.cmd("git", ["show", "e39bba9f93d183e76a1eee56d5734d5dbdebce71:" <> path]); true = File.read!(path) == baseline; IO.puts("historical A test file byte-identical to baseline")'
git diff --no-index --check /dev/null docs/superpowers/plans/2026-10-08-singularity-v0.2-document-extraction-runtime-source-integration.md
```

The pure extractor/prefix check exited 0 and proved 4,194,318 source bytes produce the intended single tail block on line 2, and the whole current A test file is byte-identical to the preparation baseline. Whitespace validation produced no diagnostics; the final standalone B7 check corrects the new-file no-index command's diff-present exit status to 1, while tracked diff and explicit plan trailing-whitespace checks exit 0. Placeholder/obsolete-field scans found no implementation placeholders. An auxiliary ExUnit tag-inspection probe hit a `KeyError` because static test tags do not contain the runtime module tag; it changed no files. The final plan avoids module filters and uses honest cumulative scoped-file counts. An initial compile exposed constant-generated-branch type warnings; the test-local terminal-receipt helper removed them. These were plan-only checks/corrections, not production repair rounds.

Parent/self-review corrections retained in the final executable code:

- Core fragment identity uses `fragment.fragment_id`, and locator JSON uses existing `SourceLocator.to_map/1`.
- PDF fixture lookup uses four parent directories from the actual Runtime test directory; the path was verified during compilation of its tag.
- Existing v4 checkpoint construction preserves the required `access: :worker` binding.
- Death observations pin the exact runner monitor; the complete-read test observes lease termination without killing the lease to hide cleanup failure.
- Retained owner scope uses a second complete constraint-valid other-owner original/Document/event/submission; alternate principal membership/capability is established before mutating the event. No FK is disabled or bypassed.
- Object/pin size mismatch expects the existing SQL descriptor conflict. A separate truncation inside the expected data record checks actual storage failure before claim, without overclaiming final-record authentication.
- First-claim deletion pauses at `:claim_before` after running progress, avoiding an earlier progress re-description denial being mistaken for claim evidence.

The only worker-owned changed path is this new plan. The parent-owned B evidence file is preserved; production and tests are unchanged. Owned commands are finished; the Mix slot is released. Failed Sol production repair rounds: 0; received Astra repair counter: 0; Astra gate: none. No production/test GO has been acted on.

## B test execution after parent GO

Parent personally read all 1,209 preparation lines and all six code blocks, accepted the plan-only corrections, and issued explicit B test GO on 2026-10-09. Test-only append and this plan's execution results are worker-owned; parent evidence is preserved. Production remains frozen. The shared Mix slot is exclusively assigned to this worker for incremental B1–B7 execution, until explicit release.

- [x] B1: Appended the exact 527-line support block. Whole-file syntax parsed successfully and the historical A prefix is byte-identical to baseline.
- [x] B2: Appended the exact 65-line ready/replay module. The scoped integration command in B2 exited 0, seed 1208: 50 reported, 43 excluded, 7 executed, 0 failures. These are characterization contracts for existing behavior; no manufactured RED or production change occurred.
- [x] B3: Appended the authentication/authority block; the initial fixture failure and authorized surgical repair are preserved below. Rerun passed all 22 cumulative B integration contracts, with 43 A unit exclusions.
- [x] B4: Unlock wake and progress preservation/error stage passed, 25 cumulative B integration contracts executed, 0 failures.
- [x] B5: Worker death/restart stage passed, 29 cumulative B integration contracts executed, 0 failures.
- [x] B6: Tombstone and first-claim deletion stage passed, all 31 B integration contracts executed, 0 failures.
- [x] B7: Combined scoped gates, final ownership/source checks, and parent handoff.

B2 allocated database `singularity_test_1138b27770371676db4fe112` and root `/tmp/singularity/integration/1138b27770371676db4fe112`. Independent read-only cleanup query returned database count 0 and `storage_root_absent`, exit 0. The integration command finished; borrowed services were not restarted. Actual ready/replay assertions checked lease-supervisor emptiness; this stage created no runner-death barrier process. Failed Sol production repair rounds remain 0; Astra attempts remain 0.

### B3 unexpected fixture setup failure — stopped before repair

The same scoped integration command exited 2, seed 1208: 65 reported, 43 excluded, 22 selected, 21 passed and 1 fixture-setup failure. Failing contract: `actual object versus pin length mismatch denies descriptor before bytes`, `DocumentSourceAuthenticationIntegrationTest`, appended test file line 1377. Exact failure:

```text
** (Postgrex.Error) ERROR 23514 (check_violation) Document source is not the accepted live Asset tuple
constraint: document_versions_source_check
```

The stack reaches `KnowledgeFixtures.insert_document!/2` at its line 99 through the existing fixture owner transaction and new `source_fixture!/4` at test-file line 1232; `Extract.run/2` has not executed for this contract. Read-only inspection confirms `20260906000100_create_document_aggregate.exs:252` enforces `object.plaintext_byte_size = NEW.source_byte_size` on Document insertion before the expected worker-descriptor check. The approved plan incorrectly tried to seed the length disagreement directly in the new canonical Document. This is a harness/fixture-plan defect, not evidence of a Runtime production defect.

The command allocated database `singularity_test_327491e87549efc405366784` and root `/tmp/singularity/integration/327491e87549efc405366784`. After it finished, an independent read-only query returned database count 0 and `storage_root_absent`, exit 0. No runner-death processes were created in this stage. Borrowed services remain untouched.

Per B test GO, preserve the exact failing test/fixture and stop before production changes, assertion changes, or fixture repair. B4–B7 have not started. The existing storage worker repository test at line 1124 characterizes an object/source size disagreement through a post-insertion Asset object metadata update; the parent can review that precedent before deciding whether to authorize a narrowly revised fixture. No such change has been applied here.

Final stop checks: historical A prefix is byte-identical to baseline; task test diff is 748 additions and 0 deletions; `git diff --check` exited 0; Runtime production source/wiring diff is empty. The parent evidence file is preserved. All owned commands finished and the Mix slot is released. Failed Sol production repair rounds: 0; successful A test-harness correction: 1 inherited; B fixture repair rounds: 0; Astra attempts: 0. Parent decision is needed for a complete-code fixture-plan correction and bounded test-only repair; no production GO is requested or implied.

### Explicit B3 fixture repair GO

The parent independently confirmed the guard and existing worker repository test at lines 1124–1139, read the complete surgical replacement, independently verified failed-run cleanup, and issued test-harness repair GO. The correction removes only the impossible `:short_length` pin tag/helper branch and, after a valid matching Document fixture exists, explicitly increments only `content.asset_objects.plaintext_byte_size` under fixture administration. An affected-row count of 1 is asserted. Existing typed conflict, no lease, no claim, no extractor, and pending generation-zero assertions are unchanged. The immutable Document pin, production code, migrations, triggers and grants are untouched. The same exact correction is reflected in the embedded plan code. B harness repair-and-validation round 1 is in progress; failed production repair rounds remain 0 and Astra attempts remain 0. The shared Mix slot was reassigned exclusively for the rerun and authorized continuation if green.

B3 repair validation exited 0, seed 1208: 65 reported, 43 excluded, 22 executed, 0 failures. Exact database `singularity_test_e3042464b5568eedec04d45a` and root `/tmp/singularity/integration/e3042464b5568eedec04d45a` were independently confirmed absent (count 0 and `storage_root_absent`, exit 0). One successful B fixture repair-and-validation round is now recorded; no failed production repair round occurred. Production remains unchanged. The authorized sequence continues to B4 with the exclusive Mix slot retained.

B4's scoped command exited 0, seed 1208: 68 reported, 43 excluded, 25 executed, 0 failures. Actual existing KeyCustodian activation → ObanAdapter wake changed requested/consumed generations to 1/1 and scheduled runner to available; waiting/running transitions preserved v4 version 4/revision 37/checkpoint text. Both actual progress SQL rollback cases returned sanitized errors without a claim. Exact database `singularity_test_ecf8750e954407d188a7be41` and root `/tmp/singularity/integration/ecf8750e954407d188a7be41` were independently confirmed absent, count 0 / `storage_root_absent`, exit 0. All B4 assertions passed, including owned lease-supervisor cleanup; the owned named Oban instance stopped through ExUnit supervision. Production remains frozen; proceeding to B5.

B5's scoped command exited 0, seed 1208: 72 reported, 43 excluded, 29 executed, 0 failures. Actual two-record source partial-read death terminated the monitored consumer, lease and blocked authenticated reader; restart delivered indices 0/1 and the full identical original digest. Complete-read/preclaim death preserved the existing v4 checkpoint and reread from zero. The real extractor barrier death/resume preserved exact logical job, generation 1, plain_text/1, start and database deadline. Owned process/lease cleanup assertions passed. Exact database `singularity_test_aa8ba5b50835ffdde64f9834` and root `/tmp/singularity/integration/aa8ba5b50835ffdde64f9834` were independently confirmed absent, count 0 / `storage_root_absent`, exit 0. No production edits or service restarts; proceeding to B6.

B6's scoped command exited 0, seed 1208: 74 reported, 43 excluded, 31 executed, 0 failures. Source Asset tombstone retained identical encrypted original bytes while actual worker composition reached ready. Document deletion at the real first-claim barrier denied the claim with no extractor/fragments and retained bytes. All owned runner/lease cleanup assertions passed. Exact database `singularity_test_7ee5c4305e692d96995725d3` and root `/tmp/singularity/integration/7ee5c4305e692d96995725d3` were independently confirmed absent, count 0 / `storage_root_absent`, exit 0. Proceeding to B7's explicitly required combined gates; production remains frozen.

B7's required complete B-file integration command exited 0, seed 1208: 74 reported, 43 excluded, 31 executed, 0 failures. Exact database `singularity_test_1f8a6062a760fb6d469e44e1` and root `/tmp/singularity/integration/1f8a6062a760fb6d469e44e1` were independently confirmed absent, count 0 / `storage_root_absent`, exit 0. The historical A prefix remained byte-identical; the unformatted append was 939 lines with no deletions and `git diff --check` passed. Combined existing custody/worker-repository regressions and remaining checks are still pending at this checkpoint.

B7's first combined B/custody/worker-repository invocation exited 0, seed 1208: storage 73 executed; Runtime 88 reported, 48 excluded, 40 executed; total 113 executed, 0 failures. Exact database `singularity_test_b3af91411ad79cc11ce8d8b2` and root `/tmp/singularity/integration/b3af91411ad79cc11ce8d8b2` were independently confirmed absent, count 0 / `storage_root_absent`, exit 0. The parent independently confirmed cleanup.

A strict source-versus-concatenated-plan diagnostic then exited 1 because the appended Progress module followed Restart/Tombstone, although all six individual blocks were byte-identical and the A prefix was unchanged. This was a non-behavioral module-order discrepancy, not a test failure or production/assertion repair. The parent authorized moving Progress intact before Restart via `apply_patch`. Scoped `mix format` and `mix format --check-formatted` both exited 0; the historical A prefix remained byte-identical. The formatted append is 1,456 lines with 0 deletions. Embedded complete-code blocks were synchronized to the formatted source without semantic changes. A fresh combined invocation on that final reordered/formatted source is required and in progress.

That final-source combined command exited 0, seed 1208: storage 73 reported/executed, 0 failures; Runtime 88 reported, 48 excluded, 40 executed, 0 failures. Total 113 executed, 0 failures. Exact database `singularity_test_d99048bb21d9d9fb724dc284` and root `/tmp/singularity/integration/d99048bb21d9d9fb724dc284` were independently confirmed absent, count 0 / `storage_root_absent`, exit 0. All owned-process cleanup assertions passed. Strict whole-file equality against the original A bytes plus the six ordered, formatted embedded blocks passed. The parent-directed exclusive Mix slot remained assigned across B2–B7 rather than being released/reacquired between each stage; it will be explicitly released at final handoff.

The exact focused unit/architecture command in B7 exited 0, seed 1208: Runtime 113 reported, 48 integration exclusions, 65 executed, 0 failures; Web architecture 15 reported/executed, 0 failures. Total 80 existing unit/architecture contracts executed; the 31 B contracts were intentionally excluded here and are proved by integration runs instead. `mix xref graph --format cycles --fail-above 0` exited 0 with `No cycles found`. No isolated database/root was allocated by the unit, formatting, or xref commands.

Final whitespace evidence distinguishes command semantics: `git diff --check` exits 0; `git diff --no-index --check /dev/null` for the new plan exits 1 with no output (the file differs from `/dev/null`), not the exit 0 previously summarized during preparation. An independent Elixir line-by-line trailing-whitespace assertion on the plan exits 0. This reporting correction changes no test or production behavior.

### Final B-only handoff — 2026-10-09

Runtime B implementation and the scoped B1–B7 verification sequence are complete. Final test source is `apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs`, 2,191 lines, SHA-256 `373ad3d5fcfdd07ae522f00a037caa6efabbfba5f060c6c9685fb7d71da14178`. Its first 735 historical A lines are byte-identical to baseline `e39bba9f93d183e76a1eee56d5734d5dbdebce71`; the task diff is only 1,456 appended lines, with 0 deletions. All six formatted blocks in this plan match the source suffix exactly and in order. The only tracked changed file is that test file; worker-owned untracked work is this plan. Parent-owned verification evidence is preserved. No production source, migrations, grants, dependency, public interface, Vault feature or compatibility file changed.

All owned commands have finished. Every invoked integration environment is named and independently proven absent above; owned runner, authenticated reader, lease and Oban supervisor cleanup assertions passed. Borrowed PostgreSQL/devenv services were not restarted. The shared Mix slot is explicitly released to the parent at this handoff. Branch/worktree are preserved; no commit, push, external write or E2E run occurred. Failed Sol production repair rounds: 0; inherited successful A harness correction: 1; B fixture repair-and-validation rounds: 1 successful; Astra attempts/received repair counter: 0; Astra gate: none.

The parent must independently verify the final exact source and arrange fresh spec review followed by quality review. The mandatory C ledger remains wholly open; C test/production edits are not included or authorized by this handoff. Task 12, Phase 2 and the full release are not accepted by these B results.
