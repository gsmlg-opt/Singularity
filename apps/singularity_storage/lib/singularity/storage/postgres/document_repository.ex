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
                      :ok <- persist(transaction_repo, command) do
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

  @impl true
  def get_version(context, resource, version) do
    with {:ok, repo} <- context_repo(context), :ok <- UUID.validate([resource, version]) do
      scoped(repo, context, &load(&1, context, resource, version))
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  @impl true
  def claim(context, version, generation, adapter, format) do
    with :ok <- generation(generation),
         true <-
           is_binary(adapter) and String.valid?(adapter) and String.trim(adapter) != "" and
             byte_size(adapter) <= 255 and not String.contains?(adapter, <<0>>),
         true <- is_integer(format) and format in 1..2_147_483_647 do
      lifecycle(context, version, "claim_document_extraction", [generation, adapter, format])
    else
      _ -> error(:invalid)
    end
  end

  @impl true
  def reset_failed(context, version, generation) do
    with :ok <- generation(generation),
         do: lifecycle(context, version, "reset_document_extraction", [generation])
  end

  @impl true
  def complete(context, input) do
    with {:ok, repo} <- context_repo(context),
         {:ok, completion} <- DocumentCompletion.new(input),
         true <- completion.owner_scope_id == context.owner_scope_id do
      scoped(repo, context, fn transaction_repo ->
        with {:ok, current} <-
               load(
                 transaction_repo,
                 context,
                 completion.resource_id,
                 completion.resource_version_id
               ),
             true <-
               completion.adapter_name == current.adapter_name and
                 completion.format_version == current.format_version and
                 completion.media_type == current.source.media_type do
          {function, args} = completion_args(completion)
          invoke(transaction_repo, context, completion.resource_version_id, function, args)
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
  defp invoke(repo, context, version, function, args) do
    placeholders =
      case function do
        "claim_document_extraction" -> "$1::uuid,$2::bigint,$3::text,$4::integer"
        "reset_document_extraction" -> "$1::uuid,$2::bigint"
        "fail_document_extraction" -> "$1::uuid,$2::bigint,$3::text,$4::text"
        "complete_document_extraction" -> "$1::uuid,$2::bigint,$3::jsonb,$4::bytea,$5::text"
      end

    %{rows: [[resource]]} =
      SafeSQL.query!(
        repo,
        "SELECT resource_id FROM content.#{function}(#{placeholders})",
        [Ecto.UUID.dump!(version) | args]
      )

    load(repo, context, Ecto.UUID.load!(resource), version)
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

  defp scoped(repo, context, callback),
    do:
      ScopedRepo.transact(
        repo,
        %{principal_id: context.principal_id, vault_id: context.owner_scope_id},
        callback
      )

  defp error(code), do: {:error, Error.new(code)}
end
