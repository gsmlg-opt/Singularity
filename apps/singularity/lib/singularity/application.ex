defmodule Singularity.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Singularity.Repo,
      {DNSCluster, query: Application.get_env(:singularity, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Singularity.PubSub}
      # Start a worker by calling: Singularity.Worker.start_link(arg)
      # {Singularity.Worker, arg}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Singularity.Supervisor)
  end
end
