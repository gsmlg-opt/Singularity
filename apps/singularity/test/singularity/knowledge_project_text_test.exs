defmodule Singularity.KnowledgeProjectTextTest do
  use Singularity.DataCase, async: true
  use Styx.Testing, repo: Singularity.Repo

  import Singularity.Fixtures

  alias Singularity.Knowledge
  alias Singularity.Knowledge.FetchReadmeWorker

  describe "deprecation" do
    test "marking by hand, with a trimmed reason, and clearing it" do
      project = project_fixture()
      refute Knowledge.deprecated?(project)

      {:ok, project} = Knowledge.deprecate(project, "  Superseded by acme/next ")
      assert Knowledge.deprecated?(project)
      assert project.deprecation_reason == "Superseded by acme/next"

      {:ok, project} = Knowledge.undeprecate(project)
      refute Knowledge.deprecated?(project)
      assert project.deprecation_reason == nil
    end

    test "a blank reason is stored as nil" do
      {:ok, project} = Knowledge.deprecate(project_fixture(), " ")
      assert project.deprecated_at
      assert project.deprecation_reason == nil
    end

    test "an archived GitHub project stays deprecated" do
      project = project_fixture(attributes: %{"archived" => true})
      assert Knowledge.deprecated?(project)
      {:ok, project} = Knowledge.undeprecate(project)
      assert Knowledge.deprecated?(project)
    end

    test "list_projects filters by status" do
      active = project_fixture(title: "acme/active", attributes: %{"archived" => false})
      archived = project_fixture(title: "acme/archived", attributes: %{"archived" => true})
      marked = project_fixture(title: "acme/marked", deprecated_at: now())
      plain = project_fixture(title: "acme/plain")

      ids = fn status ->
        Knowledge.list_projects(status: status) |> Enum.map(& &1.id) |> Enum.sort()
      end

      assert ids.(:deprecated) == Enum.sort([archived.id, marked.id])
      assert ids.(:active) == Enum.sort([active.id, plain.id])
      assert length(ids.(nil)) == 4
    end
  end

  describe "instruction" do
    test "is saved, and blank text clears it" do
      project = project_fixture()

      {:ok, project} = Knowledge.update_instruction(project, %{"instruction" => "A **rocket**."})
      assert project.instruction == "A **rocket**."

      {:ok, project} = Knowledge.update_instruction(project, %{"instruction" => "  \n"})
      assert project.instruction == nil
    end

    test "has a length limit" do
      long = String.duplicate("x", 20_001)

      assert {:error, changeset} =
               Knowledge.update_instruction(project_fixture(), %{"instruction" => long})

      assert %{instruction: [_message]} = errors_on(changeset)
    end
  end

  test "adding a GitHub project by hand queues its README" do
    {:ok, project} = Knowledge.add_project(%{"name" => "Rocket", "address" => "acme/rocket"})
    assert_enqueued(worker: FetchReadmeWorker, args: %{item_id: project.id})

    {:ok, other} =
      Knowledge.add_project(%{"name" => "Lab", "address" => "https://gitlab.com/acme/lab"})

    refute_enqueued(worker: FetchReadmeWorker, args: %{item_id: other.id})
  end
end
