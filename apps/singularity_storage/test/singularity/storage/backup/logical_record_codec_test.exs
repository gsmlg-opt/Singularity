defmodule Singularity.Storage.Backup.LogicalRecordCodecTest do
  use ExUnit.Case, async: true

  alias Singularity.Storage.Backup.LogicalRecordCodec
  alias Singularity.Storage.Backup.LogicalSchema
  alias Singularity.Storage.Backup.LogicalSchemaV2
  alias Singularity.Core.Error

  @manifest_id "00000000-0000-4000-8000-000000000a01"
  @vault_id "00000000-0000-4000-8000-000000000a02"
  @snapshot_id "00000000-0000-4000-8000-000000000a03"
  @object_id "00000000-0000-4000-8000-000000000a04"
  @key_domain_id "00000000-0000-4000-8000-000000000a05"
  @record_payload_limit 16 * 1024 * 1024
  @logical_v1_contract_sha256 "e7d4d4a31c99edb4a7e23ea592bd563eb5644aead6ed29538b692a0c5157083a"
  @logical_v1_tables [
    "identity.people",
    "identity.accounts",
    "identity.credentials",
    "identity.principals",
    "core.capabilities",
    "core.vaults",
    "core.vault_members",
    "core.principal_capabilities",
    "identity.devices",
    "core.key_domains",
    "core.vault_key_versions",
    "core.vault_key_wrappers",
    "core.domain_key_versions",
    "core.domain_dedup_key_wrappers",
    "content.resources",
    "content.resource_versions",
    "content.asset_objects",
    "content.assets",
    "content.asset_key_envelopes",
    "content.asset_metadata",
    "content.resource_assets",
    "content.source_references",
    "content.tombstones",
    "audit.events",
    "core.outbox_events",
    "jobs.job_submissions",
    "jobs.job_progress",
    "jobs.effect_receipts"
  ]

  test "publishes versioned logical restore table order with version two as the default" do
    assert LogicalRecordCodec.default_version() == 2
    assert LogicalRecordCodec.tables(1) == @logical_v1_tables

    assert LogicalRecordCodec.tables(2) ==
             @logical_v1_tables ++ ["content.note_versions", "content.note_conflicts"]

    assert LogicalRecordCodec.tables() == LogicalRecordCodec.tables(2)
  end

  test "publishes the exact version-one schema registry and sanitized key slots" do
    assert LogicalSchema.version() == 1
    assert LogicalSchema.count() == 28

    assert Enum.map(LogicalSchema.all(), &{&1.ordinal, &1.table}) ==
             LogicalRecordCodec.tables(1)
             |> Enum.with_index()
             |> Enum.map(fn {table, ordinal} -> {ordinal, table} end)

    assert Enum.sum(Enum.map(LogicalSchema.all(), &length(&1.columns))) == 257
    assert schema_contract_sha256(LogicalSchema) == @logical_v1_contract_sha256

    for schema <- LogicalSchema.all() do
      assert MapSet.size(MapSet.new(schema.columns, & &1.name)) == length(schema.columns)
      assert schema.primary_key != []

      for primary_key <- schema.primary_key do
        assert Enum.at(schema.columns, primary_key.position).tag == primary_key.tag
      end
    end

    assert {:ok,
            %{
              version: 1,
              ordinal: 2,
              table: "identity.credentials",
              columns: [
                %{name: "id", tag: "uuid", nullable?: false},
                %{name: "account_id", tag: "uuid", nullable?: false},
                %{name: "normalized_login", tag: "text", nullable?: false},
                %{name: "revoked_at", tag: "timestamp", nullable?: true},
                %{name: "inserted_at", tag: "timestamp", nullable?: false}
              ],
              primary_key: [%{position: 0, tag: "uuid"}]
            }} = LogicalSchema.fetch_table("identity.credentials")

    assert {:ok,
            %{
              version: 1,
              ordinal: 11,
              table: "core.vault_key_wrappers",
              columns: [
                %{name: "id", tag: "uuid", nullable?: false},
                %{name: "vault_id", tag: "uuid", nullable?: false},
                %{name: "vault_key_version_id", tag: "uuid", nullable?: false},
                %{name: "account_id", tag: "uuid", nullable?: false},
                %{name: "generation", tag: "integer", nullable?: false},
                %{name: "inserted_at", tag: "timestamp", nullable?: false}
              ],
              primary_key: [%{position: 0, tag: "uuid"}]
            }} = LogicalSchema.fetch_ordinal(11)

    assert {:ok,
            %{
              version: 1,
              ordinal: 23,
              table: "audit.events",
              columns: [
                %{name: "id", tag: "uuid", nullable?: false},
                %{name: "vault_id", tag: "uuid", nullable?: true},
                %{name: "actor_kind", tag: "text", nullable?: false},
                %{name: "principal_id", tag: "uuid", nullable?: true},
                %{name: "anonymous_fingerprint", tag: "bytes", nullable?: true},
                %{name: "system_principal_name", tag: "text", nullable?: true},
                %{name: "operation", tag: "text", nullable?: false},
                %{name: "result", tag: "text", nullable?: false},
                %{name: "classification", tag: "text", nullable?: false},
                %{name: "correlation_id", tag: "uuid", nullable?: false},
                %{name: "target_type", tag: "text", nullable?: false},
                %{name: "target_id", tag: "uuid", nullable?: false},
                %{name: "metadata", tag: "json", nullable?: false},
                %{name: "occurred_at", tag: "timestamp", nullable?: false},
                %{name: "inserted_at", tag: "timestamp", nullable?: false}
              ],
              primary_key: [%{position: 0, tag: "uuid"}]
            }} = LogicalSchema.fetch_table("audit.events")

    assert :error = LogicalSchema.fetch_table("core.data_classifications")
    assert :error = LogicalSchema.fetch_ordinal(28)
  end

  test "publishes the exact version-two schema while preserving every version-one ordinal" do
    assert LogicalSchemaV2.version() == 2
    assert LogicalSchemaV2.count() == 30
    assert LogicalSchemaV2.column_count() == 280
    assert Enum.sum(Enum.map(LogicalSchemaV2.all(), &length(&1.columns))) == 280

    for v1_schema <- LogicalSchema.all() do
      assert {:ok, v2_schema} = LogicalSchemaV2.fetch_table(v1_schema.table)
      assert v2_schema.version == 2
      assert v2_schema.ordinal == v1_schema.ordinal
      assert v2_schema.table == v1_schema.table
      assert Enum.take(v2_schema.columns, length(v1_schema.columns)) == v1_schema.columns
      assert v2_schema.primary_key == v1_schema.primary_key
    end

    assert {:ok, v1_resources} = LogicalSchema.fetch_table("content.resources")

    assert {:ok,
            %{
              version: 2,
              ordinal: 14,
              table: "content.resources",
              columns: resource_columns,
              primary_key: [%{position: 0, tag: "uuid"}]
            }} = LogicalSchemaV2.fetch_ordinal(14)

    assert resource_columns ==
             v1_resources.columns ++
               [
                 %{name: "kind", tag: "text", nullable?: false},
                 %{name: "current_version_id", tag: "uuid", nullable?: true}
               ]

    assert {:ok,
            %{
              version: 2,
              ordinal: 28,
              table: "content.note_versions",
              columns: [
                %{name: "resource_version_id", tag: "uuid", nullable?: false},
                %{name: "resource_id", tag: "uuid", nullable?: false},
                %{name: "vault_id", tag: "uuid", nullable?: false},
                %{name: "classification", tag: "text", nullable?: false},
                %{name: "title", tag: "text", nullable?: false},
                %{name: "markdown", tag: "text", nullable?: false},
                %{name: "created_by_principal_id", tag: "uuid", nullable?: false},
                %{name: "parent_version_id", tag: "uuid", nullable?: true},
                %{name: "merge_parent_version_id", tag: "uuid", nullable?: true},
                %{name: "inserted_at", tag: "timestamp", nullable?: false}
              ],
              primary_key: [%{position: 0, tag: "uuid"}]
            }} = LogicalSchemaV2.fetch_ordinal(28)

    assert {:ok,
            %{
              version: 2,
              ordinal: 29,
              table: "content.note_conflicts",
              columns: [
                %{name: "id", tag: "uuid", nullable?: false},
                %{name: "resource_id", tag: "uuid", nullable?: false},
                %{name: "vault_id", tag: "uuid", nullable?: false},
                %{name: "classification", tag: "text", nullable?: false},
                %{name: "base_version_id", tag: "uuid", nullable?: false},
                %{name: "canonical_version_id", tag: "uuid", nullable?: false},
                %{name: "competing_version_id", tag: "uuid", nullable?: false},
                %{name: "state", tag: "text", nullable?: false},
                %{name: "resolution_version_id", tag: "uuid", nullable?: true},
                %{name: "created_at", tag: "timestamp", nullable?: false},
                %{name: "resolved_at", tag: "timestamp", nullable?: true}
              ],
              primary_key: [%{position: 0, tag: "uuid"}]
            }} = LogicalSchemaV2.fetch_table("content.note_conflicts")

    assert :error = LogicalSchemaV2.fetch_table("content.note_search_documents")
    assert :error = LogicalSchemaV2.fetch_table("content.note_mutation_receipts")
    assert :error = LogicalSchemaV2.fetch_ordinal(30)
  end

  test "encodes and decodes a canonical cut header record" do
    counts = Enum.to_list(0..29)

    attrs = %{
      manifest_id: @manifest_id,
      vault_id: @vault_id,
      snapshot_id: @snapshot_id,
      database_snapshot: "100:120:101,119",
      outbox_high_water_mark: 42,
      table_count_vector: counts,
      object_count: 3
    }

    assert {:ok, %{type: 0x0001, payload: payload, payload_length: payload_length} = record} =
             LogicalRecordCodec.encode_cut(attrs)

    assert payload_length == byte_size(payload)
    refute match?(<<131, 80, _::binary>>, payload)

    assert LogicalRecordCodec.descriptor(record) == %{
             record_type: 0x0001,
             payload_length: payload_length,
             sha256: :crypto.hash(:sha256, payload)
           }

    assert {:ok, %{kind: :cut, table_count_vector: ^counts} = decoded} =
             LogicalRecordCodec.decode(record.type, payload)

    assert decoded.logical_version == 2
    assert Map.drop(decoded, [:kind, :logical_version]) == attrs
    assert {:ok, ^record} = LogicalRecordCodec.encode_cut(attrs, 2)
  end

  test "enforces the snapshot and total non-manifest frame bounds at the cut" do
    exact_snapshot =
      "1:2:" <> Enum.join(["10" | List.duplicate("1", 2_045)], ",")

    assert byte_size(exact_snapshot) == 4_096

    exact_counts = [999_998 | List.duplicate(0, 29)]

    assert {:ok, _record} =
             LogicalRecordCodec.encode_cut(
               cut_attrs(database_snapshot: exact_snapshot, table_count_vector: exact_counts)
             )

    over_snapshot =
      "1:2:" <> Enum.join(["100" | List.duplicate("1", 2_045)], ",")

    assert byte_size(over_snapshot) == 4_097

    assert_invalid(LogicalRecordCodec.encode_cut(cut_attrs(database_snapshot: over_snapshot)))

    assert_invalid(
      LogicalRecordCodec.encode_cut(
        cut_attrs(table_count_vector: [999_999 | List.duplicate(0, 29)])
      )
    )

    assert {:ok, _record} =
             LogicalRecordCodec.encode_cut(cut_attrs(object_count: 499_999))

    assert_invalid(LogicalRecordCodec.encode_cut(cut_attrs(object_count: 500_000)))
  end

  test "round trips explicitly requested version-one cut, row, and object records" do
    cut_attrs = cut_attrs(table_count_vector: List.duplicate(0, 28))

    assert {:ok, cut_record} = LogicalRecordCodec.encode_cut(cut_attrs, 1)

    assert {:ok, %{kind: :cut, logical_version: 1} = decoded_cut} =
             LogicalRecordCodec.decode(cut_record.type, cut_record.payload)

    assert Map.drop(decoded_cut, [:kind, :logical_version]) == cut_attrs

    {primary_key_values, ordered_column_values} = valid_row("content.resources", 1)

    assert {:ok, row_record} =
             LogicalRecordCodec.encode_row(
               "content.resources",
               primary_key_values,
               ordered_column_values,
               1
             )

    assert {:ok,
            %{
              kind: :row,
              logical_version: 1,
              table: "content.resources",
              table_ordinal: 14,
              primary_key_values: ^primary_key_values,
              ordered_column_values: ^ordered_column_values
            }} = LogicalRecordCodec.decode(row_record.type, row_record.payload)

    object_attrs = object_attrs()
    assert {:ok, object_record} = LogicalRecordCodec.encode_object(object_attrs, 1)

    assert {:ok, %{kind: :object, logical_version: 1} = decoded_object} =
             LogicalRecordCodec.decode(object_record.type, object_record.payload)

    assert Map.drop(decoded_object, [:kind, :logical_version]) == object_attrs
  end

  test "rejects unknown logical versions and records shaped for another schema version" do
    {v1_primary_key, v1_values} = valid_row("content.resources", 1)
    {v2_primary_key, v2_values} = valid_row("content.resources", 2)
    v1_cut_attrs = cut_attrs(table_count_vector: List.duplicate(0, 28))
    v2_cut_attrs = cut_attrs()
    object_attrs = object_attrs()

    assert {:ok, cut_record} = LogicalRecordCodec.encode_cut(v2_cut_attrs)

    assert {:ok, row_record} =
             LogicalRecordCodec.encode_row("content.resources", v2_primary_key, v2_values)

    assert {:ok, object_record} = LogicalRecordCodec.encode_object(object_attrs)

    for invalid_version <- [0, 3, "2"] do
      assert_invalid(LogicalRecordCodec.encode_cut(v2_cut_attrs, invalid_version))

      assert_invalid(
        LogicalRecordCodec.encode_row(
          "content.resources",
          v2_primary_key,
          v2_values,
          invalid_version
        )
      )

      assert_invalid(LogicalRecordCodec.encode_object(object_attrs, invalid_version))

      for record <- [cut_record, row_record, object_record] do
        assert_invalid(
          LogicalRecordCodec.decode(
            record.type,
            replace_wire_version(record.payload, invalid_version)
          )
        )
      end
    end

    assert_invalid(LogicalRecordCodec.encode_cut(v1_cut_attrs, 2))
    assert_invalid(LogicalRecordCodec.encode_cut(v2_cut_attrs, 1))

    assert_invalid(
      LogicalRecordCodec.encode_row("content.resources", v1_primary_key, v1_values, 2)
    )

    assert_invalid(
      LogicalRecordCodec.encode_row("content.resources", v2_primary_key, v2_values, 1)
    )

    assert_invalid(
      LogicalRecordCodec.decode(
        0x0002,
        wire({"singularity.backup.logical.row", 2, 14, v1_primary_key, v1_values})
      )
    )

    assert_invalid(
      LogicalRecordCodec.decode(
        0x0002,
        wire({"singularity.backup.logical.row", 1, 14, v2_primary_key, v2_values})
      )
    )
  end

  test "encodes row values with deterministic JSON map ordering" do
    json_entries = Enum.map(0..40, &{"key-#{&1}", &1})
    json_forward = Map.new(json_entries)
    json_reverse = json_entries |> Enum.reverse() |> Map.new()
    primary_key_values = [{"uuid", @manifest_id}]

    values = [
      {"uuid", @manifest_id},
      {"text", "Alice"},
      {"json", json_forward},
      {"timestamp", "2026-07-23T12:34:56.123456Z"},
      {"timestamp", "2026-07-23T12:34:56.123456Z"}
    ]

    reverse_values = List.replace_at(values, 2, {"json", json_reverse})

    assert {:ok, %{type: 0x0002} = record} =
             LogicalRecordCodec.encode_row(
               "identity.people",
               primary_key_values,
               values
             )

    assert {:ok, reverse_record} =
             LogicalRecordCodec.encode_row(
               "identity.people",
               primary_key_values,
               reverse_values
             )

    assert record.payload == reverse_record.payload

    assert {:ok,
            %{
              kind: :row,
              logical_version: 2,
              table: "identity.people",
              table_ordinal: 0,
              primary_key_values: ^primary_key_values,
              ordered_column_values: ^values
            }} = LogicalRecordCodec.decode(record.type, record.payload)

    assert {:ok, ^record} =
             LogicalRecordCodec.encode_row(
               "identity.people",
               primary_key_values,
               values,
               2
             )

    assert LogicalRecordCodec.descriptor(record) == %{
             record_type: 0x0002,
             payload_length: record.payload_length,
             sha256: :crypto.hash(:sha256, record.payload)
           }
  end

  test "enforces arity, tags, nullability, and primary-key equality for every schema" do
    for schema <- LogicalSchemaV2.all() do
      {primary_key_values, ordered_column_values} = valid_row(schema)

      assert {:ok, record} =
               LogicalRecordCodec.encode_row(
                 schema.table,
                 primary_key_values,
                 ordered_column_values
               )

      assert {:ok,
              %{
                logical_version: 2,
                table: table,
                table_ordinal: ordinal,
                primary_key_values: ^primary_key_values,
                ordered_column_values: ^ordered_column_values
              }} = LogicalRecordCodec.decode(record.type, record.payload)

      assert table == schema.table
      assert ordinal == schema.ordinal

      assert_invalid(
        LogicalRecordCodec.encode_row(
          schema.table,
          primary_key_values,
          Enum.drop(ordered_column_values, -1)
        )
      )

      assert_invalid(
        LogicalRecordCodec.encode_row(
          schema.table,
          primary_key_values,
          ordered_column_values ++ [{"null"}]
        )
      )

      for {column, position} <- Enum.with_index(schema.columns) do
        wrong_tag_values =
          List.replace_at(ordered_column_values, position, wrong_tag_value(column.tag))

        assert_invalid(
          LogicalRecordCodec.encode_row(schema.table, primary_key_values, wrong_tag_values)
        )

        null_values = List.replace_at(ordered_column_values, position, {"null"})

        if column.nullable? do
          assert {:ok, _record} =
                   LogicalRecordCodec.encode_row(schema.table, primary_key_values, null_values)
        else
          assert_invalid(
            LogicalRecordCodec.encode_row(schema.table, primary_key_values, null_values)
          )
        end
      end

      for {primary_key, primary_position} <- Enum.with_index(schema.primary_key) do
        null_primary_key = List.replace_at(primary_key_values, primary_position, {"null"})

        null_primary_columns =
          List.replace_at(ordered_column_values, primary_key.position, {"null"})

        assert_invalid(
          LogicalRecordCodec.encode_row(
            schema.table,
            null_primary_key,
            null_primary_columns
          )
        )

        mismatched_primary_key =
          List.replace_at(primary_key_values, primary_position, {"uuid", @object_id})

        assert_invalid(
          LogicalRecordCodec.encode_row(
            schema.table,
            mismatched_primary_key,
            ordered_column_values
          )
        )
      end
    end
  end

  test "decode independently enforces the registered row schema" do
    {primary_key_values, ordered_column_values} = valid_row("identity.people")

    invalid_terms = [
      {"singularity.backup.logical.row", 1, 0, primary_key_values,
       Enum.drop(ordered_column_values, -1)},
      {"singularity.backup.logical.row", 1, 0, primary_key_values,
       List.replace_at(ordered_column_values, 1, {"bytes", <<1>>})},
      {"singularity.backup.logical.row", 1, 0, primary_key_values,
       List.replace_at(ordered_column_values, 1, {"null"})},
      {"singularity.backup.logical.row", 1, 0, [{"uuid", @object_id}], ordered_column_values}
    ]

    for term <- invalid_terms do
      assert_invalid(LogicalRecordCodec.decode(0x0002, wire(term)))
    end
  end

  test "rejects unknown tables and non-canonical row value containers" do
    {valid_pk, valid_values} = valid_row("identity.people")

    invalid_rows = [
      {"unknown.table", valid_pk, valid_values},
      {"identity.people", [], valid_values},
      {"identity.people", {"uuid", @manifest_id}, valid_values},
      {"identity.people", [{"null"}], valid_values},
      {"identity.people", [hd(valid_pk), {"null"}], valid_values},
      {"identity.people", [{:uuid, @manifest_id}], valid_values},
      {"identity.people", [{"uuid", String.upcase(@manifest_id)}],
       List.replace_at(valid_values, 0, {"uuid", String.upcase(@manifest_id)})},
      {"identity.people", valid_pk,
       List.replace_at(valid_values, 3, {"timestamp", "2026-07-23T12:34:56Z"})},
      {"identity.people", valid_pk,
       List.replace_at(
         valid_values,
         3,
         {"timestamp", "2026-07-23T12:34:56.123456+00:00"}
       )},
      {"identity.people", valid_pk, List.replace_at(valid_values, 1, {"text", <<255>>})},
      {"identity.people", valid_pk,
       List.replace_at(valid_values, 2, {"json", %{atom_key: "bad"}})},
      {"identity.people", valid_pk,
       List.replace_at(valid_values, 2, {"json", %{"bad" => :atom_value}})},
      {"identity.people", valid_pk, List.replace_at(valid_values, 1, {"unknown", "value"})},
      {"identity.people", valid_pk, %{"not" => "a list"}}
    ]

    for {table, primary_key_values, ordered_column_values} <- invalid_rows do
      assert_invalid(
        LogicalRecordCodec.encode_row(table, primary_key_values, ordered_column_values)
      )
    end
  end

  test "encodes and decodes canonical object evidence" do
    attrs = object_attrs()

    assert {:ok, %{type: 0x0003} = record} = LogicalRecordCodec.encode_object(attrs)
    assert record.payload_length == byte_size(record.payload)

    assert {:ok, %{kind: :object, logical_version: 2} = decoded} =
             LogicalRecordCodec.decode(record.type, record.payload)

    assert Map.drop(decoded, [:kind, :logical_version]) == attrs
    assert {:ok, ^record} = LogicalRecordCodec.encode_object(attrs, 2)

    assert LogicalRecordCodec.descriptor(record) == %{
             record_type: 0x0003,
             payload_length: record.payload_length,
             sha256: :crypto.hash(:sha256, record.payload)
           }
  end

  test "rejects non-canonical object evidence fields" do
    invalid_objects = [
      object_attrs(object_index: -1),
      object_attrs(asset_object_id: String.upcase(@object_id)),
      object_attrs(vault_id: <<0::128>>),
      object_attrs(key_domain_id: "not-a-uuid"),
      object_attrs(classification: :private),
      object_attrs(classification: "public"),
      object_attrs(lookup_digest: <<0::248>>),
      object_attrs(storage_ref: ""),
      object_attrs(storage_ref: <<255>>),
      object_attrs(ciphertext_byte_size: -1),
      object_attrs(ciphertext_hash: <<0::264>>)
    ]

    for attrs <- invalid_objects do
      assert_invalid(LogicalRecordCodec.encode_object(attrs))
    end
  end

  test "rejects trailing, compressed, non-canonical, and structurally wrong ETF" do
    {primary_key_values, ordered_column_values} = valid_row("identity.people")

    compressible_values =
      List.replace_at(
        ordered_column_values,
        1,
        {"text", String.duplicate("compress-me", 200)}
      )

    assert {:ok, row} =
             LogicalRecordCodec.encode_row(
               "identity.people",
               primary_key_values,
               compressible_values
             )

    row_term = :erlang.binary_to_term(row.payload, [:safe])
    compressed = :erlang.term_to_binary(row_term, compressed: 9)
    assert match?(<<131, 80, _::binary>>, compressed)

    non_canonical = non_canonical_version_integer(row.payload)

    invalid_payloads = [
      row.payload <> <<0>>,
      compressed,
      non_canonical,
      wire({"wrong.tag", 1, 0, primary_key_values, ordered_column_values}),
      wire({"singularity.backup.logical.row", 3, 0, primary_key_values, ordered_column_values}),
      wire({"singularity.backup.logical.row", 2, 0, primary_key_values}),
      wire({
        "singularity.backup.logical.row",
        1,
        28,
        primary_key_values,
        ordered_column_values
      })
    ]

    for payload <- invalid_payloads do
      assert_invalid(LogicalRecordCodec.decode(0x0002, payload))
    end

    assert_invalid(LogicalRecordCodec.decode(0x0001, row.payload))
    assert_invalid(LogicalRecordCodec.decode(0x9999, row.payload))
  end

  test "descriptor rejects payloads that are not canonical records of their claimed type" do
    {primary_key_values, ordered_column_values} = valid_row("identity.people")

    assert {:ok, row} =
             LogicalRecordCodec.encode_row(
               "identity.people",
               primary_key_values,
               ordered_column_values
             )

    row_term = :erlang.binary_to_term(row.payload, [:safe])

    invalid_payloads = [
      <<>>,
      row.payload <> <<0>>,
      :erlang.term_to_binary(row_term, compressed: 9),
      non_canonical_version_integer(row.payload),
      wire({"wrong.tag", 1, 0, primary_key_values, ordered_column_values}),
      wire({"singularity.backup.logical.row", 1, 0, primary_key_values, []})
    ]

    for payload <- invalid_payloads do
      assert_invalid(
        LogicalRecordCodec.descriptor(%{
          type: 0x0002,
          payload: payload,
          payload_length: byte_size(payload)
        })
      )
    end

    assert_invalid(
      LogicalRecordCodec.descriptor(%{
        type: 0x0001,
        payload: row.payload,
        payload_length: row.payload_length
      })
    )

    assert_invalid(
      LogicalRecordCodec.descriptor(%{
        type: 0x0002,
        payload: row.payload,
        payload_length: row.payload_length + 1
      })
    )
  end

  test "enforces payload bounds before accepting structured records" do
    oversized = :binary.copy(<<"x">>, @record_payload_limit)
    {primary_key_values, ordered_column_values} = valid_row("content.asset_objects")
    oversized_values = List.replace_at(ordered_column_values, 4, {"bytes", oversized})

    assert_invalid(
      LogicalRecordCodec.encode_row(
        "content.asset_objects",
        primary_key_values,
        oversized_values
      )
    )

    assert_invalid(LogicalRecordCodec.encode_object(object_attrs(storage_ref: oversized)))
    assert_invalid(LogicalRecordCodec.decode(0x0002, oversized <> <<0>>))
    assert_invalid(LogicalRecordCodec.decode(0x0001, :binary.copy(<<0>>, 65_537)))
  end

  test "sanitized row contracts cannot fit credential or active-wrapper secrets" do
    verifier = "verifier-canary-never-serialize"
    old_wrapper = "old-wrapper-canary-never-serialize"
    passphrase = "passphrase-canary-never-serialize"
    derived_key = "derived-key-canary-never-serialize"
    canaries = [verifier, old_wrapper, passphrase, derived_key]

    {credential_primary_key, credential_values} = valid_row("identity.credentials")

    assert_invalid(
      LogicalRecordCodec.encode_row(
        "identity.credentials",
        credential_primary_key,
        List.insert_at(credential_values, 3, {"text", verifier})
      )
    )

    {wrapper_primary_key, wrapper_values} = valid_row("core.vault_key_wrappers")

    for secret <- [
          {"bytes", old_wrapper},
          {"text", passphrase},
          {"bytes", derived_key}
        ] do
      assert_invalid(
        LogicalRecordCodec.encode_row(
          "core.vault_key_wrappers",
          wrapper_primary_key,
          wrapper_values ++ [secret]
        )
      )
    end

    assert {:ok, credential} =
             LogicalRecordCodec.encode_row(
               "identity.credentials",
               credential_primary_key,
               credential_values
             )

    assert {:ok, wrapper} =
             LogicalRecordCodec.encode_row(
               "core.vault_key_wrappers",
               wrapper_primary_key,
               wrapper_values
             )

    for canary <- canaries do
      assert :binary.match(credential.payload, canary) == :nomatch
      assert :binary.match(wrapper.payload, canary) == :nomatch
    end
  end

  test "does not accept secret-bearing fields outside non-row record contracts" do
    canary = "never-serialize-this-passphrase"

    assert_invalid(LogicalRecordCodec.encode_cut(Map.put(cut_attrs(), :passphrase, canary)))

    assert_invalid(LogicalRecordCodec.encode_object(Map.put(object_attrs(), :backup_key, canary)))

    assert {:ok, cut} = LogicalRecordCodec.encode_cut(cut_attrs())
    assert {:ok, object} = LogicalRecordCodec.encode_object(object_attrs())
    assert :binary.match(cut.payload, canary) == :nomatch
    assert :binary.match(object.payload, canary) == :nomatch
  end

  defp cut_attrs(overrides \\ []) do
    Map.merge(
      %{
        manifest_id: @manifest_id,
        vault_id: @vault_id,
        snapshot_id: @snapshot_id,
        database_snapshot: "100:120:101,119",
        outbox_high_water_mark: 42,
        table_count_vector: List.duplicate(0, 30),
        object_count: 0
      },
      Map.new(overrides)
    )
  end

  defp object_attrs(overrides \\ []) do
    Map.merge(
      %{
        object_index: 0,
        asset_object_id: @object_id,
        vault_id: @vault_id,
        key_domain_id: @key_domain_id,
        classification: "private",
        lookup_digest: :binary.copy(<<0xA1>>, 32),
        storage_ref: "objects/#{@object_id}",
        ciphertext_byte_size: 4_096,
        ciphertext_hash: :binary.copy(<<0xA2>>, 32)
      },
      Map.new(overrides)
    )
  end

  defp valid_row(table) when is_binary(table) do
    valid_row(table, 2)
  end

  defp valid_row(schema) do
    ordered_column_values =
      schema.columns
      |> Enum.with_index()
      |> Enum.map(fn {column, position} -> tagged_value(column.tag, position) end)

    primary_key_values =
      Enum.map(schema.primary_key, fn primary_key ->
        Enum.at(ordered_column_values, primary_key.position)
      end)

    {primary_key_values, ordered_column_values}
  end

  defp valid_row(table, version) when is_binary(table) do
    {:ok, schema} = schema_module(version).fetch_table(table)
    valid_row(schema)
  end

  defp tagged_value("uuid", _position), do: {"uuid", @manifest_id}
  defp tagged_value("text", position), do: {"text", "value-#{position}"}
  defp tagged_value("bytes", position), do: {"bytes", <<position>>}
  defp tagged_value("integer", position), do: {"integer", position}
  defp tagged_value("boolean", position), do: {"boolean", rem(position, 2) == 0}

  defp tagged_value("timestamp", _position),
    do: {"timestamp", "2026-07-23T12:34:56.123456Z"}

  defp tagged_value("json", position), do: {"json", %{"position" => position}}

  defp wrong_tag_value("uuid"), do: {"text", "not-a-uuid"}
  defp wrong_tag_value(_tag), do: {"uuid", @object_id}

  defp wire(term), do: :erlang.term_to_binary(term, [:deterministic])

  defp schema_module(1), do: LogicalSchema
  defp schema_module(2), do: LogicalSchemaV2

  defp schema_contract_sha256(schema_module) do
    contract =
      Enum.map(schema_module.all(), fn schema ->
        {
          schema.ordinal,
          schema.table,
          Enum.map(schema.columns, &{&1.name, &1.tag, &1.nullable?}),
          Enum.map(schema.primary_key, &{&1.position, &1.tag})
        }
      end)

    :crypto.hash(:sha256, :erlang.term_to_binary(contract, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp replace_wire_version(payload, version) do
    payload
    |> :erlang.binary_to_term([:safe])
    |> put_elem(1, version)
    |> wire()
  end

  defp non_canonical_version_integer(
         <<131, 104, 5, 109, tag_length::32, tag::binary-size(tag_length), 97, version,
           rest::binary>>
       ) do
    <<131, 104, 5, 109, tag_length::32, tag::binary, 98, 0, 0, 0, version, rest::binary>>
  end

  defp assert_invalid(result) do
    assert {:error, %Error{code: :backup_invalid}} = result
  end
end
