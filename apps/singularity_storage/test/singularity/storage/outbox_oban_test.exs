defmodule Singularity.Storage.OutboxObanTest do
  use ExUnit.Case, async: false

  alias Singularity.Core.JobEnvelope
  alias Singularity.Storage.Jobs.EnvelopeCodec
  alias Singularity.Storage.Jobs.GenericWorker

  @handler_key :job_handler

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

  defp encoded_envelope do
    %{
      "version" => 1,
      "job_id" => uuid(1),
      "job_type" => "asset_verify",
      "idempotency_key" => "asset:verify:7",
      "vault_id" => uuid(2),
      "principal_id" => uuid(3),
      "required_capability" => "asset:verify",
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
      idempotency_key: "asset:verify:7",
      vault_id: uuid(2),
      principal_id: uuid(3),
      required_capability: "asset:verify",
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
