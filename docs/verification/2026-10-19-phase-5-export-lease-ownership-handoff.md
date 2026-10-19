# Phase 5 native export-lease ownership: source handoff

## Verdict and exact scope

Qualified local **native prerequisite**, not original Task16 or Phase5 acceptance.
Worktree `.trees/v0.2-phase-5-export-backup`, branch
`codex/v0.2-phase-5-export-backup`; tested/reviewed files are committed through
`6c7f867309470e23e8f34c06a8f53af0b496d48d`.

The user's 2026-10-19 exception permits only Asset/Document export-request
ownership and cleanup in KeyCustodian/DownloadLease. Ordinary Asset download,
ordinary Document request, extraction-worker, authenticated source/session/
principal/owner/unlock/capability/epoch and key/crypto behavior remain unchanged.
No migration, dependency, public flag or configuration was added. No broader
Vault feature work occurred. E2E NOT RUN/manual-deferred; no merge, push,
version/tag/release/deploy, production activation/backfill or production data.

Governing [design](../superpowers/specs/2026-10-19-singularity-v0.2-phase-5-export-lease-ownership-design.md)
and [plan](../superpowers/plans/2026-10-19-singularity-v0.2-phase-5-export-lease-ownership.md)
retain their historical design-stage status separately from current facts.

## Implementation and local commits

- `2d98710b051d9fc493f8a0cb0b062b2c01b92371`: reviewed design/plan and nine
  governance additions; eleven docs only, parent `a5afb537e7d8f7455ec71e7c98bc120d5d397673`.
- `994611ecebe336dafbbfa2cc991afb2a3be95ca4`: native two-source change, new unit
  owner and additive genuine-live cases; exactly four files, parent `2d98710b…`.
- `6c7f867309470e23e8f34c06a8f53af0b496d48d`: new exact-inverse architecture
  owner only, parent `994611ec…`.

Root verified both source commits' exact pathsets/parents and all five committed
blob SHA256 values against the tested/reviewed bytes. Both staged whitespace
checks passed; source-only index EMPTY and literal Git status empty.
Actual source clean-closure receipt
`.devenv/phase5-task16-export-lease-source-commits-clean-closure.json`,
SHA256 `391f54df1b56cffbb4d397cf90959c5920f6dead61f58750828a6dd05583ab46`.
Its committed-clean guard SHA256 is
`1320a480ecc982f42bcec4bbe7d9449610a891d04e15a0e106314ef98f1dc3ae`.
These are actual source closure, not proof of the subsequent docs-only closure.

`export_lease/2` allocates its fixed native five-second pending ticket before
enqueue; only a timely successful reply accepts it. Timeout cancels even for a
surviving caller; failed acceptance of a known PID waits for native revoke
acknowledgement or termination. Actual call origin owns cleanup before init
usability. Export-only monitors, pending expiry, cancellation and reader linkage
clean abandoned custody and prevent plaintext delivery. Accepted leases retain
the original60-second TTL. No caller selects owner/ticket/deadline or worker mode.

## Actual verification and preserved failures

Every native command used a fresh mode0600 raw PTY with natural completion via
the established private PostgreSQL wrapper. Each immediately received its own
fresh ordinary residual-database query; all21 posts exited0 with EMPTY bodies.
No forced database cleanup, command deadline, seed change, filtered native
output or concurrent author/runtime commands were used.

| Evidence | Actual result |
| --- | --- |
| Unchanged-source baseline001/003 | 92 unit and75 integration executed, zero failures |
| Missing-API RED005 | 38 executed/38 intended failures:33 public API and5 helper |
| Genuine live RED007 | 81 executed:15 new missing-API failures, original66 passed |
| Candidate1 GREEN011/013 | 130 unit and90 integration executed, zero failures |
| Permissive inverse RED015/017 | 138 executed/135 failures:133 mutations plus2 inverse checks |
| Architecture GREEN021 | 254 executed, zero failures:116 existing plus138 new |
| Candidate2 unit031 | 141 registered,9 excluded,132 executed, zero failures |
| Candidate2 integration033 | 95 registered,5 excluded,90 executed, zero failures |
| Candidate2 architecture035 | 254 registered/executed, zero failures |
| Format037, devcompileWAE039, xref041 | natural0; zero xref cycles |

The initial native015 four-megabyte output was tool-truncated and its full body
was NOT READ by root or either source reviewer. All135 failure names/reasons
were independently machine-reconciled against native017's fully read1232-line
raw. The diagnostic-only boolean-local change retained the same assertions and
did not filter or weaken them. All other41 raw bodies were read completely.
The existing negative foreign-key log23503 remains in integration output; its
test verdict is zero failures. The existing devenv2.2.2/locked2.1.2 notice remains
recorded; no environment update was performed.

Actual SOURCE SPEC candidate1 required a P2 evidence repair: direct revoke and
synthetic expired-ticket tests did not execute the public wrapper's known-PID
failed-acceptance acknowledgement branch. The source appeared correct.
Two additive Asset/Document tests suspend the real requester before its genuine
successful reply, cross the actual5-second boundary, and suspend the known lease.
No result may arrive before cleanup resumes; then actual DOWN, sanitized error,
surviving caller, native read denial and unchanged unlocked session are required.
Both processes are resumed in try/after and on_exit before fixture teardown.
Exactly54 added unit lines reconstruct candidate1 bytes on removal. No original
assertion changed; no production repair or invented additional RED was claimed.

## Independent reviews and proof limits

Design SPEC then NEW distinct DESIGN QUALITY both CLOSED PASS before source GO.
Source candidate1 P2 receipt remains unchanged:
`.devenv/phase5-task16-export-lease-source-spec-candidate1.json`,
SHA256 `2ee9c8e8ca18f3a857145ff0ddcad00fa33be16bad716e12f977fcba0d7a7a99`.

Revised independent SOURCE SPEC `/root/task16_export_lease_source_spec` CLOSED
PASS after complete amended725-line unit and14 new raw bodies; prior complete
coverage of the four unchanged owners was retained by exact hashes, not claimed
as a fresh reread. Receipt SHA256
`32fa7d38ea4aa3e700dfc1223096c1222c43e564f583a9a29e366aa8bc83ae79`.

NEW distinct SOURCE QUALITY `/root/task16_export_lease_source_quality` CLOSED
PASS, no findings. Fresh complete five-owner coverage:4571 KeyCustodian,
778 DownloadLease,725 unit,2231 live,283 architecture lines including decoded
16-hunk literals; all41 safe raw bodies. Receipt SHA256
`44e7ba20dca5fb42497e8e6ebdac1c44312909341e825ae74826f8e2ddf3f4e0`.
Both reviewers independently reconciled raw42 metadata/argv/exits/counts,
all21 posts, exact inverses and opening/closing guards.

Root's source review covered all16 changed native hunks and ordinary/auth context,
the complete new unit/source-contract owners and complete additive live diff.
It is not a fresh reread claim for all unchanged legacy lines; fresh independent
QUALITY complete-owner coverage is recorded explicitly above.

Unit authorization/reader doubles are not genuine encrypted-custody proof.
Separate live cases use actual custody, storage and retained encrypted Document
sources, covering loader/init timeout, pre-recording death, blocked real-reader
cleanup, hard lease death, accepted TTL and same-session isolation.
No universal wall-clock cleanup bound is claimed while an existing native
loader/clock/revoke callback is blocked. Barriers are released before asserting
cleanup; manual teardown is not credited as autonomous recovery.
The new wrapper witness covers expiry BEFORE acceptance after a successful
reply. Narrow live post-CAS clock crossing remains NOT WITNESSED; fixed source
and pure helper proofs are explicitly narrower evidence.
Source failed Sol repair rounds0; Astra repair attempts0. The prior Astra
architecture advisory and read-only reviewer parser corrections are not repairs.

## Frozen source attribution

The original56 manifest remains immutable:
`d0296d241c66e382baa09a0a092fe8add6df66364d5f2d5644f4f4ea1963a050`.
Its literal raw check reports exactly two authorized native-source mismatches;
the other54 remain byte-identical. All16 reviewed exact old/new hunks with
unique two-sided contexts independently invert to original DownloadLease
`3ecce1470e11d506435d8213faa1b2c0c012ffb360cb3e4b82f67bdd5277636e`
and KeyCustodian
`33a5eb62e2e8ff951dfddbb65cb029a66654a56bdab51e553a89e7d98d95b7bd`.
All133 mutation counterproofs reject; no rebaseline or whole-module whitelist.
Existing four ordinary unit owners, Assets.Download, ExportRead, Task8 and
native-text API attribution remain byte-identical. The existing live owner has
only additive cases/observers and no removed original assertions.

Qualified source5 manifest SHA256:
`6e5a597602d5dd40ee5a0e74d7e105ba9e3dd14c81adec2aceb61f432f174086`.

```text
4745d1b11ac40a499913bab80d4cc78e89705deaa3113065983760ecd913b060  apps/singularity_runtime/lib/singularity/runtime/download_lease.ex
1ce96736cc737fa6d07b72286ae24e1f56b989b665f878d92343c5884f883b6b  apps/singularity_runtime/lib/singularity/runtime/key_custodian.ex
a047896e3dd65af462f173877f5d7fe55a40357ba5e89a4f0050fa90ca162358  apps/singularity_runtime/test/singularity/runtime/export_lease_ownership_test.exs
3945e1cefe62154f3521915c0abd2f433de117d2ae2650ad7d026efacf109b9a  apps/singularity_runtime/test/singularity/runtime/knowledge_export_custody_live_test.exs
7615cb292537aae9f7fc17c42d210aee814104d72af8a1d3c3dce0f4b432f2a7  apps/singularity_web/test/singularity/architecture/export_lease_ownership_contract_test.exs
```

## Exact commands and immutable evidence

The following are the actual final source-qualification command lines, not
new executions. Test commands retain seed215378 and warnings-as-errors;
format, development compile and xref use their explicitly listed flags:

```sh
script --quiet --return --flush --log-out '/home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-5-export-backup/.devenv/phase5-task16-export-lease-native031-unit-ack.log' -- devenv shell -- bash .devenv/phase5-pg-command.sh 'mix' 'test' 'apps/singularity_runtime/test/singularity/runtime/export_lease_ownership_test.exs' 'apps/singularity_runtime/test/singularity/runtime/download_lease_test.exs' 'apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs' 'apps/singularity_runtime/test/singularity/runtime/asset_download_test.exs' 'apps/singularity_runtime/test/singularity/runtime/knowledge_export_read_test.exs' '--seed' '215378' '--warnings-as-errors'
script --quiet --return --flush --log-out '/home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-5-export-backup/.devenv/phase5-task16-export-lease-native033-integration-candidate2.log' -- devenv shell -- bash .devenv/phase5-pg-command.sh 'mix' 'singularity.test.integration' 'apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs' 'apps/singularity_runtime/test/singularity/runtime/knowledge_export_custody_live_test.exs' '--seed' '215378' '--warnings-as-errors'
script --quiet --return --flush --log-out '/home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-5-export-backup/.devenv/phase5-task16-export-lease-native035-architecture-candidate2.log' -- devenv shell -- bash .devenv/phase5-pg-command.sh 'mix' 'test' 'apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs' 'apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs' 'apps/singularity_web/test/singularity/architecture/export_lease_ownership_contract_test.exs' '--seed' '215378' '--warnings-as-errors'
script --quiet --return --flush --log-out '/home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-5-export-backup/.devenv/phase5-task16-export-lease-native037-format-check-candidate2.log' -- devenv shell -- bash .devenv/phase5-pg-command.sh 'mix' 'format' '--check-formatted' 'apps/singularity_runtime/lib/singularity/runtime/download_lease.ex' 'apps/singularity_runtime/lib/singularity/runtime/key_custodian.ex' 'apps/singularity_runtime/test/singularity/runtime/export_lease_ownership_test.exs' 'apps/singularity_runtime/test/singularity/runtime/knowledge_export_custody_live_test.exs' 'apps/singularity_web/test/singularity/architecture/export_lease_ownership_contract_test.exs'
script --quiet --return --flush --log-out '/home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-5-export-backup/.devenv/phase5-task16-export-lease-native039-compile-candidate2.log' -- devenv shell -- bash .devenv/phase5-pg-command.sh 'env' 'MIX_ENV=dev' 'mix' 'compile' '--warnings-as-errors'
script --quiet --return --flush --log-out '/home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-5-export-backup/.devenv/phase5-task16-export-lease-native041-xref-candidate2.log' -- devenv shell -- bash .devenv/phase5-pg-command.sh 'env' 'MIX_ENV=dev' 'mix' 'xref' 'graph' '--format' 'cycles'
```

Each invocation's own post used the same raw-PTY/wrapper pattern with:
`psql --dbname=postgres --no-psqlrc --tuples-only --no-align --file=.devenv/phase5-task11-residual.sql`.
The old28 campaign remains immutable at SHA256
`235b1136b42cfb7ec3d237adbd3aad4982721e5ca4ac25d5f8a6c44e7a3c6bc0`.
Cumulative42 campaign `.devenv/phase5-task16-export-lease-native42-campaign.json`
SHA256 `18c3ea2efc4011aefc57e9e944b3de46c0bec2b50f414055a6ec7ac5b44a0208`
contains every exact argv/raw/size/line/exit and count. Raw42 manifest SHA256
`36926e1cece51ec82ddb6c405ea39b90e69a51000a9356f9228afe3d8baaabf9`.
Ignored evidence is retained in this worktree; no ignored tooling/raw is staged.
The excluded Task11 static-native secret raw was never opened.

```text
b4a7d2a29404475a26041e6f9926d0a49c3a3f21043e121d8dfc80d7dcc0e196  .devenv/phase5-task16-export-lease-native001-baseline-unit.log
3a8eb11397078401292348cf47d56f5de4a31a832fac7f6411c3d56f1c208141  .devenv/phase5-task16-export-lease-native002-baseline-unit-post.log
53b837b45751197009c6aaad26209693c4b3880ee0658982db3e7bc5ced0dc7e  .devenv/phase5-task16-export-lease-native003-baseline-integration.log
0408d20a588502d38dee1e5ff23b87c1cf2d3f7c32a2d055cb084114e63debf2  .devenv/phase5-task16-export-lease-native004-baseline-integration-post.log
7650de34f51e25495ad01c2a0c818f4ad2b56619d5e8cebbbd90d788a7ce7249  .devenv/phase5-task16-export-lease-native005-red-unit.log
497c992bd1fc61290e46770e0debcf2991856c5e691bb544529b9c9bbf7e96b5  .devenv/phase5-task16-export-lease-native006-red-unit-post.log
406a64b1a8702897fc224762d99b81815192e97fa4f2a43553a832733f695cc5  .devenv/phase5-task16-export-lease-native007-red-integration.log
8d429ddc35227376525112b44f3589ac72c704454d6f8d3576e806a737850d62  .devenv/phase5-task16-export-lease-native008-red-integration-post.log
756ae94b45728a3ac2107ebef4f31fe5a40b1241fff780cf5750b076d25537be  .devenv/phase5-task16-export-lease-native009-format.log
ecec7ee9bb1552e2c7870dbbc595a240062c965dc81ff07cbf5326e5efb6c1b8  .devenv/phase5-task16-export-lease-native010-format-post.log
1409a934097cfef2df36d99ea8498750e73a9226ac56449e2301c3fac61cc7ec  .devenv/phase5-task16-export-lease-native011-green-unit.log
5dcdc7b5b1c892e65f744cc79c1dd19f03dc9b59fa84965a82f93263f2ead3b9  .devenv/phase5-task16-export-lease-native012-green-unit-post.log
31c28b05d7ed3e82c536aebcb9cd17bc5591c97e8061e8e84511e0a083dc104d  .devenv/phase5-task16-export-lease-native013-green-integration.log
8fd916b36d079212b6271cf28f14d67bcc6f2e67ee741f46c31fa8ac6e4c4d51  .devenv/phase5-task16-export-lease-native014-green-integration-post.log
01c4c31c037ff97d142fdfa5a26a3af95dc80a551ff8f6957442ae51c74359f6  .devenv/phase5-task16-export-lease-native015-inverse-red.log
6b48852e151528eed0d2fd2ba4128cafbed48eece82d75e1a4136348efd010ca  .devenv/phase5-task16-export-lease-native016-inverse-red-post.log
81f97200e90cb287e77e4d0eb08555c4d04df52726c4965fc1781c6ca2ed0b3a  .devenv/phase5-task16-export-lease-native017-inverse-readable-red.log
b08d15683f664724d85cbb47718602d620a36200001ba2b641438a5f7da50d1c  .devenv/phase5-task16-export-lease-native018-inverse-readable-red-post.log
106e0bc271f19ded328ae553e634ad4bd96ddc10d25381960d657fd3ac3eacc8  .devenv/phase5-task16-export-lease-native019-inverse-format.log
96b2d560bba0d5b438db0bcbb5193d4ac7b0bae8e6ef8afeb31e4f2f26ca4fc0  .devenv/phase5-task16-export-lease-native020-inverse-format-post.log
f86e80121cf647273ac8c4b08b101cf6f2c7df233fe0041a86d6f546fe496c52  .devenv/phase5-task16-export-lease-native021-architecture-green.log
06db7aa7a0eadf761096de18b69834defb08b269707c1eeb723ece3589e9b2b5  .devenv/phase5-task16-export-lease-native022-architecture-green-post.log
32301f92fa9087cd93ab4442186d1b19f69d0967a2f42b1910f518ffb8a9c6a2  .devenv/phase5-task16-export-lease-native023-format-check.log
5564f171a5595855cbfaa6c47f558c4c43aaeb751826f5d9dcab01c421fb99e0  .devenv/phase5-task16-export-lease-native024-format-check-post.log
6ae232825e43973c46b670ce4a1e95dc88bdcff2b7727c3d9e1fe1b610fbf2c8  .devenv/phase5-task16-export-lease-native025-dev-compile.log
30398ded295d246fbba599983e5cfa6d7cea6dbe89e0e364cf548894dbcca847  .devenv/phase5-task16-export-lease-native026-dev-compile-post.log
9512a781cb8cf7cc2d4504d26edae8e9ff48e16beee8bfac48787bfdf09fef5a  .devenv/phase5-task16-export-lease-native027-xref.log
4e9a24158f95d283b60a680f5b810b4968cc820c1abe8cd07eacc2045a04c281  .devenv/phase5-task16-export-lease-native028-xref-post.log
e46740325d68aa23a6683ae83c46656cee936a755538a6f16272ea5313007f69  .devenv/phase5-task16-export-lease-native029-format-unit-ack.log
6d33ca76a4a060c910eb85fedc12475486cfe52dfbb87d758e52ef1d702195f8  .devenv/phase5-task16-export-lease-native030-format-unit-ack-post.log
3a3988b5458742929e486e9e9bd1b9cc08c7e3cca4e2809f56c434010a4ada0d  .devenv/phase5-task16-export-lease-native031-unit-ack.log
01eb8e9d096ed52288fea491d65e48eee333bf1661bab226b241a9393bb7f2f6  .devenv/phase5-task16-export-lease-native032-unit-ack-post.log
ea1a2ba208d3ea4d0b71e6b19ea4ff4b9c7cd76ee0cec5c4dfd6c5d8124775ea  .devenv/phase5-task16-export-lease-native033-integration-candidate2.log
f6a8e65679d1b8e96f4af2b5c24d78e92839d1bc29c2e58fc7a32dcffd1cdfac  .devenv/phase5-task16-export-lease-native034-integration-candidate2-post.log
122c9bcdc5f28af11081133a784f367d991f8791027f17fd9a916981bcf9f598  .devenv/phase5-task16-export-lease-native035-architecture-candidate2.log
91b0d209b0bffac189bfd9b9552fc74e821b2910d6baf5a522d607698aeb661a  .devenv/phase5-task16-export-lease-native036-architecture-candidate2-post.log
3f24d67ad9f9f765080ecf6db73946e72698272a5be2e75621450a90cb24c25f  .devenv/phase5-task16-export-lease-native037-format-check-candidate2.log
8460a61c28d46fa6bed98156915cc9460978ad9c5bfb4c1978390ec9a007d6dd  .devenv/phase5-task16-export-lease-native038-format-check-candidate2-post.log
cb555f3e822fed73a98c4824705c3140aacb062a6fccafb079761c428a2d88f7  .devenv/phase5-task16-export-lease-native039-compile-candidate2.log
924625e6b018e3dfc65b898e01c33b7e938aac8dc730e4d386ffdd04030ca272  .devenv/phase5-task16-export-lease-native040-compile-candidate2-post.log
16d6806622f6cb7b863ed1c06928adfa2496e1cbd9e1565695b2d64c8f98f0c1  .devenv/phase5-task16-export-lease-native041-xref-candidate2.log
8c6760c2d44b136fc48d64bfc44e6001061e0de4572b98904ee2204b242ae77e  .devenv/phase5-task16-export-lease-native042-xref-candidate2-post.log
```

## Documentation closure and next work

This is the docs-review candidate. Actual documentation SPEC then NEW distinct
QUALITY, exact docs-only commit and literal clean closure remain subsequent
facts, recorded separately; this snapshot cannot prove its own later commit.
Any post-authoring architecture confirmation belongs to that later actual
closure record, not the already-closed source42 campaign.

Resume original Task16 Steps1–8 using the dedicated native entry point inside
the companion adapter. Keep strict timeout/pre-recording-companion-death
end-to-end tests and original ALL-leases checkboxes unchecked until the actual
orchestrator passes them. Native acceptance does not complete artifact ownership,
authorization handoff, startup exclusion, handles or the four Runtime.Api calls.
Step7a is already accepted at `9f91c97eb392b4c49c888ed31795d520d15bb8dd`:
preserve it and the native-text inverse when layering Step7b. Task17 live portable
acceptance, Task18 historical upgrade and Task19 complete permitted README gates
remain. E2E NOT RUN; no browser/release/production acceptance is claimed.
