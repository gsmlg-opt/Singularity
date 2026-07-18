defmodule Singularity.Storage.Crypto.ObjectIdentityTest do
  use ExUnit.Case, async: true

  alias Singularity.Storage.Crypto.ObjectIdentity

  test "creates independent random 256-bit keys for the exact hierarchy" do
    first = ObjectIdentity.generate_hierarchy()
    second = ObjectIdentity.generate_hierarchy()

    assert %{
             vault_key: <<_::binary-size(32)>>,
             domain_key: <<_::binary-size(32)>>,
             object_dek: <<_::binary-size(32)>>,
             domain_dedup_key: <<_::binary-size(32)>>
           } = first

    assert first |> Map.values() |> Enum.uniq() |> length() == 4
    assert first != second
  end

  test "exposes only keyed lookup identity and exact ciphertext integrity" do
    dedup_key = :binary.copy(<<11>>, 32)
    plaintext = "private plaintext"
    plaintext_sha256 = :crypto.hash(:sha256, plaintext)
    ciphertext = "exact canonical ciphertext"

    assert {:ok, identity} =
             ObjectIdentity.protect(dedup_key, plaintext_sha256, ciphertext)

    expected_lookup = :crypto.mac(:hmac, :sha256, dedup_key, plaintext_sha256)
    expected_ciphertext_hash = :crypto.hash(:sha256, ciphertext)

    assert identity == %{
             lookup_digest: expected_lookup,
             ciphertext_hash: expected_ciphertext_hash
           }

    refute Map.has_key?(identity, :plaintext_sha256)
    refute Map.has_key?(identity, :plaintext_digest)
  end

  test "lookup identity is stable only for the same domain dedup key" do
    digest = :crypto.hash(:sha256, "same plaintext")

    assert {:ok, first} =
             ObjectIdentity.lookup_digest(:binary.copy(<<1>>, 32), digest)

    assert {:ok, ^first} =
             ObjectIdentity.lookup_digest(:binary.copy(<<1>>, 32), digest)

    assert {:ok, second} =
             ObjectIdentity.lookup_digest(:binary.copy(<<2>>, 32), digest)

    assert first != second
  end
end
