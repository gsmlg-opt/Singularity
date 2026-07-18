defmodule Singularity.Core.ObjectStorageContract do
  @moduledoc """
  Reusable public-behavior contract for object-storage adapters.

  Each generated test obtains isolated adapter context from the required
  zero-arity context factory.
  """

  import ExUnit.Assertions

  alias Singularity.Core.Error
  alias Singularity.Core.ObjectRef
  alias Singularity.Core.StageRef

  @callbacks [
    abort_stage: 2,
    append_encrypted_chunk: 3,
    delete: 2,
    finalize: 3,
    list_staged: 1,
    open: 2,
    read_range: 3,
    seal_stage: 3,
    stage: 2,
    stat: 2,
    stat_stage: 2,
    verify: 2
  ]

  @payload "encrypted-contract-payload"
  @read_range 4..11

  defmacro __using__(options) do
    adapter = options |> Keyword.fetch!(:adapter) |> Macro.expand(__CALLER__)
    context_factory = Keyword.fetch!(options, :context)

    quote do
      use ExUnit.Case, async: true

      @adapter unquote(adapter)

      defp object_storage_contract_context do
        Singularity.Core.ObjectStorageContract.fresh_context!(unquote(context_factory))
      end

      test "#{inspect(@adapter)} implements the complete object-storage port" do
        _context = object_storage_contract_context()

        Singularity.Core.ObjectStorageContract.assert_callback_inventory!(
          @adapter,
          unquote(@callbacks)
        )
      end

      test "a staged reference appears in list_staged" do
        Singularity.Core.ObjectStorageContract.assert_stage_listed!(
          @adapter,
          object_storage_contract_context()
        )
      end

      test "encrypted chunks can be appended, sealed, and inspected" do
        Singularity.Core.ObjectStorageContract.assert_stage_sealed!(
          @adapter,
          object_storage_contract_context()
        )
      end

      test "a finalized object can be inspected, opened, ranged, and verified" do
        Singularity.Core.ObjectStorageContract.assert_finalized_object!(
          @adapter,
          object_storage_contract_context()
        )
      end

      test "aborting a stage removes it from staged listings" do
        Singularity.Core.ObjectStorageContract.assert_stage_aborted!(
          @adapter,
          object_storage_contract_context()
        )
      end

      test "deleting a finalized object makes it unavailable" do
        Singularity.Core.ObjectStorageContract.assert_object_deleted!(
          @adapter,
          object_storage_contract_context()
        )
      end

      test "separate contexts do not expose each other's staged references" do
        Singularity.Core.ObjectStorageContract.assert_context_isolation!(
          @adapter,
          object_storage_contract_context(),
          object_storage_contract_context()
        )
      end
    end
  end

  @doc false
  @spec fresh_context!((-> term())) :: term()
  def fresh_context!(factory) when is_function(factory, 0), do: factory.()

  def fresh_context!(_factory) do
    raise ArgumentError, "object storage contract context must be a zero-arity function"
  end

  @doc false
  @spec assert_callback_inventory!(module(), keyword(non_neg_integer())) :: :ok
  def assert_callback_inventory!(adapter, callbacks) do
    assert Enum.sort(Singularity.Core.ObjectStorage.behaviour_info(:callbacks)) ==
             Enum.sort(callbacks)

    for {name, arity} <- callbacks do
      assert function_exported?(adapter, name, arity),
             "#{inspect(adapter)} must export #{name}/#{arity}"
    end

    :ok
  end

  @doc false
  @spec assert_stage_listed!(module(), term()) :: :ok
  def assert_stage_listed!(adapter, context) do
    assert {:ok, %StageRef{} = stage_ref} =
             adapter.stage(context, %{"contract" => "stage-list"})

    assert {:ok, staged_refs} = adapter.list_staged(context)
    assert stage_ref in staged_refs
    :ok
  end

  @doc false
  @spec assert_stage_sealed!(module(), term()) :: :ok
  def assert_stage_sealed!(adapter, context) do
    assert {:ok, %StageRef{} = stage_ref} =
             adapter.stage(context, %{"contract" => "seal"})

    assert :ok = adapter.append_encrypted_chunk(context, stage_ref, ["encrypted-", "contract-"])
    assert :ok = adapter.append_encrypted_chunk(context, stage_ref, "payload")
    assert {:ok, sealed} = adapter.seal_stage(context, stage_ref, %{"contract" => "sealed"})
    assert is_map(sealed)
    assert {:ok, staged_stat} = adapter.stat_stage(context, stage_ref)
    assert is_map(staged_stat)
    :ok
  end

  @doc false
  @spec assert_finalized_object!(module(), term()) :: :ok
  def assert_finalized_object!(adapter, context) do
    object_ref = finalize_object!(adapter, context)

    assert {:ok, object_stat} = adapter.stat(context, object_ref)
    assert is_map(object_stat)
    assert {:ok, handle} = adapter.open(context, object_ref)

    expected =
      binary_part(
        @payload,
        @read_range.first,
        @read_range.last - @read_range.first + 1
      )

    assert {:ok, ^expected} = adapter.read_range(context, handle, @read_range)
    assert :ok = adapter.verify(context, object_ref)
    :ok
  end

  @doc false
  @spec assert_stage_aborted!(module(), term()) :: :ok
  def assert_stage_aborted!(adapter, context) do
    assert {:ok, %StageRef{} = stage_ref} =
             adapter.stage(context, %{"contract" => "abort"})

    assert :ok = adapter.abort_stage(context, stage_ref)
    assert {:ok, staged_refs} = adapter.list_staged(context)
    refute stage_ref in staged_refs
    :ok
  end

  @doc false
  @spec assert_object_deleted!(module(), term()) :: :ok
  def assert_object_deleted!(adapter, context) do
    object_ref = finalize_object!(adapter, context)

    assert :ok = adapter.delete(context, object_ref)
    assert {:error, %Error{code: :not_found}} = adapter.stat(context, object_ref)
    :ok
  end

  @doc false
  @spec assert_context_isolation!(module(), term(), term()) :: :ok
  def assert_context_isolation!(adapter, first_context, second_context) do
    assert {:ok, %StageRef{} = first_stage} =
             adapter.stage(first_context, %{"contract" => "context-isolation"})

    assert {:ok, first_staged_refs} = adapter.list_staged(first_context)
    assert first_stage in first_staged_refs
    assert {:ok, second_staged_refs} = adapter.list_staged(second_context)
    refute first_stage in second_staged_refs
    :ok
  end

  defp finalize_object!(adapter, context) do
    assert {:ok, %StageRef{} = stage_ref} =
             adapter.stage(context, %{"contract" => "finalize"})

    assert :ok = adapter.append_encrypted_chunk(context, stage_ref, @payload)
    assert {:ok, sealed} = adapter.seal_stage(context, stage_ref, %{"contract" => "sealed"})
    assert is_map(sealed)

    object_ref = %ObjectRef{object_id: unique_id("object")}
    assert {:ok, ^object_ref} = adapter.finalize(context, stage_ref, object_ref)
    object_ref
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end
