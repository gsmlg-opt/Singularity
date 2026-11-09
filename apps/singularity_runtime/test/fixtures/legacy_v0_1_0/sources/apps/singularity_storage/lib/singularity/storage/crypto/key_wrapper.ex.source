defmodule Singularity.Storage.Crypto.KeyWrapper do
  @moduledoc """
  Authenticated, versioned AES-256-GCM wrapping for hierarchy keys.

  Purpose labels are disjoint across vault, domain, object, deduplication, and
  backup-recovery wrapping. Every call generates a fresh 96-bit nonce.
  """

  @behaviour Singularity.Core.KeyWrapper

  alias Singularity.Core.Error

  @magic "SGKW"
  @version 1
  @algorithm :aes_256_gcm
  @algorithm_id 1
  @tag_size 16

  @purposes %{
    vault_key: {1, "singularity:v1:wrap:vault-key"},
    domain_key: {2, "singularity:v1:wrap:domain-key"},
    object_dek: {3, "singularity:v1:wrap:object-dek"},
    domain_dedup_key: {4, "singularity:v1:wrap:domain-dedup-key"},
    backup_recovery: {5, "singularity:v1:wrap:backup-recovery"}
  }

  @impl true
  def wrap(
        <<_::binary-size(32)>> = wrapping_key,
        <<_::binary-size(32)>> = raw_key,
        metadata
      ) do
    with {:ok, purpose_id, label, generation, external_aad} <-
           validate_metadata(metadata) do
      nonce = :crypto.strong_rand_bytes(12)

      prefix =
        <<@magic::binary, @version, @algorithm_id, purpose_id, generation::unsigned-big-32,
          nonce::binary, byte_size(raw_key)::unsigned-big-32>>

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          wrapping_key,
          nonce,
          raw_key,
          wrapper_aad(label, prefix, external_aad),
          @tag_size,
          true
        )

      encoded = <<prefix::binary, ciphertext::binary, tag::binary>>

      {:ok,
       %{
         version: @version,
         algorithm: @algorithm,
         purpose: metadata.purpose,
         generation: generation,
         encoded: encoded
       }}
    end
  end

  def wrap(_wrapping_key, _raw_key, _metadata),
    do: {:error, Error.new(:invalid)}

  @impl true
  def unwrap(
        <<_::binary-size(32)>> = wrapping_key,
        encoded,
        metadata
      )
      when is_binary(encoded) do
    with {:ok, expected_purpose_id, label, expected_generation, external_aad} <-
           validate_metadata(metadata),
         {:ok, prefix, purpose_id, generation, nonce, ciphertext, tag} <-
           parse(encoded),
         true <- purpose_id == expected_purpose_id,
         true <- generation == expected_generation,
         plaintext
         when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             wrapping_key,
             nonce,
             ciphertext,
             wrapper_aad(label, prefix, external_aad),
             tag,
             false
           ) do
      {:ok, plaintext}
    else
      _mismatch -> {:error, Error.new(:integrity_failure)}
    end
  end

  def unwrap(_wrapping_key, _encoded, _metadata),
    do: {:error, Error.new(:integrity_failure)}

  @spec purpose_label(atom()) :: binary()
  def purpose_label(purpose) do
    {_purpose_id, label} = Map.fetch!(@purposes, purpose)
    label
  end

  defp validate_metadata(%{
         purpose: purpose,
         generation: generation,
         aad: external_aad
       })
       when is_integer(generation) and generation > 0 and
              generation <= 0xFFFFFFFF and is_binary(external_aad) and
              byte_size(external_aad) > 0 do
    case Map.fetch(@purposes, purpose) do
      {:ok, {purpose_id, label}} ->
        {:ok, purpose_id, label, generation, external_aad}

      :error ->
        {:error, Error.new(:invalid)}
    end
  end

  defp validate_metadata(_metadata), do: {:error, Error.new(:invalid)}

  defp parse(
         <<@magic::binary, @version, @algorithm_id, purpose_id, generation::unsigned-big-32,
           nonce::binary-size(12), size::unsigned-big-32, ciphertext::binary-size(size),
           tag::binary-size(@tag_size)>>
       ) do
    prefix =
      <<@magic::binary, @version, @algorithm_id, purpose_id, generation::unsigned-big-32,
        nonce::binary, size::unsigned-big-32>>

    {:ok, prefix, purpose_id, generation, nonce, ciphertext, tag}
  end

  defp parse(_encoded), do: {:error, :invalid_wrapper}

  defp wrapper_aad(label, prefix, external_aad) do
    <<label::binary, 0, prefix::binary, 0, external_aad::binary>>
  end
end
