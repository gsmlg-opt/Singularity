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
    KnowledgeFixtures.retire_document_on_exit!(document)
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

  test "actual WorkerRepo permits scoped Document reads and denies canonical writes", %{
    fixture: f
  } do
    for operation <- [
          "DELETE FROM content.document_versions WHERE false",
          "UPDATE content.document_versions SET title=title WHERE false",
          "INSERT INTO content.document_versions DEFAULT VALUES"
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
               Ecto.Adapters.SQL.query(WorkerRepo, operation, [], log: false)
    end

    Singularity.Storage.WorkerDocumentReadAssertions.assert_read_only_rls!()
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

defmodule Singularity.Runtime.DocumentOutcomeIntegrationSupport do
  import ExUnit.Assertions
  alias Singularity.Core.{DocumentCompletion, DocumentFragmentation, Error, SourceLocator}
  alias Singularity.Ingest.Documents.{Markdown, PDF, Poppler, Text}
  alias Singularity.Runtime.{AuthorizationDependencies, Authorize, JobDispatcher, KeyCustodian}
  alias Singularity.Runtime.DocumentSourceIntegrationSupport, as: S
  alias Singularity.Runtime.DocumentSourceIntegrationSupport.{Custodian, Lease, Probe}
  alias Singularity.Runtime.Documents.Extract

  alias Singularity.Storage.{
    Fixtures,
    KnowledgeFixtures,
    MigrationRepo,
    RequestRepo,
    SafeSQL,
    ScopedRepo,
    WorkerRepo
  }

  alias Singularity.Storage.Jobs.{EnvelopeCodec, GenericWorker, WorkerScope}

  alias Singularity.Storage.Postgres.{
    DocumentRepository,
    DocumentWorkerRepository,
    IdentityRepository
  }

  @canary "CANARY_C_PRIVATE_TITLE_SOURCE_LOCATOR_TOOL_SQL"
  def canary, do: @canary

  defmodule ToolFailure do
    alias Singularity.Ingest.Documents.Poppler
    def run(:info, bytes, opts), do: Poppler.run(:info, bytes, opts)

    def run(:text, bytes, opts) do
      path = Keyword.fetch!(opts, :c_pid_path)
      fault = Keyword.fetch!(opts, :c_fault)

      script =
        case fault do
          :timeout -> "printf '%s' \"$$\" > \"$1\"; exec sleep 10"
          :tool_exit -> "printf '%s' \"$$\" > \"$1\"; printf '%s' \"$2\" >&2; exit 42"
        end

      result =
        Poppler.run_guarded(
          "/bin/sh",
          [
            "-c",
            script,
            "c-owned-tool",
            path,
            Singularity.Runtime.DocumentOutcomeIntegrationSupport.canary()
          ],
          bytes,
          timeout_ms: 2000,
          output_limit: 1024
        )

      pid = path |> File.read!() |> String.to_integer()
      ExUnit.Assertions.refute(File.exists?("/proc/#{pid}"))
      result
    end
  end

  defmodule Extractor do
    alias Singularity.Ingest.Documents.{PDF, Text}
    alias Singularity.Runtime.DocumentOutcomeIntegrationSupport.ToolFailure
    alias Singularity.Runtime.DocumentSourceIntegrationSupport.Probe
    alias Singularity.Storage.WorkerRepo

    def extract(config, bytes) do
      true = WorkerRepo.checked_out?()
      false = WorkerRepo.in_transaction?()

      Probe.event(config.f.probe, :c_extract, %{
        size: byte_size(bytes),
        digest: :crypto.hash(:sha256, bytes)
      })

      case config.mode do
        :actual ->
          config.module.extract(bytes)

        :raise ->
          {:ok, _} = Text.extract(bytes)
          raise Singularity.Runtime.DocumentOutcomeIntegrationSupport.canary()

        :throw ->
          {:ok, _} = Text.extract(bytes)
          throw(Singularity.Runtime.DocumentOutcomeIntegrationSupport.canary())

        mode when mode in [:timeout, :tool_exit] ->
          PDF.extract(bytes,
            runner: ToolFailure,
            c_fault: mode,
            c_pid_path: Path.join(config.f.root, "owned-tool-pid")
          )
      end
    end
  end

  defmodule Worker do
    alias Singularity.Runtime.DocumentSourceIntegrationSupport.Probe
    alias Singularity.Storage.{SafeSQL, WorkerRepo}
    alias Singularity.Storage.Postgres.DocumentWorkerRepository, as: R
    def describe(_config, context, envelope), do: R.describe(context, envelope)

    def put_progress_state(config, context, envelope, state) do
      result = R.put_progress_state(context, envelope, state)

      if state == :waiting_for_unlock and result == {:ok, :saved},
        do: Probe.event(config.f.probe, :c_waiting_saved, :saved)

      result
    end

    def claim(config, context, envelope, adapter, format) do
      result = R.claim(context, envelope, adapter, format)
      Probe.event(config.f.probe, :c_claimed, result)
      result
    end

    def complete(config, context, envelope, source, attempt, completion) do
      false = WorkerRepo.in_transaction?()

      Probe.event(config.f.probe, :c_complete_before, %{
        outcome: completion.outcome,
        generation: attempt.generation
      })

      R.complete(
        fault_context(context, config.complete_fault?),
        envelope,
        source,
        attempt,
        completion
      )
    end

    def record_exhaustion(config, context, envelope, failure, metadata) do
      Probe.event(config.f.probe, :c_terminal, metadata)

      result =
        R.record_exhaustion(
          fault_context(context, config.recorder_fault?),
          envelope,
          failure,
          metadata
        )

      Probe.event(config.f.probe, :c_terminal_result, result)
      result
    end

    defp fault_context(context, false), do: context

    defp fault_context(context, true) do
      original = context.transact

      Map.put(context, :transact, fn options, phase ->
        original.(options, fn repo ->
          result = phase.(repo)

          SafeSQL.query!(repo, "SELECT runtime_c_private_failure($1::text)", [
            Singularity.Runtime.DocumentOutcomeIntegrationSupport.canary()
          ])

          result
        end)
      end)
    end
  end

  defmodule Handler do
    alias Singularity.Core.Error
    alias Singularity.Runtime.JobDispatcher
    alias Singularity.Runtime.DocumentSourceIntegrationSupport.Probe
    def dependencies, do: Application.fetch_env!(:singularity_storage, :runtime_c_dependencies)

    def handle(context, envelope) do
      case context.c_handler_mode do
        :actual -> JobDispatcher.handle(context, envelope)
        {:error, %Error{} = error} -> {:error, error}
        :raise -> raise Singularity.Runtime.DocumentOutcomeIntegrationSupport.canary()
        :throw -> throw(Singularity.Runtime.DocumentOutcomeIntegrationSupport.canary())
      end
    end

    def handle_failure(context, envelope, failure, metadata) do
      Probe.event(context.c_fixture.probe, :c_callback, metadata)
      JobDispatcher.handle_failure(context, envelope, failure, metadata)
    end
  end

  def setup(context) do
    {:ok, fixture: f} = S.setup(context)
    f = if Map.get(context, :private_title?, false), do: private_document!(f), else: f
    {:ok, fixture: f}
  end

  def dependencies(f, options \\ []) do
    config = %{
      f: f,
      complete_fault?: Keyword.get(options, :complete_fault?, false),
      recorder_fault?: Keyword.get(options, :recorder_fault?, false)
    }

    extractors =
      Map.new(
        [
          {"text/plain", Text, "plain_text"},
          {"text/markdown", Markdown, "markdown"},
          {"application/pdf", PDF, "poppler_text"}
        ],
        fn {type, module, name} ->
          {type,
           {{Extractor, %{f: f, module: module, mode: Keyword.get(options, :mode, :actual)}},
            name, 1}}
        end
      )

    %{
      authorize: Authorize,
      authorization: %AuthorizationDependencies{
        store: IdentityRepository,
        custodian: {KeyCustodian, f.custodian}
      },
      document_worker: {Worker, config},
      custodian: {Custodian, %{probe: f.probe, pid: f.custodian}},
      document_source_lease: {Lease, f.probe},
      document_extractors: extractors,
      c_fixture: f,
      c_handler_mode: Keyword.get(options, :handler_mode, :actual)
    }
  end

  def run(f, options \\ []) do
    envelope = Keyword.get(options, :envelope, f.envelope)

    WorkerScope.run(envelope, fn scope ->
      assert scope.repo_handle === WorkerRepo
      refute WorkerRepo.in_transaction?()
      Extract.run(Map.merge(dependencies(f, options), scope), envelope)
    end)
  end

  def configure_runner!(f, options \\ []) do
    for {key, value} <- [job_handler: Handler, runtime_c_dependencies: dependencies(f, options)] do
      previous = Application.fetch_env(:singularity_storage, key)

      ExUnit.Callbacks.on_exit(fn ->
        case previous do
          {:ok, old} -> Application.put_env(:singularity_storage, key, old)
          :error -> Application.delete_env(:singularity_storage, key)
        end
      end)

      Application.put_env(:singularity_storage, key, value)
    end

    :ok
  end

  def spawn_run(f, options \\ []) do
    owner = self()
    token = make_ref()
    {pid, monitor} = spawn_monitor(fn -> send(owner, {token, :result, run(f, options)}) end)
    ExUnit.Callbacks.on_exit(fn -> S.stop_owned(pid) end)
    %{pid: pid, monitor: monitor, token: token}
  end

  def live!(f) do
    scope = %{principal_id: f.principal_id, vault_id: f.vault_id, owner_scope_id: f.vault_id}

    assert {:ok, document} =
             ScopedRepo.transact(RequestRepo, scope, fn repo ->
               DocumentRepository.get_live_scoped(repo, scope, f.envelope.payload["resource_id"])
             end)

    assert document.resource_id == f.envelope.payload["resource_id"]

    assert {:ok, binding} =
             ScopedRepo.transact(RequestRepo, scope, fn repo ->
               DocumentRepository.source_live_scoped(repo, scope, document.resource_id)
             end)

    assert binding.object_id == Ecto.UUID.load!(f.source.object_id)
    assert binding.source_byte_size == byte_size(f.plaintext)

    fragments =
      ScopedRepo.transact(RequestRepo, scope, fn repo ->
        DocumentRepository.fragments_live_scoped(repo, scope, document.resource_id)
      end)

    case document.state do
      :ready ->
        assert {:ok, public} = fragments

        assert Enum.map(public, fn fragment ->
                 [
                   fragment.fragment_id,
                   fragment.ordinal,
                   fragment.text,
                   fragment.digest,
                   SourceLocator.to_map(fragment.locator)
                 ]
               end) == S.fragments(f)

      :pending ->
        assert {:error, %Error{code: :conflict}} = fragments
    end
  end

  def captured_attempt!(f) do
    assert [{:c_claimed, _, {:ok, attempt}}] =
             Enum.filter(S.events(f), &(elem(&1, 0) == :c_claimed))

    assert {:ok, {:source, source}} =
             WorkerScope.run(
               f.envelope,
               &DocumentWorkerRepository.describe(&1, f.envelope)
             )

    {source, attempt}
  end

  def sql_complete(f, fragments, digest) do
    e = f.envelope

    WorkerScope.run(e, fn scope ->
      scope.transact.([], fn repo ->
        SafeSQL.query(
          repo,
          "SELECT * FROM content.complete_document_worker($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)",
          [
            f.document.resource_id,
            f.document.resource_version_id,
            Ecto.UUID.dump!(e.job_id),
            e.expected_entity_revision,
            e.principal_authorization_epoch,
            e.vault_authorization_epoch,
            e.expected_entity_revision + 1,
            "plain_text",
            1,
            "text/plain",
            fragments,
            digest,
            nil
          ]
        )
      end)
    end)
  end

  def json_fragments(completion) do
    Enum.map(completion.fragments, fn fragment ->
      %{
        "id" => fragment.fragment_id,
        "ordinal" => fragment.ordinal,
        "text" => fragment.text,
        "digest" => Base.encode16(fragment.digest, case: :lower),
        "locator" => SourceLocator.to_map(fragment.locator)
      }
    end)
  end

  def job(f, attempt \\ 1, maximum \\ 3) do
    {:ok, args} = EnvelopeCodec.encode(f.envelope)
    now = DateTime.utc_now()

    %Oban.Job{
      args: args,
      attempt: attempt,
      max_attempts: maximum,
      queue: "document_extract",
      worker: Oban.Worker.to_string(GenericWorker),
      attempted_at: now,
      scheduled_at: now
    }
  end

  def claim_by_interruption!(f) do
    token = S.barrier!(f, :claimed)
    runner = S.spawn_run(f)
    {pid, {:ok, attempt}} = S.await_barrier!(f, :claimed, token)
    assert pid == runner.pid
    S.kill_runner!(runner)
    refute :extracted in S.keys(f)
    assert DynamicSupervisor.which_children(f.lease_supervisor) == []

    {:ok, {:source, source}} =
      WorkerScope.run(f.envelope, &DocumentWorkerRepository.describe(&1, f.envelope))

    {source, attempt}
  end

  def completion!(f, source, attempt, outcome \\ :ready) do
    attrs = %{
      resource_id: source.resource_id,
      resource_version_id: source.resource_version_id,
      owner_scope_id: f.vault_id,
      classification: :private,
      generation: attempt.generation,
      adapter_name: attempt.adapter_name,
      format_version: attempt.format_version,
      media_type: f.media_type,
      finished_at: DateTime.utc_now(),
      outcome: outcome
    }

    attrs =
      if outcome == :ready do
        {:ok, blocks} = Text.extract(f.plaintext)

        {:ok, fragments} =
          DocumentFragmentation.build(
            Map.take(
              attrs,
              [:resource_id, :resource_version_id, :owner_scope_id, :classification]
            ),
            f.media_type,
            blocks
          )

        Map.merge(attrs, %{
          fragments: fragments,
          extracted_text_digest: :crypto.hash(:sha256, Enum.map(fragments, & &1.text))
        })
      else
        Map.put(attrs, :failure_code, "extractor_failed")
      end

    {:ok, completion} = DocumentCompletion.new(attrs)
    completion
  end

  def complete(f, source, attempt, completion) do
    WorkerScope.run(f.envelope, fn scope ->
      DocumentWorkerRepository.complete(scope, f.envelope, source, attempt, completion)
    end)
  end

  def exhaustion(f, options \\ []) do
    WorkerScope.run(f.envelope, fn scope ->
      Extract.record_exhaustion(
        Map.merge(dependencies(f, options), scope),
        f.envelope,
        Error.new(:storage_unavailable, retryable?: true),
        %{attempt: 3, max_attempts: 3}
      )
    end)
  end

  def no_projection!(f) do
    assert [[true, true, true]] =
             S.owner_query(
               """
               SELECT NOT EXISTS(SELECT 1 FROM content.asset_search_documents WHERE resource_version_id=$1),
                 NOT EXISTS(SELECT 1 FROM content.note_search_documents WHERE resource_version_id=$1),
                 EXISTS(SELECT 1 FROM content.asset_search_documents WHERE resource_version_id=$2)
               """,
               [f.document.resource_version_id, f.source.resource_version_id]
             ).rows
  end

  def outcome!(f, state, code, options \\ []) do
    before = File.read!(f.path)
    assert {:ok, %{state: ^state, generation: 1}} = run(f, options)
    assert [[actual, 1, job_id, _, 1, started, deadline, nil]] = S.attempt_rows(f)
    assert actual == Atom.to_string(state)
    assert job_id == Ecto.UUID.dump!(f.envelope.job_id)
    assert DateTime.diff(deadline, started, :microsecond) == 180_000_000

    assert [[^code]] =
             S.owner_query(
               "SELECT failure_code FROM content.document_versions WHERE resource_version_id=$1",
               [f.document.resource_version_id]
             ).rows

    assert S.fragments(f) == []
    no_projection!(f)
    assert File.read!(f.path) == before
    assert DynamicSupervisor.which_children(f.lease_supervisor) == []
  end

  def hidden!(f) do
    scope = %{principal_id: f.principal_id, vault_id: f.vault_id, owner_scope_id: f.vault_id}

    for operation <- [:get_live_scoped, :fragments_live_scoped, :source_live_scoped] do
      assert {:error, %Error{code: :not_found}} =
               ScopedRepo.transact(RequestRepo, scope, fn repo ->
                 apply(DocumentRepository, operation, [
                   repo,
                   scope,
                   f.envelope.payload["resource_id"]
                 ])
               end)
    end
  end

  def mutation!(f, operation) when operation in [:retry, :restore] do
    assert [[id]] =
             Fixtures.with_owner(fn ->
               Singularity.Storage.DataCase.query!(
                 MigrationRepo,
                 "SELECT set_config('singularity.principal_id',$1,true),set_config('singularity.vault_id',$2,true)",
                 [f.principal_id, f.vault_id]
               )

               Singularity.Storage.DataCase.query!(
                 MigrationRepo,
                 "SELECT content.#{operation}_document_runtime($1,'plain_text',1)",
                 [f.document.resource_id]
               ).rows
             end)

    assert id == f.document.resource_id
  end

  def successor!(f, revision) do
    key = "document-extraction:#{f.envelope.payload["resource_version_id"]}:#{revision}"

    assert [[id, pe, oe, correlation, causation, payload]] =
             S.owner_query(
               """
               SELECT id,principal_authorization_epoch,vault_authorization_epoch,correlation_id,causation_id,payload
               FROM core.outbox_events WHERE vault_id=$1 AND idempotency_key=$2
               """,
               [f.source.vault_id, key]
             ).rows

    env = %{
      f.envelope
      | job_id: Ecto.UUID.load!(id),
        idempotency_key: key,
        expected_entity_revision: revision,
        principal_authorization_epoch: pe,
        vault_authorization_epoch: oe,
        correlation_id: Ecto.UUID.load!(correlation),
        causation_id: Ecto.UUID.load!(causation || id),
        payload: payload
    }

    {:ok, encoded} = EnvelopeCodec.encode(env)
    {:ok, ^env} = EnvelopeCodec.decode(encoded)

    S.owner_query(
      """
      INSERT INTO jobs.job_submissions(id,vault_id,outbox_event_id,classification,idempotency_key,job_type)
      VALUES($1,$2,$1,'private',$3,'document_extract') ON CONFLICT(outbox_event_id) DO NOTHING
      """,
      [id, f.source.vault_id, key]
    )

    %{f | envelope: env, request: %{f.request | job_id: env.job_id}}
  end

  def stale!(f, source, attempt) do
    ready = completion!(f, source, attempt)
    failed = completion!(f, source, attempt, :failed)
    before = {S.attempt_rows(f), S.fragments(f)}

    assert {:error, %Error{code: :conflict}} =
             WorkerScope.run(
               f.envelope,
               &DocumentWorkerRepository.claim(
                 &1,
                 f.envelope,
                 attempt.adapter_name,
                 attempt.format_version
               )
             )

    assert {:error, %Error{code: :conflict}} = complete(f, source, attempt, ready)
    assert {:error, %Error{code: :conflict}} = complete(f, source, attempt, failed)
    assert {:ok, :unchanged} = exhaustion(f)
    assert {S.attempt_rows(f), S.fragments(f)} == before
  end

  def wait_for_deadline!(f, attempt) do
    assert DateTime.diff(attempt.deadline_at, attempt.started_at, :microsecond) == 180_000_000
    wait_for_deadline(f, attempt.deadline_at, System.monotonic_time(:millisecond) + 190_000)
  end

  defp wait_for_deadline(f, deadline, bound) do
    assert System.monotonic_time(:millisecond) < bound

    assert [[current, stored]] =
             S.owner_query(
               "SELECT clock_timestamp(),attempt_deadline_at FROM content.document_versions WHERE resource_version_id=$1",
               [f.document.resource_version_id]
             ).rows

    assert stored == deadline
    remaining = DateTime.diff(deadline, current, :millisecond)

    if remaining >= 0 do
      token = make_ref()
      timer = Process.send_after(self(), {:deadline_tick, token}, min(remaining + 2, 30_000))

      receive do
        {:deadline_tick, ^token} -> :ok
      after
        31_000 ->
          Process.cancel_timer(timer)
          flunk("database deadline timer exceeded bound")
      end

      wait_for_deadline(f, deadline, bound)
    else
      :ok
    end
  end

  def pdf_bytes(pages) do
    stream = "BT /F1 12 Tf 20 100 Td (page text) Tj ET\n"
    stream_id = pages + 4
    kids = Enum.map_join(4..(pages + 3), " ", &"#{&1} 0 R")

    objects =
      [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Count #{pages} /Kids [#{kids}] >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
      ] ++
        Enum.map(1..pages, fn _ ->
          "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 3 0 R >> >> /Contents #{stream_id} 0 R >>"
        end) ++
        ["<< /Length #{byte_size(stream)} >>\nstream\n#{stream}endstream"]

    {body, offsets} =
      Enum.with_index(objects, 1)
      |> Enum.reduce(
        {"%PDF-1.4\n", []},
        fn {object, id}, {body, offsets} ->
          {body <> "#{id} 0 obj\n#{object}\nendobj\n", [byte_size(body) | offsets]}
        end
      )

    xref =
      Enum.reverse(offsets)
      |> Enum.map_join("", &(String.pad_leading(Integer.to_string(&1), 10, "0") <> " 00000 n \n"))

    body <>
      "xref\n0 #{length(objects) + 1}\n0000000000 65535 f \n" <>
      xref <>
      "trailer\n<< /Size #{length(objects) + 1} /Root 1 0 R >>\nstartxref\n#{byte_size(body)}\n%%EOF\n"
  end

  def fixture_bytes(name),
    do:
      File.read!(
        Path.expand("../../../../singularity_ingest/test/fixtures/documents/#{name}", __DIR__)
      )

  defp private_document!(f) do
    document = KnowledgeFixtures.document!(f.source, %{title: @canary, media_type: f.media_type})
    KnowledgeFixtures.retire_document_on_exit!(document)
    id = Ecto.UUID.generate()

    env = %{
      f.envelope
      | job_id: id,
        correlation_id: id,
        causation_id: id,
        idempotency_key: "document-extraction:" <> Ecto.UUID.load!(document.resource_version_id),
        payload: %{
          "resource_id" => Ecto.UUID.load!(document.resource_id),
          "resource_version_id" => Ecto.UUID.load!(document.resource_version_id)
        }
    }

    S.owner_query(
      """
      INSERT INTO core.outbox_events(id,event_type,idempotency_key,vault_id,principal_id,required_capability,
        principal_authorization_epoch,vault_authorization_epoch,classification,correlation_id,
        expected_entity_revision,envelope_version,payload,occurred_at)
      VALUES($1,'document.extraction_requested',$2,$3,$4,'asset.read',0,0,'private',$1,0,1,$5,CURRENT_TIMESTAMP)
      """,
      [
        Ecto.UUID.dump!(id),
        env.idempotency_key,
        f.source.vault_id,
        f.source.principal_id,
        env.payload
      ]
    )

    S.owner_query(
      """
      INSERT INTO jobs.job_submissions(id,vault_id,outbox_event_id,classification,idempotency_key,job_type)
      VALUES($1,$2,$1,'private',$3,'document_extract')
      """,
      [Ecto.UUID.dump!(id), f.source.vault_id, env.idempotency_key]
    )

    %{
      f
      | document: document,
        envelope: env,
        request: %{
          f.request
          | job_id: id,
            resource_version_id: env.payload["resource_version_id"]
        }
    }
  end
end

defmodule Singularity.Runtime.DocumentOutcomeIntegrationTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  @moduletag :tmp_dir
  alias Singularity.Core.Error
  alias Singularity.Ingest.Documents.PDF
  alias Singularity.Runtime.KeyCustodian
  alias Singularity.Runtime.DocumentSourceIntegrationSupport, as: S
  alias Singularity.Runtime.DocumentOutcomeIntegrationSupport, as: C
  alias Singularity.Storage.{Fixtures, KnowledgeFixtures, MigrationRepo}

  setup context do
    context =
      case Map.get(context, :plaintext_fixture) do
        :source_limit ->
          Map.put(context, :plaintext, :binary.copy(" ", 67_108_859) <> "\ntail")

        :normalized_over_limit ->
          Map.put(context, :plaintext, :binary.copy("x", 16_777_217))

        :normalized_fragment_limit ->
          Map.put(
            context,
            :plaintext,
            Enum.map_join(1..256, "\n\n", fn _ -> :binary.copy("x", 65_536) end)
          )

        _ ->
          context
      end

    C.setup(context)
  end

  @tag plaintext: <<255>>
  test "actual invalid UTF-8 persists only unsupported invalid_utf8", %{fixture: f} do
    C.outcome!(f, :unsupported, "invalid_utf8")
  end

  for {name, code} <- [
        {"malformed.pdf", "malformed_document"},
        {"encrypted.pdf", "encrypted_document"},
        {"encrypted_pdf20_xref_stream.pdf", "encrypted_document"},
        {"empty.pdf", "no_extractable_text"}
      ] do
    @tag plaintext: C.fixture_bytes(name)
    @tag media_type: "application/pdf"
    test "actual #{name} persists bounded #{code}", %{fixture: f} do
      C.outcome!(f, :unsupported, unquote(code))
    end
  end

  @tag plaintext_fixture: :source_limit
  @tag timeout: 120_000
  test "exact 64 MiB authenticated source reaches ready without source loss", %{fixture: f} do
    assert byte_size(f.plaintext) == 67_108_864
    assert {:ok, %{state: :ready, generation: 1}} = C.run(f)
    assert [[_, 0, "tail", _, %{"start_line" => 2, "end_line" => 2}]] = S.fragments(f)
    assert Enum.count(S.keys(f), &match?({:delivered, _}, &1)) == 16
    C.no_projection!(f)
    assert DynamicSupervisor.which_children(f.lease_supervisor) == []
  end

  test "canonical oversized INSERT is rejected with no partial Document or event", %{fixture: f} do
    resource = KnowledgeFixtures.uuid()
    version = KnowledgeFixtures.uuid()

    error =
      assert_raise Postgrex.Error, fn ->
        Fixtures.with_owner(fn ->
          query!(
            MigrationRepo,
            "UPDATE content.asset_objects SET plaintext_byte_size=67108865 WHERE id=$1",
            [f.source.object_id]
          )

          KnowledgeFixtures.insert_document!(f.source, %{
            resource_id: resource,
            resource_version_id: version,
            source_byte_size: 67_108_865
          })
        end)
      end

    assert error.postgres.constraint == "document_versions_source_byte_size_check"

    assert [[0, 0, 0]] =
             S.owner_query(
               """
               SELECT (SELECT count(*) FROM content.resources WHERE id=$1),
                 (SELECT count(*) FROM content.resource_versions WHERE id=$2),
                 (SELECT count(*) FROM core.outbox_events WHERE payload->>'resource_id'=$3)
               """,
               [resource, version, Ecto.UUID.load!(resource)]
             ).rows

    assert [[size]] =
             S.owner_query("SELECT plaintext_byte_size FROM content.asset_objects WHERE id=$1", [
               f.source.object_id
             ]).rows

    assert size == byte_size(f.plaintext)
    S.pending!(f)
  end

  @tag timeout: 120_000
  test "actual PDF source cap rejects over 64 MiB before process work", %{fixture: f} do
    assert {:error, {:unsupported, "source_too_large"}} =
             PDF.extract(:binary.copy("x", 67_108_865))

    S.pending!(f)
    assert S.keys(f) == []
  end

  test "valid post-insert oversized object drift denies descriptor before custody", %{fixture: f} do
    assert %{num_rows: 1} =
             S.owner_query(
               "UPDATE content.asset_objects SET plaintext_byte_size=67108865 WHERE id=$1",
               [f.source.object_id]
             )

    assert {:error, %Error{code: :conflict, message: nil, details: %{}}} = C.run(f)
    refute :leased in S.keys(f)
    refute :c_claimed in S.keys(f)
    S.pending!(f)
  end

  @tag plaintext_fixture: :normalized_over_limit
  @tag timeout: 120_000
  test "actual normalized text above 16 MiB persists unsupported output_too_large", %{fixture: f} do
    C.outcome!(f, :unsupported, "output_too_large")
  end

  @tag plaintext_fixture: :normalized_fragment_limit
  @tag timeout: 120_000
  test "exact 16 MiB normalized output and 65536-byte fragments persist ready", %{fixture: f} do
    assert {:ok, %{state: :ready}} = C.run(f)
    fragments = S.fragments(f)
    assert length(fragments) == 256
    assert Enum.all?(fragments, fn [_, _, text, _, _] -> byte_size(text) == 65_536 end)

    assert Enum.sum(Enum.map(fragments, fn [_, _, text, _, _] -> byte_size(text) end)) ==
             16_777_216

    C.no_projection!(f)
  end

  @tag plaintext: :binary.copy("x", 65_537)
  test "65537-byte block splits into valid bounded deterministic fragments", %{fixture: f} do
    assert {:ok, %{state: :ready}} = C.run(f)
    assert [[_, 0, first, _, first_locator], [_, 1, second, _, second_locator]] = S.fragments(f)
    assert {byte_size(first), byte_size(second)} == {65_536, 1}
    assert first <> second == f.plaintext
    assert first_locator["kind"] == "fragment" and second_locator["kind"] == "fragment"
    C.no_projection!(f)
  end

  @tag plaintext: Enum.map_join(1..4096, "\n\n", fn _ -> "x" end)
  @tag timeout: 120_000
  test "4096 actual semantic fragments persist one complete ready set", %{fixture: f} do
    assert {:ok, %{state: :ready}} = C.run(f)
    assert length(S.fragments(f)) == 4096

    assert Enum.map(S.fragments(f), fn [_, ordinal, _, _, _] -> ordinal end) ==
             Enum.to_list(0..4095)

    C.no_projection!(f)
  end

  @tag plaintext: Enum.map_join(1..4097, "\n\n", fn _ -> "x" end)
  test "4097 actual semantic fragments persist unsupported with no partial rows", %{fixture: f} do
    C.outcome!(f, :unsupported, "output_too_large")
  end

  @tag plaintext: C.pdf_bytes(4096)
  @tag media_type: "application/pdf"
  @tag timeout: 120_000
  test "actual 4096-page PDF persists complete page provenance", %{fixture: f} do
    assert {:ok, %{state: :ready}} = C.run(f)
    fragments = S.fragments(f)
    assert length(fragments) == 4096

    assert Enum.map(fragments, fn [_, _, _, _, locator] -> locator["page"] end) ==
             Enum.to_list(1..4096)

    C.no_projection!(f)
  end

  @tag plaintext: C.pdf_bytes(4097)
  @tag media_type: "application/pdf"
  @tag timeout: 120_000
  test "actual 4097-page PDF persists unsupported page_limit", %{fixture: f} do
    C.outcome!(f, :unsupported, "page_limit")
  end

  for {mode, code} <- [timeout: "timeout", tool_exit: "extractor_failed"] do
    @tag plaintext: S.pdf_bytes()
    @tag media_type: "application/pdf"
    test "real owned subprocess #{mode} persists failed #{code}", %{fixture: f} do
      C.outcome!(f, :failed, unquote(code), mode: unquote(mode))
      pid_path = Path.join(f.root, "owned-tool-pid")
      assert File.regular?(pid_path)
      assert {pid, ""} = Integer.parse(File.read!(pid_path))
      assert pid > 0
      refute File.exists?("/proc/#{pid}")
    end
  end

  for mode <- [:raise, :throw] do
    test "#{mode} private extractor diagnostic persists only failed extractor_failed", %{
      fixture: f
    } do
      C.outcome!(f, :failed, "extractor_failed", mode: unquote(mode))
    end
  end

  for loss <- [:custody, :storage] do
    test "already-claimed #{loss} loss fails exact attempt without re-claim or deadline extension",
         %{fixture: f} do
      {_source, attempt} = C.claim_by_interruption!(f)
      S.clear(f)

      case unquote(loss) do
        :custody ->
          assert {:ok, token} =
                   KeyCustodian.begin_revoke(f.custodian, %{session_id: f.session_id})

          assert :ok = KeyCustodian.finish_revoke(f.custodian, token)

        :storage ->
          S.corrupt!(f, :missing)
      end

      assert {:ok, %{state: :failed, generation: 1}} = C.run(f)
      assert [["failed", 1, job, "plain_text", 1, started, deadline, nil]] = S.attempt_rows(f)
      assert job == Ecto.UUID.dump!(attempt.job_id)
      assert started == attempt.started_at and deadline == attempt.deadline_at
      refute :c_claimed in S.keys(f)
      refute :c_extract in S.keys(f)

      assert [["extractor_failed"]] =
               S.owner_query(
                 "SELECT failure_code FROM content.document_versions WHERE resource_version_id=$1",
                 [f.document.resource_version_id]
               ).rows

      assert S.fragments(f) == []
      C.no_projection!(f)
    end
  end

  for mode <- [:actual, :raise] do
    test "#{mode} post-claim final SQL fault rolls back terminal fields and all fragments", %{
      fixture: f
    } do
      assert {:error,
              %Error{code: :storage_unavailable, retryable?: true, message: nil, details: %{}}} =
               C.run(f, mode: unquote(mode), complete_fault?: true)

      assert [["extracting", 1, job, "plain_text", 1, started, deadline, nil]] = S.attempt_rows(f)
      assert job == Ecto.UUID.dump!(f.envelope.job_id)
      assert DateTime.diff(deadline, started, :microsecond) == 180_000_000
      assert S.fragments(f) == []
      C.no_projection!(f)

      assert [[nil, nil]] =
               S.owner_query(
                 "SELECT failure_code,attempt_finished_at FROM content.document_versions WHERE resource_version_id=$1",
                 [f.document.resource_version_id]
               ).rows

      assert File.exists?(f.path)
      assert DynamicSupervisor.which_children(f.lease_supervisor) == []
    end
  end
end

defmodule Singularity.Runtime.DocumentOutcomeFencesIntegrationTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  @moduletag :tmp_dir
  alias Singularity.Core.Error
  alias Singularity.Runtime.DocumentSourceIntegrationSupport, as: S
  alias Singularity.Runtime.DocumentOutcomeIntegrationSupport, as: C
  alias Singularity.Runtime.Documents.ExtractionReconciler
  alias Singularity.Storage.Postgres.KnowledgeError
  alias Singularity.Storage.{MigrationRepo, SafeSQL}
  alias Singularity.Storage.Postgres.DocumentRepository

  @c3_system_timeout 5_000
  @c3_settle_timeout 200_000
  @c3_admission_limit 10_000

  setup context do
    isolation =
      if Map.get(context, :c3_expiry_isolation, false) do
        guard = suspend_automatic_reconciler!()

        residual =
          bounded_settle!(fn ->
            admit_alias_database!()
            settle_prior_attempts!()
          end)

        %{guard: guard, residual: residual}
      end

    {:ok, fixture: fixture} = C.setup(context)
    {:ok, fixture: fixture, c3_isolation: isolation}
  end

  for mode <- [:actual, :raise] do
    test "claimed #{mode} completion survives Document tombstone while ordinary reads stay hidden",
         %{fixture: f} do
      C.live!(f)
      token = S.barrier!(f, :c_complete_before)
      runner = C.spawn_run(f, mode: unquote(mode))
      {pid, %{generation: 1, outcome: outcome}} = S.await_barrier!(f, :c_complete_before, token)
      assert pid == runner.pid
      assert outcome == if(unquote(mode) == :actual, do: :ready, else: :failed)
      S.tombstone!(f, :document)
      C.hidden!(f)
      send(pid, {token, :continue})
      assert {:ok, %{state: ^outcome, generation: 1}} = S.await_result!(runner)
      C.hidden!(f)
      C.no_projection!(f)

      if outcome == :ready,
        do: assert(S.fragments(f) == S.expected_fragments!(f, Singularity.Ingest.Documents.Text)),
        else: assert(S.fragments(f) == [])

      assert File.exists?(f.path)
      assert DynamicSupervisor.which_children(f.lease_supervisor) == []
    end
  end

  for operation <- [:retry, :restore] do
    test "actual #{operation} successor fences paused old ready fail claim and exhaustion", %{
      fixture: f
    } do
      token = S.barrier!(f, :c_complete_before)
      runner = C.spawn_run(f)
      {pid, %{outcome: :ready}} = S.await_barrier!(f, :c_complete_before, token)
      {source, attempt} = C.captured_attempt!(f)

      assert {:ok, %{state: :failed}} =
               C.complete(f, source, attempt, C.completion!(f, source, attempt, :failed))

      if unquote(operation) == :restore, do: S.tombstone!(f, :document)
      C.mutation!(f, unquote(operation))
      successor = C.successor!(f, 2)
      assert successor.envelope.job_id != f.envelope.job_id
      assert {:ok, %{state: :ready, generation: 3}} = C.run(successor)
      send(pid, {token, :continue})

      assert {:error, %Error{code: :conflict, message: nil, details: %{}}} =
               S.await_result!(runner)

      C.stale!(f, source, attempt)

      assert [[1]] =
               S.owner_query(
                 "SELECT count(*) FROM core.outbox_events WHERE idempotency_key=$1 AND vault_id=$2",
                 [successor.envelope.idempotency_key, f.source.vault_id]
               ).rows

      C.no_projection!(f)
    end
  end

  test "restoring pending Document emits successor and rejects original first claim", %{
    fixture: f
  } do
    token = S.barrier!(f, :claim_before)
    runner = S.spawn_run(f)
    {pid, _} = S.await_barrier!(f, :claim_before, token)
    S.tombstone!(f, :document)
    C.mutation!(f, :restore)
    successor = C.successor!(f, 1)
    assert successor.envelope.causation_id == successor.envelope.job_id

    assert [[nil]] ==
             S.owner_query(
               "SELECT causation_id FROM core.outbox_events WHERE id=$1 AND vault_id=$2",
               [Ecto.UUID.dump!(successor.envelope.job_id), f.source.vault_id]
             ).rows

    send(pid, {token, :continue})
    assert {:error, %Error{code: :conflict}} = S.await_result!(runner)
    assert {:ok, %{state: :ready, generation: 2}} = C.run(successor)
    C.no_projection!(f)
  end

  test "restoring ready Document re-exposes identical result without reopening or extraction event",
       %{
         fixture: f
       } do
    assert {:ok, receipt} = C.run(f)
    before = {S.attempt_rows(f), S.fragments(f)}

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
               [
                 f.source.principal_id,
                 f.source.vault_id,
                 f.document.resource_version_id,
                 f.document.resource_id
               ]
             ).rows

    assert canonical_revision == 0

    S.tombstone!(f, :document)
    C.hidden!(f)
    C.mutation!(f, :restore)
    C.live!(f)

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
  end

  @tag timeout: 420_000
  @tag c3_expiry_isolation: true
  test "actual DB deadline expiry and concurrent recovery fence every old outcome and terminal callback",
       %{fixture: f, c3_isolation: isolation} do
    assert_c3_isolation!(isolation, f)
    {source, attempt} = C.claim_by_interruption!(f)
    before = S.attempt_rows(f)
    assert {:ok, 0} = ExtractionReconciler.run(%{repo: WorkerRepo})
    assert S.attempt_rows(f) == before
    C.wait_for_deadline!(f, attempt)
    assert_c3_isolation!(isolation, f)
    assert {:messages, queued} = Process.info(isolation.guard.pid, :messages)
    assert :reconcile in queued
    C.stale!(f, source, attempt)
    assert S.attempt_rows(f) == before

    C.configure_runner!(f,
      handler_mode: {:error, Error.new(:storage_unavailable, retryable?: true)}
    )

    assert {:error, %{code: :job_failed}} =
             Singularity.Storage.Jobs.GenericWorker.perform(C.job(f, 3, 3))

    assert S.attempt_rows(f) == before

    assert_c3_isolation!(isolation, f)
    owner = self()
    token = make_ref()

    runners =
      Enum.map(1..2, fn _ ->
        {pid, monitor} =
          spawn_monitor(fn ->
            receive do
              {^token, :start} ->
                send(owner, {token, self(), ExtractionReconciler.run(%{repo: WorkerRepo})})
            after
              5_000 -> exit(:recovery_start_timeout)
            end
          end)

        on_exit(fn -> S.stop_owned(pid) end)
        {pid, monitor}
      end)

    Enum.each(runners, fn {pid, _} -> send(pid, {token, :start}) end)

    results =
      Enum.map(runners, fn {pid, monitor} ->
        assert_receive {^token, ^pid, result}, 5_000
        assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
        result
      end)

    assert_c3_isolation!(isolation, f)
    assert Enum.sort(results) == [{:ok, 0}, {:ok, 1}]
    assert [["pending", 2, nil, nil, nil, nil, nil, nil]] = S.attempt_rows(f)
    C.stale!(f, source, attempt)

    assert {:error, %{code: :job_failed}} =
             Singularity.Storage.Jobs.GenericWorker.perform(C.job(f, 3, 3))

    assert [["pending", 2, nil, nil, nil, nil, nil, nil]] = S.attempt_rows(f)
    successor = C.successor!(f, 2)
    S.clear(successor)
    {_successor_source, successor_attempt} = C.claim_by_interruption!(successor)
    assert successor_attempt.generation == 3
    C.stale!(f, source, attempt)
    before_successor = S.attempt_rows(f)

    assert {:error, %{code: :job_failed}} =
             Singularity.Storage.Jobs.GenericWorker.perform(C.job(f, 3, 3))

    assert S.attempt_rows(f) == before_successor
    assert {:ok, %{state: :ready, generation: 3}} = C.run(successor)
    C.stale!(f, source, attempt)
    C.no_projection!(f)
    assert {:ok, 0} = ExtractionReconciler.run(%{repo: WorkerRepo})
    assert DynamicSupervisor.which_children(f.lease_supervisor) == []
    assert_c3_isolation!(isolation, f)
  end

  test "actual complete exact replay is idempotent and conflicting valid replay leaves sealed rows unchanged",
       %{fixture: f} do
    {source, attempt} = C.claim_by_interruption!(f)
    completion = C.completion!(f, source, attempt)
    assert {:ok, receipt} = C.complete(f, source, attempt, completion)
    before = {S.attempt_rows(f), S.fragments(f)}
    assert {:ok, ^receipt} = C.complete(f, source, attempt, completion)

    assert {:ok, conflicting} =
             Singularity.Core.DocumentCompletion.new(%{completion | detected_language: "en"})

    assert {:error, %Error{code: :conflict}} = C.complete(f, source, attempt, conflicting)
    assert {S.attempt_rows(f), S.fragments(f)} == before
    C.no_projection!(f)
  end

  test "actual worker SQL independently rejects twelve invalid fragment sets without partial rows",
       %{fixture: f} do
    {source, attempt} = C.claim_by_interruption!(f)
    completion = C.completion!(f, source, attempt)
    [first, second] = C.json_fragments(completion)
    digest = completion.extracted_text_digest

    invalid = [
      {[], digest},
      {[first, %{second | "ordinal" => 0}], digest},
      {[first, %{second | "id" => first["id"]}], digest},
      {[first, %{second | "id" => "wrong-id"}], digest},
      {[first, %{second | "digest" => String.duplicate("00", 32)}], digest},
      {[first, %{second | "locator" => %{"version" => 1, "kind" => "pdf", "page" => 1}}], digest},
      {[first, %{second | "text" => ""}], digest},
      {[first, %{second | "text" => String.duplicate("x", 65_537)}], digest},
      {List.duplicate(first, 4097), digest},
      {List.duplicate(%{first | "text" => String.duplicate("x", 65_536)}, 257), digest},
      {[first, second], :crypto.hash(:sha256, "wrong aggregate")},
      {[first, Map.put(second, "private_extra", C.canary())], digest}
    ]

    assert length(invalid) == 12
    before = S.attempt_rows(f)

    for {fragments, hash} <- invalid do
      assert {:error, %Postgrex.Error{} = raw} = C.sql_complete(f, fragments, hash)
      assert %Error{code: :invalid, message: nil, details: %{}} = KnowledgeError.from(raw)
      assert S.attempt_rows(f) == before
      assert S.fragments(f) == []
      C.no_projection!(f)
    end

    assert {:ok, %{state: :ready}} = C.complete(f, source, attempt, completion)
    assert S.fragments(f) == S.expected_fragments!(f, Singularity.Ingest.Documents.Text)
  end

  defp suspend_automatic_reconciler! do
    supervisor = Process.whereis(Singularity.Runtime.Supervisor)
    pid = Process.whereis(ExtractionReconciler)
    assert is_pid(supervisor) and is_pid(pid)
    assert node(supervisor) == node() and node(pid) == node()
    assert_reconciler_status!(pid, supervisor, :running)
    state = :sys.get_state(pid, @c3_system_timeout)
    assert state == %{repo: WorkerRepo}
    guard = %{pid: pid, supervisor: supervisor, state: state}

    # Arm cleanup before suspend; a timeout does not prove non-delivery.
    on_exit(fn ->
      try do
        assert Process.whereis(ExtractionReconciler) == pid
        assert :sys.get_state(pid, @c3_system_timeout) == state
      after
        # Never address a replacement registered child.
        assert :ok = :sys.resume(pid, @c3_system_timeout)
        assert_reconciler_status!(pid, supervisor, :running)
        assert :sys.get_state(pid, @c3_system_timeout) == state
      end
    end)

    assert :ok = :sys.suspend(pid, @c3_system_timeout)
    assert_reconciler_suspended!(guard)
    guard
  end

  defp assert_reconciler_status!(pid, supervisor, expected) do
    assert Process.whereis(Singularity.Runtime.Supervisor) == supervisor
    assert Process.whereis(ExtractionReconciler) == pid

    assert {:status, ^pid, {:module, :gen_server},
            [_dictionary, ^expected, ^supervisor, _debug, _status]} =
             :sys.get_status(pid, @c3_system_timeout)

    assert {:links, links} = Process.info(pid, :links)
    assert supervisor in links
  end

  defp assert_reconciler_suspended!(guard) do
    assert_reconciler_status!(guard.pid, guard.supervisor, :suspended)
    assert :sys.get_state(guard.pid, @c3_system_timeout) == guard.state
  end

  defp admit_alias_database! do
    assert [[database]] = S.owner_query("SELECT current_database()", []).rows

    assert [^database, suffix] =
             Regex.run(~r/\Asingularity_test_([0-9a-f]{24})\z/, database)

    assert MigrationRepo.config()[:database] == database
    assert WorkerRepo.config()[:database] == database

    assert %{rows: [[^database]]} =
             SafeSQL.query!(WorkerRepo, "SELECT current_database()", [])

    assert Application.fetch_env!(:singularity_storage, :storage_root) ==
             Path.join([System.tmp_dir!(), "singularity", "integration", suffix])

    config = Oban.config(Singularity.Oban)
    assert config.testing == :manual
    assert config.queues == []
    assert config.plugins == []
  end

  defp extracting_attempts!(excluded_version \\ nil) do
    rows =
      S.owner_query(
        """
        SELECT resource_version_id,vault_id,attempt_generation,attempt_job_id,
               extraction_adapter,extraction_format,attempt_started_at,attempt_deadline_at
        FROM content.document_versions
        WHERE state='extracting'
          AND ($1::uuid IS NULL OR resource_version_id <> $1)
        ORDER BY resource_version_id
        LIMIT 10001
        """,
        [excluded_version]
      ).rows

    assert length(rows) <= @c3_admission_limit
    rows
  end

  defp settle_prior_attempts! do
    admitted = extracting_attempts!()
    assert [[now]] = S.owner_query("SELECT clock_timestamp()", []).rows

    deadlines =
      Enum.map(admitted, fn
        [_version, _owner, _generation, _job, _adapter, _format, started, deadline] ->
          assert DateTime.diff(deadline, started, :microsecond) == 180_000_000
          assert DateTime.diff(deadline, now, :microsecond) <= 180_000_000
          deadline
      end)

    case deadlines do
      [] ->
        :ok

      [first | rest] ->
        maximum =
          Enum.reduce(rest, first, fn deadline, latest ->
            if DateTime.compare(deadline, latest) == :gt, do: deadline, else: latest
          end)

        wait_past_database_deadline!(maximum, System.monotonic_time(:millisecond) + 190_000)
    end

    assert extracting_attempts!() == admitted

    admitted_ids =
      MapSet.new(admitted, fn [version, owner | _] ->
        {Ecto.UUID.load!(version), Ecto.UUID.load!(owner)}
      end)

    maximum_scans = div(length(admitted) + 99, 100)

    result =
      Enum.reduce_while(0..maximum_scans, nil, fn _, _ ->
        assert {:ok, ids} =
                 DocumentRepository.list_expired_recovery_ids(%{repo: WorkerRepo}, 100)

        case ids do
          [] ->
            {:halt, :settled}

          [_ | _] ->
            assert Enum.all?(ids, &MapSet.member?(admitted_ids, &1))
            before = extracting_attempts!()
            assert {:ok, recovered} = ExtractionReconciler.run(%{repo: WorkerRepo})
            assert recovered == length(ids)
            remaining = extracting_attempts!()
            assert length(before) - length(remaining) == recovered
            assert MapSet.subset?(MapSet.new(remaining), MapSet.new(before))
            {:cont, nil}
        end
      end)

    assert result == :settled

    assert {:ok, []} =
             DocumentRepository.list_expired_recovery_ids(%{repo: WorkerRepo}, 100)

    residual = extracting_attempts!()
    assert MapSet.subset?(MapSet.new(residual), MapSet.new(admitted))
    residual
  end

  defp wait_past_database_deadline!(deadline, bound) do
    remaining_bound = bound - System.monotonic_time(:millisecond)
    assert remaining_bound > 0
    assert [[now]] = S.owner_query("SELECT clock_timestamp()", []).rows
    remaining = DateTime.diff(deadline, now, :millisecond)

    if remaining >= 0 do
      token = make_ref()
      delay = min(min(remaining + 2, 30_000), remaining_bound)
      timer = Process.send_after(self(), {:c3_settle_tick, token}, delay)

      try do
        receive do
          {:c3_settle_tick, ^token} -> :ok
        after
          delay + 1_000 -> flunk("C3 settling timer exceeded its bound")
        end
      after
        Process.cancel_timer(timer)
      end

      wait_past_database_deadline!(deadline, bound)
    end
  end

  defp bounded_settle!(fun) do
    owner = self()
    token = make_ref()

    pid =
      start_supervised!(%{
        id: token,
        restart: :temporary,
        shutdown: :brutal_kill,
        start:
          {Task, :start_link,
           [
             fn ->
               receive do
                 {^token, :start} -> send(owner, {token, self(), fun.()})
               after
                 5_000 -> exit(:c3_settle_start_timeout)
               end
             end
           ]}
      })

    monitor = Process.monitor(pid)
    send(pid, {token, :start})

    receive do
      {^token, ^pid, residual} ->
        assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
        residual

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        flunk("C3 prior-attempt settling failed")
    after
      @c3_settle_timeout ->
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 5_000
        flunk("C3 prior-attempt settling exceeded its bound")
    end
  end

  defp assert_c3_isolation!(isolation, fixture) do
    assert_reconciler_suspended!(isolation.guard)
    assert extracting_attempts!(fixture.document.resource_version_id) == isolation.residual
  end
end

defmodule Singularity.Runtime.DocumentOutcomeRunnerIntegrationTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  @moduletag :tmp_dir
  alias Singularity.Core.Error
  alias Singularity.Runtime.DocumentSourceIntegrationSupport, as: S
  alias Singularity.Runtime.DocumentOutcomeIntegrationSupport, as: C
  alias Singularity.Storage.Jobs.{GenericWorker, ObanAdapter}
  setup context, do: C.setup(context)

  for {retryable, attempt, maximum, expected} <- [
        {false, 1, 9, {:cancel, %{code: :job_failed}}},
        {true, 3, 3, {:error, %{code: :job_failed}}}
      ] do
    test "actual GenericWorker #{if retryable, do: "final retryable", else: "immediate nonretryable"} callback fails only matching active attempt",
         %{fixture: f} do
      {_source, claimed} = C.claim_by_interruption!(f)
      S.clear(f)

      failure =
        Error.new(:storage_unavailable,
          retryable?: unquote(retryable),
          message: C.canary(),
          details: %{private: C.canary()}
        )

      C.configure_runner!(f, handler_mode: {:error, failure})

      assert unquote(Macro.escape(expected)) ==
               GenericWorker.perform(C.job(f, unquote(attempt), unquote(maximum)))

      assert [{:c_callback, _, metadata}] =
               Enum.filter(S.events(f), &(elem(&1, 0) == :c_callback))

      assert metadata == %{attempt: unquote(attempt), max_attempts: unquote(maximum)}

      assert [{:c_terminal_result, _, {:ok, %{state: :failed, generation: 1}}}] =
               Enum.filter(S.events(f), &(elem(&1, 0) == :c_terminal_result))

      assert [["failed", 1, job, "plain_text", 1, started, deadline, nil]] = S.attempt_rows(f)
      assert job == Ecto.UUID.dump!(claimed.job_id)
      assert started == claimed.started_at and deadline == claimed.deadline_at
      assert S.fragments(f) == []
      C.no_projection!(f)
      refute :leased in S.keys(f)
    end
  end

  test "nonfinal retryable GenericWorker error never invokes terminal hook", %{fixture: f} do
    C.claim_by_interruption!(f)
    before = S.attempt_rows(f)
    S.clear(f)

    C.configure_runner!(f,
      handler_mode: {:error, Error.new(:storage_unavailable, retryable?: true)}
    )

    assert {:error, %{code: :job_failed}} = GenericWorker.perform(C.job(f, 2, 3))
    refute :c_callback in S.keys(f)
    refute :c_terminal in S.keys(f)
    assert S.attempt_rows(f) == before
    assert S.fragments(f) == []
    C.no_projection!(f)
  end

  @tag locked?: true
  test "terminal callback cannot turn unclaimed locked pending work into failed", %{fixture: f} do
    C.configure_runner!(f, handler_mode: {:error, Error.new(:job_failed)})
    assert {:cancel, %{code: :job_failed}} = GenericWorker.perform(C.job(f, 1, 1))

    assert [{:c_terminal_result, _, {:ok, :unchanged}}] =
             Enum.filter(S.events(f), &(elem(&1, 0) == :c_terminal_result))

    S.pending!(f)
    refute :leased in S.keys(f)
    assert S.progress(f) == []
  end

  for terminal <- [:ready, :failed, :unsupported] do
    test "terminal GenericWorker exhaustion leaves #{terminal} receipt and fragments unchanged",
         %{fixture: f} do
      S.terminal_receipt!(f, unquote(terminal))
      before = {S.attempt_rows(f), S.fragments(f)}
      S.clear(f)

      C.configure_runner!(f,
        handler_mode: {:error, Error.new(:storage_unavailable, retryable?: true)}
      )

      assert {:error, %{code: :job_failed}} = GenericWorker.perform(C.job(f, 3, 3))

      assert [{:c_terminal_result, _, {:ok, :unchanged}}] =
               Enum.filter(S.events(f), &(elem(&1, 0) == :c_terminal_result))

      assert {S.attempt_rows(f), S.fragments(f)} == before
      refute :leased in S.keys(f)
      C.no_projection!(f)
    end
  end

  test "old logical job exhaustion cannot overwrite another job's active successor", %{fixture: f} do
    S.seed_terminal!(f, :failed)
    C.mutation!(f, :retry)
    successor = C.successor!(f, 2)
    S.clear(f)
    {_source, attempt} = C.claim_by_interruption!(successor)
    assert attempt.generation == 3
    before = S.attempt_rows(f)
    S.clear(f)
    C.configure_runner!(f, handler_mode: {:error, Error.new(:job_failed)})
    assert {:cancel, %{code: :job_failed}} = GenericWorker.perform(C.job(f, 1, 1))

    assert [{:c_terminal_result, _, {:ok, :unchanged}}] =
             Enum.filter(S.events(f), &(elem(&1, 0) == :c_terminal_result))

    assert S.attempt_rows(f) == before
    assert S.fragments(f) == []
    C.no_projection!(f)
  end

  test "actual authority denial propagates from exhaustion and GenericWorker cancels", %{
    fixture: f
  } do
    C.claim_by_interruption!(f)
    before = S.attempt_rows(f)

    S.owner_query(
      "UPDATE core.principal_capabilities SET revoked_at=CURRENT_TIMESTAMP WHERE principal_id=$1 AND vault_id=$2",
      [f.source.principal_id, f.source.vault_id]
    )

    assert {:error, %Error{code: :forbidden, message: nil, details: %{}}} = C.exhaustion(f)

    C.configure_runner!(f,
      handler_mode: {:error, Error.new(:storage_unavailable, retryable?: true)}
    )

    assert {:cancel, %{code: :job_failed}} = GenericWorker.perform(C.job(f, 3, 3))
    assert S.attempt_rows(f) == before
    assert S.fragments(f) == []
  end

  test "actual recorder SQL error propagates rather than becoming unchanged", %{fixture: f} do
    C.claim_by_interruption!(f)
    before = S.attempt_rows(f)

    assert {:error,
            %Error{code: :storage_unavailable, retryable?: true, message: nil, details: %{}}} =
             C.exhaustion(f, recorder_fault?: true)

    S.clear(f)
    C.configure_runner!(f, recorder_fault?: true, handler_mode: {:error, Error.new(:job_failed)})
    assert {:error, %{code: :job_failed}} = GenericWorker.perform(C.job(f, 1, 1))

    assert [{:c_terminal_result, _, {:error, %Error{code: :storage_unavailable}}}] =
             Enum.filter(S.events(f), &(elem(&1, 0) == :c_terminal_result))

    assert S.attempt_rows(f) == before
    assert S.fragments(f) == []
    C.no_projection!(f)
  end

  @tag locked?: true
  @tag wake?: true
  test "actual unlock wake shortens snooze and Basic restores attempt without max_attempts change",
       %{fixture: f} do
    assert [[4, 37, json, "running"]] = S.seed_v4!(f)
    name = elem(f.wake, 1)
    assert {:ok, id} = ObanAdapter.submit(%{oban_name: name}, f.envelope)
    id = String.to_integer(id)
    queue = "document_c4_" <> Integer.to_string(id)

    assert [["document_extract"]] =
             S.owner_query("SELECT queue FROM jobs.oban_jobs WHERE id=$1", [id]).rows

    assert %{num_rows: 1} =
             S.owner_query(
               "UPDATE jobs.oban_jobs SET queue=$2 WHERE id=$1 AND queue='document_extract'",
               [id, queue]
             )

    assert [[1]] =
             S.owner_query("SELECT count(*) FROM jobs.oban_jobs WHERE queue=$1", [queue]).rows

    conf = Oban.config(name)
    assert {:ok, meta} = Oban.Engines.Basic.init(conf, queue: queue, limit: 1)

    assert {:ok, {meta, [%Oban.Job{id: ^id, queue: ^queue, attempt: 1} = fetched]}} =
             Oban.Engines.Basic.fetch_jobs(conf, meta, %{})

    maximum = fetched.max_attempts
    C.configure_runner!(f)
    token = S.barrier!(f, :c_waiting_saved)
    owner = self()
    result_token = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        send(owner, {result_token, :result, GenericWorker.perform(%{fetched | conf: conf})})
      end)

    on_exit(fn -> S.stop_owned(pid) end)
    {^pid, :saved} = S.await_barrier!(f, :c_waiting_saved, token)
    assert [[4, 37, ^json, "waiting_for_unlock"]] = S.progress(f)
    assert :ok = S.activate!(f)

    assert [[1, 0]] =
             S.owner_query(
               "SELECT wake_requested_generation,wake_consumed_generation FROM jobs.job_submissions WHERE id=$1",
               [Ecto.UUID.dump!(f.envelope.job_id)]
             ).rows

    send(pid, {token, :continue})
    assert_receive {^result_token, :result, {:snooze, 1}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
    refute :c_callback in S.keys(f)
    refute :c_terminal in S.keys(f)
    S.pending!(f)

    assert [[1, 1]] =
             S.owner_query(
               "SELECT wake_requested_generation,wake_consumed_generation FROM jobs.job_submissions WHERE id=$1",
               [Ecto.UUID.dump!(f.envelope.job_id)]
             ).rows

    assert :ok = Oban.Engines.Basic.snooze_job(conf, fetched, 1)

    assert [["scheduled", 0, ^maximum, %{"snoozed" => 1}]] =
             S.owner_query(
               "SELECT state,attempt,max_attempts,meta FROM jobs.oban_jobs WHERE id=$1",
               [id]
             ).rows

    assert [[4, 37, ^json, "waiting_for_unlock"]] = S.progress(f)
    S.owner_query("UPDATE jobs.oban_jobs SET state='available' WHERE id=$1", [id])

    assert {:ok,
            {_meta,
             [%Oban.Job{id: ^id, queue: ^queue, attempt: 1, max_attempts: ^maximum} = resumed]}} =
             Oban.Engines.Basic.fetch_jobs(conf, meta, %{})

    assert :ok = GenericWorker.perform(%{resumed | conf: conf})
    assert :ok = Oban.Engines.Basic.complete_job(conf, resumed)

    assert [["completed", 1, ^maximum]] =
             S.owner_query("SELECT state,attempt,max_attempts FROM jobs.oban_jobs WHERE id=$1", [
               id
             ]).rows

    assert [[4, 37, ^json, "running"]] = S.progress(f)
    refute :c_callback in S.keys(f)
    C.no_projection!(f)
  end
end

defmodule Singularity.Runtime.DocumentOutcomePrivacyIntegrationTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag :wake?
  @moduletag :private_title?
  @moduletag plaintext: "# CANARY_C_PRIVATE_TITLE_SOURCE_LOCATOR_TOOL_SQL\n\nprivate body"
  @moduletag media_type: "text/markdown"
  import ExUnit.CaptureLog
  alias Singularity.Core.Error
  alias Singularity.Runtime.DocumentSourceIntegrationSupport, as: S
  alias Singularity.Runtime.DocumentOutcomeIntegrationSupport, as: C
  alias Singularity.Storage.{DispatcherRepo, MigrationRepo, PreAuthRepo, SafeSQL}
  alias Singularity.Storage.Jobs.ObanAdapter
  setup context, do: C.setup(context)

  test "real ready runner stores private canonical content but no metadata surface leaks it", %{
    fixture: f
  } do
    capture_private!(f, [], :success)

    assert [[C.canary()]] ==
             S.owner_query(
               "SELECT title FROM content.document_versions WHERE resource_version_id=$1",
               [f.document.resource_version_id]
             ).rows

    assert Enum.any?(S.fragments(f), fn [_, _, text, _, locator] ->
             String.contains?(text, C.canary()) and String.contains?(inspect(locator), C.canary())
           end)
  end

  test "actual source authentication failure exposes no source title or key through runner errors",
       %{fixture: f} do
    S.corrupt!(f, :data)
    assert {:error, %Error{code: :integrity_failure, message: nil, details: %{}}} = C.run(f)
    capture_private!(f, [], :cancelled)
    S.pending!(f)
    assert S.fragments(f) == []
  end

  test "actual post-claim SQL diagnostic and parameter failure remains private in Oban persisted errors",
       %{fixture: f} do
    assert {:error, %Error{code: :storage_unavailable, message: nil, details: %{}}} =
             C.run(f, complete_fault?: true)

    capture_private!(f, [complete_fault?: true], :failure)
    assert [["extracting", 1, _, _, _, _, _, nil]] = S.attempt_rows(f)
    assert S.fragments(f) == []
    C.no_projection!(f)
  end

  for mode <- [:raise, :throw] do
    @tag media_type: "text/plain"
    test "#{mode} private extractor exception remains bounded through real successful runner receipt",
         %{fixture: f} do
      capture_private!(f, [mode: unquote(mode)], :success)
      assert [["failed", 1, _, _, _, _, _, nil]] = S.attempt_rows(f)
      assert S.fragments(f) == []
      C.no_projection!(f)
    end
  end

  for mode <- [:raise, :throw] do
    test "#{mode} private handler fallback produces real sanitized Oban exception without terminal hook",
         %{fixture: f} do
      capture_private!(f, [handler_mode: unquote(mode)], :failure)
      refute :c_callback in S.keys(f)
      S.pending!(f)
    end
  end

  for mode <- [:timeout, :tool_exit] do
    @tag plaintext: S.pdf_bytes()
    @tag media_type: "application/pdf"
    test "actual #{mode} private tool failure produces no stderr or source metadata leakage", %{
      fixture: f
    } do
      capture_private!(f, [mode: unquote(mode)], :success)
      pid_path = Path.join(f.root, "owned-tool-pid")
      assert File.regular?(pid_path)
      assert {pid, ""} = Integer.parse(File.read!(pid_path))
      assert pid > 0
      refute File.exists?("/proc/#{pid}")
      expected_code = if unquote(mode) == :timeout, do: "timeout", else: "extractor_failed"

      assert [[expected_code]] ==
               S.owner_query(
                 "SELECT failure_code FROM content.document_versions WHERE resource_version_id=$1 AND vault_id=$2",
                 [f.document.resource_version_id, f.source.vault_id]
               ).rows

      assert [["failed", 1, _, _, _, _, _, nil]] = S.attempt_rows(f)
      assert S.fragments(f) == []
      C.no_projection!(f)
    end
  end

  @doc false
  def event(event, measurements, metadata, {owner, token}),
    do: send(owner, {token, :event, event, measurements, metadata})

  defp capture_private!(f, options, expected_state) do
    Singularity.Storage.WorkerDocumentReadAssertions.assert_read_only_rls!()
    C.configure_runner!(f, options)
    assert f.envelope.causation_id == f.envelope.job_id

    assert [[nil]] ==
             S.owner_query(
               "SELECT causation_id FROM core.outbox_events WHERE id=$1 AND vault_id=$2",
               [Ecto.UUID.dump!(f.envelope.job_id), f.source.vault_id]
             ).rows

    assert {:ok, encoded} = Singularity.Storage.Jobs.EnvelopeCodec.encode(f.envelope)
    assert {:ok, decoded} = Singularity.Storage.Jobs.EnvelopeCodec.decode(encoded)
    assert decoded == f.envelope
    name = elem(f.wake, 1)
    assert {:ok, id} = ObanAdapter.submit(%{oban_name: name}, f.envelope)
    id = String.to_integer(id)
    queue = "document_c5_" <> Integer.to_string(id)

    assert [["document_extract"]] =
             S.owner_query("SELECT queue FROM jobs.oban_jobs WHERE id=$1", [id]).rows

    assert %{num_rows: 1} =
             S.owner_query(
               "UPDATE jobs.oban_jobs SET queue=$2 WHERE id=$1 AND queue='document_extract'",
               [id, queue]
             )

    assert [[1]] =
             S.owner_query("SELECT count(*) FROM jobs.oban_jobs WHERE queue=$1", [queue]).rows

    conf = Oban.config(name)
    assert {:ok, meta} = Oban.Engines.Basic.init(conf, queue: queue, limit: 1)

    assert {:ok, {_meta, [%Oban.Job{id: ^id, queue: ^queue} = fetched]}} =
             Oban.Engines.Basic.fetch_jobs(conf, meta, %{})

    audit_before = audit(f)
    token = make_ref()
    handler = {__MODULE__, token}
    repos = [WorkerRepo, RequestRepo, DispatcherRepo, PreAuthRepo, MigrationRepo]
    query_events = Enum.uniq(Enum.map(repos, &(&1.config()[:telemetry_prefix] ++ [:query])))
    denial = [:singularity, :authorization, :rls_denial]
    retry_event = [:singularity, :job, :retry]
    failure_event = [:singularity, :job, :failure]

    events =
      query_events ++
        [
          denial,
          retry_event,
          failure_event,
          [:oban, :job, :start],
          [:oban, :job, :stop],
          [:oban, :job, :exception]
        ]

    assert Enum.any?(
             :telemetry.list_handlers([:oban, :job, :exception]),
             &(&1.id == Singularity.Runtime.Observability.Telemetry)
           )

    assert :ok = :telemetry.attach_many(handler, events, &__MODULE__.event/4, {self(), token})
    on_exit(fn -> :telemetry.detach(handler) end)
    owner = self()

    logs =
      capture_log(fn ->
        execution =
          conf
          |> Oban.Queues.Executor.new(%{fetched | conf: conf}, ack: true)
          |> Oban.Queues.Executor.call()

        send(owner, {token, :execution, execution})

        assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
                 SafeSQL.query(
                   WorkerRepo,
                   "SELECT state FROM content.document_import_receipts WHERE state=$1",
                   [C.canary()]
                 )
      end)

    assert_receive {^token, :execution, execution}, 5_000
    assert execution.state == expected_state
    captured = drain(token, [])
    assert Enum.any?(captured, fn {event, _, _} -> event == [:oban, :job, :start] end)

    assert Enum.any?(captured, fn {event, _, metadata} ->
             event == denial and metadata == %{repo: :worker}
           end)

    terminal_event =
      if expected_state == :failure, do: [:oban, :job, :exception], else: [:oban, :job, :stop]

    assert Enum.any?(captured, fn {event, _, _} -> event == terminal_event end)
    refute Enum.any?(captured, fn {event, _, _} -> event in query_events end)

    bounded_event =
      case expected_state do
        :failure -> retry_event
        :cancelled -> failure_event
        :success -> nil
      end

    if bounded_event do
      assert Enum.any?(captured, fn {event, measurements, metadata} ->
               event == bounded_event and measurements == %{count: 1} and
                 metadata == %{
                   attempt: fetched.attempt,
                   max_attempts: fetched.max_attempts,
                   queue: :unknown,
                   worker: :generic_worker
                 }
             end)
    else
      refute Enum.any?(captured, fn {event, _, _} -> event in [retry_event, failure_event] end)
    end

    inspected_source = inspect(f.plaintext, limit: :infinity, printable_limit: :infinity)

    assert String.contains?(
             inspect(%{leaked_source: f.plaintext}, limit: :infinity, printable_limit: :infinity),
             inspected_source
           )

    secrets = [
      C.canary(),
      "runtime_c_private_failure",
      f.plaintext,
      inspected_source,
      inspect(f.domain_key),
      Base.encode16(f.domain_key),
      Base.encode64(f.domain_key)
    ]

    public = inspect(execution.result, limit: :infinity, printable_limit: :infinity)
    telemetry = inspect(captured, limit: :infinity, printable_limit: :infinity)
    persisted = persisted(f, id)

    for secret <- secrets do
      refute String.contains?(logs, secret)
      refute String.contains?(public, secret)
      refute String.contains?(telemetry, secret)

      refute String.contains?(
               inspect(persisted, limit: :infinity, printable_limit: :infinity),
               secret
             )
    end

    assert audit(f) == audit_before
    assert :ok = :telemetry.detach(handler)
    assert DynamicSupervisor.which_children(f.lease_supervisor) == []
  end

  defp drain(token, events) do
    receive do
      {^token, :event, name, measurements, metadata} ->
        drain(token, [{name, measurements, metadata} | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp audit(f),
    do:
      S.owner_query("SELECT metadata FROM audit.events WHERE vault_id=$1 ORDER BY id", [
        f.source.vault_id
      ]).rows

  defp persisted(f, id) do
    assert [[payload]] =
             S.owner_query("SELECT payload FROM core.outbox_events WHERE id=$1", [
               Ecto.UUID.dump!(f.envelope.job_id)
             ]).rows

    assert Map.keys(payload) |> Enum.sort() == ["resource_id", "resource_version_id"]

    assert [[args, meta, errors]] =
             S.owner_query("SELECT args,meta,errors FROM jobs.oban_jobs WHERE id=$1", [id]).rows

    assert args["payload"] == payload

    checkpoint =
      case S.owner_query("SELECT checkpoint FROM jobs.job_progress WHERE submission_id=$1", [
             Ecto.UUID.dump!(f.envelope.job_id)
           ]).rows do
        [] -> nil
        [[value]] -> value
      end

    outbox_rows =
      S.owner_query(
        "SELECT to_jsonb(e) FROM core.outbox_events e WHERE vault_id=$1 ORDER BY id",
        [f.source.vault_id]
      ).rows

    submission_rows =
      S.owner_query(
        "SELECT to_jsonb(s) FROM jobs.job_submissions s WHERE vault_id=$1 ORDER BY id",
        [f.source.vault_id]
      ).rows

    progress_rows =
      S.owner_query("SELECT to_jsonb(p) FROM jobs.job_progress p WHERE vault_id=$1 ORDER BY id", [
        f.source.vault_id
      ]).rows

    runner_rows =
      S.owner_query(
        "SELECT to_jsonb(j) FROM jobs.oban_jobs j WHERE args->>'vault_id'=$1 ORDER BY id",
        [f.vault_id]
      ).rows

    audit_rows =
      S.owner_query("SELECT to_jsonb(a) FROM audit.events a WHERE vault_id=$1 ORDER BY id", [
        f.source.vault_id
      ]).rows

    assert outbox_rows != [] and submission_rows != [] and runner_rows != []

    %{
      outbox: payload,
      args: args,
      meta: meta,
      errors: errors,
      checkpoint: checkpoint,
      outbox_rows: outbox_rows,
      submission_rows: submission_rows,
      progress_rows: progress_rows,
      runner_rows: runner_rows,
      audit_rows: audit_rows
    }
  end
end

defmodule Singularity.Runtime.DocumentOutcomeFixtureMetadataTest do
  use ExUnit.Case, async: true

  test "large Document outcome fixtures are deferred without changing integration metadata" do
    tests = Singularity.Runtime.DocumentOutcomeIntegrationTest.__ex_unit__().tests
    assert length(tests) == 24

    fixtures = [
      {:"test exact 64 MiB authenticated source reaches ready without source loss",
       :source_limit},
      {:"test actual normalized text above 16 MiB persists unsupported output_too_large",
       :normalized_over_limit},
      {:"test exact 16 MiB normalized output and 65536-byte fragments persist ready",
       :normalized_fragment_limit}
    ]

    metadata =
      for {name, selector} <- fixtures do
        assert [test] = Enum.filter(tests, &(&1.name == name))
        {test, selector}
      end

    for {test, selector} <- metadata do
      assert test.tags[:plaintext_fixture] == selector
      refute Map.has_key?(test.tags, :plaintext)
      assert test.tags[:integration] == true
      assert test.tags[:tmp_dir] == true
      assert test.tags[:timeout] == 120_000
    end
  end
end
