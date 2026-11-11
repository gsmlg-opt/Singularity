defmodule Singularity.GitHubTest do
  use ExUnit.Case, async: true

  alias Singularity.GitHub

  @fixture Path.join([__DIR__, "../fixtures/github_api/elixir.json"])
  @now ~U[2026-11-11 08:00:00Z]

  defp repo_json, do: @fixture |> File.read!() |> JSON.decode!()

  describe "parse_repo/1" do
    test "extracts details from a real API response" do
      assert %{title: "elixir-lang/elixir", summary: summary, attributes: attributes} =
               GitHub.parse_repo(repo_json())

      assert is_binary(summary)

      assert %{
               "language" => "Elixir",
               "license" => "Apache-2.0",
               "archived" => false,
               "created_at" => "2011-01-09T08:43:57Z",
               "default_branch" => "main"
             } = attributes

      assert is_integer(attributes["stars"]) and attributes["stars"] > 0
      assert is_integer(attributes["forks"])
      assert is_list(attributes["topics"])
      assert is_binary(attributes["homepage"])
      assert is_binary(attributes["pushed_at"])

      assert attributes |> Map.keys() |> Enum.sort() ==
               ~w(archived created_at default_branch forks homepage language license pushed_at stars topics)
    end

    test "tolerates missing fields" do
      json = Map.drop(repo_json(), ~w(description language topics license homepage archived))

      assert %{summary: nil, attributes: attributes} = GitHub.parse_repo(json)

      assert %{
               "language" => nil,
               "topics" => [],
               "license" => nil,
               "homepage" => nil,
               "archived" => false
             } = attributes
    end

    test "marks archived repositories and drops blank homepages" do
      json =
        repo_json()
        |> Map.put("archived", true)
        |> Map.put("homepage", "")
        |> Map.put("topics", ["lang", "web"])
        |> Map.put("license", %{"spdx_id" => "NOASSERTION", "name" => "Other"})

      assert %{
               attributes: %{
                 "archived" => true,
                 "homepage" => nil,
                 "topics" => ["lang", "web"],
                 "license" => "Other"
               }
             } = GitHub.parse_repo(json)
    end
  end

  describe "fetch_repo/3" do
    setup do
      HTTP.Test.verify_on_exit!()
    end

    test "requests the repository with GitHub headers and returns parsed details" do
      HTTP.Test.expect(GitHub, fn request ->
        assert request.url.host == "api.github.com"
        assert request.url.path == "/repos/elixir-lang/elixir"
        assert HTTP.Headers.get(request.headers, "accept") == "application/vnd.github+json"
        assert HTTP.Headers.get(request.headers, "user-agent") == "Singularity"
        assert HTTP.Headers.get(request.headers, "authorization") == nil
        HTTP.Test.response(200, File.read!(@fixture), [{"content-type", "application/json"}])
      end)

      assert {:ok, %{title: "elixir-lang/elixir", attributes: %{"language" => "Elixir"}}} =
               GitHub.fetch_repo("elixir-lang", "elixir", token: nil)
    end

    test "sends a token as a bearer token" do
      HTTP.Test.expect(GitHub, fn request ->
        assert HTTP.Headers.get(request.headers, "authorization") == "Bearer secret"
        HTTP.Test.response(200, File.read!(@fixture))
      end)

      assert {:ok, _details} = GitHub.fetch_repo("elixir-lang", "elixir", token: "secret")
    end

    test "maps 404 to :not_found" do
      HTTP.Test.expect(GitHub, fn _request -> HTTP.Test.status(404) end)
      assert {:error, :not_found} = GitHub.fetch_repo("nobody", "nothing")
    end

    test "maps an exhausted rate limit to the seconds until x-ratelimit-reset" do
      reset = Integer.to_string(DateTime.to_unix(@now) + 120)

      HTTP.Test.expect(GitHub, fn _request ->
        HTTP.Test.status(403)
        |> HTTP.Test.headers([{"x-ratelimit-remaining", "0"}, {"x-ratelimit-reset", reset}])
      end)

      assert {:error, {:rate_limited, 120}} = GitHub.fetch_repo("a", "b", now: @now)
    end

    test "prefers retry-after" do
      HTTP.Test.expect(GitHub, fn _request ->
        HTTP.Test.status(429) |> HTTP.Test.headers([{"retry-after", "30"}])
      end)

      assert {:error, {:rate_limited, 30}} = GitHub.fetch_repo("a", "b", now: @now)
    end

    test "treats a 403 without rate limit headers as an HTTP error" do
      HTTP.Test.expect(GitHub, fn _request -> HTTP.Test.status(403) end)
      assert {:error, {:http_status, 403}} = GitHub.fetch_repo("a", "b", now: @now)
    end

    test "maps other statuses and unreadable bodies" do
      HTTP.Test.expect(GitHub, 2, fn request ->
        case request.url.path do
          "/repos/a/server-error" -> HTTP.Test.status(500)
          "/repos/a/html" -> HTTP.Test.html("<html></html>")
        end
      end)

      assert {:error, {:http_status, 500}} = GitHub.fetch_repo("a", "server-error")
      assert {:error, :invalid_response} = GitHub.fetch_repo("a", "html")
    end

    test "maps connection errors to transport errors" do
      HTTP.Test.expect(GitHub, fn _request -> HTTP.Test.transport_error(:nxdomain) end)
      assert {:error, {:transport, "nxdomain"}} = GitHub.fetch_repo("a", "b")
    end
  end

  describe "fetch_starred/3" do
    setup do
      HTTP.Test.verify_on_exit!()
    end

    test "requests one page with the star media type and a token" do
      HTTP.Test.expect(GitHub, fn request ->
        assert request.url.path == "/users/gsmlg/starred"
        assert URI.decode_query(request.url.query) == %{"per_page" => "100", "page" => "2"}
        assert HTTP.Headers.get(request.headers, "accept") == "application/vnd.github.star+json"
        assert HTTP.Headers.get(request.headers, "authorization") == "Bearer secret"
        HTTP.Test.response(200, ~s([{"starred_at": "2026-01-01T00:00:00Z", "repo": {}}]))
      end)

      assert {:ok, [%{"starred_at" => "2026-01-01T00:00:00Z"}]} =
               GitHub.fetch_starred("gsmlg", 2, token: "secret")
    end

    test "rejects a body that is not a list" do
      HTTP.Test.expect(GitHub, fn _request -> HTTP.Test.response(200, "{}") end)
      assert {:error, :invalid_response} = GitHub.fetch_starred("gsmlg", 1)
    end
  end

  describe "fetch_readme/3" do
    setup do
      HTTP.Test.verify_on_exit!()
    end

    test "returns the raw README" do
      HTTP.Test.expect(GitHub, fn request ->
        assert request.url.path == "/repos/elixir-lang/elixir/readme"
        assert HTTP.Headers.get(request.headers, "accept") == "application/vnd.github.raw+json"
        HTTP.Test.response(200, "# Elixir\n\nA language.")
      end)

      assert {:ok, "# Elixir\n\nA language."} = GitHub.fetch_readme("elixir-lang", "elixir")
    end

    test "maps a missing README and rate limits" do
      HTTP.Test.expect(GitHub, fn _request -> HTTP.Test.status(404) end)
      assert {:error, :not_found} = GitHub.fetch_readme("a", "b")

      HTTP.Test.expect(GitHub, fn _request ->
        HTTP.Test.status(429) |> HTTP.Test.headers([{"retry-after", "9"}])
      end)

      assert {:error, {:rate_limited, 9}} = GitHub.fetch_readme("a", "b")
    end

    test "replaces invalid UTF-8 and cuts very long READMEs" do
      HTTP.Test.expect(GitHub, 2, fn request ->
        case request.url.path do
          "/repos/a/bad/readme" -> HTTP.Test.response(200, <<"ok ", 0xFF, " end">>)
          "/repos/a/long/readme" -> HTTP.Test.response(200, String.duplicate("x", 200_010))
        end
      end)

      assert {:ok, "ok \uFFFD end"} = GitHub.fetch_readme("a", "bad")
      assert {:ok, long} = GitHub.fetch_readme("a", "long")
      assert String.length(long) == 200_000
    end
  end
end
