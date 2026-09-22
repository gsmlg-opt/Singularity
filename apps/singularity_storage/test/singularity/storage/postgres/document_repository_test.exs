defmodule Singularity.Storage.Postgres.DocumentRepositoryTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  alias Singularity.Core.{DocumentCompletion, DocumentFragment, DocumentVersion, Error}

  alias Singularity.Storage.{
    Fixtures,
    KnowledgeFixtures,
    KnowledgeTestGrants,
    MigrationRepo,
    ScopedRepo
  }

  alias Singularity.Storage.Postgres.DocumentRepository

  setup do
    source = KnowledgeFixtures.prepared_source!()

    %{
      source: source,
      context: KnowledgeFixtures.document_context(source),
      command: KnowledgeFixtures.document_command(source)
    }
  end

  test "creates pending aggregate with immutable source and preparation outside transaction", c do
    context = %{
      c.context
      | digest_operation: fn _, binding ->
          refute RequestRepo.in_transaction?()
          assert binding.resource_version_id == c.source.resource_version_id
          {:ok, %{sha256: c.source.digest, byte_size: 12}}
        end
    }

    grants(fn ->
      assert {:ok, %DocumentVersion{state: :pending, generation: 0, revision: 0} = document} =
               DocumentRepository.create_pending(context, c.command)

      assert document.resource_id == c.command.resource_id
      assert document.source == c.command.source

      assert {:ok, ^document} =
               DocumentRepository.get_version(
                 context,
                 document.resource_id,
                 document.resource_version_id
               )
    end)

    assert %{rows: [[false, false]]} =
             query!(
               RequestRepo,
               "SELECT has_table_privilege(current_user,'content.document_versions','SELECT'), has_table_privilege(current_user,'content.document_import_receipts','UPDATE')"
             )
  end

  test "new import emits one IDs-only extraction event with live authorization", c do
    grants(fn ->
      assert {:ok, document} = DocumentRepository.create_pending(c.context, c.command)

      assert [event] = extraction_events(c)

      assert event["payload"] == %{
               "resource_id" => document.resource_id,
               "resource_version_id" => document.resource_version_id
             }

      assert event["event_type"] == "document.extraction_requested"
      assert event["required_capability"] == "asset.read"
      assert event["classification"] == "private"
      assert event["causation_id"] == c.command.mutation_id
      assert event["correlation_id"] == c.command.correlation_id
      assert event["idempotency_key"] == "document-extraction:#{document.resource_version_id}"
      assert event["expected_entity_revision"] == 0

      assert {:ok, %{rows: [[principal_epoch, vault_epoch]]}} =
               ScopedRepo.transact(
                 RequestRepo,
                 %{principal_id: c.context.principal_id, vault_id: c.context.owner_scope_id},
                 fn repo ->
                   {:ok,
                    query!(
                      repo,
                      "SELECT principal_authorization_epoch, vault_authorization_epoch FROM core.live_principal_authorization() WHERE principal_id=$1 AND vault_id=$2",
                      [
                        Ecto.UUID.dump!(c.context.principal_id),
                        Ecto.UUID.dump!(c.context.owner_scope_id)
                      ]
                    )}
                 end
               )

      assert event["principal_authorization_epoch"] == principal_epoch
      assert event["vault_authorization_epoch"] == vault_epoch
    end)
  end

  test "replay ignores candidate IDs and time but preserves current lifecycle", c do
    grants(fn ->
      assert {:ok, first} = DocumentRepository.create_pending(c.context, c.command)

      retry = %{
        c.command
        | resource_id: Ecto.UUID.generate(),
          resource_version_id: Ecto.UUID.generate(),
          inserted_at: DateTime.add(c.command.inserted_at, 60),
          correlation_id: Ecto.UUID.generate()
      }

      assert {:ok, ^first} = DocumentRepository.create_pending(c.context, retry)
      assert [_event] = extraction_events(c)

      KnowledgeTestGrants.with_lifecycle_grants(fn ->
        job = Ecto.UUID.generate()

        assert {:ok, %DocumentVersion{state: :extracting, generation: 1} = claimed} =
                 DocumentRepository.claim(
                   c.context,
                   first.resource_version_id,
                   0,
                   job,
                   "plain",
                   1
                 )

        assert {:ok, ^claimed} = DocumentRepository.create_pending(c.context, retry)

        assert {:error, %Error{code: :conflict}} =
                 DocumentRepository.claim(
                   c.context,
                   first.resource_version_id,
                   0,
                   Ecto.UUID.generate(),
                   "plain",
                   1
                 )
      end)
    end)
  end

  test "same mutation changed title conflicts and distinct mutation creates a separate document",
       c do
    grants(fn ->
      assert {:ok, first} = DocumentRepository.create_pending(c.context, c.command)

      assert {:error, %Error{code: :conflict, message: nil, details: %{}}} =
               DocumentRepository.create_pending(c.context, %{c.command | title: "Other"})

      assert [_event] = extraction_events(c)

      assert {:ok, second} =
               DocumentRepository.create_pending(
                 c.context,
                 KnowledgeFixtures.document_command(c.source)
               )

      refute first.resource_id == second.resource_id
      assert first.source == second.source
      assert [_first_event, _second_event] = extraction_events(c)
    end)
  end

  test "concurrent same mutation returns a single winner", c do
    grants(fn ->
      tasks =
        for _ <- 1..4 do
          Task.async(fn ->
            DocumentRepository.create_pending(
              c.context,
              %{
                c.command
                | resource_id: Ecto.UUID.generate(),
                  resource_version_id: Ecto.UUID.generate()
              }
            )
          end)
        end

      results = Enum.map(tasks, &Task.await(&1, 15_000))
      assert [{:ok, %DocumentVersion{}}] = Enum.uniq(results)
    end)
  end

  test "source race rolls back aggregate and receipt", c do
    context = %{
      c.context
      | digest_operation: fn _, _ ->
          Fixtures.with_owner(fn ->
            query!(
              MigrationRepo,
              "UPDATE content.resource_assets SET released_at=CURRENT_TIMESTAMP WHERE asset_id=$1",
              [Ecto.UUID.dump!(c.source.asset_id)]
            )
          end)

          {:ok, %{sha256: c.source.digest, byte_size: 12}}
        end
    }

    grants(fn ->
      assert {:error, %Error{}} = DocumentRepository.create_pending(context, c.command)
      assert_counts(c, 0, 0)
    end)
  end

  test "outbox insertion failure rolls back document and receipt", c do
    grants(fn ->
      Fixtures.with_owner(fn ->
        query!(MigrationRepo, "REVOKE INSERT ON core.outbox_events FROM singularity_web")
      end)

      try do
        assert {:error, %Error{}} = DocumentRepository.create_pending(c.context, c.command)
        assert_counts(c, 0, 0)
        assert [] = extraction_events(c)
      after
        Fixtures.with_owner(fn ->
          query!(MigrationRepo, "GRANT INSERT ON core.outbox_events TO singularity_web")
        end)
      end
    end)
  end

  test "source access is required even for a completed receipt replay", c do
    grants(fn ->
      assert {:ok, _} = DocumentRepository.create_pending(c.context, c.command)

      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "UPDATE content.resource_assets SET released_at=CURRENT_TIMESTAMP WHERE asset_id=$1",
          [Ecto.UUID.dump!(c.source.asset_id)]
        )
      end)

      assert {:error, %Error{code: :not_found}} =
               DocumentRepository.create_pending(c.context, c.command)
    end)
  end

  test "forged command source, principal, invalid struct and caller preparation fail closed", c do
    grants(fn ->
      for command <- [
            %{c.command | title: ""},
            %{c.command | principal_id: Ecto.UUID.generate()},
            %{c.command | source: %{c.command.source | digest: :binary.copy(<<9>>, 32)}}
          ] do
        assert {:error, %Error{message: nil, details: %{}}} =
                 DocumentRepository.create_pending(c.context, command)
      end

      assert {:error, %Error{}} =
               DocumentRepository.create_pending(
                 Map.delete(c.context, :digest_operation),
                 c.command
               )

      assert {:error, %Error{code: :invalid}} =
               ScopedRepo.transact(
                 RequestRepo,
                 %{principal_id: c.context.principal_id, vault_id: c.context.owner_scope_id},
                 fn _ -> DocumentRepository.create_pending(c.context, c.command) end
               )

      assert_counts(c, 0, 0)
    end)
  end

  test "failure completion and reset use guarded lifecycle and reject stale generation", c do
    grants(fn ->
      KnowledgeTestGrants.with_lifecycle_grants(fn ->
        {:ok, document} = DocumentRepository.create_pending(c.context, c.command)
        job = Ecto.UUID.generate()

        {:ok, _} =
          DocumentRepository.claim(c.context, document.resource_version_id, 0, job, "plain", 1)

        {:ok, completion} =
          DocumentCompletion.new(%{
            resource_id: document.resource_id,
            resource_version_id: document.resource_version_id,
            owner_scope_id: document.owner_scope_id,
            classification: :private,
            generation: 1,
            outcome: :failed,
            adapter_name: "plain",
            format_version: 1,
            finished_at: DateTime.utc_now(:microsecond),
            media_type: "text/plain",
            failure_code: "timeout"
          })

        assert {:ok, %DocumentVersion{state: :failed, failure_code: "timeout"}} =
                 DocumentRepository.complete(c.context, job, completion)

        assert {:error, %Error{code: :conflict}} =
                 DocumentRepository.reset_failed(
                   c.context,
                   document.resource_version_id,
                   0,
                   "plain",
                   1
                 )

        assert {:ok, %DocumentVersion{state: :pending, generation: 1}} =
                 DocumentRepository.reset_failed(
                   c.context,
                   document.resource_version_id,
                   1,
                   "plain",
                   1
                 )

        assert {:error, %Error{code: :invalid}} =
                 DocumentRepository.complete(c.context, job, %{completion | generation: -1})
      end)
    end)
  end

  test "claimed job can finish after tombstone while public lookup and new claims stay closed",
       c do
    grants(fn ->
      KnowledgeTestGrants.with_lifecycle_grants(fn ->
        for outcome <- [:failed, :ready] do
          {:ok, document} =
            DocumentRepository.create_pending(
              c.context,
              KnowledgeFixtures.document_command(c.source)
            )

          job = Ecto.UUID.generate()

          assert {:ok, %DocumentVersion{state: :extracting}} =
                   DocumentRepository.claim(
                     c.context,
                     document.resource_version_id,
                     0,
                     job,
                     "plain",
                     1
                   )

          Fixtures.with_owner(fn ->
            query!(
              MigrationRepo,
              "UPDATE content.resources SET deleted_at = CURRENT_TIMESTAMP WHERE id = $1",
              [Ecto.UUID.dump!(document.resource_id)]
            )
          end)

          assert {:error, %Error{code: :not_found}} =
                   DocumentRepository.get_version(
                     c.context,
                     document.resource_id,
                     document.resource_version_id
                   )

          assert {:error, %Error{}} =
                   DocumentRepository.claim(
                     c.context,
                     document.resource_version_id,
                     0,
                     Ecto.UUID.generate(),
                     "plain",
                     1
                   )

          identity = %{
            resource_id: document.resource_id,
            resource_version_id: document.resource_version_id,
            owner_scope_id: document.owner_scope_id,
            classification: :private,
            generation: 1,
            adapter_name: "plain",
            format_version: 1,
            finished_at: DateTime.utc_now(:microsecond),
            media_type: "text/plain"
          }

          attrs =
            case outcome do
              :failed ->
                Map.merge(identity, %{outcome: :failed, failure_code: "timeout"})

              :ready ->
                {:ok, fragment} =
                  DocumentFragment.new(%{
                    resource_id: document.resource_id,
                    resource_version_id: document.resource_version_id,
                    owner_scope_id: document.owner_scope_id,
                    classification: :private,
                    ordinal: 0,
                    text: "hello",
                    locator: %{
                      "version" => 1,
                      "kind" => "text",
                      "start_line" => 1,
                      "end_line" => 1
                    }
                  })

                Map.merge(identity, %{
                  outcome: :ready,
                  fragments: [fragment],
                  extracted_text_digest: :crypto.hash(:sha256, "hello")
                })
            end

          {:ok, completion} = DocumentCompletion.new(attrs)

          assert {:error, %Error{code: :conflict}} =
                   DocumentRepository.complete(c.context, Ecto.UUID.generate(), completion)

          if outcome == :failed do
            assert {:error, %Error{code: :not_found}} =
                     DocumentRepository.complete(
                       c.context,
                       job,
                       %{completion | resource_id: Ecto.UUID.generate()}
                     )

            other = KnowledgeFixtures.prepared_source!()
            other_context = KnowledgeFixtures.document_context(other)

            assert {:error, %Error{code: :not_found}} =
                     DocumentRepository.complete(
                       other_context,
                       job,
                       %{completion | owner_scope_id: other.vault_id}
                     )
          end

          KnowledgeTestGrants.with_fragment_read_grants(fn ->
            assert {:ok, %DocumentVersion{state: ^outcome}} =
                     DocumentRepository.complete(c.context, job, completion)
          end)

          assert {:error, %Error{code: :not_found}} =
                   DocumentRepository.get_version(
                     c.context,
                     document.resource_id,
                     document.resource_version_id
                   )
        end
      end)
    end)
  end

  test "attempt claim binds a job and fixed database deadline", c do
    grants(fn ->
      KnowledgeTestGrants.with_lifecycle_grants(fn ->
        {:ok, document} = DocumentRepository.create_pending(c.context, c.command)
        job_a = Ecto.UUID.generate()
        job_b = Ecto.UUID.generate()

        assert {:ok,
                %DocumentVersion{state: :extracting, generation: 1, attempt_job_id: ^job_a} =
                  claimed} =
                 DocumentRepository.claim(
                   c.context,
                   document.resource_version_id,
                   0,
                   job_a,
                   "plain",
                   1
                 )

        assert DateTime.diff(
                 claimed.attempt_deadline_at,
                 claimed.attempt_started_at,
                 :microsecond
               ) ==
                 180_000_000

        assert {:ok, ^claimed} =
                 DocumentRepository.claim(
                   c.context,
                   document.resource_version_id,
                   0,
                   job_a,
                   "plain",
                   1
                 )

        assert {:error, %Error{code: :conflict}} =
                 DocumentRepository.claim(
                   c.context,
                   document.resource_version_id,
                   0,
                   job_b,
                   "plain",
                   1
                 )

        assert {:error, %Error{code: :invalid, message: nil, details: %{}}} =
                 DocumentRepository.claim(
                   c.context,
                   document.resource_version_id,
                   0,
                   String.upcase(job_a),
                   "plain",
                   1
                 )
      end)
    end)
  end

  test "ready completion hydrates canonical fragments, exact replay, and rejects forged identity",
       c do
    grants(fn ->
      KnowledgeTestGrants.with_lifecycle_grants(fn ->
        KnowledgeTestGrants.with_fragment_read_grants(fn ->
          {:ok, document} = DocumentRepository.create_pending(c.context, c.command)
          job = Ecto.UUID.generate()

          {:ok, _} =
            DocumentRepository.claim(c.context, document.resource_version_id, 0, job, "plain", 1)

          identity = %{
            resource_id: document.resource_id,
            resource_version_id: document.resource_version_id,
            owner_scope_id: document.owner_scope_id,
            classification: :private
          }

          {:ok, fragment} =
            DocumentFragment.new(
              Map.merge(identity, %{
                ordinal: 0,
                text: "hello",
                locator: %{"version" => 1, "kind" => "text", "start_line" => 1, "end_line" => 1}
              })
            )

          {:ok, completion} =
            DocumentCompletion.new(
              Map.merge(identity, %{
                generation: 1,
                outcome: :ready,
                adapter_name: "plain",
                format_version: 1,
                finished_at: ~U[2020-01-01 00:00:00.000000Z],
                media_type: "text/plain",
                fragments: [fragment],
                extracted_text_digest: :crypto.hash(:sha256, "hello")
              })
            )

          for forged <- [
                %{completion | resource_id: Ecto.UUID.generate()},
                %{completion | owner_scope_id: Ecto.UUID.generate()},
                %{completion | adapter_name: "other"},
                %{completion | format_version: 2}
              ] do
            assert {:error, %Error{}} = DocumentRepository.complete(c.context, job, forged)
          end

          assert {:ok, %DocumentVersion{state: :ready, fragments: [^fragment]} = ready} =
                   DocumentRepository.complete(c.context, job, completion)

          refute ready.finished_at == completion.finished_at
          assert {:ok, ^ready} = DocumentRepository.complete(c.context, job, completion)
          assert {:ok, ^ready} = DocumentRepository.create_pending(c.context, c.command)
        end)
      end)
    end)
  end

  test "completed replay revalidates source changes after preparation", c do
    grants(fn ->
      assert {:ok, _} = DocumentRepository.create_pending(c.context, c.command)

      context = %{
        c.context
        | digest_operation: fn _, _ ->
            Fixtures.with_owner(fn ->
              query!(
                MigrationRepo,
                "UPDATE content.resource_assets SET released_at=CURRENT_TIMESTAMP WHERE asset_id=$1",
                [Ecto.UUID.dump!(c.source.asset_id)]
              )
            end)

            {:ok, %{sha256: c.source.digest, byte_size: 12}}
          end
      }

      assert {:error, %Error{code: :not_found}} =
               DocumentRepository.create_pending(context, c.command)

      assert_counts(c, 1, 1)
    end)
  end

  defp grants(fun),
    do:
      KnowledgeTestGrants.with_grants(["document_versions"], fn ->
        KnowledgeTestGrants.with_receipt_grants(fun)
      end)

  defp extraction_events(c) do
    Fixtures.with_owner(fn ->
      %{rows: rows} =
        query!(
          MigrationRepo,
          "SELECT to_jsonb(event) FROM core.outbox_events AS event WHERE vault_id=$1 AND event_type='document.extraction_requested' ORDER BY sequence",
          [Ecto.UUID.dump!(c.context.owner_scope_id)]
        )

      Enum.map(rows, fn [event] -> event end)
    end)
  end

  defp assert_counts(c, documents, receipts) do
    Fixtures.with_owner(fn ->
      assert %{rows: [[^documents]]} =
               query!(
                 MigrationRepo,
                 "SELECT count(*) FROM content.document_versions WHERE resource_version_id=$1",
                 [Ecto.UUID.dump!(c.command.resource_version_id)]
               )

      assert %{rows: [[^receipts]]} =
               query!(
                 MigrationRepo,
                 "SELECT count(*) FROM content.document_import_receipts WHERE mutation_id=$1",
                 [Ecto.UUID.dump!(c.command.mutation_id)]
               )
    end)
  end
end
