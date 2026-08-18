defmodule Singularity.Storage.OutboxObanTest do
  use ExUnit.Case, async: false

  alias Singularity.Core.JobEnvelope
  alias Singularity.Storage.Jobs.EnvelopeCodec
  alias Singularity.Storage.Jobs.GenericWorker

  @handler_key :job_handler
  @secret "CANARY_RAW_OBAN_SECRET_31d8"

  defmodule MalformedDependencies do
    @behaviour Singularity.Core.JobHandler

    @impl true
    def dependencies, do: [:not, :a, :map]

    @impl true
    def handle(_context, _envelope), do: :ok
  end

  defmodule ReservedDependencies do
    @behaviour Singularity.Core.JobHandler

    @impl true
    def dependencies, do: %{transact: fn _options, _fun -> :unsafe end}

    @impl true
    def handle(_context, _envelope), do: :ok
  end

  defmodule ConfiguredDependencies do
    @behaviour Singularity.Core.JobHandler

    @impl true
    def dependencies do
      Application.fetch_env!(:singularity_storage, :test_job_dependencies)
    end

    @impl true
    def handle(_context, _envelope), do: :ok
  end

  defmodule ExplodingDependencies do
    @behaviour Singularity.Core.JobHandler

    @impl true
    def dependencies, do: raise("CANARY_RAW_OBAN_SECRET_31d8")

    @impl true
    def handle(_context, _envelope), do: :ok
  end

  setup do
    previous = Application.get_env(:singularity_storage, @handler_key)

    previous_dependencies =
      Application.get_env(:singularity_storage, :test_job_dependencies)

    on_exit(fn ->
      if previous do
        Application.put_env(:singularity_storage, @handler_key, previous)
      else
        Application.delete_env(:singularity_storage, @handler_key)
      end

      if previous_dependencies do
        Application.put_env(
          :singularity_storage,
          :test_job_dependencies,
          previous_dependencies
        )
      else
        Application.delete_env(:singularity_storage, :test_job_dependencies)
      end
    end)
  end

  test "encodes and decodes the complete version-one envelope as string-keyed JSON data" do
    assert {:ok, envelope} = JobEnvelope.new(valid_envelope())
    assert {:ok, encoded} = EnvelopeCodec.encode(envelope)

    assert Map.keys(encoded) |> Enum.sort() ==
             ~w[
               attempt causation_id classification correlation_id
               expected_entity_revision idempotency_key job_id job_type payload
               principal_authorization_epoch principal_id required_capability
               vault_authorization_epoch vault_id version
             ]

    assert encoded["classification"] == "private"
    assert encoded["payload"] == %{"asset_id" => uuid(7)}
    assert {:ok, ^envelope} = EnvelopeCodec.decode(encoded)
  end

  test "rejects atom keys, missing authority, unknown versions and unknown job types" do
    assert {:error, %{code: :job_failed}} =
             valid_envelope()
             |> Map.put("version", 1)
             |> EnvelopeCodec.decode()

    for invalid <- [
          Map.delete(encoded_envelope(), "principal_id"),
          Map.delete(encoded_envelope(), "principal_authorization_epoch"),
          Map.delete(encoded_envelope(), "vault_authorization_epoch"),
          Map.put(encoded_envelope(), "version", 2),
          Map.put(encoded_envelope(), "job_type", "arbitrary.module.Name"),
          Map.put(encoded_envelope(), "payload", %{asset_id: uuid(7)}),
          Map.put(encoded_envelope(), "principal_authorization_epoch", -1),
          Map.put(encoded_envelope(), "vault_authorization_epoch", -1),
          Map.put(encoded_envelope(), "unexpected", "authority")
        ] do
      assert {:error, %{code: :job_failed}} = EnvelopeCodec.decode(invalid)
    end
  end

  test "accepts only the exact bounded payload and authority schema for each executable job type" do
    asset_id = uuid(7)
    object_id = uuid(8)
    manifest_id = uuid(9)

    schemas = [
      {"asset_finalize", "asset.write", %{"asset_id" => asset_id},
       "asset-finalize:#{asset_id}:7"},
      {"asset_verify", "asset.write", %{"asset_id" => asset_id}, "asset-verify:#{asset_id}:7"},
      {"asset_metadata", "asset.read", %{"asset_id" => asset_id}, "asset-metadata:#{asset_id}:7"},
      {"asset_cleanup", "asset.write", %{"asset_id" => asset_id}, "asset-cleanup:#{asset_id}:7"},
      {"object_cleanup", "object.cleanup", %{"asset_id" => asset_id, "object_id" => object_id},
       "object-cleanup:#{object_id}:7"},
      {"note_projection", "note.write", %{"resource_id" => asset_id},
       "note-current-changed:#{asset_id}:7"},
      {"backup", "backup.create", %{"pending_manifest_id" => manifest_id},
       "backup:#{manifest_id}"}
    ]

    for {job_type, capability, payload, idempotency_key} <- schemas do
      encoded =
        encoded_envelope()
        |> Map.put("job_type", job_type)
        |> Map.put("required_capability", capability)
        |> Map.put("payload", payload)
        |> Map.put("idempotency_key", idempotency_key)

      assert {:ok, %JobEnvelope{job_type: ^job_type, payload: ^payload}} =
               EnvelopeCodec.decode(encoded)

      assert EnvelopeCodec.known_job_type?(job_type)
    end
  end

  test "note projection accepts only one canonical resource id and private write authority" do
    resource_id = uuid(7)

    valid =
      encoded_envelope()
      |> Map.put("job_type", "note_projection")
      |> Map.put("required_capability", "note.write")
      |> Map.put("payload", %{"resource_id" => resource_id})
      |> Map.put("idempotency_key", "note-restored:#{resource_id}:#{uuid(8)}")

    assert {:ok, %JobEnvelope{payload: %{"resource_id" => ^resource_id}}} =
             EnvelopeCodec.decode(valid)

    for invalid <- [
          put_in(valid, ["payload"], %{"resource_id" => resource_id, "title" => @secret}),
          put_in(valid, ["payload"], %{"resource_id" => "bad"}),
          Map.put(valid, "required_capability", "note.read"),
          Map.put(valid, "classification", "sensitive"),
          Map.put(valid, "idempotency_key", "note-current-changed:#{resource_id}:#{@secret}")
        ] do
      assert {:error, %{code: :job_failed}} = EnvelopeCodec.decode(invalid)
      refute inspect(EnvelopeCodec.decode(invalid)) =~ @secret
    end
  end

  test "accepts the exact legacy sealed-upload producer schema" do
    asset_id = uuid(7)

    encoded =
      encoded_envelope()
      |> Map.put("required_capability", "assets.verify")
      |> Map.put("idempotency_key", "sealed-upload:#{asset_id}")

    assert {:ok,
            %JobEnvelope{
              job_type: "asset_verify",
              required_capability: "assets.verify",
              payload: %{"asset_id" => ^asset_id}
            }} = EnvelopeCodec.decode(encoded)
  end

  test "rejects free-form values that could carry secrets into raw Oban args" do
    assert {:ok, envelope} = JobEnvelope.new(valid_envelope())

    assert {:error, %{code: :job_failed}} =
             EnvelopeCodec.encode(%{envelope | classification: @secret})

    for invalid <- [
          Map.put(encoded_envelope(), "job_id", @secret),
          Map.put(encoded_envelope(), "correlation_id", @secret),
          Map.put(encoded_envelope(), "causation_id", @secret),
          Map.put(encoded_envelope(), "idempotency_key", @secret),
          Map.put(encoded_envelope(), "required_capability", @secret),
          Map.put(encoded_envelope(), "payload", %{
            "asset_id" => uuid(7),
            "token" => @secret
          }),
          Map.put(encoded_envelope(), "payload", %{"asset_id" => @secret}),
          encoded_envelope()
          |> Map.put("job_type", "maintenance")
          |> Map.put("payload", %{"command" => @secret})
        ] do
      assert {:error, %{code: :job_failed}} = EnvelopeCodec.decode(invalid)
      refute inspect(EnvelopeCodec.decode(invalid)) =~ @secret
    end
  end

  test "rejects the unsupported durable integrity audit job type" do
    assert {:ok, integrity_audit} =
             valid_envelope()
             |> Map.put(:job_type, "integrity_audit")
             |> JobEnvelope.new()

    assert {:error, %{code: :job_failed}} = EnvelopeCodec.encode(integrity_audit)

    assert {:error, %{code: :job_failed}} =
             encoded_envelope()
             |> Map.put("job_type", "integrity_audit")
             |> EnvelopeCodec.decode()

    refute EnvelopeCodec.known_job_type?("integrity_audit")
    refute EnvelopeCodec.known_job_type?("maintenance")
  end

  test "generic worker fails closed before checkout when callback configuration is missing" do
    Application.delete_env(:singularity_storage, @handler_key)

    assert {:cancel, %{code: :job_failed}} =
             GenericWorker.perform(%Oban.Job{args: encoded_envelope()})
  end

  test "generic worker rejects malformed and worker-reserved injected dependencies" do
    for handler <- [MalformedDependencies, ReservedDependencies] do
      Application.put_env(:singularity_storage, @handler_key, handler)

      assert {:cancel, %{code: :job_failed}} =
               GenericWorker.perform(%Oban.Job{args: encoded_envelope()})
    end

    Application.put_env(
      :singularity_storage,
      @handler_key,
      ConfiguredDependencies
    )

    for reserved <- [
          :repo_handle,
          :lock_mode,
          :transact,
          "repo_handle",
          "lock_mode",
          "transact"
        ] do
      Application.put_env(
        :singularity_storage,
        :test_job_dependencies,
        %{reserved => :injected}
      )

      assert {:cancel, %{code: :job_failed}} =
               GenericWorker.perform(%Oban.Job{args: encoded_envelope()})
    end
  end

  test "generic worker rejects envelopes without principal or vault context" do
    Application.put_env(
      :singularity_storage,
      @handler_key,
      Singularity.Storage.Fake.JobHandler
    )

    for field <- ["principal_id", "vault_id"] do
      assert {:cancel, %{code: :job_failed}} =
               GenericWorker.perform(%Oban.Job{
                 args: Map.put(encoded_envelope(), field, "")
               })
    end
  end

  test "generic worker cancels malformed nonempty PostgreSQL authority IDs" do
    Application.put_env(
      :singularity_storage,
      @handler_key,
      Singularity.Storage.Fake.JobHandler
    )

    for field <- ["principal_id", "vault_id"] do
      assert {:cancel, %{code: :job_failed}} =
               GenericWorker.perform(%Oban.Job{
                 args: Map.put(encoded_envelope(), field, "not-a-uuid")
               })
    end
  end

  test "generic worker collapses callback values into bounded Oban outcomes" do
    assert :ok = GenericWorker.normalize_result({:ok, %{token: @secret}})
    assert {:snooze, 1} = GenericWorker.normalize_result({:snooze, 1})
    assert {:snooze, 60} = GenericWorker.normalize_result({:snooze, 60})
    assert {:cancel, %{code: :job_failed}} = GenericWorker.normalize_result({:snooze, 61})

    assert {:error, %{code: :job_failed}} =
             GenericWorker.normalize_result(
               {:error,
                Singularity.Core.Error.new(:storage_unavailable,
                  retryable?: true,
                  details: %{token: @secret}
                )}
             )

    for unsafe <- [
          {:error, @secret},
          {:cancel, @secret},
          RuntimeError.exception(@secret),
          @secret
        ] do
      result = GenericWorker.normalize_result(unsafe)
      assert result == {:cancel, %{code: :job_failed}}
      refute inspect(result) =~ @secret
    end
  end

  test "generic worker fails closed on malformed decoder input" do
    malformed =
      encoded_envelope()
      |> Map.put("payload", ["improper" | @secret])

    assert {:cancel, %{code: :job_failed}} =
             GenericWorker.perform(%Oban.Job{args: malformed})
  end

  test "an actual raw Oban event contains no callback exception canary" do
    Application.put_env(
      :singularity_storage,
      @handler_key,
      ExplodingDependencies
    )

    events = [
      [:oban, :job, :start],
      [:oban, :job, :exception],
      [:oban, :job, :stop]
    ]

    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.capture_raw_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    now = DateTime.utc_now()

    job = %Oban.Job{
      args: encoded_envelope(),
      attempt: 1,
      attempted_at: now,
      max_attempts: 3,
      queue: "asset_verify",
      scheduled_at: now,
      worker: Oban.Worker.to_string(GenericWorker)
    }

    conf =
      Oban.Config.new(
        name: __MODULE__,
        repo: Singularity.Storage.WorkerRepo,
        testing: :manual
      )

    assert %{state: :failure} =
             conf
             |> Oban.Queue.Executor.new(job, ack: false)
             |> Oban.Queue.Executor.call()

    assert_receive {:raw_oban, [:oban, :job, :start], _measurements, start_metadata}

    assert_receive {:raw_oban, [:oban, :job, :exception], _measurements, exception_metadata}

    for metadata <- [start_metadata, exception_metadata] do
      refute inspect(metadata) =~ @secret
    end

    assert exception_metadata.result == {:error, %{code: :job_failed}}
    assert exception_metadata.stacktrace == []
    refute_receive {:raw_oban, [:oban, :job, :stop], _, _}
  end

  @doc false
  def capture_raw_event(event, measurements, metadata, owner) do
    send(owner, {:raw_oban, event, measurements, metadata})
  end

  defp encoded_envelope do
    %{
      "version" => 1,
      "job_id" => uuid(1),
      "job_type" => "asset_verify",
      "idempotency_key" => "asset-verify:#{uuid(7)}:7",
      "vault_id" => uuid(2),
      "principal_id" => uuid(3),
      "required_capability" => "asset.write",
      "principal_authorization_epoch" => 4,
      "vault_authorization_epoch" => 9,
      "classification" => "private",
      "correlation_id" => uuid(5),
      "causation_id" => uuid(6),
      "expected_entity_revision" => 7,
      "attempt" => 0,
      "payload" => %{"asset_id" => uuid(7)}
    }
  end

  defp valid_envelope do
    %{
      version: 1,
      job_id: uuid(1),
      job_type: "asset_verify",
      idempotency_key: "asset-verify:#{uuid(7)}:7",
      vault_id: uuid(2),
      principal_id: uuid(3),
      required_capability: "asset.write",
      principal_authorization_epoch: 4,
      vault_authorization_epoch: 9,
      classification: :private,
      correlation_id: uuid(5),
      causation_id: uuid(6),
      expected_entity_revision: 7,
      attempt: 0,
      payload: %{"asset_id" => uuid(7)}
    }
  end

  defp uuid(number) do
    "00000000-0000-0000-0000-#{number |> Integer.to_string() |> String.pad_leading(12, "0")}"
  end
end
