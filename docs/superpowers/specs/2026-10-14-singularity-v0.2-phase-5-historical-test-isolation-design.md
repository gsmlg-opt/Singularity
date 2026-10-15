# Singularity 0.2 Phase 5 — historical admission test isolation

Status: selected under continuing development authority; independent Sol design
review CLOSED PASS (scope-coordinate finding corrected). Task10/Phase5 NOT
ACCEPTED. No product behavior change; whole historical file40/0 PASS with natural
cleanup. Complete README verification stopped at a unit-test failure requiring
separate diagnosis; original failures remain failures.

## Problem and evidence

The exact README no-argument integration gate on Recovery4 Source22 failed two
ordinary60000ms historical admission tests. The subsequent ordinary full-cohort
diagnostic passed both only narrowly (Note59.315825s/Ready59.820514s), not an
acceptance substitute. A separately reviewed causal diagnostic then naturally
exited2 with1863 passed/1 failed: Note aggregate expired at the sixth destination
release; Ready aggregate passed51.773461s. Original failures remain failures.

All six Note child lifecycles have acquisition and cleanup entry coverage;
their individual observed spans are9.537..10.417s, summing60.198807224s. Ready
spans8.253..8.874s sum51.768556811s. Acquiring each complete migrated destination
dominates the aggregate. Entry spans are not intrinsic durations, successful
action proofs, wait attribution, overhead estimates or timing guarantees.

Root reviewed the entire1859-line raw, SHA256
`6357453d8421b65643a783cfe75e4c6a1e2dbe42c8a0a3e0353692273618f2a6`.
Diagnostic tool valid/normal closure PASS; Native FAIL1. Natural main-root cleanup
and maintenance inventory EMPTY. Source22 seals unchanged. Two independent Sol
source-contract/lifecycle investigations and separate Note/Ready numeric analyses
support independent registration, not changing fixture semantics.

## Selected remedy and rejected alternatives

Register the twelve existing independent counterexamples as twelve separate
ExUnit tests instead of two aggregates. Retain `async: false`, integration tags,
the ordinary60000ms timeout and each full isolated destination lifecycle. There
is no cross-counterexample state dependency: baseline bundles are immutable,
each callback receives a fresh verified Replay, admission transaction rolls back,
then staging/Replay/database/root cleanup completes.

This changes test scheduling and the unit to which the existing timeout applies;
it does not decrease total fixture work, optimize migrations or prove a faster
product. It is not permission to remove an assertion or timeout a cleanup less
strictly. Grouping some cases would retain aggregate exposure. Reusing a database,
Replay or migration state would change isolation. Raising timeouts, trace mode,
selective acceptance runs and fixture/backend workarounds are rejected.

## Exact preserved mapping

| Independent case | Candidate-only mutation | Expected rejection | Phase | SQLSTATE |
|---|---|---|---|---|
| Ready digest | first digest=`<<0::256>>`, retain rest | document_extraction_input_check | content.document_fragments |23514|
| Ready identity | first id=64 zero characters | same | same |23514|
| Ready locator bounds | text start0/end1 | same | same |23514|
| Ready locator shape | text start1/end1 plus unknown=true | same | same |23514|
| Ready empty completion | fragment list=[] | document_versions_completion_check | ordinary_constraints |23514|
| Ready incomplete completion | take original first fragment | same | same |23514|
| Note target kind | target_kind=asset | note_attachments_source_check | ordinary_constraints |23514|
| Note target resource | target_resource_id=id(980) | same | same |23514|
| Note target version | target_resource_version_id=id(981) | same | same |23514|
| Note order | ordinal=1 | note_attachments_source_set_check | seal |23514|
| Note natural uniqueness | append original member with only id=id(982) | note_attachments_note_ordinal_key | content.note_attachments |23505|
| Historical citation locator | first locator=pdf page99, retain rest | note_citations_locator_check | ordinary_constraints |23514|

The citation case MUST use `ctx.sources.complete_history`; it cannot use the
citation-free `note_sources` fixture. Other Note cases use `note_sources`; Ready
uses `ready_fragments`. Existing literal cardinalities29/24/114 and38 digests,
successful historical oracle and sealed append/immutable cases remain unchanged.

Every case retains: fresh `with_destination`; original portable baseline/binding
and source database inequality; real authenticated stage and validate; repeated
expected-summary comparison; real begin_restore/bound proof; advisory admission
lock and pending saga; deferred insertion in frozen schema order; principal cleanup
update/readback and Note seals. The three Note identity cases explicitly force
`content.note_attachments_source_set_check IMMEDIATE` at ordinary phase before
the unchanged32 selective ordinary constraints. Ordinal rejects at seal.

`assert_statement_rejected` must retain the exact Postgrex error code, constraint,
phase and callback-not-returned proof, plus both dictionary-marker cleanup steps.
Each rejection is followed by `assert_no_import` inside its callback: all canonical
V3 tables, admission/seal/saga state and twelve excluded relations empty; optional
knowledge_mutation_receipts remains absent-or-empty. Existing Replay disposal,
staging abort/empty/object-prefix checks, owned fixture close and on_exit receipt
termination remain unchanged. Later Native PASS is required to prove execution.

## Ownership and scope

Only production/test Source change:
`apps/singularity_storage/test/singularity/storage/backup/knowledge_historical_admission_test.exs`,
the two former aggregate blocks (prechange477..531 and533..604). Follow existing generated
test/tag style for data, with names that identify each counterexample. No private
helper, setup, fixture, schema, migration, runtime, permission, configuration or
workflow edit. Expected module registration count30→40 (net+10), not fewer checks.

Root owns this design/plan and evidence synchronization; author owns only the
test block. Preserve all unrelated dirty files. Existing Source21 other than this
one path must remain byte-identical. Preserve old manifests; a NEW22-file manifest
declares this intentional one-path change. Frozen/protected/locked checks remain
unchanged. Old source-sealed diagnostic tools are not rerun after this edit.

Astra bounded recovery is authorized by two failed Sol Source rounds and the
user's continuing authorization. Failed Sol2/Astra4 and utility9 remain historical;
this is Source recovery5, distinct from ignored utility repairs. It does not
invent a three-attempt maximum. Independent design review precedes author GO.

## Verification and exit criteria

Existing exact failed README gate is the RED evidence; don't rerun unchanged
Source merely to obtain another failure. First verify a surgical inverse against
the sealed prechange source and complete twelve-case mapping; format only this
file and validate the new seal. Then run the WHOLE historical admission file with
the ordinary integration task, no line filters, trace or timeout override; expect
40 executed/0 failed. Validate natural owned-root/database cleanup after EOF.

Run all15 unchanged permitted README code gates, including NO-ARGUMENT unit,
integration and independent restore oracle. Keep the seven-application graph and
xref cycles0. Focused PASS cannot replace the full gate. Native failures enter
diagnosis and bounded repair; don't weaken assertions or bypass a live owner.
No Source/Git mutations or extra SQL/Native commands during live validation.

Final actual Source SPEC, then a NEW distinct fresh Source QUALITY review must
both pass on exact tested Source. Record commands, raw hashes, outcomes, warnings,
cleanup, risks and no Vault feature work. Authorized small local commits follow
review, then literal full Git cleanliness (no filtering/stashing/deletion/ignore
tricks). Only then can Task10 be accepted and dependent work proceed. E2E remains
NOT RUN/manual-only/deferred; release/push/deploy/production actions remain gated.
