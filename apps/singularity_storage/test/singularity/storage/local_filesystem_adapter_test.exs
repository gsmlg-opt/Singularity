defmodule Singularity.Storage.LocalFilesystemAdapterTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Core.ObjectRef
  alias Singularity.Core.StageRef
  alias Singularity.Storage.Local.PathGuard
  alias Singularity.Storage.LocalFilesystemAdapter

  @vault_id "00000000-0000-0000-0000-000000000001"
  @domain_id "00000000-0000-0000-0000-000000000002"
  @lookup_digest String.duplicate("ab", 32)

  @moduletag :tmp_dir

  test "stages, seals, finalizes, reads, verifies, and deletes at the protected path", %{
    tmp_dir: tmp_dir
  } do
    context = context(tmp_dir)
    original_filename = "quarterly-report.pdf"
    ciphertext = "encrypted-records"
    object_ref = object_ref()

    assert {:ok, %StageRef{} = stage_ref} =
             LocalFilesystemAdapter.stage(context, %{original_filename: original_filename})

    assert {:ok, stage_path} = PathGuard.staging_path(tmp_dir, stage_ref.stage_id)
    assert File.regular?(stage_path)
    refute stage_path =~ original_filename

    assert :ok = LocalFilesystemAdapter.append_encrypted_chunk(context, stage_ref, ciphertext)

    assert {:ok, %{byte_size: 17, sealed?: true}} =
             LocalFilesystemAdapter.seal_stage(context, stage_ref, %{})

    assert {:error, %Error{code: :conflict}} =
             LocalFilesystemAdapter.append_encrypted_chunk(context, stage_ref, "late-record")

    assert {:ok, ^object_ref} =
             LocalFilesystemAdapter.finalize(context, stage_ref, object_ref)

    assert {:ok, final_path} =
             PathGuard.object_path(tmp_dir, @vault_id, @domain_id, @lookup_digest)

    assert final_path ==
             Path.join([
               tmp_dir,
               "objects",
               @vault_id,
               @domain_id,
               "hmac-sha256",
               "ab",
               @lookup_digest
             ])

    assert File.read!(final_path) == ciphertext
    refute File.exists?(stage_path)
    refute final_path =~ original_filename
    assert final_path =~ @lookup_digest

    assert {:ok, %{byte_size: 17}} = LocalFilesystemAdapter.stat(context, object_ref)
    assert {:ok, handle} = LocalFilesystemAdapter.open(context, object_ref)
    assert {:ok, "crypted"} = LocalFilesystemAdapter.read_range(context, handle, 2..8)
    assert :ok = LocalFilesystemAdapter.verify(context, object_ref)
    assert :ok = LocalFilesystemAdapter.delete(context, object_ref)
    assert :ok = LocalFilesystemAdapter.delete(context, object_ref)

    assert {:error, %Error{code: :not_found}} =
             LocalFilesystemAdapter.stat(context, object_ref)
  end

  test "creating a directory chain syncs every new directory and its parent", %{
    tmp_dir: tmp_dir
  } do
    owner = self()
    staging_directory = Path.join(tmp_dir, "staging")

    context =
      tmp_dir
      |> context()
      |> Map.put(:sync_options,
        sync_fun: fn kind, path ->
          send(owner, {:synced, kind, path})
          :ok
        end
      )

    assert {:ok, %StageRef{}} = LocalFilesystemAdapter.stage(context, %{})
    assert_receive {:synced, :directory, ^staging_directory}
    assert_receive {:synced, :directory, ^tmp_dir}
  end

  test "a failed stage sync is never acknowledged as sealed", %{tmp_dir: tmp_dir} do
    context = context(tmp_dir)
    assert {:ok, stage_ref} = LocalFilesystemAdapter.stage(context, %{})
    assert :ok = LocalFilesystemAdapter.append_encrypted_chunk(context, stage_ref, "ciphertext")

    failing_context =
      Map.put(context, :sync_options,
        sync_fun: fn
          :directory, _path -> {:error, :injected_sync_failure}
          :file, _path -> :ok
        end
      )

    assert {:error, %Error{code: :storage_unavailable}} =
             LocalFilesystemAdapter.seal_stage(failing_context, stage_ref, %{})

    assert {:ok, %{sealed?: false}} =
             LocalFilesystemAdapter.stat_stage(context, stage_ref)

    assert :ok =
             LocalFilesystemAdapter.append_encrypted_chunk(context, stage_ref, "-continued")
  end

  test "seal waits for an already-open append to finish", %{tmp_dir: tmp_dir} do
    owner = self()

    context =
      tmp_dir
      |> context()
      |> Map.put(:filesystem_options,
        operation_hook: fn
          :append_opened, _paths ->
            send(owner, {:append_opened, self()})

            receive do
              :release_append -> :ok
            end

          _operation, _paths ->
            :ok
        end
      )

    assert {:ok, stage_ref} = LocalFilesystemAdapter.stage(context, %{})

    append_task =
      Task.async(fn ->
        LocalFilesystemAdapter.append_encrypted_chunk(context, stage_ref, "ciphertext")
      end)

    assert_receive {:append_opened, append_pid}

    seal_task =
      Task.async(fn ->
        LocalFilesystemAdapter.seal_stage(context, stage_ref, %{})
      end)

    assert Task.yield(seal_task, 50) == nil
    send(append_pid, :release_append)

    assert :ok = Task.await(append_task)
    assert {:ok, %{byte_size: 10, sealed?: true}} = Task.await(seal_task)

    assert {:error, %Error{code: :conflict}} =
             LocalFilesystemAdapter.append_encrypted_chunk(context, stage_ref, "late")
  end

  test "abort waits for an already-open append to finish", %{tmp_dir: tmp_dir} do
    owner = self()

    context =
      tmp_dir
      |> context()
      |> Map.put(:filesystem_options,
        operation_hook: fn
          :append_opened, _paths ->
            send(owner, {:append_opened, self()})

            receive do
              :release_append -> :ok
            end

          _operation, _paths ->
            :ok
        end
      )

    assert {:ok, stage_ref} = LocalFilesystemAdapter.stage(context, %{})

    append_task =
      Task.async(fn ->
        LocalFilesystemAdapter.append_encrypted_chunk(context, stage_ref, "ciphertext")
      end)

    assert_receive {:append_opened, append_pid}
    abort_task = Task.async(fn -> LocalFilesystemAdapter.abort_stage(context, stage_ref) end)
    assert Task.yield(abort_task, 50) == nil
    send(append_pid, :release_append)

    assert :ok = Task.await(append_task)
    assert :ok = Task.await(abort_task)

    assert {:error, %Error{code: :not_found}} =
             LocalFilesystemAdapter.stat_stage(context, stage_ref)
  end

  test "a failed final sync is not acknowledged and a retry recovers idempotently", %{
    tmp_dir: tmp_dir
  } do
    context = context(tmp_dir)
    object_ref = object_ref()
    stage_ref = sealed_stage!(context, "ciphertext")

    failing_context =
      Map.put(context, :sync_options,
        sync_fun: fn
          :directory, _path -> {:error, :injected_sync_failure}
          :file, _path -> :ok
        end
      )

    assert {:error, %Error{code: :storage_unavailable}} =
             LocalFilesystemAdapter.finalize(failing_context, stage_ref, object_ref)

    assert {:ok, ^object_ref} =
             LocalFilesystemAdapter.finalize(context, stage_ref, object_ref)

    assert :ok = LocalFilesystemAdapter.verify(context, object_ref)
  end

  test "a durable receipt recovers after stage removal but before its parent sync", %{
    tmp_dir: tmp_dir
  } do
    context = context(tmp_dir)
    object_ref = object_ref()
    stage_ref = sealed_stage!(context, "ciphertext")
    staging_directory = Path.join(tmp_dir, "staging")

    failing_context =
      Map.put(context, :sync_options,
        sync_fun: fn
          :directory, ^staging_directory -> {:error, :injected_staging_sync_failure}
          _kind, _path -> :ok
        end
      )

    assert {:error, %Error{code: :storage_unavailable}} =
             LocalFilesystemAdapter.finalize(failing_context, stage_ref, object_ref)

    assert {:error, %Error{code: :not_found}} =
             LocalFilesystemAdapter.stat_stage(context, stage_ref)

    owner = self()

    retry_context =
      Map.put(context, :sync_options,
        sync_fun: fn kind, path ->
          send(owner, {:retry_synced, kind, path})
          :ok
        end
      )

    assert {:ok, ^object_ref} =
             LocalFilesystemAdapter.finalize(retry_context, stage_ref, object_ref)

    assert_receive {:retry_synced, :directory, ^staging_directory}
  end

  test "a delete retry re-syncs the object parent after the entry is already absent", %{
    tmp_dir: tmp_dir
  } do
    context = context(tmp_dir)
    object_ref = object_ref()
    stage_ref = sealed_stage!(context, "ciphertext")
    assert {:ok, ^object_ref} = LocalFilesystemAdapter.finalize(context, stage_ref, object_ref)

    assert {:ok, object_path} =
             PathGuard.object_path(tmp_dir, @vault_id, @domain_id, @lookup_digest)

    object_directory = Path.dirname(object_path)

    failing_context =
      Map.put(context, :sync_options,
        sync_fun: fn
          :directory, ^object_directory -> {:error, :injected_object_parent_sync_failure}
          _kind, _path -> :ok
        end
      )

    assert {:error, %Error{code: :storage_unavailable}} =
             LocalFilesystemAdapter.delete(failing_context, object_ref)

    refute File.exists?(object_path)
    owner = self()

    retry_context =
      Map.put(context, :sync_options,
        sync_fun: fn kind, path ->
          send(owner, {:retry_synced, kind, path})
          :ok
        end
      )

    assert :ok = LocalFilesystemAdapter.delete(retry_context, object_ref)
    assert_receive {:retry_synced, :directory, ^object_directory}
  end

  test "deleting a missing object is idempotent before its parent exists", %{
    tmp_dir: tmp_dir
  } do
    missing_root = Path.join(tmp_dir, "never-created")

    refute File.exists?(missing_root)
    assert :ok = LocalFilesystemAdapter.delete(context(missing_root), object_ref())
    refute File.exists?(missing_root)
  end

  test "an abort retry re-syncs the staging parent after the entry is already absent", %{
    tmp_dir: tmp_dir
  } do
    context = context(tmp_dir)
    staging_directory = Path.join(tmp_dir, "staging")
    assert {:ok, stage_ref} = LocalFilesystemAdapter.stage(context, %{})
    assert :ok = LocalFilesystemAdapter.append_encrypted_chunk(context, stage_ref, "partial")

    failing_context =
      Map.put(context, :sync_options,
        sync_fun: fn
          :directory, ^staging_directory -> {:error, :injected_staging_parent_sync_failure}
          _kind, _path -> :ok
        end
      )

    assert {:error, %Error{code: :storage_unavailable}} =
             LocalFilesystemAdapter.abort_stage(failing_context, stage_ref)

    assert {:error, %Error{code: :not_found}} =
             LocalFilesystemAdapter.stat_stage(context, stage_ref)

    owner = self()

    retry_context =
      Map.put(context, :sync_options,
        sync_fun: fn kind, path ->
          send(owner, {:retry_synced, kind, path})
          :ok
        end
      )

    assert :ok = LocalFilesystemAdapter.abort_stage(retry_context, stage_ref)
    assert_receive {:retry_synced, :directory, ^staging_directory}
  end

  test "aborting a missing stage is idempotent before its parent exists", %{
    tmp_dir: tmp_dir
  } do
    missing_root = Path.join(tmp_dir, "never-created")
    stage_ref = %StageRef{stage_id: Ecto.UUID.generate()}

    refute File.exists?(missing_root)
    assert :ok = LocalFilesystemAdapter.abort_stage(%{root: missing_root}, stage_ref)
    refute File.exists?(missing_root)
  end

  test "a failure after the atomic rename reports published state", %{tmp_dir: tmp_dir} do
    context = context(tmp_dir)
    object_ref = object_ref()
    stage_ref = sealed_stage!(context, "ciphertext")
    sync_state_key = {__MODULE__, make_ref()}

    failing_context =
      Map.put(context, :sync_options,
        sync_fun: fn
          :file, path ->
            if String.contains?(path, "/objects/") do
              Process.put(sync_state_key, :object_file_synced)
            end

            :ok

          :directory, _path ->
            if Process.get(sync_state_key) == :object_file_synced do
              {:error, :injected_post_publication_failure}
            else
              :ok
            end
        end
      )

    assert {:error,
            %Error{
              code: :storage_unavailable,
              details: %{publication_state: :published}
            }} = LocalFilesystemAdapter.finalize(failing_context, stage_ref, object_ref)

    assert {:ok, ^object_ref} =
             LocalFilesystemAdapter.finalize(context, stage_ref, object_ref)
  end

  test "append and seal reject a symlink substituted for a stage", %{tmp_dir: tmp_dir} do
    context = context(tmp_dir)
    assert {:ok, stage_ref} = LocalFilesystemAdapter.stage(context, %{})
    assert {:ok, stage_path} = PathGuard.staging_path(tmp_dir, stage_ref.stage_id)
    outside = Path.join(tmp_dir, "outside")
    File.write!(outside, "outside")
    File.rm!(stage_path)
    File.ln_s!(outside, stage_path)

    assert {:error, %Error{code: :invalid}} =
             LocalFilesystemAdapter.append_encrypted_chunk(context, stage_ref, "attack")

    assert {:error, %Error{code: :invalid}} =
             LocalFilesystemAdapter.seal_stage(context, stage_ref, %{})

    assert File.read!(outside) == "outside"
  end

  test "finalize refuses a symlinked object parent", %{tmp_dir: tmp_dir} do
    context = context(tmp_dir)
    stage_ref = sealed_stage!(context, "ciphertext")
    outside = Path.join(tmp_dir, "outside")
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(tmp_dir, "objects"))

    assert {:error, %Error{code: :invalid}} =
             LocalFilesystemAdapter.finalize(context, stage_ref, object_ref())

    assert {:ok, stage_path} = PathGuard.staging_path(tmp_dir, stage_ref.stage_id)
    assert File.regular?(stage_path)
    assert File.ls!(outside) == []
  end

  test "verify detects corruption against the sealed ciphertext hash", %{tmp_dir: tmp_dir} do
    ciphertext = "ciphertext"

    context =
      context(tmp_dir)
      |> Map.put(:ciphertext_hash, :crypto.hash(:sha256, ciphertext))

    object_ref = object_ref()
    stage_ref = sealed_stage!(context, ciphertext)
    assert {:ok, ^object_ref} = LocalFilesystemAdapter.finalize(context, stage_ref, object_ref)

    assert {:ok, final_path} =
             PathGuard.object_path(tmp_dir, @vault_id, @domain_id, @lookup_digest)

    File.chmod!(final_path, 0o600)
    File.write!(final_path, "corrupt")

    assert {:error, %Error{code: :integrity_failure}} =
             LocalFilesystemAdapter.verify(context, object_ref)
  end

  test "interrupted and sealed orphan stages remain discoverable until aborted", %{
    tmp_dir: tmp_dir
  } do
    context = context(tmp_dir)
    assert {:ok, interrupted} = LocalFilesystemAdapter.stage(context, %{})
    assert :ok = LocalFilesystemAdapter.append_encrypted_chunk(context, interrupted, "partial")
    sealed = sealed_stage!(context, "sealed")

    assert {:ok, staged} = LocalFilesystemAdapter.list_staged(context)

    assert Enum.sort_by(staged, & &1.stage_id) ==
             Enum.sort_by([interrupted, sealed], & &1.stage_id)

    assert :ok = LocalFilesystemAdapter.abort_stage(context, interrupted)
    assert :ok = LocalFilesystemAdapter.abort_stage(context, interrupted)
    assert {:ok, [^sealed]} = LocalFilesystemAdapter.list_staged(context)
  end

  test "duplicate and concurrent finalize calls are idempotent and never replace bytes", %{
    tmp_dir: tmp_dir
  } do
    context = context(tmp_dir)
    object_ref = object_ref()
    stage_ref = sealed_stage!(context, "canonical")

    results =
      1..2
      |> Task.async_stream(
        fn _ -> LocalFilesystemAdapter.finalize(context, stage_ref, object_ref) end,
        ordered: false,
        max_concurrency: 2
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.sort(results) == Enum.sort([{:ok, object_ref}, {:ok, object_ref}])
    assert {:ok, handle} = LocalFilesystemAdapter.open(context, object_ref)
    assert {:ok, "canonical"} = LocalFilesystemAdapter.read_range(context, handle, 0..8)
  end

  test "an existing object never authorizes an unsealed candidate stage", %{
    tmp_dir: tmp_dir
  } do
    context = context(tmp_dir)
    object_ref = object_ref()
    canonical_stage = sealed_stage!(context, "canonical")

    assert {:ok, ^object_ref} =
             LocalFilesystemAdapter.finalize(context, canonical_stage, object_ref)

    assert {:ok, candidate_stage} = LocalFilesystemAdapter.stage(context, %{})

    assert :ok =
             LocalFilesystemAdapter.append_encrypted_chunk(
               context,
               candidate_stage,
               "canonical"
             )

    assert {:error, %Error{code: :conflict}} =
             LocalFilesystemAdapter.finalize(context, candidate_stage, object_ref)

    assert {:ok, %{sealed?: false}} =
             LocalFilesystemAdapter.stat_stage(context, candidate_stage)
  end

  test "an existing object does not authorize an unrelated missing stage", %{
    tmp_dir: tmp_dir
  } do
    context = context(tmp_dir)
    object_ref = object_ref()
    finalized_stage = sealed_stage!(context, "canonical")

    assert {:ok, ^object_ref} =
             LocalFilesystemAdapter.finalize(context, finalized_stage, object_ref)

    missing_stage = %StageRef{stage_id: Ecto.UUID.generate()}

    assert {:error, %Error{code: :conflict}} =
             LocalFilesystemAdapter.finalize(context, missing_stage, object_ref)
  end

  test "a destination race with different bytes fails closed and preserves the stage", %{
    tmp_dir: tmp_dir
  } do
    context = context(tmp_dir)
    object_ref = object_ref()
    stage_ref = sealed_stage!(context, "candidate")

    assert {:ok, final_path} =
             PathGuard.object_path(tmp_dir, @vault_id, @domain_id, @lookup_digest)

    File.mkdir_p!(Path.dirname(final_path))
    File.write!(final_path, "racing-object")

    assert {:error, %Error{code: :conflict}} =
             LocalFilesystemAdapter.finalize(context, stage_ref, object_ref)

    assert File.read!(final_path) == "racing-object"
    assert {:ok, stage_path} = PathGuard.staging_path(tmp_dir, stage_ref.stage_id)
    assert File.regular?(stage_path)
  end

  test "a destination created at the publication boundary is never replaced", %{
    tmp_dir: tmp_dir
  } do
    object_ref = object_ref()

    assert {:ok, final_path} =
             PathGuard.object_path(tmp_dir, @vault_id, @domain_id, @lookup_digest)

    context =
      tmp_dir
      |> context()
      |> Map.put(:filesystem_options,
        operation_hook: fn
          :before_publish, %{destination: ^final_path} ->
            File.write!(final_path, "racing-object")

          _operation, _paths ->
            :ok
        end
      )

    stage_ref = sealed_stage!(context, "candidate")

    assert {:error, %Error{code: :conflict}} =
             LocalFilesystemAdapter.finalize(context, stage_ref, object_ref)

    assert File.read!(final_path) == "racing-object"
    assert {:ok, stage_path} = PathGuard.staging_path(tmp_dir, stage_ref.stage_id)
    assert File.regular?(stage_path)
  end

  test "publication revalidates the sealed ciphertext after the publication hook", %{
    tmp_dir: tmp_dir
  } do
    object_ref = object_ref()

    context =
      tmp_dir
      |> context()
      |> Map.put(:filesystem_options,
        operation_hook: fn
          :before_publish, %{source: source} ->
            File.chmod!(source, 0o600)
            File.write!(source, "tampered")
            File.chmod!(source, 0o400)

          _operation, _paths ->
            :ok
        end
      )

    stage_ref = sealed_stage!(context, "candidate")

    assert {:ok, final_path} =
             PathGuard.object_path(tmp_dir, @vault_id, @domain_id, @lookup_digest)

    assert {:error,
            %Error{
              code: :integrity_failure,
              details: %{publication_state: :not_published}
            }} = LocalFilesystemAdapter.finalize(context, stage_ref, object_ref)

    refute File.exists?(final_path)
    assert {:ok, stage_path} = PathGuard.staging_path(tmp_dir, stage_ref.stage_id)
    assert File.read!(stage_path) == "tampered"
  end

  test "a parent symlink substituted at the publication boundary is rejected", %{
    tmp_dir: tmp_dir
  } do
    object_ref = object_ref()
    outside = Path.join(tmp_dir, "outside")
    File.mkdir_p!(outside)

    assert {:ok, final_path} =
             PathGuard.object_path(tmp_dir, @vault_id, @domain_id, @lookup_digest)

    final_parent = Path.dirname(final_path)
    displaced_parent = final_parent <> "-displaced"

    context =
      tmp_dir
      |> context()
      |> Map.put(:filesystem_options,
        operation_hook: fn
          :before_publish, %{destination: ^final_path} ->
            File.rename!(final_parent, displaced_parent)
            File.ln_s!(outside, final_parent)

          _operation, _paths ->
            :ok
        end
      )

    stage_ref = sealed_stage!(context, "candidate")

    assert {:error,
            %Error{
              code: :invalid,
              details: %{publication_state: :not_published}
            }} = LocalFilesystemAdapter.finalize(context, stage_ref, object_ref)

    assert File.ls!(outside) == []
    assert {:ok, stage_path} = PathGuard.staging_path(tmp_dir, stage_ref.stage_id)
    assert File.regular?(stage_path)
  end

  test "invalid references and invalid ranges fail closed", %{tmp_dir: tmp_dir} do
    context = context(tmp_dir)

    for stage_id <- ["../escape", "/absolute", "a/b", "asset.pdf", "bad\\path"] do
      stage_ref = %StageRef{stage_id: stage_id}

      assert {:error, %Error{code: :invalid}} =
               LocalFilesystemAdapter.stat_stage(context, stage_ref)
    end

    object_ref = object_ref()
    stage_ref = sealed_stage!(context, "ciphertext")
    assert {:ok, ^object_ref} = LocalFilesystemAdapter.finalize(context, stage_ref, object_ref)
    assert {:ok, handle} = LocalFilesystemAdapter.open(context, object_ref)

    assert {:error, %Error{code: :invalid}} =
             LocalFilesystemAdapter.read_range(context, handle, 2..1//-1)
  end

  defp context(root) do
    %{
      root: root,
      vault_namespace: @vault_id,
      domain_namespace: @domain_id,
      lookup_digest: @lookup_digest
    }
  end

  defp object_ref do
    %ObjectRef{object_id: "00000000-0000-0000-0000-#{unique_suffix()}"}
  end

  defp sealed_stage!(context, ciphertext) do
    assert {:ok, stage_ref} = LocalFilesystemAdapter.stage(context, %{})
    assert :ok = LocalFilesystemAdapter.append_encrypted_chunk(context, stage_ref, ciphertext)
    assert {:ok, %{sealed?: true}} = LocalFilesystemAdapter.seal_stage(context, stage_ref, %{})
    stage_ref
  end

  defp unique_suffix do
    System.unique_integer([:positive, :monotonic])
    |> Integer.to_string()
    |> String.pad_leading(12, "0")
    |> binary_part(0, 12)
  end
end
