defmodule Singularity.Storage.KnowledgeExport.ArtifactDirectory do
  @moduledoc "Private, identity-checked filesystem envelopes for temporary knowledge exports."

  import Bitwise, only: [band: 2]

  alias Singularity.Core.Error

  @context_keys [:root, :storage_root, :backup_root]
  @root_keys [:root, :identity]
  @operation_keys [:id, :path, :root, :root_identity, :identity, :marker_identity]
  @marker_keys ~w(format version operation_id root operation)
  @identity_keys ~w(major_device minor_device inode uid gid)
  @prefix "knowledge-export-"
  @format "singularity.knowledge-export-owner"
  @marker ".ownership"
  @marker_bytes 1_024

  def prepare(context) do
    with true <- exact_map?(context, @context_keys),
         true <- Enum.all?(Map.values(context), &canonical_absolute?/1),
         true <- disjoint?(context.root, context.storage_root),
         true <- disjoint?(context.root, context.backup_root),
         {:ok, storage} <- directory_chain(context.storage_root),
         {:ok, backup} <- directory_chain(context.backup_root),
         {:ok, existing, root_chain} <- prospective_root(context.root),
         true <- native_disjoint?(existing, root_chain, [storage, backup]),
         :ok <- existing_root_mode(existing),
         probe_parent = if(existing, do: context.root, else: Path.dirname(context.root)),
         guard = fn ->
           with :ok <- chains_valid([root_chain, storage, backup]),
                :ok <- existing_root_valid(context.root, existing),
                do: :ok
         end,
         {:ok, uid} <- probe_uid(probe_parent, guard),
         :ok <- existing_root_owner(existing, uid) do
      prepare_root(context.root, existing, root_chain, [storage, backup], uid)
    else
      {:error, %Error{}} = failure -> failure
      _ -> error(:invalid)
    end
  rescue
    _ -> error(:storage_unavailable)
  catch
    _, _ -> error(:storage_unavailable)
  end

  def create(root) do
    with true <- root_shape?(root),
         :ok <- owned_root(root),
         id = Ecto.UUID.generate(),
         path = Path.join(root.root, @prefix <> id),
         :ok <- root_valid(root),
         :ok <- File.mkdir(path) do
      case File.lstat(path) do
        {:ok, %{type: :directory} = stat} -> create_operation(root, id, path, stat)
        _ -> error(:storage_unavailable)
      end
    else
      {:error, %Error{}} = failure -> failure
      false -> error(:invalid)
      _ -> error(:storage_unavailable)
    end
  rescue
    _ -> error(:storage_unavailable)
  catch
    _, _ -> error(:storage_unavailable)
  end

  def cleanup(operation) do
    with true <- operation_shape?(operation),
         root = operation_root(operation),
         :ok <- owned_root(root) do
      case File.lstat(operation.path) do
        {:error, :enoent} -> :ok
        {:ok, _stat} -> cleanup_existing(operation)
        _ -> error(:integrity_failure)
      end
    else
      {:error, %Error{}} = failure -> failure
      _ -> error(:invalid)
    end
  rescue
    _ -> error(:integrity_failure)
  catch
    _, _ -> error(:integrity_failure)
  end

  def scavenge(root) do
    with true <- root_shape?(root),
         :ok <- owned_root(root),
         {:ok, names} <- File.ls(root.root) do
      Enum.reduce_while(names, {:ok, %{removed: 0, preserved: 0}}, fn name, {:ok, counts} ->
        with :ok <- root_valid(root) do
          case recognize(root, name) do
            {:ok, operation} ->
              case cleanup(operation) do
                :ok -> {:cont, {:ok, %{counts | removed: counts.removed + 1}}}
                {:error, %Error{}} = failure -> {:halt, failure}
              end

            :unrecognized ->
              {:cont, {:ok, %{counts | preserved: counts.preserved + 1}}}
          end
        else
          _ -> {:halt, error(:integrity_failure)}
        end
      end)
      |> finish_scavenge(root)
    else
      {:error, %Error{}} = failure -> failure
      false -> error(:invalid)
      _ -> error(:integrity_failure)
    end
  rescue
    _ -> error(:integrity_failure)
  catch
    _, _ -> error(:integrity_failure)
  end

  defp prepare_root(path, nil, parent_chain, protected, uid) do
    with :ok <- chains_valid([parent_chain | protected]),
         :ok <- File.mkdir(path) do
      case File.lstat(path) do
        {:ok, %{type: :directory} = created} ->
          result =
            with true <- created.uid == uid,
                 :ok <- chains_valid([parent_chain | protected]),
                 :ok <- same_entry(path, created, :directory),
                 :ok <- File.chmod(path, 0o700),
                 {:ok, chain} <- directory_chain(path),
                 current = chain |> List.last() |> elem(1),
                 true <- identity(current) == identity(created),
                 true <- private_mode?(current, 0o700) and current.uid == uid,
                 true <- native_disjoint?(current, chain, protected),
                 :ok <- chains_valid([parent_chain | protected]),
                 :ok <- root_valid(%{root: path, identity: identity(current)}) do
              {:ok, %{root: path, identity: identity(current)}}
            else
              _ -> error(:storage_unavailable)
            end

          if match?({:error, _}, result) and created.uid == uid do
            remove_created_root(path, created, parent_chain)
          end

          result

        _ ->
          error(:storage_unavailable)
      end
    else
      _ -> error(:storage_unavailable)
    end
  end

  defp prepare_root(path, existing, chain, protected, uid) do
    with :ok <- chains_valid([chain | protected]),
         :ok <- existing_root_valid(path, existing),
         true <- existing.uid == uid and private_mode?(existing, 0o700),
         true <- native_disjoint?(existing, chain, protected) do
      {:ok, %{root: path, identity: identity(existing)}}
    else
      _ -> error(:invalid)
    end
  end

  defp prospective_root(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        with {:ok, chain} <- directory_chain(path) do
          {:ok, chain |> List.last() |> elem(1), chain}
        end

      {:error, :enoent} ->
        with {:ok, chain} <- directory_chain(Path.dirname(path)), do: {:ok, nil, chain}

      _ ->
        error(:invalid)
    end
  end

  defp existing_root_mode(nil), do: :ok

  defp existing_root_mode(stat),
    do: if(private_mode?(stat, 0o700), do: :ok, else: error(:invalid))

  defp existing_root_owner(nil, _uid), do: :ok
  defp existing_root_owner(%{uid: uid}, uid), do: :ok
  defp existing_root_owner(_stat, _uid), do: error(:invalid)

  defp existing_root_valid(_path, nil), do: :ok
  defp existing_root_valid(path, stat), do: root_valid(%{root: path, identity: identity(stat)})

  defp native_disjoint?(root_stat, root_chain, protected) do
    Enum.all?(protected, fn protected_chain ->
      protected_stat = protected_chain |> List.last() |> elem(1)

      not Enum.any?(root_chain, fn {_path, stat} ->
        native_identity(stat) == native_identity(protected_stat)
      end) and
        (is_nil(root_stat) or
           not Enum.any?(protected_chain, fn {_path, stat} ->
             native_identity(stat) == native_identity(root_stat)
           end))
    end)
  end

  defp owned_root(root) do
    with :ok <- root_valid(root),
         {:ok, uid} <- probe_uid(root.root, fn -> root_valid(root) end),
         true <- uid == elem(root.identity, 3),
         :ok <- root_valid(root) do
      :ok
    else
      _ -> error(:integrity_failure)
    end
  end

  defp root_valid(root) do
    with {:ok, chain} <- directory_chain(root.root),
         stat = chain |> List.last() |> elem(1),
         true <- private_mode?(stat, 0o700),
         true <- identity(stat) == root.identity do
      :ok
    else
      _ -> error(:integrity_failure)
    end
  end

  defp probe_uid(parent, guard) do
    path = Path.join(parent, ".knowledge-export-owner-probe-" <> Ecto.UUID.generate())

    case exclusive_file(path, "", guard) do
      {:ok, stat} ->
        with :ok <- remove_recorded_file(path, identity(stat), guard), do: {:ok, stat.uid}

      {:error, recorded} ->
        if recorded, do: remove_recorded_file(path, recorded, guard)
        error(:storage_unavailable)
    end
  end

  defp create_operation(root, id, path, created) do
    operation = %{
      id: id,
      path: path,
      root: root.root,
      root_identity: root.identity,
      identity: identity(created),
      marker_identity: nil
    }

    guard = fn -> operation_valid(operation, false) end

    result =
      with true <- created.uid == elem(root.identity, 3),
           :ok <- root_valid(root),
           :ok <- same_entry(path, created, :directory),
           :ok <- File.chmod(path, 0o700),
           :ok <- guard.(),
           {:ok, encoded} <- Jason.encode(marker_value(operation)),
           true <- byte_size(encoded) <= @marker_bytes do
        case exclusive_file(Path.join(path, @marker), encoded, guard) do
          {:ok, marker_stat} ->
            complete = %{operation | marker_identity: identity(marker_stat)}

            case validate_operation(complete) do
              :ok ->
                {:ok, complete}

              _ ->
                cleanup_created(complete)
                error(:storage_unavailable)
            end

          {:error, recorded} ->
            cleanup_created(%{operation | marker_identity: recorded})
            error(:storage_unavailable)
        end
      else
        _ ->
          cleanup_created(operation)
          error(:storage_unavailable)
      end

    result
  rescue
    _ ->
      cleanup_created(%{
        id: id,
        path: path,
        root: root.root,
        root_identity: root.identity,
        identity: identity(created),
        marker_identity: nil
      })

      error(:storage_unavailable)
  end

  defp exclusive_file(path, bytes, guard) do
    with :ok <- guard.(),
         {:ok, device} <-
           :file.open(String.to_charlist(path), [:read, :write, :binary, :raw, :exclusive]) do
      # The exclusive descriptor, not a subsequent pathname alone, is the
      # creation receipt used for both publication and partial-failure cleanup.
      case descriptor_stat(device) do
        {:ok, %{type: :regular} = created} ->
          result =
            try do
              with :ok <- guard.(),
                   :ok <- same_entry(path, created, :regular),
                   true <- created.size == 0,
                   :ok <- File.chmod(path, 0o600),
                   :ok <- same_entry(path, created, :regular),
                   :ok <- :file.write(device, bytes),
                   {:ok, current} <- descriptor_stat(device),
                   true <- identity(current) == identity(created),
                   true <- current.type == :regular and private_mode?(current, 0o600),
                   true <- current.size == byte_size(bytes),
                   :ok <- same_regular_file(path, current),
                   :ok <- guard.() do
                {:ok, current}
              else
                _ -> {:error, identity(created)}
              end
            rescue
              _ -> {:error, identity(created)}
            catch
              _, _ -> {:error, identity(created)}
            end

          case :file.close(device) do
            :ok -> result
            _ -> {:error, identity(created)}
          end

        _ ->
          :file.close(device)
          {:error, nil}
      end
    else
      _ -> {:error, nil}
    end
  end

  defp descriptor_stat(device) do
    case :file.read_file_info(device) do
      {:ok,
       {:file_info, size, type, _access, _atime, _mtime, _ctime, mode, _links, major, minor,
        inode, uid, gid}} ->
        {:ok,
         %{
           size: size,
           type: type,
           mode: mode,
           major_device: major,
           minor_device: minor,
           inode: inode,
           uid: uid,
           gid: gid
         }}

      _ ->
        error(:integrity_failure)
    end
  end

  defp same_regular_file(path, original) do
    with {:ok, %{type: :regular} = stat} <- File.lstat(path),
         true <- identity(stat) == identity(original),
         true <- stat.size == original.size,
         true <- private_mode?(stat, 0o600) do
      :ok
    else
      _ -> error(:integrity_failure)
    end
  end

  defp operation_valid(operation, marker?) do
    with :ok <- root_valid(operation_root(operation)),
         {:ok, %{type: :directory} = stat} <- File.lstat(operation.path),
         true <- identity(stat) == operation.identity,
         true <- private_mode?(stat, 0o700),
         true <- stat.uid == elem(operation.root_identity, 3) do
      if marker?, do: marker_identity_valid(operation), else: :ok
    else
      _ -> error(:integrity_failure)
    end
  end

  defp marker_identity_valid(operation) do
    with {:ok, %{type: :regular} = stat} <- File.lstat(Path.join(operation.path, @marker)),
         true <- identity(stat) == operation.marker_identity,
         true <- private_mode?(stat, 0o600),
         true <- stat.uid == elem(operation.identity, 3),
         true <- stat.size in 0..@marker_bytes do
      :ok
    else
      _ -> error(:integrity_failure)
    end
  end

  defp validate_operation(operation) do
    with :ok <- operation_valid(operation, true),
         {:ok, marker, marker_stat} <- read_marker(operation),
         true <- identity(marker_stat) == operation.marker_identity,
         true <- marker == marker_value(operation),
         :ok <- operation_valid(operation, true) do
      :ok
    else
      _ -> error(:integrity_failure)
    end
  end

  defp read_marker(operation) do
    path = Path.join(operation.path, @marker)

    with :ok <- operation_valid(operation, true),
         {:ok, %{type: :regular} = before_stat} <- File.lstat(path),
         {:ok, device} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      result =
        try do
          with {:ok, descriptor} <- descriptor_stat(device),
               true <- identity(descriptor) == identity(before_stat),
               true <- descriptor.type == :regular and private_mode?(descriptor, 0o600),
               true <- descriptor.size == before_stat.size,
               true <- descriptor.size in 1..@marker_bytes,
               :ok <- same_regular_file(path, descriptor),
               :ok <- operation_valid(operation, true),
               {:ok, bytes} <- :file.read(device, @marker_bytes + 1),
               true <- byte_size(bytes) == descriptor.size,
               :eof <- :file.read(device, 1),
               {:ok, after_descriptor} <- descriptor_stat(device),
               true <- identity(after_descriptor) == identity(descriptor),
               true <- after_descriptor.size == descriptor.size,
               true <- private_mode?(after_descriptor, 0o600),
               :ok <- same_regular_file(path, after_descriptor),
               :ok <- operation_valid(operation, true),
               {:ok, marker} <- decode_marker(bytes) do
            {:ok, marker, after_descriptor}
          else
            _ -> error(:integrity_failure)
          end
        rescue
          _ -> error(:integrity_failure)
        catch
          _, _ -> error(:integrity_failure)
        end

      case :file.close(device) do
        :ok -> result
        _ -> error(:integrity_failure)
      end
    else
      _ -> error(:integrity_failure)
    end
  end

  defp decode_marker(bytes) do
    with {:ok, %Jason.OrderedObject{values: fields}} <-
           Jason.decode(bytes, objects: :ordered_objects),
         true <- exact_fields?(fields, @marker_keys),
         marker = Map.new(fields),
         true <- marker["format"] == @format and marker["version"] === 1,
         true <- canonical_uuid?(marker["operation_id"]),
         {:ok, root} <- decode_identity(marker["root"]),
         {:ok, operation} <- decode_identity(marker["operation"]) do
      {:ok, %{marker | "root" => root, "operation" => operation}}
    else
      _ -> error(:integrity_failure)
    end
  end

  defp decode_identity(%Jason.OrderedObject{values: fields}) do
    if exact_fields?(fields, @identity_keys) and
         Enum.all?(fields, fn {_key, value} -> is_integer(value) and value >= 0 end) do
      {:ok, Map.new(fields)}
    else
      error(:integrity_failure)
    end
  end

  defp decode_identity(_other), do: error(:integrity_failure)

  defp exact_fields?(fields, expected) do
    # Ordered objects retain duplicate JSON keys, including escaped spellings.
    # Converting to a map before this check would silently discard that proof.
    length(fields) == length(expected) and
      Enum.sort(Enum.map(fields, &elem(&1, 0))) == Enum.sort(expected)
  end

  defp marker_value(operation) do
    %{
      "format" => @format,
      "version" => 1,
      "operation_id" => operation.id,
      "root" => identity_map(operation.root_identity),
      "operation" => identity_map(operation.identity)
    }
  end

  defp identity_map(value), do: Map.new(Enum.zip(@identity_keys, Tuple.to_list(value)))

  defp recognize(root, @prefix <> id = name) do
    path = Path.join(root.root, name)

    with true <- canonical_uuid?(id),
         {:ok, %{type: :directory} = stat} <- File.lstat(path),
         true <- private_mode?(stat, 0o700) and stat.uid == elem(root.identity, 3),
         {:ok, %{type: :regular} = marker_stat} <- File.lstat(Path.join(path, @marker)),
         operation = %{
           id: id,
           path: path,
           root: root.root,
           root_identity: root.identity,
           identity: identity(stat),
           marker_identity: identity(marker_stat)
         },
         :ok <- validate_operation(operation) do
      {:ok, operation}
    else
      _ -> :unrecognized
    end
  end

  defp recognize(_root, _name), do: :unrecognized

  defp cleanup_existing(operation) do
    with :ok <- validate_operation(operation),
         :ok <-
           remove_contents(
             operation,
             operation.path,
             [{operation.path, operation.identity}],
             true
           ),
         :ok <- operation_valid(operation, true),
         {:ok, [@marker]} <- File.ls(operation.path),
         :ok <-
           remove_recorded_file(
             Path.join(operation.path, @marker),
             operation.marker_identity,
             fn -> operation_valid(operation, true) end
           ),
         :ok <- operation_valid(operation, false),
         {:ok, []} <- File.ls(operation.path),
         :ok <- operation_valid(operation, false),
         :ok <- File.rmdir(operation.path) do
      :ok
    else
      _ -> error(:integrity_failure)
    end
  end

  defp remove_contents(operation, directory, parents, top?) do
    with :ok <- deletion_guard(operation, parents),
         {:ok, names} <- File.ls(directory) do
      names
      |> Enum.reject(&(top? and &1 == @marker))
      |> Enum.reduce_while(:ok, fn name, :ok ->
        with true <- safe_leaf?(name),
             :ok <- deletion_guard(operation, parents),
             path = Path.join(directory, name),
             {:ok, stat} <- File.lstat(path),
             true <- stat.uid == elem(operation.identity, 3),
             :ok <- remove_child(operation, path, stat, parents) do
          {:cont, :ok}
        else
          _ -> {:halt, error(:integrity_failure)}
        end
      end)
    else
      _ -> error(:integrity_failure)
    end
  end

  defp remove_child(operation, path, %{type: :directory} = stat, parents) do
    nested = parents ++ [{path, identity(stat)}]

    with :ok <- remove_contents(operation, path, nested, false),
         :ok <- deletion_guard(operation, nested),
         :ok <- File.rmdir(path) do
      :ok
    else
      _ -> error(:integrity_failure)
    end
  end

  defp remove_child(operation, path, stat, parents) do
    with :ok <- deletion_guard(operation, parents),
         :ok <- same_entry(path, stat, stat.type),
         :ok <- File.rm(path) do
      :ok
    else
      _ -> error(:integrity_failure)
    end
  end

  defp deletion_guard(operation, parents) do
    # These are identity rechecks inside the validated private owner root, not
    # an atomic openat-style guarantee against a hostile process with its uid.
    with :ok <- operation_valid(operation, true),
         true <-
           Enum.all?(parents, fn {path, expected} ->
             case File.lstat(path) do
               {:ok, %{type: :directory} = stat} -> identity(stat) == expected
               _ -> false
             end
           end) do
      :ok
    else
      _ -> error(:integrity_failure)
    end
  end

  defp cleanup_created(operation) do
    guard = fn ->
      with :ok <- root_valid(operation_root(operation)),
           {:ok, %{type: :directory} = stat} <- File.lstat(operation.path),
           true <- identity(stat) == operation.identity,
           true <- stat.uid == elem(operation.root_identity, 3) do
        :ok
      else
        _ -> error(:integrity_failure)
      end
    end

    if not is_nil(operation.marker_identity) and
         elem(operation.marker_identity, 3) == elem(operation.root_identity, 3) do
      remove_recorded_file(Path.join(operation.path, @marker), operation.marker_identity, guard)
    end

    with :ok <- guard.(), do: File.rmdir(operation.path)
  rescue
    _ -> error(:integrity_failure)
  end

  defp remove_created_root(path, created, parents) do
    with :ok <- chains_valid([parents]),
         :ok <- same_entry(path, created, :directory),
         {:ok, []} <- File.ls(path),
         :ok <- chains_valid([parents]),
         :ok <- same_entry(path, created, :directory) do
      File.rmdir(path)
    end
  end

  defp remove_recorded_file(path, expected, guard) do
    with :ok <- guard.(),
         {:ok, %{type: :regular} = stat} <- File.lstat(path),
         true <- identity(stat) == expected,
         :ok <- guard.(),
         :ok <- same_entry(path, stat, :regular),
         :ok <- File.rm(path) do
      :ok
    else
      _ -> error(:integrity_failure)
    end
  end

  defp finish_scavenge({:ok, counts}, root) do
    with :ok <- root_valid(root), do: {:ok, counts}
  end

  defp finish_scavenge({:error, %Error{}} = failure, _root), do: failure

  defp same_entry(path, original, type) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == type and identity(stat) == identity(original) do
      :ok
    else
      _ -> error(:integrity_failure)
    end
  end

  defp directory_chain(path) do
    path
    |> ancestors()
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, chain} ->
      case File.lstat(part) do
        {:ok, %{type: :directory} = stat} -> {:cont, {:ok, [{part, stat} | chain]}}
        _ -> {:halt, error(:invalid)}
      end
    end)
    |> case do
      {:ok, chain} -> {:ok, Enum.reverse(chain)}
      failure -> failure
    end
  end

  defp ancestors("/"), do: ["/"]
  defp ancestors(path), do: ancestors(Path.dirname(path)) ++ [path]

  defp chains_valid(chains) do
    if Enum.all?(chains, fn chain ->
         Enum.all?(chain, fn {path, stat} -> same_entry(path, stat, :directory) == :ok end)
       end) do
      :ok
    else
      error(:integrity_failure)
    end
  end

  defp root_shape?(root) do
    exact_map?(root, @root_keys) and canonical_absolute?(root.root) and
      valid_identity?(root.identity)
  end

  defp operation_shape?(operation) do
    exact_map?(operation, @operation_keys) and canonical_absolute?(operation.root) and
      canonical_uuid?(operation.id) and is_binary(operation.path) and
      operation.path == Path.join(operation.root, @prefix <> operation.id) and
      valid_identity?(operation.root_identity) and valid_identity?(operation.identity) and
      valid_identity?(operation.marker_identity)
  end

  defp operation_root(operation), do: %{root: operation.root, identity: operation.root_identity}

  defp exact_map?(value, keys) do
    is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)
  end

  defp valid_identity?(value) do
    is_tuple(value) and tuple_size(value) == 5 and
      Enum.all?(Tuple.to_list(value), &(is_integer(&1) and &1 >= 0))
  end

  defp identity(stat), do: {stat.major_device, stat.minor_device, stat.inode, stat.uid, stat.gid}
  defp native_identity(stat), do: {stat.major_device, stat.minor_device, stat.inode}
  defp private_mode?(stat, mode), do: band(stat.mode, 0o7777) == mode

  defp canonical_absolute?(path) do
    is_binary(path) and Path.type(path) == :absolute and path != "/" and
      not String.contains?(path, <<0>>) and Path.expand(path) == path
  end

  defp canonical_uuid?(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, ^id} -> id == String.downcase(id)
      _ -> false
    end
  end

  defp canonical_uuid?(_id), do: false

  defp disjoint?(left, right) do
    left != right and not String.starts_with?(left, right <> "/") and
      not String.starts_with?(right, left <> "/")
  end

  defp safe_leaf?(name),
    do: is_binary(name) and name not in ["", ".", ".."] and Path.basename(name) == name

  defp error(code), do: {:error, Error.new(code)}
end
