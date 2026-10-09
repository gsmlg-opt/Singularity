# Task 14 empty-original authentication qualification

## Scope and status

This is a bounded Task 14 repair in the existing Phase 2 worktree. It is
not Phase 2 acceptance, a release gate, publication, or deployment evidence.
Baseline source: `26e16a5716dec8c3df835a7ff8e1d258249cde58` on
`codex/v0.2-phase-2-import-extraction`.

No E2E is authorized. Vault behavior, custody issuance, keys, capabilities,
storage codecs, migrations, and worker-empty authentication are unchanged
by the proposed repair. The original untracked C integration plan is excluded.

## Characterization before edits

All commands ran in the Phase 2 worktree with
`MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps`.

```sh
devenv shell -- mix singularity.test.integration \
  apps/singularity_runtime/test/singularity/runtime/document_api_test.exs \
  apps/singularity_storage/test/singularity/storage/postgres/document_repository_test.exs \
  apps/singularity_runtime/test/singularity/runtime/note_reads_test.exs \
  apps/singularity_runtime/test/singularity/runtime/asset_download_test.exs \
  --seed 1208
```

PASS, session `67272`, exit 0. Storage: 18 tests, 0 failures (9.4 seconds).
Runtime: 28 reported, 22 excluded, 6 executed, 0 failures (4.2 seconds).
Total: 24 executed. Observed database
`singularity_test_bdf2855b0ed2617944e010ee` was independently absent
(`pg_database` count 0), and its exact storage root
`/tmp/singularity/integration/bdf2855b0ed2617944e010ee` was absent after exit.

```sh
devenv shell -- mix test \
  apps/singularity_runtime/test/singularity/runtime/document_api_test.exs \
  apps/singularity_runtime/test/singularity/runtime/note_reads_test.exs \
  apps/singularity_runtime/test/singularity/runtime/asset_download_test.exs \
  apps/singularity_runtime/test/singularity/runtime/download_lease_test.exs \
  apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs \
  --seed 1208
```

PASS, session `58687`, exit 0. Runtime: 59 reported, 15 excluded,
44 executed, 0 failures (3.8 seconds).

## Root cause and evidence boundary

Read-only Astra investigation confirmed that `Read.authenticate/3` skips
the reader when the canonical source size is zero. Computing the empty
SHA-256 digest in memory does not prove the retained ciphertext exists or
authenticates. Custody issuance unwraps database key material without opening
that ciphertext. Generic request `read(:all)` is deliberately denied, and the
existing worker empty-source operation is worker-only.

The bounded repair will use a separate request-only operation through the
existing authenticated storage reader. Request reader ownership remains its
existing monitored lifecycle; worker hard-kill/consumer-death guarantees are
not claimed for request leases.

## Independent design review

Parent read the complete 125-line design and 293-line draft plan. An independent
Astra review found no production-contract blocker. Before test-only execution,
parent removed unavailable `unbuffer` commands, restored the original Task 14
storage repository gate, and clarified exact-type and exception/privacy controls.

## Additional unchanged custody characterization

```sh
devenv shell -- mix singularity.test.integration \
  apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs \
  --seed 1208
```

PASS, session `55663`, exit 0: 14 reported, 5 excluded, 9 executed,
0 failures (8.6 seconds). Database
`singularity_test_6f858e83f74b03dc2256fd4b` independently absent (count 0);
`/tmp/singularity/integration/6f858e83f74b03dc2256fd4b` absent.

## Actual API regression RED, before production edits

```sh
devenv shell -- mix singularity.test.integration \
  apps/singularity_runtime/test/singularity/runtime/document_api_test.exs \
  --seed 1208
```

Initial session `91667` exited 2: 14 reported, 5 excluded, 9 executed,
2 failures (5.8 seconds). Missing ciphertext reproduced unexpected success;
corrupt ciphertext encountered a fixture `File.write!` permission failure.
The latter is not valid regression RED: finalized test objects are read-only.
Astra added an explicit chmod only for that fixture object before corruption.
No production file changed. Database
`singularity_test_bfcd051292e9fa31dfc832cd` independently absent (count 0);
`/tmp/singularity/integration/bfcd051292e9fa31dfc832cd` absent.

Retry session `50677` exited 2: 14 reported, 5 excluded, 9 executed,
2 assertion failures (6.2 seconds). Both required negative cases reached the
actual API/custody/PostgreSQL/filesystem path and incorrectly returned
`{:ok, %{byte_size: 0, chunk_count: 0, read_chunk: function}}`:

- Missing ciphertext expected `{:error, :not_found}`.
- Corrupt ciphertext expected `{:error, :integrity_failure}`.

The valid empty control and existing integration cases passed. These two
assertion failures establish the defect independently of the absent new lease
function. Database `singularity_test_6f4d69437ddd2146412f7a01` independently absent
(count 0); `/tmp/singularity/integration/6f4d69437ddd2146412f7a01` absent.

Production repair failed rounds: 0. The first fixture diagnostic retry above
does not represent a failed production repair round.

## Focused contract RED

```sh
devenv shell -- mix test \
  apps/singularity_runtime/test/singularity/runtime/download_lease_test.exs \
  apps/singularity_runtime/test/singularity/runtime/document_api_test.exs \
  --seed 1208
```

Session `5428`, exit 2: 55 reported, 14 excluded, 41 executed,
18 failures (1.5 seconds). Three new Read assertions detected the skipped
empty authentication or unreleased delivery lease; 15 new lease contracts failed
because the new function was absent. Existing controls passed. This new-function
RED supplements, and does not replace, the meaningful API negative-case RED.
Parent then granted production edits restricted to the two approved files.

The new fixture registers exact ExUnit temporary-root cleanup before creating
its storage object. Its canonical source size/digest and trusted object metadata
are prepared before immutable Document insertion; no existing Document pin is
modified. Existing nonempty and worker test bodies are preserved.

## First production GREEN and independent source reviews

The first bounded production repair changed only `documents/read.ex` and
`download_lease.ex`. It added the request-only empty operation and zero-byte
composition without editing worker guards, issuance, storage, or migrations.
Tests were unchanged from their observed RED except later formatting-only wraps.

Focused unit command above: session `42719`, exit 0, 55 reported,
14 excluded, 41 executed, 0 failures (1.4 seconds).
Actual API integration command above: session `71168`, exit 0, 22 reported,
8 excluded, 14 executed, 0 failures (10.5 seconds). All missing/corrupt,
valid-empty, source-Asset deletion, tombstone, cross-owner, revoked-session,
and immutable-digest controls passed. Database
`singularity_test_912f618af18305a63b54ce79` independently absent (count 0);
`/tmp/singularity/integration/912f618af18305a63b54ce79` absent. The exact observed
ExUnit corrupt-object temporary root from the initial fixture failure was also
absent after these cleanup-armed tests.

Independent fresh Astra SPEC review: CLEAR, no actionable findings. Independent
fresh Astra QUALITY review: CLEAR on the final formatted production/test source,
no actionable findings. Parent read the complete changed test and production
diffs and verified unchanged existing worker/nonempty assertions and guards.

Initial changed-file formatting check `5056` exited 1 for five new test wrapping
sites only. Parent applied those line wraps without changing assertions or
production; check `30900` then exited 0. No whole-file mechanical rewrite or
frozen C-source formatting was performed.

## Final scoped unit gate

The five-file scoped unit command from characterization was rerun on final
formatted source: session `41964`, exit 0, 86 reported, 23 excluded,
63 executed, 0 failures (3.5 seconds). Integration exclusions are explicit,
not counted as executions. This command was:

```sh
devenv shell -- mix test \
  apps/singularity_runtime/test/singularity/runtime/document_api_test.exs \
  apps/singularity_runtime/test/singularity/runtime/download_lease_test.exs \
  apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs \
  apps/singularity_runtime/test/singularity/runtime/asset_download_test.exs \
  apps/singularity_runtime/test/singularity/runtime/note_reads_test.exs \
  --seed 1208
```

## Final qualification

### Final scoped integration gate

```sh
devenv shell -- mix singularity.test.integration \
  apps/singularity_runtime/test/singularity/runtime/document_api_test.exs \
  apps/singularity_storage/test/singularity/storage/postgres/document_repository_test.exs \
  apps/singularity_runtime/test/singularity/runtime/note_reads_test.exs \
  apps/singularity_runtime/test/singularity/runtime/asset_download_test.exs \
  apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs \
  --seed 1208
```

PASS, session `23111`, exit 0. Storage: 18 executed, 0 failures
(9.3 seconds). Runtime: 53 reported, 30 excluded, 23 executed, 0 failures
(17.5 seconds). Total integration executions: 41. Final scoped unit plus
integration executions: 104, with 0 failures. Database
`singularity_test_7341d33191545f1057244918` independently absent (count 0);
`/tmp/singularity/integration/7341d33191545f1057244918` absent.

### Compilation and final source scope

`devenv shell -- mix compile --warnings-as-errors`, session `13689`, exited 0.
Final changed-file formatting check `30900` exited 0. `git diff --check` passed.
The ExUnit integration module temporary directory has no remaining files
(`rg --files --hidden` returned no matches, expected exit 1).

Verified production/test hashes:

| File | SHA-256 |
| --- | --- |
| `documents/read.ex` | `d03d60b6c9241c3b7a1b2c116c648d8cb30ede06ab7416103237e1bdf53cdeb3` |
| `download_lease.ex` | `3ecce1470e11d506435d8213faa1b2c0c012ffb360cb3e4b82f67bdd5277636e` |
| `document_api_test.exs` | `2019fad0ab5534a27faa6b2cb713718807357bca44c8390f663ab993fa687eba` |
| `download_lease_test.exs` | `81096c858e57401943f583a4db239e439bffe488b6352cae1c92e9c55be3619c` |

The original untracked C plan remains byte-identical at
`350a655703264603c4af8cea7fbbdba96126b22e2ee52f4e23bef6c561234281`.
Frozen C Runtime test remains
`b8c6f602344926f4ec085edbd7b3a3b84173efb3d58654cc90ce20d31ba07e42`;
Task 13 supervised-restart test remains
`3fe960f0afb64f5253626bafbd3acda5b6a04d14c9c884c2b3dc380401f9aed9`.
Root main remains clean at `e866990fc0ee8682d139d70da9cbf5aff9b2ae2b`.

`devenv shell -- mix xref graph --format cycles --fail-above 0`, session
`86974`, exited 0 with `No cycles found`.

## Bounded verdict and remaining release boundary

Independent final Astra documentary/source acceptance audit: CLEAR. It read all
three bounded documents and the full four-file diff, verified every recorded
source/frozen hash and root-main identity, and found no actionable evidence gap.
Execution and teardown observations remained parent-owned terminal evidence.

PASS: Task 14 empty-original source repair is locally accepted. The first
production repair passed all scoped regressions and reviews; failed production
repair rounds remain 0. Changed source is exactly two production files and two
test files, plus this evidence and its bounded design/plan. No migration was
added or edited. No Vault feature work, custody issuance/key/capability change,
storage change, worker-empty behavior change, or assertion weakening occurred.

No Phase 2/release acceptance, E2E, merge, push, publication, or deployment is
claimed. The complete Phase 2 README gate is not run here; Task 15 acceptance
remains open, and the user's E2E exclusion is preserved. This local scoped
acceptance does not authorize later-phase activation or external publication.
