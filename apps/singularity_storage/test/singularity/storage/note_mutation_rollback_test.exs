defmodule Singularity.Storage.NoteMutationRollbackTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.NoteSaveResult
  alias Singularity.Core.NoteSnapshot
  alias Singularity.Storage.FailureInjector
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.Postgres.NoteRepository
  alias Singularity.Storage.ScopedRepo

  setup do
    %{one: fixture} = Fixtures.two_vaults!()
    {:ok, fixture: load_ids(fixture)}
  end

  test "every canonical write checkpoint rolls back the complete mutation", %{fixture: fixture} do
    assert {:ok, %NoteSaveResult{} = created} =
             scoped(fixture, &NoteRepository.create(&1, create_intent(fixture, "rollback")))

    for point <- [
          :after_snapshot,
          :after_head,
          :after_projection,
          :after_audit,
          :after_outbox,
          :after_receipt
        ] do
      intent =
        save_intent(
          fixture,
          created.resource_id,
          created.canonical_version_id,
          "rollback-#{point}"
        )
        |> inject(point)

      before = aggregate_state(fixture, created.resource_id)

      assert_raise RuntimeError, "injected failure at #{point}", fn ->
        scoped(fixture, &NoteRepository.save(&1, intent))
      end

      assert aggregate_state(fixture, created.resource_id) == before
      assert mutation_side_channel_counts(fixture, intent) == [0, 0, 0]
    end
  end

  test "the conflict checkpoint rolls back competitor, conflict, effects, and receipt", %{
    fixture: fixture
  } do
    assert {:ok, %NoteSaveResult{} = created} =
             scoped(fixture, &NoteRepository.create(&1, create_intent(fixture, "conflict")))

    accepted =
      save_intent(
        fixture,
        created.resource_id,
        created.canonical_version_id,
        "accepted"
      )

    assert {:ok, %NoteSaveResult{outcome: :saved}} =
             scoped(fixture, &NoteRepository.save(&1, accepted))

    stale =
      save_intent(
        fixture,
        created.resource_id,
        created.canonical_version_id,
        "competing"
      )
      |> inject(:after_conflict)

    before = aggregate_state(fixture, created.resource_id)

    assert_raise RuntimeError, "injected failure at after_conflict", fn ->
      scoped(fixture, &NoteRepository.save(&1, stale))
    end

    assert aggregate_state(fixture, created.resource_id) == before
    assert mutation_side_channel_counts(fixture, stale) == [0, 0, 0]
  end

  test "every merge checkpoint rolls back resolution, two-event effects, and receipt", %{
    fixture: fixture
  } do
    assert {:ok, %NoteSaveResult{} = created} =
             scoped(fixture, &NoteRepository.create(&1, create_intent(fixture, "merge-rollback")))

    accepted =
      save_intent(
        fixture,
        created.resource_id,
        created.canonical_version_id,
        "merge-accepted"
      )

    assert {:ok, %NoteSaveResult{outcome: :saved} = current} =
             scoped(fixture, &NoteRepository.save(&1, accepted))

    stale =
      save_intent(
        fixture,
        created.resource_id,
        created.canonical_version_id,
        "merge-competing"
      )

    assert {:ok, %NoteSaveResult{outcome: :conflict} = conflict} =
             scoped(fixture, &NoteRepository.save(&1, stale))

    for point <- [
          :after_snapshot,
          :after_head,
          :after_projection,
          :after_conflict,
          :after_audit,
          :after_outbox,
          :after_receipt
        ] do
      intent =
        merge_intent(fixture, created.resource_id, current, conflict, "merge-#{point}")
        |> inject(point)

      before = aggregate_state(fixture, created.resource_id)

      assert_raise RuntimeError, "injected failure at #{point}", fn ->
        scoped(fixture, &NoteRepository.merge(&1, intent))
      end

      assert aggregate_state(fixture, created.resource_id) == before
      assert mutation_side_channel_counts(fixture, intent) == [0, 0, 0]
    end
  end

  defp inject(intent, point) do
    Map.put(intent, :failure_injector, %{
      point => fn -> FailureInjector.run!(point, point) end
    })
  end

  defp aggregate_state(fixture, resource_id) do
    scoped(fixture, fn repo ->
      assert %{rows: [[state]]} =
               query!(
                 repo,
                 """
                 SELECT jsonb_build_object(
                   'resource', (
                     SELECT to_jsonb(resource)
                     FROM content.resources AS resource
                     WHERE resource.id = $1
                   ),
                   'versions', (
                     SELECT COALESCE(jsonb_agg(to_jsonb(version) ORDER BY version.revision), '[]'::jsonb)
                     FROM content.resource_versions AS version
                     WHERE version.resource_id = $1
                   ),
                   'snapshots', (
                     SELECT COALESCE(jsonb_agg(to_jsonb(snapshot) ORDER BY snapshot.resource_version_id), '[]'::jsonb)
                     FROM content.note_versions AS snapshot
                     WHERE snapshot.resource_id = $1
                   ),
                   'conflicts', (
                     SELECT COALESCE(jsonb_agg(to_jsonb(conflict) ORDER BY conflict.id), '[]'::jsonb)
                     FROM content.note_conflicts AS conflict
                     WHERE conflict.resource_id = $1
                   ),
                   'projection', (
                     SELECT to_jsonb(projection)
                     FROM content.note_search_documents AS projection
                     WHERE projection.resource_id = $1
                   ),
                   'audit', (
                     SELECT COALESCE(jsonb_agg(to_jsonb(event) ORDER BY event.id), '[]'::jsonb)
                     FROM audit.events AS event
                     WHERE event.target_type = 'note' AND event.target_id = $1
                   ),
                   'outbox', (
                     SELECT COALESCE(jsonb_agg(to_jsonb(event) ORDER BY event.id), '[]'::jsonb)
                     FROM core.outbox_events AS event
                     WHERE event.payload ->> 'resource_id' = $2
                   ),
                   'receipts', (
                     SELECT COALESCE(jsonb_agg(to_jsonb(receipt) ORDER BY receipt.mutation_id), '[]'::jsonb)
                     FROM content.note_mutation_receipts AS receipt
                     WHERE receipt.resource_id = $1
                   )
                 )
                 """,
                 [Ecto.UUID.dump!(resource_id), resource_id]
               )

      state
    end)
  end

  defp mutation_side_channel_counts(fixture, intent) do
    scoped(fixture, fn repo ->
      assert %{rows: [counts]} =
               query!(
                 repo,
                 """
                 SELECT
                   (SELECT count(*) FROM content.note_mutation_receipts WHERE mutation_id = $1),
                   (SELECT count(*) FROM audit.events WHERE correlation_id = $2),
                   (SELECT count(*) FROM core.outbox_events WHERE correlation_id = $2)
                 """,
                 [Ecto.UUID.dump!(intent.mutation_id), Ecto.UUID.dump!(intent.correlation_id)]
               )

      counts
    end)
  end

  defp create_intent(fixture, label) do
    {:ok, snapshot} =
      NoteSnapshot.initial(%{
        classification: :private,
        title: "#{label} original",
        markdown: "# #{label} original"
      })

    %{
      mutation_id: Ecto.UUID.generate(),
      principal_id: fixture.principal_id,
      vault_id: fixture.vault_id,
      classification: :private,
      correlation_id: Ecto.UUID.generate(),
      snapshot: snapshot,
      request_fingerprint: :crypto.hash(:sha256, "#{label}-create")
    }
  end

  defp save_intent(fixture, resource_id, base_version_id, label) do
    {:ok, snapshot} =
      NoteSnapshot.normal(%{
        classification: :private,
        title: "#{label} title",
        markdown: "# #{label} markdown",
        parent_version_id: base_version_id
      })

    %{
      mutation_id: Ecto.UUID.generate(),
      principal_id: fixture.principal_id,
      vault_id: fixture.vault_id,
      classification: :private,
      correlation_id: Ecto.UUID.generate(),
      resource_id: resource_id,
      base_version_id: base_version_id,
      snapshot: snapshot,
      request_fingerprint: :crypto.hash(:sha256, [resource_id, base_version_id, label])
    }
  end

  defp merge_intent(fixture, resource_id, current, conflict, label) do
    {:ok, snapshot} =
      NoteSnapshot.merge(%{
        classification: :private,
        title: "#{label} title",
        markdown: "# #{label} markdown",
        parent_version_id: current.canonical_version_id,
        merge_parent_version_id: conflict.submitted_version_id
      })

    %{
      mutation_id: Ecto.UUID.generate(),
      principal_id: fixture.principal_id,
      vault_id: fixture.vault_id,
      classification: :private,
      correlation_id: Ecto.UUID.generate(),
      resource_id: resource_id,
      conflict_id: conflict.conflict_id,
      expected_current_version_id: current.canonical_version_id,
      competing_version_id: conflict.submitted_version_id,
      snapshot: snapshot,
      request_fingerprint:
        :crypto.hash(:sha256, [
          resource_id,
          current.canonical_version_id,
          conflict.conflict_id,
          conflict.submitted_version_id,
          label
        ])
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
        {key, Ecto.UUID.load!(value)}

      pair ->
        pair
    end)
  end
end
