defmodule Singularity.KnowledgeRecordTest do
  use Singularity.DataCase, async: true

  import Singularity.Fixtures

  alias Singularity.Collector.Result
  alias Singularity.Knowledge
  alias Singularity.Knowledge.{Item, Observation}
  alias Singularity.Repo
  alias Singularity.Test.FakeCollector

  @t1 ~U[2026-11-09 08:00:00Z]
  @t2 ~U[2026-11-10 08:00:00Z]

  defp result(period, ids),
    do: %Result{
      period: period,
      entries: Enum.with_index(ids, 1) |> Enum.map(fn {id, r} -> FakeCollector.entry(id, r) end)
    }

  test "creates items and observations" do
    source = source_fixture()
    assert {:ok, 2} = Knowledge.record(source, result("2026-11-09", ["a", "b"]), @t1)

    assert Repo.aggregate(Item, :count) == 2
    obs = Repo.all(Observation)
    assert Enum.map(obs, & &1.period) == ["2026-11-09", "2026-11-09"]
    assert Enum.sort(Enum.map(obs, & &1.rank)) == [1, 2]
  end

  test "re-recording the same period is idempotent" do
    source = source_fixture()
    {:ok, _} = Knowledge.record(source, result("2026-11-09", ["a"]), @t1)
    {:ok, _} = Knowledge.record(source, result("2026-11-09", ["a"]), @t1)

    assert Repo.aggregate(Item, :count) == 1
    assert Repo.aggregate(Observation, :count) == 1
  end

  test "a new period appends an observation and updates last_seen_at only" do
    source = source_fixture()
    {:ok, _} = Knowledge.record(source, result("2026-11-09", ["a"]), @t1)
    {:ok, _} = Knowledge.record(source, result("2026-11-10", ["a"]), @t2)

    item = Repo.one!(Item)
    assert item.first_seen_at == @t1
    assert item.last_seen_at == @t2
    assert Repo.aggregate(Observation, :count) == 2
  end

  test "the same item from two sources is one item with two observations" do
    s1 = source_fixture()
    s2 = source_fixture(name: "Other")
    {:ok, _} = Knowledge.record(s1, result("2026-11-09", ["a"]), @t1)
    {:ok, _} = Knowledge.record(s2, result("2026-11-09", ["a"]), @t1)

    assert Repo.aggregate(Item, :count) == 1
    assert Repo.aggregate(Observation, :count) == 2
  end
end
