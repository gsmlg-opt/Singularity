defmodule Singularity.Storage.AssetAccessRetryTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.Asset
  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.Jobs.EnvelopeCodec
  alias Singularity.Storage.Jobs.GenericWorker
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.Postgres.AssetRepository
  alias Singularity.Storage.RequestRepo
  alias Singularity.Storage.ScopedRepo

  defmodule ControlledFailureHandler do
    @behaviour Singularity.Core.JobHandler

    alias Singularity.Core.Error
    alias Singularity.Runtime.Application, as: RuntimeApplication
    alias Singularity.Runtime.JobDispatcher

    @impl true
    def dependencies, do: RuntimeApplication.job_dependencies()

    @impl true
    def handle(_context, _envelope) do
      retryable? =
        Application.fetch_env!(
          :singularity_storage,
          :controlled_failure_retryable
        )

      code = if retryable?, do: :storage_unavailable, else: :integrity_failure
      {:error, Error.new(code, retryable?: retryable?)}
    end

    @impl true
    def handle_failure(context, envelope, failure, attempt) do
      JobDispatcher.handle_failure(context, envelope, failure, attempt)
    end
  end

  setup do
    %{one: raw_fixture, two: raw_other} = Fixtures.two_vaults!()

    fixture = load_ids(raw_fixture)
    other = load_ids(raw_other)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE content.assets
        SET
          state = 'uploaded',
          state_revision = 1,
          failure_code = 'storage_unavailable',
          retryable = true,
          failed_operation = 'asset_verify',
          attempt = 2
        WHERE id = $1
        """,
        [raw_fixture.asset_id]
      )
    end)

    {:ok, fixture: fixture, other: other}
  end

  test "status returns exact orthogonal failure metadata only inside its vault", %{
    fixture: fixture,
    other: other
  } do
    assert {:ok,
            %Asset{
              asset_id: asset_id,
              vault_id: vault_id,
              state: :uploaded,
              state_revision: 1,
              failure_code: :storage_unavailable,
              retryable?: true,
              failed_operation: "asset_verify",
              attempt: 2
            }} =
             scoped(fixture, fn repo ->
               AssetRepository.status(repo, fixture.asset_id)
             end)

    assert asset_id == fixture.asset_id
    assert vault_id == fixture.vault_id

    assert {:error, %Error{code: :not_found}} =
             scoped(other, fn repo ->
               AssetRepository.status(repo, fixture.asset_id)
             end)
  end

  test "retry clears the failure and enqueues exactly one new attempt", %{
    fixture: fixture
  } do
    command = retry_command(fixture, 1)

    assert {:ok, :accepted} =
             scoped(fixture, fn repo ->
               AssetRepository.retry(repo, command)
             end)

    assert {:ok, :accepted} =
             scoped(fixture, fn repo ->
               AssetRepository.retry(repo, command)
             end)

    scoped(fixture, fn repo ->
      assert %{
               rows: [
                 [
                   "uploaded",
                   1,
                   nil,
                   nil,
                   nil,
                   3,
                   1,
                   1
                 ]
               ]
             } =
               query!(
                 repo,
                 """
                 SELECT
                   asset.state,
                   asset.state_revision,
                   asset.failure_code,
                   asset.retryable,
                   asset.failed_operation,
                   asset.attempt,
                   (
                     SELECT count(*)
                     FROM audit.events
                     WHERE target_id = asset.id
                       AND operation = 'asset.retry_requested'
                   ),
                   (
                     SELECT count(*)
                     FROM core.outbox_events
                     WHERE event_type = 'asset.verify_requested'
                       AND payload ->> 'asset_id' = asset.id::text
                       AND idempotency_key =
                         'asset-retry:' || asset.id::text || ':1:3'
                       AND expected_entity_revision = 1
                       AND required_capability = 'asset.write'
                   )
                 FROM content.assets AS asset
                 WHERE asset.id = $1
                 """,
                 [Ecto.UUID.dump!(fixture.asset_id)]
               )

      :ok
    end)
  end

  test "terminal or exhausted job failure is persisted once with audit and receipt", %{
    fixture: fixture
  } do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE content.assets
        SET
          failure_code = NULL,
          retryable = NULL,
          failed_operation = NULL
        WHERE id = $1
        """,
        [Ecto.UUID.dump!(fixture.asset_id)]
      )
    end)

    assert {:ok, envelope} =
             JobEnvelope.new(%{
               attempt: 0,
               causation_id: Ecto.UUID.generate(),
               classification: :private,
               correlation_id: Ecto.UUID.generate(),
               expected_entity_revision: 1,
               idempotency_key: "asset-failure:#{fixture.asset_id}:#{Ecto.UUID.generate()}",
               job_id: Ecto.UUID.generate(),
               job_type: "asset_verify",
               payload: %{"asset_id" => fixture.asset_id},
               principal_authorization_epoch: 0,
               principal_id: fixture.principal_id,
               required_capability: "asset.write",
               vault_authorization_epoch: 0,
               vault_id: fixture.vault_id,
               version: 1
             })

    insert_outbox!(envelope)

    failure = Error.new(:storage_unavailable, retryable?: true)

    for _replay <- 1..2 do
      assert {:ok,
              %Asset{
                failure_code: :storage_unavailable,
                retryable?: true,
                failed_operation: "asset_verify",
                attempt: 2
              }} =
               scoped(fixture, fn repo ->
                 AssetRepository.record_job_failure(
                   repo,
                   envelope,
                   failure
                 )
               end)
    end

    scoped(fixture, fn repo ->
      assert %{rows: [[1, 1]]} =
               query!(
                 repo,
                 """
                 SELECT
                   (
                     SELECT count(*)
                     FROM audit.events
                     WHERE target_id = $1
                       AND operation = 'asset.verify_failed'
                       AND result = 'failed'
                   ),
                   (
                     SELECT count(*)
                     FROM jobs.effect_receipts
                     WHERE submission_id = $2
                       AND result = 'failed'
                       AND entity_revision = 1
                   )
                 """,
                 [
                   Ecto.UUID.dump!(fixture.asset_id),
                   Ecto.UUID.dump!(envelope.job_id)
                 ]
               )

      :ok
    end)
  end

  test "generic worker persists only terminal failures through the production repository", %{
    fixture: fixture
  } do
    clear_failure!(fixture)
    grant_asset_write!(fixture)

    with_production_failure_handler(fn ->
      retryable = worker_envelope(fixture, true)
      insert_outbox!(retryable)
      Application.put_env(:singularity_storage, :controlled_failure_retryable, true)

      assert {:ok, retryable_args} = EnvelopeCodec.encode(retryable)

      assert {:error, %{code: :job_failed}} =
               GenericWorker.perform(%Oban.Job{
                 args: retryable_args,
                 attempt: 1,
                 max_attempts: 3
               })

      assert_failure_evidence(fixture, retryable, [
        nil,
        nil,
        nil,
        0,
        0
      ])

      exhausted_job = %Oban.Job{
        args: retryable_args,
        attempt: 3,
        max_attempts: 3
      }

      for _replay <- 1..2 do
        assert {:error, %{code: :job_failed}} =
                 GenericWorker.perform(exhausted_job)
      end

      assert_failure_evidence(fixture, retryable, [
        "storage_unavailable",
        true,
        "asset_verify",
        1,
        1
      ])

      nonretryable = worker_envelope(fixture, false)
      insert_outbox!(nonretryable)
      Application.put_env(:singularity_storage, :controlled_failure_retryable, false)
      assert {:ok, nonretryable_args} = EnvelopeCodec.encode(nonretryable)

      immediate_job = %Oban.Job{
        args: nonretryable_args,
        attempt: 1,
        max_attempts: 20
      }

      for _replay <- 1..2 do
        assert {:cancel, %{code: :job_failed}} =
                 GenericWorker.perform(immediate_job)
      end

      assert_failure_evidence(fixture, nonretryable, [
        "integrity_failure",
        false,
        "asset_verify",
        1,
        1
      ])
    end)
  end

  test "stale and non-retryable retries are side-effect free", %{
    fixture: fixture
  } do
    assert {:ok, :stale} =
             scoped(fixture, fn repo ->
               AssetRepository.retry(repo, retry_command(fixture, 0))
             end)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE content.assets
        SET retryable = false
        WHERE id = $1
        """,
        [Ecto.UUID.dump!(fixture.asset_id)]
      )
    end)

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, fn repo ->
               AssetRepository.retry(repo, retry_command(fixture, 1))
             end)

    scoped(fixture, fn repo ->
      assert %{rows: [[0, 0, 2]]} =
               query!(
                 repo,
                 """
                 SELECT
                   (
                     SELECT count(*)
                     FROM audit.events
                     WHERE target_id = asset.id
                       AND operation = 'asset.retry_requested'
                   ),
                   (
                     SELECT count(*)
                     FROM core.outbox_events
                     WHERE idempotency_key LIKE
                       'asset-retry:' || asset.id::text || ':%'
                   ),
                   asset.attempt
                 FROM content.assets AS asset
                 WHERE asset.id = $1
                 """,
                 [Ecto.UUID.dump!(fixture.asset_id)]
               )

      :ok
    end)
  end

  defp retry_command(fixture, revision) do
    %{
      asset_id: fixture.asset_id,
      vault_id: fixture.vault_id,
      principal_id: fixture.principal_id,
      classification: :private,
      expected_state_revision: revision
    }
  end

  defp worker_envelope(fixture, retryable?) do
    retry_attempt = if retryable?, do: 1, else: 2

    {:ok, envelope} =
      JobEnvelope.new(%{
        attempt: 0,
        causation_id: Ecto.UUID.generate(),
        classification: :private,
        correlation_id: Ecto.UUID.generate(),
        expected_entity_revision: 1,
        idempotency_key: "asset-retry:#{fixture.asset_id}:1:#{retry_attempt}",
        job_id: Ecto.UUID.generate(),
        job_type: "asset_verify",
        payload: %{"asset_id" => fixture.asset_id},
        principal_authorization_epoch: 0,
        principal_id: fixture.principal_id,
        required_capability: "asset.write",
        vault_authorization_epoch: 0,
        vault_id: fixture.vault_id,
        version: 1
      })

    envelope
  end

  defp clear_failure!(fixture) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE content.assets
        SET
          failure_code = NULL,
          retryable = NULL,
          failed_operation = NULL
        WHERE id = $1
        """,
        [Ecto.UUID.dump!(fixture.asset_id)]
      )
    end)
  end

  defp grant_asset_write!(fixture) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO core.capabilities (id, name)
        VALUES ($1, 'asset.write')
        ON CONFLICT (name) DO NOTHING
        """,
        [Ecto.UUID.dump!(Ecto.UUID.generate())]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.principal_capabilities (
          principal_id,
          vault_id,
          capability_id
        )
        SELECT $1, $2, capability.id
        FROM core.capabilities AS capability
        WHERE capability.name = 'asset.write'
        ON CONFLICT (principal_id, vault_id, capability_id) DO NOTHING
        """,
        [
          Ecto.UUID.dump!(fixture.principal_id),
          Ecto.UUID.dump!(fixture.vault_id)
        ]
      )
    end)
  end

  defp assert_failure_evidence(fixture, envelope, expected) do
    scoped(fixture, fn repo ->
      assert %{rows: [^expected]} =
               query!(
                 repo,
                 """
                 SELECT
                   asset.failure_code,
                   asset.retryable,
                   asset.failed_operation,
                   (
                     SELECT count(*)
                     FROM audit.events
                     WHERE target_id = asset.id
                       AND operation = 'asset.verify_failed'
                       AND result = 'failed'
                       AND metadata ->> 'job_id' = $2
                   ),
                   (
                     SELECT count(*)
                     FROM jobs.effect_receipts
                     WHERE submission_id = $3
                       AND result = 'failed'
                       AND entity_revision = 1
                   )
                 FROM content.assets AS asset
                 WHERE asset.id = $1
                 """,
                 [
                   Ecto.UUID.dump!(fixture.asset_id),
                   envelope.job_id,
                   Ecto.UUID.dump!(envelope.job_id)
                 ]
               )

      :ok
    end)
  end

  defp with_production_failure_handler(callback) do
    previous = Application.get_env(:singularity_storage, :job_handler)

    previous_failure_mode =
      Application.get_env(
        :singularity_storage,
        :controlled_failure_retryable
      )

    previous_authorization =
      Application.fetch_env!(
        :singularity_runtime,
        :authorization_dependencies
      )

    Application.put_env(
      :singularity_storage,
      :job_handler,
      ControlledFailureHandler
    )

    Application.put_env(
      :singularity_runtime,
      :authorization_dependencies,
      Map.put(
        previous_authorization,
        :store,
        Singularity.Storage.Postgres.IdentityRepository
      )
    )

    try do
      callback.()
    after
      Application.put_env(
        :singularity_runtime,
        :authorization_dependencies,
        previous_authorization
      )

      if previous do
        Application.put_env(:singularity_storage, :job_handler, previous)
      else
        Application.delete_env(:singularity_storage, :job_handler)
      end

      if is_boolean(previous_failure_mode) do
        Application.put_env(
          :singularity_storage,
          :controlled_failure_retryable,
          previous_failure_mode
        )
      else
        Application.delete_env(
          :singularity_storage,
          :controlled_failure_retryable
        )
      end
    end
  end

  defp insert_outbox!(envelope) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO core.outbox_events (
          id,
          event_type,
          idempotency_key,
          vault_id,
          principal_id,
          required_capability,
          principal_authorization_epoch,
          vault_authorization_epoch,
          classification,
          correlation_id,
          causation_id,
          expected_entity_revision,
          envelope_version,
          payload,
          occurred_at
        ) VALUES (
          $1, 'asset.verify_requested', $2, $3, $4, $5, $6, $7,
          $8, $9, $10, $11, 1, $12::text::jsonb, CURRENT_TIMESTAMP
        )
        """,
        [
          Ecto.UUID.dump!(envelope.job_id),
          envelope.idempotency_key,
          Ecto.UUID.dump!(envelope.vault_id),
          Ecto.UUID.dump!(envelope.principal_id),
          envelope.required_capability,
          envelope.principal_authorization_epoch,
          envelope.vault_authorization_epoch,
          Atom.to_string(envelope.classification),
          Ecto.UUID.dump!(envelope.correlation_id),
          Ecto.UUID.dump!(envelope.causation_id),
          envelope.expected_entity_revision,
          JSON.encode!(envelope.payload)
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO jobs.job_submissions (
          id,
          vault_id,
          outbox_event_id,
          classification,
          idempotency_key,
          job_type
        ) VALUES ($1, $2, $1, $3, $4, $5)
        """,
        [
          Ecto.UUID.dump!(envelope.job_id),
          Ecto.UUID.dump!(envelope.vault_id),
          Atom.to_string(envelope.classification),
          envelope.idempotency_key,
          envelope.job_type
        ]
      )
    end)
  end

  defp scoped(fixture, callback) do
    ScopedRepo.transact(
      RequestRepo,
      %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
      callback
    )
  end

  defp load_ids(fixture) do
    Map.new(fixture, fn
      {key, value}
      when key in [
             :account_id,
             :asset_id,
             :credential_id,
             :principal_id,
             :resource_id,
             :resource_version_id,
             :session_id,
             :vault_id
           ] ->
        {key, Ecto.UUID.load!(value)}

      pair ->
        pair
    end)
  end
end
