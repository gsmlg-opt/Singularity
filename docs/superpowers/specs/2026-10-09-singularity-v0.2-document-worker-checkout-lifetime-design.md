# Document worker checkout lifetime repair design

Date: 2026-10-09. Status: accepted bounded architecture under the user's standing
approval and instruction to select the recommended next move. Implementation is
held until main reads the complete executable plan and issues scoped GO.

## Evidence and purpose

Task 12's real C2 integration run exposed two production-path failures: the exact
64 MiB authenticated source and exact 16 MiB extracted output lose their checked-
out PostgreSQL connection. After the separate one-line fixture setup correction,
31 B and 22 C2 contracts passed; these two cases failed with a checkout longer
than 15,000 ms. The failing assertions remain unchanged.

WorkerScope currently obtains a default checkout through VaultLock.with_shared
and retains it across source reading, normalization, fragmentation and completion,
outside SQL transactions. The installed Ecto SQL 3.14.0, DBConnection 2.10.2 and
Postgrex 0.22.4 reuse that checked-out connection. A larger outer timeout alone
would also loosen effective nested SQL timing. This is application composition,
not an evidenced dependency defect.

A fresh Astra architecture worker traced the installed checkout, holder deadline,
Postgrex receive and borrower-death cleanup paths. Its read-only assessment is not
a repair attempt or test result. Failed Sol production repairs and Astra repair
attempts are both zero; user-authorized Astra repair attempts remain capped at 3.

## Decision and exact production boundary

Only production file:
`apps/singularity_storage/lib/singularity/storage/jobs/worker_scope.ex`.

Add a closed `job_type: "document_extract"` branch before the existing generic
shared-lock fallback. Other job types, including backup, retain their existing
paths unchanged. No configurable timeout, injected repository or caller option.

1. Reject pre-existing WorkerRepo checkout with sanitized `Error.new(:invalid)`
   before changing settings or acquiring locks. Nested checkout cannot replace
   the existing deadline and cannot establish exclusive session-setting ownership.
2. Obtain a fresh WorkerRepo checkout with fixed `timeout: 300_000`.
3. Read and validate the nonnegative millisecond integer for `statement_timeout`
   from `pg_catalog.pg_settings`. Preserve that exact integer for restoration.
4. Install 15,000 ms if the saved value is zero; otherwise install the smaller of
   the saved value and 15,000. Arm restoration before installation begins.
5. Call existing `VaultLock.with_shared_checked_out/3`. Retain the existing
   AuthorizationLock and envelope-bound ScopedRepo transaction closure.
6. Release existing locks in the existing order, then restore the saved timeout
   before returning this connection to the pool.

Use existing SafeSQL for parameter-free settings queries, with installed public
simple-query options `query_type: :text, timeout: 15_000`. Any generated setting
literal comes only from the validated integer, never caller input. The complete
plan must characterize the actual installed API and exact result shapes.

No Vault file or semantics, key/capability/custody change, schema/migration,
privilege grant, Runtime extractor, GenericWorker, retry/wake behavior or global
repository configuration change is authorized.

## Timing and failure semantics

The fixed five-minute checkout resource budget consists of the existing maximum
60-second source lease, 180-second canonical attempt window and 60 seconds of
orchestration/cleanup allowance. PDF's 120-second bound is inside post-claim work,
not an additional attempt extension. Same-job resume keeps its original start,
generation and database deadline. No canonical timestamp resets.

This is not a guaranteed aggregate worker SLA. Contention, scheduling and CPU work
may still exhaust the finite budget and fail closed. Server statement_timeout
preserves a per-statement SQL execution/lock-wait ceiling; it does not guarantee
the same 15-second client wall-clock bound over a broken network. The outer
checkout deadline is the finite network/lifetime backstop. This distinction is
accepted explicitly, not described as identical timeout behavior.

Normal callback returns, returned failures, exceptions and throws must restore
the session setting and otherwise retain existing propagation behavior. If
restoration raises, throws, exits or returns an invalid result, terminate the
current checkout-owning worker with `Process.exit(self(), :kill)`. This exceptional
untrappable termination must occur while it still owns the fresh checkout. It
prevents catchable unwinding/checkin with uncertain session state.

Installed DBConnection borrower-death handling disconnects the transferred holder;
actual-role tests must prove the owned backend disappears, session advisory locks
release and later borrowers have clean settings. No disconnect_all, pool restart,
arbitrary backend signalling, retries, cleanup suppression or compensating write
on another connection. Lost attempts remain subject to existing canonical fences
and recovery. Source inspection alone does not establish this cleanup contract.

## Alternatives considered

- Bare outer timeout widening: smaller patch, but no independent short SQL cap.
- Global WorkerRepo timeout: simpler configuration, but changes unrelated jobs.
- Release/reacquire locks around extraction: avoids long checkout, but changes the
  accepted authority/locking architecture and introduces new races.

The closed Document checkout plus local statement cap is recommended because it
addresses the reproduced cases without those broader behavior changes.

## Required focused contracts and gates

New test file:
`apps/singularity_storage/test/singularity/storage/document_worker_scope_test.exs`.
Keep existing C2 and all frozen A/B assertions unchanged.

- Actual Document callback survives beyond 15 seconds on the same checked-out
  backend, outside a transaction; both shared advisory locks remain held and
  subsequently release.
- Real SQL exceeding 15 seconds is cancelled; an existing stricter statement
  timeout remains effective. No temporary grants or timeout hooks.
- Save/restore the exact session setting on success, returned failure, exception,
  throw and transaction rollback. Prove same-backend reuse and absent request GUCs.
- Kill a monitored borrower; prove its exact backend disappears, locks release,
  and a subsequent borrower has clean settings.
- Force loss of only the test-owned backend inside the callback, then allow real
  restoration to fail. No successful result/checkin; prove cleanup. Distinguish
  this actual connection-loss proof from source reasoning for still-live reset
  failure; do not invent successful cleanup using a fake repository.
- Reject nested Document entry before settings/locks change.
- Characterize unchanged non-Document behavior and existing checkout limit.
- Exercise the actual fixed 300-second outer expiry once using a deadline-derived
  bounded timer and monitored worker, no production timeout override. Prove exact
  backend/lock cleanup and absence of late mutation.
- Rerun unchanged exact-size C2 cases and the complete scoped Runtime integration
  file; retain resume/deadline, authority, stale-generation, Asset/application,
  architecture and zero-cycle contracts.

Use the existing isolated integration alias, one shared Mix command at a time.
Record actual counts, exclusions, exact temporary database/root cleanup and every
owned process termination. Borrowed services remain running. No E2E. A required
unexpected failure is retained before repair; no assertion weakening.

Main must read the complete executable test/production plan before test or repair
GO. Independent spec and quality review plus fresh exact-source verification are
required before accepting the repair. No Task 12, Phase 2, release, merge, push,
tag, publication or deployment acceptance is implied.
