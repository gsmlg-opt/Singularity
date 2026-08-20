defmodule Singularity.Web.RouteContractTest do
  use ExUnit.Case, async: true

  test "router exposes exactly the Task 18 browser and API surface" do
    actual =
      Singularity.Web.Router.__routes__()
      |> Enum.map(&{&1.verb, &1.path})
      |> MapSet.new()

    expected =
      MapSet.new([
        {:get, "/login"},
        {:post, "/login"},
        {:get, "/vault/unlock"},
        {:post, "/vault/unlock"},
        {:get, "/assets"},
        {:get, "/notes"},
        {:put, "/api/v1/uploads/:grant_id"},
        {:get, "/api/v1/assets/:asset_id/content"},
        {:get, "/api/v1/notes/:resource_id/export"},
        {:get, "/activity"},
        {:get, "/audit"},
        {:get, "/backups"},
        {:post, "/backups"},
        {:get, "/settings"},
        {:delete, "/logout"}
      ])

    assert expected == actual
  end
end
