defmodule Singularity.Collectors.GithubStars do
  @moduledoc """
  Collects every repository a GitHub user has starred. The result is the
  complete list, so a repository the user unstars leaves this source. Each star
  carries the full repository object, stored as the project's details.
  """

  @behaviour Singularity.Collector

  alias Singularity.Collector.{Entry, Result}
  alias Singularity.{GitHub, Settings}
  alias Singularity.Knowledge.Address

  @login ~r/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$/
  # 10,000 stars; beyond this the list would be partial, so the fetch fails.
  @max_pages 100
  @per_page GitHub.per_page()

  @impl true
  def kind, do: "github_stars"

  @impl true
  def queue, do: :github_api

  @impl true
  def label, do: "GitHub Stars"

  @impl true
  def config_fields do
    [%{name: :user, type: :string, label: "GitHub user", required: true, options: []}]
  end

  @impl true
  def default_interval_minutes, do: 1440

  @impl true
  def validate_config(config) when is_map(config) do
    user = config |> Map.get("user", "") |> to_string() |> String.trim()

    cond do
      user == "" -> {:error, [{:user, "can't be blank"}]}
      Regex.match?(@login, user) -> {:ok, %{"user" => user}}
      true -> {:error, [{:user, "is not a GitHub user name"}]}
    end
  end

  @impl true
  def fetch(%{"user" => user}, now) do
    with {:ok, stars} <- fetch_pages(user, 1, [], token: Settings.get_github_token(), now: now) do
      {entries, skipped} = parse(stars, user)
      period = now |> DateTime.to_date() |> Date.to_iso8601()
      {:ok, %Result{period: period, entries: entries, skipped: skipped, complete: true}}
    end
  end

  defp fetch_pages(_user, page, _acc, _opts) when page > @max_pages,
    do: {:error, :too_many_stars}

  defp fetch_pages(user, page, acc, opts) do
    # The github_api queue runs one job at a time; spacing the pages keeps this job
    # within the same request budget as single-request jobs.
    if page > 1, do: Process.sleep(page_interval())

    case GitHub.fetch_starred(user, page, opts) do
      {:ok, stars} when length(stars) < @per_page ->
        {:ok, Enum.concat(Enum.reverse([stars | acc]))}

      {:ok, stars} ->
        fetch_pages(user, page + 1, [stars | acc], opts)

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Pure parser for `GET /users/:user/starred` (star media type) elements:
  returns the entries and the number of unusable elements.
  """
  @spec parse([term()], String.t()) :: {[Entry.t()], non_neg_integer()}
  def parse(stars, user) when is_list(stars) do
    {entries, skipped} =
      Enum.reduce(stars, {[], 0}, fn star, {entries, skipped} ->
        case parse_star(star, user) do
          {:ok, entry} -> {[entry | entries], skipped}
          :error -> {entries, skipped + 1}
        end
      end)

    {Enum.reverse(entries), skipped}
  end

  defp parse_star(
         %{"starred_at" => starred_at, "repo" => %{"full_name" => full_name} = repo},
         user
       )
       when is_binary(starred_at) and is_binary(full_name) do
    with {:ok, starred, _offset} <- DateTime.from_iso8601(starred_at),
         {:ok, %{github?: true} = address} <- Address.normalize(full_name) do
      details = GitHub.parse_repo(repo)

      {:ok,
       %Entry{
         item_kind: "software_project",
         external_id: address.external_id,
         title: full_name,
         url: address.url,
         summary: details.summary,
         period: starred |> DateTime.to_date() |> Date.to_iso8601(),
         details: details,
         item_attributes: details.attributes,
         observation_attributes: %{"user" => user, "starred_at" => starred_at},
         raw: %{"full_name" => full_name, "starred_at" => starred_at}
       }}
    else
      _invalid -> :error
    end
  end

  defp parse_star(_star, _user), do: :error

  defp page_interval,
    do: :singularity |> Application.get_env(__MODULE__, []) |> Keyword.get(:page_interval, 2_000)
end
