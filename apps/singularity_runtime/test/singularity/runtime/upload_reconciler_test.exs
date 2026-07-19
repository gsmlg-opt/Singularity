defmodule Singularity.Runtime.UploadReconcilerTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Core.StageRef
  alias Singularity.Runtime.Assets.UploadReconciler

  @stage_id "00000000-0000-4000-8000-000000000501"

  defmodule Repository do
    def list_open_stages(test) do
      send(test, :listed_open_stages)

      {:ok,
       [
         %{
           stage_id: "00000000-0000-4000-8000-000000000500",
           storage_ref: "00000000-0000-4000-8000-000000000501"
         }
       ]}
    end

    def with_locked_stage(
          test,
          stage_id,
          storage_ref,
          callback
        ) do
      send(test, {:locked_stage, stage_id, storage_ref})

      callback.(%{
        stage_id: stage_id,
        storage_ref: storage_ref,
        state: :open,
        state_revision: 0,
        failure_code: nil
      })
    end

    def mark_abandoned(
          test,
          stage_id,
          storage_ref,
          abandoned_at,
          reason
        ) do
      send(
        test,
        {:marked_abandoned, stage_id, storage_ref, abandoned_at, reason}
      )

      {:ok, %{stage_id: stage_id, state: :abandoned, state_revision: 1}}
    end
  end

  defmodule Storage do
    def abort_stage(test, %StageRef{} = stage_ref) do
      send(test, {:aborted_stage, stage_ref})
      :ok
    end
  end

  defmodule FailingStorage do
    def abort_stage(test, %StageRef{} = stage_ref) do
      send(test, {:failed_abort, stage_ref})
      {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  defmodule EmptyRepository do
    def list_open_stages(_context), do: {:ok, []}
  end

  defmodule FailingRepository do
    alias Singularity.Core.Error

    def list_open_stages(_context),
      do: {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  test "aborts staged bytes before recording restart abandonment" do
    now = ~U[2026-07-19 05:00:00.000000Z]

    assert {:ok, 1} =
             UploadReconciler.run(%{
               repository: {Repository, self()},
               storage: {Storage, self()},
               clock: fn -> now end
             })

    assert_receive :listed_open_stages
    assert_receive {:locked_stage, "00000000-0000-4000-8000-000000000500", @stage_id}
    assert_receive {:aborted_stage, %StageRef{stage_id: @stage_id}}

    assert_receive {:marked_abandoned, "00000000-0000-4000-8000-000000000500", @stage_id, ^now,
                    :runtime_restarted}
  end

  test "does not acknowledge abandonment when physical cleanup must retry" do
    assert {:error, %Error{code: :storage_unavailable, retryable?: true}} =
             UploadReconciler.run(%{
               repository: {Repository, self()},
               storage: {FailingStorage, self()},
               clock: fn -> DateTime.utc_now(:microsecond) end
             })

    assert_receive :listed_open_stages
    assert_receive {:locked_stage, "00000000-0000-4000-8000-000000000500", @stage_id}
    assert_receive {:failed_abort, %StageRef{stage_id: @stage_id}}

    refute_receive {:marked_abandoned, _stage_id, _storage_ref, _abandoned_at, _reason}
  end

  test "custody fallback reconciles only the exact stage without global discovery" do
    now = ~U[2026-07-19 05:15:00.000000Z]

    assert {:ok,
            %{
              stage_id: "00000000-0000-4000-8000-000000000500",
              state: :abandoned,
              state_revision: 1
            }} =
             UploadReconciler.reconcile_stage(
               %{
                 repository: {Repository, self()},
                 storage: {Storage, self()},
                 clock: fn -> now end
               },
               %{
                 stage_id: "00000000-0000-4000-8000-000000000500",
                 storage_ref: @stage_id
               },
               :custody_revoked
             )

    refute_receive :listed_open_stages
    assert_receive {:locked_stage, "00000000-0000-4000-8000-000000000500", @stage_id}
    assert_receive {:aborted_stage, %StageRef{stage_id: @stage_id}}

    assert_receive {:marked_abandoned, "00000000-0000-4000-8000-000000000500", @stage_id, ^now,
                    :custody_revoked}
  end

  test "startup is a synchronous barrier that fails closed" do
    context = %{
      repository: {EmptyRepository, :unused},
      storage: {Storage, self()},
      clock: fn -> ~U[2026-07-19 05:00:00.000000Z] end
    }

    assert :ignore = UploadReconciler.start_link(context: context)

    assert {:error, %Error{code: :storage_unavailable, retryable?: true}} =
             UploadReconciler.start_link(
               context: %{
                 context
                 | repository: {FailingRepository, :unused}
               }
             )
  end
end
