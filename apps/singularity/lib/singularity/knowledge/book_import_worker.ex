defmodule Singularity.Knowledge.BookImportWorker do
  @moduledoc "Imports an SSH directory one EPUB at a time."

  use Styx.Worker,
    queue: :book_import,
    max_attempts: 1,
    unique: [keys: [:location], states: :incomplete, period: :infinity]

  import Ecto.Query

  alias Singularity.{DataDir, Knowledge, Repo}
  alias Singularity.Knowledge.BookImportSSH

  @impl true
  def perform(%Styx.Job{args: %{"location" => location}} = job) do
    heartbeat = spawn_link(fn -> heartbeat(job) end)

    try do
      import_directory(job, location)
    after
      send(heartbeat, :stop)
    end
  end

  defp import_directory(job, location) do
    ssh = Application.get_env(:singularity, :book_import_ssh, BookImportSSH)

    with {:ok, host, directory} <- BookImportSSH.parse(location),
         {:ok, paths} <- ssh.list(host, directory) do
      destination = Path.join(DataDir.path!("book-imports"), "job-#{job.id}.epub")
      counts = %{"total" => length(paths), "imported" => 0, "duplicates" => 0, "failed" => 0}
      record_progress!(job, counts)

      Enum.reduce(paths, counts, fn path, counts ->
        result = import_file(ssh, host, path, destination)
        counts = Map.update!(counts, result, &(&1 + 1))
        record_progress!(job, counts)
        counts
      end)

      :ok
    end
  end

  defp import_file(ssh, host, path, destination) do
    try do
      with :ok <- ssh.fetch(host, path, destination) do
        Knowledge.import_staged_book(destination, Path.basename(path))
      end
      |> case do
        {:ok, _book} -> "imported"
        {:existing, _book} -> "duplicates"
        {:error, _reason} -> "failed"
      end
    after
      File.rm(destination)
    end
  end

  defp record_progress!(job, counts) do
    {:ok, _job} = Styx.update_job(job, %{meta: Map.put(job.meta, "book_import", counts)})
  end

  # Lifeline ages executing jobs by attempted_at, including active transfers.
  defp heartbeat(job) do
    receive do
      :stop -> :ok
    after
      :timer.minutes(1) ->
        from(j in Styx.Job,
          where: j.id == ^job.id and j.state == "executing" and j.attempt == ^job.attempt
        )
        |> Repo.update_all(set: [attempted_at: DateTime.utc_now()])

        heartbeat(job)
    end
  end
end
