defmodule Singularity.Runtime.AssetEventsTest do
  use ExUnit.Case, async: false

  alias Singularity.Core.Error
  alias Singularity.Runtime.AssetEvents

  @registry __MODULE__.Registry
  @vault_id "00000000-0000-4000-8000-000000000701"
  @other_vault_id "00000000-0000-4000-8000-000000000702"
  @asset_id "00000000-0000-4000-8000-000000000703"

  setup do
    start_supervised!({Registry, keys: :duplicate, name: @registry})
    tasks = start_supervised!({Task.Supervisor, name: nil})

    {:ok, tasks: tasks}
  end

  test "duplicate-key subscribers receive only the exact vault-scoped safe signal", %{
    tasks: tasks
  } do
    subscribers =
      for _index <- 1..2 do
        start_subscriber(tasks, @vault_id)
      end

    other_subscriber = start_subscriber(tasks, @other_vault_id)

    assert :ok = AssetEvents.publish(@registry, @vault_id, @asset_id)

    for subscriber <- subscribers do
      assert_receive {:subscriber_message, ^subscriber,
                      {:asset_changed, %{vault_id: @vault_id, asset_id: @asset_id}}}
    end

    refute_receive {:subscriber_message, ^other_subscriber, _message}
  end

  test "subscription validates the vault identifier before registry work" do
    assert {:error, %Error{code: :invalid}} =
             AssetEvents.subscribe(@registry, "not-a-uuid")

    assert Registry.lookup(@registry, "not-a-uuid") == []
  end

  test "repeated subscription by one process and vault delivers one signal" do
    assert :ok = AssetEvents.subscribe(@registry, @vault_id)
    assert :ok = AssetEvents.subscribe(@registry, @vault_id)

    assert :ok = AssetEvents.publish(@registry, @vault_id, @asset_id)

    assert_receive {:asset_changed, %{vault_id: @vault_id, asset_id: @asset_id}}
    refute_receive {:asset_changed, %{vault_id: @vault_id, asset_id: @asset_id}}
  end

  test "publication drops invalid identifiers and registry failures best-effort" do
    assert :ok = AssetEvents.subscribe(@registry, @vault_id)

    assert {:error, %Error{code: :storage_unavailable, retryable?: true}} =
             AssetEvents.subscribe(
               Singularity.Runtime.AssetEventsTest.UnavailableRegistry,
               @vault_id
             )

    assert :ok = AssetEvents.publish(@registry, @vault_id, "not-a-uuid")
    refute_receive {:asset_changed, _signal}

    assert :ok =
             AssetEvents.publish(
               Singularity.Runtime.AssetEventsTest.UnavailableRegistry,
               @vault_id,
               @asset_id
             )
  end

  defp start_subscriber(tasks, vault_id) do
    owner = self()

    {:ok, pid} =
      Task.Supervisor.start_child(tasks, fn ->
        assert :ok = AssetEvents.subscribe(@registry, vault_id)
        send(owner, {:subscriber_ready, self()})

        receive do
          message -> send(owner, {:subscriber_message, self(), message})
        end
      end)

    assert_receive {:subscriber_ready, ^pid}
    pid
  end
end
