defmodule Singularity.SchemaTest do
  use Singularity.DataCase, async: true

  import Singularity.Fixtures

  alias Singularity.Knowledge.{Item, Observation}
  alias Singularity.Repo

  defp item_attrs(external_id) do
    %{
      kind: "fake_item",
      external_id: external_id,
      title: "T",
      url: "https://example.test",
      first_seen_at: now(),
      last_seen_at: now()
    }
  end

  test "items are unique per kind and external_id" do
    Repo.insert!(Item.changeset(%Item{}, item_attrs("a")))
    assert {:error, changeset} = Repo.insert(Item.changeset(%Item{}, item_attrs("a")))
    assert %{kind: ["has already been taken"]} = errors_on(changeset)
  end

  test "observations are unique per source, item and period; deleting a source cascades" do
    source = source_fixture()
    item = Repo.insert!(Item.changeset(%Item{}, item_attrs("a")))
    attrs = %{item_id: item.id, source_id: source.id, period: "2026-11-09", observed_at: now()}

    Repo.insert!(Observation.changeset(%Observation{}, attrs))
    assert {:error, _} = Repo.insert(Observation.changeset(%Observation{}, attrs))

    fetch_run_fixture(source)
    Repo.delete!(source)

    assert Repo.aggregate(Observation, :count) == 0
    assert Repo.aggregate(Singularity.Collection.FetchRun, :count) == 0
    assert Repo.get(Item, item.id)
  end
end
