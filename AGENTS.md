# Singularity Repository Instructions

## Active release

The only active product release is Singularity `0.2.0`, the first complete
single-user personal knowledge base. Its governing documents are:

- `docs/superpowers/specs/2026-08-31-singularity-v0.2-release-design.md`
- `docs/superpowers/plans/2026-08-31-singularity-v0.2-release.md`

Work proceeds one accepted phase at a time in a separate project-local
worktree and branch. Phase 1 must not begin until Phase 0 is accepted and
Phase 1 has its own approved design and detailed implementation plan.

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
- Run focused checks during a phase and the complete README verification gate
  before accepting the phase.
- Preserve the seven-application dependency graph and require zero xref
  cycles.
- Record commits, changed files, migrations, tests, exact commands and
  results, remaining risks, and confirmation that no Vault feature work
  occurred.

Phase 0 permits documentation, test-contract, and workflow-contract
corrections only. It does not authorize production-code or
production-behavior changes, version bumps, tags, releases, pushes,
deployments, or Phase 1 work.

## Stop conditions

Stop the affected work and report evidence when:

- live remote identity or required workflow state cannot be verified;
- a complete required gate fails;
- work would change Vault semantics or require an unapproved migration;
- an additive implementation cannot preserve immutable source provenance;
- backup compatibility would break;
- release automation cannot prove the exact tested source; or
- a dependency issue in a configured internal organization blocks the task.

Follow the repository upstream-issue routing policy. Do not hide a dependency
defect behind an unapproved local workaround. Independent work may continue
only when it remains valid and does not evade the blocker.
