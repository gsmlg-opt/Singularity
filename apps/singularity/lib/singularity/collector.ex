defmodule Singularity.Collector do
  @moduledoc """
  The only extension point for new source types.

  A collector fetches and parses; it never touches the database. Register
  implementations under `config :singularity, :collectors`.
  """

  alias Singularity.Collector.Result

  @type field :: %{
          name: atom(),
          type: :string | :select | :integer,
          label: String.t(),
          required: boolean(),
          options: [String.t()]
        }

  @callback kind() :: String.t()
  @callback label() :: String.t()
  @callback config_fields() :: [field()]
  @callback default_interval_minutes() :: pos_integer()
  @callback validate_config(map()) :: {:ok, map()} | {:error, [{atom(), String.t()}]}
  @callback fetch(config :: map(), now :: DateTime.t()) :: {:ok, Result.t()} | {:error, term()}

  @spec all() :: [module()]
  def all, do: Application.get_env(:singularity, :collectors, [])

  @spec fetch_module(String.t()) :: {:ok, module()} | :error
  def fetch_module(kind) when is_binary(kind) do
    case Enum.find(all(), &(&1.kind() == kind)) do
      nil -> :error
      module -> {:ok, module}
    end
  end
end
