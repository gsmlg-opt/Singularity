defmodule Singularity.Runtime.JobDispatcherDocumentProjectionTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.{Error, JobEnvelope}
  alias Singularity.Runtime.JobDispatcher
  alias Singularity.Storage.Jobs.GenericWorker

  @job "00000000-0000-4000-8000-000000003001"
  @owner "00000000-0000-4000-8000-000000003002"
  @principal "00000000-0000-4000-8000-000000003003"
  @resource "00000000-0000-4000-8000-000000003004"
  @version "00000000-0000-4000-8000-000000003005"
  @canary "DOCUMENT_PROJECTION_CONTENT_CANARY"

  defmodule Authorize do
    def check_job(observer, authorization, repo, envelope) do
      send(observer, {:authorize, authorization, repo, envelope})
      Process.get(:document_projection_authority, :ok)
    end
  end

  defmodule Projection do
    def reconcile_document(observer, repo, envelope) do
      send(observer, {:reconcile_document, repo, envelope})

      case Process.get(:document_projection_result, {:ok, 2}) do
        :raise -> raise "DOCUMENT_PROJECTION_CONTENT_CANARY"
        :throw -> throw("DOCUMENT_PROJECTION_CONTENT_CANARY")
        result -> result
      end
    end
  end

  test "validates and authorizes before reconciling in one existing transaction without custody" do
    envelope = envelope()
    assert :ok = JobDispatcher.handle(context(), envelope)
    assert_receive {:transact, []}
    assert_receive {:authorize, :authorization, :worker_repo, ^envelope}
    assert_receive {:reconcile_document, :worker_repo, ^envelope}
  end

  test "rejects every malformed closed-envelope field before any database work" do
    for invalid <-
          [
            %{envelope() | version: 2},
            %{envelope() | job_id: "invalid"},
            %{envelope() | principal_id: "invalid"},
            %{envelope() | vault_id: "invalid"},
            %{envelope() | correlation_id: "invalid"},
            %{envelope() | causation_id: "invalid"},
            %{envelope() | principal_authorization_epoch: -1},
            %{envelope() | vault_authorization_epoch: -1},
            %{envelope() | expected_entity_revision: -1},
            %{envelope() | expected_entity_revision: 9_223_372_036_854_775_808},
            %{envelope() | principal_authorization_epoch: 9_223_372_036_854_775_808},
            %{envelope() | vault_authorization_epoch: 9_223_372_036_854_775_808},
            %{envelope() | attempt: -1},
            %{envelope() | required_capability: "asset.write"},
            %{envelope() | classification: :sensitive},
            %{envelope() | idempotency_key: "document-projection:#{@resource}"},
            %{envelope() | payload: %{"resource_id" => @resource}},
            %{envelope() | payload: %{resource_id: @resource, resource_version_id: @version}},
            %{
              envelope()
              | payload: %{"resource_id" => @resource, "resource_version_id" => "invalid"}
            }
          ] ++
            for(
              field <- ~w(title body snippet query locator tag_labels digest),
              do: %{envelope() | payload: Map.put(envelope().payload, field, @canary)}
            ) do
      assert {:error, %Error{code: :job_failed, message: nil, details: %{}}} =
               JobDispatcher.handle(context(), invalid)
    end

    refute_received {:transact, _}
    refute_received {:authorize, _, _, _}
    refute_received {:reconcile_document, _, _}
  end

  test "denied authority prevents the projection adapter and strips error content" do
    Process.put(
      :document_projection_authority,
      {:error, Error.new(:forbidden, message: @canary, details: %{query: @canary})}
    )

    assert {:error, %Error{code: :forbidden, message: nil, details: %{}, retryable?: false}} =
             JobDispatcher.handle(context(), envelope())

    assert_receive {:authorize, _, _, _}
    refute_received {:reconcile_document, _, _}
  end

  test "adapter errors preserve only stable code and retry policy including terminal exhaustion" do
    for {code, retryable, outcome} <- [
          {:forbidden, false, :cancel},
          {:invalid, false, :cancel},
          {:storage_unavailable, true, :error}
        ] do
      failure =
        Error.new(code, message: @canary, details: %{body: @canary}, retryable?: retryable)

      Process.put(:document_projection_result, {:error, failure})

      assert {:error, %Error{code: ^code, retryable?: ^retryable, message: nil, details: %{}}} =
               result = JobDispatcher.handle(context(), envelope())

      assert {^outcome, %{code: :job_failed}} = GenericWorker.normalize_result(result)

      assert {:error, %Error{code: ^code, retryable?: ^retryable, message: nil, details: %{}}} =
               terminal =
               JobDispatcher.handle_failure(context(), envelope(), failure, %{
                 attempt: 3,
                 max_attempts: 3
               })

      assert {^outcome, %{code: :job_failed}} = GenericWorker.normalize_result(terminal)
      refute inspect(terminal) =~ @canary
    end
  end

  test "exceptions and malformed adapter values produce sanitized bounded failures" do
    for unsafe <- [:raise, :throw, {:ok, @canary}, {:error, @canary}, :ok, {:ok, -1}] do
      Process.put(:document_projection_result, unsafe)

      assert {:error, %Error{message: nil, details: %{}}} =
               result =
               JobDispatcher.handle(context(), envelope())

      refute inspect(result) =~ @canary
    end
  end

  defp context do
    %{
      authorization: :authorization,
      authorize: {Authorize, self()},
      document_projection: {Projection, self()},
      transact: fn options, callback ->
        send(self(), {:transact, options})
        callback.(:worker_repo)
      end
    }
  end

  defp envelope do
    {:ok, envelope} =
      JobEnvelope.new(%{
        version: 1,
        job_id: @job,
        job_type: "document_projection",
        idempotency_key: "document-projection:#{@job}",
        vault_id: @owner,
        principal_id: @principal,
        required_capability: "asset.read",
        principal_authorization_epoch: 7,
        vault_authorization_epoch: 11,
        classification: :private,
        correlation_id: @job,
        causation_id: @job,
        expected_entity_revision: 0,
        attempt: 0,
        payload: %{"resource_id" => @resource, "resource_version_id" => @version}
      })

    envelope
  end
end
