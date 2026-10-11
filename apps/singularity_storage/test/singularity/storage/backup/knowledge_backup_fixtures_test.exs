defmodule Singularity.Storage.Backup.KnowledgeBackupFixturesTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Singularity.Core.DocumentFragment
  alias Singularity.Core.Error
  alias Singularity.Storage.{Fixtures, MigrationRepo}
  alias Singularity.Storage.Backup.{BundleReader, LogicalBundleVerifier, LogicalRecordCodec}
  alias Singularity.Storage.Backup.{LogicalSchemaV2, LogicalSchemaV3}
  alias Singularity.Storage.Crypto.{ChunkedAEAD, Format, KeyWrapper}
  alias Singularity.Storage.Local.PathGuard

  @fixtures Singularity.Storage.Backup.KnowledgeBackupFixtures
  @originals %{
    pdf: "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n",
    pdf_duplicate: "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n",
    empty: "",
    plain: "plain original\r\nsecond line\n",
    unicode: "界🙂 café\n",
    markdown: "# Original Markdown\n\n[source](https://example.test/)\n"
  }
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
       |> Map.new(fn {name, index} ->
         {name,
          "50000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(index), 12, "0")}
       end)
  @appended [
    {"content.document_versions",
     ~w(resource_version_id resource_id vault_id classification source_asset_id source_resource_id source_resource_version_id source_object_id source_digest source_byte_size media_type title created_by_principal_id state attempt_generation extraction_adapter extraction_format extracted_text_digest detected_language failure_code attempt_finished_at inserted_at attempt_job_id attempt_started_at attempt_deadline_at),
     ~w(resource_version_id)},
    {"content.document_fragments",
     ~w(id resource_id resource_version_id vault_id classification ordinal text digest locator inserted_at),
     ~w(id)},
    {"content.document_import_receipts",
     ~w(vault_id principal_id mutation_id request_fingerprint state resource_id version_id inserted_at),
     ~w(vault_id principal_id mutation_id)},
    {"content.note_attachments",
     ~w(note_resource_version_id id note_resource_id vault_id classification target_resource_id target_resource_version_id target_kind ordinal role label inserted_at),
     ~w(note_resource_version_id id)},
    {"content.note_citations",
     ~w(note_resource_version_id id note_resource_id vault_id classification source_resource_id source_resource_version_id fragment_id locator ordinal inserted_at),
     ~w(note_resource_version_id id)},
    {"content.tags",
     ~w(id vault_id classification display_value normalized_key created_by_principal_id inserted_at),
     ~w(id)},
    {"content.resource_tags", ~w(resource_id tag_id vault_id classification inserted_at),
     ~w(resource_id tag_id vault_id)},
    {"content.relationships",
     ~w(id vault_id classification source_resource_id target_resource_id target_resource_version_id type created_by_principal_id inserted_at),
     ~w(id)}
  ]
  @excluded ~w(identity.sessions content.note_source_set_seals content.search_entries
               content.note_search_documents content.note_mutation_receipts
               content.knowledge_mutation_receipts jobs.oban_jobs jobs.oban_peers
               audit.restore_import_sagas)
  @repos [
    MigrationRepo,
    Singularity.Storage.RequestRepo,
    Singularity.Storage.PreAuthRepo,
    Singularity.Storage.DispatcherRepo,
    Singularity.Storage.WorkerRepo
  ]

  test "the fixture support exposes every bounded test-only seam without compile-time stubs" do
    assert Code.ensure_loaded?(@fixtures), "missing independent KnowledgeBackupFixtures support"

    for {name, arity} <- [
          seed!: 1,
          canonical_rows: 1,
          source_bytes: 1,
          search_rows: 1,
          verified_bundle: 2,
          malformed_bundle: 2,
          with_destination: 2
        ] do
      assert function_exported?(@fixtures, name, arity), "missing #{name}/#{arity} fixture seam"
    end
  end

  test "destination allocation restores caller rows configs services and owned root on return and throw" do
    assert Code.ensure_loaded?(@fixtures), "missing independent KnowledgeBackupFixtures support"
    before = caller_state()

    assert :returned =
             call(:with_destination, [
               :current,
               fn destination ->
                 assert_destination(destination, before)
                 fixture = seed(destination)
                 assert fixture.ids == @ids

                 send(
                   self(),
                   {:normal_destination, destination.database, destination.object_root}
                 )

                 :returned
               end
             ])

    assert_receive {:normal_destination, database, root}
    assert caller_state() == before
    refute File.exists?(root)
    refute File.exists?(String.replace_suffix(root, "/objects", ""))
    refute database_exists?(database)

    assert catch_throw(
             call(:with_destination, [
               :current,
               fn destination ->
                 assert_destination(destination, before)
                 _fixture = seed(destination)

                 send(
                   self(),
                   {:thrown_destination, destination.database, destination.object_root}
                 )

                 throw(:fixture_abort)
               end
             ])
           ) == :fixture_abort

    assert_receive {:thrown_destination, thrown_database, thrown_root}
    assert caller_state() == before
    refute File.exists?(thrown_root)
    refute File.exists?(String.replace_suffix(thrown_root, "/objects", ""))
    refute database_exists?(thrown_database)
  end

  test "the complete established owner key graph and actual object evidence agree with literal originals" do
    with_fixture(fn fixture ->
      rows = direct_canonical_rows(fixture)

      assert [%{"id" => account, "status" => "active", "person_id" => person}] =
               rows["identity.accounts"]

      assert account == @ids.account_id
      assert Enum.any?(rows["identity.people"], &(&1["id"] == person))

      assert Enum.any?(
               rows["identity.credentials"],
               &(&1["account_id"] == account and is_nil(&1["revoked_at"]))
             )

      assert Enum.any?(
               rows["identity.principals"],
               &(&1["id"] == @ids.principal_id and &1["account_id"] == account and
                   &1["kind"] == "owner")
             )

      assert [%{"id" => vault, "object_cleanup_principal_id" => cleanup}] = rows["core.vaults"]
      assert vault == @ids.vault_id

      assert Enum.any?(
               rows["identity.principals"],
               &(&1["id"] == cleanup and &1["kind"] == "system")
             )

      assert Enum.any?(
               rows["core.vault_members"],
               &(&1["principal_id"] == @ids.principal_id and is_nil(&1["revoked_at"]))
             )

      cleanup_capability = Enum.find(rows["core.capabilities"], &(&1["name"] == "object.cleanup"))
      assert %{"id" => cleanup_capability_id} = cleanup_capability

      assert Enum.any?(
               rows["core.principal_capabilities"],
               &(&1["principal_id"] == cleanup and &1["capability_id"] == cleanup_capability_id and
                   is_nil(&1["revoked_at"]))
             )

      assert rows["core.vault_key_versions"] != []
      assert rows["core.vault_key_wrappers"] != []
      assert rows["core.domain_key_versions"] != []
      assert rows["core.domain_dedup_key_wrappers"] != []

      for wrapper <- rows["core.vault_key_wrappers"] do
        assert wrapper["account_id"] == account

        assert Enum.any?(
                 rows["core.vault_key_versions"],
                 &(&1["id"] == wrapper["vault_key_version_id"])
               )
      end

      for version <- rows["core.domain_key_versions"] do
        assert Enum.any?(
                 rows["core.vault_key_versions"],
                 &(&1["id"] == version["vault_key_version_id"])
               )

        assert Enum.any?(rows["core.key_domains"], &(&1["id"] == version["key_domain_id"]))
      end

      for wrapper <- rows["core.domain_dedup_key_wrappers"] do
        assert Enum.any?(
                 rows["core.domain_key_versions"],
                 &(&1["id"] == wrapper["domain_key_version_id"] and
                     &1["key_domain_id"] == wrapper["key_domain_id"])
               )
      end

      originals = call(:source_bytes, [fixture])

      assert Enum.sort(Enum.map(rows["content.asset_objects"], & &1["id"])) ==
               Enum.sort(Map.keys(originals))

      for object <- rows["content.asset_objects"] do
        assert object["lifecycle"] == "available"
        assert object["format_version"] == 1
        assert object["plaintext_byte_size"] == byte_size(Map.fetch!(originals, object["id"]))
        assert byte_size(object["lookup_digest"]) == 32
        assert byte_size(object["ciphertext_hash"]) == 32
        assert Enum.any?(rows["core.key_domains"], &(&1["id"] == object["key_domain_id"]))

        envelopes =
          Enum.filter(
            rows["content.asset_key_envelopes"],
            &(&1["asset_object_id"] == object["id"])
          )

        assert envelopes != []

        for envelope <- envelopes do
          assert envelope["key_domain_id"] == object["key_domain_id"]

          assert Enum.any?(
                   rows["core.domain_key_versions"],
                   &(&1["id"] == envelope["domain_key_version_id"] and
                       &1["key_domain_id"] == envelope["key_domain_id"])
                 )
        end

        assert {:ok, path} =
                 PathGuard.object_path(
                   fixture.destination.object_root,
                   fixture.owner.vault_id,
                   object["key_domain_id"],
                   Base.encode16(object["lookup_digest"], case: :lower)
                 )

        ciphertext = File.read!(path)
        assert byte_size(ciphertext) == object["ciphertext_byte_size"]
        assert :crypto.hash(:sha256, ciphertext) == object["ciphertext_hash"]
      end

      assert owner_query(fn ->
               query(
                 "SELECT account_id::text,principal_id::text,vault_id::text FROM identity.sessions WHERE id=$1",
                 [dump(@ids.session_id)]
               ).rows
             end) ==
               [[@ids.account_id, @ids.principal_id, @ids.vault_id]]
    end)
  end

  test "persisted wrapper chain uses real consumer AADs and decrypts all five literal originals" do
    with_fixture(fn fixture ->
      before = direct_canonical_rows(fixture)
      owner = fixture.owner
      assert [vault_wrapper] = before["core.vault_key_wrappers"]
      assert vault_wrapper["generation"] == 1

      # The frozen logical projection omits this persisted ciphertext. Read it
      # directly rather than substituting the helper's raw hierarchy keys.
      assert [[wrapped_vault_key]] =
               owner_query(fn ->
                 query(
                   "SELECT wrapped_key FROM core.vault_key_wrappers WHERE id=$1 AND vault_id=$2 AND account_id=$3",
                   [dump(vault_wrapper["id"]), dump(owner.vault_id), dump(owner.account_id)]
                 ).rows
               end)

      vault_metadata = %{purpose: :vault_key, generation: 1, aad: owner.vault_id}

      assert {:ok, vault_key} =
               KeyWrapper.unwrap(fixture.keys.password_key, wrapped_vault_key, vault_metadata)

      assert byte_size(vault_key) == 32

      assert KeyWrapper.unwrap(
               fixture.keys.password_key,
               wrapped_vault_key,
               %{vault_metadata | aad: owner.vault_id <> ":wrong"}
             ) == {:error, Error.new(:integrity_failure)}

      assert [domain] = before["core.domain_key_versions"]
      assert domain["vault_key_version_id"] == vault_wrapper["vault_key_version_id"]

      domain_metadata = %{
        purpose: :domain_key,
        generation: domain["generation"],
        aad: owner.vault_id <> ":" <> domain["key_domain_id"]
      }

      assert {:ok, domain_key} =
               KeyWrapper.unwrap(vault_key, domain["wrapped_key"], domain_metadata)

      assert byte_size(domain_key) == 32

      assert KeyWrapper.unwrap(
               vault_key,
               domain["wrapped_key"],
               %{domain_metadata | aad: domain["key_domain_id"]}
             ) == {:error, Error.new(:integrity_failure)}

      assert [dedup_wrapper] = before["core.domain_dedup_key_wrappers"]
      assert dedup_wrapper["domain_key_version_id"] == domain["id"]
      assert dedup_wrapper["key_domain_id"] == domain["key_domain_id"]

      dedup_metadata = %{
        purpose: :domain_dedup_key,
        generation: domain["generation"],
        aad: dedup_wrapper["key_domain_id"]
      }

      assert {:ok, dedup_key} =
               KeyWrapper.unwrap(domain_key, dedup_wrapper["wrapped_key"], dedup_metadata)

      assert byte_size(dedup_key) == 32

      assert KeyWrapper.unwrap(
               domain_key,
               dedup_wrapper["wrapped_key"],
               %{dedup_metadata | aad: owner.vault_id <> ":" <> dedup_wrapper["key_domain_id"]}
             ) == {:error, Error.new(:integrity_failure)}

      expected = %{
        @ids.pdf_object_id => @originals.pdf,
        @ids.empty_object_id => @originals.empty,
        @ids.plain_object_id => @originals.plain,
        @ids.unicode_object_id => @originals.unicode,
        @ids.markdown_object_id => @originals.markdown
      }

      objects = before["content.asset_objects"]
      assert length(objects) == 5
      assert Enum.sort(Enum.map(objects, & &1["id"])) == Enum.sort(Map.keys(expected))

      decrypted =
        Map.new(objects, fn object ->
          assert object["key_domain_id"] == domain["key_domain_id"]

          assert [envelope] =
                   Enum.filter(
                     before["content.asset_key_envelopes"],
                     &(&1["asset_object_id"] == object["id"])
                   )

          assert envelope["domain_key_version_id"] == domain["id"]
          assert envelope["key_domain_id"] == domain["key_domain_id"]

          object_metadata = %{
            purpose: :object_dek,
            generation: envelope["key_generation"],
            aad: "object:" <> object["id"]
          }

          assert {:ok, dek} =
                   KeyWrapper.unwrap(domain_key, envelope["wrapped_dek"], object_metadata)

          assert byte_size(dek) == 32

          assert KeyWrapper.unwrap(
                   domain_key,
                   envelope["wrapped_dek"],
                   %{object_metadata | aad: "object:" <> object["id"] <> ":wrong"}
                 ) == {:error, Error.new(:integrity_failure)}

          assert {:ok, path} =
                   PathGuard.object_path(
                     fixture.destination.object_root,
                     owner.vault_id,
                     object["key_domain_id"],
                     Base.encode16(object["lookup_digest"], case: :lower)
                   )

          ciphertext = File.read!(path)
          assert byte_size(ciphertext) == object["ciphertext_byte_size"]
          assert :crypto.hash(:sha256, ciphertext) == object["ciphertext_hash"]

          context = %{
            key: dek,
            vault_id: owner.vault_id,
            encryption_domain_id: object["key_domain_id"],
            object_id: object["id"],
            chunk_index: 0,
            algorithm: Format.algorithm(),
            format_version: Format.format_version(),
            chunk_size: Format.chunk_size()
          }

          assert object["format_version"] == context.format_version
          assert {:ok, plaintext} = ChunkedAEAD.decode(ciphertext, context)
          assert plaintext == Map.fetch!(expected, object["id"])
          assert byte_size(plaintext) == object["plaintext_byte_size"]
          digest = :crypto.hash(:sha256, plaintext)
          assert digest == :crypto.hash(:sha256, Map.fetch!(expected, object["id"]))
          assert object["lookup_digest"] == :crypto.mac(:hmac, :sha256, dedup_key, digest)

          assert ChunkedAEAD.decode(ciphertext, %{context | vault_id: @ids.account_id}) ==
                   {:error, :integrity_failure}

          {object["id"], plaintext}
        end)

      assert decrypted == expected
      assert call(:source_bytes, [fixture]) == expected
      assert direct_canonical_rows(fixture) == before
    end)
  end

  test "legal Note history preserves both conflict states lower parents merge ancestry and tombstones" do
    with_fixture(fn fixture ->
      rows = direct_canonical_rows(fixture)
      assert call(:canonical_rows, [fixture]) == rows

      expected =
        [
          {@ids.initial_note_version_id, 0, nil, nil, "# Initial fixture\n"},
          {@ids.canonical_note_version_id, 1, @ids.initial_note_version_id, nil,
           "# Canonical fixture\n"},
          {@ids.competing_note_version_id, 2, @ids.initial_note_version_id, nil,
           "# Competing fixture\n"},
          {@ids.merge_note_version_id, 3, @ids.canonical_note_version_id,
           @ids.competing_note_version_id, "# Merged fixture\n"},
          {@ids.open_competing_note_version_id, 4, @ids.canonical_note_version_id, nil,
           "# Open competing fixture\n"},
          {@ids.deleted_note_version_id, 0, nil, nil, "# Deleted fixture\n"}
        ]
        |> Enum.sort()

      actual =
        Enum.map(rows["content.note_versions"], fn note ->
          version =
            Enum.find(
              rows["content.resource_versions"],
              &(&1["id"] == note["resource_version_id"])
            )

          {note["resource_version_id"], version["revision"], note["parent_version_id"],
           note["merge_parent_version_id"], note["markdown"]}
        end)
        |> Enum.sort()

      assert actual == expected

      assert [
               %{
                 "id" => resolved,
                 "state" => "resolved",
                 "resolution_version_id" => merge,
                 "base_version_id" => initial,
                 "canonical_version_id" => canonical,
                 "competing_version_id" => competing,
                 "resolved_at" => resolved_at
               },
               %{
                 "id" => open,
                 "state" => "open",
                 "resolution_version_id" => nil,
                 "base_version_id" => canonical,
                 "canonical_version_id" => merge,
                 "competing_version_id" => open_competing,
                 "resolved_at" => nil
               }
             ] =
               rows["content.note_conflicts"]

      assert {resolved, open, initial, canonical, competing, merge, open_competing} ==
               {@ids.resolved_conflict_id, @ids.open_conflict_id, @ids.initial_note_version_id,
                @ids.canonical_note_version_id, @ids.competing_note_version_id,
                @ids.merge_note_version_id, @ids.open_competing_note_version_id}

      assert is_binary(resolved_at)

      assert %{"current_version_id" => head, "deleted_at" => nil} =
               resource(rows, @ids.live_note_id)

      assert head == @ids.merge_note_version_id

      assert %{"current_version_id" => deleted_head, "deleted_at" => deleted_at} =
               resource(rows, @ids.deleted_note_id)

      assert deleted_head == @ids.deleted_note_version_id
      assert is_binary(deleted_at)
    end)
  end

  test "every Document state and historical head has independently canonical fragment evidence" do
    with_fixture(fn fixture ->
      rows = direct_canonical_rows(fixture)
      documents = rows["content.document_versions"]

      expected_states = %{
        @ids.ready_old_version_id => "ready",
        @ids.ready_current_version_id => "ready",
        @ids.deleted_document_version_id => "ready",
        @ids.pending_version_id => "pending",
        @ids.extracting_version_id => "extracting",
        @ids.failed_version_id => "failed",
        @ids.unsupported_version_id => "unsupported"
      }

      assert Map.new(documents, &{&1["resource_version_id"], &1["state"]}) == expected_states

      assert resource(rows, @ids.ready_document_id)["current_version_id"] ==
               @ids.ready_current_version_id

      assert is_binary(resource(rows, @ids.deleted_document_id)["deleted_at"])

      for document <- documents do
        fragments =
          rows["content.document_fragments"]
          |> Enum.filter(&(&1["resource_version_id"] == document["resource_version_id"]))
          |> Enum.sort_by(& &1["ordinal"])

        case document["state"] do
          "ready" ->
            assert Enum.map(fragments, & &1["ordinal"]) == [0, 1]
            assert Enum.map(fragments, & &1["text"]) == ["first\n", "界🙂"]
            assert document["extracted_text_digest"] == :crypto.hash(:sha256, "first\n界🙂")
            assert is_binary(document["attempt_finished_at"])

            for fragment <- fragments do
              assert {:ok, canonical} =
                       DocumentFragment.new(%{
                         resource_id: fragment["resource_id"],
                         resource_version_id: fragment["resource_version_id"],
                         owner_scope_id: fixture.owner.vault_id,
                         classification: :private,
                         ordinal: fragment["ordinal"],
                         text: fragment["text"],
                         locator: fragment["locator"]
                       })

              assert fragment["id"] == canonical.fragment_id
              assert fragment["digest"] == :crypto.hash(:sha256, fragment["text"])
            end

          "pending" ->
            assert fragments == []
            assert document["attempt_generation"] == 0

            assert Enum.all?(
                     ~w(attempt_job_id attempt_started_at attempt_deadline_at attempt_finished_at
                               extracted_text_digest extraction_adapter extraction_format failure_code),
                     &is_nil(document[&1])
                   )

          "extracting" ->
            assert fragments == []
            assert document["attempt_generation"] == 1

            assert Enum.all?(
                     ~w(attempt_job_id attempt_started_at attempt_deadline_at extraction_adapter),
                     &is_binary(document[&1])
                   )

            assert document["extraction_format"] == 1
            assert document["attempt_finished_at"] == nil
            assert document["extracted_text_digest"] == nil

          terminal when terminal in ["failed", "unsupported"] ->
            assert fragments == []
            assert document["attempt_generation"] == 1
            assert is_binary(document["attempt_finished_at"])
            assert is_binary(document["failure_code"])
            assert document["extracted_text_digest"] == nil
        end
      end
    end)
  end

  test "literal originals deduplicate yet survive Asset release pointer clearing and Document tombstones" do
    with_fixture(fn fixture ->
      assert Map.keys(fixture.sources) |> Enum.sort() == Map.keys(@originals) |> Enum.sort()

      expected_objects = %{
        @ids.pdf_object_id => @originals.pdf,
        @ids.empty_object_id => @originals.empty,
        @ids.plain_object_id => @originals.plain,
        @ids.unicode_object_id => @originals.unicode,
        @ids.markdown_object_id => @originals.markdown
      }

      assert call(:source_bytes, [fixture]) == expected_objects
      assert fixture.sources.pdf.object_id == @ids.pdf_object_id
      assert fixture.sources.pdf_duplicate.object_id == @ids.pdf_object_id
      refute fixture.sources.pdf.asset_id == fixture.sources.pdf_duplicate.asset_id
      rows = direct_canonical_rows(fixture)

      for name <- [:pdf, :pdf_duplicate] do
        source = Map.fetch!(fixture.sources, name)
        asset = Enum.find(rows["content.assets"], &(&1["id"] == source.asset_id))
        assert asset["state"] == "deleted"
        assert asset["asset_object_id"] == nil
        assert is_binary(resource(rows, source.resource_id)["deleted_at"])

        association =
          Enum.find(rows["content.resource_assets"], fn row ->
            row["asset_id"] == source.asset_id and
              row["resource_version_id"] == source.resource_version_id
          end)

        assert is_binary(association["released_at"])
      end

      retained =
        Enum.filter(rows["content.document_versions"], fn row ->
          row["resource_version_id"] in [
            @ids.ready_old_version_id,
            @ids.ready_current_version_id,
            @ids.deleted_document_version_id
          ]
        end)

      assert Enum.map(retained, & &1["source_object_id"]) == List.duplicate(@ids.pdf_object_id, 3)

      for document <- rows["content.document_versions"] do
        bytes = Map.fetch!(expected_objects, document["source_object_id"])
        assert document["source_digest"] == :crypto.hash(:sha256, bytes)
        assert document["source_byte_size"] == byte_size(bytes)
      end

      before = call(:canonical_rows, [fixture])
      assert call(:source_bytes, [fixture]) == expected_objects
      assert call(:canonical_rows, [fixture]) == before
    end)
  end

  test "exact sealed source membership completed receipts and organization rows form a legal graph" do
    with_fixture(fn fixture ->
      rows = direct_canonical_rows(fixture)

      expected_counts = %{
        @ids.initial_note_version_id => {0, 0},
        @ids.canonical_note_version_id => {1, 0},
        @ids.competing_note_version_id => {0, 1},
        @ids.merge_note_version_id => {1, 1},
        @ids.open_competing_note_version_id => {1, 0},
        @ids.deleted_note_version_id => {1, 1}
      }

      seals =
        owner_query(fn ->
          query(
            "SELECT note_resource_version_id::text,attachment_count,citation_count FROM content.note_source_set_seals WHERE vault_id=$1 ORDER BY note_resource_version_id",
            [dump(fixture.owner.vault_id)]
          ).rows
        end)

      assert Map.new(seals, fn [version, attached, cited] -> {version, {attached, cited}} end) ==
               expected_counts

      for {version, {attached, cited}} <- expected_counts do
        attachments =
          Enum.filter(
            rows["content.note_attachments"],
            &(&1["note_resource_version_id"] == version)
          )

        citations =
          Enum.filter(
            rows["content.note_citations"],
            &(&1["note_resource_version_id"] == version)
          )

        assert Enum.sort(Enum.map(attachments, & &1["ordinal"])) == ordinals(attached)
        assert Enum.sort(Enum.map(citations, & &1["ordinal"])) == ordinals(cited)

        for attachment <- attachments do
          assert attachment["role"] == "source"

          assert {attachment["target_resource_id"], attachment["target_resource_version_id"],
                  attachment["target_kind"]} in [
                   {fixture.sources.pdf.resource_id, fixture.sources.pdf.resource_version_id,
                    "asset"},
                   {@ids.deleted_document_id, @ids.deleted_document_version_id, "document"}
                 ]
        end

        for citation <- citations do
          fragment =
            Enum.find(rows["content.document_fragments"], &(&1["id"] == citation["fragment_id"]))

          assert citation["source_resource_id"] == fragment["resource_id"]
          assert citation["source_resource_version_id"] == fragment["resource_version_id"]
          assert citation["locator"] == fragment["locator"]
        end
      end

      assert Enum.map(
               rows["content.note_attachments"],
               &{&1["note_resource_version_id"], &1["id"]}
             ) ==
               Enum.sort([
                 {@ids.canonical_note_version_id, @ids.attachment_id},
                 {@ids.merge_note_version_id, @ids.attachment_id},
                 {@ids.open_competing_note_version_id, @ids.attachment_id},
                 {@ids.deleted_note_version_id, @ids.deleted_attachment_id}
               ])

      assert Enum.map(rows["content.note_citations"], &{&1["note_resource_version_id"], &1["id"]}) ==
               Enum.sort([
                 {@ids.competing_note_version_id, @ids.citation_id},
                 {@ids.merge_note_version_id, @ids.citation_id},
                 {@ids.deleted_note_version_id, @ids.deleted_citation_id}
               ])

      assert rows["content.document_import_receipts"] != []

      assert Enum.sort(Enum.map(rows["content.document_import_receipts"], & &1["version_id"])) ==
               Enum.sort(Enum.map(rows["content.document_versions"], & &1["resource_version_id"]))

      for receipt <- rows["content.document_import_receipts"] do
        assert receipt["state"] == "completed"
        assert byte_size(receipt["request_fingerprint"]) == 32

        assert receipt["request_fingerprint"] ==
                 :crypto.hash(:sha256, "document-import:" <> receipt["version_id"])

        assert Enum.any?(rows["content.document_versions"], fn document ->
                 document["resource_id"] == receipt["resource_id"] and
                   document["resource_version_id"] == receipt["version_id"]
               end)
      end

      assert [%{"id" => tag, "display_value" => "Straße", "normalized_key" => "strasse"}] =
               rows["content.tags"]

      assert tag == @ids.tag_id
      assert [%{"resource_id" => note, "tag_id" => ^tag}] = rows["content.resource_tags"]
      assert note == @ids.live_note_id

      assert [
               %{
                 "id" => edge,
                 "source_resource_id" => ^note,
                 "target_resource_id" => document,
                 "target_resource_version_id" => pin,
                 "type" => "references"
               }
             ] = rows["content.relationships"]

      assert {edge, document, pin} ==
               {@ids.relationship_id, @ids.ready_document_id, @ids.ready_old_version_id}

      assert call(:canonical_rows, [fixture]) == rows
    end)
  end

  test "canonical oracles use explicit ordered columns and PKs while search and durable work stay distinct" do
    with_fixture(fn fixture ->
      rows = direct_canonical_rows(fixture)
      assert Map.keys(rows) |> Enum.sort() == LogicalSchemaV3.tables() |> Enum.sort()
      assert call(:canonical_rows, [fixture]) == rows
      for excluded <- @excluded, do: refute(Map.has_key?(rows, excluded))

      assert [
               %{
                 "event_type" => "document.extraction_requested",
                 "id" => event_id,
                 "expected_entity_revision" => 0,
                 "envelope_version" => 1,
                 "required_capability" => "asset.read",
                 "payload" => payload
               }
             ] = rows["core.outbox_events"]

      assert payload == %{
               "resource_id" => @ids.extracting_document_id,
               "resource_version_id" => @ids.extracting_version_id
             }

      assert [
               %{
                 "outbox_event_id" => ^event_id,
                 "job_type" => "document_extract",
                 "id" => submission
               }
             ] = rows["jobs.job_submissions"]

      assert [%{"submission_id" => ^submission, "state" => "waiting_for_unlock"}] =
               rows["jobs.job_progress"]

      assert [%{"submission_id" => ^submission, "result" => "applied"}] =
               rows["jobs.effect_receipts"]

      extracting =
        Enum.find(
          rows["content.document_versions"],
          &(&1["resource_version_id"] == @ids.extracting_version_id)
        )

      assert extracting["attempt_job_id"] == event_id

      search =
        owner_query(fn ->
          query(
            "SELECT entry_id,resource_id::text,resource_version_id::text,kind,fragment_id,ordinal,title,body,locator FROM content.search_entries WHERE vault_id=$1 ORDER BY entry_id",
            [dump(fixture.owner.vault_id)]
          )
          |> row_maps()
        end)

      assert call(:search_rows, [fixture]) == %{"content.search_entries" => search}
      assert search != []

      assert Enum.all?(search, fn entry ->
               head = resource(rows, entry["resource_id"])

               head["deleted_at"] == nil and
                 head["current_version_id"] == entry["resource_version_id"]
             end)
    end)
  end

  test "explicit V3 record and bounded Replay fixtures are authenticated without writer or restore admission" do
    with_fixture(fn fixture ->
      before = call(:canonical_rows, [fixture])
      expected_objects = call(:source_bytes, [fixture]) |> Map.keys() |> Enum.sort()

      for mode <- [:records, :replay] do
        bundle = call(:verified_bundle, [fixture, [logical_version: 3, mode: mode]])

        assert %BundleReader.Verified{
                 manifest: %{version: 1},
                 manifest_hash: <<_::256>>,
                 manifest_tag: <<_::128>>
               } = bundle.verified

        assert bundle.cut.logical_version == 3
        assert Enum.map(bundle.cut.object_inventory, & &1.asset_object_id) == expected_objects

        case mode do
          :records ->
            assert {:ok, cut} = LogicalBundleVerifier.verify(bundle.verified, bundle.binding)
            assert cut == bundle.cut
            assert Enum.all?(decoded_rows(bundle.verified.records), &(&1.logical_version == 3))

          :replay ->
            assert %BundleReader.Replay{} = bundle.verified.replay
            assert bundle.verified.records == []
            assert bundle.verified.cut == bundle.cut

            assert {:ok, events} =
                     BundleReader.reduce_verified(bundle.verified, [], fn event, acc ->
                       {:ok, [event | acc]}
                     end)

            assert events != []

            assert Enum.count(events, &match?({:record_start, 0x0002, _size}, &1)) ==
                     Enum.sum(Enum.map(before, fn {_table, rows} -> length(rows) end))
        end
      end

      assert LogicalRecordCodec.default_version() == 2
      assert call(:canonical_rows, [fixture]) == before
    end)
  end

  test "single-field semantic malformations remain authenticated and do not mutate the source graph" do
    with_fixture(fn fixture ->
      before = call(:canonical_rows, [fixture])
      originals = call(:verified_bundle, [fixture, [logical_version: 3, mode: :records]])

      mutations = [
        {"content.document_versions", @ids.ready_old_version_id, "source_digest",
         :binary.copy(<<7>>, 32)},
        {"content.document_versions", @ids.ready_old_version_id, "source_byte_size", 999},
        {"content.document_versions", @ids.ready_old_version_id, "source_object_id",
         @ids.empty_object_id},
        {"content.note_versions", @ids.merge_note_version_id, "parent_version_id",
         @ids.merge_note_version_id},
        {"content.tags", @ids.tag_id, "normalized_key", "not-the-normalized-key"},
        {"content.relationships", @ids.relationship_id, "target_resource_version_id",
         @ids.deleted_note_version_id}
      ]

      for {table, primary_key, field, value} <- mutations do
        malformed =
          call(:malformed_bundle, [
            fixture,
            %{table: table, primary_key: primary_key, field: field, value: value, mode: :records}
          ])

        assert %BundleReader.Verified{manifest_hash: <<_::256>>, manifest_tag: <<_::128>>} =
                 malformed.verified

        # These are typed but semantically invalid graphs. Task4, not the wire verifier,
        # must reject their history/source closure before any canonical admission.
        assert {:ok, cut} = LogicalBundleVerifier.verify(malformed.verified, malformed.binding)
        assert cut == malformed.cut

        assert logical_field_changes(originals.verified.records, malformed.verified.records) ==
                 [{table, primary_key, field, value}]

        assert malformed.verified.manifest_hash != originals.verified.manifest_hash
      end

      assert call(:canonical_rows, [fixture]) == before
    end)
  end

  test "fixed V2 remains explicitly selected and the genuine pre-Notes V1 golden stays byte identical" do
    golden =
      Path.expand("../../../fixtures/backup/logical-v1-pre-notes.backup", __DIR__) |> File.read!()

    assert Base.encode16(:crypto.hash(:sha256, golden), case: :lower) ==
             "75605267628f11cb694b8ae05cd9b43fcdb87ae0c240fcc98c87ab143045b6b2"

    legacy = call(:verified_bundle, [:legacy_v2, [logical_version: 2, mode: :records]])
    assert legacy.cut.logical_version == 2
    assert {:ok, cut} = LogicalBundleVerifier.verify(legacy.verified, legacy.binding)
    assert cut == legacy.cut
    assert Enum.all?(decoded_rows(legacy.verified.records), &(&1.logical_version == 2))

    assert Enum.any?(
             decoded_rows(legacy.verified.records),
             &(&1.table == "content.note_versions")
           )

    assert Enum.all?(
             decoded_rows(legacy.verified.records),
             &(&1.table in LogicalSchemaV2.tables())
           )

    assert LogicalRecordCodec.default_version() == 2
  end

  defp call(function, args) do
    assert Code.ensure_loaded?(@fixtures), "missing independent KnowledgeBackupFixtures support"

    assert function_exported?(@fixtures, function, length(args)),
           "missing #{function}/#{length(args)} fixture seam"

    apply(@fixtures, function, args)
  end

  defp with_fixture(fun),
    do: call(:with_destination, [:current, fn destination -> fun.(seed(destination)) end])

  defp seed(destination) do
    fixture = call(:seed!, [Map.merge(destination, %{ids: @ids, originals: @originals})])
    assert fixture.ids == @ids
    assert fixture.destination == destination

    assert %{vault_id: vault, principal_id: principal, session_id: session, account_id: account} =
             fixture.owner

    assert {vault, principal, session, account} ==
             {@ids.vault_id, @ids.principal_id, @ids.session_id, @ids.account_id}

    fixture
  end

  defp direct_canonical_rows(fixture) do
    prefix =
      Enum.map(LogicalSchemaV2.all(), fn schema ->
        {schema.table, Enum.map(schema.columns, & &1.name),
         Enum.map(schema.primary_key, fn key ->
           Enum.fetch!(schema.columns, key.position).name
         end)}
      end)

    # Explicit column projection (never SELECT *) and PK order; the appended list
    # is a literal oracle independent of V3/Exporter/Restorer. V2 is frozen substrate.
    owner_query(fn ->
      Map.new(prefix ++ @appended, fn {table, columns, primary_key} ->
        {where, parameters} = owner_filter(table, columns, fixture.owner)

        result =
          query(
            "SELECT #{Enum.join(columns, ",")} FROM #{table} WHERE #{where} ORDER BY #{Enum.join(primary_key, ",")}",
            parameters
          )

        {table, row_maps(result)}
      end)
    end)
  end

  defp owner_filter("identity.people", _columns, owner),
    do: {"id IN (SELECT person_id FROM identity.accounts WHERE id=$1)", [dump(owner.account_id)]}

  defp owner_filter("identity.accounts", _columns, owner), do: {"id=$1", [dump(owner.account_id)]}

  defp owner_filter(table, _columns, owner)
       when table in ~w(identity.credentials identity.principals),
       do: {"account_id=$1", [dump(owner.account_id)]}

  defp owner_filter("core.capabilities", _columns, owner),
    do:
      {"id IN (SELECT capability_id FROM core.principal_capabilities WHERE vault_id=$1)",
       [dump(owner.vault_id)]}

  defp owner_filter("core.vaults", _columns, owner), do: {"id=$1", [dump(owner.vault_id)]}

  defp owner_filter(_table, columns, owner) do
    assert "vault_id" in columns
    {"vault_id=$1", [dump(owner.vault_id)]}
  end

  defp row_maps(%{columns: columns, rows: rows}),
    do:
      Enum.map(rows, fn row ->
        Map.new(Enum.zip(columns, row), fn {key, value} ->
          {key, canonical_value(key, value)}
        end)
      end)

  defp canonical_value(_key, %DateTime{} = value), do: DateTime.to_iso8601(value)

  defp canonical_value(key, <<_::128>> = value) do
    if key == "id" or String.ends_with?(key, "_id"), do: Ecto.UUID.load!(value), else: value
  end

  defp canonical_value(_key, value), do: value

  defp resource(rows, id), do: Enum.find(rows["content.resources"], &(&1["id"] == id))
  defp ordinals(0), do: []
  defp ordinals(count), do: Enum.to_list(0..(count - 1))
  defp dump(id), do: Ecto.UUID.dump!(id)

  defp decoded_rows(records) do
    for %{type: 0x0002, payload: payload} <- records do
      assert {:ok, row} = LogicalRecordCodec.decode(0x0002, payload)
      row
    end
  end

  defp logical_field_changes(originals, changed) do
    old_rows = decoded_rows(originals)
    new_rows = decoded_rows(changed)

    assert Enum.map(old_rows, &{&1.table, &1.primary_key_values}) ==
             Enum.map(new_rows, &{&1.table, &1.primary_key_values})

    Enum.zip(old_rows, new_rows)
    |> Enum.flat_map(fn {old, new} ->
      if old.ordered_column_values == new.ordered_column_values do
        []
      else
        {:ok, schema} = LogicalSchemaV3.fetch_table(old.table)
        assert [{"uuid", primary_key}] = old.primary_key_values

        Enum.zip([schema.columns, old.ordered_column_values, new.ordered_column_values])
        |> Enum.flat_map(fn
          {_column, value, value} -> []
          {column, _old, {_tag, value}} -> [{old.table, primary_key, column.name, value}]
        end)
      end
    end)
  end

  defp assert_destination(%{repo: MigrationRepo, database: database, object_root: root}, caller) do
    assert database =~ ~r/\Asingularity_test_[0-9a-f]{24}\z/
    refute database == caller.database
    refute {:ok, root} == caller.storage_root
    owned_prefix = Path.join([System.tmp_dir!(), "singularity", "integration"]) <> "/"
    assert String.starts_with?(root, owned_prefix)
    assert String.replace_prefix(root, owned_prefix, "") =~ ~r/\A[0-9a-f]{24}(?:\/objects)?\z/
    assert Path.type(root) == :absolute
    assert File.dir?(root)
    assert owner_query(fn -> query("SELECT current_database()").rows end) == [[database]]
  end

  defp caller_state do
    running = Map.new(@repos, &{&1, Process.whereis(&1) != nil})

    configs =
      Map.new(
        [:singularity_storage, :singularity_runtime],
        &{&1, Map.new(Application.get_all_env(&1))}
      )

    runtime =
      Enum.any?(Application.started_applications(), &(elem(&1, 0) == :singularity_runtime))

    {database, canonical} =
      caller_owner_query(fn ->
        [[database]] = query("SELECT current_database()").rows

        canonical =
          Enum.map(
            ~w(content.resources content.resource_versions content.note_versions
                                content.document_versions content.asset_objects),
            fn table ->
              query(
                "SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text),'[]'::jsonb) FROM #{table} t"
              ).rows
            end
          )

        {database, canonical}
      end)

    %{
      database: database,
      canonical: canonical,
      configs: configs,
      running: running,
      runtime: runtime,
      storage_root: Application.fetch_env(:singularity_storage, :storage_root)
    }
  end

  defp database_exists?(database),
    do:
      caller_owner_query(fn ->
        [[exists?]] =
          query("SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname=$1)", [database]).rows

        exists?
      end)

  defp caller_owner_query(fun) do
    if Process.whereis(MigrationRepo), do: owner_query(fun), else: Fixtures.with_owner(fun)
  end

  defp owner_query(fun) do
    {:ok, value} =
      MigrationRepo.transaction(fn ->
        query("SET LOCAL ROLE singularity_table_owner")
        fun.()
      end)

    value
  end

  defp query(sql, parameters \\ []),
    do: Ecto.Adapters.SQL.query!(MigrationRepo, sql, parameters, log: false)
end
