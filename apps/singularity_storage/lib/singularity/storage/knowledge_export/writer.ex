defmodule Singularity.Storage.KnowledgeExport.Writer do
  @moduledoc "Private, bounded portable materialization from a sealed capture. Not request authority."

  alias Singularity.Core.{
    DocumentFragment,
    Error,
    KnowledgeExport,
    KnowledgeExportManifest,
    NoteAttachmentReference,
    NoteCitationReference,
    NoteMarkdownSources,
    SourceLocator
  }

  alias Singularity.Storage.KnowledgeExport.Spool
  import Bitwise, only: [band: 2]

  @collections ~w(resources versions fragments tags tag_assignments relationships attachments citations)a
  @fields %{
    resources: ~w(id kind title current_version_id deleted_at selection_reason),
    versions:
      ~w(resource_id version_id revision kind inserted_at availability body_path original_path extracted_path body_digest original_digest original_byte_size extracted_digest media_type state extraction_adapter extraction_format parent_version_id merge_parent_version_id),
    fragments:
      ~w(id resource_id version_id ordinal digest locator extracted_path start_byte byte_size),
    tags: ~w(id display_value normalized_key),
    tag_assignments: ~w(resource_id tag_id),
    relationships: ~w(id source_resource_id target_resource_id target_version_id type),
    attachments:
      ~w(note_resource_id note_version_id id ordinal target_resource_id target_version_id target_kind role label),
    citations:
      ~w(note_resource_id note_version_id id ordinal source_resource_id source_version_id fragment_id locator),
    files: ~w(path media_type byte_size sha256)
  }
  @context_keys ~w(root storage_root backup_root capture options original_fold write)a
  @directories ["notes", "assets", "documents", "documents/originals", "documents/extracted"]
  @busy -1
  @complete -2
  @aborted -3
  @chunk 65_536

  def open(context) do
    try do
      validate_context!(context)
      {captured, auxiliary, index_bytes, index_records} = capture_index!(context.capture)

      accounting = %{
        spool_bytes: context.capture.accounting.spool_bytes + index_bytes,
        metadata_records: context.capture.accounting.metadata_records + index_records,
        selected_keys: context.capture.accounting.selected_keys,
        file_bytes: 0,
        manifest_bytes: 0
      }

      budget!(accounting)
      ensure(context.capture.accounting.original_bytes < KnowledgeExport.limits().file_bytes)
      root_stat = private_directory!(context.root)
      operation_id = Ecto.UUID.generate()
      staging = Path.join(context.root, operation_id <> ".staging")
      ledger = :ets.new(__MODULE__, [:set, :public])
      phase = :atomics.new(2, signed: true)
      secret = :crypto.strong_rand_bytes(32)
      native!(File.mkdir(staging))
      stat = File.lstat!(staging)

      writer = %{
        operation_id: operation_id,
        deadline: context.capture._deadline,
        accounting: accounting,
        _capture: context.capture,
        _options: context.options,
        _fold: context.original_fold,
        _write: Map.get(context, :write, &IO.binwrite/2),
        _clock: context.capture._clock,
        _secret: secret,
        _phase: phase,
        _generation: 0,
        _ledger: ledger,
        _identity: %{
          root: context.root,
          root_stat: identity(root_stat),
          id: operation_id,
          operation_stat: identity(stat)
        },
        _captured: captured,
        _fragment_counts: auxiliary.fragment_counts,
        _fragment_identities: auxiliary.fragment_identities,
        _source_keys: auxiliary.source_keys,
        _records: Map.new(@collections, &{&1, %{}}),
        _outputs: %{},
        _documents: %{},
        _seen: MapSet.new(),
        _journal_size: 0
      }

      :ets.insert(ledger, {:accounting, accounting})
      :ets.insert(ledger, {:location, :staging})

      :ets.insert(
        ledger,
        {:binding,
         %{
           identity: writer._identity,
           deadline: writer.deadline,
           clock: writer._clock,
           phase: writer._phase
         }}
      )

      initialize(writer)
    rescue
      _ -> error(:storage_unavailable)
    catch
      {:writer_error, code} -> error(code)
      _, _ -> error(:storage_unavailable)
    end
  end

  def append_manifest_record(writer, collection, record) do
    mutate(writer, fn state ->
      ensure(collection in @collections)
      ensure(is_map(record) and not is_struct(record))
      key = record_key(collection, record)
      ensure(not Map.has_key?(state._records[collection], key))
      expected = captured_record!(state, collection, key)
      ensure(expected === record, :integrity_failure)
      # A pending Asset SHA is private until actual original bytes are folded.
      if pending_asset?(record) do
        selector = {:binary_binding, :asset, record["resource_id"], record["version_id"]}
        ref = Map.fetch!(state._capture.binary_refs, selector)
        binding = read_capture_json!(state, ref)

        ensure(
          binding["resource_id"] == record["resource_id"] and
            binding["version_id"] == record["version_id"] and
            binding["plaintext_byte_size"] == record["original_byte_size"],
          :integrity_failure
        )
      else
        core_record!(collection, record)
      end

      payload = JSON.encode!(record)

      frame =
        <<byte_size(payload)::unsigned-big-64, :crypto.hash(:sha256, payload)::binary>> <> payload

      offset = state._journal_size
      state = charge!(state, byte_size(frame), 1)
      append_native!(state, ".records", frame)
      ref = %{offset: offset + 40, byte_size: byte_size(payload), sha256: sha(payload)}

      state = %{
        state
        | _journal_size: offset + byte_size(frame),
          _records: Map.update!(state._records, collection, &Map.put(&1, key, ref))
      }

      index =
        JSON.encode!([
          Atom.to_string(collection),
          json_key(key),
          ref.offset,
          ref.byte_size,
          ref.sha256
        ])

      state = charge!(state, byte_size(index) + 1, 1)
      append_native!(state, ".index", index <> "\n")
      state
    end)
  end

  def append_file(writer, selector, reference) do
    mutate(writer, fn state ->
      ensure(not MapSet.member?(state._seen, selector))

      state =
        case selector do
          {:original, kind, resource, version} when kind in [:asset, :document] ->
            ensure(reference === :authenticated)
            write_original!(state, selector, kind, resource, version)

          {:note_markdown, resource, version} ->
            exact_text_ref!(state, selector, reference)
            write_note!(state, resource, version, reference)

          {:fragment_text, resource, version, ordinal, fragment_id} ->
            exact_text_ref!(state, selector, reference)
            write_fragment!(state, resource, version, ordinal, fragment_id, reference)

          _ ->
            fail(:invalid)
        end

      %{state | _seen: MapSet.put(state._seen, selector)}
    end)
  end

  def finish(writer) do
    mutate(writer, fn state ->
      complete_records!(state)
      verify_closure!(state)
      complete_files!(state)
      verify_outputs!(state)
      state = write_manifest!(state)
      verify_outputs!(state)
      publish!(state)
    end)
  end

  def abort(state) do
    try do
      identity_valid!(state)
      :atomics.put(state._phase, 2, 1)
      phase = :atomics.get(state._phase, 1)

      if phase == @busy do
        # The active fold/finish owns its open FD and closes it before cleanup.
        :ok
      else
        ensure(phase in [@complete, @aborted] or phase >= 0)

        if phase == @aborted or :atomics.compare_exchange(state._phase, 1, phase, @busy) == :ok do
          try do
            cleanup!(state)
            :ok
          after
            # A refused cleanup has no active FD owner. Keep cancellation sealed,
            # but permit a later genuine abort to retry after identity restoration.
            :atomics.compare_exchange(state._phase, 1, @busy, @aborted)
          end
        else
          :ok
        end
      end
    rescue
      _ -> error(:storage_unavailable)
    catch
      {:writer_error, code} -> error(code)
      _, _ -> error(:storage_unavailable)
    end
  end

  def entries(artifact, cursor) do
    deliver(artifact, fn state ->
      after_key = cursor_key!(state, cursor)
      keys = state._outputs |> Map.keys() |> Enum.sort()
      selected = keys |> Enum.filter(&(is_nil(after_key) or &1 > after_key)) |> Enum.take(501)
      page = Enum.take(selected, 500)
      Enum.each(page, &file_valid!(state, &1))
      next = if length(selected) > 500, do: cursor(state, List.last(page)), else: nil
      {:ok, %{entries: Enum.map(page, &descriptor(&1, state._outputs[&1])), next_cursor: next}}
    end)
  end

  def read_chunk(artifact, path, ordinal) do
    deliver(artifact, fn state ->
      ensure(is_binary(path) and is_integer(ordinal) and ordinal >= 0)
      output = Map.get(state._outputs, path)
      ensure(not is_nil(output))
      ensure(ordinal < max(1, div(output.byte_size + @chunk - 1, @chunk)))
      size = min(@chunk, max(0, output.byte_size - ordinal * @chunk))
      bytes = read_native!(state, path, ordinal * @chunk, size)
      ensure(sha(bytes) == Map.fetch!(output.chunks, ordinal), :integrity_failure)
      {:ok, bytes}
    end)
  end

  defp initialize(writer) do
    try do
      native!(File.chmod(directory(writer), 0o700))

      ensure(
        identity(private_directory!(directory(writer))) == writer._identity.operation_stat,
        :integrity_failure
      )

      create_file!(writer, ".records")
      create_file!(writer, ".index")
      {:ok, writer}
    rescue
      _ -> failed(writer, :storage_unavailable)
    catch
      {:writer_error, code} -> failed(writer, code)
      _, _ -> failed(writer, :storage_unavailable)
    end
  end

  defp mutate(state, fun) do
    try do
      identity_valid!(state)
      ensure(is_integer(state._generation) and state._generation >= 0)
      ensure(:atomics.compare_exchange(state._phase, 1, state._generation, @busy) == :ok)

      try do
        alive!(state)
        budget!(state.accounting)
        ensure(:ets.lookup(state._ledger, :accounting) == [{:accounting, state.accounting}])
        filesystem!(state)
        next = fun.(state)
        alive!(next)
        :ets.insert(next._ledger, {:accounting, next.accounting})

        if Map.has_key?(next, :manifest) do
          ensure(:atomics.compare_exchange(next._phase, 1, @busy, @complete) == :ok)
          # Cancellation may race publication, but must be observed before returning.
          alive!(next)
          {:ok, next}
        else
          generation = state._generation + 1
          ensure(:atomics.compare_exchange(next._phase, 1, @busy, generation) == :ok)
          alive!(next)
          {:ok, %{next | _generation: generation}}
        end
      rescue
        _ -> failed(state, :storage_unavailable)
      catch
        {:writer_error, code} -> failed(state, code)
        _, _ -> failed(state, :storage_unavailable)
      end
    rescue
      _ -> error(:invalid)
    catch
      {:writer_error, code} -> error(code)
      _, _ -> error(:invalid)
    end
  end

  defp deliver(state, fun) do
    try do
      identity_valid!(state)
      ensure(:atomics.get(state._phase, 1) == @complete and Map.has_key?(state, :manifest))

      try do
        alive!(state)
        filesystem!(state)
        result = delivery_result(state, fun)
        if match?({:ok, _}, result), do: alive!(state)
        result
      rescue
        _ -> failed(state, :integrity_failure)
      catch
        {:writer_error, code} -> failed(state, code)
        _, _ -> failed(state, :integrity_failure)
      end
    rescue
      _ -> error(:invalid)
    catch
      {:writer_error, code} -> error(code)
      _, _ -> error(:invalid)
    end
  end

  defp delivery_result(state, fun) do
    try do
      fun.(state)
    rescue
      _ -> failed(state, :integrity_failure)
    catch
      {:writer_error, :invalid} -> error(:invalid)
      {:writer_error, code} -> failed(state, code)
      _, _ -> failed(state, :integrity_failure)
    end
  end

  defp failed(state, code) do
    :atomics.put(state._phase, 2, 1)

    try do
      cleanup!(state)
      error(code)
    rescue
      _ -> error(:storage_unavailable)
    catch
      _, _ -> error(:storage_unavailable)
    after
      :atomics.compare_exchange(state._phase, 1, @busy, @aborted)
    end
  end

  defp validate_context!(c) do
    ensure(is_map(c) and not is_struct(c))
    ensure(Enum.all?(Map.keys(c), &(&1 in @context_keys)))
    ensure(Enum.all?(@context_keys -- [:write], &Map.has_key?(c, &1)))
    ensure(is_function(c.original_fold, 3))
    ensure(not Map.has_key?(c, :write) or is_function(c.write, 2))
    ensure(KnowledgeExport.options(c.options) == {:ok, c.options})

    for path <- [c.root, c.storage_root, c.backup_root] do
      safe_absolute!(path)
    end

    ensure(c.root != "/")
    private_directory!(c.root)
    ensure(disjoint?(c.root, c.storage_root) and disjoint?(c.root, c.backup_root))

    ensure(
      identity(File.lstat!(c.root)) not in [
        identity(File.lstat!(c.storage_root)),
        identity(File.lstat!(c.backup_root))
      ]
    )

    ensure(is_map(c.capture) and c.capture[:sealed?] === true)
    ensure(is_function(c.capture._clock, 0) and is_integer(c.capture._deadline))
    ensure(c.capture._clock.() < c.capture._deadline)
  end

  defp capture_index!(capture) do
    auxiliary = %{
      fragment_counts: %{},
      fragment_identities: %{},
      source_keys: %{attachments: %{}, citations: %{}}
    }

    {indexes, auxiliary, bytes, count} =
      Enum.reduce(@collections, {%{}, auxiliary, 0, 0}, fn collection,
                                                           {indexes, auxiliary, bytes, count} ->
        {index, auxiliary, total_bytes, total_records} =
          value!(
            Spool.reduce_metadata(capture, collection, {%{}, auxiliary, bytes, count}, fn record,
                                                                                          {i, a,
                                                                                           b,
                                                                                           n} ->
              key = record_key(collection, record)

              size =
                byte_size(
                  JSON.encode!([capture.capture_id, Atom.to_string(collection), json_key(key)])
                ) + 40

              if Map.has_key?(i, key) do
                error(:integrity_failure)
              else
                with {:ok, {b, n}} <- admit_index(capture, b, n, size, 1),
                     {:ok, {a, b, n}} <- capture_auxiliary(capture, collection, key, {a, b, n}) do
                  {:ok, {Map.put(i, key, true), a, b, n}}
                end
              end
            end)
          )

        {Map.put(indexes, collection, index), auxiliary, total_bytes, total_records}
      end)

    source_keys =
      Map.new(auxiliary.source_keys, fn {collection, groups} ->
        {collection, Map.new(groups, fn {key, keys} -> {key, Enum.reverse(keys)} end)}
      end)

    {indexes, %{auxiliary | source_keys: source_keys}, bytes, count}
  end

  defp capture_auxiliary(capture, :fragments, {resource, version, _, id} = key, {a, b, n}) do
    version_key = {resource, version}
    count = Map.get(a.fragment_counts, version_key, 0) + 1
    identity = {resource, version, id}
    # Keep unused historical ambiguity fileless; citations deny it at closure.
    match = if Map.has_key?(a.fragment_identities, identity), do: :ambiguous, else: key

    with {:ok, {counts, b, n}} <-
           put_auxiliary(capture, "fragment_count", a.fragment_counts, version_key, count, b, n),
         {:ok, {identities, b, n}} <-
           put_auxiliary(
             capture,
             "fragment_identity",
             a.fragment_identities,
             identity,
             match,
             b,
             n
           ) do
      {:ok, {%{a | fragment_counts: counts, fragment_identities: identities}, b, n}}
    end
  end

  defp capture_auxiliary(capture, collection, {resource, version, _, _} = key, {a, b, n})
       when collection in [:attachments, :citations] do
    {header_kind, member_kind} =
      case collection do
        :attachments -> {"attachment_group", "attachment_member"}
        :citations -> {"citation_group", "citation_member"}
      end

    group_key = {resource, version}
    groups = a.source_keys[collection]
    keys = Map.get(groups, group_key, [])

    header =
      if Map.has_key?(groups, group_key),
        do: {:ok, {groups, b, n}},
        else: put_auxiliary(capture, header_kind, groups, group_key, [], b, n)

    with {:ok, {groups, b, n}} <- header,
         size = auxiliary_bytes(capture, member_kind, group_key, key),
         {:ok, {b, n}} <- admit_index(capture, b, n, size, 1) do
      groups = Map.put(groups, group_key, [key | keys])
      {:ok, {%{a | source_keys: Map.put(a.source_keys, collection, groups)}, b, n}}
    end
  end

  defp capture_auxiliary(_capture, _collection, _key, accumulator), do: {:ok, accumulator}

  defp put_auxiliary(capture, kind, entries, key, value, bytes, records) do
    previous = Map.fetch(entries, key)

    if previous == {:ok, value} do
      {:ok, {entries, bytes, records}}
    else
      size = auxiliary_bytes(capture, kind, key, value)

      {size, count} =
        case previous do
          :error -> {size, 1}
          {:ok, old} -> {max(0, size - auxiliary_bytes(capture, kind, key, old)), 0}
        end

      with {:ok, {bytes, records}} <- admit_index(capture, bytes, records, size, count) do
        {:ok, {Map.put(entries, key, value), bytes, records}}
      end
    end
  end

  defp auxiliary_bytes(capture, kind, key, value),
    do: byte_size(JSON.encode!([capture.capture_id, kind, json_key(key), json_key(value)])) + 40

  defp admit_index(capture, bytes, records, size, count) do
    limits = KnowledgeExport.limits()

    if capture.accounting.metadata_records + records + count > limits.metadata_records or
         capture.accounting.spool_bytes + bytes + size > limits.metadata_bytes do
      error(:invalid)
    else
      {:ok, {bytes + size, records + count}}
    end
  end

  defp captured_record!(state, collection, key) do
    ensure(Map.get(state._captured[collection], key) === true)
    record = value!(Spool.read_metadata(state._capture, collection, key))
    ensure(record_key(collection, record) == key, :integrity_failure)
    record
  end

  defp record!(state, collection, key) do
    ref = Map.get(state._records[collection], key)
    ensure(not is_nil(ref), :integrity_failure)
    bytes = read_native!(state, ".records", ref.offset, ref.byte_size)
    ensure(sha(bytes) == ref.sha256, :integrity_failure)
    JSON.decode!(bytes)
  end

  defp core_record!(collection, record),
    do: value!(KnowledgeExportManifest.record(collection, record))

  defp pending_asset?(%{
         "kind" => "asset",
         "availability" => "included",
         "original_digest" => nil
       }),
       do: true

  defp pending_asset?(_), do: false

  defp record_key(collection, r) when collection in [:resources, :tags, :relationships],
    do: r["id"]

  defp record_key(:versions, r), do: {r["resource_id"], r["version_id"]}
  defp record_key(:fragments, r), do: {r["resource_id"], r["version_id"], r["ordinal"], r["id"]}
  defp record_key(:tag_assignments, r), do: {r["resource_id"], r["tag_id"]}

  defp record_key(collection, r) when collection in [:attachments, :citations],
    do: {r["note_resource_id"], r["note_version_id"], r["ordinal"], r["id"]}

  defp write_original!(state, selector, kind, resource, version) do
    record = record!(state, :versions, {resource, version})
    ensure(record["kind"] == Atom.to_string(kind) and record["availability"] == "included")
    path = record["original_path"]
    ensure(not is_nil(path))
    exact_path!(kind, resource, version, record["media_type"], path)
    ensure(not Map.has_key?(state._outputs, path))

    if kind == :asset do
      ref = Map.fetch!(state._capture.binary_refs, {:binary_binding, :asset, resource, version})
      binding = read_capture_json!(state, ref)

      ensure(
        binding["resource_id"] == resource and binding["version_id"] == version and
          binding["plaintext_byte_size"] == record["original_byte_size"],
        :integrity_failure
      )
    end

    create_file!(state, path)

    {state, size, digest} =
      with_device!(state, path, fn device ->
        initial = {state, 0, :crypto.hash_init(:sha256)}

        emit = fn bytes, {current, size, hash} ->
          try do
            alive!(current)
            ensure(is_binary(bytes) and byte_size(bytes) <= @chunk)
            ensure(size + byte_size(bytes) <= record["original_byte_size"], :integrity_failure)
            current = final_write!(current, path, device, bytes)
            {:ok, {current, size + byte_size(bytes), :crypto.hash_update(hash, bytes)}}
          rescue
            _ -> error(:storage_unavailable)
          catch
            {:writer_error, code} -> error(code)
            _, _ -> error(:storage_unavailable)
          end
        end

        case state._fold.(selector, initial, emit) do
          {:ok, {next, size, hash}} -> {next, size, :crypto.hash_final(hash) |> hex()}
          {:error, %Error{code: code}} -> fail(safe_code(code))
          _ -> fail(:integrity_failure)
        end
      end)

    ensure(size == record["original_byte_size"], :integrity_failure)

    ensure(
      is_nil(record["original_digest"]) or digest == record["original_digest"],
      :integrity_failure
    )

    register_output!(state, path, record["media_type"], size, digest)
  end

  defp exact_text_ref!(state, selector, ref) do
    expected = Map.get(state._capture.text_refs, selector)
    ensure(not is_nil(expected) and expected === ref)
  end

  defp write_note!(state, resource, version, ref) do
    record = record!(state, :versions, {resource, version})
    ensure(record["kind"] == "note" and record["availability"] == "included")
    ensure(ref.byte_size <= KnowledgeExport.limits().note_bytes, :integrity_failure)
    state = charge!(state, ref.byte_size, 1)
    body = read_capture_bytes!(state, ref)
    ensure(sha(body) == record["body_digest"], :integrity_failure)

    descriptions_ref =
      Map.fetch!(state._capture.render_refs, {:render_descriptions, resource, version})

    state = charge!(state, descriptions_ref.byte_size, 1)
    descriptions = read_capture_json!(state, descriptions_ref) |> typed_descriptions!()
    verify_descriptions!(state, resource, version, descriptions)
    files = source_files!(state, descriptions)
    rendered = value!(NoteMarkdownSources.render_portable(body, descriptions, files))
    ensure(byte_size(rendered) <= KnowledgeExport.limits().rendered_note_bytes)
    state = charge!(state, byte_size(rendered), 1)
    path = record["body_path"]
    exact_path!(:note, resource, version, nil, path)
    create_file!(state, path)

    state =
      with_device!(state, path, fn device -> write_binary!(state, path, device, rendered) end)

    register_output!(state, path, "text/markdown", byte_size(rendered), sha(rendered))
  end

  defp write_fragment!(state, resource, version, ordinal, id, ref) do
    record = record!(state, :fragments, {resource, version, ordinal, id})
    doc = record!(state, :versions, {resource, version})

    ensure(
      doc["kind"] == "document" and doc["availability"] == "included" and doc["state"] == "ready"
    )

    ensure(ref.byte_size <= KnowledgeExport.limits().fragment_bytes, :integrity_failure)
    state = charge!(state, ref.byte_size, 1)
    text = read_capture_bytes!(state, ref)
    ensure(sha(text) == record["digest"], :integrity_failure)

    ensure(
      DocumentFragment.id(version, record["locator"], ordinal, :crypto.hash(:sha256, text)) == id,
      :integrity_failure
    )

    key = {resource, version}

    progress =
      Map.get(state._documents, key, %{count: 0, byte_size: 0, hash: :crypto.hash_init(:sha256)})

    ensure(
      progress.count == ordinal and record["start_byte"] == progress.byte_size and
        record["byte_size"] == byte_size(text) and
        record["extracted_path"] == doc["extracted_path"],
      :integrity_failure
    )

    path = doc["extracted_path"]
    exact_path!(:extracted, resource, version, nil, path)
    if ordinal == 0, do: create_file!(state, path)
    state = with_device!(state, path, fn device -> final_write!(state, path, device, text) end)

    progress = %{
      count: ordinal + 1,
      byte_size: progress.byte_size + byte_size(text),
      hash: :crypto.hash_update(progress.hash, text)
    }

    ensure(progress.count <= 4096 and progress.byte_size <= 16_777_216, :integrity_failure)
    state = %{state | _documents: Map.put(state._documents, key, progress)}

    count = Map.fetch!(state._fragment_counts, key)

    if progress.count == count do
      digest = progress.hash |> :crypto.hash_final() |> hex()
      ensure(progress.byte_size > 0 and digest == doc["extracted_digest"], :integrity_failure)
      register_output!(state, path, "text/plain", progress.byte_size, digest)
    else
      state
    end
  end

  defp read_capture_bytes!(state, ref) do
    count = max(1, div(ref.byte_size + @chunk - 1, @chunk))

    bytes =
      Enum.map(0..(count - 1), fn ordinal ->
        alive!(state)
        value!(Spool.read_chunk(state._capture, ref, ordinal))
      end)
      |> IO.iodata_to_binary()

    ensure(byte_size(bytes) == ref.byte_size and sha(bytes) == ref.sha256, :integrity_failure)
    bytes
  end

  defp read_capture_json!(state, ref), do: state |> read_capture_bytes!(ref) |> JSON.decode!()

  defp typed_descriptions!(input) do
    ensure(is_map(input) and Enum.sort(Map.keys(input)) == ~w(attachments citations))
    attachments = Enum.map(input["attachments"], fn d -> typed_descriptor!(d, :attachment) end)
    citations = Enum.map(input["citations"], fn d -> typed_descriptor!(d, :citation) end)
    ensure(length(attachments) <= 100 and length(citations) <= 100)
    %{attachments: attachments, citations: citations}
  end

  defp typed_descriptor!(d, type) do
    ensure(is_map(d) and Enum.sort(Map.keys(d)) == ~w(href reference source))
    source = d["source"]

    ensure(
      is_map(source) and
        Enum.sort(Map.keys(source)) == ~w(deleted? kind resource_id resource_version_id title)
    )

    reference =
      if type == :attachment,
        do: value!(NoteAttachmentReference.new(d["reference"])),
        else: value!(NoteCitationReference.new(d["reference"]))

    %{
      reference: reference,
      href: d["href"],
      source: %{
        kind: kind!(source["kind"]),
        resource_id: source["resource_id"],
        resource_version_id: source["resource_version_id"],
        title: source["title"],
        deleted?: source["deleted?"]
      }
    }
  end

  defp verify_descriptions!(state, resource, version, descriptions) do
    for {collection, items} <- [
          attachments: descriptions.attachments,
          citations: descriptions.citations
        ] do
      keys = Map.get(state._source_keys[collection], {resource, version}, [])

      ensure(length(keys) == length(items), :integrity_failure)

      Enum.zip(keys, items)
      |> Enum.each(fn {key, d} ->
        record = record!(state, collection, key)

        case collection do
          :attachments ->
            ensure(
              record["id"] == d.reference.attachment_id and
                record["target_resource_id"] == d.reference.target_resource_id and
                record["target_version_id"] == d.reference.target_resource_version_id and
                record["target_kind"] == Atom.to_string(d.reference.target_kind) and
                record["role"] == Atom.to_string(d.reference.role) and
                record["label"] == d.reference.label,
              :integrity_failure
            )

          :citations ->
            ensure(
              record["id"] == d.reference.citation_id and
                record["source_resource_id"] == d.reference.source_resource_id and
                record["source_version_id"] == d.reference.source_resource_version_id and
                record["fragment_id"] == d.reference.fragment_id and
                record["locator"] == SourceLocator.to_map(d.reference.locator),
              :integrity_failure
            )
        end
      end)
    end
  end

  defp source_files!(state, descriptions) do
    Enum.reduce(descriptions.attachments ++ descriptions.citations, %{}, fn d, files ->
      source = d.source
      key = {source.resource_id, source.resource_version_id}
      version = record!(state, :versions, key)
      ensure(version["kind"] == Atom.to_string(source.kind), :integrity_failure)
      availability = version["availability"]
      ensure(availability != "metadata_only_unavailable", :integrity_failure)

      path =
        case source.kind do
          :note -> version["body_path"]
          :asset -> version["original_path"]
          :document -> version["extracted_path"] || version["original_path"]
        end

      reason =
        case availability do
          "included" -> nil
          "metadata_only_deleted" -> "Deleted source"
          "metadata_only_unselected" -> "Unselected historical metadata"
          _ -> fail(:integrity_failure)
        end

      Map.put(files, {source.kind, elem(key, 0), elem(key, 1)}, %{
        availability: availability,
        path: path,
        reason: reason
      })
    end)
  end

  defp complete_records!(state) do
    for collection <- @collections do
      ensure(
        Enum.sort(Map.keys(state._records[collection])) ==
          Enum.sort(Map.keys(state._captured[collection])),
        :integrity_failure
      )
    end
  end

  defp verify_closure!(state) do
    each_record!(state, :resources, fn r ->
      if r["current_version_id"] do
        v = record!(state, :versions, {r["id"], r["current_version_id"]})
        ensure(v["kind"] == r["kind"], :integrity_failure)
      end
    end)

    each_record!(state, :versions, fn v ->
      resource = record!(state, :resources, v["resource_id"])

      ensure(
        resource["kind"] == v["kind"] and v["availability"] != "metadata_only_unavailable",
        :integrity_failure
      )

      for parent <- [v["parent_version_id"], v["merge_parent_version_id"]], not is_nil(parent) do
        ancestor = record!(state, :versions, {v["resource_id"], parent})
        ensure(v["kind"] == "note" and ancestor["kind"] == "note", :integrity_failure)
      end
    end)

    each_record!(state, :fragments, fn f ->
      v = record!(state, :versions, {f["resource_id"], f["version_id"]})
      ensure(v["kind"] == "document", :integrity_failure)

      if f["extracted_path"] do
        ensure(
          v["availability"] == "included" and v["state"] == "ready" and
            f["extracted_path"] == v["extracted_path"],
          :integrity_failure
        )
      else
        ensure(v["availability"] != "included", :integrity_failure)
      end
    end)

    each_record!(state, :attachments, fn r ->
      note = record!(state, :versions, {r["note_resource_id"], r["note_version_id"]})
      target = record!(state, :versions, {r["target_resource_id"], r["target_version_id"]})
      ensure(note["kind"] == "note" and target["kind"] == r["target_kind"], :integrity_failure)
      ensure(r["note_resource_id"] != r["target_resource_id"], :integrity_failure)
    end)

    each_record!(state, :citations, fn r ->
      note = record!(state, :versions, {r["note_resource_id"], r["note_version_id"]})
      target = record!(state, :versions, {r["source_resource_id"], r["source_version_id"]})
      ensure(note["kind"] == "note" and target["kind"] == "document", :integrity_failure)

      key =
        Map.get(state._fragment_identities, {
          r["source_resource_id"],
          r["source_version_id"],
          r["fragment_id"]
        })

      ensure(
        is_tuple(key) and tuple_size(key) == 4 and Map.has_key?(state._records.fragments, key),
        :integrity_failure
      )

      fragment = record!(state, :fragments, key)
      ensure(fragment["locator"] == r["locator"], :integrity_failure)
    end)

    verify_source_ordinals!(state)

    each_record!(state, :tag_assignments, fn r ->
      record!(state, :resources, r["resource_id"])
      record!(state, :tags, r["tag_id"])
    end)

    each_record!(state, :relationships, fn r ->
      record!(state, :resources, r["source_resource_id"])
      record!(state, :resources, r["target_resource_id"])

      if r["target_version_id"],
        do: record!(state, :versions, {r["target_resource_id"], r["target_version_id"]})
    end)
  end

  defp verify_source_ordinals!(state) do
    groups =
      Enum.reduce([:attachments, :citations], %{}, fn collection, groups ->
        Enum.reduce(Enum.sort(Map.keys(state._records[collection])), groups, fn {r, v, ordinal, _} =
                                                                                  key,
                                                                                acc ->
          group = Map.get(acc, {r, v}, %{attachments: 0, citations: 0, targets: MapSet.new()})
          ensure(ordinal == group[collection], :integrity_failure)
          record = record!(state, collection, key)

          target =
            case collection do
              :attachments ->
                {record["target_kind"], record["target_resource_id"], record["target_version_id"]}

              :citations ->
                {"document", record["source_resource_id"], record["source_version_id"]}
            end

          targets = MapSet.put(group.targets, target)
          ensure(MapSet.size(targets) <= 100, :integrity_failure)
          group = group |> Map.update!(collection, &(&1 + 1)) |> Map.put(:targets, targets)
          Map.put(acc, {r, v}, group)
        end)
      end)

    ensure(map_size(groups) <= KnowledgeExport.limits().selected_keys)
  end

  defp each_record!(state, collection, fun) do
    state._records[collection]
    |> Map.keys()
    |> Enum.sort()
    |> Enum.each(fn key ->
      alive!(state)
      fun.(record!(state, collection, key))
    end)
  end

  defp complete_files!(state) do
    expected = MapSet.new(Map.keys(state._capture.text_refs))

    expected =
      Enum.reduce(Map.keys(state._records.versions), expected, fn key, acc ->
        r = record!(state, :versions, key)

        if r["availability"] == "included" and r["kind"] in ["asset", "document"],
          do: MapSet.put(acc, {:original, kind!(r["kind"]), elem(key, 0), elem(key, 1)}),
          else: acc
      end)

    ensure(expected == state._seen, :integrity_failure)

    each_record!(state, :versions, fn r ->
      for path <- [r["body_path"], r["original_path"], r["extracted_path"]], not is_nil(path) do
        ensure(Map.has_key?(state._outputs, path), :integrity_failure)
      end
    end)
  end

  defp write_manifest!(state) do
    create_file!(state, "manifest.json")
    state = Map.put(state, :_manifest_hash, :crypto.hash_init(:sha256))

    state =
      with_device!(state, "manifest.json", fn device ->
        start =
          "{\"format\":\"singularity.portable-knowledge\",\"version\":1,\"selection\":{\"mode\":\"live_heads_with_source_closure\",\"include_tombstones\":" <>
            JSON.encode!(state._options.include_tombstones) <> "}"

        state = write_binary!(state, "manifest.json", device, start)

        state =
          Enum.reduce(@collections, state, fn collection, current ->
            current = write_binary!(current, "manifest.json", device, ",\"#{collection}\":[")

            {current, _} =
              current._records[collection]
              |> Map.keys()
              |> Enum.sort()
              |> Enum.reduce({current, true}, fn key, {acc, first?} ->
                record = record!(acc, collection, key) |> public_record!(acc, collection)
                acc = if first?, do: acc, else: write_binary!(acc, "manifest.json", device, ",")

                {write_binary!(acc, "manifest.json", device, encode_record(collection, record)),
                 false}
              end)

            write_binary!(current, "manifest.json", device, "]")
          end)

        state = write_binary!(state, "manifest.json", device, ",\"files\":[")

        {state, _} =
          state._outputs
          |> Map.keys()
          |> Enum.sort()
          |> Enum.reduce({state, true}, fn path, {acc, first?} ->
            acc = if first?, do: acc, else: write_binary!(acc, "manifest.json", device, ",")
            record = descriptor(path, acc._outputs[path])
            core_record!(:files, record)
            {write_binary!(acc, "manifest.json", device, encode_record(:files, record)), false}
          end)

        write_binary!(state, "manifest.json", device, "]}")
      end)

    size = state.accounting.manifest_bytes
    digest = state._manifest_hash |> :crypto.hash_final() |> hex()
    state = register_output!(state, "manifest.json", "application/json", size, digest)
    Map.put(state, :manifest, descriptor("manifest.json", state._outputs["manifest.json"]))
  end

  defp public_record!(record, state, collection) do
    record =
      if collection == :versions and pending_asset?(record) do
        output = Map.fetch!(state._outputs, record["original_path"])
        ensure(output.byte_size == record["original_byte_size"], :integrity_failure)
        Map.put(record, "original_digest", output.sha256)
      else
        record
      end

    core_record!(collection, record)
  end

  defp encode_record(collection, record) do
    "{" <>
      Enum.map_join(@fields[collection], ",", fn key ->
        JSON.encode!(key) <> ":" <> JSON.encode!(record[key])
      end) <> "}"
  end

  defp register_output!(state, path, media, expected_size, expected_digest) do
    ensure(not Map.has_key?(state._outputs, path))
    {size, digest, chunks} = hash_native!(state, path, true)
    ensure(size == expected_size and digest == expected_digest, :integrity_failure)
    index = JSON.encode!([path, media, size, digest])
    state = charge!(state, byte_size(index) + 1, 1)
    append_native!(state, ".index", index <> "\n")

    state =
      Enum.reduce(Enum.sort(chunks), state, fn {ordinal, hash}, current ->
        entry = JSON.encode!([path, ordinal, hash]) <> "\n"
        current = charge!(current, byte_size(entry), 1)
        append_native!(current, ".index", entry)
        current
      end)

    output = %{media_type: media, byte_size: size, sha256: digest, chunks: chunks}
    %{state | _outputs: Map.put(state._outputs, path, output)}
  end

  defp descriptor(path, output),
    do: %{
      "path" => path,
      "media_type" => output.media_type,
      "byte_size" => output.byte_size,
      "sha256" => output.sha256
    }

  defp verify_outputs!(state) do
    Enum.each(state._outputs, fn {path, output} ->
      {size, digest, chunks} = hash_native!(state, path)

      ensure(
        size == output.byte_size and digest == output.sha256 and chunks == output.chunks,
        :integrity_failure
      )
    end)
  end

  defp publish!(state) do
    alive!(state)
    filesystem!(state)
    root = state._identity.root
    target = Path.join(root, state.operation_id <> ".complete")
    # mkdir is exclusive. Existing empty/nonempty directories and symlinks deny.
    native!(File.mkdir(target))
    stat = File.lstat!(target)
    :ets.insert(state._ledger, {:reservation, identity(stat)})
    native!(File.chmod(target, 0o700))
    ensure(identity(private_directory!(target)) == identity(stat), :integrity_failure)
    alive!(state)
    ensure(File.ls!(target) == [], :integrity_failure)
    ensure(identity(File.lstat!(target)) == identity(stat), :integrity_failure)
    filesystem!(state)
    native!(File.rename(directory(state), target))
    :ets.insert(state._ledger, {:location, :complete})
    :ets.delete(state._ledger, :reservation)
    ensure(identity(File.lstat!(target)) == state._identity.operation_stat, :integrity_failure)
    alive!(state)
    filesystem!(state)

    Map.drop(state, [
      :_capture,
      :_captured,
      :_fragment_counts,
      :_fragment_identities,
      :_source_keys,
      :_records,
      :_fold,
      :_write,
      :_documents,
      :_seen,
      :_journal_size,
      :_options,
      :_manifest_hash
    ])
  end

  defp write_binary!(state, path, device, bytes) when byte_size(bytes) <= @chunk,
    do: final_write!(state, path, device, bytes)

  defp write_binary!(state, path, device, <<chunk::binary-size(@chunk), rest::binary>>) do
    state = final_write!(state, path, device, chunk)
    write_binary!(state, path, device, rest)
  end

  defp final_write!(state, path, device, bytes) do
    accounting = %{
      state.accounting
      | file_bytes: state.accounting.file_bytes + byte_size(bytes),
        manifest_bytes:
          state.accounting.manifest_bytes +
            if(path == "manifest.json", do: byte_size(bytes), else: 0)
    }

    budget!(accounting)
    state = %{state | accounting: accounting}

    state =
      if path == "manifest.json",
        do: Map.update!(state, :_manifest_hash, &:crypto.hash_update(&1, bytes)),
        else: state

    write_device!(state, path, device, bytes)
    state
  end

  defp charge!(state, bytes, records) do
    accounting = %{
      state.accounting
      | spool_bytes: state.accounting.spool_bytes + bytes,
        metadata_records: state.accounting.metadata_records + records
    }

    budget!(accounting)
    %{state | accounting: accounting}
  end

  defp budget!(accounting) do
    limits = KnowledgeExport.limits()

    caps = %{
      spool_bytes: limits.metadata_bytes,
      metadata_records: limits.metadata_records,
      selected_keys: limits.selected_keys,
      file_bytes: limits.file_bytes,
      manifest_bytes: limits.metadata_bytes
    }

    ensure(is_map(accounting) and Enum.sort(Map.keys(accounting)) == Enum.sort(Map.keys(caps)))

    ensure(
      Enum.all?(caps, fn {key, cap} ->
        is_integer(accounting[key]) and accounting[key] in 0..cap
      end)
    )
  end

  defp append_native!(state, path, bytes) do
    with_device!(state, path, fn device -> write_temp!(state, path, device, bytes) end)
  end

  defp write_temp!(state, path, device, bytes) when byte_size(bytes) <= @chunk,
    do: write_device!(state, path, device, bytes)

  defp write_temp!(state, path, device, <<chunk::binary-size(@chunk), rest::binary>>) do
    write_device!(state, path, device, chunk)
    write_temp!(state, path, device, rest)
  end

  defp with_device!(state, path, fun) do
    file_valid!(state, path)
    device = value!(File.open(filename(state, path), [:read, :write, :binary]))

    try do
      value!(:file.position(device, :eof))
      fun.(device)
    after
      native!(:file.close(device))
    end
  end

  defp write_device!(state, path, device, bytes) do
    alive!(state)
    file_valid!(state, path)
    [{_, entry}] = :ets.lookup(state._ledger, {:file, path})
    native!(state._write.(device, bytes))
    stat = File.lstat!(filename(state, path))

    ensure(
      identity(stat) == entry.identity and stat.size == entry.size + byte_size(bytes),
      :integrity_failure
    )

    :ets.insert(state._ledger, {{:file, path}, %{entry | size: stat.size}})
    alive!(state)
    :ok
  end

  defp create_file!(state, path) do
    filesystem!(state)
    ensure(not :ets.member(state._ledger, {:file, path}))
    parent = Path.dirname(path)
    if parent != ".", do: create_directories!(state, Path.split(parent), "")
    device = value!(File.open(filename(state, path), [:write, :binary, :exclusive]))

    try do
      stat = File.lstat!(filename(state, path))
      :ets.insert(state._ledger, {{:file, path}, %{identity: identity(stat), size: 0}})
      native!(File.chmod(filename(state, path), 0o600))
      file_valid!(state, path)
    after
      native!(:file.close(device))
    end
  end

  defp create_directories!(_state, [], _prefix), do: :ok

  defp create_directories!(state, [part | rest], prefix) do
    prefix = if prefix == "", do: part, else: prefix <> "/" <> part
    ensure(prefix in @directories, :integrity_failure)
    path = filename(state, prefix)

    case File.lstat(path) do
      {:error, :enoent} ->
        native!(File.mkdir(path))
        stat = File.lstat!(path)
        :ets.insert(state._ledger, {{:directory, prefix}, identity(stat)})
        native!(File.chmod(path, 0o700))

      {:ok, %File.Stat{type: :directory} = stat} ->
        ensure(
          band(stat.mode, 0o777) == 0o700 and stat.uid == elem(state._identity.operation_stat, 2),
          :integrity_failure
        )

        case :ets.lookup(state._ledger, {:directory, prefix}) do
          [] -> :ets.insert(state._ledger, {{:directory, prefix}, identity(stat)})
          [{_, original}] -> ensure(identity(stat) == original, :integrity_failure)
        end

      _ ->
        fail(:integrity_failure)
    end

    create_directories!(state, rest, prefix)
  end

  defp file_valid!(state, path) do
    filesystem_root!(state)
    [{_, entry}] = :ets.lookup(state._ledger, {:file, path})
    safe_absolute!(Path.dirname(filename(state, path)))
    stat = File.lstat!(filename(state, path))

    ensure(
      stat.type == :regular and band(stat.mode, 0o777) == 0o600 and
        identity(stat) == entry.identity and stat.size == entry.size,
      :integrity_failure
    )
  end

  defp read_native!(state, path, offset, size) do
    file_valid!(state, path)
    device = value!(File.open(filename(state, path), [:read, :binary]))

    try do
      case :file.pread(device, offset, size) do
        {:ok, bytes} when byte_size(bytes) == size -> bytes
        :eof when size == 0 -> ""
        _ -> fail(:integrity_failure)
      end
    after
      native!(:file.close(device))
    end
  end

  defp hash_native!(state, path, reserve? \\ false) do
    file_valid!(state, path)
    device = value!(File.open(filename(state, path), [:read, :binary]))

    try do
      available =
        if reserve?,
          do: KnowledgeExport.limits().metadata_records - state.accounting.metadata_records - 1,
          else: KnowledgeExport.limits().metadata_records

      hash_device!(state, device, 0, :crypto.hash_init(:sha256), %{}, available)
    after
      native!(:file.close(device))
    end
  end

  defp hash_device!(state, device, size, hash, chunks, available) do
    alive!(state)

    case :file.read(device, @chunk) do
      {:ok, bytes} ->
        ensure(map_size(chunks) < available)

        hash_device!(
          state,
          device,
          size + byte_size(bytes),
          :crypto.hash_update(hash, bytes),
          Map.put(chunks, map_size(chunks), sha(bytes)),
          available
        )

      :eof ->
        ensure(available >= 1)
        chunks = if size == 0, do: %{0 => sha("")}, else: chunks
        {size, hash |> :crypto.hash_final() |> hex(), chunks}

      _ ->
        fail(:storage_unavailable)
    end
  end

  defp filesystem!(state) do
    filesystem_root!(state)

    for path <- @directories do
      case :ets.lookup(state._ledger, {:directory, path}) do
        [] ->
          :ok

        [{_, original}] ->
          ensure(
            identity(private_directory!(filename(state, path))) == original,
            :integrity_failure
          )
      end
    end
  end

  defp filesystem_root!(state) do
    safe_absolute!(state._identity.root)

    ensure(
      identity(private_directory!(state._identity.root)) == state._identity.root_stat,
      :integrity_failure
    )

    ensure(
      identity(private_directory!(directory(state))) == state._identity.operation_stat,
      :integrity_failure
    )
  end

  defp identity_valid!(state) do
    ensure(is_map(state) and not is_struct(state))
    ensure(state.operation_id == state._identity.id and is_binary(state.operation_id))
    ensure(Ecto.UUID.cast(state.operation_id) == {:ok, state.operation_id})
    ensure(:ets.info(state._ledger) != :undefined)

    ensure(
      :ets.lookup(state._ledger, :binding) == [
        {:binding,
         %{
           identity: state._identity,
           deadline: state.deadline,
           clock: state._clock,
           phase: state._phase
         }}
      ]
    )
  end

  defp alive!(state) do
    ensure(:atomics.get(state._phase, 2) == 0)
    now = state._clock.()
    ensure(is_integer(now) and now < state.deadline)
  end

  defp cleanup!(state) do
    safe_absolute!(state._identity.root)

    ensure(
      identity(private_directory!(state._identity.root)) == state._identity.root_stat,
      :integrity_failure
    )

    path = directory(state)

    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :directory} = stat} ->
        ensure(identity(stat) == state._identity.operation_stat, :integrity_failure)
        cleanup_children!(state, path, "")
        native!(File.rmdir(path))

      _ ->
        fail(:integrity_failure)
    end

    case :ets.lookup(state._ledger, :reservation) do
      [{:reservation, original}] ->
        target = Path.join(state._identity.root, state.operation_id <> ".complete")

        ensure(
          identity(File.lstat!(target)) == original and File.ls!(target) == [],
          :integrity_failure
        )

        native!(File.rmdir(target))
        :ets.delete(state._ledger, :reservation)

      [] ->
        :ok
    end

    :ok
  end

  defp cleanup_children!(state, directory, prefix) do
    Enum.each(File.ls!(directory), fn basename ->
      relative = if prefix == "", do: basename, else: prefix <> "/" <> basename
      path = Path.join(directory, basename)
      stat = File.lstat!(path)
      ensure(stat.uid == elem(state._identity.operation_stat, 2), :integrity_failure)

      case stat.type do
        :directory ->
          case :ets.lookup(state._ledger, {:directory, relative}) do
            [{_, original}] -> ensure(identity(stat) == original, :integrity_failure)
            [] -> :ok
          end

          cleanup_children!(state, path, relative)
          ensure(identity(File.lstat!(path)) == identity(stat), :integrity_failure)
          native!(File.rmdir(path))

        type when type in [:regular, :symlink] ->
          case :ets.lookup(state._ledger, {:file, relative}) do
            [{_, original}] -> ensure(identity(stat) == original.identity, :integrity_failure)
            [] -> :ok
          end

          ensure(identity(File.lstat!(path)) == identity(stat), :integrity_failure)
          native!(File.rm(path))

        _ ->
          fail(:integrity_failure)
      end
    end)
  end

  defp directory(state) do
    [{:location, location}] = :ets.lookup(state._ledger, :location)

    Path.join(
      state._identity.root,
      state.operation_id <> if(location == :complete, do: ".complete", else: ".staging")
    )
  end

  defp filename(state, relative), do: Path.join(directory(state), relative)

  defp safe_absolute!(path) do
    ensure(
      is_binary(path) and Path.type(path) == :absolute and Path.expand(path) == path and
        not String.contains?(path, <<0>>)
    )

    path
    |> Path.split()
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.each(fn part ->
      case File.lstat(part) do
        {:ok, %File.Stat{type: :directory}} -> :ok
        _ -> fail(:invalid)
      end
    end)
  end

  defp private_directory!(path) do
    stat = File.lstat!(path)
    ensure(stat.type == :directory and band(stat.mode, 0o777) == 0o700)
    stat
  end

  defp disjoint?(a, b),
    do: a != b and not String.starts_with?(a, b <> "/") and not String.starts_with?(b, a <> "/")

  defp identity(stat), do: {stat.major_device, stat.inode, stat.uid, stat.gid}

  defp exact_path!(kind, resource, version, media, path) do
    media = if kind == :document, do: media, else: nil
    ensure(KnowledgeExport.path(kind, resource, version, media) == {:ok, path})
  end

  defp cursor(state, after_key),
    do: %{
      operation_id: state.operation_id,
      after: after_key,
      proof: cursor_proof(state, after_key)
    }

  defp cursor_key!(_state, nil), do: nil

  defp cursor_key!(state, cursor) do
    ensure(
      is_map(cursor) and not is_struct(cursor) and
        Enum.sort(Map.keys(cursor)) == [:after, :operation_id, :proof]
    )

    ensure(
      cursor.operation_id == state.operation_id and is_binary(cursor.after) and
        Map.has_key?(state._outputs, cursor.after) and
        cursor.proof == cursor_proof(state, cursor.after)
    )

    cursor.after
  end

  defp cursor_proof(state, key),
    do: :crypto.mac(:hmac, :sha256, state._secret, state.operation_id <> ":" <> key) |> hex()

  defp json_key(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.map(&json_key/1)

  defp json_key(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), json_key(v)} end)

  defp json_key(value) when is_list(value), do: Enum.map(value, &json_key/1)

  defp json_key(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp json_key(value), do: value
  defp kind!("asset"), do: :asset
  defp kind!("document"), do: :document
  defp kind!("note"), do: :note
  defp kind!(_), do: fail(:invalid)
  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> hex()
  defp hex(bytes), do: bytes |> Base.encode16(case: :lower) |> :binary.copy()
  defp native!(:ok), do: :ok
  defp native!(_), do: fail(:storage_unavailable)
  defp value!({:ok, value}), do: value
  defp value!({:error, %Error{code: code}}), do: fail(safe_code(code))
  defp value!(_), do: fail(:storage_unavailable)

  defp safe_code(code)
       when code in [:invalid, :integrity_failure, :storage_unavailable, :forbidden, :conflict],
       do: code

  defp safe_code(_), do: :storage_unavailable
  defp ensure(true, _code), do: :ok
  defp ensure(_, code), do: fail(code)
  defp ensure(value), do: ensure(value, :invalid)
  defp fail(code), do: throw({:writer_error, code})
  defp error(code), do: {:error, Error.new(code)}
end
