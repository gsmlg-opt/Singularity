defmodule Singularity.SettingsTest do
  # Not async: these tests change the GITHUB_TOKEN environment variable.
  use Singularity.DataCase, async: false

  alias Singularity.Settings

  setup do
    previous = System.get_env("GITHUB_TOKEN")
    System.delete_env("GITHUB_TOKEN")

    on_exit(fn ->
      if previous,
        do: System.put_env("GITHUB_TOKEN", previous),
        else: System.delete_env("GITHUB_TOKEN")
    end)
  end

  test "without a stored or environment token there is none" do
    assert Settings.get_github_token() == nil
    assert Settings.github_token_status() == :unset
  end

  test "falls back to GITHUB_TOKEN" do
    System.put_env("GITHUB_TOKEN", "env-token-1234")
    assert Settings.get_github_token() == "env-token-1234"
    assert Settings.github_token_status() == {:env, "1234"}
  end

  test "a stored token wins over the environment and is reported by its last four characters" do
    System.put_env("GITHUB_TOKEN", "env-token-1234")
    assert {:ok, _setting} = Settings.put_github_token("  ghp_secretabcd ")
    assert Settings.get_github_token() == "ghp_secretabcd"
    assert Settings.github_token_status() == {:settings, "abcd"}
  end

  test "putting a token again replaces it; clearing removes it" do
    {:ok, _} = Settings.put_github_token("first-1111")
    {:ok, _} = Settings.put_github_token("second-2222")
    assert Settings.get_github_token() == "second-2222"

    assert :ok = Settings.clear_github_token()
    assert Settings.get_github_token() == nil
  end

  test "rejects a blank token" do
    assert {:error, changeset} = Settings.put_github_token("   ")
    assert %{value: ["can't be blank"]} = errors_on(changeset)
  end

  describe "theme" do
    test "defaults to moonlight" do
      assert Settings.theme() == "moonlight"
      assert hd(Settings.themes()) == "moonlight"
    end

    test "stores a known theme and rejects unknown ones" do
      assert {:ok, _setting} = Settings.put_theme("sunshine")
      assert Settings.theme() == "sunshine"
      assert {:error, :unknown_theme} = Settings.put_theme("neon")
      assert Settings.theme() == "sunshine"
    end
  end
end
