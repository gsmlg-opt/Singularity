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
- [x] Run the two full existing governance suites, format/compile/xref and diff
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
- [x] Write new tests before production changes. Require real constructors,
  ordered typed fields, omitted initial empty/normal inherited/merge inherited
  modes, independent explicit clear, canonical Unicode/string alias behavior,
  invalid fields/UUIDs/kinds/roles/locators/forged structs/duplicates/bounds.
  No caller scope, containing Note/version or ordinal fields are accepted.
- [x] Parent executes the tests and records expected missing-module/default
  RED. Then implement the two strict owner-free reference values, using fixed
  kind/role clauses and existing validators/SourceLocator; no new dependency.
- [x] Extend snapshots with at most 100 references per collection, unique member
  IDs and attachment target/version/role tuples, at most 100 union targets and
  fragments. Preserve list order. Create omission is `[]`; normal/merge omission
  is internal `:inherit`; explicit sentinel input is invalid.
- [x] Add optional source fields only to create/save/merge Command keys;
  keep all existing required keys/strict aliases and lifecycle shapes. When
  rebuilding a command, omit internal `:inherit` fields to preserve omission
  rather than accepting explicit client sentinels. Domains and Runtime HMAC
  reconstruction must propagate lists and preserve canonical equality.
- [x] Preserve exact v1 literal tuples for default modes and explicit empty
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
- [x] Add Domains fake-port intent assertions using its existing fake, not a
  database simulation; prove forged snapshot/command still fails before port.
  Add Runtime HMAC tests with a literal independently constructed v1 oracle,
  every-field/order/mode v2 perturbations, normalization equivalence, malformed
  nested structs and sanitized errors. Do not change Runtime input/grants yet.
- [x] Run new and all four existing owning files, format/compile/xref, inspect
  diff, SPEC then QUALITY review. Commit `feat(notes): model versioned source intent`.

## Task 2: SQL source-set sealing and historical retention guards

**Create:** Storage migration
`priv/repo/migrations/20261011000000_seal_note_source_sets.exs`;
`test/singularity/storage/note_source_set_sealing_test.exs`.
**Modify:** Storage `postgres/knowledge_link_repository.ex`, support
`knowledge_fixtures.ex`, `knowledge_schema_test.exs`, `knowledge_rls_test.exs`,
owning `postgres/knowledge_link_repository_test.exs`, `knowledge_privacy_test.exs`
and `backup/logical_exporter_test.exs` as required. These established source-set
fixtures must change together so the new seal does not mask their existing
privacy, provenance, replay or unsupported-backup assertions.

- [x] Add integration RED proving a committed empty/nonempty version can still
  be appended; preserve every original FK/ordinal/locator/identity negative.
- [x] Add the immutable owner-scoped seal table and composite typed-Note FK;
  forced RLS, exact grants and bounded counts. Runtime gets no direct seal
  INSERT/UPDATE/DELETE/TRUNCATE; no role attributes/membership changes.
- [x] Under write-excluding table locks, validate/backfill old structural sets
  including empty versions, without child rewriting or historical live checks.
  Add migration vectors for old nonempty membership and malformed old sets.
- [x] Add visible-seal child INSERT guard and named deferred finalizers for
  both Note versions and children. Validate counts/contiguous ordinals/bounds;
  compare existing seals exactly, never silently ignore conflicts or reseal.
- [x] Extend new-member provenance guards to derive unchanged retention from
  stored direct parent(s), comparing member UUID and every semantic field except
  ordinal/new container/time. Retained deleted evidence can reorder; changed or
  new fields require live typed/ready exact sources. A mixed target cannot grant
  a blanket retention exemption. Never trust caller flags or a custom GUC.
- [x] Independently require retained parents to belong to the same Note/owner/
  private identity and have strictly lower canonical resource revisions than
  the containing new version. Add raw-SQL self-parent, non-lower parent and
  two-version-cycle rejection vectors; the old same-resource FK is insufficient.
- [x] Make `insert_set` flush only named full-set provenance/finalizer
  constraints after both collections, including empty Note finalization.
  The adapter owns only these named initially-deferred modes: flush immediate
  then re-defer them, leaving every unrelated constraint mode untouched.
  Do not claim arbitrary prior-mode restoration; no `SET CONSTRAINTS ALL`.
- [x] Replace complete-set fixtures that append after Note commit with atomic
  same-transaction construction. The former positive second-transaction append
  assertion becomes a sealed negative, not deleted/skipped coverage.
  Split fixture identity allocation from `insert_note!(repo, source, row)`;
  keep `note!/1` for empty committed sets and use an optional same-transaction
  owner callback for raw schema fixtures. Adapter fixtures must create the Note
  and call the real `insert_set` inside one ScopedRepo/RequestRepo transaction,
  never a MigrationRepo callback followed by a different connection. Keep
  readiness/FK/locator failures on fresh unsealed Notes so an append guard cannot
  mask the intended constraint. Replace the old committed-empty append race
  with a fresh-version publication barrier while preserving reader atomicity.
  The oversized-reader regression inserts 101 real citations on a fresh Note,
  asserts the SQL count and unchanged real-reader rejection inside that same
  scoped transaction, then deliberately rolls back before deferred finalization.
  Separately prove actual oversized-set commit rejection; no disabled triggers,
  faked SQL or weaker cardinality assertions. Unsupported-backup fixtures must
  still contain real legal nonempty metadata, constructed atomically.
- [x] Prove reverse ordinal and parent/child construction, gap/101-member
  rejection, early-immediate sealing and irreversible re-deferral, rollback,
  append/update/delete/reseal rejection, cross-owner denial, and a barrier
  controlled concurrent child append during Note/seal commit.
- [x] Run full changed sealing/schema/link/RLS suites and migration history
  contracts, SPEC then QUALITY review; commit `feat(storage): seal note version sources`.

## Task 3: Atomic Note mutation source composition and ordered locks

**Create:** Storage `postgres/note_sources.ex` and
`test/singularity/storage/postgres/note_sources_test.exs` for the narrow
prepare/lock/insert composition; no general graph/process abstraction.
**Modify:** `postgres/note_repository.ex`, `knowledge_link_repository.ex`,
`note_mutation_receipts.ex` for fingerprint-only conflict classification, and
owning `note_repository_test.exs`/`knowledge_link_repository_test.exs` plus the
complete `note_mutation_receipts_test.exs`. Preserve structural operation/resource
mismatch invalid errors; explicitly update only the fingerprint mismatch contract
and strengthen combined-mismatch precedence/unchanged-row/effect assertions.

- [x] Add real integration RED for metadata-only new versions, normal/stale
  inheritance from exact base, independent clear/replace, and merge inheritance
  from expected current while explicit unchanged members may use either parent.
- [x] Prepare the full target set without row locks inside winning receipt
  callback. Do not call the current locking `list_set` for early preparation.
  Expose a narrow immutable membership reader with canonical revalidation.
- [x] Lock sorted target Assets→objects→all resources including edited Note→
  aggregate advisory locks→resource versions→Asset associations before CAS.
  No later target discovery or Asset locking; preserve existing shared-request,
  receipt, deadlines, head/conflict and projection semantics.
- [x] Resolve canonical witnesses per-member as historical retained or live new;
  construct validated Core NoteAttachment/NoteCitation rows from strict resolved
  reference lists with derived owner/new Note/version/ordinals; check actual
  canonical typed/fragment/locator metadata without fetching retained content,
  preserving the full-text public NoteSourceSet constructor unchanged;
  insert both collections and force seal within shared `insert_note_version`.
- [x] Replay must bypass all preparation/live checks and leave zero new rows,
  audits, jobs or events after source deletion; same-ID changed request conflicts.
  Characterize the unchanged complete receipt suite, observe fingerprint-only
  conflict RED, then repair without changing receipt keys/HMAC or weakening
  owner/operation/resource/integrity guards. Preserve established same-owner
  lineage error classification through nonlocking aggregate-input preflight,
  followed by all original post-ordered-lock revalidation.
- [x] Prove old versions remain exact, stale conflict sets preserve submitted
  metadata, merge parents/conflict resolution remain correct, changed/new dead
  references fail atomically, forged/self/cyclic/non-lower parent and
  owner/locator/pins fail in adapter
  and raw SQL, and bounds/rollback maintain prior row/effect counts.
- [x] Add barrier-controlled mutual Note attachments, Save versus Asset delete
  and Document lifecycle operations, without sleeps/timeout increases. Run all
  changed Note/source owning integration suites and deadline regressions;
  SPEC then QUALITY review; commit `feat(storage): persist note sources atomically`.

## Task 4: Authenticated source mutation, DTOs and exact resolution

The bounded winning-source mutation slice has passed its actual Runtime units,
real Storage/Runtime authorization suites, static gates and independent SPEC
then QUALITY. The narrow Storage selected-reader slice has also passed its
actual port/owning SQL suites, static gates and separate SPEC then QUALITY.
Runtime DTO/composer and all current/exact/conflict/mutation/Export collection
routes have passed their owning units, real authorization suites, static gates
and separate SPEC then QUALITY after a reproduced canonical-output repair.
Public exact resolution and permanent grants have now passed their focused RED,
full owning Runtime/Storage/Web suites, static gates and actual independent
SPEC then QUALITY. Task 4 is locally qualified; this is not Phase 4 acceptance.

**Create:** Runtime `notes/resolve_source.ex`, `dto/note_attachment.ex`,
`dto/note_citation.ex`, `notes/source_collections.ex`, and the source owning tests.
**Modify:** Runtime `notes/create.ex` (contains Mutation), `notes/dto.ex`,
`notes/get.ex` and `notes/export.ex` for shared metadata-only source composition,
`dto/note.ex`, `dto/note_version.ex`, the shared `NoteValidation` section in
`dto/note_summary.ex` (without changing summary fields/behavior), `api.ex`,
existing Notes owning tests and new `note_source_collections_test.exs` and
`note_source_collection_routes_test.exs`
(`note_mutations_test.exs`, `note_reads_test.exs`, `note_api_test.exs`,
`note_authorization_integration_test.exs`, `note_observability_test.exs`);
Storage `postgres/note_repository.ex` and `postgres/note_sources_test.exs` for
the server-only winning authorization context; `postgres/knowledge_link_repository.ex`
and its full owning suite for narrow selected-reference/historical metadata readers, plus
Domains `knowledge_links/repository.ex` and `knowledge_ports_test.exs` for the four
explicitly typed existing-scope selector/resolution callbacks;
`test/support/knowledge_test_grants.ex` to preserve permanent organization
DELETE privileges in temporary test grants; Web
`architecture/knowledge_phase1_contract_test.exs` for exact approved API additions;
Web `notes_live_test.exs` constructor fixtures for explicit empty reference arrays,
without changing browser behavior;
Storage new forward `20261011000100_knowledge_runtime_grants.exs` and
`knowledge_grants_test.exs` exact ACL expectations and
`knowledge_rls_test.exs` durable-grant/missing-scope contracts.

- [x] Add Runtime RED for optional reference client fields, absent/clear/mixed
  modes, conflict/source response shape and exact resolution selectors.
- [x] Extend fixed client whitelist only for the two collections; reject owner,
  Vault, sentinel, evidence/retention and containing-version injection. Continue
  deriving scope from authenticated context.
- [x] Use current `note.write` plus unlock. New Note sources require existing
  `note.read`; Asset/Document sources require existing `asset.read`. Copying
  retained exact references must not fetch private source content. Compose
  required existing capabilities inside OperationScope; no Vault change.
- [x] Pass only a server-created scoped-repo/authorization-callback context
  through the existing opaque repository port. Preserve raw internal callers;
  mapped contexts without a valid callback fail closed. Invoke after new-member
  preparation only inside the winning receipt callback, before ordered locks
  and insertion. Bind both current session epochs in the existing authorizer;
  empty/new-member-free and replay paths bypass it. Keep intents/Command/HMAC
  unchanged. Prove same-repo ordering, denial rollback, retained-only and replay
  bypass with real storage tests; preserve ordinary sanitized source denial
  rather than forging the initial OperationScope denial/audit marker.
- [x] Include exact ordered owner-free references in version/conflict DTOs;
  normalize/revalidate all nested shapes. Add `resolve_note_attachment` and
  `resolve_note_citation` with containing Note read and current target read.
  Preserve pins, expose deleted status/historical evidence, and don't return
  new original-byte payloads or follow current head.
- [x] Compose complete source arrays in Runtime through a shared helper and the
  explicit internal `knowledge_link_repository`, using the existing scoped
  metadata-only membership reader. Bind exact row IDs/revision/session scope;
  compose both conflict branches separately and latest-head mutation replay.
  Export must compose before strict DTO conversion even before Task 7 rendering.
  Preserve raw Storage reader contracts and summary/history/search DTOs.
  Constructors require explicit arrays; nested reference DTOs reject extra or
  noncanonical data, duplicates and oversized sets. Do not replace an absent or
  failed real membership read with empty arrays. Unit fakes must inject their
  own explicit reader; actual source integration must retain the real one.
- [x] Select only the requested stored canonical member on the authenticated
  scoped connection before determining its target read capability. After that
  current check, hydrate exact historical Asset/Note/Document typed metadata
  and the selected citation fragment/locator on the same authorization boundary.
  Do not reuse live-only search resolution or content-hydrating whole-set reads
  unchanged for pre-authorization selection. Keep ordinary live-only resource
  read behavior intact; missing/foreign members are nondisclosing.
- [x] Add the four `select_attachment_in_scope/4`, `select_citation_in_scope/4`,
  `resolve_attachment_in_scope/2` and `resolve_citation_in_scope/2` operations
  with named explicit owner-free metadata/fragment/resolution port types.
  Selectors validate the live/private/sealed containing tuple and matching
  scoped GUCs, select only the requested member and hold the containing share
  lock. Resolution remains a separate post-target-authorization operation:
  exact historical typed metadata and only the selected citation fragment,
  preserving pins, locator/digest and tombstone/restore status. Missing or
  mismatched AssetMetadata binding is not-found, never a mutable-head fallback.
  Characterize unchanged adapter/port tests, add actual RED for these callbacks,
  and qualify the full owning suites plus requested-member isolation and strict
  owner-free outputs. Temporary SELECT revocation must restore the original ACL;
  no trigger, policy or seal assertion may be bypassed to construct a fixture.
- [x] Apply explicit narrow web source/organization grants under forced RLS;
  worker/download remain excluded; seal write privileges remain absent.
- [x] Test real canonical mutation composition, capability denial/revocation,
  owner isolation, deleted/restored exact sources, replay/latest-head hydration,
  and strict API registration. Keep logging/audit/job/event payloads content-free.
- [x] Run full changed Runtime/Storage grant/RLS suites, SPEC then QUALITY;
  commit `feat(runtime): expose version pinned note sources`.

## Task 5: Bounded organization values, ports and queries

The pure and Storage portions are locally qualified. The public resource-tag
facade remains in Task 6, and permanent-grant cleanup remains coupled to Task 4.

**Create:** Core `organization_page_query.ex`, `organization_page.ex`;
Domains `organization.ex`; Storage `postgres/organization_cursor.ex` and
owning pure/adapter tests.
**Modify:** existing Domains tag/relationship ports and Storage
`tag_repository.ex`, `relationship_repository.ex` with scoped internal seams.

- [x] Add failing fixed-key query/page contracts: limit1–50/default20, cursor
  optional/max2048, ordered unique owner-free outputs and exact cursor binding.
  Query fields are only `limit`/`cursor`; `OrganizationPage.new(operation,
  attrs, query)` receives the server operation separately and returns only
  `items`/`next_cursor`, with internal `:done` terminal. Fixed items are
  tag ID/display value, resource ID/kind, or edge ID/endpoints/nullable pin/type.
  Reject injected owner/capability/content fields, malformed/forged structs,
  duplicate/reversed UUID keys and non-full continuations. Domains' literal
  query dispatch revalidates selector/query/page, with trusted allowed kinds
  passed separately and SQL endpoint-kind filtering before `limit + 1`.
- [x] Add tag browse port and limit+1 UUID keyset browse; edge outgoing/incoming
  use relationship UUID keysets, selector visibility and live endpoints.
  Preserve legacy calls; avoid hidden max100 truncation on the public seam.
- [ ] Add `list_resource_tags(session, resource_id, params \\ %{})` with the
  same bounded page contract, tag UUID keyset and resource-selector cursor
  domain. Retain the legacy internal list call; prove a >100-tag resource is
  completely traversable without an unbounded query or silent truncation.
- [x] Domain-separated authenticated cursor binds owner, selector, direction
  and ordering version using existing secret; tampering/wrong context fails
  sanitized. Add an independent literal Perl/OpenSSL framing/HMAC oracle for
  the design's exact v1 `v/f/i/h` canonical JSON envelope and distinct binding/
  cursor domains. Cursor helpers take canonical last UUID, exact server binding
  and existing secret; decode nil only after validating binding/secret. Reject
  signed malformed/noncanonical/duplicate-key envelopes as well as bad MACs.
  Limit stays independent; reapply current allowed kinds each SQL page.
  Pages are live, not stable snapshots across mutations.
- [x] Add internal in-scope resolve/attach/detach/relate/unrelate/query paths
  usable inside Runtime OperationScope without nested transactions; retain
  existing standalone adapter behaviors. No Save/organization atomic coupling.
- [x] Preserve tag normalization/first spelling, natural edge identity/pin
  conflicts, directed semantics and audit-only-on-change.
- [ ] Correct temporary grant helper cleanup to restore existing privileges,
  not revoke permanent ones.
- [x] Run full tag/edge/cursor/query suites and negative RLS tests; SPEC then
  QUALITY review; commit `feat(storage): page knowledge organization queries`.

## Task 6: Authenticated tag, relationship and backlink operations

**Create:** Runtime `organization/operations.ex`, `organization/dto.ex`,
`organization/authorizer.ex`,
`dto/organization_tag.ex`, `dto/organization_resource.ex`,
`dto/organization_relationship.ex`, `dto/organization_page.ex`,
`test/singularity/runtime/organization_api_test.exs`,
`organization_authorizer_test.exs`, `organization_operations_test.exs` and
real-authorization owning contracts; Domains `organization/repository.ex`;
Storage `postgres/organization_repository.ex` and its owning test.
**Modify:** Runtime `api.ex`, registration contracts and necessary adapter config;
Domains `relationships/repository.ex`, Storage
`postgres/relationship_repository.ex` and its full owning test for additive
selected conditional deletion, retaining established callers.

- [x] Add failing APIs for design's attach/detach/list/browse tags and
  relate/unrelate/outgoing/backlinks signatures and strict owner-free fields.
  Use the design's fixed OrganizationTag/Resource/Relationship item DTOs and
  OrganizationPage; attach/relate return their item, detach/unrelate `:ok`.
  Preserve ownerful Core port contracts; strictly revalidate and bind before
  conversion. Core page validation remains unchanged; convert only its
  established terminal to public nil and never normalize server item values.
  Prove typed Page DTO roundtrips; raw page maps still require the Core terminal,
  not an untyped public nil sentinel.
- [x] Derive owner from Runtime context; require existing `note.read/write` or
  `asset.read/write` by actual resource kind. Relation creation checks both
  visible endpoints and source write authority; no new capabilities.
- [x] Compose the fixed read/write entry OR through an invocation-local injected
  authorizer, delegating existing single capabilities and both epochs on the
  existing locked/scoped connection; no general auth/Vault change. Preserve
  Note unlock and established Asset/Document metadata behavior. Exact kind
  checks precede labels/mutations; only canonical nonretryable returned forbidden
  or Note-lock denials permit alternatives. Exposed faults terminate; inherited
  Authorize forbidden opacity is explicit and never grants the denied kind.
  Add contracts for opaque denial plus independently complete fallback, direct
  throw/raise/exit, retryable and malformed replies, and denied-kind exclusion.
- [x] Add bounded complete resource ID/kind and selected edge metadata callbacks
  under matching scoped GUCs, with ordered Resource locks and no hydration.
  Bind exact keys/values/selectors, omit no requested member, and make missing/
  foreign selectors nondisclosing. Selected unrelate checks the live source's
  write then uses owner/all-field conditional DELETE without relationship UPDATE
  grants; absent/foreign stays no-op and tombstoned source is not-found.
- [x] Filter appropriate read capabilities before page admission, with bounded
  queries and no unfiltered count/existence leak; pagination must not silently
  truncate permitted results. Unknown/cross-owner selectors are nondisclosing.
- [x] Prove Unicode duplicate tags preserve canonical UUID/spelling, repeated
  attach/detach/relate/unrelate emit no extra mutation/audit, pin changes conflict,
  reversed direction remains distinct and self-edges fail. Prove deterministic
  pages/backlinks omit tombstoned endpoints and restore makes live rows visible.
- [x] Prove selector/cursor/capability denial and revocation paths, ID-only
  audit/telemetry/privacy and Web-only-Runtime boundary. Run full owning suites;
  SPEC then QUALITY review; commit `feat(runtime): add knowledge organization APIs`.

Task 6 is locally qualified after actual owning SQL **173 Storage / 42 Runtime**,
owning units **22 Core / 11 Domains / 9 Storage / 291 Runtime / 41 Web**,
exact 19-file format, warnings-as-errors compile and zero xref cycles. Independent
actual SPEC then separate QUALITY found zero actionable P0–P2 issues on the
unchanged 19-file manifest. Cleanup verified zero generated databases, all five
allocated roots absent and the owned private PostgreSQL server stopped. This is
not whole-Phase-4, live-custody, browser or release acceptance; E2E NOT RUN.
See the [qualification report](../../verification/2026-10-11-phase-4-acceptance.md).

## Task 7: Ordinary Markdown source rendering

**Create:** Core `note_markdown_sources.ex` and owning tests; Runtime
`note_markdown_source_export_test.exs` and `note_markdown_export_integration_test.exs`.
**Modify:** Runtime `notes/export.ex`, `dto/note_export.ex`, existing owning
export/DTO tests and the nonempty source-collection route contract as necessary.
No public Api signature, persistence port, grant or migration change is planned.

- [x] Independently SPEC then QUALITY review the Task 7 renderer/export detail,
  including the separate rendered 16 MiB ceiling and unchanged canonical 1 MiB
  write/input limit, before implementation. This is necessary compatibility,
  not an unrelated broadening of the old file list.

- [x] Add RED for empty byte identity, ordered pinned source information,
  standard readable footnotes/links and Unicode/Markdown escaping.
- [x] Implement pure rendering from validated authorized descriptors and safe
  exporter-assigned relative links, never caller filesystem paths/proprietary
  schemes. Nonempty references append a separated Sources section; footnotes
  include exact UUID/version/fragment and human-readable locator. Do not fetch
  bytes or create a Phase5 portable/V3 package.
- [x] Compose after existing `note.export` plus `note.read` and every required
  current source read. Deleted exact sources stay readable as historical
  metadata; unauthorized content is not hydrated or silently exported.
- [x] Test escaping/scheme rejection, stable deterministic output, pinned old
  source despite new head, deletion, invalid nested descriptors and privacy.
  Run existing text export/Runtime suites; SPEC then QUALITY review; commit
  `feat(notes): render portable markdown citations`.

Execute the reviewed detail with these deterministic contracts:

1. Add Core RED for exact closed/canonical descriptors, ordered complete sets,
   empty byte identity (including BOM/line endings), readable ordinary links and
   all locator forms, deleted status, Unicode/Markdown/control escaping,
   existing footnote label collisions, exact relative path/pin grammar,
   malformed references/locators, improper/duplicate/oversize sets, duplicate
   attachment natural keys with different member UUIDs/labels, legal
   descending member UUIDs and retained-member reordering without sorting,
   a legal 1 MiB body with sources and the rendered 16 MiB bound. Keep source
   body/fragment/owner/authority fields rejected.
   Characterize and test the reviewed conservative nonempty formatter admission:
   closed/proven open column-zero fences (both markers), matching/shorter/wrong/
   indented/content-bearing closers, LF/CRLF/bare CR, exact original prefix;
   raw HTML classes, autolinks, literal `<`, ambiguous indented/container/inline/
   escaped triple-runs and BOM-prefixed fences fail without audit. All such
   bodies with empty membership remain exact bytes. Count fence/escape output
   before allocation. Use the established local parser read-only to prove the
   Sources heading and appended references are outside code/HTML, not merely
   present as text; this does not run a browser or E2E.
2. Add Runtime RED using the real pure renderer, requiring all source-kind
   checks with both epochs before the first referenced hydration, one exact
   containing-reference selector, one existing scope and exact historical pins.
   A later denial/malformed member, body boundary or budget failure yields no partial output
   or success audit. Empty membership retains existing calls/byte identity.
3. Implement the pure renderer and narrowly update only rendered NoteExport
   validation. Extend Export's existing scope using original authorizer and
   in-scope selected/resolution ports, not new per-member public operations.
   Bound retained aggregate raw-title payloads, count rendered output before
   escape allocation, and finalize/validate the complete DTO before ID-only audit.
4. Add actual PostgreSQL/Authorize integration with permanent grants for mixed
   Asset/Note/Document membership, citation locators, changed heads, target
   deletion, current capability/epoch denial, exact source order/pins and audit
   privacy. Retain the integration Custodian limitation explicitly; no live
   custody/byte/browser proof is inferred. Parent serializes every Mix/DB run.
5. Run all owning Core/Runtime/export/DTO/source suites, static checks and actual
   SQL; actual SPEC then separate QUALITY on frozen implementation hashes,
   exact cleanup and scoped local commit. Task 9 remains required for phase
   acceptance; E2E stays NOT RUN.

## Task 8: Complete legacy restore compatibility

**Modify:** Storage `backup/restorer.ex` only for derived-seal destination
locking/pre-emptiness inventory; add sealing restore contracts and full owning
`restore_import_test.exs`, `restore_rewrap_test.exs`, `unified_search_restore_test.exs`
coverage as needed, plus the existing Runtime `singularity.test.restore` oracle's
destination inventory and exact restored-seal assertions. Update only relevant
test destination/reset helpers for the new derived table; never classify
legitimate restored seals as post-restore excluded data. V1/V2 schema/export
wire columns, crypto and all original canonical assertions remain unchanged.

- [x] Add RED for derived destination seal inventory and restored empty seals.
- [x] Include seals in pre-restore lock/empty checks separately from the
  post-restore excluded-table list; restore legitimately regenerates seals.
- [x] Run full original V1/V2 restore oracle; assert every restored Note version
  has exact immutable empty seal, unchanged canonical counts/bytes/digests and
  search reconstruction. Preserve unsupported-backup rejection for nonempty
  attachments/citations/tags/edges, not empty derived seals.
- [x] Verify rollback/resume inventory and unchanged wire manifests, no backup
  cryptography/key lifecycle changes. Explicitly report frozen-substrate file
  patch; SPEC then QUALITY review; commit `fix(backup): regenerate note source seals`.

Task8 is a prerequisite for whole-phase acceptance, not a reason to postpone
needed restore verification after the Task2 schema change; run relevant full
restore contracts immediately when Task2/Task3 can affect them.

## Task 9: Whole-candidate qualification and automatic handoff

**Files:** Phase4 report, design/plan, master Phase4 checklist and active guidance.

Necessary qualification repair, 2026-10-11: the first complete unit attempt
exposed the old `knowledge_ports_test.exs` callback inventory missing the Task6
`unrelate_selected_in_scope/2` contract. Synchronize that exact inventory and
assert its selected `Organization.Repository.relationship_metadata()` argument
and complete return type; preserve every prior assertion. No production port,
grant, schema, released migration or Vault change is needed. Run the owning
port/organization suites and independent SPEC then separate QUALITY review
before a narrow local repair commit, then rerun the entire permitted README
gate on the resulting clean source.

The initial qualification runner added `--warnings-as-errors` to the global
unit/integration test commands, beyond README's required commands. Record
that attempt as FAIL. The required rerun uses README's `mix test` and
`mix singularity.test.integration` with the recorded deterministic seed,
retains `mix compile --warnings-as-errors`, and executes every required test
and assertion. Existing frozen Vault test-module redefinition warnings remain
visible and unmodified; no warning suppression or compiler-option change is
authorized. Focused suites keep their already-qualified stricter test flag.

### Task 9 necessary compatibility and diagnosis work

Complete-gate `44472` failed on clean source `1f760855`: Storage integration
reported five failures. Separate whole-candidate QUALITY found two Asset
lifecycle defects. The independently SPEC/QUALITY-reviewed amendment is now
part of the governing design; preserve the failed gate and every old assertion.

1. Historical test-contract repair: change only
   `postgres/search_candidate_migration_test.exs`,
   `postgres/search_candidate_ids_test.exs`,
   `search_projection_schema_test.exs` and `document_schema_test.exs`.
   Run each complete historical contract at `20261010000000`, preserving its
   nested predecessor, inventory SQL, lock barriers, deadlines and errors.
   Assert exact historical migration head and enclosing latest repository
   configuration/head/catalog/security restoration. Add a separate latest
   sealed non-head typed Note deletion regression with unchanged identities,
   head and seals. Run all four owning files and current grants/sealing
   counterproofs, actual SPEC then fresh QUALITY and a narrow local commit.
2. Diagnose short-literal plan failure: unchanged focused run `97157` passes,
   but does not resolve the failed complete-run case. Add failing diagnostic
   contracts before a test-only opt-in process-local first-error record in
   `test/support/knowledge_search_plan_observer.ex`, its owning observer tests
   and `postgres/knowledge_search_plan_test.exs`. Keep closed fixed fields,
   unchanged public errors, cleanup, content-canary and zero logging/query
   telemetry; no error messages, operands, raw plans/queries/params or stack
   arguments. Run complete observer/plan suites with unchanged deadline
   barrier. Design a production repair only after actual cause is evidenced.
3. Asset lifecycle repair: parent adds real `Api.delete_asset` RED to owning
   Runtime organization and Markdown/source integration tests. After RED, Sol
   owns new forward migration
   `20261011000200_knowledge_asset_lifecycle_guards.exs`, shared hardened invoker
   predicates/witnessed guard, KnowledgeLink/Organization/Tag/Relationship
   repositories and owning SQL tests. Parent owns Runtime tests and evidence.
   Historical metadata must retain the exact Resource/version/Asset/Metadata/
   association identity after deletion/cleanup. Before metadata selection, count
   distinct Asset IDs across Asset, metadata and association evidence for the
   pinned version/owner without filtering classification or lifecycle markers;
   require exactly one identity and retain every exact private join. Admission
   and exact selection must share one SQL statement/snapshot; retain
   the entire population in SQL with bounded scalar/metadata output, not a BEAM
   candidate list. State that this relies on retained lifecycle evidence and
   cannot reconstruct identity after all original evidence is lost. Native-web
   reclassified-A-plus-B and reassigned-A-plus-B regressions must prove fail-closed
   resolution without new identity fields, update restrictions or privileges.
   Organization SQL filters live
   bindings before LIMIT; one INSERT-trigger guard locks Assets before Resources,
   retaining and revalidating only actually held witnesses. No nested/late
   Asset locks, newly inserted rescue binding, invented binding cap or retry.
   Runtime metadata prechecks/read selectors become lock-free under the
   unchanged global kind-immutability contract. Detach/selected-unrelate uses
   one source-only guard; first check exact selected-row visibility without
   locks so absent/foreign/mismatched no-ops and legacy unrelate remain unchanged.
4. Prove actual delete/normal cleanup, every live state/multiple bindings,
   exact historical pins/title/deleted marker, retained Save/new-source rejection,
   selectors/pages/audits and native role/RLS/ACL/kind immutability. Use supported
   upload B and observed Asset A lock barriers for unheld-binding rejection,
   still-live-witness control, one INSERT guard and Note Save/finalization/delete
   interleavings. No fake deletion, direct Resource tombstone substitute,
   arbitrary sleeps, deadline increase, assertion waiver, Vault/custody change,
   E2E or publication.
5. Run owning suites, complete V1/V2 restore/static checks and actual SPEC then
   fresh QUALITY before a scoped local repair commit. Any changed candidate
   needs a new whole-candidate frozen SPEC then fresh QUALITY and the entire
   permitted README gate on one clean source. Phase4 stays unaccepted and
   Phase5 execution remains pending until all required checks pass.

Broader owning-suite refinement (133 tests / nine failures): independently review
the added fixture/payload-privacy design detail before test edits. Sol owns only
`postgres/tag_repository_test.exs` and `postgres/organization_repository_test.exs`
for this refinement; parent applies separate RED and repair artifacts and runs
all SQL checks. Preserve every original assertion and keep production source
unchanged. Locally add the two exact ResourceAsset bindings while preserving
the original staging fixtures. Refine only the isolated Organization ACL helper:
retain table SELECT denials and exact metadata results, allow the five enumerated
Asset lifecycle columns, deny every other typed column with actual-role probes,
prove RLS/nonlive/fail-closed behavior, and restore complete table/column
privilege-entry inventories and original web SELECT ACLs in `after`, including
callback failure. Fail unsupported grantors before mutation and preflight/reject
all web-issued table/column SELECT grants before the first
mutation, with no CASCADE and a native-web dependent-grant unchanged-inventory
counterproof. No shared fixture,
Vault, production privilege/definer change or assertion waiver. Record RED then
full five-file Storage owning GREEN and fresh independent source SPEC followed
by separate QUALITY; previous scoped source review is not acceptance of new
test contracts.

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
