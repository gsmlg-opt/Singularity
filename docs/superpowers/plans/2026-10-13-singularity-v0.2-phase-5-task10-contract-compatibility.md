# Phase 5 Task 10 Native Contract Compatibility Implementation Plan

> **For agentic workers:** Use subagent-driven-development or executing-plans,
> with the parent ownership/native serialization in the main Task10 plan.

**Goal:** Close the six evidenced initial native failures without weakening
restored provenance, role denials, malformed-wire checks or cleanup.

**Architecture:** Add an absence-only private preflight classification; propagate
its constant sanitized error through existing savepoints. Qualify two test-local
fixture seams. No D/E/F production, migration, wire, custody or Vault edits.

**Tech Stack:** Existing Elixir/Ecto/PostgreSQL harness and authenticated fixtures.

Design: `../specs/2026-10-13-singularity-v0.2-phase-5-task10-contract-compatibility-design.md`.
Status: actual independent DESIGN SPEC then NEW distinct fresh DESIGN QUALITY
CLOSED PASS/noP1P2 on designbe69d9a4/plan1f8141be; bounded repair GO, not GREEN.
Status-only bookkeeping follows the exact archived reviewed documents.
Initial full H3 session16076 exit2/148tests6FAIL781.0s; cleanup/frozen CLOSED0.
Root owns preflight source/test/docs; disjoint Sol owns Raw/Doc test preparation.
No native/format/compile/Git mutation while either source author is LIVE.

## A. Record boundaries and causal evidence before repair

- [x] Review the actual six failures, source-backed diagnoses and four-path
  ownership in the companion design. Preserve earlier failure archives.
- [ ] Independent DESIGN SPEC then NEW distinct fresh DESIGN QUALITY on exact
  design/plan and main amendment; resolve findings. Parent local design commit
  stages only these two new reviewed documents after every native command CLOSED.
- [ ] Capture exact entry hashes including KnowledgePreflight and its tests,
  prior six Task10 files and frozen/protected receipts. No source regeneration.

## B. Synchronize precise preflight negatives and establish RED

- [ ] Root moves only the existing submission.outbox_event_id=@unknown and
  extracting.attempt_job_id=@unknown variants out of the generic negative loop.
  Invoke them explicitly with exact `:integrity_failure` expectation:

```elixir
reject_change(fixture, storage, "jobs.job_submissions", %{"id" => id(702)},
  "outbox_event_id", @unknown, :integrity_failure)
reject_change(fixture, storage, "content.document_versions",
  %{"resource_version_id" => @ids.extracting_version_id},
  "attempt_job_id", @unknown, :integrity_failure)
```

- [ ] Add optional expected_code defaulting to :backup_invalid through
  reject_change -> reject_rows -> reject_bundle. Match
  `%Error{code: ^expected_code, details: %{}}`; retain every original canonical,
  transaction-queryability, temporary-table, owned-stage, publication and
  outer-rollback assertion. No other caller or expected code changes.
- [ ] Add a late-validation contract using existing genuine authenticated bundle:

```elixir
test "missing extracting provenance during validation retains typed cleanup denial" do
  with_fixture(fn fixture, storage ->
    before = @fixtures.canonical_rows(fixture)
    bundle = authenticated(fixture)
    assert {:error, :rejected} = owner_transaction(fn ->
      assert {:ok, staged} = stage(bundle, storage)
      schema = Enum.find(Singularity.Storage.Backup.LogicalSchemaV3.all(),
        &(&1.table == "core.outbox_events"))
      relation = "pg_temp.knowledge_restore_" <> Integer.to_string(schema.ordinal)
      assert %{num_rows: 1} =
        sql("DELETE FROM " <> relation <> " WHERE id=$1", [Ecto.UUID.dump!(id(700))])
      assert {:error, %Error{code: :integrity_failure, details: %{}}} =
        validate(staged, bundle.cut)
      assert @fixtures.canonical_rows(fixture) == before
      assert_no_temp_tables()
      assert {:ok, []} = LocalFilesystemAdapter.list_staged(storage.context)
      assert_no_publication(storage)
      MigrationRepo.rollback(:rejected)
    end)
    assert @fixtures.canonical_rows(fixture) == before
    assert_no_temp_tables()
    assert {:ok, []} = LocalFilesystemAdapter.list_staged(storage.context)
    assert_no_publication(storage)
  end)
end
```

- [ ] Close test author; parent formats only the owned test, runs the complete
  preflight owner RED command below with warnings-as-errors. Record actual
  missing classification failures, never predict totals or ignore fixture errors.

## C. Minimal absence-only production repair after valid RED

- [ ] In semantics!, immediately after scope! and before references!, invoke
  document_attempt_provenance!(repo). Leave existing jobs! predicate unchanged.
- [ ] Add the exact private helper:

```elixir
defp document_attempt_provenance!(repo) do
  [[missing?]] = query!(repo, """
  SELECT EXISTS (
    SELECT 1 FROM #{relation("content.document_versions")} d
    WHERE d.state='extracting' AND d.attempt_job_id IS NOT NULL
      AND (NOT EXISTS (SELECT 1 FROM #{relation("core.outbox_events")} e
            WHERE e.id=d.attempt_job_id)
        OR NOT EXISTS (SELECT 1 FROM #{relation("jobs.job_submissions")} s
            WHERE s.outbox_event_id=d.attempt_job_id))
  )
  """).rows
  case missing? do
    true -> throw(:knowledge_restore_missing_document_attempt_provenance)
    false -> :ok
  end
end
```

- [ ] Add explicit constant-marker catch clauses before generic catches in
  stage_authenticated, validate and admission_savepoint respectively:

```elixir
:throw, :knowledge_restore_missing_document_attempt_provenance ->
  rollback!(repo, storage, Process.get(ledger, []),
    {:error, Error.new(:integrity_failure)})

:throw, :knowledge_restore_missing_document_attempt_provenance ->
  rollback!(repo, staged.storage, staged.artifacts,
    {:error, Error.new(:integrity_failure)})

:throw, :knowledge_restore_missing_document_attempt_provenance ->
  rollback_admission!(repo, name, {:error, Error.new(:integrity_failure)})
```

- [ ] Give rollback! a fourth private argument `error \\ invalid()` and change
  only its successful-cleanup result from invalid() to error. Preserve the
  rollback/release/owned-abort ordering and storage_unavailable failure branch.
  Keep every other catch and generic malformed-present denial unchanged.

## D. Disjoint test-local qualification repairs

- [ ] Sol worker, only Doc helper assert_worker_contract!: resolve exact native
  positive OIDs using existing owner transaction, then keep role matrix/ACL checks:

```elixir
oids = owner(fn ->
  Enum.map(@functions, fn signature ->
    [[oid]] = sql("SELECT $1::text::regprocedure::oid", [signature]).rows
    assert is_integer(oid) and oid > 0
    oid
  end)
end)
# Existing role matrix uses this same resolved OID per signature:
sql("SELECT has_function_privilege($1::text,$2::oid,'EXECUTE')", [role, oid])
# Existing Public ACL statement changes only p.oid=$1::regprocedure to:
# p.oid=$1::oid, parameter [oid]. All other assertions remain exact.
```

- [ ] Sol worker, only three Raw final-deleted setups after ready_document!
  and before synthetic event/cut: existing owner context selects exact genuine
  ready event by owner/version payload, asserts single event and uses existing
  insert_submission!(event_id,"document_projection") for exact native identity.
  No duplicate-suppression clause, event removal/rewrite or shared fixture edit.
  Preserve every existing final-state, runner, canonical and idempotence check.
- [ ] Both authors report actual CLOSED/held, exact changed paths/hashes and
  inverse-diff preservation; no own native/formatter/Git. Parent alone resumes.

## E. Serial native qualification and independent handoff

Complete preflight RED/GREEN command, no line filters:

```sh
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/knowledge_preflight_test.exs --seed 215378 --warnings-as-errors
```

- [ ] Parent formats owned four paths, compiles warnings-as-errors, then runs
  whole preflight GREEN and exact complete main TaskH H3 command (all three
  owners, no filters). Focused diagnostics may precede, never replace these.
- [ ] Retain all main H Runtime2/Base/Task9/Task8/static/README gates. Capture
  exact eight Task10/compatibility sources, frozen56/protected receipts, full
  outputs/exit/counts, natural command closure, normal maintenance EMPTY and
  exact allocated root absence after each full native command.
- [ ] Record cumulative repair rounds accurately: initial E/F implementation
  and these read-only diagnoses had Solrepair0/Astra0. First implementation
  repair attempt is counted only once performed/verified. Two failed Sol repair
  rounds or evidenced impasse trigger parent-managed actual Astra, at least
  three bounded attempts if needed. Never weaken required assertions or freeze.
- [ ] Actual independent SOURCE SPEC then NEW distinct fresh SOURCE QUALITY on
  exact combined implementation/docs/evidence. Resolve/rerun; main bounded local
  Task10 commit includes only reviewed paths. No merge/push/tag/version/release/
  deploy/data or E2E. Phase5/Task16 remain unaccepted until their required gates.
