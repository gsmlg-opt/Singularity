# Phase 5 Task11 final-source qualification handoff

## Scope and current status

Task11 source and non-E2E gate qualification are complete on local source
`4a2e007649ab2d7c62aa72ee84bf1d2de0a93802`, descended from
`fed04c1259450a6be3e8ce5bf6a9a1e03c9758c8`.
All26 required campaign rows and their26 separate ordinary residual posts PASS.
Actual combined SOURCE SPEC followed by NEW distinct SOURCE QUALITY both CLOSED
PASS on the exact21 complete source files; the final committed Git blobs match
those same whole-file SHA256 values.

This document is the documentation-review candidate, not a prediction of its own
review or commit. Task11 local handoff closes only after independent documentation
SPEC, NEW distinct QUALITY, an explicit separate docs commit and the literal
clean-handoff checks below. Their post-review facts belong to
`.devenv/phase5-task11-v3-task11-documentation-handoff-closure.json`;
do not invent a docs commit hash or change already-reviewed bytes to record
their own verdict. Phase5 is NOT ACCEPTED; Task12 still needs its own reviewed
design/plan and execution after Task11 handoff closure.

Default logical version remains2. The unsupported-canonical guard and production
canonical writes remain closed. Task16 BOTH strict ALL-leases remain
UNSATISFIED/UNWAIVED/BLOCKED_DESIGN; Task17 is NOT GO; Task18 retains11/12/17
dependencies. E2E is NOT RUN — explicitly deferred local development, not PASS.
Final browser/release acceptance remains required. No merge, push, version bump,
tag, release, workflow dispatch, deployment, production activation or backfill.

## Local source commits and exact-byte binding

| Local commit | Responsibility | Files |
| --- | --- | ---: |
| `34f7db33dd94c2c4da64a4e059881d334e8dd506` | test(architecture): preserve accepted native-text provenance | 1 |
| `a5a71d0941f3cfdb333615858dc39bbb52682714` | test(storage): harden owned knowledge fixture lifecycle | 7 |
| `52b433c78b7c2b1cd661fb98e4ef76966c81c7df` | fix(backup): accept existing native algorithm metadata | 5 |
| `ddf1a1a329227096165a90ee6d69b6fecb643eeb` | test(backup): add independent canonical and native restore oracles | 4 |
| `0f5ee1102c2ce47263f534874bf9ad7e7c3e69e0` | test(restore): qualify complete v3 saga and malformed rejection | 2 |
| `4a2e007649ab2d7c62aa72ee84bf1d2de0a93802` | test(restore): extend independent task with guarded knowledge oracle | 2 |

The union of these six commits changes exactly the21 source paths below.
Every index blob was checked before its commit; each commit's parent/path set,
empty resulting index and exact removal of only its owned status entries were
checked. Final HEAD blobs21/21 and all1860 precommit current pins matched.
After source commits, only the30 owned design/plan paths remained dirty.

The original qualification guard is unchanged, SHA256
`27566dfd59921ecf7df0010bb9c13ec2f9d83ddb78be7f2989f88dec83c16cf7`.
Its last root PASS before the first source commit used
`task11-saga13-native273-final-source-commits-ready`.
Both actual source reviewers had opening/closing original-guard PASS on their
specified precommit generations. Its fixed fed04 HEAD/status naturally no
longer applies after the authorized commits: no postcommit original-guard PASS
is claimed and no guard or historical manifest was rewritten or rebaselined.
Postcommit source/tree/ownership checks are separate evidence, not a replacement
qualification run.

### Qualified source SHA256

```text
320b5ae99d6687692d8bf39daaade648c7bb5733717367b83ef5c43f3bad1cac  apps/singularity_runtime/lib/mix/tasks/singularity.test.restore.ex
c48b2465568c8a3367f93ec67c81f3ce45b82b4824dae3319f17befa41b0348d  apps/singularity_storage/lib/singularity/storage/backup/knowledge_preflight.ex
a42efd3edcad2ff81f8954c10b78efa89de683be28896c1848069cafa34147a3  apps/singularity_storage/test/singularity/storage/backup/knowledge_preflight_test.exs
58824ff938fdb6348de4e7b67fb61bd87fd38df4d0ac1526a05d6386d07e1742  apps/singularity_storage/test/singularity/storage/backup/logical_v3_import_test.exs
ced636d8d21f139865b769911f39569f5dfa86b2e31fea85737da915b8e16d72  apps/singularity_storage/test/singularity/storage/knowledge_concurrency_test.exs
ef22034681c3e44552610e9423fa94f823ac6da321cd8f0fef59d2858a30d2b6  apps/singularity_storage/test/singularity/storage/postgres/document_projection_events_test.exs
51ed58ab3301878db5a83f1badc11867e3a92ebe981344f38e5d17795a92ca16  apps/singularity_storage/test/singularity/storage/postgres/document_repository_test.exs
491fd836cda6203c16c65200bde6436854f5e96d5924d1b45227d1c21d94dd06  apps/singularity_storage/test/singularity/storage/postgres/knowledge_asset_lifecycle_guards_test.exs
a5bcfe503e87420f68437359be5be5b680f352f6ec9dba78ca0b21fa4cf65540  apps/singularity_storage/test/singularity/storage/postgres/outbox_test.exs
4bcdffea76038c7275044235233c64d4376dd7de77e762a32a1c43044ef61b34  apps/singularity_storage/test/support/knowledge_backup_fixtures.ex
bdda89e16c15435d87f7b9850ce3b6c16d7937a58e31d5bd2bad8eddd869b271  apps/singularity_storage/test/support/knowledge_fixture_resource_owner.ex
980581b92eb6cc8228281bd8a7e50738b42d4f2f53801ec862c309ea64233861  apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs
51f95b54176747a0c63a1d55bf9ed6bb4d94b2ff1b8f74ca4841ae44dfe532da  apps/singularity_runtime/test/mix/tasks/singularity.test.restore_test.exs
860295ebb15a7eae201e219073be02dc50a2dd9685defe61c3fd5177479a66b1  apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs
312bf9526f2ec6052c586c9f786eb821b5423bc08460514fbd769ae112f8004c  apps/singularity_runtime/test/support/knowledge_backup_restore_fixture.ex
a2fb3dbf751d0ab70a60b75924666b839fe4cb6addccc21988e4b1b5696cf813  apps/singularity_runtime/test/support/knowledge_restore_oracle.ex
546d71750646c8b2564d454f4aaf6750a60fa118183166285115792dae8db6b5  apps/singularity_storage/priv/repo/migrations/20261016000100_knowledge_restore_algorithm_metadata.exs
9448bd8ca8c0bafc633b1cf94c720ef4ffd01d6d8b5b02ef7a9eb7210d4bc264  apps/singularity_storage/test/singularity/storage/backup/knowledge_fixture_nested_lifecycle_test.exs
1d992bdac7cda04bbf37c5f98200052e4d8f9cb2708c7dc49ac8f7872039cba2  apps/singularity_storage/test/singularity/storage/backup/knowledge_restore_algorithm_migration_test.exs
0c2a318cfe2946d881b493369f6a0eadf75031adc4b4075c223f29a0a4a3d1f9  apps/singularity_storage/test/singularity/storage/backup/logical_v3_failure_test.exs
20a8dc97bccf77edec2d2b09e8b8a29d3bd421fd0e7ef77dcb26d2cc02cca1a2  apps/singularity_storage/test/support/knowledge_canonical_oracle.ex
```

## Implementation and compatibility boundary

The native fixture constructs genuine originals through existing public Asset
publication, retains immutable original/version/source-set bindings and observes
the actual backup worker cut. The independent canonical oracle covers the
38-table/367-column contract; the independent restore oracle observes UUID,
canonical-path and mixed original inventories, exact bytes/history, reconstructed
public search and late-corruption rejection through existing real crypto/custody.

The complete Runtime/Storage fault owners retain exact malformed, staged
failure, cleanup, retry and sentinel assertions. Supported SAME-destination
replays are distinct from RESTART into fresh disposable targets. Lost/consumed
integrity custody after committed rewrap remains an unsupported in-place
continuation boundary, not a fabricated durable recovery or rollback guarantee.
The sole independent restore task enters its guarded test-only oracle only
after unchanged legacy cleanup; no production static dependency on test support.

Necessary compatibility is limited to accepting the two already-established
algorithm metadata spellings `aes_256_gcm` and `aes-256-gcm` in knowledge
preflight and the exact existing knowledge-restore graph predicate. New forward
migration `20261016000100_knowledge_restore_algorithm_metadata.exs` changes
only that predicate with a fail-closed exact-source/cardinality check. No released
migration was edited. This is the explicit smallest knowledge backup metadata
compatibility patch involving legacy key metadata; it adds no Vault feature,
key/custody/capability/policy/crypto semantic change, grant or production rewrite.

Owned fixture lifecycle changes establish descendant-before-parent resource
closure. The three existing Document test owners add retirement without
canonical-history deletion. No temporary diagnostic observer remains. The
case-local120000ms sentinel watchdog is exactly the reviewed amendment; no other
deadline, assertion, filter, tag or concurrency relaxation is claimed.

## Complete final-source campaign

The [reviewed detailed qualification plan](../superpowers/plans/2026-10-18-singularity-v0.2-phase-5-task11-final-source-qualification.md)
defines exact order and direct argv. Results below are actual executed counts;
excluded cases are NOT passes. Overlapping focused runs are not additive unique
coverage. Every gate and each distinct ordinary post naturally exited0; every
post result was EMPTY, with no forced cleanup.

| ID | Native gate/post | Actual result |
| --- | --- | --- |
| R01 | 222/223 | Private role verification PASS; adapted bootstrap, not shared devenv up/down. |
| R02 | 224/225 | Dependencies Unchanged. |
| R03 | 226/227 | Unused-dependency check PASS. |
| R04 | 228/229 | Complete format check PASS. |
| R05 | 230/231 | Dev compilation --warnings-as-errors PASS. |
| R06 | 232/233 | 2215 executed tests +10 properties; 0 failures; 2086 excluded integration tests. |
| R07 | 234/235 | 2086 executed tests; 0 failures; 2225 excluded items, including10 properties. |
| M01 | 236/237 | 110 executed tests; 0 failures; 6 excluded. |
| M02 | 238/239 | 55 executed tests; 0 failures; 27 excluded. |
| T01 | 240/241 | 167 executed tests; 0 failures; 8 excluded. |
| T02 | 242/243 | 15 executed tests; 0 failures; 0 excluded. |
| T03 | 244/245 | 29 executed tests; 0 failures; 57 excluded. |
| P01 | 246/247 | 15 executed tests; 0 failures; 0 excluded. |
| P02 | 248/249 | 164 executed tests; 0 failures; 2 excluded. |
| P03 | 250/251 | 265 executed tests; 0 failures; 52 excluded. |
| P04 | 252/253 | 29 executed tests; 0 failures; 27 excluded. |
| A01 | 254/255 | 131 executed tests; 0 failures; 0 excluded. |
| S01 | 256/257 | 6 executed integration tests; 0 failures; 0 excluded. |
| R08 | 258/259 | One independent restore: retained V1/V2; 3 positive UUID/canonical/mixed knowledge variants and 1 late-corruption negative; unified Note search3/expected3. Also sole M03. |
| R09 | 260/261 | Frozen copy-strategy frontend install166 packages; 207 lock entries reported OK. |
| R10 | 262/263 | 166 installed packages match lockfile. |
| R11 | 264/265 | 22 JS files checked, no formatting/lint findings. |
| R12 | 266/267 | Vitest9 files/197 JS unit tests PASS; not E2E. |
| R13 | 268/269 | Tailwind and JS asset builds PASS; four bundles/manifest5 entries. |
| R14 | 270/271 | xref cycles0, fail-above0. |
| R15 | 272/273 | actionlint1.7.12: five workflow files, zero findings; syntax only, no dispatch/E2E. |

Literal R06 per application: Core233tests+10properties; Domains56; Storage446
executed/1624excluded; Retrieval52; Ingest83; Runtime1073executed/462excluded;
Web272. Zero failures. Literal R07: Storage1624executed/446excluded and
Runtime462executed/1073excluded; Core233tests+10properties, Domains56,
Retrieval52, Ingest83 and Web272 were excluded. Zero failures.
R07 generated seed395800/max_cases96; no seed/filter/concurrency flag was added.
R08=M03 is one invocation, never two restore credits or an invented ExUnit count.

### Environment and launcher

The unchanged wrapper SHA256 is
`66a4ace46937b352ca16e3099ce8d0c0b7d65338aba5e2cdacc5cccf788d19b5`.
It selects the isolated PostgreSQL17.10 process21905 at private socket
`/tmp/singularity-phase5-socket.hzWDT0`, port5432 and private data directory
`.devenv/phase5-pg.0LPElO`, plus MIX_ENV=test and pinned shared dependencies.
Toolchain: Elixir1.18.4/OTP28.5.0.3 and devenv profile
`/nix/store/x83m8i4dfw7gwf2cg79yqll5ngi36ks3-devenv-profile`.
Explicit dev overrides remain exactly as listed. R01 verifies already-provisioned
private roles; it is not README shared-service `devenv up/down` lifecycle proof.

Each fresh gate used umask077 and this direct launcher, with concrete raw/argv
fields from the per-row GO (angle brackets below are explanatory, not shell input):

```text
script --quiet --return --flush --log-out <absolute private raw> -- devenv shell -- bash .devenv/phase5-pg-command.sh <exact argv>
```

Each gate had its OWN fresh ordinary post with identical launcher and exact argv:

```sh
psql --dbname=postgres --no-psqlrc --tuples-only --no-align --file=.devenv/phase5-task11-residual.sql
```

Residual SQL SHA256:
`ed2cf491f44c1bb938d05abc3c68529343b8a2ae32a79a471ff2346d45f0b357`.
The parent read all52 regular nonsymlink0600 safe raws through their actual
footers, checked hashes/counts and closing original guards. The independent
evidence auditor independently reread all52; actual SOURCE SPEC also read all52.
SOURCE QUALITY read complete M01/T01/A01/R08 and own posts and checked52 hashes;
it did not independently reread every raw. Both source reviewers independently
read all21 complete source files (29487lines),12 complete tracked diffs and9
new complete files plus complete governing authorities. Reviewers changed no
files and launched no VM/tests/SQL/network/service/signal/Git mutation.

### Warnings and retained uncertainty

These runs are not warning-free. R06 recorded3 module warnings and2 warning
JSON logs. R07 recorded54 module warnings,26 warning and75 error JSON logs.
P03 recorded2 error JSON logs. R08 recorded102 module warnings and OID debug logs.
npm lifecycle and Vite-loader compatibility warnings remain. No unsupported
classification of these logs as expected/pre-existing is made; separate dev
compilation with warnings-as-errors passed.

Historical Native174 remains FAIL (2083executed/3failures/natural2).
Document retirement has meaningful RED18043executed/3teardown failures and
SAME18843executed/0failures, plus separate helper182/1901executed/0failures and
actual SOURCE SPEC then distinct QUALITY191PASS. Exact174 foreign-UUID producers
and checkout/cleanup causes remain unproved.
Native220's57executed/0failure observation remains diagnostic UNREPRODUCED,
not causal repair. Temporary observers were removed with exact whole-original
and inverse proof; historical evidence/allowances were preserved, not renewed.
Earlier interrupted, failed, excluded and unreached results remain historical.
The separately reviewed final campaign used its own one-shot allowances;
all26 are consumed, not a repeat-until-green policy.

Product-B causal failed Sol0/Astra0/no impasse; retirement focused repair1GREEN;
observer correction1GREEN/failed0. Advisory/design reviews are not repair rounds.

## Documentation ownership and closure conditions

This handoff synchronizes master and saga current status, final qualification
design/plan, and the Phase5 verification report. The26 new dated amendment
design/plan files are retained as authored historical records; their candidate
status/checklists are not replacement execution evidence or permission to
recreate removed observers. Current execution facts are this matrix and the
sealed GO/row-ledger/review receipts. Older unchanged requirement narratives and
their FAIL/NOT RUN records are historical, not current acceptance assertions.

Required documentation closure is independent SPEC then NEW distinct QUALITY
on the exact final32 owned docs, followed by a docs-only local commit.
Root must verify unchanged source21/frozen controls, exact docs ownership/hashes,
empty index and the literal README handoff commands after that commit:

```sh
git diff --check
git status --short
test -z "$(git status --porcelain)"
```

Before that actual check no clean handoff is claimed. No unrelated file may be
staged/deleted to obtain a clean status. Postcommit closure records exact docs
commit and reviewed blob hashes separately; no source/DB changes or new Native
tests are introduced by status synchronization.

## Exact argv and immutable raw hashes

All paths below are local ignored qualification artifacts, preserved rather
than committed with private runtime logs.

### R01

```sh
mix singularity.db.verify_roles
```

Gate: `.devenv/phase5-task11-v3-saga13-native222-final-source-r01-roles-native.log`.

SHA256: `d6fc5d618b6f92c1a10795244260e2e7ce41786a8855133b6a1428c03a8201cd`.

Own ordinary post: `.devenv/phase5-task11-v3-saga13-native223-final-source-r01-post-native.log`.

SHA256: `ac1d25a581496b9ae43f42647f8e3b8e4cc29d893507add1a1544808a76b1215`.

### R02

```sh
env MIX_ENV=dev mix deps.get
```

Gate: `.devenv/phase5-task11-v3-saga13-native224-final-source-r02-deps-native.log`.

SHA256: `0d138d207c13ad682c6c3f9588b2eb3b224a299914168dadd264aef2c008fff0`.

Own ordinary post: `.devenv/phase5-task11-v3-saga13-native225-final-source-r02-post-native.log`.

SHA256: `219f3f45cde3329a57eace4610aa0db8acedf7a84e10e41c7f951c40f3f8ef80`.

### R03

```sh
env MIX_ENV=dev mix deps.unlock --check-unused
```

Gate: `.devenv/phase5-task11-v3-saga13-native226-final-source-r03-unused-native.log`.

SHA256: `6833dd6344b7a8e3beb568db645578d3f00c7716c54323a436804a273e36a149`.

Own ordinary post: `.devenv/phase5-task11-v3-saga13-native227-final-source-r03-post-native.log`.

SHA256: `b1c9a5ebb82b063614f011f787d604e41bc6bd5046214a2e997713cd2e952eaa`.

### R04

```sh
env MIX_ENV=dev mix format --check-formatted
```

Gate: `.devenv/phase5-task11-v3-saga13-native228-final-source-r04-format-check-native.log`.

SHA256: `2592568f23f0e64425047fe388400b382082a47bc16db12c413ff6adf410884f`.

Own ordinary post: `.devenv/phase5-task11-v3-saga13-native229-final-source-r04-post-native.log`.

SHA256: `9ad3b3c8e3c01118bddfc20b62b0da587dd658073a79e1f1b1612acd7cc4efa3`.

### R05

```sh
env MIX_ENV=dev mix compile --warnings-as-errors
```

Gate: `.devenv/phase5-task11-v3-saga13-native230-final-source-r05-compile-native.log`.

SHA256: `7641e4783d1514572a5b8fd3f35e71c8179bc5d5818325ddda424b141e826dea`.

Own ordinary post: `.devenv/phase5-task11-v3-saga13-native231-final-source-r05-post-native.log`.

SHA256: `294260587e20a3d8bfbe1187a032e282398b93182c818666c216882f69ca6a4b`.

### R06

```sh
mix test
```

Gate: `.devenv/phase5-task11-v3-saga13-native232-final-source-r06-unit-native.log`.

SHA256: `e3a89773449de1ff840e485b7fc4f0979c3849b884cf5364c7d6b31056679dd3`.

Own ordinary post: `.devenv/phase5-task11-v3-saga13-native233-final-source-r06-post-native.log`.

SHA256: `887c270b317820da3bb1d24c81037f0c072f15062a1520589f41179fdaad891e`.

### R07

```sh
mix singularity.test.integration
```

Gate: `.devenv/phase5-task11-v3-saga13-native234-final-source-r07-integration-native.log`.

SHA256: `a4a47e00794a3b9dc61bb79b407630f7ce85d552f0d60ac4de33be01d3ab010f`.

Own ordinary post: `.devenv/phase5-task11-v3-saga13-native235-final-source-r07-post-native.log`.

SHA256: `f467c12432c97c4b0f910c69620af6c561790c9b32195160e9f56976f217079b`.

### M01

```sh
mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_failure_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs --seed 215378 --warnings-as-errors
```

Gate: `.devenv/phase5-task11-v3-saga13-native236-final-source-m01-master-integration-native.log`.

SHA256: `6b8c1da0140723b383ee815a67315f43549045baeab46126eafe431f2bc772fc`.

Own ordinary post: `.devenv/phase5-task11-v3-saga13-native237-final-source-m01-post-native.log`.

SHA256: `9e5a41e8457a55ff00af12d59073503ecf66571c069c9621dc3be61310a55873`.

### M02

```sh
mix test apps/singularity_runtime/test/singularity/runtime/backup_vault_test.exs apps/singularity_runtime/test/singularity/runtime/restore_vault_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs --seed 215378 --warnings-as-errors
```

Gate: `.devenv/phase5-task11-v3-saga13-native238-final-source-m02-legacy-unit-native.log`.

SHA256: `55f5b70351af3429dcc5138959c8c331429e83f50f9c263196b12bb75beb47c8`.

Own ordinary post: `.devenv/phase5-task11-v3-saga13-native239-final-source-m02-post-native.log`.

SHA256: `1a187e546771e54421ac1ce0047ce3cefa0d5f071ab47a8464153a685d155d83`.

### T01

```sh
mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/logical_v3_import_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_preflight_test.exs apps/singularity_storage/test/singularity/storage/backup/document_restore_integrity_test.exs apps/singularity_storage/test/singularity/storage/backup/document_restore_reconciliation_test.exs apps/singularity_storage/test/singularity/storage/unified_search_restore_test.exs --seed 215378 --warnings-as-errors
```

Gate: `.devenv/phase5-task11-v3-saga13-native240-final-source-t01-storage-retained-native.log`.

SHA256: `655d8c9850e668b52b2e9bcdda0e77c82bacfdb2f3910b7246ea10aa382c6edc`.

Own ordinary post: `.devenv/phase5-task11-v3-saga13-native241-final-source-t01-post-native.log`.

SHA256: `ee403b49f19eae62dbe721460195e8ce120d858304c4811c8305260656cafc51`.

### T02

```sh
mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/native_text_ingestion_live_test.exs apps/singularity_runtime/test/singularity/runtime/native_text_authorization_live_test.exs apps/singularity_runtime/test/singularity/runtime/native_text_backup_cut_live_test.exs apps/singularity_runtime/test/singularity/runtime/native_text_backup_restore_live_test.exs --seed 215378 --warnings-as-errors
```

Gate: `.devenv/phase5-task11-v3-saga13-native242-final-source-t02-native-text-retained-native.log`.

SHA256: `3aa24e70c6d0dae899dc320b62298a8f847d646b7d519804e3d380edbfeef7ac`.

Own ordinary post: `.devenv/phase5-task11-v3-saga13-native243-final-source-t02-post-native.log`.

SHA256: `5d5ae5b500cf629144ead06441dd1cd736dd5bbedfa317e9615d214a05974dbc`.

### T03

```sh
mix test apps/singularity_storage/test/singularity/storage/backup/logical_record_codec_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_schema_v3_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_schema_ddl_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_exporter_test.exs --seed 215378 --warnings-as-errors
```

Gate: `.devenv/phase5-task11-v3-saga13-native244-final-source-t03-codec-schema-unit-native.log`.

SHA256: `43ce9e3e43221c148d10e2940628da045ac61aa56a77e84edab80ee33c878151`.

Own ordinary post: `.devenv/phase5-task11-v3-saga13-native245-final-source-t03-post-native.log`.

SHA256: `b26c0fbc4f0bd80637832e054cc47496471d68ee7e3d162f5d82428dd4008401`.

### P01

```sh
mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/native_text_ingestion_live_test.exs apps/singularity_runtime/test/singularity/runtime/native_text_authorization_live_test.exs apps/singularity_runtime/test/singularity/runtime/native_text_backup_cut_live_test.exs apps/singularity_runtime/test/singularity/runtime/native_text_backup_restore_live_test.exs --seed 0
```

Gate: `.devenv/phase5-task11-v3-saga13-native246-final-source-p01-native-prerequisite-native.log`.

SHA256: `83fcf4b1bcd2c36b88b4f5ef8a2dd40d1de8019eb1bcfca5676099c7315a618e`.

Own ordinary post: `.devenv/phase5-task11-v3-saga13-native247-final-source-p01-post-native.log`.

SHA256: `5ac9f57d793c674d0c9736c6a2a89299dba78c44548ac8949e23dc1c73413661`.

### P02

```sh
mix test apps/singularity_ingest/test/singularity/ingest/upload_request_test.exs apps/singularity_ingest/test/singularity/ingest/upload_text_test.exs apps/singularity_runtime/test/singularity/runtime/api_test.exs apps/singularity_runtime/test/singularity/runtime/accept_upload_test.exs apps/singularity_runtime/test/singularity/runtime/upload_session_lock_test.exs apps/singularity_runtime/test/singularity/runtime/asset_download_test.exs apps/singularity_runtime/test/singularity/runtime/upload_message_stream_test.exs apps/singularity_runtime/test/singularity/runtime/authorization_test.exs apps/singularity_runtime/test/singularity/runtime/create_upload_grant_test.exs apps/singularity_runtime/test/singularity/runtime/cancel_upload_grant_test.exs apps/singularity_runtime/test/singularity/runtime/upload_session_supervisor_test.exs apps/singularity_runtime/test/singularity/runtime/upload_reconciler_test.exs --seed 0
```

Gate: `.devenv/phase5-task11-v3-saga13-native248-final-source-p02-upload-unit-prerequisite-native.log`.

SHA256: `53ba538132ac7074a7439606a6d3f1cb5d62e9e933ad65f8097443b621da90a8`.

Own ordinary post: `.devenv/phase5-task11-v3-saga13-native249-final-source-p02-post-native.log`.

SHA256: `87fa51f0d8c50ead21664c4ec9b0121673e633a0e6d3d1a4cfda26382e4e614e`.

### P03

```sh
mix singularity.test.integration apps/singularity_storage/test/singularity/storage/asset_saga_test.exs apps/singularity_storage/test/singularity/storage/asset_grant_creation_test.exs apps/singularity_storage/test/singularity/storage/server_owned_upload_grant_test.exs apps/singularity_storage/test/singularity/storage/asset_stage_abandonment_test.exs apps/singularity_storage/test/singularity/storage/asset_sealed_checkpoint_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_fixture_lifecycle_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_exporter_test.exs apps/singularity_storage/test/singularity/storage/backup_restore_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_job_test.exs apps/singularity_runtime/test/singularity/runtime/asset_vertical_test.exs apps/singularity_runtime/test/singularity/runtime/asset_verification_finalization_test.exs apps/singularity_runtime/test/singularity/runtime/upload_reconciliation_integration_test.exs apps/singularity_runtime/test/singularity/runtime/upload_session_lock_test.exs --seed 0
```

Gate: `.devenv/phase5-task11-v3-saga13-native250-final-source-p03-storage-runtime-prerequisite-native.log`.

SHA256: `fe9807ecfbe1bf6aec724598dd7d52adee4a71d3dccbd614118e3d2ccccca8ce`.

Own ordinary post: `.devenv/phase5-task11-v3-saga13-native251-final-source-p03-post-native.log`.

SHA256: `63ecd31a9729f05903f516bbe266b64aac93ef83fab5677ded0d816306abbc03`.

### P04

```sh
mix test apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs apps/singularity_storage/test/singularity/storage/backup_restore_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs --seed 0
```

Gate: `.devenv/phase5-task11-v3-saga13-native252-final-source-p04-storage-unit-prerequisite-native.log`.

SHA256: `1a9fee0c29e390518fc1c6242d6f68d9f7a828b6fe4b288042f4ebd73dcd726b`.

Own ordinary post: `.devenv/phase5-task11-v3-saga13-native253-final-source-p04-post-native.log`.

SHA256: `6e45ca0c15dc1128be872a8c943c908c6ab08bee03c868c6254b021adba146ca`.

### A01

```sh
mix test apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs --seed 215378 --warnings-as-errors
```

Gate: `.devenv/phase5-task11-v3-saga13-native254-final-source-a01-architecture-native.log`.

SHA256: `deb8a84898cb1363a481db17fb18b7a051d89c6f75d56ce562411e628a3afa14`.

Own ordinary post: `.devenv/phase5-task11-v3-saga13-native255-final-source-a01-post-native.log`.

SHA256: `e4aaf1032d996072e42aac3ae8c9e04263b80cf3a2ac79d0a2995f05c7629f5a`.

### S01

```sh
mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/note_search_store_test.exs --seed 215378 --warnings-as-errors
```

Gate: `.devenv/phase5-task11-v3-saga13-native256-final-source-s01-search-projection-native.log`.

SHA256: `70a3a7bcfabc332e1636b5ef35d3ebde314a9ec7cc4980f3383c9484a63e570c`.

Own ordinary post: `.devenv/phase5-task11-v3-saga13-native257-final-source-s01-post-native.log`.

SHA256: `87fe49fd45df56e212bd22938e2f136b1b1aefc14c772ee221b0ff6c06121e35`.

### R08

```sh
mix singularity.test.restore
```

Gate: `.devenv/phase5-task11-v3-saga13-native258-final-source-r08-restore-native.log`.

SHA256: `9daea341d4fff92080d2ea3a06d77d696c44695d1f500467f25e12ca2eb8ca20`.

Own ordinary post: `.devenv/phase5-task11-v3-saga13-native259-final-source-r08-post-native.log`.

SHA256: `f1e92adefe0330f5fde004909538e67d54243f7afe888e264dd78456fe702bbe`.

### R09

```sh
env MIX_ENV=dev NPM_EX_LINK_STRATEGY=copy mix npm.install --frozen
```

Gate: `.devenv/phase5-task11-v3-saga13-native260-final-source-r09-npm-install-native.log`.

SHA256: `fffc8b830af1233af40d9e0022f93e0cd06a8a356e679ad0866ee22afce8eac3`.

Own ordinary post: `.devenv/phase5-task11-v3-saga13-native261-final-source-r09-post-native.log`.

SHA256: `ef96a76103eb65a1d0be07b4e171483c3c569bf856adf276f577a928e44954b9`.

### R10

```sh
env MIX_ENV=dev mix npm.verify
```

Gate: `.devenv/phase5-task11-v3-saga13-native262-final-source-r10-npm-verify-native.log`.

SHA256: `0d26128eca094d4765e7f1d5977f2b7377db9605df20ef6e22ae2ec0c012221e`.

Own ordinary post: `.devenv/phase5-task11-v3-saga13-native263-final-source-r10-post-native.log`.

SHA256: `b03892fbb1e6f32e0fa0fcfc2961fb5f90a449c1bfd8e78d2efddd58856e0311`.

### R11

```sh
env MIX_ENV=dev mix duskmoon_bundler.js.check
```

Gate: `.devenv/phase5-task11-v3-saga13-native264-final-source-r11-js-check-native.log`.

SHA256: `a2433986fbd129ebc48388c0182634bed6947174f4720f33f9dbcb939b483f9a`.

Own ordinary post: `.devenv/phase5-task11-v3-saga13-native265-final-source-r11-post-native.log`.

SHA256: `fc197c631e5c74c0ff2abc717617df9b656fffae69a82092b402440be2678b89`.

### R12

```sh
env MIX_ENV=dev mix npm.run test:js
```

Gate: `.devenv/phase5-task11-v3-saga13-native266-final-source-r12-js-unit-native.log`.

SHA256: `5287de1afeae06ca34bc2caca26f28ca97151f1aac952781da0c9966400fe5eb`.

Own ordinary post: `.devenv/phase5-task11-v3-saga13-native267-final-source-r12-post-native.log`.

SHA256: `66f9b83c66900d1af29aead9b926fd53d67e2b9fff1f05aeb801c1568399e589`.

### R13

```sh
env MIX_ENV=dev mix duskmoon_bundler.build singularity_web --tailwind
```

Gate: `.devenv/phase5-task11-v3-saga13-native268-final-source-r13-assets-build-native.log`.

SHA256: `0bfe845506f1e164dbc9f5bac90b0d9aa8fb056d543fb3e0c6299f723d7cb3ac`.

Own ordinary post: `.devenv/phase5-task11-v3-saga13-native269-final-source-r13-post-native.log`.

SHA256: `2d8ae96fc58556179661a022a3ce8eb00840843bafa11810285964277f9622d8`.

### R14

```sh
env MIX_ENV=dev mix xref graph --format cycles --fail-above 0
```

Gate: `.devenv/phase5-task11-v3-saga13-native270-final-source-r14-xref-native.log`.

SHA256: `ee9b0751e43e07f6c91704794a5b11c323607636b890e4c33b753fcd503f5b18`.

Own ordinary post: `.devenv/phase5-task11-v3-saga13-native271-final-source-r14-post-native.log`.

SHA256: `5a1cb930c69af1e38873c6ee2075469cfa13d9ec8b58bee5468ef14f3ca70bdf`.

### R15

```sh
nix run nixpkgs#actionlint -- .github/workflows/ci.yml .github/workflows/test.yml .github/workflows/e2e.yml .github/workflows/release.yml .github/workflows/docker-image.yml
```

Gate: `.devenv/phase5-task11-v3-saga13-native272-final-source-r15-actionlint-native.log`.

SHA256: `c5776e79d1584fd4911574583c3b4fe43aa15bcc31026769c685e30ad8a66f02`.

Own ordinary post: `.devenv/phase5-task11-v3-saga13-native273-final-source-r15-post-native.log`.

SHA256: `7bf00f93886c18a4e2ea3e68236c7a97f8f28fcf7a1b5eb98b45eb9afe861420`.
