# Phase 2 Document Worker Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the approved Task 12 SQL and adapter bridge under actual WorkerRepo privileges, then compose Runtime extraction after its source-replay dependency is resolved.

**Architecture:** Four security-definer SQL wrappers independently bind scoped live authority to a retained outbox event and project bounded descriptors/receipts from existing lifecycle operations. A separate worker adapter owns short transactions through WorkerScope's envelope-bound closure. Runtime retains the approved describe → lease/digest → claim → extract → complete sequence with the selected fresh Document extraction lease; actual restart evidence remains required before acceptance.

**Tech Stack:** Elixir/OTP 28, Ecto/Postgrex, PostgreSQL 17, Oban 2.24, existing Text/Markdown/PDF extraction and Poppler guardian, ExUnit, devenv.

**Readiness:** Reviewed bounded planning draft, not an execution-ready code plan.
The historical lifecycle failure is resolved by a separate authorized repair.
Before production implementation, code steps require complete focused contracts and SQL/Elixir
bodies under the writing-plans self-review gate. No unchecked item is accepted
or waived by this document.

---

## Authority and dependencies

Follow the [approved amendment](../specs/2026-10-08-singularity-v0.2-phase-2-worker-bridge-proposal.md) and existing Phase 2 Task 12. Execute only in `/home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-2-import-extraction`, branch `codex/v0.2-phase-2-import-extraction`. Source was inspected at `e6397e7e940a9ff6bf6b96764dafd010059fc6a3`; coordinating-agent HEAD is now `2b037f1`. Recheck current diff before editing; other workers own approval/status and Notes contract changes.

The [worker baseline](../../verification/2026-10-08-phase-2-worker-baseline.md), committed at `9cf809b`, records the historical outside-scope lifecycle failure: `apps/singularity_storage/test/singularity/storage/document_lifecycle_test.exs:206` expected pending generation 1 and observed 2; 19 tests, 1 failure. The full unit suites passed, seed 710289. The corrected focused integration command failed; an earlier command used an incorrect `postgres/` path and its zero exit is not passing evidence. The owner subsequently authorized a separate [lifecycle repair](../../verification/2026-10-08-document-lifecycle-generation-repair.md), committed at `cf87c7e`, which corrects the stale contract and passes the focused checks. Preserve the original failure evidence; that repair does not establish bridge or Phase 2 acceptance.

Standing owner approval authorizes this amendment and bounded design resolution without routine approval prompts. E2E remains prohibited. No release, push, publication, deployment, production activation, Vault change, Asset lease change, public repository type change, GenericWorker change, historical migration edit, or canonical/lifecycle grant expansion is authorized by this plan.

### Runtime source-replay design dependency

`KeyLease.read_chunk/2` requires exactly the persisted next index (`key_lease.ex:499–516`); each successful read persists the increment before returning bytes (`:824–830`). A new v4 Document lease loads that persisted index (`:1016–1021`). `CustodyRepository.load_checkpoint_version/4` initializes index zero only when no progress row exists (`custody_repository.ex:171–211`). No existing API restarts a consumed same-job checkpoint.

After partial preclaim reading or postclaim process death, lost in-memory bytes cannot be reconstructed through the old same-job lease. Metadata claim/resume can preserve deadline and work after tombstone, but that does not prove Runtime can reread original bytes. The selected [fresh-read design](../specs/2026-10-08-singularity-v0.2-document-source-replay-design.md) uses a new closed purpose and sequential-only ephemeral worker mode. It shares no mutable checkpoint and needs no new incarnation/CAS fence. Do not reset/delete progress, call `Progress.put_state` as an unfenced reset, substitute RequestRepo/request leases, invent a new job ID, durably cache plaintext, or alter Asset/Vault semantics. Keep an actual real-custody regression for this gap; fake resume cannot satisfy it. Tasks 1–6 do not implement this extension; Task 7 needs its detailed executable contracts and real restart evidence.

## Ownership and order

| File | Responsibility |
| --- | --- |
| `apps/singularity_storage/priv/repo/migrations/20261008000000_document_worker_bridge.exs` | New forward migration: four exposed wrappers and an ungranted helper. |
| `apps/singularity_storage/lib/singularity/storage/postgres/document_worker_repository.ex` | Internal typed adapter and `record_exhaustion/4`. |
| `apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs` | Actual WorkerRepo security, lifecycle, races, privacy; local admin fixtures only. |
| `apps/singularity_runtime/lib/singularity/runtime/documents/extract.ex` | Existing planned Task 12 pipeline, after replay architecture resolution. |
| `apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs` | Fake stage contracts, real custody vertical, terminal dispatch. |
| Runtime `job_dispatcher.ex`, `application.ex` | Exact Document route/dependencies/terminal callback. |
| `apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs` | Exact approved worker registration allowances, preserving negative cases. |

Preserve `DocumentRepository`, `DocumentPinnedSource`, `GenericWorker`, `WorkerScope`, `ScopedRepo`, storage custody adapters and all committed migrations. Task 7 alone has the fresh-read design's additional shared Runtime file boundary. Coordinator owns governing amendments and `notes_scope_contract_test.exs`. SQL → adapter → exhaustion → adversarial review is sequential; independent review/test preparation may run in parallel without overlapping file ownership.

### Task 1: Confirm baseline and add a no-grant red contract

- [ ] Verify `pwd`, `git branch --show-current`, `git rev-parse HEAD`, `git status --short`, `git diff --stat`; preserve pre-existing edits. Run `rg --files apps/singularity_storage/priv/repo/migrations | rg '20261008000000'`; no match is expected. Resolve timestamp collision before creating a migration.
- [ ] Create the storage test using `Singularity.Storage.DataCase, async: false` and `@moduletag :integration`. Build fixtures with `KnowledgeFixtures.prepared_source!/0`, convert UUID fields to binary for `KnowledgeFixtures.document!/1`, and use `Fixtures.with_owner/1` plus `MigrationRepo` only to insert capability/event/fixture rows. Never call `KnowledgeTestGrants`.
- [ ] Insert a real `document.extraction_requested` event: IDs-only exact payload, `asset.read`, private, envelope version 1, current epochs, expected revision 0, key `document-extraction:<version>`. Use its UUID as envelope job ID; Oban runner ID is unrelated. Existing `document_pinned_source_test.exs:event!/3` is a source pattern, but its arbitrary idempotency key is unsuitable here.
- [ ] Add the failing call and privilege assertion using explicit existing scope composition:

```elixir
assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
  SafeSQL.query(WorkerRepo, "SELECT resource_version_id FROM content.document_versions LIMIT 0")
assert {:ok, {:source, %{state: :pending, generation: 0}}} =
  WorkerRepo.checkout(fn ->
    context = %{repo_handle: WorkerRepo, transact: fn options, callback ->
      ScopedRepo.transact(WorkerRepo, envelope, options, callback)
    end}
    DocumentWorkerRepository.describe(context, envelope)
  end)
```

- [ ] Run the new storage file with the scoped integration command in Task 8; record missing adapter/function as agreed red, not a repair failure. The known lifecycle failure remains separately recorded.

### Task 2: Add exact SQL signatures, authority binding, and descriptor

- [ ] Create the unique forward migration module `Singularity.Storage.Migrations.DocumentWorkerBridge`, set local role to `singularity_table_owner` in `up/0`, and make `down/0` raise `Ecto.MigrationError, "Document worker bridge migration is forward-only"`. Do not execute until all four wrappers and ACLs are present.
- [ ] Define six leading arguments in this order: `requested_resource uuid, requested_version uuid, requested_job uuid, expected_revision bigint, requested_principal_epoch bigint, requested_owner_epoch bigint`. Add only:

```text
content.describe_document_worker(B)
content.claim_document_worker(B, adapter text, format integer)
content.complete_document_worker(B, claimed_generation bigint, adapter text, format integer,
  media_type text, fragments jsonb, extracted_digest bytea, language text)
content.fail_document_worker(B, claimed_generation bigint, adapter text, format integer,
  media_type text, outcome text, failure_code text)
```

- [ ] Each wrapper is explicit `LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = pg_catalog, content, core, identity`. An ungranted `content.document_worker_target(B, lock_rows boolean)` helper may share validation; internal composite values never cross an exposed result. No authority or row-lock helper runs in a DECLARE initializer.
- [ ] Parse nonempty principal/owner GUCs as UUIDs, catch malformed UUIDs as authority denial, reject missing/negative epochs/revision and maximum bigint before computing n+1, and reject `current_setting('transaction_isolation') <> 'read committed'`. Acquire this lock in its own statement before querying authority:

```sql
PERFORM pg_catalog.pg_advisory_xact_lock_shared(pg_catalog.hashtextextended(
  'singularity:authorization:' || scoped_principal::text || ':' || scoped_owner::text, 0));
```

- [ ] Query `core.live_principal_authorization()` (definition in `20260718000800_add_task11_authorization_functions.exs:1466`): live owner principal, active account, unrevoked membership, private/sensitive/restricted clearance, asset.read, exact current nonnegative epochs. Ignore `vault_locked`; require no session/custody for metadata or terminal operations.
- [ ] Independently bind retained event ID/owner/principal/type/capability/private/envelope_version=1, both epochs, revision and exact two-key JSON payload; key is `document-extraction:<version>` at 0, otherwise `document-extraction:<version>:<n>`. Delivered timestamps do not invalidate it. Bind Document/resource/resource-version owner/private/kind/creator identity. Mutation lock order is resource then version, followed by event/target/fence recheck.
- [ ] Describe explicit columns: `kind text, resource_id uuid, resource_version_id uuid, job_id uuid, state text, generation bigint, object_id uuid, object_generation bigint, source_digest bytea, source_byte_size bigint, media_type text, adapter_name text, format_version integer, started_at timestamptz, deadline_at timestamptz`. Terminal n+1/same-job returns only receipt columns and NULL for all nine source/attempt columns.
- [ ] Source descriptor uses one consistent query: live pending at n or same-job extracting at n+1 with future DB deadline, including tombstoned extracting. Join available same-owner object and exact active key binding as `DocumentPinnedSource.generation/3`: envelope object/owner/domain; domain-version ID/owner/domain/state; domain ID/owner/classification/state/kind=content. Require exactly one binding, positive key generation, source/object size equality in 0..64 MiB, 32-byte digest and approved media. No Asset-liveness predicate. Stale/expired/deleted-before-claim results fail with recognized lifecycle conflict.

### Task 3: Add claim/resume, terminal delegation, and exact ACLs

- [ ] Claim returns explicit resource/version/job/generation/state/adapter/format/start/deadline columns. For pending, delegate to existing `claim_document_extraction(version,n,job,adapter,format)` only after validation/locks; its live-only lock must reject deletion between describe and claim.
- [ ] For same-job resume use `lock_document_terminal_extraction(version,job,n+1)` from `20260922000110_document_terminal_tombstone.exs`, then require matching adapter/format and future DB deadline. Return unchanged start/deadline; do not delegate resume to the live-only claim function.
- [ ] Complete/fail return exactly resource/version/job/generation/state. Require claimed generation n+1 and exact adapter/format/media under terminal lock. Delegate to existing complete/fail internals from `20260922000100_document_extraction_attempts.exs`; preserve canonical fragment validation, atomicity, deadline fences and exact ready replay. A conflicting ready replay fails; different/recovered attempts cannot write outcomes.
- [ ] Apply ACLs to exact signatures, including all type arguments. Each exposed wrapper is owned by table owner, EXECUTE revoked from PUBLIC/web/dispatcher/pre-auth and granted only to worker. Revoke all runtime execution of the private helper. Existing table/RLS/raw lifecycle ACLs and definitions remain unchanged.
- [ ] Add red→green SQL tests: exact columns/terminal NULLs; catalog owner/search path/volatility/security-definer; exact ACLs including PUBLIC via `aclexplode`; worker denied SELECT/INSERT/UPDATE/DELETE and raw lifecycle/helper calls; claim once/resume unchanged; resume/complete/fail after tombstone; first-claim deletion; ready replay/conflict. Verified calls use WorkerRepo, never MigrationRepo.

### Task 4: Implement bounded adapter types and short trusted transactions

- [ ] Create `Singularity.Storage.Postgres.DocumentWorkerRepository`, without public Documents.Repository behaviour. Define `receipt()` fields resource/version/job/generation/terminal state; `attempt()` adds extracting/adapter/format/start/deadline; `source()` adds object/key generation/digest/size/media and nullable attempt metadata. Closed state/kind allowlists only; never partial DocumentVersion or dynamic atom conversion.
- [ ] Define `describe(context,envelope)`, `claim(context,envelope,adapter,format)`, `complete(context,envelope,source,attempt,completion)`, `record_exhaustion(context,envelope,error,runner_metadata)`. `describe/2` returns `{:ok,{:source,source}}` or `{:ok,{:terminal,receipt}}`; claim returns typed attempt; complete returns receipt.
- [ ] Validate envelope with existing EnvelopeCodec roundtrip and UUID validation; parameters come only from envelope. Reject malformed/extra payload and unsafe n+1 arithmetic before serialization. Decode exactly one row and the exact ordered output-column list; validate UUIDs, generation/state, bounded metadata and nullable shape. Compare returned identity/fences with the authenticated envelope.
- [ ] Require checked-out WorkerRepo handle and `transact/2` closure, reject an existing transaction, and call only `transact.([], phase)`. ScopedRepo already queries before callback; do not SET isolation there or pass unsupported `:read_committed`. SQL's isolation guard fails closed when connection default differs.

```elixir
with false <- WorkerRepo.in_transaction?(), true <- WorkerRepo.checked_out?() do
  context.transact.([], fn repo ->
    case SafeSQL.query(repo, statement, parameters) do
      {:ok, result} -> decode_result.(result)
      {:error, exception} -> {:error, KnowledgeError.from(exception)}
    end
  end)
else
  _ -> {:error, Error.new(:invalid)}
end
```

- [ ] Before serialization call `DocumentCompletion.new/1`, compare owner/private/resource/version/generation/adapter/format/media with envelope+source+attempt, and reject mismatches rather than replacing identities. Serialize fragments matching the existing private `DocumentRepository.completion_args/1` locator/digest shape; do not call or expose that private function. No new locator/public API. Use SafeSQL and KnowledgeError only; never raw exception diagnostics/parameters.
- [ ] Add adapter tests for nesting/missing context/RequestRepo substitution, fake callback overrides, completion identity mismatch and closed decoders. On a reused connection assert principal/owner GUCs absent after successful commit and recognized rollback; preserve GenericWorker reserved dependency-key rejection and ScopedRepo exceptional cleanup semantics.

### Task 5: Add active-current-attempt-only exhaustion

- [ ] Add red tests for pending, terminal, expired, other-job, recovered and newly claimed successor outcomes: all unchanged. A same-job unexpired n+1 attempt alone becomes failed/extractor_failed, preserving generation/start/deadline and leaving zero fragments/search rows. Authority/storage errors propagate.
- [ ] Implement `record_exhaustion/4`: describe without lease; extracting descriptor supplies typed attempt; construct `DocumentCompletion` with fixed failed/extractor_failed and current trusted envelope identity, then invoke the same fail wrapper through `complete/5`. No fifth SQL entrypoint. Recognized lifecycle conflict alone becomes `{:ok,:unchanged}`; no blanket error swallowing.
- [ ] Run storage tests, review exact SQL/adapter diff independently, and repair only approved new files. No public DocumentRepository exhaustion method; no GenericWorker normalization change.

### Task 6: Adversarial authority, snapshots, races, and privacy

- [ ] Add actual-role cases for absent/malformed scope, cross owner/principal/resource/version, revoked principal/membership/account, capability denial, stale epochs, forged event fields/extra payload/key/revision/version, creator mismatch and bigint overflow. Valid clearance values all authorize; invalid clearance fixtures must respect existing schema constraints, not disable them.
- [ ] Prove post-wait snapshot freshness: admin exclusive xact advisory lock + uncommitted revocation; separate scoped WorkerRepo wrapper waits; observe its ungranted advisory lock via pg_locks; commit revocation; wrapper denies. Use bounded mailbox barriers and test-owned tasks. Test direct REPEATABLE READ/SERIALIZABLE transactions reject all four functions without mutation; set isolation before any query in those manual test transactions.
- [ ] Race deletion/read/claim and claimed tombstone completion; expire start+deadline consistently, run existing reconciler, and assert stale claim/complete/fail/exhaustion cannot affect successor. Exercise existing retry/restore guarded operations only as admin fixture setup, without worker grants. Same-job metadata resume retains its original deadline.
- [ ] Reach SQL fragment validation directly: malformed/duplicate ordinals, wrong IDs/digests/locator/media, 4097 fragments, oversized fragment/aggregate, empty content and conflicting replay; assert atomic rollback/no partial fragments/no Document-version search rows. Adapter validation alone does not prove SQL validation.
- [ ] Capture logs, configured Repo telemetry, bounded RLS-denial telemetry and public errors across canary content/tool-output/SQL failures; assert no title/fragments/bytes/keys/SQL parameters escape. Detach handlers and finish test-owned tasks in cleanup. Keep source Asset's pre-existing projection distinct from Document projection counts.
- [ ] Run scoped bridge/custody integration tests; record evidence and independent security review before Runtime wiring. The separate lifecycle repair resolves the historical baseline mismatch, not these new bridge requirements.

### Task 7: Runtime pipeline with the selected fresh-read extension

- [ ] Follow the selected fresh-read design: extend Runtime `key_custodian.ex` and `download_lease.ex`, plus `document_custody_test.exs` and `download_lease_test.exs`, only for the new Document extraction purpose. Add preserving `put_progress_state/3` to the planned worker adapter and its tests. Keep storage custody bindings, old KeyLease/v4, generic progress/wake and Asset semantics unchanged. Expand these into exact red/green code steps before implementation. No custody modification belongs to Tasks 1–6.
- [ ] Add fake Runtime stage contracts with local fully defined module-or-context-tuple adapters: terminal receipt avoids lease; locked custody snoozes 60 without claim; bounded source read checks size/digest before claim; lease revoked on success/error before external extraction; same-job attempt deadline unchanged; stale attempt cannot complete/fail. For nonempty sources read the exact expected chunk count at 4,194,304 bytes/chunk and verify exact length plus canonical digest; no EOF sentinel exists. For zero bytes require the new-mode-only `DownloadLease.authenticate_empty_document_source/1` before hashing/claiming, never a zero-read shortcut. Its internal authorized `read_range(:all)` must authenticate the loaded zero-size object header/final record, require empty output, return `:ok` and consume the lease. Public full/ranged reads stay denied. Add real valid/missing/corrupted empty-object tests and nonempty-binding rejection; no failure may claim. Keep the exact 64-MiB bound. Do not claim full nonempty-container authentication from chunk APIs.
- [ ] Implement approved five stages outside long DB transactions. Existing adapters: Text.extract/1, Markdown.extract/1, PDF.extract/2. Map source_too_large→input_too_large, page_limit_exceeded→page_limit, extractor_timeout→timeout; preserve valid canonical reasons and map unknown/raised/tool output to failed/extractor_failed. Build DocumentFragment/DocumentCompletion through existing constructors, enforce their bounded output, persist atomically, return typed receipt.
- [ ] Add only `document_worker_repository` and fixed extractor mappings to Application dependencies, one document_extract dispatcher route, and a terminal `handle_failure/4` delegation to adapter record_exhaustion. Existing GenericWorker invokes it for immediate typed nonretryable/final retryable errors; earlier retryable errors and snooze never invoke it. Test both cases plus wake shortening to 1 and actual Oban snooze attempt restoration, without equating runner attempts and generation.
- [ ] Prove one real vertical: admin fixture creates actual encrypted original and wrapped DEK, real persisted session and submission, real KeyCustodian/CustodyReader/LocalFilesystemAdapter, actual WorkerScope/WorkerRepo, source Asset deletion, legitimately delivered event, describe→lease→digest→claim→extract→complete, terminal duplicate receipt. No grants/fake Reader/admin verified calls. Add real consumed-checkpoint/process-death regression and recovery/deletion races; acceptance requires passing real restart evidence.
- [ ] Permit only exact new worker terms in architecture contract, keep Asset worker regressions, capture privacy evidence, and independently review final wiring. Raised/thrown worker death remains reconciler recovery, not a promised terminal recorder invocation.

### Task 8: Exact scoped verification and handoff

- [ ] Services are already ready per coordinator evidence. If a later execution finds them absent: `devenv processes list`; start this worktree with `devenv up -d`, bounded `devenv processes wait --timeout 120`, then `devenv shell -- bash apps/singularity_storage/priv/repo/bootstrap_roles.sh`. Record ownership; stop only execution-owned services. Do not run these during plan authoring.
- [ ] Use shared deps with worktree-local `_build`, never share MIX_BUILD_PATH. Integration alias allocates/drops its own isolated database; plain mix test excludes integration tags.

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_unlock_resume_test.exs apps/singularity_runtime/test/singularity/runtime/job_dispatcher_asset_events_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix compile --warnings-as-errors
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix xref graph --format cycles --fail-above 0
git diff --check
git diff --stat
git status --short
```

- [ ] Run `mix format --check-formatted` with the exact changed Elixir paths from the ownership table, then scoped tests above; do not run nonexistent files before their task creates them. Record actual failures/exclusions, commands, source SHA, migration timestamp, changed files, review findings/repairs, zero xref cycles/seven-app graph, no temporary grants, no Vault feature or Asset behavior changes, the explicit Document-only shared custody file extension, and finished commands/test-owned cleanup.
- [ ] Full Task 12 acceptance is blocked by unresolved real source replay or failing required scoped gates. The historical lifecycle baseline is repaired; full Phase 2 acceptance separately needs the complete README gate. E2E is unrun under owner restriction. Do not imply release readiness, silently repair outside scope, or continue to later phases. Hand off reviewable small diffs; commits require coordinator authorization, and this documentation-only assignment performs no staging/commits.

## Coordinator self-review

The coordinator read the entire draft and approved amendment. SQL/ACL/event,
bounded receipt, transaction isolation, exhaustion, privacy and actual-role
requirements map to Tasks 1–6. Task 7 maps the separately selected fresh-read
extension; no reset/incarnation workaround is assumed. Corrected the private
serializer reference and process-list command. Remaining readiness gap: complete
test/implementation code for the outlined steps, including new-mode reader
lifetime and checkpoint-preserving progress, is not supplied here. This draft
must not be represented as ready for unattended production implementation.
Independent design review additionally found that zero data chunks bypass
storage authentication. The selected design and Task 7 now require the explicit
authenticated empty-source operation and real corruption contracts instead.
