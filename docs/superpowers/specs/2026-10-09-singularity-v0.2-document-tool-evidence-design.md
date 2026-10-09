# Document subprocess evidence assertion amendment

Status: bounded test-only amendment accepted locally after oracle controls,
final-source actual integration gates and independent full-C Astra reviews.
All mandatory C6 gates now pass; the dependent local commit is authorized in
`docs/verification/2026-10-09-document-runtime-outcomes-integration.md`.
Phase2/release acceptance remains separate. Independent Astra
whole-block quality review identified the gap and supplied this exact minimal
recipe. Parent verified the rescue path, personally read this complete design and
executable plan, and accepted only the exact additive test-body edits. The fresh
amended gates and independent reviews below have passed; historical evidence follows.

## Evidence and decision

The unmodified C1 ToolFailure helper reads its PID file and asserts child death
inside the production extraction callback. `Extract.extract/2` rescues assertion
and file errors as `extractor_failed`. C2's tool_exit contract expects that code;
C5's two tool cases only assert failed state. Thus these contracts can falsely
pass when subprocess evidence is missing or a termination assertion fails.
This is a test-proof gap, not an observed child leak or production defect.
Original plan has the same placement. Source `68537ed…feb3f` passed all84 real
integration contracts, but that green does not clear the independent finding.

Recommended: retain every C1 byte/assertion and add independent PID-file presence,
strict positive integer and child-death assertions directly in both C2/C5 test
bodies outside the rescue boundary. In C5 also assert exact failure_code for
each tool mode. Reject changing production rescue behavior, waiving evidence,
or replacing the real tool path with fabricated success.

## Narrow freeze exception and scope

Only additive assertions in the C2 subprocess pair and C5 subprocess pair in
`apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs`.
These two loop bodies cover four existing contracts; register no new contracts.
No C1 helper, existing assertion, earlier A/B byte, C3 helper, C4, production,
configuration, dependency, schema, custody/key/capability/Vault behavior changes.
No whole-file formatting. Companion plan and current evidence may change.

Reversing only the exact new assertion blocks in memory must recover full source
SHA-256 `68537ed710bff9559c70ac498f482b56e7aab2d59c01811e56b8ec27e3bfeb3f`.
This supersedes absolute C2/prefix freeze only for the specified additive block.
Original A/B hash and exact C3 restoration-helper hash remain unchanged.

## Verification and acceptance

Use the actual assertion AST in a disposable standalone no-app/no-DB harness.
Missing PID file, live current BEAM PID, zero and malformed PID must fail at
their precise required assertions; synchronously reaped owned child must pass.
This proves the assertion oracle, not production cleanup. Real integration
contracts remain the actual production/tool evidence. Then require focused
actual four-contract tool diagnostics, full unchanged84 integration count,
all mandatory C6 regressions, independent fresh spec then quality review and
exact environment cleanup before C-block acceptance. No E2E or release claim.
