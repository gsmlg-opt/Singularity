# Phase 3 Runtime event contract repair implementation plan

> **For agentic workers:** Use subagent-driven-development for disjoint work
> and independent review. The parent alone runs formatting, builds, tests,
> PostgreSQL, and Git. Wait for the Document fixture-lifetime implementer's
> ownership handoff before editing `document_extraction_job_test.exs`.

**Goal:** Repair two stale Runtime event assertions while preserving exact
event identity, authorization metadata, extraction state, and deduplication.

**Architecture:** Compare claimed submissions by retained event ID without
requiring arrival order; compare complete owner outbox snapshots around actual
ready restoration and terminal replay. Production code remains unchanged.
Follow the [design](../specs/2026-10-10-singularity-v0.2-phase-3-runtime-event-contract-repair-design.md)
and continuous authority; no routine human approval pause is required.

**Tech Stack:** Elixir/ExUnit, existing owned PostgreSQL 17 integration
environment, `.devenv/phase3-integration.sh`, shared dependencies via
`MIX_DEPS_PATH`.

## Task 1: Characterize and review

- [ ] Read the design, current two owning files, claim migration
  `20260722000100_skip_vault_locked_outbox_claims.exs`, projection-event migration
  `20261009000300_document_projection_events.exs`, and existing Phase 3 design.
- [ ] Parent records current SHA and diff, including fixture-lifetime changes,
  and characterizes both unchanged event-test bodies:

```sh
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_runtime/test/singularity/runtime/outbox_dispatcher_test.exs apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs --seed 918339
```

Expected: the ready-restoration count contract fails; undefined dispatch order
may reproduce FAIL or produce isolated PASS. Record actual executed/excluded
counts, failures, allocation, and cleanup. Preserve full-run `37888` evidence.
Do not manufacture RED, change deadlines, or classify an unrun check as PASS.

- [x] Close independent exact-document SPEC then separate QUALITY review.
  Both passed with nonauthor `search_observer_actual_review`.
- [x] Confirm the fixture-lifetime worker has stopped editing the shared job
  test before assigning its implementation ownership.
  Worker handoff retained job-test SHA `adf3ca4509d1c0b0237372d54f74c1bbf9862bebf7c7221976e65e885db5b312`;
  parent still owns execution and the unchanged event-body baseline.

## Task 2: Repair extraction-generation dispatch assertions

**Modify:** `apps/singularity_runtime/test/singularity/runtime/outbox_dispatcher_test.exs`,
test `retry and restore extraction generations encode and submit with stable dedupe`.

- [ ] Retain both original fixture events and initial exact dispatch summary.
  Replace the generation-ordered receive loop with identity-based checks:

```elixir
first =
  for _ <- 1..2 do
    assert_receive {:runner_submit, envelope, runner_id}
    {envelope.job_id, {envelope, runner_id}}
  end

expected_ids = Enum.map(events, &load_uuid(&1.id))
assert Enum.sort(Enum.map(first, &elem(&1, 0))) == Enum.sort(expected_ids)
first_by_id = Map.new(first)

for {event, generation} <- Enum.zip(events, [1, 2]) do
  {envelope, _runner_id} = Map.fetch!(first_by_id, load_uuid(event.id))
  assert envelope.expected_entity_revision == generation
  assert envelope.idempotency_key ==
           "document-extraction:#{resource_version_id}:#{generation}"
  assert {:ok, _encoded} = EnvelopeCodec.encode(envelope)
end

refute_receive {:runner_submit, _, _}
```

- [ ] Keep the original reset loop scoped to `events` and the second exact
  `submitted: 2, skipped: 0, failed: 0` summary. After that summary, assert:

```elixir
second =
  for _ <- 1..2 do
    assert_receive {:runner_submit, envelope, runner_id}
    {envelope.job_id, {envelope, runner_id}}
  end

assert Enum.sort(Enum.map(second, &elem(&1, 0))) == Enum.sort(expected_ids)
assert Map.new(second) == first_by_id
refute_receive {:runner_submit, _, _}
assert FakeRunner.submission_count(runner) == 2
```

Multiset comparison precedes mapping so duplicate IDs cannot disappear.
Keep the original codec, generation, key, reset, and deduplication assertions.
Do not impose production SQL ordering or alter runner/dispatcher behavior.

## Task 3: Repair the ready-Document restore event contract

**Modify:** `apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs`,
test `restoring ready Document re-exposes identical result without reopening or event`.

- [ ] Rename the final words to `without reopening or extraction event`.
  Keep initial `C.run(f)`, its receipt, and the original attempts/fragments
  snapshot. Replace the old count snapshot with a local complete-row snapshot:

```elixir
events = fn ->
  S.owner_query(
    "SELECT to_jsonb(event) FROM core.outbox_events AS event WHERE vault_id=$1 ORDER BY id",
    [f.source.vault_id]
  ).rows
  |> Map.new(fn [event] -> {event["id"], event} end)
end

before_events = events.()

assert [[principal_epoch, owner_epoch, canonical_revision]] =
         S.owner_query(
           """
           SELECT principal.authorization_epoch, owner.authorization_epoch, version.revision
           FROM identity.principals AS principal
           JOIN core.vaults AS owner ON owner.id=$2
           JOIN core.vault_members AS member
             ON member.principal_id=principal.id AND member.vault_id=owner.id
           JOIN content.resource_versions AS version
             ON version.id=$3 AND version.resource_id=$4 AND version.vault_id=owner.id
           WHERE principal.id=$1 AND principal.kind='owner'
             AND principal.revoked_at IS NULL AND member.revoked_at IS NULL
           """,
           [f.source.principal_id, f.source.vault_id,
            f.document.resource_version_id, f.document.resource_id]
         ).rows

assert canonical_revision == 0
```

The snapshot includes all immutable metadata and also requires unchanged
mutable columns for these undispatched rows; it does not omit projection events.
The authority query reads the exact fixture's current canonical epochs.

- [ ] Keep `S.tombstone!(f, :document)`, `C.hidden!(f)`,
  `C.mutation!(f, :restore)`, and `C.live!(f)` in their original order. Before
  the existing replay assertion, require the exact new event:

```elixir
after_restore = events.()
assert Map.take(after_restore, Map.keys(before_events)) == before_events
assert [restored] = Map.values(Map.drop(after_restore, Map.keys(before_events)))
restored_id = restored["id"]
assert {:ok, ^restored_id} = Ecto.UUID.cast(restored_id)
refute Map.has_key?(before_events, restored_id)
assert restored["event_type"] == "document.restored"
assert restored["idempotency_key"] == "document-projection:#{restored_id}"
assert restored["vault_id"] == f.vault_id
assert restored["principal_id"] == f.principal_id
assert restored["principal_authorization_epoch"] == principal_epoch
assert restored["vault_authorization_epoch"] == owner_epoch
assert restored["required_capability"] == "asset.read"
assert restored["classification"] == "private"
assert restored["envelope_version"] == 1
assert {:ok, _correlation_id} = Ecto.UUID.cast(restored["correlation_id"])
assert restored["causation_id"] == nil
assert restored["expected_entity_revision"] == canonical_revision
assert restored["payload"] == %{
         "resource_id" => Ecto.UUID.load!(f.document.resource_id),
         "resource_version_id" => Ecto.UUID.load!(f.document.resource_version_id)
       }

assert {:ok, ^receipt} = C.run(f)
assert {S.attempt_rows(f), S.fragments(f)} == before
assert events.() == after_restore
```

Keep all original attempt/fragment/receipt and hidden/live assertions. Preserve
the fixture-lifetime registrations already added by the other slice. No event
filtering, count-only replacement, or production mutation is needed.

## Task 4: Verify, independently review, and commit locally

- [ ] Parent formats only the two owned files and reruns their complete batch
  from Task 1. Diagnose remaining failures; compatibility repair counters for
  this slice begin at zero, separate from earlier observer recovery counters.
- [ ] Parent runs existing exact-event/lifecycle regressions:

```sh
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/document_projection_events_test.exs apps/singularity_storage/test/singularity/storage/document_lifecycle_test.exs --seed 918339
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix format --check-formatted
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix compile --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix xref graph --format cycles --fail-above 0
git diff --check
```

- [ ] Nonauthors review SPEC then QUALITY against the exact two-file diff;
  resolve findings and rerun relevant checks without weakening assertions.
- [ ] Confirm owned database/root cleanup, stopped PostgreSQL, unchanged
  production/migration/lockfile hashes, protected worktrees, and valid links.
- [ ] Parent records exact outcomes and source hashes in the qualification
  record, preserves historical FAIL and E2E NOT RUN, and explicitly stages
  only reviewed slice files for a local conventional commit.
- [ ] Resume other full-gate repairs and the remaining README checks.

## Self-review

Identity-multiset checks reject foreign/duplicate/missing submissions before
mapping; comparing both dispatch maps proves retained envelope and runner
identity. Complete-row snapshots preserve every old event and require exactly
one restored event with canonical revision and live authority metadata.
Terminal replay cannot create another event. Production ordering, Vault,
extraction deadlines, fixtures owned by another slice, source provenance, and
backup formats remain intact. Independent review and all execution are pending;
this plan makes no Phase 3 acceptance or qualification claim.
