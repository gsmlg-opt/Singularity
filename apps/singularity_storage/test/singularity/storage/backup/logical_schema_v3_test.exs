defmodule Singularity.Storage.Backup.LogicalSchemaV3Test do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Storage.Backup.LogicalRecordCodec
  alias Singularity.Storage.Backup.LogicalSchemaV2
  alias Singularity.Storage.Backup.LogicalSchemaV3

  @id "00000000-0000-4000-8000-000000000a01"
  @other_id "00000000-0000-4000-8000-000000000a02"
  @definitions [
    {"content.document_versions",
     [
       {"resource_version_id", "uuid", false},
       {"resource_id", "uuid", false},
       {"vault_id", "uuid", false},
       {"classification", "text", false},
       {"source_asset_id", "uuid", false},
       {"source_resource_id", "uuid", false},
       {"source_resource_version_id", "uuid", false},
       {"source_object_id", "uuid", false},
       {"source_digest", "bytes", false},
       {"source_byte_size", "integer", false},
       {"media_type", "text", false},
       {"title", "text", false},
       {"created_by_principal_id", "uuid", false},
       {"state", "text", false},
       {"attempt_generation", "integer", false},
       {"extraction_adapter", "text", true},
       {"extraction_format", "integer", true},
       {"extracted_text_digest", "bytes", true},
       {"detected_language", "text", true},
       {"failure_code", "text", true},
       {"attempt_finished_at", "timestamp", true},
       {"inserted_at", "timestamp", false},
       {"attempt_job_id", "uuid", true},
       {"attempt_started_at", "timestamp", true},
       {"attempt_deadline_at", "timestamp", true}
     ], [{0, "uuid"}]},
    {"content.document_fragments",
     [
       {"id", "text", false},
       {"resource_id", "uuid", false},
       {"resource_version_id", "uuid", false},
       {"vault_id", "uuid", false},
       {"classification", "text", false},
       {"ordinal", "integer", false},
       {"text", "text", false},
       {"digest", "bytes", false},
       {"locator", "json", false},
       {"inserted_at", "timestamp", false}
     ], [{0, "text"}]},
    {"content.document_import_receipts",
     [
       {"vault_id", "uuid", false},
       {"principal_id", "uuid", false},
       {"mutation_id", "uuid", false},
       {"request_fingerprint", "bytes", false},
       {"state", "text", false},
       {"resource_id", "uuid", true},
       {"version_id", "uuid", true},
       {"inserted_at", "timestamp", false}
     ], [{0, "uuid"}, {1, "uuid"}, {2, "uuid"}]},
    {"content.note_attachments",
     [
       {"note_resource_version_id", "uuid", false},
       {"id", "uuid", false},
       {"note_resource_id", "uuid", false},
       {"vault_id", "uuid", false},
       {"classification", "text", false},
       {"target_resource_id", "uuid", false},
       {"target_resource_version_id", "uuid", false},
       {"target_kind", "text", false},
       {"ordinal", "integer", false},
       {"role", "text", false},
       {"label", "text", true},
       {"inserted_at", "timestamp", false}
     ], [{0, "uuid"}, {1, "uuid"}]},
    {"content.note_citations",
     [
       {"note_resource_version_id", "uuid", false},
       {"id", "uuid", false},
       {"note_resource_id", "uuid", false},
       {"vault_id", "uuid", false},
       {"classification", "text", false},
       {"source_resource_id", "uuid", false},
       {"source_resource_version_id", "uuid", false},
       {"fragment_id", "text", false},
       {"locator", "json", false},
       {"ordinal", "integer", false},
       {"inserted_at", "timestamp", false}
     ], [{0, "uuid"}, {1, "uuid"}]},
    {"content.tags",
     [
       {"id", "uuid", false},
       {"vault_id", "uuid", false},
       {"classification", "text", false},
       {"display_value", "text", false},
       {"normalized_key", "text", false},
       {"created_by_principal_id", "uuid", false},
       {"inserted_at", "timestamp", false}
     ], [{0, "uuid"}]},
    {"content.resource_tags",
     [
       {"resource_id", "uuid", false},
       {"tag_id", "uuid", false},
       {"vault_id", "uuid", false},
       {"classification", "text", false},
       {"inserted_at", "timestamp", false}
     ], [{0, "uuid"}, {1, "uuid"}, {2, "uuid"}]},
    {"content.relationships",
     [
       {"id", "uuid", false},
       {"vault_id", "uuid", false},
       {"classification", "text", false},
       {"source_resource_id", "uuid", false},
       {"target_resource_id", "uuid", false},
       {"target_resource_version_id", "uuid", true},
       {"type", "text", false},
       {"created_by_principal_id", "uuid", false},
       {"inserted_at", "timestamp", false}
     ], [{0, "uuid"}]}
  ]

  test "V3 preserves the entire immutable V2 prefix and appends the literal 87-column contract" do
    assert Code.ensure_loaded?(LogicalSchemaV3)
    assert v3(:version) == 3
    assert v3(:count) == 38
    assert v3(:column_count) == 367
    schemas = v3(:all)

    assert Enum.take(schemas, 30) ==
             Enum.map(LogicalSchemaV2.all(), &Map.put(&1, :version, 3))

    appended_contract =
      schemas
      |> Enum.drop(30)
      |> Enum.map(fn schema ->
        {schema.table, Enum.map(schema.columns, &{&1.name, &1.tag, &1.nullable?}),
         Enum.map(schema.primary_key, &{&1.position, &1.tag})}
      end)

    assert appended_contract == @definitions
    assert Enum.map(Enum.drop(schemas, 30), & &1.ordinal) == Enum.to_list(30..37)
    assert Enum.map(schemas, & &1.version) == List.duplicate(3, 38)
    assert Enum.sum(Enum.map(schemas, &length(&1.columns))) == 367

    assert Enum.sum(Enum.map(@definitions, fn {_table, columns, _pk} -> length(columns) end)) ==
             87

    assert v3(:tables) ==
             LogicalSchemaV2.tables() ++ Enum.map(@definitions, &elem(&1, 0))

    assert LogicalRecordCodec.tables(3) == v3(:tables)
    assert LogicalRecordCodec.default_version() == 2
    assert LogicalRecordCodec.tables() == LogicalSchemaV2.tables()

    for schema <- schemas do
      assert {:ok, ^schema} = v3(:fetch_table, [schema.table])
      assert {:ok, ^schema} = v3(:fetch_ordinal, [schema.ordinal])
    end
  end

  test "V3 lookup rejects unknown tables, excluded projections and malformed registry keys" do
    for table <- [
          "content.document_search_projections",
          "content.note_search_documents",
          "content.note_mutation_receipts",
          "content.note_source_set_seals",
          "jobs.oban_jobs",
          "backup.restore_staging",
          "knowledge.export_artifacts",
          "unknown.table",
          :content,
          nil,
          %{table: "content.tags"}
        ] do
      assert :error = v3(:fetch_table, [table])
    end

    for ordinal <- [-1, 38, "30", nil, %{ordinal: 30}] do
      assert :error = v3(:fetch_ordinal, [ordinal])
    end
  end

  test "released V1 and V2 registry source bytes remain frozen" do
    for {filename, expected} <- [
          {"logical_schema.ex",
           "ba0722ca85ce0a1259ce650927aa53ed728db0b28467adf308c3ada5a03036e8"},
          {"logical_schema_v2.ex",
           "992ef89fb52a91ccaa0d7cf2b3ae6607a465e7b345cca5d6c55a86c3fac9f3e6"}
        ] do
      path = Path.expand("../../../../lib/singularity/storage/backup/#{filename}", __DIR__)
      actual = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
      assert actual == expected
    end
  end

  test "every appended row enforces independent column arity, tags, nullability and key slots" do
    for {{table, columns, key_slots}, ordinal} <- Enum.with_index(@definitions, 30) do
      values = Enum.map(columns, fn {_name, tag, _nullable?} -> value(tag) end)
      primary_key = Enum.map(key_slots, fn {position, _tag} -> Enum.at(values, position) end)
      assert_row(table, ordinal, primary_key, values)

      for invalid_values <- [Enum.drop(values, -1), values ++ [{"null"}]] do
        assert_invalid_row(table, ordinal, primary_key, invalid_values)
      end

      for {{_name, tag, nullable?}, position} <- Enum.with_index(columns) do
        wrong_tag = if tag == "uuid", do: {"text", "not-a-uuid"}, else: {"uuid", @other_id}

        assert_invalid_row(
          table,
          ordinal,
          primary_key,
          List.replace_at(values, position, wrong_tag)
        )

        nullable_values = List.replace_at(values, position, {"null"})

        if nullable? do
          assert_row(table, ordinal, primary_key, nullable_values)
        else
          assert_invalid_row(table, ordinal, primary_key, nullable_values)
        end
      end

      for invalid_key <- [Enum.drop(primary_key, -1), primary_key ++ [{"null"}]] do
        assert_invalid_row(table, ordinal, invalid_key, values)
      end

      for {{column_position, tag}, key_position} <- Enum.with_index(key_slots) do
        mismatch = if tag == "uuid", do: {"uuid", @other_id}, else: {"text", "other-key"}

        assert_invalid_row(
          table,
          ordinal,
          List.replace_at(primary_key, key_position, mismatch),
          values
        )

        assert_invalid_row(
          table,
          ordinal,
          List.replace_at(primary_key, key_position, {"null"}),
          List.replace_at(values, column_position, {"null"})
        )
      end
    end
  end

  test "V3-only rows remain unavailable to default V2 and both explicit legacy codecs" do
    for {table, columns, key_slots} <- @definitions do
      values = Enum.map(columns, fn {_name, tag, _nullable?} -> value(tag) end)
      primary_key = Enum.map(key_slots, fn {position, _tag} -> Enum.at(values, position) end)
      assert_invalid(LogicalRecordCodec.encode_row(table, primary_key, values))

      for version <- [1, 2] do
        assert_invalid(LogicalRecordCodec.encode_row(table, primary_key, values, version))
      end
    end
  end

  defp v3(function, arguments \\ []), do: apply(LogicalSchemaV3, function, arguments)

  defp assert_row(table, ordinal, primary_key, values) do
    payload = wire_row(ordinal, primary_key, values)

    assert {:ok, %{type: 0x0002, payload: ^payload}} =
             LogicalRecordCodec.encode_row(table, primary_key, values, 3)

    assert {:ok,
            %{
              logical_version: 3,
              table: ^table,
              table_ordinal: ^ordinal,
              primary_key_values: ^primary_key,
              ordered_column_values: ^values
            }} =
             LogicalRecordCodec.decode(0x0002, payload)
  end

  defp assert_invalid_row(table, ordinal, primary_key, values) do
    assert_invalid(LogicalRecordCodec.encode_row(table, primary_key, values, 3))
    assert_invalid(LogicalRecordCodec.decode(0x0002, wire_row(ordinal, primary_key, values)))
  end

  defp wire_row(ordinal, primary_key, values) do
    :erlang.term_to_binary(
      {"singularity.backup.logical.row", 3, ordinal, primary_key, values},
      [:deterministic]
    )
  end

  defp value("uuid"), do: {"uuid", @id}
  defp value("text"), do: {"text", "literal-value"}
  defp value("bytes"), do: {"bytes", <<0xA1::256>>}
  defp value("integer"), do: {"integer", 7}
  defp value("json"), do: {"json", %{"kind" => "fragment", "ordinal" => 0}}
  defp value("timestamp"), do: {"timestamp", "2026-10-11T00:00:00.000000Z"}

  defp assert_invalid(result), do: assert({:error, %Error{code: :backup_invalid}} = result)
end
