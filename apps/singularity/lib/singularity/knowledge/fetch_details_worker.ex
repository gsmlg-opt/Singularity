defmodule Singularity.Knowledge.FetchDetailsWorker do
  @moduledoc """
  Fetches a software project's GitHub details and recomputes its automatic
  labels. Rate limits snooze the job; a missing repository is recorded and not
  retried; other failures are recorded and retried by Styx.
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

    case GitHub.fetch_repo(owner, repo, token: Settings.get_github_token()) do
      {:ok, details} ->
        {:ok, _project} = Knowledge.put_details(project, details, DateTime.utc_now())
        :ok

      {:error, {:rate_limited, seconds}} ->
        {:snooze, seconds}

      {:error, :not_found} ->
        {:ok, _project} = Knowledge.put_details_error(project, "repository not found")
        :ok

      {:error, reason} ->
        {:ok, _project} = Knowledge.put_details_error(project, describe(reason))
        {:error, reason}
    end
  end

  defp describe({:http_status, status}), do: "GitHub returned HTTP #{status}"
  defp describe({:transport, message}), do: "transport error: " <> message
  defp describe(:invalid_response), do: "GitHub returned an unreadable response"
end
