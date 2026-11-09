defmodule Singularity.Runtime.UploadSessionSupervisor do
  @moduledoc "Bounds short-lived upload sessions independently of request capacity."

  use DynamicSupervisor

  alias Singularity.Core.Error
  alias Singularity.Runtime.Assets.UploadSession

  @default_max_children 2

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options) when is_list(options) do
    max_children =
      Keyword.get_lazy(options, :max_children, fn ->
        Application.get_env(
          :singularity_runtime,
          :max_concurrent_uploads,
          @default_max_children
        )
      end)

    with true <- is_integer(max_children) and max_children > 0 do
      supervisor_options =
        case Keyword.get(options, :name, __MODULE__) do
          nil -> []
          name -> [name: name]
        end

      DynamicSupervisor.start_link(
        __MODULE__,
        max_children,
        supervisor_options
      )
    else
      false -> {:error, Error.new(:invalid)}
    end
  end

  def start_link(_options), do: {:error, Error.new(:invalid)}

  @spec start_upload(Supervisor.supervisor(), Supervisor.child_spec()) ::
          DynamicSupervisor.on_start_child() | {:error, Error.t()}
  def start_upload(supervisor, child_spec) do
    case DynamicSupervisor.start_child(supervisor, child_spec) do
      {:error, :max_children} ->
        {:error, Error.new(:storage_unavailable, retryable?: true)}

      result ->
        result
    end
  rescue
    _error -> {:error, Error.new(:invalid)}
  end

  @doc """
  Starts one bounded upload and returns only after its grant consumption and
  durable open-stage transaction have committed.

  Callers must invoke this before reading a request body.
  """
  @spec begin_upload(map(), map(), map(), pid()) ::
          {:ok, pid()} | {:error, Error.t()}
  def begin_upload(runtime, session, grant, owner)
      when is_map(runtime) and is_map(session) and is_map(grant) and
             is_pid(owner) do
    supervisor = Map.get(runtime, :upload_session_supervisor, __MODULE__)
    session_module = Map.get(runtime, :upload_session, UploadSession)

    with true <- concrete_module?(session_module),
         {:ok, upload} <-
           start_upload(
             supervisor,
             {session_module, runtime: runtime, session: session, grant: grant, owner: owner}
           ) do
      case apply(session_module, :await_ready, [upload]) do
        {:ok, ^upload} ->
          {:ok, upload}

        {:error, %Error{}} = error ->
          _ = DynamicSupervisor.terminate_child(supervisor, upload)
          error

        _invalid ->
          _ = DynamicSupervisor.terminate_child(supervisor, upload)
          {:error, Error.new(:storage_unavailable, retryable?: true)}
      end
    else
      false -> {:error, Error.new(:invalid)}
      {:error, %Error{}} = error -> error
      _invalid -> {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  rescue
    _error -> {:error, Error.new(:invalid)}
  end

  def begin_upload(_runtime, _session, _grant, _owner),
    do: {:error, Error.new(:invalid)}

  @impl true
  def init(max_children) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_children: max_children
    )
  end

  defp concrete_module?(module) when is_atom(module) and not is_nil(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :child_spec, 1) and
      function_exported?(module, :await_ready, 1)
  end

  defp concrete_module?(_module), do: false
end
