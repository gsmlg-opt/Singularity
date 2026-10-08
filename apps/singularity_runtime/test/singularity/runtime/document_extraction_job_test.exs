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
