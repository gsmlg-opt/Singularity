defmodule Singularity.Fixtures do
  @moduledoc "Direct-insert fixtures that bypass context validation."

  alias Singularity.Collection.FetchRun
  alias Singularity.Knowledge.{Item, Label, Observation}
  alias Singularity.Repo
  alias Singularity.Sources.Source

  def now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  def source_fixture(attrs \\ %{}) do
    defaults = %{
      kind: "fake",
      name: "Fake source",
      config: %{"topic" => "t"},
      enabled: true,
      interval_minutes: 60,
      next_run_at: now()
    }

    Source |> struct!(Map.merge(defaults, Map.new(attrs))) |> Repo.insert!()
  end

  def fetch_run_fixture(%Source{} = source, attrs \\ %{}) do
    defaults = %{
      source_id: source.id,
      status: "ok",
      item_count: 1,
      started_at: now(),
      finished_at: now()
    }

    FetchRun |> struct!(Map.merge(defaults, Map.new(attrs))) |> Repo.insert!()
  end

  def project_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    title = Map.get(attrs, :title, "acme/project-#{System.unique_integer([:positive])}")

    defaults = %{
      kind: "software_project",
      external_id: "github.com/" <> String.downcase(title),
      title: title,
      url: "https://github.com/" <> title,
      attributes: %{},
      first_seen_at: now(),
      last_seen_at: now()
    }

    Item |> struct!(Map.merge(defaults, attrs)) |> Repo.insert!()
  end

  def label_fixture(%Item{} = item, name, origin \\ "auto"),
    do: Repo.insert!(%Label{item_id: item.id, name: name, origin: origin})

  def observation_fixture(%Item{} = item, source, attrs \\ %{}) do
    defaults = %{
      item_id: item.id,
      source_id: source && source.id,
      period: "2026-11-11",
      observed_at: now(),
      attributes: %{}
    }

    Observation |> struct!(Map.merge(defaults, Map.new(attrs))) |> Repo.insert!()
  end
end
