# Phase 2 Task 15 Inclusive Extraction Limits Qualification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Qualify inclusive fragment, page, and raw-output limits without production changes.

**Architecture:** Add five cases to the two existing owning tests. Preserve the established semantic 16 MiB success and adjacent over-limit refusals. Distinguish adapter runner-double output from native raw-byte evidence.

**Tech Stack:** Elixir/ExUnit, immutable Core fragment contracts, PDF FaultRunner, existing native Poppler guardian with resolved cat.

**Status:** This bounded slice is complete: 27 tests in each of two final-source
orders passed; independent Astra SPEC and QUALITY reviews cleared. Full Task 15
and Phase 2 acceptance remain open, and E2E remains NOT RUN.

---

## Task 1: baseline, scope, and design review

- [x] Read both complete owning tests and production contracts at `c7efaec`.
- [x] Run unchanged baseline (command in Task 3, seed 1208): session `15903`,
  exit 0, Core 6 tests/0 failures (5.3 seconds), PDF 16/0 (10.0 seconds).
- [x] Parent reads this plan and the corresponding extraction-limits design
  completely; fresh independent Astra design review clears all findings.
- [x] Record test-only GO under standing user approval; no production repair GO.

Only implementation files:
`apps/singularity_core/test/singularity/core/document_fragmentation_test.exs` and
`apps/singularity_ingest/test/singularity/ingest/documents/pdf_test.exs`.
The parent owns docs/evidence, Mix, Git, and services. Subagents are not alone;
preserve others' edits and the original untracked C plan. Do not edit support,
production, fixtures, migration, config, dependencies, or any other tests.

## Task 2: add the five inclusive contracts

- [x] Add two Core tests using existing `identity/0`; add `SourceLocator` alias.
  Keep all existing tests and assertions exactly. Use these bodies:

```elixir
test "accepts exactly 4096 fragments with stable exact provenance" do
  blocks = for line <- 1..4096 do
    %{text: "x", locator: %{version: 1, kind: "text", start_line: line, end_line: line}}
  end
  assert {:ok, fragments} = DocumentFragmentation.build(identity(), "text/plain", blocks)
  assert length(fragments) == 4096
  assert Enum.map(fragments, & &1.ordinal) == Enum.to_list(0..4095)
  assert MapSet.size(MapSet.new(fragments, & &1.fragment_id)) == 4096
  for {fragment, line} <- Enum.with_index(fragments, 1) do
    assert fragment.text == "x"
    assert Map.take(fragment, [:resource_id, :resource_version_id, :owner_scope_id, :classification]) == identity()
    assert fragment.digest == :crypto.hash(:sha256, "x")
    assert SourceLocator.to_map(fragment.locator) ==
      %{"version" => 1, "kind" => "text", "start_line" => line, "end_line" => line}
  end
  assert {:ok, ^fragments} = DocumentFragmentation.build(identity(), "text/plain", blocks)
end

test "does not divide a multi-codepoint grapheme at the byte boundary" do
  prefix = String.duplicate("a", 65_535)
  grapheme = "e\u0301"
  text = prefix <> grapheme
  block = %{text: text, locator: %{version: 1, kind: "text", start_line: 1, end_line: 1}}
  assert {:ok, [first, second] = fragments} = DocumentFragmentation.build(identity(), "text/plain", [block])
  assert first.text == prefix
  assert second.text == grapheme
  assert {byte_size(first.text), byte_size(second.text)} == {65_535, 3}
  assert String.valid?(first.text) and String.valid?(second.text)
  assert first.text <> second.text == text
  assert {first.ordinal, second.ordinal} == {0, 1}
  assert SourceLocator.to_map(first.locator) == %{"version" => 1, "kind" => "fragment", "ordinal" => 0}
  assert SourceLocator.to_map(second.locator) == %{"version" => 1, "kind" => "fragment", "ordinal" => 1}
  assert {:ok, ^fragments} = DocumentFragmentation.build(identity(), "text/plain", [block])
end
```

- [x] Add two PDF adapter cases using the existing FaultRunner, without changing it:

```elixir
test "accepts exactly 4096 reported pages with all page locators" do
  assert {:ok, blocks} = PDF.extract("small", runner: FaultRunner,
    info: "Pages: 4096\n", text: {:ok, String.duplicate("é\f", 4096)})
  expected = for page <- 1..4096 do
    %{text: "é", locator: %{version: 1, kind: "pdf", page: page, start_char: 0, end_char: 1}}
  end
  assert blocks == expected
end

test "accepts exactly 16 MiB of raw PDF output including a page separator" do
  body = :binary.copy("x", 16_777_215)
  raw = body <> "\f"
  assert byte_size(raw) == 16_777_216
  assert {:ok, [%{text: ^body, locator: %{version: 1, kind: "pdf", page: 1,
    start_char: 0, end_char: 16_777_215}}]} =
      PDF.extract("small", runner: FaultRunner, info: "Pages: 1\n", text: {:ok, raw})
end
```

- [x] Add native inclusive/adjacent-negative pair; preserve existing native tests:

```elixir
@tag :linux
test "native runner accepts its exact raw output cap and refuses one extra byte" do
  cat = System.find_executable("cat") || flunk("cat executable is required")
  assert Path.type(cat) == :absolute
  payload = :binary.copy("x", 16_777_216)
  assert {:ok, ^payload} = Poppler.run_guarded(cat, [], payload,
    output_limit: 16_777_216, timeout_ms: 10_000)
  assert {:error, :output_limit} = Poppler.run_guarded(cat, [], payload <> "x",
    output_limit: 16_777_216, timeout_ms: 10_000)
end
```

- [x] Self-review exact conversions, old assertion preservation, and evidence
  boundaries. No shared state, sleeps, process introspection, shell, new fixtures,
  or content files. Parent reads the complete diff before first characterization.
  These are new tests against existing behavior; no production RED is forced.
  On a failure, report exact source/command/diagnostic. No production fix is
  authorized; harness-only Astra repairs require traced cause and retained claims.

## Task 3: final-source checks, independent reviews, and handoff

- [x] Parent runs both full owning files on current source:

```sh
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps \
  devenv shell -- mix test \
  apps/singularity_core/test/singularity/core/document_fragmentation_test.exs \
  apps/singularity_ingest/test/singularity/ingest/documents/pdf_test.exs \
  --seed 1208 --trace
```

Expected Core 8 and PDF 19 tests, zero failures, no test exclusions. The runner's
integration exclusion selects no cases in these two unit modules. No DB/service
operation or integration/browser E2E occurs. Execute only one Mix process at a time.

- [x] Format only those two tests, check formatted source, and rerun both with
  seed 90731. If formatting changes source, run seed 1208 again on final source.
  Expected 27 executions per final whole-file run; do not count earlier source
  or failures as final-source passing evidence.
- [x] Run `git diff --check` and `devenv shell -- mix xref graph --format cycles --fail-above 0`
  with the same Mix environment. Expect exit 0 and zero cycles. Verify unchanged
  Core/PDF/Poppler production and protected Runtime/V2/untracked-plan hashes.
- [x] Fresh independent Astra SPEC review, then a distinct fresh QUALITY review
  of the exact final test hashes must clear. Keep parent-executed results distinct
  from source review. Diagnose findings; no assertion weakening or silent retries.
- [x] Update only this design, this plan, and the existing Task 15 matrix with
  exact hashes, commands/sessions, count/results/exclusions, unchanged files,
  repair attempts, limits evidence boundaries, and no Vault feature work.
- [x] Parent locally commits only the two tests and three records after reviews.
  Keep the Phase 2 worktree; its entire development branch is not finished.
- [x] Stop this bounded slice. E2E/full README gate, Task 15/Phase 2 acceptance,
  real scanned/process/privacy follow-up, merge, push, tag, release, deployment,
  and production activation remain incomplete or NOT RUN.
