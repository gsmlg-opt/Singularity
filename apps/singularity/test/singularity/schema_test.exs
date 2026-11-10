defmodule Singularity.SchemaTest do
  use Singularity.DataCase, async: true

  import Singularity.Fixtures

  alias Singularity.Knowledge.{Item, Label, Observation}
  alias Singularity.Settings.Setting
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

  test "labels are normalized, unique per item and name, and deleted with the item" do
    item = Repo.insert!(Item.changeset(%Item{}, item_attrs("a")))
    attrs = %{item_id: item.id, name: "  Lang:Elixir ", origin: "manual"}

    label = Repo.insert!(Label.changeset(%Label{}, attrs))
    assert label.name == "lang:elixir"

    assert {:error, changeset} = Repo.insert(Label.changeset(%Label{}, attrs))
    assert %{item_id: ["has already been taken"]} = errors_on(changeset)

    assert %{origin: ["is invalid"]} =
             errors_on(Label.changeset(%Label{}, %{attrs | origin: "other"}))

    Repo.delete!(item)
    assert Repo.aggregate(Label, :count) == 0
  end

  test "manual observations have no source and are unique per item and period" do
    item = Repo.insert!(Item.changeset(%Item{}, item_attrs("a")))

    attrs = %{
      item_id: item.id,
      period: "2026-11-11",
      observed_at: now(),
      attributes: %{"via" => "manual"}
    }

    assert %Observation{source_id: nil} =
             Repo.insert!(Observation.changeset(%Observation{}, attrs))

    assert {:error, _changeset} = Repo.insert(Observation.changeset(%Observation{}, attrs))
  end

  test "new items have no details yet" do
    item = Repo.insert!(Item.changeset(%Item{}, item_attrs("a")))
    assert %Item{details_fetched_at: nil, details_error: nil} = item
  end

  test "settings are unique per key" do
    Repo.insert!(Setting.changeset(%Setting{}, %{key: "k", value: "v"}))

    assert {:error, changeset} =
             Repo.insert(Setting.changeset(%Setting{}, %{key: "k", value: "w"}))

    assert %{key: ["has already been taken"]} = errors_on(changeset)
  end
end
