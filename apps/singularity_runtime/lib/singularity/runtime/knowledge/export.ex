defmodule Singularity.Runtime.Knowledge.Export do
  @moduledoc "Portable-export input and public-result boundaries."

  alias Singularity.Core.{Error, KnowledgeExport}
  alias Singularity.Runtime.{OperationScope, SessionContext}
  alias Singularity.Runtime.Knowledge.{ExportArtifact, ExportRead, ExportSnapshot}
  alias Singularity.Runtime.Knowledge.ExportArtifact.Handle
  alias Singularity.Storage.KnowledgeExport.{Repository, Spool, Writer}

  @handle_keys [:__struct__, :binding, :deadline, :operation_ref, :owner]
  @cursor_keys [:after, :operation_id, :proof]
  @descriptor_keys ["byte_size", "media_type", "path", "sha256"]
  @collections ~w(resources versions fragments tags tag_assignments relationships attachments citations)a

  def run(runtime, session, options) do
    with {:ok, normalized_options} <- KnowledgeExport.options(options),
         :ok <- validate_request(runtime, session),
         :ok <- shared(runtime, session, fn _repo -> :ok end) do
      work = fn operation_runtime, operation ->
        materialize(operation_runtime, session, normalized_options, operation)
      end

      ExportArtifact.generate(runtime, session, work)
    else
      {:error, %Error{code: code, retryable?: retryable?}} ->
        {:error, Error.new(code, retryable?: retryable?)}

      _ ->
        storage_unavailable()
    end
  rescue
    _ -> storage_unavailable()
  catch
    _, _ -> storage_unavailable()
  end

  def entries(runtime, session, handle, cursor) do
    safely(fn ->
      with :ok <- validate(:knowledge_export_entries, [handle, cursor]),
           :ok <- validate_request(runtime, session),
           do: ExportArtifact.entries(runtime, session, handle, cursor)
    end)
  end

  def read_chunk(runtime, session, handle, path, ordinal) do
    safely(fn ->
      with :ok <- validate(:read_knowledge_export_chunk, [handle, path, ordinal]),
           :ok <- validate_request(runtime, session),
           do: ExportArtifact.read_chunk(runtime, session, handle, path, ordinal)
    end)
  end

  def close(runtime, session, handle) do
    safely(fn ->
      with :ok <- validate(:close_knowledge_export, [handle]),
           :ok <- validate_request(runtime, session),
           do: ExportArtifact.close(runtime, session, handle)
    end)
  end

  def configuration, do: ExportArtifact.configuration()

  defp materialize(runtime, session, normalized_options, operation) do
    safely(fn ->
      configuration = runtime.knowledge_export

      with {:ok, spool} <-
             Spool.open(%{
               root: operation.path,
               storage_root: configuration.storage_root,
               backup_root: configuration.backup_root,
               clock: configuration.clock
             }) do
        result =
          safely(fn ->
            with {:ok, capture} <-
                   ExportSnapshot.capture(runtime, session, normalized_options, spool),
                 :ok <- outside_transaction(runtime),
                 {:ok, writer} <-
                   Writer.open(%{
                     root: operation.path,
                     storage_root: configuration.storage_root,
                     backup_root: configuration.backup_root,
                     capture: capture,
                     options: normalized_options,
                     write: Map.get(runtime, :knowledge_export_write, &IO.binwrite/2),
                     original_fold: fn selector, acc, emit ->
                       original_fold(runtime, session, capture, selector, acc, emit)
                     end
                   }),
                 :ok <- ExportArtifact.writer_opened(operation, writer),
                 {:ok, writer} <- append_records(capture, writer),
                 {:ok, writer} <- append_originals(capture, writer),
                 {:ok, writer} <- append_fragments(runtime, session, capture, writer),
                 {:ok, writer} <- append_notes(runtime, session, capture, writer),
                 {:ok, artifact} <- Writer.finish(writer),
                 :ok <- revalidate_sources(runtime, session, capture) do
              shared(runtime, session, fn _repo ->
                {:after_commit, fn -> ExportArtifact.accept_completed(operation, artifact) end}
              end)
            end
          end)

        # The protected work has returned from COMMIT, including exception paths.
        # The original descriptor also owns a capture sealed before failed COMMIT.
        # A successful artifact cannot retain its capture after cleanup failure.
        case {result, Spool.abort(spool)} do
          {{:ok, _artifact} = success, :ok} -> success
          {{:ok, _artifact}, _cleanup_error} -> storage_unavailable()
          {error, _cleanup_result} -> error
        end
      end
    end)
  end

  defp append_records(capture, writer) do
    Enum.reduce_while(@collections, {:ok, writer}, fn collection, {:ok, current} ->
      result =
        Spool.reduce_metadata(capture, collection, current, fn record, acc ->
          Writer.append_manifest_record(acc, collection, record)
        end)

      continue(result)
    end)
  end

  defp append_originals(capture, writer) do
    Spool.reduce_metadata(capture, :versions, writer, fn version, current ->
      case {version["availability"], version["kind"]} do
        {"included", "asset"} ->
          Writer.append_file(current, original_selector(:asset, version), :authenticated)

        {"included", "document"} ->
          Writer.append_file(current, original_selector(:document, version), :authenticated)

        _ ->
          {:ok, current}
      end
    end)
  end

  defp original_fold(runtime, session, capture, {:original, kind, resource, version}, acc, emit)
       when kind in [:asset, :document] do
    safely(fn ->
      with {:ok, record} <- Spool.read_metadata(capture, :versions, {resource, version}),
           {:ok, source} <- original_source(runtime, session, capture, record),
           {:ok, descriptor} <- original_descriptor(runtime, session, record, source),
           true <- descriptor.byte_size == record["original_byte_size"] do
        descriptor.reduce.(acc, emit)
      else
        {:error, _} = error -> error
        _ -> integrity_failure()
      end
    end)
  end

  defp original_selector(kind, version),
    do: {:original, kind, version["resource_id"], version["version_id"]}

  defp original_source(runtime, session, capture, version) do
    result =
      case version["kind"] do
        "asset" ->
          {:ok, {:binary_binding, :asset, version["resource_id"], version["version_id"]}}

        "document" ->
          scoped(runtime, session, "asset.read", fn repo ->
            call(repository(runtime), :document_source_selector, [repo, version])
          end)
      end

    with {:ok, selector} <- result,
         {:ok, reference} <- Map.fetch(capture.binary_refs, selector),
         true <- is_integer(reference.byte_size) and reference.byte_size in 0..65_536,
         {:ok, bytes} <- Spool.read_chunk(capture, reference, 0),
         true <- byte_size(bytes) == reference.byte_size and sha(bytes) == reference.sha256,
         {:ok, binding} <- JSON.decode(bytes),
         true <- is_map(binding) and not is_struct(binding),
         true <-
           selector == {:binary_binding, :asset, binding["resource_id"], binding["version_id"]},
         true <- binding["plaintext_byte_size"] == version["original_byte_size"] do
      {:ok, binding}
    else
      {:error, %Error{}} = error -> error
      _ -> integrity_failure()
    end
  end

  defp original_descriptor(runtime, session, %{"kind" => "asset"}, source),
    do: ExportRead.asset_for_export(runtime, session, source)

  defp original_descriptor(runtime, session, %{"kind" => "document"} = version, source),
    do: ExportRead.document_for_export(runtime, session, %{version: version, source: source})

  defp append_fragments(runtime, session, capture, writer) do
    Spool.reduce_metadata(capture, :fragments, writer, fn fragment, current ->
      selector =
        {:fragment_text, fragment["resource_id"], fragment["version_id"], fragment["ordinal"],
         fragment["id"]}

      with {:ok, reference} <- Map.fetch(capture.text_refs, selector),
           {:ok, descriptor} <-
             ExportRead.fragment(runtime, session, %{
               capture: capture,
               text_ref: reference,
               fragment: fragment
             }),
           :ok <- text_descriptor(descriptor, reference, fragment["digest"]),
           do: Writer.append_file(current, selector, reference)
    end)
  end

  defp append_notes(runtime, session, capture, writer) do
    Spool.reduce_metadata(capture, :versions, writer, fn version, current ->
      if version["kind"] == "note" and version["availability"] == "included" do
        selector = {:note_markdown, version["resource_id"], version["version_id"]}

        with {:ok, reference} <- Map.fetch(capture.text_refs, selector),
             {:ok, descriptor} <-
               ExportRead.note(runtime, session, %{
                 capture: capture,
                 text_ref: reference,
                 version: version
               }),
             :ok <- text_descriptor(descriptor, reference, version["body_digest"]),
             do: Writer.append_file(current, selector, reference)
      else
        {:ok, current}
      end
    end)
  end

  defp text_descriptor(descriptor, reference, digest) do
    if descriptor.byte_size == reference.byte_size and descriptor.sha256 == reference.sha256 and
         descriptor.sha256 == digest,
       do: :ok,
       else: integrity_failure()
  end

  defp revalidate_sources(runtime, session, capture) do
    with {:ok, :ok} <-
           Spool.reduce_metadata(capture, :versions, :ok, fn version, :ok ->
             result = revalidate_version(runtime, session, capture, version)
             if result == :ok, do: {:ok, :ok}, else: result
           end),
         {:ok, :ok} <-
           Spool.reduce_metadata(capture, :fragments, :ok, fn fragment, :ok ->
             case scoped(runtime, session, "asset.read", fn repo ->
                    call(repository(runtime), :revalidate_fragment, [repo, %{fragment: fragment}])
                  end) do
               :ok -> {:ok, :ok}
               error -> error
             end
           end),
         do: :ok
  end

  defp revalidate_version(runtime, session, capture, %{"availability" => "included"} = version) do
    case version["kind"] do
      "note" ->
        scoped(runtime, session, "note.read", fn repo ->
          call(repository(runtime), :revalidate_note, [repo, %{version: version}])
        end)

      kind when kind in ["asset", "document"] ->
        with {:ok, source} <- original_source(runtime, session, capture, version) do
          scoped(runtime, session, "asset.read", fn repo ->
            if kind == "asset" do
              mode = if source["plaintext_byte_size"] == 0, do: :zero, else: 0..0
              call(repository(runtime), :lock_asset_source, [repo, source, mode])
            else
              case call(repository(runtime), :document_source, [
                     repo,
                     %{version: version, source: source}
                   ]) do
                {:ok, _binding} -> :ok
                error -> error
              end
            end
          end)
        end
    end
  end

  defp revalidate_version(_runtime, _session, _capture, _version), do: :ok

  defp shared(runtime, session, callback),
    do: OperationScope.with_shared_request(runtime, session, requirement(session), callback)

  defp scoped(runtime, session, capability, callback) do
    requirement =
      session
      |> requirement()
      |> Map.delete(:required_capabilities)
      |> Map.put(:required_capability, capability)

    OperationScope.with_read_request(runtime, session, requirement, callback)
  end

  defp requirement(session) do
    %{
      vault_id: session.vault_id,
      required_capabilities: ["asset.read", "note.read"],
      classification: :private,
      requires_unlocked?: true,
      principal_authorization_epoch: session.principal_authorization_epoch,
      vault_authorization_epoch: session.vault_authorization_epoch
    }
  end

  defp validate_request(runtime, %SessionContext{} = session) when is_map(runtime) do
    if binding?(
         {session.session_id, session.principal_id, session.vault_id,
          session.principal_authorization_epoch, session.vault_authorization_epoch}
       ),
       do: outside_transaction(runtime),
       else: invalid()
  end

  defp validate_request(_runtime, _session), do: invalid()

  defp outside_transaction(runtime) do
    repo =
      case runtime.request_repo do
        {module, _context} -> module
        module -> module
      end

    if repo.in_transaction?(), do: invalid(), else: :ok
  end

  defp repository(runtime), do: Map.get(runtime, :knowledge_export_repository, Repository)

  defp call(module, function, arguments) when is_atom(module),
    do: apply(module, function, arguments)

  defp call({module, context}, function, arguments),
    do: apply(module, function, [context | arguments])

  defp continue({:ok, _} = result), do: {:cont, result}
  defp continue(error), do: {:halt, error}
  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp safely(callback) do
    case callback.() do
      {:error, %Error{code: code, retryable?: retryable?}} ->
        {:error, Error.new(code, retryable?: retryable?)}

      result ->
        result
    end
  rescue
    _ -> storage_unavailable()
  catch
    _, _ -> storage_unavailable()
  end

  def validate(:export_knowledge, [options]) when is_map(options) and not is_struct(options) do
    case KnowledgeExport.options(options) do
      {:ok, _options} -> :ok
      {:error, %Error{}} -> invalid()
    end
  end

  def validate(:knowledge_export_entries, [handle, cursor]),
    do: valid_input(handle?(handle) and cursor?(cursor))

  def validate(:read_knowledge_export_chunk, [handle, path, ordinal]),
    do:
      valid_input(
        handle?(handle) and relative_path?(path) and is_integer(ordinal) and ordinal >= 0
      )

  def validate(:close_knowledge_export, [handle]), do: valid_input(handle?(handle))
  def validate(_operation, _arguments), do: invalid()

  def public_result({:ok, handle} = result, :export_knowledge),
    do: valid_result(handle?(handle), result)

  def public_result({:ok, page} = result, :knowledge_export_entries),
    do: valid_result(page?(page), result)

  def public_result({:ok, bytes} = result, :read_knowledge_export_chunk),
    do: valid_result(is_binary(bytes) and byte_size(bytes) <= 65_536, result)

  def public_result(:ok, :close_knowledge_export), do: :ok

  def public_result({:error, %Error{code: code, retryable?: retryable?}}, _operation)
      when is_boolean(retryable?) do
    if code in Error.codes(),
      do: {:error, Error.new(code, retryable?: retryable?)},
      else: integrity_failure()
  end

  def public_result({:error, %Error{}}, _operation), do: integrity_failure()

  def public_result({:error, code}, _operation) when is_atom(code) do
    if code in Error.codes(),
      do: {:error, Error.new(code)},
      else: storage_unavailable()
  end

  def public_result({:error, _reason}, _operation), do: storage_unavailable()
  def public_result(_result, _operation), do: integrity_failure()

  # These fields are identity hints and local routing only. Current authority,
  # stored operation reference and cursor membership require the live owner.
  defp handle?(
         %Handle{owner: owner, operation_ref: reference, binding: binding, deadline: deadline} =
           handle
       ) do
    Enum.sort(Map.keys(handle)) == @handle_keys and is_pid(owner) and node(owner) == node() and
      is_reference(reference) and binding?(binding) and is_integer(deadline)
  end

  defp handle?(_handle), do: false

  defp binding?({session, principal, owner, principal_epoch, owner_epoch}) do
    Enum.all?([session, principal, owner], &uuid?/1) and
      is_integer(principal_epoch) and principal_epoch >= 0 and
      is_integer(owner_epoch) and owner_epoch >= 0
  end

  defp binding?(_binding), do: false

  defp cursor?(nil), do: true

  defp cursor?(cursor) when is_map(cursor) and not is_struct(cursor) do
    Enum.sort(Map.keys(cursor)) == @cursor_keys and uuid?(cursor.operation_id) and
      relative_path?(cursor.after) and digest?(cursor.proof)
  end

  defp cursor?(_cursor), do: false

  defp page?(page) when is_map(page) and not is_struct(page) do
    Enum.sort(Map.keys(page)) == [:entries, :next_cursor] and
      descriptors?(page.entries) and cursor?(page.next_cursor)
  end

  defp page?(_page), do: false

  defp descriptors?(entries) when is_list(entries), do: descriptors?(entries, 0)
  defp descriptors?(_entries), do: false

  defp descriptors?([], _count), do: true

  defp descriptors?([entry | rest], count) when count < 500,
    do: descriptor?(entry) and descriptors?(rest, count + 1)

  defp descriptors?(_entries, _count), do: false

  defp descriptor?(entry) when is_map(entry) and not is_struct(entry) do
    Enum.sort(Map.keys(entry)) == @descriptor_keys and relative_path?(entry["path"]) and
      is_binary(entry["media_type"]) and entry["media_type"] != "" and
      is_integer(entry["byte_size"]) and entry["byte_size"] >= 0 and digest?(entry["sha256"])
  end

  defp descriptor?(_entry), do: false

  defp relative_path?(path) when is_binary(path) do
    String.valid?(path) and path != "" and Path.type(path) == :relative and
      not String.contains?(path, ["\\", <<0>>]) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  defp relative_path?(_path), do: false

  defp uuid?(value) when is_binary(value), do: Ecto.UUID.cast(value) == {:ok, value}
  defp uuid?(_value), do: false

  defp digest?(value) when is_binary(value) and byte_size(value) == 64,
    do: value |> :binary.bin_to_list() |> Enum.all?(&(&1 in ?0..?9 or &1 in ?a..?f))

  defp digest?(_value), do: false

  defp valid_input(true), do: :ok
  defp valid_input(false), do: invalid()
  defp valid_result(true, result), do: result
  defp valid_result(false, _result), do: integrity_failure()
  defp invalid, do: {:error, Error.new(:invalid)}
  defp integrity_failure, do: {:error, Error.new(:integrity_failure)}
  defp storage_unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
