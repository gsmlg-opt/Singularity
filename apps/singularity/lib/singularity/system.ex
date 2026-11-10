defmodule Singularity.System do
  @moduledoc """
  Read-only system status. Refer to it as `Singularity.System`: an alias would
  shadow Elixir's `System`.
  """

  import Ecto.Query

  alias Singularity.Repo

  @states ~w(available executing retryable)

  @type queue_status :: %{
          name: String.t(),
          available: non_neg_integer(),
          executing: non_neg_integer(),
          retryable: non_neg_integer()
        }

  @spec status() :: %{version: String.t(), queues: [queue_status()]}
  def status do
    counts =
      Styx.Job
      |> where([j], j.state in ^@states)
      |> group_by([j], [j.queue, j.state])
      |> select([j], {{j.queue, j.state}, count(j.id)})
      |> Repo.all()
      |> Map.new()

    configured =
      :singularity
      |> Application.fetch_env!(Styx)
      |> Keyword.fetch!(:queues)
      |> Enum.map(fn {name, _limit} -> Atom.to_string(name) end)

    names =
      (configured ++ Enum.map(Map.keys(counts), fn {queue, _state} -> queue end))
      |> Enum.uniq()
      |> Enum.sort()

    %{
      version: :singularity |> Application.spec(:vsn) |> to_string(),
      queues:
        Enum.map(names, fn name ->
          %{
            name: name,
            available: Map.get(counts, {name, "available"}, 0),
            executing: Map.get(counts, {name, "executing"}, 0),
            retryable: Map.get(counts, {name, "retryable"}, 0)
          }
        end)
    }
  end
end
