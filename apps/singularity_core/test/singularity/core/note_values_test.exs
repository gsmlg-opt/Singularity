defmodule Singularity.Core.NoteValuesTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.NoteConflict
  alias Singularity.Core.NoteSaveResult
  alias Singularity.Core.NoteSnapshot

  @resource_id "11111111-1111-1111-1111-111111111111"
  @vault_id "22222222-2222-2222-2222-222222222222"
  @base_version_id "33333333-3333-3333-3333-333333333333"
  @canonical_version_id "44444444-4444-4444-4444-444444444444"
  @competing_version_id "55555555-5555-5555-5555-555555555555"
  @uppercase_version_id "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
  @resolution_version_id "66666666-6666-6666-6666-666666666666"
  @conflict_id "77777777-7777-7777-7777-777777777777"
  @created_at ~U[2026-08-18 08:00:00Z]
  @resolved_at ~U[2026-08-18 09:00:00Z]

  test "normal snapshots trim title and preserve Markdown exactly" do
    markdown = "# Heading\n\n<body onclick='x'>kept as source</body>\n"

    assert {:ok,
            %NoteSnapshot{
              classification: :private,
              title: "Heading",
              markdown: ^markdown,
              parent_version_id: @base_version_id,
              merge_parent_version_id: nil
            }} =
             NoteSnapshot.normal(%{
               classification: :private,
               title: "  Heading  ",
               markdown: markdown,
               parent_version_id: @base_version_id
             })
  end

  test "snapshot constructors enforce exact parent shapes" do
    assert {:ok, %NoteSnapshot{parent_version_id: nil, merge_parent_version_id: nil}} =
             NoteSnapshot.initial(note_attrs())

    assert {:error, %{code: :invalid}} =
             NoteSnapshot.initial(Map.put(note_attrs(), :parent_version_id, @base_version_id))

    assert {:error, %{code: :invalid}} =
             NoteSnapshot.normal(note_attrs())

    assert {:error, %{code: :invalid}} =
             NoteSnapshot.normal(
               note_attrs(parent_version_id: @base_version_id)
               |> Map.put(:merge_parent_version_id, @canonical_version_id)
             )

    assert {:ok,
            %NoteSnapshot{
              parent_version_id: @canonical_version_id,
              merge_parent_version_id: @competing_version_id
            }} =
             NoteSnapshot.merge(
               note_attrs(
                 parent_version_id: @canonical_version_id,
                 merge_parent_version_id: @competing_version_id
               )
             )
  end

  test "merge snapshots require two distinct canonical parents" do
    assert {:error, %{code: :invalid}} =
             NoteSnapshot.merge(note_attrs(parent_version_id: @canonical_version_id))

    assert {:error, %{code: :invalid}} =
             NoteSnapshot.merge(
               note_attrs(
                 parent_version_id: @canonical_version_id,
                 merge_parent_version_id: @canonical_version_id
               )
             )

    assert {:error, %{code: :invalid}} =
             NoteSnapshot.merge(
               note_attrs(
                 parent_version_id: @uppercase_version_id,
                 merge_parent_version_id: @competing_version_id
               )
             )
  end

  test "snapshots reject invalid Markdown" do
    for markdown <- [<<"bad", 0>>, <<"bad", 255>>, :binary.copy("x", 1_048_577)] do
      assert {:error, %{code: :invalid}} = NoteSnapshot.initial(note_attrs(markdown: markdown))
    end
  end

  test "snapshots reject invalid titles and non-private classifications" do
    for title <- ["   ", <<"bad", 255>>, " " <> :binary.copy("x", 256) <> " "] do
      assert {:error, %{code: :invalid}} = NoteSnapshot.initial(note_attrs(title: title))
    end

    assert {:error, %{code: :invalid}} =
             NoteSnapshot.initial(note_attrs(classification: :sensitive))
  end

  test "open conflicts have no resolution and resolved conflicts require one" do
    assert {:ok,
            %NoteConflict{
              conflict_id: @conflict_id,
              resource_id: @resource_id,
              vault_id: @vault_id,
              classification: :private,
              base_version_id: @base_version_id,
              canonical_version_id: @canonical_version_id,
              competing_version_id: @competing_version_id,
              state: :open,
              resolution_version_id: nil,
              created_at: @created_at,
              resolved_at: nil
            }} = NoteConflict.open(open_conflict_attrs())

    assert {:ok,
            %NoteConflict{
              state: :resolved,
              resolution_version_id: @resolution_version_id,
              resolved_at: @resolved_at
            }} =
             NoteConflict.resolved(
               open_conflict_attrs(
                 resolution_version_id: @resolution_version_id,
                 resolved_at: @resolved_at
               )
             )

    assert {:error, %{code: :invalid}} =
             NoteConflict.open(Map.put(open_conflict_attrs(), :resolved_at, @resolved_at))

    assert {:error, %{code: :invalid}} = NoteConflict.resolved(open_conflict_attrs())

    assert {:error, %{code: :invalid}} =
             NoteConflict.resolved(
               open_conflict_attrs(
                 resolution_version_id: @resolution_version_id,
                 resolved_at: ~N[2026-08-18 09:00:00]
               )
             )
  end

  test "save results contain only canonical references" do
    assert {:ok,
            %NoteSaveResult{
              outcome: :saved,
              resource_id: @resource_id,
              canonical_version_id: @canonical_version_id,
              submitted_version_id: @canonical_version_id,
              conflict_id: nil
            }} =
             NoteSaveResult.saved(save_result_attrs(submitted_version_id: @canonical_version_id))

    assert {:ok,
            %NoteSaveResult{
              outcome: :conflict,
              resource_id: @resource_id,
              canonical_version_id: @canonical_version_id,
              submitted_version_id: @competing_version_id,
              conflict_id: @conflict_id
            }} =
             NoteSaveResult.conflict(
               save_result_attrs(
                 submitted_version_id: @competing_version_id,
                 conflict_id: @conflict_id
               )
             )

    assert {:error, %{code: :invalid}} =
             NoteSaveResult.saved(save_result_attrs(submitted_version_id: @competing_version_id))

    assert {:error, %{code: :invalid}} =
             NoteSaveResult.conflict(
               save_result_attrs(
                 submitted_version_id: @canonical_version_id,
                 conflict_id: @conflict_id
               )
             )
  end

  defp note_attrs(overrides \\ []) do
    Map.merge(
      %{classification: :private, title: "Title", markdown: "Markdown"},
      Map.new(overrides)
    )
  end

  defp open_conflict_attrs(overrides \\ []) do
    Map.merge(
      %{
        conflict_id: @conflict_id,
        resource_id: @resource_id,
        vault_id: @vault_id,
        classification: :private,
        base_version_id: @base_version_id,
        canonical_version_id: @canonical_version_id,
        competing_version_id: @competing_version_id,
        created_at: @created_at
      },
      Map.new(overrides)
    )
  end

  defp save_result_attrs(overrides) do
    Map.merge(
      %{
        resource_id: @resource_id,
        canonical_version_id: @canonical_version_id,
        submitted_version_id: @canonical_version_id
      },
      Map.new(overrides)
    )
  end
end
