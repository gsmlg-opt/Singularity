defmodule Singularity.Fixtures do
  @moduledoc "Direct-insert fixtures that bypass context validation."

  alias Singularity.Collection.FetchRun
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
end
