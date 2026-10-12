defmodule Singularity.Storage.KnowledgeExport.WriterTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.{
    DocumentFragment,
    Error,
    KnowledgeExport,
    KnowledgeExportManifest,
    NoteAttachmentReference,
    NoteCitationReference,
    NoteMarkdownSources,
    SourceLocator
  }

  alias Singularity.Storage.KnowledgeExport.Spool

  @moduletag :tmp_dir
  @writer Singularity.Storage.KnowledgeExport.Writer
  @collections ~w(resources versions fragments tags tag_assignments relationships attachments citations)a
  @top_keys ~w(format version selection resources versions fragments tags tag_assignments relationships attachments citations files)
  @record_fields %{
    resources: ~w(id kind title current_version_id deleted_at selection_reason),
    versions:
      ~w(resource_id version_id revision kind inserted_at availability body_path original_path extracted_path body_digest original_digest original_byte_size extracted_digest media_type state extraction_adapter extraction_format parent_version_id merge_parent_version_id),
    fragments:
      ~w(id resource_id version_id ordinal digest locator extracted_path start_byte byte_size),
    tags: ~w(id display_value normalized_key),
    tag_assignments: ~w(resource_id tag_id),
    relationships: ~w(id source_resource_id target_resource_id target_version_id type),
    attachments:
      ~w(note_resource_id note_version_id id ordinal target_resource_id target_version_id target_kind role label),
    citations:
      ~w(note_resource_id note_version_id id ordinal source_resource_id source_version_id fragment_id locator),
    files: ~w(path media_type byte_size sha256)
  }
  @time "2026-10-11T01:02:03.123456Z"
  @body "WRITER_CANONICAL_BODY_72c0\n界 😀\n"
  @private_canaries ["PRIVATE_LOOKUP_", "PRIVATE_CIPHERTEXT_", "PRIVATE_STORAGE_"]

  # Internal trusted composition, not request input or a custody/authentication proof:
  # open(context) -> {:ok, writer}; append_* -> {:ok, next_writer};
  # finish(writer) -> {:ok, artifact}; abort(writer_or_artifact) -> :ok;
  # entries(artifact, nil_or_cursor) -> {:ok, %{entries: page, next_cursor: cursor}};
  # read_chunk(artifact, relative_path, ordinal) -> {:ok, binary}.
  # original_fold.(exact_selector, acc, emit) -> {:ok, acc} only after closure;
  # emit.(authenticated_chunk, acc) -> {:ok, acc}. Writer computes the digest.
  # The future Runtime bridge resolves Document selectors from immutable pins and
  # the sealed capture, NEVER by comparing sizes/digests with another binding.
  setup %{tmp_dir: tmp_dir} do
    roots =
      Map.new(~w(writer capture ciphertext backup)a, &{&1, Path.join(tmp_dir, to_string(&1))})

    for path <- Map.values(roots) do
      File.mkdir!(path)
      File.chmod!(path, 0o700)
    end

    sentinel = Path.join(roots.writer, "neighbor-sentinel")
    File.write!(sentinel, "neighbor")
    %{roots: roots, sentinel: sentinel}
  end

  test "open requires a real sealed capture and creates random private exclusive operations", c do
    f = fixture(c)
    {:ok, one} = call(:open, [context(c, f)])
    {:ok, two} = call(:open, [context(c, f)])
    assert {:ok, _} = Ecto.UUID.cast(one.operation_id)
    refute one.operation_id == two.operation_id
    assert_private_tree(staging(c, one))
    assert_private_tree(staging(c, two))
    assert_mode(staging(c, one), 0o700)
    assert one.deadline == f.capture._deadline
    refute inspect(one, limit: :infinity, printable_limit: :infinity) =~ @body
    assert :ok = call(:abort, [one])
    assert :ok = call(:abort, [one])
    refute File.exists?(staging(c, one))
    assert File.dir?(staging(c, two))
    assert File.read!(c.sentinel) == "neighbor"
    assert :ok = call(:abort, [two])
  end

  test "unsealed aborted and forged captures cannot supply Writer authority", c do
    {:ok, unsealed} = Spool.open(spool_context(c))
    f = fixture(c)

    for capture <- [unsealed, %{}, Map.put(f.capture, :capture_id, uuid(999))] do
      assert_error(call(:open, [%{context(c, f) | capture: capture}]), :invalid)
    end

    assert :ok = Spool.abort(unsealed)
    assert :ok = Spool.abort(f.capture)
    assert_error(call(:open, [context(c, f)]))
    assert_writer_root_empty(c)
  end

  test "trusted roots reject traversal overlap insecure modes and symlink ancestors", c do
    f = fixture(c)

    for root <- [
          "relative",
          c.roots.ciphertext,
          c.roots.backup,
          Path.join(c.roots.ciphertext, "nested"),
          Path.dirname(c.roots.ciphertext)
        ] do
      assert_error(call(:open, [%{context(c, f) | root: root}]), :invalid)
    end

    File.chmod!(c.roots.writer, 0o755)
    assert_error(call(:open, [context(c, f)]), :invalid)
    File.chmod!(c.roots.writer, 0o700)
    link = Path.join(Path.dirname(c.roots.writer), "writer-link")
    File.ln_s!(c.roots.writer, link)
    assert_error(call(:open, [%{context(c, f) | root: link}]), :invalid)
    assert_writer_root_empty(c)
  end

  test "no request quota TTL path hash key wrapper or lease overrides are accepted", c do
    f = fixture(c)

    for key <- [
          :limits,
          :quota,
          :max_bytes,
          :metadata_bytes,
          :file_bytes,
          :metadata_records,
          :selected_keys,
          :execution_ms,
          :clock,
          :deadline,
          :ttl,
          :path,
          :sha256,
          :keys,
          :wrapped_dek,
          :lease,
          :owner_scope_id
        ] do
      assert_error(call(:open, [Map.put(context(c, f), key, 1)]), :invalid)
    end

    for options <- [%{include_tombstones: "true"}, %{root: c.roots.writer}, %{limits: %{}}] do
      assert_error(call(:open, [%{context(c, f) | options: options}]), :invalid)
    end

    assert_writer_root_empty(c)
  end

  test "complete portable fixture has exact schema bytes references hashes and no private binding",
       c do
    f = fixture(c)
    artifact = materialize(c, f)
    {manifest_bytes, manifest, entries} = inspect_artifact(artifact)
    assert Enum.sort(Map.keys(manifest)) == Enum.sort(@top_keys)
    assert manifest["format"] == "singularity.portable-knowledge"
    assert manifest["version"] === 1

    assert manifest["selection"] == %{
             "mode" => "live_heads_with_source_closure",
             "include_tombstones" => true
           }

    assert_top_key_order(manifest_bytes)

    assert Enum.map(manifest["files"], & &1["path"]) ==
             Enum.sort(Enum.map(manifest["files"], & &1["path"]))

    refute Enum.any?(manifest["files"], &(&1["path"] == "manifest.json"))

    assert [%{"path" => "manifest.json", "byte_size" => size, "sha256" => digest}] =
             Enum.filter(entries, &(&1["path"] == "manifest.json"))

    assert size == byte_size(manifest_bytes)
    assert digest == sha(manifest_bytes)

    assert artifact.manifest == %{
             "path" => "manifest.json",
             "media_type" => "application/json",
             "byte_size" => size,
             "sha256" => digest
           }

    assert Enum.sort(entries) == Enum.sort([artifact.manifest | manifest["files"]])
    assert File.dir?(completed(c, artifact))
    refute File.exists?(staging(c, artifact))
    assert_private_tree(completed(c, artifact))

    for collection <- @collections do
      records = manifest[Atom.to_string(collection)]
      assert records != []

      for record <- records,
          do: assert({:ok, ^record} = KnowledgeExportManifest.record(collection, record))
    end

    assert_metadata_equal(f, manifest)
    assert_record_order(manifest)

    for collection <- @collections ++ [:files], record <- manifest[Atom.to_string(collection)] do
      assert manifest_bytes =~ canonical_record(collection, record)
    end

    for entry <- entries do
      bytes = read_all(artifact, entry)
      assert byte_size(bytes) == entry["byte_size"]
      assert sha(bytes) == entry["sha256"]
      assert File.read!(Path.join(completed(c, artifact), entry["path"])) == bytes
    end

    for field <-
          ~w(owner_scope_id vault_id principal_id session_id object_id asset_id storage_ref lookup_digest ciphertext_hash wrapped_dek key_domain_id domain_key_version_id plaintext_sha256) do
      refute manifest_bytes =~ "\"#{field}\""
    end

    for canary <- @private_canaries, do: refute(manifest_bytes =~ canary)

    for private_id <- [uuid(4_000), uuid(5_000), uuid(6_000)],
        do: refute(manifest_bytes =~ private_id)

    refute inspect(artifact, limit: :infinity, printable_limit: :infinity) =~ @body
    assert :ok = call(:abort, [artifact])
    assert_writer_root_empty(c)
  end

  test "empty sealed selection completes only an independently verified manifest", c do
    {:ok, spool} = Spool.open(spool_context(c))
    {:ok, capture} = Spool.seal(spool)
    on_exit(fn -> assert :ok = Spool.abort(capture) end)
    f = %{capture: capture, include_tombstones: false, originals: %{}}
    token = make_ref()

    fold = fn _, _, _ ->
      send(self(), token)
      {:error, Error.new(:invalid)}
    end

    {:ok, writer} = call(:open, [context(c, f, %{original_fold: fold})])
    {:ok, artifact} = call(:finish, [writer])
    {bytes, manifest, [entry]} = inspect_artifact(artifact)
    assert {:ok, ^manifest} = KnowledgeExportManifest.header(%{include_tombstones: false})
    assert entry == artifact.manifest
    assert entry["byte_size"] == byte_size(bytes)
    assert entry["sha256"] == sha(bytes)
    refute_receive ^token, 0
    assert :ok = call(:abort, [artifact])
    assert_writer_root_empty(c)
  end

  test "identical captures yield byte-identical files despite insertion operation and clock differences",
       c do
    first = fixture(c, %{reverse: false, now: 10})
    second = fixture(c, %{reverse: true, now: 50_000})
    one = materialize(c, first)
    two = materialize(c, second)
    {bytes_one, _, entries_one} = inspect_artifact(one)
    {bytes_two, _, entries_two} = inspect_artifact(two)
    assert bytes_one == bytes_two
    assert entries_one == entries_two
    for entry <- entries_one, do: assert(read_all(one, entry) == read_all(two, entry))
    refute bytes_one =~ "exported_at"
    refute bytes_one =~ one.operation_id
    refute bytes_one =~ first.capture.capture_id
    assert :ok = call(:abort, [one])
    assert :ok = call(:abort, [two])
  end

  test "canonical Note SHA is distinct from rendered SHA and sealed typed sources remain readable",
       c do
    f = fixture(c)
    artifact = materialize(c, f)
    {_, manifest, entries} = inspect_artifact(artifact)
    [note_version] = Enum.filter(manifest["versions"], &(&1["version_id"] == uuid(1_001)))
    entry = Enum.find(entries, &(&1["path"] == path(:note, 1)))
    rendered = read_all(artifact, entry)
    assert note_version["body_digest"] == sha(@body)
    assert entry["sha256"] == sha(rendered)
    refute entry["sha256"] == note_version["body_digest"]
    assert String.starts_with?(rendered, @body)
    assert rendered =~ "## Sources"
    assert rendered =~ "../assets/#{uuid(5)}--#{uuid(1_005)}.bin"
    assert rendered =~ "../documents/extracted/#{uuid(2)}--#{uuid(1_002)}.txt"
    assert rendered =~ "deleted historical source"
    refute rendered =~ "sources/"
    refute rendered =~ "javascript:"
    refute rendered =~ "PRIVATE_"
    for id <- [uuid(501), uuid(502), uuid(503), uuid(601), uuid(602)], do: assert(rendered =~ id)
    assert rendered =~ fragment_id(13, 0, "deleted fragment")
    assert rendered =~ "Text lines 1–2"

    portable_files = %{
      {:asset, uuid(5), uuid(1_005)} => %{
        availability: "included",
        path: path(:asset, 5),
        reason: nil
      },
      {:asset, uuid(12), uuid(1_012)} => %{
        availability: "included",
        path: path(:asset, 12),
        reason: nil
      },
      {:document, uuid(2), uuid(1_002)} => %{
        availability: "included",
        path: path(:extracted, 2),
        reason: nil
      },
      {:note, uuid(6), uuid(1_006)} => %{
        availability: "metadata_only_deleted",
        path: nil,
        reason: "Deleted source"
      },
      {:document, uuid(13), uuid(1_013)} => %{
        availability: "metadata_only_deleted",
        path: nil,
        reason: "Deleted source"
      }
    }

    assert {:ok, ^rendered} =
             NoteMarkdownSources.render_portable(@body, descriptions(), portable_files)

    assert :ok = call(:abort, [artifact])
  end

  test "UTF8 fragment offsets are bytes and extracted text has no added delimiter", c do
    f = fixture(c)
    artifact = materialize(c, f)
    {_, manifest, entries} = inspect_artifact(artifact)
    entry = Enum.find(entries, &(&1["path"] == path(:extracted, 2)))
    assert read_all(artifact, entry) == "界😀tail\n"
    assert entry["sha256"] == sha("界😀tail\n")
    [first, second] = Enum.filter(manifest["fragments"], &(&1["resource_id"] == uuid(2)))
    assert first["start_byte"] == 0
    assert first["byte_size"] == 7
    assert first["digest"] == sha("界😀")
    assert second["start_byte"] == 7
    assert second["byte_size"] == 5
    assert second["digest"] == sha("tail\n")

    assert binary_part(read_all(artifact, entry), second["start_byte"], second["byte_size"]) ==
             "tail\n"

    assert :ok = call(:abort, [artifact])
  end

  test "binary empty and Unicode originals are hashed from the fold not lookup or callback claims",
       c do
    token = make_ref()
    f = fixture(c)

    drafts =
      Enum.filter(
        f.records.versions,
        &(&1["kind"] == "asset" and &1["availability"] == "included")
      )

    assert Enum.map(drafts, &{&1["resource_id"], &1["original_byte_size"]}) ==
             [{uuid(5), 6}, {uuid(12), 0}]

    for draft <- drafts do
      assert draft["original_digest"] == nil
      assert {:error, %Error{code: :invalid}} = KnowledgeExportManifest.record(:versions, draft)
    end

    [metadata_only] =
      Enum.filter(
        f.records.versions,
        &(&1["kind"] == "asset" and &1["availability"] == "metadata_only_unselected")
      )

    assert metadata_only["resource_id"] == uuid(14)
    assert metadata_only["version_id"] == uuid(1_014)
    assert metadata_only["original_digest"] == nil
    assert metadata_only["original_byte_size"] == nil
    assert metadata_only["original_path"] == nil
    assert metadata_only["body_path"] == nil
    assert {:ok, ^metadata_only} = KnowledgeExportManifest.record(:versions, metadata_only)

    fold = fn selector, acc, emit ->
      send(self(), {token, selector})
      fold_bytes(Map.fetch!(f.originals, selector), acc, emit)
    end

    artifact = materialize(c, f, %{original_fold: fold})
    {_, manifest, entries} = inspect_artifact(artifact)

    for {selector, bytes} <- f.originals do
      assert_receive {^token, ^selector}
      {:original, kind, resource, version} = selector

      [record] =
        Enum.filter(
          manifest["versions"],
          &(&1["resource_id"] == resource and &1["version_id"] == version)
        )

      assert record["original_digest"] == sha(bytes)
      assert record["original_byte_size"] == byte_size(bytes)
      entry = Enum.find(entries, &(&1["path"] == record["original_path"]))
      assert read_all(artifact, entry) == bytes
      assert entry["sha256"] == sha(bytes)

      if kind == :asset,
        do: refute(record["original_digest"] == sha("PRIVATE_LOOKUP_#{resource}"))
    end

    refute_receive {^token, _}
    empty = Enum.find(entries, &(&1["path"] == path(:asset, 12)))
    assert empty["byte_size"] == 0
    assert empty["sha256"] == sha("")
    assert {:ok, ""} = call(:read_chunk, [artifact, empty["path"], 0])
    assert_error(call(:read_chunk, [artifact, empty["path"], 1]), :invalid)
    assert :ok = call(:abort, [artifact])
  end

  test "Document public selector is forwarded unchanged even with identical Asset size and digest",
       c do
    f = fixture(c)
    token = make_ref()

    fold = fn selector, acc, emit ->
      send(self(), {token, selector})
      fold_bytes(Map.fetch!(f.originals, selector), acc, emit)
    end

    artifact = materialize(c, f, %{original_fold: fold})
    # Same actual bytes intentionally do not identify the original's private binding.
    assert f.originals[{:original, :document, uuid(2), uuid(1_002)}] ==
             f.originals[{:original, :asset, uuid(5), uuid(1_005)}]

    assert_receive {^token, {:original, :document, document_resource, document_version}}
    assert document_resource == uuid(2)
    assert document_version == uuid(1_002)
    assert_receive {^token, {:original, :asset, asset_resource, asset_version}}
    assert asset_resource == uuid(5)
    assert asset_version == uuid(1_005)
    assert :ok = call(:abort, [artifact])
  end

  test "nonready Documents retain originals and explicit states without fabricated text", c do
    f = fixture(c)
    artifact = materialize(c, f)
    {_, manifest, entries} = inspect_artifact(artifact)

    for {n, state} <- [{3, "pending"}, {4, "failed"}, {8, "unsupported"}, {9, "extracting"}] do
      [record] = Enum.filter(manifest["versions"], &(&1["resource_id"] == uuid(n)))
      assert record["state"] == state
      assert record["original_path"] == path(:document, n)
      assert record["extracted_path"] == nil
      assert record["extracted_digest"] == nil
      refute Enum.any?(entries, &(&1["path"] == path(:extracted, n)))
      refute Enum.any?(manifest["fragments"], &(&1["resource_id"] == uuid(n)))
    end

    assert :ok = call(:abort, [artifact])
  end

  test "positive deleted and ancestry metadata stay fileless and do not invoke originals", c do
    f = fixture(c)
    artifact = materialize(c, f)
    {_, manifest, entries} = inspect_artifact(artifact)

    for {n, availability} <- [
          {6, "metadata_only_deleted"},
          {14, "metadata_only_unselected"},
          {13, "metadata_only_deleted"}
        ] do
      [record] = Enum.filter(manifest["versions"], &(&1["resource_id"] == uuid(n)))
      assert record["availability"] == availability
      for field <- ~w(body_path original_path extracted_path), do: assert(record[field] == nil)
      refute Enum.any?(entries, &String.contains?(&1["path"], uuid(n)))
    end

    [ancestor] = Enum.filter(manifest["versions"], &(&1["version_id"] == uuid(1_007)))
    assert ancestor["resource_id"] == uuid(1)
    assert ancestor["availability"] == "metadata_only_unselected"
    assert ancestor["body_path"] == nil
    refute Enum.any?(entries, &String.contains?(&1["path"], uuid(1_007)))
    [deleted_fragment] = Enum.filter(manifest["fragments"], &(&1["resource_id"] == uuid(13)))
    assert deleted_fragment["extracted_path"] == nil
    assert deleted_fragment["start_byte"] == nil
    assert deleted_fragment["byte_size"] == nil
    refute Enum.any?(manifest["versions"], &(&1["availability"] == "metadata_only_unavailable"))
    assert :ok = call(:abort, [artifact])
  end

  test "original include_tombstones false is preserved even when deleted source metadata is present",
       c do
    f = fixture(c, %{include_tombstones: false})
    artifact = materialize(c, f)
    {_, manifest, _} = inspect_artifact(artifact)
    assert manifest["selection"]["include_tombstones"] === false
    assert Enum.any?(manifest["versions"], &(&1["availability"] == "metadata_only_deleted"))
    assert :ok = call(:abort, [artifact])
  end

  test "append_manifest_record accepts only exact fixed captured records and never caller files",
       c do
    f = fixture(c)
    original = hd(f.records.resources)

    for {collection, record} <- [
          {:resources, Map.put(original, "title", "unchecked post-seal replacement")},
          {:resources, Map.put(original, "storage_ref", "PRIVATE_STORAGE_SECRET")},
          {:versions,
           Map.put(hd(f.records.versions), "availability", "metadata_only_unavailable")},
          {:files,
           %{
             "path" => "manifest.json",
             "media_type" => "application/json",
             "byte_size" => 0,
             "sha256" => sha("")
           }},
          {:unknown, original},
          {"resources", original},
          {:resources, :erlang.term_to_binary(original)}
        ] do
      {:ok, writer} = call(:open, [context(c, f)])
      assert_error(call(:append_manifest_record, [writer, collection, record]))
      assert :ok = call(:abort, [writer])
    end

    assert_writer_root_empty(c)
  end

  test "genuinely sealed Note text cannot satisfy an inconsistent captured canonical body SHA",
       c do
    wrong_digest = sha("different canonical Note")
    f = fixture(c, %{note_digest: wrong_digest})

    [version] =
      Enum.filter(captured_records(f.capture, :versions), &(&1["version_id"] == uuid(1_001)))

    assert version["body_digest"] == wrong_digest
    assert {:ok, ^version} = KnowledgeExportManifest.record(:versions, version)
    selector = {:note_markdown, uuid(1), uuid(1_001)}
    reference = Map.fetch!(f.capture.text_refs, selector)
    assert f.capture.sealed? === true
    assert reference.selector == selector
    assert reference.sha256 == sha(@body)
    assert reference.byte_size == byte_size(@body)
    assert {:ok, @body} = Spool.read_chunk(f.capture, reference, 0)
    refute version["body_digest"] == reference.sha256

    {:ok, writer} = call(:open, [context(c, f)])
    assert_error(append_until_error(writer, f), :integrity_failure)
    assert :ok = call(:abort, [writer])
    assert_writer_root_empty(c)
  end

  test "genuinely sealed fragment text cannot satisfy an inconsistent captured canonical SHA",
       c do
    assert_sealed_fragment_denied(c, %{fragment_digest: sha("wrong fragment")}, "digest")
  end

  test "genuinely sealed fragment selector cannot invent the canonical fragment identity", c do
    # The uncited second fragment isolates canonical identity from citation closure.
    assert_sealed_fragment_denied(c, %{fragment_id: sha("wrong fragment identity")}, "id")
  end

  test "genuinely sealed Unicode fragments cannot use character counts as extracted byte offsets",
       c do
    assert String.length("界😀") == 2
    assert byte_size("界😀") == 7
    assert_sealed_fragment_denied(c, %{fragment_offset: 2}, "start_byte")
  end

  test "genuinely sealed Unicode fragments cannot declare a character-sized canonical byte length",
       c do
    assert String.length("界😀") == 2
    assert byte_size("界😀") == 7
    assert_sealed_fragment_denied(c, %{first_fragment_size: 2}, "byte_size", 0)
  end

  test "Spool rejects an inconsistent complete extracted SHA before any Writer authority exists",
       c do
    wrong_digest = sha("界😀\ntail\n")
    f = prepare_fixture(c, %{extracted_digest: wrong_digest})
    on_exit(fn -> assert :ok = Spool.abort(f.spool) end)
    [version] = Enum.filter(f.records.versions, &(&1["version_id"] == uuid(1_002)))
    assert {:ok, ^version} = KnowledgeExportManifest.record(:versions, version)
    assert version["extracted_digest"] == wrong_digest
    refute version["extracted_digest"] == sha("界😀tail\n")
    [first, second] = Enum.filter(f.records.fragments, &(&1["resource_id"] == uuid(2)))
    assert first["digest"] == sha("界😀")
    assert second["digest"] == sha("tail\n")
    assert first["start_byte"] == 0
    assert second["start_byte"] == byte_size("界😀")
    assert f.spool.sealed? === false

    # complete_documents/1 hashes the real ordinal text frames without a delimiter.
    # This is a native Spool denial, not a fabricated sealed capture or Writer denial.
    assert_error(Spool.seal(f.spool), :integrity_failure)
    assert :ok = Spool.abort(f.spool)
    assert File.ls!(c.roots.capture) == []
    assert_writer_root_empty(c)
  end

  test "append_file rejects arbitrary paths raw text and cross-capture or altered refs", c do
    f = fixture(c)
    other = fixture(c)
    selector = {:note_markdown, uuid(1), uuid(1_001)}
    reference = f.capture.text_refs[selector]

    for {key, ref} <- [
          {selector, @body},
          {selector, other.capture.text_refs[selector]},
          {selector, Map.put(reference, :sha256, sha("forged"))},
          {selector, Map.put(reference, :offset, reference.offset + 1)},
          {selector, Map.put(reference, :byte_size, reference.byte_size + 1)},
          {selector, Map.put(reference, :path, c.sentinel)},
          {"../../neighbor-sentinel", reference},
          {{:note_markdown, uuid(1), String.upcase(uuid(1_001))}, reference},
          {{:note_markdown, String.upcase(uuid(31)), uuid(1_001)}, reference},
          {{:original, :asset, uuid(5), uuid(1_005)}, %{sha256: sha("invented")}},
          {{:original, :document, uuid(13), uuid(1_013)}, :authenticated}
        ] do
      {:ok, writer} = call(:open, [context(c, f)])
      writer = append_records(writer, f)
      assert_error(call(:append_file, [writer, key, ref]))
      assert :ok = call(:abort, [writer])
    end

    assert_writer_root_empty(c)
  end

  test "duplicate record file or case-fold alias cannot overwrite an existing file", c do
    f = fixture(c)
    {:ok, writer} = call(:open, [context(c, f)])
    record = hd(f.records.resources)
    {:ok, writer} = call(:append_manifest_record, [writer, :resources, record])
    assert_error(call(:append_manifest_record, [writer, :resources, record]))
    assert :ok = call(:abort, [writer])
    {:ok, writer} = call(:open, [context(c, f)])
    writer = append_records(writer, f)
    selector = {:original, :asset, uuid(5), uuid(1_005)}
    {:ok, writer} = call(:append_file, [writer, selector, :authenticated])
    assert_error(call(:append_file, [writer, selector, :authenticated]))
    assert :ok = call(:abort, [writer])
    assert_writer_root_empty(c)
  end

  test "existing destination file is never overwritten", c do
    f = fixture(c)
    {:ok, writer} = call(:open, [context(c, f)])
    writer = append_records(writer, f)
    directory = Path.join(staging(c, writer), "assets")
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    target = Path.join(staging(c, writer), path(:asset, 5))
    File.write!(target, "EXISTING_DO_NOT_OVERWRITE")
    File.chmod!(target, 0o600)

    assert_error(
      call(:append_file, [writer, {:original, :asset, uuid(5), uuid(1_005)}, :authenticated])
    )

    if File.exists?(target), do: assert(File.read!(target) == "EXISTING_DO_NOT_OVERWRITE")
    assert :ok = call(:abort, [writer])
    assert_writer_root_empty(c)
  end

  test "symlink destination never writes through to a neighboring root", c do
    f = fixture(c)
    {:ok, writer} = call(:open, [context(c, f)])
    writer = append_records(writer, f)
    outside = Path.join(c.roots.backup, "neighbor")
    File.mkdir!(outside)
    File.write!(Path.join(outside, "sentinel"), "outside")
    File.ln_s!(outside, Path.join(staging(c, writer), "assets"))

    assert_error(
      call(:append_file, [writer, {:original, :asset, uuid(5), uuid(1_005)}, :authenticated])
    )

    assert File.ls!(outside) == ["sentinel"]
    assert File.read!(Path.join(outside, "sentinel")) == "outside"
    assert :ok = call(:abort, [writer])
    assert_writer_root_empty(c)
  end

  test "finish verifies complete metadata closure and every required file before publication",
       c do
    f = fixture(c)
    {:ok, writer} = call(:open, [context(c, f)])
    writer = append_records(writer, f)
    assert_error(call(:finish, [writer]))
    refute File.exists?(completed(c, writer))
    assert :ok = call(:abort, [writer])
    {:ok, writer} = call(:open, [context(c, f)])
    [omitted] = captured_records(f.capture, :relationships)
    assert omitted == hd(f.records.relationships)
    assert omitted["target_resource_id"] == uuid(14)
    writer = append_records(writer, f, [:relationships])
    writer = append_files(writer, f)
    assert_error(call(:finish, [writer]))
    refute File.exists?(completed(c, writer))
    assert :ok = call(:abort, [writer])
    assert_writer_root_empty(c)
  end

  test "missing real captured citations deny Note rendering before finish without exposing content",
       c do
    f = fixture(c)
    captured = captured_records(f.capture, :citations)
    assert length(captured) == 2
    assert Enum.sort(captured) == Enum.sort(f.records.citations)
    {:ok, writer} = call(:open, [context(c, f)])
    writer = append_records(writer, f, [:citations])
    writer = append_non_note_files(writer, f)
    selector = {:note_markdown, uuid(1), uuid(1_001)}
    reference = Map.fetch!(f.capture.text_refs, selector)
    assert_error(call(:append_file, [writer, selector, reference]), :integrity_failure)
    refute File.exists?(completed(c, writer))
    refute File.exists?(staging(c, writer))
    assert_writer_root_empty(c)
    assert :ok = call(:abort, [writer])
    assert_writer_root_empty(c)
  end

  test "manifest is last and completion rename cannot replace an existing completed operation",
       c do
    f = fixture(c)
    {:ok, writer} = call(:open, [context(c, f)])
    writer = writer |> append_records(f) |> append_files(f)
    refute File.exists?(Path.join(staging(c, writer), "manifest.json"))
    target = completed(c, writer)
    File.mkdir!(target)
    sentinel = Path.join(target, "do-not-replace")
    File.write!(sentinel, "existing-completed")
    assert_error(call(:finish, [writer]))
    assert File.read!(sentinel) == "existing-completed"
    assert :ok = call(:abort, [writer])
    assert File.read!(sentinel) == "existing-completed"
    assert File.read!(c.sentinel) == "neighbor"
  end

  test "completion cannot replace a preexisting empty directory", c do
    f = fixture(c)
    {:ok, writer} = call(:open, [context(c, f)])
    writer = writer |> append_records(f) |> append_files(f)
    target = completed(c, writer)
    File.mkdir!(target)
    File.chmod!(target, 0o700)
    original = native_identity(target)
    assert File.ls!(target) == []
    assert_error(call(:finish, [writer]))
    assert native_identity(target) == original
    assert File.ls!(target) == []
    refute File.exists?(staging(c, writer))
    assert :ok = call(:abort, [writer])
    assert native_identity(target) == original
    assert File.ls!(target) == []
    assert File.read!(c.sentinel) == "neighbor"
    File.rmdir!(target)
    assert_writer_root_empty(c)
  end

  test "completion cannot replace or follow a preexisting symlink", c do
    f = fixture(c)
    {:ok, writer} = call(:open, [context(c, f)])
    writer = writer |> append_records(f) |> append_files(f)
    target = completed(c, writer)
    outside = Path.join(c.roots.backup, "completion-neighbor")
    File.write!(outside, "foreign-completion")
    File.ln_s!(c.roots.backup, target)
    original = native_identity(target)
    assert original.type == :symlink
    assert_error(call(:finish, [writer]))
    assert native_identity(target) == original
    assert File.read_link!(target) == c.roots.backup
    assert File.read!(outside) == "foreign-completion"
    assert File.ls!(c.roots.backup) == ["completion-neighbor"]
    refute File.exists?(staging(c, writer))
    assert :ok = call(:abort, [writer])
    assert native_identity(target) == original
    assert File.read!(outside) == "foreign-completion"
    assert File.read!(c.sentinel) == "neighbor"
    File.rm!(target)
    assert_writer_root_empty(c)
  end

  test "native completion reservation identity drift denies publication and preserves foreign paths",
       c do
    for replacement <- [:directory, :symlink] do
      token = make_ref()
      owner = self()
      changed = :atomics.new(1, signed: true)
      foreign = Path.join(c.roots.backup, "reservation-neighbor")
      File.write!(foreign, "foreign-reservation")

      # The existing trusted capture clock is a synchronous barrier only. It
      # changes real native paths after exclusive mkdir, not a fabricated rename
      # result or an added Writer option. This does not prove hostile-UID atomicity.
      clock = fn ->
        targets = File.ls!(c.roots.writer) |> Enum.filter(&String.ends_with?(&1, ".complete"))

        if targets != [] and :atomics.compare_exchange(changed, 1, 0, 1) == :ok do
          [basename] = targets
          target = Path.join(c.roots.writer, basename)
          original = native_identity(target)
          assert original.type == :directory
          assert File.ls!(target) == []
          displaced = target <> "-owned-reservation"
          File.rename!(target, displaced)

          case replacement do
            :directory ->
              File.mkdir!(target)
              File.chmod!(target, 0o700)
              File.write!(Path.join(target, "foreign-sentinel"), "foreign-reservation")

            :symlink ->
              File.ln_s!(c.roots.backup, target)
          end

          send(owner, {token, target, displaced, original, native_identity(target)})
        end

        10
      end

      f = fixture(c, %{clock: clock})
      {:ok, writer} = call(:open, [context(c, f)])
      writer = writer |> append_records(f) |> append_files(f)
      assert_error(call(:finish, [writer]))
      assert_receive {^token, target, displaced, original, foreign_identity}
      assert target == completed(c, writer)
      assert native_identity(displaced) == original
      refute foreign_identity.inode == original.inode
      assert native_identity(target) == foreign_identity
      assert File.ls!(displaced) == []
      refute File.exists?(staging(c, writer))
      assert_error(call(:entries, [writer, nil]))
      assert_error(call(:abort, [writer]))
      assert native_identity(target) == foreign_identity
      assert File.read!(foreign) == "foreign-reservation"
      assert File.read!(c.sentinel) == "neighbor"

      case replacement do
        :directory ->
          sentinel = Path.join(target, "foreign-sentinel")
          assert File.read!(sentinel) == "foreign-reservation"
          File.rm!(sentinel)
          File.rmdir!(target)

        :symlink ->
          assert File.read_link!(target) == c.roots.backup
          assert File.ls!(c.roots.backup) == ["reservation-neighbor"]
          File.rm!(target)
      end

      # Restore the real witnessed owned inode before retrying genuine cleanup;
      # Writer must never adopt/remove the replacement merely to make abort pass.
      File.rename!(displaced, target)
      assert :ok = call(:abort, [writer])
      refute File.exists?(target)
      assert_writer_root_empty(c)
      File.rm!(foreign)
    end
  end

  test "original wrong bytes size final error or dishonest write success produce no artifact",
       c do
    f = fixture(c)
    selector = {:original, :document, uuid(2), uuid(1_002)}

    for fold <- [
          fn _, acc, emit -> fold_bytes("BADBAD", acc, emit) end,
          fn _, acc, emit -> fold_bytes("", acc, emit) end,
          fn _, acc, emit ->
            {:ok, _} = fold_bytes(Map.fetch!(f.originals, selector), acc, emit)
            {:error, Error.new(:forbidden)}
          end
        ] do
      {:ok, writer} = call(:open, [context(c, f, %{original_fold: fold})])
      writer = append_records(writer, f)
      assert_error(call(:append_file, [writer, selector, :authenticated]))
      refute File.exists?(completed(c, writer))
      assert :ok = call(:abort, [writer])
    end

    {:ok, writer} = call(:open, [context(c, f, %{write: fn _, _ -> :ok end})])
    result = append_until_error(writer, f)
    assert_error(result, :integrity_failure)
    refute File.exists?(completed(c, writer))
    assert :ok = call(:abort, [writer])
    assert_writer_root_empty(c)
  end

  test "pending Asset SHA cannot hide captured size mismatch or substitute a returned hash", c do
    f = fixture(c, %{asset_size: 7})
    {:ok, writer} = call(:open, [context(c, f)])
    writer = append_records(writer, f)

    assert_error(
      call(:append_file, [writer, {:original, :asset, uuid(5), uuid(1_005)}, :authenticated]),
      :integrity_failure
    )

    assert :ok = call(:abort, [writer])
    normal = fixture(c)
    selector = {:original, :document, uuid(2), uuid(1_002)}

    claim = fn _, acc, emit ->
      {:ok, next} = fold_bytes("BADBAD", acc, emit)
      {:ok, next, %{sha256: sha(Map.fetch!(normal.originals, selector)), byte_size: 6}}
    end

    {:ok, writer} = call(:open, [context(c, normal, %{original_fold: claim})])
    writer = append_records(writer, normal)
    assert_error(call(:append_file, [writer, selector, :authenticated]))
    assert :ok = call(:abort, [writer])
    assert_writer_root_empty(c)
  end

  test "callback exceptions and error details never expose canonical or private canaries", c do
    f = fixture(c)

    for fold <- [
          fn _, _, _ -> raise @body <> "PRIVATE_STORAGE_SECRET" end,
          fn _, _, _ ->
            {:error,
             Error.new(:forbidden,
               details: %{content: @body, storage_ref: "PRIVATE_STORAGE_SECRET"}
             )}
          end
        ] do
      {:ok, writer} = call(:open, [context(c, f, %{original_fold: fold})])
      writer = append_records(writer, f)

      assert_error(
        call(:append_file, [writer, {:original, :document, uuid(2), uuid(1_002)}, :authenticated])
      )

      refute File.exists?(completed(c, writer))
      assert :ok = call(:abort, [writer])
    end

    assert_writer_root_empty(c)
  end

  test "cancel between authenticated chunks stops the fold and never publishes", c do
    f = fixture(c)
    token = make_ref()

    fold = fn _, acc, emit ->
      {:ok, next} = emit.(<<0, 255, 1>>, acc)

      receive do
        {^token, :cancel, owned_writer} -> assert :ok = call(:abort, [owned_writer])
      after
        0 -> flunk("missing owning Writer cancellation descriptor")
      end

      result = emit.(<<2, 3, 4>>, next)
      send(self(), {token, result})
      result
    end

    {:ok, writer} = call(:open, [context(c, f, %{original_fold: fold})])
    writer = append_records(writer, f)
    send(self(), {token, :cancel, writer})

    assert_error(
      call(:append_file, [writer, {:original, :document, uuid(2), uuid(1_002)}, :authenticated])
    )

    assert_receive {^token, {:error, %Error{}}}
    assert :ok = call(:abort, [writer])
    assert_writer_root_empty(c)
  end

  test "real staged file tampering is detected at finish and completed tampering at delivery",
       c do
    f = fixture(c)

    for mutation <- [:same_size, :truncate] do
      {:ok, writer} = call(:open, [context(c, f)])
      writer = writer |> append_records(f) |> append_files(f)
      target = Path.join(staging(c, writer), path(:note, 1))
      bytes = File.read!(target)

      changed =
        if mutation == :same_size,
          do: String.replace(bytes, "72c0", "72c1"),
          else: binary_part(bytes, 0, 1)

      File.write!(target, changed)
      assert_error(call(:finish, [writer]), :integrity_failure)
      refute File.exists?(completed(c, writer))
      assert :ok = call(:abort, [writer])
    end

    artifact = materialize(c, f)
    File.write!(Path.join(completed(c, artifact), path(:asset, 5)), "tamper")
    assert_error(call(:read_chunk, [artifact, path(:asset, 5), 0]), :integrity_failure)
    assert :ok = call(:abort, [artifact])
    assert_writer_root_empty(c)
  end

  test "sealed capture text or metadata corruption cannot be downgraded to unavailable", c do
    for canary <- [@body, "Duplicate [title]", sha("PRIVATE_LOOKUP_#{uuid(5)}")] do
      f = fixture(c)
      {:ok, writer} = call(:open, [context(c, f)])
      target = payload_file(Path.join(c.roots.capture, f.capture.capture_id), canary)
      bytes = File.read!(target)
      changed = binary_part(bytes, 0, max(0, byte_size(bytes) - 1))
      File.write!(target, changed)
      assert_error(append_until_error(writer, f))
      refute File.exists?(completed(c, writer))
      assert :ok = call(:abort, [writer])
    end

    assert_writer_root_empty(c)
  end

  test "disk-full callback cleans real operation files without advertising partial output", c do
    f = fixture(c)
    token = make_ref()

    write = fn _device, bytes ->
      send(self(), {token, byte_size(bytes)})
      {:error, :enospc}
    end

    # SYNTHETIC ENOSPC at the native write seam, not actual filesystem exhaustion.
    {:ok, writer} = call(:open, [context(c, f, %{write: write})])
    assert_error(append_until_error(writer, f), :storage_unavailable)
    assert_receive {^token, size}
    assert size in 1..65_536
    refute File.exists?(completed(c, writer))
    assert_writer_root_empty(c)
    assert :ok = call(:abort, [writer])
    assert_writer_root_empty(c)
  end

  test "original producer must honor 64KiB chunks and propagate Writer cancellation", c do
    f = fixture(c)
    bad_fold = fn _, acc, emit -> emit.(String.duplicate("x", 65_537), acc) end
    {:ok, writer} = call(:open, [context(c, f, %{original_fold: bad_fold})])
    writer = append_records(writer, f)

    assert_error(
      call(:append_file, [writer, {:original, :asset, uuid(5), uuid(1_005)}, :authenticated]),
      :invalid
    )

    assert :ok = call(:abort, [writer])
    token = make_ref()

    fold = fn _, acc, emit ->
      result = emit.("first", acc)
      send(self(), {token, result})
      result
    end

    {:ok, writer} = call(:open, [context(c, f, %{original_fold: fold})])
    assert :ok = call(:abort, [writer])

    assert_error(
      call(:append_file, [writer, {:original, :asset, uuid(5), uuid(1_005)}, :authenticated])
    )

    refute_receive {^token, _}
    assert_writer_root_empty(c)
  end

  test "capture's original deadline is not restarted by Writer open finish or delivery", c do
    now = :atomics.new(1, signed: true)
    :atomics.put(now, 1, 10)
    f = fixture(c, %{clock: fn -> :atomics.get(now, 1) end})
    :atomics.put(now, 1, f.capture._deadline - 1)
    {:ok, writer} = call(:open, [context(c, f)])
    assert writer.deadline == f.capture._deadline
    writer = writer |> append_records(f) |> append_files(f)
    :atomics.put(now, 1, f.capture._deadline)
    assert_error(call(:finish, [writer]))
    assert :ok = call(:abort, [writer])
    :atomics.put(now, 1, 10)
    fresh = fixture(c, %{clock: fn -> :atomics.get(now, 1) end})
    artifact = materialize(c, fresh)
    :atomics.put(now, 1, fresh.capture._deadline)
    assert_error(call(:entries, [artifact, nil]))
    assert_error(call(:read_chunk, [artifact, "manifest.json", 0]))
    assert :ok = call(:abort, [artifact])
    assert_writer_root_empty(c)
  end

  test "shared capture temporary framing index and duplicate bytes are all accounted", c do
    f = fixture(c)
    {:ok, writer} = call(:open, [context(c, f)])
    initial = writer.accounting
    assert initial.spool_bytes >= f.capture.accounting.spool_bytes
    assert initial.metadata_records >= f.capture.accounting.metadata_records
    writer = append_records(writer, f)
    writer = append_files(writer, f)

    assert writer.accounting.spool_bytes >=
             f.capture.accounting.spool_bytes + temporary_disk_bytes(staging(c, writer), f)

    assert writer.accounting.spool_bytes > initial.spool_bytes
    assert writer.accounting.metadata_records > initial.metadata_records
    assert writer.accounting.spool_bytes <= KnowledgeExport.limits().metadata_bytes
    assert writer.accounting.metadata_records <= KnowledgeExport.limits().metadata_records
    assert writer.accounting.selected_keys <= KnowledgeExport.limits().selected_keys
    {:ok, artifact} = call(:finish, [writer])
    {bytes, _, entries} = inspect_artifact(artifact)
    assert artifact.accounting.manifest_bytes == byte_size(bytes)
    assert artifact.accounting.file_bytes == Enum.sum(Enum.map(entries, & &1["byte_size"]))
    assert artifact.accounting.file_bytes <= 68_719_476_736
    assert artifact.accounting.manifest_bytes <= 1_073_741_824
    assert :ok = call(:abort, [artifact])
  end

  test "fixed exhausted or invalid USED counters fail closed without limit overrides", c do
    # SYNTHETIC used-counter arithmetic only, NOT actual GiB/1M-record exhaustion.
    f = fixture(c)

    for {field, used} <- [
          spool_bytes: 1_073_741_824,
          metadata_records: 1_000_000,
          selected_keys: 100_001,
          file_bytes: 68_719_476_736,
          manifest_bytes: 1_073_741_824
        ] do
      {:ok, writer} = call(:open, [context(c, f)])
      exhausted = %{writer | accounting: Map.put(writer.accounting, field, used)}
      result = append_until_error(exhausted, f)
      assert_error(result)
      refute File.exists?(completed(c, writer))
      assert :ok = call(:abort, [writer])
    end

    for field <- [:spool_bytes, :metadata_records, :file_bytes, :manifest_bytes] do
      {:ok, writer} = call(:open, [context(c, f)])
      malformed = %{writer | accounting: Map.put(writer.accounting, field, -1)}
      assert_error(append_until_error(malformed, f))
      assert :ok = call(:abort, [writer])
    end

    assert_writer_root_empty(c)
  end

  test "temporary canonical Note reassembly has no plaintext exemption from the shared ceiling",
       c do
    # SYNTHETIC remaining-byte arithmetic over a REAL sealed maximum-size Note.
    # The fixed 1GiB limit is unchanged; this does not claim a 1GiB allocation.
    f = fixture(c, %{body: String.duplicate("x", 1_048_576)})
    {:ok, writer} = call(:open, [context(c, f)])
    writer = writer |> append_records(f) |> append_non_note_files(f)

    exhausted = %{
      writer
      | accounting:
          Map.put(writer.accounting, :spool_bytes, 1_073_741_824 - byte_size(f.body) + 1)
    }

    selector = {:note_markdown, uuid(1), uuid(1_001)}
    assert_error(call(:append_file, [exhausted, selector, f.capture.text_refs[selector]]))
    refute File.exists?(completed(c, writer))
    assert :ok = call(:abort, [writer])
    assert_writer_root_empty(c)
  end

  test "all final files reserve room for manifest even at the fixed original ceiling", c do
    {:ok, spool} = Spool.open(spool_context(c))
    size = 68_719_476_736

    {:ok, spool} =
      Spool.append(spool, {:binary_binding, :asset, uuid(5), uuid(1_005)}, asset_binding(5, size))

    version = asset_version(5, size)
    {:ok, spool} = Spool.append(spool, {:metadata, :resources}, resource(version))
    {:ok, spool} = Spool.append(spool, {:metadata, :versions}, version)
    {:ok, capture} = Spool.seal(spool)
    on_exit(fn -> assert :ok = Spool.abort(capture) end)
    f = %{capture: capture, include_tombstones: false, originals: %{}}
    assert f.capture.accounting.original_bytes == 68_719_476_736
    assert_error(call(:open, [context(c, f)]))
    assert_writer_root_empty(c)
  end

  test "native write and public chunk observers remain bounded with a maximum-size Note", c do
    f = fixture(c, %{body: String.duplicate("界", 349_525) <> "x"})
    assert byte_size(f.body) == 1_048_576
    token = make_ref()

    write = fn device, bytes ->
      send(self(), {token, byte_size(bytes)})
      IO.binwrite(device, bytes)
    end

    artifact = materialize(c, f, %{write: write})
    sizes = drain(token)
    assert sizes != []
    assert Enum.all?(sizes, &(&1 in 0..65_536))
    {_, _, entries} = inspect_artifact(artifact)
    entry = Enum.find(entries, &(&1["path"] == path(:note, 1)))
    rendered = read_all(artifact, entry)
    assert String.starts_with?(rendered, f.body)
    assert byte_size(rendered) <= 16_777_216
    assert :erts_debug.flat_size(artifact) < 100_000

    refute inspect(artifact, limit: :infinity, printable_limit: :infinity) =~
             binary_part(f.body, 0, 1_000)

    assert :ok = call(:abort, [artifact])
  end

  test "one Note reconstructs the full 100 distinct fixed typed source descriptions", c do
    f = fixture(c, %{extra_notes: 100, source_count: 100})
    artifact = materialize(c, f)
    {_, manifest, entries} = inspect_artifact(artifact)
    assert length(manifest["attachments"]) == 98
    assert length(manifest["citations"]) == 2

    typed_targets =
      Enum.map(
        manifest["attachments"],
        &{&1["target_kind"], &1["target_resource_id"], &1["target_version_id"]}
      ) ++
        Enum.map(
          manifest["citations"],
          &{"document", &1["source_resource_id"], &1["source_version_id"]}
        )

    assert MapSet.size(MapSet.new(typed_targets)) == 100
    entry = Enum.find(entries, &(&1["path"] == path(:note, 1)))
    rendered = read_all(artifact, entry)

    for n <- 2_000..2_094 do
      assert rendered =~ "#{uuid(n)}--#{uuid(n + 1_000)}.md"
      assert rendered =~ uuid(n + 10_000)
    end

    for id <- [uuid(501), uuid(502), uuid(503), uuid(601), uuid(602)], do: assert(rendered =~ id)
    assert byte_size(rendered) <= 16_777_216
    assert :ok = call(:abort, [artifact])
  end

  test "valid escaped metadata larger than 64KiB is streamed as bounded native writes", c do
    locator = %{
      "version" => 1,
      "kind" => "markdown",
      "heading_path" => List.duplicate(String.duplicate("\u0001", 255), 64)
    }

    f = fixture(c, %{locator: locator})
    assert Enum.any?(f.records.citations, &(byte_size(JSON.encode!(&1)) > 65_536))
    token = make_ref()

    write = fn device, bytes ->
      send(self(), {token, byte_size(bytes)})
      IO.binwrite(device, bytes)
    end

    artifact = materialize(c, f, %{write: write})
    sizes = drain(token)
    assert sizes != []
    assert Enum.all?(sizes, &(&1 in 0..65_536))
    {_, manifest, _} = inspect_artifact(artifact)
    assert Enum.all?(manifest["citations"], &(&1["locator"] == locator))
    assert :ok = call(:abort, [artifact])
  end

  test "entry pages are bounded stable capture-bound and reject arbitrary delivery paths", c do
    f = fixture(c, %{extra_notes: 501})
    artifact = materialize(c, f)
    {:ok, %{entries: first, next_cursor: next}} = call(:entries, [artifact, nil])
    assert length(first) <= 500
    refute is_nil(next)
    {entries, page_sizes} = entry_pages(artifact, nil, [], [])
    assert Enum.all?(page_sizes, &(&1 in 1..500))
    assert length(page_sizes) >= 2
    assert length(entries) == 513
    paths = Enum.map(entries, & &1["path"])
    assert paths == Enum.sort(paths)
    assert length(paths) == MapSet.size(MapSet.new(paths))
    second = materialize(c, fixture(c))

    for cursor <- [
          next |> Map.put(:operation_id, second.operation_id),
          :erlang.term_to_binary(next),
          %{path: c.sentinel},
          Map.put(next, :extra, true)
        ] do
      assert_error(call(:entries, [artifact, cursor]), :invalid)
    end

    for target <- [
          c.sentinel,
          "../neighbor-sentinel",
          "notes/../manifest.json",
          "MANIFEST.JSON",
          "manifest.json\0",
          path(:note, 999),
          :manifest
        ] do
      assert_error(call(:read_chunk, [artifact, target, 0]), :invalid)
    end

    for ordinal <- [-1, 1.0, nil, 1_000_000],
        do: assert_error(call(:read_chunk, [artifact, "manifest.json", ordinal]), :invalid)

    assert :ok = call(:abort, [artifact])
    assert :ok = call(:abort, [second])
  end

  test "abort invalidates open and complete delivery without deleting neighboring operations",
       c do
    f = fixture(c)
    artifact = materialize(c, f)
    {:ok, writer} = call(:open, [context(c, f)])
    assert :ok = call(:abort, [artifact])
    assert :ok = call(:abort, [artifact])
    assert_error(call(:entries, [artifact, nil]))
    assert_error(call(:read_chunk, [artifact, "manifest.json", 0]))
    assert File.dir?(staging(c, writer))
    assert :ok = call(:abort, [writer])
    assert_error(call(:finish, [writer]))
    assert_writer_root_empty(c)
  end

  test "cleanup rejects forged identity and symlink replacement without following foreign paths",
       c do
    f = fixture(c)
    {:ok, writer} = call(:open, [context(c, f)])
    assert_error(call(:abort, [Map.put(writer, :operation_id, "neighbor-sentinel")]))
    directory = staging(c, writer)
    displaced = directory <> "-displaced"
    File.rename!(directory, displaced)
    File.ln_s!(c.roots.backup, directory)
    assert_error(call(:abort, [writer]))
    assert File.read!(c.sentinel) == "neighbor"
    File.rm!(directory)
    File.rename!(displaced, directory)
    assert :ok = call(:abort, [writer])
    assert_writer_root_empty(c)
  end

  # BEGIN sealed-record-iteration test-only additions
  test "metadata indexing sorts each large collection once and exact appends never paginate", c do
    f = fixture(c, %{extra_notes: 501})

    {accounting, counts} =
      with_metadata_work_trace(fn ->
        {:ok, writer} = call(:open, [context(c, f)])

        try do
          final =
            Enum.reduce(@collections, writer, fn collection, current ->
              Enum.reduce(f.records[collection], current, fn record, owned ->
                {:ok, next} = call(:append_manifest_record, [owned, collection, record])
                next
              end)
            end)

          final.accounting
        after
          # Initial/latest descriptors share native phase and the test-owned ETS.
          # Close before trace delivery, counter assertions or restoration can fail.
          assert :ok = call(:abort, [writer])
          assert_writer_root_empty(c)
        end
      end)

    assert counts.page_calls == 0
    assert counts.large_sorts == 2
    assert accounting.metadata_records <= KnowledgeExport.limits().metadata_records
    assert accounting.spool_bytes <= KnowledgeExport.limits().metadata_bytes
  end

  test "capture membership charges deny one byte or record beyond the fixed combined ceiling",
       c do
    f = fixture(c)

    {index_bytes, index_records} =
      Enum.reduce(@collections, {0, 0}, fn collection, totals ->
        Enum.reduce(f.records[collection], totals, fn record, {bytes, records} ->
          key = record_key(collection, record)
          json_key = if is_tuple(key), do: Tuple.to_list(key), else: key

          charge =
            byte_size(JSON.encode!([f.capture.capture_id, Atom.to_string(collection), json_key])) +
              40

          {bytes + charge, records + 1}
        end)
      end)

    # SYNTHETIC remaining USED-counter arithmetic over actual sealed native frames,
    # not a GiB/1M-record allocation, a raised quota or a fabricated read result.
    for {field, used} <- [
          spool_bytes: KnowledgeExport.limits().metadata_bytes - index_bytes + 1,
          metadata_records: KnowledgeExport.limits().metadata_records - index_records + 1
        ] do
      capture = %{f.capture | accounting: Map.put(f.capture.accounting, field, used)}
      assert_error(call(:open, [%{context(c, f) | capture: capture}]), :invalid)
      assert_writer_root_empty(c)

      assert {:ok, %{records: [_ | _]}} =
               Spool.read_page(
                 f.capture,
                 %{capture_id: f.capture.capture_id, collection: :resources, after: nil},
                 500
               )
    end
  end

  defp with_metadata_work_trace(callback) do
    page_mfa = {Spool, :read_page, 3}
    sort_mfa = {Enum, :sort, 1}

    for module <- [Spool, Enum], do: assert({:module, ^module} = Code.ensure_loaded(module))

    caller = self()
    original_flags = :erlang.trace_info(caller, :flags)
    original_tracer = :erlang.trace_info(caller, :tracer)

    original_patterns =
      for mfa <- [page_mfa, sort_mfa], into: %{} do
        {mfa, {:erlang.trace_info(mfa, :traced), :erlang.trace_info(mfa, :match_spec)}}
      end

    assert original_flags == {:flags, []}
    assert original_tracer == {:tracer, []}

    assert Enum.all?(original_patterns, fn {_, state} ->
             state == {{:traced, false}, {:match_spec, false}}
           end)

    token = make_ref()

    tracer =
      spawn_link(fn -> metadata_trace_loop(caller, token, %{page_calls: 0, large_sorts: 0}) end)

    sort_spec = [{[:"$1"], [{:is_list, :"$1"}, {:>=, {:length, :"$1"}, 501}], []}]

    try do
      assert 1 = :erlang.trace_pattern(page_mfa, true, [:local])
      assert 1 = :erlang.trace_pattern(sort_mfa, sort_spec, [:local])
      assert 1 = :erlang.trace(caller, true, [:call, :arity, {:tracer, tracer}])
      result = callback.()
      :erlang.trace(caller, false, [:call, :arity])
      for mfa <- [page_mfa, sort_mfa], do: :erlang.trace_pattern(mfa, false, [:local])
      delivered = :erlang.trace_delivered(caller)
      assert_receive {:trace_delivered, ^caller, ^delivered}, 1_000
      send(tracer, {:finish_metadata_trace, token})
      assert_receive {:metadata_work_counts, ^token, counts}, 1_000
      {result, counts}
    after
      :erlang.trace(caller, false, [:call, :arity])
      for mfa <- [page_mfa, sort_mfa], do: :erlang.trace_pattern(mfa, false, [:local])
      Process.unlink(tracer)
      if Process.alive?(tracer), do: Process.exit(tracer, :kill)
      assert :erlang.trace_info(caller, :flags) == original_flags
      assert :erlang.trace_info(caller, :tracer) == original_tracer

      for {mfa, {pattern, match}} <- original_patterns do
        assert :erlang.trace_info(mfa, :traced) == pattern
        assert :erlang.trace_info(mfa, :match_spec) == match
      end
    end
  end

  defp metadata_trace_loop(caller, token, counts) do
    receive do
      {:trace, ^caller, :call, {Spool, :read_page, 3}} ->
        metadata_trace_loop(caller, token, %{counts | page_calls: counts.page_calls + 1})

      {:trace, ^caller, :call, {Enum, :sort, 1}} ->
        metadata_trace_loop(caller, token, %{counts | large_sorts: counts.large_sorts + 1})

      {:finish_metadata_trace, ^token} ->
        send(caller, {:metadata_work_counts, token, counts})
    end
  end

  # END sealed-record-iteration test-only additions

  # BEGIN full-materialization-repair2 test-only additions
  test "complete native materialization never scans the global fragment or Note source keys", c do
    f = full_materialization_fixture(c)
    {accounting, counts} = with_full_materialization_trace(fn -> traced_materialization(c, f) end)
    assert accounting.file_bytes > 0
    assert counts.large_counts == 0
    assert counts.large_filters == 0
  end

  test "complete native materialization never copies the growing whole file ledger", c do
    f = full_materialization_fixture(c)
    {accounting, counts} = with_full_materialization_trace(fn -> traced_materialization(c, f) end)
    assert accounting.manifest_bytes > 0
    assert counts.ledger_copies == 0
  end

  test "auxiliary identities deny when primary membership alone fits the fixed record ceiling",
       c do
    f = fixture(c)

    primary_records =
      Enum.reduce(@collections, 0, fn collection, n -> n + length(f.records[collection]) end)

    limit = KnowledgeExport.limits().metadata_records
    used = limit - primary_records
    assert used > f.capture.accounting.metadata_records
    assert used + primary_records == limit
    # SYNTHETIC USED-counter arithmetic over small, real sealed native frames.
    # This is not a million-record fixture or a caller-selectable quota.
    capture = %{f.capture | accounting: Map.put(f.capture.accounting, :metadata_records, used)}
    result = call(:open, [%{context(c, f) | capture: capture}])

    case result do
      {:ok, writer} ->
        try do
          assert writer.accounting.metadata_records == limit
        after
          assert :ok = call(:abort, [writer])
          assert_writer_root_empty(c)
        end

      {:error, %Error{}} ->
        assert_writer_root_empty(c)
    end

    first = hd(f.records.fragments)

    assert {:ok, ^first} =
             Spool.read_metadata(f.capture, :fragments, record_key(:fragments, first))

    assert_error(result, :invalid)
  end

  test "sealed historical fragment identity ambiguity still denies only at citation closure", c do
    f = prepare_fixture(c, %{})
    [original] = Enum.filter(f.records.fragments, &(&1["resource_id"] == uuid(13)))
    duplicate = %{original | "ordinal" => 1}
    assert duplicate["id"] == original["id"]
    refute record_key(:fragments, duplicate) == record_key(:fragments, original)
    assert duplicate["extracted_path"] == nil
    assert duplicate["start_byte"] == nil
    assert duplicate["byte_size"] == nil
    assert {:ok, ^duplicate} = KnowledgeExportManifest.record(:fragments, duplicate)
    {:ok, spool} = Spool.append(f.spool, {:metadata, :fragments}, duplicate)
    f = %{f | spool: spool, records: %{f.records | fragments: f.records.fragments ++ [duplicate]}}
    f = seal_full_fixture(f)

    assert {:ok, ^duplicate} =
             Spool.read_metadata(f.capture, :fragments, record_key(:fragments, duplicate))

    {:ok, writer} = call(:open, [context(c, f)])

    try do
      current = writer |> append_known_records(f) |> append_files(f)
      assert_error(call(:finish, [current]), :integrity_failure)
      refute File.exists?(completed(c, writer))
    after
      assert :ok = call(:abort, [writer])
      assert_writer_root_empty(c)
    end
  end

  test "already witnessed Document directory prefixes reject a foreign replacement inode", c do
    f = fixture(c)

    for prefix <- ["documents", "documents/originals", "documents/extracted"] do
      {:ok, writer} = call(:open, [context(c, f)])
      current = writer |> append_known_records(f) |> append_files(f)
      directory = Path.join(staging(c, writer), prefix)
      original = native_identity(directory)
      assert original.type == :directory
      assert_mode(directory, 0o700)

      assert [{{:directory, ^prefix}, witnessed}] =
               :ets.lookup(writer._ledger, {:directory, prefix})

      assert witnessed == {original.major_device, original.inode, original.uid, original.gid}
      # Keep the witnessed tree outside recursive operation cleanup until restored.
      displaced = Path.join(c.roots.backup, "owned-document-prefix-" <> writer.operation_id)
      File.rename!(directory, displaced)

      try do
        File.mkdir!(directory)
        File.chmod!(directory, 0o700)
        sentinel = Path.join(directory, "foreign-sentinel")
        File.write!(sentinel, "foreign-document-prefix")
        foreign = native_identity(directory)
        assert foreign.type == :directory
        assert foreign.uid == original.uid
        assert_mode(directory, 0o700)
        refute foreign.inode == original.inode
        assert_error(call(:finish, [current]))
        assert native_identity(directory) == foreign
        assert File.read!(sentinel) == "foreign-document-prefix"
        assert native_identity(displaced) == original
        assert_error(call(:abort, [writer]))
        assert File.read!(sentinel) == "foreign-document-prefix"
        assert File.read!(c.sentinel) == "neighbor"
      after
        # Restore the witnessed owned inode before genuine recursive cleanup.
        File.rm!(Path.join(directory, "foreign-sentinel"))
        File.rmdir!(directory)
        File.rename!(displaced, directory)
        assert native_identity(directory) == original
        assert :ok = call(:abort, [writer])
        assert_writer_root_empty(c)
      end
    end
  end

  defp full_materialization_fixture(c) do
    prepared = prepare_fixture(c, %{})
    document_numbers = Enum.to_list(30_000..30_002)

    {prepared, extracted} =
      Enum.reduce(document_numbers, {prepared, %{}}, fn n, {f, extracted} ->
        {fragments, _offset} =
          Enum.map_reduce(0..42, 0, fn ordinal, offset ->
            text = "界😀 canonical fragment #{ordinal}\n"

            locator = %{
              "version" => 1,
              "kind" => "text",
              "start_line" => ordinal + 1,
              "end_line" => ordinal + 1
            }

            {:ok, canonical} =
              DocumentFragment.new(%{
                resource_id: uuid(n),
                resource_version_id: uuid(n + 1_000),
                owner_scope_id: uuid(4_000),
                classification: :private,
                ordinal: ordinal,
                text: text,
                locator: locator
              })

            record = fragment(n, ordinal, text, offset, locator)
            assert record["id"] == canonical.fragment_id
            assert record["digest"] == Base.encode16(canonical.digest, case: :lower)
            assert {:ok, ^record} = KnowledgeExportManifest.record(:fragments, record)
            {{record, text}, offset + byte_size(text)}
          end)

        bytes = Enum.map_join(fragments, "", fn {_, text} -> text end)
        # Explicitly synthetic original-fold bytes; no live custody claim.
        originals =
          Map.put(
            f.originals,
            {:original, :document, uuid(n), uuid(n + 1_000)},
            "synthetic original #{n}\n"
          )

        version =
          document_version(n, "ready", originals) |> Map.put("extracted_digest", sha(bytes))

        records = %{
          f.records
          | resources: f.records.resources ++ [resource(version)],
            versions: f.records.versions ++ [version],
            fragments: f.records.fragments ++ Enum.map(fragments, &elem(&1, 0))
        }

        spool = append_fixture_metadata(f.spool, :resources, [resource(version)])
        spool = append_fixture_metadata(spool, :versions, [version])
        spool = append_fixture_metadata(spool, :fragments, Enum.map(fragments, &elem(&1, 0)))

        spool =
          Enum.reduce(fragments, spool, fn {record, text}, acc ->
            spool_append_chunks(acc, fragment_selector(record), text)
          end)

        {%{f | spool: spool, records: records, originals: originals},
         Map.put(extracted, path(:extracted, n), bytes)}
      end)

    {prepared, note_inputs} =
      Enum.reduce(
        20_000..20_128,
        {prepared, %{{uuid(1), uuid(1_001)} => {prepared.body, descriptions()}}},
        fn n, {f, inputs} ->
          document = Enum.at(document_numbers, rem(n - 20_000, 3))
          body = "Note #{n} 界😀\n"

          {:ok, attachment} =
            NoteAttachmentReference.new(%{
              attachment_id: uuid(n + 40_000),
              target_resource_id: uuid(5),
              target_resource_version_id: uuid(1_005),
              target_kind: :asset,
              role: :source,
              label: "typed attachment #{n}"
            })

          locator = %{"version" => 1, "kind" => "text", "start_line" => 1, "end_line" => 1}

          {:ok, citation} =
            NoteCitationReference.new(%{
              citation_id: uuid(n + 50_000),
              source_resource_id: uuid(document),
              source_resource_version_id: uuid(document + 1_000),
              fragment_id: fragment_id(document, 0, "界😀 canonical fragment 0\n", locator),
              locator: locator
            })

          descriptors = %{
            attachments: [
              %{reference: attachment, source: source(5, :asset, false), href: href(5, :asset)}
            ],
            citations: [
              %{
                reference: citation,
                source: source(document, :document, false),
                href: href(document, :document)
              }
            ]
          }

          owner = %{"note_resource_id" => uuid(n), "note_version_id" => uuid(n + 1_000)}
          a = attachment_record(hd(descriptors.attachments), 0) |> Map.merge(owner)
          citation_record = citation_record(hd(descriptors.citations), 0) |> Map.merge(owner)
          version = note_version(n, body)

          records = %{
            f.records
            | resources: f.records.resources ++ [resource(version)],
              versions: f.records.versions ++ [version],
              attachments: f.records.attachments ++ [a],
              citations: f.records.citations ++ [citation_record]
          }

          spool = append_fixture_metadata(f.spool, :resources, [resource(version)])
          spool = append_fixture_metadata(spool, :versions, [version])
          spool = append_fixture_metadata(spool, :attachments, [a])
          spool = append_fixture_metadata(spool, :citations, [citation_record])
          spool = spool_append_chunks(spool, {:note_markdown, uuid(n), uuid(n + 1_000)}, body)

          {:ok, spool} =
            Spool.append(spool, {:render_descriptions, uuid(n), uuid(n + 1_000)}, descriptors)

          {%{f | spool: spool, records: records},
           Map.put(inputs, {uuid(n), uuid(n + 1_000)}, {body, descriptors})}
        end
      )

    f = seal_full_fixture(prepared)
    versions = Map.new(f.records.versions, &{{&1["resource_id"], &1["version_id"]}, &1})

    expected =
      Enum.reduce(
        f.originals,
        Map.put(extracted, path(:extracted, 2), "界😀tail\n"),
        fn {{:original, _, r, v}, bytes}, acc ->
          Map.put(acc, versions[{r, v}]["original_path"], bytes)
        end
      )

    expected =
      Enum.reduce(note_inputs, expected, fn {{r, v}, {body, descriptors}}, acc ->
        files =
          Enum.reduce(descriptors.attachments ++ descriptors.citations, %{}, fn d, files ->
            s = d.source
            version = versions[{s.resource_id, s.resource_version_id}]
            availability = version["availability"]

            target_path =
              case s.kind do
                :note -> version["body_path"]
                :asset -> version["original_path"]
                :document -> version["extracted_path"] || version["original_path"]
              end

            reason =
              case availability do
                "included" -> nil
                "metadata_only_deleted" -> "Deleted source"
                "metadata_only_unselected" -> "Unselected historical metadata"
              end

            Map.put(files, {s.kind, s.resource_id, s.resource_version_id}, %{
              availability: availability,
              path: target_path,
              reason: reason
            })
          end)

        assert {:ok, rendered} = NoteMarkdownSources.render_portable(body, descriptors, files)
        Map.put(acc, versions[{r, v}]["body_path"], rendered)
      end)

    # All constructors, expected rendering and native capture proof precede tracing.
    assert length(note_inputs |> Map.keys()) == 130
    assert length(f.records.fragments) == 132

    for collection <- @collections, record <- f.records[collection] do
      assert {:ok, ^record} =
               Spool.read_metadata(f.capture, collection, record_key(collection, record))
    end

    for {_, ref} <- f.capture.text_refs do
      assert {:ok, bytes} = Spool.read_chunk(f.capture, ref, 0)
      assert byte_size(bytes) == ref.byte_size
      assert sha(bytes) == ref.sha256
    end

    Map.put(f, :expected_files, expected)
  end

  defp append_fixture_metadata(spool, collection, records) do
    Enum.reduce(records, spool, fn record, acc ->
      {:ok, next} = Spool.append(acc, {:metadata, collection}, record)
      next
    end)
  end

  defp seal_full_fixture(f) do
    {:ok, capture} = Spool.seal(f.spool)
    on_exit(fn -> assert :ok = Spool.abort(capture) end)
    f |> Map.delete(:spool) |> Map.put(:capture, capture)
  end

  defp append_known_records(writer, f) do
    Enum.reduce(@collections, writer, fn collection, current ->
      Enum.reduce(f.records[collection], current, fn record, owned ->
        {:ok, next} = call(:append_manifest_record, [owned, collection, record])
        next
      end)
    end)
  end

  defp traced_materialization(c, f) do
    {:ok, writer} = call(:open, [context(c, f)])

    try do
      current = writer |> append_known_records(f) |> append_files(f)
      {:ok, artifact} = call(:finish, [current])
      # Known descriptor/path reads avoid entries/2 and inspect_artifact/1 filters.
      manifest_bytes = read_all(artifact, artifact.manifest)
      assert byte_size(manifest_bytes) == artifact.manifest["byte_size"]
      assert sha(manifest_bytes) == artifact.manifest["sha256"]
      assert File.read!(Path.join(completed(c, artifact), "manifest.json")) == manifest_bytes
      manifest = JSON.decode!(manifest_bytes)
      assert manifest["format"] == "singularity.portable-knowledge"
      assert manifest["version"] == 1
      assert_metadata_equal(f, manifest)
      assert length(manifest["files"]) == map_size(f.expected_files)

      assert MapSet.new(Enum.map(manifest["files"], & &1["path"])) ==
               MapSet.new(Map.keys(f.expected_files))

      for entry <- manifest["files"] do
        expected = Map.fetch!(f.expected_files, entry["path"])
        assert entry["byte_size"] == byte_size(expected)
        assert entry["sha256"] == sha(expected)
        assert read_all(artifact, entry) == expected
        assert File.read!(Path.join(completed(c, artifact), entry["path"])) == expected
      end

      assert artifact.accounting.file_bytes ==
               byte_size(manifest_bytes) +
                 Enum.reduce(f.expected_files, 0, fn {_, bytes}, n -> n + byte_size(bytes) end)

      artifact.accounting
    after
      # Shared phase/location/ledger permits initial descriptor cleanup after finish.
      # The live test PID owns ETS; abort must precede every trace barrier/assertion.
      assert :ok = call(:abort, [writer])
      assert_writer_root_empty(c)
    end
  end

  defp with_full_materialization_trace(callback) do
    mfas = [{Enum, :count, 2}, {Enum, :filter, 2}, {:ets, :tab2list, 1}]

    for {module, function, arity} <- mfas do
      assert {:module, ^module} = Code.ensure_loaded(module)
      assert function_exported?(module, function, arity)
    end

    caller = self()
    flags = :erlang.trace_info(caller, :flags)
    tracer_state = :erlang.trace_info(caller, :tracer)

    patterns =
      Map.new(mfas, fn mfa ->
        {mfa, {:erlang.trace_info(mfa, :traced), :erlang.trace_info(mfa, :match_spec)}}
      end)

    assert flags == {:flags, []}
    assert tracer_state == {:tracer, []}

    assert Enum.all?(patterns, fn {_, state} ->
             state == {{:traced, false}, {:match_spec, false}}
           end)

    token = make_ref()

    tracer =
      spawn_link(fn ->
        full_materialization_trace_loop(caller, token, %{
          large_counts: 0,
          large_filters: 0,
          ledger_copies: 0
        })
      end)

    large_spec = [{[:"$1", :"$2"], [{:is_list, :"$1"}, {:>=, {:length, :"$1"}, 129}], []}]

    try do
      assert 1 = :erlang.trace_pattern({Enum, :count, 2}, large_spec, [:local])
      assert 1 = :erlang.trace_pattern({Enum, :filter, 2}, large_spec, [:local])
      assert 1 = :erlang.trace_pattern({:ets, :tab2list, 1}, true, [:local])
      assert 1 = :erlang.trace(caller, true, [:call, :arity, {:tracer, tracer}])
      result = callback.()
      :erlang.trace(caller, false, [:call, :arity])
      for mfa <- mfas, do: :erlang.trace_pattern(mfa, false, [:local])
      delivered = :erlang.trace_delivered(caller)
      assert_receive {:trace_delivered, ^caller, ^delivered}, 1_000
      send(tracer, {:finish_full_materialization_trace, token})
      assert_receive {:full_materialization_counts, ^token, counts}, 1_000
      {result, counts}
    after
      :erlang.trace(caller, false, [:call, :arity])
      for mfa <- mfas, do: :erlang.trace_pattern(mfa, false, [:local])
      Process.unlink(tracer)
      if Process.alive?(tracer), do: Process.exit(tracer, :kill)
      assert :erlang.trace_info(caller, :flags) == flags
      assert :erlang.trace_info(caller, :tracer) == tracer_state

      for {mfa, {pattern, match}} <- patterns do
        assert :erlang.trace_info(mfa, :traced) == pattern
        assert :erlang.trace_info(mfa, :match_spec) == match
      end
    end
  end

  defp full_materialization_trace_loop(caller, token, counts) do
    receive do
      {:trace, ^caller, :call, {Enum, :count, 2}} ->
        full_materialization_trace_loop(caller, token, %{
          counts
          | large_counts: counts.large_counts + 1
        })

      {:trace, ^caller, :call, {Enum, :filter, 2}} ->
        full_materialization_trace_loop(caller, token, %{
          counts
          | large_filters: counts.large_filters + 1
        })

      {:trace, ^caller, :call, {:ets, :tab2list, 1}} ->
        full_materialization_trace_loop(caller, token, %{
          counts
          | ledger_copies: counts.ledger_copies + 1
        })

      {:finish_full_materialization_trace, ^token} ->
        send(caller, {:full_materialization_counts, token, counts})
    end
  end

  # END full-materialization-repair2 test-only additions

  defp call(function, args) do
    assert Code.ensure_loaded?(@writer), "missing concrete portable Writer"
    assert function_exported?(@writer, function, length(args))
    apply(@writer, function, args)
  end

  defp native_identity(path),
    do:
      File.lstat!(path)
      |> Map.from_struct()
      |> Map.take([:major_device, :inode, :uid, :gid, :type, :mode])

  defp context(c, f, overrides \\ %{}) do
    Map.merge(
      %{
        root: c.roots.writer,
        storage_root: c.roots.ciphertext,
        backup_root: c.roots.backup,
        capture: f.capture,
        options: %{include_tombstones: f.include_tombstones},
        original_fold: fn selector, acc, emit ->
          fold_bytes(Map.fetch!(f.originals, selector), acc, emit)
        end
      },
      overrides
    )
  end

  defp spool_context(c),
    do: %{root: c.roots.capture, storage_root: c.roots.ciphertext, backup_root: c.roots.backup}

  defp fixture(c, options \\ %{}) do
    prepared = prepare_fixture(c, options)
    {:ok, capture} = Spool.seal(prepared.spool)
    on_exit(fn -> assert :ok = Spool.abort(capture) end)
    prepared |> Map.delete(:spool) |> Map.put(:capture, capture)
  end

  defp prepare_fixture(c, options) do
    body = Map.get(options, :body, @body)
    clock = Map.get(options, :clock, fn -> Map.get(options, :now, 10) end)
    {:ok, spool} = Spool.open(Map.put(spool_context(c), :clock, clock))

    originals = %{
      {:original, :document, uuid(2), uuid(1_002)} => <<0, 255, 1, 2, 3, 4>>,
      {:original, :document, uuid(3), uuid(1_003)} => "Unicode 原文 😀",
      {:original, :document, uuid(4), uuid(1_004)} => "failed original",
      {:original, :document, uuid(8), uuid(1_008)} => "unsupported original",
      {:original, :document, uuid(9), uuid(1_009)} => "extracting original",
      {:original, :document, uuid(10), uuid(1_010)} => "# markdown original\n",
      {:original, :document, uuid(11), uuid(1_011)} => "%PDF-1.7\noriginal",
      {:original, :asset, uuid(5), uuid(1_005)} => <<0, 255, 1, 2, 3, 4>>,
      {:original, :asset, uuid(12), uuid(1_012)} => ""
    }

    locator = Map.get(options, :locator, locator_map())

    descriptions =
      if Map.get(options, :source_count) == 100,
        do: hundred_sources(),
        else: descriptions(locator)

    fragments = [
      fragment(2, 0, "界😀", 0, locator)
      |> Map.put("byte_size", Map.get(options, :first_fragment_size, 7)),
      fragment(2, 1, "tail\n", Map.get(options, :fragment_offset, 7), locator)
      |> Map.put("digest", Map.get(options, :fragment_digest, sha("tail\n")))
      |> Map.put("id", Map.get(options, :fragment_id, fragment_id(2, 1, "tail\n", locator))),
      %{
        fragment(13, 0, "deleted fragment", 0, locator)
        | "extracted_path" => nil,
          "start_byte" => nil,
          "byte_size" => nil
      }
    ]

    versions = [
      note_version(1, body)
      |> Map.put("body_digest", Map.get(options, :note_digest, sha(body)))
      |> Map.put("parent_version_id", uuid(1_007)),
      document_version(2, "ready", originals)
      |> Map.put("extracted_digest", Map.get(options, :extracted_digest, sha("界😀tail\n"))),
      document_version(3, "pending", originals),
      document_version(4, "failed", originals),
      asset_version(5, Map.get(options, :asset_size, 6)),
      metadata_version(6, "note", "metadata_only_deleted"),
      metadata_version(7, "note", "metadata_only_unselected") |> Map.put("resource_id", uuid(1)),
      document_version(8, "unsupported", originals),
      document_version(9, "extracting", originals),
      document_version(10, "pending", originals, "text/markdown"),
      document_version(11, "pending", originals, "application/pdf"),
      asset_version(12, 0),
      metadata_version(13, "document", "metadata_only_deleted"),
      metadata_version(14, "asset", "metadata_only_unselected")
    ]

    resources = versions |> Enum.map(&resource/1) |> Enum.uniq_by(& &1["id"])

    attachments =
      Enum.with_index(descriptions.attachments, fn d, ordinal -> attachment_record(d, ordinal) end)

    citations =
      Enum.with_index(descriptions.citations, fn d, ordinal -> citation_record(d, ordinal) end)

    records = %{
      resources: resources,
      versions: versions,
      fragments: fragments,
      tags: [%{"id" => uuid(701), "display_value" => "Tag", "normalized_key" => "tag"}],
      tag_assignments: [%{"resource_id" => uuid(1), "tag_id" => uuid(701)}],
      relationships: [
        %{
          "id" => uuid(801),
          "source_resource_id" => uuid(1),
          "target_resource_id" => uuid(14),
          "target_version_id" => uuid(1_014),
          "type" => "references"
        }
      ],
      attachments: attachments,
      citations: citations
    }

    extra = Map.get(options, :extra_notes, 0)
    extra_numbers = if extra == 0, do: [], else: Enum.to_list(2_000..(1_999 + extra))

    records =
      Enum.reduce(extra_numbers, records, fn n, acc ->
        v = note_version(n, "")
        %{acc | resources: [resource(v) | acc.resources], versions: [v | acc.versions]}
      end)

    spool =
      Enum.reduce([5, 12], spool, fn n, acc ->
        size = if n == 5, do: Map.get(options, :asset_size, 6), else: 0

        {:ok, next} =
          Spool.append(
            acc,
            {:binary_binding, :asset, uuid(n), uuid(n + 1_000)},
            asset_binding(n, size)
          )

        next
      end)

    spool =
      Enum.reduce(@collections, spool, fn collection, acc ->
        list = records[collection]
        list = if Map.get(options, :reverse, false), do: Enum.reverse(list), else: list

        Enum.reduce(list, acc, fn record, current ->
          {:ok, next} = Spool.append(current, {:metadata, collection}, record)
          next
        end)
      end)

    spool = spool_append_chunks(spool, {:note_markdown, uuid(1), uuid(1_001)}, body)
    {:ok, spool} = Spool.append(spool, {:render_descriptions, uuid(1), uuid(1_001)}, descriptions)

    spool =
      Enum.reduce(extra_numbers, spool, fn n, acc ->
        {:ok, acc} = Spool.append(acc, {:note_markdown, uuid(n), uuid(n + 1_000)}, "")

        {:ok, acc} =
          Spool.append(acc, {:render_descriptions, uuid(n), uuid(n + 1_000)}, %{
            attachments: [],
            citations: []
          })

        acc
      end)

    spool = spool_append_chunks(spool, fragment_selector(hd(fragments)), "界😀")
    spool = spool_append_chunks(spool, fragment_selector(Enum.at(fragments, 1)), "tail\n")

    %{
      spool: spool,
      records: records,
      originals: originals,
      body: body,
      include_tombstones: Map.get(options, :include_tombstones, true)
    }
  end

  defp blank_version(n, kind, availability) do
    ~w(resource_id version_id revision kind inserted_at availability body_path original_path extracted_path body_digest original_digest original_byte_size extracted_digest media_type state extraction_adapter extraction_format parent_version_id merge_parent_version_id)
    |> Map.new(&{&1, nil})
    |> Map.merge(%{
      "resource_id" => uuid(n),
      "version_id" => uuid(n + 1_000),
      "revision" => 0,
      "kind" => kind,
      "inserted_at" => @time,
      "availability" => availability
    })
  end

  defp note_version(n, body),
    do:
      blank_version(n, "note", "included")
      |> Map.merge(%{"body_path" => path(:note, n), "body_digest" => sha(body)})

  defp asset_version(n, size),
    do:
      blank_version(n, "asset", "included")
      |> Map.merge(%{
        "original_path" => path(:asset, n),
        "original_byte_size" => size,
        "media_type" => "application/octet-stream"
      })

  defp metadata_version(n, kind, availability), do: blank_version(n, kind, availability)

  defp document_version(n, state, originals, media \\ "text/plain") do
    bytes = Map.fetch!(originals, {:original, :document, uuid(n), uuid(n + 1_000)})

    blank_version(n, "document", "included")
    |> Map.merge(%{
      "original_path" => path(:document, n, media),
      "original_digest" => sha(bytes),
      "original_byte_size" => byte_size(bytes),
      "media_type" => media,
      "state" => state
    })
    |> Map.merge(
      if state == "pending",
        do: %{},
        else: %{"extraction_adapter" => "plain_text", "extraction_format" => 1}
    )
    |> Map.merge(
      if state == "ready",
        do: %{"extracted_path" => path(:extracted, n), "extracted_digest" => sha("界😀tail\n")},
        else: %{}
    )
  end

  defp resource(v) do
    deleted? = v["availability"] == "metadata_only_deleted"

    reason =
      cond do
        v["availability"] == "metadata_only_unselected" -> "relationship_endpoint"
        v["kind"] == "asset" or deleted? -> "source"
        true -> "head"
      end

    %{
      "id" => v["resource_id"],
      "kind" => v["kind"],
      "title" => "Duplicate [title] 界",
      "current_version_id" => v["version_id"],
      "deleted_at" => if(deleted?, do: @time, else: nil),
      "selection_reason" => reason
    }
  end

  defp fragment(n, ordinal, text, offset, locator) do
    %{
      "id" => fragment_id(n, ordinal, text, locator),
      "resource_id" => uuid(n),
      "version_id" => uuid(n + 1_000),
      "ordinal" => ordinal,
      "digest" => sha(text),
      "locator" => locator,
      "extracted_path" => path(:extracted, n),
      "start_byte" => offset,
      "byte_size" => byte_size(text)
    }
  end

  defp descriptions(locator \\ locator_map()) do
    attachments =
      Enum.map([{5, :asset, false, 501}, {6, :note, true, 502}, {12, :asset, false, 503}], fn {n,
                                                                                               kind,
                                                                                               deleted?,
                                                                                               id} ->
        {:ok, reference} =
          NoteAttachmentReference.new(%{
            attachment_id: uuid(id),
            target_resource_id: uuid(n),
            target_resource_version_id: uuid(n + 1_000),
            target_kind: kind,
            role: :source,
            label: "label [safe]"
          })

        %{reference: reference, source: source(n, kind, deleted?), href: href(n, kind)}
      end)

    citations =
      Enum.map([{2, false, 601, "界😀"}, {13, true, 602, "deleted fragment"}], fn {n, deleted?, id,
                                                                                 text} ->
        {:ok, reference} =
          NoteCitationReference.new(%{
            citation_id: uuid(id),
            source_resource_id: uuid(n),
            source_resource_version_id: uuid(n + 1_000),
            fragment_id: fragment_id(n, 0, text, locator),
            locator: locator
          })

        %{reference: reference, source: source(n, :document, deleted?), href: href(n, :document)}
      end)

    %{attachments: attachments, citations: citations}
  end

  defp hundred_sources do
    base = descriptions()

    attachments =
      Enum.map(2_000..2_094, fn n ->
        {:ok, reference} =
          NoteAttachmentReference.new(%{
            attachment_id: uuid(n + 10_000),
            target_resource_id: uuid(n),
            target_resource_version_id: uuid(n + 1_000),
            target_kind: :note
          })

        %{reference: reference, source: source(n, :note, false), href: href(n, :note)}
      end)

    %{attachments: base.attachments ++ attachments, citations: base.citations}
  end

  defp source(n, kind, deleted?),
    do: %{
      kind: kind,
      resource_id: uuid(n),
      resource_version_id: uuid(n + 1_000),
      title: "Duplicate [title] 界",
      deleted?: deleted?
    }

  defp href(n, kind),
    do:
      "sources/#{kind}-#{uuid(n)}-#{uuid(n + 1_000)}.#{if kind == :asset, do: "bin", else: if(kind == :note, do: "md", else: "txt")}"

  defp locator_map, do: %{"version" => 1, "kind" => "text", "start_line" => 1, "end_line" => 2}

  defp fragment_id(n, ordinal, text, locator \\ locator_map()),
    do: DocumentFragment.id(uuid(n + 1_000), locator, ordinal, :crypto.hash(:sha256, text))

  defp attachment_record(d, ordinal) do
    r = d.reference

    %{
      "note_resource_id" => uuid(1),
      "note_version_id" => uuid(1_001),
      "id" => r.attachment_id,
      "ordinal" => ordinal,
      "target_resource_id" => r.target_resource_id,
      "target_version_id" => r.target_resource_version_id,
      "target_kind" => Atom.to_string(r.target_kind),
      "role" => "source",
      "label" => r.label
    }
  end

  defp citation_record(d, ordinal) do
    r = d.reference

    %{
      "note_resource_id" => uuid(1),
      "note_version_id" => uuid(1_001),
      "id" => r.citation_id,
      "ordinal" => ordinal,
      "source_resource_id" => r.source_resource_id,
      "source_version_id" => r.source_resource_version_id,
      "fragment_id" => r.fragment_id,
      "locator" => SourceLocator.to_map(r.locator)
    }
  end

  defp asset_binding(n, size) do
    resource = uuid(n)

    %{
      "kind" => "asset",
      "resource_id" => resource,
      "version_id" => uuid(n + 1_000),
      "asset_id" => uuid(n + 2_000),
      "object_id" => uuid(n + 3_000),
      "owner_scope_id" => uuid(4_000),
      "classification" => "private",
      "key_domain_id" => uuid(5_000),
      "domain_key_version_id" => uuid(6_000),
      "domain_key_generation" => 1,
      "object_generation" => 1,
      "lookup_digest" => sha("PRIVATE_LOOKUP_#{resource}"),
      "ciphertext_hash" => sha("PRIVATE_CIPHERTEXT_#{resource}"),
      "plaintext_byte_size" => size,
      "ciphertext_byte_size" => size + 134,
      "storage_ref" => uuid(n + 3_000),
      "format_version" => 1,
      "plaintext_sha256" => nil
    }
  end

  defp materialize(c, f, overrides \\ %{}) do
    {:ok, writer} = call(:open, [context(c, f, overrides)])
    writer = writer |> append_records(f) |> append_files(f)
    {:ok, artifact} = call(:finish, [writer])
    artifact
  end

  defp append_records(writer, f, omitted \\ []) do
    Enum.reduce(@collections -- omitted, writer, fn collection, acc ->
      read_capture_pages(f.capture, collection, nil, acc, fn record, current ->
        {:ok, next} = call(:append_manifest_record, [current, collection, record])
        next
      end)
    end)
  end

  defp read_capture_pages(capture, collection, cursor, acc, consume) do
    cursor = cursor || %{capture_id: capture.capture_id, collection: collection, after: nil}
    {:ok, %{records: records, next_cursor: next}} = Spool.read_page(capture, cursor, 500)
    assert length(records) <= 500
    acc = Enum.reduce(records, acc, consume)
    if is_nil(next), do: acc, else: read_capture_pages(capture, collection, next, acc, consume)
  end

  defp captured_records(capture, collection) do
    read_capture_pages(capture, collection, nil, [], fn record, acc -> [record | acc] end)
  end

  defp assert_sealed_fragment_denied(c, options, field, ordinal \\ 1) do
    f = fixture(c, options)

    [record] =
      Enum.filter(
        captured_records(f.capture, :fragments),
        &(&1["resource_id"] == uuid(2) and &1["ordinal"] == ordinal)
      )

    text = if ordinal == 0, do: "界😀", else: "tail\n"
    canonical = fragment(2, ordinal, text, if(ordinal == 0, do: 0, else: 7), locator_map())
    refute record[field] == canonical[field]
    assert Map.delete(record, field) == Map.delete(canonical, field)
    assert {:ok, ^record} = KnowledgeExportManifest.record(:fragments, record)
    selector = fragment_selector(record)
    reference = Map.fetch!(f.capture.text_refs, selector)
    assert f.capture.sealed? === true
    assert reference.selector == selector
    assert reference.sha256 == sha(text)
    assert reference.byte_size == byte_size(text)
    assert {:ok, ^text} = Spool.read_chunk(f.capture, reference, 0)

    [version] =
      Enum.filter(captured_records(f.capture, :versions), &(&1["version_id"] == uuid(1_002)))

    assert version["extracted_digest"] == sha("界😀tail\n")

    {:ok, writer} = call(:open, [context(c, f)])
    assert_error(append_until_error(writer, f), :integrity_failure)
    assert :ok = call(:abort, [writer])
    assert_writer_root_empty(c)
  end

  defp append_files(writer, f) do
    writer = append_non_note_files(writer, f)

    Enum.reduce(Enum.sort(f.capture.text_refs), writer, fn
      {{:note_markdown, _, _} = selector, reference}, acc ->
        {:ok, next} = call(:append_file, [acc, selector, reference])
        next

      _, acc ->
        acc
    end)
  end

  defp append_non_note_files(writer, f) do
    writer =
      Enum.reduce(Enum.sort(Map.keys(f.originals)), writer, fn selector, acc ->
        {:ok, next} = call(:append_file, [acc, selector, :authenticated])
        next
      end)

    Enum.reduce(Enum.sort(f.capture.text_refs), writer, fn
      {{:fragment_text, _, _, _, _} = selector, reference}, acc ->
        {:ok, next} = call(:append_file, [acc, selector, reference])
        next

      _, acc ->
        acc
    end)
  end

  defp append_until_error(writer, f) do
    operations =
      Enum.flat_map(@collections, fn collection ->
        Enum.map(f.records[collection], &{:append_manifest_record, [collection, &1]})
      end)

    operations =
      operations ++
        Enum.map(Enum.sort(Map.keys(f.originals)), &{:append_file, [&1, :authenticated]}) ++
        Enum.map(Enum.sort(f.capture.text_refs), fn {selector, ref} ->
          {:append_file, [selector, ref]}
        end) ++ [{:finish, []}]

    Enum.reduce_while(operations, {:ok, writer}, fn {function, args}, {:ok, current} ->
      case call(function, [current | args]) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp spool_append_chunks(spool, selector, bytes) do
    chunks = chunks(bytes)

    Enum.reduce(chunks, spool, fn chunk, acc ->
      {:ok, next} = Spool.append(acc, selector, chunk)
      next
    end)
  end

  defp fold_bytes(bytes, acc, emit) do
    Enum.reduce_while(chunks(bytes), {:ok, acc}, fn chunk, {:ok, current} ->
      case emit.(chunk, current) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp chunks(<<>>), do: [""]
  defp chunks(bytes) when byte_size(bytes) <= 65_536, do: [bytes]
  defp chunks(<<chunk::binary-size(65_536), rest::binary>>), do: [chunk | chunks(rest)]

  defp entry_pages(artifact, cursor, acc, sizes) do
    {:ok, %{entries: entries, next_cursor: next}} = call(:entries, [artifact, cursor])
    assert length(entries) <= 500

    if is_nil(next),
      do: {acc ++ entries, sizes ++ [length(entries)]},
      else: entry_pages(artifact, next, acc ++ entries, sizes ++ [length(entries)])
  end

  defp inspect_artifact(artifact) do
    {entries, _} = entry_pages(artifact, nil, [], [])
    [entry] = Enum.filter(entries, &(&1["path"] == "manifest.json"))
    bytes = read_all(artifact, entry)
    {bytes, JSON.decode!(bytes), entries}
  end

  defp read_all(artifact, entry) do
    # Bounded fixture oracle only; production Writer must never collect the corpus.
    count = max(1, div(entry["byte_size"] + 65_535, 65_536))

    Enum.map_join(0..(count - 1), "", fn ordinal ->
      {:ok, chunk} = call(:read_chunk, [artifact, entry["path"], ordinal])
      assert byte_size(chunk) <= 65_536
      chunk
    end)
  end

  defp assert_metadata_equal(f, manifest) do
    for collection <- @collections do
      expected =
        Enum.map(f.records[collection], fn record ->
          if collection == :versions and record["kind"] == "asset" and
               record["availability"] == "included" do
            selector = {:original, :asset, record["resource_id"], record["version_id"]}
            Map.put(record, "original_digest", sha(Map.fetch!(f.originals, selector)))
          else
            record
          end
        end)

      assert Enum.sort(expected) == Enum.sort(manifest[Atom.to_string(collection)])
    end
  end

  defp assert_top_key_order(bytes) do
    positions =
      Enum.map(@top_keys, fn key ->
        {position, _} = :binary.match(bytes, "\"#{key}\":")
        position
      end)

    assert positions == Enum.sort(positions)
  end

  defp assert_record_order(manifest) do
    for collection <- @collections do
      records = manifest[Atom.to_string(collection)]
      keys = Enum.map(records, &record_key(collection, &1))
      assert keys == Enum.sort(keys)
      assert length(keys) == MapSet.size(MapSet.new(keys))
    end
  end

  defp canonical_record(collection, record) do
    "{" <>
      Enum.map_join(@record_fields[collection], ",", fn key ->
        JSON.encode!(key) <> ":" <> JSON.encode!(record[key])
      end) <> "}"
  end

  defp record_key(collection, r) when collection in [:resources, :tags, :relationships],
    do: r["id"]

  defp record_key(:versions, r), do: {r["resource_id"], r["version_id"]}
  defp record_key(:fragments, r), do: {r["resource_id"], r["version_id"], r["ordinal"], r["id"]}
  defp record_key(:tag_assignments, r), do: {r["resource_id"], r["tag_id"]}

  defp record_key(collection, r) when collection in [:attachments, :citations],
    do: {r["note_resource_id"], r["note_version_id"], r["ordinal"], r["id"]}

  defp fragment_selector(r),
    do: {:fragment_text, r["resource_id"], r["version_id"], r["ordinal"], r["id"]}

  defp path(kind, n, media \\ nil) do
    media = if kind == :document, do: media || "text/plain", else: nil
    {:ok, path} = KnowledgeExport.path(kind, uuid(n), uuid(n + 1_000), media)
    path
  end

  defp uuid(n),
    do:
      "00000000-0000-4000-8000-" <>
        String.pad_leading(Integer.to_string(n, 16) |> String.downcase(), 12, "0")

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp staging(c, state), do: Path.join(c.roots.writer, state.operation_id <> ".staging")
  defp completed(c, state), do: Path.join(c.roots.writer, state.operation_id <> ".complete")
  defp tree(path), do: Path.wildcard(Path.join(path, "**/*"), match_dot: true)
  defp assert_mode(path, mode), do: assert(Bitwise.band(File.lstat!(path).mode, 0o777) == mode)

  defp assert_private_tree(path) do
    for child <- tree(path) do
      case File.lstat!(child).type do
        :directory -> assert_mode(child, 0o700)
        :regular -> assert_mode(child, 0o600)
        other -> flunk("unexpected private filesystem type: #{other}")
      end
    end
  end

  defp temporary_disk_bytes(directory, f) do
    final_paths =
      Enum.flat_map(
        f.records.versions,
        &Enum.reject([&1["body_path"], &1["original_path"], &1["extracted_path"]], fn path ->
          is_nil(path)
        end)
      )
      |> MapSet.new()

    Enum.reduce(tree(directory), 0, fn file, acc ->
      case File.lstat!(file) do
        %{type: :regular, size: size} ->
          if MapSet.member?(final_paths, Path.relative_to(file, directory)),
            do: acc,
            else: acc + size

        _ ->
          acc
      end
    end)
  end

  defp assert_writer_root_empty(c) do
    assert File.ls!(c.roots.writer) == ["neighbor-sentinel"]
    assert File.read!(c.sentinel) == "neighbor"
  end

  defp payload_file(directory, canary) do
    Enum.find(tree(directory), fn file ->
      File.regular?(file) and String.contains?(File.read!(file), canary)
    end) || flunk("missing actual capture payload")
  end

  defp drain(token, acc \\ []) do
    receive do
      {^token, size} -> drain(token, [size | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp assert_error(result, code \\ nil) do
    assert {:error, %Error{} = error} = result
    if code, do: assert(error.code == code)
    text = inspect(error, limit: :infinity, printable_limit: :infinity)
    refute text =~ @body
    for canary <- @private_canaries, do: refute(text =~ canary)
    result
  end
end
