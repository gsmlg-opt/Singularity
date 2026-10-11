# Task 13 Owner-Precommit Native-Authority Test Amendment

Status: independent actual SOURCE SPEC followed by distinct fresh QUALITY PASS
on the complete candidate design b1bc11db and plan c42238e0. Parent-authored
from read-only Astra PROJECT_ARCHITECTURE advice and isolated permission
probes. Test authoring still waits for closure of live SQL50680. No
implementation, Task13 acceptance, phase acceptance or permission change is
asserted.

## Goal and ownership

Reach the two existing malformed owner-precommit Repository contracts through
real native authorization on the SAME MigrationRepo connection and RR snapshot.
Correct only the NEW Repository owning test's fixture composition. Preserve
all original assertions, cases, default timeouts, rollback and private-text
checks; add stronger native-call and exact-error witnesses.

Only implementation file:
`apps/singularity_storage/test/singularity/storage/knowledge_export/repository_test.exs`.
Parent owns this design, matching plan, master-plan reconciliation and report.
No production, shared fixture, existing helper, application/configuration,
released migration, grant, role membership/attribute, administrator repository,
credential, Vault, custody, capability, policy, key, lease or crypto change.
E2E NOT RUN/manual-only; publication and production activation remain excluded.

## Actual RED and permission evidence

Whole Task13 SQL initial16022:43 actual/12 FAIL; Repository ordinal-only repair1
54662:43 actual/2 FAIL, Runtime17 actual/0 FAIL. Remaining cases:

- real authorized precommit unsealed membership, test line402;
- real owner-role precommit ready-zero, test line793.

Both fail their existing required callback witnesses BEFORE Repository. The
test-local PrecommitOwnerScope selects table_owner before unchanged
OperationScope calls Authorize. IdentityRepository.load_live_session/2 calls
core.live_session_authorization(uuid), created as authorization_definer in
released20260718000800, with explicit web EXECUTE and PUBLIC revoked.
Actual owner permission is false and native invocation returns42501.

The first probe's suggested migration-to-web switch also returns42501; its
exit1/archiveef1a38e2 remains FAILED diagnostic evidence. No grant is added.
Existing bootstrap_roles.sql103–108 grants migration SET TRUE for
authorization_definer, not web. A second isolated probe14424/7f3047 exit0
verifies existing SET membership, actual function owner/EXECUTE, real no-row
function invocation, same backend/transaction/RR/off/GUCs, restoration to
table_owner and same-pinned-backend role/GUC cleanup.
Archive `.devenv/phase5-task13-precommit-definer-permission-probe.log`, SHA
`79abb898ec1543df4cebd07a946b36892171ccb79404fce9021af9f6c046852e`.
This proves permission/composition only, NOT live-session authorization.

## Selected bounded composition

Keep PrecommitOwnerScope, MigrationRepo's existing migration login, existing
authorization locks and unchanged ScopedRepo transaction. Content mutation,
canonical source queries and Repository capture still run as table_owner.

Add a test-local Identity-store decorator with load_live_session/3. Apply it
ONLY to private copies of the two tests' c.runtime.authorization. Capture and
delegate the fixture's actual ObservedIdentity adapter/context unchanged.
Keep runtime.authorizer exactly Authorize and the actual custodian unchanged.
Use the same decorated c in both the OperationScope initial check and the
existing lexical authorization(c,repo) closure; do not replace that closure.

Before every native delegation require expected caller, exact MigrationRepo,
active transaction, repeatable read/off, table_owner current role, migration
session user and exact existing principal/owner GUCs. Record only bounded
control witnesses. The binding checks are fixture guards, not authorization.

Use ONLY fixed SET LOCAL ROLE singularity_authorization_definer around the
UNCHANGED native identity delegation on that same repo. Return the EXACT
delegated result; no cache, fabricated session, copied authorization SQL,
capability injection, authorizer replacement or second connection.
The unchanged Authorize then checks actual session identity/epochs/revocation/
capabilities/classification and existing live custody unlock.

Restore fixed table_owner before returning and before any content query.
A bounded fixed savepoint around this read-only identity invocation is allowed
solely to restore role even if the native SQL aborts its subtransaction. It
must preserve the original delegate result/exception, outer RR snapshot and
existing owner writes. Setup/restore failure must fail the test and be reported
separately, never converted into expected Repository denial. Do not swallow an
error or let an aborted transaction satisfy a witness.

Pin the existing MigrationRepo connection through operation AND post-closure
cleanup observation. Verify same backend/transaction/caller/repo/RR/GUCs across
every native read, malformed owner state and Repository's repeated lexical
authorization. At least the required initial and capture checks execute; the
ready-zero test retains its explicit successful extra closure check. Require
every observed native read to return genuine live identity and restore owner.
After rollback, observe migration role, no active transaction, cleared GUCs
and released operation locks on that SAME pinned connection. Stop only the
test-owned supervisor in after.

## Required assertions and evidence classification

Unsealed membership keeps actual malformed-row/no-seal/rollback/no-text-leak
witnesses and must reach actual KnowledgeLinkRepository.read_membership/3.
Its real absent-seal not_found is mapped by existing Repository
unwrap_integrity/1 to exact integrity_failure. Add that exact-error assertion;
authorization/permission/storage errors cannot satisfy this content contract.

Ready-zero preserves actual claim/ready0/0/RR/current-role/GUC/native-session
witnesses, exact integrity_failure, source/attempt rollback, spool invalidation,
failed seal and neighbor sentinel. Preserve the separate real deferred-COMMIT
rejection cases and ALL real Runtime/web authorization/denial tests unchanged.

These are authenticated OWNER-role malformed PRECOMMIT probes which roll back,
not web privilege acceptance, committed malformed Runtime data, successful
COMMIT or authenticated-original-byte proof. Nothing is skipped/reclassified.
The complete earlier gates remain FAIL; repeat complete114pure/43SQL selections
and report actual counts, never substitute the permission probe for them.

## Review and completion

Independent actual SOURCE SPEC then distinct fresh QUALITY precede test-only GO.
Parent alone formats/runs complete selections/static checks, immutable source
receipts/frozen56 and DB/root/role/GUC/lock cleanup. No source authoring overlaps
those gates. Final actual Task13 nonauthor SOURCE SPEC and fresh QUALITY remain
required before small local commit or Task14 authoring. Ordinary failure enters
bounded Sol diagnosis/repair; Astra architecture advice consumes no repair round.
No routine approve request is needed under continuing development authority.
