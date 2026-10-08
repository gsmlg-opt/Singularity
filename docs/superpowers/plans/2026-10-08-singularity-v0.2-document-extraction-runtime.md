# Phase 2 Document Extraction Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. The parent owns delegation and review; do not launch nested workers.

**Goal:** Complete Task 12's authenticated, replay-safe, fenced Document extraction worker and prove its production composition.

**Architecture:** Runtime validates the closed durable envelope, checks live job authorization in a short trusted transaction, and obtains typed source metadata from DocumentWorkerRepository. Each invocation obtains a fresh sequential Document DownloadLease, authenticates the full bounded original and compares its pinned SHA-256, revokes the lease, then claims/resumes and extracts outside SQL transactions before persisting a validated bounded outcome. Existing claimed source-access failures use the descriptor's exact attempt fields to persist failed/extractor_failed without re-claiming; terminal replay returns only the typed receipt.

**Tech Stack:** Elixir, existing Core DocumentCompletion/DocumentFragmentation, Text/Markdown/PDF Ingest adapters, Runtime KeyCustodian/DownloadLease, WorkerScope/WorkerRepo, and existing Oban GenericWorker.

---

## Authority and checkout

This plan applies only to `/home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-2-import-extraction`, branch `codex/v0.2-phase-2-import-extraction`, baseline `5cf98c61172fba497bde1df2b4f81fa31c492011`.

Governing documents, read before preparing this plan:

- `docs/superpowers/specs/2026-09-22-singularity-v0.2-phase-2-import-extraction-design.md`
- `docs/superpowers/specs/2026-10-08-singularity-v0.2-phase-2-worker-bridge-proposal.md`
- `docs/superpowers/specs/2026-10-08-singularity-v0.2-document-source-replay-design.md`
- Task 12 in `docs/superpowers/plans/2026-09-22-singularity-v0.2-phase-2-import-extraction.md`

Prerequisites already committed: SQL bridge b8db6d5, typed adapter 0cc65c0, fresh lease 03a1bc2, source-lease evidence 5f2b4cf, progress ebb1f7c, progress evidence/current baseline 5cf98c6.

At the preparation checkpoint, production edits required main to read this entire executable A plan and give GO. Main completed that review and issued bounded A GO after the final 43-contract RED and parent architecture RED. B and C still require complete-code plans and review checkpoints after A. None of A, B, or C alone accepts Task 12 or Phase 2. All required contracts remain in the ledger below. No worker commit, push, release, version change, deployment, E2E, new dependency, migration, Vault feature/compatibility patch, or outside-scope fix is included.

## File ownership and sequencing

The implementation worker owns exactly:

- New `apps/singularity_runtime/lib/singularity/runtime/documents/extract.ex`: the complete five-stage worker and sanitized terminal callback delegation.
- New `apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs`: A unit contracts, then B/C integration modules in this same file.
- `apps/singularity_runtime/lib/singularity/runtime/job_dispatcher.ex`: additive Document route, lease dependency, and terminal callback.
- `apps/singularity_runtime/lib/singularity/runtime/application.ex`: additive Document repository/extractor dependencies.
- This plan.

Main owns the architecture guard and verification/specification records. Main may add only the exact approved wiring allowances while preserving all original frozen hashes/bytes and negative assertions. Existing application_test dependency assertions are partial maps; no old assertion changes are needed.

Dependency order, approved by main: A supplies the complete production worker plus comprehensive isolated unit contracts; B proves actual WorkerRepo/crypto/storage source, claim, and death behavior; C proves actual outcomes, lifecycle/recovery/exhaustion/privacy. Later integration evidence can require surgical repairs to A's complete implementation, but cannot silently reduce acceptance.

## Characterized baseline and RED

- [x] Unchanged Asset/application baseline: `MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/metadata_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_unlock_resume_test.exs apps/singularity_runtime/test/singularity/runtime/job_dispatcher_asset_events_test.exs apps/singularity_runtime/test/singularity/runtime/application_test.exs --seed 1208`. Exit 0; ExUnit reported 39 tests, 0 failures, 17 integration exclusions, hence 22 executed. No existing assertions changed.
- [x] Unchanged architecture baseline: `MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs --seed 1208`. Exit 0; 14 reported/executed tests, 0 failures.
- [x] Initial isolated RED: `MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs --seed 1208`. Exit 2; initial 32 reported/executed tests, 32 failures due to missing Document dispatcher route/dependencies. No production changes.
- [x] Initial expanded isolated RED: the same new-file command above, seed 1208, exited 2 with 40 reported/executed tests, 40 expected assertion failures and no exclusions. Missing route, terminal callback, and dependency entries explain the failures. The dependency assertion uses a map pattern, so absence produces an assertion failure rather than KeyError.
- [x] Post-review expanded isolated RED: the same new-file command above, seed 1208, exited 2 with 43 reported/executed tests, 43 expected assertion failures and no exclusions. The additional contracts accept the exact local normal/noproc revoke-call exits after empty authentication and reject unrelated cleanup exits.
- [x] An owned local GenServer probe verified the exact normal and noproc revoke-call exit tuples on the current OTP/Elixir runtime; its monitor confirmed termination. This confirms exit shapes only; B still requires actual DownloadLease/crypto/storage proof.
- [x] Parsed the entire proposed Extract module with Code.string_to_quoted/1 in an Elixir-only command; syntax passed. This did not compile/write a production file or establish GREEN behavior.
- [x] Main reads this complete A plan and authorizes production GO.

Ordinary unit commands create no temporary integration database/root. Integration B/C commands must use the isolated alias and verify the exact printed database/root are absent afterward while leaving borrowed PostgreSQL services running. The shared Mix slot allows one Mix command at a time.

## A1: Complete focused unit contracts

**Files:** Create `apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs`.

- [x] Add the complete test file below. Adapters isolate repository/custody effects; actual Text, Markdown, PDF, DocumentFragmentation, and DocumentCompletion perform extraction/normalization/validation. The small Script chunk size proves size-independent sequential reading without changing production storage. Real source authentication/authority/atomicity remains mandatory in B/C.

```elixir
defmodule Singularity.Runtime.DocumentExtractionJobTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.{DocumentCompletion, Error, JobEnvelope}
  alias Singularity.Runtime.{DownloadLease, JobDispatcher, KeyLease}
  alias Singularity.Storage.Postgres.DocumentWorkerRepository
  alias Singularity.Ingest.Documents.{Markdown, PDF, Text}

  @canary "document-private-content-and-tool-output-canary"

  defmodule Script do
    def event(server, event) do
      {hook, transaction?} =
        Agent.get_and_update(server, fn state ->
          {{Map.get(state.hooks, elem(event, 0)), state.transaction?},
           %{state | events: state.events ++ [event]}}
        end)

      if hook, do: hook.(event, transaction?)
      transaction?
    end

    def value(server, key), do: Agent.get(server, &Map.fetch!(&1, key))

    def check_job(server, _authorization, :worker_repo, envelope) do
      true = event(server, {:authorize, envelope.job_id})
      value(server, :authorization_result)
    end

    def describe(server, _context, envelope) do
      false = event(server, {:describe, envelope.job_id})
      value(server, :description)
    end

    def put_progress_state(server, _context, _envelope, state) do
      false = event(server, {:progress, state})
      value(server, :progress_result)
    end

    def lease(server, request) do
      false = event(server, {:lease, request})

      case value(server, :lease_result) do
        :lease -> {:ok, server}
        other -> other
      end
    end

    def read_document_chunk(server, lease, index) when server == lease do
      false = event(server, {:read, index})

      case value(server, :read_result) do
        :bytes ->
          bytes = value(server, :bytes)
          chunk_size = value(server, :chunk_size)
          offset = index * chunk_size

          if offset < byte_size(bytes),
            do: {:ok, binary_part(bytes, offset, min(byte_size(bytes) - offset, chunk_size))},
            else: {:ok, ""}

        other ->
          other
      end
    end

    def authenticate_empty_document_source(server, lease) when server == lease do
      false = event(server, {:empty, :authenticate})
      value(server, :empty_result)
    end

    def revoke(server, lease) when server == lease do
      false = event(server, {:revoke, :source})
      value(server, :revoke_result)
    end

    def claim(server, _context, envelope, adapter_name, format_version) do
      false = event(server, {:claim, adapter_name, format_version})

      case value(server, :claim_result) do
        :attempt ->
          {:ok,
           Map.merge(identity(envelope), %{
             state: :extracting,
             generation: envelope.expected_entity_revision + 1,
             adapter_name: adapter_name,
             format_version: format_version,
             started_at: ~U[2026-10-08 00:00:00Z],
             deadline_at: ~U[2026-10-08 00:03:00Z]
           })}

        other ->
          other
      end
    end

    def extract(server, bytes) do
      false = event(server, {:extract, :crypto.hash(:sha256, bytes)})

      case value(server, :extract_result) do
        :text -> Text.extract(bytes)
        other -> other
      end
    end

    def complete(server, _context, envelope, source, attempt, completion) do
      false = event(server, {:complete, completion})
      {:ok, valid} = DocumentCompletion.new(completion)
      true = valid.resource_version_id == source.resource_version_id
      true = valid.generation == attempt.generation

      case value(server, :complete_result) do
        :receipt ->
          {:ok,
           Map.merge(identity(envelope), %{generation: attempt.generation, state: valid.outcome})}

        other ->
          other
      end
    end

    def record_exhaustion(server, _context, envelope, failure, metadata) do
      false = event(server, {:exhaustion, envelope.job_id, failure, metadata})
      value(server, :exhaustion_result)
    end

    defp identity(envelope),
      do: %{
        resource_id: envelope.payload["resource_id"],
        resource_version_id: envelope.payload["resource_version_id"],
        job_id: envelope.job_id
      }
  end

  setup do
    version = Ecto.UUID.generate()

    {:ok, envelope} =
      JobEnvelope.new(%{
        version: 1,
        job_type: "document_extract",
        job_id: Ecto.UUID.generate(),
        idempotency_key: "document-extraction:" <> version,
        vault_id: Ecto.UUID.generate(),
        principal_id: Ecto.UUID.generate(),
        required_capability: "asset.read",
        principal_authorization_epoch: 0,
        vault_authorization_epoch: 0,
        classification: :private,
        correlation_id: Ecto.UUID.generate(),
        causation_id: Ecto.UUID.generate(),
        expected_entity_revision: 0,
        attempt: 0,
        payload: %{"resource_id" => Ecto.UUID.generate(), "resource_version_id" => version}
      })

    bytes = "first paragraph\n\nsecond paragraph"

    source = %{
      resource_id: envelope.payload["resource_id"],
      resource_version_id: version,
      job_id: envelope.job_id,
      state: :pending,
      generation: 0,
      object_id: Ecto.UUID.generate(),
      object_generation: 1,
      source_digest: :crypto.hash(:sha256, bytes),
      source_byte_size: byte_size(bytes),
      media_type: "text/plain",
      adapter_name: nil,
      format_version: nil,
      started_at: nil,
      deadline_at: nil
    }

    server =
      start_supervised!(
        {Agent,
         fn ->
           %{
             events: [],
             hooks: %{},
             transaction?: false,
             bytes: bytes,
             chunk_size: 4_194_304,
             description: {:ok, {:source, source}},
             authorization_result: :ok,
             progress_result: {:ok, :saved},
             lease_result: :lease,
             read_result: :bytes,
             empty_result: :ok,
             revoke_result: :ok,
             claim_result: :attempt,
             extract_result: :text,
             complete_result: :receipt,
             exhaustion_result: {:ok, :unchanged}
           }
         end}
      )

    context = %{
      document_worker: {Script, server},
      authorization: :live_authorization,
      authorize: {Script, server},
      custodian: {Script, server},
      document_source_lease: {Script, server},
      document_extractors: %{
        "text/plain" => {{Script, server}, "plain_text", 1},
        "text/markdown" => {Markdown, "markdown", 1},
        "application/pdf" => {PDF, "poppler_text", 1}
      },
      transact: fn [], callback ->
        Agent.update(server, &%{&1 | transaction?: true})

        try do
          callback.(:worker_repo)
        after
          Agent.update(server, &%{&1 | transaction?: false})
        end
      end
    }

    %{server: server, context: context, envelope: envelope, source: source, bytes: bytes}
  end

  test "terminal duplicate returns only its bounded receipt without custody", c do
    receipt = receipt(c, :ready)
    update(c, description: {:ok, {:terminal, receipt}})
    assert {:ok, ^receipt} = run(c)
    assert [{:authorize, _}, {:describe, _}] = events(c)
  end

  test "whole-source digest precedes claim and cleanup precedes extraction", c do
    assert {:ok, receipt} = run(c)
    assert receipt == receipt(c, :ready)

    assert [
             {:authorize, _},
             {:describe, _},
             {:lease, request},
             {:read, 0},
             {:revoke, :source},
             {:progress, :running},
             {:claim, "plain_text", 1},
             {:extract, digest},
             {:complete, completion}
           ] = events(c)

    assert request == %{
             purpose: :document_extraction_source,
             access: :worker,
             job_id: c.envelope.job_id,
             resource_version_id: c.source.resource_version_id,
             vault_id: c.envelope.vault_id,
             principal_id: c.envelope.principal_id,
             required_capability: "asset.read",
             principal_authorization_epoch: 0,
             vault_authorization_epoch: 0,
             object_id: c.source.object_id,
             object_generation: 1
           }

    assert digest == c.source.source_digest
    assert %DocumentCompletion{outcome: :ready, fragments: [first, second]} = completion

    assert {first.ordinal, first.text, first.locator.fields.start_line} ==
             {0, "first paragraph", 1}

    assert {second.ordinal, second.text, second.locator.fields.start_line} ==
             {1, "second paragraph", 3}

    assert completion.extracted_text_digest == :crypto.hash(:sha256, [first.text, second.text])
  end

  test "fresh invocation rereads every chunk in order and builds deterministic fragments", c do
    bytes = "abcdtail"

    source = %{
      c.source
      | source_byte_size: byte_size(bytes),
        source_digest: :crypto.hash(:sha256, bytes)
    }

    update(c, bytes: bytes, chunk_size: 4, description: {:ok, {:source, source}})
    assert {:ok, _} = run(c)
    [{:complete, first}] = Enum.filter(events(c), &(elem(&1, 0) == :complete))
    update(c, events: [])
    assert {:ok, _} = run(c)
    assert [{:read, 0}, {:read, 1}] = Enum.filter(events(c), &(elem(&1, 0) == :read))
    [{:complete, second}] = Enum.filter(events(c), &(elem(&1, 0) == :complete))
    assert first.fragments == second.fragments
    assert first.extracted_text_digest == second.extracted_text_digest
  end

  test "Markdown uses the production adapter with heading and line provenance", c do
    bytes = "# Heading\n\nbody"

    source = %{
      c.source
      | media_type: "text/markdown",
        source_byte_size: byte_size(bytes),
        source_digest: :crypto.hash(:sha256, bytes)
    }

    update(c, bytes: bytes, description: {:ok, {:source, source}})
    assert {:ok, _} = run(c)
    [{:complete, completion}] = Enum.filter(events(c), &(elem(&1, 0) == :complete))
    assert completion.adapter_name == "markdown"
    assert [heading, body] = completion.fragments
    assert heading.locator.fields.heading_path == ["Heading"]
    assert body.locator.fields.start_line == 3
  end

  test "real PDF adapter preserves multiple pages and deterministic fragments", c do
    bytes =
      File.read!(
        Path.expand(
          "../../../../singularity_ingest/test/fixtures/documents/two_pages.pdf",
          __DIR__
        )
      )

    source = %{
      c.source
      | media_type: "application/pdf",
        source_byte_size: byte_size(bytes),
        source_digest: :crypto.hash(:sha256, bytes)
    }

    update(c, bytes: bytes, description: {:ok, {:source, source}})
    assert {:ok, %{state: :ready}} = run(c)
    [{:complete, first}] = Enum.filter(events(c), &(elem(&1, 0) == :complete))
    assert [page_one, page_two] = first.fragments
    assert {page_one.locator.fields.page, page_two.locator.fields.page} == {1, 2}
    assert page_one.text =~ "First page"
    assert page_two.text =~ "Second page"
    assert first.adapter_name == "poppler_text"
    update(c, events: [])
    assert {:ok, %{state: :ready}} = run(c)
    [{:complete, second}] = Enum.filter(events(c), &(elem(&1, 0) == :complete))
    assert first.fragments == second.fragments
    assert first.extracted_text_digest == second.extracted_text_digest
  end

  test "actual text decoder maps invalid UTF-8 to unsupported", c do
    bytes = <<255>>
    source = %{c.source | source_byte_size: 1, source_digest: :crypto.hash(:sha256, bytes)}
    update(c, bytes: bytes, description: {:ok, {:source, source}})
    assert {:ok, %{state: :unsupported}} = run(c)
    [{:complete, completion}] = Enum.filter(events(c), &(elem(&1, 0) == :complete))
    assert completion.failure_code == "invalid_utf8"
  end

  test "same-job claimed source uses the recorded adapter identity without changing deadline",
       c do
    source =
      Map.merge(c.source, %{
        state: :extracting,
        generation: 1,
        adapter_name: "plain_text",
        format_version: 1,
        started_at: ~U[2026-10-08 00:00:00Z],
        deadline_at: ~U[2026-10-08 00:03:00Z]
      })

    update(c, description: {:ok, {:source, source}})
    assert {:ok, %{state: :ready}} = run(c)
    assert {:claim, "plain_text", 1} in events(c)
  end

  test "unsupported source size is rejected before custody", c do
    source = %{c.source | source_byte_size: 67_108_865}
    update(c, description: {:ok, {:source, source}})
    assert {:error, %Error{code: :integrity_failure}} = run(c)
    refute_action(c, :lease)
    refute_action(c, :claim)
  end

  test "valid empty source authenticates storage before claim and becomes unsupported", c do
    source = %{c.source | source_byte_size: 0, source_digest: :crypto.hash(:sha256, "")}
    update(c, bytes: "", description: {:ok, {:source, source}})
    assert {:ok, receipt} = run(c)
    assert receipt.state == :unsupported

    assert [
             {:authorize, _},
             {:describe, _},
             {:lease, _},
             {:empty, :authenticate},
             {:revoke, :source},
             {:progress, :running},
             {:claim, _, _},
             {:extract, _},
             {:complete, completion}
           ] = events(c)

    assert completion.failure_code == "no_extractable_text"
  end

  test "failed empty authentication revokes without claiming or extracting", c do
    source = %{c.source | source_byte_size: 0, source_digest: :crypto.hash(:sha256, "")}

    update(c,
      description: {:ok, {:source, source}},
      empty_result: {:error, Error.new(:integrity_failure)}
    )

    assert {:error, %Error{code: :integrity_failure, message: nil, details: %{}}} = run(c)
    refute_action(c, :claim)
    refute_action(c, :extract)
    assert List.last(events(c)) == {:revoke, :source}
  end

  test "locked custody saves waiting before snoozing without claiming", c do
    update(c, lease_result: {:error, :waiting_for_unlock})
    assert {:snooze, 60} = run(c)

    assert [{:authorize, _}, {:describe, _}, {:lease, _}, {:progress, :waiting_for_unlock}] =
             events(c)

    refute_action(c, :claim)
    update(c, lease_result: :lease, events: [])
    assert {:ok, _} = run(c)
    assert {:progress, :running} in events(c)
  end

  for state <- [:waiting_for_unlock, :running] do
    test "#{state} progress persistence failure propagates sanitized without claim", c do
      update(c,
        progress_result:
          {:error,
           Error.new(:storage_unavailable,
             retryable?: true,
             message: @canary,
             details: %{content: @canary}
           )}
      )

      if unquote(state) == :waiting_for_unlock,
        do: update(c, lease_result: {:error, :waiting_for_unlock})

      assert {:error,
              %Error{code: :storage_unavailable, retryable?: true, message: nil, details: %{}}} =
               run(c)

      refute_action(c, :claim)
      refute_action(c, :extract)
    end
  end

  test "digest mismatch leaves no attempt or extractor call", c do
    source = %{c.source | source_digest: :crypto.hash(:sha256, "different")}
    update(c, description: {:ok, {:source, source}})
    assert {:error, %Error{code: :integrity_failure, retryable?: false}} = run(c)
    refute_action(c, :claim)
    refute_action(c, :extract)
    assert List.last(events(c)) == {:revoke, :source}
  end

  test "short or overlong authenticated data records fail before claim", c do
    for bytes <- ["short", c.bytes <> "extra"] do
      update(c, bytes: bytes, events: [])
      assert {:error, %Error{code: :integrity_failure}} = run(c)
      refute_action(c, :claim)
      refute_action(c, :extract)
      assert List.last(events(c)) == {:revoke, :source}
    end
  end

  test "read error and raised private diagnostic both revoke and sanitize", c do
    update(c,
      read_result:
        {:error,
         Error.new(:storage_unavailable,
           message: @canary,
           details: %{content: @canary},
           retryable?: true
         )}
    )

    assert {:error, %Error{code: :storage_unavailable, message: nil, details: %{}}} = run(c)
    assert List.last(events(c)) == {:revoke, :source}
    update(c, hooks: %{read: fn _, _ -> raise @canary end}, events: [])
    assert {:error, %Error{code: :storage_unavailable, message: nil, details: %{}}} = run(c)
    assert List.last(events(c)) == {:revoke, :source}
    refute_action(c, :claim)
  end

  test "lease cleanup failure prevents extraction and claim", c do
    update(c, revoke_result: {:error, @canary})
    assert {:error, %Error{code: :storage_unavailable, message: nil, details: %{}}} = run(c)
    refute_action(c, :claim)
    refute_action(c, :extract)
  end

  for reason <- [:normal, :noproc] do
    test "empty authentication tolerates exact local #{reason} revoke-call exit", c do
      source = %{c.source | source_byte_size: 0, source_digest: :crypto.hash(:sha256, "")}

      update(c,
        bytes: "",
        description: {:ok, {:source, source}},
        hooks: %{
          revoke: fn _, _ ->
            exit({unquote(reason), {GenServer, :call, [c.server, :revoke, :infinity]}})
          end
        }
      )

      assert {:ok, %{state: :unsupported}} = run(c)
      assert {:empty, :authenticate} in events(c)
      assert {:revoke, :source} in events(c)
      assert {:claim, "plain_text", 1} in events(c)
    end
  end

  test "unrelated cleanup exits cannot masquerade as a closed source lease", c do
    for reason <- [
          :normal,
          {:normal, {GenServer, :call, [self(), :revoke, :infinity]}},
          {:normal, {GenServer, :call, [c.server, :read, :infinity]}},
          {:noproc, {GenServer, :call, [c.server, :revoke, 5_000]}},
          {:shutdown, {GenServer, :call, [c.server, :revoke, :infinity]}}
        ] do
      update(c, events: [], hooks: %{revoke: fn _, _ -> exit(reason) end})
      assert {:error, %Error{code: :storage_unavailable, message: nil, details: %{}}} = run(c)
      refute_action(c, :claim)
      refute_action(c, :extract)
    end
  end

  test "authorization failure prevents all source operations", c do
    update(c, authorization_result: {:error, Error.new(:forbidden, message: @canary)})
    assert {:error, %Error{code: :forbidden, message: nil, details: %{}}} = run(c)
    assert [{:authorize, _}] = events(c)
  end

  test "malformed envelope and injected identity fields fail before authorization", c do
    for envelope <- [
          Map.from_struct(c.envelope),
          %{
            c.envelope
            | payload: Map.put(c.envelope.payload, "owner_scope_id", Ecto.UUID.generate())
          },
          %{c.envelope | payload: Map.put(c.envelope.payload, "object_id", Ecto.UUID.generate())},
          %{c.envelope | payload: Map.put(c.envelope.payload, "text", @canary)},
          %{c.envelope | principal_id: "bad"},
          %{c.envelope | classification: :sensitive},
          %{c.envelope | required_capability: "asset.write"},
          %{c.envelope | expected_entity_revision: 9_223_372_036_854_775_807}
        ] do
      assert {:error, %Error{code: :invalid, message: nil, details: %{}}} =
               JobDispatcher.handle(c.context, envelope)

      assert events(c) == []
    end
  end

  test "claim rejection after source read prevents extraction", c do
    update(c, claim_result: {:error, Error.new(:conflict, message: @canary)})
    assert {:error, %Error{code: :conflict, message: nil, details: %{}}} = run(c)
    refute_action(c, :extract)
    refute_action(c, :complete)
  end

  for failure <- [:locked, :storage] do
    test "already-claimed #{failure} source access persists failure without re-claim", c do
      source = extracting_source(c)
      update(c, description: {:ok, {:source, source}})

      case unquote(failure) do
        :locked ->
          update(c, lease_result: {:error, :waiting_for_unlock})

        :storage ->
          update(c,
            read_result:
              {:error, Error.new(:storage_unavailable, retryable?: true, message: @canary)}
          )
      end

      assert {:ok, %{state: :failed}} = run(c)
      refute_action(c, :claim)
      refute_action(c, :extract)
      refute_action(c, :progress)
      [{:complete, completion}] = Enum.filter(events(c), &(elem(&1, 0) == :complete))
      assert completion.generation == 1
      assert completion.failure_code == "extractor_failed"
      assert completion.fragments == nil
    end
  end

  test "post-claim source-failure persistence error propagates sanitized", c do
    update(c,
      description: {:ok, {:source, extracting_source(c)}},
      lease_result: {:error, :waiting_for_unlock},
      complete_result:
        {:error, Error.new(:storage_unavailable, retryable?: true, message: @canary)}
    )

    assert {:error,
            %Error{code: :storage_unavailable, retryable?: true, message: nil, details: %{}}} =
             run(c)

    refute_action(c, :claim)
    refute_action(c, :extract)
  end

  for {input, outcome, code} <- [
        {{:error, {:unsupported, "invalid_utf8"}}, :unsupported, "invalid_utf8"},
        {{:error, {:unsupported, "malformed_document"}}, :unsupported, "malformed_document"},
        {{:error, {:unsupported, "encrypted_document"}}, :unsupported, "encrypted_document"},
        {{:error, {:unsupported, "no_extractable_text"}}, :unsupported, "no_extractable_text"},
        {{:error, {:unsupported, "source_too_large"}}, :unsupported, "input_too_large"},
        {{:error, {:unsupported, "output_too_large"}}, :unsupported, "output_too_large"},
        {{:error, {:unsupported, "page_limit_exceeded"}}, :unsupported, "page_limit"},
        {{:error, {:failed, "extractor_timeout"}}, :failed, "timeout"},
        {{:error, {:failed, "extractor_failed"}}, :failed, "extractor_failed"},
        {{:error, {:unsupported, @canary}}, :failed, "extractor_failed"},
        {{:error, @canary}, :failed, "extractor_failed"}
      ] do
    test "extractor result #{inspect(input)} persists #{outcome}/#{code}", c do
      update(c, extract_result: unquote(Macro.escape(input)))
      assert {:ok, receipt} = run(c)
      assert receipt.state == unquote(outcome)
      [{:complete, completion}] = Enum.filter(events(c), &(elem(&1, 0) == :complete))

      assert %DocumentCompletion{
               outcome: unquote(outcome),
               failure_code: unquote(code),
               fragments: nil,
               extracted_text_digest: nil
             } = completion

      refute inspect(completion) =~ @canary
    end
  end

  test "raised extractor diagnostic becomes a persisted bounded failed outcome", c do
    update(c, hooks: %{extract: fn _, _ -> raise @canary end})
    assert {:ok, %{state: :failed}} = run(c)
    [{:complete, completion}] = Enum.filter(events(c), &(elem(&1, 0) == :complete))
    assert completion.failure_code == "extractor_failed"
    refute inspect(completion) =~ @canary
  end

  test "fragment count limit becomes unsupported without partial completion", c do
    blocks =
      for _ <- 1..4_097,
          do: %{text: "x", locator: %{version: 1, kind: "text", start_line: 1, end_line: 1}}

    update(c, extract_result: {:ok, blocks})
    assert {:ok, %{state: :unsupported}} = run(c)
    [{:complete, completion}] = Enum.filter(events(c), &(elem(&1, 0) == :complete))
    assert completion.failure_code == "output_too_large"
    assert completion.fragments == nil
  end

  test "normalized output byte limit becomes unsupported before fragment construction", c do
    blocks = [
      %{
        text: :binary.copy("x", 16_777_217),
        locator: %{version: 1, kind: "text", start_line: 1, end_line: 1}
      }
    ]

    update(c, extract_result: {:ok, blocks})
    assert {:ok, %{state: :unsupported}} = run(c)
    [{:complete, completion}] = Enum.filter(events(c), &(elem(&1, 0) == :complete))
    assert completion.failure_code == "output_too_large"
    assert completion.fragments == nil
  end

  test "completion storage failure propagates a sanitized error", c do
    update(c,
      complete_result:
        {:error, Error.new(:storage_unavailable, retryable?: true, message: @canary)}
    )

    assert {:error,
            %Error{code: :storage_unavailable, retryable?: true, message: nil, details: %{}}} =
             run(c)
  end

  test "terminal callback delegates envelope and runner metadata without custody", c do
    failure = Error.new(:storage_unavailable, retryable?: true, message: @canary)
    metadata = %{attempt: 4, max_attempts: 4}

    assert {:ok, :unchanged} =
             JobDispatcher.handle_failure(c.context, c.envelope, failure, metadata)

    assert [{:authorize, _}, {:exhaustion, job, safe, ^metadata}] = events(c)
    assert job == c.envelope.job_id
    assert safe == Error.new(:storage_unavailable, retryable?: true)
  end

  test "production dependency map keeps Asset KeyLease and uses dedicated DownloadLease", _c do
    dependencies = JobDispatcher.dependencies()

    assert %{
             document_worker: DocumentWorkerRepository,
             document_source_lease: DownloadLease,
             key_lease: KeyLease,
             document_extractors: %{
               "text/plain" => {Text, "plain_text", 1},
               "text/markdown" => {Markdown, "markdown", 1},
               "application/pdf" => {PDF, "poppler_text", 1}
             }
           } = dependencies
  end

  defp run(c), do: JobDispatcher.handle(c.context, c.envelope)

  defp extracting_source(c),
    do:
      Map.merge(c.source, %{
        state: :extracting,
        generation: 1,
        adapter_name: "plain_text",
        format_version: 1,
        started_at: ~U[2026-10-08 00:00:00Z],
        deadline_at: ~U[2026-10-08 00:03:00Z]
      })

  defp events(c), do: Script.value(c.server, :events)
  defp update(c, changes), do: Agent.update(c.server, &Map.merge(&1, Map.new(changes)))
  defp refute_action(c, action), do: refute(Enum.any?(events(c), &(elem(&1, 0) == action)))

  defp receipt(c, state),
    do:
      Map.merge(Map.take(c.source, [:resource_id, :resource_version_id, :job_id]), %{
        generation: 1,
        state: state
      })
end
```

- [x] Run RED before any production edit:

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs --seed 1208
```

Expected: every new test fails because the Document dispatcher route/dependencies are absent. Fix only test setup/compile defects if any; never weaken existing assertions. Expected RED is not a production repair round.

## A2: Complete five-stage production worker

**Files:** Create `apps/singularity_runtime/lib/singularity/runtime/documents/extract.ex`.

- [x] After main GO, create this exact complete module:

```elixir
defmodule Singularity.Runtime.Documents.Extract do
  @moduledoc "Composes bounded, authenticated Document extraction outside SQL transactions."

  alias Singularity.Core.{DocumentCompletion, DocumentFragmentation, Error, JobEnvelope}
  alias Singularity.Storage.Jobs.EnvelopeCodec

  @max_revision 9_223_372_036_854_775_807
  @source_limit 67_108_864
  @unsupported ~w(invalid_utf8 malformed_document encrypted_document no_extractable_text output_too_large)

  @spec run(map(), JobEnvelope.t()) :: {:ok, map()} | {:snooze, 60} | {:error, Error.t()}
  def run(context, %JobEnvelope{job_type: "document_extract"} = envelope)
      when is_map(context) do
    with :ok <- validate_envelope(envelope),
         :ok <- validate_context(context),
         :ok <- authorize(context, envelope),
         {:ok, target} <- call(context.document_worker, :describe, [context, envelope]) do
      run_target(context, envelope, target)
    end
    |> sanitize_result()
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  def run(_, _), do: {:error, Error.new(:invalid)}

  @doc false
  def record_exhaustion(
        context,
        %JobEnvelope{job_type: "document_extract"} = envelope,
        %Error{} = failure,
        metadata
      )
      when is_map(context) do
    with :ok <- validate_envelope(envelope),
         :ok <- validate_context(context),
         :ok <- authorize(context, envelope) do
      call(context.document_worker, :record_exhaustion, [
        context,
        envelope,
        sanitize_error(failure),
        metadata
      ])
    end
    |> sanitize_result()
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  def record_exhaustion(_, _, _, _), do: {:error, Error.new(:invalid)}

  defp run_target(_context, _envelope, {:terminal, receipt}), do: {:ok, receipt}

  defp run_target(context, envelope, {:source, source}) do
    with :ok <- validate_source(source),
         {:ok, extractor, adapter_name, format_version} <- extractor(context, source) do
      case acquire_source(context, envelope, source) do
        {:ok, bytes} ->
          with {:ok, :saved} <-
                 call(context.document_worker, :put_progress_state, [context, envelope, :running]),
               {:ok, attempt} <-
                 call(context.document_worker, :claim, [
                   context,
                   envelope,
                   adapter_name,
                   format_version
                 ]),
               {:ok, completion} <-
                 completion(envelope, source, attempt, extract(extractor, bytes)) do
            call(context.document_worker, :complete, [
              context,
              envelope,
              source,
              attempt,
              completion
            ])
          end

        {:error, %Error{code: :integrity_failure}} = error ->
          error

        failure ->
          source_failure(context, envelope, source, failure)
      end
    end
  end

  defp run_target(_, _, _), do: {:error, Error.new(:integrity_failure)}

  defp source_failure(context, envelope, %{state: :pending}, {:error, :waiting_for_unlock}) do
    with {:ok, :saved} <-
           call(context.document_worker, :put_progress_state, [
             context,
             envelope,
             :waiting_for_unlock
           ]) do
      {:snooze, 60}
    end
  end

  defp source_failure(context, envelope, %{state: :extracting} = source, {:error, _}) do
    attempt =
      Map.take(
        source,
        ~w(resource_id resource_version_id job_id generation state adapter_name format_version started_at deadline_at)a
      )

    with {:ok, completion} <-
           completion(envelope, source, attempt, {:error, {:failed, "extractor_failed"}}) do
      call(context.document_worker, :complete, [context, envelope, source, attempt, completion])
    end
  end

  defp source_failure(_context, _envelope, _source, failure), do: failure

  defp acquire_source(context, envelope, source) do
    request = %{
      purpose: :document_extraction_source,
      access: :worker,
      job_id: envelope.job_id,
      resource_version_id: source.resource_version_id,
      vault_id: envelope.vault_id,
      principal_id: envelope.principal_id,
      required_capability: "asset.read",
      principal_authorization_epoch: envelope.principal_authorization_epoch,
      vault_authorization_epoch: envelope.vault_authorization_epoch,
      object_id: source.object_id,
      object_generation: source.object_generation
    }

    with {:ok, lease} <- call(context.custodian, :lease, [request]) do
      try do
        with {:ok, bytes} <-
               read_source(context.document_source_lease, lease, source.source_byte_size),
             true <- :crypto.hash(:sha256, bytes) === source.source_digest do
          {:ok, bytes}
        else
          false -> {:error, Error.new(:integrity_failure)}
          other -> other
        end
      after
        revoke(context.document_source_lease, lease)
      end
    end
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  defp read_source(adapter, lease, 0) do
    case call(adapter, :authenticate_empty_document_source, [lease]) do
      :ok -> {:ok, ""}
      other -> other
    end
  end

  defp read_source(adapter, lease, size), do: read_chunks(adapter, lease, 0, size, [])

  defp read_chunks(_adapter, _lease, _index, 0, chunks),
    do: {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

  defp read_chunks(adapter, lease, index, remaining, chunks) do
    case call(adapter, :read_document_chunk, [lease, index]) do
      {:ok, bytes}
      when is_binary(bytes) and byte_size(bytes) > 0 and byte_size(bytes) <= remaining ->
        read_chunks(adapter, lease, index + 1, remaining - byte_size(bytes), [bytes | chunks])

      {:error, _} = error ->
        error

      _ ->
        {:error, Error.new(:integrity_failure)}
    end
  end

  defp revoke(adapter, lease) do
    case call(adapter, :revoke, [lease]) do
      :ok -> :ok
      _ -> throw(:document_source_cleanup_failed)
    end
  catch
    :exit, {reason, {GenServer, :call, [^lease, :revoke, :infinity]}}
    when reason in [:noproc, :normal] and is_pid(lease) and node(lease) == node() ->
      :ok
  end

  defp extractor(context, source) do
    case Map.fetch(context.document_extractors, source.media_type) do
      {:ok, {adapter, name, format}}
      when is_binary(name) and is_integer(format) and format > 0 ->
        if source.state == :pending or
             {source.adapter_name, source.format_version} == {name, format} do
          {:ok, adapter, name, format}
        else
          {:error, Error.new(:conflict)}
        end

      _ ->
        {:error, Error.new(:invalid)}
    end
  end

  defp extract(adapter, bytes) do
    call(adapter, :extract, [bytes])
  rescue
    _ -> {:error, {:failed, "extractor_failed"}}
  catch
    _, _ -> {:error, {:failed, "extractor_failed"}}
  end

  defp completion(envelope, source, attempt, extraction) do
    identity = %{
      resource_id: source.resource_id,
      resource_version_id: source.resource_version_id,
      owner_scope_id: envelope.vault_id,
      classification: :private
    }

    attrs =
      Map.merge(identity, %{
        generation: attempt.generation,
        adapter_name: attempt.adapter_name,
        format_version: attempt.format_version,
        finished_at: DateTime.utc_now(),
        media_type: source.media_type
      })

    result =
      with {:ok, blocks} when is_list(blocks) <- extraction,
           {:ok, fragments} <- DocumentFragmentation.build(identity, source.media_type, blocks) do
        {:ready, fragments}
      else
        reason -> outcome(reason)
      end

    case result do
      {:ready, fragments} ->
        DocumentCompletion.new(
          Map.merge(attrs, %{
            outcome: :ready,
            fragments: fragments,
            extracted_text_digest: :crypto.hash(:sha256, Enum.map(fragments, & &1.text))
          })
        )

      {state, code} ->
        DocumentCompletion.new(Map.merge(attrs, %{outcome: state, failure_code: code}))
    end
  rescue
    _ -> failed_completion(envelope, source, attempt)
  catch
    _, _ -> failed_completion(envelope, source, attempt)
  end

  defp failed_completion(envelope, source, attempt) do
    DocumentCompletion.new(%{
      resource_id: source.resource_id,
      resource_version_id: source.resource_version_id,
      owner_scope_id: envelope.vault_id,
      classification: :private,
      generation: attempt.generation,
      adapter_name: attempt.adapter_name,
      format_version: attempt.format_version,
      finished_at: DateTime.utc_now(),
      media_type: source.media_type,
      outcome: :failed,
      failure_code: "extractor_failed"
    })
  end

  defp outcome({:error, {:unsupported, code}}) when code in @unsupported,
    do: {:unsupported, code}

  defp outcome({:error, {:unsupported, "source_too_large"}}),
    do: {:unsupported, "input_too_large"}

  defp outcome({:error, {:unsupported, "page_limit_exceeded"}}), do: {:unsupported, "page_limit"}
  defp outcome({:error, {:failed, "extractor_timeout"}}), do: {:failed, "timeout"}
  defp outcome(_), do: {:failed, "extractor_failed"}

  defp authorize(context, envelope) do
    context.transact.([], fn repo ->
      call(context.authorize, :check_job, [context.authorization, repo, envelope])
    end)
  end

  defp validate_envelope(envelope) do
    with true <- envelope.expected_entity_revision < @max_revision,
         true <- envelope.principal_authorization_epoch <= @max_revision,
         true <- envelope.vault_authorization_epoch <= @max_revision,
         {:ok, encoded} <- EnvelopeCodec.encode(envelope),
         {:ok, ^envelope} <- EnvelopeCodec.decode(encoded) do
      :ok
    else
      _ -> {:error, Error.new(:invalid)}
    end
  end

  defp validate_context(context) do
    required = [
      :document_worker,
      :authorization,
      :authorize,
      :custodian,
      :document_source_lease,
      :document_extractors
    ]

    if Enum.all?(required, &(Map.get(context, &1) not in [nil, false])) and
         is_map(context.document_extractors) and is_function(Map.get(context, :transact), 2),
       do: :ok,
       else: {:error, Error.new(:invalid)}
  end

  defp validate_source(%{source_byte_size: size, source_digest: digest})
       when is_integer(size) and size in 0..@source_limit and
              is_binary(digest) and byte_size(digest) == 32,
       do: :ok

  defp validate_source(_), do: {:error, Error.new(:integrity_failure)}

  defp sanitize_result({:error, %Error{} = error}), do: {:error, sanitize_error(error)}
  defp sanitize_result({:ok, _} = result), do: result
  defp sanitize_result({:snooze, 60} = result), do: result
  defp sanitize_result(_), do: unavailable()

  defp sanitize_error(%Error{code: code, retryable?: retryable?}) do
    if code in Error.codes() and is_boolean(retryable?),
      do: Error.new(code, retryable?: retryable?),
      else: Error.new(:storage_unavailable, retryable?: true)
  end

  defp unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}

  defp call(module, function, arguments) when is_atom(module) and not is_nil(module),
    do: apply(module, function, arguments)

  defp call({module, adapter_context}, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, [adapter_context | arguments])
end
```

Read semantics are deliberate: consume positive authenticated data records at sequential indices until exactly the trusted byte length is consumed. The descriptor contains no container chunk size, so the Runtime worker does not assume one. Reject zero progress, oversized records, errors, wrong total length, or a mismatching final SHA-256. For nonempty input this proves every expected plaintext data record plus pin equality; it does not claim final-record/container authentication. Empty input must complete the dedicated storage-authentication operation before its digest comparison.

The lease is revoked in cleanup before progress, claim, or extraction. The empty operation's normal termination can race the subsequent revoke call: only normal/noproc exits carrying the exact local lease PID, GenServer.call, :revoke, and :infinity are accepted as already closed. Arbitrary callback exits, a different PID/operation/timeout, and shutdown exits prevent claim/extraction. A fresh invocation rereads from zero. Same-job resume uses the existing SQL deadline. No transaction encloses read, hash, fragmentation, or external extraction.

The production extractor identities intentionally match existing Runtime.Documents.Mutate defaults. Exact codec round-trip rejects extra IDs/content/owner overrides; live Authorize.check_job runs only inside the context's short scoped transaction. DocumentWorkerRepository independently repeats live authority and durable-event fences for every operation.

PDF adapter codes map explicitly to Core's existing allowlist: source_too_large to input_too_large; page_limit_exceeded to page_limit; extractor_timeout to timeout. Unknown output and raised/thrown extractor diagnostics become failed/extractor_failed. Core validates fragments before the outcome write. Storage errors/public errors retain only allowlisted code and retryability, clearing message/details.

## A3: Additive production wiring

**Files:** Modify `apps/singularity_runtime/lib/singularity/runtime/application.ex` and `apps/singularity_runtime/lib/singularity/runtime/job_dispatcher.ex`.

- [x] After main GO, apply this complete patch from the worktree root. Each hunk only adds a contiguous block at the frozen-byte guard's exact anchor; no original line is removed or changed.

```diff
*** Begin Patch
*** Update File: apps/singularity_runtime/lib/singularity/runtime/application.ex
@@
+  alias Singularity.Ingest.Documents.{Markdown, PDF, Text}
   alias Singularity.Runtime.AuthorizationDependencies
@@
   alias Singularity.Storage.Postgres.BackupRepository
+  alias Singularity.Storage.Postgres.DocumentWorkerRepository
   alias Singularity.Storage.Postgres.NoteProjectionReconciler
@@
         {LocalDestination,
          %{backup_root: Application.fetch_env!(:singularity_storage, :backup_root)}},
+      document_worker: DocumentWorkerRepository,
+      document_extractors: %{
+        "text/plain" => {Text, "plain_text", 1},
+        "text/markdown" => {Markdown, "markdown", 1},
+        "application/pdf" => {PDF, "poppler_text", 1}
+      },
       exporter: Exporter,
*** Update File: apps/singularity_runtime/lib/singularity/runtime/job_dispatcher.ex
@@
   alias Singularity.Runtime.BackupVault
+  alias Singularity.Runtime.Documents.Extract
+  alias Singularity.Runtime.DownloadLease
   alias Singularity.Runtime.KeyCustodian
@@
       custodian: custody_adapter(dependencies.authorization.custodian),
+      document_source_lease: DownloadLease,
       job_progress: Progress,
@@
+  def handle(context, %{job_type: "document_extract"} = envelope),
+    do: Extract.run(context, envelope)
+
   def handle(_context, _envelope), do: {:error, Error.new(:job_failed)}
@@
+  @impl true
+  def handle_failure(
+        context,
+        %JobEnvelope{job_type: "document_extract"} = envelope,
+        %Error{} = failure,
+        attempt
+      )
+      when is_map(context),
+      do: Extract.record_exhaustion(context, envelope, failure, attempt)
+
   @impl true
   def handle_failure(
         context,
         %JobEnvelope{job_type: "asset_metadata"} = envelope,
*** End Patch
```

The new callback performs sanitized authorization and delegates to DocumentWorkerRepository.record_exhaustion/4. It is invoked only through GenericWorker's existing terminal callback dispatch in production. Do not add another exhaustion trigger to Extract.run/2, interpret runner counters as generation, or modify GenericWorker. Typed nonretryable failures remain immediate terminal callbacks; retryable failures invoke it only on their final positive retry budget; snoozes never invoke it.

## A4: Verify complete production composition

- [x] Format only the owned files:

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix format apps/singularity_runtime/lib/singularity/runtime/documents/extract.ex apps/singularity_runtime/lib/singularity/runtime/job_dispatcher.ex apps/singularity_runtime/lib/singularity/runtime/application.ex apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs
```

- [x] Run the focused A file and unchanged regressions:

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_unlock_resume_test.exs apps/singularity_runtime/test/singularity/runtime/job_dispatcher_asset_events_test.exs apps/singularity_runtime/test/singularity/runtime/application_test.exs --seed 1208
```

Expected: all executed A/old unit contracts pass; the old integration exclusions remain explicitly reported. This is unit evidence, not real WorkerRepo/custody qualification.

- [x] Once main has added exact approved architecture allowances, run the unchanged assertions plus the complete new additions:

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs --seed 1208
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix xref graph --format cycles --fail-above 0
git diff --check
```

Expected: architecture contract passes with every historical assertion preserved; zero xref cycles; no whitespace errors. A new failure outside scope is reported and stops affected work.

- [x] Inspect the exact diff and confirm only the owned production paths/test/plan changed, plus main-owned documented changes. Record actual commands, counts, exclusions, risks, and no Vault feature work. No worker commits.

A implementation checkpoint: initial GREEN had three new-test provenance-accessor
failures. Five accesses were corrected to the established `locator.fields` shape,
preserving all expected values; no production repair was needed. Rerun seed1208
passed 82 reported Runtime tests,17 excluded,65 executed,0 failures, plus15
architecture tests,0 failures. Xref found no cycles; whitespace and embedded
source/test byte comparisons passed. Main independently reran the combined
Runtime/architecture command with the same results. One successful test-harness
repair round; zero failed production repair rounds and zero Astra attempts.
Independent read-only spec review then quality review returned SPEC_COMPLIANT
and QUALITY_APPROVED, respectively, both with zero findings. Mandatory B/C are
not established by these unit results or bounded A reviews.

## Mandatory B coverage ledger: actual source/claim/death composition

B requires its own complete-code test plan before edits, using the existing production adapters and real encrypted local storage. Administrative fixture writes are separate from the verified WorkerScope calls. Use full existing KnowledgeFixtures/custody fixture patterns; never grant WorkerRepo temporary privileges, replace WorkerRepo, or synthesize partial production canonical values. Every verified invocation passes a real retained outbox event and actual WorkerScope context.

| Contract | B evidence required |
| --- | --- |
| Real text/Markdown/multipage PDF ready | Real custody plus WorkerRepository persistence; ordered provenance and deterministic fragments/digest for equal source/version/adapter. |
| Empty authentication | Real valid empty object performs authenticate_empty_document_source before claim; missing/corrupt header/final record fails with pending generation zero and no extractor. |
| Terminal replay | Ready/failed/unsupported duplicate returns only bounded receipt with no lease/read or text exposure. |
| Strict envelope/authority | Malformed envelope, injected owner, extra IDs, stale epochs, wrong retained event/scope fail under actual WorkerRepo without byte reads or mutation. |
| Locked initial custody | pending generation zero, preserving waiting state, snooze60, actual existing unlock wake, resume running, ready. |
| Existing v4 progress | Byte-for-byte checkpoint version/revision/JSON preservation through waiting and resumed running; no generic Progress reset. |
| Progress persistence failure | Real storage error propagates sanitized; never claims saved wake state on failure. |
| Pin integrity | Full length and SHA mismatch fail before claim with no attempt/extractor; actual data authentication failure behaves safely. |
| Partial-read worker death | Owned worker killed at bounded reader barrier before claim, monitor termination/reader cleanup, restart starts index zero and obtains whole identical digest. |
| Complete-read worker death | Kill at revoke/progress barrier after whole read but before claim; restart again authenticates the whole identical source; pending generation remains zero. |
| Claimed worker death | Kill at extractor barrier, restart resumes exact job/generation/adapter/format and proves the original DB deadline is unchanged. |
| Source Asset deletion | Real retained pin still composes describe → lease → digest → claim → complete after Asset tombstone. |
| Document delete before claim | Barrier after source read/before claim, delete Document, release, claim denied without extractor or fragments. |

Use bounded message barriers and process monitors, never arbitrary sleeps. Own and terminate all created Tasks/processes/readers. Preserve borrowed PostgreSQL services. Source read and extraction assertions prove no SQL transaction spans plaintext work.

Required B command (after its complete test code exists):

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs --seed 1208
```

The integration alias sets MIX_ENV=test and an isolated database/storage root. Plain mix test does not configure the required integration environment. Capture the exact printed names and prove both are absent after the alias completes. Do not infer cleanup from exit code alone.

## Mandatory C coverage ledger: actual outcomes, fences, exhaustion, privacy

C requires a complete-code plan before edits and depends on B fixtures/real composition.

| Contract | C evidence required |
| --- | --- |
| Deterministic unsupported | Actual invalid UTF-8/malformed/encrypted/no-text PDF, plus source/output/page/fragment caps, persist only allowlisted unsupported codes. |
| Transient extraction | Timeout/transient tool error or raised/thrown private diagnostic persists failed/timeout or failed/extractor_failed with no content details. |
| Existing-claim custody/storage loss | Described extracting attempt that loses custody/reads persists failed/extractor_failed without re-claim or deadline extension; SQL still independently fences failure. |
| Post-claim persistence failure | Sanitized storage failure returned; no partial terminal or fragments; existing terminal callback/recovery remains responsible. |
| Tombstone after claim | Both ready completion and failed completion may finish exact claimed job after delete; ordinary public reads stay hidden. |
| Recovery staleness | Actual expiry/recovery advances fence; old claim, complete, fail, and exhaustion cannot overwrite current generation. |
| Manual retry staleness | Actual eligible retry creates new retained event/fence; original job's outcomes/exhaustion remain stale. |
| Restore staleness | Actual restore/pending or eligible outcome scheduling fences old job; ready is not reopened. |
| Active exhaustion only | Real GenericWorker terminal dispatch records failed only for the matching unexpired active job/generation, for typed nonretryable immediate and retryable final cases. |
| Unchanged exhaustion targets | Pending locked, ready, failed/unsupported terminal, expired, recovered, and another logical job remain unchanged; authority/storage failures are not swallowed. |
| Nonterminal retry/snooze | Actual GenericWorker nonfinal retryable error invokes no terminal hook; snooze invokes no hook; existing Oban Basic acknowledgement restores attempt and leaves max_attempts unchanged; wake may shorten60 to1. |
| Atomic outcomes/no search | Invalid fragment set/final storage failure leaves no partial fragments; every failed attempt leaves no fragment/search projection rows; exact replay remains idempotent. |
| Actual privacy canaries | Capture real application logs, telemetry metadata, and public errors through source/extractor/SQL/runner failures; source/title/locator/tool output/SQL parameters remain absent from logs/events/progress/Oban/outbox/audit. |

Required C commands after its complete test code exists:

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_unlock_resume_test.exs apps/singularity_runtime/test/singularity/runtime/job_dispatcher_asset_events_test.exs apps/singularity_runtime/test/singularity/runtime/application_test.exs --seed 1208
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_unlock_resume_test.exs apps/singularity_runtime/test/singularity/runtime/job_dispatcher_asset_events_test.exs apps/singularity_runtime/test/singularity/runtime/application_test.exs --seed 1208
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs --seed 1208
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix xref graph --format cycles --fail-above 0
git diff --check
```

Only after A+B+C and required regressions pass can main review Task 12 completion. Full Phase 2 acceptance additionally requires its complete README verification gate and checklist; this bounded task does not claim that gate or E2E acceptance.

## Stop and recovery protocol

- [ ] Preserve all pre-existing/main-owned work. Do not reset/stash/clean, commit, push, or alter unowned processes.
- [ ] On an internal dependency blocker, follow repository issue routing and stop that task; do not hide it behind a local workaround.
- [ ] Count production repair-and-validation rounds cumulatively from zero; initial expected RED is not a repair. After two unsuccessful rounds, stop edits and return evidence to main for routing.
- [ ] Before any checkpoint/handoff, confirm owned commands finished and the Mix slot is released. Record exact worktree/baseline, changed paths, verification results, cleanup, remaining B/C coverage, and no Vault changes.
