# Phase 5 Task 13 snapshot denial/audit test-contract correction

Status: design authored; actual independent source/spec and fresh quality review
are required before the three affected SQL expectations change. Continuous
development authorization selects this bounded recommendation automatically.
This is a test-contract correction, not a product authorization change.

## Scope and failure evidence

The complete Task 13 partial-production SQL command closed normally at
`5ef0e4`, exit 2: Repository 26 tests/19 failures and Runtime 17 selected SQL
tests/7 failures, **43 actual tests/26 failures**. Its untruncated archive is
`.devenv/phase5-task13-partial-initial-production-sql.log`, SHA256
`c83c8d16047aad0dedd9e021580a29d36a1f8935b5327360b2c78d62d198e808`.
The missing Repository and an exception in the newly authored observation
fixture prevent positive live-authority qualification. Reported denial PASS
must not be treated as causal authorization proof while that exception exists.
All earlier failed runs remain failed and retained.

The new fixture's strict boolean condition incorrectly treats a nil/reference
barrier as a boolean and calls `not` on a nil process-dictionary value.
The separately bounded fixture-only correction uses explicit `is_nil` checks;
it preserves the real IdentityRepository delegate, barrier and five-second
timeout. It does not authorize changing these three denial assertions.

## Actual frozen source contract

- `runtime/authorize.ex:26-37,75-107,113-130` reloads actual live identity,
  rejects missing sessions/binding/revoked membership, and rescues exceptions
  as forbidden. Therefore a mere denied return does not prove that the real
  identity delegate executed successfully.
- Released `20260718000800_add_task11_authorization_functions.exs:1375-1464`
  binds `core.live_session_authorization` to both request GUCs. A forged
  principal or owner hint returns `{:ok, nil}` through IdentityRepository,
  so Authorize returns `:unauthenticated`; revoked membership returns the
  actual live row and Authorize returns `:forbidden`.
- `runtime/operation_scope.ex:158-177` deliberately propagates the denial
  audit error instead of the initial authorization error when audit fails.
- `storage/postgres/audit_sink.ex:56-74` maps actual SQLSTATE 42501 to
  `:storage_unavailable` with `retryable?: true`; it does not report success.
- Released `20260718000600_create_security_functions_rls_and_grants.exs:
  352-380,428,1144-1180` requires a matching, nonrevoked membership to INSERT
  an audit event. Forged principal/owner and revoked membership cannot meet
  that predicate. No policy, grant, role, or audit behavior may be changed.
- Knowledge ExportSnapshot preserves a Core error's code/retryable flag and
  aborts its operation spool. It must not remap the audit failure to forbidden.

## Recommended test-only correction

Only the new Runtime SQL test module's three cases for `:wrong_principal`,
`:wrong_owner` and `:membership_revoked` are affected. The other nine live
denial cases and their existing capture-error allowlist remain unchanged.
The three cases retain the strict authorization-denial predicate and strengthen
it to the exact native code on a direct real Authorize check inside a fresh
RR request transaction, with the same fixed requirements as capture:
`asset.read`, `note.read`, private classification, unlocked custody, and
session-bound principal/owner epochs. The underlying store and custodian stay
the real SQL IdentityRepository and established KeyCustodian.

A new test-local observing store delegates to the existing ObservedIdentity,
records its actual returned result, and returns that result unchanged. Assert
successful SQL execution with the actual nil result for the forged hints, or
the actual revoked-membership row for membership revocation. Observe and assert
RR/off before authorization SQL. This rules out the fixture exception as a
substitute proof. Do not fabricate live rows or authorizer results.

Then call actual ExportSnapshot/OperationScope with a test-local audit observer.
The observer delegates the unchanged event to the real AuditSink. Its insert
observer delegates `RequestRepo.insert/1` on the same process/checked-out
connection, records the real Postgrex error's code and SQLSTATE, and reraises
the original exception. Assert the original sink result and final capture both
equal `:storage_unavailable`, `retryable?: true`, with exact 42501 and
`:insufficient_privilege`. This observer does not replace the audit outcome,
change persistence, or swallow the original exception.

Observe the audit event's generated ID, principal/owner, action/result and empty
metadata, without content. Check the attempted event ID is absent through the
existing owner-only test fixture after the failure. Prove no repository capture
callback was entered using a test-local capture observer which delegates to
the actual Repository if called; it may never grant authority or fake a result.
Preserve the unsuccessful-descriptor assertion, operation-directory cleanup,
neighbor preservation and fresh GUC/transaction checks.

The original authorization-denial assertion is not relaxed to accept arbitrary
storage failures. It is applied to the actual Authorize decision and made
exact. A separate exact assertion qualifies the frozen audit-failure contract.
No assertion, case, timeout or selection is removed, skipped or reclassified.

## Mutation and acceptance boundaries

Author only
`apps/singularity_runtime/test/singularity/runtime/knowledge_export_snapshot_test.exs`
after the design passes actual independent source/spec and distinct fresh
quality review. Keep the shared fixture's already corrected boolean condition,
all production, frozen 56-file substrate and accepted migrations unchanged.
Parent owns formatting, complete test gates, SQL services, source receipts and
Git. The author may not run them or edit other files.

Run the complete five-file Task 13 pure selection and complete two-file SQL
selection without line filtering/default-timeout changes. Before Repository
implementation, missing-feature positive failures remain expected RED, not
PASS. Require the three strengthened denial proofs to execute and pass, archive
the entire result and verify database/root cleanup and source hashes. After
Repository exists, rerun the complete selections to GREEN and independently
review actual final source. This amendment is not Task 13/Phase 5 acceptance.

E2E is NOT RUN/manual-only. No production activation/backfill/data, Vault
feature, custody/key/capability/policy/lease/crypto change, merge, push, version,
tag, release or deployment is authorized by this correction.
