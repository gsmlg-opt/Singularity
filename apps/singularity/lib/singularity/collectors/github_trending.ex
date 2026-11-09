defmodule Singularity.Collectors.GithubTrending do
  @moduledoc "Collects https://github.com/trending (optionally per language and range)."

  @behaviour Singularity.Collector

  alias Singularity.Collector.{Entry, Result}

  @base_url "https://github.com/trending"
  @since_values ~w(daily weekly monthly)
  @stars_in_period ~r/([\d,]+)\s+stars?\s+(?:today|this week|this month)/

  @impl true
  def kind, do: "github_trending"

  @impl true
  def label, do: "GitHub Trending"

  @impl true
  def config_fields do
    [
      %{name: :language, type: :string, label: "语言（留空表示全部）", required: false, options: []},
      %{name: :since, type: :select, label: "时间范围", required: true, options: @since_values}
    ]
  end

  @impl true
  def default_interval_minutes, do: 1440

  @impl true
  def validate_config(config) when is_map(config) do
    language =
      config |> Map.get("language", "") |> to_string() |> String.trim() |> String.downcase()

    since = config |> Map.get("since", "daily") |> to_string()

    errors =
      [
        unless(language == "" or Regex.match?(~r/^[a-z0-9+#.\-]+$/, language),
          do: {:language, "contains invalid characters"}
        ),
        unless(since in @since_values, do: {:since, "must be one of daily, weekly, monthly"})
      ]
      |> Enum.reject(&is_nil/1)

    if errors == [],
      do: {:ok, %{"language" => language, "since" => since}},
      else: {:error, errors}
  end

  @impl true
  def fetch(config, now) do
    request = [user_agent: "Singularity", retry: false] ++ req_options()

    case Req.get(trending_url(config), request) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {entries, skipped} = parse(body, config["since"])
        period = now |> DateTime.to_date() |> Date.to_iso8601()
        {:ok, %Result{period: period, entries: entries, skipped: skipped}}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, exception} ->
        {:error, {:transport, Exception.message(exception)}}
    end
  end

  def trending_url(config) do
    base =
      case config["language"] do
        language when language in [nil, ""] -> @base_url
        language -> @base_url <> "/" <> URI.encode(language, &URI.char_unreserved?/1)
      end

    base <> "?" <> URI.encode_query(%{"since" => config["since"] || "daily"})
  end

  @doc "Pure parser: returns entries ranked by page position and the number of unparseable rows."
  @spec parse(String.t(), String.t() | nil) :: {[Entry.t()], non_neg_integer()}
  def parse(html, since) do
    case Floki.parse_document(html) do
      {:ok, document} ->
        document
        |> Floki.find("article.Box-row")
        |> Enum.with_index(1)
        |> Enum.reduce({[], 0}, fn {row, rank}, {entries, skipped} ->
          case parse_row(row, rank, since) do
            {:ok, entry} -> {[entry | entries], skipped}
            :error -> {entries, skipped + 1}
          end
        end)
        |> then(fn {entries, skipped} -> {Enum.reverse(entries), skipped} end)

      {:error, _reason} ->
        {[], 0}
    end
  end

  defp parse_row(row, rank, since) do
    with [href | _] <- Floki.attribute(row, "h2 a", "href"),
         "/" <> path <- String.trim(href),
         [owner, repo] <- String.split(path, "/", trim: true) do
      full_name = owner <> "/" <> repo
      summary = row |> Floki.find("p") |> Floki.text() |> squish()

      language =
        row |> Floki.find(~s([itemprop="programmingLanguage"])) |> Floki.text() |> squish()

      stars = link_count(row, "/stargazers")
      forks = link_count(row, "/forks")
      stars_in_period = row |> Floki.text() |> stars_in_period()

      {:ok,
       %Entry{
         item_kind: "github_repo",
         external_id: full_name,
         title: full_name,
         url: "https://github.com/" <> full_name,
         summary: summary,
         rank: rank,
         item_attributes: %{"language" => language, "stars" => stars, "forks" => forks},
         observation_attributes: %{
           "stars" => stars,
           "forks" => forks,
           "stars_in_period" => stars_in_period,
           "since" => since
         },
         raw: %{
           "owner" => owner,
           "repo" => repo,
           "description" => summary,
           "language" => language,
           "stars" => stars,
           "forks" => forks,
           "stars_in_period" => stars_in_period,
           "rank" => rank
         }
       }}
    else
      _ -> :error
    end
  end

  defp link_count(row, suffix) do
    row
    |> Floki.find("a")
    |> Enum.find(fn link ->
      link |> Floki.attribute("href") |> List.first("") |> String.ends_with?(suffix)
    end)
    |> case do
      nil -> nil
      link -> link |> Floki.text() |> to_integer()
    end
  end

  defp stars_in_period(text) do
    case Regex.run(@stars_in_period, text) do
      [_, count] -> to_integer(count)
      nil -> nil
    end
  end

  defp to_integer(text) do
    case text |> String.replace(~r/[^\d]/, "") |> Integer.parse() do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp squish(text) do
    case text |> String.split() |> Enum.join(" ") do
      "" -> nil
      value -> value
    end
  end

  defp req_options do
    :singularity |> Application.get_env(__MODULE__, []) |> Keyword.get(:req_options, [])
  end
end
