# C4/C5 test runner isolation

Status: accepted bounded test-only design; independent Astra review cleared the
exact amendment without Critical/Important findings. C3 is accepted locally at
source SHA-256 `62631052619632b747892be4636474f4b824ebd3eaaad63501cc589c7bfba3c9`.

This is a test-only amendment to C4/C5/C6 of the preserved complete outcome plan.
Separate C4 implementation is accepted locally after its full 75-contract gate,
independent Astra reviews and exact cleanup. Append-only C5 TEST GO is recorded
in the executable amendment; C5 is now accepted locally at final source
`b8c6f602344926f4ec085edbd7b3a3b84173efb3d58654cc90ce20d31ba07e42`.
See `docs/verification/2026-10-09-document-runtime-outcomes-integration.md`
for exact gates, independent reviews and cleanup. All C6 gates now pass and its
dependent local commit is authorized; Phase2/release acceptance remains separate.
Phase 2, Vault freeze, no E2E, and all
production boundaries remain unchanged. User standing approval selects the
recommended bounded test-isolation direction, not premature phase acceptance.

## Evidence and recommended change

Independent Astra preflight identified that named Oban instances still share the
same `jobs.oban_jobs` table. Actual Basic fetch selects eligible rows by queue,
not instance name or a specific submission ID. Frozen B intentionally retains an
available runner after domain completion. Therefore C4's snooze case and C5's
privacy runner can fetch that older job instead of their own new submission.

Before fetching, positively assert the new runner was submitted to the original
`document_extract` queue. Move only that exact newly submitted ID to a unique
per-test queue derived from its numeric runner ID, and assert exactly one row
uses the queue. Actual Basic fetch, GenericWorker/Executor, and acknowledgements
then use that queue and must return the original target ID. Keep the envelope,
job type, worker, attempts/max_attempts, canonical rows, and all prior assertions.
Do not drain or mutate earlier tests' runners, change shared handler/Oban config,
or edit frozen B/C1/C2/C3 code. No fake fetch/executor result is introduced.

For privacy events, both original `document_extract` and the isolated queue map
to the existing bounded `:unknown` label (verified in Runtime telemetry's closed
queue map). The original exact bounded-event assertions remain unchanged; no
observability production change or new dynamic atom is allowed.

The old C6 whole-file formatter instructions are superseded: only the newly
authorized append may be formatted. Preserve the 2,790-line original prefix and
accepted C3 bytes exactly. All cumulative integration and required regression
partitions remain mandatory and unfiltered. These amendments do not reduce the
11 C4 or nine C5 contracts or any mandatory coverage.

## Acceptance boundary

After C3 acceptance, independently review the exact amendment and grant separate
append-only GO. Execute C4, then C5 under one parent-owned Mix slot, stopping on
unexpected failure before any bounded repair. The final C block requires complete
scoped integration, custody/storage, Asset/application, unit/architecture, zero
xref cycles, exact cleanup and independent spec then quality review. Do not
infer Task 12, Phase 2, release, or browser acceptance from these gates.

## C5 private-fixture causation repair amendment

The focused C5 diagnostic failed at actual `ObanAdapter.submit`, before Executor
or privacy assertions. Independent Astra tracing confirms the existing C1
`private_document!/1` creates an envelope with `causation_id: nil`; strict
EnvelopeCodec correctly requires a UUID. Production Outbox normalizes stored
NULL causation to the actual event ID. The fixture must mirror that boundary,
not weaken the codec or change the stored event.

Parent grants one explicit freeze exception under standing repair approval:
only the private fixture's `causation_id: nil` becomes `causation_id: id` on its
existing envelope-construction line. Every other accepted C1–C4 byte and assertion
remains frozen. Add exactly two positive controls in the new C5 capture helper
before submission: envelope causation equals its actual job/event ID, and the
same event/owner's persisted causation remains NULL. Retain every original C5
contract, secret assertion and real executor/telemetry/acknowledgement path.
Also require strict `EnvelopeCodec.encode` and exact decode round-trip assertions
before submission, as requested by independent Astra review.

Record old/new prefix and full hashes. Reversing only this new fixture exception
must recover accepted C4 prefix `7322557…33bd4`; C3 cleanup helper bytes and
original A/B prefix must remain unchanged. No whole-prefix formatting, production,
event, codec, configuration or grant change is permitted. Require fresh focused
diagnostic, full unfiltered 84-contract gate, exact cleanup, independent spec
then quality review before C5 acceptance. This is bounded test-only repair GO,
not runtime acceptance or an unsuccessful production repair round.

## C5 inspected-source detector amendment

Independent Astra quality review found a proof gap, not an observed production
leak: raw PDF source is escaped/formatted inside inspected metadata terms, and
this PDF fixture has no title canary. Parent independently reproduced that the
old raw-source/title checks miss a fabricated inspected source-containing map.

Strengthen only the C5 append: add the complete inspected source representation
to the existing secrets list, retaining every old secret and assertion. Include
a deterministic positive control that the same representation detects a
fabricated source-containing term. That fabricated term tests the detector only;
actual privacy coverage must still use real Executor/logs/events/persisted rows.
No recursive framework or production telemetry change is needed. No earlier
prefix change is allowed. Finish the current frozen-source run and exact cleanup
before editing, then require fresh unfiltered 84-contract verification, spec then
quality re-review, and cleanup. A green pre-amendment run cannot clear this gap.
