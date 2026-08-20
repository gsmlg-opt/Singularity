defmodule Singularity.Storage.Backup.LogicalV1CompatibilityTest do
  use ExUnit.Case, async: true

  alias Singularity.Storage.Backup.BundleReader
  alias Singularity.Storage.Backup.LocalDestination
  alias Singularity.Storage.Backup.LogicalBundleVerifier
  alias Singularity.Storage.Backup.LogicalRecordCodec
  alias Singularity.Storage.Backup.LogicalSchema
  alias Singularity.Storage.Backup.LogicalSchemaV2
  alias Singularity.Storage.Crypto.Argon2KeyDeriver

  @fixture_sha256 "75605267628f11cb694b8ae05cd9b43fcdb87ae0c240fcc98c87ab143045b6b2"
  @passphrase "singularity-v1-compatibility-passphrase"

  defmodule FixtureCrypto do
    @moduledoc false

    alias Singularity.Storage.Crypto.ChunkedAEAD
    alias Singularity.Storage.Crypto.Format

    @backup_encryption_domain_id "9c22b7fa-ff48-4ee2-a49a-d23464393618"
    @manifest_record_type 0xFFFF

    def decrypt_all(<<_::binary-size(32)>> = key, public_header, encrypted) do
      expected = %{
        algorithm: Format.algorithm(),
        chunk_index: 0,
        chunk_size: Format.chunk_size(),
        encryption_domain_id: @backup_encryption_domain_id,
        format_version: Format.format_version(),
        key: key,
        object_id: public_header.manifest_id,
        vault_id: public_header.vault_id
      }

      with {:ok, plaintext} <- ChunkedAEAD.decode(encrypted, expected),
           {:ok, encoded_manifest} <- final_manifest(plaintext),
           final_record <- binary_part(encrypted, byte_size(encrypted) - 68, 68),
           {:ok, manifest_tag} <- ChunkedAEAD.final_tag(final_record) do
        {:ok, plaintext,
         %{
           manifest_hash: :crypto.hash(:sha256, encoded_manifest),
           manifest_tag: manifest_tag
         }}
      end
    end

    defp final_manifest(encoded), do: final_manifest(encoded, nil)

    defp final_manifest("", {@manifest_record_type, payload}), do: {:ok, payload}

    defp final_manifest(
           <<type::unsigned-big-16, size::unsigned-big-64, payload::binary-size(size),
             rest::binary>>,
           _previous
         ),
         do: final_manifest(rest, {type, payload})

    defp final_manifest(_encoded, _previous), do: :error
  end

  test "checked-in authenticated pre-Notes bundle remains a genuine logical V1 fixture" do
    fixture = fixture_path()
    encoded = File.read!(fixture)

    assert Base.encode16(:crypto.hash(:sha256, encoded), case: :lower) == @fixture_sha256

    root = Path.dirname(fixture)
    filename = Path.basename(fixture)
    assert {:ok, source} = LocalDestination.reader_source(%{backup_root: root}, filename)
    assert {:ok, public_header} = BundleReader.read_public_header(source)
    assert public_header.version == 1

    assert {:ok, backup_key} = derive_key(public_header.kdf)

    assert {:ok, verified} =
             BundleReader.authenticate_all(source, crypto: {FixtureCrypto, backup_key})

    assert verified.manifest.version == 1
    assert [%{type: 0x0001, payload: cut_payload} | _records] = verified.records

    assert {"singularity.backup.logical.cut", 1, _manifest_id, _vault_id, _snapshot_id,
            _database_snapshot, _outbox_high_water_mark, table_counts,
            _object_count} =
             :erlang.binary_to_term(cut_payload, [:safe])

    assert length(table_counts) == 28
    assert {:ok, %{kind: :cut}} = LogicalRecordCodec.decode(0x0001, cut_payload)

    binding = %{
      destination_ref: filename,
      manifest_id: public_header.manifest_id,
      recovery: verified.manifest.recovery,
      vault_id: public_header.vault_id
    }

    assert {:ok, %{manifest_id: manifest_id, vault_id: vault_id}} =
             LogicalBundleVerifier.verify(verified, binding)

    assert manifest_id == public_header.manifest_id
    assert vault_id == public_header.vault_id

    assert {:error, %{code: :backup_invalid}} =
             authenticate_with_passphrase(source, public_header, @passphrase <> "-wrong")
  end

  test "logical V1 is frozen while V2 appends Notes without renumbering history" do
    assert LogicalSchema.version() == 1
    assert LogicalSchema.count() == 28
    assert Enum.sum(Enum.map(LogicalSchema.all(), &length(&1.columns))) == 257

    assert LogicalSchemaV2.version() == 2
    assert LogicalSchemaV2.count() == 30
    assert LogicalSchemaV2.column_count() == 280
    assert LogicalRecordCodec.default_version() == 2

    for v1 <- LogicalSchema.all() do
      assert {:ok, v2} = LogicalSchemaV2.fetch_ordinal(v1.ordinal)
      assert v2.table == v1.table
      assert v2.ordinal == v1.ordinal
      assert Enum.take(v2.columns, length(v1.columns)) == v1.columns
      assert v2.primary_key == v1.primary_key
    end

    assert {:ok, resources} = LogicalSchemaV2.fetch_table("content.resources")

    assert Enum.map(Enum.drop(resources.columns, 8), &{&1.name, &1.tag, &1.nullable?}) == [
             {"kind", "text", false},
             {"current_version_id", "uuid", true}
           ]

    assert {:ok, %{ordinal: 28, columns: note_columns}} =
             LogicalSchemaV2.fetch_table("content.note_versions")

    assert length(note_columns) == 10

    assert {:ok, %{ordinal: 29, columns: conflict_columns}} =
             LogicalSchemaV2.fetch_table("content.note_conflicts")

    assert length(conflict_columns) == 11
    assert :error = LogicalSchemaV2.fetch_table("content.note_search_documents")
    assert :error = LogicalSchemaV2.fetch_table("content.note_mutation_receipts")
  end

  defp authenticate_with_passphrase(source, public_header, passphrase) do
    with {:ok, key} <- derive_key(public_header.kdf, passphrase) do
      BundleReader.authenticate_all(source, crypto: {FixtureCrypto, key})
    end
  end

  defp derive_key(kdf, passphrase \\ @passphrase) do
    with {:ok, salt} <- Base.decode64(kdf["salt"]) do
      Argon2KeyDeriver.derive(passphrase, salt, %{
        version: kdf["parameters"]["version"],
        t_cost: kdf["parameters"]["t_cost"],
        m_cost: kdf["parameters"]["m_cost"],
        parallelism: kdf["parameters"]["parallelism"]
      })
    end
  end

  defp fixture_path do
    Path.expand("../../../fixtures/backup/logical-v1-pre-notes.backup", __DIR__)
  end
end
