defmodule Singularity.Core.NoteValuesTest.OffsetTimeZoneDatabase do
  @moduledoc false

  @behaviour Calendar.TimeZoneDatabase

  @period %{utc_offset: 28_800, std_offset: 0, zone_abbr: "GMT+8"}

  @impl true
  def time_zone_periods_from_wall_datetime(_naive_datetime, "Etc/GMT-8"), do: {:ok, @period}

  def time_zone_periods_from_wall_datetime(_naive_datetime, _time_zone),
    do: {:error, :time_zone_not_found}

  @impl true
  def time_zone_period_from_utc_iso_days(_iso_days, "Etc/GMT-8"), do: {:ok, @period}

  def time_zone_period_from_utc_iso_days(_iso_days, _time_zone),
    do: {:error, :time_zone_not_found}
end

defmodule Singularity.Core.NoteValuesTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.NoteConflict
  alias Singularity.Core.NoteSaveResult
  alias Singularity.Core.NoteSnapshot
  alias Singularity.Core.Types
  alias Singularity.Core.NoteValuesTest.OffsetTimeZoneDatabase

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

  test "snapshots accept exact title and Markdown byte boundaries" do
    title = String.duplicate("界", 85)
    markdown = :binary.copy("x", 1_048_576)

    assert byte_size(title) == 255
    assert byte_size(markdown) == 1_048_576

    assert {:ok, %NoteSnapshot{title: ^title, markdown: ^markdown}} =
             NoteSnapshot.initial(note_attrs(title: title, markdown: markdown))
  end

  test "snapshots reject a valid UTF-8 title at exactly 256 bytes" do
    title = String.duplicate("界", 85) <> "a"

    assert byte_size(title) == 256
    assert {:error, %{code: :invalid}} = NoteSnapshot.initial(note_attrs(title: title))
  end

  test "snapshots accept empty Markdown" do
    assert {:ok, %NoteSnapshot{markdown: ""}} =
             NoteSnapshot.initial(note_attrs(markdown: ""))
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

  test "open conflicts require pairwise distinct lineage references" do
    for duplicate_lineage <- [
          %{canonical_version_id: @base_version_id},
          %{competing_version_id: @base_version_id},
          %{competing_version_id: @canonical_version_id},
          %{
            canonical_version_id: @base_version_id,
            competing_version_id: @base_version_id
          }
        ] do
      assert {:error, %{code: :invalid}} =
               NoteConflict.open(open_conflict_attrs(duplicate_lineage))
    end
  end

  test "resolved conflicts require a resolution distinct from every lineage reference" do
    for resolution_version_id <- [
          @base_version_id,
          @canonical_version_id,
          @competing_version_id
        ] do
      assert {:error, %{code: :invalid}} =
               NoteConflict.resolved(
                 open_conflict_attrs(
                   resolution_version_id: resolution_version_id,
                   resolved_at: @resolved_at
                 )
               )
    end
  end

  test "canonical UUID validation requires lowercase canonical values" do
    assert {:ok, @base_version_id} = Types.canonical_uuid(%{id: @base_version_id}, :id)
    assert {:error, %{code: :invalid}} = Types.canonical_uuid(%{id: @uppercase_version_id}, :id)

    assert {:error, %{code: :invalid}} =
             Types.canonical_uuid(%{id: "33333333-3333-3333-3333-33333333333"}, :id)

    assert {:error, %{code: :invalid}} = Types.canonical_uuid(%{}, :id)
    assert {:error, %{code: :invalid}} = Types.canonical_uuid(%{id: 333}, :id)
  end

  test "conflict and save result constructors reject invalid UUIDs" do
    assert {:error, %{code: :invalid}} =
             NoteConflict.open(open_conflict_attrs(conflict_id: @uppercase_version_id))

    assert {:error, %{code: :invalid}} =
             NoteSaveResult.saved(
               save_result_attrs(resource_id: "11111111-1111-1111-1111-11111111111")
             )
  end

  test "conflict constructors reject valid offset DateTimes" do
    offset_datetime =
      DateTime.from_naive!(
        ~N[2026-08-18 17:00:00],
        "Etc/GMT-8",
        OffsetTimeZoneDatabase
      )

    assert %DateTime{time_zone: "Etc/GMT-8", utc_offset: 28_800} = offset_datetime

    assert {:error, %{code: :invalid}} =
             NoteConflict.open(open_conflict_attrs(created_at: offset_datetime))

    assert {:error, %{code: :invalid}} =
             NoteConflict.resolved(
               open_conflict_attrs(
                 resolution_version_id: @resolution_version_id,
                 resolved_at: offset_datetime
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
