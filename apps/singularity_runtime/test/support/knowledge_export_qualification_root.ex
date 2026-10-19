defmodule Singularity.Runtime.KnowledgeExportQualificationRoot do
  @moduledoc false

  @environment "SINGULARITY_TASK16_FIXTURE_ROOT"
  @failure "invalid Task16 fixture root"
  @identity_keys [:major_device, :minor_device, :inode, :uid, :gid, :mode, :type]

  def allocate!(fallback_tmp_dir) do
    case System.fetch_env(@environment) do
      :error -> fallback_tmp_dir
      {:ok, root} -> allocate_configured!(root, fallback_tmp_dir)
    end
  end

  defp allocate_configured!(root, fallback_tmp_dir) do
    with true <- canonical_absolute?(root),
         {:ok, fallback} <- real_directory(fallback_tmp_dir),
         {:ok, chain} <- directory_chain(root),
         {^root, parent} <- List.last(chain),
         true <- private_directory?(parent, fallback.uid) do
      child = Path.join(root, Base.encode16(:crypto.strong_rand_bytes(16), case: :lower))

      with :ok <- File.mkdir(child),
           :ok <- File.chmod(child, 0o700),
           {:ok, stat} <- real_directory(child),
           true <- private_directory?(stat, fallback.uid),
           true <- same_chain?(chain) do
        child
      else
        _ -> invalid!()
      end
    else
      _ -> invalid!()
    end
  end

  defp canonical_absolute?(path) do
    is_binary(path) and path != "" and not String.contains?(path, <<0>>) and
      Path.type(path) == :absolute and Path.expand(path) == path
  end

  defp real_directory(path) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory} = stat} -> {:ok, stat}
      _ -> :error
    end
  end

  defp real_directory(_path), do: :error

  defp private_directory?(stat, uid) do
    stat.uid == uid and Bitwise.band(stat.mode, 0o7777) == 0o700
  end

  defp directory_chain(root) do
    root
    |> ancestors()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, chain} ->
      case real_directory(path) do
        {:ok, stat} -> {:cont, {:ok, [{path, stat} | chain]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, chain} -> {:ok, Enum.reverse(chain)}
      :error -> :error
    end
  end

  defp ancestors("/"), do: ["/"]
  defp ancestors(path), do: ancestors(Path.dirname(path)) ++ [path]

  defp same_chain?(chain) do
    Enum.all?(chain, fn {path, before} ->
      case real_directory(path) do
        {:ok, after_stat} ->
          Map.take(after_stat, @identity_keys) == Map.take(before, @identity_keys)

        :error ->
          false
      end
    end)
  end

  defp invalid!, do: raise(ArgumentError, @failure)
end
