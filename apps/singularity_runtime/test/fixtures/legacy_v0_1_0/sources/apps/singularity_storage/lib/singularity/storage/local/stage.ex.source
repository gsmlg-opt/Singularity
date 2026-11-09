defmodule Singularity.Storage.Local.Stage do
  @moduledoc false

  import Bitwise

  alias Singularity.Core.Error
  alias Singularity.Core.StageRef
  alias Singularity.Storage.Crypto.Format
  alias Singularity.Storage.Local.PathGuard
  alias Singularity.Storage.Local.Sync

  @write_bit 0o200
  @read_size 64 * 1024
  @header_size 66
  @record_header_size 8
  @record_tag_size 16
  @final_plaintext_size 44

  @spec create(map()) :: {:ok, StageRef.t()} | {:error, Error.t()}
  def create(%{root: root} = context) when is_binary(root) do
    staging_directory = Path.join(Path.expand(root), "staging")

    with :ok <- ensure_directory(context, staging_directory) do
      create_unique(root, 4)
    end
  end

  def create(_context), do: invalid()

  @spec create(map(), String.t()) :: {:ok, StageRef.t()} | {:error, Error.t()}
  def create(%{root: root} = context, stage_id)
      when is_binary(root) and is_binary(stage_id) do
    staging_directory = Path.join(Path.expand(root), "staging")

    with {:ok, ^stage_id} <- PathGuard.uuid(stage_id),
         :ok <- ensure_directory(context, staging_directory),
         {:ok, path} <- PathGuard.staging_path(root, stage_id) do
      create_exact(path, stage_id)
    else
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> invalid()
    end
  end

  def create(_context, _stage_id), do: invalid()

  @spec append(map(), StageRef.t(), iodata()) :: :ok | {:error, Error.t()}
  def append(%{root: root} = context, %StageRef{stage_id: stage_id} = stage_ref, chunk)
      when is_binary(root) do
    with {:ok, _size} <- iodata_size(chunk),
         {:ok, ^stage_id} <- PathGuard.uuid(stage_id) do
      with_lock(context, stage_ref, fn -> append_locked(context, stage_id, chunk) end)
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def append(_context, _stage_ref, _chunk), do: invalid()

  @spec seal(map(), StageRef.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def seal(%{root: root} = context, %StageRef{stage_id: stage_id} = stage_ref, metadata)
      when is_binary(root) and is_map(metadata) do
    with {:ok, ^stage_id} <- PathGuard.uuid(stage_id) do
      with_lock(context, stage_ref, fn ->
        with {:ok, path} <- PathGuard.staging_path(root, stage_id) do
          seal_path(context, path, stage_id, metadata)
        end
      end)
    else
      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  def seal(_context, _stage_ref, _metadata), do: invalid()

  @spec with_lock(map(), StageRef.t(), (-> result)) :: result | {:error, Error.t()}
        when result: term()
  def with_lock(%{root: root}, %StageRef{stage_id: stage_id}, operation)
      when is_binary(root) and is_function(operation, 0) do
    lock_id = {{__MODULE__, Path.expand(root), stage_id}, self()}

    case :global.trans(lock_id, operation, [node()]) do
      {:aborted, _reason} -> unavailable()
      result -> result
    end
  end

  def with_lock(_context, _stage_ref, _operation), do: invalid()

  @spec stat(map(), StageRef.t()) :: {:ok, map()} | {:error, Error.t()}
  def stat(%{root: root}, %StageRef{stage_id: stage_id}) when is_binary(root) do
    with {:ok, ^stage_id} <- PathGuard.uuid(stage_id),
         {:ok, path} <- PathGuard.staging_path(root, stage_id),
         {:ok, file_stat} <- regular_stat(path),
         {:ok, digest} <- digest(path),
         {:ok, format_envelope} <- inspect_format_envelope(path, file_stat.size) do
      {:ok,
       %{
         byte_size: file_stat.size,
         ciphertext_hash: digest,
         format_envelope: format_envelope,
         sealed?: sealed?(file_stat)
       }}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, :enoent} -> not_found()
      {:error, _reason} -> unavailable()
    end
  end

  def stat(_context, _stage_ref), do: invalid()

  @spec abort(map(), StageRef.t()) :: :ok | {:error, Error.t()}
  def abort(%{root: root} = context, %StageRef{stage_id: stage_id} = stage_ref)
      when is_binary(root) do
    with {:ok, ^stage_id} <- PathGuard.uuid(stage_id) do
      with_lock(context, stage_ref, fn -> abort_locked(context, stage_ref) end)
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def abort(_context, _stage_ref), do: invalid()

  @doc false
  @spec abort_locked(map(), StageRef.t()) :: :ok | {:error, Error.t()}
  def abort_locked(%{root: root} = context, %StageRef{stage_id: stage_id})
      when is_binary(root) do
    with {:ok, ^stage_id} <- PathGuard.uuid(stage_id),
         {:ok, path} <- PathGuard.staging_path(root, stage_id),
         :ok <- remove_regular(path),
         :ok <- Sync.directory_if_present(Path.dirname(path), sync_options(context)) do
      :ok
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, _reason} -> unavailable()
    end
  end

  def abort_locked(_context, _stage_ref), do: invalid()

  @spec list(map()) :: {:ok, [StageRef.t()]} | {:error, Error.t()}
  def list(%{root: root}) when is_binary(root) do
    directory = Path.join(Path.expand(root), "staging")

    with :ok <- ensure_existing_directory(root, directory),
         {:ok, entries} <- File.ls(directory) do
      list_entries(root, entries)
    else
      {:error, :enoent} -> {:ok, []}
      {:error, %Error{} = error} -> {:error, error}
      {:error, _reason} -> unavailable()
    end
  end

  def list(_context), do: invalid()

  @spec path(map(), StageRef.t()) :: {:ok, binary()} | {:error, Error.t()}
  def path(%{root: root}, %StageRef{stage_id: stage_id}) when is_binary(root) do
    PathGuard.staging_path(root, stage_id)
  end

  def path(_context, _stage_ref), do: invalid()

  @spec sealed?(File.Stat.t()) :: boolean()
  def sealed?(%File.Stat{mode: mode}), do: band(mode, @write_bit) == 0

  @spec ensure_directory(map(), binary()) :: :ok | {:error, Error.t()}
  def ensure_directory(%{root: root} = context, directory)
      when is_binary(root) and is_binary(directory) do
    root = Path.expand(root)
    directory = Path.expand(directory)

    with true <- inside?(root, directory),
         :ok <- create_root(root),
         :ok <- create_relative_directories(root, Path.relative_to(directory, root)),
         :ok <- PathGuard.assert_safe_path(root, directory),
         :ok <- sync_directory_chain(root, directory, sync_options(context)) do
      :ok
    else
      false -> invalid()
      {:error, %Error{} = error} -> {:error, error}
      {:error, _reason} -> unavailable()
    end
  end

  def ensure_directory(_context, _directory), do: invalid()

  @spec digest(binary()) :: {:ok, binary()} | {:error, term()}
  def digest(path) when is_binary(path) do
    with {:ok, io} <- open_regular(path, [:read, :binary, :raw]) do
      digest_io(io, :crypto.hash_init(:sha256))
    end
  end

  defp create_unique(_root, 0), do: unavailable()

  defp create_unique(root, attempts_left) do
    stage_id = Ecto.UUID.generate()

    with {:ok, path} <- PathGuard.staging_path(root, stage_id) do
      case :file.open(String.to_charlist(path), [:write, :binary, :raw, :exclusive]) do
        {:ok, io} ->
          case :file.close(io) do
            :ok ->
              with :ok <- File.chmod(path, 0o600) do
                {:ok, %StageRef{stage_id: stage_id}}
              else
                {:error, _reason} -> unavailable()
              end

            {:error, _reason} ->
              unavailable()
          end

        {:error, :eexist} ->
          create_unique(root, attempts_left - 1)

        {:error, _reason} ->
          unavailable()
      end
    end
  end

  defp create_exact(path, stage_id) do
    case :file.open(String.to_charlist(path), [:write, :binary, :raw, :exclusive]) do
      {:ok, io} ->
        case :file.close(io) do
          :ok ->
            with :ok <- File.chmod(path, 0o600) do
              {:ok, %StageRef{stage_id: stage_id}}
            else
              {:error, _reason} -> unavailable()
            end

          {:error, _reason} ->
            unavailable()
        end

      {:error, :eexist} ->
        reusable_empty_stage(path, stage_id)

      {:error, _reason} ->
        unavailable()
    end
  end

  defp reusable_empty_stage(path, stage_id) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: 0} = stat} ->
        if sealed?(stat) do
          {:error, Error.new(:conflict)}
        else
          {:ok, %StageRef{stage_id: stage_id}}
        end

      {:ok, _other} ->
        invalid()

      {:error, _reason} ->
        unavailable()
    end
  end

  defp make_read_only(path, %File.Stat{} = stat) do
    if sealed?(stat), do: :ok, else: File.chmod(path, 0o400)
  end

  defp append_locked(context, stage_id, chunk) do
    with {:ok, path} <- PathGuard.staging_path(context.root, stage_id),
         {:ok, stat} <- regular_stat(path),
         false <- sealed?(stat),
         {:ok, io} <- open_regular(path, [:append, :binary, :raw]) do
      result =
        case operation_hook(context, :append_opened, %{path: path}) do
          :ok ->
            write_and_close(io, chunk)

          {:error, _reason} = error ->
            _ = :file.close(io)
            error
        end

      normalize_io_result(result)
    else
      true -> {:error, Error.new(:conflict)}
      {:error, %Error{} = error} -> {:error, error}
      {:error, :enoent} -> not_found()
      {:error, _reason} -> unavailable()
    end
  end

  defp regular_stat(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular} = stat} -> {:ok, stat}
      {:ok, _other} -> invalid()
      {:error, reason} -> {:error, reason}
    end
  end

  defp inspect_format_envelope(path, byte_size)
       when is_integer(byte_size) and
              byte_size >=
                @header_size + @record_header_size +
                  @final_plaintext_size + @record_tag_size do
    with {:ok, io} <- open_regular(path, [:read, :binary, :raw]) do
      result =
        with {:ok, header} <- :file.pread(io, 0, Format.header_size()),
             {:ok, ^header, "", parsed} <- Format.split_header(header),
             {:ok, chunk_count} <-
               inspect_record_frames(io, Format.header_size(), byte_size, 0, false),
             {:ok, vault_id} <- Ecto.UUID.load(parsed.vault_id),
             {:ok, encryption_domain_id} <-
               Ecto.UUID.load(parsed.encryption_domain_id),
             {:ok, object_id} <- Ecto.UUID.load(parsed.object_id) do
          {:ok,
           %{
             algorithm: parsed.algorithm,
             chunk_count: chunk_count,
             chunk_size: parsed.chunk_size,
             encryption_domain_id: encryption_domain_id,
             final_record?: true,
             format_version: parsed.format_version,
             object_id: object_id,
             vault_id: vault_id
           }}
        else
          _invalid -> {:ok, nil}
        end

      close_result = :file.close(io)

      case {result, close_result} do
        {{:ok, envelope}, :ok} -> {:ok, envelope}
        {{:error, _reason} = error, :ok} -> error
        {_result, {:error, reason}} -> {:error, reason}
      end
    end
  end

  defp inspect_format_envelope(_path, _byte_size), do: {:ok, nil}

  defp inspect_record_frames(
         io,
         offset,
         byte_size,
         expected_counter,
         short_record_seen?
       ) do
    with true <- offset + @record_header_size <= byte_size,
         {:ok, <<counter::unsigned-big-32, plaintext_size::unsigned-big-32>>} <-
           :file.pread(io, offset, @record_header_size) do
      inspect_record_frame(
        io,
        offset,
        byte_size,
        expected_counter,
        short_record_seen?,
        counter,
        plaintext_size
      )
    else
      _invalid -> {:error, :invalid_format}
    end
  end

  defp inspect_record_frame(
         _io,
         offset,
         byte_size,
         expected_counter,
         _short_record_seen?,
         counter,
         @final_plaintext_size
       )
       when counter == 0xFFFFFFFF and
              offset + @record_header_size + @final_plaintext_size +
                @record_tag_size == byte_size,
       do: {:ok, expected_counter}

  defp inspect_record_frame(
         io,
         offset,
         byte_size,
         expected_counter,
         false,
         counter,
         plaintext_size
       )
       when counter == expected_counter and counter <= 0xFFFFFFFE and
              plaintext_size > 0 and plaintext_size <= 4_194_304 do
    next_offset =
      offset + @record_header_size + plaintext_size + @record_tag_size

    inspect_record_frames(
      io,
      next_offset,
      byte_size,
      expected_counter + 1,
      plaintext_size < 4_194_304
    )
  end

  defp inspect_record_frame(
         _io,
         _offset,
         _byte_size,
         _expected_counter,
         _short_record_seen?,
         _counter,
         _plaintext_size
       ),
       do: {:error, :invalid_format}

  defp open_regular(path, modes) do
    with {:ok, before_stat} <- regular_stat(path),
         {:ok, io} <- :file.open(String.to_charlist(path), modes) do
      result =
        with {:ok, descriptor_stat} <- :file.read_file_info(io),
             {:ok, after_stat} <- regular_stat(path),
             true <- same_file?(before_stat, descriptor_stat),
             true <- same_file?(descriptor_stat, after_stat) do
          :ok
        else
          false -> invalid()
          {:error, reason} -> {:error, reason}
        end

      case result do
        :ok ->
          {:ok, io}

        {:error, _reason} = error ->
          _ = :file.close(io)
          error
      end
    end
  end

  defp same_file?(
         %File.Stat{} = left,
         {:file_info, _, :regular, _, _, _, _, _, _, major, _, inode, _, _}
       ) do
    left.inode == inode and left.major_device == major and left.type == :regular
  end

  defp same_file?(
         {:file_info, _, :regular, _, _, _, _, _, _, major, _, inode, _, _},
         %File.Stat{} = right
       ) do
    right.inode == inode and right.major_device == major and right.type == :regular
  end

  defp same_file?(_left, _right), do: false

  defp write_and_close(io, chunk) do
    result = :file.write(io, chunk)
    close_result = :file.close(io)

    case {result, close_result} do
      {:ok, :ok} -> :ok
      {{:error, reason}, _close} -> {:error, reason}
      {:ok, {:error, reason}} -> {:error, reason}
    end
  end

  defp digest_io(io, hash) do
    case :file.read(io, @read_size) do
      {:ok, bytes} ->
        digest_io(io, :crypto.hash_update(hash, bytes))

      :eof ->
        case :file.close(io) do
          :ok -> {:ok, :crypto.hash_final(hash)}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        _ = :file.close(io)
        {:error, reason}
    end
  end

  defp remove_regular(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> remove_existing_regular(path)
      {:ok, _other} -> invalid()
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_existing_regular(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_entries(root, entries) do
    entries
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, refs} ->
      with {:ok, ^entry} <- PathGuard.uuid(entry),
           {:ok, path} <- PathGuard.staging_path(root, entry),
           {:ok, %File.Stat{type: :regular}} <- File.lstat(path) do
        {:cont, {:ok, [%StageRef{stage_id: entry} | refs]}}
      else
        _invalid -> {:halt, invalid()}
      end
    end)
    |> case do
      {:ok, refs} -> {:ok, Enum.reverse(refs)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp ensure_existing_directory(root, directory) do
    with :ok <- PathGuard.assert_safe_path(root, directory),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(directory) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _other -> invalid()
    end
  end

  defp create_root(root) do
    case File.mkdir_p(root) do
      :ok ->
        case File.lstat(root) do
          {:ok, %File.Stat{type: :directory}} -> :ok
          {:ok, _other} -> invalid()
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_relative_directories(_root, "."), do: :ok

  defp create_relative_directories(root, relative) do
    relative
    |> Path.split()
    |> Enum.reduce_while(root, fn segment, parent ->
      path = Path.join(parent, segment)

      case File.mkdir(path) do
        :ok ->
          {:cont, path}

        {:error, :eexist} ->
          case File.lstat(path) do
            {:ok, %File.Stat{type: :directory}} -> {:cont, path}
            _invalid -> {:halt, invalid()}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      _path -> :ok
    end
  end

  defp inside?(root, path) do
    relative = Path.relative_to(path, root)
    relative == "." or (relative != ".." and not String.starts_with?(relative, "../"))
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

  defp iodata_size(chunk) do
    {:ok, :erlang.iolist_size(chunk)}
  rescue
    ArgumentError -> invalid()
  end

  defp sync_options(context) do
    case Map.get(context, :sync_options, []) do
      options when is_list(options) -> options
      _invalid -> []
    end
  end

  defp operation_hook(context, operation, paths) do
    with options when is_list(options) <- Map.get(context, :filesystem_options, []),
         true <- Keyword.keyword?(options),
         hook when is_function(hook, 2) <-
           Keyword.get(options, :operation_hook, fn _operation, _paths -> :ok end) do
      case hook.(operation, paths) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected_hook_return, other}}
      end
    else
      _invalid -> {:error, :invalid_filesystem_options}
    end
  rescue
    exception -> {:error, {:hook_exception, exception.__struct__}}
  catch
    kind, reason -> {:error, {:hook_catch, kind, reason}}
  end

  defp normalize_io_result(:ok), do: :ok
  defp normalize_io_result({:error, _reason}), do: unavailable()

  defp seal_path(context, path, stage_id, metadata) do
    with {:ok, file_stat} <- regular_stat(path),
         :ok <- make_read_only(path, file_stat),
         :ok <- Sync.file_and_parent(path, sync_options(context)),
         {:ok, sealed_stat} <- stat(context, %StageRef{stage_id: stage_id}) do
      {:ok, Map.put(sealed_stat, :metadata, metadata)}
    else
      {:error, %Error{code: :storage_unavailable} = error} ->
        _ = File.chmod(path, 0o600)
        {:error, error}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, :enoent} ->
        not_found()

      {:error, _reason} ->
        unavailable()
    end
  end

  defp invalid, do: {:error, Error.new(:invalid)}
  defp not_found, do: {:error, Error.new(:not_found)}
  defp unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
