defmodule Singularity.Storage.Crypto.ObjectIdentity do
  @moduledoc """
  Random hierarchy generation and protected canonical-object identity.

  Raw plaintext digests are accepted only transiently and are never included
  in returned identity maps.
  """

  alias Singularity.Core.Error

  @key_size 32

  @spec generate_hierarchy() :: %{
          vault_key: binary(),
          domain_key: binary(),
          object_dek: binary(),
          domain_dedup_key: binary()
        }
  def generate_hierarchy do
    %{
      vault_key: generate_key(),
      domain_key: generate_key(),
      object_dek: generate_key(),
      domain_dedup_key: generate_key()
    }
  end

  @spec generate_key() :: binary()
  def generate_key, do: :crypto.strong_rand_bytes(@key_size)

  @spec lookup_digest(binary(), binary()) ::
          {:ok, binary()} | {:error, Error.t()}
  def lookup_digest(
        <<_::binary-size(@key_size)>> = domain_dedup_key,
        <<_::binary-size(32)>> = plaintext_sha256
      ) do
    {:ok, :crypto.mac(:hmac, :sha256, domain_dedup_key, plaintext_sha256)}
  end

  def lookup_digest(_domain_dedup_key, _plaintext_sha256),
    do: {:error, Error.new(:invalid)}

  @spec protect(binary(), binary(), binary()) ::
          {:ok, %{lookup_digest: binary(), ciphertext_hash: binary()}}
          | {:error, Error.t()}
  def protect(domain_dedup_key, plaintext_sha256, ciphertext)
      when is_binary(ciphertext) do
    with {:ok, lookup_digest} <-
           lookup_digest(domain_dedup_key, plaintext_sha256) do
      {:ok,
       %{
         lookup_digest: lookup_digest,
         ciphertext_hash: :crypto.hash(:sha256, ciphertext)
       }}
    end
  end

  def protect(_domain_dedup_key, _plaintext_sha256, _ciphertext),
    do: {:error, Error.new(:invalid)}
end
