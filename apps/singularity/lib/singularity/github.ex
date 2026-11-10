defmodule Singularity.GitHub do
  @moduledoc """
  GitHub REST client on http_fetch. `fetch_repo/3` never raises; turning the
  JSON into project details is the pure `parse_repo/1`.
  """

  alias Singularity.HttpClient

  @api "https://api.github.com"

  @type details :: %{title: String.t() | nil, summary: String.t() | nil, attributes: map()}
  @type error ::
          :not_found
          | :invalid_response
          | {:rate_limited, pos_integer()}
          | {:http_status, pos_integer()}
          | {:transport, String.t()}

  @doc """
  `GET /repos/:owner/:repo`. Options: `:token` (sent as a bearer token when
  present) and `:now` (turns `x-ratelimit-reset` into a delay; defaults to now).
  """
  @spec fetch_repo(String.t(), String.t(), keyword()) :: {:ok, details()} | {:error, error()}
  def fetch_repo(owner, repo, opts \\ []) do
    url = "#{@api}/repos/#{encode(owner)}/#{encode(repo)}"

    headers =
      [{"Accept", "application/vnd.github+json"}, {"User-Agent", "Singularity"}] ++
        authorization(opts[:token])

    case HttpClient.get(url, headers, adapter()) do
      {:ok, %{status: 200, body: body}} ->
        decode(body)

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status, headers: response_headers}} when status in [403, 429] ->
        rate_limited(status, response_headers, Keyword.get(opts, :now, DateTime.utc_now()))

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, {:transport, _message}} = error ->
        error
    end
  end

  @doc "Pure: turns a `GET /repos/:owner/:repo` JSON object into project details."
  @spec parse_repo(map()) :: details()
  def parse_repo(json) when is_map(json) do
    %{
      title: json["full_name"],
      summary: blank_to_nil(json["description"]),
      attributes: %{
        "stars" => json["stargazers_count"],
        "forks" => json["forks_count"],
        "language" => json["language"],
        "topics" => topics(json["topics"]),
        "license" => license(json["license"]),
        "homepage" => blank_to_nil(json["homepage"]),
        "archived" => json["archived"] == true,
        "created_at" => json["created_at"],
        "pushed_at" => json["pushed_at"],
        "default_branch" => json["default_branch"]
      }
    }
  end

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, %{} = json} -> {:ok, parse_repo(json)}
      _other -> {:error, :invalid_response}
    end
  end

  defp rate_limited(status, headers, now) do
    case retry_after(headers) || until_reset(headers, now) do
      nil -> {:error, {:http_status, status}}
      seconds -> {:error, {:rate_limited, max(seconds, 1)}}
    end
  end

  defp retry_after(headers), do: headers |> HTTP.Headers.get("retry-after") |> to_integer()

  defp until_reset(headers, now) do
    with "0" <- HTTP.Headers.get(headers, "x-ratelimit-remaining"),
         reset when is_integer(reset) <-
           headers |> HTTP.Headers.get("x-ratelimit-reset") |> to_integer() do
      reset - DateTime.to_unix(now)
    else
      _no_reset -> nil
    end
  end

  defp to_integer(nil), do: nil

  defp to_integer(text) do
    case Integer.parse(String.trim(text)) do
      {value, ""} -> value
      _other -> nil
    end
  end

  defp topics(topics) when is_list(topics), do: Enum.filter(topics, &is_binary/1)
  defp topics(_topics), do: []

  defp license(%{"spdx_id" => id}) when is_binary(id) and id not in ["", "NOASSERTION"], do: id
  defp license(%{"name" => name}) when is_binary(name) and name != "", do: name
  defp license(_license), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil

  defp authorization(token) when is_binary(token) and token != "",
    do: [{"Authorization", "Bearer " <> token}]

  defp authorization(_token), do: []

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  defp adapter, do: :singularity |> Application.get_env(__MODULE__, []) |> Keyword.get(:adapter)
end
