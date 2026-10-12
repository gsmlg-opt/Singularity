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

Task9E amendment status: actual NONAUTHOR DESIGN SPEC then distinct fresh
QUALITY CLOSED PASS/noP1P2 on design c161d673/plan bf434b49/master design
78848c2e/master plan13ba6ee2, after complete parent/reviewer reads. Captures:
`.devenv/phase5-task9e-amendment-design-spec-review.md` and
`.devenv/phase5-task9e-amendment-design-quality-review.md`. Earlier C/D history
is preserved and does not qualify E. Unchanged existing-owner baseline48pure/0
and35SQL/0, normalEMPTY/rootabsent and frozen/native checks passed. Test-only
GO is issued at local HEAD `4e2499d5b89664c3e7b63cb1f3136c243b276c83`;
production authoring still waits for complete causal RED. This status-only
update changes no reviewed architecture and consumes zero repair rounds.
Task11 remains separate; subsequent bounded test evidence is recorded below.

Task9E test-fixture correction status, 2026-10-13: first pure compilation FAIL
archive9bee787a is preserved. The exact four-name correction renamed local
`binding/1` and its three calls to `document_binding/1`, changing formatted test
ec424f86 to b85734a0 without other byte changes. Compiled whole pure gate d695d2
closed exit2:88 actual/27 failures (3 missing format seam,24 Runtime wiring,
order and validation),45 SQL exclusions. Full archive SHA256:
`53ec0a2e45fbba574eecd1d948683d333429980df5d6ebf6bf45a5bb8e75327b`.
Four actual native reader empty/chunk-edge cases passed; this does not qualify E.
First whole SQL17497 closed exit2:70 reported/25 excluded/45 actual,10 cleanup
failures masking primary outcomes,35 retained SQL cases passed. Full archive:
`60f526299acc41ad3f4d87e8d012a97b10373544b8d95e380e8229530cd2e148`.
It is not causal SQL qualification. Owned root2c53e0b41aa3a5a1c5ee1478 is absent
and normal PG maintenance24169d0 closed EMPTY; maintenance archive:
`ea9b9ff7f553d8f0786b2fc23d72fa1fb9174d41ff7eaae95b3a10c58be4c346`.
The bounded snapshot-lifetime fixture correction is authored, not qualified;
actual NONAUTHOR review and complete parent pure/SQL reruns remain pending.
Compile correction is separate; snapshot-fixture correction attempt1;
E production repair0/Astra recovery0. Original reviewed architecture/hash
receipts remain historical evidence; no E production authoring GO is implied.

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

TaskD's actual required xref gate exposes a file-level cycle when the bridge
expands `%Restorer.Imported{}` while Restorer calls the bridge. Preserve the
same exact struct-tag pattern with `%{__struct__: Restorer.Imported}` instead:
the module atom literal has no struct-expansion dependency. This is a bounded
compile-dependency repair, not generic-map acceptance or a runtime dispatch
seam. Every field, original term hash, saga check and error path stays unchanged;
whole C/D gates and actual independent reviews must qualify the exact source.

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

## Task9E: unfrozen composition and exact evidence contract

The current Runtime `integrity_audit.ex:105–125` validates the actual typed
`RestoreIntegrityLease.PlaintextSummary` before rebuild. Its target already
retains original I (`:285–291`), while `search_binding/1` returns exactly
`%{manifest_id: ..., vault_id: ...}` (`:270–271`). Preserve those boundaries.
Add internal `Backup.KnowledgeIntegrityAudit` in
`apps/singularity_storage/lib/singularity/storage/backup/knowledge_integrity_audit.ex`:

- `verify_document_sources(repo, binding, original_inventory, plaintext_hashes)`
  delegates to `KnowledgeIntegrityInventory.verify_document_sources/4` and
  returns `:ok | {:error, Error.t()}`.
- `rebuild(repo, binding)` initially delegates unchanged to
  `Backup.IntegrityAudit.rebuild/2`, including its result and error semantics.
  Task10 later owns unified knowledge rebuild in this unfrozen facade; it must
  preserve the native Asset/Note behavior and unchanged legacy Base rebuild.

Compose V3 `search_rebuilder` as `{KnowledgeIntegrityAudit, MigrationRepo}`.
Keep ciphertext and audit-completion adapters unchanged. Runtime's existing
module `/3` or contextual `{module, context}` `/4` callback dispatch remains;
no new context configuration key, behaviour module, process or registry.
The dependency direction is facade -> inventory helper -> existing Base, and
facade -> Base rebuild. Never add a Base -> inventory-helper delegate: the
helper already calls Base material loading at `knowledge_integrity_inventory.ex:105`,
so that reverse dependency would create an xref cycle.

Retain logical version in Runtime's private target from the authenticated
Imported/Rewrapped cut, never a request option, adapter choice, table count,
reference spelling or hash list. Explicit V3 requires both the Document
callback and rebuild before final verification proceeds. Explicit V1/V2 and
the established legacy map path with no logical-version field retain the old
requirements and sequence; an explicitly unknown version is not a legacy
fallback. No new caller-selectable version/authority field is added to the cut
or any frozen handoff. This remains trusted internal adapter composition, not
authentication of an arbitrary caller-created map.

For V3 only, after successful `validate_plaintext_summary/3` and before rebuild:

```elixir
:ok <- adapter_ok(call(adapters.search_rebuilder, :verify_document_sources,
  [search_binding(target), target.original_inventory, plaintext.plaintext_hashes]))
```

The actual typed summary and its owner/count/N(I)-digest/ordered-hash validation
remain unchanged. Never rewrite or manufacture a summary. Missing callback,
malformed result or any helper error prevents rebuild and completion, and the
existing `after` revocation still runs. V1/V2 adapters need no new callback.

The Storage helper validates exact two-key binding, canonical IDs, exact
nine-field original inventory entries, canonical ordering/positions, unique
objects/physical identities and exact accepted reference forms. It may derive
the UUID view for the unchanged inventory validator, but hashes original I for
the saga and compares original persisted references without normalization.
No size/format fields are added to either inventory. Require exactly one map
with only `asset_object_id` and a 32-byte `sha256` per entry, in inventory order;
reject duplicate/missing/extra/reordered evidence and extra map keys.

In one fresh existing migration-authority repeatable-read transaction, require
the singleton saga's manifest/owner/imported state/count and original inventory
term hash, full required-object closure and exact persisted original metadata.
Reuse C's established closure/transaction helpers without changing their
accepted behavior. `consistent_transaction/3` (`:303–339`) rejects nesting and
expects an internal `{:ok, value}` callback: unwrap success to public `:ok` at
the new helper boundary. Sanitize errors with existing content-free Error
codes; no source bytes or individual object hashes in logs, telemetry,
exceptions or job/audit data. Existing aggregate completion digests stay intact.

This `/4` interface lacks expected manifest hash/tag/root and lease-key binding.
Do not fabricate a full C.Context, copy database values into supposed expected
authority, or claim independent revalidation of those absent inputs. Actual
C/D preparation/material loading already checks those commitments; E checks
the manifest/owner/original-I identity available through its own contract.
The helper is internal and consumes already authenticated evidence; it cannot
make a bare list of caller-supplied hashes authenticated by checking its shape.

Check every Document version, including old, deleted and all non-ready states:
exact owner/classification/resource/version/Asset/association/object pins,
retained available object, source size and authenticated plaintext digest.
Retired source Assets may have null object pointers and released associations;
do not reintroduce live-Asset admission. Asset-only inventory entries remain
valid. Stream ready-version fragments in version/ordinal order, enforce the
existing per-version bounds/contiguous ordinals and canonical fragment identity,
then compare incremental SHA-256 of UTF-8 text with no delimiter against each
stored extracted digest, including non-head/deleted ready versions. Select
ready versions independently so a missing fragment set cannot disappear in an
inner join. No body or whole-corpus collection and no canonical writes.

### Format-1 size proof, independent of mutable material

The frozen summary has no sizes (`restore_integrity_lease.ex:49–62`). Base
material loading selects CURRENT object size/format (`backup/integrity_audit.ex:327–329`);
no lock spans native plaintext verification and this later helper. Current
Document/Object size equality alone does not prove the size previously read.

`Crypto.Format` publicly fixes version1, header66, chunk4,194,304 and data/final
counter bounds (`crypto/format.ex:14–17,29–45`). Frozen AuthenticatedReader uses
24-byte data-record overhead and 68-byte final record (`:15–16,165–189`), checks
the canonical layout/chunk count, then authenticates final length/count/hash
(`:380–388`). Therefore, for nonnegative integer P with a supported chunk count:

```text
n = div(P + Format.chunk_size() - 1, Format.chunk_size())
C(P) = Format.header_size() + P + 24*n + 68
0 <= n <= Format.max_data_counter() + 1
```

Require each Document's `source_byte_size` in 0..67,108,864 and
`C(source_byte_size) == ORIGINAL_I_entry.ciphertext_byte_size`; also require
current Object format1 and size agreement. Use public Format constants for
version/header/chunk/counter bounds; do not modify Format, reader or crypto.
The overhead constants describe their existing format1 contract, not a newly
configurable encoding. C(P) is strictly increasing (step1 within a chunk,
step25 at a boundary). Successful actual native authentication of the same
attested ciphertext length therefore establishes exactly one P, independent of
later metadata changes. This implication requires real reader/lease success;
fixture-known hashes or recording adapters do not establish its premise.

If a pure seam is needed, add only internal `@doc false`
`KnowledgeIntegrityInventory.validate_plaintext_size/2` for the exact size law,
returning `:ok | {:error, Error.t()}`. It accepts valid format1 integer sizes
and supported chunk counts; apply the stricter Document maximum at the Document
callsite, not to ordinary Asset-only originals. No new module/public API.
Use these independently fixed literal vectors, never expected values computed
by the function under test:

| P | C(P) |
| ---: | ---: |
| 0 | 134 |
| 1 | 159 |
| 4,194,303 | 4,194,461 |
| 4,194,304 | 4,194,462 |
| 4,194,305 | 4,194,487 |
| 8,388,607 | 8,388,789 |
| 8,388,608 | 8,388,790 |
| 8,388,609 | 8,388,815 |
| 67,108,864 | 67,109,382 |

Add adjacent wrong ciphertext lengths, gap values, negative/noninteger/missing
sizes and chunk-count overflow without allocating huge binaries. Independently
qualify empty and chunk-edge actual encrypted originals through the unchanged
authenticated reader. The four native reader cases passed in the compiled pure
gate above; size-law/helper and full live-composition qualification remain pending.

### Causal import/helper tests and the one fault-injection exception

Use public `KnowledgeBackupFixtures.with_destination(:current, ...)`, `seed!/1`,
`canonical_rows/1`, `source_bytes/1`, `verified_bundle/2`, `transformed_bundle/2`
and `malformed_bundle/2`. Its seven versions cover ready old/current/deleted,
pending, extracting, failed and unsupported, with PDF bytes retained only by
Documents after source Asset retirement (`test/support/knowledge_backup_fixtures.ex:107–129,431–439`).
Freshly authenticate portable fixture bytes using actual LocalDestination,
BundleReader and LogicalBundleVerifier, then actual Restorer.import into a
different empty owned migrated destination. Reuse public contracts, not copied
private test-helper bodies. Establish genuine committed import and original-I
persisted equality before exercising E; no forged Verified, saga or authority.

The owning test helper observes the returned LocalDestination public
`file_system.close_snapshot` callback without replacing native filesystem work.
BundleReader.reduce_verified consumes the one-shot Replay and closes it once;
LocalDestination returns `:ok` only when the actual native close succeeds.
Delegate the original callback exactly and preserve every return or raised
outcome unchanged. A helper-owned two-counter atomic reference records actual
successful closes and foreign-owner closes, without content, keys, authority,
Replay/device inspection, messages or process-dictionary state. Require zero
successes/zero foreign closes after genuine authentication before import, then
exactly one success/zero foreign closes immediately after genuine import and
before the callback. The unconditional finalizer discards verified input only
when no successful close was observed, requires its actual `:ok`, and then
requires exactly one success/zero foreign closes. A consumed Replay is never
discarded again by this helper. Duplicate or foreign successful closes fail;
`:einval` never counts as success or changes its returned result. Existing
Restorer cleanup and every semantic assertion/default timeout remain unchanged.
The existing disposable-destination finally still cleans owned resources even
when authentication, import, semantic verification or close assertions fail.

For wrong source digest, transform ALL Documents sharing the selected object
to the same wrong32-byte digest before authenticating/importing. Preflight and
admission agree structurally; actual native plaintext authentication succeeds
and the helper must reject the independent digest mismatch. For the stronger
wrong-size witness, transform all sharing Documents AND the Object to the same
wrong size before import. After genuine commit, correct only mutable Object
size for an actual authenticated-reader read, then restore the wrong Object
size to match the immutable wrong Documents. Helper denial must depend on
original ciphertext length, not current Doc/Object inequality. Keep native
bytes/hash/count and every other pin/reference unchanged, record each committed
transition, and assert no completion. A known fixture hash alone is insufficient.
If the existing public frozen-lease composition is readily available, qualify
that same sequence with actual RestoreIntegrityLease as stronger evidence;
otherwise leave that native-lease witness explicitly to Task11, NOT RUN.

After genuine import, independently reject missing/duplicate/extra/reordered or
malformed hashes, foreign binding, changed persisted original reference and
projected N(I) substituted for path-containing original I. Prove positives for
UUID/canonical/mixed references, all retained states and Asset-only entries.
Runtime recording tests separately prove summary -> helper -> rebuild -> audit
ordering, exact arguments, fail-closed denial and capability revocation. None
of those recording tests qualifies actual reader, lease or normal publication.

The required ready-history extracted mismatch cannot be produced through valid
public writes: released lifecycle guards reject it, admission rechecks all ready
digests, and version completion independently rejects it at deferred commit
(`20260922000300:95–145`, `20261011000300:1218–1235,1466–1496`,
`20260906000200:375–411`). Preflight denial is not helper evidence; an outer
rollback-only transaction also fails E's nonnested transaction contract.

Select ONLY this necessary test-contract exception under continuing local
development authority, after this amendment's independent design reviews:

1. In `document_restore_integrity_test.exs` only, allocate an owned disposable
   current-migrated destination with genuine committed import and successful
   helper baseline. Snapshot actual trigger definitions, their function
   definitions and enabled states for Document versions/fragments and admission;
   snapshot Document-table RLS enabled/forced flags, policy definitions and ACLs.
   Require the original named guard enabled, all expected guards present and
   ordinary immutable fragment UPDATE rejected before fault injection.
2. Select exactly the old ready non-head version's ordinal1 fragment. Assert
   zero references from every actual FK referencing its identity, including
   note_citations/search_entries, before changing its ID. The fixture uses
   ordinal0 citations (`knowledge_backup_fixtures.ex:617–634`); this source fact
   does not replace the live zero-reference check. Construct a different valid
   text/digest/id tuple with actual `Core.DocumentFragment.new/1`, keeping
   owner/classification/resource/version/ordinal/locator/inserted_at unchanged.
3. In a SEPARATE native transaction under existing migration/table-owner
   authority, first execute `SET CONSTRAINTS ALL IMMEDIATE`, following the
   existing lifecycle fixture's transaction-local timing. Every active deferred
   constraint then executes during UPDATE rather than remaining queued when
   ALTER must restore the guard; none is disabled or suppressed. Disable only
   named `document_fragments_immutable_guard` on
   `content.document_fragments`, update that one tuple with exact old identity
   and UPDATE RETURNING assertions, and ENABLE that same trigger BEFORE COMMIT.
   Keep every other trigger and all RLS active; no ALL/USER trigger disable,
   replication-role change, function replacement or schema/grant change.
4. Observe real native COMMIT, not callback return alone. The existing deferred
   `document_fragments_completion_check` stays enabled: its released function
   returns for fragment events whose parent is already ready
   (`20260906000200:383–386`). Do not update the parent Document or admission:
   those changes would queue independent rejecting checks. The fragment remains
   canonical while its parent's stored concatenation digest is now wrong.
5. Assert exact restoration of the trigger/function/enabled-state/RLS/ACL
   snapshots and an ordinary forbidden UPDATE still rejected in a separate
   rolled-back transaction. Any injection error rolls back its DDL and data;
   verify restoration on that failure path too. Run E only afterward in its
   own fresh consistent transaction; require the extracted-history rejection,
   imported saga retained, zero integrity-completion event and unpublished
   maintenance destination. Unconditional fixture cleanup remains required.

This single test exception is not released-migration, production, general
historical replay or Vault authority. Do not add a reusable corruption service,
shared fixture bypass or optional production switch. Do not disable the version
lifecycle/completion guards as an alternative. Its causal native baseline,
successful corruption commit, restoration and helper denial are NOT RUN until
parent verification; no required assertion is waived if that witness fails.

Task9E qualifies its algorithm, helper/import boundary and actual reader cases
only. Task11 must still prove normal Asset publication -> V3 backup -> native
import/rewrap -> actual unchanged RestoreIntegrityLease and wrappers -> helper
-> unified rebuild -> completion, including UUID/canonical/mixed inventories.
No E gate or fixture-known value substitutes for that live composition.

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

## Native ready-fragment witness timing correction

Initial E implementation pure gate20f81b passed88actual/0fail/45SQLexcluded.
Complete initial SQLdd7b31 failed1of45actual (44PASS,25pureexcluded),453.5s:
the historical-fragment helper baseline/rollback checks passed, but re-enabling
the single immutable guard raised native55006 pending trigger events. Its
required corruption COMMIT and subsequent extracted-history denial were NOT
REACHED. Actual NONAUTHOR SOURCE SPEC CLOSEDFAIL1P2, no E production finding.
The full failed loga4291e1c and native cleanupedb02d0c remain preserved; root
1d9480339f3a511644146dcf absent75307f and maintenancef888ea closed0EMPTY.

The bounded test-only correction sets constraints IMMEDIATE inside the same
mutation transaction BEFORE disabling the one approved guard. This follows
document_lifecycle_test.exs:249 and the released ready-fragment return path;
all FK/completion/admission checks remain active and run earlier, with no
released migration/function/trigger/RLS/ACL/source/timeout change. All rollback,
native COMMIT, exact restoration, ordinary UPDATE denial and independent helper
assertions remain. Exact correction SPEC/freshQUALITY and full parent reruns
are pending; this does not qualify the witness or E. Prior compile and snapshot
fixture failures/correction attempt1 remain separate retained history, not reset;
this is native constraint-timing fixture repair1, Eproductionrepair0/Astra0.
