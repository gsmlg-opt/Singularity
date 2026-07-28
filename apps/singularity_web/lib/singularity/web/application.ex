defmodule Singularity.Web.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Singularity.Web.PubSub},
      Singularity.Web.Endpoint
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Singularity.Web.Supervisor
    )
  end

  @impl true
  def config_change(changed, _new, removed) do
    Singularity.Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
