defmodule Singularity.Knowledge.TextDiffTest do
  use ExUnit.Case, async: true

  alias Singularity.Knowledge.TextDiff

  defp numbered(range), do: Enum.map_join(range, "", &"line #{&1}\n")

  test "identical texts have no diff" do
    assert TextDiff.unified("a\nb\n", "a\nb\n") == ""
    assert TextDiff.unified("", "") == ""
  end

  test "one changed line gives one hunk with three lines of context" do
    old = numbered(1..10)
    new = String.replace(old, "line 5\n", "line five\n")

    assert TextDiff.unified(old, new) ==
             """
             @@ -2,7 +2,7 @@
              line 2
              line 3
              line 4
             -line 5
             +line five
              line 6
              line 7
              line 8
             """
  end

  test "lines added at the start and at the end" do
    old = numbered(1..10)
    new = "first\n" <> old <> "last\n"

    assert TextDiff.unified(old, new) ==
             """
             @@ -1,3 +1,4 @@
             +first
              line 1
              line 2
              line 3
             @@ -8,3 +9,4 @@
              line 8
              line 9
              line 10
             +last
             """
  end

  test "changes close together share a hunk" do
    old = numbered(1..10)
    new = old |> String.replace("line 3\n", "x\n") |> String.replace("line 6\n", "y\n")

    assert [_header] = Regex.scan(~r/^@@/m, TextDiff.unified(old, new))
  end

  test "a diff over the limit is cut at a line and marked" do
    old = numbered(1..2000)
    new = String.replace(old, "line ", "row ")

    diff = TextDiff.unified(old, new, 3, 1_000)

    assert byte_size(diff) <= 1_000 + byte_size("… diff truncated\n")
    assert String.ends_with?(diff, "\n… diff truncated\n")
  end
end
