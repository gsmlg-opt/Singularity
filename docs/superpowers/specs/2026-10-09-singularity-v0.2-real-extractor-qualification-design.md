# Singularity v0.2 real extractor qualification design

Date: 2026-10-09
Status: bounded qualification verified locally with independent SPEC and QUALITY
reviews and final evidence closure clear. Only the bounded local commit is
authorized; Task 15 and Phase 2 remain open and unaccepted.

## Purpose and authority

This is the remaining bounded real-extractor evidence slice of Phase 2 Task 15.
It qualifies existing extraction behavior at source baseline
`d39ad93f257df3a6e01a87a420c7a034c888192b`. It does not accept Phase 2,
activate production writes, or authorize production repair. The governing
Phase 2 design and plan remain unchanged.

The coordinator reports an unchanged PDF baseline: session `73785`, exit 0,
19 tests, zero failures, 18.9 seconds. The reported PDF test SHA-256 is
`38302505e1266731e081141eef2d6565199349be08f446ed7efc2de49f843d0d`.
The inspected guardian C SHA-256 is
`c9232d53efa3280fb1d53fe7badcd317138e4ffe10425d4637d4d0f6af66d607`.
The parent has verified the current baseline hashes. These are baseline
evidence, not results for the proposed tests.

## File ownership and alternatives

The execution allowlist contains exactly six files:

1. This design.
2. `docs/superpowers/plans/2026-10-09-singularity-v0.2-real-extractor-qualification.md`.
3. `apps/singularity_ingest/test/singularity/ingest/documents/pdf_test.exs`.
4. New `apps/singularity_ingest/test/singularity/ingest/documents/poppler_lifecycle_test.exs`.
5. New `apps/singularity_ingest/test/fixtures/documents/scanned_image_only.pdf`.
6. `docs/verification/2026-10-09-phase-2-task-15-matrix.md`, owned by the coordinator.

The PDF worker owns the existing PDF test and fixture. The native worker owns
only the new lifecycle test. This permits parallel authoring while retaining
every existing assertion and native helper unchanged. The coordinator alone
owns Mix execution, evidence updates, services, and any separately authorized
Git operation. Other dirty files, including the unrelated Runtime-outcomes
plan, remain untouched and unstaged.

Adding all tests to the existing PDF module would reuse names but would mix
two independently authored helper families in an already large module.
A shared test-support framework would add coupling for only two cases.
The small companion module is the recommended compromise; no helper extraction
or old-test cleanup is included.

## Real PDF evidence

Add one literal ASCII PDF with a 23 by 7 grayscale raster spelling SCAN.
Its page paints an Image XObject through `/Scan Do`, has no font or text
operators, and contains correct stream lengths and cross-reference offsets.
Use a PDF 1.5 ASCIIHexDecode cross-reference stream so the literal fixture is
strictly valid with LF-only encoding and ordinary whitespace checks. The original
classic-xref proposal was withdrawn after apply_patch normalized its CRLF records.
Compute stream lengths, decoded xref entries, and offsets in JavaScript and
insert the exact ASCII/LF bytes through apply_patch. Ordinary Git whitespace
checks require no exemptions or attributes. This encoding follows the
[PDF Association's xref-stream guidance](https://pdfa.org/the-smallest-possible-valid-pdf/).
The fixture is original synthetic test content, contains no metadata or
external reference, and is committed directly rather than regenerated at test
time. Structure assertions and real `PDF.extract(..., runner: Poppler)`
must prove the image-only case returns `no_extractable_text`. The existing
empty-page test remains independently intact. OCR remains excluded.

Run the existing two-page PDF through real Poppler twice. Both executions must
produce the same two normalized blocks, then the same Core fragments and ready
`DocumentCompletion`. Check the known page strings, exact page/character
locators, zero-based ordinals, per-fragment SHA-256 values, distinct stable
fragment IDs, authenticated identity fields, and completion identity and
digest. The completion digest hashes concatenated fragment texts without a
separator. A fixed timestamp, generation 1, adapter pdf, format version 1,
private classification, and application/pdf make the two completion values
exactly comparable. This proves adapter-to-Core value composition only;
Runtime, encrypted custody, database persistence, jobs, and publication remain
outside the claim.

## Privacy evidence

Capture all six real fixture paths: both encrypted variants, malformed,
empty, scanned image-only, and ready two-page PDF. Assert each expected
return independently. Ready text is allowed in the explicit result.

Also inject `PRIVATE_PDF_DIAGNOSTIC_7A94` through three invalid classification
shapes and a text-runner diagnostic error, plus timeout and exit faults.
Each error must become its exact approved bounded classification.

Capture Logger at debug while temporarily lowering the actual primary Logger
threshold, restoring it in `after`; a capture handler's level alone cannot
override the configured warning threshold. Include all Logger metadata.
Capture BEAM standard output and standard error and require all three captures
to be empty. Do not enable optional ExCmd dependency debug configuration.

These observations establish the exercised adapter Logger/BEAM-output boundary.
Native pdfinfo fd 2 is redirected into bounded sanitized classifier output;
pdftotext fd 2 is disabled. BEAM captures do not inspect arbitrary native fd 2
or establish general telemetry, audit, outbox, Oban, or Runtime privacy.

## Native lifecycle evidence

Add exactly two real `Poppler.run_guarded/4` tests: timeout with target stdin
backpressure and output overflow with an established descendant tree.
All executable paths are resolved absolutely; missing Linux procfs or required
executables fails qualification rather than skipping it. Shell invocation is
confined to explicit process-tree test fixtures.

Each target creates a normal grandchild and a TERM-ignoring setsid escapee.
The escapee records its PID and execs sleep, preserving its identity. A private
control FIFO is opened read/write by the test before spawn and by the target
on fd 3. The target never reads fd 0. Its command read on fd 3 prevents overflow
until the test has observed all descendants. The test's read/write FIFO handle
also prevents a release write from hanging if the target has already died.

Before release, observe child, grandchild, escapee and guardian Linux stat
identities: PID, start time, parent, process group and session. Assert all are
live, the child leads its group, the grandchild belongs to that group and is
the child's direct descendant, and the escapee leads its own group/session
and ignores TERM. Guardian identity comes from the target parent, never a
broad process search. PID reuse means a different start time is a different
process, not a survivor of this test.

For timeout, supply 67,108,864 bytes and require this to exceed the live
`/proc/sys/fs/pipe-max-size`. The guardian buffers the complete outer input
frame before forking; the target marker therefore proves that transfer
completed. The guardian does not resize its target pipe, and the target never
reads it: this proves guardian-to-target delivery backpressure, not a blocked
BEAM writer. Optionally corroborate the still-open matching pipe descriptors.
Release hold only after observing the tree, then require exact `:timeout`.

For overflow, supply no stdin bytes, release the established tree to print
1,025 bytes, set output_limit to 1,024, and require exact
`{:error, :output_limit}`. Both cases use timeout_ms 5,000, comprising the
existing 4,250 ms execution allowance and 750 ms cleanup reserve.

Each invocation runs in its own monitored unlinked supervised BEAM task and
uses a fresh result reference. Readiness and disappearance use deadline-based
condition polling, never arbitrary settling sleeps or whole-case retries.
After the exact result and before any fallback cleanup, require all four
recorded native identities to be absent.

## Failure handling and acceptance

On failure, cancel only the owned BEAM task so the existing controller observes
caller death and closes control input. Never signal a numeric native PID, use
a process-name search, or stop a shared service. Await owned native identities
for a bounded interval, retain PID/FIFO artifacts, and report their directory.
Cleanup cannot precede the primary absence assertion or turn failure into
passing evidence. On success remove only this test's exact private directory.

Any real behavioral failure stops the affected task for evidence-based
diagnosis and a separately reviewed bounded repair. Production source, C,
dependencies, configuration, migrations, frozen Runtime/V2 paths, and Vault
remain unchanged. Do not weaken assertions to obtain green.

All Mix commands run with MIX_ENV=test. Acceptance for this slice requires
complete owning test files with seeds
1208 and 90731, formatting of both changed test files, zero xref cycles,
protected-file checks, and fresh specification then quality review of exact
candidate content. Expected Ingest count is 24: existing 19 plus three PDF
tests and two lifecycle tests. Optional existing Core fragmentation coverage
adds 8 tests, for 32 total, only if explicitly selected by the coordinator.
Record actual results, hashes, review evidence and remaining limits in the
matrix. E2E and the complete Phase 2 gate remain NOT RUN; Task 15 stays open.
