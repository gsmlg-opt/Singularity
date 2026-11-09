defmodule Singularity.KnowledgeQueryTest do
  use Singularity.DataCase, async: true

  import Singularity.Fixtures

  alias Singularity.Collector.Result
  alias Singularity.Knowledge
  alias Singularity.Test.FakeCollector

  defp record!(source, period, at, ids) do
    entries = ids |> Enum.with_index(1) |> Enum.map(fn {id, r} -> FakeCollector.entry(id, r) end)
    {:ok, _} = Knowledge.record(source, %Result{period: period, entries: entries}, at)
  end

  setup do
    source = source_fixture()
    record!(source, "2026-11-09", ~U[2026-11-09 08:00:00Z], ["a", "b"])
    record!(source, "2026-11-10", ~U[2026-11-10 08:00:00Z], ["c", "a"])
    %{source: source}
  end

  test "list_items/1 orders by most recent observation, one row per item" do
    # c and a share the latest observed_at; ties break by item id, newest first.
    assert Knowledge.list_items() |> Enum.map(& &1.item.external_id) == ["c", "a", "b"]
  end

  test "list_items/1 filters by date range and kind" do
    ids =
      Knowledge.list_items(from: ~D[2026-11-09], to: ~D[2026-11-09])
      |> Enum.map(& &1.item.external_id)

    assert Enum.sort(ids) == ["a", "b"]
    assert Knowledge.list_items(kind: "other") == []
  end

  test "list_items/1 paginates" do
    assert length(Knowledge.list_items(per_page: 2, page: 1)) == 2
    assert length(Knowledge.list_items(per_page: 2, page: 2)) == 1
  end

  test "latest_period/1 and list_period/2 return the latest ranked list", %{source: source} do
    assert Knowledge.latest_period(source.id) == "2026-11-10"
    rows = Knowledge.list_period(source.id, "2026-11-10")
    assert Enum.map(rows, &{&1.rank, &1.item.external_id}) == [{1, "c"}, {2, "a"}]
  end

  test "list_observations/1 returns history newest first with sources" do
    [%{item: item}] = Knowledge.list_items() |> Enum.filter(&(&1.item.external_id == "a"))
    history = Knowledge.list_observations(item.id)
    assert Enum.map(history, & &1.period) == ["2026-11-10", "2026-11-09"]
    assert hd(history).source.name == "Fake source"
  end

  test "list_item_kinds/0" do
    assert Knowledge.list_item_kinds() == ["fake_item"]
  end
end
