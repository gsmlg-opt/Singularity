defmodule Singularity.Knowledge.Address do
  @moduledoc """
  Normalizes git repository addresses into the key that identifies a software
  project: the lowercase `host/path`, without user, port, query or `.git`.

  A bare `owner/repo` means GitHub. GitHub addresses keep only `owner/repo`;
  other hosts keep the whole path (GitLab has nested groups).
  """

  @url ~r/^(https?|ssh|git):\/\/(?:[^@\/\s]+@)?([^\/:\s]+)(?::(\d+))?(\/.*)?$/i
  @scp ~r/^(?:[^@\/\s]+@)?([^\/:\s]+\.[^\/:\s]+):(?!\/)(.+)$/
  @host_path ~r/^([^\/:@\s]+\.[^\/:@\s]+)(\/.*)$/
  @bare ~r/^[^\/.:@\s]+\/[^\/:@\s]+$/
  @segment ~r/^[A-Za-z0-9._~-]+$/
  @owner ~r/^[A-Za-z0-9][A-Za-z0-9-]{0,38}$/
  @repo ~r/^[A-Za-z0-9._-]{1,100}$/

  @type t :: %{
          external_id: String.t(),
          host: String.t(),
          path: String.t(),
          url: String.t(),
          github?: boolean()
        }

  @spec normalize(term()) :: {:ok, t()} | {:error, :unsupported_address}
  def normalize(input) when is_binary(input) do
    input = String.trim(input)

    case split(input) do
      {scheme, host, port, path} -> build(input, scheme, String.downcase(host), port, path)
      nil -> {:error, :unsupported_address}
    end
  end

  def normalize(_input), do: {:error, :unsupported_address}

  # {scheme, host, port, path}; scheme is nil for forms that are not web URLs.
  defp split(input) do
    cond do
      match = Regex.run(@url, input) ->
        [_all, scheme, host | rest] = match ++ List.duplicate("", 2)
        [port, path | _] = rest
        {String.downcase(scheme), host, port, path}

      match = Regex.run(@scp, input) ->
        [_all, host, path] = match
        {:scp, host, "", path}

      match = Regex.run(@host_path, input) ->
        [_all, host, path] = match
        {"https", host, "", path}

      Regex.match?(@bare, input) ->
        {"https", "github.com", "", input}

      true ->
        nil
    end
  end

  defp build(input, scheme, host, port, path) do
    host = String.replace_prefix(host, "www.", "")
    [path | _query_or_fragment] = String.split(path, ["?", "#"], parts: 2)
    segments = String.split(path, "/", trim: true)

    with {:ok, segments} <- segments(host, segments) do
      path = Enum.join(segments, "/")

      {:ok,
       %{
         external_id: String.downcase(host <> "/" <> path),
         host: host,
         path: path,
         url: url(input, scheme, host, port, path),
         github?: host == "github.com"
       }}
    end
  end

  defp segments("github.com", [owner, repo | _rest]) do
    repo = String.replace_suffix(repo, ".git", "")

    if Regex.match?(@owner, owner) and Regex.match?(@repo, repo) and repo not in [".", ".."],
      do: {:ok, [owner, repo]},
      else: {:error, :unsupported_address}
  end

  defp segments("github.com", _segments), do: {:error, :unsupported_address}
  defp segments(_host, []), do: {:error, :unsupported_address}

  defp segments(_host, segments) do
    segments = List.update_at(segments, -1, &String.replace_suffix(&1, ".git", ""))

    if Enum.all?(segments, &(Regex.match?(@segment, &1) and &1 not in [".", ".."])),
      do: {:ok, segments},
      else: {:error, :unsupported_address}
  end

  defp url(_input, _scheme, "github.com", _port, path), do: "https://github.com/" <> path

  defp url(_input, scheme, host, port, path) when scheme in ["http", "https"],
    do: "#{scheme}://#{host}#{if port != "", do: ":" <> port}/#{path}"

  # ssh, git and scp addresses have no web page; keep what the user typed.
  defp url(input, _scheme, _host, _port, _path), do: input
end
