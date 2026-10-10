defmodule Singularity.Runtime.SearchRebuildBoundaryTest do
  use ExUnit.Case, async: true

  alias Singularity.Runtime.{Api, SessionContext}
  alias Singularity.Runtime.DTO.Session

  @owner "00000000-0000-4000-8000-000000000d01"
  @principal "00000000-0000-4000-8000-000000000d02"
  @session "00000000-0000-4000-8000-000000000d03"
  @resource "00000000-0000-4000-8000-000000000d04"

  test "only a canonical resource UUID or all is accepted before the maintenance callback" do
    config = %{rebuild_search: fn _, _ -> flunk("invalid selector reached maintenance") end}

    for selector <- [
          nil,
          "all",
          :note,
          "not-a-uuid",
          String.upcase(@resource),
          Ecto.UUID.dump!(@resource),
          %{resource_id: @resource},
          %{resource_id: @resource, owner_scope_id: @owner},
          %{owner_scope_id: @owner},
          %{vault_id: @owner},
          %{principal_id: @principal},
          %{role: "singularity_table_owner"},
          %{connection: Singularity.Storage.MigrationRepo},
          [resource_id: @resource, owner_scope_id: @owner]
        ] do
      assert rebuild(config, session(), selector) == {:error, :invalid}
    end
  end

  test "valid selectors bind only the resolved session context and return counts" do
    owner = self()

    config = %{
      rebuild_search: fn context, selector ->
        send(owner, {:maintenance, context, selector})
        {:ok, %{resources: 1, entries: 0}}
      end
    }

    for selector <- [@resource, :all] do
      assert rebuild(config, session(), selector) == {:ok, %{resources: 1, entries: 0}}

      assert_received {:maintenance, %SessionContext{vault_id: @owner, principal_id: @principal},
                       ^selector}
    end
  end

  test "malformed count results cannot expose adapter content or falsely report success" do
    for counts <- [
          %{resources: -1, entries: 0},
          %{resources: 1, entries: -1},
          %{resources: 1.0, entries: 0},
          %{resources: 1},
          %{resources: 1, entries: 1, body: "private-maintenance-canary"},
          %{resources: 1, entries: 1, owner_scope_id: @owner},
          %{resources: 1, entries: 1, session: session()},
          %{"resources" => 1, "entries" => 1},
          nil
        ] do
      config = %{rebuild_search: fn _, _ -> {:ok, counts} end}
      assert rebuild(config, session(), :all) == {:error, :storage_unavailable}
    end
  end

  test "count fields are bounded independently at the PostgreSQL bigint boundary" do
    maximum = 9_223_372_036_854_775_807

    for counts <- [
          %{resources: maximum + 1, entries: 0},
          %{resources: 0, entries: maximum + 1}
        ] do
      config = %{rebuild_search: fn _, _ -> {:ok, counts} end}
      assert rebuild(config, session(), :all) == {:error, :storage_unavailable}
    end
  end

  defp rebuild(config, session, selector) do
    assert Code.ensure_loaded?(Api)
    assert function_exported?(Api, :rebuild_search, 3)
    apply(Api, :rebuild_search, [config, session, selector])
  end

  defp session do
    %Session{
      session_id: @session,
      account_id: @principal,
      principal_id: @principal,
      vault_id: @owner,
      expires_at: DateTime.add(DateTime.utc_now(), 600, :second),
      principal_authorization_epoch: 0,
      vault_authorization_epoch: 0,
      authorization_epoch: 0,
      unlocked?: true
    }
  end
end

defmodule Singularity.Runtime.SearchRebuildIntegrationTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration

  alias Singularity.Core.Error

  alias Singularity.Runtime.{
    Api,
    AuthorizationDependencies,
    CustodyReader,
    KeyCustodian,
    KeyLeaseSupervisor,
    OperationScope,
    ResolveSession
  }

  alias Singularity.Storage.{
    AuthorizationLock,
    Fixtures,
    KnowledgeFixtures,
    MigrationRepo,
    MigrationTestEnvironment,
    PreAuthRepo,
    RequestRepo,
    SafeSQL,
    ScopedRepo,
    VaultLock
  }

  alias Singularity.Storage.Postgres.{IdentityRepository, PreAuth, SearchProjectionReconciler}

  defmodule ObservedReconciler do
    def resource_kind(context, repo, resource_id) do
      Process.put({:rebuild_call, context.tag}, {:identity, resource_id})
      SearchProjectionReconciler.resource_kind(repo, resource_id)
    end

    def list_resource_ids(context, repo, after_id, limit) do
      Process.put({:rebuild_call, context.tag}, {:page, after_id})
      result = SearchProjectionReconciler.list_resource_ids(repo, after_id, limit)
      send(context.observer, {:rebuild_page, context.tag, after_id, limit, result})
      transform = Map.get(context, :transform_page, fn result -> result end)
      transform.(result)
    end

    def reconcile(context, repo, resource_id) do
      Process.put({:rebuild_call, context.tag}, {:resource, resource_id})
      %{rows: [[transaction]]} = SafeSQL.query!(repo, "SELECT txid_current()")
      send(context.observer, {:rebuild_resource, context.tag, resource_id, transaction})
      result = SearchProjectionReconciler.reconcile(repo, resource_id)
      transform = Map.get(context, :transform_reconcile, fn _, result -> result end)
      transform.(resource_id, result)
    end
  end

  defmodule ObservedScope do
    def with_read_request(context, runtime, session, requirement, callback) do
      Process.delete({:rebuild_call, context.tag})

      result =
        OperationScope.with_read_request(runtime, session, requirement, fn repo ->
          send(context.observer, {:rebuild_content_callback, context.tag, requirement})
          callback.(repo)
        end)

      # Hooks run after the real scope releases its transaction and advisory lock.
      hook = Map.get(context, :after_scope, fn _, _ -> :ok end)
      hook.(Process.get({:rebuild_call, context.tag}), result)
      result
    end
  end

  test "each kind rebuilds a missing projection using its own existing read capability" do
    for {kind, capabilities, unlocked?} <- [
          {:note, ["note.read"], true},
          {:document, ["asset.read"], false}
        ] do
      source = KnowledgeFixtures.source!()

      row =
        case kind do
          :note -> KnowledgeFixtures.note!(source)
          :document -> elem(KnowledgeFixtures.ready_document!(source), 0)
        end

      project!(source, [row])
      {runtime, session, _custodian} = live_runtime(source, capabilities, unlocked?)
      config = config(runtime)
      assert {:ok, before} = search(config, session, %{kind: kind})
      assert [%{resource_id: resource_id, kind: ^kind}] = before.items
      assert resource_id == uuid(row.resource_id)
      canonical = canonical_snapshot(source)
      remove_projections!(source)
      assert {:ok, %{items: [], next_cursor: nil}} = search(config, session, %{kind: kind})

      assert rebuild(config, session, resource_id) == {:ok, %{resources: 1, entries: 1}}
      assert rebuild(config, session, :all) == {:error, :forbidden}
      assert search(config, session, %{kind: kind}) == {:ok, before}
      assert canonical_snapshot(source) == canonical
    end
  end

  test "full maintenance reconstructs two canonical sources through the resolved live session" do
    source = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    {document, _fragment} = KnowledgeFixtures.ready_document!(source)
    {runtime, session, _custodian} = live_runtime(source, ["asset.read", "note.read"], true)
    project!(source, [note, document])
    config = config(runtime)
    assert {:ok, before} = search(config, session, %{limit: 1})
    assert [_] = before.items
    assert is_binary(before.next_cursor)
    assert {:ok, next} = search(config, session, %{limit: 1, cursor: before.next_cursor})
    assert [_] = next.items
    assert next.next_cursor == nil
    canonical = canonical_snapshot(source)
    remove_projections!(source)

    assert rebuild(config, session, :all) == {:ok, %{resources: 2, entries: 2}}
    assert search(config, session, %{limit: 1}) == {:ok, before}
    assert search(config, session, %{limit: 1, cursor: before.next_cursor}) == {:ok, next}
    assert canonical_snapshot(source) == canonical
    assert rebuild(config, session, :all) == {:ok, %{resources: 2, entries: 2}}
  end

  test "canonical enumeration includes tombstones and pending Documents while preserving foreign rows" do
    source = KnowledgeFixtures.source!()
    foreign = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    {document, _} = KnowledgeFixtures.ready_document!(source)
    dead_note = KnowledgeFixtures.note!(source)
    {dead_document, _} = KnowledgeFixtures.ready_document!(source)
    KnowledgeFixtures.document!(source)
    foreign_note = KnowledgeFixtures.note!(foreign)
    project!(source, [dead_note, dead_document])
    project!(foreign, [foreign_note])

    Fixtures.with_owner(fn ->
      for row <- [dead_note, dead_document] do
        query!(
          MigrationRepo,
          "UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id=$1",
          [
            row.resource_id
          ]
        )
      end
    end)

    {runtime, session, _} = live_runtime(source, ["asset.read", "note.read"], true)
    canonical = canonical_snapshot(source)
    foreign_entries = projection_snapshot(foreign)

    assert rebuild(config(runtime), session, :all) == {:ok, %{resources: 5, entries: 2}}
    assert {:ok, %{items: items, next_cursor: nil}} = search(config(runtime), session, %{})

    assert Enum.sort(Enum.map(items, & &1.resource_id)) ==
             Enum.sort([uuid(note.resource_id), uuid(document.resource_id)])

    projected_ids = Enum.map(projection_snapshot(source), fn [row] -> row["resource_id"] end)

    assert Enum.sort(projected_ids) ==
             Enum.sort([uuid(note.resource_id), uuid(document.resource_id)])

    assert projection_snapshot(foreign) == foreign_entries
    assert canonical_snapshot(source) == canonical

    assert rebuild(config(runtime), session, uuid(foreign_note.resource_id)) ==
             {:error, :not_found}

    assert rebuild(config(runtime), session, Ecto.UUID.generate()) == {:error, :not_found}
  end

  test "kind-specific authority and actual process custody fail closed before rebuilding" do
    source = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    {document, _} = KnowledgeFixtures.ready_document!(source)
    {runtime, session, custodian} = live_runtime(source, ["asset.read"], false)
    config = config(runtime)
    note_id = uuid(note.resource_id)
    document_id = uuid(document.resource_id)

    assert rebuild(config, session, document_id) == {:ok, %{resources: 1, entries: 1}}
    assert rebuild(config, session, note_id) == {:error, :forbidden}
    assert rebuild(config, session, :all) == {:error, :forbidden}
    capabilities!(source, ["asset.read", "note.read"])
    assert rebuild(config, session, note_id) == {:error, :vault_locked}
    assert rebuild(config, session, :all) == {:error, :vault_locked}

    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "UPDATE core.vaults SET locked=false WHERE id=$1", [source.vault_id])
    end)

    hinted = %{session | unlocked?: true}
    assert rebuild(config, hinted, note_id) == {:error, :vault_locked}
    activate_unlock(custodian, session)
    assert rebuild(config, session, :all) == {:ok, %{resources: 2, entries: 2}}

    fresh = custodian!()

    assert {:ok, authorization} =
             AuthorizationDependencies.new(%{
               store: IdentityRepository,
               custodian: {KeyCustodian, fresh}
             })

    fresh_config = config(%{runtime | authorization: authorization})
    assert rebuild(fresh_config, hinted, note_id) == {:error, :vault_locked}
    assert rebuild(fresh_config, hinted, :all) == {:error, :vault_locked}
    assert rebuild(fresh_config, hinted, document_id) == {:ok, %{resources: 1, entries: 1}}

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE identity.sessions SET revoked_at=CURRENT_TIMESTAMP WHERE id=$1",
        [
          source.session_id
        ]
      )
    end)

    assert rebuild(config, hinted, document_id) == {:error, :unauthenticated}
    assert rebuild(config, hinted, :all) == {:error, :unauthenticated}
  end

  test "canonical UUID pages are bounded at 100 and each resource has an independent transaction" do
    source = KnowledgeFixtures.source!()
    notes = for _ <- 1..101, do: KnowledgeFixtures.note!(source)
    {document, _} = KnowledgeFixtures.ready_document!(source)
    ids = Enum.sort(Enum.map([document | notes], &uuid(&1.resource_id)))
    {runtime, session, _} = live_runtime(source, ["asset.read", "note.read"], true)
    tag = make_ref()
    observed = observe(runtime, tag)
    canonical = canonical_snapshot(source)

    assert rebuild(config(observed), session, :all) == {:ok, %{resources: 102, entries: 102}}
    {first, second} = Enum.split(ids, 100)
    after_id = List.last(first)
    assert_received {:rebuild_page, ^tag, nil, 100, {:ok, ^first}}
    assert_received {:rebuild_page, ^tag, ^after_id, 100, {:ok, ^second}}
    refute_received {:rebuild_page, ^tag, _, _, _}

    transactions =
      Enum.map(ids, fn expected ->
        assert_received {:rebuild_resource, ^tag, id, transaction}
        assert id == expected
        transaction
      end)

    assert Enum.uniq(transactions) == transactions

    for _ <- 1..104 do
      assert_received {:rebuild_content_callback, ^tag,
                       %{
                         required_capabilities: ["asset.read", "note.read"],
                         requires_unlocked?: true
                       }}
    end

    refute_received {:rebuild_content_callback, ^tag, _}
    assert canonical_snapshot(source) == canonical

    for limit <- [0, 101, "100"] do
      assert SearchProjectionReconciler.list_resource_ids(RequestRepo, nil, limit) ==
               {:error, Error.new(:invalid)}
    end

    assert SearchProjectionReconciler.list_resource_ids(RequestRepo, nil, 100) ==
             {:error, Error.new(:invalid)}

    assert ScopedRepo.transact(RequestRepo, session_scope(session), fn repo ->
             SearchProjectionReconciler.list_resource_ids(repo, after_id, 100)
           end) == {:ok, second}
  end

  test "malformed enumeration pages fail closed before any resource reconciliation" do
    source = KnowledgeFixtures.source!()
    notes = for _ <- 1..2, do: KnowledgeFixtures.note!(source)
    [first, second] = Enum.sort(Enum.map(notes, &uuid(&1.resource_id)))
    {runtime, session, _} = live_runtime(source, ["asset.read", "note.read"], true)
    canonical = canonical_snapshot(source)

    for malformed <- [
          [second, first],
          [first, first],
          [first | :improper],
          List.duplicate(first, 101),
          ["not-a-uuid"],
          [%{resource_id: first, title: "private-page-canary"}],
          %{items: [first]}
        ] do
      tag = make_ref()
      observed = observe(runtime, tag, %{transform_page: fn _ -> {:ok, malformed} end})
      assert rebuild(config(observed), session, :all) == {:error, :storage_unavailable}
      assert_received {:rebuild_page, ^tag, nil, 100, {:ok, [^first, ^second]}}
      refute_received {:rebuild_resource, ^tag, _, _}
      assert projection_snapshot(source) == []
    end

    positive = make_ref()

    assert rebuild(config(observe(runtime, positive)), session, :all) ==
             {:ok, %{resources: 2, entries: 2}}

    assert_received {:rebuild_resource, ^positive, ^first, _}
    assert canonical_snapshot(source) == canonical
  end

  test "full authority is checked before enumeration and missing or expired sessions reach no content callback" do
    source = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    KnowledgeFixtures.ready_document!(source)
    {runtime, session, _} = live_runtime(source, ["asset.read"], true)
    denied = make_ref()
    assert rebuild(config(observe(runtime, denied)), session, :all) == {:error, :forbidden}
    refute_received {:rebuild_page, ^denied, _, _, _}
    refute_received {:rebuild_resource, ^denied, _, _}
    refute_received {:rebuild_content_callback, ^denied, _}

    capabilities!(source, ["asset.read", "note.read"])
    positive = make_ref()

    assert rebuild(config(observe(runtime, positive)), session, :all) ==
             {:ok, %{resources: 2, entries: 2}}

    assert_received {:rebuild_page, ^positive, nil, 100, {:ok, [_, _]}}
    assert_received {:rebuild_resource, ^positive, _, _}
    assert_received {:rebuild_content_callback, ^positive, _}

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE identity.sessions SET expires_at=CURRENT_TIMESTAMP-interval '1 second' WHERE id=$1",
        [
          source.session_id
        ]
      )
    end)

    for stale <- [session, %{session | session_id: Ecto.UUID.generate()}] do
      tag = make_ref()
      config = config(observe(runtime, tag))
      assert rebuild(config, stale, :all) == {:error, :unauthenticated}
      assert rebuild(config, stale, uuid(note.resource_id)) == {:error, :unauthenticated}
      refute_received {:rebuild_page, ^tag, _, _, _}
      refute_received {:rebuild_resource, ^tag, _, _}
      refute_received {:rebuild_content_callback, ^tag, _}
    end
  end

  test "an interrupted command keeps completed resources and restarts from canonical state" do
    source = KnowledgeFixtures.source!()
    notes = for _ <- 1..3, do: KnowledgeFixtures.note!(source)
    [first, interrupted, last] = Enum.sort(Enum.map(notes, &uuid(&1.resource_id)))
    {runtime, session, _} = live_runtime(source, ["asset.read", "note.read"], true)
    canonical = canonical_snapshot(source)
    tag = make_ref()

    transform = fn id, result ->
      if id == interrupted,
        do: {:error, Error.new(:integrity_failure, message: "private-interruption-canary")},
        else: result
    end

    observed = observe(runtime, tag, %{transform_reconcile: transform})
    assert rebuild(config(observed), session, :all) == {:error, :integrity_failure}
    assert_received {:rebuild_resource, ^tag, ^first, _}
    assert_received {:rebuild_resource, ^tag, ^interrupted, _}
    refute_received {:rebuild_resource, ^tag, ^last, _}
    assert [[%{"resource_id" => ^first}]] = projection_snapshot(source)
    assert canonical_snapshot(source) == canonical

    assert rebuild(config(runtime), session, :all) == {:ok, %{resources: 3, entries: 3}}
    entries = projection_snapshot(source)
    remove_projections!(source)
    assert rebuild(config(runtime), session, :all) == {:ok, %{resources: 3, entries: 3}}
    assert projection_snapshot(source) == entries
    assert canonical_snapshot(source) == canonical
  end

  test "overflow from a resource adapter never returns a falsely complete success" do
    source = KnowledgeFixtures.source!()
    for _ <- 1..2, do: KnowledgeFixtures.note!(source)
    {runtime, session, _} = live_runtime(source, ["asset.read", "note.read"], true)
    tag = make_ref()

    observed =
      observe(runtime, tag, %{
        transform_reconcile: fn _, {:ok, _} -> {:ok, 9_223_372_036_854_775_807} end
      })

    assert rebuild(config(observed), session, :all) == {:error, :storage_unavailable}
  end

  test "revocation between canonical pages denies the next callback after releasing the authorization lock" do
    source = KnowledgeFixtures.source!()
    notes = for _ <- 1..101, do: KnowledgeFixtures.note!(source)
    ids = Enum.sort(Enum.map(notes, &uuid(&1.resource_id)))
    first_page_last = Enum.at(ids, 99)
    last = List.last(ids)
    {runtime, session, _} = live_runtime(source, ["asset.read", "note.read"], true)
    canonical = canonical_snapshot(source)
    observer = self()
    tag = make_ref()

    hook = fn
      {:resource, ^first_page_last}, {:ok, 1} ->
        send(observer, {:rebuild_between_pages, tag, self()})
        await_release!(tag)

      _, _ ->
        :ok
    end

    observed = observe(runtime, tag, %{observer: observer, after_scope: hook})
    task = Task.async(fn -> rebuild(config(observed), session, :all) end)

    try do
      assert_receive {:rebuild_between_pages, ^tag, blocked}, 5_000

      RequestRepo.checkout(fn ->
        AuthorizationLock.with_exclusive(
          RequestRepo,
          session.principal_id,
          session.vault_id,
          fn _ ->
            Fixtures.with_owner(fn ->
              query!(
                MigrationRepo,
                "UPDATE identity.sessions SET revoked_at=CURRENT_TIMESTAMP WHERE id=$1",
                [
                  source.session_id
                ]
              )
            end)
          end
        )
      end)

      for _ <- 1..101 do
        assert_received {:rebuild_content_callback, ^tag, _}
      end

      refute_received {:rebuild_content_callback, ^tag, _}
      send(blocked, {tag, :release})
      assert Task.await(task, 5_000) == {:error, :unauthenticated}
      refute_received {:rebuild_content_callback, ^tag, _}
      refute_received {:rebuild_resource, ^tag, ^last, _}
      assert_received {:rebuild_page, ^tag, nil, 100, {:ok, first_page}}
      assert first_page == Enum.take(ids, 100)
      refute_received {:rebuild_page, ^tag, ^first_page_last, _, _}
      assert length(projection_snapshot(source)) == 100
      assert canonical_snapshot(source) == canonical
    after
      send(task.pid, {tag, :release})
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "delete and restore between enumeration and reconciliation use the committed current canonical state" do
    source = KnowledgeFixtures.source!()
    {document, _} = KnowledgeFixtures.ready_document!(source)
    {runtime, session, _} = live_runtime(source, ["asset.read", "note.read"], true)
    project!(source, [document])
    canonical = canonical_snapshot(source)
    original_entries = projection_snapshot(source)

    for {deleted_at, expected_entries} <- [{:deleted, 0}, {:restored, 1}] do
      tag = make_ref()
      observer = self()

      hook = fn
        {:page, nil}, {:ok, [_]} ->
          send(observer, {:rebuild_enumerated, tag, self()})
          await_release!(tag)

        _, _ ->
          :ok
      end

      observed = observe(runtime, tag, %{observer: observer, after_scope: hook})
      task = Task.async(fn -> rebuild(config(observed), session, :all) end)

      try do
        assert_receive {:rebuild_enumerated, ^tag, blocked}, 5_000

        Fixtures.with_owner(fn ->
          statement =
            case deleted_at do
              :deleted -> "UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id=$1"
              :restored -> "UPDATE content.resources SET deleted_at=NULL WHERE id=$1"
            end

          query!(MigrationRepo, statement, [document.resource_id])
        end)

        send(blocked, {tag, :release})
        assert Task.await(task, 5_000) == {:ok, %{resources: 1, entries: expected_entries}}
        assert {:ok, %{items: items}} = search(config(runtime), session, %{})
        assert length(items) == expected_entries
        assert length(projection_snapshot(source)) == expected_entries
      after
        send(task.pid, {tag, :release})
        Task.shutdown(task, :brutal_kill)
      end
    end

    assert canonical_snapshot(source) == canonical
    assert projection_snapshot(source) == original_entries
    assert rebuild(config(runtime), session, :all) == {:ok, %{resources: 1, entries: 1}}
    assert projection_snapshot(source) == original_entries
  end

  test "historical canonical Notes and ready Documents are backfilled without later lifecycle events" do
    MigrationTestEnvironment.with_database(20_261_008_000_000, fn _environment ->
      source = KnowledgeFixtures.source!()
      note = KnowledgeFixtures.note!(source)
      {document, _} = KnowledgeFixtures.ready_document!(source)
      canonical = canonical_snapshot(source)

      assert %{rows: [[nil]]} =
               query!(RequestRepo, "SELECT to_regclass('content.search_entries')")

      assert outbox_count(source) == 0
      upgrade_historical!()
      assert canonical_snapshot(source) == canonical
      assert projection_snapshot(source) == []
      assert outbox_count(source) == 0
      {runtime, session, _} = live_runtime(source, ["asset.read", "note.read"], true)

      assert rebuild(config(runtime), session, :all) == {:ok, %{resources: 2, entries: 2}}
      entries = projection_snapshot(source)
      assert [[_], [_]] = entries
      assert {:ok, ranked} = search(config(runtime), session, %{q: "Note", limit: 1})
      assert [%{rank: rank}] = ranked.items
      assert rank > 0
      assert canonical_snapshot(source) == canonical
      assert outbox_count(source) == 0

      remove_projections!(source)
      project!(source, [note, document])
      assert projection_snapshot(source) == entries
      assert search(config(runtime), session, %{q: "Note", limit: 1}) == {:ok, ranked}
      assert canonical_snapshot(source) == canonical
      assert outbox_count(source) == 0
    end)
  end

  test "complete nonempty ranked pages retain exact ordering timestamps locators and cursors after rebuilding" do
    source = KnowledgeFixtures.source!()
    notes = for _ <- 1..2, do: KnowledgeFixtures.note!(source)
    {document, _} = KnowledgeFixtures.ready_document!(source)
    project!(source, [document | notes])
    {runtime, session, _} = live_runtime(source, ["asset.read", "note.read"], true)
    config = config(runtime)
    canonical = canonical_snapshot(source)
    queries = ["", "t", "Note", "Document"]
    before = Map.new(queries, fn q -> {q, search_pages!(config, session, %{q: q, limit: 1})} end)
    assert [_, _, _] = before["t"]
    assert [_, _] = before["Note"]
    assert [_] = before["Document"]

    for q <- ["t", "Note", "Document"] do
      assert Enum.all?(Enum.flat_map(before[q], & &1.items), &(&1.rank > 0))
    end

    remove_projections!(source)
    assert rebuild(config, session, :all) == {:ok, %{resources: 3, entries: 3}}

    for q <- queries do
      assert search_pages!(config, session, %{q: q, limit: 1}) == before[q]
    end

    assert canonical_snapshot(source) == canonical
  end

  defp search_pages!(config, session, params) do
    assert {:ok, page} = search(config, session, params)

    case page.next_cursor do
      nil -> [page]
      cursor -> [page | search_pages!(config, session, Map.put(params, :cursor, cursor))]
    end
  end

  defp observe(runtime, tag, options \\ %{}) do
    context = options |> Map.put_new(:observer, self()) |> Map.put(:tag, tag)

    runtime
    |> Map.put(:search_projection_reconciler, {ObservedReconciler, context})
    |> Map.put(:operation_scope, {ObservedScope, context})
  end

  defp await_release!(tag) do
    receive do
      {^tag, :release} -> :ok
    after
      5_000 -> raise "search rebuild barrier timed out"
    end
  end

  defp session_scope(session), do: Map.take(session, [:principal_id, :vault_id])

  defp upgrade_historical! do
    path = :singularity_storage |> :code.priv_dir() |> to_string() |> Path.join("repo/migrations")
    {:ok, pid} = MigrationRepo.start_link()
    compiler_options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      Ecto.Migrator.run(MigrationRepo, path, :up, all: true, log: false)
    after
      Code.compiler_options(compiler_options)
      Supervisor.stop(pid)
    end
  end

  defp outbox_count(source) do
    Fixtures.with_owner(fn ->
      %{rows: [[count]]} =
        query!(MigrationRepo, "SELECT count(*) FROM core.outbox_events WHERE vault_id=$1", [
          source.vault_id
        ])

      count
    end)
  end

  defp live_runtime(source, capabilities, unlocked?) do
    capabilities!(source, capabilities)
    token = :crypto.strong_rand_bytes(32)

    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "UPDATE identity.sessions SET token_digest=$2 WHERE id=$1", [
        source.session_id,
        :crypto.hash(:sha256, token)
      ])

      query!(MigrationRepo, "UPDATE core.vaults SET locked=$2 WHERE id=$1", [
        source.vault_id,
        not unlocked?
      ])
    end)

    custodian = custodian!()

    adapters = %{
      pre_auth: PreAuth,
      pre_auth_context: PreAuthRepo,
      custodian: KeyCustodian,
      custodian_context: custodian
    }

    resolver = %{resolve_session: fn token -> ResolveSession.run(adapters, token) end}
    opaque_id = Base.url_encode64(token, padding: false)
    assert {:ok, session} = Api.resolve_session(resolver, opaque_id)
    if unlocked?, do: activate_unlock(custodian, session)
    assert {:ok, session} = Api.resolve_session(resolver, opaque_id)
    assert session.unlocked? == unlocked?
    assert session.principal_id == uuid(source.principal_id)
    assert session.vault_id == uuid(source.vault_id)

    assert {:ok, authorization} =
             AuthorizationDependencies.new(%{
               store: IdentityRepository,
               custodian: {KeyCustodian, custodian}
             })

    runtime = %{
      authorization: authorization,
      authorization_lock: AuthorizationLock,
      operation_scope: OperationScope,
      request_repo: RequestRepo,
      scoped_repo: ScopedRepo,
      vault_lock: VaultLock
    }

    {runtime, session, custodian}
  end

  defp custodian! do
    lease_supervisor = start_supervised!({KeyLeaseSupervisor, name: nil}, id: make_ref())

    start_supervised!(
      {KeyCustodian,
       %{
         authorization: CustodyReader,
         clock: CustodyReader,
         context: %{},
         idle_lock: fn _ -> :ok end,
         key_reader: CustodyReader,
         object_key_loader: CustodyReader,
         lease_supervisor: lease_supervisor
       }},
      id: make_ref()
    )
  end

  defp activate_unlock(custodian, session) do
    assert {:ok, pending} =
             KeyCustodian.prepare_unlock(
               custodian,
               session |> Map.from_struct() |> Map.put(:vault_key, :crypto.strong_rand_bytes(32))
             )

    assert :ok = KeyCustodian.activate_unlock(custodian, pending)
  end

  defp capabilities!(source, names) do
    Fixtures.with_owner(fn ->
      for name <- ["asset.read", "note.read"] do
        query!(
          MigrationRepo,
          "INSERT INTO core.capabilities(id,name) VALUES($1,$2) ON CONFLICT(name) DO NOTHING",
          [
            KnowledgeFixtures.uuid(),
            name
          ]
        )
      end

      query!(
        MigrationRepo,
        "DELETE FROM core.principal_capabilities WHERE principal_id=$1 AND vault_id=$2",
        [
          source.principal_id,
          source.vault_id
        ]
      )

      for name <- names do
        query!(
          MigrationRepo,
          "INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name=$3",
          [
            source.principal_id,
            source.vault_id,
            name
          ]
        )
      end
    end)
  end

  defp project!(source, rows) do
    Fixtures.with_owner(fn ->
      for row <- rows do
        query!(MigrationRepo, "SELECT content.reconcile_search_resource_internal($1,$2)", [
          source.vault_id,
          row.resource_id
        ])
      end
    end)
  end

  defp remove_projections!(source) do
    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "DELETE FROM content.search_entries WHERE vault_id=$1", [
        source.vault_id
      ])
    end)
  end

  defp canonical_snapshot(source) do
    Fixtures.with_owner(fn ->
      for {table, order} <- [
            {"resources", "id"},
            {"resource_versions", "id"},
            {"note_versions", "resource_version_id"},
            {"document_versions", "resource_version_id"},
            {"document_fragments", "id"}
          ] do
        query!(
          MigrationRepo,
          "SELECT to_jsonb(canonical)::text FROM content.#{table} AS canonical WHERE vault_id=$1 ORDER BY #{order}",
          [
            source.vault_id
          ]
        ).rows
      end
    end)
  end

  defp projection_snapshot(source) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "SELECT to_jsonb(entry) FROM content.search_entries AS entry WHERE vault_id=$1 ORDER BY entry_id COLLATE \"C\"",
        [
          source.vault_id
        ]
      ).rows
    end)
  end

  defp config(runtime) do
    %{
      rebuild_search: fn session, selector ->
        apply(Singularity.Runtime.Search.Rebuild, :run, [runtime, session, selector])
      end,
      search_knowledge: fn session, params ->
        Singularity.Runtime.Search.Search.run(runtime, session, params)
      end
    }
  end

  defp search(config, session, params), do: Api.search_knowledge(config, session, params)

  defp rebuild(config, session, selector) do
    assert Code.ensure_loaded?(Api)
    assert function_exported?(Api, :rebuild_search, 3)
    apply(Api, :rebuild_search, [config, session, selector])
  end

  defp uuid(id), do: Ecto.UUID.load!(id)
end
