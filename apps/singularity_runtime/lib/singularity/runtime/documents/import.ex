defmodule Singularity.Runtime.Documents.Import do
  @moduledoc "Authenticated public import of an existing private Asset."

  alias Singularity.Core.{DocumentVersion, Error, KnowledgeValidation, Types}
  alias Singularity.Domains.Documents
  alias Singularity.Domains.Documents.Command
  alias Singularity.Runtime.Assets.Download
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.SessionContext
  alias Singularity.Storage.Documents.PrepareSource
  alias Singularity.Storage.Postgres.DocumentRepository
  alias Singularity.Storage.RequestRepo

  @fields [:asset_id, :title, :mutation_id]

  @spec run(map(), SessionContext.t(), map()) ::
          {:ok, DocumentVersion.t()} | {:error, Error.t()}
  def run(runtime, %SessionContext{} = session, attrs) when is_map(runtime) do
    with {:ok, %{asset_id: asset_id, title: title, mutation_id: mutation_id}} <- attrs(attrs),
         true <- session.unlocked? do
      scope = Map.get(runtime, :operation_scope, OperationScope)
      repository = Map.get(runtime, :document_repository, DocumentRepository)

      call(scope, :with_shared_request, [
        runtime,
        session,
        %{
          vault_id: session.vault_id,
          required_capability: "asset.read",
          classification: :private,
          requires_unlocked?: true
        },
        fn repo ->
          case call(repository, :find_import_receipt_scoped, [repo, session, mutation_id]) do
            {:ok, document} ->
              compare_replay(document, session, asset_id, title)

            {:error, %Error{code: :not_found}} ->
              {:after_commit,
               fn -> create_from_live_source(runtime, session, asset_id, title, mutation_id) end}

            {:error, %Error{}} = error ->
              error
          end
        end
      ])
    else
      false -> {:error, Error.new(:vault_locked)}
      {:error, %Error{}} = error -> error
    end
  rescue
    _ -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def run(_, _, _), do: {:error, Error.new(:invalid)}

  defp attrs(input) when is_map(input) and not is_struct(input) do
    keys = Map.keys(input)

    if length(keys) == 3 and
         Enum.all?(@fields, fn field ->
           Map.has_key?(input, field) != Map.has_key?(input, Atom.to_string(field))
         end) do
      attrs =
        Map.new(@fields, fn field ->
          {field, Map.get(input, field, Map.get(input, Atom.to_string(field)))}
        end)

      with {:ok, _} <- Types.canonical_uuid(attrs, :asset_id),
           {:ok, _} <- Types.canonical_uuid(attrs, :mutation_id),
           {:ok, title} <- KnowledgeValidation.bounded_name(attrs.title) do
        {:ok, %{attrs | title: title}}
      end
    else
      {:error, Error.new(:invalid)}
    end
  end

  defp attrs(_), do: {:error, Error.new(:invalid)}

  defp compare_replay(%DocumentVersion{} = document, session, asset_id, title) do
    with {:ok, ^document} <- DocumentVersion.new(document),
         true <- document.owner_scope_id == session.vault_id,
         true <- document.created_by_principal_id == session.principal_id do
      if document.source.asset_id == asset_id and document.title == title,
        do: {:ok, document},
        else: {:error, Error.new(:conflict)}
    else
      _ -> {:error, Error.new(:integrity_failure)}
    end
  end

  defp compare_replay(_, _, _, _), do: {:error, Error.new(:integrity_failure)}

  defp create_from_live_source(runtime, session, asset_id, title, mutation_id) do
    repo = Map.get(runtime, :request_repo, RequestRepo)
    prepare = Map.get(runtime, :prepare_source, PrepareSource)
    repository = Map.get(runtime, :document_repository, DocumentRepository)

    digest_operation = fn _context, binding ->
      with {:ok, plaintext} <- Download.run(runtime, session, asset_id, :all),
           true <- byte_size(plaintext) == binding.byte_size do
        {:ok, %{sha256: :crypto.hash(:sha256, plaintext), byte_size: byte_size(plaintext)}}
      else
        false -> {:error, Error.new(:integrity_failure)}
        {:error, %Error{}} = error -> error
      end
    end

    context = %{
      repo: repo,
      principal_id: session.principal_id,
      owner_scope_id: session.vault_id,
      fingerprint_secret: Map.get(runtime, :fingerprint_secret),
      digest_operation: digest_operation
    }

    with {:ok, prepared} <-
           call(prepare, :prepare, [
             context,
             %{
               context: %{principal_id: session.principal_id, owner_scope_id: session.vault_id},
               asset_id: asset_id
             }
           ]),
         {:ok, command} <-
           Command.new(%{
             mutation_id: mutation_id,
             resource_id: Ecto.UUID.generate(),
             resource_version_id: Ecto.UUID.generate(),
             title: title,
             source: prepared.source,
             principal_id: session.principal_id,
             owner_scope_id: session.vault_id,
             classification: :private,
             correlation_id: Ecto.UUID.generate(),
             inserted_at: DateTime.utc_now(:microsecond)
           }) do
      Documents.create(%{repository: repository, repository_context: context}, command)
    end
  end

  defp call({module, context}, function, args), do: apply(module, function, [context | args])
  defp call(module, function, args), do: apply(module, function, args)
end
