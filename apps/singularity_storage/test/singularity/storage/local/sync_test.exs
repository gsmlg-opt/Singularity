defmodule Singularity.Storage.Local.SyncTest do
  use ExUnit.Case, async: true

  alias Singularity.Storage.Local.Sync

  @moduletag :tmp_dir

  test "syncs a file and its parent directory in durability order", %{tmp_dir: root} do
    path = Path.join(root, "stage")
    File.write!(path, "encrypted")
    owner = self()

    sync_fun = fn kind, synced_path ->
      send(owner, {:synced, kind, synced_path})
      :ok
    end

    assert :ok = Sync.file_and_parent(path, sync_fun: sync_fun)
    assert_receive {:synced, :file, ^path}
    assert_receive {:synced, :directory, ^root}
  end

  test "does not acknowledge when file synchronization fails", %{tmp_dir: root} do
    path = Path.join(root, "stage")
    File.write!(path, "encrypted")
    owner = self()

    sync_fun = fn
      :file, ^path -> {:error, :injected_file_failure}
      :directory, ^root -> send(owner, :directory_synced)
    end

    assert {:error, %{code: :storage_unavailable, retryable?: true}} =
             Sync.file_and_parent(path, sync_fun: sync_fun)

    refute_receive :directory_synced
  end

  test "does not acknowledge when parent directory synchronization fails", %{tmp_dir: root} do
    path = Path.join(root, "stage")
    File.write!(path, "encrypted")
    owner = self()

    sync_fun = fn
      :file, ^path ->
        send(owner, :file_synced)
        :ok

      :directory, ^root ->
        {:error, :injected_directory_failure}
    end

    assert {:error, %{code: :storage_unavailable, retryable?: true}} =
             Sync.file_and_parent(path, sync_fun: sync_fun)

    assert_receive :file_synced
  end

  test "treats unexpected injected callback returns and exceptions as failures", %{
    tmp_dir: root
  } do
    path = Path.join(root, "stage")
    File.write!(path, "encrypted")

    assert {:error, %{code: :storage_unavailable}} =
             Sync.file(path, sync_fun: fn :file, ^path -> :not_synced end)

    assert {:error, %{code: :storage_unavailable}} =
             Sync.directory(root,
               sync_fun: fn :directory, ^root -> raise "injected failure" end
             )
  end

  test "uses real fsync primitives for regular files and directories", %{tmp_dir: root} do
    path = Path.join(root, "stage")
    File.write!(path, "encrypted")

    assert :ok = Sync.file(path)
    assert :ok = Sync.directory(root)
    assert :ok = Sync.file_and_parent(path)
  end

  test "returns a storage error instead of false success for missing paths", %{
    tmp_dir: root
  } do
    missing = Path.join(root, "missing")

    assert {:error, %{code: :storage_unavailable, retryable?: true}} =
             Sync.file(missing)

    assert {:error, %{code: :storage_unavailable, retryable?: true}} =
             Sync.directory(missing)
  end
end
