defmodule Singularity.Collectors.IetfRfcTest do
  # Every test syncs into the one mirror under the test data directory.
  use ExUnit.Case, async: false

  alias Singularity.Collector.{Entry, Result}
  alias Singularity.Collectors.IetfRfc
  alias Singularity.Collectors.IetfRfc.Markdown
  alias Singularity.DataDir
  alias Singularity.Documents.XbergExtractor

  @remote Path.expand("../../fixtures/ietf_rfcs/remote", __DIR__)
  @now ~U[2026-11-12 08:00:00Z]

  setup do
    mirror = Path.join(DataDir.root(), "ietf-rfcs")
    File.rm_rf!(mirror)
    Process.put(:fake_rsync, &remote_rsync/1)
    %{mirror: mirror}
  end

  # Copies what the real call would fetch from the fixture "remote".
  defp remote_rsync(args) do
    destination = List.last(args)

    files =
      case Enum.find(args, &String.starts_with?(&1, "--files-from=")) do
        nil ->
          Path.wildcard(Path.join(@remote, "rfc*.{json,txt}"))

        "--files-from=" <> list ->
          for name <- list |> File.read!() |> String.split("\n", trim: true),
              path = Path.join(@remote, name),
              File.exists?(path),
              do: path
      end

    Enum.each(files, &File.cp!(&1, Path.join(destination, Path.basename(&1))))
  end

  defp fetch!, do: {:ok, %Result{}} = IetfRfc.fetch(%{}, @now)
  defp by_id(%Result{entries: entries}), do: Map.new(entries, &{&1.external_id, &1})

  test "syncs and parses every issued RFC into entries", %{mirror: mirror} do
    {:ok, result} = fetch!()

    assert %Result{period: "2026-11", complete: true, skipped: 1} = result
    assert result.entries |> Enum.map(& &1.external_id) == ["rfc791", "rfc8446", "rfc9999"]

    assert_received {:rsync, text_args}
    assert "--delete" in text_args
    assert "--include=rfc*.json" in text_args
    assert Enum.take(text_args, -2) == ["rsync.rfc-editor.org::rfcs/", mirror <> "/"]

    assert_received {:rsync, html_args}
    assert ("--files-from=" <> Path.join(mirror, "html-files.txt")) in html_args
    refute "--delete" in html_args
    assert File.read!(Path.join(mirror, "html-files.txt")) == "rfc9999.html\n"
  end

  test "an RFC's metadata, labels and period" do
    {:ok, result} = fetch!()

    assert %Entry{
             item_kind: "ietf_rfc",
             title: "The Transport Layer Security (TLS) Protocol Version 1.3",
             url: "https://www.rfc-editor.org/rfc/rfc8446",
             published_at: ~U[2018-08-01 00:00:00Z],
             period: "2018-08",
             labels: ["status:proposed-standard", "obsoleted"],
             item_attributes: attributes
           } = by_id(result)["rfc8446"]

    assert %{
             "number" => 8446,
             "authors" => ["E. Rescorla"],
             "status" => "PROPOSED STANDARD",
             "stream_source" => "Transport Layer Security",
             "obsoletes" => ["rfc5077", "rfc5246", "rfc6961"],
             "obsoleted_by" => ["rfc9846"],
             "updates" => ["rfc5705", "rfc6066"],
             "page_count" => 160,
             "doi" => "10.17487/RFC8446",
             "draft" => "draft-ietf-tls-tls13-28",
             "content_source" => "text"
           } = attributes
  end

  test "an empty abstract is no summary" do
    {:ok, result} = fetch!()

    assert %Entry{summary: nil, labels: ["status:internet-standard"]} = by_id(result)["rfc791"]
  end

  test "older RFCs get their text verbatim in a fence, v3 RFCs Markdown from HTML" do
    {:ok, result} = fetch!()
    entries = by_id(result)

    text_md = File.read!(entries["rfc791"].content_path)
    assert text_md == Markdown.from_text(File.read!(Path.join(@remote, "rfc791.txt")))

    assert %Entry{item_attributes: %{"content_source" => "html"}, content_path: html_md} =
             entries["rfc9999"]

    # The test extractor stands in for xberg here.
    assert_received {:fake_extractor_called, html_path, [mime_type: "text/html"]}
    assert Path.basename(html_path) == "rfc9999.html"
    assert File.read!(html_md) == "# Fake"
  end

  test "cached Markdown is reused, and regenerated when the converter version changes",
       %{mirror: mirror} do
    fetch!()
    assert_received {:fake_extractor_called, _path, _opts}

    fetch!()
    refute_received {:fake_extractor_called, _path, _opts}

    File.write!(Path.join([mirror, "markdown", "VERSION"]), "0\n")
    fetch!()
    assert_received {:fake_extractor_called, _path, _opts}
  end

  test "HTML of RFCs no longer v3 is removed", %{mirror: mirror} do
    File.mkdir_p!(mirror)
    stale = Path.join(mirror, "rfc1234.html")
    File.write!(stale, "<html></html>")

    fetch!()

    refute File.exists?(stale)
    assert File.exists?(Path.join(mirror, "rfc9999.html"))
  end

  test "a failed metadata sync is an error and nothing else is fetched" do
    Process.put(:fake_rsync, fn _args -> {:error, {:rsync, 10, "connection refused"}} end)

    assert {:error, {:rsync, 10, "connection refused"}} = IetfRfc.fetch(%{}, @now)
    assert_received {:rsync, _text_args}
    refute_received {:rsync, _html_args}
  end

  test "a failed HTML sync is an error" do
    Process.put(:fake_rsync, fn args ->
      if Enum.any?(args, &String.starts_with?(&1, "--files-from=")),
        do: {:error, {:rsync, 23, "partial transfer"}},
        else: remote_rsync(args)
    end)

    assert {:error, {:rsync, 23, "partial transfer"}} = IetfRfc.fetch(%{}, @now)
  end

  test "an empty mirror gives an empty result" do
    Process.put(:fake_rsync, fn _args -> :ok end)

    assert {:ok, %Result{entries: [], skipped: 0}} = IetfRfc.fetch(%{}, @now)
  end

  test "xberg turns v3 HTML into clean Markdown" do
    {:ok, %{content: markdown}} = XbergExtractor.extract(Path.join(@remote, "rfc9999.html"), [])
    markdown = Markdown.clean_html(markdown)

    assert String.starts_with?(markdown, "# RFC 9999\n")
    assert markdown =~ "## 1. Introduction"
    assert markdown =~ "[RFC 9334](https://www.rfc-editor.org/rfc/rfc9334)"
    refute markdown =~ "¶"
    refute markdown =~ "](#"
  end
end
