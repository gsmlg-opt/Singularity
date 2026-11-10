defmodule Singularity.Knowledge.AddressTest do
  use ExUnit.Case, async: true

  alias Singularity.Knowledge.Address

  @elixir %{
    external_id: "github.com/elixir-lang/elixir",
    owner: "elixir-lang",
    repo: "elixir",
    url: "https://github.com/elixir-lang/elixir"
  }

  test "accepts the supported GitHub address forms" do
    for input <- [
          "elixir-lang/elixir",
          " elixir-lang/elixir ",
          "elixir-lang/elixir.git",
          "github.com/elixir-lang/elixir",
          "www.github.com/elixir-lang/elixir",
          "https://github.com/elixir-lang/elixir",
          "http://github.com/elixir-lang/elixir/",
          "https://github.com/elixir-lang/elixir.git",
          "https://github.com/elixir-lang/elixir/tree/main/lib",
          "https://github.com/elixir-lang/elixir?tab=readme#top",
          "git@github.com:elixir-lang/elixir.git"
        ] do
      assert Address.normalize(input) == {:ok, @elixir}, "input: #{inspect(input)}"
    end
  end

  test "lowercases the external id and keeps the given spelling elsewhere" do
    assert Address.normalize("https://GitHub.com/PhoenixFramework/Phoenix_Live_View") ==
             {:ok,
              %{
                external_id: "github.com/phoenixframework/phoenix_live_view",
                owner: "PhoenixFramework",
                repo: "Phoenix_Live_View",
                url: "https://github.com/PhoenixFramework/Phoenix_Live_View"
              }}
  end

  test "keeps dots in repository names" do
    assert {:ok, %{external_id: "github.com/vercel/next.js", repo: "next.js"}} =
             Address.normalize("vercel/next.js")
  end

  test "rejects non-GitHub and malformed addresses" do
    for input <- [
          "",
          "elixir",
          "https://gitlab.com/a/b",
          "gitlab.com/a/b",
          "git@gitlab.com:a/b.git",
          "example.com/a",
          "https://github.com/elixir-lang",
          "a/b/c",
          "-bad/repo",
          "owner/..",
          nil,
          42
        ] do
      assert Address.normalize(input) == {:error, :unsupported_address},
             "input: #{inspect(input)}"
    end
  end
end
