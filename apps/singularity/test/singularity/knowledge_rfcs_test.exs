defmodule Singularity.KnowledgeRfcsTest do
  use Singularity.DataCase, async: true

  import Singularity.Fixtures

  alias Singularity.{Collection, Knowledge}
  alias Singularity.Knowledge.ItemChange

  setup do
    tls =
      rfc_fixture(8446,
        title: "The Transport Layer Security (TLS) Protocol Version 1.3",
        content: "big"
      )

    ip = rfc_fixture(791, title: "Internet Protocol")
    project_fixture(title: "acme/tls")
    label_fixture(tls, "status:proposed-standard")
    %{tls: tls, ip: ip}
  end

  defp numbers(items), do: Enum.map(items, & &1.attributes["number"])

  test "list_rfcs/1 lists RFCs only, highest number first, without content" do
    assert [tls, _ip] = Knowledge.list_rfcs()
    assert numbers(Knowledge.list_rfcs()) == [8446, 791]
    assert tls.content == nil
    assert [%{name: "status:proposed-standard"}] = tls.labels
    assert Knowledge.count_rfcs() == 2
  end

  test "list_rfcs/1 searches by number or title, and filters by label" do
    assert numbers(Knowledge.list_rfcs(q: "791")) == [791]
    assert numbers(Knowledge.list_rfcs(q: "RFC 8446")) == [8446]
    assert numbers(Knowledge.list_rfcs(q: "transport layer")) == [8446]
    assert numbers(Knowledge.list_rfcs(q: "100%")) == []
    assert numbers(Knowledge.list_rfcs(label: "status:proposed-standard")) == [8446]
    assert Knowledge.count_rfcs(q: "internet") == 1
  end

  test "list_rfcs/1 pages" do
    assert numbers(Knowledge.list_rfcs(per_page: 1, page: 2)) == [791]
  end

  test "get_rfc!/1 and get_rfcs_by_external_ids/1", %{tls: tls} do
    assert %{id: id, content: "big", labels: [_label]} = Knowledge.get_rfc!(8446)
    assert id == tls.id
    assert_raise Ecto.NoResultsError, fn -> Knowledge.get_rfc!(1) end

    assert %{"rfc791" => %{title: "Internet Protocol"}} =
             found = Knowledge.get_rfcs_by_external_ids(["rfc791", "rfc1", "github.com/acme/tls"])

    assert Map.keys(found) == ["rfc791"]
    assert Knowledge.get_rfcs_by_external_ids([]) == %{}
  end

  test "list_item_changes/1 is newest first with the run", %{tls: tls} do
    source = source_fixture()
    run = fetch_run_fixture(source)
    older = item_change_fixture(run, tls, change: "added", inserted_at: ~U[2026-10-01 00:00:00Z])
    newer = item_change_fixture(run, tls, inserted_at: ~U[2026-11-01 00:00:00Z])

    assert [%ItemChange{id: first, fetch_run: %{id: run_id}}, %ItemChange{id: second}] =
             Knowledge.list_item_changes(tls.id)

    assert {first, second, run_id} == {newer.id, older.id, run.id}
  end

  test "get_run!/1, list_run_changes/2 and count_run_changes/2", %{tls: tls, ip: ip} do
    source = source_fixture(name: "IETF RFCs")
    run = fetch_run_fixture(source)
    item_change_fixture(run, tls, change: "updated")
    item_change_fixture(run, ip, change: "added")
    item_change_fixture(run, nil, change: "removed", external_id: "rfc1")
    item_change_fixture(fetch_run_fixture(source), ip)

    assert %{source: %{name: "IETF RFCs"}} = Collection.get_run!(run.id)

    assert Enum.map(Collection.list_run_changes(run.id), &{&1.change, &1.external_id}) ==
             [{"added", "rfc791"}, {"removed", "rfc1"}, {"updated", "rfc8446"}]

    assert [%{external_id: "rfc8446"}] = Collection.list_run_changes(run.id, change: "updated")
    assert [%{external_id: "rfc1"}] = Collection.list_run_changes(run.id, per_page: 1, page: 2)
    assert Collection.count_run_changes(run.id) == 3
    assert Collection.count_run_changes(run.id, change: "added") == 1
  end
end
