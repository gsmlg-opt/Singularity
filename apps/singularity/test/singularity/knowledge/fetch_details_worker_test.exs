defmodule Singularity.Knowledge.FetchDetailsWorkerTest do
  use Singularity.DataCase, async: true
  use Styx.Testing, repo: Singularity.Repo

  import Singularity.Fixtures

  alias Singularity.{GitHub, Knowledge, Settings}
  alias Singularity.Knowledge.FetchDetailsWorker

  @fixture Path.join([__DIR__, "../../fixtures/github_api/elixir.json"])

  setup do
    HTTP.Test.verify_on_exit!()

    project =
      project_fixture(
        title: "elixir-lang/Elixir",
        external_id: "github.com/elixir-lang/elixir",
        details_error: "old failure"
      )

    observation_fixture(project, source_fixture(), attributes: %{"since" => "weekly"})
    label_fixture(project, "topic:stale")
    label_fixture(project, "lang:elixir", "manual")
    %{project: project}
  end

  test "stores details, clears the error and recomputes automatic labels", %{project: project} do
    Knowledge.subscribe()
    project_id = project.id
    # Fixed topics keep the expected labels independent of the captured repository.
    body = @fixture |> File.read!() |> JSON.decode!() |> Map.put("topics", ["functional"])

    HTTP.Test.expect(GitHub, fn request ->
      assert request.url.path == "/repos/elixir-lang/elixir"
      HTTP.Test.response(200, JSON.encode!(body), [{"content-type", "application/json"}])
    end)

    assert :ok = perform_job(FetchDetailsWorker, %{item_id: project.id})

    project = Knowledge.get_project!(project.id)
    assert project.title == "elixir-lang/elixir"
    assert project.attributes["language"] == "Elixir"
    assert %DateTime{} = project.details_fetched_at
    assert project.details_error == nil

    assert Enum.map(project.labels, &{&1.name, &1.origin}) == [
             {"lang:elixir", "manual"},
             {"topic:functional", "auto"},
             {"trending:weekly", "auto"}
           ]

    assert_receive {:project_updated, ^project_id}
  end

  test "snoozes until the rate limit resets", %{project: project} do
    HTTP.Test.expect(GitHub, fn _request ->
      HTTP.Test.status(429) |> HTTP.Test.headers([{"retry-after", "90"}])
    end)

    assert {:snooze, 90} = perform_job(FetchDetailsWorker, %{item_id: project.id})
    assert Knowledge.get_project!(project.id).details_error == "old failure"
  end

  test "records a missing repository without retrying", %{project: project} do
    HTTP.Test.expect(GitHub, fn _request -> HTTP.Test.status(404) end)

    assert :ok = perform_job(FetchDetailsWorker, %{item_id: project.id})
    assert Knowledge.get_project!(project.id).details_error == "repository not found"
  end

  test "records other failures and returns an error so Styx retries", %{project: project} do
    HTTP.Test.expect(GitHub, fn _request -> HTTP.Test.transport_error(:timeout) end)

    assert {:error, {:transport, "timeout"}} =
             perform_job(FetchDetailsWorker, %{item_id: project.id})

    assert Knowledge.get_project!(project.id).details_error == "transport error: timeout"
  end

  test "sends the stored GitHub token", %{project: project} do
    {:ok, _setting} = Settings.put_github_token("ghp_stored")

    HTTP.Test.expect(GitHub, fn request ->
      assert HTTP.Headers.get(request.headers, "authorization") == "Bearer ghp_stored"
      HTTP.Test.status(404)
    end)

    assert :ok = perform_job(FetchDetailsWorker, %{item_id: project.id})
  end

  test "cancels when the project no longer exists" do
    assert {:cancel, :project_not_found} = perform_job(FetchDetailsWorker, %{item_id: -1})
  end
end
