defmodule Singularity.Runtime.JobDispatcherAssetEventsTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope
  alias Singularity.Runtime.JobDispatcher

  @vault_id "00000000-0000-4000-8000-000000000901"
  @asset_id "00000000-0000-4000-8000-000000000902"

  defmodule Events do
    def publish(owner, vault_id, asset_id) do
      send(owner, {:asset_event, vault_id, asset_id})

      case Process.get(:asset_event_result, :ok) do
        :raise -> raise "asset event registry unavailable"
        result -> result
      end
    end
  end

  defmodule Allow do
    def check_job(_authorization, _repo, _envelope), do: :ok
  end

  defmodule Assets do
    def prepare_verification(_repo, _envelope) do
      Process.get(
        :verify_result,
        {:ok,
         %{
           status: :complete,
           asset: %{state: :verified, secret: "VERIFY_RESULT_CANARY"}
         }}
      )
    end

    def resolve_finalization(_repo, _envelope) do
      {:ok,
       %{
         status: :complete,
         asset: %{state: :available, secret: "FINALIZE_RESULT_CANARY"}
       }}
    end

    def begin_or_resume_processing(_repo, _envelope) do
      {:ok,
       %{
         status: :pending,
         processing_revision: 4,
         checkpoint: %{},
         object_id: "00000000-0000-4000-8000-000000000903",
         object_generation: 1,
         declared_media_type: "application/pdf",
         plaintext_byte_size: 12
       }}
    end

    def record_metadata_exhaustion(_repo, envelope, failure) do
      send(Process.get(:asset_event_owner), {
        :recorded_failure,
        envelope.job_type,
        failure.code
      })

      Process.get(
        :failure_record_result,
        {:ok, %{state: :processing, secret: "FAILURE_RESULT_CANARY"}}
      )
    end

    def record_job_failure(_repo, envelope, failure) do
      send(Process.get(:asset_event_owner), {
        :recorded_failure,
        envelope.job_type,
        failure.code
      })

      Process.get(
        :failure_record_result,
        {:ok, %{state: :failed, secret: "FAILURE_RESULT_CANARY"}}
      )
    end
  end

  defmodule Deletions do
    def complete_logical_delete(_repo, _envelope) do
      {:ok, %{state: :deleted, secret: "CLEANUP_RESULT_CANARY"}}
    end

    def claim_orphan_delete(_repo, _envelope), do: {:ok, :retained}
  end

  defmodule ObjectLock do
    def with_exclusive(_repo_handle, _object_id, callback), do: callback.()
  end

  defmodule Custodian do
    def lease(_request), do: {:error, :waiting_for_unlock}
    def revoke_backup_key(_opaque_ref), do: :ok
  end

  defmodule JobProgress do
    def wait_metadata_for_unlock(
          _repo,
          _envelope,
          _processing_revision,
          _target
        ),
        do: {:ok, %{state: :waiting_for_unlock}}
  end

  defmodule Backups do
    def load_pending(_repo, %{manifest_id: manifest_id}) do
      {:ok,
       %{
         id: manifest_id,
         status: :sealed,
         backup_key_lease_id: make_ref()
       }}
    end
  end

  setup do
    Process.put(:asset_event_owner, self())

    on_exit(fn ->
      Process.delete(:asset_event_owner)
      Process.delete(:asset_event_result)
      Process.delete(:failure_record_result)
      Process.delete(:verify_result)
    end)
  end

  test "the four exact asset handlers publish after non-error results including snooze" do
    context = context()

    expected_results = %{
      "asset_verify" => {:ok, :verified},
      "asset_finalize" => {:ok, :available},
      "asset_metadata" => {:snooze, 60},
      "asset_cleanup" => {:ok, :deleted}
    }

    for {job_type, expected} <- expected_results do
      result = JobDispatcher.handle(context, envelope(job_type))

      assert result_shape(result) == expected

      assert_receive {:asset_event, @vault_id, @asset_id}
      refute_receive {:asset_event, _vault_id, _asset_id}
    end
  end

  test "handler errors and invalid signal identifiers do not publish" do
    Process.put(:verify_result, {:error, Error.new(:job_failed)})

    assert {:error, %Error{code: :job_failed}} =
             JobDispatcher.handle(context(), envelope("asset_verify"))

    refute_receive {:asset_event, _vault_id, _asset_id}

    Process.delete(:verify_result)

    assert {:ok, %{state: :verified}} =
             JobDispatcher.handle(
               context(),
               %{envelope("asset_verify") | vault_id: "not-a-uuid"}
             )

    assert {:ok, %{state: :verified}} =
             JobDispatcher.handle(
               context(),
               %{
                 envelope("asset_verify")
                 | payload: %{"asset_id" => "not-a-uuid"}
               }
             )

    refute_receive {:asset_event, _vault_id, _asset_id}
  end

  test "object cleanup and backup never publish asset lifecycle signals" do
    assert {:ok, :noop} =
             JobDispatcher.handle(
               context(),
               envelope("object_cleanup")
             )

    assert {:ok, %{status: :sealed}} =
             JobDispatcher.handle(context(), envelope("backup"))

    refute_receive {:asset_event, _vault_id, _asset_id}
  end

  test "notification failures never replace a successful handler result" do
    Process.put(:asset_event_result, :raise)

    assert {:ok,
            %{
              state: :verified,
              secret: "VERIFY_RESULT_CANARY"
            }} =
             JobDispatcher.handle(
               context(),
               envelope("asset_verify")
             )

    assert_receive {:asset_event, @vault_id, @asset_id}
  end

  test "durably recorded asset failures publish only after a successful record" do
    failure = Error.new(:storage_unavailable, retryable?: true)

    for job_type <- [
          "asset_verify",
          "asset_finalize",
          "asset_metadata",
          "asset_cleanup"
        ] do
      assert {:ok, result} =
               JobDispatcher.handle_failure(
                 context(),
                 envelope(job_type),
                 failure,
                 %{attempt: 20, max_attempts: 20}
               )

      assert result.secret == "FAILURE_RESULT_CANARY"
      assert_receive {:recorded_failure, ^job_type, :storage_unavailable}
      assert_receive {:asset_event, @vault_id, @asset_id}
    end

    Process.put(
      :failure_record_result,
      {:error, Error.new(:storage_unavailable, retryable?: true)}
    )

    assert {:error, %Error{code: :storage_unavailable}} =
             JobDispatcher.handle_failure(
               context(),
               envelope("asset_verify"),
               failure,
               %{attempt: 20, max_attempts: 20}
             )

    assert_receive {:recorded_failure, "asset_verify", :storage_unavailable}
    refute_receive {:asset_event, _vault_id, _asset_id}
  end

  defp context do
    %{
      asset_deletions: Deletions,
      asset_events: {Events, self()},
      assets: Assets,
      authorization: :authorization,
      authorize: Allow,
      backups: Backups,
      bundle_reader: :unused_bundle_reader,
      bundle_verifier: :unused_bundle_verifier,
      bundle_writer: :unused_bundle_writer,
      custodian: Custodian,
      destination: :unused_destination,
      exporter: :unused_exporter,
      job_progress: JobProgress,
      key_lease: :unused_key_lease,
      object_lock: ObjectLock,
      object_storage: :unused_object_storage,
      repo_handle: :repo_handle,
      storage: :unused_storage,
      transact: fn [], callback -> callback.(:repo) end
    }
  end

  defp envelope(job_type) do
    required_capability =
      case job_type do
        "asset_cleanup" -> "asset.write"
        "object_cleanup" -> "object.cleanup"
        "backup" -> "backup.create"
        _asset_job -> "asset.process"
      end

    payload =
      case job_type do
        "object_cleanup" ->
          %{"object_id" => "00000000-0000-4000-8000-000000000904"}

        "backup" ->
          %{"pending_manifest_id" => "00000000-0000-4000-8000-000000000905"}

        _asset_job ->
          %{"asset_id" => @asset_id}
      end

    %JobEnvelope{
      version: 1,
      job_id: "00000000-0000-4000-8000-000000000906",
      job_type: job_type,
      idempotency_key: "job:#{job_type}:1",
      vault_id: @vault_id,
      principal_id: "00000000-0000-4000-8000-000000000907",
      required_capability: required_capability,
      principal_authorization_epoch: 1,
      vault_authorization_epoch: 2,
      classification: :private,
      correlation_id: "00000000-0000-4000-8000-000000000908",
      causation_id: "00000000-0000-4000-8000-000000000909",
      expected_entity_revision: 3,
      attempt: 0,
      payload: payload
    }
  end

  defp result_shape({:ok, %{state: state}}), do: {:ok, state}
  defp result_shape(result), do: result
end
