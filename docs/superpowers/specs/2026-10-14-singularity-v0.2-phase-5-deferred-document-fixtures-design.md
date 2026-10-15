# Singularity 0.2 Phase 5 — defer excluded Document fixture construction

Status: selected necessary knowledge-test repair under continuous authorization;
independent design review CLOSED PASS, Stage1 expected RED and Stage2 focused GREEN CLOSED. Task10/Phase5 remain
NOT ACCEPTED. This does not waive or change the frozen upload lock tests.

Postimplementation original full-cohort seed151533 diagnostic naturally CLOSED2:
2083executedtests+10properties/1original100msfailure/1874excluded, rawf8bc17ac.
Bounded actual Source SPEC then distinctfresh QUALITY CLOSED PASS, but the
fixture repair did NOT remove the upload failure. Causality remainsUNKNOWN;
fresh15README gate sequence NOT STARTED on this Source. Return to bounded
diagnosis under preserved Astra eligibility; no frozen-test change/retryloop.

## Evidence and limitations

Recovery5 historical admission file passed40/0 under ordinary deadlines, but
the exact no-args README unit gate naturally failed one UploadSessionLockTest
100ms writer_chunk assertion. An unchanged full-cohort diagnostic at the same
seed151533 reproduced it. Whole original upload file passed8/0; whole Runtime
unit directory passed1023/0. Fixed complementary sibling cohorts both failed;
the second also failed the original fragmented-magic chunk assertion. The
predeclared reduction matrix STOPPED at3runs; no more reshuffling or blind retry.
All raw failures, Source seals, natural closure and maintenanceEMPTY retained.
Actual cause of the short message deadlines remains UNKNOWN.

Independent read-only source investigation found three integration-only
DocumentOutcomeIntegrationTest tags eagerly constructing100,663,807 bytes at
file loading, even when their tests are excluded. This is independently
verifiable fixture-loading work; neither its causal relationship to the upload
failure nor a cure is established. Other concrete candidate workloads include
large Markdown escaping and Fake module re-require calls; they are NOT part of
this repair. Do not call the failed gate successful or change its assertions.

## Exact selected change

Only in `apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs`:
replace the following three plaintext tags with small atom selector tags.
The exact key is `:plaintext_fixture`: use `@tag plaintext_fixture: <selector>`
and require that key in the metadata regression, never a different marker.
Resolve them in DocumentOutcomeIntegrationTest's MODULE-LOCAL setup, then call
the unchanged `C.setup(context)`. Do not change shared C.setup or S.setup.
Construct these exact expressions only when the corresponding test executes:

| Existing test | Selector | Original constructor | Original bytes |
|---|---|---|---:|
| exact 64 MiB authenticated source reaches ready without source loss | source_limit | :binary.copy(" ",67_108_859) <> "\ntail" |67,108,864|
| actual normalized text above 16 MiB persists unsupported output_too_large | normalized_over_limit | :binary.copy("x",16_777_217) |16,777,217|
| exact 16 MiB normalized output and 65536-byte fragments persist ready | normalized_fragment_limit | Enum.map_join(1..256,"\n\n",fn _ -> :binary.copy("x",65_536) end) |16,777,726|

The final original includes255 double-newline separators/510 extra bytes;
normalized fragment text remains16,777,216. Do not remove those separators or
replace any original with merely a same-sized different binary. Preserve all
three existing test names, bodies/assertions, module integration/tmp_dir tags,
and120000ms timeouts. All other plaintext tags, defaults, context fields,
test cases, media types, pin flags and setup behavior remain unchanged.

Plaintext is read only by S.setup and then used by the same real fixture for
encrypted originals, digest, persisted size, canonical source proof, extraction
probe and retained fixture.plaintext. Keeping those consumers and exact bytes
preserves original-source identity. No fake custody/completion/restore evidence.
Moving construction into setup places it inside the existing test deadline;
verification must establish it fits, not raise that deadline.

Add one narrow PURE metadata regression in this same file, in a separate ordinary
unit-executed ExUnit module with no inherited integration/tmp_dir tags or fixture
setup. It must execute in the Stage1 whole-file unit RED. Inspect compiled
ExUnit metadata for precisely these three original names: exact atom selector,
no :plaintext tag, integration/tmp_dir true, timeout120000, exactly one matching
case each, and unchanged original module inventory. Source expansion suggests
24 original cases; root Native inventory probe naturally CLOSED0 confirmed24,
exactly three expected names/sizes/preserved tags (rawSHAa93be295). The regression
must retain that confirmed24-case inventory and NOT invoke constructors, fixtures, SQL,
keys, custody or extraction. It must not materialize another96MiB expected value.

## Scope and freezes

Two independent Sol investigations mapped the source bytes/setup consumers and
the exact freeze boundary. This is knowledge extraction fixture timing, not
Vault locking/tests or substrate behavior. Continuous authorization permits the
necessary documented/reviewed test repair; routine human approval is not needed.
No production code, shared helper, schema/migration, role/grant, test timeout,
async mode, upload orchestration, Vault/custody/key/capability/DownloadLease,
defaultV2, workflow or E2E change. Preserve the existing role/read-assertion edits
in this file. No other Source change is authorized by this amendment.

Baseline file SHA1a7a1a536eb762cea906f1df007b565b9753b1dabc68b23ae8c5fb6e32938a56,
HEAD1c1ca7f68035e255247e0c2efb86d16000bb34c5, existing Source22 manifest492218d7.
This supersedes only the earlier one-path Source5 amendment for this necessary
additional path. Preserve earlier manifests; create NEW stage-specific22-file
seals for intentional changes, keeping the other21 Source paths byte-identical
and existing frozen/protected/locked seals unchanged. Do not overwrite failures.

Root owns design, Native validation, manifests/evidence and local commits.
One Sol author owns only the module-local setup/three tags/new metadata test.
No other writer or tests during parent LIVE validation. No author Native/Mix,
formatting, SQL, services, Git mutations or delegation. Apply_patch only.

## Verification and acceptance

Independent design review precedes author GO. Stage1 adds ONLY the metadata
regression; inspect actual registration and run ordinary whole-file unit tests.
Require the expected metadata-contract RED with no unrelated failures. Root
records raw/natural exit/seals; do not use a failed inventory assumption as RED.
Stage2 implements the exact deferred constructors; root formats the one file,
checks full diff/surgical preservation, publishes NEW seal, repeats focused
whole-file unit checks for GREEN. Native commands remain parent-serialized.

Reproduce the original whole umbrella unit cohort ONCE with seed151533 and
unchanged default96/deadlines on this repaired Source. It is a diagnostic, NOT
the no-args README gate; outcome does not prove causation. Any failure returns
to bounded diagnosis within authority, never a frozen lock-test change.

Run all15 exact permitted README code gates on this final Source, including
NO-ARGUMENT unit/integration/sole independent restore oracle, whole integration
owner coverage for the three originals, seven apps/xref0, root/database cleanup
and exact Source/frozen/protected/locked checks after EOF. Whole integration
proves their original120s contracts; pure metadata PASS alone is insufficient.
No Source/docs/Git mutations or extraNative/SQL during LIVE commands.

Final actual Source SPEC, then NEW distinct fresh Source QUALITY must pass.
Sync governing phase evidence preserving every failure and unknown; reviewed
small LOCAL commits then literal complete Git cleanliness are still required.
Source failedSol2/Astra4/Recovery5 unitFAIL history remains; this fixture repair
uses Sol by default. An auxiliary fixture-attempt count may be recorded, but
does NOT reset Task10's cumulative Source Sol2/Astra4 history or existing
escalation eligibility through a new symptom, label or thread. Every required
gate failure preserves that history and follows the applicable bounded Astra
route; no invented three-attempt maximum. Author attempts and tool diagnostics
remain distinguished without erasing prior Source repair failures.
Expected RED tests and read-only diagnostics are not failed repair rounds.

Task10 acceptance/dependentTask11/12 remain NO GO until all required predicates.
E2E NOT RUN/manual deferred; final browser/release acceptance still required.
No merge/push/version/tag/release/deploy/production actions or scope expansion.
