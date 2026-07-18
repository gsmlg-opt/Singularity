defmodule Singularity.Storage.FailureInjector do
  @moduledoc false

  def run!(configured_point, point) when configured_point == point do
    raise "injected failure at #{point}"
  end

  def run!(_configured_point, _point), do: :ok
end
