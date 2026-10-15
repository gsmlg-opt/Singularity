# Phase 5 Storage-Reference Compatibility Implementation Plan

> **For agentic workers:** Use the applicable subagent-driven-development or executing-plans skill under parent-managed ownership. Steps use checkboxes. Actual design SPEC and fresh QUALITY passed; preceding Task8 acceptance and causal RED still gate dependent implementation.

**Goal:** Preserve ordinary UUID and accepted canonical-path references through V3 restore without changing frozen custody or original evidence.

**Architecture:** Keep authenticated/persisted inventory `I` unchanged. A Storage-owned, V3-only adapter validates its saga/persisted binding and derives UUID inventory `N(I)` for the existing lease and ciphertext summaries. Document integrity consumes original `I` and verified plaintext hashes.

**Tech stack:** Existing Elixir/OTP, PostgreSQL/Ecto, LocalFilesystemAdapter and authenticated restore adapters; no new dependency.

Status: DESIGN REVIEWED — TaskA qualified after Task8 source commit
`21d066036edbcb3f0a0737ae2dca36a9cea79427`; TaskB test authoring/causal RED
closed at whole gate12238 (70 actual,5 causal FAIL,65 PASS); narrow TaskB
production whole-owner gate30413 passed588d26 (70 actual,0 failures), including
actual full-function/security equivalence. Subsequent bounded Legacy contract
repairs passed owning70, complete retained16 (344actual/0,3 exclusions) and
separate legacy pure5/0, static/frozen/normal-cleanup checks, then actual
NONAUTHOR SOURCE SPEC and distinct fresh QUALITY. TaskC now has complete
9pure/13SQL GREEN and actual independent SOURCE SPEC then distinct fresh
QUALITY. TaskD's exact typed-source whole pure/SQL/static gates and actual
NONAUTHOR SOURCE SPEC then distinct fresh QUALITY now pass; only this bounded
C/D component qualifies. TasksE–G and combined compatibility acceptance remain
pending. Governing
[design](../specs/2026-10-12-singularity-v0.2-phase-5-storage-reference-compatibility-design.md)
and [master Phase 5 plan](2026-10-11-singularity-v0.2-phase-5-export-backup.md).
HEAD at preparation: `38b16f5d4a1f5d870a74d3e3093b3e2a2a0c5041`.
No tests run for this document. Architecture counters: Sol 0/Astra 0, no repair consumed.
Actual distinct independent design SPEC and fresh QUALITY passed draft SHA256
`448b2b83a1e301223eebbd2e610feeb8e27b3024f495084dab9cc5b8c217dfb1`.
Parent factual records are named in the governing compatibility design.
Only review status/citation metadata changed afterward; implementation/runtime
acceptance and every unchecked causal gate below remain pending.

Current B–F component status, 2026-10-13: corrected whole E and all retained F
native gates are CLOSED PASS. Combined actual NONAUTHOR SOURCE SPEC then
distinct fresh SOURCE QUALITY are CLOSED PASS/noP1P2 on exact source14 and
all79 protected entries, at HEAD `9f91c97eb392b4c49c888ed31795d520d15bb8dd`.
Earlier pending/FAIL paragraphs are historical evidence, not current verdicts.
Exact results/review captures are in
`docs/verification/2026-10-13-phase-5-task9-compatibility-handoff.md`.
The bounded26-path local commit is `5619eccdbc2256c4c5aa702b653038fa57ada6fe`;
TaskG/Task10–12 remain unqualified. All earlier pending statements are historical.

Task9E amendment: actual NONAUTHOR DESIGN SPEC and distinct fresh QUALITY
CLOSED PASS/noP1P2 on exact four-file review hashes c161d673/bf434b49/
78848c2e/13ba6ee2. Prior review/gate receipts and exact TaskD history below
remain preserved; they do not qualify E implementation. Parent full reads,
current source16/original frozen56/protected native5 checks and unchanged
existing-owner baseline48pure/0+35SQL/0 with normal cleanup closed before
test-only GO at HEAD `4e2499d5b89664c3e7b63cb1f3136c243b276c83`.
Production GO still requires complete causal RED. Architecture consumes zero
repair rounds and resets no counter; bounded test evidence follows.

Task9E test-fixture correction status, 2026-10-13: first pure compilation FAIL
archive9bee787a remains preserved. Exact four-name test correction ec424f86 to
b85734a0 renamed `binding/1` and its three calls to `document_binding/1` only.
Compiled whole pure gate d695d2 closed exit2:88 actual/27 failures (3 missing
format seam,24 Runtime wiring/order/validation),45 SQL exclusions. Full archive:
`53ec0a2e45fbba574eecd1d948683d333429980df5d6ebf6bf45a5bb8e75327b`.
Four native reader empty/chunk-edge cases passed; E remains unqualified.
First whole SQL17497 closed exit2:70 reported/25 excluded/45 actual,10 cleanup
failures masking primary outcomes,35 retained SQL cases passed. Full archive:
`60f526299acc41ad3f4d87e8d012a97b10373544b8d95e380e8229530cd2e148`.
This is not causal SQL qualification. Root2c53e0b41aa3a5a1c5ee1478 is absent;
normal PG maintenance24169d0 closed EMPTY, archive:
`ea9b9ff7f553d8f0786b2fc23d72fa1fb9174d41ff7eaae95b3a10c58be4c346`.
The bounded snapshot-lifetime test correction is authored; actual NONAUTHOR
review and complete parent pure/SQL reruns remain pending. Compile correction
is separate; snapshot-fixture correction attempt1; E production repair0/Astra
recovery0. Preserve original reviewed architecture/hash receipts as history;
no E production authoring GO or unrun gate PASS is implied.

## Ownership and execution rules

The parent owns formatter, Mix, SQL, services, test serialization, review and Git.
Workers are not alone: preserve Task 8/13 and unrelated edits; freeze source
during parent verification. Use complete owning files/default timeouts for
acceptance. Record actual RED/GREEN commands, exits, counts, excluded coverage,
source hashes and cleanup. Never delete, weaken, skip or relabel assertions.
Necessary goal-serving compatibility amendments are allowed after design/review;
the file map below is responsibility, not a reason to bypass a real scope conflict.

Storage implementation owner:

- Create `apps/singularity_storage/lib/singularity/storage/backup/knowledge_integrity_inventory.ex`.
- Modify `apps/singularity_storage/lib/singularity/storage/backup/knowledge_preflight.ex` and `restorer.ex` in the same `backup/` directory.
- Create `apps/singularity_storage/lib/singularity/storage/backup/knowledge_integrity_audit.ex`; extend the existing new `knowledge_integrity_inventory.ex` for E. Preserve Base `backup/integrity_audit.ex` unchanged.
- Create `apps/singularity_storage/priv/repo/migrations/20261011000700_knowledge_restore_storage_references.exs`.
- Create `apps/singularity_storage/test/singularity/storage/backup/knowledge_integrity_inventory_test.exs` and `document_restore_integrity_test.exs`.
- Extend existing `backup/knowledge_preflight_test.exs`, `knowledge_restore_admission_test.exs`, `logical_v3_import_test.exs`, `restore_rewrap_test.exs` and `test/singularity/storage/integrity_audit_test.exs` under the Storage application.

Runtime owner modifies `apps/singularity_runtime/lib/singularity/runtime/integrity_audit.ex`
and its complete `test/singularity/runtime/integrity_audit_test.exs`. Parent owns
governing documentation synchronization and later Task 11 live/oracle tests.
No change to any of the 56 frozen files, existing migration, lease, reader,
physical adapter, key material, grants, policy, default V2 or production data.

## Task A: Close preceding Task 8 writer repair and design reviews

- [x] Parent finishes the separate exact two-form `00600` writer correction's
  causal full-owner RED, source implementation, full gates, SOURCE SPEC and fresh
  QUALITY. Its current UUID tests are SQL shape evidence only; preserve that label.
- [x] Parent reads both new documents completely, obtains independent design SPEC
  then fresh QUALITY, records exact reviewed hashes, and links them from the
  governing Phase 5 documents. Resolve findings before dependent implementation.
- [x] Verify actual baseline/dirty ownership and the unchanged frozen registry:

```sh
git rev-parse HEAD
git status --short
sha256sum .devenv/phase5-frozen-baseline.sha256
sha256sum -c .devenv/phase5-frozen-baseline.sha256
```

Expected registry hash is `d0296d241c66e382baa09a0a092fe8add6df66364d5f2d5644f4f4ea1963a050`;
all 56 entries must match. Never regenerate the registry to accept drift.

## Task B: Characterize and correct V3 preflight/deferred admission

Depends on A. Storage owner; parent runs commands.

- [x] Add independent UUID-positive and wrong-UUID/path-negative cases preserving
  existing canonical-path fixtures. Prove both preflight and actual deferred
  commit: complete canonical digests, loading/validated admission, finalizer and
  rollback assertions remain active. New tests must expose each old predicate,
  not stop at an earlier rejection and claim both boundaries characterized.
- [x] Run the complete preflight/admission owners below; record the causal failures.
- [x] Implement only two-form reference agreement in preflight and additive
  `00700`. Use an exactly-once expected-clause transformation or reviewed complete
  function replacement. Compare before/after `pg_get_functiondef`, owner/ACL and
  settings; assert all other body text and security attributes remain equivalent.
- [x] Run the same owners GREEN, then Task F's complete retained gate. Preserve
  accepted `00300` and its destination digests/deferred validation unchanged.

```sh
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/knowledge_preflight_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_restore_admission_test.exs --seed 215378 --warnings-as-errors
```

## Task C: Implement the two-view adapter and original-evidence binding

Depends on B; no Restorer/Runtime routing change until the adapter's own RED exists.

- [x] Add complete-file tests for `project(storage, cut)`, `prepare(repo, storage,
  imported)` and `load_plaintext_material(context, binding, projected_entry)`.
  Cover UUID identity, canonical/mixed conversion, exact non-reference equality,
  order/count, canonical IDs, duplicate physical identities, wrong paths/UUIDs,
  unknown logical version and path conversion through a nonlocal adapter.
- [x] Add SQL counterproofs for wrong manifest ID/hash/tag, original inventory
  hash, owner/count/status/root, unequal original cut/handoff, missing/extra
  objects, changed persisted reference/metadata and wrong projected position.
  Compare existing Restorer saga hashing against the new helper byte-for-byte.
- [x] Run both commands below RED; absence of the new module alone is initial RED,
  not proof that the binding counterexamples are meaningful.

Initial authoring and constructor corrections are recorded in the Phase 5
report. The final complete initial pure gate closed624d7a/exit2:22 reported,
9 actual failures,13 SQL exclusions. The complete initial SQL gate
closed d7d88e/exit2:22 reported,13 actual failures,9 pure exclusions.
Both now reach the missing concrete adapter guard; these are wiring RED only.
Original failed compilation, incorrect cut-constructor failures and incomplete
SQL capture remain historical FAIL, not substantive negative proof. Actual
source/persisted binding behavior, production and GREEN qualification remain
pending. The actual normalized Imported cut omits wire-only count fields;
the tests preserve optional supplied-count validation and separately witness
the committed saga count. No existing assertion or frozen source was changed.

The first concrete TaskC adapter source is authored, not yet compiled or
qualified. Raw source SHA3e4febf344e4c9f95131d0fd443abb2b0a80102b0fce950596e57368a698ae25;
owning tests now additionally assert the actual owner GUC alongside backend,
role and repeatable-read snapshot witnesses. A nonauthor bounded read-only
advisory found no confirmed blocking defect, but is not acceptance SPEC or
QUALITY and does not replace either complete owner gate. Restorer/Runtime
composition remains unchanged; TaskD implementation waits for TaskC GREEN.
- [x] Implement explicit authenticated-version dispatch and design interfaces.
  `prepare` checks existing imported saga and original rows in a consistent
  migration transaction. Loader checks the original entry then delegates the
  EXACT projected single entry to the existing four-key-binding loader in that
  same transaction; return its wrappers/material without alteration. Do not
  return raw keys, widen legacy inventory validation or create authority flags.
- [x] Run both owners GREEN; assert invalid bindings do not call the base loader,
  and real SQL cases prove connection/snapshot consistency and persisted refs.

Corrected complete pure gate closed6746e0/exit0:9 actual/0 failures,13 SQL
exclusions. Complete SQL closed7fca5f/exit0:13 actual/0 failures,9 pure exclusions,
147.6s, including the real same-backend/RR/owner and distinct-backend committed
mutation witnesses. Parent static closed488c28/exit0 (format/WAE/zero cycles),
source receipt matched916dab, frozen56 matchedab7632 and normal SQL cleanup is
recorded in the acceptance report. Actual NONAUTHOR SOURCE SPEC by
phase5_precommit_native_quality and distinct fresh QUALITY by
phase5_inventory_source_quality both closed without findings on source1f360f65
and testa2044e65. Parent factual records are
`.devenv/phase5-task9c-recording-repair1-source-spec.md` and
`.devenv/phase5-task9c-recording-repair1-quality.md`.
ComponentC is locally accepted for TaskD test-first work, not combined TaskF/G
qualification or a standalone commit. No Restorer/Runtime routing or Document
plaintext acceptance yet.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/backup/knowledge_integrity_inventory_test.exs --seed 215378 --warnings-as-errors
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/knowledge_integrity_inventory_test.exs --seed 215378 --warnings-as-errors
```

## Task D: Compose unchanged lease and honest integrity summaries

Depends on C. Storage owns Restorer; Runtime owner coordinates its separate file.

- [x] Add RED in `restore_rewrap_test.exs` for genuine V3 prepare errors occurring
  before issuer/commit, original Imported/Rewrapped equality, exact UUID lease
  inventory, wrapper context and unchanged legacy option behavior. Retain issuer
  failure, commit failure/revocation and all old credential/rewrap assertions.
- [x] Add Runtime RED proving both ciphertext entrypoints derive the same `N(I)`
  while retaining original `I`; reject cut mismatch and actual-summary mismatch.
  Fakes record exact arguments/order and prove denial, not real custody success.
- [x] Parent runs Task E's complete pure command and the integration command
  below. Record expected failures before implementation.
- [x] Make Restorer options preparation return `{:ok, options}` or Error and
  propagate before `issue`. Select V3 from authenticated `cut.logical_version`.
  Keep legacy options, original handoffs, key values and issuer lifecycle intact.
- [x] Runtime keeps original-cut equality, uses projected inventory for ciphertext
  and actual lease-summary comparison, and retains original inventory separately.
  Leave `StorageIntegrityAudit.inventory_sha256/2`, V1 encoding and structs intact.
  Never replace summary digests or present converted inventory as original cut.
- [x] Rerun owning commands GREEN; independently inspect the dataflow and unchanged
  lease/reader hashes. This still does not qualify Task 11 live restoration.

Actual whole pure3 RED closed76ebf3/exit2: Storage8actual/0 with22SQLexcluded,
Runtime31actual/19fail;39actual total. All19 failures reach the absent V3
projection, not native fixture setup. All old cases remain unchanged.
Whole RestoreRewrap SQL closede60607/exit2:21reported/18actual/15fail/3pureexcluded,
167.9s. All15 complete native failure sections classified:10 missing V3
preparation denials and5 missing projected material-loader options. All native
authenticated bundle/import constructors pass; the existing cut mismatch
already denies. Full archive `.devenv/phase5-task9d-initial-red-sql-complete.log`
SHA cc677acf5209522a1ac8a7df7f5a21b2da76a36a885014272ec23145cb431e38.
Earlier two whole SQL runs also closed15FAIL but had truncated native output;
retain as incomplete-output history, not qualification. No test/source changes
between the three SQL runs; this was evidence capture, not Sol repair attempts.
Source receipt matched d1dd0c; rootfda1934c absentd5083e and maintenance4bbec6
closed0 EMPTY normally. The complete old tests remain byte-identical prefixes:
Storage23930bytes/48237f9d and Runtime11332bytes/51382c89.
Root's bounded TaskD production composition now passes whole pure3f6b115exit0:
39actual/0fail,22SQLexcluded; whole RestoreRewrap SQL8d71f0exit0:
18actual/0fail,3pureexcluded,194.5s. Full archives b433c38c/e50f3749;
normal root a5a82a2f absent752dcc. Issuer waits for prepared V3 options;
Runtime keeps original cut/I and validates summaries over projected N(I),
without rewriting any summary evidence. Legacy options/guard remain unchanged;
necessary bare-Error return is corrected to the declared error tuple.
Required static gate926e72exit1 detects a two-file cycle: Restorer calls the
adapter, whose `%Restorer.Imported{}` pattern requires struct expansion from
the Restorer source file. No digest-call dependency exists. The smallest
compatibility repair keeps the exact same struct-module tag using
`%{__struct__: Restorer.Imported}` rather than expansion. Source repair1d5f6216
closed; inverse recovers old1f360f65 byte-for-byte. No type acceptance, hashes,
metadata, transaction, summary or error semantics change. Source/verification
and actual independent reviews still pending; static FAIL remains historical.
Typed repair1 complete format/WAE/xref gate5e0b09 closes exit0 with zero cycles.
The C whole pure command874f09 closes9actual/0fail/13SQLexcluded; whole C SQL
50a72e closes13actual/0fail/9pureexcluded,149.7s, on exact typed source1d5f6216.
Full archivesf366a915/9fde11f6; actual root5cdbf16b absent82e976 and normal
maintenance1730cb closes0 EMPTY. The D whole pure3 now closes8189b3/exit0:
39actual/0fail/22SQLexcluded; whole RestoreRewrap SQL247558/exit0 closes
18actual/0fail/3pureexcluded,120.9s. Complete archives1e5ef566/ceadc19e.
Actual root224584b4 absent4a12ef; normalmaintenance3268e3 closes0 EMPTY.
Fresh static01d1a4 exit0 verifies format/WAE/zero cycles, archivee7a13d89;
source16receipt1119efdb matched8ee021 and originalfrozen56matched35be64.
Actual NONAUTHOR D SOURCE SPEC and distinct fresh SOURCE QUALITY both now
CLOSEDPASS/noP1P2 after whole source/tests/governing/native import/material/lease/
reader/crypto reads and exact six hashes, old-prefix and typed-inverse proofs.
Parent received-closure capture `.devenv/phase5-task9d-current-source-reviews.md`
SHA7f402bb18f60ae0a1ab5f0bf6f87df96284a470be20bd333ae5c4f3aef6ad46d.
TaskD is qualified only as a bounded component; combinedF/localcommit/Phase5
remain pending. TaskE test/source GO still requires its NEW amendment's actual
independent design SPEC then distinct fresh QUALITY; prior Dreviews do not
review those new facade/size/fault-injection decisions.
This necessary compile-dependency repair extends the owning C file only, not
product scope or frozen substrate. Initial production FAIL, bounded Solrepair1
authored, no failed repair round yet/Astra0. No TaskE Document source-pin
verification or live Task11 qualification yet.

```sh
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs --seed 215378 --warnings-as-errors
```

## Task E: Complete Task 9 Document plaintext verification

Depends on D's complete exact-source gates and actual independent reviews.
Storage/Runtime owners coordinate under the parent; retain every master Task9
requirement. The governing design's Task9E section defines the chosen facade,
size proof and the only permitted fault-injection exception. No new project,
process registry, dependency, authority or production migration belongs to E.

- [x] Parent fully reads this plan, compatibility design and both synchronized
  master documents. Obtain actual NONAUTHOR DESIGN SPEC, resolve findings, then
  distinct fresh QUALITY on the exact four-file hashes. Record reviews before
  issuing test-only GO; architecture authoring alone does not open source GO.
- [x] Freeze current source/ownership and original frozen56 receipts; verify
  C/D accepted source and all old test bodies remain. Record received Sol/Astra
  repair counters, distinguishing expected initial TDD RED and fixture failures
  from failure-directed implementation repair rounds. No task rename, new symptom
  or design amendment resets counters; parent owns routing and validation.
- [x] Parent runs the existing whole Runtime/Base integrity, rewrap and C pure/SQL
  owners using the commands below, omitting only the not-yet-created Document
  test from this initial baseline. Record actual counts/exclusions and normal
  cleanup. Existing
  failure is diagnosed and retained, never relabeled a causal E RED.
- [ ] Add pure boundary tests using all nine literal P/C vectors in the design,
  adjacent wrong lengths/gap values, malformed/negative/noninteger/missing
  values and supported-counter overflow without large allocation. Independently
  assert actual public Format version/header/chunk/counter constants. If needed,
  use only internal `KnowledgeIntegrityInventory.validate_plaintext_size/2`;
  no generic size module/configuration or expected values derived from it.
- [ ] Extend the complete Runtime integrity test with explicit authenticated-V3
  target selection and the existing no-version legacy map path. Exact module
  callback `/3` and tuple-context `/4` forms receive TWO-key search binding,
  ORIGINAL I and actual validated typed-summary pairs. Preserve both summary
  validators and all rebuild/audit/revocation assertions. Test missing V3
  callback, unknown explicit version, wrong/malformed summaries and helper
  error/malformed result; deny before rebuild/audit and revoke. Legacy V1/V2
  adapters lacking the new callback must preserve their original sequence.
- [ ] Create the complete `document_restore_integrity_test.exs` with public
  KnowledgeBackupFixtures constructors, sequential source/different owned empty
  migrated destination, actual LocalDestination/BundleReader/LogicalBundleVerifier
  authentication and Restorer.import. Reuse public fixture APIs; do not copy
  private helpers wholesale or forge Verified/imported saga/native authority.
  Assert genuine COMMIT, original-I persisted equality and imported saga before
  calling E. Verify UUID/canonical/mixed positives, seven historical/all-state
  Document versions, Doc-only retained PDF after Asset retirement and Asset-only
  entries. Expected source bytes/digests derive from independent fixture oracles.
- [ ] Qualify the bounded one-shot snapshot fixture correction in this new test
  file only. Wrap only returned LocalDestination public
  `file_system.close_snapshot`; call the original native callback and preserve
  its exact return/raised outcome. Helper-owned atomic counters retain actual
  `:ok` successes and foreign-owner closes without content/key/authority or
  Replay/device inspection. Require0/0 after authentication before import and
  exactly1/0 immediately after genuine import before any semantic callback.
  BundleReader.reduce_verified already closes consumed Replay once. The
  unconditional finalizer calls discard_verified only for zero observed
  successful closes, requires actual `:ok`, then asserts exactly1/0. Never
  double-discard consumed input, accept duplicate/foreign successful closes,
  convert `:einval` to success, or change frozen Reader/Restorer behavior.
  Preserve all import/original-I/reader/lease/history/corruption assertions,
  default timeouts and unconditional disposable-destination cleanup. Obtain
  actual NONAUTHOR review of the exact correction before whole parent pure/SQL
  reruns; prior masked cleanup failures are not causal helper RED evidence.
- [ ] Qualify actual encrypted empty and chunk-edge originals using unchanged
  AuthenticatedReader, with exact observed byte length/hash against independent
  originals. This is local reader evidence, not a native restore-lease witness.
  A recording loader/issuer or known fixture hash never proves a lease used P.
- [ ] Add the causal wrong-digest input: transform every sharing Document's
  source_digest to the same wrong32 bytes, authenticate the resulting bundle,
  genuinely import/commit and authenticate actual plaintext; E then denies.
  Preserve preflight/admission success instead of counting their rejection as
  Document-helper proof.
- [ ] Add the causal stronger size case: transform all sharing immutable Doc
  sizes and Object size to the same wrong value before authentication/import.
  After actual commit, temporarily correct only mutable Object size for the
  genuine reader, obtain its actual bytes/hash, then commit Object size back to
  the wrong value matching Docs. Assert ciphertext/original-I/all other pins
  unchanged and current Doc/Object equality; E must reject via original C(P).
  If readily supported by existing public material/issuer composition, also
  execute this barrier with actual frozen RestoreIntegrityLease; otherwise
  explicitly retain that native-lease proof as NOT RUN/Task11, without faking it.
- [ ] After genuine import, separately reject missing/duplicate/extra/reordered
  and malformed hashes/extra map keys, foreign or extra-key bindings, changed
  persisted original reference, and supplied N(I) replacing path-containing I.
  Assert original saga commitment, no audit completion and no publication.
  Do not normalize any supplied reference or reduce the nine-field inventory.
- [ ] Establish the ready-history fault-injection baseline in this new test file
  only: genuine committed valid import, successful helper baseline and normal
  immutable fragment UPDATE denial. Snapshot actual trigger definitions/function
  definitions/enabled states for versions/fragments/admission plus Document RLS
  enabled/forced flags, policies and ACLs. Require original guards active.
- [ ] Select old-ready nonhead ordinal1, prove zero references from EVERY actual
  referencing FK (including citations/search), and build a valid different
  text/digest/id with actual DocumentFragment.new/1. Preserve every other field.
  In ONE separate native migration/table-owner transaction, first execute
  `SET CONSTRAINTS ALL IMMEDIATE`, then disable only
  named `document_fragments_immutable_guard` on `content.document_fragments`, update exactly
  that old-identified tuple, re-enable the same trigger BEFORE COMMIT and observe
  native commit success. No version/admission write or other disabled trigger;
  all RLS and deferred completion checks stay active. The existing ready-fragment
  return path, not a changed function, permits this one canonical-row corruption.
  Immediate transaction-local timing executes ALL native deferred constraints
  during UPDATE before the guard-restoring ALTER; no pending event is bypassed
  and no check is disabled. Follow the existing lifecycle fixture at line249.
- [ ] Require exact trigger/function/enabled-state/RLS/policy/ACL restoration,
  native ordinary forbidden UPDATE rejection afterward and DDL/data rollback
  plus restored snapshots on injection failure. Then invoke E in its OWN fresh
  transaction, never inside the corruption transaction. Require the historical
  extracted aggregate mismatch denial, imported saga intact, zero completion
  and unpublished destination. Always close fixture-owned resources. If the
  native witness fails, diagnose; do not weaken the mismatch requirement or
  substitute preflight, admission, lifecycle or nested-transaction rejection.
- [ ] Parent runs the complete expanded pure and SQL commands below to causal
  RED before E implementation. Missing export/callback can establish wiring
  RED only; failed fixture/auth/import/commit/restoration cannot be labeled a
  causal mismatch. Record complete failure sections and every prior failure.
- [ ] Implement `KnowledgeIntegrityInventory.verify_document_sources/4` per the
  design: exact two-key binding/hash closure, original saga hash/refs/metadata,
  every historical source pin/digest, immutable ciphertext-size law plus current
  metadata agreement, and incremental all-ready fragment validation. Use the
  established fresh consistent migration transaction and correct internal
  `{:ok, value}`/external `:ok` return conversion. No fabricated C.Context or
  claimed independent manifest-hash/tag/root authority absent from `/4` inputs.
- [ ] Add the unfrozen KnowledgeIntegrityAudit facade with `/4` Document delegate
  and `/2` unchanged Base rebuild delegate. Runtime stores version only from the
  authenticated cut (or preserves established no-version legacy behavior),
  requires Document callback only for V3 and invokes it after actual typed
  summary validation with original I. No Base->C edge, frozen-source edit,
  new option or V1/V2 callback requirement. Task10 later owns unified rebuilding
  in the facade; E does not claim a complete unified rebuild.
- [ ] Run the same whole pure/SQL owners GREEN, including successful native
  import/reader/corruption/restoration prerequisites and each substantive denial.
  Add complete C pure/SQL owners because the C file changes; retain complete
  old Storage integrity and rewrap tests. A helper denial leaves committed
  import/rewrap unpublished; never claim their rollback.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_runtime/test/singularity/runtime/integrity_audit_test.exs apps/singularity_storage/test/singularity/storage/integrity_audit_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_integrity_inventory_test.exs apps/singularity_storage/test/singularity/storage/backup/document_restore_integrity_test.exs --seed 215378 --warnings-as-errors
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/integrity_audit_test.exs apps/singularity_storage/test/singularity/storage/backup/document_restore_integrity_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_integrity_inventory_test.exs --seed 215378 --warnings-as-errors
```

- [ ] Run complete TaskF retained commands, separate Task8 gates, static
  format/WAE/zero-cycle and unchanged frozen56/source receipts. Parent records
  actual counts, exclusions, full outputs, cleanup and cumulative repair rounds.
  Obtain actual nonauthor SOURCE SPEC then distinct fresh QUALITY on the exact
  implementation; resolve findings and rerun affected/required checks without
  replacing complete acceptance with selected tests. No E/F local handoff before
  these close; no Task11/live-lease/normal-publication claim from E reader tests.

## Task F: Retained gates, independent review and bounded local handoff

Depends on B–E. Parent only. Existing counts are historical evidence, not expected
new totals: preflight 39, import owners 32, historical admission 24, complete
retained selection 334 actual SQL, separate legacy pure 5 and downstream 186.
Run every whole file below; report actual new totals and separately cover exclusions.

```sh
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/logical_v3_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_preflight_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_restore_admission_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_restore_digest_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_backup_fixtures_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_schema_ddl_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_historical_admission_test.exs apps/singularity_storage/test/singularity/storage/document_lifecycle_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_link_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_asset_lifecycle_guards_test.exs apps/singularity_storage/test/singularity/storage/note_source_set_sealing_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_sources_test.exs apps/singularity_storage/test/singularity/storage/knowledge_rls_test.exs apps/singularity_storage/test/singularity/storage/knowledge_grants_test.exs apps/singularity_storage/test/singularity/storage/knowledge_schema_test.exs --seed 215378 --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs --seed 215378 --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/backup/logical_schema_v3_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_record_codec_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_bundle_verifier_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs apps/singularity_core/test/singularity/core/knowledge_export_test.exs apps/singularity_core/test/singularity/core/knowledge_export_manifest_test.exs apps/singularity_core/test/singularity/core/note_markdown_sources_test.exs apps/singularity_runtime/test/singularity/runtime/note_markdown_source_export_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs --seed 215378 --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format --check-formatted, compile --warnings-as-errors, xref graph --format cycles --fail-above 0
sha256sum -c .devenv/phase5-frozen-baseline.sha256
git diff --check
```

- [x] Rerun the separate Task 8 complete exporter/security and pure owning gates
  from the master plan because writer/restore predicate agreement is required.
- [x] Record exact source/migration lists, unchanged accepted migrations/frozen56,
  test results, SQL function equivalence/ACL evidence and residual risks. Obtain
  actual nonauthor SOURCE SPEC then separate fresh QUALITY on that exact diff.
- [x] Parent makes a small local reviewed commit, preserving unrelated files:
  `fix(restore): preserve v3 storage references across integrity verification`.
  Record commit SHA and exact verification scope; no publication or phase acceptance.

## Task G: Required Task 11 live qualification before Task 12

Depends on F and master Task 10. Parent owns the existing Task 11 live fixture,
`apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs`,
`apps/singularity_storage/test/singularity/storage/backup/logical_v3_failure_test.exs`
and the narrow knowledge-oracle additions in
`apps/singularity_runtime/lib/mix/tasks/singularity.test.restore.ex`.

- [ ] Add mandatory actual normal Asset finalization → UUID persisted reference →
  explicit V3 export/authentication/preflight → real deferred admission commit →
  unchanged lease/real wrappers/ciphertext/AEAD → Document digest/search/completion.
- [ ] Compose the V3 search-rebuilder as `{KnowledgeIntegrityAudit, MigrationRepo}`
  with Task10's unified implementation; preserve original-I Document callback
  and actual typed native lease summary. Keep native V1/V2 Base rebuild and old
  restore-oracle assertions unchanged. Qualify the size-mutation witness through
  the actual frozen lease if E established only local reader proof; recording
  issuer/material ports and fixture-known hashes do not satisfy this check.
- [ ] Also qualify preserved canonical-path and mixed inventories with real local
  encrypted bytes and unchanged lease, plus wrong headers/wrappers/plaintext,
  mutation and saga failures. Compare exact original refs, canonical pins, bytes
  and both inventory views. Keep all existing frozen fixtures and legacy assertions.
- [ ] Run the master Task 11 complete live/legacy commands and independent
  `mix singularity.test.restore` oracle; record actual results and independent
  SPEC/fresh QUALITY. Fakes and Task 8 SQL-shape tests cannot substitute for this.

```sh
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_failure_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs --seed 215378 --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_runtime/test/singularity/runtime/backup_vault_test.exs apps/singularity_runtime/test/singularity/runtime/restore_vault_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs --seed 215378 --warnings-as-errors
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.restore
```

- [ ] Only qualified Tasks 8–11 permit the separate Task 12 default change.
  Complete permitted README acceptance remains master Task 19; E2E is NOT RUN.
  Architecture completion, these documents and earlier green gates grant no
  production activation, release or browser acceptance.

## Native constraint-timing fixture repair1: required whole-owner rerun

Initial E source pure20f81b CLOSED0:88actual/0fail/45SQLexcluded. Initial whole
SQLdd7b31 CLOSED2:45actual/44PASS/1FAIL/25pureexcluded,453.5s. Native55006 at
the new historical-fragment ENABLE TRIGGER prevented the required corruption
COMMIT/independent helper-denial witness. SOURCE SPEC CLOSEDFAIL1P2, no confirmed
E production finding. Logs a4291e1c/edb02d0c and inverse/diagnosis909b68d8 retain
full native failures, original C/Runtime byte inverses and normal root/PG cleanup.

- [ ] Review the exact test-only IMMEDIATE-before-disable correction, with all
  other DocTest bytes unchanged and C/Runtime/facade/protected5/frozen56 preserved.
  Obtain actual NONAUTHOR correction SPEC then distinct fresh QUALITY; source
  reviews cannot waive the failed native witness.
- [ ] Parent formats only the new owning test, records a new versioned18source
  receipt (never regenerate original frozen/protected manifests), and reruns
  BOTH complete expanded E pure/SQL commands above, without line filters.
- [ ] Require all native constraints active, actual rollback and later COMMIT,
  exact guard/function/RLS/policy/ACL restoration, normal forbidden UPDATE denial
  and the OWN fresh helper transaction's old-ready aggregate rejection. Native
  FK/constraint/fixture/lifecycle failure is not this substantive mismatch proof.
- [ ] Close normal disposable-root/PG cleanup; repeat static/retained gates and
  actual whole E SOURCE SPEC/freshQUALITY before acceptance. No acceptance yet.

Counters are retained: earlier compile correction and snapshot fixture attempt1;
native constraint-timing fixture repair1 now authored, verification NOT RUN;
Eproductionrepair0/AstraRECOVERY0. No native-source or product-scope change.
