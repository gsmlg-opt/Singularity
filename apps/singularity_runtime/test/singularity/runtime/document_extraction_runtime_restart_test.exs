defmodule Singularity.Runtime.DocumentExtractionRuntimeRestartTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration
  @moduletag timeout: 300_000

  alias Singularity.Core.{Error, JobEnvelope}
  alias Singularity.Runtime.Documents.ExtractionReconciler
  alias Singularity.Storage.{Fixtures, KnowledgeFixtures, MigrationRepo}
  alias Singularity.Storage.Jobs.{EnvelopeCodec, WorkerScope}
  alias Singularity.Storage.Postgres.DocumentWorkerRepository

  @runtime_names [Singularity.Runtime.Supervisor, ExtractionReconciler, WorkerRepo]
  @event_fields ~w(event_type idempotency_key vault_id principal_id required_capability principal_authorization_epoch vault_authorization_epoch classification correlation_id causation_id expected_entity_revision envelope_version payload)

  test "replacing Runtime automatically recovers an attempt that expired while it was stopped" do
    assert_isolated_environment!()
    old_processes = runtime_processes!()

    on_exit(fn ->
      assert {:ok, _started} = Application.ensure_all_started(:singularity_runtime)
      runtime_processes!()
    end)

    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)
    KnowledgeFixtures.retire_document_on_exit!(document)
    {event, envelope} = extraction_event!(source, document)
    {pending, _observed_at} = snapshot!(document)

    assert pending.row["state"] == "pending"
    assert pending.row["attempt_generation"] == 0
    assert pending.events == [event]

    for field <-
          ~w(source_asset_id source_resource_id source_resource_version_id source_object_id source_digest source_byte_size media_type created_by_principal_id)a do
      assert pending.row[Atom.to_string(field)] == Map.fetch!(document, field)
    end

    assert {:ok, attempt} = claim(envelope)

    assert attempt == %{
             resource_id: Ecto.UUID.load!(document.resource_id),
             resource_version_id: Ecto.UUID.load!(document.resource_version_id),
             job_id: event["id"],
             generation: 1,
             state: :extracting,
             adapter_name: "plain_text",
             format_version: 1,
             started_at: attempt.started_at,
             deadline_at: attempt.deadline_at
           }

    assert %DateTime{} = attempt.started_at
    assert %DateTime{} = attempt.deadline_at
    assert DateTime.diff(attempt.deadline_at, attempt.started_at, :microsecond) == 180_000_000

    expected_attempt = %{
      pending
      | row:
          Map.merge(pending.row, %{
            "state" => "extracting",
            "attempt_generation" => 1,
            "attempt_job_id" => Ecto.UUID.dump!(envelope.job_id),
            "attempt_started_at" => attempt.started_at,
            "attempt_deadline_at" => attempt.deadline_at,
            "extraction_adapter" => "plain_text",
            "extraction_format" => 1
          })
    }

    {original, _observed_at} = snapshot!(document)
    assert original == expected_attempt
    monitors = Enum.map(old_processes, fn {_name, pid} -> {pid, Process.monitor(pid)} end)

    assert :ok = Application.stop(:singularity_runtime)

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 5_000
      refute Process.alive?(pid)
    end

    assert_runtime_stopped!()
    {stopped, stopped_at} = snapshot!(document)
    assert stopped == original
    assert DateTime.compare(stopped_at, attempt.deadline_at) == :lt

    await_expiry!(document, original, System.monotonic_time(:millisecond) + 210_000)

    restart_started_at = System.monotonic_time(:millisecond)
    assert {:ok, started} = Application.ensure_all_started(:singularity_runtime)
    assert :singularity_runtime in started
    new_processes = runtime_processes!()

    for name <- @runtime_names do
      refute Map.fetch!(new_processes, name) == Map.fetch!(old_processes, name)
    end

    recovered =
      await_recovery!(document, original, event, restart_started_at + 10_000)

    assert {:error, %Error{code: :conflict}} = claim(envelope)
    {after_replay, _observed_at} = snapshot!(document)
    assert after_replay == recovered
    assert runtime_processes!() == new_processes
  end

  defp assert_isolated_environment! do
    assert Application.fetch_env!(:singularity_runtime, :start_infrastructure) == true
    assert %{rows: [[database]]} = query!(WorkerRepo, "SELECT current_database()")
    assert database =~ ~r/\Asingularity_test_[0-9a-f]{24}\z/
    suffix = String.replace_prefix(database, "singularity_test_", "")

    assert Application.fetch_env!(:singularity_storage, :storage_root) ==
             Path.join([System.tmp_dir!(), "singularity", "integration", suffix])

    for repo <- [MigrationRepo, RequestRepo, PreAuthRepo, DispatcherRepo, WorkerRepo] do
      assert Keyword.fetch!(repo.config(), :database) == database
    end

    assert %{rows: [[^database]]} =
             Fixtures.with_owner(fn -> query!(MigrationRepo, "SELECT current_database()") end)
  end

  defp runtime_processes! do
    processes =
      Map.new(@runtime_names, fn name ->
        pid = Process.whereis(name)
        assert is_pid(pid)
        assert Process.alive?(pid)
        {name, pid}
      end)

    children = Supervisor.which_children(Map.fetch!(processes, Singularity.Runtime.Supervisor))

    for {name, type} <- [{ExtractionReconciler, :worker}, {WorkerRepo, :supervisor}] do
      pid = Map.fetch!(processes, name)
      assert {name, pid, type, [name]} in children
    end

    assert is_pid(Oban.whereis(Singularity.Oban))

    assert %Oban.Config{
             name: Singularity.Oban,
             repo: WorkerRepo,
             testing: :manual,
             queues: [],
             plugins: []
           } = Oban.config(Singularity.Oban)

    processes
  end

  defp assert_runtime_stopped! do
    for name <- @runtime_names, do: assert(is_nil(Process.whereis(name)))
  end

  defp extraction_event!(source, document) do
    event =
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "INSERT INTO core.capabilities(id,name) VALUES($1,'asset.read') ON CONFLICT (name) DO NOTHING",
          [KnowledgeFixtures.uuid()]
        )

        assert %{num_rows: 1} =
                 query!(
                   MigrationRepo,
                   "INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name='asset.read'",
                   [source.principal_id, source.vault_id]
                 )

        %{rows: [[principal_epoch, owner_epoch]]} =
          query!(
            MigrationRepo,
            "SELECT p.authorization_epoch,v.authorization_epoch FROM identity.principals p CROSS JOIN core.vaults v WHERE p.id=$1 AND v.id=$2",
            [source.principal_id, source.vault_id]
          )

        %{rows: [[event]]} =
          query!(
            MigrationRepo,
            """
            INSERT INTO core.outbox_events AS event
              (id,event_type,idempotency_key,vault_id,principal_id,required_capability,
               principal_authorization_epoch,vault_authorization_epoch,classification,
               correlation_id,causation_id,expected_entity_revision,envelope_version,payload,occurred_at)
            VALUES ($1,'document.extraction_requested',$2,$3,$4,'asset.read',$5,$6,'private',
                    $7,$1,0,1,$8::jsonb,clock_timestamp())
            RETURNING to_jsonb(event)
            """,
            [
              KnowledgeFixtures.uuid(),
              "document-extraction:#{Ecto.UUID.load!(document.resource_version_id)}",
              source.vault_id,
              source.principal_id,
              principal_epoch,
              owner_epoch,
              document.resource_version_id,
              %{
                "resource_id" => Ecto.UUID.load!(document.resource_id),
                "resource_version_id" => Ecto.UUID.load!(document.resource_version_id)
              }
            ]
          )

        Map.take(event, ["id" | @event_fields])
      end)

    assert {:ok, envelope} =
             JobEnvelope.new(%{
               version: event["envelope_version"],
               job_id: event["id"],
               job_type: "document_extract",
               idempotency_key: event["idempotency_key"],
               vault_id: event["vault_id"],
               principal_id: event["principal_id"],
               required_capability: event["required_capability"],
               principal_authorization_epoch: event["principal_authorization_epoch"],
               vault_authorization_epoch: event["vault_authorization_epoch"],
               classification: :private,
               correlation_id: event["correlation_id"],
               causation_id: event["causation_id"],
               expected_entity_revision: event["expected_entity_revision"],
               attempt: 0,
               payload: event["payload"]
             })

    assert event["classification"] == "private"
    assert {:ok, encoded} = EnvelopeCodec.encode(envelope)
    assert {:ok, ^envelope} = EnvelopeCodec.decode(encoded)
    {event, envelope}
  end

  defp claim(envelope) do
    WorkerScope.run(envelope, fn context ->
      assert context.repo_handle == WorkerRepo
      assert WorkerRepo.checked_out?()
      refute WorkerRepo.in_transaction?()
      DocumentWorkerRepository.claim(context, envelope, "plain_text", 1)
    end)
  end

  defp snapshot!(document) do
    Fixtures.with_owner(fn ->
      result =
        query!(
          MigrationRepo,
          """
          SELECT d.*, clock_timestamp() AS observed_at,
            p.authorization_epoch AS current_principal_epoch,
            v.authorization_epoch AS current_owner_epoch,
            COALESCE((SELECT jsonb_agg(to_jsonb(provenance) ORDER BY provenance.id)
              FROM (SELECT #{Enum.join(["id" | @event_fields], ",")}
                FROM core.outbox_events e
                WHERE e.event_type='document.extraction_requested'
                  AND (e.payload->>'resource_version_id'=$1::uuid::text
                       OR e.idempotency_key=$2 OR e.idempotency_key LIKE $2 || ':%')) provenance),
              '[]'::jsonb) AS extraction_events
          FROM content.document_versions d
          JOIN identity.principals p ON p.id=d.created_by_principal_id
          JOIN core.vaults v ON v.id=d.vault_id
          WHERE d.resource_version_id=$1
          """,
          [
            document.resource_version_id,
            "document-extraction:#{Ecto.UUID.load!(document.resource_version_id)}"
          ]
        )

      assert [values] = result.rows
      row = Map.new(Enum.zip(result.columns, values))

      {%{
         row:
           Map.drop(
             row,
             ~w(observed_at current_principal_epoch current_owner_epoch extraction_events)
           ),
         events: row["extraction_events"],
         epochs: {row["current_principal_epoch"], row["current_owner_epoch"]}
       }, row["observed_at"]}
    end)
  end

  defp await_expiry!(document, original, deadline) do
    assert_runtime_stopped!()
    {snapshot, observed_at} = snapshot!(document)
    assert snapshot == original
    assert System.monotonic_time(:millisecond) < deadline

    if DateTime.compare(observed_at, original.row["attempt_deadline_at"]) == :gt do
      :ok
    else
      Process.sleep(1_000)
      await_expiry!(document, original, deadline)
    end
  end

  defp await_recovery!(document, original, original_event, deadline) do
    assert System.monotonic_time(:millisecond) < deadline
    {snapshot, _observed_at} = snapshot!(document)
    assert System.monotonic_time(:millisecond) < deadline

    if snapshot == original do
      Process.sleep(20)
      await_recovery!(document, original, original_event, deadline)
    else
      expected_row =
        Map.merge(original.row, %{
          "state" => "pending",
          "attempt_generation" => 2,
          "attempt_job_id" => nil,
          "attempt_started_at" => nil,
          "attempt_deadline_at" => nil,
          "extraction_adapter" => nil,
          "extraction_format" => nil,
          "extracted_text_digest" => nil,
          "detected_language" => nil,
          "failure_code" => nil,
          "attempt_finished_at" => nil
        })

      assert snapshot.row == expected_row
      assert snapshot.epochs == original.epochs
      assert length(snapshot.events) == 2
      assert original_event in snapshot.events
      assert [successor] = Enum.reject(snapshot.events, &(&1 == original_event))
      successor_id = successor["id"]
      assert {:ok, ^successor_id} = Ecto.UUID.cast(successor_id)
      refute successor_id == original_event["id"]
      {principal_epoch, owner_epoch} = snapshot.epochs

      assert Map.take(successor, @event_fields) == %{
               "event_type" => "document.extraction_requested",
               "idempotency_key" => original_event["idempotency_key"] <> ":2",
               "vault_id" => original_event["vault_id"],
               "principal_id" => original_event["principal_id"],
               "required_capability" => "asset.read",
               "principal_authorization_epoch" => principal_epoch,
               "vault_authorization_epoch" => owner_epoch,
               "classification" => "private",
               "correlation_id" => Ecto.UUID.load!(document.resource_version_id),
               "causation_id" => original_event["id"],
               "expected_entity_revision" => 2,
               "envelope_version" => 1,
               "payload" => %{
                 "resource_id" => Ecto.UUID.load!(document.resource_id),
                 "resource_version_id" => Ecto.UUID.load!(document.resource_version_id)
               }
             }

      snapshot
    end
  end
end
