defmodule Singularity.Core.ObjectStorageContractMemoryAdapter do
  @moduledoc false

  @behaviour Singularity.Core.ObjectStorage

  alias Singularity.Core.Error
  alias Singularity.Core.ObjectRef
  alias Singularity.Core.StageRef

  def new_context, do: :ets.new(__MODULE__, [:set, :public])

  @impl true
  def stage(context, _options) do
    stage_ref = %StageRef{stage_id: unique_id("stage")}
    true = :ets.insert(context, {{:stage, stage_ref.stage_id}, %{bytes: "", sealed?: false}})
    {:ok, stage_ref}
  end

  @impl true
  def append_encrypted_chunk(context, %StageRef{stage_id: stage_id}, chunk) do
    case :ets.lookup(context, {:stage, stage_id}) do
      [{{:stage, ^stage_id}, stage}] ->
        updated = %{stage | bytes: stage.bytes <> IO.iodata_to_binary(chunk)}
        true = :ets.insert(context, {{:stage, stage_id}, updated})
        :ok

      [] ->
        {:error, Error.new(:not_found)}
    end
  end

  @impl true
  def seal_stage(context, %StageRef{stage_id: stage_id}, metadata) do
    case :ets.lookup(context, {:stage, stage_id}) do
      [{{:stage, ^stage_id}, stage}] ->
        true =
          :ets.insert(
            context,
            {{:stage, stage_id}, Map.merge(stage, %{sealed?: true, metadata: metadata})}
          )

        {:ok, metadata}

      [] ->
        {:error, Error.new(:not_found)}
    end
  end

  @impl true
  def stat_stage(context, %StageRef{stage_id: stage_id}) do
    case :ets.lookup(context, {:stage, stage_id}) do
      [{{:stage, ^stage_id}, %{metadata: metadata}}] -> {:ok, metadata}
      [{{:stage, ^stage_id}, _stage}] -> {:ok, %{}}
      [] -> {:error, Error.new(:not_found)}
    end
  end

  @impl true
  def finalize(
        context,
        %StageRef{stage_id: stage_id},
        %ObjectRef{object_id: object_id} = object_ref
      ) do
    case :ets.lookup(context, {:stage, stage_id}) do
      [{{:stage, ^stage_id}, %{sealed?: true} = stage}] ->
        true = :ets.insert(context, {{:object, object_id}, stage})
        true = :ets.delete(context, {:stage, stage_id})
        {:ok, object_ref}

      [{{:stage, ^stage_id}, _stage}] ->
        {:error, Error.new(:invalid)}

      [] ->
        {:error, Error.new(:not_found)}
    end
  end

  @impl true
  def abort_stage(context, %StageRef{stage_id: stage_id}) do
    true = :ets.delete(context, {:stage, stage_id})
    :ok
  end

  @impl true
  def stat(context, %ObjectRef{object_id: object_id}) do
    case :ets.lookup(context, {:object, object_id}) do
      [{{:object, ^object_id}, %{metadata: metadata}}] -> {:ok, metadata}
      [] -> {:error, Error.new(:not_found)}
    end
  end

  @impl true
  def open(context, %ObjectRef{object_id: object_id}) do
    case :ets.lookup(context, {:object, object_id}) do
      [{{:object, ^object_id}, _object}] -> {:ok, {context, object_id}}
      [] -> {:error, Error.new(:not_found)}
    end
  end

  @impl true
  def read_range(context, {context, object_id}, first..last//1)
      when first >= 0 and last >= first do
    case :ets.lookup(context, {:object, object_id}) do
      [{{:object, ^object_id}, %{bytes: bytes}}] ->
        {:ok, binary_part(bytes, first, last - first + 1)}

      [] ->
        {:error, Error.new(:not_found)}
    end
  end

  @impl true
  def verify(context, %ObjectRef{object_id: object_id}) do
    case :ets.lookup(context, {:object, object_id}) do
      [{{:object, ^object_id}, _object}] -> :ok
      [] -> {:error, Error.new(:not_found)}
    end
  end

  @impl true
  def delete(context, %ObjectRef{object_id: object_id}) do
    true = :ets.delete(context, {:object, object_id})
    :ok
  end

  @impl true
  def list_staged(context) do
    staged =
      context
      |> :ets.match_object({{:stage, :_}, :_})
      |> Enum.map(fn {{:stage, stage_id}, _stage} -> %StageRef{stage_id: stage_id} end)

    {:ok, staged}
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end

defmodule Singularity.Core.ObjectStorageContractNoOpAdapter do
  @moduledoc false

  @behaviour Singularity.Core.ObjectStorage

  alias Singularity.Core.ObjectRef
  alias Singularity.Core.StageRef

  def new_context, do: :no_state

  @impl true
  def stage(_context, _options), do: {:ok, %StageRef{stage_id: "no-op-stage"}}

  @impl true
  def append_encrypted_chunk(_context, _stage_ref, _chunk), do: :ok

  @impl true
  def seal_stage(_context, _stage_ref, _metadata), do: {:ok, %{}}

  @impl true
  def stat_stage(_context, _stage_ref), do: {:ok, %{}}

  @impl true
  def finalize(_context, _stage_ref, object_ref), do: {:ok, object_ref}

  @impl true
  def abort_stage(_context, _stage_ref), do: :ok

  @impl true
  def stat(_context, %ObjectRef{}), do: {:ok, %{}}

  @impl true
  def open(_context, %ObjectRef{}), do: {:ok, :no_op_handle}

  @impl true
  def read_range(_context, _handle, _range), do: {:ok, ""}

  @impl true
  def verify(_context, %ObjectRef{}), do: :ok

  @impl true
  def delete(_context, %ObjectRef{}), do: :ok

  @impl true
  def list_staged(_context), do: {:ok, []}
end

defmodule Singularity.Core.ObjectStorageGeneratedContractTest do
  use Singularity.Core.ObjectStorageContract,
    adapter: Singularity.Core.ObjectStorageContractMemoryAdapter,
    context: fn -> Singularity.Core.ObjectStorageContractMemoryAdapter.new_context() end
end

defmodule Singularity.Core.ObjectStorageContractTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.ObjectStorageContract
  alias Singularity.Core.ObjectStorageContractNoOpAdapter

  test "the exact public module exports the __using__/1 macro" do
    assert macro_exported?(ObjectStorageContract, :__using__, 1)
  end

  test "using the contract requires a context factory" do
    source = """
    defmodule Singularity.Core.ObjectStorageMissingContextContractTest do
      use Singularity.Core.ObjectStorageContract,
        adapter: Singularity.Core.ObjectStorageContractNoOpAdapter
    end
    """

    assert_raise KeyError, ~r/key :context not found/, fn ->
      Code.compile_string(source)
    end

    assert_raise ArgumentError, ~r/context must be a zero-arity function/, fn ->
      ObjectStorageContract.fresh_context!(%{})
    end
  end

  test "an export-only adapter cannot satisfy the behavioral contract" do
    assert_raise ExUnit.AssertionError, fn ->
      ObjectStorageContract.assert_stage_listed!(
        ObjectStorageContractNoOpAdapter,
        ObjectStorageContractNoOpAdapter.new_context()
      )
    end
  end
end
