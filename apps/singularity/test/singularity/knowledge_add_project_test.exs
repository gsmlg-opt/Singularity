defmodule Singularity.KnowledgeAddProjectTest do
  use Singularity.DataCase, async: true
  use Styx.Testing, repo: Singularity.Repo

  import Singularity.Fixtures

  alias Singularity.Knowledge
  alias Singularity.Knowledge.{FetchDetailsWorker, Item, Label, Observation}

  @now ~U[2026-11-11 08:00:00Z]

  defp add(name, address, now \\ @now),
    do: Knowledge.add_project(%{"name" => name, "address" => address}, now)

  test "adds a GitHub project under the given name and queues a details fetch" do
    Knowledge.subscribe()

    assert {:ok, %Item{} = item} = add(" Elixir ", "https://github.com/Elixir-Lang/Elixir.git")

    assert item.kind == "software_project"
    assert item.external_id == "github.com/elixir-lang/elixir"
    assert item.title == "Elixir"
    assert item.custom_title
    assert item.url == "https://github.com/Elixir-Lang/Elixir"
    assert item.first_seen_at == @now

    assert [
             %Observation{
               source_id: nil,
               period: "2026-11-11",
               attributes: %{"via" => "manual"}
             }
           ] = Repo.all(Observation)

    assert_enqueued(worker: FetchDetailsWorker, args: %{item_id: item.id}, queue: :details)
    item_id = item.id
    assert_receive {:project_updated, ^item_id}
  end

  test "adds a project on another host without a details fetch, labelled by host" do
    assert {:ok, item} = add("Inkscape", "git@gitlab.com:inkscape/inkscape.git")

    assert item.external_id == "gitlab.com/inkscape/inkscape"
    assert item.url == "git@gitlab.com:inkscape/inkscape.git"
    refute Knowledge.details_supported?(item)
    assert [%Label{name: "host:gitlab.com", origin: "auto"}] = Repo.all(Label)
    assert all_enqueued(worker: FetchDetailsWorker) == []
    assert {:error, :details_unsupported} = Knowledge.enqueue_details(item.id)
  end

  test "adding a known project returns it unchanged without a second fetch" do
    {:ok, item} = add("Elixir", "elixir-lang/elixir")
    next_day = DateTime.add(@now, 86_400, :second)

    assert {:existing, %Item{id: id, title: "Elixir"}} =
             add("Another name", "git@github.com:elixir-lang/elixir.git", next_day)

    assert id == item.id
    assert {:existing, _item} = add("Elixir", "elixir-lang/elixir", next_day)
    assert Repo.aggregate(Item, :count) == 1
    assert Repo.aggregate(Observation, :count) == 2
    assert length(all_enqueued(worker: FetchDetailsWorker)) == 1
  end

  test "requires a name and a repository address" do
    assert {:error, changeset} = add("", "")
    assert %{name: ["can't be blank"], address: ["can't be blank"]} = errors_on(changeset)

    assert {:error, changeset} = add("Thing", "not an address")
    assert %{address: ["is not a repository address"]} = errors_on(changeset)
    assert Repo.aggregate(Item, :count) == 0
  end

  test "details keep a title the user typed" do
    {:ok, item} = add("My Elixir", "elixir-lang/elixir")

    {:ok, item} =
      Knowledge.put_details(
        item,
        %{title: "elixir-lang/elixir", summary: "s", attributes: %{}},
        @now
      )

    assert item.title == "My Elixir"
  end

  test "list_manual_projects/1 lists hand-added projects, latest addition first" do
    {:ok, first} = add("First", "gitlab.com/a/first")
    {:ok, second} = add("Second", "acme/second", DateTime.add(@now, 60, :second))
    _collected = project_fixture()

    assert [
             %{item: %Item{id: second_id}, manual_added_at: second_at},
             %{item: %Item{id: first_id, labels: [%Label{name: "host:gitlab.com"}]}}
           ] = Knowledge.list_manual_projects(10)

    assert {second_id, first_id} == {second.id, first.id}
    assert second_at == DateTime.add(@now, 60, :second)
  end

  test "enqueue_details/1 keeps one incomplete fetch per project" do
    project = project_fixture()
    assert {:ok, _job} = Knowledge.enqueue_details(project.id)
    assert {:ok, _job} = Knowledge.enqueue_details(project.id)
    assert length(all_enqueued(worker: FetchDetailsWorker)) == 1
  end
end
