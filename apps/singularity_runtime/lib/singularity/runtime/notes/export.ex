defmodule Singularity.Runtime.Notes.Export do
  @moduledoc "Exports canonical Markdown and pinned source inventory after current authorization."

  alias Singularity.Core.{
    Error,
    NoteAttachmentReference,
    NoteCitationReference,
    NoteMarkdownSources
  }

  alias Singularity.Runtime.Audit
  alias Singularity.Runtime.Authorize
  alias Singularity.Runtime.DTO.Note
  alias Singularity.Runtime.DTO.NoteAttachment
  alias Singularity.Runtime.DTO.NoteCitation
  alias Singularity.Runtime.DTO.NoteExport
  alias Singularity.Runtime.Notes.DTO, as: NotesDTO
  alias Singularity.Runtime.Notes.SourceCollections
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.SessionContext
  alias Singularity.Storage.Postgres.AuditSink
  alias Singularity.Storage.Postgres.NoteRepository
  alias Singularity.Storage.Postgres.KnowledgeLinkRepository

  @media_type "text/markdown; charset=utf-8"
  @max_rendered_bytes 16_777_216
  @unsafe_filename ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}\/\\]+/u

  @spec run(map(), SessionContext.t(), String.t()) ::
          {:ok, NoteExport.t()} | {:error, Error.t()}
  def run(runtime, %SessionContext{} = session, resource_id) when is_map(runtime) do
    with true <- valid_uuid?(resource_id),
         {:ok, adapters} <- adapters(runtime) do
      adapters.operation_scope
      |> call_adapter(:with_shared_request, [
        runtime,
        session,
        requirement(session),
        fn repo -> export(adapters, repo, session, resource_id) end
      ])
      |> export_result()
    else
      false -> invalid()
      result -> normalize_error(result)
    end
  rescue
    _error -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  def run(_runtime, _session, _resource_id), do: invalid()

  defp export(adapters, repo, session, resource_id) do
    with {:ok, source} <-
           call_adapter(adapters.note_repository, :get, [repo, session.vault_id, resource_id]),
         :ok <- source_scope(source, session.vault_id, resource_id),
         {:ok, source} <-
           SourceCollections.compose(adapters.knowledge_link_repository, repo, session, source),
         {:ok, note} <- NotesDTO.note(source),
         {:ok, attrs} <- export_attrs(note, resource_id),
         {:ok, references} <- canonical_sources(note),
         :ok <- authorize_sources(adapters, repo, session, references),
         {:ok, descriptors} <- resolve_sources(adapters, repo, session, note, references),
         {:ok, markdown} <- render(note.markdown, descriptors),
         {:ok, export} <- NoteExport.new(%{attrs | markdown: markdown}),
         :ok <- append_audit(adapters.audit, repo, session, export) |> normalize_ok() do
      {:ok, export}
    else
      result -> normalize_error(result)
    end
  end

  defp canonical_sources(note) do
    members =
      Enum.map(note.attachments, &{:attachment, &1}) ++
        Enum.map(note.citations, &{:citation, &1})

    members
    |> Enum.reduce_while({:ok, []}, fn {operation, input}, {:ok, acc} ->
      case canonical_reference(input) do
        {:ok, reference} -> {:cont, {:ok, [{operation, reference} | acc]}}
        failure -> {:halt, failure}
      end
    end)
    |> case do
      {:ok, references} ->
        if references
           |> Enum.map(fn {_, reference} -> target_identity(reference) end)
           |> MapSet.new()
           |> MapSet.size() <= 100,
           do: {:ok, Enum.reverse(references)},
           else: integrity_failure()

      failure ->
        failure
    end
  end

  defp canonical_reference(%NoteAttachment{} = input),
    do: reconstruct_reference(NoteAttachmentReference, input)

  defp canonical_reference(%NoteCitation{} = input),
    do: reconstruct_reference(NoteCitationReference, input)

  defp canonical_reference(_input), do: integrity_failure()

  defp reconstruct_reference(module, input) do
    attrs = Map.from_struct(input)

    with {:ok, reference} <- module.new(attrs),
         true <- Map.from_struct(reference) === attrs do
      {:ok, reference}
    else
      _invalid -> integrity_failure()
    end
  end

  defp target_identity(%NoteAttachmentReference{} = reference),
    do: {reference.target_resource_id, reference.target_resource_version_id}

  defp target_identity(%NoteCitationReference{} = reference),
    do: {reference.source_resource_id, reference.source_resource_version_id}

  defp authorize_sources(adapters, repo, session, references) do
    references
    |> Enum.map(fn {_, reference} -> source_capability(reference) end)
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn capability, :ok ->
      required = %{
        vault_id: session.vault_id,
        classification: :private,
        requires_unlocked?: true,
        required_capability: capability,
        principal_authorization_epoch:
          session.principal_authorization_epoch || session.authorization_epoch,
        vault_authorization_epoch: session.vault_authorization_epoch
      }

      case call_adapter(adapters.authorizer, :check, [
             adapters.authorization,
             repo,
             session,
             required
           ])
           |> normalize_ok() do
        :ok -> {:cont, :ok}
        failure -> {:halt, failure}
      end
    end)
  end

  defp source_capability(%NoteAttachmentReference{target_kind: :note}), do: "note.read"
  defp source_capability(_asset_or_document), do: "asset.read"

  defp resolve_sources(_adapters, _repo, _session, _note, []),
    do: {:ok, %{attachments: [], citations: []}}

  defp resolve_sources(adapters, repo, session, note, [{operation, reference} | _] = references) do
    context = %{repo: repo, principal_id: session.principal_id, owner_scope_id: session.vault_id}
    {selector, _resolver} = functions(operation)

    # The existing selector establishes the containing Resource share lock.
    # It runs only after every referenced-source capability has passed.
    with {:ok, selected} <-
           call_adapter(adapters.knowledge_link_repository, selector, [
             context,
             note.resource_id,
             note.resource_version_id,
             member_id(reference)
           ])
           |> normalize_reply(),
         true <- selected === reference do
      hydrate_sources(adapters, context, session, references)
    else
      false -> integrity_failure()
      result -> normalize_error(result)
    end
  end

  defp hydrate_sources(adapters, context, session, references) do
    references
    |> Enum.reduce_while({:ok, %{attachments: [], citations: []}, 0}, fn {operation, reference},
                                                                         {:ok, descriptors,
                                                                          title_bytes} ->
      {_selector, resolver} = functions(operation)

      with {:ok, resolved} <-
             call_adapter(adapters.knowledge_link_repository, resolver, [context, reference])
             |> normalize_reply(),
           {:ok, title_bytes} <- title_budget(resolved, title_bytes),
           {:ok, resolved} <-
             NotesDTO.source_resolution(
               operation,
               resolved,
               member_id(reference),
               session.vault_id
             ),
           {:ok, canonical} <- canonical_reference(resolved.reference),
           true <- canonical === reference do
        field = if operation == :attachment, do: :attachments, else: :citations

        descriptor = %{
          reference: reference,
          source: resolved.source,
          href: source_href(resolved.source)
        }

        {:cont, {:ok, Map.update!(descriptors, field, &[descriptor | &1]), title_bytes}}
      else
        false -> {:halt, integrity_failure()}
        result -> {:halt, normalize_error(result)}
      end
    end)
    |> case do
      {:ok, descriptors, _title_bytes} ->
        {:ok, Map.new(descriptors, fn {field, values} -> {field, Enum.reverse(values)} end)}

      failure ->
        failure
    end
  end

  defp title_budget(%{source: %{title: title}}, used) when is_binary(title) do
    total = used + byte_size(title)
    if total <= @max_rendered_bytes, do: {:ok, total}, else: integrity_failure()
  end

  defp title_budget(_resolved, _used), do: integrity_failure()

  defp source_href(source) do
    extension = %{asset: "bin", note: "md", document: "txt"}[source.kind]
    "sources/#{source.kind}-#{source.resource_id}-#{source.resource_version_id}.#{extension}"
  end

  defp functions(:attachment), do: {:select_attachment_in_scope, :resolve_attachment_in_scope}
  defp functions(:citation), do: {:select_citation_in_scope, :resolve_citation_in_scope}
  defp member_id(%NoteAttachmentReference{attachment_id: id}), do: id
  defp member_id(%NoteCitationReference{citation_id: id}), do: id

  defp render(markdown, descriptors) do
    case NoteMarkdownSources.render(markdown, descriptors) do
      {:ok, rendered} when is_binary(rendered) -> {:ok, rendered}
      _invalid -> integrity_failure()
    end
  end

  defp export_result({:ok, %NoteExport{} = export}),
    do: NoteExport.new(Map.from_struct(export))

  defp export_result(result), do: normalize_error(result)

  defp normalize_reply({:ok, _value} = result), do: result
  defp normalize_reply(result), do: normalize_error(result)
  defp normalize_ok(:ok), do: :ok
  defp normalize_ok(result), do: normalize_error(result)

  defp normalize_error({:error, %Error{code: code, retryable?: retryable?}})
       when is_boolean(retryable?) do
    if code in Error.codes(),
      do: {:error, Error.new(code, retryable?: retryable?)},
      else: integrity_failure()
  end

  defp normalize_error(_invalid), do: integrity_failure()

  defp export_attrs(
         %Note{
           resource_id: resource_id,
           resource_version_id: version_id,
           title: title,
           markdown: markdown,
           deleted?: false
         },
         resource_id
       )
       when is_binary(title) and is_binary(markdown) do
    if valid_uuid?(version_id) do
      {:ok,
       %{
         resource_id: resource_id,
         resource_version_id: version_id,
         filename: filename(title),
         media_type: @media_type,
         markdown: markdown
       }}
    else
      integrity_failure()
    end
  end

  defp export_attrs(_note, _resource_id), do: integrity_failure()

  defp source_scope(
         %{resource_id: resource_id, vault_id: vault_id, classification: :private},
         vault_id,
         resource_id
       ),
       do: :ok

  defp source_scope(_source, _vault_id, _resource_id), do: integrity_failure()

  defp append_audit(audit, repo, session, attrs) do
    Audit.append_principal(audit, repo, session, %{
      action: "note.export",
      result: :completed,
      classification: :private,
      correlation_id: Ecto.UUID.generate(),
      target_type: "note",
      target_id: attrs.resource_id,
      metadata: %{"resource_version_id" => attrs.resource_version_id}
    })
  end

  defp filename(title) do
    title = String.trim(title)
    safe = String.replace(title, @unsafe_filename, "_")
    safe_content = String.replace(title, @unsafe_filename, "")

    if String.trim(safe_content) == "", do: "note.md", else: safe <> ".md"
  end

  defp requirement(session) do
    %{
      vault_id: session.vault_id,
      required_capabilities: ["note.export", "note.read"],
      classification: :private,
      requires_unlocked?: true
    }
  end

  defp adapters(runtime) do
    values = %{
      audit: Map.get(runtime, :audit, AuditSink),
      note_repository: Map.get(runtime, :note_repository, NoteRepository),
      knowledge_link_repository:
        Map.get(runtime, :knowledge_link_repository, KnowledgeLinkRepository),
      operation_scope: Map.get(runtime, :operation_scope, OperationScope),
      authorizer: Map.get(runtime, :authorizer, Authorize),
      authorization: Map.get(runtime, :authorization)
    }

    if values |> Map.delete(:authorization) |> Map.values() |> Enum.all?(&concrete?/1),
      do: {:ok, values},
      else: invalid()
  end

  defp valid_uuid?(value), do: Ecto.UUID.cast(value) == {:ok, value}

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, arguments)

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, [context | arguments])

  defp concrete?(value), do: value not in [nil, false]
  defp invalid, do: {:error, Error.new(:invalid)}
  defp integrity_failure, do: {:error, Error.new(:integrity_failure)}
  defp storage_unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
