defmodule Singularity.Storage.Backup.LogicalExporterTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Ecto.Adapters.SQL
  alias Singularity.Core.Error
  alias Singularity.Storage.Backup.Exporter
  alias Singularity.Storage.Backup.LogicalRecordCodec
  alias Singularity.Storage.Backup.LogicalSchema
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.ScopedRepo

  @query_event [:singularity, :storage, :worker_repo, :query]
  @wrapper_secret "logical-wrapper-secret-canary"
  @extra_verifier "logical-extra-verifier-canary"

  setup do
    %{one: raw_fixture, two: raw_other} = Fixtures.two_vaults!()
    seeded = seed_export_rows!(raw_fixture)

    {:ok,
     fixture: load_ids(raw_fixture),
     raw_fixture: raw_fixture,
     raw_other: raw_other,
     seeded: seeded,
     cut: cut(load_ids(raw_fixture), seeded.outbox_high_water_mark)}
  end

  test "exports deterministic lazy logical records with exact counts, ordering, and descriptors",
       %{fixture: fixture, raw_fixture: raw_fixture, seeded: seeded, cut: cut} do
    handler_id = {__MODULE__, self(), make_ref()}

    assert :ok =
             :telemetry.attach(
               handler_id,
               @query_event,
               &__MODULE__.capture_query/4,
               self()
             )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, result} =
             ScopedRepo.transact(
               WorkerRepo,
               %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
               [isolation: :repeatable_read],
               fn repo ->
                 export_cut = current_snapshot_cut(repo, cut)

                 assert {:ok, %{records: records, inventory: inventory}} =
                          Exporter.records(repo, export_cut)

                 descriptor_queries = drain_queries()
                 assert Enum.any?(descriptor_queries, &identity_export_query?/1)

                 assert [%{type: 0x0001}] = Enum.take(records, 1)
                 assert drain_queries() == []

                 first_records = Enum.to_list(records)
                 first_pass_queries = drain_queries()
                 assert Enum.any?(first_pass_queries, &identity_export_query?/1)
                 assert_all_database_tables_queried(first_pass_queries)

                 second_records = Enum.to_list(records)
                 second_pass_queries = drain_queries()
                 assert Enum.any?(second_pass_queries, &identity_export_query?/1)
                 assert_all_database_tables_queried(second_pass_queries)

                 assert first_records == second_records

                 assert Enum.map(first_records, &LogicalRecordCodec.descriptor/1) == inventory

                 {:ok,
                  %{
                    records: first_records,
                    inventory: inventory,
                    cut: export_cut,
                    queries: descriptor_queries ++ first_pass_queries ++ second_pass_queries
                  }}
               end
             )

    %{records: records, inventory: inventory, cut: cut, queries: queries} = result

    decoded =
      Enum.map(records, fn record ->
        assert {:ok, decoded_record} = LogicalRecordCodec.decode(record.type, record.payload)
        decoded_record
      end)

    assert [%{kind: :cut} = header | body] = decoded
    {rows, objects} = Enum.split_while(body, &(&1.kind == :row))
    assert Enum.all?(objects, &(&1.kind == :object))
    assert Enum.map(objects, & &1.object_index) == [0, 1]
    assert Enum.map(objects, & &1.classification) == ["private", "sensitive"]

    for {object, entry} <- Enum.zip(objects, cut.object_inventory) do
      assert object.asset_object_id == entry.asset_object_id
      assert object.vault_id == entry.vault_id
      assert object.key_domain_id == entry.key_domain_id
      assert object.classification == Atom.to_string(entry.classification)
      assert object.lookup_digest == entry.lookup_digest
      assert object.storage_ref == entry.storage_ref
      assert object.ciphertext_byte_size == entry.ciphertext_byte_size
      assert object.ciphertext_hash == entry.ciphertext_hash
      assert object.object_index == entry.inventory_position
    end

    assert header.manifest_id == cut.manifest_id
    assert header.vault_id == fixture.vault_id
    assert header.snapshot_id == cut.snapshot_id
    assert header.database_snapshot == cut.database_snapshot
    assert header.outbox_high_water_mark == cut.outbox_high_water_mark
    assert header.object_count == 2

    counts = table_counts(rows)
    assert header.table_count_vector == counts
    assert length(counts) == LogicalSchema.count()
    assert Enum.sum(counts) + header.object_count + 1 == length(records)
    assert length(inventory) == length(records)

    assert table_count(counts, "identity.people") == 1
    assert table_count(counts, "identity.accounts") == 1
    assert table_count(counts, "identity.credentials") == 2
    assert table_count(counts, "identity.principals") == 2
    assert table_count(counts, "core.capabilities") == 1
    assert table_count(counts, "core.vault_key_wrappers") == 1

    assert Enum.map(rows, & &1.table_ordinal) == Enum.sort(Enum.map(rows, & &1.table_ordinal))
    assert_vault_scoped_rows(rows, fixture.vault_id)

    rows
    |> Enum.group_by(& &1.table)
    |> Enum.each(fn
      {"core.outbox_events", outbox_rows} ->
        assert Enum.map(outbox_rows, &outbox_sort_key/1) ==
                 Enum.sort(Enum.map(outbox_rows, &outbox_sort_key/1))

      {_table, table_rows} ->
        assert Enum.map(table_rows, & &1.primary_key_values) ==
                 Enum.sort(Enum.map(table_rows, & &1.primary_key_values))
    end)

    outbox_rows = rows_for(rows, "core.outbox_events")
    assert length(outbox_rows) == 2

    assert Enum.map(outbox_rows, &tagged_value(Enum.at(&1.ordered_column_values, 0))) == [
             seeded.first_event_id,
             seeded.second_event_id
           ]

    assert Enum.all?(outbox_rows, fn row ->
             tagged_value(Enum.at(row.ordered_column_values, 1)) <=
               cut.outbox_high_water_mark
           end)

    capability_rows = rows_for(rows, "core.capabilities")

    assert Enum.map(capability_rows, &tagged_value(Enum.at(&1.ordered_column_values, 0))) == [
             seeded.referenced_capability_id
           ]

    payloads = IO.iodata_to_binary(Enum.map(records, & &1.payload))
    refute payloads =~ raw_fixture.verifier
    refute payloads =~ @extra_verifier
    refute payloads =~ @wrapper_secret

    refute Enum.any?(queries, &direct_identity_table_query?/1)

    wrapper_queries = Enum.filter(queries, &String.contains?(&1, "core.vault_key_wrappers"))
    assert wrapper_queries != []

    for query <- wrapper_queries do
      refute query =~ "kdf_version"
      refute query =~ "kdf_salt"
      refute query =~ "kdf_parameters"
      refute query =~ "wrapper_algorithm"
      refute query =~ "wrapped_key"
    end

    for excluded <- [
          "identity.sessions",
          "identity.auth_attempts",
          "identity.security_settings",
          "content.asset_stages",
          "content.upload_grants",
          "content.asset_search_documents",
          "audit.backup_manifests",
          "audit.backup_manifest_objects"
        ] do
      refute Enum.any?(queries, &String.contains?(&1, excluded))
    end
  end

  test "rejects missing or multiple matching active owner wrappers", %{
    fixture: fixture,
    raw_fixture: raw_fixture,
    seeded: seeded,
    cut: cut
  } do
    delete_wrapper!(seeded.wrapper_id)
    assert_export_invalid(fixture, cut)

    wrapper_id = insert_wrapper!(raw_fixture, seeded.vault_key_version_id, 1)
    _second_wrapper_id = insert_wrapper!(raw_fixture, seeded.vault_key_version_id, 1)
    assert_export_invalid(fixture, cut)

    delete_wrapper!(wrapper_id)
  end

  test "exports the active owner wrapper after password rewrap advances its generation", %{
    fixture: fixture,
    seeded: seeded,
    cut: cut
  } do
    Fixtures.with_owner(fn ->
      owner_query!(
        "UPDATE core.vault_key_wrappers SET generation = 2 WHERE id = $1",
        [Ecto.UUID.dump!(seeded.wrapper_id)]
      )
    end)

    assert {:ok, records} = materialized_records(fixture, cut)

    assert [wrapper] =
             records
             |> Enum.map(fn record ->
               {:ok, decoded} = LogicalRecordCodec.decode(record.type, record.payload)
               decoded
             end)
             |> Enum.filter(&(&1.kind == :row))
             |> rows_for("core.vault_key_wrappers")

    assert tagged_value(Enum.at(wrapper.ordered_column_values, 4)) == 2
  end

  test "accepts multiple active credentials but rejects a closure with none active", %{
    fixture: fixture,
    raw_fixture: raw_fixture,
    cut: cut
  } do
    assert {:ok, _export} = run_export(fixture, cut)

    Fixtures.with_owner(fn ->
      owner_query!(
        "UPDATE identity.credentials SET revoked_at = CURRENT_TIMESTAMP WHERE account_id = $1",
        [raw_fixture.account_id]
      )
    end)

    assert_export_invalid(fixture, cut)

    Fixtures.with_owner(fn ->
      owner_query!("DELETE FROM identity.sessions WHERE account_id = $1", [
        raw_fixture.account_id
      ])

      owner_query!("DELETE FROM identity.credentials WHERE account_id = $1", [
        raw_fixture.account_id
      ])
    end)

    assert_export_invalid(fixture, cut)
  end

  test "rejects vault rows that would reference identity outside the owner closure", %{
    fixture: fixture,
    raw_fixture: raw_fixture,
    raw_other: raw_other,
    cut: cut
  } do
    Fixtures.with_owner(fn ->
      owner_query!(
        "INSERT INTO core.vault_members (principal_id, vault_id) VALUES ($1, $2)",
        [raw_other.principal_id, raw_fixture.vault_id]
      )
    end)

    assert_export_invalid(fixture, cut)
  end

  test "tags lazy database failures as storage unavailable", %{fixture: fixture, cut: cut} do
    records =
      ScopedRepo.transact(
        WorkerRepo,
        %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
        [isolation: :repeatable_read],
        fn repo ->
          assert {:ok, export} = Exporter.records(repo, current_snapshot_cut(repo, cut))
          export.records
        end
      )

    assert {Exporter, :object_stream_error, %Error{code: :storage_unavailable}} =
             catch_throw(Enum.to_list(records))
  end

  test "rejects malformed cuts and inventory evidence", %{
    fixture: fixture,
    cut: cut
  } do
    assert_export_invalid(fixture, cut, false)
    assert_export_invalid(fixture, Map.delete(cut, :manifest_id))
    assert_export_invalid(fixture, %{cut | snapshot_id: "not-a-uuid"})
    assert_export_invalid(fixture, %{cut | database_snapshot: "not-a-snapshot"}, false)

    [first | rest] = cut.object_inventory
    malformed_inventory = [%{first | inventory_position: 7} | rest]
    assert_export_invalid(fixture, %{cut | object_inventory: malformed_inventory})

    extra_field_inventory = [Map.put(first, :unexpected, "field") | rest]
    assert_export_invalid(fixture, %{cut | object_inventory: extra_field_inventory})
    assert_export_invalid(fixture, %{cut | object_inventory: [:not_an_entry]})
  end

  def capture_query(_event, _measurements, %{query: query}, observer) when is_binary(query) do
    send(observer, {:logical_export_query, query})
  end

  def capture_query(_event, _measurements, _metadata, _observer), do: :ok

  defp assert_export_invalid(fixture, cut, bind_snapshot? \\ true) do
    assert {:error, %Error{code: :invalid}} = run_export(fixture, cut, bind_snapshot?)
  end

  defp run_export(fixture, cut, bind_snapshot? \\ true) do
    ScopedRepo.transact(
      WorkerRepo,
      %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
      [isolation: :repeatable_read],
      fn repo ->
        cut = if bind_snapshot?, do: current_snapshot_cut(repo, cut), else: cut
        Exporter.records(repo, cut)
      end
    )
  end

  defp materialized_records(fixture, cut) do
    ScopedRepo.transact(
      WorkerRepo,
      %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
      [isolation: :repeatable_read],
      fn repo ->
        with {:ok, export} <- Exporter.records(repo, current_snapshot_cut(repo, cut)) do
          {:ok, Enum.to_list(export.records)}
        end
      end
    )
  end

  defp current_snapshot_cut(repo, cut) do
    %{rows: [[database_snapshot]]} =
      SQL.query!(repo, "SELECT txid_current_snapshot()::text", [], log: false)

    %{cut | database_snapshot: database_snapshot}
  end

  defp drain_queries(queries \\ []) do
    receive do
      {:logical_export_query, query} -> drain_queries([query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp identity_export_query?(query) do
    String.contains?(query, "identity.export_current_vault_owner")
  end

  defp direct_identity_table_query?(query) do
    normalized = String.replace(query, "\"", "")

    Regex.match?(
      ~r/\b(?:FROM|JOIN)\s+identity\.(people|accounts|credentials|principals)\b/i,
      normalized
    )
  end

  defp assert_vault_scoped_rows(rows, vault_id) do
    Enum.each(rows, fn row ->
      {:ok, schema} = LogicalSchema.fetch_table(row.table)

      case Enum.find_index(schema.columns, &(&1.name == "vault_id")) do
        nil ->
          if row.table == "core.vaults" do
            assert tagged_value(Enum.at(row.ordered_column_values, 0)) == vault_id
          end

        position ->
          assert tagged_value(Enum.at(row.ordered_column_values, position)) == vault_id
      end
    end)
  end

  defp assert_all_database_tables_queried(queries) do
    for table <- LogicalSchema.tables() -- ~w(
          identity.people identity.accounts identity.credentials identity.principals
        ) do
      assert Enum.any?(queries, &table_query?(&1, table)),
             "expected lazy pass to query #{table}"
    end
  end

  defp table_query?(query, table) do
    query
    |> String.replace("\"", "")
    |> String.contains?("FROM #{table} AS source")
  end

  defp table_counts(rows) do
    by_ordinal = Enum.frequencies_by(rows, & &1.table_ordinal)
    Enum.map(0..(LogicalSchema.count() - 1), &Map.get(by_ordinal, &1, 0))
  end

  defp table_count(counts, table) do
    {:ok, schema} = LogicalSchema.fetch_table(table)
    Enum.at(counts, schema.ordinal)
  end

  defp rows_for(rows, table), do: Enum.filter(rows, &(&1.table == table))

  defp outbox_sort_key(row) do
    [tagged_value(Enum.at(row.ordered_column_values, 1)) | row.primary_key_values]
  end

  defp tagged_value({_tag, value}), do: value

  defp cut(fixture, outbox_high_water_mark) do
    object_ids = Enum.sort([Ecto.UUID.generate(), Ecto.UUID.generate()])

    inventory =
      Enum.zip(object_ids, [:private, :sensitive])
      |> Enum.with_index()
      |> Enum.map(fn {{object_id, classification}, position} ->
        %{
          asset_object_id: object_id,
          vault_id: fixture.vault_id,
          key_domain_id: Ecto.UUID.generate(),
          classification: classification,
          lookup_digest: :crypto.hash(:sha256, "lookup-#{position}"),
          storage_ref: "logical/#{position}/#{object_id}",
          ciphertext_byte_size: position + 17,
          ciphertext_hash: :crypto.hash(:sha256, "ciphertext-#{position}"),
          inventory_position: position
        }
      end)

    %{
      database_snapshot: "100:101:",
      manifest_id: Ecto.UUID.generate(),
      object_inventory: inventory,
      outbox_high_water_mark: outbox_high_water_mark,
      snapshot_id: Ecto.UUID.generate(),
      vault_id: fixture.vault_id
    }
  end

  defp seed_export_rows!(fixture) do
    extra_credential_id = uuid_dump()
    extra_principal_id = uuid_dump()
    capability_id = uuid_dump()
    unreferenced_capability_id = uuid_dump()
    vault_key_version_id = uuid_dump()
    wrapper_id = uuid_dump()

    Fixtures.with_owner(fn ->
      owner_query!(
        """
        INSERT INTO identity.credentials (id, account_id, normalized_login, verifier)
        VALUES ($1, $2, $3, $4)
        """,
        [
          extra_credential_id,
          fixture.account_id,
          "extra-#{Ecto.UUID.generate()}@example.test",
          @extra_verifier
        ]
      )

      owner_query!(
        "INSERT INTO identity.principals (id, account_id, kind) VALUES ($1, $2, 'system')",
        [extra_principal_id, fixture.account_id]
      )

      owner_query!(
        "INSERT INTO core.vault_members (principal_id, vault_id) VALUES ($1, $2)",
        [extra_principal_id, fixture.vault_id]
      )

      owner_query!(
        "INSERT INTO core.capabilities (id, name) VALUES ($1, $2)",
        [capability_id, "logical.export.#{Ecto.UUID.generate()}"]
      )

      owner_query!(
        "INSERT INTO core.capabilities (id, name) VALUES ($1, $2)",
        [unreferenced_capability_id, "logical.unreferenced.#{Ecto.UUID.generate()}"]
      )

      owner_query!(
        """
        INSERT INTO core.principal_capabilities (
          principal_id, vault_id, capability_id
        ) VALUES ($1, $2, $3)
        """,
        [fixture.principal_id, fixture.vault_id, capability_id]
      )

      owner_query!(
        """
        INSERT INTO core.vault_key_versions (
          id, vault_id, generation, state, algorithm, activated_at
        ) VALUES ($1, $2, 1, 'active', 'aes-256-gcm', CURRENT_TIMESTAMP)
        """,
        [vault_key_version_id, fixture.vault_id]
      )

      insert_wrapper_row!(wrapper_id, fixture, vault_key_version_id, 1)
    end)

    first_event = Fixtures.outbox_event!(fixture)
    second_event = Fixtures.outbox_event!(fixture)
    third_event = Fixtures.outbox_event!(fixture)
    first_sequence = outbox_sequence!(first_event.id)
    second_sequence = outbox_sequence!(second_event.id)
    third_sequence = outbox_sequence!(third_event.id)
    assert first_sequence < second_sequence and second_sequence < third_sequence

    %{
      extra_credential_id: load_uuid(extra_credential_id),
      extra_principal_id: load_uuid(extra_principal_id),
      first_event_id: load_uuid(first_event.id),
      second_event_id: load_uuid(second_event.id),
      outbox_high_water_mark: second_sequence,
      referenced_capability_id: load_uuid(capability_id),
      unreferenced_capability_id: load_uuid(unreferenced_capability_id),
      vault_key_version_id: load_uuid(vault_key_version_id),
      wrapper_id: load_uuid(wrapper_id)
    }
  end

  defp insert_wrapper!(fixture, vault_key_version_id, generation) do
    wrapper_id = uuid_dump()

    Fixtures.with_owner(fn ->
      insert_wrapper_row!(wrapper_id, fixture, Ecto.UUID.dump!(vault_key_version_id), generation)
    end)

    load_uuid(wrapper_id)
  end

  defp insert_wrapper_row!(wrapper_id, fixture, vault_key_version_id, generation) do
    owner_query!(
      """
      INSERT INTO core.vault_key_wrappers (
        id,
        vault_id,
        vault_key_version_id,
        account_id,
        generation,
        kdf_version,
        kdf_salt,
        kdf_parameters,
        wrapper_algorithm,
        wrapped_key
      ) VALUES (
        $1, $2, $3, $4, $5, 1, $6, $7::text::jsonb, 'aes_256_gcm', $8
      )
      """,
      [
        wrapper_id,
        fixture.vault_id,
        vault_key_version_id,
        fixture.account_id,
        generation,
        :crypto.strong_rand_bytes(16),
        JSON.encode!(%{"m_cost" => 8, "parallelism" => 1, "t_cost" => 1, "version" => 1}),
        @wrapper_secret
      ]
    )
  end

  defp delete_wrapper!(wrapper_id) do
    Fixtures.with_owner(fn ->
      owner_query!("DELETE FROM core.vault_key_wrappers WHERE id = $1", [
        Ecto.UUID.dump!(wrapper_id)
      ])
    end)
  end

  defp outbox_sequence!(event_id) do
    Fixtures.with_owner(fn ->
      %{rows: [[sequence]]} =
        owner_query!("SELECT sequence FROM core.outbox_events WHERE id = $1", [event_id])

      sequence
    end)
  end

  defp owner_query!(statement, parameters) do
    SQL.query!(MigrationRepo, statement, parameters, log: false)
  end

  defp load_ids(fixture) do
    Map.new(fixture, fn
      {key, <<_::128>> = value} -> {key, load_uuid(value)}
      entry -> entry
    end)
  end

  defp uuid_dump, do: Ecto.UUID.generate() |> Ecto.UUID.dump!()
  defp load_uuid(value), do: Ecto.UUID.load!(value)
end
