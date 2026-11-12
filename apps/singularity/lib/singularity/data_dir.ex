defmodule Singularity.DataDir do
  @moduledoc """
  The one root directory for synced files (`config :singularity, :data_dir`,
  `DATA_DIR` in production). Each feature keeps its files in a fixed
  subdirectory, e.g. `ietf-rfcs`.
  """

  @doc "`<data_dir>/<name>`, created if missing."
  @spec path!(String.t()) :: Path.t()
  def path!(name) when is_binary(name) and name != "" do
    path = Path.join(root(), name)
    File.mkdir_p!(path)
    path
  end

  @spec root() :: Path.t()
  def root, do: Application.fetch_env!(:singularity, :data_dir)
end
