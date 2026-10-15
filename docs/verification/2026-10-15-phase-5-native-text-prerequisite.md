# Phase 5 Task11 native-text prerequisite verification

Status: implementation, scoped checks and independent actual-source SPEC then
NEW distinct fresh QUALITY PASS. Four local code commits are recorded below;
documentation review and literal clean handoff require separate closure. This is not
Task11 full knowledge-V3 saga acceptance, Phase5 acceptance, browser/release
acceptance or production activation. E2E NOT RUN by user instruction.

Baseline: `94efb34ae128298ab62bfbd7b77d387b882bbb62`, branch
`codex/v0.2-phase-5-export-backup`, project-local worktree
`.trees/v0.2-phase-5-export-backup`. The index remained empty during verification.
The governing design and plan are the corresponding
`2026-10-15-singularity-v0.2-phase-5-native-text-ingestion` documents.

## Implemented boundary

Eight production files implement the bounded prerequisite:

- Ingest `upload_request.ex` and new `upload_text.ex`: exactly text/plain and
  text/markdown, bounded incremental complete UTF8/EOF/NUL/signature validation,
  honest empty text and min(configured maximum,67108864), without normalization.
- Runtime `api.ex`, `assets/accept_upload.ex`, `assets/upload_session.ex` and the
  smallest `assets/download.ex` MIME compatibility: preserve public authority
  rejection, exact-byte streaming, actual writer sealing and download protocol.
- Storage `postgres/asset_repository.ex`: internal sealed marker, exact/no-upgrade
  replay, independent finalization evidence checks and one real acknowledgement
  transaction through available3/processing4/ready5 with completed metadata,
  search, audits and genuine receipt5; binary metadata jobs remain unchanged.
- Storage `backup/exporter.ex`: read-only same-snapshot fail-closed unsupported
  uploaded/verified text guard in BOTH entrypoints, after the existing canonical
  guard, before inventory, for default2/explicit2/explicit3.

Test support changes are confined to ResourceOwner/MigrationTestEnvironment and
new Runtime.NativeAssetFixture. One unnamed owned infrastructure supervisor
excludes exactly four already-owned repositories and stops before repositories
and database drain. Genuine tests use real bootstrap/login/unlock, authorization,
custody, public upload, Outbox, Oban, object storage and plaintext download.
Protocol/fault doubles remain separate scoped contracts, not live-auth proofs.

No migration, role/grant/policy, frozen Vault feature, custody/key/capability or
DownloadLease implementation change. Test-only bootstrap and exact owned
negative authorization-row mutations use established opaque legacy owner scope;
they add no Vault feature. The Runtime.Download change is only its two MIME
allowlist entries. No metadata lease/extractor protocol, defaultV2, dependency,
runtime pin, production canonical-write activation or production data change.
No merge, push, version bump, tag, release or deployment.

## Execution and exact commands

Every qualified command used the established pinned private-PostgreSQL wrapper:
`script --quiet --return --flush --log-out <fresh-raw> -- devenv shell -- bash
.devenv/phase5-pg-command.sh <command>`. Fresh raw paths were absent and not
symlinks; umask077. Native runs retained seed0/max_cases96 and original deadlines,
assertions, input sizes and concurrency. All other actors/commands were CLOSED
during Native/formatter/maintenance LIVE; parent performed only exact-session
polling/commentary. No prewarm, hidden filtering or forced cleanup.

Before/after guards checked branch, exact HEAD/index, source/status manifests,
private PostgreSQL identity, Elixir1.18.4/OTP28.5.0.3 profile pins and owned
BEAM/logger absence. Ordinary residual queries returned natural0/EMPTY after
each qualified route. Complete qualified raw output was read through natural EOF.

Final native generation GREEN5 source53 entries:
`6817ac39ccc7be7060523b3105f383da302d0f361047dc124050f4bb9fd0f596`.
Retained generation reg1 source56 entries:
`f52a01253cc9a6c09ead853dbd8cd9f107ba6dd19f0f9fb5be66ef8ae6f6dd3b`;
status `b82415b10e53b2f928526f2b721f76216d35b6cc74d263a55f6aa653af200c5f`.
The sole code delta between these generations is the grant test-contract
synchronization described below. Subsequent progress/documentation edits are
not execution evidence and require independent review before local handoff.

The native route ran all four owners, not selected test lines:

```sh
mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/native_text_ingestion_live_test.exs apps/singularity_runtime/test/singularity/runtime/native_text_authorization_live_test.exs apps/singularity_runtime/test/singularity/runtime/native_text_backup_cut_live_test.exs apps/singularity_runtime/test/singularity/runtime/native_text_backup_restore_live_test.exs --seed 0
```

Retained Ingest/Runtime unit owners:

```sh
mix test apps/singularity_ingest/test/singularity/ingest/upload_request_test.exs apps/singularity_ingest/test/singularity/ingest/upload_text_test.exs apps/singularity_runtime/test/singularity/runtime/api_test.exs apps/singularity_runtime/test/singularity/runtime/accept_upload_test.exs apps/singularity_runtime/test/singularity/runtime/upload_session_lock_test.exs apps/singularity_runtime/test/singularity/runtime/asset_download_test.exs apps/singularity_runtime/test/singularity/runtime/upload_message_stream_test.exs apps/singularity_runtime/test/singularity/runtime/authorization_test.exs apps/singularity_runtime/test/singularity/runtime/create_upload_grant_test.exs apps/singularity_runtime/test/singularity/runtime/cancel_upload_grant_test.exs apps/singularity_runtime/test/singularity/runtime/upload_session_supervisor_test.exs apps/singularity_runtime/test/singularity/runtime/upload_reconciler_test.exs --seed 0
```

Retained integration owners:

```sh
mix singularity.test.integration apps/singularity_storage/test/singularity/storage/asset_saga_test.exs apps/singularity_storage/test/singularity/storage/asset_grant_creation_test.exs apps/singularity_storage/test/singularity/storage/server_owned_upload_grant_test.exs apps/singularity_storage/test/singularity/storage/asset_stage_abandonment_test.exs apps/singularity_storage/test/singularity/storage/asset_sealed_checkpoint_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_fixture_lifecycle_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_exporter_test.exs apps/singularity_storage/test/singularity/storage/backup_restore_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_job_test.exs apps/singularity_runtime/test/singularity/runtime/asset_vertical_test.exs apps/singularity_runtime/test/singularity/runtime/asset_verification_finalization_test.exs apps/singularity_runtime/test/singularity/runtime/upload_reconciliation_integration_test.exs apps/singularity_runtime/test/singularity/runtime/upload_session_lock_test.exs --seed 0
```

The integration route excludes unit cases. Run these complete Storage owners
through the ordinary unit route to close its29 excluded-unit gap:

```sh
mix test apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs apps/singularity_storage/test/singularity/storage/backup_restore_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs --seed 0
```

Independent restore and static checks each used direct arguments, separately:

```sh
mix singularity.test.restore
mix format --check-formatted
mix compile --warnings-as-errors
mix xref graph --format cycles --fail-above 0
```

## Final scoped results

Raw names below are relative to ignored `.devenv/`; SHA256 identifies the exact
full raw, including natural command termination. Excluded cases are not passes.
Counts from overlapping focused runs are not summed as distinct coverage.

| Route | Actual result | Raw suffix / SHA256 |
| --- | --- | --- |
| Final native GREEN5 | 15 executed,0fail;170.6s;natural0 | `phase5-task11-native-text-green5-live-native.log` / `295d234c7d62d8a0afe24f9b7f830fba3f95d2b09a16d5b3a17761a3ddd6ced9` |
| Retained Ingest/Runtime unit | Ingest27/0;Runtime139/0/2excluded;164 executed;natural0 | `phase5-task11-native-text-regression-unit-repair1-native.log` / `44552fe7a6b612c03c43e098d141c389cd8c89018146e6262e96ee9a7ee3650f` |
| Retained Storage unit | 56/0/27excluded;29 executed;natural0 | `phase5-task11-native-text-regression-storage-unit-native.log` / `32e5994d3acd03cc744b6581733614a54ac3e4f28c94f506f98d2bad3518e71a` |
| Retained integration | Storage235/0/29excluded;Runtime82/0/23excluded;265 executed;natural0 | `phase5-task11-native-text-regression-integration-native.log` / `453297f41cd3c27300f9ba4ff2acba754b2f71ec4f79565e9771002ed003298f` |
| Sole independent restore | V2 and V1 completed on separate empty destinations;Note search3/3;natural0 | `phase5-task11-native-text-regression-restore-native.log` / `a642e0df1e3ad19f13a71c9047c16a8ae9d79de4dd84c6ab5d6760302b2bbcd0` |
| Format | natural0 | `phase5-task11-native-text-format-check-native.log` / `bd77975aecb08a3cd575796bd0ef521e2269b14c560bb2d46215410f8efa52a4` |
| Compile warnings-as-errors | natural0 | `phase5-task11-native-text-compile-check-native.log` / `93557bcd5d8ca3d8a6332aee12dc96e179080ab6f18bb3fedef543ee1fc43e46` |
| xref | No cycles found;natural0 | `phase5-task11-native-text-xref-check-native.log` / `9edc37b006db12e8b3eec48f92dfa9a7ff9f9dadb6b55e8740f6652bcdeaed84` |

The Runtime23 integration-route exclusions are the upload_session_lock unit
module, covered by the retained unit route. Its two integration cases execute in
the integration route. The Storage29 exclusions are covered by the separate
four-owner unit route; its27 integration exclusions execute in integration.
The independent restore task emits existing dynamic migration-redefinition
warnings and Postgrex post-migration type reload diagnostics. Those diagnostics
are not failures or new compile warnings; they were not suppressed or repaired.
Expected lifecycle exception/killed probes likewise remain visible.

## Native assertions and compatibility limits

All15 final native cases reach their assertions: retained binary publication;
empty/plain/Unicode/BOM/CRLF/decomposed/Markdown byte preservation; identical
plain/Markdown bytes sharing one real object but independent declarations;
nonempty encrypted partial upload removed after genuine producer disconnect;
capability/principal-epoch/opaque-owner-epoch refusal for both MIME types before
publication; and four real repeatable-read seal/finalize boundaries for both
backup entrypoints/default2/explicit2/explicit3.

The native V2 case performs actual public backup of four completed originals,
observes logical version2, closes source infrastructure, restores the sealed
encrypted bundle into a genuinely empty destination with ordinary production
RestoreVault composition, then authenticates/unlocks and downloads EVERY
original byte-for-byte with immutable source identities, metadata and search.
It is separate from the unchanged sole independent V1/V2 restore task.

Focused sealed/finalizer contracts also passed60 tests (Storage29,Runtime31)
on unchanged production code; raw GREEN4 storage SHA256
`6249225f4a24ed687254f4f9100531851691fd638d6b0f14844be4af9124c73c`.
These same owners execute again in retained integration. Actual metadata/search/
audit/effect failure triggers prove transaction rollback, original physical
publication/stat/hash remain real, and successful retry/lost acknowledgement/
concurrent replay/later lawful revision use genuine receipt5. No fake positive
text metadata, synthetic completion/checkpoint or custody substitution.

## Failed attempts and repair accounting

Historical RED1/RED2/RED3 remain expected old-behavior assertions, not failed
repairs. RED3 ran59 sealed/finalizer cases with43 assertion failures before the
AssetRepository implementation; raw
`f6f27af44a1430e7fd7f889313abf619d4c701dce69f821821c1e0d836c3d967`.
No later GREEN overwrites RED or credits an assertion not reached in that run.

Four distinct ordinary failures each received one successful narrow Sol test
repair; unsuccessful repair rounds0/Astra0 for each:

1. Fixture lifecycle actor/supervisor cleanup race: wait for exact normal DOWN
   before owner cleanup, preserving original deadlines/assertions; complete63
   exporter/lifecycle tests then passed.
2. GREEN3 finalizer60 cases:8 backup assertions failed because its protocol
   fixture lacked existing backup.create authority. Provision only that exact
   test-owned capability assignment before upload/envelopes; assert authority in
   the same RR transaction. Existing unauthorized guard contract is unchanged.
   Production guard/policy is unchanged; complete60 later passed.
3. GREEN4 native15 cases: one producer-cleanup observer used SQL reserved alias
   grant (42601) before physical assertions. Rename only that alias; unchanged
   complete15 cases then passed in GREEN5. GREEN4 failure remains recorded.
4. First retained unit route: Ingest27/0,Runtime137/1/2excluded; natural2; raw
   `216fbec196d8599bb04f0c833ea5eb7804b38608a6feb85885c212e53d7e9409`.
   Its old unsupported-media fixture was text/plain, now intentionally supported.
   Use unsupported text/csv, retain exact error/no-scope/no-command assertions,
   and add two deterministic-clock positive grant-binding cases. No production
   repair, removal or weakening of the unsupported-format security contract.

An initial compound static launcher invocation failed naturally1 and receives
no format/compile/xref credit; each gate was rerun directly as recorded above.
Its private local incident receipt remains separate from source qualification.
All qualified runs retain ordinary empty disposable-database cleanup evidence;
the final xref post-cleanup raw SHA256 is
`3ef996741fe07d8884fca3dde497940c71cf3452ac0951cc50ab8eb92c22b934`.

## Independent source reviews and local code commits

Actual direct nonauthor SPEC `/root/task11_native_text_actual_spec` CLOSED PASS,
followed by NEW distinct fresh QUALITY `/root/task11_native_text_actual_quality`
CLOSED PASS. Each read all29 scoped files (26 code/test/helper paths and three
documents), complete tracked diffs, approved requirements and safe qualified raw
evidence through EOF. Each before/after review1 guard returned natural0 with
exact baseline HEAD, empty index, source/status/pins and owned-runtime-zero.
No actionable finding or frozen-scope change was established. Reviewers performed
no writes, VM, SQL, service or Git mutations and zero repair rounds.

The reviewed generation has78 entries (29 changed/new paths plus49 controls):
manifest SHA256 `9aedb72d111cf31acef4f402b272b239b5810d2a868648ab27cc8be8031a0fd2`,
status `83f038e14b5b44357c08ed7ae813e833cdc47f7e9b6bfedd7a2f3378e0946db4`.
Ignored immutable actual SPEC receipt SHA256
`be77aa1d3450ee3ff97c9b1012e0ff6af4d76b4a1ab35ec3455fdc1f8e64b5da`;
actual QUALITY receipt
`34f84de67f69e3cc3b10c4a794f5b64775ba4f1ec9e3ae3e2cf3f6e209426224`.
Unsafe invocation raw was never opened by reviewers and receives zero credit;
QUALITY did not independently reread or credit older unqualified intermediates.

Four explicit local commits preserve the combined qualified source:

| Commit | Scope | Paths |
| --- | --- | --- |
| `b36b9a98a91e7e69b563c86193b3d5f6133fef8a` | owned native fixture infrastructure lifecycle | 3 |
| `3b852c90b77ec47fa0a47b8b481b0bd53f24dc0d` | bounded incremental native text validation | 4 |
| `6fd422a6987121d02e54a8cc6395061880ec903f` | genuine atomic text publication and fail-closed backup cuts | 14 |
| `5f388ac88d5603b8c29df3a592d0843885a30912` | genuine publication/authorization/snapshot/V2 recovery witnesses | 5 |

The exact26 code/test/helper paths are reproducible without including later docs:

```sh
git diff --name-only 94efb34ae128298ab62bfbd7b77d387b882bbb62 5f388ac88d5603b8c29df3a592d0843885a30912
```

Before staging and after EACH commit, all26 reg1 code bytes, all25 common
GREEN5 native code bytes and all49 review controls matched their immutable
SHA256 manifests. Explicit staged/committed path sets and commit parent/subject
were verified, with empty index after each natural local commit. Derived
code/control/native-common manifest SHA256 identities respectively:
`482264eb1f70a1559466a46206a41c8607c8436fecdc5db9278ce19a6b01e048`,
`2248cbe53e5ee034b5b954a52ead9c702c3d0654e4709d23f5673fdfd042b8ba`,
`e232f942c945cc1efbe32176bb83420919cfc2acc5695f09b487ab972b54e1b2`.
No intermediate commit is claimed to have its own full README/native execution;
the combined unchanged source is what the recorded scoped gates qualified.
Old HEAD-specific guards remain historical and are not rewritten or run as
current guards after commits. No merge or publication occurred.

## Documentation closure and still-required work

These three prerequisite documents are synchronized only after actual source
review and local code commits. Final closure separately requires actual
documentation SPEC followed by NEW distinct fresh QUALITY, the explicit local
documentation commit and literal clean index/status with unchanged qualified
code, controls and reviewed documents. The immutable ignored handoff receipt
records those actual results; this text does not self-certify future actions.
The full permitted README gate must run on the eventual
phase candidate; Task10 historical full-green results do not qualify this code.
Next is Task11's separately written/reviewed native knowledge-V3 saga amendment,
then Task12 only after combined writer/restore qualification. DefaultV2 remains.
Task16 BOTH strict ALL-leases remains UNSATISFIED/UNWAIVED/BLOCKED_DESIGN; no
frozen custody/lease workaround is authorized. E2E remains NOT RUN and required
for final browser/release acceptance.
