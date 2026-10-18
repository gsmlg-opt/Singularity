# Phase 5 Task 11: native V3 algorithm-metadata compatibility repair

Date: 2026-10-16. Status: design amendment; independent SPEC and NEW distinct
QUALITY review pending. No repair or Task6 acceptance is claimed.
Companion plan:
`docs/superpowers/plans/2026-10-16-singularity-v0.2-phase-5-native-algorithm-compatibility.md`.

## Authority and bounded outcome

This forward amendment supplements the 2026-10-15 native V3 saga design/plan,
Task6 only. Continuing development authority in AGENTS.md authorizes necessary
compatibility repair without renewed routine approval. It does not relax the
Vault freeze, immutable provenance, required verification or publication gates.
The earlier seven-path SourceGO remains historical; after this amendment's
actual SPEC then NEW distinct QUALITY pass, the parent records a new additive
SourceGO for the two additional paths below. Old seals/receipts are not rewritten.

Outcome: genuine, unchanged native bootstrap metadata can pass logical V3
preflight; both previously accepted and native spellings remain byte-exact
through staging/import. Unknown algorithm metadata remains fail-closed. This
does not add a cryptographic algorithm, change key interpretation, or enable V3
by default. E2E remains NOT RUN/deferred.

## Evidence and causal hypothesis

Worktree: `.trees/v0.2-phase-5-export-backup`; branch
`codex/v0.2-phase-5-export-backup`; HEAD
`fed04c1259450a6be3e8ce5bf6a9a1e03c9758c8`. Index is empty. The current
six-path dirty state belongs to the ongoing Task11 tests/helpers.

Four Task6 Native runs failed; none is reclassified. The latest complete Runtime
owner ran14 tests:12PASS/2FAIL in171.7s, natural exit2, seed215378,
warnings-as-errors. All prior12 cases passed. Actual authentication succeeded;
temporary fixed argument-free checkpoints narrowed both new failures to
`KnowledgePreflight.scalar_checks!/1`, before `ownership!/1`. The exact SQL
predicate was not directly observed. Root receipt
`.devenv/phase5-task11-v3-task6-astra1-failure.md`, SHA256
`75d395238bfecbbd755bd3a8e8f03bf13d360524a4134d6ffc1aa17e4703a4df`,
preserves source, commands, safe raw hashes, final guard and EMPTY PG residual.
A separate read-only Sol SQL/type/function-visibility audit found no concrete
execution-mechanics defect; that is not live catalog proof.

Astra's bounded source diagnosis establishes this deterministic incompatibility:

1. Runtime fixture calls the actual `BootstrapOwner.run/2`.
2. `apps/singularity_runtime/lib/singularity/runtime/bootstrap_owner.ex`
   builds `vault_key_version.algorithm: "aes-256-gcm"`.
3. `apps/singularity_storage/lib/singularity/storage/postgres/identity_repository.ex`
   inserts that command using
   `apps/singularity_storage/lib/singularity/storage/schema/core/vault_key_version.ex`.
   The string is not normalized. Released migration
   `20260718000200_create_identity_and_vault_tables.exs` permits this text.
4. `apps/singularity_storage/lib/singularity/storage/backup/exporter.ex`
   selects/encodes text unchanged. Logical V3 preserves the V2 prefix.
5. `KnowledgePreflight.scalar_checks!/1` instead accepts only
   `algorithm='aes_256_gcm'` for `core.vault_key_versions`.
6. Established synthetic V3 fixtures use the underscore spelling, so their
   passing structural contracts did not cover the normal bootstrap spelling.

A focused preflight regression must reproduce the hyphen rejection before the
production edit. Full native saga success remains unverified until executed.

## Alternatives and selected design

1. Recommended: accept exactly the two established metadata literals in this
   single V3 scalar predicate. Preserve every incoming byte and every other
   predicate. Smallest additive compatibility boundary; requires explicit
   positives and malformed/adjacent negatives.
2. Normalize or replace bootstrap/source/wire values. Rejected: would conceal
   the actual native path, change frozen behavior or violate exact source-row
   preservation. No source metadata patch is authorized.
3. Remove the algorithm predicate or accept arbitrary names. Rejected:
   unnecessary expansion and loss of fail-closed validation.

The only production edit is:

```elixir
{"core.vault_key_versions",
 "generation>0 AND state IN ('pending','active','retired') AND algorithm IN ('aes_256_gcm','aes-256-gcm')"},
```

Generation/state checks remain identical. No case folding, trimming, alias
function, data migration or algorithm rewrite is introduced. Domain-version,
dedup-wrapper and asset-envelope rules continue to accept only the existing
underscore spelling. Their genuine producers already use
`Singularity.Storage.Crypto.KeyWrapper`'s `:aes_256_gcm` serialization and
the actual AssetRepository validates that exact envelope spelling.

## File ownership and preservation

Additional production/test scope, and nothing adjacent:

- `apps/singularity_storage/lib/singularity/storage/backup/knowledge_preflight.ex`:
  the one predicate above only. Baseline SHA256
  `b05f0b5e61be7ba5a2c3ae4da6bbcfc292627fcc73ca689978294fd4b0bf8ff9`.
- `apps/singularity_storage/test/singularity/storage/backup/knowledge_preflight_test.exs`:
  additive algorithm contracts using its established authenticated transform,
  typed staging, validation, rollback and private-storage cleanup harness.
  Strengthen existing reject helper to assert retryable=false; retain every old
  assertion/test. Baseline SHA256
  `8426e9865621af5340bb5ae22690ac59a5e978fa61719645ea877b11a2017ee6`.

Existing Task6 scope, for removal of temporary diagnostic tracing only:

- `apps/singularity_runtime/test/support/knowledge_backup_restore_fixture.ex`.
- `apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs`.

Oracle and synthetic fixture are unchanged. The Task5 exact inverse filters must
still recover both accepted archives. Frozen56, prerequisite26, controls49,
native-common25, roles, migrations and all other existing dirty work remain
unchanged. Temporary tracing is removed before final qualification; bounded
existing auth/import/hook diagnostics may remain. No new trace or SQL logging.

This is knowledge restore validation of opaque legacy owner metadata, not Vault
feature work. Bootstrap, Vault APIs/semantics/tests, crypto, custody, keys,
passwords, policies/capabilities, DownloadLease, schema/wire, defaults, V1/V2
behavior, provenance and production data remain unchanged. No merge, push,
version, tag, release, deployment, activation or backfill.

## Verification and acceptance

1. After actual document SPEC then NEW distinct QUALITY pass, add the structural
   tests first. A focused whole-owner preflight run must causally fail the native
   hyphen positive on the old predicate; compile/absence failures are not RED.
   The underscore positive and malformed/adjacent denial cases must pass.
2. The two accepted spellings independently stage and validate without altering
   complete expected rows. Verify all38 staged projections, row counts,
   exact algorithm text, rollback, unchanged canonical source and owned cleanup.
   This remains a synthetic structural contract, never native custody proof.
3. Reject empty, unknown, other-cipher, case-changed and whitespace-suffixed
   names with nonretryable backup_invalid and empty details/clean rollback.
   Hyphen remains rejected separately for domain versions, dedup wrappers and
   asset envelopes. Do not weaken or skip existing checks.
4. Apply the one production predicate edit, remove the temporary diagnostic
   checkpoint probe, and run the complete preflight owner plus retained V3
   import contracts. Require GREEN and natural closure/EMPTY PG residual.
5. Run the complete Task6 Runtime owner with retained search and storage restore
   regressions. Require actual fourteen-case native owner success, exact38
   pre-rewrap comparisons (only established locked transformation), native
   rewrap/custody/typed plaintext, original-byte/public search proof and real
   deterministic recovery. Subsequent failures enter diagnosis, not acceptance.
6. Parent exclusively owns formatting, Native/SQL/maintenance execution; ALL
   other actors/commands CLOSED before every LIVE interval. Only exact-session
   empty polls/commentary during LIVE. Capture exact commands, results, source
   hashes, counters and cleanup. No unsafe credential-bearing historical log.
7. Actual combined source SPEC followed by NEW distinct fresh QUALITY must
   cover this repair and Task6 before acceptance. Then continue Task7, not
   Phase5/release acceptance. Small local commits follow the Task13 combined
   qualification boundary; no publication is implied.

Task16 strict BOTH/ALL leases remains UNSATISFIED/UNWAIVED/BLOCKED_DESIGN.
Repair counters at authoring: actual Native failures4; Sol code repairs0;
Astra code-repair validations0; completed Astra diagnostic runs1. Its gate is
evidenced SOL_IMPASSE, not a fabricated two-Sol-repair threshold.
