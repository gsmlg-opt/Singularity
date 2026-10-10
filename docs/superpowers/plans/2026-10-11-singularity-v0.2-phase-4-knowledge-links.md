# Singularity v0.2 Phase 4 Knowledge Links Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to execute each task with independent SPEC then QUALITY review. The continuous authorization supersedes routine approval waits, not verification.

**Goal:** Immutable Note-version attachments/citations with exact provenance,
historical retention, authenticated tags/relationships/backlinks, and readable
ordinary Markdown citation export.

**Architecture:** Pure references and intent in Core/Domains; bounded source
preparation, shared lock protocol, per-version seal, and existing Note receipt
transaction in Storage; existing-capability composition and owner-free DTOs in
Runtime. Organization operations remain independent of Note Save.

**Tech Stack:** Existing seven-app Elixir umbrella, PostgreSQL 17,
Ecto/Postgrex, scoped safe SQL, ExUnit, existing receipts and HMAC keysets.

---

## Authority, base and execution discipline

Follow the [Phase 4 design](../specs/2026-10-11-singularity-v0.2-phase-4-knowledge-links-design.md)
and [release Phase 4](2026-08-31-singularity-v0.2-release.md#phase-4--attachments-citations-tags-relationships-and-backlinks).
Design/plan are not implementation acceptance. The local base is Phase 3 tested
source `35c1f8360dd22b129832a1618b3723032a1983bd` plus documentation handoff
`617f0b986a3ecffba14c952988e39e3afe022cea`, not root `main`.
Use `.trees/v0.2-phase-4-knowledge-links`, branch
`codex/v0.2-phase-4-knowledge-links`, preserving all earlier worktrees and
the protected untracked Phase 2 integration plan.

The user's continuous authorization permits recommended in-scope design,
implementation, necessary compatibility repairs, additive forward migrations,
docs, tests, independent review and local commits. No Vault feature/semantics,
custody/key/capability change, merge, push, version bump, tag, release,
deployment, production activation/backfill, V3 backup or browser feature.
The explicit E2E deferral permits local advancement only after every other
required gate and independent review passes. E2E remains manual-only NOT RUN;
final browser/release acceptance is still required.

Parent serializes all Mix, database, formatter, service and Git mutations.
Assign workers disjoint file ownership, tell them they are not alone, and
preserve others' changes. Parallel read-only investigations or independent
artifact work are allowed; dependent implementation tasks stay ordered.
Start each behavior with an observed focused RED, then GREEN, self-review,
independent SPEC, independent QUALITY and a small scoped local commit.
Repair failures without weaker assertions/timeouts or skipped checks. Sol is
default; Astra is restricted to actual architecture or two failed Sol repair
rounds/evidenced impasse. Its completed source-seal architecture advice used
zero repair attempts. Preserve cumulative counts and permit at least three
bounded Astra repair attempts where needed.

Run commands from this worktree with its own `_build`; reuse only locked
dependency sources. Do not update dependencies or the devenv lock for a notice.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_core/test/singularity/core/note_values_test.exs apps/singularity_core/test/singularity/core/knowledge_link_values_test.exs apps/singularity_domains/test/singularity/domains/notes_test.exs apps/singularity_runtime/test/singularity/runtime/note_mutation_fingerprint_test.exs --seed 215378
```

For integration use the existing owned-cluster harness, copied/adapted only
inside ignored `.devenv` task tooling if required. Resolve and record exact
worktree PGDATA/socket/port; never borrow or stop another worktree's cluster.
Bootstrap the exact owned database with the existing external administrator
hook and keep EXIT cleanup for owned processes/generated databases/roots.
Do not put environment-specific scripts or secrets in the commit.
No E2E command is part of this plan.

## Task 0: Qualified handoff and reviewed design

**Files:** `AGENTS.md`, `README.md`, `docs/guide.md`, master release design/plan,
Phase 3 design/plan/report, existing Web architecture contracts, this design/plan,
and `docs/verification/2026-10-11-phase-4-acceptance.md`.

- [x] Synchronize exact E2E-deferral governance without changing final acceptance,
  and record baseline/RED/GREEN plus SPEC and QUALITY review in Phase 3 report.
- [x] Independently review the complete Phase 4 design/plan against inspected
  code and the master deliverables. Amend ambiguities before implementation.
- [x] Update only active-phase guidance/contract expectations to Phase 4, with
  exact tested Phase 3 source and handoff, resolving all local Markdown links.
  Preserve activation prerequisites, frozen runtime byte hashes and negative
  governance assertions.
- [ ] Run the two full existing governance suites, format/compile/xref and diff
  checks. Create the Phase 4 report with explicit incomplete status; commit
  `docs: start phase four under deferred e2e acceptance` after review.

## Task 1: Pure references, snapshot modes and receipt fingerprints

**Create:**

- `apps/singularity_core/lib/singularity/core/note_attachment_reference.ex`
- `apps/singularity_core/lib/singularity/core/note_citation_reference.ex`
- `apps/singularity_core/test/singularity/core/note_source_references_test.exs`

**Modify:** Core `note_snapshot.ex` and owning `note_values_test.exs`;
Domains `notes/command.ex`, `notes.ex`, `notes_test.exs`; Runtime
`notes/mutation_fingerprint.ex`, `note_mutation_fingerprint_test.exs`.

- [x] Characterize the four existing owning files with the baseline command.
- [ ] Write new tests before production changes. Require real constructors,
  ordered typed fields, omitted initial empty/normal inherited/merge inherited
  modes, independent explicit clear, canonical Unicode/string alias behavior,
  invalid fields/UUIDs/kinds/roles/locators/forged structs/duplicates/bounds.
  No caller scope, containing Note/version or ordinal fields are accepted.
- [ ] Parent executes the tests and records expected missing-module/default
  RED. Then implement the two strict owner-free reference values, using fixed
  kind/role clauses and existing validators/SourceLocator; no new dependency.
- [ ] Extend snapshots with at most 100 references per collection, unique member
  IDs and attachment target/version/role tuples, at most 100 union targets and
  fragments. Preserve list order. Create omission is `[]`; normal/merge omission
  is internal `:inherit`; explicit sentinel input is invalid.
- [ ] Add optional source fields only to create/save/merge Command keys;
  keep all existing required keys/strict aliases and lifecycle shapes. When
  rebuilding a command, omit internal `:inherit` fields to preserve omission
  rather than accepting explicit client sentinels. Domains and Runtime HMAC
  reconstruction must propagate lists and preserve canonical equality.
- [ ] Preserve exact v1 literal tuples for default modes and explicit empty
  Create; keep lifecycle tuples unchanged. Use `:note_mutation_v2` for other
  cases, extending the corresponding legacy operation fields with canonical
  attachments/citations mode terms. Each reference term covers every semantic
  field; locator uses existing canonical `SourceLocator.encode/1`. Fingerprint
  list order and inherit/replace distinction, never generated IDs/witnesses.
  The exact v2 shape replaces element zero of the corresponding v1 tuple with
  `:note_mutation_v2`, then appends the two mode terms: `:inherit` or
  `{:replace, ordered_member_tuples}`. Attachment members are
  `{attachment_id, target_resource_id, target_resource_version_id, target_kind,
  role, label}`; citation members are `{citation_id, source_resource_id,
  source_resource_version_id, fragment_id, encoded_locator}`.
- [ ] Add Domains fake-port intent assertions using its existing fake, not a
  database simulation; prove forged snapshot/command still fails before port.
  Add Runtime HMAC tests with a literal independently constructed v1 oracle,
  every-field/order/mode v2 perturbations, normalization equivalence, malformed
  nested structs and sanitized errors. Do not change Runtime input/grants yet.
- [ ] Run new and all four existing owning files, format/compile/xref, inspect
  diff, SPEC then QUALITY review. Commit `feat(notes): model versioned source intent`.

## Task 2: SQL source-set sealing and historical retention guards

**Create:** Storage migration
`priv/repo/migrations/20261011000000_seal_note_source_sets.exs`;
`test/singularity/storage/note_source_set_sealing_test.exs`.
**Modify:** Storage `postgres/knowledge_link_repository.ex`, support
`knowledge_fixtures.ex`, `knowledge_schema_test.exs`, `knowledge_rls_test.exs`,
and owning `postgres/knowledge_link_repository_test.exs` as required.

- [ ] Add integration RED proving a committed empty/nonempty version can still
  be appended; preserve every original FK/ordinal/locator/identity negative.
- [ ] Add the immutable owner-scoped seal table and composite typed-Note FK;
  forced RLS, exact grants and bounded counts. Runtime gets no direct seal
  INSERT/UPDATE/DELETE/TRUNCATE; no role attributes/membership changes.
- [ ] Under write-excluding table locks, validate/backfill old structural sets
  including empty versions, without child rewriting or historical live checks.
  Add migration vectors for old nonempty membership and malformed old sets.
- [ ] Add visible-seal child INSERT guard and named deferred finalizers for
  both Note versions and children. Validate counts/contiguous ordinals/bounds;
  compare existing seals exactly, never silently ignore conflicts or reseal.
- [ ] Extend new-member provenance guards to derive unchanged retention from
  stored direct parent(s), comparing member UUID and every semantic field except
  ordinal/new container/time. Retained deleted evidence can reorder; changed or
  new fields require live typed/ready exact sources. A mixed target cannot grant
  a blanket retention exemption. Never trust caller flags or a custom GUC.
- [ ] Independently require retained parents to belong to the same Note/owner/
  private identity and have strictly lower canonical resource revisions than
  the containing new version. Add raw-SQL self-parent, non-lower parent and
  two-version-cycle rejection vectors; the old same-resource FK is insufficient.
- [ ] Make `insert_set` flush only named full-set provenance/finalizer
  constraints after both collections, including empty Note finalization.
  The adapter owns only these named initially-deferred modes: flush immediate
  then re-defer them, leaving every unrelated constraint mode untouched.
  Do not claim arbitrary prior-mode restoration; no `SET CONSTRAINTS ALL`.
- [ ] Replace complete-set fixtures that append after Note commit with atomic
  same-transaction construction. The former positive second-transaction append
  assertion becomes a sealed negative, not deleted/skipped coverage.
- [ ] Prove reverse ordinal and parent/child construction, gap/101-member
  rejection, early-immediate sealing and irreversible re-deferral, rollback,
  append/update/delete/reseal rejection, cross-owner denial, and a barrier
  controlled concurrent child append during Note/seal commit.
- [ ] Run full changed sealing/schema/link/RLS suites and migration history
  contracts, SPEC then QUALITY review; commit `feat(storage): seal note version sources`.

## Task 3: Atomic Note mutation source composition and ordered locks

**Create:** Storage `postgres/note_sources.ex` and
`test/singularity/storage/postgres/note_sources_test.exs` for the narrow
prepare/lock/insert composition; no general graph/process abstraction.
**Modify:** `postgres/note_repository.ex`, `knowledge_link_repository.ex`,
and owning `note_repository_test.exs`/`knowledge_link_repository_test.exs`.

- [ ] Add real integration RED for metadata-only new versions, normal/stale
  inheritance from exact base, independent clear/replace, and merge inheritance
  from expected current while explicit unchanged members may use either parent.
- [ ] Prepare the full target set without row locks inside winning receipt
  callback. Do not call the current locking `list_set` for early preparation.
  Expose a narrow immutable membership reader with canonical revalidation.
- [ ] Lock sorted target Assets→objects→all resources including edited Note→
  aggregate advisory locks→resource versions→Asset associations before CAS.
  No later target discovery or Asset locking; preserve existing shared-request,
  receipt, deadlines, head/conflict and projection semantics.
- [ ] Resolve canonical witnesses per-member as historical retained or live new;
  construct stored NoteSourceSet with derived owner/new Note/version/ordinals;
  insert both collections and force seal within shared `insert_note_version`.
- [ ] Replay must bypass all preparation/live checks and leave zero new rows,
  audits, jobs or events after source deletion; same-ID changed request conflicts.
- [ ] Prove old versions remain exact, stale conflict sets preserve submitted
  metadata, merge parents/conflict resolution remain correct, changed/new dead
  references fail atomically, forged/self/cyclic/non-lower parent and
  owner/locator/pins fail in adapter
  and raw SQL, and bounds/rollback maintain prior row/effect counts.
- [ ] Add barrier-controlled mutual Note attachments, Save versus Asset delete
  and Document lifecycle operations, without sleeps/timeout increases. Run all
  changed Note/source owning integration suites and deadline regressions;
  SPEC then QUALITY review; commit `feat(storage): persist note sources atomically`.

## Task 4: Authenticated source mutation, DTOs and exact resolution

**Create:** Runtime `notes/resolve_source.ex`, `dto/note_attachment.ex`,
`dto/note_citation.ex`, and `test/singularity/runtime/note_sources_test.exs`.
**Modify:** Runtime `notes/create.ex` (contains Mutation), `notes/dto.ex`,
`dto/note.ex`, `dto/note_version.ex`, `api.ex`, existing Notes owning tests;
Storage new forward `20261011000100_knowledge_runtime_grants.exs` and
`knowledge_grants_test.exs` exact ACL expectations.

- [ ] Add Runtime RED for optional reference client fields, absent/clear/mixed
  modes, conflict/source response shape and exact resolution selectors.
- [ ] Extend fixed client whitelist only for the two collections; reject owner,
  Vault, sentinel, evidence/retention and containing-version injection. Continue
  deriving scope from authenticated context.
- [ ] Use current `note.write` plus unlock. New Note sources require existing
  `note.read`; Asset/Document sources require existing `asset.read`. Copying
  retained exact references must not fetch private source content. Compose
  required existing capabilities inside OperationScope; no Vault change.
- [ ] Include exact ordered owner-free references in version/conflict DTOs;
  normalize/revalidate all nested shapes. Add `resolve_note_attachment` and
  `resolve_note_citation` with containing Note read and current target read.
  Preserve pins, expose deleted status/historical evidence, and don't return
  new original-byte payloads or follow current head.
- [ ] Apply explicit narrow web source/organization grants under forced RLS;
  worker/download remain excluded; seal write privileges remain absent.
- [ ] Test real canonical mutation composition, capability denial/revocation,
  owner isolation, deleted/restored exact sources, replay/latest-head hydration,
  and strict API registration. Keep logging/audit/job/event payloads content-free.
- [ ] Run full changed Runtime/Storage grant/RLS suites, SPEC then QUALITY;
  commit `feat(runtime): expose version pinned note sources`.

## Task 5: Bounded organization values, ports and queries

**Create:** Core `organization_page_query.ex`, `organization_page.ex`;
Domains `organization.ex`; Storage `postgres/organization_cursor.ex` and
owning pure/adapter tests.
**Modify:** existing Domains tag/relationship ports and Storage
`tag_repository.ex`, `relationship_repository.ex` with scoped internal seams.

- [ ] Add failing fixed-key query/page contracts: limit1–50/default20, cursor
  optional/max2048, ordered unique owner-free outputs and exact cursor binding.
- [ ] Add tag browse port and limit+1 UUID keyset browse; edge outgoing/incoming
  use relationship UUID keysets, selector visibility and live endpoints.
  Preserve legacy calls; avoid hidden max100 truncation on the public seam.
- [ ] Add `list_resource_tags(session, resource_id, params \\ %{})` with the
  same bounded page contract, tag UUID keyset and resource-selector cursor
  domain. Retain the legacy internal list call; prove a >100-tag resource is
  completely traversable without an unbounded query or silent truncation.
- [ ] Domain-separated authenticated cursor binds owner, selector, direction
  and ordering version using existing secret; tampering/wrong context fails
  sanitized. Pages are live, not stable snapshots across mutations.
- [ ] Add internal in-scope resolve/attach/detach/relate/unrelate/query paths
  usable inside Runtime OperationScope without nested transactions; retain
  existing standalone adapter behaviors. No Save/organization atomic coupling.
- [ ] Preserve tag normalization/first spelling, natural edge identity/pin
  conflicts, directed semantics and audit-only-on-change. Correct temporary
  grant helper cleanup to restore existing privileges, not revoke permanent ones.
- [ ] Run full tag/edge/cursor/query suites and negative RLS tests; SPEC then
  QUALITY review; commit `feat(storage): page knowledge organization queries`.

## Task 6: Authenticated tag, relationship and backlink operations

**Create:** Runtime `organization/operations.ex`, DTO organization page/items,
`test/singularity/runtime/organization_api_test.exs`.
**Modify:** Runtime `api.ex`, registration contracts and necessary adapter config.

- [ ] Add failing APIs for design's attach/detach/list/browse tags and
  relate/unrelate/outgoing/backlinks signatures and strict owner-free fields.
- [ ] Derive owner from Runtime context; require existing `note.read/write` or
  `asset.read/write` by actual resource kind. Relation creation checks both
  visible endpoints and source write authority; no new capabilities.
- [ ] Filter appropriate read capabilities before page admission, with bounded
  queries and no unfiltered count/existence leak; pagination must not silently
  truncate permitted results. Unknown/cross-owner selectors are nondisclosing.
- [ ] Prove Unicode duplicate tags preserve canonical UUID/spelling, repeated
  attach/detach/relate/unrelate emit no extra mutation/audit, pin changes conflict,
  reversed direction remains distinct and self-edges fail. Prove deterministic
  pages/backlinks omit tombstoned endpoints and restore makes live rows visible.
- [ ] Prove selector/cursor/capability denial and revocation paths, ID-only
  audit/telemetry/privacy and Web-only-Runtime boundary. Run full owning suites;
  SPEC then QUALITY review; commit `feat(runtime): add knowledge organization APIs`.

## Task 7: Ordinary Markdown source rendering

**Create:** Core `note_markdown_sources.ex` and owning tests.
**Modify:** Runtime `notes/export.ex` and owning export tests.

- [ ] Add RED for empty byte identity, ordered pinned source information,
  standard readable footnotes/links and Unicode/Markdown escaping.
- [ ] Implement pure rendering from validated authorized descriptors and safe
  exporter-assigned relative links, never caller filesystem paths/proprietary
  schemes. Nonempty references append a separated Sources section; footnotes
  include exact UUID/version/fragment and human-readable locator. Do not fetch
  bytes or create a Phase5 portable/V3 package.
- [ ] Compose after existing `note.export` plus `note.read` and every required
  current source read. Deleted exact sources stay readable as historical
  metadata; unauthorized content is not hydrated or silently exported.
- [ ] Test escaping/scheme rejection, stable deterministic output, pinned old
  source despite new head, deletion, invalid nested descriptors and privacy.
  Run existing text export/Runtime suites; SPEC then QUALITY review; commit
  `feat(notes): render portable markdown citations`.

## Task 8: Complete legacy restore compatibility

**Modify:** Storage `backup/restorer.ex` only for derived-seal destination
locking/pre-emptiness inventory; add sealing restore contracts and full owning
`restore_import_test.exs`, `restore_rewrap_test.exs`, `unified_search_restore_test.exs`
coverage as needed. V1/V2 schema/export wire columns and crypto remain unchanged.

- [ ] Add RED for derived destination seal inventory and restored empty seals.
- [ ] Include seals in pre-restore lock/empty checks separately from the
  post-restore excluded-table list; restore legitimately regenerates seals.
- [ ] Run full original V1/V2 restore oracle; assert every restored Note version
  has exact immutable empty seal, unchanged canonical counts/bytes/digests and
  search reconstruction. Preserve unsupported-backup rejection for nonempty
  attachments/citations/tags/edges, not empty derived seals.
- [ ] Verify rollback/resume inventory and unchanged wire manifests, no backup
  cryptography/key lifecycle changes. Explicitly report frozen-substrate file
  patch; SPEC then QUALITY review; commit `fix(backup): regenerate note source seals`.

Task8 is a prerequisite for whole-phase acceptance, not a reason to postpone
needed restore verification after the Task2 schema change; run relevant full
restore contracts immediately when Task2/Task3 can affect them.

## Task 9: Whole-candidate qualification and automatic handoff

**Files:** Phase4 report, design/plan, master Phase4 checklist and active guidance.

- [ ] Run all changed owning suites plus deterministic source/organization
  canary/deadline/race regressions; record exact commands, seeds, counts and
  every failed attempt honestly. No E2E, assertion waiver or timeout increase.
- [ ] Independently review the complete clean candidate for SPEC coverage of
  every master Phase4 deliverable; then separate QUALITY/privacy/lock/grant
  source review. Resolve findings, rerun required tests and re-review.
- [ ] Run the complete permitted README dependency/build/static/format/compile/
  zero-cycle/unit/property/integration/restore/frontend/workflow gate from one
  recorded clean source. E2E stays NOT RUN and is not counted as passing.
- [ ] Verify owned PG shutdown, zero generated databases and recorded temporary
  roots absent, unchanged protected worktree heads/untracked hash, no background
  test/service process, and clean scoped commit state.
- [ ] Record tested source versus documentation-only handoff, new migration
  inventory, exact review/verdicts, compatibility patch, remaining final E2E and
  activation/publication limits. Mark only proven Phase4 checkboxes complete.
- [ ] Local qualified acceptance requires all executed gates PASS and review
  PASS. Commit `docs: record phase four local acceptance`; automatically prepare
  separately reviewed Phase5 design/plan in its own `.trees` worktree. Do not
  merge/push/release/deploy or claim the final browser/release gate passed.
