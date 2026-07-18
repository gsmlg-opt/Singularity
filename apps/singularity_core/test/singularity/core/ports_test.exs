defmodule Singularity.Core.PortsTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.AssetSearchStore
  alias Singularity.Core.AuditSink
  alias Singularity.Core.Clock
  alias Singularity.Core.IdGenerator
  alias Singularity.Core.JobEnvelope
  alias Singularity.Core.JobHandler
  alias Singularity.Core.JobRunner
  alias Singularity.Core.KeyDeriver
  alias Singularity.Core.KeyWrapper
  alias Singularity.Core.ObjectStorage
  alias Singularity.Core.Outbox
  alias Singularity.Core.PasswordHasher

  @callbacks %{
    ObjectStorage => [
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
    ],
    Outbox => [acknowledge: 3, append: 2, claim: 2],
    JobRunner => [submit: 2, wake_vault: 2],
    JobHandler => [dependencies: 0, handle: 2],
    PasswordHasher => [hash: 2, verify: 3],
    KeyDeriver => [derive: 3],
    KeyWrapper => [unwrap: 3, wrap: 3],
    AuditSink => [append: 2],
    AssetSearchStore => [delete: 2, search: 2, upsert: 2],
    Clock => [utc_now: 1],
    IdGenerator => [generate: 1]
  }

  test "foundation ports expose only the fixed callback inventory" do
    for {behaviour, expected_callbacks} <- @callbacks do
      assert Enum.sort(behaviour.behaviour_info(:callbacks)) == Enum.sort(expected_callbacks)
    end
  end

  test "a job handler receives an explicit per-attempt context and versioned envelope" do
    assert {:ok, envelope} = JobEnvelope.new(valid_envelope())
    dependencies = %{authorization_store: :store, key_custodian: :custodian}
    context = %{dependencies: dependencies, attempt_ref: make_ref()}

    assert __MODULE__.InjectedHandler.dependencies() == dependencies

    assert {:ok, {^context, ^envelope}} =
             __MODULE__.InjectedHandler.handle(context, envelope)
  end

  defmodule InjectedHandler do
    @moduledoc false

    @behaviour Singularity.Core.JobHandler

    @impl true
    def dependencies, do: %{authorization_store: :store, key_custodian: :custodian}

    @impl true
    def handle(context, envelope), do: {:ok, {context, envelope}}
  end

  defp valid_envelope do
    %{
      version: 1,
      job_id: "job-1",
      job_type: "asset_verify",
      idempotency_key: "asset-1:verify:7",
      vault_id: "vault-1",
      principal_id: "principal-1",
      required_capability: "asset:verify",
      principal_authorization_epoch: 2,
      vault_authorization_epoch: 7,
      classification: :private,
      correlation_id: "correlation-1",
      causation_id: "outbox-1",
      expected_entity_revision: 7,
      attempt: 0,
      payload: %{"asset_id" => "asset-1"}
    }
  end
end
