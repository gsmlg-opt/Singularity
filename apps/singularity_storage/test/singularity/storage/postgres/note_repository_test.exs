defmodule Singularity.Storage.Postgres.NoteRepositoryTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Core.NoteSaveResult
  alias Singularity.Core.NoteSnapshot
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.Postgres.NoteRepository
  alias Singularity.Storage.ScopedRepo

  setup do
    %{one: fixture, two: other_fixture} = Fixtures.two_vaults!()
    {:ok, fixture: load_ids(fixture), other_fixture: load_ids(other_fixture)}
  end

  test "create atomically persists revision zero, canonical projections, effects, and receipt", %{
    fixture: fixture
  } do
    title = "CREATE_TITLE_CANARY_#{Ecto.UUID.generate()}"
    markdown = "# CREATE_MARKDOWN_CANARY_#{Ecto.UUID.generate()}"
    intent = create_intent(fixture, title, markdown)

    assert {:ok,
            %NoteSaveResult{
              outcome: :saved,
              resource_id: resource_id,
              canonical_version_id: version_id,
              submitted_version_id: version_id,
              conflict_id: nil
            }} = scoped(fixture, &NoteRepository.create(&1, intent))

    scoped(fixture, fn repo ->
      assert %{
               rows: [[resource_dump, vault_dump, "private", "note", head_dump, ^title, nil, %{}]]
             } =
               query!(
                 repo,
                 """
                 SELECT id, vault_id, classification, kind, current_version_id,
                        title, deleted_at, metadata
                 FROM content.resources
                 WHERE id = $1
                 """,
                 [Ecto.UUID.dump!(resource_id)]
               )

      assert load_uuid(resource_dump) == resource_id
      assert load_uuid(vault_dump) == fixture.vault_id
      assert load_uuid(head_dump) == version_id

      assert %{rows: [[version_dump, resource_dump, vault_dump, "private", 0, head_inserted_at]]} =
               query!(
                 repo,
                 """
                 SELECT id, resource_id, vault_id, classification, revision, inserted_at
                 FROM content.resource_versions
                 WHERE id = $1
                 """,
                 [Ecto.UUID.dump!(version_id)]
               )

      assert load_uuid(version_dump) == version_id
      assert load_uuid(resource_dump) == resource_id
      assert load_uuid(vault_dump) == fixture.vault_id

      assert %{
               rows: [
                 [
                   version_dump,
                   resource_dump,
                   vault_dump,
                   "private",
                   ^title,
                   ^markdown,
                   principal_dump,
                   nil,
                   nil
                 ]
               ]
             } =
               query!(
                 repo,
                 """
                 SELECT resource_version_id, resource_id, vault_id, classification,
                        title, markdown, created_by_principal_id,
                        parent_version_id, merge_parent_version_id
                 FROM content.note_versions
                 WHERE resource_version_id = $1
                 """,
                 [Ecto.UUID.dump!(version_id)]
               )

      assert load_uuid(version_dump) == version_id
      assert load_uuid(resource_dump) == resource_id
      assert load_uuid(vault_dump) == fixture.vault_id
      assert load_uuid(principal_dump) == fixture.principal_id

      assert %{
               rows: [
                 [
                   resource_dump,
                   version_dump,
                   vault_dump,
                   "private",
                   ^title,
                   ^markdown,
                   projection_head_inserted_at
                 ]
               ]
             } =
               query!(
                 repo,
                 """
                 SELECT resource_id, resource_version_id, vault_id, classification,
                        title, markdown, head_inserted_at
                 FROM content.note_search_documents
                 WHERE resource_id = $1
                 """,
                 [Ecto.UUID.dump!(resource_id)]
               )

      assert load_uuid(resource_dump) == resource_id
      assert load_uuid(version_dump) == version_id
      assert load_uuid(vault_dump) == fixture.vault_id
      assert DateTime.compare(projection_head_inserted_at, head_inserted_at) == :eq

      assert_create_effects(repo, fixture, intent, resource_id, version_id)
      refute_canaries_in_side_channels(repo, intent, [title, markdown])
      :ok
    end)
  end

  test "canonical save appends revision one and moves every canonical pointer exactly", %{
    fixture: fixture
  } do
    create_title = "ORIGINAL_TITLE_CANARY_#{Ecto.UUID.generate()}"
    create_markdown = "# ORIGINAL_MARKDOWN_CANARY_#{Ecto.UUID.generate()}"
    create = create_intent(fixture, create_title, create_markdown)

    assert {:ok, %NoteSaveResult{} = created} =
             scoped(fixture, &NoteRepository.create(&1, create))

    save_title = "SAVED_TITLE_CANARY_#{Ecto.UUID.generate()}"
    save_markdown = "# SAVED_MARKDOWN_CANARY_#{Ecto.UUID.generate()}"

    save =
      save_intent(
        fixture,
        created.resource_id,
        created.canonical_version_id,
        save_title,
        save_markdown
      )

    assert {:ok,
            %NoteSaveResult{
              outcome: :saved,
              resource_id: resource_id,
              canonical_version_id: saved_version_id,
              submitted_version_id: saved_version_id,
              conflict_id: nil
            }} = scoped(fixture, &NoteRepository.save(&1, save))

    assert resource_id == created.resource_id
    refute saved_version_id == created.canonical_version_id

    scoped(fixture, fn repo ->
      assert %{rows: [[head_dump, ^save_title]]} =
               query!(
                 repo,
                 "SELECT current_version_id, title FROM content.resources WHERE id = $1",
                 [Ecto.UUID.dump!(resource_id)]
               )

      assert load_uuid(head_dump) == saved_version_id

      assert %{rows: [[initial_dump, 0, initial_inserted_at], [saved_dump, 1, saved_inserted_at]]} =
               query!(
                 repo,
                 """
                 SELECT id, revision, inserted_at
                 FROM content.resource_versions
                 WHERE resource_id = $1
                 ORDER BY revision
                 """,
                 [Ecto.UUID.dump!(resource_id)]
               )

      assert load_uuid(initial_dump) == created.canonical_version_id
      assert load_uuid(saved_dump) == saved_version_id
      assert DateTime.compare(saved_inserted_at, initial_inserted_at) in [:gt, :eq]

      assert %{
               rows: [
                 [initial_note_dump, ^create_title, ^create_markdown, nil, nil],
                 [saved_note_dump, ^save_title, ^save_markdown, parent_dump, nil]
               ]
             } =
               query!(
                 repo,
                 """
                 SELECT note.resource_version_id, note.title, note.markdown,
                        note.parent_version_id, note.merge_parent_version_id
                 FROM content.note_versions AS note
                 JOIN content.resource_versions AS version
                   ON version.id = note.resource_version_id
                 WHERE note.resource_id = $1
                 ORDER BY version.revision
                 """,
                 [Ecto.UUID.dump!(resource_id)]
               )

      assert load_uuid(initial_note_dump) == created.canonical_version_id
      assert load_uuid(saved_note_dump) == saved_version_id
      assert load_uuid(parent_dump) == created.canonical_version_id

      assert %{
               rows: [
                 [
                   projection_version_dump,
                   ^save_title,
                   ^save_markdown,
                   projection_head_inserted_at
                 ]
               ]
             } =
               query!(
                 repo,
                 """
                 SELECT resource_version_id, title, markdown, head_inserted_at
                 FROM content.note_search_documents
                 WHERE resource_id = $1
                 """,
                 [Ecto.UUID.dump!(resource_id)]
               )

      assert load_uuid(projection_version_dump) == saved_version_id
      assert DateTime.compare(projection_head_inserted_at, saved_inserted_at) == :eq

      assert %{rows: [["completed", "saved", receipt_resource_dump, receipt_version_dump]]} =
               query!(
                 repo,
                 """
                 SELECT state, outcome, resource_id, version_id
                 FROM content.note_mutation_receipts
                 WHERE mutation_id = $1
                 """,
                 [Ecto.UUID.dump!(save.mutation_id)]
               )

      assert load_uuid(receipt_resource_dump) == resource_id
      assert load_uuid(receipt_version_dump) == saved_version_id

      assert %{
               rows: [
                 [
                   "note.save",
                   "completed",
                   "private",
                   correlation_dump,
                   "note",
                   target_dump,
                   %{"version_id" => ^saved_version_id}
                 ]
               ]
             } =
               query!(
                 repo,
                 """
                 SELECT operation, result, classification, correlation_id,
                        target_type, target_id, metadata
                 FROM audit.events
                 WHERE correlation_id = $1
                 """,
                 [Ecto.UUID.dump!(save.correlation_id)]
               )

      assert load_uuid(correlation_dump) == save.correlation_id
      assert load_uuid(target_dump) == resource_id

      assert_current_changed_outbox(repo, fixture, save, resource_id, 1)

      refute_canaries_in_side_channels(repo, save, [save_title, save_markdown])
      :ok
    end)
  end

  test "create and save replay return winner identifiers without duplicate effects", %{
    fixture: fixture
  } do
    create = create_intent(fixture, "Replay create", "# Replay create")

    assert {:ok, %NoteSaveResult{} = first_create} =
             scoped(fixture, &NoteRepository.create(&1, create))

    assert {:ok, ^first_create} = scoped(fixture, &NoteRepository.create(&1, create))

    save =
      save_intent(
        fixture,
        first_create.resource_id,
        first_create.canonical_version_id,
        "Replay save",
        "# Replay save"
      )

    assert {:ok, %NoteSaveResult{} = first_save} =
             scoped(fixture, &NoteRepository.save(&1, save))

    assert {:ok, ^first_save} = scoped(fixture, &NoteRepository.save(&1, save))

    assert note_effect_counts(fixture, first_create.resource_id) == [2, 2, 1, 2, 2, 2]
  end

  test "a stale canonical save is a conflict with no writes in Task 5", %{fixture: fixture} do
    create = create_intent(fixture, "Stale original", "# Stale original")

    assert {:ok, %NoteSaveResult{} = created} =
             scoped(fixture, &NoteRepository.create(&1, create))

    first_save =
      save_intent(
        fixture,
        created.resource_id,
        created.canonical_version_id,
        "Accepted",
        "# Accepted"
      )

    assert {:ok, %NoteSaveResult{}} = scoped(fixture, &NoteRepository.save(&1, first_save))
    before = note_effect_counts(fixture, created.resource_id)
    canonical_before = canonical_state(fixture, created.resource_id)

    stale =
      save_intent(
        fixture,
        created.resource_id,
        created.canonical_version_id,
        "Stale",
        "# Stale"
      )

    assert {:error, %Error{code: :conflict, retryable?: false}} =
             scoped(fixture, &NoteRepository.save(&1, stale))

    assert note_effect_counts(fixture, created.resource_id) == before
    assert canonical_state(fixture, created.resource_id) == canonical_before
  end

  test "a missing typed base is not found and writes nothing", %{fixture: fixture} do
    create = create_intent(fixture, "Missing base", "# Missing base")

    assert {:ok, %NoteSaveResult{} = created} =
             scoped(fixture, &NoteRepository.create(&1, create))

    before = note_effect_counts(fixture, created.resource_id)
    canonical_before = canonical_state(fixture, created.resource_id)

    save =
      save_intent(
        fixture,
        created.resource_id,
        Ecto.UUID.generate(),
        "Missing base save",
        "# Missing base save"
      )

    assert {:error, %Error{code: :not_found, retryable?: false}} =
             scoped(fixture, &NoteRepository.save(&1, save))

    assert note_effect_counts(fixture, created.resource_id) == before
    assert canonical_state(fixture, created.resource_id) == canonical_before
  end

  test "a cross-vault typed base is not found and writes nothing", %{
    fixture: fixture,
    other_fixture: other_fixture
  } do
    target_create = create_intent(fixture, "Cross-vault target", "# Cross-vault target")
    foreign_create = create_intent(other_fixture, "Foreign base", "# Foreign base")

    assert {:ok, %NoteSaveResult{} = target} =
             scoped(fixture, &NoteRepository.create(&1, target_create))

    assert {:ok, %NoteSaveResult{} = foreign} =
             scoped(other_fixture, &NoteRepository.create(&1, foreign_create))

    before = note_effect_counts(fixture, target.resource_id)
    canonical_before = canonical_state(fixture, target.resource_id)

    save =
      save_intent(
        fixture,
        target.resource_id,
        foreign.canonical_version_id,
        "Cross-vault save",
        "# Cross-vault save"
      )

    assert {:error, %Error{code: :not_found, retryable?: false}} =
             scoped(fixture, &NoteRepository.save(&1, save))

    assert note_effect_counts(fixture, target.resource_id) == before
    assert canonical_state(fixture, target.resource_id) == canonical_before
  end

  test "a same-vault base owned by another note is invalid and writes nothing", %{
    fixture: fixture
  } do
    target_create = create_intent(fixture, "Target note", "# Target note")
    other_create = create_intent(fixture, "Other note", "# Other note")

    assert {:ok, %NoteSaveResult{} = target} =
             scoped(fixture, &NoteRepository.create(&1, target_create))

    assert {:ok, %NoteSaveResult{} = other} =
             scoped(fixture, &NoteRepository.create(&1, other_create))

    before = note_effect_counts(fixture, target.resource_id)
    canonical_before = canonical_state(fixture, target.resource_id)

    save =
      save_intent(
        fixture,
        target.resource_id,
        other.canonical_version_id,
        "Other note base",
        "# Other note base"
      )

    assert {:error, %Error{code: :invalid, retryable?: false}} =
             scoped(fixture, &NoteRepository.save(&1, save))

    assert note_effect_counts(fixture, target.resource_id) == before
    assert canonical_state(fixture, target.resource_id) == canonical_before
  end

  test "a tombstoned note is not found and writes no receipt or effects", %{fixture: fixture} do
    create = create_intent(fixture, "Tombstoned", "# Tombstoned")

    assert {:ok, %NoteSaveResult{} = created} =
             scoped(fixture, &NoteRepository.create(&1, create))

    scoped(fixture, fn repo ->
      query!(
        repo,
        "UPDATE content.resources SET deleted_at = CURRENT_TIMESTAMP WHERE id = $1",
        [Ecto.UUID.dump!(created.resource_id)]
      )

      :ok
    end)

    before = note_effect_counts(fixture, created.resource_id)

    save =
      save_intent(
        fixture,
        created.resource_id,
        created.canonical_version_id,
        "Hidden",
        "# Hidden"
      )

    assert {:error, %Error{code: :not_found}} = scoped(fixture, &NoteRepository.save(&1, save))
    assert note_effect_counts(fixture, created.resource_id) == before
  end

  test "malformed create and save intents return invalid without effects", %{fixture: fixture} do
    malformed_create =
      fixture
      |> create_intent("Malformed", "# Malformed")
      |> Map.put(:request_fingerprint, <<1>>)

    assert {:error, %Error{code: :invalid, retryable?: false}} =
             scoped(fixture, &NoteRepository.create(&1, malformed_create))

    assert note_effect_counts(fixture, Ecto.UUID.generate()) == [0, 0, 0, 0, 0, 0]

    create = create_intent(fixture, "Valid", "# Valid")

    assert {:ok, %NoteSaveResult{} = created} =
             scoped(fixture, &NoteRepository.create(&1, create))

    before = note_effect_counts(fixture, created.resource_id)

    malformed_save =
      save_intent(
        fixture,
        created.resource_id,
        created.canonical_version_id,
        "Malformed save",
        "# Malformed save"
      )
      |> Map.put(:base_version_id, "not-a-version")

    assert {:error, %Error{code: :invalid, retryable?: false}} =
             scoped(fixture, &NoteRepository.save(&1, malformed_save))

    assert note_effect_counts(fixture, created.resource_id) == before
  end

  defp create_intent(fixture, title, markdown) do
    {:ok, snapshot} =
      NoteSnapshot.initial(%{classification: :private, title: title, markdown: markdown})

    %{
      mutation_id: Ecto.UUID.generate(),
      principal_id: fixture.principal_id,
      vault_id: fixture.vault_id,
      classification: :private,
      correlation_id: Ecto.UUID.generate(),
      snapshot: snapshot,
      request_fingerprint: :crypto.hash(:sha256, [title, 0, markdown])
    }
  end

  defp save_intent(fixture, resource_id, base_version_id, title, markdown) do
    {:ok, snapshot} =
      NoteSnapshot.normal(%{
        classification: :private,
        title: title,
        markdown: markdown,
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
      request_fingerprint: :crypto.hash(:sha256, [resource_id, base_version_id, title, markdown])
    }
  end

  defp assert_create_effects(repo, fixture, intent, resource_id, version_id) do
    request_fingerprint = intent.request_fingerprint

    assert %{
             rows: [
               [
                 "note.create",
                 "completed",
                 "private",
                 correlation_dump,
                 "note",
                 target_dump,
                 %{"version_id" => ^version_id}
               ]
             ]
           } =
             query!(
               repo,
               """
               SELECT operation, result, classification, correlation_id,
                      target_type, target_id, metadata
               FROM audit.events
               WHERE correlation_id = $1
               """,
               [Ecto.UUID.dump!(intent.correlation_id)]
             )

    assert load_uuid(correlation_dump) == intent.correlation_id
    assert load_uuid(target_dump) == resource_id

    assert_current_changed_outbox(repo, fixture, intent, resource_id, 0)

    assert %{
             rows: [
               [
                 "create",
                 ^request_fingerprint,
                 "completed",
                 "saved",
                 receipt_resource_dump,
                 receipt_version_dump,
                 nil
               ]
             ]
           } =
             query!(
               repo,
               """
               SELECT operation, request_fingerprint, state, outcome,
                      resource_id, version_id, conflict_id
               FROM content.note_mutation_receipts
               WHERE mutation_id = $1
               """,
               [Ecto.UUID.dump!(intent.mutation_id)]
             )

    assert load_uuid(receipt_resource_dump) == resource_id
    assert load_uuid(receipt_version_dump) == version_id
  end

  defp assert_current_changed_outbox(repo, fixture, intent, resource_id, revision) do
    expected_idempotency_key = "note-current-changed:#{resource_id}:#{revision}"

    assert %{
             rows: [
               [
                 "note.current_changed",
                 ^expected_idempotency_key,
                 vault_dump,
                 principal_dump,
                 "note.write",
                 principal_epoch,
                 vault_epoch,
                 "private",
                 correlation_dump,
                 causation_dump,
                 ^revision,
                 %{"resource_id" => ^resource_id}
               ]
             ]
           } =
             query!(
               repo,
               """
               SELECT event_type, idempotency_key, vault_id, principal_id,
                      required_capability, principal_authorization_epoch,
                      vault_authorization_epoch, classification, correlation_id,
                      causation_id, expected_entity_revision, payload
               FROM core.outbox_events
               WHERE correlation_id = $1
               """,
               [Ecto.UUID.dump!(intent.correlation_id)]
             )

    assert load_uuid(vault_dump) == fixture.vault_id
    assert load_uuid(principal_dump) == fixture.principal_id
    assert load_uuid(correlation_dump) == intent.correlation_id
    assert load_uuid(causation_dump) == intent.mutation_id
    assert is_integer(principal_epoch) and principal_epoch >= 0
    assert is_integer(vault_epoch) and vault_epoch >= 0
  end

  defp refute_canaries_in_side_channels(repo, intent, canaries) do
    assert %{rows: [[audit_json]]} =
             query!(
               repo,
               "SELECT to_jsonb(event) FROM audit.events AS event WHERE correlation_id = $1",
               [
                 Ecto.UUID.dump!(intent.correlation_id)
               ]
             )

    assert %{rows: [[outbox_json]]} =
             query!(
               repo,
               "SELECT to_jsonb(event) FROM core.outbox_events AS event WHERE correlation_id = $1",
               [Ecto.UUID.dump!(intent.correlation_id)]
             )

    assert %{rows: [[receipt_json]]} =
             query!(
               repo,
               "SELECT to_jsonb(receipt) FROM content.note_mutation_receipts AS receipt WHERE mutation_id = $1",
               [Ecto.UUID.dump!(intent.mutation_id)]
             )

    encoded = JSON.encode!([audit_json, outbox_json, receipt_json])
    Enum.each(canaries, &refute(String.contains?(encoded, &1)))
  end

  defp note_effect_counts(fixture, resource_id) do
    scoped(fixture, fn repo ->
      %{rows: [counts]} =
        query!(
          repo,
          """
          SELECT
            (SELECT count(*) FROM content.resource_versions WHERE resource_id = $1),
            (SELECT count(*) FROM content.note_versions WHERE resource_id = $1),
            (SELECT count(*) FROM content.note_search_documents WHERE resource_id = $1),
            (SELECT count(*) FROM audit.events WHERE target_type = 'note' AND target_id = $1),
            (SELECT count(*) FROM core.outbox_events WHERE payload ->> 'resource_id' = $2),
            (SELECT count(*) FROM content.note_mutation_receipts WHERE resource_id = $1)
          """,
          [Ecto.UUID.dump!(resource_id), resource_id]
        )

      counts
    end)
  end

  defp canonical_state(fixture, resource_id) do
    scoped(fixture, fn repo ->
      %{rows: [state]} =
        query!(
          repo,
          """
          SELECT
            resource.current_version_id,
            resource.title,
            projection.resource_version_id,
            projection.title,
            projection.markdown
          FROM content.resources AS resource
          LEFT JOIN content.note_search_documents AS projection
            ON projection.resource_id = resource.id
           AND projection.vault_id = resource.vault_id
          WHERE resource.id = $1
          """,
          [Ecto.UUID.dump!(resource_id)]
        )

      state
    end)
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
