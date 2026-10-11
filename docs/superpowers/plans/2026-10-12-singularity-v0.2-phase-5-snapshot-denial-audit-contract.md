# Task 13 snapshot denial/audit contract correction plan

Design:
`docs/superpowers/specs/2026-10-12-singularity-v0.2-phase-5-snapshot-denial-audit-contract-design.md`.
Status: independently reviewed amendment implemented and verified; truthful
causal RED remains historical. Current Task13 implementation passes complete
pure114/SQL48/static and final actual independent SOURCE SPEC/fresh QUALITY on
receipt3d7de0cf. Local commit is next after normal separate Legacy70/0 closure;
Phase5 acceptance remains pending. Continuous authority does not waive review.

- [x] Independently review the design against actual Authorize,
  IdentityRepository/released live-session SQL, OperationScope, AuditSink,
  released audit RLS, ScopedRepo and the new Runtime SQL tests. Record actual
  source/spec findings; then obtain a distinct fresh quality review.
  Actual nonauthor SOURCE/SPEC: phase5_task9b_reference_contract_author PASS;
  distinct fresh QUALITY: phase5_task13_denial_contract_quality PASS.
  Parent-transcribed actual review records are retained under
  `.devenv/phase5-task13-denial-audit-amendment-{spec,quality}-review.md`.
- [x] Freeze production and other tests. Give the Task 13 test author sole
  ownership of the new Runtime SQL test file for this correction. Keep all
  twelve denial cases, the nine unaffected allowlist assertions and all
  cleanup/neighbor/transaction assertions and default timeouts.
- [x] Add test-local observers that delegate actual identity, audit insert and
  repository capture unchanged. No fake audit success, fabricated authority,
  role/policy change, hidden bypass or new production seam.
- [x] For the three affected cases, assert a successful real identity return,
  RR/off and actual Authorize's exact denial: unauthenticated for forged
  principal/owner, forbidden for revoked membership. Use the identical fixed
  capture requirements/session epochs and real custody.
- [x] In actual capture, assert denial audit action/result/empty metadata and
  attempted ID, real insert Postgrex 42501/insufficient_privilege, unchanged
  real AuditSink and capture storage_unavailable/retryable result, no persisted
  attempted event and no repository capture entry. Retain all cleanup checks.
- [x] Close author commands. Parent reads the complete changed source and
  inverse-checks unchanged test bodies. Parent alone formats, records a new
  immutable source receipt, then freezes all source/support for gates.
- [x] Run the complete five-file pure command below. Archive full output,
  require normal exit and actual counts, and verify source/frozen hashes.
- [x] Run the complete two-file SQL command below. Archive full output,
  require the three strengthened denial proofs to execute successfully, and
  retain all still-missing-Repository failures as RED. Record normal exit,
  exact counts, database/root cleanup and source/frozen hashes.
- [x] Only after truthful causal RED closes may the separate Task 13
  Repository authoring proceed. Require complete pure/SQL GREEN after that
  implementation; actual independent source/spec then fresh quality review
  precede any Task 13 acceptance/local commit.

## Complete pure gate

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/knowledge_export/spool_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_snapshot_test.exs apps/singularity_core/test/singularity/core/knowledge_export_test.exs apps/singularity_core/test/singularity/core/knowledge_export_manifest_test.exs apps/singularity_core/test/singularity/core/note_markdown_sources_test.exs --seed 215378 --warnings-as-errors
```

## Complete SQL gate

```sh
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/knowledge_export/repository_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_snapshot_test.exs --seed 215378 --warnings-as-errors
```

Use the existing private PostgreSQL fixture and the existing maintenance
database query for leftover `singularity_test_%` databases. Do not change
runtime configuration, dependencies, identities, locks, capabilities, policies,
grants, immutable migrations, or frozen substrate. Source commands and SQL
gates never overlap; independent reviewers are read-only.

E2E: NOT RUN/manual-only. Publications, deployment and production data are not
in this plan. A denied/audit-failed capture never constitutes a successful
capture or stage acceptance.
