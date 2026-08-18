defmodule Singularity.Storage.NoteMutationConcurrencyTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration
  @barrier_timeout 5_000

  alias Singularity.Core.NoteSaveResult
  alias Singularity.Core.NoteSnapshot
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.Postgres.NoteRepository
  alias Singularity.Storage.ScopedRepo

  setup do
    %{one: fixture} = Fixtures.two_vaults!()
    {:ok, fixture: load_ids(fixture)}
  end

  test "same-base saves deterministically produce one canonical version and one conflict", %{
    fixture: fixture
  } do
    assert {:ok, %NoteSaveResult{} = created} =
             scoped(fixture, &NoteRepository.create(&1, create_intent(fixture)))

    gate = make_ref()

    intents = [
      save_intent(fixture, created, "race-a", gate),
      save_intent(fixture, created, "race-b", gate)
    ]

    tasks = start_save_tasks(fixture, intents, gate)
    ready = await_ready(tasks, gate)
    Enum.each(ready, fn {_label, task_pid, _backend_pid} -> send(task_pid, {gate, :start}) end)

    assert_receive {:resource_locked, ^gate, winner_label, winner_task}, @barrier_timeout

    {_, _loser_task, loser_backend} =
      Enum.find(ready, fn {label, _task_pid, _backend_pid} -> label != winner_label end)

    {_, _, winner_backend} =
      Enum.find(ready, fn {label, _task_pid, _backend_pid} -> label == winner_label end)

    await_blocked_by!(loser_backend, winner_backend)
    send(winner_task, {gate, :continue})

    assert_receive {:resource_locked, ^gate, _loser_label, loser_task}, @barrier_timeout
    send(loser_task, {gate, :continue})

    results = Enum.map(tasks, &Task.await(&1, @barrier_timeout))

    assert [conflict] =
             for({:ok, %NoteSaveResult{outcome: :conflict} = result} <- results, do: result)

    assert [saved] = for({:ok, %NoteSaveResult{outcome: :saved} = result} <- results, do: result)
    assert conflict.canonical_version_id == saved.submitted_version_id
    assert conflict.resource_id == saved.resource_id

    scoped(fixture, fn repo ->
      assert %{rows: [[0], [1], [2]]} =
               query!(
                 repo,
                 "SELECT revision FROM content.resource_versions WHERE resource_id = $1 ORDER BY revision",
                 [Ecto.UUID.dump!(created.resource_id)]
               )

      assert %{rows: snapshot_rows} =
               query!(
                 repo,
                 """
                 SELECT resource_version_id, parent_version_id
                 FROM content.note_versions
                 WHERE resource_id = $1 AND parent_version_id IS NOT NULL
                 ORDER BY resource_version_id
                 """,
                 [Ecto.UUID.dump!(created.resource_id)]
               )

      assert Enum.map(snapshot_rows, fn [_id, parent] -> load_uuid(parent) end) == [
               created.canonical_version_id,
               created.canonical_version_id
             ]

      assert %{rows: [[head_dump, projection_dump, 1]]} =
               query!(
                 repo,
                 """
                 SELECT resource.current_version_id, projection.resource_version_id,
                        (SELECT count(*) FROM content.note_search_documents WHERE resource_id = resource.id)
                 FROM content.resources AS resource
                 JOIN content.note_search_documents AS projection ON projection.resource_id = resource.id
                 WHERE resource.id = $1
                 """,
                 [Ecto.UUID.dump!(created.resource_id)]
               )

      assert load_uuid(head_dump) == saved.submitted_version_id
      assert load_uuid(projection_dump) == saved.submitted_version_id

      assert %{rows: [[base_dump, canonical_dump, competing_dump, "open"]]} =
               query!(
                 repo,
                 """
                 SELECT base_version_id, canonical_version_id, competing_version_id, state
                 FROM content.note_conflicts
                 WHERE id = $1
                 """,
                 [Ecto.UUID.dump!(conflict.conflict_id)]
               )

      assert load_uuid(base_dump) == created.canonical_version_id
      assert load_uuid(canonical_dump) == saved.submitted_version_id
      assert load_uuid(competing_dump) == conflict.submitted_version_id

      assert %{rows: [[2]]} =
               query!(
                 repo,
                 "SELECT count(*) FROM content.note_mutation_receipts WHERE mutation_id = ANY($1)",
                 [
                   [
                     Ecto.UUID.dump!(Enum.at(intents, 0).mutation_id),
                     Ecto.UUID.dump!(Enum.at(intents, 1).mutation_id)
                   ]
                 ]
               )

      :ok
    end)
  end

  test "simultaneous identical mutation claims use a barrier and run the callback once", %{
    fixture: fixture
  } do
    assert {:ok, %NoteSaveResult{} = created} =
             scoped(fixture, &NoteRepository.create(&1, create_intent(fixture)))

    gate = make_ref()
    intent = save_intent(fixture, created, "same-claim", gate)
    tasks = start_save_tasks(fixture, [intent, intent], gate)
    ready = await_ready(tasks, gate)
    Enum.each(ready, fn {_label, task_pid, _backend_pid} -> send(task_pid, {gate, :start}) end)

    assert_receive {:resource_locked, ^gate, owner_label, owner_task}, @barrier_timeout

    {_, _waiter_task, waiter_backend} =
      Enum.find(ready, fn {label, _task_pid, _backend_pid} -> label != owner_label end)

    {_, _, owner_backend} =
      Enum.find(ready, fn {label, _task_pid, _backend_pid} -> label == owner_label end)

    await_blocked_by!(waiter_backend, owner_backend)
    send(owner_task, {gate, :continue})

    results = Enum.map(tasks, &Task.await(&1, @barrier_timeout))
    assert [{:ok, %NoteSaveResult{} = result}, {:ok, result}] = results
    refute_receive {:resource_locked, ^gate, _label, _task}, 0

    scoped(fixture, fn repo ->
      assert %{rows: [[1, 2, 1]]} =
               query!(
                 repo,
                 """
                 SELECT
                   (SELECT count(*) FROM content.note_mutation_receipts WHERE mutation_id = $1),
                   (SELECT count(*) FROM content.resource_versions WHERE resource_id = $2),
                   (SELECT count(*) FROM core.outbox_events WHERE correlation_id = $3)
                 """,
                 [
                   Ecto.UUID.dump!(intent.mutation_id),
                   Ecto.UUID.dump!(created.resource_id),
                   Ecto.UUID.dump!(intent.correlation_id)
                 ]
               )

      :ok
    end)
  end

  defp start_save_tasks(fixture, intents, gate) do
    parent = self()

    intents
    |> Enum.with_index()
    |> Enum.map(fn {intent, label} ->
      Task.async(fn ->
        RequestRepo.checkout(fn ->
          ScopedRepo.transact(
            RequestRepo,
            %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
            fn repo ->
              %{rows: [[backend_pid]]} = query!(repo, "SELECT pg_backend_pid()")
              send(parent, {:save_ready, gate, label, self(), backend_pid})

              receive do
                {^gate, :start} -> :ok
              after
                @barrier_timeout -> raise "save start barrier timed out"
              end

              checkpoint = fn ->
                send(parent, {:resource_locked, gate, label, self()})

                receive do
                  {^gate, :continue} -> :ok
                after
                  @barrier_timeout -> raise "resource lock barrier timed out"
                end
              end

              intent
              |> Map.put(:failure_injector, %{after_resource_lock: checkpoint})
              |> then(&NoteRepository.save(repo, &1))
            end
          )
        end)
      end)
    end)
  end

  defp await_ready(tasks, gate) do
    for _task <- tasks do
      assert_receive {:save_ready, ^gate, label, task_pid, backend_pid}, @barrier_timeout
      {label, task_pid, backend_pid}
    end
  end

  defp await_blocked_by!(waiting_backend, blocking_backend, attempts \\ 200)

  defp await_blocked_by!(_waiting_backend, _blocking_backend, 0) do
    flunk("save contender did not block on the expected connection")
  end

  defp await_blocked_by!(waiting_backend, blocking_backend, attempts) do
    %{rows: [[blocked?]]} =
      query!(
        RequestRepo,
        "SELECT $2 = ANY(pg_blocking_pids($1))",
        [waiting_backend, blocking_backend]
      )

    if blocked? do
      :ok
    else
      Process.sleep(10)
      await_blocked_by!(waiting_backend, blocking_backend, attempts - 1)
    end
  end

  defp create_intent(fixture) do
    {:ok, snapshot} =
      NoteSnapshot.initial(%{
        classification: :private,
        title: "Concurrent original",
        markdown: "# Concurrent original"
      })

    %{
      mutation_id: Ecto.UUID.generate(),
      principal_id: fixture.principal_id,
      vault_id: fixture.vault_id,
      classification: :private,
      correlation_id: Ecto.UUID.generate(),
      snapshot: snapshot,
      request_fingerprint: :crypto.hash(:sha256, "concurrent-create")
    }
  end

  defp save_intent(fixture, created, label, gate) do
    title = "Concurrent #{label}"
    markdown = "# Concurrent #{label}"

    {:ok, snapshot} =
      NoteSnapshot.normal(%{
        classification: :private,
        title: title,
        markdown: markdown,
        parent_version_id: created.canonical_version_id
      })

    %{
      mutation_id: Ecto.UUID.generate(),
      principal_id: fixture.principal_id,
      vault_id: fixture.vault_id,
      classification: :private,
      correlation_id: Ecto.UUID.generate(),
      resource_id: created.resource_id,
      base_version_id: created.canonical_version_id,
      snapshot: snapshot,
      request_fingerprint:
        :crypto.hash(:sha256, [label, gate |> :erlang.phash2() |> Integer.to_string()])
    }
  end

  defp scoped(fixture, fun) do
    ScopedRepo.transact(
      RequestRepo,
      %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
      fun
    )
  end

  defp load_ids(fixture) do
    Map.new(fixture, fn
      {key, value}
      when key in [
             :account_id,
             :asset_id,
             :credential_id,
             :principal_id,
             :resource_id,
             :resource_version_id,
             :session_id,
             :vault_id
           ] ->
        {key, load_uuid(value)}

      pair ->
        pair
    end)
  end

  defp load_uuid(uuid), do: Ecto.UUID.load!(uuid)
end
