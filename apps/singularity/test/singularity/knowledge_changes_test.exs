defmodule Singularity.KnowledgeChangesTest do
  use Singularity.DataCase, async: true
  use Styx.Testing, repo: Singularity.Repo

  import Singularity.Fixtures

  alias Singularity.Collector.{Entry, Result}
  alias Singularity.Knowledge
  alias Singularity.Knowledge.{Item, ItemChange, Label}
  alias Singularity.Repo

  @t1 ~U[2026-11-01 08:00:00Z]
  @t2 ~U[2026-12-01 08:00:00Z]
  @t3 ~U[2027-01-01 08:00:00Z]

  @moduletag :tmp_dir

  defp rfc(number, opts \\ []) do
    %Entry{
      item_kind: "ietf_rfc",
      external_id: "rfc#{number}",
      title: Keyword.get(opts, :title, "RFC #{number} title"),
      url: "https://www.rfc-editor.org/rfc/rfc#{number}",
      summary: Keyword.get(opts, :summary),
      published_at: ~U[2018-08-01 00:00:00Z],
      period: "2018-08",
      item_attributes:
        Keyword.get(opts, :attributes, %{"number" => number, "obsoleted_by" => []}),
      labels: Keyword.get(opts, :labels),
      content_path: Keyword.get(opts, :content_path)
    }
  end

  defp record(source, entries, now, opts \\ []) do
    run = fetch_run_fixture(source)

    result = %Result{
      period: "run",
      entries: entries,
      complete: Keyword.get(opts, :complete, true)
    }

    {:ok, counts} = Knowledge.record(source, result, now, run.id)
    {run, counts}
  end

  defp changes(run),
    do: ItemChange |> where(fetch_run_id: ^run.id) |> order_by(:external_id) |> Repo.all()

  defp item(external_id), do: Repo.get_by!(Item, external_id: external_id)

  defp write!(dir, name, text) do
    path = Path.join(dir, name)
    File.write!(path, text)
    path
  end

  test "a first run records every item as added, without diffs", %{tmp_dir: dir} do
    source = source_fixture()
    path = write!(dir, "rfc1.md", "# RFC 1\n")

    {run, counts} = record(source, [rfc(1, content_path: path), rfc(2)], @t1)

    assert counts == %{count: 2, added: 2, updated: 0, removed: 0}

    assert [
             %ItemChange{external_id: "rfc1", change: "added", content_diff: nil, fields: %{}},
             %ItemChange{external_id: "rfc2", change: "added", kind: "ietf_rfc"}
           ] = changes(run)

    assert %Item{content: "# RFC 1\n", content_updated_at: @t1} = item("rfc1")
  end

  test "an unchanged run records nothing and keeps content_updated_at", %{tmp_dir: dir} do
    source = source_fixture()
    path = write!(dir, "rfc1.md", "# RFC 1\n")

    record(source, [rfc(1, content_path: path)], @t1)
    {run, counts} = record(source, [rfc(1, content_path: path)], @t2)

    assert counts == %{count: 1, added: 0, updated: 0, removed: 0}
    assert changes(run) == []
    assert item("rfc1").content_updated_at == @t1
  end

  test "collected values overwrite an RFC and the change is recorded by field" do
    source = source_fixture()
    record(source, [rfc(8446)], @t1)

    attributes = %{"number" => 8446, "obsoleted_by" => ["rfc9846"]}

    {run, counts} =
      record(source, [rfc(8446, title: "TLS 1.3", attributes: attributes)], @t2)

    assert counts.updated == 1
    assert %Item{title: "TLS 1.3", attributes: ^attributes} = item("rfc8446")

    assert [%ItemChange{change: "updated", title: "TLS 1.3", fields: fields}] = changes(run)

    assert fields == %{
             "title" => %{"old" => "RFC 8446 title", "new" => "TLS 1.3"},
             "attributes.obsoleted_by" => %{"old" => [], "new" => ["rfc9846"]}
           }
  end

  test "changed content is written and its diff recorded", %{tmp_dir: dir} do
    source = source_fixture()
    path = write!(dir, "rfc1.md", "a\nb\nc\n")
    record(source, [rfc(1, content_path: path)], @t1)

    File.write!(path, "a\nB\nc\n")
    {run, _counts} = record(source, [rfc(1, content_path: path)], @t2)

    assert %Item{content: "a\nB\nc\n", content_updated_at: @t2} = item("rfc1")

    assert [%ItemChange{change: "updated", fields: %{}, content_diff: diff}] = changes(run)
    assert diff == "@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n"
  end

  test "Latin-1 and NUL bytes are stored as valid text", %{tmp_dir: dir} do
    path = write!(dir, "rfc1.txt", <<"caf", 0xE9, 0, "\n">>)
    record(source_fixture(), [rfc(1, content_path: path)], @t1)

    assert item("rfc1").content == "café\n"
  end

  @tag capture_log: true
  test "an unreadable content file keeps the old content", %{tmp_dir: dir} do
    source = source_fixture()
    path = write!(dir, "rfc1.md", "kept\n")
    record(source, [rfc(1, content_path: path)], @t1)

    File.rm!(path)
    {run, _counts} = record(source, [rfc(1, content_path: path)], @t2)

    assert item("rfc1").content == "kept\n"
    assert changes(run) == []
  end

  test "entry labels replace automatic labels and keep manual ones" do
    source = source_fixture()
    record(source, [rfc(1, labels: ["status:draft", "obsoleted"])], @t1)
    label_fixture(item("rfc1"), "mine", "manual")

    record(source, [rfc(1, labels: ["status:proposed-standard"])], @t2)

    labels =
      Label |> where(item_id: ^item("rfc1").id) |> Repo.all() |> Map.new(&{&1.name, &1.origin})

    assert labels == %{"mine" => "manual", "status:proposed-standard" => "auto"}
  end

  test "items leaving and rejoining the source are recorded as removed and added" do
    source = source_fixture()
    record(source, [rfc(1), rfc(2)], @t1)

    {left, counts} = record(source, [rfc(1)], @t2)
    assert counts.removed == 1
    assert [%ItemChange{external_id: "rfc2", change: "removed"}] = changes(left)

    {back, counts} = record(source, [rfc(1), rfc(2, title: "Renamed")], @t3)
    assert counts == %{count: 2, added: 1, updated: 0, removed: 0}
    assert [%ItemChange{external_id: "rfc2", change: "added", title: "Renamed"}] = changes(back)
  end

  test "an incomplete result removes nothing" do
    source = source_fixture()
    record(source, [rfc(1), rfc(2)], @t1)

    {run, counts} = record(source, [rfc(1)], @t2, complete: false)

    assert counts.removed == 0
    assert changes(run) == []
  end

  test "software projects only get added and removed records" do
    source = source_fixture()

    project = %Entry{
      item_kind: "software_project",
      external_id: "github.com/acme/rocket",
      title: "acme/rocket",
      url: "https://github.com/acme/rocket",
      summary: "First"
    }

    {first, _counts} = record(source, [project], @t1)
    assert [%ItemChange{change: "added"}] = changes(first)

    {second, counts} = record(source, [%{project | summary: "Second"}], @t2)
    assert counts.updated == 0
    assert changes(second) == []
    assert item("github.com/acme/rocket").summary == "First"
  end

  test "change records outlive their item" do
    source = source_fixture()
    {run, _counts} = record(source, [rfc(1)], @t1)

    Repo.delete!(item("rfc1"))

    assert [%ItemChange{item_id: nil, external_id: "rfc1", title: "RFC 1 title"}] = changes(run)
  end
end
