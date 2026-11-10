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

  describe "ensure_default_sources/1" do
    test "creates a daily GitHub Trending source for all languages and each common language" do
      assert {:ok, created} = Sources.ensure_default_sources(@now)

      sources = Sources.list_sources()
      assert created == length(sources)
      assert Enum.all?(sources, &(&1.kind == "github_trending" and &1.config["since"] == "daily"))

      languages = Enum.map(sources, & &1.config["language"])
      assert "" in languages

      assert Enum.all?(
               ["elixir", "rust", "go", "python", "typescript", "c++", "c#"],
               &(&1 in languages)
             )

      assert Enum.find(sources, &(&1.config["language"] == "")).name ==
               "GitHub Trending · All languages · daily"

      assert Enum.find(sources, &(&1.config["language"] == "c++")).name ==
               "GitHub Trending · C++ · daily"
    end

    test "is idempotent" do
      {:ok, _created} = Sources.ensure_default_sources(@now)
      count = length(Sources.list_sources())

      assert {:ok, 0} = Sources.ensure_default_sources(@now)
      assert length(Sources.list_sources()) == count
    end

    test "does not duplicate an existing source with the same language and range" do
      {:ok, existing} =
        Sources.create_source(
          %{"kind" => "github_trending", "name" => "Mine", "config" => %{"language" => "rust"}},
          @now
        )

      {:ok, _created} = Sources.ensure_default_sources(@now)

      assert [%Source{id: id}] =
               Enum.filter(Sources.list_sources(), &(&1.config["language"] == "rust"))

      assert id == existing.id
    end

    test "does not recreate a default source the user deleted" do
      {:ok, _created} = Sources.ensure_default_sources(@now)
      elixir = Enum.find(Sources.list_sources(), &(&1.config["language"] == "elixir"))
      {:ok, _deleted} = Sources.delete_source(elixir)

      assert {:ok, 0} = Sources.ensure_default_sources(@now)
      refute Enum.any?(Sources.list_sources(), &(&1.config["language"] == "elixir"))
    end
  end
end
