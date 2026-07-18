defmodule Singularity.Storage.DataCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  using do
    quote do
      import Singularity.Storage.DataCase

      alias Singularity.Storage.DispatcherRepo
      alias Singularity.Storage.PreAuthRepo
      alias Singularity.Storage.RequestRepo
      alias Singularity.Storage.WorkerRepo
    end
  end

  @spec query!(module(), String.t(), list()) :: Postgrex.Result.t()
  def query!(repo, statement, parameters \\ []) do
    Ecto.Adapters.SQL.query!(repo, statement, parameters, log: false)
  end
end
