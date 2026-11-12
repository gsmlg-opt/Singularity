defmodule Singularity.Collectors.IetfRfc do
  @moduledoc """
  Collects every IETF RFC from the RFC Editor's rsync service into
  `<data_dir>/ietf-rfcs`: JSON metadata and plain text for all RFCs, HTML for
  v3 RFCs (8650 on, `"XML"` in their formats). Each RFC's Markdown content is
  cached under `markdown/` (see `IetfRfc.Markdown`). The result is the complete
  list, so an RFC the RFC Editor stops listing leaves this source.
  """

  @behaviour Singularity.Collector

  require Logger

  alias Singularity.Collector.{Entry, Result}
  alias Singularity.Collectors.IetfRfc.Markdown
  alias Singularity.{DataDir, Documents}

  @remote "rsync.rfc-editor.org::rfcs/"
  @rfc_editor "https://www.rfc-editor.org/rfc/rfc"
  # Bump to regenerate every cached Markdown file (and record the changes).
  @converter_version 1

  @months ~w(January February March April May June July August September October November December)
  @related ~w(obsoletes obsoleted_by updates updated_by see_also)

  @impl true
  def kind, do: "ietf_rfc"

  @impl true
  def queue, do: :rfc_editor

  @impl true
  def label, do: "IETF RFCs"

  @impl true
  def config_fields, do: []

  @impl true
  def default_interval_minutes, do: 43_200

  @impl true
  def validate_config(_config), do: {:ok, %{}}

  @impl true
  def fetch(_config, now) do
    mirror = DataDir.path!("ietf-rfcs")

    with :ok <- timed("metadata and text synced", fn -> rsync().sync(text_args(mirror)) end) do
      {rfcs, skipped} = parse_dir(mirror)
      v3 = for {number, json} <- rfcs, v3?(json), do: number
      list = write_html_list!(mirror, v3)

      # A second request in the same job: wait as long as the queue's rate limit.
      Process.sleep(request_interval())

      with :ok <- timed("v3 HTML synced", fn -> rsync().sync(html_args(mirror, list)) end) do
        remove_stale_html!(mirror, v3)
        markdown_dir = prepare_markdown_dir!(mirror)
        v3 = MapSet.new(v3)

        entries =
          timed("#{length(rfcs)} RFCs parsed and converted", fn ->
            Enum.map(rfcs, fn {number, json} ->
              content = markdown!(mirror, markdown_dir, number, MapSet.member?(v3, number))
              parse_rfc(json, content)
            end)
          end)

        {:ok, %Result{period: period(now), entries: entries, skipped: skipped, complete: true}}
      end
    end
  end

  defp timed(step, fun) do
    {microseconds, result} = :timer.tc(fun)
    Logger.info("IETF RFCs: #{step} in #{div(microseconds, 1000)} ms")
    result
  end

  defp text_args(mirror) do
    ~w(-rt --delete --timeout=600 --include=rfc*.json --include=rfc*.txt --exclude=*) ++
      [@remote, mirror <> "/"]
  end

  defp html_args(mirror, list),
    do: ["-rt", "--timeout=600", "--files-from=" <> list, @remote, mirror <> "/"]

  defp write_html_list!(mirror, numbers) do
    path = Path.join(mirror, "html-files.txt")
    File.write!(path, Enum.map(numbers, &"rfc#{&1}.html\n"))
    path
  end

  # The HTML call cannot --delete; HTML of RFCs no longer listed as v3 is removed here.
  defp remove_stale_html!(mirror, v3) do
    keep = MapSet.new(v3, &"rfc#{&1}.html")

    mirror
    |> Path.join("rfc*.html")
    |> Path.wildcard()
    |> Enum.reject(&MapSet.member?(keep, Path.basename(&1)))
    |> Enum.each(&File.rm!/1)
  end

  defp v3?(json), do: "XML" in List.wrap(json["format"])

  defp period(now), do: now |> DateTime.to_date() |> Calendar.strftime("%Y-%m")

  @doc """
  Reads `rfc<number>.json` files in `dir`: `{[{number, json}], skipped}`.
  Files that cannot be decoded or lack `doc_id` or `title` are skipped; RFCs
  that were never issued and other file names are ignored.
  """
  @spec parse_dir(Path.t()) :: {[{pos_integer(), map()}], non_neg_integer()}
  def parse_dir(dir) do
    dir
    |> Path.join("rfc*.json")
    |> Path.wildcard()
    |> Enum.filter(&Regex.match?(~r/^rfc\d+\.json$/, Path.basename(&1)))
    |> Enum.reduce({[], 0}, fn path, {rfcs, skipped} ->
      case read_json(path) do
        {:ok, %{"status" => "NOT ISSUED"}} ->
          {rfcs, skipped}

        {:ok, %{"doc_id" => "RFC" <> _, "title" => title} = json} when is_binary(title) ->
          add(json, rfcs, skipped)

        _unusable ->
          {rfcs, skipped + 1}
      end
    end)
    |> then(fn {rfcs, skipped} -> {Enum.sort_by(rfcs, &elem(&1, 0)), skipped} end)
  end

  defp read_json(path) do
    with {:ok, body} <- File.read(path), do: Jason.decode(body)
  end

  defp add(%{"doc_id" => "RFC" <> digits} = json, rfcs, skipped) do
    case Integer.parse(digits) do
      {number, ""} when number > 0 -> {[{number, json} | rfcs], skipped}
      _not_a_number -> {rfcs, skipped + 1}
    end
  end

  @doc """
  The entry for one RFC's JSON metadata. `content` is `{markdown_path,
  "html" | "text"}`, or nil when the RFC has no usable text.
  """
  @spec parse_rfc(map(), {Path.t(), String.t()} | nil) :: Entry.t()
  def parse_rfc(%{"doc_id" => "RFC" <> digits} = json, content) do
    number = String.to_integer(digits)
    status = blank_to_nil(json["status"])
    published_at = published_at(json["pub_date"])
    related = Map.new(@related, &{&1, related_ids(json[&1])})

    attributes =
      %{
        "number" => number,
        "authors" => strings(json["authors"]),
        "status" => status,
        "stream_source" => blank_to_nil(json["source"]),
        "keywords" => strings(json["keywords"]),
        "doi" => blank_to_nil(json["doi"]),
        "errata_url" => blank_to_nil(json["errata_url"]),
        "page_count" => integer(json["page_count"]),
        "draft" => blank_to_nil(json["draft"]),
        "formats" => strings(json["format"]),
        "content_source" => content && elem(content, 1)
      }
      |> Map.merge(related)

    %Entry{
      item_kind: kind(),
      external_id: "rfc#{number}",
      title: String.trim(json["title"]),
      url: "#{@rfc_editor}#{number}",
      summary: blank_to_nil(json["abstract"]),
      published_at: published_at,
      period: if(published_at, do: Calendar.strftime(published_at, "%Y-%m"), else: "unknown"),
      item_attributes: attributes,
      labels: labels(status, related["obsoleted_by"]),
      content_path: content && elem(content, 0)
    }
  end

  defp labels(status, obsoleted_by) do
    status_label =
      if status, do: ["status:" <> (status |> String.downcase() |> String.replace(~r/\s+/, "-"))]

    List.wrap(status_label) ++ if(obsoleted_by == [], do: [], else: ["obsoleted"])
  end

  defp published_at(pub_date) when is_binary(pub_date) do
    with [_all, month, year] <- Regex.run(~r/(\p{L}+)\s+(\d{4})\s*$/u, pub_date),
         index when is_integer(index) <- Enum.find_index(@months, &(&1 == month)),
         {:ok, date} <- Date.new(String.to_integer(year), index + 1, 1) do
      DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    else
      _unparsable -> nil
    end
  end

  defp published_at(_pub_date), do: nil

  defp related_ids(ids) do
    for id <- strings(ids) do
      case Regex.run(~r/^RFC0*(\d+)$/i, id) do
        [_all, number] -> "rfc" <> number
        nil -> String.downcase(id)
      end
    end
  end

  defp strings(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp strings(_other), do: []

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _other -> nil
    end
  end

  defp integer(_value), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  # Markdown cache: <mirror>/markdown/rfc<n>.<html|txt>.md, regenerated when
  # missing or older than its source, and all of it when VERSION changes.
  defp prepare_markdown_dir!(mirror) do
    dir = Path.join(mirror, "markdown")
    version_file = Path.join(dir, "VERSION")

    if File.read(version_file) != {:ok, "#{@converter_version}\n"} do
      File.rm_rf!(dir)
      File.mkdir_p!(dir)
      File.write!(version_file, "#{@converter_version}\n")
    end

    dir
  end

  defp markdown!(mirror, dir, number, v3?) do
    html = Path.join(mirror, "rfc#{number}.html")
    txt = Path.join(mirror, "rfc#{number}.txt")

    if v3? and File.regular?(html),
      do: from_html(dir, number, html) || from_text(dir, number, txt),
      else: from_text(dir, number, txt)
  end

  defp from_html(dir, number, html) do
    cached(Path.join(dir, "rfc#{number}.html.md"), html, "html", fn ->
      case Documents.extract(html, mime_type: "text/html") do
        {:ok, %{content: markdown}} ->
          {:ok, Markdown.clean_html(markdown)}

        {:error, reason} ->
          Logger.warning("RFC #{number}: HTML not converted (#{inspect(reason)}), using text")
          :error
      end
    end)
  end

  defp from_text(dir, number, txt) do
    if File.regular?(txt) do
      cached(Path.join(dir, "rfc#{number}.txt.md"), txt, "text", fn ->
        {:ok, txt |> File.read!() |> Markdown.from_text()}
      end)
    end
  end

  defp cached(path, source, source_name, convert) do
    if fresh?(path, source) do
      {path, source_name}
    else
      case convert.() do
        {:ok, markdown} ->
          File.write!(path, markdown)
          {path, source_name}

        :error ->
          nil
      end
    end
  end

  defp fresh?(path, source) do
    with {:ok, %File.Stat{mtime: cached}} <- File.stat(path, time: :posix),
         {:ok, %File.Stat{mtime: original}} <- File.stat(source, time: :posix) do
      cached >= original
    else
      _missing -> false
    end
  end

  defp config, do: Application.get_env(:singularity, __MODULE__, [])
  defp rsync, do: Keyword.get(config(), :rsync, Singularity.Collectors.IetfRfc.Rsync)
  defp request_interval, do: Keyword.get(config(), :request_interval, :timer.seconds(60))
end
