defmodule Singularity.Knowledge.TextDiff do
  @moduledoc """
  Unified line diffs of item content, as stored in `item_changes.content_diff`.
  """

  @max_bytes 1_048_576
  @truncated "… diff truncated\n"

  @doc """
  The unified diff (`@@ -a,b +c,d @@` hunks, lines prefixed with ` `, `-` or
  `+`) between two texts, with `context` lines around each change. `""` when
  they are equal. Longer than `max_bytes`, it is cut at a line and marked.
  """
  @spec unified(String.t(), String.t(), non_neg_integer(), pos_integer()) :: String.t()
  def unified(old, new, context \\ 3, max_bytes \\ @max_bytes) do
    old
    |> lines()
    |> List.myers_difference(lines(new))
    |> positioned()
    |> hunks(context)
    |> Enum.map(&render_hunk/1)
    |> IO.iodata_to_binary()
    |> truncate(max_bytes)
  end

  defp lines(text), do: String.split(text, "\n", trim: false) |> drop_final_empty()

  defp drop_final_empty(lines) do
    case List.last(lines) do
      "" -> Enum.drop(lines, -1)
      _line -> lines
    end
  end

  # Each line as {op, text, old_lines_before, new_lines_before}.
  defp positioned(script) do
    {lines, _counts} =
      Enum.flat_map_reduce(script, {0, 0}, fn {op, texts}, counts ->
        Enum.map_reduce(texts, counts, fn text, {o, n} ->
          {{op, text, o, n}, advance(op, o, n)}
        end)
      end)

    lines
  end

  defp advance(:eq, o, n), do: {o + 1, n + 1}
  defp advance(:del, o, n), do: {o + 1, n}
  defp advance(:ins, o, n), do: {o, n + 1}

  defp hunks(lines, context) do
    indexed = Enum.with_index(lines)
    last = length(lines) - 1

    indexed
    |> Enum.reject(fn {{op, _, _, _}, _i} -> op == :eq end)
    |> Enum.map(fn {_line, i} -> {max(i - context, 0), min(i + context, last)} end)
    |> merge_ranges()
    |> Enum.map(fn {from, to} -> Enum.slice(lines, from..to) end)
  end

  defp merge_ranges(ranges) do
    ranges
    |> Enum.reduce([], fn
      {from, to}, [{prev_from, prev_to} | rest] when from <= prev_to + 1 ->
        [{prev_from, max(to, prev_to)} | rest]

      range, acc ->
        [range | acc]
    end)
    |> Enum.reverse()
  end

  defp render_hunk([{_op, _text, o, n} | _] = lines) do
    old_count = Enum.count(lines, fn {op, _, _, _} -> op != :ins end)
    new_count = Enum.count(lines, fn {op, _, _, _} -> op != :del end)

    header = ["@@ -", range(o, old_count), " +", range(n, new_count), " @@\n"]
    [header | Enum.map(lines, &render_line/1)]
  end

  # Unified diff ranges: "start,count", or "start" when count is 1; an empty
  # side starts at the line before it.
  defp range(before, 0), do: "#{before},0"
  defp range(before, 1), do: "#{before + 1}"
  defp range(before, count), do: "#{before + 1},#{count}"

  defp render_line({:eq, text, _, _}), do: [" ", text, "\n"]
  defp render_line({:del, text, _, _}), do: ["-", text, "\n"]
  defp render_line({:ins, text, _, _}), do: ["+", text, "\n"]

  defp truncate(diff, max_bytes) when byte_size(diff) <= max_bytes, do: diff

  defp truncate(diff, max_bytes) do
    head = binary_part(diff, 0, max_bytes)

    cut =
      case :binary.matches(head, "\n") do
        [] -> ""
        matches -> binary_part(head, 0, elem(List.last(matches), 0) + 1)
      end

    cut <> @truncated
  end
end
