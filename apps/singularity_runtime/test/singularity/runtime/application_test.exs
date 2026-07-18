defmodule Singularity.Runtime.ApplicationTest do
  use ExUnit.Case, async: false

  alias Singularity.Runtime.Application, as: RuntimeApplication
  alias Singularity.Runtime.AuthorizationDependencies
  alias Singularity.Runtime.JobDispatcher
  alias Singularity.Storage.Jobs.GenericWorker

  test "pure tests opt out of every infrastructure child" do
    assert RuntimeApplication.infrastructure_children(%{
             start_infrastructure: false
           }) == []
  end

  test "infrastructure children preserve the literal dependency order" do
    composition = valid_composition()

    assert RuntimeApplication.infrastructure_children(composition)
           |> Enum.map(&child_id/1) == [
             Singularity.Storage.RequestRepo,
             Singularity.Storage.PreAuthRepo,
             Singularity.Storage.DispatcherRepo,
             Singularity.Storage.WorkerRepo,
             Singularity.Runtime.KeyLeaseSupervisor,
             Singularity.Runtime.KeyCustodian,
             Singularity.Storage.Jobs.ObanAdapter,
             Singularity.Runtime.OutboxDispatcher
           ]

    refute Singularity.Storage.MigrationRepo in Enum.map(
             RuntimeApplication.infrastructure_children(composition),
             &child_id/1
           )
  end

  test "startup validation fails closed for a missing handler or authorization member" do
    for invalid <- [
          put_in(valid_composition(), [:job_handler], nil),
          put_in(valid_composition(), [:authorization, :store], nil),
          put_in(valid_composition(), [:authorization, :custodian], nil),
          update_in(
            valid_composition(),
            [:key_custodian],
            &Map.delete(&1, :object_key_loader)
          )
        ] do
      assert_raise ArgumentError, ~r/runtime job composition is invalid/, fn ->
        RuntimeApplication.infrastructure_children(invalid)
      end
    end
  end

  test "authorization bundle has a concrete store and custodian" do
    assert {:ok,
            %{
              __struct__: AuthorizationDependencies,
              store: Fake.Authorization,
              custodian: Singularity.Runtime.KeyCustodian
            }} =
             AuthorizationDependencies.new(%{
               store: Fake.Authorization,
               custodian: Singularity.Runtime.KeyCustodian
             })

    for invalid <- [%{}, %{store: Fake.Authorization}, %{custodian: self()}] do
      assert {:error, %{code: :job_failed}} =
               AuthorizationDependencies.new(invalid)
    end
  end

  test "runtime has no direct Oban dependency and storage has no runtime dependency" do
    runtime_mix = File.read!(Path.expand("../../../mix.exs", __DIR__))
    storage_mix = File.read!(Path.expand("../../../../singularity_storage/mix.exs", __DIR__))

    refute runtime_mix =~ "{:oban,"
    refute storage_mix =~ ":singularity_runtime"
  end

  test "runtime handler and generic worker fail closed for an invalid authorization bundle" do
    previous_handler = Application.get_env(:singularity_storage, :job_handler)

    previous_authorization =
      Application.get_env(:singularity_runtime, :authorization_dependencies)

    on_exit(fn ->
      Application.put_env(:singularity_storage, :job_handler, previous_handler)

      Application.put_env(
        :singularity_runtime,
        :authorization_dependencies,
        previous_authorization
      )
    end)

    Application.put_env(:singularity_storage, :job_handler, JobDispatcher)

    for invalid <- [
          nil,
          %{store: nil, custodian: Singularity.Runtime.KeyCustodian},
          %{store: Fake.Authorization, custodian: nil}
        ] do
      if invalid do
        Application.put_env(
          :singularity_runtime,
          :authorization_dependencies,
          invalid
        )
      else
        Application.delete_env(
          :singularity_runtime,
          :authorization_dependencies
        )
      end

      assert {:cancel, %{code: :job_failed}} =
               GenericWorker.perform(%Oban.Job{args: encoded_envelope()})
    end
  end

  test "runtime handler exposes only the explicit bundle and rejects all unregistered jobs" do
    assert %{
             authorization: %AuthorizationDependencies{
               store: Fake.Authorization,
               custodian: Singularity.Runtime.KeyCustodian
             }
           } = JobDispatcher.dependencies()

    assert {:error, %{code: :job_failed}} =
             JobDispatcher.handle(JobDispatcher.dependencies(), :unregistered)
  end

  defp valid_composition do
    %{
      start_infrastructure: true,
      job_handler: Singularity.Runtime.JobDispatcher,
      authorization: %{
        store: Fake.Authorization,
        custodian: Singularity.Runtime.KeyCustodian
      },
      key_custodian: %{
        authorization: Fake.Authorization,
        clock: Fake.Clock,
        context: %{},
        idle_lock: fn _session -> :ok end,
        key_reader: Fake.KeyReader,
        object_key_loader: Fake.KeyReader
      },
      oban: [],
      outbox_dispatcher: []
    }
  end

  defp child_id(module) when is_atom(module), do: module
  defp child_id({module, _options}) when is_atom(module), do: module
  defp child_id(%{id: id}), do: id

  defp encoded_envelope do
    %{
      "version" => 1,
      "job_id" => "00000000-0000-0000-0000-000000000001",
      "job_type" => "asset_verify",
      "idempotency_key" => "asset:verify:7",
      "vault_id" => "00000000-0000-0000-0000-000000000002",
      "principal_id" => "00000000-0000-0000-0000-000000000003",
      "required_capability" => "asset:verify",
      "authorization_epoch" => 4,
      "classification" => "private",
      "correlation_id" => "00000000-0000-0000-0000-000000000005",
      "causation_id" => "00000000-0000-0000-0000-000000000006",
      "expected_entity_revision" => 7,
      "attempt" => 0,
      "payload" => %{"asset_id" => "00000000-0000-0000-0000-000000000007"}
    }
  end
end
