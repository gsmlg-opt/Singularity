defmodule Singularity.CollectorTest do
  use ExUnit.Case, async: true

  alias Singularity.Collector

  test "fetch_module/1 resolves registered kinds" do
    assert {:ok, Singularity.Test.FakeCollector} = Collector.fetch_module("fake")
    assert :error = Collector.fetch_module("unknown")
  end

  test "all/0 lists registered collectors" do
    assert Singularity.Test.FakeCollector in Collector.all()
  end
end
