defmodule Singularity.Test.FakeCollector do
  @moduledoc """
  Test collector. By default returns one entry derived from the "topic" config.
  Override per test with `Process.put(:fake_collector_response, fn config, now -> ... end)`.
  """

  @behaviour Singularity.Collector

  alias Singularity.Collector.{Entry, Result}

  @impl true
  def kind, do: "fake"

  @impl true
  def label, do: "Fake"

  @impl true
  def config_fields,
    do: [%{name: :topic, type: :string, label: "Topic", required: true, options: []}]

  @impl true
  def default_interval_minutes, do: 60

  @impl true
  def validate_config(%{"topic" => topic}) when is_binary(topic) and topic != "",
    do: {:ok, %{"topic" => topic}}

  def validate_config(_config), do: {:error, [{:topic, "can't be blank"}]}

  @impl true
  def fetch(config, now) do
    case Process.get(:fake_collector_response) do
      nil -> {:ok, %Result{period: period(now), entries: [entry(config["topic"] <> "-1", 1)]}}
      fun when is_function(fun, 2) -> fun.(config, now)
    end
  end

  def period(now), do: now |> DateTime.to_date() |> Date.to_iso8601()

  def entry(external_id, rank) do
    %Entry{
      item_kind: "fake_item",
      external_id: external_id,
      title: "Item " <> external_id,
      url: "https://example.test/" <> external_id,
      rank: rank,
      item_attributes: %{"n" => rank},
      observation_attributes: %{"n" => rank},
      raw: %{"id" => external_id}
    }
  end
end
