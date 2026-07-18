defmodule Singularity.Runtime.Application do
  @moduledoc false

  use Application

  alias Singularity.Runtime.AuthorizationDependencies
  alias Singularity.Runtime.KeyCustodian
  alias Singularity.Runtime.KeyLeaseSupervisor

  @impl true
  def start(_type, _args) do
    children = infrastructure_children(composition())

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Singularity.Runtime.Supervisor
    )
  end

  @spec infrastructure_children(map()) :: [Supervisor.child_spec()]
  def infrastructure_children(%{start_infrastructure: false}), do: []

  def infrastructure_children(%{start_infrastructure: true} = composition) do
    composition = validate_composition!(composition)

    key_lease_supervisor = %{
      id: KeyLeaseSupervisor,
      start: {__MODULE__, :start_named_key_lease_supervisor, []},
      type: :supervisor
    }

    custodian_options =
      Map.put(
        composition.key_custodian,
        :lease_supervisor,
        KeyLeaseSupervisor
      )

    key_custodian = %{
      id: KeyCustodian,
      start: {__MODULE__, :start_named_key_custodian, [custodian_options]}
    }

    [
      Singularity.Storage.RequestRepo,
      Singularity.Storage.PreAuthRepo,
      Singularity.Storage.DispatcherRepo,
      Singularity.Storage.WorkerRepo,
      key_lease_supervisor,
      key_custodian,
      {Singularity.Storage.Jobs.ObanAdapter, composition.oban},
      {Singularity.Runtime.OutboxDispatcher, composition.outbox_dispatcher}
    ]
  end

  def infrastructure_children(_composition),
    do: raise(ArgumentError, "runtime job composition is invalid")

  @spec job_dependencies() :: map()
  def job_dependencies do
    dependencies =
      :singularity_runtime
      |> Application.fetch_env!(:authorization_dependencies)
      |> build_authorization!()

    %{authorization: dependencies}
  end

  @doc false
  def start_named_key_lease_supervisor do
    with {:ok, pid} <- KeyLeaseSupervisor.start_link([]) do
      true = Process.register(pid, KeyLeaseSupervisor)
      {:ok, pid}
    end
  end

  @doc false
  def start_named_key_custodian(options) do
    with {:ok, pid} <- KeyCustodian.start_link(options) do
      true = Process.register(pid, KeyCustodian)
      {:ok, pid}
    end
  end

  defp composition do
    %{
      start_infrastructure: Application.fetch_env!(:singularity_runtime, :start_infrastructure),
      job_handler: Application.get_env(:singularity_storage, :job_handler),
      authorization: Application.get_env(:singularity_runtime, :authorization_dependencies),
      key_custodian: Application.get_env(:singularity_runtime, :key_custodian),
      oban: Application.get_env(:singularity_runtime, :oban_options, []),
      outbox_dispatcher: Application.get_env(:singularity_runtime, :outbox_dispatcher_options, [])
    }
  end

  defp validate_composition!(composition) do
    with true <- valid_handler?(composition.job_handler),
         %AuthorizationDependencies{} <- build_authorization!(composition.authorization),
         true <- valid_custodian_options?(composition.key_custodian),
         true <- is_list(composition.oban),
         true <- is_list(composition.outbox_dispatcher) do
      composition
    else
      _invalid -> raise ArgumentError, "runtime job composition is invalid"
    end
  rescue
    _error -> raise ArgumentError, "runtime job composition is invalid"
  end

  defp build_authorization!(dependencies) do
    case AuthorizationDependencies.new(dependencies) do
      {:ok, authorization} -> authorization
      {:error, _error} -> raise ArgumentError, "runtime job composition is invalid"
    end
  end

  defp valid_handler?(handler) when is_atom(handler) and not is_nil(handler) do
    Code.ensure_loaded?(handler) and function_exported?(handler, :dependencies, 0) and
      function_exported?(handler, :handle, 2)
  end

  defp valid_handler?(_handler), do: false

  defp valid_custodian_options?(options) when is_map(options) do
    Enum.all?(
      [
        :authorization,
        :clock,
        :context,
        :idle_lock,
        :key_reader,
        :object_key_loader
      ],
      fn key ->
        Map.has_key?(options, key) and Map.fetch!(options, key) not in [nil, false]
      end
    )
  end

  defp valid_custodian_options?(_options), do: false
end
