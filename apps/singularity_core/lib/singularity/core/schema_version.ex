defmodule Singularity.Core.SchemaVersion do
  @moduledoc "Validates PRD-001 canonical schema versions."

  alias Singularity.Core.Error

  @current 1

  @spec current() :: pos_integer()
  def current, do: @current

  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(@current), do: :ok

  def validate(version) when is_integer(version) and version > 0 do
    {:error, %Error{code: :unsupported, details: %{schema_version: version}}}
  end

  def validate(version) do
    {:error, %Error{code: :invalid, details: %{schema_version: version}}}
  end
end
