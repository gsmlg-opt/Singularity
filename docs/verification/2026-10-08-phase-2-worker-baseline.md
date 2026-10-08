# Phase 2 worker baseline — 2026-10-08

Source: `cbdd909` on `codex/v0.2-phase-2-import-extraction`, before worker-bridge
production changes. Approval and planning documentation had uncommitted changes.
This record is not phase acceptance or release readiness.

The local worktree PostgreSQL service was started with `devenv up -d` and
reported ready with zero restarts. `devenv shell -- pg_isready` accepted
connections. Local test roles were provisioned successfully with:

```sh
devenv shell -- bash apps/singularity_storage/priv/repo/bootstrap_roles.sh
```

The focused disposable-database integration baseline was:

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs apps/singularity_storage/test/singularity/storage/document_lifecycle_test.exs
```

Seed `207950`, exit 2. Storage: 19 tests, one failure. Runtime: three tests,
zero failures, two nonintegration tests excluded. The lifecycle failure at line
206 expects pending generation 1 after resetting a failed attempt, but receives
2. The later forward migration
`20260922000300_document_runtime_mutations.exs` replaces reset with a generation
increment. The existing test also expects the next claim to use revision 1.
No lifecycle test, assertion, or production behavior was changed to hide this
failure. The test is outside the narrow worker-bridge amendment's file boundary;
affected acceptance is stopped under the repository scope rule. Independent
source-restart architecture work does not depend on changing this assertion.

Postgrex also reported existing fixed-text deferred fragment constraint errors
from adversarial lifecycle cases. They contained no source content. These do
not change the failing assertion above or establish new bridge privacy evidence.

An initial command incorrectly used
`apps/singularity_storage/test/singularity/storage/postgres/document_lifecycle_test.exs`.
The integration alias returned exit 0 despite reporting that this path did not
exist. Only the runtime integration case ran (seed `570037`, three tests, zero
failures, two excluded). That command is not evidence for storage. The corrected
command above ran the actual file and exposed the failure.

The separate full unit run passed, as recorded in
[the Notes scope repair evidence](2026-10-08-notes-scope-contract-alignment.md).
Unit success does not cover the excluded integration suite. No E2E, restore,
frontend, container, release, deployment, or remote publication ran. No Vault
feature work or compatibility patch occurred.
