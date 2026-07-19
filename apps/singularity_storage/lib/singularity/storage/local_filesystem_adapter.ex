defmodule Singularity.Storage.LocalFilesystemAdapter do
  @moduledoc """
  Durable, immutable local-filesystem implementation of object storage.

  Every path component below the configured root is either a canonical UUID or
  a protected HMAC-SHA-256 digest. Original filenames and other client-provided
  metadata are never used to build filesystem paths.
  """

  @behaviour Singularity.Core.ObjectStorage

  alias Singularity.Core.Error
  alias Singularity.Core.ObjectRef
  alias Singularity.Core.StageRef
  alias Singularity.Storage.Local.PathGuard
  alias Singularity.Storage.Local.Stage
  alias Singularity.Storage.Local.Sync

  @default_vault_namespace "00000000-0000-0000-0000-000000000001"
  @default_domain_namespace "00000000-0000-0000-0000-000000000002"
  @receipt_magic "SINGULARITY-FINALIZED-V1\0"

  defmodule Handle do
    @moduledoc false

    @enforce_keys [:object_ref]
    defstruct [:object_ref]
  end

  @impl true
  def stage(context, %{stage_id: stage_id}) when is_binary(stage_id),
    do: Stage.create(context, stage_id)

  def stage(context, options) when is_map(options), do: Stage.create(context)

  def stage(_context, _options), do: invalid()

  @impl true
  def append_encrypted_chunk(context, %StageRef{} = stage_ref, chunk),
    do: Stage.append(context, stage_ref, chunk)

  def append_encrypted_chunk(_context, _stage_ref, _chunk), do: invalid()

  @impl true
  def seal_stage(context, %StageRef{} = stage_ref, metadata),
    do: Stage.seal(context, stage_ref, metadata)

  def seal_stage(_context, _stage_ref, _metadata), do: invalid()

  @impl true
  def stat_stage(context, %StageRef{} = stage_ref), do: Stage.stat(context, stage_ref)
  def stat_stage(_context, _stage_ref), do: invalid()

  @impl true
  def finalize(context, %StageRef{} = stage_ref, %ObjectRef{} = object_ref) do
    with {:ok, stage_path} <- Stage.path(context, stage_ref),
         {:ok, object_path} <- object_path(context, object_ref),
         :ok <- Stage.ensure_directory(context, Path.dirname(object_path)) do
      Stage.with_lock(context, stage_ref, fn ->
        lock_id = {{__MODULE__, object_path}, self()}

        case :global.trans(
               lock_id,
               fn -> finalize_locked(context, stage_ref, stage_path, object_ref, object_path) end,
               [node()]
             ) do
          {:aborted, _reason} -> unavailable()
          result -> result
        end
      end)
    else
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> invalid()
    end
  end

  def finalize(_context, _stage_ref, _object_ref), do: invalid()

  @impl true
  def abort_stage(context, %StageRef{} = stage_ref), do: Stage.abort(context, stage_ref)
  def abort_stage(_context, _stage_ref), do: invalid()

  @impl true
  def stat(context, %ObjectRef{} = object_ref) do
    with {:ok, path} <- object_path(context, object_ref),
         :ok <- PathGuard.assert_safe_path(context.root, path),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(path),
         {:ok, ciphertext_hash} <- Stage.digest(path) do
      {:ok, %{byte_size: size, ciphertext_hash: ciphertext_hash}}
    else
      {:ok, _other} -> invalid()
      {:error, %Error{} = error} -> {:error, error}
      {:error, :enoent} -> not_found()
      {:error, _reason} -> unavailable()
      _invalid -> invalid()
    end
  end

  def stat(_context, _object_ref), do: invalid()

  @impl true
  def open(context, %ObjectRef{} = object_ref) do
    with :ok <- verify(context, object_ref) do
      {:ok, %Handle{object_ref: object_ref}}
    end
  end

  def open(_context, _object_ref), do: invalid()

  @impl true
  def read_range(
        %{root: root} = context,
        %Handle{object_ref: %ObjectRef{} = object_ref},
        %Range{first: first, last: last, step: 1}
      )
      when is_binary(root) and is_integer(first) and first >= 0 and is_integer(last) and
             last >= first do
    with {:ok, path} <- object_path(context, object_ref),
         :ok <- PathGuard.assert_safe_path(root, path),
         {:ok, io} <- open_regular(path),
         result <- :file.pread(io, first, last - first + 1),
         :ok <- close(io) do
      case result do
        {:ok, bytes} -> {:ok, bytes}
        :eof -> {:ok, ""}
        {:error, _reason} -> unavailable()
      end
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, :enoent} -> not_found()
      {:error, _reason} -> unavailable()
      _invalid -> invalid()
    end
  end

  def read_range(_context, _handle, _range), do: invalid()

  @impl true
  def verify(context, %ObjectRef{} = object_ref) do
    with {:ok, %{ciphertext_hash: actual_hash}} <- stat(context, object_ref),
         {:ok, expected_hash} <- expected_ciphertext_hash(context),
         true <- is_nil(expected_hash) or secure_compare(actual_hash, expected_hash) do
      :ok
    else
      false -> integrity_failure()
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> invalid()
    end
  end

  def verify(_context, _object_ref), do: invalid()

  @impl true
  def delete(context, %ObjectRef{} = object_ref) do
    with {:ok, path} <- object_path(context, object_ref),
         :ok <- remove_object(path),
         :ok <- Sync.directory_if_present(Path.dirname(path), sync_options(context)) do
      :ok
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, _reason} -> unavailable()
      _invalid -> invalid()
    end
  end

  def delete(_context, _object_ref), do: invalid()

  @impl true
  def list_staged(context), do: Stage.list(context)

  defp finalize_locked(context, stage_ref, stage_path, object_ref, object_path) do
    with :ok <- PathGuard.assert_safe_path(context.root, stage_path),
         :ok <- PathGuard.assert_safe_path(context.root, object_path) do
      case File.lstat(object_path) do
        {:ok, %File.Stat{type: :regular}} ->
          reuse_existing(context, stage_ref, stage_path, object_ref, object_path)

        {:ok, _other} ->
          invalid()

        {:error, :enoent} ->
          publish_stage(context, stage_ref, stage_path, object_ref, object_path)

        {:error, _reason} ->
          unavailable()
      end
    end
  end

  defp publish_stage(context, stage_ref, stage_path, object_ref, object_path) do
    with {:ok, %{sealed?: true} = stage_stat} <- Stage.stat(context, stage_ref),
         :ok <- verify_expected_hash(context, stage_stat.ciphertext_hash),
         :ok <- PathGuard.assert_safe_path(context.root, stage_path),
         :ok <- PathGuard.assert_safe_path(context.root, object_path) do
      case publish_without_replacement(
             context,
             stage_ref,
             stage_path,
             object_path,
             stage_stat.ciphertext_hash
           ) do
        :ok ->
          finish_publication(
            context,
            stage_path,
            object_ref,
            object_path
          )

        {:error, :eexist} ->
          publication_error(Error.new(:conflict), :not_published)

        {:error, :enoent} ->
          publication_error(Error.new(:not_found), :not_published)

        {:error, %Error{} = error} ->
          publication_error(error, :not_published)

        {:error, _reason} ->
          publication_error(
            Error.new(:storage_unavailable, retryable?: true),
            :not_published
          )
      end
    else
      {:ok, %{sealed?: false}} ->
        publication_error(Error.new(:conflict), :not_published)

      {:error, %Error{} = error} ->
        publication_error(error, :not_published)

      {:error, :enoent} ->
        publication_error(Error.new(:not_found), :not_published)

      {:error, _reason} ->
        publication_error(
          Error.new(:storage_unavailable, retryable?: true),
          :not_published
        )

      _invalid ->
        invalid()
    end
  end

  defp finish_publication(context, stage_path, object_ref, object_path) do
    with :ok <- Sync.file_and_parent(object_path, sync_options(context)),
         :ok <- Sync.directory(Path.dirname(stage_path), sync_options(context)) do
      {:ok, object_ref}
    else
      {:error, %Error{} = error} ->
        publication_error(error, :published)

      {:error, _reason} ->
        publication_error(
          Error.new(:storage_unavailable, retryable?: true),
          :published
        )
    end
  end

  defp reuse_existing(context, stage_ref, stage_path, object_ref, object_path) do
    with {:ok, existing_digest} <- Stage.digest(object_path),
         :ok <- verify_expected_hash(context, existing_digest) do
      reuse_candidate(
        context,
        stage_ref,
        stage_path,
        object_ref,
        object_path,
        existing_digest
      )
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, _reason} -> unavailable()
    end
  end

  defp reuse_candidate(
         context,
         stage_ref,
         stage_path,
         object_ref,
         object_path,
         existing_digest
       ) do
    case Stage.stat(context, stage_ref) do
      {:ok, %{sealed?: true, ciphertext_hash: candidate_digest}} ->
        with true <- secure_compare(existing_digest, candidate_digest),
             :ok <- Sync.file_and_parent(object_path, sync_options(context)),
             :ok <- ensure_receipt(context, stage_ref, object_path, existing_digest),
             :ok <- discard_duplicate_stage(context, stage_ref, stage_path) do
          {:ok, object_ref}
        else
          false -> {:error, Error.new(:conflict)}
          {:error, %Error{} = error} -> {:error, error}
          {:error, _reason} -> unavailable()
        end

      {:ok, %{sealed?: false}} ->
        {:error, Error.new(:conflict)}

      {:error, %Error{code: :not_found}} ->
        with :ok <- verify_receipt(context, stage_ref, object_path, existing_digest),
             :ok <- Sync.file_and_parent(object_path, sync_options(context)),
             :ok <- Sync.directory(Path.dirname(stage_path), sync_options(context)) do
          {:ok, object_ref}
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp discard_duplicate_stage(context, stage_ref, stage_path) do
    case File.lstat(stage_path) do
      {:ok, %File.Stat{type: :regular}} -> Stage.abort_locked(context, stage_ref)
      {:ok, _other} -> invalid()
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp publish_without_replacement(
         context,
         %StageRef{} = stage_ref,
         source,
         destination,
         ciphertext_hash
       ) do
    with :ok <- ensure_receipt(context, stage_ref, destination, ciphertext_hash),
         :ok <-
           operation_hook(context, :before_publish, %{
             source: source,
             destination: destination
           }),
         :ok <- PathGuard.assert_safe_path(context.root, source),
         :ok <- PathGuard.assert_safe_path(context.root, destination),
         {:ok,
          %{
            sealed?: true,
            ciphertext_hash: <<_::binary-size(32)>> = observed_ciphertext_hash
          }} <-
           Stage.stat(context, stage_ref),
         true <- secure_compare(observed_ciphertext_hash, ciphertext_hash),
         :ok <- ensure_destination_absent(destination),
         :ok <- File.rename(source, destination) do
      :ok
    else
      false -> integrity_failure()
      {:ok, %{sealed?: false}} -> {:error, Error.new(:conflict)}
      {:ok, %{sealed?: true}} -> integrity_failure()
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_destination_absent(destination) do
    case File.lstat(destination) do
      {:error, :enoent} -> :ok
      {:ok, _existing} -> {:error, :eexist}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_receipt(context, %StageRef{stage_id: stage_id}, object_path, object_digest) do
    with {:ok, receipt_path} <-
           PathGuard.finalization_receipt_path(context.root, stage_id),
         :ok <- Stage.ensure_directory(context, Path.dirname(receipt_path)),
         payload <- receipt_payload(context.root, object_path, object_digest),
         :ok <- create_or_verify_receipt(receipt_path, payload, sync_options(context)),
         :ok <- Sync.file_and_parent(receipt_path, sync_options(context)) do
      :ok
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, _reason} -> unavailable()
    end
  end

  defp verify_receipt(context, %StageRef{stage_id: stage_id}, object_path, object_digest) do
    with {:ok, receipt_path} <-
           PathGuard.finalization_receipt_path(context.root, stage_id),
         :ok <- PathGuard.assert_safe_path(context.root, receipt_path),
         {:ok, payload} <- File.read(receipt_path),
         true <-
           secure_compare(payload, receipt_payload(context.root, object_path, object_digest)) do
      :ok
    else
      false -> {:error, Error.new(:conflict)}
      {:error, %Error{} = error} -> {:error, error}
      {:error, :enoent} -> {:error, Error.new(:conflict)}
      {:error, _reason} -> unavailable()
    end
  end

  defp create_or_verify_receipt(receipt_path, payload, sync_options) do
    case File.read(receipt_path) do
      {:ok, existing_payload} ->
        verify_receipt_payload(existing_payload, payload)

      {:error, :enoent} ->
        publish_receipt(receipt_path, payload, sync_options)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp publish_receipt(receipt_path, payload, sync_options) do
    temporary_path = receipt_path <> ".#{Ecto.UUID.generate()}.tmp"

    result =
      with :ok <- write_receipt(temporary_path, payload),
           :ok <- Sync.file(temporary_path, sync_options) do
        case File.ln(temporary_path, receipt_path) do
          :ok ->
            :ok

          {:error, :eexist} ->
            with {:ok, existing_payload} <- File.read(receipt_path) do
              verify_receipt_payload(existing_payload, payload)
            end

          {:error, reason} ->
            {:error, reason}
        end
      end

    _ = File.rm(temporary_path)
    result
  end

  defp write_receipt(receipt_path, payload) do
    case :file.open(String.to_charlist(receipt_path), [:write, :binary, :raw, :exclusive]) do
      {:ok, io} ->
        write_and_close_receipt(io, receipt_path, payload)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_and_close_receipt(io, receipt_path, payload) do
    write_result = :file.write(io, payload)
    close_result = :file.close(io)

    case {write_result, close_result} do
      {:ok, :ok} ->
        case File.chmod(receipt_path, 0o400) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end

      {{:error, reason}, _close_result} ->
        _ = File.rm(receipt_path)
        {:error, reason}

      {:ok, {:error, reason}} ->
        _ = File.rm(receipt_path)
        {:error, reason}
    end
  end

  defp verify_receipt_payload(existing_payload, payload) do
    if secure_compare(existing_payload, payload),
      do: :ok,
      else: {:error, Error.new(:conflict)}
  end

  defp receipt_payload(root, object_path, object_digest) do
    object_fingerprint =
      object_path
      |> Path.relative_to(Path.expand(root))
      |> then(&:crypto.hash(:sha256, &1))

    @receipt_magic <> object_fingerprint <> object_digest
  end

  defp object_path(%{root: root} = context, %ObjectRef{object_id: object_id})
       when is_binary(root) and is_binary(object_id) and byte_size(object_id) > 0 do
    vault_namespace = Map.get(context, :vault_namespace, @default_vault_namespace)
    domain_namespace = Map.get(context, :domain_namespace, @default_domain_namespace)

    lookup_digest =
      Map.get_lazy(context, :lookup_digest, fn ->
        :crypto.hash(:sha256, object_id)
        |> Base.encode16(case: :lower)
      end)

    PathGuard.object_path(root, vault_namespace, domain_namespace, lookup_digest)
  end

  defp object_path(_context, _object_ref), do: invalid()

  defp expected_ciphertext_hash(context) when is_map(context) do
    case Map.get(context, :ciphertext_hash) do
      nil -> {:ok, nil}
      <<_::binary-size(32)>> = digest -> {:ok, digest}
      _invalid -> invalid()
    end
  end

  defp expected_ciphertext_hash(_context), do: invalid()

  defp verify_expected_hash(context, actual_hash) do
    with {:ok, expected_hash} <- expected_ciphertext_hash(context),
         true <- is_nil(expected_hash) or secure_compare(actual_hash, expected_hash) do
      :ok
    else
      false -> integrity_failure()
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp open_regular(path) do
    with {:ok, %File.Stat{type: :regular} = before_stat} <- File.lstat(path),
         {:ok, io} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      result =
        with {:ok, descriptor_stat} <- :file.read_file_info(io),
             {:ok, %File.Stat{type: :regular} = after_stat} <- File.lstat(path),
             true <- same_file?(before_stat, descriptor_stat),
             true <- same_file?(descriptor_stat, after_stat) do
          :ok
        else
          false -> invalid()
          {:ok, _other} -> invalid()
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

  defp remove_object(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> remove_existing_object(path)
      {:ok, _other} -> invalid()
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_existing_object(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp close(io) do
    case :file.close(io) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp secure_compare(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    :crypto.hash_equals(left, right)
  end

  defp secure_compare(_left, _right), do: false

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

  defp publication_error(%Error{} = error, state)
       when state in [:not_published, :published, :ambiguous] do
    {:error, %{error | details: Map.put(error.details, :publication_state, state)}}
  end

  defp invalid, do: {:error, Error.new(:invalid)}
  defp not_found, do: {:error, Error.new(:not_found)}
  defp integrity_failure, do: {:error, Error.new(:integrity_failure)}
  defp unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
