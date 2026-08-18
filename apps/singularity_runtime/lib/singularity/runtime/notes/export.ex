defmodule Singularity.Runtime.Notes.Export do
  @moduledoc "Exports exact canonical Markdown after conjunctive authorization and audit."

  alias Singularity.Core.Error
  alias Singularity.Runtime.Audit
  alias Singularity.Runtime.DTO.Note
  alias Singularity.Runtime.DTO.NoteExport
  alias Singularity.Runtime.Notes.DTO, as: NotesDTO
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.SessionContext
  alias Singularity.Storage.Postgres.AuditSink
  alias Singularity.Storage.Postgres.NoteRepository

  @media_type "text/markdown; charset=utf-8"
  @unsafe_filename ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}\/\\]+/u

  @spec run(map(), SessionContext.t(), String.t()) ::
          {:ok, NoteExport.t()} | {:error, Error.t()}
  def run(runtime, %SessionContext{} = session, resource_id) when is_map(runtime) do
    with true <- valid_uuid?(resource_id),
         {:ok, adapters} <- adapters(runtime) do
      call_adapter(adapters.operation_scope, :with_shared_request, [
        runtime,
        session,
        requirement(session),
        fn repo -> export(adapters, repo, session, resource_id) end
      ])
    else
      false -> invalid()
      {:error, %Error{}} = error -> error
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
         {:ok, note} <- NotesDTO.note(source),
         {:ok, attrs} <- export_attrs(note, resource_id),
         :ok <- append_audit(adapters.audit, repo, session, attrs),
         {:ok, export} <- NoteExport.new(attrs) do
      {:ok, export}
    end
  end

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
      operation_scope: Map.get(runtime, :operation_scope, OperationScope)
    }

    if Enum.all?(Map.values(values), &concrete?/1), do: {:ok, values}, else: invalid()
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
