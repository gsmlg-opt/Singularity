# Phase 5 storage-reference compatibility design

Status: DESIGN REVIEWED — implementation gated by preceding Task 8 acceptance.
Date: 2026-10-12. Actual independent SOURCE SPEC and separate fresh QUALITY
passed the architecture draft. Parent records are
`.devenv/phase5-task9-compatibility-design-spec-record.md` and
`.devenv/phase5-task9-compatibility-design-quality-record.md`; both explicitly
record actual verdicts, not verbatim transcripts. Reviewed draft SHA256 was
`bbfa64d615ef8c3b241d1e1a3ec07b1f75b7ea1f81b332cc26ee50e9bf5d7af0`.
This status update and the requested Storage citation clarification do not alter
the reviewed architecture. No implementation/runtime/phase acceptance is implied.
Continuous development authority covers this necessary compatibility work;
routine human approval is not required.

This supplements the governing
[Phase 5 design](2026-10-11-singularity-v0.2-phase-5-export-backup-design.md)
and [implementation plan](../plans/2026-10-12-singularity-v0.2-phase-5-storage-reference-compatibility.md).
Worktree: `.trees/v0.2-phase-5-export-backup`, inspected HEAD
`38b16f5d4a1f5d870a74d3e3093b3e2a2a0c5041`. Existing Task 8 and Task 13 edits
are parent-owned and preserved. This architecture assignment consumes no repair
round: received same-defect Sol 0, cumulative Astra 0.

## Problem and source evidence

Paths below abbreviate `apps/singularity_storage/lib/singularity/storage/`,
`apps/singularity_runtime/lib/singularity/runtime/`, or the Storage migration directory.

| Source | Established contract |
| --- | --- |
| `postgres/asset_repository.ex:2563–2575,2862` | Normal staged-object publication stores the object UUID as `storage_ref`. |
| `local_filesystem_adapter.ex:613–624`; `local/path_guard.ex:53–75` | Explicit owner/domain/lookup context determines the physical object path independently of the opaque reference string. |
| Runtime `custody_reader.ex:278–305`; Storage `authenticated_reader.ex:105–130,221–234` | Ordinary reads use UUID ObjectRefs; authenticated reader requires reference equal to object UUID and verifies header owner/domain/object identity. |
| `backup/knowledge_preflight.ex:1262`; migration `00300:1286`; new `00600:238–241` | Three Phase 5 predicates incorrectly require every available object's persisted reference to be a canonical path. |
| `backup/integrity_audit.ex:110–140,222,284–299`; Runtime `restore_integrity_lease.ex:211–212,405–435` | Existing integrity digest encodes UUID references; the frozen lease also requires reference equal to object UUID. |
| `backup/restorer.ex:169–185,442–455,1552–1562,1590–1617,3594–3617` | Parsed authenticated cut carries logical version; original cut/inventory equality and original saga inventory hash must survive rewrap. |

`KnowledgeBackupFixtures` constructs canonical path references from PathGuard
and writes real encrypted bytes. Its accepted preflight/import positives must
remain. They do not prove complete lease restoration. Task 8's separate UUID
SQL regressions characterize writer row shapes only: one initial Asset UUID
insert and one disposable PDF-object reference update preserve the existing
pins. Neither is evidence of actual normal publication or plaintext restoration.

## Fixed scope

Preserve all 56 frozen files, Vault/custody/key/capability/policy/crypto semantics,
the seven-application graph, immutable provenance, and every existing assertion.
No dependencies, role/grant changes, public API, production data/activation,
default V3 selection, merge/push/version/tag/release/deployment, or E2E execution.
E2E remains NOT RUN/manual-only. Existing V1/V2 import, reference validation,
wire/golden bytes and integrity behavior remain unchanged.

The separate preceding Task 8 repair changes only its unaccepted writer guard
to the two-form predicate below after its own review and causal RED. This
document covers the corresponding accepted preflight/admission corrections and
Task 9 integrity composition. It does not accept Task 8 or advance Task 12.

## Two inventories, one immutable object identity

Let `I` be the original authenticated V3 inventory. A reference is admissible
only if it equals the canonical `asset_object_id` UUID, or exactly:

```text
objects/<vault_id>/<key_domain_id>/hmac-sha256/<first-two-hex>/<lookup_digest-hex>
```

UUIDs and digest hex are lowercase canonical values. Check equality directly;
never normalize a supplied path. Reject another UUID, arbitrary opaque strings,
traversal, absolute paths, alternative separators, case changes and wrong
owner/domain/digest. Preserve existing shape, ordering, uniqueness and closure
checks; additionally reject repeated physical `(owner,domain,lookup)` identities.

Derive `N(I)` by changing only each entry's `storage_ref` to its existing object
UUID. Every other field and position stays identical. Persisted rows, wire
records, `cut.object_inventory`, Imported/Rewrapped inventories and the saga's
original inventory hash remain `I`, never `N(I)`.

For the actual LocalFilesystemAdapter with explicit owner/domain/lookup context,
both representations resolve to the same PathGuard path. Its implementation
uses that context's lookup digest, not the reference string. Accept path
conversion only for that actual adapter and complete context; do not assert
equivalence for arbitrary test or future adapters. UUID-only operation preserves
existing adapter behavior. Keep filesystem safety checks and authenticated
reader unchanged. The nondeleted-object unique physical-identity index remains.

Dispatch this bridge only on `cut.logical_version == 3` from the existing
authenticated parse. Do not infer version from references/table counts or add
fields to the cut. Unknown versions fail through existing dispatch. Legacy
versions retain their original path without global validator widening.

## Storage and Runtime integration

Add internal Storage `Backup.KnowledgeIntegrityInventory` with these boundaries:

- `project(storage, cut)` validates the V3 forms and physical equivalence and
  returns `{:ok, lease_inventory}` or an ordinary content-free Error. It is
  data conversion, not authenticated authority by itself. Validate the derived
  inventory through the unchanged V1 inventory validator/digest as well.
- `prepare(repo, storage, imported)` first validates original cut/handoff
  equality and committed imported-saga binding, then returns
  `{:ok, %{inventory: lease_inventory, material_loader: {__MODULE__, context}}}`.
  Validate exact manifest
  ID/hash/tag, owner, imported status, count, original inventory hash and the
  existing expanded destination-root hash. Compare the original inventory's
  exact persisted object fields and required closure in a consistent SQL
  transaction under existing migration authority. No new tables or privileges.
- `load_plaintext_material(context, binding, projected_entry)` checks the exact
  four-key existing lease binding (manifest, owner, Vault-key version and
  generation) against context; finds the original entry by
  inventory position; proves complete projected-entry equality; revalidates the
  saga, root binding and original persisted entry in one consistent transaction;
  delegates to existing `StorageIntegrityAudit.load_plaintext_material(repo,
  binding, projected_entry)` and returns its material unchanged. That existing
  function takes ONE entry, not the inventory. Its nested owner transaction must
  share the checked connection/snapshot. Context holds metadata, never raw keys.

The wrapper must check persisted `storage_ref` itself: the existing loader
does not select it or validate the saga. Reuse the existing original-inventory
hash algorithm (deterministic term encoding then SHA-256), with equivalence
tests; do not redefine the saga contract or hash projected data into its slot.
The physical root is trusted adapter configuration, never bundle/request input.

In Restorer, prepare the V3 lease options through a result-returning step before
issuer invocation and rewrap commit. Propagate projection/binding failures;
never fabricate invalid options as an error signal. Pass only `N(I)` to the
unchanged lease and configure the wrapper through its existing material-loader
port. Preserve all keys, bindings, generation values, owner PID, TTL, issuer,
capability, revocation and failed-commit handling.

Runtime IntegrityAudit retains `cut_inventory == object_inventory`, keeps `I`
as original evidence, and independently derives `N(I)` using actual configured
storage for both ciphertext and final verification. Ciphertext and lease
summaries must be the actual results over `N(I)`, validated through the unchanged
V1 inventory digest. Never widen `inventory_sha256/2`, change its encoding,
forge/rewrite a summary, or replace hashes to make equality succeed.

After plaintext-summary validation, Task 9's Document helper receives ORIGINAL
`I`, exact owner/manifest binding, and the authenticated ordered object/hash
pairs. It revalidates saga/original inventory identity and full object coverage,
then checks all Document pins, sizes/plaintext digests and ready historical
extracted digests before rebuild/completion. Asset-only entries remain valid.
Original reference spellings remain authenticated by bundle/saga evidence;
the unchanged lease summary attests the UUID physical-object view. These are
distinct commitments, explicitly checked together rather than conflated.

## Forward admission correction

Correct `KnowledgePreflight.objects!/2` to the same two-form predicate. Create
`20261011000700_knowledge_restore_storage_references.exs` to replace only that
predicate in `audit.assert_knowledge_restore_graph(uuid)`; keep accepted `00300`
unchanged. Prefer an exact function-definition transformation that requires
exactly one expected old clause. Abort on mismatch. No broad text substitution.
If definition formatting prevents a reliable exact transformation, use a fixed
complete CREATE OR REPLACE definition with source-equivalence proof showing
only this predicate changed. Preserve owner, ACL, signature, language,
volatility, SECURITY INVOKER, pinned search_path, all other guards and deferred
admission/destination-digest behavior. No runtime helper permissions are added.

## Acceptance and alternatives

Require UUID, canonical-path and mixed histories to preserve original rows and
wire evidence while passing actual unchanged-lease authentication. Counterproofs
cover wrong references, physical aliases, original/projected mismatch, saga/
root/owner/manifest mismatch, changed persisted material, wrong wrappers/header/
plaintext, and summary mismatch. Denial prevents rebuild/completion; committed
import/rewrap failures remain unpublished maintenance state, not false rollback.

Reject persisted-reference normalization, dropping canonical-path positives,
changing the frozen lease/reader, altering the V1 digest, or correcting only the
writer. UUID-only fixtures would hide accepted compatibility and cannot qualify
real normal publication. The additional adapter is justified by the frozen
lease's UUID contract and the independent original-evidence commitment.

Architecture inspection ran no tests/SQL/services. Frozen registry SHA-256:
`d0296d241c66e382baa09a0a092fe8add6df66364d5f2d5644f4f4ea1963a050`.
All 56 entries passed the preceding read-only checksum check. Required live
tests, migration-definition equivalence and independent review remain pending;
no source/runtime acceptance is implied by this document.
