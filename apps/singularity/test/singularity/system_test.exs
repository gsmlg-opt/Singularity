defmodule Singularity.SystemTest do
  use Singularity.DataCase, async: true

  import Singularity.Fixtures

  alias Singularity.Knowledge

  test "status/0 reports the version and job counts for every configured queue" do
    project = project_fixture()
    {:ok, _job} = Knowledge.enqueue_details(project.id)

    # Fully qualified on purpose: aliasing Singularity.System would shadow Elixir's System.
    status = Singularity.System.status()

    assert status.version == to_string(Application.spec(:singularity, :vsn))

    assert Enum.map(status.queues, & &1.name) == [
             "collect",
             "default",
             "github_api",
             "github_web",
             "rfc_editor"
           ]

    assert %{available: 1, executing: 0, retryable: 0} =
             Enum.find(status.queues, &(&1.name == "github_api"))
  end
end
