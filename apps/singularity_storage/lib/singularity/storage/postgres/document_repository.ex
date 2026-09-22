defmodule Singularity.Storage.Postgres.DocumentRepository do
  @moduledoc """
  Internal authenticated Document adapter. Context is a plain map carrying
  `repo`, `principal_id`, and `owner_scope_id`. Creation additionally requires
  a trusted `digest_operation` and a storage-owned 32-byte `fingerprint_secret`.
  No live custody composition or caller-supplied preparation proof is accepted.
  """
  @behaviour Singularity.Domains.Documents.Repository
  import Ecto.Query

  alias Singularity.Core.{
    DocumentCompletion,
    DocumentFragment,
    DocumentSource,
    DocumentVersion,
    Error,
    SourceLocator
  }

  alias Singularity.Domains.Documents.Command
  alias Singularity.Storage.{SafeSQL, ScopedRepo}
  alias Singularity.Storage.WorkerRepo
  alias Singularity.Storage.Documents.PrepareSource

  alias Singularity.Storage.Postgres.{
    DocumentMutationReceipts,
    DocumentSourceRepository,
    KnowledgeError,
    UUID
  }

  alias Singularity.Storage.Schema.Content.{Resource, ResourceVersion}
  alias Singularity.Storage.Schema.Content.DocumentVersion, as: StoredDocument
  alias Singularity.Storage.Schema.Content.DocumentFragment, as: StoredFragment
  alias Singularity.Storage.Schema.Core.OutboxEvent

  @impl true
  def create_pending(context, input) do
    with {:ok, repo} <- context_repo(context),
         {:ok, command} <- Command.new(input),
         true <-
           command.principal_id == context.principal_id and
             command.owner_scope_id == context.owner_scope_id,
         {:ok, secret} <- secret(context),
         {:ok, prepared} <-
           PrepareSource.prepare(context, %{
             context: auth_context(context),
             asset_id: command.source.asset_id
           }),
         true <- prepared.source == command.source do
      fingerprint =
        :crypto.mac(
          :hmac,
          :sha256,
          secret,
          :erlang.term_to_binary(Command.fingerprint_term(command), [:deterministic])
        )

      scoped(repo, context, fn transaction_repo ->
        claim = %{
          owner_scope_id: context.owner_scope_id,
          principal_id: context.principal_id,
          mutation_id: command.mutation_id,
          fingerprint: fingerprint,
          inserted_at: command.inserted_at
        }

        with {:ok, identity} <-
               DocumentMutationReceipts.with_claim(transaction_repo, claim, fn ->
                 with {:ok, _} <-
                        DocumentSourceRepository.revalidate(
                          transaction_repo,
                          auth_context(context),
                          prepared
                        ),
                      :ok <- persist(transaction_repo, command),
                      :ok <- request_extraction(transaction_repo, command) do
                   {:ok, Map.take(command, [:resource_id, :resource_version_id])}
                 end
               end),
             {:ok, _} <-
               DocumentSourceRepository.revalidate(
                 transaction_repo,
                 auth_context(context),
                 prepared
               ) do
          load(transaction_repo, context, identity.resource_id, identity.resource_version_id)
        end
      end)
    else
      false -> error(:conflict)
      {:error, %Error{} = reason} -> {:error, KnowledgeError.from(reason)}
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  @doc "Looks up a completed import in an already authenticated scoped transaction."
  @spec find_import_receipt_scoped(module(), map(), String.t()) ::
          {:ok, DocumentVersion.t()} | {:error, Error.t()}
  def find_import_receipt_scoped(
        repo,
        %{principal_id: principal, vault_id: owner},
        mutation_id
      )
      when is_atom(repo) do
    with true <- repo.in_transaction?(),
         :ok <- UUID.validate([principal, owner, mutation_id]),
         %{rows: [[^principal, ^owner]]} <-
           SafeSQL.query!(
             repo,
             "SELECT current_setting('singularity.principal_id',true), current_setting('singularity.vault_id',true)",
             []
           ) do
      case SafeSQL.query!(
             repo,
             "SELECT state,resource_id,version_id FROM content.document_import_receipts WHERE vault_id=$1 AND principal_id=$2 AND mutation_id=$3",
             [Ecto.UUID.dump!(owner), Ecto.UUID.dump!(principal), Ecto.UUID.dump!(mutation_id)]
           ) do
        %{rows: []} ->
          error(:not_found)

        %{rows: [["completed", resource, version]]}
        when not is_nil(resource) and not is_nil(version) ->
          load(
            repo,
            %{owner_scope_id: owner},
            Ecto.UUID.load!(resource),
            Ecto.UUID.load!(version)
          )

        _ ->
          error(:conflict)
      end
    else
      false -> error(:invalid)
      {:error, %Error{}} = result -> result
      _ -> error(:forbidden)
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  def find_import_receipt_scoped(_, _, _), do: error(:invalid)

  @impl true
  def get_version(context, resource, version) do
    with {:ok, repo} <- context_repo(context), :ok <- UUID.validate([resource, version]) do
      scoped(repo, context, &load(&1, context, resource, version))
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  @impl true
  def claim(context, version, generation, job_id, adapter, format) do
    with :ok <- generation(generation),
         :ok <- canonical_job(job_id),
         true <-
           is_binary(adapter) and String.valid?(adapter) and String.trim(adapter) != "" and
             byte_size(adapter) <= 255 and not String.contains?(adapter, <<0>>),
         true <- is_integer(format) and format in 1..2_147_483_647 do
      lifecycle(context, version, "claim_document_extraction", [
        generation,
        Ecto.UUID.dump!(job_id),
        adapter,
        format
      ])
    else
      _ -> error(:invalid)
    end
  end

  @impl true
  def reset_failed(context, version, generation, adapter, format) do
    with :ok <- generation(generation),
         true <- valid_adapter?(adapter) and is_integer(format) and format in 1..2_147_483_647 do
      lifecycle(context, version, "reset_document_extraction", [generation, adapter, format])
    else
      _ -> error(:invalid)
    end
  end

  @impl true
  def recover_expired(context, version, generation) do
    with :ok <- generation(generation),
         do: lifecycle(context, version, "recover_document_extraction", [generation])
  end

  @doc "Enumerates at most 100 expired version/owner ID pairs for the worker reconciler."
  def list_expired_recovery_ids(%{repo: WorkerRepo}, limit)
      when is_integer(limit) and limit in 1..100 do
    case SafeSQL.query(
           WorkerRepo,
           "SELECT version_id,owner_id FROM content.expired_document_extraction_ids($1)",
           [limit]
         ) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [version, owner] ->
           {Ecto.UUID.load!(version), Ecto.UUID.load!(owner)}
         end)}

      {:error, reason} ->
        {:error, KnowledgeError.from(reason)}
    end
  end

  def list_expired_recovery_ids(_, _), do: error(:invalid)

  @doc "Atomically resets one expired attempt and writes its successor event."
  def recover_expired_with_event(%{repo: WorkerRepo}, version, owner) do
    with :ok <- UUID.validate([version, owner]) do
      case WorkerRepo.transaction(fn ->
             SafeSQL.query!(
               WorkerRepo,
               "SELECT content.recover_expired_document_with_event($1,$2)",
               [Ecto.UUID.dump!(version), Ecto.UUID.dump!(owner)]
             )
           end) do
        {:ok, %{rows: [[recovered?]]}} -> {:ok, recovered?}
        {:error, reason} -> {:error, KnowledgeError.from(reason)}
      end
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  def recover_expired_with_event(_, _, _), do: error(:invalid)

  @impl true
  def complete(context, job_id, input) do
    with {:ok, repo} <- context_repo(context),
         :ok <- canonical_job(job_id),
         {:ok, completion} <- DocumentCompletion.new(input),
         true <- completion.owner_scope_id == context.owner_scope_id do
      scoped(repo, context, fn transaction_repo ->
        with {:ok, current} <-
               load_for_attempt(
                 transaction_repo,
                 context,
                 completion.resource_id,
                 completion.resource_version_id,
                 job_id,
                 completion.generation
               ),
             true <-
               completion.adapter_name == current.adapter_name and
                 completion.format_version == current.format_version and
                 completion.media_type == current.source.media_type do
          {function, args} = completion_args(completion)

          invoke(
            transaction_repo,
            context,
            completion.resource_version_id,
            function,
            [Ecto.UUID.dump!(job_id) | args],
            {job_id, completion.generation}
          )
        else
          false -> error(:conflict)
          {:error, %Error{}} = result -> result
        end
      end)
    else
      false -> error(:forbidden)
      {:error, %Error{} = reason} -> {:error, KnowledgeError.from(reason)}
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  defp lifecycle(context, version, function, args) do
    with {:ok, repo} <- context_repo(context), :ok <- UUID.validate(version) do
      scoped(repo, context, &invoke(&1, context, version, function, args))
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  # Function names and placeholder lists are internal constants; data is always bound.
  defp invoke(repo, context, version, function, args, attempt \\ nil) do
    placeholders =
      case function do
        "claim_document_extraction" ->
          "$1::uuid,$2::bigint,$3::uuid,$4::text,$5::integer"

        "reset_document_extraction" ->
          "$1::uuid,$2::bigint,$3::text,$4::integer"

        "recover_document_extraction" ->
          "$1::uuid,$2::bigint"

        "fail_document_extraction" ->
          "$1::uuid,$2::uuid,$3::bigint,$4::text,$5::text"

        "complete_document_extraction" ->
          "$1::uuid,$2::uuid,$3::bigint,$4::jsonb,$5::bytea,$6::text"
      end

    %{rows: [[resource]]} =
      SafeSQL.query!(
        repo,
        "SELECT resource_id FROM content.#{function}(#{placeholders})",
        [Ecto.UUID.dump!(version) | args]
      )

    case attempt do
      nil ->
        load(repo, context, Ecto.UUID.load!(resource), version)

      {job_id, generation} ->
        load_for_attempt(repo, context, Ecto.UUID.load!(resource), version, job_id, generation)
    end
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

    {"complete_document_extraction",
     [
       completion.generation,
       fragments,
       completion.extracted_text_digest,
       completion.detected_language
     ]}
  end

  defp completion_args(completion),
    do:
      {"fail_document_extraction",
       [completion.generation, Atom.to_string(completion.outcome), completion.failure_code]}

  defp persist(repo, command) do
    common = %{vault_id: command.owner_scope_id, classification: :private}

    resource =
      Resource.create_changeset(
        %Resource{},
        Map.merge(common, %{
          id: command.resource_id,
          kind: :document,
          title: command.title,
          current_version_id: command.resource_version_id,
          metadata: %{}
        })
      )

    version =
      ResourceVersion.create_changeset(
        %ResourceVersion{},
        Map.merge(common, %{
          id: command.resource_version_id,
          resource_id: command.resource_id,
          revision: 0
        })
      )

    source = command.source

    typed =
      StoredDocument.create_changeset(
        %StoredDocument{},
        Map.merge(common, %{
          resource_version_id: command.resource_version_id,
          resource_id: command.resource_id,
          source_asset_id: source.asset_id,
          source_resource_id: source.resource_id,
          source_resource_version_id: source.resource_version_id,
          source_object_id: source.object_id,
          source_digest: source.digest,
          source_byte_size: source.byte_size,
          media_type: source.media_type,
          title: command.title,
          created_by_principal_id: command.principal_id,
          inserted_at: command.inserted_at
        })
      )

    with {:ok, _} <- repo.insert(resource, log: false),
         {:ok, _} <- repo.insert(version, log: false),
         {:ok, _} <- repo.insert(typed, log: false) do
      SafeSQL.query!(
        repo,
        """
        SET CONSTRAINTS content.resources_version_head_fkey,
          content.resource_versions_resource_classification_fkey,
          content.document_versions_resource_version_fkey,
          content.document_versions_source_asset_fkey,
          content.document_versions_source_version_fkey,
          content.document_versions_source_association_fkey,
          content.document_versions_source_object_fkey,
          content.resources_00_typed_head_check,
          content.document_versions_00_typed_head_check IMMEDIATE
        """,
        []
      )

      :ok
    else
      {:error, reason} -> {:error, KnowledgeError.from(reason)}
    end
  end

  defp request_extraction(repo, command) do
    with {:ok, epochs} <- authorization_epochs(repo, command),
         {:ok, _event} <-
           repo.insert(
             OutboxEvent.create_changeset(
               %OutboxEvent{},
               Map.merge(epochs, %{
                 id: Ecto.UUID.generate(),
                 event_type: "document.extraction_requested",
                 idempotency_key: "document-extraction:#{command.resource_version_id}",
                 vault_id: command.owner_scope_id,
                 principal_id: command.principal_id,
                 required_capability: "asset.read",
                 classification: :private,
                 correlation_id: command.correlation_id,
                 causation_id: command.mutation_id,
                 expected_entity_revision: 0,
                 envelope_version: 1,
                 payload: %{
                   "resource_id" => command.resource_id,
                   "resource_version_id" => command.resource_version_id
                 },
                 occurred_at: DateTime.utc_now(:microsecond)
               })
             ),
             log: false
           ) do
      :ok
    else
      {:error, reason} -> {:error, KnowledgeError.from(reason)}
    end
  end

  defp authorization_epochs(repo, command) do
    case SafeSQL.query(
           repo,
           """
           SELECT principal_authorization_epoch, vault_authorization_epoch,
                  principal_revoked_at, membership_revoked_at, vault_locked,
                  capabilities
           FROM core.live_principal_authorization()
           WHERE principal_id = $1 AND vault_id = $2
           """,
           [Ecto.UUID.dump!(command.principal_id), Ecto.UUID.dump!(command.owner_scope_id)]
         ) do
      {:ok, %{rows: [[principal_epoch, vault_epoch, nil, nil, false, capabilities]]}}
      when is_integer(principal_epoch) and principal_epoch >= 0 and
             is_integer(vault_epoch) and vault_epoch >= 0 and is_list(capabilities) ->
        if "asset.read" in capabilities do
          {:ok,
           %{
             principal_authorization_epoch: principal_epoch,
             vault_authorization_epoch: vault_epoch
           }}
        else
          error(:forbidden)
        end

      {:ok, %{rows: []}} ->
        error(:forbidden)

      {:ok, %{rows: [[_, _, _, _, _, _]]}} ->
        error(:forbidden)

      {:ok, _} ->
        error(:integrity_failure)

      {:error, _} ->
        {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  defp load(repo, context, resource, version) do
    query =
      from d in StoredDocument,
        join: v in ResourceVersion,
        on: v.id == d.resource_version_id and v.resource_id == d.resource_id,
        join: r in Resource,
        on: r.id == d.resource_id and r.vault_id == d.vault_id,
        where:
          d.resource_version_id == ^version and d.resource_id == ^resource and
            d.vault_id == ^context.owner_scope_id,
        where: d.classification == :private and r.kind == :document and is_nil(r.deleted_at),
        select: {d, v.revision}

    case repo.one(query, log: false) do
      nil -> error(:not_found)
      {row, revision} -> hydrate(repo, row, revision)
    end
  end

  defp load_for_attempt(repo, context, resource, version, job_id, generation) do
    query =
      from d in StoredDocument,
        join: v in ResourceVersion,
        on: v.id == d.resource_version_id and v.resource_id == d.resource_id,
        join: r in Resource,
        on: r.id == d.resource_id and r.vault_id == d.vault_id,
        where:
          d.resource_version_id == ^version and d.resource_id == ^resource and
            d.vault_id == ^context.owner_scope_id,
        where: d.classification == :private and r.kind == :document,
        select: {d, v.revision}

    case repo.one(query, log: false) do
      nil ->
        error(:not_found)

      {row, revision}
      when row.attempt_job_id == job_id and row.attempt_generation == generation and
             row.state in [:extracting, :ready, :failed, :unsupported] ->
        hydrate(repo, row, revision)

      _ ->
        error(:conflict)
    end
  end

  defp hydrate(repo, row, revision) do
    with {:ok, source} <-
           DocumentSource.new(%{
             asset_id: row.source_asset_id,
             resource_id: row.source_resource_id,
             resource_version_id: row.source_resource_version_id,
             object_id: row.source_object_id,
             owner_scope_id: row.vault_id,
             classification: row.classification,
             digest: row.source_digest,
             byte_size: row.source_byte_size,
             media_type: row.media_type
           }),
         {:ok, fragments} <- fragments(repo, row) do
      DocumentVersion.new(%{
        resource_id: row.resource_id,
        resource_version_id: row.resource_version_id,
        owner_scope_id: row.vault_id,
        classification: row.classification,
        revision: revision,
        source: source,
        title: row.title,
        created_by_principal_id: row.created_by_principal_id,
        inserted_at: row.inserted_at,
        state: row.state,
        generation: row.attempt_generation,
        attempt_job_id: row.attempt_job_id,
        attempt_started_at: row.attempt_started_at,
        attempt_deadline_at: row.attempt_deadline_at,
        adapter_name: row.extraction_adapter,
        format_version: row.extraction_format,
        extracted_text_digest: row.extracted_text_digest,
        detected_language: row.detected_language,
        failure_code: row.failure_code,
        finished_at: row.attempt_finished_at,
        fragments: fragments
      })
    end
  end

  defp fragments(repo, %{state: :ready} = row) do
    repo.all(
      from(f in StoredFragment,
        where: f.resource_version_id == ^row.resource_version_id and f.vault_id == ^row.vault_id,
        order_by: f.ordinal
      ),
      log: false
    )
    |> Enum.reduce_while({:ok, []}, fn fragment, {:ok, acc} ->
      case DocumentFragment.new(%{
             fragment_id: fragment.id,
             resource_id: fragment.resource_id,
             resource_version_id: fragment.resource_version_id,
             owner_scope_id: fragment.vault_id,
             classification: fragment.classification,
             ordinal: fragment.ordinal,
             text: fragment.text,
             digest: fragment.digest,
             locator: fragment.locator
           }) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp fragments(_, _), do: {:ok, nil}

  defp context_repo(%{repo: repo, principal_id: principal, owner_scope_id: owner})
       when is_atom(repo) do
    with :ok <- UUID.validate([principal, owner]), false <- repo.in_transaction?() do
      {:ok, repo}
    else
      true -> error(:invalid)
      {:error, %Error{}} = result -> result
    end
  end

  defp context_repo(_), do: error(:invalid)
  defp auth_context(context), do: Map.take(context, [:principal_id, :owner_scope_id])
  defp secret(%{fingerprint_secret: <<_::256>> = secret}), do: {:ok, secret}
  defp secret(_), do: error(:storage_unavailable)
  defp generation(value) when is_integer(value) and value in 0..9_223_372_036_854_775_807, do: :ok
  defp generation(_), do: error(:invalid)

  defp canonical_job(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, value),
      do: :ok,
      else: error(:invalid)
  end

  defp canonical_job(_), do: error(:invalid)

  defp valid_adapter?(value),
    do:
      is_binary(value) and String.valid?(value) and String.trim(value) != "" and
        byte_size(value) <= 255 and not String.contains?(value, <<0>>)

  defp scoped(repo, context, callback),
    do:
      ScopedRepo.transact(
        repo,
        %{principal_id: context.principal_id, vault_id: context.owner_scope_id},
        callback
      )

  defp error(code), do: {:error, Error.new(code)}
end
