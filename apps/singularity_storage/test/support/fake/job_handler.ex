defmodule Singularity.Storage.Fake.JobHandler do
  @moduledoc false

  @behaviour Singularity.Core.JobHandler

  alias Ecto.Adapters.SQL
  alias Singularity.Storage.Jobs.Progress

  @impl true
  def dependencies do
    %{
      fake_dependencies:
        Application.get_env(:singularity_storage, :fake_job_dependencies, %{
          crash_after_external_effect?: false,
          external_effects: nil,
          observer: self()
        })
    }
  end

  @impl true
  def handle(
        context,
        %{
          payload: %{
            "wait_for_unlock" => true,
            "checkpoint" => checkpoint
          }
        } = envelope
      ) do
    wait_before_progress(context, envelope)

    case context.transact.([], fn repo ->
           Progress.put_state(repo, envelope, :waiting_for_unlock, %{
             checkpoint_version: 1,
             checkpoint: checkpoint
           })
         end) do
      {:ok, _progress} ->
        wait_after_progress(context, envelope)
        {:snooze, 60}

      {:error, _reason} = error ->
        error
    end
  end

  def handle(context, %{payload: %{"asset_id" => asset_id}} = envelope) do
    with {:ok, receipt} <-
           context.transact.([], fn repo ->
             send_phase(repo, context, 1)

             result =
               case SQL.query!(
                      repo,
                      """
                      UPDATE content.assets
                      SET
                        state = 'uploaded',
                        state_revision = state_revision + 1,
                        updated_at = CURRENT_TIMESTAMP
                      WHERE id = $1
                        AND vault_id = $2
                        AND state_revision = $3
                      RETURNING state_revision
                      """,
                      [
                        Ecto.UUID.dump!(asset_id),
                        Ecto.UUID.dump!(envelope.vault_id),
                        envelope.expected_entity_revision
                      ],
                      log: false
                    ) do
                 %{num_rows: 1, rows: [[revision]]} -> {:applied, revision}
                 %{num_rows: 0, rows: []} -> {:stale, envelope.expected_entity_revision}
               end

             {effect_result, entity_revision} = result

             Progress.record_effect(repo, envelope, %{
               effect_key: envelope.idempotency_key,
               result: effect_result,
               entity_revision: entity_revision
             })
           end) do
      apply_external_effect(context, envelope.idempotency_key)

      context.transact.([], fn repo ->
        send_phase(repo, context, 2)
        {:ok, receipt}
      end)
    end
  end

  def handle(context, envelope) do
    send(self(), {:job_handler_called, context, envelope})
    :ok
  end

  defp send_phase(repo, context, phase) do
    %{rows: [[principal_id, vault_id]]} =
      SQL.query!(
        repo,
        """
        SELECT
          current_setting('singularity.principal_id', true),
          current_setting('singularity.vault_id', true)
        """,
        [],
        log: false
      )

    send(
      observer(context),
      {:job_phase, phase, %{principal_id: principal_id, vault_id: vault_id}, context.repo_handle}
    )
  end

  defp apply_external_effect(
         %{fake_dependencies: %{external_effects: external_effects} = dependencies} = context,
         effect_key
       )
       when is_pid(external_effects) do
    applied? =
      Agent.get_and_update(external_effects, fn state ->
        calls = Map.update(state.calls, effect_key, 1, &(&1 + 1))

        if MapSet.member?(state.applied, effect_key) do
          {false, %{state | calls: calls}}
        else
          {true, %{state | applied: MapSet.put(state.applied, effect_key), calls: calls}}
        end
      end)

    if applied? do
      send(observer(context), {:external_effect, effect_key})
    end

    if applied? and Map.get(dependencies, :crash_after_external_effect?, false) do
      send(observer(context), {:crash_after_external_effect, effect_key})
      raise "injected worker crash after external effect"
    end

    :ok
  end

  defp apply_external_effect(context, effect_key) do
    send(observer(context), {:external_effect, effect_key})
    :ok
  end

  defp observer(context) do
    context
    |> Map.get(:fake_dependencies, %{})
    |> Map.get(:observer, self())
  end

  defp wait_before_progress(context, envelope) do
    case get_in(context, [:fake_dependencies, :pre_progress_barrier]) do
      %{observer: observer, ref: ref} ->
        send(observer, {:waiting_decision_observed, ref, self(), envelope.job_id})

        receive do
          {:release_waiting_progress, ^ref} -> :ok
        after
          5_000 -> raise "waiting pre-progress barrier timed out"
        end

      _no_barrier ->
        :ok
    end
  end

  defp wait_after_progress(context, envelope) do
    case get_in(context, [:fake_dependencies, :wait_barrier]) do
      %{observer: observer, ref: ref} ->
        send(observer, {:waiting_progress_committed, ref, self(), envelope.job_id})

        receive do
          {:release_waiting_worker, ^ref} -> :ok
        after
          5_000 -> raise "waiting progress barrier timed out"
        end

      _no_barrier ->
        :ok
    end
  end
end
