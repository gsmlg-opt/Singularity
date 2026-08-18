defmodule Singularity.Runtime.JobDispatcherNoteProjectionTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope
  alias Singularity.Runtime.JobDispatcher

  @job_id "00000000-0000-4000-8000-000000002001"
  @vault_id "00000000-0000-4000-8000-000000002002"
  @principal_id "00000000-0000-4000-8000-000000002003"
  @resource_id "00000000-0000-4000-8000-000000002004"
  @correlation_id "00000000-0000-4000-8000-000000002005"
  @causation_id "00000000-0000-4000-8000-000000002006"

  defmodule Authorize do
    def check_job(owner, authorization, repo, envelope) do
      send(owner, {:authorize, authorization, repo, envelope})
      Process.get(:note_projection_authorization, :ok)
    end
  end

  defmodule Projection do
    def reconcile(owner, repo, selector) do
      send(owner, {:reconcile, repo, selector})
      Process.get(:note_projection_result, :ok)
    end
  end

  setup do
    on_exit(fn ->
      Process.delete(:note_projection_authorization)
      Process.delete(:note_projection_result)
    end)
  end

  test "authorizes live job authority before reconciling only canonical identity" do
    envelope = envelope()

    assert :ok = JobDispatcher.handle(context(), envelope)

    assert_receive {:transact, [], callback}
    assert is_function(callback, 1)

    assert_receive {:authorize, :authorization, :worker_repo, ^envelope}

    assert_receive {:reconcile, :worker_repo, %{vault_id: @vault_id, resource_id: @resource_id}}

    refute_received {:reconcile, _repo, %{title: _title}}
    refute_received {:reconcile, _repo, %{markdown: _markdown}}
  end

  test "live revocation or epoch denial prevents reconciliation" do
    Process.put(:note_projection_authorization, {:error, Error.new(:forbidden)})

    assert {:error, %Error{code: :forbidden}} =
             JobDispatcher.handle(context(), envelope())

    assert_receive {:authorize, :authorization, :worker_repo, _envelope}
    refute_received {:reconcile, _repo, _selector}
  end

  test "rejects extra payload content and malformed authority before transaction work" do
    for invalid <- [
          %{envelope() | payload: %{"resource_id" => @resource_id, "markdown" => "secret"}},
          %{envelope() | required_capability: "note.read"},
          %{envelope() | classification: :sensitive},
          %{envelope() | vault_id: "not-a-uuid"},
          %{envelope() | payload: %{"resource_id" => "not-a-uuid"}}
        ] do
      assert {:error, %Error{code: :job_failed}} = JobDispatcher.handle(context(), invalid)
    end

    refute_received {:authorize, _authorization, _repo, _envelope}
    refute_received {:reconcile, _repo, _selector}
  end

  defp context do
    %{
      authorization: :authorization,
      authorize: {Authorize, self()},
      note_projection: {Projection, self()},
      note_repository: :note_repository,
      transact: fn options, callback ->
        send(self(), {:transact, options, callback})
        callback.(:worker_repo)
      end
    }
  end

  defp envelope do
    {:ok, envelope} =
      JobEnvelope.new(%{
        version: 1,
        job_id: @job_id,
        job_type: "note_projection",
        idempotency_key: "note-current-changed:#{@resource_id}:1",
        vault_id: @vault_id,
        principal_id: @principal_id,
        required_capability: "note.write",
        principal_authorization_epoch: 7,
        vault_authorization_epoch: 11,
        classification: :private,
        correlation_id: @correlation_id,
        causation_id: @causation_id,
        expected_entity_revision: 1,
        attempt: 0,
        payload: %{"resource_id" => @resource_id}
      })

    envelope
  end
end
