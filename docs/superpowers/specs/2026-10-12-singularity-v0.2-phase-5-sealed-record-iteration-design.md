# Phase5 sealed-record iteration repair design

Status: final design SOURCE SPEC and distinct fresh QUALITY closed without
remaining findings; TEST-ONLY source closed and whole pure5 causal RED recorded
in the repair plan. Production repair1 passes whole owning/retained gates;
actual source SPEC passed; fresh QUALITY found two additional full-path P2s
documented in the repair2 amendment below. Local handoff remains pending. This is a
necessary Task15 quality repair under continuous local-development authority,
not a new product feature, authority seam or completed phase.

Governing [Phase5 design](2026-10-11-singularity-v0.2-phase-5-export-backup-design.md),
[master plan](../plans/2026-10-11-singularity-v0.2-phase-5-export-backup.md) and
[repair plan](../plans/2026-10-12-singularity-v0.2-phase-5-sealed-record-iteration.md).
Worktree `.trees/v0.2-phase-5-export-backup`, baseline09f8ee0. Source ownership
remains parent-managed; concurrent Task14 and TaskD edits must be preserved.

## Evidence and root cause

Actual nonauthor Writer SOURCE SPEC closed without findings; distinct fresh
QUALITY by phase5_writer_source_quality found one P2. Parent factual record:
`.devenv/phase5-task15-repair1-quality-finding.md`. Writer4681a19e, all50 owning
Testsa1d596e8 and formatdocument902a8a8a remain pinned historical evidence.
Root independently read the actual loops and the entire Spool.

Writer `capture_index!/1` at405 calls `index_page!/5`; line414 requests one
Spool metadata record per iteration. `captured_record!/3` at438–443 repeats
that one-record page for every append. Spool `read_page/3` at85–96 rebuilds all
collection keys, sorts them and fully filters them before taking a page.
Two N-record passes therefore do O(N^2 log N) sorting and O(N^2) key-list
allocation. The fixed15-minute lifetime makes this an avoidable scaling risk.
This is a static finding, not measured million-row latency or a claim that the
existing116/0 owning gate failed. That gate does not bound traversal work.

Existing Spool frame readers prove actual on-disk size/hash and filesystem
identity. However `checked_payload/2` discards index-selector bytes. Initial
SOURCE SPEC found a same-ID resource/tag catalog swap would pass that primitive
and key equality. The corrected additive metadata-specific reader must bind
the requested collection to its native index selector and payload reference;
existing paging/chunk readers remain unchanged. This is design correction0,
not a failed implementation round or a changed historical GREEN.

## Fixed boundaries

Do not change Vault/custody/key/capability/policy/lease semantics, frozen56,
accepted migrations, Repository capture/source-selection semantics, wire or
portable schemas, original selectors, lifecycle/cleanup ownership, runtime
configuration, quotas/deadlines or dependencies. No public request adapter,
path, cursor, limit, tracing or performance option. No global registry, new
process or corpus-payload cache. E2E NOT RUN/manual-only; no merge/push/version/
tag/release/deployment/production activation or backfill.

Spool is accepted Task13 source, not a frozen file. Its existing open/append/
seal/read_page/read_chunk/abort contracts, private frame format, cursors and
their authentication remain unchanged. A small additive internal read port
is authorized only after this design's actual SPEC and distinct fresh QUALITY,
causal RED and parent source GO. Retain all existing tests and assertions.

## Selected internal interfaces

Add two plain Spool functions, usable only with the actual sealed capture:

```elixir
Spool.read_metadata(sealed, fixed_collection_atom, exact_record_key)
# {:ok, exact_decoded_record} | {:error, content_free_error}

Spool.reduce_metadata(sealed, fixed_collection_atom, initial, consume)
# consume.(one_exact_record, accumulator) -> {:ok, next} | {:error, Error.t()}
# {:ok, final_accumulator} only after the complete ordered traversal closes
```

`read_metadata/3` validates readable sealed identity/phase/deadline/filesystem,
uses the existing collection map's exact key (no coercion or normalization),
reads both real index and payload frames through a new metadata-specific helper
reusing unchanged `read_frame/3`. Decode native index bytes and require exact
equality with the four-key map: selector `["metadata", collection_name]`,
payload offset, length and lowercase SHA256 from the selected payload frame.
Decode one payload record, require existing `metadata_valid/3` (including the
accepted pending Asset draft rule) and
`record_key(collection, record) === supplied_key`.
Unknown collection/key or invalid arguments deny; frame/catalog mismatch or
native corruption follows existing fail-closed owned-capture cleanup. No file
descriptor remains open across the consumer and no error contains payloads.

`reduce_metadata/4` checks readable before traversal, sorts that collection's
identity keys once and walks the list once. Each step uses `read_metadata/3`;
one record reaches the trusted consumer, never an array of payload records.
Successful final return repeats readable even for an empty collection. Ordinary
consumer Error is sanitized and propagated without falsely claiming native
capture corruption; exception/malformed callback success returns a content-free
failure. A reader's genuine failure/expiry keeps existing cleanup semantics.
The accumulator is a trusted BEAM implementation detail, never request input.

No new retained ordered index is added to the capture. The bounded temporary
identity list contains no bodies/labels/records. Sorting is O(N log N), one
read traversal O(N), and each exact append lookup has no collection scan/sort.
This does not promise a maximum elapsed time for million-row exports or remove
the fixed deadline. Final-artifact entry pagination is a separate existing port.

## Writer composition and accounting

Replace only capture indexing and exact captured-record retrieval. Writer
builds `_captured[collection]` as exact key-to-presence metadata through one
`reduce_metadata/4` call. No decoded record payload is stored in that index.
Record payloads still go only to the existing private native `.records` journal.
`captured_record!/3` requires indexed membership and calls `read_metadata/3`;
the existing complete record equality and SHA checks remain active.

Charge every retained identity entry before insertion: encoded
`[capture_id, collection_name, exact_key]` bytes plus the existing40-byte
reference/framing allowance, and one metadata record. Combined capture+Writer
metadata/byte ceilings, selected-key bounds and every journal/file/manifest
charge stay fixed. The presence entry has no cursor/proof payload, so its charge
reflects its actual smaller representation, not an increased quota. Add a
near-limit counterproof showing new index insertion still denies at the ceiling.

Do not alter original folds, text/reference checks, source descriptions,
publication reservation, ETS/atomics lifetime/ownership or cleanup paths.
Task16 still requires a genuine supervised artifact owner/ETS handoff test.

## Causal and retained verification

Before production edits, add a native deterministic Writer regression using a
real sealed capture with501 extra Notes. During actual Writer.open and append
all captured metadata from the fixture's known records (not a paginated helper),
scope arity-only call tracing to that one test PID. Count `Spool.read_page/3`
calls and `Enum.sort/1` calls whose input is a list of at least501 identities.
Expect no one-record pagination path and exactly two large sorts (resources and
versions), once per large collection. Current source must fail causally.

Reuse the existing Repository test's separate tracer PID, exact original trace
flags/pattern checks, `trace_delivered` barrier and unconditional restoration.
The traced callback closes its owned Writer synchronously in `try/after` on
both success and failure BEFORE trace barriers/counter collection/restoration.
Return only immutable accounting for subsequent assertions. An `on_exit` abort
cannot replace this cleanup because test-owned ETS disappears with its PID.
This closes fresh QUALITY's proposed-test cleanup P2; actual final full-document
SOURCE SPEC and distinct QUALITY both closed PASS at reviewed design ed5f601e
and plan c67f0fa1. These factual status updates do not change the reviewed ports.
Never trace argument/return payloads, log content, use arbitrary sleeps or add
production diagnostic knobs. Trace match-spec filtering inspects only list
length; messages contain MFA arity, not values. The test proves bounded work
for its actual fixture, not production-scale timing. Independent review must
also verify the static one-traversal/no-scan dataflow.

Add direct Spool positive/negative tests: exact same native metadata as existing
pages; deterministic complete order/empty collection; wrong key/collection;
swapped catalog-key mapping, same-ID cross-collection frame swap and native
wrong-index-reference substitution; real payload/index corruption; stale/aborted/
expired/identity-drift captures; consumer cancellation/error/exception and final
readability. Retain all50 Writer cases and existing Spool/Repository/Snapshot/
Core pure/live owner gates, source/frozen receipts and normal cleanup checks.
No source author may overlap parent formatter/Mix/SQL/service commands.

After whole GREEN, obtain actual nonauthor SOURCE SPEC then distinct fresh
QUALITY for changed Spool/Writer/tests and dependencies. Record exact source,
commands/counts/exclusions, previous FAIL and this finding, scoped risk and local
commit only after review. Neither this repair nor Writer GREEN accepts Phase5,
Task14 live custody, Task16 artifacts, browser behavior or publication.

## Full materialization amendment — cumulative scalability repair2

Status: actual nonauthor design SPEC and distinct fresh QUALITY CLOSED PASS,
reviewed interface hashes711deca5/4131e4b4. Parent controls test-only GO after
all native gates/authors close; no production GO before complete causal RED.

Actual source SPEC on repair1 passes; fresh source QUALITY closes two P2s
(record .devenv/phase5-sealed-iteration-repair1-quality-findings.md,6a7ff820).
The complete Writer still performs F_included*F_total fragment-key work at609,
N_notes*(A_total+C_total) source-key work at679, C_total*F_total citation work
at808, and approximately1+...+K file-ledger copying via ETS.tab2list at1265.
Parent independently inspected these methods, all callsites and fixed Core paths.
The180/0 repair1 native gate remains GREEN; it does not close these full-path
findings. Preserve cumulative Task15 scalability round1 NOT ACCEPTED; the next
bounded Sol round is repair2. If its same full-path outcome still fails, escalate
to bounded Astra recovery. Architecture attempts are not recovery rounds.

Alternatives: retain corpus scans (cannot meet bounded traversal); retain decoded
record caches (unnecessary payload retention); selected once-built charged
identity-only grouping plus fixed directory lookups. No new process/config/API.

### One-time charged identity groups

Build the following private auxiliary indexes in the existing ordered capture
index reductions, before Writer creates ETS or staging:

- Fragment counts: exact {resource_id, version_id} -> integer count.
- Fragment identities: exact {resource_id, version_id, fragment_id} -> full
  {resource_id, version_id, ordinal, fragment_id} key. A second distinct key for
  that identity marks it ambiguous; do NOT reject early solely because this
  unused identity is ambiguous. A citation still requires exactly one matching
  appended fragment at closure, with its unchanged exact locator comparison.
- Source groups: collection attachments/citations -> exact
  {note_resource_id, note_version_id} -> ordered list of full source record keys.
  Derive only identity keys, no labels, text, locator, payload or cached records.
  Native ordered reduction already orders these tuple keys; prepend then reverse
  each group once at index completion. Per-Note reads get only that exact group,
  and retain exact item count, IDs, target/version/role/label/locator comparisons.

All values come from actual native read_metadata validation, never request input.
Charge every retained auxiliary group header/member/map entry before insertion:
canonical JSON identity encoding including capture ID, fixed index kind, exact
key/value plus the existing40-byte framing/reference allowance, and one metadata
record. A count update charges any positive encoded-size delta before replacement;
no refund, quota bump, or uncharged side dictionary. A duplicate fragment identity
may replace its retained key with an ambiguity marker without refund; it stores
no list of duplicate payloads. Group members are charged individually, group
headers once. Fixed combined capture+Writer1GiB/1M ceilings apply throughout;
ordinary budget denial does not falsely corrupt the sealed capture. Group reverse
walks contain identity keys only and their temporary references remain within
these charged allowances. No new limit or caller override.

write_fragment uses the exact captured per-version count, preserving actual
ordinal/UTF-8 offset/size/hash/final extracted-digest checks. verify_descriptions
uses only the exact ordered Note source group, retaining native journal rereads
and every existing comparison. verify_closure uses the exact fragment identity
lookup and requires an unambiguous full key present in appended records before
native journal reread and locator comparison. complete_records still establishes
exact captured/appended key-set equality before closure; do not weaken it.
Discard all auxiliary indexes on publication along with the existing capture,
records, fold and source state. No completed artifact retains corpus identities.

### Fixed bounded directory validation

Core KnowledgeExport.path and Writer exact_path admit only notes, assets,
documents/originals, documents/extracted and their documents parent. Keep this
fixed private list of five directory identities; for each, use exact ETS lookup
of {:directory, literal_path}, and perform the SAME original mode/UID/inode and
no-symlink checks when present. Ensure create_directories accepts only these
fixed prefixes; no generated/user-supplied directory list or whole-table select,
fold, tab2list or filtered scan. Root/operation validation remains unchanged.
File identity/size/mode verification continues by exact existing file lookup.
Reservation, atomics/generation, publish/abort and owned recursive cleanup remain
unchanged. This changes traversal cost, not the same-UID threat-model claim.

### Full-path causal verification

Add TWO independent native work regressions using real Spool frames, actual
Writer.open, known complete metadata records, every original/text append, and
Writer.finish. New additive fixture helpers reuse existing prepare_fixture with
no old behavior edits, then add129 Notes, each with one typed attachment and one
typed citation, plus three ready Documents with43 genuine canonical fragments
per Document. All metadata/source descriptions go through existing constructors
and Spool.append/seal; fragments use real DocumentFragment.id/locators/digests,
contiguous ordinals/UTF-8 offsets and exact aggregate extracted digest. Originals
remain the explicitly synthetic unit-fold fixture, NOT live custody evidence.
Keep every existing50+2 Writer case/helper and the original501-note metadata trace.

Trace ONLY the current test PID, arity-only MFAs Enum.count/2 and Enum.filter/2
with match specs requiring a list length >=129; also ETS.tab2list/1, which is the
actual offending public call. No values/returns/content in trace messages.
One test expects zero large count/filter calls; the other expects zero whole-
ledger-copy calls. Both first require successful complete materialization and
actual native output reads/digests/manifest presence, not just metadata append.
Do not use the old append_records paginated helper inside the traced callback;
append f.records directly. Source/output verification must not manufacture a
tracer failure: source constructors run before tracing, and arity patterns must
be actual native callable exports. Preserve default ExUnit timeouts/async flags.

The traced callback owns Writer.abort in try/after while its ETS owner is alive,
on success AND assertion/exception, BEFORE trace_delivered/counter collection/
restoration. Stop only the owned tracer and restore exact original disabled
patterns/flags unconditionally; a setup/tracer failure is not causal RED. Add a
synthetic-counter near-ceiling case where primary membership fits but auxiliary
identities cannot fit, using real sealed small frames and unchanged1M ceiling;
label this honestly, not a volume test. Add a sealed deleted/historical fragment
identity ambiguity counterexample to preserve exactly-one citation matching,
and retain all existing ordinal/closure/source-render/inode/corruption/privacy
assertions. Include an exact directory replacement regression if prior tests do
not cover a nested documents prefix. Genuine output correctness assertions must
precede expected work-counter failures; no weakened count/timer assertions.

Parent whole pure5 RED then source GO, whole pure5/retained SQL/Task13pure/static
GREEN, fresh actual NONAUTHOR source SPEC then distinct fresh QUALITY are required.
Record exact evidence/counts/exclusions/source/frozen receipts, preserve all prior
FAIL/green/reviews and default fixed limits. Task14/16 and Phase5 remain separate.
