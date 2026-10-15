defmodule Singularity.Storage.Backup.KnowledgeHistoricalAdmissionTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Singularity.Core.DocumentFragment
  alias Singularity.Storage.{LocalFilesystemAdapter, MigrationRepo}

  alias Singularity.Storage.Backup.{
    BundleReader,
    KnowledgeBackupFixtures,
    KnowledgePreflight,
    LocalDestination,
    LogicalBundleVerifier,
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
  # Literal cardinalities derived from source construction, in frozen V3 order.
  # Neither bundle metadata nor destination counts choose this expectation.
  @counts %{
    deleted_document: [
      1,
      1,
      1,
      2,
      2,
      1,
      2,
      2,
      0,
      1,
      1,
      1,
      1,
      1,
      2,
      2,
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
      0,
      0,
      1,
      2,
      1,
      0,
      0,
      0,
      0,
      0
    ],
    ready_fragments: [
      1,
      1,
      1,
      2,
      2,
      1,
      2,
      2,
      0,
      1,
      1,
      1,
      1,
      1,
      2,
      2,
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
      0,
      0,
      1,
      2,
      1,
      0,
      0,
      0,
      0,
      0
    ],
    note_sources: [
      1,
      1,
      1,
      2,
      2,
      1,
      2,
      2,
      0,
      1,
      1,
      1,
      1,
      1,
      2,
      2,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      2,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0
    ],
    organization: [
      1,
      1,
      1,
      2,
      2,
      1,
      2,
      2,
      0,
      1,
      1,
      1,
      1,
      1,
      2,
      2,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      2,
      0,
      0,
      0,
      0,
      0,
      0,
      1,
      1,
      1
    ],
    complete_history: [
      1,
      1,
      1,
      2,
      2,
      1,
      2,
      2,
      0,
      1,
      1,
      1,
      1,
      1,
      14,
      19,
      5,
      6,
      5,
      0,
      6,
      0,
      0,
      0,
      1,
      1,
      1,
      1,
      6,
      2,
      7,
      6,
      7,
      4,
      3,
      1,
      1,
      1
    ]
  }
  @totals %{
    deleted_document: 29,
    ready_fragments: 29,
    note_sources: 24,
    organization: 26,
    complete_history: 114
  }
  @base_tables ~w(identity.people identity.accounts identity.credentials identity.principals
    core.capabilities core.vaults core.vault_members core.principal_capabilities
    identity.devices core.key_domains core.vault_key_versions core.vault_key_wrappers
    core.domain_key_versions core.domain_dedup_key_wrappers)
  @ordinary_constraints ~w(
    resource_versions_resource_classification_fkey resources_version_head_fkey
    note_versions_parent_fkey note_versions_merge_parent_fkey note_conflicts_base_version_fkey
    note_conflicts_canonical_version_fkey note_conflicts_competing_version_fkey
    note_conflicts_resolution_version_fkey note_mutation_receipts_resource_fkey
    note_mutation_receipts_version_fkey note_mutation_receipts_conflict_fkey
    document_versions_resource_version_fkey document_import_receipts_version_fkey
    document_fragments_document_version_fkey note_attachments_note_fkey
    note_attachments_target_fkey note_citations_note_fkey note_citations_fragment_fkey
    note_source_set_seals_note_fkey note_versions_aggregate_check
    note_mutation_receipts_resource_check resources_00_typed_head_check
    note_versions_00_typed_head_check document_versions_00_typed_head_check
    document_import_receipts_completed_check document_versions_completion_check
    document_fragments_completion_check note_attachments_source_set_check
    note_citations_source_set_check note_versions_source_set_seal_check
    note_attachments_source_set_seal_check note_citations_source_set_seal_check
  )
  @excluded ~w(identity.sessions identity.auth_attempts content.asset_stages content.upload_grants
    content.asset_search_documents content.note_search_documents content.search_entries
    content.note_mutation_receipts audit.backup_manifests
    audit.backup_manifest_objects jobs.oban_jobs jobs.oban_peers)

  setup_all do
    portable = Path.join(System.tmp_dir!(), "knowledge-history-#{Ecto.UUID.generate()}")
    File.mkdir_p!(portable)
    File.chmod!(portable, 0o700)
    on_exit(fn -> File.rm_rf!(portable) end)
    %{sources: prepare_sources(portable)}
  end

  test "bound restore commits the deleted Document with released source and its independent retained original",
       ctx do
    source = ctx.sources.deleted_document

    assert [%{"deleted_at" => deleted}] =
             Enum.filter(
               source.rows["content.resources"],
               &(&1["id"] == @ids.deleted_document_id)
             )

    refute is_nil(deleted)
    assert [%{"state" => "deleted", "asset_object_id" => nil}] = source.rows["content.assets"]
    assert [%{"released_at" => released}] = source.rows["content.resource_assets"]
    refute is_nil(released)

    assert [%{"id" => object, "lifecycle" => "available", "deleted_at" => nil}] =
             source.rows["content.asset_objects"]

    assert [%{"source_object_id" => ^object, "source_digest" => digest, "state" => "ready"}] =
             source.rows["content.document_versions"]

    assert digest == :crypto.hash(:sha256, @originals.pdf)

    assert Enum.map(source.rows["content.document_fragments"], & &1["ordinal"]) |> Enum.sort() ==
             [0, 1]

    assert_restore_commits(source)
  end

  test "bound restore inserts exact ready fragments independently of deleted-source admission",
       ctx do
    source = ctx.sources.ready_fragments

    assert [%{"state" => "available", "asset_object_id" => object}] =
             source.rows["content.assets"]

    assert [%{"released_at" => nil}] = source.rows["content.resource_assets"]

    assert [%{"state" => "ready", "source_object_id" => ^object, "attempt_generation" => 1}] =
             source.rows["content.document_versions"]

    assert Enum.map(source.rows["content.document_fragments"], & &1["ordinal"]) |> Enum.sort() ==
             [0, 1]

    assert_restore_commits(source)
  end

  test "bound loading admits the initial sealed Note source history after both Notes are tombstoned",
       ctx do
    source = ctx.sources.note_sources
    assert source.rows["content.document_versions"] == []
    assert source.rows["content.document_fragments"] == []

    assert [%{"parent_version_id" => nil}, %{"parent_version_id" => nil}] =
             source.rows["content.note_versions"]

    assert [%{"target_kind" => "note", "ordinal" => 0}] = source.rows["content.note_attachments"]
    assert Enum.all?(source.rows["content.resources"], &(not is_nil(&1["deleted_at"])))
    assert_restore_commits(source)
  end

  test "bound restore commits tags and exact pinned edges on tombstoned typed endpoints", ctx do
    source = ctx.sources.organization
    assert source.rows["content.document_versions"] == []
    assert source.rows["content.note_attachments"] == []
    assert source.rows["content.note_citations"] == []
    assert [%{"target_resource_version_id" => pin}] = source.rows["content.relationships"]
    assert Enum.any?(source.rows["content.note_versions"], &(&1["resource_version_id"] == pin))
    assert Enum.all?(source.rows["content.resources"], &(not is_nil(&1["deleted_at"])))
    assert_restore_commits(source)
  end

  test "whole history commits all thirty-eight independent digests with conflicts, old sources, seals and work intact",
       ctx do
    source = ctx.sources.complete_history

    assert [%{"state" => "open"}, %{"state" => "resolved"}] =
             Enum.sort_by(source.rows["content.note_conflicts"], & &1["state"])

    assert Enum.map(source.rows["content.document_versions"], & &1["state"]) |> Enum.sort() ==
             ["extracting", "failed", "pending", "ready", "ready", "ready", "unsupported"]

    assert_restore_commits(source)
  end

  test "unbound migration transactions retain each exact creation-time guard", ctx do
    cases = [
      {:deleted_document, "document_versions_source_check", "content.document_versions"},
      {:ready_fragments, "document_fragments_insert_state_check", "content.document_fragments"},
      {:note_sources, "note_attachments_source_check", :ordinary_constraints},
      {:organization, "resource_tags_resource_check", "content.resource_tags"}
    ]

    for {name, constraint, phase} <- cases do
      source = Map.fetch!(ctx.sources, name)

      with_destination(source, fn _destination, _bundle, _storage ->
        assert_statement_rejected(constraint, phase, fn ->
          assert_bound(false)
          sql("SELECT set_config('singularity.knowledge_restore_admitted','true',true)")
          insert_graph(source.rows)
          force_ordinary_constraints()
        end)

        assert_no_import()
      end)
    end

    with_destination(ctx.sources.organization, fn _destination, _bundle, _storage ->
      rows = Map.put(ctx.sources.organization.rows, "content.resource_tags", [])

      assert_statement_rejected("relationships_resource_check", "content.relationships", fn ->
        insert_graph(rows)
      end)

      assert_no_import()
    end)
  end

  for {field, number} <- [
        {"source_object_id", 999},
        {"source_asset_id", 998},
        {"source_resource_id", 997},
        {"source_resource_version_id", 996},
        {"vault_id", 995},
        {"source_byte_size", nil}
      ] do
    test "bound historical source validators reject wrong #{field}", ctx do
      source = ctx.sources.deleted_document
      field = unquote(field)

      value =
        if field == "source_byte_size",
          do: byte_size(@originals.pdf) + 1,
          else: id(unquote(number))

      with_destination(source, fn _destination, bundle, storage ->
        assert_statement_rejected(
          "document_versions_source_check",
          "content.document_versions",
          fn ->
            open_admission(source, bundle, storage)

            rows =
              change_one(
                source.rows,
                "content.document_versions",
                &Map.replace!(&1, field, value)
              )

            insert_graph(rows)
          end
        )

        assert_no_import()
      end)
    end
  end

  test "bound historical source validators reject ambiguous Asset bindings", ctx do
    source = ctx.sources.deleted_document

    with_destination(source, fn _destination, bundle, storage ->
      assert_statement_rejected(
        "document_versions_source_check",
        "content.document_versions",
        fn ->
          open_admission(source, bundle, storage)
          [asset] = source.rows["content.assets"]
          [association] = source.rows["content.resource_assets"]

          rows =
            source.rows
            |> Map.update!("content.assets", &(&1 ++ [Map.put(asset, "id", id(994))]))
            |> Map.update!(
              "content.resource_assets",
              &(&1 ++ [Map.put(association, "asset_id", id(994))])
            )

          insert_graph(rows)
        end
      )

      assert_no_import()
    end)
  end

  for {name, field, value} <- [
        {"canonical digest", "digest", <<0::256>>},
        {"identity", "id", String.duplicate("0", 64)},
        {"locator bounds", "locator",
         %{
           "version" => 1,
           "kind" => "text",
           "start_line" => 0,
           "end_line" => 1
         }},
        {"locator shape", "locator",
         %{
           "version" => 1,
           "kind" => "text",
           "start_line" => 1,
           "end_line" => 1,
           "unknown" => true
         }}
      ] do
    @tag ready_fragment_mutation: {field, value}
    test "bound ready-fragment admission retains #{name} check", ctx do
      source = ctx.sources.ready_fragments
      {field, value} = ctx.ready_fragment_mutation

      with_destination(source, fn _destination, bundle, storage ->
        assert_statement_rejected(
          "document_extraction_input_check",
          "content.document_fragments",
          fn ->
            open_admission(source, bundle, storage)
            [first | rest] = source.rows["content.document_fragments"]

            insert_graph(
              Map.put(source.rows, "content.document_fragments", [
                Map.put(first, field, value) | rest
              ])
            )
          end
        )

        assert_no_import()
      end)
    end
  end

  for completion <- [:empty, :incomplete] do
    @tag ready_fragment_completion: completion
    test "bound ready-fragment admission rejects #{completion} completion", ctx do
      source = ctx.sources.ready_fragments

      fragments =
        case ctx.ready_fragment_completion do
          :empty -> []
          :incomplete -> Enum.take(source.rows["content.document_fragments"], 1)
        end

      with_destination(source, fn _destination, bundle, storage ->
        assert_statement_rejected(
          "document_versions_completion_check",
          :ordinary_constraints,
          fn ->
            open_admission(source, bundle, storage)
            insert_graph(Map.put(source.rows, "content.document_fragments", fragments))
            force_ordinary_constraints()
          end
        )

        assert_no_import()
      end)
    end
  end

  for {field, value, constraint} <- [
        {"target_kind", "asset", "note_attachments_source_check"},
        {"target_resource_id", {:id, 980}, "note_attachments_source_check"},
        {"target_resource_version_id", {:id, 981}, "note_attachments_source_check"},
        {"ordinal", 1, "note_attachments_source_set_check"}
      ] do
    @tag note_source_mutation: {field, value, constraint}
    test "bound Note source history rejects wrong #{field}", ctx do
      source = ctx.sources.note_sources
      {field, value, constraint} = ctx.note_source_mutation

      value =
        case value do
          {:id, number} -> id(number)
          value -> value
        end

      with_destination(source, fn _destination, bundle, storage ->
        phase = if field == "ordinal", do: :seal, else: :ordinary_constraints

        assert_statement_rejected(constraint, phase, fn ->
          open_admission(source, bundle, storage)

          insert_graph(
            change_one(source.rows, "content.note_attachments", &Map.replace!(&1, field, value))
          )

          if field != "ordinal" do
            Process.put({__MODULE__, :phase}, :ordinary_constraints)
            sql("SET CONSTRAINTS content.note_attachments_source_set_check IMMEDIATE")
          end

          force_ordinary_constraints()
        end)

        assert_no_import()
      end)
    end
  end

  test "bound Note source history retains natural attachment uniqueness", ctx do
    source = ctx.sources.note_sources

    with_destination(source, fn _destination, bundle, storage ->
      assert_statement_rejected(
        "note_attachments_note_ordinal_key",
        "content.note_attachments",
        fn ->
          open_admission(source, bundle, storage)
          [member] = source.rows["content.note_attachments"]

          rows =
            Map.put(source.rows, "content.note_attachments", [
              member,
              Map.put(member, "id", id(982))
            ])

          insert_graph(rows)
        end,
        :unique_violation
      )

      assert_no_import()
    end)
  end

  test "bound Note source history retains the historical citation locator check", ctx do
    source = ctx.sources.complete_history

    with_destination(source, fn _destination, bundle, storage ->
      assert_statement_rejected("note_citations_locator_check", :ordinary_constraints, fn ->
        open_admission(source, bundle, storage)

        rows =
          Map.update!(source.rows, "content.note_citations", fn [first | rest] ->
            [Map.put(first, "locator", %{"version" => 1, "kind" => "pdf", "page" => 99}) | rest]
          end)

        insert_graph(rows)
        force_ordinary_constraints()
      end)

      assert_no_import()
    end)
  end

  test "bound organization validates exact endpoint owner, pinned-version identity and natural edge uniqueness",
       ctx do
    source = ctx.sources.organization

    for {table, field, value, constraint, phase, code} <- [
          {"content.resource_tags", "resource_id", id(970), "resource_tags_resource_check",
           "content.resource_tags", :check_violation},
          {"content.relationships", "target_resource_id", id(971), "relationships_resource_check",
           "content.relationships", :check_violation},
          {"content.relationships", "vault_id", id(972), "relationships_resource_check",
           "content.relationships", :check_violation},
          {"content.relationships", "target_resource_version_id", id(931),
           "relationships_resource_check", "content.relationships", :check_violation}
        ] do
      with_destination(source, fn _destination, bundle, storage ->
        assert_statement_rejected(
          constraint,
          phase,
          fn ->
            open_admission(source, bundle, storage)
            insert_graph(change_one(source.rows, table, &Map.replace!(&1, field, value)))
          end,
          code
        )

        assert_no_import()
      end)
    end

    with_destination(source, fn _destination, bundle, storage ->
      assert_statement_rejected(
        "relationships_owner_source_target_type_key",
        "content.relationships",
        fn ->
          open_admission(source, bundle, storage)
          [edge] = source.rows["content.relationships"]

          insert_graph(
            Map.put(source.rows, "content.relationships", [edge, Map.put(edge, "id", id(974))])
          )
        end,
        :unique_violation
      )

      assert_no_import()
    end)
  end

  test "a complete historical graph without validation reaches actual COMMIT and is rejected",
       ctx do
    source = ctx.sources.complete_history

    with_destination(source, fn _destination, bundle, storage ->
      assert_commit_rejected("knowledge restore was not finalized", fn ->
        open_admission(source, bundle, storage)
        insert_graph(source.rows)
        assert_bound(true)
        force_ordinary_constraints()
        assert_owned_summary(source.expected)
      end)

      assert_no_import()
    end)
  end

  test "equal-count history mutation after validation reaches actual COMMIT and is rejected",
       ctx do
    source = ctx.sources.organization

    with_destination(source, fn _destination, bundle, storage ->
      assert_commit_rejected(
        "knowledge restore destination differs from authenticated staging",
        fn ->
          staged = open_admission(source, bundle, storage)
          insert_graph(source.rows)
          force_ordinary_constraints()
          assert :ok = KnowledgePreflight.validate_destination(MigrationRepo, staged)
          assert_bound(false)
          sql("UPDATE content.tags SET display_value='Changed',normalized_key='changed'")
          assert [[1]] == sql("SELECT count(*) FROM content.tags").rows
        end
      )

      assert_no_import()
    end)
  end

  test "validated historical admission never permits a later transaction to append ready fragments",
       ctx do
    source = ctx.sources.ready_fragments

    with_destination(source, fn _destination, bundle, storage ->
      assert {:ok, :committed} =
               owner_transaction(fn ->
                 staged = open_admission(source, bundle, storage)
                 insert_graph(source.rows)
                 force_ordinary_constraints()
                 assert :ok = KnowledgePreflight.validate_destination(MigrationRepo, staged)
                 :committed
               end)

      [document] = source.rows["content.document_versions"]
      append = fragment_row(document, 2, "late\n")

      assert_statement_rejected(
        "document_fragments_insert_state_check",
        "content.document_fragments",
        fn ->
          assert_bound(false)
          sql("SELECT set_config('singularity.knowledge_restore_admitted','true',true)")
          insert_row("content.document_fragments", append)
        end
      )

      owner_transaction(fn -> assert_owned_summary(source.expected) end)
    end)
  end

  test "actual web and worker sessions with spoofed GUCs reach and retain historical, sealed and immutable guards" do
    with_fixture(fn fixture ->
      rows = KnowledgeBackupFixtures.canonical_rows(fixture)
      {foreign_resource, foreign_version} = seed_foreign_note()

      with_runtime_permissions(fn ->
        for {repo, role} <- runtime_repos() do
          assert [[role, role]] ==
                   query(repo, "SELECT session_user::text,current_user::text").rows

          runtime_rejected(
            repo,
            "document_versions_source_check",
            "content.document_versions",
            fn ->
              candidate = new_document_row(rows, fixture.sources.pdf, id(950), id(951))

              seed_runtime_identity(
                repo,
                candidate["resource_id"],
                candidate["resource_version_id"],
                "document"
              )

              insert_row("content.document_versions", candidate, repo)
            end
          )

          ready =
            Enum.find(
              rows["content.document_versions"],
              &(&1["resource_version_id"] == @ids.ready_old_version_id)
            )

          runtime_rejected(
            repo,
            "document_fragments_immutable_check",
            "content.document_fragments",
            fn ->
              insert_row("content.document_fragments", fragment_row(ready, 2, "late\n"), repo)
            end
          )

          # The established seal SELECT policy is web-only. Prove the invoker
          # BEFORE INSERT guard with that genuine role, without changing RLS.
          for version <-
                if(role == "singularity_web",
                  do: [@ids.initial_note_version_id, @ids.merge_note_version_id],
                  else: []
                ) do
            runtime_rejected(
              repo,
              "note_attachments_sealed_check",
              "content.note_attachments",
              fn ->
                insert_row(
                  "content.note_attachments",
                  attachment_row(
                    @ids.live_note_id,
                    version,
                    fixture.sources.plain.resource_id,
                    fixture.sources.plain.resource_version_id,
                    "asset",
                    id(952)
                  ),
                  repo
                )
              end
            )

            runtime_rejected(repo, "note_citations_sealed_check", "content.note_citations", fn ->
              fragment =
                Enum.find(
                  rows["content.document_fragments"],
                  &(&1["resource_version_id"] == @ids.ready_old_version_id)
                )

              insert_row(
                "content.note_citations",
                citation_row(@ids.live_note_id, version, fragment, id(953)),
                repo
              )
            end)
          end

          runtime_rejected(
            repo,
            "note_attachments_source_check",
            :runtime_source_constraint,
            fn ->
              seed_runtime_identity(repo, id(954), id(955), "note")
              seed_note_version(repo, id(954), id(955))

              insert_row(
                "content.note_attachments",
                attachment_row(
                  id(954),
                  id(955),
                  @ids.deleted_note_id,
                  @ids.deleted_note_version_id,
                  "note",
                  id(956)
                ),
                repo
              )

              Process.put({__MODULE__, :phase}, :runtime_source_constraint)
              query(repo, "SET CONSTRAINTS content.note_attachments_source_set_check IMMEDIATE")
            end
          )

          runtime_rejected(
            repo,
            "note_attachments_source_check",
            :runtime_source_constraint,
            fn ->
              seed_runtime_identity(repo, id(954), id(955), "note")
              seed_note_version(repo, id(954), id(955))

              insert_row(
                "content.note_attachments",
                attachment_row(
                  id(954),
                  id(955),
                  foreign_resource,
                  foreign_version,
                  "note",
                  id(956)
                ),
                repo
              )

              Process.put({__MODULE__, :phase}, :runtime_source_constraint)
              query(repo, "SET CONSTRAINTS content.note_attachments_source_set_check IMMEDIATE")
            end
          )

          runtime_rejected(repo, "note_citations_source_check", :runtime_source_constraint, fn ->
            seed_runtime_identity(repo, id(954), id(955), "note")
            seed_note_version(repo, id(954), id(955))

            fragment =
              Enum.find(
                rows["content.document_fragments"],
                &(&1["resource_version_id"] == @ids.deleted_document_version_id)
              )

            insert_row(
              "content.note_citations",
              citation_row(id(954), id(955), fragment, id(957)),
              repo
            )

            Process.put({__MODULE__, :phase}, :runtime_source_constraint)
            query(repo, "SET CONSTRAINTS content.note_citations_source_set_check IMMEDIATE")
          end)

          runtime_rejected(repo, "resource_tags_resource_check", "content.resource_tags", fn ->
            insert_row(
              "content.resource_tags",
              %{
                "resource_id" => @ids.deleted_note_id,
                "tag_id" => @ids.tag_id,
                "vault_id" => @ids.vault_id,
                "classification" => "private",
                "inserted_at" => timestamp()
              },
              repo
            )
          end)

          runtime_rejected(repo, "relationships_resource_check", "content.relationships", fn ->
            insert_row(
              "content.relationships",
              relationship_row(
                id(958),
                @ids.live_note_id,
                @ids.deleted_document_id,
                @ids.deleted_document_version_id
              ),
              repo
            )
          end)

          runtime_rejected(repo, "relationships_resource_check", "content.relationships", fn ->
            insert_row(
              "content.relationships",
              relationship_row(id(958), @ids.live_note_id, foreign_resource, foreign_version),
              repo
            )
          end)

          for field <-
                ~w(source_asset_id source_resource_id source_resource_version_id source_object_id) do
            runtime_rejected(repo, "document_versions_immutable_check", :runtime_mutation, fn ->
              Process.put({__MODULE__, :phase}, :runtime_mutation)

              query(
                repo,
                "UPDATE content.document_versions SET #{field}=$2 WHERE resource_version_id=$1",
                [dump(@ids.ready_old_version_id), dump(id(959))]
              )
            end)
          end

          for {table, constraint, key, value} <- [
                {"content.document_fragments", "document_fragments_immutable_check",
                 "resource_version_id", @ids.ready_old_version_id},
                {"content.note_attachments", "note_attachments_immutable_check",
                 "note_resource_version_id", @ids.merge_note_version_id},
                {"content.note_citations", "note_citations_immutable_check",
                 "note_resource_version_id", @ids.merge_note_version_id}
              ],
              operation <- [:update, :delete] do
            runtime_rejected(repo, constraint, :runtime_mutation, fn ->
              Process.put({__MODULE__, :phase}, :runtime_mutation)

              statement =
                if operation == :delete,
                  do: "DELETE FROM #{table} WHERE #{key}=$1",
                  else: "UPDATE #{table} SET classification=classification WHERE #{key}=$1"

              query(repo, statement, [dump(value)])
            end)
          end
        end
      end)

      assert KnowledgeBackupFixtures.canonical_rows(fixture) == rows
    end)
  end

  for {table, constraint, operation} <- [
        {"content.document_versions", "document_versions_immutable_check", :update_pin},
        {"content.document_versions", "document_versions_immutable_check", :delete},
        {"content.document_fragments", "document_fragments_immutable_check", :update},
        {"content.document_fragments", "document_fragments_immutable_check", :delete},
        {"content.note_attachments", "note_attachments_immutable_check", :update},
        {"content.note_attachments", "note_attachments_immutable_check", :delete},
        {"content.note_citations", "note_citations_immutable_check", :update},
        {"content.note_citations", "note_citations_immutable_check", :delete},
        {"content.note_source_set_seals", "note_source_set_seals_immutable_check", :update},
        {"content.note_source_set_seals", "note_source_set_seals_immutable_check", :delete}
      ] do
    @tag bound_mutation: {table, constraint, operation}
    test "bound admission retains #{table} #{operation} guard with the complete historical oracle",
         ctx do
      {table, constraint, operation} = ctx.bound_mutation
      source = ctx.sources.complete_history

      with_destination(source, fn _destination, bundle, storage ->
        assert_statement_rejected(constraint, :bound_mutation, fn ->
          assert_bound_history_loaded(source, bundle, storage)
          Process.put({__MODULE__, :phase}, :bound_mutation)

          case operation do
            :update_pin ->
              sql("UPDATE content.document_versions SET source_object_id=$1", [dump(id(960))])

            :update ->
              sql("UPDATE #{table} SET classification=classification")

            :delete ->
              sql("DELETE FROM #{table}")
          end
        end)

        assert_no_import()
      end)

      # Preserve both sealed-append counterproofs while keeping each independent
      # immutable case within ExUnit's ordinary timeout and its own fresh Replay.
      if table == "content.note_attachments" do
        version =
          if operation == :update,
            do: @ids.initial_note_version_id,
            else: @ids.merge_note_version_id

        with_destination(source, fn _destination, bundle, storage ->
          assert_statement_rejected(
            "note_attachments_sealed_check",
            "content.note_attachments",
            fn ->
              assert_bound_history_loaded(source, bundle, storage)

              insert_row(
                "content.note_attachments",
                attachment_row(
                  @ids.live_note_id,
                  version,
                  @ids.deleted_note_id,
                  @ids.deleted_note_version_id,
                  "note",
                  id(961)
                )
              )
            end
          )

          assert_no_import()
        end)
      end
    end
  end

  defp assert_bound_history_loaded(source, bundle, storage) do
    assert ordered_counts(source.expected) == Map.fetch!(@counts, :complete_history)
    assert Enum.sum(ordered_counts(source.expected)) == 114
    assert map_size(source.expected.digests) == 38
    open_admission(source, bundle, storage)
    insert_graph(source.rows)
    assert_owned_summary(source.expected)
    assert_seals(source.rows)
    assert_bound(true)
  end

  defp prepare_sources(portable) do
    with_fixture(fn fixture ->
      # Every original member, receipt and organization row committed normally
      # in seed!/1 before these additional containing endpoints are tombstoned.
      owner_transaction(fn ->
        for resource <- [@ids.live_note_id, @ids.ready_document_id],
            do:
              sql("UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id=$1", [
                dump(resource)
              ])
      end)

      complete = KnowledgeBackupFixtures.canonical_rows(fixture)
      seed_isolated_sources(fixture, complete)
      all = KnowledgeBackupFixtures.canonical_rows(fixture)

      groups = %{
        complete_history: complete,
        deleted_document:
          document_subset(
            all,
            fixture.sources.pdf,
            @ids.deleted_document_id,
            @ids.deleted_document_version_id
          ),
        ready_fragments: document_subset(all, fixture.sources.plain, id(910), id(911)),
        note_sources: note_subset(all, [id(920), id(922)], [id(921), id(923)], id(924)),
        organization: organization_subset(all)
      }

      Map.new(groups, fn {name, rows} ->
        assert {:ok, bundle} =
                 KnowledgeBackupFixtures.transformed_bundle(fixture, rows: fn _ -> rows end)

        assert %BundleReader.Verified{records: [], replay: %BundleReader.Replay{}} =
                 bundle.verified

        filename = bundle.binding.destination_ref

        File.cp!(
          Path.join(fixture.destination.object_root, filename),
          Path.join(portable, filename)
        )

        File.chmod!(Path.join(portable, filename), 0o600)
        storage = private_storage(fixture.destination, "expected-#{name}")

        try do
          assert {:error, {:expected, expected}} =
                   owner_transaction(fn ->
                     assert {:ok, staged} =
                              KnowledgePreflight.stage(
                                MigrationRepo,
                                bundle.verified,
                                bundle.cut,
                                storage
                              )

                     assert {:ok, expected} =
                              KnowledgePreflight.validate(MigrationRepo, staged, bundle.cut)

                     assert ordered_counts(expected) == Map.fetch!(@counts, name)
                     assert Enum.sum(ordered_counts(expected)) == Map.fetch!(@totals, name)
                     assert map_size(expected.digests) == 38
                     MigrationRepo.rollback({:expected, expected})
                   end)

          {name,
           %{
             name: name,
             rows: rows,
             expected: expected,
             database: fixture.destination.database,
             portable: portable,
             filename: filename,
             binding: bundle.binding
           }}
        after
          cleanup_stages(storage)
        end
      end)
    end)
  end

  defp seed_isolated_sources(fixture, rows) do
    owner_transaction(fn ->
      scope(MigrationRepo)
      document = new_document_row(rows, fixture.sources.plain, id(910), id(911))
      seed_runtime_identity(MigrationRepo, id(910), id(911), "document")
      insert_row("content.document_versions", document)

      sql("SELECT content.claim_document_extraction($1,0,$2,'plain_text',1)", [
        dump(id(911)),
        dump(id(912))
      ])

      fragments =
        Enum.map(Enum.with_index(["isolated first\n", "isolated second\n"]), fn {text, ordinal} ->
          row = fragment_row(document, ordinal, text)

          Map.take(row, ~w(id ordinal text locator))
          |> Map.put("digest", Base.encode16(row["digest"], case: :lower))
        end)

      sql(
        "SELECT content.complete_document_extraction($1,$2,1,($3::text)::jsonb,$4,NULL)",
        [
          dump(id(911)),
          dump(id(912)),
          Jason.encode!(fragments),
          :crypto.hash(:sha256, "isolated first\nisolated second\n")
        ]
      )

      insert_row("content.document_import_receipts", %{
        "vault_id" => @ids.vault_id,
        "principal_id" => @ids.principal_id,
        "mutation_id" => id(911),
        "request_fingerprint" => :crypto.hash(:sha256, "document-import:" <> id(911)),
        "state" => "completed",
        "resource_id" => id(910),
        "version_id" => id(911),
        "inserted_at" => timestamp()
      })

      for {resource, version} <- [
            {id(920), id(921)},
            {id(922), id(923)},
            {id(930), id(931)},
            {id(932), id(933)}
          ] do
        seed_runtime_identity(MigrationRepo, resource, version, "note")
        seed_note_version(MigrationRepo, resource, version)
      end

      insert_row(
        "content.note_attachments",
        attachment_row(id(920), id(921), id(922), id(923), "note", id(924))
      )

      for version <- [id(921), id(923), id(931), id(933)], do: finalize_seal(version)

      insert_row("content.resource_tags", %{
        "resource_id" => id(930),
        "tag_id" => @ids.tag_id,
        "vault_id" => @ids.vault_id,
        "classification" => "private",
        "inserted_at" => timestamp()
      })

      insert_row("content.relationships", relationship_row(id(934), id(930), id(932), id(933)))
      force_ordinary_constraints()
    end)

    owner_transaction(fn ->
      for resource <- [id(920), id(922), id(930), id(932)],
          do:
            sql("UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id=$1", [
              dump(resource)
            ])
    end)
  end

  defp document_subset(all, source, resource, version) do
    subset(all, %{
      "content.resources" =>
        select(all, "content.resources", "id", [source.resource_id, resource]),
      "content.resource_versions" =>
        select(all, "content.resource_versions", "id", [source.resource_version_id, version]),
      "content.asset_objects" => select(all, "content.asset_objects", "id", [source.object_id]),
      "content.assets" => select(all, "content.assets", "id", [source.asset_id]),
      "content.asset_key_envelopes" =>
        select(all, "content.asset_key_envelopes", "asset_object_id", [source.object_id]),
      "content.resource_assets" =>
        select(all, "content.resource_assets", "asset_id", [source.asset_id]),
      "content.document_versions" =>
        select(all, "content.document_versions", "resource_version_id", [version]),
      "content.document_fragments" =>
        select(all, "content.document_fragments", "resource_version_id", [version]),
      "content.document_import_receipts" =>
        select(all, "content.document_import_receipts", "version_id", [version])
    })
  end

  defp note_subset(all, resources, versions, attachment) do
    subset(all, %{
      "content.resources" => select(all, "content.resources", "id", resources),
      "content.resource_versions" => select(all, "content.resource_versions", "id", versions),
      "content.note_versions" =>
        select(all, "content.note_versions", "resource_version_id", versions),
      "content.note_attachments" => select(all, "content.note_attachments", "id", [attachment])
    })
  end

  defp organization_subset(all) do
    subset(all, %{
      "content.resources" => select(all, "content.resources", "id", [id(930), id(932)]),
      "content.resource_versions" =>
        select(all, "content.resource_versions", "id", [id(931), id(933)]),
      "content.note_versions" =>
        select(all, "content.note_versions", "resource_version_id", [id(931), id(933)]),
      "content.tags" => all["content.tags"],
      "content.resource_tags" => select(all, "content.resource_tags", "resource_id", [id(930)]),
      "content.relationships" => select(all, "content.relationships", "id", [id(934)])
    })
  end

  defp subset(all, selected),
    do:
      Map.new(all, fn {table, rows} ->
        {table, if(table in @base_tables, do: rows, else: Map.get(selected, table, []))}
      end)

  defp select(rows, table, field, ids), do: Enum.filter(rows[table], &(&1[field] in ids))
  defp change_one(rows, table, fun), do: Map.update!(rows, table, fn [row] -> [fun.(row)] end)

  defp assert_restore_commits(source) do
    assert ordered_counts(source.expected) == Map.fetch!(@counts, source.name)

    with_destination(source, fn destination, bundle, storage ->
      assert {:ok, :committed} =
               owner_transaction(fn ->
                 staged = open_admission(source, bundle, storage)
                 insert_graph(source.rows)
                 # Deferred AFTER INSERT source checks must execute with loading authority.
                 assert_bound(true)
                 force_ordinary_constraints()
                 assert_bound(true)
                 assert_owned_summary(source.expected)
                 assert_seals(source.rows)

                 if source.name == :complete_history, do: assert_whole_history_graph()

                 assert :ok = KnowledgePreflight.validate_destination(MigrationRepo, staged)
                 assert_bound(false)

                 assert [["validated"]] ==
                          sql("SELECT state FROM audit.knowledge_restore_admissions").rows

                 sql(
                   "UPDATE audit.restore_import_sagas SET state='imported',imported_at=CURRENT_TIMESTAMP"
                 )

                 :committed
               end)

      owner_transaction(fn ->
        assert_owned_summary(source.expected)
        assert_seals(source.rows)
        assert_exclusions_empty()
        assert [["imported"]] == sql("SELECT state FROM audit.restore_import_sagas").rows
      end)

      refute destination.database == source.database
    end)
  end

  defp assert_whole_history_graph do
    payload =
      owned_graph_diagnostic(:payload, fn ->
        sql("""
        SELECT audit.knowledge_restore_payload_is_valid(e)
        FROM core.outbox_events e
        WHERE event_type='document.extraction_requested'
        """)
      end)

    assert payload.rows == [[true]]

    graph =
      owned_graph_diagnostic(:graph, fn ->
        sql("SELECT audit.assert_knowledge_restore_graph($1)", [dump(@ids.vault_id)])
      end)

    assert graph.num_rows == 1
  end

  defp owned_graph_diagnostic(step, fun) do
    sql("SAVEPOINT historical_graph_diagnostic")

    result =
      try do
        {:ok, fun.()}
      rescue
        error in Postgrex.Error ->
          {:error, Map.take(error.postgres, [:code, :pg_code, :message, :constraint])}
      end

    case result do
      {:ok, value} ->
        sql("RELEASE SAVEPOINT historical_graph_diagnostic")
        value

      {:error, diagnostic} ->
        sql("ROLLBACK TO SAVEPOINT historical_graph_diagnostic")
        sql("RELEASE SAVEPOINT historical_graph_diagnostic")
        flunk("whole-history #{step} diagnostic failed: #{inspect(diagnostic)}")
    end
  end

  defp open_admission(source, bundle, storage) do
    sql("SELECT pg_advisory_xact_lock(hashtextextended('singularity:restore-import:v1',0))")

    sql(
      """
      INSERT INTO audit.restore_import_sagas(singleton,manifest_id,vault_id,manifest_hash,manifest_tag,inventory_hash,destination_root_hash,object_count,state)
      VALUES(true,$1,$2,$3,$4,$5,$6,$7,'pending')
      """,
      [
        dump(bundle.cut.manifest_id),
        dump(bundle.cut.vault_id),
        bundle.verified.manifest_hash,
        bundle.verified.manifest_tag,
        :crypto.hash(
          :sha256,
          :erlang.term_to_binary(bundle.cut.object_inventory, [:deterministic])
        ),
        :crypto.hash(:sha256, Path.expand(storage.context.root)),
        length(bundle.cut.object_inventory)
      ]
    )

    assert {:ok, staged} =
             KnowledgePreflight.stage(MigrationRepo, bundle.verified, bundle.cut, storage)

    assert {:ok, expected} = KnowledgePreflight.validate(MigrationRepo, staged, bundle.cut)
    assert expected == source.expected
    assert {:ok, expected} = KnowledgePreflight.begin_restore(MigrationRepo, staged)
    assert expected == source.expected
    assert_bound(true)
    staged
  end

  defp insert_graph(rows) do
    sql("SET CONSTRAINTS ALL DEFERRED")
    [[dummy]] = sql("SELECT dummy_verifier FROM identity.security_settings WHERE singleton").rows

    for schema <- LogicalSchemaV3.all(), row <- rows[schema.table] do
      fields =
        Enum.map(schema.columns, fn column ->
          value =
            case {schema.table, column.name} do
              {"core.vaults", "locked"} -> true
              {"core.vaults", "object_cleanup_principal_id"} -> nil
              _ -> row[column.name]
            end

          {column.name, column.tag, value}
        end)

      fields =
        case schema.table do
          "identity.credentials" ->
            fields ++
              [
                {"verifier", "text", dummy},
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

      insert_fields(MigrationRepo, schema.table, fields)
    end

    # Match the established restore ordering: the immediate membership FK cannot
    # reference a cleanup principal until its membership has been inserted.
    # Restore the authenticated source value, not a transformed digest oracle.
    for vault <- rows["core.vaults"] do
      cleanup = vault["object_cleanup_principal_id"]

      assert %{num_rows: 1} =
               sql(
                 "UPDATE core.vaults SET object_cleanup_principal_id=$1 WHERE id=$2",
                 [parameter("uuid", cleanup), dump(vault["id"])]
               )

      assert [[parameter("uuid", cleanup)]] ==
               sql("SELECT object_cleanup_principal_id FROM core.vaults WHERE id=$1", [
                 dump(vault["id"])
               ]).rows
    end

    for note <- rows["content.note_versions"], do: finalize_seal(note["resource_version_id"])
  end

  defp insert_row(table, row, repo \\ MigrationRepo) do
    {:ok, schema} = LogicalSchemaV3.fetch_table(table)
    fields = Enum.map(schema.columns, &{&1.name, &1.tag, row[&1.name]})
    insert_fields(repo, table, fields)
  end

  defp insert_fields(repo, table, fields) do
    columns = Enum.map_join(fields, ",", fn {name, _, _} -> name end)

    placeholders =
      fields
      |> Enum.with_index(1)
      |> Enum.map_join(",", fn {{_, tag, _}, n} ->
        if tag == "json", do: "($#{n}::text)::jsonb", else: "$#{n}"
      end)

    Process.put({__MODULE__, :phase}, table)
    override_identity = if table == "core.outbox_events", do: " OVERRIDING SYSTEM VALUE", else: ""

    query(
      repo,
      "INSERT INTO #{table}(#{columns})#{override_identity} VALUES(#{placeholders})",
      Enum.map(fields, fn {_, tag, value} -> parameter(tag, value) end)
    )
  end

  defp seed_foreign_note do
    person = id(2000)
    account = id(2001)
    principal = id(2002)
    vault = id(2003)
    resource = id(2004)
    version = id(2005)

    assert {:ok, :committed} =
             owner_transaction(fn ->
               sql("INSERT INTO identity.people(id,display_name) VALUES($1,'Foreign owner')", [
                 dump(person)
               ])

               sql("INSERT INTO identity.accounts(id,person_id) VALUES($1,$2)", [
                 dump(account),
                 dump(person)
               ])

               sql("INSERT INTO identity.principals(id,account_id,kind) VALUES($1,$2,'owner')", [
                 dump(principal),
                 dump(account)
               ])

               sql("INSERT INTO core.vaults(id) VALUES($1)", [dump(vault)])

               sql("INSERT INTO core.vault_members(principal_id,vault_id) VALUES($1,$2)", [
                 dump(principal),
                 dump(vault)
               ])

               sql(
                 "INSERT INTO content.resources(id,vault_id,classification,kind,current_version_id,title) VALUES($1,$2,'private','note',$3,'Foreign Note')",
                 [dump(resource), dump(vault), dump(version)]
               )

               sql(
                 "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',0)",
                 [dump(version), dump(resource), dump(vault)]
               )

               sql(
                 "INSERT INTO content.note_versions(resource_version_id,resource_id,vault_id,classification,title,markdown,created_by_principal_id) VALUES($1,$2,$3,'private','Foreign Note','# Foreign Note',$4)",
                 [dump(version), dump(resource), dump(vault), dump(principal)]
               )

               finalize_seal(version)
               :committed
             end)

    assert {:ok, :verified} =
             owner_transaction(fn ->
               refute vault == @ids.vault_id

               assert [[dump(vault), dump(principal), "note", 0, 0]] ==
                        sql(
                          """
                          SELECT r.vault_id,n.created_by_principal_id,r.kind,s.attachment_count,s.citation_count
                          FROM content.resources r
                          JOIN content.resource_versions v ON (v.id,v.resource_id,v.vault_id,v.classification)=(r.current_version_id,r.id,r.vault_id,r.classification)
                          JOIN content.note_versions n ON (n.resource_version_id,n.resource_id,n.vault_id,n.classification)=(v.id,v.resource_id,v.vault_id,v.classification)
                          JOIN content.note_source_set_seals s ON (s.note_resource_version_id,s.note_resource_id,s.vault_id,s.classification)=(n.resource_version_id,n.resource_id,n.vault_id,n.classification)
                          JOIN core.vault_members m ON (m.principal_id,m.vault_id)=(n.created_by_principal_id,n.vault_id) AND m.revoked_at IS NULL
                          JOIN identity.principals p ON p.id=m.principal_id AND p.kind='owner' AND p.revoked_at IS NULL
                          JOIN identity.accounts a ON a.id=p.account_id AND a.status='active'
                          WHERE r.id=$1 AND v.id=$2 AND r.deleted_at IS NULL
                          """,
                          [dump(resource), dump(version)]
                        ).rows

               :verified
             end)

    {resource, version}
  end

  defp seed_runtime_identity(repo, resource, version, kind) do
    query(
      repo,
      "INSERT INTO content.resources(id,vault_id,classification,kind,current_version_id,title) VALUES($1,$2,'private',$3,$4,'Isolated history')",
      [dump(resource), dump(@ids.vault_id), kind, dump(version)]
    )

    query(
      repo,
      "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',0)",
      [dump(version), dump(resource), dump(@ids.vault_id)]
    )
  end

  defp seed_note_version(repo, resource, version),
    do:
      query(
        repo,
        "INSERT INTO content.note_versions(resource_version_id,resource_id,vault_id,classification,title,markdown,created_by_principal_id) VALUES($1,$2,$3,'private','Isolated history','# Isolated history',$4)",
        [dump(version), dump(resource), dump(@ids.vault_id), dump(@ids.principal_id)]
      )

  defp new_document_row(rows, source, resource, version) do
    template =
      Enum.find(
        rows["content.document_versions"],
        &(&1["resource_version_id"] == @ids.pending_version_id)
      )

    Map.merge(template, %{
      "resource_id" => resource,
      "resource_version_id" => version,
      "source_asset_id" => source.asset_id,
      "source_resource_id" => source.resource_id,
      "source_resource_version_id" => source.resource_version_id,
      "source_object_id" => source.object_id,
      "source_digest" => source.digest,
      "source_byte_size" => source.byte_size,
      "media_type" => "text/plain",
      "title" => "Isolated history"
    })
  end

  defp attachment_row(note, version, target, target_version, kind, member),
    do: %{
      "note_resource_version_id" => version,
      "id" => member,
      "note_resource_id" => note,
      "vault_id" => @ids.vault_id,
      "classification" => "private",
      "target_resource_id" => target,
      "target_resource_version_id" => target_version,
      "target_kind" => kind,
      "ordinal" => 0,
      "role" => "source",
      "label" => nil,
      "inserted_at" => timestamp()
    }

  defp citation_row(note, version, fragment, member),
    do: %{
      "note_resource_version_id" => version,
      "id" => member,
      "note_resource_id" => note,
      "vault_id" => @ids.vault_id,
      "classification" => "private",
      "source_resource_id" => fragment["resource_id"],
      "source_resource_version_id" => fragment["resource_version_id"],
      "fragment_id" => fragment["id"],
      "locator" => fragment["locator"],
      "ordinal" => 0,
      "inserted_at" => timestamp()
    }

  defp relationship_row(member, source, target, version),
    do: %{
      "id" => member,
      "vault_id" => @ids.vault_id,
      "classification" => "private",
      "source_resource_id" => source,
      "target_resource_id" => target,
      "target_resource_version_id" => version,
      "type" => "references",
      "created_by_principal_id" => @ids.principal_id,
      "inserted_at" => timestamp()
    }

  defp fragment_row(document, ordinal, text) do
    {:ok, fragment} =
      DocumentFragment.new(%{
        resource_id: document["resource_id"],
        resource_version_id: document["resource_version_id"],
        owner_scope_id: document["vault_id"],
        classification: :private,
        ordinal: ordinal,
        text: text,
        locator: %{"version" => 1, "kind" => "fragment", "ordinal" => ordinal}
      })

    %{
      "id" => fragment.fragment_id,
      "resource_id" => document["resource_id"],
      "resource_version_id" => document["resource_version_id"],
      "vault_id" => document["vault_id"],
      "classification" => "private",
      "ordinal" => ordinal,
      "text" => text,
      "digest" => fragment.digest,
      "locator" => %{"version" => 1, "kind" => "fragment", "ordinal" => ordinal},
      "inserted_at" => timestamp()
    }
  end

  defp assert_statement_rejected(constraint, phase, fun, code \\ :check_violation) do
    Process.put({__MODULE__, :phase}, :setup)
    Process.put({__MODULE__, :returned}, false)

    error =
      assert_raise Postgrex.Error, fn ->
        owner_transaction(fn ->
          fun.()
          Process.put({__MODULE__, :returned}, true)
        end)
      end

    assert error.postgres.code == code
    assert error.postgres.constraint == constraint
    assert Process.get({__MODULE__, :phase}) == phase
    refute Process.get({__MODULE__, :returned})
    Process.delete({__MODULE__, :phase})
    Process.delete({__MODULE__, :returned})
  end

  defp assert_commit_rejected(message, fun) do
    Process.put({__MODULE__, :returned}, false)

    error =
      assert_raise Postgrex.Error, fn ->
        owner_transaction(fn ->
          fun.()
          Process.put({__MODULE__, :returned}, true)
          :returned_normally
        end)
      end

    assert Process.get({__MODULE__, :returned}),
           "the callback must return normally before actual COMMIT rejection"

    assert error.postgres.code == :check_violation
    assert error.postgres.message == message
    assert error.postgres.where =~ "enforce_knowledge_restore_final"
    Process.delete({__MODULE__, :returned})
  end

  defp runtime_rejected(repo, constraint, phase, fun) do
    Process.put({__MODULE__, :phase}, :setup)
    Process.put({__MODULE__, :returned}, false)

    error =
      assert_raise Postgrex.Error, fn ->
        repo.transaction(fn ->
          query(repo, "SET CONSTRAINTS ALL DEFERRED")
          scope(repo)

          query(
            repo,
            "SELECT set_config('singularity.knowledge_restore_admitted','true',true),set_config('singularity.document_lifecycle','on',true)"
          )

          fun.()
          Process.put({__MODULE__, :returned}, true)
        end)
      end

    diagnostic = %{
      role:
        Enum.find_value(runtime_repos(), fn {candidate, role} ->
          if candidate == repo, do: role
        end),
      phase: Process.get({__MODULE__, :phase}),
      postgres: Map.take(error.postgres, [:code, :message, :schema, :table, :constraint, :where])
    }

    assert error.postgres.code == :check_violation,
           "runtime guard probe failed: #{inspect(diagnostic)}"

    assert error.postgres.constraint == constraint
    assert Process.get({__MODULE__, :phase}) == phase
    refute Process.get({__MODULE__, :returned})
    Process.delete({__MODULE__, :phase})
    Process.delete({__MODULE__, :returned})
  end

  defp with_runtime_permissions(fun) do
    # Temporary privileges only in an allocated disposable database, restored to
    # their exact prior grant matrix. They expose enforced guards, not an ACL miss.
    tables = ~w(content.resources content.resource_versions content.note_versions
      content.document_versions content.document_fragments content.note_attachments
      content.note_citations content.resource_tags content.relationships)

    permissions =
      for {_repo, role} <- runtime_repos(),
          table <- tables,
          privilege <- ~w(SELECT INSERT UPDATE DELETE),
          do: {role, table, privilege}

    # The invoker BEFORE INSERT guard reads seals even for an unsealed source.
    # Let Worker reach it without changing its default-deny forced-RLS policy.
    permissions =
      permissions ++ [{"singularity_worker", "content.note_source_set_seals", "SELECT"}]

    {:ok, existing} =
      owner_transaction(fn ->
        [[database]] = sql("SELECT current_database()").rows
        assert database =~ ~r/\Asingularity_test_[0-9a-f]{24}\z/

        Map.new(permissions, fn {role, table, privilege} = permission ->
          [[allowed]] = sql("SELECT has_table_privilege($1,$2,$3)", [role, table, privilege]).rows
          sql("GRANT #{privilege} ON #{table} TO #{role}")
          {permission, allowed}
        end)
      end)

    try do
      fun.()
    after
      owner_transaction(fn ->
        for {{role, table, privilege}, false} <- existing,
            do: sql("REVOKE #{privilege} ON #{table} FROM #{role}")

        for {{role, table, privilege}, allowed} <- existing,
            do:
              assert(
                [[allowed]] ==
                  sql("SELECT has_table_privilege($1,$2,$3)", [role, table, privilege]).rows
              )
      end)
    end
  end

  defp with_fixture(fun),
    do:
      KnowledgeBackupFixtures.with_destination(:current, fn destination ->
        fixture =
          KnowledgeBackupFixtures.seed!(
            Map.merge(destination, %{ids: @ids, originals: @originals})
          )

        fun.(fixture)
      end)

  defp with_destination(source, fun) do
    KnowledgeBackupFixtures.with_destination(:current, fn destination ->
      refute destination.database == source.database
      storage = private_storage(destination, "historical-private")

      assert {:ok, reader} =
               LocalDestination.reader_source(%{backup_root: source.portable}, source.filename)

      context = %{
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
                 crypto: {FixtureCrypto, context},
                 verifier: {LogicalBundleVerifier, source.binding}
               )

      assert %BundleReader.Verified{records: [], replay: %BundleReader.Replay{}} = verified

      try do
        fun.(
          destination,
          %{verified: verified, cut: verified.cut, binding: source.binding},
          storage
        )
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

  defp assert_owned_summary(expected) do
    for schema <- LogicalSchemaV3.all(),
        do:
          assert(
            [[expected.counts[schema.table], expected.digests[schema.table]]] ==
              sql("SELECT row_count,digest FROM audit.knowledge_restore_table_digest($1)", [
                schema.ordinal
              ]).rows
          )
  end

  defp assert_seals(rows) do
    expected =
      rows["content.note_versions"]
      |> Enum.map(fn note ->
        version = note["resource_version_id"]

        [
          version,
          note["resource_id"],
          note["vault_id"],
          "private",
          Enum.count(
            rows["content.note_attachments"],
            &(&1["note_resource_version_id"] == version)
          ),
          Enum.count(rows["content.note_citations"], &(&1["note_resource_version_id"] == version))
        ]
      end)
      |> Enum.sort()

    assert expected ==
             sql(
               "SELECT note_resource_version_id::text,note_resource_id::text,vault_id::text,classification,attachment_count,citation_count FROM content.note_source_set_seals ORDER BY note_resource_version_id"
             ).rows
  end

  defp force_ordinary_constraints do
    assert length(@ordinary_constraints) == 32
    Process.put({__MODULE__, :phase}, :ordinary_constraints)

    sql(
      "SET CONSTRAINTS #{Enum.map_join(@ordinary_constraints, ",", &("content." <> &1))} IMMEDIATE"
    )
  end

  defp finalize_seal(version) do
    Process.put({__MODULE__, :phase}, :seal)
    sql("SELECT content.finalize_note_source_set($1)", [dump(version)])
  end

  defp assert_bound(expected),
    do:
      assert(
        [[expected]] ==
          sql("SELECT audit.knowledge_restore_is_bound($1)", [dump(@ids.vault_id)]).rows
      )

  defp assert_exclusions_empty do
    assert length(@excluded) == 12
    assert @excluded == Enum.uniq(@excluded)
    refute "content.knowledge_mutation_receipts" in @excluded

    for table <- @excluded do
      assert [[true]] == sql("SELECT to_regclass($1) IS NOT NULL", [table]).rows,
             "required excluded relation missing: #{table}"

      assert [[0]] == sql("SELECT count(*) FROM #{table}").rows
    end

    # This optional compatibility name is absent in the released schema. As in
    # the Task5 oracle, prove catalog absence or, if present, that it stays empty.
    case sql("SELECT to_regclass('content.knowledge_mutation_receipts')::text").rows do
      [[nil]] ->
        :absent

      [["content.knowledge_mutation_receipts"]] ->
        assert [[0]] == sql("SELECT count(*) FROM content.knowledge_mutation_receipts").rows
    end
  end

  defp assert_no_import do
    owner_transaction(fn ->
      for schema <- LogicalSchemaV3.all(),
          do: assert([[0]] == sql("SELECT count(*) FROM #{schema.table}").rows)

      assert [[0]] == sql("SELECT count(*) FROM content.note_source_set_seals").rows
      assert [[0]] == sql("SELECT count(*) FROM audit.knowledge_restore_admissions").rows
      assert [[0]] == sql("SELECT count(*) FROM audit.restore_import_sagas").rows
      assert_exclusions_empty()
    end)
  end

  defp scope(repo),
    do:
      query(
        repo,
        "SELECT set_config('singularity.vault_id',$1,true),set_config('singularity.principal_id',$2,true)",
        [@ids.vault_id, @ids.principal_id]
      )

  defp runtime_repos,
    do: [
      {Singularity.Storage.RequestRepo, "singularity_web"},
      {Singularity.Storage.WorkerRepo, "singularity_worker"}
    ]

  defp owner_transaction(fun),
    do:
      MigrationRepo.transaction(fn ->
        sql("SET LOCAL ROLE singularity_table_owner")
        fun.()
      end)

  defp query(repo, statement, params \\ []),
    do: Ecto.Adapters.SQL.query!(repo, statement, params, log: false)

  defp sql(statement, params \\ []), do: query(MigrationRepo, statement, params)
  defp ordered_counts(summary), do: Enum.map(LogicalSchemaV3.all(), &summary.counts[&1.table])
  defp parameter(_tag, nil), do: nil
  defp parameter("uuid", value), do: dump(value)
  defp parameter("json", value), do: Jason.encode!(value)

  defp parameter("timestamp", value) do
    {:ok, time, 0} = DateTime.from_iso8601(value)
    time
  end

  defp parameter(_tag, value), do: value
  defp timestamp, do: "2026-10-11T00:00:00.000000Z"
  defp dump(value), do: Ecto.UUID.dump!(value)
  defp id(n), do: "60000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")
end
