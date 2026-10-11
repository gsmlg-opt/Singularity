defmodule Singularity.Storage.Backup.LogicalBundleVerifierTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Storage.Backup.BundleReader
  alias Singularity.Storage.Backup.LogicalBundleVerifier
  alias Singularity.Storage.Backup.LogicalRecordCodec
  alias Singularity.Storage.Backup.LogicalSchema
  alias Singularity.Storage.Backup.LogicalSchemaV2
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

    assert fixture.verified.manifest.version == 1
    assert {:ok, cut} = LogicalBundleVerifier.verify(fixture.verified, fixture.binding)

    assert cut == %{
             manifest_id: @manifest_id,
             logical_version: 2,
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

  test "selects the schema from the authenticated cut and accepts coherent V1 and V2" do
    for logical_version <- [1, 2] do
      fixture = fixture(logical_version)

      assert fixture.verified.manifest.version == 1

      assert {:ok, %{logical_version: ^logical_version}} =
               LogicalBundleVerifier.verify(fixture.verified, fixture.binding)
    end
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
    assert %{logical_version: 2} = streamed_cut
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

  test "rejects an authenticated row whose logical version differs from the cut" do
    fixture = fixture(2)
    records = fixture.verified.records

    mixed_row_records =
      List.replace_at(
        records,
        1,
        row_record("core.vaults", %{"id" => {"uuid", @vault_id}}, 1)
      )

    assert_invalid(
      mixed_row_records
      |> verified_with_records(fixture.verified)
      |> LogicalBundleVerifier.verify(fixture.binding)
    )
  end

  test "rejects authenticated object evidence whose logical version differs from the cut" do
    fixture = fixture(2)
    records = fixture.verified.records

    object_position = 1 + Enum.sum(fixture.counts)

    mixed_object_records =
      List.replace_at(
        records,
        object_position,
        object_record(fixture, 0, @object_one_id, [], 1)
      )

    assert {:ok, %{kind: :object, logical_version: 1}} =
             mixed_object_records
             |> Enum.at(object_position)
             |> then(&LogicalRecordCodec.decode(&1.type, &1.payload))

    assert_invalid(
      mixed_object_records
      |> verified_with_records(fixture.verified)
      |> LogicalBundleVerifier.verify(fixture.binding)
    )
  end

  test "rejects an authenticated cut with an unknown logical version" do
    fixture = fixture(2)

    unknown_version_records =
      List.update_at(fixture.verified.records, 0, &record_with_logical_version(&1, 4))

    assert_invalid(
      unknown_version_records
      |> verified_with_records(fixture.verified)
      |> LogicalBundleVerifier.verify(fixture.binding)
    )
  end

  test "reconstructs an authenticated V3 wire cut containing all eight appended table shapes" do
    fixture = v3_fixture()
    assert fixture.verified.manifest.version == 1

    assert {:ok, cut} = LogicalBundleVerifier.verify(fixture.verified, fixture.binding)
    assert {:ok, ^cut} = verify_streamed(fixture.verified, fixture.binding)

    assert cut == %{
             manifest_id: @manifest_id,
             logical_version: 3,
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

  test "both verifier paths reject bidirectional V3 and legacy mixed row versions" do
    fixtures = %{1 => fixture(1), 2 => fixture(2), 3 => v3_fixture()}

    for {cut_version, row_version} <- [{3, 1}, {1, 3}, {3, 2}, {2, 3}] do
      fixture = Map.fetch!(fixtures, cut_version)

      assert {:ok, %{logical_version: ^cut_version}} =
               LogicalBundleVerifier.verify(fixture.verified, fixture.binding)

      assert {:ok, %{logical_version: ^cut_version}} =
               verify_streamed(fixture.verified, fixture.binding)

      mixed_row =
        fixture.verified.records
        |> Enum.at(1)
        |> record_with_logical_version(row_version)

      assert {:ok, %{kind: :row, logical_version: ^row_version}} =
               LogicalRecordCodec.decode(mixed_row.type, mixed_row.payload)

      verified =
        fixture.verified.records
        |> List.replace_at(1, mixed_row)
        |> verified_with_records(fixture.verified)

      assert_invalid_both(verified, fixture.binding)
    end
  end

  test "both verifier paths reject bidirectional V3 and legacy mixed object versions" do
    fixtures = %{1 => fixture(1), 2 => fixture(2), 3 => v3_fixture()}

    for {cut_version, object_version} <- [{3, 1}, {1, 3}, {3, 2}, {2, 3}] do
      fixture = Map.fetch!(fixtures, cut_version)

      assert {:ok, %{logical_version: ^cut_version}} =
               LogicalBundleVerifier.verify(fixture.verified, fixture.binding)

      assert {:ok, %{logical_version: ^cut_version}} =
               verify_streamed(fixture.verified, fixture.binding)

      object_position = 1 + Enum.sum(fixture.counts)

      mixed_object =
        fixture.verified.records
        |> Enum.at(object_position)
        |> record_with_logical_version(object_version)

      assert {:ok, %{kind: :object, logical_version: ^object_version}} =
               LogicalRecordCodec.decode(mixed_object.type, mixed_object.payload)

      verified =
        fixture.verified.records
        |> List.replace_at(object_position, mixed_object)
        |> verified_with_records(fixture.verified)

      assert_invalid_both(verified, fixture.binding)
    end
  end

  test "both verifier paths reject malformed V3 cut vectors and authenticated row schemas" do
    fixture = v3_fixture()

    assert {:ok, %{logical_version: 3}} =
             LogicalBundleVerifier.verify(fixture.verified, fixture.binding)

    assert {:ok, %{logical_version: 3}} = verify_streamed(fixture.verified, fixture.binding)
    [cut | remaining] = fixture.verified.records
    term = :erlang.binary_to_term(cut.payload, [:safe])

    for counts <- [
          Enum.take(fixture.counts, 30),
          Enum.drop(fixture.counts, -1),
          fixture.counts ++ [0],
          List.replace_at(fixture.counts, 30, -1),
          List.replace_at(fixture.counts, 30, "1"),
          fixture.counts |> List.replace_at(30, 0) |> List.replace_at(35, 2)
        ] do
      invalid_cut = wire_record(0x0001, put_elem(term, 7, counts))
      verified = verified_with_records([invalid_cut | remaining], fixture.verified)
      assert_invalid_both(verified, fixture.binding)
    end

    document_row = Enum.at(fixture.verified.records, 6)
    row_term = :erlang.binary_to_term(document_row.payload, [:safe])
    columns = elem(row_term, 4)

    for malformed <- [
          put_elem(row_term, 2, 38),
          put_elem(row_term, 3, []),
          put_elem(row_term, 3, [{"uuid", @snapshot_id}]),
          put_elem(row_term, 4, Enum.drop(columns, -1)),
          put_elem(row_term, 4, List.replace_at(columns, 3, {"bytes", "private"})),
          put_elem(row_term, 4, List.replace_at(columns, 3, {"null"})),
          put_elem(row_term, 4, List.replace_at(columns, 2, {"uuid", @other_vault_id}))
        ] do
      verified =
        fixture.verified.records
        |> List.replace_at(6, wire_record(0x0002, malformed))
        |> verified_with_records(fixture.verified)

      assert_invalid_both(verified, fixture.binding)
    end
  end

  test "both verifier paths reject malformed V3 object evidence and raw-object integrity" do
    fixture = v3_fixture()

    assert {:ok, %{logical_version: 3}} =
             LogicalBundleVerifier.verify(fixture.verified, fixture.binding)

    assert {:ok, %{logical_version: 3}} = verify_streamed(fixture.verified, fixture.binding)
    object_position = 1 + Enum.sum(fixture.counts)
    evidence = Enum.at(fixture.verified.records, object_position)
    term = :erlang.binary_to_term(evidence.payload, [:safe])

    for malformed <- [
          put_elem(term, 2, 1),
          put_elem(term, 4, @other_vault_id),
          put_elem(term, 6, "public"),
          put_elem(term, 7, <<0::248>>),
          put_elem(term, 9, byte_size(fixture.raw_one) + 1),
          put_elem(term, 10, :binary.copy(<<0xFF>>, 32))
        ] do
      verified =
        fixture.verified.records
        |> List.replace_at(object_position, wire_record(0x0003, malformed))
        |> verified_with_records(fixture.verified)

      assert_invalid_both(verified, fixture.binding)
    end

    verified =
      fixture.verified.records
      |> List.replace_at(object_position + 2, %{
        type: 0x8000,
        payload: fixture.raw_one <> "tampered"
      })
      |> verified_with_records(fixture.verified)

    assert_invalid_both(verified, fixture.binding)
  end

  test "both verifier paths reject zero, unknown and forged cut-version terms" do
    fixture = fixture(2)

    for version <- [0, 4, "3", nil, true, {:logical_version, 3}, %{logical_version: 3}] do
      verified =
        fixture.verified.records
        |> List.update_at(0, &record_with_logical_version(&1, version))
        |> verified_with_records(fixture.verified)

      assert_invalid_both(verified, fixture.binding)
    end
  end

  # These independent row terms qualify wire shape only, not historical restore admission.
  defp v3_fixture do
    fixture = fixture(2)
    counts = fixture.counts ++ List.duplicate(1, 8)
    [legacy_cut | _rest] = fixture.verified.records

    cut_term =
      legacy_cut.payload
      |> :erlang.binary_to_term([:safe])
      |> put_elem(1, 3)
      |> put_elem(7, counts)

    inherited_rows =
      fixture.verified.records
      |> Enum.slice(1, 5)
      |> Enum.map(&record_with_logical_version(&1, 3))

    objects =
      fixture.verified.records
      |> Enum.slice(6, 2)
      |> Enum.map(&record_with_logical_version(&1, 3))

    raw_objects = Enum.slice(fixture.verified.records, 8, 2)

    records =
      [wire_record(0x0001, cut_term)] ++ inherited_rows ++ v3_rows() ++ objects ++ raw_objects

    %{fixture | counts: counts, verified: verified_with_records(records, fixture.verified)}
  end

  defp v3_rows do
    uuid = fn id -> {"uuid", id} end
    private = {"text", "private"}
    inserted_at = {"timestamp", "2026-10-11T00:00:00.000000Z"}
    null = {"null"}
    fragment_id = String.duplicate("a", 64)
    digest = {"bytes", :binary.copy(<<0xA1>>, 32)}
    locator = {"json", %{"kind" => "fragment", "ordinal" => 0}}

    [
      {30, [0],
       [
         uuid.(@related_id),
         uuid.(@resource_one_id),
         uuid.(@vault_id),
         private,
         uuid.(@related_id),
         uuid.(@resource_two_id),
         uuid.(@related_id),
         uuid.(@object_one_id),
         digest,
         {"integer", 26},
         {"text", "text/plain"},
         {"text", "Document"},
         uuid.(@related_id),
         {"text", "pending"},
         {"integer", 0},
         null,
         null,
         null,
         null,
         null,
         null,
         inserted_at,
         null,
         null,
         null
       ]},
      {31, [0],
       [
         {"text", fragment_id},
         uuid.(@resource_one_id),
         uuid.(@related_id),
         uuid.(@vault_id),
         private,
         {"integer", 0},
         {"text", "Document text"},
         digest,
         locator,
         inserted_at
       ]},
      {32, [0, 1, 2],
       [
         uuid.(@vault_id),
         uuid.(@related_id),
         uuid.(@snapshot_id),
         digest,
         {"text", "completed"},
         uuid.(@resource_one_id),
         uuid.(@related_id),
         inserted_at
       ]},
      {33, [0, 1],
       [
         uuid.(@related_id),
         uuid.(@snapshot_id),
         uuid.(@resource_two_id),
         uuid.(@vault_id),
         private,
         uuid.(@resource_one_id),
         uuid.(@related_id),
         {"text", "document"},
         {"integer", 0},
         {"text", "source"},
         null,
         inserted_at
       ]},
      {34, [0, 1],
       [
         uuid.(@related_id),
         uuid.(@snapshot_id),
         uuid.(@resource_two_id),
         uuid.(@vault_id),
         private,
         uuid.(@resource_one_id),
         uuid.(@related_id),
         {"text", fragment_id},
         locator,
         {"integer", 0},
         inserted_at
       ]},
      {35, [0],
       [
         uuid.(@related_id),
         uuid.(@vault_id),
         private,
         {"text", "Topic"},
         {"text", "topic"},
         uuid.(@related_id),
         inserted_at
       ]},
      {36, [0, 1, 2],
       [uuid.(@resource_one_id), uuid.(@related_id), uuid.(@vault_id), private, inserted_at]},
      {37, [0],
       [
         uuid.(@related_id),
         uuid.(@vault_id),
         private,
         uuid.(@resource_one_id),
         uuid.(@resource_two_id),
         null,
         {"text", "related_to"},
         uuid.(@related_id),
         inserted_at
       ]}
    ]
    |> Enum.map(fn {ordinal, key_positions, values} ->
      primary_key = Enum.map(key_positions, &Enum.at(values, &1))
      wire_record(0x0002, {"singularity.backup.logical.row", 3, ordinal, primary_key, values})
    end)
  end

  defp wire_record(type, term) do
    payload = :erlang.term_to_binary(term, [:deterministic])
    %{type: type, payload: payload, payload_length: byte_size(payload)}
  end

  defp verify_streamed(verified, binding) do
    with {:ok, state} <- LogicalBundleVerifier.init(binding) do
      events =
        Enum.flat_map(verified.records, fn record ->
          [{:record_start, record.type, byte_size(record.payload)}] ++
            Enum.map(chunk_binary(record.payload, 3), &{:record_chunk, &1}) ++ [:record_end]
        end)

      result =
        Enum.reduce_while(events, {:ok, state}, fn event, {:ok, state} ->
          case LogicalBundleVerifier.handle_event(state, event) do
            {:ok, next_state} -> {:cont, {:ok, next_state}}
            {:error, %Error{}} = error -> {:halt, error}
          end
        end)

      with {:ok, state} <- result do
        LogicalBundleVerifier.finish(state, verified.manifest)
      end
    end
  end

  defp assert_invalid_both(verified, binding) do
    assert_invalid(LogicalBundleVerifier.verify(verified, binding))
    assert_invalid(verify_streamed(verified, binding))
  end

  defp fixture(logical_version \\ 2) do
    recovery = %{
      "binding" => %{"manifest_id" => @manifest_id, "vault_id" => @vault_id},
      "label" => "backup_recovery",
      "wrapper" => "wrapped-recovery-key"
    }

    rows = [
      row_record("core.vaults", %{"id" => {"uuid", @vault_id}}, logical_version),
      row_record(
        "content.resources",
        %{
          "id" => {"uuid", @resource_one_id},
          "vault_id" => {"uuid", @vault_id},
          "kind" => {"text", "asset"},
          "current_version_id" => {"null"}
        },
        logical_version
      ),
      row_record(
        "content.resources",
        %{
          "id" => {"uuid", @resource_two_id},
          "vault_id" => {"uuid", @vault_id},
          "kind" => {"text", "asset"},
          "current_version_id" => {"null"}
        },
        logical_version
      ),
      row_record(
        "core.outbox_events",
        %{
          "id" => {"uuid", @outbox_one_id},
          "sequence" => {"integer", 4},
          "vault_id" => {"uuid", @vault_id}
        },
        logical_version
      ),
      row_record(
        "core.outbox_events",
        %{
          "id" => {"uuid", @outbox_two_id},
          "sequence" => {"integer", 9},
          "vault_id" => {"uuid", @vault_id}
        },
        logical_version
      )
    ]

    counts = row_counts(rows, logical_version)
    raw_one = "authenticated-ciphertext-one"
    raw_two = "authenticated-ciphertext-two"

    cut =
      cut_record(
        %{
          database_snapshot: "100:120:101,119",
          manifest_id: @manifest_id,
          object_count: 2,
          outbox_high_water_mark: 42,
          snapshot_id: @snapshot_id,
          table_count_vector: counts,
          vault_id: @vault_id
        },
        logical_version
      )

    object_one =
      object_record_attrs(
        %{
          asset_object_id: @object_one_id,
          ciphertext_byte_size: byte_size(raw_one),
          ciphertext_hash: :crypto.hash(:sha256, raw_one),
          classification: "private",
          key_domain_id: @key_domain_one_id,
          lookup_digest: :binary.copy(<<0xA1>>, 32),
          object_index: 0,
          storage_ref: "objects/one",
          vault_id: @vault_id
        },
        logical_version
      )

    object_two =
      object_record_attrs(
        %{
          asset_object_id: @object_two_id,
          ciphertext_byte_size: byte_size(raw_two),
          ciphertext_hash: :crypto.hash(:sha256, raw_two),
          classification: "sensitive",
          key_domain_id: @key_domain_two_id,
          lookup_digest: :binary.copy(<<0xA2>>, 32),
          object_index: 1,
          storage_ref: "objects/two",
          vault_id: @vault_id
        },
        logical_version
      )

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
    logical_version = decoded.logical_version

    replacement =
      decoded
      |> Map.drop([:kind, :logical_version])
      |> Map.merge(Map.new(overrides))
      |> cut_record(logical_version)

    [replacement | rest]
  end

  defp object_record(
         fixture,
         object_index,
         asset_object_id,
         overrides \\ [],
         logical_version \\ 2
       ) do
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
    |> object_record_attrs(logical_version)
  end

  defp cut_record(attrs, logical_version) do
    assert {:ok, record} = LogicalRecordCodec.encode_cut(attrs, logical_version)
    record
  end

  defp row_record(table, overrides, logical_version \\ 2) do
    schema_module = logical_schema(logical_version)
    {:ok, schema} = schema_module.fetch_table(table)

    values =
      Enum.map(schema.columns, fn column ->
        Map.get_lazy(overrides, column.name, fn -> tagged_value(column) end)
      end)

    primary_key = Enum.map(schema.primary_key, &Enum.at(values, &1.position))

    assert {:ok, record} =
             LogicalRecordCodec.encode_row(table, primary_key, values, logical_version)

    record
  end

  defp object_record_attrs(attrs, logical_version) do
    assert {:ok, record} = LogicalRecordCodec.encode_object(attrs, logical_version)
    record
  end

  defp tagged_value(%{tag: "uuid"}), do: {"uuid", @related_id}
  defp tagged_value(%{tag: "text", name: name}), do: {"text", "value-#{name}"}
  defp tagged_value(%{tag: "bytes", name: name}), do: {"bytes", :crypto.hash(:sha256, name)}
  defp tagged_value(%{tag: "integer"}), do: {"integer", 1}
  defp tagged_value(%{tag: "boolean"}), do: {"boolean", false}
  defp tagged_value(%{tag: "timestamp"}), do: {"timestamp", "2026-07-23T12:34:56.123456Z"}
  defp tagged_value(%{tag: "json", name: name}), do: {"json", %{"field" => name}}

  defp row_counts(records, logical_version) do
    counts =
      Enum.reduce(records, %{}, fn record, counts ->
        assert {:ok, %{table_ordinal: ordinal}} =
                 LogicalRecordCodec.decode(record.type, record.payload)

        Map.update(counts, ordinal, 1, &(&1 + 1))
      end)

    schema_module = logical_schema(logical_version)
    Enum.map(0..(schema_module.count() - 1), &Map.get(counts, &1, 0))
  end

  defp table_ordinal(table, logical_version \\ 2) do
    schema_module = logical_schema(logical_version)
    {:ok, %{ordinal: ordinal}} = schema_module.fetch_table(table)
    ordinal
  end

  defp logical_schema(1), do: LogicalSchema
  defp logical_schema(2), do: LogicalSchemaV2

  defp record_with_logical_version(record, logical_version) do
    term = :erlang.binary_to_term(record.payload, [:safe])
    payload = term |> put_elem(1, logical_version) |> :erlang.term_to_binary([:deterministic])
    %{record | payload: payload, payload_length: byte_size(payload)}
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
