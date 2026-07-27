defmodule Singularity.Runtime.RestoreIntegrityLeaseTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Core.ObjectRef
  alias Singularity.Runtime.RestoreIntegrityLease
  alias Singularity.Runtime.RestoreIntegrityLease.Capability
  alias Singularity.Runtime.RestoreIntegrityLease.PlaintextSummary
  alias Singularity.Storage.Crypto.ChunkedAEAD
  alias Singularity.Storage.Crypto.Format
  alias Singularity.Storage.Crypto.KeyWrapper
  alias Singularity.Storage.LocalFilesystemAdapter

  @moduletag :tmp_dir

  @vault_id "71000000-0000-0000-0000-000000000001"
  @vault_key_version_id "71000000-0000-0000-0000-000000000002"
  @domain_id "71000000-0000-0000-0000-000000000003"
  @domain_key_version_id "71000000-0000-0000-0000-000000000004"
  @manifest_id "71000000-0000-0000-0000-000000000005"

  defmodule MaterialLoader do
    def load_plaintext_material(%{material: material, owner: owner}, binding, entry) do
      send(owner, {:load_material, binding, entry.asset_object_id})
      material
    end
  end

  test "one-shot opaque custody authenticates vault to domain to DEK and returns hashes only", %{
    tmp_dir: tmp_dir
  } do
    plaintext = "restored plaintext must remain inside custody"
    fixture = fixture(tmp_dir, plaintext)

    assert {:ok, %Capability{} = capability} = issue(fixture)
    inspected = inspect(capability)
    assert inspected == "#RestoreIntegrityLease.Capability<REDACTED>"
    refute inspected =~ Base.encode16(fixture.vault_key)

    assert {:ok,
            %PlaintextSummary{
              vault_id: @vault_id,
              object_count: 1,
              inventory_sha256: <<_::binary-size(32)>>,
              plaintext_hashes: [
                %{asset_object_id: object_id, sha256: plaintext_sha256}
              ]
            } = summary} = RestoreIntegrityLease.verify_all(capability)

    assert object_id == fixture.entry.asset_object_id
    assert plaintext_sha256 == :crypto.hash(:sha256, plaintext)
    refute inspect(summary) =~ plaintext
    refute inspect(summary) =~ Base.encode16(fixture.object_dek)
    assert_receive {:load_material, binding, ^object_id}
    assert binding == fixture.binding

    assert {:error, %Error{code: :backup_invalid}} =
             RestoreIntegrityLease.verify_all(capability)

    assert :ok = RestoreIntegrityLease.revoke(capability)
  end

  test "object and domain keys may have independent generations", %{tmp_dir: tmp_dir} do
    plaintext = "independently rotated custody material"
    fixture = fixture(tmp_dir, plaintext, object_generation: 3)

    assert fixture.material.object_generation == 3
    assert fixture.material.domain_key_generation == 7
    assert {:ok, capability} = issue(fixture)

    assert {:ok,
            %PlaintextSummary{
              object_count: 1,
              plaintext_hashes: [
                %{asset_object_id: object_id, sha256: plaintext_sha256}
              ]
            }} = RestoreIntegrityLease.verify_all(capability)

    assert object_id == fixture.entry.asset_object_id
    assert plaintext_sha256 == :crypto.hash(:sha256, plaintext)
  end

  test "a stolen capability cannot verify or consume the owner's lease", %{tmp_dir: tmp_dir} do
    fixture = fixture(tmp_dir, "owner-bound plaintext")
    {:ok, capability} = issue(fixture)

    assert {:error, %Error{code: :backup_invalid}} =
             Task.async(fn -> RestoreIntegrityLease.verify_all(capability) end)
             |> Task.await()

    assert {:ok, %PlaintextSummary{object_count: 1}} =
             RestoreIntegrityLease.verify_all(capability)
  end

  test "an invalid domain or DEK wrapper fails without returning plaintext", %{tmp_dir: tmp_dir} do
    fixture = fixture(tmp_dir, "wrapper authentication is mandatory")

    for field <- [:wrapped_domain_key, :wrapped_dek] do
      malformed = update_in(fixture.material[field], &flip_last_byte/1)
      {:ok, capability} = issue(%{fixture | material: malformed})

      assert {:error, %Error{code: :integrity_failure, message: nil, details: %{}}} =
               RestoreIntegrityLease.verify_all(capability)
    end
  end

  test "authenticated reader rejects ciphertext corruption and the lease remains one-shot", %{
    tmp_dir: tmp_dir
  } do
    fixture = fixture(tmp_dir, "ciphertext authentication is mandatory")
    {:ok, capability} = issue(fixture)
    corrupt_byte!(fixture.path, fixture.entry.ciphertext_byte_size - 1)

    assert {:error, %Error{code: :integrity_failure}} =
             RestoreIntegrityLease.verify_all(capability)

    assert {:error, %Error{code: :backup_invalid}} =
             RestoreIntegrityLease.verify_all(capability)
  end

  test "synchronous revoke is idempotent and prevents later verification", %{tmp_dir: tmp_dir} do
    fixture = fixture(tmp_dir, "revoked plaintext")
    {:ok, capability} = issue(fixture)

    assert :ok = RestoreIntegrityLease.revoke(capability)
    assert :ok = RestoreIntegrityLease.revoke(capability)

    assert {:error, %Error{code: :backup_invalid}} =
             RestoreIntegrityLease.verify_all(capability)
  end

  test "issuance fails closed for a missing material loader or malformed inventory", %{
    tmp_dir: tmp_dir
  } do
    fixture = fixture(tmp_dir, "issuance validation")

    assert {:error, %Error{code: :invalid}} =
             fixture
             |> issue_options()
             |> Map.put(:material_loader, {:missing_adapter, %{}})
             |> RestoreIntegrityLease.issue()

    assert {:error, %Error{code: :backup_invalid}} =
             fixture
             |> issue_options()
             |> Map.update!(:inventory, fn [entry] ->
               [%{entry | vault_id: Ecto.UUID.generate()}]
             end)
             |> RestoreIntegrityLease.issue()
  end

  defp issue(fixture), do: fixture |> issue_options() |> RestoreIntegrityLease.issue()

  defp issue_options(fixture) do
    %{
      binding: fixture.binding,
      inventory: [fixture.entry],
      key_wrapper: KeyWrapper,
      material_loader: {MaterialLoader, %{material: {:ok, fixture.material}, owner: self()}},
      object_storage: {LocalFilesystemAdapter, %{root: fixture.root}},
      owner: self(),
      ttl_ms: 5_000,
      vault_key: fixture.vault_key
    }
  end

  defp fixture(root, plaintext, options \\ []) do
    object_generation = Keyword.get(options, :object_generation, 7)
    vault_key = :crypto.strong_rand_bytes(32)
    domain_key = :crypto.strong_rand_bytes(32)
    object_dek = :crypto.strong_rand_bytes(32)
    object_id = Ecto.UUID.generate()
    lookup_digest = :crypto.hash(:sha256, "lookup:" <> object_id)

    {:ok, domain_wrapper} =
      KeyWrapper.wrap(vault_key, domain_key, %{
        purpose: :domain_key,
        generation: 7,
        aad: @vault_id <> ":" <> @domain_id
      })

    {:ok, dek_wrapper} =
      KeyWrapper.wrap(domain_key, object_dek, %{
        purpose: :object_dek,
        generation: object_generation,
        aad: "object:" <> object_id
      })

    {:ok, ciphertext} =
      ChunkedAEAD.encode(%{
        key: object_dek,
        plaintext: plaintext,
        format_version: Format.format_version(),
        algorithm: Format.algorithm(),
        chunk_size: Format.chunk_size(),
        vault_id: @vault_id,
        encryption_domain_id: @domain_id,
        object_id: object_id,
        chunk_index: 0
      })

    storage_context = %{
      root: root,
      vault_namespace: @vault_id,
      domain_namespace: @domain_id,
      lookup_digest: Base.encode16(lookup_digest, case: :lower)
    }

    object_ref = %ObjectRef{object_id: object_id}
    {:ok, stage_ref} = LocalFilesystemAdapter.stage(storage_context, %{})
    :ok = LocalFilesystemAdapter.append_encrypted_chunk(storage_context, stage_ref, ciphertext)
    {:ok, %{sealed?: true}} = LocalFilesystemAdapter.seal_stage(storage_context, stage_ref, %{})
    {:ok, ^object_ref} = LocalFilesystemAdapter.finalize(storage_context, stage_ref, object_ref)

    {:ok, handle} = LocalFilesystemAdapter.open(storage_context, object_ref)

    {:ok, %{byte_size: ciphertext_byte_size, ciphertext_hash: ciphertext_hash}} =
      LocalFilesystemAdapter.stat(storage_context, object_ref)

    entry = %{
      asset_object_id: object_id,
      ciphertext_byte_size: ciphertext_byte_size,
      ciphertext_hash: ciphertext_hash,
      classification: :private,
      inventory_position: 0,
      key_domain_id: @domain_id,
      lookup_digest: lookup_digest,
      storage_ref: object_id,
      vault_id: @vault_id
    }

    %{
      root: root,
      path: object_path!(storage_context, handle.object_ref),
      binding: %{
        manifest_id: @manifest_id,
        vault_id: @vault_id,
        vault_key_generation: 5,
        vault_key_version_id: @vault_key_version_id
      },
      entry: entry,
      material: %{
        object_id: object_id,
        vault_id: @vault_id,
        key_domain_id: @domain_id,
        classification: :private,
        lookup_digest: lookup_digest,
        ciphertext_hash: ciphertext_hash,
        plaintext_byte_size: byte_size(plaintext),
        ciphertext_byte_size: ciphertext_byte_size,
        format_version: Format.format_version(),
        lifecycle: :available,
        object_generation: object_generation,
        envelope_classification: :private,
        envelope_algorithm: "aes_256_gcm",
        wrapped_dek: dek_wrapper.encoded,
        domain_id: @domain_id,
        domain_classification: :private,
        domain_kind: "content",
        domain_state: :active,
        domain_key_version_id: @domain_key_version_id,
        vault_key_version_id: @vault_key_version_id,
        domain_key_generation: 7,
        domain_version_state: :active,
        domain_algorithm: "aes_256_gcm",
        wrapped_domain_key: domain_wrapper.encoded,
        vault_key_generation: 5,
        vault_version_state: :active
      },
      object_dek: object_dek,
      vault_key: vault_key
    }
  end

  defp object_path!(context, object_ref) do
    {:ok, handle} = LocalFilesystemAdapter.open(context, object_ref)

    {:ok, path} =
      Singularity.Storage.Local.PathGuard.object_path(
        context.root,
        context.vault_namespace,
        context.domain_namespace,
        context.lookup_digest
      )

    assert %LocalFilesystemAdapter.Handle{} = handle
    path
  end

  defp flip_last_byte(binary) do
    size = byte_size(binary) - 1
    <<prefix::binary-size(size), byte>> = binary
    <<prefix::binary, Bitwise.bxor(byte, 1)>>
  end

  defp corrupt_byte!(path, offset) do
    File.chmod!(path, 0o600)
    {:ok, io} = :file.open(path, [:read, :write, :binary])

    try do
      {:ok, <<byte>>} = :file.pread(io, offset, 1)
      :ok = :file.pwrite(io, offset, <<Bitwise.bxor(byte, 1)>>)
      :ok = :file.sync(io)
    after
      :ok = :file.close(io)
    end
  end
end
