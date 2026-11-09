# Document Extraction Runtime C Outcomes Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. The parent owns delegation and independent reviews. Do not spawn agents.

**Goal:** Qualify Task 12's real outcomes, terminal fences, recovery, retry, restore, exhaustion, atomic persistence, and privacy without changing production.

**Architecture:** Append integration modules after the frozen A/B test source. Reuse B's complete encrypted fixtures and actual custody and WorkerScope composition. New test delegates inject failures or observe real calls; all successful authorization, source reads, extraction, claims, and typed persistence come from production adapters. Administrative lifecycle setup stays separate from worker calls.

**Tech Stack:** Elixir/ExUnit, WorkerRepo/PostgreSQL, actual encrypted local storage, Core constructors, Text/Markdown/Poppler, GenericWorker, Oban Basic 2.24, existing isolated integration alias.

---

## Authority, current source, and stop checkpoint

This plan is preparation only. Main must personally read its entire final content and issue explicit **C TEST GO** before any test edit. No production GO is implied. The assigned path is the only worker-owned change during preparation. Main owns verification/status documents, including `docs/verification/2026-10-09-document-runtime-outcomes-integration.md` and all B evidence.

Worktree: `/home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-2-import-extraction`; branch: `codex/v0.2-phase-2-import-extraction`. B source is `5be1e515ef9315933aed4bd7c65dc2b6abc4ed23`; subsequent evidence-only commits are `33e9bdae575f531f8f907a3a4157bf314feb99a8` and current HEAD `4f9f316c6af4eaaca54ff6f82b1817342e21d1ae`. Runtime A production remains `d5ea128f3423e54df2381d78b941cafff291a62a`. The existing test file is 2,191 lines and SHA-256 `373ad3d5fcfdd07ae522f00a037caa6efabbfba5f060c6c9685fb7d71da14178`. Its entire current content, including the first 735 A lines and all B support/tests, is frozen.

Main's exact-B-source prerequisite recheck executed 113 integration contracts and 80 unit/architecture contracts, zero failures, plus scoped format and xref with zero cycles. The exact isolated database `singularity_test_dda6b9ffca0c3d4a20f4b5c9` and root `/tmp/singularity/integration/dda6b9ffca0c3d4a20f4b5c9` were independently confirmed absent. These are prerequisite results, not C execution evidence. No redundant baseline is needed. Main released the Mix slot; acquire an explicit assignment before running any Mix or DB command. Borrowed devenv/PostgreSQL services remain running.

Read the supplied instructions and `AGENTS.md`, the complete 2026-09-22 Phase 2 design/plan, 2026-10-08 worker bridge and source replay amendments, complete Runtime A plan including mandatory B/C ledgers, full B plan, and A/B evidence. Required skills: writing-plans, executing-plans, test-driven-development and its testing-anti-patterns reference, verification-before-completion, using-elixir-skills, elixir-thinking, ecto-thinking, otp-thinking, oban-thinking, and elixir-observability with references/examples.md. They guide complete executable steps, real dependencies, process ownership, bounded telemetry and fresh evidence. Parent instructions override generic skill suggestions to commit, delegate, install `unbuffer`, or delete accepted implementation to manufacture RED.

Already implemented behavior may immediately pass these new characterization tests. Report that honestly. An unexpected test or baseline failure is retained and reported before repair. No test weakening, production repair, schema/migration, new grant, RequestRepo substitution for worker calls, fabricated partial canonical record, v4 reset/deletion, production hook, dependency, key/capability/custody/Vault semantic change, generic retry/wake or public repository change is authorized. No E2E, commit, push, merge, release, publication, or deployment. Full Task 12, Phase 2 and release acceptance remain separate.

Counters inherited across A/B/C: failed Sol production repairs 0; Astra attempts 0. One successful A accessor harness correction and one successful B constraint-valid fixture correction remain recorded. Two unsuccessful cumulative Sol production repair rounds or an evidenced technical impasse require parent-managed Astra routing, maximum three Astra attempts; do not reset counters or self-delegate.

## Characterized constraints and failure hypotheses

1. Canonical `source_byte_size` is 0..67,108,864 and INSERT requires equality with the available source object. An oversized pending Document cannot legitimately reach extraction. Source-cap evidence therefore comprises actual maximum-size worker success, canonical oversized INSERT rejection with transaction rollback, actual oversized PDF adapter rejection, and valid post-insert object metadata drift denied by describe before custody. A's existing synthetic mapping assertions remain frozen; no unreachable persisted `input_too_large` claim is made.
2. The lifecycle trigger prohibits changing an extracting attempt's start/deadline even under table-owner administration. Existing storage-test `expire/1` disables the trigger and is prohibited here. Pending-to-extracting administration with consistent past timestamps is legal but would not prove a real claimed worker's expiry race. C instead waits for one actual captured database deadline. A timer is calculated from PostgreSQL time/deadline, sliced to at most 30 seconds, with a 190-second monotonic bound and a 240-second test timeout. It neither changes the clock nor uses sleeps to order a race. All other ordering uses bounded mailbox barriers and process monitors.
3. Worker terminal SQL independently binds job/generation/adapter/format/media and deadline. Hypotheses under test: stale ready/fail writes after retry/restore/recovery must conflict; exhaustion alone must translate recognized lifecycle conflicts to unchanged, while authority/storage failures propagate.
4. GenericWorker calls its terminal callback only for typed immediate nonretryable or final retryable errors. A raised/thrown handler fallback is distinct and may leave a claim for recovery. Oban Basic fetch increments `attempt`; `snooze_job/3` decrements it and does not change `max_attempts`. Wake counters reside in submissions and may shorten a snooze from 60 to 1.
5. SQL validates all fragments before insertion, and the final completion transaction must roll back every inserted fragment and terminal field when a later SQL statement fails. Source storage and the immutable pin remain retained. No Document-version search row may appear; the source Asset's existing projection is a positive control.
6. SafeSQL disables ordinary query logging/telemetry; RLS denial emits only a role. Privacy tests attach to real configured Repo and Oban event names, capture actual logs and public errors, inspect persisted metadata surfaces, and include positive controls for successful canonical content and observed runner/denial events. Empty event collections alone are not a privacy proof.

## Ownership and execution order

After C TEST GO only, append the five complete Elixir blocks below, in order, to `apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs`. Do not change any existing byte. Main owns evidence/status. No production file is part of this plan. All modules use integration tags and serial fixture administration because `Fixtures.with_owner/1` starts the named MigrationRepo. Temporary directories and supervisors are owned by ExUnit; runner cleanup uses monitors. Each fault delegate either returns an actual result or injects a failure, never a successful replacement.

### Task C1: Append real composition and bounded failure support

- [ ] Recheck branch, current HEAD, exact diff and frozen test hash before editing.

```sh
git status --short
git branch --show-current
git rev-parse HEAD
sha256sum apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs
git diff -- apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs
```

- [ ] Append this entire support block. `RequestRepo` appears only in ordinary public-read assertions, never in worker composition. Administrative retry/restore invokes the existing guarded SQL as table owner with matching scoped identity; it adds no grant or public repository change.

```elixir
defmodule Singularity.Runtime.DocumentOutcomeIntegrationSupport do
  import ExUnit.Assertions
  alias Singularity.Core.{DocumentCompletion, DocumentFragmentation, Error, SourceLocator}
  alias Singularity.Ingest.Documents.{Markdown, PDF, Poppler, Text}
  alias Singularity.Runtime.{AuthorizationDependencies, Authorize, JobDispatcher, KeyCustodian}
  alias Singularity.Runtime.DocumentSourceIntegrationSupport, as: S
  alias Singularity.Runtime.DocumentSourceIntegrationSupport.{Custodian, Lease, Probe}
  alias Singularity.Runtime.Documents.Extract
  alias Singularity.Storage.{Fixtures, KnowledgeFixtures, MigrationRepo, RequestRepo, SafeSQL, ScopedRepo, WorkerRepo}
  alias Singularity.Storage.Jobs.{EnvelopeCodec, GenericWorker, WorkerScope}
  alias Singularity.Storage.Postgres.{DocumentRepository, DocumentWorkerRepository, IdentityRepository}

  @canary "CANARY_C_PRIVATE_TITLE_SOURCE_LOCATOR_TOOL_SQL"
  def canary, do: @canary

  defmodule ToolFailure do
    alias Singularity.Ingest.Documents.Poppler
    def run(:info, bytes, opts), do: Poppler.run(:info, bytes, opts)
    def run(:text, bytes, opts) do
      path = Keyword.fetch!(opts, :c_pid_path)
      fault = Keyword.fetch!(opts, :c_fault)
      script =
        case fault do
          :timeout -> "printf '%s' \"$$\" > \"$1\"; exec sleep 10"
          :tool_exit -> "printf '%s' \"$$\" > \"$1\"; printf '%s' \"$2\" >&2; exit 42"
        end
      result = Poppler.run_guarded("/bin/sh", ["-c", script, "c-owned-tool", path,
        Singularity.Runtime.DocumentOutcomeIntegrationSupport.canary()], bytes,
        timeout_ms: 2000, output_limit: 1024)
      pid = path |> File.read!() |> String.to_integer()
      ExUnit.Assertions.refute(File.exists?("/proc/#{pid}"))
      result
    end
  end

  defmodule Extractor do
    alias Singularity.Ingest.Documents.{PDF, Text}
    alias Singularity.Runtime.DocumentOutcomeIntegrationSupport.ToolFailure
    alias Singularity.Runtime.DocumentSourceIntegrationSupport.Probe
    alias Singularity.Storage.WorkerRepo
    def extract(config, bytes) do
      true = WorkerRepo.checked_out?()
      false = WorkerRepo.in_transaction?()
      Probe.event(config.f.probe, :c_extract, %{size: byte_size(bytes), digest: :crypto.hash(:sha256, bytes)})
      case config.mode do
        :actual -> config.module.extract(bytes)
        :raise ->
          {:ok, _} = Text.extract(bytes)
          raise Singularity.Runtime.DocumentOutcomeIntegrationSupport.canary()
        :throw ->
          {:ok, _} = Text.extract(bytes)
          throw(Singularity.Runtime.DocumentOutcomeIntegrationSupport.canary())
        mode when mode in [:timeout, :tool_exit] ->
          PDF.extract(bytes, runner: ToolFailure, c_fault: mode,
            c_pid_path: Path.join(config.f.root, "owned-tool-pid"))
      end
    end
  end

  defmodule Worker do
    alias Singularity.Runtime.DocumentSourceIntegrationSupport.Probe
    alias Singularity.Storage.{SafeSQL, WorkerRepo}
    alias Singularity.Storage.Postgres.DocumentWorkerRepository, as: R
    def describe(_config, context, envelope), do: R.describe(context, envelope)
    def put_progress_state(config, context, envelope, state) do
      result = R.put_progress_state(context, envelope, state)
      if state == :waiting_for_unlock and result == {:ok, :saved},
        do: Probe.event(config.f.probe, :c_waiting_saved, :saved)
      result
    end
    def claim(config, context, envelope, adapter, format) do
      result = R.claim(context, envelope, adapter, format)
      Probe.event(config.f.probe, :c_claimed, result)
      result
    end
    def complete(config, context, envelope, source, attempt, completion) do
      false = WorkerRepo.in_transaction?()
      Probe.event(config.f.probe, :c_complete_before, %{outcome: completion.outcome, generation: attempt.generation})
      R.complete(fault_context(context, config.complete_fault?), envelope, source, attempt, completion)
    end
    def record_exhaustion(config, context, envelope, failure, metadata) do
      Probe.event(config.f.probe, :c_terminal, metadata)
      result = R.record_exhaustion(fault_context(context, config.recorder_fault?), envelope, failure, metadata)
      Probe.event(config.f.probe, :c_terminal_result, result)
      result
    end
    defp fault_context(context, false), do: context
    defp fault_context(context, true) do
      original = context.transact
      Map.put(context, :transact, fn options, phase ->
        original.(options, fn repo ->
          result = phase.(repo)
          SafeSQL.query!(repo, "SELECT runtime_c_private_failure($1::text)",
            [Singularity.Runtime.DocumentOutcomeIntegrationSupport.canary()])
          result
        end)
      end)
    end
  end

  defmodule Handler do
    alias Singularity.Core.Error
    alias Singularity.Runtime.JobDispatcher
    alias Singularity.Runtime.DocumentSourceIntegrationSupport.Probe
    def dependencies, do: Application.fetch_env!(:singularity_storage, :runtime_c_dependencies)
    def handle(context, envelope) do
      case context.c_handler_mode do
        :actual -> JobDispatcher.handle(context, envelope)
        {:error, %Error{} = error} -> {:error, error}
        :raise -> raise Singularity.Runtime.DocumentOutcomeIntegrationSupport.canary()
        :throw -> throw(Singularity.Runtime.DocumentOutcomeIntegrationSupport.canary())
      end
    end
    def handle_failure(context, envelope, failure, metadata) do
      Probe.event(context.c_fixture.probe, :c_callback, metadata)
      JobDispatcher.handle_failure(context, envelope, failure, metadata)
    end
  end

  def setup(context) do
    {:ok, fixture: f} = S.setup(context)
    f = if Map.get(context, :private_title?, false), do: private_document!(f), else: f
    {:ok, fixture: f}
  end

  def dependencies(f, options \\ []) do
    config = %{f: f, complete_fault?: Keyword.get(options, :complete_fault?, false),
      recorder_fault?: Keyword.get(options, :recorder_fault?, false)}
    extractors = Map.new([{"text/plain", Text, "plain_text"},
      {"text/markdown", Markdown, "markdown"}, {"application/pdf", PDF, "poppler_text"}],
      fn {type, module, name} ->
        {type, {{Extractor, %{f: f, module: module, mode: Keyword.get(options, :mode, :actual)}}, name, 1}}
      end)
    %{authorize: Authorize,
      authorization: %AuthorizationDependencies{store: IdentityRepository, custodian: {KeyCustodian, f.custodian}},
      document_worker: {Worker, config},
      custodian: {Custodian, %{probe: f.probe, pid: f.custodian}},
      document_source_lease: {Lease, f.probe}, document_extractors: extractors,
      c_fixture: f, c_handler_mode: Keyword.get(options, :handler_mode, :actual)}
  end

  def run(f, options \\ []) do
    envelope = Keyword.get(options, :envelope, f.envelope)
    WorkerScope.run(envelope, fn scope ->
      assert scope.repo_handle === WorkerRepo
      refute WorkerRepo.in_transaction?()
      Extract.run(Map.merge(dependencies(f, options), scope), envelope)
    end)
  end

  def configure_runner!(f, options \\ []) do
    for {key, value} <- [job_handler: Handler, runtime_c_dependencies: dependencies(f, options)] do
      previous = Application.fetch_env(:singularity_storage, key)
      ExUnit.Callbacks.on_exit(fn ->
        case previous do
          {:ok, old} -> Application.put_env(:singularity_storage, key, old)
          :error -> Application.delete_env(:singularity_storage, key)
        end
      end)
      Application.put_env(:singularity_storage, key, value)
    end
    :ok
  end

  def spawn_run(f, options \\ []) do
    owner = self()
    token = make_ref()
    {pid, monitor} = spawn_monitor(fn -> send(owner, {token, :result, run(f, options)}) end)
    ExUnit.Callbacks.on_exit(fn -> S.stop_owned(pid) end)
    %{pid: pid, monitor: monitor, token: token}
  end

  def live!(f) do
    scope = %{principal_id: f.principal_id, vault_id: f.vault_id, owner_scope_id: f.vault_id}
    assert {:ok, document} = ScopedRepo.transact(RequestRepo, scope, fn repo ->
      DocumentRepository.get_live_scoped(repo, scope, f.envelope.payload["resource_id"])
    end)
    assert document.resource_id == f.envelope.payload["resource_id"]
    assert {:ok, binding} = ScopedRepo.transact(RequestRepo, scope, fn repo ->
      DocumentRepository.source_live_scoped(repo, scope, document.resource_id)
    end)
    assert binding.object_id == Ecto.UUID.load!(f.source.object_id)
    assert binding.source_byte_size == byte_size(f.plaintext)
    fragments = ScopedRepo.transact(RequestRepo, scope, fn repo ->
      DocumentRepository.fragments_live_scoped(repo, scope, document.resource_id)
    end)
    case document.state do
      :ready ->
        assert {:ok, public} = fragments
        assert Enum.map(public, fn fragment ->
          [fragment.fragment_id, fragment.ordinal, fragment.text, fragment.digest, SourceLocator.to_map(fragment.locator)]
        end) == S.fragments(f)
      :pending -> assert {:error, %Error{code: :conflict}} = fragments
    end
  end

  def captured_attempt!(f) do
    assert [{:c_claimed, _, {:ok, attempt}}] = Enum.filter(S.events(f), &(elem(&1, 0) == :c_claimed))
    assert {:ok, {:source, source}} = WorkerScope.run(f.envelope,
      &DocumentWorkerRepository.describe(&1, f.envelope))
    {source, attempt}
  end

  def sql_complete(f, fragments, digest) do
    e = f.envelope
    WorkerScope.run(e, fn scope ->
      scope.transact.([], fn repo ->
        SafeSQL.query(repo, "SELECT * FROM content.complete_document_worker($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)",
          [f.document.resource_id, f.document.resource_version_id, Ecto.UUID.dump!(e.job_id),
           e.expected_entity_revision, e.principal_authorization_epoch, e.vault_authorization_epoch,
           e.expected_entity_revision + 1, "plain_text", 1, "text/plain", fragments, digest, nil])
      end)
    end)
  end

  def json_fragments(completion) do
    Enum.map(completion.fragments, fn fragment ->
      %{"id" => fragment.fragment_id, "ordinal" => fragment.ordinal, "text" => fragment.text,
        "digest" => Base.encode16(fragment.digest, case: :lower), "locator" => SourceLocator.to_map(fragment.locator)}
    end)
  end

  def job(f, attempt \\ 1, maximum \\ 3) do
    {:ok, args} = EnvelopeCodec.encode(f.envelope)
    now = DateTime.utc_now()
    %Oban.Job{args: args, attempt: attempt, max_attempts: maximum, queue: "document_extract",
      worker: Oban.Worker.to_string(GenericWorker), attempted_at: now, scheduled_at: now}
  end

  def claim_by_interruption!(f) do
    token = S.barrier!(f, :claimed)
    runner = S.spawn_run(f)
    {pid, {:ok, attempt}} = S.await_barrier!(f, :claimed, token)
    assert pid == runner.pid
    S.kill_runner!(runner)
    refute :extracted in S.keys(f)
    assert DynamicSupervisor.which_children(f.lease_supervisor) == []
    {:ok, {:source, source}} = WorkerScope.run(f.envelope, &DocumentWorkerRepository.describe(&1, f.envelope))
    {source, attempt}
  end

  def completion!(f, source, attempt, outcome \\ :ready) do
    attrs = %{resource_id: source.resource_id, resource_version_id: source.resource_version_id,
      owner_scope_id: f.vault_id, classification: :private, generation: attempt.generation,
      adapter_name: attempt.adapter_name, format_version: attempt.format_version,
      media_type: f.media_type, finished_at: DateTime.utc_now(), outcome: outcome}
    attrs = if outcome == :ready do
      {:ok, blocks} = Text.extract(f.plaintext)
      {:ok, fragments} = DocumentFragmentation.build(Map.take(attrs,
        [:resource_id, :resource_version_id, :owner_scope_id, :classification]), f.media_type, blocks)
      Map.merge(attrs, %{fragments: fragments,
        extracted_text_digest: :crypto.hash(:sha256, Enum.map(fragments, & &1.text))})
    else
      Map.put(attrs, :failure_code, "extractor_failed")
    end
    {:ok, completion} = DocumentCompletion.new(attrs)
    completion
  end

  def complete(f, source, attempt, completion) do
    WorkerScope.run(f.envelope, fn scope ->
      DocumentWorkerRepository.complete(scope, f.envelope, source, attempt, completion)
    end)
  end

  def exhaustion(f, options \\ []) do
    WorkerScope.run(f.envelope, fn scope ->
      Extract.record_exhaustion(Map.merge(dependencies(f, options), scope), f.envelope,
        Error.new(:storage_unavailable, retryable?: true), %{attempt: 3, max_attempts: 3})
    end)
  end

  def no_projection!(f) do
    assert [[true, true, true]] = S.owner_query("""
      SELECT NOT EXISTS(SELECT 1 FROM content.asset_search_documents WHERE resource_version_id=$1),
        NOT EXISTS(SELECT 1 FROM content.note_search_documents WHERE resource_version_id=$1),
        EXISTS(SELECT 1 FROM content.asset_search_documents WHERE resource_version_id=$2)
      """, [f.document.resource_version_id, f.source.resource_version_id]).rows
  end

  def outcome!(f, state, code, options \\ []) do
    before = File.read!(f.path)
    assert {:ok, %{state: ^state, generation: 1}} = run(f, options)
    assert [[actual, 1, job_id, _, 1, started, deadline, nil]] = S.attempt_rows(f)
    assert actual == Atom.to_string(state)
    assert job_id == Ecto.UUID.dump!(f.envelope.job_id)
    assert DateTime.diff(deadline, started, :microsecond) == 180_000_000
    assert [[^code]] = S.owner_query("SELECT failure_code FROM content.document_versions WHERE resource_version_id=$1",
      [f.document.resource_version_id]).rows
    assert S.fragments(f) == []
    no_projection!(f)
    assert File.read!(f.path) == before
    assert DynamicSupervisor.which_children(f.lease_supervisor) == []
  end

  def hidden!(f) do
    scope = %{principal_id: f.principal_id, vault_id: f.vault_id, owner_scope_id: f.vault_id}
    for operation <- [:get_live_scoped, :fragments_live_scoped, :source_live_scoped] do
      assert {:error, %Error{code: :not_found}} = ScopedRepo.transact(RequestRepo, scope, fn repo ->
        apply(DocumentRepository, operation, [repo, scope, f.envelope.payload["resource_id"]])
      end)
    end
  end

  def mutation!(f, operation) when operation in [:retry, :restore] do
    assert [[id]] = Fixtures.with_owner(fn ->
      Singularity.Storage.DataCase.query!(MigrationRepo,
        "SELECT set_config('singularity.principal_id',$1,true),set_config('singularity.vault_id',$2,true)",
        [f.principal_id, f.vault_id])
      Singularity.Storage.DataCase.query!(MigrationRepo,
        "SELECT content.#{operation}_document_runtime($1,'plain_text',1)", [f.document.resource_id]).rows
    end)
    assert id == f.document.resource_id
  end

  def successor!(f, revision) do
    key = "document-extraction:#{f.envelope.payload["resource_version_id"]}:#{revision}"
    assert [[id, pe, oe, correlation, causation, payload]] = S.owner_query("""
      SELECT id,principal_authorization_epoch,vault_authorization_epoch,correlation_id,causation_id,payload
      FROM core.outbox_events WHERE vault_id=$1 AND idempotency_key=$2
      """, [f.source.vault_id, key]).rows
    env = %{f.envelope | job_id: Ecto.UUID.load!(id), idempotency_key: key,
      expected_entity_revision: revision, principal_authorization_epoch: pe,
      vault_authorization_epoch: oe, correlation_id: Ecto.UUID.load!(correlation),
      causation_id: if(is_nil(causation), do: nil, else: Ecto.UUID.load!(causation)),
      payload: payload}
    {:ok, encoded} = EnvelopeCodec.encode(env)
    {:ok, ^env} = EnvelopeCodec.decode(encoded)
    S.owner_query("""
      INSERT INTO jobs.job_submissions(id,vault_id,outbox_event_id,classification,idempotency_key,job_type)
      VALUES($1,$2,$1,'private',$3,'document_extract') ON CONFLICT(outbox_event_id) DO NOTHING
      """, [id, f.source.vault_id, key])
    %{f | envelope: env, request: %{f.request | job_id: env.job_id}}
  end

  def stale!(f, source, attempt) do
    ready = completion!(f, source, attempt)
    failed = completion!(f, source, attempt, :failed)
    before = {S.attempt_rows(f), S.fragments(f)}
    assert {:error, %Error{code: :conflict}} = WorkerScope.run(f.envelope,
      &DocumentWorkerRepository.claim(&1, f.envelope, attempt.adapter_name, attempt.format_version))
    assert {:error, %Error{code: :conflict}} = complete(f, source, attempt, ready)
    assert {:error, %Error{code: :conflict}} = complete(f, source, attempt, failed)
    assert {:ok, :unchanged} = exhaustion(f)
    assert {S.attempt_rows(f), S.fragments(f)} == before
  end

  def wait_for_deadline!(f, attempt) do
    assert DateTime.diff(attempt.deadline_at, attempt.started_at, :microsecond) == 180_000_000
    wait_for_deadline(f, attempt.deadline_at, System.monotonic_time(:millisecond) + 190_000)
  end
  defp wait_for_deadline(f, deadline, bound) do
    assert System.monotonic_time(:millisecond) < bound
    assert [[current, stored]] = S.owner_query("SELECT clock_timestamp(),attempt_deadline_at FROM content.document_versions WHERE resource_version_id=$1",
      [f.document.resource_version_id]).rows
    assert stored == deadline
    remaining = DateTime.diff(deadline, current, :millisecond)
    if remaining >= 0 do
      token = make_ref()
      timer = Process.send_after(self(), {:deadline_tick, token}, min(remaining + 2, 30_000))
      receive do
        {:deadline_tick, ^token} -> :ok
      after
        31_000 -> Process.cancel_timer(timer); flunk("database deadline timer exceeded bound")
      end
      wait_for_deadline(f, deadline, bound)
    else
      :ok
    end
  end

  def pdf_bytes(pages) do
    stream = "BT /F1 12 Tf 20 100 Td (page text) Tj ET\n"
    stream_id = pages + 4
    kids = Enum.map_join(4..(pages + 3), " ", &"#{&1} 0 R")
    objects = ["<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Count #{pages} /Kids [#{kids}] >>",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"] ++
      Enum.map(1..pages, fn _ -> "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 3 0 R >> >> /Contents #{stream_id} 0 R >>" end) ++
      ["<< /Length #{byte_size(stream)} >>\nstream\n#{stream}endstream"]
    {body, offsets} = Enum.with_index(objects, 1) |> Enum.reduce({"%PDF-1.4\n", []},
      fn {object, id}, {body, offsets} ->
        {body <> "#{id} 0 obj\n#{object}\nendobj\n", [byte_size(body) | offsets]}
      end)
    xref = Enum.reverse(offsets) |> Enum.map_join("", &(String.pad_leading(Integer.to_string(&1), 10, "0") <> " 00000 n \n"))
    body <> "xref\n0 #{length(objects) + 1}\n0000000000 65535 f \n" <> xref <>
      "trailer\n<< /Size #{length(objects) + 1} /Root 1 0 R >>\nstartxref\n#{byte_size(body)}\n%%EOF\n"
  end

  def fixture_bytes(name), do: File.read!(Path.expand("../../../../singularity_ingest/test/fixtures/documents/#{name}", __DIR__))

  defp private_document!(f) do
    document = KnowledgeFixtures.document!(f.source, %{title: @canary, media_type: f.media_type})
    id = Ecto.UUID.generate()
    env = %{f.envelope | job_id: id, correlation_id: id, causation_id: nil,
      idempotency_key: "document-extraction:" <> Ecto.UUID.load!(document.resource_version_id),
      payload: %{"resource_id" => Ecto.UUID.load!(document.resource_id),
        "resource_version_id" => Ecto.UUID.load!(document.resource_version_id)}}
    S.owner_query("""
      INSERT INTO core.outbox_events(id,event_type,idempotency_key,vault_id,principal_id,required_capability,
        principal_authorization_epoch,vault_authorization_epoch,classification,correlation_id,
        expected_entity_revision,envelope_version,payload,occurred_at)
      VALUES($1,'document.extraction_requested',$2,$3,$4,'asset.read',0,0,'private',$1,0,1,$5,CURRENT_TIMESTAMP)
      """, [Ecto.UUID.dump!(id), env.idempotency_key, f.source.vault_id, f.source.principal_id, env.payload])
    S.owner_query("""
      INSERT INTO jobs.job_submissions(id,vault_id,outbox_event_id,classification,idempotency_key,job_type)
      VALUES($1,$2,$1,'private',$3,'document_extract')
      """, [Ecto.UUID.dump!(id), f.source.vault_id, env.idempotency_key])
    %{f | document: document, envelope: env, request: %{f.request | job_id: id,
      resource_version_id: env.payload["resource_version_id"]}}
  end
end
```

- [ ] Parse/compile the complete appended blocks in memory with `ExUnit.start(autorun: false)` before any integration run. This detects syntax/API compile mistakes only and is never reported as tests executed.

### Task C2: Actual unsupported inputs, limits, transient failures, and claimed loss

- [ ] Append the entire following module. Large source/output cases have explicit test timeouts. The source-cap INSERT test uses one real administrative transaction and leaves the valid original fixture unchanged after the rejected insertion rolls back.

```elixir
defmodule Singularity.Runtime.DocumentOutcomeIntegrationTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  @moduletag :tmp_dir
  alias Singularity.Core.Error
  alias Singularity.Ingest.Documents.PDF
  alias Singularity.Runtime.KeyCustodian
  alias Singularity.Runtime.DocumentSourceIntegrationSupport, as: S
  alias Singularity.Runtime.DocumentOutcomeIntegrationSupport, as: C
  alias Singularity.Storage.{Fixtures, KnowledgeFixtures, MigrationRepo}
  setup context, do: C.setup(context)

  @tag plaintext: <<255>>
  test "actual invalid UTF-8 persists only unsupported invalid_utf8", %{fixture: f} do
    C.outcome!(f, :unsupported, "invalid_utf8")
  end

  for {name, code} <- [{"malformed.pdf", "malformed_document"},
        {"encrypted.pdf", "encrypted_document"},
        {"encrypted_pdf20_xref_stream.pdf", "encrypted_document"},
        {"empty.pdf", "no_extractable_text"}] do
    @tag plaintext: C.fixture_bytes(name)
    @tag media_type: "application/pdf"
    test "actual #{name} persists bounded #{code}", %{fixture: f} do
      C.outcome!(f, :unsupported, unquote(code))
    end
  end

  @tag plaintext: :binary.copy(" ", 67_108_859) <> "\ntail"
  @tag timeout: 120_000
  test "exact 64 MiB authenticated source reaches ready without source loss", %{fixture: f} do
    assert byte_size(f.plaintext) == 67_108_864
    assert {:ok, %{state: :ready, generation: 1}} = C.run(f)
    assert [[_, 0, "tail", _, %{"start_line" => 2, "end_line" => 2}]] = S.fragments(f)
    assert Enum.count(S.keys(f), &match?({:delivered, _}, &1)) == 16
    C.no_projection!(f)
    assert DynamicSupervisor.which_children(f.lease_supervisor) == []
  end

  test "canonical oversized INSERT is rejected with no partial Document or event", %{fixture: f} do
    resource = KnowledgeFixtures.uuid()
    version = KnowledgeFixtures.uuid()
    error = assert_raise Postgrex.Error, fn ->
      Fixtures.with_owner(fn ->
        query!(MigrationRepo, "UPDATE content.asset_objects SET plaintext_byte_size=67108865 WHERE id=$1", [f.source.object_id])
        KnowledgeFixtures.insert_document!(f.source, %{resource_id: resource,
          resource_version_id: version, source_byte_size: 67_108_865})
      end)
    end
    assert error.postgres.constraint == "document_versions_source_byte_size_check"
    assert [[0, 0, 0]] = S.owner_query("""
      SELECT (SELECT count(*) FROM content.resources WHERE id=$1),
        (SELECT count(*) FROM content.resource_versions WHERE id=$2),
        (SELECT count(*) FROM core.outbox_events WHERE payload->>'resource_id'=$3)
      """, [resource, version, Ecto.UUID.load!(resource)]).rows
    assert [[size]] = S.owner_query("SELECT plaintext_byte_size FROM content.asset_objects WHERE id=$1", [f.source.object_id]).rows
    assert size == byte_size(f.plaintext)
    S.pending!(f)
  end

  @tag timeout: 120_000
  test "actual PDF source cap rejects over 64 MiB before process work", %{fixture: f} do
    assert {:error, {:unsupported, "source_too_large"}} = PDF.extract(:binary.copy("x", 67_108_865))
    S.pending!(f)
    assert S.keys(f) == []
  end

  test "valid post-insert oversized object drift denies descriptor before custody", %{fixture: f} do
    assert %{num_rows: 1} = S.owner_query("UPDATE content.asset_objects SET plaintext_byte_size=67108865 WHERE id=$1", [f.source.object_id])
    assert {:error, %Error{code: :conflict, message: nil, details: %{}}} = C.run(f)
    refute :leased in S.keys(f)
    refute :c_claimed in S.keys(f)
    S.pending!(f)
  end

  @tag plaintext: :binary.copy("x", 16_777_217)
  @tag timeout: 120_000
  test "actual normalized text above 16 MiB persists unsupported output_too_large", %{fixture: f} do
    C.outcome!(f, :unsupported, "output_too_large")
  end

  @tag plaintext: Enum.map_join(1..256, "\n\n", fn _ -> :binary.copy("x", 65_536) end)
  @tag timeout: 120_000
  test "exact 16 MiB normalized output and 65536-byte fragments persist ready", %{fixture: f} do
    assert {:ok, %{state: :ready}} = C.run(f)
    fragments = S.fragments(f)
    assert length(fragments) == 256
    assert Enum.all?(fragments, fn [_, _, text, _, _] -> byte_size(text) == 65_536 end)
    assert Enum.sum(Enum.map(fragments, fn [_, _, text, _, _] -> byte_size(text) end)) == 16_777_216
    C.no_projection!(f)
  end

  @tag plaintext: :binary.copy("x", 65_537)
  test "65537-byte block splits into valid bounded deterministic fragments", %{fixture: f} do
    assert {:ok, %{state: :ready}} = C.run(f)
    assert [[_, 0, first, _, first_locator], [_, 1, second, _, second_locator]] = S.fragments(f)
    assert {byte_size(first), byte_size(second)} == {65_536, 1}
    assert first <> second == f.plaintext
    assert first_locator["kind"] == "fragment" and second_locator["kind"] == "fragment"
    C.no_projection!(f)
  end

  @tag plaintext: Enum.map_join(1..4096, "\n\n", fn _ -> "x" end)
  @tag timeout: 120_000
  test "4096 actual semantic fragments persist one complete ready set", %{fixture: f} do
    assert {:ok, %{state: :ready}} = C.run(f)
    assert length(S.fragments(f)) == 4096
    assert Enum.map(S.fragments(f), fn [_, ordinal, _, _, _] -> ordinal end) == Enum.to_list(0..4095)
    C.no_projection!(f)
  end

  @tag plaintext: Enum.map_join(1..4097, "\n\n", fn _ -> "x" end)
  test "4097 actual semantic fragments persist unsupported with no partial rows", %{fixture: f} do
    C.outcome!(f, :unsupported, "output_too_large")
  end

  @tag plaintext: C.pdf_bytes(4096)
  @tag media_type: "application/pdf"
  @tag timeout: 120_000
  test "actual 4096-page PDF persists complete page provenance", %{fixture: f} do
    assert {:ok, %{state: :ready}} = C.run(f)
    fragments = S.fragments(f)
    assert length(fragments) == 4096
    assert Enum.map(fragments, fn [_, _, _, _, locator] -> locator["page"] end) == Enum.to_list(1..4096)
    C.no_projection!(f)
  end

  @tag plaintext: C.pdf_bytes(4097)
  @tag media_type: "application/pdf"
  @tag timeout: 120_000
  test "actual 4097-page PDF persists unsupported page_limit", %{fixture: f} do
    C.outcome!(f, :unsupported, "page_limit")
  end

  for {mode, code} <- [timeout: "timeout", tool_exit: "extractor_failed"] do
    @tag plaintext: S.pdf_bytes()
    @tag media_type: "application/pdf"
    test "real owned subprocess #{mode} persists failed #{code}", %{fixture: f} do
      C.outcome!(f, :failed, unquote(code), mode: unquote(mode))
    end
  end

  for mode <- [:raise, :throw] do
    test "#{mode} private extractor diagnostic persists only failed extractor_failed", %{fixture: f} do
      C.outcome!(f, :failed, "extractor_failed", mode: unquote(mode))
    end
  end

  for loss <- [:custody, :storage] do
    test "already-claimed #{loss} loss fails exact attempt without re-claim or deadline extension", %{fixture: f} do
      {_source, attempt} = C.claim_by_interruption!(f)
      S.clear(f)
      case unquote(loss) do
        :custody ->
          assert {:ok, token} = KeyCustodian.begin_revoke(f.custodian, %{session_id: f.session_id})
          assert :ok = KeyCustodian.finish_revoke(f.custodian, token)
        :storage -> S.corrupt!(f, :missing)
      end
      assert {:ok, %{state: :failed, generation: 1}} = C.run(f)
      assert [["failed", 1, job, "plain_text", 1, started, deadline, nil]] = S.attempt_rows(f)
      assert job == Ecto.UUID.dump!(attempt.job_id)
      assert started == attempt.started_at and deadline == attempt.deadline_at
      refute :c_claimed in S.keys(f)
      refute :c_extract in S.keys(f)
      assert [["extractor_failed"]] = S.owner_query("SELECT failure_code FROM content.document_versions WHERE resource_version_id=$1", [f.document.resource_version_id]).rows
      assert S.fragments(f) == []
      C.no_projection!(f)
    end
  end

  for mode <- [:actual, :raise] do
    test "#{mode} post-claim final SQL fault rolls back terminal fields and all fragments", %{fixture: f} do
      assert {:error, %Error{code: :storage_unavailable, retryable?: true, message: nil, details: %{}}} =
        C.run(f, mode: unquote(mode), complete_fault?: true)
      assert [["extracting", 1, job, "plain_text", 1, started, deadline, nil]] = S.attempt_rows(f)
      assert job == Ecto.UUID.dump!(f.envelope.job_id)
      assert DateTime.diff(deadline, started, :microsecond) == 180_000_000
      assert S.fragments(f) == []
      C.no_projection!(f)
      assert [[nil, nil]] = S.owner_query("SELECT failure_code,attempt_finished_at FROM content.document_versions WHERE resource_version_id=$1", [f.document.resource_version_id]).rows
      assert File.exists?(f.path)
      assert DynamicSupervisor.which_children(f.lease_supervisor) == []
    end
  end
end
```

- [ ] With the parent's Mix-slot assignment, run the cumulative focused integration file, record actual executed/excluded counts and stop on unexpected failure. No production repair is authorized.

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs --seed 1208
```

Expected after C2: all 31 B plus 24 new C2 contracts execute; A's 43 unit contracts are excluded. Report actual output, never replace it with this expectation.

### Task C3: Tombstones, actual lifecycle races, replay, and SQL validation

- [ ] Append this full module. The expiry test deliberately spends up to one real 180-second deadline; its timeout is 240 seconds. Keep the shared Mix slot until it finishes. The process is test-owned and deadline waits occur outside SQL transactions. Retry/restore races use an actual paused worker, actual failed completion, actual guarded mutation, and a separately retained successor event/submission.

```elixir
defmodule Singularity.Runtime.DocumentOutcomeFencesIntegrationTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  @moduletag :tmp_dir
  alias Singularity.Core.Error
  alias Singularity.Runtime.DocumentSourceIntegrationSupport, as: S
  alias Singularity.Runtime.DocumentOutcomeIntegrationSupport, as: C
  alias Singularity.Runtime.Documents.ExtractionReconciler
  alias Singularity.Storage.Postgres.KnowledgeError
  setup context, do: C.setup(context)

  for mode <- [:actual, :raise] do
    test "claimed #{mode} completion survives Document tombstone while ordinary reads stay hidden", %{fixture: f} do
      C.live!(f)
      token = S.barrier!(f, :c_complete_before)
      runner = C.spawn_run(f, mode: unquote(mode))
      {pid, %{generation: 1, outcome: outcome}} = S.await_barrier!(f, :c_complete_before, token)
      assert pid == runner.pid
      assert outcome == if(unquote(mode) == :actual, do: :ready, else: :failed)
      S.tombstone!(f, :document)
      C.hidden!(f)
      send(pid, {token, :continue})
      assert {:ok, %{state: ^outcome, generation: 1}} = S.await_result!(runner)
      C.hidden!(f)
      C.no_projection!(f)
      if outcome == :ready, do: assert(S.fragments(f) == S.expected_fragments!(f, Singularity.Ingest.Documents.Text)), else: assert(S.fragments(f) == [])
      assert File.exists?(f.path)
      assert DynamicSupervisor.which_children(f.lease_supervisor) == []
    end
  end

  for operation <- [:retry, :restore] do
    test "actual #{operation} successor fences paused old ready fail claim and exhaustion", %{fixture: f} do
      token = S.barrier!(f, :c_complete_before)
      runner = C.spawn_run(f)
      {pid, %{outcome: :ready}} = S.await_barrier!(f, :c_complete_before, token)
      {source, attempt} = C.captured_attempt!(f)
      assert {:ok, %{state: :failed}} = C.complete(f, source, attempt, C.completion!(f, source, attempt, :failed))
      if unquote(operation) == :restore, do: S.tombstone!(f, :document)
      C.mutation!(f, unquote(operation))
      successor = C.successor!(f, 2)
      assert successor.envelope.job_id != f.envelope.job_id
      assert {:ok, %{state: :ready, generation: 3}} = C.run(successor)
      send(pid, {token, :continue})
      assert {:error, %Error{code: :conflict, message: nil, details: %{}}} = S.await_result!(runner)
      C.stale!(f, source, attempt)
      assert [[1]] = S.owner_query("SELECT count(*) FROM core.outbox_events WHERE idempotency_key=$1 AND vault_id=$2",
        [successor.envelope.idempotency_key, f.source.vault_id]).rows
      C.no_projection!(f)
    end
  end

  test "restoring pending Document emits successor and rejects original first claim", %{fixture: f} do
    token = S.barrier!(f, :claim_before)
    runner = S.spawn_run(f)
    {pid, _} = S.await_barrier!(f, :claim_before, token)
    S.tombstone!(f, :document)
    C.mutation!(f, :restore)
    successor = C.successor!(f, 1)
    send(pid, {token, :continue})
    assert {:error, %Error{code: :conflict}} = S.await_result!(runner)
    assert {:ok, %{state: :ready, generation: 2}} = C.run(successor)
    C.no_projection!(f)
  end

  test "restoring ready Document re-exposes identical result without reopening or event", %{fixture: f} do
    assert {:ok, receipt} = C.run(f)
    before = {S.attempt_rows(f), S.fragments(f)}
    count = S.owner_query("SELECT count(*) FROM core.outbox_events WHERE vault_id=$1", [f.source.vault_id]).rows
    S.tombstone!(f, :document)
    C.hidden!(f)
    C.mutation!(f, :restore)
    C.live!(f)
    assert {:ok, ^receipt} = C.run(f)
    assert {S.attempt_rows(f), S.fragments(f)} == before
    assert S.owner_query("SELECT count(*) FROM core.outbox_events WHERE vault_id=$1", [f.source.vault_id]).rows == count
  end

  @tag timeout: 240_000
  test "actual DB deadline expiry and concurrent recovery fence every old outcome and terminal callback", %{fixture: f} do
    {source, attempt} = C.claim_by_interruption!(f)
    before = S.attempt_rows(f)
    assert {:ok, 0} = ExtractionReconciler.run(%{repo: WorkerRepo})
    assert S.attempt_rows(f) == before
    C.wait_for_deadline!(f, attempt)
    C.stale!(f, source, attempt)
    assert S.attempt_rows(f) == before
    C.configure_runner!(f, handler_mode: {:error, Error.new(:storage_unavailable, retryable?: true)})
    assert {:error, %{code: :job_failed}} = Singularity.Storage.Jobs.GenericWorker.perform(C.job(f, 3, 3))
    assert S.attempt_rows(f) == before

    owner = self()
    token = make_ref()
    runners = Enum.map(1..2, fn _ ->
      {pid, monitor} = spawn_monitor(fn ->
        receive do
          {^token, :start} -> send(owner, {token, self(), ExtractionReconciler.run(%{repo: WorkerRepo})})
        after
          5_000 -> exit(:recovery_start_timeout)
        end
      end)
      on_exit(fn -> S.stop_owned(pid) end)
      {pid, monitor}
    end)
    Enum.each(runners, fn {pid, _} -> send(pid, {token, :start}) end)
    results = Enum.map(runners, fn {pid, monitor} ->
      assert_receive {^token, ^pid, result}, 5_000
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
      result
    end)
    assert Enum.sort(results) == [{:ok, 0}, {:ok, 1}]
    assert [["pending", 2, nil, nil, nil, nil, nil, nil]] = S.attempt_rows(f)
    C.stale!(f, source, attempt)
    assert {:error, %{code: :job_failed}} = Singularity.Storage.Jobs.GenericWorker.perform(C.job(f, 3, 3))
    assert [["pending", 2, nil, nil, nil, nil, nil, nil]] = S.attempt_rows(f)
    successor = C.successor!(f, 2)
    S.clear(successor)
    {_successor_source, successor_attempt} = C.claim_by_interruption!(successor)
    assert successor_attempt.generation == 3
    C.stale!(f, source, attempt)
    before_successor = S.attempt_rows(f)
    assert {:error, %{code: :job_failed}} = Singularity.Storage.Jobs.GenericWorker.perform(C.job(f, 3, 3))
    assert S.attempt_rows(f) == before_successor
    assert {:ok, %{state: :ready, generation: 3}} = C.run(successor)
    C.stale!(f, source, attempt)
    C.no_projection!(f)
    assert {:ok, 0} = ExtractionReconciler.run(%{repo: WorkerRepo})
    assert DynamicSupervisor.which_children(f.lease_supervisor) == []
  end

  test "actual complete exact replay is idempotent and conflicting valid replay leaves sealed rows unchanged", %{fixture: f} do
    {source, attempt} = C.claim_by_interruption!(f)
    completion = C.completion!(f, source, attempt)
    assert {:ok, receipt} = C.complete(f, source, attempt, completion)
    before = {S.attempt_rows(f), S.fragments(f)}
    assert {:ok, ^receipt} = C.complete(f, source, attempt, completion)
    assert {:ok, conflicting} = Singularity.Core.DocumentCompletion.new(%{completion | detected_language: "en"})
    assert {:error, %Error{code: :conflict}} = C.complete(f, source, attempt, conflicting)
    assert {S.attempt_rows(f), S.fragments(f)} == before
    C.no_projection!(f)
  end

  test "actual worker SQL independently rejects twelve invalid fragment sets without partial rows", %{fixture: f} do
    {source, attempt} = C.claim_by_interruption!(f)
    completion = C.completion!(f, source, attempt)
    [first, second] = C.json_fragments(completion)
    digest = completion.extracted_text_digest
    invalid = [
      {[], digest},
      {[first, %{second | "ordinal" => 0}], digest},
      {[first, %{second | "id" => first["id"]}], digest},
      {[first, %{second | "id" => "wrong-id"}], digest},
      {[first, %{second | "digest" => String.duplicate("00", 32)}], digest},
      {[first, %{second | "locator" => %{"version" => 1, "kind" => "pdf", "page" => 1}}], digest},
      {[first, %{second | "text" => ""}], digest},
      {[first, %{second | "text" => String.duplicate("x", 65_537)}], digest},
      {List.duplicate(first, 4097), digest},
      {List.duplicate(%{first | "text" => String.duplicate("x", 65_536)}, 257), digest},
      {[first, second], :crypto.hash(:sha256, "wrong aggregate")},
      {[first, Map.put(second, "private_extra", C.canary())], digest}
    ]
    assert length(invalid) == 12
    before = S.attempt_rows(f)
    for {fragments, hash} <- invalid do
      assert {:error, %Postgrex.Error{} = raw} = C.sql_complete(f, fragments, hash)
      assert %Error{code: :invalid, message: nil, details: %{}} = KnowledgeError.from(raw)
      assert S.attempt_rows(f) == before
      assert S.fragments(f) == []
      C.no_projection!(f)
    end
    assert {:ok, %{state: :ready}} = C.complete(f, source, attempt, completion)
    assert S.fragments(f) == S.expected_fragments!(f, Singularity.Ingest.Documents.Text)
  end
end
```

- [ ] Run the complete cumulative integration file using the exact C2 command. Expected new C3 contracts: 9. Verify real deadline duration, exact start/deadline identity, one successor event, every monitored process termination, and alias database/root cleanup. Do not replace the expiry case with a trigger bypass if it is slow.

### Task C4: Actual GenericWorker terminal routing and Oban Basic wake/snooze

- [ ] Append this full module. The handler's only fabricated values are deliberate failures; its terminal callback delegates to actual JobDispatcher/Extract/DocumentWorkerRepository. Global handler configuration is restored by on_exit and all cases are serial. The snooze case executes actual KeyCustodian wake and GenericWorker, then actual Basic acknowledgement; no replacement retry/wake implementation is introduced.

```elixir
defmodule Singularity.Runtime.DocumentOutcomeRunnerIntegrationTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  @moduletag :tmp_dir
  alias Singularity.Core.Error
  alias Singularity.Runtime.DocumentSourceIntegrationSupport, as: S
  alias Singularity.Runtime.DocumentOutcomeIntegrationSupport, as: C
  alias Singularity.Storage.Jobs.{GenericWorker, ObanAdapter}
  setup context, do: C.setup(context)

  for {retryable, attempt, maximum, expected} <- [
        {false, 1, 9, {:cancel, %{code: :job_failed}}},
        {true, 3, 3, {:error, %{code: :job_failed}}}] do
    test "actual GenericWorker #{if retryable, do: "final retryable", else: "immediate nonretryable"} callback fails only matching active attempt", %{fixture: f} do
      {_source, claimed} = C.claim_by_interruption!(f)
      S.clear(f)
      failure = Error.new(:storage_unavailable, retryable?: unquote(retryable),
        message: C.canary(), details: %{private: C.canary()})
      C.configure_runner!(f, handler_mode: {:error, failure})
      assert unquote(Macro.escape(expected)) == GenericWorker.perform(C.job(f, unquote(attempt), unquote(maximum)))
      assert [{:c_callback, _, metadata}] = Enum.filter(S.events(f), &(elem(&1, 0) == :c_callback))
      assert metadata == %{attempt: unquote(attempt), max_attempts: unquote(maximum)}
      assert [{:c_terminal_result, _, {:ok, %{state: :failed, generation: 1}}}] =
        Enum.filter(S.events(f), &(elem(&1, 0) == :c_terminal_result))
      assert [["failed", 1, job, "plain_text", 1, started, deadline, nil]] = S.attempt_rows(f)
      assert job == Ecto.UUID.dump!(claimed.job_id)
      assert started == claimed.started_at and deadline == claimed.deadline_at
      assert S.fragments(f) == []
      C.no_projection!(f)
      refute :leased in S.keys(f)
    end
  end

  test "nonfinal retryable GenericWorker error never invokes terminal hook", %{fixture: f} do
    C.claim_by_interruption!(f)
    before = S.attempt_rows(f)
    S.clear(f)
    C.configure_runner!(f, handler_mode: {:error, Error.new(:storage_unavailable, retryable?: true)})
    assert {:error, %{code: :job_failed}} = GenericWorker.perform(C.job(f, 2, 3))
    refute :c_callback in S.keys(f)
    refute :c_terminal in S.keys(f)
    assert S.attempt_rows(f) == before
    assert S.fragments(f) == []
    C.no_projection!(f)
  end

  @tag locked?: true
  test "terminal callback cannot turn unclaimed locked pending work into failed", %{fixture: f} do
    C.configure_runner!(f, handler_mode: {:error, Error.new(:job_failed)})
    assert {:cancel, %{code: :job_failed}} = GenericWorker.perform(C.job(f, 1, 1))
    assert [{:c_terminal_result, _, {:ok, :unchanged}}] = Enum.filter(S.events(f), &(elem(&1, 0) == :c_terminal_result))
    S.pending!(f)
    refute :leased in S.keys(f)
    assert S.progress(f) == []
  end

  for terminal <- [:ready, :failed, :unsupported] do
    test "terminal GenericWorker exhaustion leaves #{terminal} receipt and fragments unchanged", %{fixture: f} do
      S.terminal_receipt!(f, unquote(terminal))
      before = {S.attempt_rows(f), S.fragments(f)}
      S.clear(f)
      C.configure_runner!(f, handler_mode: {:error, Error.new(:storage_unavailable, retryable?: true)})
      assert {:error, %{code: :job_failed}} = GenericWorker.perform(C.job(f, 3, 3))
      assert [{:c_terminal_result, _, {:ok, :unchanged}}] = Enum.filter(S.events(f), &(elem(&1, 0) == :c_terminal_result))
      assert {S.attempt_rows(f), S.fragments(f)} == before
      refute :leased in S.keys(f)
      C.no_projection!(f)
    end
  end

  test "old logical job exhaustion cannot overwrite another job's active successor", %{fixture: f} do
    S.seed_terminal!(f, :failed)
    C.mutation!(f, :retry)
    successor = C.successor!(f, 2)
    S.clear(f)
    {_source, attempt} = C.claim_by_interruption!(successor)
    assert attempt.generation == 3
    before = S.attempt_rows(f)
    S.clear(f)
    C.configure_runner!(f, handler_mode: {:error, Error.new(:job_failed)})
    assert {:cancel, %{code: :job_failed}} = GenericWorker.perform(C.job(f, 1, 1))
    assert [{:c_terminal_result, _, {:ok, :unchanged}}] = Enum.filter(S.events(f), &(elem(&1, 0) == :c_terminal_result))
    assert S.attempt_rows(f) == before
    assert S.fragments(f) == []
    C.no_projection!(f)
  end

  test "actual authority denial propagates from exhaustion and GenericWorker cancels", %{fixture: f} do
    C.claim_by_interruption!(f)
    before = S.attempt_rows(f)
    S.owner_query("UPDATE core.principal_capabilities SET revoked_at=CURRENT_TIMESTAMP WHERE principal_id=$1 AND vault_id=$2",
      [f.source.principal_id, f.source.vault_id])
    assert {:error, %Error{code: :forbidden, message: nil, details: %{}}} = C.exhaustion(f)
    C.configure_runner!(f, handler_mode: {:error, Error.new(:storage_unavailable, retryable?: true)})
    assert {:cancel, %{code: :job_failed}} = GenericWorker.perform(C.job(f, 3, 3))
    assert S.attempt_rows(f) == before
    assert S.fragments(f) == []
  end

  test "actual recorder SQL error propagates rather than becoming unchanged", %{fixture: f} do
    C.claim_by_interruption!(f)
    before = S.attempt_rows(f)
    assert {:error, %Error{code: :storage_unavailable, retryable?: true, message: nil, details: %{}}} = C.exhaustion(f, recorder_fault?: true)
    S.clear(f)
    C.configure_runner!(f, recorder_fault?: true, handler_mode: {:error, Error.new(:job_failed)})
    assert {:error, %{code: :job_failed}} = GenericWorker.perform(C.job(f, 1, 1))
    assert [{:c_terminal_result, _, {:error, %Error{code: :storage_unavailable}}}] = Enum.filter(S.events(f), &(elem(&1, 0) == :c_terminal_result))
    assert S.attempt_rows(f) == before
    assert S.fragments(f) == []
    C.no_projection!(f)
  end

  @tag locked?: true
  @tag wake?: true
  test "actual unlock wake shortens snooze and Basic restores attempt without max_attempts change", %{fixture: f} do
    assert [[4, 37, json, "running"]] = S.seed_v4!(f)
    name = elem(f.wake, 1)
    assert {:ok, id} = ObanAdapter.submit(%{oban_name: name}, f.envelope)
    id = String.to_integer(id)
    conf = Oban.config(name)
    assert {:ok, meta} = Oban.Engines.Basic.init(conf, queue: "document_extract", limit: 1)
    assert {:ok, {meta, [%Oban.Job{id: ^id, attempt: 1} = fetched]}} = Oban.Engines.Basic.fetch_jobs(conf, meta, %{})
    maximum = fetched.max_attempts
    C.configure_runner!(f)
    token = S.barrier!(f, :c_waiting_saved)
    owner = self()
    result_token = make_ref()
    {pid, monitor} = spawn_monitor(fn ->
      send(owner, {result_token, :result, GenericWorker.perform(%{fetched | conf: conf})})
    end)
    on_exit(fn -> S.stop_owned(pid) end)
    {^pid, :saved} = S.await_barrier!(f, :c_waiting_saved, token)
    assert [[4, 37, ^json, "waiting_for_unlock"]] = S.progress(f)
    assert :ok = S.activate!(f)
    assert [[1, 0]] = S.owner_query("SELECT wake_requested_generation,wake_consumed_generation FROM jobs.job_submissions WHERE id=$1",
      [Ecto.UUID.dump!(f.envelope.job_id)]).rows
    send(pid, {token, :continue})
    assert_receive {^result_token, :result, {:snooze, 1}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
    refute :c_callback in S.keys(f)
    refute :c_terminal in S.keys(f)
    S.pending!(f)
    assert [[1, 1]] = S.owner_query("SELECT wake_requested_generation,wake_consumed_generation FROM jobs.job_submissions WHERE id=$1",
      [Ecto.UUID.dump!(f.envelope.job_id)]).rows
    assert :ok = Oban.Engines.Basic.snooze_job(conf, fetched, 1)
    assert [["scheduled", 0, ^maximum, %{"snoozed" => 1}]] = S.owner_query("SELECT state,attempt,max_attempts,meta FROM jobs.oban_jobs WHERE id=$1", [id]).rows
    assert [[4, 37, ^json, "waiting_for_unlock"]] = S.progress(f)
    S.owner_query("UPDATE jobs.oban_jobs SET state='available' WHERE id=$1", [id])
    assert {:ok, {_meta, [%Oban.Job{id: ^id, attempt: 1, max_attempts: ^maximum} = resumed]}} = Oban.Engines.Basic.fetch_jobs(conf, meta, %{})
    assert :ok = GenericWorker.perform(%{resumed | conf: conf})
    assert :ok = Oban.Engines.Basic.complete_job(conf, resumed)
    assert [["completed", 1, ^maximum]] = S.owner_query("SELECT state,attempt,max_attempts FROM jobs.oban_jobs WHERE id=$1", [id]).rows
    assert [[4, 37, ^json, "running"]] = S.progress(f)
    refute :c_callback in S.keys(f)
    C.no_projection!(f)
  end
end
```

- [ ] Run the exact cumulative integration command. Expected new C4 contracts: 11. Expired/recovered and active recovered-successor GenericWorker cases are in C3's single real-deadline contract. These are not counted twice. Report callback metadata separately from canonical generation.

### Task C5: Actual logs, telemetry, public errors, and persisted metadata privacy

- [ ] Append this whole module. Read `elixir-observability/SKILL.md` and `references/examples.md` before adding these tests. Handlers only forward events to the test PID and are detached using unique IDs. The tests invoke the real Oban Executor with acknowledgement, not a synthetic call to a telemetry callback. Logs, configured Repo query events, bounded RLS denial, Oban events, public results and persisted outbox/progress/runner/audit metadata are checked together.

```elixir
defmodule Singularity.Runtime.DocumentOutcomePrivacyIntegrationTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag :wake?
  @moduletag :private_title?
  @moduletag plaintext: "# CANARY_C_PRIVATE_TITLE_SOURCE_LOCATOR_TOOL_SQL\n\nprivate body"
  @moduletag media_type: "text/markdown"
  import ExUnit.CaptureLog
  alias Singularity.Core.Error
  alias Singularity.Runtime.DocumentSourceIntegrationSupport, as: S
  alias Singularity.Runtime.DocumentOutcomeIntegrationSupport, as: C
  alias Singularity.Storage.{DispatcherRepo, MigrationRepo, PreAuthRepo, SafeSQL}
  alias Singularity.Storage.Jobs.ObanAdapter
  setup context, do: C.setup(context)

  test "real ready runner stores private canonical content but no metadata surface leaks it", %{fixture: f} do
    capture_private!(f, [], :success)
    assert [[C.canary()]] == S.owner_query("SELECT title FROM content.document_versions WHERE resource_version_id=$1", [f.document.resource_version_id]).rows
    assert Enum.any?(S.fragments(f), fn [_, _, text, _, locator] ->
      String.contains?(text, C.canary()) and String.contains?(inspect(locator), C.canary())
    end)
  end

  test "actual source authentication failure exposes no source title or key through runner errors", %{fixture: f} do
    S.corrupt!(f, :data)
    assert {:error, %Error{code: :integrity_failure, message: nil, details: %{}}} = C.run(f)
    capture_private!(f, [], :cancelled)
    S.pending!(f)
    assert S.fragments(f) == []
  end

  test "actual post-claim SQL diagnostic and parameter failure remains private in Oban persisted errors", %{fixture: f} do
    assert {:error, %Error{code: :storage_unavailable, message: nil, details: %{}}} = C.run(f, complete_fault?: true)
    capture_private!(f, [complete_fault?: true], :failure)
    assert [["extracting", 1, _, _, _, _, _, nil]] = S.attempt_rows(f)
    assert S.fragments(f) == []
    C.no_projection!(f)
  end

  for mode <- [:raise, :throw] do
    @tag media_type: "text/plain"
    test "#{mode} private extractor exception remains bounded through real successful runner receipt", %{fixture: f} do
      capture_private!(f, [mode: unquote(mode)], :success)
      assert [["failed", 1, _, _, _, _, _, nil]] = S.attempt_rows(f)
      assert S.fragments(f) == []
      C.no_projection!(f)
    end
  end

  for mode <- [:raise, :throw] do
    test "#{mode} private handler fallback produces real sanitized Oban exception without terminal hook", %{fixture: f} do
      capture_private!(f, [handler_mode: unquote(mode)], :failure)
      refute :c_callback in S.keys(f)
      S.pending!(f)
    end
  end

  for mode <- [:timeout, :tool_exit] do
    @tag plaintext: S.pdf_bytes()
    @tag media_type: "application/pdf"
    test "actual #{mode} private tool failure produces no stderr or source metadata leakage", %{fixture: f} do
      capture_private!(f, [mode: unquote(mode)], :success)
      assert [["failed", 1, _, _, _, _, _, nil]] = S.attempt_rows(f)
      assert S.fragments(f) == []
      C.no_projection!(f)
    end
  end

  @doc false
  def event(event, measurements, metadata, {owner, token}),
    do: send(owner, {token, :event, event, measurements, metadata})

  defp capture_private!(f, options, expected_state) do
    C.configure_runner!(f, options)
    name = elem(f.wake, 1)
    assert {:ok, id} = ObanAdapter.submit(%{oban_name: name}, f.envelope)
    id = String.to_integer(id)
    conf = Oban.config(name)
    assert {:ok, meta} = Oban.Engines.Basic.init(conf, queue: "document_extract", limit: 1)
    assert {:ok, {_meta, [%Oban.Job{id: ^id} = fetched]}} = Oban.Engines.Basic.fetch_jobs(conf, meta, %{})
    audit_before = audit(f)
    token = make_ref()
    handler = {__MODULE__, token}
    repos = [WorkerRepo, RequestRepo, DispatcherRepo, PreAuthRepo, MigrationRepo]
    query_events = Enum.uniq(Enum.map(repos, &(&1.config()[:telemetry_prefix] ++ [:query])))
    denial = [:singularity, :authorization, :rls_denial]
    retry_event = [:singularity, :job, :retry]
    failure_event = [:singularity, :job, :failure]
    events = query_events ++ [denial, retry_event, failure_event,
      [:oban, :job, :start], [:oban, :job, :stop], [:oban, :job, :exception]]
    assert Enum.any?(:telemetry.list_handlers([:oban, :job, :exception]),
      &(&1.id == Singularity.Runtime.Observability.Telemetry))
    assert :ok = :telemetry.attach_many(handler, events, &__MODULE__.event/4, {self(), token})
    on_exit(fn -> :telemetry.detach(handler) end)
    owner = self()
    logs = capture_log(fn ->
      execution = conf |> Oban.Queues.Executor.new(%{fetched | conf: conf}, ack: true) |> Oban.Queues.Executor.call()
      send(owner, {token, :execution, execution})
      assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
        SafeSQL.query(WorkerRepo, "SELECT title FROM content.document_versions WHERE title=$1", [C.canary()])
    end)
    assert_receive {^token, :execution, execution}, 5_000
    assert execution.state == expected_state
    captured = drain(token, [])
    assert Enum.any?(captured, fn {event, _, _} -> event == [:oban, :job, :start] end)
    assert Enum.any?(captured, fn {event, _, metadata} -> event == denial and metadata == %{repo: :worker} end)
    terminal_event = if expected_state == :failure, do: [:oban, :job, :exception], else: [:oban, :job, :stop]
    assert Enum.any?(captured, fn {event, _, _} -> event == terminal_event end)
    refute Enum.any?(captured, fn {event, _, _} -> event in query_events end)
    bounded_event = case expected_state do
      :failure -> retry_event
      :cancelled -> failure_event
      :success -> nil
    end
    if bounded_event do
      assert Enum.any?(captured, fn {event, measurements, metadata} ->
        event == bounded_event and measurements == %{count: 1} and
          metadata == %{attempt: fetched.attempt, max_attempts: fetched.max_attempts,
            queue: :unknown, worker: :generic_worker}
      end)
    else
      refute Enum.any?(captured, fn {event, _, _} -> event in [retry_event, failure_event] end)
    end
    secrets = [C.canary(), "runtime_c_private_failure", f.plaintext,
      inspect(f.domain_key), Base.encode16(f.domain_key), Base.encode64(f.domain_key)]
    public = inspect(execution.result, limit: :infinity, printable_limit: :infinity)
    telemetry = inspect(captured, limit: :infinity, printable_limit: :infinity)
    persisted = persisted(f, id)
    for secret <- secrets do
      refute String.contains?(logs, secret)
      refute String.contains?(public, secret)
      refute String.contains?(telemetry, secret)
      refute String.contains?(inspect(persisted, limit: :infinity, printable_limit: :infinity), secret)
    end
    assert audit(f) == audit_before
    assert :ok = :telemetry.detach(handler)
    assert DynamicSupervisor.which_children(f.lease_supervisor) == []
  end

  defp drain(token, events) do
    receive do
      {^token, :event, name, measurements, metadata} -> drain(token, [{name, measurements, metadata} | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp audit(f), do: S.owner_query("SELECT metadata FROM audit.events WHERE vault_id=$1 ORDER BY id", [f.source.vault_id]).rows

  defp persisted(f, id) do
    assert [[payload]] = S.owner_query("SELECT payload FROM core.outbox_events WHERE id=$1", [Ecto.UUID.dump!(f.envelope.job_id)]).rows
    assert Map.keys(payload) |> Enum.sort() == ["resource_id", "resource_version_id"]
    assert [[args, meta, errors]] = S.owner_query("SELECT args,meta,errors FROM jobs.oban_jobs WHERE id=$1", [id]).rows
    assert args["payload"] == payload
    checkpoint = case S.owner_query("SELECT checkpoint FROM jobs.job_progress WHERE submission_id=$1", [Ecto.UUID.dump!(f.envelope.job_id)]).rows do
      [] -> nil
      [[value]] -> value
    end
    outbox_rows = S.owner_query("SELECT to_jsonb(e) FROM core.outbox_events e WHERE vault_id=$1 ORDER BY id", [f.source.vault_id]).rows
    submission_rows = S.owner_query("SELECT to_jsonb(s) FROM jobs.job_submissions s WHERE vault_id=$1 ORDER BY id", [f.source.vault_id]).rows
    progress_rows = S.owner_query("SELECT to_jsonb(p) FROM jobs.job_progress p WHERE vault_id=$1 ORDER BY id", [f.source.vault_id]).rows
    runner_rows = S.owner_query("SELECT to_jsonb(j) FROM jobs.oban_jobs j WHERE args->>'vault_id'=$1 ORDER BY id", [f.vault_id]).rows
    audit_rows = S.owner_query("SELECT to_jsonb(a) FROM audit.events a WHERE vault_id=$1 ORDER BY id", [f.source.vault_id]).rows
    assert outbox_rows != [] and submission_rows != [] and runner_rows != []
    %{outbox: payload, args: args, meta: meta, errors: errors, checkpoint: checkpoint,
      outbox_rows: outbox_rows, submission_rows: submission_rows, progress_rows: progress_rows,
      runner_rows: runner_rows, audit_rows: audit_rows}
  end
end
```

- [ ] Run the exact cumulative integration command. Expected new C5 contracts: 9. Actual metadata is intentionally inspected without truncation. The worker path currently emits no audit event; equality of owner audit rows before/after is evidence for that absence, not a claim that a fabricated event proves privacy. Outbox/submission/runner and Oban start/terminal/RLS events supply positive observed surfaces. Do not add observability production code.

### Task C6: Complete scoped gates, cleanup, frozen prefix, reviews, and handoff

- [ ] Acquire the shared Mix slot and run the entire integration file without module filtering. Expected 31 B + 53 C = 84 integration contracts, with 43 A unit exclusions. C's expiry test takes approximately one real attempt lifetime. Report actual test counts and outcomes. Do not use plain `mix test` as integration evidence.

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs --seed 1208
```

- [ ] Run the unchanged actual custody/storage prerequisite regressions and the mandatory Asset/application regressions, serialized in the same shared slot.

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs --seed 1208
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_unlock_resume_test.exs apps/singularity_runtime/test/singularity/runtime/job_dispatcher_asset_events_test.exs apps/singularity_runtime/test/singularity/runtime/application_test.exs --seed 1208
```

Expected integration executed counts are 166 (113 prerequisites + 53 C) and 101 (48 B/Asset/application prerequisites + 53 C), respectively. Every mandatory existing contract remains asserted. Record exclusions exactly. An outside-scope required failure is listed and stops affected work; do not fix it.

- [ ] Every integration alias prints a concrete `database=` and `storage_root=`. After that invocation finishes, independently query `pg_database` using that exact observed database literal and test that exact observed root's absence. For the preparation prerequisite main already ran the following concrete checks; execution repeats their structure using each newly printed exact name, not this historical name:

```sh
devenv shell -- psql -U singularity_migration -d postgres -At -c "SELECT count(*) FROM pg_database WHERE datname = 'singularity_test_dda6b9ffca0c3d4a20f4b5c9'"
test ! -e /tmp/singularity/integration/dda6b9ffca0c3d4a20f4b5c9
```

Expected database count 0 and root absent. Capture exact commands and results in parent evidence. Never infer cleanup from exit 0. Do not stop borrowed services or delete a broad directory. If the alias leaves an owned environment, report BLOCKED_ENV and exact targets before any cleanup action.

- [ ] Format only the C additions, preserve every existing byte, and run focused formatting/unit/architecture/xref checks. A whole-file formatter is permitted only if exact prefix comparison proves it left the frozen A/B bytes unchanged.

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix format apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix format --check-formatted apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_unlock_resume_test.exs apps/singularity_runtime/test/singularity/runtime/job_dispatcher_asset_events_test.exs apps/singularity_runtime/test/singularity/runtime/application_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs --seed 1208
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix xref graph --format cycles --fail-above 0
git diff --check
git diff --stat
git status --short
```

Expected 80 unit/architecture contracts execute unchanged; B/C integration modules are excluded under the unit command. Xref must report no cycles with the seven-application dependency graph preserved. No full README gate, E2E or phase/release acceptance is implied.

- [ ] Prove the frozen entire B file is still an exact prefix and inspect the exact append:

```sh
elixir -e 'path = "apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs"; {baseline, 0} = System.cmd("git", ["show", "5be1e515ef9315933aed4bd7c65dc2b6abc4ed23:" <> path]); true = Base.encode16(:crypto.hash(:sha256, baseline), case: :lower) == "373ad3d5fcfdd07ae522f00a037caa6efabbfba5f060c6c9685fb7d71da14178"; true = String.starts_with?(File.read!(path), baseline); IO.puts("frozen 2191-line A/B prefix unchanged")'
git diff --numstat -- apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs
git diff -- apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs
```

- [ ] Report test source SHA, production source SHA separately, all actual counts/commands/exclusions, process and alias cleanup, scoped diff, counter values and risks. Finish all owned commands and explicitly release the Mix slot. Main personally reads the final complete test append, independently rechecks it, then arranges fresh spec review followed by quality review. Worker does not commit. Main separately decides whether Task 12 is qualified; no full Phase 2/release completion claim.

## Mandatory coverage mapping and finite contract ledger

| Mandatory contract | Executable location |
| --- | --- |
| Invalid UTF-8 and actual malformed/encrypted/PDF2/no-text PDFs | C2 first five tests; actual Poppler |
| Source cap without impossible oversized canonical row | C2 exact 64 MiB ready, canonical INSERT rejection, actual adapter oversize, valid metadata drift |
| Normalized output/fragment count/per-fragment/page bounds | C2 actual 16 MiB and overflow, 65536/65537-byte blocks, 4096/4097 fragments and real PDFs |
| Timeout/transient tool error/raised/thrown private diagnostics | C2 actual owned child fault pair and raise/throw pair; C5 real runner/log captures |
| Existing extracting custody/storage loss; no new claim/deadline extension | C2 real interrupted claim followed by revocation/missing ciphertext |
| Final ready/failed persistence rollback; no partial fragments/search | C2 final actual SQL-fault pair and C3 twelve SQL-validation vectors |
| Ready and failed completion after claimed tombstone; ordinary reads hidden | C3 actual paused completion pair with live RequestRepo control and hidden reads |
| Actual recovery/expiry and stale claim/complete/fail/exhaustion | C3 real deadline and concurrent reconciler passes, stale writes before/after recovery and after successor |
| Actual retry/restore race and ready restore | C3 paused worker/failed completion/guarded mutation pair, pending restore and ready restore |
| Immediate nonretryable/final retryable GenericWorker callbacks | C4 terminal pair, actual terminal SQL and exact original attempt timestamps |
| Locked pending/terminal/expired/recovered/other active job unchanged | C4 pending/three terminal/active other-job; C3 expired/recovered/active recovered-successor runner callbacks |
| Authority/storage failures propagate | C4 direct public recorder errors plus actual GenericWorker normalized result and observed recorder result |
| Nonfinal retry and snooze never terminal; Basic attempt/max; wake60→1 | C4 nonfinal contract and real unlock/waiting barrier, GenericWorker, Basic fetch/snooze/resume |
| Exact and conflicting completion replay | C3 actual complete replay then validated language conflict |
| Content/title/locator/tool/SQL/key privacy across all surfaces | C5 nine cases, actual Executor acknowledgements/logs/telemetry/metadata, canonical positive controls |
| Actual WorkerRepo, complete canonical/events/submissions/custody, outside transactions | C1 composition and B's frozen actual helpers; C1/C2 assertions |
| Owned processes, exact environment cleanup, no frozen changes or Vault work | C1 monitored runners, C3 concurrent scanners, C4 runner, C6 exact checks |

Finite new registered tests: C2 24, C3 9, C4 11, C5 9; total 53. C3's invalid-fragment test additionally specifies 12 independent SQL rejection vectors against the same retained active claim. Existing A43 and B31 remain frozen. The expiry case is counted once even though it checks expired, recovered, and successor states. Registration was verified during preparation with autorun disabled; no C test execution is claimed.

## Preparation-only final checkpoint

- [x] Read all governing requirements against the mapping above; retain every A/B mandatory C ledger item.
- [x] Parse every complete block and compile in memory with autorun disabled, inspect every compiler warning and registered contract count. Never execute tests or allocate a database during this check.
- [x] Check every referenced source API, fixture path, SQL signature, expected constraint, callback/error shape, and process ownership. Scan for placeholders and unsafe fixture shortcuts.
- [x] Confirm the only worker-owned difference is this new plan; parent-owned evidence stays preserved and the frozen test hash is unchanged.
- [ ] Stop for main's full personal read and explicit C TEST GO. No C test/production edits, acceptance, external writes or continuing later phases are authorized at this checkpoint.

Preparation validation on 2026-10-09 used the existing built dependency/application modules and compiled only in memory. This command completed exit 0, with no compiler warnings, five complete Elixir blocks and registered counts 24/9/11/9 = 53. `ExUnit.start(autorun: false)` prevents test execution; no application, Repo, database, or Mix task was started. This is syntax/module-registration evidence, not runtime acceptance:

```sh
elixir -pa '_build/test/lib/*/ebin' -e 'ExUnit.start(autorun: false); target = Path.expand("apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs"); existing = File.read!(target); suffix = existing |> String.split("defmodule Singularity.Runtime.DocumentSourceIntegrationSupport", parts: 2) |> List.last(); Code.compile_string("defmodule Singularity.Runtime.DocumentSourceIntegrationSupport" <> suffix, target); path = "docs/superpowers/plans/2026-10-09-singularity-v0.2-document-extraction-runtime-outcomes-integration.md"; blocks = Regex.scan(~r/```elixir\n(.*?)\n```/s, File.read!(path), capture: :all_but_first); counts = Enum.with_index(blocks, 1) |> Enum.flat_map(fn {[code], index} -> Code.string_to_quoted!(code); modules = Code.compile_string(code, target); counts = for {module, _} <- modules, function_exported?(module, :__ex_unit__, 0), do: {module, length(module.__ex_unit__().tests)}; IO.inspect({index, counts}); counts end); true = Enum.sum(Enum.map(counts, &elem(&1, 1))) == 53; IO.puts("five blocks compiled; 53 registered C tests; autorun disabled; no tests or database operations")'
```

`git diff --check` completed exit 0. The frozen test SHA-256 still equals the value above; `git status --short` showed this new plan as the only difference. Every owned command finished. Failed production repair rounds and Astra attempts remain 0. The material constraint/risk is the required real approximately 180-second expiry test; all behavioral assertions remain unexecuted until explicit C TEST GO and fresh scoped integration evidence. The worker stops here for main review; main retains approval and execution authority.
