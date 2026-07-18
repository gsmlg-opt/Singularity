defmodule Singularity.Storage.Crypto.FormatVectorsTest do
  use ExUnit.Case, async: true

  alias Singularity.Storage.Crypto.ChunkedAEAD

  @fixture_root Path.expand("../../../fixtures/crypto", __DIR__)
  @nonce_prefix Base.decode16!("2021222324252627")

  test "format v1 is pinned byte for byte" do
    vector = vector()
    plaintext = vector.plaintext

    assert {:ok, encoded} = ChunkedAEAD.encode_vector(vector, @nonce_prefix)
    assert Base.encode16(encoded) == fixture("format-v1.hex")
    assert {:ok, ^plaintext} = ChunkedAEAD.decode(encoded, vector)
  end

  test "vector encoding requires an exact 8-byte nonce prefix" do
    assert {:error, :invalid_format} =
             ChunkedAEAD.encode_vector(vector(), binary_part(@nonce_prefix, 0, 7))

    assert {:error, :invalid_format} =
             ChunkedAEAD.encode_vector(vector(), @nonce_prefix <> <<0>>)
  end

  defp vector do
    %{
      format_version: 1,
      algorithm: :aes_256_gcm,
      chunk_size: 4_194_304,
      key:
        Base.decode16!(
          "000102030405060708090A0B0C0D0E0F" <>
            "101112131415161718191A1B1C1D1E1F"
        ),
      vault_id: "00000000-0000-0000-0000-000000000010",
      encryption_domain_id: "00000000-0000-0000-0000-000000000020",
      object_id: "00000000-0000-0000-0000-000000000001",
      chunk_index: 0,
      plaintext: "authenticated test vector"
    }
  end

  defp fixture(filename) do
    @fixture_root
    |> Path.join(filename)
    |> File.read!()
    |> String.trim()
  end
end
