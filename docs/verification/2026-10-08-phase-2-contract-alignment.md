# Phase 2 contract alignment verification — 2026-10-08

Scope: approved Phase 2 contract/governance alignment only, not Phase 2 or
`0.2.0` acceptance.

Worktree: `.trees/v0.2-phase-2-import-extraction`.
Branch: `codex/v0.2-phase-2-import-extraction`.
Baseline: `80cabbee8735158372ae3b4ac8f09a9cf400ad0d`.
Implementation: `6f4083048748901d8f1b536edd8a930b1668164d`
(`test(knowledge): align approved phase 2 contracts`).
Main and origin/main remained at the baseline during these checks.

## Reason and changes

The hosted Tests run for the baseline failed four stale Phase 1 contracts:
[run 37733561179](https://github.com/gsmlg-opt/Singularity/actions/runs/37733561179).
Approved Phase 2 work had changed the repository callbacks, active guidance,
and Document runtime interfaces without aligning those assertions.

The implementation changes only:

- `apps/singularity_domains/test/singularity/domains/knowledge_ports_test.exs`:
  exact approved callback inventory, arities, and operation-specific return types.
- `apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs`:
  current governance, bounded runtime registration, original legacy hashes,
  independently frozen approved additions, and adversarial guard tests.
- `README.md`: active Phase 2 paragraph and governing links.
- `docs/guide.md`: governing links, active roadmap paragraph, and current gate.

Original V1/V2 backup hashes and legacy runtime composition hashes remain
unchanged. Approved API additions are individually hashed before stripping;
application and queue additions require unique exact surrounding context.
Unapproved, changed, missing, duplicated, or relocated additions are rejected.
Browser Document routes remain absent. Activation prerequisites, Vault freeze,
separate publication gates, and the complete README gate remain intact.

No production code, migration, dependency, lockfile, workflow, version, or Vault
file changed. No Vault feature work or compatibility patch occurred.

## Reproduction and focused verification

Commands ran from the worktree. The existing main-checkout dependency cache was
used with a worktree-local build; no dependency installation or update occurred.
The first attempt without that cache stopped before tests because dependencies
were absent. `unbuffer` was unavailable; output was captured through devenv.

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_domains/test/singularity/domains/knowledge_ports_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs
```

Baseline seed `163479`: 1 domain test and 7 web tests, exactly 4 intended
failures, exit 2. After alignment: 12 tests, 0 failures, seed `226975`, exit 0.
An initial regex module-attribute compilation error was isolated and corrected
by keeping the unchanged regex/hash entries in a private function.

Independent quality review reproduced a placement bypass: moving the exact
queue line from Oban into Tailwind still satisfied the initial normalization.
Three valid-AST relocation tests were added before changing the guard.
Seed `66806`: all 3 new relocation assertions failed as intended, exit 2.
After placement-aware normalization, 20 scoped tests passed, seed `273671`.

Parent verification, including the existing domain Document contracts:

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_domains/test/singularity/domains/knowledge_ports_test.exs apps/singularity_domains/test/singularity/domains/documents_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix format --check-formatted apps/singularity_domains/test/singularity/domains/knowledge_ports_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix xref graph --format cycles --fail-above 0
git diff --check
git diff --cached --check
```

All exited 0. Final pre-commit tests: 6 domain and 14 web tests, zero failures,
seed `687749`. Post-implementation-commit repetition: 20 tests, zero failures,
seed `590375`. Integration-tagged tests were excluded. Xref reported
`No cycles found`; the seven-application graph was not changed.

Independent spec review approved the actual diff. Independent code-quality
re-review approved after the relocation fix. Neither review substitutes for
the complete acceptance gate.

## Remaining work and required architecture amendment

Task 12's live extraction worker is still missing. Its planned composition
cannot use the existing adapters under actual WorkerRepo privileges: those
adapters directly read canonical Document rows and hydrate full DocumentVersion
values, while the worker is deliberately denied those reads and raw lifecycle
EXECUTE. Temporary fixture grants do not prove production composition.

The read-only architecture review recommends a separate DocumentWorkerRepository
and a new forward migration exposing four worker-only security-definer entrypoints:
describe, claim/resume, complete, and fail. They would return bounded source
metadata and attempt/outcome receipts, never titles, fragments, keys, or source
bytes. Task 12's success result would become a typed worker receipt rather than
a fabricated full DocumentVersion. Public repository callbacks remain unchanged.

Each entrypoint must independently bind scoped identity, current authorization
epochs, the exact IDs-only durable event, source identity, and job/generation
fences. New claims require a live Document; matching unexpired already-claimed
work may resume and finish after deletion without resetting its deadline.
Existing Document leases remain the only plaintext path. Exhaustion uses the
same fenced fail entrypoint, not an extra SQL function. Canonical table reads
and raw lifecycle execution stay denied; no RequestRepo substitution or Vault
semantics change is allowed. Actual WorkerRepo tests without temporary grants
must prove ACLs, replay, expiry, recovery races, deletion, and sanitized failures.

This is an unapproved architecture recommendation, not implementation authority.
The forward migration, separate adapter, and receipt-return amendment require
explicit approval before Task 12 implementation proceeds. No such changes were
made in this repair.

No full unit suite, integration, restore, browser E2E, complete README gate,
container build, GitHub dispatch, version bump, tag, release, push, merge, or
deployment occurred in this repair. Hosted Tests remains failed at the old
baseline until separately authorized integration and fresh hosted verification.
The full release objective remains unfinished; no phase checklist was marked
complete or acceptance requirement waived.
