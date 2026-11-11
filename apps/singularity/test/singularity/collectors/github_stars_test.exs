defmodule Singularity.Collectors.GithubStarsTest do
  use Singularity.DataCase, async: true

  alias Singularity.Collector.{Entry, Result}
  alias Singularity.Collectors.GithubStars
  alias Singularity.GitHub

  @fixture Path.join([__DIR__, "../../fixtures/github_api/starred.json"])
  @now ~U[2026-11-11 08:00:00Z]

  defp stars, do: @fixture |> File.read!() |> JSON.decode!()

  describe "parse/2" do
    test "turns real starred elements into entries with details" do
      assert {[first, second], 0} = GithubStars.parse(stars(), "gsmlg")

      assert %Entry{
               item_kind: "software_project",
               external_id: "github.com/xberg-io/xberg",
               title: "xberg-io/xberg",
               url: "https://github.com/xberg-io/xberg",
               period: "2026-11-06",
               rank: nil,
               observation_attributes: %{
                 "user" => "gsmlg",
                 "starred_at" => "2026-11-06T19:49:14Z"
               },
               raw: %{"full_name" => "xberg-io/xberg", "starred_at" => "2026-11-06T19:49:14Z"}
             } = first

      assert %{title: "xberg-io/xberg", attributes: %{"language" => "Rust", "license" => "MIT"}} =
               first.details

      assert first.item_attributes == first.details.attributes
      assert second.external_id == "github.com/morluto/rea"
      assert second.period == "2026-10-13"
    end

    test "an empty list has no entries" do
      assert {[], 0} = GithubStars.parse([], "gsmlg")
    end

    test "skips a broken element and keeps the rest" do
      [first, second] = stars()
      broken = Map.update!(second, "repo", &Map.delete(&1, "full_name"))
      bad_date = Map.put(first, "starred_at", "yesterday")

      assert {[%Entry{title: "xberg-io/xberg"}], 3} =
               GithubStars.parse([first, broken, bad_date, "nonsense"], "gsmlg")
    end
  end

  describe "validate_config/1" do
    test "requires a GitHub user name" do
      assert {:ok, %{"user" => "gsmlg"}} = GithubStars.validate_config(%{"user" => " gsmlg "})
      assert {:error, [user: "can't be blank"]} = GithubStars.validate_config(%{})

      assert {:error, [user: "is not a GitHub user name"]} =
               GithubStars.validate_config(%{"user" => "no/slash"})
    end
  end

  describe "fetch/2" do
    setup do
      HTTP.Test.verify_on_exit!()
    end

    defp page(n, count) do
      [element | _] = stars()

      for i <- 1..count//1 do
        put_in(element, ["repo", "full_name"], "acme/repo-#{n}-#{i}")
      end
    end

    test "reads every page until a short one and returns the complete list" do
      HTTP.Test.expect(GitHub, 3, fn request ->
        assert request.url.path == "/users/gsmlg/starred"
        assert HTTP.Headers.get(request.headers, "accept") == "application/vnd.github.star+json"
        query = URI.decode_query(request.url.query)
        assert query["per_page"] == "100"

        count = %{"1" => 100, "2" => 100, "3" => 2}[query["page"]]
        HTTP.Test.response(200, JSON.encode!(page(query["page"], count)))
      end)

      assert {:ok, %Result{period: "2026-11-11", complete: true, skipped: 0, entries: entries}} =
               GithubStars.fetch(%{"user" => "gsmlg"}, @now)

      assert length(entries) == 202
      assert hd(entries).external_id == "github.com/acme/repo-1-1"
    end

    test "a user without stars gives an empty complete list" do
      HTTP.Test.expect(GitHub, fn _request -> HTTP.Test.response(200, "[]") end)

      assert {:ok, %Result{entries: [], complete: true}} =
               GithubStars.fetch(%{"user" => "gsmlg"}, @now)
    end

    test "fails as a whole when a later page fails" do
      HTTP.Test.expect(GitHub, 2, fn request ->
        case URI.decode_query(request.url.query)["page"] do
          "1" -> HTTP.Test.response(200, JSON.encode!(page(1, 100)))
          "2" -> HTTP.Test.status(500)
        end
      end)

      assert {:error, {:http_status, 500}} = GithubStars.fetch(%{"user" => "gsmlg"}, @now)
    end

    test "maps an unknown user and rate limits" do
      HTTP.Test.expect(GitHub, fn _request -> HTTP.Test.status(404) end)
      assert {:error, :not_found} = GithubStars.fetch(%{"user" => "nobody"}, @now)

      HTTP.Test.expect(GitHub, fn _request ->
        HTTP.Test.status(429) |> HTTP.Test.headers([{"retry-after", "60"}])
      end)

      assert {:error, {:rate_limited, 60}} = GithubStars.fetch(%{"user" => "gsmlg"}, @now)
    end
  end
end
