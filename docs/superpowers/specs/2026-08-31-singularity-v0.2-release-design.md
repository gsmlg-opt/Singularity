# Singularity v0.2.0 Release Design

**Status:** Approved

**Date:** 2026-08-31

**Authoritative release directive:**
`docs/superpowers/plans/2026-08-31-singularity-v0.2-release.md`

## 1. Purpose

Singularity `0.2.0` is the first complete personal knowledge-base release.
The release extends the established Assets and immutable Markdown Notes
foundation with Documents, provenance-preserving extraction, unified lexical
search, source-pinned knowledge links, portable export, complete logical
backup and restore, and one coherent browser workflow.

This design approves the release direction and defines how development starts.
It does not approve a version bump, tag, publication, deployment, or Phase 1
implementation. Work begins with Phase 0: make the active scope unambiguous,
establish a verified baseline, and prepare a detailed execution plan.

## 2. Verified starting state

The supplied release directive reviewed `main` at the `v0.1.0` commit
`c49dc0aeda1d0115b20ff291f0da658f7e558b43`. At approval time, local `main`
and the locally recorded `origin/main` both point to
`5151febde7d94c92877f7a49525e0e2add5b2faf`. The intervening change is limited
to corrections in an existing implementation-plan document; it does not
change application or release behavior.

The repository already contains the seven-application Elixir umbrella,
PostgreSQL canonical storage, encrypted Asset storage, immutable Markdown
Notes, Note lexical search, Outbox and Oban processing, the Runtime API
boundary, Phoenix LiveView with React App Clips, logical backup versions 1 and
2, and multi-architecture container release tooling. These are foundations to
characterize and preserve.

Live GitHub release and workflow queries timed out during design review. Phase
0 therefore treats remote branch, tag, release, and required-workflow state as
unverified until it can refresh them successfully. Stale remote observations
must not be used as release evidence.

## 3. Product and architecture decision

The authoritative release directive governs the full `0.2.0` outcome, scope,
architecture, phase order, verification gates, stop conditions, and definition
of done. Detailed implementation decisions are made one phase at a time. No
single branch or pull request may attempt the whole release.

The fixed architectural boundaries are:

- PostgreSQL remains canonical for structured knowledge records.
- Original Document bytes remain in the established Asset storage path.
- Canonical resources, immutable versions, fragments, attachments, citations,
  tags, and relationships are distinct from rebuildable search projections.
- Every search result and citation resolves to an exact immutable source
  version.
- `singularity_web` calls only `Singularity.Runtime.Api`.
- Pure domain modules do not acquire Ecto, Phoenix, filesystem, shell,
  PostgreSQL, or React concerns.
- External extraction runs outside long PostgreSQL transactions.
- Retried imports, jobs, and projection rebuilds remain idempotent.
- User content does not enter logs, telemetry metadata, exceptions, outbox
  payloads, job arguments, or audit metadata.

## 4. Vault compatibility boundary

Vault is frozen compatibility substrate for `0.2.0`, not an active product
module or release deliverable.

Phase 0 must establish the following active guidance:

- no Vault feature, redesign, cleanup, removal, migration, UX, command,
  policy, telemetry, or acceptance work;
- existing `vault_id` persistence and adapter plumbing remain opaque legacy
  owner-scope encoding where current infrastructure requires them;
- new knowledge APIs derive owner scope from authenticated runtime context and
  never accept a new caller-selected Vault scope;
- unavoidable Vault-file changes are restricted to the smallest
  compile-preserving compatibility patch and are reported explicitly;
- replacing legacy Vault infrastructure requires a separately approved
  migration project.

The active invariant becomes:

> Every user-owned object belongs to an authenticated owner scope, and every
> projection points to an immutable source version.

Historical specifications remain historical records and are not rewritten to
erase earlier Vault decisions.

## 5. Phase 0 deliverables

Phase 0 is a documentation, governance, characterization, and baseline slice.
It will:

1. record the refreshed local and live remote starting state;
2. add root `AGENTS.md` with the Vault freeze, active `0.2.0` scope, phase
   boundaries, verification rules, and stop conditions;
3. add `docs/adr/0003-vault-frozen-for-knowledge-base-development.md`;
4. retain this approved release design and the canonical master release plan;
5. update only active guidance in `README.md` and `docs/guide.md`, including
   the roadmap and ownership/projection invariant;
6. preserve historical implementation documents without retrospective edits;
7. reconcile the documented complete verification sequence with existing
   CI/Test workflow contract coverage;
8. run the complete repository verification sequence from an isolated,
   clean worktree; and
9. obtain independent review before Phase 0 is accepted.

The master release directive is canonicalized by moving the supplied untracked
document to
`docs/superpowers/plans/2026-08-31-singularity-v0.2-release.md`. Its pre-move
and immediate post-move SHA-256 was
`28efc53ec4ec70b473f464a78b5004c6a61d80b308e4f8b98bd1c46591230fc2`;
the required Phase 0 baseline addendum was then applied to the canonical file.
No duplicate source of truth is retained.

## 6. Verification reconciliation

The complete local gate is the command sequence in the authoritative release
directive. It covers PostgreSQL lifecycle and role bootstrap, dependency and
format checks, warnings-as-errors compilation, unit tests, isolated database
integration tests, restore acceptance, frozen JavaScript dependencies,
JavaScript checks and tests, production asset build, Playwright acceptance,
zero dependency cycles, workflow linting, diff validation, and final working
tree state.

Phase 0 may update active verification documentation and focused workflow
contract tests when they disagree with the established CI and Tests workflows.
It must not pull Phase 7 work forward: exact-SHA release gating, reviewed
all-application version bumps, branch protection, release notes, image
extraction smoke tests, tags, and publication remain Phase 7 deliverables.

Focused checks may support diagnosis but never replace the complete Phase 0
gate.

## 7. Failure and escalation policy

Baseline failures are characterized and reported before any repair. This
approved Phase 0 design permits documentation, test-contract, and workflow-
contract corrections only; those corrections must preserve existing
assertions and production behavior. A production-code or production-behavior
repair requires an explicit design amendment and user approval before work
begins, even when the failure blocks knowledge-base development.

The phase stops and reports evidence when a repair would require any of the
following:

- new or changed Vault semantics;
- an unapproved schema or product migration;
- broad cleanup or an unrelated feature;
- weakened, deleted, bypassed, or reclassified verification;
- a local workaround for a blocking dependency issue in an upstream
  `gsmlg-*`, `duskmoon-dev`, or other configured internal organization; or
- release publication without proof that the exact required revision passed
  its gates.

Dependency issues follow the repository's upstream issue-routing policy. A
blocker stops the affected work; a needed or nice-to-have workaround must be
linked and explicitly marked.

Independent unblocked work may continue only when it does not weaken or evade
the failed gate.

## 8. Branching and review

Phase 0 implementation uses branch
`codex/v0.2-phase-0-scope-baseline` in the project-local worktree
`.trees/v0.2-phase-0-scope-baseline`. Later phases use separate worktrees and
branches created only after the preceding phase is accepted.

Established behavior is characterized before modification. Each behavioral
change follows a failing-test, minimal-implementation, passing-test cycle.
Documentation-only assertions use focused contract tests where automated
enforcement is valuable.

Independent review must address every Critical and Important finding before
the phase is accepted. The Phase 0 report records commits, files changed,
migrations, tests, exact commands and results, remaining risks, remote-state
evidence, and confirmation that no Vault feature work occurred.

## 9. Phase 0 acceptance

Phase 0 is complete only when:

- the worktree is clean;
- root `AGENTS.md`, ADR 0003, the approved design, the canonical release plan,
  and corrected active guidance are present and mutually consistent;
- local and live remote baseline evidence is recorded;
- characterization evidence records the established Notes, Assets, backup,
  release, Runtime API, and application-boundary behavior that later phases
  must preserve;
- every currently supported complete verification check passes;
- active guidance cannot reasonably be read as directing new Vault work;
- no production code, production behavior, or Vault functionality changed;
- no application version was bumped and no tag, release, or deployment was
  created; and
- Phase 1 has not started.

After acceptance, Phase 1 receives its own design and detailed implementation
plan for the canonical Document and knowledge-link model.
