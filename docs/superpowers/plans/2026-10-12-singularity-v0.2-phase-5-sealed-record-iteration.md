# Phase5 Sealed-Record Iteration Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development or executing-plans under parent-managed ownership. Steps use checkbox syntax.

**Goal:** Remove repeated full-collection sorting from Writer metadata indexing and exact reads without weakening sealed-source integrity or resource bounds.

**Architecture:** Add internal exact Spool metadata reads and one ordered reduction; retain existing paging/cursors. Writer stores only charged identity membership and rereads actual native frames on append.

**Tech Stack:** Existing Elixir/OTP, Spool native frame readers and scoped native arity-only tracing in tests; no new dependency or process in production.

Status: final actual SOURCE SPEC and distinct fresh QUALITY closed PASS at
reviewed design ed5f601e/plan c67f0fa1. TEST-ONLY source closed and whole pure5
causal RED recorded below; production repair1 passes whole owning/retained gates.
Actual source SPEC passed; fresh source QUALITY found two additional full-path
P2s. Repair2 amendment TasksE–H passed actual design reviews. Test-only causal
RED and production authoring are closed; all current owning/retained/static
gates pass. Actual SOURCE SPEC and distinct fresh SOURCE QUALITY both CLOSED
PASS/noP1P2; Task15 is a qualified bounded component locally committed at
`4e2499d5b89664c3e7b63cb1f3136c243b276c83`, exactly seven owned paths.
The same quality agent's later model-capacity failure concerned its separate
Task9E design review, not the completed Writer source verdict; that design
review subsequently resumed and also closed PASS.
Factual statuses do not erase earlier reviewed ports/results.
Initial SOURCE SPEC found one P2: same-ID cross-collection frame substitution
passed the proposed key-only check. Design correction0 below requires exact
native index selector/reference and collection shape. New scaling-defect Solrepair0/
Astra0; earlier unrelated Writer repair1 GREEN remains historical evidence.
[Design](../specs/2026-10-12-singularity-v0.2-phase-5-sealed-record-iteration-design.md).

## Ownership and gate discipline

Parent owns design/plan/review, all formatter/Mix/SQL/services, receipts and Git.
Repair worker owns only:

- `apps/singularity_storage/lib/singularity/storage/knowledge_export/spool.ex`
- `apps/singularity_storage/lib/singularity/storage/knowledge_export/writer.ex`
- `apps/singularity_storage/test/singularity/storage/knowledge_export/spool_test.exs`
- `apps/singularity_storage/test/singularity/storage/knowledge_export/writer_test.exs`

Parent synchronizes the master design/plan, acceptance report and portable-format
document if implementation detail changes require it. Preserve other authors'
Task14 Repository/ExportRead and TaskD tests. No frozen/source-fixture/API/DDL/
dependency/quota/default-role change. Source authors close before every gate.

## Task A: Close independent design reviews

- [x] Root self-reviews design/plan coverage, exact interfaces and absence of placeholders.
- [x] Nonauthor actual design SOURCE SPEC then distinct fresh QUALITY read both full documents and native source. Record reviewed hashes and findings; resolve before test/source GO.

## Task B: Add and observe deterministic causal RED

- [x] Add one Writer test around the current public internal APIs, preserving the complete old50 cases. Use the actual existing fixture and record lists:

```elixir
test "metadata indexing sorts each large collection once and exact appends never paginate", c do
  f = fixture(c, %{extra_notes: 501})
  {accounting, counts} = with_metadata_work_trace(fn ->
    {:ok, writer} = call(:open, [context(c, f)])
    try do
      final = Enum.reduce(@collections, writer, fn collection, current ->
        Enum.reduce(f.records[collection], current, fn record, owned ->
          {:ok, next} = call(:append_manifest_record, [owned, collection, record])
          next
        end)
      end)
      final.accounting
    after
      # Initial and latest descriptors share native ownership/phase/ledger.
      # Close while this test PID still owns its ETS, before trace barriers.
      assert :ok = call(:abort, [writer])
      assert_writer_root_empty(c)
    end
  end)
  assert counts.page_calls == 0
  assert counts.large_sorts == 2
  assert accounting.metadata_records <= KnowledgeExport.limits().metadata_records
end
```

`with_metadata_work_trace/1` uses the existing Repository test's separate native
tracer pattern (repository_test.exs1938–1994), not a fake reader. Its two MFAs
are `{Spool,:read_page,3}` and `{Enum,:sort,1}`. For the latter:

```elixir
sort_spec = [{[:"$1"], [{:is_list, :"$1"}, {:>=, {:length, :"$1"}, 501}], []}]
# only caller PID is traced with [:call, :arity, {:tracer, tracer}]
# tracer counts {:trace, caller, :call, {Spool, :read_page, 3}}
# and {:trace, caller, :call, {Enum, :sort, 1}}; no argument payloads
```

Concrete helper implementation, retaining all existing helpers:

```elixir
defp with_metadata_work_trace(callback) do
  page_mfa = {Spool, :read_page, 3}
  sort_mfa = {Enum, :sort, 1}
  for module <- [Spool, Enum], do: assert({:module, ^module} = Code.ensure_loaded(module))
  caller = self()
  original_flags = :erlang.trace_info(caller, :flags)
  original_tracer = :erlang.trace_info(caller, :tracer)
  original_patterns = for mfa <- [page_mfa, sort_mfa], into: %{} do
    {mfa, {:erlang.trace_info(mfa, :traced), :erlang.trace_info(mfa, :match_spec)}}
  end
  assert original_flags == {:flags, []}
  assert original_tracer == {:tracer, []}
  assert Enum.all?(original_patterns, fn {_, state} ->
    state == {{:traced, false}, {:match_spec, false}}
  end)
  token = make_ref()
  tracer = spawn_link(fn -> metadata_trace_loop(caller, token, %{page_calls: 0, large_sorts: 0}) end)
  sort_spec = [{[:"$1"], [{:is_list, :"$1"}, {:>=, {:length, :"$1"}, 501}], []}]

  try do
    assert 1 = :erlang.trace_pattern(page_mfa, true, [:local])
    assert 1 = :erlang.trace_pattern(sort_mfa, sort_spec, [:local])
    assert 1 = :erlang.trace(caller, true, [:call, :arity, {:tracer, tracer}])
    result = callback.()
    :erlang.trace(caller, false, [:call, :arity])
    for mfa <- [page_mfa, sort_mfa], do: :erlang.trace_pattern(mfa, false, [:local])
    delivered = :erlang.trace_delivered(caller)
    assert_receive {:trace_delivered, ^caller, ^delivered}, 1_000
    send(tracer, {:finish_metadata_trace, token})
    assert_receive {:metadata_work_counts, ^token, counts}, 1_000
    {result, counts}
  after
    :erlang.trace(caller, false, [:call, :arity])
    for mfa <- [page_mfa, sort_mfa], do: :erlang.trace_pattern(mfa, false, [:local])
    Process.unlink(tracer)
    if Process.alive?(tracer), do: Process.exit(tracer, :kill)
    assert :erlang.trace_info(caller, :flags) == original_flags
    assert :erlang.trace_info(caller, :tracer) == original_tracer
    for {mfa, {pattern, match}} <- original_patterns do
      assert :erlang.trace_info(mfa, :traced) == pattern
      assert :erlang.trace_info(mfa, :match_spec) == match
    end
  end
end

defp metadata_trace_loop(caller, token, counts) do
  receive do
    {:trace, ^caller, :call, {Spool, :read_page, 3}} ->
      metadata_trace_loop(caller, token, %{counts | page_calls: counts.page_calls + 1})
    {:trace, ^caller, :call, {Enum, :sort, 1}} ->
      metadata_trace_loop(caller, token, %{counts | large_sorts: counts.large_sorts + 1})
    {:finish_metadata_trace, ^token} ->
      send(caller, {:metadata_work_counts, token, counts})
  end
end
```

Fresh QUALITY found cleanup initially started only after the trace helper
returned, missing post-callback delivery/count/restoration failures. The
corrected callback closes its owned Writer synchronously in `try/after` on
success AND failure, before any trace barrier; subsequent assertions use only
immutable accounting. Do not defer abort to `on_exit`: its ETS ledger belongs
to this live test PID. This complements unconditional trace restoration.
Trace only the test
PID, so concurrent untraced callers have no trace messages or payload exposure.
Do not change the existing module's async setting or assertions.

Require originally empty flags/tracer and disabled patterns/match specs. Restore
both patterns and caller flags in `after`, use `trace_delivered(caller)` bounded
barrier, retrieve counters and stop only the owned tracer. On callback failure,
cleanup the native Writer as well; do not leak staging for a failed assertion.
No elapsed-time threshold or arbitrary sleep. Whole test count must rise, not
replace the pagination513-file regression or any quota/collision/assertion.

- [x] Add direct Spool tests for the two proposed exports guarded before apply; native capture setup from existing owning helpers, no invented frames. Positives must equal existing page records; wrong keys/collections/swapped frames, same-ID resource/tag collection substitution, native wrong-index-reference substitution and real payload/index corruption must deny. Include ordered/empty folds, stale/aborted/expired/identity drift, ordinary consumerError and malformed/raised callback, finaldeadline barrier and unchanged cleanup sentinel. Add Writer near-limit index-counter denial retaining all old quota assertions.
- [x] Close test source author, root reads full additions/delta, formats only owning test files and captures new versioned source receipts without regenerating frozen56.
- [x] Parent runs complete pure5 below RED, records actual exits/counts/exclusions and complete native output. Expected Writer traversal test fails at page_calls/large_sorts; direct newSpool guards fail missing exports. Constructor/trace failures must be diagnosed and corrected, not called causal RED.

Whole pure5 closed4696b3/exit2: Core66actual/0, Storage103actual/21FAIL,
Runtime11actual/0 with17SQLexcluded;180actual total,159PASS. All20 additive
Spool cases reach missing concrete exports; the Writer native trace and cleanup
succeed before `page_calls == 0` fails with2080actual calls. No constructor,
tracer or old-case failures. Full native archive
`.devenv/phase5-sealed-iteration-initial-red-pure.log` SHA f98aae73c76071b66ad31c50e1f1ce6bc1088108b1a6c326275b3e9af35aefd6.
Old31Spool/50Writer cases remain unchanged; additive cases20/2. Formatted
SpoolTestc0cafb37/WriterTestbe8a650e; production Spoolb643cd80/Writer4681a19e
unchanged. New versioned source receipt7d6b4361 matches all9entries; original
frozen56 matches4019b5. Initial scaling Sol0/Astra0; production and GREEN pending.

Parent production GO followed causal RED, then source author closed repair1:
raw Spool2d6dfb4e/Writerf9da10de. Source-only inverses recover entire prior
Spoolb643cd80/Writer4681a19e; root fullread both changed blocks and every native
index helper. Tests unchanged c0cafb37/be8a650e. No old paging/chunk/frame method,
quota/deadline/manifest/custody interface changes. Parent formatter/GREEN and
actual source reviews pending; no failed repair round/Astra0.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/knowledge_export/writer_test.exs apps/singularity_storage/test/singularity/storage/knowledge_export/spool_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_snapshot_test.exs apps/singularity_core/test/singularity/core/knowledge_export_manifest_test.exs apps/singularity_core/test/singularity/core/note_markdown_sources_test.exs --seed 215378 --warnings-as-errors
```

## Task C: Implement exact sealed metadata and one traversal

- [ ] Implement `read_metadata/3` with knowncollection/exactkey/readable checks; use an additive metadata-specific helper over unchanged `read_frame/3`, authenticate the exact native index selector and payload reference, decode one record, validate collection shape and compare its actual key. Keep missingkey invalid and native mismatch owned fail_capture semantics, no payload-bearing exceptions. Keep all existing Spool interfaces byte-for-byte except necessary additive helpers.

```elixir
def read_metadata(spool, collection, key) when collection in @collections do
  with :ok <- readable(spool),
       {:ok, frame} <- Map.fetch(spool._collections[collection], key) do
    with {:ok, bytes} <- checked_metadata_payload(spool, collection, frame),
         record = JSON.decode!(bytes),
         :ok <- metadata_valid(spool, collection, record),
         true <- record_key(collection, record) === key do
      {:ok, record}
    else
      _ -> fail_capture(spool, :integrity_failure)
    end
  else
    {:error, %Error{}} = failure -> failure
    _ -> error(:invalid)
  end
rescue
  _ -> fail_capture(spool, :integrity_failure)
catch
  _, _ -> fail_capture(spool, :integrity_failure)
end
def read_metadata(_, _, _), do: error(:invalid)

defp checked_metadata_payload(spool, collection, frame) do
  expected_index = %{
    "selector" => ["metadata", Atom.to_string(collection)],
    "offset" => frame.offset,
    "length" => frame.length,
    "sha256" => hex(frame.hash)
  }
  with {:ok, index_bytes} <- read_frame(spool, :index, frame.index),
       true <- JSON.decode!(index_bytes) === expected_index,
       {:ok, bytes} <- read_frame(spool, :payload, frame) do
    {:ok, bytes}
  else
    _ -> error(:integrity_failure)
  end
end
```

- [ ] Implement `reduce_metadata/4`: readable entry, one `Map.keys |> Enum.sort`, `Enum.reduce_while` carrying only callback accumulator. Each key calls `read_metadata/3`; ordinary callbackError is rebuilt from code/retryable only and returned, malformed success invalid/exception unavailable. Final `readable` check gates `{:ok, final}` even for zero keys. No native FD or record array retained across callback.

```elixir
def reduce_metadata(spool, collection, initial, consume)
    when collection in @collections and is_function(consume, 2) do
  with :ok <- readable(spool) do
    keys = spool._collections |> Map.fetch!(collection) |> Map.keys() |> Enum.sort()
    result = Enum.reduce_while(keys, {:ok, initial}, fn key, {:ok, acc} ->
      with {:ok, record} <- read_metadata(spool, collection, key),
           {:ok, next} <- consume.(record, acc) do
        {:cont, {:ok, next}}
      else
        {:error, %Error{code: code, retryable?: retryable?}} ->
          {:halt, {:error, Error.new(code, retryable?: retryable?)}}
        _ -> {:halt, error(:invalid)}
      end
    end)
    with {:ok, final} <- result, :ok <- readable(spool), do: {:ok, final}
  end
rescue
  _ -> error(:storage_unavailable)
catch
  _, _ -> error(:storage_unavailable)
end
def reduce_metadata(_, _, _, _), do: error(:invalid)
```

- [ ] Replace Writer `capture_index!/1` with eight ordered Spool reductions. Consumer derives exactkey, deniesduplicate, calculates encoded `[capture_id, collection_name, json_key(key)]` bytes+40 and validates combined capture+index count/bytes BEFORE `Map.put(index,key,true)`. Return ordinary invalid Error for budget violation so root `value!` preserves classification. Remove only orphan `index_page!/5`; every original budget/metadata-record check remains.
- [ ] Replace Writer exact reread with indexed key membership plus `value!(Spool.read_metadata(state._capture,collection,key))`; keep actual `record_key == key` and complete expected-record equality. No original/text/fold/render/manifest/publication/ETS/cleanup change.
- [ ] Close production author, root reads entire changed methods, hashes/inverse and verifies no payload cache/options/frozen drift before formatter/gates.

## Task D: Whole GREEN, retained live gate and fresh review

- [x] Rerun complete pure5 command above to GREEN; retain separate SQL exclusions explicitly.
- [x] Run unchanged actual Repository+Snapshot SQL owning files after all authors/gates close:

```sh
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/knowledge_export/repository_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_snapshot_test.exs --seed 215378 --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format --check-formatted, compile --warnings-as-errors, xref graph --format cycles --fail-above 0
sha256sum -c .devenv/phase5-frozen-baseline.sha256
git diff --check
```

- [ ] Record actual source receipt/new hashes, commands/counts/exclusions/fulloutput and normal roots/DB cleanup, old50+new tests, retained selectedsource/budget/identity/failure contracts. Earlier accepted Spool hash changes legitimately; preserve old receipt as historical and create a new receipt, never regenerate frozen56 to accept drift.
- [ ] Actual nonauthor SOURCE SPEC then distinct fresh QUALITY read changed Spool/Writer/tests and governing docs; confirm static linear read/traversal, no weakened constraints. Repair real failures with same-defect Sol counters; escalate after two failed rounds/evidenced impasse, permit≥3 boundedAstra rounds if needed.
- [ ] Update master/report/format detail and make a small local reviewed commit only after all scoped gates/reviews pass, preserving other dirty source. No production/phase/browser/release qualification. E2E stays NOT RUN.

Repair1 whole pure5 closed53d354exit0:180actual/0fail,17SQLexcluded;
Core66/Storage103/Runtime11actual,13.6s+88.1s+2.1s. All31+20Spool and50+2Writer
cases pass. Full archive1eb75933. Retained Repository+Snapshot SQL closedb04230
exit0:48actual/0fail,11pureexcluded,32.6s+6.7s; full archive34f0c5df. Actual
23514/23503 constraint messages belong to passing failure/COMMIT contracts.
Retained Task13 pure5 closedad4cf3exit0:134actual/0fail,17SQLexcluded.
Static5e0b09exit0 format/WAE/zeroCycles; source16receipt49531b6f matched91abca,
originalfrozen56matched01c519. Root independently removes only the unique
addition marker and recovers old wholeSpoolTest1fbe2ed1 (5bd39d) and
WriterTesta1d596e8 (7b7565), including all assertions/helpers. Normal SQL
root1e718922 absent27a2a2; maintenancebcb369exit0EMPTY, no manualcleanup.
Actual fresh NONAUTHOR SOURCE SPEC closedPASS; distinct fresh QUALITY closed
two full-materialization P2s. Point-read native gates remain GREEN; Task15
scalability round1 is NOT ACCEPTED and repair2 TasksE–H are required. No Astra
recovery yet; architecture attempts remain separate.

## Task E: Review full-materialization amendment before authoring

- [x] Parent reads actual source-quality P2s and the full native hot paths/Core
  fixed paths; records genuine previous GREEN vs incomplete fullTask15 acceptance.
- [x] Actual nonauthor design SPEC reads full updated design/plan plus Writer,
  fixtures/native trace/bounds/identity paths; resolve findings, then distinct
  fresh QUALITY. No test/source authoring before these actual reviews close.

## Task F: Full-path test-only causal RED

Ownership: worker ONLY writer_test.exs additive uniquely marked block; all old
source/cases/helpers unchanged. No production edit/formatter/gates/service/Git.

- [x] Add the two independent full-materialization identity-scan and ledger-copy
  tests exactly described by the amendment, actual constructor/sealed frames,
  typed129 Notes/sources +3x43 ready Document fragments, all files and finish.
- [x] Native caller-only arity trace: Enum.count/2 and Enum.filter/2 listlen>=129,
  ETS.tab2list/1. Require original disabled patterns/flags, restore unconditionally,
  positive native outputs and synchronous owned Writer.abort before every barrier.
- [x] Add auxiliary-index synthetic near-ceiling denial, exactly-one ambiguous
  historical fragment citation denial, and any needed nested-prefix identity
  substitution regression. Retain every old50+2 case and all current helpers.
- [x] Author CLOSED; parent fullread/test-only inverse, format, immutable source
  receipt; whole pure5 RED. Work counters must be the causal failures, not fixture,
  missing tracer exports, early output/custody assumptions or timeout changes.

Author added five cases in one unique block; formatted WriterTest51d972c1,
57cases total. Parent marker-only inverse5bef3a recovers complete previous
be8a650e with all52oldcases/helpers unchanged. Formatterca6aae exit0;
whole pure5 RED05eaca exit2:Core66/0+Storage108/3FAIL+Runtime11actual/0,
17SQLexcluded;185actual total/182PASS. The three failures reach nativework
counts131/1266 and missingauxiliarybudgetdenial; all positive output/trace/
cleanup setup and old180actual plus newambiguity/inode cases PASS.
Full archive `.devenv/phase5-full-materialization-repair2-initial-red-pure.log`
SHA3f17139c0936930f3cc2106578ad4299f5cfa67ef7d40e44f69e641c0ad06d31.
Versioned source16receipt1119efdb matched8ee021; frozen56matched35be64.
This causal RED consumes no failed production round. Bounded cumulative Sol
scalability repair2 now authorized; actual GREEN/reviews/localhandoff pending.

## Task G: Bounded cumulative Sol scalability repair2

Worker ONLY writer.ex. Preserve accepted Spool ports/tests, format, Task14/D/frozen.

- [x] Build charged exact fragment counts, ambiguity-preserving identity lookup,
  ordered per-Note source key groups in the existing one-time capture folds;
  charge all headers/members/count byte growth before mutation at fixed limits.
- [x] Substitute the three exact lookups but retain native record reads, complete
  captured/appended key equality, unique fragment requirement, all comparisons,
  ordinals/UTF-8/source rendering/digests; discard auxiliary maps at publication.
- [x] Replace whole ETS ledger traversal with five fixed directory lookups and
  exact prefix allowlist; preserve every root/operation/file/directory identity,
  permission/symlink/ownership/reservation/cancellation/cleanup check.
- [x] Author CLOSED; parent full changed-source read/inverse/format/source receipt.
  No frozen/helper/options/DDL/dependencies/quota/deadline/default/source changes.

## Task H: Complete GREEN, reviews and local handoff

- [x] Parent runs the SAME complete pure5 command above with all added and old
  cases, then retained Repository/Snapshot SQL and complete Task13pure; report
  actual counts/exclusions/normal cleanup and preserve all complete native outputs.
- [x] Complete format/WAE/xrefzero, exact versioned source receipt and original
  frozen56 validation; do not regenerate frozen baseline or suppress warnings.
- [x] Actual NONAUTHOR SOURCE SPEC then distinct fresh QUALITY reads full source,
  tests and amended design/plan/native chain; all P1/P2 close before localcommit.
- [x] Audit cumulative Solrepair2 outcome: complete owning/retained/static gates
  and actual independent SPEC/QUALITY pass; escalation is not triggered. If the
  same fullTask15 outcome fails later, retain counters and route parent-managed
  Astra RECOVERY with at least3 bounded attempts if needed. Never misclassify
  architecture/model-capacity errors as repairs or artificially reset counts.
- [x] Parent scoped local commit only after all required gates/reviews; synchronize
  master/report exactscope/evidence/noVaultwork. Task16/Phase5 remain unqualified.

Repair2 source author CLOSED with only Writer.ex changed. Parent fully read all
1640 lines, retained all95 untouched methods and author whole-source inverse,
then formatted ONLY Writer (0b444f/exit0). Writer841f3e6b/Test51d972c1;
versioned16-source receipt3c6b7ee1 matched70630d/faae0b; originalfrozen56d0296d24
allmatch, never regenerated. Whole SAME pure5 closes4a39eb/exit0:185actual/0fail,
17SQLexcluded (66Core+108Storage+11Runtimeactual); complete archivefd47fc89.
Retained Repository/Snapshot SQL731f65/exit0:48actual/0fail/11pureexcluded,
archive63219b0c; rootc14f809a absentb042df, normalmaintenanceb6a231/exit0EMPTY,
archive0e1665c4, no manualcleanup. Retained Task13pure24a037/exit0:134actual/0fail/
17SQLexcluded, archive764c576c. Complete statica4ff05/exit0 format/WAE/zeroCycles,
archive6fd24830. Actual NONAUTHOR SOURCE SPEC CLOSEDPASS/noP1P2 after complete
source/tests/nativeproof reads, receiptff9a8735. Distinct fresh SOURCE QUALITY
subsequently CLOSEDPASS/noP1P2 after complete source/tests/native-path/archive
reads and independent whole old52-case inverse/checksums. Earlier spawn/followup
thread-limit failures were review availability history, not source repair results;
no parent self-review replaced the required actual review. The reviewer's later
model-capacity failure affected its separate unfinished Task9E design review,
which also subsequently closed PASS. Repair2 owning/retained/static gates and
both source reviews pass; scoped localcommit4e2499d is recorded. Cumulative
scalabilityround1 remains unaccepted history; Astra recovery0. No Task16/Phase5,
browser or release acceptance, Vault feature work, E2E or publication is claimed.
