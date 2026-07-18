defmodule Singularity.Storage.ObjectStorageContractTest do
  Code.ensure_loaded!(Singularity.Storage.LocalFilesystemAdapter)

  use Singularity.Core.ObjectStorageContract,
    adapter: Singularity.Storage.LocalFilesystemAdapter,
    context: fn ->
      root =
        Path.join(
          System.tmp_dir!(),
          "singularity-#{System.unique_integer([:positive, :monotonic])}"
        )

      %{root: root}
    end
end
