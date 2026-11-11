defmodule Singularity.GitHub.Quota do
  @moduledoc """
  Keeps the GitHub API quota reported by the last response (`x-ratelimit-*`
  headers) and holds requests back while less than 10% of it is left, until
  the quota resets. The table is owned by a process in the supervision tree.
  """
  use GenServer

  @threshold 0.1

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  @impl GenServer
  def init(table) do
    :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, table}
  end

  @doc "Records the quota from a response's headers; responses without them are ignored."
  @spec record(atom(), HTTP.Headers.t()) :: :ok
  def record(table, headers) do
    with remaining when is_integer(remaining) <- header(headers, "x-ratelimit-remaining"),
         limit when is_integer(limit) and limit > 0 <- header(headers, "x-ratelimit-limit"),
         reset when is_integer(reset) <- header(headers, "x-ratelimit-reset") do
      :ets.insert(table, {:quota, remaining, limit, reset})
    end

    :ok
  end

  @doc "`:ok`, or how long to wait while the remaining quota is below the threshold."
  @spec check(atom(), DateTime.t()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def check(table, %DateTime{} = now) do
    case :ets.lookup(table, :quota) do
      [{:quota, remaining, limit, reset}] ->
        wait = reset - DateTime.to_unix(now)

        if remaining < limit * @threshold and wait > 0,
          do: {:error, {:rate_limited, wait}},
          else: :ok

      [] ->
        :ok
    end
  end

  defp header(headers, name) do
    with value when is_binary(value) <- HTTP.Headers.get(headers, name),
         {integer, ""} <- Integer.parse(String.trim(value)) do
      integer
    else
      _missing -> nil
    end
  end
end
