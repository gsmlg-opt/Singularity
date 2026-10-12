# Phase 5 Document worker-read contract correction plan

Status: DESIGN REVIEWED — actual SOURCE SPEC then distinct fresh QUALITY PASS;
test authoring is authorized, whole gates and source acceptance remain pending.
Reviewed draft SHA46f49b991f62ebe05e974cf3a081e2e2f424426469e2bf3cf63e3a6111645c5b.
Design: `../specs/2026-10-12-singularity-v0.2-phase-5-document-worker-read-contract-design.md`.
The parent owns formatter, all gates/services/SQL, factual records and Git.
The Task14 worker owns only the final DocumentCustodyPermissionTest module;
other source/test/support/migrations are frozen. Workers are not alone and
must preserve the existing Task9/14/15/Legacy edits.

- [x] Obtain actual independent design SOURCE SPEC followed by distinct fresh
  QUALITY. Record exact reviewed hashes and evidence; resolve findings.
- [x] Replace the one outdated permission case with all design acceptance
  assertions using real existing fixtures/ScopedRepo and PostgreSQL. No source
  change is permitted while any parent gate runs. Close authoring before gates.

The bounded test-authoring unit is CLOSED. Parent read the full final module
and delta. It retains the single default-timeout integration case, asserts
native grants/RLS and same/foreign/revoked scope, executes actual PostgreSQL
42501 mutation probes through unchanged SafeSQL inside independently rolled
back ScopedRepo transactions, checks row preservation and same-backend GUC
cleanup. Raw owning-file SHA37946344ab9ef2167c1a98ba26daf53cbb534c24b27bf2b9041c104ae305cb4a;
the preceding custody-module prefix remains exactly56daca6dc13501fe397c03d029079c62f11684fb725cd961dbfcd5169d018ccf.
Formatter and complete corrected pure/live gates remain pending; authoring
closure is not native permission or custody qualification.
- [ ] Parent reads complete changed module/delta, formats owning changed tests
  and freezes all authors. Run whole Task14 pure/live3 below; keep initial FAIL
  and distinguish missing new ExportRead wiring from actual old-case GREEN.
- [ ] Once ExportRead exists, run the same full owners GREEN, owning retained
  Task13 checks/static/frozen checks, actual NONAUTHOR SOURCE SPEC then distinct
  fresh QUALITY. Preserve every native byte-custody assertion. Commit only as
  part of the qualified bounded Task14 local handoff, no standalone acceptance.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_runtime/test/singularity/runtime/knowledge_export_read_test.exs apps/singularity_runtime/test/singularity/runtime/document_api_test.exs apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs --seed 215378 --warnings-as-errors
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_export_custody_live_test.exs apps/singularity_runtime/test/singularity/runtime/document_api_test.exs apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs --seed 215378 --warnings-as-errors
```

First observed permission failure is initial characterization, not a repair
round. Use Sol for the first bounded correction; escalate after two failed
same-defect rounds/evidenced impasse, preserving all required assertions.
E2E remains NOT RUN; frozen production/custody/Vault and publication limits
are unchanged. This correction does not qualify Phase5 or production V3.
