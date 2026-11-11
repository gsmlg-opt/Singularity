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

  @doc """
  The Styx queue its collection jobs run in, so requests to one site share
  that queue's rate limit. Defaults to `:collect`.
  """
  @callback queue() :: atom()

  @optional_callbacks queue: 0

  @spec all() :: [module()]
  def all, do: Application.get_env(:singularity, :collectors, [])

  @doc "The queue for a collector module (`:collect` unless it defines `queue/0`)."
  @spec queue(module()) :: atom()
  def queue(collector) do
    if Code.ensure_loaded?(collector) and function_exported?(collector, :queue, 0),
      do: collector.queue(),
      else: :collect
  end

  @spec fetch_module(String.t()) :: {:ok, module()} | :error
  def fetch_module(kind) when is_binary(kind) do
    case Enum.find(all(), &(&1.kind() == kind)) do
      nil -> :error
      module -> {:ok, module}
    end
  end
end
