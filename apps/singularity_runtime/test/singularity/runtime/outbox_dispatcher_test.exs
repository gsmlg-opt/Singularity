defmodule Singularity.Runtime.OutboxDispatcherTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Domains.Assets
  alias Singularity.Runtime.AuthorizationDependencies
  alias Singularity.Runtime.Authorize
  alias Singularity.Runtime.OutboxDispatcher
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.Postgres.AssetRepository
  alias Singularity.Storage.Postgres.IdentityRepository
  alias Singularity.Storage.ScopedRepo
  alias Singularity.Storage.VaultLock

  defmodule FakeRunner do
    @behaviour Singularity.Core.JobRunner

    use Agent

    def start_link(options) do
      Agent.start_link(fn ->
        %{
          observer: Keyword.fetch!(options, :observer),
          calls: [],
          submissions: %{}
        }
      end)
    end

    @impl true
    def submit(runner, envelope) do
      Agent.get_and_update(runner, fn state ->
        runner_id =
          Map.get(
            state.submissions,
            envelope.job_id,
            "fake-runner:" <> envelope.job_id
          )

        send(state.observer, {:runner_submit, envelope, runner_id})

        state = %{
          state
          | calls: [envelope | state.calls],
            submissions: Map.put(state.submissions, envelope.job_id, runner_id)
        }

        {{:ok, runner_id}, state}
      end)
    end

    @impl true
    def wake_vault(_runner, _vault_id), do: :ok

    def calls(runner), do: Agent.get(runner, &Enum.reverse(&1.calls))
    def submission_count(runner), do: Agent.get(runner, &map_size(&1.submissions))
  end

  defmodule BarrierOutbox do
    @behaviour Singularity.Core.Outbox

    @impl true
    def append(repo, event) do
      Singularity.Storage.Postgres.Outbox.append(repo, event)
    end

    @impl true
    def claim(repo, options) do
      %{observer: observer, ref: ref} =
        Application.fetch_env!(:singularity_runtime, :test_claim_barrier)

      case repo.transaction(fn ->
             result = Singularity.Storage.Postgres.Outbox.claim(repo, options)
             send(observer, {:claim_boundary, ref, self(), result})

             receive do
               {:release_claim, ^ref} -> result
             after
               5_000 -> raise "claim barrier timed out"
             end
           end) do
        {:ok, result} ->
          result

        {:error, _reason} ->
          {:error, Singularity.Core.Error.new(:storage_unavailable, retryable?: true)}
      end
    end

    @impl true
    def acknowledge(repo, event_id, options) do
      Singularity.Storage.Postgres.Outbox.acknowledge(repo, event_id, options)
    end
  end

  defmodule AcknowledgeBarrierOutbox do
    @behaviour Singularity.Core.Outbox

    @impl true
    def append(repo, event) do
      Singularity.Storage.Postgres.Outbox.append(repo, event)
    end

    @impl true
    def claim(repo, options) do
      Singularity.Storage.Postgres.Outbox.claim(repo, options)
    end

    @impl true
    def acknowledge(repo, event_id, options) do
      %{observer: observer, ref: ref} =
        Application.fetch_env!(:singularity_runtime, :test_acknowledge_barrier)

      result = Singularity.Storage.Postgres.Outbox.acknowledge(repo, event_id, options)
      send(observer, {:acknowledge_finished, ref, self(), result})

      receive do
        {:release_acknowledge, ^ref} -> result
      after
        5_000 -> raise "acknowledge barrier timed out"
      end
    end
  end

  defmodule CountingRunner do
    @behaviour Singularity.Core.JobRunner

    @impl true
    def submit(%{observer: observer}, envelope) do
      send(observer, {:counting_runner_submit, envelope.job_id})
      Singularity.Storage.Jobs.ObanAdapter.submit(%{}, envelope)
    end

    @impl true
    def wake_vault(_context, vault_id) do
      Singularity.Storage.Jobs.ObanAdapter.wake_vault(%{}, vault_id)
    end
  end

  defmodule BlockingRunner do
    @behaviour Singularity.Core.JobRunner

    @impl true
    def submit(%{observer: observer, ref: ref}, envelope) do
      send(observer, {:blocking_submit_entered, ref, self(), envelope})

      receive do
        {:release_blocking_submit, ^ref} ->
          {:ok, "blocking-runner:" <> envelope.job_id}
      after
        5_000 ->
          raise "blocking runner timed out"
      end
    end

    @impl true
    def wake_vault(_context, _vault_id), do: :ok
  end

  setup do
    mark_existing_events_delivered!()
    runner = start_supervised!({FakeRunner, observer: self()})
    %{runner: runner}
  end

  test "claims, submits and acknowledges a strict versioned envelope", %{runner: runner} do
    fixture = Fixtures.two_vaults!().one
    event = Fixtures.outbox_event!(fixture)
    causation_id = Ecto.UUID.generate()

    owner_query(
      "UPDATE core.outbox_events SET causation_id = $1 WHERE id = $2",
      [Ecto.UUID.dump!(causation_id), event.id]
    )

    assert {:ok, %{submitted: 1, skipped: 0}} =
             OutboxDispatcher.dispatch_once(dispatcher_options(runner))

    assert_receive {:runner_submit, envelope, runner_id}
    assert envelope.job_id == load_uuid(event.id)
    assert envelope.job_type == "asset_verify"
    assert envelope.vault_id == load_uuid(fixture.vault_id)
    assert envelope.principal_id == load_uuid(fixture.principal_id)
    assert envelope.principal_authorization_epoch == 7
    assert envelope.vault_authorization_epoch == 23
    assert envelope.causation_id == causation_id
    assert envelope.payload == %{"asset_id" => load_uuid(fixture.asset_id)}
    assert is_binary(runner_id)

    assert %{rows: [[^runner_id, %DateTime{}]]} =
             owner_query(
               """
               SELECT runner_job_id, delivered_at
               FROM core.outbox_events
               WHERE id = $1
               """,
               [event.id]
             )
  end

  test "an AssetRepository job becomes stale when either live authorization axis changes", %{
    runner: runner
  } do
    fixture = Fixtures.two_vaults!().one
    principal_id = load_uuid(fixture.principal_id)
    vault_id = load_uuid(fixture.vault_id)
    asset_id = load_uuid(fixture.asset_id)
    resource_version_id = load_uuid(fixture.resource_version_id)
    capability_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()

    owner_query(
      """
      UPDATE identity.principals
      SET authorization_epoch = 11
      WHERE id = $1
      """,
      [fixture.principal_id]
    )

    owner_query(
      "UPDATE core.vaults SET authorization_epoch = 23 WHERE id = $1",
      [fixture.vault_id]
    )

    owner_query(
      """
      INSERT INTO core.capabilities (id, name)
      VALUES ($1, 'assets.verify')
      ON CONFLICT (name) DO NOTHING
      """,
      [capability_id]
    )

    owner_query(
      """
      INSERT INTO core.principal_capabilities (
        principal_id,
        vault_id,
        capability_id
      )
      SELECT $1, $2, capability.id
      FROM core.capabilities AS capability
      WHERE capability.name = 'assets.verify'
      ON CONFLICT (principal_id, vault_id, capability_id)
      DO UPDATE SET revoked_at = NULL
      """,
      [fixture.principal_id, fixture.vault_id]
    )

    assert {:ok, %{outbox: %{event_type: "asset.verify_requested"}}} =
             ScopedRepo.transact(
               RequestRepo,
               %{principal_id: principal_id, vault_id: vault_id},
               fn repo ->
                 Assets.record_sealed_upload(
                   %{
                     repository: AssetRepository,
                     context: repo,
                     audit: Singularity.Storage.Postgres.AuditSink,
                     outbox: Singularity.Storage.Postgres.Outbox
                   },
                   %{
                     asset_id: asset_id,
                     vault_id: vault_id,
                     resource_version_id: resource_version_id,
                     principal_id: principal_id,
                     sealed_ref: "sealed://#{vault_id}/#{asset_id}",
                     filename: "two-axis.bin",
                     content_type: "application/octet-stream",
                     byte_size: 4,
                     checksum: "sha256:" <> String.duplicate("ab", 32),
                     classification: :private
                   }
                 )
               end
             )

    assert {:ok, %{submitted: 1, skipped: 0, failed: 0}} =
             OutboxDispatcher.dispatch_once(dispatcher_options(runner))

    assert_receive {:runner_submit, envelope, _runner_id}
    assert envelope.principal_authorization_epoch == 11
    assert envelope.vault_authorization_epoch == 23

    assert {:ok,
            %{
              principal_id: ^principal_id,
              principal_kind: :owner,
              principal_authorization_epoch: 11,
              vault_id: ^vault_id,
              vault_authorization_epoch: 23,
              principal_revoked_at: nil,
              membership_revoked_at: nil,
              clearance: :private,
              capabilities: capabilities
            }} = live_job_authority(envelope)

    assert "assets.verify" in capabilities
    assert envelope.required_capability == "assets.verify"
    assert envelope.classification == :private
    assert :ok = authorize_job(envelope)

    owner_query(
      "UPDATE core.vaults SET authorization_epoch = 24 WHERE id = $1",
      [fixture.vault_id]
    )

    assert {:error, %Error{code: :forbidden}} = authorize_job(envelope)

    current_vault = %{envelope | vault_authorization_epoch: 24}
    assert :ok = authorize_job(current_vault)

    owner_query(
      """
      UPDATE identity.principals
      SET revoked_at = CURRENT_TIMESTAMP, authorization_epoch = 12
      WHERE id = $1
      """,
      [fixture.principal_id]
    )

    assert {:error, %Error{code: :forbidden}} = authorize_job(current_vault)

    owner_query(
      """
      UPDATE identity.principals
      SET revoked_at = NULL, authorization_epoch = 13
      WHERE id = $1
      """,
      [fixture.principal_id]
    )

    assert {:error, %Error{code: :forbidden}} = authorize_job(current_vault)

    current_authority = %{current_vault | principal_authorization_epoch: 13}
    assert :ok = authorize_job(current_authority)
  end

  test "post-submit crash retries with the same runner identity and one logical submission",
       %{runner: runner} do
    fixture = Fixtures.two_vaults!().one
    event = Fixtures.outbox_event!(fixture)
    parent = self()

    crashing_options =
      dispatcher_options(runner)
      |> Map.put(:after_submit, fn envelope, runner_id ->
        send(parent, {:after_submit, envelope.job_id, runner_id})
        raise "injected dispatcher crash"
      end)

    assert_raise RuntimeError, "injected dispatcher crash", fn ->
      OutboxDispatcher.dispatch_once(crashing_options)
    end

    assert_receive {:after_submit, job_id, runner_id}
    assert job_id == load_uuid(event.id)
    expire_claim!(event.id)

    assert {:ok, %{submitted: 1, skipped: 0}} =
             OutboxDispatcher.dispatch_once(dispatcher_options(runner))

    assert_receive {:runner_submit, %{job_id: ^job_id}, ^runner_id}
    assert FakeRunner.submission_count(runner) == 1
    assert [%{job_id: ^job_id}, %{job_id: ^job_id}] = FakeRunner.calls(runner)
  end

  test "concurrent duplicate dispatcher claims submit one logical job" do
    fixture = Fixtures.two_vaults!().one
    event = Fixtures.outbox_event!(fixture)
    barrier_ref = make_ref()
    previous_barrier = Application.get_env(:singularity_runtime, :test_claim_barrier)

    Application.put_env(:singularity_runtime, :test_claim_barrier, %{
      observer: self(),
      ref: barrier_ref
    })

    on_exit(fn ->
      if previous_barrier do
        Application.put_env(:singularity_runtime, :test_claim_barrier, previous_barrier)
      else
        Application.delete_env(:singularity_runtime, :test_claim_barrier)
      end
    end)

    options =
      self()
      |> dispatcher_options()
      |> Map.merge(%{
        job_runner: CountingRunner,
        job_runner_context: %{observer: self()},
        outbox: BarrierOutbox
      })

    tasks =
      1..2
      |> Enum.map(fn _index ->
        Task.async(fn -> OutboxDispatcher.dispatch_once(options) end)
      end)

    boundaries =
      for _index <- 1..2 do
        assert_receive {:claim_boundary, ^barrier_ref, task_pid, {:ok, events}}, 5_000
        {task_pid, length(events)}
      end

    assert boundaries |> Enum.map(&elem(&1, 1)) |> Enum.sort() == [0, 1]

    Enum.each(boundaries, fn {task_pid, _event_count} ->
      send(task_pid, {:release_claim, barrier_ref})
    end)

    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.sum(Enum.map(results, fn {:ok, summary} -> summary.submitted end)) == 1
    assert_receive {:counting_runner_submit, job_id}
    refute_receive {:counting_runner_submit, _duplicate_job_id}
    assert job_id == load_uuid(event.id)

    assert %{rows: [[1]]} =
             owner_query(
               "SELECT count(*) FROM jobs.job_submissions WHERE outbox_event_id = $1",
               [event.id]
             )
  end

  test "an exclusive backup lock skips its vault without stalling another vault",
       %{runner: runner} do
    %{one: one, two: two} = Fixtures.two_vaults!()
    one_event = Fixtures.outbox_event!(one)
    _two_event = Fixtures.outbox_event!(two)
    parent = self()

    lock =
      Task.async(fn ->
        VaultLock.with_exclusive(WorkerRepo, one.vault_id, fn _repo ->
          send(parent, :backup_lock_acquired)

          receive do
            :release_backup_lock -> :ok
          end
        end)
      end)

    assert_receive :backup_lock_acquired

    assert {:ok, %{submitted: 1, skipped: 1}} =
             OutboxDispatcher.dispatch_once(dispatcher_options(runner))

    assert_receive {:runner_submit, %{vault_id: submitted_vault}, _runner_id}
    assert submitted_vault == load_uuid(two.vault_id)
    one_vault_id = load_uuid(one.vault_id)
    refute_receive {:runner_submit, %{vault_id: ^one_vault_id}, _runner_id}

    send(lock.pid, :release_backup_lock)
    assert :ok = Task.await(lock)
    expire_claim!(one_event.id)

    assert {:ok, %{submitted: 1, skipped: 0}} =
             OutboxDispatcher.dispatch_once(dispatcher_options(runner))

    assert_receive {:runner_submit, %{vault_id: released_vault}, _runner_id}
    assert released_vault == load_uuid(one.vault_id)
  end

  test "dispatch holds the shared vault lock through submission and acknowledgement" do
    fixture = Fixtures.two_vaults!().one
    event = Fixtures.outbox_event!(fixture)
    parent = self()
    ref = make_ref()
    previous_barrier = Application.get_env(:singularity_runtime, :test_acknowledge_barrier)

    Application.put_env(:singularity_runtime, :test_acknowledge_barrier, %{
      observer: self(),
      ref: ref
    })

    on_exit(fn ->
      if previous_barrier do
        Application.put_env(
          :singularity_runtime,
          :test_acknowledge_barrier,
          previous_barrier
        )
      else
        Application.delete_env(:singularity_runtime, :test_acknowledge_barrier)
      end
    end)

    options =
      self()
      |> dispatcher_options()
      |> Map.merge(%{
        job_runner: BlockingRunner,
        job_runner_context: %{observer: self(), ref: ref},
        outbox: AcknowledgeBarrierOutbox,
        after_submit: fn _envelope, _runner_id ->
          send(parent, {:after_submit_entered, ref, self()})

          receive do
            {:release_after_submit, ^ref} -> :ok
          after
            5_000 -> raise "after-submit barrier timed out"
          end
        end
      })

    dispatch =
      Task.async(fn ->
        OutboxDispatcher.dispatch_once(options)
      end)

    assert_receive {:blocking_submit_entered, ^ref, dispatch_pid, envelope}, 5_000
    assert dispatch_pid == dispatch.pid
    assert envelope.job_id == load_uuid(event.id)

    exclusive =
      Task.async(fn ->
        send(parent, {:exclusive_attempting, ref})

        VaultLock.with_exclusive(WorkerRepo, fixture.vault_id, fn _repo ->
          send(parent, {:exclusive_acquired, ref})

          receive do
            {:release_exclusive, ^ref} -> :ok
          after
            5_000 -> raise "exclusive lock release timed out"
          end
        end)
      end)

    assert_receive {:exclusive_attempting, ^ref}
    refute_receive {:exclusive_acquired, ^ref}, 250

    send(dispatch.pid, {:release_blocking_submit, ref})

    assert_receive {:after_submit_entered, ^ref, ^dispatch_pid}, 5_000
    refute_receive {:exclusive_acquired, ^ref}, 250

    send(dispatch.pid, {:release_after_submit, ref})

    assert_receive {:acknowledge_finished, ^ref, ^dispatch_pid, :ok}, 5_000
    refute_receive {:exclusive_acquired, ^ref}, 250

    send(dispatch.pid, {:release_acknowledge, ref})

    assert {:ok, %{submitted: 1, skipped: 0}} = Task.await(dispatch, 5_000)
    assert_receive {:exclusive_acquired, ^ref}, 5_000

    send(exclusive.pid, {:release_exclusive, ref})
    assert :ok = Task.await(exclusive, 5_000)

    assert %{rows: [[%DateTime{}]]} =
             owner_query(
               "SELECT delivered_at FROM core.outbox_events WHERE id = $1",
               [event.id]
             )
  end

  defp dispatcher_options(runner) do
    %{
      outbox: Singularity.Storage.Postgres.Outbox,
      outbox_context: DispatcherRepo,
      job_runner: FakeRunner,
      job_runner_context: runner,
      batch_size: 100,
      lease_seconds: 60,
      after_submit: fn _envelope, _runner_id -> :ok end
    }
  end

  defp authorize_job(envelope) do
    dependencies = %AuthorizationDependencies{
      store: IdentityRepository,
      custodian: :unused
    }

    ScopedRepo.transact(WorkerRepo, envelope, fn repo ->
      Authorize.check_job(dependencies, repo, envelope)
    end)
  end

  defp live_job_authority(envelope) do
    ScopedRepo.transact(WorkerRepo, envelope, fn repo ->
      IdentityRepository.load_live_principal(
        repo,
        envelope.principal_id,
        envelope.vault_id
      )
    end)
  end

  defp expire_claim!(event_id) do
    owner_query(
      """
      UPDATE core.outbox_events
      SET claimed_until = CURRENT_TIMESTAMP - interval '1 second'
      WHERE id = $1
      """,
      [event_id]
    )
  end

  defp mark_existing_events_delivered! do
    owner_query(
      """
      UPDATE core.outbox_events
      SET delivered_at = CURRENT_TIMESTAMP
      WHERE delivered_at IS NULL
      """,
      []
    )

    :ok
  end

  defp owner_query(statement, parameters) do
    Fixtures.with_owner(fn ->
      query!(Singularity.Storage.MigrationRepo, statement, parameters)
    end)
  end

  defp load_uuid(uuid), do: Ecto.UUID.load!(uuid)
end
