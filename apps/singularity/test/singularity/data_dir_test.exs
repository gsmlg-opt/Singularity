defmodule Singularity.DataDirTest do
  use ExUnit.Case, async: true

  alias Singularity.DataDir

  test "path!/1 is a subdirectory of the root and exists" do
    name = "data-dir-test-#{System.unique_integer([:positive])}"
    path = DataDir.path!(name)
    on_exit(fn -> File.rm_rf!(path) end)

    assert path == Path.join(DataDir.root(), name)
    assert File.dir?(path)
  end
end
