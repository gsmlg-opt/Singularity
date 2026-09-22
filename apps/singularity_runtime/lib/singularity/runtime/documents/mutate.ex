defmodule Singularity.Runtime.Documents.Mutate do
  @moduledoc "Authenticated, idempotent Document lifecycle mutations."

  alias Singularity.Core.Error
  alias Singularity.Runtime.{OperationScope, SessionContext}
  alias Singularity.Storage.Postgres.DocumentRepository

  def retry(runtime, %SessionContext{} = session, resource_id),
    do: mutate(runtime, session, resource_id, :retry)

  def delete(runtime, %SessionContext{} = session, resource_id),
    do: mutate(runtime, session, resource_id, :delete)

  def restore(runtime, %SessionContext{} = session, resource_id),
    do: mutate(runtime, session, resource_id, :restore)

  defp mutate(runtime, session, resource_id, action) do
    operation_scope = Map.get(runtime, :operation_scope, OperationScope)
    repository = Map.get(runtime, :document_repository, DocumentRepository)

    call(operation_scope, :with_shared_request, [
      runtime,
      session,
      %{
        vault_id: session.vault_id,
        required_capability: "asset.read",
        classification: :private,
        requires_unlocked?: false
      },
      fn repo ->
        call(repository, mutation(action), [
          repo,
          %{principal_id: session.principal_id, owner_scope_id: session.vault_id},
          resource_id,
          current_adapter(runtime)
        ])
      end
    ])
  rescue
    _ -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  defp mutation(:retry), do: :retry_live_scoped
  defp mutation(:delete), do: :delete_live_scoped
  defp mutation(:restore), do: :restore_live_scoped

  defp current_adapter(runtime) do
    Map.get(runtime, :document_extractor_versions, %{
      "text/plain" => %{adapter_name: "plain_text", format_version: 1},
      "text/markdown" => %{adapter_name: "markdown", format_version: 1},
      "application/pdf" => %{adapter_name: "poppler_text", format_version: 1}
    })
  end

  defp call(module, function, args) when is_atom(module), do: apply(module, function, args)
  defp call({module, context}, function, args), do: apply(module, function, [context | args])
end
