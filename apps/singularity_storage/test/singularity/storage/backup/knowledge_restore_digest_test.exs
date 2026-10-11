defmodule Singularity.Storage.Backup.KnowledgeRestoreDigestTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Storage.Backup.{KnowledgeBackupFixtures, LogicalRecordCodec, LogicalSchemaV3}
  alias Singularity.Storage.SafeSQL

  @digest Singularity.Storage.Backup.KnowledgeRestoreDigest
  # Literal binary vectors were framed independently before implementation.
  # Table hash oracles use SHA-256 over those literal bytes, not this module.
  @vectors [
    {"text", "NULL::text", "04000000000000000000"},
    {"text", "''::text", "04010000000000000000"},
    {"text", "'界🙂'::text", "04010000000000000007e7958cf09f9982"},
    {"boolean", "false", "0101000000000000000100"},
    {"boolean", "true", "0101000000000000000101"},
    {"integer", "'-9223372036854775808'::bigint", "020100000000000000088000000000000000"},
    {"integer", "'9223372036854775807'::bigint", "020100000000000000087fffffffffffffff"},
    {"bytes", "decode('0000ff80','hex')", "030100000000000000040000ff80"},
    {"uuid", "'00112233-4455-6677-8899-aabbccddeeff'::uuid",
     "0501000000000000001000112233445566778899aabbccddeeff"},
    {"timestamp", "'1969-12-31 23:59:59.999999+00'::timestamptz",
     "06010000000000000008ffffffffffffffff"},
    {"timestamp", "'1970-01-01 00:00:00.000001+00'::timestamptz",
     "060100000000000000080000000000000001"},
    {"json", "NULL::jsonb", "07000000000000000000"},
    {"json", "'null'::jsonb", "0701000000000000000100"},
    {"json", "'false'::jsonb", "0701000000000000000101"},
    {"json", "'true'::jsonb", "0701000000000000000102"},
    {"json", "'1'::jsonb", "0701000000000000000a03000000000000000131"},
    {"json", "'1.0'::jsonb", "0701000000000000000a03000000000000000131"},
    {"json", "'1e0'::jsonb", "0701000000000000000a03000000000000000131"},
    {"json", "'-0.00'::jsonb", "0701000000000000000a03000000000000000130"},
    {"json", "'\"界\\n\\\"\"'::jsonb", "0701000000000000000e040000000000000005e7958c0a22"},
    {"json", "'[]'::jsonb", "07010000000000000009050000000000000000"},
    {"json", "'{}'::jsonb", "07010000000000000009060000000000000000"},
    {"json", "'{\"界\":2,\"z\":[null,true,{\"a\":\"é\"}],\"é\":1.00}'::jsonb",
     "0701000000000000009b06000000000000000300000000000000017a00000000000000480500000000000000030000000000000001000000000000000001020000000000000025060000000000000001000000000000000161000000000000000b040000000000000002c3a90000000000000002c3a9000000000000000a030000000000000001310000000000000003e7958c000000000000000a03000000000000000132"},
    {"json", "'12345678901234567890123456789012345678901234567890.1200'::jsonb",
     "0701000000000000003e03000000000000003531323334353637383930313233343536373839303132333435363738393031323334353637383930313233343536373839302e3132"},
    {"json", "'1.25e-7'::jsonb", "0701000000000000001403000000000000000b302e303030303030313235"}
  ]

  @empty_digest "06748816d518ce749f176bd61301a931a9c741074d0616d7fa1043600e3f1952"
  @two_rows_digest "68b2f172d46d7d4779db36c530447183c1715be2fb2afb94743c344721c985a2"
  @reversed_digest "82b6573b5da1aeeb046881275050f1503b8ab2c84a50c2ae36ec8ef7a5457ddb"

  test "the typed digest exposes only fixed registry and bounded SQL seams" do
    assert Code.ensure_loaded?(@digest), "missing knowledge restore typed digest"

    for {function, arity} <- [projection: 1, install: 1, value_encoding_sql: 1, table_digest: 3] do
      assert function_exported?(@digest, function, arity)
    end
  end

  test "projection comes from all 38 immutable wire schemas and rejects identifiers" do
    for schema <- LogicalSchemaV3.all() do
      assert {:ok, ^schema} = call(:projection, [schema.table])
    end

    for invalid <- ["content.notes; DROP SCHEMA content", "pg_temp.knowledge_restore_0", nil, %{}] do
      assert :error = call(:projection, [invalid])
    end
  end

  test "SQL scalar and recursive JSON encoding agrees with independent literal bytes" do
    with_destination(fn repo ->
      owner_transaction(repo, fn ->
        assert :ok = call(:install, [repo])

        for {tag, value_sql, expected_hex} <- @vectors do
          assert {:ok, expression} = call(:value_encoding_sql, [tag])

          result =
            SafeSQL.query!(
              repo,
              "SELECT encode(" <>
                expression <>
                ",'hex') FROM (SELECT " <> value_sql <> " AS value) AS literal_fixture",
              []
            )

          assert result.rows == [[expected_hex]], "incorrect independent #{tag} vector"
        end

        assert :error = call(:value_encoding_sql, ["text); DROP TABLE content.resources"])
        assert :error = call(:value_encoding_sql, [nil])
      end)
    end)
  end

  test "empty and two-row digest bytes are independently frozen and sorted by primary key" do
    assert {:ok, schema} = call(:projection, ["identity.people"])

    assert Enum.map(schema.columns, & &1.name) ==
             ~w(id display_name metadata inserted_at updated_at)

    with_destination(fn repo ->
      owner_transaction(repo, fn ->
        SafeSQL.query!(
          repo,
          "CREATE TEMP TABLE knowledge_restore_0 (LIKE identity.people INCLUDING ALL) ON COMMIT DROP"
        )

        assert {:ok, %{count: 0, digest: empty}} =
                 call(:table_digest, [repo, "identity.people", :staged])

        assert Base.encode16(empty, case: :lower) == @empty_digest

        # Reverse insertion order cannot select the digest traversal order.
        SafeSQL.query!(repo, """
        INSERT INTO pg_temp.knowledge_restore_0(id,display_name,metadata,inserted_at,updated_at)
        VALUES ('00000000-0000-0000-0000-000000000002','','{"a":1}',
                  TIMESTAMPTZ '1970-01-01 00:00:00.000001+00',TIMESTAMPTZ '1969-12-31 23:59:59.999999+00'),
               ('00000000-0000-0000-0000-000000000001','界🙂','{}',
                  TIMESTAMPTZ '1970-01-01 00:00:00+00',TIMESTAMPTZ '1970-01-01 00:00:00.000001+00')
        """)

        assert {:ok, %{count: 2, digest: two}} =
                 call(:table_digest, [repo, "identity.people", :staged])

        assert Base.encode16(two, case: :lower) == @two_rows_digest
        refute Base.encode16(two, case: :lower) == @reversed_digest

        SafeSQL.query!(
          repo,
          "UPDATE pg_temp.knowledge_restore_0 SET display_name='X' WHERE id='00000000-0000-0000-0000-000000000002'"
        )

        assert {:ok, %{count: 2, digest: changed}} =
                 call(:table_digest, [repo, "identity.people", :staged])

        refute changed == two
        assert SafeSQL.query!(repo, "SELECT count(*) FROM identity.people").rows == [[0]]
      end)
    end)
  end

  test "canonical and staged rows share exact projection without writing the canonical graph" do
    KnowledgeBackupFixtures.with_destination(:current, fn destination ->
      fixture = fixture(destination)
      before = KnowledgeBackupFixtures.canonical_rows(fixture)

      owner_transaction(destination.repo, fn ->
        SafeSQL.query!(destination.repo, """
        CREATE TEMP TABLE knowledge_restore_0 ON COMMIT DROP AS
        SELECT id,display_name,metadata,inserted_at,updated_at FROM identity.people
        """)

        assert {:ok, canonical} =
                 call(:table_digest, [destination.repo, "identity.people", :canonical])

        assert {:ok, ^canonical} =
                 call(:table_digest, [destination.repo, "identity.people", :staged])

        SafeSQL.query!(
          destination.repo,
          "UPDATE pg_temp.knowledge_restore_0 SET display_name='different same-count bytes'"
        )

        assert {:ok, staged} =
                 call(:table_digest, [destination.repo, "identity.people", :staged])

        assert staged.count == canonical.count
        refute staged.digest == canonical.digest
      end)

      assert KnowledgeBackupFixtures.canonical_rows(fixture) == before
    end)
  end

  test "canonical JSON numbers do not round at Decimal precision or truncate digits" do
    with_destination(fn repo ->
      owner_transaction(repo, fn ->
        SafeSQL.query!(repo, """
        CREATE TEMP TABLE knowledge_restore_3 ON COMMIT DROP AS
        SELECT id,account_id,kind,authorization_epoch,revoked_at,metadata,inserted_at,updated_at
        FROM identity.principals WITH NO DATA
        """)

        SafeSQL.query!(repo, """
        INSERT INTO pg_temp.knowledge_restore_3 VALUES
          ('00000000-0000-0000-0000-000000000001',
           '00000000-0000-0000-0000-000000000002','owner',1,NULL,
           '{"n":12345678901234567890123456789012345678901234567890.1200}',
           TIMESTAMPTZ '1970-01-01 00:00:00+00',TIMESTAMPTZ '1970-01-01 00:00:00+00')
        """)

        assert {:ok, original} = call(:table_digest, [repo, "identity.principals", :staged])

        SafeSQL.query!(repo, """
        UPDATE pg_temp.knowledge_restore_3
        SET metadata='{"n":12345678901234567890123456789012345678901234567890.12}'
        """)

        assert {:ok, ^original} = call(:table_digest, [repo, "identity.principals", :staged])

        SafeSQL.query!(repo, """
        UPDATE pg_temp.knowledge_restore_3
        SET metadata='{"n":12345678901234567890123456789012345678901234567890.13}'
        """)

        assert {:ok, changed} = call(:table_digest, [repo, "identity.principals", :staged])
        assert changed.count == original.count
        refute changed.digest == original.digest
      end)
    end)
  end

  test "a legal wire row keeps its independent digest when typed JSON framing exceeds the wire limit" do
    with_destination(fn repo ->
      metadata = %{
        "bulk" => String.duplicate("x", 16_777_216 - 10_000),
        "numbers" => List.duplicate(1, 1000)
      }

      id = "00000000-0000-4000-8000-000000000001"

      assert {:ok, record} =
               LogicalRecordCodec.encode_row(
                 "identity.people",
                 [{"uuid", id}],
                 [
                   {"uuid", id},
                   {"text", ""},
                   {"json", metadata},
                   {"timestamp", "1970-01-01T00:00:00.000000Z"},
                   {"timestamp", "1970-01-01T00:00:00.000001Z"}
                 ],
                 3
               )

      assert byte_size(record.payload) <= 16_777_216
      # Separately framed literal JSON/row lengths: 16,785,286/16,785,376.
      # The expected SHA was calculated before this test, without production SQL.

      owner_transaction(repo, fn ->
        SafeSQL.query!(repo, """
        CREATE TEMP TABLE knowledge_restore_0 ON COMMIT DROP AS
        SELECT id,display_name,metadata,inserted_at,updated_at
        FROM identity.people WITH NO DATA
        """)

        SafeSQL.query!(
          repo,
          """
          INSERT INTO pg_temp.knowledge_restore_0 VALUES
            ($1,'',($2::text)::jsonb,
             TIMESTAMPTZ '1970-01-01 00:00:00+00',
             TIMESTAMPTZ '1970-01-01 00:00:00.000001+00')
          """,
          [Ecto.UUID.dump!(id), Jason.encode!(metadata)]
        )

        assert [["object"]] =
                 SafeSQL.query!(
                   repo,
                   "SELECT jsonb_typeof(metadata) FROM pg_temp.knowledge_restore_0"
                 ).rows

        assert :ok = call(:install, [repo])
        assert {:ok, json_cell} = call(:value_encoding_sql, ["json"])

        assert [[16_785_296]] =
                 SafeSQL.query!(
                   repo,
                   "SELECT pg_catalog.octet_length(#{json_cell}) " <>
                     "FROM (SELECT metadata AS value FROM pg_temp.knowledge_restore_0) AS source"
                 ).rows

        assert {:ok, %{count: 1, digest: digest}} =
                 call(:table_digest, [repo, "identity.people", :staged])

        assert Base.encode16(digest, case: :lower) ==
                 "c714e3d40d807916e9a7d462deb3d3b382aeabf3c204e8e5ea77cbf5a4a5b161"

        assert SafeSQL.query!(repo, "SELECT count(*) FROM identity.people").rows == [[0]]
      end)
    end)
  end

  test "the fixed typed SQL query transports bounded chunks in native primary-key order" do
    with_destination(fn repo ->
      owner_transaction(repo, fn ->
        SafeSQL.query!(repo, """
        CREATE TEMP TABLE knowledge_restore_0 ON COMMIT DROP AS
        SELECT id,display_name,metadata,inserted_at,updated_at
        FROM identity.people WITH NO DATA
        """)

        SafeSQL.query!(repo, """
        INSERT INTO pg_temp.knowledge_restore_0 VALUES
          ('00000000-0000-4000-8000-000000000002',repeat('界',65536),'{}',
           TIMESTAMPTZ '1970-01-01 00:00:00+00',TIMESTAMPTZ '1970-01-01 00:00:00.000001+00'),
          ('00000000-0000-4000-8000-000000000001','','{}',
           TIMESTAMPTZ '1970-01-01 00:00:00+00',TIMESTAMPTZ '1970-01-01 00:00:00.000001+00')
        """)

        assert :ok = call(:install, [repo])
        assert {:ok, query} = call(:row_chunks_sql, ["identity.people", :staged])

        metrics =
          repo
          |> SafeSQL.stream(query, [], max_rows: 1)
          |> Enum.flat_map(fn %{rows: rows} ->
            assert length(rows) <= 1

            Enum.map(rows, fn [row_length, offset, chunk] ->
              assert byte_size(chunk) in 1..65_536
              {row_length, offset, byte_size(chunk)}
            end)
          end)

        assert metrics == [
                 {99, 0, 99},
                 {196_707, 0, 65_536},
                 {196_707, 65_536, 65_536},
                 {196_707, 131_072, 65_536},
                 {196_707, 196_608, 99}
               ]

        assert {:ok, canonical_query} = call(:row_chunks_sql, ["identity.people", :canonical])

        assert Enum.flat_map(SafeSQL.stream(repo, canonical_query, [], max_rows: 1), & &1.rows) ==
                 []

        for {table, selector} <- [
              {"identity.people; DROP SCHEMA identity", :staged},
              {"identity.people", "pg_temp.anything"},
              {"identity.people", :unknown}
            ] do
          assert :error = call(:row_chunks_sql, [table, selector])
        end

        assert SafeSQL.query!(repo, "SELECT count(*) FROM identity.people").rows == [[0]]
      end)
    end)
  end

  test "nontransaction and arbitrary table or selector calls fail closed without SQL changes" do
    with_destination(fn repo ->
      assert {:error, %Error{code: :backup_invalid}} =
               call(:table_digest, [repo, "identity.people", :canonical])

      assert {:error, %Error{code: :backup_invalid}} = call(:install, [repo])

      owner_transaction(repo, fn ->
        for {table, selector} <- [
              {"identity.people; DROP SCHEMA identity", :canonical},
              {"identity.people", "pg_temp.anything"},
              {"identity.people", :unknown}
            ] do
          assert {:error, %Error{code: :backup_invalid}} =
                   call(:table_digest, [repo, table, selector])
        end

        assert SafeSQL.query!(repo, "SELECT count(*) FROM identity.people").rows == [[0]]
      end)
    end)
  end

  defp call(function, args), do: apply(@digest, function, args)

  defp with_destination(callback) do
    KnowledgeBackupFixtures.with_destination(:current, fn %{repo: repo} ->
      callback.(repo)
    end)
  end

  defp owner_transaction(repo, callback) do
    assert {:ok, :verified} =
             repo.transaction(fn ->
               SafeSQL.query!(repo, "SET LOCAL ROLE singularity_table_owner")
               callback.()
               :verified
             end)
  end

  defp fixture(destination) do
    ids =
      ~w(account_id principal_id vault_id session_id live_note_id deleted_note_id
         initial_note_version_id canonical_note_version_id competing_note_version_id
         merge_note_version_id open_competing_note_version_id deleted_note_version_id
         resolved_conflict_id open_conflict_id ready_document_id ready_old_version_id
         ready_current_version_id deleted_document_id deleted_document_version_id
         pending_document_id pending_version_id extracting_document_id extracting_version_id
         failed_document_id failed_version_id unsupported_document_id unsupported_version_id
         attachment_id citation_id deleted_attachment_id deleted_citation_id tag_id
         relationship_id pdf_object_id empty_object_id plain_object_id unicode_object_id
         markdown_object_id)a
      |> Enum.with_index(1)
      |> Map.new(fn {name, index} ->
        {name,
         "50000000-0000-4000-8000-" <>
           String.pad_leading(Integer.to_string(index), 12, "0")}
      end)

    originals = %{
      pdf: "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n",
      pdf_duplicate: "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n",
      empty: "",
      plain: "plain original\r\nsecond line\n",
      unicode: "界🙂 café\n",
      markdown: "# Original Markdown\n\n[source](https://example.test/)\n"
    }

    KnowledgeBackupFixtures.seed!(Map.merge(destination, %{ids: ids, originals: originals}))
  end
end
