defmodule Singularity.Storage.Backup.KnowledgeRestoreAdmissionTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Storage.{MigrationRepo, LocalFilesystemAdapter}

  alias Singularity.Storage.Backup.{
    BundleReader,
    KnowledgeBackupFixtures,
    KnowledgePreflight,
    KnowledgeRestoreDigest,
    LocalDestination,
    LogicalBundleVerifier,
    LogicalRecordCodec,
    LogicalSchemaV3
  }

  alias Singularity.Storage.Backup.KnowledgeBackupFixtures.FixtureCrypto
  alias Singularity.Storage.Crypto.Format

  @ids ~w(
    account_id principal_id vault_id session_id live_note_id deleted_note_id
    initial_note_version_id canonical_note_version_id competing_note_version_id
    merge_note_version_id open_competing_note_version_id deleted_note_version_id
    resolved_conflict_id open_conflict_id ready_document_id ready_old_version_id
    ready_current_version_id deleted_document_id deleted_document_version_id
    pending_document_id pending_version_id extracting_document_id extracting_version_id
    failed_document_id failed_version_id unsupported_document_id unsupported_version_id
    attachment_id citation_id deleted_attachment_id deleted_citation_id tag_id
    relationship_id pdf_object_id empty_object_id plain_object_id unicode_object_id
    markdown_object_id
  )a
       |> Enum.with_index(1)
       |> Map.new(fn {name, n} ->
         {name, "50000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")}
       end)
  @originals %{
    pdf: "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n",
    pdf_duplicate: "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n",
    empty: "",
    plain: "plain original\r\nsecond line\n",
    unicode: "界🙂 café\n",
    markdown: "# Original Markdown\n\n[source](https://example.test/)\n"
  }
  # Independent fixture cardinalities in frozen ordinal order, not a destination oracle.
  @counts [
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    0,
    1,
    1,
    1,
    1,
    1,
    3,
    3,
    1,
    1,
    1,
    0,
    1,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
    1,
    0,
    1,
    1,
    0,
    1,
    1,
    1
  ]
  @lock "singularity:restore-import:v1"
  @unknown "60000000-0000-4000-8000-000000999999"
  @excluded ~w(identity.sessions identity.auth_attempts content.asset_stages
    content.upload_grants content.asset_search_documents content.note_search_documents
    content.search_entries content.note_mutation_receipts audit.backup_manifests
    audit.backup_manifest_objects jobs.oban_jobs jobs.oban_peers)
  # Fixed ordinary constraints only. Never drain knowledge_restore_final_check.
  @ordinary_constraints ~w(
    content.resource_versions_resource_classification_fkey
    content.resources_version_head_fkey content.resources_00_typed_head_check
    content.note_versions_00_typed_head_check content.document_versions_00_typed_head_check
    content.note_versions_aggregate_check content.note_attachments_note_fkey
    content.note_attachments_target_fkey content.note_attachments_source_set_check
    content.note_versions_source_set_seal_check content.note_attachments_source_set_seal_check
    content.note_source_set_seals_note_fkey content.document_import_receipts_version_fkey
    content.document_import_receipts_completed_check
  )
  @signatures [
    "audit.begin_knowledge_restore(uuid,uuid,bytea,bigint[],bytea[])",
    "audit.validate_knowledge_restore(uuid,uuid,bytea)",
    "audit.knowledge_restore_is_bound(uuid)",
    "audit.enforce_knowledge_restore_final()",
    "audit.knowledge_restore_json_bytes(jsonb)",
    "audit.knowledge_restore_table_digest(integer)",
    "audit.assert_knowledge_restore_graph(uuid)"
  ]
  @empty_digest "06748816d518ce749f176bd61301a931a9c741074d0616d7fa1043600e3f1952"
  @two_digest "68b2f172d46d7d4779db36c530447183c1715be2fb2afb94743c344721c985a2"
  @reverse_digest "82b6573b5da1aeeb046881275050f1503b8ab2c84a50c2ae36ec8ef7a5457ddb"
  @json_vectors [
    {"NULL::jsonb", nil},
    {"'null'::jsonb", "00"},
    {"'false'::jsonb", "01"},
    {"'true'::jsonb", "02"},
    {"'1'::jsonb", "03000000000000000131"},
    {"'1.0'::jsonb", "03000000000000000131"},
    {"'1e0'::jsonb", "03000000000000000131"},
    {"'-0.00'::jsonb", "03000000000000000130"},
    {"'\"界\\n\\\"\"'::jsonb", "040000000000000005e7958c0a22"},
    {"'[]'::jsonb", "050000000000000000"},
    {"'{}'::jsonb", "060000000000000000"},
    {"'{\"界\":2,\"z\":[null,true,{\"a\":\"é\"}],\"é\":1.00}'::jsonb",
     "06000000000000000300000000000000017a00000000000000480500000000000000030000000000000001000000000000000001020000000000000025060000000000000001000000000000000161000000000000000b040000000000000002c3a90000000000000002c3a9000000000000000a030000000000000001310000000000000003e7958c000000000000000a03000000000000000132"},
    {"'12345678901234567890123456789012345678901234567890.1200'::jsonb",
     "03000000000000003531323334353637383930313233343536373839303132333435363738393031323334353637383930313233343536373839302e3132"},
    {"'1.25e-7'::jsonb", "03000000000000000b302e303030303030313235"}
  ]

  setup_all do
    portable = Path.join(System.tmp_dir!(), "knowledge-admission-#{Ecto.UUID.generate()}")
    File.mkdir_p!(portable)
    File.chmod!(portable, 0o700)
    on_exit(fn -> File.rm_rf!(portable) end)
    # These environments are sequential: the helper owns global repo configuration.
    %{locked: prepare_source(portable, true), unlocked: prepare_source(portable, false)}
  end

  @tag :fixture_characterization
  test "genuine reduced source is thirty live-compatible rows and commits through normal guards",
       ctx do
    for source <- [ctx.locked, ctx.unlocked] do
      assert ordered_counts(source.raw_summary) == @counts
      assert Enum.sum(@counts) == 30
      assert source.raw_summary.counts == source.expected.counts

      with_destination(source, fn destination, _bundle, _storage ->
        assert {:ok, :committed} =
                 owner_transaction(fn ->
                   insert_graph(source.rows)
                   force_ordinary_constraints()
                   assert canonical_summary() == source.expected
                   assert_seal()
                   :committed
                 end)

        owner_transaction(fn ->
          assert canonical_summary() == source.expected
          assert_empty_exclusions()
          assert_seal()
        end)

        assert destination.database != source.database
      end)
    end
  end

  test "admission relation and private pinned helpers have the exact maintenance-only shape",
       ctx do
    with_destination(ctx.locked, fn _destination, _bundle, _storage ->
      owner_transaction(fn ->
        require_contract()

        assert [["singularity_table_owner", true, true]] ==
                 sql("""
                 SELECT pg_get_userbyid(c.relowner),c.relrowsecurity,c.relforcerowsecurity
                 FROM pg_class c WHERE c.oid='audit.knowledge_restore_admissions'::regclass
                 """).rows

        types =
          sql("""
          SELECT a.attname,t.typname FROM pg_attribute a JOIN pg_type t ON t.oid=a.atttypid
          WHERE a.attrelid='audit.knowledge_restore_admissions'::regclass
            AND a.attnum>0 AND NOT a.attisdropped ORDER BY a.attnum
          """).rows
          |> Map.new(fn [name, type] -> {name, type} end)

        assert types == %{
                 "singleton" => "bool",
                 "manifest_id" => "uuid",
                 "vault_id" => "uuid",
                 "manifest_hash" => "bytea",
                 "transaction_id" => "xid8",
                 "backend_pid" => "int4",
                 "expected_counts" => "_int8",
                 "expected_digests" => "_bytea",
                 "state" => "text",
                 "manifest_tag" => "bytea",
                 "inventory_hash" => "bytea",
                 "destination_root_hash" => "bytea",
                 "object_count" => "int8"
               }

        for signature <- @signatures do
          assert [["singularity_table_owner", ["search_path=pg_catalog"]]] ==
                   sql(
                     """
                     SELECT pg_get_userbyid(proowner),proconfig FROM pg_proc WHERE oid=to_regprocedure($1)
                     """,
                     [signature]
                   ).rows

          assert [[false]] ==
                   sql(
                     """
                     SELECT EXISTS(SELECT 1 FROM pg_proc p,
                       LATERAL aclexplode(COALESCE(p.proacl,acldefault('f',p.proowner))) a
                       WHERE p.oid=to_regprocedure($1) AND a.grantee=0 AND a.privilege_type='EXECUTE')
                     """,
                     [signature]
                   ).rows

          for role <- runtime_roles() do
            assert [[false]] ==
                     sql("SELECT has_function_privilege($1,to_regprocedure($2),'EXECUTE')", [
                       role,
                       signature
                     ]).rows
          end
        end

        assert [[false]] ==
                 sql("""
                 SELECT EXISTS(SELECT 1 FROM pg_class c,
                   LATERAL aclexplode(COALESCE(c.relacl,acldefault('r',c.relowner))) a
                   WHERE c.oid='audit.knowledge_restore_admissions'::regclass AND a.grantee=0)
                 """).rows

        for role <- runtime_roles(),
            privilege <- ~w(SELECT INSERT UPDATE DELETE TRUNCATE REFERENCES TRIGGER) do
          assert [[false]] ==
                   sql("SELECT has_table_privilege($1,'audit.knowledge_restore_admissions',$2)", [
                     role,
                     privilege
                   ]).rows
        end

        assert [[true, true]] ==
                 sql("""
                 SELECT tgdeferrable,tginitdeferred FROM pg_trigger
                 WHERE tgrelid='audit.knowledge_restore_admissions'::regclass
                   AND tgname='knowledge_restore_final_check' AND NOT tgisinternal
                 """).rows

        assert "audit.knowledge_restore_admissions" not in LogicalSchemaV3.tables()
      end)
    end)
  end

  test "direct SQL accepts all thirty rows, independently matches all thirty-eight digests and commits pending or imported",
       ctx do
    for final_state <- [:pending, :imported] do
      with_destination(ctx.locked, fn _destination, bundle, storage ->
        assert {:ok, :committed} =
                 owner_transaction(fn ->
                   require_contract()
                   lock_restore()
                   marker(bundle, storage)
                   begin_sql(ctx.locked.expected, bundle)
                   assert_bound(true)
                   assert_admission(ctx.locked.expected, bundle, storage, "loading")
                   insert_graph(ctx.locked.rows)
                   assert_owned_summary(ctx.locked.expected)
                   sql("SELECT audit.assert_knowledge_restore_graph($1)", [dump(@ids.vault_id)])
                   validate_sql(bundle)
                   assert_bound(false)
                   assert_admission(ctx.locked.expected, bundle, storage, "validated")
                   force_ordinary_constraints()
                   if final_state == :imported, do: mark_imported()
                   :committed
                 end)

        owner_transaction(fn ->
          assert_owned_summary(ctx.locked.expected)
          assert_seal()
          assert_empty_exclusions()
        end)
      end)
    end
  end

  test "internal adapter uses only authentic bound staging, preserving raw unlocked evidence",
       ctx do
    for source <- [ctx.locked, ctx.unlocked] do
      with_destination(source, fn _destination, bundle, storage ->
        assert {:ok, :committed} =
                 owner_transaction(fn ->
                   require_contract()
                   require_adapter()
                   lock_restore()
                   marker(bundle, storage)

                   assert {:ok, staged} =
                            KnowledgePreflight.stage(
                              MigrationRepo,
                              bundle.verified,
                              bundle.cut,
                              storage
                            )

                   assert {:ok, raw} =
                            KnowledgePreflight.validate(MigrationRepo, staged, bundle.cut)

                   assert raw == source.raw_summary
                   assert staged.summary == source.raw_summary

                   assert [[source.locked]] ==
                            sql("SELECT locked FROM pg_temp.knowledge_restore_5").rows

                   assert {:ok, expected} =
                            apply(KnowledgePreflight, :begin_restore, [MigrationRepo, staged])

                   assert expected == source.expected
                   assert staged.summary == source.raw_summary

                   assert [[source.locked]] ==
                            sql("SELECT locked FROM pg_temp.knowledge_restore_5").rows

                   insert_graph(source.rows)
                   assert [[true]] == sql("SELECT locked FROM core.vaults").rows
                   assert_owned_summary(source.expected)
                   poison_temp_encoder()

                   assert :ok =
                            apply(KnowledgePreflight, :validate_destination, [
                              MigrationRepo,
                              staged
                            ])

                   assert [[true]] ==
                            sql("""
                            SELECT strpos(prosrc,'untrusted temporary restore encoder')>0 FROM pg_proc
                            WHERE oid=to_regprocedure('pg_temp.knowledge_restore_json(jsonb)')
                            """).rows

                   force_ordinary_constraints()
                   :committed
                 end)

        if not source.locked do
          for schema <- LogicalSchemaV3.all(), schema.ordinal != 5 do
            assert source.raw_summary.digests[schema.table] ==
                     source.expected.digests[schema.table]
          end

          refute source.raw_summary.digests["core.vaults"] ==
                   source.expected.digests["core.vaults"]
        end
      end)
    end
  end

  test "loading without explicit validation fails at actual COMMIT and leaves no visible rows",
       ctx do
    with_destination(ctx.locked, fn _destination, bundle, storage ->
      require_owner_contract()

      commit_rejected(fn ->
        lock_restore()
        marker(bundle, storage)
        begin_sql(ctx.locked.expected, bundle)
        insert_graph(ctx.locked.rows)
        force_ordinary_constraints()
      end)

      assert_no_import()
    end)
  end

  test "adapter admission compares authenticated full marker rather than a caller-detached summary",
       ctx do
    for {column, value} <- [
          {"manifest_hash", <<0::256>>},
          {"manifest_tag", <<0::128>>},
          {"inventory_hash", <<0::256>>},
          {"destination_root_hash", <<0::256>>},
          {"object_count", 2}
        ] do
      with_destination(ctx.locked, fn _destination, bundle, storage ->
        require_owner_contract()
        require_adapter()

        assert {:error, :rejected} =
                 owner_transaction(fn ->
                   lock_restore()
                   marker(bundle, storage)

                   assert {:ok, staged} =
                            KnowledgePreflight.stage(
                              MigrationRepo,
                              bundle.verified,
                              bundle.cut,
                              storage
                            )

                   assert {:ok, raw} =
                            KnowledgePreflight.validate(MigrationRepo, staged, bundle.cut)

                   assert raw == ctx.locked.raw_summary
                   sql("UPDATE audit.restore_import_sagas SET #{column}=$1", [value])

                   assert_invalid(
                     apply(KnowledgePreflight, :begin_restore, [MigrationRepo, staged])
                   )

                   assert [[0]] ==
                            sql("SELECT count(*) FROM audit.knowledge_restore_admissions").rows

                   for schema <- LogicalSchemaV3.all(),
                       do: assert([[0]] == sql("SELECT count(*) FROM #{schema.table}").rows)

                   MigrationRepo.rollback(:rejected)
                 end)

        assert_no_import()
      end)
    end
  end

  test "equal-count valid Tag mutation after validation and ordinary forcing fails only at actual COMMIT",
       ctx do
    with_destination(ctx.locked, fn _destination, bundle, storage ->
      require_owner_contract()

      commit_rejected(fn ->
        lock_restore()
        marker(bundle, storage)
        begin_sql(ctx.locked.expected, bundle)
        insert_graph(ctx.locked.rows)
        validate_sql(bundle)
        force_ordinary_constraints()
        # This is an otherwise legal, same-count Tag pair. There is deliberately
        # no second validate call and no SET CONSTRAINTS ALL IMMEDIATE.
        sql(
          "UPDATE content.tags SET display_value='Changed',normalized_key='changed' WHERE id=$1",
          [dump(@ids.tag_id)]
        )

        assert [[1]] == sql("SELECT count(*) FROM content.tags").rows

        assert [["Changed", "changed"]] ==
                 sql("SELECT display_value,normalized_key FROM content.tags").rows
      end)

      assert_no_import()
    end)
  end

  test "direct entry requires the exact current backend exclusive bigint lock", ctx do
    with_destination(ctx.locked, fn _destination, bundle, storage ->
      require_owner_contract()

      for lock <- [:absent, :wrong, :shared, :two_integer] do
        reject_transaction(fn ->
          marker(bundle, storage)

          case lock do
            :absent ->
              :ok

            :wrong ->
              sql("SELECT pg_advisory_xact_lock(hashtextextended('not-the-restore-lock',0))")

            :shared ->
              sql("SELECT pg_advisory_xact_lock_shared(hashtextextended($1::text,0))", [@lock])

            :two_integer ->
              sql(
                "SELECT pg_advisory_xact_lock((hashtextextended($1::text,0)>>32)::integer,hashtextextended($1::text,0)::bit(32)::integer)",
                [@lock]
              )
          end

          begin_sql(ctx.locked.expected, bundle)
        end)
      end

      with_migration_connection(fn connection ->
        Postgrex.query!(connection, "SELECT pg_advisory_lock(hashtextextended($1::text,0))", [
          @lock
        ])

        try do
          reject_transaction(fn ->
            marker(bundle, storage)
            begin_sql(ctx.locked.expected, bundle)
          end)
        after
          Postgrex.query!(connection, "SELECT pg_advisory_unlock(hashtextextended($1::text,0))", [
            @lock
          ])
        end
      end)

      assert_no_import()
    end)
  end

  test "wrong saga identity or caller binding never opens admission", ctx do
    with_destination(ctx.locked, fn _destination, bundle, storage ->
      require_owner_contract()

      for change <- [:missing, :owner, :manifest, :hash, :state] do
        reject_transaction(fn ->
          lock_restore()
          if change != :missing, do: marker(bundle, storage)

          case change do
            :owner ->
              sql("UPDATE audit.restore_import_sagas SET vault_id=$1", [dump(@unknown)])

            :manifest ->
              sql("UPDATE audit.restore_import_sagas SET manifest_id=$1", [dump(@unknown)])

            :hash ->
              sql("UPDATE audit.restore_import_sagas SET manifest_hash=$1", [<<0::256>>])

            :state ->
              mark_imported()

            :missing ->
              :ok
          end

          begin_sql(ctx.locked.expected, bundle)
        end)
      end

      for field <- [:vault_id, :manifest_id, :manifest_hash] do
        reject_transaction(fn ->
          lock_restore()
          marker(bundle, storage)
          params = begin_parameters(ctx.locked.expected, bundle)
          index = %{manifest_id: 0, vault_id: 1, manifest_hash: 2}[field]
          replacement = if field == :manifest_hash, do: <<0::256>>, else: dump(@unknown)
          sql(begin_statement(), List.replace_at(params, index, replacement))
        end)
      end

      assert_no_import()
    end)
  end

  test "array shape, lower bound, NULL cells and digest lengths are closed", ctx do
    with_destination(ctx.locked, fn _destination, bundle, storage ->
      require_owner_contract()

      vectors = [
        {"$4", "$5", Enum.drop(@counts, 1), ordered_digests(ctx.locked.expected)},
        {"$4", "$5", @counts ++ [0], ordered_digests(ctx.locked.expected)},
        {"$4", "$5", List.replace_at(@counts, 0, -1), ordered_digests(ctx.locked.expected)},
        {"$4", "$5", List.replace_at(@counts, 0, nil), ordered_digests(ctx.locked.expected)},
        {"$4", "$5", @counts, List.replace_at(ordered_digests(ctx.locked.expected), 0, nil)},
        {"$4", "$5", @counts, List.replace_at(ordered_digests(ctx.locked.expected), 0, <<1>>)},
        {"$4", "$5", @counts, Enum.drop(ordered_digests(ctx.locked.expected), 1)},
        {"ARRAY[$4::bigint[]]", "$5", @counts, ordered_digests(ctx.locked.expected)},
        {"array_fill(0::bigint,ARRAY[38],ARRAY[0])", "$5", @counts,
         ordered_digests(ctx.locked.expected)},
        {"NULL::bigint[]", "$5", @counts, ordered_digests(ctx.locked.expected)},
        {"$4", "NULL::bytea[]", @counts, ordered_digests(ctx.locked.expected)}
      ]

      for {counts_expr, digest_expr, counts, digests} <- vectors do
        reject_transaction(fn ->
          lock_restore()
          marker(bundle, storage)
          # All parameters remain typed even when the chosen expression does not use them.
          sql(
            "SELECT audit.begin_knowledge_restore($1,$2,$3,#{counts_expr}::bigint[],#{digest_expr}::bytea[]) FROM (SELECT $4::bigint[],$5::bytea[]) AS typed",
            Enum.take(begin_parameters(ctx.locked.expected, bundle), 3) ++ [counts, digests]
          )
        end)
      end

      assert_no_import()
    end)
  end

  test "nonempty canonical, excluded and derived destinations deny admission", ctx do
    with_destination(ctx.locked, fn _destination, bundle, storage ->
      require_owner_contract()

      for kind <- [:canonical, :excluded, :seal] do
        reject_transaction(fn ->
          lock_restore()
          marker(bundle, storage)

          case kind do
            :canonical ->
              sql("INSERT INTO identity.people(id,display_name) VALUES($1,'occupied')", [
                dump(@unknown)
              ])

            :excluded ->
              sql(
                """
                INSERT INTO identity.auth_attempts(id,login_fingerprint,source_fingerprint,result,correlation_id)
                VALUES($1,$2,$2,'started',$1)
                """,
                [dump(@unknown), <<0::256>>]
              )

            :seal ->
              sql(
                """
                INSERT INTO content.note_source_set_seals(note_resource_version_id,note_resource_id,vault_id,classification,attachment_count,citation_count)
                VALUES($1,$2,$3,'private',0,0)
                """,
                [dump(@ids.initial_note_version_id), dump(@ids.live_note_id), dump(@ids.vault_id)]
              )
          end

          begin_sql(ctx.locked.expected, bundle)
        end)
      end

      assert_no_import()
    end)
  end

  test "full pending marker is immutable across validation and final COMMIT", ctx do
    with_destination(ctx.locked, fn _destination, bundle, storage ->
      require_owner_contract()

      mutations = [
        {"manifest_tag", <<0::128>>},
        {"inventory_hash", <<0::256>>},
        {"destination_root_hash", <<0::256>>},
        {"object_count", 2}
      ]

      for {column, value} <- mutations do
        reject_transaction(fn ->
          lock_restore()
          marker(bundle, storage)
          begin_sql(ctx.locked.expected, bundle)
          insert_graph(ctx.locked.rows)
          sql("UPDATE audit.restore_import_sagas SET #{column}=$1", [value])
          validate_sql(bundle)
        end)

        commit_rejected(fn ->
          lock_restore()
          marker(bundle, storage)
          begin_sql(ctx.locked.expected, bundle)
          insert_graph(ctx.locked.rows)
          validate_sql(bundle)
          force_ordinary_constraints()
          sql("UPDATE audit.restore_import_sagas SET #{column}=$1", [value])
        end)
      end

      commit_rejected(fn ->
        lock_restore()
        marker(bundle, storage)
        begin_sql(ctx.locked.expected, bundle)
        insert_graph(ctx.locked.rows)
        validate_sql(bundle)
        force_ordinary_constraints()

        sql(
          """
          UPDATE audit.restore_import_sagas SET state='rewrapped',imported_at=CURRENT_TIMESTAMP,
            rewrapped_at=CURRENT_TIMESTAMP,integrity_principal_id=$1,wrapper_generation=1
          """,
          [dump(@ids.principal_id)]
        )
      end)

      assert_no_import()
    end)
  end

  test "binding and expectation columns cannot be rewritten by their table owner", ctx do
    with_destination(ctx.locked, fn _destination, bundle, storage ->
      require_owner_contract()

      for {column, expression} <- [
            {"manifest_id", "'#{@unknown}'::uuid"},
            {"vault_id", "'#{@unknown}'::uuid"},
            {"manifest_hash", "decode(repeat('00',32),'hex')"},
            {"manifest_tag", "decode(repeat('00',16),'hex')"},
            {"inventory_hash", "decode(repeat('00',32),'hex')"},
            {"destination_root_hash", "decode(repeat('00',32),'hex')"},
            {"object_count", "object_count+1"},
            {"backend_pid", "backend_pid+1"},
            {"transaction_id", "'1'::xid8"},
            {"expected_counts", "array_fill(0::bigint,ARRAY[38])"},
            {"expected_digests", "array_fill(decode(repeat('00',32),'hex'),ARRAY[38])"}
          ] do
        reject_transaction(fn ->
          lock_restore()
          marker(bundle, storage)
          begin_sql(ctx.locked.expected, bundle)
          sql("UPDATE audit.knowledge_restore_admissions SET #{column}=#{expression}")
        end)
      end

      commit_rejected(
        fn ->
          lock_restore()
          marker(bundle, storage)
          begin_sql(ctx.locked.expected, bundle)
          # A caller-selected flag is not validation of the missing graph.
          sql("UPDATE audit.knowledge_restore_admissions SET state='validated'")
        end,
        false
      )

      assert_no_import()
    end)
  end

  test "counts alone, missing seals and an inactive source owner cannot validate", ctx do
    with_destination(ctx.locked, fn _destination, bundle, storage ->
      require_owner_contract()

      for fault <- [:digest, :count, :missing_seal] do
        reject_transaction(fn ->
          lock_restore()
          marker(bundle, storage)

          expected =
            case fault do
              :digest -> put_in(ctx.locked.expected, [:digests, "content.tags"], <<0::256>>)
              :count -> put_in(ctx.locked.expected, [:counts, "content.tags"], 2)
              :missing_seal -> ctx.locked.expected
            end

          begin_sql(expected, bundle)
          insert_graph(ctx.locked.rows, fault != :missing_seal)
          validate_sql(bundle)
        end)
      end

      # Exercise the independent graph seam itself, not a changed digest oracle.
      reject_transaction(fn ->
        insert_graph(ctx.locked.rows)
        sql("UPDATE core.vault_members SET revoked_at=CURRENT_TIMESTAMP")
        sql("SELECT audit.assert_knowledge_restore_graph($1)", [dump(@ids.vault_id)])
      end)

      reject_transaction(fn ->
        insert_graph(ctx.locked.rows, false)

        sql(
          """
          INSERT INTO content.note_source_set_seals(note_resource_version_id,note_resource_id,vault_id,classification,attachment_count,citation_count)
          VALUES($1,$2,$3,'private',0,0)
          """,
          [dump(@ids.initial_note_version_id), dump(@ids.live_note_id), dump(@ids.vault_id)]
        )

        sql("SELECT audit.assert_knowledge_restore_graph($1)", [dump(@ids.vault_id)])
      end)

      assert_no_import()
    end)
  end

  test "committed admission does not bind a later full transaction or another backend", ctx do
    with_destination(ctx.locked, fn _destination, bundle, storage ->
      require_owner_contract()

      MigrationRepo.checkout(fn ->
        assert {:ok, {saved_pid, saved_xid}} =
                 owner_transaction(fn ->
                   lock_restore()
                   marker(bundle, storage)
                   begin_sql(ctx.locked.expected, bundle)
                   insert_graph(ctx.locked.rows)
                   validate_sql(bundle)
                   [[pid, xid]] = sql("SELECT pg_backend_pid(),pg_current_xact_id()::text").rows
                   {pid, xid}
                 end)

        owner_transaction(fn ->
          [[pid, xid]] = sql("SELECT pg_backend_pid(),pg_current_xact_id()::text").rows
          assert pid == saved_pid
          refute xid == saved_xid
          assert_bound(false)
        end)

        reject_transaction(fn -> validate_sql(bundle) end)

        with_migration_connection(fn connection ->
          Postgrex.query!(connection, "BEGIN")
          Postgrex.query!(connection, "SET LOCAL ROLE singularity_table_owner")

          try do
            [[pid, xid]] =
              Postgrex.query!(connection, "SELECT pg_backend_pid(),pg_current_xact_id()::text").rows

            refute pid == saved_pid
            refute xid == saved_xid

            assert [[false]] ==
                     Postgrex.query!(connection, "SELECT audit.knowledge_restore_is_bound($1)", [
                       dump(@ids.vault_id)
                     ]).rows

            assert_raise Postgrex.Error, fn ->
              Postgrex.query!(
                connection,
                "SELECT audit.validate_knowledge_restore($1,$2,$3)",
                binding_parameters(bundle)
              )
            end
          after
            Postgrex.query!(connection, "ROLLBACK")
          end
        end)
      end)
    end)
  end

  test "omitted legacy credential and pending-wrapper values are checked separately from all thirty-eight digests",
       ctx do
    with_destination(ctx.locked, fn _destination, bundle, storage ->
      require_owner_contract()

      mutations = [
        "UPDATE identity.credentials SET verifier='not-the-destination-dummy-verifier'",
        "UPDATE identity.credentials SET verifier_version=2",
        "UPDATE identity.credentials SET updated_at=inserted_at+interval '1 microsecond'",
        "UPDATE core.vault_key_wrappers SET kdf_version=2",
        "UPDATE core.vault_key_wrappers SET kdf_salt=decode('01','hex')",
        "UPDATE core.vault_key_wrappers SET kdf_parameters='{\"state\":\"changed\",\"version\":1}'::jsonb",
        "UPDATE core.vault_key_wrappers SET wrapper_algorithm='changed'",
        "UPDATE core.vault_key_wrappers SET wrapped_key=decode('01','hex')"
      ]

      for mutation <- mutations do
        reject_transaction(fn ->
          lock_restore()
          marker(bundle, storage)
          begin_sql(ctx.locked.expected, bundle)
          insert_graph(ctx.locked.rows)
          sql(mutation)
          assert_owned_summary(ctx.locked.expected)
          validate_sql(bundle)
        end)
      end

      assert_no_import()
    end)
  end

  test "staged adapter handle cannot move to another process, backend, cut or completed transaction",
       ctx do
    for fault <- [:process, :cut, :outside, :new_transaction] do
      # A bad-cut validator owns cleanup. Never reuse its destroyed handle as
      # evidence for an independent process/transaction boundary.
      with_destination(ctx.locked, fn _destination, bundle, storage ->
        require_owner_contract()
        require_adapter()

        assert {:error, {:staged, staged}} =
                 owner_transaction(fn ->
                   assert {:ok, staged} =
                            KnowledgePreflight.stage(
                              MigrationRepo,
                              bundle.verified,
                              bundle.cut,
                              storage
                            )

                   assert staged.summary == ctx.locked.raw_summary

                   case fault do
                     :process ->
                       task =
                         Task.async(fn ->
                           apply(KnowledgePreflight, :begin_restore, [MigrationRepo, staged])
                         end)

                       assert_invalid(Task.await(task, 15_000))

                       assert {:ok, raw} =
                                KnowledgePreflight.validate(MigrationRepo, staged, bundle.cut)

                       assert raw == ctx.locked.raw_summary

                     :cut ->
                       assert_invalid(
                         KnowledgePreflight.validate(MigrationRepo, staged, %{
                           bundle.cut
                           | manifest_id: @unknown
                         })
                       )

                     _ ->
                       assert {:ok, raw} =
                                KnowledgePreflight.validate(MigrationRepo, staged, bundle.cut)

                       assert raw == ctx.locked.raw_summary
                   end

                   MigrationRepo.rollback({:staged, staged})
                 end)

        case fault do
          :outside ->
            assert_invalid(apply(KnowledgePreflight, :begin_restore, [MigrationRepo, staged]))

          :new_transaction ->
            owner_transaction(fn ->
              assert_invalid(apply(KnowledgePreflight, :begin_restore, [MigrationRepo, staged]))

              assert_invalid(
                apply(KnowledgePreflight, :validate_destination, [MigrationRepo, staged])
              )
            end)

          _ ->
            :ok
        end

        assert_no_import()
      end)
    end
  end

  test "actual runtime sessions, GUC spoofing and table-owner SECURITY DEFINER nesting cannot admit",
       ctx do
    with_destination(ctx.locked, fn _destination, bundle, _storage ->
      require_owner_contract()

      schema_snapshot = fn ->
        {
          sql("SELECT nspacl::text FROM pg_namespace WHERE nspname='audit'").rows,
          sql(
            "SELECT role,has_schema_privilege(role,'audit','USAGE') FROM unnest($1::text[]) AS role ORDER BY role",
            [runtime_roles()]
          ).rows
        }
      end

      {:ok, {helper_oids, baseline_schema}} =
        owner_transaction(fn ->
          assert [[true]] ==
                   sql(
                     "SELECT to_regprocedure('audit.test_nested_knowledge_restore(uuid,uuid,bytea,bigint[],bytea[])') IS NULL"
                   ).rows

          helper_oids =
            for signature <- @signatures do
              assert [[oid]] = sql("SELECT to_regprocedure($1)::oid", [signature]).rows
              assert is_integer(oid) and oid > 0
              oid
            end

          {helper_oids, schema_snapshot.()}
        end)

      {_baseline_acl, baseline_usage} = baseline_schema
      baseline_usage_by_role = Map.new(baseline_usage, fn [role, usage] -> {role, usage} end)

      assert baseline_usage_by_role == %{
               "singularity_web" => true,
               "singularity_worker" => true,
               "singularity_dispatcher" => false,
               "singularity_pre_auth" => false
             }

      temporary_usage_roles = for [role, false] <- baseline_usage, do: role

      for {repo, role} <- runtime_repos() do
        assert [[role, role]] ==
                 Ecto.Adapters.SQL.query!(
                   repo,
                   "SELECT session_user::text,current_user::text",
                   [],
                   log: false
                 ).rows

        assert [[Map.fetch!(baseline_usage_by_role, role)]] ==
                 Ecto.Adapters.SQL.query!(
                   repo,
                   "SELECT has_schema_privilege(current_user,'audit','USAGE')",
                   [],
                   log: false
                 ).rows

        for oid <- helper_oids do
          assert [[false]] ==
                   Ecto.Adapters.SQL.query!(
                     repo,
                     "SELECT has_function_privilege(current_user,$1::oid,'EXECUTE')",
                     [oid],
                     log: false
                   ).rows
        end
      end

      try do
        owner_transaction(fn ->
          sql("""
          CREATE FUNCTION audit.test_nested_knowledge_restore(uuid,uuid,bytea,bigint[],bytea[])
          RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $body$
          BEGIN
            PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('singularity:restore-import:v1',0));
            PERFORM audit.begin_knowledge_restore($1,$2,$3,$4,$5);
          END $body$
          """)

          sql(
            "REVOKE ALL ON FUNCTION audit.test_nested_knowledge_restore(uuid,uuid,bytea,bigint[],bytea[]) FROM PUBLIC"
          )

          for role <- runtime_roles(),
              do:
                sql(
                  "GRANT EXECUTE ON FUNCTION audit.test_nested_knowledge_restore(uuid,uuid,bytea,bigint[],bytea[]) TO #{role}"
                )

          for role <- temporary_usage_roles, do: sql("GRANT USAGE ON SCHEMA audit TO #{role}")
        end)

        for {repo, _role} <- runtime_repos() do
          for oid <- helper_oids do
            assert [[false]] ==
                     Ecto.Adapters.SQL.query!(
                       repo,
                       "SELECT has_function_privilege(current_user,$1::oid,'EXECUTE')",
                       [oid],
                       log: false
                     ).rows
          end

          for {statement, nested?} <- [
                {begin_statement(), false},
                {"SELECT audit.test_nested_knowledge_restore($1,$2,$3,$4,$5)", true}
              ] do
            error =
              assert_raise Postgrex.Error, fn ->
                repo.transaction(fn ->
                  Ecto.Adapters.SQL.query!(
                    repo,
                    "SELECT set_config('singularity.knowledge_restore_admitted','true',true),set_config('singularity.vault_id',$1,true),set_config('singularity.principal_id',$2,true)",
                    [@ids.vault_id, @ids.principal_id],
                    log: false
                  )

                  Ecto.Adapters.SQL.query!(
                    repo,
                    statement,
                    begin_parameters(ctx.locked.expected, bundle),
                    log: false
                  )
                end)
              end

            assert error.postgres.code == :insufficient_privilege

            if nested? do
              assert error.postgres.message == "knowledge restore authority unavailable"
              assert is_binary(error.postgres[:where])
              assert error.postgres.where =~ "begin_knowledge_restore"
              assert error.postgres.where =~ "test_nested_knowledge_restore"
            end
          end

          error =
            assert_raise Postgrex.Error, fn ->
              Ecto.Adapters.SQL.query!(
                repo,
                "SELECT * FROM audit.knowledge_restore_admissions",
                [],
                log: false
              )
            end

          assert error.postgres.code == :insufficient_privilege
        end
      after
        owner_transaction(fn ->
          sql(
            "DROP FUNCTION IF EXISTS audit.test_nested_knowledge_restore(uuid,uuid,bytea,bigint[],bytea[])"
          )

          for role <- temporary_usage_roles, do: sql("REVOKE USAGE ON SCHEMA audit FROM #{role}")
          assert schema_snapshot.() == baseline_schema

          assert [[true]] ==
                   sql(
                     "SELECT to_regprocedure('audit.test_nested_knowledge_restore(uuid,uuid,bytea,bigint[],bytea[])') IS NULL"
                   ).rows
        end)
      end

      assert_no_import()
    end)
  end

  test "owned JSON encoding obeys frozen literals, never caller pg_temp functions", ctx do
    with_destination(ctx.locked, fn _destination, _bundle, _storage ->
      owner_transaction(fn ->
        require_contract()
        poison_temp_encoder()

        for {literal, expected} <- @json_vectors do
          assert [[expected]] ==
                   sql("SELECT encode(audit.knowledge_restore_json_bytes(#{literal}),'hex')").rows
        end

        assert [[0, hex(@empty_digest)]] ==
                 sql("SELECT row_count,digest FROM audit.knowledge_restore_table_digest(0)").rows
      end)
    end)
  end

  test "owned people digest matches independent empty, two-row native-PK and value-sensitive vectors",
       ctx do
    with_destination(ctx.locked, fn _destination, _bundle, _storage ->
      require_owner_contract()

      assert {:error, :vectors} =
               owner_transaction(fn ->
                 assert [[0, hex(@empty_digest)]] ==
                          sql(
                            "SELECT row_count,digest FROM audit.knowledge_restore_table_digest(0)"
                          ).rows

                 sql("""
                 INSERT INTO identity.people(id,display_name,metadata,inserted_at,updated_at) VALUES
                 ('00000000-0000-0000-0000-000000000002','', '{"a":1}'::jsonb,
                   TIMESTAMPTZ '1970-01-01 00:00:00.000001+00',TIMESTAMPTZ '1969-12-31 23:59:59.999999+00'),
                 ('00000000-0000-0000-0000-000000000001','界🙂','{}'::jsonb,
                   TIMESTAMPTZ '1970-01-01 00:00:00+00',TIMESTAMPTZ '1970-01-01 00:00:00.000001+00')
                 """)

                 assert [[2, hex(@two_digest)]] ==
                          sql(
                            "SELECT row_count,digest FROM audit.knowledge_restore_table_digest(0)"
                          ).rows

                 refute hex(@two_digest) == hex(@reverse_digest)

                 sql(
                   "UPDATE identity.people SET metadata='{\"a\":2}'::jsonb WHERE id='00000000-0000-0000-0000-000000000002'"
                 )

                 [[2, changed]] =
                   sql("SELECT row_count,digest FROM audit.knowledge_restore_table_digest(0)").rows

                 refute changed == hex(@two_digest)
                 MigrationRepo.rollback(:vectors)
               end)

      for ordinal <- [-1, 38, nil] do
        reject_transaction(fn ->
          sql("SELECT * FROM audit.knowledge_restore_table_digest($1)", [ordinal])
        end)
      end
    end)
  end

  test "legal sixteen-MiB wire JSON expansion retains the independently frozen full row digest",
       ctx do
    with_destination(ctx.locked, fn _destination, _bundle, _storage ->
      require_owner_contract()

      metadata = %{
        "bulk" => String.duplicate("x", 16_777_216 - 10_000),
        "numbers" => List.duplicate(1, 1000)
      }

      uuid = "00000000-0000-4000-8000-000000000001"

      assert {:ok, record} =
               LogicalRecordCodec.encode_row(
                 "identity.people",
                 [{"uuid", uuid}],
                 [
                   {"uuid", uuid},
                   {"text", ""},
                   {"json", metadata},
                   {"timestamp", "1970-01-01T00:00:00.000000Z"},
                   {"timestamp", "1970-01-01T00:00:00.000001Z"}
                 ],
                 3
               )

      assert byte_size(record.payload) <= 16_777_216

      assert {:error, :expanded} =
               owner_transaction(fn ->
                 sql(
                   """
                   INSERT INTO identity.people(id,display_name,metadata,inserted_at,updated_at)
                   VALUES($1,'',($2::text)::jsonb,TIMESTAMPTZ '1970-01-01 00:00:00+00',TIMESTAMPTZ '1970-01-01 00:00:00.000001+00')
                   """,
                   [dump(uuid), Jason.encode!(metadata)]
                 )

                 assert [[16_785_286]] ==
                          sql(
                            "SELECT octet_length(audit.knowledge_restore_json_bytes(metadata)) FROM identity.people"
                          ).rows

                 assert [
                          [
                            1,
                            hex(
                              "c714e3d40d807916e9a7d462deb3d3b382aeabf3c204e8e5ea77cbf5a4a5b161"
                            )
                          ]
                        ] ==
                          sql(
                            "SELECT row_count,digest FROM audit.knowledge_restore_table_digest(0)"
                          ).rows

                 MigrationRepo.rollback(:expanded)
               end)
    end)
  end

  defp prepare_source(portable, locked) do
    KnowledgeBackupFixtures.with_destination(:current, fn destination ->
      fixture =
        KnowledgeBackupFixtures.seed!(Map.merge(destination, %{ids: @ids, originals: @originals}))

      rows = live_rows(KnowledgeBackupFixtures.canonical_rows(fixture), fixture, locked)

      assert {:ok, bundle} =
               KnowledgeBackupFixtures.transformed_bundle(fixture, rows: fn _ -> rows end)

      assert %BundleReader.Verified{records: [], replay: %BundleReader.Replay{}} = bundle.verified
      filename = bundle.binding.destination_ref
      File.cp!(Path.join(destination.object_root, filename), Path.join(portable, filename))
      File.chmod!(Path.join(portable, filename), 0o600)
      storage = private_storage(destination, "source-expected")

      try do
        assert {:error, {:prepared, raw, expected}} =
                 owner_transaction(fn ->
                   assert {:ok, staged} =
                            KnowledgePreflight.stage(
                              MigrationRepo,
                              bundle.verified,
                              bundle.cut,
                              storage
                            )

                   assert {:ok, raw} =
                            KnowledgePreflight.validate(MigrationRepo, staged, bundle.cut)

                   assert ordered_counts(raw) == @counts
                   assert Enum.sum(Map.values(raw.counts)) == 30

                   expected =
                     if locked do
                       raw
                     else
                       sql("UPDATE pg_temp.knowledge_restore_5 SET locked=true")
                       expected = staged_summary()
                       sql("UPDATE pg_temp.knowledge_restore_5 SET locked=false")
                       assert staged_summary() == raw
                       assert staged.summary == raw
                       expected
                     end

                   MigrationRepo.rollback({:prepared, raw, expected})
                 end)

        %{
          database: destination.database,
          portable: portable,
          filename: filename,
          rows: rows,
          raw_summary: raw,
          expected: expected,
          locked: locked,
          binding: bundle.binding
        }
      after
        cleanup_stages(storage)
      end
    end)
  end

  defp live_rows(all, fixture, locked) do
    empty = fixture.sources.empty
    resources = [empty.resource_id, @ids.live_note_id, @ids.pending_document_id]
    versions = [empty.resource_version_id, @ids.initial_note_version_id, @ids.pending_version_id]
    capability = Enum.find(all["core.capabilities"], &(&1["name"] == "asset.read"))
    people = Enum.find(all["identity.accounts"], &(&1["id"] == @ids.account_id))["person_id"]

    selected = %{
      "identity.people" => Enum.filter(all["identity.people"], &(&1["id"] == people)),
      "identity.accounts" =>
        Enum.filter(all["identity.accounts"], &(&1["id"] == @ids.account_id)),
      "identity.credentials" => all["identity.credentials"],
      "identity.principals" =>
        Enum.filter(all["identity.principals"], &(&1["id"] == @ids.principal_id)),
      "core.capabilities" => [capability],
      "core.vaults" =>
        Enum.map(
          all["core.vaults"],
          &Map.merge(&1, %{"locked" => locked, "object_cleanup_principal_id" => nil})
        ),
      "core.vault_members" =>
        Enum.filter(all["core.vault_members"], &(&1["principal_id"] == @ids.principal_id)),
      "core.principal_capabilities" =>
        Enum.filter(
          all["core.principal_capabilities"],
          &(&1["principal_id"] == @ids.principal_id and &1["capability_id"] == capability["id"])
        ),
      "content.resources" =>
        all["content.resources"]
        |> Enum.filter(&(&1["id"] in resources))
        |> Enum.map(fn row ->
          if row["id"] == @ids.live_note_id,
            do: Map.put(row, "current_version_id", @ids.initial_note_version_id),
            else: row
        end),
      "content.resource_versions" =>
        Enum.filter(all["content.resource_versions"], &(&1["id"] in versions)),
      "content.asset_objects" =>
        Enum.filter(all["content.asset_objects"], &(&1["id"] == empty.object_id)),
      "content.assets" => Enum.filter(all["content.assets"], &(&1["id"] == empty.asset_id)),
      "content.asset_key_envelopes" =>
        Enum.filter(
          all["content.asset_key_envelopes"],
          &(&1["asset_object_id"] == empty.object_id)
        ),
      "content.resource_assets" =>
        Enum.filter(all["content.resource_assets"], &(&1["asset_id"] == empty.asset_id)),
      "content.note_versions" =>
        Enum.filter(
          all["content.note_versions"],
          &(&1["resource_version_id"] == @ids.initial_note_version_id)
        ),
      "content.document_versions" =>
        Enum.filter(
          all["content.document_versions"],
          &(&1["resource_version_id"] == @ids.pending_version_id)
        ),
      "content.document_import_receipts" =>
        Enum.filter(
          all["content.document_import_receipts"],
          &(&1["version_id"] == @ids.pending_version_id)
        ),
      "content.note_attachments" => [
        hd(all["content.note_attachments"])
        |> Map.merge(%{
          "note_resource_version_id" => @ids.initial_note_version_id,
          "id" => @ids.attachment_id,
          "note_resource_id" => @ids.live_note_id,
          "target_resource_id" => empty.resource_id,
          "target_resource_version_id" => empty.resource_version_id,
          "target_kind" => "asset",
          "ordinal" => 0,
          "role" => "source"
        })
      ],
      "content.tags" => all["content.tags"],
      "content.resource_tags" => all["content.resource_tags"],
      "content.relationships" =>
        Enum.map(
          all["content.relationships"],
          &Map.merge(&1, %{
            "target_resource_id" => @ids.pending_document_id,
            "target_resource_version_id" => @ids.pending_version_id
          })
        )
    }

    for table <-
          ~w(core.key_domains core.vault_key_versions core.vault_key_wrappers core.domain_key_versions core.domain_dedup_key_wrappers),
        into: selected do
      {table, all[table]}
    end
    |> then(fn selected ->
      Map.new(all, fn {table, _rows} -> {table, Map.get(selected, table, [])} end)
    end)
  end

  defp with_destination(source, fun) do
    KnowledgeBackupFixtures.with_destination(:current, fn destination ->
      refute destination.database == source.database
      storage = private_storage(destination, "admission-private")

      assert {:ok, reader} =
               LocalDestination.reader_source(%{backup_root: source.portable}, source.filename)

      crypto = %{
        key: :crypto.hash(:sha256, "knowledge-fixture-backup-key"),
        vault_id: @ids.vault_id,
        encryption_domain_id: id(902),
        object_id: id(900),
        chunk_index: 0,
        algorithm: Format.algorithm(),
        format_version: Format.format_version(),
        chunk_size: Format.chunk_size()
      }

      assert {:ok, verified} =
               BundleReader.authenticate_all(reader,
                 crypto: {FixtureCrypto, crypto},
                 verifier: {LogicalBundleVerifier, source.binding}
               )

      assert %BundleReader.Verified{records: [], replay: %BundleReader.Replay{}} = verified
      bundle = %{verified: verified, cut: verified.cut, binding: source.binding}

      try do
        fun.(destination, bundle, storage)
      after
        BundleReader.discard_verified(verified)
        cleanup_stages(storage)
      end
    end)
  end

  defp private_storage(destination, name) do
    root = Path.join(destination.object_root, name)
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    %{module: LocalFilesystemAdapter, context: %{root: root}}
  end

  defp cleanup_stages(storage) do
    assert {:ok, stages} = LocalFilesystemAdapter.list_staged(storage.context)
    for ref <- stages, do: assert(:ok == LocalFilesystemAdapter.abort_stage(storage.context, ref))
    assert {:ok, []} = LocalFilesystemAdapter.list_staged(storage.context)
    assert Path.wildcard(Path.join(storage.context.root, "objects/**/*"), match_dot: true) == []
    assert Path.wildcard(Path.join(storage.context.root, "finalized/**/*"), match_dot: true) == []
  end

  defp insert_graph(rows, seal? \\ true) do
    sql("SET CONSTRAINTS ALL DEFERRED")

    [[dummy_verifier]] =
      sql("SELECT dummy_verifier FROM identity.security_settings WHERE singleton").rows

    assert is_binary(dummy_verifier) and dummy_verifier != ""

    for schema <- LogicalSchemaV3.all(), row <- rows[schema.table] do
      fields =
        Enum.map(schema.columns, fn column ->
          value =
            if schema.table == "core.vaults" and column.name == "locked",
              do: true,
              else: row[column.name]

          {column.name, column.tag, value}
        end)

      fields =
        case schema.table do
          "identity.credentials" ->
            fields ++
              [
                {"verifier", "text", dummy_verifier},
                {"verifier_version", "integer", 1},
                {"updated_at", "timestamp", row["inserted_at"]}
              ]

          "core.vault_key_wrappers" ->
            fields ++
              [
                {"kdf_version", "integer", 1},
                {"kdf_salt", "bytes", "restore-pending"},
                {"kdf_parameters", "json", %{"state" => "restore_pending", "version" => 1}},
                {"wrapper_algorithm", "text", "restore_pending"},
                {"wrapped_key", "bytes", "restore-pending"}
              ]

          _ ->
            fields
        end

      columns = Enum.map_join(fields, ",", fn {name, _, _} -> name end)

      placeholders =
        fields
        |> Enum.with_index(1)
        |> Enum.map_join(",", fn {{_, tag, _}, n} ->
          if tag == "json", do: "($#{n}::text)::jsonb", else: "$#{n}"
        end)

      params = Enum.map(fields, fn {_, tag, value} -> parameter(tag, value) end)
      sql("INSERT INTO #{schema.table}(#{columns}) VALUES(#{placeholders})", params)
    end

    if seal?,
      do: sql("SELECT content.finalize_note_source_set($1)", [dump(@ids.initial_note_version_id)])
  end

  defp parameter(_tag, nil), do: nil
  defp parameter("uuid", uuid), do: dump(uuid)
  defp parameter("json", value), do: Jason.encode!(value)

  defp parameter("timestamp", value) do
    {:ok, time, 0} = DateTime.from_iso8601(value)
    time
  end

  defp parameter(_tag, value), do: value

  defp staged_summary, do: digest_summary(:staged)
  defp canonical_summary, do: digest_summary(:canonical)

  defp digest_summary(selection) do
    Enum.reduce(LogicalSchemaV3.all(), %{counts: %{}, digests: %{}}, fn schema, acc ->
      assert {:ok, %{count: count, digest: digest}} =
               KnowledgeRestoreDigest.table_digest(MigrationRepo, schema.table, selection)

      %{
        counts: Map.put(acc.counts, schema.table, count),
        digests: Map.put(acc.digests, schema.table, digest)
      }
    end)
  end

  defp assert_owned_summary(expected) do
    for schema <- LogicalSchemaV3.all() do
      assert [[expected.counts[schema.table], expected.digests[schema.table]]] ==
               sql("SELECT row_count,digest FROM audit.knowledge_restore_table_digest($1)", [
                 schema.ordinal
               ]).rows
    end
  end

  defp ordered_counts(summary), do: Enum.map(LogicalSchemaV3.all(), &summary.counts[&1.table])
  defp ordered_digests(summary), do: Enum.map(LogicalSchemaV3.all(), &summary.digests[&1.table])

  defp marker(bundle, storage) do
    sql(
      """
      INSERT INTO audit.restore_import_sagas(singleton,manifest_id,vault_id,manifest_hash,manifest_tag,inventory_hash,destination_root_hash,object_count,state)
      VALUES(true,$1,$2,$3,$4,$5,$6,$7,'pending')
      """,
      binding_parameters(bundle) ++
        [
          bundle.verified.manifest_tag,
          inventory_hash(bundle),
          root_hash(storage),
          length(bundle.cut.object_inventory)
        ]
    )
  end

  defp inventory_hash(bundle),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(bundle.cut.object_inventory, [:deterministic]))

  defp root_hash(storage), do: :crypto.hash(:sha256, Path.expand(storage.context.root))

  defp binding_parameters(bundle),
    do: [
      dump(bundle.binding.manifest_id),
      dump(bundle.binding.vault_id),
      bundle.verified.manifest_hash
    ]

  defp begin_parameters(expected, bundle),
    do: binding_parameters(bundle) ++ [ordered_counts(expected), ordered_digests(expected)]

  defp begin_statement,
    do: "SELECT audit.begin_knowledge_restore($1,$2,$3,$4::bigint[],$5::bytea[])"

  defp begin_sql(expected, bundle), do: sql(begin_statement(), begin_parameters(expected, bundle))

  defp validate_sql(bundle),
    do: sql("SELECT audit.validate_knowledge_restore($1,$2,$3)", binding_parameters(bundle))

  defp lock_restore,
    do: sql("SELECT pg_advisory_xact_lock(hashtextextended($1::text,0))", [@lock])

  defp mark_imported,
    do:
      sql(
        "UPDATE audit.restore_import_sagas SET state='imported',imported_at=CURRENT_TIMESTAMP WHERE singleton"
      )

  defp assert_bound(value),
    do:
      assert(
        [[value]] ==
          sql("SELECT audit.knowledge_restore_is_bound($1)", [dump(@ids.vault_id)]).rows
      )

  defp assert_admission(expected, bundle, storage, state) do
    assert [[true]] ==
             sql(
               """
               SELECT singleton AND manifest_id=$1 AND vault_id=$2 AND manifest_hash=$3
                 AND manifest_tag=$4 AND inventory_hash=$5 AND destination_root_hash=$6
                 AND object_count=$7 AND expected_counts=$8 AND expected_digests=$9 AND state=$10
                 AND backend_pid=pg_backend_pid() AND transaction_id=pg_current_xact_id()
               FROM audit.knowledge_restore_admissions
               """,
               binding_parameters(bundle) ++
                 [
                   bundle.verified.manifest_tag,
                   inventory_hash(bundle),
                   root_hash(storage),
                   length(bundle.cut.object_inventory),
                   ordered_counts(expected),
                   ordered_digests(expected),
                   state
                 ]
             ).rows
  end

  defp require_contract do
    assert [[true]] ==
             sql("SELECT to_regclass('audit.knowledge_restore_admissions') IS NOT NULL").rows

    for signature <- @signatures,
        do: assert([[true]] == sql("SELECT to_regprocedure($1) IS NOT NULL", [signature]).rows)
  end

  defp require_owner_contract, do: owner_transaction(&require_contract/0)

  defp require_adapter do
    assert Code.ensure_loaded?(KnowledgePreflight)

    assert function_exported?(KnowledgePreflight, :begin_restore, 2),
           "missing KnowledgePreflight.begin_restore/2"

    assert function_exported?(KnowledgePreflight, :validate_destination, 2),
           "missing KnowledgePreflight.validate_destination/2"
  end

  defp assert_invalid(result) do
    assert {:error, %Error{code: :backup_invalid, details: details}} = result
    assert details == %{}
  end

  defp assert_seal do
    assert [[@ids.initial_note_version_id, @ids.live_note_id, @ids.vault_id, "private", 1, 0]] ==
             sql(
               "SELECT note_resource_version_id::text,note_resource_id::text,vault_id::text,classification,attachment_count,citation_count FROM content.note_source_set_seals"
             ).rows
  end

  defp force_ordinary_constraints,
    do: sql("SET CONSTRAINTS #{Enum.join(@ordinary_constraints, ",")} IMMEDIATE")

  defp assert_empty_exclusions do
    for table <- @excluded, do: assert([[0]] == sql("SELECT count(*) FROM #{table}").rows)

    if sql("SELECT to_regclass('content.knowledge_mutation_receipts') IS NOT NULL").rows == [
         [true]
       ],
       do: assert([[0]] == sql("SELECT count(*) FROM content.knowledge_mutation_receipts").rows)
  end

  defp assert_no_import do
    owner_transaction(fn ->
      for schema <- LogicalSchemaV3.all(),
          do: assert([[0]] == sql("SELECT count(*) FROM #{schema.table}").rows)

      assert [[0]] == sql("SELECT count(*) FROM content.note_source_set_seals").rows
      assert [[0]] == sql("SELECT count(*) FROM audit.knowledge_restore_admissions").rows
      assert_empty_exclusions()
    end)
  end

  defp reject_transaction(fun) do
    returned = {__MODULE__, :rejection_callback_returned}
    Process.put(returned, false)
    Process.put({__MODULE__, :at_contract_call}, false)

    assert_raise Postgrex.Error, fn ->
      owner_transaction(fn ->
        result = fun.()
        Process.put(returned, true)
        result
      end)
    end

    # A fixture INSERT, missing native relation or a later loading-state COMMIT
    # cannot masquerade as rejection by the specific API/write under test.
    refute Process.get(returned)
    assert Process.get({__MODULE__, :at_contract_call})
    Process.delete(returned)
    Process.delete({__MODULE__, :at_contract_call})
  end

  defp commit_rejected(fun, must_return? \\ true) do
    key = {__MODULE__, :callback_returned}
    Process.put(key, false)

    assert_raise Postgrex.Error, fn ->
      owner_transaction(fn ->
        fun.()
        Process.put(key, true)
        :returned_normally
      end)
    end

    if must_return?, do: assert(Process.get(key))
    Process.delete(key)
  end

  defp poison_temp_encoder do
    sql("CREATE TEMP TABLE admission_temp_namespace_probe(n integer) ON COMMIT DROP")

    sql("""
    CREATE OR REPLACE FUNCTION pg_temp.knowledge_restore_json(value jsonb) RETURNS bytea
    LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog AS $body$
    BEGIN RAISE EXCEPTION 'untrusted temporary restore encoder'; END $body$
    """)
  end

  defp with_migration_connection(fun) do
    config =
      MigrationRepo.config()
      |> Keyword.take([
        :hostname,
        :port,
        :socket_dir,
        :username,
        :password,
        :database,
        :ssl,
        :parameters,
        :timeout,
        :connect_timeout
      ])

    {:ok, connection} = Postgrex.start_link(config)

    try do
      fun.(connection)
    after
      GenServer.stop(connection)
    end
  end

  defp runtime_repos,
    do: [
      {Singularity.Storage.RequestRepo, "singularity_web"},
      {Singularity.Storage.WorkerRepo, "singularity_worker"},
      {Singularity.Storage.DispatcherRepo, "singularity_dispatcher"},
      {Singularity.Storage.PreAuthRepo, "singularity_pre_auth"}
    ]

  defp runtime_roles, do: Enum.map(runtime_repos(), &elem(&1, 1))

  defp owner_transaction(fun),
    do:
      MigrationRepo.transaction(fn ->
        sql("SET LOCAL ROLE singularity_table_owner")
        fun.()
      end)

  defp sql(statement, params \\ []) do
    Process.put(
      {__MODULE__, :at_contract_call},
      String.starts_with?(statement, [
        "SELECT audit.begin_knowledge_restore",
        "SELECT audit.validate_knowledge_restore",
        "SELECT audit.assert_knowledge_restore_graph",
        "UPDATE audit.knowledge_restore_admissions",
        "SELECT * FROM audit.knowledge_restore_table_digest"
      ])
    )

    Ecto.Adapters.SQL.query!(MigrationRepo, statement, params, log: false)
  end

  defp dump(uuid), do: Ecto.UUID.dump!(uuid)
  defp hex(value), do: Base.decode16!(value, case: :lower)
  defp id(n), do: "60000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")
end
