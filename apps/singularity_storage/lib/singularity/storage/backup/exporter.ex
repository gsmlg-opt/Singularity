defmodule Singularity.Storage.Backup.Exporter do
  @moduledoc """
  Captures a repeatable-read vault cut and lazily streams its logical records
  and immutable objects.
  """

  alias Singularity.Storage.SafeSQL, as: SQL
  alias Singularity.Core.Error
  alias Singularity.Core.ObjectRef
  alias Singularity.Storage.Backup.LogicalRecordCodec
  alias Singularity.Storage.Backup.LogicalSchemaV2
  alias Singularity.Storage.Backup.LogicalSchemaV3

  @cut_record_type 0x0001
  @row_record_type 0x0002
  @object_evidence_record_type 0x0003
  @object_record_type 0x8000
  @object_chunk_bytes 65_536
  @object_stream_error :object_stream_error
  @classifications [:private, :sensitive, :restricted]
  @logical_cut_keys ~w[
    database_snapshot manifest_id object_inventory outbox_high_water_mark snapshot_id vault_id
  ]a
  @capture_cut_keys @logical_cut_keys -- [:manifest_id]
  @object_inventory_keys ~w[
    asset_object_id ciphertext_byte_size ciphertext_hash classification inventory_position
    key_domain_id lookup_digest storage_ref vault_id
  ]a
  @identity_tables ~w[
    identity.people identity.accounts identity.credentials identity.principals
  ]
  @identity_projection %{
    "identity.people" => 0..4,
    "identity.accounts" => 5..10,
    "identity.credentials" => 11..15,
    "identity.principals" => 16..23
  }
  @logical_stream_rows 500

  @spec snapshot_cut(module(), Ecto.UUID.t()) :: {:ok, map()} | {:error, Error.t()}
  def snapshot_cut(repo, vault_id),
    do: snapshot_cut(repo, vault_id, LogicalRecordCodec.default_version())

  def snapshot_cut(_repo, _vault_id, version) when version not in [2, 3],
    do: {:error, Error.new(:backup_unsupported)}

  def snapshot_cut(repo, vault_id, version) when is_atom(repo) and not is_nil(repo) do
    with {:ok, vault_id} <- canonical_uuid(vault_id),
         :ok <- require_repeatable_read(repo),
         {:ok, database_snapshot} <- database_snapshot(repo),
         {:ok, outbox_high_water_mark} <- outbox_high_water_mark(repo, vault_id),
         :ok <- reject_unsupported_canonical_rows(repo, vault_id, version),
         :ok <- reject_inflight_text_originals(repo, vault_id),
         {:ok, object_inventory} <- object_inventory(repo, vault_id, version) do
      {:ok,
       %{
         database_snapshot: database_snapshot,
         object_inventory: object_inventory,
         outbox_high_water_mark: outbox_high_water_mark,
         snapshot_id: Ecto.UUID.generate(),
         vault_id: vault_id
       }}
    end
  rescue
    _exception -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  def snapshot_cut(_repo, _vault_id, _version), do: invalid()

  @spec records(module(), map()) ::
          {:ok, %{records: Enumerable.t(), inventory: [map()]}} | {:error, Error.t()}
  def records(repo, cut), do: records(repo, cut, LogicalRecordCodec.default_version())

  def records(_repo, _cut, version) when version not in [2, 3],
    do: {:error, Error.new(:backup_unsupported)}

  def records(repo, cut, version) when is_atom(repo) and not is_nil(repo) and is_map(cut) do
    with :ok <- require_repeatable_read(repo),
         {:ok, cut} <- validate_logical_cut(cut),
         :ok <- require_database_snapshot(repo, cut.database_snapshot),
         :ok <- reject_unsupported_canonical_rows(repo, cut.vault_id, version),
         :ok <- reject_inflight_text_originals(repo, cut.vault_id),
         :ok <- require_inventory(repo, cut, version),
         {:ok, binding} <- transaction_binding(repo, cut.vault_id),
         {:ok, identity} <- identity_rows(repo, cut.vault_id, version),
         {:ok, table_inventory, table_counts} <-
           describe_tables(repo, cut, identity, version),
         {:ok, object_inventory} <- describe_object_evidence(cut.object_inventory, version),
         {:ok, header} <-
           LogicalRecordCodec.encode_cut(
             %{
               database_snapshot: cut.database_snapshot,
               manifest_id: cut.manifest_id,
               object_count: length(cut.object_inventory),
               outbox_high_water_mark: cut.outbox_high_water_mark,
               snapshot_id: cut.snapshot_id,
               table_count_vector: table_counts,
               vault_id: cut.vault_id
             },
             version
           ),
         {:ok, header_descriptor} <- logical_descriptor(header) do
      stream_identity = Map.take(identity, [:account_id, :principal_ids])
      records = logical_record_stream(repo, cut, stream_identity, header, version, binding)

      {:ok,
       %{
         records: records,
         inventory: [header_descriptor | table_inventory ++ object_inventory]
       }}
    else
      {:error, %Error{code: :storage_unavailable}} = error -> error
      {:error, %Error{code: :backup_unsupported}} = error -> error
      _invalid -> invalid()
    end
  rescue
    _exception -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  def records(_repo, _cut, _version), do: invalid()

  def stream_inventory(%{repo: repo, storage: storage}, cut),
    do: stream_inventory(repo, storage, cut)

  @spec stream_inventory({module(), map()}, map()) ::
          {:ok, %{records: Enumerable.t(), inventory: [map()]}} | {:error, Error.t()}
  def stream_inventory({storage_module, storage_context}, cut)
      when is_atom(storage_module) and not is_nil(storage_module) and is_map(storage_context) and
             is_map(cut) do
    with true <- storage_adapter?(storage_module),
         {:ok, vault_id} <- cut_vault_id(cut),
         {:ok, entries} <- validate_inventory(Map.get(cut, :object_inventory), vault_id) do
      descriptors = Enum.map(entries, &descriptor/1)

      records =
        Stream.map(entries, fn entry ->
          Map.merge(entry, %{
            payload: object_payload(storage_module, storage_context, entry),
            payload_length: entry.ciphertext_byte_size,
            type: @object_record_type
          })
        end)

      {:ok, %{records: records, inventory: descriptors}}
    else
      {:error, %Error{}} = error -> error
      _invalid -> invalid()
    end
  rescue
    _exception -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  def stream_inventory(_storage, _cut), do: invalid()

  def stream_inventory(repo, {storage_module, storage_context}, cut)
      when is_atom(repo) and not is_nil(repo) and is_atom(storage_module) and
             not is_nil(storage_module) and is_map(storage_context) and is_map(cut) do
    with true <- storage_adapter?(storage_module),
         true <- exact_keys?(cut, @capture_cut_keys),
         {:ok, logical_cut} <- validate_logical_cut(Map.put(cut, :manifest_id, cut.snapshot_id)),
         :ok <- require_repeatable_read(repo),
         :ok <- require_database_snapshot(repo, logical_cut.database_snapshot),
         {:ok, binding} <- transaction_binding(repo, logical_cut.vault_id) do
      records =
        logical_cut.object_inventory
        |> Stream.map(fn entry ->
          Map.merge(entry, %{
            payload: object_payload(storage_module, storage_context, entry, binding),
            payload_length: entry.ciphertext_byte_size,
            type: @object_record_type
          })
        end)
        |> guard_logical_stream(binding)

      {:ok, %{records: records, inventory: Enum.map(logical_cut.object_inventory, &descriptor/1)}}
    else
      {:error, %Error{}} = error -> error
      _invalid -> invalid()
    end
  rescue
    _exception -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  def stream_inventory(_repo, _storage, _cut), do: invalid()

  defp validate_logical_cut(cut) do
    with true <- exact_keys?(cut, @logical_cut_keys),
         {:ok, manifest_id} <- canonical_uuid(cut.manifest_id),
         {:ok, snapshot_id} <- canonical_uuid(cut.snapshot_id),
         {:ok, vault_id} <- canonical_uuid(cut.vault_id),
         true <- is_binary(cut.database_snapshot),
         true <- is_integer(cut.outbox_high_water_mark) and cut.outbox_high_water_mark >= 0,
         true <-
           is_list(cut.object_inventory) and
             Enum.all?(cut.object_inventory, &exact_keys?(&1, @object_inventory_keys)),
         {:ok, object_inventory} <- validate_inventory(cut.object_inventory, vault_id) do
      {:ok,
       %{
         database_snapshot: cut.database_snapshot,
         manifest_id: manifest_id,
         object_inventory: object_inventory,
         outbox_high_water_mark: cut.outbox_high_water_mark,
         snapshot_id: snapshot_id,
         vault_id: vault_id
       }}
    else
      _invalid -> invalid()
    end
  end

  defp identity_rows(repo, vault_id, version) do
    projection =
      if version == 3 do
        "person_id, person_display_name, person_metadata::text, person_inserted_at, " <>
          "person_updated_at, account_id, account_person_id, account_status, account_metadata::text, " <>
          "account_inserted_at, account_updated_at, credential_id, credential_account_id, " <>
          "credential_normalized_login, credential_revoked_at, credential_inserted_at, " <>
          "principal_id, principal_account_id, principal_kind, principal_authorization_epoch, " <>
          "principal_revoked_at, principal_metadata::text, principal_inserted_at, principal_updated_at"
      else
        "*"
      end

    statement = """
    SELECT #{projection}
    FROM identity.export_current_vault_owner($1)
    ORDER BY principal_id, credential_id
    """

    repo
    |> logical_query_stream(statement, [Ecto.UUID.dump!(vault_id)])
    |> Enum.reduce_while({:ok, empty_identity_rows()}, fn raw_row, {:ok, rows} ->
      case add_identity_projection(rows, raw_row, version) do
        {:ok, projected} -> {:cont, {:ok, projected}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} -> finish_identity_rows(rows)
      {:error, %Error{}} = error -> error
    end
  end

  defp empty_identity_rows do
    Map.new(@identity_tables, &{&1, %{}})
  end

  defp add_identity_projection(rows, raw_row, version)
       when is_list(raw_row) and length(raw_row) == 24 do
    Enum.reduce_while(@identity_tables, {:ok, rows}, fn table, {:ok, projected} ->
      {:ok, schema} = schema_registry(version).fetch_table(table)
      values = Enum.map(@identity_projection[table], &Enum.at(raw_row, &1))

      with {:ok, logical_row} <- tagged_row(schema, values, version),
           {:ok, table_rows} <-
             put_unique_row(projected[table], logical_row.primary_key_values, logical_row) do
        {:cont, {:ok, Map.put(projected, table, table_rows)}}
      else
        _invalid -> {:halt, invalid()}
      end
    end)
  end

  defp add_identity_projection(_rows, _raw_row, _version), do: invalid()

  defp put_unique_row(rows, primary_key, row) do
    case Map.fetch(rows, primary_key) do
      :error -> {:ok, Map.put(rows, primary_key, row)}
      {:ok, ^row} -> {:ok, rows}
      {:ok, _conflicting} -> invalid()
    end
  end

  defp finish_identity_rows(rows) do
    groups =
      Map.new(@identity_tables, fn table ->
        ordered_rows = rows[table] |> Map.values() |> Enum.sort_by(& &1.primary_key_values)
        {table, ordered_rows}
      end)

    people = groups["identity.people"]
    accounts = groups["identity.accounts"]
    credentials = groups["identity.credentials"]
    principals = groups["identity.principals"]

    with [person] <- people,
         [account] <- accounts,
         true <- credentials != [],
         true <- principals != [],
         person_id <- tagged_value_at(person, 0),
         account_id <- tagged_value_at(account, 0),
         ^person_id <- tagged_value_at(account, 1),
         true <- Enum.all?(credentials, &(tagged_value_at(&1, 1) == account_id)),
         true <- Enum.any?(credentials, &(Enum.at(&1.ordered_column_values, 3) == {"null"})),
         true <- Enum.all?(principals, &(tagged_value_at(&1, 1) == account_id)),
         true <-
           Enum.any?(principals, fn principal ->
             tagged_value_at(principal, 2) == "owner" and
               Enum.at(principal.ordered_column_values, 4) == {"null"}
           end) do
      {:ok,
       %{
         account_id: account_id,
         groups: groups,
         principal_ids: MapSet.new(principals, &tagged_value_at(&1, 0))
       }}
    else
      _invalid -> invalid()
    end
  end

  defp describe_tables(repo, cut, identity, version) do
    schema_registry(version).all()
    |> Enum.reduce_while({:ok, [], []}, fn schema, {:ok, inventory, counts} ->
      result =
        if schema.table in @identity_tables do
          describe_tagged_rows(identity.groups[schema.table])
        else
          describe_database_table(repo, schema, cut, identity, version)
        end

      case result do
        {:ok, descriptors, count} ->
          {:cont, {:ok, [descriptors | inventory], [count | counts]}}

        {:error, %Error{}} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, inventory, counts} ->
        {:ok, inventory |> Enum.reverse() |> List.flatten(), Enum.reverse(counts)}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp describe_tagged_rows(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, descriptors} ->
      with {:ok, record} <- encode_tagged_row(row),
           {:ok, descriptor} <- logical_descriptor(record) do
        {:cont, {:ok, [descriptor | descriptors]}}
      else
        _invalid -> {:halt, invalid()}
      end
    end)
    |> case do
      {:ok, descriptors} -> {:ok, Enum.reverse(descriptors), length(descriptors)}
      {:error, %Error{}} = error -> error
    end
  end

  defp describe_database_table(repo, schema, cut, identity, version) do
    {statement, parameters} = table_query(schema, cut, identity.account_id, version)

    repo
    |> logical_query_stream(statement, parameters)
    |> Enum.reduce_while({:ok, []}, fn raw_row, {:ok, descriptors} ->
      with {:ok, row} <- tagged_row(schema, raw_row, version),
           :ok <- validate_identity_references(row, identity.principal_ids),
           {:ok, record} <- encode_tagged_row(row),
           {:ok, descriptor} <- logical_descriptor(record) do
        {:cont, {:ok, [descriptor | descriptors]}}
      else
        _invalid -> {:halt, invalid()}
      end
    end)
    |> case do
      {:ok, descriptors} ->
        descriptors = Enum.reverse(descriptors)

        if schema.table == "core.vault_key_wrappers" and length(descriptors) != 1 do
          invalid()
        else
          {:ok, descriptors, length(descriptors)}
        end

      {:error, %Error{}} = error ->
        error
    end
  end

  defp describe_object_evidence(entries, version) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, descriptors} ->
      with {:ok, record} <- encode_object_evidence(entry, version),
           {:ok, descriptor} <- logical_descriptor(record) do
        {:cont, {:ok, [descriptor | descriptors]}}
      else
        _invalid -> {:halt, invalid()}
      end
    end)
    |> case do
      {:ok, descriptors} -> {:ok, Enum.reverse(descriptors)}
      {:error, %Error{}} = error -> error
    end
  end

  defp logical_record_stream(repo, cut, identity, header, version, binding) do
    identity_stream =
      Stream.flat_map([:identity], fn :identity ->
        case identity_rows(repo, cut.vault_id, version) do
          {:ok, repeated_identity}
          when repeated_identity.account_id == identity.account_id and
                 repeated_identity.principal_ids == identity.principal_ids ->
            @identity_tables
            |> Stream.flat_map(&repeated_identity.groups[&1])
            |> Stream.map(&encode_tagged_row!/1)

          _invalid ->
            throw_logical_backup_invalid()
        end
      end)

    table_stream =
      schema_registry(version).all()
      |> Stream.reject(&(&1.table in @identity_tables))
      |> Stream.flat_map(fn schema ->
        database_table_record_stream(repo, schema, cut, identity, version)
      end)

    object_stream = Stream.map(cut.object_inventory, &encode_object_evidence!(&1, version))

    guard_logical_stream(
      Stream.concat([[header], identity_stream, table_stream, object_stream]),
      binding
    )
  end

  defp database_table_record_stream(repo, schema, cut, identity, version) do
    {statement, parameters} = table_query(schema, cut, identity.account_id, version)

    repo
    |> logical_query_stream(statement, parameters)
    |> Stream.map(fn raw_row ->
      with {:ok, row} <- tagged_row(schema, raw_row, version),
           :ok <- validate_identity_references(row, identity.principal_ids) do
        encode_tagged_row!(row)
      else
        _invalid -> throw_logical_backup_invalid()
      end
    end)
  end

  defp guard_logical_stream(enumerable, binding) do
    Stream.resource(
      fn -> {:initial, enumerable} end,
      fn state ->
        require_stream_binding!(binding)
        guarded_stream_next(state)
      end,
      &halt_guarded_stream/1
    )
  end

  defp guarded_stream_next(state) do
    result =
      case state do
        {:initial, enumerable} ->
          Enumerable.reduce(enumerable, {:cont, nil}, &suspend_stream_element/2)

        {:continuation, continuation} ->
          continuation.({:cont, nil})
      end

    case result do
      {:suspended, element, continuation} -> {[element], {:continuation, continuation}}
      {:done, _accumulator} -> {:halt, :done}
      {:halted, _accumulator} -> {:halt, :done}
    end
  rescue
    _exception -> throw_object_stream_error(storage_unavailable_error())
  catch
    :throw, {__MODULE__, @object_stream_error, %Error{} = error} ->
      throw_object_stream_error(error)

    _kind, _reason ->
      throw_object_stream_error(storage_unavailable_error())
  end

  defp suspend_stream_element(element, _accumulator), do: {:suspend, element}

  defp halt_guarded_stream({:continuation, continuation}) do
    _halted = continuation.({:halt, nil})
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp halt_guarded_stream(_state), do: :ok

  defp logical_query_stream(repo, statement, parameters) do
    repo
    |> sql_repo()
    |> SQL.stream(statement, parameters, max_rows: @logical_stream_rows, log: false)
    |> Stream.flat_map(fn
      %{rows: rows} when is_list(rows) -> rows
      _unexpected -> raise "unexpected logical export query result"
    end)
  end

  defp table_query(schema, cut, account_id, version) do
    projection =
      Enum.map_join(schema.columns, ", ", fn column ->
        suffix = if version == 3 and column.tag == "json", do: "::text", else: ""
        "source.#{quote_identifier(column.name)}#{suffix}"
      end)

    order =
      case schema.table do
        "core.outbox_events" ->
          "source.\"sequence\", source.\"id\""

        _table ->
          Enum.map_join(schema.primary_key, ", ", fn primary_key ->
            column = Enum.at(schema.columns, primary_key.position)
            "source.#{quote_identifier(column.name)}"
          end)
      end

    vault_id = Ecto.UUID.dump!(cut.vault_id)

    case schema.table do
      "core.capabilities" ->
        {
          """
          SELECT #{projection}
          FROM core.capabilities AS source
          WHERE EXISTS (
            SELECT 1
            FROM core.principal_capabilities AS assignment
            WHERE assignment.capability_id = source.id
              AND assignment.vault_id = $1
          )
          ORDER BY #{order}
          """,
          [vault_id]
        }

      "core.vaults" ->
        {standard_table_query(projection, schema.table, "source.id = $1", order), [vault_id]}

      "core.vault_key_wrappers" ->
        {
          """
          SELECT #{projection}
          FROM core.vault_key_wrappers AS source
          JOIN core.vault_key_versions AS active_version
            ON active_version.id = source.vault_key_version_id
           AND active_version.vault_id = source.vault_id
           AND active_version.state = 'active'
          WHERE source.vault_id = $1
            AND source.account_id = $2
          ORDER BY #{order}
          """,
          [vault_id, Ecto.UUID.dump!(account_id)]
        }

      "content.note_conflicts" ->
        {
          """
          SELECT #{projection}
          FROM content.export_note_conflicts_for_backup($1) AS source
          ORDER BY #{order}
          """,
          [vault_id]
        }

      "content.document_import_receipts" ->
        {
          """
          SELECT #{projection}
          FROM content.export_document_import_receipts_for_backup($1) AS source
          ORDER BY #{order}
          """,
          [vault_id]
        }

      "core.outbox_events" ->
        {
          standard_table_query(
            projection,
            schema.table,
            "source.vault_id = $1 AND source.sequence <= $2",
            order
          ),
          [vault_id, cut.outbox_high_water_mark]
        }

      table ->
        {standard_table_query(projection, table, "source.vault_id = $1", order), [vault_id]}
    end
  end

  defp standard_table_query(projection, table, predicate, order) do
    """
    SELECT #{projection}
    FROM #{quote_table(table)} AS source
    WHERE #{predicate}
    ORDER BY #{order}
    """
  end

  defp quote_table(table) do
    table
    |> String.split(".")
    |> Enum.map_join(".", &quote_identifier/1)
  end

  defp quote_identifier(identifier), do: ~s("#{identifier}")

  defp tagged_row(schema, raw_values, version)
       when is_list(raw_values) and length(raw_values) == length(schema.columns) do
    schema.columns
    |> Enum.zip(raw_values)
    |> Enum.reduce_while({:ok, []}, fn {column, value}, {:ok, values} ->
      case projected_value(column, value, version) do
        {:ok, tagged} -> {:cont, {:ok, [tagged | values]}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} ->
        ordered_column_values = Enum.reverse(values)

        {:ok,
         %{
           ordered_column_values: ordered_column_values,
           primary_key_values:
             Enum.map(schema.primary_key, &Enum.at(ordered_column_values, &1.position)),
           schema: schema,
           version: version
         }}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp tagged_row(_schema, _raw_values, _version), do: invalid()

  defp projected_value(%{tag: "json"}, value, 3) when is_binary(value) do
    case JSON.decode(value) do
      {:ok, decoded} -> {:ok, {"json", decoded}}
      _invalid -> invalid()
    end
  end

  defp projected_value(column, value, _version), do: tagged_value(column, value)

  defp tagged_value(%{nullable?: true}, nil), do: {:ok, {"null"}}
  defp tagged_value(%{nullable?: false}, nil), do: invalid()

  defp tagged_value(%{tag: "uuid"}, value) do
    case loaded_uuid(value) do
      {:ok, uuid} -> {:ok, {"uuid", uuid}}
      _invalid -> invalid()
    end
  end

  defp tagged_value(%{tag: "timestamp"}, %DateTime{} = value) do
    if value.utc_offset + value.std_offset == 0 do
      {microseconds, _precision} = value.microsecond
      {:ok, {"timestamp", DateTime.to_iso8601(%{value | microsecond: {microseconds, 6}})}}
    else
      invalid()
    end
  end

  defp tagged_value(%{tag: "text"}, value) when is_binary(value),
    do: {:ok, {"text", value}}

  defp tagged_value(%{tag: "bytes"}, value) when is_binary(value),
    do: {:ok, {"bytes", value}}

  defp tagged_value(%{tag: "integer"}, value) when is_integer(value),
    do: {:ok, {"integer", value}}

  defp tagged_value(%{tag: "boolean"}, value) when is_boolean(value),
    do: {:ok, {"boolean", value}}

  defp tagged_value(%{tag: "json"}, value), do: {:ok, {"json", value}}
  defp tagged_value(_column, _value), do: invalid()

  defp encode_tagged_row(row) do
    LogicalRecordCodec.encode_row(
      row.schema.table,
      row.primary_key_values,
      row.ordered_column_values,
      row.version
    )
  end

  defp encode_tagged_row!(row) do
    case encode_tagged_row(row) do
      {:ok, %{type: @row_record_type} = record} -> record
      _invalid -> throw_logical_backup_invalid()
    end
  end

  defp encode_object_evidence(entry, version) do
    LogicalRecordCodec.encode_object(
      %{
        asset_object_id: entry.asset_object_id,
        ciphertext_byte_size: entry.ciphertext_byte_size,
        ciphertext_hash: entry.ciphertext_hash,
        classification: Atom.to_string(entry.classification),
        key_domain_id: entry.key_domain_id,
        lookup_digest: entry.lookup_digest,
        object_index: entry.inventory_position,
        storage_ref: entry.storage_ref,
        vault_id: entry.vault_id
      },
      version
    )
  end

  defp encode_object_evidence!(entry, version) do
    case encode_object_evidence(entry, version) do
      {:ok, %{type: @object_evidence_record_type} = record} -> record
      _invalid -> throw_logical_backup_invalid()
    end
  end

  defp throw_logical_backup_invalid do
    throw_object_stream_error(Error.new(:backup_invalid))
  end

  defp logical_descriptor(record) do
    case LogicalRecordCodec.descriptor(record) do
      %{record_type: type} = descriptor
      when type in [@cut_record_type, @row_record_type, @object_evidence_record_type] ->
        {:ok, descriptor}

      _invalid ->
        invalid()
    end
  end

  defp tagged_value_at(row, position) do
    case Enum.at(row.ordered_column_values, position) do
      {_tag, value} -> value
      {"null"} -> nil
    end
  end

  @principal_reference_positions %{
    "core.vaults" => [7],
    "core.vault_members" => [0],
    "core.principal_capabilities" => [0],
    "identity.devices" => [1],
    "content.source_references" => [3],
    "content.tombstones" => [3],
    "content.note_versions" => [6],
    "audit.events" => [3],
    "core.outbox_events" => [5],
    "content.document_versions" => [12],
    "content.document_import_receipts" => [1],
    "content.tags" => [5],
    "content.relationships" => [7]
  }

  defp validate_identity_references(row, principal_ids) do
    row.schema.table
    |> then(&Map.get(@principal_reference_positions, &1, []))
    |> Enum.all?(fn position ->
      case Enum.at(row.ordered_column_values, position) do
        {"null"} -> true
        {"uuid", principal_id} -> MapSet.member?(principal_ids, principal_id)
        _invalid -> false
      end
    end)
    |> if(do: :ok, else: invalid())
  end

  defp exact_keys?(map, keys) when is_map(map),
    do: Map.keys(map) |> Enum.sort() == Enum.sort(keys)

  defp exact_keys?(_value, _keys), do: false

  defp require_repeatable_read(repo) do
    if repo.in_transaction?(), do: check_repeatable_read(repo), else: invalid()
  end

  defp check_repeatable_read(repo) do
    case query(repo, "SHOW transaction_isolation", []) do
      {:ok, %{rows: [["repeatable read"]]}} -> :ok
      {:ok, _other} -> invalid()
      {:error, %Error{}} = error -> error
    end
  end

  defp require_database_snapshot(repo, expected_snapshot) do
    case database_snapshot(repo) do
      {:ok, ^expected_snapshot} -> :ok
      {:ok, _different_snapshot} -> invalid()
      {:error, %Error{}} = error -> error
    end
  end

  defp database_snapshot(repo) do
    case query(repo, "SELECT txid_current_snapshot()::text", []) do
      {:ok, %{rows: [[snapshot]]}} when is_binary(snapshot) and snapshot != "" ->
        {:ok, snapshot}

      {:ok, _other} ->
        storage_unavailable()

      {:error, %Error{}} = error ->
        error
    end
  end

  defp outbox_high_water_mark(repo, vault_id) do
    case query(
           repo,
           """
           SELECT COALESCE(max(sequence), 0)
           FROM core.outbox_events
           WHERE vault_id = $1
           """,
           [Ecto.UUID.dump!(vault_id)]
         ) do
      {:ok, %{rows: [[mark]]}} when is_integer(mark) and mark >= 0 -> {:ok, mark}
      {:ok, _other} -> storage_unavailable()
      {:error, %Error{}} = error -> error
    end
  end

  defp reject_unsupported_canonical_rows(repo, vault_id, version) do
    {statement, parameters} =
      if version == 3 do
        {"SELECT content.backup_has_unsupported_canonical_rows($1,$2)",
         [Ecto.UUID.dump!(vault_id), version]}
      else
        {"SELECT content.backup_has_unsupported_canonical_rows($1)", [Ecto.UUID.dump!(vault_id)]}
      end

    case query(
           repo,
           statement,
           parameters
         ) do
      {:ok, %{rows: [[false]]}} -> :ok
      {:ok, %{rows: [[true]]}} -> {:error, Error.new(:backup_unsupported)}
      {:ok, _other} -> storage_unavailable()
      {:error, %Error{}} = error -> error
    end
  end

  # Logical bundles omit upload grants/stages. An uploaded or verified text
  # original cannot resume from an empty destination until its real finalization
  # atomically completes metadata. Query this SAME repeatable-read cut at each
  # public entrypoint, without trusting ephemeral worker or stage state.
  defp reject_inflight_text_originals(repo, vault_id) do
    case query(
           repo,
           """
           SELECT EXISTS (
             SELECT 1 FROM content.assets AS asset
             WHERE asset.vault_id = $1 AND asset.state IN ('uploaded', 'verified')
               AND (
                 EXISTS (
                   SELECT 1 FROM content.source_references AS source
                   WHERE source.vault_id = asset.vault_id
                     AND source.resource_version_id = asset.resource_version_id
                     AND source.declared_media_type IN ('text/plain', 'text/markdown')
                 )
                 OR EXISTS (
                   SELECT 1 FROM content.asset_metadata AS metadata
                   WHERE metadata.vault_id = asset.vault_id AND metadata.asset_id = asset.id
                     AND (metadata.declared_media_type IN ('text/plain', 'text/markdown')
                       OR metadata.extractor_version = 'upload_text_v1')
                 )
               )
           )
           """,
           [Ecto.UUID.dump!(vault_id)]
         ) do
      {:ok, %{rows: [[false]]}} -> :ok
      {:ok, %{rows: [[true]]}} -> {:error, Error.new(:backup_unsupported)}
      {:ok, _other} -> storage_unavailable()
      {:error, %Error{}} = error -> error
    end
  end

  defp object_inventory(repo, vault_id, 3) do
    case query(
           repo,
           """
           WITH required AS (
             SELECT object.id
             FROM content.asset_objects AS object
             WHERE object.vault_id = $1 AND object.lifecycle = 'available'
               AND EXISTS (SELECT 1 FROM content.assets AS asset
                 WHERE asset.asset_object_id = object.id AND asset.vault_id = object.vault_id
                   AND asset.state NOT IN ('pending_delete', 'deleted'))
             UNION
             SELECT source_object_id FROM content.document_versions WHERE vault_id = $1
           )
           SELECT object.id, object.vault_id, object.key_domain_id, object.classification,
             object.lookup_digest, object.storage_ref, object.ciphertext_byte_size, object.ciphertext_hash
           FROM required LEFT JOIN content.asset_objects AS object
             ON object.id = required.id AND object.vault_id = $1 AND object.lifecycle = 'available'
           ORDER BY required.id
           """,
           [Ecto.UUID.dump!(vault_id)]
         ) do
      {:ok, %{rows: rows}} when is_list(rows) -> rows_to_inventory(rows, vault_id)
      {:ok, _other} -> storage_unavailable()
      {:error, %Error{}} = error -> error
    end
  end

  defp object_inventory(repo, vault_id, 2) do
    case query(
           repo,
           """
           SELECT
             object.id,
             object.vault_id,
             object.key_domain_id,
             object.classification,
             object.lookup_digest,
             object.storage_ref,
             object.ciphertext_byte_size,
             object.ciphertext_hash
           FROM content.asset_objects AS object
           WHERE object.vault_id = $1
             AND object.lifecycle = 'available'
             AND EXISTS (
               SELECT 1
               FROM content.assets AS asset
               WHERE asset.asset_object_id = object.id
                 AND asset.vault_id = object.vault_id
                 AND asset.state NOT IN ('pending_delete', 'deleted')
             )
           ORDER BY object.id
           """,
           [Ecto.UUID.dump!(vault_id)]
         ) do
      {:ok, %{rows: rows}} when is_list(rows) -> rows_to_inventory(rows, vault_id)
      {:ok, _other} -> storage_unavailable()
      {:error, %Error{}} = error -> error
    end
  end

  defp require_inventory(_repo, _cut, 2), do: :ok

  defp require_inventory(repo, cut, 3) do
    with {:ok, entries} <- object_inventory(repo, cut.vault_id, 3),
         true <- entries == cut.object_inventory do
      :ok
    else
      {:error, %Error{}} = error -> error
      _invalid -> invalid()
    end
  end

  defp schema_registry(2), do: LogicalSchemaV2
  defp schema_registry(3), do: LogicalSchemaV3

  defp transaction_binding(repo, vault_id) do
    with true <- repo.in_transaction?(),
         {:ok, %{rows: [[backend, xid, "repeatable read", owner, principal]]}} <-
           query(
             repo,
             """
             SELECT pg_backend_pid(), pg_current_xact_id()::text,
               current_setting('transaction_isolation'),
               NULLIF(current_setting('singularity.vault_id', true), '')::uuid,
               NULLIF(current_setting('singularity.principal_id', true), '')::uuid
             """,
             []
           ),
         true <- is_integer(backend) and is_binary(xid) and xid != "",
         {:ok, ^vault_id} <- loaded_uuid(owner),
         {:ok, principal_id} <- loaded_uuid(principal) do
      {:ok,
       %{
         caller: self(),
         repo: repo,
         backend: backend,
         xid: xid,
         vault_id: vault_id,
         principal_id: principal_id
       }}
    else
      {:error, %Error{}} = error -> error
      _invalid -> invalid()
    end
  end

  defp require_stream_binding!(nil), do: :ok

  defp require_stream_binding!(%{caller: caller, repo: repo} = binding) do
    with true <- self() == caller,
         true <- repo.in_transaction?(),
         {:ok, ^binding} <- transaction_binding(repo, binding.vault_id) do
      :ok
    else
      _invalid -> throw_object_stream_error(storage_unavailable_error())
    end
  rescue
    _exception -> throw_object_stream_error(storage_unavailable_error())
  end

  defp rows_to_inventory(rows, expected_vault_id) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {
        [
          object_id,
          vault_id,
          key_domain_id,
          classification,
          lookup_digest,
          storage_ref,
          ciphertext_byte_size,
          ciphertext_hash
        ],
        position
      },
      {:ok, entries} ->
        with {:ok, object_id} <- loaded_uuid(object_id),
             {:ok, ^expected_vault_id} <- loaded_uuid(vault_id),
             {:ok, key_domain_id} <- loaded_uuid(key_domain_id),
             {:ok, classification} <- classification(classification),
             true <- digest?(lookup_digest),
             true <- is_binary(storage_ref) and storage_ref != "",
             true <- is_integer(ciphertext_byte_size) and ciphertext_byte_size >= 0,
             true <- digest?(ciphertext_hash) do
          entry = %{
            asset_object_id: object_id,
            ciphertext_byte_size: ciphertext_byte_size,
            ciphertext_hash: ciphertext_hash,
            classification: classification,
            inventory_position: position,
            key_domain_id: key_domain_id,
            lookup_digest: lookup_digest,
            storage_ref: storage_ref,
            vault_id: expected_vault_id
          }

          {:cont, {:ok, [entry | entries]}}
        else
          _invalid -> {:halt, invalid()}
        end

      _row, _entries ->
        {:halt, storage_unavailable()}
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, %Error{}} = error -> error
    end
  end

  defp validate_inventory(entries, vault_id) when is_list(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, position}, {:ok, validated} ->
      case validate_entry(entry, vault_id, position) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | validated]}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, validated} -> {:ok, Enum.reverse(validated)}
      {:error, %Error{}} = error -> error
    end
  end

  defp validate_inventory(_entries, _vault_id), do: invalid()

  defp validate_entry(
         %{
           asset_object_id: object_id,
           vault_id: entry_vault_id,
           key_domain_id: key_domain_id,
           classification: classification,
           lookup_digest: lookup_digest,
           storage_ref: storage_ref,
           ciphertext_byte_size: ciphertext_byte_size,
           ciphertext_hash: ciphertext_hash,
           inventory_position: position
         },
         vault_id,
         position
       )
       when classification in @classifications and is_binary(storage_ref) and storage_ref != "" and
              is_integer(ciphertext_byte_size) and ciphertext_byte_size >= 0 and
              is_binary(lookup_digest) and byte_size(lookup_digest) == 32 and
              is_binary(ciphertext_hash) and byte_size(ciphertext_hash) == 32 do
    with {:ok, object_id} <- canonical_uuid(object_id),
         {:ok, ^vault_id} <- canonical_uuid(entry_vault_id),
         {:ok, key_domain_id} <- canonical_uuid(key_domain_id) do
      {:ok,
       %{
         asset_object_id: object_id,
         ciphertext_byte_size: ciphertext_byte_size,
         ciphertext_hash: ciphertext_hash,
         classification: classification,
         inventory_position: position,
         key_domain_id: key_domain_id,
         lookup_digest: lookup_digest,
         storage_ref: storage_ref,
         vault_id: vault_id
       }}
    else
      _invalid -> invalid()
    end
  end

  defp validate_entry(_entry, _vault_id, _position), do: invalid()

  defp descriptor(entry) do
    %{
      payload_length: entry.ciphertext_byte_size,
      record_type: @object_record_type,
      sha256: entry.ciphertext_hash
    }
  end

  defp object_payload(storage_module, storage_context, entry, binding \\ nil) do
    context =
      Map.merge(storage_context, %{
        ciphertext_hash: entry.ciphertext_hash,
        domain_namespace: entry.key_domain_id,
        lookup_digest: Base.encode16(entry.lookup_digest, case: :lower),
        vault_namespace: entry.vault_id
      })

    Stream.resource(
      fn ->
        require_stream_binding!(binding)
        open_object(storage_module, context, entry.storage_ref)
      end,
      fn state ->
        require_stream_binding!(binding)
        read_object(state, storage_module, context, entry, binding)
      end,
      fn _state -> :ok end
    )
  end

  defp open_object(storage_module, context, storage_ref) do
    case storage_call(storage_module, :open, [context, %ObjectRef{object_id: storage_ref}]) do
      {:ok, handle} -> {:open, handle, 0, :crypto.hash_init(:sha256)}
      {:error, %Error{} = error} -> {:failed, error}
    end
  end

  defp read_object({:failed, %Error{} = error}, _storage_module, _context, _entry, _binding),
    do: throw_object_stream_error(error)

  defp read_object({:open, _handle, offset, _hash}, _storage_module, _context, entry, nil)
       when offset >= entry.ciphertext_byte_size,
       do: {:halt, :done}

  defp read_object({:open, handle, offset, hash}, storage_module, context, entry, _binding)
       when offset == entry.ciphertext_byte_size do
    case storage_call(storage_module, :read_range, [context, handle, offset..offset]) do
      {:ok, ""} ->
        if :crypto.hash_final(hash) == entry.ciphertext_hash,
          do: {:halt, :done},
          else: throw_object_stream_error(Error.new(:integrity_failure))

      {:ok, _bytes} ->
        throw_object_stream_error(Error.new(:integrity_failure))

      {:error, %Error{} = error} ->
        throw_object_stream_error(error)
    end
  end

  defp read_object({:open, handle, offset, hash}, storage_module, context, entry, _binding) do
    requested = min(@object_chunk_bytes, entry.ciphertext_byte_size - offset)
    range = offset..(offset + requested - 1)

    case storage_call(storage_module, :read_range, [context, handle, range]) do
      {:ok, ""} ->
        throw_object_stream_error(Error.new(:integrity_failure))

      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= requested ->
        {[bytes], {:open, handle, offset + byte_size(bytes), :crypto.hash_update(hash, bytes)}}

      {:ok, _unexpected} ->
        throw_object_stream_error(storage_unavailable_error())

      {:error, %Error{} = error} ->
        throw_object_stream_error(error)
    end
  end

  defp throw_object_stream_error(%Error{} = error) do
    throw({__MODULE__, @object_stream_error, error})
  end

  defp storage_adapter?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :open, 2) and
      function_exported?(module, :read_range, 3)
  end

  defp cut_vault_id(%{vault_id: vault_id}), do: canonical_uuid(vault_id)
  defp cut_vault_id(_cut), do: invalid()

  defp canonical_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> invalid()
    end
  end

  defp loaded_uuid(value) do
    case Ecto.UUID.load(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> canonical_uuid(value)
    end
  end

  defp classification("private"), do: {:ok, :private}
  defp classification("sensitive"), do: {:ok, :sensitive}
  defp classification("restricted"), do: {:ok, :restricted}
  defp classification(_classification), do: invalid()

  defp digest?(value), do: is_binary(value) and byte_size(value) == 32

  defp query(repo, statement, parameters) do
    case SQL.query(sql_repo(repo), statement, parameters, log: false) do
      {:ok, result} -> {:ok, result}
      {:error, _reason} -> storage_unavailable()
    end
  end

  defp sql_repo(repo) do
    if function_exported?(repo, :get_dynamic_repo, 0),
      do: repo.get_dynamic_repo(),
      else: repo
  end

  defp storage_call(module, function, arguments) do
    case apply(module, function, arguments) do
      {:ok, _value} = ok -> ok
      {:error, %Error{}} = error -> error
      _unexpected -> storage_unavailable()
    end
  rescue
    _exception -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  defp invalid, do: {:error, Error.new(:invalid)}

  defp storage_unavailable,
    do: {:error, storage_unavailable_error()}

  defp storage_unavailable_error,
    do: Error.new(:storage_unavailable, retryable?: true)
end
