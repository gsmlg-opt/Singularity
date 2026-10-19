# Singularity Repository Instructions

## Active release

The only active product release is Singularity `0.2.0`, the first complete
single-user personal knowledge base. Its governing documents are:

- `docs/superpowers/specs/2026-08-31-singularity-v0.2-release-design.md`
- `docs/superpowers/specs/2026-09-01-singularity-v0.2-phase-0-blocker-repair-design.md`
- `docs/superpowers/plans/2026-08-31-singularity-v0.2-release.md`
- `docs/superpowers/specs/2026-09-06-singularity-v0.2-phase-1-canonical-model-design.md`
- `docs/superpowers/plans/2026-09-06-singularity-v0.2-phase-1-canonical-model.md`

Work proceeds one accepted phase at a time in a separate project-local
worktree and branch. Phase 3 has qualified local acceptance on tested source
`35c1f8360dd22b129832a1618b3723032a1983bd`, recorded by documentation handoff
`617f0b986a3ecffba14c952988e39e3afe022cea`. Its historical design and plan remain
`docs/superpowers/specs/2026-10-09-singularity-v0.2-phase-3-unified-lexical-search-design.md`
and
`docs/superpowers/plans/2026-10-09-singularity-v0.2-phase-3-unified-lexical-search.md`.
Phase 4 has qualified local acceptance on tested source
`42c01a5c99b1df3d1e4284d277c6ea48046875cb`, recorded in
`docs/verification/2026-10-11-phase-4-acceptance.md`, with documentation handoff
`5f7e6363be534dbfb4dfa1475538fddcbd29cf32`. Its historical design and plan remain
`docs/superpowers/specs/2026-10-11-singularity-v0.2-phase-4-knowledge-links-design.md`
and
`docs/superpowers/plans/2026-10-11-singularity-v0.2-phase-4-knowledge-links.md`.
The active implementation slice is Phase 5 under
`docs/superpowers/specs/2026-10-11-singularity-v0.2-phase-5-export-backup-design.md`
and
`docs/superpowers/plans/2026-10-11-singularity-v0.2-phase-5-export-backup.md`.
Phase 5 implementation and acceptance remain unqualified.
Later phases require designs, detailed plans, required verification, and
independent review, without renewed routine human approval.
Advance automatically only after the preceding phase's required gates pass.
Version bumps, tags, releases, pushes, and deployments remain separately gated.

Phase 4 covers sealed Note-version attachment/citation sets, atomic Note Save
and conflict/merge source semantics, authenticated tags/relationships/backlinks,
ordinary Markdown citation rendering, narrow runtime grants, and necessary
derived-seal V1/V2 restore compatibility. Necessary repairs follow the continuous
development authorization below rather than an obsolete per-file permission
list. It does not enable V3 backup, new browser features or production activation.

Phase 5 covers portable Markdown, retained originals, extracted text and a
non-secret manifest, complete logical V3 history, V1/V2/V3 restore with source
integrity and search reconstruction, and a reproducible historical `0.1.0`
upgrade. It adds no browser features or production activation.
New backups use logical V3 after combined writer and restore qualification.
Explicit V2 retains its fail-closed unsupported-canonical guard.
The default transition follows
`docs/superpowers/specs/2026-10-18-singularity-v0.2-phase-5-task12-default-v3-design.md` and
`docs/superpowers/plans/2026-10-18-singularity-v0.2-phase-5-task12-default-v3.md`.
Task12's tested/reviewed local source is `4d832e91a5cf093ecd081be7b4fd515426b21f7d`;
see `docs/verification/2026-10-18-phase-5-task12-handoff.md` for its actual
gates and documentation-closure boundary.
Task11's local documentation handoff is `e24b2b2b10f4bb2d21d7600ad8bdc2f931237d56`;
see `docs/verification/2026-10-18-phase-5-task11-handoff.md` for its source/gates.

The 2026-10-10 approved Phase 3 amendment permits explicit per-application
database `pg_trgm` provisioning/hardening through the existing external
administrator connection, plus its fresh/historical test lifecycle hooks and
operator instructions. Final search grants and projection DDL remain forward
migrations. No administrator repository, runtime credentials, role-attribute or
membership change, extension-function ownership transfer, or Vault change is
authorized by this exception.

New canonical writes remain unavailable to production runtime roles.
Public import, extraction workers, search, Note Save integration, backup V3,
and browser behavior remain in their designated later phases.

Phase 2 must provide original-byte retention and abandoned extraction recovery
before public import. Phase 4 must seal Note source-set membership before enabling
its writes. Production activation requires a fail-closed backup guard for
unsupported canonical rows or complete V3 support.

Phase 1 source acceptance covers only the bounded authenticated storage digest
primitive, source-proof contract, source revalidation, and isolated contract tests.
Live runtime custody composition requires a separately approved Phase 2 design.
No custody, key, capability, or Vault change is authorized.
Test doubles do not prove live source verification.

## Continuous development authorization — 2026-10-10

The user grants continuing authorization for the existing Singularity `0.2.0`
product goal. This supersedes older routine per-step, per-file, and per-phase
human approval requirements in repository instructions, designs, and plans,
including the older global PRD rules that stopped at a file-scope boundary or
an out-of-scope test failure. Necessary goal-serving repairs are authorized;
unrelated feature work and cleanup are not.
Historical approvals and verification results remain historical evidence.

- Automatically choose the recommended in-scope approach and complete design,
  detailed planning, implementation, necessary repairs, documentation, tests,
  independent review, and small local commits without asking for `approve`.
- After a phase passes its required verification and independent review,
  automatically prepare the next phase's design and plan and execute it in a
  separate project-local worktree and branch. Do not bypass phase dependencies.
- Necessary compatibility fixes, test-contract updates, documentation
  synchronization, and additive forward migrations are authorized within the
  product goal. Amend the design and plan, record the reason and evidence, and
  obtain independent review; an old file allowlist is not a reason to stop.
- Characterize test failures and enter diagnosis and repair. Use Sol by default;
  escalate to Astra after two failed Sol repair rounds or an evidenced technical
  impasse. Astra may also handle architecture design. Allow at least three
  bounded, evidence-driven Astra repair attempts if needed, unless the issue is
  resolved or a genuine external blocker or preserved restriction prevents
  further work. Keep cumulative repair counts distinct from advisory/design
  attempts. Never weaken assertions, skip a
  required check, or declare a failed or unrun gate successful.
- This authority does not expand product scope or relax Vault freeze,
  immutable provenance, backup compatibility, or production-data protections.
  It does not authorize merge, push, version bump, tag, release, deployment,
  production activation, or production backfill.
- E2E remains manual-only and must not be run under the current user restriction.
  On 2026-10-10 the user explicitly deferred E2E for local development and phase
  advancement. All other required checks and independent review must pass.
  E2E stays NOT RUN and final browser/release acceptance remains required.
- Stop and request direction only for genuinely new external permission, a
  product decision only the user can make, or an external blocker that cannot
  be resolved within this authority. Continue independent valid work when safe.

## Vault freeze

Vault is frozen compatibility substrate for `0.2.0`, not an active product
module or release deliverable.

- Do not add, redesign, clean up, remove, migrate, or make Vault optional.
- Do not change Vault unlock, locking, keys, passwords, recovery,
  capabilities, administration, policies, commands, telemetry, tests, or UX.
- Do not investigate or repair unrelated Vault issues.
- Existing `vault_id` columns and adapter plumbing may remain only as opaque
  legacy owner-scope encoding required by current persistence.
- New knowledge APIs derive owner scope from authenticated runtime context and
  never accept a caller-selected Vault scope.
- A Vault-related file may change only for the smallest compile-preserving
  compatibility patch required by approved knowledge work, and that patch
  must be reported explicitly.
- Removing or replacing legacy Vault infrastructure requires a separately
  approved migration project.

### Authorized export-request lease exception — 2026-10-19

The user explicitly approved one minimal exception to this freeze: ownership
and cleanup of native Asset and Document **export request** leases in
`KeyCustodian` and `DownloadLease`. The governing amendment is
`docs/superpowers/specs/2026-10-19-singularity-v0.2-phase-5-export-lease-ownership-design.md`
and its detailed plan is
`docs/superpowers/plans/2026-10-19-singularity-v0.2-phase-5-export-lease-ownership.md`.
This exception supersedes conflicting compile-only/frozen-interface rules
only for that lifecycle seam and its focused export tests and exact attribution.

- Bind cleanup authority before a lease can become usable, including delayed
  issuance after acquisition timeout and operation-owner death before the lease
  identifier is returned or recorded. Neither strict cleanup assertion is waived.
- Keep existing authenticated source, session/principal, owner scope, unlock,
  capability and authorization-epoch checks. Add no new capability or caller-
  selected authority. Do not use whole-session/principal/Vault revocation as
  export cleanup.
- Preserve ordinary Asset download, ordinary Document request, extraction-worker,
  key/crypto and all other Vault behavior. No unrelated frozen-source or frozen-
  test repair is included. Native export-only regressions are required.
- Preserve the original 56-file manifest unchanged. The two authorized source
  deltas require exact reviewed inverse attribution to their original hashes;
  the other 54 entries must remain byte-identical. Do not regenerate or weaken
  historical baselines.
- Design, detailed planning, test-first implementation, independent SPEC then
  fresh QUALITY review and small local commits follow continuing authority.
  E2E, publication/deployment and production-data restrictions remain unchanged.

The native prerequisite has qualified local source acceptance at
`6c7f867309470e23e8f34c06a8f53af0b496d48d`; see
`docs/verification/2026-10-19-phase-5-export-lease-ownership-handoff.md`.
Resume original Task16 using `KeyCustodian.export_lease/2` only in its companion
adapter. Native component acceptance does not accept Task16's artifact/startup
composition, either end-to-end ALL-leases assertion, Task17 or Phase5.

Task16's one-way orchestration seam and exact P5-A2 formatter reconciliation
follow
`docs/superpowers/specs/2026-10-19-singularity-v0.2-phase-5-export-acyclic-composition-design.md`
and
`docs/superpowers/plans/2026-10-19-singularity-v0.2-phase-5-export-acyclic-composition.md`.
The fixed internal generation closure is not caller/configuration-selected;
all original ownership, native cleanup, startup and zero-cycle gates remain.

The active invariant is:

> Every user-owned object belongs to an authenticated owner scope, and every
> projection points to an immutable source version.

## Active exclusions

Qdrant is out of scope for `0.2.0`.

Embeddings, vector or hybrid retrieval, reranking, RAG, LLM or Agent
execution, OCR, Office formats, autosave, WYSIWYG editing, CRDTs,
collaboration, synchronization, sharing, media domains, finance, health,
external connectors, ESS/S3 redesign, Activity expansion, and Settings
expansion are also out of scope.

## Architectural boundaries

- PostgreSQL is canonical for structured knowledge records.
- Original binary bytes remain in the established Asset storage path.
- Search rows are rebuildable projections, never canonical records.
- Every search result and citation resolves to an immutable source version.
- `singularity_web` calls only `Singularity.Runtime.Api`.
- Domain code does not acquire Ecto, Phoenix, filesystem, shell, PostgreSQL,
  or React concerns.
- External extraction stays outside long PostgreSQL transactions.
- Imports, jobs, and projection rebuilds are idempotent.
- User content stays out of logs, telemetry metadata, exceptions, outbox
  payloads, job arguments, and audit metadata.

## Phase and verification protocol

- Characterize established behavior before changing it.
- Add a failing focused contract before changing enforced behavior.
- Never edit a released migration.
- Never weaken, skip, delete, or reclassify a required assertion.
- Run focused checks during a phase and the complete permitted README verification
  gate before local development acceptance. The user's explicit E2E deferral
  permits phase advancement after all other required checks and independent review
  pass. A failing executed gate still blocks acceptance and advancement; E2E stays
  NOT RUN and required for final browser/release acceptance.
- Preserve the seven-application dependency graph and require zero xref
  cycles.
- Record commits, changed files, migrations, tests, exact commands and
  results, remaining risks, and confirmation that no Vault feature work
  occurred.

### Historical Phase 0 blocker repairs

The following approved repair scope records the accepted Phase 0 boundary;
its Phase 1 prohibition and routine approval gates are historical and do not
override the active release scope or continuous development authorization.

- `docs/superpowers/specs/2026-09-01-singularity-v0.2-phase-0-blocker-repair-design.md`

The only classification repair makes
`resource_versions_resource_classification_fkey` deferrable and initially
deferred through a new forward migration.

The only wake repair moves application-owned wake generation counters from
Oban metadata to `jobs.job_submissions` and raises the supported Oban floor to
2.24.

At that historical boundary, no other Phase 0 production-code,
production-behavior, or schema change was authorized, and Phase 1 had not yet
been authorized. Current local development follows the authorization above;
publication and deployment restrictions remain in force.

## Stop conditions

Do not accept or advance a failing or incompletely verified phase. Diagnose and
repair ordinary failures within the continuous authorization; design and review
necessary forward migrations instead of waiting for routine approval.

Stop the affected work and report evidence only when proceeding requires new
external permission, a user-only product decision, or an irreducible external
blocker. This includes required remote/workflow state that remains unverifiable,
a blocking dependency defect in a configured internal organization, or an
outcome that cannot be achieved without changing the frozen Vault/product scope
or violating immutable provenance, backup compatibility, or production-data
protections. Unverified release-source identity blocks publication, not unrelated
local work. Do not cross those boundaries to make a gate green.

Follow the repository upstream-issue routing policy. Do not hide a dependency
defect behind an unapproved local workaround. Independent work may continue
only when it remains valid and does not evade the blocker.
