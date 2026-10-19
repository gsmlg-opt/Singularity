# Phase 5 Task17: live portable export acceptance — design candidate

Date: 2026-10-19. Status: generated-digest backing amendment candidate;
independent DESIGN SPEC, NEW distinct QUALITY and root GO are required before
the amended production repair. Earlier reviewed test implementation is retained.

Canonical design path:
`docs/superpowers/specs/2026-10-19-singularity-v0.2-phase-5-task17-live-export-design.md`.

## Authority, prerequisites and scope

This elaborates Task17 of
`docs/superpowers/plans/2026-10-11-singularity-v0.2-phase-5-export-backup.md`
without dropping any acceptance item. The governing Phase5
design, accepted source/lease/committed-transfer/terminal-close/recovery
amendments, repository instructions and fixed Core export limits remain binding.
The companion plan is
`docs/superpowers/plans/2026-10-19-singularity-v0.2-phase-5-task17-live-export.md`.

Task16 now has qualified local acceptance. Its tested/reviewed final source is
`5d7cd738c1049071987f93d6ec6c6dd68d4e409b`, the final combined tree from local
commits `2340fd4efc90cc06332ded6e66d33c19548a3b39`,
`16875fea0cfd873f4f2809a046147842246eb4bb`, and that final source commit.
The source43 manifest is
`.devenv/phase5-task16-restore-transport-fortythree.sha256`, SHA-256
`b7ec2220705f0bab1a7c467fcbbeadb0b60f06fbe2dcaa508d8e16db158aca2f`.
Final SOURCE SPEC and subsequent NEW distinct SOURCE QUALITY actually PASS.
Documentation commit `a0fb0f854509cb69e42ec598deb6aa2f4116729f` changes only the
three closure documents, frozen manifest SHA
`641b7eb29d09f2ea0f3e8245a518c1c2425b557847ff6dbf41fb03f087fa98f2`.
The actual closure receipt is
`.devenv/phase5-task16-docclosure-actual-closure.json`, SHA-256
`20082e7b57a9444470791ce3c53a0f79c4a24422e8781f2b69dcef1bae929084`.
It records ordered documentation/lifecycle/actual-evidence review PASS, actual
207 tests/0 failures, own post EMPTY/natural0, exact owned stop and byte-exact
1601-byte archive PASS0, committed-blob matches and literal clean/index-empty
closure. All Task16 command sessions closed; its PostgreSQL identity was stopped
and RAM data/fixtures remain retained. Its identity receipt is 34 lines/1259 bytes;
older 43-line descriptions are historical count errors, not new identity proof.

The immutable 307-line `docs/verification/2026-10-19-phase-5-task16-handoff.md`
honestly retains its then-PENDING documentation snapshot; the separate actual
receipt supplies completion. Native117's 22 failures, C13 and
`8fb1142ee593641544769658d03a96cb83ebaa56` remain historical evidence there,
not today's baseline or an unaccepted-Task16 premise. Worktree remains
`.trees/v0.2-phase-5-export-backup`, branch `codex/v0.2-phase-5-export-backup`.
Pin both accepted source and documentation commit before implementation; never
rewrite old failures or frozen manifests. The preceding canonical pair received
actual independent DESIGN SPEC, NEW distinct QUALITY and root GO before test
implementation. Its review receipts are
`.devenv/phase5-task17-canonical-design-spec.json` (SHA-256
`06759741d8099bd0708cc547ffbe659832fd43f899aa5129a1c78950099d0d07`)
and `.devenv/phase5-task17-canonical-design-quality.json` (SHA-256
`2d9c7be432706d9bb60c37e273ec82addf2ec7227193b59e27dc37f9aef1161a`).
They do not review this new digest-backing amendment; obtain the same ordered
reviews and root GO again before its production repair. Draft3's exact passing
review receipts remain historical:
design `62adf796f252bd20634dac6c7252c00433ec54af8921f11ac5fd7e9982c238a5`,
plan `5641ce4edc994d79ce423e62836db5e4291c7323b714c052cda5393890ff2f2b`.
They do not review this revision.

Parent reads both complete drafts, then obtains independent DESIGN SPEC and a
new distinct QUALITY review before implementation. These are ordinary internal
design prerequisites under continuous authority, not a renewed human-approval
request. Promoting drafts is not implementation or phase advancement.

Task17 creates real Runtime.Api portable/privacy acceptance and small test
support modules. The original production amendment forwards an existing Writer
write seam from a trusted internal runtime map. The bounded amendment below
also detaches generated digest binaries in the two existing private Spool/Writer
hex helpers, preserving their exact bytes and the strict backing model. There
is no new public option, environment selector, adapter family, capability,
production/permanent grant, migration, custody/DownloadLease change or Vault
feature work. No other Spool/Writer production change is authorized.
Task18/19, browser/E2E, release/version/publication/deployment and production
activation are excluded. Existing E2E remains NOT RUN under its manual-only
boundary; this does not waive any other required gate.

## Selected approach and evidence boundaries

Use a disposable native runtime started by `NativeAssetFixture.with_fixture/1`.
Publish real encrypted Assets with its public upload/verify/finalize operations;
import real Documents through `Api.import_document/2`; dispatch and execute the
actual extraction worker. Export through all four configured Api callbacks,
each delegating unchanged to actual `Knowledge.Export`. Materialize only public
entry/chunk responses into a second, disjoint, test-owned offline directory.
Verify that directory independently, with no repository/runtime calls in the
oracle. Add deterministic trusted-map observers and barriers around real calls,
never replacement authorization, materialization, custody or successful data.

This qualifies genuine configured-facade/runtime/native-custody composition.
The fixture must also retain a successful default-production-Api export smoke
using the fixture's genuine configuration, so observer configuration cannot hide
broken production callback wiring. Private SQL-only export fixtures, fake
DownloadLease results and a direct Export call are not substitutes for either.

Do not extract or call NativeTest's private `fixture!/3`,
`composition_fixture!/2`, or transfer helpers. They contain useful observer
patterns, but the former seeds encrypted bindings through SQL and the latter
can deliberately discard a successful delivery. Neither establishes public
upload/import publication. Do not invoke a complete backup just to obtain an
export fixture. Reuse public constructors and copy only minimal test patterns
additively; preserve every old fixture/helper/assertion byte.

Alternatives rejected: filling the host disk or changing mount/quota/rlimits
affects shared infrastructure; a synthetic lower-level Writer/Spool test misses
the Api/Artifact/native lifetime composition; a new general filesystem adapter
or public fault option enlarges production authority; database-derived expected
output or the production validator makes the offline oracle circular.

## File ownership and test-only interfaces

New support files:

- `apps/singularity_runtime/test/support/knowledge_export_live_fixture.ex`:
  disposable native publication, real trusted runtime/config construction,
  graph construction and scoped delegating observers/barriers.
- `apps/singularity_runtime/test/support/knowledge_export_offline_oracle.ex`:
  pure local-files/Jason/hash/Markdown checks; no runtime/storage/core export
  validator aliases, SQL, proprietary URI resolver or fixture mutation.

New test owners are `knowledge_export_live_test.exs` and
`knowledge_export_privacy_test.exs` under `test/singularity/runtime`.
Existing `note_markdown_export_integration_test.exs` remains unchanged and is a
whole-file regression owner, not live native-custody proof. Any architecture
assertion needed for the one-line forwarding amendment is strictly additive in
the existing composition contract; its parent owns attribution and serial edits.
The parent also owns the new, separate
`apps/singularity_web/test/singularity/architecture/knowledge_export_digest_backing_contract_test.exs`
for exact two-helper attribution and causal source rejection controls. Preserve
every old architecture assertion and historical source manifest literally.

The support module exposes a small fixed interface, not a general fixture DSL:
`with_fixture/1`, `publish_sources!/1`, `build_graph!/1`, `export_config/2`,
`materialize!/3`, and `assert_quiescent!/1`. Fixture state keeps the original
`DTO.Session`, credentials, independently retained input bytes, graph IDs and
expected selection, owned roots, supervisor and observer token. It never returns
key material as an oracle. `export_config/2` accepts only trusted test controls;
no request-derived map can choose adapters or roots. Cleanup is registered
before the first public operation and closes unexpected successful handles.

Build the export-only runtime explicitly from the same concrete dependencies as
`Api.production_runtime/0`: RequestRepo, ScopedRepo, OperationScope, Authorize,
real AuthorizationDependencies containing IdentityRepository and KeyCustodian,
AuthorizationLock/VaultLock/ObjectLock, AuditSink, AssetRepository, identity
repository, native KeyCustodian and DownloadLease, and the existing export
configuration shape with private Task.Supervisor, roots and monotonic clock.
Use the real Repository by default; a trusted tuple wrapper only delegates and
observes. Never fabricate a SessionContext: Api converts the genuine unlocked
DTO.Session and performs its unchanged result/error validation.

The four configured callbacks are exactly:

```elixir
%{
  export_knowledge: &Export.run(runtime, &1, &2),
  knowledge_export_entries: &Export.entries(runtime, &1, &2, &3),
  read_knowledge_export_chunk: &Export.read_chunk(runtime, &1, &2, &3, &4),
  close_knowledge_export: &Export.close(runtime, &1, &2)
}
```

Acquire a private existing Task.Supervisor child specification for export test
operations; do not replace global registered infrastructure or introduce a new
supervisor type. Save and restore every application setting changed by the
existing native bootstrap, including backup/root settings. The qualified
artifact-root lane is the accepted Task16 IO-Q1 retained-RAM lane, with frozen
`apps/singularity_runtime/test/support/knowledge_export_qualification_root.ex`
`KnowledgeExportQualificationRoot.allocate!/1`, SHA-256
`64108a2958159e41dc9962c12cd0044b4f31ee3a971549e8c73bd5d554f7192f`.
Root alone opens a fresh Task17 execution
identity/log/guard set, validates retained roots and unchanged settings/roles,
and closes/archives it after actual ordinary posts. An old active PID, native250
controller or guard requiring unchanged source43 HEAD is not a reusable command.
The offline materialization root is disjoint from
artifact, object-storage and backup roots. Do not invent a tmpdir symlink,
mount, timeout relaxation or alternate storage path to make tests pass. The
explicit independent-scenario harness allocation below is the sole reviewed
clarification; it does not increase a per-case or product timeout.

## Temporary existing test-only permission contract

NativeAssetFixture already owns the live disposable MigrationRepo: its
with_fixture/1 opens ResourceOwner and start_runtime!/2 records repository PIDs
(native_asset_fixture.ex:17-49). KnowledgeTestGrants cannot be nested unchanged:
its wrappers call Fixtures.with_owner/1, which unconditionally starts another
MigrationRepo (fixtures.ex:74-80; knowledge_test_grants.ex:89-149). Leave both
old helpers byte-identical. The new export fixture owns only a local permission
scope on that same already-running repo and run-local database, not a second
owner or a general grant API.

Before any permission delta, bind the exact live MigrationRepo PID recorded by
the native fixture to its destination database and existing isolated-name check
(knowledge_test_grants.ex:151-157). Snapshot the touched object ACLs and effective
privilege states, and witness unchanged role attributes/membership and the
ordinary canonical-write guard outside the scope. Use only the existing owner
transaction/SET LOCAL ROLE pattern on this owned database. Enclose setup and
callback in try/after before the first grant; setup failure, callback failure
and success all restore exact original ACL/privilege states before owner close.
Grant only missing required privileges, without grant option; revoke only the
scope's own additions and positively compare the snapshots after restoration.
Do not blindly copy with_permissions/2's unconditional REVOKE behavior. Do not
start/stop the borrowed repo, rewrite catalogs, bootstrap a global database or
change roles, memberships, production grants or capabilities. If an exact state
cannot be safely restored, stop that fixture path rather than widening authority.

The source-identified permission ceiling is KnowledgeTestGrants, not a blanket
request to grant its whole inventory. Its only role names are singularity_web
and singularity_worker (line15). Select the minimal needed subset as follows:

- with_grants/2 (lines17-36): SELECT/INSERT on content.document_versions and
  content.document_import_receipts for actual import; document_versions also
  entails EXECUTE on content.document_trim_name(text). Existing import proof
  uses exactly those tables plus with_receipt_grants/1's receipt UPDATE
  (document_import_live_test.exs:546-558; grant helper:48-56).
- The same SELECT/INSERT allowlist contains document_fragments, note_attachments,
  note_citations, tags, resource_tags and relationships (helper:6). Only source-
  membership/graph operations that need them select them; fragment SELECT may
  instead be already present or use the existing read-only contract (58-63).
- Lifecycle EXECUTE is a separate existing allowlist (8-14,38-45):
  content.claim_document_extraction(uuid,bigint,uuid,text,integer),
  content.complete_document_extraction(uuid,uuid,bigint,jsonb,bytea,text),
  content.fail_document_extraction(uuid,uuid,bigint,text,text),
  content.reset_document_extraction(uuid,bigint,text,integer), and
  content.recover_document_extraction(uuid,bigint). Actual extraction uses its
  real configured worker path; inspect existing privileges first and add only
  those this unchanged scenario actually requires. This is not permission to
  add reset/recovery scenarios or grant redundant functions automatically.
- Existing organization DELETE scope is only resource_tags/relationships
  (65-74), and only if an already-required valid tag/relationship mutation needs
  it. with_direct_mutation_grants/1 (76-86) is excluded: no extra direct
  Document/fragment UPDATE/DELETE authority or lifecycle/constraint bypass.

“No new grants” and “SQL setup cannot grant authority” prohibit new product,
production or permanent authority, not this explicit temporary existing test-only
permission contract. Frozen production canonical-write guards remain unchanged
and denied outside the scope, with before/after positive assertions. Table-owner
SQL graph arrangement never becomes runtime authority or fake publication.
No migration, bootstrap, configuration, role/capability, custody or Vault change
is authorized. Any additional object/privilege requirement is a bounded design
gap for parent review, not an implicit allowlist extension.

## Native publication and rich immutable graph

Retain independent original inputs before any upload: the exact repository
fixture `apps/singularity_ingest/test/fixtures/documents/two_pages.pdf`, literal
plain text, literal Unicode Markdown, and `<<>>`. Record bytes/digest/length in
test input data, never recover expectations by reading SQL, runtime output,
storage ciphertext or a production serializer. The PDF is the valid existing
two-page fixture, not the backup fixture's intentionally minimal PDF-like bytes.
Plain/Markdown/empty originals are genuinely published with
`NativeAssetFixture.upload!/4` and `verify_and_finalize!/0`.

Use `Api.import_document/2` for the valid PDF and text/Markdown Documents, then
real OutboxDispatcher and actual Oban `:document_extract` processing through
JobDispatcher -> Documents.Extract -> configured real extractors/source lease.
Assert the public results and persisted terminal/fragment provenance positively.
An empty original can be an Asset source and, when imported, a genuine
unsupported/no_extractable_text outcome; never fabricate a zero-fragment ready
Document. Do not replace actual extraction with direct completion SQL or a fake
extractor. Queue dispatch/drain assertions must account for known submitted jobs
and assert failure=0; do not discard extra failures or unrelated work silently.

Create/save/merge/delete Notes through available public Note APIs. Extend graph
setup only for immutable shapes not constructible through those APIs; use the
existing backup/snapshot fixture patterns and legal sealed source-set functions
inside the owned disposable database. SQL setup must preserve real resource/
version/Asset/object binding, provenance, source membership, owner/classification
and deferred constraints. It cannot disable constraints, grant production or
permanent authority, forge live publication, manufacture invalid ready Documents
or replace native imports.
Keep setup witnesses distinct from export observations and from independent
expected bytes. All added graph rows are valid committed canonical state.

The fixed graph contains duplicate titles, path-like/malicious Unicode labels,
ordinary external URLs, two exact historical Document-version pins, a Note
source cycle, a later head that must not retarget either pin, relationship
metadata-only endpoints with a pinned target, parent and merge ancestry,
unselected conflict/history canary bodies, a live Document whose source Asset
is deleted after publication, an exact positively resolved deleted source
referenced by a live Note, and optional owner-scoped tombstones. Assertions
enumerate selected files and metadata identities independently. No deleted,
unselected-history/conflict/ancestor-only body or original file is present.
`metadata_only_unavailable` is absent: there is no positive unavailable resolver
witness. A selected live missing/denied source fails the whole operation rather
than being downgraded to metadata-only success.

## Public materializer and independent offline oracle

The materializer uses only Api entry pagination, Api chunk reads and Api close.
It creates a mode-0700 offline root, rejects unsafe paths before opening anything,
writes exclusive regular mode-0600 files and copies exactly the advertised chunk
sequence, including the canonical empty-file result. Reject symlinks, absolute
paths, dot/parent components, backslashes, duplicate paths/cursors/chunks and
unexpected directories. Close in `after`; a failed materialization advertises no
offline success. Oracle checks never reach back into the live fixture.

Parse `manifest.json` with test-only Jason, independently of production's built-in
`JSON`/`:elixir_json` codec. Assert the literal twelve top-level keys: `format`,
`version`, `selection`, and all nine arrays `resources`, `versions`, `fragments`,
`tags`, `tag_assignments`, `relationships`, `attachments`, `citations`, `files`.
Define each record's exact literal field set from the format document, not a
production validator/header/field-list call. Assert inventory,
collection records, nullable provenance fields, source/version references,
metadata-only availability and no private spool/custody/path fields. Compute
SHA-256 and byte counts directly from every materialized file. The manifest's
file inventory excludes itself; the public entries inventory equals those files
plus the separately verified manifest descriptor. Reject extra files as well as
missing files. Explicit expected identities and literal source bytes prevent an
internally self-consistent but incomplete package from passing.

Use test-owned path and Markdown parsing/checking, not Core export validation or
the production renderer. Check fixed expected rendered snippets/footnotes for
the known graph and resolve every generated ordinary relative source link and
footnote into the offline directory. Distinguish user-authored external links
from generated portable source links; reject proprietary source URIs and path
escapes, not legitimate external URLs in the Note body. Check UUID/version path
identity rather than deriving filenames from titles. Verify fragment UTF-8 byte
offset/length slices, contiguous ordinals and no-delimiter concatenation against
independently expected Unicode fragment text; a character-counting oracle is
incorrect. Input PDF/plain/Markdown/empty originals equal the retained inputs
byte-for-byte, independently of manifest hashes.

Exercise the oracle itself with a valid positive control and one-at-a-time file,
hash/size, inventory, relative-link, footnote and multibyte-offset corruptions in
separate test-owned copies. Each must fail at the intended oracle boundary, not
only an unrelated final assertion. Never mutate canonical baselines or old tests
to obtain RED. Do not call a broken production export an expected oracle RED.

## Deterministic observation and race matrix

Observer modules live only in test support trusted maps, retain actual return
values and never authorize. Reuse the real ScopedRepo-delegation pattern from
NativeTest: recognize the capture result, wait until real transact returns, then
assert `RequestRepo.in_transaction?() == false` before a mutation barrier. Use
operation/token/PID-targeted handshakes with exact monitors, not sleeps or
arbitrary scheduling. Observe real KeyCustodian export-lease returns, actual
DownloadLease reads/revokes, Writer write sizes, public page/chunk sizes and the
sealed spool accounting scalars. Compute schema/count/backing summaries in the
owning process/delegating transaction wrapper; send only bounded scalar summaries
to the observer. Do not ship/retain the full capture or copy corpus content merely
to measure it. Do not emit content/key/session/request maps
into telemetry or logs. Observer messages are private test state, detached from
the diagnostic surface under test.

| Case | Actual checkpoint and action | Required result |
| --- | --- | --- |
| Snapshot stability | After capture COMMIT, update head and tags via valid operations | Captured graph/files remain exact; current head is not substituted |
| Transfer denial | After capture COMMIT, before native transfer, delete/revoke admitted source | Sanitized whole failure; no handle/partial success; all issued leases terminal |
| Completion denial | After actual bytes, before final source authorization/COMMIT, delete/revoke | Completed private files are not advertised; cleanup finishes |
| Native generation revocation | Deliver one genuine bounded original piece during generation, then revoke authority before the next native read | Next real native read denies; export fails and tears down |
| Completed-handle revocation | Complete a genuine export and one successful Api chunk call; revoke real authority before the next ordinal call | Next facade call denies without bytes; real terminal cleanup preserves neighbors |
| Generation cancellation | Block actual generation after observable work and kill the requester | Exact requester DOWN; real owner/companion cleanup; no handle |
| Owner loss | Kill actual operation owner after real native acquisition/Writer ownership | Companion revokes, observes owner DOWN, deletes only owned directory; no handle |
| Expiry | Fixed trusted monotonic clock advances across generation and delivery deadline | Real authorization/expiry failure and terminal cleanup; no timing guess |
| Startup recovery | Kill real companion at pre-owner clock barrier; stop all fixture tasks/supervisors, then separately start guarded recovery | Recognized residue removed; malformed/foreign neighbors untouched |

The completed-handle case uses two actual `Api.read_knowledge_export_chunk`
calls through the configured facade after successful export, with real authority
revocation between them. Positively observe the first chunk, then denial without
bytes on the next ordinal, exact owner/companion DOWN, Writer ETS gone and owned
directory absent, with storage/backup/neighbor sentinels unchanged. This is
completed Writer-file delivery, not a native acquisition during generation;
retain both distinct cases and do not substitute synthetic Artifact authority.

For successful exports also check wrong session/principal/owner/epoch use denies
without exposing data, complete read/close behavior, and no handle before final
completion. Cover the real generation cancellation path reached when Api export
returns an actual failure/expiry: observe its real requester-to-companion cancel
and terminal cleanup, rather than inventing a public cancel API or sending a
forged protocol message. Keep this distinct from requester death and normal
completed-handle close. Capture real owner/companion PIDs and Writer ETS table ownership from
the private test supervisor; do not treat a made-up handle or fabricated EXIT
message as lifecycle proof. Maintain Task16 recovery limits: companion loss
before owner handoff may leave a recognized orphan until a separate guarded
startup. Do not assert universal immediate cleanup or delete partial/foreign
directories to disguise that documented boundary.

## Narrow injected-ENOSPC amendment

`Export.materialize/4` already opens real Writer with an original_fold. Add only
this context entry alongside existing entries:

```elixir
write: Map.get(runtime, :knowledge_export_write, &IO.binwrite/2)
```

Writer already validates arity two, performs real file/identity/ledger checks and
maps write errors fail-closed. Artifact's owner runtime copy preserves unrelated
trusted keys. Production Api configuration/runtime must not populate this key;
Core public options remain exactly `include_tombstones`. No public/config/env
selector, Spool forwarding, new adapter or Writer callback-interface change is
needed. The independent digest-helper repair below does not alter this seam.
Default behavior remains IO.binwrite. Pin the exact amendment/inverse against the
accepted Task16 Export bytes; today's pre-amendment file hash is
`dab8881c7685bc967bb214736f167b6f37808040eb8adeaf48a2da9567ca8009`.

First add a failing genuine Api test whose trusted runtime contains the callback.
It delegates ordinary writes to IO.binwrite until an observed actual native
delivery arms the next real Writer write to return `{:error, :enospc}`. The test
requires both a callback witness at that late point and public
`{:error, :storage_unavailable}`. Current Export ignores the callback and
succeeds; that is the causal RED. An `after` path closes an unexpected successful
handle so RED does not leak. Successful Writer writes/native delivery must be
observed positively before the fault; the error must not occur during fixture
publication or be simulated by a fake materializer.

After the forwarding change, require no successful handle, every issued native
lease PID terminal (actual inactive/read-denied result plus exact DOWN), requester
termination, owner/companion DOWN, Writer ETS gone and owned directory absent.
Run the Api call in a monitored requester so its exit is an observed lifecycle,
not an assumption that the test process dies. Check sibling artifacts, malformed
neighbors, storage ciphertext/inventory and backup sentinels unchanged.
Capture no partial artifact as success. Label this proof **injected ENOSPC
through genuine Api/real Writer**, not a physically full filesystem. Existing
lower-level Spool/Writer synthetic error tests remain separate evidence.

## Generated-digest backing repair after actual strict RED

The whole `live-prewrite4` and `live-prewrite5` commands ran on unchanged
production code and failed the required small-binary backing check. The latter
actual raw log is
`.devenv/phase5-task17-qualification-run-live-prewrite5-primary.log`, SHA-256
`ac5bd9f3cf6d16752285245208c1a7f44403f453bc1a720c68f5998686e025db`:
20 tests/7 failures, natural2, separate own post EMPTY/natural0, all commands
closed. A real generated digest has logical size64 and lowercase hex bytes but
referenced backing70. This is a producer-origin gap, not permission to raise
the64-byte assertion or change a coefficient. Other failures remain failures.
Task17's reviewed qualification lane was separately reopened and remains owned
and active under `.devenv/phase5-task17-qualification-active-pg-identity.json`,
SHA-256 `6bb2d0d5cebdfe1a1f01c66b4cc56be6a7e89e41b11e41c112f78476bf9d7fbf`;
Task16's stopped receipt is never its operational identity.

The same run independently established the original genuine Api ENOSPC RED:
14 positive real native pieces, real Writer owner, zero callback invocations,
and an unexpected successful opaque handle, closed in after. Preserve the
separate `.devenv/phase5-task17-api-enospc-causal-red.json` and run that exact
test case unchanged across the one-entry forwarding repair. A digest-model
failure alone is never its replacement RED.

The read-only Astra architecture advisory is
`.devenv/phase5-task17-generated-hash-backing-architecture1.md`, 216 lines,
SHA-256 `c487aa260206c45c93421ace2d31a9831c97e6621208cd479be52a56ac60bd17`.
Its source analysis distinguishes JSON-decoded short leaves from generated
Base.encode16 outputs: Elixir1.18.4's encoder builds an appendable result, so
logical size64 does not establish referenced size64. OTP shrinking may retain
slack;70 is an observation, not a qualified maximum or exact GC-history proof.

Authorize only replacing the existing private helper body in each file:

```elixir
defp hex(bytes), do: bytes |> Base.encode16(case: :lower) |> :binary.copy()
```

The exact old body is `defp hex(bytes), do: Base.encode16(bytes, case: :lower)`.
Pin the entire preimage, require exactly one contextual replacement, and invert
it to the exact full-file old hash; reject missing/duplicate helpers, different
producer changes or unrelated bytes:

- `apps/singularity_storage/lib/singularity/storage/knowledge_export/spool.ex`:
  `2d6dfb4e10b78a4ac27e0e868a6f33326e746c96a309a4d5a833511f63f18556`.
- `apps/singularity_storage/lib/singularity/storage/knowledge_export/writer.ex`:
  `841f3e6b7333e7e94296c8b961353c732cbfddef1cebc8cce15041720e5e80e1`.

These helpers currently encode fixed32-byte SHA-256/HMAC inputs. The copy adds
one fixed64-byte detachment, also at bounded transient cursor/comparison uses;
it changes no digest/proof/cursor/output bytes, schema, framing, source checks,
quota, accounting or lifetime protocol. Do not add a generic public encoder,
test-side digest copying, private-helper exports or whole-corpus copies.
Repository's Q/T fragment selector is the actual database fragment `id`, not
its encoded digest metadata: preserve Repository's complete preimage
`618983d395ff382939ce47ba0cdfa36881e4a71b3a58cfc7c1e87322baf2981c`.
Its digest metadata and model fragment IDs pass through individual JSON record
decoding. No Repository/Core/native-custody repair is justified by this finding.

Keep Task16's source43 and every accepted source/assertion unchanged as
historical attribution. These two storage files are not members of source43;
do not regenerate that manifest. The new digest architecture owner checks the
exact forward/inverse pair and causal mutants with the same positive validator.
Add this fifth whole owner to the architecture gate. Existing composition
assertions are preserved, with only the separately attributed forwarding block.

Compiled-runtime qualification must inspect all actual generated retained
families: sealed text/render/binary-binding refs, Writer record refs, every
output SHA and every empty/nonempty chunk SHA. Require binary size64, lowercase
hex, referenced size<=64 and unchanged known-byte digests; preserve Q/T retained
selector checks and actual long-locator/MIME/ETS fixtures. Extend only the new
live test owner where a coverage gap is evidenced. Run the same small/501-entry
formulas and causal model mutants; no increased bound, coefficient, forced GC,
quota override or weaker assertion. Independent offline inventories, manifest
and per-file byte equality plus the two genuine deterministic exports remain
required. A source-only architecture PASS is not backing-runtime proof.

Before post-write execution root reviews a new finite source/lifecycle stage
that pins the amended canonical reviews, all authorized source paths, the exact
three production inverses and additive-only old architecture block. It must
retain all other committed raw blobs, accepted runtime/role facts, independent
own posts and source-independent operational stop/archive. Old pre-write
operational scripts remain byte-exact and usable for owned cleanup. No runtime
command runs while any source owner is editing. Final source/spec then a new
distinct quality review and all actual gates are still required.

## Boundedness, determinism, privacy and permissions

Use a genuinely published multi-chunk original and a valid 1,048,576-byte
canonical Note, plus enough valid small Notes/files to produce more than 500
public entries. A four-MiB-plus-tail input makes native/public chunking visible
without pretending to test all maximum total byte limits. Observe every public
page <=500 and facade/consumer/Writer chunks <=65,536. Asset native ranges stay
<=65,536; native Document records retain the existing aligned4,194,304-byte
ceiling, exact final-tail validation and subsequent <=65,536-byte consumer
pieces. Do not change the preserved native Document primitive. Observe sealed scalar counters
`spool_bytes`, `metadata_records`, `selected_keys`, `original_bytes` against the
unchanged fixed limits. Check accounting identities against actual journal and
fixture inventory; counters cannot be accepted merely because they are small.
`spool_bytes` includes both physical framed payload/index bytes and Repository's
established `temporary_text/2` plaintext charges. Require exact equality to the
two actual journal sizes PLUS independently predicted temporary charges, never
infer those charges from the observed counter difference. The live small/501
fixtures charge only their known Note bodies and the 12-byte companion Note:
1,048,588 and 1,056,482 bytes respectively; their pending Document has no ready
fragments or citation-resolver calls. Accumulate only known input byte counts,
not a retained body list. Direct compiled Spool fixtures have zero Repository
temporary charges. Keep both exact physical-file stat checks, all fixed ceilings
and retained-family formulas. The same validator must reject predicted-charge
minus-one/plus-one mutants at this exact accounting boundary. No production
counter, Repository, budget, quota or backing assertion changes are authorized.

Inspect actual Export/Spool/Writer source for fixed internal page limits, bounded
framing, no nonempty eager `:all`, no corpus-wide `Enum.to_list` and no whole-
manifest JSON encoding. Distinguish public-page instrumentation from this static
internal-call proof; do not claim an unobserved internal page trace.

### Source-derived retained-index and backing model

Use the source preparation note
`.devenv/phase5-task17-retained-binary-origin-preparation1.md` (245 lines,
SHA-256 `c7017faf58331658f059950b06d81e96de0a160e59a52ed8443ae67a58be6936`)
as origin evidence, not runtime qualification. Relevant production seams are
Spool seal52–78, charge735–769/813–836, install931–983/refs1086–1099;
Writer capture409–519, record118–169/545–550, outputs1066–1083,
publish1127–1141 and ledger1245–1284; Core Manifest's exact19-field versions
schema and Core Export's fixed paths/limits. Config selects built-in JSON.
The note's exact Elixir1.18.4/OTP28.5.0.3 small-binary copying inference remains
source-derived until the actual compiled-runtime regressions execute.

Count these actual sealed families: S selected identities, C collection keys,
V version summaries, A draft sizes, B binding sizes, T typed text selectors,
D document headers, Q ordinal members, J outer frames across collections/texts.
Reject unknown fields, selector/key variants, retained body/title/locator values,
unsealed hash/carry fields and inconsistent family counts before measuring.
Spool's actual charges imply the conservative retained-count relation:

```text
S + C + V + A + B + 3*T + D + Q + 4*J <= R <= 1_000_000
S == accounting.selected_keys <= 100_000
Lsealed <= Bsealed + S*cS + C*cC + V*cV + A*cA + B*cB
                       + T*cT + D*cD + Q*cQ + J*cJ
```

R is actual sealed `metadata_records`; overwrites can leave extra historical
charges, so equality with the left side is not required. J includes each outer
frame's inner index frame. T includes exactly one sealed `_texts` entry and one
of `text_refs/render_refs/binary_refs`, with its repeated selector/capture ID.
No descriptor or ETS reference is itself the contents of its referenced state.

Make coefficients executable from explicit worst-shape skeletons, not a chosen
heap/ETF threshold. Define `e(x)=:erlang.external_size(x)-1`; content integer
slots use the larger e of signed64 extremes (counts/offsets use their smaller
fixed caps), and n denotes that slot's bounded worst case. Filesystem identities,
clock and opaque fields use their pinned actual non-content sizes separately,
not an assumed signed64 identity limit. u/id is a36-byte UUID, h a64-byte digest,
b a32-byte hash. `pair(k,v)=e({k,v})`
conservatively includes map-entry overhead; `cell(x)=e([x])-e([])` overcounts
a list header per member. Base Bsealed contains only the exact fixed map/
MapSet headers and fixed non-content state; record root/clock/opaque-reference
sizes separately as fixture inputs. Check installed MapSet representation and
include its full header and member cost, rather than assuming a list.

| Family coefficient | Exact maximal-shape construction |
| --- | --- |
| cS | Maximum single-member installed MapSet delta for `{kind,u,u}`, kind in asset/note/document |
| cC | Maximum `pair(key,nil)` over id, `{u,u}`, `{u,u,n,h}`, `{u,u,n,u}`; frames charged by J |
| cV | `pair({u,u}, %{"kind"=>kind,"state"=>state,"availability"=>availability,"extracted_digest"=>h})`, maximum over literal enums/null alternatives |
| cA, cB | `pair({u,u},n)`; `pair({:binary_binding,:asset,u,u},n)` |
| cT | Maximum `pair(selector,%{byte_size:n,frames:[]}) + pair(selector,%{capture_id:u,selector:selector,offset:n,byte_size:n,sha256:h})` |
| cD, cQ | `pair({u,u},%{ordinals:%{},bytes:n})`; maximum `pair(n,fragment_selector)` |
| cJ | `cell(%{offset:n,length:n,hash:b,index:%{offset:n,length:n,hash:b}})` |

Typed selectors are exactly `{:note_markdown,u,u}`,
`{:render_descriptions,u,u}`, `{:binary_binding,:asset,u,u}` and
`{:fragment_text,u,u,ordinal,h}`, ordinal0..4095. Serialize only these bounded
skeletons to derive numeric coefficients; enumerate actual leaves/counts for the
observation. Publish the numeric coefficients and derivation in test evidence.
An unsupported shape or an unproved coefficient fails the check; it cannot be
omitted or replaced with an unexplained `flat_size` allowance.

Writer's build families additionally include C captured keys and <=C records,
<=V fragment-count/document-progress headers, <=C fragment identities, <=C
source-group headers and <=C source members, and <=(T+V) seen selectors (original
selectors differ from binary-binding selectors). Build coefficients use the
literal key/ref/progress/group/list skeletons at capture409–519, records118–169,
seen175–195 and documents686–714; include repeated keys/list cells and opaque
hash context separately:

| Build family | Maximal member coefficient recipe |
| --- | --- |
| Captured / record ref | `pair(key,true)` / `pair(key,%{offset:n,byte_size:n,sha256:h})` |
| Fragment count / identity | `pair({u,u},n)` / max `pair({u,u,h},fragment_key)` or `:ambiguous` |
| Source group / member | `pair({u,u},[])` / `cell(source_key)` for both fixed collections |
| Document progress | `pair({u,u},%{count:n,byte_size:n,hash:actual_bounded_hash_context})` |
| Seen | Max installed MapSet member delta for typed selectors or `{:original,kind,u,u}` |

Each key is one of the literal maximal collection shapes above; count fixed
collection/group headers once in Bbuild and separately record hash-context size.
Thus use
`Lbuild <= Lsealed+Bbuild+sum(Nfamily*cfamily)+O*cO+K*cK` with the listed count
ceilings, not a claim that publishing erased every build allocation.
Publishing drops those build-only maps; published content index obeys:

```text
O + K <= RW <= 1_000_000
Lpublished <= Bpublished + O*cO + K*cK
cO = pair(path100,%{media_type:mime255,byte_size:n,sha256:h,chunks:%{}})
cK = pair(ordinal,h)
Lledger <= Bledger + (O+2)*cFile + 5*cDirectory + cAccounting+cLocation+cBinding
```

O includes manifest output; K counts all retained chunk hashes, including
empty-file chunks. RW is Writer's cumulative charged metadata_records, distinct
from sealed R. Include both quotas and actual fixture identities. Ledger file
rows are `{{:file,path},%{identity:{n,n,n,n},size:n}}` for outputs plus
`.records/.index`; directory rows are `{{:directory,prefix},{n,n,n,n}}` for
at most the five literal directories. Administrative rows are actual
`:accounting/:location/:binding`; count the temporary reservation row separately
during finish. Read real ETS rows under the exact owner, reject unknown rows and
account for every row. Each cFile/cDirectory/administrative coefficient is e of
its exact maximal row skeleton just described, including all tuple/map keys,
identity integers and the separately measured fixed clock/phase/root inputs.
Do not measure only `_ledger`'s ETS identifier.

Logical serialization is only one axis. Walk every retained content-index
binary leaf and real ledger-row leaf using `:binary.referenced_byte_size/1`.
Spool's UUID/hash/enum leaves are <=64 bytes; require the real long-locator
append/seal path to establish that they do not pin its large metadata payload.
Writer path83–98 bytes (cap100) and valid MIME65–255 bytes can retain ONE decoded
versions-record payload. That schema has exactly19 fields and no body/title/
label/locator/storage-ref. Its conservative JSON payload bound is:

```text
Vmax = 19*((2+6*23)+1+(2+6*255))+18+2 = 31_807 bytes
```

Keys use maximum23 raw bytes; every scalar overbounds at255 raw bytes and six
JSON bytes per byte, plus punctuation. Writer pread reads exactly that individual
.records payload, not its40-byte frame or the journal. Require actual long-MIME
publish and ledger observations to show each relevant retained leaf's referenced
backing <=31_807. Overcount shared parents: at most output path, output MIME and
ledger path per output, giving an additional conservative `3*O*31_807` backing
allowance; generated hashes/small literals must have the observed small backing.
Keep fixed root/clock/identity binary backing separate. A bounded versions parent
is allowed by this model; source inference alone authorizes no additional copy
repair beyond the independently reviewed generated-digest amendment above. If
runtime establishes a larger/content-bearing parent or unsupported
shape, report the exact gap before source-scope expansion.

Run small and large real fixtures using the SAME formulas, plus isolated
long-locator sealed and long-MIME published/ledger regressions. The latter use
actual compiled Spool append/seal and Writer import/publish, with the genuine
retained descriptors and live ETS rows, separately labelled boundedness evidence;
they do not replace the genuine Api/native-custody acceptance. This needs no
production observer, Writer interface change, private process-state access or
new seam; the bounded generated-digest helper repair is separately reviewed.
Add causal local
shape/count rejection controls with unchanged positive fixtures. Do not mutate
the descriptor that production consumes or force GC to obtain a pass.

Account separately for one canonical Note<=1MiB, rendered Note<=16MiB and its
source descriptions. A Note permits <=100 attachments AND <=100 citations,
<=100 distinct combined targets, not100 total members. Source titles have a
16MiB aggregate rendering bound and can individually reach that bound; do not
assume255 without tracing that particular database origin. Include labels<=255,
Markdown locator<=64 headings each<=255, bounded reference/href/identity objects
and JSON escape expansion in the one-Note description working set. One metadata
record and bounded native Document4MiB/consumer64KiB buffers and transient sorted
identity lists are separate allocations; record their schema/count limits.
None is silently absorbed into the content-index formula.

`external_size` bounds serialized logical representation; referenced-byte
observations separately bound retained backing. Neither measures exact process
heap, ETS allocator overhead, GC peak, RSS, or a whole-VM/build peak. The claim is
deterministic retained-index/counter/backing bounds plus separately bounded
working sets, never a whole-VM memory ceiling. No GC/RSS/time threshold, corpus
encoding, million-record stress claim or test-only quota override is permitted.

Two runs over identical captured selection/metadata produce identical manifest
and every output file byte despite different handles, roots and operation/time
IDs. Compare offline inventories and bytes, not handle terms. Do not mutate the
graph between those two deterministic captures.

Capture export-only success and each failure's logs, telemetry, sanitized error
and opaque Handle Inspect with independent canaries for bodies, titles, labels,
storage refs, IDs/principal/session fields, key material markers and job payload
fields. Around each actual Api call attach unique unfiltered handlers for all
five repositories' query events and existing authorization/job events; detach
before fixture SQL, oracle assertions or expected-content rendering. Require
zero raw query events under unchanged SafeSQL suppression. Check the exact
handler event-set, external callback and owner/token registration before and
after each call. An empty diagnostic window is not activity or attachment proof.
Independently require fresh token/phase/caller-bound private Observer witnesses:
export capture/native/final COMMIT and returned handle, positive page/chunk
counts/bytes and real results, and authenticated close COMMIT plus exact owner
DOWN. Fault/expiry retain native-triggered real Writer injection/clock changes
and all terminal checks. Stale/invalid pre-capture rejection requires its exact
real result and full privacy scan, not invented success/authorization events.
Private witnesses are not telemetry; unrelated/earlier events cannot count.

After temporary grants unwind, outside Api captures, prove the unchanged exact
owned privilege/repository/database baseline and denied worker receipt SELECT.
In a separately labelled capture run the existing real SafeSQL WorkerRepo query
on `content.document_import_receipts` with a private canary parameter. Require
real PostgreSQL insufficient_privilege (42501), exactly one sanitized rls_denial
event with exact count=1/repo=worker from its exact emitter/control token, zero
query events and a complete raw event/log/error canary scan. Detach and recheck
the same baseline. Never attribute this control to export. Use the identical
registered capture callback; its strict registration/delivery/activity predicates
must reject a really detached sacrificial handler and missing/duplicate or
wrong-event/callback/configuration/token/phase/caller/positive-count mutants.
Do not fabricate events, add grants, enable SQL telemetry or filter metadata.
This follows DocumentImportLiveTest's separate real denial-control semantics,
not the earlier incorrect positive-query-per-export interpretation. Do not
redefine the intentionally explicit Session DTO as a secret Inspect object;
check diagnostic surfaces and opaque export handles, not caller DTOs.

Check actual operation directories mode0700/files0600 during generation and
after success; offline copy also uses0700/0600. Sentinels and byte/inventory
observations prove no neighbor/object-storage/backup mutation on normal close,
failure, cancellation and recognized-orphan recovery. Teardown is owner-scoped
and monitor-driven, never broad process kills or recursive workspace cleanup.

### Actual post-write proof-contract corrections

`postwrite-privacy1` is retained as actual2/2FAIL (raw SHA-256
`7756d0732a4379335975625ff5c7438ded8adad734dfc2f29edbfa623e4a9849`):
both impossible positive-query assertions observed zero under established SafeSQL.
`postwrite-live2` is retained as actual21/1FAIL (raw SHA-256
`c19ba2607cade5e4554aa6f6aa1d5bce155d63288224c549a6458b5bc3029083`):
the remaining model assertion omitted Repository's temporary plaintext charges.
Its unchanged complete ENOSPC case passed all fault and terminal assertions;
that scoped GREEN does not accept the whole live gate or Task17. Both commands
closed naturally with separate actual EMPTY/natural0 ownership posts and
unchanged facts/source/Mix authority. These test-contract corrections require
ordered independent design reviews before source repair and freshly reviewed
post-write tooling before any amended-source execution. No failed run is erased.

### Independent small/501 scenarios after the actual live3 failure

The actual `postwrite-live3` whole-live run executed21 tests:13PASS/8FAIL,
natural2, raw74707 bytes with SHA-256
`82b1780b535c2c185dc65f6cbff3146730f44871615637fd988aececea036260`.
The combined small/501 test exceeded180000ms at its second large export,
original B1629. Its first501 export/model/materialization and the small pair
had completed. This establishes neither standalone501 duration, phase durations,
a production deadlock nor a completed501 deterministic pair. Seven subsequent
cases failed the strict previous-trace-pattern-is-false guard after the killed
fixture requester left global trace state. All failures remain failed evidence.

Authorize exactly two count-specific ExUnit cases generated for `[1,501]`.
This replaces one shared180000ms harness budget with two independently enforced
180000ms budgets: aggregate allocation changes, while each existing timeout and
every product deadline remain unchanged. This explicit scenario isolation is
the sole clarification of the earlier timeout-relaxation prohibition, not
permission for other timeout changes. The acceptance is deterministic retained-
index/counter/backing proof, not a shared wall-clock target. Standalone501 is
unmeasured; if it still exceeds180000ms, preserve FAIL and diagnose/repair without
increasing any deadline or reducing required work.

Keep one shared lexical inner body, including a fresh complete fixture inside
each timed case; bind its count through `unquote(count)`. Preserve all501 public
Note creations, the maximum1MiB Note, multi-chunk original, both real Api exports
and materializations, unchanged graph between them, distinct handles/roots,
exact entry/inventory/every-file byte comparisons, the SAME formulas and
coefficients, accounting mutants, schemas/backing/native/page/chunk/write and
cleanup assertions. Do not split a deterministic pair across tests or move
fixture work outside its timed case. The six public fixture functions remain.

Only additive content-free diagnostic markers may bracket fixture setup,
Note creation, each export/materialization, comparison/quiescence and successful
fixture return. Their fields are finite phase labels, count, ordinal and
monotonic elapsed milliseconds; no content, paths, handles, tokens, IDs,
session/principal/key fields or inspected runtime structures. Markers impose
no performance threshold, replace no assertion and never report completion in
an `after` block. No retries, exclusions, detached setup, concurrency, forced
GC, sleeps, precomputed export or timeout override is authorized.

Pin original whole B SHA-256
`0bab7421fc79f9461194e644de2d3557f4fe3f15d6c24d7adfa8daa805796c8e`
and original model block/body. A strict source-preservation validator must
require the exact two-value generator, unique count name/binding, one shared
body and unchanged timeout. Strip only exact finite diagnostic additions;
require the resulting inner body byte-equal to its preimage. Invert the outer
organization and require the entire B preimage, before separately additive
lifecycle regressions. The SAME validator must reject source-copy mutants
dropping an assertion, reducing501, removing the second export/materialization,
changing timeout or inspecting runtime data in a marker. Frozen complete
ENOSPC bytes remain unchanged. The split alone changes21 to22 cases; record
the actual total after additive lifecycle cases, never an invented count.

### Fixture-caller abort ownership and exact collector restoration

The live3 cascade exposes a separate test-fixture ownership defect: caller
`:killed` bypasses its `after` clauses and kills caller-linked helpers before
their global trace patterns are restored. Correcting scenario organization
does not discharge this defect. Keep `previous == false` and all foreign-
pattern/tracer guards; never reset global tracing merely to make a test pass.
Only the new A fixture and new B regressions may change; the six public fixture
functions, native/production/custody/Vault interfaces and all old helpers stay
fixed. No new supervisor type or generic finalizer facility is introduced.

Explicitly authorize A's existing test-only ResourceOwner checkpoint closure
as A's acquisition/finalization coordinator. It runs in the real surviving
owner, not in the fixture caller; it never substitutes native acquisition or
runs the user's callback there. At acquisition `:ready`, before native runtime
bootstrap, register token-scoped initial state, allocate/register the exact
qualified root and its identities, and start/register control linked to this
owner. Control stays outside native infrastructure: the accepted pre-owner
recovery path deliberately stops tracker/private/native infrastructure and then
continues consulting control. Do not change ResourceOwner, NativeAssetFixture,
MigrationTestEnvironment or the frozen qualification-root helper.

After real native runtime creation, atomically register its exact references
in control before starting the temporary collector and private existing
Task.Supervisor children under that exact native infrastructure. Register their
fixed `{module, token}` IDs before start, so the surviving owner can find a child
whose start reply never reaches the killed caller. Publish complete context
before tracing or public operations. Partial acquisition is not full success;
cleanup queries only those exact IDs/PIDs, never arbitrary or replacement
children. All stop callers create fresh monitors locally; monitor references
owned by a dead fixture caller cannot provide owner-cleanup DOWN evidence.

Use one owner finalizer at `:owner_cleanup_begin`, before native infrastructure,
custodian or repositories stop, for normal return, callback failure and caller
death. Close recorded handles through real authenticated Api, retire tasks and
startup-recovery operations with exact monitored DOWN, preserve existing
permission/repository/native terminal and neighbor assertions, explicitly
finalize the collector, then stop it with exact DOWN. Earlier pre-owner recovery
stops must persist actual finalized/monitored receipts and are joined only on
that exact recorded identity; control remains alive through guarded startup.
Already-dead PIDs or successful Supervisor.stop alone earn no cleanup credit.

Collector finalization folds real queued issuance, actual revoke ACK and
lease DOWN messages through the SAME transitions as ordinary handling. A
selective trace-delivery receive alone is insufficient. Retain suppressed
native call arguments and opaque-PID-only observations. An emitted-trace fence
alone does not prove completion of pending custodian issuance; the protocol
must establish actual accepted native operation completion before its final
drain/restoration and account for every actual late/unreturned lease. Preserve
the existing terminal predicate: actual revoke ACK where required, or the
already-accepted independently confirmed owner/companion-loss path plus exact
lease DOWN/read denial. Autonomous native owner-loss does not fabricate a
`revoke/1` return; no new universal-ACK requirement or waiver is introduced.
Missing native evidence fails closed, never synthesizes ACK/DOWN or revokes a
whole session/principal/Vault.

The existing safe completion fence is
`KeyCustodian.unlocked?(exact_custodian_pid, fixture.session.session_id)`.
It is a synchronous existing5000ms GenServer call; its handler only checks
session-map membership and returns a boolean. Accept either real boolean:
revoked/locked tests must not be forced unlocked. Do not inspect native state,
capture the session identifier in diagnostics or call an atom-selected replacement.
Before this fence, close admission and obtain exact DOWN for all issuance-
capable operations/companions and their fixture-owned private AND native-global
task supervisors. Bind the global supervisor's existing child ID/PID under the
exact native infrastructure at acquisition, require its pre-owned baseline
empty/no foreign clients, and terminate that exact child through its parent
without an automatic restart; do not stop an unrelated global process.
Pending requests processed after all their callers are dead fail existing
`export_acquisition_status/2` before issuance. A request already executing must
finish before the boolean reply, including any actual late issuance; hence the
subsequent emitted-trace fence/common-handler drain closes that issuance set
without assuming cross-sender FIFO. Source: existing KeyCustodian165–166,
251–280,701–702,817/860,1623–1630,2786 and accepted native composition
`knowledge_export_custody_live_test.exs:1420`. Previously completed pre-owner
shutdown joins only its exact stored successful fence/finalization/DOWN receipt;
absence of a live custodian alone is not a fence.

Before ANY restoration mutation, validate the complete acquired target set,
installed match specs/local tracing, and exact custodian flags/tracer ownership.
Use an explicit partial-acquisition journal; restore only positively owned
entries and require their exact originals afterward. Failed enable must not
claim ownership or erase a foreign pattern. Keep the existing5000ms protocol,
delivery and exact-DOWN bounds; a multi-message drain uses one monotonic
deadline, not a fresh allowance per message. Add no infinite shutdown or timeout
increase. Persist an actual token/owner/caller/collector/custodian-bound result
in surviving control; the owner independently checks post-state and exact
collector DOWN. Missing receipt, unexpected death or timeout remains failure.

Remove only the exact registered qualified child after successful retirement
and proof, checking canonical parent-chain and device/inode/uid/gid/mode/type
identity plus owned neighbor sentinels and external sibling preservation.
On failed proof retain the configured external child and fixed failure receipt.
Native cleanup still proceeds after checkpoint failure and can remove its own
root, including A's fallback child; failed-proof fallback evidence retention is
not claimed. Do not broaden helper scope to manufacture that guarantee.

Restore/check A's captured present/absent settings after successful retirement;
native cleanup independently restores both complete application environments.
At `:owner_cleanup_completed`, verify the exact originally captured complete
environments of both runtime/storage applications, including present/absent
keys, not only A's four named settings. Copy fixed actual outcomes to the
surviving normal caller or its registered token-bound private regression
controller; they independently require the matching completion receipt and
post-state. Stop control with a fresh exact monitor and discard A's private
registry. If
begin never ran after acquisition failure, discharge ONLY recorded initial
resources; never retry a failed full finalizer as successful initial cleanup.
Checkpoint failures use the existing retained ResourceOwner failure channel.
No inspection/logging of private native key state, new request option, public
fixture function, production selector or checkpoint multiplexing is required.

Test first with an additive contract that compiles against old A: an unlinked
sacrificial fixture caller completes genuine native Api export/materialization
with positive issuance/revoke/DOWN evidence, publishes exact resource identities
to the external controller, then is actually killed while its callback waits.
The controller monitors owner/helpers itself and records all post-state facts:
exact settings, both patterns/tracer, qualified-child absence and unchanged
siblings, before asserting them. Its unregistered native owner must really
finish, not remain as an ExUnit retained receipt. Old residue is contained only
AFTER recorded failure evaluation: require dead exact owned collector/custodian,
known original/installed full trace state and exact child/parent identities
before any owned-only restoration/removal; foreign state is never mutated.
This fallback earns no pass or cleanup evidence. Preserve live3's separate FAIL.

After repair, add real configured AND default-Api in-flight caller-kill coverage
and queued-drain proof, bounded partial-
initialization coverage, exact foreign-pattern and custodian-tracer preflight
controls and missing-receipt/restoration controls using the same validators.
A private nested Observer probe may copy actual outcomes only; it cannot inject
success. Use real runtime messages, not synthetic trace/ACK/DOWN tuples. Final
whole-live/privacy/master and all other canonical gates remain required. A
focused causal-RED location run is diagnostic only, never final acceptance.

### Actual companion ACK origin and bounded queued proof after live5

Whole live4 failed32/10 and whole live5 failed32/3; neither accepts Task17.
Their raw logs, source manifests, natural2 exits and independent EMPTY/natural0
posts remain historical evidence. Live5's actual default-warm classifier
identified line3652: the newly added existential native-revoke-ACK assertion.
Its actual events contained native issuance and DOWN, not a companion ACK.
Two independent Sol source diagnoses and Astra architecture advisory2 establish
why: A traces only the custodian, while ExportArtifact's companion calls the
real reader revoke. The configured ObservedReader already sees its actual return;
default Api bypasses that wrapper. Waiting longer cannot create that producer.
The advisory is `.devenv/phase5-task17-companion-ack-architecture2.md`, SHA-256
`39a75e6699a2f8b2f7c83ca98ac7f3237b85cc98770b23af04e9842d30d6576b`.
It is architecture advice, not an Astra implementation repair or source GO.

Authorize only private nested Observer/IssuedLeases changes in new A and the
separate additive lifecycle block in new B. Keep six outer fixture functions,
all old B assertions, frozen ENOSPC bytes, model1/501/shared body/180000ms,
native source43, both existing trace patterns and every foreign-ownership guard.
No production/native/custody/helper change, new trace target/sender or inherited
process tracing is authorized by this amendment.

Before configured acquisition, bind the actual ObservedCustodian caller's
companion PID to this fixture token, owner/caller/control/collector/custodian
and exact private task-supervisor membership. Associate its opaque lease PID
only after the actual native call succeeds. Retain no native options, keys,
source/session identifiers or content. The existing configured reader is the
sole producer of a bounded actual revoke-result record: call the unchanged
DownloadLease.revoke first, then persist its fixed outcome and private identity
with that exact registered companion/lease association in surviving control.
Only an actual :ok result can earn ACK; failure, exception, disappearance, DOWN
and read denial cannot. Preserve the existing real Observer event/callback.

Notify the collector asynchronously with a distinct private observation message,
never a fabricated Erlang trace/native ACK/DOWN tuple or synchronous call that
would deadlock a paused collector. Validate the stored record's exact binding,
producer association and identity. Collector.issued still derives ONLY from
the existing real custodian start_download_lease return trace; wrapper
registration or an ACK cannot invent issuance. Hold records arriving before
that issuance as pending, apply them only after the exact real issuance is
reduced, deduplicate actual records/leases and retain source=:companion rather
than claiming a custodian return. Unmatched/stale/unissued records earn no ACK
and cannot discharge finalization.

The SAME ACK transition handles ordinary notifications, ordinary sync and
final drain. Extend the drain's receive set for the distinct notification.
Ordinary sync reconciles actual persisted records from control through that
transition, because custodian trace_delivered does not fence another sender.
Report deduplicated actual before/after consumed counts, not guessed events.
The queued test must complete/persist its real configured ACK before releasing
the gate. A general sync is only a bounded snapshot of work observed so far.
After all native issuance-capable producers and both owned supervisors have
exact monitored DOWN, seal the observation ledger and reconcile its closed
snapshot during final drain, preserving the exact existing custodian boolean
completion fence and emitted-trace fence. A sealed ledger rejects late writes.
An interrupted wrapper without a committed result has no observed ACK; only
the independently proven existing loss branch can discharge it. Preserve one
original monotonic5000ms deadline, exact restoration/preflight, actual bound
receipt, collector DOWN and surviving-owner cleanup.

Explicitly correct ONLY the new default-warm existential ACK overconstraint;
it is not an old required assertion or a newly waived native guarantee. Default
warm must instead prove the complete already-accepted loss branch, separately
from configured evidence: initially empty exact owned global supervisor, real
default Api export/materialization/close and a positive issuance-set difference
scoped to that operation. While its actual handle owner and unique companion
are live, install fresh independent monitors and bind them through that exact
supervisor. Require non-missing/non-noproc DOWN for BOTH and, for EVERY newly
issued lease, actual collector DOWN plus fresh actual native read denial.
Keep offline bytes, no remaining owned tasks, traces, environments, neighbor
and permission assertions. Never label this default loss proof as an ACK or
use a configured warm event as default evidence. Configured positive ACKs and
the original literal caller-kill positive controls remain required unchanged.

Live5 also disproved two new test arrangements. Native Asset read succeeds then
stops that lease; a positive byte observation alone cannot establish a live
lease. Document reads remain active until explicit revoke. Both new in-flight
and queued gates must therefore select a genuine positive Document read, carry
its exact lease and prove that exact PID is issued and still alive. Preserve
all byte/issuance/alive assertions and every real zero-byte event; claim active
generation, not an unread source tail. Optional native-piece callbacks/barriers
require positive actual bytes; zero-byte EOF is still recorded and delivered.

The rich graph's remaining configured generation plus another full default
export did not finish under the queued test's original5000ms bound. No hidden
collector deadlock is established by that timeout. Arrange ONLY this additive
queued test on one small plain Document, publicly uploaded, imported and
genuinely extracted before opening the unchanged drain deadline. Do not create
an empty/fake source or reduce any original rich/model/ENOSPC scenario. Still
require successful complete configured export/close and genuine default
export/page/positive bounded chunk/close while the same collector is paused.
The already-issued/monitored configured lease supplies its actual ACK and DOWN;
the default operation supplies real queued new issuance. ALL THREE consumed
counters remain strictly positive and identify the held lease's actual record;
unrelated old ACKs cannot satisfy it. Preserve exact monitors, zero-count and
missing-receipt mutants. If the minimal real arrangement still fails5000ms,
retain FAIL and diagnose; do not enlarge the budget, retry or skip work.

Before source implementation, independently review this canonical pair in
ordered DESIGN SPEC then NEW distinct QUALITY and issue root GO. Exercise real
pending-before-issuance and duplicate delivery/reconciliation without injecting
native success; copies with stale binding, wrong producer, unissued lease or
missing actual record must fail the SAME validator. Preserve original failure
history and rerun every whole-owner/static/post gate and ordered final source
reviews. E2E remains NOT RUN; no Task17/Phase5 acceptance is implied here.

## Master-owner composition and exact-link oracle repair — 2026-10-20

Whole master1 is retained FAIL:49 tests/14 failures in693.9 seconds, natural2;
its independent ownership post is EMPTY/natural0. Raw49314 bytes have SHA-256
`008f6840c945696f23ad0cb29ecb913258801ab94961e4e3d5039ce11cf8d5c9`.
All14 failures occur in the unchanged Markdown owner's shared Note creation
setup, before export assertions. Its Custodian adapter is defined only in
`note_authorization_integration_test.exs`, which the original three-file master
omitted. Phase4 acceptance lines2010–2018 records the same loading dependency.
This is a command-composition compatibility defect, not evidence of a changed
authorization or custody contract. Preserve the failed run and every old owner.
Add the FULL unchanged authorization owner to the master before its existing
flags. Do not require/load only a helper, select away its cases, duplicate the
adapter, change grants, or edit either old integration owner. The authoritative
master now contains four complete owners; all other required whole gates remain.

Independent read-only preflight additionally found a P2 defect in the NEW offline
oracle: separately present pin text plus any existing in-root href does not bind
the generated link to that immutable source's required file. No wrong production
output is established. Enforce the existing portable-format contract only in
new B and the new oracle. First add one positive-first corruption that retargets
a ready Document's extracted-text href to its existing original file, preserving
all pin text and refreshing file/manifest integrity descriptors. The old oracle
must produce an actual causal RED because it fails to reject that corruption.
Then bind each generated inventory record's reference ID, resource/version and
kind to its exact format-defined href: Note basename, Asset original, ready
Document extracted text, other included Document original with the literal
media extension. Metadata-only sources have no fictitious href. Isolate the
generated suffix after the canonical byte prefix; preserve legitimate external
links in user Markdown. Bind each citation definition to its own citation,
resource/version and fragment tuple, retaining independent expected membership
and fragment/locator checks. Do not invoke/copy a production renderer, validator,
resolver or live repository. Keep every existing positive, corruption and exact
assertion boundary; general unsafe-link checks precede new exact-link checks.

Review this complete canonical pair in ordered DESIGN SPEC then NEW distinct
QUALITY, followed by root GO, before applying the test repair. Independently
review NEW exact-pin tooling rather than editing C8 or historical evidence.
Finite whole-paired Note and offline-oracle diagnostics are permitted, not final
acceptance; existing moved diagnostic declarations require exact refreshed line
pins. Root freezes the same11 paths/four existing inverses, observes actual
oracle RED/GREEN and paired Note results, and reruns all11 whole-owner/static
gates on final source, including complete live/privacy/four-owner master. Final
SOURCE SPEC then NEW distinct QUALITY and ordinary owned closure remain required.
No source/test assertion, native/Vault interface, timeout, original1/501 model,
frozen ENOSPC, migration, dependency, E2E or publication restriction is relaxed.

## Verification, review and remaining facts

The plan records exact scoped commands. Required evidence includes causal RED,
whole four-file master Task17 command, unchanged whole Api/Artifact/Read/
Snapshot/native and architecture owners, actual format/compile/xref/static
checks and ordinary ownership-post gates. Parent serializes runtime execution,
records actual commands/source hashes/results and confirms commands are closed.
No compile/setup failure is a behavioral RED; integration exclusion is not native
execution. Final source/spec then a distinct fresh quality review precede the
authorized local commit. This is Task17-scoped acceptance, not Phase5/release or
production/browser acceptance.

Implementation must establish, rather than assume: the exact minimal temporary
permission deltas and before/after ACL restoration on the existing owned repo;
the fresh Task17 identity/wrapper on the accepted retained-RAM lane; exact real
extraction job/fragment witnesses for each media type; legal minimal SQL graph
rows for cycles/historical pins; numeric coefficients and runtime backing
regressions for the explicit schema-derived model above. These are bounded
implementation
facts, not requests to expand architecture or obtain renewed user permission.
If any cannot preserve immutable provenance, frozen custody, fixed limits or
existing assertions, stop that work and report the exact design gap. Native117
failure history stays in the accepted source handoff; no current Task16 NO-GO
premise or Task17 acceptance is asserted by this amendment. The actual failed
pre-write runs above remain failed evidence, not a completion claim.
