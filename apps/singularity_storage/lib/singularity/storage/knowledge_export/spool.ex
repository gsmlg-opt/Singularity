defmodule Singularity.Storage.KnowledgeExport.Spool do
  @moduledoc "Private, bounded capture journal. Its descriptors are internal, not public artifacts."

  alias Singularity.Core.{
    Error,
    KnowledgeExport,
    KnowledgeExportManifest,
    NoteMarkdownSources,
    SourceLocator
  }

  alias Singularity.Storage.Local.PathGuard
  import Bitwise, only: [band: 2]

  @collections ~w(resources versions fragments tags tag_assignments relationships attachments citations)a
  @context_keys [:root, :storage_root, :backup_root, :clock, :write]
  @binding_keys ~w(kind resource_id version_id asset_id object_id owner_scope_id classification key_domain_id domain_key_version_id domain_key_generation object_generation lookup_digest ciphertext_hash plaintext_byte_size ciphertext_byte_size storage_ref format_version plaintext_sha256)
  @busy -1
  @sealed -2
  @aborted -3
  @frame_bytes 40

  def open(context) do
    with :ok <- context_valid(context),
         {:ok, root_stat} <- private_directory(context.root),
         :ok <- safe_absolute(context.root),
         id = Ecto.UUID.generate(),
         directory = Path.join(context.root, id),
         :ok <- File.mkdir(directory),
         {:ok, %File.Stat{type: :directory} = owned_stat} <- File.lstat(directory) do
      create_operation(context, root_stat, id, directory, owned_stat)
    else
      _ -> error(:invalid)
    end
  rescue
    _ -> error(:storage_unavailable)
  catch
    _, _ -> error(:storage_unavailable)
  end

  def append(spool, selector, value) do
    mutate(spool, fn current ->
      with {:ok, kind, payload, selected, original} <- prepare(current, selector, value),
           {:ok, current} <-
             admit(current, selected, original, retained_records(current, selector, value)),
           {:ok, current, frames} <- journal_payload(current, selector, kind, payload) do
        install(current, selector, kind, payload, frames)
      end
    end)
  end

  def seal(spool) do
    mutate(spool, fn current ->
      accounting = %{
        current.accounting
        | metadata_records: current.accounting.metadata_records + 2 * map_size(current._texts)
      }

      current = %{current | accounting: accounting}

      with :ok <- budget(accounting),
           :ok <- complete_texts(current),
           :ok <- complete_documents(current),
           :ok <- complete_drafts(current),
           :ok <- filesystem(current, true) do
        {text_refs, render_refs, binary_refs} = sealed_refs(current)

        sealed =
          current
          |> Map.put(:text_refs, text_refs)
          |> Map.put(:render_refs, render_refs)
          |> Map.put(:binary_refs, binary_refs)
          |> Map.put(:sealed?, true)
          |> Map.update!(:_texts, fn texts ->
            Map.new(texts, fn {key, entry} ->
              {key, entry |> Map.delete(:hash) |> Map.delete(:carry)}
            end)
          end)

        {:sealed, sealed}
      end
    end)
  end

  def read_metadata(spool, collection, key) when collection in @collections do
    with :ok <- readable(spool),
         {:ok, frame} <- Map.fetch(spool._collections[collection], key) do
      with {:ok, bytes} <- checked_metadata_payload(spool, collection, frame),
           record = JSON.decode!(bytes),
           :ok <- metadata_valid(spool, collection, record),
           true <- record_key(collection, record) === key do
        {:ok, record}
      else
        _ -> fail_capture(spool, :integrity_failure)
      end
    else
      {:error, %Error{}} = failure -> failure
      _ -> error(:invalid)
    end
  rescue
    _ -> fail_capture(spool, :integrity_failure)
  catch
    _, _ -> fail_capture(spool, :integrity_failure)
  end

  def read_metadata(_, _, _), do: error(:invalid)

  def reduce_metadata(spool, collection, initial, consume)
      when collection in @collections and is_function(consume, 2) do
    with :ok <- readable(spool) do
      keys = spool._collections |> Map.fetch!(collection) |> Map.keys() |> Enum.sort()

      result =
        Enum.reduce_while(keys, {:ok, initial}, fn key, {:ok, acc} ->
          with {:ok, record} <- read_metadata(spool, collection, key),
               {:ok, next} <- consume.(record, acc) do
            {:cont, {:ok, next}}
          else
            {:error, %Error{code: code, retryable?: retryable?}} ->
              {:halt, {:error, Error.new(code, retryable?: retryable?)}}

            _ ->
              {:halt, error(:invalid)}
          end
        end)

      with {:ok, final} <- result, :ok <- readable(spool), do: {:ok, final}
    end
  rescue
    _ -> error(:storage_unavailable)
  catch
    _, _ -> error(:storage_unavailable)
  end

  def reduce_metadata(_, _, _, _), do: error(:invalid)

  def read_page(spool, cursor, limit) do
    with :ok <- readable(spool),
         true <- is_integer(limit) and limit in 1..500,
         {:ok, collection, after_key} <- check_cursor(spool, cursor) do
      indexes = Map.fetch!(spool._collections, collection)

      keys =
        indexes
        |> Map.keys()
        |> Enum.sort()
        |> Enum.filter(fn key -> is_nil(after_key) or key > after_key end)
        |> Enum.take(limit + 1)

      page_keys = Enum.take(keys, limit)

      with {:ok, records} <- read_records(spool, indexes, page_keys) do
        next =
          if length(keys) > limit,
            do: next_cursor(spool, collection, List.last(page_keys)),
            else: nil

        {:ok, %{records: records, next_cursor: next}}
      else
        _ -> fail_capture(spool, :integrity_failure)
      end
    else
      {:error, %Error{}} = failure -> failure
      _ -> error(:invalid)
    end
  rescue
    _ -> fail_capture(spool, :integrity_failure)
  catch
    _, _ -> fail_capture(spool, :integrity_failure)
  end

  def read_chunk(spool, reference, ordinal) do
    with :ok <- readable(spool),
         true <- is_map(reference) and not is_struct(reference),
         true <- is_integer(ordinal) and ordinal >= 0,
         {:ok, entry} <- exact_reference(spool, reference),
         true <- ordinal < max(1, div(reference.byte_size + 65_535, 65_536)) do
      start = ordinal * 65_536
      size = min(65_536, max(0, reference.byte_size - start))

      case read_range(spool, entry.frames, start, size) do
        {:ok, bytes} -> {:ok, bytes}
        _ -> fail_capture(spool, :integrity_failure)
      end
    else
      {:error, %Error{}} = failure -> failure
      _ -> error(:invalid)
    end
  rescue
    _ -> fail_capture(spool, :integrity_failure)
  catch
    _, _ -> fail_capture(spool, :integrity_failure)
  end

  def abort(spool) do
    with :ok <- identity_valid(spool),
         :ok <- filesystem(spool, false) do
      :atomics.put(spool._phase, 1, @aborted)
      cleanup(spool)
    else
      {:error, %Error{}} = failure -> failure
      _ -> error(:invalid)
    end
  rescue
    _ -> error(:storage_unavailable)
  catch
    _, _ -> error(:storage_unavailable)
  end

  defp context_valid(context) when is_map(context) and not is_struct(context) do
    with true <- Enum.all?(Map.keys(context), &(&1 in @context_keys)),
         true <- Enum.all?([:root, :storage_root, :backup_root], &Map.has_key?(context, &1)),
         true <-
           Enum.all?([context.root, context.storage_root, context.backup_root], &absolute?/1),
         true <- context.root != "/",
         true <-
           Enum.all?(
             [context.storage_root, context.backup_root],
             &(PathGuard.assert_safe_path("/", &1) == :ok)
           ),
         true <- disjoint?(context.root, context.storage_root),
         true <- disjoint?(context.root, context.backup_root),
         true <- not Map.has_key?(context, :clock) or is_function(context.clock, 0),
         true <- not Map.has_key?(context, :write) or is_function(context.write, 2) do
      :ok
    else
      _ -> error(:invalid)
    end
  end

  defp context_valid(_), do: error(:invalid)

  defp absolute?(path),
    do:
      is_binary(path) and Path.type(path) == :absolute and Path.expand(path) == path and
        not String.contains?(path, <<0>>)

  defp disjoint?(left, right),
    do:
      left != right and not String.starts_with?(left, right <> "/") and
        not String.starts_with?(right, left <> "/")

  defp safe_absolute(path) do
    path
    |> Path.split()
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.reduce_while(:ok, fn component, :ok ->
      case File.lstat(component) do
        {:ok, %File.Stat{type: :directory}} -> {:cont, :ok}
        _ -> {:halt, error(:invalid)}
      end
    end)
  end

  defp private_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory, mode: mode} = stat} when band(mode, 0o777) == 0o700 ->
        {:ok, stat}

      _ ->
        error(:invalid)
    end
  end

  defp create_operation(context, root_stat, id, directory, owned_stat) do
    phase = :atomics.new(1, signed: true)
    clock = Map.get(context, :clock, fn -> System.monotonic_time(:millisecond) end)
    writer = Map.get(context, :write, &IO.binwrite/2)

    with :ok <- File.chmod(directory, 0o700),
         {:ok, operation_stat} <- private_directory(directory),
         true <- identity(operation_stat) == identity(owned_stat),
         true <- operation_stat.uid == root_stat.uid,
         now when is_integer(now) <- clock.(),
         {:ok, files} <- create_files(directory, owned_stat) do
      initialize_operation(
        context,
        root_stat,
        id,
        directory,
        operation_stat,
        files,
        phase,
        clock,
        writer,
        now
      )
    else
      _ ->
        cleanup_created(directory, owned_stat, %{})
        error(:storage_unavailable)
    end
  rescue
    _ ->
      cleanup_created(directory, owned_stat, %{})
      error(:storage_unavailable)
  end

  defp initialize_operation(
         context,
         root_stat,
         id,
         directory,
         operation_stat,
         files,
         phase,
         clock,
         writer,
         now
       ) do
    {:ok,
     %{
       capture_id: id,
       accounting: %{spool_bytes: 0, metadata_records: 0, selected_keys: 0, original_bytes: 0},
       _phase: phase,
       _generation: 0,
       _clock: clock,
       _deadline: now + KnowledgeExport.limits().execution_ms,
       _write: writer,
       _secret: :crypto.strong_rand_bytes(32),
       _identity: %{
         id: id,
         root: context.root,
         root_stat: identity(root_stat),
         operation_stat: identity(operation_stat),
         files: Map.new(files, fn {name, stat} -> {name, identity(stat)} end)
       },
       _sizes: %{payload: 0, index: 0},
       _selected: MapSet.new(),
       _collections: Map.new(@collections, &{&1, %{}}),
       _texts: %{},
       _documents: %{},
       _bindings: %{},
       _drafts: %{},
       _versions: %{},
       text_refs: %{},
       render_refs: %{},
       binary_refs: %{},
       sealed?: false
     }}
  rescue
    _ ->
      cleanup_created(directory, operation_stat, files)
      error(:storage_unavailable)
  end

  defp create_files(directory, owned_stat) do
    Enum.reduce_while([:payload, :index], {:ok, %{}}, fn name, {:ok, files} ->
      case exclusive_file(Path.join(directory, Atom.to_string(name))) do
        {:ok, stat} ->
          {:cont, {:ok, Map.put(files, name, stat)}}

        {:created_error, stat} ->
          cleanup_created(directory, owned_stat, Map.put(files, name, stat))
          {:halt, error(:storage_unavailable)}

        _ ->
          cleanup_created(directory, owned_stat, files)
          {:halt, error(:storage_unavailable)}
      end
    end)
  end

  defp exclusive_file(path) do
    with {:ok, device} <- File.open(path, [:write, :binary, :exclusive]) do
      try do
        case File.lstat(path) do
          {:ok, %File.Stat{type: :regular} = created} ->
            with :ok <- File.chmod(path, 0o600),
                 {:ok, %File.Stat{type: :regular} = stat} <- File.lstat(path),
                 true <- identity(stat) == identity(created) do
              {:ok, stat}
            else
              _ -> {:created_error, created}
            end

          _ ->
            error(:storage_unavailable)
        end
      after
        File.close(device)
      end
    end
  end

  defp cleanup_created(directory, owned_stat, files) do
    # Creation failures have no descriptor. Retain exact ownership evidence,
    # never follow a replacement directory or delete an unowned existing file.
    case File.lstat(directory) do
      {:ok, %File.Stat{type: :directory} = current} ->
        if identity(current) == identity(owned_stat) do
          Enum.each(files, fn {name, original} ->
            path = Path.join(directory, Atom.to_string(name))

            case File.lstat(path) do
              {:ok, %File.Stat{type: :regular} = stat} ->
                if identity(stat) == identity(original), do: File.rm(path)

              _ ->
                :ok
            end
          end)

          File.rmdir(directory)
        end

      _ ->
        :ok
    end
  end

  defp mutate(spool, callback) do
    with :ok <- identity_valid(spool),
         false <- spool.sealed?,
         true <- is_integer(spool._generation) and spool._generation >= 0,
         :ok <- :atomics.compare_exchange(spool._phase, 1, spool._generation, @busy) do
      try do
        with :ok <- alive(spool),
             :ok <- filesystem(spool, true) do
          case callback.(spool) do
            {:ok, next} ->
              generation = spool._generation + 1

              with :ok <- alive(next),
                   :ok <- :atomics.compare_exchange(spool._phase, 1, @busy, generation) do
                {:ok, %{next | _generation: generation}}
              else
                _ -> fail_capture(spool, :invalid)
              end

            {:sealed, next} ->
              with :ok <- alive(next),
                   :ok <- :atomics.compare_exchange(spool._phase, 1, @busy, @sealed) do
                {:ok, next}
              else
                _ -> fail_capture(spool, :invalid)
              end

            {:error, %Error{code: code}} ->
              fail_capture(spool, code)

            _ ->
              fail_capture(spool, :invalid)
          end
        else
          _ -> fail_capture(spool, :integrity_failure)
        end
      rescue
        _ -> fail_capture(spool, :storage_unavailable)
      catch
        _, _ -> fail_capture(spool, :storage_unavailable)
      end
    else
      _ -> error(:invalid)
    end
  rescue
    _ -> error(:invalid)
  end

  defp identity_valid(%{capture_id: id, _identity: %{id: original, root: root}, _phase: phase}) do
    with true <- id == original,
         {:ok, ^id} <- PathGuard.uuid(id),
         true <- absolute?(root),
         _ <- :atomics.get(phase, 1) do
      :ok
    else
      _ -> error(:invalid)
    end
  end

  defp identity_valid(_), do: error(:invalid)

  defp identity(stat), do: {stat.major_device, stat.minor_device, stat.inode, stat.uid}
  defp directory(spool), do: Path.join(spool._identity.root, spool._identity.id)
  defp filename(spool, file), do: Path.join(directory(spool), Atom.to_string(file))

  defp filesystem(spool, check_sizes?) do
    with :ok <- safe_absolute(spool._identity.root),
         {:ok, root} <- private_directory(spool._identity.root),
         true <- identity(root) == spool._identity.root_stat do
      case File.lstat(directory(spool)) do
        {:error, :enoent} when not check_sizes? ->
          :ok

        {:ok, %File.Stat{type: :directory, mode: mode} = stat} when band(mode, 0o777) == 0o700 ->
          with true <- identity(stat) == spool._identity.operation_stat do
            Enum.reduce_while([:payload, :index], :ok, fn file, :ok ->
              case File.lstat(filename(spool, file)) do
                {:ok, %File.Stat{type: :regular, mode: mode, size: size} = child}
                when band(mode, 0o777) == 0o600 ->
                  if identity(child) == spool._identity.files[file] and
                       (not check_sizes? or size == spool._sizes[file]),
                     do: {:cont, :ok},
                     else: {:halt, error(:integrity_failure)}

                _ ->
                  {:halt, error(:integrity_failure)}
              end
            end)
          else
            _ -> error(:integrity_failure)
          end

        _ ->
          error(:integrity_failure)
      end
    else
      _ -> error(:integrity_failure)
    end
  end

  defp cleanup(spool) do
    case File.lstat(directory(spool)) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :directory} = stat} ->
        with true <- identity(stat) == spool._identity.operation_stat,
             :ok <- remove_owned_file(spool, :payload),
             :ok <- remove_owned_file(spool, :index),
             :ok <- File.rmdir(directory(spool)) do
          :ok
        else
          _ -> error(:storage_unavailable)
        end

      _ ->
        error(:integrity_failure)
    end
  end

  defp remove_owned_file(spool, file) do
    with :ok <- safe_absolute(spool._identity.root),
         {:ok, %File.Stat{type: :directory} = parent} <- File.lstat(directory(spool)),
         true <- identity(parent) == spool._identity.operation_stat do
      case File.lstat(filename(spool, file)) do
        {:error, :enoent} ->
          :ok

        {:ok, %File.Stat{type: :regular} = stat} ->
          if identity(stat) == spool._identity.files[file],
            do: File.rm(filename(spool, file)),
            else: error(:integrity_failure)

        _ ->
          error(:integrity_failure)
      end
    else
      _ -> error(:integrity_failure)
    end
  end

  defp fail_capture(spool, code) do
    case abort(spool) do
      :ok -> error(code)
      _ -> error(:storage_unavailable)
    end
  end

  defp alive(spool) do
    now = spool._clock.()

    if is_integer(now) and now < spool._deadline and :atomics.get(spool._phase, 1) != @aborted,
      do: :ok,
      else: error(:invalid)
  end

  defp readable(spool) do
    with :ok <- identity_valid(spool),
         true <- spool.sealed? and :atomics.get(spool._phase, 1) == @sealed do
      with :ok <- alive(spool), :ok <- filesystem(spool, true) do
        :ok
      else
        _ -> fail_capture(spool, :integrity_failure)
      end
    else
      _ -> error(:invalid)
    end
  end

  defp prepare(spool, {:metadata, collection}, record) when collection in @collections do
    with :ok <- metadata_valid(spool, collection, record) do
      original =
        if collection == :versions and record["availability"] == "included",
          do: record["original_byte_size"] || 0,
          else: 0

      {:ok, :metadata, JSON.encode!(record), selected_identity(collection, record), original}
    end
  end

  defp prepare(_spool, {:note_markdown, resource, version}, bytes) do
    with :ok <- ids([resource, version]),
         true <- is_binary(bytes) and byte_size(bytes) <= 65_536 do
      {:ok, :text, bytes, {:note, resource, version}, 0}
    else
      _ -> error(:invalid)
    end
  end

  defp prepare(_spool, {:fragment_text, resource, version, ordinal, digest}, bytes) do
    with :ok <- ids([resource, version]),
         {:ok, ^digest} <- PathGuard.digest(digest),
         true <- is_integer(ordinal) and ordinal in 0..4095,
         true <- is_binary(bytes) and byte_size(bytes) <= 65_536,
         false <- String.contains?(bytes, "\r") do
      {:ok, :text, bytes, {:document, resource, version}, 0}
    else
      _ -> error(:invalid)
    end
  end

  defp prepare(_spool, {:render_descriptions, resource, version}, descriptions) do
    with :ok <- ids([resource, version]),
         {:ok, _rendered} <- NoteMarkdownSources.render("", descriptions) do
      {:ok, :render, descriptions |> json_value() |> JSON.encode!(), {:note, resource, version},
       0}
    end
  end

  defp prepare(_spool, {:binary_binding, :asset, resource, version}, binding) do
    with :ok <- ids([resource, version]),
         :ok <- binding_valid(binding),
         true <- binding["resource_id"] == resource and binding["version_id"] == version do
      {:ok, :binding, JSON.encode!(binding), {:asset, resource, version}, 0}
    else
      _ -> error(:invalid)
    end
  end

  defp prepare(_, _, _), do: error(:invalid)

  defp metadata_valid(
         spool,
         :versions,
         %{"kind" => "asset", "availability" => "included", "original_digest" => nil} = draft
       ) do
    key = {:binary_binding, :asset, draft["resource_id"], draft["version_id"]}
    # A shape-validation probe only: this value is never written or claimed as
    # an original digest. The capture draft retains nil until Task15 verifies bytes.
    with {:ok, _} <-
           KnowledgeExportManifest.record(
             :versions,
             Map.put(draft, "original_digest", String.duplicate("0", 64))
           ),
         {:ok, size} <- Map.fetch(spool._bindings, key),
         true <- size == draft["original_byte_size"] do
      :ok
    else
      _ -> error(:invalid)
    end
  end

  defp metadata_valid(_spool, collection, record) do
    case KnowledgeExportManifest.record(collection, record) do
      {:ok, %{"availability" => "metadata_only_unavailable"}} -> error(:invalid)
      {:ok, _} -> :ok
      _ -> error(:invalid)
    end
  end

  defp binding_valid(binding) when is_map(binding) and not is_struct(binding) do
    with true <- Enum.sort(Map.keys(binding)) == Enum.sort(@binding_keys),
         true <- binding["kind"] == "asset" and binding["classification"] == "private",
         true <- is_nil(binding["plaintext_sha256"]),
         :ok <-
           ids(
             Enum.map(
               ~w(resource_id version_id asset_id object_id owner_scope_id key_domain_id domain_key_version_id),
               &binding[&1]
             )
           ),
         {:ok, _} <- PathGuard.digest(binding["lookup_digest"]),
         {:ok, _} <- PathGuard.digest(binding["ciphertext_hash"]),
         true <-
           positive?(binding["object_generation"]) and positive?(binding["domain_key_generation"]),
         true <-
           is_integer(binding["plaintext_byte_size"]) and
             binding["plaintext_byte_size"] in 0..68_719_476_736,
         true <-
           is_integer(binding["ciphertext_byte_size"]) and
             binding["ciphertext_byte_size"] in 0..9_223_372_036_854_775_807 and
             binding["ciphertext_byte_size"] >= binding["plaintext_byte_size"],
         true <- binding["format_version"] == 1,
         true <- storage_reference?(binding) do
      :ok
    else
      _ -> error(:invalid)
    end
  end

  defp binding_valid(_), do: error(:invalid)
  defp positive?(number), do: is_integer(number) and number in 1..9_223_372_036_854_775_807

  defp storage_reference?(%{"storage_ref" => value} = binding)
       when is_binary(value) and byte_size(value) <= 4096 do
    digest = binding["lookup_digest"]

    canonical =
      "objects/#{binding["owner_scope_id"]}/#{binding["key_domain_id"]}/hmac-sha256/#{binary_part(digest, 0, 2)}/#{digest}"

    value == binding["object_id"] or value == canonical
  end

  defp storage_reference?(_), do: false

  defp ids(values) do
    if Enum.all?(values, &match?({:ok, _}, PathGuard.uuid(&1))), do: :ok, else: error(:invalid)
  end

  defp json_value(%SourceLocator{} = locator), do: SourceLocator.to_map(locator)
  defp json_value(%{__struct__: _} = value), do: value |> Map.from_struct() |> json_value()

  defp json_value(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, json_value(item)} end)

  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)

  defp json_value(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp json_value(value), do: value

  defp selected_identity(:resources, record),
    do: {record["kind"], record["id"], record["current_version_id"]}

  defp selected_identity(:versions, record),
    do: {record["kind"], record["resource_id"], record["version_id"]}

  defp selected_identity(:fragments, record),
    do: {:document, record["resource_id"], record["version_id"]}

  defp selected_identity(_, _), do: nil

  defp retained_records(_spool, {:metadata, :versions}, record) do
    2 +
      if(
        record["kind"] == "asset" and record["availability"] == "included" and
          is_nil(record["original_digest"]),
        do: 1,
        else: 0
      )
  end

  defp retained_records(_spool, {:binary_binding, :asset, _, _}, _), do: 2

  defp retained_records(spool, {:fragment_text, resource, version, ordinal, _}, _) do
    document = Map.get(spool._documents, {resource, version})

    1 + if(is_nil(document), do: 1, else: 0) +
      if(is_nil(document) or not Map.has_key?(document.ordinals, ordinal), do: 1, else: 0)
  end

  defp retained_records(_, _, _), do: 1

  defp admit(spool, selected, original, records) do
    selected = normalize_selected(selected)
    new? = not is_nil(selected) and not MapSet.member?(spool._selected, selected)

    accounting = %{
      spool.accounting
      | selected_keys: spool.accounting.selected_keys + if(new?, do: 1, else: 0),
        original_bytes: spool.accounting.original_bytes + original,
        metadata_records: spool.accounting.metadata_records + records + if(new?, do: 1, else: 0)
    }

    with :ok <- budget(accounting) do
      indexes = if new?, do: MapSet.put(spool._selected, selected), else: spool._selected
      {:ok, %{spool | accounting: accounting, _selected: indexes}}
    end
  end

  defp normalize_selected({kind, resource, version}) when is_binary(kind),
    do: {kind, resource, version}

  defp normalize_selected({kind, resource, version}) when is_atom(kind),
    do: {Atom.to_string(kind), resource, version}

  defp normalize_selected(nil), do: nil

  defp budget(accounting) do
    limits = KnowledgeExport.limits()

    if Enum.all?(
         [:spool_bytes, :metadata_records, :selected_keys, :original_bytes],
         &(is_integer(accounting[&1]) and accounting[&1] >= 0)
       ) and
         accounting.spool_bytes <= limits.metadata_bytes and
         accounting.metadata_records <= limits.metadata_records and
         accounting.selected_keys <= limits.selected_keys and
         accounting.original_bytes <= limits.file_bytes,
       do: :ok,
       else: error(:invalid)
  end

  defp journal_payload(spool, selector, kind, payload) do
    with :ok <- text_admission(spool, selector, kind, payload) do
      pieces = if kind == :metadata, do: [payload], else: chunks(payload)

      Enum.reduce_while(pieces, {:ok, spool, []}, fn piece, {:ok, current, frames} ->
        case journal_piece(current, selector, piece) do
          {:ok, next, frame} -> {:cont, {:ok, next, [frame | frames]}}
          failure -> {:halt, failure}
        end
      end)
      |> case do
        {:ok, next, frames} -> {:ok, next, Enum.reverse(frames)}
        failure -> failure
      end
    end
  end

  defp journal_piece(spool, selector, payload) do
    offset = spool._sizes.payload
    digest = :crypto.hash(:sha256, payload)

    index_payload =
      JSON.encode!(%{
        "selector" => selector |> Tuple.to_list() |> json_value(),
        "offset" => offset,
        "length" => byte_size(payload),
        "sha256" => hex(digest)
      })

    bytes = byte_size(payload) + byte_size(index_payload) + 2 * @frame_bytes
    # Data and on-disk index records, plus their retained reference entries.
    accounting = %{
      spool.accounting
      | spool_bytes: spool.accounting.spool_bytes + bytes,
        metadata_records: spool.accounting.metadata_records + 4
    }

    with :ok <- budget(accounting),
         {:ok, spool, data_ref} <- write_frame(spool, :payload, payload),
         {:ok, spool, index_ref} <- write_frame(spool, :index, index_payload) do
      {:ok, %{spool | accounting: accounting}, Map.put(data_ref, :index, index_ref)}
    end
  end

  defp chunks(<<>>), do: [""]
  defp chunks(bytes), do: chunks(bytes, [])
  defp chunks(<<>>, result), do: Enum.reverse(result)

  defp chunks(bytes, result) do
    size = min(byte_size(bytes), 65_536)
    <<piece::binary-size(size), rest::binary>> = bytes
    chunks(rest, [piece | result])
  end

  defp write_frame(spool, file, payload) do
    hash = :crypto.hash(:sha256, payload)
    offset = spool._sizes[file]
    header = <<byte_size(payload)::unsigned-big-64, hash::binary-size(32)>>

    with :ok <- filesystem(spool, true),
         {:ok, device} <- File.open(filename(spool, file), [:append, :binary]) do
      result =
        try do
          with :ok <- bounded_write(spool, device, header),
               :ok <- bounded_write(spool, device, payload) do
            :ok
          end
        after
          File.close(device)
        end

      with :ok <- result do
        sizes = Map.put(spool._sizes, file, offset + @frame_bytes + byte_size(payload))
        {:ok, %{spool | _sizes: sizes}, %{offset: offset, length: byte_size(payload), hash: hash}}
      end
    end
  end

  defp bounded_write(_spool, _device, <<>>), do: :ok

  defp bounded_write(spool, device, bytes) do
    size = min(byte_size(bytes), 65_536)
    <<piece::binary-size(size), rest::binary>> = bytes

    with :ok <- alive(spool),
         :ok <- spool._write.(device, piece) do
      bounded_write(spool, device, rest)
    else
      _ -> error(:storage_unavailable)
    end
  end

  defp text_admission(spool, selector, :text, payload) do
    old = Map.get(spool._texts, selector, %{byte_size: 0, carry: ""})
    maximum = if elem(selector, 0) == :note_markdown, do: 1_048_576, else: 65_536

    with true <- old.byte_size + byte_size(payload) <= maximum,
         {:ok, _carry} <- utf8(old.carry <> payload),
         :ok <- fragment_admission(spool, selector, payload) do
      :ok
    else
      _ -> error(:invalid)
    end
  end

  defp text_admission(_, _, _, _), do: :ok

  defp utf8(bytes) do
    if :binary.match(bytes, <<0>>) == :nomatch do
      case :unicode.characters_to_binary(bytes, :utf8, :utf8) do
        complete when is_binary(complete) -> {:ok, ""}
        {:incomplete, _complete, carry} when byte_size(carry) <= 3 -> {:ok, carry}
        _ -> error(:invalid)
      end
    else
      error(:invalid)
    end
  end

  defp fragment_admission(
         spool,
         {:fragment_text, resource, version, ordinal, _} = selector,
         payload
       ) do
    document = Map.get(spool._documents, {resource, version}, %{ordinals: %{}, bytes: 0})
    existing = Map.get(document.ordinals, ordinal)

    if (is_nil(existing) or existing == selector) and
         document.bytes + byte_size(payload) <= 16_777_216,
       do: :ok,
       else: error(:invalid)
  end

  defp fragment_admission(_, _, _), do: :ok

  defp install(spool, {:metadata, collection}, :metadata, payload, [frame]) do
    record = JSON.decode!(payload)
    key = record_key(collection, record)
    collections = Map.update!(spool._collections, collection, &Map.put(&1, key, frame))
    spool = %{spool | _collections: collections}

    spool =
      if collection == :versions do
        version = Map.take(record, ~w(kind state availability extracted_digest))
        spool = %{spool | _versions: Map.put(spool._versions, key, version)}

        if record["kind"] == "asset" and record["availability"] == "included" and
             is_nil(record["original_digest"]),
           do: %{spool | _drafts: Map.put(spool._drafts, key, record["original_byte_size"])},
           else: spool
      else
        spool
      end

    {:ok, spool}
  end

  defp install(spool, selector, kind, payload, frames) do
    empty = %{byte_size: 0, hash: :crypto.hash_init(:sha256), carry: "", frames: []}
    old = if kind == :text, do: Map.get(spool._texts, selector, empty), else: empty
    {:ok, carry} = if kind == :text, do: utf8(old.carry <> payload), else: {:ok, ""}

    entry = %{
      old
      | byte_size: old.byte_size + byte_size(payload),
        hash: :crypto.hash_update(old.hash, payload),
        carry: carry,
        frames: old.frames ++ frames
    }

    spool = %{spool | _texts: Map.put(spool._texts, selector, entry)}

    spool =
      case selector do
        {:fragment_text, resource, version, ordinal, _} ->
          document = Map.get(spool._documents, {resource, version}, %{ordinals: %{}, bytes: 0})

          document = %{
            document
            | ordinals: Map.put(document.ordinals, ordinal, selector),
              bytes: document.bytes + byte_size(payload)
          }

          %{spool | _documents: Map.put(spool._documents, {resource, version}, document)}

        {:binary_binding, :asset, _, _} ->
          binding = JSON.decode!(payload)
          %{spool | _bindings: Map.put(spool._bindings, selector, binding["plaintext_byte_size"])}

        _ ->
          spool
      end

    {:ok, spool}
  end

  defp record_key(collection, record) when collection in [:resources, :tags, :relationships],
    do: record["id"]

  defp record_key(:versions, record), do: {record["resource_id"], record["version_id"]}

  defp record_key(:fragments, record),
    do: {record["resource_id"], record["version_id"], record["ordinal"], record["id"]}

  defp record_key(:tag_assignments, record), do: {record["resource_id"], record["tag_id"]}

  defp record_key(collection, record) when collection in [:attachments, :citations],
    do: {record["note_resource_id"], record["note_version_id"], record["ordinal"], record["id"]}

  defp complete_texts(spool) do
    Enum.reduce_while(spool._texts, :ok, fn {_selector, entry}, :ok ->
      with true <- entry.carry == "",
           {:ok, hash} <- hash_frames(spool, entry.frames, :crypto.hash_init(:sha256)),
           true <- :crypto.hash_final(hash) == :crypto.hash_final(entry.hash) do
        {:cont, :ok}
      else
        _ -> {:halt, error(:integrity_failure)}
      end
    end)
  end

  defp complete_documents(spool) do
    with true <-
           Enum.all?(spool._documents, fn {_key, doc} ->
             count = map_size(doc.ordinals)

             count in 1..4096 and
               Enum.sort(Map.keys(doc.ordinals)) == Enum.to_list(0..(count - 1))
           end) do
      Enum.reduce_while(spool._versions, :ok, fn {key, version}, :ok ->
        case version do
          %{"kind" => "document", "availability" => "included", "state" => "ready"} ->
            with {:ok, doc} <- Map.fetch(spool._documents, key),
                 true <- doc.bytes in 1..16_777_216,
                 {:ok, hash} <- document_hash(spool, doc),
                 true <- hex(hash) == version["extracted_digest"] do
              {:cont, :ok}
            else
              _ -> {:halt, error(:integrity_failure)}
            end

          %{"kind" => "document", "availability" => "included"} ->
            if Map.has_key?(spool._documents, key),
              do: {:halt, error(:integrity_failure)},
              else: {:cont, :ok}

          _ ->
            {:cont, :ok}
        end
      end)
    else
      _ -> error(:integrity_failure)
    end
  end

  defp document_hash(spool, document) do
    document.ordinals
    |> Enum.sort()
    |> Enum.reduce_while({:ok, :crypto.hash_init(:sha256)}, fn {_ordinal, selector},
                                                               {:ok, hash} ->
      entry = Map.fetch!(spool._texts, selector)

      case hash_frames(spool, entry.frames, hash) do
        {:ok, next} -> {:cont, {:ok, next}}
        failure -> {:halt, failure}
      end
    end)
    |> case do
      {:ok, hash} -> {:ok, :crypto.hash_final(hash)}
      failure -> failure
    end
  end

  defp hash_frames(spool, frames, hash) do
    Enum.reduce_while(frames, {:ok, hash}, fn frame, {:ok, hash} ->
      case checked_payload(spool, frame) do
        {:ok, bytes} -> {:cont, {:ok, :crypto.hash_update(hash, bytes)}}
        failure -> {:halt, failure}
      end
    end)
  end

  defp complete_drafts(spool) do
    if Enum.all?(spool._drafts, fn {{resource, version}, size} ->
         Map.get(spool._bindings, {:binary_binding, :asset, resource, version}) == size
       end),
       do: :ok,
       else: error(:integrity_failure)
  end

  defp sealed_refs(spool) do
    Enum.reduce(spool._texts, {%{}, %{}, %{}}, fn {selector, entry}, {texts, renders, bindings} ->
      reference = %{
        capture_id: spool.capture_id,
        selector: selector,
        offset: hd(entry.frames).offset + @frame_bytes,
        byte_size: entry.byte_size,
        sha256: entry.hash |> :crypto.hash_final() |> hex()
      }

      case elem(selector, 0) do
        :render_descriptions -> {texts, Map.put(renders, selector, reference), bindings}
        :binary_binding -> {texts, renders, Map.put(bindings, selector, reference)}
        _ -> {Map.put(texts, selector, reference), renders, bindings}
      end
    end)
  end

  defp check_cursor(spool, cursor) when is_map(cursor) and not is_struct(cursor) do
    keys = Enum.sort(Map.keys(cursor))
    initial? = keys == Enum.sort([:capture_id, :collection, :after]) and is_nil(cursor[:after])

    continued? =
      keys == Enum.sort([:capture_id, :collection, :after, :proof]) and not is_nil(cursor[:after])

    with true <- cursor[:capture_id] == spool.capture_id and cursor[:collection] in @collections,
         true <-
           initial? or
             (continued? and
                cursor[:proof] == cursor_proof(spool, cursor.collection, cursor.after)),
         true <-
           is_nil(cursor.after) or
             Map.has_key?(spool._collections[cursor.collection], cursor.after) do
      {:ok, cursor.collection, cursor.after}
    else
      _ -> error(:invalid)
    end
  end

  defp check_cursor(_, _), do: error(:invalid)

  defp next_cursor(spool, collection, key),
    do: %{
      capture_id: spool.capture_id,
      collection: collection,
      after: key,
      proof: cursor_proof(spool, collection, key)
    }

  defp cursor_proof(spool, collection, key) do
    key = if is_tuple(key), do: Tuple.to_list(key), else: key

    :crypto.mac(
      :hmac,
      :sha256,
      spool._secret,
      JSON.encode!([spool.capture_id, Atom.to_string(collection), key])
    )
    |> hex()
  end

  defp read_records(spool, indexes, keys) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, records} ->
      case checked_payload(spool, Map.fetch!(indexes, key)) do
        {:ok, bytes} -> {:cont, {:ok, [JSON.decode!(bytes) | records]}}
        failure -> {:halt, failure}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      failure -> failure
    end
  end

  defp exact_reference(spool, reference) do
    selector = Map.get(reference, :selector)

    expected =
      Map.get(spool.text_refs, selector) || Map.get(spool.render_refs, selector) ||
        Map.get(spool.binary_refs, selector)

    if not is_nil(expected) and expected === reference,
      do: Map.fetch(spool._texts, selector),
      else: error(:invalid)
  end

  defp read_range(spool, frames, start, size) do
    Enum.reduce_while(frames, {:ok, [], 0}, fn frame, {:ok, pieces, position} ->
      frame_end = position + frame.length
      relevant? = (size == 0 and position == 0) or (position < start + size and frame_end > start)

      if relevant? do
        case checked_payload(spool, frame) do
          {:ok, bytes} ->
            from = max(start - position, 0)
            length = max(0, min(frame_end, start + size) - max(position, start))
            piece = binary_part(bytes, from, length)
            {:cont, {:ok, [piece | pieces], frame_end}}

          failure ->
            {:halt, failure}
        end
      else
        {:cont, {:ok, pieces, frame_end}}
      end
    end)
    |> case do
      {:ok, pieces, _} ->
        bytes = pieces |> Enum.reverse() |> IO.iodata_to_binary()
        if byte_size(bytes) == size, do: {:ok, bytes}, else: error(:integrity_failure)

      failure ->
        failure
    end
  end

  defp checked_metadata_payload(spool, collection, frame) do
    expected_index = %{
      "selector" => ["metadata", Atom.to_string(collection)],
      "offset" => frame.offset,
      "length" => frame.length,
      "sha256" => hex(frame.hash)
    }

    with {:ok, index_bytes} <- read_frame(spool, :index, frame.index),
         true <- JSON.decode!(index_bytes) === expected_index,
         {:ok, bytes} <- read_frame(spool, :payload, frame) do
      {:ok, bytes}
    else
      _ -> error(:integrity_failure)
    end
  end

  defp checked_payload(spool, frame) do
    with {:ok, _index} <- read_frame(spool, :index, frame.index),
         {:ok, bytes} <- read_frame(spool, :payload, frame) do
      {:ok, bytes}
    end
  end

  defp read_frame(spool, file, frame) do
    with :ok <- alive(spool),
         :ok <- filesystem(spool, true),
         {:ok, device} <- File.open(filename(spool, file), [:read, :binary]) do
      try do
        with {:ok, bytes} <- :file.pread(device, frame.offset, @frame_bytes + frame.length),
             <<length::unsigned-big-64, hash::binary-size(32), payload::binary>> <- bytes,
             true <- length == frame.length and byte_size(payload) == length,
             true <- hash == frame.hash and :crypto.hash(:sha256, payload) == hash do
          {:ok, payload}
        else
          _ -> error(:integrity_failure)
        end
      after
        File.close(device)
      end
    end
  end

  defp hex(bytes), do: bytes |> Base.encode16(case: :lower) |> :binary.copy()
  defp error(code), do: {:error, Error.new(code)}
end
