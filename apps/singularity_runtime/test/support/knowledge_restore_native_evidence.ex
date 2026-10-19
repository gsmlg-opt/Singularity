defmodule Singularity.Runtime.KnowledgeRestoreNativeEvidence do
  @moduledoc false

  def original_inventory!(rows) do
    rows
    |> Enum.sort_by(& &1["id"])
    |> Enum.with_index()
    |> Enum.map(fn {row, position} ->
      %{
        asset_object_id: row["id"],
        vault_id: row["vault_id"],
        key_domain_id: row["key_domain_id"],
        classification: String.to_existing_atom(row["classification"]),
        lookup_digest: row["lookup_digest"],
        ciphertext_hash: row["ciphertext_hash"],
        ciphertext_byte_size: row["ciphertext_byte_size"],
        storage_ref: row["storage_ref"],
        inventory_position: position
      }
    end)
  end

  def reference_witness!(root, entry) do
    alias Singularity.Storage.{LocalFilesystemAdapter, Local.PathGuard}

    {:ok, path} =
      PathGuard.object_path(
        root,
        entry.vault_id,
        entry.key_domain_id,
        Base.encode16(entry.lookup_digest, case: :lower)
      )

    canonical_ref = Path.relative_to(path, root)

    context = %{
      root: root,
      vault_namespace: entry.vault_id,
      domain_namespace: entry.key_domain_id,
      lookup_digest: Base.encode16(entry.lookup_digest, case: :lower),
      ciphertext_hash: entry.ciphertext_hash
    }

    witnesses =
      for spelling <- [entry.asset_object_id, canonical_ref] do
        ref = %Singularity.Core.ObjectRef{object_id: spelling}
        stat = expect_ok!(LocalFilesystemAdapter.stat(context, ref), "alias ciphertext stat")
        handle = expect_ok!(LocalFilesystemAdapter.open(context, ref), "alias ciphertext open")

        bytes =
          expect_ok!(
            LocalFilesystemAdapter.read_range(context, handle, 0..(stat.byte_size - 1)),
            "alias ciphertext read"
          )

        require!(
          stat.byte_size == entry.ciphertext_byte_size and
            stat.ciphertext_hash == entry.ciphertext_hash and
            byte_size(bytes) == entry.ciphertext_byte_size and
            :crypto.hash(:sha256, bytes) == entry.ciphertext_hash,
          "actual alias ciphertext differs from persisted native evidence"
        )

        %{stat: stat, ciphertext: bytes}
      end

    [uuid, canonical] = witnesses
    require!(uuid == canonical, "UUID and canonical adapter reads differ")
    physical = File.lstat!(path)
    require!(physical.type == :regular, "native alias does not resolve a regular file")

    Map.merge(uuid, %{
      canonical_ref: canonical_ref,
      physical: {physical.major_device, physical.minor_device, physical.inode}
    })
  end

  def inventory_handoff(value) do
    %{
      cut: value.cut,
      inventory: value.object_inventory,
      manifest_id: value.manifest.manifest_id,
      manifest_hash: value.manifest_hash,
      manifest_tag: value.manifest_tag,
      owner: Map.take(value.owner, [:vault_key_version_id, :vault_key_generation])
    }
  end

  def replace_ciphertext!(root, entry, replacement) when is_binary(replacement) do
    alias Singularity.Storage.Local.PathGuard

    before = reference_witness!(root, entry)

    {:ok, path} =
      PathGuard.object_path(
        root,
        entry.vault_id,
        entry.key_domain_id,
        Base.encode16(entry.lookup_digest, case: :lower)
      )

    physical = File.lstat!(path)
    original_mode = Bitwise.band(physical.mode, 0o7777)
    replacement_hash = :crypto.hash(:sha256, replacement)

    require!(
      physical.type == :regular and original_mode == 0o400 and
        byte_size(replacement) == entry.ciphertext_byte_size and
        replacement_hash != entry.ciphertext_hash,
      "foreign composition requires one genuine read-only equal-length owned ciphertext"
    )

    :ok = PathGuard.assert_safe_path(root, path)

    try do
      File.chmod!(path, Bitwise.bor(original_mode, 0o200))

      File.open!(path, [:read, :write, :binary], fn io ->
        :ok = :file.pwrite(io, 0, replacement)
        :ok = :file.sync(io)
      end)
    after
      :ok = PathGuard.assert_safe_path(root, path)
      File.chmod!(path, original_mode)
    end

    after_physical = File.lstat!(path)
    after_bytes = File.read!(path)

    same_physical =
      after_physical.type == :regular and after_physical.mode == physical.mode and
        after_physical.size == physical.size and after_bytes == replacement and
        {after_physical.major_device, after_physical.minor_device, after_physical.inode} ==
          before.physical

    require!(same_physical, "foreign composition changed owned file identity, mode or length")

    %{
      before: %{
        physical: before.physical,
        mode: physical.mode,
        sha256: entry.ciphertext_hash,
        byte_size: entry.ciphertext_byte_size
      },
      after: %{
        physical: before.physical,
        mode: after_physical.mode,
        sha256: replacement_hash,
        byte_size: byte_size(after_bytes)
      }
    }
  end

  defp expect_ok!({:ok, value}, _operation), do: value
  defp expect_ok!(_, operation), do: raise(ArgumentError, operation <> " failed")
  defp require!(true, _message), do: :ok
  defp require!(false, message), do: raise(ArgumentError, message)
end
