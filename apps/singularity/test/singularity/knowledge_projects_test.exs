defmodule Singularity.KnowledgeProjectsTest do
  use Singularity.DataCase, async: true

  import Singularity.Fixtures

  alias Singularity.Knowledge

  defp days_ago(days), do: DateTime.add(now(), -days * 86_400, :second)
  defp ids(projects), do: Enum.map(projects, & &1.id)

  describe "list_projects/1" do
    setup do
      old =
        project_fixture(
          title: "acme/old-rocket",
          summary: "A rocket engine",
          attributes: %{"stars" => 900},
          first_seen_at: days_ago(10)
        )

      new =
        project_fixture(
          title: "zeta/new-tool",
          summary: "Tooling for 100% coverage",
          attributes: %{"stars" => 50},
          first_seen_at: days_ago(1)
        )

      unstarred = project_fixture(title: "solo/plain", first_seen_at: days_ago(5))

      label_fixture(old, "lang:rust")
      label_fixture(new, "topic:cli")
      label_fixture(new, "lang:rust", "manual")

      %{old: old, new: new, unstarred: unstarred}
    end

    test "orders by recently added and preloads labels by name", %{
      old: old,
      new: new,
      unstarred: unstarred
    } do
      projects = Knowledge.list_projects()
      assert ids(projects) == [new.id, unstarred.id, old.id]

      assert projects |> hd() |> Map.fetch!(:labels) |> Enum.map(& &1.name) == [
               "lang:rust",
               "topic:cli"
             ]
    end

    test "sorts by stars with unknown counts last", %{old: old, new: new, unstarred: unstarred} do
      assert ids(Knowledge.list_projects(sort: :stars)) == [old.id, new.id, unstarred.id]
    end

    test "filters by label", %{old: old, new: new} do
      assert ids(Knowledge.list_projects(label: "lang:rust")) == [new.id, old.id]
      assert ids(Knowledge.list_projects(label: "topic:cli")) == [new.id]
    end

    test "searches owner/repo and description, treating % literally", %{old: old, new: new} do
      assert ids(Knowledge.list_projects(q: "ROCKET")) == [old.id]
      assert ids(Knowledge.list_projects(q: "zeta/")) == [new.id]
      assert ids(Knowledge.list_projects(q: "%")) == [new.id]
    end

    test "paginates" do
      assert length(Knowledge.list_projects(per_page: 2, page: 1)) == 2
      assert length(Knowledge.list_projects(per_page: 2, page: 2)) == 1
    end

    test "ignores items of other kinds" do
      project_fixture(kind: "fake_item")
      assert length(Knowledge.list_projects()) == 3
    end
  end

  test "count_projects/0, count_projects_since/1 and recent_projects/1" do
    project_fixture(first_seen_at: days_ago(10))
    recent = project_fixture(first_seen_at: days_ago(2))

    assert Knowledge.count_projects() == 2
    assert Knowledge.count_projects_since(days_ago(7)) == 1
    assert [%{id: id, labels: []}] = Knowledge.recent_projects(1)
    assert id == recent.id
  end

  test "get_project!/1 preloads labels; items of other kinds are not projects" do
    project = project_fixture()
    label_fixture(project, "archived")
    assert %{labels: [%{name: "archived"}]} = Knowledge.get_project!(project.id)

    other = project_fixture(kind: "fake_item")
    assert_raise Ecto.NoResultsError, fn -> Knowledge.get_project!(other.id) end
    assert Knowledge.get_project(other.id) == nil
  end

  test "top_labels/1 ranks labels by project count" do
    a = project_fixture()
    b = project_fixture()
    label_fixture(a, "lang:rust")
    label_fixture(b, "lang:rust")
    label_fixture(b, "topic:cli")

    assert Knowledge.top_labels(1) == [{"lang:rust", 2}]
    assert Knowledge.top_labels(5) == [{"lang:rust", 2}, {"topic:cli", 1}]
  end

  test "list_observations/1 returns history newest first, with nil sources for manual additions" do
    source = source_fixture()
    project = project_fixture()

    observation_fixture(project, source,
      period: "2026-11-09",
      observed_at: ~U[2026-11-09 08:00:00Z]
    )

    observation_fixture(project, nil, period: "2026-11-10", observed_at: ~U[2026-11-10 08:00:00Z])

    assert [
             %{period: "2026-11-10", source: nil},
             %{period: "2026-11-09", source: %{name: "Fake source"}}
           ] = Knowledge.list_observations(project.id)
  end

  test "list_additions/1 lists projects newest first with the source that brought them" do
    source = source_fixture(name: "Trending")
    trending = project_fixture(first_seen_at: days_ago(2))
    manual = project_fixture(first_seen_at: days_ago(1))
    observation_fixture(trending, source, observed_at: days_ago(2))
    observation_fixture(manual, nil, observed_at: days_ago(1))

    assert [
             %{item: %{id: manual_id}, source: nil, at: %DateTime{}},
             %{item: %{id: trending_id}, source: %{name: "Trending"}}
           ] = Knowledge.list_additions(10)

    assert {manual_id, trending_id} == {manual.id, trending.id}
  end

  describe "manual labels" do
    test "add_label/2 normalizes, broadcasts and turns an automatic label into a manual one" do
      Knowledge.subscribe()
      project = project_fixture()
      project_id = project.id
      label_fixture(project, "lang:rust")

      assert {:ok, %{name: "my-pick", origin: "manual"}} =
               Knowledge.add_label(project, "  My-Pick ")

      assert_receive {:project_updated, ^project_id}
      assert {:ok, %{origin: "manual"}} = Knowledge.add_label(project, "lang:rust")

      assert project.id
             |> Knowledge.get_project!()
             |> Map.fetch!(:labels)
             |> Enum.map(&{&1.name, &1.origin}) == [
               {"lang:rust", "manual"},
               {"my-pick", "manual"}
             ]
    end

    test "add_label/2 rejects blank and overlong names" do
      project = project_fixture()
      assert {:error, changeset} = Knowledge.add_label(project, " ")
      assert %{name: ["can't be blank"]} = errors_on(changeset)
      assert {:error, changeset} = Knowledge.add_label(project, String.duplicate("x", 101))
      assert %{name: [_too_long]} = errors_on(changeset)
    end

    test "remove_label/2 deletes manual labels only" do
      project = project_fixture()
      label_fixture(project, "lang:rust")
      label_fixture(project, "mine", "manual")

      assert :ok = Knowledge.remove_label(project, "MINE")
      assert {:error, :auto_label} = Knowledge.remove_label(project, "lang:rust")
      assert {:error, :not_found} = Knowledge.remove_label(project, "nope")
      assert [%{name: "lang:rust"}] = Knowledge.get_project!(project.id).labels
    end
  end
end
