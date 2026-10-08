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

defmodule Singularity.Runtime.DocumentSourceIntegrationSupport do
  import ExUnit.Assertions
  import Singularity.Storage.DataCase, only: [query!: 3]

  alias Singularity.Core.{
    DocumentCompletion,
    DocumentFragmentation,
    JobEnvelope,
    ObjectRef,
    SourceLocator
  }

  alias Singularity.Ingest.Documents.{Markdown, PDF, Text}

  alias Singularity.Runtime.{
    AuthorizationDependencies,
    Authorize,
    CustodyReader,
    KeyCustodian,
    KeyLease,
    KeyLeaseSupervisor
  }

  alias Singularity.Runtime.Documents.Extract

  alias Singularity.Storage.{
    Fixtures,
    KnowledgeFixtures,
    LocalFilesystemAdapter,
    MigrationRepo,
    ScopedRepo,
    WorkerRepo
  }

  alias Singularity.Storage.Crypto.{ChunkedAEAD, Format, KeyWrapper}
  alias Singularity.Storage.Jobs.{EnvelopeCodec, WorkerScope}
  alias Singularity.Storage.Local.PathGuard

  alias Singularity.Storage.Postgres.{
    CustodyRepository,
    DocumentWorkerRepository,
    IdentityRepository
  }

  defmodule Probe do
    def start_link(owner),
      do: Agent.start_link(fn -> %{owner: owner, events: [], barriers: %{}} end)

    def barrier(probe, key) do
      token = make_ref()
      Agent.update(probe, &put_in(&1.barriers[key], token))
      token
    end

    def event(probe, key, value) do
      caller = self()

      {owner, token} =
        Agent.get_and_update(probe, fn state ->
          {token, barriers} = Map.pop(state.barriers, key)

          {{state.owner, token},
           %{state | barriers: barriers, events: state.events ++ [{key, caller, value}]}}
        end)

      if token do
        send(owner, {probe, :barrier, key, caller, token, value})

        receive do
          {^token, :continue} -> :ok
        after
          5_000 -> raise "Document integration barrier expired"
        end
      end

      :ok
    end

    def events(probe), do: Agent.get(probe, & &1.events)
    def clear(probe), do: Agent.update(probe, &%{&1 | events: []})
  end

  defmodule Reader do
    alias Singularity.Runtime.CustodyReader
    alias Singularity.Runtime.DocumentSourceIntegrationSupport.Probe
    alias Singularity.Storage.WorkerRepo

    def read_chunk(context, binding, index) do
      result = CustodyReader.read_chunk(context, binding, index)

      summary =
        case result do
          {:ok, bytes} -> %{size: byte_size(bytes), digest: :crypto.hash(:sha256, bytes)}
          {:error, _} -> :error
        end

      Probe.event(context.b_probe, {:reader_after, index}, %{
        summary: summary,
        transaction?: WorkerRepo.in_transaction?()
      })

      result
    end

    def read_range(context, binding, range) do
      result = CustodyReader.read_range(context, binding, range)

      Probe.event(context.b_probe, :reader_empty_after, %{
        result: if(result == {:ok, ""}, do: :authenticated_empty, else: :error),
        transaction?: WorkerRepo.in_transaction?()
      })

      result
    end
  end

  defmodule Custodian do
    alias Singularity.Runtime.KeyCustodian
    alias Singularity.Runtime.DocumentSourceIntegrationSupport.Probe

    def lease(%{probe: probe, pid: pid}, request) do
      result = KeyCustodian.lease(pid, request)
      Probe.event(probe, :leased, result)
      result
    end
  end

  defmodule Lease do
    alias Singularity.Runtime.DownloadLease
    alias Singularity.Runtime.DocumentSourceIntegrationSupport.Probe
    alias Singularity.Storage.WorkerRepo

    def read_document_chunk(probe, lease, index) do
      false = WorkerRepo.in_transaction?()
      result = DownloadLease.read_document_chunk(lease, index)

      Probe.event(
        probe,
        {:delivered, index},
        case result do
          {:ok, bytes} -> %{size: byte_size(bytes), digest: :crypto.hash(:sha256, bytes)}
          {:error, _} -> :error
        end
      )

      result
    end

    def authenticate_empty_document_source(probe, lease) do
      false = WorkerRepo.in_transaction?()
      result = DownloadLease.authenticate_empty_document_source(lease)
      Probe.event(probe, :empty_authenticated, result)
      result
    end

    def revoke(probe, lease) do
      false = WorkerRepo.in_transaction?()
      result = DownloadLease.revoke(lease)
      Probe.event(probe, :revoked, %{lease: lease, result: result})
      result
    end
  end

  defmodule Worker do
    alias Singularity.Runtime.DocumentSourceIntegrationSupport.Probe
    alias Singularity.Storage.{DataCase, WorkerRepo}
    alias Singularity.Storage.Postgres.DocumentWorkerRepository

    def describe(probe, context, envelope) do
      result = DocumentWorkerRepository.describe(context, envelope)
      Probe.event(probe, :described, result)
      result
    end

    def put_progress_state(probe, context, envelope, state) do
      false = WorkerRepo.in_transaction?()

      context =
        if Map.get(context, :b_fail_progress?, false) do
          Map.put(context, :transact, fn options, phase ->
            context.transact.(options, fn repo ->
              result = phase.(repo)
              DataCase.query!(repo, "SELECT runtime_b_private_progress_failure()", [])
              result
            end)
          end)
        else
          context
        end

      result = DocumentWorkerRepository.put_progress_state(context, envelope, state)
      Probe.event(probe, {:progress, state}, result)
      result
    end

    def claim(probe, context, envelope, adapter, format) do
      false = WorkerRepo.in_transaction?()
      Probe.event(probe, :claim_before, {adapter, format})
      result = DocumentWorkerRepository.claim(context, envelope, adapter, format)
      Probe.event(probe, :claimed, result)
      result
    end

    def complete(probe, context, envelope, source, attempt, completion) do
      false = WorkerRepo.in_transaction?()
      result = DocumentWorkerRepository.complete(context, envelope, source, attempt, completion)
      Probe.event(probe, :completed, result)
      result
    end
  end

  defmodule Extractor do
    alias Singularity.Runtime.DocumentSourceIntegrationSupport.Probe
    alias Singularity.Storage.WorkerRepo

    def extract(%{probe: probe, module: module}, bytes) do
      true = WorkerRepo.checked_out?()
      false = WorkerRepo.in_transaction?()
      result = module.extract(bytes)

      Probe.event(probe, :extracted, %{
        digest: :crypto.hash(:sha256, bytes),
        size: byte_size(bytes),
        module: module
      })

      result
    end
  end

  defmodule Wake do
    alias Singularity.Storage.Jobs.ObanAdapter

    def wake_waiting(name, %{vault_id: owner, limit: limit}) do
      ObanAdapter.wake_vault(%{oban_name: name, limit: limit}, owner)
    end
  end

  def setup(context) do
    fixture =
      source_fixture!(
        context.tmp_dir,
        Map.get(context, :plaintext, "first\n\nsecond\n"),
        Map.get(context, :media_type, "text/plain"),
        Map.get(context, :pin, :matching)
      )

    probe =
      ExUnit.Callbacks.start_supervised!(%{id: make_ref(), start: {Probe, :start_link, [self()]}})

    supervisor =
      ExUnit.Callbacks.start_supervised!({KeyLeaseSupervisor, name: nil}, id: make_ref())

    custody = %{
      key_wrapper: KeyWrapper,
      repo: WorkerRepo,
      repository_adapter: CustodyRepository,
      scope: ScopedRepo,
      b_probe: probe,
      storage: %{adapter: LocalFilesystemAdapter, context: %{root: context.tmp_dir}}
    }

    wake =
      if Map.get(context, :wake?, false) do
        name = Singularity.Runtime.DocumentSourceIntegrationSupport.OwnedOban

        ExUnit.Callbacks.start_supervised!(
          {Oban,
           name: name,
           repo: WorkerRepo,
           prefix: "jobs",
           testing: :manual,
           queues: false,
           plugins: false},
          id: make_ref()
        )

        {Wake, name}
      else
        nil
      end

    custodian =
      ExUnit.Callbacks.start_supervised!(
        {KeyCustodian,
         %{
           authorization: CustodyReader,
           clock: CustodyReader,
           context: custody,
           idle_lock: fn _ -> :ok end,
           key_reader: Reader,
           object_key_loader: CustodyReader,
           lease_supervisor: supervisor,
           wake_waiting: wake
         }},
        id: make_ref()
      )

    session =
      Map.merge(
        Map.take(
          fixture,
          [
            :session_id,
            :principal_id,
            :vault_id,
            :key_domain_id,
            :domain_key_version_id,
            :domain_key
          ]
        ),
        %{
          principal_authorization_epoch: 0,
          vault_authorization_epoch: 0,
          expires_at: DateTime.add(DateTime.utc_now(), 300, :second),
          domain_key_generation: 1,
          domain_classification: :private,
          domain_dedup_key: :crypto.strong_rand_bytes(32),
          vault_key: :crypto.strong_rand_bytes(32)
        }
      )

    fixture =
      Map.merge(fixture, %{
        probe: probe,
        custodian: custodian,
        session: session,
        lease_supervisor: supervisor,
        wake: wake
      })

    unless Map.get(context, :locked?, false), do: activate!(fixture)
    {:ok, fixture: fixture}
  end

  def activate!(fixture) do
    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "UPDATE core.vaults SET locked=false WHERE id=$1", [
        fixture.source.vault_id
      ])
    end)

    assert {:ok, pending} = KeyCustodian.prepare_unlock(fixture.custodian, fixture.session)
    assert :ok = KeyCustodian.activate_unlock(fixture.custodian, pending)
    :ok
  end

  def run(fixture, options \\ []) do
    envelope = Keyword.get(options, :envelope, fixture.envelope)

    WorkerScope.run(envelope, fn scope ->
      assert scope.repo_handle === WorkerRepo
      assert WorkerRepo.checked_out?()
      refute WorkerRepo.in_transaction?()

      authorization = %AuthorizationDependencies{
        store: IdentityRepository,
        custodian: {KeyCustodian, fixture.custodian}
      }

      extractors =
        Map.new(
          [
            {"text/plain", Text, "plain_text"},
            {"text/markdown", Markdown, "markdown"},
            {"application/pdf", PDF, "poppler_text"}
          ],
          fn {type, module, name} ->
            {type, {{Extractor, %{probe: fixture.probe, module: module}}, name, 1}}
          end
        )

      context =
        Map.merge(scope, %{
          authorize: Authorize,
          authorization: authorization,
          document_worker: {Worker, fixture.probe},
          custodian: {Custodian, %{probe: fixture.probe, pid: fixture.custodian}},
          document_source_lease: {Lease, fixture.probe},
          document_extractors: extractors,
          b_fail_progress?: Keyword.get(options, :fail_progress?, false)
        })

      Extract.run(context, envelope)
    end)
  end

  def spawn_run(fixture, options \\ []) do
    owner = self()
    token = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result = run(fixture, options)
        send(owner, {token, :result, result})
      end)

    ExUnit.Callbacks.on_exit(fn -> stop_owned(pid) end)
    %{pid: pid, monitor: monitor, token: token}
  end

  def stop_owned(pid) do
    monitor = Process.monitor(pid)
    if Process.alive?(pid), do: Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _} -> :ok
    after
      5_000 -> raise "owned Document integration process did not terminate"
    end
  end

  def kill_runner!(runner) do
    %{pid: pid, monitor: monitor, token: token} = runner
    Process.exit(runner.pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000
    refute_receive {^token, :result, _}, 0
  end

  def await_result!(runner) do
    assert_receive {token, :result, result} when token == runner.token, 5_000

    assert_receive {:DOWN, monitor, :process, pid, :normal}
                   when monitor == runner.monitor and pid == runner.pid,
                   5_000

    result
  end

  def barrier!(fixture, key), do: Probe.barrier(fixture.probe, key)

  def await_barrier!(fixture, key, token) do
    probe = fixture.probe
    assert_receive {^probe, :barrier, ^key, pid, ^token, value}, 5_000
    {pid, value}
  end

  def events(fixture), do: Probe.events(fixture.probe)
  def clear(fixture), do: Probe.clear(fixture.probe)
  def keys(fixture), do: Enum.map(events(fixture), &elem(&1, 0))

  def pending!(fixture) do
    assert [["pending", 0, nil, nil, nil, nil, nil, nil]] = attempt_rows(fixture)
    assert fragments(fixture) == []
  end

  def attempt_rows(fixture) do
    owner_query(
      """
      SELECT state,attempt_generation,attempt_job_id,extraction_adapter,extraction_format,
        attempt_started_at,attempt_deadline_at,extracted_text_digest
      FROM content.document_versions WHERE resource_version_id=$1
      """,
      [fixture.document.resource_version_id]
    ).rows
  end

  def fragments(fixture) do
    owner_query(
      """
      SELECT id,ordinal,text,digest,locator FROM content.document_fragments
      WHERE resource_version_id=$1 ORDER BY ordinal
      """,
      [fixture.document.resource_version_id]
    ).rows
  end

  def progress(fixture) do
    owner_query(
      """
      SELECT checkpoint_version,processing_revision,checkpoint::text,state
      FROM jobs.job_progress WHERE submission_id=$1
      """,
      [Ecto.UUID.dump!(fixture.envelope.job_id)]
    ).rows
  end

  def tombstone!(fixture, target) do
    id =
      case target do
        :asset -> fixture.source.resource_id
        :document -> fixture.document.resource_id
      end

    assert %{num_rows: 1} =
             owner_query(
               "UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id=$1",
               [id]
             )
  end

  def owner_query(sql, params),
    do: Fixtures.with_owner(fn -> query!(MigrationRepo, sql, params) end)

  def expected_fragments!(fixture, adapter) do
    assert {:ok, blocks} = adapter.extract(fixture.plaintext)

    identity = %{
      resource_id: fixture.envelope.payload["resource_id"],
      resource_version_id: fixture.envelope.payload["resource_version_id"],
      owner_scope_id: fixture.vault_id,
      classification: :private
    }

    assert {:ok, fragments} = DocumentFragmentation.build(identity, fixture.media_type, blocks)

    Enum.map(fragments, fn fragment ->
      [
        fragment.fragment_id,
        fragment.ordinal,
        fragment.text,
        fragment.digest,
        SourceLocator.to_map(fragment.locator)
      ]
    end)
  end

  def ready!(fixture, adapter) do
    assert {:ok, receipt} = run(fixture)

    assert receipt == %{
             resource_id: fixture.envelope.payload["resource_id"],
             resource_version_id: fixture.envelope.payload["resource_version_id"],
             job_id: fixture.envelope.job_id,
             generation: 1,
             state: :ready
           }

    assert fragments(fixture) == expected_fragments!(fixture, adapter)
    assert [["ready", 1, job, name, 1, started, deadline, digest]] = attempt_rows(fixture)
    assert job == Ecto.UUID.dump!(fixture.envelope.job_id)
    assert name in ["plain_text", "markdown", "poppler_text"]
    assert DateTime.diff(deadline, started, :microsecond) == 180_000_000
    texts = Enum.map(fragments(fixture), fn [_, _, text, _, _] -> text end)
    assert digest == :crypto.hash(:sha256, texts)

    assert Enum.any?(events(fixture), fn
             {:extracted, _, %{digest: hash, size: size, module: ^adapter}} ->
               hash == :crypto.hash(:sha256, fixture.plaintext) and
                 size == byte_size(fixture.plaintext)

             _ ->
               false
           end)

    assert DynamicSupervisor.which_children(fixture.lease_supervisor) == []
    receipt
  end

  def seed_terminal!(fixture, state) when state in [:failed, :unsupported] do
    WorkerScope.run(fixture.envelope, fn context ->
      assert {:ok, {:source, source}} =
               DocumentWorkerRepository.describe(context, fixture.envelope)

      assert {:ok, attempt} =
               DocumentWorkerRepository.claim(context, fixture.envelope, "plain_text", 1)

      assert {:ok, completion} =
               DocumentCompletion.new(%{
                 resource_id: source.resource_id,
                 resource_version_id: source.resource_version_id,
                 owner_scope_id: fixture.vault_id,
                 classification: :private,
                 generation: attempt.generation,
                 adapter_name: attempt.adapter_name,
                 format_version: attempt.format_version,
                 media_type: fixture.media_type,
                 finished_at: DateTime.utc_now(),
                 outcome: state,
                 failure_code: if(state == :failed, do: "extractor_failed", else: "invalid_utf8")
               })

      assert {:ok, receipt} =
               DocumentWorkerRepository.complete(
                 context,
                 fixture.envelope,
                 source,
                 attempt,
                 completion
               )

      receipt
    end)
  end

  def terminal_receipt!(fixture, :ready), do: ready!(fixture, Text)

  def terminal_receipt!(fixture, state) when state in [:failed, :unsupported],
    do: seed_terminal!(fixture, state)

  def seed_v4!(fixture) do
    binding = Map.delete(fixture.request, :purpose)
    checkpoint = KeyLease.document_checkpoint(binding, 1)

    assert %{num_rows: 1} =
             owner_query(
               """
               INSERT INTO jobs.job_progress(id,vault_id,submission_id,classification,state,
                 processing_revision,checkpoint_version,checkpoint,inserted_at,updated_at)
               VALUES($1,$2,$3,'private','running',37,4,$4::jsonb,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)
               """,
               [
                 KnowledgeFixtures.uuid(),
                 fixture.source.vault_id,
                 Ecto.UUID.dump!(fixture.envelope.job_id),
                 checkpoint
               ]
             )

    progress(fixture)
  end

  def corrupt!(fixture, kind) do
    case kind do
      :missing ->
        File.rename!(fixture.path, fixture.path <> ".missing")

      :truncated ->
        File.chmod!(fixture.path, 0o600)
        bytes = File.read!(fixture.path)
        cut = Format.header_size() + 8 + 1
        assert cut < byte_size(bytes)
        File.write!(fixture.path, binary_part(bytes, 0, cut))

      kind when kind in [:header, :final, :data] ->
        offset =
          case kind do
            :header -> 0
            :final -> File.stat!(fixture.path).size - 1
            :data -> Format.header_size() + 8
          end

        File.chmod!(fixture.path, 0o600)
        {:ok, io} = :file.open(fixture.path, [:read, :write, :binary])

        try do
          {:ok, <<byte>>} = :file.pread(io, offset, 1)
          :ok = :file.pwrite(io, offset, <<Bitwise.bxor(byte, 1)>>)
          :ok = :file.sync(io)
        after
          :ok = :file.close(io)
        end
    end
  end

  def pdf_bytes do
    File.read!(
      Path.expand(
        "../../../../singularity_ingest/test/fixtures/documents/two_pages.pdf",
        __DIR__
      )
    )
  end

  def restart_bytes, do: :binary.copy(" ", Format.chunk_size()) <> "\nrestart tail\n"

  def source_fixture!(root, plaintext, media_type, pin) do
    %{one: source, two: other} = Fixtures.two_vaults!()

    ids =
      Map.new(
        [:object_id, :key_domain_id, :domain_key_version_id, :vault_key_version_id, :job_id],
        &{&1, Ecto.UUID.generate()}
      )

    vault_id = Ecto.UUID.load!(source.vault_id)
    domain_key = :crypto.strong_rand_bytes(32)
    dek = :crypto.strong_rand_bytes(32)
    lookup = :crypto.strong_rand_bytes(32)

    assert {:ok, ciphertext} =
             ChunkedAEAD.encode(%{
               key: dek,
               plaintext: plaintext,
               chunk_index: 0,
               format_version: Format.format_version(),
               algorithm: Format.algorithm(),
               chunk_size: Format.chunk_size(),
               vault_id: vault_id,
               encryption_domain_id: ids.key_domain_id,
               object_id: ids.object_id
             })

    storage = %{
      root: root,
      vault_namespace: vault_id,
      domain_namespace: ids.key_domain_id,
      lookup_digest: Base.encode16(lookup, case: :lower)
    }

    assert {:ok, stage} = LocalFilesystemAdapter.stage(storage, %{})
    assert :ok = LocalFilesystemAdapter.append_encrypted_chunk(storage, stage, ciphertext)
    assert {:ok, %{sealed?: true}} = LocalFilesystemAdapter.seal_stage(storage, stage, %{})
    object = %ObjectRef{object_id: ids.object_id}
    assert {:ok, ^object} = LocalFilesystemAdapter.finalize(storage, stage, object)

    assert {:ok, path} =
             PathGuard.object_path(root, vault_id, ids.key_domain_id, storage.lookup_digest)

    assert {:ok, wrapper} =
             KeyWrapper.wrap(domain_key, dek, %{
               purpose: :object_dek,
               generation: 1,
               aad: "object:" <> ids.object_id
             })

    digest = :crypto.hash(:sha256, plaintext)

    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "UPDATE core.vaults SET locked=false WHERE id=$1", [source.vault_id])

      query!(
        MigrationRepo,
        "INSERT INTO core.capabilities(id,name) VALUES($1,'asset.read') ON CONFLICT(name) DO NOTHING",
        [KnowledgeFixtures.uuid()]
      )

      query!(
        MigrationRepo,
        "INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name='asset.read'",
        [source.principal_id, source.vault_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO core.vault_key_versions(id,vault_id,generation,state,algorithm,activated_at) VALUES($1,$2,1,'active','aes_256_gcm',CURRENT_TIMESTAMP)",
        [Ecto.UUID.dump!(ids.vault_key_version_id), source.vault_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO core.key_domains(id,vault_id,classification,kind,state) VALUES($1,$2,'private','content','active')",
        [Ecto.UUID.dump!(ids.key_domain_id), source.vault_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO core.domain_key_versions(id,vault_id,key_domain_id,vault_key_version_id,generation,state,algorithm,wrapped_key) VALUES($1,$2,$3,$4,1,'active','aes_256_gcm',$5)",
        [
          Ecto.UUID.dump!(ids.domain_key_version_id),
          source.vault_id,
          Ecto.UUID.dump!(ids.key_domain_id),
          Ecto.UUID.dump!(ids.vault_key_version_id),
          :crypto.strong_rand_bytes(60)
        ]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.asset_objects(id,vault_id,key_domain_id,classification,lookup_digest,ciphertext_hash,plaintext_byte_size,ciphertext_byte_size,storage_ref,format_version,lifecycle) VALUES($1,$2,$3,'private',$4,$5,$6,$7,$8,1,'available')",
        [
          Ecto.UUID.dump!(ids.object_id),
          source.vault_id,
          Ecto.UUID.dump!(ids.key_domain_id),
          lookup,
          :crypto.hash(:sha256, ciphertext),
          byte_size(plaintext),
          byte_size(ciphertext),
          ids.object_id
        ]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.asset_key_envelopes(id,vault_id,asset_object_id,domain_key_version_id,key_domain_id,classification,algorithm,key_generation,wrapped_dek) VALUES($1,$2,$3,$4,$5,'private','aes_256_gcm',1,$6)",
        [
          KnowledgeFixtures.uuid(),
          source.vault_id,
          Ecto.UUID.dump!(ids.object_id),
          Ecto.UUID.dump!(ids.domain_key_version_id),
          Ecto.UUID.dump!(ids.key_domain_id),
          wrapper.encoded
        ]
      )

      query!(
        MigrationRepo,
        "UPDATE content.assets SET state='available',asset_object_id=$1 WHERE id=$2",
        [Ecto.UUID.dump!(ids.object_id), source.asset_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.resource_assets(resource_version_id,asset_id,vault_id,classification) VALUES($1,$2,$3,'private')",
        [source.resource_version_id, source.asset_id, source.vault_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.asset_metadata(id,asset_id,resource_version_id,vault_id,classification,projection_version,original_filename,declared_media_type,detected_media_type,plaintext_byte_size,extraction_state,completed_at) VALUES($1,$2,$3,$4,'private',1,'source',$5,$5,$6,'completed',CURRENT_TIMESTAMP)",
        [
          KnowledgeFixtures.uuid(),
          source.asset_id,
          source.resource_version_id,
          source.vault_id,
          media_type,
          byte_size(plaintext)
        ]
      )
    end)

    source =
      Map.merge(source, %{
        object_id: Ecto.UUID.dump!(ids.object_id),
        digest: digest,
        byte_size: byte_size(plaintext)
      })

    pin_attrs =
      case pin do
        :matching -> %{}
        :wrong_digest -> %{source_digest: :crypto.hash(:sha256, "different immutable original")}
      end

    document = KnowledgeFixtures.document!(source, Map.put(pin_attrs, :media_type, media_type))
    key = "document-extraction:" <> Ecto.UUID.load!(document.resource_version_id)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO core.outbox_events(id,event_type,idempotency_key,vault_id,principal_id,required_capability,principal_authorization_epoch,vault_authorization_epoch,classification,correlation_id,expected_entity_revision,envelope_version,payload,occurred_at) VALUES($1,'document.extraction_requested',$2,$3,$4,'asset.read',0,0,'private',$1,0,1,$5::jsonb,CURRENT_TIMESTAMP)",
        [
          Ecto.UUID.dump!(ids.job_id),
          key,
          source.vault_id,
          source.principal_id,
          %{
            "resource_id" => Ecto.UUID.load!(document.resource_id),
            "resource_version_id" => Ecto.UUID.load!(document.resource_version_id)
          }
        ]
      )

      query!(
        MigrationRepo,
        "INSERT INTO jobs.job_submissions(id,vault_id,outbox_event_id,classification,idempotency_key,job_type) VALUES($1,$2,$1,'private',$3,'document_extract')",
        [Ecto.UUID.dump!(ids.job_id), source.vault_id, key]
      )
    end)

    %{rows: [[job, event_key, owner, principal, pe, oe, correlation, revision, version, payload]]} =
      owner_query(
        "SELECT id,idempotency_key,vault_id,principal_id,principal_authorization_epoch,vault_authorization_epoch,correlation_id,expected_entity_revision,envelope_version,payload FROM core.outbox_events WHERE id=$1",
        [Ecto.UUID.dump!(ids.job_id)]
      )

    assert {:ok, envelope} =
             JobEnvelope.new(%{
               version: version,
               job_id: Ecto.UUID.load!(job),
               job_type: "document_extract",
               idempotency_key: event_key,
               vault_id: Ecto.UUID.load!(owner),
               principal_id: Ecto.UUID.load!(principal),
               required_capability: "asset.read",
               principal_authorization_epoch: pe,
               vault_authorization_epoch: oe,
               classification: :private,
               correlation_id: Ecto.UUID.load!(correlation),
               causation_id: Ecto.UUID.load!(job),
               expected_entity_revision: revision,
               attempt: 1,
               payload: payload
             })

    assert {:ok, encoded} = EnvelopeCodec.encode(envelope)
    assert {:ok, ^envelope} = EnvelopeCodec.decode(encoded)

    request = %{
      purpose: :document_extraction_source,
      access: :worker,
      job_id: envelope.job_id,
      resource_version_id: envelope.payload["resource_version_id"],
      vault_id: envelope.vault_id,
      principal_id: envelope.principal_id,
      required_capability: "asset.read",
      principal_authorization_epoch: pe,
      vault_authorization_epoch: oe,
      object_id: ids.object_id,
      object_generation: 1
    }

    Map.merge(ids, %{
      source: source,
      other: other,
      document: document,
      envelope: envelope,
      request: request,
      path: path,
      plaintext: plaintext,
      media_type: media_type,
      vault_id: envelope.vault_id,
      principal_id: envelope.principal_id,
      session_id: Ecto.UUID.load!(source.session_id),
      domain_key: domain_key,
      root: root
    })
  end
end

defmodule Singularity.Runtime.DocumentSourceReadyIntegrationTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  @moduletag :tmp_dir
  alias Singularity.Ingest.Documents.{Markdown, PDF, Text}
  alias Singularity.Runtime.DocumentSourceIntegrationSupport, as: S
  setup context, do: S.setup(context)

  test "actual WorkerRepo denies direct canonical Document access", %{fixture: f} do
    for operation <- [
          "SELECT resource_version_id FROM content.document_versions LIMIT 0",
          "DELETE FROM content.document_versions WHERE false",
          "UPDATE content.document_versions SET title=title WHERE false",
          "INSERT INTO content.document_versions DEFAULT VALUES"
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
               Ecto.Adapters.SQL.query(WorkerRepo, operation, [], log: false)
    end

    S.pending!(f)
  end

  test "real text persists exact ordered provenance and deterministic fragments", %{fixture: f} do
    receipt = S.ready!(f, Text)

    assert [
             [_, 0, "first", _, %{"kind" => "text", "start_line" => 1, "end_line" => 1}],
             [_, 1, "second", _, %{"kind" => "text", "start_line" => 3, "end_line" => 3}]
           ] = S.fragments(f)

    before = S.fragments(f)
    assert {:ok, ^receipt} = S.run(f)
    assert S.fragments(f) == before
  end

  @tag plaintext: "# One\r\n\r\nCafe\u0301\r\n\r\n## Two\r\nbody\r\n"
  @tag media_type: "text/markdown"
  test "real Markdown preserves normalized heading and source line provenance", %{fixture: f} do
    S.ready!(f, Markdown)

    assert [
             [_, 0, "# One", _, %{"heading_path" => ["One"], "start_line" => 1}],
             [_, 1, "Café", _, %{"heading_path" => ["One"], "start_line" => 3}],
             [_, 2, "## Two", _, %{"heading_path" => ["One", "Two"], "start_line" => 5}],
             [_, 3, "body", _, %{"heading_path" => ["One", "Two"], "start_line" => 6}]
           ] = S.fragments(f)
  end

  @tag plaintext: S.pdf_bytes()
  @tag media_type: "application/pdf"
  test "real multipage Poppler source persists page and character provenance", %{fixture: f} do
    S.ready!(f, PDF)

    assert [
             [
               _,
               0,
               first,
               _,
               %{"kind" => "pdf", "page" => 1, "start_char" => 0, "end_char" => a}
             ],
             [
               _,
               1,
               second,
               _,
               %{"kind" => "pdf", "page" => 2, "start_char" => 0, "end_char" => b}
             ]
           ] = S.fragments(f)

    assert first =~ "First page"
    assert second =~ "Second page"
    assert a > 0 and b > 0
  end

  for terminal <- [:ready, :failed, :unsupported] do
    test "#{terminal} replay returns only receipt without any source access", %{fixture: f} do
      receipt = S.terminal_receipt!(f, unquote(terminal))
      before = {S.attempt_rows(f), S.fragments(f), S.progress(f)}
      S.clear(f)
      File.rename!(f.path, f.path <> ".terminal-replay")
      assert {:ok, ^receipt} = S.run(f)

      assert Enum.sort(Map.keys(receipt)) ==
               Enum.sort(~w(resource_id resource_version_id job_id generation state)a)

      assert S.keys(f) == [:described]
      assert {S.attempt_rows(f), S.fragments(f), S.progress(f)} == before
    end
  end
end

defmodule Singularity.Runtime.DocumentSourceAuthenticationIntegrationTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  @moduletag :tmp_dir
  alias Singularity.Core.Error
  alias Singularity.Runtime.DocumentSourceIntegrationSupport, as: S
  setup context, do: S.setup(context)

  @tag plaintext: ""
  test "valid empty original is authenticated before claim and extraction", %{fixture: f} do
    assert {:ok, %{state: :unsupported, generation: 1}} = S.run(f)

    assert [
             {:described, _, _},
             {:leased, _, {:ok, _}},
             {:reader_empty_after, _, %{result: :authenticated_empty, transaction?: false}},
             {:empty_authenticated, _, :ok},
             {{:progress, :running}, _, {:ok, :saved}},
             {:claim_before, _, _},
             {:claimed, _, {:ok, %{generation: 1}}},
             {:extracted, _, %{size: 0}},
             {:completed, _, {:ok, %{state: :unsupported}}}
           ] = S.events(f)

    assert S.fragments(f) == []
    assert DynamicSupervisor.which_children(f.lease_supervisor) == []
  end

  for corruption <- [:missing, :header, :final] do
    @tag plaintext: ""
    test "#{corruption} empty original fails authentication without attempt or extractor", %{
      fixture: f
    } do
      S.corrupt!(f, unquote(corruption))
      assert {:error, %Error{message: nil, details: %{}}} = S.run(f)
      S.pending!(f)
      refute :claim_before in S.keys(f)
      refute :extracted in S.keys(f)
      assert S.progress(f) == []
      assert DynamicSupervisor.which_children(f.lease_supervisor) == []
    end
  end

  @tag pin: :wrong_digest
  test "wrong immutable digest rejects authenticated plaintext before attempt and extractor", %{
    fixture: f
  } do
    assert {:error, %Error{code: :integrity_failure, message: nil, details: %{}}} = S.run(f)
    assert :leased in S.keys(f)
    assert {:delivered, 0} in S.keys(f)
    S.pending!(f)
    refute :claim_before in S.keys(f)
    refute :extracted in S.keys(f)
    assert S.progress(f) == []
    assert DynamicSupervisor.which_children(f.lease_supervisor) == []
  end

  test "actual object versus pin length mismatch denies descriptor before bytes", %{fixture: f} do
    assert %{num_rows: 1} =
             S.owner_query(
               "UPDATE content.asset_objects SET plaintext_byte_size=plaintext_byte_size+1 WHERE id=$1",
               [f.source.object_id]
             )

    assert {:error, %Error{code: :conflict, message: nil, details: %{}}} = S.run(f)
    refute :leased in S.keys(f)
    refute :claim_before in S.keys(f)
    refute :extracted in S.keys(f)
    S.pending!(f)
  end

  test "actual truncation inside expected data record fails before attempt", %{fixture: f} do
    S.corrupt!(f, :truncated)
    assert {:error, %Error{code: :integrity_failure, message: nil, details: %{}}} = S.run(f)
    assert :leased in S.keys(f)

    assert Enum.any?(S.events(f), fn
             {{:reader_after, 0}, _, %{summary: :error}} -> true
             _ -> false
           end)

    S.pending!(f)
    refute :claim_before in S.keys(f)
    refute :extracted in S.keys(f)
    assert DynamicSupervisor.which_children(f.lease_supervisor) == []
  end

  test "actual data AEAD authentication failure never claims or extracts", %{fixture: f} do
    S.corrupt!(f, :data)
    assert {:error, %Error{code: :integrity_failure, message: nil, details: %{}}} = S.run(f)
    S.pending!(f)

    assert Enum.any?(S.events(f), fn
             {{:reader_after, 0}, _, %{summary: :error}} -> true
             _ -> false
           end)

    refute :claim_before in S.keys(f)
    refute :extracted in S.keys(f)
    assert DynamicSupervisor.which_children(f.lease_supervisor) == []
  end

  test "malformed envelopes, owner injection and extra payload fields deny before bytes", %{
    fixture: f
  } do
    env = f.envelope

    for invalid <- [
          %{
            env
            | payload: %{
                "resource_id" => "not-a-uuid",
                "resource_version_id" => env.payload["resource_version_id"]
              }
          },
          %{env | payload: Map.put(env.payload, "owner_scope_id", f.vault_id)},
          %{env | payload: Map.put(env.payload, "extra", true)},
          Map.put(env, :owner_scope_id, Ecto.UUID.generate()),
          %{env | vault_id: Ecto.UUID.load!(f.other.vault_id)},
          %{env | principal_authorization_epoch: env.principal_authorization_epoch + 1},
          %{env | vault_authorization_epoch: env.vault_authorization_epoch + 1},
          %{env | job_id: Ecto.UUID.generate()},
          %{env | payload: Map.put(env.payload, "resource_version_id", Ecto.UUID.generate())}
        ] do
      S.clear(f)
      assert {:error, %Error{message: nil, details: %{}}} = S.run(f, envelope: invalid)
      refute :leased in S.keys(f)
      refute :claim_before in S.keys(f)
      refute :extracted in S.keys(f)
      S.pending!(f)
    end
  end

  test "coherent other-owner retained event cannot be consumed by original authenticated scope",
       %{fixture: f} do
    other =
      S.source_fixture!(
        Path.join(f.root, "other-owner"),
        "other original",
        "text/plain",
        :matching
      )

    assert {:ok, {:source, %{state: :pending}}} =
             Singularity.Storage.Jobs.WorkerScope.run(other.envelope, fn context ->
               Singularity.Storage.Postgres.DocumentWorkerRepository.describe(
                 context,
                 other.envelope
               )
             end)

    forged = %{
      other.envelope
      | vault_id: f.envelope.vault_id,
        principal_id: f.envelope.principal_id
    }

    assert {:error, %Error{message: nil, details: %{}}} = S.run(f, envelope: forged)
    refute :leased in S.keys(f)
    refute :claim_before in S.keys(f)
    refute :extracted in S.keys(f)
    S.pending!(f)
    S.pending!(other)
  end

  test "constraint-valid alternate-member retained principal and changed creator deny before bytes",
       %{fixture: f} do
    S.owner_query(
      "INSERT INTO core.vault_members(principal_id,vault_id) VALUES($1,$2)",
      [f.other.principal_id, f.source.vault_id]
    )

    S.owner_query(
      "INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name='asset.read'",
      [f.other.principal_id, f.source.vault_id]
    )

    S.owner_query(
      "UPDATE core.outbox_events SET principal_id=$2 WHERE id=$1",
      [Ecto.UUID.dump!(f.envelope.job_id), f.other.principal_id]
    )

    for envelope <- [
          f.envelope,
          %{f.envelope | principal_id: Ecto.UUID.load!(f.other.principal_id)}
        ] do
      S.clear(f)
      assert {:error, %Error{message: nil, details: %{}}} = S.run(f, envelope: envelope)
      refute :leased in S.keys(f)
      refute :claim_before in S.keys(f)
      refute :extracted in S.keys(f)
      S.pending!(f)
    end
  end

  for corruption <- [:extras, :revision, :principal_epoch, :owner_epoch] do
    test "actual retained #{corruption} mismatch denies before lease and mutation", %{fixture: f} do
      {field, value} =
        case unquote(corruption) do
          :extras -> {"payload", Map.put(f.envelope.payload, "extra", true)}
          :revision -> {"expected_entity_revision", 1}
          :principal_epoch -> {"principal_authorization_epoch", 1}
          :owner_epoch -> {"vault_authorization_epoch", 1}
        end

      S.owner_query(
        "UPDATE core.outbox_events SET #{field}=$2 WHERE id=$1",
        [Ecto.UUID.dump!(f.envelope.job_id), value]
      )

      assert {:error, %Error{message: nil, details: %{}}} = S.run(f)
      refute :leased in S.keys(f)
      refute :claim_before in S.keys(f)
      refute :extracted in S.keys(f)
      S.pending!(f)
    end
  end
end

defmodule Singularity.Runtime.DocumentSourceProgressIntegrationTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  @moduletag :tmp_dir
  import ExUnit.CaptureLog
  alias Singularity.Core.Error
  alias Singularity.Ingest.Documents.Text
  alias Singularity.Runtime.DocumentSourceIntegrationSupport, as: S
  alias Singularity.Storage.Jobs.ObanAdapter
  setup context, do: S.setup(context)

  @tag locked?: true
  @tag wake?: true
  test "locked pending work saves waiting, wakes through existing unlock, resumes running and preserves v4",
       %{fixture: f} do
    assert [[4, 37, json, "running"]] = S.seed_v4!(f)
    assert {:ok, runner} = ObanAdapter.submit(%{oban_name: elem(f.wake, 1)}, f.envelope)
    runner = String.to_integer(runner)

    S.owner_query(
      "UPDATE jobs.oban_jobs SET state='scheduled',scheduled_at=CURRENT_TIMESTAMP+INTERVAL '1 hour' WHERE id=$1",
      [runner]
    )

    S.owner_query("UPDATE core.vaults SET locked=true WHERE id=$1", [f.source.vault_id])

    assert {:snooze, 60} = S.run(f)
    S.pending!(f)
    assert [[4, 37, ^json, "waiting_for_unlock"]] = S.progress(f)
    refute :claim_before in S.keys(f)
    refute :extracted in S.keys(f)

    assert S.owner_query(
             "SELECT wake_requested_generation,wake_consumed_generation FROM jobs.job_submissions WHERE id=$1",
             [Ecto.UUID.dump!(f.envelope.job_id)]
           ).rows == [[0, 0]]

    assert :ok = S.activate!(f)

    assert S.owner_query(
             "SELECT wake_requested_generation,wake_consumed_generation FROM jobs.job_submissions WHERE id=$1",
             [Ecto.UUID.dump!(f.envelope.job_id)]
           ).rows == [[1, 1]]

    assert [["available"]] =
             S.owner_query("SELECT state FROM jobs.oban_jobs WHERE id=$1", [runner]).rows

    assert [[4, 37, ^json, "waiting_for_unlock"]] = S.progress(f)

    S.clear(f)
    S.ready!(f, Text)
    assert [[4, 37, ^json, "running"]] = S.progress(f)

    assert {{:progress, :running}, _, {:ok, :saved}} =
             Enum.find(S.events(f), &(elem(&1, 0) == {:progress, :running}))

    assert S.owner_query("SELECT meta FROM jobs.oban_jobs WHERE id=$1", [runner]).rows == [[%{}]]
  end

  for locked <- [true, false] do
    @tag locked?: locked
    test "real #{if locked, do: "waiting", else: "running"} progress SQL failure rolls back and stays sanitized",
         %{fixture: f} do
      before = S.seed_v4!(f)
      state = if unquote(locked), do: :waiting_for_unlock, else: :running

      log =
        capture_log(fn ->
          assert {:error,
                  %Error{code: :storage_unavailable, retryable?: true, message: nil, details: %{}}} =
                   S.run(f, fail_progress?: true)
        end)

      refute log =~ "runtime_b_private_progress_failure"
      assert S.progress(f) == before

      assert {{:progress, ^state}, _, {:error, %Error{code: :storage_unavailable}}} =
               Enum.find(S.events(f), &(elem(&1, 0) == {:progress, state}))

      refute :claim_before in S.keys(f)
      refute :extracted in S.keys(f)
      S.pending!(f)
    end
  end
end

defmodule Singularity.Runtime.DocumentSourceRestartIntegrationTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag plaintext: Singularity.Runtime.DocumentSourceIntegrationSupport.restart_bytes()
  alias Singularity.Ingest.Documents.Text
  alias Singularity.Runtime.DocumentSourceIntegrationSupport, as: S
  setup context, do: S.setup(context)

  test "death fixture spans actual storage records but extracts only the tail", %{fixture: f} do
    assert byte_size(f.plaintext) > 4_194_304

    assert {:ok, [%{text: "restart tail", locator: %{start_line: 2, end_line: 2}}]} =
             Text.extract(f.plaintext)
  end

  test "partial preclaim worker death cleans owned reader and rereads full identical original from zero",
       %{fixture: f} do
    token = S.barrier!(f, {:reader_after, 1})
    runner = S.spawn_run(f)

    {reader, %{summary: %{size: tail_size}, transaction?: false}} =
      S.await_barrier!(f, {:reader_after, 1}, token)

    assert tail_size == byte_size("\nrestart tail\n")
    assert [{:leased, _, {:ok, lease}}] = Enum.filter(S.events(f), &(elem(&1, 0) == :leased))

    assert {{:delivered, 0}, pid, %{size: 4_194_304}} =
             Enum.find(S.events(f), &(elem(&1, 0) == {:delivered, 0}))

    assert pid == runner.pid
    refute {:delivered, 1} in S.keys(f)
    lease_monitor = Process.monitor(lease)
    reader_monitor = Process.monitor(reader)
    S.kill_runner!(runner)
    assert_receive {:DOWN, ^lease_monitor, :process, ^lease, _}, 5_000
    assert_receive {:DOWN, ^reader_monitor, :process, ^reader, _}, 5_000
    assert DynamicSupervisor.which_children(f.lease_supervisor) == []
    S.pending!(f)
    assert S.progress(f) == []
    S.clear(f)
    S.ready!(f, Text)

    assert Enum.filter(S.keys(f), &match?({:delivered, _}, &1)) ==
             [{:delivered, 0}, {:delivered, 1}]
  end

  test "complete read preclaim death reauthenticates full source and leaves legacy v4 bytes untouched",
       %{fixture: f} do
    before = S.seed_v4!(f)
    token = S.barrier!(f, :revoked)
    runner = S.spawn_run(f)
    {pid, %{lease: lease, result: :ok}} = S.await_barrier!(f, :revoked, token)
    assert pid == runner.pid
    lease_monitor = Process.monitor(lease)
    assert_receive {:DOWN, ^lease_monitor, :process, ^lease, _}, 5_000

    assert Enum.filter(S.keys(f), &match?({:delivered, _}, &1)) ==
             [{:delivered, 0}, {:delivered, 1}]

    refute :claim_before in S.keys(f)
    S.kill_runner!(runner)
    S.pending!(f)
    assert S.progress(f) == before
    assert DynamicSupervisor.which_children(f.lease_supervisor) == []
    S.clear(f)
    S.ready!(f, Text)

    assert Enum.filter(S.keys(f), &match?({:delivered, _}, &1)) ==
             [{:delivered, 0}, {:delivered, 1}]

    assert S.progress(f) == before
  end

  test "claimed worker death resumes exact job generation adapter format and database deadline",
       %{fixture: f} do
    token = S.barrier!(f, :extracted)
    runner = S.spawn_run(f)
    {pid, %{digest: digest, module: Text}} = S.await_barrier!(f, :extracted, token)
    assert pid == runner.pid
    assert digest == :crypto.hash(:sha256, f.plaintext)
    assert [before] = S.attempt_rows(f)
    assert ["extracting", 1, job, "plain_text", 1, started, deadline, nil] = before
    assert job == Ecto.UUID.dump!(f.envelope.job_id)
    assert DateTime.diff(deadline, started, :microsecond) == 180_000_000
    assert DynamicSupervisor.which_children(f.lease_supervisor) == []
    S.kill_runner!(runner)
    assert S.attempt_rows(f) == [before]
    S.clear(f)
    S.ready!(f, Text)
    assert [["ready", 1, ^job, "plain_text", 1, ^started, ^deadline, _]] = S.attempt_rows(f)
    assert [{:claimed, _, {:ok, resumed}}] = Enum.filter(S.events(f), &(elem(&1, 0) == :claimed))
    assert resumed.job_id == f.envelope.job_id

    assert resumed.generation == 1 and resumed.adapter_name == "plain_text" and
             resumed.format_version == 1

    assert resumed.started_at == started and resumed.deadline_at == deadline

    assert Enum.filter(S.keys(f), &match?({:delivered, _}, &1)) ==
             [{:delivered, 0}, {:delivered, 1}]
  end
end

defmodule Singularity.Runtime.DocumentSourceTombstoneIntegrationTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  @moduletag :tmp_dir
  alias Singularity.Core.Error
  alias Singularity.Ingest.Documents.Text
  alias Singularity.Runtime.DocumentSourceIntegrationSupport, as: S
  setup context, do: S.setup(context)

  test "source Asset tombstone retains original for the entire actual worker composition", %{
    fixture: f
  } do
    ciphertext_before = File.read!(f.path)
    S.tombstone!(f, :asset)
    S.ready!(f, Text)
    assert File.read!(f.path) == ciphertext_before

    assert [[source_object]] =
             S.owner_query(
               "SELECT source_object_id FROM content.document_versions WHERE resource_version_id=$1",
               [f.document.resource_version_id]
             ).rows

    assert source_object == f.source.object_id

    assert Enum.filter(
             S.keys(f),
             &(&1 in [:described, :leased, :claimed, :extracted, :completed])
           ) ==
             [:described, :leased, :claimed, :extracted, :completed]
  end

  test "Document deletion after full read before first claim denies extraction and fragments", %{
    fixture: f
  } do
    token = S.barrier!(f, :claim_before)
    runner = S.spawn_run(f)
    {pid, {"plain_text", 1}} = S.await_barrier!(f, :claim_before, token)
    assert pid == runner.pid
    S.pending!(f)
    S.tombstone!(f, :document)
    send(pid, {token, :continue})
    assert {:error, %Error{message: nil, details: %{}}} = S.await_result!(runner)
    S.pending!(f)
    assert :claim_before in S.keys(f)

    assert [{:claimed, _, {:error, %Error{}}}] =
             Enum.filter(S.events(f), &(elem(&1, 0) == :claimed))

    refute :extracted in S.keys(f)
    assert DynamicSupervisor.which_children(f.lease_supervisor) == []
    assert File.exists?(f.path)
  end
end
