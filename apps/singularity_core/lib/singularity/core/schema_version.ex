defmodule Singularity.Core.SchemaVersion do
  @moduledoc "Validates PRD-001 canonical schema versions."

  alias Singularity.Core.Error

  @current 1

  @spec current() :: pos_integer()
  def current, do: @current

  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(@current), do: :ok

  def validate(version) do
    {:error, Error.new(:invalid, details: %{schema_version: version})}
  end
end
