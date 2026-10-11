defmodule Singularity.Storage.Backup.LogicalV3SchemaDDLTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Storage.Backup.{LogicalSchemaV2, LogicalSchemaV3}

  @fixture_path Path.expand("../../../fixtures/backup/logical-v3-schema.json", __DIR__)
  @tables ~w(content.document_versions content.document_fragments content.document_import_receipts content.note_attachments content.note_citations content.tags content.resource_tags content.relationships)
  @wire_tags %{
    "uuid" => "uuid",
    "text" => "text",
    "bytea" => "bytes",
    "bigint" => "integer",
    "integer" => "integer",
    "jsonb" => "json",
    "timestamptz" => "timestamp"
  }

  # These fixed catalog queries inspect every live column, not a filtered subset
  # named by the registry. PostgreSQL calls integer/bigint int4/int8 internally.
  @columns_sql """
  SELECT attribute.attname,
         CASE type.typname
           WHEN 'int4' THEN 'integer'
           WHEN 'int8' THEN 'bigint'
           ELSE type.typname::text
         END,
         NOT (attribute.attnotnull OR type.typnotnull)
  FROM pg_catalog.pg_attribute AS attribute
  JOIN pg_catalog.pg_type AS type ON type.oid = attribute.atttypid
  WHERE attribute.attrelid = pg_catalog.to_regclass($1)
    AND attribute.attnum > 0 AND NOT attribute.attisdropped
  ORDER BY attribute.attnum
  """

  @constraint_pk_sql """
  SELECT attribute.attname
  FROM pg_catalog.pg_constraint AS constraint_row
  CROSS JOIN LATERAL unnest(constraint_row.conkey)
    WITH ORDINALITY AS key_column(attnum, position)
  JOIN pg_catalog.pg_attribute AS attribute
    ON attribute.attrelid = constraint_row.conrelid
   AND attribute.attnum = key_column.attnum
  WHERE constraint_row.conrelid = pg_catalog.to_regclass($1)
    AND constraint_row.contype = 'p'
  ORDER BY key_column.position
  """

  @index_pk_sql """
  SELECT attribute.attname
  FROM pg_catalog.pg_index AS index_row
  CROSS JOIN LATERAL unnest(index_row.indkey)
    WITH ORDINALITY AS key_column(attnum, position)
  JOIN pg_catalog.pg_attribute AS attribute
    ON attribute.attrelid = index_row.indrelid
   AND attribute.attnum = key_column.attnum
  WHERE index_row.indrelid = pg_catalog.to_regclass($1)
    AND index_row.indisprimary
    AND key_column.position <= index_row.indnkeyatts
  ORDER BY key_column.position
  """

  setup_all do
    fixture = @fixture_path |> File.read!() |> Jason.decode!()

    database =
      Map.new(@tables, fn table ->
        {table,
         %{
           columns: query!(RequestRepo, @columns_sql, [table]).rows,
           constraint_pk: query!(RequestRepo, @constraint_pk_sql, [table]).rows,
           index_pk: query!(RequestRepo, @index_pk_sql, [table]).rows
         }}
      end)

    {:ok, fixture: fixture, database: database}
  end

  test "literal fixture covers exactly eight ordered appended tables and 87 columns", %{
    fixture: fixture
  } do
    assert fixture["version"] == 3
    assert fixture["appended_table_count"] == 8
    assert fixture["appended_column_count"] == 87
    assert length(fixture["tables"]) == 8
    assert Enum.map(fixture["tables"], & &1["table"]) == @tables
    assert Enum.map(fixture["tables"], & &1["ordinal"]) == Enum.to_list(30..37)
    assert Enum.map(fixture["tables"], &length(&1["columns"])) == [25, 10, 8, 12, 11, 7, 5, 9]
    assert Enum.sum(Enum.map(fixture["tables"], &length(&1["columns"]))) == 87

    for table <- fixture["tables"] do
      columns = table["columns"]
      names = Enum.map(columns, & &1["name"])
      assert length(Enum.uniq(names)) == length(names)
      assert table["primary_key"] != []
      assert length(Enum.uniq(table["primary_key"])) == length(table["primary_key"])

      for column <- columns do
        assert Enum.sort(Map.keys(column)) == ["name", "nullable", "type"]
        assert is_binary(column["name"])
        assert Map.has_key?(@wire_tags, column["type"])
        assert is_boolean(column["nullable"])
      end

      for name <- table["primary_key"] do
        assert name in names
        assert Enum.find(columns, &(&1["name"] == name))["nullable"] == false
      end
    end
  end

  test "all actual DDL columns and both ordered primary-key catalogs match the literal oracle", %{
    fixture: fixture,
    database: database
  } do
    assert_ddl!(fixture, database)
  end

  test "V3 agrees with the independent oracle and preserves the full historical V2 wire prefix",
       %{
         fixture: fixture
       } do
    schemas = LogicalSchemaV3.all()
    prefix = Enum.map(LogicalSchemaV2.all(), &Map.put(&1, :version, 3))

    assert length(prefix) == 30
    assert Enum.take(schemas, 30) == prefix
    assert Enum.drop(schemas, 30) == Enum.map(fixture["tables"], &wire_schema/1)
    assert length(schemas) == 38
    assert LogicalSchemaV3.count() == 38
    assert LogicalSchemaV3.column_count() == 367
    assert Enum.sum(Enum.map(schemas, &length(&1.columns))) == 367

    # No physical SELECT * ordering is imposed on the frozen V2 projection.
    assert Enum.take(LogicalSchemaV3.tables(), 30) == LogicalSchemaV2.tables()
  end

  test "oracle rejects bigint changed to integer even though their wire tags agree", %{
    fixture: fixture,
    database: database
  } do
    assert_ddl!(fixture, database)

    wrong_type =
      update_in(fixture, ["tables", Access.at(0), "columns", Access.at(9), "type"], fn
        "bigint" -> "integer"
      end)

    assert_raise ExUnit.AssertionError, fn -> assert_ddl!(wrong_type, database) end
  end

  test "oracle rejects a missing column without changing actual DDL", %{
    fixture: fixture,
    database: database
  } do
    assert_ddl!(fixture, database)
    missing_column = update_in(fixture, ["tables", Access.at(0), "columns"], &Enum.drop(&1, -1))

    assert_raise ExUnit.AssertionError, fn -> assert_ddl!(missing_column, database) end
  end

  test "oracle rejects swapped same-type composite primary-key positions", %{
    fixture: fixture,
    database: database
  } do
    assert_ddl!(fixture, database)

    swapped_pk =
      update_in(fixture, ["tables", Access.at(3), "primary_key"], &Enum.reverse/1)

    assert_raise ExUnit.AssertionError, fn -> assert_ddl!(swapped_pk, database) end
  end

  defp assert_ddl!(fixture, database) do
    for table <- fixture["tables"] do
      actual = Map.fetch!(database, table["table"])

      expected_columns =
        Enum.map(table["columns"], fn column ->
          [column["name"], column["type"], column["nullable"]]
        end)

      expected_pk = Enum.map(table["primary_key"], &[&1])
      assert actual.columns == expected_columns, "column contract: #{table["table"]}"
      assert actual.constraint_pk == expected_pk, "constraint PK order: #{table["table"]}"
      assert actual.index_pk == expected_pk, "index PK order: #{table["table"]}"
    end
  end

  defp wire_schema(table) do
    columns =
      Enum.map(table["columns"], fn column ->
        %{
          name: column["name"],
          tag: Map.fetch!(@wire_tags, column["type"]),
          nullable?: column["nullable"]
        }
      end)

    %{
      version: 3,
      ordinal: table["ordinal"],
      table: table["table"],
      columns: columns,
      primary_key:
        Enum.map(table["primary_key"], fn name ->
          position = Enum.find_index(columns, &(&1.name == name))
          %{position: position, tag: Enum.at(columns, position).tag}
        end)
    }
  end
end
