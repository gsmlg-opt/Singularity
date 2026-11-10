defmodule Singularity.SourcesTest do
  use Singularity.DataCase, async: true

  import Singularity.Fixtures

  alias Singularity.Sources
  alias Singularity.Sources.Source

  @now ~U[2026-11-09 08:00:00Z]

  describe "source types" do
    test "list_source_types/0 describes every registered type for forms" do
      types = Sources.list_source_types()

      assert %{kind: "fake", label: "Fake", fields: [%{name: :topic}]} =
               Enum.find(types, &(&1.kind == "fake"))

      assert Enum.any?(types, &(&1.kind == "github_trending"))
    end

    test "fetch_source_type/1 returns the type or :error" do
      assert {:ok, %{kind: "fake", label: "Fake"}} = Sources.fetch_source_type("fake")
      assert :error = Sources.fetch_source_type("nope")
    end

    test "new_source/1 builds an unsaved source of the given type" do
      assert %Source{id: nil, kind: "fake", config: %{}} = Sources.new_source("fake")
    end
  end

  describe "create_source/2" do
    test "applies the collector's default interval, normalized config and immediate schedule" do
      assert {:ok, %Source{} = source} =
               Sources.create_source(
                 %{"kind" => "fake", "name" => "F", "config" => %{"topic" => "x"}},
                 @now
               )

      assert source.interval_minutes == 60
      assert source.config == %{"topic" => "x"}
      assert source.next_run_at == @now
      assert source.enabled
    end

    test "rejects invalid config via the collector" do
      assert {:error, changeset} =
               Sources.create_source(%{"kind" => "fake", "name" => "F", "config" => %{}}, @now)

      assert %{config: ["topic can't be blank"]} = errors_on(changeset)
    end

    test "rejects unregistered kinds" do
      assert {:error, changeset} = Sources.create_source(%{"kind" => "nope", "name" => "F"}, @now)
      assert %{kind: ["is not a registered source type"]} = errors_on(changeset)
    end

    test "rejects intervals under five minutes" do
      attrs = %{
        "kind" => "fake",
        "name" => "F",
        "config" => %{"topic" => "x"},
        "interval_minutes" => "1"
      }

      assert {:error, changeset} = Sources.create_source(attrs, @now)
      assert %{interval_minutes: [_]} = errors_on(changeset)
    end
  end

  test "update_source/2 and set_enabled/2" do
    source = source_fixture()
    assert {:ok, source} = Sources.update_source(source, %{"name" => "Renamed"})
    assert source.name == "Renamed"
    assert {:ok, %Source{enabled: false}} = Sources.set_enabled(source, false)
  end

  describe "claim_due_sources/1" do
    test "returns due enabled sources of registered kinds and advances them" do
      due = source_fixture(next_run_at: ~U[2026-11-09 07:00:00Z])
      _future = source_fixture(next_run_at: ~U[2026-11-09 09:00:00Z])
      _disabled = source_fixture(enabled: false, next_run_at: ~U[2026-11-09 07:00:00Z])
      _gone = source_fixture(kind: "gone", next_run_at: ~U[2026-11-09 07:00:00Z])

      assert [claimed] = Sources.claim_due_sources(@now)
      assert claimed.id == due.id
      assert claimed.next_run_at == ~U[2026-11-09 09:00:00Z]
      assert Sources.claim_due_sources(@now) == []
    end
  end

  test "ensure_default_source/1 creates the GitHub Trending default only once" do
    assert {:ok, %Source{kind: "github_trending"}} = Sources.ensure_default_source(@now)
    assert {:ok, :exists} = Sources.ensure_default_source(@now)
    assert length(Sources.list_sources()) == 1
  end
end
