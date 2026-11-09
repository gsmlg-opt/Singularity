defmodule Singularity.Runtime.StorageAdapter do
  @moduledoc "Resolves the configured object-storage adapter and its runtime context."

  alias Singularity.Storage.LocalFilesystemAdapter

  # WORKAROUND(upstream): gsmlg-opt/ex_storage_service#5
  @spec configured() :: {module(), map()}
  def configured do
    adapter =
      Application.get_env(
        :singularity_runtime,
        :storage_adapter,
        LocalFilesystemAdapter
      )

    root = Application.fetch_env!(:singularity_storage, :storage_root)
    {adapter, %{root: root}}
  end
end
