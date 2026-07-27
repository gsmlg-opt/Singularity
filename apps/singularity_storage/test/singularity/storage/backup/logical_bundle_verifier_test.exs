defmodule Singularity.Storage.Backup.LogicalBundleVerifierTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Storage.Backup.BundleReader
  alias Singularity.Storage.Backup.LogicalBundleVerifier
  alias Singularity.Storage.Backup.LogicalRecordCodec
  alias Singularity.Storage.Backup.LogicalSchema
  alias Singularity.Storage.Backup.Manifest

  @manifest_id "11111111-1111-4111-8111-111111111111"
  @vault_id "22222222-2222-4222-8222-222222222222"
  @snapshot_id "33333333-3333-4333-8333-333333333333"
  @other_vault_id "44444444-4444-4444-8444-444444444444"
  @related_id "55555555-5555-4555-8555-555555555555"
  @resource_one_id "61000000-0000-4000-8000-000000000001"
  @resource_two_id "62000000-0000-4000-8000-000000000002"
  @outbox_one_id "64000000-0000-4000-8000-000000000004"
  @outbox_two_id "63000000-0000-4000-8000-000000000003"
  @outbox_three_id "65000000-0000-4000-8000-000000000005"
  @object_one_id "71000000-0000-4000-8000-000000000001"
  @object_two_id "72000000-0000-4000-8000-000000000002"
  @key_domain_one_id "81000000-0000-4000-8000-000000000001"
  @key_domain_two_id "82000000-0000-4000-8000-000000000002"

  test "reconstructs the exact authenticated cut" do
    fixture = fixture()

    assert {:ok, cut} = LogicalBundleVerifier.verify(fixture.verified, fixture.binding)

    assert cut == %{
             manifest_id: @manifest_id,
             vault_id: @vault_id,
             snapshot_id: @snapshot_id,
             database_snapshot: "100:120:101,119",
             outbox_high_water_mark: 42,
             object_inventory: [
               %{
                 asset_object_id: @object_one_id,
                 ciphertext_byte_size: byte_size(fixture.raw_one),
                 ciphertext_hash: :crypto.hash(:sha256, fixture.raw_one),
                 classification: :private,
                 inventory_position: 0,
                 key_domain_id: @key_domain_one_id,
                 lookup_digest: :binary.copy(<<0xA1>>, 32),
                 storage_ref: "objects/one",
                 vault_id: @vault_id
               },
               %{
                 asset_object_id: @object_two_id,
                 ciphertext_byte_size: byte_size(fixture.raw_two),
                 ciphertext_hash: :crypto.hash(:sha256, fixture.raw_two),
                 classification: :sensitive,
                 inventory_position: 1,
                 key_domain_id: @key_domain_two_id,
                 lookup_digest: :binary.copy(<<0xA2>>, 32),
                 storage_ref: "objects/two",
                 vault_id: @vault_id
               }
             ]
           }
  end

  test "reconstructs the same cut from bounded record events" do
    fixture = fixture()

    assert {:ok, state} = LogicalBundleVerifier.init(fixture.binding)

    state =
      Enum.reduce(fixture.verified.records, state, fn record, state ->
        assert {:ok, state} =
                 LogicalBundleVerifier.handle_event(
                   state,
                   {:record_start, record.type, byte_size(record.payload)}
                 )

        state =
          record.payload
          |> chunk_binary(3)
          |> Enum.reduce(state, fn chunk, state ->
            assert {:ok, state} =
                     LogicalBundleVerifier.handle_event(state, {:record_chunk, chunk})

            state
          end)

        assert {:ok, state} = LogicalBundleVerifier.handle_event(state, :record_end)
        state
      end)

    assert {:ok, streamed_cut} = LogicalBundleVerifier.finish(state, fixture.verified.manifest)
    assert {:ok, listed_cut} = LogicalBundleVerifier.verify(fixture.verified, fixture.binding)
    assert streamed_cut == listed_cut
  end

  test "rejects pending, manifest, and cut binding mismatches" do
    fixture = fixture()

    assert_invalid(
      LogicalBundleVerifier.verify(fixture.verified, %{
        fixture.binding
        | manifest_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
      })
    )

    assert_invalid(
      LogicalBundleVerifier.verify(fixture.verified, %{
        fixture.binding
        | recovery: put_in(fixture.binding.recovery["wrapper"], "different-wrapper")
      })
    )

    assert_invalid(
      fixture.verified
      |> verified_with_manifest(%{vault_ids: [@vault_id, @other_vault_id]})
      |> LogicalBundleVerifier.verify(fixture.binding)
    )

    assert_invalid(
      fixture
      |> replace_cut(snapshot_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
      |> LogicalBundleVerifier.verify(fixture.binding)
    )

    assert_invalid(
      fixture
      |> replace_cut(outbox_high_water_mark: 43)
      |> LogicalBundleVerifier.verify(fixture.binding)
    )

    assert_invalid(
      LogicalBundleVerifier.verify(fixture.verified, %{fixture.binding | destination_ref: ""})
    )
  end

  test "rejects incomplete or malformed authenticated-reader evidence" do
    fixture = fixture()

    incomplete =
      Map.take(fixture.verified, [
        :__struct__,
        :manifest,
        :records
      ])

    assert_invalid(LogicalBundleVerifier.verify(incomplete, fixture.binding))

    assert_invalid(
      fixture.verified
      |> Map.put(:manifest_hash, <<0::248>>)
      |> LogicalBundleVerifier.verify(fixture.binding)
    )

    assert_invalid(
      fixture.verified
      |> Map.put(:manifest_tag, <<0::120>>)
      |> LogicalBundleVerifier.verify(fixture.binding)
    )
  end

  test "rejects a wrong canonical manifest hash or mismatched manifest inventory" do
    fixture = fixture()

    assert_invalid(
      fixture.verified
      |> Map.put(:manifest_hash, :binary.copy(<<0xBB>>, 32))
      |> LogicalBundleVerifier.verify(fixture.binding)
    )

    inventory_mismatch =
      List.replace_at(
        fixture.verified.records,
        1,
        row_record("core.vaults", %{
          "id" => {"uuid", @vault_id},
          "kind" => {"text", "tampered-kind"}
        })
      )

    assert_invalid(
      fixture.verified
      |> Map.put(:records, inventory_mismatch)
      |> LogicalBundleVerifier.verify(fixture.binding)
    )
  end

  test "rejects outbox sequences outside the authenticated cut or repeated within it" do
    fixture = fixture()
    records = fixture.verified.records

    invalid_record_sets = [
      List.replace_at(
        records,
        4,
        row_record("core.outbox_events", %{
          "id" => {"uuid", @outbox_one_id},
          "sequence" => {"integer", -1},
          "vault_id" => {"uuid", @vault_id}
        })
      ),
      List.replace_at(
        records,
        5,
        row_record("core.outbox_events", %{
          "id" => {"uuid", @outbox_two_id},
          "sequence" => {"integer", 43},
          "vault_id" => {"uuid", @vault_id}
        })
      ),
      List.replace_at(
        records,
        5,
        row_record("core.outbox_events", %{
          "id" => {"uuid", @outbox_three_id},
          "sequence" => {"integer", 4},
          "vault_id" => {"uuid", @vault_id}
        })
      )
    ]

    for invalid_records <- invalid_record_sets do
      assert_invalid(
        invalid_records
        |> verified_with_records(fixture.verified)
        |> LogicalBundleVerifier.verify(fixture.binding)
      )
    end
  end

  test "requires exactly one core.vaults row" do
    fixture = fixture()
    vault_ordinal = table_ordinal("core.vaults")

    zero_vaults =
      fixture.verified.records
      |> List.delete_at(1)
      |> replace_cut_record(table_count_vector: List.replace_at(fixture.counts, vault_ordinal, 0))

    assert_invalid(
      zero_vaults
      |> verified_with_records(fixture.verified)
      |> LogicalBundleVerifier.verify(fixture.binding)
    )

    second_vault = row_record("core.vaults", %{"id" => {"uuid", @vault_id}})

    multiple_vaults =
      fixture.verified.records
      |> List.insert_at(2, second_vault)
      |> replace_cut_record(table_count_vector: List.replace_at(fixture.counts, vault_ordinal, 2))

    assert_invalid(
      multiple_vaults
      |> verified_with_records(fixture.verified)
      |> LogicalBundleVerifier.verify(fixture.binding)
    )
  end

  test "rejects row count, grouping, ordering, duplicate, and vault binding violations" do
    fixture = fixture()
    records = fixture.verified.records

    wrong_counts =
      fixture.counts
      |> List.replace_at(table_ordinal("content.resources"), 1)
      |> List.replace_at(table_ordinal("content.resource_versions"), 1)

    assert_invalid(
      fixture
      |> replace_cut(table_count_vector: wrong_counts)
      |> LogicalBundleVerifier.verify(fixture.binding)
    )

    assert_invalid(
      records
      |> swap(2, 4)
      |> verified_with_records(fixture.verified)
      |> LogicalBundleVerifier.verify(fixture.binding)
    )

    assert_invalid(
      records
      |> swap(2, 3)
      |> verified_with_records(fixture.verified)
      |> LogicalBundleVerifier.verify(fixture.binding)
    )

    assert_invalid(
      records
      |> List.replace_at(3, Enum.at(records, 2))
      |> verified_with_records(fixture.verified)
      |> LogicalBundleVerifier.verify(fixture.binding)
    )

    assert_invalid(
      records
      |> swap(4, 5)
      |> verified_with_records(fixture.verified)
      |> LogicalBundleVerifier.verify(fixture.binding)
    )

    assert_invalid(
      records
      |> List.replace_at(
        2,
        row_record("content.resources", %{
          "id" => {"uuid", @resource_one_id},
          "vault_id" => {"uuid", @other_vault_id}
        })
      )
      |> verified_with_records(fixture.verified)
      |> LogicalBundleVerifier.verify(fixture.binding)
    )

    assert_invalid(
      records
      |> List.replace_at(
        1,
        row_record("core.vaults", %{"id" => {"uuid", @other_vault_id}})
      )
      |> verified_with_records(fixture.verified)
      |> LogicalBundleVerifier.verify(fixture.binding)
    )
  end

  test "rejects object evidence and raw payload integrity violations" do
    fixture = fixture()
    records = fixture.verified.records

    invalid_record_sets = [
      List.replace_at(records, 7, object_record(fixture, 2, @object_two_id)),
      List.replace_at(
        records,
        6,
        object_record(fixture, 0, @object_one_id, vault_id: @other_vault_id)
      ),
      records
      |> List.replace_at(6, object_record(fixture, 0, @object_two_id))
      |> List.replace_at(7, object_record(fixture, 1, @object_one_id)),
      List.replace_at(
        records,
        6,
        object_record(fixture, 0, @object_one_id,
          ciphertext_byte_size: byte_size(fixture.raw_one) + 1
        )
      ),
      List.replace_at(
        records,
        6,
        object_record(fixture, 0, @object_one_id, ciphertext_hash: :binary.copy(<<0xFF>>, 32))
      ),
      List.replace_at(records, 8, %{type: 0x8000, payload: fixture.raw_one <> "tampered"}),
      List.replace_at(records, 8, %{type: 0x7000, payload: fixture.raw_one}),
      swap(records, 8, 9),
      List.delete_at(records, 9),
      records ++ [%{type: 0x8000, payload: "extra"}]
    ]

    for invalid_records <- invalid_record_sets do
      assert_invalid(
        invalid_records
        |> verified_with_records(fixture.verified)
        |> LogicalBundleVerifier.verify(fixture.binding)
      )
    end
  end

  test "rejects unknown or reordered logical frame types" do
    fixture = fixture()
    records = fixture.verified.records

    assert_invalid(
      records
      |> List.replace_at(0, %{type: 0x7000, payload: "unknown"})
      |> verified_with_records(fixture.verified)
      |> LogicalBundleVerifier.verify(fixture.binding)
    )

    assert_invalid(
      records
      |> swap(0, 1)
      |> verified_with_records(fixture.verified)
      |> LogicalBundleVerifier.verify(fixture.binding)
    )
  end

  defp fixture do
    recovery = %{
      "binding" => %{"manifest_id" => @manifest_id, "vault_id" => @vault_id},
      "label" => "backup_recovery",
      "wrapper" => "wrapped-recovery-key"
    }

    rows = [
      row_record("core.vaults", %{"id" => {"uuid", @vault_id}}),
      row_record("content.resources", %{
        "id" => {"uuid", @resource_one_id},
        "vault_id" => {"uuid", @vault_id}
      }),
      row_record("content.resources", %{
        "id" => {"uuid", @resource_two_id},
        "vault_id" => {"uuid", @vault_id}
      }),
      row_record("core.outbox_events", %{
        "id" => {"uuid", @outbox_one_id},
        "sequence" => {"integer", 4},
        "vault_id" => {"uuid", @vault_id}
      }),
      row_record("core.outbox_events", %{
        "id" => {"uuid", @outbox_two_id},
        "sequence" => {"integer", 9},
        "vault_id" => {"uuid", @vault_id}
      })
    ]

    counts = row_counts(rows)
    raw_one = "authenticated-ciphertext-one"
    raw_two = "authenticated-ciphertext-two"

    cut =
      cut_record(%{
        database_snapshot: "100:120:101,119",
        manifest_id: @manifest_id,
        object_count: 2,
        outbox_high_water_mark: 42,
        snapshot_id: @snapshot_id,
        table_count_vector: counts,
        vault_id: @vault_id
      })

    object_one =
      object_record_attrs(%{
        asset_object_id: @object_one_id,
        ciphertext_byte_size: byte_size(raw_one),
        ciphertext_hash: :crypto.hash(:sha256, raw_one),
        classification: "private",
        key_domain_id: @key_domain_one_id,
        lookup_digest: :binary.copy(<<0xA1>>, 32),
        object_index: 0,
        storage_ref: "objects/one",
        vault_id: @vault_id
      })

    object_two =
      object_record_attrs(%{
        asset_object_id: @object_two_id,
        ciphertext_byte_size: byte_size(raw_two),
        ciphertext_hash: :crypto.hash(:sha256, raw_two),
        classification: "sensitive",
        key_domain_id: @key_domain_two_id,
        lookup_digest: :binary.copy(<<0xA2>>, 32),
        object_index: 1,
        storage_ref: "objects/two",
        vault_id: @vault_id
      })

    records =
      [cut | rows] ++
        [
          object_one,
          object_two,
          %{type: 0x8000, payload: raw_one},
          %{type: 0x8000, payload: raw_two}
        ]

    manifest =
      manifest!(records, %{
        manifest_id: @manifest_id,
        outbox_high_water_mark: 42,
        recovery: recovery,
        snapshot_id: @snapshot_id,
        vault_ids: [@vault_id]
      })

    %{
      binding: %{
        destination_ref: "backups/vault-one.sbk",
        manifest_id: @manifest_id,
        recovery: recovery,
        vault_id: @vault_id
      },
      counts: counts,
      raw_one: raw_one,
      raw_two: raw_two,
      verified: verified(manifest, records)
    }
  end

  defp replace_cut(fixture, overrides) do
    fixture.verified.records
    |> replace_cut_record(overrides)
    |> verified_with_records(fixture.verified)
  end

  defp replace_cut_record([record | rest], overrides) do
    {:ok, decoded} = LogicalRecordCodec.decode(record.type, record.payload)

    replacement =
      decoded
      |> Map.delete(:kind)
      |> Map.merge(Map.new(overrides))
      |> cut_record()

    [replacement | rest]
  end

  defp object_record(fixture, object_index, asset_object_id, overrides \\ []) do
    {raw, defaults} =
      case object_index do
        0 ->
          {fixture.raw_one,
           %{
             classification: "private",
             key_domain_id: @key_domain_one_id,
             lookup_digest: :binary.copy(<<0xA1>>, 32),
             storage_ref: "objects/one"
           }}

        _other ->
          {fixture.raw_two,
           %{
             classification: "sensitive",
             key_domain_id: @key_domain_two_id,
             lookup_digest: :binary.copy(<<0xA2>>, 32),
             storage_ref: "objects/two"
           }}
      end

    defaults
    |> Map.merge(%{
      asset_object_id: asset_object_id,
      ciphertext_byte_size: byte_size(raw),
      ciphertext_hash: :crypto.hash(:sha256, raw),
      object_index: object_index,
      vault_id: @vault_id
    })
    |> Map.merge(Map.new(overrides))
    |> object_record_attrs()
  end

  defp cut_record(attrs) do
    assert {:ok, record} = LogicalRecordCodec.encode_cut(attrs)
    record
  end

  defp row_record(table, overrides) do
    {:ok, schema} = LogicalSchema.fetch_table(table)

    values =
      Enum.map(schema.columns, fn column ->
        Map.get_lazy(overrides, column.name, fn -> tagged_value(column) end)
      end)

    primary_key = Enum.map(schema.primary_key, &Enum.at(values, &1.position))
    assert {:ok, record} = LogicalRecordCodec.encode_row(table, primary_key, values)
    record
  end

  defp object_record_attrs(attrs) do
    assert {:ok, record} = LogicalRecordCodec.encode_object(attrs)
    record
  end

  defp tagged_value(%{tag: "uuid"}), do: {"uuid", @related_id}
  defp tagged_value(%{tag: "text", name: name}), do: {"text", "value-#{name}"}
  defp tagged_value(%{tag: "bytes", name: name}), do: {"bytes", :crypto.hash(:sha256, name)}
  defp tagged_value(%{tag: "integer"}), do: {"integer", 1}
  defp tagged_value(%{tag: "boolean"}), do: {"boolean", false}
  defp tagged_value(%{tag: "timestamp"}), do: {"timestamp", "2026-07-23T12:34:56.123456Z"}
  defp tagged_value(%{tag: "json", name: name}), do: {"json", %{"field" => name}}

  defp row_counts(records) do
    counts =
      Enum.reduce(records, %{}, fn record, counts ->
        assert {:ok, %{table_ordinal: ordinal}} =
                 LogicalRecordCodec.decode(record.type, record.payload)

        Map.update(counts, ordinal, 1, &(&1 + 1))
      end)

    Enum.map(0..(LogicalSchema.count() - 1), &Map.get(counts, &1, 0))
  end

  defp table_ordinal(table) do
    {:ok, %{ordinal: ordinal}} = LogicalSchema.fetch_table(table)
    ordinal
  end

  defp verified_with_records(records, %BundleReader.Verified{manifest: manifest}) do
    manifest = manifest!(records, Map.delete(manifest, :inventory))
    verified(manifest, records)
  end

  defp verified_with_manifest(
         %BundleReader.Verified{manifest: manifest, records: records},
         overrides
       ) do
    manifest = manifest!(records, manifest |> Map.delete(:inventory) |> Map.merge(overrides))
    verified(manifest, records)
  end

  defp verified(manifest, records) do
    {:ok, encoded_manifest} = Manifest.encode(manifest)

    %BundleReader.Verified{
      manifest: manifest,
      records: records,
      manifest_hash: :crypto.hash(:sha256, encoded_manifest),
      manifest_tag: :binary.copy(<<0xAA>>, 16)
    }
  end

  defp manifest!(records, attrs) do
    inventory =
      records
      |> Enum.with_index()
      |> Enum.map(fn {%{type: type, payload: payload}, position} ->
        %{
          payload_length: byte_size(payload),
          position: position,
          record_type: type,
          sha256: :crypto.hash(:sha256, payload)
        }
      end)

    assert {:ok, manifest} = Manifest.new(Map.merge(attrs, %{inventory: inventory, version: 1}))
    manifest
  end

  defp swap(values, left, right) do
    left_value = Enum.at(values, left)
    right_value = Enum.at(values, right)

    values
    |> List.replace_at(left, right_value)
    |> List.replace_at(right, left_value)
  end

  defp assert_invalid(result) do
    assert {:error, %Error{code: :backup_invalid}} = result
  end

  defp chunk_binary(binary, size), do: chunk_binary(binary, size, [])

  defp chunk_binary("", _size, chunks), do: Enum.reverse(chunks)

  defp chunk_binary(binary, size, chunks) do
    count = min(size, byte_size(binary))
    <<chunk::binary-size(count), rest::binary>> = binary
    chunk_binary(rest, size, [chunk | chunks])
  end
end
