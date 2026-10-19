defmodule Singularity.Storage.KnowledgeExport.ArtifactDirectoryTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error

  @moduletag :tmp_dir
  @directory Singularity.Storage.KnowledgeExport.ArtifactDirectory
  @identity_keys ~w(major_device minor_device inode uid gid)
  @format "singularity.knowledge-export-owner"
  @canary "private-artifact-directory-canary"

  setup %{tmp_dir: tmp} do
    context =
      Map.new([:root, :storage_root, :backup_root], fn key ->
        path = Path.join(tmp, Atom.to_string(key))
        File.mkdir!(path)
        File.chmod!(path, 0o700)
        {key, path}
      end)

    sentinel = Path.join(context.root, "foreign-sentinel")
    File.write!(sentinel, @canary)
    outside = Path.join(tmp, "outside-sentinel")
    File.write!(outside, @canary)
    %{context: context, sentinel: sentinel, outside: outside}
  end

  test "prepare returns only the canonical root and all five native identity fields", c do
    assert {:ok, root} = call(:prepare, [c.context])
    assert root == %{root: c.context.root, identity: identity(c.context.root)}
    assert File.ls!(c.context.root) == ["foreign-sentinel"]
    assert File.read!(c.sentinel) == @canary
    assert_mode(c.context.root, 0o700)
  end

  test "prepare creates only an absent dedicated root beneath an existing parent", c do
    root = Path.join(c.tmp_dir, "absent-export-root")
    assert {:ok, prepared} = call(:prepare, [%{c.context | root: root}])
    assert prepared == %{root: root, identity: identity(root)}
    assert_mode(root, 0o700)
    assert File.ls!(root) == []
    assert File.read!(c.sentinel) == @canary
    assert File.read!(c.outside) == @canary
  end

  test "prepare rejects a missing export parent without recursive directory creation", c do
    parent = Path.join(c.tmp_dir, "absent-parent")
    assert_error(call(:prepare, [%{c.context | root: Path.join(parent, "export")}]))
    refute File.exists?(parent)
    assert File.read!(c.sentinel) == @canary
  end

  for key <- [:storage_root, :backup_root] do
    test "prepare never creates missing protected #{key}", c do
      missing = Path.join(c.tmp_dir, "absent-#{unquote(key)}")
      before = File.lstat!(c.context.root)
      assert_error(call(:prepare, [Map.put(c.context, unquote(key), missing)]))
      refute File.exists?(missing)
      assert identity(c.context.root) == identity(before)
      assert_mode(c.context.root, 0o700)
      assert File.ls!(c.context.root) == ["foreign-sentinel"]
    end
  end

  test "prepare rejects nonplain or nonexact trusted context shapes", c do
    for context <- [
          nil,
          [],
          c.context.root,
          %{},
          Map.delete(c.context, :backup_root),
          Map.put(c.context, :extra, :ignored),
          Map.put(c.context, :uid, 0),
          Map.put(c.context, :__struct__, __MODULE__)
        ] do
      assert_error(call(:prepare, [context]))
    end

    assert File.ls!(c.context.root) == ["foreign-sentinel"]
  end

  for key <- [:root, :storage_root, :backup_root] do
    test "prepare rejects noncanonical or invalid #{key} paths without changing roots", c do
      original = Map.fetch!(c.context, unquote(key))

      for path <- [
            nil,
            7,
            "relative",
            "/",
            original <> "/",
            original <> "/.",
            original <> "/../" <> Path.basename(original),
            original <> <<0>>
          ] do
        assert_error(call(:prepare, [Map.put(c.context, unquote(key), path)]))
      end

      for path <- Map.values(c.context), do: assert_mode(path, 0o700)
      assert File.read!(c.sentinel) == @canary
    end

    test "prepare rejects a symlink #{key} leaf rather than following its target", c do
      link = Path.join(c.tmp_dir, "linked-#{unquote(key)}")
      File.ln_s!(Map.fetch!(c.context, unquote(key)), link)
      assert_error(call(:prepare, [Map.put(c.context, unquote(key), link)]))
      assert File.lstat!(link).type == :symlink
      assert File.read!(c.sentinel) == @canary
    end

    test "prepare rejects a symlink ancestor in #{key}", c do
      link = Path.join(c.tmp_dir, "linked-parent-#{unquote(key)}")
      File.ln_s!(c.tmp_dir, link)
      path = Path.join(link, Path.basename(Map.fetch!(c.context, unquote(key))))
      assert_error(call(:prepare, [Map.put(c.context, unquote(key), path)]))
      assert File.lstat!(link).type == :symlink
      assert File.read!(c.outside) == @canary
    end

    test "prepare rejects a regular-file ancestor in #{key}", c do
      path = Path.join(c.outside, "child")
      assert_error(call(:prepare, [Map.put(c.context, unquote(key), path)]))
      assert File.read!(c.outside) == @canary
    end
  end

  for key <- [:storage_root, :backup_root] do
    test "prepare rejects an export root equal to #{key}", c do
      protected = Map.fetch!(c.context, unquote(key))
      assert_error(call(:prepare, [%{c.context | root: protected}]))
      assert File.ls!(protected) == []
      assert_mode(protected, 0o700)
    end

    test "prepare rejects an export root nested inside #{key}", c do
      nested = Path.join(Map.fetch!(c.context, unquote(key)), "nested-export")
      assert_error(call(:prepare, [%{c.context | root: nested}]))
      refute File.exists?(nested)
    end

    test "prepare rejects #{key} nested inside the export root", c do
      nested = Path.join(c.context.root, "nested-protected")
      File.mkdir!(nested)
      File.chmod!(nested, 0o700)
      sentinel = Path.join(nested, "protected-sentinel")
      File.write!(sentinel, @canary)
      assert_error(call(:prepare, [Map.put(c.context, unquote(key), nested)]))
      assert File.read!(sentinel) == @canary
      assert File.read!(c.sentinel) == @canary
    end
  end

  test "lexically similar sibling names are disjoint rather than ancestor matches", c do
    root = c.context.storage_root <> "-export"
    assert {:ok, prepared} = call(:prepare, [%{c.context | root: root}])
    assert prepared.root == root
    assert File.ls!(c.context.storage_root) == []
  end

  for mode <- [0o755, 0o770, 0o1700] do
    test "prepare rejects existing export mode #{mode} without chmod repair", c do
      fixture_mode!(c.context.root, unquote(mode))
      assert_error(call(:prepare, [c.context]))
      assert_mode(c.context.root, unquote(mode))
      assert File.read!(c.sentinel) == @canary
    end
  end

  test "create returns an exclusive canonical UUID envelope with its marker already written", c do
    root = prepare(c)
    assert {:ok, operation} = call(:create, [root])

    assert Enum.sort(Map.keys(operation)) ==
             Enum.sort([:id, :path, :root, :root_identity, :identity, :marker_identity])

    assert operation.id =~ ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
    assert Ecto.UUID.cast(operation.id) == {:ok, operation.id}
    assert operation.path == Path.join(root.root, "knowledge-export-" <> operation.id)
    assert operation.root == root.root
    assert operation.root_identity == root.identity
    assert operation.identity == identity(operation.path)
    assert operation.marker_identity == identity(marker_path(operation))
    assert File.ls!(operation.path) == [".ownership"]
    assert_mode(operation.path, 0o700)
    assert_mode(marker_path(operation), 0o600)
    encoded = File.read!(marker_path(operation))
    assert byte_size(encoded) <= 1_024
    assert Jason.decode!(encoded) == expected_marker(operation)
    refute encoded =~ @canary
    refute encoded =~ c.tmp_dir
    assert :ok = call(:cleanup, [operation])
  end

  test "two independently created operations have distinct native identities and markers", c do
    root = prepare(c)
    {:ok, one} = call(:create, [root])
    {:ok, two} = call(:create, [root])
    refute one.id == two.id
    refute one.path == two.path
    refute one.identity == two.identity
    refute one.marker_identity == two.marker_identity
    assert Jason.decode!(File.read!(marker_path(one))) == expected_marker(one)
    assert Jason.decode!(File.read!(marker_path(two))) == expected_marker(two)
    assert :ok = call(:cleanup, [one])
    assert File.dir?(two.path)
    assert :ok = call(:cleanup, [two])
    assert File.read!(c.sentinel) == @canary
  end

  test "create rejects invalid prepared descriptors without filesystem effects", c do
    root = prepare(c)

    for descriptor <- [
          nil,
          %{},
          Map.put(root, :extra, true),
          Map.put(root, :__struct__, __MODULE__),
          %{root | root: c.context.storage_root},
          %{root | identity: {0, 0, 0, 0, 0}}
        ] do
      assert_error(call(:create, [descriptor]))
    end

    assert File.ls!(c.context.root) == ["foreign-sentinel"]
    assert File.ls!(c.context.storage_root) == []
  end

  test "create refuses a replaced root inode and preserves its replacement sentinel", c do
    root = prepare(c)
    retained = c.context.root <> "-retained"
    File.rename!(c.context.root, retained)
    File.mkdir!(c.context.root)
    File.chmod!(c.context.root, 0o700)
    replacement = Path.join(c.context.root, "replacement-sentinel")
    File.write!(replacement, @canary)
    assert_error(call(:create, [root]), :integrity_failure)
    assert File.ls!(c.context.root) == ["replacement-sentinel"]
    assert File.read!(Path.join(retained, "foreign-sentinel")) == @canary
  end

  test "cleanup is idempotent and preserves foreign siblings and the other operation", c do
    root = prepare(c)
    {:ok, operation} = call(:create, [root])
    {:ok, other} = call(:create, [root])
    File.write!(Path.join(operation.path, "content"), @canary)
    other_sentinel = Path.join(other.path, "other-sentinel")
    File.write!(other_sentinel, @canary)
    assert :ok = call(:cleanup, [operation])
    assert :ok = call(:cleanup, [operation])
    refute File.exists?(operation.path)
    assert File.read!(other_sentinel) == @canary
    assert File.read!(c.sentinel) == @canary
    assert File.read!(c.outside) == @canary
    assert :ok = call(:cleanup, [other])
  end

  test "cleanup removes nested own content without following file or directory symlink leaves",
       c do
    operation = create(c)
    nested = Path.join(operation.path, "nested")
    File.mkdir!(nested)
    File.mkdir!(Path.join(nested, "empty"))
    File.write!(Path.join(nested, "content"), @canary)
    File.ln_s!(c.outside, Path.join(nested, "file-link"))
    File.ln_s!(c.context.storage_root, Path.join(nested, "directory-link"))
    protected = Path.join(c.context.storage_root, "protected-sentinel")
    File.write!(protected, @canary)
    assert :ok = call(:cleanup, [operation])
    refute File.exists?(operation.path)
    assert File.read!(c.outside) == @canary
    assert File.read!(protected) == @canary
  end

  test "cleanup unlinks a dangling symlink leaf rather than treating it as an absent entry", c do
    operation = create(c)
    File.ln_s!(Path.join(c.tmp_dir, "missing-target"), Path.join(operation.path, "dangling"))
    assert :ok = call(:cleanup, [operation])
    refute File.exists?(operation.path)
    refute File.exists?(Path.join(c.tmp_dir, "missing-target"))
  end

  test "cleanup rejects replaced root identity without deleting either owned or replacement tree",
       c do
    operation = create(c)
    retained = c.context.root <> "-retained"
    File.rename!(c.context.root, retained)
    File.mkdir!(c.context.root)
    File.chmod!(c.context.root, 0o700)
    File.write!(Path.join(c.context.root, "replacement"), @canary)
    assert_error(call(:cleanup, [operation]), :integrity_failure)
    assert File.read!(Path.join(c.context.root, "replacement")) == @canary
    assert File.exists?(Path.join([retained, Path.basename(operation.path), ".ownership"]))
  end

  test "cleanup rejects replaced operation inode and retains both original and questionable trees",
       c do
    operation = create(c)
    retained = operation.path <> "-retained"
    File.rename!(operation.path, retained)
    File.mkdir!(operation.path)
    File.chmod!(operation.path, 0o700)
    File.write!(Path.join(operation.path, "replacement"), @canary)
    assert_error(call(:cleanup, [operation]), :integrity_failure)
    assert File.read!(Path.join(operation.path, "replacement")) == @canary
    assert File.exists?(Path.join(retained, ".ownership"))
  end

  test "cleanup rejects operation replacement with a symlink without following it", c do
    operation = create(c)
    File.rename!(operation.path, operation.path <> "-retained")
    File.ln_s!(c.context.storage_root, operation.path)
    protected = Path.join(c.context.storage_root, "protected-sentinel")
    File.write!(protected, @canary)
    assert_error(call(:cleanup, [operation]), :integrity_failure)
    assert File.lstat!(operation.path).type == :symlink
    assert File.read!(protected) == @canary
  end

  test "cleanup rejects marker inode replacement even when JSON bytes are identical", c do
    operation = create(c)
    marker = marker_path(operation)
    bytes = File.read!(marker)
    File.rename!(marker, marker <> "-retained")
    File.write!(marker, bytes)
    File.chmod!(marker, 0o600)
    assert_error(call(:cleanup, [operation]), :integrity_failure)
    assert File.read!(marker) == bytes
    assert File.read!(marker <> "-retained") == bytes
  end

  test "cleanup rejects a symlink marker and preserves the target", c do
    operation = create(c)
    marker = marker_path(operation)
    File.rename!(marker, marker <> "-retained")
    File.ln_s!(c.outside, marker)
    assert_error(call(:cleanup, [operation]), :integrity_failure)
    assert File.lstat!(marker).type == :symlink
    assert File.read!(c.outside) == @canary
  end

  test "cleanup refuses a missing marker and preserves unproven content", c do
    operation = create(c)
    content = Path.join(operation.path, "content")
    File.write!(content, @canary)
    File.rm!(marker_path(operation))
    assert_error(call(:cleanup, [operation]), :integrity_failure)
    assert File.read!(content) == @canary
    assert File.read!(c.sentinel) == @canary
  end

  for field <- [:root_identity, :identity, :marker_identity], index <- 0..4 do
    test "cleanup rejects forged #{field} component #{index} rather than deleting", c do
      operation = create(c)

      forged =
        Map.update!(operation, unquote(field), fn tuple ->
          put_elem(tuple, unquote(index), elem(tuple, unquote(index)) + 1)
        end)

      assert_error(call(:cleanup, [forged]), :integrity_failure)
      assert Jason.decode!(File.read!(marker_path(operation))) == expected_marker(operation)
      assert File.read!(c.sentinel) == @canary
    end
  end

  test "cleanup rejects descriptor paths or ids outside the exact own UUID envelope", c do
    operation = create(c)
    other = create(c)

    for descriptor <- [
          %{operation | root: c.context.storage_root},
          %{operation | path: c.context.storage_root},
          %{operation | path: operation.path <> "/.."},
          %{operation | path: other.path},
          %{operation | id: other.id},
          %{operation | id: "00000000-0000-4000-8000-00000000000A"},
          %{operation | id: "../foreign-sentinel"},
          Map.put(operation, :extra, true),
          Map.put(operation, :__struct__, __MODULE__)
        ] do
      assert_error(call(:cleanup, [descriptor]))
      assert File.exists?(marker_path(operation))
      assert File.exists?(marker_path(other))
      assert File.read!(c.sentinel) == @canary
    end
  end

  for target <- [:operation, :marker], mode <- [0o755, 0o1700] do
    test "cleanup rejects insecure #{target} mode #{mode} without repairing it", c do
      operation = create(c)
      target = if unquote(target) == :operation, do: operation.path, else: marker_path(operation)
      fixture_mode!(target, unquote(mode))
      assert_error(call(:cleanup, [operation]), :integrity_failure)
      assert_mode(target, unquote(mode))
      assert File.exists?(marker_path(operation))
    end
  end

  test "cleanup rejects an insecure root without chmod repair", c do
    operation = create(c)
    File.chmod!(c.context.root, 0o755)
    assert_error(call(:cleanup, [operation]), :integrity_failure)
    assert_mode(c.context.root, 0o755)
    assert File.exists?(marker_path(operation))
  end

  for mutation <- [
        :format,
        :version,
        :operation_id,
        :extra,
        :missing,
        :root_extra,
        :operation_extra,
        :root_missing,
        :operation_missing,
        :root_uid,
        :operation_uid,
        :root_gid,
        :operation_gid,
        :root_device,
        :operation_device,
        :root_minor,
        :operation_minor,
        :root_inode,
        :operation_inode,
        :integer_type
      ] do
    test "cleanup rejects exact marker schema mutation #{mutation} and preserves content", c do
      operation = create(c)
      marker = expected_marker(operation) |> mutate_marker(unquote(mutation))
      File.write!(marker_path(operation), Jason.encode!(marker))
      assert_error(call(:cleanup, [operation]), :integrity_failure)
      assert Jason.decode!(File.read!(marker_path(operation))) == marker
      assert File.read!(c.sentinel) == @canary
    end
  end

  for encoded <- ["not-json", "[]", "null", String.duplicate("x", 1_025)] do
    test "cleanup rejects malformed or oversized marker #{inspect(binary_part(encoded, 0, min(10, byte_size(encoded))))}",
         c do
      operation = create(c)
      File.write!(marker_path(operation), unquote(encoded))
      assert_error(call(:cleanup, [operation]), :integrity_failure)
      assert File.read!(marker_path(operation)) == unquote(encoded)
    end
  end

  test "cleanup rejects duplicate top-level JSON keys even when ordinary decoder looks valid",
       c do
    operation = create(c)
    encoded = Jason.encode!(expected_marker(operation))
    duplicate = "{\"format\":\"#{@format}\"," <> binary_part(encoded, 1, byte_size(encoded) - 1)
    assert Jason.decode!(duplicate) == expected_marker(operation)
    File.write!(marker_path(operation), duplicate)
    assert_error(call(:cleanup, [operation]), :integrity_failure)
    assert File.read!(marker_path(operation)) == duplicate
  end

  test "cleanup rejects duplicate nested identity keys even when ordinary decoder looks valid",
       c do
    operation = create(c)
    marker = expected_marker(operation)
    encoded = Jason.encode!(marker)
    root = Jason.encode!(marker["root"])

    duplicate_root =
      "{\"uid\":#{marker["root"]["uid"]}," <> binary_part(root, 1, byte_size(root) - 1)

    duplicate = String.replace(encoded, "\"root\":" <> root, "\"root\":" <> duplicate_root)
    refute duplicate == encoded
    assert Jason.decode!(duplicate) == marker
    File.write!(marker_path(operation), duplicate)
    assert_error(call(:cleanup, [operation]), :integrity_failure)
    assert File.read!(marker_path(operation)) == duplicate
  end

  for encoding <- [:pretty, :reordered] do
    test "cleanup accepts exact marker schema with #{encoding} JSON encoding", c do
      operation = create(c)
      marker = expected_marker(operation)

      encoded =
        case unquote(encoding) do
          :pretty ->
            Jason.encode!(marker, pretty: true)

          :reordered ->
            fields = marker |> Enum.sort() |> Enum.reverse()

            "{" <>
              Enum.map_join(fields, ",", fn {key, value} ->
                Jason.encode!(key) <> ":" <> Jason.encode!(value)
              end) <> "}"
        end

      assert byte_size(encoded) <= 1_024
      assert Jason.decode!(encoded) == marker
      File.write!(marker_path(operation), encoded)
      assert :ok = call(:cleanup, [operation])
      refute File.exists?(operation.path)
      assert File.read!(c.sentinel) == @canary
    end
  end

  test "scavenge removes a recognized immediate leftover and returns counts without paths", c do
    root = prepare(c)
    {:ok, operation} = call(:create, [root])
    File.write!(Path.join(operation.path, "partial-content"), @canary)
    assert {:ok, %{removed: 1, preserved: 1}} = call(:scavenge, [root])
    refute File.exists?(operation.path)
    assert File.read!(c.sentinel) == @canary
    assert {:ok, %{removed: 0, preserved: 1}} = call(:scavenge, [root])
  end

  test "scavenge does not recursively discover a recognized operation below a foreign directory",
       c do
    root = prepare(c)
    {:ok, operation} = call(:create, [root])
    foreign = Path.join(root.root, "foreign-directory")
    File.mkdir!(foreign)
    nested = Path.join(foreign, Path.basename(operation.path))
    File.rename!(operation.path, nested)
    assert {:ok, %{removed: 0, preserved: 2}} = call(:scavenge, [root])
    assert File.exists?(Path.join(nested, ".ownership"))
    assert File.read!(c.sentinel) == @canary
  end

  test "scavenge preserves unrecognized UUID names, prefix-only directories and symlinks", c do
    root = prepare(c)

    names = [
      "knowledge-export-not-a-uuid",
      "knowledge-export-" <> Ecto.UUID.generate(),
      "knowledge-export-00000000-0000-4000-8000-00000000000A",
      "unrelated"
    ]

    for name <- names do
      path = Path.join(root.root, name)
      File.mkdir!(path)
      File.chmod!(path, 0o700)
      File.write!(Path.join(path, "sentinel"), @canary)
    end

    link = Path.join(root.root, "knowledge-export-" <> Ecto.UUID.generate())
    File.ln_s!(c.context.storage_root, link)
    assert {:ok, %{removed: 0, preserved: 6}} = call(:scavenge, [root])
    for name <- names, do: assert(File.read!(Path.join([root.root, name, "sentinel"])) == @canary)
    assert File.lstat!(link).type == :symlink
    assert File.read!(c.sentinel) == @canary
  end

  for kind <- [
        :malformed,
        :oversized,
        :wrong_uid,
        :wrong_gid,
        :wrong_inode,
        :wrong_root,
        :extra_key,
        :duplicate_key,
        :missing_marker,
        :symlink_marker,
        :insecure_operation,
        :insecure_marker
      ] do
    test "scavenge preserves unrecognized candidate #{kind} without calling it removed", c do
      root = prepare(c)
      {:ok, operation} = call(:create, [root])
      make_unrecognized(operation, unquote(kind), c)
      assert {:ok, %{removed: 0, preserved: 2}} = call(:scavenge, [root])
      assert File.dir?(operation.path)
      assert File.read!(c.sentinel) == @canary
      assert File.read!(c.outside) == @canary
    end
  end

  test "scavenge removes separate recognized operations but preserves external symlink targets",
       c do
    root = prepare(c)
    {:ok, one} = call(:create, [root])
    {:ok, two} = call(:create, [root])
    File.ln_s!(c.outside, Path.join(one.path, "outside-link"))
    File.write!(Path.join(two.path, "partial"), @canary)
    assert {:ok, %{removed: 2, preserved: 1}} = call(:scavenge, [root])
    refute File.exists?(one.path)
    refute File.exists?(two.path)
    assert File.read!(c.sentinel) == @canary
    assert File.read!(c.outside) == @canary
  end

  test "scavenge rejects a replaced root identity without touching its new children", c do
    root = prepare(c)
    File.rename!(root.root, root.root <> "-retained")
    File.mkdir!(root.root)
    File.chmod!(root.root, 0o700)
    sentinel = Path.join(root.root, "replacement-sentinel")
    File.write!(sentinel, @canary)
    assert_error(call(:scavenge, [root]), :integrity_failure)
    assert File.read!(sentinel) == @canary
    assert File.read!(Path.join(root.root <> "-retained", "foreign-sentinel")) == @canary
  end

  test "scavenge propagates a recognized cleanup failure instead of counting it removed", c do
    root = prepare(c)
    {:ok, operation} = call(:create, [root])
    inaccessible = Path.join(operation.path, "inaccessible")
    File.mkdir!(inaccessible)
    inaccessible_identity = identity(inaccessible)
    nested = Path.join(inaccessible, "protected-content")
    File.write!(nested, @canary)
    File.chmod!(inaccessible, 0o000)

    on_exit(fn ->
      case File.lstat(inaccessible) do
        {:ok, %{type: :directory} = stat} ->
          if identity(stat) == inaccessible_identity, do: File.chmod!(inaccessible, 0o700)

        _ ->
          :ok
      end
    end)

    # This is a real filesystem permission failure under the unprivileged test
    # uid, not a simulated uid mismatch or a hostile same-uid race guarantee.
    assert_error(call(:scavenge, [root]))
    assert File.exists?(marker_path(operation))
    assert_mode(inaccessible, 0o000)
    assert identity(inaccessible) == inaccessible_identity
    File.chmod!(inaccessible, 0o700)
    assert File.read!(nested) == @canary
    assert File.read!(c.sentinel) == @canary
  end

  defp call(function, arguments), do: apply(@directory, function, arguments)

  defp prepare(c) do
    assert {:ok, root} = call(:prepare, [c.context])
    root
  end

  defp create(c) do
    assert {:ok, operation} = call(:create, [prepare(c)])
    operation
  end

  defp marker_path(operation), do: Path.join(operation.path, ".ownership")

  defp identity(path) when is_binary(path), do: identity(File.lstat!(path))
  defp identity(stat), do: {stat.major_device, stat.minor_device, stat.inode, stat.uid, stat.gid}

  defp identity_map(tuple), do: Map.new(Enum.zip(@identity_keys, Tuple.to_list(tuple)))

  defp expected_marker(operation) do
    %{
      "format" => @format,
      "version" => 1,
      "operation_id" => operation.id,
      "root" => identity_map(operation.root_identity),
      "operation" => identity_map(operation.identity)
    }
  end

  defp fixture_mode!(path, mode) do
    assert {"", 0} =
             System.cmd("chmod", ["--", Integer.to_string(mode, 8), path], stderr_to_stdout: true)

    assert_mode(path, mode)
  end

  defp assert_mode(path, expected),
    do: assert(Bitwise.band(File.lstat!(path).mode, 0o7777) == expected)

  defp assert_error(result, expected_code \\ nil) do
    assert {:error, %Error{} = error} = result
    if expected_code, do: assert(error.code == expected_code)
    assert error.message == nil
    assert error.details == %{}
    refute inspect(error, limit: :infinity) =~ @canary
    result
  end

  defp mutate_marker(marker, :format), do: Map.put(marker, "format", "foreign")
  defp mutate_marker(marker, :version), do: Map.put(marker, "version", 2)

  defp mutate_marker(marker, :operation_id),
    do: Map.put(marker, "operation_id", Ecto.UUID.generate())

  defp mutate_marker(marker, :extra), do: Map.put(marker, "extra", true)
  defp mutate_marker(marker, :missing), do: Map.delete(marker, "version")
  defp mutate_marker(marker, :root_extra), do: put_in(marker, ["root", "extra"], 1)
  defp mutate_marker(marker, :operation_extra), do: put_in(marker, ["operation", "extra"], 1)

  defp mutate_marker(marker, :root_missing),
    do: Map.update!(marker, "root", &Map.delete(&1, "gid"))

  defp mutate_marker(marker, :operation_missing),
    do: Map.update!(marker, "operation", &Map.delete(&1, "gid"))

  defp mutate_marker(marker, :integer_type), do: put_in(marker, ["root", "uid"], "1000")

  defp mutate_marker(marker, mutation) do
    {side, field} =
      case mutation do
        :root_uid -> {"root", "uid"}
        :operation_uid -> {"operation", "uid"}
        :root_gid -> {"root", "gid"}
        :operation_gid -> {"operation", "gid"}
        :root_device -> {"root", "major_device"}
        :operation_device -> {"operation", "major_device"}
        :root_minor -> {"root", "minor_device"}
        :operation_minor -> {"operation", "minor_device"}
        :root_inode -> {"root", "inode"}
        :operation_inode -> {"operation", "inode"}
      end

    update_in(marker, [side, field], &(&1 + 1))
  end

  defp make_unrecognized(operation, kind, c) do
    marker = marker_path(operation)
    expected = expected_marker(operation)

    case kind do
      :malformed ->
        File.write!(marker, "not-json")

      :oversized ->
        File.write!(marker, String.duplicate("x", 1_025))

      :wrong_uid ->
        File.write!(marker, Jason.encode!(mutate_marker(expected, :operation_uid)))

      :wrong_gid ->
        File.write!(marker, Jason.encode!(mutate_marker(expected, :operation_gid)))

      :wrong_inode ->
        File.write!(marker, Jason.encode!(mutate_marker(expected, :operation_inode)))

      :wrong_root ->
        File.write!(marker, Jason.encode!(mutate_marker(expected, :root_inode)))

      :extra_key ->
        File.write!(marker, Jason.encode!(mutate_marker(expected, :extra)))

      :duplicate_key ->
        encoded = Jason.encode!(expected)

        File.write!(
          marker,
          "{\"format\":\"#{@format}\"," <> binary_part(encoded, 1, byte_size(encoded) - 1)
        )

      :missing_marker ->
        File.rm!(marker)

      :symlink_marker ->
        File.rm!(marker)
        File.ln_s!(c.outside, marker)

      :insecure_operation ->
        File.chmod!(operation.path, 0o755)

      :insecure_marker ->
        File.chmod!(marker, 0o644)
    end
  end
end
