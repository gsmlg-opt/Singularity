# Phase 5 Task16 Exact Attribution Staging Amendment

Status: actual C1 formatter receipt closed; independent DESIGN SPEC then NEW
distinct QUALITY pending. No source GO or acceptance is claimed.

## Purpose and authority

This narrow forward amendment completes Step7b of the
[artifact ownership design](2026-10-12-singularity-v0.2-phase-5-export-artifact-ownership-design.md)
and its [implementation plan](../plans/2026-10-12-singularity-v0.2-phase-5-export-artifact-ownership.md).
The already-qualified Step7a prerequisite is not repeated or replaced.
Continuing development authority permits this necessary contract update without
another routine human approval. No product, Vault or publication scope expands.

The inspected checkout is `.trees/v0.2-phase-5-export-backup`, branch
`codex/v0.2-phase-5-export-backup`, HEAD
`8fb1142ee593641544769658d03a96cb83ebaa56`.

## Current evidence and the missing input boundary

The current architecture owner is
`apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs`,
1,909 lines, SHA-256
`f3f2b57689ac6470d357a7578e3721d1df484b8bfd16a70ec344288ab087aed0`.
Its API normalizer already contains all eleven accepted native-text inverses.
Step7b's older generic normalizer snippet must not overwrite them.

The accepted native-text positive witness independently hashes its raw API
input before using that normalizer. Strict Task16 stripping is therefore
needed at this second input boundary as well as the existing Task8 positive
witness. Changing only the outer normalizer leaves that positive witness broken.
An optional absent-block branch or a current-file replacement hash would conceal
the defect rather than preserve the accepted proof.

The two fixed native-text hashes remain:

- Before the native inverse:
  `8557685c2415c5ee3b30e33be6dfaab6e4ee25b0772bb3123a92384a914c33b4`.
- After exactly one native inverse:
  `6212a126be413c4b19bc0e24e8cc3c86f1e8ce776ebd2e8a7427ee2e2695fda1`.

## Required staging

Factor the existing eleven-hunk `Enum.reduce` body, unchanged, into one private
native-only helper. Do not alter its hunk fixtures, context guards, mutation
builders or digest inputs. API normalization becomes strict Task16-only
stripping followed by exactly that helper. Other paths become strict Task16
stripping followed by the existing Task8 inverse. The historical Phase4
organization, Phase4, Phase3, Phase2 special/worker stages remain unchanged.

The native positive witness must perform this exact sequence:

1. Read raw current API.
2. Require and remove only the exact reviewed Task16 blocks in their contexts.
3. Assert the SAME fixed `8557685c…` digest on those staged bytes.
4. Run all eleven SAME native hunk guards on those bytes.
5. Invoke the native-only helper once, not the outer normalizer again.
6. Assert the SAME fixed `6212a126…` digest and historical runtime baseline.

The Task8 positive witness follows the already-reviewed original Step7b body:
guard both Task8 tuples on RAW Application, strictly invert/strip Task16 only,
invoke the Task8 inverse once, then assert the unchanged fixed pre-Task8
`4deda19432de3174c2f737216c8185e3cdea8bb91d3960475308a27558bdfbca`
and historical baseline. Neither positive uses optional detection, an already-
normalized fallback, a second inverse, whitespace normalization or new baselines.

Keep all thirteen Task8 tuple negatives, three extra-registration negatives,
eleven native-hunk tests with seven mutations each, unrelated legacy-byte
counterproof and seven historical mutation groups. Their raw mutation setups
and causal rejection routes remain. Add explicit stage checks showing strict
Task16 stripping succeeds for retained native mutants before their original
native guard rejects them; unrelated-byte mutation must reach the historical
digest failure, not a missing Task16/native prerequisite.

## Formatter reconciliation boundary

The acyclic amendment already qualified the single P5-A2 formatter wrap. Its
addition/context hashes remain `1cfcdcb92693b92b2409afabe85319f60966dfbf00adb7765eae4a4a014d2b7f`
and `cc309bdb2211654f4e571a914dd5e12f790d6a66b58b5fc8b6daf97c9ed5f11a`.

The parent has proved all five current Step6 whole-file inverses before
formatting, using the immutable
`.devenv/phase5-task16-parent-step6-preformat-inverses.js` (SHA-256
`17ff36dc323acab2badc133d3bccffee19c0d447c3fecb098912175a7518fb92`).
The actual C1 formatter delta below is the only newly reconciled wrap. Any
additional planned-block delta requires its own explicit characterization and
review.
Preserve the old checker, proposals, manifests and receipts byte-for-byte;
create a separate post-format checker, never a rewritten historical baseline.

The actual C1 formatter ran as native057, not a proposed formatting guess:

```text
mix run --no-start --no-compile .devenv/phase5-task16-exact-format-receipt.exs config/dev.exs
```

Its immutable raw is
`.devenv/phase5-task16-resumed-native057-c1-actual-format-receipt.log`,
SHA-256 `2b814d407217ff9fcfac92a235a959cb1322f6b9d9e9e80b532c64247934a55f`,
1,191 bytes / 5 lines, natural exit0. The separate native058 ordinary post is
`.devenv/phase5-task16-resumed-native058-c1-actual-format-receipt-post.log`,
SHA-256 `b0fb27c04afa5826e273b9b0e7a55920046746a4262f705ee618c397bd49ed13`,
425 bytes / 4 lines, natural exit0 with its entire actual body EMPTY. Parent
read both complete raws. Neither command is a runtime qualification.

Only this exact old addition is superseded:

```elixir
export_backup_root =
  System.get_env("SINGULARITY_BACKUP_ROOT", Path.expand("../var/backups", __DIR__))

config :singularity_runtime,
  knowledge_export_root:
    System.get_env(
      "SINGULARITY_EXPORT_ROOT",
      Path.join(Path.dirname(export_backup_root), Path.basename(export_backup_root) <> "-knowledge-export")
    )
```

The actual formatted addition is:

```elixir
export_backup_root =
  System.get_env("SINGULARITY_BACKUP_ROOT", Path.expand("../var/backups", __DIR__))

config :singularity_runtime,
  knowledge_export_root:
    System.get_env(
      "SINGULARITY_EXPORT_ROOT",
      Path.join(
        Path.dirname(export_backup_root),
        Path.basename(export_backup_root) <> "-knowledge-export"
      )
    )
```

Both additions have one additional LF after the shown final line. Their exact
before/after context bytes, with literal LF escapes, remain:

```text
Before: "      Path.expand(\"../var/storage\", __DIR__)\n    )\n\n"
After: "config :singularity_storage, Singularity.Storage.MigrationRepo,\n"
```

| Value | Before actual formatting | After actual formatting |
| --- | --- | --- |
| Addition SHA-256 | `414ee65a6c7c333fca7a3d84fe181b1b231f67b44ef9e5a134e28afdb517c052` | `d00f70903d73f1238d0c7f7f062db307bbf778d0708ff5a29c9bf280ce45257a` |
| Before + addition + after SHA-256 | `cd255aed0ce6420944d42bf66b2929adb7c7b14f9285f760cd06ef5d36832d35` | `e04b97ef27cd4bee396b4667422b481a66ae86aa34eb4bf06594048a6eeec67c` |
| Whole dev file SHA-256 | `4ce5de11211915bd463795019171435348bb43236baf59bc4207bc719d982ec5` | `df506220462f8cbed1ff0e9d689987c12842ae8f6509d565be93068c49310f9a` |

The unique exact wrap inverse recovers the whole unformatted dev file; removing
only the exact addition in its context then recovers the SAME whole pre-Step6
`b028676aba7578fad1e217fbecc94c0aad66610c671eeec1220d1808b3d6c8d0`. All five complete Step6 parent comparisons PASS in the
new `.devenv/phase5-task16-parent-step6-c1-postformat-inverses.js`. The old
pre-format checker remains byte-identical. The actual delta and both command
records are preserved in `.devenv/phase5-task16-C1-format-reconciliation.json`.

All other Step7b seven-addition/P5-A5 old-new/context digests and relocation
anchors remain exactly the original plan. P5-A5 is one replacement, never an
eighth addition. Closed AST registration checks retain exact public arities and
qualified references; documentation cannot hide an extra clause/registration.
No blanket `Export` term allowlist or broad normalization is permitted.

## Ownership, verification and exclusions

The implementation writer owns only the architecture owner named above after
explicit parent GO. Parent owns formatter reconciliation and these two new
documents. Notes-scope contracts, all other architecture files, production
source and old phase documents are outside this amendment's write scope.

Before source GO: actual formatter receipt, complete parent read, independent
DESIGN SPEC followed by NEW distinct QUALITY on exact document pins. Then add
causal contract tests before their strict inverse implementation, preserve all
old assertions/hashes, run the full original Task16 pure owner command plus the
composition owner, and obtain independent SOURCE SPEC then NEW QUALITY.
Record exact whole-file inverse attribution to the inspected architecture
owner; no existing source pin is silently regenerated.

Task16 remains unqualified. Native055 failures and all other native/startup/
cleanup gates remain required; this amendment does not repair them. E2E is
NOT RUN/manual-deferred. No merge, push, version/tag/release, deployment,
production activation/backfill/data or Vault feature work is authorized.
