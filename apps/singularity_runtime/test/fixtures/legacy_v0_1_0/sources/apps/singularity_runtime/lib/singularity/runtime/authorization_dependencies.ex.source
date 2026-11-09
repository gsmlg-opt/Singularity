defmodule Singularity.Runtime.AuthorizationDependencies do
  @moduledoc false

  alias Singularity.Core.Error

  @enforce_keys [:store, :custodian]
  defstruct @enforce_keys

  @type t :: %__MODULE__{store: term(), custodian: term()}

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(%{store: store, custodian: custodian}) do
    if concrete?(store) and concrete?(custodian) do
      {:ok, %__MODULE__{store: store, custodian: custodian}}
    else
      {:error, Error.new(:job_failed)}
    end
  end

  def new(_dependencies), do: {:error, Error.new(:job_failed)}

  defp concrete?(value), do: value not in [nil, false]
end
