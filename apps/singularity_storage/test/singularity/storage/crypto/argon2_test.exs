defmodule Singularity.Storage.Crypto.Argon2Test do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Storage.Crypto.Argon2KeyDeriver
  alias Singularity.Storage.Crypto.Argon2PasswordHasher
  alias Singularity.Storage.Crypto.KeyWrapper

  @params %{version: 1, t_cost: 1, m_cost: 8, parallelism: 1}

  test "credential hashing and raw vault KEK derivation are independent" do
    password = "correct horse battery staple"
    salt = "0123456789ABCDEF"

    assert {:ok, first_verifier} = Argon2PasswordHasher.hash(@params, password)
    assert {:ok, second_verifier} = Argon2PasswordHasher.hash(@params, password)
    assert first_verifier != second_verifier
    assert String.starts_with?(first_verifier, "$argon2id$")
    assert {:ok, true} = Argon2PasswordHasher.verify(@params, password, first_verifier)
    assert {:ok, false} = Argon2PasswordHasher.verify(@params, "wrong", first_verifier)

    assert {:ok, first_key} = Argon2KeyDeriver.derive(password, salt, @params)
    assert {:ok, ^first_key} = Argon2KeyDeriver.derive(password, salt, @params)
    assert byte_size(first_key) == 32
    refute first_verifier =~ Base.encode16(first_key)

    assert {:ok, other_salt_key} =
             Argon2KeyDeriver.derive(password, "FEDCBA9876543210", @params)

    assert first_key != other_salt_key
  end

  test "rejects unknown KDF parameter versions" do
    invalid = %{@params | version: 2}

    assert {:error, %Error{code: :invalid}} =
             Argon2PasswordHasher.hash(invalid, "password")

    assert {:error, %Error{code: :invalid}} =
             Argon2KeyDeriver.derive("password", "0123456789ABCDEF", invalid)
  end

  test "credential verification enforces the exact selected Argon2 cost profile" do
    password = "profile-bound password"

    assert {:ok, valid} = Argon2PasswordHasher.hash(@params, password)
    assert {:ok, true} = Argon2PasswordHasher.verify(@params, password, valid)

    mismatched =
      for options <- [
            [t_cost: 1, m_cost: 7, parallelism: 1],
            [t_cost: 2, m_cost: 8, parallelism: 1],
            [t_cost: 1, m_cost: 9, parallelism: 1],
            [t_cost: 1, m_cost: 8, parallelism: 2]
          ] do
        Argon2.hash_pwd_salt(password, [argon2_type: 2] ++ options)
      end

    for verifier <- mismatched do
      assert {:error, %Error{code: :invalid}} =
               Argon2PasswordHasher.verify(@params, password, verifier)
    end
  end

  test "credential verification rejects variants, versions, and hash-shape drift" do
    password = "strict verifier policy"

    invalid_verifiers = [
      Argon2.hash_pwd_salt(password,
        t_cost: 1,
        m_cost: 8,
        parallelism: 1,
        argon2_type: 1
      ),
      Argon2.hash_pwd_salt(password,
        t_cost: 1,
        m_cost: 8,
        parallelism: 1,
        argon2_type: 2,
        salt_len: 8
      ),
      Argon2.hash_pwd_salt(password,
        t_cost: 1,
        m_cost: 8,
        parallelism: 1,
        argon2_type: 2,
        hashlen: 16
      ),
      valid_verifier(password) |> String.replace("$v=19$", "$v=16$"),
      "not-an-argon2-verifier",
      "$argon2id$v=19$m=256,t=1,p=1$malformed"
    ]

    for verifier <- invalid_verifiers do
      assert {:error, %Error{code: :invalid}} =
               Argon2PasswordHasher.verify(@params, password, verifier)
    end
  end

  test "wraps keys with authenticated purpose, generation, and associated context" do
    wrapping_key = :binary.copy(<<1>>, 32)
    raw_key = :binary.copy(<<2>>, 32)

    metadata = %{
      purpose: :vault_key,
      generation: 7,
      aad: "vault:00000000-0000-0000-0000-000000000010"
    }

    assert {:ok, first} = KeyWrapper.wrap(wrapping_key, raw_key, metadata)
    assert {:ok, second} = KeyWrapper.wrap(wrapping_key, raw_key, metadata)

    assert %{
             algorithm: :aes_256_gcm,
             encoded: encoded,
             generation: 7,
             purpose: :vault_key,
             version: 1
           } = first

    assert first.encoded != second.encoded
    assert {:ok, ^raw_key} = KeyWrapper.unwrap(wrapping_key, encoded, metadata)

    for mismatched <- [
          %{metadata | purpose: :domain_key},
          %{metadata | generation: 8},
          %{metadata | aad: metadata.aad <> ":altered"}
        ] do
      assert {:error, %Error{code: :integrity_failure}} =
               KeyWrapper.unwrap(wrapping_key, encoded, mismatched)
    end

    assert {:error, %Error{code: :integrity_failure}} =
             KeyWrapper.unwrap(wrapping_key, flip_last_byte(encoded), metadata)
  end

  test "assigns a distinct authenticated label to every wrapping purpose" do
    wrapping_key = :binary.copy(<<3>>, 32)
    raw_key = :binary.copy(<<4>>, 32)

    labels =
      for purpose <- [
            :vault_key,
            :domain_key,
            :object_dek,
            :domain_dedup_key,
            :backup_recovery
          ] do
        metadata = %{purpose: purpose, generation: 1, aad: "same-context"}
        assert {:ok, wrapper} = KeyWrapper.wrap(wrapping_key, raw_key, metadata)
        assert {:ok, ^raw_key} = KeyWrapper.unwrap(wrapping_key, wrapper.encoded, metadata)
        KeyWrapper.purpose_label(purpose)
      end

    assert Enum.uniq(labels) == labels
  end

  defp flip_last_byte(encoded) do
    size = byte_size(encoded) - 1
    <<prefix::binary-size(size), byte>> = encoded
    <<prefix::binary, Bitwise.bxor(byte, 1)>>
  end

  defp valid_verifier(password) do
    Argon2.hash_pwd_salt(password,
      t_cost: 1,
      m_cost: 8,
      parallelism: 1,
      argon2_type: 2
    )
  end
end
