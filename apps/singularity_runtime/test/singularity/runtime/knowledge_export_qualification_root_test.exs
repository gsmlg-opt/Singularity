defmodule Singularity.Runtime.KnowledgeExportQualificationRootTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @allocator Singularity.Runtime.KnowledgeExportQualificationRoot
  @environment "SINGULARITY_TASK16_FIXTURE_ROOT"
  @failure "invalid Task16 fixture root"
  @sentinel "qualification-root-existing-sentinel"

  setup %{tmp_dir: tmp_dir} do
    previous = System.fetch_env(@environment)
    System.delete_env(@environment)

    on_exit(fn ->
      case previous do
        {:ok, value} -> System.put_env(@environment, value)
        :error -> System.delete_env(@environment)
      end
    end)

    root = Path.join(tmp_dir, "qualification-root")
    File.mkdir!(root)
    File.chmod!(root, 0o700)

    # Restore only this test fixture's permissions after assertions, without deleting it.
    on_exit(fn -> File.chmod!(root, 0o700) end)

    sentinel = Path.join(root, "existing-sentinel")
    File.write!(sentinel, @sentinel)
    %{root: root, sentinel: sentinel}
  end

  test "unset configuration returns the exact fallback without filesystem mutation", c do
    before = identity(c.tmp_dir)
    entries = File.ls!(c.tmp_dir)

    assert allocate!(c.tmp_dir) === c.tmp_dir
    assert identity(c.tmp_dir) == before
    assert File.ls!(c.tmp_dir) == entries
    assert_unchanged_root(c)
  end

  test "unset configuration does not normalize or validate the fallback", c do
    fallback = Path.join(c.tmp_dir, "missing/../literal-fallback")

    assert allocate!(fallback) === fallback
    refute File.exists?(Path.join(c.tmp_dir, "missing"))
    refute File.exists?(Path.join(c.tmp_dir, "literal-fallback"))
    assert_unchanged_root(c)
  end

  test "a private root allocates one real empty 0700 child with the fallback UID", c do
    System.put_env(@environment, c.root)
    before = identity(c.root)

    child = allocate!(c.tmp_dir)

    assert Path.dirname(child) == c.root
    assert Path.basename(child) =~ ~r/\A[0-9a-f]{32}\z/
    assert File.lstat!(child).type == :directory
    assert File.lstat!(child).uid == File.lstat!(c.tmp_dir).uid
    assert Bitwise.band(File.lstat!(child).mode, 0o7777) == 0o700
    assert File.ls!(child) == []
    assert Enum.sort(File.ls!(c.root)) == Enum.sort(["existing-sentinel", Path.basename(child)])
    assert identity(c.root) == before
    assert File.read!(c.sentinel) == @sentinel
  end

  test "successive allocations preserve existing children and sentinel contents", c do
    System.put_env(@environment, c.root)
    first = allocate!(c.tmp_dir)
    retained = Path.join(first, "retained")
    File.write!(retained, @sentinel)
    before = identity(first)

    second = allocate!(c.tmp_dir)

    refute first == second
    assert Path.dirname(second) == c.root
    assert Path.basename(second) =~ ~r/\A[0-9a-f]{32}\z/
    assert identity(first) == before
    assert File.read!(retained) == @sentinel
    assert File.read!(c.sentinel) == @sentinel
    assert File.ls!(second) == []

    assert Enum.sort(File.ls!(c.root)) ==
             Enum.sort(["existing-sentinel", Path.basename(first), Path.basename(second)])
  end

  test "allocation needs no ExUnit cleanup registration and survives its caller exiting", c do
    System.put_env(@environment, c.root)
    caller = self()
    reference = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        send(caller, {reference, allocate!(c.tmp_dir)})
      end)

    assert_receive {^reference, child}
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    assert File.lstat!(child).type == :directory
    assert File.ls!(child) == []
    assert File.read!(c.sentinel) == @sentinel
  end

  test "an explicitly empty value fails closed without changing the parent", c do
    assert_rejected(c, "")
  end

  test "a relative root fails closed without changing the parent", c do
    assert_rejected(c, "relative-qualification-root")
    refute File.exists?(Path.join(c.tmp_dir, "relative-qualification-root"))
  end

  test "a dot alias fails closed rather than normalizing the configured root", c do
    assert_rejected(c, c.root <> "/.")
  end

  test "a parent alias fails closed rather than normalizing the configured root", c do
    assert_rejected(c, c.root <> "/../" <> Path.basename(c.root))
  end

  test "a trailing separator fails closed rather than normalizing the configured root", c do
    assert_rejected(c, c.root <> "/")
  end

  test "a missing root is not recursively created", c do
    missing = Path.join(c.tmp_dir, "missing-parent/qualification-root")
    assert_rejected(c, missing)
    refute File.exists?(Path.dirname(missing))
  end

  test "a regular file root is not replaced or removed", c do
    file = Path.join(c.tmp_dir, "file-root")
    File.write!(file, @sentinel)
    before = identity(file)

    assert_rejected(c, file)

    assert identity(file) == before
    assert File.read!(file) == @sentinel
  end

  for {name, mode} <- [
        {"group-accessible", 0o750},
        {"other-accessible", 0o707},
        {"owner-read-only", 0o500},
        {"special-mode", 0o1700}
      ] do
    test "a #{name} root is rejected without repairing its permissions", c do
      mode = unquote(mode)

      if mode == 0o1700 do
        # This toolchain's File.chmod/2 drops the sticky bit; establish it with chmod.
        assert {"", 0} = System.cmd("chmod", ["1700", c.root])
      else
        File.chmod!(c.root, mode)
      end

      assert Bitwise.band(File.lstat!(c.root).mode, 0o7777) == mode

      assert_rejected(c, c.root)

      assert Bitwise.band(File.lstat!(c.root).mode, 0o7777) == mode
    end
  end

  test "a symlink leaf is rejected without following or removing it", c do
    link = Path.join(c.tmp_dir, "linked-root")
    File.ln_s!(c.root, link)
    before = identity(link)

    assert_rejected(c, link)

    assert identity(link) == before
    assert File.lstat!(link).type == :symlink
    assert File.read_link!(link) == c.root
  end

  test "a symlink ancestor is rejected without changing either directory", c do
    link = Path.join(c.tmp_dir, "linked-parent")
    File.ln_s!(c.tmp_dir, link)
    before = identity(link)

    assert_rejected(c, Path.join(link, Path.basename(c.root)))

    assert identity(link) == before
    assert File.lstat!(link).type == :symlink
    assert File.read_link!(link) == c.tmp_dir
  end

  test "a regular-file ancestor is rejected without changing its contents", c do
    file = Path.join(c.tmp_dir, "file-parent")
    File.write!(file, @sentinel)
    before = identity(file)

    assert_rejected(c, Path.join(file, "qualification-root"))

    assert identity(file) == before
    assert File.read!(file) == @sentinel
  end

  test "a configured root requires an existing fallback directory", c do
    fallback = Path.join(c.tmp_dir, "missing-fallback")
    assert_rejected(c, c.root, fallback)
    refute File.exists?(fallback)
  end

  test "a configured root rejects a regular-file fallback without modifying it", c do
    fallback = Path.join(c.tmp_dir, "file-fallback")
    File.write!(fallback, @sentinel)
    before = identity(fallback)

    assert_rejected(c, c.root, fallback)

    assert identity(fallback) == before
    assert File.read!(fallback) == @sentinel
  end

  test "a configured root rejects a symlink fallback rather than borrowing its UID", c do
    fallback = Path.join(c.tmp_dir, "linked-fallback")
    File.ln_s!(c.tmp_dir, fallback)
    before = identity(fallback)

    assert_rejected(c, c.root, fallback)

    assert identity(fallback) == before
    assert File.lstat!(fallback).type == :symlink
    assert File.read_link!(fallback) == c.tmp_dir
  end

  defp allocate!(fallback), do: apply(@allocator, :allocate!, [fallback])

  defp assert_rejected(context, configured_root, fallback \\ nil) do
    before = identity(context.root)
    System.put_env(@environment, configured_root)

    assert_raise ArgumentError, @failure, fn ->
      allocate!(fallback || context.tmp_dir)
    end

    assert identity(context.root) == before
    assert_unchanged_root(context)
  end

  defp assert_unchanged_root(context) do
    assert File.ls!(context.root) == ["existing-sentinel"]
    assert File.read!(context.sentinel) == @sentinel
  end

  defp identity(path) do
    path
    |> File.lstat!()
    |> Map.take([:major_device, :minor_device, :inode, :uid, :gid, :mode, :type])
  end
end
