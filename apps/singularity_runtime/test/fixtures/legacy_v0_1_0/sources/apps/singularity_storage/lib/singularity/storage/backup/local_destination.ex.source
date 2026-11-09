defmodule Singularity.Storage.Backup.LocalDestination do
  @moduledoc """
  Resolves persisted backup references beneath a configured local backup root.

  The context requires an existing absolute `:backup_root` directory.
  Persisted references are canonical, root-relative paths. Filesystem callbacks
  re-check containment and symlinks immediately before opening or mutating a
  path. Writer callbacks carry the opened partial's opaque file identity through
  publication and cleanup. Publication uses a same-filesystem hard link so an
  existing final is never replaced.
  """

  alias Singularity.Core.Error
  alias Singularity.Storage.Local.PathGuard
  alias Singularity.Storage.Local.Sync

  @read_size 64 * 1024

  @spec valid_ref?(term()) :: boolean()
  def valid_ref?(reference) when is_binary(reference) and reference != "" do
    valid_path_syntax?(reference)
  end

  def valid_ref?(_reference), do: false

  @spec normalize(map(), term()) :: {:ok, binary()} | {:error, Error.t()}
  def normalize(context, operator_path) do
    with {:ok, root} <- backup_root(context),
         true <- valid_path_syntax?(operator_path),
         path = Path.expand(operator_path, root),
         {:ok, relative} <- contained_relative(root, path),
         :ok <- PathGuard.assert_safe_path(root, path),
         :ok <- final_absent_or_regular(path) do
      {:ok, relative}
    else
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> invalid()
    end
  end

  @spec writer_destination(map(), term()) :: {:ok, map()} | {:error, Error.t()}
  def writer_destination(context, persisted_ref) do
    with {:ok, root, path} <- persisted_path(context, persisted_ref),
         :ok <- final_absent_or_regular(path),
         :ok <- ensure_parent(context, root, path),
         :ok <- PathGuard.assert_safe_path(root, path),
         :ok <- final_absent_or_regular(path) do
      {:ok,
       %{
         destination_ref: persisted_ref,
         file_system: writer_file_system(context, root, path),
         partial_path: &manifest_partial_path(path, &1),
         path: path
       }}
    end
  end

  @spec reader_source(map(), term()) :: {:ok, map()} | {:error, Error.t()}
  def reader_source(context, persisted_ref) do
    with {:ok, root, path} <- persisted_path(context, persisted_ref),
         :ok <- require_regular(path) do
      {:ok, %{file_system: reader_file_system(root, path), path: path}}
    end
  end

  @spec probe(map(), term()) :: {:ok, :absent | {:final, map()}} | {:error, Error.t()}
  def probe(context, persisted_ref) do
    with {:ok, root, path} <- persisted_path(context, persisted_ref) do
      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular}} ->
          {:ok, {:final, %{file_system: reader_file_system(root, path), path: path}}}

        {:error, :enoent} ->
          {:ok, :absent}

        {:ok, _other} ->
          invalid()

        {:error, reason} ->
          unavailable(:probe, reason)
      end
    end
  end

  @spec probe(map(), term(), term()) ::
          {:ok, :absent | :partial | {:final, map()}} | {:error, Error.t()}
  def probe(context, persisted_ref, manifest_id) do
    with {:ok, root, path} <- persisted_path(context, persisted_ref),
         {:ok, manifest_id} <- PathGuard.uuid(manifest_id) do
      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular}} ->
          {:ok, {:final, %{file_system: reader_file_system(root, path), path: path}}}

        {:error, :enoent} ->
          probe_partial(root, manifest_partial_path(path, manifest_id))

        {:ok, _other} ->
          invalid()

        {:error, reason} ->
          unavailable(:probe, reason)
      end
    end
  end

  @spec cleanup_partial(map(), term(), term()) :: :ok | {:error, Error.t()}
  def cleanup_partial(context, persisted_ref, manifest_id) do
    with {:ok, root, path} <- persisted_path(context, persisted_ref),
         {:ok, manifest_id} <- PathGuard.uuid(manifest_id) do
      guarded_remove_partial(
        root,
        path,
        manifest_partial_path(path, manifest_id),
        sync_options(context)
      )
    end
  end

  defp backup_root(%{backup_root: root}) when is_binary(root) and root != "" do
    if Path.type(root) == :absolute and not String.contains?(root, <<0>>) do
      root = Path.expand(root)

      with :ok <- PathGuard.assert_safe_path(root, root),
           {:ok, %File.Stat{type: :directory}} <- File.lstat(root) do
        {:ok, root}
      else
        {:ok, _other} -> invalid()
        {:error, :enoent} -> invalid()
        {:error, %Error{} = error} -> {:error, error}
        {:error, reason} -> unavailable(:inspect_backup_root, reason)
      end
    else
      invalid()
    end
  end

  defp backup_root(_context), do: invalid()

  defp persisted_path(context, persisted_ref) do
    with {:ok, root} <- backup_root(context),
         true <- canonical_persisted_ref?(persisted_ref),
         path = Path.join(root, persisted_ref),
         :ok <- PathGuard.assert_safe_path(root, path) do
      {:ok, root, path}
    else
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> invalid()
    end
  end

  defp canonical_persisted_ref?(reference) do
    valid_path_syntax?(reference) and Path.type(reference) == :relative and
      reference == Path.join(Path.split(reference))
  end

  defp valid_path_syntax?(reference) when is_binary(reference) and reference != "" do
    not String.contains?(reference, <<0>>) and
      not String.contains?(reference, "\\") and
      Path.split(reference) != [] and
      Enum.all?(Path.split(reference), &(&1 not in [".", ".."]))
  end

  defp valid_path_syntax?(_reference), do: false

  defp contained_relative(root, path) do
    relative = Path.relative_to(path, root)
    segments = Path.split(relative)

    if relative != "." and Path.type(relative) == :relative and ".." not in segments do
      {:ok, Path.join(segments)}
    else
      invalid()
    end
  end

  defp final_absent_or_regular(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:error, :enoent} -> :ok
      {:ok, _other} -> invalid()
      {:error, reason} -> unavailable(:inspect_final, reason)
    end
  end

  defp require_regular(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:error, :enoent} -> {:error, Error.new(:not_found)}
      {:ok, _other} -> invalid()
      {:error, reason} -> unavailable(:inspect_final, reason)
    end
  end

  defp ensure_parent(context, root, path) do
    directory = Path.dirname(path)

    with :ok <- require_existing_root(root),
         :ok <- create_descendant_directories(root, Path.relative_to(directory, root)),
         :ok <- PathGuard.assert_safe_path(root, directory),
         :ok <- sync_directory_chain(root, directory, sync_options(context)) do
      :ok
    end
  end

  defp require_existing_root(root) do
    with :ok <- PathGuard.assert_safe_path(root, root),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(root) do
      :ok
    else
      {:ok, _other} -> invalid()
      {:error, :enoent} -> invalid()
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> unavailable(:inspect_backup_root, reason)
    end
  end

  defp create_descendant_directories(_root, "."), do: :ok

  defp create_descendant_directories(root, relative) do
    relative
    |> Path.split()
    |> Enum.reduce_while(root, fn segment, parent ->
      path = Path.join(parent, segment)

      result =
        with :ok <- PathGuard.assert_safe_path(root, path) do
          case File.mkdir(path) do
            :ok -> :ok
            {:error, :eexist} -> require_existing_directory(path)
            {:error, reason} -> unavailable(:create_backup_directory, reason)
          end
        end

      case result do
        :ok -> {:cont, path}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:error, %Error{} = error} -> {:error, error}
      _path -> :ok
    end
  end

  defp require_existing_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, _other} -> invalid()
      {:error, reason} -> unavailable(:inspect_backup_directory, reason)
    end
  end

  defp sync_directory_chain(root, directory, options) do
    root
    |> directory_chain(directory)
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case Sync.directory(path, options) do
        :ok -> {:cont, :ok}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp directory_chain(root, root), do: [root]

  defp directory_chain(root, directory),
    do: [directory | directory_chain(root, Path.dirname(directory))]

  defp manifest_partial_path(path, manifest_id), do: path <> ".partial." <> manifest_id

  defp probe_partial(root, partial_path) do
    with :ok <- PathGuard.assert_safe_path(root, partial_path) do
      case File.lstat(partial_path) do
        {:ok, %File.Stat{type: :regular}} -> {:ok, :partial}
        {:error, :enoent} -> {:ok, :absent}
        {:ok, _other} -> invalid()
        {:error, reason} -> unavailable(:probe_partial, reason)
      end
    end
  end

  defp writer_file_system(context, root, final_path) do
    options = sync_options(context)

    %{
      close: &:file.close/1,
      exists?: &guarded_exists?(root, final_path, &1),
      open: &guarded_open(root, final_path, &1, &2, options),
      publish: &guarded_publish(root, final_path, &1, &2, &3, options),
      remove_owned: &guarded_remove_owned(root, final_path, &1, &2, options),
      sync: &:file.sync/1,
      write: &:file.write/2
    }
  end

  defp reader_file_system(root, final_path),
    do: %{
      close_snapshot: &close_snapshot/1,
      open_snapshot: &guarded_open_snapshot(root, final_path, &1, &2),
      pread: &pread_snapshot/3,
      read: &guarded_read(root, final_path, &1, &2),
      read_prefix: &guarded_read_prefix(root, final_path, &1, &2),
      verify_snapshot: &verify_snapshot/2
    }

  defp guarded_exists?(root, final_path, path) do
    with :ok <- allowed_path(final_path, path),
         :ok <- PathGuard.assert_safe_path(root, path) do
      case File.lstat(path) do
        {:ok, _stat} -> true
        {:error, :enoent} -> false
        {:error, reason} -> unavailable(:inspect_path, reason)
      end
    end
  end

  defp guarded_open(root, final_path, path, modes, options) do
    with :ok <- allowed_partial(final_path, path),
         true <- Enum.sort(modes) == Enum.sort([:write, :binary, :exclusive]),
         :ok <- PathGuard.assert_safe_path(root, path),
         {:error, :enoent} <- File.lstat(path),
         {:ok, device} <-
           :file.open(String.to_charlist(path), [
             :write,
             :binary,
             :raw,
             :exclusive
           ]) do
      verify_opened_partial(root, path, device, options)
    else
      {:error, %Error{} = error} -> {:error, error}
      false -> invalid()
      {:ok, _existing} -> {:error, Error.new(:conflict)}
      {:error, reason} -> unavailable(:open_partial, reason)
    end
  end

  defp verify_opened_partial(root, path, device, options) do
    case descriptor_identity(device) do
      {:ok, ownership, 0o600} ->
        case regular_identity(path) do
          {:ok, ^ownership} ->
            {:ok, device, ownership}

          {:ok, _replacement} ->
            open_verification_failure(
              root,
              path,
              device,
              ownership,
              Error.new(:invalid),
              options
            )

          {:error, %Error{} = error} ->
            open_verification_failure(root, path, device, ownership, error, options)
        end

      {:ok, _ownership, _unsafe_mode} ->
        close_unsafe_partial(device, Error.new(:invalid))

      {:error, %Error{} = error} ->
        open_verification_failure(root, path, device, nil, error, options)
    end
  end

  defp close_unsafe_partial(device, primary) do
    case close_opened_device(device) do
      :ok ->
        {:error, primary}

      close_result ->
        {:error,
         Error.new(:storage_unavailable,
           details: %{
             close_error: result_code(close_result),
             operation: :open_cleanup,
             partial_state: :preserved,
             primary_error: primary.code
           },
           retryable?: true
         )}
    end
  end

  defp open_verification_failure(root, path, device, ownership, primary, options) do
    cleanup_result =
      case ownership do
        nil -> {:error, storage_error(:remove_owned, :ownership_unavailable)}
        ownership -> remove_owned_path(root, path, ownership, options)
      end

    close_result = close_opened_device(device)

    case {close_result, cleanup_result} do
      {:ok, :ok} ->
        {:error, primary}

      {close_result, cleanup_result} ->
        open_cleanup_failure(primary, close_result, cleanup_result)
    end
  end

  defp close_opened_device(device) do
    case :file.close(device) do
      :ok -> :ok
      {:error, _reason} -> {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  defp open_cleanup_failure(primary, close_result, cleanup_result) do
    {:error,
     Error.new(:storage_unavailable,
       details: %{
         cleanup_error: result_code(cleanup_result),
         close_error: result_code(close_result),
         operation: :open_cleanup,
         primary_error: primary.code
       },
       retryable?: true
     )}
  end

  defp guarded_read(root, final_path, final_path, max_bytes)
       when is_integer(max_bytes) and max_bytes >= 0 do
    with :ok <- PathGuard.assert_safe_path(root, final_path),
         {:ok, %File.Stat{type: :regular} = before_stat} <- File.lstat(final_path),
         true <- before_stat.size <= max_bytes,
         {:ok, device} <- :file.open(String.to_charlist(final_path), [:read, :binary, :raw]) do
      read_verified(device, final_path, before_stat, max_bytes)
    else
      {:error, %Error{} = error} -> {:error, error}
      {:ok, _other} -> invalid()
      false -> {:error, :max_bytes_exceeded}
      {:error, :enoent} -> {:error, Error.new(:not_found)}
      {:error, reason} -> unavailable(:read_final, reason)
    end
  end

  defp guarded_read(_root, _final_path, _other_path, _max_bytes), do: invalid()

  defp guarded_read_prefix(root, final_path, final_path, max_bytes)
       when is_integer(max_bytes) and max_bytes >= 0 do
    with :ok <- PathGuard.assert_safe_path(root, final_path),
         {:ok, %File.Stat{type: :regular} = before_stat} <- File.lstat(final_path),
         {:ok, device} <- :file.open(String.to_charlist(final_path), [:read, :binary, :raw]) do
      read_prefix_verified(device, final_path, before_stat, max_bytes)
    else
      {:error, %Error{} = error} -> {:error, error}
      {:ok, _other} -> invalid()
      {:error, :enoent} -> {:error, Error.new(:not_found)}
      {:error, reason} -> unavailable(:read_final, reason)
    end
  end

  defp guarded_read_prefix(_root, _final_path, _other_path, _max_bytes), do: invalid()

  defp guarded_open_snapshot(root, final_path, final_path, max_bytes)
       when is_integer(max_bytes) and max_bytes >= 0 do
    with :ok <- PathGuard.assert_safe_path(root, final_path),
         {:ok, %File.Stat{type: :regular} = before_stat} <- File.lstat(final_path),
         :ok <- size_within_limit(before_stat.size, max_bytes),
         {:ok, device} <- :file.open(String.to_charlist(final_path), [:read, :binary, :raw]) do
      verify_opened_snapshot(final_path, device, before_stat, max_bytes)
    else
      {:error, %Error{} = error} -> {:error, error}
      {:ok, _other} -> invalid()
      {:error, :max_bytes_exceeded} = error -> error
      {:error, :enoent} -> {:error, Error.new(:not_found)}
      {:error, reason} -> unavailable(:open_snapshot, reason)
    end
  end

  defp guarded_open_snapshot(_root, _final_path, _other_path, _max_bytes), do: invalid()

  defp verify_opened_snapshot(path, device, before_stat, max_bytes) do
    result =
      with {:ok, descriptor_stat} <- :file.read_file_info(device),
           {:ok, %File.Stat{type: :regular} = after_stat} <- File.lstat(path),
           true <- same_file?(before_stat, descriptor_stat),
           true <- same_file?(after_stat, descriptor_stat),
           :ok <- descriptor_within_limit(descriptor_stat, max_bytes),
           {:ok, identity, _mode} <- descriptor_identity(device),
           {:ok, size} <- descriptor_size(descriptor_stat),
           {:ok, content_sha256} <- snapshot_content_sha256(device, size),
           :ok <- verify_descriptor(device, identity, size) do
        {:ok, %{content_sha256: content_sha256, device: device, identity: identity, size: size},
         %{identity: identity, size: size}}
      else
        false -> invalid()
        {:ok, _other} -> invalid()
        {:error, %Error{} = error} -> {:error, error}
        {:error, :max_bytes_exceeded} = error -> error
        {:error, reason} -> unavailable(:verify_snapshot, reason)
      end

    case result do
      {:ok, _snapshot, _metadata} = ok ->
        ok

      error ->
        _ = :file.close(device)
        error
    end
  end

  defp pread_snapshot(
         %{device: device, identity: identity, size: size},
         offset,
         count
       )
       when is_integer(offset) and offset >= 0 and is_integer(count) and count >= 0 and
              offset <= size do
    with :ok <- verify_descriptor(device, identity, size) do
      case :file.pread(device, offset, count) do
        {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= count -> {:ok, bytes}
        :eof -> :eof
        {:error, reason} -> unavailable(:pread_snapshot, reason)
        _invalid -> invalid()
      end
    end
  end

  defp pread_snapshot(_snapshot, _offset, _count), do: invalid()

  defp verify_snapshot(
         %{content_sha256: content_sha256, device: device, identity: identity, size: size},
         expected_size
       )
       when size == expected_size do
    with :ok <- verify_descriptor(device, identity, size),
         {:ok, ^content_sha256} <- snapshot_content_sha256(device, size),
         :ok <- verify_descriptor(device, identity, size) do
      :ok
    else
      {:ok, _mismatch} -> invalid()
      {:error, %Error{}} = error -> error
      _invalid -> invalid()
    end
  end

  defp verify_snapshot(_snapshot, _expected_size), do: invalid()

  defp verify_descriptor(device, identity, size) do
    with {:ok, descriptor_stat} <- :file.read_file_info(device),
         {:ok, ^identity, _mode} <- descriptor_identity_from_stat(descriptor_stat),
         {:ok, ^size} <- descriptor_size(descriptor_stat) do
      :ok
    else
      {:ok, _mismatch} -> invalid()
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> unavailable(:verify_snapshot, reason)
    end
  end

  defp snapshot_content_sha256(device, size) when is_integer(size) and size >= 0 do
    snapshot_content_sha256(device, 0, size, :crypto.hash_init(:sha256))
  end

  defp snapshot_content_sha256(_device, _size), do: invalid()

  defp snapshot_content_sha256(_device, offset, offset, hash),
    do: {:ok, :crypto.hash_final(hash)}

  defp snapshot_content_sha256(device, offset, size, hash) when offset < size do
    count = min(@read_size, size - offset)

    case :file.pread(device, offset, count) do
      {:ok, bytes} when is_binary(bytes) and bytes != "" and byte_size(bytes) <= count ->
        snapshot_content_sha256(
          device,
          offset + byte_size(bytes),
          size,
          :crypto.hash_update(hash, bytes)
        )

      {:error, reason} ->
        unavailable(:verify_snapshot, reason)

      _invalid ->
        invalid()
    end
  end

  defp close_snapshot(%{device: device}) do
    case :file.close(device) do
      :ok -> :ok
      {:error, reason} -> unavailable(:close_snapshot, reason)
    end
  end

  defp close_snapshot(_snapshot), do: invalid()

  defp read_verified(device, path, before_stat, max_bytes) do
    verification =
      with {:ok, descriptor_stat} <- :file.read_file_info(device),
           {:ok, %File.Stat{type: :regular} = after_stat} <- File.lstat(path),
           true <- same_file?(before_stat, descriptor_stat),
           true <- same_file?(after_stat, descriptor_stat),
           :ok <- descriptor_within_limit(descriptor_stat, max_bytes),
           :ok <- size_within_limit(after_stat.size, max_bytes) do
        :ok
      else
        false -> invalid()
        {:ok, _other} -> invalid()
        {:error, %Error{} = error} -> {:error, error}
        {:error, reason} -> unavailable(:verify_final, reason)
      end

    case verification do
      :ok ->
        read_all_and_close(device, [], max_bytes)

      {:error, %Error{} = error} ->
        _ = :file.close(device)
        {:error, error}

      {:error, :max_bytes_exceeded} = error ->
        _ = :file.close(device)
        error
    end
  end

  defp read_prefix_verified(device, path, before_stat, max_bytes) do
    verification =
      with {:ok, descriptor_stat} <- :file.read_file_info(device),
           {:ok, %File.Stat{type: :regular} = after_stat} <- File.lstat(path),
           true <- same_file?(before_stat, descriptor_stat),
           true <- same_file?(after_stat, descriptor_stat) do
        :ok
      else
        false -> invalid()
        {:ok, _other} -> invalid()
        {:error, %Error{} = error} -> {:error, error}
        {:error, reason} -> unavailable(:verify_final, reason)
      end

    case verification do
      :ok ->
        read_prefix_and_close(device, max_bytes)

      {:error, %Error{} = error} ->
        _ = :file.close(device)
        {:error, error}
    end
  end

  defp read_all_and_close(device, fragments, remaining) do
    read_size = min(@read_size, remaining + 1)

    case :file.read(device, read_size) do
      {:ok, bytes} when byte_size(bytes) <= remaining ->
        read_all_and_close(device, [bytes | fragments], remaining - byte_size(bytes))

      {:ok, _bytes} ->
        _ = :file.close(device)
        {:error, :max_bytes_exceeded}

      :eof ->
        close_read(device, fragments)

      {:error, reason} ->
        _ = :file.close(device)
        unavailable(:read_final, reason)
    end
  end

  defp descriptor_within_limit(
         {:file_info, size, :regular, _, _, _, _, _, _, _, _, _, _, _},
         max_bytes
       ),
       do: size_within_limit(size, max_bytes)

  defp descriptor_within_limit(_descriptor_stat, _max_bytes), do: invalid()

  defp descriptor_size({:file_info, size, :regular, _, _, _, _, _, _, _, _, _, _, _})
       when is_integer(size) and size >= 0,
       do: {:ok, size}

  defp descriptor_size(_descriptor_stat), do: invalid()

  defp size_within_limit(size, max_bytes)
       when is_integer(size) and size >= 0 and size <= max_bytes,
       do: :ok

  defp size_within_limit(_size, _max_bytes), do: {:error, :max_bytes_exceeded}

  defp close_read(device, fragments) do
    case :file.close(device) do
      :ok -> {:ok, fragments |> Enum.reverse() |> IO.iodata_to_binary()}
      {:error, reason} -> unavailable(:close_final, reason)
    end
  end

  defp read_prefix_and_close(device, max_bytes) do
    case :file.read(device, max_bytes) do
      {:ok, bytes} ->
        close_read(device, [bytes])

      :eof ->
        close_read(device, [])

      {:error, reason} ->
        _ = :file.close(device)
        unavailable(:read_final, reason)
    end
  end

  defp guarded_publish(root, final_path, partial_path, final_path, ownership, options) do
    with :ok <- allowed_partial(final_path, partial_path),
         :ok <- PathGuard.assert_safe_path(root, partial_path),
         :ok <- PathGuard.assert_safe_path(root, final_path),
         :ok <- require_identity(partial_path, ownership),
         :ok <- require_final_absent(final_path),
         :ok <- PathGuard.assert_safe_path(root, partial_path),
         :ok <- PathGuard.assert_safe_path(root, final_path),
         :ok <- require_identity(partial_path, ownership) do
      publish_link(root, partial_path, final_path, ownership, options)
    else
      {:error, %Error{} = error} ->
        state = Map.get(error.details, :publication_state, :not_published)
        publication_error(error, state, :publish)
    end
  end

  defp guarded_publish(
         _root,
         _final_path,
         _partial_path,
         _other_final,
         _ownership,
         _options
       ),
       do: publication_error(Error.new(:invalid), :not_published, :publish)

  defp publish_link(root, partial_path, final_path, original_identity, options) do
    case File.ln(partial_path, final_path) do
      :ok ->
        finish_published(root, partial_path, final_path, original_identity, options)

      {:error, :eexist} ->
        publication_error(Error.new(:conflict), :not_published, :link_final)

      {:error, reason} ->
        state = if final_absent?(final_path), do: :not_published, else: :ambiguous
        publication_error(storage_error(:link_final, reason), state, :link_final)
    end
  end

  defp finish_published(root, partial_path, final_path, original_identity, options) do
    with :ok <- PathGuard.assert_safe_path(root, partial_path),
         :ok <- PathGuard.assert_safe_path(root, final_path),
         :ok <- require_original_identity(partial_path, final_path, original_identity),
         :ok <- Sync.file_and_parent(final_path, options),
         :ok <- PathGuard.assert_safe_path(root, partial_path),
         :ok <- PathGuard.assert_safe_path(root, final_path),
         :ok <- require_original_identity(partial_path, final_path, original_identity),
         :ok <-
           guarded_remove_owned(root, final_path, partial_path, original_identity, options),
         :ok <- PathGuard.assert_safe_path(root, final_path),
         :ok <- require_identity(final_path, original_identity) do
      :ok
    else
      {:error, %Error{} = error} ->
        publication_error(error, :published, :durable_publish)

      {:error, reason} ->
        publication_error(storage_error(:durable_publish, reason), :published, :durable_publish)
    end
  end

  defp require_original_identity(left, right, original_identity) do
    with :ok <- require_identity(left, original_identity),
         :ok <- require_identity(right, original_identity) do
      :ok
    end
  end

  defp require_identity(path, original_identity) do
    case regular_identity(path) do
      {:ok, ^original_identity} -> :ok
      {:ok, _other_identity} -> ownership_mismatch()
      {:error, %Error{code: :not_found}} -> ownership_mismatch()
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp guarded_remove_owned(root, final_path, partial_path, ownership, options) do
    with :ok <- allowed_partial(final_path, partial_path) do
      remove_owned_path(root, partial_path, ownership, options)
    end
  end

  defp remove_owned_path(root, path, ownership, options) do
    with :ok <- PathGuard.assert_safe_path(root, path) do
      case regular_identity(path) do
        {:ok, ^ownership} ->
          with :ok <- PathGuard.assert_safe_path(root, path),
               {:ok, ^ownership} <- regular_identity(path),
               :ok <- remove_regular(path),
               :ok <- Sync.directory(Path.dirname(path), options) do
            :ok
          else
            {:ok, _replacement} -> owned_removal_mismatch()
            {:error, %Error{code: :not_found}} -> :ok
            {:error, %Error{} = error} -> {:error, error}
          end

        {:ok, _replacement} ->
          owned_removal_mismatch()

        {:error, %Error{code: :not_found}} ->
          :ok

        {:error, %Error{} = error} ->
          {:error, error}
      end
    end
  end

  defp guarded_remove_partial(root, final_path, partial_path, options) do
    with :ok <- allowed_partial(final_path, partial_path),
         :ok <- PathGuard.assert_safe_path(root, partial_path) do
      case File.lstat(partial_path) do
        {:ok, %File.Stat{type: :regular}} ->
          with :ok <- PathGuard.assert_safe_path(root, partial_path),
               :ok <- remove_regular(partial_path),
               :ok <- Sync.directory(Path.dirname(partial_path), options) do
            :ok
          end

        {:error, :enoent} ->
          :ok

        {:ok, _other} ->
          invalid()

        {:error, reason} ->
          unavailable(:inspect_partial, reason)
      end
    end
  end

  defp remove_regular(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> unavailable(:remove_partial, reason)
    end
  end

  defp regular_identity(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, inode: inode, major_device: major}} ->
        {:ok, {:local_file, major, inode}}

      {:ok, _other} ->
        invalid()

      {:error, :enoent} ->
        {:error, Error.new(:not_found)}

      {:error, reason} ->
        unavailable(:inspect_regular_identity, reason)
    end
  end

  defp descriptor_identity(device) do
    case :file.read_file_info(device) do
      {:ok, descriptor_stat} ->
        descriptor_identity_from_stat(descriptor_stat)

      {:error, reason} ->
        unavailable(:inspect_opened_partial, reason)
    end
  end

  defp descriptor_identity_from_stat(
         {:file_info, _, :regular, _, _, _, _, mode, _, major, _, inode, _, _}
       ) do
    {:ok, {:local_file, major, inode}, Bitwise.band(mode, 0o777)}
  end

  defp descriptor_identity_from_stat(_descriptor_stat), do: invalid()

  defp ownership_mismatch do
    {:error,
     Error.new(:storage_unavailable,
       details: %{
         operation: :verify_owned_partial,
         ownership_state: :mismatch,
         publication_state: :ambiguous
       },
       retryable?: true
     )}
  end

  defp owned_removal_mismatch do
    {:error,
     Error.new(:storage_unavailable,
       details: %{operation: :remove_owned, ownership_state: :mismatch},
       retryable?: true
     )}
  end

  defp require_final_absent(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _existing} -> {:error, Error.new(:conflict)}
      {:error, reason} -> unavailable(:inspect_final, reason)
    end
  end

  defp final_absent?(path), do: match?({:error, :enoent}, File.lstat(path))

  defp allowed_path(final_path, path) do
    if path == final_path or valid_partial_path?(final_path, path), do: :ok, else: invalid()
  end

  defp allowed_partial(final_path, path) do
    if valid_partial_path?(final_path, path), do: :ok, else: invalid()
  end

  defp valid_partial_path?(final_path, path) when is_binary(path) do
    prefix = final_path <> ".partial."

    case path do
      <<^prefix::binary, manifest_id::binary>> ->
        Path.dirname(path) == Path.dirname(final_path) and
          match?({:ok, ^manifest_id}, PathGuard.uuid(manifest_id))

      _other ->
        false
    end
  end

  defp valid_partial_path?(_final_path, _path), do: false

  defp same_file?(
         %File.Stat{type: :regular, inode: inode, major_device: major},
         {:file_info, _, :regular, _, _, _, _, _, _, major, _, inode, _, _}
       ),
       do: true

  defp same_file?(_path_stat, _descriptor_stat), do: false

  defp sync_options(context) do
    case Map.get(context, :sync_options, []) do
      options when is_list(options) -> options
      _invalid -> []
    end
  end

  defp result_code(:ok), do: :ok
  defp result_code({:error, %Error{code: code}}), do: code
  defp result_code(_other), do: :storage_unavailable

  defp publication_error(%Error{} = error, state, operation) do
    details =
      error.details
      |> Map.put(:publication_state, state)
      |> Map.put_new(:operation, operation)

    {:error, %{error | details: details}}
  end

  defp storage_error(operation, reason) do
    Error.new(:storage_unavailable,
      details: %{operation: operation, reason: reason},
      retryable?: true
    )
  end

  defp invalid, do: {:error, Error.new(:invalid)}

  defp unavailable(operation, reason),
    do: {:error, storage_error(operation, reason)}
end
