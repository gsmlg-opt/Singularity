defmodule Singularity.Core.KnowledgeExportTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error

  @export Singularity.Core.KnowledgeExport
  @resource "00000000-0000-4000-8000-0000000003e9"
  @version "00000000-0000-4000-8000-0000000007d1"
  @other "00000000-0000-4000-8000-0000000007d2"
  @basename @resource <> "--" <> @version

  test "options default only tombstones and accept explicit booleans" do
    assert {:ok, %{include_tombstones: false}} = call(:options, [%{}])

    for include <- [false, true] do
      assert {:ok, %{include_tombstones: ^include}} =
               call(:options, [%{include_tombstones: include}])
    end
  end

  test "options reject caller authority paths adapters ambiguous keys and forged structs" do
    for input <- [
          nil,
          [],
          [include_tombstones: true, include_tombstones: false],
          %{"include_tombstones" => true},
          %{:include_tombstones => true, "include_tombstones" => false},
          %{include_tombstones: nil},
          %{include_tombstones: "false"},
          %{include_tombstones: 0},
          %{__struct__: Error, include_tombstones: false}
        ] do
      assert_invalid(call(:options, [input]))
    end

    for key <- [:owner_scope_id, :vault_id, :session, :adapter, :destination, :path, :all_history] do
      assert_invalid(call(:options, [Map.put(%{include_tombstones: false}, key, "canary")]))
    end
  end

  test "paths contain only exact canonical version identities and fixed extensions" do
    for {kind, media, expected} <- [
          {:note, nil, "notes/#{@basename}.md"},
          {:asset, nil, "assets/#{@basename}.bin"},
          {:document, "application/pdf", "documents/originals/#{@basename}.pdf"},
          {:document, "text/markdown", "documents/originals/#{@basename}.md"},
          {:document, "text/plain", "documents/originals/#{@basename}.txt"},
          {:extracted, nil, "documents/extracted/#{@basename}.txt"}
        ] do
      assert {:ok, ^expected} = call(:path, [kind, @resource, @version, media])
    end

    assert {:ok, first} = call(:path, [:document, @resource, @version, "application/pdf"])
    assert {:ok, second} = call(:path, [:document, @resource, @other, "application/pdf"])
    refute first == second
  end

  test "unsafe noncanonical and case-fold-colliding identifiers never become paths" do
    for bad <- [
          nil,
          "",
          "../x",
          "/tmp/x",
          "a/b",
          "a\\b",
          "a%2fb",
          "a\0b",
          "CON",
          String.upcase(@resource),
          String.replace(@resource, "-", ""),
          <<255>>
        ],
        {resource, version} <- [{bad, @version}, {@resource, bad}] do
      assert_invalid(call(:path, [:note, resource, version, nil]))
    end

    for {kind, media} <- [
          {:unknown, nil},
          {"note", nil},
          {:note, "text/plain"},
          {:asset, "application/pdf"},
          {:document, nil},
          {:document, "image/png"},
          {:document, "text/plain; charset=utf-8"},
          {:document, "../../x"},
          {:extracted, "application/pdf"}
        ] do
      assert_invalid(call(:path, [kind, @resource, @version, media]))
    end
  end

  test "ordinary relative source destinations derive from validated root-relative files" do
    note = "notes/#{@basename}.md"

    for {target, relative} <- [
          {"notes/#{@resource}--#{@other}.md", "#{@resource}--#{@other}.md"},
          {"assets/#{@basename}.bin", "../assets/#{@basename}.bin"},
          {"documents/originals/#{@basename}.pdf", "../documents/originals/#{@basename}.pdf"},
          {"documents/extracted/#{@basename}.txt", "../documents/extracted/#{@basename}.txt"}
        ] do
      assert {:ok, ^relative} = call(:relative_source_path, [note, target])
    end

    # These are string-shape checks, not filesystem or symlink-containment proof.
    for bad <- [
          "../" <> note,
          "/" <> note,
          "notes/../" <> note,
          "notes//#{@basename}.md",
          "notes/#{@basename}.md\0",
          "notes/#{@basename}.md?x=1",
          "notes/#{@basename}.md#x",
          "notes/title [x](bad).md",
          "https://example.com/x",
          "manifest.json",
          String.replace(note, "/", "\\"),
          String.upcase(note),
          %{symlink: note}
        ] do
      assert_invalid(call(:relative_source_path, [note, bad]))
      assert_invalid(call(:relative_source_path, [bad, note]))
    end
  end

  test "fixed global and stricter item ceilings are explicit pure values" do
    assert call(:limits, []) == %{
             selected_keys: 100_000,
             metadata_records: 1_000_000,
             metadata_bytes: 1_073_741_824,
             file_bytes: 68_719_476_736,
             execution_ms: 900_000,
             page_rows: 500,
             chunk_bytes: 65_536,
             document_bytes: 67_108_864,
             document_fragments: 4_096,
             fragment_bytes: 65_536,
             extracted_bytes: 16_777_216,
             note_bytes: 1_048_576,
             rendered_note_bytes: 16_777_216,
             source_targets: 100
           }
  end

  defp call(function, args) do
    assert Code.ensure_loaded?(@export), "missing pure KnowledgeExport contract"
    assert function_exported?(@export, function, length(args))
    apply(@export, function, args)
  end

  defp assert_invalid(result), do: assert(result == {:error, Error.new(:invalid)})
end
