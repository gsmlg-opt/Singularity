defmodule Singularity.Storage.Crypto.KeyRotationTest do
  use ExUnit.Case, async: true

  alias Singularity.Storage.Crypto.Argon2PasswordHasher
  alias Singularity.Storage.Crypto.ChunkedAEAD
  alias Singularity.Storage.Crypto.KeyWrapper
  alias Singularity.Storage.Crypto.ObjectIdentity

  test "password change rewrites only the credential and active vault wrapper" do
    state = hierarchy_fixture()
    new_kek = :crypto.strong_rand_bytes(32)
    params = %{version: 1, t_cost: 1, m_cost: 8, parallelism: 1}

    assert {:ok, old_credential} =
             Argon2PasswordHasher.hash(params, "old-password")

    assert {:ok, new_credential} =
             Argon2PasswordHasher.hash(params, "new-password")

    assert {:ok, vault_key} =
             KeyWrapper.unwrap(state.old_kek, state.vault_wrapper.encoded, vault_metadata(1))

    assert {:ok, changed_vault_wrapper} =
             KeyWrapper.wrap(new_kek, vault_key, vault_metadata(1))

    assert changed_vault_wrapper.encoded != state.vault_wrapper.encoded
    assert new_credential != old_credential
    assert state.domain_wrapper == state.original_domain_wrapper
    assert state.object_wrapper == state.original_object_wrapper
    assert state.dedup_wrapper == state.original_dedup_wrapper

    assert {:ok, ^vault_key} =
             KeyWrapper.unwrap(new_kek, changed_vault_wrapper.encoded, vault_metadata(1))
  end

  test "vault-key rotation rewraps domain keys without touching child wrappers" do
    state = hierarchy_fixture()
    new_vault_key = :crypto.strong_rand_bytes(32)

    assert {:ok, domain_key} =
             KeyWrapper.unwrap(
               state.vault_key,
               state.domain_wrapper.encoded,
               domain_metadata(1)
             )

    assert {:ok, rotated_domain_wrapper} =
             KeyWrapper.wrap(new_vault_key, domain_key, domain_metadata(1))

    assert rotated_domain_wrapper.encoded != state.domain_wrapper.encoded
    assert state.object_wrapper == state.original_object_wrapper
    assert state.dedup_wrapper == state.original_dedup_wrapper

    assert {:ok, ^domain_key} =
             KeyWrapper.unwrap(
               new_vault_key,
               rotated_domain_wrapper.encoded,
               domain_metadata(1)
             )
  end

  test "domain rotation rewraps object DEKs and stable dedup key without rewriting identity" do
    state = hierarchy_fixture()
    new_domain_key = :crypto.strong_rand_bytes(32)

    assert {:ok, object_dek} =
             KeyWrapper.unwrap(
               state.domain_key,
               state.object_wrapper.encoded,
               object_metadata(1)
             )

    assert {:ok, dedup_key} =
             KeyWrapper.unwrap(
               state.domain_key,
               state.dedup_wrapper.encoded,
               dedup_metadata(1)
             )

    assert {:ok, rotated_object_wrapper} =
             KeyWrapper.wrap(new_domain_key, object_dek, object_metadata(2))

    assert {:ok, rotated_dedup_wrapper} =
             KeyWrapper.wrap(new_domain_key, dedup_key, dedup_metadata(2))

    assert rotated_object_wrapper.encoded != state.object_wrapper.encoded
    assert rotated_dedup_wrapper.encoded != state.dedup_wrapper.encoded
    assert state.ciphertext == state.original_ciphertext
    assert state.lookup_digest == state.original_lookup_digest

    assert {:ok, unwrapped_object_dek} =
             KeyWrapper.unwrap(
               new_domain_key,
               rotated_object_wrapper.encoded,
               object_metadata(2)
             )

    assert unwrapped_object_dek == object_dek

    assert {:ok, unwrapped_dedup_key} =
             KeyWrapper.unwrap(
               new_domain_key,
               rotated_dedup_wrapper.encoded,
               dedup_metadata(2)
             )

    assert unwrapped_dedup_key == dedup_key
    plaintext = state.plaintext
    lookup_digest = state.lookup_digest

    assert {:ok, ^plaintext} =
             ChunkedAEAD.decode(
               state.ciphertext,
               codec_context(unwrapped_object_dek, plaintext)
             )

    plaintext_sha256 = :crypto.hash(:sha256, plaintext)

    assert {:ok, ^lookup_digest} =
             ObjectIdentity.lookup_digest(unwrapped_dedup_key, plaintext_sha256)
  end

  defp hierarchy_fixture do
    keys = ObjectIdentity.generate_hierarchy()
    old_kek = :crypto.strong_rand_bytes(32)

    {:ok, vault_wrapper} =
      KeyWrapper.wrap(old_kek, keys.vault_key, vault_metadata(1))

    {:ok, domain_wrapper} =
      KeyWrapper.wrap(keys.vault_key, keys.domain_key, domain_metadata(1))

    {:ok, object_wrapper} =
      KeyWrapper.wrap(keys.domain_key, keys.object_dek, object_metadata(1))

    {:ok, dedup_wrapper} =
      KeyWrapper.wrap(keys.domain_key, keys.domain_dedup_key, dedup_metadata(1))

    plaintext = "canonical private object"
    codec = codec_context(keys.object_dek, plaintext)
    {:ok, ciphertext} = ChunkedAEAD.encode(codec)
    plaintext_sha256 = :crypto.hash(:sha256, plaintext)

    {:ok, lookup_digest} =
      ObjectIdentity.lookup_digest(keys.domain_dedup_key, plaintext_sha256)

    %{
      old_kek: old_kek,
      vault_key: keys.vault_key,
      domain_key: keys.domain_key,
      vault_wrapper: vault_wrapper,
      domain_wrapper: domain_wrapper,
      object_wrapper: object_wrapper,
      dedup_wrapper: dedup_wrapper,
      original_domain_wrapper: domain_wrapper,
      original_object_wrapper: object_wrapper,
      original_dedup_wrapper: dedup_wrapper,
      plaintext: plaintext,
      ciphertext: ciphertext,
      original_ciphertext: ciphertext,
      lookup_digest: lookup_digest,
      original_lookup_digest: lookup_digest
    }
  end

  defp vault_metadata(generation),
    do: %{purpose: :vault_key, generation: generation, aad: "vault:vault-1"}

  defp domain_metadata(generation),
    do: %{purpose: :domain_key, generation: generation, aad: "domain:domain-1"}

  defp object_metadata(generation),
    do: %{purpose: :object_dek, generation: generation, aad: "object:object-1"}

  defp dedup_metadata(generation),
    do: %{
      purpose: :domain_dedup_key,
      generation: generation,
      aad: "dedup:domain-1"
    }

  defp codec_context(key, plaintext) do
    %{
      format_version: 1,
      algorithm: :aes_256_gcm,
      chunk_size: 4_194_304,
      key: key,
      nonce_prefix: <<9, 8, 7, 6, 5, 4, 3, 2>>,
      vault_id: "00000000-0000-0000-0000-000000000010",
      encryption_domain_id: "00000000-0000-0000-0000-000000000020",
      object_id: "00000000-0000-0000-0000-000000000001",
      chunk_index: 0,
      plaintext: plaintext
    }
  end
end
