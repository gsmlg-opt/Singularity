# Document Worker Adapter Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the approved internal typed Document worker adapter and active-attempt exhaustion recorder under actual WorkerRepo privileges.

**Architecture:** The adapter validates a durable Document envelope, uses the trusted WorkerScope transaction closure, and calls only the four accepted SQL entrypoints. Private closed decoders return source maps, attempt maps, and receipts. Exhaustion shares completion validation and the fixed fail SQL path, with only the recognized lifecycle SQL constraint converted to unchanged.

**Tech Stack:** Elixir, Ecto/Postgrex, PostgreSQL 17, ExUnit, devenv.

---

## Scope and execution boundary

Execute only in `/home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-2-import-extraction`, branch `codex/v0.2-phase-2-import-extraction`, baseline `78a8634527059b79014247b7bcf11567006cf4a7`.
The accepted SQL implementation is `b8db6d562d072c2de5dc77635d29159080d1401a`.
The parent owns existing documentation; this plan and the adapter/test files are assigned to the implementation worker. Preserve other workers' edits.

Files:

- Create `apps/singularity_storage/lib/singularity/storage/postgres/document_worker_repository.ex`: the complete module below, no public repository behaviour.
- Modify `apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs`: additive adapter integration contracts already present; preserve all 32 accepted SQL tests and fixture authority boundaries.
- Create this plan. No migrations, grants, Runtime wiring, public interfaces, GenericWorker changes, custody changes, Vault work, E2E, commits, pushes, or releases.

The approved governing specification is `docs/superpowers/specs/2026-10-08-singularity-v0.2-phase-2-worker-bridge-proposal.md`, sections 3–7 and 10. The trusted closure is an application boundary; arbitrary function provenance is not a credential. Validate its supplied repo and real transaction before querying. Do not add decoder test seams or substitute administrative repositories for verified calls.

## Task 1: Preserve and extend adapter RED evidence

- [x] Inspect `git status --short`, `git diff --stat`, branch and HEAD. Confirm only assigned files are edited by this worker.
- [x] Retain the existing new tests named `adapter describes the durable job through actual WorkerScope with a closed source map`, `adapter claims once and returns only a typed ready receipt on completion and replay`, and `adapter rejects absent or substituted context and nested transactions before mutation`. Their complete executable bodies and real outbox fixture `worker_envelope/1` are in the assigned test file.
- [x] Retain the complete additional adapter tests in that file for completion identity/metadata, closed source/attempt input, rollback cleanup, unsupported receipt, pending/active/expired exhaustion, recovery/retry/restore successors, and live authority failure/privacy.
- [x] Run the exact scoped integration command:

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs
```

Initial RED already observed: seed `853983`, exit 2, 35 tests/3 failures, all three new tests fail at missing `DocumentWorkerRepository.describe/2`; original 32 SQL tests pass. This is agreed feature absence, not a repair round. Record expanded RED separately. No production module until parent self-review and GO.

## Task 2: Implement the complete internal adapter

- [x] After the parent reviews this full plan against the approved specification and gives GO, create the exact module below with `apply_patch`.

```elixir
defmodule Singularity.Storage.Postgres.DocumentWorkerRepository do
  @moduledoc false

  alias Singularity.Core.{
    DocumentCompletion,
    Error,
    JobEnvelope,
    KnowledgeValidation,
    SourceLocator
  }

  alias Singularity.Storage.{SafeSQL, WorkerRepo}
  alias Singularity.Storage.Jobs.EnvelopeCodec
  alias Singularity.Storage.Postgres.KnowledgeError

  @max_bigint 9_223_372_036_854_775_807
  @media_types ["application/pdf", "text/markdown", "text/plain"]
  @receipt_keys ~w(resource_id resource_version_id job_id generation state)a
  @attempt_keys @receipt_keys ++ ~w(adapter_name format_version started_at deadline_at)a
  @source_keys @attempt_keys ++
                 ~w(object_id object_generation source_digest source_byte_size media_type)a
  @describe_columns ~w(kind resource_id resource_version_id job_id state generation object_id object_generation source_digest source_byte_size media_type adapter_name format_version started_at deadline_at)
  @claim_columns ~w(resource_id resource_version_id job_id generation state adapter_name format_version started_at deadline_at)
  @receipt_columns ~w(resource_id resource_version_id job_id generation state)

  @type receipt :: %{
          resource_id: String.t(),
          resource_version_id: String.t(),
          job_id: String.t(),
          generation: pos_integer(),
          state: :ready | :failed | :unsupported
        }
  @type attempt :: %{
          resource_id: String.t(),
          resource_version_id: String.t(),
          job_id: String.t(),
          generation: pos_integer(),
          state: :extracting,
          adapter_name: String.t(),
          format_version: pos_integer(),
          started_at: DateTime.t(),
          deadline_at: DateTime.t()
        }
  @type source :: %{
          resource_id: String.t(),
          resource_version_id: String.t(),
          job_id: String.t(),
          generation: non_neg_integer(),
          state: :pending | :extracting,
          object_id: String.t(),
          object_generation: pos_integer(),
          source_digest: binary(),
          source_byte_size: non_neg_integer(),
          media_type: String.t(),
          adapter_name: String.t() | nil,
          format_version: pos_integer() | nil,
          started_at: DateTime.t() | nil,
          deadline_at: DateTime.t() | nil
        }

  @spec describe(map(), JobEnvelope.t()) ::
          {:ok, {:source, source()} | {:terminal, receipt()}} | {:error, Error.t()}
  def describe(context, envelope), do: describe(context, envelope, :error)

  @spec claim(map(), JobEnvelope.t(), String.t(), pos_integer()) ::
          {:ok, attempt()} | {:error, Error.t()}
  def claim(context, envelope, adapter, format) do
    with {:ok, ^adapter} <- KnowledgeValidation.bounded_name(adapter),
         true <- format?(format) do
      execute(
        context,
        envelope,
        "SELECT * FROM content.claim_document_worker($1,$2,$3,$4,$5,$6,$7,$8)",
        [adapter, format],
        &decode_attempt(&1, envelope),
        :error
      )
    else
      _ -> invalid()
    end
  end

  @spec complete(map(), JobEnvelope.t(), source(), attempt(), term()) ::
          {:ok, receipt()} | {:error, Error.t()}
  def complete(context, envelope, source, attempt, completion),
    do: complete(context, envelope, source, attempt, completion, :error)

  @spec record_exhaustion(map(), JobEnvelope.t(), term(), term()) ::
          {:ok, receipt() | :unchanged} | {:error, Error.t()}
  def record_exhaustion(context, envelope, _error, _runner_metadata) do
    case describe(context, envelope, :unchanged) do
      {:ok, {:source, %{state: :extracting} = source}} ->
        attempt = Map.take(source, @attempt_keys)

        complete(
          context,
          envelope,
          source,
          attempt,
          %{
            resource_id: source.resource_id,
            resource_version_id: source.resource_version_id,
            owner_scope_id: envelope.vault_id,
            classification: :private,
            generation: attempt.generation,
            outcome: :failed,
            adapter_name: attempt.adapter_name,
            format_version: attempt.format_version,
            finished_at: DateTime.utc_now(),
            media_type: source.media_type,
            failure_code: "extractor_failed"
          },
          :unchanged
        )

      {:ok, {:source, %{state: :pending}}} ->
        {:ok, :unchanged}

      {:ok, {:terminal, _receipt}} ->
        {:ok, :unchanged}

      other ->
        other
    end
  end

  defp describe(context, envelope, conflict_mode) do
    execute(
      context,
      envelope,
      "SELECT * FROM content.describe_document_worker($1,$2,$3,$4,$5,$6)",
      [],
      &decode_source(&1, envelope),
      conflict_mode
    )
  end

  defp complete(context, envelope, source, attempt, input, conflict_mode) do
    with :ok <- valid_envelope(envelope),
         true <- source?(source, envelope),
         true <- attempt?(attempt, envelope),
         true <- compatible_attempt?(source, attempt),
         {:ok, completion} <- DocumentCompletion.new(input),
         true <- completion_matches?(completion, envelope, source, attempt) do
      {statement, extra} = completion_args(completion)
      execute(context, envelope, statement, extra, &decode_receipt(&1, envelope), conflict_mode)
    else
      _ -> invalid()
    end
  end

  defp valid_envelope(%JobEnvelope{job_type: "document_extract"} = envelope) do
    with {:ok, encoded} <- EnvelopeCodec.encode(envelope),
         {:ok, ^envelope} <- EnvelopeCodec.decode(encoded),
         true <-
           is_integer(envelope.expected_entity_revision) and
             envelope.expected_entity_revision >= 0 and
             envelope.expected_entity_revision < @max_bigint,
         true <- bigint?(envelope.principal_authorization_epoch, 0),
         true <- bigint?(envelope.vault_authorization_epoch, 0) do
      :ok
    else
      _ -> invalid()
    end
  end

  defp valid_envelope(_), do: invalid()

  defp execute(context, envelope, statement, extra, decode, conflict_mode) do
    with :ok <- valid_envelope(envelope),
         %{repo_handle: WorkerRepo, transact: transact} when is_function(transact, 2) <- context,
         true <- WorkerRepo.checked_out?(),
         false <- WorkerRepo.in_transaction?() do
      result =
        transact.([], fn repo ->
          if repo === WorkerRepo and WorkerRepo.checked_out?() and WorkerRepo.in_transaction?() do
            case SafeSQL.query(repo, statement, parameters(envelope) ++ extra, log: false) do
              {:ok, result} ->
                decode.(result)

              {:error,
               %Postgrex.Error{postgres: %{constraint: "document_extraction_conflict_check"}}}
              when conflict_mode == :unchanged ->
                {:error, :document_worker_lifecycle_conflict}

              {:error, error} ->
                {:error, KnowledgeError.from(error)}
            end
          else
            invalid()
          end
        end)

      case result do
        {:error, :document_worker_lifecycle_conflict} when conflict_mode == :unchanged ->
          {:ok, :unchanged}

        {:error, error} ->
          {:error, KnowledgeError.from(error)}

        success ->
          success
      end
    else
      _ -> invalid()
    end
  rescue
    error -> {:error, KnowledgeError.from(error)}
  end

  defp parameters(envelope) do
    [
      Ecto.UUID.dump!(envelope.payload["resource_id"]),
      Ecto.UUID.dump!(envelope.payload["resource_version_id"]),
      Ecto.UUID.dump!(envelope.job_id),
      envelope.expected_entity_revision,
      envelope.principal_authorization_epoch,
      envelope.vault_authorization_epoch
    ]
  end

  defp decode_source(
         %Postgrex.Result{
           columns: @describe_columns,
           num_rows: 1,
           rows: [
             [
               "terminal",
               resource,
               version,
               job,
               state,
               generation,
               nil,
               nil,
               nil,
               nil,
               nil,
               nil,
               nil,
               nil,
               nil
             ]
           ]
         },
         envelope
       ) do
    with {:ok, receipt} <- receipt(resource, version, job, generation, state, envelope),
         do: {:ok, {:terminal, receipt}}
  end

  defp decode_source(
         %Postgrex.Result{
           columns: @describe_columns,
           num_rows: 1,
           rows: [
             [
               "source",
               resource,
               version,
               job,
               state,
               generation,
               object,
               object_generation,
               digest,
               size,
               media,
               adapter,
               format,
               started,
               deadline
             ]
           ]
         },
         envelope
       ) do
    with {:ok, resource} <- uuid(resource),
         {:ok, version} <- uuid(version),
         {:ok, job} <- uuid(job),
         {:ok, object} <- uuid(object),
         {:ok, state} <- source_state(state),
         source = %{
           resource_id: resource,
           resource_version_id: version,
           job_id: job,
           state: state,
           generation: generation,
           object_id: object,
           object_generation: object_generation,
           source_digest: digest,
           source_byte_size: size,
           media_type: media,
           adapter_name: adapter,
           format_version: format,
           started_at: started,
           deadline_at: deadline
         },
         true <- source?(source, envelope) do
      {:ok, {:source, source}}
    else
      _ -> invalid()
    end
  end

  defp decode_source(_, _), do: invalid()

  defp decode_attempt(
         %Postgrex.Result{
           columns: @claim_columns,
           num_rows: 1,
           rows: [
             [
               resource,
               version,
               job,
               generation,
               "extracting",
               adapter,
               format,
               started,
               deadline
             ]
           ]
         },
         envelope
       ) do
    with {:ok, resource} <- uuid(resource),
         {:ok, version} <- uuid(version),
         {:ok, job} <- uuid(job),
         attempt = %{
           resource_id: resource,
           resource_version_id: version,
           job_id: job,
           generation: generation,
           state: :extracting,
           adapter_name: adapter,
           format_version: format,
           started_at: started,
           deadline_at: deadline
         },
         true <- attempt?(attempt, envelope) do
      {:ok, attempt}
    else
      _ -> invalid()
    end
  end

  defp decode_attempt(_, _), do: invalid()

  defp decode_receipt(
         %Postgrex.Result{
           columns: @receipt_columns,
           num_rows: 1,
           rows: [[resource, version, job, generation, state]]
         },
         envelope
       ),
       do: receipt(resource, version, job, generation, state, envelope)

  defp decode_receipt(_, _), do: invalid()

  defp receipt(resource, version, job, generation, state, envelope) do
    with {:ok, resource} <- uuid(resource),
         {:ok, version} <- uuid(version),
         {:ok, job} <- uuid(job),
         {:ok, state} <- terminal_state(state),
         receipt = %{
           resource_id: resource,
           resource_version_id: version,
           job_id: job,
           generation: generation,
           state: state
         },
         true <- identity?(receipt, envelope),
         true <- generation === envelope.expected_entity_revision + 1 do
      {:ok, receipt}
    else
      _ -> invalid()
    end
  end

  defp source?(source, envelope) do
    closed?(source, @source_keys) and identity?(source, envelope) and
      canonical_uuid?(source.object_id) and bigint?(source.object_generation, 1) and
      is_binary(source.source_digest) and byte_size(source.source_digest) == 32 and
      is_integer(source.source_byte_size) and source.source_byte_size in 0..67_108_864 and
      source.media_type in @media_types and source_attempt?(source, envelope)
  end

  defp source_attempt?(%{state: :pending} = source, envelope),
    do:
      source.generation === envelope.expected_entity_revision and
        Enum.all?(
          [source.adapter_name, source.format_version, source.started_at, source.deadline_at],
          &is_nil/1
        )

  defp source_attempt?(%{state: :extracting} = source, envelope),
    do: attempt?(Map.take(source, @attempt_keys), envelope)

  defp source_attempt?(_, _), do: false

  defp attempt?(attempt, envelope) do
    closed?(attempt, @attempt_keys) and identity?(attempt, envelope) and
      attempt.state === :extracting and
      attempt.generation === envelope.expected_entity_revision + 1 and
      match?(
        {:ok, adapter} when adapter == attempt.adapter_name,
        KnowledgeValidation.bounded_name(attempt.adapter_name)
      ) and
      format?(attempt.format_version) and datetime?(attempt.started_at) and
      datetime?(attempt.deadline_at) and
      DateTime.diff(attempt.deadline_at, attempt.started_at, :microsecond) == 180_000_000
  end

  defp compatible_attempt?(%{state: :pending}, _attempt), do: true
  defp compatible_attempt?(source, attempt), do: Map.take(source, @attempt_keys) === attempt

  defp completion_matches?(completion, envelope, source, attempt) do
    completion.resource_id === source.resource_id and
      completion.resource_version_id === source.resource_version_id and
      completion.owner_scope_id === envelope.vault_id and completion.classification === :private and
      completion.generation === attempt.generation and
      completion.adapter_name === attempt.adapter_name and
      completion.format_version === attempt.format_version and
      completion.media_type === source.media_type
  end

  defp completion_args(%DocumentCompletion{outcome: :ready} = completion) do
    fragments =
      Enum.map(completion.fragments, fn fragment ->
        %{
          "id" => fragment.fragment_id,
          "ordinal" => fragment.ordinal,
          "text" => fragment.text,
          "digest" => Base.encode16(fragment.digest, case: :lower),
          "locator" => SourceLocator.to_map(fragment.locator)
        }
      end)

    {"SELECT * FROM content.complete_document_worker($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)",
     [
       completion.generation,
       completion.adapter_name,
       completion.format_version,
       completion.media_type,
       fragments,
       completion.extracted_text_digest,
       completion.detected_language
     ]}
  end

  defp completion_args(completion),
    do:
      {"SELECT * FROM content.fail_document_worker($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)",
       [
         completion.generation,
         completion.adapter_name,
         completion.format_version,
         completion.media_type,
         Atom.to_string(completion.outcome),
         completion.failure_code
       ]}

  defp closed?(value, keys),
    do: is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)

  defp identity?(value, envelope),
    do:
      value.resource_id === envelope.payload["resource_id"] and
        value.resource_version_id === envelope.payload["resource_version_id"] and
        value.job_id === envelope.job_id

  defp uuid(value) when is_binary(value) and byte_size(value) == 16 do
    case Ecto.UUID.load(value) do
      {:ok, value} -> {:ok, value}
      _ -> invalid()
    end
  end

  defp uuid(_), do: invalid()

  defp canonical_uuid?(value),
    do: is_binary(value) and match?({:ok, ^value}, Ecto.UUID.cast(value))

  defp bigint?(value, minimum),
    do: is_integer(value) and value >= minimum and value <= @max_bigint

  defp format?(value), do: is_integer(value) and value in 1..2_147_483_647

  defp datetime?(value),
    do: match?({:ok, _}, KnowledgeValidation.utc_datetime(%{value: value}, :value))

  defp source_state("pending"), do: {:ok, :pending}
  defp source_state("extracting"), do: {:ok, :extracting}
  defp source_state(_), do: invalid()
  defp terminal_state("ready"), do: {:ok, :ready}
  defp terminal_state("failed"), do: {:ok, :failed}
  defp terminal_state("unsupported"), do: {:ok, :unsupported}
  defp terminal_state(_), do: invalid()
  defp invalid, do: {:error, Error.new(:invalid)}
end
```

## Task 3: Verify and review the bounded slice

- [x] Format only the two assigned Elixir paths, then check formatting:

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix format apps/singularity_storage/lib/singularity/storage/postgres/document_worker_repository.ex apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix format --check-formatted apps/singularity_storage/lib/singularity/storage/postgres/document_worker_repository.ex apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs
```

- [x] Run the Task 1 scoped integration command. Expected: all adapter contracts and all original 32 SQL contracts pass. Record seed, test count, exclusions, elapsed time and actual exit status.
- [x] Run `git diff --check` and `git diff --stat`; independently review the exact adapter/test diff against the governing spec. Verify no migration/grant/public API/Vault/Runtime changes. Confirm all commands and test-owned tasks have finished.
- [x] Parent runs the separately required scoped GenericWorker/ScopedRepo boundary regressions and compile/xref gates after this slice. Report slice evidence without claiming Task 12, Phase 2, runtime custody, E2E, or release acceptance.

## Self-review and parent execution gate

The coordinator records completed checks from executed commands and both independent reviews; no required slice check is waived. The initial three-contract RED evidence above is preserved separately from later tests.

Spec mapping: exact envelope/IDs and bounded maps are Task 2 `valid_envelope`, parameters and private decoders; transaction/context/cleanup are Task 2 `execute` plus Task 1 real WorkerScope/rollback tests; completion identity and canonical serializer are Task 2 `complete` and `completion_args`; exhaustion fences and recognized-conflict-only handling are Task 2 `record_exhaustion`/`execute` plus Task 1 matrix; privacy uses SafeSQL/KnowledgeError and Task 1 canary assertions. The accepted SQL tests retain ACLs, lock/snapshot/race and canonical SQL validation evidence.

Before production creation, the parent must read this entire plan and confirm spec coverage, placeholder absence, and consistent types/signatures. GO is a parent coordination gate already requested by the assignment, not another user approval request.

The main agent completed that self-review and gave GO on 2026-10-08 after reading the full plan, mapping specification sections 3–7 and 10, checking type/signature consistency, and finding no placeholder matches. Its one correction broadened raised-exception sanitation to `KnowledgeError.from/1`, with a RuntimeError canary regression, while leaving exits and process death uncaught. Final preimplementation RED: seed `89315`, exit 2, 47 tests/15 missing-module failures, 20.9 seconds; original 32 SQL tests pass. Initial RED remains recorded above. The code block is synchronized with the formatted implementation.

First GREEN: seed `653159`, exit 0, 47 tests, 0 failures. Parent fresh combined integration: seed `637050`, exit 0, 73 executed tests, 0 failures (72 storage and 1 Runtime; 2 Runtime tests excluded). Parent fresh durable-job unit regressions: seed `650669`, 16 tests, 0 failures. Scoped formatting, strict incremental compile, zero-cycle xref, exact plan/module comparison and diff checks pass. Independent spec review reports `SPEC_COMPLIANT`; independent code quality review reports no Critical, Important or Minor findings and readiness for local commit. Both reviews were read-only and did not independently rerun tests. See the [verification record](../../verification/2026-10-08-document-worker-adapter.md) for exact commands and boundaries. This is not Task 12 or Phase 2 acceptance.
