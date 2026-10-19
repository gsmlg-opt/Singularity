defmodule Singularity.Runtime.KnowledgeRestoreNativeEvidenceTest do
  use ExUnit.Case, async: true

  alias Singularity.Runtime.{KnowledgeRestoreNativeEvidence, KnowledgeRestoreOracle}
  alias Singularity.Storage.Local.PathGuard

  @moduletag :tmp_dir
  @vault "00000000-0000-4000-8000-000000009001"
  @domain "00000000-0000-4000-8000-000000009002"
  @object "00000000-0000-4000-8000-000000009003"
  @lookup <<1::256>>
  # Synthetic adapter bytes only: not AEAD, native publication or custody proof.
  @original "owned-ciphertext-A"
  @foreign "owned-ciphertext-B"

  test "literal inventory sorts rows and preserves every mapped field" do
    [a, b] = inventory_rows()

    expected = [
      %{
        asset_object_id: "a",
        vault_id: "vault-a",
        key_domain_id: "domain-a",
        classification: :private,
        lookup_digest: <<1::256>>,
        ciphertext_hash: <<3::256>>,
        ciphertext_byte_size: 17,
        storage_ref: "reference-a",
        inventory_position: 0
      },
      %{
        asset_object_id: "b",
        vault_id: "vault-b",
        key_domain_id: "domain-b",
        classification: :private,
        lookup_digest: <<2::256>>,
        ciphertext_hash: <<4::256>>,
        ciphertext_byte_size: 18,
        storage_ref: "reference-b",
        inventory_position: 1
      }
    ]

    assert KnowledgeRestoreNativeEvidence.original_inventory!([b, a]) == expected
    assert KnowledgeRestoreOracle.original_inventory!([b, a]) == expected
  end

  test "unknown classification atom is rejected without changing the input" do
    [a, b] = inventory_rows()
    rows = [Map.replace!(a, "classification", "task16_nonexisting_classification_93af"), b]
    before = rows

    assert_raise ArgumentError, fn -> KnowledgeRestoreNativeEvidence.original_inventory!(rows) end
    assert rows == before
    assert_raise ArgumentError, fn -> KnowledgeRestoreOracle.original_inventory!(rows) end
    assert rows == before
  end

  test "handoff projects exact fields and requires the cut" do
    value = %{
      cut: %{sequence: 9},
      object_inventory: [%{asset_object_id: @object}],
      manifest: %{manifest_id: "manifest-id", secret: "manifest-canary"},
      manifest_hash: <<5::256>>,
      manifest_tag: <<6::128>>,
      owner: %{
        vault_key_version_id: "key-version-id",
        vault_key_generation: 3,
        secret: "owner-canary"
      },
      secret: "top-level-canary"
    }

    expected = %{
      cut: %{sequence: 9},
      inventory: [%{asset_object_id: @object}],
      manifest_id: "manifest-id",
      manifest_hash: <<5::256>>,
      manifest_tag: <<6::128>>,
      owner: %{vault_key_version_id: "key-version-id", vault_key_generation: 3}
    }

    assert KnowledgeRestoreNativeEvidence.inventory_handoff(value) == expected
    assert KnowledgeRestoreOracle.inventory_handoff(value) == expected
    missing_cut = Map.delete(value, :cut)
    assert_raise KeyError, fn -> KnowledgeRestoreNativeEvidence.inventory_handoff(missing_cut) end
    assert_raise KeyError, fn -> KnowledgeRestoreOracle.inventory_handoff(missing_cut) end
  end

  test "UUID and canonical adapter witnesses preserve exact native file evidence", %{tmp_dir: tmp} do
    f = ciphertext_fixture!(tmp, "aliases")
    before = physical_state(f.path)
    {major, minor, inode, _mode, _size, _bytes} = before

    expected = %{
      stat: %{byte_size: byte_size(@original), ciphertext_hash: :crypto.hash(:sha256, @original)},
      ciphertext: @original,
      canonical_ref:
        Path.join([
          "objects",
          @vault,
          @domain,
          "hmac-sha256",
          "00",
          "0000000000000000000000000000000000000000000000000000000000000001"
        ]),
      physical: {major, minor, inode}
    }

    assert KnowledgeRestoreNativeEvidence.reference_witness!(f.root, f.entry) == expected
    assert physical_state(f.path) == before
    assert KnowledgeRestoreOracle.reference_witness!(f.root, f.entry) == expected
    assert physical_state(f.path) == before
  end

  test "wrong expected size fails without mutating the owned file", %{tmp_dir: tmp} do
    f = ciphertext_fixture!(tmp, "wrong-size")
    before = physical_state(f.path)
    wrong = Map.replace!(f.entry, :ciphertext_byte_size, byte_size(@original) + 1)

    assert_raise ArgumentError,
                 "actual alias ciphertext differs from persisted native evidence",
                 fn ->
                   KnowledgeRestoreNativeEvidence.reference_witness!(f.root, wrong)
                 end

    assert physical_state(f.path) == before

    assert_raise ArgumentError,
                 "actual alias ciphertext differs from persisted native evidence",
                 fn ->
                   KnowledgeRestoreOracle.reference_witness!(f.root, wrong)
                 end

    assert physical_state(f.path) == before
  end

  test "wrong expected hash fails at adapter open without mutating the file", %{tmp_dir: tmp} do
    f = ciphertext_fixture!(tmp, "wrong-hash")
    before = physical_state(f.path)
    wrong = Map.replace!(f.entry, :ciphertext_hash, :crypto.hash(:sha256, @foreign))

    assert_raise ArgumentError, "alias ciphertext open failed", fn ->
      KnowledgeRestoreNativeEvidence.reference_witness!(f.root, wrong)
    end

    assert physical_state(f.path) == before

    assert_raise ArgumentError, "alias ciphertext open failed", fn ->
      KnowledgeRestoreOracle.reference_witness!(f.root, wrong)
    end

    assert physical_state(f.path) == before
  end

  test "equal-length replacement preserves identity mode and size on both public paths", %{
    tmp_dir: tmp
  } do
    for {name, replace} <- [
          {"leaf", &KnowledgeRestoreNativeEvidence.replace_ciphertext!/3},
          {"oracle", &KnowledgeRestoreOracle.replace_ciphertext!/3}
        ] do
      f = ciphertext_fixture!(tmp, name)
      {major, minor, inode, mode, size, @original} = physical_state(f.path)
      assert Bitwise.band(mode, 0o7777) == 0o400

      assert replace.(f.root, f.entry, @foreign) == %{
               before: %{
                 physical: {major, minor, inode},
                 mode: mode,
                 sha256: :crypto.hash(:sha256, @original),
                 byte_size: size
               },
               after: %{
                 physical: {major, minor, inode},
                 mode: mode,
                 sha256: :crypto.hash(:sha256, @foreign),
                 byte_size: byte_size(@foreign)
               }
             }

      assert physical_state(f.path) == {major, minor, inode, mode, size, @foreign}
    end
  end

  test "same bytes wrong length and writable mode are rejected without mutation", %{tmp_dir: tmp} do
    for {name, replace} <- [
          {"leaf", &KnowledgeRestoreNativeEvidence.replace_ciphertext!/3},
          {"oracle", &KnowledgeRestoreOracle.replace_ciphertext!/3}
        ],
        kind <- [:same, :wrong_length, :writable] do
      f = ciphertext_fixture!(tmp, "#{name}-#{kind}")
      if kind == :writable, do: File.chmod!(f.path, 0o600)
      before = physical_state(f.path)
      replacement = if kind == :same, do: @original, else: @foreign
      replacement = if kind == :wrong_length, do: replacement <> "!", else: replacement

      assert_raise ArgumentError,
                   "foreign composition requires one genuine read-only equal-length owned ciphertext",
                   fn -> replace.(f.root, f.entry, replacement) end

      assert physical_state(f.path) == before
    end
  end

  test "nonbinary replacement preserves the public function guard", %{tmp_dir: tmp} do
    f = ciphertext_fixture!(tmp, "guard")
    before = physical_state(f.path)

    assert_raise FunctionClauseError, fn ->
      KnowledgeRestoreNativeEvidence.replace_ciphertext!(f.root, f.entry, :not_binary)
    end

    assert physical_state(f.path) == before

    assert_raise FunctionClauseError, fn ->
      KnowledgeRestoreOracle.replace_ciphertext!(f.root, f.entry, :not_binary)
    end

    assert physical_state(f.path) == before
  end

  defp inventory_rows do
    [
      %{
        "id" => "a",
        "vault_id" => "vault-a",
        "key_domain_id" => "domain-a",
        "classification" => "private",
        "lookup_digest" => <<1::256>>,
        "ciphertext_hash" => <<3::256>>,
        "ciphertext_byte_size" => 17,
        "storage_ref" => "reference-a"
      },
      %{
        "id" => "b",
        "vault_id" => "vault-b",
        "key_domain_id" => "domain-b",
        "classification" => "private",
        "lookup_digest" => <<2::256>>,
        "ciphertext_hash" => <<4::256>>,
        "ciphertext_byte_size" => 18,
        "storage_ref" => "reference-b"
      }
    ]
  end

  defp ciphertext_fixture!(tmp, name) do
    root = Path.join(tmp, name)
    File.mkdir!(root)
    File.chmod!(root, 0o700)

    {:ok, path} =
      PathGuard.object_path(root, @vault, @domain, Base.encode16(@lookup, case: :lower))

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, @original, [:binary, :exclusive])
    File.chmod!(path, 0o400)

    %{
      root: root,
      path: path,
      entry: %{
        asset_object_id: @object,
        vault_id: @vault,
        key_domain_id: @domain,
        classification: :private,
        lookup_digest: @lookup,
        ciphertext_hash: :crypto.hash(:sha256, @original),
        ciphertext_byte_size: byte_size(@original),
        storage_ref: @object
      }
    }
  end

  defp physical_state(path) do
    stat = File.lstat!(path)
    {stat.major_device, stat.minor_device, stat.inode, stat.mode, stat.size, File.read!(path)}
  end
end
