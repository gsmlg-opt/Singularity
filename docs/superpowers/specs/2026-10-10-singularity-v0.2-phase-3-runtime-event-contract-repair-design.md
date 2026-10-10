# Phase 3 Runtime event contract repair

Date: 2026-10-10. This test-only slice follows the
[continuous development authorization](../../../AGENTS.md#continuous-development-authorization--2026-10-10)
and the [Phase 3 design](2026-10-09-singularity-v0.2-phase-3-unified-lexical-search-design.md).
Independent exact-document SPEC and separate QUALITY review passed with
nonauthor `search_observer_actual_review`; implementation verification and
review remain required.

## Evidence and boundary

Clean source `999b2fc7ce5308156203944eb0f474a5cdb2a44f` failed full integration
`37888`, seed `918339`: 16 Storage and 10 Runtime failures. This slice addresses
two Runtime contracts in `outbox_dispatcher_test.exs` and
`document_extraction_job_test.exs`. The
[qualification record](../../verification/2026-10-09-phase-3-acceptance.md)
retains the failed full gate. Other failures and remaining README checks stay open.

The dispatcher test received extraction generation 2 where it expected 1.
Migration `20260722000100_skip_vault_locked_outbox_claims.exs` orders candidate
membership before LIMIT, but neither UPDATE RETURNING nor the final SELECT
orders returned events. The current dispatcher forwards those results. The
failure establishes an invalid ordering assumption; it does not establish that
the received event identities were the two intended fixtures.

The ready-Document restore test expected an unchanged owner outbox count of 2
and observed 3. Phase 3 requires a fresh `document.restored` projection event
for an actual restoration, including a ready version. Migration
`20261009000300_document_projection_events.exs` emits that event while leaving
ready extraction state intact. Its projection revision comes from immutable
`content.resource_versions.revision`, which is 0 for this fixture, rather than
extraction generation 1. The test's direct `S.tombstone!` UPDATE emits no
`document.deleted` event. Exact terminal extraction replay emits no new event.

## Decisions

### Compare dispatcher identities and deduplication, independent of arrival order

Retain the exact two fixture event IDs and their generation association.
Receive exactly two submissions and compare their complete ID multiset with
those IDs before building a map. This rejects duplicate, missing, and foreign
events without assuming mailbox order. For each retained ID, assert its original
generation, exact `document-extraction:<version>:<generation>` key, and successful
closed codec encoding. Do not alter production claim ordering or a migration.

Keep both dispatch summaries exactly `submitted: 2, skipped: 0, failed: 0`.
Reset only the retained fixture IDs, collect the second dispatch's exact two
submissions, and require the same envelopes and runner IDs by event ID. Keep
the final unique submission count of 2. Reject any additional submission in
the test mailbox. An isolated characterization may pass because ordering is
undefined; record that result honestly and retain the full-run failure.

### Require exactly one ready-restoration projection event

Rename the ready restore test to say it creates no new **extraction** event.
Snapshot every owner event row before tombstone/restore, including all immutable
metadata; keep the snapshot test-local. After actual restore, require every
previous row unchanged and exactly one additional row. Assert:

- Fresh UUID identity and exact `document-projection:<event UUID>` key.
- Type `document.restored` and identifier-only payload containing exactly the
  fixture resource and immutable version IDs.
- Exact authenticated owner/principal, live principal and owner authorization
  epochs read from the fixture's current canonical authority, `asset.read`,
  `private`, envelope version 1, UUID correlation, and NULL causation.
- Canonical resource-version revision 0, independently read from the exact
  resource/version/owner, rather than attempt generation.

Retain the original ready receipt, hidden/live checks, and byte-for-byte
attempt/fragments equality. After ready extraction replay, require the entire
event snapshot unchanged from the post-restore snapshot. This proves no new
extraction, ready, restored, or unrelated event. Do not filter projection events
out of the assertion or replace exact metadata checks with a count alone.

## Ownership and verification

The Document fixture-lifetime slice also changes
`document_extraction_job_test.exs`. It must finish and hand off that file before
this slice edits it; preserve its explicit retirement registrations. The
dispatcher file can be prepared independently once the exact documents pass
review. Parent alone formats, executes checks, owns PostgreSQL, and mutates Git.

Characterize both unchanged owning files, then verify the complete corrected
files and existing lifecycle/projection-event contracts with seed `918339`.
Keep original deadlines, assertions, runner behavior, and privacy checks.
Independent SPEC review precedes a separate QUALITY review and a narrow local
commit. These results cannot erase the failed full gate or accept Phase 3.

No production behavior, released migration, grants, Vault semantics, backup
format, E2E, publication, deployment, production activation, or production data
change belongs to this slice. Ordinary failures enter diagnosis and repair
under AGENTS.md; a new evidenced repair requires synchronized design and review.
