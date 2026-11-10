defmodule Singularity.Collectors.GithubTrendingTest do
  use ExUnit.Case, async: true

  alias Singularity.Collector.{Entry, Result}
  alias Singularity.Collectors.GithubTrending

  defp fixture(name),
    do: Path.join([__DIR__, "../../fixtures/github_trending", name]) |> File.read!()

  describe "parse/2" do
    test "extracts entries, ranks by page position and counts broken rows" do
      {entries, skipped} = GithubTrending.parse(fixture("minimal.html"), "daily")

      assert skipped == 1
      assert [%Entry{} = rocket, %Entry{} = tool] = entries

      assert rocket.external_id == "github.com/acme/rocket"
      assert rocket.title == "acme/rocket"
      assert rocket.url == "https://github.com/acme/rocket"
      assert rocket.summary == "A fast rocket engine"
      assert rocket.rank == 1
      assert rocket.item_kind == "software_project"
      assert rocket.item_attributes == %{"language" => "Rust", "stars" => 12_345, "forks" => 678}

      assert rocket.observation_attributes == %{
               "stars" => 12_345,
               "forks" => 678,
               "stars_in_period" => 1_234,
               "since" => "daily"
             }

      assert tool.rank == 3
      assert tool.summary == nil
      assert tool.item_attributes["language"] == nil
      assert tool.observation_attributes["stars_in_period"] == 7
    end

    test "returns no entries for pages without trending rows" do
      assert {[], 0} = GithubTrending.parse("<html><body><p>nothing</p></body></html>", "daily")
    end

    test "parses a captured real trending page" do
      html = fixture("daily.html")
      {:ok, doc} = Floki.parse_document(html)
      row_count = doc |> Floki.find("article.Box-row") |> length()

      {entries, skipped} = GithubTrending.parse(html, "daily")

      assert row_count > 0
      assert skipped == 0
      assert Enum.map(entries, & &1.rank) == Enum.to_list(1..row_count)

      for entry <- entries do
        assert entry.external_id =~ ~r{^github\.com/[a-z0-9-]+/[a-z0-9._-]+$}
        assert entry.item_kind == "software_project"
        assert is_integer(entry.item_attributes["stars"])
        assert is_integer(entry.observation_attributes["stars_in_period"])
      end
    end
  end

  describe "validate_config/1" do
    test "normalizes valid config" do
      assert {:ok, %{"language" => "elixir", "since" => "weekly"}} =
               GithubTrending.validate_config(%{"language" => " Elixir ", "since" => "weekly"})

      assert {:ok, %{"language" => "", "since" => "daily"}} = GithubTrending.validate_config(%{})
    end

    test "rejects bad values" do
      assert {:error, errors} =
               GithubTrending.validate_config(%{"language" => "a/b", "since" => "yearly"})

      assert Keyword.has_key?(errors, :language)
      assert Keyword.has_key?(errors, :since)
    end
  end

  describe "fetch/2" do
    setup do
      HTTP.Test.verify_on_exit!()
    end

    test "requests the language page and returns a dated result" do
      HTTP.Test.expect(GithubTrending, fn request ->
        assert request.url.path == "/trending/c%2B%2B"
        assert request.url.query == "since=weekly"
        assert HTTP.Headers.get(request.headers, "user-agent") == "Singularity"
        HTTP.Test.html(fixture("minimal.html"))
      end)

      assert {:ok, %Result{period: "2026-11-09", entries: [_, _], skipped: 1}} =
               GithubTrending.fetch(
                 %{"language" => "c++", "since" => "weekly"},
                 ~U[2026-11-09 23:30:00Z]
               )
    end

    test "requests the all-languages page when language is blank" do
      HTTP.Test.expect(GithubTrending, fn request ->
        assert request.url.path == "/trending"
        HTTP.Test.html(fixture("minimal.html"))
      end)

      assert {:ok, _} =
               GithubTrending.fetch(
                 %{"language" => "", "since" => "daily"},
                 ~U[2026-11-09 00:00:00Z]
               )
    end

    test "maps non-200 responses to errors" do
      HTTP.Test.expect(GithubTrending, fn _request -> HTTP.Test.text("slow down", 429) end)

      assert {:error, {:http_status, 429}} =
               GithubTrending.fetch(
                 %{"language" => "", "since" => "daily"},
                 ~U[2026-11-09 00:00:00Z]
               )
    end

    test "maps transport failures to errors instead of raising" do
      HTTP.Test.expect(GithubTrending, fn _request -> HTTP.Test.transport_error(:econnrefused) end)

      assert {:error, {:transport, "econnrefused"}} =
               GithubTrending.fetch(
                 %{"language" => "", "since" => "daily"},
                 ~U[2026-11-09 00:00:00Z]
               )
    end
  end
end
