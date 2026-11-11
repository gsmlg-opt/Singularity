defmodule Singularity.GitHub.QuotaTest do
  use ExUnit.Case, async: true

  alias Singularity.GitHub.Quota

  @now ~U[2026-11-12 08:00:00Z]

  setup do
    table = :"quota_#{System.unique_integer([:positive])}"
    start_supervised!({Quota, name: table})
    %{table: table}
  end

  defp headers(remaining, limit, reset),
    do:
      HTTP.Headers.new([
        {"x-ratelimit-remaining", Integer.to_string(remaining)},
        {"x-ratelimit-limit", Integer.to_string(limit)},
        {"x-ratelimit-reset", Integer.to_string(reset)}
      ])

  test "allows requests before any quota is known", %{table: table} do
    assert :ok = Quota.check(table, @now)
  end

  test "allows requests while at least 10% of the quota is left", %{table: table} do
    reset = DateTime.to_unix(@now) + 600
    Quota.record(table, headers(500, 5000, reset))
    assert :ok = Quota.check(table, @now)
  end

  test "holds requests back until the reset once less than 10% is left", %{table: table} do
    reset = DateTime.to_unix(@now) + 600
    Quota.record(table, headers(499, 5000, reset))

    assert {:error, {:rate_limited, 600}} = Quota.check(table, @now)
    assert :ok = Quota.check(table, DateTime.add(@now, 600, :second))
  end

  test "ignores responses without quota headers", %{table: table} do
    Quota.record(table, headers(1, 5000, DateTime.to_unix(@now) + 600))
    Quota.record(table, HTTP.Headers.new([{"content-type", "text/html"}]))

    assert {:error, {:rate_limited, _seconds}} = Quota.check(table, @now)
  end
end
