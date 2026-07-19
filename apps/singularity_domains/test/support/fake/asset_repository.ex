defmodule Fake.AssetRepository do
  use Agent

  @behaviour Singularity.Domains.Assets.Repository

  alias Singularity.Core.Asset
  alias Singularity.Core.AssetState
  alias Singularity.Core.Error

  def start_link(_opts) do
    Agent.start_link(fn ->
      %{
        assets: %{},
        calls: [],
        audit: [],
        outbox: [],
        ordering: []
      }
    end)
  end

  @impl true
  def create_upload_grant(context, intent) do
    Agent.get_and_update(repository(context), fn state ->
      state = %{state | calls: [{:create_upload_grant, intent} | state.calls]}

      {{:ok, intent}, state}
    end)
  end

  @impl true
  def create_upload_intent(context, intent) do
    Agent.get_and_update(repository(context), fn state ->
      state = %{
        state
        | assets: Map.put(state.assets, intent.asset.asset_id, intent.asset),
          calls: [{:create_upload_intent, intent} | state.calls]
      }

      {{:ok, intent}, state}
    end)
  end

  @impl true
  def consume_upload_grant(context, intent) do
    Agent.get_and_update(repository(context), fn state ->
      state = %{state | calls: [{:consume_upload_grant, intent} | state.calls]}

      {{:ok, intent}, state}
    end)
  end

  @impl true
  def consume_grant_and_create_stage(context, intent) do
    Agent.get_and_update(repository(context), fn state ->
      state = %{
        state
        | calls: [{:consume_grant_and_create_stage, intent} | state.calls]
      }

      {{:ok, intent}, state}
    end)
  end

  @impl true
  def mark_stage_abandoned(context, intent) do
    Agent.get_and_update(repository(context), fn state ->
      state = %{
        state
        | calls: [{:mark_stage_abandoned, intent} | state.calls]
      }

      {{:ok, intent}, state}
    end)
  end

  @impl true
  def record_sealed_stage(context, intent) do
    Agent.get_and_update(repository(context), fn state ->
      case persisted_asset(intent.asset) do
        {:ok, asset} ->
          persisted_intent = %{intent | asset: asset}

          state = %{
            state
            | assets: Map.put(state.assets, asset.asset_id, asset),
              calls: [{:record_sealed_stage, persisted_intent} | state.calls],
              audit: [intent.audit | state.audit],
              outbox: [intent.outbox | state.outbox]
          }

          {{:ok, persisted_intent}, state}

        {:error, %Error{}} = error ->
          {error, state}
      end
    end)
  end

  @impl true
  def prepare_verification(context, intent) do
    Agent.get_and_update(repository(context), fn state ->
      state = %{
        state
        | calls: [{:prepare_verification, intent} | state.calls]
      }

      {{:ok, intent}, state}
    end)
  end

  @impl true
  def record_verified_stage(context, intent) do
    Agent.get_and_update(repository(context), fn state ->
      state = %{
        state
        | calls: [{:record_verified_stage, intent} | state.calls]
      }

      {{:ok, intent}, state}
    end)
  end

  @impl true
  def resolve_finalization(context, intent) do
    record_passthrough(context, :resolve_finalization, intent)
  end

  @impl true
  def reserve_finalization(context, intent) do
    record_passthrough(context, :reserve_finalization, intent)
  end

  @impl true
  def acknowledge_finalization(context, intent) do
    record_passthrough(context, :acknowledge_finalization, intent)
  end

  @impl true
  def record_job_failure(context, intent, error) do
    record_passthrough(
      context,
      :record_job_failure,
      %{intent: intent, error: error}
    )
  end

  @impl true
  def transition(context, intent) do
    Agent.get_and_update(repository(context), fn state ->
      case Map.get(state.assets, intent.asset_id) do
        nil ->
          {{:error, Error.new(:not_found)}, state}

        %{classification: classification} when classification != intent.classification ->
          {{:error, Error.new(:forbidden)}, state}

        %{state_revision: revision} = asset
        when revision != intent.expected_state_revision ->
          state = %{
            state
            | calls: [{:transition, :stale, intent} | state.calls]
          }

          {{:ok, :stale, asset}, state}

        asset ->
          case AssetState.transition(
                 asset,
                 intent.to,
                 intent.expected_state_revision
               ) do
            {:ok, transitioned} ->
              state = %{
                state
                | assets: Map.put(state.assets, intent.asset_id, transitioned),
                  calls: [{:transition, :applied, intent} | state.calls],
                  audit: [intent.audit | state.audit],
                  outbox: [intent.outbox | state.outbox]
              }

              {{:ok, :applied, transitioned}, state}

            {:error, %Error{}} = error ->
              {error, state}
          end
      end
    end)
  end

  @impl true
  def tombstone_and_release(context, intent) do
    Agent.get_and_update(repository(context), fn state ->
      case Map.get(state.assets, intent.asset_id) do
        nil ->
          {{:error, Error.new(:not_found)}, state}

        %{classification: classification} when classification != intent.classification ->
          {{:error, Error.new(:forbidden)}, state}

        asset ->
          case AssetState.transition(
                 asset,
                 :pending_delete,
                 intent.expected_state_revision
               ) do
            {:ok, tombstoned} ->
              state = %{
                state
                | assets: Map.put(state.assets, intent.asset_id, tombstoned),
                  calls: [{:tombstone_and_release, intent} | state.calls],
                  audit: [intent.audit | state.audit],
                  outbox: [intent.outbox | state.outbox],
                  ordering: [
                    {:release_outbox, intent.outbox.event_type},
                    {:tombstone, intent.asset_id}
                    | state.ordering
                  ]
              }

              {{:ok,
                %{
                  asset: tombstoned,
                  audit: intent.audit,
                  outbox: intent.outbox
                }}, state}

            {:error, %Error{}} = error ->
              {error, state}
          end
      end
    end)
  end

  def calls(context), do: Agent.get(repository(context), &Enum.reverse(&1.calls))
  def audit_entries(context), do: Agent.get(repository(context), &Enum.reverse(&1.audit))
  def outbox_entries(context), do: Agent.get(repository(context), &Enum.reverse(&1.outbox))
  def ordering(context), do: Agent.get(repository(context), &Enum.reverse(&1.ordering))

  defp record_passthrough(context, operation, intent) do
    Agent.get_and_update(repository(context), fn state ->
      state = %{
        state
        | calls: [{operation, intent} | state.calls]
      }

      {{:ok, intent}, state}
    end)
  end

  defp persisted_asset(%Asset{} = asset), do: {:ok, asset}

  defp persisted_asset(asset) do
    Asset.new(%{
      asset_id: asset.asset_id,
      vault_id: asset.vault_id,
      resource_version_id: persisted_resource_version_id(asset),
      classification: asset.classification,
      state: asset.state,
      state_revision: Map.get(asset, :state_revision, 0),
      metadata: %{
        "byte_size" => asset.byte_size,
        "checksum" => asset.checksum,
        "content_type" => asset.content_type,
        "filename" => asset.filename,
        "principal_id" => asset.principal_id,
        "sealed_ref" => asset.sealed_ref
      }
    })
  end

  defp persisted_resource_version_id(%{
         resource_version_id: nil,
         asset_id: asset_id
       }),
       do: "sealed-upload/#{asset_id}"

  defp persisted_resource_version_id(%{resource_version_id: resource_version_id}),
    do: resource_version_id

  defp repository(%{repository: repository}), do: repository
  defp repository(repository) when is_pid(repository), do: repository
end
