defmodule Singularity.Knowledge.Address do
  @moduledoc """
  Normalizes GitHub repository addresses into the `github.com/<owner>/<repo>`
  key (lowercase) that identifies a software project. Other hosts are not
  supported yet.
  """

  @scp ~r/^git@github\.com:(.+)$/i
  @url ~r/^(?:https?:\/\/)?(?:www\.)?github\.com\/(.*)$/i
  @bare ~r/^[^\/.:@\s]+\/[^\/:@\s]+$/
  @owner ~r/^[A-Za-z0-9][A-Za-z0-9-]{0,38}$/
  @repo ~r/^[A-Za-z0-9._-]{1,100}$/

  @type t :: %{external_id: String.t(), owner: String.t(), repo: String.t(), url: String.t()}

  @spec normalize(term()) :: {:ok, t()} | {:error, :unsupported_address}
  def normalize(input) when is_binary(input), do: input |> String.trim() |> path() |> parse()
  def normalize(_input), do: {:error, :unsupported_address}

  defp path(text) do
    case {Regex.run(@scp, text), Regex.run(@url, text)} do
      {[_, path], _} -> path
      {nil, [_, path]} -> path
      {nil, nil} -> if Regex.match?(@bare, text), do: text
    end
  end

  defp parse(nil), do: {:error, :unsupported_address}

  defp parse(path) do
    [path | _query_or_fragment] = String.split(path, ["?", "#"], parts: 2)

    case String.split(path, "/", trim: true) do
      [owner, repo | _rest] -> build(owner, String.replace_suffix(repo, ".git", ""))
      _ -> {:error, :unsupported_address}
    end
  end

  defp build(owner, repo) do
    if Regex.match?(@owner, owner) and Regex.match?(@repo, repo) and repo not in [".", ".."] do
      {:ok,
       %{
         external_id: String.downcase("github.com/#{owner}/#{repo}"),
         owner: owner,
         repo: repo,
         url: "https://github.com/#{owner}/#{repo}"
       }}
    else
      {:error, :unsupported_address}
    end
  end
end
