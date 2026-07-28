defmodule Singularity.Storage.Backup.LogicalRecordCodecTest do
  use ExUnit.Case, async: true

  alias Singularity.Storage.Backup.LogicalRecordCodec
  alias Singularity.Storage.Backup.LogicalSchema
  alias Singularity.Core.Error

  @manifest_id "00000000-0000-4000-8000-000000000a01"
  @vault_id "00000000-0000-4000-8000-000000000a02"
  @snapshot_id "00000000-0000-4000-8000-000000000a03"
  @object_id "00000000-0000-4000-8000-000000000a04"
  @key_domain_id "00000000-0000-4000-8000-000000000a05"
  @record_payload_limit 16 * 1024 * 1024

  test "publishes the fixed logical restore table order" do
    assert LogicalRecordCodec.tables() == [
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
  end

  test "publishes the exact version-one schema registry and sanitized key slots" do
    assert LogicalSchema.version() == 1
    assert LogicalSchema.count() == 28

    assert Enum.map(LogicalSchema.all(), &{&1.ordinal, &1.table}) ==
             LogicalRecordCodec.tables()
             |> Enum.with_index()
             |> Enum.map(fn {table, ordinal} -> {ordinal, table} end)

    assert Enum.sum(Enum.map(LogicalSchema.all(), &length(&1.columns))) == 257

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

  test "encodes and decodes a canonical cut header record" do
    counts = Enum.to_list(0..27)

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

    assert Map.drop(decoded, [:kind]) == attrs
  end

  test "enforces the snapshot and total non-manifest frame bounds at the cut" do
    exact_snapshot =
      "1:2:" <> Enum.join(["10" | List.duplicate("1", 2_045)], ",")

    assert byte_size(exact_snapshot) == 4_096

    exact_counts = [999_998 | List.duplicate(0, 27)]

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
        cut_attrs(table_count_vector: [999_999 | List.duplicate(0, 27)])
      )
    )

    assert {:ok, _record} =
             LogicalRecordCodec.encode_cut(cut_attrs(object_count: 499_999))

    assert_invalid(LogicalRecordCodec.encode_cut(cut_attrs(object_count: 500_000)))
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
              table: "identity.people",
              table_ordinal: 0,
              primary_key_values: ^primary_key_values,
              ordered_column_values: ^values
            }} = LogicalRecordCodec.decode(record.type, record.payload)

    assert LogicalRecordCodec.descriptor(record) == %{
             record_type: 0x0002,
             payload_length: record.payload_length,
             sha256: :crypto.hash(:sha256, record.payload)
           }
  end

  test "enforces arity, tags, nullability, and primary-key equality for every schema" do
    for schema <- LogicalSchema.all() do
      {primary_key_values, ordered_column_values} = valid_row(schema)

      assert {:ok, record} =
               LogicalRecordCodec.encode_row(
                 schema.table,
                 primary_key_values,
                 ordered_column_values
               )

      assert {:ok,
              %{
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

    assert {:ok, %{kind: :object} = decoded} =
             LogicalRecordCodec.decode(record.type, record.payload)

    assert Map.drop(decoded, [:kind]) == attrs

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
      wire({"singularity.backup.logical.row", 2, 0, primary_key_values, ordered_column_values}),
      wire({"singularity.backup.logical.row", 1, 0, primary_key_values}),
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
        table_count_vector: List.duplicate(0, 28),
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
    {:ok, schema} = LogicalSchema.fetch_table(table)
    valid_row(schema)
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

  defp non_canonical_version_integer(
         <<131, 104, 5, 109, tag_length::32, tag::binary-size(tag_length), 97, 1, rest::binary>>
       ) do
    <<131, 104, 5, 109, tag_length::32, tag::binary, 98, 0, 0, 0, 1, rest::binary>>
  end

  defp assert_invalid(result) do
    assert {:error, %Error{code: :backup_invalid}} = result
  end
end
