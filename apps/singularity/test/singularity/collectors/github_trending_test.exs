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

      assert rocket.external_id == "acme/rocket"
      assert rocket.title == "acme/rocket"
      assert rocket.url == "https://github.com/acme/rocket"
      assert rocket.summary == "A fast rocket engine"
      assert rocket.rank == 1
      assert rocket.item_kind == "github_repo"
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
        assert entry.external_id =~ ~r{^[^/\s]+/[^/\s]+$}
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
    test "requests the language page and returns a dated result" do
      Req.Test.stub(GithubTrending, fn conn ->
        assert conn.request_path == "/trending/c%2B%2B"
        assert conn.query_string == "since=weekly"
        assert Plug.Conn.get_req_header(conn, "user-agent") == ["Singularity"]
        Plug.Conn.send_resp(conn, 200, fixture("minimal.html"))
      end)

      assert {:ok, %Result{period: "2026-11-09", entries: [_, _], skipped: 1}} =
               GithubTrending.fetch(
                 %{"language" => "c++", "since" => "weekly"},
                 ~U[2026-11-09 23:30:00Z]
               )
    end

    test "requests the all-languages page when language is blank" do
      Req.Test.stub(GithubTrending, fn conn ->
        assert conn.request_path == "/trending"
        Plug.Conn.send_resp(conn, 200, fixture("minimal.html"))
      end)

      assert {:ok, _} =
               GithubTrending.fetch(
                 %{"language" => "", "since" => "daily"},
                 ~U[2026-11-09 00:00:00Z]
               )
    end

    test "maps non-200 responses to errors" do
      Req.Test.stub(GithubTrending, &Plug.Conn.send_resp(&1, 429, "slow down"))

      assert {:error, {:http_status, 429}} =
               GithubTrending.fetch(
                 %{"language" => "", "since" => "daily"},
                 ~U[2026-11-09 00:00:00Z]
               )
    end

    test "maps transport failures to errors instead of raising" do
      Req.Test.stub(GithubTrending, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, {:transport, message}} =
               GithubTrending.fetch(
                 %{"language" => "", "since" => "daily"},
                 ~U[2026-11-09 00:00:00Z]
               )

      assert is_binary(message)
    end
  end
end
