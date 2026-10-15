# Task9 B–F storage-reference and Document-integrity compatibility

## Current verdict

All required parent-executed native B–F checks are CLOSED PASS.
Combined actual NONAUTHOR SOURCE SPEC and distinct fresh SOURCE QUALITY are
also CLOSED PASS, no P1/P2. The bounded B–F component is locally committed at
`5619eccdbc2256c4c5aa702b653038fa57ada6fe`, exactly26 reviewed paths. It does not accept
Task10/11, Phase5 or any release.

Worktree: `.trees/v0.2-phase-5-export-backup`.
Branch: `codex/v0.2-phase-5-export-backup`.
Reviewed precommit HEAD: `9f91c97eb392b4c49c888ed31795d520d15bb8dd`.
Bounded local handoff HEAD: `5619eccdbc2256c4c5aa702b653038fa57ada6fe`.
Previous `4e2499d5b89664c3e7b63cb1f3136c243b276c83` remains unchanged
apart from the separately reviewed Task8 attribution test/report commit.
Main, other worktrees, unrelated files and the index are preserved.

## Governing contract and exact bounded source

This follows the compatibility design and plan at
`docs/superpowers/specs/2026-10-12-singularity-v0.2-phase-5-storage-reference-compatibility-design.md`
and
`docs/superpowers/plans/2026-10-12-singularity-v0.2-phase-5-storage-reference-compatibility.md`,
Tasks B–F, and accepted admission-fixture-lifecycle,
backup-reader-grant-contract and document-worker-read-contract amendments.
Earlier characterization, causal RED, failed diagnostics and successful bounded
repairs remain historical evidence in the main Phase5 acceptance report.

Only established UUID persisted references or the established canonical
content-addressed path are accepted, consistently in preflight and SQL.
Forward migration `20261011000700` replaces exactly one unique fixed
storage-reference predicate in the current finalizer function. Other body,
owner, security mode, search path and ACLs remain unchanged; a missing/duplicate
predicate fails closed. No released migration is edited.

The original nine-field authenticated inventory remains canonical. Its V3
projection/binding is used only at the native integrity seam; original persisted
references are revalidated in the same fresh repeatable-read MigrationRepo
snapshot before the unchanged material loader. Typed summaries, issuer, lease
material, crypto, keys, binding, owner PID, revocation and completion authority
remain unchanged.

V3 Runtime integrity validates the authenticated logical version, rejects
unsupported versions before content access, requires the Document callback,
validates exact plaintext hash shapes, then passes ORIGINAL inventory and
validated native plaintext evidence to the unfrozen KnowledgeIntegrityAudit
facade. V1/V2/no-version behavior remains. Complete historical Document source
pins and ready fragments use bounded ordered streaming, independent size proof
and Core fragment validation. Base integrity audit is unchanged.

The separately reviewed disposable fault witness disables only the named
immutable guard after genuine import COMMIT. Every other guard/RLS/policy/ACL
stays active. It proves rollback/restoration, actual corruption COMMIT, ordinary
denial and aggregate mismatch in the helper's OWN fresh transaction. Denial
prevents rebuild/completion and leaves the destination unpublished; it is NOT
rollback of an already committed import/rewrap.

Exactly fourteen application/test/migration files form this bounded implementation:

| File | SHA-256 at native gates |
| --- | --- |
| `apps/singularity_runtime/lib/singularity/runtime/integrity_audit.ex` | `6a109eb19a3cdf0eb393d4505f14965638d9d31edc9778d25b2343fab54f9fa3` |
| `apps/singularity_runtime/test/singularity/runtime/integrity_audit_test.exs` | `0b9afd8b21d0e9ab4431f75c7061ec34c01561b5a54890971cd5a6c46f8f31e8` |
| `apps/singularity_storage/lib/singularity/storage/backup/knowledge_preflight.ex` | `77e8116d85e2133fb7a62c36adf2dfba89276c77fb7747f1ba38663a9d8539ad` |
| `apps/singularity_storage/lib/singularity/storage/backup/restorer.ex` | `b23f8409adf95d95bf55966ffdb8dad51e02ee4a6481b85d69e2f3c817559b78` |
| `apps/singularity_storage/lib/singularity/storage/backup/knowledge_integrity_inventory.ex` | `e8b4d49fbf240898cc48f7fd6ca97293213c2ca3a917eae00554c6f3772e3e80` |
| `apps/singularity_storage/lib/singularity/storage/backup/knowledge_integrity_audit.ex` | `89ebf162b842a24972812cf845fb673e22215cbfef3720e054d1d7f0f5d0e12c` |
| `apps/singularity_storage/priv/repo/migrations/20261011000700_knowledge_restore_storage_references.exs` | `9422e8695bf465f1441fc3cd795d05d6b2f6aa038ab58c53ac5d00b4a1965d0c` |
| `apps/singularity_storage/test/singularity/storage/backup/knowledge_preflight_test.exs` | `7024a8c6472eff25d995acd36515aecf638ccd362f4ba75dba06af610e7ad31c` |
| `apps/singularity_storage/test/singularity/storage/backup/knowledge_restore_admission_test.exs` | `43b4c144730fe3616d11c04375d217a43670da957de107acf00dcd47eac82d82` |
| `apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs` | `2f3d6bfc0c90581e68c0af04b11c92063ec90c829d098ff4af7066a88f6ff84b` |
| `apps/singularity_storage/test/singularity/storage/backup/document_restore_integrity_test.exs` | `01334f2e0b6fe30a5bcc65fc968e507675dd827259c8fb5e525d4cf7f50df82e` |
| `apps/singularity_storage/test/singularity/storage/backup/knowledge_integrity_inventory_test.exs` | `a2044e65f05d97e703acd983dd06dd7ebf2c7d37e48688c3716376be70a7a715` |
| `apps/singularity_storage/test/singularity/storage/knowledge_grants_test.exs` | `efd5c7c819d47be4f35b081aab245172d10b688f7a18aae91cea9605cb9512be` |
| `apps/singularity_storage/test/singularity/storage/knowledge_rls_test.exs` | `e24dcace89448098c8af35462e880e02b39dc47dfbc278de99324bd9a3acfd5c` |

The ignored manifest is `.devenv/phase5-task9f-native-source14.sha256`.
Current E corrected source18, protected native5 and original frozen56 were
rechecked after the required gates: all 79 entries OK. Original manifests were
never regenerated; source14 does not supersede them.

Task13 capture, Task14 existing request-custody read and Task15 portable writer
remain locally committed at `09f8ee0`, `444e460` and `4e2499d`.
This is not new live publication acceptance. Task8 attribution is locally
accepted at `9f91c97`; its dedicated report records complete 51-test GREEN,
causal RED and original-byte inverse. No Task16/17 GO follows.

## Corrected whole E source review and native ownership

Direct NONAUTHOR whole corrected E SOURCE SPEC
`/root/phase5_task16_atomic_startup_design_spec`: CLOSED PASS, no P1/P2.
Distinct fresh NONAUTHOR whole E SOURCE QUALITY
`/root/phase5_task9e_constraint_timing_fresh_quality`: CLOSED PASS, no P1/P2.
Both read complete eight assigned files, frozen native seams and full outputs,
independently recovered previous source/test bytes and confirmed entry equals
closure hashes. Read-only reviewer commands closed; no native reviewer gate.

Parent captures:

- `.devenv/phase5-task9e-corrected-implementation-source-spec-review.md`,
  SHA-256 `d20a0c747507ced4c87953d5da7adaf74d2e7ad313d8d81fc5355d63a3cac884`.
- `.devenv/phase5-task9e-corrected-implementation-source-fresh-quality-review.md`,
  SHA-256 `1aa0353233be47008a4f03b3aad04e0127c35779886bc3d67a345b15e2aedd6a`.

Same complete five E pure owners: 88 actual, zero failures, 45 SQL excluded.
Same complete four E SQL owners: 45 actual, zero failures, 25 pure excluded
from 70 reported; all 35 retained and 10 new tests pass. Positive import,
fault/rollback, exact restoration, native old-ready corruption and OWN fresh
helper denial were reached. Allocation root `71b441243a29932ce9322aae`
was absent; normal maintenance EMPTY. Static format/compile/xref passed.
Earlier PG55006 SQL and independent SPEC FAIL remain failures; the narrowly
reviewed timing-fixture correction resolved them in complete owning reruns.

## Retained F exact commands and actual results

The parent ran every whole owner without line filters, serially, with no author
editing during native gates. Historical totals were not assumed as new results.

### Retained whole16 SQL

```sh
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/logical_v3_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_preflight_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_restore_admission_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_restore_digest_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_backup_fixtures_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_schema_ddl_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_historical_admission_test.exs apps/singularity_storage/test/singularity/storage/document_lifecycle_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_link_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_asset_lifecycle_guards_test.exs apps/singularity_storage/test/singularity/storage/note_source_set_sealing_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_sources_test.exs apps/singularity_storage/test/singularity/storage/knowledge_rls_test.exs apps/singularity_storage/test/singularity/storage/knowledge_grants_test.exs apps/singularity_storage/test/singularity/storage/knowledge_schema_test.exs --seed 215378 --warnings-as-errors
```

Actual: 344 actual; 0 failures; 3 excluded from 347; exit 0.

### Legacy pure whole2

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs --seed 215378 --warnings-as-errors
```

Actual: 5 actual; 0 failures; 9 integration exclusions from 14; exit 0.

### Downstream pure whole10

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/backup/logical_schema_v3_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_record_codec_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_bundle_verifier_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs apps/singularity_core/test/singularity/core/knowledge_export_test.exs apps/singularity_core/test/singularity/core/knowledge_export_manifest_test.exs apps/singularity_core/test/singularity/core/note_markdown_sources_test.exs apps/singularity_runtime/test/singularity/runtime/note_markdown_source_export_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs --seed 215378 --warnings-as-errors
```

Actual: Core72 + Storage51 + Runtime26 + Web54 = 203 actual; 0 failures; exit 0.

### Separate Task8 SQL whole3

```sh
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/logical_v3_exporter_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs apps/singularity_storage/test/singularity/storage/task14_backup_identity_export_security_test.exs --seed 215378 --warnings-as-errors
```

Actual: 78 actual; 0 failures; no exclusions reported; exit 0.

### Separate Task8 pure whole3

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_runtime/test/singularity/runtime/application_test.exs apps/singularity_runtime/test/singularity/runtime/backup_vault_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs --seed 215378 --warnings-as-errors
```

Actual: Storage2 + Runtime48 = 50 actual; 0 failures; no exclusions reported; exit 0.

### Complete static

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format --check-formatted, compile --warnings-as-errors, xref graph --format cycles --fail-above 0
```

Actual: Format check, warnings-as-errors compile and zero xref cycles; exit 0.

## Full output archives and normal cleanup

| Archive under `.devenv/` | SHA-256 |
| --- | --- |
| `phase5-task9f-retained-whole16-sql.log` | `d8c2a82c440d451e88483b1343b3881f171312cc9037f83ae7c23b9440849a9f` |
| `phase5-task9f-retained-whole16-cleanup.log` | `ad06c41a5490976e9f0244173b1c07af9558e3b074f0acf58b566fcb86191801` |
| `phase5-task9f-retained-legacy-pure.log` | `b122c834f66d2c9d1b8633b9ed85255da665644bac2702b60d968c34c071eec6` |
| `phase5-task9f-retained-downstream-pure.log` | `8ce7b1ce6be689ddc283959d75387aef1101b71edeb0c637f6633a095b9259f4` |
| `phase5-task9f-separate-task8-whole-sql.log` | `59a776d66225f878452f6064dad0901860393a236c2e2c757c40a8af04ee6ceb` |
| `phase5-task9f-separate-task8-whole-sql-cleanup.log` | `7e2a1a6ce00acbe02227a295baa8e0b1bcc27addd412997c03aff6227821f491` |
| `phase5-task9f-separate-task8-whole-pure.log` | `c2d867994bec1416e0878554f37b6eb1ba5ed86c1e197987bd76bd578e0bb695` |
| `phase5-task9f-retained-static.log` | `521043351042190baef1fc043fd625e69a18181a46345db13527e622b773f709` |

Retained whole16 SQL session19586 closed normally, exit0, 1619.7 seconds;
owned `/tmp/singularity/integration/3819047be1c15f2374cc5db5` absent,
normal maintenance EMPTY. Separate Task8 SQL session15521 closed normally,
exit0, 299.3 seconds; owned
`/tmp/singularity/integration/b5671072e0969dcfc7dd696b` absent,
normal maintenance EMPTY. Expected PostgreSQL rejection logs in negative
contracts are not assertion failures. No manual database/root deletion.

## Actual combined source reviews and bounded handoff

Actual NONAUTHOR SOURCE SPEC `/root/phase5_task8_attribution_source_spec` and
distinct fresh SOURCE QUALITY `/root/phase5_task9f_combined_fresh_quality` are
CLOSED PASS, no P1/P2 or missing required F gate. Both read all fourteen source
files through EOF, governing amendments, complete native archives and original
preservation evidence. Entry equals closure: source14 and all79 entries match,
HEAD `9f91c97eb392b4c49c888ed31795d520d15bb8dd`.

Parent captures after actual review closure:

- `.devenv/phase5-task9f-combined-implementation-source-spec-review.md`,
  SHA-256 `b1fff0f5d5cd1b7488edb6678e9cb9af3639b5f852fa636e3117c2640931ec1b`.
- `.devenv/phase5-task9f-combined-implementation-source-fresh-quality-review.md`,
  SHA-256 `dd88bb75b4268a875d850ec09d5e7f53371292e32d66d34347215a13cff45d94`.

The reviewed pre-receipt report SHA was
`bef2e8bcf19b3863b240f6459bdb2d96ed10cbc863ff295d8d7055d8600ad8ba`.
Only factual review/handoff metadata is appended after closure; the fourteen
tested source bytes are unchanged. QUALITY's initial read-only preflight-prefix
diagnostic failed because additions are internal; its subsequent complete-line/
diff preservation calculation passed. This is recorded, not a source repair.
No Task10 production GO follows merely from F's acceptance.

Parent Git commit closed exit0; exact staged26-path verification, cached
diff-check and staged/current equality all passed. Postcommit index is EMPTY.
Task10/16 untracked documents and Task13/15 bookkeeping remain preserved and
unstaged. Commit message:
`fix(restore): preserve v3 storage references across integrity verification`.
New F native repair rounds: 0. Earlier component-specific Sol/fixture repairs
and Astra architecture advice remain separately recorded, not reset by GREEN.
Astra recovery rounds remain 0.

## Next Task10 characterization is not GREEN

Parent unchanged whole Runtime recovery/restart baseline subsequently closed
FAIL: 10 actual tests, 9 PASS, 1 FAIL, 185.7 seconds. The failure is the old
worker SELECT privilege expectation in
`document_extraction_reconciler_test.exs:283`; exact contract diagnosis is pending.
Both Runtime files remain byte-identical. Full archive:
`.devenv/phase5-task10-baseline-native-runtime2-fail.log`, SHA-256
`bea4d96a98f39afd00c9b51e28bf93a4f7dd9c1672d1c3ae51261c6547955af8`.
The allocated root `b8d2d57fb6c4751e5ff923f2` is absent and normal maintenance
is EMPTY. No manual cleanup, waiver, assertion edit or native retry occurred.
This separate Task10 gate is not a failed F gate and blocks Task10 acceptance.

Task10 unified search/extraction reconciliation and Task11 genuine normal Asset
finalization, unchanged live lease and complete V3 saga qualification remain
required; local reader proof cannot substitute. The two strict Task16 lease
guarantees remain UNSATISFIED / UNWAIVED / BLOCKED_DESIGN.

E2E NOT RUN, manual-only, explicitly deferred. No Vault feature work,
custody/key/capability/policy/crypto semantic change, released migration edit,
merge/push, version/tag/release/deployment, production activation/backfill or
production-data mutation.
