defmodule Singularity.Runtime.MetadataJobTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope
  alias Singularity.Runtime.AuthorizationDependencies
  alias Singularity.Runtime.Assets.ExtractMetadata
  alias Singularity.Runtime.Authorize
  alias Singularity.Runtime.JobDispatcher
  alias Singularity.Runtime.KeyLease
  alias Singularity.Storage.Crypto.Format
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.Jobs.Progress
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.Postgres.AssetRepository
  alias Singularity.Storage.Postgres.CustodyRepository
  alias Singularity.Storage.Postgres.IdentityRepository
  alias Singularity.Storage.ScopedRepo

  defmodule AllowAuthorize do
    def check_job(_authorization, _repo, _envelope), do: :ok
  end

  defmodule RuntimeScript do
    use Agent

    def start_link(options) do
      Agent.start_link(fn ->
        %{
          lease_calls: [],
          lease_responses: Keyword.get(options, :lease_responses, []),
          step_calls: [],
          step_responses: Keyword.get(options, :step_responses, [])
        }
      end)
    end

    def lease(script, request) do
      Agent.get_and_update(script, fn state ->
        [response | rest] = state.lease_responses

        result =
          case response do
            :waiting_for_unlock ->
              {:error, :waiting_for_unlock}

            {:waiting_for_unlock, callback} when is_function(callback, 1) ->
              :ok = callback.(request)
              {:error, :waiting_for_unlock}

            {:ok, lease} ->
              {:ok, lease}
          end

        {result,
         %{
           state
           | lease_calls: [request | state.lease_calls],
             lease_responses: rest
         }}
      end)
    end

    def metadata_step(script, lease) do
      Agent.get_and_update(script, fn state ->
        [response | rest] = state.step_responses

        result =
          case response do
            {:callback, callback} when is_function(callback, 1) -> callback.(lease)
            result -> result
          end

        {result,
         %{
           state
           | step_calls: [lease | state.step_calls],
             step_responses: rest
         }}
      end)
    end

    def replace(script, lease_responses, step_responses) do
      Agent.update(script, fn state ->
        %{
          state
          | lease_responses: lease_responses,
            step_responses: step_responses
        }
      end)
    end

    def calls(script) do
      Agent.get(script, fn state ->
        %{
          leases: Enum.reverse(state.lease_calls),
          steps: Enum.reverse(state.step_calls)
        }
      end)
    end
  end

  defmodule TerminalFirstCasKeyLease do
    @moduledoc false

    alias Singularity.Core.Error
    alias Singularity.Storage.Postgres.CustodyRepository

    def metadata_step(%{
          binding: binding,
          classification: classification,
          expected: expected,
          next: next,
          owner: owner,
          transact: transact
        }) do
      token = make_ref()
      send(owner, {:terminal_first_cas_ready, self(), token})

      receive do
        {:continue_terminal_first_cas, ^token} -> :ok
      end

      result =
        transact.(fn repo ->
          CustodyRepository.persist_checkpoint(
            repo,
            binding,
            classification,
            expected,
            next
          )
        end)

      send(owner, {:terminal_first_cas_result, result})

      case result do
        {:error, :checkpoint_advanced} -> {:retry, :checkpoint_advanced}
        {:error, %Error{}} = error -> error
        :ok -> {:continue, next}
      end
    end
  end

  setup do
    raw = Fixtures.two_vaults!().one
    {:ok, fixture: metadata_fixture!(raw)}
  end

  test "first claim persists processing revision and same job resumes while another job is stale",
       %{
         fixture: fixture
       } do
    assert {:ok, first} =
             scoped(fixture, fn repo ->
               AssetRepository.begin_or_resume_processing(repo, fixture.envelope)
             end)

    assert first.status == :pending
    assert first.processing_revision == 4
    assert first.asset.state == :processing
    assert first.asset.state_revision == 4
    assert first.object_id == fixture.object_id
    assert first.object_generation == 3
    assert first.declared_media_type == "application/pdf"
    assert first.original_filename == "sample.pdf"
    assert first.plaintext_byte_size == 22
    assert first.checkpoint["version"] == 3
    assert first.checkpoint["processing_revision"] == 4
    assert first.checkpoint["next_chunk_index"] == 0

    assert first.checkpoint["extractor_state"] == %{
             "phase" => "start",
             "declared_media_type" => "application/pdf",
             "plaintext_bytes" => 22
           }

    assert {:ok, resumed} =
             scoped(fixture, fn repo ->
               AssetRepository.begin_or_resume_processing(repo, fixture.envelope)
             end)

    assert resumed.status == :pending
    assert resumed.processing_revision == first.processing_revision
    assert resumed.checkpoint == first.checkpoint

    assert {:ok, stale} =
             scoped(fixture, fn repo ->
               AssetRepository.begin_or_resume_processing(repo, fixture.stale_envelope)
             end)

    assert stale.status == :complete
    assert stale.effect_result == :stale

    assert %{rows: [["processing", 4, 1, "running", 4, 3, checkpoint, 1]]} =
             owner_query(
               """
               SELECT
                 asset.state,
                 asset.state_revision,
                 (SELECT count(*) FROM jobs.job_progress WHERE submission_id = $2),
                 progress.state,
                 progress.processing_revision,
                 progress.checkpoint_version,
                 progress.checkpoint,
                 (SELECT count(*) FROM jobs.effect_receipts WHERE submission_id = $3)
               FROM content.assets AS asset
               JOIN jobs.job_progress AS progress ON progress.submission_id = $2
               WHERE asset.id = $1
               """,
               [
                 Ecto.UUID.dump!(fixture.asset_id),
                 Ecto.UUID.dump!(fixture.envelope.job_id),
                 Ecto.UUID.dump!(fixture.stale_envelope.job_id)
               ]
             )

    assert checkpoint == first.checkpoint
  end

  test "resume rejects a malformed waiting checkpoint before changing state or leasing plaintext",
       %{
         fixture: fixture
       } do
    assert {:ok, claimed} =
             scoped(fixture, fn repo ->
               AssetRepository.begin_or_resume_processing(repo, fixture.envelope)
             end)

    malformed = %{claimed.checkpoint | "next_chunk_index" => 1}

    owner_query(
      """
      UPDATE jobs.job_progress
      SET state = 'waiting_for_unlock', checkpoint = $2::text::jsonb
      WHERE submission_id = $1
      """,
      [Ecto.UUID.dump!(fixture.envelope.job_id), JSON.encode!(malformed)]
    )

    script = start_supervised!({RuntimeScript, lease_responses: []})

    assert {:error, %Error{code: :integrity_failure}} =
             ExtractMetadata.run(runtime_context(fixture, script), fixture.envelope)

    assert RuntimeScript.calls(script) == %{leases: [], steps: []}

    assert %{rows: [["waiting_for_unlock", ^malformed]]} =
             owner_query(
               """
               SELECT state, checkpoint
               FROM jobs.job_progress
               WHERE submission_id = $1
               """,
               [Ecto.UUID.dump!(fixture.envelope.job_id)]
             )
  end

  test "live authorization denial prevents the initial metadata claim and plaintext lease", %{
    fixture: fixture
  } do
    revoke_live_job_authority!(fixture)
    script = start_supervised!({RuntimeScript, lease_responses: []})

    assert {:error, %Error{code: :forbidden}} =
             ExtractMetadata.run(live_runtime_context(fixture, script), fixture.envelope)

    assert RuntimeScript.calls(script) == %{leases: [], steps: []}

    assert %{rows: [["available", 3, 0, 0, 0]]} =
             owner_query(
               """
               SELECT
                 asset.state,
                 asset.state_revision,
                 (SELECT count(*) FROM jobs.job_progress WHERE submission_id = $2),
                 (SELECT count(*) FROM jobs.effect_receipts WHERE submission_id = $2),
                 (SELECT count(*) FROM audit.events
                    WHERE target_id = asset.id
                      AND operation IN ('asset.metadata_completed', 'asset.metadata_failed'))
               FROM content.assets AS asset
               WHERE asset.id = $1
               """,
               [
                 Ecto.UUID.dump!(fixture.asset_id),
                 Ecto.UUID.dump!(fixture.envelope.job_id)
               ]
             )
  end

  test "live authorization denial after lease refusal preserves the running checkpoint", %{
    fixture: fixture
  } do
    revoke_after_lease = fn _request -> revoke_live_job_authority!(fixture) end

    script =
      start_supervised!(
        {RuntimeScript,
         lease_responses: [{:waiting_for_unlock, revoke_after_lease}], step_responses: []}
      )

    assert {:error, %Error{code: :forbidden}} =
             ExtractMetadata.run(live_runtime_context(fixture, script), fixture.envelope)

    assert %{leases: [request], steps: []} = RuntimeScript.calls(script)
    refute Map.has_key?(request, :session_id)

    assert %{rows: [["processing", 4, "running", "0", 0, 0]]} =
             owner_query(
               """
               SELECT
                 asset.state,
                 asset.state_revision,
                 progress.state,
                 progress.checkpoint ->> 'next_chunk_index',
                 (SELECT count(*) FROM jobs.effect_receipts WHERE submission_id = $2),
                 (SELECT count(*) FROM audit.events
                    WHERE target_id = asset.id
                      AND operation IN ('asset.metadata_completed', 'asset.metadata_failed'))
               FROM content.assets AS asset
               JOIN jobs.job_progress AS progress ON progress.submission_id = $2
               WHERE asset.id = $1
               """,
               [
                 Ecto.UUID.dump!(fixture.asset_id),
                 Ecto.UUID.dump!(fixture.envelope.job_id)
               ]
             )
  end

  test "live authorization denial after a committed checkpoint prevents metadata completion", %{
    fixture: fixture
  } do
    metadata = %{
      detected_media_type: "application/pdf",
      plaintext_bytes: 22,
      width: nil,
      height: nil,
      pdf_version: "1.7",
      extractor_version: 1
    }

    initial_checkpoint =
      KeyLease.metadata_checkpoint(
        %{
          job_id: fixture.envelope.job_id,
          vault_id: fixture.envelope.vault_id,
          principal_id: fixture.envelope.principal_id,
          required_capability: fixture.envelope.required_capability,
          principal_authorization_epoch: fixture.envelope.principal_authorization_epoch,
          vault_authorization_epoch: fixture.envelope.vault_authorization_epoch,
          object_id: fixture.object_id,
          object_generation: 3,
          processing_revision: 4
        },
        0,
        %{
          "phase" => "start",
          "declared_media_type" => "application/pdf",
          "plaintext_bytes" => 22
        }
      )

    final_checkpoint = final_checkpoint(initial_checkpoint, metadata)

    checkpoint_then_revoke = fn :completion_lease ->
      assert :ok =
               scoped(fixture, fn repo ->
                 CustodyRepository.persist_checkpoint(
                   repo,
                   checkpoint_binding(initial_checkpoint, fixture),
                   :private,
                   initial_checkpoint,
                   final_checkpoint
                 )
               end)

      revoke_live_job_authority!(fixture)
      {:done, metadata, final_checkpoint}
    end

    script =
      start_supervised!(
        {RuntimeScript,
         lease_responses: [{:ok, :completion_lease}],
         step_responses: [{:callback, checkpoint_then_revoke}]}
      )

    assert {:error, %Error{code: :forbidden}} =
             ExtractMetadata.run(live_runtime_context(fixture, script), fixture.envelope)

    assert %{leases: [_request], steps: [:completion_lease]} = RuntimeScript.calls(script)

    assert %{rows: [["processing", 4, "running", "1", "pending", 0, 0]]} =
             owner_query(
               """
               SELECT
                 asset.state,
                 asset.state_revision,
                 progress.state,
                 progress.checkpoint ->> 'next_chunk_index',
                 metadata.extraction_state,
                 (SELECT count(*) FROM jobs.effect_receipts WHERE submission_id = $2),
                 (SELECT count(*) FROM audit.events
                    WHERE target_id = asset.id
                      AND operation IN ('asset.metadata_completed', 'asset.metadata_failed'))
               FROM content.assets AS asset
               JOIN content.asset_metadata AS metadata ON metadata.asset_id = asset.id
               JOIN jobs.job_progress AS progress ON progress.submission_id = $2
               WHERE asset.id = $1
               """,
               [
                 Ecto.UUID.dump!(fixture.asset_id),
                 Ecto.UUID.dump!(fixture.envelope.job_id)
               ]
             )
  end

  test "successful extraction commits metadata, ready state, search, audit, receipt, and progress once",
       %{
         fixture: fixture
       } do
    assert {:ok, claimed} =
             scoped(fixture, fn repo ->
               AssetRepository.begin_or_resume_processing(repo, fixture.envelope)
             end)

    metadata = %{
      detected_media_type: "application/pdf",
      plaintext_bytes: 22,
      width: nil,
      height: nil,
      pdf_version: "1.7",
      extractor_version: 1
    }

    final_checkpoint = final_checkpoint(claimed.checkpoint, metadata)

    assert :ok =
             scoped(fixture, fn repo ->
               CustodyRepository.persist_checkpoint(
                 repo,
                 checkpoint_binding(claimed.checkpoint, fixture),
                 :private,
                 claimed.checkpoint,
                 final_checkpoint
               )
             end)

    assert {:ok, completed} =
             scoped(fixture, fn repo ->
               AssetRepository.complete_metadata(
                 repo,
                 fixture.envelope,
                 claimed.processing_revision,
                 metadata,
                 final_checkpoint
               )
             end)

    assert completed.status == :complete
    assert completed.effect_result == :applied
    assert completed.asset.state == :ready
    assert completed.asset.state_revision == 5

    assert {:ok, replayed} =
             scoped(fixture, fn repo ->
               AssetRepository.complete_metadata(
                 repo,
                 fixture.envelope,
                 claimed.processing_revision,
                 metadata,
                 final_checkpoint
               )
             end)

    assert replayed.status == :complete
    assert replayed.asset.state_revision == 5

    assert %{
             rows: [
               [
                 "ready",
                 5,
                 "completed",
                 "application/pdf",
                 "1.7",
                 "1",
                 "ready",
                 1,
                 1,
                 "completed",
                 ^final_checkpoint
               ]
             ]
           } =
             owner_query(
               """
               SELECT
                 asset.state,
                 asset.state_revision,
                 metadata.extraction_state,
                 metadata.detected_media_type,
                 metadata.pdf_header_version,
                 metadata.extractor_version,
                 search.state,
                 (SELECT count(*) FROM audit.events
                    WHERE target_id = $1 AND operation = 'asset.metadata_completed'),
                 (SELECT count(*) FROM jobs.effect_receipts
                    WHERE submission_id = $2 AND result = 'applied'),
                 progress.state,
                 progress.checkpoint
               FROM content.assets AS asset
               JOIN content.asset_metadata AS metadata ON metadata.asset_id = asset.id
               JOIN content.asset_search_documents AS search ON search.asset_id = asset.id
               JOIN jobs.job_progress AS progress ON progress.submission_id = $2
               WHERE asset.id = $1
               """,
               [
                 Ecto.UUID.dump!(fixture.asset_id),
                 Ecto.UUID.dump!(fixture.envelope.job_id)
               ]
             )
  end

  test "a losing metadata checkpoint CAS retries without recording terminal failure", %{
    fixture: fixture
  } do
    assert {:ok, claimed} =
             scoped(fixture, fn repo ->
               AssetRepository.begin_or_resume_processing(repo, fixture.envelope)
             end)

    metadata = %{
      detected_media_type: "application/pdf",
      plaintext_bytes: 22,
      width: nil,
      height: nil,
      pdf_version: "1.7",
      extractor_version: 1
    }

    final_checkpoint = final_checkpoint(claimed.checkpoint, metadata)

    assert :ok =
             scoped(fixture, fn repo ->
               CustodyRepository.persist_checkpoint(
                 repo,
                 checkpoint_binding(claimed.checkpoint, fixture),
                 :private,
                 claimed.checkpoint,
                 final_checkpoint
               )
             end)

    script =
      start_supervised!(
        {RuntimeScript,
         lease_responses: [{:ok, :losing_lease}, {:ok, :winning_lease}],
         step_responses: [
           {:retry, :checkpoint_advanced},
           {:done, metadata, final_checkpoint}
         ]}
      )

    context = runtime_context(fixture, script)

    results =
      [
        Task.async(fn -> ExtractMetadata.run(context, fixture.envelope) end),
        Task.async(fn -> ExtractMetadata.run(context, fixture.envelope) end)
      ]
      |> Task.await_many()

    assert Enum.any?(results, &match?({:snooze, 1}, &1))
    assert Enum.any?(results, &match?({:ok, %{state: :ready}}, &1))

    assert %{rows: [["ready", "completed", 1, 0, 1, 0]]} =
             owner_query(
               """
               SELECT
                 asset.state,
                 progress.state,
                 (SELECT count(*) FROM audit.events
                    WHERE target_id = $1 AND operation = 'asset.metadata_completed'),
                 (SELECT count(*) FROM audit.events
                    WHERE target_id = $1 AND operation = 'asset.metadata_failed'),
                 (SELECT count(*) FROM jobs.effect_receipts
                    WHERE submission_id = $2 AND result = 'applied'),
                 (SELECT count(*) FROM jobs.effect_receipts
                    WHERE submission_id = $2 AND result = 'failed')
               FROM content.assets AS asset
               JOIN jobs.job_progress AS progress ON progress.submission_id = $2
               WHERE asset.id = $1
               """,
               [
                 Ecto.UUID.dump!(fixture.asset_id),
                 Ecto.UUID.dump!(fixture.envelope.job_id)
               ]
             )

    assert {:ok, %{state: :ready}} = ExtractMetadata.run(context, fixture.envelope)

    assert %{leases: [_first, _second], steps: [:losing_lease, :winning_lease]} =
             RuntimeScript.calls(script)
  end

  test "a terminal-first checkpoint CAS miss snoozes and replays completed work", %{
    fixture: fixture
  } do
    assert {:ok, claimed} =
             scoped(fixture, fn repo ->
               AssetRepository.begin_or_resume_processing(repo, fixture.envelope)
             end)

    metadata = %{
      detected_media_type: "application/pdf",
      plaintext_bytes: 22,
      width: nil,
      height: nil,
      pdf_version: "1.7",
      extractor_version: 1
    }

    final_checkpoint = final_checkpoint(claimed.checkpoint, metadata)
    binding = checkpoint_binding(claimed.checkpoint, fixture)

    lease = %{
      binding: binding,
      classification: :private,
      expected: claimed.checkpoint,
      next: final_checkpoint,
      owner: self(),
      transact: fn callback -> scoped(fixture, callback) end
    }

    script =
      start_supervised!({RuntimeScript, lease_responses: [{:ok, lease}], step_responses: []})

    context =
      fixture
      |> runtime_context(script)
      |> Map.put(:key_lease, TerminalFirstCasKeyLease)

    loser = Task.async(fn -> ExtractMetadata.run(context, fixture.envelope) end)

    assert_receive {:terminal_first_cas_ready, loser_lease, token}, 5_000

    assert :ok =
             scoped(fixture, fn repo ->
               CustodyRepository.persist_checkpoint(
                 repo,
                 binding,
                 :private,
                 claimed.checkpoint,
                 final_checkpoint
               )
             end)

    assert {:ok, %{asset: %{state: :ready, state_revision: 5}}} =
             scoped(fixture, fn repo ->
               AssetRepository.complete_metadata(
                 repo,
                 fixture.envelope,
                 claimed.processing_revision,
                 metadata,
                 final_checkpoint
               )
             end)

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, fn repo ->
               CustodyRepository.load_checkpoint(repo, binding, :private)
             end)

    send(loser_lease, {:continue_terminal_first_cas, token})

    assert_receive {:terminal_first_cas_result, {:error, :checkpoint_advanced}}, 5_000
    assert {:snooze, 1} = Task.await(loser, 5_000)

    assert {:ok, %{state: :ready, state_revision: 5}} =
             ExtractMetadata.run(context, fixture.envelope)

    assert %{rows: [["ready", "completed", 1, 0, 1, 0]]} =
             owner_query(
               """
               SELECT
                 asset.state,
                 progress.state,
                 (SELECT count(*) FROM audit.events
                    WHERE target_id = $1 AND operation = 'asset.metadata_completed'),
                 (SELECT count(*) FROM audit.events
                    WHERE target_id = $1 AND operation = 'asset.metadata_failed'),
                 (SELECT count(*) FROM jobs.effect_receipts
                    WHERE submission_id = $2 AND result = 'applied'),
                 (SELECT count(*) FROM jobs.effect_receipts
                    WHERE submission_id = $2 AND result = 'failed')
               FROM content.assets AS asset
               JOIN jobs.job_progress AS progress ON progress.submission_id = $2
               WHERE asset.id = $1
               """,
               [
                 Ecto.UUID.dump!(fixture.asset_id),
                 Ecto.UUID.dump!(fixture.envelope.job_id)
               ]
             )

    processing_revision = claimed.processing_revision

    assert %{
             leases: [
               %{
                 purpose: :metadata,
                 processing_revision: ^processing_revision
               }
             ],
             steps: []
           } = RuntimeScript.calls(script)
  end

  test "large PDF may finish from its authenticated first chunk", %{fixture: fixture} do
    plaintext_bytes = Format.chunk_size() + 100

    owner_query(
      "UPDATE content.asset_objects SET plaintext_byte_size = $2 WHERE id = $1",
      [Ecto.UUID.dump!(fixture.object_id), plaintext_bytes]
    )

    owner_query(
      "UPDATE content.asset_metadata SET plaintext_byte_size = $2 WHERE asset_id = $1",
      [Ecto.UUID.dump!(fixture.asset_id), plaintext_bytes]
    )

    assert {:ok, claimed} =
             scoped(fixture, fn repo ->
               AssetRepository.begin_or_resume_processing(repo, fixture.envelope)
             end)

    metadata = %{
      detected_media_type: "application/pdf",
      plaintext_bytes: plaintext_bytes,
      width: nil,
      height: nil,
      pdf_version: "1.7",
      extractor_version: 1
    }

    final_checkpoint = final_checkpoint(claimed.checkpoint, metadata)
    assert final_checkpoint["next_chunk_index"] == 1

    assert :ok =
             scoped(fixture, fn repo ->
               CustodyRepository.persist_checkpoint(
                 repo,
                 checkpoint_binding(claimed.checkpoint, fixture),
                 :private,
                 claimed.checkpoint,
                 final_checkpoint
               )
             end)

    assert {:ok, %{asset: %{state: :ready}}} =
             scoped(fixture, fn repo ->
               AssetRepository.complete_metadata(
                 repo,
                 fixture.envelope,
                 claimed.processing_revision,
                 metadata,
                 final_checkpoint
               )
             end)
  end

  test "terminal extraction failure is atomic and preserves canonical encrypted object evidence",
       %{
         fixture: fixture
       } do
    assert {:ok, claimed} =
             scoped(fixture, fn repo ->
               AssetRepository.begin_or_resume_processing(repo, fixture.envelope)
             end)

    failed_checkpoint =
      claimed.checkpoint
      |> Map.put("next_chunk_index", 1)
      |> Map.put("extractor_state", %{
        "phase" => "failed",
        "error_code" => "unsupported_media_type",
        "declared_media_type" => "application/pdf",
        "plaintext_bytes" => 22
      })

    before_object =
      owner_query(
        "SELECT ciphertext_hash, storage_ref, plaintext_byte_size FROM content.asset_objects WHERE id = $1",
        [Ecto.UUID.dump!(fixture.object_id)]
      ).rows

    assert :ok =
             scoped(fixture, fn repo ->
               CustodyRepository.persist_checkpoint(
                 repo,
                 checkpoint_binding(claimed.checkpoint, fixture),
                 :private,
                 claimed.checkpoint,
                 failed_checkpoint
               )
             end)

    assert {:ok, failed} =
             scoped(fixture, fn repo ->
               AssetRepository.record_metadata_failure(
                 repo,
                 fixture.envelope,
                 claimed.processing_revision,
                 Error.new(:unsupported_media_type),
                 failed_checkpoint
               )
             end)

    assert failed.status == :complete
    assert failed.effect_result == :failed
    assert failed.asset.state == :processing

    assert %{
             rows: [
               [
                 "processing",
                 4,
                 "unsupported_media_type",
                 false,
                 "asset_metadata",
                 "failed",
                 1,
                 1,
                 0
               ]
             ]
           } =
             owner_query(
               """
               SELECT
                 asset.state,
                 asset.state_revision,
                 asset.failure_code,
                 asset.retryable,
                 asset.failed_operation,
                 metadata.extraction_state,
                 (SELECT count(*) FROM audit.events
                    WHERE target_id = $1 AND operation = 'asset.metadata_failed'),
                 (SELECT count(*) FROM jobs.effect_receipts
                    WHERE submission_id = $2 AND result = 'failed'),
                 (SELECT count(*) FROM content.asset_search_documents
                    WHERE asset_id = $1)
               FROM content.assets AS asset
               JOIN content.asset_metadata AS metadata ON metadata.asset_id = asset.id
               WHERE asset.id = $1
               """,
               [
                 Ecto.UUID.dump!(fixture.asset_id),
                 Ecto.UUID.dump!(fixture.envelope.job_id)
               ]
             )

    assert before_object ==
             owner_query(
               "SELECT ciphertext_hash, storage_ref, plaintext_byte_size FROM content.asset_objects WHERE id = $1",
               [Ecto.UUID.dump!(fixture.object_id)]
             ).rows

    assert {:ok, replayed} =
             scoped(fixture, fn repo ->
               AssetRepository.begin_or_resume_processing(repo, fixture.envelope)
             end)

    assert replayed.status == :complete
    assert replayed.effect_result == :failed
    assert replayed.asset.state == :processing

    no_lease_script = start_supervised!({RuntimeScript, lease_responses: []})

    assert {:ok, replayed_asset} =
             ExtractMetadata.run(
               runtime_context(fixture, no_lease_script),
               fixture.envelope
             )

    assert replayed_asset.state == :processing
    assert RuntimeScript.calls(no_lease_script) == %{leases: [], steps: []}
  end

  test "terminal worker exhaustion records a stable metadata failure instead of stranding processing",
       %{
         fixture: fixture
       } do
    assert {:ok, claimed} =
             scoped(fixture, fn repo ->
               AssetRepository.begin_or_resume_processing(repo, fixture.envelope)
             end)

    script = start_supervised!({RuntimeScript, lease_responses: []})
    context = runtime_context(fixture, script)
    failure = Error.new(:storage_unavailable, retryable?: true)

    assert {:ok, recorded} =
             JobDispatcher.handle_failure(
               context,
               fixture.envelope,
               failure,
               %{attempt: 20, max_attempts: 20}
             )

    assert recorded.status == :complete
    assert recorded.effect_result == :failed
    assert recorded.asset.state == :processing
    assert recorded.asset.state_revision == claimed.processing_revision
    checkpoint = claimed.checkpoint

    assert %{rows: [["processing", "storage_unavailable", false, "failed", ^checkpoint, 1, 0]]} =
             owner_query(
               """
               SELECT
                 asset.state,
                 asset.failure_code,
                 asset.retryable,
                 progress.state,
                 progress.checkpoint,
                 (SELECT count(*) FROM jobs.effect_receipts
                    WHERE submission_id = $2 AND result = 'failed'),
                 (SELECT count(*) FROM content.asset_search_documents
                    WHERE asset_id = $1)
               FROM content.assets AS asset
               JOIN jobs.job_progress AS progress ON progress.submission_id = $2
               WHERE asset.id = $1
               """,
               [
                 Ecto.UUID.dump!(fixture.asset_id),
                 Ecto.UUID.dump!(fixture.envelope.job_id)
               ]
             )

    assert {:ok, replayed_asset} = ExtractMetadata.run(context, fixture.envelope)
    assert replayed_asset.state == :processing
    assert RuntimeScript.calls(script) == %{leases: [], steps: []}
  end

  test "metadata progress operations classify non-object checkpoint JSON as integrity failure", %{
    fixture: fixture
  } do
    assert {:ok, claimed} =
             scoped(fixture, fn repo ->
               AssetRepository.begin_or_resume_processing(repo, fixture.envelope)
             end)

    target = %{
      object_id: claimed.object_id,
      object_generation: claimed.object_generation,
      declared_media_type: claimed.declared_media_type,
      plaintext_byte_size: claimed.plaintext_byte_size
    }

    progress_operations = [
      fn repo ->
        Progress.begin_metadata(
          repo,
          fixture.envelope,
          claimed.processing_revision,
          claimed.checkpoint
        )
      end,
      fn repo ->
        Progress.resume_metadata(repo, fixture.envelope, claimed.processing_revision)
      end,
      fn repo ->
        Progress.wait_metadata_for_unlock(
          repo,
          fixture.envelope,
          claimed.processing_revision,
          target
        )
      end,
      fn repo ->
        Progress.transition_metadata(
          repo,
          fixture.envelope,
          claimed.processing_revision,
          claimed.checkpoint,
          :failed
        )
      end
    ]

    script = start_supervised!({RuntimeScript, lease_responses: []})
    context = runtime_context(fixture, script)
    failure = Error.new(:storage_unavailable, retryable?: true)

    for malformed <- ["scalar", ["list"], nil] do
      assert %{num_rows: 1} =
               owner_query(
                 """
                 UPDATE jobs.job_progress
                 SET state = 'running',
                     checkpoint_version = 3,
                     checkpoint = $2::text::jsonb
                 WHERE submission_id = $1
                 """,
                 [
                   Ecto.UUID.dump!(fixture.envelope.job_id),
                   JSON.encode!(malformed)
                 ]
               )

      for operation <- progress_operations do
        assert {:error, %Error{code: :integrity_failure}} =
                 scoped(fixture, operation)
      end

      assert {:error, %Error{code: :integrity_failure}} =
               JobDispatcher.handle_failure(
                 context,
                 fixture.envelope,
                 failure,
                 %{attempt: 20, max_attempts: 20}
               )

      assert %{rows: [["processing", "running", ^malformed, 0, 0]]} =
               owner_query(
                 """
                 SELECT
                   asset.state,
                   progress.state,
                   progress.checkpoint,
                   (SELECT count(*) FROM jobs.effect_receipts
                      WHERE submission_id = $2),
                   (SELECT count(*) FROM audit.events
                      WHERE target_id = $1 AND operation = 'asset.metadata_failed')
                 FROM content.assets AS asset
                 JOIN jobs.job_progress AS progress ON progress.submission_id = $2
                 WHERE asset.id = $1
                 """,
                 [
                   Ecto.UUID.dump!(fixture.asset_id),
                   Ecto.UUID.dump!(fixture.envelope.job_id)
                 ]
               )
    end
  end

  test "unlock wake bridge delegates a bounded vault wake", %{fixture: fixture} do
    assert :ok =
             JobDispatcher.wake_waiting(%{
               session_id: fixture.session_id,
               principal_id: fixture.principal_id,
               vault_id: fixture.vault_id,
               limit: 1
             })

    assert {:error, %Error{code: :invalid}} =
             JobDispatcher.wake_waiting(%{
               vault_id: fixture.vault_id,
               limit: 101
             })
  end

  test "wait for unlock rejects a checkpoint bound to a different target", %{fixture: fixture} do
    assert {:ok, claimed} =
             scoped(fixture, fn repo ->
               AssetRepository.begin_or_resume_processing(repo, fixture.envelope)
             end)

    wrong_checkpoint = %{
      claimed.checkpoint
      | "object_id" => Ecto.UUID.generate(),
        "object_generation" => claimed.object_generation + 1
    }

    assert %{num_rows: 1} =
             owner_query(
               """
               UPDATE jobs.job_progress
               SET checkpoint = $2::text::jsonb
               WHERE submission_id = $1
               """,
               [
                 Ecto.UUID.dump!(fixture.envelope.job_id),
                 JSON.encode!(wrong_checkpoint)
               ]
             )

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, fn repo ->
               Progress.wait_metadata_for_unlock(
                 repo,
                 fixture.envelope,
                 claimed.processing_revision,
                 %{
                   object_id: claimed.object_id,
                   object_generation: claimed.object_generation,
                   declared_media_type: claimed.declared_media_type,
                   plaintext_byte_size: claimed.plaintext_byte_size
                 }
               )
             end)

    assert %{rows: [["running", ^wrong_checkpoint]]} =
             owner_query(
               """
               SELECT state, checkpoint
               FROM jobs.job_progress
               WHERE submission_id = $1
               """,
               [Ecto.UUID.dump!(fixture.envelope.job_id)]
             )
  end

  test "wait for unlock distinguishes malformed progress from a stale identity", %{
    fixture: fixture
  } do
    assert {:ok, claimed} =
             scoped(fixture, fn repo ->
               AssetRepository.begin_or_resume_processing(repo, fixture.envelope)
             end)

    target = %{
      object_id: claimed.object_id,
      object_generation: claimed.object_generation,
      declared_media_type: claimed.declared_media_type,
      plaintext_byte_size: claimed.plaintext_byte_size
    }

    malformed_rows = [
      {2, claimed.checkpoint},
      {3, Map.delete(claimed.checkpoint, "object_id")},
      {3, Map.put(claimed.checkpoint, "next_chunk_index", "zero")}
    ]

    for {checkpoint_version, checkpoint} <- malformed_rows do
      assert %{num_rows: 1} =
               owner_query(
                 """
                 UPDATE jobs.job_progress
                 SET state = 'running',
                     checkpoint_version = $2,
                     checkpoint = $3::text::jsonb
                 WHERE submission_id = $1
                 """,
                 [
                   Ecto.UUID.dump!(fixture.envelope.job_id),
                   checkpoint_version,
                   JSON.encode!(checkpoint)
                 ]
               )

      assert {:error, %Error{code: :integrity_failure}} =
               scoped(fixture, fn repo ->
                 Progress.wait_metadata_for_unlock(
                   repo,
                   fixture.envelope,
                   claimed.processing_revision,
                   target
                 )
               end)
    end

    malformed_and_stale = Map.put(claimed.checkpoint, "unexpected", true)

    assert %{num_rows: 1} =
             owner_query(
               """
               UPDATE jobs.job_progress
               SET state = 'running',
                   checkpoint_version = 3,
                   checkpoint = $2::text::jsonb
               WHERE submission_id = $1
               """,
               [
                 Ecto.UUID.dump!(fixture.envelope.job_id),
                 JSON.encode!(malformed_and_stale)
               ]
             )

    assert {:error, %Error{code: :integrity_failure}} =
             scoped(fixture, fn repo ->
               Progress.wait_metadata_for_unlock(
                 repo,
                 fixture.envelope,
                 claimed.processing_revision + 1,
                 target
               )
             end)

    stale_identity =
      Map.put(claimed.checkpoint, "principal_id", Ecto.UUID.generate())

    assert %{num_rows: 1} =
             owner_query(
               """
               UPDATE jobs.job_progress
               SET state = 'running',
                   checkpoint_version = 3,
                   checkpoint = $2::text::jsonb
               WHERE submission_id = $1
               """,
               [
                 Ecto.UUID.dump!(fixture.envelope.job_id),
                 JSON.encode!(stale_identity)
               ]
             )

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, fn repo ->
               Progress.wait_metadata_for_unlock(
                 repo,
                 fixture.envelope,
                 claimed.processing_revision,
                 target
               )
             end)

    assert %{rows: [["running", ^stale_identity]]} =
             owner_query(
               """
               SELECT state, checkpoint
               FROM jobs.job_progress
               WHERE submission_id = $1
               """,
               [Ecto.UUID.dump!(fixture.envelope.job_id)]
             )
  end

  test "same handler resumes after claim, unlock wait, and committed checkpoint crashes exactly once",
       %{
         fixture: fixture
       } do
    assert {:ok, claimed} =
             scoped(fixture, fn repo ->
               AssetRepository.begin_or_resume_processing(repo, fixture.envelope)
             end)

    script =
      start_supervised!(
        {RuntimeScript, lease_responses: [:waiting_for_unlock], step_responses: []}
      )

    context = runtime_context(fixture, script)

    assert {:snooze, 60} = ExtractMetadata.run(context, fixture.envelope)
    initial_checkpoint = claimed.checkpoint

    assert %{rows: [["processing", 4, "waiting_for_unlock", ^initial_checkpoint]]} =
             owner_query(
               """
               SELECT asset.state, asset.state_revision, progress.state, progress.checkpoint
               FROM content.assets AS asset
               JOIN jobs.job_progress AS progress ON progress.submission_id = $2
               WHERE asset.id = $1
               """,
               [
                 Ecto.UUID.dump!(fixture.asset_id),
                 Ecto.UUID.dump!(fixture.envelope.job_id)
               ]
             )

    metadata = %{
      detected_media_type: "application/pdf",
      plaintext_bytes: 22,
      width: nil,
      height: nil,
      pdf_version: "1.7",
      extractor_version: 1
    }

    final_checkpoint = final_checkpoint(claimed.checkpoint, metadata)

    assert {:ok, %{status: :pending, checkpoint: ^initial_checkpoint}} =
             scoped(fixture, fn repo ->
               AssetRepository.begin_or_resume_processing(repo, fixture.envelope)
             end)

    assert :ok =
             scoped(fixture, fn repo ->
               CustodyRepository.persist_checkpoint(
                 repo,
                 checkpoint_binding(claimed.checkpoint, fixture),
                 :private,
                 claimed.checkpoint,
                 final_checkpoint
               )
             end)

    :ok =
      RuntimeScript.replace(
        script,
        [{:ok, :fresh_lease}],
        [{:done, metadata, final_checkpoint}]
      )

    assert {:ok, ready} = ExtractMetadata.run(context, fixture.envelope)
    assert ready.state == :ready
    assert ready.state_revision == 5

    assert {:ok, replayed} = ExtractMetadata.run(context, fixture.envelope)
    assert replayed.state == :ready

    assert %{leases: [first_request, second_request], steps: [:fresh_lease]} =
             RuntimeScript.calls(script)

    assert first_request == second_request
    refute Map.has_key?(first_request, :session_id)

    assert %{rows: [[1, 1, "completed", "ready"]]} =
             owner_query(
               """
               SELECT
                 (SELECT count(*) FROM audit.events
                    WHERE target_id = $1 AND operation = 'asset.metadata_completed'),
                 (SELECT count(*) FROM jobs.effect_receipts
                    WHERE submission_id = $2 AND result = 'applied'),
                 progress.state,
                 asset.state
               FROM content.assets AS asset
               JOIN jobs.job_progress AS progress ON progress.submission_id = $2
               WHERE asset.id = $1
               """,
               [
                 Ecto.UUID.dump!(fixture.asset_id),
                 Ecto.UUID.dump!(fixture.envelope.job_id)
               ]
             )
  end

  test "wait after a committed CAS preserves the advanced checkpoint", %{fixture: fixture} do
    assert {:ok, claimed} =
             scoped(fixture, fn repo ->
               AssetRepository.begin_or_resume_processing(repo, fixture.envelope)
             end)

    metadata = %{
      detected_media_type: "application/pdf",
      plaintext_bytes: 22,
      width: nil,
      height: nil,
      pdf_version: "1.7",
      extractor_version: 1
    }

    final_checkpoint = final_checkpoint(claimed.checkpoint, metadata)

    persist_then_revoke = fn _request ->
      scoped(fixture, fn repo ->
        CustodyRepository.persist_checkpoint(
          repo,
          checkpoint_binding(claimed.checkpoint, fixture),
          :private,
          claimed.checkpoint,
          final_checkpoint
        )
      end)
    end

    script =
      start_supervised!(
        {RuntimeScript,
         lease_responses: [{:waiting_for_unlock, persist_then_revoke}], step_responses: []}
      )

    context = runtime_context(fixture, script)

    assert {:snooze, 60} = ExtractMetadata.run(context, fixture.envelope)

    assert %{rows: [["waiting_for_unlock", ^final_checkpoint]]} =
             owner_query(
               """
               SELECT state, checkpoint
               FROM jobs.job_progress
               WHERE submission_id = $1
               """,
               [Ecto.UUID.dump!(fixture.envelope.job_id)]
             )

    :ok =
      RuntimeScript.replace(script, [{:ok, :fresh_lease}], [{:done, metadata, final_checkpoint}])

    assert {:ok, ready} = ExtractMetadata.run(context, fixture.envelope)
    assert ready.state == :ready
    assert ready.state_revision == 5
  end

  defp runtime_context(fixture, script) do
    %{
      assets: AssetRepository,
      authorization: :test_authorization,
      authorize: AllowAuthorize,
      custodian: {RuntimeScript, script},
      job_progress: Progress,
      key_lease: {RuntimeScript, script},
      transact: fn _options, callback -> scoped(fixture, callback) end
    }
  end

  defp live_runtime_context(fixture, script) do
    runtime_context(fixture, script)
    |> Map.put(:authorize, Authorize)
    |> Map.put(
      :authorization,
      %AuthorizationDependencies{
        store: IdentityRepository,
        custodian: :unused
      }
    )
  end

  defp revoke_live_job_authority!(fixture) do
    assert %{num_rows: 1} =
             owner_query(
               """
               UPDATE identity.principals
               SET authorization_epoch = authorization_epoch + 1
               WHERE id = $1
               """,
               [Ecto.UUID.dump!(fixture.principal_id)]
             )

    :ok
  end

  defp final_checkpoint(checkpoint, metadata) do
    checkpoint
    |> Map.put("next_chunk_index", 1)
    |> Map.put("extractor_state", %{
      "phase" => "done",
      "result" => %{
        "detected_media_type" => metadata.detected_media_type,
        "plaintext_bytes" => metadata.plaintext_bytes,
        "width" => metadata.width,
        "height" => metadata.height,
        "pdf_version" => metadata.pdf_version,
        "extractor_version" => metadata.extractor_version
      }
    })
  end

  defp checkpoint_binding(checkpoint, _fixture) do
    target = checkpoint_target(checkpoint["extractor_state"])

    %{
      job_id: checkpoint["job_id"],
      vault_id: checkpoint["vault_id"],
      principal_id: checkpoint["principal_id"],
      required_capability: checkpoint["required_capability"],
      principal_authorization_epoch: checkpoint["principal_authorization_epoch"],
      vault_authorization_epoch: checkpoint["vault_authorization_epoch"],
      object_id: checkpoint["object_id"],
      object_generation: checkpoint["object_generation"],
      processing_revision: checkpoint["processing_revision"],
      declared_media_type: target.declared_media_type,
      plaintext_byte_size: target.plaintext_byte_size
    }
  end

  defp checkpoint_target(%{
         "phase" => phase,
         "declared_media_type" => declared_media_type,
         "plaintext_bytes" => plaintext_byte_size
       })
       when phase in ["start", "jpeg_scan", "failed"],
       do: %{
         declared_media_type: declared_media_type,
         plaintext_byte_size: plaintext_byte_size
       }

  defp checkpoint_target(%{
         "phase" => "done",
         "result" => %{
           "detected_media_type" => declared_media_type,
           "plaintext_bytes" => plaintext_byte_size
         }
       }),
       do: %{
         declared_media_type: declared_media_type,
         plaintext_byte_size: plaintext_byte_size
       }

  defp metadata_fixture!(raw) do
    ids = %{
      capability_id: Ecto.UUID.generate(),
      domain_key_version_id: Ecto.UUID.generate(),
      key_domain_id: Ecto.UUID.generate(),
      metadata_id: Ecto.UUID.generate(),
      object_id: Ecto.UUID.generate(),
      source_id: Ecto.UUID.generate(),
      vault_key_version_id: Ecto.UUID.generate()
    }

    fixture = %{
      asset_id: Ecto.UUID.load!(raw.asset_id),
      principal_id: Ecto.UUID.load!(raw.principal_id),
      resource_version_id: Ecto.UUID.load!(raw.resource_version_id),
      session_id: Ecto.UUID.load!(raw.session_id),
      vault_id: Ecto.UUID.load!(raw.vault_id)
    }

    first = metadata_envelope(fixture, Ecto.UUID.generate(), "metadata-primary")
    stale = metadata_envelope(fixture, Ecto.UUID.generate(), "metadata-stale")

    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "UPDATE core.vaults SET locked = false WHERE id = $1", [raw.vault_id])

      query!(
        MigrationRepo,
        """
        INSERT INTO core.capabilities (id, name)
        VALUES ($1, 'asset.read')
        ON CONFLICT (name) DO NOTHING
        """,
        [Ecto.UUID.dump!(ids.capability_id)]
      )

      %{rows: [[capability_id]]} =
        query!(
          MigrationRepo,
          "SELECT id FROM core.capabilities WHERE name = 'asset.read'"
        )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.principal_capabilities (
          principal_id, vault_id, capability_id
        ) VALUES ($1, $2, $3)
        """,
        [raw.principal_id, raw.vault_id, capability_id]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.vault_key_versions (
          id, vault_id, generation, state, algorithm, activated_at
        ) VALUES ($1, $2, 1, 'active', 'aes_256_gcm', CURRENT_TIMESTAMP)
        """,
        [Ecto.UUID.dump!(ids.vault_key_version_id), raw.vault_id]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.key_domains (id, vault_id, classification, kind, state)
        VALUES ($1, $2, 'private', 'content', 'active')
        """,
        [Ecto.UUID.dump!(ids.key_domain_id), raw.vault_id]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.domain_key_versions (
          id, vault_id, key_domain_id, vault_key_version_id,
          generation, state, algorithm, wrapped_key
        ) VALUES ($1, $2, $3, $4, 5, 'active', 'aes_256_gcm', $5)
        """,
        [
          Ecto.UUID.dump!(ids.domain_key_version_id),
          raw.vault_id,
          Ecto.UUID.dump!(ids.key_domain_id),
          Ecto.UUID.dump!(ids.vault_key_version_id),
          :crypto.strong_rand_bytes(60)
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO content.asset_objects (
          id, vault_id, key_domain_id, classification, lookup_digest,
          ciphertext_hash, plaintext_byte_size, ciphertext_byte_size,
          storage_ref, format_version, lifecycle
        ) VALUES ($1, $2, $3, 'private', $4, $5, 22, 180, $6, 1, 'available')
        """,
        [
          Ecto.UUID.dump!(ids.object_id),
          raw.vault_id,
          Ecto.UUID.dump!(ids.key_domain_id),
          :crypto.strong_rand_bytes(32),
          :crypto.strong_rand_bytes(32),
          ids.object_id
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO content.asset_key_envelopes (
          id, vault_id, asset_object_id, domain_key_version_id, key_domain_id,
          classification, algorithm, key_generation, wrapped_dek
        ) VALUES ($1, $2, $3, $4, $5, 'private', 'aes_256_gcm', 3, $6)
        """,
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          raw.vault_id,
          Ecto.UUID.dump!(ids.object_id),
          Ecto.UUID.dump!(ids.domain_key_version_id),
          Ecto.UUID.dump!(ids.key_domain_id),
          :crypto.strong_rand_bytes(60)
        ]
      )

      query!(
        MigrationRepo,
        """
        UPDATE content.assets
        SET asset_object_id = $2, state = 'available', state_revision = 3
        WHERE id = $1
        """,
        [raw.asset_id, Ecto.UUID.dump!(ids.object_id)]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO content.source_references (
          id, vault_id, resource_version_id, principal_id, classification,
          kind, observed_at, original_filename, declared_media_type,
          byte_size, idempotency_key_digest
        ) VALUES (
          $1, $2, $3, $4, 'private', 'browser_upload', CURRENT_TIMESTAMP,
          'sample.pdf', 'application/pdf', 22, $5
        )
        """,
        [
          Ecto.UUID.dump!(ids.source_id),
          raw.vault_id,
          raw.resource_version_id,
          raw.principal_id,
          :crypto.strong_rand_bytes(32)
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO content.asset_metadata (
          id, asset_id, resource_version_id, vault_id, classification,
          projection_version, original_filename, declared_media_type,
          plaintext_byte_size, extraction_state
        ) VALUES ($1, $2, $3, $4, 'private', 1, 'sample.pdf',
                  'application/pdf', 22, 'pending')
        """,
        [
          Ecto.UUID.dump!(ids.metadata_id),
          raw.asset_id,
          raw.resource_version_id,
          raw.vault_id
        ]
      )

      Enum.each([first, stale], &insert_job!(&1, raw.vault_id))
    end)

    Map.merge(fixture, %{
      object_id: ids.object_id,
      envelope: first,
      stale_envelope: stale
    })
  end

  defp insert_job!(envelope, raw_vault_id) do
    query!(
      MigrationRepo,
      """
      INSERT INTO core.outbox_events (
        id, event_type, idempotency_key, vault_id, principal_id,
        required_capability, principal_authorization_epoch,
        vault_authorization_epoch, classification, correlation_id,
        causation_id, expected_entity_revision, envelope_version,
        payload, occurred_at
      ) VALUES (
        $1, 'asset.metadata_requested', $2, $3, $4, 'asset.read',
        0, 0, 'private', $5, $6, 3, 1, $7::text::jsonb,
        CURRENT_TIMESTAMP
      )
      """,
      [
        Ecto.UUID.dump!(envelope.job_id),
        envelope.idempotency_key,
        raw_vault_id,
        Ecto.UUID.dump!(envelope.principal_id),
        Ecto.UUID.dump!(envelope.correlation_id),
        Ecto.UUID.dump!(envelope.causation_id),
        JSON.encode!(envelope.payload)
      ]
    )

    query!(
      MigrationRepo,
      """
      INSERT INTO jobs.job_submissions (
        id, vault_id, outbox_event_id, classification, idempotency_key, job_type
      ) VALUES ($1, $2, $1, 'private', $3, 'asset_metadata')
      """,
      [
        Ecto.UUID.dump!(envelope.job_id),
        raw_vault_id,
        envelope.idempotency_key
      ]
    )
  end

  defp metadata_envelope(fixture, job_id, idempotency_key) do
    {:ok, envelope} =
      JobEnvelope.new(%{
        version: 1,
        job_id: job_id,
        job_type: "asset_metadata",
        idempotency_key: idempotency_key,
        vault_id: fixture.vault_id,
        principal_id: fixture.principal_id,
        required_capability: "asset.read",
        principal_authorization_epoch: 0,
        vault_authorization_epoch: 0,
        classification: :private,
        correlation_id: Ecto.UUID.generate(),
        causation_id: Ecto.UUID.generate(),
        expected_entity_revision: 3,
        attempt: 0,
        payload: %{"asset_id" => fixture.asset_id}
      })

    envelope
  end

  defp scoped(fixture, callback) do
    ScopedRepo.transact(
      WorkerRepo,
      %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
      callback
    )
  end

  defp owner_query(statement, parameters) do
    Fixtures.with_owner(fn -> query!(MigrationRepo, statement, parameters) end)
  end
end
