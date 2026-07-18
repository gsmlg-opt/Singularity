defmodule Singularity.Core.JobEnvelopeTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.JobEnvelope

  @required_fields ~w[
    version job_id job_type idempotency_key vault_id principal_id
    required_capability authorization_epoch classification correlation_id
    causation_id expected_entity_revision attempt payload
  ]a

  test "required fields are stable and complete" do
    assert JobEnvelope.required_fields() == @required_fields
  end

  test "constructs a versioned envelope and normalizes stable string keys" do
    assert {:ok,
            %JobEnvelope{
              version: 1,
              job_id: "job-1",
              job_type: "asset_verify",
              idempotency_key: "asset-1:verify:7",
              vault_id: "vault-1",
              principal_id: "principal-1",
              required_capability: "asset:verify",
              authorization_epoch: 2,
              classification: :private,
              correlation_id: "correlation-1",
              causation_id: "outbox-1",
              expected_entity_revision: 7,
              attempt: 0,
              payload: %{"asset_id" => "asset-1"}
            }} = JobEnvelope.new(valid_envelope())
  end

  test "rejects every missing required authority and concurrency field" do
    for field <- [
          :principal_id,
          :vault_id,
          :required_capability,
          :classification,
          :authorization_epoch,
          :expected_entity_revision,
          :correlation_id
        ] do
      assert {:error, %{code: :invalid}} =
               valid_envelope()
               |> Map.delete(field)
               |> JobEnvelope.new()
    end
  end

  test "rejects missing causation and identity fields from the exact required inventory" do
    for field <- @required_fields -- [:payload] do
      assert {:error, %{code: :invalid}} =
               valid_envelope()
               |> Map.delete(field)
               |> JobEnvelope.new()
    end
  end

  test "rejects non-string payload keys" do
    assert {:error, %{code: :invalid}} =
             JobEnvelope.new(valid_envelope(payload: %{asset_id: "asset-1"}))
  end

  test "rejects blank normalized keys and negative epochs, revisions, or attempts" do
    for overrides <- [
          [idempotency_key: " \t "],
          [required_capability: "  "],
          [authorization_epoch: -1],
          [expected_entity_revision: -1],
          [attempt: -1]
        ] do
      assert {:error, %{code: :invalid}} =
               JobEnvelope.new(valid_envelope(overrides))
    end
  end

  defp valid_envelope(overrides \\ []) do
    Map.merge(
      %{
        version: 1,
        job_id: "job-1",
        job_type: "asset_verify",
        idempotency_key: " asset-1:verify:7 ",
        vault_id: "vault-1",
        principal_id: "principal-1",
        required_capability: " asset:verify ",
        authorization_epoch: 2,
        classification: :private,
        correlation_id: "correlation-1",
        causation_id: "outbox-1",
        expected_entity_revision: 7,
        attempt: 0,
        payload: %{"asset_id" => "asset-1"}
      },
      Map.new(overrides)
    )
  end
end
