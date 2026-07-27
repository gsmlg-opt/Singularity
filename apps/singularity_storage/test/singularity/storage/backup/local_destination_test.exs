defmodule Singularity.Storage.Backup.LocalDestinationTest do
  use ExUnit.Case, async: false

  alias Singularity.Core.Error
  alias Singularity.Storage.Backup.BundleWriter
  alias Singularity.Storage.Backup.LocalDestination

  @manifest_id "00000000-0000-4000-8000-000000000901"
  @vault_id "00000000-0000-4000-8000-000000000902"
  @snapshot_id "00000000-0000-4000-8000-000000000903"

  @moduletag :tmp_dir

  defmodule TestCrypto do
    @moduledoc false

    alias Singularity.Storage.Backup.Manifest

    def init_encrypt(:capability, public_header),
      do: {:ok, "LOCAL-DESTINATION-TEST", public_header}

    def encrypt_chunk(state, fragment),
      do: {:ok, fragment, state}

    def finalize(_state, manifest) do
      {:ok, encoded_manifest} = Manifest.encode(manifest)
      manifest_tag = binary_part(:crypto.hash(:sha256, "local destination final"), 0, 16)

      {:ok, "LOCAL-DESTINATION-FINAL" <> manifest_tag,
       %{
         manifest_hash: :crypto.hash(:sha256, encoded_manifest),
         manifest_tag: manifest_tag
       }, :finalized}
    end
  end

  test "normalizes relative and contained absolute paths independently of the CWD", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "backups")
    context = backup_context(root)
    relative = "vaults/owner.singularity-backup"
    absolute = Path.join(root, relative)

    assert {:ok, ^relative} = LocalDestination.normalize(context, relative)
    assert {:ok, ^relative} = LocalDestination.normalize(context, absolute)

    other_cwd = Path.join(tmp_dir, "other-cwd")
    File.mkdir_p!(other_cwd)

    assert {:ok, ^relative} =
             File.cd!(other_cwd, fn -> LocalDestination.normalize(context, relative) end)
  end

  test "rejects unsafe operator paths and noncanonical persisted references", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "backups")
    context = backup_context(root)
    outside = Path.join(tmp_dir, "outside.bundle")

    for unsafe <- [
          "",
          <<0>>,
          ".",
          "..",
          "../outside.bundle",
          "nested/../outside.bundle",
          "nested/./backup.bundle",
          "nested\\..\\outside.bundle"
        ] do
      assert {:error, %Error{code: :invalid}} = LocalDestination.normalize(context, unsafe)
    end

    assert {:error, %Error{code: :invalid}} = LocalDestination.normalize(context, outside)

    for unstable <- ["nested//backup.bundle", "nested/backup.bundle/", "/absolute.bundle"] do
      assert {:error, %Error{code: :invalid}} =
               LocalDestination.writer_destination(context, unstable)
    end

    assert {:error, %Error{code: :invalid}} =
             LocalDestination.writer_destination(%{backup_root: "relative-root"}, "backup.bundle")
  end

  test "requires the configured backup root to already be a directory", %{tmp_dir: tmp_dir} do
    missing = Path.join(tmp_dir, "missing-root")
    regular = Path.join(tmp_dir, "regular-root")
    File.write!(regular, "not a directory")

    assert {:error, %Error{code: :invalid}} =
             LocalDestination.normalize(%{backup_root: missing}, "backup.bundle")

    assert {:error, %Error{code: :invalid}} =
             LocalDestination.writer_destination(%{backup_root: regular}, "backup.bundle")

    refute File.exists?(missing)
  end

  test "rejects symlink roots, components, final paths, and directory destinations", %{
    tmp_dir: tmp_dir
  } do
    real_root = Path.join(tmp_dir, "real-root")
    linked_root = Path.join(tmp_dir, "linked-root")
    File.mkdir_p!(real_root)
    File.ln_s!(real_root, linked_root)

    assert {:error, %Error{code: :invalid}} =
             LocalDestination.normalize(%{backup_root: linked_root}, "backup.bundle")

    root = Path.join(tmp_dir, "backups")
    outside = Path.join(tmp_dir, "outside")
    linked_component = Path.join(root, "linked")
    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    File.ln_s!(outside, linked_component)

    assert {:error, %Error{code: :invalid}} =
             LocalDestination.normalize(%{backup_root: root}, "linked/backup.bundle")

    final = Path.join(root, "final.bundle")
    target = Path.join(outside, "target.bundle")
    File.write!(target, "outside")
    File.ln_s!(target, final)

    assert {:error, %Error{code: :invalid}} =
             LocalDestination.normalize(%{backup_root: root}, "final.bundle")

    directory = Path.join(root, "directory.bundle")
    File.mkdir_p!(directory)

    assert {:error, %Error{code: :invalid}} =
             LocalDestination.normalize(%{backup_root: root}, "directory.bundle")
  end

  test "builds guarded writer and reader shapes and probes only regular finals", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "backups")
    context = backup_context(root)
    reference = "daily/backup.bundle"
    final = Path.join(root, reference)

    assert {:ok,
            %{
              destination_ref: ^reference,
              path: ^final,
              file_system: writer_fs
            } = destination} =
             LocalDestination.writer_destination(context, reference)

    assert is_function(destination.partial_path, 1)

    assert Enum.sort(Map.keys(writer_fs)) ==
             [:close, :exists?, :open, :publish, :remove_owned, :sync, :write]

    assert {:ok, :absent} = LocalDestination.probe(context, reference)

    File.write!(final, "authenticated bundle")

    assert {:ok, {:final, %{path: ^final, file_system: source_fs} = source}} =
             LocalDestination.probe(context, reference)

    assert {:ok, ^source} = LocalDestination.reader_source(context, reference)

    assert Enum.sort(Map.keys(source_fs)) ==
             [
               :close_snapshot,
               :open_snapshot,
               :pread,
               :read,
               :read_prefix,
               :verify_snapshot
             ]

    assert {:ok, "authenticated bundle"} = source_fs.read.(final, 64)
    assert {:error, :max_bytes_exceeded} = source_fs.read.(final, 3)
    assert {:ok, "auth"} = source_fs.read_prefix.(final, 4)

    assert {:ok, snapshot, %{size: 20}} = source_fs.open_snapshot.(final, 64)
    assert :ok = source_fs.verify_snapshot.(snapshot, 20)
    assert {:ok, "auth"} = source_fs.pread.(snapshot, 0, 4)
    assert {:ok, "bundle"} = source_fs.pread.(snapshot, 14, 6)
    assert :eof = source_fs.pread.(snapshot, 20, 1)
    assert :ok = source_fs.close_snapshot.(snapshot)
  end

  test "one immutable reader snapshot survives pathname replacement between passes", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "backups")
    context = backup_context(root)
    reference = "daily/backup.bundle"
    final = Path.join(root, reference)
    moved = final <> ".authenticated"

    File.mkdir_p!(Path.dirname(final))
    File.write!(final, "authenticated-original")

    assert {:ok, %{file_system: file_system}} =
             LocalDestination.reader_source(context, reference)

    assert {:ok, snapshot, %{size: 22}} = file_system.open_snapshot.(final, 64)
    assert {:ok, "authenticated-original"} = file_system.pread.(snapshot, 0, 22)

    File.rename!(final, moved)
    File.write!(final, "untrusted-replacement")

    assert :ok = file_system.verify_snapshot.(snapshot, 22)
    assert {:ok, "authenticated-original"} = file_system.pread.(snapshot, 0, 22)
    assert :ok = file_system.close_snapshot.(snapshot)
  end

  test "reader snapshot rejects a same-inode same-size in-place rewrite", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "backups")
    context = backup_context(root)
    reference = "daily/backup.bundle"
    final = Path.join(root, reference)
    original = "authenticated-original"

    File.mkdir_p!(Path.dirname(final))
    File.write!(final, original)

    assert {:ok, %{file_system: file_system}} =
             LocalDestination.reader_source(context, reference)

    assert {:ok, snapshot, %{size: size}} = file_system.open_snapshot.(final, 64)
    assert size == byte_size(original)

    File.write!(final, :binary.copy(<<0x58>>, size))

    assert {:error, %Error{code: :invalid}} =
             file_system.verify_snapshot.(snapshot, size)

    assert :ok = file_system.close_snapshot.(snapshot)
  end

  test "classifies only the owned partial and lets an immutable final win without mutation", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "backups")
    context = backup_context(root)
    reference = "daily/backup.bundle"
    other_manifest_id = "00000000-0000-4000-8000-000000000904"

    assert {:ok, destination} = LocalDestination.writer_destination(context, reference)
    final = destination.path
    partial = destination.partial_path.(@manifest_id)
    foreign_partial = destination.partial_path.(other_manifest_id)

    assert {:ok, :absent} = LocalDestination.probe(context, reference, @manifest_id)

    File.write!(foreign_partial, "foreign partial")
    assert {:ok, :absent} = LocalDestination.probe(context, reference, @manifest_id)

    File.write!(partial, "owned partial")
    assert {:ok, :partial} = LocalDestination.probe(context, reference, @manifest_id)

    File.write!(final, "immutable final")

    assert {:ok, {:final, %{path: ^final}}} =
             LocalDestination.probe(context, reference, @manifest_id)

    assert File.read!(final) == "immutable final"
    assert File.read!(partial) == "owned partial"
    assert File.read!(foreign_partial) == "foreign partial"

    assert {:error, %Error{code: :invalid}} =
             LocalDestination.probe(context, reference, "not-a-manifest-id")
  end

  test "rejects a nonregular owned partial instead of treating it as resumable", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "backups")
    context = backup_context(root)
    reference = "backup.bundle"

    assert {:ok, destination} = LocalDestination.writer_destination(context, reference)
    partial = destination.partial_path.(@manifest_id)
    File.mkdir!(partial)

    assert {:error, %Error{code: :invalid}} =
             LocalDestination.probe(context, reference, @manifest_id)
  end

  test "publication atomically refuses overwrite and leaves both files intact", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "backups")
    context = backup_context(root)
    reference = "backup.bundle"
    final = Path.join(root, reference)

    assert {:ok, destination} = LocalDestination.writer_destination(context, reference)
    partial = destination.partial_path.(@manifest_id)
    File.write!(final, "existing-final")

    assert {:ok, device, ownership} =
             destination.file_system.open.(partial, [:write, :binary, :exclusive])

    assert :ok = destination.file_system.write.(device, "new-partial")
    assert :ok = destination.file_system.close.(device)

    assert {:error, %Error{code: :conflict, details: %{publication_state: :not_published}}} =
             destination.file_system.publish.(partial, final, ownership)

    assert File.read!(final) == "existing-final"
    assert File.read!(partial) == "new-partial"
  end

  test "partial cleanup is manifest-specific and cannot remove another backup", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "backups")
    context = backup_context(root)
    reference = "backup.bundle"
    other_manifest_id = "00000000-0000-4000-8000-000000000904"

    assert {:ok, destination} = LocalDestination.writer_destination(context, reference)
    partial = destination.partial_path.(@manifest_id)
    other_partial = destination.partial_path.(other_manifest_id)
    File.write!(partial, "ours")
    File.write!(other_partial, "other")

    assert :ok = LocalDestination.cleanup_partial(context, reference, @manifest_id)
    refute File.exists?(partial)
    assert File.read!(other_partial) == "other"

    assert {:error, %Error{code: :invalid}} =
             LocalDestination.cleanup_partial(context, reference, "../not-a-manifest")
  end

  test "exclusive partial creation sets mode 0600 at open time", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "backups")
    context = backup_context(root)
    reference = "backup.bundle"

    assert {:ok, destination} = LocalDestination.writer_destination(context, reference)
    partial = destination.partial_path.(@manifest_id)

    assert {:ok, device, _ownership} =
             destination.file_system.open.(partial, [:write, :binary, :exclusive])

    assert Bitwise.band(File.stat!(partial).mode, 0o777) == 0o600
    assert :ok = destination.file_system.close.(device)
  end

  test "an opened partial replaced before publication is neither published nor deleted", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "backups")
    context = backup_context(root)
    reference = "backup.bundle"
    final = Path.join(root, reference)

    assert {:ok, destination} = LocalDestination.writer_destination(context, reference)
    partial = destination.partial_path.(@manifest_id)
    replacement = Path.join(root, "replacement")
    original_close = destination.file_system.close

    destination =
      put_in(destination, [:file_system, :close], fn device ->
        :ok = File.write(replacement, "replacement B")
        refute File.stat!(replacement).inode == File.stat!(partial).inode
        :ok = original_close.(device)
        :ok = File.rm(partial)
        :ok = File.rename(replacement, partial)
      end)

    assert {:error,
            %Error{
              code: :storage_unavailable,
              retryable?: true,
              details: %{publication_state: :ambiguous}
            }} = write_bundle(destination)

    refute File.exists?(final)
    assert File.read!(partial) == "replacement B"
  end

  test "cleanup refuses to delete a replacement that is not owned by the writer", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "backups")
    context = backup_context(root)
    reference = "backup.bundle"
    primary = Error.new(:integrity_failure)

    assert {:ok, destination} = LocalDestination.writer_destination(context, reference)
    partial = destination.partial_path.(@manifest_id)
    replacement = Path.join(root, "replacement")

    destination =
      put_in(destination, [:file_system, :write], fn _device, _bytes ->
        :ok = File.write(replacement, "replacement B")
        refute File.stat!(replacement).inode == File.stat!(partial).inode
        :ok = File.rm(partial)
        :ok = File.rename(replacement, partial)
        {:error, primary}
      end)

    assert {:error,
            %Error{
              code: :storage_unavailable,
              retryable?: true,
              details: %{
                cleanup_error: :storage_unavailable,
                operation: :cleanup_partial,
                primary_error: :integrity_failure
              }
            }} = write_bundle(destination)

    assert File.read!(partial) == "replacement B"
  end

  test "the ownership-bound remover preserves a replacement inode", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "backups")
    context = backup_context(root)
    reference = "backup.bundle"

    assert {:ok, destination} = LocalDestination.writer_destination(context, reference)
    partial = destination.partial_path.(@manifest_id)
    replacement = Path.join(root, "replacement")

    assert {:ok, device, ownership} =
             destination.file_system.open.(partial, [:write, :binary, :exclusive])

    :ok = File.write(replacement, "replacement B")
    refute File.stat!(replacement).inode == File.stat!(partial).inode
    :ok = destination.file_system.close.(device)
    :ok = File.rm(partial)
    :ok = File.rename(replacement, partial)

    assert {:error,
            %Error{
              code: :storage_unavailable,
              retryable?: true,
              details: %{operation: :remove_owned, ownership_state: :mismatch}
            }} = destination.file_system.remove_owned.(partial, ownership)

    assert File.read!(partial) == "replacement B"
  end

  test "post-publication sync failure is typed, retains the final, and skips writer cleanup", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "backups")
    reference = "backup.bundle"
    final = Path.join(root, reference)

    sync_fun = fn
      :file, ^final -> {:error, :injected_post_publication_sync_failure}
      _kind, _path -> :ok
    end

    context = backup_context(root, %{sync_options: [sync_fun: sync_fun]})
    assert {:ok, destination} = LocalDestination.writer_destination(context, reference)
    owner = self()
    original_remove = destination.file_system.remove_owned

    destination =
      put_in(destination, [:file_system, :remove_owned], fn path, ownership ->
        send(owner, {:writer_cleanup, path})
        original_remove.(path, ownership)
      end)

    assert {:error,
            %Error{
              code: :storage_unavailable,
              retryable?: true,
              details: %{publication_state: :published}
            }} = write_bundle(destination)

    assert File.regular?(final)
    assert File.regular?(destination.partial_path.(@manifest_id))
    refute_receive {:writer_cleanup, _path}
  end

  test "post-cleanup directory sync failure retains the already durable final", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "backups")
    reference = "backup.bundle"
    final = Path.join(root, reference)
    {:ok, sync_count} = Agent.start_link(fn -> 0 end)

    sync_fun = fn
      :directory, ^root ->
        count = Agent.get_and_update(sync_count, &{&1 + 1, &1 + 1})

        if count == 3,
          do: {:error, :injected_cleanup_directory_sync_failure},
          else: :ok

      _kind, _path ->
        :ok
    end

    context = backup_context(root, %{sync_options: [sync_fun: sync_fun]})
    assert {:ok, destination} = LocalDestination.writer_destination(context, reference)

    assert {:error,
            %Error{
              code: :storage_unavailable,
              retryable?: true,
              details: %{publication_state: :published}
            }} = write_bundle(destination)

    assert File.regular?(final)
    refute File.exists?(destination.partial_path.(@manifest_id))
  end

  test "publication rejects a final replaced during the cleanup directory sync", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "backups")
    reference = "backup.bundle"
    final = Path.join(root, reference)
    replacement = Path.join(root, "replacement")
    {:ok, directory_sync_count} = Agent.start_link(fn -> 0 end)

    sync_fun = fn
      :file, ^final ->
        :ok = File.write(replacement, "replacement bundle")
        refute File.stat!(replacement).inode == File.stat!(final).inode
        :ok

      :directory, ^root ->
        count = Agent.get_and_update(directory_sync_count, &{&1 + 1, &1 + 1})

        if count == 3 do
          :ok = File.rm(final)
          :ok = File.rename(replacement, final)
        end

        :ok

      _kind, _path ->
        :ok
    end

    context = backup_context(root, %{sync_options: [sync_fun: sync_fun]})
    assert {:ok, destination} = LocalDestination.writer_destination(context, reference)

    assert {:error,
            %Error{
              code: :storage_unavailable,
              retryable?: true,
              details: %{publication_state: :published}
            }} =
             write_bundle(destination)

    assert File.read!(final) == "replacement bundle"
    refute File.exists?(destination.partial_path.(@manifest_id))
  end

  test "ambiguous publication failure preserves the typed error and partial", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "backups")
    context = backup_context(root)
    reference = "backup.bundle"

    assert {:ok, destination} = LocalDestination.writer_destination(context, reference)
    owner = self()

    ambiguous =
      Error.new(:storage_unavailable,
        details: %{operation: :link_final, publication_state: :ambiguous},
        retryable?: true
      )

    destination =
      destination
      |> put_in([:file_system, :publish], fn _partial, _final, _ownership ->
        {:error, ambiguous}
      end)
      |> put_in([:file_system, :remove_owned], fn path, _ownership ->
        send(owner, {:writer_cleanup, path})
        File.rm(path)
      end)

    assert {:error, ^ambiguous} = write_bundle(destination)
    assert File.regular?(destination.partial_path.(@manifest_id))
    refute_receive {:writer_cleanup, _path}
  end

  test "unknown publication callback outcomes retain a possibly published final and partial", %{
    tmp_dir: tmp_dir
  } do
    for outcome <- [:raise, :malformed] do
      root = Path.join(tmp_dir, Atom.to_string(outcome))
      context = backup_context(root)
      reference = "backup.bundle"
      final = Path.join(root, reference)

      assert {:ok, destination} = LocalDestination.writer_destination(context, reference)
      partial = destination.partial_path.(@manifest_id)

      destination =
        put_in(destination, [:file_system, :publish], fn ^partial, ^final, _ownership ->
          :ok = File.ln(partial, final)

          case outcome do
            :raise -> raise "publication outcome lost"
            :malformed -> :unexpected_publication_result
          end
        end)

      assert {:error,
              %Error{
                code: :storage_unavailable,
                retryable?: true,
                details: %{operation: :publish, publication_state: :ambiguous}
              }} = write_bundle(destination)

      assert File.regular?(final)
      assert File.regular?(partial)
    end
  end

  test "publication rejects both names replaced by a new shared inode during sync", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "backups")
    reference = "backup.bundle"
    final = Path.join(root, reference)
    owner = self()

    sync_fun = fn
      :file, ^final ->
        receive do
          {:replace_published_names, partial} ->
            replacement = Path.join(root, "replacement")
            :ok = File.write(replacement, "replacement bundle")
            original_inode = File.stat!(partial).inode
            refute File.stat!(replacement).inode == original_inode
            :ok = File.rm(final)
            :ok = File.rm(partial)
            :ok = File.rename(replacement, partial)
            :ok = File.ln(partial, final)
            send(owner, :published_names_replaced)
            :ok
        after
          1_000 ->
            {:error, :missing_partial_path}
        end

      _kind, _path ->
        :ok
    end

    context = backup_context(root, %{sync_options: [sync_fun: sync_fun]})
    assert {:ok, destination} = LocalDestination.writer_destination(context, reference)
    partial = destination.partial_path.(@manifest_id)
    send(self(), {:replace_published_names, partial})

    assert {:error,
            %Error{
              code: :storage_unavailable,
              retryable?: true,
              details: %{publication_state: :published}
            }} =
             write_bundle(destination)

    assert_receive :published_names_replaced
    assert File.regular?(final)
    assert File.regular?(partial)
    assert File.stat!(final).inode == File.stat!(partial).inode
  end

  test "writer reports cleanup failure instead of returning a nonretryable primary error", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "backups")
    context = backup_context(root)
    reference = "backup.bundle"
    primary = Error.new(:integrity_failure)

    cleanup_error =
      Error.new(:storage_unavailable,
        details: %{operation: :injected_remove_failure},
        retryable?: true
      )

    assert {:ok, destination} = LocalDestination.writer_destination(context, reference)
    partial = destination.partial_path.(@manifest_id)

    destination =
      destination
      |> put_in([:file_system, :write], fn _device, _bytes -> {:error, primary} end)
      |> put_in([:file_system, :remove_owned], fn ^partial, _ownership ->
        {:error, cleanup_error}
      end)

    assert {:error,
            %Error{
              code: :storage_unavailable,
              retryable?: true,
              details: %{
                cleanup_error: :storage_unavailable,
                operation: :cleanup_partial,
                primary_error: :integrity_failure
              }
            }} = write_bundle(destination)

    assert File.regular?(partial)
  end

  test "real publication fsyncs and leaves one durable final with no partial", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "backups")
    context = backup_context(root)
    reference = "nested/backup.bundle"
    final = Path.join(root, reference)

    assert {:ok, destination} = LocalDestination.writer_destination(context, reference)

    assert {:ok,
            %{
              destination_ref: ^reference,
              path: ^final,
              manifest_id: @manifest_id
            }} = write_bundle(destination)

    assert File.regular?(final)
    refute File.exists?(destination.partial_path.(@manifest_id))
    assert {:ok, {:final, %{path: ^final}}} = LocalDestination.probe(context, reference)
  end

  defp write_bundle(destination) do
    manifest = %{
      version: 1,
      manifest_id: @manifest_id,
      vault_ids: [@vault_id],
      snapshot_id: @snapshot_id,
      outbox_high_water_mark: 0,
      recovery: %{
        "binding" => %{"manifest_id" => @manifest_id, "vault_id" => @vault_id},
        "label" => "backup_recovery",
        "wrapper" => "wrapped-recovery-key"
      },
      inventory: []
    }

    BundleWriter.stream(destination, [], [], manifest, %{
      adapter: TestCrypto,
      capability: :capability,
      public_header: %{version: 1, manifest_id: @manifest_id}
    })
  end

  defp backup_context(root, extra \\ %{}) do
    File.mkdir_p!(root)
    Map.merge(%{backup_root: root}, extra)
  end
end
