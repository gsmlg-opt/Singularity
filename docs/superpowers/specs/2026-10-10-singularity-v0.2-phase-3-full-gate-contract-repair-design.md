# Phase 3 full-gate contract repair: legacy storage tests

Date: 2026-10-10. This bounded test-only design follows the
[continuous development authorization](../../../AGENTS.md#continuous-development-authorization--2026-10-10).
Its boundary and exact documents passed independent SPEC and separate QUALITY
review by the nonauthor `search_observer_actual_review`; implementation
verification and review remain required. No routine human approval is pending.

## Evidence and boundary

The clean candidate `999b2fc7ce5308156203944eb0f474a5cdb2a44f` passed all
1,382 unit/property cases, then failed the full integration gate: 871 Storage
cases with 16 failures and 236 Runtime cases with 10 failures (`37888`, seed
`918339`). The [qualification record](../../verification/2026-10-09-phase-3-acceptance.md)
preserves the entire failed checkpoint and earlier scoped passes.

This slice addresses 14 observed Storage failures in exactly five test files.
The separate selective-plan failures, test-owned Document lifetime isolation,
Runtime event contracts, and all remaining README checks are not closed by it.
These boundaries organize work; they do not reinstate obsolete approval gates
on necessary repairs. New evidence requires a synchronized design and review.

## Decisions

### Explicit Note fixture authority

The Phase 3 Note projection function revalidates `note.write` through live
authorization. Three legacy test modules construct a principal and membership
without that capability, so Note creation returns `:forbidden` before their
intended rollback/concurrency/restore assertions.

In `note_mutation_rollback_test.exs` and `note_mutation_concurrency_test.exs`,
ensure the existing capability catalog entry and assign only `note.write` to
the selected generated principal/opaque owner scope during setup. Follow the
existing `NoteRepositoryTest` owner-repository pattern, including an exact
one-row assignment assertion. Do not change shared fixture defaults or grant
SQL table privileges. Preserve every checkpoint, barrier, timeout, receipt,
snapshot, and rollback/side-channel assertion.

In `restore_reconciliation_test.exs`, do the same only inside the Note-specific
`restored_note_scenario!` helper, before its existing lifecycle construction.
Leave password-change setup untouched. Preserve the subsequent deletion of
**all** `note.%` assignments and assert none remain before reconciliation.
Keep the exact restored `note.export`, `note.read`, and `note.write` result
and every lifecycle/event/submission-reset assertion. This is fixture authority
for existing Note work, not a change to Vault or recovery semantics.

### Exact current canonical read matrix

Phase 3 intentionally grants web-only SELECT on `tags` and `resource_tags`.
`knowledge_grants_test.exs` still expects only the two Document read grants.
Keep its Document-only attribute unchanged because other tests use Document
columns. Add a distinct canonical-read allowlist containing the two Document
tables plus the two tag tables, used only in the final privilege/ACL/unscoped
read test, and update that test's description.

Retain every cell for four runtime roles and seven privileges, exact
nongrantable ACLs, enabled/forced RLS, empty unscoped web reads, all remaining
SELECT denials, and actual INSERT/UPDATE/DELETE denials. Do not change production
grants, policies, roles, or migrations to satisfy an obsolete test expectation.

### Compare deadline instants, not timestamp spelling

`document_lifecycle_test.exs` reads `timestamptz` through `to_jsonb`, which can
serialize the PostgreSQL session's offset. Its final expiry assertion compares
that string lexically against a UTC string. The observed `20:59:57+08:00` was
already earlier than `12:59:58Z`, despite failing the string comparison.

Require successful `DateTime.from_iso8601/1` parsing and strict
`DateTime.compare(deadline, DateTime.utc_now()) == :lt`. Preserve the exact
181-second fixture aging, 180-second deadline, fencing/recovery assertions,
and unchanged serialized-state equality. Do not force the server timezone,
increase timeouts, or alter production time handling.

## Verification and exclusions

Characterize all five unchanged owning files before editing. A focused run
may pass an order/environment-dependent case; record that honestly rather
than manufacturing RED. After the changes, run the complete five-file batch
and the existing Note repository, search-reconciliation denial, and knowledge
RLS regressions. Parent owns formatting, execution, PostgreSQL, and Git.

Require independent SPEC review followed by a separate QUALITY review before
a narrow local commit. Preserve full-gate failure history. No production code,
released migration, Vault feature/test semantics, source provenance, backup
format, E2E, merge, push, version, release, deployment, or production data change
belongs to this slice. Phase 3 remains unaccepted while any required gate fails
or remains prohibited/unrun.
