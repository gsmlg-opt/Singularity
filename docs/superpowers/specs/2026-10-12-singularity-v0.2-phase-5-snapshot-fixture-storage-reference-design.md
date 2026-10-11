# Phase 5 Task 13 SQL fixture storage-reference correction

Status: proposed bounded fixture-only amendment; actual independent nonauthor
source/spec and distinct fresh quality review are required before its edit.
Continuous development authority selects the recommendation automatically.
Repository authoring continues independently under its existing strict contract.

## Evidence and scope

The new compiled `KnowledgeExportSnapshotFixture.live_fixture!/1` obtains
`KnowledgeFixtures.prepared_source!/0`. The established schema-only fixture
`knowledge_fixtures.ex:23-31` intentionally persists
`knowledge-test/<object UUID>`; `prepared_source!/0` keeps that value.
The new Spool's reviewed `binding_valid?/1` accepts only the exact object UUID
or exact canonical owner/domain/lookup path. RepositoryTest's existing private
binding equality assertion requires the actual persisted storage_ref unchanged.
A correct capture must reject the inherited noncanonical fixture value;
production normalization or accepting arbitrary references would violate the
approved contract.

Full Task13 SQL already retains truthful missing-Repository RED: 43 actual
tests/24 failures. This amendment addresses a separately demonstrated invalid
NEW positive-fixture setup, not those failures' classification. No actual
encrypted source bytes, authenticated original delivery, or completed artifact
are established by these metadata capture fixtures.

## Options and recommendation

1. Recommended: correct only the NEW shared fixture's persisted reference in
   its existing owner-only setup before request work, asserting the exact row
   and stored UUID. Preserve every contract assertion and all production.
2. Change established KnowledgeFixtures: unnecessary effects on other schema
   contracts; do not change it.
3. Normalize references in Repository or widen Spool: contradicts exact source
   evidence and is not permitted.

## Exact fixture-only change

Inside `live_fixture!/1`'s existing `Fixtures.with_owner` block, before the
session token update, add:

```elixir
%{rows: [[stored_ref]]} =
  query!(
    MigrationRepo,
    "UPDATE content.asset_objects SET storage_ref=$2 WHERE id=$1 AND vault_id=$3 AND storage_ref=$4 RETURNING storage_ref",
    [
      dump(source.object_id),
      source.object_id,
      dump(source.vault_id),
      "knowledge-test/#{source.object_id}"
    ]
  )

assert stored_ref == source.object_id
```

The exact ID, owner and inherited prior reference must match one real row;
missing/different/multiple results fail setup. No request role, RLS, privilege,
policy or source-proof substitute changes. Repository must still preserve the
stored value verbatim, and Spool must retain its exact reference predicate and
all canonical-path/UUID negative cases.

Only `apps/singularity_runtime/test/support/knowledge_export_snapshot_fixture.ex`
may change. Its actual identity delegate, observation, barrier and five-second
timeout remain byte-identical. All SQL/pure test cases, assertions, selection,
default timeouts and production sources remain unchanged. The established
KnowledgeFixtures and frozen56 remain unchanged. Do not add ciphertext,
digest, size, generation or custody alterations to this correction.

## Verification and acceptance boundary

Parent alone edits with apply_patch after both actual reviews, reads the entire
source, inverse-reconstructs the prior helper byte-identically at SHA256
`90d71d4386e5e762f0c83650934be0042e578ae70fe980daa49e0960dfbb37cd`,
formats after all authors close, and records a new immutable source receipt.
No source or test/support authoring overlaps any Mix/SQL gate.

Run all five Task13 pure files and both complete Task13 SQL files with the
unchanged seed215378 and warnings-as-errors. Require the stored-reference
equality, all31 Spool cases and three real native-denial/42501 audit witnesses
to retain their assertions. Archive full output, exact actual counts/exit,
frozen/source checks and private database/root cleanup. Missing or incorrect
Repository remains RED until repaired; do not infer acceptance from this setup
correction. Actual independent final SOURCE SPEC then fresh QUALITY and all
required gates precede Task13 acceptance/local commit.

E2E NOT RUN/manual-only. No released migration, frozen Vault/custody/key/lease/
crypto/policy/capability, publication, deployment, activation, backfill or
production-data action is authorized.
