defmodule Singularity.Knowledge.FetchReadmeWorker do
  @moduledoc """
  Fetches a GitHub project's README. A repository without one is recorded as
  fetched with no README; rate limits snooze; other failures are retried.
  """

  use Styx.Worker,
    queue: :details,
    max_attempts: 5,
    unique: [keys: [:item_id], states: :incomplete, period: :infinity]

  alias Singularity.{GitHub, Knowledge, Settings}

  @impl Styx.Worker
  def perform(%Styx.Job{args: %{"item_id" => item_id}}) do
    case Knowledge.get_project(item_id) do
      nil ->
        {:cancel, :project_not_found}

      project ->
        if Knowledge.details_supported?(project),
          do: fetch(project),
          else: {:cancel, :details_unsupported}
    end
  end

  defp fetch(project) do
    ["github.com", owner, repo] = String.split(project.external_id, "/")

    case GitHub.fetch_readme(owner, repo, token: Settings.get_github_token()) do
      {:ok, readme} ->
        {:ok, _project} = Knowledge.put_readme(project, readme, DateTime.utc_now())
        :ok

      {:error, :not_found} ->
        {:ok, _project} = Knowledge.put_readme(project, nil, DateTime.utc_now())
        :ok

      {:error, {:rate_limited, seconds}} ->
        {:snooze, seconds}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
