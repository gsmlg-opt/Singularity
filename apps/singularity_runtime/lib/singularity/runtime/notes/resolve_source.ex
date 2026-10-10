defmodule Singularity.Runtime.Notes.ResolveSource do
  @moduledoc "Resolves one pinned Note source after current containing and target authorization."

  alias Singularity.Core.{Error, NoteAttachmentReference, NoteCitationReference}
  alias Singularity.Runtime.Authorize
  alias Singularity.Runtime.Notes.DTO, as: NotesDTO
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.SessionContext
  alias Singularity.Storage.Postgres.KnowledgeLinkRepository

  @spec attachment(map(), SessionContext.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def attachment(runtime, session, note_id, version_id, attachment_id),
    do: run(:attachment, runtime, session, note_id, version_id, attachment_id)

  @spec citation(map(), SessionContext.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def citation(runtime, session, note_id, version_id, citation_id),
    do: run(:citation, runtime, session, note_id, version_id, citation_id)

  defp run(operation, runtime, %SessionContext{} = session, note_id, version_id, member_id)
       when is_map(runtime) do
    with true <-
           Enum.all?(
             [note_id, version_id, member_id, session.principal_id, session.vault_id],
             &canonical_uuid?/1
           ),
         {:ok, adapters} <- adapters(runtime),
         {:ok, resolved} <-
           call_adapter(adapters.operation_scope, :with_read_request, [
             runtime,
             session,
             requirement(session, "note.read"),
             fn repo ->
               resolve(operation, adapters, repo, session, note_id, version_id, member_id)
             end
           ])
           |> normalize_reply(),
         {:ok, result} <-
           NotesDTO.source_resolution(operation, resolved, member_id, session.vault_id) do
      {:ok, result}
    else
      false -> invalid()
      {:error, %Error{}} = failure -> failure
      _invalid -> integrity_failure()
    end
  rescue
    _exception -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  defp run(_operation, _runtime, _session, _note_id, _version_id, _member_id), do: invalid()

  defp resolve(operation, adapters, repo, session, note_id, version_id, member_id) do
    context = %{repo: repo, principal_id: session.principal_id, owner_scope_id: session.vault_id}
    {selector, resolver} = functions(operation)

    with {:ok, reference} <-
           call_adapter(adapters.knowledge_link_repository, selector, [
             context,
             note_id,
             version_id,
             member_id
           ])
           |> normalize_reply(),
         :ok <- selected_reference(operation, reference, member_id),
         :ok <- authorize_target(adapters, repo, session, reference),
         {:ok, resolved} <-
           call_adapter(adapters.knowledge_link_repository, resolver, [context, reference])
           |> normalize_reply(),
         true <- is_map(resolved) and resolved[:reference] === reference do
      {:ok, resolved}
    else
      {:error, %Error{}} = failure -> failure
      _invalid -> integrity_failure()
    end
  end

  defp selected_reference(:attachment, %NoteAttachmentReference{} = reference, member_id) do
    with {:ok, ^reference} <- NoteAttachmentReference.new(reference),
         true <- reference.attachment_id === member_id do
      :ok
    else
      _invalid -> integrity_failure()
    end
  end

  defp selected_reference(:citation, %NoteCitationReference{} = reference, member_id) do
    with {:ok, ^reference} <- NoteCitationReference.new(reference),
         true <- reference.citation_id === member_id do
      :ok
    else
      _invalid -> integrity_failure()
    end
  end

  defp selected_reference(_operation, _reference, _member_id), do: integrity_failure()

  defp authorize_target(adapters, repo, session, reference) do
    capability =
      case reference do
        %NoteAttachmentReference{target_kind: :note} -> "note.read"
        _asset_or_document -> "asset.read"
      end

    required =
      session
      |> requirement(capability)
      |> Map.put(
        :principal_authorization_epoch,
        session.principal_authorization_epoch || session.authorization_epoch
      )
      |> Map.put(:vault_authorization_epoch, session.vault_authorization_epoch)

    case call_adapter(adapters.authorizer, :check, [
           adapters.authorization,
           repo,
           session,
           required
         ]) do
      :ok -> :ok
      result -> normalize_error(result)
    end
  end

  defp requirement(session, capability) do
    %{
      vault_id: session.vault_id,
      classification: :private,
      requires_unlocked?: true,
      required_capability: capability
    }
  end

  defp functions(:attachment),
    do: {:select_attachment_in_scope, :resolve_attachment_in_scope}

  defp functions(:citation), do: {:select_citation_in_scope, :resolve_citation_in_scope}

  defp adapters(runtime) do
    values = %{
      knowledge_link_repository:
        Map.get(runtime, :knowledge_link_repository, KnowledgeLinkRepository),
      operation_scope: Map.get(runtime, :operation_scope, OperationScope),
      authorizer: Map.get(runtime, :authorizer, Authorize),
      authorization: Map.get(runtime, :authorization)
    }

    if Enum.all?(
         Map.take(values, [:knowledge_link_repository, :operation_scope, :authorizer])
         |> Map.values(),
         &(&1 not in [nil, false])
       ),
       do: {:ok, values},
       else: invalid()
  end

  defp normalize_reply({:ok, _value} = result), do: result
  defp normalize_reply(result), do: normalize_error(result)

  defp normalize_error({:error, %Error{code: code, retryable?: retryable?}})
       when is_boolean(retryable?) do
    if code in Error.codes(),
      do: {:error, Error.new(code, retryable?: retryable?)},
      else: integrity_failure()
  end

  defp normalize_error(_invalid), do: integrity_failure()

  defp canonical_uuid?(value), do: Ecto.UUID.cast(value) == {:ok, value}

  defp call_adapter(module, function, arguments) when is_atom(module) and not is_nil(module),
    do: apply(module, function, arguments)

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, [context | arguments])

  defp invalid, do: {:error, Error.new(:invalid)}
  defp integrity_failure, do: {:error, Error.new(:integrity_failure)}
  defp storage_unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
