# Document subprocess evidence implementation plan

> For agentic workers: use subagent-driven-development. Parent owns Mix, probes,
> reviews, evidence and commits. Astra owns only the two exact test-body edits.

**Goal:** ensure tool-run/termination proof failures cannot be sanitized into
the expected extraction outcome. No production change or assertion removal.

Status: all three tasks and strengthened C6 verification below passed on final
source `b8c6f602344926f4ec085edbd7b3a3b84173efb3d58654cc90ce20d31ba07e42`.
Parent accepts the bounded amendment and complete C block locally; the exact
eight-file dependent local commit is authorized. See final closure in
`docs/verification/2026-10-09-document-runtime-outcomes-integration.md` for
actual counts, commands, independent reviews and exact cleanup. Task12 scoped
qualification is accepted separately; Phase2/release acceptance remains open.

**Architecture:** assertions in the calling ExUnit test process after runtime
returns, outside production rescue; retain existing callback assertions too.

**Tech stack:** Elixir/ExUnit, existing actual Poppler guarded subprocess runner.

Worktree `.trees/v0.2-phase-2-import-extraction`, base `caf80fd4`; source freeze
`68537ed710bff9559c70ac498f482b56e7aab2d59c01811e56b8ec27e3bfeb3f`.
Read companion design. All prior C3/C4/C5 and telemetry compatibility constraints
remain except the explicit additive C2 freeze exception.

## Task 1: additive independent evidence checks

In C2 test `real owned subprocess #{mode} persists failed #{code}`, immediately
after existing `C.outcome!(...)`, add exactly:

```elixir
pid_path = Path.join(f.root, "owned-tool-pid")
assert File.regular?(pid_path)
assert {pid, ""} = Integer.parse(File.read!(pid_path))
assert pid > 0
refute File.exists?("/proc/#{pid}")
```

In C5 test `actual #{mode} private tool failure produces no stderr or source
metadata leakage`, immediately after existing `capture_private!(...)`, add the
same five lines, then this exact code before existing attempt/fragments checks:

```elixir
expected_code = if unquote(mode) == :timeout, do: "timeout", else: "extractor_failed"
assert [[expected_code]] ==
         S.owner_query(
           "SELECT failure_code FROM content.document_versions WHERE resource_version_id=$1 AND vault_id=$2",
           [f.document.resource_version_id, f.source.vault_id]
         ).rows
```

Apply with `apply_patch`, match surrounding indentation without reformatting
frozen code. Register no new tests and retain all old statements in order.
Parent proves reversal recovers full old hash, original A/B/C1 and C3 helper
bytes unchanged, and reviews actual diff. Agent runs no Mix or commit.

Formatting clarification: `Code.format_string!` requests only two additional
blank lines around the new C5 SQL assertion (between expected_code assignment
and assert; between `.rows` and the old attempt assertion). After the current
frozen-source run terminates and exact cleanup passes, parent may insert only
these two blank lines. Include them in the exact removable amendment block;
prove the complete normalized AST unchanged and the whole C5 append formatted.
No whole-file rewrite or other earlier whitespace change is permitted.

## Task 2: exact assertion-oracle probe

Parent extracts the exact five added statements from actual source, compares
both C2/C5 normalized ASTs for equality, and evaluates them with `f.root` bound
to a uniquely allocated temporary directory. Use `import ExUnit.Assertions` and
`Code.eval_quoted/2`; do not start applications, Mix or a database.

Require these controls:

- Missing file: `ExUnit.AssertionError`, expression `File.regular?(pid_path)`.
- File containing `System.pid()`: `ExUnit.AssertionError`, expression
  `File.exists?("/proc/#{pid}")` (the refuted live-process expression).
- File containing `"0"`: `ExUnit.AssertionError`, expression `pid > 0`.
- File containing `"invalid"`: `ExUnit.AssertionError` at strict Integer.parse match.
- Positive: `System.cmd("/bin/sh", ["-c", "printf '%s' \"$$\""])` returns exit0;
  write its numeric PID to the fixture after synchronous reap; assertions pass.

Check exact error expression, not just generic rescue success. Test fixture
writes are confined to the allocated temp directory; remove only those owned
files via `apply_patch` after recording results. Verify source hashes unchanged.
This standalone oracle probe is separate from real subprocess acceptance.

## Task 3: actual tool diagnostics, full gates and independent reviews

Run focused actual tool pairs via exact observed C2/C5 source line selectors
using the integration alias, seed1208. Capture actual selected/excluded counts
and exact database/root cleanup. Never call unit-only Mix as integration proof.
Then rerun full84 Runtime integration and every original C6 custody/storage,
Asset/application, unit/architecture/xref gate using the exact commands in the
compatibility plan and original C6. Actual counts govern, no filtering for full
gates. Only one Mix process; borrowed services untouched. No assertion weakening.

### Task12 verification-only consolidation

Main's complete worker-bridge plan read and independent Astra readiness audit
confirmed its seven existing reconciler contracts and explicit compile gate are
also required. The original C6 custody/storage group may be strengthened to this
union (no source/contract change):

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs --seed 1208
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix compile --warnings-as-errors
```

Expected union173 = original166 plus7 reconciler integration contracts; actual
reported/excluded/executed counts govern. Every assertion of original C6 and both
bridge integration groups remains required, with full Runtime file unfiltered.
Independent Astra audit cleared this union instead of a redundant separate91
Runtime/reconciler invocation. Standalone84, original101 Asset/application,
80 unit/architecture, zero-cycle xref, final-source freeze/reviews and exact
environment cleanup remain unchanged. Compile warnings must be checked explicitly.
This does not establish Task13's literal supervised-restart contract or Task14
empty-original authentication; those remain separate subsequent qualifications.

Fresh independent spec then quality review must clear amended full source.
Record new full/prefix hashes, exact old-source reversal and command outcomes in
the evidence record. Dependent source commit stays deferred until full C6 passes.
Phase2/release acceptance, merge, push, deployment and E2E remain out of scope.
