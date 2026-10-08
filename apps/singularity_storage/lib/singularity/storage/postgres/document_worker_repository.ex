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
