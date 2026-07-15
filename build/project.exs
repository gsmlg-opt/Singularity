defmodule Singularity.Build do
  @moduledoc false

  @elixir_requirement "~> 1.18"
  @elixir_version "1.18.4"
  @otp_version "28"

  def elixir_requirement, do: @elixir_requirement
  def elixir_version, do: @elixir_version
  def otp_version, do: @otp_version
end
