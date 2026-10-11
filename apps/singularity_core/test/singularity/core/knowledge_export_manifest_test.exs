defmodule Singularity.Core.KnowledgeExportManifestTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error

  @manifest Singularity.Core.KnowledgeExportManifest
  @resource "00000000-0000-4000-8000-0000000003e9"
  @version "00000000-0000-4000-8000-0000000007d1"
  @other "00000000-0000-4000-8000-0000000007d2"
  @member "00000000-0000-4000-8000-00000000000a"
  @digest String.duplicate("a1", 32)
  @time "2026-10-11T01:02:03.123456Z"
  @basename @resource <> "--" <> @version
  @arrays ~w(resources versions fragments tags tag_assignments relationships attachments citations files)a
  @version_keys ~w(resource_id version_id revision kind inserted_at availability body_path original_path extracted_path body_digest original_digest original_byte_size extracted_digest media_type state extraction_adapter extraction_format parent_version_id merge_parent_version_id)

  test "header is the exact versioned twelve-key JSON-ready skeleton without clock or authority" do
    for include <- [false, true] do
      expected = %{
        "format" => "singularity.portable-knowledge",
        "version" => 1,
        "selection" => %{
          "mode" => "live_heads_with_source_closure",
          "include_tombstones" => include
        },
        "resources" => [],
        "versions" => [],
        "fragments" => [],
        "tags" => [],
        "tag_assignments" => [],
        "relationships" => [],
        "attachments" => [],
        "citations" => [],
        "files" => []
      }

      assert {:ok, ^expected} = call(:header, [%{include_tombstones: include}])
    end

    for input <- [
          nil,
          %{include_tombstones: "true"},
          %{include_tombstones: true, owner: @resource}
        ] do
      assert_invalid(call(:header, [input]))
    end
  end

  test "all nine record arrays have exact literal required fields and preserve user values" do
    for kind <- @arrays do
      record = fixture(kind)
      assert {:ok, ^record} = record(kind, record)

      for key <- Map.keys(record) do
        assert_invalid(record(kind, Map.delete(record, key)))
      end
    end

    version = fixture(:versions)
    assert Enum.sort(Map.keys(version)) == Enum.sort(@version_keys)
    assert is_nil(version["body_path"])
    assert is_nil(version["parent_version_id"])
    assert is_nil(version["merge_parent_version_id"])
  end

  test "records reject unrecognized arrays nonmaps structs missing keys and extra private fields" do
    for kind <- @arrays do
      good = fixture(kind)

      for malformed <- [
            nil,
            [],
            %{},
            Map.put(good, :__struct__, Error),
            Map.put(good, "extra", nil),
            Map.put(good, :vault_id, @resource)
          ] do
        assert_invalid(record(kind, malformed))
      end

      for key <-
            ~w(owner_scope_id vault_id login session_id principal_id storage_ref wrapped_key key_domain_id capabilities receipt job_payload metadata) do
        assert_invalid(record(kind, Map.put(good, key, "private-canary")))
      end
    end

    assert_invalid(record(:unknown, fixture(:resources)))
    assert_invalid(record("resources", fixture(:resources)))
  end

  test "UUID SHA and UTC microsecond encodings are canonical rather than silently normalized" do
    for bad <- [nil, String.upcase(@resource), "../x", String.replace(@resource, "-", ""), 1] do
      assert_invalid(record(:resources, Map.put(fixture(:resources), "id", bad)))
    end

    for bad <- [nil, String.upcase(@digest), <<0::256>>, String.duplicate("g", 64), "a1"] do
      assert_invalid(record(:files, Map.put(fixture(:files), "sha256", bad)))
    end

    for bad <- [
          nil,
          "2026-10-11T01:02:03Z",
          "2026-10-11T01:02:03.123Z",
          "2026-10-11T01:02:03.123456+00:00",
          "2026-02-30T01:02:03.123456Z",
          ~U[2026-10-11 01:02:03.123456Z]
        ] do
      assert_invalid(record(:versions, Map.put(fixture(:versions), "inserted_at", bad)))
    end
  end

  test "resource kinds selection reasons and optional tombstone and head fields are closed" do
    for kind <- ["asset", "note", "document"],
        reason <- ["head", "source", "relationship_endpoint", "tombstone"] do
      value = %{fixture(:resources) | "kind" => kind, "selection_reason" => reason}
      assert {:ok, ^value} = record(:resources, value)
    end

    value = %{fixture(:resources) | "current_version_id" => nil, "deleted_at" => @time}
    assert {:ok, ^value} = record(:resources, value)

    for {field, bad} <- [
          {"kind", "vault"},
          {"kind", :note},
          {"selection_reason", "all_history"},
          {"title", <<255>>},
          {"title", "title\0"},
          {"deleted_at", "today"},
          {"current_version_id", "not-a-version"}
        ] do
      assert_invalid(record(:resources, Map.put(fixture(:resources), field, bad)))
    end
  end

  test "included versions distinguish Note bodies Asset bytes and ready Document text" do
    document = fixture(:versions)
    assert {:ok, ^document} = record(:versions, document)

    note =
      empty_version("note", "included")
      |> Map.merge(%{"body_path" => "notes/#{@basename}.md", "body_digest" => @digest})

    assert {:ok, ^note} = record(:versions, note)

    asset =
      empty_version("asset", "included")
      |> Map.merge(%{
        "original_path" => "assets/#{@basename}.bin",
        "original_digest" => @digest,
        "original_byte_size" => 0,
        "media_type" => "application/octet-stream",
        "revision" => 0
      })

    assert {:ok, ^asset} = record(:versions, asset)

    for state <- ["pending", "extracting", "failed", "unsupported"] do
      value = %{document | "state" => state, "extracted_path" => nil, "extracted_digest" => nil}

      value =
        if state == "pending",
          do: %{value | "extraction_adapter" => nil, "extraction_format" => nil},
          else: value

      assert {:ok, ^value} = record(:versions, value)

      assert_invalid(
        record(:versions, Map.put(value, "extracted_path", document["extracted_path"]))
      )
    end
  end

  test "metadata-only availability never grants a body original or extracted file" do
    for kind <- ["note", "document", "asset"],
        availability <- [
          "metadata_only_deleted",
          "metadata_only_unavailable",
          "metadata_only_unselected"
        ] do
      value = empty_version(kind, availability)
      assert {:ok, ^value} = record(:versions, value)

      for {field, path} <- [
            {"body_path", "notes/#{@basename}.md"},
            {"original_path", "documents/originals/#{@basename}.pdf"},
            {"extracted_path", "documents/extracted/#{@basename}.txt"}
          ] do
        assert_invalid(record(:versions, Map.put(value, field, path)))
      end
    end
  end

  test "version shapes reject unknown availability states formats wrong pins and invalid sizes" do
    for {field, value} <- [
          {"availability", "available"},
          {"availability", :included},
          {"state", "done"},
          {"revision", -1},
          {"revision", 1.0},
          {"original_byte_size", -1},
          {"original_byte_size", 67_108_865},
          {"media_type", "image/png"},
          {"extraction_adapter", "ocr"},
          {"extraction_format", 2},
          {"original_path", "documents/originals/#{@resource}--#{@other}.pdf"},
          {"body_path", "notes/#{@basename}.md"},
          {"parent_version_id", "bad"},
          {"original_digest", String.upcase(@digest)}
        ] do
      assert_invalid(record(:versions, Map.put(fixture(:versions), field, value)))
    end
  end

  test "fragments validate readable locators lowercase identity and byte offsets including zero" do
    for locator <- [
          %{"version" => 1, "kind" => "pdf", "page" => 2},
          %{"version" => 1, "kind" => "text", "start_line" => 1, "end_line" => 2},
          %{"version" => 1, "kind" => "markdown", "heading_path" => ["界"]},
          %{"version" => 1, "kind" => "fragment", "ordinal" => 0}
        ] do
      value = Map.put(fixture(:fragments), "locator", locator)
      assert {:ok, ^value} = record(:fragments, value)
    end

    metadata = %{
      fixture(:fragments)
      | "extracted_path" => nil,
        "start_byte" => nil,
        "byte_size" => nil
    }

    assert {:ok, ^metadata} = record(:fragments, metadata)

    for {field, value} <- [
          {"id", String.upcase(@digest)},
          {"ordinal", -1},
          {"ordinal", 0.0},
          {"start_byte", -1},
          {"byte_size", 65_537},
          {"start_byte", nil},
          {"locator", %{"version" => 1, "kind" => "pdf", "page" => 0}},
          {"locator",
           %{"version" => 1, "kind" => "fragment", "ordinal" => 0, "storage_ref" => "secret"}}
        ] do
      assert_invalid(record(:fragments, Map.put(fixture(:fragments), field, value)))
    end
  end

  test "tag and edge values retain their canonical normalization and closed vocabulary" do
    tag = %{"id" => @member, "display_value" => "Straße", "normalized_key" => "strasse"}
    assert {:ok, ^tag} = record(:tags, tag)
    assert_invalid(record(:tags, Map.put(tag, "normalized_key", "straße")))
    assert_invalid(record(:tags, Map.put(tag, "display_value", "Straße\n")))

    for type <- ["related_to", "references", "derived_from"] do
      edge = Map.put(fixture(:relationships), "type", type)
      assert {:ok, ^edge} = record(:relationships, edge)
    end

    for {kind, field, bad} <- [
          {:relationships, "type", "owns"},
          {:relationships, "target_version_id", "bad"},
          {:attachments, "target_kind", "vault"},
          {:attachments, "role", "owner"},
          {:attachments, "ordinal", -1},
          {:attachments, "label", "canary\0"},
          {:citations, "ordinal", 0.5},
          {:citations, "fragment_id", "bad"},
          {:tag_assignments, "tag_id", "bad"}
        ] do
      assert_invalid(record(kind, Map.put(fixture(kind), field, bad)))
    end
  end

  test "file records reject manifest recursion unsafe paths and non-byte sizes" do
    for {field, value} <- [
          {"path", "manifest.json"},
          {"path", "../secret"},
          {"path", "/secret"},
          {"path", "notes/Title (copy).md"},
          {"path", %{symlink: "secret"}},
          {"path", "documents/originals/#{@basename}.pdf\0"},
          {"byte_size", -1},
          {"byte_size", 1.0},
          {"byte_size", 68_719_476_737},
          {"media_type", "application/pdf\nX-Secret: canary"}
        ] do
      assert_invalid(record(:files, Map.put(fixture(:files), field, value)))
    end
  end

  test "PDF original file metadata honors the exact 64 MiB item ceiling" do
    assert_file_boundary("documents/originals/#{@basename}.pdf", "application/pdf", 67_108_864)
  end

  test "Markdown original file metadata honors the exact 64 MiB item ceiling" do
    assert_file_boundary("documents/originals/#{@basename}.md", "text/markdown", 67_108_864)
  end

  test "plain text original file metadata honors the exact 64 MiB item ceiling" do
    assert_file_boundary("documents/originals/#{@basename}.txt", "text/plain", 67_108_864)
  end

  test "extracted text file metadata honors the exact 16 MiB item ceiling" do
    assert_file_boundary("documents/extracted/#{@basename}.txt", "text/plain", 16_777_216)
  end

  test "rendered Note file metadata honors the exact 16 MiB item ceiling" do
    assert_file_boundary("notes/#{@basename}.md", "text/markdown", 16_777_216)
  end

  test "Asset file metadata retains the exact 64 GiB ceiling" do
    assert_file_boundary("assets/#{@basename}.bin", "application/octet-stream", 68_719_476_736)
  end

  defp assert_file_boundary(path, media_type, ceiling) do
    # Validate declared sizes only: no content allocation or filesystem proof.
    value = %{
      fixture(:files)
      | "path" => path,
        "media_type" => media_type,
        "byte_size" => ceiling
    }

    assert {:ok, ^value} = record(:files, value)
    assert_invalid(record(:files, Map.put(value, "byte_size", ceiling + 1)))
  end

  defp fixture(:resources),
    do: %{
      "id" => @resource,
      "kind" => "document",
      "title" => "Two same titles 界",
      "current_version_id" => @version,
      "deleted_at" => nil,
      "selection_reason" => "head"
    }

  defp fixture(:versions) do
    empty_version("document", "included")
    |> Map.merge(%{
      "original_path" => "documents/originals/#{@basename}.pdf",
      "extracted_path" => "documents/extracted/#{@basename}.txt",
      "original_digest" => @digest,
      "original_byte_size" => 3,
      "extracted_digest" => @digest,
      "media_type" => "application/pdf",
      "state" => "ready",
      "extraction_adapter" => "poppler_text",
      "extraction_format" => 1
    })
  end

  defp fixture(:fragments),
    do: %{
      "id" => @digest,
      "resource_id" => @resource,
      "version_id" => @version,
      "ordinal" => 0,
      "digest" => @digest,
      "locator" => %{"version" => 1, "kind" => "pdf", "page" => 1},
      "extracted_path" => "documents/extracted/#{@basename}.txt",
      "start_byte" => 0,
      "byte_size" => 3
    }

  defp fixture(:tags),
    do: %{"id" => @member, "display_value" => "Source", "normalized_key" => "source"}

  defp fixture(:tag_assignments), do: %{"resource_id" => @resource, "tag_id" => @member}

  defp fixture(:relationships),
    do: %{
      "id" => @member,
      "source_resource_id" => @other,
      "target_resource_id" => @resource,
      "target_version_id" => nil,
      "type" => "references"
    }

  defp fixture(:attachments),
    do: %{
      "note_resource_id" => @other,
      "note_version_id" => @member,
      "id" => @member,
      "ordinal" => 0,
      "target_resource_id" => @resource,
      "target_version_id" => @version,
      "target_kind" => "document",
      "role" => "source",
      "label" => nil
    }

  defp fixture(:citations),
    do: %{
      "note_resource_id" => @other,
      "note_version_id" => @member,
      "id" => @member,
      "ordinal" => 0,
      "source_resource_id" => @resource,
      "source_version_id" => @version,
      "fragment_id" => @digest,
      "locator" => %{"version" => 1, "kind" => "pdf", "page" => 1}
    }

  defp fixture(:files),
    do: %{
      "path" => "documents/originals/#{@basename}.pdf",
      "media_type" => "application/pdf",
      "byte_size" => 3,
      "sha256" => @digest
    }

  defp empty_version(kind, availability) do
    @version_keys
    |> Map.new(&{&1, nil})
    |> Map.merge(%{
      "resource_id" => @resource,
      "version_id" => @version,
      "revision" => 1,
      "kind" => kind,
      "inserted_at" => @time,
      "availability" => availability
    })
  end

  defp record(kind, input), do: call(:record, [kind, input])

  defp call(function, args) do
    assert Code.ensure_loaded?(@manifest), "missing pure KnowledgeExportManifest contract"
    assert function_exported?(@manifest, function, length(args))
    apply(@manifest, function, args)
  end

  defp assert_invalid(result), do: assert(result == {:error, Error.new(:invalid)})
end
