defmodule Singularity.Runtime.Observability.TelemetryTest do
  use ExUnit.Case, async: false

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope
  alias Singularity.Core.ObjectRef
  alias Singularity.Core.StageRef
  alias Singularity.Runtime.Assets.Finalize
  alias Singularity.Runtime.Assets.ObjectCleanup
  alias Singularity.Runtime.Assets.UploadReconciler
  alias Singularity.Runtime.Assets.Verify
  alias Singularity.Runtime.BackupVault
  alias Singularity.Runtime.Observability.Telemetry
  alias Singularity.Runtime.RestoreVault
  alias Singularity.Runtime.UnlockVault

  @secret "CANARY_TELEMETRY_SECRET_42f1"

  defmodule AllowAuthorization do
    def check_job(_authorization, _repo, _envelope), do: :ok
  end

  defmodule ImmediateObjectLock do
    def with_exclusive(_repo, _object_id, callback), do: callback.()
  end

  defmodule FinalizeRepository do
    alias Singularity.Core.ObjectRef
    alias Singularity.Core.StageRef

    @object_id "172ac8c7-d2a2-48e5-a493-d6c626df7fbd"
    @stage_id "b8c76ed3-1c49-4de2-a7a0-599b1a962ef4"
    @hash :binary.copy(<<0x34>>, 32)

    def resolve_finalization(_repo, _envelope),
      do: {:ok, %{status: :lock, object_id: @object_id}}

    def reserve_finalization(_repo, _command) do
      {:ok,
       %{
         status: :reserved,
         action: :reuse,
         object_id: @object_id,
         stage_id: @stage_id,
         object_ref: %ObjectRef{object_id: @object_id},
         stage_ref: %StageRef{stage_id: @stage_id},
         ciphertext_byte_size: 7,
         ciphertext_hash: @hash
       }}
    end

    def acknowledge_finalization(_repo, %{action: :reuse}),
      do: {:ok, %{asset: %{id: "asset"}}}
  end

  defmodule FinalizeStorage do
    @hash :binary.copy(<<0x34>>, 32)

    def verify(%ObjectRef{}), do: :ok
    def abort_stage(%StageRef{}), do: :ok
    def stat(%ObjectRef{}), do: {:ok, %{byte_size: 7, ciphertext_hash: @hash}}
  end

  defmodule VerifyRepository do
    @expected_hash :binary.copy(<<0x11>>, 32)

    def prepare_verification(_repo, _envelope) do
      {:ok,
       %{
         status: :pending,
         stage_id: "stage",
         stage_ref: %StageRef{stage_id: "stage"},
         ciphertext_byte_size: 9,
         ciphertext_hash: @expected_hash,
         format_envelope: %{format_version: 1}
       }}
    end
  end

  defmodule IntegrityMismatchStorage do
    def stat_stage(%StageRef{}) do
      {:ok,
       %{
         sealed?: true,
         byte_size: 9,
         ciphertext_hash: :binary.copy(<<0x22>>, 32),
         format_envelope: %{format_version: 1}
       }}
    end
  end

  defmodule CleanupRepository do
    def claim_orphan_delete(_repo, _envelope) do
      {:ok,
       %{
         object_ref: %ObjectRef{object_id: "object"},
         vault_id: "af598922-5862-467f-9cd2-30ad23931498",
         key_domain_id: "5127de70-5723-4aac-ac9d-68f30cf65a90",
         lookup_digest: :binary.copy(<<0x44>>, 32),
         ciphertext_hash: :binary.copy(<<0x55>>, 32)
       }}
    end

    def acknowledge_object_deleted(_repo, %{envelope: %JobEnvelope{}}),
      do: {:ok, %{id: "object"}}
  end

  defmodule CleanupStorage do
    def delete(%ObjectRef{}), do: :ok
  end

  defmodule RecoveryRepository do
    def list_open_stages(_context),
      do:
        {:ok,
         [
           %{
             stage_id: "stage",
             storage_ref: "storage",
             inserted_at: ~U[2026-07-19 04:59:45.000000Z]
           }
         ]}

    def with_locked_stage(_context, "stage", "storage", callback) do
      callback.(%{
        stage_id: "stage",
        storage_ref: "storage",
        state: :open
      })
    end

    def mark_abandoned(
          _context,
          "stage",
          "storage",
          %DateTime{},
          :runtime_restarted
        ),
        do: {:ok, %{stage_id: "stage", state: :abandoned}}
  end

  defmodule RecoveryStorage do
    def abort_stage(%StageRef{stage_id: "storage"}), do: :ok
  end

  test "execute prefixes events, keeps numeric measurements, and redacts metadata" do
    event = [:singularity, :contract, :executed]
    attach(event)

    assert :ok =
             Telemetry.execute(
               [:contract, :executed],
               %{count: 1},
               %{token: @secret, outcome: :ok}
             )

    assert_receive {:telemetry, ^event, %{count: 1}, metadata}
    assert metadata.outcome == :ok
    refute inspect(metadata) =~ @secret

    assert :ok =
             Telemetry.execute(
               [:contract, :executed],
               %{unsafe: @secret},
               %{}
             )

    refute_receive {:telemetry, ^event, _, _}
  end

  test "span returns the operation result and emits bounded lifecycle metadata" do
    stop_event = [:singularity, :contract, :stop]
    attach(stop_event)

    assert {:ok, :done} =
             Telemetry.span([:contract], %{token: @secret}, fn ->
               {:ok, :done}
             end)

    assert_receive {:telemetry, ^stop_event, %{duration: duration}, metadata}
    assert is_integer(duration) and duration >= 0
    assert metadata.result == :ok
    refute inspect(metadata) =~ @secret
  end

  test "span exception telemetry omits the exception and scans the complete payload" do
    exception_event = [:singularity, :contract, :exception]
    attach(exception_event)

    assert_raise RuntimeError, @secret, fn ->
      Telemetry.span([:contract], %{token: @secret}, fn -> raise @secret end)
    end

    assert_receive {:telemetry, ^exception_event, measurements, metadata} = payload
    assert Enum.all?(Map.values(measurements), &is_number/1)
    assert metadata.kind == :error
    assert metadata.result == :exception
    refute inspect(payload, limit: :infinity, printable_limit: :infinity) =~ @secret
  end

  test "span emits a separate integrity failure without forwarding the error" do
    integrity_event = [:singularity, :integrity, :failure]
    attach(integrity_event)

    assert {:error, %Error{code: :integrity_failure}} =
             Telemetry.span([:asset, :verify], %{}, fn ->
               {:error, Error.new(:integrity_failure, details: %{token: @secret})}
             end)

    assert_receive {:telemetry, ^integrity_event, %{count: 1}, metadata}
    assert metadata.operation == :asset_verify
    refute inspect(metadata) =~ @secret
  end

  test "metrics expose the bounded Task 15 event contract" do
    names =
      Telemetry.metrics()
      |> Enum.map(&Enum.join(&1.name, "."))
      |> MapSet.new()

    assert MapSet.subset?(
             MapSet.new([
               "singularity.upload.stop.bytes",
               "singularity.upload.stop.duration",
               "singularity.asset.dedup.count",
               "singularity.integrity.failure.count",
               "singularity.outbox.dispatch.lag",
               "singularity.job.retry.count",
               "singularity.job.failure.count",
               "singularity.authentication.audit_write_failure.count",
               "singularity.authorization.rls_denial.count",
               "singularity.vault.unlock.stop.duration",
               "singularity.backup.stop.duration",
               "singularity.restore.stop.duration",
               "singularity.orphan.cleanup.count",
               "singularity.upload.reconciliation.count",
               "singularity.upload.reconciliation.stage.age"
             ]),
             names
           )
  end

  test "the supervised owner attaches and detaches its source handlers" do
    event = [:task_15, :probe]
    handler_id = {__MODULE__, make_ref()}

    pid =
      start_supervised!(
        {Telemetry, name: nil, handler_id: handler_id, source_events: [event]},
        id: make_ref()
      )

    assert handler_attached?(event, handler_id)

    :ok = GenServer.stop(pid)

    refute handler_attached?(event, handler_id)
  end

  test "Oban retry and terminal failure derivation never forwards job data" do
    retry_event = [:singularity, :job, :retry]
    failure_event = [:singularity, :job, :failure]
    attach_many([retry_event, failure_event])

    unsafe_metadata = %{
      worker: "Elixir.Singularity.Storage.Jobs.GenericWorker",
      queue: "asset_verify",
      attempt: 2,
      max_attempts: 3,
      args: %{"payload" => @secret},
      reason: RuntimeError.exception(@secret),
      stacktrace: [@secret]
    }

    assert :ok =
             Telemetry.handle_event(
               [:oban, :job, :exception],
               %{duration: 12},
               unsafe_metadata,
               nil
             )

    assert_receive {:telemetry, ^retry_event, %{count: 1}, retry_metadata}

    assert retry_metadata == %{
             attempt: 2,
             max_attempts: 3,
             queue: :asset_verify,
             worker: :generic_worker
           }

    refute inspect(retry_metadata) =~ @secret

    assert :ok =
             Telemetry.handle_event(
               [:oban, :job, :exception],
               %{duration: 13},
               %{unsafe_metadata | attempt: 3},
               nil
             )

    assert_receive {:telemetry, ^failure_event, %{count: 1}, failure_metadata}
    assert failure_metadata.attempt == 3
    refute inspect(failure_metadata) =~ @secret
  end

  test "operation boundaries emit durations and integrity failures" do
    events = [
      [:singularity, :vault, :unlock, :stop],
      [:singularity, :backup, :stop],
      [:singularity, :restore, :stop],
      [:singularity, :asset, :verify, :stop],
      [:singularity, :integrity, :failure]
    ]

    attach_many(events)

    assert {:error, %Error{code: :invalid}} = UnlockVault.run(%{}, nil, "", "")
    assert_receive {:telemetry, [:singularity, :vault, :unlock, :stop], %{duration: _}, _}

    assert {:error, %Error{code: :invalid}} = BackupVault.run(%{}, %{})
    assert_receive {:telemetry, [:singularity, :backup, :stop], %{duration: _}, _}

    assert {:error, %Error{code: :invalid}} = RestoreVault.run(%{}, %{})
    assert_receive {:telemetry, [:singularity, :restore, :stop], %{duration: _}, _}

    envelope = envelope("asset_verify", "asset.verify")

    assert {:error, %Error{code: :integrity_failure}} =
             Verify.run(
               %{
                 assets: VerifyRepository,
                 authorization: :authorization,
                 authorize: AllowAuthorization,
                 storage: IntegrityMismatchStorage,
                 transact: transaction()
               },
               envelope
             )

    assert_receive {:telemetry, [:singularity, :asset, :verify, :stop], %{duration: _}, _}
    assert_receive {:telemetry, [:singularity, :integrity, :failure], %{count: 1}, _}
  end

  test "dedup, orphan cleanup, and upload recovery emit only durable outcomes" do
    dedup_event = [:singularity, :asset, :dedup]
    orphan_event = [:singularity, :orphan, :cleanup]
    recovery_event = [:singularity, :upload, :reconciliation]
    attach_many([dedup_event, orphan_event, recovery_event])

    finalize_envelope = envelope("asset_finalize", "asset.write")

    assert {:ok, %{id: "asset"}} =
             Finalize.run(
               %{
                 assets: FinalizeRepository,
                 authorization: :authorization,
                 authorize: AllowAuthorization,
                 object_lock: ImmediateObjectLock,
                 repo_handle: :repo,
                 storage: FinalizeStorage,
                 transact: transaction()
               },
               finalize_envelope
             )

    assert_receive {:telemetry, ^dedup_event, %{count: 1}, %{outcome: :reuse}}

    cleanup_envelope =
      envelope(
        "object_cleanup",
        "object.cleanup",
        %{"object_id" => "172ac8c7-d2a2-48e5-a493-d6c626df7fbd"}
      )

    assert {:ok, %{id: "object"}} =
             ObjectCleanup.run(
               %{
                 asset_deletions: CleanupRepository,
                 authorization: :authorization,
                 authorize: AllowAuthorization,
                 object_lock: ImmediateObjectLock,
                 repo_handle: :repo,
                 storage: CleanupStorage,
                 transact: transaction()
               },
               cleanup_envelope
             )

    assert_receive {:telemetry, ^orphan_event, %{count: 1}, %{outcome: :deleted}}

    assert {:ok, 1} =
             UploadReconciler.run(%{
               clock: fn -> DateTime.utc_now(:microsecond) end,
               repository: {RecoveryRepository, :context},
               storage: RecoveryStorage
             })

    assert_receive {:telemetry, ^recovery_event, %{count: 1}, %{outcome: :abandoned}}
  end

  test "upload recovery reports age from the durable stage timestamp" do
    event = [:singularity, :upload, :reconciliation, :stage]
    attach(event)

    assert {:ok, 1} =
             UploadReconciler.run(%{
               clock: fn -> ~U[2026-07-19 05:00:00.000000Z] end,
               repository: {RecoveryRepository, :context},
               storage: RecoveryStorage
             })

    assert_receive {:telemetry, ^event, %{age: 15_000}, %{outcome: :abandoned}}
  end

  defp attach(event), do: attach_many([event])

  defp attach_many(events) do
    owner = self()
    handler_id = {__MODULE__, owner, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.capture/4,
        owner
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  @doc false
  def capture(event, measurements, metadata, owner) do
    send(owner, {:telemetry, event, measurements, metadata})
  end

  defp handler_attached?(event, handler_id) do
    event
    |> :telemetry.list_handlers()
    |> Enum.any?(&(&1.id == handler_id))
  end

  defp transaction do
    fn _options, callback -> callback.(:repo) end
  end

  defp envelope(job_type, capability, payload \\ %{}) do
    {:ok, envelope} =
      JobEnvelope.new(%{
        version: 1,
        job_id: "9a2a9379-ef8e-44c6-95cf-69f6abe07287",
        job_type: job_type,
        idempotency_key: "telemetry-test",
        vault_id: "af598922-5862-467f-9cd2-30ad23931498",
        principal_id: "68854fed-f262-4d5c-a3ca-fb13951a5f18",
        required_capability: capability,
        principal_authorization_epoch: 0,
        vault_authorization_epoch: 0,
        classification: :private,
        correlation_id: "75771186-d153-4a90-85bb-00106ec11fd2",
        causation_id: "0f698290-a7dd-4c86-864c-8ed125873498",
        expected_entity_revision: 0,
        attempt: 0,
        payload: payload
      })

    envelope
  end
end
