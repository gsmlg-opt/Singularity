# Phase 2 Task 15: bounded backup qualification design

Date: 2026-10-09

Status: fixture prerequisite repaired and reviewed; new test qualification GO.
Source inspected: `dfe60aa11ac471da243e0523a33a23b0bf426276` in
`.trees/v0.2-phase-2-import-extraction`.

## Purpose and authority

Characterize the existing Task 2 backup guard for Task 15: supported legacy
exports succeed, unsupported canonical inventory refuses both exporter
entrypoints, owner scopes remain isolated, and the guard observes the export's
repeatable-read snapshot. This is test qualification, not a new backup feature.
The active Phase 2 design's “Backup compatibility and activation” section and
Task 2 remain authoritative. Phase 5 owns V3 backup and restore.

The user selected recommended design choices automatically. The review sequence
is written design and plan, complete parent read, fresh Astra design review,
then a bounded test-only GO. A source defect or failed prerequisite pauses its
affected work; this document does not authorize a production fix.

## Existing baseline failure and bounded prerequisite

The parent ran the unchanged `logical_exporter_test.exs`: 11 tests, one failure.
The existing Document refusal case failed in `DocumentRepository.create_pending/2`
with `:forbidden`, before either backup assertion. The other ten tests passed.
The test runner's disposable database and root were subsequently gone.

Source explains two missing fixture prerequisites. `Fixtures.vault_fixture!/1`
inserts a vault using `locked = true` by default. `KnowledgeFixtures.prepared_source!/0`
neither unlocks that fixture nor assigns `asset.read`.
`DocumentRepository.authorization_epochs/2`, reached by `request_extraction/2`,
requires `vault_locked = false` and `asset.read`. The existing
`DocumentRepositoryTest.grant_asset_read!/1` supplies exactly those conditions.

The permitted repair is local to the owning backup test: before its existing
`create_pending/2` call, establish those same fixture prerequisites with
`Fixtures.with_owner/1`. Keep the repository call, temporary grants, title
canary, unsupported refusal, real-worker checks, and other-owner success.
Do not replace this regression with raw SQL Document creation. This is existing
fixture authorization compatibility, not a change to Vault or capability
semantics. Re-run that case and then the whole owning file before adding new
qualification. Any remaining failure is a new stop-and-report point.

## File boundary and alternatives

Recommended: surgical additions to
`apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs`.
Its private helpers already establish a valid owner export closure, wrapper,
`backup.create`, legacy Note conflict, valid cut, and snapshot binding. Reuse
them without extracting or refactoring shared support.

A focused companion file would separate concerns but duplicate substantial
private legacy-export setup. Moving setup into support would broaden this
qualification into a refactor. Neither alternative is selected.

Allowed changes are that test file, these two qualification documents, and the
parent-owned Task 15 evidence matrix. Existing assertions remain intact.
Production, migrations, support, configuration, dependencies, frozen extraction
and restart tests, and the original untracked C integration plan are excluded.
`logical_schema_v2.ex` must remain byte-identical to the inspected source.
No Vault feature, key, custody, capability-policy, activation, V3, browser,
release, push, merge, tag, or deployment work is authorized.

## Live guard contract

Inspect the installed function by exact signature
`content.backup_has_unsupported_canonical_rows(uuid)` through the real worker
connection. Require `current_user = singularity_worker`, `prosecdef = true`,
`provolatile = s`, boolean return type, owner `singularity_table_owner`, and
`proconfig = ARRAY['search_path=pg_catalog, content, core']`.

Require worker EXECUTE; deny effective EXECUTE to web, dispatcher, and pre-auth.
Inspect the exploded ACL for PUBLIC (grantee zero), accounting for a null ACL
with `acldefault('f', proowner)`. For each of the eight omitted tables, assert
the worker lacks direct SELECT after fixture grants have closed. Never grant
worker SELECT to make export pass. Check the live function body contains the
eight owner-scoped EXISTS predicates and the established live-authorization
check. This structural inventory check complements behavioral evidence; it
does not prove independently reached branches of PostgreSQL's OR expression.

Keep the existing unauthorized and cross-owner raw predicate assertions,
including SQLSTATE `42501` through `:insufficient_privilege` and savepoint
rollback. At exporter entrypoints, valid worker context with the requested
foreign owner or missing `backup.create` must produce the existing sanitized
storage-unavailable error, not row information. Use a correctly shaped,
current-snapshot cut for `records/2` so malformed-cut validation cannot mask
the guard. Run each expected SQL error in a separate transaction or savepoint.

## Legal omitted inventory

Each case commits its fixture before assertions and verifies the exact
nonzero omitted-table inventory as table owner. Keep constraints and triggers
enabled; no pending receipts left uncommitted, orphan rows, disabled triggers,
session replication changes, or deletion of required parents.

| Target | Legal fixture | Independent unsupported case? |
| --- | --- | --- |
| `document_versions` | `KnowledgeFixtures.document!(source)` without receipt | Yes |
| `document_fragments` | `ready_document!(source)` using existing guarded lifecycle | No: Document required |
| `document_import_receipts` | completed receipt referencing a committed Document | No: Document required; pending receipt cannot commit |
| `note_attachments` | source Note attached to another supported Note, ordinal 0 | Yes |
| `note_citations` | Note citation with exact locator of a ready Document fragment | No: Document and fragment required |
| `tags` | owner-local private tag with creator principal | Yes |
| `resource_tags` | supported Note plus owner-local tag | No: tag required |
| `relationships` | two supported Notes, `related_to`, no target version needed | Yes |

Use separate fresh owner scopes for the cases. A raw source from
`KnowledgeFixtures.source!/0` can be made export-capable with the existing
`seed_export_rows!/1`; it has no active wrapper before that helper runs.
Use `KnowledgeFixtures.note!/1` for supported Note parents. Do not call
`seed_export_rows!/1` on a prepared source that already has an active key
version. Keep the established setup owner as the clean control.

Before insertion, both owners export successfully. After insertion, both
`snapshot_cut/2` and `records/2` for the target return exactly
`{:error, Error.new(:backup_unsupported)}` (`message: nil`, `details: %{}`,
`retryable?: false`). Assert complete equality and absence of title, tag,
label, fragment, and locator canaries applicable to that fixture.
The clean owner still succeeds at both entrypoints; materialize its record
stream inside its transaction and verify owner-scoped decoded rows.

For target `records/2`, bind the established valid test cut to the transaction's
current snapshot independently of `snapshot_cut/2`. A refused cut must not
prevent executing the records guard. Preserve existing legacy deterministic
ordering, counts, descriptors, wrapper and privacy assertions.

Report all eight targets as inventory coverage, but only the four independent
cases as independent omitted-inventory refusal. Composite fixtures cannot
establish isolated coverage of the dependent EXISTS branches.

## Deterministic repeatable-read proof

Use the existing complete legacy fixture. The writer inserts only a private
tag, avoiding new source-custody setup. The main process owns the worker read
transaction; a monitored, unlinked task owns a separate MigrationRepo connection through
`Fixtures.with_owner/1`. No grants are open during worker observations.

1. Establish the reader's repeatable-read snapshot explicitly with
   `txid_current_snapshot()` and capture `pg_backend_pid()`.
2. Obtain a successful cut, attach `manifest_id`, and fully materialize records.
   This creates the exact legacy baseline within the established snapshot.
3. Release the waiting writer with a unique reference-tagged message. It inserts
   and commits a canary tag for that same owner, records its backend PID, and
   reports success only after `Fixtures.with_owner/1` returns from commit.
4. The reader waits with a finite timeout; assert distinct backend PIDs and
   matching reference. The old snapshot identifier remains equal. A new cut
   within that old transaction succeeds; compare stable cut fields only because
   `snapshot_id` is deliberately regenerated. Calling `records/2` with the
   original cut still succeeds and materializes exactly the previous bytes
   and inventory. The tag is absent from those bytes.
5. End the reader transaction. Confirm the committed tag by owner query.
   In a fresh repeatable-read worker transaction both entrypoints return the
   exact unsupported error. Construct the records cut using that new snapshot;
   reusing the old cut would only prove snapshot-mismatch rejection.

Use bounded receive/Task.await/Task.shutdown and SQL statement/lock timeouts;
never use sleeps, retries, shared Sandbox ownership, or timing assumptions.
Use a test-supervised Task.Supervisor and async_nolink so writer failure reaches
the reader as a monitored result and cannot kill it before cleanup runs.
The writer must not create fixtures before the reader establishes its snapshot.
The writer task owns its MigrationRepo supervisor. On all exits, stop/await the
writer before leaving the test; verify a recorded supervisor PID has terminated
or stop that exact surviving PID with a bounded call. Do not stop shared repos.
Persisted fixtures belong to the disposable database and are removed by the
existing runner; do not bypass immutable-row cleanup rules.

## Verification and evidence limits

Use the scoped integration runner; ordinary `mix test` excludes this module.
Record the baseline failure separately, the fixture repair result, new test
names, exact commands and results, catalog observations, legal inventory
classification, and snapshot barrier ordering in the Task 15 matrix.
Use focused test iterations and one final whole-file run, plus formatter and
diff checks limited to changed files. Existing V2 schema must show no diff.

No full README gate, E2E, real bundle publication/restore, full Phase 2
acceptance, or production backup acceptance follows from this slice. Mark each
NOT RUN. Stop if a valid fixture cannot be constructed without broader changes,
the unchanged baseline cannot pass after its documented setup repair, the
guard differs from this contract, or either exporter leaks canonical content.
