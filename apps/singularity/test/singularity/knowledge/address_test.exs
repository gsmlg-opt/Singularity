defmodule Singularity.Knowledge.AddressTest do
  use ExUnit.Case, async: true

  alias Singularity.Knowledge.Address

  @elixir %{
    external_id: "github.com/elixir-lang/elixir",
    host: "github.com",
    path: "elixir-lang/elixir",
    url: "https://github.com/elixir-lang/elixir",
    github?: true
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
          "git@github.com:elixir-lang/elixir.git",
          "ssh://git@github.com/elixir-lang/elixir.git"
        ] do
      assert Address.normalize(input) == {:ok, @elixir}, "input: #{inspect(input)}"
    end
  end

  test "lowercases the external id and keeps the given spelling elsewhere" do
    assert Address.normalize("https://GitHub.com/PhoenixFramework/Phoenix_Live_View") ==
             {:ok,
              %{
                external_id: "github.com/phoenixframework/phoenix_live_view",
                host: "github.com",
                path: "PhoenixFramework/Phoenix_Live_View",
                url: "https://github.com/PhoenixFramework/Phoenix_Live_View",
                github?: true
              }}
  end

  test "keeps dots in repository names" do
    assert {:ok, %{external_id: "github.com/vercel/next.js", path: "vercel/next.js"}} =
             Address.normalize("vercel/next.js")
  end

  test "accepts other hosts with their whole path" do
    gitlab = %{
      external_id: "gitlab.com/group/sub/tool",
      host: "gitlab.com",
      path: "group/sub/tool",
      github?: false
    }

    for {input, url} <- [
          {"https://gitlab.com/group/sub/tool", "https://gitlab.com/group/sub/tool"},
          {"https://GitLab.com/group/sub/tool.git/", "https://gitlab.com/group/sub/tool"},
          {"gitlab.com/group/sub/tool", "https://gitlab.com/group/sub/tool"},
          {"git@gitlab.com:group/sub/tool.git", "git@gitlab.com:group/sub/tool.git"},
          {"ssh://git@gitlab.com:2222/group/sub/tool.git",
           "ssh://git@gitlab.com:2222/group/sub/tool.git"}
        ] do
      assert {:ok, address} = Address.normalize(input), "input: #{inspect(input)}"
      assert Map.delete(address, :url) == gitlab, "input: #{inspect(input)}"
      assert address.url == url, "input: #{inspect(input)}"
    end

    assert {:ok, %{external_id: "git.example.com/tool", url: "http://git.example.com:3000/tool"}} =
             Address.normalize("http://git.example.com:3000/tool")
  end

  test "rejects malformed addresses" do
    for input <- [
          "",
          "elixir",
          "https://github.com/elixir-lang",
          "https://gitlab.com",
          "https://gitlab.com/a/../b",
          "a/b/c",
          "-bad/repo",
          "owner/..",
          "ftp://example.com/a",
          nil,
          42
        ] do
      assert Address.normalize(input) == {:error, :unsupported_address},
             "input: #{inspect(input)}"
    end
  end
end
