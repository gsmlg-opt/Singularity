defmodule Singularity.Collectors.IetfRfc.MarkdownTest do
  use ExUnit.Case, async: true

  alias Singularity.Collectors.IetfRfc.Markdown

  @fixtures Path.expand("../../../fixtures/ietf_rfcs", __DIR__)

  describe "clean_html/1 on xberg's output for RFC 9999" do
    setup do
      %{md: @fixtures |> Path.join("rfc9999.xberg.md") |> File.read!() |> Markdown.clean_html()}
    end

    test "starts at the RFC heading, without front matter or the header table", %{md: md} do
      assert String.starts_with?(md, "# RFC 9999\n")
      refute md =~ "meta-generator"
      refute md =~ "| RFC 9999"
    end

    test "removes pilcrows and flattens in-page links", %{md: md} do
      refute md =~ "¶"
      refute md =~ "](#"
      assert md =~ "## Abstract\n"
      assert md =~ "## 1. Introduction\n"
      assert md =~ "architecture [RFC9334] are protocol-agnostic"
    end

    test "keeps external links", %{md: md} do
      assert md =~ "[Section 8](https://rfc-editor.org/rfc/rfc9334#section-8)"
    end
  end

  test "clean_html/1 rewrites relative RFC links and titled in-page links" do
    md = """
    # RFC 1

    Obsoletes: [5077](./rfc5077), see [RFC 5246](./rfc5246#section-1).
    Signed with [[RSA](#ref-RSA "\\"A Method (for) Signatures\\"")].
    """

    assert Markdown.clean_html(md) == """
           # RFC 1

           Obsoletes: [5077](https://www.rfc-editor.org/rfc/rfc5077), see [RFC 5246](https://www.rfc-editor.org/rfc/rfc5246#section-1).
           Signed with [RSA].
           """
  end

  test "clean_html/1 keeps everything when there is no RFC heading" do
    assert Markdown.clean_html("Just text\n") == "Just text\n"
  end

  describe "from_text/1" do
    test "keeps the text byte for byte in a text fence" do
      text = "   +------+\n   | IP   |\n   +------+\n"
      assert Markdown.from_text(text) == "```text\n" <> text <> "```\n"
    end

    test "adds a final newline inside the fence" do
      assert Markdown.from_text("x") == "```text\nx\n```\n"
    end

    test "uses a fence longer than any backtick run in the text" do
      text = "example:\n````\ncode\n````\n"
      assert Markdown.from_text(text) == "`````text\n" <> text <> "`````\n"
    end
  end
end
