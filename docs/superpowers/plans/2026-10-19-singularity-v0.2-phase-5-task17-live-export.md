# Phase 5 Task17 Live Portable Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development for parent-managed independent work, or superpowers:executing-plans for serialized execution. Read the full design and applicable repository instructions first. Parent owns delegation and exclusive VM/gate execution.

**Goal:** Prove genuine Runtime.Api portable bytes, exact source closure,
privacy, boundedness and denial/fault cleanup using native published originals
and a separate independent offline oracle.

**Architecture:** Add test-only native fixture/observer and offline-oracle
modules plus live/privacy tests. Forward only trusted internal
`:knowledge_export_write` into the existing Writer write callback. After actual
strict digest-backing RED and new ordered design reviews, detach generated
digests only in the two existing private Spool/Writer hex helpers. Preserve
Spool/Writer/custody/public interfaces, bytes, fixed limits and strict assertions.

**Tech Stack:** Elixir/ExUnit, existing Runtime.Api/OTP supervision, permanent
PostgreSQL roles, real Oban extraction/native DownloadLease, test-only Jason
oracle (production uses built-in JSON/:elixir_json), SHA-256,
existing local encrypted storage and qualified private artifact roots.

Canonical plan path:
`docs/superpowers/plans/2026-10-19-singularity-v0.2-phase-5-task17-live-export.md`.
The companion design is
`docs/superpowers/specs/2026-10-19-singularity-v0.2-phase-5-task17-live-export-design.md`.
This is the canonical plan candidate, not implementation GO. Task16 has actual local
acceptance at tested/reviewed source
`5d7cd738c1049071987f93d6ec6c6dd68d4e409b` and documentation commit
`a0fb0f854509cb69e42ec598deb6aa2f4116729f`. Source43 manifest SHA-256 is
`b7ec2220705f0bab1a7c467fcbbeadb0b60f06fbe2dcaa508d8e16db158aca2f`;
three-document manifest SHA is
`641b7eb29d09f2ea0f3e8245a518c1c2425b557847ff6dbf41fb03f087fa98f2`.
FULL actual closure receipt
`.devenv/phase5-task16-docclosure-actual-closure.json`, SHA-256
`20082e7b57a9444470791ce3c53a0f79c4a24422e8781f2b69dcef1bae929084`,
records ordered actual reviews,207/0 doc gate, own post EMPTY0, owned stop/
byte-exact1601-byte archive0 and committed-blob/literal clean closure. All Task16
commands are closed; its PG identity was stopped; all RAM data/fixtures remain
retained. Task17's separately reopened active qualification identity is pinned
in the companion design; do not reuse Task16's stopped identity operationally.
Source commits `2340fd4efc90cc06332ded6e66d33c19548a3b39`,
`16875fea0cfd873f4f2809a046147842246eb4bb` and `5d7cd738…` are slices of one
qualified final tree, not separately tested intermediates.
The immutable307-line source handoff's documentation-PENDING snapshot is
resolved by the separate receipt; preserve both. Historical native117/C13/
8fb1142 failures and prior drafts remain historical evidence, not today's
unaccepted-Task16 premise. The preceding canonical pair actually passed ordered
DESIGN SPEC/NEW distinct QUALITY and root GO before test implementation; exact
receipts are recorded in the companion design. This digest-backing amendment
requires fresh independent DESIGN SPEC, NEW distinct QUALITY and root GO before
its production repair, not renewed human approval.

## Execution and ownership rules

Worktree: `/home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-5-export-backup`.
Baseline HEAD: `a0fb0f854509cb69e42ec598deb6aa2f4116729f`, with tested source
`5d7cd738c1049071987f93d6ec6c6dd68d4e409b` immediately below its doc-only commit.
Before source work, verify those accepted source/documentation/actual-receipt
pins. Preserve unrelated/user/other-worker edits.
No Task18/19, Vault behavior, migration, new dependency, publication, deployment,
production activation or browser/E2E work. Do not weaken or edit old assertions.

Parent owns sequencing, public design promotion, source pins/attribution,
architecture contract additions, reviews, all VMs/tests/formatters and local
commit. Workers edit only explicitly allocated files. Maximum three active
agents includes parent: start A, then B and C only after A freezes shared files
and parent can keep this concurrency bound. A serialized parent review/gate is
not permission to overlap live database/resource owners.

- A: new `test/support/knowledge_export_live_fixture.ex`, and the one context
  entry in `lib/singularity/runtime/knowledge/export.ex` only after causal RED.
- B: new `test/support/knowledge_export_offline_oracle.ex` and
  `test/singularity/runtime/knowledge_export_live_test.exs`, including fault case.
- C: new `test/singularity/runtime/knowledge_export_privacy_test.exs`; consumes
  A's fixed public fixture interface without editing it concurrently.
- D: after amendment GO, only the existing private hex helper body in
  `apps/singularity_storage/lib/singularity/storage/knowledge_export/spool.ex`
  and `writer.ex`; no other production line or old test changes.
- Parent: minimal additive architecture assertion if required, exact old-byte
  inverses, new digest architecture owner, baseline/gate records, integration
  ownership and review findings. Parent may own A's one-entry forwarding repair
  after the genuine Api RED, without overlapping A's fixture ownership.

All paths above are under `apps/singularity_runtime` except parent-owned
`apps/singularity_web/test/singularity/architecture/knowledge_export_composition_contract_test.exs`,
new `knowledge_export_digest_backing_contract_test.exs` in that same architecture
directory, and D's two explicit storage files above. Existing NativeAssetFixture,
NativeTest, Api, Artifact, Read, Markdown integration and canonical baseline
assertions remain unchanged. Spool/Writer change only by D's two helper bodies.

## Task A0: Close prerequisites before implementation

- [ ] Parent reads complete private design/plan, promotes only the reviewed pair
  to the named public targets, obtains independent DESIGN SPEC then a new
  distinct QUALITY review, and resolves findings without changing boundaries.
- [ ] Verify the accepted Task16 source43, three local source commits,
  source/spec and NEW distinct quality, doc commit and final actual receipt
  pinned above. Preserve native117 and all historical FAILs in the immutable
  source handoff; do not rerun or relabel them as current prerequisite failures.
- [ ] Use the accepted retained-RAM IO-Q1 lane and frozen existing
  `test/support/knowledge_export_qualification_root.ex` helper
  `KnowledgeExportQualificationRoot.allocate!/1`, SHA-256
  `64108a2958159e41dc9962c12cd0044b4f31ee3a971549e8c73bd5d554f7192f`.
  Root alone prepares reviewed Task17-specific lifecycle/wrapper/guards,
  NEW active identity, fresh log/raw/
  archive paths and immutable phase-candidate pins before execution. Validate
  retained roots/settings/roles against accepted facts; a stopped cluster is
  never an active-lane PASS. Do not rerun native250's controller, old active
  expected PID or source guard requiring unchanged43 HEAD. Do not invent
  tmpdir symlinks, mounts, disk tuning, quota changes or larger product timeouts.
- [ ] Parent records existing dirty files and assigns nonoverlapping author
  windows. All runtime commands remain exclusive, with actual ownership-post
  records and natural exit statuses. No old failure may be reclassified to
  make this prerequisite green.

## Task A1: Add native fixture support without modifying old helpers

- [ ] Create `knowledge_export_live_fixture.ex` with fixed public functions
  `with_fixture/1`, `publish_sources!/1`, `build_graph!/1`, `export_config/2`,
  `materialize!/3`, `assert_quiescent!/1`. Keep observers nested in this support
  owner. Tests are integration-tagged and async:false.
- [ ] Wrap `NativeAssetFixture.with_fixture/1`, preserving real bootstrap,
  login/unlock DTO.Session, disposable ResourceOwner and permanent role grants.
  Save/restore settings that native startup changes; register owned cleanup
  before publication. Start one private actual Task.Supervisor, never a fake
  owner or replacement global service. Use disjoint qualified artifact/offline/
  storage/backup roots and immutable neighbor sentinels.
- [ ] Build the trusted export runtime using real dependencies from
  `Api.production_runtime/0`: real AuthorizationDependencies/IdentityRepository/
  KeyCustodian, Authorize, OperationScope, ScopedRepo, RequestRepo, locks,
  AuditSink, AssetRepository and DownloadLease. Keep real authorization custody
  even when the export-acquisition observer delegates native export_lease.
- [ ] Add configured facade callbacks verbatim in shape:

```elixir
%{
  export_knowledge: &Export.run(runtime, &1, &2),
  knowledge_export_entries: &Export.entries(runtime, &1, &2, &3),
  read_knowledge_export_chunk: &Export.read_chunk(runtime, &1, &2, &3, &4),
  close_knowledge_export: &Export.close(runtime, &1, &2)
}
```

- [ ] Prove all four callback routes with positive actual results through Api,
  and retain a default-production-Api successful smoke using genuine fixture
  settings. Reject fake session structs/handles, fake authorizers or direct
  Export-only proof. Do not copy private NativeTest helpers that seed publication
  with SQL or discard successful native deliveries.
- [ ] Parent runs the first focused new integration case. A compile/setup
  failure is an implementation defect, not causal behavioral RED. Assert fixture
  teardown stops all owned tasks/supervisors and preserves borrowed repo
  identities; it must not stop unrelated infrastructure.

### A1 abort-lifecycle amendment after actual live3 cascade

- [ ] Amend both canonical documents with the source-established existing native
  completion fence; obtain independent DESIGN SPEC, NEW distinct
  QUALITY and root GO before implementation. Preserve A preimage SHA-256
  `335ce30768e55aba6ffad766221795935bae4d9a5dcb09c67de67d4b157411c0`,
  all old helper/source bytes and all historical FAILs.
- [ ] B first adds a new literal-test declaration using only existing fixture
  operations: sacrificial unlinked caller completes actual native Api bytes,
  issuance/revoke ACK/DOWN, sends exact resource identities and waits. External
  controller monitors it and the real unregistered ResourceOwner, kills caller,
  records every cleanup fact and requires exact settings/trace/helper/root/
  sibling outcomes. It must compile/run against old A; setup or absent-positive-
  witness failure is not behavioral RED.
- [ ] Root freezes source and reviews the finite C7 execution tooling. Add only
  the diagnostic `abort-red` route through unchanged native runner with an
  actual pinned literal `knowledge_export_live_test.exs:<new-test-line>`, seed
  215378 and warnings-as-errors. Installed Mix location selection overrides
  runner inclusion; do not append another `--only` tag (OR would select all
  integration cases). Obtain actual causal RED and independent own post.
  No location/tag filter reduces any final whole-owner gate.
- [ ] Record old-A failure before narrowly owned fallback containment. Validate
  the complete known installed trace state, dead exact collector/custodian and
  qualified child/parent identity before touching it; preserve all foreign
  state/siblings. Record actual containment, never award cleanup credit.
- [ ] A alone implements the design's checkpoint-owned initial/control/root
  registry, exact temporary child IDs under existing native infrastructure,
  atomic context publication and one pre-native-shutdown owner finalizer.
  Control survives the accepted deliberate infrastructure-stop/recovery path.
  No old-helper/native/production edit, new supervisor type, selector or public
  fixture function. Use a fresh locally owned exact monitor at every stop.
- [ ] Bind exact native-global/private task-supervisor ownership and empty
  initial global baseline. Close their admission, retire every issuance-capable
  operation/companion with exact DOWN and stop those exact supervisors through
  their actual parent without restart. Then invoke existing
  `KeyCustodian.unlocked?(exact_pid, fixture.session.session_id)` as a synchronous
  completion fence; accept either genuine boolean, never expose session/key
  state, add a new command or use a replacement process. Later pending requests
  fail existing dead-caller checks; current issuance finishes before the reply.
  Preserve the accepted terminal predicate, not an invented universal ACK.
- [ ] Finalize native operations and collector explicitly while custodian/control
  are live: that existing completion fence, real queued transitions,
  issuance/revoke ACK/all-lease DOWN, one existing5000ms deadline, full ownership
  preflight BEFORE mutation, exact original trace restoration and actual bound
  receipt plus collector DOWN. Missing receipt, foreign ownership, death and
  timeout fail closed. No infinite shutdown, raw native key-state inspection,
  fake messages, whole-session revocation or larger timeout.
- [ ] Preserve existing permission/repository/neighbor assertions. Remove only
  the identity-checked exact qualified child after successful proof; on failed
  proof retain the configured external child and retained failure. Do not claim
  fallback failed-proof retention under native root. Verify exact original
  complete present/absent runtime/storage application environments after native
  cleanup, deliver a required bound actual receipt to the surviving caller or
  registered private controller for independent verification,
  stop control with exact DOWN and clear private registry. Handle only recorded
  initial state when acquisition skipped begin; do not relabel full failure.
- [ ] B adds real configured/default-Api in-flight kill and queued-drain,
  bounded partial-initialization,
  foreign-pattern/tracer and missing-receipt/restoration controls without
  changing old assertions or the complete frozen ENOSPC case. Initial focused
  RED and final actual GREEN both remain evidence. Root freezes all source,
  records actual whole-live totals, replays whole privacy/master/other required
  owners and all static gates/posts, then ordered final SOURCE SPEC and NEW
  distinct QUALITY. Test-only scoped success does not accept Task17 or Phase5.

### A1 companion-result and queued-arrangement amendment after live5

- [ ] Preserve actual whole live4 FAIL32/10 and live5 FAIL32/3, raw/source/time/
  natural-exit/own-post records. Live5 default classifier3652 proves the new
  existential ACK assertion lacks its actual producer. Root reads Astra
  architecture advisory2; record it as architecture, not a repair PASS. Amend
  this canonical pair, then independent DESIGN SPEC, NEW distinct QUALITY and
  root GO before implementing the ACK/test-contract change. Refresh the exact
  canonical/source-stage pins through independently reviewed execution tooling;
  old C7 receipts remain immutable historical evidence.
- [ ] In new A only, register exact actual configured companion membership and
  actual returned lease association. After unchanged real native revoke returns,
  persist a bounded fixed outcome/identity/binding record in surviving control;
  retain no options, keys or content. Send a distinct asynchronous private
  observation notification. No new traced process/target, native hook, production
  change or fabricated trace/ACK/DOWN tuple. Both original match patterns and
  complete ownership/restoration guards stay unchanged.
- [ ] Fold the actual stored observation through ONE ordinary/final ACK
  transition, pending until real custodian issuance and deduplicated by record/
  lease. Wrapper registration never creates collector issuance. Reconcile actual
  control records during ordinary sync without assuming cross-sender FIFO.
  After exact producer/supervisor DOWN and the existing native completion fence,
  seal and drain the closed record set under the SAME monotonic5000ms bound.
  Missing, stale, foreign, unissued or unpersisted records cannot earn ACK.
- [ ] Add real ordering/dedup controls and SAME-validator negative record-copy
  controls, without injecting native success or letting a controller submit an
  outcome. Require correct source=:companion attribution, actual issued-set
  origin, final receipts, restored full patterns/tracer and exact collector DOWN.
- [ ] Explicitly replace ONLY the new unsupported default-warm existential ACK
  with stronger complete default loss proof: initial owned-global emptiness,
  positive actual per-operation issuance difference, genuine default export/
  materialization/close, fresh independently monitored exact live owner AND
  companion, both non-missing/non-noproc DOWN, EVERY new lease's actual native
  DOWN and fresh native read denial. Retain offline bytes and all resource/ACL/
  environment/trace checks. Do not claim a default ACK, borrow configured events
  or change an old assertion/canonical terminal predicate.
- [ ] Correct new configured/queued gates to a real positive Document read and
  carry/prove the exact issued live lease; Asset success may already stop its
  lease. Preserve every old/new byte/issued/alive assertion. Keep actual empty
  EOF records/messages but do not fire optional native-piece controls on them.
- [ ] Arrange ONLY the additive queued test on one small real plain Document
  using public upload/import and genuine extraction before the original deadline.
  No Note graph is needed for this lifecycle proof; all original rich/model/
  ENOSPC tests remain byte-identical under their existing preservation validator.
  Keep complete successful configured export/close and default export/page/
  positive bounded read/close while paused, exact held-lease ACK and DOWN plus
  actual queued default issuance, ALL THREE positive consumed counters, exact
  monitors, counter/missing-receipt mutants and ONE5000ms drain budget. A further
  timeout stays FAIL; no retry, budget increase or assertion deletion.
- [ ] Root alone freezes final11 paths and runs whole live/privacy/master,
  pure9/native2/architecture5, format, both compile/xref environments and ordinary
  posts. Require actual natural0, zero failures, closed commands, exact historical
  inverses/source43 and dependency graph. Then SOURCE SPEC and NEW distinct
  QUALITY before the scoped local commit. E2E/publication remain unauthorized.

## Task A1a: Scope existing test-only permissions on the owned live repo

- [ ] Keep NativeAssetFixture, KnowledgeTestGrants and Fixtures byte-identical.
  NativeAssetFixture.with_fixture/1 already starts the disposable MigrationRepo
  through ResourceOwner and records its PID (native_asset_fixture.ex:17-49).
  Do not nest KnowledgeTestGrants wrappers: they call Fixtures.with_owner/1,
  whose unconditional MigrationRepo.start_link collides (fixtures.ex:74-80;
  knowledge_test_grants.ex:89-149). Implement only private local fixture logic
  against that same live owned repo/database, not a new grant interface.
- [ ] Before changing permissions, assert the exact recorded MigrationRepo PID,
  live owner, destination database identity and the existing isolated test-name
  predicate (grant helper:151-157). Snapshot touched object ACLs and effective
  privilege states, unchanged role attributes/membership, and the existing
  outside-scope denied canonical-write guard. Register restoration before the
  first delta and run owner SQL only by the existing local owner transaction
  pattern. No global bootstrap, role creation/membership or catalog rewrite.
- [ ] Select only necessary existing allowlisted privileges, never all grants
  by default. Roles are exactly singularity_web and singularity_worker. Import
  uses SELECT/INSERT document_versions/document_import_receipts, EXECUTE
  content.document_trim_name(text), plus receipt UPDATE as in
  DocumentImportLiveTest.with_import_grants/2 (546-558). This matches
  KnowledgeTestGrants.with_grants/2 and with_receipt_grants/1 (17-36,48-56).
- [ ] For unchanged graph/source membership, select only needed SELECT/INSERT
  from the remaining existing table allowlist: document_fragments,
  note_attachments, note_citations, tags, resource_tags, relationships (helper:6).
  Preserve preexisting fragment SELECT; read-only fragment scope is at58-63.
  Existing DELETE scope is only resource_tags/relationships (65-74), only if an
  already-required valid mutation needs it. Exclude with_direct_mutation_grants/1:
  no direct Document/fragment UPDATE/DELETE or constraint/lifecycle bypass.
- [ ] Check the actual worker route's existing EXECUTE privileges first. The
  only optional lifecycle ceiling is the helper's five exact signatures (8-14):
  claim_document_extraction(uuid,bigint,uuid,text,integer),
  complete_document_extraction(uuid,uuid,bigint,jsonb,bytea,text),
  fail_document_extraction(uuid,uuid,bigint,text,text),
  reset_document_extraction(uuid,bigint,text,integer),
  recover_document_extraction(uuid,bigint), all in content. Grant only the subset
  actually needed by already-planned extraction; no new reset/recovery cases
  or automatic blanket lifecycle grants. Existing production grants stay intact.
- [ ] Grant only missing necessary permissions with no grant option. In after,
  on partial setup failure, callback failure and success, revoke only owned
  additions and assert exact original ACL/effective-privilege snapshots before
  NativeAssetFixture returns to ResourceOwner.close. Do not reuse blind REVOKE
  from with_permissions/2. Restore prior states, not a guessed all-denied state;
  never stop/restart the borrowed repo or widen authority to force restoration.
- [ ] Characterize the nesting limitation and permission scope with focused
  test-first witnesses: same PID/database throughout, required public import/
  extraction/source membership succeeds inside, existing denied-write guard
  and exact ACLs restored outside, and raised callback/partial setup cleanup
  also restores. Parent records actual RED/GREEN; setup failure alone is not
  the public-export behavioral RED. Preserve every old permission assertion.
  “No new grants” means no product/production/permanent grants: this existing
  temporary test-only contract is explicit, not hidden authority or native
  publication proof. Any extra object/privilege is reported before expansion.

## Task A2: Publish independent original inputs and build a valid rich graph

- [ ] Retain inputs before upload: File.read! of the existing valid
  `apps/singularity_ingest/test/fixtures/documents/two_pages.pdf`, literal
  plain text, Unicode Markdown and empty bytes. Retain their independent
  hashes/sizes. Do not use backup fixture's PDF-like synthetic bytes.
- [ ] Publish through actual `NativeAssetFixture.upload!/4`, finish and
  verify/finalize. After each deterministic batch assert known dispatch/job
  counts and zero failure rather than accepting an unspecified drain result.
- [ ] Call actual `Api.import_document/2` for PDF/plain/Markdown and dispatch
  actual OutboxDispatcher jobs. Drain actual `:document_extract` through
  JobDispatcher/Documents.Extract with real source lease and real configured
  extractors. Assert ready fragment/source provenance for valid inputs and
  genuine terminal no_extractable_text/unsupported handling where appropriate.
  Never force empty originals into invalid ready zero-fragment Documents.
- [ ] Use public create/save/merge/delete Note APIs for constructible graph
  portions. Add minimal legal committed SQL fixture rows only for exact
  historical/cycle/source-set shapes not expressible through public operations;
  base them on existing sealed source-set/backup graph patterns, with genuine
  published binding witnesses. No trigger/constraint/production-permission
  bypass or fake extraction completion. Record which rows use SQL and why.
- [ ] Record independent expected selected identity/file sets for duplicate
  titles, malicious labels/paths, Note source cycles, two historical pins,
  metadata relationship endpoints/pinned target, parent/merge descriptors,
  unselected conflict/history canaries and tombstones. Keep native publication
  positives separate from these graph arrangement witnesses.
- [ ] Delete a genuinely published source Asset through the actual public API
  and cleanup workflow while its live Document retains original access. Include
  a separately positively resolved deleted source in a live Note. Assert legal
  retention/deleted-source metadata witnesses before export, not only absence.

## Task B1: Add independent offline materialization and oracle REDs

- [ ] Test A's public materialization in fixture support: Api pagination from
  nil cursor until terminal cursor, <=500 rows/page, duplicate/cycle rejection,
  only safe relative paths; exclusive0600 files below new0700 offline root;
  exact Api chunk ordinals and <=65,536 bytes; always close real handle.
  Register cleanup for an unexpected successful handle on every intended RED.
- [ ] Create `knowledge_export_offline_oracle.ex`. Its only inputs are offline
  root and explicit expected input/graph data. No SQL/runtime/storage lookup,
  Core export validator/renderer or proprietary URI resolution is permitted.
- [ ] Parse manifest with test-only Jason; production's configured codec is
  built-in JSON/:elixir_json. Independently define the literal12 top-level keys
  (format/version/selection plus resources/versions/fragments/tags/
  tag_assignments/relationships/attachments/citations/files) and all exact
  per-array field sets from the format document, never a production validator.
  Independently check exact schema/key sets,
  file inventory plus separately hashed manifest descriptor, SHA256/byte sizes,
  identities/references/nullability, no extras and metadata-only availability.
  Compare original PDF/plain/Markdown/empty file bytes directly with inputs.
- [ ] Check rendered Markdown against literal expected graph snippets and
  footnotes, then resolve every generated relative source link/footnote offline.
  Check path escapes/proprietary source URIs without rejecting legitimate
  user-authored external URLs. Assert version-addressed UUID names independent
  of titles. Verify exact multibyte UTF-8 offsets and no-delimiter fragment
  concatenation from explicit expected fragment bytes.
- [ ] First prove oracle causality with one valid local fixture and individual
  mutations: missing/extra file, altered bytes/hash/size, wrong reference,
  unsafe relative link, missing footnote and character-vs-byte offset. Each
  negative starts with a passing positive control and fails its own boundary.
  No old/canonical baseline is modified. Then add the actual Api live acceptance
  test; record its initial actual result without inventing a product failure.
- [ ] Assert deleted/ancestor-only/history/conflict bodies/originals are absent
  from the exact inventory and `metadata_only_unavailable` is never emitted.
  Verify two historical pins remain distinct descriptors/files even when
  originals deduplicate internally. Run both tombstone options.

## Task B2: Add real post-COMMIT race and lifecycle acceptance

- [ ] Add scoped adapter wrappers delegating actual ScopedRepo.transact and
  real Repository methods. Mark capture only by the real result; barrier only
  after transact returned and `in_transaction?() == false`. Preserve actual
  callback results and exceptions. Compute bounded schema/count/backing summaries
  in the owning process/delegating transaction wrapper and send scalar summaries
  only; never retain/ship the full capture or copy corpus bodies for measurement.
- [ ] Reuse native observer patterns additively: actual KeyCustodian lease
  returns, DownloadLease reads/empty authentication/revoke, exact PIDs/monitors,
  Writer-owned ETS and operation/token handshakes. Do not change authorization
  dependencies to observer custody or synthesize successful native responses.
- [ ] After capture COMMIT, change heads/tags through valid operations; assert
  offline output equals captured expectations, not later heads/tags.
- [ ] Delete/revoke a selected live source before transfer and separately
  before completion authorization/COMMIT; require sanitized whole failure,
  no handle/partial artifact and complete operation cleanup. A live missing
  source must fail, not become metadata-only success.
- [ ] During generation deliver one real bounded original consumer piece, then
  revoke authority before the next native read; assert real denial and all
  issued leases terminal. Keep this native-generation path distinct from
  completed-handle delivery.
- [ ] Complete a genuine export, positively read the first chunk through
  `Api.read_knowledge_export_chunk` and the configured facade, revoke real
  authority, then request the next ordinal through the same public path.
  Require denial without bytes, actual owner/companion DOWN, Writer ETS gone,
  owned directory absent and storage/backup/neighbor sentinels unchanged.
  Synthetic Artifact authority or native generation denial is not this witness.
- [ ] Include wrong-session/principal/owner/epoch public operations and
  fixed-clock expiry during generation and delivery without sleep-based races.
- [ ] Observe the actual generation failure/expiry cancellation path and its
  real requester-to-companion cancel/terminal cleanup, separately from requester
  death and normal completed-handle close. Do not invent a public cancellation
  API or send a forged internal cancel message to simulate production behavior.
- [ ] Kill the real monitored requester during generation and separately kill
  the actual owner after native/Writer acquisition. Assert no precompletion
  handle; exact requester/owner/companion DOWN; all issued native leases real
  inactive/read-denied plus DOWN; Writer ETS gone; owned dir gone; neighbors
  and object-storage/backup bytes/inventories unchanged.
- [ ] At the actual companion pre-owner clock barrier, kill the genuine
  companion; record recognized residue and sanitized requester failure. Stop
  all fixture operation tasks/supervisors before separate guarded startup.
  Assert recognized orphan removed and malformed/foreign neighbors preserved.
  Preserve Task16's documented pre-owner recovery limit, not an invented
  universal immediate-cleanup guarantee.

## Task B3 / A3: Causal Api ENOSPC RED, then the one-entry production amendment

- [ ] B adds a genuine Api test with `runtime.knowledge_export_write` arity2.
  The callback delegates ordinary IO.binwrite until observed real native chunk
  delivery arms the next Writer write; then returns `{:error, :enospc}`.
  Track actual callback invocation, pre-fault successful writes/native delivery
  and exact operation ownership. Do not use failure during fixture publication.
- [ ] Require callback witness and `{:error, :storage_unavailable}` from Api.
  On today's source the key is ignored and export succeeds: parent records
  that precise behavioral RED and closes the unexpected real handle in after.
  Never accept a setup/compile error or lower-level synthetic failure as RED.
- [ ] A adds only the following entry to Export.materialize's Writer.open map:

```elixir
write: Map.get(runtime, :knowledge_export_write, &IO.binwrite/2),
```

- [ ] Parent records exact forward/inverse against accepted Task16 Export
  bytes (preparatory source hash
  `dab8881c7685bc967bb214736f167b6f37808040eb8adeaf48a2da9567ca8009`). No
  other Export/Artifact/Api config or public options code changes. The separate
  Task B4a below owns only the reviewed two private digest helper bodies. Add an
  additive architecture assertion that the internal key exists only at this
  trusted forwarding boundary and defaults to IO.binwrite; production config
  never supplies it. Public options remain exactly include_tombstones.
- [ ] Re-run the same case unchanged to GREEN. Assert actual public sanitized
  error/no handle, all issued native leases real inactive/read-denied plus
  DOWN, monitored requester/owner/companion DOWN, Writer ETS dead, owned dir
  absent, no partial artifact and storage/backup/neighbors unchanged.
- [ ] Label evidence injected ENOSPC through genuine Api/real Writer, not
  physical disk exhaustion. Preserve lower-level Spool/Writer error tests as
  separate coverage. Never fill shared storage or change mounts/quotas/rlimits.

## Task B4: Boundedness and byte determinism

### Task B4a: Strict generated-digest RED and bounded producer detachment

- [ ] Preserve actual pre-write whole-run failures and source pins. The
  `live-prewrite5` raw SHA is
  `ac5bd9f3cf6d16752285245208c1a7f44403f453bc1a720c68f5998686e025db`:
  20 tests/7 failures, natural2, own post EMPTY0, all commands closed. Strict
  generated digest size64/lowercase checks pass but backing70 exceeds64.
  Preserve the independent genuine Api ENOSPC RED receipt (14 native pieces,
  zero callback calls, unexpected successful handle closedafter); these are
  distinct causes and neither waives other failures.
- [ ] Parent reads the full216-line Astra advisory SHA
  `c487aa260206c45c93421ace2d31a9831c97e6621208cd479be52a56ac60bd17`,
  amends both canonical documents and obtains new ordered DESIGN SPEC, NEW
  distinct QUALITY and root GO before source repair. Generated Base.encode16
  slack is not the JSON-decoded-small-leaf premise;70 is not a new bound.
- [ ] D changes exactly one existing helper per file to
  `defp hex(bytes), do: bytes |> Base.encode16(case: :lower) |> :binary.copy()`.
  Exact Spool preimage is
  `2d6dfb4e10b78a4ac27e0e868a6f33326e746c96a309a4d5a833511f63f18556`;
  exact Writer preimage is
  `841f3e6b7333e7e94296c8b961353c732cbfddef1cebc8cce15041720e5e80e1`.
  Record exact contextual forward/inverse to each full old hash. Reject
  duplicate/missing helpers and unrelated bytes; add no generic encoder or
  test-side copy. Fixed32-byte SHA/HMAC inputs produce the same64-byte result;
  transient cursor/comparison copies are separately bounded, not heap proof.
- [ ] Preserve all historical source43 bytes and assertions. Repository remains
  SHA `618983d395ff382939ce47ba0cdfa36881e4a71b3a58cfc7c1e87322baf2981c`:
  Q/T selectors use the database fragment id, not encoded digest metadata. No
  Repository/Core/schema/custody change or manifest normalization is allowed.
- [ ] Parent adds only the new digest architecture owner, testing both exact
  helper inverses and causal rejection controls with the same positive
  validator. Keep old composition assertions byte-identical outside one
  attributed additive forwarding block; add the fifth whole architecture file
  to the registered gate and preserve all other owners/argv.
- [ ] Inspect actual compiled sealed text/render/binary refs, Writer record
  refs, all output SHAs and empty/nonempty chunk SHAs for size64/lowercase/
  backing<=64 plus known-byte equality. Extend only new live tests if actual
  coverage lacks a family. Preserve Q/T selectors, same small/501 model,
  long-locator/MIME/real ETS checks, deterministic exports and offline bytes.
  Do not change bounds, coefficients, quotas, asserts, GC or failure semantics.
- [ ] Root prepares and independently reviews a post-write finite source/
  lifecycle stage, pinning amended canonical reviews, exact three production
  inverses, additive-only old architecture block and all other committed raw
  blobs. Retain runtime/role facts, separate own posts and source-independent
  stop/archive; preserve old operational scripts. Freeze all owners before
  any VM/formatter. Record actual RED/GREEN and final ordered source reviews.

### Remaining boundedness and determinism acceptance

- [ ] Preserve actual `postwrite-live3`21/8FAIL/13PASS, natural2 and raw SHA-256
  `82b1780b535c2c185dc65f6cbff3146730f44871615637fd988aececea036260`.
  Record the second501 export timeout and subsequent seven trace-state failures
  separately. No501 deterministic-pair PASS or production deadlock is proved.
- [ ] After canonical amendment, independent DESIGN SPEC, NEW distinct QUALITY
  and root GO, replace the combined count loop with two generated cases for
  `[1,501]`, retaining `@moduletag timeout: 180_000`, integration and async:false.
  Explicitly acknowledge one shared180000ms becomes two independent180000ms
  harness budgets; this changes aggregate allocation, not per-case/product
  deadlines. It is the sole reviewed scenario-isolation clarification, not
  authority for larger timeouts. Standalone501 remains unmeasured until run.
- [ ] Preserve one shared complete lexical inner body and fresh fixture inside
  each case, all501 public creations, maximum Note/native original, both exports
  and materializations and every formula/mutant/schema/backing/native/page/
  chunk/write/byte-comparison/cleanup assertion. Add only the design's finite
  scalar monotonic markers, including successful fixture-return separately from
  callback return. No retry, exclusion, detached setup, concurrency, precomputed
  result, sleeps, forced GC, alternate path or timeout override.
- [ ] Pin B's original whole SHA-256
  `0bab7421fc79f9461194e644de2d3557f4fe3f15d6c24d7adfa8daa805796c8e`
  and block/body bytes. Run the strict SAME source-preservation validator:
  exact generator/name/binding/shared body/timeout, remove only exact finite
  diagnostic additions, require body byte equality and whole-file inverse
  before separately additive lifecycle regressions. Require rejection of
  dropped-assertion, reduced501, absent-second-export/materialization, changed-
  timeout and content-inspecting-marker source-copy mutants. Preserve the
  complete frozen ENOSPC case. Source preservation is not runtime acceptance.
- [ ] Freeze all owners and use freshly independently reviewed execution
  tooling. Replay the complete whole-live owner: split alone changes21 to22;
  record actual totals after new lifecycle regressions. Both cases must pass
  under180000ms each, otherwise retain FAIL and diagnose/repair without reduced
  work or larger timeout. All master/other whole-owner/static gates, own posts
  and final ordered independent SOURCE reviews remain required.
- [ ] Create >500 actual public entries from valid small Notes/source files,
  one valid maximum1MiB canonical Note and a genuinely uploaded multi-chunk
  original (fourMiB plus a tail suffices). Keep inputs within unchanged fixed
  per-item and total limits; no quota overrides or million-record claims.
- [ ] Observe all facade pages <=500 and facade/consumer/Writer chunks
  <=65,536. Native Asset ranges remain <=65,536; native Document records retain
  the existing aligned4,194,304-byte ceiling, exact final-tail validation and
  <=65,536-byte split consumer pieces. Do not alter native code to impose the
  consumer ceiling on aligned Document reads. Observe sealed scalar counters
  spool_bytes/metadata_records/selected_keys/original_bytes and verify exact
  fixture/journal accounting identities plus unchanged Core total ceilings.
- [ ] Preserve exact physical payload/index stat equalities. Check spool_bytes
  equals those sizes PLUS independently known Repository temporary plaintext
  charges, not an observed difference: current small/501 fixtures predict
  1,048,588/1,056,482 bytes from known Note bodies plus the 12-byte companion;
  pending Document and no-citation Notes add no fragment/resolver charge.
  Accumulate only input byte counts. Direct compiled Spool fixtures use zero.
  The SAME model validator must reject plus-one/minus-one predicted-charge
  mutants at the exact accounting boundary; keep all other model formulas,
  physical checks and fixed limits. Do not change Repository or production
  accounting/budgets to satisfy the mistaken physical-only test identity.
- [ ] Implement the design's deterministic sealed-family model in private test
  support, preserving the six public fixture functions. Enumerate actual sealed
  S/C/V/A/B/T/D/Q/J counts, exact schemas/selectors, frames and installed MapSet
  shape. Require `S+C+V+A+B+3*T+D+Q+4*J <= R <= 1_000_000`,
  `S == selected_keys <= 100_000`, actual accounting/journal identities and no
  retained body/title/locator values or unsealed _texts hash/carry fields in
  content indexes; retained frame hashes/digests remain required. Reject extra fields,
  altered selector/ref shapes, count inconsistencies and unknown families.
- [ ] Derive numeric cS..cJ using the exact bounded skeleton recipes in the
  design, `e(x)=:erlang.external_size(x)-1`, signed64 integer extrema and fixed
  UUID/hash/enum bounds; include container/MapSet/list/header overhead and
  repeated keys/refs. Record numeric coefficients and skeleton pins in evidence.
  Sum real family counts against `Bsealed+sum(N*c)`; do not encode the corpus,
  choose a flat_size constant or discard a shape to make it pass. Run small and
  large compiled-runtime real append/seal fixtures with the SAME formula.
- [ ] Model Writer build families separately: C captured keys, <=C record refs,
  <=V count/progress headers, <=C fragment identities/source-group headers/
  members, <=(T+V) seen selectors and O outputs/K chunk hashes. Include exact
  key/ref/list/progress skeletons; separately bound opaque hash context. Verify
  publish actually drops the listed build-only fields. Require independent
  Writer charged `O+K <= RW <= 1_000_000`, not an equality to sealed R.
- [ ] On real compiled-runtime Writer import/publish fixtures, inspect actual
  published output indexes and live owner ETS rows. Use
  `Lpublished<=Bpublished+O*cO+K*cK` and exact output/chunk skeletons;
  `Lledger<=Bledger+(O+2)*cFile+5*cDirectory+cAccounting+cLocation+cBinding`.
  Observe .records/.index plus every output file row, <=5 directory rows and
  all administrative rows; transient reservation is separately counted during
  finish. Reject unknown row/field shapes. An ETS identifier is not its rows.
  These real boundary fixtures supply boundedness evidence, not fake Api/native
  acceptance or a reason to add production observers/private state inspection.
- [ ] Add long-locator real Spool append/seal backing regression and a valid
  long-MIME real Writer publish/ledger regression. Traverse retained binary
  leaves with `:binary.referenced_byte_size/1`; require small sealed UUID/hash/
  enum leaves not to pin the large locator frame. Production JSON/:elixir_json
  and exactOTP28.5.0.3 <=64-byte copying remain source inference until this
  actual compiled-runtime check. Assert every output path/MIME and ledger path
  backing <=31_807, derived from19 version fields, max23-byte key, conservative
  255-byte scalar and sixfold JSON expansion:
  `19*((2+6*23)+1+(2+6*255))+18+2`. That individual versions pread contains
  no title/body/locator/storage-ref; never label it whole-journal retention.
  Conservatively add `3*O*31_807` to the retained backing budget if parents
  alias; keep fixed root/clock/identity backing separate. No copy repair is
  authorized solely by this source-inferred bounded parent possibility; B4a's
  independent actual generated-digest RED authorizes only its two helper bodies.
- [ ] Prove model rejection causally using positive fixtures then local copies
  with extra content field, malformed selector/ref, oversized binary or count
  contradiction. Do not mutate live descriptors production will consume. If
  actual shapes/backing escape the derivation, report the precise design gap;
  do not raise constants, weaken the criterion or expand production scope.
- [ ] Record the separate one-Note working set: canonical<=1MiB, rendered<=16MiB,
  <=100 attachments AND <=100 citations, <=100 distinct combined targets,
  aggregate source.title<=16MiB, labels<=255 and Markdown locators<=64 headings
  each<=255, with structural/href/reference/JSON escape costs. Do not assume
  255-byte source titles without their exact origin proof. Bound single-record
  decode, native Document<=4MiB/consumer<=64KiB buffers, transient identity-sort
  lists and build closures separately from retained indexes. Static review
  checks internal pages and no nonempty eager :all/full-export list/JSON buffer;
  public page observations are not an internal trace. Serialized external_size
  plus referenced backing are not exact heap/ETS/RSS/GC/whole-VM peak claims.
  No forced GC, time/RSS thresholds, million-record stress or quota overrides.
- [ ] Export identical captured data twice with different handle/operation/time
  IDs and disjoint offline roots; compare exact inventories, manifest bytes
  and every file byte. Record that graph/tag/head state did not change between
  captures. Handles need not and must not compare equal.

## Task C1: Privacy and real permission acceptance

- [ ] Create privacy integration owner using A's fixture unchanged. Add unique
  canaries for text/title/labels/storage refs/principal/session/key/job fields.
  Capture only actual export success/failure/chunk/close/lifecycle operations.
- [ ] Attach unique unfiltered handlers around each actual Api call for all
  five repo query events and existing authorization/job events. Require zero
  query events under unchanged SafeSQL suppression; check exact registered
  event-set, external callback and owner/token before and after the call.
  Detach before fixture SQL/oracle/content work; preserve parent-known requester
  cleanup and try/after restoration. Scan every raw event/log/error, unfiltered.
- [ ] Require fresh private Observer token/phase/caller-bound real operation
  proof: export capture/native/final COMMIT and handle; positive public page/
  chunk bounds and result; close authenticated COMMIT and exact owner DOWN.
  Fault/expiry preserve native-triggered Writer injection/clock evidence and all
  terminal checks. Stale/invalid pre-capture rejection needs exact result and
  privacy scan, not synthetic success events. Chain existing controls once;
  unrelated/earlier events cannot count. No A or production hook change.
- [ ] After temporary grants unwind, prove exact owned privilege/repository/
  database baseline and denied worker receipt SELECT. A separate labelled real
  SafeSQL WorkerRepo receipt query with a private canary must yield PostgreSQL
  42501, exactly one count=1/repo=worker RLS event from its exact emitter/token,
  zero query events and full raw canary scan; detach and recheck the baseline.
  Never attribute that event to export. No grants or SQL telemetry changes.
- [ ] Exercise the SAME strict registration/delivery/operation predicates with
  real positive observations, an actually detached sacrificial handler and
  missing/duplicate/wrong-event/callback/configuration/token/phase/caller and
  zero-count/byte mutants. All must fail causally without fabricated telemetry,
  filtering or unrelated global events satisfying a witness.
- [ ] Assert captured logs/events, sanitized errors and opaque Handle Inspect
  contain no canaries/private fields. Do not assert intentional caller DTO
  identities are globally secret or change DTO/Vault Inspect behavior.
- [ ] Check real artifact directories0700/files0600 while live and completed,
  and offline equivalents. Assert neighbor/storage/backup byte and inventory
  preservation for success/fault/cancellation/recovery. No arbitrary broad
  cleanup or test-owned path symlink is allowed.

## Master-owner and existing exact-link contract repair — 2026-10-20

- [ ] Preserve actual master1 FAIL49/14/natural2/rawSHA
  `008f6840c945696f23ad0cb29ecb913258801ab94961e4e3d5039ce11cf8d5c9`
  and its EMPTY/natural0 own post. Read the exact missing-sibling adapter cause
  and Phase4 historical confirmation; do not reinterpret setup failure as an
  export behavioral RED. The amendment changes only the master invocation to
  add the FULL unchanged authorization owner, retaining all three original
  full owners, environment, seed and warnings-as-errors. No old source, fixture,
  grant, native/Vault or migration change is required.
- [ ] Obtain complete amended-pair independent DESIGN SPEC then NEW distinct
  QUALITY and root GO before applying the bounded new-B/oracle repair below.
- [ ] Add one wrong-existing-file href corruption to the existing positive-first
  offline-oracle test without changing any prior mutation/assertion/fixture.
  Redirect a ready Document extracted link to its existing original, preserving
  reference/pin text and using existing integrity-descriptor refresh. Through
  freshly independently reviewed exact-pin tooling, require actual RED at the
  missing rejection, not setup/compile failure or an unrelated assertion.
- [ ] Repair only new offline oracle's generated suffix checks to bind each
  reference's ID/resource/version/kind to its exact format-defined relative
  href and each citation definition to its own citation/resource/version/fragment
  tuple. Preserve independent locator checks, canonical user external links,
  metadata-only no-link behavior and every existing corruption boundary.
  Production renderer/validator/resolver/live SQL remain forbidden in the oracle.
- [ ] Refresh exact moved diagnostic declaration lines and freeze all11 paths.
  Finite diagnostic argv may run the FULL unchanged Markdown and authorization
  owners together, or the exact existing offline-oracle test declaration; neither
  replaces final whole gates. Preserve unchanged C8 and every prior receipt.
- [ ] Observe oracle GREEN and whole-paired Note results, then rerun all11 final
  whole-owner/static gates under the amended authority, ordinary posts and final
  ordered SOURCE SPEC/NEW distinct QUALITY. Preserve1/501/180000ms, ENOSPC, native
  source43/four inverses, all old assertions and all prior FAIL evidence. E2E
  stays NOT RUN; no Task17/Phase5 acceptance follows merely from this amendment.

## Task P1: Whole-owner regression and ordinary gates

Parent executes from W through a freshly reviewed Task17 wrapper on the accepted
retained-RAM qualification lane. Task17's separate owned PG identity is active;
no VM command is live while these amended sources are edited. The command blocks
below preserve required inner whole-owner argv (and the master's shell/env form),
not reusable active lifecycle invocations. Record the NEW wrapper's exact outer
argv/hash, actual unchanged inner argv/environment, fresh active identity, guard
and immutable Task17 candidate pins before every invocation. Existing
`.devenv/phase5-pg-command.sh` and native250 controller/expected PID/source43-only
guard are historical argv/evidence only; never run them casually against today's
changed-source lane. Root owns all VM/formatter/PG/SQL/process/
lifecycle/Git execution, fresh ordinary posts and exact owned stop/archive.
Preserve raw RED/GREEN receipts, source hashes, exact
actual wrapper/command, seed, executed/excluded counts, warnings, exit status and
ordinary ownership-post results after each exclusive VM command. Expected GREEN
is zero failures and natural0; never fabricate test counts. Explicitly confirm
native integration cases execute rather than being excluded by normal mix test.

- [ ] Run the master Task17 whole-four-file command exactly, with an approved
  wrapper only if its exact actual invocation is recorded:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_export_live_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_privacy_test.exs apps/singularity_runtime/test/singularity/runtime/note_markdown_export_integration_test.exs apps/singularity_runtime/test/singularity/runtime/note_authorization_integration_test.exs --seed 215378 --warnings-as-errors
```

- [ ] Run unchanged whole pure export owners plus Api/Application regression:

```sh
mix test apps/singularity_runtime/test/singularity/runtime/api_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_api_test.exs apps/singularity_runtime/test/singularity/runtime/application_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_artifact_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_read_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_snapshot_test.exs apps/singularity_storage/test/singularity/storage/knowledge_export/spool_test.exs apps/singularity_storage/test/singularity/storage/knowledge_export/writer_test.exs apps/singularity_storage/test/singularity/storage/knowledge_export/artifact_directory_test.exs --seed 215378 --warnings-as-errors
```

- [ ] Replay actual whole native/snapshot owners, not the normal excluded route:

```sh
mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_export_snapshot_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_custody_live_test.exs --seed 215378 --warnings-as-errors
```

- [ ] Run the four governing architecture files unchanged except the approved
  additive seam assertion, plus the new digest architecture owner; preserve
  Task16 attribution compatibility checks:

```sh
mix test apps/singularity_web/test/singularity/architecture/knowledge_export_composition_contract_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs apps/singularity_web/test/singularity/architecture/export_lease_ownership_contract_test.exs apps/singularity_web/test/singularity/architecture/knowledge_export_digest_backing_contract_test.exs --seed 215378 --warnings-as-errors
```

- [ ] Run actual formatter only on authorized changed files, then static gates:

```sh
devenv shell -- mix format --check-formatted
devenv shell -- mix compile --warnings-as-errors
devenv shell -- mix xref graph --format cycles --fail-above 0
git diff --check
```

- [ ] Parent verifies dependency graph remains seven-app/acyclic, no public/env
  injection selector, no new product/production/permanent grants or migrations
  or Vault changes, exact temporary fixture ACL restoration, no eager
  nonempty :all/full-export buffering, exact old-assertion inverses and fixed
  source attribution. If new explicit contract amendment is necessary, review
  it independently before source repair; never silently rewrite old hashes.
- [ ] After every runtime gate run the established ordinary ownership-post
  check and require actual EMPTY/natural0, all command sessions closed, no owned
  runtime/DB/resource leftovers. Do not substitute a fabricated receipt or
  kill others' processes. Full README phase/release gates remain required at
  their governing acceptance point; Task17-scoped GREEN alone is not Phase5
  acceptance. E2E remains explicitly NOT RUN/manual-only.
- [ ] Parent obtains independent complete source/spec review, then a distinct
  fresh quality review of final source and actual evidence. Resolve every
  required finding within scope and rerun affected whole owners. Record any
  unrun/unqualified gate as such, not PASS.
- [ ] Only after all Task17 criteria/gates/reviews pass, parent makes the
  authorized local commit `test(export): prove portable bytes source closure and denial cleanup`
  and records exact files/source/commands/results/limits/no Vault feature work.
  Task17 workers STOP and hand off at this task boundary; they do not implement
  Task18/19. Parent continuing authority to prepare and advance subsequent tasks
  after their actual prerequisites and design/review gates remains intact.
  No push, tag, release, deployment, activation or E2E is authorized here.

## Bounded open implementation facts

Task16 source/documentation/actual acceptance and the retained-RAM lane are
pinned above. Task17's actual pre-write identity/wrapper/guards and failed runs
are retained; a newly reviewed post-write source/lifecycle stage remains required
before changed production sources execute. Before acceptance, record exact actual
extractor job/fragment results, legal minimal SQL-only immutable graph
arrangements, exact minimal temporary permissions and before/after raw ACL/
effective-privilege restoration on the same owned live repo, numeric schema-model
coefficients and real small/large/locator/MIME/ETS backing results. None authorizes
relaxing provenance, fixed limits,
custody, assertions or failure semantics. A genuine uncovered architectural boundary is reported
to parent with source evidence; ordinary test arrangement facts are resolved
through scoped RED/GREEN, not a renewed user-approval demand.
