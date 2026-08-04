defmodule Singularity.Web.RootLayoutAssetsTest do
  use Singularity.Web.ConnCase, async: false

  defmodule ReleaseEndpoint do
    def config(:code_reloader), do: false
    def config(:otp_app), do: :singularity_web
    def static_path(path), do: path
  end

  test "test endpoint disables vendor prebundle during plug initialization" do
    assert DuskmoonBundler.Config.server(:singularity_web).vendor_prebundle == false
  end

  test "code-reloading endpoint starts the DuskmoonBundler runtime application" do
    assert Singularity.Web.Endpoint.config(:code_reloader) == true

    assert Enum.any?(Application.started_applications(), fn {app, _description, _version} ->
             app == :duskmoon_bundler
           end)

    refute :ets.whereis(:duskmoon_bundler_cache) == :undefined
  end

  test "development server serves the TypeScript entry from the web app source root", %{
    conn: conn
  } do
    response = get(conn, "/assets/js/app.ts")

    assert response.status == 200
    assert response.resp_body =~ "import.meta.hot.accept"
  end

  test "endpoint serves built assets from the web application priv directory", %{conn: conn} do
    filename = "static-fixture-#{System.unique_integer([:positive])}.js"
    path = Application.app_dir(:singularity_web, "priv/static/assets/js/#{filename}")
    body = "export const staticFixture = true;"

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    on_exit(fn -> File.rm(path) end)

    response = get(conn, "/assets/js/#{filename}")

    assert response.status == 200
    assert response.resp_body == body
  end

  test "test endpoint uses source assets without a production manifest", %{conn: conn} do
    assert Singularity.Web.Endpoint.config(:code_reloader) == true

    result =
      try do
        {:ok, get(conn, "/login")}
      rescue
        error -> {:error, error}
      end

    assert {:ok, response} = result
    html = html_response(response, 200)

    assert html =~ ~s(href="/assets/css/app.css")
    assert html =~ ~s(src="/assets/js/app.ts")
  end

  test "root layout exposes exactly one nonempty CSRF meta token", %{conn: conn} do
    html =
      conn
      |> get("/login")
      |> html_response(200)

    assert [{"meta", attributes, []}] =
             html
             |> Floki.parse_document!()
             |> Floki.find(~s(meta[name="csrf-token"]))

    assert {"content", token} = List.keyfind(attributes, "content", 0)
    assert is_binary(token)
    assert token != ""
  end

  test "trusted preload output renders as markup instead of escaped text" do
    manifest = %{
      "app.js" => %{
        "file" => "app-hash.js",
        "imports" => ["vendor-hash.js"]
      }
    }

    html =
      manifest
      |> DuskmoonBundler.Preload.tags(prefix: "/assets/js", entry: "app.js")
      |> Phoenix.HTML.raw()
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    assert [_link] =
             html
             |> Floki.parse_fragment!()
             |> Floki.find("link[rel=modulepreload]")

    refute html =~ "&lt;link"
  end

  test "release helpers require a manifest and resolve hashed assets and preloads" do
    outdir =
      Path.join(
        System.tmp_dir!(),
        "singularity-release-assets-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(outdir) end)

    assert_raise DuskmoonBundler.Manifest.Error, fn ->
      DuskmoonBundler.Preload.tags(
        ReleaseEndpoint,
        "/assets/js/app.js",
        outdir: outdir,
        prefix: "/assets"
      )
    end

    manifest = %{
      "app.js" => %{
        "file" => "app-hash.js",
        "imports" => ["vendor-hash.js"]
      }
    }

    manifest_dir = Path.join(outdir, "js")
    File.mkdir_p!(manifest_dir)

    File.write!(
      Path.join(manifest_dir, "manifest.json"),
      manifest |> DuskmoonBundler.Manifest.wrap() |> JSON.encode!()
    )

    assert DuskmoonBundler.static_path(
             ReleaseEndpoint,
             "/assets/js/app.js",
             outdir: outdir,
             prefix: "/assets"
           ) == "/assets/js/app-hash.js"

    preload_html =
      DuskmoonBundler.Preload.tags(
        ReleaseEndpoint,
        "/assets/js/app.js",
        outdir: outdir,
        prefix: "/assets"
      )

    assert preload_html =~ ~s(rel="modulepreload")
    assert preload_html =~ ~s(href="/assets/js/vendor-hash.js")
  end
end
