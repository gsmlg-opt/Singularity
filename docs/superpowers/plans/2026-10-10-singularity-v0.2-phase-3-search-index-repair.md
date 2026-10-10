# Phase 3 Guarded Search-Index Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Repair the two failing selective-index contracts through a guarded candidate-ID function, preserving current authorization, immutable-source results, ranking, paging, deadlines, and diagnostic privacy.

**Architecture:** A single read-only table-owner definer selects uncapped canonical candidate identities after fresh live authorization. The existing web-role Store joins those identities only for nonempty queries and retains all outer visibility, text, rank, and cursor checks. The already-qualified synthetic observer proves executed inner index nodes on the actual production Store call; it is not a product diagnostic API.

**Tech Stack:** Elixir/Ecto, PostgreSQL 17 PL/pgSQL, existing GIN/pg_trgm indexes, ExUnit, process-specific Erlang call/return tracing, and the qualified test-only auto_explain NOTICE observer.

---

## Authority, baseline, and execution boundary

Work in `.trees/v0.2-phase-3-search-design`, branch `codex/v0.2-phase-3-search-design`, based on observer prerequisite commit `cdfa29ab46913d65a7611a2f2e9f820f120c9cc7`. Read the complete [reviewed repair design](../specs/2026-10-10-singularity-v0.2-phase-3-search-index-repair-design.md) and [original Phase 3 design](../specs/2026-10-09-singularity-v0.2-phase-3-unified-lexical-search-design.md). The initial historical design-review checkpoint was SHA256 `abf390ced68bd2d3a5604a139da8c58d1ef05d6aaec5b22abd5ecb067cfb9d06`; the independently reviewed two-result observation amendment is `4d32dd0f2653a8b5120f3f94fd4fd96386caa81a554e090aa1901aa1abbaed5e`. This plan does not supersede their privacy or provenance rules.

The later transaction-local assertion-preservation amendment was independently reviewed at design SHA256 `d5c26a3f614b89654ec3ccc5e64c6073324cfd7da897aa053d2daad4e56a084d`; it retains the original plan test's exact settings assertion during the Task 6 rewrite. Earlier design digests above identify historical review checkpoints, not the amended file's current digest.

The observer prerequisite is complete with independent SPEC and QUALITY reviews: parent sessions `62549`, `17116`, and `30119` qualified static/pure, real-web nested proof, and cleanup respectively. See its [owning plan](2026-10-10-singularity-v0.2-phase-3-search-plan-observer.md). Do not rebuild its lifecycle or replace its named real Repo. Its helper starts this repair at SHA256 `87213eef3a4a8017004951781a04160b06e01a3e3ed199c73e5ccc5505c3e8f3`.

Unchanged Store/pagination characterization already passed in parent session `70425`: 21 integration cases, zero failures, seed `215378`, 19.5 seconds. The parent used the owning harness and stopped its PostgreSQL afterward. Do not rerun that baseline merely to label it RED. Original selective qualification remains **FAIL**, two of four contracts, until this repair actually qualifies; the evidence remains in the [verification record](../../verification/2026-10-09-phase-3-acceptance.md).

The continuous-development authority permits this reviewed forward migration, fixture contracts, necessary compatibility fixes, documentation, independent review, and local commits without renewed human approval. It does not permit product expansion, Vault semantics, production data/backfill/activation, merge, push, version/tag/release, deployment, or E2E. E2E remains **NOT RUN** and an unmet required gate still prevents phase acceptance/advancement.

The parent serially owns every formatter, Mix/test command, database/service lifecycle, Git action, and commit. Workers edit assigned disjoint files only. Preserve all existing assertions and user work. Characterize and repair ordinary failures; retain cumulative repair counts and the established Sol-two-failed-rounds/Astra escalation conditions. No planner forcing, leakproof changes, RLS relaxation, grants to inspect hidden GUCs, runtime credentials, or copied inner-query EXPLAIN.

## Full-gate follow-up: post-load fixture maintenance

The earlier scoped passes below remain historical. Clean full integration
`37888` reopened both selective cases; unchanged owning run `38416` failed the
title case (four executed, one failed, 34.8 seconds, seed `918339`). Diagnostic
`4158` retained all assertions and printed only already-validated closed
metadata before them: title sample 1 had one candidate call, one result,
one outer loop, 47 buffer nodes and only `search_entries_fts`; cleanup passed.
Thus that reproduced failure is the missing required title index, not missing
plan evidence. FTS, short-query and deadline contracts passed.

- [x] Characterize the unchanged fixture and locate the failure without raw
  plans, SQL, parameters, result content or exception inspection.
- [x] Measure the already-permitted uniform maintenance on all three indexes.
  Probe `7612` exited 2 with four invalid tests because the relation-name binding
  needed `$1::text::regclass`, not `$1::regclass`; it supplied no plan evidence.
  Corrected probe `47219` exited 0: 71/208/270 actual pending pages cleaned,
  four tests passed in 33.8 seconds. FTS seven samples used backend `1604292`
  with 49 buffer nodes; title used `1609596` with 50; both observed the required
  indexes. Short row visits remained 32,768/32,766. Do not attribute the older
  zero-page probe or every full-run failure to this maintenance.
- [x] Remove temporary diagnostic prints/error branches. The retained owning
  test diff adds only uniform maintenance before ANALYZE plus bounded fixed-name
  page reporting. Every original contract and observer byte stays unchanged.
- [x] Independently review that narrow diff and the design amendment, SPEC then
  QUALITY, without changing production indexes, credentials, settings or code.
  Nonauthor `search_observer_actual_review` passed both reviews on the final
  13-line test diff, SHA `a371e9e6a9ab9996d549ba532a3b3e4f7b8d3d389e4610a9448f028d06a2fc1d`.
- [x] Parent reruns the final owning command with both seeds and the existing
  combined search regression with seed `918339`:

```sh
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_test.exs --seed 918339
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_test.exs --seed 215378
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/search_candidate_ids_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_store_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_pagination_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_observer_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_test.exs --seed 918339
```

Final unprobed runs all exited 0: `25556`, seed `918339`, four tests passed in
35.7 seconds; `33312`, seed `215378`, four passed in 35.5 seconds; combined
`47775`, seed `918339`, 86 executed cases passed, seven excluded, 101.3 seconds.
Both selective shapes retained seven same-backend cold/warm samples with all
three named content indexes. Short-query counts and the original deadline
contract also passed. Each wrapper stopped PostgreSQL. Final static checks
passed in `96668`; cleanup `19748` confirmed zero generated databases, absent
recorded roots and stopped PostgreSQL, with direct checks covering every new root.

- [x] Record exact final hashes, cleanup, reviews and results, then narrowly
  commit the test-only maintenance locally.
  Test-only maintenance is local commit `e7a6723924135c45ec9b45b72b297b5ab94846ac`;
  evidence documentation is the subsequent local handoff.
- [x] Re-run the clean-SHA full allowed README sequence after all compatibility
  repairs. E2E remains NOT RUN and no phase advancement is implied.
  Full ordered non-E2E run `91785` exited 0 on clean candidate
  `35c1f8360dd22b129832a1618b3723032a1983bd`: 1,383 unit/property cases, 1,109
  integration cases (including all four original plan contracts), complete
  V1/V2 restore, 197 frontend tests and the remaining static/build checks passed.
  Independent complete-candidate SPEC and separate QUALITY source reviews
  passed on that same SHA; fresh cleanup `8761` passed. The qualification record
  retains exact counts/seeds and all earlier failures. The complete phase gate
  remains unmet because manual E2E is still NOT RUN.

## Exact file map

Create:

- `apps/singularity_storage/priv/repo/migrations/20261010000000_create_guarded_search_candidates.exs`: the sole new function, owner, ACL, fixed settings, forward-only downgrade error.
- `apps/singularity_storage/test/singularity/storage/postgres/search_candidate_ids_test.exs`: real-role authority, input, canonical, migration, and controlled concurrency contracts, with private owning helpers only.

Modify:

- `apps/singularity_storage/lib/singularity/storage/postgres/knowledge_search_store.ex`: nonempty candidate CTE/join only; preserve empty-query SQL and all 13 bindings.
- `apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_store_test.exs`: owning source creation seeds actual read assignments once; add nonempty/empty compatibility assertions.
- `apps/singularity_runtime/test/singularity/runtime/search_rebuild_test.exs`: only the evidenced Task 8 ordered-progress wait repair; preserve all original revocation assertions and deadlines.
- `apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_pagination_test.exs`: owning source creation seeds read assignments once; original order/rank/cursor assertions stay intact.
- `apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_test.exs`: retain four contracts and 8,192-row fixture; move actual call capture behind the observer helper, strengthen nested cold/warm and inner-plus-outer scan evidence.
- `apps/singularity_storage/test/support/knowledge_search_plan_observer.ex`: add only `search_summary/3` and its private correlated trace/parser; preserve existing lifecycle and `authorization_summary/2`.
- `apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_observer_test.exs`: add actual-Store proof/privacy/trace-cleanup contracts without changing its six existing contracts.
- `docs/superpowers/plans/2026-10-09-singularity-v0.2-phase-3-unified-lexical-search.md`, this plan, and `docs/verification/2026-10-09-phase-3-acceptance.md`: parent records exact qualification and remaining gate status.

The three existing files above are the complete direct-Store caller inventory. Do not change shared `Fixtures`/`KnowledgeFixtures` defaults, released migrations, bootstrap, SafeSQL, authorization functions, runtime/API/custody, cursor policy, backup code, or architecture hashes. Existing role/migration tests are gates, not automatic edit targets. New candidate catalog coverage belongs in its owning test file. If an exact enforced inventory needs a necessary additive entry, first show the actual failing assertion and make only that reviewed contract update; never weaken an inventory assertion.

The original plan test starts at SHA256 `01b20aca6afb66f65e0e62f17cbc083e5753603b446e62412dae0fb0595da570`; amendments below replace unavailable evidence, not the named-index obligations. Runtime privacy remains byte-identical at SHA256 `17e6eeebdef3314b328b600e02110c840a64ebffc3727162e928dcd957d01056`, uninstrumented. The design and this plan require no new general test-support file.

## Parent command conventions

All following commands are for the parent, from this worktree, using its devenv PTY and shared dependencies. Owning integration commands use the existing private `.devenv/phase3-integration.sh` allocation/start/stop wrapper; it supplies `SINGULARITY_TEST_OBSERVER_PGDATA`. The committed helper must not embed that harness's temporary path or start/stop PostgreSQL itself.

```bash
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_observer_test.exs --seed 215378
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/search_candidate_ids_test.exs --seed 215378
```

ExUnit excludes integration cases in the ordinary unit command; report executed versus excluded counts separately. Every actual RED/GREEN result, seed, source hash, runtime, cleanup result, and local commit belongs in the evidence record. Do not infer execution success from this document.

## Task 1: Establish missing-function RED and explicit owning fixture authority

**Files:** Create `search_candidate_ids_test.exs`; modify only the three enumerated direct-Store fixture files.

- [x] Add an `async: false`, integration-tagged owning module with a positive Note and ready Document built using `KnowledgeFixtures`, then projected with the existing private builder inside `Fixtures.with_owner/1`. Its first test calls the new function with `q="o"`, `kind="all"` (both established fixture titles contain this literal) through `ScopedRepo.transact(RequestRepo, scope, callback)` and expects only the two exact `entry_id` values, deduplicated and ordered by `COLLATE "C"`. Assert real `session_user = current_user = 'singularity_web'` before the call; no SET ROLE substitutes for this positive control.

The private direct-call seam is fixed and parameterized. Convert database results/errors to closed identities/error tuples inside the helper before any assertion; never inspect raw errors or their query fields in failure output:

```elixir
defp candidates(source, q, kind, tags \\ []) do
  ScopedRepo.transact(RequestRepo, Map.take(source, [:principal_id, :vault_id]), fn repo ->
    case SafeSQL.query(repo, """
         SELECT candidate.entry_id
         FROM content.search_candidate_ids($1::text,$2::text,$3::uuid[]) AS candidate
         ORDER BY candidate.entry_id COLLATE "C"
         """, [q, kind, tags]) do
      {:ok, %{rows: rows}} -> {:ok, rows}
      {:error, %Postgrex.Error{postgres: fields}} -> candidate_error(fields)
      _ -> {:error, :candidate_call_failed}
    end
  end)
end

defp candidate_error(%{code: :undefined_function}),
  do: {:error, :candidate_function_missing}
defp candidate_error(%{code: code, message: message} = fields)
     when (code == :check_violation and message == "search candidates input is invalid") or
          (code == :insufficient_privilege and message == "search candidates are not authorized") do
  {:error, {code, message, {not is_nil(fields[:detail]), not is_nil(fields[:hint])}}}
end
defp candidate_error(_), do: {:error, :candidate_call_failed}

test "real web reads only canonical Note and ready Document identities" do
  source = KnowledgeFixtures.source!() |> seed_reads!(["note.read", "asset.read"])
  note = KnowledgeFixtures.note!(source)
  {document, fragment} = KnowledgeFixtures.ready_document!(source)
  Fixtures.with_owner(fn ->
    for resource <- [note, document] do
      result = SafeSQL.query!(MigrationRepo,
        "SELECT content.reconcile_search_resource_internal($1,$2)",
        [source.vault_id, resource.resource_id])
      assert result.rows == [[1]]
    end
  end)
  identity = SafeSQL.query!(RequestRepo, "SELECT session_user,current_user")
  assert identity.rows == [["singularity_web", "singularity_web"]]
  expected = Enum.sort([
    ["note:" <> Ecto.UUID.load!(note.resource_version_id)],
    ["document:" <> fragment.fragment_id]
  ])
  assert candidates(source, "o", "all") == {:ok, expected}
end
```

- [x] Give each owning test file a private source-construction wrapper, replacing its calls to `KnowledgeFixtures.source!/0`, not its search helper. The existing Store/pagination wrappers seed both reads; the new authority file seeds exactly the capability list supplied by each case. Keep invalid-map and foreign-owner assertions unchanged. The plan fixture seeds both reads once when `canonical_fixture!/0` creates its source. Seed the existing product capability names if their definition rows are absent (fresh Storage migrations do not seed `asset.read`), then assignments; this follows the reconciler's established owning fixture pattern. Never invent a capability meaning or un-revoke an assignment:

```elixir
defp seed_reads!(source, names) do
  Fixtures.with_owner(fn ->
    for name <- names do
      SafeSQL.query!(MigrationRepo,
        "INSERT INTO core.capabilities(id,name) VALUES($1,$2) ON CONFLICT(name) DO NOTHING",
        [KnowledgeFixtures.uuid(), name])
    end
    result = SafeSQL.query!(MigrationRepo, """
    INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id)
    SELECT $1,$2,capability.id FROM core.capabilities AS capability
    WHERE capability.name=ANY($3::text[])
    ON CONFLICT(principal_id,vault_id,capability_id) DO NOTHING
    """, [source.principal_id, source.vault_id, names])
    assert result.num_rows == length(names)
  end)
  source
end

defp authorized_source! do
  KnowledgeFixtures.source!() |> seed_reads!(["note.read", "asset.read"])
end
```

This wrapper is called once per newly created source. Negative cases retain their absent/revoked assignments throughout; no per-search setup or shared fixture mutation is allowed. An empty names list is valid in the authority module and inserts zero rows.

- [x] Parent runs the new owning file. Expected RED is undefined `content.search_candidate_ids(text,text,uuid[])` after its live-role/canonical preconditions pass, not a fixture or authentication failure. Check `rg --files apps/singularity_storage/priv/repo/migrations | rg '20261010000000'` is empty before creating the migration; do not renumber another migration. Record no production edit yet.

Task 1 execution: parent `31744`, exit 2, seed `215378`, 2.4 seconds,
one test failed exactly with the closed `:candidate_function_missing` category
after the real web-login and canonical fixture prerequisites passed. Migration
version availability was checked before implementation. This is intended RED,
not a failed repair round. The original Store/pagination assertions remain
unchanged; their local authority wrappers are fixture-only changes.

## Task 2: Create the guarded forward-only candidate function

**Files:** New migration and `search_candidate_ids_test.exs`.

- [x] Add independent real-role contracts for Note-only, Document-only, and conjunctive all-kind reads. Each uses a fresh source and the exact required read assignments; note.write/asset.write are not substitutes. Assert both-read all success, each single-read all denial, and direct worker/dispatcher/preauth denial through their actual Repo logins. Use catalog ACL evidence for PUBLIC and existing unrelated-role denial controls; do not create a new production role or membership.
- [x] Add the fixed catalog contract before migration implementation: exact three argument types and `RETURNS TABLE(entry_id text)`; one function and no additional privileged helper; owner table owner; `prosecdef=true`, `provolatile='v'`, `proparallel='u'`, `proisstrict=false`; exact two `proconfig` values; no PUBLIC or non-web runtime EXECUTE. Capture existing role attributes/memberships, ENABLE/FORCE flags, policies, grants, and three valid/ready GIN index definitions as immutable comparison data. Parent runs owning RED and records the missing function.
- [x] Implement `Singularity.Storage.Migrations.CreateGuardedSearchCandidates`, `up/0` with `SET LOCAL ROLE singularity_table_owner`, one CREATE FUNCTION, explicit OWNER/REVOKE/GRANT, then `SET LOCAL ROLE NONE`. `down/0` raises exactly `Ecto.MigrationError, "Guarded search candidates migration is forward-only"`. Use this function header and guard, not a new authorization abstraction:

```sql
CREATE FUNCTION content.search_candidate_ids(
  requested_q text, requested_kind text, requested_tag_ids uuid[]
) RETURNS TABLE(entry_id text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER PARALLEL UNSAFE
SET search_path = pg_catalog, content, core, identity, pg_temp
SET pg_trgm.similarity_threshold = '0.3'
AS $function$
DECLARE principal uuid; owner uuid; capabilities text[]; pattern text;
BEGIN
  IF requested_q IS NULL OR requested_q = ''
     OR pg_catalog.octet_length(pg_catalog.convert_to(requested_q,'UTF8')) > 1024
     OR requested_kind IS NULL OR requested_kind NOT IN ('note','document','all')
     OR requested_tag_ids IS NULL THEN
    RAISE EXCEPTION 'search candidates input is invalid' USING ERRCODE='23514';
  END IF;
  IF COALESCE(pg_catalog.array_ndims(requested_tag_ids),1) <> 1
     OR pg_catalog.cardinality(requested_tag_ids) > 20 THEN
    RAISE EXCEPTION 'search candidates input is invalid' USING ERRCODE='23514';
  END IF;
  IF pg_catalog.array_position(requested_tag_ids,NULL::uuid) IS NOT NULL THEN
    RAISE EXCEPTION 'search candidates input is invalid' USING ERRCODE='23514';
  END IF;
  IF pg_catalog.current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'search candidates are not authorized' USING ERRCODE='42501';
  END IF;
  BEGIN
    principal := NULLIF(pg_catalog.current_setting('singularity.principal_id',true),'')::uuid;
    owner := NULLIF(pg_catalog.current_setting('singularity.vault_id',true),'')::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'search candidates are not authorized' USING ERRCODE='42501';
  END;
  IF principal IS NULL OR owner IS NULL THEN
    RAISE EXCEPTION 'search candidates are not authorized' USING ERRCODE='42501';
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock_shared(pg_catalog.hashtextextended(
    'singularity:authorization:' || principal::text || ':' || owner::text,0));
  SELECT auth.capabilities INTO capabilities
  FROM core.live_principal_authorization() AS auth
  WHERE auth.principal_id=principal AND auth.vault_id=owner AND auth.principal_kind='owner'
    AND auth.principal_revoked_at IS NULL AND auth.membership_revoked_at IS NULL
    AND auth.clearance IN ('private','sensitive','restricted');
  IF NOT FOUND THEN
    RAISE EXCEPTION 'search candidates are not authorized' USING ERRCODE='42501';
  END IF;
  IF (requested_kind IN ('note','all') AND NOT ('note.read'=ANY(capabilities)))
     OR (requested_kind IN ('document','all') AND NOT ('asset.read'=ANY(capabilities))) THEN
    RAISE EXCEPTION 'search candidates are not authorized' USING ERRCODE='42501';
  END IF;
  pattern := '%' || pg_catalog.replace(pg_catalog.replace(pg_catalog.replace(
    requested_q,pg_catalog.chr(92),pg_catalog.chr(92)||pg_catalog.chr(92)),
    '%',pg_catalog.chr(92)||'%'),'_',pg_catalog.chr(92)||'_') || '%';
  RETURN QUERY
  WITH /* singularity:search_candidate_ids:v1 */ matched AS (
    SELECT e.entry_id FROM content.search_entries AS e
    WHERE e.vault_id=owner AND e.classification='private'
      AND (requested_kind='all' OR e.kind=requested_kind)
      AND e.search_vector @@ pg_catalog.plainto_tsquery('simple'::regconfig,requested_q)
    UNION
    SELECT e.entry_id FROM content.search_entries AS e
    WHERE e.vault_id=owner AND e.classification='private'
      AND (requested_kind='all' OR e.kind=requested_kind)
      AND e.title ILIKE pattern ESCAPE pg_catalog.chr(92)
    UNION
    SELECT e.entry_id FROM content.search_entries AS e
    WHERE e.vault_id=owner AND e.classification='private'
      AND (requested_kind='all' OR e.kind=requested_kind)
      AND e.body ILIKE pattern ESCAPE pg_catalog.chr(92)
    UNION
    SELECT e.entry_id FROM content.search_entries AS e
    WHERE e.vault_id=owner AND e.classification='private'
      AND (requested_kind='all' OR e.kind=requested_kind)
      AND pg_catalog.char_length(requested_q)>=3
      AND e.title OPERATOR(search_extensions.%) requested_q
  )
  SELECT e.entry_id
  FROM matched AS candidate
  JOIN content.search_entries AS e ON e.entry_id=candidate.entry_id
  JOIN content.resources AS resource
    ON resource.id=e.resource_id AND resource.vault_id=e.vault_id
   AND resource.classification=e.classification AND resource.kind=e.kind
   AND resource.current_version_id=e.resource_version_id AND resource.deleted_at IS NULL
  JOIN content.resource_versions AS version
    ON version.id=e.resource_version_id AND version.resource_id=e.resource_id
   AND version.vault_id=e.vault_id AND version.classification=e.classification
  LEFT JOIN content.note_versions AS note
    ON e.kind='note' AND note.resource_version_id=e.note_resource_version_id
   AND note.resource_version_id=e.resource_version_id AND note.resource_id=e.resource_id
   AND note.vault_id=e.vault_id AND note.classification=e.classification
  LEFT JOIN content.document_versions AS document
    ON e.kind='document' AND document.resource_version_id=e.resource_version_id
   AND document.resource_id=e.resource_id AND document.vault_id=e.vault_id
   AND document.classification=e.classification AND document.state='ready'
  LEFT JOIN content.document_fragments AS fragment
    ON e.kind='document' AND fragment.id=e.fragment_id AND fragment.resource_id=document.resource_id
   AND fragment.resource_version_id=document.resource_version_id AND fragment.vault_id=document.vault_id
   AND fragment.classification=document.classification AND fragment.ordinal=e.ordinal
  WHERE e.vault_id=owner AND e.classification='private'
    AND (requested_kind='all' OR e.kind=requested_kind)
    AND ((e.kind='note' AND note.resource_version_id IS NOT NULL)
      OR (e.kind='document' AND fragment.id IS NOT NULL))
    AND NOT EXISTS (
      SELECT FROM pg_catalog.unnest(requested_tag_ids) AS requested(tag_id)
      WHERE NOT EXISTS (
        SELECT FROM content.resource_tags AS membership
        JOIN content.tags AS tag ON tag.id=membership.tag_id AND tag.vault_id=membership.vault_id
         AND tag.classification=membership.classification
        WHERE membership.resource_id=e.resource_id AND membership.vault_id=owner
          AND membership.classification='private' AND tag.vault_id=owner
          AND tag.classification='private' AND tag.id=requested.tag_id
      )
    );
END
$function$;
ALTER FUNCTION content.search_candidate_ids(text,text,uuid[]) OWNER TO singularity_table_owner;
REVOKE ALL ON FUNCTION content.search_candidate_ids(text,text,uuid[])
  FROM PUBLIC,singularity_web,singularity_worker,singularity_dispatcher,singularity_pre_auth;
GRANT EXECUTE ON FUNCTION content.search_candidate_ids(text,text,uuid[]) TO singularity_web;
```

The fixed source marker is part of the candidate SELECT, not the authorization query. No dynamic SQL, persistent write, per-branch LIMIT, rank, caller scope, extra helper, timer reset, or planner override enters the function. Every emitted identity is unique because `matched` uses UNION and `search_entries.entry_id` is its existing primary key.

Two evidence-driven implementation refinements preserve this contract. The
migration calls the already-granted `search_extensions.similarity('','')` once
after selecting the table-owner role, before CREATE, to register the USERSET
GUC on a cold historical-upgrade connection (`99538`). The single static marker
is inside the SQL after `WITH`: PostgreSQL's parser trims material preceding the
first SQL token, so a comment before WITH would not survive into nested Query
Text. This nonsemantic placement refinement is source-analysis evidence, not
actual nested-plan qualification; Task 6 still has to prove the original call.

- [x] Parent reruns owning GREEN. Expected exact positive identities and fixed 42501 denials, not empty-success authorization fallback. Parent also runs the unchanged roles and search-projection schema gates. Make a small local commit of the new migration, owning test, and three fixture-only authority changes after this batch passes; use explicit paths and message `feat(storage): add guarded canonical search candidates`.

Task 2 execution: parent `46619` recorded 11 tests with nine expected
missing-function/catalog failures before implementation. Final owning run
`58453`, exit 0, passed all 12 contracts in 17.5 seconds; role/projection-schema
gate `99086`, exit 0, passed 45 unchanged tests in 147.4 seconds. All runs used
seed `215378`. Independent SPEC and QUALITY reviews passed for the new migration,
owning tests, and fixture-only changes. Review strengthened complete historical
policy equality and the all-user-schema privileged-function inventory using
predecessor `20261009000400`; this is not the later populated upgrade gate.
Source/input/concurrency/index qualification in Tasks 3–8 remains outstanding.
The checkpoint was committed locally as
`8fa8aa1d1a55485713dc200c4758d13e7b9994b3`
(`feat(storage): add guarded canonical search candidates`). Tasks 3 and 4 may
proceed in parallel because both depend on this guarded function checkpoint,
not on each other's test changes; the parent still serializes all execution.

## Task 3: Qualify direct input, context, revocation, and shadowing guards

**Files:** `search_candidate_ids_test.exs`; migration only if a newly failing contract proves a defect.

- [x] Add table-driven direct SQL calls for null/empty q, 1,025 UTF-8 bytes (including multibyte boundary), null/unknown kind, null tags, nested arrays, null elements, and 21 duplicate tag IDs before deduplication. Positive boundaries: 1,024 bytes, empty tags, 20 valid repeated tags, and literal `\\`, `%`, `_` escaped exactly like Store. Use separately scoped transactions because a database exception aborts its transaction; never continue a matrix in an aborted transaction.
- [x] Add missing/empty/malformed principal and owner GUC cases and unsupported repeatable-read/serializable transactions. Do malformed GUC checks through a raw real RequestRepo transaction with fixed `set_config` calls, not through ScopedRepo validation that would preempt the database guard. Use actual owner/principal identifiers for wrong-owner, non-owner principal, inactive account, revoked principal, revoked membership, and revoked capability cases. Public-only clearance cannot be persisted under the unchanged `vault_members_classification_check`: prove its UPDATE is rejected by that exact constraint/SQLSTATE, membership stays private, and the positive candidate control and canonical snapshot remain unchanged. Do not claim a function denial for this impossible state or modify the constraint. This evidence-based contract amendment corrects the fixture failure in parent run `93996`. Existing reconciler tests provide the exact fixtures and UPDATE columns; all mutations are disposable owner fixture SQL, not authority doubles. A preceding positive call and following clean independent call demonstrate that failure is not merely missing content.
- [x] Add local assertions using the private `candidate_error/1` sanitization above, never raw query/params/options/errors. Expect `{:error,{:check_violation,"search candidates input is invalid",{false,false}}}` or `{:error,{:insufficient_privilege,"search candidates are not authorized",{false,false}}}`; the booleans prove DETAIL/HINT absence without exporting their values. Undefined-function RED uses the closed `:candidate_function_missing` category. Direct EXECUTE-denied roles have PostgreSQL's own 42501 message rather than the function's message: reduce that path to a closed code predicate privately and assert insufficient privilege, without emitting its text. Test Store's existing mapping with separate invalid and forbidden patterns, each `%Error{message: nil, details: %{}, retryable?: false}`. Type parser errors that precede function invocation retain sanitized mapping; do not claim the function produced its own message in those cases.
- [x] Add temporary-table/caller-search_path shadowing controls on the web connection, using only its existing temporary privileges and fixed synthetic names. The qualified references and function trusted path must still yield the exact legitimate identities; do not grant CREATE on application schemas.
- [x] Parent runs owning RED/GREEN increments. A newly added contract may already pass; record that actual result rather than forcing a failure. Fix only the evidenced guard defect, then rerun the complete owning module. Preserve immutable canonical snapshots before and after all successful and rejected read calls. Commit this bounded qualification batch as `test(storage): qualify search candidate authority boundaries` once green.

Qualified after the evidence-based fixture correction: owning run `5183` passed
all 27 tests, and independent amended SPEC and QUALITY reviews passed. The
prior run `93996` failure remains recorded. This is one successful Sol fixture
repair, not a production guard change; Tasks 5–8 remain unqualified.

## Task 4: Preserve the Store's nonempty and empty-query contracts

**Files:** Store and the three direct-Store test files.

- [x] Add a successful nonempty Store call without read capabilities as an intended denial contract, alongside existing actual matching-result controls. Add assertions that empty q still returns rank zero without invoking the candidate function; use process-specific call capture of actual SQL, not production instrumentation. A source with no read assignments is allowed only for the established direct-storage empty-q characterization; Runtime still applies its own mandatory capabilities.
- [x] Preserve `parameters/2`, `rank_expression/1`, `text_predicate/1`, resolve paths, item/page mapping, cursor domain, and `fixed_settings/1` byte-for-byte. Add these two private fragments in Store and interpolate them at the indicated existing SQL anchors:

```elixir
defp candidate_relation(""), do: ""
defp candidate_relation(_), do: """
, candidates AS MATERIALIZED (
  SELECT candidate.entry_id
  FROM input
  CROSS JOIN LATERAL content.search_candidate_ids(input.q,input.kind,input.tags) AS candidate
)
"""

defp candidate_join(""), do: ""
defp candidate_join(_),
  do: "JOIN candidates AS candidate ON candidate.entry_id = entry.entry_id"
```

Change the `statement/1` opening from `), scored AS MATERIALIZED (` to `)#{candidate_relation(q)}, scored AS MATERIALIZED (`; after its existing `CROSS JOIN input`, insert `#{candidate_join(q)}`. The empty fragments yield the same SQL meaning and no definer call. The nonempty relation invokes the function once from the single-row input; it does not pass `$1` owner or introduce a fourteenth binding. Retain every outer join/predicate and its materialization/order/cursor/limit text.
- [x] Parent runs Store and pagination GREEN, retaining all original 21 cases and any new focused cases. Compare exact ordered tuples, integer ranks, immutable timestamps, locators and cursor continuity, including repeated page limits 1/7/50 and mixed-kind tied rows. Verify unknown/foreign tags, query escaping, 13 bindings, hidden historical/conflict/not-ready resources, and exact-source resolve behavior remain unchanged. The existing Store suite already contains these assertions; do not replace them with weaker counts.
- [x] Parent commits only Store and these owning compatibility assertions as `fix(storage): join guarded candidates for nonempty search`. No Runtime, SafeSQL, source DTO, cursor, auth, or Vault edit belongs in this commit.

Qualified locally in `9793289851022c15ea6aa31305daeecacb2c9d85`: RED `92037`
had the expected one failing contract, GREEN `33792` passed all 26 tests, and
static gate `33585` passed formatting/compilation with zero xref cycles.
Independent nonauthor SPEC and QUALITY reviews passed. This narrow Store gate
does not establish nested-index or complete-phase acceptance.

Parent command for this task:

```bash
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_store_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_pagination_test.exs --seed 215378
```

## Task 5: Prove exact-lock fresh authority and conservative source coherence

**Files:** `search_candidate_ids_test.exs` only, with narrow evidenced migration/Store fixes if a contract fails.

- [x] Add a direct-call positive control, then start an owner MigrationRepo transaction that holds this exact exclusive transaction lock before updating an existing read assignment to revoked:

```sql
SELECT pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended($1,0));
UPDATE core.principal_capabilities SET revoked_at=CURRENT_TIMESTAMP
WHERE principal_id=$2 AND vault_id=$3;
```

`$1` is exactly `singularity:authorization:<canonical principal UUID>:<canonical owner UUID>`. The blocker reports its backend and hash. A separate Task on actual RequestRepo reports its backend before invoking the function. Reuse the reconciler test's message/release/drain pattern, but strengthen its poll to correlate the exact advisory lock, not any ungranted advisory lock:

```sql
SELECT EXISTS (
 SELECT FROM pg_locks AS waiting JOIN pg_locks AS held
   ON held.locktype=waiting.locktype AND held.database=waiting.database
  AND held.classid=waiting.classid AND held.objid=waiting.objid AND held.objsubid=waiting.objsubid
 WHERE waiting.pid=$1 AND held.pid=$2 AND waiting.locktype='advisory'
   AND waiting.mode='ShareLock' AND NOT waiting.granted
   AND held.mode='ExclusiveLock' AND held.granted
   AND waiting.classid=((pg_catalog.hashtextextended($3,0) >> 32) & 4294967295)::oid
   AND waiting.objid=(pg_catalog.hashtextextended($3,0) & 4294967295)::oid
   AND waiting.objsubid=1
) AND $2::integer=ANY(pg_catalog.pg_blocking_pids($1));
```

Poll with an absolute four-second deadline and observed state; no guessed sleeps. On direct-function calls, additionally confirm no content relation AccessShareLock has been acquired before the authority wait. Do not apply this assertion to the outer Store statement, which legitimately obtains its own relation locks at startup. Commit revocation, release through transaction completion, then require the fixed forbidden error rather than stale success. Run independently for capability, membership, and principal revocation. `after` always sends release and drains both owned Tasks.
- [x] Add the wrong-key negative control: hold the same-shaped key for a different actual principal/owner pair and prove the authorized reader completes successfully while that holder is still alive. It must not satisfy the exact-key wait predicate. A timeout alone is not proof of authorization serialization.
- [x] Add deterministic Store head/tag/deletion changes behind the same observed authorization wait. Outer Store statement snapshot exists before the inner guard blocks; the owner writer inserts a legitimate immutable replacement Note version and reconciles its projection, removes/adds canonical tag membership, or performs tombstone/restore in that transaction, then commits. The VOLATILE inner command sees the newly committed canonical state. Assert conservative intersection, never a mismatched returned version/fragment/digest/locator. For the controlled head replacement and tag removal, the waiting result is empty; after completion a fresh search yields the exact current expected row/tag visibility. For tombstone/restore, require absence or a coherent eligible identity, never an unauthorized stale source.
- [x] Compare complete immutable Note/Document/resource-version/fragment/source digest rows before versus after read operations. The deliberate writer is the only allowed canonical difference; snapshot immediately after its commit and confirm subsequent searches do not change it. Keep exact full ordered unchanged-set paging assertions in Task 4. No frozen cross-page snapshot promise or STABLE label is introduced.
- [x] Add uncapped/dedup direct-candidate controls using at least 66 eligible entries, with one entry matching several branches and matching rows beyond the Store's first page. Assert the full unique entry set before pagination; tags are canonical AND constraints, unknown/foreign tags return no IDs. Reuse existing stale-projection setup patterns for tombstoned, historical/conflict, pending/failed Document, wrong fragment ordinal, foreign owner, and wrong kind. Do not drop/disable schema constraints merely to invent a state persistence already forbids; construct admissible stale derived rows as existing Store tests do.
- [x] Parent runs the full owning module and Store/pagination contracts. Commit passing barrier/canonical controls as `test(storage): cover search candidate revocation and source races`. A failed fresh-authority assertion is a source defect, not a waived snapshot limitation.

Task 5's schema-boundary qualification follows the same representability rule
as the public-clearance correction: impossible composite source/fragment/kind
tuples and Document lifecycle states must fail their exact existing constraints
with unchanged canonical and projection snapshots. Do not fabricate them by
disabling persistence checks. Keep live exclusion for admissible stale rows and
valid foreign-owner/kind-filter controls. This refinement was found during
fixture source review, before executing the remaining Task 5 cases.

Qualified locally in `e85b3035826ed00226d182b0141f37b3f39aed77`.
Final owning test hash is `225beea1a7b19226e065cb6e029364e93f9648c3738e7a09ebf208ab80e42b99`.
Parent gate `27406` passed all 45 candidate and 26 Store/pagination contracts
(71 total, zero failures) in 178.4 seconds with no compiler warnings.
Independent nonauthor SPEC and separate QUALITY reviews passed on those
formatted bytes. This establishes Task 5 only; actual nested-index qualification
and the final regression/acceptance gates remain outstanding.

## Task 6: Capture actual Store call/return and qualify cold/warm nested indexes

**Files:** Observer helper, observer owning test, and existing plan test. Preserve observer setup/cleanup implementation and all prior lifecycle assertions.

The two-result observation amendment in the design supersedes the initial
single-result outer-NOTICE assumption and EXPLAIN replay. Diagnostics `1701`
and `88899` and primary PostgreSQL/locked Postgrex source establish that the
outer NOTICE can arrive only during later portal cleanup, and candidate
context contains ordered SPI/PL/pgSQL frames. Astra supplied architecture only;
parent records the amendment and obtains independent review before Sol repair.

- [x] Add `KnowledgeSearchPlanObserver.search_summary(Repo = repo, scope, query)` with closed result `{:ok, page, summary}` or `{:error, :observer_evidence_missing}`. `page` is the unchanged Store page, not raw rows. The closed summary keys are `:backend`, `:parameter_count`, `:candidate_calls`, `:nested_statements`, `:executed_nodes`, `:actual_rows`, `:actual_loops`, `:buffer_nodes`, `:indexes`, `:entry_rows_inspected`, and `:entry_access`; `:entry_access` contains only allowlisted node names and bounded counts. No raw SQL, parameters, plans/notices, errors/options, literals, or source text escapes the helper.
- [x] Write the owning actual-Store proof contract first. It uses `with_observer(database, fn repo -> search_summary(repo, scope, query) end)` on a small real-authorized canonical fixture, asserts its exact positive page plus closed metadata, then `clean?/1`, shared RequestRepo PID/dynamic state unchanged, caller flags empty, and SafeSQL trace pattern false. Add callback-exception and failed-search capture controls that verify trace flags/pattern/collector teardown even when no summary is returned. Use computed boolean log/event absence assertions, as in existing observer tests, so a failed assertion cannot print a raw diagnostic payload. Parent runs missing-export RED before helper implementation.
- [x] Move/extend the existing plan-test `capture_search/2` collector into this helper, not a general tracing library. Keep its refusal to replace existing tracing. Trace only the calling process and `{SafeSQL,:query,4}` with `:local`, now with an explicit return trace match specification:

```elixir
:erlang.trace_pattern({SafeSQL, :query, 4}, [{:_, [], [{:return_trace}]}], [:local])
:erlang.trace(caller, true, [:call, {:tracer, tracer}])
```

The isolated collector pushes each call's `{repo, binary_statement, params, options}` onto a private stack and pairs `{:trace, caller, :return_from, {SafeSQL,:query,4}, result}` with the last call. Calls are synchronous and the captured module does not recursively query; reject an unmatched return, nonempty final stack, duplicate search/drain, intervening SQL, or wrong Repo. Select exactly one actual outer statement by repo identity plus existing `WITH input AS (`/`scored AS MATERIALIZED` anchors, immediately followed by exactly one fixed drain; preceding Store context/settings calls cannot satisfy either identity. Require exactly 13 captured search parameters and zero drain parameters. SQL spelling is only a statement-selection control, not an invocation count: derive `candidate_calls` from uniquely matching ORIGINAL-call nested candidate notices, correlated with the candidate Function Scan's analyzed execution/loops in the original outer NOTICE collected by the immediate drain. Nonempty q requires exactly one candidate notice and one executed function invocation; reject duplicate notices or loops greater than one. Empty q requires both absent and yields zero. Never reconstruct parameters or use `pg_prepared_statements`.
- [x] Call the unchanged `KnowledgeSearchStore.search(repo, query)` inside unchanged `ScopedRepo.transact/3` on the passed named observer Repo. Immediately after success and before any other SQL, issue the fixed binary `SELECT pg_catalog.pg_backend_pid()` through unchanged SafeSQL with zero parameters and unnamed execution. Then use `trace_delivered/1`, its existing delivery barrier, and collect both paired results. Require the previously verified backend, original result connection ID, drain result connection ID, and drain's returned PID to agree. Candidate evidence comes only from the original result; original outer evidence comes only from the immediate drain. Reject missing/duplicate/wrong-channel evidence. Preserve unconditional removal of only owned flags/pattern and normal monitor-confirmed collector termination; never discard consumed events before the capture has been summarized. Sanitization encloses all parse/capture errors, and no ExUnit match/raise inside the helper may print raw terms.
- [x] In helper-local memory, retrieve the deployed function's `pg_proc` identity/header/config and source. Read only the fixed tested migration path, parse with `Code.string_to_quoted/1` without evaluation, and use `Macro.prewalk/3` to collect `{:execute, _metadata, [sql]}` nodes whose argument is a literal binary and trimmed prefix is `CREATE FUNCTION content.search_candidate_ids(`. Require exactly one such compiled literal and exactly two `$function$` delimiters. Split that literal, compare its function body to deployed `prosrc` using only edge trimming, and require one fixed `/* singularity:search_candidate_ids:v1 */` marker. Parsing the compiled literal handles Elixir heredoc indentation and escaping; raw file slicing or marker-only/arbitrary SQL normalization is not equal source proof. Keep the migration CREATE statement a literal heredoc without interpolation so this check is deterministic. From the ACTUAL paired SafeSQL result messages, accept NOTICE duration JSON only when `:where` names the exact `search_candidate_ids(text,text,uuid[])` PL/pgSQL function at RETURN QUERY and `Query Text` is the uniquely marked RETURN QUERY SELECT contained in the deployed source. Ignore unrelated authorization/setup/catalog plans; reject zero/ambiguous candidate plans for nonempty q. Use the existing JSON parser and bounded-node traversal privately; do not parse an exception string or emit Query Text.
- [x] Parse candidate context as the exact SPI `SQL statement "` frame containing the selected Query Text bytes (edge-trimmed equality to validated migration SQL), then one complete exact PL/pgSQL function frame at RETURN QUERY with bounded positive line number. Permit only end-of-context or the exact following `unnamed portal with parameters: ` prefix; its suffix remains opaque and private. Do not search that suffix for proof, normalize interior SQL, or invent escaping. Require the drained original outer Query Text to match the captured original statement using edge trimming only. Reject malformed/misordered contexts and candidate notices in the drain or outer notices in the original result.
- [x] The candidate plan's analyzed nodes must contain positive `Actual Loops`; accumulate named indexes only from executed nodes. Validate row/loop/buffer types and bounds and known node names before arithmetic or closed-summary construction. Remove all EXPLAIN replay. The original outer plan from the immediate drain must have root rows equal to the original result row count, positive analyzed loops/buffers, and the required candidate Function Scan count/loop proof. `entry_rows_inspected` sums `(Actual Rows + Rows Removed by Filter) * Actual Loops` for search_entries access nodes in both ORIGINAL candidate and ORIGINAL outer plans, not a narrowed relation or second execution. Enforce 1 MiB per selected record before JSON parsing, at most 4,096 plan nodes, depth 64, and existing `0..1_000_000_000` numeric bounds; overflow, unknown types/nodes, and ceiling breaches fail rather than truncate.
- [x] Before repair implementation, add failing owning contracts for successive same-backend calls and synthetic envelope rejections: missing/duplicate/wrong-channel plans, wrong drain backend/PID, intervening SQL, malformed/misordered context, fake frames only in parameter context, malformed/negative/oversized metrics, and record/node/depth ceilings. A bounded test-support-only validator may expose only closed metadata or the fixed error to synthetic tests; it must not expose raw capture data or become production API. Preserve every existing actual positive/empty/failed-search/callback/conflicting-pattern, cleanup, and privacy assertion. Remove all temporary diagnostic probes and reproduce the original lifecycle/default function bytes before qualification. Parent runs the added pure RED contracts before validator changes; synthetic tests never replace actual Store proof.
- [x] Preserve the original `executed_plan/2` exact transaction-local settings assertion by moving its fixed read-only query into `search_summary/3`, after capture/validation and trace teardown but before that same scoped transaction exits. Require exactly `[["singularity_web", "on", "on", "5s", "0.3"]]` for current user, row security, sequential scans, timeout, and trigram threshold. Return the same fixed missing-evidence error on mismatch; do not expose settings, add summary keys, mutate settings, nest scopes, interpose before the drain, or use this query as execution-plan proof. This is relocation of an existing mandatory assertion, not a new product behavior. Parent revalidates the helper's pure/real gates and independent review before counting the rewritten plan contracts.
- [x] Rewrite plan `executed_plan/2` to call the fixed observer helper, preserving the four named contracts and the exact fixture generator: 8,192 canonical rows, actual builder in 512-ID transactions, final ANALYZE, same title/body distribution and query strings. Keep its fixed observed relation-lock timeout test on ordinary uninstrumented RequestRepo, fixed five seconds overriding the test's 30-second starting local setting, clean rollback/settings, and successful retry. Only its positive/retry plan controls use the observer; do not preload observation into the timeout reader.
- [x] In each existing selective contract, use a fresh `with_observer/2` session and call `search_summary/3` seven times within that SAME callback/backend, each in its own scoped transaction. Assert the backend is identical across all seven calls; the first is cold and calls 6/7 are beyond five-call warmup. Only each fixed drain may follow its search; no extra search or EXPLAIN replay may alter the sequence. Every call retains one exact matching item, positive rank, outer `actual_rows == 1`, positive analyzed buffer/loop evidence, one candidate invocation, and the required executed index (`search_entries_fts` or `search_entries_title_trigram`). Do not change planner costs, thresholds, plan_cache_mode, RLS, or enable_seqscan. No Function Scan-only/unused node/owner query/index statistics satisfies these assertions.

The existing assertion shape becomes closed-summary evidence, not a weaker index condition:

```elixir
assert summary.parameter_count == 13
assert summary.candidate_calls == 1
assert summary.actual_rows == 1
assert summary.actual_loops > 0
assert summary.buffer_nodes > 0
assert @index in summary.indexes
```

- [x] For both `"o"` and `"ol"`, keep 20 returned items, a cursor, ranks at least 1,000,000, outer actual rows 21, and scanned search_entries work at least `div(8_192 * 9,10)`. Require nonempty closed entry-access evidence. Report only bounded counters/known node/index names; no raw plan. Keep empty-q positive rank-zero and zero-candidate-call control. Do not lower the 8,192 fixture or short-scan threshold to make tests pass. Do not introduce GIN maintenance unless the unchanged fixture measurement proves it necessary; any normal maintenance must apply uniformly to all three indexes and be recorded without a causal claim about the earlier zero-page cleanup.
- [x] Parent runs the observer owning module and all four original plan contracts. Expected GREEN requires both named selective indexes on cold and warm actual-call evidence, the honest short scan, and unchanged sanitized five-second timeout/retry. Missing notices or observation overhead causing deadline failure is FAIL, never an assertion waiver. Independent review must inspect capture ownership and diagnostic confinement. Commit the bounded helper/test changes as `test(storage): qualify actual nested cold and warm search plans` after green.

Parent commands:

```bash
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_observer_test.exs --seed 215378
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_observer_test.exs --seed 215378
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_test.exs --seed 215378
```

## Task 7: Qualify fresh and historical migration identity without data rewrites

**Files:** `search_candidate_migration_test.exs`; no released migration/global helper edits.

This independent compatibility gate uses a separate owning test module so the
parent can implement it alongside Task 5's candidate-contract additions and
Task 6's observer work without shared-file edits. The proof obligations below
are unchanged; all database/build execution remains parent-serialized. Include
this module in both Task 8's focused unit command (pure forward-only contract)
and its migration integration batch.

- [x] On the ordinary fully migrated disposable test database, assert the full Task 2 function catalog and exact ACL arrays. Compare the pre-repair definitions/flags/grants for the existing three content GIN indexes, search_entries FORCE/ENABLE RLS and owner/web policies, runtime role attributes/memberships, and authorization function source/owner/config to unchanged baseline expectations. Include web SELECT and runtime INSERT/UPDATE/DELETE denials. Assert no new function with an internal/alternate candidate signature exists.
- [x] Add a historical integration case using `MigrationTestEnvironment.with_database(20_261_009_000_400, callback)`, the verified latest existing migration `20261009000400_document_projection_worker.exs`. The callback builds canonical Notes/ready Documents and their projections before the new function exists, records exact canonical/projection row bytes plus existing security/index catalog state, then runs only the new forward migration to `20_261_010_000_000` using a locally owned MigrationRepo PID, the existing compiler-options restore pattern, and `log: false`. If the actual predecessor changes before execution, report the handoff mismatch and update this exact ceiling rather than silently migrating a different fixture.
- [x] Historical RED asserts missing function before upgrade; after upgrade, real-web scoped direct candidates and actual Store nonempty search must return the same full immutable identities/ranks/locators as the fresh path. Assert byte-identical preexisting rows and unchanged role/RLS/index/auth definitions, exact new catalog contract, and no backfill/event/schema/index rewrite. Stop only the locally started migration Repo and let MigrationTestEnvironment restore its own repos/config/database/root in `after`. Do not start the observer inside this migration fixture; its independent allocated target guards remain unchanged.
- [x] Add the pure fixed forward-only downgrade contract using `apply(Singularity.Storage.Migrations.CreateGuardedSearchCandidates,:down,[])`; require the exact error string. Parent runs new owning tests plus existing migration/roles/schema gates, and commits passing qualification as `test(storage): verify guarded search migration compatibility`.

Qualified locally: cold-backend initialization repair
`2acbfa07055c59e95882730f7d0be97aedd1b32b` and migration qualification
`193f1c38579944278b60cb7c9bf26e549ce9b220`. Final-byte pure gate `43640`
passed one executed test; combined `13321` passed both owning integration
contracts; prescribed migration/role/schema/RLS regression `84484` passed
109 integration tests (117 total, eight excluded) in 434.5 seconds.
Independent nonauthor SPEC and separate QUALITY reviews passed for both
migration and owning test. These results do not qualify Task 6 or full Phase 3.

## Task 8: Regression gates, independent reviews, cleanup, and evidence handoff

**Files:** Parent-owned plans/verification only; source fixes require a preceding failing focused contract.

The combined runtime gate `92723` exposed a test wait-contract defect at
`search_rebuild_test.exs:521` (frozen pre-repair SHA
`f921060241616536a55f7acbf2519fccaebbdca970a0a3146f975611b02bcb8d`).
Its five-second receive covered enumeration plus 100 serial, freshly authorized
resource transactions, although the asserted event occurs only after the
hundredth scope has returned. Recorded callback/resource messages show progress.
No production rebuild deadline or missing callback defect has been established.

The bounded compatibility repair owns only that test: before the unchanged
five-second between-pages receive, consume the existing first 100 resource
progress markers in exact canonical order, with a bounded five-second wait per
progress step. Match the next tagged ID then assert equality, so selective
receive cannot hide reordering or duplicates. Require positive integer, unique
transaction IDs and no extra resource marker. Do not consume or requeue content
callback/page messages; preserve all 101 post-revocation callback assertions,
no-extra/no-final-resource/no-page-two checks, 100 projected rows, unchanged
canonical snapshot, fixture size, existing test deadline, and owned Task cleanup.
No sleep, timeout increase, reduced fixture, fake authorization, or production
change belongs in this repair. Parent runs the owning module and combined
regression again, obtains independent review, and records the original failure.

- [x] Parent formats only changed source/test files, then runs static compilation/xref and all focused unit/property/architecture contracts. No architecture hash changes are expected from this Store/migration boundary:

```bash
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix format --check-formatted
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix compile --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix xref graph --format cycles --fail-above 0
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_cursor_test.exs apps/singularity_storage/test/singularity/storage/postgres/search_candidate_ids_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_observer_test.exs apps/singularity_retrieval/test/singularity/retrieval/knowledge_search_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_search_api_test.exs apps/singularity_runtime/test/singularity/runtime/search_rebuild_test.exs apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs apps/singularity_storage/test/singularity/storage/postgres/search_candidate_migration_test.exs --seed 215378
```

- [x] Parent runs these serial owning integration batches; retain all original assertions and state exact executed/excluded counts:

```bash
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/search_candidate_ids_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_store_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_pagination_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_observer_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_test.exs --seed 215378
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/migrations_test.exs apps/singularity_storage/test/singularity/storage/knowledge_migration_test.exs apps/singularity_storage/test/singularity/storage/task12_migration_downgrade_test.exs apps/singularity_storage/test/singularity/storage/roles_test.exs apps/singularity_storage/test/singularity/storage/search_extension_bootstrap_test.exs apps/singularity_storage/test/singularity/storage/search_projection_schema_test.exs apps/singularity_storage/test/singularity/storage/knowledge_rls_test.exs apps/singularity_storage/test/singularity/storage/note_rls_test.exs apps/singularity_storage/test/singularity/storage/postgres/search_candidate_migration_test.exs --seed 215378
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/note_projection_reconciler_test.exs apps/singularity_storage/test/singularity/storage/postgres/search_projection_reconciler_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_search_store_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_search_api_test.exs apps/singularity_runtime/test/singularity/runtime/search_rebuild_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_search_privacy_test.exs apps/singularity_runtime/test/singularity/runtime/job_dispatcher_note_projection_test.exs --seed 215378
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/unified_search_restore_test.exs apps/singularity_storage/test/singularity/storage/integrity_audit_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs --seed 215378
devenv shell -- bash .devenv/phase3-restore.sh
```

The final restore command is the parent's established private wrapper for the complete `mix singularity.test.restore` V1/V2 oracle, not a replacement assertion subset. New function comes from migrations, never backup export. Runtime privacy runs without observer/trace instrumentation and retains all six canaries and its timeout/retry/audit/rebuild-fault assertions. Verify its protected SHA before and after.

- [x] Obtain independent SPEC review first against the complete design and migration/Store/capture/fixture diff; resolve findings with focused regressions and parent revalidation. Then obtain a separate independent QUALITY review covering ACL/security, concurrency/snapshot semantics, trace ownership/cleanup/privacy, strict real-login proof, deterministic fixture size, and maintainability. Reviewers must not be authors of the reviewed code. Do not claim either review from implementation self-review.
- [x] Parent verifies all commands terminal, no owned worker/collector/Repo remains, no owned auto_explain defaults or loaded ordinary session leakage, all allocated source/target databases and recorded storage roots removed, owned PostgreSQL stopped, protected worktrees unchanged, local links valid, and `git diff --check` clean. Never use broad destructive cleanup, stop another owner's service, reset all settings, or stage unrelated files.
- [x] Parent records actual commands/results/source/test hashes/commits, cold and warm same-backend counters/named executed indexes, short-scan totals, 5-second retry result, migration/role/restore gates, independent review identities, cumulative repair counters, and zero Vault work. Preserve every historical failed checkpoint; append the qualified repair result rather than recasting the original tests as passed. Mark remaining README/Phase 3 gates accurately, especially E2E **NOT RUN**; this repair's scoped green is not phase/release/production acceptance.
- [x] Parent makes a final explicit-path local documentation commit `docs: record guarded search index qualification`, then returns to the remaining [Phase 3 plan](2026-10-09-singularity-v0.2-phase-3-unified-lexical-search.md). No push/release/deployment or next-phase advancement occurs while a required acceptance gate is unmet.

## Self-review and unrun proof obligations

Plan self-review maps authority/input/ACL/path/null behavior to Tasks 1–3; narrow Store/empty/rank/13-binding/cursor/deadline preservation to Task 4; post-lock VOLATILE authorization and conservative canonical/tag/source/dedup completeness to Task 5; real-call nested source/context/backend/index/buffer proof, cold/warm plans and honest short scans to Task 6; fresh/historical migration byte/security invariants to Task 7; privacy, restore, architecture, independent reviews and cleanup to Task 8. The observer's already-qualified lifecycle is reused rather than redesigned. Fixture authority is explicit and created once, not granted per search. No product decision or implementation alternative remains open.

All repair checks are **NOT RUN** at plan authorship. Remaining technical risks are actual PL/pgSQL notice source/context formatting, captured nested-plan delivery, unforced cold/warm cost choices, instrumentation within the existing deadline, and deterministic post-lock snapshot/concurrency evidence. Those are executable obligations, not reasons to waive assertions or expand scope. Ordinary implementation failures enter bounded diagnosis/repair; an evidenced architecture impasse returns to the coordinator with counters and exact failure evidence.
