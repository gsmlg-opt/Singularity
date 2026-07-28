defmodule Singularity.Web.RouteContractTest do
  use ExUnit.Case, async: true

  test "router exposes exactly the Task 16 browser and API surface" do
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
        {:put, "/api/v1/uploads/:grant_id"},
        {:get, "/api/v1/assets/:asset_id/content"},
        {:get, "/activity"},
        {:get, "/audit"},
        {:get, "/backups"},
        {:get, "/settings"},
        {:delete, "/logout"}
      ])

    assert expected == actual
  end
end
