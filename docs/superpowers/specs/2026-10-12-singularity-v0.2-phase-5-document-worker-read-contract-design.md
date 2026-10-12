# Phase 5 Document worker-read test-contract correction

Status: DESIGN REVIEWED — actual independent SOURCE SPEC then distinct fresh
QUALITY PASS, no blocking findings; implementation/gates remain pending.
Reviewed draft SHA6dce0f9f75960d7ef34ba659332d8b2f01cddaf53b26ad96ee997c551b177339.
Parent factual records are `.devenv/phase5-document-worker-read-design-source-spec.md`
and `.devenv/phase5-document-worker-read-design-quality.md`.
Continuous local-development authority covers this necessary compatibility
correction; no renewed routine human approval is required.

## Evidence and fixed boundary

The complete Task14 live gate closed8e46b6/exit2. The existing
`DocumentCustodyPermissionTest` expects worker SELECT on document_versions to
fail, but actual native SELECT succeeds. This is not sufficient by itself to
classify the grant as safe. Accepted migration
`20261011000500_knowledge_backup_read_grants.exs:8-9` intentionally grants
worker SELECT on the seven knowledge projection tables, including this table,
as the Phase5 design specifies for the existing backup worker. Exporter reads
the real registry and retained Document pins; ordinary backup still defaults
to V2. The grant does not activate production V3 or confer byte custody.

Released Document DDL retains ENABLE/FORCE RLS, matching owner/principal GUCs
and core.principal_is_authorized. Worker extraction/projection bridges grant
specific function EXECUTE, not unrestricted direct table mutation. Unchanged
native custody independently requires actual session/epochs/capability/exact
immutable pin/object/generation and access-specific liveness.

Correct only the final permission-test module in Runtime
`test/singularity/runtime/document_custody_test.exs`. Preserve every other
custody test and all production/migration/shared fixture/frozen bytes. Do not
revoke accepted SELECT, add grants, change RLS/custody or merely invert the
old assertion. No Vault feature/test/policy or original-byte behavior changes.

## Replacement acceptance contract

- Assert the actual native worker role, SELECT=true and INSERT/UPDATE/DELETE/
  TRUNCATE=false, plus actual table ENABLE/FORCE RLS.
- Create known same-owner and foreign-owner disposable canonical Document
  metadata through existing owner fixtures. This is SQL permission evidence,
  not authenticated original-byte evidence.
- Missing scope returns no known rows. The matching active owner/principal
  returns exactly its expected immutable version/object pin. Foreign owner,
  mismatched principal/owner and revoked authorization return no target rows.
- Assert native PostgreSQL 42501 for direct mutation attempts, not fake
  exceptions or only privilege-catalog claims. Preserve fixtures/foreign rows.
- Reuse actual ScopedRepo and prove scope rollback/normal exit clears both
  GUCs on the same checked-out backend. No temporary production grant or new
  scope selector/authority flag.

All existing authorization/custody assertions remain. The incorrect historical
denied-SELECT assertion is replaced by the accepted narrower read-only/RLS
contract with explicit positive and adversarial native evidence. Required
whole-file tests, frozen receipts and independent source reviews still gate
qualification. E2E NOT RUN/manual-only; no merge/push/release/deployment,
production activation/backfill or data work.
