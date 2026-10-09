# Phase 2 Task 15: inclusive extraction-limit qualification design

Date: 2026-10-09

Status: bounded qualification complete; 54 final-source executions passed and
independent Astra SPEC/QUALITY reviews clear. Task 15 and Phase 2 remain open.
Inspected source: `c7efaec657c1f3d18fad16bed39ea6ae0e85a083` in
`.trees/v0.2-phase-2-import-extraction`.

## Purpose, authority, and alternatives

Qualify the positive sides of Phase 2 Task 15's extraction-size boundary pairs
without changing production limits or behavior. The user auto-selects recommended
choices and authorizes continued repository work; E2E remains explicitly excluded.
The Phase 2 design and Tasks 5, 6, and 15 of its detailed plan remain authoritative.

Recommended: add bounded cases to the existing Core fragmentation and PDF owning
tests, retaining every existing assertion. Separate new files would duplicate
private identity and runner helpers. A combined all-extractor/process/privacy
expansion would mix independent behavioral contracts. Neither is selected.
Real scanned-PDF, blocked-stdin/overflow descendant cleanup, real PDF-to-fragment
digest reruns, and adapter log privacy remain the next separately designed slice.

Parent read the owning files and their production contracts fully. A read-only
Astra source audit confirmed the missing positive coverage. The unchanged baseline
passed 6 Core and 16 PDF tests, seed 1208, session `15903`: 22 total, zero failures.
No database was allocated. Design and plan receive a fresh independent Astra
review before test-only implementation GO under the user's standing approval.

## File boundary and existing evidence

Only code changes:

- `apps/singularity_core/test/singularity/core/document_fragmentation_test.exs`
- `apps/singularity_ingest/test/singularity/ingest/documents/pdf_test.exs`

The parent owns this design, its plan, and the existing Task 15 evidence matrix.
No production, support, migration, dependency, configuration, fixture binary,
Runtime/storage test, V2 schema, Vault, custody, or capability change is authorized.
Preserve the user-owned untracked C plan. No public activation, merge, push, tag,
release, or deployment is included. Keep the existing Phase 2 worktree.

Core already accepts exactly 16,777,216 semantic bytes: its existing largest
UTF-8 block becomes 256 fragments, each 65,536 bytes, reconstructing the input.
It already rejects 16,777,217 bytes and 4097 fragments. Do not duplicate or weaken
these tests. Existing PDF tests reject 4097 reported pages and 16,777,217 raw
output bytes. The new positive cases complement these adjacent refusals.

## Core positive contracts

1. A 4096-block input with one nonempty character and a distinct exact text line
   locator per block builds 4096 fragments. Require ordinals 0..4095, unchanged
   text and all locator fields, immutable resource/version/owner identities,
   correct per-fragment SHA-256, unique fragment IDs, and complete rerun equality.
   No splitting is needed; the exact source range must remain, not fall back.
2. A multi-codepoint grapheme must not straddle the byte boundary. Use 65,535
   ASCII bytes followed by `e` plus combining acute (three bytes total). Core
   receives the unnormalized vector directly and must preserve it as two chunks:
   65,535 bytes and the intact three-byte grapheme. Require valid UTF-8, exact
   reconstruction, contiguous ordinals, ordinal provenance fallback, and rerun
   equality. This detects a codepoint splitter that would put `e` in the first
   chunk. Text/Markdown normalize NFC before Core; their behavior is not changed.

## PDF adapter and native raw-byte contracts

PDF checks raw bytes before LF/NFC normalization, form-feed splitting, and trim.
Core checks semantic fragment text independently. Never conflate these budgets.

1. Through the existing FaultRunner, report 4096 pages and provide 4096 nonempty
   `é` pages, each terminated by form feed. Require every exact page locator
   1..4096 with character range 0..1 and text `é`. The trailing empty segment
   must not create page 4097. This is an adapter parsing test using a runner
   double, not proof that a real 4096-page PDF was processed by Poppler.
2. Supply exactly 16,777,216 raw bytes including one trailing form feed. Use an
   ASCII body of 16,777,215 bytes; require the sole block to retain that exact
   body and page-1 character range 0..16,777,215. This proves inclusive raw output
   acceptance, not 16 MiB semantic PDF text or real Poppler extraction.
3. Independently exercise the native guardian/controller with the resolved
   absolute `cat` executable: exactly 16,777,216 input/output bytes return exact
   success; one extra byte returns `{:error, :output_limit}`. Set output_limit to
   16,777,216 and timeout_ms to 10,000, within existing supported bounds. Require
   Linux and fail if `cat` is unavailable; never skip a required assertion.
   No shell, persistent plaintext, descendants, timing sleeps, or new dependency.
   This is real native raw-limit evidence, not PDF semantics or a proof of the
   deferred descendant-overflow cleanup scenario.

## Verification and failure handling

This is characterization of already implemented contracts, not permission to
force a red result by modifying production. Run new assertions against unchanged
production. Diagnose every failure before editing; any valid behavioral failure
requires a separately bounded reviewed repair. Never relax limits, change vectors
to avoid a valid failure, weaken old assertions, or silently work around dependency
defects. Fixture/harness corrections may remain in the two owning tests, with
exact failure and repair evidence. Use Astra; the user permits at least three
failed repair attempts if needed, not fabricated failures or retry masking.

Parent runs one Mix process at a time with the established `devenv shell` runner
and shared read-only dependency path; `unbuffer` remains unavailable, no install.
Run both full owning files, then a changed-order repeat on final formatted source.
Record exact hashes, commands, counts/exclusions, results, and source checks in
the existing matrix. Check formatting for only the two changed tests, whitespace,
zero xref cycles, unchanged production hashes, and protected files. Require fresh
independent Astra SPEC then QUALITY reviews before local test commit.

No full README gate, E2E, complete Task 15/Phase 2 acceptance, publication,
production activation, or deployment follows. Stop this bounded slice after its
test/evidence handoff; the active release goal remains incomplete.
