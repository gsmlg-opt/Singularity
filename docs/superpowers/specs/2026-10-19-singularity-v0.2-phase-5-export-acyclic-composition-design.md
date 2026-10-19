# Phase 5 Task16: acyclic export composition amendment

## Status, authority and scope

This forward amendment selects the minimal recommendation from the parent-managed
PROJECT_ARCHITECTURE advisory. Continuing `0.2.0` development authority permits
design and planning without another routine approval. Independent DESIGN SPEC,
then a NEW distinct DESIGN QUALITY review, must close before implementation of
this changed seam. Neither this document nor those reviews establish source,
Task16 or Phase5 acceptance.

Inspected worktree: `.trees/v0.2-phase-5-export-backup`; branch:
`codex/v0.2-phase-5-export-backup`; HEAD:
`6f1ddc788b9f68169ca4d8e88a4522660e926c1e`. Existing uncommitted Api, Export,
Handle, directory and test work belongs to the parent and remains intact.

Governing historical documents remain unchanged:

- [Task16 ownership design](2026-10-12-singularity-v0.2-phase-5-export-artifact-ownership-design.md).
- [Task16 ownership plan](../plans/2026-10-12-singularity-v0.2-phase-5-export-artifact-ownership.md).
- [Qualified native lease prerequisite](../../verification/2026-10-19-phase-5-export-lease-ownership-handoff.md).

This amendment overrides only the original Step4 reverse materializer call,
Step5 materializer visibility, the third argument's internal meaning in
`ExportArtifact.generate/3`, and the specifically reconciled P5-A2 formatter
bytes below. Every other ownership, source, authority, cleanup, startup and
exact-attribution obligation stays required. No dependency, migration, global
process, public Api operation/arity or caller configuration is added.

## Evidence and alternatives

The original plan's Step4 says the owner executes `Export.materialize/4`.
Its Step5 routes `Export.run/3` to Artifact, retains final
`ExportArtifact.accept_completed/2`, and current `export.ex` also uses
`ExportArtifact.Handle`, whose module lives in `export_artifact.ex`. Implementing
the reverse call literally therefore creates a two-file cycle. This is a
source-supported **planned** cycle, not a claim that a compiled cycle already
failed: the current Artifact file contains only Handle/Inspect and materialize
is not implemented.

README's exact gate is `mix xref graph --format cycles --fail-above 0`, with no
label filter. The architecture advisory inspected the installed xref task:
its file graph combines runtime, export and compile references. Moving Handle
alone cannot remove the intended run/materialize/accept loop.

1. **Selected: one fixed operation-local work closure.** Export depends on
   Artifact; Artifact invokes an internally supplied function without referring
   back to Export. Preserve the existing file responsibilities and generate/3
   arity, with no new public seam.
2. **Separate materializer plus protocol leaf.** A materializer that still calls
   Artifact's completion protocol can retain a cycle. Separating that protocol
   too would add files/interfaces without a present requirement.
3. **Merge orchestration and ownership.** Removing the file edge this way mixes
   validation/materialization with process cleanup and expands the change.

Dynamic `apply`, module/MFA selection, a runtime materializer adapter, filtered
xref labels, cycle whitelists and changed historical baselines are rejected.

## Selected one-way composition contract

`Export.run/3` keeps strict option/session validation and current native
authorization before generation. It constructs exactly this local work/2 at
the fixed call site, using the already normalized options:

```elixir
work = fn operation_runtime, operation ->
  materialize(operation_runtime, session, normalized_options, operation)
end

ExportArtifact.generate(runtime, session, work)
```

`materialize/4` becomes `defp`, not an exported entry point. The third argument
of `generate/3` is now this fixed work/2, not options. There is no options-taking
compatibility clause, default implementation, external callback registration or
new generate arity. This internal function value is not an authorization token.

Artifact creates the operation reference and companion, records the owned
envelope, and establishes the eventual owner before work can execute. In the
eventual Writer-owning process it creates a private copy of runtime with only
custodian/authenticated-reader replaced by its fixed `Leases` adapters; the
authorization dependency bundle retains genuine native custody. It invokes
`work.(operation_runtime, operation)` exactly once in that owner. It never runs
work in the generating requester, companion, delivery loop or startup path.
After generation returns or fails, no completed/closed owner or companion state
retains the work closure; retry requires a distinct new operation, not reinvocation.

The closure is constructed literally in run/3, never obtained or selected from
request options, runtime/configuration, application environment, a message or
an MFA. Internal task initialization may carry the fixed work to the owner;
there is no message opcode that accepts executable work. Leases and operation
envelope details remain internal and never enter the public Handle.

Artifact has **no** reference, alias, import or dispatch back to Export,
including `validate`, `public_result`, `materialize` or identity helpers. It
checks its own stored operation reference/binding and uses unchanged native
OperationScope/Authorize for admission and delivery. Any small binding predicate
needed there stays local; do not introduce a shared dependency that recreates
the cycle. Export may continue using Artifact.Handle, generate and completion
helpers: the direction is exclusively Export → Artifact.

## Preserved materialization and lifetime requirements

The work closure calls the actual Snapshot/Spool/ExportRead/Repository/Writer
composition; it is not a fake materializer injection seam. Snapshot's real
repeatable-read COMMIT precedes Writer.open and binary work. The owner creates
all Writer ETS ledgers, reports the initial descriptor before mutations, and
keeps that ledger after successful requester death. Metadata remains streamed
in the fixed eight-collection order; exact immutable selectors, sealed text,
digests, quotas and source revalidation are unchanged.

The final combined native scope still returns the existing after-COMMIT
`ExportArtifact.accept_completed(operation, artifact)` callback. It performs
the prepared/accepted requester-monitor handoff, not early publication. Artifact
must not duplicate that acknowledgement, publish on a synthetic COMMIT, or
remove the requester monitor before the established linearization point.

All original fixed creation-time deadlines, idle authority ticks, current
session/principal/owner/both-epoch checks, foreign-handle noninterference,
owning-session failure cleanup, dead-owner close rules and no-resurrection
requirements remain. Cleanup must await actual owner DOWN before envelope
deletion and use independently recorded identities if ETS has disappeared.

The companion alone acquires native export-request leases through qualified
`KeyCustodian.export_lease/2`, records before forwarding, and retires only after
native acknowledgement/DOWN as required. Both strict end-to-end ALL-leases
assertions—late issuance after acquisition timeout and companion hard death
before recording—remain required in actual artifact composition. Primitive
qualification, a fake PID, process DOWN or closed delivery alone proves neither.
Recorded/pre-forward/known-forwarded cases and native public read denial stay
required; no global enumeration, worker substitution or broader Vault change.

Startup retains the fixed local `:global.trans` lock through actual native
Supervisor.start_link registration/return, checks surviving named supervisors
before filesystem effects, and preserves the false-infrastructure no-effect
path. No root, clock, supervisor, cleanup or source policy changes here.

## Exact P5-A2 formatter reconciliation

Original Step6 expressly permits parent formatter/review reconciliation before
new block hashes freeze. Actual formatting wrapped only this planned line:

```elixir
    do: knowledge_export_call(config, :read_knowledge_export_chunk, session, [handle, path, index])
```

into:

```elixir
    do:
      knowledge_export_call(config, :read_knowledge_export_chunk, session, [handle, path, index])
```

There is no token/behavior change. Future Step7b must require only the exact
formatted literal and its fixed context, not accept both forms or normalize
arbitrary whitespace.

| P5-A2 record | Bytes | Block SHA-256 | Context SHA-256 |
| --- | --- | --- | --- |
| Historical proposal | 2170 | `a42d2e03a9b424de2267a5c80d4853fca8cf13c3d39e7cbef1b18bc4702c5224` | `002c4066ea063568421c00649d1a2a8f0cd7a0a062ffa58787cc8fc7e3a081f0` |
| Reviewed reconciliation candidate | 2176 | `1cfcdcb92693b92b2409afabe85319f60966dfbf00adb7765eae4a4a014d2b7f` | `cc309bdb2211654f4e571a914dd5e12f790d6a66b58b5fc8b6daf97c9ed5f11a` |

P5-A1 remains `bafbd33be306cb42c49cc94eb8ceb15e22c74cac3373d6fc0f0b982ccabee525`.
Read-only byte calculation independently confirms removal of those two exact current blocks recovering
HEAD Api, SHA-256
`8557685c2415c5ee3b30e33be6dfaab6e4ee25b0772bb3123a92384a914c33b4`.
The result is byte-identical to `git show HEAD:apps/singularity_runtime/lib/singularity/runtime/api.ex`.
This is not qualification of the five remaining additions or P5-A5 startup
replacement, which remain future source.

Step7a was accepted at `9f91c97eb392b4c49c888ed31795d520d15bb8dd`;
do not repeat it. Future Step7b must preserve the current native-text inverse
and the strict Task16 → Task8 → historical attribution order, including raw
Task8 positive-witness guards and all causal negative assertions. Never paste
the older plan's normalization body over the later native-text layer. Historical
docs, raw manifests, frozen 56-file inventory and baseline digests stay intact.
New docs/candidate source require separately named derived guards/manifests;
do not edit old pins to make a changed candidate appear unchanged.

## Acceptance and evidence boundary

The [forward plan](../plans/2026-10-19-singularity-v0.2-phase-5-export-acyclic-composition.md)
adds test-first canaries for materializer/work/callback/MFA request keys,
literal-only composition architecture checks, actual owner/ETS and COMMIT
witnesses, and retains all original whole-owner/native/startup gates. Tests
must distinguish synthetic authority/COMMIT fixtures from actual SQL/custody.
The exact README zero-cycle command remains unchanged, with seven applications.

Design author performed read-only source/doc inspection, exact in-memory
P5-A1/P5-A2 byte/hash/inverse checks and document self-review only.
Implementation, Mix/SQL/native execution, architecture tests and zero-cycle
gate: **NOT RUN by this author**. E2E remains **NOT RUN / manual-deferred**.
Independent DESIGN SPEC and NEW distinct QUALITY are pending. No Task16 or
Phase5 acceptance, publication, production operation or Vault feature work is
claimed. This architecture amendment consumes no production repair round and
resets no prior counter.
