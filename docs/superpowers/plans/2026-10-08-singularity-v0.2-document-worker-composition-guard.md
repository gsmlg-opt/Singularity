# Document worker composition guard implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the existing architecture contract only for the exact approved Runtime Document worker additions, without changing any legacy baseline hash or assertion.

**Architecture:** Seven literal insertion blocks are checked for uniqueness and their exact surrounding context before removal from the legacy-byte comparison. The original frozen files and hashes remain authoritative. Negative contracts reject mutation, removal, duplication and relocation of every new block.

**Tech Stack:** Elixir, ExUnit, existing AST and SHA-256 architecture guards.

## Scope and dependencies

Modify only `apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs`. This is the parent-owned architecture allowance authorized by worker-bridge section 9, alongside Runtime step A. No production file, historical assertion or baseline hash changes here. Runtime additions must match A3 in `2026-10-08-singularity-v0.2-document-extraction-runtime.md` exactly. Real source/claim and outcome/recovery integration in steps B/C remains mandatory; this contract proves composition bytes, not custody or worker privileges.

## Task 1: Exact additive contract

- [x] Apply the complete patch below before Runtime production GO. It changes only the precise AST allowlist and literal insertion allowances, and adds negative coverage; no historical assertion is removed.

```diff
*** Begin Patch
*** Update File: apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs
@@
   @application "apps/singularity_runtime/lib/singularity/runtime/application.ex"
+  @dispatcher "apps/singularity_runtime/lib/singularity/runtime/job_dispatcher.ex"
@@
-    @application => [:Documents],
+    @application => [:Documents, :DocumentWorkerRepository, :document_worker, :document_extractors],
+    @dispatcher => [:Documents, :document_source_lease, "document_extract"],
*** End Patch
```

Insert the following full test immediately before `test "documentation attributes remain outside the registration scan"`, leaving that test intact:

```elixir
  test "every approved worker block rejects mutation, removal, duplication and relocation" do
    for {path, preceding, addition, following, destination} <- worker_additions() do
      source = read_source(path)
      assert_runtime_baseline!(path, source, @runtime_baselines[path])
      assert [before, rest] = String.split(source, addition)

      for replacement <- ["", addition <> addition, addition <> "  # unapproved worker change\n"] do
        changed = before <> replacement <> rest

        assert_raise ExUnit.AssertionError, fn ->
          assert_runtime_baseline!(path, changed, @runtime_baselines[path])
        end
      end

      assert [_, _] = String.split(source, preceding <> addition <> following)
      relocated = String.replace(before <> rest, destination, destination <> addition, global: false)
      refute relocated == source
      assert_document_registration!(path, relocated)

      assert_raise ExUnit.AssertionError, fn ->
        assert_runtime_baseline!(path, relocated, @runtime_baselines[path])
      end
    end
  end
```

Insert this exact reduction immediately before the existing `assert_digest!(path, legacy, expected)` line in `assert_runtime_baseline!/3`:

```elixir
    legacy =
      Enum.reduce(worker_additions(), legacy, fn
        {^path, preceding, addition, following, _destination}, remaining ->
          strip_in_context!(remaining, preceding, addition, following)

        _other, remaining ->
          remaining
      end)
```

Insert this complete private function immediately before `api_additions/0` (leave its existing comment attached to it):

```elixir
  defp worker_additions do
    [
      {@application, "  use Application\n\n",
       "  alias Singularity.Ingest.Documents.{Markdown, PDF, Text}\n",
       "  alias Singularity.Runtime.AuthorizationDependencies\n",
       "  alias Singularity.Runtime.BackupKeyLease\n"},
      {@application, "  alias Singularity.Storage.Postgres.BackupRepository\n",
       "  alias Singularity.Storage.Postgres.DocumentWorkerRepository\n",
       "  alias Singularity.Storage.Postgres.NoteProjectionReconciler\n",
       "  alias Singularity.Runtime.BackupKeyLease\n"},
      {@application,
       "        {LocalDestination,\n         %{backup_root: Application.fetch_env!(:singularity_storage, :backup_root)}},\n",
       "      document_worker: DocumentWorkerRepository,\n" <>
         "      document_extractors: %{\n" <>
         "        \"text/plain\" => {Text, \"plain_text\", 1},\n" <>
         "        \"text/markdown\" => {Markdown, \"markdown\", 1},\n" <>
         "        \"application/pdf\" => {PDF, \"poppler_text\", 1}\n" <>
         "      },\n",
       "      exporter: Exporter,\n", "      assets: AssetRepository,\n"},
      {@dispatcher, "  alias Singularity.Runtime.BackupVault\n",
       "  alias Singularity.Runtime.Documents.Extract\n" <>
         "  alias Singularity.Runtime.DownloadLease\n",
       "  alias Singularity.Runtime.KeyCustodian\n",
       "  alias Singularity.Runtime.AssetEvents\n"},
      {@dispatcher, "      custodian: custody_adapter(dependencies.authorization.custodian),\n",
       "      document_source_lease: DownloadLease,\n", "      job_progress: Progress,\n",
       "      job_progress: Progress,\n"},
      {@dispatcher,
       "  def handle(context, %{job_type: \"note_projection\"} = envelope),\n    do: Projection.run(context, envelope)\n\n",
       "  def handle(context, %{job_type: \"document_extract\"} = envelope),\n    do: Extract.run(context, envelope)\n\n",
       "  def handle(_context, _envelope), do: {:error, Error.new(:job_failed)}\n",
       "  @impl true\n  def handle(context, %{job_type: \"asset_verify\"} = envelope),\n    do: run_asset_job(context, envelope, Verify)\n\n"},
      {@dispatcher, "  def wake_waiting(_command), do: {:error, Error.new(:invalid)}\n\n",
       "  @impl true\n  def handle_failure(\n" <>
         "        context,\n" <>
         "        %JobEnvelope{job_type: \"document_extract\"} = envelope,\n" <>
         "        %Error{} = failure,\n" <>
         "        attempt\n" <>
         "      )\n" <>
         "      when is_map(context),\n" <>
         "      do: Extract.record_exhaustion(context, envelope, failure, attempt)\n\n",
       "  @impl true\n  def handle_failure(\n        context,\n        %JobEnvelope{job_type: \"asset_metadata\"} = envelope,\n",
       "  @impl true\n  def handle(context, %{job_type: \"asset_verify\"} = envelope),\n    do: run_asset_job(context, envelope, Verify)\n\n"}
    ]
  end
```

- [x] Run the exact focused RED command while production wiring remains absent:

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix format apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs --seed 1208
```

Expected: assertion failures because approved worker additions are absent; no syntax errors. Record actual count, exit status and causes. No E2E. Shared Mix slot must be released by Runtime worker first.

Actual RED: exit 2, seed 1208, 15 executed and 5 expected assertion failures,
no exclusions. The failures identify missing worker AST registrations/literal
insertions; all historical baseline hashes and assertions remain intact.

## Task 2: Verify against exact Runtime wiring

- [x] Main personally reviews the full worker plan and cleanup correction, then grants worker production GO. Parent does not edit worker-owned production files.
- [x] After worker GREEN and release of the Mix slot, rerun the exact focused architecture command above. Expected: 15 tests, zero failures and no exclusions, including all original negative guards and seven new block mutation/removal/duplication/relocation checks.
- [x] Run scoped formatting and `git diff --check`; inspect that every original baseline hash and assertion remains unchanged. Independent spec review then quality review covers this extension together with Runtime A. Record results in `docs/verification/2026-10-08-document-extraction-runtime.md`; only then consider a local commit. No push, merge, tag, release or deployment.

This plan changes no Vault file, policy, keys, capabilities, database schema, worker role, generic retry/wake behavior, backup format or browser route. Test doubles do not establish live source verification. Task 12 and Phase 2 remain unaccepted until required B/C and full gates pass.

Actual GREEN: worker and main independently ran the architecture contract,
seed1208,15 executed,0 failures,no exclusions. Main's combined scoped run also
executed65 Runtime unit contracts successfully (17 integration exclusions remain
unverified). Focused formatting passed; independent main xref found no cycles.
Independent spec review returned SPEC_COMPLIANT for A, including this guard;
independent quality review returned QUALITY_APPROVED with zero findings. No acceptance or external publication follows
from these bounded results.
