defmodule Singularity.Knowledge.FetchReadmeWorkerTest do
  use Singularity.DataCase, async: true
  use Styx.Testing, repo: Singularity.Repo

  import Singularity.Fixtures

  alias Singularity.{GitHub, Knowledge}
  alias Singularity.Knowledge.{FetchReadmeWorker, ReadmeRefreshWorker}

  setup do
    HTTP.Test.verify_on_exit!()
    %{project: project_fixture(title: "acme/rocket")}
  end

  test "stores the README", %{project: project} do
    Knowledge.subscribe()
    project_id = project.id

    HTTP.Test.expect(GitHub, fn request ->
      assert request.url.path == "/repos/acme/rocket/readme"
      HTTP.Test.response(200, "# Rocket")
    end)

    assert :ok = perform_job(FetchReadmeWorker, %{item_id: project.id})
    project = Repo.reload!(project)
    assert project.readme == "# Rocket"
    assert project.readme_fetched_at
    assert_received {:project_updated, ^project_id}
  end

  test "records a repository without a README", %{project: project} do
    HTTP.Test.expect(GitHub, fn _request -> HTTP.Test.status(404) end)

    assert :ok = perform_job(FetchReadmeWorker, %{item_id: project.id})
    project = Repo.reload!(project)
    assert project.readme == nil
    assert project.readme_fetched_at
  end

  test "snoozes on rate limits and retries other errors", %{project: project} do
    HTTP.Test.expect(GitHub, fn _request ->
      HTTP.Test.status(429) |> HTTP.Test.headers([{"retry-after", "30"}])
    end)

    assert {:snooze, 30} = perform_job(FetchReadmeWorker, %{item_id: project.id})

    HTTP.Test.expect(GitHub, fn _request -> HTTP.Test.status(500) end)
    assert {:error, {:http_status, 500}} = perform_job(FetchReadmeWorker, %{item_id: project.id})
    assert Repo.reload!(project).readme_fetched_at == nil
  end

  test "cancels for projects off GitHub" do
    project = project_fixture(external_id: "gitlab.com/acme/x", url: "https://gitlab.com/acme/x")

    assert {:cancel, :details_unsupported} =
             perform_job(FetchReadmeWorker, %{item_id: project.id})

    assert {:error, :details_unsupported} = Knowledge.enqueue_readme(project.id)
  end

  test "the refresh queues missing and stale READMEs on GitHub only, never-fetched first", %{
    project: never
  } do
    now = ~U[2026-11-11 08:00:00Z]
    fresh = project_fixture(readme_fetched_at: DateTime.add(now, -1, :day))
    stale = project_fixture(readme_fetched_at: DateTime.add(now, -31, :day))
    project_fixture(external_id: "gitlab.com/a/b", url: "https://gitlab.com/a/b")

    assert Knowledge.enqueue_stale_readmes(now, 1) == 1
    assert queued_ids() == [never.id]

    assert :ok = perform_job(ReadmeRefreshWorker, %{})
    assert Enum.sort(queued_ids()) == Enum.sort([never.id, stale.id])
    refute fresh.id in queued_ids()
  end

  defp queued_ids,
    do: all_enqueued(worker: FetchReadmeWorker) |> Enum.map(& &1.args["item_id"])
end
