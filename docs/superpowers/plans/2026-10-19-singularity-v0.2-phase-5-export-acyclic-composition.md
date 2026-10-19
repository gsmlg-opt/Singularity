# Phase 5 Task16 Acyclic Export Composition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development`
> (recommended) or `executing-plans` task-by-task. The parent allocates exclusive
> file ownership, closes authors before gates, and owns native validation.

**Goal:** Implement the existing Task16 export ownership design without the
planned Export/Artifact file cycle, preserving every acceptance obligation.

**Architecture:** Export constructs one fixed local work/2, then calls
Artifact.generate/3. The eventual Writer owner invokes it once with Artifact's
private Leases-wrapped runtime. Artifact never refers back to Export.

**Tech Stack:** Existing Elixir/OTP umbrella, Task.Supervisor, Ecto/PostgreSQL,
Spool/Writer/ExportRead and native export-request leases. No dependency,
migration, public operation or infrastructure addition.

---

## Authority, prerequisites and execution boundary

Read the [forward design](../specs/2026-10-19-singularity-v0.2-phase-5-export-acyclic-composition-design.md)
and original [Task16 plan](2026-10-12-singularity-v0.2-phase-5-export-artifact-ownership.md).
This is a delta plan, not a replacement for original Steps1–8. The parent must
obtain independent DESIGN SPEC then NEW distinct DESIGN QUALITY for these exact
two documents before implementing the amended seam. Routine human reapproval
is superseded by continuing authority; unrun gates are not accepted.

Use `.trees/v0.2-phase-5-export-backup`, branch
`codex/v0.2-phase-5-export-backup`; inspected HEAD is
`6f1ddc788b9f68169ca4d8e88a4522660e926c1e`. Preserve pre-existing Api, Export,
Handle, filesystem and test work. Native prerequisite is qualified at
`6c7f867309470e23e8f34c06a8f53af0b496d48d`; Step7a is already accepted at
`9f91c97eb392b4c49c888ed31795d520d15bb8dd`. Neither is Task16 acceptance.

The parent retains old raw logs/guards/manifests unchanged, then records a new
derived candidate manifest and guard covering these docs and actual source.
Record exact source and staged scope before each exclusive author window.
No overlapping authors on one file. No author runs VM, SQL or service commands
while the parent's single native validation window is open.

### Work ownership

| Exclusive owner | Files and responsibility |
| --- | --- |
| Orchestration author | `apps/singularity_runtime/lib/singularity/runtime/knowledge/export.ex`: fixed run-local closure, private materialize, real source composition; `apps/singularity_storage/lib/singularity/storage/knowledge_export/repository.ex`: original exact Document selector only |
| Artifact author | `apps/singularity_runtime/lib/singularity/runtime/knowledge/export_artifact.ex`: owner, companion, fixed Leases, generate/3 invocation and stored-binding/native checks; no Export reference |
| Test author, before production writers | `apps/singularity_runtime/test/singularity/runtime/knowledge_export_api_test.exs`, `apps/singularity_runtime/test/singularity/runtime/knowledge_export_artifact_test.exs`, `apps/singularity_runtime/test/singularity/runtime/knowledge_export_custody_live_test.exs`: additive contracts and actual lifecycle/native witnesses; new `apps/singularity_web/test/singularity/architecture/knowledge_export_composition_contract_test.exs`: fixed composition direction, mutation contracts and causal RED before production edits |
| Attribution author, after production writers close | `apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs`: original Step7b with reviewed formatted P5-A2 and preserved native-text/Task8 inverses |
| Parent | Original Step6 Api/config/application additions, startup tests, formatting, derived guard/manifest, all execution/review/evidence and explicit local commits |

The parent may combine nonoverlapping assignments, never concurrent edits to
the same test/source file. Files not changed by this amendment remain governed
by their original task, including ArtifactDirectory and previously qualified
Snapshot/ExportRead/Spool/Writer/native source.

## Task A: strengthen request and composition contracts first

- [ ] Add public-facade canaries alongside existing unknown-key cases, preserving
  every existing assertion. Reject each key both alone and alongside valid
  `include_tombstones: false`: `:materializer`, `:work`, `:callback`, `:module`,
  `:function`, `:args`, `:mfa`. Values include a function sending a canary and
  `{__MODULE__, :canary, []}`; the configured callback and function must never run.

```elixir
for key <- [:materializer, :work, :callback, :module, :function, :args, :mfa] do
  test "caller-selected #{key} cannot select export work" do
    observer = self()
    canary = fn _, _ -> send(observer, :unexpected_work) end
    config = %{export_knowledge: fn _, _ -> send(observer, :unexpected_composition) end}

    for value <- [canary, {__MODULE__, :canary, []}],
        options <- [%{unquote(key) => value},
                    %{unquote(key) => value, :include_tombstones => false}] do
      assert {:error, :invalid} = Api.export_knowledge(config, session_dto(), options)
      refute_received :unexpected_composition
      refute_received :unexpected_work
    end
  end
end
```

  `session_dto/0` is the existing owning Api test's strict DTO helper; preserve
  its binding. These canaries may already be GREEN because Core options rejects
  unknown keys;
  record characterization honestly, not an invented RED.

- [ ] Create the composition architecture owner. Parse source with
  `Code.string_to_quoted!/1`; assert exactly one literal work/2 construction in
  run/3 with the specified arguments and one fixed generate/3 call. Require
  private materialize/4, no exported materialize/4, no options-taking generate
  compatibility clause, no reverse Export alias/import/qualified references,
  and no `apply`/MFA/module-dispatch workaround in Artifact. Count executable
  AST, not documentation occurrences. Require sole work invocation inside the
  eventual owner generation path and no retained work in delivered/closed state.
- [ ] Add in-memory negative mutations for replacing the literal with
  runtime/config work lookup, adding a reverse Export call/alias, exposing
  materialize, adding another generate clause, invoking work in the companion,
  or retaining it in delivered state. Each must fail its intended assertion.
  Source/AST checks supplement—not substitute for—the actual lifecycle witnesses.
- [ ] Parent runs both whole owners before production edits. The new composition
  owner must fail for missing run/materialize/owner composition; existing Api
  cases must retain their actual outcome. Preserve raw failures and source pins.

## Task B: implement the fixed one-way seam

- [ ] Orchestration author implements the existing run validation/native scope
  and uses precisely this internal composition after option normalization:

```elixir
work = fn operation_runtime, operation ->
  materialize(operation_runtime, session, normalized_options, operation)
end

ExportArtifact.generate(runtime, session, work)
```

  Change the original Step5 signature to `defp materialize(runtime, session,
  normalized_options, operation)`. Keep the remaining public orchestration
  methods, fixed configuration, exact Repository selector and actual
  Snapshot/Spool/ExportRead/Writer implementation from original Step5. The
  closure is not loaded from any map or message and cannot be caller-selected.
- [ ] Artifact author implements `generate(runtime, session, work)` as the sole
  generate/3 meaning. No /4, default, options compatibility or materializer
  configuration is introduced. After companion records envelope/owner/ref,
  the owner constructs the existing fixed adapter copy:

```elixir
operation_runtime =
  runtime
  |> Map.put(:custodian, {ExportArtifact.Leases, lease_context})
  |> Map.put(:authenticated_reader, {ExportArtifact.Leases, lease_context})

result = work.(operation_runtime, operation)
```

  `lease_context` and `operation` are the private structures already required
  by original Steps3–4, created by Artifact, not request input. Retain the
  genuine authorization bundle. Invoke once in the owner and drop work before
  entering delivery/closed loops, including error paths; never retry it.
- [ ] Keep Artifact's stored-binding checks local and native authority checks
  unchanged. Do not call Export validation/result/binding helpers from Artifact.
  Preserve exact after-COMMIT `ExportArtifact.accept_completed/2` in the private
  materializer; it still owns final prepared/accepted handoff semantics.
- [ ] Parent reads both whole changed files and their exact diff; reconcile
  signatures before testing. Neither author adds test materializer hooks,
  dynamic dispatch, shared-global state or a fake completed Writer.

## Task C: prove actual composition, not only source direction

- [ ] Retain and complete the existing artifact lifetime RED cases with real
  Spool/Writer. Demonstrate that the successful requester exits while entries
  and all manifest chunks remain readable; inspect only the known owner's
  matching Writer ledger metadata and assert `:ets.info(ledger, :owner)` equals
  the eventual owner PID, not requester or companion.
- [ ] Exercise request death inside capture and before completion, blocked
  originals, Writer errors, owner/companion death, deadlines and authority loss.
  Observe exact monitors/barriers, no sleeps; preserve foreign sentinels and
  all no-handle/no-plaintext assertions. Synthetic authority/simulated COMMIT
  tests remain labeled synthetic.
- [ ] Add genuine SQL/custody composition witnesses: real snapshot COMMIT before
  Writer.open/original reads, no transaction during binary materialization or
  delivery, final native scope COMMIT before prepared acceptance, commit failure
  denies publication, exact immutable source revalidation and final authority
  denial. Use existing trusted repository/native delegate seams, never work
  injection or an altered materializer.
- [ ] Complete original native ALL-leases tests through actual Export.run:
  timeout/late issuance, companion hard death before recording, pre-forward and
  known-forwarded deaths, plus retained owner/requester races. Use genuine
  `export_lease/2` request modes, native public read denial and owned-file
  cleanup; DOWN or primitive-only success is insufficient. Retain failures and
  counters rather than weakening assertions or treating a timeout as cleanup.
- [ ] Complete all original actual-supervisor startup serialization witnesses;
  fixed guard covers native start return/registration, and false infrastructure
  still has no root/guard effects. This amendment changes none of that protocol.

## Task D: implement Step7b with exact forward reconciliation

- [ ] Do not redo accepted Step7a. Extend current normalization, preserving its
  native-text inverse, rather than replacing it with the old plan's snippet.
  Stage strict P5-A5 inverse/seven Task16 additions before Task8/historical
  inverse processing. Keep raw Task8 positive tuple guards before strict Task16
  stripping and the one Task8 inverse; retain all old negative routes/digests.
- [ ] In the P5-A2 tuple use the original Step6 literal with **only** this exact
  substitution; all other bytes, including final newline, stay identical:

```elixir
    do:
      knowledge_export_call(config, :read_knowledge_export_chunk, session, [handle, path, index])
```

  It replaces the single original one-line `do: knowledge_export_call(...)`
  for configured read_knowledge_export_chunk/5, not any other helper call.
  Freeze P5-A2 at 2176 bytes, block SHA-256
  `1cfcdcb92693b92b2409afabe85319f60966dfbf00adb7765eae4a4a014d2b7f`,
  context SHA-256
  `cc309bdb2211654f4e571a914dd5e12f790d6a66b58b5fc8b6daf97c9ed5f11a`.
  Context remains original Before + formatted block + original After.
  Historical 2170-byte block/hash
  `a42d2e03a9b424de2267a5c80d4853fca8cf13c3d39e7cbef1b18bc4702c5224`
  and context `002c4066ea063568421c00649d1a2a8f0cd7a0a062ffa58787cc8fc7e3a081f0`
  remain historical, not accepted alternative bytes.
- [ ] Verify unchanged P5-A1 hash
  `bafbd33be306cb42c49cc94eb8ceb15e22c74cac3373d6fc0f0b982ccabee525`
  and the two-block inverse receipt recovering original Api hash
  `8557685c2415c5ee3b30e33be6dfaab6e4ee25b0772bb3123a92384a914c33b4`
  before adding the remaining original blocks. Five other additions and startup
  remain independently subject to their exact literal/context and mutation
  gates; this reconciliation gives them no blanket allowance. Any further
  formatter delta needs its own exact reviewed forward receipt.
- [ ] Preserve original baseline files/manifests and all native 56-file inverse
  proofs. New source/doc candidate pins and guard wrappers receive fresh names;
  never rewrite earlier evidence to hide changed candidates.

## Task E: parent verification, review and bounded handoff

Close all source authors before execution. Use the parent's private PostgreSQL
wrapper/current environment and fresh raw logs, with the established immediate
own residual check after each native command. The commands below specify the
whole test owners, not line filters; the parent supplies its already qualified
environment without starting a competing VM or service.

```sh
mix test apps/singularity_runtime/test/singularity/runtime/knowledge_export_api_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_artifact_test.exs apps/singularity_runtime/test/singularity/runtime/application_test.exs apps/singularity_runtime/test/singularity/runtime/note_markdown_source_export_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_web/test/singularity/architecture/knowledge_export_composition_contract_test.exs apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs --seed 215378 --warnings-as-errors
mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_export_artifact_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_snapshot_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_custody_live_test.exs --seed 215378 --warnings-as-errors
mix test apps/singularity_runtime/test/singularity/runtime/knowledge_export_snapshot_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_read_test.exs apps/singularity_storage/test/singularity/storage/knowledge_export/spool_test.exs apps/singularity_storage/test/singularity/storage/knowledge_export/writer_test.exs apps/singularity_storage/test/singularity/storage/knowledge_export/artifact_directory_test.exs --seed 215378 --warnings-as-errors
mix format --check-formatted
mix compile --warnings-as-errors
mix xref graph --format cycles --fail-above 0
git diff --check
```

- [ ] Require zero failures for each applicable whole owner; report registered,
  executed and excluded cases separately. An integration-tagged assertion not
  executed by pure mix test remains unqualified until integration actually runs.
- [ ] Require exact zero cycles with no label filtering and unchanged seven-app
  graph. Architecture source contracts do not replace this compiled gate.
- [ ] Retain original Step8 full-source/error/cleanup review, inventories,
  original inverse mutations and every actual startup/native boundary. Run the
  complete permitted README phase gate before Phase5 acceptance, not merely
  this scoped component gate. E2E remains NOT RUN / manual-deferred.
- [ ] Obtain source SPEC then a NEW distinct fresh source QUALITY review on
  exact source/test/log pins. Record findings, repairs and actual commands;
  continuing authority does not waive a failed assertion or reset repair counts.
- [ ] Parent may commit only explicit reviewed local paths after passing scoped
  gates/reviews. Record exact tested source and deferred risks. Complete Task16
  only after all original applicable assertions pass, then continue its dependent
  work; no merge/push/version/tag/release/deployment or production operation.

## Self-review and current disposition

The amended seam is covered by Tasks A/B, real process/COMMIT/native preservation
by C, exact formatter/Task8 attribution by D and unchanged compiled/review gates
by E. The original materialize entry becomes private consistently; generate
stays /3 with only its internal third-argument meaning changed. No caller-facing
callback or compatibility fallback is planned. Historical evidence stays intact.

This author ran read-only inspection, document self-review and scoped whitespace
checks only. All implementation/native/Mix/SQL/zero-cycle gates above are
**NOT RUN by this author**; DESIGN SPEC and NEW distinct QUALITY are pending.
No Task16/Phase5 acceptance or production repair round is claimed or reset.

Candidate1's independent DESIGN QUALITY found a P2 ownership-window contradiction:
the new composition architecture test was assigned after production despite Task A
requiring causal RED first. Candidate2 moves only that file's assignment into the
before-production test window; Step7b remains after production. The failed review
and reviewed candidate1 bytes are retained. This correction still requires actual
DESIGN SPEC then NEW distinct DESIGN QUALITY before implementing the changed seam.
