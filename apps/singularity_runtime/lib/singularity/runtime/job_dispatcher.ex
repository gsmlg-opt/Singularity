defmodule Singularity.Runtime.JobDispatcher do
  @moduledoc false

  @behaviour Singularity.Core.JobHandler

  alias Singularity.Core.Error
  alias Singularity.Runtime.Application, as: RuntimeApplication

  @impl true
  def dependencies, do: RuntimeApplication.job_dependencies()

  @impl true
  def handle(_context, _envelope), do: {:error, Error.new(:job_failed)}
end
