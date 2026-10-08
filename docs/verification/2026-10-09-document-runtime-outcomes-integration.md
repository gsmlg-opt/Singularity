# Document Runtime outcome/recovery integration verification

Date: 2026-10-09. Status: mandatory C preparation only; no C test or production
GO. Task 12, Phase 2 and full release acceptance remain open.

## Current state and previous-turn audit

The previous goal turn made concrete progress, not merely a wait: source
integration was committed at `5be1e515ef9315933aed4bd7c65dc2b6abc4ed23`,
independently spec/quality reviewed and tested on that exact commit (113 scoped
integration and 80 unit/architecture contracts, zero failures, 48 exclusions in
each mode, zero xref cycles). Evidence was committed at
`33e9bdae575f531f8f907a3a4157bf314feb99a8`.

Main rechecked current authoritative state: the Phase 2 worktree was clean at
`33e9bdae575f531f8f907a3a4157bf314feb99a8`, branch
`codex/v0.2-phase-2-import-extraction`, in the existing project-local linked
worktree. Root main was clean and unchanged at
`e866990fc0ee8682d139d70da9cbf5aff9b2ae2b`. The C preparation worker was confirmed
live by the agent-status tool; it must not be restarted on an observation timeout.

The full release definition of done is not established: later search,
organization, attachments/citations, backup V3/backward restore/upgrade, browser
workflow and exact-source multi-architecture artifacts remain open. The goal
remains active; no completion or repeated-blocker claim is made.

## Ownership and preparation boundary

`document_runtime_c_plan` owns only the new complete-code C plan under
`docs/superpowers/plans/2026-10-09-singularity-v0.2-document-extraction-runtime-outcomes-integration.md`.
Main owns this evidence and any status corrections. The existing complete
2,191-line A/B test source remains frozen. C must cover all mandatory outcome,
recovery/retry/restore, post-claim deletion, exhaustion/retry/snooze, atomicity and
privacy contracts, not replace them with successful fakes. Main must personally
read the complete executable plan before explicit test GO. Production changes
would separately require a focused failing contract and bounded approval.

## Characterized source-cap and expiry boundaries

The released canonical source-size constraint permits only 0..67,108,864 bytes.
The initial source guard requires object/pin size equality; worker describe
independently rejects later object-size drift. Therefore a claimed canonical
Document over 64 MiB is not a valid fixture. Main independently inspected these
guards. The proposed plan must distinguish real maximum-size worker success,
canonical insertion rejection, actual adapter oversize rejection and descriptor
drift denial from mappings that cannot be reached by a valid canonical worker.
Existing assertions are not weakened to force an impossible persisted outcome.

Existing storage expiry fixtures disable a lifecycle trigger, which is prohibited
for C. The worker is preparing a real claim/deadline-derived bounded wait and
actual recovery race, with no trigger bypass, clock hook or arbitrary race sleep.
The complete code and timing assertions remain subject to main review; no C test
has yet run.

No E2E, schema/migration, Vault feature/compatibility patch, key/capability
semantics, generic retry/wake, public repository, merge, push, tag, release,
publication or deployment is authorized here. Borrowed services stay running.
Failed Sol production repair rounds: 0; Astra attempts: 0 (maximum 3 if required).
Successful harness corrections remain recorded separately: A accessor 1 and
B source-size fixture 1. The shared Mix slot is free; preparation needs no
duplicate B baseline.

## Required Asset/application integration baseline

While the C worker prepared the plan without code edits, main took the free
shared Mix slot and ran the mandatory scoped Asset/application regression command
from the A plan against source `5be1e51` (HEAD `33e9bda`, documentation-only above
that tested source):

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_unlock_resume_test.exs apps/singularity_runtime/test/singularity/runtime/job_dispatcher_asset_events_test.exs apps/singularity_runtime/test/singularity/runtime/application_test.exs --seed 1208
```

Exit 0, seed 1208: 113 reported, 65 unit exclusions, 48 integration executed,
0 failures. This explicitly executes the 17 historical Asset/application
integration contracts previously excluded from ordinary unit checks, together
with the 31 B contracts. It does not establish C behavior or Phase 2 acceptance.

Exact database `singularity_test_23caaf53ea4fea9b4368c6b1` and root
`/tmp/singularity/integration/23caaf53ea4fea9b4368c6b1` were independently checked
afterward: database count 0 and root absent, checks exit 0. All main-owned commands
finished and the Mix slot is released; borrowed services remain running. No
production/test edits, repairs or E2E occurred. This new scoped execution evidence
is current-turn progress toward the required regression gate, not a status-only
restatement of B.

## Privacy-path preparation evidence

Main inspected actual SafeSQL, repository defaults/configuration, observability
handlers and the installed Oban executor. SafeSQL forces `log: false` and
`telemetry_event: nil`; repository defaults suppress query telemetry and current
configuration suppresses SQL logs. These source observations are not privacy test
execution. C must capture actual Oban executor start/stop/exception events with
positive event controls, repository query events, bounded application events,
public errors, logs and persisted job/outbox/progress/audit surfaces. Unique owned
handlers must be detached. Direct calls to a telemetry handler cannot substitute
for real runner evidence; no observability expansion is authorized.
