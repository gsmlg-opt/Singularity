defmodule Singularity.KnowledgeAddProjectTest do
  use Singularity.DataCase, async: true
  use Styx.Testing, repo: Singularity.Repo

  import Singularity.Fixtures

  alias Singularity.Knowledge
  alias Singularity.Knowledge.{FetchDetailsWorker, Item, Observation}

  @now ~U[2026-11-11 08:00:00Z]

  test "creates a project, records a manual addition and queues a details fetch" do
    Knowledge.subscribe()

    assert {:ok, %Item{} = item} =
             Knowledge.add_project("https://github.com/Elixir-Lang/Elixir.git", @now)

    assert item.kind == "software_project"
    assert item.external_id == "github.com/elixir-lang/elixir"
    assert item.title == "Elixir-Lang/Elixir"
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

  test "adding a known project returns it without a second fetch" do
    {:ok, item} = Knowledge.add_project("elixir-lang/elixir", @now)
    next_day = DateTime.add(@now, 86_400, :second)

    assert {:existing, %Item{id: id}} =
             Knowledge.add_project("git@github.com:elixir-lang/elixir.git", next_day)

    assert id == item.id
    assert {:existing, _item} = Knowledge.add_project("elixir-lang/elixir", next_day)
    assert Repo.aggregate(Item, :count) == 1
    assert Repo.aggregate(Observation, :count) == 2
    assert length(all_enqueued(worker: FetchDetailsWorker)) == 1
  end

  test "rejects unsupported addresses" do
    assert {:error, :unsupported_address} = Knowledge.add_project("https://gitlab.com/a/b")
    assert Repo.aggregate(Item, :count) == 0
  end

  test "enqueue_details/1 keeps one incomplete fetch per project" do
    project = project_fixture()
    assert {:ok, _job} = Knowledge.enqueue_details(project.id)
    assert {:ok, _job} = Knowledge.enqueue_details(project.id)
    assert length(all_enqueued(worker: FetchDetailsWorker)) == 1
  end
end
