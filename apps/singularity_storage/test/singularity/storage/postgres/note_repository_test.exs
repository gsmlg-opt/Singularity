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

  test "a stale save preserves a competing snapshot and open conflict without moving canonical state",
       %{
         fixture: fixture
       } do
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

    assert {:ok, %NoteSaveResult{canonical_version_id: accepted_id}} =
             scoped(fixture, &NoteRepository.save(&1, first_save))

    canonical_before = canonical_state(fixture, created.resource_id)

    stale =
      save_intent(
        fixture,
        created.resource_id,
        created.canonical_version_id,
        "Stale",
        "# Stale"
      )

    assert {:ok,
            %NoteSaveResult{
              outcome: :conflict,
              resource_id: resource_id,
              canonical_version_id: ^accepted_id,
              submitted_version_id: competing_id,
              conflict_id: conflict_id
            }} = scoped(fixture, &NoteRepository.save(&1, stale))

    assert resource_id == created.resource_id
    assert canonical_state(fixture, created.resource_id) == canonical_before

    scoped(fixture, fn repo ->
      assert %{rows: [[0], [1], [2]]} =
               query!(
                 repo,
                 "SELECT revision FROM content.resource_versions WHERE resource_id = $1 ORDER BY revision",
                 [Ecto.UUID.dump!(created.resource_id)]
               )

      assert %{rows: [[parent_dump, nil, "Stale", "# Stale"]]} =
               query!(
                 repo,
                 """
                 SELECT parent_version_id, merge_parent_version_id, title, markdown
                 FROM content.note_versions
                 WHERE resource_version_id = $1
                 """,
                 [Ecto.UUID.dump!(competing_id)]
               )

      assert load_uuid(parent_dump) == created.canonical_version_id

      assert %{
               rows: [
                 [
                   base_dump,
                   canonical_dump,
                   competing_dump,
                   "open",
                   nil,
                   nil
                 ]
               ]
             } =
               query!(
                 repo,
                 """
                 SELECT base_version_id, canonical_version_id, competing_version_id,
                        state, resolution_version_id, resolved_at
                 FROM content.note_conflicts
                 WHERE id = $1
                 """,
                 [Ecto.UUID.dump!(conflict_id)]
               )

      assert load_uuid(base_dump) == created.canonical_version_id
      assert load_uuid(canonical_dump) == accepted_id
      assert load_uuid(competing_dump) == competing_id

      assert %{rows: [["completed", "conflict", receipt_version, receipt_conflict]]} =
               query!(
                 repo,
                 """
                 SELECT state, outcome, version_id, conflict_id
                 FROM content.note_mutation_receipts
                 WHERE mutation_id = $1
                 """,
                 [Ecto.UUID.dump!(stale.mutation_id)]
               )

      assert load_uuid(receipt_version) == competing_id
      assert load_uuid(receipt_conflict) == conflict_id

      assert %{
               rows: [
                 [
                   "note.save",
                   "completed",
                   %{"conflict_id" => ^conflict_id, "version_id" => ^competing_id}
                 ]
               ]
             } =
               query!(
                 repo,
                 "SELECT operation, result, metadata FROM audit.events WHERE correlation_id = $1",
                 [Ecto.UUID.dump!(stale.correlation_id)]
               )

      assert %{
               rows: [
                 [
                   "note.conflict_created",
                   %{"conflict_id" => ^conflict_id, "resource_id" => ^resource_id}
                 ]
               ]
             } =
               query!(
                 repo,
                 "SELECT event_type, payload FROM core.outbox_events WHERE correlation_id = $1",
                 [Ecto.UUID.dump!(stale.correlation_id)]
               )

      refute_canaries_in_side_channels(repo, stale, ["Stale", "# Stale"])
      :ok
    end)
  end

  test "merge requires the expected current head and returns conflict without writes when stale",
       %{
         fixture: fixture
       } do
    scenario = conflict_scenario(fixture, "stale-merge")
    before = mutation_state(fixture, scenario.created.resource_id)

    merge =
      merge_intent(
        fixture,
        scenario.created.resource_id,
        scenario.conflict.conflict_id,
        scenario.created.canonical_version_id,
        scenario.conflict.submitted_version_id,
        "Stale merge",
        "# Stale merge"
      )

    assert {:error, %Error{code: :conflict, retryable?: false}} =
             scoped(fixture, &NoteRepository.merge(&1, merge))

    assert mutation_state(fixture, scenario.created.resource_id) == before
  end

  test "merge creates a two-parent canonical snapshot and resolves only the selected conflict", %{
    fixture: fixture
  } do
    scenario = conflict_scenario(fixture, "merge")

    second_stale =
      save_intent(
        fixture,
        scenario.created.resource_id,
        scenario.created.canonical_version_id,
        "Other competing",
        "# Other competing"
      )

    assert {:ok, %NoteSaveResult{outcome: :conflict} = other_conflict} =
             scoped(fixture, &NoteRepository.save(&1, second_stale))

    merge =
      merge_intent(
        fixture,
        scenario.created.resource_id,
        scenario.conflict.conflict_id,
        scenario.accepted.canonical_version_id,
        scenario.conflict.submitted_version_id,
        "Merged title",
        "# Merged markdown"
      )

    assert {:ok,
            %NoteSaveResult{
              outcome: :saved,
              canonical_version_id: merged_id,
              submitted_version_id: merged_id,
              conflict_id: nil
            }} = scoped(fixture, &NoteRepository.merge(&1, merge))

    historical_conflict = scenario.conflict
    after_merge = mutation_state(fixture, scenario.created.resource_id)

    assert {:ok, ^historical_conflict} =
             scoped(fixture, &NoteRepository.save(&1, scenario.stale_intent))

    assert mutation_state(fixture, scenario.created.resource_id) == after_merge

    scoped(fixture, fn repo ->
      assert %{
               rows: [
                 [head_dump, "Merged title", projection_dump, "Merged title", "# Merged markdown"]
               ]
             } =
               query!(
                 repo,
                 """
                 SELECT resource.current_version_id, resource.title,
                        projection.resource_version_id, projection.title, projection.markdown
                 FROM content.resources AS resource
                 JOIN content.note_search_documents AS projection
                   ON projection.resource_id = resource.id
                 WHERE resource.id = $1
                 """,
                 [Ecto.UUID.dump!(scenario.created.resource_id)]
               )

      assert load_uuid(head_dump) == merged_id
      assert load_uuid(projection_dump) == merged_id

      assert %{rows: [[4]]} =
               query!(
                 repo,
                 "SELECT revision FROM content.resource_versions WHERE id = $1",
                 [Ecto.UUID.dump!(merged_id)]
               )

      assert %{rows: [[parent_dump, merge_parent_dump]]} =
               query!(
                 repo,
                 "SELECT parent_version_id, merge_parent_version_id FROM content.note_versions WHERE resource_version_id = $1",
                 [Ecto.UUID.dump!(merged_id)]
               )

      assert load_uuid(parent_dump) == scenario.accepted.canonical_version_id
      assert load_uuid(merge_parent_dump) == scenario.conflict.submitted_version_id

      assert %{rows: conflict_rows} =
               query!(
                 repo,
                 """
                 SELECT id, state, resolution_version_id, resolved_at
                 FROM content.note_conflicts
                 WHERE id = ANY($1)
                 ORDER BY id
                 """,
                 [
                   [
                     Ecto.UUID.dump!(scenario.conflict.conflict_id),
                     Ecto.UUID.dump!(other_conflict.conflict_id)
                   ]
                 ]
               )

      conflicts =
        Map.new(conflict_rows, fn [id, state, resolution_id, resolved_at] ->
          {load_uuid(id), {state, load_optional_uuid(resolution_id), resolved_at}}
        end)

      assert {"resolved", ^merged_id, %DateTime{}} =
               Map.fetch!(conflicts, scenario.conflict.conflict_id)

      assert {"open", nil, nil} = Map.fetch!(conflicts, other_conflict.conflict_id)

      assert %{rows: [["completed", "saved", receipt_version, nil]]} =
               query!(
                 repo,
                 "SELECT state, outcome, version_id, conflict_id FROM content.note_mutation_receipts WHERE mutation_id = $1",
                 [Ecto.UUID.dump!(merge.mutation_id)]
               )

      assert load_uuid(receipt_version) == merged_id

      assert %{
               rows: [
                 [
                   "note.merge",
                   "completed",
                   %{"conflict_id" => selected_conflict, "version_id" => ^merged_id}
                 ]
               ]
             } =
               query!(
                 repo,
                 "SELECT operation, result, metadata FROM audit.events WHERE correlation_id = $1",
                 [Ecto.UUID.dump!(merge.correlation_id)]
               )

      assert selected_conflict == scenario.conflict.conflict_id

      assert %{rows: event_rows} =
               query!(
                 repo,
                 "SELECT event_type, payload FROM core.outbox_events WHERE correlation_id = $1 ORDER BY event_type",
                 [Ecto.UUID.dump!(merge.correlation_id)]
               )

      assert event_rows == [
               [
                 "note.conflict_resolved",
                 %{
                   "conflict_id" => scenario.conflict.conflict_id,
                   "resource_id" => scenario.created.resource_id
                 }
               ],
               ["note.current_changed", %{"resource_id" => scenario.created.resource_id}]
             ]

      refute_canaries_in_side_channels(repo, merge, ["Merged title", "# Merged markdown"])
      :ok
    end)
  end

  test "merge rejects a mismatched competitor or resolved conflict as invalid without writes", %{
    fixture: fixture
  } do
    scenario = conflict_scenario(fixture, "invalid-merge")

    mismatched =
      merge_intent(
        fixture,
        scenario.created.resource_id,
        scenario.conflict.conflict_id,
        scenario.accepted.canonical_version_id,
        Ecto.UUID.generate(),
        "Mismatched merge",
        "# Mismatched merge"
      )

    before_mismatch = mutation_state(fixture, scenario.created.resource_id)

    assert {:error, %Error{code: :invalid, retryable?: false}} =
             scoped(fixture, &NoteRepository.merge(&1, mismatched))

    assert mutation_state(fixture, scenario.created.resource_id) == before_mismatch

    valid =
      merge_intent(
        fixture,
        scenario.created.resource_id,
        scenario.conflict.conflict_id,
        scenario.accepted.canonical_version_id,
        scenario.conflict.submitted_version_id,
        "Resolved merge",
        "# Resolved merge"
      )

    assert {:ok, %NoteSaveResult{outcome: :saved} = resolved} =
             scoped(fixture, &NoteRepository.merge(&1, valid))

    closed =
      merge_intent(
        fixture,
        scenario.created.resource_id,
        scenario.conflict.conflict_id,
        resolved.canonical_version_id,
        scenario.conflict.submitted_version_id,
        "Closed merge",
        "# Closed merge"
      )

    before_closed = mutation_state(fixture, scenario.created.resource_id)

    assert {:error, %Error{code: :invalid, retryable?: false}} =
             scoped(fixture, &NoteRepository.merge(&1, closed))

    assert mutation_state(fixture, scenario.created.resource_id) == before_closed
  end

  test "merge classifies a same-vault conflict owned by another note as invalid without writes",
       %{
         fixture: fixture
       } do
    assert {:ok, %NoteSaveResult{} = target} =
             scoped(
               fixture,
               &NoteRepository.create(
                 &1,
                 create_intent(fixture, "Target merge note", "# Target merge note")
               )
             )

    other = conflict_scenario(fixture, "other-note-conflict")

    merge =
      merge_intent(
        fixture,
        target.resource_id,
        other.conflict.conflict_id,
        target.canonical_version_id,
        other.conflict.submitted_version_id,
        "Wrong note merge",
        "# Wrong note merge"
      )

    target_before = mutation_state(fixture, target.resource_id)
    other_before = mutation_state(fixture, other.created.resource_id)

    assert {:error, %Error{code: :invalid, retryable?: false}} =
             scoped(fixture, &NoteRepository.merge(&1, merge))

    assert mutation_state(fixture, target.resource_id) == target_before
    assert mutation_state(fixture, other.created.resource_id) == other_before

    scoped(fixture, fn repo ->
      assert %{rows: [[0, 0, 0]]} =
               query!(
                 repo,
                 """
                 SELECT
                   (SELECT count(*) FROM content.note_mutation_receipts WHERE mutation_id = $1),
                   (SELECT count(*) FROM audit.events WHERE correlation_id = $2),
                   (SELECT count(*) FROM core.outbox_events WHERE correlation_id = $2)
                 """,
                 [Ecto.UUID.dump!(merge.mutation_id), Ecto.UUID.dump!(merge.correlation_id)]
               )

      :ok
    end)
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

  test "canonical, exact-version, conflict-detail, history, and Trash reads are scoped and deterministic",
       %{
         fixture: fixture
       } do
    scenario = conflict_scenario(fixture, "reads")

    scoped(fixture, fn repo ->
      assert {:ok, canonical} =
               NoteRepository.get(repo, fixture.vault_id, scenario.created.resource_id)

      assert canonical.resource_id == scenario.created.resource_id
      assert canonical.resource_version_id == scenario.accepted.canonical_version_id
      assert canonical.title == "reads accepted"
      assert canonical.markdown == "# reads accepted"
      assert canonical.revision == 1
      assert canonical.classification == :private
      assert canonical.deleted_at == nil

      assert {:ok, initial} =
               NoteRepository.get_version(
                 repo,
                 fixture.vault_id,
                 scenario.created.resource_id,
                 scenario.created.canonical_version_id
               )

      assert initial.resource_version_id == scenario.created.canonical_version_id
      assert initial.title == "reads original"
      assert initial.revision == 0
      assert initial.canonical? == false

      assert {:ok, detail} =
               NoteRepository.get_conflict(
                 repo,
                 fixture.vault_id,
                 scenario.created.resource_id,
                 scenario.conflict.conflict_id
               )

      assert detail.conflict.conflict_id == scenario.conflict.conflict_id
      assert detail.conflict.state == :open
      assert detail.current.resource_version_id == scenario.accepted.canonical_version_id
      assert detail.competing.resource_version_id == scenario.conflict.submitted_version_id

      assert {:ok, %{items: [revision_two, revision_one], next_cursor: cursor}} =
               NoteRepository.history(
                 repo,
                 fixture.vault_id,
                 scenario.created.resource_id,
                 %{limit: 2, cursor: nil}
               )

      assert [revision_two.revision, revision_one.revision] == [2, 1]
      assert is_binary(cursor)
      refute Map.has_key?(revision_two, :markdown)

      assert {:ok, %{items: [revision_zero], next_cursor: :done}} =
               NoteRepository.history(
                 repo,
                 fixture.vault_id,
                 scenario.created.resource_id,
                 %{limit: 2, cursor: cursor}
               )

      assert revision_zero.revision == 0

      assert {:ok, %{items: [], next_cursor: :done}} =
               NoteRepository.trash(repo, fixture.vault_id, %{limit: 10, cursor: nil})

      :ok
    end)
  end

  test "same-vault foreign read IDs are invalid while absent and cross-vault IDs are not found",
       %{
         fixture: fixture,
         other_fixture: other_fixture
       } do
    assert {:ok, %NoteSaveResult{} = target} =
             scoped(
               fixture,
               &NoteRepository.create(
                 &1,
                 create_intent(fixture, "Read target", "# Read target")
               )
             )

    other = conflict_scenario(fixture, "read-other")

    cross =
      create_intent(other_fixture, "Cross-vault read", "# Cross-vault read")

    assert {:ok, %NoteSaveResult{} = cross_note} =
             scoped(other_fixture, &NoteRepository.create(&1, cross))

    scoped(fixture, fn repo ->
      assert {:error, %Error{code: :invalid}} =
               NoteRepository.get_version(
                 repo,
                 fixture.vault_id,
                 target.resource_id,
                 other.created.canonical_version_id
               )

      assert {:error, %Error{code: :invalid}} =
               NoteRepository.get_conflict(
                 repo,
                 fixture.vault_id,
                 target.resource_id,
                 other.conflict.conflict_id
               )

      for resource_id <- [Ecto.UUID.generate(), cross_note.resource_id] do
        assert {:error, %Error{code: :not_found}} =
                 NoteRepository.get(repo, fixture.vault_id, resource_id)
      end

      :ok
    end)
  end

  test "tombstone and restore are receipt-first, replayable, and create no content versions", %{
    fixture: fixture
  } do
    scenario = conflict_scenario(fixture, "lifecycle")
    before_versions = version_count(fixture, scenario.created.resource_id)

    tombstone =
      tombstone_intent(
        fixture,
        scenario.created.resource_id,
        scenario.accepted.canonical_version_id
      )

    assert {:ok,
            %{
              state: :tombstoned,
              resource_id: resource_id,
              canonical_version_id: canonical_version_id
            } = tombstoned} = scoped(fixture, &NoteRepository.tombstone(&1, tombstone))

    assert resource_id == scenario.created.resource_id
    assert canonical_version_id == scenario.accepted.canonical_version_id
    assert {:ok, ^tombstoned} = scoped(fixture, &NoteRepository.tombstone(&1, tombstone))
    assert version_count(fixture, resource_id) == before_versions

    scoped(fixture, fn repo ->
      assert {:error, %Error{code: :not_found}} =
               NoteRepository.get(repo, fixture.vault_id, resource_id)

      assert {:ok, %{items: [trash_item], next_cursor: :done}} =
               NoteRepository.trash(repo, fixture.vault_id, %{limit: 10, cursor: nil})

      assert trash_item.resource_id == resource_id
      assert trash_item.resource_version_id == canonical_version_id
      assert %DateTime{} = trash_item.deleted_at
      assert trash_item.deleted? == true
      assert trash_item.open_conflict_count == 1

      assert Enum.sort(Map.keys(trash_item)) ==
               Enum.sort([
                 :resource_id,
                 :resource_version_id,
                 :vault_id,
                 :classification,
                 :title,
                 :revision,
                 :updated_at,
                 :deleted?,
                 :open_conflict_count,
                 :deleted_at
               ])

      assert %{rows: [[0]]} =
               query!(
                 repo,
                 "SELECT count(*) FROM content.note_search_documents WHERE resource_id = $1",
                 [Ecto.UUID.dump!(resource_id)]
               )

      :ok
    end)

    blocked_save =
      save_intent(
        fixture,
        resource_id,
        canonical_version_id,
        "Blocked tombstone save",
        "# Blocked tombstone save"
      )

    assert {:error, %Error{code: :not_found}} =
             scoped(fixture, &NoteRepository.save(&1, blocked_save))

    blocked_merge =
      merge_intent(
        fixture,
        resource_id,
        scenario.conflict.conflict_id,
        canonical_version_id,
        scenario.conflict.submitted_version_id,
        "Blocked tombstone merge",
        "# Blocked tombstone merge"
      )

    assert {:error, %Error{code: :not_found}} =
             scoped(fixture, &NoteRepository.merge(&1, blocked_merge))

    restore = restore_intent(fixture, resource_id)

    assert {:ok,
            %{
              state: :restored,
              resource_id: ^resource_id,
              canonical_version_id: ^canonical_version_id
            } = restored} = scoped(fixture, &NoteRepository.restore(&1, restore))

    assert {:ok, ^restored} = scoped(fixture, &NoteRepository.restore(&1, restore))
    assert version_count(fixture, resource_id) == before_versions

    scoped(fixture, fn repo ->
      assert {:ok, %{resource_version_id: ^canonical_version_id}} =
               NoteRepository.get(repo, fixture.vault_id, resource_id)

      assert %{rows: [[^canonical_version_id]]} =
               query!(
                 repo,
                 "SELECT resource_version_id::text FROM content.note_search_documents WHERE resource_id = $1",
                 [Ecto.UUID.dump!(resource_id)]
               )

      :ok
    end)

    assert {:error, %Error{code: :not_found}} =
             scoped(fixture, &NoteRepository.restore(&1, restore_intent(fixture, resource_id)))

    refute_lifecycle_plaintext(fixture, [tombstone, restore], [
      "lifecycle accepted",
      "# lifecycle accepted"
    ])
  end

  test "stale tombstone returns conflict without writes", %{fixture: fixture} do
    scenario = conflict_scenario(fixture, "stale-delete")
    before = mutation_state(fixture, scenario.created.resource_id)

    stale =
      tombstone_intent(
        fixture,
        scenario.created.resource_id,
        scenario.created.canonical_version_id
      )

    assert {:error, %Error{code: :conflict}} =
             scoped(fixture, &NoteRepository.tombstone(&1, stale))

    assert mutation_state(fixture, scenario.created.resource_id) == before
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

  defp merge_intent(
         fixture,
         resource_id,
         conflict_id,
         expected_current_version_id,
         competing_version_id,
         title,
         markdown
       ) do
    {:ok, snapshot} =
      NoteSnapshot.merge(%{
        classification: :private,
        title: title,
        markdown: markdown,
        parent_version_id: expected_current_version_id,
        merge_parent_version_id: competing_version_id
      })

    %{
      mutation_id: Ecto.UUID.generate(),
      principal_id: fixture.principal_id,
      vault_id: fixture.vault_id,
      classification: :private,
      correlation_id: Ecto.UUID.generate(),
      resource_id: resource_id,
      conflict_id: conflict_id,
      expected_current_version_id: expected_current_version_id,
      competing_version_id: competing_version_id,
      snapshot: snapshot,
      request_fingerprint:
        :crypto.hash(:sha256, [
          resource_id,
          conflict_id,
          expected_current_version_id,
          competing_version_id,
          title,
          markdown
        ])
    }
  end

  defp tombstone_intent(fixture, resource_id, expected_current_version_id) do
    %{
      mutation_id: Ecto.UUID.generate(),
      principal_id: fixture.principal_id,
      vault_id: fixture.vault_id,
      classification: :private,
      correlation_id: Ecto.UUID.generate(),
      resource_id: resource_id,
      expected_current_version_id: expected_current_version_id,
      request_fingerprint:
        :crypto.hash(:sha256, [resource_id, expected_current_version_id, "tombstone"])
    }
  end

  defp restore_intent(fixture, resource_id) do
    %{
      mutation_id: Ecto.UUID.generate(),
      principal_id: fixture.principal_id,
      vault_id: fixture.vault_id,
      classification: :private,
      correlation_id: Ecto.UUID.generate(),
      resource_id: resource_id,
      request_fingerprint: :crypto.hash(:sha256, [resource_id, "restore"])
    }
  end

  defp conflict_scenario(fixture, prefix) do
    create = create_intent(fixture, "#{prefix} original", "# #{prefix} original")

    assert {:ok, %NoteSaveResult{} = created} =
             scoped(fixture, &NoteRepository.create(&1, create))

    accepted_intent =
      save_intent(
        fixture,
        created.resource_id,
        created.canonical_version_id,
        "#{prefix} accepted",
        "# #{prefix} accepted"
      )

    assert {:ok, %NoteSaveResult{} = accepted} =
             scoped(fixture, &NoteRepository.save(&1, accepted_intent))

    stale_intent =
      save_intent(
        fixture,
        created.resource_id,
        created.canonical_version_id,
        "#{prefix} competing",
        "# #{prefix} competing"
      )

    assert {:ok, %NoteSaveResult{outcome: :conflict} = conflict} =
             scoped(fixture, &NoteRepository.save(&1, stale_intent))

    %{
      create: create,
      created: created,
      accepted_intent: accepted_intent,
      accepted: accepted,
      stale_intent: stale_intent,
      conflict: conflict
    }
  end

  defp mutation_state(fixture, resource_id) do
    %{
      canonical: canonical_state(fixture, resource_id),
      counts: note_effect_counts(fixture, resource_id),
      conflicts:
        scoped(fixture, fn repo ->
          %{rows: rows} =
            query!(
              repo,
              """
              SELECT id, base_version_id, canonical_version_id, competing_version_id,
                     state, resolution_version_id, resolved_at
              FROM content.note_conflicts
              WHERE resource_id = $1
              ORDER BY id
              """,
              [Ecto.UUID.dump!(resource_id)]
            )

          rows
        end)
    }
  end

  defp version_count(fixture, resource_id) do
    scoped(fixture, fn repo ->
      %{rows: [[count]]} =
        query!(
          repo,
          "SELECT count(*) FROM content.resource_versions WHERE resource_id = $1",
          [Ecto.UUID.dump!(resource_id)]
        )

      count
    end)
  end

  defp refute_lifecycle_plaintext(fixture, intents, canaries) do
    scoped(fixture, fn repo ->
      correlations = Enum.map(intents, &Ecto.UUID.dump!(&1.correlation_id))
      mutations = Enum.map(intents, &Ecto.UUID.dump!(&1.mutation_id))

      %{rows: audit_rows} =
        query!(
          repo,
          "SELECT to_jsonb(event) FROM audit.events AS event WHERE correlation_id = ANY($1)",
          [
            correlations
          ]
        )

      %{rows: outbox_rows} =
        query!(
          repo,
          "SELECT to_jsonb(event) FROM core.outbox_events AS event WHERE correlation_id = ANY($1)",
          [correlations]
        )

      %{rows: receipt_rows} =
        query!(
          repo,
          "SELECT to_jsonb(receipt) FROM content.note_mutation_receipts AS receipt WHERE mutation_id = ANY($1)",
          [mutations]
        )

      encoded = JSON.encode!([audit_rows, outbox_rows, receipt_rows])
      Enum.each(canaries, &refute(String.contains?(encoded, &1)))
      :ok
    end)
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

    assert %{rows: outbox_rows} =
             query!(
               repo,
               "SELECT to_jsonb(event) FROM core.outbox_events AS event WHERE correlation_id = $1",
               [Ecto.UUID.dump!(intent.correlation_id)]
             )

    assert outbox_rows != []
    outbox_json = Enum.map(outbox_rows, fn [row] -> row end)

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
  defp load_optional_uuid(nil), do: nil
  defp load_optional_uuid(uuid), do: load_uuid(uuid)
end
