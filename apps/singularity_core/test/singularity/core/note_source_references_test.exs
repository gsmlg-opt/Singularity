defmodule Singularity.Core.NoteSourceReferencesTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.{Error, SourceLocator}

  @attachment Singularity.Core.NoteAttachmentReference
  @citation Singularity.Core.NoteCitationReference
  @id "00000000-0000-4000-8000-000000000a01"
  @resource "00000000-0000-4000-8000-000000000a02"
  @version "00000000-0000-4000-8000-000000000a03"
  @other "00000000-0000-4000-8000-000000000a04"
  @fragment String.duplicate("a1", 32)

  test "attachments contain only stable owner-free references and a default source role" do
    for kind <- [:asset, :note, :document] do
      assert {:ok, reference} = new(@attachment, attachment(target_kind: kind))

      assert Map.from_struct(reference) == %{
               attachment_id: @id,
               target_resource_id: @resource,
               target_resource_version_id: @version,
               target_kind: kind,
               role: :source,
               label: nil
             }

      assert reference.__struct__ == @attachment
      assert {:ok, ^reference} = new(@attachment, reference)
    end
  end

  test "citations contain a stable ID, immutable fragment source, and canonical v1 locator" do
    assert {:ok, locator} = SourceLocator.new(locator())
    assert {:ok, reference} = new(@citation, citation())
    assert reference.__struct__ == @citation

    assert Map.from_struct(reference) == %{
             citation_id: @id,
             source_resource_id: @resource,
             source_resource_version_id: @version,
             fragment_id: @fragment,
             locator: locator
           }

    assert {:ok, ^reference} = new(@citation, reference)
  end

  test "fixed string enums and string keys normalize without accepting conflicting aliases" do
    assert {:ok, expected} = new(@attachment, attachment(label: "é", role: :source))
    raw = attachment(target_kind: "asset", role: "source", label: "e\u0301")
    assert {:ok, ^expected} = new(@attachment, string_keys(raw))
    assert {:ok, ^expected} = new(@attachment, duplicate_keys(raw))
    assert_invalid(new(@attachment, Map.put(raw, "target_kind", :asset)))
    assert_invalid(new(@attachment, Map.put(raw, "attachment_id", @other)))
    assert_invalid(new(@attachment, Map.put(raw, "label", "é")))

    raw = citation(locator: string_keys(locator()))
    assert {:ok, expected} = new(@citation, raw)
    assert {:ok, ^expected} = new(@citation, string_keys(raw))
    assert {:ok, ^expected} = new(@citation, duplicate_keys(raw))
    assert_invalid(new(@citation, Map.put(raw, "citation_id", @other)))
    assert_invalid(new(@citation, Map.put(raw, "locator", locator())))
  end

  test "references require every canonical UUID and reject unknown kinds and roles" do
    for {module, raw, fields} <- [
          {@attachment, attachment(),
           [:attachment_id, :target_resource_id, :target_resource_version_id]},
          {@citation, citation(),
           [:citation_id, :source_resource_id, :source_resource_version_id]}
        ],
        field <- fields do
      assert_invalid(new(module, Map.delete(raw, field)))

      for value <- [
            String.upcase(@id),
            "not-a-uuid",
            nil,
            7,
            "00000000-0000-4000-8000-000000000a0"
          ] do
        assert_invalid(new(module, Map.put(raw, field, value)))
      end
    end

    assert_invalid(new(@attachment, Map.delete(attachment(), :target_kind)))

    for kind <- [:asset_revision, :pdf, :unknown, "Asset", "unknown", nil, 7] do
      assert_invalid(new(@attachment, attachment(target_kind: kind)))
    end

    for role <- [:citation, :attachment, :unknown, "Source", "unknown", nil, 7] do
      assert_invalid(new(@attachment, attachment(role: role)))
    end
  end

  test "labels preserve whitespace, normalize NFC, and enforce byte limits before and after NFC" do
    for label <- [nil, "", "  é  ", String.duplicate("界", 85), String.duplicate("a", 255)] do
      assert {:ok, %{label: ^label}} = new(@attachment, attachment(label: label))
    end

    assert {:ok, %{label: "é"}} = new(@attachment, attachment(label: "e\u0301"))

    # NFC shrinks this input below 255, but the raw bytes still exceed the limit.
    assert_invalid(new(@attachment, attachment(label: String.duplicate("e\u0301", 86))))
    # U+0344 expands to U+0308 U+0301 under NFC: raw 254 bytes, normalized 508 bytes.
    assert_invalid(new(@attachment, attachment(label: String.duplicate("\u0344", 127))))

    for label <- [String.duplicate("a", 256), <<255>>, "private-canary\0", :label, 7] do
      assert_invalid(new(@attachment, attachment(label: label)))
    end
  end

  test "citation fragment hashes and locators are strict and content-free on rejection" do
    for fragment <- [
          String.upcase(@fragment),
          String.duplicate("a", 63),
          String.duplicate("a", 65),
          String.duplicate("g", 64),
          nil,
          7
        ] do
      assert_invalid(new(@citation, citation(fragment_id: fragment)))
    end

    for key <- [:fragment_id, :locator] do
      assert_invalid(new(@citation, Map.delete(citation(), key)))
    end

    for bad_locator <- [
          nil,
          %{},
          %{version: 2, kind: "fragment", ordinal: 0},
          %{version: 1, kind: "text", start_line: 2, end_line: 1},
          %{version: 1, kind: "fragment", ordinal: -1},
          Map.put(locator(), :text, "private-canary")
        ] do
      assert_invalid(new(@citation, citation(locator: bad_locator)))
    end

    assert {:ok, %{locator: %{fields: %{heading_path: ["é"]}}}} =
             new(
               @citation,
               citation(locator: %{version: 1, kind: "markdown", heading_path: ["e\u0301"]})
             )
  end

  test "owner, container, evidence, and content fields are never part of reference input" do
    fields = [
      :owner_id,
      :principal_id,
      :vault_id,
      :classification,
      :note_id,
      :note_version_id,
      :resource_id,
      :resource_version_id,
      :ordinal,
      :live,
      :retained,
      :text,
      :witness,
      :source_proof,
      :created_at
    ]

    for {module, raw} <- [{@attachment, attachment()}, {@citation, citation()}],
        field <- fields do
      assert_invalid(new(module, Map.put(raw, field, "private-canary")))
      assert_invalid(new(module, Map.put(raw, Atom.to_string(field), "private-canary")))
    end
  end

  test "unknown input strings never create atoms" do
    key = "private-canary-note-reference-key-that-is-not-an-atom-7820"
    kind = "private-canary-note-reference-kind-that-is-not-an-atom-7820"
    role = "private-canary-note-reference-role-that-is-not-an-atom-7820"

    for value <- [key, kind, role] do
      assert_raise ArgumentError, fn -> String.to_existing_atom(value) end
    end

    assert_invalid(new(@attachment, Map.put(attachment(), key, true)))
    assert_invalid(new(@citation, Map.put(citation(), key, true)))
    assert_invalid(new(@attachment, attachment(target_kind: kind)))
    assert_invalid(new(@attachment, attachment(role: role)))

    for value <- [key, kind, role] do
      assert_raise ArgumentError, fn -> String.to_existing_atom(value) end
    end
  end

  test "constructors revalidate exact own structs and reject foreign or noncanonical nested structs" do
    assert {:ok, attachment} = new(@attachment, attachment(label: "é"))
    assert {:ok, citation} = new(@citation, citation())

    assert {:ok, markdown_locator} =
             SourceLocator.new(%{version: 1, kind: "markdown", heading_path: ["é"]})

    for forged <- [
          Map.put(attachment, :witness, "private-canary"),
          Map.delete(attachment, :role),
          Map.put(attachment, :target_kind, "asset"),
          Map.put(attachment, :role, "source"),
          Map.put(attachment, :label, "e\u0301"),
          Map.put(attachment, :attachment_id, "invalid"),
          citation,
          %Error{code: :invalid}
        ] do
      assert_invalid(new(@attachment, forged))
    end

    for forged <- [
          Map.put(citation, :ordinal, 0),
          Map.delete(citation, :fragment_id),
          Map.put(citation, :fragment_id, String.upcase(@fragment)),
          Map.put(citation, :locator, Map.put(citation.locator, :text, "private-canary")),
          Map.put(citation, :locator, %{markdown_locator | fields: %{heading_path: ["e\u0301"]}}),
          Map.put(citation, :locator, %{markdown_locator | fields: %{"heading_path" => ["é"]}}),
          attachment,
          %Error{code: :invalid}
        ] do
      assert_invalid(new(@citation, forged))
    end

    for module <- [@attachment, @citation],
        input <- [nil, :bad, [], [attachment_id: @id, attachment_id: @other]] do
      assert_invalid(new(module, input))
    end
  end

  defp new(module, attrs) do
    assert Code.ensure_loaded?(module), "missing reference constructor #{inspect(module)}"
    apply(module, :new, [attrs])
  end

  defp assert_invalid(result), do: assert(result == {:error, Error.new(:invalid)})

  defp attachment(overrides \\ []) do
    Map.merge(
      %{
        attachment_id: @id,
        target_resource_id: @resource,
        target_resource_version_id: @version,
        target_kind: :asset
      },
      Map.new(overrides)
    )
  end

  defp citation(overrides \\ []) do
    Map.merge(
      %{
        citation_id: @id,
        source_resource_id: @resource,
        source_resource_version_id: @version,
        fragment_id: @fragment,
        locator: locator()
      },
      Map.new(overrides)
    )
  end

  defp locator, do: %{version: 1, kind: "fragment", ordinal: 0}
  defp string_keys(raw), do: Map.new(raw, fn {key, value} -> {Atom.to_string(key), value} end)

  defp duplicate_keys(raw),
    do:
      Enum.reduce(raw, raw, fn {key, value}, acc -> Map.put(acc, Atom.to_string(key), value) end)
end
