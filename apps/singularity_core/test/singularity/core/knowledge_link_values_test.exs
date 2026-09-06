defmodule Singularity.Core.KnowledgeLinkValuesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Singularity.Core.{
    DocumentFragment,
    Error,
    NoteAttachment,
    NoteCitation,
    NoteSourceSet,
    Relationship,
    ResourceTag,
    Tag
  }

  defp id(n), do: "00000000-0000-0000-0000-" <> String.pad_leading(Integer.to_string(n), 12, "0")
  defp owner, do: %{owner_scope_id: id(1), classification: :private}
  defp note, do: Map.merge(owner(), %{note_resource_id: id(2), note_resource_version_id: id(3)})

  defp attachment,
    do:
      Map.merge(note(), %{
        attachment_id: id(4),
        target_kind: :document,
        target_resource_id: id(5),
        target_resource_version_id: id(6),
        ordinal: 0,
        role: :source
      })

  defp target,
    do:
      Map.merge(owner(), %{
        resource_id: id(5),
        resource_version_id: id(6),
        kind: :document,
        state: :ready
      })

  defp fragment do
    {:ok, fragment} =
      DocumentFragment.new(
        Map.merge(owner(), %{
          resource_id: id(5),
          resource_version_id: id(6),
          ordinal: 0,
          text: "source",
          locator: %{version: 1, kind: "text", start_line: 1, end_line: 1}
        })
      )

    fragment
  end

  defp citation do
    f = fragment()

    Map.merge(note(), %{
      citation_id: id(7),
      source_resource_id: f.resource_id,
      source_resource_version_id: f.resource_version_id,
      fragment_id: f.fragment_id,
      locator: f.locator,
      ordinal: 0
    })
  end

  defp source_set,
    do:
      Map.merge(note(), %{
        attachments: [attachment()],
        citations: [citation()],
        targets: [target()],
        fragments: [fragment()]
      })

  defp tag, do: Map.merge(owner(), %{tag_id: id(8), display_value: " Straße "})

  defp relationship,
    do:
      Map.merge(owner(), %{
        relationship_id: id(9),
        source_resource_id: id(2),
        target_resource_id: id(5),
        type: :references
      })

  test "attachments and citations pin immutable versions and reject malformed identity" do
    assert {:ok, a} = NoteAttachment.new(Map.put(attachment(), :label, "e\u0301"))
    assert a.label == "é"
    assert {:ok, _} = NoteCitation.new(citation())

    for {module, attrs, key} <- [
          {NoteAttachment, attachment(), :attachment_id},
          {NoteCitation, citation(), :citation_id}
        ] do
      assert {:error, %Error{code: :invalid}} = module.new(Map.put(attrs, key, "bad"))
      assert {:error, %Error{code: :invalid}} = module.new(Map.put(attrs, :ordinal, -1))

      assert {:error, %Error{code: :invalid}} =
               module.new(Map.put(attrs, :ordinal, 9_223_372_036_854_775_808))

      assert {:error, %Error{code: :invalid}} = module.new(Map.put(attrs, :vault_id, id(1)))

      assert {:error, %Error{code: :invalid}} =
               module.new(Map.put(attrs, "classification", :public))

      {:ok, value} = module.new(attrs)
      assert {:error, %Error{code: :invalid}} = module.new(Map.put(value, key, nil))
    end

    assert {:error, _} = NoteAttachment.new(Map.put(attachment(), :target_resource_id, id(2)))
    assert {:error, _} = NoteCitation.new(Map.put(citation(), :source_resource_id, id(2)))
    assert {:error, _} = NoteAttachment.new(Map.put(attachment(), :label, <<255>>))

    assert {:error, _} =
             NoteCitation.new(Map.put(citation(), :fragment_id, String.duplicate("A", 64)))
  end

  test "source set validates supplied targets and immutable fragment evidence atomically" do
    assert {:ok, _} = NoteSourceSet.new(source_set())

    assert {:ok, _} =
             NoteSourceSet.new(
               Map.merge(note(), %{attachments: [], citations: [], targets: [], fragments: []})
             )

    for mutation <- [
          %{targets: []},
          %{fragments: []},
          %{targets: [Map.put(target(), :state, :processing)]},
          %{targets: [Map.put(target(), :owner_scope_id, id(20))]},
          %{targets: [Map.put(target(), :kind, :asset)]},
          %{attachments: [attachment(), Map.put(attachment(), :ordinal, 1)]},
          %{
            attachments: [
              attachment(),
              Map.merge(attachment(), %{attachment_id: id(21), ordinal: 1})
            ]
          },
          %{citations: [citation(), Map.put(citation(), :ordinal, 1)]},
          %{attachments: [Map.put(attachment(), :ordinal, 1)]},
          %{citations: [Map.put(citation(), :note_resource_version_id, id(20))]},
          %{
            citations: [
              Map.put(citation(), :locator, %{version: 1, kind: "fragment", ordinal: 0})
            ]
          },
          %{fragments: [Map.put(fragment(), :text, "forged")]}
        ] do
      assert {:error, %Error{code: :invalid}} =
               NoteSourceSet.new(Map.merge(source_set(), mutation))
    end
  end

  test "tags normalize Unicode casefold while retaining trimmed display spelling" do
    assert {:ok, first} = Tag.new(tag())
    assert first.display_value == "Straße"
    assert first.normalized_key == "strasse"
    assert {:ok, second} = Tag.new(Map.put(tag(), :display_value, "STRASSE"))
    assert first.normalized_key == second.normalized_key
    assert {:ok, accent} = Tag.new(Map.put(tag(), :display_value, " E\u0301 "))
    assert accent.display_value == "É"
    assert accent.normalized_key == "é"

    for value <- ["", " ", "a\n", "a\u0085b", <<255>>, "a\0b", String.duplicate("é", 128)] do
      assert {:error, %Error{code: :invalid}} = Tag.new(Map.put(tag(), :display_value, value))
    end

    assert {:error, _} = Tag.new(Map.put(first, :normalized_key, "forged"))
    assert {:ok, _} = Tag.new(Map.put(tag(), :display_value, String.duplicate("a", 255)))
  end

  test "asset and note target evidence has no document lifecycle and citations require documents" do
    for kind <- [:asset, :note] do
      target = target() |> Map.put(:kind, kind) |> Map.delete(:state)

      attrs =
        Map.merge(source_set(), %{
          attachments: [Map.put(attachment(), :target_kind, kind)],
          citations: [],
          targets: [target],
          fragments: []
        })

      assert {:ok, _} = NoteSourceSet.new(attrs)
      assert {:error, _} = NoteSourceSet.new(Map.put(attrs, :citations, [citation()]))

      assert {:error, _} =
               NoteSourceSet.new(Map.put(attrs, :targets, [Map.put(target, :state, :ready)]))
    end
  end

  test "source evidence and collection identity cannot be forged or partially accepted" do
    for mutation <- [
          %{attachments: [Map.put(attachment(), :owner_scope_id, id(20))]},
          %{citations: [Map.put(citation(), :ordinal, 1)]},
          %{targets: [Map.put(target(), :resource_version_id, id(20))]},
          %{targets: [Map.put(target(), :classification, :public)]},
          %{targets: [Map.put(target(), :unexpected, true)]},
          %{fragments: [Map.put(fragment(), :owner_scope_id, id(20))]},
          %{fragments: [Map.put(fragment(), :resource_id, id(20))]},
          %{attachments: :invalid},
          %{citations: [citation(), %URI{}]}
        ] do
      assert {:error, %Error{code: :invalid}} =
               NoteSourceSet.new(Map.merge(source_set(), mutation))
    end
  end

  test "source evidence cannot contradict a version identity or contain improper lists" do
    contradictory = target() |> Map.put(:kind, :asset) |> Map.delete(:state)

    assert {:error, %Error{code: :invalid}} =
             NoteSourceSet.new(Map.put(source_set(), :targets, [target(), contradictory]))
  end

  test "source evidence rejects improper lists without raising" do
    for key <- [:attachments, :citations, :targets, :fragments] do
      [first] = source_set()[key]

      assert {:error, %Error{code: :invalid}} =
               NoteSourceSet.new(Map.put(source_set(), key, [first | :invalid]))
    end
  end

  property "constructors reject arbitrary unknown fields on maps and handcrafted structs" do
    check all(value <- term()) do
      for {module, attrs} <- [
            {NoteAttachment, attachment()},
            {NoteCitation, citation()},
            {NoteSourceSet, source_set()},
            {Tag, tag()},
            {ResourceTag, Map.merge(owner(), %{resource_id: id(2), tag_id: id(8)})},
            {Relationship, relationship()}
          ] do
        {:ok, valid} = module.new(attrs)
        assert {:ok, ^valid} = module.new(valid)
        assert {:error, %Error{code: :invalid}} = module.new(Map.put(attrs, :unexpected, value))
        assert {:error, %Error{code: :invalid}} = module.new(Map.put(valid, :unexpected, value))
      end
    end
  end

  property "tag casefold keys are idempotent for Unicode spellings" do
    check all(text <- string(:alphanumeric, min_length: 1, max_length: 30)) do
      assert {:ok, value} = Tag.new(Map.put(tag(), :display_value, text))
      assert {:ok, normalized} = Tag.new(Map.put(tag(), :display_value, value.normalized_key))
      assert value.normalized_key == normalized.normalized_key
    end
  end

  test "resource tags and directed relationships validate private canonical identities" do
    attrs = Map.merge(owner(), %{resource_id: id(2), tag_id: id(8)})
    assert {:ok, _} = ResourceTag.new(attrs)
    assert {:ok, _} = Relationship.new(relationship())

    assert {:ok, _} =
             Relationship.new(Map.put(relationship(), :target_resource_version_id, id(6)))

    assert {:error, _} = Relationship.new(Map.put(relationship(), :target_resource_id, id(2)))
    assert {:error, _} = Relationship.new(Map.put(relationship(), :type, :unknown))

    assert {:error, _} =
             Relationship.new(Map.put(relationship(), :target_resource_version_id, "bad"))

    for {module, attrs} <- [
          {ResourceTag, attrs},
          {Relationship, relationship()},
          {Tag, tag()},
          {NoteSourceSet, source_set()}
        ] do
      assert {:error, _} = module.new(Map.put(attrs, :classification, :public))
      assert {:error, _} = module.new(Map.put(attrs, :unknown, nil))
      assert {:error, _} = module.new(%URI{})
      assert {:error, _} = module.new(nil)
    end
  end
end
