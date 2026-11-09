defmodule Singularity.Storage.Local.PathGuard do
  @moduledoc """
  Builds local object paths from validated server-generated identifiers.

  Path construction is deliberately limited to canonical UUIDs and lowercase
  SHA-256 digests. Callers must re-run `assert_safe_path/2` immediately before
  filesystem mutations to detect a path component replaced with a symlink.
  """

  alias Singularity.Core.Error

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @digest ~r/\A[0-9a-f]{64}\z/

  @spec segment(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def segment(value) do
    case uuid(value) do
      {:ok, uuid} -> {:ok, uuid}
      {:error, _error} -> digest(value)
    end
  end

  @spec uuid(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def uuid(value) when is_binary(value) do
    if Regex.match?(@uuid, value),
      do: {:ok, value},
      else: invalid()
  end

  def uuid(_value), do: invalid()

  @spec digest(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def digest(value) when is_binary(value) do
    if Regex.match?(@digest, value),
      do: {:ok, value},
      else: invalid()
  end

  def digest(_value), do: invalid()

  @spec staging_path(term(), term()) ::
          {:ok, Path.t()} | {:error, Error.t()}
  def staging_path(root, stage_id) do
    with {:ok, root} <- root(root),
         {:ok, stage_id} <- uuid(stage_id),
         path = Path.join([root, "staging", stage_id]),
         :ok <- assert_safe_path(root, path) do
      {:ok, path}
    end
  end

  @spec object_path(term(), term(), term(), term()) ::
          {:ok, Path.t()} | {:error, Error.t()}
  def object_path(root, vault_uuid, domain_uuid, lookup_digest) do
    with {:ok, root} <- root(root),
         {:ok, vault_uuid} <- uuid(vault_uuid),
         {:ok, domain_uuid} <- uuid(domain_uuid),
         {:ok, lookup_digest} <- digest(lookup_digest),
         prefix = binary_part(lookup_digest, 0, 2),
         path <-
           Path.join([
             root,
             "objects",
             vault_uuid,
             domain_uuid,
             "hmac-sha256",
             prefix,
             lookup_digest
           ]),
         :ok <- assert_safe_path(root, path) do
      {:ok, path}
    end
  end

  @spec finalization_receipt_path(term(), term()) ::
          {:ok, Path.t()} | {:error, Error.t()}
  def finalization_receipt_path(root, stage_id) do
    with {:ok, root} <- root(root),
         {:ok, stage_id} <- uuid(stage_id),
         path = Path.join([root, "finalized", stage_id]),
         :ok <- assert_safe_path(root, path) do
      {:ok, path}
    end
  end

  @spec assert_safe_path(term(), term()) :: :ok | {:error, Error.t()}
  def assert_safe_path(root, path) do
    with {:ok, root} <- root(root),
         {:ok, path} <- path(path),
         {:ok, relative} <- relative_path(root, path) do
      relative
      |> existing_components(root)
      |> reject_symlinks()
    end
  end

  defp root(root) when is_binary(root) and byte_size(root) > 0 do
    if String.contains?(root, <<0>>),
      do: invalid(),
      else: {:ok, Path.expand(root)}
  end

  defp root(_root), do: invalid()

  defp path(path) when is_binary(path) and byte_size(path) > 0 do
    if String.contains?(path, <<0>>),
      do: invalid(),
      else: {:ok, Path.expand(path)}
  end

  defp path(_path), do: invalid()

  defp relative_path(root, path) do
    relative = Path.relative_to(path, root)
    segments = Path.split(relative)

    if Path.type(relative) == :relative and ".." not in segments,
      do: {:ok, relative},
      else: invalid()
  end

  defp existing_components(".", root), do: [root]

  defp existing_components(relative, root) do
    [root | Enum.scan(Path.split(relative), root, &Path.join(&2, &1))]
  end

  defp reject_symlinks(paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case File.lstat(path) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, invalid()}

        {:ok, _stat} ->
          {:cont, :ok}

        {:error, :enoent} ->
          {:cont, :ok}

        {:error, :enotdir} ->
          {:halt, invalid()}

        {:error, reason} ->
          {:halt, unavailable(:inspect_path, reason)}
      end
    end)
  end

  defp invalid, do: {:error, Error.new(:invalid)}

  defp unavailable(operation, reason) do
    {:error,
     Error.new(:storage_unavailable,
       details: %{operation: operation, reason: reason},
       retryable?: true
     )}
  end
end
