defmodule Singularity.Web.AssetToolchainContractTest do
  use ExUnit.Case, async: false

  @root Path.expand("../../../../../", __DIR__)

  test "uses one named DuskmoonBundler profile for the web asset surface" do
    assert {:ok, profile} =
             Application.fetch_env(:duskmoon_bundler, :singularity_web)

    assert Keyword.fetch!(profile, :root) == "apps/singularity_web/assets"
    assert Keyword.fetch!(profile, :entry) == "apps/singularity_web/assets/js/app.ts"
    assert Keyword.fetch!(profile, :outdir) == "apps/singularity_web/priv/static/assets"
    assert Keyword.fetch!(profile, :resolve_dirs) == ["apps", "deps"]

    assert Keyword.fetch!(profile, :tailwind) == [
             css: "apps/singularity_web/assets/css/app.css",
             sources: [
               %{base: "apps/singularity_web/lib", pattern: "**/*.{ex,exs,heex}"},
               %{
                 base: "apps/singularity_web/assets",
                 pattern: "**/*.{css,js,ts,jsx,tsx}"
               }
             ]
           ]

    assert profile
           |> Keyword.fetch!(:server)
           |> Keyword.fetch!(:watch_dirs) ==
             [
               "apps/singularity_web/lib",
               "apps/singularity_web/assets"
             ]
  end

  test "exposes JavaScript assets to no-argument DuskmoonBundler checks" do
    expected =
      @root
      |> Path.join("apps/singularity_web/assets/**/*.{js,ts,jsx,tsx}")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.expand/1)
      |> Enum.sort()

    discovered =
      File.cd!(@root, fn ->
        DuskmoonBundler.JS.Helpers.discover_files()
        |> Enum.map(&Path.expand/1)
        |> Enum.sort()
      end)

    assert [_ | _] = expected
    assert discovered == expected
    refute Enum.any?(discovered, &(Path.extname(&1) in [".css", ".json"]))
    refute Enum.any?(discovered, &String.contains?(&1, "/node_modules/"))
  end

  test "resolves the runtime profile from the web app priv directory" do
    assert {:ok, runtime_profile} =
             Application.fetch_env(:duskmoon_bundler_runtime, :singularity_web)

    assert Keyword.fetch!(runtime_profile, :outdir) == "priv/static/assets"

    assert DuskmoonBundler.Runtime.Config.resolve(:singularity_web).outdir ==
             "priv/static/assets"
  end

  test "wires the named profile through Mix, dev serving, formatting, and the root layout" do
    web_mix = read!("apps/singularity_web/mix.exs")
    root_mix = read!("mix.exs")
    dev_config = read!("config/dev.exs")
    endpoint = read!("apps/singularity_web/lib/singularity/web/endpoint.ex")

    root_layout =
      read!("apps/singularity_web/lib/singularity/web/components/layouts/root.html.heex")

    formatter = read!(".formatter.exs")

    assert web_mix =~ ~s|{:duskmoon_bundler_runtime, "~> 9.12.2"}|

    assert web_mix =~
             ~s|{:duskmoon_bundler, "~> 9.12.2", runtime: Mix.env() in [:dev, :test]}|

    assert web_mix =~ ~s|{:floki, ">= 0.36.0", only: :test}|
    assert web_mix =~ ~s|{:lazy_html, ">= 0.1.0"}|

    refute web_mix =~ "phoenix_duskmoon"
    refute web_mix =~ "TODO(upstream): duskmoon-dev/phoenix-duskmoon-ui#105"
    refute web_mix =~ "WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#107"
    refute web_mix =~ "defp extra_applications"
    assert web_mix =~ "extra_applications: [:logger]"

    assert root_mix =~
             ~s("assets.build": ["duskmoon_bundler.build singularity_web --tailwind"])

    assert root_mix =~
             ~s("assets.deploy": [\n        "duskmoon_bundler.build singularity_web --tailwind",\n        "phx.digest"\n      ])

    assert dev_config =~
             ~s({Mix.Tasks.DuskmoonBundler.Dev, :run, [["singularity_web"]]})

    assert dev_config =~ "code_reloader: true"
    refute dev_config =~ "code_reloader: false"

    assert endpoint =~ "plug DuskmoonBundler.DevServer"
    assert endpoint =~ "profile: :singularity_web"
    assert endpoint =~ ~s|@assets_js_root Path.expand("../../../assets/js", __DIR__)|
    assert endpoint =~ "root: @assets_js_root"
    refute endpoint =~ ~s(root: "apps/singularity_web/assets/js")
    assert endpoint =~ ~s(prefix: "/assets/js")
    assert endpoint =~ "plug Plug.Static"
    assert endpoint =~ ~s(at: "/assets")
    assert endpoint =~ ~s(from: {:singularity_web, "priv/static/assets"})

    assert root_layout =~
             ~r/Phoenix\.HTML\.raw\(\s*DuskmoonBundler\.Preload\.tags\(.*?\)\s*\)/s

    assert root_layout =~ ~r/DuskmoonBundler\.Preload\.tags\(\s*@conn,/s
    assert root_layout =~ ~r/DuskmoonBundler\.static_path\(\s*@conn,/s
    refute root_layout =~ "Singularity.Web.Endpoint"

    assert root_layout =~ "DuskmoonBundler.static_path"
    assert root_layout =~ ~s("/assets/js/app.js")
    assert root_layout =~ ~s("/assets/css/app.css")
    assert root_layout =~ "profile: :singularity_web"

    assert formatter =~ "DuskmoonBundler.Formatter"
    assert formatter =~ ~s("apps/singularity_web/assets/**/*.{js,ts,jsx,tsx}")
    refute formatter =~ ~s("apps/singularity_web/assets/**/*.json")
    refute formatter =~ ~s("apps/singularity_web/assets/**/*.css")
  end

  test "locks the root React and test-runner workspace contract" do
    package_path = Path.join(@root, "package.json")
    tsconfig_path = Path.join(@root, "tsconfig.json")
    vitest_path = Path.join(@root, "vitest.config.ts")
    lock_path = Path.join(@root, "package-lock.json")
    legacy_lock_path = Path.join(@root, "npm.lock")

    assert File.exists?(package_path)
    assert File.exists?(tsconfig_path)
    assert File.exists?(vitest_path)
    assert File.exists?(lock_path)
    refute File.exists?(legacy_lock_path)

    package = package_path |> File.read!() |> JSON.decode!()
    lock = lock_path |> File.read!() |> JSON.decode!()

    assert lock["name"] == "singularity"
    assert lock["lockfileVersion"] == 3

    assert package == %{
             "name" => "singularity",
             "private" => true,
             "scripts" => %{
               "test:e2e" => "playwright test",
               "test:js" => "vitest run"
             },
             "dependencies" => %{
               "react" => "^19.2.0",
               "react-dom" => "^19.2.0",
               "react-markdown" => "10.1.0"
             },
             "devDependencies" => %{
               "@axe-core/playwright" => "^4.12.0",
               "@playwright/test" => "^1.61.0",
               "@types/node" => "26.2.0",
               "@types/react" => "^19.2.0",
               "@types/react-dom" => "^19.2.0",
               "jsdom" => "^29.1.0",
               "typescript" => "^7.0.0",
               "vitest" => "^4.1.0"
             }
           }

    vitest = File.read!(vitest_path)
    assert vitest =~ ~s(environment: "jsdom")

    assert vitest =~
             ~s("apps/singularity_web/assets/test/**/*.test.{ts,tsx}")
  end

  defp read!(path), do: File.read!(Path.join(@root, path))
end
