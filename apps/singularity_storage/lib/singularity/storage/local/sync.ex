defmodule Singularity.Storage.Local.Sync do
  @moduledoc """
  Synchronizes object bytes and directory entries before durability is reported.

  A two-argument `:sync_fun` may be injected for deterministic failure tests.
  It receives `:file` or `:directory` and the path being synchronized.
  """

  alias Singularity.Core.Error

  @type kind :: :file | :directory
  @type sync_fun :: (kind(), Path.t() -> :ok | {:error, term()})

  @spec file(Path.t(), keyword()) :: :ok | {:error, Error.t()}
  def file(path, opts \\ []), do: run(:file, path, opts)

  @spec directory(Path.t(), keyword()) :: :ok | {:error, Error.t()}
  def directory(path, opts \\ []), do: run(:directory, path, opts)

  @spec directory_if_present(Path.t(), keyword()) :: :ok | {:error, Error.t()}
  def directory_if_present(path, opts \\ []) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> directory(path, opts)
      {:ok, _other} -> {:error, Error.new(:invalid)}
      {:error, :enoent} -> :ok
      {:error, reason} -> unavailable(:directory, reason)
    end
  end

  @spec file_and_parent(Path.t(), keyword()) :: :ok | {:error, Error.t()}
  def file_and_parent(path, opts \\ []) do
    with :ok <- file(path, opts) do
      directory(Path.dirname(path), opts)
    end
  end

  defp run(kind, path, opts) when is_binary(path) and byte_size(path) > 0 do
    with {:ok, sync_fun} <- sync_fun(opts) do
      invoke(sync_fun, kind, path)
    end
  end

  defp run(_kind, _path, _opts), do: {:error, Error.new(:invalid)}

  defp sync_fun(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:sync_fun] == [] do
      case Keyword.get(opts, :sync_fun, &default_sync/2) do
        sync_fun when is_function(sync_fun, 2) -> {:ok, sync_fun}
        _sync_fun -> {:error, Error.new(:invalid)}
      end
    else
      {:error, Error.new(:invalid)}
    end
  end

  defp sync_fun(_opts), do: {:error, Error.new(:invalid)}

  defp invoke(sync_fun, kind, path) do
    case sync_fun.(kind, path) do
      :ok -> :ok
      {:error, reason} -> unavailable(kind, reason)
      other -> unavailable(kind, {:unexpected_return, other})
    end
  rescue
    exception -> unavailable(kind, {:exception, exception.__struct__})
  catch
    caught_kind, reason -> unavailable(kind, {caught_kind, reason})
  end

  defp default_sync(:file, path), do: sync_open_path(path, [:read, :raw, :binary], :regular)

  defp default_sync(:directory, path),
    do: sync_open_path(path, [:read, :raw, :binary, :directory], :directory)

  defp sync_open_path(path, modes, expected_type) do
    with {:ok, %File.Stat{type: ^expected_type} = before_stat} <- File.lstat(path),
         {:ok, io_device} <- :file.open(String.to_charlist(path), modes) do
      result =
        with {:ok, descriptor_stat} <- :file.read_file_info(io_device),
             {:ok, %File.Stat{type: ^expected_type} = after_stat} <- File.lstat(path),
             true <- same_file?(before_stat, descriptor_stat, expected_type),
             true <- same_file?(descriptor_stat, after_stat, expected_type) do
          :ok
        else
          false -> {:error, :path_replaced}
          {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink}
          {:ok, %File.Stat{type: type}} -> {:error, {:unexpected_type, type}}
          {:error, reason} -> {:error, reason}
        end

      case result do
        :ok ->
          sync_and_close(io_device)

        {:error, _reason} = error ->
          _ = :file.close(io_device)
          error
      end
    else
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink}
      {:ok, %File.Stat{type: type}} -> {:error, {:unexpected_type, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp same_file?(
         %File.Stat{} = left,
         {:file_info, _, type, _, _, _, _, _, _, major, _, inode, _, _},
         expected_type
       ) do
    type == expected_type and left.type == expected_type and left.inode == inode and
      left.major_device == major
  end

  defp same_file?(
         {:file_info, _, type, _, _, _, _, _, _, major, _, inode, _, _},
         %File.Stat{} = right,
         expected_type
       ) do
    type == expected_type and right.type == expected_type and right.inode == inode and
      right.major_device == major
  end

  defp same_file?(_left, _right, _expected_type), do: false

  defp sync_and_close(io_device) do
    sync_result = :file.sync(io_device)
    close_result = :file.close(io_device)

    case {sync_result, close_result} do
      {:ok, :ok} -> :ok
      {{:error, reason}, _close_result} -> {:error, {:sync, reason}}
      {:ok, {:error, reason}} -> {:error, {:close, reason}}
    end
  end

  defp unavailable(kind, reason) do
    {:error,
     Error.new(:storage_unavailable,
       details: %{operation: :"sync_#{kind}", reason: reason},
       retryable?: true
     )}
  end
end
