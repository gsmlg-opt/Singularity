# Notes scope contract alignment — 2026-10-08

Scope: the additional stale roadmap assertions in
`apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs`.
The owner explicitly approved extending the repair on 2026-10-08. This is not
Phase 2 acceptance or release readiness.

Hosted Tests at source `e866990fc0ee8682d139d70da9cbf5aff9b2ae2b` failed this
single web assertion: [run 37761897150](https://github.com/gsmlg-opt/Singularity/actions/runs/37761897150).
Hosted CI passed for the same source. The test still required accepted Phase 0
and active Phase 1, while approved guidance named accepted Phase 1 and active
Phase 2. Other reported application test suites had zero failures; integration
was excluded and this does not establish their acceptance gates.

The repair changes only the stale roadmap block: accepted Phase 1 SHA, active
Phase 2, exact approved design/plan links, later-phase approvals, and separate
publication gates. Every existing Vault freeze, ADR, owner/provenance, privacy,
exclusion, historical repair, and Markdown assertion remains intact. No
production, migration, dependency, workflow, version, or Vault change occurred.

Commands ran in `.trees/v0.2-phase-2-import-extraction` with the existing main
dependency cache and the worktree-local build:

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_domains/test/singularity/domains/knowledge_ports_test.exs apps/singularity_domains/test/singularity/domains/documents_test.exs
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix format --check-formatted apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs
git diff --check
```

Red: 12 tests, one expected failure, seed `518595`, exit 2. Worker green: 32
tests, zero failures, seed `789533`, exit 0. Parent repetition: six domain and
26 web tests, zero failures, seed `225257`, exit 0. Formatting and whitespace
checks passed. Independent specification and quality reviews both approved.
After committing the approval documentation at `2b037f1`, the parent repeated
the same four-file focused command: 32 tests, zero failures, seed `536492`,
exit 0.

No assertion was skipped, weakened, deleted, or reclassified. A subsequent
parent full unit run completed successfully with seed `710289`:

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test
```

All seven application suites reported zero failures: core 10 properties and
111 tests; domains 38 tests; storage 831 tests (570 integration tests excluded);
retrieval 26 tests; ingest 54 tests; runtime 576 tests (95 integration tests
excluded); and web 182 tests. Exit status was 0. Existing Fake.Authorization,
Fake.Clock, and Fake.KeyReader module-redefinition warnings remain outside this
repair. No integration, restore, frontend, browser E2E, container, release, or
deployment check ran in this repair. Hosted verification of a future pushed
repair revision remains required. The worker bridge has separate approved
scope and still needs implementation and actual-role evidence. No Vault feature
work or compatibility patch occurred.
