# C4/C5 runner-isolation amendment

> For agentic workers: use subagent-driven-development and verification-before-completion.

Status: C4 accepted locally at source SHA-256
`73225571a14d707c1631dc544fb48bcfb568b4a22108f47eb7c8c9f8f6033bd4`;
append-only C5 accepted locally at final source `b8c6f60…07e42` after full84,
independent final reviews and cleanup. All C6 gates now pass; parent accepts
the complete C block and authorizes its dependent local commit. See the final
closure in `docs/verification/2026-10-09-document-runtime-outcomes-integration.md`.
Governing design:
`docs/superpowers/specs/2026-10-09-singularity-v0.2-document-c4-c5-isolation-design.md`.

Worktree: `.trees/v0.2-phase-2-import-extraction`.
Parent owns documents, Mix/database execution, reviews and commits. Implementer
owns only a newly authorized Runtime test append after C3 acceptance. Preserve
the complete existing 3,285-line amended C3 source SHA-256
`62631052619632b747892be4636474f4b824ebd3eaaad63501cc589c7bfba3c9`, including
the 2,790-line prefix SHA after the explicitly accepted C1 causation correction
`2fdc2bbe3aa6ce3a4ee8a717d790eb67c28a0c243a2495dfe189a6fa4713e108`.
No production/Vault/config/grant/migration/E2E change is authorized.

## 1. Review and C4 GO

- [x] C3 full unfiltered gate and exact alias cleanup pass; parent accepts C3.
- [x] Main reads this complete amendment and original full C4/C5/C6 blocks in
  `2026-10-09-singularity-v0.2-document-extraction-runtime-outcomes-integration.md`.
- [x] Independent Astra review clears exact queue amendment and formatting
  boundary. Record append-only C4 GO; no speculative production repairs.

Parent grants C4 TEST GO after personally reading the complete amendment and
original executable blocks, independent Astra amendment review, and C3's final
64-contract unfiltered pass plus exact cleanup. This authorizes only the 11-test
C4 append and exact queue amendment below, not C5 or production changes.

## 2. C4 exact amendment

Append the complete original `DocumentOutcomeRunnerIntegrationTest` module and
all 11 contracts. In its unlock/wake/snooze test only, immediately after
`id = String.to_integer(id)` and before `conf = Oban.config(name)`, add:

```elixir
queue = "document_c4_" <> Integer.to_string(id)
assert [["document_extract"]] =
         S.owner_query("SELECT queue FROM jobs.oban_jobs WHERE id=$1", [id]).rows
assert %{num_rows: 1} =
         S.owner_query(
           "UPDATE jobs.oban_jobs SET queue=$2 WHERE id=$1 AND queue='document_extract'",
           [id, queue]
         )
assert [[1]] =
         S.owner_query("SELECT count(*) FROM jobs.oban_jobs WHERE queue=$1", [queue]).rows
```

Change only that test's Basic initialization to `queue: queue`, retaining
`limit: 1`. Strengthen both its original fetched and resumed job patterns with
`queue: ^queue`, preserving every existing field/assertion:

```elixir
assert {:ok, meta} = Oban.Engines.Basic.init(conf, queue: queue, limit: 1)
assert {:ok, {meta, [%Oban.Job{id: ^id, queue: ^queue, attempt: 1} = fetched]}} =
         Oban.Engines.Basic.fetch_jobs(conf, meta, %{})
assert {:ok,
        {_meta,
         [%Oban.Job{id: ^id, queue: ^queue, attempt: 1, max_attempts: ^maximum} = resumed]}} =
         Oban.Engines.Basic.fetch_jobs(conf, meta, %{})
```

All surrounding original operations remain in order, including wake generation,
pending/progress checks, actual snooze and completion acknowledgements, unchanged
max_attempts, exact worker results, termination, and no terminal callbacks.

- [x] Parent formats only C4 append and verifies all existing 3,285 lines/hash.
- [x] Parent runs the full unfiltered Runtime integration file, seed 1208.
  Expected: 118 reported, 43 unit excluded, 75 integration executed, zero failures.
  Actual counts govern. Independently prove exact alias database/root cleanup.
- [x] Independent spec then quality review and parent C4 acceptance before C5 GO.

C4 final unfiltered run with diagnostic `--trace`: exit 0, 532.2 seconds,
118 reported, 43 unit excluded, 75 integration executed, zero failures. Both
independent Astra reviews pass with no Critical/Important findings. Exact alias
database/root cleanup, append format and frozen C3 checks pass. Parent accepts
C4 locally and grants only the nine-contract C5 append and exact amendment below.
Freeze all existing 3,540 lines with hash `7322557…33bd4` above; no earlier
source byte may change. Dependent source commit remains deferred to C6.

## 3. C5 exact amendment

After C4 acceptance, append the complete original
`DocumentOutcomePrivacyIntegrationTest` module and all nine contracts. In
`capture_private!/3`, after `id = String.to_integer(id)` and before
`conf = Oban.config(name)`, add the exact C4 queue block above, changing only the
literal prefix to `"document_c5_"`. Change its Basic initialization to
`queue: queue` and strengthen its original fetch pattern:

```elixir
assert {:ok, meta} = Oban.Engines.Basic.init(conf, queue: queue, limit: 1)
assert {:ok, {_meta, [%Oban.Job{id: ^id, queue: ^queue} = fetched]}} =
         Oban.Engines.Basic.fetch_jobs(conf, meta, %{})
```

Retain all original actual Executor acknowledgement, telemetry positive controls,
query-event exclusion, exact bounded metadata, private canonical positive
controls, untruncated metadata/log/error inspection, audit equality, handler
detachment and lease cleanup. Never replace the real executor or weaken a secret
assertion. Existing observability maps both queue names to `:unknown`.

- [x] Parent freezes and verifies complete accepted C4 prefix before appending.
- [x] Parent formats only C5 append and proves all earlier bytes unchanged,
  except the explicitly approved fixture and subsequent C2 evidence additions.
- [x] Parent runs unfiltered Runtime integration file, seed 1208. Expected:
  127 reported, 43 unit excluded, 84 integration executed, zero failures.
  Independently prove exact alias database/root cleanup; review spec then quality.

## 4. C6 amendment and final C-block acceptance

The preserved original C6 mandatory integration/regression/unit/xref commands and
coverage ledger remain required. Its whole-file `mix format` and whole-file
`--check-formatted` commands are superseded by append-only format/format-check
using `Code.format_string!/1` on the newly authorized segment, with exact prefix
hash assertions before/after. Never write a formatted frozen prefix.

Preserve 2,790-line and full accepted C3 hashes above, plus the accepted C4 prefix
when adding C5. Retain the older 2,191-line A/B check as additional proof, not the
only freeze check. Run only one shared Mix process; no borrowed service changes.
Record production and test hashes separately, actual commands/counts/exclusions,
all allocated exact database/root cleanup, child/handler cleanup, review findings,
repair attempts and no Vault work. Unexpected failures stop the bounded slice;
user-authorized Astra repairs must remain surgical and cannot weaken assertions.

Commit dependent C1–C5 test sources only after complete C-block acceptance and
independent spec/quality gates. Preserve unrelated dirty files. Task 12 and Phase
2 acceptance are separate from this test-block checkpoint.

## 5. C5 diagnostic and explicit fixture freeze exception

The design's C5 causation amendment supersedes the earlier absolute prefix
freeze only for this exact existing helper line:

```elixir
env = %{f.envelope | job_id: id, correlation_id: id, causation_id: id,
```

Replace its previous `causation_id: nil` with `id`; no other earlier byte changes.
In C5 `capture_private!/3`, immediately after `C.configure_runner!(f, options)`,
add the two provenance controls and strict codec round-trip:

```elixir
assert f.envelope.causation_id == f.envelope.job_id
assert [[nil]] ==
         S.owner_query(
           "SELECT causation_id FROM core.outbox_events WHERE id=$1 AND vault_id=$2",
           [Ecto.UUID.dump!(f.envelope.job_id), f.source.vault_id]
         ).rows
assert {:ok, encoded} = Singularity.Storage.Jobs.EnvelopeCodec.encode(f.envelope)
assert {:ok, decoded} = Singularity.Storage.Jobs.EnvelopeCodec.decode(encoded)
assert decoded == f.envelope
```

- [x] Apply exact helper correction and positive controls/codec round-trip; preserve all other
  accepted bytes and original assertions. Format only C5 append.
- [x] Record new full and 3,540-line hashes; reverse only the new exception in
  memory to recover `7322557…33bd4`. Prove A/B and C3 cleanup helper unchanged.
- [x] Re-run focused diagnostic for red/green evidence, then full unfiltered
  Runtime integration file (84 integration contracts). Exact cleanup after each.
- [x] Independent Astra spec then quality review; parent acceptance only after
  all gates pass. Do not count focused diagnostics as complete C5/C6 acceptance.

Corrected 3,540-line prefix SHA-256:
`6fcc670f335451040e705bb350b3559f2d7b752979ceff3fc908264692a91302`.
Final formatted 3,857-line source SHA-256:
`20e92bfa0b5d0c1bbeb2b918677658959d208beb434c1edfaa1f529a1130369c`.
Historical pre-detector checkpoint: parent verified the exact reverse-line hash and unchanged original A/B and C3
cleanup helper bytes. Focused diagnostic passed (17 executed, not full coverage);
unfiltered 84-contract gate and independent reviews remain pending.

## 6. C5 inspected-source detector strengthening

After the live `20e92bf…0369c` run terminates and exact cleanup is verified,
modify only C5 `capture_private!/3` immediately before its existing secrets list:

```elixir
inspected_source = inspect(f.plaintext, limit: :infinity, printable_limit: :infinity)
assert String.contains?(
         inspect(%{leaked_source: f.plaintext}, limit: :infinity, printable_limit: :infinity),
         inspected_source
       )
```

Add `inspected_source` immediately after existing `f.plaintext` in `secrets`.
Retain every existing secret, negative assertion, canonical positive control,
actual Executor event/acknowledgement, and cleanup. No earlier byte change.

- [x] Record current full run outcome and exact alias cleanup; its green result
  alone cannot clear the independent quality finding.
- [x] Apply only the above additive detector change and append-only formatting;
  prove unchanged amended 3,540-line prefix and every original C5 assertion.
- [x] Fresh unfiltered 84-contract run, exact cleanup, independent spec then
  quality re-review and parent C5 acceptance. C6 remains separately required.

Subsequent exact subprocess-evidence amendment is governed by
`2026-10-09-singularity-v0.2-document-tool-evidence.md` and its companion design.
It supersedes the C2/prefix freeze only for five additive test-body assertions;
all C1 helpers and C3 restoration helpers remain unchanged. Final source3883lines
SHA-256 `b8c6f602344926f4ec085edbd7b3a3b84173efb3d58654cc90ce20d31ba07e42`.
Final full84:558.9seconds,127reported43excluded84executed0fail, exact cleanup;
full-C independent SPEC/QUALITY clear. Parent C5 acceptance is local only; all
original mandatory C6 regression gates have since passed; the dependent local
commit is authorized in the final verification closure.

Historical pre-compatibility checkpoint: the pre-detector full run actually failed four missing bounded-event assertions
(84 integration executed, 554.2 seconds, exit 2). Independent Astra diagnosis
identifies an existing application GenericWorker name matcher defect outside this
test-only plan. Do not weaken assertions or repair production under C5 authority.
A separate bounded compatibility design/plan is required before production edits.
The additive detector source is now 3,865 lines, SHA-256
`68537ed710bff9559c70ac498f482b56e7aab2d59c01811e56b8ec27e3bfeb3f`;
amended 3,540-line prefix remains `6fcc670…91302`. C5 acceptance remains held.
