# Phase 5 Task 10: unified restore and interrupted Document recovery

Status: DESIGN REVIEWED — round 3 actual independent SPEC and NEW distinct
fresh QUALITY are CLOSED PASS, no P1/P2. Prerequisite A.1 now has complete
Runtime2 GREEN and actual SOURCE SPEC then NEW distinct fresh QUALITY CLOSED
PASS, locally committed at `47fabf1e3fcd4b1b149444c0c7d9bb4673b5ba81`.
Parent whole TaskH B/C is now CLOSED valid causal RED: 148 tests, 81 failures,
731.6s on the archived exact three-file source, after preparation Sol2/Astra1.
Normal cleanup is CLOSED/EMPTY. Parent GO now covers production Tasks D/E/F;
GREEN, downstream verification and actual source reviews remain required.
Initial complete D/E/F native qualification is CLOSED FAIL: 148 tests, 6 failures,
781.0s; see the bounded compatibility design below. It preserves all earlier RED
outcomes and identifies previously unreached test preparation, not full GREEN.
First combined compatibility repair is also CLOSED FAIL: 148 tests, 3 failures,
827.6s, with actual SOURCE SPEC FAIL/P2x2 (post-denial pending intent and invalid
column DELETE probe). The bounded test-only synchronization is drafted in
`2026-10-13-singularity-v0.2-phase-5-task10-native-denial-contract-design.md`
and its plan. It supersedes only those contradictory test expectations, not
required canonical/storage/security denial, production behavior or any gate.
Actual independent R2 DESIGN SPEC then NEW distinct fresh DESIGN QUALITY CLOSED
PASS/noP1P2; bounded Doc-test-only repair attempt2 followed design-only
commit2a7873b and actual author closure. Exact whole H3 naturally CLOSED PASS:
148 tests, 0 failures, 631.0s; repeated complete Runtime2 CLOSED PASS:
10 tests, 0 failures, 187.3s. Both normal cleanups EMPTY/exact roots absent,
eight sources and original frozen56/protected3 unchanged. All retained Base,
Task9 and Task8 whole pure/SQL gates and static/frozen checks subsequently CLOSED
PASS; actual counts/exclusions and archives are recorded in the acceptance report.
Complete permitted README and corrected actual source acceptance remain pending.
At focused closure, combined failed Sol1/Astra0 remained unchanged; no earlier FAIL is relabeled.

Complete permitted README integration subsequently naturally CLOSED FAIL:
session36198/exit2, Storage370FAIL and Runtime369FAIL (1831executed/739FAIL).
Normal final maintenance is NOTEMPTY: one exact test-owned orphan DB/root.
Current8/frozen56/protected3/locked13 remain unchanged. Earlier focused PASSs
remain scoped evidence, not full README or Task10 acceptance. Cumulative
combined failedSol2/AstraRepair0 now requires bounded Astra recovery1;
historical failedSol1 receipts and separate preparation counters are preserved.
The precisely scoped next amendment is
`2026-10-13-singularity-v0.2-phase-5-readme-compatibility-design.md` and its
companion plan. Independent design reviews precede authoring; no Task10/Phase5
acceptance or weakened Observer/Runtime/security assertion follows.
This is not Task 10 completion or phase acceptance. The parent reports Task 9F native
gates, actual SOURCE SPEC and distinct fresh SOURCE QUALITY CLOSED PASS, with
bounded local commit `5619eccdbc2256c4c5aa702b653038fa57ada6fe` CLOSED.
The subsequent complete Runtime recovery/restart baseline is CLOSED FAIL:
10 actual tests, 9 PASS, 1 FAIL, 185.7 seconds, exit 2. Its narrowly authorized
permission-test contract correction below is an explicit prerequisite, not a
Task 10 causal RED or implementation GO.
The initial actual DESIGN SPEC and distinct fresh DESIGN QUALITY are CLOSED
FAIL on the same single P2: the earlier 0/1 native reconcile-result restriction
rejects legitimate multi-fragment Documents. This correction preserves that
history. Round 2 actual DESIGN SPEC is CLOSED PASS, but its NEW distinct fresh
QUALITY is CLOSED FAIL on one P2: impossible returned-contract variants lacked
an explicit response-injection mechanism. Round 3 corrected actual SPEC and
another NEW distinct fresh QUALITY subsequently CLOSED PASS. Preserve both
earlier FAILs and the separate round 2 SPEC PASS; none is relabeled.
Actual review receipts are `.devenv/phase5-task10-design-spec-round1-final.md`
and `.devenv/phase5-task10-design-fresh-quality-review-round1.md`.
Round 2 receipts are `.devenv/phase5-task10-design-spec-review-round2.md` and
`.devenv/phase5-task10-design-fresh-quality-review-round2.md`.
Round 3 parent verbatim captures are
`.devenv/phase5-task10-design-spec-review-round3.md` (SHA256
`971650a3125e5c9dad0742e3b420775c6883c0f25d82829acc9b5278007d395e`)
and `.devenv/phase5-task10-design-fresh-quality-review-round3.md` (SHA256
`6ddaa8485d8549902d13f5a4aff0d6550670ef6140e55760a2a6e55ff252588e`).
Reviewed pre-bookkeeping design/plan hashes were
`bb19d7507f8984d87cb1e4cf051cfc423c86d135219edd93b6932559fd856a60` /
`0b5527f216f403dc725bb8a1097e7a923b330f6d830891e6fd2a5cc5f2f08da9`;
master design/plan were `5f52114b5a436b960cebdc6e3f72e5944efebe528cc7f4f7c66acd18f6170e31` /
`89be84310a216e7ef5ee5caf0787bcfc7e48986fdcdd206d06ae0878a231df90`.
Subsequent status-only bookkeeping is not retroactively part of those reviews.
The initial lock-order concern was withdrawn after checking the latest released
`20261009000300_document_projection_events.exs` resource-before-version target;
no redundant retry prelocks or helper/frozen-source changes are authorized.

Worktree: `/home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-5-export-backup`.
Branch: `codex/v0.2-phase-5-export-backup`.
Current local HEAD: `c98b4a6aad7516489b0615163340b225ea58a954` (Task16
documentation-only commit; accepted A.1 source baseline remains47fabf1).
Task16 documents were separately reviewed; neither strict lease boundary is waived.
Task 9F baseline: `5619eccdbc2256c4c5aa702b653038fa57ada6fe`.
Original preparation baseline: `9f91c97eb392b4c49c888ed31795d520d15bb8dd`.
The author read the local HEAD; native and review outcomes above are parent
receipts, not independently rerun qualification or remote identity verification.

## 1. Governing requirement and selected amendment

This is the bounded elaboration of section 9 of
`2026-10-11-singularity-v0.2-phase-5-export-backup-design.md` and Task 10 of
the corresponding master plan. After authenticated V3 import and canonical
verification, rebuild Asset metadata and unified Note/Document search, reconcile
durable work, and preserve the restored canonical cut before any recovery.
Invalid historical authorization must require ordinary authenticated retry.
That last requirement remains unwaived.

The parent captured one bounded architecture consultation and clarification in
`.devenv/phase5-task10-recovery-epoch-architecture.md` and
`.devenv/phase5-task10-recovery-epoch-architecture-followup.md`. They are design
advice, not implementation acceptance or repair rounds (Sol/Astra repair 0/0).
They identify two connected gaps: existing periodic recovery checks current
creator authorization but not the original attempt event; existing runtime
retry rejects every `extracting` attempt. Adding only an epoch guard strands
the rejected attempt. An authorization-specific retirement marker also matters:
revoked membership can be restored at unchanged epochs, so the generic
`restore_stale_destructive` marker cannot prove the earlier rejection.

Selected approach: a V3-only rebuilding facade, Document-specific reconciliation,
and one new forward knowledge migration that narrows automatic recovery and
adds structurally bound authorization-invalid pending and expired-extracting
cases to the existing authenticated retry.
This consumes established authorization snapshots without changing policy.

Alternatives considered:

- Delegate to Base and merely add Document rows: this cannot establish the
  complete owner projection/digest or remove every stale unified row.
- Add only an epoch guard, or reuse the destructive retirement reason for every
  authorization rejection: both fail ordinary authenticated retry, particularly
  after same-epoch reauthorization.
- Change attempts during import, fake an expired failure, or invent recovery
  jobs/sessions: these break canonical-cut equality or existing lifecycle rules.

## 2. Bounded files and preserved surfaces

Task 10 initial implementation owners are exactly:

- `apps/singularity_storage/lib/singularity/storage/backup/knowledge_integrity_audit.ex`:
  retain Task 9E source verification and replace only the rebuild delegate.
- `apps/singularity_storage/lib/singularity/storage/backup/reconciler.ex`:
  add Document dispatch mapping, raw validation and state-based reconciliation.
- `apps/singularity_storage/priv/repo/migrations/20261011000800_document_restore_recovery_provenance.exs`:
  new forward migration, three existing function replacements and one constraint.
- `apps/singularity_storage/test/singularity/storage/unified_search_restore_test.exs`
  and `apps/singularity_storage/test/singularity/storage/restore_reconciliation_test.exs`:
  additive contracts, retaining all existing assertions.
- `apps/singularity_storage/test/singularity/storage/backup/document_restore_reconciliation_test.exs`:
  new complete restore/recovery, retry, SQL-security and concurrency owner.

The evidenced six-failure native repair additionally follows
`2026-10-13-singularity-v0.2-phase-5-task10-contract-compatibility-design.md`
and its detailed plan. That bounded amendment adds KnowledgePreflight and its
contract-test owner for absence-only typed rejection, plus legal preparation in
the two existing Raw/Doc owners. No frozen source, Restorer, wire, migration,
role/grant, custody or Vault change follows. Independent amendment review and
whole gates remain required; old file-list wording does not override the
continuous authorization for these necessary compatible repairs.

The later complete-README amendment above permits ONLY its ten named knowledge
test/support paths after independent design review. Earlier shared-fixture
exclusions remain for all other work; frozen/production/custody bytes stay exact.

The migration changes only
`content.expired_document_extraction_ids(integer)`,
`content.recover_expired_document_with_event(uuid,uuid)`,
`content.retry_document_runtime(uuid,text,integer)`, and
`core.outbox_events.outbox_events_retirement_shape_check`.
It preserves signatures, return types, owners, security modes, fixed search
paths, ACLs and existing grants. It adds no helper, grant, membership or new
security-definer surface. It preserves existing lifecycle transitions and
raises explicitly on `down` as a forward-only migration.

All 43 released migrations and 13 named frozen sources remain byte-identical.
Base `Backup.IntegrityAudit`, wire Schema V1/V2, Runtime API signatures,
EnvelopeCodec and outbox claim adapter remain unchanged. The sole separately
authorized Runtime-test exception is the permission case specified in section
2.1; all nine other cases across the two Runtime owners and the entire restart
file remain unchanged. Both complete owners remain mandatory native gates.
There is no Vault, policy, capability, custody, key, crypto,
lease or production-activation work. V2 stays default until Tasks 11/12 qualify
the writer and complete restore together. Task 8 V1 writer denials and the V2
unsupported-canonical cases in UnifiedSearchRestoreTest remain required.

### 2.1. Prerequisite: correct the existing worker-read permission contract

The only additional test scope is the case
`"recovery functions expose only narrow worker execution"` in
`apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs`
(original line 218). Its worker SELECT expectation at original lines 282–291
is obsolete for both `content.document_versions` and
`content.document_fragments`: released `20261011000500_knowledge_backup_read_grants.exs`
lines 7–9 grants SELECT on both. The baseline's first reached mismatch is
Document versions (`[[true, true]]`, expected `[[false, false]]`); fragments
has the same source-proven grant and requires its own native positive proof,
not a claim that the failing baseline reached that assertion.

This is the same established owner-scoped worker-read contract reviewed in
`2026-10-12-singularity-v0.2-phase-5-document-worker-read-contract-design.md`
and its plan. No production privilege, migration, policy or grant changes are
authorized. Preserve every existing function owner/security-definer/search-path/
return/Public ACL assertion, role-specific EXECUTE assertion, direct table and
column DML denial, and private-function assertion in this case. Do not replace
the SELECT denial with a bare boolean inversion. Add native worker evidence:

- Both tables have effective table/column SELECT and ENABLE/FORCE RLS.
- With actual same-owner and foreign-owner ready Documents and real fragments,
  a correctly scoped WorkerRepo sees exactly its own immutable versions and
  fragments, with exact row identities and content/locator values; foreign
  versions/fragments remain invisible.
- Missing principal or owner context, mismatched principal/owner context, and
  revoked membership each hide both tables' rows. Use the actual existing
  `core.principal_is_authorized` membership/GUC predicate; do not infer session,
  epoch, account or custody guarantees that this RLS predicate does not provide.
- Independently attempt INSERT, UPDATE, DELETE and TRUNCATE on each table as
  the actual worker role and prove native SQLSTATE `42501`, not merely zero
  affected rows or permission metadata. Isolate failures with rollback so every
  denial is reached. Compare exact owner/foreign row identities and values
  before/after the complete denial sequence.
- Keep one WorkerRepo checkout/backend across scoped normal and rollback paths;
  prove backend identity and principal/owner GUC cleanup on both exits, and
  prove an unscoped subsequent read cannot retain access.

Preserve `.devenv/phase5-frozen-baseline.sha256` (original 56 entries) and
`.devenv/phase5-task10-protected-native-baseline.sha256` (original Runtime2/Base
three entries) as historical receipts, never regenerated to absorb this edit.
The parent captures the exact approved case delta and an independently reviewed
current receipt. An inverse of only that case delta must reproduce the original
whole-file recovery-test hash; the other nine cases, whole restart file and
Base audit must match their original receipts directly. Required whole Runtime2
GREEN with this stronger reviewed contract must close before dependent Task 10
test/production GO. Historical FAIL remains recorded. This documentation
amendment is not a native Sol repair round.

## 3. Atomic V3 rebuilding

`KnowledgeIntegrityAudit.rebuild/2` keeps its existing return type:
`{:ok, IntegrityAudit.SearchSummary.t()} | {:error, Error.t()}`. Its exact
binding remains `%{manifest_id: canonical_uuid, vault_id: canonical_uuid}`;
`vault_id` is the established opaque authenticated owner encoding.

Reject nested entry before doing any work. Open one fresh repeatable-read
restore-maintenance transaction, set the existing TableOwner role, prove the
existing migration login/SET-role context, and set the local owner GUC on that
same connection. Use the established KnowledgeIntegrityInventory transaction
pattern. No live session, caller-selected new scope, ordinary runtime role or
new privileged repository is introduced.

Within that transaction:

1. Call unchanged `IntegrityAudit.rebuild(repo, binding)` nested on the same
   transaction/connection. This retains native Asset and legacy Note behavior.
   Accept only a valid typed SearchSummary; discard its legacy count/digest.
2. Enumerate this owner's Note and Document resource UUIDs in stable UUID order,
   including tombstones and resources whose heads are not ready.
3. Delete **all** this owner's `content.search_entries`, without a join or kind
   filter that could hide stale rows. Foreign-owner entries remain untouched.
4. Invoke `content.reconcile_search_resource_internal(owner, resource)` once for
   every enumerated resource. Require exactly one row with one cell `[[count]]`,
   where count is an integer in `0..9223372036854775807` (nonnegative bigint).
   Reject `-1`, out-of-range values and every malformed shape/type.
5. Read actual Asset metadata and actual unified rows from this same snapshot;
   validate their complete row shapes and return the new typed summary.

Every inner error, malformed Base result, bad resource row, failed deletion,
rejected native reconcile result or summary-read failure rolls back the entire outer
transaction, including Base changes. Preserve sanitized Error values; query
failure maps to `storage_unavailable`, malformed evidence/integrity disagreement
fails closed. No exception, log or telemetry metadata contains content.

Only derived rows change. Current live Notes yield one unified row each;
current live ready Documents yield one row per exact canonical fragment.
Deleted/non-ready/old-head Documents yield none. Historical versions, fragments,
citations, source seals, tags and relationships remain unchanged. Rebuild twice
and compare exact IDs, kind/resource/version/fragment tuples, ordinal, text,
locator, timestamp and search tokens, along with count and digest.
Require a positive current ready Document with at least two real canonical
fragments, plus two actual six-column Asset rows. Independently compare every
fragment's full eleven-column unified row, actual combined projection count
and digest, exact repetition, canonical/history preservation and foreign-owner
preservation. Count fragments, not resources; do not derive the expected rows
from production's query or digest. Released
`20261009000200_unified_search_reconciliation.exs` returns bigint `ROW_COUNT`
after inserting all ready fragments; the established seven-state fixture seeds
two per ready Document. Its valid result `[[2]]` must not fail rebuilding.

### 3.1. Three separate result and rollback evidence paths

Do not claim PostgreSQL's scalar `RETURNS bigint` produces malformed shapes,
noninteger cells or out-of-bigint-range values. Preserve three distinct paths:

1. **Genuine native positive:** execute the unchanged native function with the
   current ready Document's at least two real fragments, including valid `[[2]]`.
   Independently compare full eleven-column fragment rows, two six-column Asset
   rows, count/digest, repeat rebuilding and canonical/foreign preservation as
   required above. This is not a response-substitution test.
2. **Disposable native faults:** in the test-owned database, exercise the native
   `-1` sentinel and a separate late SQL failure after actual Base rebuilding
   and owner unified-row deletion. Any bounded test-only function-body fault must
   retain the exact installed signature, bigint return, owner, security mode,
   search path and ACLs. Never disable canonical/security guards or change
   grants/policies. Capture original definitions and metadata before arming;
   restore the exact original definitions in `after` on every exit and verify
   metadata/definitions after cleanup. A real SQL error proves SQL-error
   rollback, not rejection of a successfully returned malformed value.
3. **INJECTED_CONTRACT_FAULT:** for impossible returned shapes/types/ranges,
   introduce a test-local real-query-delegate-then-response-alter proxy only in
   the three owned Storage test files. Alias the actual MigrationRepo metadata
   and pool, replacing only its SQL dispatch module with a forwarding proxy.
   Delegate every repository operation, backend/connection selection, checkout,
   transaction and rollback to the actual native repository; keep SafeSQL and
   Base unchanged. Forward all SQL callbacks to the original native SQL module.
   For exactly the selected facade reconcile SQL/parameters, execute the real
   query **first**, retain its original native result, then alter only that
   returned contract. Nonselected calls/results/errors remain untouched. Use
   process-local fault state and a test-owned alias; no separate pool, fake
   transaction, dependency change, production hook or shared-source helper.

The existing `knowledge_integrity_inventory_test.exs` RecordingRepo supplies
only a native metadata-alias pattern, not a response proxy. SafeSQL calls Ecto
SQL, whose installed `ecto/adapters/sql.ex` lines 684–697 dispatch through
`adapter_meta.sql` on the native transaction connection/pool. The new local
proxy must implement that forwarding boundary explicitly, not assume overriding
a repo `query/4` intercepts SafeSQL.

For every rejection prove interception/fault execution was reached **after real
Base writes and owner search deletion**. Capture independent pretransaction
rows, in-flight native backend/role/repeatable-read/owner-GUC witnesses and actual
derived rows demonstrating those changes. On the response-proxy path record
the original successful native target result and actual inserted fragment rows
before substitution. For late SQL failure capture the witness before the failing
dispatch and its native error, not a post-abort query or fabricated result.
After the facade error and real outer rollback compare exact before/after rows
for all owner projections, foreign projections and canonical/history inputs.
Cleanup alias/registry/proxy/process fault state and any database fault definitions
in `after` on every exit. Confirm original definitions and function metadata,
backend/GUC cleanup and no residual fault. Label impossible-response evidence
`INJECTED_CONTRACT_FAULT`: it proves the returned-contract guard and native
SQL/rollback composition, not PostgreSQL-generated malformed bigint output.
None of these helpers or faults changes production or frozen source bytes.

## 4. Exact SearchSummary evidence

The literal `projection` stays `postgres_metadata_v1`, preserving the existing
Runtime validator. `document_count` is the number of actual Asset index rows
plus actual unified rows; legacy Note projection rows are not counted again.
Use the existing completion digest field; add no summary table or wire fields.

Asset evidence is the unchanged Base six-column projection:

```sql
SELECT asset_id::text, resource_version_id::text, classification, state,
       detected_media_type, search_vector::text
FROM content.asset_search_documents
WHERE vault_id = $1
ORDER BY asset_id
```

Unified evidence has exactly these eleven columns and deterministic ordering:

```sql
SELECT entry_id, kind, resource_id::text, resource_version_id::text,
       fragment_id, ordinal, title, body, locator,
       to_char(source_inserted_at AT TIME ZONE 'UTC',
               'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), search_vector::text
FROM content.search_entries
WHERE vault_id = $1
ORDER BY kind COLLATE "C", resource_id, resource_version_id, ordinal,
         entry_id COLLATE "C"
```

Keep SQL NULL as `nil`, JSON locators as maps and timestamps as the exact UTC
microsecond string. Never coalesce/cast away nil, omit source version, or join
canonical tables to conceal stale actual rows. Hash these actual row lists:

```elixir
evidence = %{assets: asset_rows, knowledge: unified_rows}
bytes = :erlang.term_to_binary(evidence, [:deterministic, {:minor_version, 2}])
digest = :crypto.hash(:sha256, bytes)
```

Independent literal vectors, verified by parent native preparation (not
Task 10 implementation qualification):

- Empty ETF hex:
  `83740000000277066173736574736a77096b6e6f776c656467656a`.
  SHA-256: `4a29cf8e8bc7cc6ed0f147e2b94bcdee7a1dd0eadf55971d702f0f00e92331c6`.
- `assets: []`, `knowledge: [row]`, where row is:

```elixir
[
  "note:00000000-0000-4000-8000-000000000002", "note",
  "00000000-0000-4000-8000-000000000001",
  "00000000-0000-4000-8000-000000000002", nil, 0, "Alpha", "Beta",
  %{"version" => 1, "kind" => "markdown", "heading_path" => []},
  "2026-01-01T00:00:00.000000Z", "'alpha':1A 'beta':2"
]
```

  Proposed SHA-256:
  `83571fc40de7553cbf9504066d3a05bb1d73de1543d06f37fdd6ee2d19f2d0b0`.

The parent verified both with native ETF before test-authoring GO; complete
archive `.devenv/phase5-task10-native-etf-vectors.log` SHA256 is
`627739bd672aadf4ef3dd55f316183d5dd4bcf17a4b8306c1b7b351bda98a20b`.
Test
oracles separately construct expected projection rows from canonical fixture
inputs and literal expected tokens; neither production's SELECT nor its own
computed digest is the expected oracle. Prove that changing each evidence
column, count, retained nil or source version changes or rejects evidence.

## 5. Raw Document provenance before retirement decisions

Map exactly `document.extraction_requested` to `document_extract`, and
`document.ready`, `document.deleted`, `document.restored` to
`document_projection`. Unknown event types remain errors. Validate every
Document row, including retired rows, before any generic retired/terminal
shortcut. Keep legacy Note/Asset branches and assertions intact.

Validate raw event UUID, owner, original Document creator, `asset.read`, private
classification, envelope version 1, nonnegative bigint revision/epochs,
exactly the two resource/version UUID payload keys, exact owner/resource/version
binding, retirement timestamp/reason pair and matching submission job type,
owner, classification and idempotency key. Bound historical extraction events
to their own attempt revision; only the actual claimed attempt compares against
`attempt_generation - 1`. An obsolete valid event is retired, not treated as
malformed merely because a newer generation exists.

Extraction keys are `document-extraction:<version>` at revision 0 and
`document-extraction:<version>:<revision>` above 0. Projection keys are exactly
`document-projection:<event UUID>` and use the existing projection provenance
contract. Epoch mismatch/current authorization rejection is distinct from
structural corruption. Missing principal/owner binding or malformed epochs are
structural failures, never an authorization-invalid retirement escape.

Raw `correlation_id` is required UUID; raw `causation_id` is NULL or UUID.
Normal runtime retry and projection SQL legitimately persist NULL causation.
The established outbox claim adapter converts only NULL causation to event ID
when constructing its in-memory envelope, and RuntimeDispatcher copies it.
EnvelopeCodec requires strict UUIDs. Therefore validate raw fields first,
preserve raw NULL in storage, and build a temporary codec envelope with
`causation_id: raw_causation_id || event_id`. Validate it through unchanged
JobEnvelope/EnvelopeCodec. Do not copy the Note helper's direct-nil path,
rewrite persisted causation or loosen the codec. Test both legitimate NULL and
explicit UUID causation for extraction and projection.

Reconcile against final canonical state:

Decision order is structural validation first, then obsolete generation/head/
destructive classification, then current-attempt authorization and reflected/
pending handling. Obsolete or malformed work must never receive the new
authorization-invalid reason solely because its authority is also stale.

| Valid Document work | Derived decision |
| --- | --- |
| Current live pending, current generation and current authority | Retain one exact extraction request; clear lost runner/claims so normal wake can dispatch |
| Claimed extracting, exact attempt event and valid authority | Retire `restore_effect_already_reflected`; clear obsolete runner without resetting for dispatch |
| Ready/failed/unsupported redundant extraction | Retire reflected; never re-extract during restore |
| Old generation/head, deleted or destructive-obsolete work | Retire `restore_stale_destructive`; never revive an old head |
| Structurally bound extraction with stale epochs/current authorization rejected | Retire `restore_document_authorization_invalid`; preserve canonical attempt |
| Valid projection | Reconcile against final resource state; clear or retire redundant work without reviving serialized state |
| Malformed/unknown/cross-owner work, including retired work | Integrity failure and rollback of all reconciliation changes |

The new reason is allowed only for `document.extraction_requested`. Preserve
all three existing reasons and the existing nullable-text wire shape. Preserve
the existing rejection of malformed timestamp/reason pairs: the added CHECK
alternative explicitly requires both `retired_at IS NOT NULL` and
`retirement_reason IS NOT NULL`, so a null reason cannot pass via SQL UNKNOWN.
Preserve retired-at on idempotent repetition. An extracting claim must never enter
`reset_for_dispatch` or the generic path that calls `clear_terminal_runner`
in a way that makes the original claimed request dispatchable.

## 6. Forward recovery and authenticated retry

Original-event existence is tested by UUID **alone**:

```sql
SELECT e.* INTO original_event
FROM core.outbox_events AS e
WHERE e.id = found_document.attempt_job_id;
```

Only genuine absence permits the established native eventless compatibility
branch. Owner/type/generation/retirement predicates in that lookup would hide
a present invalid row and are prohibited. V3 preflight and deferred finalizer
already require the exact attempt event plus `document_extract` submission,
with event revision `generation - 1`; their missing-event denial remains.

For a present event automatic recovery requires the raw event structural binding
from section 5, original creator/current owner authorization, exact current
principal and owner epochs, current live head, native expiry and overflow
guards, and either no retirement or valid reflected retirement. Submission
presence has two explicitly different native compatibility cases:

- A valid **unretired native** attempt may have no submission. The unchanged
  Runtime restart owner's `extraction_event!` inserts only the real outbox row;
  its `claim/1` calls WorkerScope and DocumentWorkerRepository.claim directly.
  WorkerScope acquires existing locks/context; claim delegates to
  `content.claim_document_worker`, not submission creation. Preserve this
  established ordinary native path. If a submission exists, validate its exact
  event UUID, owner, private classification, `document_extract` type and key.
- A **reflected-retired V3 imported** attempt must have its matching extraction
  submission. V3 preflight/finalizer already require it, and reconciliation must
  retain that exact binding. Missing or malformed submissions on this branch
  deny recovery; reflected retirement is not a compatibility escape.

Missing submission never makes a present event eventless and never relaxes
UUID-only lookup, event/revision/epochs/current-authority checks. Scanner and
locked mutator use the same distinction. Reconciler's restored-row validation
and V3 preflight/finalizer mandatory-submission denials remain unchanged.
Automatic recovery rejects
the new authorization-invalid reason permanently, including after later
reauthorization. Generic destructive/legacy retirement cannot auto-recover.

The scanner evaluates all eligibility exclusions **before LIMIT**, orders by
deadline/version and still returns only version/owner UUID pairs. A page of
100 invalid early attempts must not starve a later valid candidate. The mutator
repeats all authoritative checks under locks; scanner success is not authority.
Acquire the existing shared authorization advisory lock for creator/owner
before canonical locks; lock resource before version, then inspect the exact
event and current authorization consistently. Preserve existing recovery
semantics: locked custody alone does not prevent identifier-only recovery.

Recovery reuses native `recover_document_extraction`: `extracting` generation
g becomes `pending` generation g+1, clears attempt fields, and atomically inserts
one normal successor authored by the original creator with current epochs,
key suffix g+1, expected revision g+1 and causation old job UUID. Preserve the
existing recovery correlation convention. A successor insert collision rolls
back the canonical transition; concurrent recovery/retry creates at most one
successful successor. Second recovery returns false.

The unchanged authenticated Runtime retry API gains two SQL eligibility cases:
live `pending` authorization-invalid work, and expired `extracting`
authorization-invalid attempts. Both require exact present structural binding,
current live head, current authenticated original creator/owner authority, and
either actual stale original epochs or
`restore_document_authorization_invalid` retirement.
Take existing authorization serialization before calling the existing
resource-before-version runtime target and revalidate the predicate under
locks. Preserve native failure/unsupported rules, pending idempotence and
error contracts. Current equal epochs plus generic destructive retirement
does not authorize this added retry route.

Retry uses the existing legal extracting-to-pending or pending-to-pending
generation increment and ordinary current-epoch extraction event: fresh
correlation UUID, raw NULL causation, current authenticated creator and existing
key/revision conventions.
No identity/session is synthesized. Unauthenticated, revoked, foreign-owner,
foreign-creator, stale-head, malformed or unexpired extracting attempts remain
denied.

The parent additionally authorized the necessary pending-work amendment during
this design preparation. Source evidence is
`20260922000300_document_runtime_mutations.exs`: retry's early pending branch
tests only current event-key existence, and its guard otherwise accepts only
failed/unsupported. It cannot reactivate retired pending work. The same
migration's lifecycle guard explicitly allows pending-to-pending generation+1
when all fields other than generation stay identical (lines 125–128). No
lifecycle-guard replacement is needed or authorized.

Pending has NULL `attempt_job_id`; find its original current request using the
existing unique `(vault_id, idempotency_key)` pair, never an arbitrary/latest
event. The key is unsuffixed at generation 0 and suffixed with generation above
0, as EnvelopeCodec's exact Phase 2 extraction-key contract requires. Validate
the whole event plus matching submission; event revision equals the pending
generation. Its creator/owner/resource/version/capability/private/version-1/raw
correlation/optional-cause/epoch/retirement binding remains mandatory.

Valid authorized unretired current pending work keeps the ordinary idempotent
return and unchanged generation. Normal retry inserts an outbox event before
the dispatcher creates its submission; therefore this idempotent branch validates
any present submission but permits ordinary pre-dispatch absence. That absence
is not permitted for the original authorization-invalid imported pending request
being advanced: that route requires its exact existing matching submission.
Do not invent a submission inside retry SQL to satisfy repeated idempotence.
Structurally valid pending work with stale
epochs or the distinct authorization-invalid marker is never reset/woken
automatically; after real authenticated retry it advances generation once,
changing only that canonical field, and inserts one ordinary current-epoch
request atomically. Never unretire or rewrite the old event's provenance.
Missing/malformed/foreign/obsolete/destructive current pending work cannot use
this route; neither can a generic destructive reason even with stale epochs.
Repeated retry sees the new valid current pending request and returns
idempotently. Collision rolls back the increment. Keep existing NULL pending
attempt/terminal fields identical to satisfy the native lifecycle guard.

Proposed minimal master amendment: name additive migration `00800`; require
both authorization-invalid pending and expired-extracting ordinary retry,
exact current event/submission binding, existing legal generation+1 transitions,
and unchanged API/security/frozen boundaries. Parent alone edits governing
documents after F closes; the amendment requires DESIGN SPEC then fresh QUALITY.
The master amendment also names the single prerequisite permission-case
correction in section 2.1 and the unretired-native optional/reflected-V3
mandatory submission distinction above, without expanding Runtime production
or other test scope.

## 7. Causal fixture and acceptance

Use sequential `KnowledgeBackupFixtures.with_destination(:current, ...)`
environments because they own global application configuration. Seed the
established seven-state graph and actual encrypted V3 bundle. Copy the bundle
outside its owned source allocation before source cleanup; then authenticate
and import into a distinct fresh receiver. Do not copy a verified handle or
create a source/destination nested fixture environment.

The genuine extracting fixture already has start
`2026-10-11T00:00:00.000000Z`, deadline +180 seconds, generation 1, matching
attempt/outbox UUID, event revision 0, extraction submission, claimed-effect
receipt and no extracting fragments. Assert Runtime's periodic recovery process
is absent. Before reconciliation/rebuild/recovery, compare the complete restored
wire cut to source, including imported outbox/submission/progress/receipt rows.
Keep a separate canonical knowledge/source/history snapshot that excludes
derived work and projections. Reconciliation and rebuilding may change only
their permitted derived rows; reassert the separate canonical snapshot equality
and verify the exact derived deltas rather than comparing retired work to its
original unretired representation.

Only after equality, assert the persisted deadline is less than the actual
database clock. The fixed fixture makes this a deterministic reached barrier;
never rewrite its deadline, sleep until it expires or introduce a clock API.
Drive `DocumentRepository.list_expired_recovery_ids/2` and
`recover_expired_with_event/3` through actual WorkerRepo, following the same
periodic algorithm without creating a Storage-to-Runtime dependency.

Required causal cases include valid reflected recovery once; stale principal
epoch; independent stale owner epoch; current revocation; same-epoch
revoke/retire/reauthorize; both pending and expired-extracting fresh actual
authenticated-session retry once;
malformed/cross-owner/wrong type/revision/key and retired malformed rollback;
eventless native compatibility; present valid unretired native recovery with
absent or exact submission and mismatched-present denial; reflected-V3 missing
or malformed submission denial; V3 missing-event denial; deleted/nonhead and
unexpired denials; scanner fairness; recovery/retry concurrency and authorization
change barriers; successor collision rollback. Current authorization alone must
not make a historically rejected attempt automatically recover.

Characterize unchanged Base before new RED to exclude an unrelated legacy
precondition as the cause of an intended failure. Require whole Storage three
owners plus the whole Runtime extraction reconciler owner with only the reviewed
section 2.1 case correction and the byte-identical whole restart owner,
legacy Base and complete Runtime integrity owners, retained Task 9E integrity
owners and Task 8 denials. Native SQL metadata/source-equivalence checks prove
the three-function/one-constraint delta and all unchanged security surfaces.
Format, warnings-as-errors compilation, seven-application graph/zero cycles,
frozen/source receipts and normal EMPTY/root-absence cleanup remain required.
Parent alone runs all native operations serially; authors stop for every gate.
First close the prerequisite permission-contract repair with both full Runtime
owners; then retain both full owners after Task 10 migration changes. Neither
run may omit or filter the nine preserved cases or the corrected security case.

Independent DESIGN SPEC then distinct fresh DESIGN QUALITY must review both
documents and the parent-maintained master amendment after F commits, before
test-authoring GO. Whole causal RED precedes production GO. After GREEN,
independent actual SOURCE SPEC then distinct fresh SOURCE QUALITY precede the
bounded local commit `feat(restore): reconstruct unified search and document work`.
No predicted test totals or native PASS are recorded here.

### 7.1. Disposable receiver authentication preparation

Status: supplementary round1 actual DESIGN SPEC CLOSED FAIL on one P2: the
source fixture's distinct identity IDs cannot use the unchanged native login
scope. Corrected round2 actual SPEC then NEW distinct fresh QUALITY are now
CLOSED PASS, no P1/P2; parent test-only preparation GO covers the selected
fixture composition below, not current test SOURCE/native qualification or
production D/E/F. Round1 remains FAIL and is captured verbatim in
`.devenv/phase5-task10-receiver-auth-design-spec-round1.md`. This is a
test-environment clarification, not additional production or Vault scope.
Actual round2 SPEC receipt
`.devenv/phase5-task10-receiver-auth-design-spec-round2.md`, SHA256
`c5532da13a109c5fda45fb7dd6c1154e123b20cb5bb871694727e0bc40b0d1e6`;
NEW distinct fresh QUALITY receipt
`.devenv/phase5-task10-receiver-auth-design-fresh-quality-round2.md`, SHA256
`234ef60b1ab55ccced41fc1e62a9bacd06de62ed5465419f9f6ee3c1521c2db8`.
Both reviewers' exact pre-bookkeeping four-document hashes are retained in
those verbatim receipts. All reviewer commands CLOSED/read-only; subsequent
parent status bookkeeping is not retroactive independent review.
Direct source tracing found that both accepted Restorer insertion paths replace
the non-wire credential verifier with the installation dummy verifier; neither
revokes nor disables the credential. LogicalSchemaV2 carries only credential
id/account/login/revoked-at/inserted-at, and excludes sessions. Restorer also
forces the imported owner `core.vaults.locked` bit true and leaves wrappers in
`restore_pending`. The unchanged latest Document runtime target still requires
`vault_locked=false`, even though `Documents.Mutate.retry` requests no custody
unlock. A source password hash cannot therefore qualify a fresh receiver login,
and a fresh session alone cannot qualify the native retry prerequisite.

The selected narrow preparation follows the existing Document knowledge-test
fixture pattern (including `DocumentImportLiveTest.grant_runtime!/1`), only in
the current test's privately allocated receiver database:

- BEFORE seeding the source, bind only this test-local identity map to the
  established `PreAuth.owner_scope/1` contract: `account_id == principal_id ==
  vault_id`. Keep all knowledge/version/object IDs and the seven-state graph.
  Capture/export that genuinely seeded identity; assert the same binding after
  import and on the newly issued native session. Do not rewrite receiver
  identities, change shared fixtures or PreAuth, invent a session or replace
  authentication with a scope-selecting adapter.
- FIRST assert the complete restored wire cut equals the captured source cut,
  the source's old session was expired before export, and no such session was
  imported. Assert the actual dummy verifier, locked owner and restore-pending
  wrappers; keep their exact native snapshots.
- After that equality, set only the fixture's exact existing credential verifier
  to a real `Argon2PasswordHasher` hash of the test password. Do not insert a
  credential, account, principal, session, capability, membership or wrapper;
  do not change revocation or epochs for this preparation. Any later authority
  invalidation/reauthorization remains a separately asserted causal test action.
- Use real public `Api.login`, existing Login/ResolveSession/IdentityRepository
  and the native pre-auth/request repositories. Prove the newly issued session
  and token digest/expiry in native storage; never fabricate a session DTO or
  authentication attempt. Actual login before credential preparation must deny.
  Retain and account for its genuine pre-auth attempt/anonymous denied-audit
  effects, then the successful native attempt/session/login audit. They are
  not evidence of post-login complete wire-cut equality.
- With the real fresh session and the receiver still locked, actual public
  Document retry must deny without changing canonical knowledge or work. Only
  then set the exact fixture owner's existing locked bit false as test metadata
  preparation, asserting that this is the sole changed wire field. Keep all
  wrappers, keys, epochs and other authority fields exactly unchanged.
- Execute retry through the unchanged real public API, Mutate, authorization
  locks and native RequestRepo. The test-owned KeyCustodian remains actually
  locked: session `unlocked?` stays false. No unlock, rewrap, key loading or
  custody operation is called. This establishes authenticated native retry
  eligibility after explicit fixture preparation, NOT real unlock, operator
  restore activation, custody composition or production acceptance.

Complete wire-cut equality is asserted before preparation and is not claimed
after that deliberate locked-bit change or ordinary login audit/session writes.
Keep the separate immutable knowledge/history snapshot and compare the precise
preparation delta as well as every subsequent permitted causal delta. Every
fixture allocation is cleaned by the existing harness; no production data or
Vault source/test owner is changed. Independent supplementary DESIGN SPEC then
distinct fresh QUALITY must close before this preparation receives test-only GO.

E2E: NOT RUN, manual-only and deferred. Task 11 native lease/complete saga,
Task 16 strict startup guarantees, phase acceptance, default V3, publication
and production activation are not qualified by Task 10.
