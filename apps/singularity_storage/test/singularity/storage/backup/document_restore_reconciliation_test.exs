defmodule Singularity.Storage.Backup.DocumentRestoreReconciliationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Singularity.Core.Error

  alias Singularity.Storage.{
    LocalFilesystemAdapter,
    MigrationRepo,
    MigrationTestEnvironment,
    PreAuthRepo,
    RequestRepo,
    SafeSQL,
    ScopedRepo,
    WorkerRepo
  }

  alias Singularity.Storage.Backup.{
    BundleReader,
    KnowledgeBackupFixtures,
    LocalDestination,
    LogicalBundleVerifier,
    Reconciler,
    Restorer
  }

  alias KnowledgeBackupFixtures.FixtureCrypto
  alias Singularity.Storage.Crypto.{Argon2PasswordHasher, Format, KeyWrapper}

  alias Singularity.Storage.Postgres.{
    AuditSink,
    CustodyRepository,
    DocumentRepository,
    IdentityRepository,
    PreAuth
  }

  @ids ~w(account_id principal_id vault_id session_id live_note_id deleted_note_id
    initial_note_version_id canonical_note_version_id competing_note_version_id
    merge_note_version_id open_competing_note_version_id deleted_note_version_id
    resolved_conflict_id open_conflict_id ready_document_id ready_old_version_id
    ready_current_version_id deleted_document_id deleted_document_version_id
    pending_document_id pending_version_id extracting_document_id extracting_version_id
    failed_document_id failed_version_id unsupported_document_id unsupported_version_id
    attachment_id citation_id deleted_attachment_id deleted_citation_id tag_id
    relationship_id pdf_object_id empty_object_id plain_object_id unicode_object_id markdown_object_id)a
       |> Enum.with_index(1)
       |> Map.new(fn {name, n} ->
         {name, "75000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")}
       end)
       |> then(fn ids ->
         Map.merge(ids, %{principal_id: ids.account_id, vault_id: ids.account_id})
       end)
  @originals %{
    pdf: "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n",
    pdf_duplicate: "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n",
    empty: "",
    plain: "plain original\r\nsecond line\n",
    unicode: "界🙂 café\n",
    markdown: "# Original Markdown\n"
  }
  @work_tables ~w(core.outbox_events jobs.job_submissions jobs.job_progress jobs.effect_receipts)
  @mutable_authority ~w(identity.principals core.vaults core.vault_members)
  @password "document-restore-native-login-test-only"
  @hash_policy %{version: 1, t_cost: 1, m_cost: 8, parallelism: 1}
  @auth_invalid "restore_document_authorization_invalid"
  @functions [
    "content.expired_document_extraction_ids(integer)",
    "content.recover_expired_document_with_event(uuid,uuid)",
    "content.retry_document_runtime(uuid,text,integer)"
  ]
  @denial_canonical_tables ~w(identity.people identity.accounts identity.credentials identity.principals
    core.capabilities core.vaults core.vault_members core.principal_capabilities
    identity.devices core.key_domains core.vault_key_versions core.vault_key_wrappers
    core.domain_key_versions core.domain_dedup_key_wrappers content.resources
    content.resource_versions content.asset_objects content.assets content.asset_key_envelopes
    content.asset_metadata content.resource_assets content.source_references content.tombstones
    audit.events core.outbox_events jobs.job_submissions jobs.job_progress jobs.effect_receipts
    content.note_versions content.note_conflicts content.document_versions
    content.document_fragments content.document_import_receipts content.note_attachments
    content.note_citations content.tags content.resource_tags content.relationships)
  @denial_excluded_tables ~w(identity.sessions identity.auth_attempts content.asset_stages content.upload_grants
    content.asset_search_documents content.note_search_documents content.search_entries
    content.note_mutation_receipts audit.backup_manifests audit.backup_manifest_objects
    jobs.oban_jobs jobs.oban_peers)

  setup_all do
    portable =
      Path.join(System.tmp_dir!(), "document-restore-reconciliation-#{Ecto.UUID.generate()}")

    File.mkdir_p!(portable)
    File.chmod!(portable, 0o700)
    on_exit(fn -> File.rm_rf!(portable) end)

    source =
      KnowledgeBackupFixtures.with_destination(:current, fn destination ->
        fixture =
          KnowledgeBackupFixtures.seed!(
            Map.merge(destination, %{ids: @ids, originals: @originals})
          )

        owner(fn ->
          assert [[true]] =
                   sql("SELECT expires_at<clock_timestamp() FROM identity.sessions WHERE id=$1", [
                     dump(@ids.session_id)
                   ]).rows

          repair_source_work_graph!()
          insert_pending_request!()
        end)

        rows = KnowledgeBackupFixtures.canonical_rows(fixture)
        bytes = KnowledgeBackupFixtures.source_bytes(fixture)

        ciphertexts =
          Map.new(rows["content.asset_objects"], fn object ->
            ciphertext = File.read!(Path.join(destination.object_root, object["storage_ref"]))
            assert byte_size(ciphertext) == object["ciphertext_byte_size"]
            assert :crypto.hash(:sha256, ciphertext) == object["ciphertext_hash"]
            {object["id"], ciphertext}
          end)

        assert length(rows["content.document_versions"]) == 7
        assert map_size(bytes) == 5

        assert [%{"id" => extraction_event_id}] =
                 Enum.filter(rows["jobs.job_submissions"], &(&1["outbox_event_id"] == id(700)))

        assert extraction_event_id == id(700)
        assert_claim_cut!(rows)

        bundles =
          Map.new([:canonical, :missing_event, :missing_submission], fn variant ->
            transform = fn rows ->
              case variant do
                :canonical ->
                  rows

                :missing_event ->
                  Map.update!(
                    rows,
                    "core.outbox_events",
                    &Enum.reject(&1, fn row -> row["id"] == id(700) end)
                  )

                :missing_submission ->
                  rows
                  |> Map.update!(
                    "jobs.job_submissions",
                    &Enum.reject(&1, fn row -> row["id"] == id(700) end)
                  )
                  |> Map.update!(
                    "jobs.job_progress",
                    &Enum.reject(&1, fn row -> row["submission_id"] == id(700) end)
                  )
                  |> Map.update!(
                    "jobs.effect_receipts",
                    &Enum.reject(&1, fn row -> row["submission_id"] == id(700) end)
                  )
              end
            end

            result =
              if variant == :canonical,
                do:
                  {:ok,
                   KnowledgeBackupFixtures.verified_bundle(fixture,
                     logical_version: 3,
                     mode: :replay
                   )},
                else: KnowledgeBackupFixtures.transformed_bundle(fixture, rows: transform)

            assert {:ok, bundle} = result
            bundle_root = Path.join(portable, Atom.to_string(variant))
            File.mkdir_p!(bundle_root)
            File.chmod!(bundle_root, 0o700)
            path = Path.join(bundle_root, bundle.binding.destination_ref)
            File.cp!(Path.join(destination.object_root, bundle.binding.destination_ref), path)
            File.chmod!(path, 0o600)
            assert :ok = BundleReader.discard_verified(bundle.verified)

            {variant,
             %{
               binding: bundle.binding,
               filename: bundle.binding.destination_ref,
               portable: bundle_root
             }}
          end)

        %{
          portable: portable,
          bundles: bundles,
          source_database: destination.database,
          source_root: destination.object_root,
          rows: rows,
          bytes: bytes,
          ciphertexts: ciphertexts
        }
      end)

    refute File.exists?(source.source_root)
    %{source: source}
  end

  test "actual encrypted V3 claim survives COMMIT and reflected retirement before native one-shot recovery",
       %{source: source} do
    with_import(source, fn _destination, imported ->
      canonical = canonical_history()
      assert canonical === canonical_history(source.rows)
      assert_deadline_barrier!()
      before_attempt = document_row(@ids.extracting_version_id)
      assert :ok = Reconciler.reconcile(MigrationRepo, imported.cut)
      assert canonical_history() === canonical
      assert_reflected!(id(700))

      assert [[nil, nil]] =
               owner(fn ->
                 sql("SELECT runner_job_id,delivered_at FROM core.outbox_events WHERE id=$1", [
                   dump(id(700))
                 ]).rows
               end)

      after_reconcile = work_rows()
      assert :ok = Reconciler.reconcile(MigrationRepo, imported.cut)
      assert work_rows() === after_reconcile
      assert canonical_history() === canonical

      context = %{repo: WorkerRepo}
      assert {:ok, candidates} = DocumentRepository.list_expired_recovery_ids(context, 100)
      assert {@ids.extracting_version_id, @ids.vault_id} in candidates

      assert {:ok, true} =
               DocumentRepository.recover_expired_with_event(
                 context,
                 @ids.extracting_version_id,
                 @ids.vault_id
               )

      assert_recovered!(before_attempt, :automatic)
      after_recovery = all_rows()

      assert {:ok, false} =
               DocumentRepository.recover_expired_with_event(
                 context,
                 @ids.extracting_version_id,
                 @ids.vault_id
               )

      assert all_rows() === after_recovery
      assert_other_history!(canonical, @ids.extracting_version_id)
      refute Process.whereis(Singularity.Runtime.Documents.ExtractionReconciler)
    end)
  end

  for state <- [:pending, :extracting],
      rejection <- [:principal_epoch, :owner_epoch, :same_epoch_membership] do
    test "#{state} #{rejection} remains automatically inert after reauthorization but fresh authenticated retry advances once",
         %{source: source} do
      with_import(source, fn destination, imported ->
        {version, resource, original_event} = retry_target(unquote(state))
        before = document_row(version)
        canonical = canonical_history()
        invalidate_authority!(unquote(rejection))
        assert :ok = Reconciler.reconcile(MigrationRepo, imported.cut)
        assert_reason!(original_event, @auth_invalid)
        assert canonical_history() === canonical
        assert_no_automatic!(version)
        reauthorize_after_rejection!(unquote(rejection))
        assert_no_automatic!(version)
        retired_original = event_row(original_event)

        with_authenticated_retry(destination, fn config, session ->
          assert {:ok, document} =
                   apply(Singularity.Runtime.Api, :retry_document, [config, session, resource])

          assert document.resource_version_id == version
          assert document.state == :pending
          assert document.generation == before["attempt_generation"] + 1
          assert_recovered!(before, :authenticated)
          assert event_row(original_event) === retired_original
          first = work_rows()
          current = document_row(version)
          # Retry SQL creates only outbox; no fake dispatcher submission is added.
          successor = successor_row(version, current["attempt_generation"])

          assert [[0]] =
                   owner(fn ->
                     sql("SELECT count(*) FROM jobs.job_submissions WHERE outbox_event_id=$1", [
                       dump(successor["id"])
                     ]).rows
                   end)

          assert {:ok, ^document} =
                   apply(Singularity.Runtime.Api, :retry_document, [config, session, resource])

          assert work_rows() === first
          assert document_row(version) === current
          assert event_row(original_event) === retired_original
          assert_other_history!(canonical, version)
        end)
      end)
    end
  end

  test "valid current pending retry is idempotent before submission and validates any present submission",
       %{source: source} do
    with_import(source, fn destination, _imported ->
      owner(fn -> sql("DELETE FROM jobs.job_submissions WHERE id=$1", [dump(id(710))]) end)

      with_authenticated_retry(destination, fn config, session ->
        before = document_row(@ids.pending_version_id)
        work = work_rows()

        assert {:ok, %{state: :pending, generation: 0}} =
                 apply(Singularity.Runtime.Api, :retry_document, [
                   config,
                   session,
                   @ids.pending_document_id
                 ])

        assert document_row(@ids.pending_version_id) === before
        assert work_rows() === work
        owner(fn -> insert_submission_from_event!(id(710), "document_extract") end)
        exact = work_rows()

        assert {:ok, %{state: :pending, generation: 0}} =
                 apply(Singularity.Runtime.Api, :retry_document, [
                   config,
                   session,
                   @ids.pending_document_id
                 ])

        assert work_rows() === exact

        owner(fn ->
          sql("UPDATE jobs.job_submissions SET job_type='document_projection' WHERE id=$1", [
            dump(id(710))
          ])
        end)

        malformed = work_rows()

        assert {:error, _reason} =
                 apply(Singularity.Runtime.Api, :retry_document, [
                   config,
                   session,
                   @ids.pending_document_id
                 ])

        assert work_rows() === malformed
        assert document_row(@ids.pending_version_id) === before
      end)
    end)
  end

  for fault <- [
        :wrong_payload,
        :wrong_creator,
        :wrong_revision,
        :wrong_key,
        :wrong_type,
        :foreign_owner,
        :stale_head
      ] do
    test "real authenticated retry refuses present #{fault} original without canonical or work changes",
         %{source: source} do
      with_import(source, fn destination, _imported ->
        invalidate_authority!(:principal_epoch)

        with_authenticated_retry(destination, fn config, session ->
          fault_original!(unquote(fault))
          assert_public_denied_unchanged!(config, session, @ids.extracting_document_id)
        end)
      end)
    end
  end

  for fault <- [
        :revoked_session,
        :expired_session,
        :revoked_membership,
        :revoked_capability,
        :disabled_account
      ] do
    test "ordinary #{fault} authority cannot use the public retry amendment", %{source: source} do
      with_import(source, fn destination, imported ->
        invalidate_authority!(:principal_epoch)
        assert :ok = Reconciler.reconcile(MigrationRepo, imported.cut)

        with_authenticated_retry(destination, fn config, session ->
          owner(fn ->
            case unquote(fault) do
              :revoked_session ->
                sql("UPDATE identity.sessions SET revoked_at=clock_timestamp() WHERE id=$1", [
                  dump(session.session_id)
                ])

              :expired_session ->
                sql(
                  "UPDATE identity.sessions SET expires_at=clock_timestamp()-interval '1 second' WHERE id=$1",
                  [dump(session.session_id)]
                )

              :revoked_membership ->
                sql(
                  "UPDATE core.vault_members SET revoked_at=clock_timestamp() WHERE principal_id=$1 AND vault_id=$2",
                  [dump(@ids.principal_id), dump(@ids.vault_id)]
                )

              :revoked_capability ->
                sql(
                  "UPDATE core.principal_capabilities SET revoked_at=clock_timestamp() WHERE principal_id=$1 AND vault_id=$2",
                  [dump(@ids.principal_id), dump(@ids.vault_id)]
                )

              :disabled_account ->
                sql("UPDATE identity.accounts SET status='disabled' WHERE id=$1", [
                  dump(@ids.account_id)
                ])
            end
          end)

          assert_public_denied_unchanged!(config, session, @ids.extracting_document_id)
          assert_no_automatic!(@ids.extracting_version_id)
        end)
      end)
    end
  end

  for fault <- [
        :wrong_payload,
        :wrong_creator,
        :wrong_revision,
        :wrong_key,
        :wrong_type,
        :foreign_owner,
        :stale_head,
        :missing_event,
        :missing_submission
      ] do
    test "pending authenticated retry refuses #{fault} rather than returning by key existence alone",
         %{source: source} do
      with_import(source, fn destination, _imported ->
        invalidate_authority!(:principal_epoch)

        with_authenticated_retry(destination, fn config, session ->
          owner(fn ->
            case unquote(fault) do
              :wrong_payload ->
                sql(
                  "UPDATE core.outbox_events SET payload=jsonb_build_object('resource_id',$2::uuid,'resource_version_id',$3::uuid) WHERE id=$1",
                  [
                    dump(id(710)),
                    dump(@ids.extracting_document_id),
                    dump(@ids.pending_version_id)
                  ]
                )

              :wrong_creator ->
                sql("UPDATE core.outbox_events SET principal_id=$2 WHERE id=$1", [
                  dump(id(710)),
                  dump(id(103))
                ])

              :wrong_revision ->
                sql("UPDATE core.outbox_events SET expected_entity_revision=1 WHERE id=$1", [
                  dump(id(710))
                ])

              :wrong_key ->
                sql(
                  "UPDATE core.outbox_events SET idempotency_key='document-extraction:wrong' WHERE id=$1",
                  [dump(id(710))]
                )

                sql(
                  "UPDATE jobs.job_submissions SET idempotency_key='document-extraction:wrong' WHERE id=$1",
                  [dump(id(710))]
                )

              :wrong_type ->
                sql("UPDATE core.outbox_events SET event_type='document.ready' WHERE id=$1", [
                  dump(id(710))
                ])

              :foreign_owner ->
                sql("INSERT INTO core.vaults(id) VALUES($1)", [dump(id(799))])

                sql("INSERT INTO core.vault_members(principal_id,vault_id) VALUES($1,$2)", [
                  dump(@ids.principal_id),
                  dump(id(799))
                ])

                sql("DELETE FROM jobs.job_submissions WHERE id=$1", [dump(id(710))])

                sql("UPDATE core.outbox_events SET vault_id=$2 WHERE id=$1", [
                  dump(id(710)),
                  dump(id(799))
                ])

              :stale_head ->
                replace_document_head!(@ids.pending_document_id)

              :missing_event ->
                sql("DELETE FROM jobs.job_submissions WHERE id=$1", [dump(id(710))])
                sql("DELETE FROM core.outbox_events WHERE id=$1", [dump(id(710))])

              :missing_submission ->
                sql("DELETE FROM jobs.job_submissions WHERE id=$1", [dump(id(710))])
            end
          end)

          assert_public_denied_unchanged!(config, session, @ids.pending_document_id)
        end)
      end)
    end
  end

  test "authenticated pending successor collision rolls back generation and preserves retired provenance",
       %{source: source} do
    with_import(source, fn destination, imported ->
      invalidate_authority!(:owner_epoch)
      assert :ok = Reconciler.reconcile(MigrationRepo, imported.cut)
      assert_reason!(id(710), @auth_invalid)

      owner(fn ->
        insert_event!(
          @ids.pending_document_id,
          @ids.pending_version_id,
          id(721),
          1,
          "document.extraction_requested",
          "document-extraction:#{@ids.pending_version_id}:1"
        )
      end)

      with_authenticated_retry(destination, fn config, session ->
        assert_public_denied_unchanged!(config, session, @ids.pending_document_id)
      end)
    end)
  end

  for state <- [:pending, :extracting] do
    test "generic destructive #{state} retirement is not an authorization-invalid retry token", %{
      source: source
    } do
      with_import(source, fn destination, _imported ->
        {_version, resource, event} = retry_target(unquote(state))
        invalidate_pending_only!(unquote(state))

        owner(fn ->
          sql(
            "UPDATE core.outbox_events SET retired_at=clock_timestamp(),retirement_reason='restore_stale_destructive' WHERE id=$1",
            [dump(event)]
          )
        end)

        with_authenticated_retry(destination, fn config, session ->
          before = all_rows()

          assert {:error, _reason} =
                   apply(Singularity.Runtime.Api, :retry_document, [config, session, resource])

          assert all_rows() === before
        end)
      end)
    end
  end

  for fault <- [
        :wrong_payload,
        :wrong_creator,
        :wrong_revision,
        :wrong_key,
        :wrong_type,
        :foreign_owner,
        :destructive,
        :legacy,
        :auth_invalid,
        :wrong_submission,
        :stale_head
      ] do
    test "present native original #{fault} never falls through to eventless compatibility", %{
      source: source
    } do
      with_import(source, fn _destination, _imported ->
        fault_original!(unquote(fault))
        before = all_rows()
        assert_no_automatic!(@ids.extracting_version_id)
        assert all_rows() === before
      end)
    end
  end

  for submission <- [:absent, :exact] do
    test "unretired present native original recovers with #{submission} submission", %{
      source: source
    } do
      with_import(source, fn _destination, _imported ->
        if unquote(submission) == :absent, do: remove_extraction_submission!()
        original = document_row(@ids.extracting_version_id)
        assert_deadline_barrier!()
        assert {:ok, ids} = DocumentRepository.list_expired_recovery_ids(%{repo: WorkerRepo}, 100)
        assert {@ids.extracting_version_id, @ids.vault_id} in ids

        assert {:ok, true} =
                 DocumentRepository.recover_expired_with_event(
                   %{repo: WorkerRepo},
                   @ids.extracting_version_id,
                   @ids.vault_id
                 )

        assert_recovered!(original, :automatic)
      end)
    end
  end

  for submission <- [:absent, :wrong] do
    test "reflected imported original requires #{submission} submission to be denied", %{
      source: source
    } do
      with_import(source, fn _destination, imported ->
        assert :ok = Reconciler.reconcile(MigrationRepo, imported.cut)
        assert_reflected!(id(700))

        if unquote(submission) == :absent,
          do: remove_extraction_submission!(),
          else:
            owner(fn ->
              sql("UPDATE jobs.job_submissions SET job_type='document_projection' WHERE id=$1", [
                dump(id(700))
              ])
            end)

        before = all_rows()
        assert_no_automatic!(@ids.extracting_version_id)
        assert all_rows() === before
      end)
    end
  end

  test "true eventless native attempt remains compatible without loosening authenticated retry",
       %{source: source} do
    with_import(source, fn destination, _imported ->
      remove_extraction_submission!()
      owner(fn -> sql("DELETE FROM core.outbox_events WHERE id=$1", [dump(id(700))]) end)
      original = document_row(@ids.extracting_version_id)

      with_authenticated_retry(destination, fn config, session ->
        before = all_rows()

        assert {:error, _reason} =
                 apply(Singularity.Runtime.Api, :retry_document, [
                   config,
                   session,
                   @ids.extracting_document_id
                 ])

        assert all_rows() === before
      end)

      assert {:ok, true} =
               DocumentRepository.recover_expired_with_event(
                 %{repo: WorkerRepo},
                 @ids.extracting_version_id,
                 @ids.vault_id
               )

      assert_recovered!(original, :automatic)
    end)
  end

  for variant <- [:missing_event, :missing_submission] do
    test "V3 #{variant} attempt provenance is denied before import COMMIT", %{source: source} do
      KnowledgeBackupFixtures.with_destination(:current, fn destination ->
        assert_empty_receiver!()
        bundle = source.bundles[unquote(variant)]
        assert {:ok, verified} = authenticate(source, bundle)

        try do
          assert {:error, %Error{code: :integrity_failure, details: %{}} = error} =
                   Restorer.import(
                     %{
                       object_storage: {LocalFilesystemAdapter, %{root: destination.object_root}}
                     },
                     MigrationRepo,
                     %{verified: verified, cut: verified.cut, binding: bundle.binding}
                   )

          assert error.details == %{}
          pending = assert_pending_denial_receiver!(destination, bundle, verified)

          assert {:ok, retry_verified} = authenticate(source, bundle)

          try do
            assert retry_verified.manifest_hash === verified.manifest_hash

            assert {:error, %Error{code: :integrity_failure, details: %{}} = retry_error} =
                     Restorer.import(
                       %{
                         object_storage:
                           {LocalFilesystemAdapter, %{root: destination.object_root}}
                       },
                       MigrationRepo,
                       %{
                         verified: retry_verified,
                         cut: retry_verified.cut,
                         binding: bundle.binding
                       }
                     )

            assert retry_error.details == %{}
            assert assert_pending_denial_receiver!(destination, bundle, verified) === pending
          after
            BundleReader.discard_verified(retry_verified)
          end

          different_bundle = source.bundles.canonical
          assert {:ok, different_verified} = authenticate(source, different_bundle)

          try do
            refute different_verified.manifest_hash === verified.manifest_hash

            assert {:error, %Error{code: :conflict, details: %{}} = conflict_error} =
                     Restorer.import(
                       %{
                         object_storage:
                           {LocalFilesystemAdapter, %{root: destination.object_root}}
                       },
                       MigrationRepo,
                       %{
                         verified: different_verified,
                         cut: different_verified.cut,
                         binding: different_bundle.binding
                       }
                     )

            assert conflict_error.details == %{}
            assert assert_pending_denial_receiver!(destination, bundle, verified) === pending
          after
            BundleReader.discard_verified(different_verified)
          end

          refute MigrationRepo.in_transaction?()
        after
          BundleReader.discard_verified(verified)
        end
      end)
    end
  end

  test "future-deadline native attempt rejects automatic recovery and authenticated retry", %{
    source: source
  } do
    with_import(source, fn destination, _imported ->
      # A separate newly claimed native Document; never rewrite the imported cut.
      {version, resource} = seed_native_attempt!(9000, :future, :exact)

      assert [[true]] =
               owner(fn ->
                 sql(
                   "SELECT attempt_deadline_at>clock_timestamp() FROM content.document_versions WHERE resource_version_id=$1",
                   [dump(version)]
                 ).rows
               end)

      with_authenticated_retry(destination, fn config, session ->
        before = all_rows()
        assert_no_automatic!(version)

        assert {:error, _reason} =
                 apply(Singularity.Runtime.Api, :retry_document, [config, session, resource])

        assert all_rows() === before
      end)
    end)
  end

  test "scanner filters one hundred earlier invalid originals before LIMIT and direct recovery repeats the guard",
       %{source: source} do
    with_import(source, fn _destination, _imported ->
      # Existing claim becomes an earlier invalid control as well.
      fault_original!(:wrong_payload)
      invalid = for n <- 1..100, do: seed_native_attempt!(10_000 + n, :expired, :wrong_type)
      {valid, _} = seed_native_attempt!(20_000, :later_expired, :exact)
      before = all_rows()

      assert {:ok, [{^valid, owner_id}]} =
               DocumentRepository.list_expired_recovery_ids(%{repo: WorkerRepo}, 1)

      assert owner_id == @ids.vault_id

      for {version, _} <- invalid,
          do:
            assert(
              {:ok, false} =
                DocumentRepository.recover_expired_with_event(
                  %{repo: WorkerRepo},
                  version,
                  @ids.vault_id
                )
            )

      assert all_rows() === before

      assert {:ok, true} =
               DocumentRepository.recover_expired_with_event(
                 %{repo: WorkerRepo},
                 valid,
                 @ids.vault_id
               )
    end)
  end

  test "recovery successor collision rolls back generation and every original field", %{
    source: source
  } do
    with_import(source, fn _destination, imported ->
      assert :ok = Reconciler.reconcile(MigrationRepo, imported.cut)

      owner(fn ->
        insert_event!(
          @ids.extracting_document_id,
          @ids.extracting_version_id,
          id(720),
          2,
          "document.extraction_requested",
          "document-extraction:#{@ids.extracting_version_id}:2"
        )
      end)

      before = all_rows()

      assert {:error, %Error{}} =
               DocumentRepository.recover_expired_with_event(
                 %{repo: WorkerRepo},
                 @ids.extracting_version_id,
                 @ids.vault_id
               )

      assert all_rows() === before
    end)
  end

  test "two blocked native recoveries serialize to one successor", %{source: source} do
    with_import(source, fn _destination, imported ->
      assert :ok = Reconciler.reconcile(MigrationRepo, imported.cut)

      results =
        race_behind_resource_lock!([
          {WorkerRepo,
           fn ->
             DocumentRepository.recover_expired_with_event(
               %{repo: WorkerRepo},
               @ids.extracting_version_id,
               @ids.vault_id
             )
           end},
          {WorkerRepo,
           fn ->
             DocumentRepository.recover_expired_with_event(
               %{repo: WorkerRepo},
               @ids.extracting_version_id,
               @ids.vault_id
             )
           end}
        ])

      assert Enum.sort(results) == [{:ok, false}, {:ok, true}]
      assert document_row(@ids.extracting_version_id)["attempt_generation"] == 2
      assert successor_row(@ids.extracting_version_id, 2)["causation_id"] == id(700)
    end)
  end

  test "authenticated retry versus retry and recovery produces at most one current-epoch successor",
       %{source: source} do
    with_import(source, fn destination, imported ->
      invalidate_authority!(:principal_epoch)
      assert :ok = Reconciler.reconcile(MigrationRepo, imported.cut)

      with_authenticated_retry(destination, fn config, session ->
        results =
          race_behind_resource_lock!([
            {RequestRepo,
             fn ->
               apply(Singularity.Runtime.Api, :retry_document, [
                 config,
                 session,
                 @ids.extracting_document_id
               ])
             end},
            {RequestRepo,
             fn ->
               apply(Singularity.Runtime.Api, :retry_document, [
                 config,
                 session,
                 @ids.extracting_document_id
               ])
             end},
            {WorkerRepo,
             fn ->
               DocumentRepository.recover_expired_with_event(
                 %{repo: WorkerRepo},
                 @ids.extracting_version_id,
                 @ids.vault_id
               )
             end}
          ])

        assert Enum.count(results, &match?({:ok, %{state: :pending, generation: 2}}, &1)) == 2
        assert {:ok, false} in results
        assert document_row(@ids.extracting_version_id)["attempt_generation"] == 2
        assert successor_row(@ids.extracting_version_id, 2)["causation_id"] == nil
      end)
    end)
  end

  for invalidation <- [:principal_epoch, :owner_epoch, :same_epoch_membership] do
    test "native recovery revalidates #{invalidation} after the actual authorization-lock wait",
         %{source: source} do
      with_import(source, fn _destination, _imported ->
        assert_deadline_barrier!()
        parent = self()
        key = "singularity:authorization:#{@ids.principal_id}:#{@ids.vault_id}"

        locker =
          Task.async(fn ->
            MigrationRepo.transaction(fn ->
              sql("SET LOCAL ROLE singularity_table_owner")
              sql("SELECT pg_advisory_xact_lock(hashtextextended($1,0))", [key])
              send(parent, {:authorization_locked, self()})

              receive do
                :invalidate_and_release ->
                  invalidate_authority!(unquote(invalidation))
                  :ok

                :abort_barrier ->
                  MigrationRepo.rollback(:barrier_aborted)
              after
                10_000 -> flunk("authorization-lock release not received")
              end
            end)
          end)

        try do
          assert_receive {:authorization_locked, locker_pid}, 10_000

          worker =
            Task.async(fn ->
              WorkerRepo.checkout(fn ->
                send(
                  parent,
                  {:recovery_backend, sql_on(WorkerRepo, "SELECT pg_backend_pid()").rows}
                )

                DocumentRepository.recover_expired_with_event(
                  %{repo: WorkerRepo},
                  @ids.extracting_version_id,
                  @ids.vault_id
                )
              end)
            end)

          try do
            assert_receive {:recovery_backend, [[backend]]}, 10_000
            assert_native_blocked!([backend], "advisory")
            original = document_row(@ids.extracting_version_id)
            send(locker_pid, :invalidate_and_release)
            assert {:ok, :ok} = Task.await(locker, 10_000)
            assert {:ok, false} = Task.await(worker, 10_000)
            assert document_row(@ids.extracting_version_id) === original

            assert [[0]] =
                     owner(fn ->
                       sql("SELECT count(*) FROM core.outbox_events WHERE idempotency_key=$1", [
                         "document-extraction:#{@ids.extracting_version_id}:2"
                       ]).rows
                     end)
          after
            if Process.alive?(worker.pid), do: Task.shutdown(worker, :brutal_kill)
          end
        after
          if Process.alive?(locker.pid) do
            send(locker.pid, :abort_barrier)
            Task.shutdown(locker, 1_000)
          end
        end
      end)
    end
  end

  test "forward migration changes only the three reviewed bodies and extraction-only retirement constraint" do
    MigrationTestEnvironment.with_database(20_261_011_000_700, fn environment ->
      {:ok, repo} = MigrationRepo.start_link(pool_size: 5)

      try do
        before = security_receipt()
        before_functions = function_receipt()

        path =
          :singularity_storage |> :code.priv_dir() |> to_string() |> Path.join("repo/migrations")

        file = Path.join(path, "20261011000800_document_restore_recovery_provenance.exs")

        assert File.regular?(file),
               "Task10 requires the additive forward migration, not released-file edits"

        compiler_options = Code.compiler_options()
        Code.compiler_options(ignore_module_conflict: true)

        try do
          assert [20_261_011_000_800] =
                   Ecto.Migrator.run(MigrationRepo, path, :up, to: 20_261_011_000_800, log: false)
        after
          Code.compiler_options(compiler_options)
        end

        after_functions = function_receipt()

        changed =
          for {signature, old} <- before_functions,
              after_functions[signature] !== old,
              do: signature

        assert Enum.sort(changed) == Enum.sort(@functions)
        assert Enum.sort(Map.keys(after_functions)) == Enum.sort(Map.keys(before_functions))

        for signature <- @functions do
          assert Map.delete(after_functions[signature], :definition) ===
                   Map.delete(before_functions[signature], :definition)

          assert after_functions[signature].owner == "singularity_table_owner"
          assert after_functions[signature].security_definer
        end

        assert security_receipt() === before

        assert before_functions[Enum.at(@functions, 0)].result ==
                 "TABLE(version_id uuid, owner_id uuid)"

        assert after_functions[Enum.at(@functions, 1)].result == "boolean"
        assert after_functions[Enum.at(@functions, 2)].result == "uuid"
        assert_worker_contract!()
        assert_retirement_constraint!(environment)
        assert_runtime_dml_denied!()
      after
        Supervisor.stop(repo)
      end
    end)
  end

  defp with_import(source, callback) do
    KnowledgeBackupFixtures.with_destination(:current, fn destination ->
      refute destination.database == source.source_database
      refute File.exists?(source.source_root)
      refute Process.whereis(Singularity.Runtime.Documents.ExtractionReconciler)
      assert_empty_receiver!()
      assert {:ok, verified} = authenticate(source, source.bundles.canonical)

      try do
        assert {:ok, imported} =
                 Restorer.import(
                   %{object_storage: {LocalFilesystemAdapter, %{root: destination.object_root}}},
                   MigrationRepo,
                   %{
                     verified: verified,
                     cut: verified.cut,
                     binding: source.bundles.canonical.binding
                   }
                 )

        refute MigrationRepo.in_transaction?()
        assert imported.cut.logical_version == 3
        assert imported.object_inventory === imported.cut.object_inventory
        assert length(imported.object_inventory) == 5
        assert Enum.all?(imported.object_inventory, &(map_size(&1) == 9))
        assert all_rows() === source.rows
        assert_claim_cut!(all_rows())
        assert @ids.account_id == @ids.principal_id
        assert @ids.principal_id == @ids.vault_id
        assert_imported_auth_metadata!()

        for object <- source.rows["content.asset_objects"] do
          assert File.read!(Path.join(destination.object_root, object["storage_ref"])) ===
                   source.ciphertexts[object["id"]]
        end

        assert [[1]] =
                 owner(fn ->
                   sql("SELECT count(*) FROM audit.restore_import_sagas WHERE state='imported'").rows
                 end)

        assert [[0]] =
                 owner(fn ->
                   sql(
                     "SELECT count(*) FROM core.outbox_events WHERE delivered_at IS NOT NULL OR runner_job_id IS NOT NULL"
                   ).rows
                 end)

        callback.(destination, imported)
      after
        BundleReader.discard_verified(verified)
      end
    end)
  end

  defp authenticate(_source, bundle) do
    with {:ok, reader} <-
           LocalDestination.reader_source(%{backup_root: bundle.portable}, bundle.filename) do
      crypto = %{
        key: :crypto.hash(:sha256, "knowledge-fixture-backup-key"),
        vault_id: @ids.vault_id,
        encryption_domain_id: id(902),
        object_id: bundle.binding.manifest_id,
        chunk_index: 0,
        algorithm: Format.algorithm(),
        format_version: Format.format_version(),
        chunk_size: Format.chunk_size()
      }

      BundleReader.authenticate_all(reader,
        crypto: {FixtureCrypto, crypto},
        verifier: {LogicalBundleVerifier, bundle.binding}
      )
    end
  end

  defp repair_source_work_graph! do
    # Immediate MATCH FULL references require lawful child deletion/recreation,
    # not changing a referenced PK. Preserve every original field and timestamp.
    for {name, table} <- [
          {"source_progress", "jobs.job_progress"},
          {"source_receipts", "jobs.effect_receipts"}
        ] do
      sql(
        "CREATE TEMP TABLE #{name} ON COMMIT DROP AS SELECT * FROM #{table} WHERE submission_id=$1",
        [dump(id(702))]
      )

      sql("DELETE FROM #{table} WHERE submission_id=$1", [dump(id(702))])
    end

    sql(
      "CREATE TEMP TABLE source_submission ON COMMIT DROP AS SELECT * FROM jobs.job_submissions WHERE id=$1",
      [dump(id(702))]
    )

    assert %{num_rows: 1} = sql("DELETE FROM jobs.job_submissions WHERE id=$1", [dump(id(702))])

    assert %{num_rows: 1} =
             sql(
               """
               INSERT INTO jobs.job_submissions SELECT (jsonb_populate_record(NULL::jobs.job_submissions,
                 to_jsonb(s)||jsonb_build_object('id',$1::uuid))).* FROM source_submission s
               """,
               [dump(id(700))]
             )

    for {name, table} <- [
          {"source_progress", "jobs.job_progress"},
          {"source_receipts", "jobs.effect_receipts"}
        ] do
      assert %{num_rows: 1} =
               sql(
                 """
                 INSERT INTO #{table} SELECT (jsonb_populate_record(NULL::#{table},
                   to_jsonb(s)||jsonb_build_object('submission_id',$1::uuid))).* FROM #{name} s
                 """,
                 [dump(id(700))]
               )
    end
  end

  defp insert_pending_request! do
    insert_event!(
      @ids.pending_document_id,
      @ids.pending_version_id,
      id(710),
      0,
      "document.extraction_requested",
      "document-extraction:#{@ids.pending_version_id}"
    )

    insert_submission_from_event!(id(710), "document_extract")
  end

  defp insert_event!(resource, version, event, revision, type, key) do
    sql(
      """
      INSERT INTO core.outbox_events(id,event_type,idempotency_key,vault_id,principal_id,
        required_capability,principal_authorization_epoch,vault_authorization_epoch,classification,
        correlation_id,causation_id,expected_entity_revision,envelope_version,payload,occurred_at)
      SELECT $1,$2,$3,$4,$5,'asset.read',p.authorization_epoch,v.authorization_epoch,'private',
        $1,NULL,$6,1,jsonb_build_object('resource_id',$7::uuid,'resource_version_id',$8::uuid),
        '2026-10-11T00:00:00Z'::timestamptz
      FROM identity.principals p CROSS JOIN core.vaults v WHERE p.id=$5 AND v.id=$4
      """,
      [
        dump(event),
        type,
        key,
        dump(@ids.vault_id),
        dump(@ids.principal_id),
        revision,
        dump(resource),
        dump(version)
      ]
    )
  end

  defp insert_submission_from_event!(event, job_type) do
    sql(
      """
      INSERT INTO jobs.job_submissions(id,vault_id,outbox_event_id,classification,idempotency_key,job_type)
      SELECT id,vault_id,id,classification,idempotency_key,$2 FROM core.outbox_events WHERE id=$1
      """,
      [dump(event), job_type]
    )
  end

  defp assert_claim_cut!(rows) do
    assert [attempt] =
             Enum.filter(
               rows["content.document_versions"],
               &(&1["resource_version_id"] == @ids.extracting_version_id)
             )

    assert attempt["state"] == "extracting"
    assert attempt["attempt_generation"] == 1
    assert attempt["attempt_job_id"] == id(700)
    assert attempt["attempt_started_at"] == "2026-10-11T00:00:00.000000Z"
    assert attempt["attempt_deadline_at"] == "2026-10-11T00:03:00.000000Z"
    assert attempt["extraction_adapter"] == "plain_text"
    assert attempt["extraction_format"] == 1

    assert [] ==
             Enum.filter(
               rows["content.document_fragments"],
               &(&1["resource_version_id"] == @ids.extracting_version_id)
             )

    assert [event] = Enum.filter(rows["core.outbox_events"], &(&1["id"] == id(700)))
    assert event["expected_entity_revision"] == 0
    assert event["causation_id"] == nil

    assert [submission] =
             Enum.filter(rows["jobs.job_submissions"], &(&1["outbox_event_id"] == id(700)))

    assert submission["id"] == id(700)
    assert submission["job_type"] == "document_extract"
    assert submission["vault_id"] == event["vault_id"]
    assert submission["idempotency_key"] == event["idempotency_key"]

    for table <- ~w(jobs.job_progress jobs.effect_receipts) do
      assert [_] = Enum.filter(rows[table], &(&1["submission_id"] == id(700)))
    end
  end

  defp assert_deadline_barrier! do
    assert [[true]] =
             owner(fn ->
               sql(
                 "SELECT attempt_deadline_at<clock_timestamp() FROM content.document_versions WHERE resource_version_id=$1",
                 [dump(@ids.extracting_version_id)]
               ).rows
             end)
  end

  defp assert_empty_receiver! do
    assert [[0, 0, 0, 0, 0]] =
             owner(fn ->
               sql("""
               SELECT (SELECT count(*) FROM core.vaults),(SELECT count(*) FROM content.resources),
                 (SELECT count(*) FROM content.document_versions),(SELECT count(*) FROM core.outbox_events),
                 (SELECT count(*) FROM audit.restore_import_sagas)
               """).rows
             end)
  end

  defp assert_pending_denial_receiver!(destination, bundle, verified) do
    snapshot =
      owner(fn ->
        assert length(@denial_canonical_tables) == 38

        counts =
          Map.new(
            @denial_canonical_tables ++
              ["content.note_source_set_seals", "audit.knowledge_restore_admissions"] ++
              @denial_excluded_tables,
            fn table ->
              assert [[0]] = sql("SELECT count(*) FROM #{table}").rows
              {table, 0}
            end
          )

        optional_receipts =
          case sql("SELECT to_regclass('content.knowledge_mutation_receipts')::text").rows do
            [[nil]] ->
              :absent

            [["content.knowledge_mutation_receipts"]] ->
              assert [[0]] = sql("SELECT count(*) FROM content.knowledge_mutation_receipts").rows
              0
          end

        assert %{columns: columns, rows: [row]} =
                 sql("""
                 SELECT singleton,manifest_id::text AS manifest_id,vault_id::text AS vault_id,
                   manifest_hash,manifest_tag,inventory_hash,destination_root_hash,object_count,state,
                   imported_at,rewrapped_at,reconciled_at,verified_at,completed_at,
                   integrity_principal_id::text AS integrity_principal_id,wrapper_generation,
                   inserted_at,updated_at
                 FROM audit.restore_import_sagas
                 """)

        assert columns ==
                 ~w(singleton manifest_id vault_id manifest_hash manifest_tag inventory_hash
                   destination_root_hash object_count state imported_at rewrapped_at reconciled_at
                   verified_at completed_at integrity_principal_id wrapper_generation inserted_at updated_at)

        marker = Map.new(Enum.zip(columns, row))
        assert marker["singleton"] == true
        assert marker["manifest_id"] == bundle.binding.manifest_id
        assert marker["vault_id"] == bundle.binding.vault_id
        assert marker["manifest_hash"] === verified.manifest_hash
        assert marker["manifest_tag"] === verified.manifest_tag

        assert marker["inventory_hash"] ===
                 :crypto.hash(
                   :sha256,
                   :erlang.term_to_binary(verified.cut.object_inventory, [:deterministic])
                 )

        assert marker["destination_root_hash"] ===
                 :crypto.hash(:sha256, Path.expand(destination.object_root))

        assert marker["object_count"] == length(verified.cut.object_inventory)
        assert marker["state"] == "pending"

        for field <-
              ~w(imported_at rewrapped_at reconciled_at verified_at completed_at integrity_principal_id wrapper_generation) do
          assert marker[field] == nil
        end

        assert %DateTime{} = marker["inserted_at"]
        assert %DateTime{} = marker["updated_at"]

        %{
          counts: counts,
          optional_receipts: optional_receipts,
          saga: %{columns: columns, row: row}
        }
      end)

    assert {:ok, staged} = LocalFilesystemAdapter.list_staged(%{root: destination.object_root})
    assert staged == []

    files =
      Path.wildcard(Path.join(destination.object_root, "**/*"), match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.sort()

    assert files == []
    refute MigrationRepo.in_transaction?()
    Map.merge(snapshot, %{staged: staged, files: files})
  end

  defp all_rows,
    do: KnowledgeBackupFixtures.canonical_rows(%{owner: Map.take(@ids, [:account_id, :vault_id])})

  defp canonical_history, do: canonical_history(all_rows())

  defp canonical_history(rows),
    do: Map.drop(rows, @work_tables ++ @mutable_authority ++ ~w(identity.sessions audit.events))

  defp work_rows, do: Map.take(all_rows(), @work_tables)

  defp document_row(version),
    do:
      Enum.find(all_rows()["content.document_versions"], &(&1["resource_version_id"] == version))

  defp event_row(event), do: Enum.find(all_rows()["core.outbox_events"], &(&1["id"] == event))

  defp successor_row(version, generation) do
    assert [row] =
             Enum.filter(
               all_rows()["core.outbox_events"],
               &(&1["idempotency_key"] == "document-extraction:#{version}:#{generation}")
             )

    row
  end

  defp assert_recovered!(before, mode) do
    version = before["resource_version_id"]
    generation = before["attempt_generation"] + 1
    after_attempt = document_row(version)
    expected = Map.put(before, "attempt_generation", generation)

    expected =
      if before["state"] == "extracting",
        do:
          Map.merge(expected, %{
            "state" => "pending",
            "attempt_job_id" => nil,
            "attempt_started_at" => nil,
            "attempt_deadline_at" => nil,
            "extraction_adapter" => nil,
            "extraction_format" => nil,
            "extracted_text_digest" => nil,
            "detected_language" => nil,
            "failure_code" => nil,
            "attempt_finished_at" => nil
          }),
        else: expected

    assert after_attempt === expected
    event = successor_row(version, generation)
    assert event["event_type"] == "document.extraction_requested"
    assert event["principal_id"] == before["created_by_principal_id"]
    assert event["vault_id"] == before["vault_id"]
    assert event["classification"] == "private"
    assert event["required_capability"] == "asset.read"
    assert event["envelope_version"] == 1
    assert event["expected_entity_revision"] == generation

    assert event["payload"] === %{
             "resource_id" => before["resource_id"],
             "resource_version_id" => version
           }

    assert event["retired_at"] == nil
    assert event["retirement_reason"] == nil

    assert event["causation_id"] ==
             if(mode == :automatic, do: before["attempt_job_id"], else: nil)

    if mode == :automatic, do: assert(event["correlation_id"] == version)

    assert [[principal_epoch, owner_epoch]] =
             owner(fn ->
               sql(
                 "SELECT p.authorization_epoch,v.authorization_epoch FROM identity.principals p CROSS JOIN core.vaults v WHERE p.id=$1 AND v.id=$2",
                 [dump(@ids.principal_id), dump(@ids.vault_id)]
               ).rows
             end)

    assert event["principal_authorization_epoch"] == principal_epoch
    assert event["vault_authorization_epoch"] == owner_epoch
  end

  defp assert_other_history!(before, version) do
    without_attempt = fn rows ->
      Map.update!(
        rows,
        "content.document_versions",
        &Enum.reject(&1, fn row -> row["resource_version_id"] == version end)
      )
    end

    assert without_attempt.(canonical_history()) === without_attempt.(before)
  end

  defp assert_public_denied_unchanged!(config, session, resource) do
    canonical = canonical_history()
    work = work_rows()

    assert {:error, _reason} =
             apply(Singularity.Runtime.Api, :retry_document, [config, session, resource])

    assert canonical_history() === canonical
    assert work_rows() === work
  end

  defp assert_no_automatic!(version) do
    assert {:ok, ids} = DocumentRepository.list_expired_recovery_ids(%{repo: WorkerRepo}, 100)
    refute {version, @ids.vault_id} in ids

    assert {:ok, false} =
             DocumentRepository.recover_expired_with_event(
               %{repo: WorkerRepo},
               version,
               @ids.vault_id
             )
  end

  defp assert_reflected!(event), do: assert_reason!(event, "restore_effect_already_reflected")

  defp assert_reason!(event, reason) do
    assert [[%DateTime{}, ^reason]] =
             owner(fn ->
               sql("SELECT retired_at,retirement_reason FROM core.outbox_events WHERE id=$1", [
                 dump(event)
               ]).rows
             end)
  end

  defp retry_target(:pending), do: {@ids.pending_version_id, @ids.pending_document_id, id(710)}

  defp retry_target(:extracting),
    do: {@ids.extracting_version_id, @ids.extracting_document_id, id(700)}

  defp reauthorize_after_rejection!(:same_epoch_membership), do: reauthorize!()
  defp reauthorize_after_rejection!(:principal_epoch), do: :ok
  defp reauthorize_after_rejection!(:owner_epoch), do: :ok

  defp invalidate_pending_only!(:pending), do: invalidate_authority!(:principal_epoch)
  defp invalidate_pending_only!(:extracting), do: :ok

  defp invalidate_authority!(which) do
    owner(fn ->
      case which do
        :principal_epoch ->
          sql(
            "UPDATE identity.principals SET authorization_epoch=authorization_epoch+1 WHERE id=$1",
            [dump(@ids.principal_id)]
          )

        :owner_epoch ->
          sql("UPDATE core.vaults SET authorization_epoch=authorization_epoch+1 WHERE id=$1", [
            dump(@ids.vault_id)
          ])

        :same_epoch_membership ->
          sql(
            "UPDATE core.vault_members SET revoked_at=clock_timestamp() WHERE principal_id=$1 AND vault_id=$2",
            [dump(@ids.principal_id), dump(@ids.vault_id)]
          )
      end
    end)
  end

  defp reauthorize!,
    do:
      owner(fn ->
        sql(
          "UPDATE core.vault_members SET revoked_at=NULL WHERE principal_id=$1 AND vault_id=$2",
          [dump(@ids.principal_id), dump(@ids.vault_id)]
        )
      end)

  defp remove_extraction_submission! do
    owner(fn ->
      sql("DELETE FROM jobs.job_progress WHERE submission_id=$1", [dump(id(700))])
      sql("DELETE FROM jobs.effect_receipts WHERE submission_id=$1", [dump(id(700))])
      sql("DELETE FROM jobs.job_submissions WHERE id=$1", [dump(id(700))])
    end)
  end

  defp fault_original!(fault) do
    owner(fn ->
      case fault do
        :wrong_payload ->
          sql(
            "UPDATE core.outbox_events SET payload=jsonb_build_object('resource_id',$2::uuid,'resource_version_id',$3::uuid) WHERE id=$1",
            [dump(id(700)), dump(@ids.pending_document_id), dump(@ids.extracting_version_id)]
          )

        :wrong_creator ->
          sql("UPDATE core.outbox_events SET principal_id=$2 WHERE id=$1", [
            dump(id(700)),
            dump(id(103))
          ])

        :wrong_revision ->
          sql("UPDATE core.outbox_events SET expected_entity_revision=1 WHERE id=$1", [
            dump(id(700))
          ])

        :wrong_key ->
          sql(
            "UPDATE core.outbox_events SET idempotency_key='document-extraction:wrong' WHERE id=$1",
            [dump(id(700))]
          )

        :wrong_type ->
          sql("UPDATE core.outbox_events SET event_type='document.ready' WHERE id=$1", [
            dump(id(700))
          ])

        :foreign_owner ->
          # Real second owner/membership, with the UUID still present globally.
          sql("INSERT INTO core.vaults(id) VALUES($1)", [dump(id(799))])

          sql("INSERT INTO core.vault_members(principal_id,vault_id) VALUES($1,$2)", [
            dump(@ids.principal_id),
            dump(id(799))
          ])

          remove_extraction_submission!()

          sql("UPDATE core.outbox_events SET vault_id=$2 WHERE id=$1", [
            dump(id(700)),
            dump(id(799))
          ])

        :wrong_submission ->
          sql("UPDATE jobs.job_submissions SET job_type='document_projection' WHERE id=$1", [
            dump(id(700))
          ])

        :stale_head ->
          replace_document_head!(@ids.extracting_document_id)

        retirement when retirement in [:destructive, :legacy, :auth_invalid] ->
          reason =
            %{
              destructive: "restore_stale_destructive",
              legacy: "legacy_missing_principal_authorization_epoch_provenance",
              auth_invalid: @auth_invalid
            }[retirement]

          sql(
            "UPDATE core.outbox_events SET retired_at=clock_timestamp(),retirement_reason=$2 WHERE id=$1",
            [dump(id(700)), reason]
          )
      end
    end)
  end

  defp replace_document_head!(resource) do
    version = Ecto.UUID.generate()
    job = Ecto.UUID.generate()
    text = "plain original\nsecond line\n"
    locator = %{"version" => 1, "kind" => "text", "start_line" => 1, "end_line" => 2}

    assert %{num_rows: 1} =
             sql("SELECT id FROM content.resources WHERE id=$1 AND vault_id=$2 FOR UPDATE", [
               dump(resource),
               dump(@ids.vault_id)
             ])

    sql(
      """
      INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision)
      SELECT $1,$2,$3,'private',max(revision)+1 FROM content.resource_versions
      WHERE resource_id=$2 AND vault_id=$3
      """,
      [dump(version), dump(resource), dump(@ids.vault_id)]
    )

    sql(
      """
      INSERT INTO content.document_versions(resource_version_id,resource_id,vault_id,classification,
        source_asset_id,source_resource_id,source_resource_version_id,source_object_id,source_digest,
        source_byte_size,media_type,title,created_by_principal_id,inserted_at)
      SELECT $1,$2,vault_id,classification,source_asset_id,source_resource_id,source_resource_version_id,
        source_object_id,source_digest,source_byte_size,media_type,title,created_by_principal_id,CURRENT_TIMESTAMP
      FROM content.document_versions WHERE resource_version_id=$3
      """,
      [dump(version), dump(resource), dump(@ids.extracting_version_id)]
    )

    sql(
      """
      UPDATE content.document_versions SET state='extracting',attempt_generation=1,attempt_job_id=$2,
        attempt_started_at=CURRENT_TIMESTAMP,attempt_deadline_at=CURRENT_TIMESTAMP+interval '180 seconds',
        extraction_adapter='plain_text',extraction_format=1 WHERE resource_version_id=$1
      """,
      [dump(version), dump(job)]
    )

    {:ok, fragment} =
      Singularity.Core.DocumentFragment.new(%{
        resource_id: resource,
        resource_version_id: version,
        owner_scope_id: @ids.vault_id,
        classification: :private,
        ordinal: 0,
        text: text,
        locator: locator
      })

    sql(
      """
      INSERT INTO content.document_fragments(id,resource_id,resource_version_id,vault_id,classification,
        ordinal,text,digest,locator,inserted_at)
      VALUES($1,$2,$3,$4,'private',0,$5,$6,$7,CURRENT_TIMESTAMP)
      """,
      [
        fragment.fragment_id,
        dump(resource),
        dump(version),
        dump(@ids.vault_id),
        text,
        fragment.digest,
        locator
      ]
    )

    sql(
      """
      UPDATE content.document_versions SET state='ready',extracted_text_digest=$2,
        attempt_finished_at=CURRENT_TIMESTAMP WHERE resource_version_id=$1
      """,
      [dump(version), :crypto.hash(:sha256, text)]
    )

    sql("UPDATE content.resources SET current_version_id=$2 WHERE id=$1", [
      dump(resource),
      dump(version)
    ])
  end

  defp seed_native_attempt!(n, deadline, contract) do
    version = id(n * 3)
    resource = id(n * 3 + 1)
    event = id(n * 3 + 2)

    owner(fn ->
      sql(
        "INSERT INTO content.resources(id,vault_id,classification,kind,current_version_id,title) VALUES($1,$2,'private','document',$3,'Native recovery fixture')",
        [dump(resource), dump(@ids.vault_id), dump(version)]
      )

      sql(
        "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',0)",
        [dump(version), dump(resource), dump(@ids.vault_id)]
      )

      sql(
        """
        INSERT INTO content.document_versions(resource_version_id,resource_id,vault_id,classification,
          source_asset_id,source_resource_id,source_resource_version_id,source_object_id,source_digest,
          source_byte_size,media_type,title,created_by_principal_id,inserted_at)
        SELECT $1,$2,vault_id,classification,source_asset_id,source_resource_id,source_resource_version_id,
          source_object_id,source_digest,source_byte_size,media_type,'Native recovery fixture',created_by_principal_id,CURRENT_TIMESTAMP
        FROM content.document_versions WHERE resource_version_id=$3
        """,
        [dump(version), dump(resource), dump(@ids.extracting_version_id)]
      )

      start =
        case deadline do
          :future -> DateTime.utc_now(:microsecond)
          :expired -> ~U[2026-10-10 00:00:00.000000Z]
          :later_expired -> ~U[2026-10-11 01:00:00.000000Z]
        end

      sql(
        """
        UPDATE content.document_versions SET state='extracting',attempt_generation=1,attempt_job_id=$2,
          attempt_started_at=$3::timestamptz,attempt_deadline_at=$3::timestamptz+interval '180 seconds',
          extraction_adapter='plain_text',extraction_format=1 WHERE resource_version_id=$1
        """,
        [dump(version), dump(event), start]
      )

      insert_event!(
        resource,
        version,
        event,
        0,
        if(contract == :wrong_type, do: "document.ready", else: "document.extraction_requested"),
        "document-extraction:#{version}"
      )

      insert_submission_from_event!(event, "document_extract")
    end)

    {version, resource}
  end

  defp with_authenticated_retry(destination, callback) do
    # Existing native repos are started by the disposable destination harness.
    refute Process.whereis(Singularity.Runtime.Documents.ExtractionReconciler)

    assert [[0]] =
             owner(fn ->
               sql("SELECT count(*) FROM identity.sessions WHERE id=$1", [dump(@ids.session_id)]).rows
             end)

    assert {:ok, leases} =
             apply(Singularity.Runtime.KeyLeaseSupervisor, :start_link, [[name: nil]])

    try do
      context = %{
        key_wrapper: KeyWrapper,
        repo: WorkerRepo,
        repository_adapter: CustodyRepository,
        scope: ScopedRepo,
        storage: %{adapter: LocalFilesystemAdapter, context: %{root: destination.object_root}}
      }

      adapters = %{
        authorization: Singularity.Runtime.CustodyReader,
        clock: Singularity.Runtime.CustodyReader,
        context: context,
        idle_lock: fn _ -> :ok end,
        key_reader: Singularity.Runtime.CustodyReader,
        key_wrapper: KeyWrapper,
        lease_supervisor: leases,
        object_key_loader: Singularity.Runtime.CustodyReader
      }

      assert {:ok, custodian} = apply(Singularity.Runtime.KeyCustodian, :start_link, [adapters])

      try do
        assert {:ok, authorization} =
                 apply(Singularity.Runtime.AuthorizationDependencies, :new, [
                   %{
                     store: IdentityRepository,
                     custodian: {Singularity.Runtime.KeyCustodian, custodian}
                   }
                 ])

        runtime = %{
          request_repo: RequestRepo,
          vault_lock: Singularity.Storage.VaultLock,
          authorization_lock: Singularity.Storage.AuthorizationLock,
          scoped_repo: ScopedRepo,
          authorizer: Singularity.Runtime.Authorize,
          authorization: authorization,
          audit: AuditSink,
          document_repository: DocumentRepository
        }

        login = %{
          pre_auth: PreAuth,
          pre_auth_context: PreAuthRepo,
          identity: IdentityRepository,
          identity_context: %{
            repo: RequestRepo,
            clock: fn -> DateTime.utc_now(:microsecond) end,
            session_ttl_seconds: 900
          },
          password_hasher: Argon2PasswordHasher,
          password_hasher_context: @hash_policy,
          audit_fingerprint_secret: :binary.copy(<<0x7A>>, 32),
          random_bytes: &:crypto.strong_rand_bytes/1
        }

        resolve = %{
          pre_auth: PreAuth,
          pre_auth_context: PreAuthRepo,
          custodian: Singularity.Runtime.KeyCustodian,
          custodian_context: custodian
        }

        config = %{
          login: fn attrs -> apply(Singularity.Runtime.Login, :run, [login, attrs]) end,
          resolve_session: fn token ->
            apply(Singularity.Runtime.ResolveSession, :run, [resolve, token])
          end,
          retry_document: fn session, resource ->
            apply(Singularity.Runtime.Documents.Mutate, :retry, [runtime, session, resource])
          end
        }

        before_login = all_rows()
        metadata = receiver_auth_metadata!()
        auth_before = native_auth_rows!()

        attrs = %{
          login: "knowledge-fixture@example.test",
          password: @password,
          source: "document-restore-#{Ecto.UUID.generate()}"
        }

        assert {:error, :unauthenticated} =
                 apply(Singularity.Runtime.Api, :login, [config, attrs])

        failed_auth = native_auth_rows!()
        assert_auth_effects!(auth_before, failed_auth, :failed)
        # Anonymous audit is retained natively, but is not an owner-scoped wire row.
        assert all_rows() === before_login
        assert receiver_auth_metadata!() === metadata

        assert {:ok, verifier} = Argon2PasswordHasher.hash(@hash_policy, @password)

        owner(fn ->
          assert %{num_rows: 1} =
                   sql(
                     "UPDATE identity.credentials SET verifier=$2 WHERE id=$1 AND account_id=$3",
                     [dump(id(102)), verifier, dump(@ids.account_id)]
                   )
        end)

        prepared = receiver_auth_metadata!()
        assert [credential] = metadata.credentials
        assert prepared === %{metadata | credentials: [Map.put(credential, "verifier", verifier)]}
        assert all_rows() === before_login

        assert {:ok, opaque, session} =
                 apply(Singularity.Runtime.Api, :login, [
                   config,
                   %{attrs | source: "document-restore-success-#{Ecto.UUID.generate()}"}
                 ])

        successful_auth = native_auth_rows!()
        assert_auth_effects!(failed_auth, successful_auth, :succeeded)
        assert {:ok, token} = Base.url_decode64(opaque, padding: false)
        assert byte_size(token) == 32
        assert session.session_id != @ids.session_id
        # PreAuth's established resolver omits account_id from its DTO; prove the
        # actual account binding in the native session row below, without filling it.
        assert session.account_id == nil
        assert session.principal_id == @ids.principal_id
        assert session.vault_id == @ids.vault_id
        refute session.unlocked?

        refute apply(Singularity.Runtime.KeyCustodian, :unlocked?, [custodian, session.session_id])

        assert [[account, principal, owner_id, credential_id, true, true]] =
                 owner(fn ->
                   sql(
                     """
                     SELECT account_id,principal_id,vault_id,credential_id,expires_at>clock_timestamp(),token_digest=$2
                     FROM identity.sessions WHERE id=$1 AND revoked_at IS NULL
                     """,
                     [dump(session.session_id), :crypto.hash(:sha256, token)]
                   ).rows
                 end)

        assert [account, principal, owner_id, credential_id] ===
                 Enum.map([@ids.account_id, @ids.principal_id, @ids.vault_id, id(102)], &dump/1)

        assert {:ok, resolved} = apply(Singularity.Runtime.ResolveSession, :run, [resolve, token])
        assert resolved.session_id == session.session_id
        refute resolved.unlocked?
        assert receiver_auth_metadata!() === prepared
        post_login = all_rows()
        assert Map.delete(post_login, "audit.events") === Map.delete(before_login, "audit.events")
        assert [login_audit] = post_login["audit.events"] -- before_login["audit.events"]
        assert before_login["audit.events"] -- post_login["audit.events"] == []
        assert login_audit["operation"] == "identity.login"
        assert login_audit["result"] == "allowed"
        assert login_audit["target_id"] == session.session_id

        # Native target rejects the locked owner even though no custody unlock is
        # required. This callback denial is not an authorization-denial audit path.
        assert {:error, :forbidden} =
                 apply(Singularity.Runtime.Api, :retry_document, [
                   config,
                   session,
                   @ids.extracting_document_id
                 ])

        assert all_rows() === post_login
        assert native_auth_rows!() === successful_auth
        assert receiver_auth_metadata!() === prepared

        owner(fn ->
          assert %{num_rows: 1} =
                   sql(
                     "UPDATE core.vaults SET locked=false WHERE id=$1 AND locked=true",
                     [dump(@ids.vault_id)]
                   )
        end)

        expected =
          Map.update!(post_login, "core.vaults", fn [vault] ->
            [Map.put(vault, "locked", false)]
          end)

        assert all_rows() === expected

        unlocked_metadata = %{
          prepared
          | vaults: Enum.map(prepared.vaults, &Map.put(&1, "locked", false))
        }

        assert receiver_auth_metadata!() === unlocked_metadata
        assert native_auth_rows!() === successful_auth

        refute apply(Singularity.Runtime.KeyCustodian, :unlocked?, [custodian, session.session_id])

        assert {:error, :invalid} =
                 apply(Singularity.Runtime.Api, :retry_document, [
                   config,
                   nil,
                   @ids.extracting_document_id
                 ])

        callback.(config, session)
      after
        if Process.alive?(custodian), do: GenServer.stop(custodian)
      end
    after
      if Process.alive?(leases), do: Supervisor.stop(leases)
    end

    refute Process.whereis(Singularity.Runtime.Documents.ExtractionReconciler)
  end

  defp assert_imported_auth_metadata! do
    assert [[credential, true]] =
             owner(fn ->
               sql(
                 """
                 SELECT to_jsonb(c),c.verifier=s.dummy_verifier FROM identity.credentials c
                 CROSS JOIN identity.security_settings s WHERE c.id=$1 AND s.singleton
                 """,
                 [dump(id(102))]
               ).rows
             end)

    assert credential["account_id"] == @ids.account_id
    assert credential["revoked_at"] == nil
    assert [account] = all_rows()["identity.accounts"]
    assert account["id"] == credential["account_id"]
    assert account["status"] == "active"
    metadata = receiver_auth_metadata!()
    assert [vault] = metadata.vaults
    assert vault["id"] == @ids.vault_id
    assert vault["locked"] == true
    assert [wrapper] = metadata.vault_wrappers
    assert wrapper["wrapper_algorithm"] == "restore_pending"
    assert wrapper["kdf_parameters"] === %{"state" => "restore_pending", "version" => 1}
    refute metadata.domain_wrappers == []
    assert [[0]] = owner(fn -> sql("SELECT count(*) FROM identity.sessions").rows end)
  end

  defp receiver_auth_metadata! do
    owner(fn ->
      Map.new(
        [
          {:credentials, "identity.credentials", "id"},
          {:vaults, "core.vaults", "id"},
          {:principals, "identity.principals", "id"},
          {:members, "core.vault_members", "principal_id,vault_id"},
          {:capabilities, "core.capabilities", "id"},
          {:assignments, "core.principal_capabilities", "principal_id,vault_id,capability_id"},
          {:settings, "identity.security_settings", "singleton"},
          {:domains, "core.key_domains", "id"},
          {:vault_keys, "core.vault_key_versions", "id"},
          {:domain_keys, "core.domain_key_versions", "id"},
          {:vault_wrappers, "core.vault_key_wrappers", "id"},
          {:domain_wrappers, "core.domain_dedup_key_wrappers", "id"}
        ],
        fn {name, table, order} ->
          {name,
           sql("SELECT to_jsonb(t) FROM #{table} t ORDER BY #{order}").rows
           |> Enum.map(fn [row] -> row end)}
        end
      )
    end)
  end

  defp native_auth_rows! do
    owner(fn ->
      Map.new(
        [
          {:attempts, "identity.auth_attempts"},
          {:sessions, "identity.sessions"},
          {:audits, "audit.events"}
        ],
        fn {name, table} ->
          {name,
           sql("SELECT to_jsonb(t) FROM #{table} t ORDER BY id").rows
           |> Enum.map(fn [row] -> row end)}
        end
      )
    end)
  end

  defp assert_auth_effects!(before, after_login, result) do
    for table <- [:attempts, :sessions, :audits],
        do: assert(before[table] -- after_login[table] == [])

    assert [attempt] = after_login.attempts -- before.attempts
    assert attempt["result"] == Atom.to_string(result)
    assert is_binary(attempt["attempted_at"])
    assert [audit] = after_login.audits -- before.audits
    assert audit["correlation_id"] == attempt["correlation_id"]
    assert audit["classification"] == "private"
    assert audit["metadata"] == %{}

    if result == :failed do
      assert after_login.sessions === before.sessions
      assert audit["operation"] == "identity.authentication_attempt"
      assert audit["result"] == "denied"
      assert audit["actor_kind"] == "anonymous"
      assert audit["vault_id"] == nil
      assert audit["principal_id"] == nil
      assert audit["target_id"] == attempt["id"]

      assert audit["anonymous_fingerprint"] ==
               "\\x" <>
                 Base.encode16(
                   :crypto.hash(
                     :sha256,
                     Base.decode16!(String.trim_leading(attempt["login_fingerprint"], "\\x"),
                       case: :mixed
                     ) <>
                       Base.decode16!(String.trim_leading(attempt["source_fingerprint"], "\\x"),
                         case: :mixed
                       )
                   ),
                   case: :lower
                 )
    else
      assert [session] = after_login.sessions -- before.sessions
      assert session["account_id"] == @ids.account_id
      assert session["principal_id"] == @ids.principal_id
      assert session["vault_id"] == @ids.vault_id
      assert audit["operation"] == "identity.login"
      assert audit["result"] == "allowed"
      assert audit["actor_kind"] == "principal"
      assert audit["principal_id"] == @ids.principal_id
      assert audit["vault_id"] == @ids.vault_id
      assert audit["target_id"] == session["id"]
    end
  end

  defp race_behind_resource_lock!(callbacks) do
    parent = self()

    locker =
      Task.async(fn ->
        MigrationRepo.transaction(fn ->
          sql("SET LOCAL ROLE singularity_table_owner")

          sql("SELECT id FROM content.resources WHERE id=$1 FOR UPDATE", [
            dump(@ids.extracting_document_id)
          ])

          send(parent, {:resource_locked, self()})

          receive do
            :release -> :ok
          after
            10_000 -> flunk("resource-lock release not received")
          end
        end)
      end)

    try do
      assert_receive {:resource_locked, locker_pid}, 10_000

      tasks =
        Enum.map(callbacks, fn {repo, callback} ->
          Task.async(fn ->
            repo.checkout(fn ->
              # Worker and request callbacks use their existing pools; report actual
              # native backend locks through pg_stat_activity below, not task start time.
              assert [[backend]] = sql_on(repo, "SELECT pg_backend_pid()").rows
              send(parent, {:race_entered, self(), backend})
              callback.()
            end)
          end)
        end)

      try do
        backends =
          Enum.map(tasks, fn task ->
            pid = task.pid
            assert_receive {:race_entered, ^pid, backend}, 10_000
            backend
          end)

        assert length(Enum.uniq(backends)) == length(callbacks)
        assert_lock_waiters!(backends)
        send(locker_pid, :release)
        assert {:ok, :ok} = Task.await(locker, 10_000)
        Enum.map(tasks, &Task.await(&1, 10_000))
      after
        Enum.each(tasks, fn task ->
          if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
        end)
      end
    after
      if Process.alive?(locker.pid) do
        send(locker.pid, :release)
        Task.shutdown(locker, 1_000)
      end
    end
  end

  defp assert_lock_waiters!(backends) do
    poll_until!(
      fn ->
        [[waiting]] =
          sql(
            """
            SELECT count(DISTINCT pid) FROM pg_locks WHERE pid=ANY($1) AND NOT granted
              AND locktype IN ('tuple','transactionid')
            """,
            [backends]
          ).rows

        waiting == length(backends)
      end,
      "native resource-lock waiters were not observed"
    )
  end

  defp assert_native_blocked!(backends, event) do
    poll_until!(
      fn ->
        [[waiting]] =
          sql(
            "SELECT count(DISTINCT pid) FROM pg_locks WHERE pid=ANY($1) AND NOT granted AND locktype=$2",
            [backends, event]
          ).rows

        waiting == length(backends)
      end,
      "native authorization-lock wait was not observed"
    )
  end

  defp poll_until!(predicate, message) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    poll_until!(predicate, deadline, message)
  end

  defp poll_until!(predicate, deadline, message) do
    if predicate.(),
      do: :ok,
      else:
        (
          assert System.monotonic_time(:millisecond) < deadline, message

          receive do
          after
            10 -> :ok
          end

          poll_until!(predicate, deadline, message)
        )
  end

  defp function_receipt do
    owner(fn ->
      sql("""
      SELECT p.oid::regprocedure::text,pg_get_functiondef(p.oid),r.rolname,p.prosecdef,
        p.proconfig,p.proacl::text,pg_get_function_result(p.oid)
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      JOIN pg_roles r ON r.oid=p.proowner
      WHERE n.nspname IN ('content','core','identity','jobs','audit') AND p.prokind='f'
      ORDER BY p.oid::regprocedure::text
      """).rows
      |> Map.new(fn [signature, definition, name, security, settings, acl, result] ->
        {signature,
         %{
           definition: definition,
           owner: name,
           security_definer: security,
           settings: settings,
           acl: acl,
           result: result
         }}
      end)
    end)
  end

  defp security_receipt do
    owner(fn ->
      %{
        relations:
          sql("""
          SELECT n.nspname,c.relname,c.relowner,c.relacl::text,c.relrowsecurity,c.relforcerowsecurity
          FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
          WHERE n.nspname IN ('content','core','identity','jobs','audit') ORDER BY 1,2
          """).rows,
        policies:
          sql(
            "SELECT * FROM pg_policies WHERE schemaname IN ('content','core','identity','jobs','audit') ORDER BY schemaname,tablename,policyname"
          ).rows,
        roles:
          sql(
            "SELECT rolname,rolsuper,rolinherit,rolcreaterole,rolcreatedb,rolcanlogin,rolreplication,rolbypassrls FROM pg_roles WHERE rolname LIKE 'singularity_%' ORDER BY rolname"
          ).rows,
        memberships:
          sql(
            "SELECT roleid,member,grantor,admin_option FROM pg_auth_members ORDER BY roleid,member,grantor"
          ).rows,
        columns:
          sql(
            "SELECT attrelid::regclass::text,attname,attacl::text FROM pg_attribute WHERE attacl IS NOT NULL ORDER BY 1,2"
          ).rows,
        constraints:
          sql(
            "SELECT conrelid::regclass::text,conname,pg_get_constraintdef(oid) FROM pg_constraint WHERE connamespace IN (SELECT oid FROM pg_namespace WHERE nspname IN ('content','core','identity','jobs','audit')) AND conname<>'outbox_events_retirement_shape_check' ORDER BY 1,2"
          ).rows
      }
    end)
  end

  defp assert_worker_contract! do
    oids =
      owner(fn ->
        Enum.map(@functions, fn signature ->
          [[oid]] = sql("SELECT $1::text::regprocedure::oid", [signature]).rows
          assert is_integer(oid) and oid > 0
          oid
        end)
      end)

    for {oid, allowed} <-
          Enum.zip(oids, ["singularity_worker", "singularity_worker", "singularity_web"]),
        role <- ~w(singularity_worker singularity_web singularity_dispatcher singularity_pre_auth) do
      assert [[granted]] =
               sql("SELECT has_function_privilege($1::text,$2::oid,'EXECUTE')", [role, oid]).rows

      assert granted == (role == allowed)
    end

    for oid <- oids do
      assert [[false]] =
               sql(
                 """
                 SELECT EXISTS(SELECT 1 FROM pg_proc p CROSS JOIN LATERAL aclexplode(
                   COALESCE(p.proacl,acldefault('f',p.proowner))) a
                   WHERE p.oid=$1::oid AND a.grantee=0 AND a.privilege_type='EXECUTE')
                 """,
                 [oid]
               ).rows
    end

    for limit <- [0, 101] do
      assert {:error, %Postgrex.Error{postgres: %{pg_code: "22023"}}} =
               SafeSQL.query(
                 WorkerRepo,
                 "SELECT * FROM content.expired_document_extraction_ids($1)",
                 [limit]
               )
    end

    assert %{columns: ["version_id", "owner_id"], rows: []} =
             sql_on(
               WorkerRepo,
               "SELECT * FROM content.expired_document_extraction_ids(1)"
             )

    for repo <- [WorkerRepo, RequestRepo],
        table <- ~w(content.document_versions content.document_fragments),
        operation <- ["INSERT", "UPDATE", "DELETE", "TRUNCATE"] do
      assert [[false]] =
               sql_on(repo, "SELECT has_table_privilege(current_user,$1,$2)", [table, operation]).rows

      if operation in ["INSERT", "UPDATE"],
        do:
          assert(
            [[false]] ==
              sql_on(repo, "SELECT has_any_column_privilege(current_user,$1,$2)", [
                table,
                operation
              ]).rows
          )
    end
  end

  defp assert_retirement_constraint!(environment) do
    root = Path.join(environment.names.storage_root, "objects")
    File.mkdir_p!(root)
    File.chmod!(environment.names.storage_root, 0o700)
    File.chmod!(root, 0o700)

    fixture =
      KnowledgeBackupFixtures.seed!(%{
        repo: MigrationRepo,
        database: MigrationRepo.config()[:database],
        object_root: root,
        ids: @ids,
        originals: @originals
      })

    assert fixture.owner.vault_id == @ids.vault_id

    for {type, reason} <-
          for(
            type <- ["document.extraction_requested", "document.ready", "asset.verify_requested"],
            reason <- [
              "legacy_missing_principal_authorization_epoch_provenance",
              "restore_effect_already_reflected",
              "restore_stale_destructive"
            ],
            do: {type, reason}
          ) ++ [{"document.extraction_requested", @auth_invalid}] do
      assert {:error, :contract_probe} =
               MigrationRepo.transaction(fn ->
                 sql("SET LOCAL ROLE singularity_table_owner")

                 assert %{num_rows: 1} =
                          sql(
                            "UPDATE core.outbox_events SET event_type=$3,retired_at=clock_timestamp(),retirement_reason=$2 WHERE id=$1",
                            [dump(id(700)), reason, type]
                          )

                 MigrationRepo.rollback(:contract_probe)
               end)
    end

    for {type, retired?, reason} <- [
          {"document.ready", true, @auth_invalid},
          {"document.extraction_requested", false, @auth_invalid},
          {"document.extraction_requested", true, nil}
        ] do
      error =
        assert_raise Postgrex.Error, fn ->
          owner(fn ->
            sql(
              """
              UPDATE core.outbox_events SET event_type=$2,
                retired_at=CASE WHEN $3 THEN clock_timestamp() ELSE NULL END,retirement_reason=$4 WHERE id=$1
              """,
              [dump(id(700)), type, retired?, reason]
            )
          end)
        end

      assert error.postgres.pg_code == "23514"
      assert error.postgres.constraint == "outbox_events_retirement_shape_check"
      assert event_row(id(700))["retired_at"] == nil
    end
  end

  defp assert_runtime_dml_denied! do
    before = all_rows()

    for repo <- [RequestRepo, WorkerRepo],
        table <- ~w(content.document_versions content.document_fragments),
        statement <- [
          "INSERT INTO #{table} SELECT * FROM #{table} WHERE false",
          "UPDATE #{table} SET classification=classification",
          "DELETE FROM #{table}",
          "TRUNCATE #{table}"
        ] do
      assert {:error, %Postgrex.Error{postgres: %{pg_code: "42501"}}} =
               repo.transaction(fn ->
                 case SafeSQL.query(repo, statement) do
                   {:error, error} -> repo.rollback(error)
                   {:ok, _} -> flunk("native runtime DML unexpectedly succeeded")
                 end
               end)

      assert all_rows() === before
    end
  end

  defp owner(callback) do
    assert {:ok, result} =
             MigrationRepo.transaction(fn ->
               sql("SET LOCAL ROLE singularity_table_owner")
               callback.()
             end)

    result
  end

  defp sql(statement, parameters \\ []), do: sql_on(MigrationRepo, statement, parameters)
  defp sql_on(repo, statement, parameters \\ []), do: SafeSQL.query!(repo, statement, parameters)
  defp dump(uuid), do: Ecto.UUID.dump!(uuid)
  defp id(n), do: "60000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")
end
