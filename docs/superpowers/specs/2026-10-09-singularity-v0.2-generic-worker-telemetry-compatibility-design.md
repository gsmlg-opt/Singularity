# GenericWorker telemetry compatibility repair

Status: accepted locally under standing user approval. Independent Astra plan,
specification and quality reviews cleared the exact scope. Parent observed
27-test RED (nine canonical failures), granted exact production GO, then observed
27-test GREEN and unchanged full84 real Executor integration GREEN with exact
cleanup. Broader C6/Phase2/release acceptance remains separate.

## Evidence and decision

The full C5 gate at Runtime test SHA-256
`20e92bfa0b5d0c1bbeb2b918677658959d208beb434c1edfaa1f529a1130369c`
executed 84 integration contracts and failed four missing derived-event assertions.
Actual Oban events were captured, but retry/failure events were absent. Installed
Oban 2.24 normalizes worker names through `Oban.Worker.to_string/1`, removing the
`Elixir.` prefix. Executor metadata copies the stored name unchanged. Runtime's
matcher accepts only the module atom and prefixed string. This is an application
compatibility defect, not an upstream dependency defect or observed content leak.

Options:

1. **Recommended:** add exactly `"Singularity.Storage.Jobs.GenericWorker"` to
   the existing closed accepted list. Retain both existing representations.
2. Normalize arbitrary prefixes: rejected because it broadens accepted identity
   and adds unnecessary transformation.
3. Fabricate prefixed C5 telemetry or waive missing events: rejected because it
   evades the real Executor boundary and weakens required assertions.

## Authorized scope

- Production: only `generic_worker?/1` in
  `apps/singularity_runtime/lib/singularity/runtime/observability/telemetry.ex`.
- Tests: new `apps/singularity_runtime/test/singularity/runtime/generic_worker_telemetry_test.exs`.
- These two design/plan documents and the current verification record.

Preserve worker/attempt/queue metadata precedence, numeric measurements, event
names, exact bounded output fields, queue allowlist, failure isolation, and every
other production byte. No new dependency, configuration, migration, public API,
custody/key/capability/Vault behavior, activation, E2E, push, release or deployment.
Existing mixed-operation telemetry tests remain untouched.

The pending C1-C5 Runtime file remains byte-identical at
`68537ed710bff9559c70ac498f482b56e7aab2d59c01811e56b8ec27e3bfeb3f`.
Its original A/B, accepted C3 cleanup helpers and approved C4/C5 amendments remain
frozen. No whole-file formatting is allowed for that file.

## Acceptance

First prove canonical-worker cases fail with unchanged Telemetry SHA-256
`ce4d557f7d03dfb770af689a2e3fd782fbea91adb4fc95c9395b54cba0a21458`.
Existing representations and negative controls must pass. Add the exact alias,
then require all focused tests green, independent specification and quality
reviews, and the unchanged full 84-contract Runtime integration gate. Follow with
all original C6 mandatory scoped regressions before accepting/committing C1-C5.

The compatibility source/test may form a separate small commit only after its
focused verification and independent reviews; do not stage dependent C1-C5 tests
prematurely. Passing these gates is not Phase 2 or release acceptance. All alias
databases and roots require independent exact-identity cleanup checks after exit.
