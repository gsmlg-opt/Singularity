defmodule Singularity.Core.Capability do
  @moduledoc "An exact, normalized capability key."

  alias Singularity.Core.Error
  alias Singularity.Core.Types

  @enforce_keys [:name]
  defstruct [:name]

  @type t :: %__MODULE__{name: String.t()}

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) do
    with {:ok, attrs} <- Types.attrs(attrs),
         {:ok, name} <- Types.normalized_string(attrs, :name) do
      {:ok, %__MODULE__{name: name}}
    end
  end

  @spec contains?([t()], String.t() | t()) :: boolean()
  def contains?(capabilities, %__MODULE__{name: required_name}),
    do: contains?(capabilities, required_name)

  def contains?(capabilities, required_name) when is_list(capabilities) do
    case Types.normalize_string(required_name) do
      {:ok, normalized} ->
        Enum.any?(capabilities, fn
          %__MODULE__{name: ^normalized} -> true
          _other -> false
        end)

      {:error, %Error{}} ->
        false
    end
  end

  def contains?(_capabilities, _required), do: false
end
