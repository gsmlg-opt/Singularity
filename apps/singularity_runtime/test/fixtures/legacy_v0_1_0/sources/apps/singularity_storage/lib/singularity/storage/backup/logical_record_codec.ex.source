defmodule Singularity.Storage.Backup.LogicalRecordCodec do
  @moduledoc "Deterministic wire codec for canonical logical backup records."

  alias Singularity.Core.Error
  alias Singularity.Storage.Backup.LogicalSchema
  alias Singularity.Storage.Backup.LogicalSchemaV2

  @cut_type 0x0001
  @row_type 0x0002
  @object_type 0x0003
  @cut_tag "singularity.backup.logical.cut"
  @row_tag "singularity.backup.logical.row"
  @object_tag "singularity.backup.logical.object"
  @default_version 2
  @header_payload_limit 64 * 1024
  @record_payload_limit 16 * 1024 * 1024
  @database_snapshot_limit 4 * 1024
  @non_manifest_frame_limit 999_999
  @max_signed_bigint 9_223_372_036_854_775_807

  @cut_keys ~w[
    database_snapshot manifest_id object_count outbox_high_water_mark snapshot_id
    table_count_vector vault_id
  ]a
  @object_keys ~w[
    asset_object_id ciphertext_byte_size ciphertext_hash classification key_domain_id
    lookup_digest object_index storage_ref vault_id
  ]a
  @classifications ~w[private sensitive restricted]
  @spec default_version() :: 2
  def default_version, do: @default_version

  @spec tables() :: [binary()]
  def tables, do: tables(@default_version)

  @spec tables(1 | 2) :: [binary()]
  def tables(1), do: LogicalSchema.tables()
  def tables(2), do: LogicalSchemaV2.tables()
  def tables(_version), do: []

  @spec encode_cut(map()) :: {:ok, map()} | {:error, Error.t()}
  def encode_cut(attrs), do: encode_cut(attrs, @default_version)

  @spec encode_cut(map(), 1 | 2) :: {:ok, map()} | {:error, Error.t()}
  def encode_cut(attrs, version) when is_map(attrs) do
    with {:ok, schema} <- schema_for(version),
         :ok <- validate_cut_attrs(attrs, schema) do
      attrs
      |> cut_wire_term(version)
      |> encode_record(@cut_type, @header_payload_limit)
    end
  end

  def encode_cut(_attrs, _version), do: invalid()

  @spec encode_row(binary(), list(), list()) :: {:ok, map()} | {:error, Error.t()}
  def encode_row(table, primary_key_values, ordered_column_values),
    do: encode_row(table, primary_key_values, ordered_column_values, @default_version)

  @spec encode_row(binary(), list(), list(), 1 | 2) ::
          {:ok, map()} | {:error, Error.t()}
  def encode_row(table, primary_key_values, ordered_column_values, version)
      when is_binary(table) do
    with {:ok, schema_module} <- schema_for(version),
         {:ok, schema} <- schema_module.fetch_table(table),
         :ok <- validate_row(schema, primary_key_values, ordered_column_values) do
      encode_record(
        {
          @row_tag,
          version,
          schema.ordinal,
          primary_key_values,
          ordered_column_values
        },
        @row_type,
        @record_payload_limit
      )
    else
      _invalid -> invalid()
    end
  end

  def encode_row(_table, _primary_key_values, _ordered_column_values, _version), do: invalid()

  @spec encode_object(map()) :: {:ok, map()} | {:error, Error.t()}
  def encode_object(attrs), do: encode_object(attrs, @default_version)

  @spec encode_object(map(), 1 | 2) :: {:ok, map()} | {:error, Error.t()}
  def encode_object(attrs, version) when is_map(attrs) do
    with {:ok, _schema} <- schema_for(version),
         :ok <- validate_object_attrs(attrs) do
      attrs
      |> object_wire_term(version)
      |> encode_record(@object_type, @record_payload_limit)
    end
  end

  def encode_object(_attrs, _version), do: invalid()

  @spec decode(non_neg_integer(), binary()) :: {:ok, map()} | {:error, Error.t()}
  def decode(@cut_type, payload) when is_binary(payload) do
    with {:ok, term} <- decode_canonical(payload, @header_payload_limit),
         {:ok, cut} <- decode_cut_term(term) do
      {:ok, cut}
    end
  end

  def decode(@row_type, payload) when is_binary(payload) do
    with {:ok, term} <- decode_canonical(payload, @record_payload_limit),
         {:ok, row} <- decode_row_term(term) do
      {:ok, row}
    end
  end

  def decode(@object_type, payload) when is_binary(payload) do
    with {:ok, term} <- decode_canonical(payload, @record_payload_limit),
         {:ok, object} <- decode_object_term(term) do
      {:ok, object}
    end
  end

  def decode(_type, _payload), do: invalid()

  @spec descriptor(map()) :: map() | {:error, Error.t()}
  def descriptor(record) when is_map(record) do
    with true <- exact_keys?(record, [:type, :payload, :payload_length]),
         %{type: type, payload: payload, payload_length: payload_length} <- record,
         {:ok, payload_limit} <- payload_limit(type),
         true <- is_binary(payload),
         true <- is_integer(payload_length),
         true <- payload_length == byte_size(payload),
         true <- payload_length <= payload_limit,
         {:ok, _decoded} <- decode(type, payload) do
      %{
        record_type: type,
        payload_length: payload_length,
        sha256: :crypto.hash(:sha256, payload)
      }
    else
      _invalid -> invalid()
    end
  end

  def descriptor(_record), do: invalid()

  defp cut_wire_term(attrs, version) do
    {
      @cut_tag,
      version,
      attrs.manifest_id,
      attrs.vault_id,
      attrs.snapshot_id,
      attrs.database_snapshot,
      attrs.outbox_high_water_mark,
      attrs.table_count_vector,
      attrs.object_count
    }
  end

  defp decode_cut_term({
         @cut_tag,
         version,
         manifest_id,
         vault_id,
         snapshot_id,
         database_snapshot,
         outbox_high_water_mark,
         table_count_vector,
         object_count
       }) do
    attrs = %{
      manifest_id: manifest_id,
      vault_id: vault_id,
      snapshot_id: snapshot_id,
      database_snapshot: database_snapshot,
      outbox_high_water_mark: outbox_high_water_mark,
      table_count_vector: table_count_vector,
      object_count: object_count
    }

    with {:ok, schema} <- schema_for(version),
         :ok <- validate_cut_attrs(attrs, schema) do
      {:ok, attrs |> Map.put(:kind, :cut) |> Map.put(:logical_version, version)}
    end
  end

  defp decode_cut_term(_term), do: invalid()

  defp decode_row_term({
         @row_tag,
         version,
         table_ordinal,
         primary_key_values,
         ordered_column_values
       }) do
    with {:ok, schema_module} <- schema_for(version),
         {:ok, schema} <- schema_module.fetch_ordinal(table_ordinal),
         :ok <- validate_row(schema, primary_key_values, ordered_column_values) do
      {:ok,
       %{
         kind: :row,
         logical_version: version,
         table: schema.table,
         table_ordinal: table_ordinal,
         primary_key_values: primary_key_values,
         ordered_column_values: ordered_column_values
       }}
    else
      _invalid -> invalid()
    end
  end

  defp decode_row_term(_term), do: invalid()

  defp object_wire_term(attrs, version) do
    {
      @object_tag,
      version,
      attrs.object_index,
      attrs.asset_object_id,
      attrs.vault_id,
      attrs.key_domain_id,
      attrs.classification,
      attrs.lookup_digest,
      attrs.storage_ref,
      attrs.ciphertext_byte_size,
      attrs.ciphertext_hash
    }
  end

  defp decode_object_term({
         @object_tag,
         version,
         object_index,
         asset_object_id,
         vault_id,
         key_domain_id,
         classification,
         lookup_digest,
         storage_ref,
         ciphertext_byte_size,
         ciphertext_hash
       }) do
    attrs = %{
      object_index: object_index,
      asset_object_id: asset_object_id,
      vault_id: vault_id,
      key_domain_id: key_domain_id,
      classification: classification,
      lookup_digest: lookup_digest,
      storage_ref: storage_ref,
      ciphertext_byte_size: ciphertext_byte_size,
      ciphertext_hash: ciphertext_hash
    }

    with {:ok, _schema} <- schema_for(version),
         :ok <- validate_object_attrs(attrs) do
      {:ok, attrs |> Map.put(:kind, :object) |> Map.put(:logical_version, version)}
    end
  end

  defp decode_object_term(_term), do: invalid()

  defp validate_cut_attrs(attrs, schema) do
    with true <- exact_keys?(attrs, @cut_keys),
         true <- canonical_uuid?(attrs.manifest_id),
         true <- canonical_uuid?(attrs.vault_id),
         true <- canonical_uuid?(attrs.snapshot_id),
         true <- canonical_database_snapshot?(attrs.database_snapshot),
         true <- unsigned_bigint?(attrs.outbox_high_water_mark),
         true <- table_count_vector?(attrs.table_count_vector, schema.count()),
         true <- unsigned_bigint?(attrs.object_count),
         true <- valid_frame_count?(attrs.table_count_vector, attrs.object_count) do
      :ok
    else
      _invalid -> invalid()
    end
  end

  defp validate_object_attrs(attrs) do
    with true <- exact_keys?(attrs, @object_keys),
         true <- unsigned_bigint?(attrs.object_index),
         true <- canonical_uuid?(attrs.asset_object_id),
         true <- canonical_uuid?(attrs.vault_id),
         true <- canonical_uuid?(attrs.key_domain_id),
         true <- attrs.classification in @classifications,
         true <- sha256?(attrs.lookup_digest),
         true <- nonempty_utf8?(attrs.storage_ref),
         true <- unsigned_bigint?(attrs.ciphertext_byte_size),
         true <- sha256?(attrs.ciphertext_hash) do
      :ok
    else
      _invalid -> invalid()
    end
  end

  defp validate_row(schema, primary_key_values, ordered_column_values) do
    with true <- column_values?(ordered_column_values, schema.columns),
         true <- primary_key_values?(primary_key_values, schema.primary_key),
         true <-
           primary_key_matches_columns?(
             primary_key_values,
             schema.primary_key,
             ordered_column_values
           ) do
      :ok
    else
      _invalid -> invalid()
    end
  end

  defp encode_record(term, type, payload_limit) do
    payload = :erlang.term_to_binary(term, [:deterministic])

    if byte_size(payload) <= payload_limit do
      {:ok, %{type: type, payload: payload, payload_length: byte_size(payload)}}
    else
      invalid()
    end
  end

  defp decode_canonical(<<131, tag, _rest::binary>> = payload, payload_limit)
       when tag != 80 and byte_size(payload) <= payload_limit do
    try do
      case :erlang.binary_to_term(payload, [:safe, :used]) do
        {term, consumed} when consumed == byte_size(payload) ->
          if :erlang.term_to_binary(term, [:deterministic]) == payload do
            {:ok, term}
          else
            invalid()
          end

        _partial ->
          invalid()
      end
    rescue
      ArgumentError -> invalid()
    end
  end

  defp decode_canonical(_payload, _payload_limit), do: invalid()

  defp exact_keys?(map, keys), do: Map.keys(map) |> Enum.sort() == Enum.sort(keys)

  defp canonical_uuid?(value) when is_binary(value) do
    match?({:ok, ^value}, Ecto.UUID.cast(value))
  end

  defp canonical_uuid?(_value), do: false

  defp canonical_database_snapshot?(value) when is_binary(value) do
    byte_size(value) <= @database_snapshot_limit and
      Regex.match?(
        ~r/\A(?:0|[1-9]\d*):(?:0|[1-9]\d*):(?:(?:0|[1-9]\d*)(?:,(?:0|[1-9]\d*))*)?\z/,
        value
      )
  end

  defp canonical_database_snapshot?(_value), do: false

  defp table_count_vector?(counts, table_count),
    do: table_count_vector?(counts, 0, table_count)

  defp table_count_vector?([], count, table_count), do: count == table_count

  defp table_count_vector?([count | rest], position, table_count) when position < table_count do
    unsigned_bigint?(count) and table_count_vector?(rest, position + 1, table_count)
  end

  defp table_count_vector?(_counts, _position, _table_count), do: false

  defp valid_frame_count?(table_count_vector, object_count) do
    1 + Enum.sum(table_count_vector) + 2 * object_count <= @non_manifest_frame_limit
  end

  defp column_values?([], []), do: true

  defp column_values?([value | values], [column | columns]) do
    column_value?(value, column) and column_values?(values, columns)
  end

  defp column_values?(_values, _columns), do: false

  defp column_value?({"null"}, %{nullable?: true}), do: true

  defp column_value?({tag, _value} = tagged_value, %{tag: tag}) do
    tagged_value?(tagged_value)
  end

  defp column_value?(_value, _column), do: false

  defp primary_key_values?([], []), do: true

  defp primary_key_values?([{tag, _value} = value | values], [primary_key | primary_keys])
       when tag == primary_key.tag do
    tagged_value?(value) and primary_key_values?(values, primary_keys)
  end

  defp primary_key_values?(_values, _primary_key), do: false

  defp primary_key_matches_columns?([], [], _ordered_column_values), do: true

  defp primary_key_matches_columns?(
         [value | values],
         [primary_key | primary_keys],
         ordered_column_values
       ) do
    Enum.at(ordered_column_values, primary_key.position) == value and
      primary_key_matches_columns?(values, primary_keys, ordered_column_values)
  end

  defp primary_key_matches_columns?(_values, _primary_key, _ordered_column_values), do: false

  defp tagged_value?({"boolean", value}), do: is_boolean(value)
  defp tagged_value?({"integer", value}), do: signed_bigint?(value)
  defp tagged_value?({"bytes", value}), do: is_binary(value)
  defp tagged_value?({"text", value}), do: utf8?(value)
  defp tagged_value?({"uuid", value}), do: canonical_uuid?(value)
  defp tagged_value?({"timestamp", value}), do: canonical_timestamp?(value)
  defp tagged_value?({"json", value}), do: json_value?(value)
  defp tagged_value?(_value), do: false

  defp canonical_timestamp?(value) when is_binary(value) do
    Regex.match?(~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/, value) and
      case DateTime.from_iso8601(value) do
        {:ok, datetime, 0} -> DateTime.to_iso8601(datetime) == value
        _invalid -> false
      end
  end

  defp canonical_timestamp?(_value), do: false

  defp json_value?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> utf8?(key) and json_value?(nested) end)
  end

  defp json_value?([]), do: true

  defp json_value?([value | rest]) do
    json_value?(value) and json_value?(rest)
  end

  defp json_value?(value) when is_binary(value), do: String.valid?(value)
  defp json_value?(value) when is_integer(value), do: true
  defp json_value?(value) when is_float(value), do: finite_float?(value)
  defp json_value?(value) when is_boolean(value) or is_nil(value), do: true
  defp json_value?(_value), do: false

  defp finite_float?(value) do
    :erlang.float_to_binary(value, [:compact]) not in ["nan", "inf", "-inf"]
  end

  defp payload_limit(@cut_type), do: {:ok, @header_payload_limit}
  defp payload_limit(@row_type), do: {:ok, @record_payload_limit}
  defp payload_limit(@object_type), do: {:ok, @record_payload_limit}
  defp payload_limit(_type), do: :error

  defp nonempty_utf8?(value), do: is_binary(value) and value != "" and String.valid?(value)
  defp utf8?(value), do: is_binary(value) and String.valid?(value)
  defp sha256?(value), do: is_binary(value) and byte_size(value) == 32

  defp signed_bigint?(value),
    do: is_integer(value) and value >= -@max_signed_bigint - 1 and value <= @max_signed_bigint

  defp unsigned_bigint?(value),
    do: is_integer(value) and value >= 0 and value <= @max_signed_bigint

  defp schema_for(1), do: {:ok, LogicalSchema}
  defp schema_for(2), do: {:ok, LogicalSchemaV2}
  defp schema_for(_version), do: invalid()

  defp invalid, do: {:error, Error.new(:backup_invalid)}
end
