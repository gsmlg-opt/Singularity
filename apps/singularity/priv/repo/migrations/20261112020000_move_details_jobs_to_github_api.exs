defmodule Singularity.Repo.Migrations.MoveDetailsJobsToGithubApi do
  use Ecto.Migration

  # The details queue is gone; its pending jobs now run in the rate-limited github_api queue.
  def up do
    execute """
    UPDATE styx_jobs SET queue = 'github_api'
    WHERE queue = 'details' AND state IN ('available', 'scheduled', 'retryable')
    """
  end

  def down do
    execute """
    UPDATE styx_jobs SET queue = 'details'
    WHERE queue = 'github_api' AND state IN ('available', 'scheduled', 'retryable')
    """
  end
end
