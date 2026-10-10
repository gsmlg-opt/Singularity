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

  test "source sets default independently to empty on create and inherit on normal and merge" do
    for {constructor, attrs, default} <- source_snapshot_shapes() do
      assert {:ok, snapshot} = apply(NoteSnapshot, constructor, [attrs])
      assert Map.fetch!(snapshot, :attachments) == default
      assert Map.fetch!(snapshot, :citations) == default

      assert {:ok, cleared} =
               apply(NoteSnapshot, constructor, [
                 Map.merge(attrs, %{attachments: [], citations: []})
               ])

      assert Map.fetch!(cleared, :attachments) == []
      assert Map.fetch!(cleared, :citations) == []

      for field <- [:attachments, :citations] do
        assert {:ok, cleared} = apply(NoteSnapshot, constructor, [Map.put(attrs, field, [])])
        assert Map.fetch!(cleared, field) == []
        other = if field == :attachments, do: :citations, else: :attachments
        assert Map.fetch!(cleared, other) == default

        for invalid <- [:inherit, "inherit", nil, %{}, :replace, [nil]] do
          assert {:error, %{code: :invalid}} =
                   apply(NoteSnapshot, constructor, [Map.put(attrs, field, invalid)])
        end
      end
    end
  end

  test "source set lists validate references and preserve their explicit order" do
    attachments = [source_attachment(2), source_attachment(1)]
    citations = [source_citation(2), source_citation(1)]

    for {constructor, attrs, _default} <- source_snapshot_shapes() do
      assert {:ok, snapshot} =
               apply(NoteSnapshot, constructor, [
                 Map.merge(attrs, %{attachments: attachments, citations: citations})
               ])

      assert [%{attachment_id: first}, %{attachment_id: second}] =
               Map.fetch!(snapshot, :attachments)

      assert {first, second} == {source_uuid(2), source_uuid(1)}
      assert [%{citation_id: ^first}, %{citation_id: ^second}] = Map.fetch!(snapshot, :citations)

      assert {:ok, ^snapshot} =
               apply(NoteSnapshot, constructor, [
                 Map.merge(attrs, Map.take(snapshot, [:attachments, :citations]))
               ])

      assert {:error, %{code: :invalid}} =
               apply(NoteSnapshot, constructor, [
                 Map.put(attrs, :attachments, [
                   Map.put(source_attachment(1), :owner_id, @vault_id)
                 ])
               ])

      assert {:error, %{code: :invalid}} =
               apply(NoteSnapshot, constructor, [
                 Map.put(attrs, :citations, [Map.put(source_citation(1), :text, "private-canary")])
               ])
    end
  end

  test "source sets reject duplicate stable IDs and attachment target-version-role triples" do
    attachment = source_attachment(1)
    citation = source_citation(1)

    invalid_sets = [
      %{
        attachments: [
          attachment,
          Map.put(source_attachment(2), :attachment_id, attachment.attachment_id)
        ]
      },
      %{
        attachments: [
          attachment,
          %{attachment | attachment_id: source_uuid(2), target_kind: :document}
        ]
      },
      %{citations: [citation, Map.put(source_citation(2), :citation_id, citation.citation_id)]}
    ]

    for {constructor, attrs, _default} <- source_snapshot_shapes(), sets <- invalid_sets do
      assert {:error, %{code: :invalid}} =
               apply(NoteSnapshot, constructor, [Map.merge(attrs, sets)])
    end

    # Separate citations may identify the same immutable fragment under different stable IDs.
    assert {:ok, snapshot} =
             NoteSnapshot.initial(
               note_attrs(citations: [citation, %{citation | citation_id: source_uuid(2)}])
             )

    assert [%{citation_id: first}, %{citation_id: second}] = Map.fetch!(snapshot, :citations)
    assert {first, second} == {source_uuid(1), source_uuid(2)}

    # Distinct versions of the same resource remain distinct attachment references.
    assert {:ok, _snapshot} =
             NoteSnapshot.initial(
               note_attrs(
                 attachments: [
                   attachment,
                   %{
                     attachment
                     | attachment_id: source_uuid(2),
                       target_resource_version_id: source_uuid(900)
                   }
                 ]
               )
             )
  end

  test "source sets enforce list and union-target bounds at 100 without counting duplicates twice" do
    attachments = Enum.map(1..100, &source_attachment/1)
    citations = Enum.map(1..100, &source_citation/1)

    for {constructor, attrs, _default} <- source_snapshot_shapes() do
      assert {:ok, _snapshot} =
               apply(NoteSnapshot, constructor, [
                 Map.merge(attrs, %{attachments: attachments, citations: citations})
               ])

      assert {:error, %{code: :invalid}} =
               apply(NoteSnapshot, constructor, [
                 Map.put(attrs, :attachments, attachments ++ [source_attachment(101)])
               ])

      assert {:error, %{code: :invalid}} =
               apply(NoteSnapshot, constructor, [
                 Map.put(attrs, :citations, citations ++ [source_citation(101)])
               ])

      # Each list is below its bound, but these targets have a union of 101.
      assert {:error, %{code: :invalid}} =
               apply(NoteSnapshot, constructor, [
                 Map.merge(attrs, %{attachments: attachments, citations: [source_citation(101)]})
               ])

      shared_resource_versions =
        Enum.map(1..100, fn i ->
          %{source_attachment(i) | target_resource_id: source_uuid(501)}
        end)

      # The union key includes the immutable version, not just the resource UUID.
      assert {:error, %{code: :invalid}} =
               apply(NoteSnapshot, constructor, [
                 Map.merge(attrs, %{
                   attachments: shared_resource_versions,
                   citations: [%{source_citation(101) | source_resource_id: source_uuid(501)}]
                 })
               ])

      same_fragment = Enum.map(citations, &Map.put(&1, :fragment_id, String.duplicate("a", 64)))

      assert {:ok, _snapshot} =
               apply(NoteSnapshot, constructor, [Map.put(attrs, :citations, same_fragment)])
    end
  end

  test "source lists reject noncanonical nested structs rather than silently repairing them" do
    assert {:ok, snapshot} =
             NoteSnapshot.initial(
               note_attrs(attachments: [source_attachment(1)], citations: [source_citation(1)])
             )

    [attachment] = Map.fetch!(snapshot, :attachments)
    [citation] = Map.fetch!(snapshot, :citations)

    for {field, reference} <- [
          {:attachments, Map.put(attachment, :label, "e\u0301")},
          {:attachments, Map.put(attachment, :ordinal, 0)},
          {:attachments, citation},
          {:citations, Map.put(citation, :fragment_id, "BAD")},
          {:citations, Map.put(citation, :witness, "private-canary")},
          {:citations, attachment}
        ] do
      assert {:error, %{code: :invalid}} =
               NoteSnapshot.initial(note_attrs([{field, [reference]}]))
    end
  end

  defp source_snapshot_shapes do
    [
      {:initial, note_attrs(), []},
      {:normal, note_attrs(parent_version_id: @base_version_id), :inherit},
      {:merge,
       note_attrs(
         parent_version_id: @canonical_version_id,
         merge_parent_version_id: @competing_version_id
       ), :inherit}
    ]
  end

  defp source_attachment(i) do
    %{
      attachment_id: source_uuid(i),
      target_resource_id: source_uuid(500 + i),
      target_resource_version_id: source_uuid(1_000 + i),
      target_kind: :asset
    }
  end

  defp source_citation(i) do
    %{
      citation_id: source_uuid(i),
      source_resource_id: source_uuid(500 + i),
      source_resource_version_id: source_uuid(1_000 + i),
      fragment_id: Integer.to_string(i, 16) |> String.downcase() |> String.pad_leading(64, "0"),
      locator: %{version: 1, kind: "fragment", ordinal: 0}
    }
  end

  defp source_uuid(i),
    do:
      "00000000-0000-4000-8000-" <>
        String.pad_leading(String.downcase(Integer.to_string(i, 16)), 12, "0")

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
