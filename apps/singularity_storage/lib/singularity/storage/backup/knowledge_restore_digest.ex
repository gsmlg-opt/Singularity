defmodule Singularity.Storage.Backup.KnowledgeRestoreDigest do
  @moduledoc """
  Internal typed, length-framed digests for authenticated V3 restore rows.

  SQL encodes values without lossy client JSON/numeric conversion. Only a
  single bounded encoded-row chunk and a count/hash accumulator cross each fetch.
  Identifiers, projections, tags and ordering come from the immutable registry.
  This does not authorize canonical writes or enable V3 import.
  """

  alias Singularity.Core.Error
  alias Singularity.Storage.SafeSQL
  alias Singularity.Storage.Backup.LogicalSchemaV3

  @domain "singularity:knowledge-restore-digest:v1"
  @tags %{
    "boolean" => 1,
    "integer" => 2,
    "bytes" => 3,
    "text" => 4,
    "uuid" => 5,
    "timestamp" => 6,
    "json" => 7
  }
  @schemas Map.new(LogicalSchemaV3.all(), &{&1.table, &1})
  @chunk_bytes 65_536

  # Connection-local pure encoder. Task5's admission validator must implement
  # the same protocol independently in owned SQL, never trust this pg_temp name.
  @json_sql """
  CREATE OR REPLACE FUNCTION pg_temp.knowledge_restore_json(value jsonb)
  RETURNS bytea LANGUAGE plpgsql IMMUTABLE STRICT
  SET search_path = pg_catalog AS $function$
  DECLARE
    kind text; payload bytea; result bytea; item record;
  BEGIN
    kind := pg_catalog.jsonb_typeof(value);
    CASE kind
    WHEN 'null' THEN RETURN pg_catalog.decode('00','hex');
    WHEN 'boolean' THEN
      IF value = 'true'::jsonb THEN RETURN pg_catalog.decode('02','hex'); END IF;
      RETURN pg_catalog.decode('01','hex');
    WHEN 'number' THEN
      payload := pg_catalog.convert_to(
        pg_catalog.trim_scale((value #>> '{}')::numeric)::text,'UTF8');
      RETURN pg_catalog.decode('03','hex') ||
        pg_catalog.int8send(pg_catalog.octet_length(payload)::bigint) || payload;
    WHEN 'string' THEN
      payload := pg_catalog.convert_to(value #>> '{}','UTF8');
      RETURN pg_catalog.decode('04','hex') ||
        pg_catalog.int8send(pg_catalog.octet_length(payload)::bigint) || payload;
    WHEN 'array' THEN
      result := pg_catalog.decode('05','hex') ||
        pg_catalog.int8send(pg_catalog.jsonb_array_length(value)::bigint);
      FOR item IN SELECT element FROM pg_catalog.jsonb_array_elements(value) AS entries(element)
      LOOP
        payload := pg_temp.knowledge_restore_json(item.element);
        result := result || pg_catalog.int8send(pg_catalog.octet_length(payload)::bigint) || payload;
      END LOOP;
      RETURN result;
    WHEN 'object' THEN
      result := pg_catalog.decode('06','hex') ||
        pg_catalog.int8send((SELECT count(*) FROM pg_catalog.jsonb_each(value)));
      FOR item IN
        SELECT key,entry FROM pg_catalog.jsonb_each(value) AS entries(key,entry)
        ORDER BY pg_catalog.convert_to(key,'UTF8')
      LOOP
        payload := pg_catalog.convert_to(item.key,'UTF8');
        result := result || pg_catalog.int8send(pg_catalog.octet_length(payload)::bigint) || payload;
        payload := pg_temp.knowledge_restore_json(item.entry);
        result := result || pg_catalog.int8send(pg_catalog.octet_length(payload)::bigint) || payload;
      END LOOP;
      RETURN result;
    ELSE RAISE EXCEPTION 'invalid restore JSON';
    END CASE;
  END;
  $function$
  """

  @spec projection(term()) :: {:ok, map()} | :error
  def projection(table), do: Map.fetch(@schemas, table)

  @doc false
  @spec install(module()) :: :ok | {:error, Error.t()}
  def install(repo) do
    with true <- transaction?(repo),
         {:ok, %{rows: [["singularity_migration", "singularity_table_owner"]]}} <-
           SafeSQL.query(repo, "SELECT session_user::text,current_user::text"),
         {:ok, _result} <- SafeSQL.query(repo, @json_sql) do
      :ok
    else
      _invalid -> invalid()
    end
  rescue
    _exception -> invalid()
  catch
    _kind, _reason -> invalid()
  end

  @doc false
  @spec value_encoding_sql(term()) :: {:ok, binary()} | :error
  def value_encoding_sql(tag) do
    if Map.has_key?(@tags, tag), do: {:ok, cell_sql(tag, "\"value\"")}, else: :error
  end

  @doc false
  @spec row_chunks_sql(term(), :staged | :canonical) :: {:ok, binary()} | :error
  def row_chunks_sql(table, selection) when selection in [:staged, :canonical] do
    with {:ok, schema} <- projection(table) do
      # OFFSET 0 keeps one row encoder below the lateral chunk expansion. Only
      # fixed registry identifiers enter this query; payloads are not collected.
      {:ok,
       "SELECT pg_catalog.octet_length(encoded_row.value)::bigint,slices.byte_offset," <>
         "pg_catalog.substring(encoded_row.value,slices.byte_offset+1," <>
         Integer.to_string(@chunk_bytes) <>
         ") FROM " <>
         relation(schema, selection) <>
         " AS source CROSS JOIN LATERAL (SELECT " <>
         row_sql(schema, "source.") <>
         " AS value OFFSET 0) AS encoded_row CROSS JOIN LATERAL " <>
         "pg_catalog.generate_series(0,pg_catalog.octet_length(encoded_row.value)-1," <>
         Integer.to_string(@chunk_bytes) <>
         ") AS slices(byte_offset) ORDER BY " <>
         order_sql(schema, "source.") <> ",slices.byte_offset"}
    end
  end

  def row_chunks_sql(_table, _selection), do: :error

  @spec table_digest(module(), term(), :staged | :canonical) ::
          {:ok, %{count: non_neg_integer(), digest: <<_::256>>}} | {:error, Error.t()}
  def table_digest(repo, table, selection) when selection in [:staged, :canonical] do
    with {:ok, schema} <- projection(table),
         {:ok, statement} <- row_chunks_sql(table, selection),
         :ok <- install(repo) do
      seed =
        :crypto.hash(
          :sha256,
          [
            <<0>>,
            frame(@domain),
            <<3::unsigned-big-64>>,
            frame(schema.table),
            frame(projection_bytes(schema))
          ]
        )

      {digest, count, nil} =
        repo
        |> SafeSQL.stream(statement, [], max_rows: 1)
        |> Enum.reduce({seed, 0, nil}, fn %{rows: rows}, state ->
          Enum.reduce(rows, state, &digest_chunk/2)
        end)

      {:ok,
       %{count: count, digest: :crypto.hash(:sha256, [<<2>>, digest, <<count::unsigned-big-64>>])}}
    else
      _invalid -> invalid()
    end
  rescue
    _exception -> invalid()
  catch
    _kind, _reason -> invalid()
  end

  def table_digest(_repo, _table, _selection), do: invalid()

  defp digest_chunk([length, offset, bytes], {previous, count, pending})
       when is_integer(length) and length > 0 and is_integer(offset) and offset >= 0 and
              is_binary(bytes) do
    expected_size = min(@chunk_bytes, length - offset)

    if expected_size <= 0 or byte_size(bytes) != expected_size,
      do: throw(:invalid_restore_chunk)

    context =
      case pending do
        nil when offset == 0 ->
          :crypto.hash_init(:sha256)
          |> :crypto.hash_update([<<1>>, previous, <<length::unsigned-big-64>>])

        {context, ^length, ^offset} ->
          context

        _invalid ->
          throw(:invalid_restore_chunk)
      end

    context = :crypto.hash_update(context, bytes)
    next = offset + byte_size(bytes)

    if next == length,
      do: {:crypto.hash_final(context), count + 1, nil},
      else: {previous, count, {context, length, next}}
  end

  defp digest_chunk(_row, _state), do: throw(:invalid_restore_chunk)

  defp transaction?(repo) when is_atom(repo) and not is_nil(repo) do
    function_exported?(repo, :in_transaction?, 0) and repo.in_transaction?()
  end

  defp transaction?(_repo), do: false

  defp projection_bytes(schema) do
    columns =
      Enum.map(schema.columns, fn column ->
        [
          frame(column.name),
          <<Map.fetch!(@tags, column.tag)>>,
          if(column.nullable?, do: <<1>>, else: <<0>>)
        ]
      end)

    IO.iodata_to_binary([
      <<length(schema.columns)::unsigned-big-64>>,
      columns,
      <<length(schema.primary_key)::unsigned-big-64>>,
      Enum.map(schema.primary_key, &<<&1.position::unsigned-big-64>>)
    ])
  end

  defp row_sql(schema, qualifier) do
    prefix = "pg_catalog.int8send(" <> Integer.to_string(length(schema.columns)) <> "::bigint)"

    Enum.reduce(schema.columns, prefix, fn column, sql ->
      sql <> " || " <> cell_sql(column.tag, qualifier <> quote_identifier(column.name))
    end)
  end

  defp cell_sql(tag, column) do
    number = Map.fetch!(@tags, tag) |> Integer.to_string(16) |> String.pad_leading(2, "0")
    payload = payload_sql(tag, column)

    "pg_catalog.decode('" <>
      number <>
      "','hex') || CASE WHEN " <>
      column <>
      " IS NULL THEN pg_catalog.decode('000000000000000000','hex') ELSE " <>
      "pg_catalog.decode('01','hex') || pg_catalog.int8send(pg_catalog.octet_length(" <>
      payload <> ")::bigint) || " <> payload <> " END"
  end

  defp payload_sql("boolean", column),
    do: "pg_catalog.decode(CASE WHEN " <> column <> " THEN '01' ELSE '00' END,'hex')"

  defp payload_sql("integer", column), do: "pg_catalog.int8send(" <> column <> "::bigint)"
  defp payload_sql("bytes", column), do: column
  defp payload_sql("text", column), do: "pg_catalog.convert_to(" <> column <> ",'UTF8')"
  defp payload_sql("uuid", column), do: "pg_catalog.uuid_send(" <> column <> ")"

  defp payload_sql("timestamp", column),
    do: "pg_catalog.int8send((extract(epoch FROM " <> column <> ")*1000000)::bigint)"

  defp payload_sql("json", column), do: "pg_temp.knowledge_restore_json(" <> column <> ")"

  defp relation(schema, :staged),
    do: "pg_temp.knowledge_restore_" <> Integer.to_string(schema.ordinal)

  defp relation(schema, :canonical),
    do: schema.table |> String.split(".") |> Enum.map_join(".", &quote_identifier/1)

  defp order_sql(schema, prefix) do
    Enum.map_join(schema.primary_key, ",", fn key ->
      column = Enum.fetch!(schema.columns, key.position)
      identifier = prefix <> quote_identifier(column.name)

      if key.tag == "text",
        do: "pg_catalog.convert_to(" <> identifier <> ",'UTF8')",
        else: identifier
    end)
  end

  defp quote_identifier(value), do: "\"" <> value <> "\""
  defp frame(value), do: [<<byte_size(value)::unsigned-big-64>>, value]
  defp invalid, do: {:error, Error.new(:backup_invalid)}
end
