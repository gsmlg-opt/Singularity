# Task16 native fixture arrangement amendment

## Authority and evidence

Continuing local-development authority permits these necessary test-contract
repairs. This supplements the committed-transfer design and plan, not production
behavior. Independent DESIGN SPEC then a distinct DESIGN QUALITY must pass
before the parent edits the named native test. Task16 remains unaccepted.

Worktree: `.trees/v0.2-phase-5-export-backup`; branch
`codex/v0.2-phase-5-export-backup`; HEAD
`8fb1142ee593641544769658d03a96cb83ebaa56`.
Native test candidate8 SHA256 is
`0bb74a2e80844a7e640b70eacf86644300ea4f1ee951049abe228422131e2606`.
Raw077 SHA256 is
`e300cf767647042110979f4b29423400b5de325807323942e91cbd25be50ec63`:
118 Runtime tests, three failures; Storage executed three, zero failures;
102 migration-module warnings. Its own078 post is EMPTY/0. Preserve these
failures as historical evidence, not successful qualification.

Read-only diagnosis establishes:

1. Export serially traverses versions sorted by `{resource_id, version_id}`.
   Independent random Asset/Document UUIDs can place Document first. At its
   first genuine storage barrier the issued ledger then correctly contains one
   lease, not the both-kinds prefix the cancellation test requires. The raw
   proves that prefix, not the actual UUID comparison.
2. New `transfer_start!` inherits `block_read_kind: :asset` from the material
   observer. After the four actual SQLSTATE55P03 checks and material release,
   an unintended second CompositionReader barrier blocks the read. Raw077
   observes that barrier; production locks need no change.
3. The aligned fixture is 4,194,308 bytes (4MiB plus `"tail"`), not 4MiB+1.
   Asset preflight and reduction each perform65 genuine <=65,536-byte reads,
   with fresh acquisition, actual initial/post commits and record authentication.
   Raw077 observes real progress but no final result at20s. It does not prove
   eventual success, an exact completed pass, or a production deadline failure.

## Selected surgical repair

Only `apps/singularity_runtime/test/singularity/runtime/knowledge_export_custody_live_test.exs`
may change. No production, Vault, SQL schema, dependency, fixture support module,
runtime timeout or original raw/manifest change is authorized by this amendment.

- Opt in only the two retained requester/owner inflight-Document cancellation
  cases with `ordered_resources: true` in their existing barrier map. A new
  helper returns an explicit Document resource ID only for that exact opt-in
  storage/Document shape. Derive it from the genuine random binary Asset UUID:
  preserve all bits except its version nibble4 becomes5. Thus Document sorts
  strictly after Asset in binary and canonical text order and is a distinct
  valid UUID. All other callers receive the existing empty attrs map.
- Change the one shared fixture construction call to pass those attrs through
  the already-existing `KnowledgeFixtures.document!/2` API, before insertion.
  Add assertions for ordering and distinctness. This explicitly supersedes the
  prior prohibition on changing that single old shared-fixture call; preserve
  its exact inverse to candidate8 and then all original81 baseline inverses.
  Do not reorder production, retry random fixtures, insert fake ledger entries,
  manufacture leases, mutate persisted IDs, or replace the real read barrier.
- Only in new `transfer_start!`, set `block_read_kind: nil` in its wrapper
  context. Do not modify the actual custody material/storage observer, shared
  CompositionReader helper, lock witnesses or barrier deadlines.
- Only the new Asset/aligned positive case receives an explicit120,000ms
  completion wait and180,000ms per-test ExUnit timeout. Other generated cases
  retain20,000ms; all global/default/old timeout contracts remain unchanged.
  These bounded synchronization limits are not product performance claims.
  Native acquisition remains5s, each fresh native leaseTTL60s, Artifact lifetime
  900s. A sequence of130 separately leased reads has no aggregate20s contract.
  The rerun must establish actual complete success; any error, timeout or
  deadline failure still fails qualification and requires diagnosis.

Every byte-size, full hash, maximum piece, actual native/COMMIT/audit order,
both-kind minimum, ALL-issued-inactive, owner/companion DOWN, owned cleanup,
unaffected independent custody and sentinel assertion remains in force. No
assertion is deleted, skipped, broadened, or converted into a weaker alternative.

## Attribution and acceptance

Parent records exact unique old/new replacement literals with unchanged
two-sided anchors, then inverts the entire new native delta to candidate8
`0bb74a2e...`. Existing inverses must still recover `ab101a81...`, `4b3e34f0...`,
`61f48e40...` and original81; no new accepted old baseline. Derive new guard and
27-file manifest names for the25 existing candidates plus this pair. Never
overwrite prior guard/manifest/raw evidence or regenerate a historical baseline.

Read and Export remain byte-identical at respectively `4fdee38a...` and
`dab8881c...`. Sol production repair rounds0 and Astra implementation0 are
unchanged by this test-only repair. Record test-arrangement repair separately.
Run the full exact Runtime-then-Storage seed215379 replay and reverse order
seed215378, each naturally closed with its own actual ordinary post EMPTY/0.
All original Task16 gates, actual formatter attribution, independent SOURCE
SPEC then NEW distinct QUALITY, and local-only commit requirements remain.
No E2E, merge, push, version/tag/release, deployment or production data work.
