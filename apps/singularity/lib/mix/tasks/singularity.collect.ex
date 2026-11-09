defmodule Mix.Tasks.Singularity.Collect do
  @shortdoc "Collects one source immediately, bypassing the job queue"
  @moduledoc "Usage: mix singularity.collect SOURCE_ID"

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run([id]) do
    source = Singularity.Sources.get_source!(String.to_integer(id))

    case Singularity.Collection.run(source) do
      {:ok, run} -> Mix.shell().info("ok: #{run.item_count} items, #{run.skipped_count} skipped")
      {:error, _reason, run} -> Mix.raise("failed: #{run.error}")
      {:error, :unavailable} -> Mix.raise("source type #{source.kind} is not registered")
    end
  end

  def run(_args), do: Mix.raise("usage: mix singularity.collect SOURCE_ID")
end
