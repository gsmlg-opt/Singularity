# GenericWorker telemetry compatibility implementation plan

> **For agentic workers:** use subagent-driven-development with independent spec
> then quality reviews. User explicitly requests Astra. Parent owns the single
> Mix slot and all commits; agents must not run Mix or commit without handoff.

**Goal:** restore bounded retry/failure derivation for Oban's canonical worker
name without changing any other telemetry or privacy contract.

**Architecture:** exact closed identity-list addition in the existing application
telemetry boundary. No additional process, dependency or normalization layer.

**Tech stack:** Elixir, ExUnit, installed Oban 2.24, telemetry, existing devenv.

Read the companion design completely. Work only in the existing project-local
Phase 2 worktree on `codex/v0.2-phase-2-import-extraction`, base `caf80fd4`.
Do not modify or stage existing dirty C1-C5 tests or unrelated work.

## Task 1: focused regression, RED before production change

Create `apps/singularity_runtime/test/singularity/runtime/generic_worker_telemetry_test.exs`
with this implementation (format this new file only):

```elixir
defmodule Singularity.Runtime.Observability.GenericWorkerTelemetryTest do
  use ExUnit.Case, async: true

  alias Singularity.Runtime.Observability.Telemetry
  alias Singularity.Storage.Jobs.GenericWorker

  @events [[:singularity, :job, :retry], [:singularity, :job, :failure]]
  @secret "CANARY_GENERIC_WORKER_TELEMETRY_CONTENT"

  setup do
    id = {__MODULE__, make_ref()}
    on_exit(fn -> :telemetry.detach(id) end)
    assert :ok = :telemetry.attach_many(id, @events, &__MODULE__.forward/4, self())
    :ok
  end

  def forward(event, measurements, metadata, owner) do
    if self() == owner, do: send(owner, {:derived, event, measurements, metadata})
    :ok
  end

  for representation <- [:canonical, :module, :legacy],
      placement <- [:top_level, :nested],
      outcome <- [:retry, :final_exception, :cancelled, :discard] do
    @tag representation: representation, placement: placement, outcome: outcome
    test "#{representation} #{placement} #{outcome} emits only bounded fields", context do
      worker = worker(context.representation)
      attempt = if context.outcome == :final_exception, do: 3, else: 2
      fields = %{worker: worker, queue: "asset_verify", attempt: attempt, max_attempts: 3}
      metadata = if context.placement == :nested, do: %{job: fields}, else: fields

      metadata = Map.merge(metadata, %{
        args: %{"payload" => @secret}, reason: RuntimeError.exception(@secret),
        stacktrace: [@secret], plaintext: @secret
      })

      {source, metadata} =
        if context.outcome in [:cancelled, :discard],
          do: {[:oban, :job, :stop], Map.put(metadata, :state, context.outcome)},
          else: {[:oban, :job, :exception], metadata}

      expected_event = if context.outcome == :retry, do: [:singularity, :job, :retry],
        else: [:singularity, :job, :failure]

      assert :ok = Telemetry.handle_event(source, %{duration: 12, unsafe: @secret}, metadata, nil)
      assert_receive {:derived, ^expected_event, measurements, safe}
      assert measurements == %{count: 1}
      assert safe == %{attempt: attempt, max_attempts: 3, queue: :asset_verify, worker: :generic_worker}
      refute_receive {:derived, _, _, _}, 0
    end
  end

  test "unknown queue remains bounded and top-level fields retain precedence" do
    metadata = %{worker: worker(:canonical), queue: @secret, attempt: 2, max_attempts: 3,
      job: %{worker: "Other.Worker", queue: "asset_verify", attempt: 3, max_attempts: 9}}
    assert :ok = Telemetry.handle_event([:oban, :job, :exception], %{}, metadata, nil)
    assert_receive {:derived, [:singularity, :job, :retry], measurements, safe}
    assert measurements == %{count: 1}
    assert safe == %{attempt: 2, max_attempts: 3, queue: :unknown, worker: :generic_worker}
    refute_receive {:derived, _, _, _}, 0
  end

  test "unrelated and lookalike names are rejected, including top-level override" do
    for name <- [nil, "Other.Worker", "Singularity.Storage.Jobs.GenericWorkerExtra",
      "Elixir.Elixir.Singularity.Storage.Jobs.GenericWorker", " GenericWorker",
      "singularity.storage.jobs.GenericWorker"] do
      metadata = %{worker: name, queue: "asset_verify", attempt: 2, max_attempts: 3}
      assert :ok = Telemetry.handle_event([:oban, :job, :exception], %{}, metadata, nil)
      refute_receive {:derived, _, _, _}, 0
    end

    metadata = %{worker: "Other.Worker", attempt: 2, max_attempts: 3,
      job: %{worker: worker(:canonical), attempt: 2, max_attempts: 3}}
    assert :ok = Telemetry.handle_event([:oban, :job, :exception], %{}, metadata, nil)
    refute_receive {:derived, _, _, _}, 0
  end

  test "invalid attempts and nonterminal stop outcomes remain ignored" do
    for {attempt, maximum} <- [{nil, 3}, {0, 3}, {-1, 3}, {"2", 3}, {2, nil}, {2, 0}, {2, "3"}] do
      metadata = %{worker: worker(:canonical), attempt: attempt, max_attempts: maximum}
      assert :ok = Telemetry.handle_event([:oban, :job, :exception], %{}, metadata, nil)
      refute_receive {:derived, _, _, _}, 0
    end

    for state <- [:success, :snoozed, :discarded] do
      metadata = %{worker: worker(:canonical), attempt: 2, max_attempts: 3, state: state}
      assert :ok = Telemetry.handle_event([:oban, :job, :stop], %{}, metadata, nil)
      refute_receive {:derived, _, _, _}, 0
    end
  end

  defp worker(:canonical), do: Oban.Worker.to_string(GenericWorker)
  defp worker(:module), do: GenericWorker
  defp worker(:legacy), do: "Elixir.Singularity.Storage.Jobs.GenericWorker"
end
```

Run from worktree root:

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/generic_worker_telemetry_test.exs --seed 1208
```

Expected: 27 tests, nine canonical positive cases fail because no derived event;
16 legacy/module positives and two rejection tests pass. Confirm actual output,
not just exit2, and Telemetry's unchanged hash before permitting Task 2.
No integration/database proof is claimed from this unit command.

## Task 2: exact compatibility repair and GREEN

Only replace the final expression in `generic_worker?/1`:

```elixir
    worker in [
      Singularity.Storage.Jobs.GenericWorker,
      @generic_worker,
      "Singularity.Storage.Jobs.GenericWorker"
    ]
```

Rerun the exact Task 1 command; require all 27 pass. Check the production diff
contains only this list expansion. Preserve original source precedence and all
other bytes, including queue mapping and other operation/Vault behavior.
Independent Astra specification review then quality review must clear before
local compatibility acceptance. Parent may commit only the two source/test files
and these design/plan docs after exact verification; pending C tests remain dirty.

## Task 3: real Executor and mandatory C6 regressions

Parent serializes commands; do not start multiple Mix runs. Keep C5 source hash
`68537ed710bff9559c70ac498f482b56e7aab2d59c01811e56b8ec27e3bfeb3f` unchanged.

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs --seed 1208
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs --seed 1208
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_unlock_resume_test.exs apps/singularity_runtime/test/singularity/runtime/job_dispatcher_asset_events_test.exs apps/singularity_runtime/test/singularity/runtime/application_test.exs --seed 1208
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_unlock_resume_test.exs apps/singularity_runtime/test/singularity/runtime/job_dispatcher_asset_events_test.exs apps/singularity_runtime/test/singularity/runtime/application_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs --seed 1208
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix xref graph --format cycles --fail-above 0
git diff --check
sha256sum apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs
```

Record terminal status/counts and exact alias database/root per run. After exit,
query the borrowed PostgreSQL catalog for the exact printed database (count0)
and independently verify the exact printed storage root absent. Never stop or
delete borrowed services or unrelated resources. `unbuffer` is unavailable;
retain these established commands without installing tools.

Require fresh independent spec then quality review of current C5/detector and
the complete dependent C block before its eventual source commit. No assertion
weakening, test reclassification, E2E, production activation, merge, push,
release or Phase 2 acceptance is authorized here. A required unrelated failure
stops its affected gate; investigate and define separate scope before repair.
